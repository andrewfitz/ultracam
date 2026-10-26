import CoreMedia
import XCTest

@objcMembers final class SwitcherCoordinatorChecks: XCTestCase {
  private func feed(_ value: String) -> FeedID { FeedID(rawValue: value) }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000)
  }

  private func frame(_ source: FeedID, _ seconds: Double)
    -> ProgramSourceFrame<FeedID> {
    ProgramSourceFrame(sourceID: source, sourceTime: time(seconds),
      duration: time(1.0 / 30.0))
  }

  func testManualCutAppliesAtTargetFrameAndAcknowledgesSelection() {
    let a = feed("A")
    let b = feed("B")
    var coordinator = SwitcherCoordinator(feedIDs: [a, b])
    XCTAssertEqual(coordinator.selectedFeedID, a)
    guard case .queued = coordinator.requestManualCut(to: b) else {
      return XCTFail("manual cut should queue")
    }
    XCTAssertEqual(coordinator.selectedFeedID, a)
    if case let .cutApplied(mapped) = coordinator.ingest(frame(b, 0)) {
      XCTAssertEqual(mapped.sourceID, b)
    } else {
      XCTFail("target frame should apply the queued cut")
    }
    XCTAssertEqual(coordinator.selectedFeedID, b)
    XCTAssertTrue(coordinator.acknowledgeCut(to: b))
    XCTAssertFalse(coordinator.hasPendingCut)
  }

  func testFixedIntervalAdvancesInStableOrderAndSkipsUnhealthyFeed() {
    let a = feed("A")
    let b = feed("B")
    let c = feed("C")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 2, strategy: .fixedInterval)
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, b, c])
    coordinator.setFeedHealth(b, healthy: false)
    XCTAssertEqual(coordinator.evaluate(at: time(0)), .idle)
    XCTAssertEqual(coordinator.evaluate(at: time(1.9)), .idle)
    XCTAssertEqual(coordinator.evaluate(at: time(2)), .cutQueued(c))
    XCTAssertEqual(coordinator.pendingCut, c)
    _ = coordinator.ingest(frame(c, 0))
    XCTAssertEqual(coordinator.selectedFeedID, c)
  }

  func testDynamicAnalysisIsAnExplicitDisabledStub() {
    let a = feed("A")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 1, strategy: .dynamicAnalysis)
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, feed("B")])
    XCTAssertEqual(coordinator.statusMessage, "Coming later.")
    XCTAssertEqual(coordinator.evaluate(at: time(10)), .dynamicAnalysisUnavailable)
    XCTAssertNil(coordinator.pendingCut)
  }

  func testNaturalDirectorDecisionRequiresExactAcknowledgement() {
    let a = feed("A")
    let b = feed("B")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 5, strategy: .manual)
    var directorSettings = NaturalTalkingHeadDirectorSettings()
    directorSettings.minimumShotDuration = 0
    directorSettings.candidateDwell = 0
    directorSettings.boundaryWindow = 0.3
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, b],
      directorSettings: directorSettings)
    let cue = TranscriptCue(timeRange: CMTimeRange(start: time(0.8), end: time(1)),
      kind: .sentenceEnd, confidence: 1, isFinal: true)
    let input = NaturalTalkingHeadDirectorInput(mediaTime: time(1),
      currentCameraID: a.rawValue, anchorCameraID: a.rawValue,
      emphasisCameraID: b.rawValue, cameraHealth: [a.rawValue: true, b.rawValue: true],
      audioCues: [AudioCue(time: time(1), speechEnergy: 1, pauseDuration: 0,
        emphasis: 1, laughter: 0)], transcriptCues: [cue])
    guard let decision = coordinator.evaluateDirector(input) else {
      return XCTFail("director should emit a deterministic decision")
    }
    XCTAssertFalse(coordinator.acknowledgeCut(CutDecision(targetCameraID: b.rawValue,
      cutTime: time(1), confidence: decision.confidence, reason: "wrong")))
    XCTAssertTrue(coordinator.acknowledgeCut(decision))
    XCTAssertFalse(coordinator.acknowledgeCut(decision))
  }

  /// PROG-2: a fixed-interval cut that expires (or is cancelled by health)
  /// must release the automatic latch, or every later tick stays idle.
  func testExpiredAutomaticCutReleasesTheFixedIntervalLatch() {
    let a = feed("A")
    let b = feed("B")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 2, strategy: .fixedInterval)
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, b])
    var now: TimeInterval = 100
    coordinator.setPendingCutClock({ now }, timeout: 2)
    _ = coordinator.ingest(frame(a, 0))
    XCTAssertEqual(coordinator.evaluate(at: time(0)), .idle)
    XCTAssertEqual(coordinator.evaluate(at: time(2)), .cutQueued(b))
    XCTAssertTrue(coordinator.isAutomaticRequestPending)
    // B is live but never sends a frame that qualifies.
    _ = coordinator.ingest(ProgramSourceFrame(sourceID: b, sourceTime: time(1), duration: .invalid))
    now = 103
    XCTAssertEqual(coordinator.evaluate(at: time(3)), .idle)
    XCTAssertFalse(coordinator.hasPendingCut)
    XCTAssertFalse(coordinator.isAutomaticRequestPending, "Expiry releases the latch")
    guard let abandoned = coordinator.takeAbandonedCut() else { return XCTFail("Expiry is reported") }
    XCTAssertEqual(abandoned.0, b)
    XCTAssertEqual(abandoned.1, .expired)
    XCTAssertEqual(coordinator.selectedFeedID, a)
    XCTAssertEqual(coordinator.settings.selectedFeedID, a, "The saved selection is what is on air")
    XCTAssertEqual(coordinator.evaluate(at: time(5)), .cutQueued(b), "Fixed interval is not wedged")

    coordinator.setFeedHealth(b, healthy: false)
    XCTAssertFalse(coordinator.isAutomaticRequestPending, "A health drop releases the latch too")
    XCTAssertEqual(coordinator.takeAbandonedCut()?.1, .targetUnavailable)
  }

  /// A camera that started but has no signal never sends a frame. A cut to
  /// it is bounded by the starting timeout, then the latch releases.
  func testCutToStartedCameraWithNoSignalExpiresAndReleasesTheLatch() {
    let a = feed("A")
    let b = feed("B")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 2, strategy: .fixedInterval)
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, b])
    var now: TimeInterval = 100
    coordinator.setPendingCutClock({ now }, timeout: 2, startingTimeout: 8)
    coordinator.setFeedHealth(b, healthy: true)  // started: "Opening UltraStudio…"
    _ = coordinator.ingest(frame(a, 0))
    XCTAssertEqual(coordinator.evaluate(at: time(0)), .idle)
    XCTAssertEqual(coordinator.evaluate(at: time(2)), .cutQueued(b))
    now = 107
    XCTAssertEqual(coordinator.evaluate(at: time(9)), .idle)
    XCTAssertTrue(coordinator.isAutomaticRequestPending, "Within the starting bound the cut waits")
    now = 108
    XCTAssertEqual(coordinator.evaluate(at: time(10)), .cutQueued(b),
      "The no-signal cut expired, the latch released and fixed-interval asked again")
    XCTAssertEqual(coordinator.takeAbandonedCut()?.1, .expired)
    XCTAssertEqual(coordinator.selectedFeedID, a)
  }

  func testSettingsNeverMoveTheSelectionAheadOfTheCut() {
    let a = feed("A")
    let b = feed("B")
    var coordinator = SwitcherCoordinator(feedIDs: [a, b])
    _ = coordinator.ingest(frame(a, 0))
    coordinator.updateSettings(SwitcherSettings(selectedFeedID: b, automatic: false,
      intervalSeconds: 9, strategy: .manual))
    XCTAssertEqual(coordinator.settings.selectedFeedID, a)
    XCTAssertEqual(coordinator.settings.intervalSeconds, 9)
    _ = coordinator.requestManualCut(to: b)
    XCTAssertEqual(coordinator.settings.selectedFeedID, a, "Pending is not on air")
    _ = coordinator.ingest(frame(b, 0))
    XCTAssertEqual(coordinator.settings.selectedFeedID, b)
  }

  /// A feed add or remove rebuilds the coordinator. The on-air source, the
  /// pending automatic cut and its latch carry over; a cut to a removed
  /// camera is reported so its requester is released.
  func testRebuildCarriesTheAutomaticCutAndReportsARemovedTarget() {
    let a = feed("A")
    let b = feed("B")
    let settings = SwitcherSettings(selectedFeedID: a, automatic: true,
      intervalSeconds: 2, strategy: .fixedInterval)
    var coordinator = SwitcherCoordinator(settings: settings, feedIDs: [a, b])
    var now: TimeInterval = 100
    coordinator.setPendingCutClock({ now }, timeout: 2)
    _ = coordinator.ingest(frame(a, 0))
    XCTAssertEqual(coordinator.evaluate(at: time(0)), .idle)
    XCTAssertEqual(coordinator.evaluate(at: time(2)), .cutQueued(b))
    var rebuilt = SwitcherCoordinator(settings: coordinator.settings, feedIDs: [a, b, feed("C")])
    rebuilt.carryProgramTimeline(from: coordinator)
    XCTAssertTrue(rebuilt.isOnAir)
    XCTAssertEqual(rebuilt.pendingCut, b)
    XCTAssertTrue(rebuilt.isAutomaticRequestPending)
    XCTAssertNil(rebuilt.takeAbandonedCut())
    now = 102
    rebuilt.expirePendingCutIfNeeded()
    XCTAssertEqual(rebuilt.takeAbandonedCut()?.1, .expired, "The carried cut keeps its clock and timeout")
    XCTAssertFalse(rebuilt.isAutomaticRequestPending)

    var removed = SwitcherCoordinator(settings: coordinator.settings, feedIDs: [a])
    removed.carryProgramTimeline(from: coordinator)
    XCTAssertFalse(removed.hasPendingCut)
    XCTAssertFalse(removed.isAutomaticRequestPending)
    guard let abandoned = removed.takeAbandonedCut() else { return XCTFail("A dropped cut is reported") }
    XCTAssertEqual(abandoned.0, b)
    XCTAssertEqual(abandoned.1, .targetUnavailable)
  }

  static let allTests = [
    ("manual cut boundary and acknowledgement", testManualCutAppliesAtTargetFrameAndAcknowledgesSelection),
    ("fixed interval health", testFixedIntervalAdvancesInStableOrderAndSkipsUnhealthyFeed),
    ("dynamic analysis stub", testDynamicAnalysisIsAnExplicitDisabledStub),
    ("natural director acknowledgement", testNaturalDirectorDecisionRequiresExactAcknowledgement),
    ("expired automatic cut releases latch", testExpiredAutomaticCutReleasesTheFixedIntervalLatch),
    ("no-signal starting cut releases latch", testCutToStartedCameraWithNoSignalExpiresAndReleasesTheLatch),
    ("settings never move selection ahead", testSettingsNeverMoveTheSelectionAheadOfTheCut),
    ("rebuild carries the automatic cut", testRebuildCarriesTheAutomaticCutAndReportsARemovedTarget),
  ]
}
