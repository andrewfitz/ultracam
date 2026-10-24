import Foundation
import XCTest

@testable import MonitorKitCore

/// HLG to SDR by Report ITU-R BT.2446-1 Method C against values re-derived here
/// from the Report's equations (`Docs/MATH.md` §5.1).
final class HDRDownConversionTests: XCTestCase {
  /// A small deterministic generator (SplitMix64).
  struct Random {
    var state: UInt64
    mutating func next() -> Double {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
  }

  // MARK: - Method C

  /// Eq. (10)'s parameters from the conditions §6.1.4 states: k1 from 50% HLG →
  /// 70% SDR, the inflection point at 80% SDR (eq. 6), k2 and k4 from continuity
  /// (eqs. 7, 8), k3 from 75% HLG → 96% SDR (eq. 9). Every printed digit comes
  /// out with the unrounded 80% SDR (58.535 cd/m², eq. 6 prints 58.5).
  func testMethodCParametersDeriveFromTheReportsConditions() {
    func hlgNits(_ e: Double) -> Double { 1000 * pow(ColorMath.hlgInverseOETF(e), 1.2) }
    func sdrNits(_ v: Double) -> Double { 100 * pow(v, 2.4) }
    let k1 = sdrNits(0.70) / hlgNits(0.50)
    XCTAssertEqual(k1, BT2446MethodC.k1, accuracy: 5e-6)
    let ip = sdrNits(0.80) / k1, reference = hlgNits(0.75), whitePoint = sdrNits(0.96)
    XCTAssertEqual(reference, 203.15, accuracy: 5e-3, "HDR Reference White, BT.2408 Table 1's 203 cd/m²")
    // Eq. (9) with k2 from eq. (7): solve for k3 by bisection.
    func residual(_ k3: Double) -> Double {
      let k2 = k1 * (1 - k3) * ip
      return k2 * log((reference / ip - k3) / (1 - k3)) - (whitePoint - k1 * ip)
    }
    var low = 0.0, high = 0.99
    for _ in 0..<200 {
      let mid = (low + high) / 2
      if residual(low) * residual(mid) <= 0 { high = mid } else { low = mid }
    }
    let k3 = (low + high) / 2, k2 = k1 * (1 - k3) * ip, k4 = k1 * ip - k2 * log(1 - k3)
    XCTAssertEqual(k2, BT2446MethodC.k2, accuracy: 5e-6)
    XCTAssertEqual(k3, BT2446MethodC.k3, accuracy: 5e-6)
    XCTAssertEqual(k4, BT2446MethodC.k4, accuracy: 5e-6)
    XCTAssertEqual(BT2446MethodC.inflection, ip, accuracy: 5e-4, "58.535 / the printed k1")
  }

  /// Eq. (5) with the printed parameters is continuous in value and slope at the
  /// inflection point taken at 58.535 cd/m², not at eq. (6)'s rounded 58.5.
  func testMethodCCurveIsContinuousAndMonotonic() {
    let c = BT2446MethodC.self, ip = c.inflection
    XCTAssertEqual(c.k1 * ip, c.k2 * log(1 - c.k3) + c.k4, accuracy: 1e-4)
    XCTAssertEqual(c.k2 / (ip * (1 - c.k3)), c.k1, accuracy: 1e-5, "slope")
    let rounded = 58.5 / c.k1
    XCTAssertGreaterThan(abs(c.k1 * rounded - (c.k2 * log(1 - c.k3) + c.k4)), 0.03, "58.5 leaves a step")
    var last = -1.0
    for i in 0...20000 {
      let y = Double(i) / 10
      let s = c.luminance(y)
      XCTAssertGreaterThanOrEqual(s, last)
      last = s
    }
    XCTAssertEqual(c.luminance(1000), 118.38, accuracy: 0.01, "eq. (5) at the 1000 cd/m² peak")
    XCTAssertEqual(pow(c.luminance(1000) / c.sdrPeak, 1 / 2.4), 1.0728, accuracy: 5e-5, "107.3% SDR on BT.1886")
  }

