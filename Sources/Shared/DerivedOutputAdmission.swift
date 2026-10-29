import CoreMedia
import CoreVideo
import Foundation

/// The negotiated *derived output*, independent of the capture-only input
/// table. Holds the immutable published description, including its colour
/// fields, without changing or retagging the producer's pixels.
///
/// Geometry, colour identity, image attachments and exact producer cadence
/// must agree with an actually installed immutable mode.
struct DerivedOutputContract {
  let format: CMVideoFormatDescription
  let duration: CMTime

  static func sameDuration(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
    lhs.isNumeric && rhs.isNumeric && lhs.epoch == 0 && rhs.epoch == 0 &&
      lhs.timescale > 0 && rhs.timescale > 0 && lhs.value > 0 && rhs.value > 0 && CMTimeCompare(lhs, rhs) == 0
  }

  /// Client property setters can encode a Double rate in nanosecond ticks.
  /// Accept only the exact rounding of a published duration at that declared
  /// precision; never apply this normalization to producer sample metadata.
  static func clientDuration(_ requested: CMTime, allowed: [CMTime]) -> CMTime? {
    guard requested.isNumeric, requested.epoch == 0, requested.timescale > 0, requested.value > 0 else { return nil }
    if let exact = allowed.first(where: { sameDuration(requested, $0) }) { return exact }
    guard requested.timescale >= 60_000 else { return nil }
    return allowed.first {
      let rounded = CMTimeConvertScale($0, timescale: requested.timescale, method: .roundHalfAwayFromZero)
      return sameDuration(requested, rounded)
    }
  }

  /// Geometry comparison is used only as the first part of complete identity.
  static func matchesLayout(_ requested: CMVideoFormatDescription, _ published: CMVideoFormatDescription) -> Bool {
    let lhs = CMVideoFormatDescriptionGetDimensions(requested), rhs = CMVideoFormatDescriptionGetDimensions(published)
    return lhs.width == rhs.width && lhs.height == rhs.height &&
      CMFormatDescriptionGetMediaSubType(requested) == CMFormatDescriptionGetMediaSubType(published)
  }

  static func matchesFormat(_ requested: CMVideoFormatDescription, _ published: CMVideoFormatDescription) -> Bool {
    guard matchesLayout(requested, published) else { return false }
    let keys = [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
      kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionExtension_FullRangeVideo,
      kCMFormatDescriptionExtension_PixelAspectRatio, kCMFormatDescriptionExtension_FieldCount,
      kCMFormatDescriptionExtension_FieldDetail, kCMFormatDescriptionExtension_ChromaLocationTopField,
      kCMFormatDescriptionExtension_ChromaLocationBottomField]
    // Required colour fields have no implicit compatibility fallback.
    for key in keys.prefix(3) {
      guard CMFormatDescriptionGetExtension(requested, extensionKey: key) != nil,
        CMFormatDescriptionGetExtension(published, extensionKey: key) != nil else { return false }
    }
    return keys.allSatisfy { key in
      let lhs = CMFormatDescriptionGetExtension(requested, extensionKey: key)
      let rhs = CMFormatDescriptionGetExtension(published, extensionKey: key)
      if key == kCMFormatDescriptionExtension_FullRangeVideo {
        // CoreMedia may omit range metadata. The exact native FourCC
        // defines its default; explicit contradictory tags remain distinct.
        if let lhs, !(lhs is Bool) { return false }
        if let rhs, !(rhs is Bool) { return false }
        let nativeFullRange = CMFormatDescriptionGetMediaSubType(requested) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        return (lhs as? Bool ?? nativeFullRange) == (rhs as? Bool ?? nativeFullRange)
      }
      switch (lhs, rhs) {
      case (nil, nil): return true
      case let (lhs?, rhs?): return CFEqual(lhs, rhs)
      default: return false
      }
    }
  }

  func matchingPublishedIndex(in descriptions: [CMVideoFormatDescription]) -> Int? {
    descriptions.firstIndex { Self.matchesFormat(format, $0) }
  }

  func mismatch(_ sample: CMSampleBuffer) -> String? {
    guard CMSampleBufferDataIsReady(sample) else { return "data not ready" }
    guard let image = CMSampleBufferGetImageBuffer(sample) else { return "no image buffer" }
    guard let description = CMSampleBufferGetFormatDescription(sample) else { return "no format description" }
    if !Self.matchesFormat(description, format) { return "sample colour, aspect, scan, size or pixel layout differs from the negotiated output" }
    guard CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: image) else { return "image attachments differ from its sample description" }
    return mismatch(image: image, time: CMSampleBufferGetPresentationTimeStamp(sample), duration: CMSampleBufferGetDuration(sample))
  }

  func mismatch(image: CVPixelBuffer, time: CMTime, duration actualDuration: CMTime) -> String? {
    let size = CMVideoFormatDescriptionGetDimensions(format)
    guard CVPixelBufferGetWidth(image) == Int(size.width), CVPixelBufferGetHeight(image) == Int(size.height) else {
      return "image dimensions: expected \(size.width)×\(size.height), got \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image))"
    }
    let type = CMFormatDescriptionGetMediaSubType(format)
    guard CVPixelBufferGetPixelFormatType(image) == type else { return "pixel layout differs from the negotiated output" }
    var actual: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &actual) == noErr,
      let actual, Self.matchesFormat(actual, format) else { return "image colour or aspect differs from the negotiated output" }
    do { try VideoBufferLayout.validate(image) }
    catch { return "invalid output buffer layout: \(error.localizedDescription)" }
    guard time.isNumeric, time.epoch == 0, time.timescale > 0, time.value >= 0 else { return "presentation time must be numeric, nonnegative and epoch zero" }
    guard Self.sameDuration(actualDuration, duration) else {
      return "frame duration: expected \(duration.value)/\(duration.timescale), got \(actualDuration.value)/\(actualDuration.timescale); renegotiate a published cadence before sending"
    }
    return nil
  }
}
