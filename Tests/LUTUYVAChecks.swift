import CoreVideo
import XCTest

@objcMembers final class LUTUYVAChecks: XCTestCase {
  func testNativeUYVAExecutesNonlinearLUTAndResizeIgnoringValidatedAlpha() throws {
    let input = try source()
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(input), 0x55595641)
    XCTAssertEqual(CVPixelBufferGetPlaneCount(input), 2)
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })))
    for resize in [false, true] {
      let output = try processor.process(input, configuration: PipelineConfiguration(applyLUT: true, downscale: resize))
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
      let row = CVPixelBufferGetHeight(output) / 2
      let width = CVPixelBufferGetWidth(output)
      XCTAssertEqual(Int(p[row * stride + width / 4]), 71, accuracy: 1, "Zero alpha must not suppress the v1 image")
      XCTAssertEqual(Int(p[row * stride + width * 3 / 4]), 71, accuracy: 1, "Opaque alpha must have identical image processing")
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(input), 0x55595641)
    }
  }

  func testUYVARequiresFullAlphaPlaneAndAggregateStorage() throws {
    let input = try source()
    let planes = (0..<2).map { VideoBufferLayout.Plane(width: CVPixelBufferGetWidthOfPlane(input, $0),
      height: CVPixelBufferGetHeightOfPlane(input, $0), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(input, $0)) }
    var metadata = VideoBufferLayout.Metadata(width: 128, height: 64, pixelFormat: 0x55595641,
      isPlanar: true, rowBytes: 0, dataSize: CVPixelBufferGetDataSize(input), planes: planes)
    XCTAssertEqual(metadata.planes[0].width, metadata.width, "Core Video physical width differs from packed Metal texel width")
    XCTAssertNoThrow(try VideoBufferLayout.validate(metadata))
    metadata.planes[1].height = 63
    XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
    metadata.planes = planes; metadata.planes[1].rowBytes = 127
    XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
    metadata.planes = planes
    metadata.dataSize = planes.reduce(0) { $0 + $1.height * $1.rowBytes } - 1
    XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
  }

  func testMalformedNativeAlphaIsRefusedByProductionLUTBeforeGPU() throws {
    _ = try source() // Ensure the real custom format registration exists.
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 256 * 64 + 128 * 64, alignment: 64)
    var addresses: [UnsafeMutableRawPointer?] = [storage, storage.advanced(by: 256 * 64)]
    var widths = [128, 128], heights = [64, 63], strides = [256, 128]
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreateWithPlanarBytes(nil, 128, 64, 0x55595641, nil, 0, 2,
      &addresses, &widths, &heights, &strides, { context, _, _, _, _ in context?.deallocate() },
      storage, nil, &created)
    guard status == kCVReturnSuccess, let input = created else {
      storage.deallocate(); XCTFail("Cannot construct malformed alpha fixture: \(status)"); return
    }
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(input), 0x55595641)
    XCTAssertEqual(CVPixelBufferGetHeightOfPlane(input, 1), 63)
    let processor = try LUTProcessor()
    XCTAssertThrowsError(try processor.process(input, configuration: PipelineConfiguration(applyLUT: false, downscale: false)))
  }

  private func source() throws -> CVPixelBuffer {
    let type: OSType = 0x55595641
    // Match the B7 native Core Video registration exactly. The color plane
    // retains image pixel width; an RGBA8 Metal texel represents two pixels.
    if CVPixelFormatDescriptionCreateWithPixelFormatType(nil, type) == nil {
      var description = try XCTUnwrap(CVPixelFormatDescriptionCreateWithPixelFormatType(nil, kCVPixelFormatType_422YpCbCr8)) as! [String: Any]
      description[kCVPixelFormatConstant as String] = type
      description[kCVPixelFormatPlanes as String] = [
        [kCVPixelFormatBitsPerBlock as String: 32, kCVPixelFormatBlockWidth as String: 2,
         kCVPixelFormatHorizontalSubsampling as String: 1, kCVPixelFormatVerticalSubsampling as String: 1,
         kCVPixelFormatBlackBlock as String: Data([128, 16, 128, 16])],
        [kCVPixelFormatBitsPerBlock as String: 8, kCVPixelFormatBlackBlock as String: Data([255])]]
      for key in [kCVPixelFormatBitsPerBlock, kCVPixelFormatBlockWidth, kCVPixelFormatHorizontalSubsampling,
        kCVPixelFormatVerticalSubsampling, kCVPixelFormatBlackBlock] { description.removeValue(forKey: key as String) }
      description[kCVPixelFormatContainsAlpha as String] = true
      CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(description as CFDictionary, type)
    }
    var created: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created), kCVReturnSuccess)
    let image = try XCTUnwrap(created)
    CVPixelBufferLockBaseAddress(image, [])
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    let color = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)
    let alpha = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 1)).assumingMemoryBound(to: UInt8.self)
    let colorStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0), alphaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
    for row in 0..<64 {
      for byte in 0..<colorStride { color[row * colorStride + byte] = 0xee }
      for x in 0..<128 { color[row * colorStride + x * 2] = 128; color[row * colorStride + x * 2 + 1] = 126 }
      for x in 0..<alphaStride { alpha[row * alphaStride + x] = x < 64 ? 0 : 255 }
    }
    return image
  }
}
