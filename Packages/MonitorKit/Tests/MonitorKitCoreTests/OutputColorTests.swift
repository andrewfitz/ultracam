import Foundation
import XCTest

@testable import MonitorKitCore

/// The output-colour math against values re-derived here from the primary sources:
/// ITU-R BT.2087-0 and Report BT.2407 (matrices), BT.2100-3 Table 4/5 (PQ, HLG),
/// Report BT.2408-8 Table 1 (reference levels), §5.1.4.1 (HLG scaling) and Annex 5
/// (the EETF), and SMPTE EG 432-1 (Display P3).
final class OutputColorTests: XCTestCase {
  func assertMatrix(
    _ m: ColorMatrix, _ rows: [[Double]], accuracy: Double, _ message: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let actual = [[m.red.r, m.red.g, m.red.b], [m.green.r, m.green.g, m.green.b], [m.blue.r, m.blue.g, m.blue.b]]
    for r in 0..<3 {
      for c in 0..<3 {
        XCTAssertEqual(actual[r][c], rows[r][c], accuracy: accuracy, "\(message) [\(r)][\(c)]", file: file, line: line)
      }
    }
  }

  // MARK: - Matrices

  func testRec709ToRec2020IsBT2087() {
    // BT.2087-0 §2.2 (M2), "calculated with high precision and then rounded to four decimal digits".
    assertMatrix(
      ColorPrimaries.rec709.conversion(to: .rec2020),
      [[0.6274, 0.3293, 0.0433], [0.0691, 0.9195, 0.0114], [0.0164, 0.0880, 0.8956]], accuracy: 5e-5, "BT.2087")
  }