  /// Where Method C reaches 100% SDR (the 100 cd/m² display's peak): eq. (5)
  /// solved for 100 cd/m², Y = Y_ip·(e^((100 − k4)/k2) + k3) = 332.58 cd/m², the
  /// display light of 82.93% HLG on the 1000 cd/m² display. `HDRToSDR.hlg` is
  /// below 1 just under that signal and exactly 1 just over it.
  func testMethodCReachesSDRPeakAt332Point6Nits() {
    let c = BT2446MethodC.self
    let peak = c.inflection * (exp((c.sdrPeak - c.k4) / c.k2) + c.k3)
    XCTAssertEqual(peak, 332.58, accuracy: 0.01)
    XCTAssertEqual(c.luminance(peak), c.sdrPeak, accuracy: 1e-9)
    // The HLG signal whose display light (BT.2100 EOTF, γ 1.2, 1000 cd/m²) is that peak.
    var low = 0.5, high = 1.0
    for _ in 0..<100 {
      let mid = (low + high) / 2
      if 1000 * pow(ColorMath.hlgInverseOETF(mid), 1.2) < peak { low = mid } else { high = mid }
    }
    XCTAssertEqual(low, 0.8293, accuracy: 1e-4)
    func sdr(_ v: Double) -> Double { HDRToSDR.hlg(ColorRGB(r: v, g: v, b: v), primaries: .rec2020).g }
    XCTAssertLessThan(sdr(low - 1e-4), 1)
    XCTAssertGreaterThan(sdr(low - 1e-4), 0.9999)
    XCTAssertEqual(sdr(low + 1e-4), 1)
  }

  /// §6.1.3–6.1.6 keep x, y and map Y alone, so the crosstalk matrix and its
  /// inverse cancel round a scalar: the long way through Yxy is the display light
  /// scaled by Y_SDR/Y, with Y the luminance of the crosstalked light. That is
  /// the form the shader runs.
  func testMethodCThroughYxyIsALuminanceRatio() {
    var random = Random(state: 7)
    for primaries in [ColorPrimaries.rec2020, .rec709] {
      let w = primaries.luminanceCoefficients
      for alpha in [0.0, 0.1, 0.33] {
        for _ in 0..<200 {
          let rgb = ColorRGB(r: 1000 * random.next(), g: 1000 * random.next(), b: 1000 * random.next())
          let long = BT2446MethodC.toneMap(rgb, primaries: primaries, crosstalk: alpha)
          let b = 1 - 2 * alpha
          let crossed = ColorRGB(
            r: b * rgb.r + alpha * rgb.g + alpha * rgb.b, g: alpha * rgb.r + b * rgb.g + alpha * rgb.b,
            b: alpha * rgb.r + alpha * rgb.g + b * rgb.b)
          let y = w.r * crossed.r + w.g * crossed.g + w.b * crossed.b
          let k = BT2446MethodC.luminance(y) / y
          XCTAssertEqual(long.r, rgb.r * k, accuracy: 1e-9 * max(1, rgb.r * k))
          XCTAssertEqual(long.g, rgb.g * k, accuracy: 1e-9 * max(1, rgb.g * k))
          XCTAssertEqual(long.b, rgb.b * k, accuracy: 1e-9 * max(1, rgb.b * k))
        }
      }
    }
    XCTAssertEqual(BT2446MethodC.toneMap(ColorRGB(r: 0, g: 0, b: 0), primaries: .rec2020), ColorRGB(r: 0, g: 0, b: 0))
  }

  /// Eq. (3)'s matrix is BT.2020's normalized primary matrix with BT.2100's luminance row.
  func testMethodCXYZMatrixIsEquationThree() {
    let m = BT2446MethodC.xyzMatrix(.rec2020)
    let printed = [[0.6370, 0.1446, 0.1689], [0.2627, 0.6780, 0.0593], [0.0000, 0.0281, 1.0610]]
    let rows = [m.red, m.green, m.blue]
    for r in 0..<3 {
      XCTAssertEqual(rows[r].r, printed[r][0], accuracy: 5e-5)
      XCTAssertEqual(rows[r].g, printed[r][1], accuracy: 5e-5)
      XCTAssertEqual(rows[r].b, printed[r][2], accuracy: 5e-5)
    }
    // Eq. (13) is its inverse, printed to four decimals.
    let inverse = m.inverse
    let printedInverse = [[1.7167, -0.3557, -0.2534], [-0.6667, 1.6165, 0.0158], [0.0176, -0.0428, 0.9421]]
    let inverseRows = [inverse.red, inverse.green, inverse.blue]
    for r in 0..<3 {
      XCTAssertEqual(inverseRows[r].r, printedInverse[r][0], accuracy: 1e-4)
      XCTAssertEqual(inverseRows[r].g, printedInverse[r][1], accuracy: 1e-4)
      XCTAssertEqual(inverseRows[r].b, printedInverse[r][2], accuracy: 1e-4)
    }
  }
}
