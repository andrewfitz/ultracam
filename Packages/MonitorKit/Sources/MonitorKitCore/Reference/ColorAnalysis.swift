// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

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
    let scale = Double(1 << (bitDepth - 8))
    return self == .full
      ? code / (Double((1 << bitDepth) - 1)) : (code - 16 * scale) / (219 * scale)
  }
  public func lumaCode(normalized: Double, bitDepth: Int) -> Double? {
    guard normalized.isFinite, (8...16).contains(bitDepth) else { return nil }
    let scale = Double(1 << (bitDepth - 8))
    let value = self == .full
      ? normalized * (Double((1 << bitDepth) - 1)) : normalized * 219 * scale + 16 * scale
    return value.isFinite ? value : nil
  }
  public func normalizeChroma(code: Double, bitDepth: Int) -> Double? {
    guard code.isFinite, (8...16).contains(bitDepth) else { return nil }
    let center = Double(1 << (bitDepth - 1))
    let span = self == .full ? Double((1 << bitDepth) - 1) : 224 * Double(1 << (bitDepth - 8))
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
    let rgb = ColorRGB(r: r, g: (y - k.r * r - k.b * b) / k.g, b: b)
    return rgb.isFinite ? rgb : nil
  }
  public static func signalLuma(_ rgb: ColorRGB, matrix: YCbCrMatrix) -> Double? {
    guard rgb.isFinite else { return nil }
    let k = matrix.coefficients
    let value = rgb.r * k.r + rgb.g * k.g + rgb.b * k.b
    return value.isFinite ? value : nil
  }
  public static func linearLuminance(_ rgb: ColorRGB, gamut: ColorGamut) -> Double? {
    guard rgb.isFinite else { return nil }
    let k = gamut.luminanceCoefficients
    let value = rgb.r * k.r + rgb.g * k.g + rgb.b * k.b
    return value.isFinite ? value : nil
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
  /// Generic half-stop quantization for fixture generation.
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
  /// Red is open-ended upward and purple downward (MonitorKit's convention, MATH.md
  /// 4.2): read literally, red's `< Bzu` at A' = 1.0 (940 legal, 1023 full) drops the
  /// most clipped codes and super-whites to grey, and purple's floor (64 legal, 0
  /// full) drops sub-blacks and negative float values to grey.
  public func zones(range: CodeRange) -> [ARRIFalseColorZone] {
    switch (self, range) {
    case (.logC3EI800, .legal): return Self.logC3LegalZones
    case (.logC3EI800, .full): return Self.logC3FullZones
    case (.alexa35LogC4EI800, .legal): return Self.logC4LegalZones
    case (.alexa35LogC4EI800, .full): return Self.logC4FullZones
    }
  }

  private static let logC3LegalZones: [ARRIFalseColorZone] = [
    .init(category: .red, lower: 878, upper: .infinity),
    .init(category: .yellow, lower: 857, upper: 878),
    .init(category: .pink, lower: 461, upper: 480),
    .init(category: .green, lower: 397, upper: 415),
    .init(category: .blue, lower: 152, upper: 172),
    .init(category: .purple, lower: -.infinity, upper: 152),
  ]
  private static let logC3FullZones: [ARRIFalseColorZone] = [
    .init(category: .red, lower: 951, upper: .infinity),
    .init(category: .yellow, lower: 926, upper: 951),
    .init(category: .pink, lower: 464, upper: 486),
    .init(category: .green, lower: 389, upper: 410),
    .init(category: .blue, lower: 103, upper: 127),
    .init(category: .purple, lower: -.infinity, upper: 103),
  ]
  private static let logC4LegalZones: [ARRIFalseColorZone] = [
    .init(category: .red, lower: 808, upper: .infinity),
    .init(category: .yellow, lower: 789, upper: 808),
    .init(category: .pink, lower: 351, upper: 366),
    .init(category: .green, lower: 300, upper: 315),
    .init(category: .blue, lower: 149, upper: 159),
    .init(category: .purple, lower: -.infinity, upper: 149),
  ]
  private static let logC4FullZones: [ARRIFalseColorZone] = [
    .init(category: .red, lower: 868, upper: .infinity),
    .init(category: .yellow, lower: 846, upper: 868),
    .init(category: .pink, lower: 335, upper: 353),
    .init(category: .green, lower: 276, upper: 293),
    .init(category: .blue, lower: 99, upper: 111),
    .init(category: .purple, lower: -.infinity, upper: 99),
  ]

  public func category(achromaticCode: Double, range: CodeRange) -> ARRIFalseColorCategory? {
    guard achromaticCode.isFinite else { return nil }
    return zones(range: range).first { achromaticCode >= $0.lower && achromaticCode < $0.upper }?
      .category
  }
  /// RGB channels are normalized LogC; the table's quantization/range is explicit.
  /// Sony input uses the separately labeled SonyARRIStyleFalseColor adaptation.
  public func color(rgb: ColorRGB, range: CodeRange) -> ColorRGB? {
    guard let luma = ColorMath.signalLuma(rgb, matrix: .bt709),
      range.lumaCode(normalized: luma, bitDepth: 10) != nil
    else { return nil }
    // ARRI eqs. (1)/(2) classify normalized achromatic LogC. Preserve neutrals
    // exactly: weighting and reconstructing codes can move an integral table
    // edge just below itself (legal code 397, for example).
    let a = rgb.r == rgb.g && rgb.g == rgb.b ? rgb.r : luma
    let zone = zones(range: range).first {
      a >= (range.normalizeLuma(code: $0.lower, bitDepth: 10) ?? -.infinity)
        && a < (range.normalizeLuma(code: $0.upper, bitDepth: 10) ?? .infinity)
    }
    return zone?.category.color ?? ColorRGB(r: a, g: a, b: a)
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
  /// The table's purple keeps its published floor, code 0 (MATH.md 4.3): a negative
  /// reference code here is also a saturated colour whose source-gamut Y is negative
  /// (S-Gamut3.Cine weights blue negatively), not only a crushed black.
  public static func category(rgb: ColorRGB, gamut: ColorGamut) -> ARRIFalseColorCategory? {
    guard let code = referenceCode(rgb: rgb, gamut: gamut), code >= 0 else { return nil }
    return ARRIFalseColorProfile.logC3EI800.category(achromaticCode: code, range: .full)
  }
  /// Unclassified pixels retain their original native S-Log3 achromatic signal.
  /// Category colors are display colors and must bypass the viewing LUT.
  public static func color(rgb: ColorRGB, gamut: ColorGamut) -> ColorRGB? {
    guard referenceCode(rgb: rgb, gamut: gamut) != nil,
      let a = ColorMath.signalLuma(rgb, matrix: .bt709), a.isFinite
    else { return nil }
    return category(rgb: rgb, gamut: gamut)?.color ?? ColorRGB(r: a, g: a, b: a)
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
