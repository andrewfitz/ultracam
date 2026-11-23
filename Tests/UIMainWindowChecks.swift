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

  @MainActor func testPendingCaptureAccessKeepsTheStopCommandAvailable() throws {
    var awaitingAccess = camera(1)
    awaitingAccess.running = false
    awaitingAccess.deviceAvailable = false
    awaitingAccess.captureAuthorizationPending = true
    awaitingAccess.signal = .deviceMissing
    var disconnected = camera(2)
    disconnected.running = false
    disconnected.deviceAvailable = false
    disconnected.signal = .deviceMissing
    let state = session([awaitingAccess, disconnected])
    let presentation = UIPresentationBuilder.session(state)
    let pending = try XCTUnwrap(presentation.cameras.first)
    XCTAssertFalse(presentation.camerasRunning)
    XCTAssertEqual(pending.tileState, .connecting)
    XCTAssertEqual(pending.statusBadge, "Waiting for capture access")
    XCTAssertEqual(UIInspectorViewContent.signalText(awaitingAccess), pending.statusBadge)
    XCTAssertTrue(pending.canStop)
    XCTAssertFalse(pending.canStart)
    XCTAssertEqual(presentation.startControl?.enabled, false)

    let items = UIMenuBarController.buildItems(presentation: presentation, session: state, target: nil, previewItem: nil)
    let stop = try XCTUnwrap(items.first { $0.title == "Stop All Capture" })
    XCTAssertTrue(stop.isEnabled)
    XCTAssertEqual(UIMenuBarController.commands(for: stop), [.action(.stopAllCameras)])
  }

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

  /// J 22 in the strings that help and VoiceOver read, and the labels pickers show.
  func testPlainStringsHaveNoDotJoins() {
    var state = session([camera(1), camera(2)])
    state.programSinkConnected = true
    let line = UIPresentationBuilder.session(state).cameras[0].outputLine
    XCTAssertEqual(line, "In Program, no viewer yet")
    let inputs = [(id: "input:00000000a1850ab8", name: "Recorder"), (id: "input:0000000046b8", name: "Recorder")]
    XCTAssertEqual(UIInputLabels.label(id: inputs[0].id, name: "Recorder", among: inputs), "Recorder (0AB8)")
    XCTAssertFalse(UIInputLabels.missingLabel(id: inputs[1].id, lastName: nil).contains(" · "))
  }

  // MARK: Picture tools

  /// The full bar stays, in the same row, while one of its popovers is open: the pointer leaves
  /// the picture on its way to the popover. It used to move back beside the name on a narrow
  /// picture, or leave altogether in Clean View, and the popover closed under the pointer.
  @MainActor func testAnOpenToolPopoverKeepsItsBarWhereItIs() {
    typealias Placement = UIMonitorToolButtons.Placement
    for narrow in [false, true] {
      for clean in [false, true] {
        let hovered = Placement(hovering: true, panelOpen: false, narrow: narrow, clean: clean)
        let opened = Placement(hovering: false, panelOpen: true, narrow: narrow, clean: clean)
        XCTAssertEqual(opened, hovered, "narrow \(narrow), clean \(clean)")
        XCTAssertTrue(opened.shown && opened.expanded)
        XCTAssertEqual(opened.ownRow, narrow)
      }
    }
    let rest = Placement(hovering: false, panelOpen: false, narrow: true, clean: false)
    XCTAssertEqual(rest, Placement(hovering: false, panelOpen: false, narrow: false, clean: false), "At rest, beside the name")
    XCTAssertFalse(rest.expanded || rest.ownRow)
    XCTAssertFalse(Placement(hovering: false, panelOpen: false, narrow: false, clean: true).shown, "Clean View at rest")
  }

  func testDurationIsOneFormEverywhere() {
    XCTAssertEqual(UIFormat.duration(6720), "1 h 52 m")
    XCTAssertEqual(UIFormat.duration(1320), "22 min")
  }

  // MARK: Session lists

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

  func testExtensionRowsAreSetupNotProblems() throws {
    var state = session([camera(1)])
    state.install = UIInstallState(canRequestChanges: true, pending: false, status: "", unavailableReason: nil, installed: false)
    let presentation = UIPresentationBuilder.session(state)
    XCTAssertEqual(presentation.setupRows.first?.action?.title, "Install Camera Extension…")
    XCTAssertEqual(presentation.setupRows.first?.symbol, UISymbol.installExtension)
    XCTAssertTrue(presentation.problems.isEmpty, "Nothing is wrong yet")
    // With no left pane, the status bar leads with the setup row and its one action.
    let segment = try XCTUnwrap(presentation.statusSegments.first)
    XCTAssertEqual(segment.kind, .warning)
    XCTAssertEqual(segment.level, .notice)
    XCTAssertEqual(segment.action?.action, .installCameraExtension)
    XCTAssertFalse(segment.pieces.contains(.warningGlyph), "A setup row has no warning triangle")
  }

  func testSetupRowsFollowProblemsInTheStatusBar() throws {
    var state = session([camera(1)])
    state.install = UIInstallState(canRequestChanges: true, pending: false, status: "", unavailableReason: nil, installed: false)
    state.defaultFolderPath = nil
    state.cameras[0].recording.folderPath = nil
    let presentation = UIPresentationBuilder.session(state)
    XCTAssertEqual(presentation.problems.map(\.id), ["folder.none"])
    let segment = try XCTUnwrap(presentation.statusSegments.first)
    XCTAssertTrue(segment.text.hasPrefix("No recording folder"), segment.text)
    XCTAssertTrue(segment.text.hasSuffix("+1"), "The setup row is counted behind the problem")
    XCTAssertTrue(segment.pieces.contains(.warningGlyph))
  }

  func testAlertsOfferIsASetupRowOnlyBeforeASession() {
    var state = session([camera(1)])
    state.offerAlerts = true
    var presentation = UIPresentationBuilder.session(state)
    XCTAssertEqual(presentation.setupRows.map(\.id), ["alerts.offer"])
    XCTAssertEqual(presentation.setupRows.first?.action?.action, .turnOnAlerts)
    XCTAssertEqual(presentation.setupRows.first?.dismiss?.action, .dismissAlertsPrompt)
    XCTAssertTrue(presentation.problems.isEmpty)
    state.cameras[0].running = true
    state.cameras[0].recording.status = .recording
    presentation = UIPresentationBuilder.session(state)
    XCTAssertTrue(presentation.setupRows.isEmpty, "Never while a take is rolling")
  }

  func testInterruptedTakesStayOutOfTheProblemList() {
    var state = session([camera(1)])
    state.interruptedTakes = [UIInterruptedTake(id: "a", title: "a.mov"), UIInterruptedTake(id: "b", title: "b.mov")]
    let presentation = UIPresentationBuilder.session(state)
    // History, not a fault: Recording's popover and the Record menu offer the recovery.
    XCTAssertFalse(presentation.problems.contains { $0.id == "takes.interrupted" })
    XCTAssertFalse(presentation.statusSegments.contains { $0.kind == .warning })
    XCTAssertEqual(presentation.menuBarIcon, UIPresentationBuilder.session(session([camera(1)])).menuBarIcon)
  }

  func testRecordingSegmentCarriesTheFormatAtFullWidthOnly() throws {
    let presentation = UIPresentationBuilder.session(session([camera(1)], codec: .hevcMain10_422))
    let segment = try XCTUnwrap(presentation.statusSegments.first { $0.kind == .recording })
    let title = RecordingCodec.hevcMain10_422.title
    XCTAssertTrue(segment.pieces.contains(.dim(title)), "\(segment.pieces)")
    XCTAssertFalse(segment.compactPieces.contains(.dim(title)))
    XCTAssertFalse(segment.essentialPieces.contains(.dim(title)))
    XCTAssertFalse(segment.text.contains(title), "Help and VoiceOver keep the summary as it was")
  }

  // MARK: Confirmations

  @MainActor func testCancelIsTheDefaultOnEverythingThatEndsSomething() {
    let state = session([camera(1, recording: .recording), camera(2, recording: .recording)])
    let presentation = UIPresentationBuilder.session(state)
    for action in [UIAction.stopAllCameras, .stopAllRecordings, .stopCamera(cameraID: "camera-1"), .removeCamera(cameraID: "camera-2")] {
      let alert = UISessionBridge.confirmationAlert(for: action, message: "x", in: presentation)
      XCTAssertEqual(alert.buttons.first?.title, "Cancel", "Return answers Cancel for \(action)")
      XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
      XCTAssertNotEqual(alert.buttons.last?.keyEquivalent, "\r", "Return never ends anything")
      XCTAssertNotEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
    }
    // Escape and ⌘. answer Cancel as well, as in every Mac alert; Return and a plain period don't
    // reach the monitor's Cancel (Return is Cancel's own key).
    func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    XCTAssertTrue(UISessionBridge.cancels(key("\u{1b}", 0x35)))
    XCTAssertTrue(UISessionBridge.cancels(key(".", 0x2F, .command)))
    XCTAssertFalse(UISessionBridge.cancels(key(".", 0x2F)))
    XCTAssertFalse(UISessionBridge.cancels(key("\r", 0x24)))
    XCTAssertFalse(UISessionBridge.cancels(key("s", 0x01, .command)))
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
    let enable = UIAction.setSyncCameras(true, sourceID: "camera-2")
    XCTAssertEqual(enable.confirmationTitle(in: presentation), "Sync Cameras from Camera 2?")
    XCTAssertTrue(enable.needsConfirmation(in: presentation)?.hasPrefix("Camera 1 takes Camera 2's effects") == true)
    XCTAssertNil(UIAction.setSyncCameras(false, sourceID: "camera-2").needsConfirmation(in: presentation),
      "Turning it off rewrites nothing")
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
    XCTAssertEqual(UIBackgroundShortcut.cut(2).actions(in: two), [.cut(cameraID: "camera-2")])
    XCTAssertEqual(UIBackgroundShortcut.cut(3).actions(in: two), [], "No third camera, no cut")
    XCTAssertEqual(UIBackgroundShortcut.cut(1).actions(in: two), [], "The camera on air takes no cut")
  }

  /// Swap Pictures puts Camera 2 first: the toolbar calls it 1, and so does ⌃⌥⌘1.
  @MainActor func testBackgroundCutsCountInStripOrderAndOnlyWhereACutIsOffered() {
    var swapped = session([camera(2), camera(1)])
    swapped.onAirID = "camera-1"
    let presentation = UIPresentationBuilder.session(swapped)
    XCTAssertEqual(presentation.cameras.map(\.number), [1, 2])
    XCTAssertEqual(presentation.cameras.map(\.id), ["camera-2", "camera-1"])
    XCTAssertEqual(UIBackgroundShortcut.cut(1).actions(in: presentation), [.cut(cameraID: "camera-2")])
    XCTAssertEqual(UIBackgroundShortcut.cut(2).actions(in: presentation), [], "Camera 1 is on air")
    var stopped = swapped
    stopped.cameras[0].running = false
    XCTAssertEqual(UIBackgroundShortcut.cut(1).actions(in: UIPresentationBuilder.session(stopped)), [],
      "A camera the Program menu can't cut to gets no cut from the background either")
  }

  // MARK: Menu bar

  @MainActor func testWaitingMenuPreviewFindsAnAvailableCameraBeyondTheFirstPair() throws {
    var state = session([camera(1), camera(2), camera(3)])
    for index in state.cameras.indices {
      state.cameras[index].automaticStart = true
      state.cameras[index].running = false
    }
    state.cameras[0].previewEnabled = false
    state.cameras[1].captureManuallyStopped = true
    func previewRow() throws -> NSMenuItem {
      let items = UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(state), session: state,
        target: nil, previewItem: nil)
      return try XCTUnwrap(items.first { $0.title == "Show Live Preview" })
    }
    XCTAssertEqual(state.menuPreviewCandidate?.id, "camera-3")
    XCTAssertTrue(try previewRow().isEnabled)
    state.cameras[2].running = true
    XCTAssertEqual(state.menuPreviewCandidate?.id, "camera-3", "Starting capture must keep demand on this preview")
    state.cameras[2].running = false
    state.cameras[2].deviceAvailable = false
    XCTAssertNil(state.menuPreviewCandidate)
    XCTAssertFalse(try previewRow().isEnabled)
    state.cameras[0].captureManuallyStopped = true
    let stopped = UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(state), session: state,
      target: nil, previewItem: nil)
    XCTAssertFalse(stopped.contains { $0.title == "Show Live Preview" })
  }

  @MainActor func testMenuBarHasNoSelectionRowsAndALUTRowPerCamera() {
    var state = session([camera(1, recording: .recording), camera(2, recording: .recording)])
    state.programInUse = true
    state.programSinkConnected = true
    let items = UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(state), session: state,
      target: nil, previewItem: nil)
    let titles = items.map(\.title)
    XCTAssertFalse(titles.contains("Processing"))
    let onAir = items.first { $0.title == "Cut to Camera 1" }
    XCTAssertEqual(onAir?.isEnabled, false)
    XCTAssertEqual(onAir?.state, .on)
    XCTAssertTrue(titles.contains("Cut to Camera 2"))
    XCTAssertTrue(titles.contains("Hold Current Shot"))
    XCTAssertTrue(titles.contains("Set Up Stream…"))
    XCTAssertTrue(titles.contains("Pause All"))
    let stop = items.firstIndex { $0.title == "Stop All Capture" }
    XCTAssertEqual(stop.map { items[$0 - 1].isSeparatorItem }, true, "A separator keeps a slip off a camera row off Stop")
    let rows = items.filter { !$0.isSeparatorItem }
    XCTAssertLessThanOrEqual(rows.count, 17, titles.joined(separator: " | "))
    for name in ["Camera 1", "Camera 2"] {
      XCTAssertTrue(items.first { $0.title == name }?.submenu?.items.contains { $0.title == "LUT" } == true)
    }
  }

  @MainActor func testMenuRefreshKeepsRowsInPlaceAsCamerasAndProblemsChange() throws {
    var state = session([camera(1), camera(2)])
    state.cameras[0].automaticStart = true
    state.cameras[0].running = false
    state.cameras[1].running = false
    func items() -> [NSMenuItem] {
      UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(state), session: state,
        target: nil, previewItem: nil, includesPreviewCommand: true)
    }
    let existing = items()
    let attention = try XCTUnwrap(existing.first { $0.title == "Attention…" })
    let preview = try XCTUnwrap(existing.first { $0.title == "Show Live Preview" })
    let firstCut = try XCTUnwrap(existing.first { $0.title == "Cut to Camera 1" })
    let secondCut = try XCTUnwrap(existing.first { $0.title == "Cut to Camera 2" })
    let pause = try XCTUnwrap(existing.first { $0.title == "Pause All" })
    XCTAssertFalse(attention.isEnabled)
    XCTAssertTrue(preview.isEnabled)
    XCTAssertFalse(pause.isEnabled)

    state.cameras[0].running = true
    state.cameras[1].running = true
    state.cameras[1].recording.status = .recording
    state.cameras[1].signal = .noSignal
    state.onAirID = "camera-2"
    state.programInUse = true
    state.interruptedTakes = [UIInterruptedTake(id: "interrupted", title: "Interrupted take")]
    XCTAssertTrue(UIMenuBarController.refresh(existing, with: items()))
    XCTAssertTrue(attention.isEnabled)
    // The lost signal on air. The interrupted take isn't a problem, so it isn't counted.
    XCTAssertEqual(attention.badge?.stringValue, "1")
    XCTAssertEqual(UIMenuBarController.commands(for: attention), [.action(.showProblems), .action(.openMainWindow)])
    XCTAssertFalse(preview.isEnabled)
    XCTAssertTrue(firstCut.isEnabled)
    XCTAssertEqual(firstCut.state, .off)
    XCTAssertFalse(secondCut.isEnabled)
    XCTAssertEqual(secondCut.state, .on)
    XCTAssertTrue(pause.isEnabled)

    state.cameras[1].signal = .live(format: "2160p 59.94")
    state.interruptedTakes.removeAll()
    XCTAssertTrue(UIMenuBarController.refresh(existing, with: items()))
    XCTAssertFalse(attention.isEnabled)
    XCTAssertNil(attention.badge)
  }

  @MainActor func testMenuRefreshReplacesUnnamedSymbolsAndTheirTint() throws {
    let old = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
    let fresh = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
    old.image = try XCTUnwrap(NSImage(systemSymbolName: "video", accessibilityDescription: nil))
    fresh.image = try XCTUnwrap(NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil))
    XCTAssertTrue(UIMenuBarController.refresh([old], with: [fresh]))
    XCTAssertTrue(old.image === fresh.image, "Unnamed symbols must follow a live state change")
    fresh.image = try XCTUnwrap(fresh.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange])))
    XCTAssertTrue(UIMenuBarController.refresh([old], with: [fresh]))
    XCTAssertTrue(old.image === fresh.image, "A warning tint must update even with the same symbol")
    fresh.image = nil
    XCTAssertTrue(UIMenuBarController.refresh([old], with: [fresh]))
    XCTAssertNil(old.image)
  }

  // MARK: Detail size

  /// At startup the split view reports zero or a sliver before its real size; cells fitted to
  /// that were about 1 pt wide and scaled up, a flash of garble before the window settled.
  @MainActor func testSettledSizeIgnoresDegenerateSizes() {
    let settled = UISettledSize()
    settled.changed(to: .zero)
    settled.changed(to: CGSize(width: 50, height: 700))
    settled.changed(to: CGSize(width: 1200, height: 40))
    XCTAssertNil(settled.value, "A degenerate size is never the first size")
    settled.changed(to: CGSize(width: 1200, height: 800))
    XCTAssertEqual(settled.value, CGSize(width: 1200, height: 800), "The first real size applies at once")
    settled.changed(to: .zero)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(settled.value, CGSize(width: 1200, height: 800), "A later degenerate size changes nothing")
  }
}
