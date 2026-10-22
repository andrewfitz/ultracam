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
    // The 100% line: y = (1 - 1.07 / 1.16) · 512 = 39.72 px.
    let line = image[39 * 1024 + 700], above = image[30 * 1024 + 700]
    XCTAssertGreaterThan(Int(line.x), 150, "an anti-aliased graticule line")
    XCTAssertEqual(above, SIMD4(0, 0, 0, 128), "background at half opacity, premultiplied")
    XCTAssertEqual(renderer.graticule.labels.count, 11)
    XCTAssertEqual(renderer.graticule.labels.first { $0.value == 100 }!.position.y * 512, 39.72, accuracy: 0.01)
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
}
