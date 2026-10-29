#if ULTRACAM_TEST_SUPPORT
import CoreVideo
import Foundation
import IOSurface
import Metal
import XCTest

@objcMembers final class RecordingGPUCacheBudgetChecks: XCTestCase {
  private func buffer(_ type: OSType) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 192, 32, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
    return try XCTUnwrap(result)
  }
  func testRealIOSurfaceCacheChargesBackingOnceAcrossDestinationPlanes() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal4 required") }
    let source = try buffer(kCVPixelFormatType_422YpCbCr10)
    let output = try buffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    let a = IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface(source)!.takeUnretainedValue())
    let b = IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface(output)!.takeUnretainedValue())
    let converter = try RecordingPixelConverter(device: device, cacheMaximumBytes: a + b)
    _ = try converter.convert(source, into: output)
    XCTAssertEqual(converter.cachedAllocationBytesForTesting, a + b)
    converter.endUse()
    XCTAssertEqual(converter.cachedAllocationBytesForTesting, 0)
  }
  func testCompletedCacheExpiresByElapsedTimeWithoutMoreFrames() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal4 required") }
    var now: TimeInterval = 10
    let converter = try RecordingPixelConverter(device: device, cacheIdleAge: 2, monotonicNow: { now })
    _ = try converter.convert(buffer(kCVPixelFormatType_422YpCbCr10), into: buffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange))
    now = 11.9; converter.evictExpiredCacheForTesting()
    XCTAssertGreaterThan(converter.cachedAllocationBytesForTesting, 0)
    now = 12; converter.evictExpiredCacheForTesting()
    XCTAssertEqual(converter.cachedAllocationBytesForTesting, 0)
  }
  func testFullRangeV210PhysicallyMapsEndpointsAndMidtonesToLegalVideoCodes() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal4 required") }
    let source = try buffer(kCVPixelFormatType_422YpCbCr10)
    let output = try buffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    let ys: [UInt32] = [0, 64, 512, 940, 1023, 1023]
    let cs: [UInt32] = [0, 512, 1023]
    CVPixelBufferLockBaseAddress(source, [])
    let base = CVPixelBufferGetBaseAddress(source)!
    let words: [UInt32] = [cs[0] | ys[0] << 10 | cs[0] << 20,
      ys[1] | cs[1] << 10 | ys[2] << 20, cs[1] | ys[3] << 10 | cs[2] << 20,
      ys[4] | cs[2] << 10 | ys[5] << 20]
    for (i,w) in words.enumerated() { base.storeBytes(of: w, toByteOffset: i * 4, as: UInt32.self) }
    CVPixelBufferUnlockBaseAddress(source, [])
    let converter = try RecordingPixelConverter(device: device)
    _ = try converter.convert(source, into: output, sourceRange: .full)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)!
    let c = CVPixelBufferGetBaseAddressOfPlane(output, 1)!
    for i in 0..<6 {
      XCTAssertEqual(y.load(fromByteOffset: i * 2, as: UInt16.self) >> 6, UInt16(64 + (ys[i] * 876 + 511) / 1023))
    }
    for i in 0..<3 {
      let expected = UInt16(64 + (cs[i] * 896 + 511) / 1023)
      XCTAssertEqual(c.load(fromByteOffset: i * 4, as: UInt16.self) >> 6, expected)
      XCTAssertEqual(c.load(fromByteOffset: i * 4 + 2, as: UInt16.self) >> 6, expected)
    }
  }
  func testFailedDestinationAdmissionRollsBackProspectiveSourceLease() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal4 required") }
    let source = try buffer(kCVPixelFormatType_422YpCbCr10)
    let output = try buffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    let bytes = IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface(source)!.takeUnretainedValue())
    let converter = try RecordingPixelConverter(device: device, cacheMaximumBytes: bytes)
    XCTAssertThrowsError(try converter.convert(source, into: output))
    XCTAssertEqual(converter.cachedAllocationBytesForTesting, 0, "Unsubmitted source cannot remain pinned to an unsignalled sequence")
    converter.endUse()
    XCTAssertEqual(converter.cachedTextureCount, 0)
  }
  func testActualAllocationCannotFitRefusesWithoutCPUFallback() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal4 required") }
    let converter = try RecordingPixelConverter(device: device, cacheMaximumBytes: 1)
    XCTAssertThrowsError(try converter.convert(buffer(kCVPixelFormatType_422YpCbCr10),
      into: buffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)))
    XCTAssertEqual(converter.cachedAllocationBytesForTesting, 0)
  }
}
#endif
