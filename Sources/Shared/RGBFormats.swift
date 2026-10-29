import Foundation

/// Packed RGB layouts accepted by the shared capture contract.
enum RGBFormat: String, Codable, Sendable, CaseIterable {
  case bgra8
  case rgba8
  case r210
  case r12l

  var bitsPerComponent: Int { self == .r12l ? 12 : (self == .r210 ? 10 : 8) }
  // R12L has fractional bytes per pixel; use minimumRowBytes for storage.
  var bytesPerPixel: Int? { self == .r12l ? nil : 4 }
  var hasAlpha: Bool { self == .bgra8 || self == .rgba8 }
  var channelOrder: [RGBChannel] {
    switch self { case .bgra8: [.blue, .green, .red, .alpha]; case .rgba8: [.red, .green, .blue, .alpha]; case .r210, .r12l: [.red, .green, .blue] }
  }
}

enum RGBChannel: String, Codable, Sendable { case red, green, blue, alpha }
enum RGBAlphaMode: String, Codable, Sendable { case straight, premultiplied, opaque }

struct RGBFormatMetadata: Hashable, Codable, Sendable {
  let format: RGBFormat
  let color: Colorimetry
  let alpha: RGBAlphaMode
  init(format: RGBFormat, color: Colorimetry = .rec709Video,
              alpha: RGBAlphaMode? = nil) throws {
    if format.hasAlpha {
      self.alpha = alpha ?? .straight
    } else {
      guard alpha == nil || alpha == .opaque else { throw SourceFormatError.invalid("Packed RGB cannot carry alpha") }
      self.alpha = .opaque
    }
    self.format = format; self.color = color
  }
}

enum RGBFormatValidator {
  /// Validates a packed row against the declared dimensions and format.
  static func validate(_ bytes: Data, width: Int, height: Int,
                              bytesPerRow: Int, metadata: RGBFormatMetadata) throws {
    guard width > 0, height > 0 else { throw SourceFormatError.invalid("Invalid RGB dimensions") }
    let minimumRow = try metadata.format.minimumRowBytes(width: width)
    guard bytesPerRow >= minimumRow else { throw SourceFormatError.invalid("RGB row is too short") }
    let (storage, storageOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    guard !storageOverflow else { throw SourceFormatError.invalid("RGB storage size overflow") }
    guard bytes.count >= storage else { throw SourceFormatError.invalid("RGB storage is too short") }
  }

  static func packRGBA8(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255,
                               format: RGBFormat = .rgba8) throws -> [UInt8] {
    switch format {
    case .rgba8: return [red, green, blue, alpha]
    case .bgra8: return [blue, green, red, alpha]
    case .r210, .r12l: throw SourceFormatError.invalid("RGBA8 packing requires an 8-bit RGB format")
    }
  }

  /// SDK R12L: contiguous little-endian 12-bit components, with no 16-bit padding.
  static func packR12L(red: UInt16, green: UInt16, blue: UInt16) -> [UInt8] {
    let value = UInt64(red & 4095) | (UInt64(green & 4095) << 12) | (UInt64(blue & 4095) << 24)
    return (0..<5).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }
  static func unpackR12L(_ bytes: ArraySlice<UInt8>) throws -> (red: UInt16, green: UInt16, blue: UInt16) {
    guard bytes.count >= 5 else { throw SourceFormatError.invalid("R12L group is truncated") }
    let value = bytes.prefix(5).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
    return (UInt16(value & 4095), UInt16((value >> 12) & 4095), UInt16((value >> 24) & 4095))
  }
}

extension RGBFormat {
  func minimumRowBytes(width: Int) throws -> Int {
    guard width > 0 else { throw SourceFormatError.invalid("Invalid RGB width") }
    let (bits, overflow) = width.multipliedReportingOverflow(by: self == .r12l ? 36 : 32)
    guard !overflow else { throw SourceFormatError.invalid("RGB row size overflow") }
    return bits / 8 + (bits % 8 == 0 ? 0 : 1)
  }
}
