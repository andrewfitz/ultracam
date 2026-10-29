import CoreVideo
import XCTest

@objcMembers final class Packed422LUTChecks: XCTestCase {
  func testBothPackedOrdersRunProductionFullAndResizeKernels() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("Metal 4 required") }
    for type in [kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs] {
      var created: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 256, 128, type,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created), kCVReturnSuccess)
      let input = try XCTUnwrap(created)
      CVPixelBufferLockBaseAddress(input, [])
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(input)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(input)
      for y in 0..<128 { for x in 0..<stride { base[y * stride + x] = 255 } }
      for y in 0..<128 { for x in 0..<128 {
        let i = y * stride + x * 4
        if type == kCVPixelFormatType_422YpCbCr8 { base[i] = 96; base[i+1] = 126; base[i+2] = 160; base[i+3] = 180 }
        else { base[i] = 126; base[i+1] = 96; base[i+2] = 180; base[i+3] = 160 }
      } }
      CVPixelBufferUnlockBaseAddress(input, [])
      let processor = try LUTProcessor()
      for color in [ColorTarget.yuv4208, .yuv4228] {
      for resize in [false, true] {
        var configuration = PipelineConfiguration(applyLUT: false, downscale: resize)
        configuration.scalingMode = .crop
        configuration.colorTarget = color
        let output = try processor.process(input, configuration: configuration)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 1)).assumingMemoryBound(to: UInt8.self)
        let middle = CVPixelBufferGetHeight(output) / 2 * CVPixelBufferGetBytesPerRowOfPlane(output, 0) + CVPixelBufferGetWidth(output) / 2
        if resize { XCTAssertTrue((120...185).contains(Int(y[middle]))) }
        else {
          XCTAssertEqual(Int(y[middle]), 126, accuracy: 1)
          XCTAssertEqual(Int(y[middle + 1]), 180, accuracy: 1)
        }
        XCTAssertEqual(Int(uv[0]), 96, accuracy: 1)
        XCTAssertEqual(Int(uv[1]), 160, accuracy: 1)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
      }
      }
    }
  }
}
