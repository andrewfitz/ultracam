import CoreVideo
import XCTest

@objcMembers final class LUTNDIPlanarChecks: XCTestCase {
  func testCustomI420AndPA16ExecuteNonlinearLUTAtNativeAndResizedDimensions() throws {
    for type: OSType in [0x49343230, 0x50413136] {
      let source = try fixture(type)
      let processor = try LUTProcessor()
      try processor.load(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })))
      for resize in [false, true] {
        var configuration = PipelineConfiguration(applyLUT: true, downscale: resize)
        configuration.resizeTarget = .hd720
        let output = try processor.process(source, configuration: configuration)
        XCTAssertEqual(CVPixelBufferGetWidth(output), resize ? 1280 : 128)
        XCTAssertEqual(CVPixelBufferGetHeight(output), resize ? 720 : 64)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(source), type, "Custom source must retain its actual format identity")
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(output), height = CVPixelBufferGetHeight(output)
        XCTAssertEqual(Int(base[height / 2 * CVPixelBufferGetBytesPerRowOfPlane(output, 0) + width / 2]), 71, accuracy: 1)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
      }
      if type == 0x50413136 {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        let alpha = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 2)).assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 2) / 2
        for row in 0..<64 { for x in 0..<128 { XCTAssertEqual(alpha[row * stride + x], x.isMultiple(of: 2) ? 0 : 65535) } }
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
      }
    }
  }

  func testPA16RequiresTheCompleteFullResolutionAlphaAllocation() throws {
    let planes = [VideoBufferLayout.Plane(width: 128, height: 64, rowBytes: 256),
      VideoBufferLayout.Plane(width: 64, height: 64, rowBytes: 256),
      VideoBufferLayout.Plane(width: 128, height: 64, rowBytes: 256)]
    var metadata = VideoBufferLayout.Metadata(width: 128, height: 64, pixelFormat: 0x50413136,
      isPlanar: true, rowBytes: 0, dataSize: 3 * 256 * 64, planes: planes)
    XCTAssertNoThrow(try VideoBufferLayout.validate(metadata))
    metadata.planes[2].width = 64
    XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
    metadata.planes = planes; metadata.planes[2].rowBytes = 254
    XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
    metadata.planes = planes; metadata.dataSize -= 1
    XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
    metadata.planes.removeLast()
    XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
  }

  private func fixture(_ type: OSType) throws -> CVPixelBuffer {
    try CPUMemoryPixelFormatRegistration.ensure(type)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary, &image), kCVReturnSuccess)
    let source = try XCTUnwrap(image)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(source), type)
    XCTAssertEqual(CVPixelBufferGetPlaneCount(source), 3)
    try VideoBufferLayout.validate(source)
    CVPixelBufferLockBaseAddress(source, []); defer { CVPixelBufferUnlockBaseAddress(source, []) }
    for plane in 0..<3 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane), rows = CVPixelBufferGetHeightOfPlane(source, plane)
      memset(base, 0xA5, stride * rows)
      if type == 0x49343230 {
        for row in 0..<rows { for x in 0..<CVPixelBufferGetWidthOfPlane(source, plane) {
          base.storeBytes(of: UInt8(plane == 0 ? 126 : 128), toByteOffset: row * stride + x, as: UInt8.self)
        } }
      } else {
        let p = base.assumingMemoryBound(to: UInt16.self), components = plane == 1 ? 2 : 1
        for row in 0..<rows { for x in 0..<(CVPixelBufferGetWidthOfPlane(source, plane) * components) {
          p[row * stride / 2 + x] = plane == 0 ? 32128 : (plane == 1 ? 32768 : (x.isMultiple(of: 2) ? 0 : 65535))
        } }
      }
    }
    return source
  }
}
