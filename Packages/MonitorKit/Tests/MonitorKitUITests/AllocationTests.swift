import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

/// The steady-state draw path: a tick reads the scene and hands frames over
/// with no heap allocation, and an encode allocates nothing beyond the library
/// calls it makes (the passes, the analysis, the scope), which allocate nothing
/// beyond Metal's own encoder objects.
final class AllocationTests: XCTestCase {
  struct Rig {
    let gpu: UIGPU
    let sources: [MonitorSource]
    let pools: [[MonitorFrame]]
    let surfaces: [MonitorSurface]
    let overlay: MonitorScopeOverlay
    let renderer: MonitorRenderer
    let target: MTLTexture
  }

  func rig() throws -> Rig {
    let gpu = try requireGPU()
    let sources = [MonitorSource(), MonitorSource()]
    let pools = try (0..<2).map { s in try (0..<4).map { try gpu.sdrFrame(width: 64, height: 36, seed: UInt8(s * 4 + $0)) } }
    var a = MonitorState()
    a.zebras[0] = ZebraSet(mode: .lowerLimit, level: 80)
    a.focus.enabled = true
    a.guides.enabled = true
    a.guides.thirds = true
    var b = MonitorState()
    b.falseColor.mode = .sixBand
    b.clipIndicators.enabled = true
    let surfaces = [
      MonitorSurface(source: sources[0], state: a, region: MonitorRegion(x: 0, y: 0, width: 0.5, height: 1)),
      MonitorSurface(source: sources[1], state: b, region: MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1)),
    ]
    var settings = ScopeSettings(kind: .waveform)
    settings.waveformColumns = 128
    settings.waveformLevels = 128
    let overlay = MonitorScopeOverlay(
      source: sources[0], settings: settings, region: MonitorRegion(x: 0, y: 0.5, width: 0.5, height: 0.5))
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: surfaces, scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    return Rig(
      gpu: gpu, sources: sources, pools: pools, surfaces: surfaces, overlay: overlay, renderer: renderer,
      target: gpu.texture(.bgra8Unorm, 128, 72))
  }

  /// A command buffer whose one-time setup (the first render encoder) is done,
  /// so it is not counted against whatever encodes next.
  func warmCommandBuffer(_ gpu: UIGPU, _ target: MTLTexture) -> MTLCommandBuffer {
    let cb = gpu.queue.makeCommandBuffer()!
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = target
    d.colorAttachments[0].loadAction = .load
    d.colorAttachments[0].storeAction = .store
    cb.makeRenderCommandEncoder(descriptor: d)!.endEncoding()
    let c = cb.makeComputeCommandEncoder()!
    c.endEncoding()
    return cb
  }

  func testSteadyTicksAndHandoffAllocateNothing() throws {
    try skipUnderTheDebugLayer()
    let r = try rig()
    for i in 0..<6 {
      r.sources[0].submit(r.pools[0][i % 4])
      r.sources[1].submit(r.pools[1][i % 4])
      try r.renderer.update()
      try r.gpu.run { try r.renderer.encode(target: r.target, into: $0) }
    }
    var submits: [Int] = [], ticks: [Int] = [], idle: [Int] = []
    for i in 0..<20 {
      let f0 = r.pools[0][i % 4], f1 = r.pools[1][(i + 1) % 4]
      guard let s = AllocationCounter.measure({
        r.sources[0].submit(f0)
        r.sources[1].submit(f1)
      }) else { throw XCTSkip("malloc_logger is unavailable") }
      submits.append(s)
      ticks.append(
        try AllocationCounter.measure {
          _ = try r.renderer.update()
          _ = r.renderer.needsDisplay(width: 128, height: 72, pixelFormat: .bgra8Unorm)
        }!)
      try r.gpu.run { try r.renderer.encode(target: r.target, into: $0) }
      // A tick with nothing new: what a display refreshing faster than the source does.
      idle.append(
        try AllocationCounter.measure {
          _ = try r.renderer.update()
          _ = r.renderer.needsDisplay(width: 128, height: 72, pixelFormat: .bgra8Unorm)
        }!)
    }
    XCTAssertEqual(submits.max(), 0, "MonitorSource.submit allocates")
    XCTAssertEqual(ticks.max(), 0, "update() with new frames allocates")
    XCTAssertEqual(idle.max(), 0, "an idle tick allocates")
  }

  /// The encode allocates no more than the same library calls made directly.
  func testEncodeAllocatesNothingBeyondTheLibrary() throws {
    try skipUnderTheDebugLayer()
    let r = try rig()
    let gpu = r.gpu
    // The same work by hand: two passes, the focus analysis, the scope.
    let feeds = [gpu.engine.makeFeed(), gpu.engine.makeFeed()]
    let passes = [gpu.engine.makePass(), gpu.engine.makePass()]
    let scopes = try gpu.scopeEngine()
    let accumulator = try scopes.makeAccumulator(settings: r.overlay.settings)
    let scopeRenderer = scopes.makeRenderer()
    let states = r.surfaces.map(\.state)
    let viewports = r.surfaces.map { $0.region.viewport(width: 128, height: 72)! }
    let scopeViewport = r.overlay.region.viewport(width: 128, height: 72)!
    func byHand(_ i: Int, _ cb: MTLCommandBuffer) throws {
      let f0 = r.pools[0][i % 4], f1 = r.pools[1][(i + 1) % 4]
      try feeds[0].analyze(f0, focus: states[0].focus, into: cb)
      try passes[0].encode(frame: f0, feed: feeds[0], state: states[0], target: r.target, viewport: viewports[0], clear: true, into: cb)
      try passes[1].encode(frame: f1, feed: feeds[1], state: states[1], target: r.target, viewport: viewports[1], clear: false, into: cb)
      try accumulator.accumulate(f0, feed: feeds[0], into: cb)
      try scopeRenderer.render(accumulator, target: r.target, viewport: scopeViewport, clear: false, into: cb)
    }
    for i in 0..<6 {
      r.sources[0].submit(r.pools[0][i % 4])
      r.sources[1].submit(r.pools[1][(i + 1) % 4])
      try r.renderer.update()
      try gpu.run { try r.renderer.encode(target: r.target, into: $0) }
      try gpu.run { try byHand(i, $0) }
    }
    var renderer: [Int] = [], library: [Int] = []
    for i in 6..<36 {
      r.sources[0].submit(r.pools[0][i % 4])
      r.sources[1].submit(r.pools[1][(i + 1) % 4])
      try r.renderer.update()
      let cb = warmCommandBuffer(gpu, r.target)
      guard let a = try AllocationCounter.measure({ try r.renderer.encode(target: r.target, into: cb) }) else {
        throw XCTSkip("malloc_logger is unavailable")
      }
      cb.commit()
      let cb2 = warmCommandBuffer(gpu, r.target)
      let b = try AllocationCounter.measure { try byHand(i, cb2) }!
      cb2.commit()
      cb2.waitUntilCompleted()
      renderer.append(a)
      library.append(b)
    }
    let a = renderer.sorted()[renderer.count / 2], b = library.sorted()[library.count / 2]
    print("BENCH MonitorRenderer encode: \(a) heap allocations per tick (2 surfaces, focus, a scope); the same library calls by hand: \(b)")
    XCTAssertLessThanOrEqual(a, b, "the renderer allocates beyond the library calls it makes")
  }

  /// The view's tick (as a display link runs it, here into an offscreen target)
  /// adds nothing to the renderer's encode.
  @MainActor
  func testViewTickAllocatesNothingBeyondTheRenderer() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    let source = MonitorSource()
    let pool = try (0..<4).map { try gpu.sdrFrame(seed: UInt8($0)) }
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 80)
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source, state: state)]),
      mode: .convenience(queue: gpu.queue))
    view.headroomOverride = 1
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    let reference = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source, state: state)]))
    for i in 0..<6 {
      source.submit(pool[i % 4])
      try gpu.run { view.drawOffscreen(into: target, commandBuffer: $0) }
      try reference.update()
      try gpu.run { try reference.encode(target: target, into: $0) }
    }
    var viewCounts: [Int] = [], rendererCounts: [Int] = []
    for i in 6..<30 {
      source.submit(pool[i % 4])
      let cb = warmCommandBuffer(gpu, target)
      guard let a = AllocationCounter.measure({ view.drawOffscreen(into: target, commandBuffer: cb) }) else {
        throw XCTSkip("malloc_logger is unavailable")
      }
      cb.commit()
      let cb2 = warmCommandBuffer(gpu, target)
      let b = try AllocationCounter.measure {
        _ = try reference.update()
        try reference.encode(target: target, into: cb2)
      }!
      cb2.commit()
      cb2.waitUntilCompleted()
      viewCounts.append(a)
      rendererCounts.append(b)
    }
    let a = viewCounts.sorted()[viewCounts.count / 2], b = rendererCounts.sorted()[rendererCounts.count / 2]
    print("BENCH MonitorMetalView tick: \(a) heap allocations; its renderer alone: \(b)")
    XCTAssertLessThanOrEqual(a, b)
    XCTAssertEqual(view.drawCount, 30)
  }
}

