import Foundation
import XCTest

/// Rules from the UI audit (docs/mockups/r3/audit/REPORT.md, decisions D1–D8)
/// expressed against the pure presentation layer.
@objcMembers final class UIPresentationChecks: XCTestCase {
  // MARK: Helpers

  private func camera(_ index: Int, running: Bool = true, signal: UISignal = .live(format: "2160p 59.94"),
    recording: UIRecordingStatus = .idle, elapsed: TimeInterval = 751, inUse: Bool = false,
    folder: String? = "/Volumes/8TB/Takes", processing: Bool = true) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-\(index)", name: "Camera \(index)")
    camera.running = running
    camera.signal = running ? signal : .none
    camera.inUse = inUse
    camera.processing = processing
    camera.recording.status = recording
    camera.recording.elapsed = recording == .idle ? 0 : elapsed
    camera.recording.folderPath = folder
    camera.audio = UIAudioLevels(present: true, peakLeft: 0.5, peakRight: 0.5, rmsLeft: 0.3, rmsRight: 0.3)
    return camera
  }

  private func program(_ cameras: [UICameraSnapshot], onAir: String? = "camera-1", pending: String? = nil,
    inUse: Bool = true) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.outputMode = .program
    session.cameras = cameras
    session.selectedID = cameras.first?.id ?? ""
    session.onAirID = onAir
    session.pendingCutID = pending
    session.programInUse = inUse
    return session
  }

  private func separate(_ cameras: [UICameraSnapshot]) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.cameras = cameras
    session.selectedID = cameras.first?.id ?? ""
    return session
  }

  private func presented(_ session: UISessionSnapshot, _ index: Int = 0) -> UICameraPresentation {
    UIPresentationBuilder.session(session).cameras[index]
  }

  private let appNames = ["Zoom", "Teams", "Meet", "FaceTime", "Webex", "Skype"]

  private func assertNoAppNames(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    for name in appNames { XCTAssertFalse(text.contains(name), "Consumer app names are unknowable: \(text)", file: file, line: line) }
  }

  // MARK: Tally (D8: ON AIR only with a client; NEXT only while a cut is pending)

  func testProgramTallyIsOnAirOnlyWithAClient() {
    let cams = [camera(1), camera(2)]
    XCTAssertEqual(presented(program(cams, inUse: true)).tally, .onAir)
    XCTAssertEqual(presented(program(cams, inUse: false)).tally, .program)
    XCTAssertEqual(UITally.program.badge, "PROGRAM")
    XCTAssertEqual(UITally.onAir.badge, "ON AIR")
    XCTAssertEqual(presented(program(cams), 1).tally, .none, "A camera that isn't on air and isn't pending has no tally")
  }

  func testNextOnlyWhilePendingAndNotOnAir() {
    let cams = [camera(1), camera(2)]
    XCTAssertEqual(presented(program(cams, pending: "camera-2"), 1).tally, .next)
    XCTAssertEqual(presented(program(cams, pending: "camera-1"), 0).tally, .onAir,
      "A pending cut to the camera already on air is not NEXT")
    XCTAssertEqual(presented(program(cams, pending: nil), 1).tally, .none, "No permanent NEXT")
  }

  func testSeparateTallyRequiresRunningAndInUse() {
    XCTAssertEqual(presented(separate([camera(1, inUse: true)])).tally, .onAir)
    XCTAssertEqual(presented(separate([camera(1, inUse: false)])).tally, .none)
    XCTAssertEqual(presented(separate([camera(1, running: false, inUse: true)])).tally, .none)
  }

  func testOutputLinesNeverNameTheConsumerApp() {
    let sessions = [program([camera(1), camera(2)]), program([camera(1), camera(2)], inUse: false),
      separate([camera(1, inUse: true), camera(2)])]
    for session in sessions {
      let presentation = UIPresentationBuilder.session(session)
      assertNoAppNames(presentation.outputSummary)
      assertNoAppNames(presentation.subtitle)
      presentation.statusSegments.forEach { assertNoAppNames($0.text) }
      presentation.cameras.forEach { assertNoAppNames($0.outputLine); assertNoAppNames($0.accessibilityLabel) }
    }
    let presentation = UIPresentationBuilder.session(separate([camera(1, inUse: true), camera(2)]))
    XCTAssertEqual(presentation.cameras[0].outputLine, "Ultracam · Camera 1 · In use")
    XCTAssertEqual(presentation.cameras[1].outputLine, "Ultracam · Camera 2 · Not in use")
    XCTAssertEqual(presentation.outputSummary, "Ultracam · Camera 1 · In use")
    XCTAssertEqual(UIPresentationBuilder.session(program([camera(1)], inUse: false)).outputSummary,
      "Ultracam · Program · Not in use")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1), camera(2)])).outputSummary, "Ultracam cameras not in use")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1)])).outputSummary, "Ultracam · Camera 1 · Not in use",
      "One output is called by its published device name")
  }

  func testProgramOutputLines() {
    let cams = [camera(1), camera(2), camera(3)]
    let onAir = UIPresentationBuilder.session(program(cams, pending: "camera-2"))
    XCTAssertEqual(onAir.cameras[0].outputLine, "In Program · on air")
    XCTAssertEqual(onAir.cameras[1].outputLine, "Next", "The pending camera reads \"Next\" everywhere")
    XCTAssertEqual(onAir.cameras[2].outputLine, "Program source")
    XCTAssertEqual(UIPresentationBuilder.session(program(cams, inUse: false)).cameras[0].outputLine, "In Program · no viewer yet")
  }

  // MARK: Tile states

  func testTileStates() {
    XCTAssertEqual(UIPresentationBuilder.tileState(for: camera(1)), .live)
    XCTAssertEqual(UIPresentationBuilder.tileState(for: camera(1, signal: .connecting)), .connecting)
    XCTAssertEqual(UIPresentationBuilder.tileState(for: camera(1, signal: .none)), .connecting)
    XCTAssertEqual(UIPresentationBuilder.tileState(for: camera(1, signal: .noSignal)), .noSignal)
    XCTAssertEqual(UIPresentationBuilder.tileState(for: camera(1, signal: .unsupported("1080i"))), .unsupported("1080i"))
    XCTAssertEqual(UIPresentationBuilder.tileState(for: camera(1, signal: .deviceMissing)), .deviceMissing)
    XCTAssertEqual(UIPresentationBuilder.tileState(for: camera(1, running: false)), .stopped)
    var missing = camera(1, running: false)
    missing.deviceAvailable = false
    XCTAssertEqual(UIPresentationBuilder.tileState(for: missing), .deviceMissing)
    var hidden = camera(1)
    hidden.previewEnabled = false
    XCTAssertEqual(UIPresentationBuilder.tileState(for: hidden), .previewHidden)
    var updating = camera(1)
    updating.applying = true
    XCTAssertEqual(UIPresentationBuilder.tileState(for: updating), .updating)
  }

  // MARK: Strip states

  func testStripStates() {
    XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1)), .ready)
    XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1, recording: .recording)), .recording)
    XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1, recording: .paused)), .paused)
    XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1, recording: .finishing)), .finishing)
    XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1, signal: .noSignal, recording: .recording)), .recordingNoSignal)
    var updating = camera(1, recording: .recording)
    updating.applying = true
    XCTAssertEqual(UIPresentationBuilder.stripState(for: updating), .updating)
    var saved = camera(1)
    saved.recording.savedFileName = "Camera 1_2026-10-21_09-41-03_001.mov"
    saved.recording.savedDuration = 2292
    XCTAssertEqual(UIPresentationBuilder.stripState(for: saved), .saved)
    XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1, folder: nil)), .noFolder)
    var failed = camera(1)
    failed.recording.error = "The drive was disconnected."
    XCTAssertEqual(UIPresentationBuilder.stripState(for: failed), .failed)
    var failedFlag = camera(1)
    failedFlag.recording.failed = true
    XCTAssertEqual(UIPresentationBuilder.stripState(for: failedFlag), .failed)
    XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1, running: false)), .stopped)
    for signal: UISignal in [.noSignal, .connecting, .unsupported("1080i"), .deviceMissing] {
      XCTAssertEqual(UIPresentationBuilder.stripState(for: camera(1, signal: signal)), .waiting)
    }
  }

  func testStripTitlesAndDetails() {
    var saved = camera(1)
    saved.recording.savedFileName = "Camera 1_001.mov"
    saved.recording.savedDuration = 2292
    let savedPresentation = presented(separate([saved]))
    XCTAssertEqual(savedPresentation.recordTitle, "Saved")
    XCTAssertEqual(savedPresentation.recordDetail, "Camera 1_001.mov · 38:12")
    XCTAssertEqual(savedPresentation.recordTone, .positive)

    let rec = presented(separate([camera(1, recording: .recording)]))
    XCTAssertEqual(rec.recordTitle, "Recording")
    XCTAssertEqual(rec.recordDetail, "12:31", "Every clock uses the short form")
    XCTAssertEqual(presented(separate([camera(1, recording: .recording, elapsed: 3767)])).recordDetail, "1:02:47")
    XCTAssertEqual(presented(separate([camera(1, recording: .paused, elapsed: 252)])).recordDetail, "4:12")
    XCTAssertEqual(rec.pauseTitle, "Pause")
    XCTAssertEqual(rec.dropsLine, "0 dropped")
    XCTAssertFalse(rec.dropsWarning)

    XCTAssertEqual(presented(separate([camera(1, recording: .paused)])).pauseTitle, "Resume")
    XCTAssertEqual(presented(separate([camera(1, signal: .noSignal, recording: .recording)])).recordTitle, "Recording · no signal")
    XCTAssertEqual(presented(separate([camera(1, signal: .noSignal, recording: .recording)])).recordTone, .warning)
    XCTAssertEqual(presented(separate([camera(1, folder: nil)])).recordDetail, "Choose where Camera 1 records")
    XCTAssertNil(presented(separate([camera(1)])).pauseTitle)

    var dropped = camera(1, recording: .recording)
    dropped.recording.droppedFrames = 14
    XCTAssertEqual(presented(separate([dropped])).dropsLine, "14 dropped")
    XCTAssertTrue(presented(separate([dropped])).dropsWarning)
  }

  // MARK: Record control and record button

  func testRecordControlLabelsAlwaysHaveAVerb() {
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1)])).recordControl, .record(all: false, enabled: true))
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1), camera(2)])).recordControl, .record(all: true, enabled: true))
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, recording: .recording)])).recordControl, .stop(elapsed: "12:31"))
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, recording: .recording), camera(2)])).recordControl,
      .stopAll(count: 1, elapsed: "12:31"))
    let both = UIPresentationBuilder.session(separate([camera(1, recording: .recording), camera(2, recording: .paused, elapsed: 252)]))
    XCTAssertEqual(both.recordControl, .stopAll(count: 2, elapsed: "12:31"))
    XCTAssertEqual(both.recordControl.title, "Stop All (2)")
    XCTAssertEqual(UIRecordControl.record(all: true, enabled: true).title, "Record All")
    XCTAssertEqual(UIRecordControl.record(all: false, enabled: true).title, "Record")
    XCTAssertEqual(UIRecordControl.stop(elapsed: "1:00").title, "Stop Recording")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, running: false)])).recordControl,
      .record(all: false, enabled: false))
  }

  func testRecordButtonEnablementAndHelp() {
    let ready = presented(separate([camera(1)]))
    XCTAssertTrue(ready.recordButtonEnabled)
    XCTAssertFalse(ready.recordButtonActive)
    XCTAssertEqual(ready.recordButtonHelp, "Record (⌘R)")

    let rec = presented(separate([camera(1, recording: .recording)]))
    XCTAssertTrue(rec.recordButtonEnabled)
    XCTAssertTrue(rec.recordButtonActive)
    XCTAssertEqual(rec.recordButtonHelp, "Stop Recording (⌘R)")

    let paused = presented(separate([camera(1, recording: .paused)]))
    XCTAssertTrue(paused.recordButtonEnabled)
    XCTAssertTrue(paused.recordButtonActive, "A paused take shows the stop square: the button ends the take")
    XCTAssertEqual(paused.recordButtonHelp, "Stop Recording (⌘R)")

    let stopped = presented(separate([camera(1, running: false)]))
    XCTAssertFalse(stopped.recordButtonEnabled)
    XCTAssertEqual(stopped.recordButtonHelp, "Start this camera before recording it.")

    let waiting = presented(separate([camera(1, signal: .noSignal)]))
    XCTAssertFalse(waiting.recordButtonEnabled)
    XCTAssertEqual(waiting.recordButtonHelp, "Recording becomes available when a supported signal arrives.")

    let noFolder = presented(separate([camera(1, folder: nil)]))
    XCTAssertFalse(noFolder.recordButtonEnabled)
    XCTAssertEqual(noFolder.recordButtonHelp, "Choose a recording folder first.")

    let finishing = presented(separate([camera(1, recording: .finishing)]))
    XCTAssertFalse(finishing.recordButtonEnabled, "Finishing blocks a duplicate take")
  }

  // MARK: Cut (D1)

  func testCutEnablement() {
    let cams = [camera(1), camera(2), camera(3, signal: .noSignal), camera(4, running: false)]
    let presentation = UIPresentationBuilder.session(program(cams))
    XCTAssertFalse(presentation.cameras[0].showsCut, "The on-air camera has no Cut button")
    XCTAssertFalse(presentation.cameras[0].cutEnabled)
    XCTAssertTrue(presentation.cameras[1].showsCut)
    XCTAssertTrue(presentation.cameras[1].cutEnabled)
    XCTAssertFalse(presentation.cameras[2].cutEnabled, "No cut to a camera without a signal")
    XCTAssertFalse(presentation.cameras[3].cutEnabled, "No cut to a stopped camera")
    XCTAssertEqual(presentation.cutButtons.map(\.number), [1, 2, 3, 4])
    XCTAssertTrue(presentation.cutButtons[0].onAir)
    XCTAssertTrue(presentation.cutButtons[0].enabled)
    XCTAssertFalse(presentation.cutButtons[2].enabled)

    let separatePresentation = UIPresentationBuilder.session(separate([camera(1), camera(2)]))
    XCTAssertTrue(separatePresentation.cutButtons.isEmpty)
    XCTAssertFalse(separatePresentation.cameras.contains { $0.showsCut || $0.cutEnabled })
    XCTAssertFalse(separatePresentation.layouts.contains(.programView), "Program View only in Program mode")
    XCTAssertTrue(presentation.layouts.contains(.programView))
  }

  func testPendingCutButton() {
    let presentation = UIPresentationBuilder.session(program([camera(1), camera(2)], pending: "camera-2"))
    XCTAssertTrue(presentation.cutButtons[1].pending)
    XCTAssertFalse(presentation.cutButtons[0].pending)
  }

  // MARK: Stop confirmations (D3)

  func testStopConfirmationMessages() {
    let rec = presented(separate([camera(1, recording: .recording)]))
    XCTAssertTrue(rec.stopNeedsConfirmation)
    XCTAssertEqual(rec.stopConfirmationMessage, "Camera 1 is recording. Stopping the camera ends the take.")

    let both = presented(separate([camera(1, recording: .recording, inUse: true)]))
    XCTAssertEqual(both.stopConfirmationMessage,
      "Camera 1 is recording and on air. Stopping the camera ends the take and its video output.")

    let onAir = presented(separate([camera(1, inUse: true)]))
    XCTAssertTrue(onAir.stopNeedsConfirmation)
    XCTAssertEqual(onAir.stopConfirmationMessage, "Camera 1 is on air. Stopping the camera ends its video output.")

    let idle = presented(separate([camera(1)]))
    XCTAssertFalse(idle.stopNeedsConfirmation)
    XCTAssertTrue(idle.canStop)
    XCTAssertFalse(idle.canStart)

    let stopped = presented(separate([camera(1, running: false)]))
    XCTAssertFalse(stopped.canStop)
    XCTAssertTrue(stopped.canStart)
    var missing = camera(1, running: false)
    missing.deviceAvailable = false
    XCTAssertFalse(presented(separate([missing])).canStart)
  }

  func testActionNeedsConfirmation() {
    let presentation = UIPresentationBuilder.session(separate([camera(1, recording: .recording), camera(2)]))
    XCTAssertEqual(UIAction.stopCamera(cameraID: "camera-1").needsConfirmation(in: presentation),
      "Camera 1 is recording. Stopping the camera ends the take.")
    XCTAssertNil(UIAction.stopCamera(cameraID: "camera-2").needsConfirmation(in: presentation))
    XCTAssertEqual(UIAction.stopAllCameras.needsConfirmation(in: presentation), "1 recording ends.",
      "The dialog title asks the question; the message doesn't repeat it")
    XCTAssertNil(UIAction.cut(cameraID: "camera-2").needsConfirmation(in: presentation))
    XCTAssertNil(UIAction.toggleRecording(cameraID: "camera-1").needsConfirmation(in: presentation))

    let busy = UIPresentationBuilder.session(program([camera(1, recording: .recording), camera(2, recording: .paused)]))
    XCTAssertEqual(UIAction.stopAllCameras.needsConfirmation(in: busy),
      "2 recordings end and on-air video stops.")
    XCTAssertEqual(UIAction.stopAllCameras.needsConfirmation(in: UIPresentationBuilder.session(program([camera(1), camera(2)]))),
      "On-air video stops.")
    let quiet = UIPresentationBuilder.session(separate([camera(1), camera(2)]))
    XCTAssertNil(UIAction.stopAllCameras.needsConfirmation(in: quiet))
  }

  // MARK: Status bar

  func testStatusSegmentOrderAndTexts() {
    var session = program([camera(1, recording: .recording), camera(2, recording: .recording)])
    session.autoSwitching = true
    session.strategy = .naturalTalkingHead
    session.drives = [UIDrive(name: "8TB", availableBytes: 1, totalBytes: 2, secondsLeft: 6720),
      UIDrive(name: "Archive", availableBytes: 1, totalBytes: 2, secondsLeft: 20400)]
    let presentation = UIPresentationBuilder.session(session)
    XCTAssertEqual(presentation.statusSegments.map(\.kind), [.output, .program, .recording, .audio])
    XCTAssertEqual(presentation.statusSegments[0].text, "Ultracam · Program · In use")
    XCTAssertEqual(presentation.statusSegments[0].tone, .positive)
    XCTAssertEqual(presentation.statusSegments[1].text, "Camera 1 on air · Auto")
    XCTAssertEqual(presentation.statusSegments[2].text, "REC 2 · 12:31 · 8TB 1 h 52 m · Archive 5 h 40 m left")
    XCTAssertEqual(presentation.statusSegments[2].tone, .critical)
    XCTAssertEqual(presentation.statusSegments[3].text, "Audio OK", "Every live camera has audio")

    session.autoHold = true
    XCTAssertEqual(UIPresentationBuilder.session(session).statusSegments[1].text, "Camera 1 on air · Auto · hold")
    session.autoSwitching = false
    XCTAssertEqual(UIPresentationBuilder.session(session).statusSegments[1].text, "Camera 1 on air · Manual")

    let separatePresentation = UIPresentationBuilder.session(separate([camera(1)]))
    XCTAssertEqual(separatePresentation.statusSegments.map(\.kind), [.output, .recording, .audio])
    XCTAssertEqual(separatePresentation.statusSegments[0].text, "Ultracam · Camera 1 · Not in use")
    XCTAssertEqual(separatePresentation.statusSegments[0].tone, .neutral)
    XCTAssertEqual(separatePresentation.statusSegments[1].text, "Not recording")
    XCTAssertEqual(separatePresentation.statusSegments[2].text, "Audio OK")
  }

  func testAudioSegment() {
    var silent = camera(2)
    silent.audio = UIAudioLevels()
    let mixed = UIPresentationBuilder.session(separate([camera(1), silent]))
    let audio = mixed.statusSegments.first { $0.kind == .audio }
    XCTAssertEqual(audio?.text, "Audio: 1 of 2")
    XCTAssertEqual(audio?.tone, .warning)
    XCTAssertEqual(UIPresentationBuilder.session(separate([silent])).statusSegments.first { $0.kind == .audio }?.text,
      "No embedded audio")
    XCTAssertNil(UIPresentationBuilder.session(separate([camera(1, running: false)])).statusSegments.first { $0.kind == .audio },
      "No audio segment until a camera is live")
    // Running without HDMI: nothing to judge, so never "Audio OK".
    XCTAssertNil(UIPresentationBuilder.session(separate([camera(1, signal: .noSignal)])).statusSegments.first { $0.kind == .audio })
  }

  func testProgramStatusSaysOnAirOnlyWhileInUse() {
    let idle = UIPresentationBuilder.session(program([camera(1), camera(2)], inUse: false))
    XCTAssertEqual(idle.statusSegments.first { $0.kind == .program }?.text, "Camera 1 in Program · Manual")
    let live = UIPresentationBuilder.session(program([camera(1), camera(2)]))
    XCTAssertEqual(live.statusSegments.first { $0.kind == .program }?.text, "Camera 1 on air · Manual")
  }

  func testOneCameraHasOnlyTheSingleLayout() {
    var session = separate([camera(1)])
    session.layout = .sideBySide
    let one = UIPresentationBuilder.session(session)
    XCTAssertEqual(one.layouts, [.single])
    XCTAssertEqual(one.layout, .single, "the stored layout returns with a second camera")
    session.cameras.append(camera(2))
    XCTAssertEqual(UIPresentationBuilder.session(session).layout, .sideBySide)
  }

  func testMixedPausedRecordingSummary() {
    let mixed = UIPresentationBuilder.session(separate([camera(1, recording: .recording), camera(2, recording: .paused, elapsed: 252)]))
    XCTAssertEqual(mixed.recordingSummary, "REC 1 · paused 1 · 12:31")
    let single = UIPresentationBuilder.session(separate([camera(1, recording: .paused, elapsed: 252)]))
    XCTAssertEqual(single.recordingSummary, "REC paused · 4:12")
    var idleWithDrive = separate([camera(1)])
    idleWithDrive.drives = [UIDrive(name: "8TB", availableBytes: 1, totalBytes: 2, secondsLeft: 600)]
    XCTAssertEqual(UIPresentationBuilder.session(idleWithDrive).recordingSummary, "Not recording · 8TB 10 min left")
  }

  func testWarningPrecedence() {
    var session = separate([camera(1, signal: .noSignal, recording: .recording), camera(2, signal: .noSignal)])
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: recording, no signal")
    session.cameras[0].recording.status = .idle
    session.cameras[0].recording.error = "Drive disconnected"
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: recording failed")
    session.cameras[0].recording.error = nil
    session.drives = [UIDrive(name: "8TB", availableBytes: 1, totalBytes: 2, secondsLeft: 12 * 60)]
    XCTAssertEqual(UIPresentationBuilder.warning(session), "8TB: 12 min left")
    session.drives = []
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: no signal")
    session.cameras = [camera(1, signal: .unsupported("1080i"))]
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: unsupported format")
    session.cameras = [camera(1, signal: .deviceMissing)]
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: input disconnected")
    var mismatch = program([camera(1), camera(2)])
    mismatch.programFormatMismatch = true
    XCTAssertEqual(UIPresentationBuilder.warning(mismatch), "Program cameras use different formats")
    XCTAssertNil(UIPresentationBuilder.warning(program([camera(1), camera(2)])))
    let warned = UIPresentationBuilder.session(mismatch)
    XCTAssertEqual(warned.statusSegments.last?.kind, .warning)
    XCTAssertEqual(warned.statusSegments.last?.tone, .warning)
  }

  // MARK: Menu bar icon

  func testMenuBarIconPrecedence() {
    var warning = separate([camera(1, signal: .noSignal, recording: .recording)])
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(warning), .attention)
    warning.cameras[0].signal = .live(format: "2160p 59.94")
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(warning), .recording)
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(separate([camera(1)])), .live)
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(separate([camera(1, processing: false)])), .bypass)
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(separate([camera(1, running: false)])), .stopped)
    var waiting = camera(1, running: false)
    waiting.automaticStart = true
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(separate([waiting])), .waiting)
    for icon in [UIMenuBarIcon.stopped, .waiting, .live, .bypass, .recording, .attention] {
      XCTAssertTrue(icon.accessibilityLabel.hasPrefix("Ultracam"))
      XCTAssertFalse(icon.symbol.isEmpty)
    }
  }

  // MARK: Formatting

  func testFormatting() {
    XCTAssertEqual(UIFormat.elapsed(751), "00:12:31")
    XCTAssertEqual(UIFormat.elapsed(-5), "00:00:00")
    XCTAssertEqual(UIFormat.elapsed(3767), "01:02:47")
    XCTAssertEqual(UIFormat.shortElapsed(751), "12:31")
    XCTAssertEqual(UIFormat.shortElapsed(3767), "1:02:47")
    XCTAssertEqual(UIFormat.duration(6720), "1 h 52 m")
    XCTAssertEqual(UIFormat.duration(600), "10 min")
    XCTAssertEqual(UIFormat.duration(20400), "5 h 40 m")
    XCTAssertEqual(UIFormat.bitrate(707), "707 Mb/s")
    XCTAssertEqual(UIFormat.bitrate(10609.61), "10.6 Gb/s")
    XCTAssertEqual(UIFormat.bitrate(0), "—")
    XCTAssertEqual(UIFormat.bitrate(.nan), "—")
  }

  // MARK: Chips, titles, labels

  func testChipsAndHelpText() {
    var withLUT = camera(1)
    withLUT.lutName = "FX3.cube"
    withLUT.effects = [true, true, false, false]
    let chips = presented(separate([withLUT])).chips
    XCTAssertEqual(chips.map(\.title), ["LUT", "1080p", "4:2:0", "29.97"])
    XCTAssertEqual(chips.map(\.isOn), [true, true, false, false])
    XCTAssertTrue(chips[0].enabled)
    XCTAssertTrue(chips[0].help.contains("Doesn't change the camera output format"), "LUT is live-safe")
    for chip in chips.dropFirst() { XCTAssertTrue(chip.help.contains("Changes the camera output format"), chip.help) }
    for chip in chips { assertNoAppNames(chip.help) }
    let noLUT = presented(separate([camera(1)])).chips
    XCTAssertFalse(noLUT[0].enabled)
    XCTAssertEqual(noLUT[0].help, "Load a .cube LUT to enable this effect.")
  }

  func testCamerasControlTitle() {
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1)])).camerasControlTitle, "Stop Camera")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, running: false)])).camerasControlTitle, "Start Camera")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1), camera(2)])).camerasControlTitle, "Stop Cameras")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, running: false), camera(2, running: false)])).camerasControlTitle,
      "Start Cameras")
    XCTAssertTrue(UIPresentationBuilder.session(separate([camera(1), camera(2, running: false)])).camerasRunning)
  }

  func testStatusBadgesAndAccessibilityLabels() {
    XCTAssertEqual(presented(separate([camera(1)])).statusBadge, "2160p 59.94")
    XCTAssertEqual(presented(separate([camera(1, running: false)])).statusBadge, "Stopped")
    XCTAssertEqual(presented(separate([camera(1, signal: .connecting)])).statusBadge, "Starting…")
    XCTAssertEqual(presented(separate([camera(1, signal: .noSignal)])).statusBadge, "No signal")
    XCTAssertEqual(presented(separate([camera(1, signal: .noSignal)])).statusTone, .warning)
    var missing = camera(1, running: false)
    missing.deviceAvailable = false
    XCTAssertEqual(presented(separate([missing])).statusBadge, "No input", "No input was ever chosen")
    missing.inputName = "UltraStudio 4K Mini"
    XCTAssertEqual(presented(separate([missing])).statusBadge, "Input missing")

    let label = presented(program([camera(1, recording: .recording), camera(2)])).accessibilityLabel
    XCTAssertEqual(label, "Camera 1, On air, recording 12:31")
    XCTAssertEqual(presented(separate([camera(1, recording: .paused, elapsed: 252)])).accessibilityLabel,
      "Camera 1, recording paused at 4:12")
  }

  func testSelectionCollapseAndTitles() {
    var session = separate([camera(1), camera(2)])
    session.selectedID = "camera-2"
    session.collapsed = ["camera-1"]
    let presentation = UIPresentationBuilder.session(session)
    XCTAssertFalse(presentation.cameras[0].selected)
    XCTAssertTrue(presentation.cameras[1].selected)
    XCTAssertEqual(presentation.selected?.id, "camera-2")
    XCTAssertTrue(presentation.cameras[0].collapsed)
    XCTAssertFalse(presentation.cameras[1].collapsed)
    session.layout = .fourUp
    XCTAssertTrue(UIPresentationBuilder.session(session).cameras.allSatisfy(\.collapsed), "Four Up collapses strips")
    XCTAssertEqual(presentation.cameras.map(\.number), [1, 2])
    // The title is always "Ultracam"; the state lives in the subtitle and the status bar.
    XCTAssertEqual(presentation.title, "Ultracam")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, inUse: true)])).title, "Ultracam")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, recording: .recording)])).title, "Ultracam")
    XCTAssertEqual(UIPresentationBuilder.session(program([camera(1)])).title, "Ultracam")
    XCTAssertEqual(UIPresentationBuilder.session(program([camera(1)], inUse: false)).title, "Ultracam")
    XCTAssertEqual(UILayout.allCases.map(\.title), ["Single", "Side by Side", "Program View", "Four Up"])
  }

  // MARK: Conformance-review additions

  func testAutomaticStartFailureAndLUTWarnings() {
    var failed = camera(1, running: false)
    failed.automaticStart = true
    failed.automaticStartFailed = true
    let session = separate([failed])
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: couldn't start")
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(session), .attention)
    XCTAssertTrue(UIPresentationBuilder.session(session).cameras[0].automaticStartFailed)

    var lut = camera(1)
    lut.lutError = "Saved LUT could not be restored: file moved"
    XCTAssertEqual(UIPresentationBuilder.warning(separate([lut])), "Camera 1: LUT unavailable")
    XCTAssertEqual(UIPresentationBuilder.session(separate([lut])).cameras[0].lutError, lut.lutError)

    // A recording problem still outranks a LUT problem.
    var recordingNoSignal = camera(2, signal: .noSignal, recording: .recording)
    recordingNoSignal.lutError = "x"
    XCTAssertEqual(UIPresentationBuilder.warning(separate([lut, recordingNoSignal])), "Camera 2: recording, no signal")
  }

  func testRemoveAndResetNeedConfirmation() {
    let presentation = UIPresentationBuilder.session(separate([camera(1), camera(2)]))
    let remove = UIAction.removeCamera(cameraID: "camera-2").needsConfirmation(in: presentation)
    XCTAssertEqual(remove, "Its settings are deleted. Recordings on disk are kept.")
    XCTAssertNotNil(UIAction.resetAllSettings.needsConfirmation(in: presentation))
    XCTAssertTrue(UIAction.resetAllSettings.needsConfirmation(in: presentation)?.contains("Recordings are not touched") == true)
    XCTAssertNil(UIAction.swapPictures.needsConfirmation(in: presentation))
    XCTAssertNil(UIAction.expandPicture(cameraID: "camera-1").needsConfirmation(in: presentation))
    XCTAssertNil(UIAction.forgetLUT(cameraID: "camera-1").needsConfirmation(in: presentation))
  }

  // MARK: Polish round (docs/ui-polish)

  func testAutoSwitchingNeedsAStrategyThatSwitches() {
    var session = program([camera(1), camera(2)])
    session.autoSwitching = true
    // S1: the default Manual strategy never cuts, so Auto never shows as on.
    let manual = UIPresentationBuilder.session(session)
    XCTAssertFalse(manual.canAutoSwitch)
    XCTAssertFalse(manual.autoSwitching)
    XCTAssertFalse(manual.canHoldShot)
    XCTAssertEqual(manual.statusSegments.first { $0.kind == .program }?.text, "Camera 1 on air · Manual")

    session.strategy = .fixedInterval
    let fixed = UIPresentationBuilder.session(session)
    XCTAssertTrue(fixed.canAutoSwitch)
    XCTAssertTrue(fixed.autoSwitching)
    XCTAssertFalse(fixed.canHoldShot, "Hold only reaches the natural talking head director")
    session.autoHold = true
    XCTAssertEqual(UIPresentationBuilder.session(session).statusSegments.first { $0.kind == .program }?.text,
      "Camera 1 on air · Auto", "A hold that does nothing isn't shown")

    session.strategy = .naturalTalkingHead
    XCTAssertTrue(UIPresentationBuilder.session(session).canHoldShot)
    session.autoSwitching = false
    XCTAssertTrue(UIPresentationBuilder.session(session).canAutoSwitch)
    XCTAssertFalse(UIPresentationBuilder.session(session).canHoldShot, "Hold needs Auto on")

    var separateSession = separate([camera(1)])
    separateSession.strategy = .fixedInterval
    separateSession.autoSwitching = true
    XCTAssertFalse(UIPresentationBuilder.session(separateSession).canAutoSwitch, "Auto is a Program mode control")
    XCTAssertFalse(UIPresentationBuilder.session(separateSession).autoSwitching)
  }

  func testCanStartAny() {
    XCTAssertTrue(UIPresentationBuilder.session(separate([camera(1)])).canStartAny, "Running: the control stops")
    XCTAssertTrue(UIPresentationBuilder.session(separate([camera(1, running: false)])).canStartAny)
    var missing = camera(1, running: false)
    missing.deviceAvailable = false
    XCTAssertFalse(UIPresentationBuilder.session(separate([missing])).canStartAny, "Nothing can start without an input")
    XCTAssertTrue(UIPresentationBuilder.session(separate([missing, camera(2, running: false)])).canStartAny)
    XCTAssertFalse(UIPresentationBuilder.session(separate([])).canStartAny)
  }

  func testTallyLabelsAreSentenceCase() {
    XCTAssertEqual(UITally.onAir.label, "On air")
    XCTAssertEqual(UITally.program.label, "Program")
    XCTAssertEqual(UITally.next.label, "Next")
    XCTAssertNil(UITally.none.label)
    XCTAssertEqual(UITally.next.badge, "NEXT", "The picture keeps all caps")
    XCTAssertEqual(presented(program([camera(1), camera(2)], pending: "camera-2"), 1).accessibilityLabel, "Camera 2, Next")
  }

  func testFailedRecordingIsOrangeAndSaysFailed() {
    var failed = camera(1, inUse: true)
    failed.recording.error = "The drive was disconnected."
    let presentation = presented(separate([failed]))
    XCTAssertEqual(presentation.recordTitle, "Recording failed")
    XCTAssertEqual(presentation.recordDetail, "The drive was disconnected.")
    XCTAssertEqual(presentation.recordTone, .warning, "Red is only for recording and on air (D8)")
    var flagged = camera(1)
    flagged.recording.failed = true
    XCTAssertEqual(presented(separate([flagged])).recordDetail, "The recording ended with an error.")
    XCTAssertEqual(presented(separate([camera(1, recording: .recording)])).recordTone, .critical)
  }

  func testFailedAutomaticStartBadge() {
    var failed = camera(1, running: false)
    failed.automaticStart = true
    failed.automaticStartFailed = true
    let presentation = presented(separate([failed]))
    XCTAssertEqual(presentation.statusBadge, "Couldn't start")
    XCTAssertEqual(presentation.statusTone, .warning)
    XCTAssertTrue(presentation.canStart)
    failed.deviceAvailable = false
    failed.inputName = "UltraStudio 4K Mini"
    XCTAssertEqual(presented(separate([failed])).statusBadge, "Input missing", "A missing input says what to fix")
    XCTAssertEqual(presented(separate([camera(1, running: false)])).statusBadge, "Stopped")
  }

  func testSubtitleOnlyCarriesWhatTheStatusBarDoesNot() {
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1)])).subtitle, "")
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1, recording: .recording, inUse: true)])).subtitle, "")
    XCTAssertEqual(UIPresentationBuilder.session(program([camera(1), camera(2)])).subtitle, "Camera 1 on air")
    XCTAssertEqual(UIPresentationBuilder.session(program([camera(1), camera(2)], inUse: false)).subtitle, "Camera 1 in Program")
    XCTAssertEqual(UIPresentationBuilder.session(program([camera(1), camera(2)], onAir: nil)).subtitle, "")
  }

  func testWaitingRecordDetailNamesWhatIsMissing() {
    let noSignal = presented(separate([camera(1, signal: .noSignal)]))
    XCTAssertEqual(noSignal.stripState, .waiting)
    XCTAssertEqual(noSignal.recordTitle, "Can't record yet")
    XCTAssertEqual(noSignal.recordDetail, "Needs a supported signal")
    XCTAssertEqual(presented(separate([camera(1, signal: .noSignal, folder: nil)])).recordDetail,
      "Needs a supported signal and a recording folder")
    XCTAssertEqual(presented(separate([camera(1, signal: .unsupported("1080i"))])).recordTitle, "Can't record yet",
      "Not \"Waiting for HDMI\" when HDMI is there in the wrong format")
  }

  func testSizeLineBeforeBytesArrive() {
    XCTAssertEqual(presented(separate([camera(1, signal: .noSignal, recording: .recording)])).sizeLine, "— · —")
    var writing = camera(1, recording: .recording)
    writing.recording.fileBytes = 1_000_000
    writing.recording.megabitsPerSecond = 707
    XCTAssertEqual(presented(separate([writing])).sizeLine, "\(UIFormat.bytes(1_000_000)) · 707 Mb/s")
  }

  func testStatusBarLeavesPlainNoSignalToTheSinglePicture() {
    let one = separate([camera(1, signal: .noSignal)])
    XCTAssertNil(UIPresentationBuilder.session(one).statusSegments.first { $0.kind == .warning },
      "One camera: its picture already says No signal")
    XCTAssertEqual(UIPresentationBuilder.warning(one), "Camera 1: no signal", "The menu bar still warns")
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(one), .attention)
    let two = separate([camera(1, signal: .noSignal), camera(2)])
    XCTAssertEqual(UIPresentationBuilder.session(two).statusSegments.last?.text, "Camera 1: no signal")
    let unsupported = separate([camera(1, signal: .unsupported("1080i"))])
    XCTAssertEqual(UIPresentationBuilder.session(unsupported).statusSegments.last?.text, "Camera 1: unsupported format")
  }

  func testMenuBarPreviewShowsTheCameraInTheMeeting() {
    var session = separate([camera(1), camera(2, inUse: true)])
    session.selectedID = "camera-1"
    XCTAssertEqual(UIPresentationBuilder.session(session).previewCamera?.id, "camera-2")
    session.cameras[1].inUse = false
    XCTAssertEqual(UIPresentationBuilder.session(session).previewCamera?.id, "camera-1", "Nothing on air: the selected camera")
  }

  func testConfirmationTitlesAndButtons() {
    let presentation = UIPresentationBuilder.session(separate([camera(1, recording: .recording), camera(2)]))
    XCTAssertEqual(UIAction.stopCamera(cameraID: "camera-1").confirmationTitle(in: presentation), "Stop Camera 1?")
    XCTAssertEqual(UIAction.removeCamera(cameraID: "camera-2").confirmationTitle(in: presentation), "Remove Camera 2?")
    XCTAssertEqual(UIAction.stopAllCameras.confirmationTitle(in: presentation), "Stop All Cameras?")
    XCTAssertEqual(UIAction.resetAllSettings.confirmationTitle(in: presentation), "Reset All Settings?")
    // S2: the destructive button says what it does, never "Stop Camera" for a removal or a reset.
    XCTAssertEqual(UIAction.stopCamera(cameraID: "camera-1").confirmationButtonTitle, "Stop Camera")
    XCTAssertEqual(UIAction.stopAllCameras.confirmationButtonTitle, "Stop All Cameras")
    XCTAssertEqual(UIAction.removeCamera(cameraID: "camera-2").confirmationButtonTitle, "Remove Camera")
    XCTAssertEqual(UIAction.resetAllSettings.confirmationButtonTitle, "Reset and Quit")
    for action in [UIAction.removeCamera(cameraID: "camera-2"), .resetAllSettings, .stopAllCameras] {
      let message = action.needsConfirmation(in: presentation) ?? ""
      XCTAssertFalse(message.contains("?"), "The message doesn't repeat the title's question: \(message)")
    }
    XCTAssertNil(UIAction.beginRename(cameraID: "camera-1").needsConfirmation(in: presentation))
    XCTAssertNil(UIAction.resumeAll.needsConfirmation(in: presentation))
  }

  func testRevealRecordingsNeedsAFolder() {
    XCTAssertTrue(UIPresentationBuilder.session(separate([camera(1)])).canRevealRecordings)
    XCTAssertFalse(UIPresentationBuilder.session(separate([camera(1, folder: nil)])).canRevealRecordings)
    var withDefault = separate([camera(1, folder: nil)])
    withDefault.defaultFolderPath = "/Volumes/8TB/Takes"
    XCTAssertTrue(UIPresentationBuilder.session(withDefault).canRevealRecordings)
  }

  // MARK: Disk full (r3 P0-5)

  private let roomy = UIDrive(name: "8TB", availableBytes: 595_000_000_000, totalBytes: 8_000_000_000_000, secondsLeft: 6720)

  func testDiskFullFromTheErrorText() {
    let errors = [
      "Recording writer failed: The operation couldn’t be completed. No space left on device",
      "Recording requires 134217728 bytes of free space; only 1024 are available.",
      "Recording writer failed: The file “Camera 1.mov” couldn’t be saved because there isn’t enough space.",
      "Recording writer failed: The operation could not be completed. (AVFoundationErrorDomain error -11807.)",
      "Recording writer failed: Disk Full",
    ]
    for error in errors {
      var failed = camera(1)
      failed.recording.error = error
      var session = separate([failed])
      session.drives = [roomy]
      let presentation = presented(session)
      XCTAssertEqual(presentation.stripState, .failed, error)
      XCTAssertEqual(presentation.recordTitle, "Disk full", error)
      XCTAssertEqual(presentation.recordDetail, "Free space on 8TB or choose another folder", error)
      XCTAssertEqual(presentation.recordTone, .warning, "Orange like any failed take; red is only for recording and on air (D8)")
      XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: disk full", error)
      XCTAssertEqual(UIPresentationBuilder.menuBarIcon(session), .attention)
      XCTAssertEqual(UIPresentationBuilder.session(session).statusSegments.last?.text, "Camera 1: disk full")
    }
  }

  func testDiskFullFromTheDriveAfterAFailedTake() {
    var failed = camera(1)
    failed.recording.failed = true
    failed.recording.error = "Recording writer failed: AVAssetWriter finish failed."
    var session = separate([failed])
    session.drives = [UIDrive(name: "8TB", availableBytes: 40_000_000, totalBytes: 8_000_000_000_000, secondsLeft: 0.4)]
    XCTAssertEqual(presented(session).recordTitle, "Disk full")
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: disk full")
    // The same error with room left on the drive is an ordinary failure.
    session.drives = [roomy]
    XCTAssertEqual(presented(session).recordTitle, "Recording failed")
    XCTAssertEqual(presented(session).recordDetail, "Recording writer failed: AVAssetWriter finish failed.")
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: recording failed")
    // A drive that can't be read (zero size) says nothing about space.
    session.drives = [UIDrive(name: "8TB", availableBytes: 0, totalBytes: 0, secondsLeft: nil)]
    XCTAssertEqual(presented(session).recordTitle, "Recording failed")
  }

  func testDiskFullNamesTheTakesDrive() {
    var failed = camera(1, folder: "/Volumes/Archive/Takes")
    failed.recording.error = "No space left on device"
    var session = separate([failed, camera(2)])
    session.drives = [roomy, UIDrive(name: "Archive", availableBytes: 0, totalBytes: 4_000_000_000_000, secondsLeft: nil)]
    XCTAssertEqual(presented(session).recordDetail, "Free space on Archive or choose another folder")
    // A folder on the startup disk: the only drive is that disk.
    var home = camera(1, folder: "/Users/andrew/Movies")
    home.recording.error = "No space left on device"
    var startup = separate([home])
    startup.drives = [UIDrive(name: "Macintosh HD", availableBytes: 0, totalBytes: 1_000_000_000_000, secondsLeft: nil)]
    XCTAssertEqual(presented(startup).recordDetail, "Free space on Macintosh HD or choose another folder")
    // Unknown drive: generic wording, still a next step.
    startup.drives = []
    XCTAssertEqual(presented(startup).recordDetail, "Free space on the drive or choose another folder")
    for text in [presented(session).recordTitle, presented(session).recordDetail] { assertNoAppNames(text) }
  }

  func testOtherFailuresStayRecordingFailed() {
    for error in ["The drive was disconnected.", "Free space could not be determined for the recording volume.",
      "Recording writer failed: VideoToolbox callback failed (OSStatus -12909)."] {
      var failed = camera(1)
      failed.recording.error = error
      var session = separate([failed])
      session.drives = [roomy]
      XCTAssertEqual(presented(session).recordTitle, "Recording failed", error)
      XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: recording failed", error)
    }
  }

  func testFullDriveWarnsAndShowsNoSpaceLeft() {
    // At zero free bytes the drive reports no time left at all; the < 30 min warning never saw it.
    var session = separate([camera(1, recording: .recording)])
    session.drives = [UIDrive(name: "8TB", availableBytes: 0, totalBytes: 8_000_000_000_000, secondsLeft: nil)]
    XCTAssertEqual(UIPresentationBuilder.warning(session), "8TB: no space left")
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(session), .attention)
    XCTAssertEqual(presented(session).timeLeftLine, "No space left")
    // Low but not empty keeps the existing time-left warning.
    session.drives = [UIDrive(name: "8TB", availableBytes: 9_000_000_000, totalBytes: 8_000_000_000_000, secondsLeft: 100)]
    XCTAssertEqual(UIPresentationBuilder.warning(session), "8TB: 1 min left")
    XCTAssertNil(presented(session).timeLeftLine, "The camera's own secondsLeft drives this line")
    session.drives = [roomy]
    XCTAssertNil(UIPresentationBuilder.warning(session))
  }

  // MARK: Program sources (r3 P1-9)

  func testOnAirCameraLosingItsPicture() {
    var session = program([camera(1), camera(2)])
    session.cameras[0].signal = .noSignal
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 on air: no signal")
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(session), .attention)
    session.cameras[0].signal = .unsupported("1080i")
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 on air: unsupported format")
    session.cameras[0].signal = .deviceMissing
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 on air: input disconnected")
    session.cameras[0] = camera(1, running: false)
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 on air: stopped")
    session.cameras[0].deviceAvailable = false
    session.cameras[0].inputName = "UltraStudio 4K Mini"
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 on air: input missing")
    // Without a viewer it's the Program camera, not on air.
    session.programInUse = false
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 in Program: input missing")
    // Still starting is not a problem yet.
    session.cameras[0] = camera(1, signal: .connecting)
    XCTAssertNil(UIPresentationBuilder.warning(session))
    // Nor is an automatic camera about to start for the meeting that just connected, alone or not.
    session.programInUse = true
    session.cameras[0] = camera(1, running: false)
    session.cameras[0].automaticStart = true
    XCTAssertNil(UIPresentationBuilder.warning(session))
    var joining = program([session.cameras[0]])
    XCTAssertNil(UIPresentationBuilder.warning(joining))
    joining.cameras.append(camera(2, running: false))
    XCTAssertNil(UIPresentationBuilder.warning(joining), "No camera has a picture yet, but one is starting")
    // Once it has failed, the failure says so.
    joining.cameras[0].automaticStartFailed = true
    XCTAssertEqual(UIPresentationBuilder.warning(joining), "Camera 1: couldn't start")
    // A camera that's not on air keeps its plain warning.
    session = program([camera(1), camera(2, signal: .noSignal)])
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 2: no signal")
  }

  func testOnAirWarningIsShownEvenWithOneCamera() {
    // The status bar leaves a plain no-signal to the one picture, but not what the meeting sees.
    let one = program([camera(1, signal: .noSignal)])
    XCTAssertEqual(UIPresentationBuilder.session(one).statusSegments.last?.text, "Camera 1 on air: no signal")
    XCTAssertEqual(UIPresentationBuilder.warning(one), "Camera 1 on air: no signal")
    // Idle Program with nobody watching and nothing running is not a problem.
    XCTAssertNil(UIPresentationBuilder.warning(program([camera(1, running: false)], inUse: false)))
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(program([camera(1, running: false)], inUse: false)), .stopped)
  }

  func testNoCameraHasAPicture() {
    var session = program([camera(1, signal: .noSignal), camera(2, running: false)])
    XCTAssertEqual(UIPresentationBuilder.warning(session), "No camera has a picture")
    XCTAssertEqual(UIPresentationBuilder.menuBarIcon(session), .attention)
    session.onAirID = nil
    XCTAssertEqual(UIPresentationBuilder.warning(session), "No camera has a picture")
    // Nobody watching: each camera's own problem instead.
    session.programInUse = false
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: no signal")
    // A camera still starting gets its chance.
    session.programInUse = true
    session.cameras[1] = camera(2, signal: .connecting)
    XCTAssertNotEqual(UIPresentationBuilder.warning(session), "No camera has a picture")
    // Separate mode has no Program to warn about.
    XCTAssertEqual(UIPresentationBuilder.warning(separate([camera(1, signal: .noSignal), camera(2, running: false)])),
      "Camera 1: no signal")
    for text in ["No camera has a picture", "Camera 1 on air: no signal"] { assertNoAppNames(text) }
  }

  func testProgramWarningPrecedence() {
    // A take losing its picture still comes first; it's the one thing that can't be redone.
    var session = program([camera(1, signal: .noSignal, recording: .recording), camera(2)])
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: recording, no signal")
    session.cameras[0].recording.status = .idle
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 on air: no signal")
    // On air beats a low drive and another camera's plain no-signal.
    session.cameras.append(camera(3, signal: .noSignal))
    session.drives = [UIDrive(name: "8TB", availableBytes: 1, totalBytes: 2, secondsLeft: 12 * 60)]
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1 on air: no signal")
    // An automatic start that failed names the fix (Retry) first.
    session.cameras[0] = camera(1, running: false)
    session.cameras[0].automaticStart = true
    session.cameras[0].automaticStartFailed = true
    XCTAssertEqual(UIPresentationBuilder.warning(session), "Camera 1: couldn't start")
  }
}
