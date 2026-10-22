import Metal
import MonitorKit
import MonitorKitCore
import XCTest
import simd

@testable import MonitorKitScopes

final class ScopeRenderTests: XCTestCase {
  func makeTarget(_ format: MTLPixelFormat = .rgba8Unorm, width: Int = 1024, height: Int = 512) throws -> MTLTexture {
    let (device, _, _) = try GPU.require()
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    return try XCTUnwrap(device.makeTexture(descriptor: d))
  }

  func pixels(_ t: MTLTexture) -> [SIMD4<UInt8>] {
    var out = [SIMD4<UInt8>](repeating: .zero, count: t.width * t.height)
    out.withUnsafeMutableBytes {
      t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    }
    return out
  }

  /// Flat 50% grey: every column's pixels in one level bin.
  func flatGreyWaveform(_ engine: ScopeEngine) throws -> (ScopeAccumulator, TestFrame) {
    let frame = try TestFrame.make(.v210, width: 1920, height: 1080, codes: { _, _ in SIMD3(502, 512, 512) })
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformColumns = 1024
    s.waveformLevels = 512
    s.display.backgroundOpacity = 1
    s.display.showsGraticule = false
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    return (accumulator, frame)
  }

  /// Rendered trace colour against the Swift intensity curve and colour ramp,
  /// with bins and viewport 1:1 so each pixel centre reads exactly one bin.
  func testWaveformTraceMatchesReference() throws {
    let (_, _, engine) = try GPU.require()
    // A vertical ramp spreads each column over many levels: unsaturated densities.
    let frame = try TestFrame.make(
      .v210, width: 1920, height: 1080, codes: { x, y in SIMD3(64 + y * 876 / 1079 + (x / 480) * 3, 512, 512) },
      mirror: false)
    for (mode, curve, gain) in [
      (WaveformMode.luma, ScopeIntensityCurve.logarithmic, 1.0), (.luma, .gamma, 3), (.rgbOverlay, .logarithmic, 0.5),
    ] {
      var s = ScopeSettings(kind: .waveform, stage: .source)
      s.waveformMode = mode
      s.waveformColumns = 1024
      s.waveformLevels = 512
      s.display.backgroundOpacity = 1
      s.display.showsGraticule = false
      s.display.intensity = curve
      s.display.gain = gain
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let bins = try readBins(accumulator)
      let target = try makeTarget()
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      let colors = ScopeRenderer.colors(settings: s)
      let bases = [colors.0, colors.1, colors.2].map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
      var random = SeededRandom(17)
      var lit = 0
      for _ in 0..<400 {
        let column = random.int(0...1023), row = random.int(0...511)
        let level = 511 - row
        var expected = SIMD3<Double>.zero
        for k in 0..<accumulator.layout.channels {
          let count = Double(bins[(k * 512 + level) * 1024 + column])
          // Each column is normalized by the frame columns that feed it.
          let frameColumns = Double((0..<1920).filter { $0 * 1024 / 1920 == column }.count)
          let unit = frameColumns * 1080 / 512
          let i = min(1, curve.value(density: gain * count / unit))
          expected += i * (bases[k] + (SIMD3(repeating: 1) - bases[k]) * (i * i * 0.6))
        }
        expected = simd_min(expected, SIMD3(repeating: 1))
        if expected.max() > 0.05 { lit += 1 }
        let got = image[row * 1024 + column]
        for c in 0..<3 {
          XCTAssertEqual(Double(got[c]), expected[c] * 255, accuracy: 1.5, "\(mode) \(curve) (\(column), \(row)) channel \(c)")
        }
      }
      XCTAssertGreaterThan(lit, 50, "the sample covers the trace")
    }
  }

