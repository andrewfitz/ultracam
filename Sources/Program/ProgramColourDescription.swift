import CoreMedia
import CoreVideo
import Foundation

extension ProgramOutputFormat {
  func matchesColourAndAspect(_ image: CVPixelBuffer) -> Bool {
    guard [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
      kCVImageBufferYCbCrMatrixKey].allSatisfy({ CVBufferCopyAttachment(image, $0, nil) != nil }),
      let actual = try? LUTProcessor.sourceColorimetry(image),
      actual.primaries == colour.primaries, actual.transfer == colour.transfer,
      actual.matrix == colour.matrix, actual.range == colour.range,
      actual.horizontalChromaSiting == .center, actual.verticalChromaSiting == .center else { return false }
    if let aspect = CVBufferCopyAttachment(image, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any] {
      let h = (aspect[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber)?.int64Value ?? 1
      let v = (aspect[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber)?.int64Value ?? 1
      return h == v && h > 0
    }
    return true
  }

  func stampColour(on image: CVPixelBuffer) throws {
    _ = try formatDescription() // Validate the exact published target before stamping.
    LUTProcessor.stampDeclaredColorimetry(colour, on: image)
  }

  /// Describes the GPU's declared target; never infer this from the arriving frame.
  func formatDescription() throws -> CMVideoFormatDescription {
    let base = try VideoContract.formatDescription(width: width, height: height, pixelFormat: pixelFormat)
    var extensions = CMFormatDescriptionGetExtensions(base) as? [String: Any] ?? [:]
    let primaries: CFString
    switch colour.primaries {
    case .rec709: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
    case .rec2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
    default: throw VideoError.message("Unsupported Program colour primaries.")
    }
    let transfer: CFString
    switch colour.transfer {
    case .rec709: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
    case .pq: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    case .hlg: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
    default: throw VideoError.message("Unsupported Program transfer function.")
    }
    let matrix: CFString
    switch colour.matrix {
    case .rec709: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case .rec2020: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
    default: throw VideoError.message("Unsupported Program matrix.")
    }
    guard colour.range == .video else { throw VideoError.message("Program target requires video range.") }
    extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries
    extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer
    extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = matrix
    extensions[kCMFormatDescriptionExtension_ChromaLocationTopField as String] = kCVImageBufferChromaLocation_Center
    var result: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: pixelFormat,
      width: Int32(width), height: Int32(height), extensions: extensions as CFDictionary,
      formatDescriptionOut: &result)
    guard status == noErr, let result else { throw VideoError.message("Cannot describe Program colour target.") }
    return result
  }
}
