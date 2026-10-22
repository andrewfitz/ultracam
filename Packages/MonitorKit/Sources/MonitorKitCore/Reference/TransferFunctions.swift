import Foundation

/// Display transfer functions and tone mapping for the output stage. The MSL in
/// MKMonitor.msl mirrors each one; `Docs/MATH.md` lists the sources.
///
/// Signals below zero (sub-blacks, out-of-gamut colours) go through the SDR curves
/// mirrored about zero, the extension Report ITU-R BT.2408-8 §5.3 describes, so an
/// extended-range output keeps them. PQ and HLG are defined from zero light only.
extension ColorMath {
  /// `sign(v)·|v|^e`.
  static func mirroredPow(_ v: Double, _ e: Double) -> Double { v < 0 ? -pow(-v, e) : pow(v, e) }

  /// ITU-R BT.1886 Annex 1 EOTF with a black of 0 and a white of 1: L = V^2.4.
  /// The display a BT.709 signal is shown on, so BT.709 video is BT.1886 display light.
  public static func bt1886EOTF(_ v: Double) -> Double { mirroredPow(v, 2.4) }
  /// The inverse: V = L^(1/2.4).
  public static func bt1886InverseEOTF(_ l: Double) -> Double { mirroredPow(l, 1 / 2.4) }

  /// ITU-R BT.1886 Annex 1 EOTF with the display's black and white luminances:
  /// L = a·max(V + b, 0)^2.4.
  public static func bt1886EOTF(_ v: Double, black: Double, white: Double) -> Double {
    let g = 1 / 2.4, w = pow(white, g), k = pow(black, g)
    let a = pow(w - k, 2.4), b = k / (w - k)
    return a * pow(max(v + b, 0), 2.4)
  }

  /// A pure 2.2 power display (common computer monitors).
  public static func gamma22EOTF(_ v: Double) -> Double { mirroredPow(v, 2.2) }
  public static func gamma22InverseEOTF(_ l: Double) -> Double { mirroredPow(l, 1 / 2.2) }

  /// IEC 61966-2-1 sRGB encode.
  public static func sRGBEncode(_ l: Double) -> Double {
    if l < 0 { return -sRGBEncode(-l) }
    return l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
  }
  /// The sRGB decode mirrored about zero.
  static func sRGBDecodeMirrored(_ v: Double) -> Double { v < 0 ? -sRGBDecode(-v) : sRGBDecode(v) }

  /// ITU-R BT.709 OETF (item 1.2): scene light 0…1 to signal. Below zero it is 0.
  public static func bt709OETF(_ l: Double) -> Double {
    l < 0.018 ? 4.5 * max(l, 0) : 1.099 * pow(l, 0.45) - 0.099
  }

  /// SMPTE ST 2084 inverse EOTF (BT.2100 Table 4): cd/m² 0…10 000 to signal.
  public static func pqSignal(nits: Double) -> Double {
    let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
    let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
    let y = pow(min(max(nits, 0), 10_000) / 10_000, m1)
    return pow((c1 + c2 * y) / (1 + c3 * y), m2)
  }

  /// ITU-R BT.2100 Table 5 HLG OETF: scene light 0…1 to signal.
  public static func hlgOETF(_ e: Double) -> Double {
    let a = 0.17883277, b = 1 - 4 * a, c = 0.5 - a * log(4 * a)
    let e = max(e, 0)
    return e <= 1.0 / 12 ? (3 * e).squareRoot() : a * log(12 * e - b) + c
  }

  /// ITU-R BT.2100 note 5f: the HLG system gamma for a display of nominal peak
  /// `peak` cd/m², 1.2 + 0.42·log10(peak/1000) from 400 to 2000 cd/m², the extended
  /// formula 1.2·1.111^log2(peak/1000) outside it.
  public static func hlgSystemGamma(peak: Double) -> Double {
    peak >= 400 && peak <= 2000 ? 1.2 + 0.42 * log10(peak / 1000) : 1.2 * pow(1.111, log2(peak / 1000))
  }

  /// BT.2100 HLG reference OOTF (black lift 0): scene light E to display light in
  /// cd/m², F = peak·Ys^(γ-1)·E, with Ys from the signal primaries' luminance weights.
  public static func hlgOOTF(_ e: ColorRGB, peak: Double, weights w: ColorRGB) -> ColorRGB {
    let ys = w.r * e.r + w.g * e.g + w.b * e.b
    guard ys > 0 else { return ColorRGB(r: 0, g: 0, b: 0) }
    let k = peak * pow(ys, hlgSystemGamma(peak: peak) - 1)
    return ColorRGB(r: k * e.r, g: k * e.g, b: k * e.b)
  }

