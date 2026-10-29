import CoreMedia
import CoreVideo
import Foundation

/// Immutable camera-extension output formats. The first entries mirror the
/// shipped extension order; all later entries are append-only colour variants.
enum OutputFormatCatalog {
  static let published = ExtensionFormatCatalog.published

  static func descriptions() throws -> [CMVideoFormatDescription] {
    try published.map { entry in
      let original = try VideoContract.formatDescription(width: entry.width, height: entry.height,
        pixelFormat: entry.pixel.rawValue)
      var extensions = CMFormatDescriptionGetExtensions(original) as! [String: Any]
      if entry.colour.primaries == .rec2020 {
        extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCVImageBufferColorPrimaries_ITU_R_2020
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCVImageBufferYCbCrMatrix_ITU_R_2020
        extensions[kCMFormatDescriptionExtension_TransferFunction as String] = entry.colour.transfer == .pq
          ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG
      }
      if entry.colour.horizontalChromaSiting == .center && entry.colour.verticalChromaSiting == .center {
        extensions[kCMFormatDescriptionExtension_ChromaLocationTopField as String] = kCVImageBufferChromaLocation_Center
      }
      var result: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
        codecType: entry.pixel.rawValue, width: Int32(entry.width), height: Int32(entry.height),
        extensions: extensions as CFDictionary, formatDescriptionOut: &result)
      guard status == noErr, let result else { throw VideoError.message("Cannot create published output format (\(status)).") }
      return result
    }
  }

  /// Require complete metadata identity and the image's matching attachments.
  /// Missing/unknown colour tags never acquire an implicit Rec.709 meaning.
  static func matches(_ sample: CMSampleBuffer, description: CMVideoFormatDescription) -> Bool {
    guard let actual = CMSampleBufferGetFormatDescription(sample),
      let image = CMSampleBufferGetImageBuffer(sample),
      DerivedOutputContract.matchesLayout(actual, description),
      CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: image) else { return false }
    return DerivedOutputContract.matchesFormat(actual, description)
  }

  static func matchingIndex(_ requested: ExtensionFormatContract,
                            duration: CMTime,
                            installed: [ExtensionFormatContract] = published) -> Int? {
    guard requested.allows(duration: duration), let index = installed.firstIndex(of: requested),
      published.contains(requested) else { return nil }
    return index
  }

  static func validateAppendOnly(previous: [ExtensionFormatContract],
                                 proposed: [ExtensionFormatContract]) -> Bool {
    proposed.count >= previous.count && Array(proposed.prefix(previous.count)) == previous &&
      Set(proposed.map(\.id)).count == proposed.count
  }
}
