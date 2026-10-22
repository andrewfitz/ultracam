import Foundation
import XCTest

@testable import MonitorKitCore

/// The signal model and reference math added for the picture-pass audit.
final class SignalReferenceTests: XCTestCase {
  func testFocusStageDecodesLeniently() throws {
    let decoder = JSONDecoder()
    let old = try decoder.decode(FocusSettings.self, from: Data(#"{"enabled": true}"#.utf8))
    XCTAssertEqual(old.stage, .source, "settings saved before stages existed measure the source")
    XCTAssertTrue(old.enabled)
    let bad = try decoder.decode(FocusSettings.self, from: Data(#"{"stage": "sideways"}"#.utf8))
    XCTAssertEqual(bad.stage, .source)
    var f = FocusSettings()
    f.stage = .monitor
    XCTAssertEqual(try decoder.decode(FocusSettings.self, from: JSONEncoder().encode(f)), f)
  }

  func testSignalDescriptionsSavedWithoutVerticalSitingDecodeAsCentred() throws {
    let old = #"{"range": "full", "matrix": "bt2020", "chromaSiting": "center", "encoding": {"display": {"_0": "pq"}}}"#
    let decoded = try JSONDecoder().decode(SignalDescription.self, from: Data(old.utf8))
    XCTAssertEqual(decoded.chromaVerticalSiting, .center)
    XCTAssertEqual(decoded.range, .full)
    let full = SignalDescription(range: .legal, matrix: .smpte240m, chromaSiting: .left, encoding: .display(.hlg),
                                 chromaVerticalSiting: .top)
    XCTAssertEqual(try JSONDecoder().decode(SignalDescription.self, from: JSONEncoder().encode(full)), full)
  }

  /// Unknown or malformed fields (a profile saved by a newer build, a hand edit)
  /// fall back field by field instead of failing the host's whole settings decode.
  func testSignalDescriptionsDecodeLeniently() throws {
    let newer = #"""
      {"range": "full", "matrix": "bt9999", "chromaSiting": "center",
       "encoding": {"log": {"_0": {"curve": "sLog2", "gamut": "sGamut", "transport": "native"}}},
       "chromaVerticalSiting": 7, "primaries": "aces"}
      """#
    let d = try JSONDecoder().decode(SignalDescription.self, from: Data(newer.utf8))
    XCTAssertEqual(d.range, .full, "known fields keep their values")
    XCTAssertEqual(d.chromaSiting, .center)
    XCTAssertEqual(d.matrix, SignalDescription.rec709.matrix)
    XCTAssertEqual(d.encoding, .unknown, "an unknown encoding is unlabelled")
    XCTAssertEqual(d.chromaVerticalSiting, .center)
    XCTAssertNil(d.primaries)
    struct Settings: Codable { var name: String; var signal: SignalDescription }
    let wrapped = #"{"name": "A cam", "signal": \#(newer)}"#
    XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(wrapped.utf8)).name, "A cam")
    let empty = try JSONDecoder().decode(SignalDescription.self, from: Data("{}".utf8))
    XCTAssertEqual(empty, SignalDescription(encoding: .unknown))
    for s in [
      SignalDescription(range: .full, matrix: .bt2020, encoding: .log(.sLog3SGamut3), primaries: nil),
      SignalDescription(encoding: .display(.pq), primaries: .displayP3), SignalDescription(encoding: .unknown),
    ] {
      XCTAssertEqual(try JSONDecoder().decode(SignalDescription.self, from: JSONEncoder().encode(s)), s)
    }
  }

  func testVerticalChromaTaps() {
    // Top: chroma row j sits on luma row 2j.
    var t = DecodeReference.chromaTaps(x: 0, y: 2, width: 8, height: 8, subsampling: .s420, siting: .left, vertical: .top)
    XCTAssertEqual(t.y0, 1); XCTAssertEqual(t.fy, 0)
    t = DecodeReference.chromaTaps(x: 0, y: 3, width: 8, height: 8, subsampling: .s420, siting: .left, vertical: .top)
    XCTAssertEqual(t.y0, 1); XCTAssertEqual(t.y1, 2); XCTAssertEqual(t.fy, 0.5)
    // Bottom: on luma row 2j + 1; row 0 clamps to the first chroma row.
    t = DecodeReference.chromaTaps(x: 0, y: 3, width: 8, height: 8, subsampling: .s420, siting: .left, vertical: .bottom)
    XCTAssertEqual(t.y0, 1); XCTAssertEqual(t.fy, 0)
    t = DecodeReference.chromaTaps(x: 0, y: 0, width: 8, height: 8, subsampling: .s420, siting: .left, vertical: .bottom)
    XCTAssertEqual(t.y0, 0); XCTAssertEqual(t.y1, 0)
    // Centre is the default and the MPEG-2 position.
    let a = DecodeReference.chromaTaps(x: 0, y: 1, width: 8, height: 8, subsampling: .s420, siting: .left)
    let b = DecodeReference.chromaTaps(x: 0, y: 1, width: 8, height: 8, subsampling: .s420, siting: .left, vertical: .center)
    XCTAssertEqual(a.fy, b.fy)
    XCTAssertEqual(a.fy, 0.25)
  }

  func testSMPTE240MCoefficients() {
    let k = YCbCrMatrix.smpte240m.coefficients
    XCTAssertEqual(k.r + k.g + k.b, 1, accuracy: 1e-12)
    XCTAssertEqual(k.r, 0.212)
    XCTAssertEqual(k.b, 0.087)
    let rgb = ColorMath.yCbCrToRGB(y: 0.5, cb: 0, cr: 0.25, matrix: .smpte240m)!
    XCTAssertEqual(rgb.r, 0.5 + 2 * (1 - 0.212) * 0.25, accuracy: 1e-12)
  }

  /// Reference values from the standards: ST 2084 at its anchors, BT.2100 HLG at
  /// the OETF's knee, BT.2408 grey cards, sRGB and BT.709 at known points.
  func testTransferReferences() {
    XCTAssertEqual(ColorMath.pqNits(0), 0, accuracy: 1e-9)
    XCTAssertEqual(ColorMath.pqNits(1), 10000, accuracy: 1e-6)
    // ST 2084: 100 cd/m² is 0.5081 (10-bit code 520), 1000 cd/m² is 0.7518.
    XCTAssertEqual(ColorMath.pqNits(0.508078), 100, accuracy: 0.05)
    XCTAssertEqual(ColorMath.pqNits(0.751827), 1000, accuracy: 0.5)
    // BT.2100 HLG: E' = 0.5 at E = 1/12; E' = 1 at E = 1.
    XCTAssertEqual(ColorMath.hlgInverseOETF(0.5), 1.0 / 12, accuracy: 1e-12)
    XCTAssertEqual(ColorMath.hlgInverseOETF(1), 1, accuracy: 1e-7)
    XCTAssertEqual(ColorMath.sRGBDecode(0.04045), 0.04045 / 12.92, accuracy: 1e-12)
    XCTAssertEqual(ColorMath.sRGBDecode(1), 1, accuracy: 1e-12)
    // The 18% grey card is 0.18 in every transfer.
    XCTAssertEqual(DisplayTransfer.bt709.exposureLinear(0.409), 0.18, accuracy: 2e-4)
    XCTAssertEqual(DisplayTransfer.sRGB.exposureLinear(0.4614), 0.18, accuracy: 2e-4)
    XCTAssertEqual(DisplayTransfer.hlg.exposureLinear(0.38), 0.18, accuracy: 1e-12)
    XCTAssertEqual(DisplayTransfer.linear.exposureLinear(0.18), 0.18)
    var pqGrey = 0.0, low = 0.0, high = 1.0
    for _ in 0..<60 {
      pqGrey = (low + high) / 2
      if ColorMath.pqNits(pqGrey) < 26 { low = pqGrey } else { high = pqGrey }
    }
    XCTAssertEqual(DisplayTransfer.pq.exposureLinear(pqGrey), 0.18, accuracy: 1e-9)
    XCTAssertEqual(pqGrey, 0.38, accuracy: 0.005, "BT.2408: the PQ grey card is about 38%")
    // HDR reference white (203 cd/m², 75% HLG) is about 2.5–3 stops over grey.
    XCTAssertEqual(log2(DisplayTransfer.hlg.exposureLinear(0.75) / 0.18), 2.46, accuracy: 0.02)
    XCTAssertEqual(log2(203.0 / 26), log2(DisplayTransfer.pq.exposureLinear(0.58) / 0.18), accuracy: 0.03)
  }

  /// LogC fills the container's range; S-Log3 keeps its 10-bit codes.
  func testLogSignalConventions() {
    for code in [64.0, 285, 308, 400, 940] {
      let legal = CodeRange.legal.normalizeLuma(code: code, bitDepth: 10)!, full = code / 1023
      for curve in [LogCurve.arriLogC3, .arriLogC4] {
        XCTAssertEqual(curve.signal(expanded: legal, range: .legal, transport: .native), legal)
        XCTAssertEqual(curve.signal(expanded: full, range: .full, transport: .native), full)
        XCTAssertEqual(curve.signal(expanded: legal, range: .legal, transport: .fullRescaledToLegal), legal)
        XCTAssertEqual(curve.signal(expanded: full, range: .full, transport: .fullRescaledToLegal), (code - 64) / 876, accuracy: 1e-12)
      }
      XCTAssertEqual(LogCurve.sLog3.signal(expanded: legal, range: .legal, transport: .native), code / 1023, accuracy: 1e-12)
    }
    // ARRI's own tables put LogC4 18% grey in green in both containers: legal code 308, full 285.
    let t = 0.278396
    XCTAssertEqual(ARRIFalseColorProfile.alexa35LogC4EI800.category(achromaticCode: (64 + 876 * t).rounded(), range: .legal), .green)
    XCTAssertEqual(ARRIFalseColorProfile.alexa35LogC4EI800.category(achromaticCode: (1023 * t).rounded(), range: .full), .green)
    let legalGrey = LogCurve.arriLogC4.signal(expanded: CodeRange.legal.normalizeLuma(code: 308, bitDepth: 10)!, range: .legal, transport: .native)
    XCTAssertEqual(log2(LogCurve.arriLogC4.decode(legalGrey)! / 0.18), 0, accuracy: 0.03)
  }
}

final class CubeShaperParsingTests: XCTestCase {
  static let resolve = """
    # Resolve shaper LUT
    TITLE "Log to 709"
    LUT_1D_SIZE 3
    LUT_1D_INPUT_RANGE -0.25 1.25
    LUT_3D_SIZE 2
    LUT_3D_INPUT_RANGE 0.0 1.0
    0 0 0
    0.6 0.5 0.4
    1 1 1
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """

  func testResolveShaperLUT() throws {
    let cube = try CubeLUT(text: Self.resolve)
    XCTAssertEqual(cube.title, "Log to 709")
    XCTAssertEqual(cube.shaperSize, 3)
    XCTAssertEqual(cube.dimension, 2)
    XCTAssertEqual(cube.shaperDomainMin, SIMD3(repeating: -0.25))
    XCTAssertEqual(cube.shaperDomainMax, SIMD3(repeating: 1.25))
    // The middle input hits the middle shaper entry, then the identity cube.
    XCTAssertEqual(cube.apply(SIMD3(repeating: 0.5)), SIMD3(0.6, 0.5, 0.4))
    // A quarter of the way: halfway between entries 0 and 1.
    XCTAssertEqual(cube.applyShaper(SIMD3(repeating: 0.125)), SIMD3(0.3, 0.25, 0.2))
    // Below the input range clamps to the first entry.
    XCTAssertEqual(cube.apply(SIMD3(repeating: -1)), .zero)
  }

  func testOneDimensionalOnlyAndDomainRules() throws {
    let oneD = try CubeLUT(text: "LUT_1D_SIZE 2\nDOMAIN_MIN 0 0 -1\nDOMAIN_MAX 2 1 1\n0 0 0\n1 2 3\n")
    XCTAssertFalse(oneD.hasCube)
    XCTAssertEqual(oneD.dimension, 0)
    XCTAssertEqual(oneD.apply(SIMD3(1, 0.5, 0)), SIMD3(0.5, 1, 1.5))
    // LUT_3D_INPUT_RANGE is the 3D domain.
    var text = "LUT_3D_SIZE 2\nLUT_3D_INPUT_RANGE -1 3\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
    let ranged = try CubeLUT(text: text)
    XCTAssertEqual(ranged.domainMin, SIMD3(repeating: -1))
    XCTAssertEqual(ranged.domainMax, SIMD3(repeating: 3))
    XCTAssertEqual(ranged.apply(SIMD3(repeating: 1)), SIMD3(repeating: 0.5))
    // Errors.
    let cubeData = (0..<8).map { _ in "0 0 0" }.joined(separator: "\n")
    let bad = [
      "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nLUT_3D_INPUT_RANGE 0 1\n" + cubeData,  // two domains for one table
      "LUT_1D_SIZE 3\n0 0 0\n1 1 1\n",  // incomplete 1D table
      "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n1 1 1\n",  // too many entries
      "LUT_1D_SIZE 1\n0 0 0\n",  // too small
      "LUT_1D_SIZE 65537\n",  // too large
      "LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 1 0\n0 0 0\n1 1 1\n",  // inverted range
      "LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0\n0 0 0\n1 1 1\n",  // one number
      "0 0 0\n",  // no size
      "LUT_1D_SIZE 2\n0 0 0\nLUT_3D_SIZE 2\n",  // header after data
    ]
    for text in bad { XCTAssertThrowsError(try CubeLUT(text: text), text) }
  }
}
