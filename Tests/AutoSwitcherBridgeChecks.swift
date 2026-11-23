import CoreMedia
import XCTest

@MainActor @objcMembers final class AutoSwitcherBridgeChecks: XCTestCase {
  func testInstructionCutAndExpiryKeepFractionalFrameBoundaries() throws {
    for denominator: Int32 in [24_000, 60_000, 120_000] {
      let sourceCut = CMTime(value: 1001 * 1_000_001, timescale: denominator)
      let sourceExpiry = CMTimeAdd(sourceCut, CMTime(value: 1001, timescale: 24_000))
      let cut = try XCTUnwrap(AutoSwitcherBridge.instructionTime(seconds: CMTimeGetSeconds(sourceCut)))
      let expiry = try XCTUnwrap(AutoSwitcherBridge.instructionTime(seconds: CMTimeGetSeconds(sourceExpiry)))
      XCTAssertEqual(cut.timescale, 240_000)
      XCTAssertEqual(CMTimeCompare(cut, sourceCut), 0)
      XCTAssertEqual(CMTimeCompare(expiry, sourceExpiry), 0)
      XCTAssertEqual(CMTimeCompare(CMTimeSubtract(expiry, cut), CMTime(value: 1001, timescale: 24_000)), 0)
    }
    XCTAssertNil(AutoSwitcherBridge.instructionTime(seconds: .infinity))
    XCTAssertNil(AutoSwitcherBridge.instructionTime(seconds: -1))
    XCTAssertNil(AutoSwitcherBridge.instructionTime(seconds: .greatestFiniteMagnitude))
    XCTAssertEqual(AutoSwitcherBridge.instructionTime(seconds: 1.6 / 240_000)?.value, 2)
    XCTAssertEqual(AutoSwitcherBridge.instructionTime(seconds: 1.4 / 240_000)?.value, 1)
  }

  func testRustBridgeCreatesAndProcessesRealtimeEvent() {
    var settings = NaturalTalkingHeadSettings()
    settings.enabled = true
    let bridge = AutoSwitcherBridge(settings: settings,
      anchor: FeedID(rawValue: "anchor"), emphasis: FeedID(rawValue: "emphasis"))
    XCTAssertNotNil(bridge)
    bridge?.tick(time: CMTime(seconds: 0, preferredTimescale: 1_000))
    bridge?.stop()
  }

  func testTranscriptCueReachesRustBridgeAndIsNormalized() throws {
    var settings = NaturalTalkingHeadSettings()
    settings.enabled = true
    let bridge = try XCTUnwrap(AutoSwitcherBridge(settings: settings,
      anchor: FeedID(rawValue: "anchor"), emphasis: FeedID(rawValue: "emphasis")))
    bridge.ingestTranscript(segmentID: "segment-1", revision: 2,
      start: CMTime(seconds: 1, preferredTimescale: 1_000),
      end: CMTime(seconds: 1.4, preferredTimescale: 1_000), kind: "sentenceEnd",
      confidence: 2, isFinal: true)
    bridge.ingestTranscript(segmentID: "bad", revision: 1,
      start: CMTime(seconds: 2, preferredTimescale: 1_000),
      end: CMTime(seconds: 1, preferredTimescale: 1_000), kind: "unknown",
      confidence: 0.9, isFinal: false)
    bridge.stop()
    let events = bridge.takeEvents()
    XCTAssertEqual(events.count, 1)
    guard case let .transcript(cue)? = events.first else { return XCTFail("Missing transcript cue") }
    XCTAssertEqual(cue.segmentID, "segment-1")
    XCTAssertEqual(cue.kind, "sentenceEnd")
    XCTAssertEqual(cue.confidence, 1, accuracy: 0.0001)
    XCTAssertEqual(cue.start, 1, accuracy: 0.0001)
    XCTAssertEqual(cue.end, 1.4, accuracy: 0.0001)
  }

