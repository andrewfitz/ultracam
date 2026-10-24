import Foundation

/// HLG to SDR tone mapping by Report ITU-R BT.2446-1 (03/2021) §6.1, "Conversion
/// Method C" (`Docs/MATH.md` §5.1 gives the equations and why C, not A).
///
/// The HLG signal is decoded to display light with the BT.2100 EOTF for the
/// 1000 cd/m² conversion peak and the system gamma 1.2 (§6.1.1). The luminance Y
/// of that light is tone mapped by eq. (5), linear below the inflection point
/// and logarithmic above it, while the chromaticity x, y is kept (§6.1.3–6.1.5).
/// The Report's parameters (eq. (10)) put 50% HLG at 70% SDR (BT.2408 Annex 4's
/// skin tones), the knee at 80% SDR and HDR Reference White (75% HLG) at 96% SDR,
/// on a 100 cd/m² SDR display.
public enum BT2446MethodC {
  /// Eq. (10).
  public static let k1 = 0.83802
  public static let k2 = 15.09968
  public static let k3 = 0.74204
  public static let k4 = 78.99439
  /// The SDR luminance of the inflection point: 80% SDR on the 100 cd/m² display,
  /// 100·0.8^2.4 = 58.535 cd/m². Eq. (6) prints it rounded to 58.5; eq. (10)'s k2,
  /// k3 and k4 come out to every printed digit only with the unrounded value, and
  /// only with it is eq. (5) continuous (to 2e-5 cd/m²) with them.
  public static let inflectionSDR = 100 * pow(0.8, 2.4)
  /// Eq. (6): Y_HDR,ip = 58.535 / k1 = 69.85 cd/m².
  public static let inflection = inflectionSDR / k1
  /// The SDR display's peak luminance in cd/m², SDR 1.0 (BT.1886's reference
  /// display; the Report's SDR levels are percentages of it).
  public static let sdrPeak = 100.0
  /// The crosstalk α of eq. (2), 0…0.33. The Report gives no value; MonitorKit
  /// uses 0 (a convention), which makes the crosstalk the identity and keeps the
  /// Report's (achromatic) anchors.
  public static let crosstalk = 0.0
  /// The HDR display the HLG signal is decoded for (§6.1.1, the 1000 cd/m²
  /// conversion peak of Table 1).
  public static let hdrPeak = 1000.0

  /// Eq. (5): HDR luminance in cd/m² to SDR luminance in cd/m².
  public static func luminance(_ y: Double) -> Double {
    y < inflection ? k1 * y : k2 * log(y / inflection - k3) + k4
  }

  /// Eq. (3)'s RGB to XYZ: the primaries' normalized primary matrix with the
  /// luminance row BT.2100 publishes (eq. (3)'s Y row is BT.2100's 0.2627, 0.6780,
  /// 0.0593), so Y is the luminance the HLG OOTF uses.
  static func xyzMatrix(_ p: ColorPrimaries) -> ColorMatrix {
    var m = p.toXYZ
    m.green = p.luminanceCoefficients
    return m
  }

  /// §6.1.2–6.1.6 on linear display light in cd/m² in `primaries`: the crosstalk
  /// matrix (eq. (2)), XYZ and xy (eqs. (3), (4)), eq. (5) on Y, XYZ from Y and
  /// the same x, y (eqs. (11), (12)), RGB (eq. (13)) and the inverse crosstalk
  /// (eq. (14)). SDR display light in cd/m², in `primaries`. Black stays black.
  public static func toneMap(_ rgb: ColorRGB, primaries: ColorPrimaries, crosstalk a: Double = crosstalk) -> ColorRGB {
    let b = 1 - 2 * a
    let x = ColorMatrix(red: ColorRGB(r: b, g: a, b: a), green: ColorRGB(r: a, g: b, b: a), blue: ColorRGB(r: a, g: a, b: b))
    let m = xyzMatrix(primaries)
    let xyz = m.apply(x.apply(rgb))
    let sum = xyz.r + xyz.g + xyz.b
    guard xyz.g > 0, sum > 0 else { return ColorRGB(r: 0, g: 0, b: 0) }
    let cx = xyz.r / sum, cy = xyz.g / sum
    let y = luminance(xyz.g)
    let sdr = ColorRGB(r: cx / cy * y, g: y, b: (1 - cx - cy) / cy * y)
    return x.inverse.apply(m.inverse.apply(sdr))
  }
}
