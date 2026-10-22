import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import Synchronization
import XCTest

@testable import MonitorKitScopes

/// The look of Ultracam's earlier MonitorTools scopes as options (a -10…110 IRE
/// level range, 768 × 256, the old parade colours), the defaults they leave
/// alone, and the warm-up API.
final class ScopeLegacyLookTests: XCTestCase {
  // MARK: defaults

  func testDefaultsAreUnchanged() {
    let s = ScopeSettings()
    XCTAssertEqual(s.levelRange, .standard)
    XCTAssertEqual(s.display.palette, .standard)
    XCTAssertEqual(s.waveformColumns, 1024)
    XCTAssertEqual(s.waveformLevels, 512)
    XCTAssertEqual(s.display.backgroundOpacity, 0.85)
    XCTAssertEqual(ScopeLevelAxis.low, -0.07)
    XCTAssertEqual(ScopeLevelAxis.high, 1.09)
    XCTAssertEqual(ScopeLevelRange.standard.low, ScopeLevelAxis.low)
    XCTAssertEqual(ScopeLevelRange.standard.high, ScopeLevelAxis.high)
    for bins in [64, 100, 256, 512, 2048] {
      for level in stride(from: -0.1, through: 1.12, by: 0.013) {
        XCTAssertEqual(
          ScopeLevelAxis.drawnFraction(ofLevel: level, bins: bins),
          ScopeLevelAxis.drawnFraction(ofLevel: level, bins: bins, range: .standard))
      }
    }
    XCTAssertEqual(
      WaveformScale.percent.ticks(range: .legal).map(\.value), stride(from: 0.0, through: 100, by: 10).map { $0 },
      "the default axis keeps 0…100")
    for scale in WaveformScale.allCases {
      for range in [CodeRange.legal, .full] {
        XCTAssertEqual(scale.ticks(range: range), scale.ticks(range: range, levelRange: .standard))
        XCTAssertEqual(scale.chromaTicks(range: range), scale.chromaTicks(range: range, levelRange: .standard))
      }
    }
    // Standard-palette colours are the shipped ones.
    var parade = ScopeSettings(kind: .waveform)
    parade.waveformMode = .rgbParade
    XCTAssertEqual(ScopeRenderer.colors(settings: parade).0, SIMD4(1, 0.18, 0.15, 1))
    XCTAssertEqual(ScopeRenderer.colors(settings: ScopeSettings()).0, SIMD4(0.45, 1, 0.55, 1))
  }

  func testLevelRanges() {
    XCTAssertEqual(ScopeLevelRange.minus10To110.low, -0.1)
    XCTAssertEqual(ScopeLevelRange.minus10To110.high, 1.1)
    XCTAssertEqual(ScopeLevelAxis.fraction(ofLevel: -0.1, range: .minus10To110), 0)
    XCTAssertEqual(ScopeLevelAxis.fraction(ofLevel: 1.1, range: .minus10To110), 1, accuracy: 1e-15)
    XCTAssertEqual(ScopeLevelAxis.fraction(ofLevel: 0.5, range: .minus10To110), 0.5, accuracy: 1e-15)
    XCTAssertEqual(ScopeLevelAxis.level(atFraction: 0.5, range: .minus10To110), 0.5, accuracy: 1e-15)
    for range in ScopeLevelRange.allCases {
      for f in [0.0, 0.25, 0.8, 1] {
        XCTAssertEqual(
          ScopeLevelAxis.fraction(ofLevel: ScopeLevelAxis.level(atFraction: f, range: range), range: range), f,
          accuracy: 1e-12)
      }
    }
  }

  // MARK: preset

