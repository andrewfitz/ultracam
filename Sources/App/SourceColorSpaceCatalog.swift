import Foundation

/// Stable user declarations. Neither LUT names nor camera names select a space.
enum SourceColorSpaceCatalog {
  struct Entry: Identifiable { let id: String; let title: String; let color: Colorimetry }
  private static func entry(_ id: String, _ title: String, _ primaries: Colorimetry.Primaries,
    _ transfer: Colorimetry.Transfer, matrix: Colorimetry.Matrix = .rec709) -> Entry {
    .init(id: id, title: title, color: .init(primaries: primaries, transfer: transfer, matrix: matrix,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center))
  }
  static let entries: [Entry] = [
    entry("rec709-video", "Rec.709", .rec709, .rec709),
    entry("sony-slog3-sgamut3cine", "S-Gamut3.Cine / S-Log3", .sGamut3Cine, .sLog3),
    entry("sony-slog3-sgamut3", "S-Gamut3 / S-Log3", .sGamut3, .sLog3),
    entry("canon-log-cinemagamut", "Canon Cinema Gamut / C-Log", .canonCinemaGamut, .canonLog),
    entry("canon-log2-cinemagamut", "Canon Cinema Gamut / C-Log2", .canonCinemaGamut, .canonLog2),
    entry("canon-log3-cinemagamut", "Canon Cinema Gamut / C-Log3", .canonCinemaGamut, .canonLog3),
    entry("panasonic-vlog-vgamut", "Panasonic V-Gamut / V-Log", .vGamut, .vLog),
    entry("blackmagic-film-gen5-widegamut", "Blackmagic Wide Gamut / Film Gen 5", .blackmagicWideGamutGen5, .blackmagicFilmGen5),
    entry("arri-logc3-ei800", "ARRI Wide Gamut 3 / LogC3", .arriWideGamut3, .arriLogC3),
    entry("arri-alexa35-logc4-ei800", "ARRI Wide Gamut 4 / LogC4", .arriWideGamut4, .arriLogC4),
    entry("red-log3g10-widegamutrgb", "REDWideGamutRGB / Log3G10", .redWideGamutRGB, .redLog3G10),
    entry("rec2020-hlg-video", "Rec.2020 / HLG", .rec2020, .hlg, matrix: .rec2020),
    entry("rec2020-pq-video", "Rec.2020 / PQ", .rec2020, .pq, matrix: .rec2020)
  ]
  /// Camera declarations that use a supported log curve, in catalog order.
  static var logProfiles: [Entry] {
    entries.filter {
      switch $0.color.transfer {
      case .unspecified, .rec709, .sRGB, .linear, .pq, .hlg: return false
      default: return true
      }
    }
  }

  /// The source picker declares RGB encoding only. Callers merge this with
  /// admitted or parsed source transport using `overridingRGBEncoding(with:)`.
  /// Complete catalog colours remain available separately for output targets.
  static func sourceRGBOverride(_ id: String) throws -> Colorimetry? {
    id == "unspecified" ? nil : try color(id)
  }
  static func color(_ id: String) throws -> Colorimetry {
    guard let entry = entries.first(where: { $0.id == id }) else {
      throw PluginError.unsupported("Unknown color-space declaration ‘\(id)’. Choose a supported LUT input and output space.")
    }
    return entry.color
  }
  static func title(_ id: String) -> String { entries.first { $0.id == id }?.title ?? id }
  static func profile(forLegacyName name: String) -> String { entries.first { $0.title == name }?.id ?? "unspecified" }
}
