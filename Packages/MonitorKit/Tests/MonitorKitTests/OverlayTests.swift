import Metal
import XCTest
import simd

@testable import MonitorKit

/// Zebras, focus peaking and guides on the GPU against their CPU definitions.
final class ZebraTests: XCTestCase {
  func sweep(_ state: MonitorState, feed: MonitorFeed? = nil, viewport: MonitorViewport? = nil) throws -> Pixels {
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.neutral(.v210, width: 1024, height: 40) { x, _ in x }.frame(gpu, signal: .rec709)
    return try gpu.render(frame, state: state, feed: feed, viewport: viewport)
  }

  func testBothSetsLowerLimitAndBandWithDistinctStripes() throws {
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 100, opacity: 0.7, stage: .source)
    state.zebras[1] = ZebraSet(mode: .band, level: 50, range: 25, opacity: 0.5, stage: .source)
    let out = try sweep(state)
    let zebras = state.normalized().zebras
    for y in 0..<40 {
      for code in 0..<1024 {
        let ire = (Double(code) - 64) / 876 * 100
        var c = SIMD3<Double>(repeating: min(1, max(0, ire / 100)))
        // Set 1: light stripes along x + y; set 2: dark stripes along x - y.
        if zebras[0].covers(ire: ire) && (code + y) % 16 < 8 { c += (SIMD3(repeating: 1) - c) * 0.7 }
        if zebras[1].covers(ire: ire) && (code + 16 - y % 16) % 16 < 8 { c += (SIMD3(repeating: 0.12) - c) * 0.5 }
        XCTAssertEqual(out.rgb(code, y), SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)), accuracy: 1e-5, "code \(code) row \(y)")
      }
    }
    // Exact edges at integral codes: 100 IRE is code 940; set 2 is [25, 75) IRE, codes 283 and 721.
    XCTAssertTrue(zebras[0].covers(ire: 100))
    XCTAssertFalse(zebras[0].covers(ire: 875.0 / 8.76))
    XCTAssertTrue(zebras[1].covers(ire: 25))
    XCTAssertFalse(zebras[1].covers(ire: 75))
    // Row 9 puts codes 283 and 721 on set 2 stripes, row 4 code 940 on a set 1 stripe.
    XCTAssertEqual(out.rgb(283, 9).x, 0.25 + (0.12 - 0.25) * 0.5, accuracy: 1e-6)
    XCTAssertEqual(out.rgb(282, 9).x, 218.0 / 876, accuracy: 1e-6)
    XCTAssertEqual(out.rgb(721, 9).x, 0.75, accuracy: 1e-6)
    XCTAssertEqual(out.rgb(720, 9).x, Float(656.0 / 876 + (0.12 - 656.0 / 876) * 0.5), accuracy: 1e-6)
  }

  func testStripesScaleWithPixelsPerPoint() throws {
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 0, opacity: 1, stage: .source)
    let out = try sweep(state, viewport: MonitorViewport(width: 1024, height: 40, pixelsPerPoint: 2))
    for x in 100..<164 { XCTAssertEqual(out.rgb(x, 0) == SIMD3(repeating: 1), x % 32 < 16, "column \(x)") }
  }

  func testStagesMeasureTheirOwnSignal() throws {
    let gpu = try requireGPU()
    // A burn-in LUT that halves everything: the output stage reads half the IRE.
    var text = "LUT_3D_SIZE 2\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(Float(r) / 2) \(Float(g) / 2) \(Float(b) / 2)\n" } } }
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try CubeLUT(text: text))
    for stage in SignalStage.allCases {
      var state = MonitorState()
      state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 40, opacity: 1, stage: stage)
      let out = try sweep(state, feed: feed)
      for code in stride(from: 64, to: 1000, by: 16) {
        let ire = (Double(code) - 64) / 876 * 100
        let measured = stage == .source ? ire : ire / 2
        if abs(measured - 40) < 0.1 { continue }
        XCTAssertEqual(out.rgb(code, 0) == SIMD3(repeating: 1), measured >= 40, "\(stage) code \(code)")
      }
    }
  }

  func testCleanAndDisabledSetsDrawNothing() throws {
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 0, opacity: 1, stage: .source)
    state.clean = true
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.neutral(.v210, width: 64, height: 8) { _, _ in 500 }.frame(gpu, signal: .rec709)
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass)
    XCTAssertEqual(pass.status.reason(for: .zebra1), .cleanFeed)
    XCTAssertEqual(out.values, try gpu.render(frame, state: MonitorState()).values)
  }
}

