import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// GPU bins against a CPU reference that mirrors the shader's Float math.
final class ScopeAccumulationTests: XCTestCase {
  struct LUTs {
    var burn: MonitorLUT?
    var monitor: MonitorLUT?
  }

  func accumulate(_ settings: ScopeSettings, _ frame: TestFrame, luts: LUTs = LUTs()) throws
    -> (ScopeAccumulator, [UInt32])
  {
    let (_, _, engine) = try GPU.require()
    let accumulator = try engine.makeAccumulator(settings: settings)
    try GPU.run { cb in
      try accumulator.accumulate(frame.frame, burnInLUT: luts.burn, monitorLUT: luts.monitor, into: cb)
    }
    return (accumulator, try readBins(accumulator))
  }

  /// The stage value of each pixel, as the kernel computes it.
  static func stageRGB(_ rgb: SIMD3<Float>, _ p: ScopeKernelParameters, _ luts: LUTs) -> SIMD3<Float> {
    var v = rgb
    if p.luts.x != 0, let lut = luts.burn { v = lut.cube.apply(v, interpolation: lut.interpolation) }
    if p.luts.y != 0, let lut = luts.monitor { v = lut.cube.apply(v, interpolation: lut.interpolation) }
    return v
  }

  static func reference(
    _ accumulator: ScopeAccumulator, _ frame: TestFrame, luts: LUTs = LUTs(), epsilon: Float = 2e-3
  ) -> BinReference {
    let s = accumulator.settings
    let p = accumulator.kernelParameters(
      settings: s, frame: frame.frame, burnInLUT: luts.burn, monitorLUT: luts.monitor, generation: 1)
    let layout = accumulator.layout
    var reference = BinReference(count: layout.binCount)
    for y in 0..<frame.height {
      for x in 0..<frame.width {
        let rgb = stageRGB(frame.rgb[y * frame.width + x], p, luts)
        let luma = p.scopeLuma(rgb, transport: frame.luma[y * frame.width + x])
        switch s.kind {
        case .waveform:
          let column = (x * layout.columns) / frame.width
          let values: SIMD3<Float>
          switch s.waveformMode {
          case .luma: values = SIMD3(repeating: luma)
          case .ycbcrParade: values = SIMD3(luma, (rgb.z - luma) * p.chroma.x + 0.5, (rgb.x - luma) * p.chroma.y + 0.5)
          case .rgbOverlay, .rgbParade: values = rgb
          }
          for k in 0..<layout.channels {
            let v = values[k]
            let l = BinReference.candidates((v - p.level.x) * p.level.y, layout.rows, epsilon: epsilon, clamp: true)
            reference.add((k * layout.rows + l.0) * layout.columns + column, (k * layout.rows + l.1) * layout.columns + column)
          }
        case .histogram:
          let values = s.histogramMode == .luma ? SIMD3(repeating: luma) : rgb
          for k in 0..<layout.channels {
            let v = values[k]
            let b = BinReference.candidates((v - p.level.x) * p.level.y, layout.columns, epsilon: epsilon, clamp: true)
            reference.add(k * layout.columns + b.0, k * layout.columns + b.1)
          }
        case .vectorscope:
          let cb = (rgb.z - luma) * p.chroma.x, cr = (rgb.x - luma) * p.chroma.y
          let n = layout.columns
          reference.add(
            x: BinReference.candidates(cb * p.chroma.z + p.chroma.w, n, epsilon: epsilon, clamp: false),
            y: BinReference.candidates(cr * p.chroma.z + p.chroma.w, n, epsilon: epsilon, clamp: false), n: n)
        }
      }
    }
    return reference
  }

