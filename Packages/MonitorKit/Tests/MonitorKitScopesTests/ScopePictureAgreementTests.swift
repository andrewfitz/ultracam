import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// The picture pass and the scopes measure one frame with one convention: the
/// same decode, the same stage luma (transport Y' at the source, Rec.709 Y' of
/// the LUT result after one) and the same inclusive 100% boundary, compared in
/// percent with the same Float operations. A pixel the
/// picture's IRE tools (custom false colour and zebras share `mk_stageLuma`)
/// mark at or above 100 IRE is one the scope counts as clipped high.
final class ScopePictureAgreementTests: XCTestCase {
  static let marker = ColorRGB(r: 1, g: 0, b: 1)

  /// Highlights straddling legal white: luma codes around 940 (exactly 940 on a
  /// third of the pixels), chroma off centre so R'G'B' is coloured.
  static func highlights(_ kind: TestFrame.Kind, width: Int, height: Int) throws -> TestFrame {
    var random = SeededRandom(0x5C09E)
    let depth: Int
    switch kind {
    case .v210: depth = 10
    case .uyvy8, .yuyv8: depth = 8
    case .biplanar(_, let d): depth = d
    default: depth = 8
    }
    let s = 1 << (depth - 8)
    var table = [SIMD3<Int>](repeating: .zero, count: width * height)
    for i in table.indices {
      let luma = i % 3 == 0 ? 235 * s : (220 + random.int(0...30)) * s + random.int(0...(s - 1))
      table[i] = SIMD3(luma, (128 + random.int(-12...12)) * s, (128 + random.int(-12...12)) * s)
    }
    var rgbTable = [SIMD3<Float>](repeating: .zero, count: width * height)
    for i in rgbTable.indices {
      // Legal-labelled 8-bit RGB: 235 is white.
      func v() -> Float { Float(i % 3 == 0 ? 235 : 220 + random.int(0...30)) / 255 }
      rgbTable[i] = SIMD3(v(), v(), v())
    }
    return try TestFrame.make(
      kind, width: width, height: height, codes: { x, y in table[y * width + x] },
      rgb: { x, y in rgbTable[y * width + x] })
  }

