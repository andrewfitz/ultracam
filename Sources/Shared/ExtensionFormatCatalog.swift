import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

enum ExtensionFormatCatalogError: Error, Equatable {
  case invalidContract(String)
  case unsupportedLocalContract
  case unavailableInstalledContract
  case unsupportedDuration
  case changedPublishedIndex
}

/// Immutable output identity. This deliberately does not use SourceFormat:
/// extension outputs include existing pixel layouts not yet admitted as inputs,
/// have a finite set of allowed cadences, and have no source-clock identity.
struct ExtensionFormatContract: Hashable, Codable, Sendable, Identifiable {
  let width: Int
  let height: Int
  let pixelAspect: Rational
  let scan: Scan
  let pixel: PixelFormatID
  let colour: Colorimetry
  let allowedDurations: [Rational]

  init(width: Int, height: Int, pixelAspect: Rational = .one, pixel: PixelFormatID,
       scan: Scan = .progressive, colour: Colorimetry, allowedDurations: [Rational]) throws {
    guard width > 0, height > 0, width <= Int32.max, height <= Int32.max,
      pixelAspect.numerator > 0, !allowedDurations.isEmpty,
      allowedDurations.allSatisfy({ $0.numerator > 0 && $0.denominator <= Int32.max }) else {
      throw ExtensionFormatCatalogError.invalidContract("Invalid dimensions, aspect or cadence")
    }
    guard colour.primaries != .unspecified, colour.transfer != .unspecified, colour.matrix != .unspecified else {
      throw ExtensionFormatCatalogError.invalidContract("Output colour must be explicit")
    }
    self.width = width; self.height = height; self.pixelAspect = pixelAspect
    self.scan = scan; self.pixel = pixel; self.colour = colour
    self.allowedDurations = Set(allowedDurations).sorted {
      CMTimeCompare(CMTime(value: $0.numerator, timescale: Int32($0.denominator)),
        CMTime(value: $1.numerator, timescale: Int32($1.denominator))) < 0
    }
  }

  /// Versioned sorted JSON with normalized rational values, never Swift Hasher.
  var id: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try! encoder.encode(self)
    return "extension-format-v1:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  func allows(duration: CMTime) -> Bool {
    guard duration.isNumeric, duration.epoch == 0, duration.timescale > 0,
      let normalized = try? Rational(duration.value, Int64(duration.timescale)) else { return false }
    return allowedDurations.contains(normalized)
  }
  private enum CodingKeys: String, CodingKey { case width, height, pixelAspect, scan, pixel, colour, allowedDurations }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height),
      pixelAspect: c.decode(Rational.self, forKey: .pixelAspect), pixel: c.decode(PixelFormatID.self, forKey: .pixel),
      scan: c.decode(Scan.self, forKey: .scan), colour: c.decode(Colorimetry.self, forKey: .colour),
      allowedDurations: c.decode([Rational].self, forKey: .allowedDurations))
  }
}

enum ExtensionFormatCatalog {
  private static let durations: [Rational] = FrameRateTarget.allCases.map {
    try! Rational($0.duration.value, Int64($0.duration.timescale))
  }

  /// The shipped eighteen entries, retained verbatim as the immutable prefix.
  static let legacyPublished: [ExtensionFormatContract] = {
    let legacy: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10]
    let added: [OSType] = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange]
    return [(1920,1080,legacy), (3840,2160,legacy), (1920,1080,added),
      (3840,2160,added), (1280,720,legacy + added)].flatMap { width, height, pixels in
      pixels.map { pixel in
        // Existing descriptions do not declare chroma location. Preserve that
        // fact instead of inventing siting for the installed legacy entries.
        let colour = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709,
          range: pixel == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? .full : .video,
          horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified)
        return try! ExtensionFormatContract(width: width, height: height, pixel: PixelFormatID(rawValue: pixel),
          colour: colour, allowedDurations: durations)
      }
    }
  }()

  /// Built once per process. Preserve the shipped eighteen entries verbatim.
  /// Range always follows the native FourCC: standby fills native black levels.
  static let published: [ExtensionFormatContract] = {
    let dci = legacyPublished.prefix(4).map { entry in
      try! ExtensionFormatContract(width: 4096, height: 2160, pixel: entry.pixel,
        colour: entry.colour, allowedDurations: entry.allowedDurations)
    } + legacyPublished[8..<10].map { entry in
      try! ExtensionFormatContract(width: 4096, height: 2160, pixel: entry.pixel,
        colour: entry.colour, allowedDurations: entry.allowedDurations)
    }
    let sdr = legacyPublished + dci
    let unsited = sdr + [Colorimetry.Transfer.pq, .hlg].flatMap { transfer in
      sdr.map { entry in
        let colour = Colorimetry(primaries: .rec2020, transfer: transfer, matrix: .rec2020,
          range: entry.colour.range, horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified)
        return try! ExtensionFormatContract(width: entry.width, height: entry.height,
          pixel: entry.pixel, colour: colour, allowedDurations: entry.allowedDurations)
      }
    }
    // GPU resampling produces centered chroma. Preserve the original nil-siting
    // contracts while giving accurately tagged processed frames distinct modes.
    return unsited + unsited.map { entry in
      try! ExtensionFormatContract(width: entry.width, height: entry.height, pixel: entry.pixel,
        colour: Colorimetry(primaries: entry.colour.primaries, transfer: entry.colour.transfer,
          matrix: entry.colour.matrix, range: entry.colour.range,
          horizontalChromaSiting: .center, verticalChromaSiting: .center),
        allowedDurations: entry.allowedDurations)
    }
  }()

  static let candidates = published.filter { $0.colour.transfer == .pq }

  static func validateAppendOnly(previous: [ExtensionFormatContract], proposed: [ExtensionFormatContract]) throws {
    guard proposed.count >= previous.count, Array(proposed.prefix(previous.count)) == previous,
      Set(proposed.map(\.id)).count == proposed.count else { throw ExtensionFormatCatalogError.changedPublishedIndex }
  }

  /// `installed` must be read from the actual extension. A local catalog is
  /// never evidence that a newer entry is installed. No metadata rewrite or
  /// implicit colour conversion is performed; the delivered contract must match.
  static func negotiate(requested: ExtensionFormatContract, duration: CMTime,
                        installed: [ExtensionFormatContract]) throws -> Int {
    guard published.contains(requested) else { throw ExtensionFormatCatalogError.unsupportedLocalContract }
    guard let index = installed.firstIndex(of: requested) else { throw ExtensionFormatCatalogError.unavailableInstalledContract }
    guard requested.allows(duration: duration) else { throw ExtensionFormatCatalogError.unsupportedDuration }
    return index
  }
}
