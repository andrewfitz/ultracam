import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// Scopes drawn into HDR and wide-gamut targets: every pixel is the SDR scope's
/// colour (authored as Rec.709 BT.1886 display values at graphics white) put
/// through `MonitorColorPipeline.overlayColor`, the CPU reference the picture
/// pass's overlays use, at the same coverage.
final class ScopeHDRTests: XCTestCase {
  /// A flat grey waveform with a fully covered 100% line at (700, 39), a white
  /// trace and opaque background, plus a colourful vectorscope.
  func scenes(_ engine: ScopeEngine) throws -> [(String, ScopeAccumulator, ScopeDisplay)] {
    let grey = try TestFrame.make(.v210, width: 1920, height: 1080, codes: { _, _ in SIMD3(502, 512, 512) })
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformColumns = 1024
    s.waveformLevels = 512
    let waveform = try engine.makeAccumulator(settings: s)
    var display = s.display
    display.backgroundOpacity = 1
    display.graticuleOpacity = 1
    display.trace = .white
    display.brightness = 1.5
    let natural = try TestFrame.natural(.v210, width: 640, height: 360, mirror: false)
    let vector = try engine.makeAccumulator(settings: ScopeSettings(kind: .vectorscope, stage: .source))
    var colorized = vector.settings.display
    colorized.trace = .colorized
    colorized.backgroundOpacity = 0.6
    colorized.gain = 4
    var parade = ScopeSettings(kind: .waveform, stage: .source)
    parade.waveformMode = .rgbParade
    let rgb = try engine.makeAccumulator(settings: parade)
    try GPU.run { cb in
      try waveform.accumulate(grey.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try vector.accumulate(natural.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try rgb.accumulate(natural.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
    }
    return [("grey waveform", waveform, display), ("colorized vectorscope", vector, colorized),
            ("RGB parade", rgb, rgb.settings.display)]
  }

  static let pqSignal = SignalDescription(matrix: .bt2020, encoding: .display(.pq), primaries: .rec2020)
  static let hlgSignal = SignalDescription(matrix: .bt2020, encoding: .display(.hlg), primaries: .rec2020)

  /// (name, output, signal) of every encoding a scope can land in.
  static let outputs: [(String, MonitorOutputColor, SignalDescription)] = [
    ("PQ BT.2020", MonitorOutputColor(primaries: .rec2020, encoding: .pq), .rec709),
    ("HLG BT.2020", MonitorOutputColor(primaries: .rec2020, encoding: .hlg), .rec709),
    ("HLG 2000 cd/m² Display P3", MonitorOutputColor(primaries: .displayP3, encoding: .hlg, hlgNominalPeak: 2000), .rec709),
    ("extended linear Display P3", MonitorOutputColor(primaries: .displayP3, encoding: .extendedLinear, headroom: 8), .rec709),
    ("extended linear BT.709", MonitorOutputColor(encoding: .extendedLinear), .rec709),
    ("sRGB Display P3", MonitorOutputColor(primaries: .displayP3, encoding: .sdr(.sRGB)), .rec709),
    ("gamma 2.2 BT.2020", MonitorOutputColor(primaries: .rec2020, encoding: .sdr(.gamma22)), .rec709),
    ("PQ at 300 cd/m² white", MonitorOutputColor(primaries: .rec2020, encoding: .pq, referenceWhite: 300), .rec709),
    ("signal-native PQ layer", .signalNative, pqSignal),
    ("signal-native HLG layer", .signalNative, hlgSignal),
  ]

  func render(
    _ engine: ScopeEngine, _ a: ScopeAccumulator, _ display: ScopeDisplay, _ format: MTLPixelFormat,
    output: MonitorOutputColor = .signalNative, signal: SignalDescription = .rec709
  ) throws -> MTLTexture {
    let (device, _, _) = try GPU.require()
    let target = try makeTexture(device, format, 1024, 512)
    let renderer = engine.makeRenderer()
    renderer.setOutputColor(output, signal: signal)
    try GPU.run { cb in try renderer.render(a, display: display, target: target, clear: true, into: cb) }
    return target
  }

  func testEveryPixelIsTheSDRScopeThroughTheOverlayEncoding() throws {
    let (_, _, engine) = try GPU.require()
    for (scene, a, display) in try scenes(engine) {
      let sdr = floatPixels(try render(engine, a, display, .rgba32Float))
      for (name, output, signal) in Self.outputs {
        let pipeline = MonitorColorPipeline(output: output, signal: signal)
        XCTAssertNotNil(pipeline.overlay, name)
        let hdr = floatPixels(try render(engine, a, display, .rgba32Float, output: output, signal: signal))
        var worst = 0.0, failures = 0
        for i in stride(from: 0, to: sdr.count, by: 7) {
          let s = sdr[i], h = hdr[i]
          XCTAssertEqual(h.w, s.w, "\(scene) \(name): alpha is the SDR scope's")
          guard s.w > 0 else {
            XCTAssertEqual(h, .zero)
            continue
          }
          let a = Double(s.w)
          let c = pipeline.overlayColor(
            ColorRGB(r: Double(s.x) / a, g: Double(s.y) / a, b: Double(s.z) / a))
          let e = SIMD3(c.r * a, c.g * a, c.b * a)
          let d = max(abs(Double(h.x) - e.x), abs(Double(h.y) - e.y), abs(Double(h.z) - e.z))
          worst = max(worst, d)
          if d > 1e-3 {
            failures += 1
            if failures <= 3 { XCTFail("\(scene) \(name) pixel \(i % 1024),\(i / 1024): \(h) vs \(e) (SDR \(s))") }
          }
        }
        XCTAssertLessThanOrEqual(worst, 1e-3, "\(scene) \(name)")
      }
    }
  }

  /// BT.2408 graphics white: the fully covered graticule pixel and the opaque
  /// white of `overlayColor` land at 58% PQ, 75% HLG and 1.0 extended linear.
  func testGraphicsWhiteAnchors() throws {
    let (_, _, engine) = try GPU.require()
    let (_, a, display) = try scenes(engine)[0]
    func white(_ output: MonitorOutputColor) -> Double {
      MonitorColorPipeline(output: output, signal: .rec709).overlayColor(ColorRGB(r: 1, g: 1, b: 1)).g
    }
    XCTAssertEqual(white(MonitorOutputColor(primaries: .rec2020, encoding: .pq)), 0.5807, accuracy: 1e-4)
    XCTAssertEqual(white(MonitorOutputColor(primaries: .rec2020, encoding: .hlg)), 0.75, accuracy: 1e-3)
    XCTAssertEqual(white(MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear)), 1, accuracy: 1e-9)
    let graticule = ScopeRenderer.graticuleColor
    for (output, format, tolerance) in [
      (MonitorOutputColor(primaries: .rec2020, encoding: .pq), MTLPixelFormat.rgba16Float, 2e-3),
      (MonitorOutputColor(primaries: .rec2020, encoding: .hlg), .rgba32Float, 1e-4),
      (MonitorOutputColor(primaries: .displayP3, encoding: .extendedLinear), .rgba32Float, 1e-4),
    ] {
      let pipeline = MonitorColorPipeline(output: output, signal: .rec709)
      let expected = pipeline.overlayColor(
        ColorRGB(r: Double(graticule.x), g: Double(graticule.y), b: Double(graticule.z)))
      let target = try render(engine, a, display, format, output: output)
      let pixel: SIMD4<Float>
      if format == .rgba16Float {
        var half = [Float16](repeating: 0, count: 4)
        half.withUnsafeMutableBytes {
          target.getBytes($0.baseAddress!, bytesPerRow: 1024 * 8, from: MTLRegionMake2D(700, 39, 1, 1), mipmapLevel: 0)
        }
        pixel = SIMD4(Float(half[0]), Float(half[1]), Float(half[2]), Float(half[3]))
      } else {
        pixel = floatPixels(target)[39 * 1024 + 700]
      }
      XCTAssertEqual(pixel.w, 1, "\(output.encoding): opaque")
      XCTAssertEqual(Double(pixel.x), expected.r, accuracy: tolerance, "\(output.encoding)")
      XCTAssertEqual(Double(pixel.y), expected.g, accuracy: tolerance, "\(output.encoding)")
      XCTAssertEqual(Double(pixel.z), expected.b, accuracy: tolerance, "\(output.encoding)")
    }
  }

  /// Outputs whose overlays stay as authored draw exactly the SDR scope.
  func testSDRLayersDrawAsAuthored() throws {
    let (_, _, engine) = try GPU.require()
    for (scene, a, display) in try scenes(engine) {
      let reference = rawBytes(try render(engine, a, display, .rgba16Float))
      for (output, signal) in [
        (MonitorOutputColor.signalNative, SignalDescription.rec709),
        (.signalNative, SignalDescription(encoding: .log(.sLog3SGamut3Cine))),
        (MonitorOutputColor(encoding: .sdr(.bt1886)), .rec709),
        (.signalNative, Self.pqSignal),
      ] {
        let renderer = engine.makeRenderer()
        if signal == Self.pqSignal {
          // A PQ signal shown through the SDR display transform is an SDR layer.
          var transform = DisplayTransformSettings()
          transform.mode = .hdrToSDR
          renderer.setOutputColor(output, signal: signal, displayTransform: transform)
        } else {
          renderer.setOutputColor(output, signal: signal)
        }
        let (device, _, _) = try GPU.require()
        let target = try makeTexture(device, .rgba16Float, 1024, 512)
        try GPU.run { cb in try renderer.render(a, display: display, target: target, clear: true, into: cb) }
        XCTAssertEqual(renderer.parameters.encode, .zero)
        XCTAssertEqual(rawBytes(target), reference, "\(scene) \(output.encoding) \(signal.encoding)")
      }
    }
  }

  /// Changing the output colour rebuilds no pipeline and allocates no GPU memory.
  func testOutputColorChangesRebuildNothing() throws {
    let (device, _, engine) = try GPU.require()
    let renderer = engine.makeRenderer()
    let (_, a, display) = try scenes(engine)[0]
    let target = try makeTexture(device, .rgba16Float, 1024, 512)
    try GPU.run { cb in try renderer.render(a, display: display, target: target, clear: true, into: cb) }
    let pipelines = engine.specializedPipelineCount
    let bytes = device.currentAllocatedSize
    let pipeline = MonitorColorPipeline(output: MonitorOutputColor(primaries: .rec2020, encoding: .pq), signal: .rec709)
    renderer.colorPipeline = pipeline
    XCTAssertEqual(renderer.colorPipeline, pipeline)
    try GPU.run { cb in try renderer.render(a, display: display, target: target, clear: true, into: cb) }
    XCTAssertEqual(renderer.parameters.encode.x, Float(MonitorColorPipeline.Transfer.pq.rawValue))
    XCTAssertEqual(renderer.parameters.encode.y, 203)
    XCTAssertEqual(engine.specializedPipelineCount.render, pipelines.render, "no pipeline per output colour")
    XCTAssertEqual(device.currentAllocatedSize, bytes, "no GPU memory per output colour")
  }

  func testDrawParameterLayoutMatchesTheShader() {
    // mk_ScopeDraw: 13 rows before the output encoding, then encode, 3 matrix rows and the weights.
    XCTAssertEqual(MemoryLayout<ScopeDrawParameters>.stride, 18 * 16)
    XCTAssertEqual(MemoryLayout<ScopeDrawParameters>.offset(of: \.traceMap), 7 * 16)
    XCTAssertEqual(MemoryLayout<ScopeDrawParameters>.offset(of: \.pixels), 8 * 16)
    XCTAssertEqual(MemoryLayout<ScopeDrawParameters>.offset(of: \.graticuleColor), 12 * 16)
    XCTAssertEqual(MemoryLayout<ScopeDrawParameters>.offset(of: \.encode), 13 * 16)
    XCTAssertEqual(MemoryLayout<ScopeDrawParameters>.offset(of: \.toTarget0), 14 * 16)
    XCTAssertEqual(MemoryLayout<ScopeDrawParameters>.offset(of: \.targetWeights), 17 * 16)
    // mk_ScopeResolve: five rows.
    XCTAssertEqual(MemoryLayout<ScopeResolveParameters>.stride, 5 * 16)
    XCTAssertEqual(MemoryLayout<ScopeResolveParameters>.offset(of: \.reduce), 4 * 16)
  }
}
