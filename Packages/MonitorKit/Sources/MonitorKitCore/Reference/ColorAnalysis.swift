import Foundation

public struct ColorRGB: Equatable, Sendable {
  public var r: Double
  public var g: Double
  public var b: Double
  public init(r: Double, g: Double, b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }
  public var isFinite: Bool { r.isFinite && g.isFinite && b.isFinite }
}

/// Code container interpretation, independent of the camera's native Log encoding.
/// Headroom/footroom are preserved; these functions never clip to nominal range.
public enum CodeRange: String, Codable, Sendable {
  case full, legal
  public func normalizeLuma(code: Double, bitDepth: Int) -> Double? {
    guard code.isFinite, (8...16).contains(bitDepth) else { return nil }
    let scale = pow(2, Double(bitDepth - 8))
    return self == .full
      ? code / (pow(2, Double(bitDepth)) - 1) : (code - 16 * scale) / (219 * scale)
  }
  public func lumaCode(normalized: Double, bitDepth: Int) -> Double? {
    guard normalized.isFinite, (8...16).contains(bitDepth) else { return nil }
    let scale = pow(2, Double(bitDepth - 8))
    return self == .full
      ? normalized * (pow(2, Double(bitDepth)) - 1) : normalized * 219 * scale + 16 * scale
  }
  public func normalizeChroma(code: Double, bitDepth: Int) -> Double? {
    guard code.isFinite, (8...16).contains(bitDepth) else { return nil }
    let center = pow(2, Double(bitDepth - 1))
    let span = self == .full ? pow(2, Double(bitDepth)) - 1 : 224 * pow(2, Double(bitDepth - 8))
    return (code - center) / span
  }
}

/// Only use when the actual transport mapping has been established. A container's
/// video-range attachment alone does not prove how native camera Log was scaled.
public struct NativeLogCodeMapping: Equatable, Sendable {
  public let transportedBlack: Double
  public let transportedWhite: Double
  public init?(transportedBlack: Double, transportedWhite: Double) {
    guard transportedBlack.isFinite, transportedWhite.isFinite, transportedWhite > transportedBlack,
      (transportedWhite - transportedBlack).isFinite
    else { return nil }
    self.transportedBlack = transportedBlack
    self.transportedWhite = transportedWhite
  }
  public func nativeNormalized(transportCode: Double) -> Double? {
    guard transportCode.isFinite else { return nil }
    let value = (transportCode - transportedBlack) / (transportedWhite - transportedBlack)
    return value.isFinite ? value : nil
  }
  public static let native10Bit = NativeLogCodeMapping(transportedBlack: 0, transportedWhite: 1023)!
  public static let fullRescaledToLegal10Bit = NativeLogCodeMapping(
    transportedBlack: 64, transportedWhite: 940)!
}

public enum YCbCrMatrix: String, Codable, Sendable {
  case bt601, bt709, bt2020
  /// SMPTE 240M-1999 (legacy 1035i/1080i HD): E'Y = 0.212 R' + 0.701 G' + 0.087 B'.
  case smpte240m
  public var coefficients: (r: Double, g: Double, b: Double) {
    switch self {
    case .bt601: return (0.299, 0.587, 0.114)
    case .bt709: return (0.2126, 0.7152, 0.0722)
    case .bt2020: return (0.2627, 0.6780, 0.0593)
    case .smpte240m: return (0.212, 0.701, 0.087)
    }
  }
}

/// Scene-linear RGB-to-Y coefficients. These are NOT the transport YCbCr matrix.
/// Each is the Y row of the gamut's normalized primary matrix (SMPTE RP 177) with
/// a D65 white; `Docs/MATH.md` section 3 lists the sources.
public enum ColorGamut: String, Codable, Sendable {
  case rec709, rec2020, sGamut3, sGamut3Cine
  /// ALEXA Wide Gamut 3 (LogC3 cameras) and 4 (ALEXA 35, LogC4).
  case arriWideGamut3, arriWideGamut4
  public var luminanceCoefficients: ColorRGB {
    switch self {
    case .rec709: return ColorRGB(r: 0.2126, g: 0.7152, b: 0.0722)
    case .rec2020: return ColorRGB(r: 0.2627, g: 0.6780, b: 0.0593)
    case .sGamut3:
      // Sony's S-Gamut3 to XYZ matrix, row Y, matches these to 10 decimals.
      return ColorRGB(r: 0.270979670813492, g: 0.786606411220905, b: -0.057586082034398)
    case .sGamut3Cine:
      return ColorRGB(r: 0.215075820115587, g: 0.885068501743727, b: -0.100144321859314)
    case .arriWideGamut3:
      // ARRI LogC3 white paper appendix, published to 6 decimals.
      return ColorRGB(r: 0.291954, g: 0.823841, b: -0.115795)
    case .arriWideGamut4:
      // ARRI LogC4 specification, eq. 5a.
      return ColorRGB(r: 0.2545241764, g: 0.7814777327, b: -0.0360019091)
    }
  }
}

