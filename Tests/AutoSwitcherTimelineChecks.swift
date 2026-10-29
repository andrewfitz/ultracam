import CoreMedia
import Foundation
import XCTest

@MainActor @objcMembers final class AutoSwitcherTimelineChecks: XCTestCase {
  func testTimelinePersistsExactTicksAndAppliedProgramCut() throws {
    var settings = NaturalTalkingHeadSettings()
    settings.maximumShotDuration = 30
    let folder = URL(fileURLWithPath: "/tmp/ultracam-auto-switcher-timeline-check")
    let recorder = AutoSwitcherTimelineRecorder(settings: settings,
      anchor: FeedID(rawValue: "anchor"), emphasis: FeedID(rawValue: "emphasis"),
      outputFolder: folder)
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
    recorder.recordApplied(decisionID: decisionID, target: FeedID(rawValue: "emphasis"),
      sourceTime: CMTime(value: 300_600, timescale: 60_000),
      programTime: CMTime(value: 300_660, timescale: 60_000))
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
    let cue = try XCTUnwrap((transcript["event"] as? [String: Any])?["transcript"] as? [String: Any])
    XCTAssertEqual(cue["segment_id"] as? String, "segment-1")
    XCTAssertEqual(cue["kind"] as? String, "sentenceEnd")
  }

  func testTimelinePreservesFractionalFrameTicksWithoutCumulativeRounding() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = AutoSwitcherTimelineRecorder(settings: NaturalTalkingHeadSettings(),
      anchor: FeedID(rawValue: "anchor"), emphasis: FeedID(rawValue: "emphasis"), outputFolder: folder)
    for index: Int64 in [1, 2, 1_000_000] {
      recorder.recordTick(time: CMTime(value: index * 1001, timescale: 24_000))
    }
    recorder.finish()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recorder.outputFileURL)) as? [String: Any])
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])
    XCTAssertEqual(events.compactMap { $0["media_time_ticks"] as? Int64 }, [10_010, 20_020, 10_010_000_000])
  }

}
