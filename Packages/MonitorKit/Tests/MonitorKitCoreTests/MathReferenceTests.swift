import Foundation
import Metal
import XCTest
import simd

@testable import MonitorKitCore

/// Independent checks of every Core constant and curve against values derived here
/// from the primary-source definitions. Sources, sections and status are in
/// `Docs/MATH.md`; each test names the clause it derives from. The shader curves
/// are compiled from the `.msl` text and run on the GPU against Core (this target
/// cannot import MonitorKit); constants in Audio and Scopes are read from their text.
final class MathReferenceTests: XCTestCase {

  // MARK: - Primaries and luminance coefficients

  /// The Y row of the normalized primary matrix (SMPTE RP 177-1993 §3.3). Every
  /// primary's XYZ column has Y = 1 before scaling, so the Y row is exactly the
  /// scale vector S = P⁻¹·W.
  fileprivate static func luminanceRow(
    _ primaries: [(Double, Double)], white: (Double, Double) = Source.d65
  ) -> SIMD3<Double> {
    func xyz(_ c: (Double, Double)) -> SIMD3<Double> { SIMD3(c.0 / c.1, 1, (1 - c.0 - c.1) / c.1) }
    let p = simd_double3x3(columns: (xyz(primaries[0]), xyz(primaries[1]), xyz(primaries[2])))
    return p.inverse * xyz(white)
  }

  func testRec709And2020LuminanceDeriveFromTheirPrimaries() {
    // BT.709-6 item 3.2 and BT.2020-2 Table 4 publish 4-decimal rounded rows.
    let rec709 = Self.luminanceRow(Source.rec709Primaries)
    let rec2020 = Self.luminanceRow(Source.rec2020Primaries)
    for (gamut, derived) in [(ColorGamut.rec709, rec709), (.rec2020, rec2020)] {
      let k = gamut.luminanceCoefficients
      XCTAssertEqual(k.r, derived.x, accuracy: 5e-5, "\(gamut)")
      XCTAssertEqual(k.g, derived.y, accuracy: 5e-5, "\(gamut)")
      XCTAssertEqual(k.b, derived.z, accuracy: 5e-5, "\(gamut)")
    }
    // The transport matrices are the published rounded constants, verbatim.
    XCTAssertTrue(YCbCrMatrix.bt601.coefficients == (0.299, 0.587, 0.114))
    XCTAssertTrue(YCbCrMatrix.bt709.coefficients == (0.2126, 0.7152, 0.0722))
    XCTAssertTrue(YCbCrMatrix.bt2020.coefficients == (0.2627, 0.6780, 0.0593))
    XCTAssertEqual(ColorGamut.rec709.luminanceCoefficients, ColorRGB(r: 0.2126, g: 0.7152, b: 0.0722))
    XCTAssertEqual(ColorGamut.rec2020.luminanceCoefficients, ColorRGB(r: 0.2627, g: 0.6780, b: 0.0593))
  }

  func testSGamut3CineLuminanceDerivesFromSonyPrimaries() {
    // Sony technical summary p.7 primaries; Sony's published matrix row is 10 decimals.
    let derived = Self.luminanceRow(Source.sGamut3CinePrimaries)
    let published = SIMD3(0.2150758201, 0.8850685017, -0.1001443219)
    XCTAssertLessThan(simd_reduce_max(simd_abs(derived - published)), 1e-10)
    let k = ColorGamut.sGamut3Cine.luminanceCoefficients
    XCTAssertEqual(k.r, derived.x, accuracy: 1e-12)
    XCTAssertEqual(k.g, derived.y, accuracy: 1e-12)
    XCTAssertEqual(k.b, derived.z, accuracy: 1e-12)
  }

  func testSGamut3LuminanceDerivesFromSonyPrimaries() {
    let derived = Self.luminanceRow(Source.sGamut3Primaries)
    // Sony's published S-Gamut/S-Gamut3 to XYZ matrix, row Y (10 decimals).
    let published = SIMD3(0.2709796708, 0.7866064112, -0.0575860820)
    XCTAssertLessThan(simd_reduce_max(simd_abs(derived - published)), 1e-10)
    let k = ColorGamut.sGamut3.luminanceCoefficients
    // 5e-11 admits Sony's 10-decimal row (MATH.md 9.1, fixed).
    XCTAssertLessThan(simd_reduce_max(simd_abs(SIMD3(k.r, k.g, k.b) - derived)), 5e-11, "\(k)")
  }

  func testWideGamutLuminanceRowsDeriveFromARRIPrimaries() {
    // ARRI publishes AWG3 to 6 decimals (ARRI-C3 appendix) and AWG4 to 10 (ARRI-C4 eq. 5a).
    let awg3 = Self.luminanceRow(Source.awg3Primaries)
    XCTAssertLessThan(simd_reduce_max(simd_abs(awg3 - SIMD3(0.291954, 0.823841, -0.115795))), 5e-7)
    let awg4 = Self.luminanceRow(Source.awg4Primaries)
    XCTAssertLessThan(
      simd_reduce_max(simd_abs(awg4 - SIMD3(0.2545241764, 0.7814777327, -0.0360019091))), 1e-10)
    for (gamut, derived, tolerance) in [(ColorGamut.arriWideGamut3, awg3, 5e-7), (.arriWideGamut4, awg4, 1e-10)] {
      let k = gamut.luminanceCoefficients
      XCTAssertLessThan(simd_reduce_max(simd_abs(SIMD3(k.r, k.g, k.b) - derived)), tolerance, "\(gamut)")
      XCTAssertEqual(k.r + k.g + k.b, 1, accuracy: 1e-9, "\(gamut) white has Y = 1")
    }
  }

  /// Camera gamut to Rec.709 (RP177: NPM_709⁻¹·NPM_camera, same D65 white), pinned for
  /// the planned analytic display transforms (MATH.md 5.1). Not in Core yet.
  func testCameraGamutToRec709MatricesDeriveFromPrimaries() {
    func npm(_ primaries: [(Double, Double)]) -> simd_double3x3 {
      func xyz(_ c: (Double, Double)) -> SIMD3<Double> { SIMD3(c.0 / c.1, 1, (1 - c.0 - c.1) / c.1) }
      let p = simd_double3x3(columns: (xyz(primaries[0]), xyz(primaries[1]), xyz(primaries[2])))
      let s = p.inverse * xyz(Source.d65)
      return simd_double3x3(columns: (p.columns.0 * s.x, p.columns.1 * s.y, p.columns.2 * s.z))
    }
    let pinned: [([(Double, Double)], [[Double]])] = [
      (Source.sGamut3CinePrimaries, [[1.6269474, -0.5401385, -0.0868089], [-0.1785155, 1.4179409, -0.2394254], [-0.0444361, -0.1959200, 1.2403561]]),
      (Source.sGamut3Primaries, [[1.8779151, -0.7941688, -0.0837464], [-0.1768070, 1.3509996, -0.1741926], [-0.0262011, -0.1484223, 1.1746234]]),
      (Source.awg3Primaries, [[1.6175234, -0.5372866, -0.0802368], [-0.0705727, 1.3346131, -0.2640403], [-0.0211017, -0.2269539, 1.2480556]]),
      (Source.awg4Primaries, [[1.8931234, -0.7808815, -0.1122419], [-0.2057004, 1.3402575, -0.1345571], [-0.0127057, -0.1521849, 1.1648906]]),
    ]
    let rec709 = npm(Source.rec709Primaries)
    for (primaries, rows) in pinned {
      let m = rec709.inverse * npm(primaries)
      for r in 0..<3 {
        // Same white point: every row sums to 1, so neutrals stay neutral.
        XCTAssertEqual(m[0][r] + m[1][r] + m[2][r], 1, accuracy: 1e-12)
        for c in 0..<3 { XCTAssertEqual(m[c][r], rows[r][c], accuracy: 5e-8, "\(primaries) [\(r)][\(c)]") }
      }
    }
  }

  /// The pass sends `log.gamut.luminanceCoefficients` to the GPU for stops on log
  /// sources (MATH.md 9.5, fixed: the profiles used Rec.709/Rec.2020 placeholders).
  private func assertProfileGamut(
    _ profile: ARRIFalseColorProfile, curve: LogCurve, primaries: [(Double, Double)]
  ) throws {
    let encoding = try XCTUnwrap(LogEncoding(profileID: profile.rawValue), "\(profile) has no LogEncoding")
    let k = encoding.gamut.luminanceCoefficients, derived = Self.luminanceRow(primaries)
    // AWG3 is published to 6 decimals (ARRI-C3 appendix), AWG4 to 10.
    XCTAssertLessThan(
      simd_reduce_max(simd_abs(SIMD3(k.r, k.g, k.b) - derived)), 5e-7, "\(profile) \(encoding.gamut)")
    XCTAssertEqual(encoding.curve, curve)
    XCTAssertEqual(encoding.profileID, profile.rawValue)
  }

  func testLogC3ProfileCarriesAWG3Luminance() throws {
    try assertProfileGamut(.logC3EI800, curve: .arriLogC3, primaries: Source.awg3Primaries)
  }

  func testLogC4ProfileCarriesAWG4Luminance() throws {
    try assertProfileGamut(.alexa35LogC4EI800, curve: .arriLogC4, primaries: Source.awg4Primaries)
  }

