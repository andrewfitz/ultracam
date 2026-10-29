#if ULTRACAM_TEST_SUPPORT
import CoreVideo
import Foundation
import Metal
import XCTest

@objcMembers final class LUTPassthroughOwnershipChecks: XCTestCase {
  private final class SDKLease: NSObject {}

  func testIndependentPassthroughReleasesCaptureLeaseAndPreservesPixelsAndColor() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 GPU required")
    }
    let processor = try LUTProcessor()
    weak var lease: SDKLease?
    let output: CVPixelBuffer = try autoreleasepool {
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
        &buffer), kCVReturnSuccess)
      let input = try XCTUnwrap(buffer)
      let owner = SDKLease()
      lease = owner
      let captured = CapturedPixelBuffer(immutable: input, retaining: owner)
      XCTAssertEqual(CVPixelBufferLockBaseAddress(input, []), kCVReturnSuccess)
      for plane in 0..<2 {
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, plane))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(input, plane)
        for row in 0..<32 {
          for x in 0..<64 {
            base.storeBytes(of: UInt16(plane == 0 ? 80 << 6 : 512 << 6),
              toByteOffset: row * stride + x * 2, as: UInt16.self)
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(input, [])
      CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
      CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldNotPropagate)
      CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldNotPropagate)
      return try processor.passthrough(captured.value)
    }
    processor.releaseIdleResources()
    XCTAssertNil(lease, "Independent output must not retain the capture SDK storage lease")
    for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)] {
      XCTAssertEqual(CVBufferCopyAttachment(output, key, nil) as? String, value as String)
    }
    XCTAssertEqual(CVPixelBufferLockBaseAddress(output, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    for plane in 0..<2 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
      for row in 0..<32 { for x in 0..<64 {
        XCTAssertEqual(base.load(fromByteOffset: row * stride + x * 2, as: UInt16.self), UInt16(plane == 0 ? 80 << 6 : 512 << 6))
      } }
    }
  }
}
#endif
