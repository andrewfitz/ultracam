import AppKit
import Foundation
import XCTest

/// Phase 3 of the UI plan: the global format and its fallback, the toolbar's controls, the
/// status bar's typed pieces, the menu bar panel, the background shortcuts and the rule that
/// Cancel is the default on everything that ends something.
@objcMembers final class UIMainWindowChecks: XCTestCase {
  private func source(_ pixel: PixelFormatID) throws -> SourceFormat {
    try SourceFormat(width: 3840, height: 2160, pixel: pixel, rate: .constant(VideoContract.fastDuration))
  }

  private func camera(_ index: Int, recording: UIRecordingStatus = .idle, inUse: Bool = false,
    source: SourceFormat? = nil) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-\(index)", name: "Camera \(index)")
    camera.running = true
    camera.signal = .live(format: "2160p 59.94")
    camera.sourceFormat = source
    camera.inUse = inUse
    camera.sinkConnected = inUse
    camera.recording.status = recording
    camera.recording.elapsed = recording == .idle ? 0 : 751
    camera.recording.folderPath = "/Volumes/8TB/Takes"
    camera.audio = UIAudioLevels(present: true)
    return camera
  }

  private func session(_ cameras: [UICameraSnapshot], codec: RecordingCodec = .hevcMain10_422) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.cameras = cameras
    session.selectedID = cameras.first?.id ?? ""
    session.codec = codec
    session.onAirID = cameras.count > 1 ? cameras.first?.id : nil
    return session
  }

  // MARK: Format

  func testFallbackFollowsTheTableAndOnlyWhenTheSourceCantRecord() throws {
    let packed422 = try source(.v210)
    XCTAssertNil(RecordingCodec.hevcMain10_422.fallback(for: packed422), "A source that can use the choice keeps it")
    XCTAssertEqual(RecordingCodec.proRes4444.fallback(for: packed422), .proRes42210Bit, "4444 on 4:2:2 falls back to HQ")
    XCTAssertEqual(RecordingCodec.hevcMain10.fallback(for: packed422), .hevcMain10_422, "HEVC 4:2:0 on 4:2:2 keeps HEVC")
    XCTAssertEqual(RecordingCodec.proRes4444.resolved(for: nil), .proRes4444, "Before any signal nothing is flagged")
  }

  func testStripShowsTheFallbackAndTheProblemNamesItsRate() throws {
    let state = session([camera(1, source: try source(.v210))], codec: .proRes4444)
    let presented = UIPresentationBuilder.session(state).cameras[0]
    XCTAssertEqual(presented.formatTitle, "ProRes 422 HQ")
    XCTAssertEqual(presented.formatFallback, "ProRes 4444 → ProRes 422 HQ")
    XCTAssertTrue(presented.formatHelp.contains("isn't available for 2160p 59.94"), presented.formatHelp)
    let problem = UIPresentationBuilder.problems(state).first { $0.id == "format.camera-1" }
    XCTAssertEqual(problem?.title, "ProRes 4444 → ProRes 422 HQ")
    XCTAssertTrue(problem?.detail?.hasPrefix("Camera 1 records ~") == true, problem?.detail ?? "")
  }

  func testARollingCameraShowsItsTakesOwnFormat() throws {
    var rolling = camera(1, recording: .recording, source: try source(.v210))
    rolling.recording.takeCodec = .proRes42210Bit
    let presented = UIPresentationBuilder.session(session([rolling], codec: .hevcMain10_422)).cameras[0]
    XCTAssertEqual(presented.formatTitle, "ProRes 422 HQ", "The take's codec, not the choice made since")
    XCTAssertNil(presented.formatFallback)
  }

  @MainActor func testRecordResolvesTheTakesFormatFromTheSource() throws {
    let feed = FeedID(rawValue: "camera-1")
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: feed, name: "Camera 1")])
    model.setOutputFolder(FileManager.default.temporaryDirectory, for: feed)
    model.codec = .proRes4444
    let format = try source(.v210)
    model.sourceFormat = { _ in format }
    model.record(feedID: feed)
    XCTAssertEqual(model.feeds.first?.takeCodec, .proRes42210Bit)
    XCTAssertEqual(model.feeds.first?.takeFallbackFrom, .proRes4444)
    XCTAssertEqual(model.codec, .proRes4444, "The camera's choice is kept")
  }

  func testFormatChoicesGiveRatesAndSayWhatTheyNeed() throws {
    var state = session([camera(1, source: try source(.v210))])
    state.drives = [UIDrive(name: "8TB", availableBytes: 595_000_000_000, totalBytes: 8_000_000_000_000, secondsLeft: nil)]
    let choices = UIPresentationBuilder.formatChoices(state)
    let hevc = choices.first { $0.codec == .hevcMain10_422 }
    XCTAssertEqual(hevc?.selected, true)
    XCTAssertTrue(hevc?.rate?.hasPrefix("~") == true, "Every rate is an estimate")
    XCTAssertTrue(hevc?.left?.hasSuffix("left") == true)
    XCTAssertEqual(choices.first { $0.codec == .proRes4444 }?.reason, "Needs an RGB source")
    XCTAssertNil(choices.first { $0.codec == .proRes4444 }?.rate)
  }

  // MARK: Toolbar and switching

  func testHoldWorksWithEveryAutomaticStrategy() {
    var state = session([camera(1), camera(2)])
    state.autoSwitching = true
    state.strategy = .fixedInterval
    XCTAssertTrue(UIPresentationBuilder.session(state).canHoldShot, "Hold reaches Fixed interval too")
    state.autoHold = true
    XCTAssertTrue(UIPresentationBuilder.session(state).autoHoldOn)
    state.autoSwitching = false
    XCTAssertFalse(UIPresentationBuilder.session(state).canHoldShot, "Hold needs Auto on")
  }

  func testOneMenuCommandPerToolbarControl() {
    XCTAssertEqual(UIMonitorTool.menuOrder.map(\.key), ["g", "z", "l", "f", "k"], "Every tool has its ⌥⌘ key")
  }

  // MARK: Status bar

  func testStatusBarIsTypedPiecesWithNoDotJoins() {
    var state = session([camera(1, recording: .recording), camera(2)])
    state.programInUse = true
    state.programSinkConnected = true
    state.drives = [UIDrive(name: "8TB", availableBytes: 1, totalBytes: 2, secondsLeft: 6720)]
    let presentation = UIPresentationBuilder.session(state)
    XCTAssertEqual(presentation.statusSegments.map(\.kind), [.program, .recording, .audio],
      "With Program and no camera's own device in use, Program's segment carries the virtual camera glyph")
    for segment in presentation.statusSegments {
      XCTAssertFalse(segment.text.contains(" · "), segment.text)
      for case .strong(let text) in segment.pieces { XCTAssertFalse(text.contains(" · "), text) }
    }
    let program = presentation.statusSegments[0]
    XCTAssertEqual(program.pieces.prefix(3), [.virtualCamera(inUse: true), .strong("Program"), .dim("Camera 1")])
    let recording = presentation.statusSegments[1]
    XCTAssertTrue(recording.pieces.contains(.recordingDot))
    XCTAssertTrue(recording.pieces.contains(.value([UIValuePart(number: "1", unit: "h"), UIValuePart(number: "52", unit: "m")])),
      "The worst drive's time left, strong digits and dim units")
    XCTAssertEqual(presentation.statusSegments[2].text, "Audio 2 of 2")
  }

  func testDurationIsOneFormEverywhere() {
    XCTAssertEqual(UIFormat.duration(6720), "1 h 52 m")
    XCTAssertEqual(UIFormat.duration(1320), "22 min")
  }

  // MARK: Left pane

  func testVirtualCamerasPutProgramFirstAndSayInUseOnlyWhenTrue() {
    var state = session([camera(1), camera(2, inUse: true)])
    state.programInUse = true
    let rows = UIPresentationBuilder.session(state).virtualCameras
    XCTAssertEqual(rows.map(\.name), ["Ultracam · Program", "Ultracam · Camera 1", "Ultracam · Camera 2"])
    XCTAssertEqual(rows.map(\.inUse), [true, false, true])
  }

  func testFolderActionNamesWhatItChanges() {
    var state = session([camera(1)])
    state.defaultFolderPath = "/Volumes/8TB/Takes"
    XCTAssertEqual(UIPresentationBuilder.folderAction(state), "Change…")
    state.cameras[0].recording.status = .recording
    XCTAssertEqual(UIPresentationBuilder.folderAction(state), "Folder for Next Take…")
  }

  func testExtensionRowsAreSetupNotProblems() {
    var state = session([camera(1)])
    state.install = UIInstallState(canRequestChanges: true, pending: false, status: "", unavailableReason: nil, installed: false)
    let presentation = UIPresentationBuilder.session(state)
    XCTAssertEqual(presentation.setupRows.first?.action?.title, "Install Camera Extension…")
    XCTAssertEqual(presentation.setupRows.first?.symbol, UISymbol.installExtension)
    XCTAssertFalse(presentation.statusSegments.contains { $0.kind == .warning }, "Nothing is wrong yet")
  }

  func testInterruptedTakesAreOneAttentionRow() {
    var state = session([camera(1)])
    state.interruptedTakes = [UIInterruptedTake(id: "a", title: "a.mov"), UIInterruptedTake(id: "b", title: "b.mov")]
    let row = UIPresentationBuilder.problems(state).first { $0.id == "takes.interrupted" }
    XCTAssertEqual(row?.title, "2 interrupted takes")
    XCTAssertEqual(row?.action?.action, .showInterruptedTakes)
  }

  // MARK: Confirmations

  @MainActor func testCancelIsTheDefaultOnEverythingThatEndsSomething() {
    let state = session([camera(1, recording: .recording), camera(2, recording: .recording)])
    let presentation = UIPresentationBuilder.session(state)
    for action in [UIAction.stopAllCameras, .stopAllRecordings, .stopCamera(cameraID: "camera-1"), .removeCamera(cameraID: "camera-2")] {
      let alert = UISessionBridge.confirmationAlert(for: action, message: "x", in: presentation)
      XCTAssertEqual(alert.buttons.first?.title, "Cancel", "Return answers Cancel for \(action)")
      XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
    }
    XCTAssertEqual(UIAction.stopAllRecordings.needsConfirmation(in: presentation),
      "2 recordings end. Cameras keep running and on-air video continues.")
    XCTAssertEqual(UIAction.stopAllRecordings.confirmationButtonTitle(in: presentation), "Stop 2 Recordings")
    XCTAssertEqual(UIAction.endingMessage(in: presentation), "2 recordings end.")
    var off = state
    off.askBeforeEnding = false
    XCTAssertNil(UIAction.stopAllRecordings.needsConfirmation(in: UIPresentationBuilder.session(off)), "Behind the setting")
  }

  func testSyncConfirmationNamesTheSourceCamera() {
    let presentation = UIPresentationBuilder.session(session([camera(1), camera(2)]))
    XCTAssertEqual(UIAction.setSyncCameras(true).confirmationTitle(in: presentation), "Sync cameras from Camera 1?")
    XCTAssertTrue(UIAction.setSyncCameras(true).needsConfirmation(in: presentation)?.hasPrefix("Camera 2 takes Camera 1's effects") == true)
    XCTAssertNil(UIAction.setSyncCameras(false).needsConfirmation(in: presentation), "Turning it off rewrites nothing")
  }

  // MARK: Background shortcuts

  @MainActor func testBackgroundRecordOnlyEverStarts() {
    let rolling = UIPresentationBuilder.session(session([camera(1, recording: .recording), camera(2)]))
    XCTAssertEqual(UIBackgroundShortcut.record.actions(in: rolling), [.toggleRecording(cameraID: "camera-2")],
      "It rolls the camera that can and never stops the one rolling")
    let allRolling = UIPresentationBuilder.session(session([camera(1, recording: .recording), camera(2, recording: .recording)]))
    XCTAssertEqual(UIBackgroundShortcut.record.actions(in: allRolling), [])
  }

  @MainActor func testBackgroundShortcutsAreOffByDefaultAndUseControlOptionCommand() {
    let suite = "org.ultracam.background-shortcuts.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(UIBackgroundShortcuts(defaults: defaults).enabled)
    XCTAssertEqual(UIBackgroundShortcut.all.map(\.title),
      ["⌃⌥⌘1", "⌃⌥⌘2", "⌃⌥⌘3", "⌃⌥⌘4", "⌃⌥⌘5", "⌃⌥⌘6", "⌃⌥⌘7", "⌃⌥⌘A", "⌃⌥⌘H", "⌃⌥⌘R"])
    let two = UIPresentationBuilder.session(session([camera(1), camera(2)]))
    XCTAssertEqual(UIBackgroundShortcut.cut(2).actions(in: two), [.cutNumber(2)])
    XCTAssertEqual(UIBackgroundShortcut.cut(3).actions(in: two), [], "No third camera, no cut")
  }

  // MARK: Menu bar

  @MainActor func testMenuBarHasNoSelectionRowsAndALUTRowPerCamera() {
    var state = session([camera(1, recording: .recording), camera(2, recording: .recording)])
    state.programInUse = true
    state.programSinkConnected = true
    let items = UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(state), session: state,
      target: nil, previewItem: nil)
    let titles = items.map(\.title)
    XCTAssertFalse(titles.contains("Processing"))
    XCTAssertFalse(titles.contains("Cut to Camera 1"), "The camera on Program gets no Cut row")
    XCTAssertTrue(titles.contains("Cut to Camera 2"))
    XCTAssertTrue(titles.contains("Hold Current Shot"))
    XCTAssertTrue(titles.contains("Pause All"))
    let stop = items.firstIndex { $0.title == "Stop All Cameras" }
    XCTAssertEqual(stop.map { items[$0 - 1].isSeparatorItem }, true, "A separator keeps a slip off a camera row off Stop")
    let rows = items.filter { !$0.isSeparatorItem }
    XCTAssertLessThanOrEqual(rows.count, 14, titles.joined(separator: " | "))
    for name in ["Camera 1", "Camera 2"] {
      XCTAssertTrue(items.first { $0.title == name }?.submenu?.items.contains { $0.title == "LUT" } == true)
    }
  }
}