  /// Pixels the picture pass marks at or above 100 IRE of `stage`, from one 1:1 draw.
  func pictureCount(_ frame: MonitorFrame, stage: SignalStage, feed: MonitorFeed, pass: MonitorPass) throws -> Int {
    let (device, _, _) = try GPU.require()
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: frame.width, height: frame.height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    var state = MonitorState()
    state.falseColor.mode = .custom
    state.falseColor.customUnit = .ire
    state.falseColor.stage = stage
    state.falseColor.customBands = [FalseColorBand(lower: 100, upper: .infinity, color: Self.marker)]
    try GPU.run { cb in try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb) }
    var pixels = [SIMD4<Float>](repeating: .zero, count: frame.width * frame.height)
    pixels.withUnsafeMutableBytes {
      target.getBytes(
        $0.baseAddress!, bytesPerRow: frame.width * 16, from: MTLRegionMake2D(0, 0, frame.width, frame.height),
        mipmapLevel: 0)
    }
    var count = 0
    for p in pixels where p.x == 1 && p.y == 0 && p.z == 1 { count += 1 }
    return count
  }

  func testPictureIREAndScopeClipCountsAgreeOnEveryLayoutAndStage() throws {
    let (device, _, engine) = try GPU.require()
    let monitor = try MonitorEngine(device: device, specialization: .synchronous)
    // A gentle lift that pushes some highlights over white, and some colours over in one channel.
    var text = "LUT_3D_SIZE 17\n"
    for b in 0..<17 {
      for g in 0..<17 {
        for r in 0..<17 {
          let v = SIMD3(Double(r), Double(g), Double(b)) / 16
          let out = v * SIMD3(1.04, 1.02, 0.98) + 0.004
          text += "\(out.x) \(out.y) \(out.z)\n"
        }
      }
    }
    let cube = try CubeLUT(text: text)
    let lut = try MonitorLUT(device: device, cube: cube)
    let (width, height) = (96, 32)
    for kind in [TestFrame.Kind.v210, .uyvy8, .biplanar(.s420, 10), .biplanar(.s422, 8), .bgra8] {
      let frame = try Self.highlights(kind, width: width, height: height)
      for stage in [SignalStage.source, .output] {
        let feed = monitor.makeFeed()
        if stage == .output { feed.burnInLUT = lut }
        let picture = try pictureCount(frame.frame, stage: stage, feed: feed, pass: monitor.makePass())
        var settings = ScopeSettings(kind: .histogram, stage: stage)
        settings.clipHighPercent = 100
        let accumulator = try engine.makeAccumulator(settings: settings)
        try GPU.run { cb in try accumulator.accumulate(frame.frame, feed: feed, into: cb) }
        let stats = try XCTUnwrap(accumulator.statistics)
        let scope = Int((stats.clippedHigh.w * Double(stats.pixelCount)).rounded())
        let label = "\(kind) \(stage)"
        XCTAssertEqual(stats.pixelCount, width * height, label)
        // The boundary is exercised: some pixels sit on it, some either side.
        XCTAssertGreaterThan(picture, width * height / 4, label)
        XCTAssertLessThan(picture, width * height, label)
        // Both compare the stage Y' in percent with the same Float operations,
        // so they agree exactly, after a LUT too.
        XCTAssertEqual(picture, scope, label)
      }
    }
  }

  /// Highlights and shadows straddling legal white and black on every channel:
  /// a quarter of the pixels at exactly 100% or 0% luma, chroma up to `chroma`
  /// 8-bit codes off centre.
  static func extremes(_ kind: TestFrame.Kind, width: Int, height: Int, chroma: Int = 14) throws -> TestFrame {
    var random = SeededRandom(0xC11B)
    let s = 1 << (kind.bitDepth - 8)
    var table = [SIMD3<Int>](repeating: .zero, count: width * height)
    var rgbTable = [SIMD3<Float>](repeating: .zero, count: width * height)
    for i in table.indices {
      let high = i % 2 == 0
      let exact = i % 4 < 2
      let luma = (exact ? (high ? 235 : 16) : (high ? 222 + random.int(0...30) : 4 + random.int(0...26))) * s
      table[i] = SIMD3(luma, (128 + random.int(-chroma...chroma)) * s, (128 + random.int(-chroma...chroma)) * s)
      // Legal-labelled 8-bit RGB: 235 is white and 16 black, per channel.
      func v() -> Float { Float(exact ? (high ? 235 : 16) : (high ? 222 + random.int(0...30) : 4 + random.int(0...26))) / 255 }
      rgbTable[i] = SIMD3(v(), v(), v())
    }
    return try TestFrame.make(
      kind, width: width, height: height, codes: { x, y in table[y * width + x] },
      rgb: { x, y in rgbTable[y * width + x] })
  }

  /// Pixels the picture's clip indicator marks, with only `channel` (0 R, 1 G,
  /// 2 B, 3 luma) enabled and only the over (`high`) or under side shown.
  func clipIndicatorCount(
    _ frame: MonitorFrame, stage: SignalStage, channel: Int, high: Bool, levels: (Double, Double), feed: MonitorFeed,
    pass: MonitorPass
  ) throws -> Int {
    let (device, _, _) = try GPU.require()
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: frame.width, height: frame.height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    var state = MonitorState()
    var c = ClipIndicatorSettings()
    c.enabled = true
    c.stage = stage
    c.red = channel == 0
    c.green = channel == 1
    c.blue = channel == 2
    c.luma = channel == 3
    c.showsOver = high
    c.showsUnder = !high
    c.high = levels.0
    c.low = levels.1
    c.coloring = .uniform
    c.overColor = Self.marker
    c.underColor = Self.marker
    c.opacity = 1
    state.clipIndicators = c
    try GPU.run { cb in try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb) }
    var pixels = [SIMD4<Float>](repeating: .zero, count: frame.width * frame.height)
    pixels.withUnsafeMutableBytes {
      target.getBytes(
        $0.baseAddress!, bytesPerRow: frame.width * 16, from: MTLRegionMake2D(0, 0, frame.width, frame.height),
        mipmapLevel: 0)
    }
    var count = 0
    for p in pixels where p.x == 1 && p.y == 0 && p.z == 1 { count += 1 }
    return count
  }

  /// Per-channel clip readouts: for R', G', B' and Y' of every stage, the
  /// scope's clipped-high and clipped-low fractions count exactly the pixels
  /// the picture's clip indicator marks at the same levels (inclusive at 100%
  /// and 0%, and at other levels), on every layout family.
  func testClipReadoutsCountExactlyThePixelsTheClipIndicatorMarks() throws {
    let (device, _, engine) = try GPU.require()
    let monitor = try MonitorEngine(device: device, specialization: .synchronous)
    let burn = try MonitorLUT(
      device: device,
      cube: try ScopeAccumulationTests.makeCube(size: 17) { $0 * SIMD3(1.04, 1.02, 0.97) - 0.004 })
    let look = try MonitorLUT(
      device: device, cube: try ScopeAccumulationTests.makeCube(size: 17) { SIMD3($0.y, $0.x, $0.z) * 1.01 - 0.002 })
    let (width, height) = (96, 24)
    for kind in [TestFrame.Kind.v210, .yuyv8, .biplanar(.s420, 10), .biplanar(.s422, 16), .bgra8] {
      let frame = try Self.extremes(kind, width: width, height: height)
      for stage in SignalStage.allCases {
        let feed = monitor.makeFeed()
        feed.burnInLUT = burn
        feed.monitorLUT = look
        for levels in [(100.0, 0.0), (97.5, 3.25)] {
          var settings = ScopeSettings(kind: .vectorscope, stage: stage)
          settings.clipHighPercent = levels.0
          settings.clipLowPercent = levels.1
          let accumulator = try engine.makeAccumulator(settings: settings)
          try GPU.run { cb in try accumulator.accumulate(frame.frame, feed: feed, into: cb) }
          let stats = try XCTUnwrap(accumulator.statistics)
          XCTAssertEqual(stats.pixelCount, width * height)
          let pass = monitor.makePass()
          var exercised = 0
          for channel in 0..<4 {
            for high in [true, false] {
              let label = "\(kind) \(stage) \(levels) channel \(channel) \(high ? "high" : "low")"
              let picture = try clipIndicatorCount(
                frame.frame, stage: stage, channel: channel, high: high, levels: levels, feed: feed, pass: pass)
              let fraction = high ? stats.clippedHigh[channel] : stats.clippedLow[channel]
              XCTAssertEqual(Int((fraction * Double(stats.pixelCount)).rounded()), picture, label)
              if picture > 0 && picture < width * height { exercised += 1 }
            }
          }
          XCTAssertGreaterThanOrEqual(exercised, 6, "\(kind) \(stage) \(levels): both sides of the levels are present")
        }
      }
    }
  }

  /// The Y' readouts count exactly the pixels the picture's luma clip indicator
  /// marks whatever the scope's colorimetry, on chromatic highlights where the
  /// colorimetries' Y' disagree: the statistics measure the stage luma, and
  /// colorimetry only weighs what the scope draws.
  func testLumaReadoutsFollowTheStageLumaWhateverTheColorimetry() throws {
    let (device, _, engine) = try GPU.require()
    let monitor = try MonitorEngine(device: device, specialization: .synchronous)
    let burn = try MonitorLUT(
      device: device,
      cube: try ScopeAccumulationTests.makeCube(size: 17) { $0 * SIMD3(1.04, 1.02, 0.97) - 0.004 })
    let (width, height) = (96, 24)
    for kind in [TestFrame.Kind.v210, .biplanar(.s422, 10), .bgra8] {
      let frame = try Self.extremes(kind, width: width, height: height, chroma: 48)
      // The frame tells the colorimetries apart at the 100% boundary.
      let k601 = YCbCrMatrix.bt601.coefficients
      let w601 = SIMD3(Float(k601.r), Float(k601.g), Float(k601.b))
      let transport = frame.luma.filter { $0 * 100 >= 100 }.count
      let weighed = frame.rgb.filter { mkLuma($0, w601) * 100 >= 100 }.count
      XCTAssertNotEqual(transport, weighed, "\(kind): BT.601 weights move pixels across 100%")
      for stage in [SignalStage.source, .output] {
        let feed = monitor.makeFeed()
        feed.burnInLUT = burn
        let pass = monitor.makePass()
        let high = try clipIndicatorCount(
          frame.frame, stage: stage, channel: 3, high: true, levels: (100, 0), feed: feed, pass: pass)
        let low = try clipIndicatorCount(
          frame.frame, stage: stage, channel: 3, high: false, levels: (100, 0), feed: feed, pass: pass)
        XCTAssertGreaterThan(high, 0)
        XCTAssertGreaterThan(low, 0)
        var reference: ScopeStatistics?
        for colorimetry in ScopeColorimetry.allCases {
          var settings = ScopeSettings(kind: .waveform, stage: stage)
          settings.colorimetry = colorimetry
          let accumulator = try engine.makeAccumulator(settings: settings)
          try GPU.run { cb in try accumulator.accumulate(frame.frame, feed: feed, into: cb) }
          let stats = try XCTUnwrap(accumulator.statistics)
          let n = Double(stats.pixelCount)
          let label = "\(kind) \(stage) \(colorimetry)"
          XCTAssertEqual(Int((stats.clippedHigh.w * n).rounded()), high, label)
          XCTAssertEqual(Int((stats.clippedLow.w * n).rounded()), low, label)
          if let r = reference {
            XCTAssertEqual(stats.lumaMinimum, r.lumaMinimum, label)
            XCTAssertEqual(stats.lumaMaximum, r.lumaMaximum, label)
            XCTAssertEqual(stats.lumaAverage, r.lumaAverage, label)
          } else {
            reference = stats
          }
        }
      }
    }
  }
}
