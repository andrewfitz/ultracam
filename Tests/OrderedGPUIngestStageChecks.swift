import Foundation
import XCTest

@objcMembers final class OrderedGPUIngestStageChecks: XCTestCase {
  func testMinimumSlotsRelaxesOnlyDurationForSlowSources() {
    let state = OrderedIngestTestState()
    let stage = OrderedGPUIngestStage<Int, Int>(capacity: 8, minimumSlots: 3, maximumBytes: 12,
      maximumDuration: 0.5, weight: { input in .init(bytes: input, duration: 1) },
      transform: { _, done in state.lock.lock(); state.complete = done; state.lock.unlock() }, emit: { _ in })
    XCTAssertFalse(stage.enqueue(13), "Oversized first allocation must refuse")
    XCTAssertTrue(stage.enqueue(4))
    XCTAssertTrue(stage.enqueue(4))
    XCTAssertTrue(stage.enqueue(4))
    XCTAssertFalse(stage.enqueue(0), "Fourth slow envelope exceeds duration")
    stage.cancel()
    state.lock.lock(); let complete = state.complete; state.complete = nil; state.lock.unlock()
    complete?(.success(4))
  }

  func testBytesAndDurationIncludeInFlightEnvelope() {
    let state = OrderedIngestTestState()
    let stage = OrderedGPUIngestStage<Int, Int>(capacity: 8, maximumBytes: 10,
      maximumDuration: 0.1, weight: { input in .init(bytes: input, duration: 0.04) },
      transform: { _, done in state.lock.lock(); state.complete = done; state.lock.unlock() }, emit: { _ in })
    XCTAssertTrue(stage.enqueue(6))
    XCTAssertFalse(stage.enqueue(5), "Active GPU allocation counts against bytes")
    XCTAssertTrue(stage.enqueue(4))
    XCTAssertFalse(stage.enqueue(0), "Active and pending media duration count")
    stage.cancel()
    state.lock.lock(); let complete = state.complete; state.complete = nil; state.lock.unlock()
    complete?(.success(6))
  }

  func testEventsWaitForGPUAndCapacityIsExplicit() {
    let state = OrderedIngestTestState()
    let done = expectation(description: "ordered envelopes"); done.expectedFulfillmentCount = 2
    let stage = OrderedGPUIngestStage<Int, Int>(capacity: 2, transform: { input, complete in
      state.lock.lock(); state.started.append(input)
      if input == 1 { state.complete = complete; state.lock.unlock() }
      else { state.lock.unlock(); complete(.success(input)) }
    }, emit: { result in
      if case .success(let value) = result { state.lock.lock(); state.emitted.append(value); state.lock.unlock() }
      done.fulfill()
    })
    XCTAssertTrue(stage.enqueue(1))
    XCTAssertTrue(stage.enqueue(2))
    XCTAssertFalse(stage.enqueue(3))
    state.lock.lock(); let started = state.started; let complete = state.complete; state.lock.unlock()
    XCTAssertEqual(started, [1])
    complete?(.success(1))
    wait(for: [done], timeout: 2)
    state.lock.lock(); let emitted = state.emitted; state.lock.unlock()
    XCTAssertEqual(emitted, [1, 2])
  }
}

private final class OrderedIngestTestState: @unchecked Sendable {
  let lock = NSLock()
  var started: [Int] = []
  var emitted: [Int] = []
  var complete: (@Sendable (Result<Int, Error>) -> Void)?
}
