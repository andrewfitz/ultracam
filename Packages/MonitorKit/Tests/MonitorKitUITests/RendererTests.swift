import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import Synchronization
import XCTest

@testable import MonitorKitUI

/// The drawable-free path: the renderer draws into offscreen textures exactly
/// what the library's own passes draw, so the view tier adds nothing to the pixels.
final class RendererTests: XCTestCase {
  func toolState() -> MonitorState {
    var s = MonitorState()
    s.zebras[0] = ZebraSet(mode: .lowerLimit, level: 70)
    s.guides.enabled = true
    s.guides.thirds = true
    s.guides.centerCross = true
    return s
  }

  func testSingleSurfaceMatchesThePass() throws {
    let gpu = try requireGPU()
    let frame = try gpu.sdrFrame()
    let source = MonitorSource()
    source.submit(frame)
    let state = toolState()
    let surface = MonitorSurface(source: source, state: state)
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
    let target = gpu.texture(.bgra8Unorm, 96, 54)
    XCTAssertTrue(try renderer.update())
    XCTAssertTrue(renderer.needsDisplay(width: 96, height: 54, pixelFormat: .bgra8Unorm))
    try gpu.run { try renderer.encode(target: target, into: $0) }

    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let reference = gpu.texture(.bgra8Unorm, 96, 54)
    try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: reference, into: $0) }
    XCTAssertEqual(Texels(target), Texels(reference))
    XCTAssertEqual(surface.status, pass.status)
    XCTAssertEqual(surface.layout, pass.layout)
    XCTAssertEqual(surface.viewport, MonitorViewport(width: 96, height: 54))
    XCTAssertTrue(renderer.takeStatusChanges())
    XCTAssertFalse(renderer.takeStatusChanges())
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))
  }

  /// Two surfaces side by side, each with its own tools: the same pixels as two
  /// passes into viewports of one target, the first clearing it.
  func testSurfacesTileTheTarget() throws {
    let gpu = try requireGPU()
    let a = try gpu.sdrFrame(seed: 0), b = try gpu.sdrFrame(width: 48, height: 48, seed: 60)
    let sa = MonitorSource(), sb = MonitorSource()
    sa.submit(a)
    sb.submit(b)
    var stateB = MonitorState()
    stateB.falseColor.mode = .sixBand
    let left = MonitorSurface(source: sa, state: toolState(), region: MonitorRegion(x: 0, y: 0, width: 0.5, height: 1))
    let right = MonitorSurface(source: sb, state: stateB, region: MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1))
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [left, right]))
    renderer.pixelsPerPoint = 2
    let target = gpu.texture(.bgra8Unorm, 101, 40)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }

    let vl = try XCTUnwrap(left.region.viewport(width: 101, height: 40, pixelsPerPoint: 2))
    let vr = try XCTUnwrap(right.region.viewport(width: 101, height: 40, pixelsPerPoint: 2))
    XCTAssertEqual(vl.width + vr.width, 101)
    let reference = gpu.texture(.bgra8Unorm, 101, 40)
    let pl = gpu.engine.makePass(), pr = gpu.engine.makePass()
    let fl = gpu.engine.makeFeed(), fr = gpu.engine.makeFeed()
    try gpu.run { cb in
      try pl.encode(frame: a, feed: fl, state: self.toolState(), target: reference, viewport: vl, clear: true, into: cb)
      try pr.encode(frame: b, feed: fr, state: stateB, target: reference, viewport: vr, clear: false, into: cb)
    }
    XCTAssertEqual(Texels(target), Texels(reference))
    XCTAssertEqual(right.status, pr.status)
    XCTAssertTrue(right.status.isActive(.falseColor))
  }

  /// Nothing to draw: the target is still cleared to black, not left with old pixels.
  func testEmptySceneClearsToBlack() throws {
    let gpu = try requireGPU()
    let target = gpu.texture(.bgra8Unorm, 16, 8)
    let red = [UInt8](repeating: 255, count: 16 * 8 * 4)
    target.replace(region: MTLRegionMake2D(0, 0, 16, 8), mipmapLevel: 0, withBytes: red, bytesPerRow: 64)
    let surface = MonitorSurface(source: MonitorSource())
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertTrue(Texels(target).values.allSatisfy { $0 == SIMD4(0, 0, 0, 1) })
  }

  /// An unchanged scene needs no draw; a frame, an edit, the headroom (on an EDR
  /// layer), the size or the format each make one.
  func testNeedsDisplayTracksChanges() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let surface = MonitorSurface(source: source)
    let scene = MonitorScene(surfaces: [surface])
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene)
    let target = gpu.texture(.bgra8Unorm, 32, 18)
    func draw() throws {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    func needs() throws -> Bool {
      try renderer.update()
      return renderer.needsDisplay(width: 32, height: 18, pixelFormat: .bgra8Unorm)
    }
    try draw()
    XCTAssertFalse(try needs())
    XCTAssertFalse(try renderer.update(), "a steady tick changes nothing")
    source.submit(try gpu.sdrFrame(seed: 9))
    XCTAssertTrue(try needs())
    try draw()
    XCTAssertFalse(try needs())
    surface.state = MonitorState()  // the same state: no revision
    XCTAssertFalse(try needs())
    surface.updateState { $0.display.brightness = 0.1 }
    XCTAssertTrue(try needs())
    try draw()
    scene.headroom = 2
    XCTAssertFalse(try needs(), "an SDR layer's pictures do not depend on the headroom")
    scene.outputColor = MonitorOutputColor(encoding: .extendedLinear)
    XCTAssertTrue(try needs())
    try draw()
    scene.headroom = 3
    XCTAssertTrue(try needs(), "an EDR layer's do")
    try draw()
    XCTAssertTrue(renderer.needsDisplay(width: 33, height: 18, pixelFormat: .bgra8Unorm))
    XCTAssertTrue(renderer.needsDisplay(width: 32, height: 18, pixelFormat: .rgba16Float))
    renderer.pixelsPerPoint = 2
    XCTAssertTrue(renderer.needsDisplay(width: 32, height: 18, pixelFormat: .bgra8Unorm))
    renderer.pixelsPerPoint = 1
    XCTAssertFalse(renderer.needsDisplay(width: 32, height: 18, pixelFormat: .bgra8Unorm))
    renderer.setNeedsDisplay()
    XCTAssertTrue(renderer.needsDisplay(width: 32, height: 18, pixelFormat: .bgra8Unorm))
  }

  /// Signal-native: the first surface with a frame tags the layer and draws its
  /// signal untouched; every other surface (and scope) is encoded for that tag.
  func testSignalNativeLayerFollowsTheFirstSurface() throws {
    let gpu = try requireGPU()
    let hdr = MonitorSource(), sdr = MonitorSource()
    hdr.submit(try gpu.pqFrame())
    sdr.submit(try gpu.sdrFrame())
    let first = MonitorSurface(source: hdr, region: MonitorRegion(x: 0, y: 0, width: 0.5, height: 1))
    let second = MonitorSurface(source: sdr, region: MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1))
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [first, second]))
    try renderer.update()
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec2020, kind: .pq))
    XCTAssertEqual(renderer.pass(for: first)?.outputColor.encoding, .signalNative)
    XCTAssertEqual(renderer.pass(for: second)?.outputColor.encoding, .pq)
    XCTAssertEqual(renderer.pass(for: second)?.outputColor.primaries, .rec2020)

    // Primaries come from the label, not the transfer: PQ labelled BT.709 stays BT.709.
    hdr.submit(try gpu.pqFrame(primaries: .rec709))
    try renderer.update()
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec709, kind: .pq))

    // A display transform makes the first picture SDR, and so the layer.
    first.updateState { $0.displayTransform.mode = .hdrToSDR }
    try renderer.update()
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))

    // The HDR source goes away: the SDR surface is first now.
    hdr.clear()
    try renderer.update()
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))
    XCTAssertEqual(renderer.pass(for: second)?.outputColor.encoding, .signalNative)

    // An explicit output colour applies to every surface.
    renderer.scene.outputColor = MonitorOutputColor(primaries: .displayP3, encoding: .extendedLinear)
    try renderer.update()
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .displayP3, kind: .extendedLinear))
    XCTAssertEqual(renderer.pass(for: first)?.outputColor.encoding, .extendedLinear)
    XCTAssertEqual(renderer.pass(for: second)?.outputColor.encoding, .extendedLinear)
  }

  /// The headroom reaches the pass as a uniform: HDR passthrough into extended
  /// linear rolls highlights off to it, matching Core's reference, with no rebuild.
  func testHeadroomPropagatesToThePicture() throws {
    let gpu = try requireGPU()
    let frame = try gpu.pqFrame()
    let source = MonitorSource()
    source.submit(frame)
    var state = MonitorState()
    state.displayTransform.mode = .hdrPassthrough
    let surface = MonitorSurface(source: source, state: state)
    let scene = MonitorScene(surfaces: [surface])
    scene.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear, headroom: 9)
    XCTAssertEqual(scene.outputColor.headroom, 1, "the scene's output colour carries no headroom; the view sets it")
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene)
    let target = gpu.texture(.rgba16Float, 64, 16)
    var brightest: [Double: Float] = [:]
    var toneMaps: [SIMD4<Float>] = []
    var rebuilds: [Int] = []
    for headroom in [1.0, 4.0, 2.5] {
      scene.headroom = headroom
      try renderer.update()
      XCTAssertEqual(renderer.headroom, headroom)
      try gpu.run { try renderer.encode(target: target, into: $0) }
      let pass = try XCTUnwrap(renderer.pass(for: surface))
      XCTAssertEqual(pass.outputColor.headroom, headroom)
      XCTAssertTrue(pass.status.isActive(.displayTransform), "\(pass.status)")
      toneMaps.append(pass.currentParameters.toneMap)
      rebuilds.append(pass.rebuildCount)
      let texels = Texels(target)
      brightest[headroom] = texels[63, 8].y
      // Core's CPU reference of the same pipeline.
      for x in [16, 40, 63] {
        let v = Double(x) / 63
        let expected = pass.colorPipeline.converted(ColorRGB(r: v, g: v, b: v), headroom: headroom)
        XCTAssertEqual(Double(texels[x, 8].y), expected.g, accuracy: max(2e-3, expected.g * 2e-3), "x \(x) headroom \(headroom)")
      }
    }
    XCTAssertNotEqual(toneMaps[0], toneMaps[1])
    XCTAssertEqual(Set(rebuilds).count, 1, "a headroom change rebuilds nothing")
    let b1 = try XCTUnwrap(brightest[1]), b4 = try XCTUnwrap(brightest[4])
    XCTAssertLessThanOrEqual(b1, 1.001)
    XCTAssertGreaterThan(b4, b1)
    XCTAssertLessThanOrEqual(b4, 4.001)
  }

  /// A source's LUTs reach its feed, and through it every surface of the source.
  func testSourceLUTsReachTheFeed() throws {
    let gpu = try requireGPU()
    let frame = try gpu.sdrFrame()
    let source = MonitorSource()
    source.submit(frame)
    let surface = MonitorSurface(source: source)
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
    let cube = try CubeLUT(
      text: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n0.5 0.5 0.5\n")
    let lut = try MonitorLUT(device: gpu.device, cube: cube)
    source.setLUT(lut, routing: .monitorOnly)
    XCTAssertTrue(source.monitorLUT === lut)
    XCTAssertNil(source.burnInLUT)
    try renderer.update()
    XCTAssertTrue(renderer.feed(for: source)?.monitorLUT === lut)
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try gpu.run { try renderer.encode(target: target, into: $0) }
    let feed = gpu.engine.makeFeed()
    feed.monitorLUT = lut
    let reference = gpu.texture(.bgra8Unorm, 64, 36)
    let pass = gpu.engine.makePass()
    try gpu.run { try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: reference, into: $0) }
    XCTAssertEqual(Texels(target), Texels(reference))
    XCTAssertTrue(surface.status.isActive(.monitorLUT))

    source.setLUT(lut, routing: .burnIn)
    try renderer.update()
    XCTAssertTrue(renderer.feed(for: source)?.burnInLUT === lut)
    XCTAssertNil(renderer.feed(for: source)?.monitorLUT)
    XCTAssertGreaterThan(renderer.retiredCount, 0, "the replaced assignment stays referenced for in-flight work")
  }

  /// Peaking on two surfaces of one source: one analysis per new frame.
  func testFocusAnalysisOncePerFrame() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    var state = MonitorState()
    state.focus.enabled = true
    let a = MonitorSurface(source: source, state: state, region: MonitorRegion(x: 0, y: 0, width: 0.5, height: 1))
    let b = MonitorSurface(source: source, state: state, region: MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1))
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [a, b]))
    let target = gpu.texture(.bgra8Unorm, 64, 18)
    for i in 0..<3 {
      source.submit(try gpu.sdrFrame(seed: UInt8(i)))
      for _ in 0..<2 {
        try renderer.update()
        try gpu.run { try renderer.encode(target: target, into: $0) }
      }
    }
    XCTAssertEqual(renderer.feed(for: source)?.analysisCount, 3)
    XCTAssertTrue(a.status.isActive(.focusPeaking), "\(a.status)")
    XCTAssertTrue(b.status.isActive(.focusPeaking), "\(b.status)")
  }

  /// Replaced frames stay referenced for the frames in flight, then go.
  func testReplacedFramesAreHeldOnlyWhileInFlight() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]))
    let target = gpu.texture(.bgra8Unorm, 16, 9)
    weak var firstTexture: MTLTexture?
    try autoreleasepool {
      let first = try gpu.sdrFrame(width: 16, height: 9)
      firstTexture = first.luma
      source.submit(first)
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    let window = max(3, gpu.engine.framesInFlight)
    for i in 0..<(window + 3) {
      source.submit(try gpu.sdrFrame(width: 16, height: 9, seed: UInt8(i)))
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
      XCTAssertLessThanOrEqual(renderer.retiredCount, window)
    }
    XCTAssertNil(firstTexture, "the first frame's texture was released once its encode was out of the window")
    for _ in 0..<(window + 1) {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    XCTAssertEqual(renderer.retiredCount, 0)
  }

  /// A scope overlay over a picture: the same pixels as the pass, the
  /// accumulation and the scope renderer encoded by hand, and its graticule published.
  func testScopeOverlayMatchesTheLibrary() throws {
    let gpu = try requireGPU()
    let scopes = try gpu.scopeEngine()
    let frame = try gpu.sdrFrame(width: 96, height: 54)
    let source = MonitorSource()
    source.submit(frame)
    let surface = MonitorSurface(source: source)
    var settings = ScopeSettings(kind: .waveform, stage: .output)
    settings.waveformColumns = 128
    settings.waveformLevels = 128
    let region = MonitorRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
    let overlay = MonitorScopeOverlay(source: source, settings: settings, region: region)
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [surface], scopes: [overlay]), scopeEngine: scopes)
    let target = gpu.texture(.bgra8Unorm, 160, 90)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertTrue(renderer.accumulator(for: overlay)?.hasData == true)
    let graticule = try XCTUnwrap(overlay.graticule)
    XCTAssertFalse(graticule.labels.isEmpty)
    XCTAssertTrue(renderer.takeGraticuleChanges())

    let vp = try XCTUnwrap(region.viewport(width: 160, height: 90))
    let reference = gpu.texture(.bgra8Unorm, 160, 90)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let accumulator = try scopes.makeAccumulator(settings: settings)
    let scopeRenderer = scopes.makeRenderer()
    scopeRenderer.setOutputColor(MonitorOutputColor.signalNative.explicit(for: renderer.layerColor))
    try gpu.run { cb in
      try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: reference, into: cb)
      try accumulator.accumulate(frame, feed: feed, into: cb)
      try scopeRenderer.render(accumulator, target: reference, viewport: vp, clear: false, into: cb)
    }
    XCTAssertEqual(Texels(target), Texels(reference))
    XCTAssertEqual(scopeRenderer.graticule, graticule)

    // The same frame again accumulates nothing new.
    let generation = renderer.accumulator(for: overlay)?.generation
    renderer.setNeedsDisplay()
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.accumulator(for: overlay)?.generation, generation)
  }

  /// A scope alone (no picture) clears the target itself.
  func testScopeOnlyScene() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let overlay = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .vectorscope))
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    let target = gpu.texture(.bgra8Unorm, 64, 64)
    let red = [UInt8](repeating: 255, count: 64 * 64 * 4)
    target.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: red, bytesPerRow: 256)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertFalse(Texels(target).values.contains(SIMD4(1, 1, 1, 1)), "the old contents were cleared")
    XCTAssertTrue(renderer.scopeRenderer(for: overlay)?.isReady == true)
  }

  /// Membership changes keep the passes of surfaces that stay, and release the rest.
  func testMembershipChangesKeepState() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let a = MonitorSurface(source: source), b = MonitorSurface(source: source)
    let scene = MonitorScene(surfaces: [a])
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene)
    try renderer.update()
    let passA = renderer.pass(for: a)
    scene.surfaces = [b, a]
    try renderer.update()
    XCTAssertTrue(renderer.pass(for: a) === passA)
    XCTAssertNotNil(renderer.pass(for: b))
    XCTAssertTrue(renderer.feed(for: source) != nil)
    scene.surfaces = [b]
    try renderer.update()
    XCTAssertNil(renderer.pass(for: a))
    scene.surfaces = []
    try renderer.update()
    XCTAssertNil(renderer.feed(for: source))
  }
}