public enum ColorMath {
  public static func yCbCrToRGB(y: Double, cb: Double, cr: Double, matrix: YCbCrMatrix)
    -> ColorRGB?
  {
    guard y.isFinite, cb.isFinite, cr.isFinite else { return nil }
    let k = matrix.coefficients
    let r = y + 2 * (1 - k.r) * cr
    let b = y + 2 * (1 - k.b) * cb
    return ColorRGB(r: r, g: (y - k.r * r - k.b * b) / k.g, b: b)
  }
  public static func signalLuma(_ rgb: ColorRGB, matrix: YCbCrMatrix) -> Double? {
    guard rgb.isFinite else { return nil }
    let k = matrix.coefficients
    return rgb.r * k.r + rgb.g * k.g + rgb.b * k.b
  }
  public static func linearLuminance(_ rgb: ColorRGB, gamut: ColorGamut) -> Double? {
    guard rgb.isFinite else { return nil }
    let k = gamut.luminanceCoefficients
    return rgb.r * k.r + rgb.g * k.g + rgb.b * k.b
  }
  /// Sony Technical Summary appendix, scene reflectance to normalized native S-Log3.
  public static func sLog3Encode(_ linear: Double) -> Double? {
    guard linear.isFinite else { return nil }
    let code =
      linear >= 0.01125
      ? 420 + log10((linear + 0.01) / 0.19) * 261.5 : linear * (171.2102946929 - 95) / 0.01125 + 95
    let result = code / 1023
    return result.isFinite ? result : nil
  }
  public static func sLog3Decode(_ nativeNormalized: Double) -> Double? {
    guard nativeNormalized.isFinite else { return nil }
    let code = nativeNormalized * 1023
    let result =
      code >= 171.2102946929
      ? pow(10, (code - 420) / 261.5) * 0.19 - 0.01 : (code - 95) * 0.01125 / (171.2102946929 - 95)
    return result.isFinite ? result : nil
  }
  /// Decode channels first, then calculate source-gamut scene-linear Y.
  public static func sLog3ExposureStops(_ rgb: ColorRGB, gamut: ColorGamut) -> Double? {
    guard let r = sLog3Decode(rgb.r), let g = sLog3Decode(rgb.g), let b = sLog3Decode(rgb.b),
      let y = linearLuminance(ColorRGB(r: r, g: g, b: b), gamut: gamut)
    else { return nil }
    return exposureStops(linearLuminance: y)
  }
  /// Nonpositive scene luminance has no finite exposure in stops.
  public static func exposureStops(linearLuminance: Double) -> Double? {
    guard linearLuminance.isFinite, linearLuminance > 0 else { return nil }
    let value = log2(linearLuminance) - log2(0.18)
    return value.isFinite ? value : nil
  }
  public static func zebra(ire: Double, threshold: Double, width: Double, above: Bool) -> Bool {
    guard ire.isFinite, threshold.isFinite, width.isFinite, width >= 0 else { return false }
    return above ? ire >= threshold : ire >= threshold - width / 2 && ire < threshold + width / 2
  }
  /// Spatial scope reference bin. Out-of-scale signal is clamped only at rasterization.
  public static func scopeBin(normalized: Double, binCount: Int) -> Int? {
    guard normalized.isFinite, binCount > 0 else { return nil }
    let value = min(1, max(0, normalized))
    if value >= 1 { return binCount - 1 }
    // Double(Int.max) rounds upward, so bound before converting back to Int.
    let scaled = (value * Double(binCount - 1)).rounded(.down)
    if scaled >= Double(Int.max) { return binCount - 1 }
    return Int(scaled)
  }
  /// Generic half-stop quantization for fixture generation; not an EL Zone classifier.
  public static func halfStopBand(stops: Double) -> Int? {
    guard stops.isFinite, abs(stops) < Double(Int.max / 4) else { return nil }
    return Int(floor(stops * 2 + 0.5))
  }
}