  func testLegacyPreset() {
    let s = ScopeSettings.ultracamLegacy()
    XCTAssertEqual(s.kind, .waveform)
    XCTAssertEqual(s.stage, .output)
    XCTAssertEqual(s.waveformMode, .rgbParade)
    XCTAssertEqual(s.waveformColumns, ScopeSettings.ultracamLegacyImageWidth)
    XCTAssertEqual(s.waveformLevels, ScopeSettings.ultracamLegacyImageHeight)
    XCTAssertEqual(ScopeSettings.ultracamLegacyImageWidth, 768)
    XCTAssertEqual(ScopeSettings.ultracamLegacyImageHeight, 256)
    XCTAssertEqual(s.waveformColumnsPerChannel, 256, "MonitorTools drew 256 columns per parade channel")
    XCTAssertEqual(s.levelRange, .minus10To110)
    XCTAssertEqual(s.display.palette, .ultracamLegacy)
    XCTAssertEqual(s.display.backgroundOpacity, 1)
    XCTAssertEqual(s.normalized(), s)
    // Everything else is the default.
    var expected = ScopeSettings(kind: .waveform, stage: .output)
    expected.waveformMode = .rgbParade
    expected.waveformColumns = 768
    expected.waveformLevels = 256
    expected.levelRange = .minus10To110
    expected.display.palette = .ultracamLegacy
    expected.display.backgroundOpacity = 1
    XCTAssertEqual(s, expected)
    let luma = ScopeSettings.ultracamLegacy(mode: .luma, stage: .source)
    XCTAssertEqual(luma.waveformMode, .luma)
    XCTAssertEqual(luma.stage, .source)
    XCTAssertEqual(luma.waveformColumnsPerChannel, 768)
  }

  func testLevelRangeIsPartOfTheAccumulationButNotForTheVectorscope() {
    var a = ScopeSettings(kind: .waveform), b = a
    b.levelRange = .minus10To110
    XCTAssertNotEqual(a.accumulationKey, b.accumulationKey)
    a = ScopeSettings(kind: .histogram)
    b = a
    b.levelRange = .minus10To110
    XCTAssertNotEqual(a.accumulationKey, b.accumulationKey)
    a = ScopeSettings(kind: .vectorscope)
    b = a
    b.levelRange = .minus10To110
    XCTAssertEqual(a.accumulationKey, b.accumulationKey, "the vectorscope has no level axis")
    a = ScopeSettings()
    b = a
    b.display.palette = .ultracamLegacy
    XCTAssertEqual(a.accumulationKey, b.accumulationKey, "the palette is display only")
  }

  // MARK: Codable

