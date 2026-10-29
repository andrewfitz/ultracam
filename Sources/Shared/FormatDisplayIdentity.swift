import Foundation
import CoreMedia

/// The user-facing identity of a video format.  It deliberately contains no
/// capture-session, clock, or allocation identifiers, so the same format has
/// the same wording across runs and devices.
struct FormatDisplayIdentity: Hashable, Sendable {
  let resolution: String
  let aspect: String
  let colour: String
  let transfer: String
  let range: String
  let pixel: String
  let scan: String
  let frameRate: String

  init(_ format: SourceFormat) {
    resolution = Self.resolution(width: format.width, height: format.height)
    aspect = Self.aspect(format.pixelAspect, width: format.width, height: format.height)
    colour = Self.colour(format.colour.primaries)
    transfer = Self.transfer(format.colour.transfer)
    range = format.colour.range == .full ? "Full range" : "Video range"
    pixel = Self.pixel(format.pixel)
    scan = format.scan == .progressive ? "Progressive" : (format.scan == .interlaced ? "Interlaced" : "Progressive segmented frame")
    frameRate = Self.rate(format.rate)
  }

  /// A compact, stable label suitable for menus and signal chips.
  var name: String { "\(resolution) · \(frameRate) · \(aspect)" }
  var displayName: String { name }
  /// Full detail intended for accessibility and diagnostics.
  var detail: String { "\(name) · \(scan) · \(pixel) · \(colour) · \(transfer) · \(range)" }
  var summary: String { detail }

  static func resolution(width: Int, height: Int) -> String {
    let product: String
    switch (width, height) {
    case (1280, 720): product = "HD"
    case (1920, 1080): product = "Full HD"
    case (3840, 2160): product = "UHD"
    case (4096, 2160): product = "DCI 4K"
    default: product = "\(width) × \(height)"
    }
    return product == "\(width) × \(height)" ? product : "\(product) \(width) × \(height)"
  }

  static func aspect(_ pixelAspect: Rational, width: Int, height: Int) -> String {
    let ratio = Double(width) * Double(pixelAspect.numerator) / (Double(height) * Double(pixelAspect.denominator))
    let common: [(Double, String)] = [(16.0 / 9, "16:9"), (17.0 / 9, "17:9"), (4.0 / 3, "4:3"), (1, "1:1")]
    if let match = common.first(where: { abs(ratio - $0.0) < 0.01 }) { return match.1 }
    return String(format: "%.2f:1", ratio)
  }

  private static func colour(_ value: Colorimetry.Primaries) -> String {
    switch value { case .rec709: "Rec. 709"; case .rec2020: "Rec. 2020"; case .p3D65: "Display P3"; case .sGamut3: "S-Gamut3"; case .sGamut3Cine: "S-Gamut3.Cine"; case .arriWideGamut3: "ARRI Wide Gamut 3"; case .arriWideGamut4: "ARRI Wide Gamut 4"; case .canonCinemaGamut: "Canon Cinema Gamut"; case .vGamut: "V-Gamut"; case .blackmagicWideGamutGen5: "Blackmagic Wide Gamut Gen 5"; case .redWideGamutRGB: "REDWideGamutRGB"; case .unspecified: "Unspecified colour" }
  }
  private static func transfer(_ value: Colorimetry.Transfer) -> String {
    switch value { case .rec709: "Rec. 709"; case .sRGB: "sRGB"; case .linear: "Linear"; case .pq: "PQ"; case .hlg: "HLG"; case .sLog3: "S-Log3"; case .arriLogC3: "ARRI LogC3"; case .arriLogC4: "ARRI LogC4"; case .canonLog: "Canon Log"; case .canonLog2: "Canon Log 2"; case .canonLog3: "Canon Log 3"; case .vLog: "V-Log"; case .blackmagicFilmGen5: "Blackmagic Film Gen 5"; case .redLog3G10: "Log3G10"; case .unspecified: "Unspecified transfer" }
  }
  private static func pixel(_ value: PixelFormatID) -> String {
    guard let entry = PixelFormatTable.entry(for: value) else { return "Unknown pixel format" }
    let sampling = entry.planes.map { ($0.horizontalSubsampling, $0.verticalSubsampling) }
    let chroma: String
    if value == .uyva { chroma = "4:2:2" }
    else if sampling.contains(where: { $0 == (2, 2) }) { chroma = "4:2:0" }
    else if sampling.contains(where: { $0 == (2, 1) }) { chroma = "4:2:2" }
    else { chroma = "4:4:4" }
    return "\(entry.bitDepth)-bit \(chroma)" + (entry.packed ? " packed" : "")
  }
  static func rate(_ value: FrameRate) -> String {
    let duration = value.nominal
    let fps = 1 / CMTimeGetSeconds(duration)
    guard fps.isFinite, fps > 0 else { return "Unknown rate — check source timing" }
    let text: String
    if CMTimeCompare(duration, CMTime(value: 1001, timescale: 24000)) == 0 { text = "23.976" }
    else if CMTimeCompare(duration, CMTime(value: 1001, timescale: 30000)) == 0 { text = "29.97" }
    else if CMTimeCompare(duration, CMTime(value: 1001, timescale: 60000)) == 0 { text = "59.94" }
    else { text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), fps).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
    return value.isVariable ? "Variable (\(text) fps nominal)" : "\(text) fps"
  }
}