public enum ARRIFalseColorProfile: String, CaseIterable, Codable, Sendable {
  case logC3EI800 = "arri-logc3-ei800"
  case alexa35LogC4EI800 = "arri-alexa35-logc4-ei800"
  public static let specificationVersion = "ARRI-2025-02-04"
  public var exposureIndex: Int { 800 }
  public var displayName: String {
    self == .logC3EI800 ? "ARRI LogC3 EI800" : "ARRI ALEXA 35 LogC4 EI800"
  }
  /// Exact published 10-bit precomputed table. Full-range values have independent
  /// rounding and must not be derived by rescaling already rounded legal bounds.
  public func zones(range: CodeRange) -> [ARRIFalseColorZone] {
    let values: [(ARRIFalseColorCategory, Double, Double)]
    switch (self, range) {
    case (.logC3EI800, .legal):
      values = [
        (.red, 878, 940), (.yellow, 857, 878), (.pink, 461, 480), (.green, 397, 415),
        (.blue, 152, 172), (.purple, 64, 152),
      ]
    case (.logC3EI800, .full):
      values = [
        (.red, 951, 1023), (.yellow, 926, 951), (.pink, 464, 486), (.green, 389, 410),
        (.blue, 103, 127), (.purple, 0, 103),
      ]
    case (.alexa35LogC4EI800, .legal):
      values = [
        (.red, 808, 940), (.yellow, 789, 808), (.pink, 351, 366), (.green, 300, 315),
        (.blue, 149, 159), (.purple, 64, 149),
      ]
    case (.alexa35LogC4EI800, .full):
      values = [
        (.red, 868, 1023), (.yellow, 846, 868), (.pink, 335, 353), (.green, 276, 293),
        (.blue, 99, 111), (.purple, 0, 99),
      ]
    }
    return values.map { ARRIFalseColorZone(category: $0.0, lower: $0.1, upper: $0.2) }
  }
  public func category(achromaticCode: Double, range: CodeRange) -> ARRIFalseColorCategory? {
    guard achromaticCode.isFinite else { return nil }
    return zones(range: range).first { achromaticCode >= $0.lower && achromaticCode < $0.upper }?
      .category
  }
  /// RGB channels are normalized LogC; the table's quantization/range is explicit.
  /// Sony input uses the separately labeled SonyARRIStyleFalseColor adaptation.
  public func color(rgb: ColorRGB, range: CodeRange) -> ColorRGB? {
    guard let a = ColorMath.signalLuma(rgb, matrix: .bt709),
      let code = range.lumaCode(normalized: a, bitDepth: 10)
    else { return nil }
    return category(achromaticCode: code, range: range)?.color ?? ColorRGB(r: a, g: a, b: a)
  }
}
/// Luminance-based ARRI-style reference adaptation for native Sony S-Log3.
public enum SonyARRIStyleFalseColor {
  public static let profileID = "arri-style-slog3-logc3-ei800-v1"
  public static let specificationVersion = "ARRI-style-SLog3-LogC3-EI800-v1"
  public static let displayName = "ARRI-style — S-Log3"
  public static let referenceExposureIndex = 800
  public static func gamut(forSourceProfileID profileID: String?) -> ColorGamut? {
    switch profileID {
    case "sony-slog3-sgamut3cine": return .sGamut3Cine
    case "sony-slog3-sgamut3": return .sGamut3
    default: return nil
    }
  }
  public static func supports(sourceProfileID: String?) -> Bool {
    gamut(forSourceProfileID: sourceProfileID) != nil
  }
  /// ARRI 2017 LogC3 exposure-value formula, EI800, expressed as full 10-bit code.
  /// This fixed reference does not describe the Sony sensor's clipping/noise floor.
  public static func referenceCode(sceneLinearLuma: Double) -> Double? {
    guard sceneLinearLuma.isFinite else { return nil }
    let normalized = sceneLinearLuma > 0.010591
      ? 0.247190 * log10(5.555556 * sceneLinearLuma + 0.052272) + 0.385537
      : 5.367655 * sceneLinearLuma + 0.092809
    let code = normalized * 1023
    return code.isFinite ? code : nil
  }
  private static func referenceCode(rgb: ColorRGB, gamut: ColorGamut) -> Double? {
    guard gamut == .sGamut3 || gamut == .sGamut3Cine,
      let r = ColorMath.sLog3Decode(rgb.r),
      let g = ColorMath.sLog3Decode(rgb.g),
      let b = ColorMath.sLog3Decode(rgb.b),
      let y = ColorMath.linearLuminance(ColorRGB(r: r, g: g, b: b), gamut: gamut)
    else { return nil }
    return referenceCode(sceneLinearLuma: y)
  }
  /// Native normalized S-Log3 channels are decoded before source-gamut linear Y.
  public static func category(rgb: ColorRGB, gamut: ColorGamut) -> ARRIFalseColorCategory? {
    guard let code = referenceCode(rgb: rgb, gamut: gamut) else { return nil }
    return ARRIFalseColorProfile.logC3EI800.category(achromaticCode: code, range: .full)
  }
  /// Unclassified pixels retain their original native S-Log3 achromatic signal.
  /// Category colors are display colors and must bypass the viewing LUT.
  public static func color(rgb: ColorRGB, gamut: ColorGamut) -> ColorRGB? {
    guard let code = referenceCode(rgb: rgb, gamut: gamut),
      let a = ColorMath.signalLuma(rgb, matrix: .bt709), a.isFinite
    else { return nil }
    return ARRIFalseColorProfile.logC3EI800.category(achromaticCode: code, range: .full)?.color
      ?? ColorRGB(r: a, g: a, b: a)
  }
}
public struct ARRIFalseColorZone: Equatable, Sendable {
  public let category: ARRIFalseColorCategory
  public let lower: Double
  public let upper: Double
}
public enum ARRIFalseColorCategory: String, CaseIterable, Codable, Sendable {
  case red, yellow, pink, green, blue, purple
  public var color: ColorRGB {
    switch self {
    case .red: return ColorRGB(r: 1, g: 0, b: 0)
    case .yellow: return ColorRGB(r: 1, g: 1, b: 0)
    case .pink: return ColorRGB(r: 1, g: 0.7, b: 0.7)
    case .green: return ColorRGB(r: 0, g: 1, b: 0)
    case .blue: return ColorRGB(r: 0, g: 0, b: 1)
    case .purple: return ColorRGB(r: 0.7, g: 0, b: 1)
    }
  }
}

