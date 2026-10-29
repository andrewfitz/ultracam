import CoreMedia
import XCTest
@objcMembers final class RecordingPerformanceChecks: XCTestCase {
  func testRetentionUsesActualPackedAllocationExtent() throws {
    let bytes = try MediaStorageExtent.allocationBytes(planes: [.init(rowBytes: 10240, rows: 2160)], pixelBufferDataSize: 0, ioSurfaceAllocationSize: nil)
    XCTAssertEqual(bytes, 22_118_400)
  }
  func testDiskEstimateUsesProductionProfileAndExactCadence() throws {
    let estimate = try XCTUnwrap(RecordingSizeEstimator(codec: .proRes422HQ, width: 3840, height: 2160, frameDuration: CMTime(value: 1001, timescale: 60000)))
    XCTAssertEqual(estimate.bytesPerSecond, 0.444 * 3840 * 2160 * 60000 / 1001, accuracy: 0.001)
  }
}
