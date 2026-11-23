import Foundation
import XCTest

@objcMembers final class OrderedGPUIngestStageChecks: XCTestCase {
  func testHalfSecondBudgetAcceptsTwentyFiveFramesAtFiftyFPS() {
    let stage = OrderedGPUIngestStage<Int, Int>(capacity: 32, maximumDuration: 0.5,
      weight: { _ in .init(bytes: 0, duration: 1.0 / 50) },
      transform: { _, _ in }, emit: { _ in })
    for index in 0..<25 { XCTAssertTrue(stage.enqueue(index)) }
    XCTAssertFalse(stage.enqueue(25))
    stage.cancel()
  }

  func testDrainedStageAcceptsFrameAtExactDurationLimit() {
    let state = OrderedIngestTestState()
    let drained = expectation(description: "both inputs emitted")
    drained.expectedFulfillmentCount = 2
    let stage = OrderedGPUIngestStage<Double, Int>(capacity: 2, maximumDuration: 0.2,
      weight: { .init(bytes: 0, duration: $0) }, transform: { input, done in
        if input == 0.05 {
          state.lock.withLock { state.complete = done }
        } else {
          done(.success(input == 0.15 ? 1 : 2))
        }
      }, emit: { result in
        if case .success(1) = result { drained.fulfill() }
      })
    XCTAssertTrue(stage.enqueue(0.05))
    XCTAssertTrue(stage.enqueue(0.15))
    let complete = state.lock.withLock {
      let saved = state.complete
      state.complete = nil
      return saved
    }
    complete?(.success(1))
    wait(for: [drained], timeout: 2)
    XCTAssertTrue(stage.enqueue(0.2))
    stage.cancel()
  }

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

  func testZeroDurationEnvelopesStillFitBehindSlowFrame() {
    let stage = OrderedGPUIngestStage<Double, Int>(capacity: 3, minimumSlots: 1, maximumDuration: 0.5,
      weight: { .init(bytes: 0, duration: $0) }, transform: { _, _ in }, emit: { _ in })
    defer { stage.cancel() }
    XCTAssertTrue(stage.enqueue(1))
    XCTAssertTrue(stage.enqueue(0), "Metadata adds no retained duration")
    XCTAssertFalse(stage.enqueue(0.01))
    XCTAssertTrue(stage.enqueue(0))
    XCTAssertFalse(stage.enqueue(0), "Metadata still counts against the slot limit")
  }

  func testCompletingLongFramePreservesPendingShortDuration() {
    let state = OrderedIngestTestState()
    let shortStarted = expectation(description: "Short frame entered the transform")
    let stage = OrderedGPUIngestStage<Double, Int>(capacity: 4, minimumSlots: 2, maximumDuration: 0.5,
      weight: { .init(bytes: 0, duration: $0) }, transform: { input, done in
        if input == 1e18 { state.lock.withLock { state.complete = done } }
        else { shortStarted.fulfill() }
      }, emit: { _ in })
    defer { stage.cancel() }
    XCTAssertTrue(stage.enqueue(1e18))
    XCTAssertTrue(stage.enqueue(0.25))
    let complete = state.lock.withLock {
      defer { state.complete = nil }
      return state.complete
    }
    complete?(.success(0))
    wait(for: [shortStarted], timeout: 2)
    XCTAssertTrue(stage.enqueue(0.20))
    XCTAssertFalse(stage.enqueue(0.10), "The short frame still consumes one quarter second")
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