  func testRec2020ToRec709IsBT2407() {
    // Report ITU-R BT.2407 §2.2 eq. (1), four decimals.
    assertMatrix(
      ColorPrimaries.rec2020.conversion(to: .rec709),
      [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]], accuracy: 5e-5, "BT.2407")
  }

  func testNormalizedPrimaryMatricesMatchPublishedValues() {
    // BT.709 / sRGB to XYZ (IEC 61966-2-1 prints the 4-decimal matrix BT.2087 uses too).
    assertMatrix(
      ColorPrimaries.rec709.toXYZ, [[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]],
      accuracy: 5e-5, "BT.709 NPM")
    // BT.2020 to XYZ (BT.2087 M2's left factor).
    assertMatrix(
      ColorPrimaries.rec2020.toXYZ, [[0.6370, 0.1446, 0.1689], [0.2627, 0.6780, 0.0593], [0, 0.0281, 1.0610]],
      accuracy: 5e-5, "BT.2020 NPM")
    // Display P3 (EG 432-1 primaries, D65), 7 decimals as colour-science publishes it.
    assertMatrix(
      ColorPrimaries.displayP3.toXYZ,
      [[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869], [0, 0.0451134, 1.0439444]],
      accuracy: 5e-7, "P3 NPM")
    for p in ColorPrimaries.allCases {
      for q in ColorPrimaries.allCases {
        let m = p.conversion(to: q)
        for row in [m.red, m.green, m.blue] { XCTAssertEqual(row.r + row.g + row.b, 1, accuracy: 1e-12, "\(p)→\(q)") }
        let back = q.conversion(to: p).concatenating(m)
        assertMatrix(back, [[1, 0, 0], [0, 1, 0], [0, 0, 1]], accuracy: 1e-12, "\(p)→\(q)→\(p)")
      }
    }
  }

  func testCameraGamutConversionsAreThePinnedRP177Matrices() {
    // The values Docs/MATH.md 5.1 pins (MathReferenceTests derives them independently).
    let pinned: [(ColorGamut, [[Double]])] = [
      (.sGamut3Cine, [[1.6269474, -0.5401385, -0.0868089], [-0.1785155, 1.4179409, -0.2394254], [-0.0444361, -0.1959200, 1.2403561]]),
      (.sGamut3, [[1.8779151, -0.7941688, -0.0837464], [-0.1768070, 1.3509996, -0.1741926], [-0.0262011, -0.1484223, 1.1746234]]),
      (.arriWideGamut3, [[1.6175234, -0.5372866, -0.0802368], [-0.0705727, 1.3346131, -0.2640403], [-0.0211017, -0.2269539, 1.2480556]]),
      (.arriWideGamut4, [[1.8931234, -0.7808815, -0.1122419], [-0.2057004, 1.3402575, -0.1345571], [-0.0127057, -0.1521849, 1.1648906]]),
    ]
    for (gamut, rows) in pinned { assertMatrix(gamut.conversion(to: .rec709), rows, accuracy: 5e-8, "\(gamut)") }
    // Every gamut's Y row is its luminance weights (MATH.md 3).
    for gamut in [ColorGamut.sGamut3, .sGamut3Cine, .arriWideGamut3, .arriWideGamut4] {
      let y = gamut.toXYZ.green, k = gamut.luminanceCoefficients
      XCTAssertEqual(y.r, k.r, accuracy: 5e-7, "\(gamut)")
      XCTAssertEqual(y.g, k.g, accuracy: 5e-7, "\(gamut)")
      XCTAssertEqual(y.b, k.b, accuracy: 5e-7, "\(gamut)")
    }
  }

  // MARK: - Transfers

  func testPQSignalInvertsTheEOTFAndHitsBT2408Levels() {
    // BT.2408 Table 1: 26 cd/m² is 38% PQ, 203 is 58%; MATH.md 5 pins the exact values.
    XCTAssertEqual(ColorMath.pqSignal(nits: 203), 0.580689, accuracy: 1e-6)
    XCTAssertEqual(ColorMath.pqSignal(nits: 100), 0.508078, accuracy: 1e-6)
    XCTAssertEqual(ColorMath.pqSignal(nits: 1000), 0.751827, accuracy: 1e-6)
    XCTAssertEqual(ColorMath.pqSignal(nits: 26) * 100, 38, accuracy: 0.5)
    XCTAssertEqual(ColorMath.pqSignal(nits: 10_000), 1, accuracy: 1e-12)
    for i in 1...100 {
      let nits = pow(10, Double(i) / 25) // 1…10 000
      XCTAssertEqual(ColorMath.pqNits(ColorMath.pqSignal(nits: nits)), nits, accuracy: nits * 1e-9)
    }
  }

  func testHLGOETFAndSystemGammaFollowBT2100() {
    // Table 5, written out independently.
    let a = 0.17883277, b = 1 - 4 * a, c = 0.5 - a * log(4 * a)
    for i in 0...1000 {
      let e = Double(i) / 1000
      let expected = e <= 1.0 / 12 ? sqrt(3 * e) : a * log(12 * e - b) + c
      XCTAssertEqual(ColorMath.hlgOETF(e), expected, accuracy: 1e-15)
      XCTAssertEqual(ColorMath.hlgInverseOETF(ColorMath.hlgOETF(e)), e, accuracy: 1e-12)
    }
    // Note 5f: 1.2 at 1000; the production formula from 400 to 2000; the extended one outside.
    XCTAssertEqual(ColorMath.hlgSystemGamma(peak: 1000), 1.2, accuracy: 1e-15)
    XCTAssertEqual(ColorMath.hlgSystemGamma(peak: 2000), 1.2 + 0.42 * log10(2), accuracy: 1e-15)
    XCTAssertEqual(ColorMath.hlgSystemGamma(peak: 400), 1.2 + 0.42 * log10(0.4), accuracy: 1e-15)
    XCTAssertEqual(ColorMath.hlgSystemGamma(peak: 4000), 1.2 * 1.111 * 1.111, accuracy: 1e-12)
    XCTAssertEqual(ColorMath.hlgSystemGamma(peak: 250), 1.2 * pow(1.111, -2), accuracy: 1e-12)
  }

  func testHLGEOTFReproducesBT2408ReferenceLevels() {
    let w = ColorPrimaries.rec2020.luminanceCoefficients
    func nits(_ v: Double) -> Double { ColorMath.hlgEOTF(ColorRGB(r: v, g: v, b: v), peak: 1000, weights: w).g }
    // Table 1 on a 1000 cd/m² display: 75% → 203, 38% → 26 (rounded in the table).
    XCTAssertEqual(nits(0.75), 203, accuracy: 0.5)
    XCTAssertEqual(nits(0.38), 26, accuracy: 0.5)
    XCTAssertEqual(nits(1), 1000, accuracy: 1e-4)
    // The inverse EOTF undoes it, colour included.
    let colours = [ColorRGB(r: 0.75, g: 0.2, b: 0.5), ColorRGB(r: 0.1, g: 0.9, b: 0.3), ColorRGB(r: 0.6, g: 0.6, b: 0.6)]
    for v in colours {
      for peak in [400.0, 1000, 2000, 4000] {
        let back = ColorMath.hlgInverseEOTF(ColorMath.hlgEOTF(v, peak: peak, weights: w), peak: peak, weights: w)
        XCTAssertEqual(back.r, v.r, accuracy: 1e-9)
        XCTAssertEqual(back.g, v.g, accuracy: 1e-9)
        XCTAssertEqual(back.b, v.b, accuracy: 1e-9)
      }
    }
    XCTAssertEqual(ColorMath.hlgInverseEOTF(ColorRGB(r: 0, g: 0, b: 0), peak: 1000, weights: w), ColorRGB(r: 0, g: 0, b: 0))
  }

  func testBT1886EOTFWithZeroBlackIsAPowerOf24() {
    for i in 0...100 {
      let v = Double(i) / 100
      XCTAssertEqual(ColorMath.bt1886EOTF(v), ColorMath.bt1886EOTF(v, black: 0, white: 1), accuracy: 1e-12)
      XCTAssertEqual(ColorMath.bt1886InverseEOTF(ColorMath.bt1886EOTF(v)), v, accuracy: 1e-12)
      XCTAssertEqual(ColorMath.sRGBDecode(ColorMath.sRGBEncode(v)), v, accuracy: 1e-12)
      XCTAssertEqual(ColorMath.gamma22InverseEOTF(ColorMath.gamma22EOTF(v)), v, accuracy: 1e-12)
    }
    // Mirrored below zero (BT.2408 §5.3), so extended range keeps sub-blacks.
    XCTAssertEqual(ColorMath.bt1886EOTF(-0.5), -pow(0.5, 2.4), accuracy: 1e-15)
  }

  // MARK: - EETF (BT.2408-8 Annex 5)

  /// Annex 5 Steps 1-5 transcribed independently, LB = Lmin = 0.
  static func eetf(_ nits: Double, lw: Double, lmax: Double) -> Double {
    let pqLW = ColorMath.pqSignal(nits: lw)
    let e1 = ColorMath.pqSignal(nits: nits) / pqLW
    let maxLum = ColorMath.pqSignal(nits: lmax) / pqLW
    let ks = 1.5 * maxLum - 0.5
    var e2 = e1
    if e1 >= ks {
      let t = (e1 - ks) / (1 - ks)
      e2 = (2 * pow(t, 3) - 3 * pow(t, 2) + 1) * ks + (pow(t, 3) - 2 * pow(t, 2) + t) * (1 - ks)
        + (-2 * pow(t, 3) + 3 * pow(t, 2)) * maxLum
    }
    return ColorMath.pqNits(e2 * pqLW)
  }

  func testEETFKneeAndRollOffAnchors() {
    for (lw, lmax) in [(1000.0, 203.0), (1000, 100), (4000, 1000), (10_000, 203), (1000, 600)] {
      let curve = ToneMapEETF(sourcePeak: lw, targetPeak: lmax)
      let ks = 1.5 * curve.maxLum - 0.5
      XCTAssertEqual(curve.kneeStart, ks, accuracy: 1e-15)
      // P(KS) = KS, P(1) = maxLum: the source peak lands on the target peak.
      XCTAssertEqual(curve.normalized(ks), ks, accuracy: 1e-12)
      XCTAssertEqual(curve.normalized(1), curve.maxLum, accuracy: 1e-12)
      XCTAssertEqual(curve.nits(lw), lmax, accuracy: lmax * 1e-9, "\(lw)→\(lmax)")
      // Slope 1 into the knee, 0 at the peak.
      let h = 1e-7
      XCTAssertEqual((curve.normalized(ks + h) - curve.normalized(ks)) / h, 1, accuracy: 1e-5)
      XCTAssertEqual((curve.normalized(1) - curve.normalized(1 - h)) / h, 0, accuracy: 1e-5)
      // 1:1 below the knee, monotonic everywhere, never above the target.
      var last = 0.0
      for i in 1...2000 {
        let nits = lw * Double(i) / 2000
        let out = curve.nits(nits)
        XCTAssertEqual(out, Self.eetf(nits, lw: lw, lmax: lmax), accuracy: max(1e-9, out * 1e-9))
        if ColorMath.pqSignal(nits: nits) / curve.sourceSignal < ks { XCTAssertEqual(out, nits, accuracy: nits * 1e-12) }
        XCTAssertGreaterThanOrEqual(out, last)
        XCTAssertLessThanOrEqual(out, lmax * (1 + 1e-12))
        last = out
      }
    }
    // A target that holds the source is the identity, beyond the peak too.
    let identity = ToneMapEETF(sourcePeak: 1000, targetPeak: 1600)
    XCTAssertTrue(identity.isIdentity)
    XCTAssertEqual(identity.nits(1500), 1500)
    // A knee below zero (maxLum < 1/3) starts the spline at 0.
    XCTAssertEqual(ToneMapEETF(sourcePeak: 10_000, targetPeak: 5).kneeStart, 0)
  }

  func testEETFWhereReferenceWhiteAndGreyLand() {
    // 1000 cd/m² master into graphics white (203): grey (26) is below the knee and
    // unchanged; reference white rolls off to 159.04 cd/m², 90.33% SDR after BT.1886
    // (both recomputed independently from BT.2408-8 Annex 5 in double precision).
    let curve = ToneMapEETF(sourcePeak: 1000, targetPeak: 203)
    XCTAssertEqual(curve.nits(26), 26, accuracy: 1e-9)
    let white = curve.nits(203)
    XCTAssertEqual(white, Self.eetf(203, lw: 1000, lmax: 203), accuracy: 1e-9)
    XCTAssertEqual(white, 159.0419, accuracy: 1e-3)
    XCTAssertEqual(pow(white / 203, 1 / 2.4), 0.90332, accuracy: 1e-5, "\(white)")
    let grey = HDRToSDR.pq(ColorRGB(r: 0.38, g: 0.38, b: 0.38), primaries: .rec2020, sourcePeak: 1000, referenceWhite: 203)
    XCTAssertEqual(grey.g, pow(ColorMath.pqNits(0.38) / 203, 1 / 2.4), accuracy: 1e-9)
    XCTAssertEqual(grey.g, 0.425, accuracy: 0.002)
    // maxRGB keeps hue: the ratios between components do not change.
    let c = curve.apply(ColorRGB(r: 800, g: 400, b: 100))
    XCTAssertEqual(c.g / c.r, 0.5, accuracy: 1e-12)
    XCTAssertEqual(c.b / c.r, 0.125, accuracy: 1e-12)
  }

  // MARK: - HDR to SDR

  func testHLGToSDRPutsReferenceWhiteAtGraphicsWhiteAndGreyWhereBT709Does() {
    // BT.2408 §5.1.4.1: 100% SDR ↔ 75% HLG scales by OETF⁻¹(0.75) = 0.265 (rounded there).
    XCTAssertEqual(HDRToSDR.hlgReferenceWhiteScene, 0.265, accuracy: 5e-4)
    func sdr(_ v: Double) -> Double { HDRToSDR.hlg(ColorRGB(r: v, g: v, b: v), primaries: .rec2020).g }
    XCTAssertEqual(sdr(0.75), 1, accuracy: 1e-12)
    // 38% HLG (the grey card) is 0.1817 scene light, 41.1% after the BT.709 OETF (an
    // SDR camera: 40.9% at 0.18).
    let grey = 0.38 * 0.38 / 3 / HDRToSDR.hlgReferenceWhiteScene
    XCTAssertEqual(sdr(0.38), 1.099 * pow(grey, 0.45) - 0.099, accuracy: 1e-12)
    XCTAssertEqual(sdr(0.38), 0.4111, accuracy: 5e-4)
    XCTAssertEqual(sdr(0.9), 1, "above reference white clips")
    XCTAssertEqual(sdr(0), 0)
    var last = -1.0
    for i in 0...1023 {
      let v = sdr(Double(i) / 1023)
      XCTAssertGreaterThanOrEqual(v, last)
      last = v
    }
  }

  func testPQToSDRIsMonotonicAndNeverLeavesTheSDRRange() {
    var last = -1.0
    for i in 0...1023 {
      let v = Double(i) / 1023
      let out = HDRToSDR.pq(ColorRGB(r: v, g: v, b: v), primaries: .rec2020, sourcePeak: 1000, referenceWhite: 203).g
      XCTAssertGreaterThanOrEqual(out, last)
      XCTAssertLessThanOrEqual(out, 1)
      last = out
    }
    XCTAssertEqual(last, 1, accuracy: 1e-12, "the master's peak and above are SDR peak white")
  }

  // MARK: - Display assist v1

  func testDisplayAssistCurveIsMonotonicContinuousAndPlacesGrey() {
    // Grey: exactly the BT.709 OETF of 0.18 (40.9%), as a standard Rec.709 camera.
    XCTAssertEqual(DisplayAssist.signal(sceneLinear: 0.18), 1.099 * pow(0.18, 0.45) - 0.099, accuracy: 1e-15)
    XCTAssertEqual(DisplayAssist.signal(sceneLinear: 0.18), 0.40901, accuracy: 1e-5)
    // The knee: value and slope continuous.
    let k = DisplayAssist.kneeScene, h = 1e-7
    XCTAssertEqual(1.099 * pow(k, 0.45) - 0.099, DisplayAssist.kneeSignal, accuracy: 1e-12)
    XCTAssertEqual(DisplayAssist.signal(sceneLinear: k * (1 + 1e-12)), 0.7, accuracy: 1e-10)
    let below = (DisplayAssist.signal(sceneLinear: k) - DisplayAssist.signal(sceneLinear: k - h)) / h
    let above = (DisplayAssist.signal(sceneLinear: k + h) - DisplayAssist.signal(sceneLinear: k)) / h
    XCTAssertEqual(below, above, accuracy: 1e-5)
    // Documented anchors.
    XCTAssertEqual(DisplayAssist.signal(sceneLinear: 0.9), 0.854, accuracy: 0.001, "white card")
    XCTAssertEqual(DisplayAssist.signal(sceneLinear: 0.18 * 16), 0.964, accuracy: 0.001, "+4 stops")
    XCTAssertEqual(DisplayAssist.signal(sceneLinear: 0.18 * 64), 0.993, accuracy: 0.001, "+6 stops")
    XCTAssertLessThan(DisplayAssist.signal(sceneLinear: 1e6), 1)
    XCTAssertEqual(DisplayAssist.signal(sceneLinear: -1), 0)
    var last = -1.0
    for i in 0...4000 {
      let v = DisplayAssist.signal(sceneLinear: pow(2, Double(i) / 200 - 12))
      XCTAssertGreaterThan(v, last)
      last = v
    }
  }

  func testLogToRec709PlacesEachCameraGreyAt40Point9() throws {
    let cases: [(LogEncoding, CodeRange, Double)] = [
      // S-Log3 grey is code 420 (Sony technical summary), stored verbatim in a legal container.
      (.sLog3SGamut3Cine, .legal, (420.0 - 64) / 876),
      (.sLog3SGamut3, .legal, (420.0 - 64) / 876),
      // LogC fills the range: grey 0.391007 (LogC3), 0.278396 (LogC4).
      (try XCTUnwrap(LogEncoding(profileID: "arri-logc3-ei800")), .full, 0.3910068),
      (try XCTUnwrap(LogEncoding(profileID: "arri-alexa35-logc4-ei800")), .full, 0.2783958),
    ]
    for (log, range, grey) in cases {
      let out = DisplayAssist.rec709(ColorRGB(r: grey, g: grey, b: grey), log: log, range: range)
      XCTAssertEqual(out.r, 0.40901, accuracy: 2e-4, "\(log.curve)")
      XCTAssertEqual(out.g, out.r, accuracy: 1e-9, "neutral stays neutral")
      XCTAssertEqual(out.b, out.r, accuracy: 1e-9)
      // Monotonic in code.
      var last = -1.0
      for code in 0...1023 {
        let e = range == .legal ? (Double(code) - 64) / 876 : Double(code) / 1023
        let v = DisplayAssist.rec709(ColorRGB(r: e, g: e, b: e), log: log, range: range).g
        XCTAssertGreaterThanOrEqual(v, last, "\(log.curve) \(code)")
        last = v
      }
    }
  }

  // MARK: - Output encodings and overlay colours

  func pipeline(_ encoding: MonitorOutputColor.Encoding, primaries: ColorPrimaries = .rec709, signal: SignalDescription = .rec709,
                mode: DisplayTransform = .none) -> MonitorColorPipeline
  {
    MonitorColorPipeline(
      output: MonitorOutputColor(primaries: primaries, encoding: encoding), signal: signal,
      transform: DisplayTransformSettings(mode: mode))
  }

  func testSDRWhiteLandsAtGraphicsWhiteInEveryEncoding() {
    let white = ColorRGB(r: 1, g: 1, b: 1)
    // BT.2408 Table 1: graphics white is 203 cd/m², 58% PQ, 75% HLG; 1.0 in extended linear.
    let expected: [(MonitorOutputColor.Encoding, Double, Double)] = [
      (.pq, ColorMath.pqSignal(nits: 203), 1e-9), (.hlg, 0.75, 2e-3), (.extendedLinear, 1, 1e-12),
      (.sdr(.bt1886), 1, 1e-12), (.sdr(.sRGB), 1, 1e-12), (.sdr(.gamma22), 1, 1e-12),
    ]
    for (encoding, value, accuracy) in expected {
      for primaries in ColorPrimaries.allCases {
        let p = pipeline(encoding, primaries: primaries)
        // The picture (an SDR BT.709 source) and an overlay authored at white agree.
        let picture = p.present(white), overlay = p.overlayColor(white)
        for c in [picture.r, picture.g, picture.b, overlay.r, overlay.g, overlay.b] {
          XCTAssertEqual(c, value, accuracy: accuracy, "\(encoding) \(primaries)")
        }
      }
    }
    XCTAssertEqual(pipeline(.pq).overlayColor(white).g, 0.5807, accuracy: 1e-4)
    // Black is black everywhere.
    for encoding in expected.map(\.0) {
      XCTAssertEqual(pipeline(encoding).overlayColor(ColorRGB(r: 0, g: 0, b: 0)).g, 0, accuracy: 1e-6, "\(encoding)")
    }
  }

  func testOverlayColoursPerEncoding() {
    let red = ColorRGB(r: 1, g: 0, b: 0)
    // SDR native: unchanged. Same primaries SDR: unchanged up to round trip.
    XCTAssertEqual(pipeline(.signalNative).overlayColor(red), red)
    let sdr = pipeline(.sdr(.bt1886)).overlayColor(red)
    XCTAssertEqual(sdr.r, 1, accuracy: 1e-12)
    XCTAssertEqual(sdr.g, 0, accuracy: 1e-12)
    // Into BT.2020: Rec.709 red is inside BT.2020, BT.2087's first column.
    let wide = pipeline(.sdr(.bt1886), primaries: .rec2020).overlayColor(red)
    XCTAssertEqual(wide.r, pow(0.6274, 1 / 2.4), accuracy: 1e-4)
    XCTAssertEqual(wide.g, pow(0.0691, 1 / 2.4), accuracy: 1e-4)
    XCTAssertEqual(wide.b, pow(0.0164, 1 / 2.4), accuracy: 1e-4)
    // Extended linear keeps it linear (BT.1886 of the authored value).
    let grey = pipeline(.extendedLinear).overlayColor(ColorRGB(r: 0.5, g: 0.5, b: 0.5))
    XCTAssertEqual(grey.g, pow(0.5, 2.4), accuracy: 1e-12)
    // Native on an HDR signal: into the signal's PQ / HLG and BT.2020.
    let pqSignal = SignalDescription(matrix: .bt2020, encoding: .display(.pq))
    let pq = pipeline(.signalNative, signal: pqSignal).overlayColor(ColorRGB(r: 1, g: 1, b: 1))
    XCTAssertEqual(pq.g, ColorMath.pqSignal(nits: 203), accuracy: 1e-9)
    let hlg = pipeline(.signalNative, signal: SignalDescription(matrix: .bt2020, encoding: .display(.hlg)))
      .overlayColor(ColorRGB(r: 1, g: 1, b: 1))
    XCTAssertEqual(hlg.g, 0.75, accuracy: 2e-3)
    // An SDR transform on an HDR signal makes the layer SDR: overlays as authored.
    XCTAssertEqual(pipeline(.signalNative, signal: pqSignal, mode: .hdrToSDR).overlayColor(red), red)
  }

  func testSignalNativeConvertsNothing() {
    for signal in [SignalDescription.rec709, SignalDescription(matrix: .bt2020, encoding: .display(.pq)),
                   SignalDescription(encoding: .log(.sLog3SGamut3Cine))] {
      let p = pipeline(.signalNative, signal: signal)
      XCTAssertNil(p.target)
      let v = ColorRGB(r: 0.3, g: 0.7, b: 1.2)
      XCTAssertEqual(p.present(v), ColorRGB(r: 0.3, g: 0.7, b: 1), "only the final clip")
    }
  }

  func testConversionsBetweenEncodingsRoundTripInLinearLight() {
    // A BT.709 picture into PQ, then read back as PQ display light, is the BT.1886
    // display light scaled to graphics white.
    let p = pipeline(.pq, primaries: .rec709)
    for i in 0...20 {
      let v = Double(i) / 20
      let out = p.present(ColorRGB(r: v, g: v, b: v)).g
      XCTAssertEqual(ColorMath.pqNits(out), pow(v, 2.4) * 203, accuracy: 1e-6 * 203)
    }
    // A PQ picture onto an SDR output clips at graphics white (no tone mapping without hdrToSDR).
    let pqSignal = SignalDescription(matrix: .bt2020, encoding: .display(.pq))
    let clip = pipeline(.sdr(.bt1886), signal: pqSignal)
    XCTAssertEqual(clip.present(ColorRGB(r: 0.58069, g: 0.58069, b: 0.58069)).g, 1, accuracy: 1e-4)
    XCTAssertEqual(clip.present(ColorRGB(r: 0.9, g: 0.9, b: 0.9)).g, 1)
    // Out of gamut: saturated BT.2020 green has negative BT.709 red; SDR clips it to 0,
    // extended linear keeps it, nothing is NaN.
    let green = ColorRGB(r: 0, g: 0.58069, b: 0)
    let sdr = clip.present(green), ext = pipeline(.extendedLinear, signal: pqSignal).present(green)
    XCTAssertEqual(sdr.r, 0)
    XCTAssertLessThan(ext.r, 0)
    XCTAssertTrue(sdr.isFinite && ext.isFinite)
  }

  func testPassthroughRollsOffToTheHeadroom() {
    let pqSignal = SignalDescription(matrix: .bt2020, encoding: .display(.pq))
    let p = pipeline(.extendedLinear, primaries: .rec2020, signal: pqSignal, mode: .hdrPassthrough)
    XCTAssertTrue(p.passthrough && p.rollsOff)
    XCTAssertEqual(p.status, .active(label: "HDR passthrough"))
    let peak = ColorRGB(r: 0.751827, g: 0.751827, b: 0.751827)  // 1000 cd/m²
    // Headroom 2 (406 cd/m²): the 1000 cd/m² master peak lands on the headroom.
    XCTAssertEqual(p.present(peak, headroom: 2).g, 2, accuracy: 1e-4)
    // Headroom 8 holds it: unchanged, 1000/203.
    XCTAssertEqual(p.present(peak, headroom: 8).g, 1000.0 / 203, accuracy: 1e-4)
    XCTAssertNil(p.rolloff(headroom: 8).flatMap { $0.isIdentity ? nil : $0 })
    // Without passthrough the display clips.
    XCTAssertFalse(pipeline(.extendedLinear, signal: pqSignal).rollsOff)
    // PQ into HLG rolls off to the HLG peak.
    XCTAssertTrue(pipeline(.hlg, primaries: .rec2020, signal: pqSignal, mode: .hdrPassthrough).rollsOff)
  }

  func testTransformStatusAndUnavailableReasons() {
    let log = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
    let pq = SignalDescription(matrix: .bt2020, encoding: .display(.pq))
    let hlg = SignalDescription(matrix: .bt2020, encoding: .display(.hlg))
    XCTAssertEqual(pipeline(.signalNative, signal: .rec709, mode: .logToRec709).status, .unavailable(.requiresLogSource))
    XCTAssertEqual(pipeline(.signalNative, signal: .rec709, mode: .hdrToSDR).status, .unavailable(.requiresHDRSource))
    XCTAssertEqual(pipeline(.extendedLinear, signal: log, mode: .hdrPassthrough).status, .unavailable(.requiresHDRSource))
    XCTAssertEqual(pipeline(.sdr(.bt1886), signal: pq, mode: .hdrPassthrough).status, .unavailable(.requiresHDROutput))
    XCTAssertEqual(pipeline(.signalNative, signal: log, mode: .logToRec709).transform, .logToRec709)
    XCTAssertEqual(pipeline(.signalNative, signal: pq, mode: .hdrToSDR).transform, .pqToSDR)
    XCTAssertEqual(pipeline(.signalNative, signal: hlg, mode: .hdrToSDR).transform, .hlgToSDR)
    if case .active(let label) = pipeline(.signalNative, signal: log, mode: .logToRec709).status {
      XCTAssertTrue(label.contains(DisplayAssist.name), label)
    } else {
      XCTFail("log transform inactive")
    }
    // A transform's output is Rec.709 SDR; an unavailable one leaves the signal's encoding.
    XCTAssertEqual(pipeline(.signalNative, signal: pq, mode: .hdrToSDR).picture.transfer, .bt1886)
    XCTAssertEqual(pipeline(.signalNative, signal: .rec709, mode: .hdrToSDR).picture.transfer, .bt1886)
    XCTAssertEqual(pipeline(.signalNative, signal: pq, mode: .hdrPassthrough).picture.transfer, .pq)
    // A LUT-produced monitor stage is Rec.709 display R'G'B'.
    let lut = MonitorColorPipeline(
      output: MonitorOutputColor(encoding: .pq), signal: pq, monitorStageHasLUT: true)
    XCTAssertEqual(lut.picture, .init(transfer: .bt1886, primaries: .rec709))
  }

  // MARK: - Layer helpers and recommendation

  func testRecommendationMirrorsUltracamsPictureColor() {
    func layer(_ signal: SignalDescription, _ mode: DisplayTransform = .none) -> MonitorLayerColor {
      let output = MonitorOutputColor.recommended(for: signal, displayTransform: mode)
      XCTAssertEqual(output.encoding, .signalNative)
      return output.layer(for: signal, displayTransform: mode)
    }
    let rec709 = layer(.rec709)
    XCTAssertEqual(rec709.colorSpace, .itur709)
    XCTAssertEqual(rec709.pixelFormat, .bgr10a2Unorm)
    XCTAssertFalse(rec709.wantsExtendedDynamicRange)
    XCTAssertNil(rec709.edrMetadata)
    XCTAssertEqual(layer(SignalDescription(matrix: .bt2020)).colorSpace, .itur2020)
    // A declared log profile is a code-value Rec.709 view, even in a BT.2020 matrix.
    XCTAssertEqual(layer(SignalDescription(matrix: .bt2020, encoding: .log(.sLog3SGamut3Cine))).colorSpace, .itur709)
    let pq = layer(SignalDescription(matrix: .bt2020, encoding: .display(.pq)))
    XCTAssertEqual(pq.colorSpace, .itur2100PQ)
    XCTAssertEqual(pq.pixelFormat, .rgba16Float)
    XCTAssertTrue(pq.wantsExtendedDynamicRange)
    XCTAssertEqual(pq.edrMetadata, .hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100))
    let hlg = layer(SignalDescription(matrix: .bt2020, encoding: .display(.hlg)))
    XCTAssertEqual(hlg.colorSpace, .itur2100HLG)
    XCTAssertEqual(hlg.edrMetadata, .hlg)
    // An SDR transform makes the layer SDR Rec.709.
    XCTAssertEqual(layer(SignalDescription(matrix: .bt2020, encoding: .display(.pq)), .hdrToSDR).colorSpace, .itur709)
    XCTAssertEqual(layer(SignalDescription(encoding: .log(.sLog3SGamut3Cine)), .logToRec709).colorSpace, .itur709)
    // Explicit encodings ignore the signal.
    let ext = MonitorOutputColor(primaries: .displayP3, encoding: .extendedLinear).layer()
    XCTAssertEqual(ext.colorSpace, .extendedLinearDisplayP3)
    XCTAssertTrue(ext.wantsExtendedDynamicRange)
    XCTAssertNil(ext.edrMetadata)
    XCTAssertNil(MonitorOutputColor(encoding: .sdr(.gamma22)).layer().colorSpace)
    XCTAssertEqual(MonitorOutputColor(primaries: .displayP3, encoding: .sdr(.sRGB)).layer().colorSpace, .displayP3)
  }

  func testOutputColorCodableAndNormalized() throws {
    let output = MonitorOutputColor(primaries: .rec2020, encoding: .sdr(.gamma22), referenceWhite: 300, hlgNominalPeak: 2000, headroom: 4)
    let data = try JSONEncoder().encode(output)
    XCTAssertEqual(try JSONDecoder().decode(MonitorOutputColor.self, from: data), output)
    for encoding in [MonitorOutputColor.Encoding.signalNative, .sdr(.bt1886), .sdr(.sRGB), .extendedLinear, .pq, .hlg] {
      let o = MonitorOutputColor(encoding: encoding)
      XCTAssertEqual(try JSONDecoder().decode(MonitorOutputColor.self, from: try JSONEncoder().encode(o)), o)
    }
    // Malformed fields fall back.
    let junk = Data(#"{"primaries":"cmyk","encoding":7,"referenceWhite":"x","headroom":1e9}"#.utf8)
    let decoded = try JSONDecoder().decode(MonitorOutputColor.self, from: junk)
    XCTAssertEqual(decoded.primaries, .rec709)
    XCTAssertEqual(decoded.encoding, .signalNative)
    XCTAssertEqual(decoded.referenceWhite, 203)
    XCTAssertEqual(decoded.headroom, 64)
    var nan = MonitorOutputColor()
    nan.referenceWhite = .nan
    nan.headroom = -.infinity
    XCTAssertEqual(nan.normalized().referenceWhite, 203)
    XCTAssertEqual(nan.normalized().headroom, 1)
    XCTAssertEqual(MonitorOutputColor(headroom: 5).withoutHeadroom, MonitorOutputColor())
  }

  func testSignalPrimariesInferenceAndBackCompatibleDecoding() throws {
    XCTAssertEqual(SignalDescription.rec709.effectivePrimaries, .rec709)
    XCTAssertEqual(SignalDescription(matrix: .bt2020).effectivePrimaries, .rec2020)
    XCTAssertEqual(SignalDescription(encoding: .display(.hlg)).effectivePrimaries, .rec2020)
    XCTAssertEqual(SignalDescription(matrix: .bt709, primaries: .displayP3).effectivePrimaries, .displayP3)
    // Saved before primaries existed.
    let old = Data(#"{"range":"legal","matrix":"bt709","chromaSiting":"left","encoding":{"display":{"_0":"bt709"}}}"#.utf8)
    let decoded = try JSONDecoder().decode(SignalDescription.self, from: old)
    XCTAssertNil(decoded.primaries)
    XCTAssertEqual(decoded, .rec709)
    let labelled = SignalDescription(primaries: .displayP3)
    XCTAssertEqual(try JSONDecoder().decode(SignalDescription.self, from: try JSONEncoder().encode(labelled)), labelled)
  }

  /// A LUT on the monitor stage makes the native picture Rec.709 SDR: the layer is
  /// tagged SDR and overlays stay as authored. No display transform runs after it
  /// (`testALUTOnTheMonitorStageMakesEveryTransformUnavailable`).
  func testMonitorStageLUTMakesTheNativePictureSDR() {
    let pq = SignalDescription(matrix: .bt2020, encoding: .display(.pq))
    XCTAssertEqual(MonitorOutputColor.signalNative.layer(for: pq).colorSpace, .itur2100PQ)
    let lut = MonitorOutputColor.recommended(for: pq, monitorStageHasLUT: true)
    XCTAssertEqual(lut.layer(for: pq, monitorStageHasLUT: true).colorSpace, .itur709)
    let p = MonitorColorPipeline(output: .signalNative, signal: pq, monitorStageHasLUT: true)
    XCTAssertEqual(p.picture, .init(transfer: .bt1886, primaries: .rec709))
    XCTAssertNil(p.overlay)
    XCTAssertEqual(p.overlayColor(ColorRGB(r: 1, g: 0, b: 0)), ColorRGB(r: 1, g: 0, b: 0))
    // Without the LUT the overlays are encoded into the signal's PQ and BT.2020.
    XCTAssertEqual(MonitorColorPipeline(output: .signalNative, signal: pq).overlay, .init(transfer: .pq, primaries: .rec2020))
    // A labelled BT.709 HLG signal keeps BT.709 primaries for its overlays and layer.
    let hlg709 = SignalDescription(encoding: .display(.hlg), primaries: .rec709)
    XCTAssertEqual(MonitorColorPipeline(output: .signalNative, signal: hlg709).overlay?.primaries, .rec709)
    XCTAssertEqual(MonitorOutputColor.recommended(for: hlg709).layer(for: hlg709).colorSpace, .itur709HLG)
  }

  /// HLG holds no signal above 1: a saturated colour clipped at the peak, whose
  /// luminance is below it, encodes to 1, not above.
  func testHLGInverseEOTFNeverExceedsFullScale() {
    let w = ColorPrimaries.rec2020.luminanceCoefficients
    let v = ColorMath.hlgInverseEOTF(ColorRGB(r: 1000, g: 50, b: 1000), peak: 1000, weights: w)
    XCTAssertEqual(v.r, ColorMath.hlgOETF(1), accuracy: 1e-12)
    XCTAssertEqual(v.b, ColorMath.hlgOETF(1), accuracy: 1e-12)
    XCTAssertLessThan(v.g, 1)
  }
}
