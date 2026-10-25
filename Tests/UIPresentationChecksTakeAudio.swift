import Foundation
import XCTest

/// A take's audio in the strip: a warning only when it needs a look, the full
/// summary in the tooltip and for VoiceOver otherwise.
extension UIPresentationChecks {
  private func takeCamera(_ status: UIRecordingStatus, audio: AudioTakeSummary?, saved: Bool = false,
    note: String? = nil) -> UICameraPresentation {
    var camera = UICameraSnapshot(id: "camera-1", name: "Camera 1")
    camera.running = true
    camera.signal = .live(format: "2160p 59.94")
    camera.recording.status = status
    camera.recording.elapsed = status == .idle ? 0 : 63
    camera.recording.folderPath = "/Volumes/8TB/Takes"
    camera.recording.note = note
    camera.recording.audio = audio
    if saved {
      camera.recording.savedFileName = "Camera 1_001.mov"
      camera.recording.savedURL = URL(fileURLWithPath: "/Volumes/8TB/Takes/Camera 1_001.mov")
      camera.recording.savedDuration = 63
    }
    var session = UISessionSnapshot()
    session.cameras = [camera]
    session.selectedID = camera.id
    return UIPresentationBuilder.session(session).cameras[0]
  }

  private static let clean = AudioTakeSummary(integrated: -23.44, maximumTruePeak: -2.06, overs: 0, duration: 63)
  private static let hot = AudioTakeSummary(integrated: -14.2, maximumTruePeak: 0.3, overs: 2, duration: 63)

  @objc func testCleanTakeAudioIsATooltipNotAWarning() {
    let recording = takeCamera(.recording, audio: Self.clean)
    XCTAssertNil(recording.recordingNote, "no warning line for clean audio")
    XCTAssertEqual(recording.takeAudioHelp, "This take so far: Audio −23.4 LUFS · max −2.1 dBTP · no overs")
    XCTAssertFalse(recording.accessibilityLabel.contains("LUFS"))
    let saved = takeCamera(.idle, audio: Self.clean, saved: true)
    XCTAssertEqual(saved.stripState, .saved)
    XCTAssertNil(saved.recordingNote)
    XCTAssertEqual(saved.takeAudioHelp, "Last take: Audio −23.4 LUFS · max −2.1 dBTP · no overs")
  }

  @objc func testTakeAudioWithAnOverWarns() {
    let saved = takeCamera(.idle, audio: Self.hot, saved: true, note: "Audio re-synced after a signal drop")
    XCTAssertEqual(saved.recordingNote,
      "Audio re-synced after a signal drop · Audio −14.2 LUFS · max +0.3 dBTP · 2 overs")
    XCTAssertTrue(saved.accessibilityLabel.contains("2 overs"), saved.accessibilityLabel)
    let recording = takeCamera(.recording, audio: Self.hot)
    XCTAssertEqual(recording.recordingNote, "Audio −14.2 LUFS · max +0.3 dBTP · 2 overs")
  }

  /// A take's audio belongs to a take: none on a camera that is ready for the next one.
  @objc func testTakeAudioOnlyWithATake() {
    let ready = takeCamera(.idle, audio: Self.hot)
    XCTAssertEqual(ready.stripState, .ready)
    XCTAssertNil(ready.recordingNote)
    XCTAssertNil(ready.takeAudioHelp)
    let starting = takeCamera(.recording, audio: nil, note: nil)
    XCTAssertNil(starting.recordingNote)
    XCTAssertNil(starting.takeAudioHelp)
  }
}
