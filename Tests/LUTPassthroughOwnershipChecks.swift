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

  func testIdleRetiresCaptureLeaseBeforeReleasedSlotFeedbackFinishesUnwinding() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 GPU required")
    }
    let processor = try LUTProcessor()
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    processor.afterSlotReleasedForTesting = {
      entered.signal()
      _ = resume.wait(timeout: .now() + 5)
    }
    defer { resume.signal() }
    weak var lease: SDKLease?
    let output: CVPixelBuffer = try autoreleasepool {
      var made: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
        &made), kCVReturnSuccess)
      let input = try XCTUnwrap(made), owner = SDKLease()
      lease = owner
      let captured = CapturedPixelBuffer(immutable: input, retaining: owner)
      return try processor.passthrough(captured.value)
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    processor.releaseIdleResources()
    XCTAssertNil(lease, "Idle must retire SDK leases before exposing the GPU slot, even if feedback unwinding is delayed")
    XCTAssertEqual(CVPixelBufferGetWidth(output), 64, "Published independent output stays valid")
  }


  func testInputLeaseRemainsValidUntilConsumerCallbackReturns() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 GPU required")
    }
    let processor = try LUTProcessor()
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    defer { resume.signal() }
    weak var lease: SDKLease?
    try autoreleasepool {
      var made: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
        &made), kCVReturnSuccess)
      let input = try XCTUnwrap(made), owner = SDKLease()
      lease = owner
      let captured = CapturedPixelBuffer(immutable: input, retaining: owner)
      try processor.submitPassthrough(captured.value) { _ in
        entered.signal()
        _ = resume.wait(timeout: .now() + 5)
        done.signal()
      }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    XCTAssertNotNil(lease, "The input lease must survive while a GPU consumer callback is still using the frame")
    XCTAssertFalse(processor.waitUntilIdle(timeout: 0.01))
    XCTAssertNotNil(lease)
    resume.signal()
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(processor.waitUntilIdle(timeout: 5))
    processor.releaseIdleResources()
    XCTAssertNil(lease)
  }

}
#endif
