import Metal
import XCTest

@testable import MonitorKit

/// GPU regressions from the W2 picture audit, each against the CPU reference in
/// `MonitorColorPipeline` where there is one.
final class AuditRegressionTests: XCTestCase {
  func floatFrame(_ gpu: TestGPU, _ values: [SIMD3<Double>], signal: SignalDescription) throws -> MonitorFrame {
    var picture = SyntheticFrame(layout: .rgba32Float, width: values.count, height: 1)
    picture.rgb = values.map { SIMD3(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) }
    return try picture.frame(gpu, signal: signal)
  }

  func color(_ v: SIMD3<Double>) -> ColorRGB { ColorRGB(r: v.x, g: v.y, b: v.z) }
  func grey(_ v: Double) -> ColorRGB { ColorRGB(r: v, g: v, b: v) }

  static let ramp: [SIMD3<Double>] = (0...64).map { SIMD3(repeating: Double($0) / 64) }
  static let colours: [SIMD3<Double>] = {
    var v = ramp
    var rng = SeededRandom(23)
    for _ in 0..<48 {
      v.append(SIMD3(Double.random(in: 0...1, using: &rng), Double.random(in: 0...1, using: &rng), Double.random(in: 0...1, using: &rng)))
    }
    return v
  }()

  static let pq = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq))
  static let hlg = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.hlg))

  /// GPU and CPU target values as the light they stand for, or as values on a
  /// layer without a conversion (float32 transcendental error on both).
  func assertSameLight(
    _ gpu: SIMD3<Float>, _ cpu: ColorRGB, _ pipeline: MonitorColorPipeline, _ message: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let g = ColorRGB(r: Double(gpu.x), g: Double(gpu.y), b: Double(gpu.z))
    XCTAssertTrue(g.isFinite, message(), file: file, line: line)
    guard let target = pipeline.target, pipeline.convertsToTarget else {
      for (x, y) in [(g.r, cpu.r), (g.g, cpu.g), (g.b, cpu.b)] {
        XCTAssertEqual(x, y, accuracy: 1e-4 + 1e-4 * abs(y), message(), file: file, line: line)
      }
      return
    }
    let a = pipeline.linear(g, transfer: target.transfer, primaries: target.primaries)
    let b = pipeline.linear(cpu, transfer: target.transfer, primaries: target.primaries)
    for (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)] {
      XCTAssertEqual(x, y, accuracy: 2e-5 + 3e-4 * abs(y), message(), file: file, line: line)
    }
  }

  // MARK: - LUT convention

  /// A burn-in LUT makes every display transform unavailable: the picture is the
  /// LUT's Rec.709 result, exactly as with no transform chosen.
  func testALUTOnTheMonitorStageDisablesEveryTransformOnTheGPU() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 256, height: 2) { x, _ in x * 4 }
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 4))
    for signal in [SignalDescription(encoding: .log(.sLog3SGamut3Cine)), SignalDescription(matrix: .bt2020, encoding: .display(.pq))] {
      let frame = try picture.frame(gpu, signal: signal)
      let plain = try gpu.render(frame, state: MonitorState(), feed: feed)
      for mode in DisplayTransform.allCases where mode != .none {
        for output in [MonitorOutputColor.signalNative, MonitorOutputColor(primaries: .rec2020, encoding: .pq)] {
          var state = MonitorState()
          state.displayTransform.mode = mode
          let pass = gpu.engine.makePass(), reference = gpu.engine.makePass()
          pass.outputColor = output
          reference.outputColor = output
          let out = try gpu.render(frame, state: state, feed: feed, pass: pass)
          XCTAssertEqual(pass.status.reason(for: .displayTransform), .lutOnMonitorStage, "\(mode)")
          XCTAssertFalse(pass.status.isActive(.displayTransform))
          XCTAssertEqual(pass.currentParameters.color.x, 0)
          let none = try gpu.render(frame, state: MonitorState(), feed: feed, pass: reference)
          XCTAssertEqual(out.values, none.values, "\(signal.encoding) \(mode) \(output.encoding)")
          if output == .signalNative { XCTAssertEqual(out.values, plain.values) }
        }
      }
    }
  }

  // MARK: - HLG and identity conversions

  /// HLG into an HLG output of any nominal peak passes through (the identity
  /// pipeline), and graphics white stays 75% HLG.
  func testHLGPassesThroughAnHLGOutputOfAnyPeak() throws {
    let gpu = try requireGPU()
    let frame = try floatFrame(gpu, Self.colours, signal: Self.hlg)
    let native = try gpu.render(frame, state: MonitorState())
    for peak in [600.0, 2000] {
      let pass = gpu.engine.makePass()
      pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: .hlg, hlgNominalPeak: peak)
      let out = try gpu.render(frame, state: MonitorState(), pass: pass)
      XCTAssertEqual(pass.currentParameters.color.z, 0, "no conversion at \(peak)")
      XCTAssertEqual(out.values, native.values, "\(peak)")
      for (i, v) in Self.colours.enumerated() {
        XCTAssertEqual(out.rgb(i, 0), SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)), "\(peak) #\(i)")
      }
      var zebra = MonitorState()
      zebra.zebras[0] = ZebraSet(mode: .lowerLimit, level: 0, stage: .source)
      zebra.zebras[0].opacity = 1
      let z = try gpu.render(frame, state: zebra, pass: pass)
      XCTAssertEqual(Double(z.rgb(0, 0).y), 0.75, accuracy: 2e-3, "graphics white at \(peak)")
      // An SDR picture into the same output: SDR white is 75% HLG too.
      let sdr = try floatFrame(gpu, [SIMD3(repeating: 1)], signal: SignalDescription(range: .full, matrix: .bt2020))
      XCTAssertEqual(Double(try gpu.render(sdr, state: MonitorState(), pass: pass).rgb(0, 0).y), 0.75, accuracy: 2e-3)
    }
  }

  /// An output that is the picture's own encoding builds the native pipeline and
  /// draws the native picture exactly.
  func testIdentityConversionsDrawTheNativePicture() throws {
    let gpu = try requireGPU()
    let cases: [(SignalDescription, MonitorOutputColor, DisplayTransform)] = [
      (Self.pq, MonitorOutputColor(primaries: .rec2020, encoding: .pq), .none),
      (SignalDescription(range: .full), MonitorOutputColor(encoding: .sdr(.bt1886)), .none),
      (SignalDescription(range: .full, encoding: .display(.sRGB)), MonitorOutputColor(encoding: .sdr(.sRGB)), .none),
      (Self.pq, MonitorOutputColor(encoding: .sdr(.bt1886)), .hdrToSDR),
    ]
    for (signal, output, mode) in cases {
      let frame = try floatFrame(gpu, Self.colours, signal: signal)
      var state = MonitorState()
      state.displayTransform.mode = mode
      let pass = gpu.engine.makePass()
      pass.outputColor = output
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertFalse(pass.colorPipeline.convertsToTarget)
      XCTAssertEqual(pass.currentParameters.color.z, 0)
      let native = try gpu.render(frame, state: state)
      XCTAssertEqual(out.values, native.values, "\(signal.encoding) → \(output.encoding)")
    }
  }

  /// PQ above its 0…1 domain (float sources) stops at 10 000 cd/m², never NaN.
  func testPQSuperWhitesAreFiniteOnTheGPU() throws {
    let gpu = try requireGPU()
    let frame = try floatFrame(gpu, [SIMD3(repeating: 2), SIMD3(repeating: 1.09), SIMD3(repeating: 1), SIMD3(2, 0, 0)], signal: Self.pq)
    for encoding in [MonitorOutputColor.Encoding.extendedLinear, .pq, .hlg, .sdr(.bt1886)] {
      let pass = gpu.engine.makePass()
      pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: encoding)
      var state = MonitorState()
      state.falseColor.mode = .custom
      state.falseColor.customUnit = .stops
      state.falseColor.customBands = [FalseColorBand(lower: 100, upper: 200, color: ColorRGB(r: 1, g: 0, b: 0))]
      for s in [MonitorState(), state] {
        let out = try gpu.render(frame, state: s, pass: pass)
        for v in out.values { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite, "\(encoding)") }
        if encoding == .extendedLinear && s == MonitorState() {
          XCTAssertEqual(Double(out.rgb(0, 0).y), 10_000 / 203, accuracy: 0.05)
          XCTAssertEqual(out.rgb(0, 0), out.rgb(1, 0))
        }
      }
    }
  }

  // MARK: - False-colour fallback

  /// Pixels no band covers show the stage's grey through the display transform and
  /// the output conversion, like the picture.
  func testFalseColourFallbackFollowsTheDisplayTransform() throws {
    let gpu = try requireGPU()
    // Custom IRE false colour whose one band covers nothing: every pixel falls back.
    var state = MonitorState()
    state.falseColor.mode = .custom
    state.falseColor.stage = .source
    state.falseColor.customBands = [FalseColorBand(lower: 500, upper: 600, color: ColorRGB(r: 1, g: 0, b: 0))]
    let cases: [(SignalDescription, DisplayTransform, MonitorOutputColor.Encoding)] = [
      (Self.pq, .hdrToSDR, .pq), (Self.pq, .hdrToSDR, .sdr(.bt1886)), (Self.pq, .hdrToSDR, .signalNative),
      (Self.hlg, .hdrToSDR, .extendedLinear), (Self.pq, .hdrPassthrough, .extendedLinear), (Self.pq, .none, .sdr(.bt1886)),
    ]
    for (signal, mode, encoding) in cases {
      let frame = try floatFrame(gpu, Self.ramp, signal: signal)
      state.displayTransform.mode = mode
      let pass = gpu.engine.makePass()
      pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: encoding, headroom: 2)
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertTrue(pass.status.isActive(.falseColor))
      let c = pass.colorPipeline
      for (i, v) in Self.ramp.enumerated() {
        assertSameLight(out.rgb(i, 0), c.present(grey(v.x), headroom: 2), c, "\(signal.encoding) \(mode) \(encoding) #\(i)")
      }
    }
    // Sony false colour with the log transform: unbanded pixels are the transform of
    // the decoded grey (the picture's look), banded ones the band colours.
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 1) { x, _ in x }
    let frame = try picture.frame(gpu, signal: SignalDescription(encoding: .log(.sLog3SGamut3Cine)))
    var sony = MonitorState()
    sony.falseColor.mode = .sonySLog3
    sony.displayTransform.mode = .logToRec709
    for encoding in [MonitorOutputColor.Encoding.signalNative, .pq] {
      let pass = gpu.engine.makePass()
      pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: encoding)
      let out = try gpu.render(frame, state: sony, pass: pass)
      let p = pass.currentParameters
      let bands = (0..<Int(p.modes.z)).map { SIMD3<Float>(p.bandColors[$0].x, p.bandColors[$0].y, p.bandColors[$0].z) }
      var fallbacks = 0
      for x in 4..<1020 {
        let y = min(max(Double(x - 64) / 876, 0), 1)
        let expected = pass.colorPipeline.present(grey(y), range: .legal)
        let got = out.rgb(x, 0)
        if bands.contains(got) { continue }
        fallbacks += 1
        assertSameLight(got, expected, pass.colorPipeline, "Sony \(encoding) code \(x)")
      }
      XCTAssertGreaterThan(fallbacks, 100, "\(encoding): Sony's gaps show the grey")
    }
  }

  // MARK: - White-point trim

  func testWhiteTrimMatchesTheCPUReference() throws {
    let gpu = try requireGPU()
    let signals: [SignalDescription] = [
      SignalDescription(range: .full), SignalDescription(range: .full, encoding: .display(.sRGB)), Self.pq, Self.hlg,
      SignalDescription(range: .full, encoding: .display(.linear), primaries: .displayP3),
    ]
    let encodings: [MonitorOutputColor.Encoding] = [.signalNative, .sdr(.bt1886), .pq, .extendedLinear, .hlg]
    for signal in signals {
      let frame = try floatFrame(gpu, Self.colours, signal: signal)
      for (temperature, tint) in [(5200.0, 0.006), (9300, -0.01)] {
        var state = MonitorState()
        state.display.temperature = temperature
        state.display.tint = tint
        for encoding in encodings {
          let pass = gpu.engine.makePass()
          pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: encoding)
          let out = try gpu.render(frame, state: state, pass: pass)
          let c = pass.colorPipeline
          let gains = WhitePointTrim.gains(state.display, primaries: c.picture.primaries)
          XCTAssertNotEqual(gains, ColorRGB(r: 1, g: 1, b: 1))
          XCTAssertTrue(pass.status.isActive(.displayAdjustments))
          for (i, v) in Self.colours.enumerated() {
            let expected = c.converted(c.whiteTrimmed(color(v), gains: gains))
            assertSameLight(out.rgb(i, 0), expected, c, "\(signal.encoding) \(temperature) \(encoding) #\(i)")
          }
        }
      }
    }
  }

  /// Neutral picture white lands on the trimmed white: on an extended-linear
  /// Rec.709 layer its chromaticity is the trimmed white's.
  func testTrimmedWhiteHasTheTrimmedChromaticity() throws {
    let gpu = try requireGPU()
    let frame = try floatFrame(gpu, [SIMD3(repeating: 1)], signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.display.temperature = 5000
    let pass = gpu.engine.makePass()
    pass.outputColor = MonitorOutputColor(encoding: .extendedLinear)
    let rgb = try gpu.render(frame, state: state, pass: pass).rgb(0, 0)
    let xyz = ColorPrimaries.rec709.toXYZ.apply(ColorRGB(r: Double(rgb.x), g: Double(rgb.y), b: Double(rgb.z)))
    let sum = xyz.r + xyz.g + xyz.b
    let d50ish = WhitePointTrim.daylight(5000), d65 = WhitePointTrim.daylight(6504)
    XCTAssertEqual(xyz.r / sum, 0.3127 + d50ish.x - d65.x, accuracy: 5e-4)
    XCTAssertEqual(xyz.g / sum, 0.3290 + d50ish.y - d65.y, accuracy: 5e-4)
    XCTAssertEqual(Double(max(rgb.x, rgb.y, rgb.z)), 1, accuracy: 1e-5, "no channel above full drive")
  }

  // MARK: - Asynchronous specialization

  /// Changing the output colour, the display transform or the source's encoding
  /// never compiles a pipeline on the encoding thread: the all-tools stand-in reads
  /// colour from the uniforms, and draws what the specialized pipeline draws.
  func testColourChangesNeverCompileOnTheEncodingThread() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    try engine.prepare(target: .init(colorPixelFormat: .rgba32Float), layouts: [.rgba32Float])
    let log = SignalDescription(range: .full, encoding: .log(.sLog3SGamut3Cine))
    let logFrame = try floatFrame(gpu, Self.colours, signal: log)
    let pqFrame = try floatFrame(gpu, Self.colours, signal: Self.pq)
    let pass = engine.makePass(), feed = engine.makeFeed()
    let target = gpu.target(Self.colours.count, 1)
    func draw(_ frame: MonitorFrame, _ state: MonitorState) throws -> (ms: Double, pixels: Pixels) {
      let cb = gpu.queue.makeCommandBuffer()!
      let start = DispatchTime.now().uptimeNanoseconds
      try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
      let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
      cb.commit()
      cb.waitUntilCompleted()
      return (ms, Pixels(target))
    }
    _ = try draw(logFrame, MonitorState())
    let built = engine.pipelinesBuiltOnCaller
    var transform = MonitorState()
    transform.displayTransform.mode = .logToRec709
    var hdr = MonitorState()
    hdr.displayTransform.mode = .hdrToSDR
    let steps: [(String, MonitorFrame, MonitorState, MonitorOutputColor)] = [
      ("log to Rec.709", logFrame, transform, .signalNative),
      ("SDR BT.1886 output", logFrame, transform, MonitorOutputColor(encoding: .sdr(.bt1886))),
      ("PQ output", logFrame, transform, MonitorOutputColor(primaries: .rec2020, encoding: .pq)),
      ("cut to a PQ source", pqFrame, hdr, MonitorOutputColor(primaries: .rec2020, encoding: .pq)),
      ("extended linear", pqFrame, hdr, MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear)),
    ]
    var slowest = 0.0
    for (name, frame, state, output) in steps {
      pass.outputColor = output
      let first = try draw(frame, state)
      slowest = max(slowest, first.ms)
      XCTAssertEqual(engine.pipelinesBuiltOnCaller, built, "\(name) compiled on the encoding thread")
      // Then the specialized pipeline arrives; it draws the same picture.
      let start = Date()
      while !pass.usesSpecializedPipeline && Date().timeIntervalSince(start) < 60 {
        Thread.sleep(forTimeInterval: 0.01)
        _ = try draw(frame, state)
      }
      XCTAssertTrue(pass.usesSpecializedPipeline, name)
      let specialized = try draw(frame, state)
      for i in 0..<Self.colours.count {
        let a = first.pixels.rgb(i, 0), b = specialized.pixels.rgb(i, 0)
        // The same code with the colour codes folded or read: fast-math rounding
        // differs by under 1e-5 (a hundredth of a 10-bit code).
        for k in 0..<3 { XCTAssertEqual(a[k], b[k], accuracy: 1e-5 * max(1, abs(b[k])), "\(name) #\(i)") }
      }
    }
    print(String(format: "BENCH encode after a colour change (asynchronous): slowest %.3f ms", slowest))
    XCTAssertLessThan(slowest, 50, "a colour change stalled the encoding thread")
  }

  // MARK: - Metal 4

  /// A render pass that clears the target stores every tile, so a compute surface
  /// into another viewport of the same target must wait for it: the right half is
  /// the compute picture every round, never the left pass's clear.
  func testComputeSurfaceAfterARenderSurfaceInOneTarget() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    // A heavy left surface: a large frame minified with every tool on.
    let big = try m.frame(PictureTests.picture(width: 1920, height: 1080), signal: .rec709)
    let small = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var heavy = MonitorState()
    everyTool(&heavy)
    heavy.focus.enabled = false
    let left = gpu.engine.makePass(), right = gpu.engine.makePass(), feed = gpu.engine.makeFeed()
    let size = 128
    let target = m.target(size * 2, size, usage: [.renderTarget, .shaderWrite, .shaderRead])
    let state = MonitorState()
    let reference = try gpu.render(small, state: state, width: size, height: size)
    for round in 0..<12 {
      try m.run { s in
        try left.encode(
          frame: big, feed: feed, state: heavy, target: target,
          viewport: MonitorViewport(x: 0, y: 0, width: size, height: size), clear: true, into: s)
        try right.encodeCompute(
          frame: small, feed: feed, state: state, target: target,
          viewport: MonitorViewport(x: size, y: 0, width: size, height: size), into: s)
      }
      let out = Pixels(target)
      var differing = 0
      for y in 0..<size {
        for x in 0..<size where out[size + x, y] != reference[x, y] { differing += 1 }
      }
      XCTAssertEqual(differing, 0, "round \(round)")
    }
  }

  /// The sole writer of a fresh target opts out of the shared-target barrier; it
  /// still waits for its focus analysis, so peaking is the analysed mask's.
  func testSoleComputeWriterStillWaitsForTheMask() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    state.focus.opacity = 1
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let reference = try gpu.render(frame, state: state, width: 96, height: 54, analyze: true)
    for round in 0..<6 {
      let target = m.target(96, 54, usage: [.shaderWrite, .shaderRead])
      try m.run { s in
        feed.invalidateFocusMask()
        try feed.analyze(frame, focus: state.focus, into: s)
        try pass.encodeCompute(frame: frame, feed: feed, state: state, target: target, sharesTarget: false, into: s)
      }
      XCTAssertEqual(Pixels(target).values, reference.values, "round \(round)")
    }
  }

  /// The compute picture on an asynchronous engine: a colour change never
  /// compiles on the encoding thread either.
  func testComputeColourChangesNeverCompileOnTheEncodingThread() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    m.queue.addResidencySet(engine.residency.set)
    try engine.prepareCompute(pixelFormat: .rgba32Float, layouts: [.rgba32Float])
    var picture = SyntheticFrame(layout: .rgba32Float, width: Self.colours.count, height: 1)
    picture.rgb = Self.colours
    let frame = try m.frame(picture, signal: Self.pq)
    let pass = engine.makePass(), feed = engine.makeFeed()
    let target = m.target(Self.colours.count, 1, usage: [.shaderWrite, .shaderRead])
    try m.run { try pass.encodeCompute(frame: frame, feed: feed, state: MonitorState(), target: target, into: $0) }
    let built = engine.pipelinesBuiltOnCaller
    var hdr = MonitorState()
    hdr.displayTransform.mode = .hdrToSDR
    for (state, output) in [
      (hdr, MonitorOutputColor.signalNative), (hdr, MonitorOutputColor(primaries: .rec2020, encoding: .pq)),
      (MonitorState(), MonitorOutputColor(primaries: .rec709, encoding: .extendedLinear)),
    ] {
      pass.outputColor = output
      try m.run { try pass.encodeCompute(frame: frame, feed: feed, state: state, target: target, into: $0) }
      XCTAssertEqual(engine.pipelinesBuiltOnCaller, built, "\(output.encoding)")
      let c = pass.colorPipeline
      let out = Pixels(target)
      for (i, v) in Self.colours.enumerated() {
        assertSameLight(out.rgb(i, 0), c.present(color(v)), c, "\(output.encoding) #\(i)")
      }
    }
    m.drain()
  }

  // MARK: - Analysis

  /// A frame the mask already holds (a frozen frame each display tick) is not
  /// analysed again; new settings, LUTs or frames are.
  func testAnalysingTheSameFrameAgainDispatchesNothing() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    var focus = FocusSettings()
    focus.enabled = true
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertEqual(feed.analysisCount, 1)
    let mask = gpu.readMask(feed)
    for _ in 0..<3 { try gpu.run { try feed.analyze(frame, focus: focus, into: $0) } }
    XCTAssertEqual(feed.analysisCount, 1)
    XCTAssertTrue(feed.hasFocusMask(for: frame))
    XCTAssertEqual(gpu.readMask(feed), mask)
    focus.noiseRejection = 0.2
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertEqual(feed.analysisCount, 2, "new thresholds")
    focus.stage = .output
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 9, seed: 2))
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertEqual(feed.analysisCount, 3, "a LUT stage")
    // Freeze: one analysis for the whole freeze.
    var frozen: MonitorFrame?
    try gpu.run { frozen = try feed.freeze(frame, into: $0) }
    for _ in 0..<4 { try gpu.run { try feed.analyze(frozen!, focus: focus, into: $0) } }
    XCTAssertEqual(feed.analysisCount, 4)
    // Off then on again re-analyses (the mask was marked stale).
    focus.enabled = false
    try gpu.run { try feed.analyze(frozen!, focus: focus, into: $0) }
    focus.enabled = true
    try gpu.run { try feed.analyze(frozen!, focus: focus, into: $0) }
    XCTAssertEqual(feed.analysisCount, 5)
  }
}
