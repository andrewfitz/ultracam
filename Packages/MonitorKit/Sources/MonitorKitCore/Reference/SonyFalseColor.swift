import Foundation

public enum SonyFalseColorCategory: String, Codable, CaseIterable, Sendable {
  case red, orange, yellow, cyan, pink, lightPink, green, lightBlue, blue, purple

  /// Ultracam display choices for Sony's named color families, not measured Sony UI RGB.
  public var color: ColorRGB {
    switch self {
    case .red: return ColorRGB(r: 1, g: 0, b: 0)
    case .orange: return ColorRGB(r: 1, g: 0.5, b: 0)
    case .yellow: return ColorRGB(r: 1, g: 1, b: 0)
    case .cyan: return ColorRGB(r: 0, g: 1, b: 1)
    case .pink: return ColorRGB(r: 1, g: 0.4, b: 0.7)
    case .lightPink: return ColorRGB(r: 1, g: 0.7, b: 0.8)
    case .green: return ColorRGB(r: 0, g: 1, b: 0)
    case .lightBlue: return ColorRGB(r: 0.3, g: 0.65, b: 1)
    case .blue: return ColorRGB(r: 0, g: 0, b: 1)
    case .purple: return ColorRGB(r: 0.6, g: 0, b: 1)
    }
  }
}

public struct SonyFalseColorZone: Equatable, Sendable {
  public let category: SonyFalseColorCategory
  public let lowerIRE: Double
  public let upperIRE: Double
}

/// Sony Monitor & Control Pattern2 (S-Log3), evaluated on native encoded signal luma.
/// Transport scaling must be undone first. Neither camera EI nor scene-linear Y is used.
public enum SonySLog3FalseColor {
  public static let profileID = "sony-slog3-false-color-v1"
  public static let specificationVersion = "sony-monitor-control-pattern2-v1"
  public static let displayName = "Sony S-Log3"
  public static let zones: [SonyFalseColorZone] = [
    .init(category: .red, lowerIRE: 93.4, upperIRE: 96.1),
    .init(category: .orange, lowerIRE: 87.7, upperIRE: 90.6),
    .init(category: .yellow, lowerIRE: 91.3, upperIRE: 93.4),
    .init(category: .cyan, lowerIRE: 43.8, upperIRE: 46.5),
    .init(category: .pink, lowerIRE: 54.3, upperIRE: 58),
    .init(category: .lightPink, lowerIRE: 47.8, upperIRE: 50.8),
    .init(category: .green, lowerIRE: 38.9, upperIRE: 42.2),
    .init(category: .lightBlue, lowerIRE: 24.6, upperIRE: 34.4),
    .init(category: .blue, lowerIRE: 3.5, upperIRE: 5.6),
    .init(category: .purple, lowerIRE: -7, upperIRE: 3.5),
  ]

  public static func supports(sourceProfileID: String?) -> Bool {
    sourceProfileID == "sony-slog3-sgamut3cine" || sourceProfileID == "sony-slog3-sgamut3"
  }

  /// Native full-code normalization is distinct from a legal/full container attachment.
  public static func ire(nativeNormalized: Double) -> Double? {
    guard nativeNormalized.isFinite else { return nil }
    let value = (nativeNormalized * 1023 - 64) / 876 * 100
    return value.isFinite ? value : nil
  }

  /// Lower-inclusive, upper-exclusive ownership is Ultracam's explicit convention.
  public static func category(ire: Double) -> SonyFalseColorCategory? {
    guard ire.isFinite else { return nil }
    return zones.first { ire >= $0.lowerIRE && ire < $0.upperIRE }?.category
  }

  public static func category(nativeSignalLuma: Double) -> SonyFalseColorCategory? {
    guard let value = ire(nativeNormalized: nativeSignalLuma) else { return nil }
    return category(ire: value)
  }

  /// Gaps and numerical headroom/footroom retain native achromatic gray without clipping.
  public static func color(nativeSignalLuma: Double) -> ColorRGB? {
    guard let value = ire(nativeNormalized: nativeSignalLuma) else { return nil }
    return category(ire: value)?.color
      ?? ColorRGB(r: nativeSignalLuma, g: nativeSignalLuma, b: nativeSignalLuma)
  }

  /// RGB channels must already have been reconstructed into native normalized S-Log3.
  public static func color(rgb: ColorRGB, matrix: YCbCrMatrix = .bt709) -> ColorRGB? {
    guard let luma = ColorMath.signalLuma(rgb, matrix: matrix) else { return nil }
    return color(nativeSignalLuma: luma)
  }
}
