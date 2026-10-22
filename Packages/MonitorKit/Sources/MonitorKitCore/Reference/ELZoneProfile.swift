import Foundation

/// Operational public-chart profile using Ultracam's explicit midpoint convention.
/// It does not claim Sony Monitor & Control's continuous classifier or output RGB.
public enum ELZoneProfile {
  public static let profileID = "ultracam-elzone-public-chart-v1"
  public static let specificationVersion = "Ultracam-PanasonicFW9-Midpoints-v1"
  public static let displayName = "EL Zone · Public chart"
  public static let stopLabels = ELZonePublicReference.stopLabels
  public static let palette = ELZonePublicReference.palette

  /// Black owns -6; remaining equalities belong to the higher exposure zone.
  /// The extrema use explicit +/-6 limits rather than midpoints to adjacent labels.
  public static let transitions: [Double] = [
    -6, -4.5, -3.5, -2.5, -1.5, -0.75, -0.25, 0.25, 0.75, 1.5, 2.5, 3.5, 4.5, 6,
  ]

  public static func gamut(forSourceProfileID: String?) -> ColorGamut? {
    switch forSourceProfileID {
    case "sony-slog3-sgamut3cine": return .sGamut3Cine
    case "sony-slog3-sgamut3": return .sGamut3
    default: return nil
    }
  }

  public static func supports(sourceProfileID: String?) -> Bool {
    gamut(forSourceProfileID: sourceProfileID) != nil
  }

  public static func zoneIndex(stops: Double) -> Int? {
    guard stops.isFinite else { return nil }
    if stops <= -6 { return 0 }
    for index in 1..<transitions.count where stops < transitions[index] { return index }
    return 14
  }

  public static func color(stops: Double) -> ColorRGB? {
    guard let index = zoneIndex(stops: stops) else { return nil }
    return palette[index]
  }

  /// Reconstruct native normalized Sony code before calling this function.
  /// Decode RGB independently, then calculate source-gamut scene-linear Y.
  /// The user offset is additive in stops; camera EI never supplies implicit gain.
  public static func color(
    rgb: ColorRGB, gamut: ColorGamut, referenceOffsetStops: Double = 0
  ) -> ColorRGB? {
    guard referenceOffsetStops.isFinite, gamut == .sGamut3 || gamut == .sGamut3Cine,
      let r = ColorMath.sLog3Decode(rgb.r),
      let g = ColorMath.sLog3Decode(rgb.g),
      let b = ColorMath.sLog3Decode(rgb.b),
      let y = ColorMath.linearLuminance(.init(r: r, g: g, b: b), gamut: gamut), y.isFinite
    else { return nil }
    if y <= 0 { return palette[0] }
    let stops = log2(y) - log2(0.18) + referenceOffsetStops
    return color(stops: stops)
  }
}