  /// The anchor came back, so the director's clock moves from the emphasis camera's stream
  /// clock to the anchor's, ten minutes on. Without starting its timing over the director
  /// reads that as a ten-minute shot and cuts at once.
  func testAClockHandoffStartsTheDirectorsTimingOverOnTheNewClock() throws {
    let anchor = FeedID(rawValue: "anchor"), emphasis = FeedID(rawValue: "emphasis")
    func cuts(rebasing: Bool) throws -> [AutoSwitcherInstruction] {
      var settings = NaturalTalkingHeadSettings()
      settings.enabled = true
      let bridge = try XCTUnwrap(AutoSwitcherBridge(settings: settings, anchor: anchor, emphasis: emphasis))
      bridge.manualOverride(cameraID: emphasis, at: .zero)
      for step in 0...20 { bridge.ingestAudio(time: CMTime(value: Int64(step), timescale: 10), rms: 0, peak: 0, present: true) }
      let handoff = CMTime(value: 600, timescale: 1)
      if rebasing { bridge.rebaseClock(at: handoff, onAir: emphasis, health: [(anchor, true), (emphasis, true)]) }
      for step in 0...20 {
        bridge.ingestAudio(time: CMTimeAdd(handoff, CMTime(value: Int64(step), timescale: 10)), rms: 0, peak: 0, present: true)
      }
      bridge.stop()  // Waits for every event already queued.
      return bridge.takeEvents().compactMap { event in
        guard case let .instruction(instruction) = event else { return nil }
        return instruction
      }
    }
    XCTAssertFalse(try cuts(rebasing: false).isEmpty, "The hazard: a forced cut on the first tick of the new clock")
    XCTAssertEqual(try cuts(rebasing: true), [], "The shot on air starts over at the handoff")
  }
  func testClockRebaseReportsEveryControlInputInDirectorOrder() throws {
    let anchor = FeedID(rawValue: "A"), emphasis = FeedID(rawValue: "B")
    let bridge = try XCTUnwrap(AutoSwitcherBridge(settings: NaturalTalkingHeadSettings(), anchor: anchor, emphasis: emphasis))
    bridge.rebaseClock(at: CMTime(value: 600, timescale: 1), onAir: emphasis,
      health: [(anchor, false), (emphasis, true)])
    bridge.stop()
    XCTAssertEqual(controlEvents(from: bridge), [.reset, .health(cameraID: "A", healthy: false, time: 600),
      .health(cameraID: "B", healthy: true, time: 600), .manualOverride(cameraID: "B", time: 600)])
  }

  func testManualControlReportsAcceptedDirectorTimeAndOmitsRejectedOverrides() throws {
    let bridge = try XCTUnwrap(AutoSwitcherBridge(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B")))
    bridge.tick(time: CMTime(value: 100, timescale: 1))
    bridge.manualOverride(cameraID: FeedID(rawValue: "B"), at: CMTime(value: 99, timescale: 1))
    bridge.manualOverride(cameraID: FeedID(rawValue: "A"), at: .zero)
    bridge.manualOverride(cameraID: FeedID(rawValue: "unknown"), at: CMTime(value: 101, timescale: 1))
    bridge.stop()
    XCTAssertEqual(controlEvents(from: bridge), [.tick(time: 100), .manualOverride(cameraID: "B", time: 100)])
  }

  func testStopLeavesOrderedAudioAndControlInputsInOnePendingBatch() throws {
    let a = FeedID(rawValue: "A"), b = FeedID(rawValue: "B")
    let bridge = try XCTUnwrap(AutoSwitcherBridge(settings: NaturalTalkingHeadSettings(), anchor: a, emphasis: b))
    let ready = expectation(description: "one wakeup for a pending batch")
    ready.assertForOverFulfill = true
    bridge.setEventsReadyHandler { ready.fulfill() }
    bridge.ingestAudio(time: .zero, rms: 0.1, peak: 0.2, present: true)
    bridge.manualOverride(cameraID: b, at: .zero)
    bridge.tick(time: CMTime(value: 1, timescale: 2))
    let acknowledged = UUID(), rejected = UUID()
    bridge.acknowledge(decisionID: acknowledged, appliedAt: nil)
    bridge.reject(decisionID: rejected)
    bridge.stop()
    wait(for: [ready], timeout: 1)
    let events = bridge.takeEvents()
    XCTAssertEqual(events.count, 6)
    guard case let .audio(cue)? = events.first else { return XCTFail("Missing initial audio cue") }
    XCTAssertEqual(cue.time, 0)
    XCTAssertEqual(events.dropFirst().compactMap(control),
      [.tick(time: 0), .manualOverride(cameraID: "B", time: 0), .tick(time: 0.5),
        .acknowledge(decisionID: acknowledged, time: nil), .reject(decisionID: rejected)])
    XCTAssertTrue(bridge.takeEvents().isEmpty)
  }

  private func controlEvents(from bridge: AutoSwitcherBridge) -> [AutoSwitcherControlEvent] {
    bridge.takeEvents().compactMap(control)
  }

  private func control(_ event: AutoSwitcherBridge.Event) -> AutoSwitcherControlEvent? {
    guard case let .control(controlEvent) = event else { return nil }
    return controlEvent
  }
}
