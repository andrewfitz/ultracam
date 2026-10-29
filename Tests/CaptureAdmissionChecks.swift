import Foundation
import XCTest

@objcMembers final class CaptureAdmissionChecks: XCTestCase {
  func testConcurrentAdmissionHasExactBoundAndConservationAfterDrain() {
    let budget = CaptureAdmissionBudget(maximumSlots: 4, maximumBytes: 200, maximumDuration: 1, minimumSlots: 1)
    let retained = HeldAdmissionLeases()
    DispatchQueue.concurrentPerform(iterations: 100) { _ in
      if let lease = budget.admit(bytes: 50, duration: 0.01) { retained.append(lease) }
    }
    XCTAssertEqual(budget.snapshot.currentSlots, 4)
    XCTAssertEqual(budget.snapshot.currentBytes, 200)
    XCTAssertEqual(budget.snapshot.accepted, 4)
    XCTAssertEqual(budget.snapshot.rejected, 96)
    XCTAssertEqual(budget.snapshot.peakSlots, 4)
    retained.releaseAll()
    XCTAssertEqual(budget.snapshot.currentSlots, 0)
    XCTAssertEqual(budget.snapshot.currentBytes, 0)
    XCTAssertEqual(budget.snapshot.released, 4)
  }
  func testHardByteLimitCannotBeOverriddenByMinimumSlots() {
    let budget = CaptureAdmissionBudget(maximumSlots: 8, maximumBytes: 100, maximumDuration: 0.2, minimumSlots: 3)
    let first = budget.admit(bytes: 60, duration: 1)
    XCTAssertNotNil(first)
    XCTAssertNil(budget.admit(bytes: 60, duration: 1))
    XCTAssertEqual(budget.snapshot.currentBytes, 60)
    XCTAssertEqual(budget.snapshot.rejected, 1)
    withExtendedLifetime(first) {}
  }
  func testMinimumSlotsAllowsLowCadenceButHardSlotsAndDurationRemainBounded() {
    let budget = CaptureAdmissionBudget(maximumSlots: 4, maximumBytes: 1000, maximumDuration: 0.2, minimumSlots: 2)
    var held: [CaptureAdmissionBudget.Lease] = []
    held.append(budget.admit(bytes: 10, duration: 1)!)
    held.append(budget.admit(bytes: 10, duration: 1)!)
    XCTAssertNil(budget.admit(bytes: 10, duration: 1))
    XCTAssertEqual(budget.snapshot.currentSlots, 2)
    held.removeAll()
    XCTAssertEqual(budget.snapshot.currentSlots, 0)
    XCTAssertEqual(budget.snapshot.currentBytes, 0)
    XCTAssertEqual(budget.snapshot.currentDuration, 0)
    let fast = CaptureAdmissionBudget(maximumSlots: 2, maximumBytes: 1000, maximumDuration: 1, minimumSlots: 1)
    let a = fast.admit(bytes: 1, duration: 0.01)
    let b = fast.admit(bytes: 1, duration: 0.01)
    XCTAssertNil(fast.admit(bytes: 1, duration: 0.01))
    withExtendedLifetime((a,b)) {}
  }
  func testLeaseRemainsAdmittedThroughAsynchronousHandoffAndDrains() {
    let budget = CaptureAdmissionBudget(maximumSlots: 2, maximumBytes: 100, maximumDuration: 1, minimumSlots: 1)
    let queue = DispatchQueue(label: "budget.test.delivery")
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var lease = budget.admit(bytes: 60, duration: 0.1)
    queue.async { [held = lease] in
      entered.signal()
      _ = release.wait(timeout: .now() + 2)
      withExtendedLifetime(held) {}
    }
    lease = nil
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    XCTAssertNil(budget.admit(bytes: 60, duration: 0.1))
    XCTAssertEqual(budget.snapshot.currentSlots, 1)
    release.signal()
    queue.sync {}
    XCTAssertEqual(budget.snapshot.currentSlots, 0)
    XCTAssertEqual(budget.snapshot.accepted, 1)
    XCTAssertEqual(budget.snapshot.released, 1)
  }
  func testInvalidAndOverflowAccountingCannotAdmit() {
    let budget = CaptureAdmissionBudget(maximumSlots: 3, maximumBytes: Int.max, maximumDuration: 1, minimumSlots: 1)
    let held = budget.admit(bytes: Int.max - 2, duration: 0.1)
    XCTAssertNotNil(held)
    XCTAssertNil(budget.admit(bytes: 10, duration: 0.1))
    XCTAssertNil(budget.admit(bytes: -1, duration: 0.1))
    XCTAssertNil(budget.admit(bytes: 0, duration: 0.1))
    XCTAssertNil(budget.admit(bytes: 1, duration: .nan))
    XCTAssertNil(budget.admit(bytes: 1, duration: .infinity))
    XCTAssertNil(budget.admit(bytes: 1, duration: 0))
    XCTAssertEqual(budget.snapshot.rejected, 6)
    withExtendedLifetime(held) {}
  }
  func testDurationBudgetIsEquivalentAcrossCadencesAndPaddedStorage() {
    for (duration, bytes) in [(0.01, 20), (0.02, 40)] {
      let budget = CaptureAdmissionBudget(maximumSlots: 100, maximumBytes: 1000, maximumDuration: 0.1, minimumSlots: 1)
      var held: [CaptureAdmissionBudget.Lease] = []
      while let next = budget.admit(bytes: bytes, duration: duration) { held.append(next) }
      XCTAssertEqual(budget.snapshot.currentDuration, 0.1, accuracy: 0.000001)
      XCTAssertEqual(budget.snapshot.currentBytes, 200)
      XCTAssertEqual(budget.snapshot.accepted, held.count)
    }
  }
}

private final class HeldAdmissionLeases: @unchecked Sendable {
  private let lock = NSLock()
  private var leases: [CaptureAdmissionBudget.Lease] = []
  func append(_ lease: CaptureAdmissionBudget.Lease) { lock.withLock { leases.append(lease) } }
  func releaseAll() { lock.withLock { leases.removeAll() } }
}