  func testGraticuleLinesAndBackgroundOpacity() throws {
    let (_, _, engine) = try GPU.require()
    let (accumulator, _) = try flatGreyWaveform(engine)
    var display = accumulator.settings.display
    display.showsGraticule = true
    display.graticuleOpacity = 1
    display.backgroundOpacity = 0.5
    let target = try makeTarget()
    let renderer = engine.makeRenderer()
    try GPU.run { cb in try renderer.render(accumulator, display: display, target: target, clear: true, into: cb) }
    let image = pixels(target)
    // The 100% line, on the centre of its bin floor(1.07 · 512 / 1.16) = 472: y = 512 - 472.5 = 39.5 px.
    let line = image[39 * 1024 + 700], above = image[30 * 1024 + 700]
    XCTAssertGreaterThan(Int(line.x), 150, "an anti-aliased graticule line")
    XCTAssertEqual(above, SIMD4(0, 0, 0, 128), "background at half opacity, premultiplied")
    XCTAssertEqual(renderer.graticule.labels.count, 11)
    XCTAssertEqual(renderer.graticule.labels.first { $0.value == 100 }!.position.y * 512, 39.5, accuracy: 1e-9)
  }

  func testHostPassDrawMatchesOwnPassAndRespectsViewport() throws {
    let (_, queue, engine) = try GPU.require()
    let (accumulator, _) = try flatGreyWaveform(engine)
    accumulator.settings.display.showsGraticule = true
    let own = try makeTarget(width: 1200, height: 800)
    let host = try makeTarget(width: 1200, height: 800)
    let viewport = MonitorViewport(x: 100, y: 50, width: 1024, height: 512, pixelsPerPoint: 2)
    let renderer = engine.makeRenderer()
    try GPU.run { cb in try renderer.render(accumulator, target: own, viewport: viewport, clear: true, into: cb) }
    let cb = try XCTUnwrap(queue.makeCommandBuffer())
    try renderer.prepare(accumulator, viewport: viewport, targetPixelFormat: host.pixelFormat, into: cb)
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = host
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    let encoder = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
    // State a host may leave behind: GL-style culling, wireframe, a scissor.
    encoder.setFrontFacing(.counterClockwise)
    encoder.setCullMode(.back)
    encoder.setTriangleFillMode(.lines)
    encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: 4, height: 4))
    renderer.draw(with: encoder)
    encoder.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let a = pixels(own), b = pixels(host)
    let differing = a.indices.filter { a[$0] != b[$0] }
    XCTAssertTrue(
      differing.isEmpty,
      "\(differing.count) pixels differ, first at \(differing.first.map { ($0 % 1200, $0 / 1200) } ?? (0, 0)): "
        + "\(differing.first.map { "\(a[$0]) vs \(b[$0])" } ?? "")")
    XCTAssertEqual(a[10 * 1200 + 10], .zero, "outside the viewport is untouched")
    XCTAssertEqual(a[(50 + 600) * 1200 + 1150], .zero)
    XCTAssertEqual(a[(50 + 260) * 1200 + 100 + 500].w, 255, "inside the viewport the scope draws")
    XCTAssertGreaterThan(a[(50 + 260) * 1200 + 100 + 500].y, 200)
  }

  func testSRGBTargetStoresTheSameDisplayValues() throws {
    let (_, _, engine) = try GPU.require()
    let (accumulator, _) = try flatGreyWaveform(engine)
    var display = accumulator.settings.display
    display.gain = 0.004
    let linear = try makeTarget(.rgba8Unorm), srgb = try makeTarget(.rgba8Unorm_srgb)
    let renderer = engine.makeRenderer()
    try GPU.run { cb in
      try renderer.render(accumulator, display: display, target: linear, clear: true, into: cb)
      try renderer.render(accumulator, display: display, target: srgb, clear: true, into: cb)
    }
    let a = pixels(linear), b = pixels(srgb)
    for i in [260 * 1024 + 3, 260 * 1024 + 900] {
      for c in 0..<3 { XCTAssertEqual(Double(a[i][c]), Double(b[i][c]), accuracy: 2) }
    }
  }

  func testNoDataDrawsOnlyBackgroundAndGraticule() throws {
    let (_, _, engine) = try GPU.require()
    var s = ScopeSettings(kind: .waveform)
    s.display.showsGraticule = false
    s.display.backgroundOpacity = 1
    let accumulator = try engine.makeAccumulator(settings: s)
    let target = try makeTarget(width: 256, height: 128)
    try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
    XCTAssertTrue(pixels(target).allSatisfy { $0 == SIMD4(0, 0, 0, 255) })
  }

  /// One pixel among 8.3 million is visible on the rendered waveform at default settings.
  func testSinglePixelIsVisibleWhenRendered() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(
      .v210, width: 3840, height: 2160, codes: { x, y in x == 1920 && y == 100 ? SIMD3(900, 512, 512) : SIMD3(64, 512, 512) },
      mirror: false)
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformColumns = 1024
    s.waveformLevels = 512
    s.display.showsGraticule = false
    s.display.backgroundOpacity = 1
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let target = try makeTarget()
    try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
    let image = pixels(target)
    let signal: Double = (900.0 - 64) / 876
    let level = Int(((signal + 0.07) * 512 / 1.16).rounded(.down))
    let px: SIMD4<UInt8> = image[(511 - level) * 1024 + 512]
    XCTAssertGreaterThan(Int(px.y), 12, "a lone pixel still lights its bin")
  }

  func testHistogramAndVectorscopeRender() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(
      .rgba16Float, width: 640, height: 360, signal: SignalDescription(range: .full), rgb: { _, _ in SIMD3(0.75, 0, 0) })
    var h = ScopeSettings(kind: .histogram, stage: .source)
    h.histogramMode = .rgbOverlay
    h.histogramBins = 512
    h.display.backgroundOpacity = 1
    h.display.showsGraticule = false
    let histogram = try engine.makeAccumulator(settings: h)
    var v = ScopeSettings(kind: .vectorscope, stage: .source)
    v.display.backgroundOpacity = 1
    v.display.showsGraticule = false
    let vectorscope = try engine.makeAccumulator(settings: v)
    try GPU.run { cb in
      try histogram.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try vectorscope.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
    }
    XCTAssertEqual(histogram.statistics?.histogramPeak, SIMD3(UInt32(640 * 360), UInt32(640 * 360), UInt32(640 * 360)))
    let target = try makeTarget(width: 512, height: 256)
    try GPU.run { cb in try engine.makeRenderer().render(histogram, target: target, clear: true, into: cb) }
    var image = pixels(target)
    // Red at 0.75 → bin floor(0.82 · 512 / 1.16) = 361; green and blue at 0 → bin 30.
    XCTAssertGreaterThan(image[128 * 512 + 361].x, 100, "red column filled")
    XCTAssertLessThan(image[128 * 512 + 361].y, 60)
    XCTAssertGreaterThan(image[128 * 512 + 30].y, 100, "green and blue fill at black")
    XCTAssertEqual(image[128 * 512 + 200], SIMD4(0, 0, 0, 255), "empty level")

    let square = try makeTarget(width: 512, height: 512)
    try GPU.run { cb in try engine.makeRenderer().render(vectorscope, target: square, clear: true, into: cb) }
    image = pixels(square)
    let red = VectorscopeTarget.bars(matrix: .bt709, amplitude: 0.75)[0]
    let p = VectorscopeGeometry.plotPosition(cb: red.cb, cr: red.cr, zoom: 1)
    let x = Int((0.5 + p.x / 2) * 512), y = Int((0.5 - p.y / 2) * 512)
    let near = (-1...1).flatMap { dy in (-1...1).map { dx in image[(y + dy) * 512 + x + dx].y } }.max()!
    XCTAssertGreaterThan(near, 100, "75% red lands on its target")
    XCTAssertEqual(image[256 * 512 + 256], SIMD4(0, 0, 0, 255), "nothing at the centre")
  }

  /// A frame narrower than the column count leaves scope columns empty; they
  /// are never drawn as black stripes, at 1:1 or magnified.
  func testNarrowFrameDrawsNoEmptyColumns() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(.v210, width: 720, height: 486, codes: { _, _ in SIMD3(502, 512, 512) }, mirror: false)
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformColumns = 1024
    s.waveformLevels = 512
    s.display.showsGraticule = false
    s.display.backgroundOpacity = 1
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let signal: Double = 438.0 / 876
    let level = Int(((signal + 0.07) * 512 / 1.16).rounded(.down))
    for width in [1024, 2048, 1500] {
      let target = try makeTarget(width: width, height: 512)
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      let row = (0..<width).map { Int(image[(511 - level) * width + $0].y) }
      let lit = row.max()!
      XCTAssertGreaterThan(lit, 100, "\(width): the trace is drawn")
      XCTAssertGreaterThanOrEqual(row.min()!, lit * 9 / 10, "\(width) px: no dark column inside the flat trace")
    }
  }

  /// One lit bin stays visible however far the scope is minified, on both axes.
  func testLoneBinSurvivesMinification() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(
      .v210, width: 3840, height: 2160, codes: { x, y in x == 2201 && y == 100 ? SIMD3(900, 512, 512) : SIMD3(64, 512, 512) },
      mirror: false)
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformColumns = 1024
    s.waveformLevels = 512
    s.display.showsGraticule = false
    s.display.backgroundOpacity = 1
    s.display.gain = 4
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let column = 2201 * 1024 / 3840
    let signal: Double = (900.0 - 64) / 876
    let level = Int(((signal + 0.07) * 512 / 1.16).rounded(.down))
    for (width, height) in [(200, 100), (160, 64), (128, 50), (100, 40), (64, 32), (37, 23)] {
      let target = try makeTarget(width: width, height: height)
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      let x = Int((Double(column) + 0.5) / 1024 * Double(width)), y = Int((1 - (Double(level) + 0.5) / 512) * Double(height))
      var best = 0
      for dy in -1...1 {
        for dx in -1...1 where (0..<width).contains(x + dx) && (0..<height).contains(y + dy) {
          best = max(best, Int(image[(y + dy) * width + x + dx].y))
        }
      }
      XCTAssertGreaterThan(best, 12, "\(width)×\(height): a lone bin is visible")
    }
  }

  /// A minified parade at plot widths that do not divide by three: a lone bin
  /// in the first or last column of a channel still lights its own panel's
  /// edge pixels, in every panel (the panels own floor or ceil of width / 3).
  func testParadeEdgeBinsSurviveMinification() throws {
    let (_, _, engine) = try GPU.require()
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformMode = .rgbParade
    s.waveformColumns = 4096
    s.waveformLevels = 512
    s.display.showsGraticule = false
    s.display.backgroundOpacity = 1
    let n = s.normalized().waveformColumnsPerChannel
    // 100% white in the 100% level bin, floor(1.07 · 512 / 1.16) = 472.
    let level = 472
    for edge in [0, n - 1] {
      let frame = try TestFrame.make(
        .bgra8, width: n, height: 64, signal: SignalDescription(range: .full),
        rgb: { x, _ in x == edge ? SIMD3(repeating: 1) : .zero })
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      for width in [1000, 1001, 999, 1002, 320, 641] {
        let height = 200
        let target = try makeTarget(width: width, height: height)
        try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
        let image = pixels(target)
        let y = Int((1 - (Double(level) + 0.5) / 512) * Double(height))
        for panel in 0..<3 {
          // The panel's pixels: those whose centre falls in its third.
          let columns = (0..<width).filter { min(Int((Double($0) + 0.5) * 3 / Double(width)), 2) == panel }
          let near = edge == 0 ? Array(columns.prefix(2)) : Array(columns.suffix(2))
          var best = 0
          for x in near {
            for dy in -2...2 where (0..<height).contains(y + dy) {
              let p = image[(y + dy) * width + x]
              best = max(best, Int(p[panel]))
            }
          }
          XCTAssertGreaterThan(best, 100, "column \(edge) at \(width) px: panel \(panel) shows its edge bin")
        }
      }
    }
  }

  /// A minified vectorscope whose square plot sits a half pixel into the
  /// viewport: every lone bin still lights a pixel at its position.
  func testVectorscopeLoneBinsSurviveMinification() throws {
    let (_, _, engine) = try GPU.require()
    // Pure primaries and secondaries at 75%: six lone chroma points.
    let colors: [SIMD3<Float>] = [
      SIMD3(0.75, 0, 0), SIMD3(0, 0.75, 0), SIMD3(0, 0, 0.75), SIMD3(0.75, 0.75, 0), SIMD3(0, 0.75, 0.75),
      SIMD3(0.75, 0, 0.75),
    ]
    let frame = try TestFrame.make(
      .rgba16Float, width: 64, height: 6, signal: SignalDescription(range: .full), rgb: { x, y in x < 2 ? colors[y] : .zero })
    var s = ScopeSettings(kind: .vectorscope, stage: .source)
    s.vectorscopeSize = 2048
    s.display.backgroundOpacity = 1
    s.display.showsGraticule = false
    s.display.gain = 20
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let k = YCbCrMatrix.bt709.coefficients
    for (width, height) in [(501, 500), (334, 333), (257, 256), (100, 99), (61, 60)] {
      let target = try makeTarget(width: width, height: height)
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      let side = Double(min(width, height))
      let left = (Double(width) - side) / 2, top = (Double(height) - side) / 2
      for c in colors {
        let r = Double(c.x), g = Double(c.y), b = Double(c.z)
        let y = k.r * r + (1 - k.r - k.b) * g + k.b * b
        let p = VectorscopeGeometry.plotPosition(cb: (b - y) / (2 * (1 - k.b)), cr: (r - y) / (2 * (1 - k.r)), zoom: 1)
        let x = Int(left + (0.5 + p.x / 2) * side), row = Int(top + (0.5 - p.y / 2) * side)
        var best = 0
        for dy in -1...1 {
          for dx in -1...1 where (0..<width).contains(x + dx) && (0..<height).contains(row + dy) {
            best = max(best, Int(image[(row + dy) * width + x + dx].y))
          }
        }
        XCTAssertGreaterThan(best, 40, "\(width)×\(height): \(c) is visible")
      }
    }
  }

  /// A 4096-bin histogram of an 8-bit ramp drawn 512 px wide: every populated
  /// bin lights its pixel column, so no code drops out of the comb.
  func testHistogramSpikesSurviveMinification() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(
      .bgra8, width: 256, height: 16, signal: SignalDescription(range: .full),
      rgb: { x, _ in SIMD3(repeating: Float(x) / 255) })
    var s = ScopeSettings(kind: .histogram, stage: .source)
    s.histogramMode = .luma
    s.histogramBins = 4096
    s.display.showsGraticule = false
    s.display.backgroundOpacity = 1
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let bins = try readBins(accumulator)
    let target = try makeTarget(width: 512, height: 128)
    try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
    let image = pixels(target)
    let populated = bins.indices.filter { bins[$0] > 0 }
    XCTAssertEqual(populated.count, 256)
    let dark = populated.filter { image[64 * 512 + $0 / 8].x < 100 }
    XCTAssertTrue(dark.isEmpty, "\(dark.count) codes vanish, first bin \(dark.first ?? -1)")
  }

  /// Zoomed in, the vectorscope's circles and targets leave the square plot;
  /// nothing is drawn in a wide viewport's side margins.
  func testZoomedVectorscopeGraticuleStaysInsideThePlot() throws {
    let (_, _, engine) = try GPU.require()
    var s = ScopeSettings(kind: .vectorscope, stage: .source)
    s.vectorscopeZoom = 2
    s.display.backgroundOpacity = 0
    s.display.graticuleOpacity = 1
    let accumulator = try engine.makeAccumulator(settings: s)
    let target = try makeTarget(width: 800, height: 400)
    let renderer = engine.makeRenderer()
    try GPU.run { cb in try renderer.render(accumulator, target: target, clear: true, into: cb) }
    let image = pixels(target)
    var margin = 0, plot = 0
    for y in 0..<400 {
      for x in 0..<800 where image[y * 800 + x].w > 0 {
        if x < 200 || x >= 600 { margin += 1 } else { plot += 1 }
      }
    }
    XCTAssertGreaterThan(plot, 1000, "the graticule is drawn")
    XCTAssertEqual(margin, 0, "nothing in the margins")
  }

  func testInvalidViewportsThrow() throws {
    let (_, queue, engine) = try GPU.require()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    let renderer = engine.makeRenderer()
    let target = try makeTarget(width: 256, height: 128)
    let cb = try XCTUnwrap(queue.makeCommandBuffer())
    for viewport in [
      MonitorViewport(width: 0, height: 100), MonitorViewport(width: 100, height: -3),
      MonitorViewport(x: 200, y: 0, width: 100, height: 100), MonitorViewport(x: -1, y: 0, width: 10, height: 10),
    ] {
      XCTAssertThrowsError(try renderer.render(accumulator, target: target, viewport: viewport, into: cb), "\(viewport)")
    }
    XCTAssertThrowsError(
      try renderer.prepare(
        accumulator, viewport: MonitorViewport(width: 0, height: 0), targetPixelFormat: .rgba8Unorm, into: cb))
    var odd = MonitorViewport(width: 100, height: 50)
    odd.pixelsPerPoint = .nan
    XCTAssertEqual(odd.pixelsPerPoint, 1)
    try renderer.render(accumulator, target: target, viewport: odd, into: cb)
    let texture = renderer.graticuleTexture
    try renderer.render(accumulator, target: target, viewport: odd, into: cb)
    XCTAssertTrue(texture === renderer.graticuleTexture, "a NaN scale neither redraws nor reallocates")
    cb.commit()
    cb.waitUntilCompleted()
  }

  /// Rows of `image` (`width` wide) between columns `x0..<x1`, brightest first by channel `c`.
  func brightestRow(_ image: [SIMD4<UInt8>], width: Int, height: Int, columns: Range<Int>, channel c: Int) -> Int {
    var best = 0, row = 0
    for y in 0..<height {
      var sum = 0
      for x in columns { sum += Int(image[y * width + x][c]) }
      if sum > best { (best, row) = (sum, y) }
    }
    return row
  }

  /// Each parade panel draws its own channel: the R, G and B (or Y', Cb, Cr)
  /// panels light the row of that channel's bin, in that channel's colour. A
  /// swapped panel order fails here.
  func testParadePanelsDrawTheirOwnChannel() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(
      .bgra8, width: 600, height: 64, signal: SignalDescription(range: .full), rgb: { _, _ in SIMD3(0.8, 0.5, 0.2) })
    for mode in [WaveformMode.rgbParade, .ycbcrParade] {
      var s = ScopeSettings(kind: .waveform, stage: .source)
      s.waveformMode = mode
      s.waveformColumns = 600
      s.waveformLevels = 256
      s.display.showsGraticule = false
      s.display.backgroundOpacity = 1
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let bins = try readBins(accumulator)
      let layout = accumulator.layout
      let target = try makeTarget(width: 600, height: 256)
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      let colors = ScopeRenderer.colors(settings: s)
      let bases = [colors.0, colors.1, colors.2]
      for k in 0..<3 {
        // The level this channel's bins hold (every column alike).
        let level = try XCTUnwrap((0..<layout.rows).first { bins[layout.index(channel: k, row: $0, column: 10)] > 0 })
        let panel = (k * 200 + 20)..<(k * 200 + 180)
        // Panels of the strongest base component show it in that component.
        let component = (0..<3).max { bases[k][$0] < bases[k][$1] }!
        let row = brightestRow(image, width: 600, height: 256, columns: panel, channel: component)
        XCTAssertEqual(row, 255 - level, "\(mode) panel \(k): its channel's level")
        let px = image[row * 600 + panel.lowerBound + 50]
        XCTAssertGreaterThan(Int(px[component]), 150, "\(mode) panel \(k) lit")
        if mode == .rgbParade {
          // The panel's colour is its channel's: R, G or B dominates.
          for c in 0..<3 where c != k { XCTAssertGreaterThan(Int(px[k]), Int(px[c]), "\(mode) panel \(k) colour") }
        }
      }
    }
  }

  /// Histogram parade panels stack R, G, B from the top, each filled at its own
  /// channel's bin only; the logarithmic scale draws log(1 + n) / log(1 + peak).
  func testHistogramParadeAndLogarithmicHeights() throws {
    let (_, _, engine) = try GPU.require()
    // 3/4 of the pixels at one level, 1/16 at another, the rest at a third.
    let frame = try TestFrame.make(
      .bgra8, width: 256, height: 16, signal: SignalDescription(range: .full),
      rgb: { x, _ in
        x < 192 ? SIMD3(0.8, 0.5, 0.2) : (x < 208 ? SIMD3(0.3, 0.9, 0.6) : SIMD3(0.1, 0.1, 0.1))
      })
    for scale in HistogramScale.allCases {
      var s = ScopeSettings(kind: .histogram, stage: .source)
      s.histogramMode = .rgbParade
      s.histogramBins = 512
      s.display.histogramScale = scale
      s.display.showsGraticule = false
      s.display.backgroundOpacity = 1
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let bins = try readBins(accumulator)
      let peak = Double(try XCTUnwrap(accumulator.statistics).histogramPeak.max())
      XCTAssertEqual(peak, 192 * 16)
      let target = try makeTarget(width: 512, height: 300)
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      for k in 0..<3 {
        let populated = (0..<512).filter { bins[k * 512 + $0] > 0 }
        XCTAssertEqual(populated.count, 3, "\(scale) channel \(k)")
        for bin in populated {
          let count = Double(bins[k * 512 + bin])
          let height = scale == .logarithmic ? log(1 + count) / log(1 + peak) : count / peak
          // Filled pixels of panel k in this bin's column, counted from the panel's bottom.
          var filled = 0
          for y in (k * 100)..<((k + 1) * 100) where image[y * 512 + bin][k] > 40 { filled += 1 }
          XCTAssertEqual(Double(filled), height * 100, accuracy: 2, "\(scale) channel \(k) bin \(bin)")
          // The other panels stay dark in this column unless they hold the same bin.
          for other in 0..<3 where other != k && bins[other * 512 + bin] == 0 {
            XCTAssertLessThan(Int(image[(other * 100 + 99) * 512 + bin][other]), 40, "\(scale) panel \(other) bin \(bin)")
          }
        }
      }
    }
  }

  /// A colorized vectorscope shows each point in the hue it measures: the
  /// target of a flat 75% bar is drawn in that bar's colour, as the fragment
  /// shader's formula gives it at that pixel.
  func testColorizedVectorscopeShowsTheMeasuredHue() throws {
    let (_, _, engine) = try GPU.require()
    for bar in VectorscopeTarget.bars(matrix: .bt709, amplitude: 0.75) {
      let rgb = SIMD3(Float(bar.rgb.r), Float(bar.rgb.g), Float(bar.rgb.b))
      let frame = try TestFrame.make(
        .rgba16Float, width: 64, height: 64, signal: SignalDescription(range: .full), rgb: { _, _ in rgb })
      var s = ScopeSettings(kind: .vectorscope, stage: .source)
      s.display.trace = .colorized
      s.display.showsGraticule = false
      s.display.backgroundOpacity = 1
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let target = try makeTarget(width: 512, height: 512)
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      let lit = image.indices.filter { image[$0].x > 0 || image[$0].y > 0 || image[$0].z > 0 }
      XCTAssertFalse(lit.isEmpty, bar.name)
      for i in lit {
        let px = SIMD2(Double(i % 512) + 0.5, Double(i / 512) + 0.5)
        // mk_scopeFragment's colorized hue at this pixel, at full intensity (every pixel in one bin).
        let c = SIMD2(px.x / 512 * 2 - 1, 1 - px.y / 512 * 2) * VectorscopeGeometry.halfExtent
        let kr = 0.2126, kb = 0.0722, y = 0.5
        let r = y + 2 * (1 - kr) * c.y, b = y + 2 * (1 - kb) * c.x
        let hue = simd_max(SIMD3(r, (y - kr * r - kb * b) / (1 - kr - kb), b), .zero)
        let base = SIMD3(repeating: 1) + (hue / max(hue.max(), 1e-3) - 1) * min(1, simd_length(c) * 6)
        let expected = simd_min(base + (SIMD3(repeating: 1) - base) * 0.3, SIMD3(repeating: 1))
        for k in 0..<3 {
          XCTAssertEqual(Double(image[i][k]), expected[k] * 255, accuracy: 1.5, "\(bar.name) channel \(k) at \(px)")
        }
      }
    }
  }

  /// Neutral pixels (Cb = Cr = 0 exactly) draw on the plot centre, under the
  /// crosshair: symmetric about it on even plots, on its pixel on odd ones.
  func testNeutralFrameDrawsOnTheVectorscopeCentre() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.make(.v210, width: 128, height: 32, codes: { _, _ in SIMD3(502, 512, 512) })
    for (side, zoom, viewport) in [(512, 1, 512), (512, 1, 511), (256, 2, 1024), (2048, 4, 300), (64, 1, 1000)] {
      var s = ScopeSettings(kind: .vectorscope, stage: .source)
      s.vectorscopeSize = side
      s.vectorscopeZoom = zoom
      s.display.showsGraticule = false
      s.display.backgroundOpacity = 1
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let target = try makeTarget(width: viewport, height: viewport)
      try GPU.run { cb in try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb) }
      let image = pixels(target)
      var weight = 0.0, sum = SIMD2<Double>.zero
      for y in 0..<viewport {
        for x in 0..<viewport {
          let w = Double(image[y * viewport + x].y)
          weight += w
          sum += w * SIMD2(Double(x) + 0.5, Double(y) + 0.5)
        }
      }
      let label = "\(side) bins ×\(zoom) in \(viewport) px"
      XCTAssertGreaterThan(weight, 0, label)
      let centroid = sum / weight
      XCTAssertEqual(centroid.x, Double(viewport) / 2, accuracy: 0.01, label)
      XCTAssertEqual(centroid.y, Double(viewport) / 2, accuracy: 0.01, label)
    }
  }

  /// At a low level count, legal white and black trace on the 100% and 0%
  /// graticule lines, not a bin-fraction above or below them.
  func testExactLevelsTraceOnTheirGraticuleLines() throws {
    let (_, _, engine) = try GPU.require()
    for (code, value) in [(940, 100.0), (64, 0.0)] {
      let frame = try TestFrame.make(.v210, width: 256, height: 32, codes: { _, _ in SIMD3(code, 512, 512) })
      for levels in [64, 100, 512] {
        var s = ScopeSettings(kind: .waveform, stage: .source)
        s.waveformLevels = levels
        s.waveformColumns = 256
        s.display.showsGraticule = false
        s.display.backgroundOpacity = 1
        let accumulator = try engine.makeAccumulator(settings: s)
        try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
        let target = try makeTarget(width: 256, height: 1000)
        let renderer = engine.makeRenderer()
        try GPU.run { cb in try renderer.render(accumulator, target: target, clear: true, into: cb) }
        let image = pixels(target)
        var weight = 0.0, sum = 0.0
        for y in 0..<1000 {
          let w = Double(image[y * 256 + 128].y)
          weight += w
          sum += w * (Double(y) + 0.5)
        }
        let line = try XCTUnwrap(renderer.graticule.labels.first { $0.value == value }).position.y * 1000
        XCTAssertEqual(sum / weight, line, accuracy: 0.6, "code \(code), \(levels) levels")
      }
    }
  }
}
