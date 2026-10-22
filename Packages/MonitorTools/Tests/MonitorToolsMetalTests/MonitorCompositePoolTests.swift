import CoreVideo
import Foundation
import IOSurface
import MonitorToolsCore
import XCTest

@testable import MonitorToolsMetal

final class MonitorCompositePoolTests: XCTestCase {
  private let reservation = 32_768

  // Catches direct allocations, missing pool threshold, and reuse while consumers hold frames.
  func testHeldBuffersAreDistinctAndThresholdRecoversAfterRelease() throws {
    let pool = MonitorCompositePool(ledger: MonitorAdmissionLedger(), maximumBuffers: 2)
    var held: [CVPixelBuffer] = try (0..<2).map { _ in
      try pool.allocate(width: 64, height: 32, reservation: reservation)
    }
    let identifiers = try held.map(surfaceID)
    XCTAssertEqual(Set(identifiers).count, 2)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 65_536)
    XCTAssertTrue(held.allSatisfy { CVPixelBufferGetPixelFormatType($0) == kCVPixelFormatType_32BGRA })
    XCTAssertThrowsError(try pool.allocate(width: 64, height: 32, reservation: reservation)) {
      XCTAssertEqual(
        $0 as? MonitorCompositePool.AllocationError,
        .allocationFailed(kCVReturnWouldExceedAllocationThreshold))
    }
    XCTAssertEqual(pool.statsSnapshot().allocations, 2)
    let releasedID = identifiers[1]
    held.removeLast()
    let recovered = try pool.allocate(width: 64, height: 32, reservation: reservation)
    XCTAssertEqual(try surfaceID(recovered), releasedID)
    XCTAssertEqual(pool.statsSnapshot().allocations, 2)
    XCTAssertEqual(pool.statsSnapshot().reuses, 1)
    XCTAssertEqual(pool.statsSnapshot().poolFailures, 1)
    withExtendedLifetime(held) {}
  }

  // Catches bypassing the threshold when a caller requests a larger configuration.
  func testConfiguredCapacityCannotExceedEightBuffers() throws {
    for pool in [
      MonitorCompositePool(ledger: MonitorAdmissionLedger()),
      MonitorCompositePool(ledger: MonitorAdmissionLedger(), maximumBuffers: 12),
    ] {
      let held = try (0..<8).map { _ in
        try pool.allocate(width: 64, height: 32, reservation: reservation)
      }
      XCTAssertThrowsError(try pool.allocate(width: 64, height: 32, reservation: reservation))
      XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 262_144)
      withExtendedLifetime(held) {}
    }
  }

  // Catches mutating or recycling an outstanding surface while caching another geometry.
  func testDimensionChangePreservesOutstandingBufferContents() throws {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger)
    let old = try pool.allocate(width: 64, height: 32, reservation: reservation)
    try fill(old, value: 71)
    let oldID = try surfaceID(old)
    let replacement = try pool.allocate(width: 128, height: 32, reservation: 65_536)
    try fill(replacement, value: 193)
    XCTAssertNotEqual(try surfaceID(replacement), oldID)
    XCTAssertEqual(try firstByte(old), 71)
    XCTAssertEqual(CVPixelBufferGetWidth(old), 64)
    XCTAssertEqual(CVPixelBufferGetWidth(replacement), 128)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 98_304)
    XCTAssertEqual(ledger.snapshot.reservations, 2)
    pool.trim()
    XCTAssertEqual(try firstByte(old), 71)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    withExtendedLifetime(replacement) {}
  }

  // Catches early cache lease release, forgotten trim/deinit release, and reservation churn.
  func testCacheBudgetPersistsUntilTrimAndDeinitializationReleasesIt() throws {
    let ledger = MonitorAdmissionLedger()
    var pool: MonitorCompositePool? = MonitorCompositePool(ledger: ledger)
    try autoreleasepool {
      _ = try pool!.allocate(width: 64, height: 32, reservation: reservation)
    }
    XCTAssertEqual(ledger.snapshot.retainedBytes, 32_768)
    XCTAssertEqual(ledger.snapshot.reservations, 1)
    try autoreleasepool {
      _ = try pool!.allocate(width: 64, height: 32, reservation: reservation)
    }
    XCTAssertEqual(ledger.snapshot.retainedBytes, 32_768)
    XCTAssertEqual(pool!.statsSnapshot().reuses, 1)
    pool!.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(pool!.statsSnapshot().poolCapacityBytes, 0)
    _ = try pool!.allocate(width: 64, height: 32, reservation: reservation)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 32_768)
    pool = nil
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
  }

  // Catches using clean reserve or allocating before obtaining a cache lease.
  func testInsufficientCacheBudgetRejectsWithoutLeakingReservation() {
    let ledger = MonitorAdmissionLedger(maximumBytes: 60_000, cleanReserveBytes: 30_000)
    let pool = MonitorCompositePool(ledger: ledger)
    XCTAssertThrowsError(try pool.allocate(width: 64, height: 32, reservation: reservation)) {
      XCTAssertEqual($0 as? MonitorCompositePool.AllocationError, .budgetExceeded)
    }
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 0)
    XCTAssertEqual(pool.statsSnapshot().allocations, 0)
    XCTAssertEqual(pool.statsSnapshot().poolFailures, 1)
  }

  // Catches an uncharged provisional allocation even when a reusable surface exists.
  func testReuseAlsoRequiresProvisionalBudgetWithoutLosingCacheCharge() throws {
    let ledger = MonitorAdmissionLedger(maximumBytes: 32_768, cleanReserveBytes: 0)
    let pool = MonitorCompositePool(ledger: ledger)
    try autoreleasepool {
      _ = try pool.allocate(width: 64, height: 32, reservation: reservation)
    }
    XCTAssertThrowsError(try pool.allocate(width: 64, height: 32, reservation: reservation)) {
      XCTAssertEqual($0 as? MonitorCompositePool.AllocationError, .budgetExceeded)
    }
    XCTAssertEqual(ledger.snapshot.retainedBytes, 32_768)
    XCTAssertEqual(pool.statsSnapshot().allocations, 1)
    XCTAssertEqual(pool.statsSnapshot().reuses, 0)
    pool.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
  }

  // Catches accepting real padded storage larger than the caller's budget bound.
  func testActualAllocationOverReservationIsRejectedAndCacheIsReleased() {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger)
    XCTAssertThrowsError(try pool.allocate(width: 64, height: 32, reservation: 1)) {
      guard let error = $0 as? MonitorCompositePool.AllocationError,
        case .allocationExceedsReservation(let actual, let reserved) = error
      else { return XCTFail("Expected actual allocation size rejection, got \($0)") }
      XCTAssertGreaterThan(actual, 1)
      XCTAssertEqual(reserved, 1)
    }
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 0)
    XCTAssertEqual(pool.statsSnapshot().poolFailures, 1)
  }

  // Catches reusing a backing under the wrong reservation at equal dimensions.
  func testReservationChangeUsesIndependentCacheCharge() throws {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger)
    let first = try pool.allocate(width: 64, height: 32, reservation: reservation)
    let second = try pool.allocate(width: 64, height: 32, reservation: 16_384)
    XCTAssertNotEqual(try surfaceID(first), try surfaceID(second))
    XCTAssertEqual(ledger.snapshot.retainedBytes, 49_152)
    XCTAssertEqual(ledger.snapshot.reservations, 2)
    withExtendedLifetime((first, second)) {}
  }

  // Catches allocating a fresh backing on each mixed-resolution feed frame.
  func testAlternatingReleasedGeometriesReuseTwoBackingsAndDeinitReleasesBoth() throws {
    let ledger = MonitorAdmissionLedger()
    var pool: MonitorCompositePool? = MonitorCompositePool(ledger: ledger)
    var identifiers: [Int: IOSurfaceID] = [:]
    for index in 0..<10 {
      let width = index.isMultiple(of: 2) ? 64 : 128
      let bytes = index.isMultiple(of: 2) ? 32_768 : 65_536
      try autoreleasepool {
        let buffer = try pool!.allocate(width: width, height: 32, reservation: bytes)
        let identifier = try surfaceID(buffer)
        if let first = identifiers[width] {
          XCTAssertEqual(identifier, first)
        } else {
          identifiers[width] = identifier
        }
      }
    }
    XCTAssertEqual(pool!.statsSnapshot().allocations, 2)
    XCTAssertEqual(pool!.statsSnapshot().reuses, 8)
    XCTAssertEqual(pool!.statsSnapshot().poolCapacityBytes, 98_304)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 98_304)
    XCTAssertEqual(ledger.snapshot.reservations, 2)
    print("Alternating geometry cache: \(pool!.statsSnapshot())")
    pool = nil
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
  }

  // Catches retaining a third geometry or evicting the recently reused geometry.
  func testThirdGeometryEvictsLeastRecentlyUsedEntry() throws {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger)
    try autoreleasepool { _ = try pool.allocate(width: 64, height: 32, reservation: 32_768) }
    try autoreleasepool { _ = try pool.allocate(width: 128, height: 32, reservation: 65_536) }
    try autoreleasepool { _ = try pool.allocate(width: 64, height: 32, reservation: 32_768) }
    try autoreleasepool { _ = try pool.allocate(width: 256, height: 32, reservation: 131_072) }
    XCTAssertEqual(pool.statsSnapshot().allocations, 3)
    XCTAssertEqual(pool.statsSnapshot().reuses, 1)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 163_840)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 163_840)
    XCTAssertEqual(ledger.snapshot.reservations, 2)
    try autoreleasepool { _ = try pool.allocate(width: 64, height: 32, reservation: 32_768) }
    XCTAssertEqual(pool.statsSnapshot().allocations, 3)
    XCTAssertEqual(pool.statsSnapshot().reuses, 2)
    try autoreleasepool { _ = try pool.allocate(width: 128, height: 32, reservation: 65_536) }
    XCTAssertEqual(pool.statsSnapshot().allocations, 4)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 98_304)
    XCTAssertEqual(ledger.snapshot.reservations, 2)
    pool.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
  }

  // Catches applying the eight-buffer limit per geometry rather than across both entries.
  func testEightHeldBuffersAcrossTwoGeometriesEnforceGlobalCapacityAndReuse() throws {
    let pool = MonitorCompositePool(ledger: MonitorAdmissionLedger())
    let first = try (0..<4).map { _ in
      try pool.allocate(width: 64, height: 32, reservation: 32_768)
    }
    var second = try (0..<4).map { _ in
      try pool.allocate(width: 128, height: 32, reservation: 65_536)
    }
    XCTAssertEqual(Set(try (first + second).map(surfaceID)).count, 8)
    for (width, bytes) in [(64, 32_768), (128, 65_536)] {
      XCTAssertThrowsError(try pool.allocate(width: width, height: 32, reservation: bytes)) {
        XCTAssertEqual($0 as? MonitorCompositePool.AllocationError,
          .allocationFailed(kCVReturnWouldExceedAllocationThreshold))
      }
    }
    XCTAssertEqual(pool.statsSnapshot().allocations, 8)
    XCTAssertEqual(pool.statsSnapshot().poolFailures, 2)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 393_216)
    second.removeLast()
    let reused = try pool.allocate(width: 128, height: 32, reservation: 65_536)
    XCTAssertEqual(pool.statsSnapshot().allocations, 8)
    XCTAssertEqual(pool.statsSnapshot().reuses, 1)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 393_216)
    print("Global geometry cache: \(pool.statsSnapshot())")
    withExtendedLifetime((first, second, reused)) {}
  }

  // Catches refusing a new geometry when a sole old entry fills the cache, or releasing
  // caller ownership when retiring its backing cache. Retired live buffers are separately charged.
  func testNewGeometryCanRetireFullOldEntryWithoutReleasingCallerBudgets() throws {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger)
    var held = try (0..<8).map { _ in try ownedFrame(pool: pool, ledger: ledger) }
    try fill(held[0].pixelBuffer, value: 71)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 524_288)
    let next = try pool.allocate(width: 128, height: 32, reservation: 65_536)
    XCTAssertEqual(pool.statsSnapshot().poolCapacityBytes, 65_536)
    XCTAssertEqual(pool.statsSnapshot().allocations, 9)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 327_680)
    XCTAssertEqual(try firstByte(held[0].pixelBuffer), 71)
    pool.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 262_144)
    held.removeAll()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
    withExtendedLifetime(next) {}
  }

  // Catches signed overflow, invalid dimensions, and allocating a zero-byte reservation.
  func testInvalidRequestsAndCapacityOverflowDoNotLeak() {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger)
    for (width, height, bytes) in [(0, 32, 32_768), (64, -1, 32_768), (64, 32, 0),
      (64, 32, Int.max)]
    {
      XCTAssertThrowsError(try pool.allocate(width: width, height: height, reservation: bytes))
    }
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
  }

  // Catches parallel pool creation, lost counters, and exceeding configured live capacity.
  func testConcurrentAllocationSerializesPoolCreationAndCapacity() throws {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger, maximumBuffers: 2)
    let results = ConcurrentBuffers()
    DispatchQueue.concurrentPerform(iterations: 20) { _ in
      do {
        let buffer = try pool.allocate(width: 64, height: 32, reservation: 32_768)
        results.append(buffer)
      } catch {
        results.recordFailure(error)
      }
    }
    let held = results.buffers
    XCTAssertEqual(held.count, 2)
    XCTAssertEqual(Set(try held.map(surfaceID)).count, 2)
    XCTAssertEqual(results.errors.count, 18)
    XCTAssertTrue(results.errors.allSatisfy {
      ($0 as? MonitorCompositePool.AllocationError) ==
        .allocationFailed(kCVReturnWouldExceedAllocationThreshold)
    })
    XCTAssertEqual(pool.statsSnapshot().allocations, 2)
    XCTAssertEqual(pool.statsSnapshot().poolFailures, 18)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 65_536)
    XCTAssertEqual(ledger.snapshot.reservations, 2)
    pool.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    withExtendedLifetime(held) {}
  }

  // Catches clearing a live frozen frame's budget when trimming the cached pool.
  func testFrozenBufferKeepsCallerBudgetAfterCacheTrim() throws {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger, maximumBuffers: 1)
    var frame: MonitorOwnedFrame? = try ownedFrame(pool: pool, ledger: ledger)
    var frozen: CVPixelBuffer? = frame!.pixelBuffer
    frame = nil
    XCTAssertNotNil(frozen)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 65_536)
    XCTAssertThrowsError(try pool.allocate(width: 64, height: 32, reservation: reservation))
    pool.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 32_768)
    frozen = nil
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
  }

  // Characterizes Core Video's attachment retention and catches stale caller leases on reuse.
  func testReusingIdleBufferClearsPreviousCallerBudgetAttachment() throws {
    let ledger = MonitorAdmissionLedger()
    let pool = MonitorCompositePool(ledger: ledger, maximumBuffers: 1)
    try autoreleasepool {
      let frame = try ownedFrame(pool: pool, ledger: ledger)
      XCTAssertNotNil(frame)
      XCTAssertEqual(ledger.snapshot.retainedBytes, 65_536)
    }
    print("Composite pool attachment idle retainedBytes=\(ledger.snapshot.retainedBytes)")
    let reused = try pool.allocate(width: 64, height: 32, reservation: reservation)
    XCTAssertNil(CVBufferCopyAttachment(reused, "com.ultracam.monitor.budget" as CFString, nil))
    XCTAssertEqual(ledger.snapshot.retainedBytes, 32_768)
    XCTAssertEqual(pool.statsSnapshot().reuses, 1)
    pool.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    withExtendedLifetime(reused) {}

    try autoreleasepool {
      let frame = try ownedFrame(pool: pool, ledger: ledger)
      XCTAssertNotNil(frame)
    }
    pool.trim()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.reservations, 0)
  }

  private func ownedFrame(pool: MonitorCompositePool, ledger: MonitorAdmissionLedger) throws
    -> MonitorOwnedFrame
  {
    let target = MonitorTargetID("pool-caller")
    let memory = try XCTUnwrap(
      ledger.tryAcquire(target: target, generation: 1, kind: .presentation, bytes: reservation))
    let buffer = try pool.allocate(width: 64, height: 32, reservation: reservation)
    let stamp = MonitorFrameStamp(
      target: target, generation: 1, sequence: 1, sourcePTS: 0, hostTime: 0,
      configurationRevision: 1)
    return MonitorOwnedFrame(stamp: stamp, pixelBuffer: buffer) { memory.release() }
  }

  private func surfaceID(_ buffer: CVPixelBuffer) throws -> IOSurfaceID {
    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer))
    return IOSurfaceGetID(surface.takeUnretainedValue())
  }

  private func fill(_ buffer: CVPixelBuffer, value: Int32) throws {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), value, CVPixelBufferGetDataSize(buffer))
  }

  private func firstByte(_ buffer: CVPixelBuffer) throws -> UInt8 {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).load(as: UInt8.self)
  }
}

private final class ConcurrentBuffers: @unchecked Sendable {
  private let lock = NSLock()
  private var held: [CVPixelBuffer] = []
  private var failures: [Error] = []
  var buffers: [CVPixelBuffer] {
    lock.lock()
    defer { lock.unlock() }
    return held
  }
  var errors: [Error] {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }
  func append(_ buffer: CVPixelBuffer) {
    lock.lock()
    held.append(buffer)
    lock.unlock()
  }
  func recordFailure(_ error: Error) {
    lock.lock()
    failures.append(error)
    lock.unlock()
  }
}
