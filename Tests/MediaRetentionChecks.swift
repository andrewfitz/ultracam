import Foundation
import XCTest

@objcMembers final class MediaRetentionChecks: XCTestCase {
  func testMinimumSlotsNeverRelaxHardBytes() throws {
    let ledger = MediaRetentionLedger(policy: try MediaRetentionPolicy(maximumBytes: 100, maximumDuration: 0.1, maximumSlots: 8, minimumSlots: 3))
    let first = try ledger.admit(bytes: 70, duration: 0.5)
    XCTAssertThrowsError(try ledger.admit(bytes: 40, duration: 0.5))
    XCTAssertEqual(ledger.snapshot.currentBytes, 70)
    first.release()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  func testVFRUsesSumAndLowRateCanKeepMinimumWork() throws {
    let ledger = MediaRetentionLedger(policy: try MediaRetentionPolicy(maximumBytes: 1000, maximumDuration: 0.1, maximumSlots: 10, minimumSlots: 2))
    let a = try ledger.admit(bytes: 10, duration: 0.2)
    let b = try ledger.admit(bytes: 10, duration: 0.3)
    XCTAssertEqual(ledger.snapshot.currentDuration, 0.5, accuracy: 1e-12)
    XCTAssertThrowsError(try ledger.admit(bytes: 10, duration: 0.01))
    a.release(); b.release()
    let c = try ledger.admit(bytes: 10, duration: 0.01)
    let d = try ledger.admit(bytes: 10, duration: 0.08)
    XCTAssertThrowsError(try ledger.admit(bytes: 10, duration: 0.02))
    XCTAssertEqual(ledger.snapshot.currentDuration, 0.09, accuracy: 1e-12)
    c.release(); d.release()
    XCTAssertEqual(ledger.snapshot.currentDuration, 0)
  }

  func testOverflowInvalidMediaAndSlotFailuresAreDistinct() throws {
    let ledger = MediaRetentionLedger(policy: try MediaRetentionPolicy(maximumBytes: Int.max, maximumDuration: 1, maximumSlots: 2))
    let a = try ledger.admit(bytes: Int.max - 2, duration: 0.01)
    XCTAssertThrowsError(try ledger.admit(bytes: 5, duration: 0.01)) { XCTAssertEqual($0 as? MediaRetentionFailure, .byteLimit) }
    XCTAssertThrowsError(try ledger.admit(bytes: 1, duration: .nan)) { XCTAssertEqual($0 as? MediaRetentionFailure, .invalidMedia) }
    a.release()
    let b = try ledger.admit(bytes: 1, duration: 0.01)
    let c = try ledger.admit(bytes: 1, duration: 0.01)
    XCTAssertThrowsError(try ledger.admit(bytes: 1, duration: 0.01)) { XCTAssertEqual($0 as? MediaRetentionFailure, .slotLimit) }
    b.release(); c.release()
  }

  func testLeaseReleaseIsIdempotentAndDeinitReleases() throws {
    let ledger = MediaRetentionLedger(policy: try MediaRetentionPolicy(maximumBytes: 100, maximumDuration: 1))
    var lease: MediaRetentionLedger.Lease? = try ledger.admit(bytes: 20, duration: 0.1)
    lease?.release(); lease?.release(); lease = nil
    XCTAssertEqual(ledger.snapshot.released, 1)
    do { let held = try ledger.admit(bytes: 30, duration: 0.1); withExtendedLifetime(held) { XCTAssertEqual(ledger.snapshot.currentBytes, 30) } }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(ledger.snapshot.released, 2)
  }

  func testPaddedPlanesAndSurfaceAllocationAreCountedWithoutDoubleCounting() throws {
    let planes = [MediaStorageExtent.Plane(rowBytes: 4096, rows: 1080), MediaStorageExtent.Plane(rowBytes: 4096, rows: 540)]
    XCTAssertEqual(try MediaStorageExtent.allocationBytes(planes: planes, pixelBufferDataSize: 0, ioSurfaceAllocationSize: nil), 4096 * 1620)
    XCTAssertEqual(try MediaStorageExtent.allocationBytes(planes: planes, pixelBufferDataSize: 7000000, ioSurfaceAllocationSize: 8000000), 8000000)
    XCTAssertThrowsError(try MediaStorageExtent.allocationBytes(planes: [.init(rowBytes: Int.max, rows: 2)], pixelBufferDataSize: 0, ioSurfaceAllocationSize: nil))
    XCTAssertThrowsError(try MediaStorageExtent.allocationBytes(planes: [.init(rowBytes: Int.max, rows: 1), .init(rowBytes: 1, rows: 1)], pixelBufferDataSize: 0, ioSurfaceAllocationSize: nil))
    XCTAssertThrowsError(try MediaStorageExtent.allocationBytes(planes: [], pixelBufferDataSize: 0, ioSurfaceAllocationSize: nil))
  }

  func testCacheIdleAgeDoesNotBecomeFrameCountOrMediaDuration() throws {
    let policy = try MediaCachePolicy(maximumBytes: 1000, idleAge: 4)
    XCTAssertFalse(try policy.isExpired(lastUsed: 10, now: 13.99))
    XCTAssertTrue(try policy.isExpired(lastUsed: 10, now: 14))
    XCTAssertThrowsError(try policy.isExpired(lastUsed: 10, now: 9))
    XCTAssertThrowsError(try MediaRetentionPolicy(maximumBytes: 0, maximumDuration: 1))
    XCTAssertThrowsError(try MediaRetentionPolicy(maximumBytes: 1, maximumDuration: .infinity))
    XCTAssertThrowsError(try MediaRetentionPolicy(maximumBytes: 1, maximumDuration: 1, maximumSlots: 2, minimumSlots: 3))
  }
}