final class FocusTests: XCTestCase {
  /// A vertical step, a horizontal step, low-level noise and isolated hot pixels.
  static func scene(width: Int = 96, height: Int = 48) -> SyntheticFrame {
    var rng = SeededRandom(5)
    var f = SyntheticFrame.neutral(.v210, width: width, height: height) { x, y in
      (x < width / 2 ? 300 : 700) + (y >= height / 2 && x >= width / 2 ? 250 : 0)
    }
    f.y = f.y.map { $0 + Int.random(in: -3...3, using: &rng) }
    for (x, y) in [(10, 10), (20, 30), (70, 10)] where x < width && y < height { f.y[y * width + x] = 1000 }
    return f
  }

  /// The detector in Double: 3-10-3 gradients, a directional median for support.
  /// `stage` maps the source luma to the luma edges are measured on.
  static func reference(
    _ f: SyntheticFrame, threshold: Double, noise: Double, stage: (Double) -> Double = { $0 }
  ) -> [Double] {
    func l(_ x: Int, _ y: Int) -> Double {
      stage((Double(f.y[min(f.height - 1, max(0, y)) * f.width + min(f.width - 1, max(0, x))]) - 64) / 876)
    }
    func median(_ a: Double, _ b: Double, _ c: Double) -> Double { max(min(a, b), min(max(a, b), c)) }
    var out: [Double] = []
    for y in 0..<f.height {
      for x in 0..<f.width {
        let dx = [l(x + 1, y - 1) - l(x - 1, y - 1), l(x + 1, y) - l(x - 1, y), l(x + 1, y + 1) - l(x - 1, y + 1)]
        let dy = [l(x - 1, y + 1) - l(x - 1, y - 1), l(x, y + 1) - l(x, y - 1), l(x + 1, y + 1) - l(x + 1, y - 1)]
        let gx = (3 * dx[0] + 10 * dx[1] + 3 * dx[2]) / 16, gy = (3 * dy[0] + 10 * dy[1] + 3 * dy[2]) / 16
        let support = max(abs(median(dx[0], dx[1], dx[2])), abs(median(dy[0], dy[1], dy[2])))
        out.append(support > noise ? min(1, max(0, (max(abs(gx), abs(gy)) - threshold) / max(1e-4, threshold * 0.5))) : 0)
      }
    }
    return out
  }

  func testMaskMatchesTheReferenceAndRejectsNoise() throws {
    let gpu = try requireGPU()
    let scene = Self.scene()
    let frame = try scene.frame(gpu, signal: .rec709)
    for sensitivity in [0.0, 0.5, 1.0] {
      var focus = FocusSettings()
      focus.enabled = true
      focus.sensitivity = sensitivity
      let feed = gpu.engine.makeFeed()
      try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
      XCTAssertEqual(feed.focusMask?.pixelFormat, .r8Unorm)
      XCTAssertTrue(feed.hasFocusMask(for: frame))
      let mask = gpu.readMask(feed)
      let expected = Self.reference(scene, threshold: focus.edgeThreshold, noise: focus.noiseRejection)
      for i in 0..<mask.count { XCTAssertEqual(Double(mask[i]), expected[i], accuracy: 0.5 / 255 + 1e-4, "\(sensitivity) at \(i)") }
      // Edges are found, flat noisy areas and hot pixels are not.
      for (x, y) in [(10, 10), (11, 10), (20, 30), (30, 40), (80, 5)] { XCTAssertEqual(mask[y * 96 + x], 0, "\(x),\(y)") }
      guard sensitivity >= 0.5 else { continue }
      XCTAssertEqual(mask[10 * 96 + 47], 1)
      XCTAssertEqual(mask[10 * 96 + 48], 1)
      XCTAssertEqual(mask[24 * 96 + 70], 1)
    }
  }

