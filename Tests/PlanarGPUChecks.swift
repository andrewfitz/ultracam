import Metal
import XCTest
import Synchronization

@objcMembers final class PlanarGPUChecks: XCTestCase {
  func testPlanarExtentsAndStridesIncludePartialChromaPairs() throws {
    XCTAssertEqual(try PlanarGPUFormat.video420.layout(width: 5, height: 3, strides: [8, 8]).chromaHeight, 2)
    XCTAssertEqual(try PlanarGPUFormat.p216.layout(width: 5, height: 3, strides: [12, 12]).chromaHeight, 3)
    XCTAssertThrowsError(try PlanarGPUFormat.p216.layout(width: 5, height: 3, strides: [10, 10]))
    XCTAssertThrowsError(try PlanarGPUFormat.p216.layout(width: Int.max, height: 3, strides: [Int.max, Int.max]))
    XCTAssertThrowsError(try PlanarGPUFormat.video420.layout(width: 2, height: 3, strides: [Int.max, Int.max]))
  }

  func testUnsupportedChromaLocationsAreExplicitlyRefused() throws {
    XCTAssertThrowsError(try PlanarGPUChromaLocation(horizontal: .top, vertical: .center))
    XCTAssertThrowsError(try PlanarGPUChromaLocation(horizontal: .center, vertical: .unspecified))
    XCTAssertNoThrow(try PlanarGPUChromaLocation(horizontal: .left, vertical: .center))
  }

  func testMetal4PlanarDecoderCompiles() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 required")
    }
    _ = try PlanarGPUDecoder(device: device)
  }

  func testGPUDecodesEveryFormatAtNativePrecisionWithRangeHeadroom() throws {
    for format in PlanarGPUFormat.allCases {
      let full = format == .full420
      let scale: UInt16 = format == .p216 ? 256 : 1
      let y: [UInt16] = [0, 16 * scale, 235 * scale, format == .p216 ? 65535 : 255]
      let result = try decode(format: format, width: 4, height: 1, luma: y,
        chroma: [128 * scale, 128 * scale, 128 * scale, 128 * scale], horizontal: .left, vertical: .top)
      let denominator: Float = full ? 255 : Float(219 * scale)
      for i in 0..<4 {
        XCTAssertEqual(result[i * 4], (Float(y[i]) - (full ? 0 : Float(16 * scale))) / denominator, accuracy: 0.00001)
        XCTAssertEqual(result[i * 4 + 1], 0, accuracy: 0.00001)
        XCTAssertEqual(result[i * 4 + 2], 0, accuracy: 0.00001)
        XCTAssertEqual(result[i * 4 + 3], 1)
      }
      if format == .p216 {
        let precision = try decode(format: format, width: 2, height: 1, luma: [4096, 4097],
          chroma: [32768, 32768], horizontal: .left, vertical: .top)
        XCTAssertGreaterThan(precision[4], precision[0], "P216 low bits must survive decoding")
      }
    }
  }

  func testGPUChromaReconstructionHonorsHorizontalAndVerticalSiting() throws {
    let chroma: [UInt16] = [128, 128, 240, 128, 16, 128, 128, 128]
    let left = try decode(format: .video420, width: 4, height: 4, luma: Array(repeating: 16, count: 16),
      chroma: chroma, horizontal: .left, vertical: .top)
    let centered = try decode(format: .video420, width: 4, height: 4, luma: Array(repeating: 16, count: 16),
      chroma: chroma, horizontal: .center, vertical: .center)
    XCTAssertEqual(left[(1 * 4 + 1) * 4 + 1], 0, accuracy: 0.00001)
    // At (1,0), left samples halfway toward chroma column 1; centered
    // samples only one quarter of that transition.
    XCTAssertEqual(left[5], 0.25, accuracy: 0.00001)
    XCTAssertEqual(centered[5], 0.125, accuracy: 0.00001)
    XCTAssertEqual(left[(1 * 4) * 4 + 1], -0.25, accuracy: 0.00001)
    XCTAssertEqual(centered[(1 * 4) * 4 + 1], -0.125, accuracy: 0.00001)
  }

  private func decode(format: PlanarGPUFormat, width: Int, height: Int, luma: [UInt16], chroma: [UInt16],
    horizontal: Colorimetry.ChromaSiting, vertical: Colorimetry.ChromaSiting) throws -> [Float] {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    let decoder = try PlanarGPUDecoder(device: device)
    func texture(_ pf: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) throws -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: w, height: h, mipmapped: false)
      d.storageMode = .shared; d.usage = usage
      return try XCTUnwrap(device.makeTexture(descriptor: d))
    }
    let cw = width / 2 + width % 2, ch = height / format.verticalSubsampling + (height % format.verticalSubsampling == 0 ? 0 : 1)
    let y = try texture(format.lumaFormat, width, height, .shaderRead)
    let uv = try texture(format.chromaFormat, cw, ch, .shaderRead)
    for (values, target, components) in [(luma, y, 1), (chroma, uv, 2)] {
      let bytes = format == .p216 ? values.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] } : values.map { UInt8(truncatingIfNeeded: $0) }
      bytes.withUnsafeBytes { target.replace(region: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: target.width * components * format.componentBytes) }
    }
    let output = try texture(.rgba32Float, width, height, .shaderWrite)
    let queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
    let allocator = try XCTUnwrap(device.makeCommandAllocator())
    let command = try XCTUnwrap(device.makeCommandBuffer())
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    command.beginCommandBuffer(allocator: allocator)
    let resources = try decoder.encode(luma: y, chroma: uv, destination: output, format: format,
      location: PlanarGPUChromaLocation(horizontal: horizontal, vertical: vertical), range: format == .full420 ? .full : .video,
      command: command, residency: residency)
    command.endCommandBuffer(); residency.commit(); queue.addResidencySet(residency)
    let completion = expectation(description: "planar GPU decode")
    let failure = Mutex<String?>(nil)
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in
      failure.withLock { $0 = feedback.error?.localizedDescription }; completion.fulfill()
    }
    queue.commit([command], options: options)
    wait(for: [completion], timeout: 10)
    XCTAssertNil(failure.withLock { $0 })
    var floats = [Float](repeating: 0, count: width * height * 4)
    floats.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 16,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
    withExtendedLifetime((decoder, resources, allocator, command)) {}
    queue.removeResidencySet(residency)
    return floats
  }
}
