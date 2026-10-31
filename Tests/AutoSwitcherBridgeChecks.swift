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

  func testTranscriptCueReachesRustBridgeAndIsNormalized() {
    var settings = NaturalTalkingHeadSettings()
    settings.enabled = true
    let bridge = AutoSwitcherBridge(settings: settings,
      anchor: FeedID(rawValue: "anchor"), emphasis: FeedID(rawValue: "emphasis"))
    let expectation = expectation(description: "transcript cue delivered")
    bridge?.onTranscriptCue = { cue in
      XCTAssertEqual(cue.segmentID, "segment-1")
      XCTAssertEqual(cue.kind, "sentenceEnd")
      XCTAssertEqual(cue.confidence, 1, accuracy: 0.0001)
      XCTAssertEqual(cue.start, 1, accuracy: 0.0001)
      XCTAssertEqual(cue.end, 1.4, accuracy: 0.0001)
      expectation.fulfill()
    }
    bridge?.ingestTranscript(segmentID: "segment-1", revision: 2,
      start: CMTime(seconds: 1, preferredTimescale: 1_000),
      end: CMTime(seconds: 1.4, preferredTimescale: 1_000), kind: "sentenceEnd",
      confidence: 2, isFinal: true)
    wait(for: [expectation], timeout: 1)
    // Invalid kinds and reversed ranges are rejected before crossing the C ABI.
    bridge?.ingestTranscript(segmentID: "bad", revision: 1,
      start: CMTime(seconds: 2, preferredTimescale: 1_000),
      end: CMTime(seconds: 1, preferredTimescale: 1_000), kind: "unknown",
      confidence: 0.9, isFinal: false)
    bridge?.stop()
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
      let log = InstructionLog()
      bridge.onInstruction = { log.append($0) }
      bridge.manualOverride(cameraID: emphasis, at: .zero)
      for step in 0...20 { bridge.ingestAudio(time: CMTime(value: Int64(step), timescale: 10), rms: 0, peak: 0, present: true) }
      let handoff = CMTime(value: 600, timescale: 1)
      if rebasing { bridge.rebaseClock(at: handoff, onAir: emphasis, health: [(anchor, true), (emphasis, true)]) }
      for step in 0...20 {
        bridge.ingestAudio(time: CMTimeAdd(handoff, CMTime(value: Int64(step), timescale: 10)), rms: 0, peak: 0, present: true)
      }
      bridge.stop()  // Waits for every event already queued.
      return log.instructions
    }
    XCTAssertFalse(try cuts(rebasing: false).isEmpty, "The hazard: a forced cut on the first tick of the new clock")
    XCTAssertEqual(try cuts(rebasing: true), [], "The shot on air starts over at the handoff")
  }
}

private final class InstructionLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AutoSwitcherInstruction] = []
  func append(_ instruction: AutoSwitcherInstruction) { lock.withLock { stored.append(instruction) } }
  var instructions: [AutoSwitcherInstruction] { lock.withLock { stored } }
}
