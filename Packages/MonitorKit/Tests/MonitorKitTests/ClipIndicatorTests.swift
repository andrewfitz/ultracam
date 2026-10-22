import Metal
import XCTest

@testable import MonitorKit

/// Clip indicators on the GPU against `ClipIndicatorSettings.indicator` (Core).
final class ClipIndicatorTests: XCTestCase {
  func clipState(_ configure: (inout ClipIndicatorSettings) -> Void = { _ in }) -> MonitorState {
    var s = MonitorState()
    s.clipIndicators.enabled = true
    configure(&s.clipIndicators)
    return s
  }

  /// 10-bit legal: 940 is 100% and flagged (inclusive), 939 is not; 64 is 0% and
  /// flagged under, 65 is not. Every code against the CPU reference.
  func testBoundariesAtEveryCode() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 1) { x, _ in x }
    let frame = try picture.frame(gpu, signal: .rec709)
    let decoded = gpu.decode(frame)
    let state = clipState()
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass)
    XCTAssertTrue(pass.status.isActive(.clipIndicators))
    for x in 0..<1024 {
      let d = decoded[x]
      let flag = state.clipIndicators.indicator(
        rgb: ColorRGB(r: Double(d.x), g: Double(d.y), b: Double(d.z)), luma: Double(d.w))
      let expected = flag.map { SIMD3<Float>($0) } ?? PictureTests.clamped(d)
      XCTAssertEqual(out.rgb(x, 0), expected, "code \(x)")
    }
    XCTAssertEqual(out.rgb(940, 0), SIMD3(1, 1, 1), "all three channels over: white")
    XCTAssertEqual(out.rgb(939, 0), PictureTests.clamped(decoded[939]))
    XCTAssertEqual(out.rgb(64, 0), SIMD3(repeating: 0.5), "all three under: grey")
    XCTAssertEqual(out.rgb(65, 0), PictureTests.clamped(decoded[65]))
  }

  /// Per-channel colours add; luma alone is white; uniform colours; opacity mixes;
  /// thresholds move; disabled channels and directions do not flag.
  func testChannelsColoursAndOpacityMatchTheCPUReference() throws {
    let gpu = try requireGPU()
    var picture = SyntheticFrame(layout: .rgba32Float, width: 12, height: 1)
    picture.rgb = [
      SIMD3(1, 0.5, 0.5), SIMD3(1, 1, 0.5), SIMD3(0.5, 1, 0.5), SIMD3(0.5, 0.5, 1), SIMD3(1, 1, 1),
      SIMD3(0, 0.5, 0.5), SIMD3(0, 0, 0), SIMD3(1, 0, 0.5), SIMD3(0.97, 0.97, 0.97), SIMD3(0.02, 0.5, 0.5),
      SIMD3(1.1, 0.2, 0.2), SIMD3(0.5, 0.5, 0.5),
    ]
    let frame = try picture.frame(gpu, signal: SignalDescription(range: .full))
    let decoded = gpu.decode(frame)
    let configurations: [(String, (inout ClipIndicatorSettings) -> Void)] = [
      ("default", { _ in }),
      ("luma only", { $0.red = false; $0.green = false; $0.blue = false }),
      ("uniform", { $0.coloring = .uniform; $0.overColor = ColorRGB(r: 1, g: 0, b: 1); $0.underColor = ColorRGB(r: 0, g: 1, b: 1) }),
      ("half opacity", { $0.opacity = 0.5 }),
      ("thresholds 95/5", { $0.high = 95; $0.low = 5 }),
      ("over only, red and blue", { $0.showsUnder = false; $0.green = false; $0.luma = false }),
      ("under only", { $0.showsOver = false }),
    ]
    for (name, configure) in configurations {
      let state = clipState(configure)
      let out = try gpu.render(frame, state: state)
      for x in 0..<picture.width {
        let d = decoded[x]
        let base = PictureTests.clamped(d)
        let c = state.clipIndicators
        var expected = base
        if let flag = c.indicator(rgb: ColorRGB(r: Double(d.x), g: Double(d.y), b: Double(d.z)), luma: Double(d.w)) {
          expected = base + (SIMD3<Float>(flag) - base) * Float(c.opacity)
        }
        XCTAssertEqual(out.rgb(x, 0).x, expected.x, accuracy: 1e-6, "\(name) \(x)")
        XCTAssertEqual(out.rgb(x, 0).y, expected.y, accuracy: 1e-6, "\(name) \(x)")
        XCTAssertEqual(out.rgb(x, 0).z, expected.z, accuracy: 1e-6, "\(name) \(x)")
      }
    }
    // Spot checks of the colour rules.
    let out = try gpu.render(frame, state: clipState())
    XCTAssertEqual(out.rgb(0, 0), SIMD3(1, 0, 0), "red over")
    XCTAssertEqual(out.rgb(1, 0), SIMD3(1, 1, 0), "red and green over: yellow")
    XCTAssertEqual(out.rgb(5, 0), SIMD3(0.5, 0, 0), "red under: half red")
    XCTAssertEqual(out.rgb(7, 0), SIMD3(1, 0, 0), "over wins over under")
  }

  /// The stage is the one measured: a LUT that maps everything to white flags the
  /// output stage, not the source.
  func testStageFollowsTheLUTs() throws {
    let gpu = try requireGPU()
    let n = 2
    let text = "LUT_3D_SIZE \(n)\n" + String(repeating: "1 1 1\n", count: n * n * n)
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try CubeLUT(text: text))
    let picture = SyntheticFrame.neutral(.v210, width: 32, height: 1) { x, _ in 400 + x }
    let frame = try picture.frame(gpu, signal: .rec709)
    for (stage, flagged) in [(SignalStage.source, false), (.output, true), (.monitor, true)] {
      var state = clipState { $0.stage = stage; $0.coloring = .uniform; $0.overColor = ColorRGB(r: 0, g: 1, b: 0) }
      state.monitorLUT = false
      let out = try gpu.render(frame, state: state, feed: feed)
      // The picture is the LUT result (white) everywhere; flagged pixels are green.
      XCTAssertEqual(out.rgb(5, 0), flagged ? SIMD3(0, 1, 0) : SIMD3(1, 1, 1), "\(stage)")
    }
  }

  /// A clean surface draws no indicators and says why; the pipeline drops the tool when off.
  func testCleanFeedAndPipelineTier() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 12, height: 1) { _, _ in 940 }
    let frame = try picture.frame(gpu, signal: .rec709)
    var state = clipState { $0.coloring = .uniform; $0.overColor = ColorRGB(r: 0, g: 0, b: 1) }
    let pass = gpu.engine.makePass()
    XCTAssertEqual(try gpu.render(frame, state: state, pass: pass).rgb(0, 0), SIMD3(0, 0, 1))
    XCTAssertEqual(pass.status.active.first { $0.tool == .clipIndicators }?.label, "Clip ≥ 100% ≤ 0%")
    state.clean = true
    XCTAssertEqual(try gpu.render(frame, state: state, pass: pass).rgb(0, 0), SIMD3(1, 1, 1))
    XCTAssertEqual(pass.status.reason(for: .clipIndicators), .cleanFeed)
    let off = MonitorPass.variant(pass.currentParameters, state: state, layout: try XCTUnwrap(pass.layout))
    XCTAssertFalse(off.clip)
    state.clean = false
    _ = try gpu.render(frame, state: state, pass: pass)
    XCTAssertTrue(MonitorPass.variant(pass.currentParameters, state: state, layout: try XCTUnwrap(pass.layout)).clip)
    // Colour and opacity changes are uniforms: the status is not rebuilt.
    let statusBuilds = pass.statusRebuildCount
    state.clipIndicators.opacity = 0.3
    state.clipIndicators.overColor = ColorRGB(r: 1, g: 0, b: 0)
    _ = try gpu.render(frame, state: state, pass: pass)
    XCTAssertEqual(pass.statusRebuildCount, statusBuilds)
  }
}