  func testCodable() throws {
    let legacy = ScopeSettings.ultracamLegacy(mode: .luma, stage: .monitor)
    XCTAssertEqual(try JSONDecoder().decode(ScopeSettings.self, from: JSONEncoder().encode(legacy)), legacy)
    var histogram = ScopeSettings(kind: .histogram)
    histogram.levelRange = .minus10To110
    histogram.display.palette = .ultracamLegacy
    XCTAssertEqual(try JSONDecoder().decode(ScopeSettings.self, from: JSONEncoder().encode(histogram)), histogram)
    // Settings saved before these options decode with the standard look.
    var old = ScopeSettings(kind: .waveform, stage: .source)
    old.waveformMode = .rgbParade
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    object["levelRange"] = nil
    var display = try XCTUnwrap(object["display"] as? [String: Any])
    display["palette"] = nil
    object["display"] = display
    let decoded = try JSONDecoder().decode(ScopeSettings.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(decoded, old)
    XCTAssertEqual(decoded.levelRange, .standard)
    XCTAssertEqual(decoded.display.palette, .standard)
    // Unknown values fall back to the standard look.
    let json = #"{"schemaVersion": 1, "kind": "waveform", "levelRange": "minus20", "display": {"palette": 3}}"#
    let lenient = try JSONDecoder().decode(ScopeSettings.self, from: Data(json.utf8))
    XCTAssertEqual(lenient.levelRange, .standard)
    XCTAssertEqual(lenient.display.palette, .standard)
  }

  // MARK: graticule

  func testLegacyRangeTicks() {
    let ticks = WaveformScale.percent.ticks(range: .legal, levelRange: .minus10To110)
    XCTAssertEqual(ticks.map(\.value), stride(from: -10.0, through: 110, by: 10).map { $0 })
    XCTAssertEqual(ticks.first?.label, "-10")
    XCTAssertEqual(ticks.first?.level, -0.1)
    XCTAssertEqual(ticks.last?.level, 1.1)
    XCTAssertEqual(ticks.filter(\.isMajor).map(\.label), ["0", "50", "100"])
    // Codes 4 and 1019 are inside this axis, so nothing is snapped.
    let codes = WaveformScale.codeValues.ticks(range: .legal, levelRange: .minus10To110)
    XCTAssertEqual(codes.first { $0.value == 1019 }?.level ?? 0, 955.0 / 876, accuracy: 1e-12)
    XCTAssertEqual(codes.first { $0.value == 4 }?.level ?? 0, -60.0 / 876, accuracy: 1e-12)
  }

  /// MonitorTools' graticule marked -10, 0, 50, 100 and 110 IRE on rows 255,
  /// 234, 128, 21 and 0 from the top of a 256-row image. On 256 levels over
  /// -10…110 MonitorKit counts those levels in bins 0, 21, 128, 234 and 255
  /// (bin = ⌊(level + 0.1) · 256 / 1.2⌋), rows 255, 234, 127, 21 and 0: the old
  /// rows within one (50% is one row higher), and the graticule lines sit on
  /// those bins' centres.
  func testLegacyGraticuleMarksTheOldLevels() throws {
    let s = ScopeSettings.ultracamLegacy(mode: .luma)
    let g = ScopeGraticule(
      settings: s, context: ScopeContext(), viewportWidth: Double(ScopeSettings.ultracamLegacyImageWidth),
      viewportHeight: Double(ScopeSettings.ultracamLegacyImageHeight))
    let expected: [(Double, Int)] = [(-10, 0), (0, 21), (50, 128), (100, 234), (110, 255)]
    for (value, bin) in expected {
      let label = try XCTUnwrap(g.labels.first { $0.role == .tick && $0.value == value }, "\(value)")
      XCTAssertEqual(label.position.y, 1 - (Double(bin) + 0.5) / 256, accuracy: 1e-12, "\(value)%")
    }
  }

  /// MonitorTools binned level v as ⌊f · 255⌋ of f = clamp((v + 0.1) / 1.2, 0, 1)
  /// (`scopeBin`, MonitorTools.metal.txt) and drew bin b on row 255 - b. The
  /// legacy preset's uniform ⌊f · 256⌋ bins agree or sit one bin higher, never
  /// more: within one row of the old image, not identical to it.
  func testLegacyBinsAreWithinOneRowOfMonitorTools() {
    func oldBin(_ v: Double) -> Int { Int(Float(min(1, max(0, (Float(v) + 0.1) / 1.2))) * 255) }
    func newBin(_ v: Double) -> Int {
      Int(ScopeLevelAxis.drawnFraction(ofLevel: v, bins: 256, range: .minus10To110) * 256)
    }
    var differ = 0
    for level in stride(from: -0.2, through: 1.2, by: 0.0007) {
      let d = newBin(level) - oldBin(level)
      XCTAssertTrue(d == 0 || d == 1, "\(level): \(newBin(level)) vs \(oldBin(level))")
      if d == 1 { differ += 1 }
    }
    XCTAssertGreaterThan(differ, 0, "not identical")
    // The old graticule levels: 50% and 100% white differ by one bin.
    XCTAssertEqual([-0.1, 0, 0.5, 1, 1.1].map(oldBin), [0, 21, 127, 233, 255])
    XCTAssertEqual([-0.1, 0, 0.5, 1, 1.1].map(newBin), [0, 21, 128, 234, 255])
  }

  // MARK: GPU

  /// The legacy graticule raster at the old image size: each horizontal line
  /// of the -10…110 axis peaks on the row of its level's bin, 255 - bin from
  /// the top (rows 255, 234, 127, 21 and 0 for -10, 0, 50, 100 and 110%), and
  /// rows between the lines are empty.
  func testLegacyGraticuleRasterSitsOnThePredictedRows() throws {
    let (device, _, engine) = try GPU.require()
    let w = ScopeSettings.ultracamLegacyImageWidth, h = ScopeSettings.ultracamLegacyImageHeight
    var s = ScopeSettings.ultracamLegacy(mode: .luma, stage: .source)
    s.display.graticuleOpacity = 1
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, seed: 4, mirror: false)
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let target = try makeTexture(device, .bgra8Unorm, w, h)
    let renderer = engine.makeRenderer()
    try GPU.run { cb in try renderer.render(accumulator, target: target, clear: true, into: cb) }
    XCTAssertEqual(renderer.graticule.plot, SIMD4(0, 0, 1, 1), "the plot fills the viewport")
    let texture = try XCTUnwrap(renderer.graticuleTexture)
    XCTAssertGreaterThanOrEqual(texture.width, w)
    XCTAssertGreaterThanOrEqual(texture.height, h)
    let bytes = try privateBytes(texture)
    // The column with the least coverage: no vertical line crosses it.
    var column = 0, least = Int.max
    for x in 1..<(w - 1) {
      var total = 0
      for y in 0..<h { total += Int(bytes[y * texture.width + x]) }
      if total < least { (column, least) = (x, total) }
    }
    let profile = (0..<h).map { Int(bytes[$0 * texture.width + column]) }
    let ticks = WaveformScale.percent.ticks(range: .legal, levelRange: .minus10To110)
    XCTAssertEqual(ticks.count, 13)
    var rows: [Double: Int] = [:]
    for tick in ticks {
      let bin = Int(ScopeLevelAxis.drawnFraction(ofLevel: tick.level, bins: h, range: .minus10To110) * Double(h))
      let row = h - 1 - bin
      rows[tick.value] = row
      XCTAssertGreaterThan(profile[row], 100, "\(tick.value)% line on row \(row): \(profile)")
      if row > 0 { XCTAssertGreaterThan(profile[row], profile[row - 1], "\(tick.value)% peaks on row \(row)") }
      if row < h - 1 { XCTAssertGreaterThan(profile[row], profile[row + 1], "\(tick.value)% peaks on row \(row)") }
    }
    XCTAssertEqual([-10.0, 0, 50, 100, 110].map { rows[$0] ?? -1 }, [255, 234, 127, 21, 0])
    // Rows two or more from every line carry no graticule.
    for y in 0..<h where !rows.values.contains(where: { abs($0 - y) <= 1 }) {
      XCTAssertEqual(profile[y], 0, "row \(y)")
    }
  }