  // MARK: - Y'CbCr

  func testYCbCrDecodeInvertsTheRecommendationEncode() throws {
    // BT.601-7 §2.5.1, BT.709-6 items 3.2-3.3, BT.2020-2 Table 4: Cb = (B'-Y')/(2(1-kb)),
    // Cr = (R'-Y')/(2(1-kr)). Published divisors pin the constants.
    let divisors: [(YCbCrMatrix, Double, Double)] = [
      (.bt601, 1.772, 1.402), (.bt709, 1.8556, 1.5748), (.bt2020, 1.8814, 1.4746),
    ]
    for (matrix, cbDivisor, crDivisor) in divisors {
      let k = matrix.coefficients
      XCTAssertEqual(k.r + k.g + k.b, 1, accuracy: 1e-15)
      XCTAssertEqual(2 * (1 - k.b), cbDivisor, accuracy: 1e-12)
      XCTAssertEqual(2 * (1 - k.r), crDivisor, accuracy: 1e-12)
      var generator = SplitMix64(seed: 0x709)
      for _ in 0..<200 {
        let rgb = SIMD3(generator.unit() * 1.4 - 0.2, generator.unit() * 1.4 - 0.2, generator.unit() * 1.4 - 0.2)
        let y = k.r * rgb.x + k.g * rgb.y + k.b * rgb.z
        let decoded = try XCTUnwrap(
          ColorMath.yCbCrToRGB(y: y, cb: (rgb.z - y) / cbDivisor, cr: (rgb.x - y) / crDivisor, matrix: matrix))
        XCTAssertEqual(decoded.r, rgb.x, accuracy: 1e-12)
        XCTAssertEqual(decoded.g, rgb.y, accuracy: 1e-12)
        XCTAssertEqual(decoded.b, rgb.z, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(ColorMath.signalLuma(decoded, matrix: matrix)), y, accuracy: 1e-12)
      }
    }
  }

  func testQuantizationMatchesBT709AndBT2100Table9() throws {
    // Narrow: D = (219E' + 16)·2^(n-8), (224E' + 128)·2^(n-8). Full: (2^n - 1)E', (2^n - 1)E' + 2^(n-1).
    let published: [(Int, CodeRange, black: Double, white: Double, chromaLow: Double, centre: Double, chromaHigh: Double)] = [
      (8, .legal, 16, 235, 16, 128, 240),
      (10, .legal, 64, 940, 64, 512, 960),
      (12, .legal, 256, 3760, 256, 2048, 3840),
      (16, .legal, 4096, 60160, 4096, 32768, 61440),
      (10, .full, 0, 1023, 0.5, 512, 1023.5),
      (12, .full, 0, 4095, 0.5, 2048, 4095.5),
    ]
    for row in published {
      let (depth, range) = (row.0, row.1)
      XCTAssertEqual(try XCTUnwrap(range.normalizeLuma(code: row.black, bitDepth: depth)), 0, accuracy: 1e-15)
      XCTAssertEqual(try XCTUnwrap(range.normalizeLuma(code: row.white, bitDepth: depth)), 1, accuracy: 1e-15)
      XCTAssertEqual(try XCTUnwrap(range.normalizeChroma(code: row.centre, bitDepth: depth)), 0, accuracy: 1e-15)
      XCTAssertEqual(try XCTUnwrap(range.normalizeChroma(code: row.chromaLow, bitDepth: depth)), -0.5, accuracy: 1e-15)
      XCTAssertEqual(try XCTUnwrap(range.normalizeChroma(code: row.chromaHigh, bitDepth: depth)), 0.5, accuracy: 1e-15)
      XCTAssertEqual(try XCTUnwrap(range.lumaCode(normalized: 1, bitDepth: depth)), row.white, accuracy: 1e-9)
    }
    // Table 9 full-range chroma extremes round to 1 and 1023 (Round = sign·floor(|x| + 0.5)).
    XCTAssertEqual((1023 * -0.5 + 512).rounded(.toNearestOrAwayFromZero), 1)
    // `levels` is the GPU's copy of the same mapping; it must agree code for code.
    for depth in [8, 10, 12, 16] {
      for range in [CodeRange.legal, .full] {
        let l = range.levels(bitDepth: depth)
        for code in stride(from: 0.0, through: pow(2, Double(depth)) - 1, by: pow(2, Double(depth)) / 61) {
          XCTAssertEqual(
            (code - l.black) / l.span, try XCTUnwrap(range.normalizeLuma(code: code, bitDepth: depth)),
            accuracy: 1e-15)
          XCTAssertEqual(
            (code - l.center) / l.chromaSpan, try XCTUnwrap(range.normalizeChroma(code: code, bitDepth: depth)),
            accuracy: 1e-15)
        }
      }
    }
  }

  // MARK: - Native log codes in every container

