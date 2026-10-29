#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class GPUAllocationBudgetChecks: XCTestCase {
  func testPaddedBytesAndMinimumFitRefusal() throws {
    let policy = try GPUAllocationBudgetPolicy(maximumBytes: 100, minimumSlots: 2)
    XCTAssertNoThrow(try policy.validateMinimum(bytesPerSlot: 50))
    XCTAssertThrowsError(try policy.validateMinimum(bytesPerSlot: 51)) { XCTAssertEqual($0 as? GPUAllocationBudgetFailure, .minimumDoesNotFit(required: 102, limit: 100)) }
    let bytes = try MediaStorageExtent.allocationBytes(planes: [.init(rowBytes: 130, rows: 3), .init(rowBytes: 70, rows: 3)], pixelBufferDataSize: 700, ioSurfaceAllocationSize: 900)
    XCTAssertEqual(bytes, 900)
  }
  func testPlaneViewsDeduplicateAndLeaseReleaseIsIdempotent() throws {
    let budget = GPUAllocationBudget(policy: try .init(maximumBytes: 100, minimumSlots: 1))
    let owner = NSObject()
    let a = try budget.acquire(backingID: 42, bytes: 80, generation: 1, owner: owner)
    let b = try budget.acquire(backingID: 42, bytes: 80, generation: 1)
    XCTAssertEqual(budget.snapshot(), .init(bytes: 80, allocations: 1, leases: 2, peakBytes: 80))
    a.release(); a.release(); XCTAssertEqual(budget.snapshot().leases, 1)
    b.release(); XCTAssertEqual(budget.snapshot().bytes, 0)
  }
  func testLaterViewOwnerAdoptsLifetimeAndGenerationReuseIsRejected() throws {
    let budget = GPUAllocationBudget(policy: try .init(maximumBytes: 100, minimumSlots: 1))
    weak var weakOwner: NSObject?
    let first = try budget.acquire(backingID: 7, bytes: 40, generation: 1)
    do {
      let owner = NSObject(); weakOwner = owner
      let second = try budget.acquire(backingID: 7, bytes: 40, generation: 1, owner: owner)
      XCTAssertNotNil(weakOwner); second.release(); XCTAssertNotNil(weakOwner)
    }
    XCTAssertNotNil(weakOwner)
    XCTAssertThrowsError(try budget.acquire(backingID: 7, bytes: 40, generation: 2)) { XCTAssertEqual($0 as? GPUAllocationBudgetFailure, .generationMismatch) }
    first.release(); XCTAssertNil(weakOwner)
  }

  func testGenerationsRetainOldBackingUntilGPULeaseCompletes() throws {
    let budget = GPUAllocationBudget(policy: try .init(maximumBytes: 100, minimumSlots: 1))
    let old = try budget.acquire(backingID: 1, bytes: 60, generation: 1)
    XCTAssertThrowsError(try budget.acquire(backingID: 2, bytes: 60, generation: 2))
    old.release()
    XCTAssertNoThrow(try budget.acquire(backingID: 2, bytes: 60, generation: 2).release())
  }
  func testCacheAgeIsMonotonicElapsedTime() throws {
    XCTAssertFalse(try GPUCacheAge.expired(lastUsed: 10, now: 11.9, idleAge: 2))
    XCTAssertTrue(try GPUCacheAge.expired(lastUsed: 10, now: 12, idleAge: 2))
    XCTAssertThrowsError(try GPUCacheAge.expired(lastUsed: 10, now: 9, idleAge: 2))
  }
}
#endif