extension AllocationTests {
  /// The view's own command buffer per tick (made, encoded, committed, watched
  /// for completion) allocates no more than making, encoding and committing one
  /// by hand.
  @MainActor
  func testOwnCommandBufferTickAllocatesNothingExtra() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    let source = MonitorSource()
    let pool = try (0..<4).map { try gpu.sdrFrame(seed: UInt8($0)) }
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .convenience(queue: gpu.queue))
    view.headroomOverride = 1
    let reference = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    for i in 0..<6 {
      source.submit(pool[i % 4])
      view.drawOffscreen(into: target)
      try reference.update()
      let cb = gpu.queue.makeCommandBuffer()!
      try reference.encode(target: target, into: cb)
      cb.commit()
    }
    var viewCounts: [Int] = [], handCounts: [Int] = []
    for i in 6..<46 {
      source.submit(pool[i % 4])
      guard let a = AllocationCounter.measure({ view.drawOffscreen(into: target) }) else {
        throw XCTSkip("malloc_logger is unavailable")
      }
      let b = try AllocationCounter.measure {
        _ = try reference.update()
        let cb = gpu.queue.makeCommandBuffer()!
        try reference.encode(target: target, into: cb)
        cb.commit()
      }!
      viewCounts.append(a)
      handCounts.append(b)
    }
    try gpu.run { _ in }
    // Minimums: Metal's command-buffer pool adds tens of allocations to random ticks of either.
    let a = viewCounts.min()!, b = handCounts.min()!
    print("BENCH MonitorMetalView tick into its own command buffer: \(a) heap allocations (fewest of 40); by hand: \(b)")
    XCTAssertLessThanOrEqual(a, b)
  }
}