  /// Narrow-range quantization scales by exactly 2^(n-8) (BT.709 item 3.4), and a
  /// camera's 10-bit code scales the same way, so the legal branches are exact at
  /// every depth: e = (c_n - 16s)/(219s) = (c10 - 64)/876 and (876e + 64)/1023 = c10/1023.
  func testNativeLogLegalAndFullNativeAreExactAtEveryDepth() throws {
    // The two worked cases from MATH.md 9.6: S-Log3 grey (code 420) at 8 and 12 bits.
    let grey8 = try XCTUnwrap(CodeRange.legal.normalizeLuma(code: 105, bitDepth: 8))
    XCTAssertEqual(
      DecodeReference.nativeLog(expanded: grey8, range: .legal, transport: .native), 420.0 / 1023, accuracy: 1e-15)
    let grey12 = try XCTUnwrap(CodeRange.legal.normalizeLuma(code: 1680, bitDepth: 12))
    XCTAssertEqual(
      DecodeReference.nativeLog(expanded: grey12, range: .legal, transport: .native), 420.0 / 1023, accuracy: 1e-15)
    for depth in [8, 10, 12, 16] {
      let scale = pow(2, Double(depth - 10)), maximum = pow(2, Double(depth)) - 1
      for code10 in stride(from: 0.0, through: 1023, by: depth == 8 ? 4 : 1) {
        // Legal container, camera codes stored verbatim (Sony).
        let legal = try XCTUnwrap(CodeRange.legal.normalizeLuma(code: code10 * scale, bitDepth: depth))
        XCTAssertEqual(
          DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .native), code10 / 1023,
          accuracy: 1e-14, "legal native \(depth)-bit code \(code10)")
        // Legal container carrying full-range codes squeezed into its own legal range.
        let t = code10 / 1023
        let squeezed = try XCTUnwrap(CodeRange.legal.lumaCode(normalized: t, bitDepth: depth))
        let squeezedExpanded = try XCTUnwrap(CodeRange.legal.normalizeLuma(code: squeezed, bitDepth: depth))
        XCTAssertEqual(
          DecodeReference.nativeLog(expanded: squeezedExpanded, range: .legal, transport: .fullRescaledToLegal), t,
          accuracy: 1e-14, "legal rescaled \(depth)-bit")
        // Full container: full-range codes are (2^n - 1)·t (BT.2100 Table 9).
        let full = try XCTUnwrap(CodeRange.full.normalizeLuma(code: t * maximum, bitDepth: depth))
        XCTAssertEqual(
          DecodeReference.nativeLog(expanded: full, range: .full, transport: .native), t, accuracy: 1e-14,
          "full native \(depth)-bit")
      }
    }
  }

  /// A full container carrying codes squeezed into the container's own legal range
  /// (16s…235s): t = (e·M - 16s)/(219s). The 10-bit-only formula (e·1023 - 64)/876
  /// it replaced was exact only at 10 bits (MATH.md 9.6, fixed). S-Log3 and LogC
  /// share the mapping in a full container.
  private func assertFullRescaled(depth: Int) throws {
    let s = pow(2, Double(depth - 8))
    var worst = 0.0
    for t in stride(from: 0.0, through: 1, by: 1.0 / 64) {
      let e = try XCTUnwrap(CodeRange.full.normalizeLuma(code: 16 * s + 219 * s * t, bitDepth: depth))
      for value in [
        DecodeReference.nativeLog(expanded: e, range: .full, transport: .fullRescaledToLegal, bitDepth: depth),
        LogCurve.sLog3.signal(expanded: e, range: .full, transport: .fullRescaledToLegal, bitDepth: depth),
        LogCurve.arriLogC4.signal(expanded: e, range: .full, transport: .fullRescaledToLegal, bitDepth: depth),
      ] { worst = max(worst, abs(value - t)) }
    }
    XCTAssertLessThan(worst, 1e-12, "full rescaled \(depth)-bit")
  }

  func testNativeLogFullContainerRescaled10Bit() throws { try assertFullRescaled(depth: 10) }

  func testNativeLogFullContainerRescaled8Bit() throws {
    // The size quoted in MATH.md 9.6: 8-bit legal white reads 1.00316.
    XCTAssertEqual((235.0 / 255 * 1023 - 64) / 876, 1.003156, accuracy: 1e-6)
    try assertFullRescaled(depth: 8)
  }

  func testNativeLogFullContainerRescaled12Bit() throws { try assertFullRescaled(depth: 12) }

  func testNativeLogFullContainerRescaled16Bit() throws { try assertFullRescaled(depth: 16) }

  /// ARRI carries LogC on legal SDI as 64 + 876·t (ARRI-FC §3.1; Table 9 puts grey
  /// at code 400 full, 406.5 legal), so in a legal container t is the expanded
  /// value. Sony stores S-Log3 codes verbatim (SONY-TS Q4). The default transport
  /// of an ARRI profile must therefore decode legal grey to 0.18 through
  /// `LogCurve.signal` (`mk_logSignal` on the GPU; MATH.md 9.7, fixed), and an
  /// ARRI full link full grey, 1023·t, the same way, at every container depth.
  private func assertARRIDefaultTransport(_ profile: ARRIFalseColorProfile, t: Double) throws {
    let encoding = try XCTUnwrap(LogEncoding(profileID: profile.rawValue))
    XCTAssertEqual(encoding.transport, .native)
    for depth in [8, 10, 12, 16] {
      let s = pow(2, Double(depth - 8)), maximum = pow(2, Double(depth)) - 1
      for (range, code) in [(CodeRange.legal, 16 * s + 219 * s * t), (.full, maximum * t)] {
        let e = try XCTUnwrap(range.normalizeLuma(code: code, bitDepth: depth))
        let signal = encoding.curve.signal(expanded: e, range: range, transport: encoding.transport, bitDepth: depth)
        let linear = try XCTUnwrap(encoding.curve.decode(signal))
        XCTAssertEqual(linear, 0.18, accuracy: 1e-6, "\(profile) \(range) \(depth)-bit grey decodes to \(linear)")
      }
    }
  }

  func testLogC3ProfileDefaultTransportDecodesLegalGrey() throws {
    let t = 0.247190 * log10(5.555556 * 0.18 + 0.052272) + 0.385537
    // The figures quoted in MATH.md 9.7 for code/1023: 406.52 → 0.19159, +0.090 stops.
    XCTAssertEqual(64 + 876 * t, 406.52, accuracy: 0.01)
    let misread = try XCTUnwrap(LogCurve.arriLogC3.decode((64 + 876 * t) / 1023))
    XCTAssertEqual(misread, 0.19159, accuracy: 1e-5)
    XCTAssertEqual(log2(misread / 0.18), 0.090, accuracy: 1e-3)
    try assertARRIDefaultTransport(.logC3EI800, t: t)
  }

  func testLogC4ProfileDefaultTransportDecodesLegalGrey() throws {
    let a = (pow(2.0, 18) - 16) / 117.45, b = (1023 - 95) / 1023.0, c = 95 / 1023.0
    let t = (log2(a * 0.18 + 64) - 6) / 14 * b + c
    // MATH.md 9.7 for code/1023: legal 307.9 → 0.23695, +0.397 stops.
    XCTAssertEqual(64 + 876 * t, 307.88, accuracy: 0.01)
    let misread = try XCTUnwrap(LogCurve.arriLogC4.decode((64 + 876 * t) / 1023))
    XCTAssertEqual(misread, 0.23695, accuracy: 1e-5)
    XCTAssertEqual(log2(misread / 0.18), 0.397, accuracy: 1e-3)
    try assertARRIDefaultTransport(.alexa35LogC4EI800, t: t)
  }

  // MARK: - Chroma siting

  /// Chroma sample positions in luma-sample units (horizontal, vertical) for
  /// ITU-T H.273 chroma_sample_loc_type 0-5; 4:2:2 uses the horizontal part.
  static let h273Siting: [(Double, Double)] = [(0, 0.5), (0.5, 0.5), (0, 0), (0.5, 0), (0, 1), (0.5, 1)]

  /// DecodeReference, which the GPU decode tests compare against, must sample chroma
  /// where H.273 puts it: 4:2:2 left co-sited with even luma (BT.709 item 4.3, BT.2100
  /// Table 8), centre midway; 4:2:0 rows midway (types 0, 1), on the even row
  /// (types 2, 3; BT.2020 and BT.2100) or on the odd row (types 4, 5).
  func testChromaTapsMatchH273Siting() {
    let (width, height) = (11, 7)
    let cases: [(ChromaSubsampling, ChromaSiting, ChromaVerticalSiting, Int)] = [
      (.s422, .left, .center, 0), (.s422, .center, .center, 1),
      (.s420, .left, .center, 0), (.s420, .center, .center, 1), (.s420, .left, .top, 2),
      (.s420, .center, .top, 3), (.s420, .left, .bottom, 4), (.s420, .center, .bottom, 5),
    ]
    for (subsampling, siting, vertical, type) in cases {
      let (offsetX, offsetY) = Self.h273Siting[type]
      // Neighbouring chroma samples and weight for a luma coordinate, clamped at the edges.
      func expected(_ p: Int, _ offset: Double, _ count: Int) -> (Int, Int, Double) {
        let c = (Double(p) - offset) / 2, f = c.rounded(.down)
        return (min(max(Int(f), 0), count - 1), min(max(Int(f) + 1, 0), count - 1), c - f)
      }
      for y in 0..<height {
        for x in 0..<width {
          let t = DecodeReference.chromaTaps(
            x: x, y: y, width: width, height: height, subsampling: subsampling, siting: siting,
            vertical: vertical)
          let what = "\(subsampling) \(siting) \(vertical) (\(x), \(y))"
          let ex = expected(x, offsetX, (width + 1) / 2)
          XCTAssertTrue(t.x0 == ex.0 && t.x1 == ex.1 && t.fx == ex.2, what)
          if subsampling == .s420 {
            let ey = expected(y, offsetY, (height + 1) / 2)
            XCTAssertTrue(t.y0 == ey.0 && t.y1 == ey.1 && t.fy == ey.2, what)
          } else {
            XCTAssertTrue(t.y0 == y && t.y1 == y && t.fy == 0, what)
          }
        }
      }
    }
    // Left siting: even luma columns read one chroma sample exactly.
    let even = DecodeReference.chromaTaps(x: 4, y: 0, width: width, height: height, subsampling: .s422, siting: .left)
    XCTAssertTrue(even.x0 == 2 && even.fx == 0)
  }

  func testColorBarVectorscopeTargets() throws {
    // 100% and 75% bars (ITU-R BT.2111 / SMPTE RP 219): R'G'B' ∈ {0, A}. Pins the
    // Cb/Cr targets a vectorscope graticule draws, and checks Core decodes them.
    let bars: [(String, SIMD3<Double>)] = [
      ("yellow", [1, 1, 0]), ("cyan", [0, 1, 1]), ("green", [0, 1, 0]),
      ("magenta", [1, 0, 1]), ("red", [1, 0, 0]), ("blue", [0, 0, 1]),
    ]
    // BT.709 10-bit narrow-range targets at 75%, rounded to codes.
    let codes75: [String: (cb: Double, cr: Double)] = [
      "yellow": (176, 543), "cyan": (589, 176), "green": (253, 207),
      "magenta": (771, 817), "red": (435, 848), "blue": (848, 481),
    ]
    for matrix in [YCbCrMatrix.bt709, .bt2020, .bt601] {
      let k = matrix.coefficients
      for (name, unit) in bars {
        for amplitude in [1.0, 0.75] {
          let rgb = unit * amplitude
          let y = k.r * rgb.x + k.g * rgb.y + k.b * rgb.z
          let cb = (rgb.z - y) / (2 * (1 - k.b)), cr = (rgb.x - y) / (2 * (1 - k.r))
          // Yellow and blue sit on the Cb rail, red and cyan on the Cr rail (±0.5·A).
          if ["yellow", "blue"].contains(name) { XCTAssertEqual(abs(cb), 0.5 * amplitude, accuracy: 1e-12) }
          if ["red", "cyan"].contains(name) { XCTAssertEqual(abs(cr), 0.5 * amplitude, accuracy: 1e-12) }
          let decoded = try XCTUnwrap(ColorMath.yCbCrToRGB(y: y, cb: cb, cr: cr, matrix: matrix))
          XCTAssertEqual(decoded.r, rgb.x, accuracy: 1e-12)
          XCTAssertEqual(decoded.g, rgb.y, accuracy: 1e-12)
          XCTAssertEqual(decoded.b, rgb.z, accuracy: 1e-12)
          if matrix == .bt709 && amplitude == 0.75, let target = codes75[name] {
            XCTAssertEqual((512 + 896 * cb).rounded(), target.cb, name)
            XCTAssertEqual((512 + 896 * cr).rounded(), target.cr, name)
          }
        }
      }
    }
  }

  // MARK: - Sony S-Log3

  func testSLog3MatchesTechnicalSummaryAppendix() throws {
    // Independent transcription of the appendix formulas (Sony technical summary p.6).
    func encode(_ x: Double) -> Double {
      x >= 0.01125
        ? (420 + log10((x + 0.01) / (0.18 + 0.01)) * 261.5) / 1023
        : (x * (171.2102946929 - 95) / 0.01125 + 95) / 1023
    }
    for x in stride(from: -0.014, through: 40, by: 0.0173) + [0, 0.01125, (0.01125).nextDown, 0.18, 0.9] {
      let code = encode(x)
      XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Encode(x)), code, accuracy: 1e-14)
      XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Decode(code)), x, accuracy: 2e-12 * max(1, x))
      XCTAssertEqual(try XCTUnwrap(LogCurve.sLog3.decode(code)), x, accuracy: 2e-12 * max(1, x))
    }
    // Breakpoint: the log branch reaches 171.2102946928606, Sony's constant to 4e-11 codes.
    let logBranch = 420 + log10((0.01125 + 0.01) / 0.19) * 261.5
    XCTAssertEqual(logBranch, 171.2102946929, accuracy: 1e-9)
    // Published code values: 95 (0%), 420 (18%), 598 (90%, Round).
    XCTAssertEqual(encode(0) * 1023, 95, accuracy: 1e-12)
    XCTAssertEqual(encode(0.18) * 1023, 420, accuracy: 1e-12)
    XCTAssertEqual((encode(0.9) * 1023).rounded(), 598)
    XCTAssertEqual(try XCTUnwrap(LogCurve.sLog3.decode(420.0 / 1023)), 0.18, accuracy: 1e-14)
  }

  func testSonyIREScaleMatchesTechnicalSummary() throws {
    // FAQ Q4: full range 0…1023 is -7…109 IRE; legal 64…940 is 0…100 IRE.
    // Appendix table: 0% black 3.5% (CV 95), 18% grey 41% (CV 420), 90% white 61% (CV 598).
    func ire(_ code: Double) throws -> Double { try XCTUnwrap(SonySLog3FalseColor.ire(nativeNormalized: code / 1023)) }
    XCTAssertEqual(try ire(64), 0, accuracy: 1e-12)
    XCTAssertEqual(try ire(940), 100, accuracy: 1e-12)
    XCTAssertEqual(try ire(0), -7, accuracy: 0.5)
    XCTAssertEqual(try ire(1023), 109, accuracy: 0.5)
    XCTAssertEqual(try ire(95), 3.5, accuracy: 0.05)
    XCTAssertEqual(try ire(420), 41, accuracy: 0.5)
    XCTAssertEqual(try ire(598), 61, accuracy: 0.5)
    // Pattern 2: native 18% grey is green, native black is blue, the floor is purple.
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: 420.0 / 1023), .green)
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: 95.0 / 1023), .blue)
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: 64.0 / 1023), .purple)
    // Codes 0-2 sit below -7.0 IRE (code 0 is -7.31), outside Sony's lowest band.
    XCTAssertNil(SonySLog3FalseColor.category(nativeSignalLuma: 0))
  }

  func testSonyPattern2TableMatchesMonitorAndControlHelpGuide() {
    let published: [(SonyFalseColorCategory, Double, Double)] = [
      (.red, 93.4, 96.1), (.orange, 87.7, 90.6), (.yellow, 91.3, 93.4), (.cyan, 43.8, 46.5),
      (.pink, 54.3, 58), (.lightPink, 47.8, 50.8), (.green, 38.9, 42.2), (.lightBlue, 24.6, 34.4),
      (.blue, 3.5, 5.6), (.purple, -7.0, 3.5),
    ]
    XCTAssertEqual(SonySLog3FalseColor.zones.count, published.count)
    for (category, lower, upper) in published {
      let zone = SonySLog3FalseColor.zones.first { $0.category == category }
      XCTAssertEqual(zone?.lowerIRE, lower, "\(category)")
      XCTAssertEqual(zone?.upperIRE, upper, "\(category)")
    }
  }

  // MARK: - ARRI LogC3 and LogC4

  func testLogC3EI800MatchesARRIWhitePaper() throws {
    // ALEXA Log C Curve, Usage in VFX (2017), p.4 formula, exposure-value table EI 800.
    let (cut, a, b, c, d, e, f) = (0.010591, 5.555556, 0.052272, 0.247190, 0.385537, 5.367655, 0.092809)
    func encode(_ x: Double) -> Double { x > cut ? c * log10(a * x + b) + d : e * x + f }
    XCTAssertEqual(encode(0.18), 0.391007, accuracy: 5e-7)
    XCTAssertEqual(encode(0), 0.092809, accuracy: 1e-15)
    // The table lists e·cut + f = 0.149658; the rounded parameters meet within 3e-7.
    XCTAssertEqual(e * cut + f, 0.149658, accuracy: 5e-7)
    XCTAssertEqual(c * log10(a * cut + b) + d, e * cut + f, accuracy: 3e-7)
    // The log branch starts 2.5e-7 below the linear one, so for x in (cut, cut + 5e-8]
    // the decode takes the linear branch: an inherent 5e-8 round-trip gap.
    XCTAssertEqual(try XCTUnwrap(LogCurve.arriLogC3.decode(encode(cut.nextUp))), cut, accuracy: 5e-8)
    for x in stride(from: -0.017, through: 55, by: 0.0191) + [0, cut, 1e-7 + cut, 0.18] {
      let t = encode(x)
      XCTAssertEqual(try XCTUnwrap(LogCurve.arriLogC3.decode(t)), x, accuracy: 1e-11 * max(1, x))
      // The Sony adaptation's encoder is a second, independent Core path.
      XCTAssertEqual(
        try XCTUnwrap(SonyARRIStyleFalseColor.referenceCode(sceneLinearLuma: x)), t * 1023, accuracy: 1e-9)
    }
  }

  func testLogC4MatchesARRISpecification() throws {
    // ARRI LogC4 specification, eqs 1b, 1c, 2, 2a-2c, 3; Appendix B reference values.
    let a = (pow(2.0, 18) - 16) / 117.45, b = (1023 - 95) / 1023.0, c = 95 / 1023.0
    let s = 7 * log(2.0) * pow(2.0, 7 - 14 * c / b) / (a * b)
    let t = (pow(2.0, 14 * (-c / b) + 6) - 64) / a
    func encode(_ x: Double) -> Double { x >= t ? (log2(a * x + 64) - 6) / 14 * b + c : (x - t) / s }
    XCTAssertEqual(117.45, 0.18 / (400.0 / 260_991), accuracy: 5e-3)  // eq 4, "the rounded version"
    XCTAssertEqual(encode(0.18), 0.278396, accuracy: 5e-7)
    XCTAssertEqual(encode(0.18), 0.2784, accuracy: 5e-5)
    XCTAssertEqual(encode(0), 95 / 1023.0, accuracy: 1e-15)
    XCTAssertEqual(try XCTUnwrap(LogCurve.arriLogC4.decode(1)), 469.8, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(LogCurve.arriLogC4.decode(0)), t, accuracy: 1e-15)
    XCTAssertEqual(t, -0.0181, accuracy: 5e-5)
    // s is the inverse slope of the log branch at t: value and slope continuous.
    XCTAssertEqual(encode(t.nextUp), 0, accuracy: 1e-12)
    let slope = b / 14 * a / ((a * t + 64) * log(2.0))
    XCTAssertEqual(slope, 1 / s, accuracy: 1e-12)
    for x in stride(from: -0.05, through: 469.8, by: 0.0937) + [0, t, 0.18] {
      XCTAssertEqual(try XCTUnwrap(LogCurve.arriLogC4.decode(encode(x))), x, accuracy: 1e-11 * max(1, x))
    }
  }

  func testLogC4EI800FalseColorTableDerivesFromSpecification() throws {
    // False color spec 2025-02-04 §5.1.1: Bz = f_hw(F/N, EI), N = 260991, Tables 16/17;
    // f_hw is LogC4 spec eq 1 with a_h = (2^18 - 16)·EI/800. Published bounds are Round().
    let b = (1023 - 95) / 1023.0, c = 95 / 1023.0, n = 260_991.0
    func hardware(_ sensor: Double, ei: Double) -> Double {
      min((log2((pow(2.0, 18) - 16) * ei / 800 * sensor / n + 64) - 6) / 14 * b + c, 1)
    }
    let bounds: [(ARRIFalseColorCategory, Double?, Double?, Double)] = [
      (.red, 207_148.69398, nil, 800), (.yellow, 164_414.02737, 207_148.69398, 800),
      (.pink, 1440, 1760, 400), (.green, 720, 880, 400), (.blue, 3, 12, 800), (.purple, nil, 3, 800),
    ]
    for range in [CodeRange.legal, .full] {
      let zones = ARRIFalseColorProfile.alexa35LogC4EI800.zones(range: range)
      func code(_ sensor: Double?, ei: Double, empty: Double) -> Double {
        guard let sensor else { return empty }
        let e = hardware(sensor, ei: ei)
        return (range == .legal ? e * 876 + 64 : e * 1023).rounded()
      }
      for (category, lower, upper, ei) in bounds {
        let zone = try XCTUnwrap(zones.first { $0.category == category })
        XCTAssertEqual(zone.lower, code(lower, ei: ei, empty: range == .legal ? 64 : 0), "\(category) \(range)")
        XCTAssertEqual(zone.upper, code(upper, ei: ei, empty: range == .legal ? 940 : 1023), "\(category) \(range)")
      }
    }
  }

  func testLogC3EI800AnchorsFallInPublishedZones() throws {
    // Table 9 has no published derivation; check that 18% grey and one stop over land
    // in green and pink in both tables (exposure-value curve, as the Sony adaptation uses).
    let profile = ARRIFalseColorProfile.logC3EI800
    for (linear, category) in [(0.18, ARRIFalseColorCategory.green), (0.36, .pink)] {
      let normalized = try XCTUnwrap(SonyARRIStyleFalseColor.referenceCode(sceneLinearLuma: linear)) / 1023
      XCTAssertEqual(profile.category(achromaticCode: normalized * 1023, range: .full), category)
      XCTAssertEqual(profile.category(achromaticCode: normalized * 876 + 64, range: .legal), category)
    }
    // ARRI equation 1 weights are Rec.709's, applied to log RGB.
    let rgb = ColorRGB(r: 0.3, g: 0.6, b: 0.1)
    let a = 0.21260 * 0.3 + 0.71520 * 0.6 + 0.07220 * 0.1
    XCTAssertEqual(profile.color(rgb: rgb, range: .full), ColorRGB(r: a, g: a, b: a))
  }

  // MARK: - Display transfers (BT.709, BT.1886, sRGB, PQ, HLG)

  func testRec709OETFAndSixBandAnchors() {
    // BT.709-6 item 1.2. The rounded 1.099/0.099/0.018 constants leave a 2.5e-4 step
    // at L = 0.018 (0.081 vs 0.0812479); the inverse below splits at 0.081.
    XCTAssertEqual(Reference.oetf709((0.018).nextDown), 0.081, accuracy: 1e-12)
    XCTAssertEqual(Reference.oetf709(0.018), 0.08124794403514, accuracy: 1e-12)
    let grey = Reference.oetf709(0.18) * 100, overOne = Reference.oetf709(0.36) * 100
    XCTAssertEqual(grey, 40.90077, accuracy: 1e-5)
    XCTAssertEqual(overOne, 59.49590, accuracy: 1e-5)
    for x in stride(from: 0.0, through: 1.09, by: 0.0071) + [(0.018).nextDown, 0.018] {
      XCTAssertEqual(Reference.inverseOETF709(Reference.oetf709(x)), x, accuracy: 1e-13)
    }
    // Six-band convention: grey lands in green and +1 stop in pink.
    XCTAssertEqual(FalseColorBands.color(grey, bands: SixBandFalseColor.bands), ColorRGB(r: 0, g: 1, b: 0))
    XCTAssertEqual(
      FalseColorBands.color(overOne, bands: SixBandFalseColor.bands), ColorRGB(r: 1, g: 0.45, b: 0.75))
    let bands = SixBandFalseColor.bands
    XCTAssertTrue(zip(bands, bands.dropFirst()).allSatisfy { $0.upper <= $1.lower }, "bands must not overlap")
  }

  func testBT2020ExactTransferConstantsSolveItsSimultaneousEquations() {
    // BT.2020-2 Table 4: α·β^0.45 − α + 1 = 4.5β and 0.45·α·β^(−0.55) = 4.5.
    let alpha = 1.09929682680944, beta = 0.018053968510807
    XCTAssertEqual(alpha * pow(beta, 0.45) - alpha + 1, 4.5 * beta, accuracy: 1e-13)
    XCTAssertEqual(0.45 * alpha * pow(beta, -0.55), 4.5, accuracy: 1e-12)
  }

  func testBT1886EOTF() {
    // BT.1886 Annex 1: L = a·max(V + b, 0)^2.4, V = 0 → LB, V = 1 → LW.
    for (white, black) in [(100.0, 0.0), (100, 0.1), (203, 0.005)] {
      let gamma = 2.4
      let a = pow(pow(white, 1 / gamma) - pow(black, 1 / gamma), gamma)
      let b = pow(black, 1 / gamma) / (pow(white, 1 / gamma) - pow(black, 1 / gamma))
      func eotf(_ v: Double) -> Double { a * pow(max(v + b, 0), gamma) }
      XCTAssertEqual(eotf(0), black, accuracy: 1e-12)
      XCTAssertEqual(eotf(1), white, accuracy: 1e-10)
      if black == 0 { XCTAssertEqual(eotf(0.5), white * pow(0.5, 2.4), accuracy: 1e-12) }
    }
  }

  func testSRGBPiecewiseCurveIsContinuous() {
    // IEC 61966-2-1: decode splits at 0.04045, encode at 0.0031308 (as in mk_srgbDecode).
    XCTAssertEqual(0.04045 / 12.92, pow((0.04045 + 0.055) / 1.055, 2.4), accuracy: 1e-7)
    XCTAssertEqual(0.0031308 * 12.92, 1.055 * pow(0.0031308, 1 / 2.4) - 0.055, accuracy: 1e-6)
    XCTAssertEqual(Reference.srgbDecode(1), 1, accuracy: 1e-15)
  }

  func testPQMatchesST2084AndBT2408() {
    // ST 2084 / BT.2100 Table 4 constants, verbatim rationals.
    XCTAssertEqual(Reference.pqM1, 0.1593017578125)
    XCTAssertEqual(Reference.pqM2, 78.84375)
    XCTAssertEqual(Reference.pqC1, 0.8359375)
    XCTAssertEqual(Reference.pqC2, 18.8515625)
    XCTAssertEqual(Reference.pqC3, 18.6875)
    XCTAssertEqual(Reference.pqC1, Reference.pqC3 - Reference.pqC2 + 1)
    XCTAssertEqual(Reference.pqEncode(nits: 100), 0.508078421517399, accuracy: 1e-12)
    XCTAssertEqual(Reference.pqEncode(nits: 1000), 0.751827096247041, accuracy: 1e-12)
    XCTAssertEqual(Reference.pqEncode(nits: 10_000), 1, accuracy: 1e-15)
    XCTAssertEqual((Reference.pqEncode(nits: 100) * 876 + 64).rounded(), 509)
    // BT.2408-8 Table 1: 18% grey 26 cd/m² = 38 %PQ, reference white 203 cd/m² = 58 %PQ.
    XCTAssertEqual((Reference.pqEncode(nits: 26) * 100).rounded(), 38)
    XCTAssertEqual((Reference.pqEncode(nits: 203) * 100).rounded(), 58)
    for nits in [0.0, 0.005, 0.1, 1, 26, 100, 203, 1000, 4000, 10_000] {
      XCTAssertEqual(Reference.pqDecode(Reference.pqEncode(nits: nits)), nits, accuracy: 1e-9 * max(1, nits))
    }
  }

  func testHLGMatchesBT2100AndBT2408() {
    // BT.2100 Table 5 and note 5c: b = 1 − 4a = 0.28466892, c = 0.5 − a·ln(4a) = 0.55991073.
    XCTAssertEqual(Reference.hlgB, 0.28466892, accuracy: 1e-15)
    XCTAssertEqual(Reference.hlgC, 0.55991073, accuracy: 5e-9)
    // E' = 0.5 at E = 1/12 from both branches; E = 1 reaches 1 within the rounding of a.
    XCTAssertEqual(Reference.hlgOETF(1.0 / 12), 0.5, accuracy: 1e-15)
    XCTAssertEqual(Reference.hlgA * log(12 * (1.0 / 12) - Reference.hlgB) + Reference.hlgC, 0.5, accuracy: 1e-8)
    XCTAssertEqual(Reference.hlgOETF(1), 1, accuracy: 1e-8)
    for e in stride(from: 0.0, through: 1, by: 0.0123) {
      XCTAssertEqual(Reference.hlgInverseOETF(Reference.hlgOETF(e)), e, accuracy: 1e-13)
    }
    // BT.2408-8 Table 1 on a 1000 cd/m² display (system gamma 1.2, achromatic):
    // 26 cd/m² → 38 %HLG, 203 cd/m² → 75 %HLG.
    func signal(nits: Double) -> Double { Reference.hlgOETF(pow(nits / 1000, 1 / 1.2)) }
    XCTAssertEqual((signal(nits: 26) * 100).rounded(), 38)
    XCTAssertEqual((signal(nits: 203) * 100).rounded(), 75)
    // Note 5f: γ = 1.2 + 0.42·log10(LW/1000).
    XCTAssertEqual(1.2 + 0.42 * log10(2000.0 / 1000), 1.32643, accuracy: 1e-5)
  }

  /// Stops over 18 % grey on HDR signals (MATH.md 4.6 and 9.8). PQ is display
  /// light: grey 26 cd/m², reference white 203 (BT.2408 Table 1). HLG inverted with
  /// its OETF is scene light; grey and white scene values follow from BT.2408
  /// through the inverse OOTF at 1000 cd/m² (γ = 1.2).
  func testStopsOnHDRSignalsUseTheirOwnTransfer() {
    XCTAssertEqual(log2(Reference.pqDecode(Reference.pqEncode(nits: 26)) / 26), 0, accuracy: 1e-9)
    XCTAssertEqual(log2(Reference.pqDecode(Reference.pqEncode(nits: 203)) / 26), 2.964896, accuracy: 1e-6)
    let greyScene = pow(26.0 / 1000, 1 / 1.2), whiteScene = pow(203.0 / 1000, 1 / 1.2)
    let hlgStops = { (signal: Double) in log2(Reference.hlgInverseOETF(signal) / greyScene) }
    XCTAssertEqual(hlgStops(Reference.hlgOETF(greyScene)), 0, accuracy: 1e-12)
    // Scene-referred: log2(203/26)/1.2. With the OOTF (display light) it is 2.965.
    XCTAssertEqual(hlgStops(Reference.hlgOETF(whiteScene)), 2.470747, accuracy: 1e-6)
    XCTAssertEqual(hlgStops(Reference.hlgOETF(whiteScene)) * 1.2, log2(203.0 / 26), accuracy: 1e-12)
    // Core's measure (`DisplayTransfer.exposureLinear`, mirrored by `mk_exposureLinear`).
    let stops = { (transfer: DisplayTransfer, signal: Double) in log2(transfer.exposureLinear(signal) / 0.18) }
    XCTAssertEqual(stops(.pq, Reference.pqEncode(nits: 26)), 0, accuracy: 1e-9)
    XCTAssertEqual(stops(.pq, Reference.pqEncode(nits: 203)), 2.964896, accuracy: 1e-6)
    XCTAssertEqual(stops(.hlg, 0.38), 0, accuracy: 1e-12)
    // BT.2408's 38% is the OETF of the scene grey (26/1000)^(1/1.2), 0.3786, rounded.
    XCTAssertEqual(Reference.hlgOETF(greyScene), 0.3786, accuracy: 1e-4)
    XCTAssertEqual(stops(.sRGB, Reference.srgbEncode(0.18)), 0, accuracy: 1e-12)
    XCTAssertEqual(stops(.linear, 0.36), 1, accuracy: 1e-12)
    XCTAssertEqual(stops(.bt709, Reference.oetf709(0.18)), 0, accuracy: 1e-12)
    // The figures quoted in MATH.md 9.8 (fixed): what the BT.709 inverse OETF, once
    // applied to every non-log source, read on these signals.
    let bt709Stops = { (signal: Double) in log2(ColorMath.bt709Linear(signal) / 0.18) }
    XCTAssertEqual(bt709Stops(0.38), -0.19, accuracy: 0.005)
    XCTAssertEqual(bt709Stops(0.58), 0.93, accuracy: 0.005)
    XCTAssertEqual(bt709Stops(0.75), 1.65, accuracy: 0.005)
  }

  // MARK: - Vectorscope skin-tone line

  /// The NTSC I axis, I = -sin 33°·U + cos 33°·V with U = 0.492111(B'-Y') and
  /// V = 0.877283(R'-Y') (SMPTE 170M; FCC I = 0.5959R - 0.2746G - 0.3213B), lies at
  /// 123° in the U/V plane. A Cb/Cr plot scales the axes differently, so the same
  /// hue sits at 132.5° (BT.601) and 134.5° (BT.709).
  func testSkinToneLineIsTheNTSCIAxis() {
    let rotation = 33 * Double.pi / 180
    let (u, v) = (-sin(rotation), cos(rotation))
    XCTAssertEqual(atan2(v, u) * 180 / .pi, 123, accuracy: 1e-12)
    // The FCC I row, recovered from the U/V definition.
    let bY = -sin(rotation) * 0.492111, rY = cos(rotation) * 0.877283
    let k = YCbCrMatrix.bt601.coefficients
    XCTAssertEqual(rY - (bY + rY) * k.r, 0.5959, accuracy: 5e-4)
    XCTAssertEqual(-(bY + rY) * k.g, -0.2746, accuracy: 5e-4)
    XCTAssertEqual(bY - (bY + rY) * k.b, -0.3213, accuracy: 5e-4)
    // The same chroma direction in Cb/Cr.
    let (bMinusY, rMinusY) = (u / 0.492111, v / 0.877283)
    for (matrix, angle) in [(YCbCrMatrix.bt601, 132.48), (.bt709, 134.49)] {
      let k = matrix.coefficients
      let cb = bMinusY / (2 * (1 - k.b)), cr = rMinusY / (2 * (1 - k.r))
      XCTAssertEqual(atan2(cr, cb) * 180 / .pi, angle, accuracy: 0.01, "\(matrix)")
    }
  }

  // MARK: - LUT interpolation

  func testTetrahedralMatchesIndependentBarycentricReference() throws {
    var generator = SplitMix64(seed: 0x4C5554)
    for size in [2, 17, 33] {
      let lut = try Self.cube(size: size) { _ in
        SIMD3(Float(generator.unit()), Float(generator.unit()), Float(generator.unit()))
      }
      for _ in 0..<400 {
        let rgb = SIMD3(Float(generator.unit()), Float(generator.unit()), Float(generator.unit())) * 1.2 - 0.1
        let expected = Self.barycentric(lut, rgb)
        let actual = lut.apply(rgb, interpolation: .tetrahedral)
        XCTAssertLessThan(simd_reduce_max(simd_abs(actual - expected)), 2e-6, "size \(size) at \(rgb)")
      }
    }
  }

  func testTetrahedralAndTrilinearReproduceAffineLUTsExactly() throws {
    // Both schemes are exact for affine functions of the lattice coordinates.
    let m = simd_float3x3(rows: [[0.8, 0.15, 0.05], [0.1, 0.7, 0.2], [-0.05, 0.1, 0.95]])
    let offset = SIMD3<Float>(0.01, -0.02, 0.03)
    for size in [2, 17, 33] {
      let lut = try Self.cube(size: size) { m * $0 + offset }
      var generator = SplitMix64(seed: UInt64(size))
      for _ in 0..<300 {
        let rgb = SIMD3(Float(generator.unit()), Float(generator.unit()), Float(generator.unit()))
        for mode in [LUTInterpolation.tetrahedral, .trilinear] {
          let error = simd_abs(lut.apply(rgb, interpolation: mode) - (m * rgb + offset))
          XCTAssertLessThan(simd_reduce_max(error), 3e-6, "\(mode) size \(size)")
        }
      }
      // Lattice points come back exactly.
      let step = 1 / Float(size - 1)
      let point = SIMD3<Float>(Float(size - 1), 0, Float(size / 2)) * step
      XCTAssertEqual(lut.apply(point), lut.lattice(size - 1, 0, size / 2))
    }
  }

  func testTetrahedralKeepsNeutralsOnTheDiagonal() throws {
    // A neutral input only touches c000 and c111, so a LUT whose diagonal is neutral
    // keeps neutrals neutral whatever its off-diagonal entries are.
    var generator = SplitMix64(seed: 7)
    let size = 17
    let lut = try Self.cube(size: size) { p in
      p.x == p.y && p.y == p.z
        ? SIMD3(repeating: p.x * p.x)
        : SIMD3(Float(generator.unit()), Float(generator.unit()), Float(generator.unit()))
    }
    for v in stride(from: Float(0), through: 1, by: 0.0137) {
      let out = lut.apply(SIMD3(repeating: v), interpolation: .tetrahedral)
      XCTAssertEqual(out.x, out.y)
      XCTAssertEqual(out.y, out.z)
    }
  }

  // MARK: - Audio (BS.1770 / EBU R 128)

  func testKWeightingPrototypeReproducesBS1770Tables() {
    // BS.1770-5 Annex 1 Tables 1 and 2 at 48 kHz.
    let shelf = Reference.kWeightingShelf(sampleRate: 48_000)
    let published1: [Double] = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
    for (value, expected) in zip(shelf.b + shelf.a, published1) { XCTAssertEqual(value, expected, accuracy: 1e-13) }
    let highPass = Reference.kWeightingHighPass(sampleRate: 48_000)
    let published2: [Double] = [1, -2, 1, -1.99004745483398, 0.99007225036621]
    for (value, expected) in zip(highPass.b + highPass.a, published2) { XCTAssertEqual(value, expected, accuracy: 1e-13) }
    // Annex 1 note 1: −0.691 cancels the K-weighting gain at 997 Hz.
    let gain = Reference.magnitude(shelf, hz: 997, sampleRate: 48_000) * Reference.magnitude(highPass, hz: 997, sampleRate: 48_000)
    XCTAssertEqual(20 * log10(gain), 0.691, accuracy: 5e-4)
  }

  func testTruePeakInterpolatorIsTheAnnex2Filter() {
    // BS.1770-5 Annex 2: 48-tap, 4-phase FIR for 4× oversampling at 48 kHz.
    let phases = Reference.truePeakPhases
    XCTAssertEqual(phases.count, 4)
    XCTAssertTrue(phases.allSatisfy { $0.count == 12 })
    XCTAssertEqual(phases[3], Array(phases[0].reversed()))
    XCTAssertEqual(phases[2], Array(phases[1].reversed()))
    // Phase DC gains are 1.00159 and 0.97302 (+0.014 dB, −0.237 dB): the filter is
    // an example, not unity-gain per phase.
    XCTAssertEqual(phases[0].reduce(0, +), 1.0015869140625, accuracy: 1e-13)
    XCTAssertEqual(phases[1].reduce(0, +), 0.9730224609375, accuracy: 1e-13)
  }

  // MARK: - Shipped Audio and Scopes constants agree with the sources

  /// This target cannot import MonitorKitAudio or MonitorKitScopes, so their literal
  /// constants are read from the Swift text, as the shader guard reads the MSL. The
  /// behaviour (K-weighting tables, gating, ballistics, true-peak cases) is tested
  /// in MonitorKitAudioTests; these constants had no check anywhere.
  func testShippedTruePeakTapsAreTheAnnex2Filter() throws {
    let filters = try Self.packageText("Sources/MonitorKitAudio/Filters.swift")
    let phases = try Self.balanced(after: "static let phases: [[Float]] =", open: "[", close: "]", in: filters)
    XCTAssertEqual(try Self.signedLiterals(in: phases), Reference.truePeakPhases.flatMap { $0 })
  }

  func testShippedScopeTransfersAreST2084AndBT2100() throws {
    let graticule = try Self.packageText("Sources/MonitorKitScopes/ScopeGraticule.swift")
    let transfer = Self.squashed(try Self.balanced(after: "public enum ScopeTransfer", open: "{", close: "}", in: graticule))
    // The same rationals and formulas the PQ/HLG tests above check against BT.2100 Tables 4 and 5.
    let expressions = [
      "m1=2610.0/16384", "m2=2523.0/4096*128", "c1=3424.0/4096", "c2=2413.0/4096*32", "c3=2392.0/4096*32",
      "y=pow(max(0,nits)/10000,m1)", "pow((c1+c2*y)/(1+c3*y),m2)",
      "hlgA=0.17883277", "hlgB=1-4*hlgA", "hlgC=0.5-hlgA*log(4*hlgA)",
      "e<=1.0/12?sqrt(3*e):hlgA*log(12*e-hlgB)+hlgC", "s<=0.5?s*s/3:(exp((s-hlgC)/hlgA)+hlgB)/12",
      "1.2+0.42*log10(peak/1000)", "hlgOETF(pow(max(0,nits)/peak,1/hlgGamma(peak:peak)))",
    ]
    for expression in expressions {
      XCTAssertTrue(transfer.contains(expression), "ScopeTransfer no longer contains \(expression)")
    }
    let bars = Self.squashed(try Self.balanced(after: "public static func bars(", open: "{", close: "}", in: graticule))
    XCTAssertTrue(bars.contains("cb:(rgb.b-y)/(2*(1-k.b))") && bars.contains("cr:(rgb.r-y)/(2*(1-k.r))"))
    let settings = Self.squashed(try Self.packageText("Sources/MonitorKitScopes/ScopeSettings.swift"))
    XCTAssertTrue(settings.contains("varskinToneAngle=123.0"), "the skin-tone default moved off the NTSC I axis")
  }

  // MARK: - Shader constants agree with the sources

  /// False-colour tables and gamut weights reach the GPU from Core (`FalseColorTable`,
  /// `ColorGamut`), so only the curve constants written into the MSL text need a guard.
  /// It checks presence only; `testShaderCurvesMatchTheCPUReferenceOnTheGPU` checks
  /// the arithmetic.
  func testShaderCurveConstantsMatchSources() throws {
    let expected: [(String, String, [Float])] = [
      ("MKMonitor.msl", "float mk_sLog3Decode", [1023, 171.2102946929, 420, 261.5, 0.19, 0.01, 95, 0.01125]),
      ("MKMonitor.msl", "float mk_logC3Decode", [5.367655, 0.010591, 0.092809, 0.385537, 0.247190, 0.052272, 5.555556]),
      ("MKMonitor.msl", "float mk_logC4Decode", [262_144, 16, 117.45, 1023, 95, 7, 14, 6, 64]),
      ("MKMonitor.msl", "float mk_logC3ReferenceCode", [0.010591, 0.247190, 5.555556, 0.052272, 0.385537, 5.367655, 0.092809, 1023]),
      ("MKMonitor.msl", "float mk_bt709Linear", [0.081, 4.5, 0.099, 1.099, 0.45]),
      ("MKMonitor.msl", "float3 mk_srgbDecode", [0.04045, 12.92, 0.055, 1.055, 2.4]),
      ("MKMonitor.msl", "inline float mk_luma709", [0.2126, 0.7152, 0.0722]),
      ("MKDecode.msl", "float3 mk_nativeLog", [1023, 64, 876]),
      ("MKDecode.msl", "float3 mk_unsqueezeLegal", [1, 256, 16, 219]),
    ]
    for (file, signature, constants) in expected {
      let literals = Set(try Self.literals(in: Self.mslFunction(signature, in: file)))
      for constant in constants {
        XCTAssertTrue(literals.contains(constant), "\(signature) no longer contains \(constant)")
      }
    }
    // Sony native IRE (SONY-TS Q4) sits inside a larger function, so match the expression.
    let logFalseColor = Self.squashed(try Self.mslFunction("float3 mk_logFalseColor", in: "MKMonitor.msl"))
    XCTAssertTrue(logFalseColor.contains("(signal*1023-64)/876*100"), "Sony IRE is no longer (code - 64)/876·100")
  }

  /// Every curve the shaders evaluate, at every 10-bit code, on the GPU against the
  /// Core reference that the tests above tie to the primary sources. This catches
  /// operator and branch changes the constant guard cannot.
  func testShaderCurvesMatchTheCPUReferenceOnTheGPU() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw XCTSkip("No Metal device")
    }
    let source = try ["MKLUT.msl", "MKDecode.msl", "MKMonitor.msl"].map(Self.msl).joined(separator: "\n")
    let options = MTLCompileOptions()
    options.mathMode = .safe  // as MonitorShaders.makeLibrary
    if #available(macOS 27.0, iOS 27.0, *) {
      options.languageVersion = .version4_1
    } else {
      options.languageVersion = .version4_0
    }
    let library = try device.makeLibrary(source: source + "\n" + Self.curveKernel, options: options)
    let pipeline = try device.makeComputePipelineState(
      function: try XCTUnwrap(library.makeFunction(name: "mkmath_curves")))
    let count = 1024, outputs = 14
    // LogC3 reference-encode inputs: every code's LogC3 decode, so the outputs span the codes.
    let linear = try (0..<count).map { Float(try XCTUnwrap(LogCurve.arriLogC3.decode(Double($0) / 1023))) }
    // mk_FrameParams (20 words) for 10-bit (legal, native), (legal, rescaled), (full, native),
    // (full, rescaled), then (full, rescaled) at 8, 12 and 16 bits: options.y (word 5) is
    // full range, options.z (word 6) rescaled, levels (words 12-15) as MonitorFrame sets them.
    let frameCases: [(CodeRange, rescaled: Bool, depth: Int)] = [
      (.legal, false, 10), (.legal, true, 10), (.full, false, 10), (.full, true, 10),
      (.full, true, 8), (.full, true, 12), (.full, true, 16),
    ]
    var frames = [UInt32](repeating: 0, count: frameCases.count * 20)
    for (k, frame) in frameCases.enumerated() {
      frames[k * 20 + 5] = frame.0 == .full ? 1 : 0
      frames[k * 20 + 6] = frame.rescaled ? 1 : 0
      let l = frame.0.levels(bitDepth: frame.depth)
      for (i, level) in [l.black, l.span, l.center, l.chromaSpan].enumerated() {
        frames[k * 20 + 12 + i] = Float(level).bitPattern
      }
    }
    let output = try XCTUnwrap(device.makeBuffer(length: count * outputs * 4, options: .storageModeShared))
    let input = try XCTUnwrap(device.makeBuffer(bytes: linear, length: count * 4, options: .storageModeShared))
    let commands = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(output, offset: 0, index: 0)
    encoder.setBytes(frames, length: frames.count * 4, index: 1)
    encoder.setBuffer(input, offset: 0, index: 2)
    encoder.dispatchThreads(
      MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    XCTAssertNil(commands.error)
    let gpu = UnsafeBufferPointer(
      start: output.contents().bindMemory(to: Float.self, capacity: count * outputs), count: count * outputs)

    let names = [
      "mk_sLog3Decode", "mk_logC3Decode", "mk_logC4Decode", "mk_bt709Linear", "mk_srgbDecode",
      "mk_logC3ReferenceCode", "mk_luma709", "mk_nativeLog legal native", "mk_nativeLog legal rescaled",
      "mk_nativeLog full native", "mk_nativeLog full rescaled", "mk_nativeLog full rescaled 8-bit",
      "mk_nativeLog full rescaled 12-bit", "mk_nativeLog full rescaled 16-bit",
    ]
    var worst = [Double](repeating: 0, count: outputs)
    for i in 0..<count {
      let v = Double(i) / 1023, legal = (Double(i) - 64) / 876
      let cpu: [Double] = [
        try XCTUnwrap(LogCurve.sLog3.decode(v)), try XCTUnwrap(LogCurve.arriLogC3.decode(v)),
        try XCTUnwrap(LogCurve.arriLogC4.decode(v)), ColorMath.bt709Linear(v), Reference.srgbDecode(v),
        try XCTUnwrap(SonyARRIStyleFalseColor.referenceCode(sceneLinearLuma: Double(linear[i]))),
        0.2126 * v + 0.7152 * (1 - v) + 0.0722 * v * v,
        DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .native),
        DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .fullRescaledToLegal),
        DecodeReference.nativeLog(expanded: v, range: .full, transport: .native),
        DecodeReference.nativeLog(expanded: v, range: .full, transport: .fullRescaledToLegal),
        DecodeReference.nativeLog(expanded: v, range: .full, transport: .fullRescaledToLegal, bitDepth: 8),
        DecodeReference.nativeLog(expanded: v, range: .full, transport: .fullRescaledToLegal, bitDepth: 12),
        DecodeReference.nativeLog(expanded: v, range: .full, transport: .fullRescaledToLegal, bitDepth: 16),
      ]
      for (j, expected) in cpu.enumerated() {
        // Relative to max(1, |value|): Float evaluation of the same formula.
        let error = abs(Double(gpu[i * outputs + j]) - expected) / max(1, abs(expected))
        worst[j] = max(worst[j], error.isNaN ? .infinity : error)
      }
    }
    for (name, error) in zip(names, worst) {
      XCTAssertLessThan(error, 4e-6, "\(name) differs from the Core reference by \(error)")
    }
    print("MATH GPU curve worst relative error:", zip(names, worst).map { "\($0) \($1)" }.joined(separator: ", "))
  }

  /// One output row per 10-bit code. Columns follow `names` in the test above.
  private static let curveKernel = """
    kernel void mkmath_curves(device float* out [[buffer(0)]], constant mk_FrameParams* frames [[buffer(1)]],
                              device const float* linear [[buffer(2)]], uint i [[thread_position_in_grid]]) {
      float v = float(i) / 1023, legal = (float(i) - 64) / 876;
      device float* o = out + i * 14;
      o[0] = mk_sLog3Decode(v);
      o[1] = mk_logC3Decode(v);
      o[2] = mk_logC4Decode(v);
      o[3] = mk_bt709Linear(v);
      o[4] = mk_srgbDecode(float3(v)).x;
      o[5] = mk_logC3ReferenceCode(linear[i]);
      o[6] = mk_luma709(float3(v, 1 - v, v * v));
      for (uint k = 0; k < 7; k++) o[7 + k] = mk_nativeLog(k < 2 ? legal : v, frames[k]);
    }
    """
}