  /// Neutral levels across the -10…110 axis land in the bins the CPU model
  /// (`ScopeLevelAxis.drawnFraction(…, range:)`) predicts, the same Float
  /// arithmetic as `mk_levelBin`; levels beyond it land in the end bins.
  func testLegacyRangeBins() throws {
    let (_, _, engine) = try GPU.require()
    let levels: [Float] = [-0.2, -0.1, -0.05, 0, 0.25, 0.5, 0.75, 1, 1.05, 1.1, 1.3]
    let width = 256
    let frame = try TestFrame.make(
      .rgba16Float, width: width, height: 8,
      rgb: { x, _ in SIMD3(repeating: levels[x * levels.count / width]) })
    for kind in [ScopeKind.waveform, .histogram] {
      var s = ScopeSettings(kind: kind, stage: .source)
      s.waveformMode = .luma
      s.histogramMode = .luma
      s.waveformColumns = width
      s.waveformLevels = 256
      s.histogramBins = 256
      s.levelRange = .minus10To110
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let bins = try readBins(accumulator)
      var expected = [UInt32](repeating: 0, count: bins.count)
      for y in 0..<8 {
        for x in 0..<width {
          let v = frame.rgb[y * width + x].x
          let f = ScopeLevelAxis.drawnFraction(ofLevel: Double(v), bins: 256, range: .minus10To110)
          let bin = Int(f * 256)
          expected[kind == .waveform ? bin * width + x : bin] += 1
        }
      }
      XCTAssertEqual(bins, expected, "\(kind)")
      // The legacy graticule's levels, as Float16 frame values.
      func bin(_ level: Float) -> Int {
        Int(ScopeLevelAxis.drawnFraction(ofLevel: Double(Float(Float16(level))), bins: 256, range: .minus10To110) * 256)
      }
      XCTAssertEqual([-0.1, 0, 0.5, 1, 1.1].map(bin), [0, 21, 128, 234, 255])
      XCTAssertEqual(bin(-0.2), 0)
      XCTAssertEqual(bin(1.3), 255)
    }
  }