/// Vendor-parity evidence, separate from the available versioned ELZoneProfile.
/// The public-chart implementation defines its own continuous band convention;
/// it does not establish Sony Monitor & Control's operational classifier.
public enum ELZoneReferenceStatus {
  public static let researchVersion = "public-primary-sources-2026-10-19"
  public static let isQualified = false
  public static let reason =
    "Sony Monitor & Control parity is not verified; EL Zone uses Ultracam's documented public-chart mapping."
}

/// Versioned public chart evidence, not a claim of continuous camera compatibility.
/// Palette values are PDF DeviceRGB rectangle operands, not sampled screenshot RGB.
public enum ELZonePublicReference {
  public static let profileID = "elzone-panasonic-varicam-fw9-public-chart"
  public static let sourceSHA256 =
    "d607e4189356c7dc09f77c93ae4d1be04a44c740b34829045a1b7f06d288a6f8"
  public static let stopLabels: [Double] = [-6, -5, -4, -3, -2, -1, -0.5, 0, 0.5, 1, 2, 3, 4, 5, 6]
  public static let palette: [ColorRGB] = [
    ColorRGB(r: 0, g: 0, b: 0),
    ColorRGB(r: 0.439, g: 0.188, b: 0.627),
    ColorRGB(r: 0, g: 0.439, b: 0.753),
    ColorRGB(r: 0, g: 0.69, b: 0.941),
    ColorRGB(r: 0.0824, g: 0.651, b: 0.0549),
    ColorRGB(r: 0.192, g: 0.878, b: 0.141),
    ColorRGB(r: 0, g: 1, b: 0),
    ColorRGB(r: 0.533, g: 0.537, b: 0.506),
    ColorRGB(r: 0.973, g: 0.949, b: 0),
    ColorRGB(r: 1, g: 0.992, b: 0.463),
    ColorRGB(r: 1, g: 0.565, b: 0),
    ColorRGB(r: 1, g: 0.694, b: 0.357),
    ColorRGB(r: 1, g: 0, b: 0),
    ColorRGB(r: 1, g: 0.412, b: 0.412),
    ColorRGB(r: 1, g: 1, b: 1),
  ]
  /// Only exact labeled points and the patent's explicit +/-6 extrema are known.
  /// Interior non-anchor values return nil rather than inventing interval edges.
  public static func knownReferenceColor(stops: Double) -> ColorRGB? {
    guard stops.isFinite else { return nil }
    if stops <= -6 { return palette[0] }
    if stops >= 6 { return palette[14] }
    guard let index = stopLabels.firstIndex(of: stops) else { return nil }
    return palette[index]
  }
  public static func referenceLinearLuminance(stops: Double) -> Double? {
    guard stops.isFinite else { return nil }
    let result = 0.18 * pow(2, stops)
    return result.isFinite && result > 0 ? result : nil
  }
}