  func testTailGroupsAndOddSizesAreCorrect() throws {
    let gpu = try requireGPU()
    let scene = Self.scene(width: 37, height: 21)
    var focus = FocusSettings()
    focus.enabled = true
    let feed = gpu.engine.makeFeed()
    let frame = try scene.frame(gpu, signal: .rec709)
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    let mask = gpu.readMask(feed)
    let expected = Self.reference(scene, threshold: focus.edgeThreshold, noise: focus.noiseRejection)
    for i in 0..<mask.count { XCTAssertEqual(Double(mask[i]), expected[i], accuracy: 0.5 / 255 + 1e-4, "at \(i)") }
  }

  func testPeakingStylesColoursAndFootprint() throws {
    let gpu = try requireGPU()
    let scene = Self.scene()
    let frame = try scene.frame(gpu, signal: .rec709)
    for color in PeakingColor.allCases {
      for style in PeakingStyle.allCases {
        var state = MonitorState()
        state.focus.enabled = true
        state.focus.color = color
        state.focus.style = style
        state.focus.opacity = 1
        let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
        let out = try gpu.render(frame, state: state, feed: feed, pass: pass, analyze: true)
        XCTAssertTrue(pass.status.isActive(.focusPeaking))
        let edge = style == .coloredEdges ? SIMD3<Float>(color.rgb) : SIMD3(repeating: 1)
        XCTAssertEqual(out.rgb(47, 10), edge, "\(color) \(style)")
        XCTAssertEqual(out.rgb(48, 10), edge)
        XCTAssertNotEqual(out.rgb(30, 10), edge)
      }
    }
    // 2:1 minification: each display pixel takes the max over its own 2 × 2 picture pixels.
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.opacity = 1
    let out = try gpu.render(frame, state: state, width: 48, height: 24, analyze: true)
    XCTAssertEqual(out.rgb(23, 5), SIMD3(1, 0, 0))
    XCTAssertEqual(out.rgb(24, 5), SIMD3(1, 0, 0))
    XCTAssertNotEqual(out.rgb(22, 5), SIMD3(1, 0, 0))
    XCTAssertNotEqual(out.rgb(25, 5), SIMD3(1, 0, 0))
  }

