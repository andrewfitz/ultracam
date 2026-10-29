import CoreVideo
import Foundation

extension CPUCompatibilityConverter {
  /// Explicit CPU-memory ingest fallback. This never relaxes malformed layout
  /// or allocation bounds and never substitutes for Metal 4 availability.
  /// `onCopied` is the session owner's per-camera ingest-stage counter hook.
  func copyIngest(_ frame: CapturedCPUMemoryFrame, metal4Available: Bool,
                  onCopied: () -> Void = {}) throws -> CapturedPixelBuffer {
    _ = try frame.validatedCPUReadableLength()
    guard metal4Available else {
      throw SourceRecordingError.unsupportedSample("Capture ingest requires Metal 4, including CPU compatibility mode.")
    }
    guard policy.allowCPUConversion else {
      throw SourceRecordingError.unsupportedSample("Capture ingest cannot safely wrap this allocation. Enable Allow CPU conversion (compatibility) for the next session to permit a counted CPU copy.")
    }
    let layouts = try frame.validatedPlaneLayouts()
    try CPUMemoryPixelFormatRegistration.ensure(frame.pixelFormat)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, frame.width, frame.height, frame.pixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      throw SourceRecordingError.unsupportedSample("Cannot allocate native-format CPU ingest IOSurface (\(status)).")
    }
    let planar = layouts.count > 1
    guard CVPixelBufferGetPlaneCount(buffer) == (planar ? layouts.count : 0) else { throw NoCopyIngestError.invalidLength }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
      throw SourceRecordingError.unsupportedSample("Cannot map CPU ingest IOSurface.")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    try withExtendedLifetime(frame) {
      for (index, layout) in layouts.enumerated() {
        let source = frame.planes[index]
        let destinationStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
        let destination = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
        guard let destination, destinationStride >= layout.minimumRowBytes else { throw NoCopyIngestError.invalidLength }
        if planar {
          let expectedWidth = frame.pixelFormat == 0x55595641 && index == 0 ? frame.width : layout.width
          guard CVPixelBufferGetWidthOfPlane(buffer, index) == expectedWidth,
            CVPixelBufferGetHeightOfPlane(buffer, index) == layout.height else { throw NoCopyIngestError.invalidLength }
        }
        for row in 0..<layout.height {
          destination.advanced(by: row * destinationStride).copyMemory(
            from: frame.pointer.advanced(by: source.offset + row * source.bytesPerRow), byteCount: layout.minimumRowBytes)
        }
      }
    }
    onCopied()
    return CapturedPixelBuffer(immutable: buffer)
  }
}