  func check(
    _ settings: ScopeSettings, _ frame: TestFrame, luts: LUTs = LUTs(), epsilon: Float = 2e-3, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let (accumulator, bins) = try accumulate(settings, frame, luts: luts)
    let reference = Self.reference(accumulator, frame, luts: luts, epsilon: epsilon)
    reference.check(bins, label, file: file, line: line)
    let stats = try XCTUnwrap(accumulator.statistics, label, file: file, line: line)
    XCTAssertEqual(stats.pixelCount, frame.width * frame.height, "\(label): every pixel counted", file: file, line: line)
  }

  // MARK: every scope × every layout family

  func testWaveformLumaEveryLayout() throws {
    for kind in TestFrame.Kind.all {
      let frame = try TestFrame.natural(kind, width: 251, height: 37, seed: 7)
      var s = ScopeSettings(kind: .waveform, stage: .source)
      s.waveformColumns = 128
      s.waveformLevels = 256
      try check(s, frame, "waveform luma \(kind)")
    }
  }

  func testWaveformModesEveryLayout() throws {
    for kind in TestFrame.Kind.all {
      let frame = try TestFrame.natural(kind, width: 198, height: 41, seed: 3)
      for mode in [WaveformMode.rgbOverlay, .rgbParade, .ycbcrParade] {
        var s = ScopeSettings(kind: .waveform, stage: .source)
        s.waveformMode = mode
        s.waveformColumns = 300
        s.waveformLevels = 200
        try check(s, frame, "waveform \(mode) \(kind)")
      }
    }
  }

  func testHistogramEveryLayout() throws {
    for kind in TestFrame.Kind.all {
      let frame = try TestFrame.natural(kind, width: 301, height: 45, seed: 11)
      for mode in HistogramMode.allCases {
        var s = ScopeSettings(kind: .histogram, stage: .source)
        s.histogramMode = mode
        s.histogramBins = 1000
        try check(s, frame, "histogram \(mode) \(kind)")
      }
    }
  }

  func testVectorscopeEveryLayoutAndZoom() throws {
    for kind in TestFrame.Kind.all {
      let frame = try TestFrame.natural(kind, width: 233, height: 29, seed: 5)
      for zoom in [1, 2, 4] {
        var s = ScopeSettings(kind: .vectorscope, stage: .source)
        s.vectorscopeZoom = zoom
        s.vectorscopeSize = 256
        try check(s, frame, "vectorscope ×\(zoom) \(kind)")
      }
    }
  }

  /// Full-range Y'CbCr on every Y'CbCr layout and depth (8, 10, 12, 16 bits), through every scope.
  func testEveryScopeOnFullRangeYCbCr() throws {
    let signal = SignalDescription(range: .full)
    for kind in TestFrame.Kind.ycbcr {
      let frame = try TestFrame.natural(kind, width: 157, height: 31, seed: 21, signal: signal)
      var settings: [ScopeSettings] = []
      for mode in WaveformMode.allCases {
        var s = ScopeSettings(kind: .waveform, stage: .source)
        s.waveformMode = mode
        s.waveformColumns = 180
        s.waveformLevels = 300
        settings.append(s)
      }
      var h = ScopeSettings(kind: .histogram, stage: .source)
      h.histogramMode = .rgbParade
      h.histogramBins = 700
      var v = ScopeSettings(kind: .vectorscope, stage: .source)
      v.vectorscopeSize = 256
      v.vectorscopeZoom = 2
      for s in settings + [h, v] {
        let label = "full \(kind) \(s.kind) \(s.waveformMode)"
        try check(s, frame, label)
        XCTAssertEqual(try accumulate(s, frame).0.context.range, .full, label)
      }
    }
  }