  /// Minified peaking shows the strongest edge under each display pixel: the max
  /// of the mask over the texels its footprint touches (gathers on the GPU).
  func testPeakingFootprintIsTheMaxOverTheCoveredTexels() throws {
    let gpu = try requireGPU()
    let scene = Self.scene(width: 96, height: 48)
    let frame = try scene.frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.opacity = 1
    state.focus.sensitivity = 0.8
    try gpu.run { try feed.analyze(frame, focus: state.focus, into: $0) }
    let mask = gpu.readMask(feed)
    // 2× (one gather), 2.4×, 3×, 4× (four), 6× (the gather loop), an anisotropic
    // de-squeezed footprint (one texel wide in x) and a subsampled one.
    for (w, h, desqueeze) in [(48, 24, 1.0), (40, 20, 1.0), (32, 16, 1.0), (24, 12, 1.0), (16, 8, 1.0), (96, 12, 4.0), (11, 9, 1.0)] {
      var s = state
      s.geometry.desqueeze = desqueeze
      var plain = s
      plain.focus.enabled = false
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: s, feed: feed, pass: pass, width: w, height: h)
      let base = try gpu.render(frame, state: plain, feed: feed, width: w, height: h)
      let layout = try XCTUnwrap(pass.layout), m = layout.displayToPicture
      for y in 0..<h {
        for x in 0..<w {
          let r = layout.imageRect
          guard Double(x) >= r.x, Double(x) < r.maxX, Double(y) >= r.y, Double(y) < r.maxY else { continue }
          let a = m.apply(x: Double(x), y: Double(y)), b = m.apply(x: Double(x + 1), y: Double(y + 1))
          let x0 = Int(min(a.x, b.x).rounded(.down)), x1 = Int(max(a.x, b.x).rounded(.up))
          let y0 = Int(min(a.y, b.y).rounded(.down)), y1 = Int(max(a.y, b.y).rounded(.up))
          var k: Float = 0
          for ty in y0..<max(y1, y0 + 1) {
            for tx in x0..<max(x1, x0 + 1) { k = max(k, mask[min(47, max(0, ty)) * 96 + min(95, max(0, tx))]) }
          }
          let c = base.rgb(x, y)
          let expected = c + (SIMD3(1, 0, 0) - c) * k
          XCTAssertEqual(out.rgb(x, y), expected, accuracy: 1e-5, "\(w)×\(h) de-squeeze \(desqueeze) at \(x),\(y)")
        }
      }
    }
  }

  func testPeakingNeedsAMaskForThisFrame() throws {
    let gpu = try requireGPU()
    let frame = try Self.scene().frame(gpu, signal: .rec709)
    let other = try Self.scene().frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.opacity = 1
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let plain = try gpu.render(frame, state: MonitorState())
    XCTAssertEqual(try gpu.render(frame, state: state, feed: feed, pass: pass).values, plain.values)
    XCTAssertEqual(pass.status.reason(for: .focusPeaking), .focusNotAnalyzed)
    try gpu.run { try feed.analyze(other, focus: state.focus, into: $0) }
    XCTAssertFalse(feed.hasFocusMask(for: frame), "analysed a different frame")
    XCTAssertEqual(try gpu.render(frame, state: state, feed: feed, pass: pass).values, plain.values)
    // Disabled focus is a no-op: no mask is made.
    let idle = gpu.engine.makeFeed()
    try gpu.run { try idle.analyze(frame, focus: FocusSettings(), into: $0) }
    XCTAssertNil(idle.focusMask)
    XCTAssertEqual(idle.persistentMemoryBytes, 0)
  }

  /// A host that hands in the same texture every frame (its own render target, a
  /// one-buffer ring) gets no stale peaking: validity follows `MonitorFrame.id`.
  func testReusedTexturesNeedAnAnalysisPerFrame() throws {
    let gpu = try requireGPU()
    let scene = Self.scene()
    let first = try scene.frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.opacity = 1
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    try gpu.run { try feed.analyze(first, focus: state.focus, into: $0) }
    XCTAssertTrue(feed.hasFocusMask(for: first))
    _ = try gpu.render(first, state: state, feed: feed, pass: pass)
    XCTAssertTrue(pass.status.isActive(.focusPeaking))
    // The next frame wraps the same texture: a new frame, so the mask is stale.
    let next = try MonitorFrame(layout: first.layout, width: first.width, height: first.height, packed: first.packed, signal: .rec709)
    XCTAssertTrue(next.packed === first.packed)
    XCTAssertFalse(feed.hasFocusMask(for: next))
    let plain = try gpu.render(next, state: MonitorState())
    XCTAssertEqual(try gpu.render(next, state: state, feed: feed, pass: pass).values, plain.values)
    XCTAssertEqual(pass.status.reason(for: .focusPeaking), .focusNotAnalyzed)
    // A host reusing one MonitorFrame value sets a new id per picture.
    var reused = first
    reused.id = 12345
    XCTAssertFalse(feed.hasFocusMask(for: reused))
    // Turning focus off at the feed marks the mask stale too.
    try gpu.run { try feed.analyze(first, focus: state.focus, into: $0) }
    XCTAssertTrue(feed.hasFocusMask(for: first))
    try gpu.run { try feed.analyze(first, focus: FocusSettings(), into: $0) }
    XCTAssertFalse(feed.hasFocusMask(for: first))
  }

  /// Peaking on the output or monitor stage measures the luma after the feed's
  /// LUTs, so a contrast-changing look changes which edges peak.
  func testPeakingOnALUTStageMeasuresTheLUTResult() throws {
    let gpu = try requireGPU()
    let scene = Self.scene()
    let frame = try scene.frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try FalseColorTests.halvingLUT())
    feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try FalseColorTests.halvingLUT())
    for stage in SignalStage.allCases {
      var focus = FocusSettings()
      focus.enabled = true
      focus.sensitivity = 0.9
      focus.stage = stage
      try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
      let mask = gpu.readMask(feed)
      let gain = stage == .source ? 1.0 : (stage == .output ? 0.5 : 0.25)
      // The LUT clamps its input to its domain before halving.
      let expected = Self.reference(scene, threshold: focus.edgeThreshold, noise: focus.noiseRejection) {
        stage == .source ? $0 : min(1, max(0, $0)) * gain
      }
      for i in 0..<mask.count { XCTAssertEqual(Double(mask[i]), expected[i], accuracy: 0.5 / 255 + 1e-4, "\(stage) at \(i)") }
      // A surface peaks only with a mask of its own stage.
      for surfaceStage in SignalStage.allCases {
        var state = MonitorState()
        state.focus = focus
        state.focus.stage = surfaceStage
        let pass = gpu.engine.makePass()
        _ = try gpu.render(frame, state: state, feed: feed, pass: pass)
        XCTAssertEqual(pass.status.isActive(.focusPeaking), surfaceStage == stage, "\(stage) mask, \(surfaceStage) surface")
        if surfaceStage == stage && stage == .output {
          XCTAssertTrue(pass.status.activeLabels.contains("Peaking · output"))
        }
      }
    }
    // The halved output has weaker edges: fewer of them pass the threshold.
    var focus = FocusSettings()
    focus.enabled = true
    focus.sensitivity = 0.9
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    let source = gpu.readMask(feed).reduce(0, +)
    focus.stage = .monitor
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertLessThan(gpu.readMask(feed).reduce(0, +), source)
  }

  func testPrepareWarmsTheFocusPipelines() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device)
    XCTAssertEqual(engine.focusPipelineCount, 0)
    try engine.prepare(pixelFormat: .bgra8Unorm, layouts: [.v210, .p010])
    XCTAssertEqual(engine.focusPipelineCount, 6, "source, output and monitor stage, per layout")
    let feed = engine.makeFeed()
    var focus = FocusSettings()
    focus.enabled = true
    try gpu.run { try feed.analyze(try Self.scene().frame(gpu, signal: .rec709), focus: focus, into: $0) }
    XCTAssertEqual(engine.focusPipelineCount, 6, "analysis built nothing on the frame path")
  }

  /// A mask replaced on a size change stays referenced for a few frames, so a
  /// command buffer without retained references never reads freed memory.
  func testReplacedMasksOutliveTheFramesInFlight() throws {
    let gpu = try requireGPU()
    var focus = FocusSettings()
    focus.enabled = true
    let feed = gpu.engine.makeFeed()
    try gpu.run { try feed.analyze(try Self.scene().frame(gpu, signal: .rec709), focus: focus, into: $0) }
    XCTAssertEqual(feed.retiredMaskCount, 0)
    let small = try Self.scene(width: 50, height: 20).frame(gpu, signal: .rec709)
    try gpu.run { try feed.analyze(small, focus: focus, into: $0) }
    XCTAssertEqual(feed.retiredMaskCount, 1)
    for _ in 0..<MonitorFeed.retiredFrames { try gpu.run { try feed.analyze(small, focus: focus, into: $0) } }
    XCTAssertEqual(feed.retiredMaskCount, 0)
  }

  func testMaskIsReusedAndRecreatedOnlyOnSizeChange() throws {
    let gpu = try requireGPU()
    var focus = FocusSettings()
    focus.enabled = true
    let feed = gpu.engine.makeFeed()
    let a = try Self.scene().frame(gpu, signal: .rec709)
    try gpu.run { try feed.analyze(a, focus: focus, into: $0) }
    let first = try XCTUnwrap(feed.focusMask)
    let created = gpu.engine.resourcesCreated
    for _ in 0..<5 { try gpu.run { try feed.analyze(try Self.scene().frame(gpu, signal: .rec709), focus: focus, into: $0) } }
    XCTAssertTrue(feed.focusMask === first)
    XCTAssertEqual(gpu.engine.resourcesCreated, created)
    XCTAssertGreaterThanOrEqual(feed.persistentMemoryBytes, 96 * 48)
    try gpu.run { try feed.analyze(try Self.scene(width: 50, height: 20).frame(gpu, signal: .rec709), focus: focus, into: $0) }
    XCTAssertFalse(feed.focusMask === first)
    XCTAssertEqual(gpu.engine.resourcesCreated, created + 1)
  }
}

