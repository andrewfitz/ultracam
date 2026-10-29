import Metal
import Foundation
import XCTest

@objcMembers final class RGBGPUDecoderChecks: XCTestCase {
  func testGPUDecodesPackingAndPaddedOddRows() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 unavailable") }
    let queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
    let decoder = try RGBGPUDecoder(device: device)
    for format in RGBFormat.allCases {
      let width = 3, height = 2, stride = try format.minimumRowBytes(width: width) + 7
      var bytes = [UInt8](repeating: 0xcd, count: stride * height)
      for row in 0..<height {
        for x in 0..<width {
          let base = row * stride
          switch format {
          case .bgra8, .rgba8:
            let pixel = try RGBFormatValidator.packRGBA8(red: 255, green: 0, blue: 0, alpha: 128, format: format)
            bytes.replaceSubrange((base+x*4)..<(base+x*4+4), with: pixel)
          case .r210:
            bytes.replaceSubrange((base+x*4)..<(base+x*4+4), with: [0x3a, 0xc1, 0x00, 0x40]) // 940,64,64
          case .r12l:
            // Write bit-by-bit independently of the production packing helper.
            for c in 0..<3 { for bit in 0..<12 {
              let offset = x * 36 + c * 12 + bit
              let mask = UInt8(1 << (offset % 8))
              bytes[base+offset/8] &= ~mask
              if c == 0 { bytes[base+offset/8] |= mask }
            } }
          }
        }
      }
      let input = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count))
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
      descriptor.storageMode = .shared; descriptor.usage = [.shaderWrite, .shaderRead]
      let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
      let command = try XCTUnwrap(device.makeCommandBuffer())
      let allocator = try XCTUnwrap(device.makeCommandAllocator())
      let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
      command.beginCommandBuffer(allocator: allocator)
      let resources = try decoder.encode(input: input, output: output, width: width, height: height, bytesPerRow: stride, format: format, commandBuffer: command, residency: residency)
      command.endCommandBuffer()
      residency.commit(); queue.addResidencySet(residency)
      let done = DispatchSemaphore(value: 0)
      let options = MTL4CommitOptions()
      options.addFeedbackHandler { feedback in
        XCTAssertNil(feedback.error)
        done.signal()
      }
      queue.commit([command], options: options)
      XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
      withExtendedLifetime((resources, allocator, command)) {}
      queue.removeResidencySet(residency)
      var values = [Float](repeating: -1, count: width*height*4)
      output.getBytes(&values, bytesPerRow: width*16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
      for i in Swift.stride(from: 0, to: values.count, by: 4) {
        XCTAssertEqual(values[i], 1, accuracy: 0.00001, format.rawValue)
        XCTAssertEqual(values[i+1], 0, accuracy: 0.00001)
        XCTAssertEqual(values[i+2], 0, accuracy: 0.00001)
        XCTAssertEqual(values[i+3], format.hasAlpha ? Float(128)/255 : 1, accuracy: 0.00001)
      }
    }
  }
}
