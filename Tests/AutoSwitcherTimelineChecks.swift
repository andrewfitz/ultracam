import CoreMedia
import Foundation
import XCTest

@MainActor @objcMembers final class AutoSwitcherTimelineChecks: XCTestCase {
  func testPeriodicCheckpointAndFolderMovePreserveOrderedEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B"), outputFolder: root)
    let oldURL = recorder.outputFileURL
    func snapshot(at url: URL) throws -> (count: Int, sequence: [Int], ended: Bool) {
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      let events = try XCTUnwrap(object["events"] as? [[String: Any]])
      return (try XCTUnwrap(object["events_processed"] as? Int),
        events.compactMap { $0["sequence"] as? Int }, object["ended_at_unix_ms"] != nil)
    }

    for frame in 1...29 { recorder.recordControlEvent(.tick(time: Double(frame) / 30)) }
    XCTAssertEqual(try snapshot(at: oldURL).count, 0)
    recorder.recordControlEvent(.tick(time: 1))
    let deadline = ContinuousClock.now + .seconds(5)
    while try snapshot(at: oldURL).count == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(try snapshot(at: oldURL).sequence, Array(1...30))

    for frame in 31...63 { recorder.recordControlEvent(.tick(time: Double(frame) / 30)) }
    recorder.setOutputFolder(root.appendingPathComponent("moved"))
    recorder.recordControlEvent(.tick(time: 64.0 / 30))
    recorder.finish()
    XCTAssertEqual(try snapshot(at: oldURL).sequence, Array(1...63))
    XCTAssertFalse(try snapshot(at: oldURL).ended)
    let final = try snapshot(at: recorder.outputFileURL)
    XCTAssertEqual(final.count, 64)
    XCTAssertEqual(final.sequence, Array(1...64))
    XCTAssertTrue(final.ended)
    let attributes = try FileManager.default.attributesOfItem(atPath: recorder.outputFileURL.path)
    recorder.finish()
    let afterRepeatFinish = try FileManager.default.attributesOfItem(atPath: recorder.outputFileURL.path)
    XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber,
      afterRepeatFinish[.systemFileNumber] as? NSNumber)
  }

  func testWriteFailureBacksOffAndFinishRecoversBufferedEvents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B"), outputFolder: root)
    let url = recorder.outputFileURL
    try FileManager.default.removeItem(at: root)
    try Data().write(to: root)
    var errors: [String] = []
    recorder.onError = { errors.append($0) }
    recorder.recordError("starts a checkpoint")
    XCTAssertEqual(errors.count, 1)

    try FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for frame in 1...60 { recorder.recordControlEvent(.tick(time: Double(frame) / 30)) }
    recorder.recordError("checkpoint during backoff")
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    recorder.finish()
    XCTAssertEqual(errors.count, 1)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])
    XCTAssertEqual(events.compactMap { $0["sequence"] as? Int }, Array(1...62))
    XCTAssertNotNil(object["ended_at_unix_ms"])
  }

  func testTimelinePersistsExactTicksAndAppliedProgramCut() throws {
    var settings = NaturalTalkingHeadSettings()
    settings.maximumShotDuration = 30
    let folder = URL(fileURLWithPath: "/tmp/ultracam-auto-switcher-timeline-check")
    let recorder = AutoSwitcherTimelineRecorder(settings: settings,
      anchor: FeedID(rawValue: "anchor"), emphasis: FeedID(rawValue: "emphasis"),
      outputFolder: folder)
    let originalURL = recorder.outputFileURL
    recorder.setOutputFolder(folder)
    XCTAssertEqual(recorder.outputFileURL, originalURL)
    recorder.recordAudioCue(AutoSwitcherAudioCue(id: 1, time: 5.0, duration: 0.02,
      speechEnergy: 0.8, pauseDuration: 0.3, emphasis: 0.9, laughter: 0,
      speechStart: true, speechStop: false, sessionGeneration: 1))
    recorder.recordTranscript(AutoSwitcherTranscriptCue(segmentID: "segment-1", revision: 2,
      start: 4.8, end: 5.0, kind: "sentenceEnd", confidence: 0.96, isFinal: true,
      sessionGeneration: 1))
    let decisionID = UUID()
    let instruction = AutoSwitcherInstruction(decisionID: decisionID, sessionGeneration: 1,
      targetCameraID: FeedID(rawValue: "emphasis"),
      cutTime: CMTime(seconds: 5.0, preferredTimescale: 60_000),
      expiresAt: CMTime(seconds: 6.0, preferredTimescale: 60_000), confidence: 0.9,
      reason: "emphasisBoundary", forced: false)
    recorder.recordInstruction(instruction, from: FeedID(rawValue: "anchor"))
    recorder.markCutApplied(decisionID: decisionID, target: FeedID(rawValue: "emphasis"),
      sourceTime: CMTime(value: 300_600, timescale: 60_000),
      programTime: CMTime(value: 300_660, timescale: 60_000))
    recorder.recordControlEvent(.acknowledge(decisionID: decisionID, time: nil))
    recorder.finish()
    if let error = recorder.lastError { XCTFail("Timeline write failed: \(error)") }
    XCTAssertNotNil(recorder.outputFileURL.lastPathComponent.range(
      of: #"^auto-switcher-\d{8}-\d{6}-\d{3}(?:-\d+)?\.json$"#, options: .regularExpression))

    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.outputFileURL)) as? [String: Any])
    XCTAssertEqual(object["schema_version"] as? Int, 3)
    let cuts = try XCTUnwrap(object["cuts"] as? [[String: Any]])
    XCTAssertEqual(cuts.first?["status"] as? String, "applied")
    XCTAssertEqual(cuts.first?["requested_cut_time_ticks"] as? Int, 1_200_000)
    XCTAssertEqual(cuts.first?["applied_source_time_ticks"] as? Int, 1_202_400)
    XCTAssertEqual(cuts.first?["applied_program_time_ticks"] as? Int, 1_202_640)
    XCTAssertEqual((object["timebase"] as? [String: Any])?["timescale"] as? Int, 240_000)
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])
    let transcript = try XCTUnwrap(events.first(where: { event in
      guard let payload = event["event"] as? [String: Any] else { return false }
      return payload["type"] as? String == "transcript"
    }))
    let cue = try XCTUnwrap((transcript["event"] as? [String: Any])?["cue"] as? [String: Any])
    XCTAssertEqual(cue["segment_id"] as? String, "segment-1")
    XCTAssertEqual(cue["kind"] as? String, "sentenceEnd")
  }

  func testNewTakeClearsPreviousSourceBounds() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let feed = FeedID(rawValue: "A")
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: feed, emphasis: FeedID(rawValue: "B"), outputFolder: folder)
    let first = folder.appendingPathComponent("first.mov"), next = folder.appendingPathComponent("next.mov")
    recorder.recordingStarted(feedID: feed, url: first, mediaStart: .zero)
    recorder.recordingFinished(feedID: feed, url: first, mediaEnd: CMTime(value: 5, timescale: 1))
    recorder.recordingStarted(feedID: feed, url: next, mediaStart: nil)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.outputFileURL)) as? [String: Any])
    let sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
    let source = try XCTUnwrap(sources.first { $0["camera_id"] as? String == feed.rawValue })
    XCTAssertEqual(source["media_file"] as? String, next.path)
    XCTAssertNil(source["media_start"])
    XCTAssertNil(source["media_end"])
    let recordings = try XCTUnwrap(object["recordings"] as? [[String: Any]])
    XCTAssertEqual(recordings.first?["media_end"] as? Double, 5)
  }

  func testLedgerProtocolAndAcknowledgementUseDirectorClock() throws {
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B"),
      outputFolder: URL(fileURLWithPath: "/tmp/ultracam-switcher-protocol-fixture"))
    recorder.recordTranscript(AutoSwitcherTranscriptCue(segmentID: "cross-language", revision: 1,
      start: 99, end: 100, kind: "sentenceEnd", confidence: 1, isFinal: true, sessionGeneration: 1))
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    let instruction = AutoSwitcherInstruction(decisionID: id, sessionGeneration: 1,
      targetCameraID: FeedID(rawValue: "B"), cutTime: CMTime(value: 100, timescale: 1),
      expiresAt: CMTime(value: 101, timescale: 1), confidence: 1, reason: "forcedMaximumShotDuration", forced: true)
    recorder.recordInstruction(instruction, from: FeedID(rawValue: "A"))
    recorder.recordControlEvent(.reject(decisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000124")!))
    recorder.markCutApplied(decisionID: id, target: FeedID(rawValue: "B"),
      sourceTime: CMTime(value: 5, timescale: 1), programTime: CMTime(value: 1000, timescale: 1))
    recorder.recordControlEvent(.acknowledge(decisionID: id, time: nil))
    recorder.finish()
    let data = try Data(contentsOf: recorder.outputFileURL)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let records = try XCTUnwrap(object["events"] as? [[String: Any]])
    let events = records.compactMap { $0["event"] as? [String: Any] }
    XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["transcript", "directorOutput", "reject", "acknowledge"])
    XCTAssertNotNil(events.first?["cue"])
    XCTAssertNil(events.last?["applied_at"])
    XCTAssertNil(events.last?["time"])
    // A real Swift-encoded fixture is consumed by the focused Rust protocol test.
    if let path = ProcessInfo.processInfo.environment["ULTRACAM_SWITCHER_LEDGER_FIXTURE"] {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
  }

  func testTimelinePreservesFractionalFrameTicksWithoutCumulativeRounding() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "anchor"), emphasis: FeedID(rawValue: "emphasis"), outputFolder: folder)
    for index: Int64 in [1, 2, 1_000_000] {
      recorder.recordControlEvent(.tick(time: CMTimeGetSeconds(CMTime(value: index * 1001, timescale: 24_000))))
    }
    recorder.finish()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.outputFileURL)) as? [String: Any])
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])
    XCTAssertEqual(events.compactMap { $0["media_time_ticks"] as? Int64 }, [10_010, 20_020, 10_010_000_000])
  }

  func testUnconfiguredCameraHealthDoesNotAdvanceTheJournalClock() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B"), outputFolder: folder)
    recorder.recordControlEvent(.health(cameraID: "unconfigured", healthy: false, time: 100))
    recorder.recordControlEvent(.tick(time: 10))
    recorder.recordControlEvent(.manualOverride(cameraID: "B", time: 10))
    recorder.finish()

    let data = try Data(contentsOf: recorder.outputFileURL)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cuts = try XCTUnwrap(object["cuts"] as? [[String: Any]])
    XCTAssertEqual(cuts.first?["session_generation"] as? UInt64, 1)
  }

  func testTimelineRoundsDirectorSecondsToNearestTick() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B"), outputFolder: folder)
    let seconds = 59.0 / 240_000
    recorder.recordControlEvent(.manualOverride(cameraID: "B", time: seconds))
    recorder.recordAudioCue(AutoSwitcherAudioCue(id: 1, time: seconds,
      duration: 0.02, speechEnergy: 0, pauseDuration: 0, emphasis: 0, laughter: 0,
      speechStart: false, speechStop: false, sessionGeneration: 1))
    recorder.recordControlEvent(.tick(time: seconds))
    recorder.recordTranscript(AutoSwitcherTranscriptCue(segmentID: "s", revision: 0,
      start: 0, end: seconds, kind: "sentenceEnd", confidence: 1, isFinal: true, sessionGeneration: 1))
    recorder.finish()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.outputFileURL)) as? [String: Any])
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])
    XCTAssertEqual(events.compactMap { $0["media_time_ticks"] as? Int }, [59, 59, 59, 59])
    for event in events {
      XCTAssertEqual(try XCTUnwrap(event["media_time"] as? Double), seconds, accuracy: 1e-18)
    }
  }

  func testClockRebaseControlInputsArePersistedInOrder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B"), outputFolder: folder)
    recorder.recordControlEvent(.reset)
    recorder.recordControlEvent(.health(cameraID: "A", healthy: false, time: 600))
    recorder.recordControlEvent(.health(cameraID: "B", healthy: true, time: 600))
    recorder.recordControlEvent(.manualOverride(cameraID: "B", time: 600))
    recorder.finish()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.outputFileURL)) as? [String: Any])
    let records = try XCTUnwrap(object["events"] as? [[String: Any]])
    let events = records.compactMap { $0["event"] as? [String: Any] }
    XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["reset", "video", "video", "manualOverride"])
    let observation = try XCTUnwrap(events[1]["observation"] as? [String: Any])
    XCTAssertEqual(observation["camera_id"] as? String, "A")
    XCTAssertEqual(observation["healthy"] as? Bool, false)
    XCTAssertEqual(observation["time"] as? Double, 600)
    XCTAssertEqual(events[3]["camera_id"] as? String, "B")
    XCTAssertEqual(events[3]["time"] as? Double, 600)
    let cuts = try XCTUnwrap(object["cuts"] as? [[String: Any]])
    XCTAssertEqual(cuts.last?["session_generation"] as? Int, 2)
  }

  func testManualOverrideCancelsPendingCutAndBecomesNextCutOrigin() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "A"), emphasis: FeedID(rawValue: "B"), outputFolder: folder)
    func instruction(_ target: String) -> AutoSwitcherInstruction {
      AutoSwitcherInstruction(decisionID: UUID(), sessionGeneration: 1,
        targetCameraID: FeedID(rawValue: target), cutTime: CMTime(value: 20, timescale: 1),
        expiresAt: CMTime(value: 21, timescale: 1), confidence: 1,
        reason: "emphasisBoundary", forced: false)
    }
    let pending = instruction("B")
    recorder.recordInstruction(pending, from: nil)
    recorder.recordControlEvent(.manualOverride(cameraID: "B", time: 20))
    recorder.markCutApplied(decisionID: pending.decisionID, target: FeedID(rawValue: "B"),
      sourceTime: CMTime(value: 20, timescale: 1), programTime: CMTime(value: 20, timescale: 1))
    recorder.recordControlEvent(.acknowledge(decisionID: pending.decisionID, time: nil))
    recorder.recordInstruction(instruction("A"), from: nil)
    recorder.recordControlEvent(.tick(time: 20))
    recorder.recordControlEvent(.tick(time: 10))
    recorder.recordControlEvent(.manualOverride(cameraID: "B", time: 10))
    recorder.finish()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.outputFileURL)) as? [String: Any])
    let cuts = try XCTUnwrap(object["cuts"] as? [[String: Any]])
    XCTAssertEqual(cuts.count, 4)
    XCTAssertEqual(cuts[0]["status"] as? String, "cancelled")
    XCTAssertEqual(cuts[1]["reason"] as? String, "manualOverride")
    XCTAssertEqual(cuts[1]["status"] as? String, "applied")
    XCTAssertEqual(cuts[1]["applied_source_time_ticks"] as? Int, 4_800_000)
    XCTAssertEqual(cuts[2]["from_camera_id"] as? String, "B")
    XCTAssertEqual(cuts[3]["session_generation"] as? Int, 2)
  }

}