  /// The same frame on both ranges: identical statistics (they never depend on
  /// the bins), different bins.
  func testLevelRangeLeavesStatisticsAlone() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, seed: 3)
    var standard = ScopeSettings(kind: .waveform, stage: .source)
    standard.waveformColumns = 256
    standard.waveformLevels = 256
    var legacy = standard
    legacy.levelRange = .minus10To110
    let a = try engine.makeAccumulator(settings: standard), b = try engine.makeAccumulator(settings: legacy)
    try GPU.run { cb in
      try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try b.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
    }
    XCTAssertEqual(statisticsWords(a), statisticsWords(b))
    XCTAssertNotEqual(try readBins(a), try readBins(b))
    XCTAssertEqual(try readBins(a).reduce(0, +), try readBins(b).reduce(0, +))
  }

  func testLegacyPaletteColours() {
    let parade = ScopeSettings.ultracamLegacy()
    let c = ScopeRenderer.colors(settings: parade)
    XCTAssertEqual(c.0, SIMD4(1, 0.1, 0.1, 1))
    XCTAssertEqual(c.1, SIMD4(0.1, 1, 0.1, 1))
    XCTAssertEqual(c.2, SIMD4(0.1, 0.3, 1, 1))
    XCTAssertEqual(ScopeRenderer.colors(settings: .ultracamLegacy(mode: .luma)).0, SIMD4(1, 1, 1, 1))
    var histogram = ScopeSettings(kind: .histogram)
    histogram.display.palette = .ultracamLegacy
    XCTAssertEqual(ScopeRenderer.colors(settings: histogram).2, SIMD4(0.1, 0.3, 1, 1))
    var vector = ScopeSettings(kind: .vectorscope)
    let standardVector = ScopeRenderer.colors(settings: vector)
    vector.display.palette = .ultracamLegacy
    XCTAssertEqual(ScopeRenderer.colors(settings: vector).0, standardVector.0, "the vectorscope keeps its colours")
  }

  /// A flat grey parade drawn with the legacy palette: each panel's trace is
  /// its channel colour scaled by intensity, without the standard bloom
  /// towards white, as MonitorTools drew it.
  func testLegacyParadeDrawsTheOldColoursWithoutBloom() throws {
    let (device, _, engine) = try GPU.require()
    let frame = try TestFrame.make(.v210, width: 768, height: 64, codes: { _, _ in SIMD3(502, 512, 512) })
    func panels(_ palette: ScopeTracePalette) throws -> [SIMD3<Float>] {
      var s = ScopeSettings.ultracamLegacy(stage: .source)
      s.display.palette = palette
      s.display.showsGraticule = false
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let target = try makeTexture(device, .rgba32Float, 768, 256)
      let renderer = engine.makeRenderer()
      try GPU.run { cb in try renderer.render(accumulator, target: target, clear: true, into: cb) }
      let image = floatPixels(target)
      // The brightest pixel of each panel's middle column.
      return (0..<3).map { k in
        let x = k * 256 + 128
        var best = SIMD3<Float>.zero
        for y in 0..<256 {
          let p = image[y * 768 + x]
          let rgb = SIMD3(p.x, p.y, p.z)
          if rgb.max() > best.max() { best = rgb }
        }
        return best
      }
    }
    let legacy = try panels(.ultracamLegacy)
    let bases: [SIMD3<Float>] = [SIMD3(1, 0.1, 0.1), SIMD3(0.1, 1, 0.1), SIMD3(0.1, 0.3, 1)]
    for k in 0..<3 {
      let i = legacy[k].max()
      XCTAssertGreaterThan(i, 0.5, "panel \(k) has a trace")
      let expected = bases[k] * i
      for c in 0..<3 { XCTAssertEqual(legacy[k][c], expected[c], accuracy: 1e-5, "panel \(k) channel \(c)") }
    }
    // The standard palette blooms: a full-intensity red trace is pinker than 1 : 0.1.
    let standard = try panels(.standard)
    XCTAssertGreaterThan(standard[0].y / standard[0].x, 0.2)
  }

  // MARK: warm-up

  func testPrepareWarmsTheDrawableFormats() throws {
    let (device, queue, _) = try GPU.require()
    XCTAssertEqual(ScopeEngine.drawablePixelFormats, [.bgr10a2Unorm, .rgba16Float, .bgra8Unorm])
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    for format in ScopeEngine.drawablePixelFormats { XCTAssertFalse(engine.isPrepared(pixelFormat: format)) }
    try engine.prepare(pixelFormats: ScopeEngine.drawablePixelFormats)
    for format in ScopeEngine.drawablePixelFormats { XCTAssertTrue(engine.isPrepared(pixelFormat: format), "\(format)") }
    XCTAssertTrue(engine.isPrepared(target: MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float)))
    XCTAssertFalse(engine.isPrepared(pixelFormat: .rgba32Float))
    XCTAssertEqual(engine.specializedPipelineCount.render, 0, "general pipelines only")
    try engine.prepare()
    XCTAssertEqual(engine.specializedPipelineCount.render, 0)
    // With settings: every format's specialized pipeline, so the first draws compile nothing.
    let settings = [ScopeSettings.ultracamLegacy(), ScopeSettings(kind: .vectorscope)]
    try engine.prepare(settings: settings, layouts: [.v210], pixelFormats: ScopeEngine.drawablePixelFormats)
    let built = engine.specializedPipelineCount
    XCTAssertEqual(built.render, 2 * ScopeEngine.drawablePixelFormats.count)
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, seed: 1, mirror: false)
    for format in ScopeEngine.drawablePixelFormats {
      let target = try makeTexture(device, format, 768, 256)
      for s in settings {
        let a = try engine.makeAccumulator(settings: s), r = engine.makeRenderer()
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try r.render(a, target: target, clear: true, into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        XCTAssertTrue(r.isReady, "\(format) \(s.kind)")
      }
    }
    XCTAssertEqual(engine.specializedPipelineCount.render, built.render, "drawing compiled nothing new")
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty, "\(engine.pipelineBuildFailures)")
  }

  /// Warm-up that finds an asynchronous build of its pipeline running waits
  /// for that build to land (or fail) instead of compiling it again. The
  /// build's completion is played here, as Metal's compiler thread would.
  func testPrepareWaitsForAPendingBuild() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let donor = try ScopeEngine(device: device, specialization: .synchronous)
    // Formats init never starts, so only this test's builds are pending.
    let ok = MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float)
    let bad = MonitorRenderTargetFormat(colorPixelFormat: .rg16Float)
    for target in [ok, bad] {
      _ = engine.pendingRender.withLock { $0.insert(ScopeEngine.RenderKey(target: target, scope: nil)) }
    }
    let finished = Mutex<[String: Bool]>([:])
    func start(_ name: String, _ target: MonitorRenderTargetFormat) -> Thread {
      let t = Thread {
        let thrown = (try? engine.prepare(target: target)) == nil
        finished.withLock { $0[name] = thrown }
      }
      t.start()
      return t
    }
    _ = start("ok", ok)
    _ = start("bad", bad)
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertTrue(finished.withLock { $0.isEmpty }, "both wait for their builds")
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.render }, 0)

    let state = try donor.renderPipeline(ScopeEngine.RenderKey(target: ok, scope: nil))
    engine.built(state, for: ScopeEngine.RenderKey(target: ok, scope: nil))
    engine.failed(ScopeEngine.RenderKey(target: bad, scope: nil), nil)
    let deadline = Date().addingTimeInterval(10)
    while finished.withLock({ $0.count }) < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    XCTAssertEqual(finished.withLock { $0 }, ["ok": false, "bad": true], "the build landed; the failure is thrown")
    XCTAssertTrue(engine.isPrepared(target: ok))
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.render }, 0, "nothing compiled twice")
  }

  /// The same for a compute kernel `prepare(settings:…)` finds building.
  func testPrepareWaitsForAPendingKernel() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let donor = try ScopeEngine(device: device, specialization: .synchronous)
    let s = ScopeSettings(kind: .histogram)
    let key = ScopeEngine.ComputeKey(kernel: .histogram, layout: PixelLayout.uyvy8.scopeLayoutCode)
    _ = engine.pendingCompute.withLock { $0.insert(key) }
    let done = Mutex(false)
    Thread {
      try? engine.prepare(settings: [s], layouts: [.uyvy8], pixelFormat: nil)
      done.withLock { $0 = true }
    }.start()
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertFalse(done.withLock { $0 })
    engine.built(try donor.computePipeline(key), for: key)
    let deadline = Date().addingTimeInterval(10)
    while !done.withLock({ $0 }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    XCTAssertTrue(done.withLock { $0 })
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.compute }, 0, "nothing compiled twice")
  }

  /// `prepare()` right after making an asynchronous engine waits for the
  /// builds init started instead of compiling them again on this thread.
  func testAsynchronousPrepareJoinsTheBuildsAlreadyRunning() throws {
    let (device, _, _) = try GPU.require()
    for _ in 0..<3 {
      let engine = try ScopeEngine(device: device, specialization: .asynchronous)
      try engine.prepare()
      for format in ScopeEngine.drawablePixelFormats {
        XCTAssertTrue(engine.isPrepared(pixelFormat: format), "\(format)")
      }
      XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.render }, 0, "nothing compiled twice")
      // A format init does not prewarm is built here.
      try engine.prepare(pixelFormats: [.rgba32Float])
      XCTAssertTrue(engine.isPrepared(pixelFormat: .rgba32Float))
      XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.render }, 1)
      XCTAssertTrue(engine.pipelineBuildFailures.isEmpty, "\(engine.pipelineBuildFailures)")
    }
  }

  /// A group's `prepare(layouts:)` on a `.off` engine joins the all-tools fused
  /// kernels init started instead of compiling them again.
  func testOffEngineGroupPrepareJoinsTheFusedBuilds() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .off)
    let members = try [ScopeKind.waveform, .histogram, .vectorscope].map {
      try engine.makeAccumulator(settings: ScopeSettings(kind: $0))
    }
    let group = try engine.makeGroup(members)
    try group.prepare(layouts: [.v210, .uyvy8])
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.compute }, 0, "nothing compiled twice")
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty, "\(engine.pipelineBuildFailures)")
  }

  /// A format whose pipeline failed does not stop the formats after it.
  func testPrepareTriesEveryFormatAfterAFailure() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    let broken = MonitorRenderTargetFormat(colorPixelFormat: .bgr10a2Unorm)
    _ = engine.failedRender.withLock { $0.insert(ScopeEngine.RenderKey(target: broken, scope: nil)) }
    XCTAssertThrowsError(try engine.prepare())
    XCTAssertFalse(engine.isPrepared(pixelFormat: .bgr10a2Unorm))
    XCTAssertTrue(engine.isPrepared(pixelFormat: .rgba16Float))
    XCTAssertTrue(engine.isPrepared(pixelFormat: .bgra8Unorm))

    // With settings: every other format and setting is still prepared.
    let other = try ScopeEngine(device: device, specialization: .synchronous)
    let parade = ScopeSettings.ultracamLegacy()
    let variant = ScopeEngine.DrawVariant(kind: parade.kind.shaderCode, mode: parade.shaderMode)
    _ = other.failedRender.withLock { $0.insert(ScopeEngine.RenderKey(target: broken, scope: variant)) }
    let settings = [parade, ScopeSettings(kind: .vectorscope)]
    XCTAssertThrowsError(
      try other.prepare(settings: settings, layouts: [.v210], pixelFormats: ScopeEngine.drawablePixelFormats))
    XCTAssertEqual(other.specializedPipelineCount.render, 2 * 3 - 1, "all but the failed one")
    for format in ScopeEngine.drawablePixelFormats { XCTAssertTrue(other.isPrepared(pixelFormat: format), "\(format)") }
  }

  /// `prepare()` removes compiler waits from draws on `.off` engines; a
  /// `.synchronous` engine still builds each scope's specialized pipeline on
  /// its first draw unless `prepare(settings:…)` built it.
  func testWhatPrepareLeavesToTheFirstDraw() throws {
    let (device, queue, _) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, seed: 5, mirror: false)
    var parade = ScopeSettings(kind: .waveform, stage: .source)
    parade.waveformMode = .rgbParade
    func draw(_ engine: ScopeEngine) throws {
      let target = try makeTexture(device, .bgra8Unorm, 768, 256)
      let a = try engine.makeAccumulator(settings: parade), r = engine.makeRenderer()
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try r.render(a, target: target, clear: true, into: cb)
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertNil(cb.error)
      XCTAssertTrue(r.isReady)
    }
    let off = try ScopeEngine(device: device, specialization: .off)
    try off.prepare()
    let offBuilt = off.builtOnCallerThread.withLock { $0.render }
    try draw(off)
    XCTAssertEqual(off.builtOnCallerThread.withLock { $0.render }, offBuilt, ".off: the draw compiled nothing")

    let sync = try ScopeEngine(device: device, specialization: .synchronous)
    try sync.prepare()
    XCTAssertEqual(sync.specializedPipelineCount.render, 0)
    try draw(sync)
    XCTAssertEqual(sync.specializedPipelineCount.render, 1, ".synchronous: the first draw built its scope's pipeline")

    let warmed = try ScopeEngine(device: device, specialization: .synchronous)
    try warmed.prepare(settings: [parade], layouts: [.v210], pixelFormats: [.bgra8Unorm])
    let built = warmed.builtOnCallerThread.withLock { $0 }
    try draw(warmed)
    let after = warmed.builtOnCallerThread.withLock { $0 }
    XCTAssertEqual(after.render, built.render, "prepare(settings:…) left the draw nothing to build")
    XCTAssertEqual(after.compute, built.compute)
  }

  /// An asynchronous engine starts the drawable formats at init and reports them once built.
  func testAsynchronousEngineReportsItsPrewarmedFormats() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let deadline = Date().addingTimeInterval(20)
    while !ScopeEngine.drawablePixelFormats.allSatisfy({ engine.isPrepared(pixelFormat: $0) }) && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    for format in ScopeEngine.drawablePixelFormats { XCTAssertTrue(engine.isPrepared(pixelFormat: format), "\(format)") }
    try engine.prepare()
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty, "\(engine.pipelineBuildFailures)")
  }

  /// `prepareMetal4()` makes each object's argument table up front; the first
  /// Metal 4 encode then uses that table and makes no other.
  func testPrepareMetal4MakesTheArgumentTablesUpFront() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, seed: 2, mirror: false)
    m.resident(frame.frame)
    let target = try m.target(768, 256, format: .bgr10a2Unorm)
    let accumulator = try engine.makeAccumulator(settings: .ultracamLegacy())
    let members = try [ScopeSettings(kind: .histogram), ScopeSettings(kind: .vectorscope)].map {
      try engine.makeAccumulator(settings: $0)
    }
    let group = try engine.makeGroup(members)
    let renderer = engine.makeRenderer()
    XCTAssertNil(accumulator.metal4Table)
    XCTAssertNil(group.metal4Table)
    XCTAssertNil(renderer.metal4Table)
    try accumulator.prepareMetal4()
    try group.prepareMetal4()
    try renderer.prepareMetal4()
    let tables = try [
      XCTUnwrap(accumulator.metal4Table), XCTUnwrap(group.metal4Table), XCTUnwrap(renderer.metal4Table),
      XCTUnwrap(members[0].metal4Table), XCTUnwrap(members[1].metal4Table),
    ].map { ObjectIdentifier($0 as AnyObject) }
    try accumulator.prepareMetal4()
    try group.prepareMetal4()
    try renderer.prepareMetal4()
    try m.run { s in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: s)
      try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: s)
      try renderer.render(accumulator, target: target, clear: true, into: s)
    }
    let after = try [
      XCTUnwrap(accumulator.metal4Table), XCTUnwrap(group.metal4Table), XCTUnwrap(renderer.metal4Table),
      XCTUnwrap(members[0].metal4Table), XCTUnwrap(members[1].metal4Table),
    ].map { ObjectIdentifier($0 as AnyObject) }
    XCTAssertEqual(after, tables, "the encodes used the prepared tables")
  }
}

/// The timing tests' re-measure helper: at most `rounds` measurements, stopping
/// at the first that meets its budget, returning the last one taken.
final class ScopeRemeasureTests: XCTestCase {
  func testStopsAtTheFirstPassingRound() {
    var calls = 0
    let value = remeasured("test", { () -> Int in
      calls += 1
      return calls
    }, until: { $0 >= 2 })
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(value, 2)
  }

  func testMeasuresAtMostThreeTimes() {
    var calls = 0
    let value = remeasured("test", { () -> Int in
      calls += 1
      return calls
    }, until: { _ in false })
    XCTAssertEqual(calls, 3)
    XCTAssertEqual(value, 3, "the last round is returned for the caller's assertion")
    calls = 0
    _ = remeasured("test", { () -> Int in
      calls += 1
      return calls
    }, until: { _ in true })
    XCTAssertEqual(calls, 1, "a passing first round is not measured again")
  }
}