final class GuideTests: XCTestCase {
  func render(_ guides: GuideSettings, code: Int = 64, width: Int = 960, height: Int = 540, ppp: Double = 1,
              state configure: (inout MonitorState) -> Void = { _ in }) throws -> (Pixels, MonitorPass) {
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.neutral(.v210, width: width, height: height) { _, _ in code }.frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.guides = guides
    configure(&state)
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass, viewport: MonitorViewport(width: width, height: height, pixelsPerPoint: ppp))
    return (out, pass)
  }

  static func plain() -> GuideSettings {
    var g = GuideSettings()
    g.enabled = true
    g.thirds = false
    g.opacity = 1
    g.contrast = 0
    return g
  }

  func testThirdsArePixelExactAtOddAndEvenStrokes() throws {
    var g = Self.plain()
    g.thirds = true
    let (one, pass) = try render(g)
    XCTAssertTrue(pass.status.isActive(.guides))
    for x in [319, 320, 321, 639, 640, 641] { XCTAssertEqual(one.rgb(x, 100), x == 320 || x == 640 ? SIMD3(repeating: 1) : .zero, "column \(x)") }
    for y in [179, 180, 181, 359, 360, 361] { XCTAssertEqual(one.rgb(100, y), y == 180 || y == 360 ? SIMD3(repeating: 1) : .zero, "row \(y)") }
    // Two pixels per point: a 2-pixel stroke centred on the pixel edge.
    let (two, _) = try render(g, ppp: 2)
    for x in [318, 319, 320, 321] { XCTAssertEqual(two.rgb(x, 100), x == 319 || x == 320 ? SIMD3(repeating: 1) : .zero, "2× column \(x)") }
  }

  func testOutlineContrastAndOpacity() throws {
    var g = Self.plain()
    g.thirds = true
    g.contrast = 1
    g.opacity = 0.5
    g.color = ColorRGB(r: 1, g: 0, b: 0)
    let (out, _) = try render(g, code: 940)
    // The line: half red over the half-darkened white.
    XCTAssertEqual(out.rgb(320, 100), SIMD3(0.75, 0.25, 0.25), accuracy: 1e-5)
    // The one-pixel dark outline beside it.
    XCTAssertEqual(out.rgb(319, 100), SIMD3(repeating: 0.5), accuracy: 1e-5)
    XCTAssertEqual(out.rgb(321, 100), SIMD3(repeating: 0.5), accuracy: 1e-5)
    XCTAssertEqual(out.rgb(322, 100), SIMD3(repeating: 1))
  }

  func testFrameGuideMatteSafeAreaCrossAndDot() throws {
    var g = Self.plain()
    g.frameGuides = [FrameGuide(aspect: 2.4, style: .linesAndMatte, matteOpacity: 0.75)]
    g.safeAreas = [90]
    g.centerCross = true
    g.centerDot = true
    let (out, pass) = try render(g, code: 502)
    let layout = try XCTUnwrap(pass.layout)
    let raster = GuideRaster(layout: layout, guides: g, pixelsPerPoint: 1)
    let matte = try XCTUnwrap(raster.matteRect)
    // 2.4:1 inside 960 × 540 is 960 × 400, rows 70..<470.
    XCTAssertEqual(matte.y, 70)
    XCTAssertEqual(matte.height, 400)
    XCTAssertEqual(out.rgb(480, 30), SIMD3(repeating: 0.125), accuracy: 1e-5, "matte darkens outside the guide")
    XCTAssertEqual(out.rgb(480, 70), SIMD3(repeating: 1), "the guide's top line")
    XCTAssertEqual(out.rgb(480, 469), SIMD3(repeating: 1), "the guide's bottom line")
    XCTAssertEqual(out.rgb(300, 300), SIMD3(repeating: 0.5), accuracy: 1e-6, "inside, untouched")
    // The 90% safe area follows the frame guide: 864 × 360 centred, left edge at x = 48.
    XCTAssertEqual(out.rgb(48, 300), SIMD3(repeating: 1))
    XCTAssertEqual(out.rgb(47, 300), SIMD3(repeating: 0.5), accuracy: 1e-6)
    // Centre cross arms and the centre dot.
    XCTAssertEqual(out.rgb(480, 270), SIMD3(repeating: 1))
    XCTAssertEqual(out.rgb(480 + 10, 270), SIMD3(repeating: 1))
    XCTAssertEqual(out.rgb(480, 270 - 10), SIMD3(repeating: 1))
    XCTAssertEqual(out.rgb(480 + 30, 270 + 30), SIMD3(repeating: 0.5), accuracy: 1e-6)
  }

  func testEveryVerticalAndHorizontalSegmentLandsOnItsPixels() throws {
    var g = Self.plain()
    g.thirds = true
    g.squareGrid = true
    g.squareGridRows = 6
    g.safeAreas = [80, 93]
    let (out, pass) = try render(g)
    let raster = GuideRaster(layout: try XCTUnwrap(pass.layout), guides: g, pixelsPerPoint: 1)
    XCTAssertGreaterThan(raster.segments.count, 20)
    for s in raster.segments {
      if s.x0 == s.x1 {
        let column = Int(s.x0.rounded(.down))
        XCTAssertEqual(out.rgb(column, Int((s.y0 + s.y1) / 2)), SIMD3(repeating: 1), "vertical at \(s.x0)")
      } else if s.y0 == s.y1 {
        let row = Int(s.y0.rounded(.down))
        XCTAssertEqual(out.rgb(Int((s.x0 + s.x1) / 2), row), SIMD3(repeating: 1), "horizontal at \(s.y0)")
      }
    }
  }

  func testDiagonalsAreAntialiased() throws {
    var g = Self.plain()
    g.diagonals = true
    let (out, _) = try render(g, width: 400, height: 400)
    // Analytic coverage: float rounding of the distance only, no quantization.
    XCTAssertEqual(out.rgb(200, 200), SIMD3(repeating: 1), accuracy: 1e-4)
    XCTAssertEqual(out.rgb(100, 100), SIMD3(repeating: 1), accuracy: 1e-4)
    XCTAssertEqual(out.rgb(299, 100), SIMD3(repeating: 1), accuracy: 1e-4)
    XCTAssertEqual(out.rgb(100, 299), SIMD3(repeating: 1), accuracy: 1e-4)
    // A pixel whose centre is 1/√2 px off the line: 1 - 0.707 coverage.
    XCTAssertEqual(out.rgb(300, 100).x, 1 - Float(0.5).squareRoot(), accuracy: 1e-4)
    XCTAssertEqual(out.rgb(100, 200), .zero)
  }

  /// Coverage of every guide stroke at pixel centre p in Double: the line and its
  /// outline, butt-ended, max over strokes; a zero-length stroke is a round dot.
  static func coverage(_ raster: GuideRaster, x: Double, y: Double, outline o: Double) -> (line: Double, outline: Double) {
    func c(_ v: Double) -> Double { min(1, max(0, v)) }
    var line = 0.0, out = 0.0
    for s in raster.segments {
      let ax = s.x1 - s.x0, ay = s.y1 - s.y0, length2 = ax * ax + ay * ay
      let hw = Double(Float(s.halfWidth))
      if length2 == 0 {
        let d = ((x - s.x0) * (x - s.x0) + (y - s.y0) * (y - s.y0)).squareRoot()
        line = max(line, c(hw + 0.5 - d))
        out = max(out, c(hw + o + 0.5 - d))
        continue
      }
      let len = length2.squareRoot(), ux = ax / len, uy = ay / len, qx = x - s.x0, qy = y - s.y0
      let along = qx * ux + qy * uy, across = abs(qx * uy - qy * ux), inside = min(along, len - along)
      line = max(line, c(hw + 0.5 - across) * c(inside + 0.5))
      out = max(out, c(hw + o + 0.5 - across) * c(inside + o + 0.5))
    }
    return (line, out)
  }

  /// Every pixel of every guide kind, thin and thick, against the Double reference.
  func testAnalyticGuidesMatchTheReferenceEverywhere() throws {
    for (ppp, width) in [(1.0, 1.0), (2.0, 1.0), (3.0, 1.5), (1.0, 4.0)] {
      var g = GuideTests.plain()
      g.thirds = true
      g.squareGrid = true
      g.squareGridRows = 16
      g.diagonals = true
      g.centerCross = true
      g.centerDot = true
      g.safeAreas = [80, 93]
      g.frameGuides = [FrameGuide(aspect: 2.39, style: .linesAndMatte, matteOpacity: 0.5), FrameGuide(aspect: 1)]
      g.contrast = 1
      g.opacity = 0.7
      g.lineWidth = width
      g.color = ColorRGB(r: 1, g: 0.5, b: 0)
      let (out, pass) = try render(g, code: 502, width: 480, height: 270, ppp: ppp)
      let layout = try XCTUnwrap(pass.layout)
      let raster = GuideRaster(layout: layout, guides: g, pixelsPerPoint: ppp)
      XCTAssertGreaterThan(raster.segments.count, 40)
      let guides = pass.currentGuides
      XCTAssertEqual(Int(guides.counts.x + guides.counts.y + guides.counts.z), raster.segments.count)
      let matte = try XCTUnwrap(raster.matteRect)
      let o = max(1, ppp.rounded())
      var worst = 0.0
      for y in 0..<270 {
        for x in 0..<480 {
          let px = Double(x) + 0.5, py = Double(y) + 0.5
          var v = SIMD3<Double>(repeating: 0.5)
          if !(px >= matte.x && px < matte.maxX && py >= matte.y && py < matte.maxY) { v *= 0.5 }
          let k = Self.coverage(raster, x: px, y: py, outline: o)
          v += (SIMD3(repeating: 0) - v) * (k.outline * 0.7)
          v += (SIMD3(1, 0.5, 0) - v) * (k.line * 0.7)
          let gpu = out.rgb(x, y)
          worst = max(worst, simd_reduce_max(simd_abs(SIMD3(Double(gpu.x), Double(gpu.y), Double(gpu.z)) - v)))
        }
      }
      XCTAssertLessThanOrEqual(worst, 2e-4, "ppp \(ppp) width \(width)")
    }
  }

  func testHiddenWhileMagnifiedAndRebuiltOnlyOnChange() throws {
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.neutral(.v210, width: 320, height: 180) { _, _ in 64 }.frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.guides = Self.plain()
    state.guides.thirds = true
    let pass = gpu.engine.makePass(), feed = gpu.engine.makeFeed()
    let t = gpu.target(320, 180)
    let created = gpu.engine.resourcesCreated
    for _ in 0..<5 { try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: t, into: $0) } }
    XCTAssertEqual(pass.guideBuildCount, 1)
    XCTAssertEqual(pass.currentGuides.counts.x, 2)
    XCTAssertEqual(pass.currentGuides.counts.y, 2)
    XCTAssertEqual(pass.persistentMemoryBytes, 0, "guides are analytic: no texture")
    state.guides.opacity = 0.5  // colour and opacity are uniforms: the strokes stay
    try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: t, into: $0) }
    XCTAssertEqual(pass.guideBuildCount, 1)
    state.guides.centerCross = true
    try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: t, into: $0) }
    XCTAssertEqual(pass.guideBuildCount, 2)
    // A live resize rebuilds the strokes each frame but creates no GPU resource.
    for w in stride(from: 300, to: 200, by: -20) {
      try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: t, viewport: MonitorViewport(width: w, height: 150), into: $0) }
    }
    XCTAssertEqual(gpu.engine.resourcesCreated, created)
    state.geometry.magnification.zoom = 2
    try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: t, into: $0) }
    XCTAssertEqual(pass.status.reason(for: .guides), .hiddenWhileMagnified)
    XCTAssertEqual(pass.currentGuides.counts, .zero)
    XCTAssertEqual(Pixels(t).rgb(160, 60), .zero)
  }
}
