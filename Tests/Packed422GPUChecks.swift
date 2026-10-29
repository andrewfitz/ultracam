import Metal
import XCTest

@objcMembers final class Packed422GPUChecks: XCTestCase {
  func testBothByteOrdersDecodePaddedRowsToExactTenBitCodes() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let decoder = try Packed422GPU(device: device)
    for format in [Packed422Format.twoVuy, .yuvs, .uyva] {
      // Two rows; row padding deliberately contains nonzero poison.
      let uyvy: [UInt8] = [16, 0, 240, 255, 33, 64, 200, 128, 99, 99, 99, 99,
                          128, 235, 128, 16, 1, 1, 254, 254, 99, 99, 99, 99]
      var bytes = uyvy
      if format == .yuvs {
        for row in 0..<2 { for pair in 0..<2 {
          let i = row * 12 + pair * 4
          bytes[i] = uyvy[i + 1]; bytes[i + 1] = uyvy[i]
          bytes[i + 2] = uyvy[i + 3]; bytes[i + 3] = uyvy[i + 2]
        } }
      }
      if format == .uyva { bytes += [0, 255, 128, 64, 255, 0, 0, 255] }
      let source = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count))
      let luma = try texture(device, .r16Uint, width: 4, height: 2)
      let chroma = try texture(device, .rg16Uint, width: 2, height: 2)
      let command = try XCTUnwrap(queue.makeCommandBuffer())
      try decoder.encode(commandBuffer: command, source: source, rowBytes: 12,
        width: 4, height: 2, format: format, alphaRowBytes: format == .uyva ? 4 : nil, luma: luma, chroma: chroma)
      command.commit(); command.waitUntilCompleted()
      XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
      var y = [UInt16](repeating: 0, count: 8)
      var uv = [UInt16](repeating: 0, count: 8)
      y.withUnsafeMutableBytes { luma.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0) }
      uv.withUnsafeMutableBytes { chroma.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0) }
      XCTAssertEqual(y, [0, 255, 64, 128, 235, 16, 1, 254].map { UInt16($0) << 8 })
      XCTAssertEqual(uv, [16, 240, 33, 200, 128, 128, 1, 254].map { UInt16($0) << 8 })
    }
  }

  func testRejectsUnsupportedFormatsAndTruncatedAllocationBeforeEncoding() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let decoder = try Packed422GPU(device: device)
    let source = try XCTUnwrap(device.makeBuffer(length: 7))
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let y = try texture(device, .r16Uint, width: 4, height: 1)
    let uv = try texture(device, .rg16Uint, width: 2, height: 1)
    XCTAssertThrowsError(try decoder.encode(commandBuffer: command, source: source,
      rowBytes: 8, width: 4, height: 1, format: .twoVuy, luma: y, chroma: uv))
    XCTAssertThrowsError(try decoder.encode(commandBuffer: command, source: source,
      rowBytes: 8, width: 4, height: 1, format: .r210, luma: y, chroma: uv))
  }

  func testMetal4DecodesUYVAWithoutUsingAlpha() throws {
    for textureSource in [false, true] {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let decoder = try Packed422GPU4(device: device)
    let bytes: [UInt8] = [16, 235, 240, 1, 0, 255]
    let source = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count))
    let packedTexture = try texture(device, .rgba8Uint, width: 1, height: 1)
    bytes.withUnsafeBytes { packedTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 4) }
    let parameters = try XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared))
    let y = try texture(device, .r16Uint, width: 2, height: 1)
    let uv = try texture(device, .rg16Uint, width: 1, height: 1)
    let queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
    let allocator = try XCTUnwrap(device.makeCommandAllocator())
    let command = try XCTUnwrap(device.makeCommandBuffer())
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    residency.addAllocation(source); residency.addAllocation(packedTexture); residency.addAllocation(parameters)
    residency.addAllocation(y); residency.addAllocation(uv)
    residency.commit(); queue.addResidencySet(residency)
    let tableDescriptor = MTL4ArgumentTableDescriptor()
    tableDescriptor.maxBufferBindCount = 2; tableDescriptor.maxTextureBindCount = 3
    let table = try device.makeArgumentTable(descriptor: tableDescriptor)
    command.beginCommandBuffer(allocator: allocator)
    let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
    if textureSource {
      try decoder.encodeTexture(encoder: encoder, table: table, parameters: parameters,
        source: packedTexture, format: .uyva, luma: y, chroma: uv)
    } else {
    try decoder.encode(encoder: encoder, table: table, parameters: parameters,
      source: source, rowBytes: 4, width: 2, height: 1, format: .uyva,
      alphaRowBytes: 2, luma: y, chroma: uv)
    }
    encoder.endEncoding(); command.endCommandBuffer()
    let finished = expectation(description: "Metal 4 feedback")
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in
      XCTAssertNil(feedback.error); finished.fulfill()
    }
    queue.commit([command], options: options)
    wait(for: [finished], timeout: 10)
    var values = [UInt16](repeating: 0, count: 2)
    values.withUnsafeMutableBytes { y.getBytes($0.baseAddress!, bytesPerRow: 4,
      from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0) }
    XCTAssertEqual(values, [235 << 8, 1 << 8])
    queue.removeResidencySet(residency)
    withExtendedLifetime((decoder, source, packedTexture, parameters, y, uv, allocator, command, table)) {}
    }
  }

  private func texture(_ device: MTLDevice, _ format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
    return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
  }
}