  /// Several strips and bands, 32-bit device bins (more than 65535 pixels
  /// per scope column) and the BT.2020 matrix.
  func testLargeFrameMultipleTiles() throws {
    let signal = SignalDescription(range: .legal, matrix: .bt2020)
    let frame = try TestFrame.natural(.v210, width: 1280, height: 720, seed: 9, signal: signal)
    let (_, _, engine) = try GPU.require()
    var waveform = ScopeSettings(kind: .waveform, stage: .source)
    waveform.waveformColumns = 64
    waveform.waveformLevels = 1024
    let accumulator = try engine.makeAccumulator(settings: waveform)
    // A UHD-tall frame would need 32-bit bins; force that path here.
    accumulator.packedBinLimit = 1000
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertEqual(accumulator.layout.bytesPerBin, 4)
    Self.reference(accumulator, frame).check(try readBins(accumulator), "32-bit waveform")

    waveform.waveformColumns = 640
    waveform.waveformMode = .ycbcrParade
    let (packed, packedBins) = try accumulate(waveform, frame)
    XCTAssertEqual(packed.layout.bytesPerBin, 2)
    Self.reference(packed, frame).check(packedBins, "packed waveform")

    var histogram = ScopeSettings(kind: .histogram, stage: .source)
    histogram.histogramBins = 4096
    try check(histogram, frame, "histogram 4096")
    var vectorscope = ScopeSettings(kind: .vectorscope, stage: .source)
    vectorscope.vectorscopeSize = 1024
    try check(vectorscope, frame, "vectorscope 1024")
  }

  // MARK: stages

  static func makeCube(size: Int, _ transform: (SIMD3<Float>) -> SIMD3<Float>) throws -> CubeLUT {
    var text = "TITLE \"test\"\nLUT_3D_SIZE \(size)\n"
    for b in 0..<size {
      for g in 0..<size {
        for r in 0..<size {
          let v = transform(SIMD3(Float(r), Float(g), Float(b)) / Float(size - 1))
          text += "\(v.x) \(v.y) \(v.z)\n"
        }
      }
    }
    return try CubeLUT(text: text)
  }

  func testStagesApplyTheFeedLUTs() throws {
    let (device, _, _) = try GPU.require()
    let warm = try Self.makeCube(size: 17) { v in
      SIMD3(pow(v.x, 0.8) * 0.95 + 0.03, v.y * 0.9 + 0.05 * v.x, pow(v.z, 1.3))
    }
    let cool = try Self.makeCube(size: 33) { v in SIMD3(v.x * 0.7, v.y, min(1, v.z * 1.2 + 0.1)) }
    let luts = LUTs(
      burn: try MonitorLUT(device: device, cube: warm, interpolation: .tetrahedral),
      monitor: try MonitorLUT(device: device, cube: cool, interpolation: .trilinear))
    for kind in [TestFrame.Kind.v210, .biplanar(.s420, 10), .bgra8] {
      let frame = try TestFrame.natural(kind, width: 160, height: 33, seed: 21)
      for stage in SignalStage.allCases {
        var waveform = ScopeSettings(kind: .waveform, stage: stage)
        waveform.waveformMode = .rgbParade
        waveform.waveformColumns = 96
        waveform.waveformLevels = 512
        try check(waveform, frame, luts: luts, epsilon: 0.02, "waveform \(stage) \(kind)")
        var histogram = ScopeSettings(kind: .histogram, stage: stage)
        histogram.histogramMode = .luma
        try check(histogram, frame, luts: luts, epsilon: 0.02, "histogram \(stage) \(kind)")
        var vectorscope = ScopeSettings(kind: .vectorscope, stage: stage)
        vectorscope.vectorscopeSize = 128
        try check(vectorscope, frame, luts: luts, epsilon: 0.02, "vectorscope \(stage) \(kind)")
      }
    }
  }