// MARK: - Source constants and reference implementations

private enum Source {
  static let d65 = (0.3127, 0.3290)
  static let rec709Primaries = [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)]
  static let rec2020Primaries = [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
  static let sGamut3Primaries = [(0.730, 0.280), (0.140, 0.855), (0.100, -0.050)]
  static let sGamut3CinePrimaries = [(0.766, 0.275), (0.225, 0.800), (0.089, -0.087)]
  static let awg3Primaries = [(0.6840, 0.3130), (0.2210, 0.8480), (0.0861, -0.1020)]
  static let awg4Primaries = [(0.7347, 0.2653), (0.1424, 0.8576), (0.0991, -0.0308)]
}

/// Reference transfer functions and filters written from the standards' text.
private enum Reference {
  static func oetf709(_ l: Double) -> Double { l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
  static func inverseOETF709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45) }
  static func srgbDecode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
  static func srgbEncode(_ l: Double) -> Double { l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055 }

  static let pqM1 = 2610.0 / 16384, pqM2 = 2523.0 / 4096 * 128
  static let pqC1 = 3424.0 / 4096, pqC2 = 2413.0 / 4096 * 32, pqC3 = 2392.0 / 4096 * 32
  static func pqEncode(nits: Double) -> Double {
    let y = pow(nits / 10_000, pqM1)
    return pow((pqC1 + pqC2 * y) / (1 + pqC3 * y), pqM2)
  }
  static func pqDecode(_ e: Double) -> Double {
    let p = pow(e, 1 / pqM2)
    return 10_000 * pow(max(p - pqC1, 0) / (pqC2 - pqC3 * p), 1 / pqM1)
  }

  static let hlgA = 0.17883277
  static let hlgB = 1 - 4 * hlgA
  static let hlgC = 0.5 - hlgA * log(4 * hlgA)
  static func hlgOETF(_ e: Double) -> Double { e <= 1.0 / 12 ? (3 * e).squareRoot() : hlgA * log(12 * e - hlgB) + hlgC }
  static func hlgInverseOETF(_ v: Double) -> Double { v <= 0.5 ? v * v / 3 : (exp((v - hlgC) / hlgA) + hlgB) / 12 }

  struct Biquad { var b: [Double]; var a: [Double] }
  /// High-shelf stage of the K-weighting prototype (the analog parameters used by
  /// libebur128), bilinear-transformed; reproduces BS.1770 Table 1 at 48 kHz.
  static func kWeightingShelf(sampleRate: Double) -> Biquad {
    let f0 = 1681.974450955533, gainDB = 3.999843853973347, q = 0.7071752369554196
    let k = tan(Double.pi * f0 / sampleRate)
    let vh = pow(10, gainDB / 20), vb = pow(vh, 0.4996667741545416)
    let a0 = 1 + k / q + k * k
    return Biquad(
      b: [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
      a: [2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
  }
  /// RLB high-pass stage; reproduces BS.1770 Table 2 at 48 kHz.
  static func kWeightingHighPass(sampleRate: Double) -> Biquad {
    let f0 = 38.13547087602444, q = 0.5003270373238773
    let k = tan(Double.pi * f0 / sampleRate)
    let a0 = 1 + k / q + k * k
    return Biquad(b: [1, -2, 1], a: [2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
  }
  static func magnitude(_ f: Biquad, hz: Double, sampleRate: Double) -> Double {
    let w = 2 * Double.pi * hz / sampleRate
    func poly(_ c: [Double]) -> (Double, Double) {
      (c[0] + c[1] * cos(w) + c[2] * cos(2 * w), -(c[1] * sin(w) + c[2] * sin(2 * w)))
    }
    let n = poly(f.b), d = poly([1] + f.a)
    return ((n.0 * n.0 + n.1 * n.1) / (d.0 * d.0 + d.1 * d.1)).squareRoot()
  }

  /// BS.1770-5 Annex 2 interpolator, one array per phase.
  static let truePeakPhases: [[Double]] = [
    [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
     0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
    [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
     0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
    [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
     0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
    [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
     0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
  ]
}

/// Deterministic generator so failures reproduce.
private struct SplitMix64 {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

extension MathReferenceTests {
  /// Builds a LUT through the public .cube parser; `value` receives the lattice
  /// point in [0, 1]³.
  fileprivate static func cube(size: Int, _ value: (SIMD3<Float>) -> SIMD3<Float>) throws -> CubeLUT {
    var text = "LUT_3D_SIZE \(size)\n"
    let step = 1 / Float(size - 1)
    for b in 0..<size {
      for g in 0..<size {
        for r in 0..<size {
          let v = value(SIMD3(Float(r), Float(g), Float(b)) * step)
          text += "\(v.x) \(v.y) \(v.z)\n"
        }
      }
    }
    return try CubeLUT(text: text)
  }

  /// Tetrahedral interpolation written as a walk from c000 to c111 along the axes in
  /// decreasing order of fractional position (Kasson, Nin & Plouffe 1995).
  fileprivate static func barycentric(_ lut: CubeLUT, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
    let n = lut.dimension
    let p = simd_clamp((rgb - lut.domainMin) / (lut.domainMax - lut.domainMin), .zero, .one) * Float(n - 1)
    let lo = SIMD3<Int>(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), Int(p.z.rounded(.down)))
    let t = p - SIMD3<Float>(Float(lo.x), Float(lo.y), Float(lo.z))
    let order = [0, 1, 2].sorted { t[$0] > t[$1] }
    var corner = lo
    var result = (1 - t[order[0]]) * lut.lattice(lo.x, lo.y, lo.z)
    for (step, axis) in order.enumerated() {
      corner[axis] = min(corner[axis] + 1, n - 1)
      let weight = t[axis] - (step < 2 ? t[order[step + 1]] : 0)
      result += weight * lut.lattice(corner.x, corner.y, corner.z)
    }
    return result
  }

  /// A file of this package, by path from the package root.
  fileprivate static func packageText(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  fileprivate static func msl(_ name: String) throws -> String {
    try packageText("Sources/MonitorKit/Shaders/\(name)")
  }

  /// The text from the first `open` after `marker` to its matching `close`, inclusive.
  fileprivate static func balanced(after marker: String, open: Character, close: Character, in text: String) throws
    -> String
  {
    let start = try XCTUnwrap(text.range(of: marker), "\(marker) not found; update this drift check")
    let first = try XCTUnwrap(text[start.upperBound...].firstIndex(of: open), "no \(open) after \(marker)")
    var depth = 0
    for index in text[first...].indices {
      if text[index] == open { depth += 1 }
      if text[index] == close {
        depth -= 1
        if depth == 0 { return String(text[first...index]) }
      }
    }
    return try XCTUnwrap(String?.none, "unbalanced \(open)\(close) after \(marker)")
  }

  /// The text of one MSL function: its signature and its brace-matched body (so a
  /// one-line function does not run on into its neighbours).
  fileprivate static func mslFunction(_ signature: String, in file: String) throws -> String {
    let source = try msl(file)
    XCTAssertNotNil(source.range(of: signature + "("), "\(signature) not found in \(file); update this drift check")
    return signature + (try balanced(after: signature + "(", open: "{", close: "}", in: source))
  }

  /// `text` without whitespace, for matching expressions independent of formatting.
  fileprivate static func squashed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

  /// Signed decimal literals in Swift text, as Double.
  fileprivate static func signedLiterals(in text: String) throws -> [Double] {
    let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z_0-9.])-?\d+\.\d+"#)
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      Range(match.range, in: text).flatMap { Double(text[$0]) }
    }
  }

  /// Every numeric literal in MSL text, as Float; identifiers such as `float3` or
  /// `exp2` are skipped.
  fileprivate static func literals(in text: String) throws -> [Float] {
    let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z_0-9.])(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?"#)
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      let token = String(text[range])
      return Float(token.hasPrefix(".") ? "0" + token : token)
    }
  }
}
