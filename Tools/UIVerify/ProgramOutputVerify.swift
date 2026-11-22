import AppKit
import SwiftUI

/// The switching menus and states: the menu bar item's Strategy submenu, refreshing its
/// open rows in place, and renders of the status bar, toolbar and menu card in states the
/// shared fixtures don't cover.
@MainActor enum ProgramOutputVerify {
  static func run(verifier: Verifier, render: (String, AnyView, CGSize, Bool) -> Void) {
    rules(verifier)
    streaming(verifier, render: render)
    menuBar(verifier)
    views(verifier, render: render)
    extensionBanner(verifier, render: render)
  }

  // MARK: Camera extension banner

  /// After an update macOS has the new version enabled but hasn't started it, so no
  /// Ultracam cameras exist yet: that's a restart, not a missing install.
  static func extensionBanner(_ verifier: Verifier, render: (String, AnyView, CGSize, Bool) -> Void) {
    func record(_ version: String, enabled: Bool = true, approval: Bool = false, uninstalling: Bool = false) -> ExtensionSystemRecord {
      ExtensionSystemRecord(bundleVersion: version, enabled: enabled, awaitingApproval: approval, uninstalling: uninstalling)
    }
    func install(_ records: [ExtensionSystemRecord]?, installed: Bool, bundled: String = "8") -> UIInstallState {
      var state = UIInstallState(canRequestChanges: true, pending: false, status: "", unavailableReason: nil, installed: installed)
      state.system = records.map { ExtensionSystemState(records: $0, bundledVersion: bundled) }
      return state
    }
    let updated = [record("7", uninstalling: true), record("8")]
    verifier.check("extension banner: enabled, no cameras yet → restart, no Install",
      UIExtensionBanner.state(install(updated, installed: false)) == .needsRestart)
    verifier.check("extension banner: enabled with cameras → none", UIExtensionBanner.state(install(updated, installed: true)) == nil)
    verifier.check("extension banner: older enabled version → Update",
      UIExtensionBanner.state(install([record("7")], installed: true)) == .outdated(installed: "7", bundled: "8"))
    verifier.check("extension banner: older and not started → Update first",
      UIExtensionBanner.state(install([record("7")], installed: false)) == .outdated(installed: "7", bundled: "8"))
    verifier.check("extension banner: only a version on its way out → Install",
      UIExtensionBanner.state(install([record("7", uninstalling: true)], installed: false)) == .notInstalled)
    verifier.check("extension banner: macOS unknown and no cameras → Install",
      UIExtensionBanner.state(install(nil, installed: false)) == .notInstalled)
    verifier.check("extension banner: awaiting approval → approve",
      UIExtensionBanner.state(install([record("8", enabled: false, approval: true)], installed: false))
        == .needsApproval(UIExtensionBanner.approvalText))

    for (name, state) in [("restart", install(updated, installed: false)), ("update", install([record("7")], installed: true))] {
      var session = UIFixtures.standalone()
      session.install = state
      // Its row leads the status bar while nothing is wrong, and heads the bar's list.
      let context = UIContext.fixture(session)
      render("component-status-bar-extension-\(name)", AnyView(UIStatusBarView(context: context)), CGSize(width: 1320, height: 40), false)
      if let segment = context.presentation.statusSegments.first(where: { $0.kind == .warning }) {
        render("popover-status-extension-\(name)", AnyView(UIStatusPopover(kind: .warning, segment: segment, context: context)
          .fixedSize(horizontal: false, vertical: true)), CGSize(width: 380, height: 300), false)
      }
    }
  }

  // MARK: Fixtures

  /// Two running cameras, nothing recording, no meeting app.
  static func idleTwoCameras() -> UISessionSnapshot {
    var session = UIFixtures.standalone()
    for index in session.cameras.indices { session.cameras[index].recording.status = .idle }
    return session
  }

  /// One camera: no Program, nothing to switch.
  static func oneCamera() -> UISessionSnapshot {
    var session = idleTwoCameras()
    session.cameras.removeLast()
    return session
  }

  /// Camera 1 on air in a meeting, nothing recording, Manual strategy.
  static func programManual() -> UISessionSnapshot {
    var session = UIFixtures.programMeeting()
    for index in session.cameras.indices { session.cameras[index].recording.status = .idle }
    session.autoSwitching = false
    session.strategy = .manual
    session.strategyTitle = "Manual"
    return session
  }

