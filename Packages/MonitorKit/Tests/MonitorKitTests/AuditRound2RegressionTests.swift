import Metal
import XCTest
import simd

@testable import MonitorKit

/// One test per defect found in the second audit of the picture module.
final class AuditRound2RegressionTests: XCTestCase {
  // MARK: - Guides

  /// Draws `pass`'s prepared picture with `guides` in place of its own strokes.
  func drawWithGuides(_ gpu: TestGPU, _ guides: GuideParameters?, state: MonitorState) throws -> Pixels {
    let frame = try SyntheticFrame.neutral(.v210, width: 96, height: 48) { _, _ in 64 }.frame(gpu, signal: .rec709)
    let pass = gpu.engine.makePass(), feed = gpu.engine.makeFeed()
    let target = gpu.target(96, 48)
    try gpu.run { cb in
      try pass.prepare(
        frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 96, height: 48),
        targetPixelFormat: .rgba32Float, into: cb)
      if let guides { pass.guides = guides }
      let d = MTLRenderPassDescriptor()
      d.colorAttachments[0].texture = target
      d.colorAttachments[0].loadAction = .clear
      d.colorAttachments[0].storeAction = .store
      let e = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: d))
      try pass.draw(with: e)
      e.endEncoding()
    }
    return Pixels(target)
  }

  /// A host that fills a `GuideParameters()` by hand (counts, reach, lines) gets
  /// its straight strokes: the cells start all set. Before, they started clear
  /// and every vertical and horizontal stroke was skipped.
  func testHandFilledGuideParametersDrawTheirLines() throws {
    let gpu = try requireGPU()
    var state = MonitorState()
    state.guides.enabled = true
    state.guides.thirds = true
    state.guides.color = ColorRGB(r: 1, g: 0, b: 0)
    state.guides.opacity = 1
    state.guides.contrast = 0
    var g = GuideParameters()
    g.counts = SIMD4(1, 1, 0, 0)
    g.reach = SIMD4(4, 1, 0, 0)
    g.lines[0] = SIMD4(10, 0, 48, 1)  // vertical at x = 10
    g.lines[1] = SIMD4(40, 0, 96, 1)  // horizontal at y = 40
    let hand = try drawWithGuides(gpu, g, state: state)
    XCTAssertEqual(hand.rgb(10, 20), SIMD3(1, 0, 0), "the vertical stroke")
    XCTAssertEqual(hand.rgb(70, 40), SIMD3(1, 0, 0), "the horizontal stroke")
    XCTAssertEqual(hand.rgb(32, 20), SIMD3(0, 0, 0), "the pass's own thirds are replaced")

    var updated = g
    updated.updateCells()
    XCTAssertNotEqual(updated.cells[0], .max, "updateCells clears the cells no stroke reaches")
    let fast = try drawWithGuides(gpu, updated, state: state)
    XCTAssertEqual(fast.values, hand.values, "updateCells keeps every stroke")

    // Garbage counts are clamped, not trapped on.
    var garbage = g
    garbage.counts = SIMD4(.max, .max, 0, 0)
    garbage.updateCells()
    XCTAssertNotEqual(garbage.cells[0], 0)

    // The control: clear cells skip the search, so the cells are what the test checks.
    var cleared = g
    cleared.cells = InlineArray(repeating: 0)
    XCTAssertEqual(try drawWithGuides(gpu, cleared, state: state).rgb(10, 20), SIMD3(0, 0, 0))
  }

  /// Raster-built guides still clear the cells no stroke reaches (the perf pass's skip).
  func testRasterGuidesKeepClearCells() throws {
    let layout = MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1080, pixelAspectRatio: 1, viewportWidth: 1920, viewportHeight: 1080,
      geometry: ViewGeometry())
    var settings = GuideSettings()
    settings.enabled = true
    let p = GuideParameters(GuideRaster(layout: layout, guides: settings, pixelsPerPoint: 1), outline: 1)
    var clear = 0, i = 0
    while i < 64 {
      clear += 32 - p.cells[i].nonzeroBitCount
      i += 1
    }
    XCTAssertGreaterThan(clear, 1500, "most cells are clear")
    var again = p
    again.updateCells()
    var same = true
    i = 0
    while i < 64 {
      same = same && again.cells[i] == p.cells[i]
      i += 1
    }
    XCTAssertTrue(same, "updateCells is what the raster builder computes")
  }

  // MARK: - Linear pictures

  /// A linear (EDR) signal shown signal-native is written as it is, values above
  /// 1 and below 0 included: its recommended layer is extended linear. Before, it
  /// was clipped to 0…1.
  func testSignalNativeLinearKeepsItsRange() throws {
    let gpu = try requireGPU()
    let signal = SignalDescription(range: .full, encoding: .display(.linear))
    XCTAssertEqual(MonitorOutputColor.recommended(for: signal).layer(for: signal).kind, .extendedLinear)
    let values: [SIMD3<Double>] = [SIMD3(4, 0.5, -0.25), SIMD3(16, 2, 0.125), SIMD3(0.18, 0.18, 0.18), SIMD3(-1, 1.5, 3)]
    var picture = SyntheticFrame(layout: .rgba16Float, width: values.count, height: 1)
    picture.rgb = values
    let frame = try picture.frame(gpu, signal: signal)
    for specialization in [true, false] {
      let pass = gpu.engine.makePass()
      pass.outputColor = .recommended(for: signal)
      var out = try gpu.render(frame, state: MonitorState(), pass: pass)
      if specialization {
        // Draw until the specialized pipeline is in use (it builds asynchronously).
        var tries = 0
        while !pass.usesSpecializedPipeline && tries < 400 {
          usleep(5000)
          out = try gpu.render(frame, state: MonitorState(), pass: pass)
          tries += 1
        }
        XCTAssertTrue(pass.usesSpecializedPipeline)
      }
      XCTAssertEqual(pass.colorPipeline.picture.transfer, .linear)
      XCTAssertFalse(pass.colorPipeline.convertsToTarget)
      for (i, v) in values.enumerated() {
        let stored = SIMD3<Float>(Float(Float16(v.x)), Float(Float16(v.y)), Float(Float16(v.z)))
        XCTAssertEqual(out.rgb(i, 0), stored, "#\(i) specialized: \(specialization)")
        let cpu = pass.colorPipeline.present(ColorRGB(r: v.x, g: v.y, b: v.z), range: .full)
        XCTAssertEqual(cpu, ColorRGB(r: v.x, g: v.y, b: v.z), "the CPU reference keeps it too")
      }
    }
  }

  // MARK: - EETF

  /// A roll-off target a hair under the source peak rounds the EETF's knee to
  /// 1.0f; the shader clipped 0/0 to black (or NaN) at and above the peak. It now
  /// clips to maxLum, as the Double reference does.
  func testNearIdentityRolloffKeepsHighlights() throws {
    let gpu = try requireGPU()
    let pq = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq))
    let headroom = Double(Float(1000.0 / 203))
    let pass = gpu.engine.makePass()
    pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear, headroom: headroom)
    var state = MonitorState()
    state.displayTransform.mode = .hdrPassthrough
    let peak = ColorMath.pqSignal(nits: 1000)
    let codes = [0.5, peak - 1e-4, peak, 0.8, 1.0]
    let frame = try OutputColorGPUTests().floatFrame(gpu, codes.map { SIMD3(repeating: $0) }, signal: pq)
    let out = try gpu.render(frame, state: state, pass: pass)
    let eetf = try XCTUnwrap(pass.colorPipeline.rolloff(headroom: headroom))
    XCTAssertFalse(eetf.isIdentity)
    XCTAssertEqual(Float(eetf.kneeStart), 1, "the case under test: the knee rounds to 1.0f")
    XCTAssertEqual(pass.currentParameters.toneMap.w, 0)
    for (i, c) in codes.enumerated() {
      let v = out.rgb(i, 0)
      let cpu = pass.colorPipeline.present(ColorRGB(r: c, g: c, b: c), range: .full, headroom: headroom)
      XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite, "#\(i)")
      XCTAssertEqual(Double(v.y), cpu.g, accuracy: 2e-4 * max(1, cpu.g), "#\(i) code \(c)")
    }
    XCTAssertEqual(Double(out.rgb(4, 0).y), 1000.0 / 203, accuracy: 2e-3, "a 10 000 cd/m² code lands at the peak")
  }

  // MARK: - Focus mask lifetime

  /// Three mask replacements in a row keep all three masks for their
  /// `retiredFrames` analyses; before, a two-slot window dropped the oldest.
  func testRetiredMasksEachLastTheirWindow() throws {
    let gpu = try requireGPU()
    XCTAssertEqual(MonitorFeed.retiredFrames, 3, "the retired ring has retiredFrames slots")
    let a = try SyntheticFrame.neutral(.v210, width: 48, height: 16) { x, _ in 64 + x * 10 }.frame(gpu, signal: .rec709)
    let b = try SyntheticFrame.neutral(.v210, width: 36, height: 12) { x, _ in 64 + x * 10 }.frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    var focus = FocusSettings()
    focus.enabled = true
    weak var first: MTLTexture?
    try gpu.run { cb in try feed.analyze(a, focus: focus, into: cb) }
    first = feed.focusMask
    for (i, f) in [b, a, b].enumerated() {
      try gpu.run { cb in try feed.analyze(f, focus: focus, into: cb) }
      XCTAssertEqual(feed.retiredMaskCount, i + 1)
    }
    XCTAssertNotNil(first, "the first replaced mask is still held two analyses later")
    // Same size from now on: each leaves after its own window.
    for expected in [2, 1, 0] {
      try gpu.run { cb in try feed.analyze(b, focus: focus, into: cb) }
      XCTAssertEqual(feed.retiredMaskCount, expected)
    }
    XCTAssertNil(first)
    // Releasing (peaking off) retires through the same ring.
    try gpu.run { cb in try feed.analyze(b, focus: FocusSettings(), into: cb) }
    XCTAssertEqual(feed.retiredMaskCount, 1)
  }

  // MARK: - Freeze on Metal 4

  /// A frozen frame the host still draws after `unfreeze()` released its planes
  /// is made resident again for that submission (it used to read non-resident memory).
  func testFrozenFrameDrawnAfterUnfreezeIsResident() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let live = try m.frame(PictureTests.picture(width: 96, height: 54), signal: .rec709)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let residency = gpu.engine.residency
    var frozen: MonitorFrame?
    try m.run { s in frozen = try feed.freeze(live, into: s) }
    let shown = try XCTUnwrap(frozen)
    let plane = try XCTUnwrap(shown.packed ?? shown.luma)
    let expected = m.target(96, 54)
    try m.run { s in try pass.encode(frame: shown, feed: feed, state: MonitorState(), target: expected, into: s) }
    XCTAssertTrue(residency.contains(plane))

    feed.unfreeze()
    // Two more submissions: the release happens once the last one using the planes completed.
    try m.run { s in residency.observe(s) }
    try m.run { s in residency.observe(s) }
    XCTAssertFalse(residency.contains(plane), "unfreeze released the planes")

    let target = m.target(96, 54)
    try m.run { s in
      try pass.encode(frame: shown, feed: feed, state: MonitorState(), target: target, into: s)
      XCTAssertTrue(residency.contains(plane), "resident again for the submission that draws it")
    }
    XCTAssertEqual(rawBytes(target), rawBytes(expected))
    try m.run { s in residency.observe(s) }
    try m.run { s in residency.observe(s) }
    XCTAssertFalse(residency.contains(plane), "and released again once that submission completed")
    XCTAssertEqual(feed.persistentMemoryBytes, 0)
  }

  // MARK: - Pipelines

  /// `prepare` builds Freeze's copy kernels, so the first Freeze compiles nothing;
  /// an asynchronous engine starts them at init.
  func testPrepareBuildsTheCopyPipelines() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .off)
    XCTAssertNil(engine.cachedCopyPipeline(integer: true))
    try engine.prepare(pixelFormat: .bgra8Unorm, layouts: [.v210])
    XCTAssertNotNil(engine.cachedCopyPipeline(integer: true))
    XCTAssertNotNil(engine.cachedCopyPipeline(integer: false))

    let asynchronous = try MonitorEngine(device: gpu.device)
    let start = Date()
    while asynchronous.cachedCopyPipeline(integer: true) == nil || asynchronous.cachedCopyPipeline(integer: false) == nil,
      Date().timeIntervalSince(start) < 10
    {
      usleep(2000)
    }
    XCTAssertNotNil(asynchronous.cachedCopyPipeline(integer: true))
    XCTAssertNotNil(asynchronous.cachedCopyPipeline(integer: false))
  }

  // MARK: - Multiview

  static func surfaces(_ gpu: TestGPU) throws -> [(MonitorFrame, MonitorFeed, MonitorPass, MonitorState, MonitorViewport)] {
    var tools = MonitorState()
    everyTool(&tools)
    tools.focus.enabled = false
    var out: [(MonitorFrame, MonitorFeed, MonitorPass, MonitorState, MonitorViewport)] = []
    for i in 0..<4 {
      let frame = try SyntheticFrame.random(.v210, width: 120, height: 68, seed: UInt64(40 + i)).frame(gpu, signal: .rec709)
      let feed = gpu.engine.makeFeed()
      feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: UInt64(i)))
      let vp = MonitorViewport(x: (i % 2) * 96, y: (i / 2) * 54, width: i == 3 ? 48 : 96, height: i == 3 ? 27 : 54)
      out.append((frame, feed, gpu.engine.makePass(), i % 2 == 0 ? tools : MonitorState(), vp))
    }
    return out
  }

  /// Every surface in one render pass draws the pixels of one render pass per surface.
  func testMultiviewMatchesOnePassPerSurface() throws {
    let gpu = try requireGPU()
    let surfaces = try Self.surfaces(gpu)
    let chained = gpu.target(192, 108), shared = gpu.target(192, 108)
    try gpu.run { cb in
      for (i, s) in surfaces.enumerated() {
        try s.2.encode(frame: s.0, feed: s.1, state: s.3, target: chained, viewport: s.4, clear: i == 0, into: cb)
      }
    }
    let multiview = MonitorMultiview()
    var escaped: MonitorMultiview.Canvas?
    try gpu.run { cb in
      try multiview.encode(target: shared, into: cb) { canvas in
        var i = 0
        while i < surfaces.count {
          let s = surfaces[i]
          try canvas.draw(s.2, frame: s.0, feed: s.1, state: s.3, viewport: s.4)
          i += 1
        }
        escaped = canvas
      }
    }
    XCTAssertEqual(rawBytes(shared), rawBytes(chained))
    let s = surfaces[0]
    XCTAssertThrowsError(try escaped?.draw(s.2, frame: s.0, feed: s.1, state: s.3), "a canvas draws only inside its encode")
    try gpu.run { cb in
      try multiview.encode(target: shared, into: cb) { canvas in
        XCTAssertThrowsError(
          try canvas.draw(s.2, frame: s.0, feed: s.1, state: s.3, viewport: MonitorViewport(x: 100, y: 0, width: 96, height: 54)))
        XCTAssertThrowsError(try multiview.encode(target: shared, into: cb) { _ in }, "no nested render pass")
      }
    }
  }

  func testMultiviewMatchesOnePassPerSurfaceOnMetal4() throws {
    let m = try requireMTL4()
    let surfaces = try Self.surfaces(m.gpu)
    for s in surfaces { m.resident(s.0) }
    let chained = m.target(192, 108), shared = m.target(192, 108), loaded = m.target(192, 108)
    try m.run { sub in
      for (i, s) in surfaces.enumerated() {
        try s.2.encode(frame: s.0, feed: s.1, state: s.3, target: chained, viewport: s.4, clear: i == 0, into: sub)
      }
    }
    let multiview = MonitorMultiview()
    try m.run { sub in
      try multiview.encode(target: shared, into: sub) { canvas in
        for s in surfaces { try canvas.draw(s.2, frame: s.0, feed: s.1, state: s.3, viewport: s.4) }
      }
    }
    XCTAssertEqual(rawBytes(shared), rawBytes(chained))
    // Loading: the first surface alone, then the rest drawn over it in a second pass.
    try m.run { sub in
      let s = surfaces[0]
      try s.2.encode(frame: s.0, feed: s.1, state: s.3, target: loaded, viewport: s.4, into: sub)
      try multiview.encode(target: loaded, clear: false, into: sub) { canvas in
        for s in surfaces.dropFirst() { try canvas.draw(s.2, frame: s.0, feed: s.1, state: s.3, viewport: s.4) }
      }
    }
    XCTAssertEqual(rawBytes(loaded), rawBytes(chained))
  }

  /// A steady-state multiview frame allocates nothing beyond the Metal calls a
  /// host makes for the same surfaces in its own render pass.
  func testMultiviewSteadyStateAllocatesNothingOfItsOwn() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    let surfaces = try Self.surfaces(gpu)
    let target = gpu.target(192, 108)
    let multiview = MonitorMultiview()
    let host = MTLRenderPassDescriptor()
    host.colorAttachments[0].texture = target
    host.colorAttachments[0].loadAction = .clear
    host.colorAttachments[0].storeAction = .store
    func draw(_ canvas: MonitorMultiview.Canvas) throws {
      var i = 0
      while i < surfaces.count {
        let s = surfaces[i]
        try canvas.draw(s.2, frame: s.0, feed: s.1, state: s.3, viewport: s.4)
        i += 1
      }
    }
    for _ in 0..<3 { try gpu.run { cb in try multiview.encode(target: target, into: cb, draw) } }
    var library: [Int] = [], inline: [Int] = []
    for _ in 0..<10 {
      let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
      cb.makeRenderCommandEncoder(descriptor: host)!.endEncoding()
      guard let a = try AllocationCounter.measure({ try multiview.encode(target: target, into: cb, draw) }) else {
        throw XCTSkip("malloc_logger is unavailable")
      }
      let b = try AllocationCounter.measure {
        let e = cb.makeRenderCommandEncoder(descriptor: host)!
        var i = 0
        while i < surfaces.count {
          let s = surfaces[i]
          try s.2.prepare(frame: s.0, feed: s.1, state: s.3, viewport: s.4, targetPixelFormat: .rgba32Float, into: cb)
          try s.2.draw(with: e)
          i += 1
        }
        e.endEncoding()
      }!
      cb.commit()
      library.append(a)
      inline.append(b)
    }
    gpu.run { _ in }
    let a = library.sorted()[library.count / 2], b = inline.sorted()[inline.count / 2]
    print("BENCH heap allocations per 4-surface multiview: \(a); the same calls in a host pass: \(b)")
    XCTAssertLessThanOrEqual(a, b)
  }
}
