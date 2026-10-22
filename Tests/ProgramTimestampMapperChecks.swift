import CoreMedia
import XCTest

@objcMembers final class ProgramTimestampMapperChecks: XCTestCase {
  private func time(_ value: Int64, _ timescale: Int32 = 60_000, epoch: Int64 = 0) -> CMTime {
    CMTime(value: value, timescale: timescale, flags: .valid, epoch: epoch)
  }

  private func frame(_ source: String, _ pts: Int64, duration: Int64 = 1,
                     timescale: Int32 = 60_000, epoch: Int64 = 0) -> ProgramSourceFrame<String> {
    ProgramSourceFrame(sourceID: source, sourceTime: time(pts, timescale, epoch: epoch),
      duration: time(duration, timescale))
  }

  private func mapped(_ result: Result<ProgramMappedFrame<String>, ProgramTimestampMappingError>,
                     file: StaticString = #filePath, line: UInt = #line) -> ProgramMappedFrame<String>? {
    guard case let .success(value) = result else {
      XCTFail("Expected mapped frame", file: file, line: line)
      return nil
    }
    return value
  }

  private func failure(_ result: Result<ProgramMappedFrame<String>, ProgramTimestampMappingError>,
                       equals expected: ProgramTimestampMappingError,
                       file: StaticString = #filePath, line: UInt = #line) {
    guard case let .failure(error) = result else {
      return XCTFail("Expected mapping failure", file: file, line: line)
    }
    XCTAssertEqual(error, expected, file: file, line: line)
  }

  func testFirstFrameAndSourceTimelineRemainMonotonic() {
    var mapper = ProgramTimestampMapper<String>(programTimescale: 60_000, selectedSource: "A")
    let first = mapped(mapper.map(frame("A", 10)))!
    let second = mapped(mapper.map(frame("A", 11)))!
    XCTAssertEqual(first.programTime, time(0))
    XCTAssertEqual(second.programTime, time(1))
    XCTAssertEqual(mapper.lastProgramTime, time(1))
  }

  func testCutResetsSourceOriginAtNextProgramBoundary() {
    var mapper = ProgramTimestampMapper<String>(selectedSource: "A")
    _ = mapped(mapper.map(frame("A", 500)))
    let prior = mapped(mapper.map(frame("A", 501)))!
    mapper.cut(to: "B")
    let cut = mapped(mapper.map(frame("B", 0)))!
    XCTAssertEqual(cut.programTime, CMTimeAdd(prior.programTime, prior.programDuration))
    XCTAssertGreaterThan(CMTimeCompare(cut.programTime, prior.programTime), 0)
  }

  func testRejectsForeignEpochTimebaseBackwardsAndInvalidDuration() {
    var mapper = ProgramTimestampMapper<String>(selectedSource: "A")
    failure(mapper.map(frame("A", 0, epoch: 1)), equals: .sourceEpochUnsupported(1))
    failure(mapper.map(frame("A", 0, duration: 0)), equals: .invalidSourceDuration)
    XCTAssertNotNil(mapped(mapper.map(frame("A", 0))))
    failure(mapper.map(frame("A", 0)), equals: .sourceTimestampRegressed)
    failure(mapper.map(frame("A", 2, timescale: 30_000)),
      equals: .sourceTimebaseChanged(expected: 60_000, actual: 30_000))
  }

  func testFailedFirstFrameDoesNotConsumeSourceOrProgramOrigin() {
    var mapper = ProgramTimestampMapper<String>(programTimescale: 60_000,
      selectedSource: "A")
    // One microsecond rounds to zero at the Program timescale, so this frame
    // is rejected. The next valid frame must still become the timeline origin.
    failure(mapper.map(frame("A", 1_000, duration: 1, timescale: 1_000_000)),
      equals: .programTimestampNotMonotonic)
    let accepted = mapped(mapper.map(frame("A", 2_000, duration: 1_000,
      timescale: 1_000_000)))!
    XCTAssertEqual(accepted.programTime, time(0))
  }