  /// Natural talking head on Auto, cameras stopped.
  static func stoppedProgram() -> UISessionSnapshot {
    var session = UIFixtures.programMeeting()
    for index in session.cameras.indices {
      session.cameras[index].running = false
      session.cameras[index].signal = .none
      session.cameras[index].recording.status = .idle
    }
    session.programInUse = false
    session.strategy = .naturalTalkingHead
    session.autoSwitching = true
    return session
  }

  // MARK: Rules

  static func rules(_ verifier: Verifier) {
    verifier.check("strategies: no Dynamic analysis offered", !UIStrategy.offered.contains(.dynamicAnalysis))
    verifier.check("switching: two cameras have Program", UIPresentationBuilder.session(idleTwoCameras()).programAvailable)
    verifier.check("switching: cut buttons with two cameras in every layout", UILayout.allCases.allSatisfy {
      var session = idleTwoCameras()
      session.layout = $0
      return UIPresentationBuilder.session(session).cutButtons.count == 2
    })
    let one = UIPresentationBuilder.session(oneCamera())
    verifier.check("switching: one camera has no Program, cut or Program View",
      !one.programAvailable && one.cutButtons.isEmpty && !one.layouts.contains(.programView))
  }

  static func streaming(_ verifier: Verifier, render: (String, AnyView, CGSize, Bool) -> Void) {
    var session = idleTwoCameras()
    verifier.check("stream: first use opens setup", session.streamCommand.action == .openSettingsTab(.streaming))
    let setup = items(session).first { $0.title == "Set Up Stream…" }
    verifier.check("stream: menu bar offers first-use setup", setup.map {
      $0.isEnabled && UIMenuBarController.commands(for: $0).contains(.action(.openSettingsTab(.streaming)))
    } == true)
    session.stream.configured = true
    session.stream.name = "Studio feed"
    session.stream.format.size = .uhd4K
    session.stream.format.rate = .fps60
    session.stream.format.codec = .hevcMain10
    session.stream.format.colorSpaceID = "rec2020-pq-video"
    session.stream.format.videoMbps = 25
    session.stream.audioFeedID = "camera-2"
    let configured = session
    verifier.check("stream: configured Program can start", session.streamCommand.action == .startProgramStream && session.streamCommandEnabled)
    let start = items(session).first { $0.title == "Start Stream" }
    verifier.check("stream: menu bar can start a configured stream", start.map {
      $0.isEnabled && UIMenuBarController.commands(for: $0).contains(.action(.startProgramStream))
    } == true)
    session.cameras[1].running = false
    session.cameras[1].automaticStart = false
    verifier.check("stream: manual audio input offers capture", session.streamCommand.action == .startCamera(cameraID: "camera-2"))
    session.cameras[1].automaticStart = true
    verifier.check("stream: available automatic audio input can start with the stream", session.streamCommand.action == .startProgramStream)
    session.cameras[1].captureManuallyStopped = true
    verifier.check("stream: manually stopped automatic audio input offers capture",
      session.streamCommand.action == .startCamera(cameraID: "camera-2"))
    session.cameras[1].streamCaptureInputAvailable = false
    verifier.check("stream: a fixed audio input held by another camera offers setup",
      session.streamCommand.action == .openSettingsTab(.streaming))
    session.cameras[1].streamCaptureInputAvailable = nil
    session.cameras[1].deviceAvailable = false
    verifier.check("stream: disconnected fixed audio input offers setup", session.streamCommand.action == .openSettingsTab(.streaming))
    session.stream.audioFeedID = nil
    session.cameras[0].running = false
    session.cameras[0].automaticStart = true
    session.cameras[0].captureManuallyStopped = true
    verifier.check("stream: manually stopped automatic picture input offers capture",
      session.streamCommand.action == .startCamera(cameraID: "camera-1"))
    session.cameras[0].deviceAvailable = false
    verifier.check("stream: no available capture device opens Hardware settings", session.streamCommand.action == .openSettingsTab(.hardware))
    session = configured
    for phase in [ProgramStreamPhase.idle, .connecting, .streaming, .reconnecting, .failed] {
      session.stream.phase = phase
      session.stream.pictureFresh = phase == .streaming
      session.stream.startedAt = Date(timeIntervalSinceNow: -90)
      var actions: [UIAction] = []
      let context = UIContext.fixture(session) { actions.append($0) }
      let segment = context.presentation.statusSegments.first { $0.kind == .program }
      if session.stream.active {
        verifier.check("stream: \(phase) has stop in menu and compact status",
          items(session).contains { $0.title == "Stop Stream" && $0.isEnabled } &&
            segment?.essentialPieces.contains(.strong(phase.streamTitle)) == true)
      }
      if let segment {
        let popover = UIStatusPopover(kind: .program, segment: segment, context: context)
        let hosted = HostedView(popover, size: CGSize(width: 380, height: 680), dark: false)
        let nodes = Accessibility.nodes(in: hosted.host)
        verifier.check("stream: \(phase) popover shows selected video format and encoder target",
          [session.stream.format.pictureDescription, session.stream.format.encoderDescription].allSatisfy { value in
            nodes.contains { $0.text.contains(value) }
          }, "", viewDependent: true)
        let control = nodes.first {
          $0.role == "AXButton" && $0.name == session.streamCommand.title
        }
        if let control { _ = Accessibility.press(control) }
        hosted.settle()
        verifier.check("stream: \(phase) popover performs its accessible action",
          actions.contains(session.streamCommand.action), session.streamCommand.title, viewDependent: true)
        hosted.close()
        render("popover-program-stream-\(phase.rawValue)",
          AnyView(UIStatusPopover(kind: .program, segment: segment, context: context)
            .fixedSize(horizontal: false, vertical: true)), CGSize(width: 380, height: 680), false)
      }
    }
    session.stream.needsSetup = true
    verifier.check("stream: rejected credentials reopen setup",
      UIPresentationBuilder.problems(session).first { $0.id == "stream.failed" }?.action?.action == .openSettingsTab(.streaming))
    session.stream.needsSetup = false
    session.stream.pictureFeedID = session.onAirID
    session.stream.phase = .streaming
    session.stream.pictureFresh = true
    session.stream.audioMissing = true
    let live = UIPresentationBuilder.session(session)
    verifier.check("stream: actual delivery independently lights Program",
      live.programTally == .onAir && !session.programInUse)
    verifier.check("stream: fixed off-air audio is protected on stop",
      UIAction.stopCamera(cameraID: "camera-2").needsConfirmation(in: live)?.contains("silences the stream audio") == true)
    verifier.check("stream: missing audio reaches session problems", live.problems.contains { $0.id == "stream.audio" })
    let previous = session.onAirID
    session.onAirID = "camera-2"
    let cut = UIPresentationBuilder.session(session)
    verifier.check("stream: Program stays on air and its source tally follows delivery across a cut",
      cut.programTally == .onAir && cut.cameras.first { $0.id == previous }?.tally == .onAir &&
        cut.cameras.first { $0.id == session.onAirID }?.tally == .program)
    verifier.check("stream: Program status shows the camera still delivered before the cut",
      cut.statusSegments.first { $0.kind == .program }?.text.contains("Camera 1 on air") == true)
    session.stream.pictureFeedID = session.onAirID
    verifier.check("stream: delivered cut moves tally", UIPresentationBuilder.programTally(session) == .onAir)
    session.onAirID = previous
    session.stream.pictureFresh = false
    verifier.check("stream: black filler clears on-air tally", UIPresentationBuilder.programTally(session) == .noPicture)
    session.cameras.removeLast()
    verifier.check("stream: Stop remains available with one camera",
      !session.programAvailable && items(session).contains { $0.title == "Stop Stream" && $0.isEnabled } &&
      UIPresentationBuilder.session(session).statusSegments.contains { $0.kind == .program })
    session.stream.phase = .failed
    verifier.check("stream: a failure remains visible with one camera",
      UIPresentationBuilder.session(session).statusSegments.contains {
        $0.kind == .program && $0.essentialPieces.contains(.strong("Stream Failed"))
      })
    session.stream.phase = .idle
    session.stream.audioFeedID = nil
    verifier.check("stream: one camera cannot start a new stream", !session.streamCommandEnabled)
  }

