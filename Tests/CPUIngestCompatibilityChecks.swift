import CoreVideo
import XCTest

@objcMembers final class CPUIngestCompatibilityChecks: XCTestCase {
  func testOffRefusesAndOnCopiesOwnedUnwrappableNativePackingAndCountsOnce() throws {
    for (format, bytes) in [(UInt32(0x72323130), [UInt8(0x3f), 0xf0, 1, 0x55]),
                             (UInt32(0x5231324c), [UInt8(0xff), 0x1f, 0x80, 0x55, 0x0a])] {
      let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
      defer { raw.deallocate() }
      for (index, value) in bytes.enumerated() { raw.storeBytes(of: value, toByteOffset: index, as: UInt8.self) }
      let frame = CapturedCPUMemoryFrame(pointer: raw, width: 1, height: 1, bytesPerRow: bytes.count,
        allocation: NoCopyIngestAllocation(baseAddress: raw, length: bytes.count, generation: 1),
        inspectVM: { _, _ in nil }, frameOwner: NSObject(), pixelFormat: format)
      var count = 0
      XCTAssertThrowsError(try CPUCompatibilityConverter(policy: .init()).copyIngest(frame,
        metal4Available: true, onCopied: { count += 1 }))
      XCTAssertEqual(count, 0)
      let enabled = CPUCompatibilityConverter(policy: .init(allowCPUConversion: true))
      XCTAssertThrowsError(try enabled.copyIngest(frame, metal4Available: false, onCopied: { count += 1 }))
      XCTAssertEqual(count, 0)
      let output = try enabled.copyIngest(frame, metal4Available: true, onCopied: { count += 1 })
      XCTAssertEqual(count, 1)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(output.value), format)
      CVPixelBufferLockBaseAddress(output.value, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(output.value, .readOnly) }
      let pixels = CVPixelBufferGetBaseAddress(output.value)!.assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels, count: bytes.count)), bytes)
    }
  }

  func testMissingOverlappingOrTruncatedAlphaCannotUseCompatibility() {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
    defer { raw.deallocate() }
    for planes: [CapturedCPUMemoryFrame.Plane] in [
      [.init(offset: 0, bytesPerRow: 16, height: 2)],
      [.init(offset: 0, bytesPerRow: 16, height: 2), .init(offset: 16, bytesPerRow: 8, height: 2)],
      [.init(offset: 0, bytesPerRow: 16, height: 2), .init(offset: 32, bytesPerRow: 7, height: 2)]
    ] {
      let frame = CapturedCPUMemoryFrame(pointer: raw, width: 8, height: 2, bytesPerRow: 16,
        allocation: NoCopyIngestAllocation(baseAddress: raw, length: 128, generation: 1),
        inspectVM: { _, _ in nil }, frameOwner: NSObject(), pixelFormat: 0x55595641, planes: planes)
      XCTAssertThrowsError(try frame.validatedCPUReadableLength())
      XCTAssertThrowsError(try CPUCompatibilityConverter(policy: .init(allowCPUConversion: true))
        .copyIngest(frame, metal4Available: true))
    }
  }

  func testMalformedOwnedExtentCannotUseCompatibility() {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 1)
    defer { raw.deallocate() }
    let frame = CapturedCPUMemoryFrame(pointer: raw, width: 2, height: 1, bytesPerRow: 8,
      allocation: NoCopyIngestAllocation(baseAddress: raw, length: 4, generation: 1),
      inspectVM: { _, _ in nil }, frameOwner: NSObject())
    var count = 0
    XCTAssertThrowsError(try CPUCompatibilityConverter(policy: .init(allowCPUConversion: true))
      .copyIngest(frame, metal4Available: true, onCopied: { count += 1 }))
    XCTAssertEqual(count, 0)
  }
}
