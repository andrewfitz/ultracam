import CoreMedia
import XCTest

@objcMembers final class RecordingSizeEstimatorChecks: XCTestCase {
  func testExactCadenceAndGeometryScaleDiskEstimate() throws {
    let uhd = try XCTUnwrap(RecordingSizeEstimator(codec: .proRes422HQ, width: 3840, height: 2160, frameDuration: CMTime(value: 1001, timescale: 60000)))
    let hd = try XCTUnwrap(RecordingSizeEstimator(codec: .proRes422HQ, width: 1920, height: 1080, frameDuration: CMTime(value: 1001, timescale: 30000)))
    XCTAssertEqual(uhd.bytesPerSecond / hd.bytesPerSecond, 8, accuracy: 0.000001)
    XCTAssertEqual(uhd.megabitsPerSecond, uhd.bytesPerSecond * 8 / 1_000_000)
    XCTAssertEqual(try XCTUnwrap(uhd.seconds(availableBytes: 1_000_000_000)), 1_000_000_000 / uhd.bytesPerSecond)
  }
  func testCodecProfilesAndRoundedStorageReservation() throws {
    let standard = try XCTUnwrap(RecordingSizeEstimator(codec: .proRes422, width: 1920, height: 1080, frameDuration: CMTime(value: 1, timescale: 25)))
    XCTAssertEqual(standard.bytesPerSecond, 15_552_000)
    XCTAssertEqual(standard.bytes(for: 0.00000001), 1)
    let hevc = try XCTUnwrap(RecordingSizeEstimator(codec: .hevcMain10_422, width: 1920, height: 1080, frameDuration: CMTime(value: 1, timescale: 25)))
    XCTAssertEqual(hevc.bytesPerSecond, standard.bytesPerSecond / 2)
  }
  func testInvalidInputsAndOverflowHaveNoEstimate() throws {
    XCTAssertNil(RecordingSizeEstimator(codec: .proRes422HQ, width: Int.max, height: 2, frameDuration: CMTime(value: 1, timescale: 60)))
    XCTAssertNil(RecordingSizeEstimator(codec: .proRes422HQ, width: 1, height: 1, frameDuration: .invalid))
    XCTAssertNil(RecordingSizeEstimator(codec: .proRes422HQ, width: 1, height: 1, frameDuration: CMTime(value: 1, timescale: 60), bitDepth: 8))
    let estimate = try XCTUnwrap(RecordingSizeEstimator(codec: .proRes422HQ, width: 3840, height: 2160, frameDuration: CMTime(value: 1, timescale: 60)))
    XCTAssertNil(estimate.bytes(for: .infinity)); XCTAssertNil(estimate.bytes(for: -1)); XCTAssertNil(estimate.bytes(for: Double.greatestFiniteMagnitude))
    XCTAssertNil(estimate.seconds(availableBytes: -1))
  }
}
