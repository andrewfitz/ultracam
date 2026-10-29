import CoreVideo
import Foundation

/// Process-wide Core Video registration is serialized and only fills missing
/// descriptions. An existing incompatible physical layout is an explicit error.
enum CPUMemoryPixelFormatRegistration {
  private static let lock = NSLock()

  /// Match Apple's packed physical block definitions when a platform lacks a
  /// native description. R12L packs eight pixels into a 288-bit row block;
  /// its IOSurface is exposed as eight-byte integer texels, preserving odd tails.
  static func packedRGBDescription(_ type: OSType) -> [String: Any]? {
    guard type == 0x72323130 || type == 0x5231324c else { return nil }
    var result: [String: Any] = [
      kCVPixelFormatConstant as String: type,
      kCVPixelFormatBitsPerBlock as String: type == 0x72323130 ? 32 : 288,
      kCVPixelFormatBitsPerComponent as String: type == 0x72323130 ? 10 : 12,
      kCVPixelFormatContainsRGB as String: true,
      kCVPixelFormatContainsYCbCr as String: false,
      kCVPixelFormatContainsGrayscale as String: false,
      kCVPixelFormatContainsAlpha as String: false,
      kCVPixelFormatComponentRange as String: type == 0x72323130 ? kCVPixelFormatComponentRange_VideoRange : kCVPixelFormatComponentRange_FullRange]
    if type == 0x5231324c { result[kCVPixelFormatBlockWidth as String] = 8 }
    return result
  }

  static func ensure(_ type: OSType) throws {
    try lock.withLock {
      if let expected = packedRGBDescription(type) {
        if let existing = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, type) as? [String: Any] {
          for key in [kCVPixelFormatBitsPerBlock, kCVPixelFormatBitsPerComponent, kCVPixelFormatContainsRGB, kCVPixelFormatContainsAlpha] {
            guard NSDictionary(dictionary: ["v": existing[key as String] ?? NSNull()]) ==
              NSDictionary(dictionary: ["v": expected[key as String] ?? NSNull()]) else { throw NoCopyIngestError.unsupportedPixelFormat }
          }
          let block = (existing[kCVPixelFormatBlockWidth as String] as? NSNumber)?.intValue ?? 1
          let expectedBlock = (expected[kCVPixelFormatBlockWidth as String] as? NSNumber)?.intValue ?? 1
          guard block == expectedBlock, existing[kCVPixelFormatPlanes as String] == nil else { throw NoCopyIngestError.unsupportedPixelFormat }
        } else { CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(expected as CFDictionary, type) }
        return
      }
      let baseType: OSType
      switch type {
      case 0x49343230: baseType = kCVPixelFormatType_420YpCbCr8Planar
      case 0x50323136, 0x50413136: baseType = kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
      case 0x55595641: baseType = kCVPixelFormatType_422YpCbCr8
      default: return
      }
      guard let base = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, baseType) as? [String: Any] else { throw NoCopyIngestError.unsupportedPixelFormat }
      var expected = base
      expected[kCVPixelFormatConstant as String] = type
      if type == 0x50413136 {
        var planes = base[kCVPixelFormatPlanes as String] as! [[String: Any]]
        planes.append([kCVPixelFormatBitsPerBlock as String: 16,
          kCVPixelFormatBlackBlock as String: Data([255, 255])])
        expected[kCVPixelFormatPlanes as String] = planes
        expected[kCVPixelFormatContainsAlpha as String] = true
      } else if type == 0x55595641 {
        // UYVY packed pairs followed by a full-resolution byte alpha plane.
        expected[kCVPixelFormatPlanes as String] = [
          [kCVPixelFormatBitsPerBlock as String: 32, kCVPixelFormatBlockWidth as String: 2,
           kCVPixelFormatHorizontalSubsampling as String: 1, kCVPixelFormatVerticalSubsampling as String: 1,
           kCVPixelFormatBlackBlock as String: Data([128, 16, 128, 16])],
          [kCVPixelFormatBitsPerBlock as String: 8, kCVPixelFormatBlackBlock as String: Data([255])]]
        for key in [kCVPixelFormatBitsPerBlock, kCVPixelFormatBlockWidth,
          kCVPixelFormatHorizontalSubsampling, kCVPixelFormatVerticalSubsampling, kCVPixelFormatBlackBlock] {
          expected.removeValue(forKey: key as String)
        }
        expected[kCVPixelFormatContainsAlpha as String] = true
      }
      if let existing = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, type) as? [String: Any] {
        // Compatibility is structural: ignore optional platform rendering hints.
        for key in [kCVPixelFormatBitsPerComponent, kCVPixelFormatContainsAlpha, kCVPixelFormatPlanes] {
          guard NSDictionary(dictionary: ["v": existing[key as String] ?? NSNull()]) ==
            NSDictionary(dictionary: ["v": expected[key as String] ?? NSNull()]) else {
            throw NoCopyIngestError.unsupportedPixelFormat
          }
        }
        return
      }
      CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(expected as CFDictionary, type)
    }
  }
}