/// A host's Metal 4 side: one queue with the engine's residency set and a host
/// set attached; submissions are committed and waited for here, never in the library.
final class MTL4Host {
  let gpu: UIGPU
  let queue: MTL4CommandQueue
  let host: MTLResidencySet
  let allocator: MTL4CommandAllocator
  private(set) var next: UInt64 = 1

  init(_ gpu: UIGPU) throws {
    guard gpu.device.supportsFamily(.metal4), let queue = gpu.device.makeMTL4CommandQueue() else {
      throw XCTSkip("No Metal 4 device")
    }
    self.gpu = gpu
    self.queue = queue
    let d = MTLResidencySetDescriptor()
    d.label = "MonitorKitUI tests host"
    host = try gpu.device.makeResidencySet(descriptor: d)
    queue.addResidencySet(gpu.engine.residency.set)
    queue.addResidencySet(host)
    allocator = gpu.device.makeCommandAllocator()!
  }

  func resident(_ textures: MTLTexture?...) {
    for t in textures { if let t { host.addAllocation(t) } }
    host.commit()
  }

  /// Encodes one submission (claiming `completed` as done), commits it and waits.
  func run(completed: UInt64? = nil, _ body: (MonitorSubmission) throws -> Void) throws {
    let index = next
    next += 1
    allocator.reset()
    let cb = gpu.device.makeCommandBuffer()!
    cb.beginCommandBuffer(allocator: allocator)
    try body(MonitorSubmission(commandBuffer: cb, index: index, completedIndex: completed ?? index - 1))
    cb.endCommandBuffer()
    let done = DispatchSemaphore(value: 0)
    let failed = Mutex(false)
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in
      if feedback.error != nil { failed.withLock { $0 = true } }
      done.signal()
    }
    queue.commit([cb], options: options)
    done.wait()
    XCTAssertFalse(failed.withLock { $0 }, "Metal 4 submission failed")
  }
}

