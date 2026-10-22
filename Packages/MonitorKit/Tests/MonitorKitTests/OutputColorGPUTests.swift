import Metal
import XCTest
import simd

@testable import MonitorKit

/// Output colour, display transforms and overlay encoding on the GPU, each against
/// the CPU reference in `MonitorColorPipeline` (Core), and the signal-native picture
/// against the W1 shader it must not change.
final class OutputColorGPUTests: XCTestCase {
  /// A float RGB frame (full range, so the decode is the stored value) of `values`, one row.
  func floatFrame(_ gpu: TestGPU, _ values: [SIMD3<Double>], signal: SignalDescription) throws -> MonitorFrame {
    var picture = SyntheticFrame(layout: .rgba32Float, width: values.count, height: 1)
    picture.rgb = values.map { SIMD3(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) }
    return try picture.frame(gpu, signal: signal)
  }

  /// A neutral ramp plus saturated and mixed colours, all within 0…1.
  static let samples: [SIMD3<Double>] = {
    var v = (0...64).map { SIMD3<Double>(repeating: Double($0) / 64) }
    var rng = SeededRandom(11)
    for _ in 0..<64 {
      v.append(SIMD3(Double.random(in: 0...1, using: &rng), Double.random(in: 0...1, using: &rng), Double.random(in: 0...1, using: &rng)))
    }
    v += [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 0, 1), SIMD3(0.75, 0.75, 0.75)]
    return v
  }()

  func color(_ v: SIMD3<Double>) -> ColorRGB { ColorRGB(r: v.x, g: v.y, b: v.z) }

  func assertClose(
    _ gpu: SIMD3<Float>, _ cpu: ColorRGB, relative: Double, absolute: Double, _ message: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for (g, c) in [(gpu.x, cpu.r), (gpu.y, cpu.g), (gpu.z, cpu.b)] {
      XCTAssertTrue(g.isFinite, message(), file: file, line: line)
      XCTAssertEqual(Double(g), c, accuracy: max(absolute, abs(c) * relative), message(), file: file, line: line)
    }
  }

  /// GPU and CPU target values compared as the light they stand for (decoded with
  /// the target's EOTF), within float32 precision of the largest light involved:
  /// a PQ highlight near 10 000 cd/m² converted between primaries cancels terms of
  /// about 50× graphics white, and gamma curves are steep near black.
  func assertSameLight(
    _ gpu: SIMD3<Float>, _ cpu: ColorRGB, _ pipeline: MonitorColorPipeline, source: ColorRGB,
    _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let target = pipeline.target else {
      // A transform's float32 maths into an SDR picture: within 1/20 of a 10-bit code.
      return assertClose(gpu, cpu, relative: 1e-4, absolute: 5e-5, message(), file: file, line: line)
    }
    let g = ColorRGB(r: Double(gpu.x), g: Double(gpu.y), b: Double(gpu.z))
    XCTAssertTrue(g.isFinite, message(), file: file, line: line)
    let a = pipeline.linear(g, transfer: target.transfer, primaries: target.primaries)
    let b = pipeline.linear(cpu, transfer: target.transfer, primaries: target.primaries)
    let input = pipeline.linear(source, transfer: pipeline.picture.transfer, primaries: pipeline.picture.primaries)
    let scale = max(1, abs(input.r), abs(input.g), abs(input.b))
    for (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)] {
      XCTAssertEqual(x, y, accuracy: 4e-6 * scale + 2e-4 * abs(y), message(), file: file, line: line)
    }
  }

  static let signals: [(String, SignalDescription)] = [
    ("BT.709", SignalDescription(range: .full)),
    ("sRGB", SignalDescription(range: .full, encoding: .display(.sRGB))),
    ("PQ 2020", SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq))),
    ("HLG 2020", SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.hlg))),
    ("HLG 709", SignalDescription(range: .full, encoding: .display(.hlg), primaries: .rec709)),
    ("linear P3", SignalDescription(range: .full, encoding: .display(.linear), primaries: .displayP3)),
  ]

  static let encodings: [MonitorOutputColor.Encoding] = [
    .sdr(.bt1886), .sdr(.sRGB), .sdr(.gamma22), .extendedLinear, .pq, .hlg,
  ]

  // MARK: - Encodings

  /// Every signal into every encoding and primaries: GPU = `present` within float precision.
  func testEveryEncodingMatchesTheCPUReference() throws {
    let gpu = try requireGPU()
    for (name, signal) in Self.signals {
      let frame = try floatFrame(gpu, Self.samples, signal: signal)
      for encoding in Self.encodings {
        for primaries in ColorPrimaries.allCases {
          let pass = gpu.engine.makePass()
          pass.outputColor = MonitorOutputColor(primaries: primaries, encoding: encoding)
          let out = try gpu.render(frame, state: MonitorState(), pass: pass)
          let c = pass.colorPipeline
          XCTAssertEqual(c.convertsToTarget ? c.target?.transfer.rawValue ?? 0 : 0, pass.currentParameters.color.z)
          for (i, v) in Self.samples.enumerated() {
            assertSameLight(out.rgb(i, 0), pass.colorPipeline.present(color(v)), pass.colorPipeline, source: color(v), "\(name) → \(encoding) \(primaries) #\(i) \(v)")
          }
        }
      }
    }
  }

  /// BT.2408 anchors through the GPU: SDR white is 58% PQ, 75% HLG, 1.0 linear,
  /// and HDR reference white comes back to it.
  func testGraphicsWhiteAndReferenceLevelsOnTheGPU() throws {
    let gpu = try requireGPU()
    func render(_ v: Double, _ signal: SignalDescription, _ encoding: MonitorOutputColor.Encoding) throws -> Float {
      let pass = gpu.engine.makePass()
      pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: encoding)
      return try gpu.render(try floatFrame(gpu, [SIMD3(repeating: v)], signal: signal), state: MonitorState(), pass: pass)
        .rgb(0, 0).y
    }
    let sdr = SignalDescription(range: .full, matrix: .bt2020)
    XCTAssertEqual(try render(1, sdr, .pq), 0.580689, accuracy: 1e-5)
    XCTAssertEqual(try render(1, sdr, .hlg), 0.75, accuracy: 2e-3)
    XCTAssertEqual(try render(1, sdr, .extendedLinear), 1, accuracy: 1e-6)
    let pq = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq))
    let hlg = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.hlg))
    XCTAssertEqual(try render(0.580689, pq, .extendedLinear), 1, accuracy: 1e-4, "203 cd/m² is graphics white")
    XCTAssertEqual(try render(0.75, hlg, .extendedLinear), 1, accuracy: 3e-3, "75% HLG is graphics white")
    XCTAssertEqual(try render(0.75, hlg, .pq), 0.580689, accuracy: 1e-3)
    // The grey card: 38% PQ and 38% HLG are both about 26 cd/m².
    XCTAssertEqual(Double(try render(0.38, hlg, .extendedLinear)) * 203, 26, accuracy: 0.5)
    XCTAssertEqual(Double(try render(0.38, pq, .extendedLinear)) * 203, ColorMath.pqNits(0.38), accuracy: 0.01)
  }

  /// Extended linear keeps out-of-gamut (negative) values and super-whites; every
  /// other encoding clips, and nothing is NaN.
  func testOutOfGamutHandling() throws {
    let gpu = try requireGPU()
    let pq = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq))
    let frame = try floatFrame(gpu, [SIMD3(0, 0.75, 0), SIMD3(0.9, 0.9, 0.9)], signal: pq)
    let ext = gpu.engine.makePass()
    ext.outputColor = MonitorOutputColor(primaries: .rec709, encoding: .extendedLinear)
    let e = try gpu.render(frame, state: MonitorState(), pass: ext)
    XCTAssertLessThan(e.rgb(0, 0).x, 0, "BT.2020 green has negative BT.709 red")
    XCTAssertGreaterThan(e.rgb(1, 0).y, 10, "a highlight keeps its headroom")
    let sdr = gpu.engine.makePass()
    sdr.outputColor = MonitorOutputColor(primaries: .rec709, encoding: .sdr(.bt1886))
    let s = try gpu.render(frame, state: MonitorState(), pass: sdr)
    XCTAssertEqual(s.rgb(0, 0).x, 0)
    XCTAssertEqual(s.rgb(1, 0), SIMD3(repeating: 1))
    for v in e.values + s.values { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite) }
  }

  // MARK: - Display transforms

  /// The log transform on every camera curve, legal and full: the GPU against
  /// `transformed` on the decoded source, every 10-bit code, neutral and coloured.
  /// Full containers labelled `.fullRescaledToLegal` go through the transform's
  /// own unsqueeze (`mk_logSignalFast`), whose scale follows the container depth:
  /// 10-bit v210 and P210, 8-bit and 16-bit biplanar.
  func testLogToRec709MatchesTheCPUReference() throws {
    let gpu = try requireGPU()
    let logC3 = try XCTUnwrap(LogEncoding(profileID: "arri-logc3-ei800"))
    let rescaled: (LogEncoding) -> LogEncoding = { var l = $0; l.transport = .fullRescaledToLegal; return l }
    let encodings: [(LogEncoding, CodeRange, PixelLayout)] = [
      (.sLog3SGamut3Cine, .legal, .v210), (.sLog3SGamut3, .full, .v210),
      (logC3, .legal, .v210), (logC3, .full, .v210),
      (try XCTUnwrap(LogEncoding(profileID: "arri-alexa35-logc4-ei800")), .legal, .v210),
      (rescaled(.sLog3SGamut3Cine), .full, .v210), (rescaled(logC3), .full, .v210),
      (rescaled(.sLog3SGamut3Cine), .full, .p210), (rescaled(logC3), .full, .p210),
      (rescaled(.sLog3SGamut3), .full, .biplanar(.s422, bitDepth: 8)),
      (rescaled(logC3), .full, .biplanar(.s422, bitDepth: 16)),
      (rescaled(logC3), .legal, .v210),
    ]
    for (log, range, layout) in encodings {
      let depth = layout.bitDepth, maxCode = (1 << depth) - 1
      func code(_ c10: Int) -> Int { Int((Double(c10) * Double(maxCode) / 1023).rounded()) }
      var picture = SyntheticFrame.neutral(layout, width: 1024, height: 2) { x, _ in code(x) }
      // Row 2 carries chroma, so out-of-gamut colours clip.
      var rng = SeededRandom(5)
      for i in picture.chromaWidth..<(2 * picture.chromaWidth) {
        picture.cb[i] = code(Int.random(in: 300...724, using: &rng))
        picture.cr[i] = code(Int.random(in: 300...724, using: &rng))
      }
      let signal = SignalDescription(range: range, encoding: .log(log))
      let frame = try picture.frame(gpu, signal: signal)
      let decoded = gpu.decode(frame)
      var state = MonitorState()
      state.displayTransform.mode = .logToRec709
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertEqual(pass.colorPipeline.transform, .logToRec709)
      XCTAssertTrue(pass.status.isActive(.displayTransform))
      for i in 0..<decoded.count {
        let d = decoded[i]
        let cpu = pass.colorPipeline.present(
          ColorRGB(r: Double(d.x), g: Double(d.y), b: Double(d.z)), range: range, bitDepth: depth)
        // Coloured highlights convert gamut from scene light far above 1, which float32
        // resolves to about 1e-6 of it; the BT.709 OETF's slope is at most 4.5.
        func scene(_ v: Float) -> Double {
          abs(log.curve.decode(log.curve.signal(expanded: Double(v), range: range, transport: log.transport, bitDepth: depth)) ?? 0)
        }
        let tolerance = 2e-5 + 5e-6 * max(1, scene(d.x), scene(d.y), scene(d.z))
        assertClose(
          out.values[i].xyz, cpu, relative: 1e-4, absolute: tolerance,
          "\(log.curve) \(log.transport) \(range) \(layout) #\(i)")
      }
    }
  }

  func testHDRToSDRMatchesTheCPUReference() throws {
    let gpu = try requireGPU()
    for (name, signal) in Self.signals where signal.isHDR {
      let frame = try floatFrame(gpu, Self.samples, signal: signal)
      for encoding in [MonitorOutputColor.Encoding.signalNative, .sdr(.bt1886), .pq] {
        var state = MonitorState()
        state.displayTransform = DisplayTransformSettings(mode: .hdrToSDR, pqSourcePeak: 2000)
        let pass = gpu.engine.makePass()
        pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: encoding)
        let out = try gpu.render(frame, state: state, pass: pass)
        XCTAssertEqual(pass.colorPipeline.picture.transfer, .bt1886, name)
        for (i, v) in Self.samples.enumerated() {
          assertSameLight(out.rgb(i, 0), pass.colorPipeline.present(color(v)), pass.colorPipeline, source: color(v), "\(name) \(encoding) #\(i)")
        }
      }
    }
  }

  /// Passthrough into extended linear rolls off to the headroom, which is a
  /// uniform: changing it rebuilds nothing and builds no pipeline.
  func testPassthroughFollowsTheHeadroomWithoutRebuilding() throws {
    let gpu = try requireGPU()
    let pq = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq))
    let frame = try floatFrame(gpu, Self.samples, signal: pq)
    var state = MonitorState()
    state.displayTransform.mode = .hdrPassthrough
    let pass = gpu.engine.makePass(), feed = gpu.engine.makeFeed()
    pass.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear, headroom: 2)
    _ = try gpu.render(frame, state: state, feed: feed, pass: pass)
    let rebuilds = pass.rebuildCount, pipelines = gpu.engine.pipelinesBuilt
    for headroom in [2.0, 3.5, 8] {
      pass.outputColor.headroom = headroom
      let out = try gpu.render(frame, state: state, feed: feed, pass: pass)
      for (i, v) in Self.samples.enumerated() {
        assertSameLight(
          out.rgb(i, 0), pass.colorPipeline.present(color(v), headroom: headroom), pass.colorPipeline, source: color(v),
          "\(headroom) #\(i)")
      }
      // The 1000 cd/m² master peak lands on the headroom, or stays when it fits.
      let peak = pass.colorPipeline.present(ColorRGB(r: 0.751827, g: 0.751827, b: 0.751827), headroom: headroom).g
      XCTAssertEqual(peak, min(headroom, 1000 / 203), accuracy: 2e-3)
    }
    XCTAssertEqual(pass.rebuildCount, rebuilds)
    XCTAssertEqual(gpu.engine.pipelinesBuilt, pipelines)
    // Following the display's headroom every frame allocates nothing.
    let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    var headroom = 1.0
    let allocations = try AllocationCounter.measure {
      var i = 0
      while i < 50 {
        headroom += 0.1
        pass.outputColor.headroom = headroom
        try pass.prepare(
          frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: frame.width, height: 1),
          targetPixelFormat: .rgba32Float, into: cb)
        i += 1
      }
    }
    if let allocations { XCTAssertEqual(allocations, 0, "headroom changes allocate") }
    XCTAssertEqual(pass.rebuildCount, rebuilds)
  }

  func testTransformStatusAndUnavailableReasons() throws {
    let gpu = try requireGPU()
    let frame = try floatFrame(gpu, [SIMD3(repeating: 0.5)], signal: SignalDescription(range: .full))
    func status(_ mode: DisplayTransform, _ encoding: MonitorOutputColor.Encoding = .signalNative) throws -> MonitorStatus {
      var state = MonitorState()
      state.displayTransform.mode = mode
      let pass = gpu.engine.makePass()
      pass.outputColor = MonitorOutputColor(encoding: encoding)
      _ = try gpu.render(frame, state: state, pass: pass)
      return pass.status
    }
    XCTAssertEqual(try status(.logToRec709).reason(for: .displayTransform), .requiresLogSource)
    XCTAssertEqual(try status(.hdrToSDR).reason(for: .displayTransform), .requiresHDRSource)
    XCTAssertEqual(try status(.hdrPassthrough).reason(for: .displayTransform), .requiresHDRSource)
    XCTAssertFalse(try status(.none).isActive(.displayTransform))
    XCTAssertNil(try status(.none).reason(for: .displayTransform))
    let pq = try floatFrame(gpu, [SIMD3(repeating: 0.5)], signal: SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq)))
    var state = MonitorState()
    state.displayTransform.mode = .hdrPassthrough
    let pass = gpu.engine.makePass()
    pass.outputColor = MonitorOutputColor(encoding: .sdr(.bt1886))
    _ = try gpu.render(pq, state: state, pass: pass)
    XCTAssertEqual(pass.status.reason(for: .displayTransform), .requiresHDROutput)
    pass.outputColor = MonitorOutputColor(encoding: .pq)
    _ = try gpu.render(pq, state: state, pass: pass)
    XCTAssertTrue(pass.status.isActive(.displayTransform))
    XCTAssertEqual(pass.status.active.first { $0.tool == .displayTransform }?.label, "HDR passthrough")
  }

  /// Tools measure their stage, never the transformed picture: a log source's
  /// zebras flag the same pixels with the transform on or off.
  func testToolsMeasureTheirStageNotTheTransformedPicture() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 1) { x, _ in x }
    let frame = try picture.frame(gpu, signal: SignalDescription(encoding: .log(.sLog3SGamut3Cine)))
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 50, stage: .source)
    state.zebras[0].opacity = 1
    for mode in [DisplayTransform.none, .logToRec709] {
      state.displayTransform.mode = mode
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass)
      let period = Int(pass.currentParameters.zebra.w)
      // Source IRE ≥ 50 is code 502 and up (S-Log3 native codes); stripes on alternate runs.
      for x in 0..<940 {
        let flagged = x >= 502 && x % period < period / 2
        XCTAssertEqual(out.rgb(x, 0) == SIMD3(repeating: 1), flagged, "\(mode) \(x)")
      }
      if mode == .logToRec709 {
        // Unflagged pixels show the transform: grey (code 420) at 40.9%.
        XCTAssertEqual(out.rgb(420, 0).y, 0.409, accuracy: 0.002)
      }
    }
  }

  // MARK: - Overlay colours

  /// Zebra, clip, false-colour and guide colours read back from the target equal
  /// the CPU's `overlayColor` of their authored Rec.709 colour, in every encoding.
  func testOverlayColoursAreEncodedForTheTarget() throws {
    let gpu = try requireGPU()
    let frame = try floatFrame(gpu, Array(repeating: SIMD3(repeating: 1), count: 64), signal: SignalDescription(range: .full))
    let encodings: [MonitorOutputColor.Encoding] = [.signalNative] + Self.encodings
    for encoding in encodings {
      for primaries in [ColorPrimaries.rec709, .rec2020] {
        let pass = gpu.engine.makePass()
        pass.outputColor = MonitorOutputColor(primaries: primaries, encoding: encoding)
        // Clip indicators: uniform magenta at full opacity over every pixel.
        var clip = MonitorState()
        clip.clipIndicators.enabled = true
        clip.clipIndicators.coloring = .uniform
        clip.clipIndicators.overColor = ColorRGB(r: 1, g: 0, b: 1)
        let c = try gpu.render(frame, state: clip, pass: pass)
        let magenta = SIMD3<Float>(pass.colorPipeline.overlayColor(ColorRGB(r: 1, g: 0, b: 1)))
        XCTAssertEqual(c.rgb(5, 0), magenta, "\(encoding) \(primaries)")
        // Zebra set 1 (light stripes) at full opacity: its stripes are graphics white.
        var zebra = MonitorState()
        zebra.zebras[0] = ZebraSet(mode: .lowerLimit, level: 0, stage: .source)
        zebra.zebras[0].opacity = 1
        let z = try gpu.render(frame, state: zebra, pass: pass)
        let white = SIMD3<Float>(pass.colorPipeline.overlayColor(ColorRGB(r: 1, g: 1, b: 1)))
        XCTAssertEqual(z.rgb(0, 0), white, "\(encoding) \(primaries)")
        // Six-band false colour: 100% is red.
        var fc = MonitorState()
        fc.falseColor.mode = .sixBand
        let f = try gpu.render(frame, state: fc, pass: pass)
        XCTAssertEqual(f.rgb(0, 0), SIMD3<Float>(pass.colorPipeline.overlayColor(ColorRGB(r: 1, g: 0, b: 0))), "\(encoding)")
        if encoding == .pq { XCTAssertEqual(white.y, 0.5807, accuracy: 1e-4) }
        if encoding == .hlg { XCTAssertEqual(white.y, 0.75, accuracy: 2e-3) }
        if encoding == .extendedLinear { XCTAssertEqual(white.y, 1, accuracy: 1e-6) }
      }
    }
  }

  /// On a signal-native HDR layer overlays go into the signal's transfer and
  /// primaries, so graphics white is 58% PQ / 75% HLG, never 100%.
  func testOverlaysOnHDRNativeLayersAreNotBlinding() throws {
    let gpu = try requireGPU()
    for (signal, expected) in [
      (SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq)), 0.580689),
      (SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.hlg)), 0.75),
    ] {
      let frame = try floatFrame(gpu, Array(repeating: SIMD3(repeating: 1), count: 16), signal: signal)
      var state = MonitorState()
      state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 0, stage: .source)
      state.zebras[0].opacity = 1
      let out = try gpu.render(frame, state: state)
      XCTAssertEqual(Double(out.rgb(0, 0).y), expected, accuracy: 2e-3)
      // A LUT on the monitor stage makes the picture Rec.709 SDR: overlays as authored.
      let feed = gpu.engine.makeFeed()
      feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 2, seed: 1))
      let lut = try gpu.render(frame, state: state, feed: feed)
      XCTAssertEqual(lut.rgb(0, 0), SIMD3(repeating: 1))
    }
  }

  // MARK: - Signal-native: the W1 picture, bit for bit

  /// The W1 picture pipeline (the committed shader before output colour), all tools on.
  static func w1Pipeline(_ gpu: TestGPU, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
    let library = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode], extra: W1PictureShader.source)
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "mk_fullscreen")
    d.fragmentFunction = library.makeFunction(name: "mk_picture")
    d.colorAttachments[0].pixelFormat = format
    return try gpu.device.makeRenderPipelineState(descriptor: d)
  }

  /// Draws with the W1 shader and the bindings `pass` used for its last frame: the
  /// W1 parameter struct is a prefix of today's, so the same bytes serve both.
  func renderW1(_ gpu: TestGPU, _ pipeline: MTLRenderPipelineState, frame: MonitorFrame, feed: MonitorFeed,
                pass: MonitorPass, state: MonitorState, size: (Int, Int)) -> Pixels {
    let target = gpu.target(size.0, size.1)
    gpu.run { cb in
      let d = MTLRenderPassDescriptor()
      d.colorAttachments[0].texture = target
      d.colorAttachments[0].loadAction = .clear
      d.colorAttachments[0].storeAction = .store
      d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      let e = cb.makeRenderCommandEncoder(descriptor: d)!
      e.setRenderPipelineState(pipeline)
      let monitor = state.monitorLUT ? feed.monitorLUT : nil
      e.setFragmentTexture(frame.packed ?? gpu.engine.emptyPacked, index: 0)
      e.setFragmentTexture(frame.luma ?? gpu.engine.emptyFloat, index: 1)
      e.setFragmentTexture(frame.chroma ?? gpu.engine.emptyFloat, index: 2)
      e.setFragmentTexture(feed.burnInLUT?.texture ?? gpu.engine.emptyLUT, index: 3)
      e.setFragmentTexture(monitor?.texture ?? gpu.engine.emptyLUT, index: 4)
      e.setFragmentTexture(pass.currentParameters.focus.z != 0 ? feed.focusMask! : gpu.engine.emptyFloat, index: 5)
      var f = frame.parameters, burn = feed.burnInLUT?.parameters ?? .disabled, mon = monitor?.parameters ?? .disabled
      var p = pass.currentParameters, g = pass.currentGuides
      e.setFragmentBytes(&f, length: MemoryLayout<FrameParameters>.stride, index: 0)
      e.setFragmentBytes(&burn, length: MemoryLayout<LUTParameters>.stride, index: 1)
      e.setFragmentBytes(&mon, length: MemoryLayout<LUTParameters>.stride, index: 2)
      e.setFragmentBytes(&p, length: MemoryLayout<PassParameters>.stride, index: 3)
      e.setFragmentBytes(&g, length: MemoryLayout<GuideParameters>.stride, index: 4)
      e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      e.endEncoding()
    }
    return Pixels(target)
  }

  /// SDR signals on the default (signal-native) output draw exactly what W1 drew:
  /// every layout family, LUTs, every overlay, log false colour, magnification.
  func testSignalNativeIsTheW1PictureBitForBit() throws {
    let gpu = try requireGPU()
    let w1 = try Self.w1Pipeline(gpu, format: .rgba32Float)
    var tools = MonitorState()
    everyTool(&tools)
    var sony = MonitorState()
    sony.falseColor.mode = .sonySLog3
    sony.zebras[0] = ZebraSet(mode: .band, level: 41, range: 3, stage: .source)
    var zoomed = tools
    zoomed.geometry.magnification.zoom = 3
    zoomed.falseColor.mode = .custom
    zoomed.falseColor.customUnit = .stops
    var adjusted = MonitorState()
    adjusted.display.monochrome = .luma
    adjusted.display.contrast = 1.4
    let cases: [(String, PixelLayout, SignalDescription, MonitorState, Bool)] = [
      ("plain v210", .v210, .rec709, MonitorState(), false),
      ("every tool v210 + LUTs", .v210, .rec709, tools, true),
      // BT.2020 SDR: the picture is W1's; its overlays are encoded for its BT.2020
      // layer since W2 (`testNativeOverlaysFollowTheLayersPrimariesAndTransfer`).
      ("p010 BT.2020 SDR", .p010, SignalDescription(matrix: .bt2020), MonitorState(), false),
      ("every tool p010 BT.709 primaries", .p010, SignalDescription(matrix: .bt2020, primaries: .rec709), tools, false),
      ("Sony false colour S-Log3", .v210, SignalDescription(encoding: .log(.sLog3SGamut3Cine)), sony, false),
      ("magnified + stops, sRGB float", .rgba16Float, SignalDescription(range: .full, encoding: .display(.sRGB)), zoomed, true),
      ("adjusted nv12", .nv12, .rec709, adjusted, false),
    ]
    for (name, layout, signal, state, luts) in cases {
      let source = layout.isRGB ? SyntheticFrame.random(layout, width: 192, height: 108, seed: 9) : PictureTests.picture(layout, width: 192, height: 108)
      let frame = try source.frame(gpu, signal: signal)
      let feed = gpu.engine.makeFeed()
      if luts {
        feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 1))
        feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 2))
      }
      let pass = gpu.engine.makePass()
      XCTAssertEqual(pass.outputColor, .signalNative)
      let now = try gpu.render(frame, state: state, feed: feed, pass: pass, width: 160, height: 90, analyze: state.focus.enabled)
      XCTAssertNil(pass.colorPipeline.target)
      XCTAssertEqual(pass.colorPipeline.overlay == nil, signal.effectivePrimaries == .rec709, name)
      let before = renderW1(gpu, w1, frame: frame, feed: feed, pass: pass, state: state, size: (160, 90))
      XCTAssertGreaterThan(Set(now.values.map(\.y)).count, 100, "\(name): a real picture")
      var differing = 0
      for i in 0..<now.values.count where now.values[i] != before.values[i] { differing += 1 }
      XCTAssertEqual(differing, 0, "\(name): pixels differ from W1")
    }
  }

  // MARK: - Layer helpers

  /// HLG/PQ sources labelled BT.709 keep BT.709 primaries, read from the pixel buffer.
  func testPrimariesAttachmentIsReadIndependentlyOfTheTransfer() throws {
    let picture = PictureTests.picture(.v210, width: 12, height: 2)
    let pb = try XCTUnwrap(picture.pixelBuffer(range: .legal))
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    var signal = MonitorFrame.signal(of: pb, range: .legal)
    XCTAssertEqual(signal.primaries, .rec709)
    XCTAssertEqual(signal.effectivePrimaries, .rec709)
    XCTAssertEqual(MonitorOutputColor.recommended(for: signal).layer(for: signal).colorSpace, .itur709HLG)
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    signal = MonitorFrame.signal(of: pb, range: .legal)
    XCTAssertEqual(signal.primaries, .rec2020)
    XCTAssertEqual(MonitorOutputColor.recommended(for: signal).layer(for: signal).colorSpace, .itur2100HLG)
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
    XCTAssertEqual(MonitorFrame.signal(of: pb, range: .legal).primaries, .displayP3)
    CVBufferRemoveAttachment(pb, kCVImageBufferColorPrimariesKey)
    signal = MonitorFrame.signal(of: pb, range: .legal)
    XCTAssertNil(signal.primaries)
    XCTAssertEqual(signal.effectivePrimaries, .rec2020, "unlabelled HLG is BT.2100")
  }

  /// `prepare` with an output colour builds the pipeline the first frame uses.
  func testPrepareBuildsTheOutputColourPipeline() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .off)
    let output = MonitorOutputColor(primaries: .rec2020, encoding: .pq)
    let signal = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.hlg))
    try engine.prepare(target: .init(colorPixelFormat: .rgba16Float), layouts: [.rgba32Float], outputColor: output, signal: signal)
    let built = engine.pipelinesBuilt
    let pass = engine.makePass()
    pass.outputColor = output
    let frame = try floatFrame(gpu, [SIMD3(repeating: 0.5)], signal: signal)
    let target = gpu.texture(.rgba16Float, 4, 4, usage: [.renderTarget])
    try gpu.run { try pass.encode(frame: frame, feed: engine.makeFeed(), state: MonitorState(), target: target, into: $0) }
    XCTAssertEqual(engine.pipelinesBuilt, built)
  }
}

extension SIMD4 where Scalar == Float {
  var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
