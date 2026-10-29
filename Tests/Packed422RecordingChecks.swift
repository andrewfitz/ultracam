import CoreVideo
import Metal
import XCTest

@objcMembers final class Packed422RecordingChecks: XCTestCase {
  func testNativePackedOrdersAndRawUYVARepackEveryEightBitCodeExactly() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let converter = try Packed422RecordingConverter(device: device)
    let width = 514, height = 2
    for format in [Packed422Format.twoVuy, .yuvs, .uyva] {
      let finished = expectation(description: format.rawValue)
      let completion: Packed422RecordingConverter.Completion = { result in
        do {
          let output = try result.get()
          XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), Packed422RecordingConverter.outputPixelFormat)
          CVPixelBufferLockBaseAddress(output, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
          let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt16.self)
          let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 1)).assumingMemoryBound(to: UInt16.self)
          let ys = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
          let cs = CVPixelBufferGetBytesPerRowOfPlane(output, 1) / 2
          for row in 0..<height { for pair in 0..<(width / 2) {
            XCTAssertEqual(y[row * ys + pair * 2], UInt16((pair * 2) % 256) << 8)
            XCTAssertEqual(y[row * ys + pair * 2 + 1], UInt16((pair * 2 + 1) % 256) << 8)
            XCTAssertEqual(uv[row * cs + pair * 2], UInt16(pair % 256) << 8)
            XCTAssertEqual(uv[row * cs + pair * 2 + 1], UInt16(255 - pair % 256) << 8)
          } }
          XCTAssertEqual(converter.retainedAllocationBytes, 0)
        } catch { XCTFail("\(error)") }
        finished.fulfill()
      }
      if format == .uyva {
        let stride = width * 2 + 30, alphaStride = width + 14
        var bytes = [UInt8](repeating: 0xee, count: (stride + alphaStride) * height)
        bytes.withUnsafeMutableBufferPointer { fill($0.baseAddress!, width: width, height: height, stride: stride, format: format) }
        let source = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count))
        try converter.convertUYVA(source, owner: source, width: width, height: height,
          rowBytes: stride, alphaRowBytes: alphaStride, completion: completion)
      } else {
        var created: CVPixelBuffer?
        let type = format == .twoVuy ? kCVPixelFormatType_422YpCbCr8 : kCVPixelFormatType_422YpCbCr8_yuvs
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, type,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created), kCVReturnSuccess)
        let input = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(input, [])
        let stride = CVPixelBufferGetBytesPerRow(input)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(input)).assumingMemoryBound(to: UInt8.self)
        for i in 0..<(stride * height) { base[i] = 0xee }
        fill(base, width: width, height: height, stride: stride, format: format)
        CVPixelBufferUnlockBaseAddress(input, [])
        try converter.convert(input, completion: completion)
      }
      wait(for: [finished], timeout: 10)
    }
  }

  func testBudgetRefusalAndTruncatedAlphaNeverRetainStorage() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let converter = try Packed422RecordingConverter(device: device, maximumBytes: 1)
    let source = try XCTUnwrap(device.makeBuffer(length: 12))
    XCTAssertThrowsError(try converter.convertUYVA(source, owner: source, width: 4, height: 1,
      rowBytes: 8, alphaRowBytes: 4) { _ in XCTFail("Refused work must not complete") })
    XCTAssertEqual(converter.retainedAllocationBytes, 0)
    let normal = try Packed422RecordingConverter(device: device)
    XCTAssertThrowsError(try normal.convertUYVA(source, owner: source, width: 4, height: 2,
      rowBytes: 8, alphaRowBytes: 4) { _ in XCTFail("Truncated work must not complete") })
    XCTAssertEqual(normal.retainedAllocationBytes, 0)
  }

  private func fill(_ base: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int, format: Packed422Format) {
    for row in 0..<height { for pair in 0..<(width / 2) {
      let i = row * stride + pair * 4
      let y0 = UInt8((pair * 2) % 256), y1 = UInt8((pair * 2 + 1) % 256)
      let u = UInt8(pair % 256), v = UInt8(255 - pair % 256)
      if format == .yuvs { base[i] = y0; base[i+1] = u; base[i+2] = y1; base[i+3] = v }
      else { base[i] = u; base[i+1] = y0; base[i+2] = v; base[i+3] = y1 }
    } }
  }
}