extension AllocationTests {
  /// Two analyses of one source (two feeds) and three scopes in one fused group:
  /// a steady tick with new frames allocates nothing, and an encode no more than
  /// the same library calls by hand.
  func testFeedsAndScopeGroupsAllocateNothingExtra() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    let source = MonitorSource()
    let pool = try (0..<4).map { try gpu.sdrFrame(width: 64, height: 36, seed: UInt8($0)) }
    var a = MonitorState(), b = MonitorState()
    a.focus.enabled = true
    b.focus.enabled = true
    b.focus.sensitivity = 0.9
    let regions = (0..<2).map { MonitorRegion(x: Double($0) / 2, y: 0, width: 0.5, height: 0.5) }
    let surfaces = [MonitorSurface(source: source, state: a, region: regions[0]), MonitorSurface(source: source, state: b, region: regions[1])]
    var w = ScopeSettings(kind: .waveform)
    w.waveformColumns = 128
    w.waveformLevels = 128
    let settings = [w, ScopeSettings(kind: .vectorscope), ScopeSettings(kind: .histogram)]
    let scopeRegions = (0..<3).map { MonitorRegion(x: Double($0) / 3, y: 0.5, width: 1.0 / 3, height: 0.5) }
    let overlays = (0..<3).map { MonitorScopeOverlay(source: source, settings: settings[$0], region: scopeRegions[$0]) }
    let scopes = try gpu.scopeEngine()
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: surfaces, scopes: overlays), scopeEngine: scopes)
    let target = gpu.texture(.bgra8Unorm, 128, 72)

    let feeds = [gpu.engine.makeFeed(), gpu.engine.makeFeed()]
    let passes = [gpu.engine.makePass(), gpu.engine.makePass()]
    let accumulators = try settings.map { try scopes.makeAccumulator(settings: $0) }
    let group = try scopes.makeGroup(accumulators)
    let scopeRenderers = (0..<3).map { _ in scopes.makeRenderer() }
    let states = [a, b]
    func byHand(_ frame: MonitorFrame, _ cb: MTLCommandBuffer) throws {
      for i in 0..<2 { try feeds[i].analyze(frame, focus: states[i].focus, into: cb) }
      try group.accumulate(frame, feed: feeds[0], into: cb)
      for i in 0..<2 {
        try passes[i].encode(
          frame: frame, feed: feeds[i], state: states[i], target: target,
          viewport: regions[i].viewport(width: 128, height: 72)!, clear: i == 0, into: cb)
      }
      for i in 0..<3 {
        try scopeRenderers[i].render(
          accumulators[i], target: target, viewport: scopeRegions[i].viewport(width: 128, height: 72)!, into: cb)
      }
    }
    for i in 0..<6 {
      source.submit(pool[i % 4])
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
      try gpu.run { try byHand(pool[i % 4], $0) }
    }
    XCTAssertEqual(renderer.feedCount(for: source), 2)
    XCTAssertEqual(renderer.scopeGroup(for: overlays[0])?.fusedMemberCount, 3)
    var ticks: [Int] = [], encodes: [Int] = [], hand: [Int] = []
    for i in 6..<30 {
      source.submit(pool[i % 4])
      guard let t = AllocationCounter.measure({
        _ = try? renderer.update()
        _ = renderer.needsDisplay(width: 128, height: 72, pixelFormat: .bgra8Unorm)
      }) else { throw XCTSkip("malloc_logger is unavailable") }
      ticks.append(t)
      let cb = warmCommandBuffer(gpu, target)
      encodes.append(try AllocationCounter.measure { try renderer.encode(target: target, into: cb) }!)
      cb.commit()
      let cb2 = warmCommandBuffer(gpu, target)
      hand.append(try AllocationCounter.measure { try byHand(pool[i % 4], cb2) }!)
      cb2.commit()
      cb2.waitUntilCompleted()
    }
    let e = encodes.sorted()[encodes.count / 2], h = hand.sorted()[hand.count / 2]
    print("BENCH MonitorRenderer encode, 2 analyses + a fused group of 3 scopes: \(e) heap allocations; by hand: \(h)")
    XCTAssertEqual(ticks.max(), 0, "update() with new frames allocates")
    XCTAssertLessThanOrEqual(e, h)

    // Split into a pictures and a scopes buffer, with a scope rate holding some frames back.
    overlays[1].accumulationInterval = 0.002
    var splits: [Int] = []
    for i in 30..<54 {
      source.submit(pool[i % 4])
      guard let t = AllocationCounter.measure({ _ = try? renderer.update() }) else { return }
      ticks.append(t)
      let cb = warmCommandBuffer(gpu, target), cb2 = warmCommandBuffer(gpu, target)
      splits.append(
        try AllocationCounter.measure {
          try renderer.encodePictures(target: target, into: cb)
          if renderer.scopesDue { renderer.encodeScopes(into: cb2) }
        }!)
      cb.commit()
      cb2.commit()
      cb2.waitUntilCompleted()
    }
    let sp = splits.sorted()[splits.count / 2]
    print("BENCH MonitorRenderer encodePictures + encodeScopes: \(sp) heap allocations")
    XCTAssertEqual(ticks.max(), 0, "update() with a scope rate allocates")
    XCTAssertLessThanOrEqual(sp, h)
  }
}

