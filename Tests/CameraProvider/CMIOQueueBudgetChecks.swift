import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class CMIOQueueBudgetChecks: XCTestCase {
  func testFixedEightSlotsAndTimeByteBounds() throws {
    let budget = try CMIOQueueBudget(queueSlots: 8, frameDuration: CMTime(value: 1001, timescale: 60000), maxBytes: 320 * 1024 * 1024)
    XCTAssertEqual(budget.queueSlots, 8)
    XCTAssertEqual(budget.maximumDuration, CMTimeMultiply(budget.frameDuration, multiplier: 8))
    XCTAssertThrowsError(try budget.admit(bytes: 320 * 1024 * 1024 + 1))
    XCTAssertTrue(try budget.admit(bytes: 40 * 1024 * 1024))
    for _ in 1..<8 { XCTAssertTrue(try budget.admit(bytes: 1)) }
    XCTAssertThrowsError(try budget.admit(bytes: 1))
    budget.releaseOne(bytes: 40 * 1024 * 1024)
    XCTAssertTrue(try budget.admit(bytes: 1))
  }
  func testPaddedAllocationValidationRejectsOverflowAndMissingExtent() throws {
    let plane = CMIOQueuePlane(rowBytes: 4096, rows: 1080)
    XCTAssertEqual(try CMIOQueueBudget.allocationBytes(planes: [plane], pixelBufferDataSize: 4_000_000, ioSurfaceAllocationSize: 8_000_000), 8_000_000)
    XCTAssertThrowsError(try CMIOQueueBudget.allocationBytes(planes: [CMIOQueuePlane(rowBytes: Int.max, rows: Int.max)], pixelBufferDataSize: 0, ioSurfaceAllocationSize: 0))
    XCTAssertThrowsError(try CMIOQueueBudget.allocationBytes(planes: [], pixelBufferDataSize: 0, ioSurfaceAllocationSize: 0))
  }
  func testHeldConsumerAndStopDrainAreExplicitOwnershipStates() throws {
    let budget = try CMIOQueueBudget(queueSlots: 8, frameDuration: CMTime(value: 1, timescale: 60), maxBytes: 100)
    let lease = try budget.admitLease(bytes: 25)
    XCTAssertEqual(budget.currentBytes, 25)
    budget.closeAdmission()
    XCTAssertThrowsError(try budget.admit(bytes: 1))
    XCTAssertEqual(budget.currentBytes, 25)
    lease.release()
    XCTAssertEqual(budget.currentBytes, 0)
    budget.releaseOne(bytes: 25)
    XCTAssertEqual(budget.currentBytes, 0)
  }
  func testMinimumSlotsNeverOverridesHardByteLimit() throws {
    let budget = try CMIOQueueBudget(queueSlots: 8, frameDuration: CMTime(value: 1, timescale: 60), maxBytes: 10, minimumSlots: 2)
    XCTAssertTrue(try budget.admit(bytes: 10))
    XCTAssertThrowsError(try budget.admit(bytes: 1))
  }
}