  /// The inverse OOTF: display light in cd/m² to scene light. Yd = peak·Ys^γ.
  public static func hlgInverseOOTF(_ f: ColorRGB, peak: Double, weights w: ColorRGB) -> ColorRGB {
    let yd = w.r * f.r + w.g * f.g + w.b * f.b
    guard yd > 0 else { return ColorRGB(r: 0, g: 0, b: 0) }
    let gamma = hlgSystemGamma(peak: peak)
    let ys = pow(yd / peak, 1 / gamma)
    let k = 1 / (peak * pow(ys, gamma - 1))
    return ColorRGB(r: k * f.r, g: k * f.g, b: k * f.b)
  }

  /// The HLG EOTF (black lift 0): signal to display light in cd/m².
  public static func hlgEOTF(_ v: ColorRGB, peak: Double, weights: ColorRGB) -> ColorRGB {
    hlgOOTF(
      ColorRGB(r: hlgInverseOETF(max(v.r, 0)), g: hlgInverseOETF(max(v.g, 0)), b: hlgInverseOETF(max(v.b, 0))),
      peak: peak, weights: weights)
  }

  /// The HLG inverse EOTF: display light in cd/m² (clipped to 0…peak) to signal
  /// (0…1). A saturated colour clipped at the peak can need scene light above 1
  /// after the inverse OOTF (its luminance is below the peak); it clips to 1, as
  /// the signal holds no more.
  public static func hlgInverseEOTF(_ f: ColorRGB, peak: Double, weights: ColorRGB) -> ColorRGB {
    let c = ColorRGB(r: min(max(f.r, 0), peak), g: min(max(f.g, 0), peak), b: min(max(f.b, 0), peak))
    let e = hlgInverseOOTF(c, peak: peak, weights: weights)
    return ColorRGB(r: hlgOETF(min(e.r, 1)), g: hlgOETF(min(e.g, 1)), b: hlgOETF(min(e.b, 1)))
  }
}

/// The PQ tone-mapping curve (EETF) of Report ITU-R BT.2408-8 Annex 5 (first
/// published in Report ITU-R BT.2390), with black levels of 0 (LB = Lmin = 0, so
/// b = 0): a 1:1 mapping up to the knee KS = 1.5·maxLum - 0.5, then a Hermite spline
/// to maxLum at the source peak, in PQ signal normalized to the source peak.
public struct ToneMapEETF: Equatable, Sendable {
  /// Mastering (source) peak and target display peak, cd/m².
  public let sourcePeak: Double
  public let targetPeak: Double
  /// PQ signal of the source peak (Step 1's normalization).
  public let sourceSignal: Double
  /// The target peak in normalized PQ (Step 1 applied to Lmax).
  public let maxLum: Double
  /// Step 2's knee start; 1:1 below it. Negative knees (maxLum < 1/3) start at 0.
  public let kneeStart: Double

  public init(sourcePeak: Double, targetPeak: Double) {
    self.sourcePeak = sourcePeak
    self.targetPeak = targetPeak
    sourceSignal = ColorMath.pqSignal(nits: sourcePeak)
    let m = ColorMath.pqSignal(nits: targetPeak) / sourceSignal
    maxLum = m
    kneeStart = max(1.5 * m - 0.5, 0)
  }

  /// Whether the target holds the source: then the curve is the identity.
  public var isIdentity: Bool { maxLum >= 1 }

  /// Steps 3 and 4 on a normalized PQ value E1: E2.
  public func normalized(_ e1: Double) -> Double {
    if isIdentity || e1 < kneeStart { return e1 }
    let t = (min(e1, 1) - kneeStart) / (1 - kneeStart), t2 = t * t, t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * kneeStart + (t3 - 2 * t2 + t) * (1 - kneeStart) + (-2 * t3 + 3 * t2) * maxLum
  }

  /// One luminance in cd/m² through Steps 1-5.
  public func nits(_ l: Double) -> Double {
    guard l > 0, !isIdentity else { return l }
    return ColorMath.pqNits(normalized(ColorMath.pqSignal(nits: l) / sourceSignal) * sourceSignal)
  }

  /// The "maxRGB" application of Annex 5 (Table A5.1: does not leave the target
  /// colour volume): the largest component is mapped and the others scaled with it.
  public func apply(_ c: ColorRGB) -> ColorRGB {
    let m = max(c.r, c.g, c.b)
    guard m > 0, !isIdentity else { return c }
    let k = nits(m) / m
    return ColorRGB(r: c.r * k, g: c.g * k, b: c.b * k)
  }
}
