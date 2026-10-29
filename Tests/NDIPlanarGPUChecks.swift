import Metal
import Synchronization
import XCTest

@objcMembers final class NDIPlanarGPUChecks: XCTestCase {
  func testI420SeparateChromaPlanesAndPA16NativePrecisionIgnoreAlpha() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    for layout in [NDIPlanarLayout.i420, .pa16] {
      let decoder = try NDIPlanarGPUDecoder(device: device)
      let descriptors = try layout.planes(width: 5, height: 3)
      var textures: [MTLTexture] = []
      for (index, d) in descriptors.enumerated() {
        let format: MTLPixelFormat = d.componentBytes == 1 ? .r8Unorm : (d.components == 2 ? .rg16Unorm : .r16Unorm)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: d.width, height: d.height, mipmapped: false)
        td.storageMode = .shared; td.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: td))
        let stride = d.minimumRowBytes + 16
        var bytes = [UInt8](repeating: 0xA5, count: stride * d.height)
        for row in 0..<d.height { for column in 0..<d.width { for component in 0..<d.components {
          let value: UInt16
          if layout == .i420 { value = index == 0 ? 235 : (index == 1 ? 240 : 16) }
          else { value = index == 0 ? (column == 0 ? 4096 : 4097) : (index == 1 ? (component == 0 ? 61440 : 4096) : 0) }
          let offset = row * stride + (column * d.components + component) * d.componentBytes
          bytes[offset] = UInt8(truncatingIfNeeded: value)
          if d.componentBytes == 2 { bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8) }
        } } }
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, d.width, d.height), mipmapLevel: 0,
          withBytes: $0.baseAddress!, bytesPerRow: stride) }
        textures.append(texture)
      }
      let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 5, height: 3, mipmapped: false)
      td.storageMode = .shared; td.usage = .shaderWrite
      let output = try XCTUnwrap(device.makeTexture(descriptor: td))
      let queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
      let allocator = try XCTUnwrap(device.makeCommandAllocator()), command = try XCTUnwrap(device.makeCommandBuffer())
      let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
      command.beginCommandBuffer(allocator: allocator)
      let resources = try decoder.encode(planes: textures, destination: output, layout: layout,
        location: PlanarGPUChromaLocation(horizontal: .left, vertical: .center), range: .video, command: command, residency: residency)
      command.endCommandBuffer(); residency.commit(); queue.addResidencySet(residency)
      let ready = expectation(description: "NDI planar decode")
      let failure = Mutex<String?>(nil), options = MTL4CommitOptions()
      options.addFeedbackHandler { feedback in failure.withLock { $0 = feedback.error?.localizedDescription }; ready.fulfill() }
      queue.commit([command], options: options); wait(for: [ready], timeout: 10)
      XCTAssertNil(failure.withLock { $0 })
      var result = [Float](repeating: 0, count: 5 * 3 * 4)
      result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 5 * 16, from: MTLRegionMake2D(0, 0, 5, 3), mipmapLevel: 0) }
      XCTAssertEqual(result[0], layout == .i420 ? 1 : 0, accuracy: 0.00001)
      XCTAssertEqual(result[1], 0.5, accuracy: 0.00001)
      XCTAssertEqual(result[2], -0.5, accuracy: 0.00001)
      XCTAssertEqual(result[3], 1, "PA16 alpha is explicitly ignored in v1")
      if layout == .pa16 { XCTAssertGreaterThan(result[4], result[0], "Native PA16 low bits survive") }
      withExtendedLifetime((decoder, resources, allocator, command)) {}
      queue.removeResidencySet(residency)
    }
  }
}