/// The Metal 4 path draws the same pixels as the classic one.
final class RendererMetal4Tests: XCTestCase {
  func testMetal4MatchesClassic() throws {
    let gpu = try requireGPU()
    let mtl4 = try MTL4Host(gpu)
    let frame = try gpu.sdrFrame(width: 80, height: 45)
    frame.addResidency(to: mtl4.host)
    let source = MonitorSource()
    source.submit(frame)
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .band, level: 50, range: 10)
    state.focus.enabled = true
    state.guides.enabled = true
    let left = MonitorSurface(source: source, state: state, region: MonitorRegion(x: 0, y: 0, width: 0.6, height: 1))
    let right = MonitorSurface(source: source, region: MonitorRegion(x: 0.6, y: 0, width: 0.4, height: 1))
    let overlay = MonitorScopeOverlay(
      source: source, settings: ScopeSettings(kind: .histogram), region: MonitorRegion(x: 0, y: 0.6, width: 0.4, height: 0.4))
    let scopes = try gpu.scopeEngine()
    let classic = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [left, right], scopes: [overlay]), scopeEngine: scopes)
    let metal4 = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: [left, right], scopes: [overlay]), scopeEngine: scopes)
    let t1 = gpu.texture(.bgra8Unorm, 120, 60), t2 = gpu.texture(.bgra8Unorm, 120, 60)
    mtl4.resident(t2)
    try classic.update()
    try gpu.run { try classic.encode(target: t1, into: $0) }
    try metal4.update()
    try mtl4.run { try metal4.encode(target: t2, into: $0) }
    XCTAssertEqual(Texels(t1), Texels(t2))
    XCTAssertEqual(metal4.encodeCount, 1)
  }

  /// Replaced frames are held until the host reports their submission complete.
  func testMetal4HoldsReplacedFramesUntilCompleted() throws {
    let gpu = try requireGPU()
    let mtl4 = try MTL4Host(gpu)
    let source = MonitorSource()
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]))
    let target = gpu.texture(.bgra8Unorm, 16, 9)
    mtl4.resident(target)
    weak var first: MTLTexture?, second: MTLTexture?
    var previous: MonitorFrame?
    // A capture host: each new frame made resident, the one it replaces dropped
    // from the host's set (the residency set would otherwise keep it alive).
    func submitFrame(_ seed: UInt8) throws -> MTLTexture? {
      let f = try gpu.sdrFrame(width: 16, height: 9, seed: seed)
      f.addResidency(to: mtl4.host)
      previous?.removeResidency(from: mtl4.host)
      mtl4.host.commit()
      previous = f
      source.submit(f)
      return f.luma
    }
    try autoreleasepool { first = try submitFrame(0) }
    try renderer.update()
    try mtl4.run(completed: 0) { try renderer.encode(target: target, into: $0) }  // 1
    try autoreleasepool { second = try submitFrame(1) }
    try renderer.update()
    try mtl4.run(completed: 0) { try renderer.encode(target: target, into: $0) }  // 2: the host knows of no completion
    XCTAssertEqual(renderer.retiredCount, 1)
    XCTAssertNotNil(first, "held: submission 1 may still read it")
    try autoreleasepool { _ = try submitFrame(2) }
    try renderer.update()
    try mtl4.run(completed: 1) { try renderer.encode(target: target, into: $0) }  // 3
    XCTAssertNil(first, "released once submission 1 completed")
    XCTAssertNotNil(second)
    XCTAssertEqual(renderer.retiredCount, 1)
    try renderer.update()
    try mtl4.run(completed: 3) { try renderer.encode(target: target, into: $0) }  // 4
    XCTAssertNil(second)
    XCTAssertEqual(renderer.retiredCount, 0)
  }

  /// No frames, and a scope-only scene: the target is cleared on Metal 4 too.
  func testMetal4ClearsTheTarget() throws {
    let gpu = try requireGPU()
    let mtl4 = try MTL4Host(gpu)
    let red = [UInt8](repeating: 255, count: 64 * 64 * 4)
    let empty = gpu.texture(.bgra8Unorm, 64, 64)
    empty.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: red, bytesPerRow: 256)
    mtl4.resident(empty)
    let none = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: MonitorSource())]))
    try none.update()
    try mtl4.run { try none.encode(target: empty, into: $0) }
    XCTAssertTrue(Texels(empty).values.allSatisfy { $0 == SIMD4(0, 0, 0, 1) })

    let source = MonitorSource()
    let frame = try gpu.sdrFrame()
    frame.addResidency(to: mtl4.host)
    source.submit(frame)
    let overlay = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .vectorscope))
    let scopeOnly = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    let t4 = gpu.texture(.bgra8Unorm, 64, 64)
    t4.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: red, bytesPerRow: 256)
    mtl4.resident(t4)
    try scopeOnly.update()
    try mtl4.run { try scopeOnly.encode(target: t4, into: $0) }
    let classic = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    let t1 = gpu.texture(.bgra8Unorm, 64, 64)
    t1.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: red, bytesPerRow: 256)
    try classic.update()
    try gpu.run { try classic.encode(target: t1, into: $0) }
    XCTAssertEqual(Texels(t4), Texels(t1))
    XCTAssertFalse(Texels(t4).values.contains(SIMD4(1, 1, 1, 1)))
  }
}