  func testOnAirSourceKeepsFlowingUntilTheCutLands() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B") else {
      return XCTFail("A valid target should queue")
    }
    guard case let .accepted(onAir) = scheduler.ingest(frame("A", 0)) else {
      return XCTFail("The on-air source must not freeze while a cut is pending")
    }
    guard case let .cutApplied(mapped, flushStaleFrames) = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("Target frame should apply the pending cut")
    }
    XCTAssertFalse(flushStaleFrames, "Frames already on air precede the cut and are kept")
    XCTAssertEqual(mapped.sourceID, "B")
    XCTAssertEqual(mapped.programTime, CMTimeAdd(onAir.programTime, onAir.programDuration))
    XCTAssertFalse(scheduler.hasPendingCut)
    XCTAssertNil(scheduler.takeAbandonedCut())
  }

  func testLiveTargetThatNeverQualifiesExpiresAndIsReported() {
    var now: TimeInterval = 10
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setClock { now }
    scheduler.pendingCutTimeout = 2
    guard case .queued = scheduler.requestCut(to: "B", noEarlierThan: time(1_000_000)) else {
      return XCTFail("A valid target should queue")
    }
    guard case .skipped(.staleQueuedFrame) = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("A target frame before the bound must not land the cut")
    }
    guard case .accepted = scheduler.ingest(frame("A", 0)) else {
      return XCTFail("The on-air source keeps flowing")
    }
    now = 12
    guard case .accepted = scheduler.ingest(frame("A", 1_001)) else {
      return XCTFail("The on-air source keeps flowing after expiry")
    }
    XCTAssertFalse(scheduler.hasPendingCut)
    XCTAssertEqual(scheduler.selectedSource, "A")
    guard let abandoned = scheduler.takeAbandonedCut() else { return XCTFail("Expiry must be reported") }
    XCTAssertEqual(abandoned.0, "B")
    XCTAssertEqual(abandoned.1, .expired)
    XCTAssertNil(scheduler.takeAbandonedCut(), "Each abandoned cut is reported once")
  }

  func testCutToStartingSourceWaitsForItsFirstFrame() {
    var now: TimeInterval = 10
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setClock { now }
    scheduler.pendingCutTimeout = 2
    scheduler.startingCutTimeout = 30
    scheduler.setSource("B", available: true)  // started; "Opening UltraStudio…"
    XCTAssertEqual(scheduler.readiness(of: "B"), .starting)
    guard case .queued = scheduler.requestCut(to: "B") else {
      return XCTFail("A starting target should queue")
    }
    var pts: Int64 = 0
    for second in stride(from: 10.0, through: 30.0, by: 0.5) {
      now = second
      guard case .accepted = scheduler.ingest(frame("A", pts)) else {
        return XCTFail("The on-air source keeps flowing while the target opens")
      }
      pts += 1_001
    }
    XCTAssertEqual(scheduler.pendingCut, "B", "Opening can take far longer than the live timeout")
    XCTAssertNil(scheduler.takeAbandonedCut())
    guard case let .cutApplied(mapped, _) = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("The target's first frame lands the cut")
    }
    XCTAssertEqual(mapped.sourceID, "B")
    XCTAssertEqual(scheduler.selectedSource, "B")
  }

  func testCutToStartingSourceWithNoSignalExpiresAtTheStartingBound() {
    var now: TimeInterval = 10
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setClock { now }
    scheduler.pendingCutTimeout = 2
    scheduler.startingCutTimeout = 8
    scheduler.setSource("B", available: true)  // opened, but no HDMI signal
    guard case .queued = scheduler.requestCut(to: "B") else { return XCTFail("A starting target should queue") }
    now = 17.9
    XCTAssertFalse(scheduler.expirePendingCutIfNeeded(), "Still inside the starting bound")
    XCTAssertEqual(scheduler.pendingCut, "B")
    now = 18
    guard case .accepted = scheduler.ingest(frame("A", 0)) else {
      return XCTFail("The on-air source keeps flowing")
    }
    XCTAssertFalse(scheduler.hasPendingCut, "A camera that never sends a frame can't hold the cut forever")
    XCTAssertEqual(scheduler.takeAbandonedCut()?.1, .expired)
    XCTAssertEqual(scheduler.selectedSource, "A")
  }

  func testStartingTargetThatSendsItsFirstFrameGetsTheLiveTimeout() {
    var now: TimeInterval = 0
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setClock { now }
    scheduler.pendingCutTimeout = 2
    scheduler.startingCutTimeout = 8
    scheduler.setSource("B", available: true)
    _ = scheduler.requestCut(to: "B", noEarlierThan: time(1_000_000))
    now = 5
    guard case .skipped(.staleQueuedFrame) = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("The first frame is before the cut bound")
    }
    now = 6.9
    XCTAssertFalse(scheduler.expirePendingCutIfNeeded(), "Live now: two seconds from its first frame")
    now = 7
    XCTAssertTrue(scheduler.expirePendingCutIfNeeded())
  }

  func testRestartedOnAirSourceIsReanchoredNotRejected() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setSource("A", available: true)
    guard case let .accepted(first) = scheduler.ingest(frame("A", 50_050)) else { return XCTFail("on air") }
    guard case let .accepted(second) = scheduler.ingest(frame("A", 51_051)) else { return XCTFail("on air") }
    // Stopped and started again: the source clock starts over at zero.
    scheduler.setSource("A", available: false)
    scheduler.setSource("A", available: true)
    guard case let .accepted(restarted) = scheduler.ingest(frame("A", 0)) else {
      return XCTFail("A restarted on-air source must not be skipped as a timestamp regression")
    }
    XCTAssertEqual(first.programTime, .zero)
    XCTAssertEqual(restarted.programTime, CMTimeAdd(second.programTime, second.programDuration),
      "It continues at the next Program boundary")
  }

  func testOnAirClockRestartWhileLiveResumesAtTheNextBoundary() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setSource("A", available: true)
    scheduler.setSource("B", available: true)
    var last: ProgramMappedFrame<String>?
    for pts in stride(from: Int64(50_050), to: 55_055, by: 1_001) {
      guard case let .accepted(mapped) = scheduler.ingest(frame("A", pts, duration: 1_001)) else {
        return XCTFail("on air")
      }
      last = mapped
    }
    guard let before = last else { return XCTFail("on air") }
    _ = scheduler.requestCut(to: "B")
    // An HDMI mode change restarts the streams: the source never leaves
    // producing, and its stream time starts over near zero.
    XCTAssertEqual(scheduler.readiness(of: "A"), .producing)
    var times: [CMTime] = []
    for pts in stride(from: Int64(0), to: 3_003, by: 1_001) {
      guard case let .accepted(mapped) = scheduler.ingest(frame("A", pts, duration: 1_001)) else {
        return XCTFail("A restarted stream clock on air must not be skipped as a regression")
      }
      times.append(mapped.programTime)
    }
    XCTAssertEqual(times, (1...3).map { CMTimeAdd(before.programTime, time(Int64($0) * 1_001)) },
      "The first restarted frame takes the next Program boundary; the rest follow it")
    XCTAssertEqual(scheduler.pendingCut, "B", "A pending cut to another camera survives the restart")
    guard case .skipped(.invalidTimestamp(.sourceTimestampRegressed)) =
      scheduler.ingest(frame("A", 2_002, duration: 1_001)) else {
      return XCTFail("A duplicate timestamp is not a restart and stays a counted skip")
    }
    guard case let .cutApplied(cut, _) = scheduler.ingest(frame("B", 0, duration: 1_001)) else {
      return XCTFail("The pending cut still lands")
    }
    XCTAssertEqual(cut.programTime, CMTimeAdd(times[2], time(1_001)))
  }

  func testRebuiltSchedulerKeepsOnAirReadinessAndThePendingCut() {
    var now: TimeInterval = 0
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setClock { now }
    scheduler.pendingCutTimeout = 2
    scheduler.setSource("A", available: true)
    scheduler.setSource("B", available: true)
    _ = scheduler.ingest(frame("A", 0, duration: 1_001))
    _ = scheduler.requestCut(to: "B")
    var rebuilt = ProgramCutScheduler<String>(selectedSource: "A")
    rebuilt.carryTimeline(from: scheduler, keeping: ["A", "B", "C"])
    XCTAssertTrue(rebuilt.isOnAir, "The on-air source is still on air after a rebuild")
    XCTAssertEqual(rebuilt.pendingCut, "B")
    XCTAssertNil(rebuilt.takeAbandonedCut())
    now = 1.9
    XCTAssertFalse(rebuilt.expirePendingCutIfNeeded(), "The carried cut keeps its own expiry clock")
    guard case let .cutApplied(cut, _) = rebuilt.ingest(frame("B", 0, duration: 1_001)) else {
      return XCTFail("The carried cut lands")
    }
    XCTAssertEqual(cut.programTime, time(1_001))

    var removed = ProgramCutScheduler<String>(selectedSource: "A")
    removed.carryTimeline(from: scheduler, keeping: ["A"])
    XCTAssertFalse(removed.hasPendingCut)
    XCTAssertEqual(removed.takeAbandonedCut()?.0, "B", "A cut to a removed camera is reported")
  }

  func testCutToStartingSourceThatFailsIsAbandonedVisibly() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setSource("B", available: true)
    guard case .queued = scheduler.requestCut(to: "B") else {
      return XCTFail("A starting target should queue")
    }
    scheduler.setSource("B", available: false)  // failed to start
    XCTAssertFalse(scheduler.hasPendingCut)
    XCTAssertEqual(scheduler.selectedSource, "A", "Selection stays on what is on air")
    guard let abandoned = scheduler.takeAbandonedCut() else { return XCTFail("Failure must be reported") }
    XCTAssertEqual(abandoned.0, "B")
    XCTAssertEqual(abandoned.1, .targetUnavailable)
  }

  func testCarriedTimelineDoesNotRestartAtZero() {
    var mapper = ProgramTimestampMapper<String>(programTimescale: 60_000, selectedSource: "A")
    let first = mapped(mapper.map(frame("A", 0)))!
    var rebuilt = ProgramTimestampMapper<String>(programTimescale: 60_000, selectedSource: "A")
    rebuilt.carryTimeline(from: mapper)
    let next = mapped(rebuilt.map(frame("A", 0)))!
    XCTAssertGreaterThan(CMTimeCompare(next.programTime, first.programTime), 0)
  }

  func testRapidCutsCoalesceToLatestTarget() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B") else {
      return XCTFail("A valid target should queue")
    }
    guard case .coalesced(previous: "B", replacement: "C") = scheduler.requestCut(to: "C") else {
      return XCTFail("Rapid cuts should replace the pending target")
    }
    if case .skipped(.nonSelectedSource) = scheduler.ingest(frame("B", 0)) {} else {
      XCTFail("An intermediate rapid-cut target must not be emitted")
    }
    guard case let .cutApplied(mapped, _) = scheduler.ingest(frame("C", 0)) else {
      return XCTFail("Latest rapid-cut target should be selected")
    }
    XCTAssertEqual(mapped.sourceID, "C")
  }

  func testInvalidPendingTargetDoesNotSwitchSelection() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B") else {
      return XCTFail("A valid target should queue")
    }
    guard case .skipped(.invalidTimestamp(.sourceEpochUnsupported(1))) =
      scheduler.ingest(frame("B", 0, epoch: 1)) else {
      return XCTFail("Invalid target frame should be skipped")
    }
    XCTAssertEqual(scheduler.selectedSource, "A")
    XCTAssertTrue(scheduler.hasPendingCut)
    guard case .cutApplied = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("A later valid target frame should still apply the cut")
    }
  }

  func testMissingSourcesAreRejectedAndPendingTargetIsDropped() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    scheduler.setSource("B", available: false)
    guard case .rejectedMissingSource = scheduler.requestCut(to: "B") else {
      return XCTFail("Unavailable target should be rejected")
    }
    guard case .skipped(.missingSource) = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("Frames from an unavailable source should be skipped")
    }
    guard case let .accepted(mapped) = scheduler.ingest(frame("A", 0)) else {
      return XCTFail("The selected source should continue")
    }
    XCTAssertEqual(mapped.programTime, time(0))
    XCTAssertFalse(scheduler.hasPendingCut)
  }

  func testUnavailablePendingTargetClearsItsEarliestCutTime() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B", noEarlierThan: time(10)) else {
      return XCTFail("A valid target should queue")
    }
    XCTAssertEqual(scheduler.pendingCutTime, time(10))
    scheduler.setSource("B", available: false)
    _ = scheduler.ingest(frame("A", 0))
    XCTAssertNil(scheduler.pendingCutTime)
  }

  func testInvalidEarliestCutTimeCannotBlockTargetFrame() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B", noEarlierThan: .invalid) else {
      return XCTFail("An invalid lower bound must not reject a valid target")
    }
    guard case .cutApplied = scheduler.ingest(frame("B", 0)) else {
      return XCTFail("Invalid timing metadata should be ignored safely")
    }
  }

  func testNegativeTargetTimestampIsInvalidRatherThanStale() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B", noEarlierThan: time(10)) else {
      return XCTFail("A valid target should queue")
    }
    guard case .skipped(.invalidTimestamp(.invalidSourceTimestamp)) =
      scheduler.ingest(frame("B", -1)) else {
      return XCTFail("Negative target timestamps are malformed, not stale")
    }
    XCTAssertTrue(scheduler.hasPendingCut)
  }

  func testEpochTargetTimestampIsReportedBeforeCutBoundaryComparison() {
    var scheduler = ProgramCutScheduler<String>(selectedSource: "A")
    guard case .queued = scheduler.requestCut(to: "B", noEarlierThan: time(10)) else {
      return XCTFail("A valid target should queue")
    }
    guard case .skipped(.invalidTimestamp(.sourceEpochUnsupported(1))) =
      scheduler.ingest(frame("B", 0, epoch: 1)) else {
      return XCTFail("Foreign timestamp epochs must not be classified as stale")
    }
    XCTAssertTrue(scheduler.hasPendingCut)
  }

  static let allTests = [
    ("first frame and monotonic source timeline", testFirstFrameAndSourceTimelineRemainMonotonic),
    ("cut resets source origin", testCutResetsSourceOriginAtNextProgramBoundary),
    ("invalid source timing", testRejectsForeignEpochTimebaseBackwardsAndInvalidDuration),
    ("failed first frame is transactional", testFailedFirstFrameDoesNotConsumeSourceOrProgramOrigin),
    ("on-air source flows until the cut", testOnAirSourceKeepsFlowingUntilTheCutLands),
    ("live target expiry is reported", testLiveTargetThatNeverQualifiesExpiresAndIsReported),
    ("starting target waits for first frame", testCutToStartingSourceWaitsForItsFirstFrame),
    ("failed starting target is abandoned", testCutToStartingSourceThatFailsIsAbandonedVisibly),
    ("no-signal starting target expires", testCutToStartingSourceWithNoSignalExpiresAtTheStartingBound),
    ("first frame switches to live timeout", testStartingTargetThatSendsItsFirstFrameGetsTheLiveTimeout),
    ("restarted on-air source re-anchors", testRestartedOnAirSourceIsReanchoredNotRejected),
    ("on-air clock restart while live", testOnAirClockRestartWhileLiveResumesAtTheNextBoundary),
    ("rebuild keeps readiness and pending cut", testRebuiltSchedulerKeepsOnAirReadinessAndThePendingCut),
    ("rapid cuts coalesce", testRapidCutsCoalesceToLatestTarget),
    ("invalid target preserves selection", testInvalidPendingTargetDoesNotSwitchSelection),
    ("missing sources", testMissingSourcesAreRejectedAndPendingTargetIsDropped),
    ("unavailable target clears cut time", testUnavailablePendingTargetClearsItsEarliestCutTime),
    ("negative target timestamp", testNegativeTargetTimestampIsInvalidRatherThanStale),
    ("epoch target timestamp", testEpochTargetTimestampIsReportedBeforeCutBoundaryComparison),
  ]
}