extension AllocationTests {
  /// A presenting tick with a scope (pictures, then scopes in a second command
  /// buffer) allocates no more than the same split encode by hand.
  @MainActor
  func testSplitScopeTickAllocatesNothingExtra() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    let source = MonitorSource()
    let pool = try (0..<4).map { try gpu.sdrFrame(seed: UInt8($0)) }
    let scopes = try gpu.scopeEngine()
    func scene() -> MonitorScene {
      MonitorScene(
        surfaces: [MonitorSurface(source: source)],
        scopes: [
          MonitorScopeOverlay(
            source: source, settings: ScopeSettings(kind: .histogram),
            region: MonitorRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        ])
    }
    let view = MonitorMetalView(
      engine: gpu.engine, scene: scene(), mode: .convenience(queue: gpu.queue), scopeEngine: scopes)
    view.headroomOverride = 1
    view.metalLayer.pixelFormat = .bgra8Unorm
    view.metalLayer.drawableSize = CGSize(width: 64, height: 36)
    view.driver.noteApplied(MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))
    let reference = MonitorRenderer(engine: gpu.engine, scene: scene(), scopeEngine: scopes)
    let layer = CAMetalLayer()
    layer.device = gpu.device
    layer.pixelFormat = .bgra8Unorm
    layer.drawableSize = CGSize(width: 64, height: 36)
    func byHand(_ drawable: CAMetalDrawable) throws {
      _ = try reference.update()
      let cb = gpu.queue.makeCommandBuffer()!
      try reference.encodePictures(target: drawable.texture, into: cb)
      cb.present(drawable)
      cb.commit()
      if reference.scopesDue {
        let cb2 = gpu.queue.makeCommandBuffer()!
        reference.encodeScopes(into: cb2)
        cb2.commit()
      }
    }
    var viewCounts: [Int] = [], handCounts: [Int] = []
    for i in 0..<46 {
      source.submit(pool[i % 4])
      guard let drawable = view.metalLayer.nextDrawable() else { throw XCTSkip("no drawable off-window") }
      let texture = drawable.texture
      guard let a = AllocationCounter.measure({
        view.driver.tick(drawable: drawable, texture: texture, timestamp: 0, commandBuffer: nil)
      }) else { throw XCTSkip("malloc_logger is unavailable") }
      XCTAssertNotNil(view.driver.lastScopeBuffer)
      guard let own = layer.nextDrawable() else { throw XCTSkip("no drawable off-window") }
      let b = try AllocationCounter.measure { try byHand(own) }!
      try gpu.run { _ in }
      if i >= 6 {
        viewCounts.append(a)
        handCounts.append(b)
      }
    }
    // Minimums: Metal's command-buffer pool adds tens of allocations to random ticks of either.
    let a = viewCounts.min()!, b = handCounts.min()!
    print("BENCH MonitorMetalView presenting tick with a scope (2 command buffers): \(a) heap allocations (fewest of 40); by hand: \(b)")
    XCTAssertLessThanOrEqual(a, b)
  }
}