  /// Every LUT size and interpolation mode on the output and monitor stages.
  func testEveryLUTSizeAndInterpolation() throws {
    let (device, _, _) = try GPU.require()
    let frame = try TestFrame.natural(.biplanar(.s422, 10), width: 120, height: 17, seed: 31)
    for size in [2, 17, 33, 65] {
      let cube = try Self.makeCube(size: size) { v in SIMD3(pow(v.x, 0.7), v.y * 0.8 + 0.1 * v.z, 1 - v.z * 0.9) }
      for interpolation in LUTInterpolation.allCases {
        let lut = try MonitorLUT(device: device, cube: cube, interpolation: interpolation)
        for stage in [SignalStage.output, .monitor] {
          var s = ScopeSettings(kind: .waveform, stage: stage)
          s.waveformMode = .rgbParade
          s.waveformColumns = 120
          // Hardware filtering weighs with 8-bit fractions, which the CPU cube
          // does not reproduce: measured within 0.0027 per LUT (2³; 0.0005 at
          // 17³), so two stacked LUTs are checked on 64 levels, 0.3 bins.
          // (The reference's two candidates bracket the true bin only below 0.5.)
          let hardware = interpolation == .hardware
          s.waveformLevels = hardware ? 64 : 256
          let epsilon: Float = hardware ? 0.45 : 0.02
          try check(s, frame, luts: LUTs(burn: lut, monitor: lut), epsilon: epsilon, "LUT \(size) \(interpolation) \(stage)")
        }
      }
    }
  }

