import Dispatch
import XCTest
@testable import MonitorKitAudio

final class ResetRequestConcurrencyTests: XCTestCase {
  func testHeldRestartWriterNeverBlocksProducerReadOrOtherRequests() {
    let requests = ResetRequests()
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    let readerFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      requests.requestRestart {
        entered.signal()
        resume.wait()
      }
      writerFinished.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global(qos: .userInteractive).async {
      // Identical handoff used at the beginning of each audio process call.
      _ = requests.load()
      requests.requestRestart()
      _ = requests.load()
      readerFinished.signal()
    }
    let completedWhileWriterHeld = readerFinished.wait(timeout: .now() + 0.25)
    // Release even on failure: a regression must fail, never hang the test run.
    resume.signal()
    XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(completedWhileWriterHeld, .success)
    if completedWhileWriterHeld != .success {
      XCTAssertEqual(readerFinished.wait(timeout: .now() + 2), .success)
    }
    let committed = requests.load()
    XCTAssertEqual(committed.all, 2)
    XCTAssertEqual(committed.discontinuities, 2)
  }

  func testConcurrentRestartsKeepBothEffectsCoherentWithoutLosingRequests() {
    let requests = ResetRequests()
    let writers = DispatchGroup()
    for _ in 0..<4 {
      writers.enter()
      DispatchQueue.global().async {
        for _ in 0..<1_000 { requests.requestRestart() }
        writers.leave()
      }
    }
    for _ in 0..<4_000 {
      let observed = requests.load()
      XCTAssertEqual(observed.all, observed.discontinuities)
    }
    XCTAssertEqual(writers.wait(timeout: .now() + 2), .success)
    let committed = requests.load()
    XCTAssertEqual(committed.all, 4_000)
    XCTAssertEqual(committed.discontinuities, 4_000)
  }

  func testRestartCoalescesAsOneReadingResetAndOneDiscontinuity() {
    let requests = ResetRequests()
    requests.requestAll()
    requests.requestDiscontinuity()
    requests.requestPeaks()
    requests.requestLoudness()
    requests.requestRestart()
    requests.requestRestart()
    let generation = requests.load()
    XCTAssertEqual(generation.all, 3)
    XCTAssertEqual(generation.discontinuities, 3)
    XCTAssertEqual(generation.total, 5)
    XCTAssertTrue(generation.resetsReadings(since: ResetGenerations()))
    XCTAssertFalse(generation.resetsReadings(since: generation))
  }
}
