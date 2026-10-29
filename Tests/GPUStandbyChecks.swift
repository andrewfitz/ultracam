#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Metal
import XCTest
import Synchronization

@objcMembers final class GPUStandbyChecks: XCTestCase {
  func testEveryPublishedFormatHasExactBlackIncludingRowPadding() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 hardware required; CPU standby is not a permitted fallback")
    }
    let producer = try GPUStandbyProducer(device: device)
    let formats = Set(ColorTarget.allCases.map(\.pixelFormat) + VideoContract.tenBit422)
    for format in formats {
      // Partial v210 groups and padded rows exercise the packed word phase.
      let width = format == kCVPixelFormatType_422YpCbCr10 ? 50 : 66
      let description = try VideoContract.formatDescription(width: width, height: 18, pixelFormat: format)
      let ready = expectation(description: VideoContract.fourCC(format))
      let output = Mutex<Result<GPUStandbyImage, Error>?>(nil)
      try producer.makeBlack(format: description) { result in output.withLock { $0 = result }; ready.fulfill() }
      wait(for: [ready], timeout: 10)
      let buffer = try XCTUnwrap(output.withLock { $0 }).get().pixelBuffer
      try VideoBufferLayout.validate(buffer)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), format)
      XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
      XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let packed = format == kCVPixelFormatType_422YpCbCr10
      let eight = ColorTarget.allCases.contains { $0.pixelFormat == format && $0.isEightBit }
      for plane in 0..<(packed ? 1 : 2) {
        let stride = packed ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let rows = packed ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, plane)
        let base = try XCTUnwrap(packed ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        let values: [UInt32] = [512 | (64 << 10) | (512 << 20), 64 | (512 << 10) | (64 << 20)]
        for row in 0..<rows {
          let p = base.advanced(by: row * stride)
          if packed {
            for x in 0..<stride / 4 { XCTAssertEqual(p.load(fromByteOffset: x * 4, as: UInt32.self), values[x % 2]) }
          } else if eight {
            for x in 0..<stride { XCTAssertEqual(p.load(fromByteOffset: x, as: UInt8.self), plane == 0 ? 16 : 128) }
          } else {
            let expected: UInt16 = plane == 1 ? 512 << 6 : (format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? 0 : 64 << 6)
            for x in 0..<stride / 2 { XCTAssertEqual(p.load(fromByteOffset: x * 2, as: UInt16.self), expected) }
          }
        }
      }
    }
  }
  func testSubmissionRetainsProducerAndBufferUntilCompletionAndCopiesPublishedTags() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 hardware required")
    }
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 1280, height: 720,
      extensions: [kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
        kCMFormatDescriptionExtension_TransferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020] as CFDictionary,
      formatDescriptionOut: &format), noErr)
    let done = expectation(description: "completion after submitter releases producer")
    let retained = Mutex<Result<GPUStandbyImage, Error>?>(nil)
    var producer: GPUStandbyProducer? = try GPUStandbyProducer(device: device)
    try producer!.makeBlack(format: XCTUnwrap(format)) { result in
      retained.withLock { $0 = result }
      done.fulfill()
    }
    producer = nil
    wait(for: [done], timeout: 10)
    let buffer = try XCTUnwrap(retained.withLock { $0 }).get().pixelBuffer
    try VideoBufferLayout.validate(buffer)
    for (key, expected) in [
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)] {
      XCTAssertEqual(CVBufferCopyAttachment(buffer, key, nil) as? String, expected as String)
    }
  }

}

#endif