  func testStageSelectsLUTsAndColorimetry() throws {
    let (device, _, engine) = try GPU.require()
    let cube = try Self.makeCube(size: 2) { $0 }
    let lut = try MonitorLUT(device: device, cube: cube)
    let frame = try TestFrame.natural(.p210Kind, width: 64, height: 8, signal: SignalDescription(matrix: .bt2020))
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform, stage: .source))
    func params(_ stage: SignalStage, _ burn: MonitorLUT?, _ monitor: MonitorLUT?) -> ScopeKernelParameters {
      var s = accumulator.settings
      s.stage = stage
      return accumulator.kernelParameters(
        settings: s, frame: frame.frame, burnInLUT: burn, monitorLUT: monitor, generation: 1)
    }
    XCTAssertEqual(params(.source, lut, lut).luts.x, 0)
    XCTAssertEqual(params(.source, lut, lut).luts.y, 0)
    XCTAssertEqual(params(.output, lut, lut).luts.x, 1)
    XCTAssertEqual(params(.output, lut, lut).luts.y, 0)
    XCTAssertEqual(params(.monitor, lut, lut).luts.x, 1)
    XCTAssertEqual(params(.monitor, lut, lut).luts.y, 1)
    XCTAssertEqual(params(.monitor, nil, lut).luts.x, 0)
    // Source luma uses the transport matrix; after a LUT, Rec.709 (as mk_ire does).
    XCTAssertEqual(params(.source, lut, nil).weights.x, Float(0.2627))
    XCTAssertEqual(params(.output, nil, nil).weights.x, Float(0.2627))
    XCTAssertEqual(params(.output, lut, nil).weights.x, Float(0.2126))
    XCTAssertEqual(params(.monitor, nil, lut).weights.x, Float(0.2126))
  }

  // MARK: vectorscope targets

  /// Colour bars land on the graticule's targets for both matrices and amplitudes.
  func testVectorscopeTargetsMatchColorBars() throws {
    let (_, _, _) = try GPU.require()
    for matrix in [YCbCrMatrix.bt709, .bt2020] {
      for amplitude in [0.75, 1.0] {
        let targets = VectorscopeTarget.bars(matrix: matrix, amplitude: amplitude)
        let bars = targets.map { SIMD3(Float($0.rgb.r), Float($0.rgb.g), Float($0.rgb.b)) }
        // Exact RGB bars (float), and the same bars as 10-bit 4:4:4 Y'CbCr codes.
        let width = 6 * 20
        let rgbFrame = try TestFrame.make(
          .rgba16Float, width: width, height: 8, signal: SignalDescription(range: .full, matrix: matrix),
          rgb: { x, _ in bars[x / 20] })
        let k = matrix.coefficients
        let codes: TestFrame.CodeSource = { x, _ in
          let t = targets[x / 20]
          let y = k.r * t.rgb.r + k.g * t.rgb.g + k.b * t.rgb.b
          return SIMD3(Int((64 + 876 * y).rounded()), Int((512 + 896 * t.cb).rounded()), Int((512 + 896 * t.cr).rounded()))
        }
        let yccFrame = try TestFrame.make(
          .biplanar(.s444, 10), width: width, height: 8, signal: SignalDescription(matrix: matrix), codes: codes)
        for (frame, tolerance) in [(rgbFrame, 1), (yccFrame, 1)] {
          var s = ScopeSettings(kind: .vectorscope, stage: .source)
          s.vectorscopeSize = 512
          let (accumulator, bins) = try accumulate(s, frame)
          XCTAssertEqual(accumulator.context.matrix, matrix)
          let n = 512
          let unit = Double(n) / (2 * VectorscopeGeometry.halfExtent)
          for target in targets {
            let expected = SIMD2(Int((target.cb * unit + Double(n) / 2).rounded(.down)),
                                 Int((target.cr * unit + Double(n) / 2).rounded(.down)))
            // The brightest bin near the target holds the whole bar.
            var best = (count: UInt32(0), at: SIMD2(-99, -99))
            for dy in -2...2 {
              for dx in -2...2 {
                let p = expected &+ SIMD2(dx, dy)
                let c = bins[p.y * n + p.x]
                if c > best.count { best = (c, p) }
              }
            }
            XCTAssertEqual(best.count, 20 * 8, "\(matrix) \(amplitude) \(target.name)")
            XCTAssertLessThanOrEqual(abs(best.at.x - expected.x), tolerance, "\(matrix) \(amplitude) \(target.name) Cb")
            XCTAssertLessThanOrEqual(abs(best.at.y - expected.y), tolerance, "\(matrix) \(amplitude) \(target.name) Cr")
          }
        }
      }
    }
  }

  // MARK: determinism and coverage

  func testSameFrameTwiceGivesIdenticalBins() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 1920, height: 540, seed: 99)
    for kind in ScopeKind.allCases {
      var s = ScopeSettings(kind: kind, stage: .source)
      s.waveformMode = .rgbParade
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let first = try readBins(accumulator)
      let firstStats = accumulator.statistics
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let second = try readBins(accumulator)
      XCTAssertEqual(first, second, "\(kind)")
      var a = try XCTUnwrap(firstStats), b = try XCTUnwrap(accumulator.statistics)
      XCTAssertEqual(b.generation, a.generation + 1)
      a.generation = 0
      b.generation = 0
      XCTAssertEqual(a, b, "\(kind) statistics")
    }
  }

  /// A single bright pixel in a black UHD frame shows up in every scope.
  func testSinglePixelAppearsInEveryScope() throws {
    let width = 3840, height = 2160, spot = SIMD2(2777, 1531)
    // 4:4:4, so the spot's chroma does not spread into its neighbours.
    let frame = try TestFrame.make(
      .biplanar(.s444, 10), width: width, height: height,
      codes: { x, y in x == spot.x && y == spot.y ? SIMD3(800, 300, 800) : SIMD3(64, 512, 512) })
    let pixel = frame.rgb[spot.y * width + spot.x]
    var waveform = ScopeSettings(kind: .waveform, stage: .source)
    waveform.waveformColumns = 1024
    waveform.waveformLevels = 512
    let (wa, wb) = try accumulate(waveform, frame)
    let p = wa.kernelParameters(settings: wa.settings, frame: frame.frame, burnInLUT: nil, monitorLUT: nil, generation: 1)
    let luma = p.scopeLuma(pixel, transport: frame.luma[spot.y * width + spot.x])
    let level = Int(((luma - p.level.x) * p.level.y).rounded(.down))
    let column = spot.x * 1024 / width
    XCTAssertEqual(wb[level * 1024 + column], 1)
    XCTAssertEqual(wb.reduce(0, +), UInt32(width * height))
    XCTAssertEqual(wa.statistics?.pixelCount, width * height)

    var histogram = ScopeSettings(kind: .histogram, stage: .source)
    histogram.histogramMode = .luma
    let (ha, hb) = try accumulate(histogram, frame)
    let hp = ha.kernelParameters(settings: ha.settings, frame: frame.frame, burnInLUT: nil, monitorLUT: nil, generation: 1)
    XCTAssertEqual(hb[Int(((luma - hp.level.x) * hp.level.y).rounded(.down))], 1)

    let (va, vb) = try accumulate(ScopeSettings(kind: .vectorscope, stage: .source), frame)
    let vp = va.kernelParameters(settings: va.settings, frame: frame.frame, burnInLUT: nil, monitorLUT: nil, generation: 1)
    let cb = (pixel.z - luma) * vp.chroma.x, cr = (pixel.x - luma) * vp.chroma.y
    let bx = Int((cb * vp.chroma.z + vp.chroma.w).rounded(.down)), by = Int((cr * vp.chroma.z + vp.chroma.w).rounded(.down))
    XCTAssertEqual(vb[by * va.layout.columns + bx], 1)
    let centre = va.layout.columns / 2
    XCTAssertEqual(vb[centre * va.layout.columns + centre], UInt32(width * height - 1))
  }

  // MARK: statistics

  func testStatisticsMatchCPU() throws {
    // 264 × 17: the vectorscope's corner threadgroup has a single thread.
    for (kind, width, height) in [(TestFrame.Kind.v210, 640, 120), (.rgba16Float, 640, 120), (.bgra8, 264, 17)] {
      let frame = try TestFrame.natural(kind, width: width, height: height, seed: 4)
      for (scope, colorimetry) in ScopeKind.allCases.map({ ($0, ScopeColorimetry.auto) }) + [(.waveform, .bt2020)] {
        var s = ScopeSettings(kind: scope, stage: .source)
        s.colorimetry = colorimetry
        s.clipHighPercent = 90
        s.clipLowPercent = 5
        let (accumulator, _) = try accumulate(s, frame)
        let stats = try XCTUnwrap(accumulator.statistics)
        let p = accumulator.kernelParameters(
          settings: s, frame: frame.frame, burnInLUT: nil, monitorLUT: nil, generation: 1)
        var lo = Double.infinity, hi = -Double.infinity, sum = 0.0
        var high = SIMD4<Double>.zero, low = SIMD4<Double>.zero
        for (rgb, transport) in zip(frame.rgb, frame.luma) {
          let y = p.statisticsLuma(rgb, transport: transport)
          let v = SIMD4(rgb.x, rgb.y, rgb.z, y)
          let yc = Double(min(3, max(-1, y)))
          lo = min(lo, yc)
          hi = max(hi, yc)
          sum += yc
          // In percent, with the shader's Float operations.
          for i in 0..<4 {
            if v[i] * 100 >= p.clip.x { high[i] += 1 }
            if v[i] * 100 <= p.clip.y { low[i] += 1 }
          }
        }
        let n = Double(frame.rgb.count)
        let label = "\(kind) \(scope) \(colorimetry)"
        XCTAssertEqual(stats.pixelCount, frame.rgb.count, label)
        XCTAssertEqual(stats.lumaMinimum, lo, accuracy: 2e-6, label)
        XCTAssertEqual(stats.lumaMaximum, hi, accuracy: 2e-6, label)
        XCTAssertEqual(stats.lumaAverage, sum / n, accuracy: 2e-4, label)
        for i in 0..<4 {
          // Values exactly at a threshold may round either way.
          XCTAssertEqual(stats.clippedHigh[i], high[i] / n, accuracy: 0.002, label)
          XCTAssertEqual(stats.clippedLow[i], low[i] / n, accuracy: 0.002, label)
        }
        XCTAssertGreaterThan(high.sum() + low.sum(), 0, "the frame exercises the clip counters")
        if scope == .histogram {
          let bins = try readBins(accumulator)
          let channels = accumulator.layout.channels, columns = accumulator.layout.columns
          for k in 0..<channels {
            XCTAssertEqual(stats.histogramPeak[k], bins[k * columns..<(k + 1) * columns].max())
          }
        }
      }
    }
  }

  func testStatisticsAlternateSlotsAndRejectOpenSlots() throws {
    let (_, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.bgra8, width: 64, height: 16)
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram))
    XCTAssertNil(accumulator.statistics)
    for expected in 1...3 {
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      XCTAssertEqual(accumulator.statistics?.generation, UInt32(expected))
    }
    // Encoded but not yet run: the open slot is ignored, the previous one is returned.
    let cb = try XCTUnwrap(queue.makeCommandBuffer())
    try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
    XCTAssertEqual(accumulator.statistics?.generation, 3)
    cb.commit()
    cb.waitUntilCompleted()
    XCTAssertEqual(accumulator.statistics?.generation, 4)
  }

  // MARK: resources

  func testBinsAreScopeSizedAndReused() throws {
    let (device, _, engine) = try GPU.require()
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformColumns = 512
    s.waveformLevels = 256
    let accumulator = try engine.makeAccumulator(settings: s)
    let small = try TestFrame.natural(.bgra8, width: 320, height: 180)
    let large = try TestFrame.natural(.bgra8, width: 1920, height: 1080)
    try GPU.run { cb in try accumulator.accumulate(small.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let bins = accumulator.bins
    XCTAssertEqual(bins.length, 512 * 256 * 2)
    try GPU.run { cb in try accumulator.accumulate(large.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertTrue(bins === accumulator.bins, "frame size alone never reallocates")
    XCTAssertEqual(accumulator.bins.length, 512 * 256 * 2)
    let allocated = device.currentAllocatedSize
    accumulator.settings.display.brightness = 2
    try GPU.run { cb in try accumulator.accumulate(large.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertTrue(bins === accumulator.bins, "display changes never reallocate")
    XCTAssertEqual(device.currentAllocatedSize, allocated)
    accumulator.settings.waveformLevels = 1024
    try GPU.run { cb in try accumulator.accumulate(large.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertEqual(accumulator.bins.length, 512 * 1024 * 2)
  }

  func testParameterStructsMatchShaderLayout() throws {
    let (device, _, engine) = try GPU.require()
    let function = try engine.library.makeFunction(name: "mk_scopeWaveform", constantValues: MTLFunctionConstantValues())
    var reflection: MTLComputePipelineReflection?
    _ = try device.makeComputePipelineState(function: function, options: [.bindingInfo], reflection: &reflection)
    let params = try XCTUnwrap(
      reflection?.bindings.first { $0.index == 3 && $0.type == .buffer } as? MTLBufferBinding)
    XCTAssertEqual(params.bufferDataSize, MemoryLayout<ScopeKernelParameters>.stride)

    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = engine.vertexFunction
    d.fragmentFunction = try engine.library.makeFunction(
      name: "mk_scopeFragment", constantValues: ScopeEngine.constants(ScopeEngine.RenderKey(target: MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm), scope: nil)))
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    var renderReflection: MTLRenderPipelineReflection?
    _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo], reflection: &renderReflection)
    let draw = try XCTUnwrap(
      renderReflection?.fragmentBindings.first { $0.index == 0 && $0.type == .buffer } as? MTLBufferBinding)
    XCTAssertEqual(draw.bufferDataSize, MemoryLayout<ScopeDrawParameters>.stride)
    XCTAssertLessThanOrEqual(MemoryLayout<ScopeDrawParameters>.stride, 4096, "fits setFragmentBytes")
  }
}

extension TestFrame.Kind {
  static let p210Kind = TestFrame.Kind.biplanar(.s422, 10)
}
