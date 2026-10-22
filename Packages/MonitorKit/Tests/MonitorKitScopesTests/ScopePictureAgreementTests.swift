import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// The picture pass and the scopes measure one frame with one convention: the
/// same decode, the same stage luma (transport Y' at the source, Rec.709 Y' of
/// the LUT result after one) and the same inclusive 100% boundary. A pixel the
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
        if stage == .source {
          XCTAssertEqual(picture, scope, label)
        } else {
          // After a LUT both read Rec.709 Y' of the same mk_applyLUT result, so
          // only pixels within float rounding of 100% may land either side.
          var near = 0
          for rgb in frame.rgb {
            let v = cube.apply(rgb, interpolation: lut.interpolation)
            if abs(mkLuma(v, SIMD3(0.2126, 0.7152, 0.0722)) - 1) < 1e-5 { near += 1 }
          }
          XCTAssertLessThanOrEqual(abs(picture - scope), near, label)
        }
      }
    }
  }
}