  // MARK: Menu bar item

  static func items(_ session: UISessionSnapshot) -> [NSMenuItem] {
    UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(session), session: session,
      target: nil, previewItem: nil, showLivePreview: false)
  }

  static func menuBar(_ verifier: Verifier) {
    verifier.check("menu bar: no Output submenu", !items(programManual()).contains { $0.title == "Output" })

    // Program: Automatic Switching is off under Manual; Strategy lives in the window's Auto menu and the
    // Program menu, so the panel stays within its rows.
    let manual = items(programManual())
    verifier.check("menu bar Program: no Strategy row", !manual.contains { $0.title == "Strategy" })
    verifier.check("menu bar Program: Automatic Switching disabled under Manual",
      manual.first { $0.title == "Automatic Switching" }?.isEnabled == false)

    // An open menu follows an automatic cut by updating its existing Cut rows.
    let meeting = UIFixtures.programMeeting()
    let open = items(meeting)
    var cut = meeting
    cut.onAirID = "camera-2"
    let refreshed = UIMenuBarController.refresh(open, with: items(cut))
    let cutRows = open.filter { $0.title.hasPrefix("Cut to") }
    verifier.check("menu bar refresh: an automatic cut updates the open rows in place",
      refreshed && cutRows.map(\.title) == ["Cut to Camera 1", "Cut to Camera 2"] &&
        cutRows.first?.isEnabled == true && cutRows.last?.state == .on && cutRows.last?.isEnabled == false,
      "refreshed \(refreshed), \(cutRows.map(\.title))")
    let nested = open.first { $0.title == "Camera 2" }?.submenu?.items.first { $0.title.hasPrefix("Cut to") }
    verifier.check("menu bar refresh: camera submenus follow too", nested?.state == .on && nested?.isEnabled == false)
    // A stopped take disables its Pause row. Removing a configured camera changes the row structure.
    var stopped = meeting
    stopped.cameras[1].recording.status = .idle
    verifier.check("menu bar refresh: a stopped take keeps its Pause row",
      UIMenuBarController.refresh(open, with: items(stopped)) &&
        open.first { $0.title == "Camera 2" }?.submenu?.items.first { $0.title == "Pause Recording" }?.isEnabled == false)
    stopped.cameras.removeLast()
    let before = open.map(\.title)
    verifier.check("menu bar refresh: a changed shape is refused untouched",
      !UIMenuBarController.refresh(open, with: items(stopped)) && open.map(\.title) == before)
  }

  // MARK: Views

  static func views(_ verifier: Verifier, render: (String, AnyView, CGSize, Bool) -> Void) {
    // The status bar says what's in use; its Virtual Cameras popover lists every published device.
    for (name, session) in [("output-idle", idleTwoCameras()), ("output-program-manual", programManual()),
      ("output-stopped-program", stoppedProgram()), ("output-one-camera", oneCamera()), ("output-recording", UIFixtures.standalone())] {
      let context = UIContext.fixture(session)
      render("component-status-bar-\(name)", AnyView(UIStatusBarView(context: context)), CGSize(width: 1320, height: 40), false)
      let segment = context.presentation.statusSegments.first { $0.kind == .output }
        ?? UIStatusSegment(kind: .output, text: "", tone: .neutral)
      render("popover-status-\(name)", AnyView(UIStatusPopover(kind: .output, segment: segment, context: context)
        .fixedSize(horizontal: false, vertical: true)), CGSize(width: 380, height: 190), false)
    }
    for (name, session) in [("output-idle", idleTwoCameras()), ("output-program-manual", programManual())] {
      let context = UIContext.fixture(session)
      render("main-\(name)", AnyView(UIMainWindowView(context: context).toolbar { UIToolbarContent(context: context) }),
        CGSize(width: 1320, height: 860), true)
    }
    let presentation = UIPresentationBuilder.session(programManual())
    render("menubar-preview-program-manual", AnyView(UIMenuPreviewContent(presentation: presentation, session: programManual(),
      pictures: UIFixturePictures(), showLive: true).fixedSize(horizontal: false, vertical: true)),
      CGSize(width: UIMenuPreviewContent.minimumWidth, height: 330), false)
  }
}
