import AppKit
import SwiftUI

/// The output mode control (Separate (ISO) / Program) and the Program-mode menus:
/// when the mode can change and why not, Stop Cameras and Switch, the menu bar item's
/// Output and Strategy submenus, refreshing its open rows in place, and renders of the
/// sidebar, toolbar and menu card in the states the shared fixtures don't cover
/// (every fixture leaves `canEditTopology` true).
@MainActor enum ProgramOutputVerify {
  static func run(verifier: Verifier, render: (String, AnyView, CGSize, Bool) -> Void) {
    rules(verifier)
    pendingSwitch(verifier)
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
      render("component-sidebar-extension-\(name)", AnyView(UISessionSidebarView(context: .fixture(session))),
        CGSize(width: 260, height: 520), false)
    }
  }

  // MARK: Fixtures

  /// Two running cameras, nothing recording, no meeting app: only the running cameras lock the mode.
  static func lockedSeparate() -> UISessionSnapshot {
    var session = UIFixtures.standalone()
    for index in session.cameras.indices { session.cameras[index].recording.status = .idle }
    session.canEditTopology = false
    return session
  }

  /// Program with Camera 1 on air in a meeting, nothing recording, Manual strategy, locked.
  static func lockedProgramManual() -> UISessionSnapshot {
    var session = UIFixtures.programMeeting()
    for index in session.cameras.indices { session.cameras[index].recording.status = .idle }
    session.autoSwitching = false
    session.strategy = .manual
    session.strategyTitle = "Manual"
    session.canEditTopology = false
    return session
  }

  /// Program, Natural talking head on Auto, cameras stopped: the mode can change.
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
    typealias Control = UIOutputModeControl
    verifier.check("output mode: free while nothing runs", Control.availability(stoppedProgram()) == .available)
    verifier.check("output mode: running cameras offer Stop Cameras and Switch",
      Control.availability(lockedSeparate()) == .stopCamerasFirst)
    var recording = UIFixtures.standalone()
    recording.canEditTopology = false
    if case .blocked(let reason) = Control.availability(recording) {
      verifier.check("output mode: recording blocks and says to stop recording", reason.contains("Stop recording"), reason)
    } else {
      verifier.check("output mode: recording blocks", false)
    }
    // On air: stopping would end a meeting's video, so there's no one-click switch.
    if case .blocked(let reason) = Control.availability(lockedProgramManual()) {
      verifier.check("output mode: Program in a meeting blocks", reason.contains("meeting app"), reason)
    } else {
      verifier.check("output mode: Program in a meeting blocks", false)
    }
    var separateInUse = lockedSeparate()
    separateInUse.cameras[0].inUse = true
    verifier.check("output mode: a camera in a meeting blocks",
      Control.availability(separateInUse) != .stopCamerasFirst && Control.availability(separateInUse) != .available)
    var stopping = lockedSeparate()
    for index in stopping.cameras.indices { stopping.cameras[index].running = false }
    verifier.check("output mode: a camera still stopping (or a LUT loading) blocks without a Stop offer",
      { if case .blocked = Control.availability(stopping) { return true }; return false }())
    verifier.check("output mode: help says why it's locked", Control.help(lockedSeparate()).hasPrefix("Stop the cameras"))
    verifier.check("strategies: no Dynamic analysis offered", !Control.strategies.contains(.dynamicAnalysis))
    // The stop never needs a confirmation: nothing recording, nothing on air.
    verifier.check("Stop Cameras and Switch: Stop All asks nothing",
      UIAction.stopAllCameras.needsConfirmation(in: UIPresentationBuilder.session(lockedSeparate())) == nil)
  }

  // MARK: Stop Cameras and Switch

  @MainActor final class FakeModel {
    var session: UISessionSnapshot
    var sent: [UIAction] = []
    var stopWorks = true
    var drainPolls = 3
    init(_ session: UISessionSnapshot) { self.session = session }
    func read() -> UISessionSnapshot {
      // A stopped camera holds the topology for a few polls while it drains.
      if !session.cameras.contains(where: \.running), !session.canEditTopology {
        drainPolls -= 1
        if drainPolls <= 0 { session.canEditTopology = true }
      }
      return session
    }
    func send(_ action: UIAction) {
      sent.append(action)
      switch action {
      case .stopAllCameras where stopWorks:
        for index in session.cameras.indices { session.cameras[index].running = false }
      case .setOutputMode(let mode) where session.canEditTopology: session.outputMode = mode
      default: break
      }
    }
  }

  static func wait(until done: () -> Bool, seconds: TimeInterval = 3) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
  }

  static func pendingSwitch(_ verifier: Verifier) {
    let switcher = UIOutputModeSwitch()
    let fake = FakeModel(lockedSeparate())
    switcher.stopCamerasAndSwitch(to: .program, send: fake.send, session: fake.read,
      timeout: .seconds(2), stillRunningAfter: .milliseconds(300), poll: .milliseconds(20))
    verifier.check("Stop Cameras and Switch: pending while the cameras stop", switcher.pending == .program)
    wait { switcher.pending == nil }
    verifier.check("Stop Cameras and Switch: stops, waits for the drain, then switches",
      fake.sent == [.stopAllCameras, .setOutputMode(.program)] && fake.session.outputMode == .program, "\(fake.sent)")
    verifier.check("Stop Cameras and Switch: done", switcher.pending == nil)

    // The stop didn't happen: give up rather than switch later by surprise.
    let stuck = FakeModel(lockedSeparate())
    stuck.stopWorks = false
    switcher.stopCamerasAndSwitch(to: .program, send: stuck.send, session: stuck.read,
      timeout: .seconds(2), stillRunningAfter: .milliseconds(200), poll: .milliseconds(20))
    wait { switcher.pending == nil }
    stuck.session.canEditTopology = true
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    verifier.check("Stop Cameras and Switch: gives up when a camera keeps running",
      stuck.sent == [.stopAllCameras] && stuck.session.outputMode == .separate, "\(stuck.sent)")

    // Recording (or on air): nothing is stopped.
    var recordingSession = UIFixtures.standalone()
    recordingSession.canEditTopology = false
    let recording = FakeModel(recordingSession)
    switcher.stopCamerasAndSwitch(to: .program, send: recording.send, session: recording.read)
    verifier.check("Stop Cameras and Switch: refuses while recording", recording.sent.isEmpty && switcher.pending == nil,
      "\(recording.sent)")
  }

  // MARK: Menu bar item

  static func items(_ session: UISessionSnapshot) -> [NSMenuItem] {
    UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(session), session: session,
      inputs: UIFixtures.inputs, stats: "CPU 31% · GPU 18%", target: nil, previewItem: nil, showLivePreview: false)
  }

  static func menuBar(_ verifier: Verifier) {
    // Output submenu: every state names the mode; locked states offer Stop or say why.
    let free = items(stoppedProgram())
    guard let output = free.first(where: { $0.title == "Output" }), let rows = output.submenu?.items else {
      return verifier.check("menu bar: Output submenu", false, free.map(\.title).joined(separator: " | "))
    }
    verifier.check("menu bar Output: subtitle is the mode", output.subtitle == "Program", output.subtitle ?? "nil")
    let separate = rows.first { $0.title == "Separate (ISO)" }
    verifier.check("menu bar Output: Separate (ISO) switches when free",
      separate?.isEnabled == true && separate.map(UIMenuBarController.commands(for:)) == [.action(.setOutputMode(.separate))])
    verifier.check("menu bar Output: Program checked", rows.first { $0.title == "Program" }?.state == .on)

    let locked = items(lockedSeparate()).first { $0.title == "Output" }?.submenu?.items ?? []
    let stop = locked.first { $0.title.hasPrefix("Stop Cameras and Switch") }
    verifier.check("menu bar Output: locked by running cameras offers Stop Cameras and Switch to Program",
      stop?.title == "Stop Cameras and Switch to Program" && stop.map(UIMenuBarController.commands(for:)) == [.stopCamerasAndSwitch(.program)],
      locked.map(\.title).joined(separator: " | "))
    verifier.check("menu bar Output: locked modes are disabled", locked.first { $0.title == "Program" }?.isEnabled == false)
    let onAir = items(lockedProgramManual()).first { $0.title == "Output" }?.submenu?.items ?? []
    verifier.check("menu bar Output: on air says why, no Stop offer",
      !onAir.contains { $0.title.hasPrefix("Stop Cameras") } && onAir.contains { $0.title.contains("meeting app") && !$0.isEnabled },
      onAir.map(\.title).joined(separator: " | "))

    // Program: Strategy submenu beside a disabled Automatic Switching.
    let manual = items(lockedProgramManual())
    let strategy = manual.first { $0.title == "Strategy" }
    verifier.check("menu bar Program: Strategy submenu with Manual checked",
      strategy?.submenu?.items.map(\.title) == ["Manual", "Fixed interval", "Natural talking head"]
        && strategy?.submenu?.items.first?.state == .on, strategy?.submenu?.items.map(\.title).joined(separator: " | ") ?? "none")
    verifier.check("menu bar Program: Automatic Switching disabled under Manual",
      manual.first { $0.title == "Automatic Switching" }?.isEnabled == false)
    verifier.check("menu bar Separate: no Strategy submenu", !items(lockedSeparate()).contains { $0.title == "Strategy" })

    // An open menu follows an automatic cut in place: same rows, new checkmark.
    let meeting = UIFixtures.programMeeting()
    let open = items(meeting)
    var cut = meeting
    cut.onAirID = "camera-2"
    let refreshed = UIMenuBarController.refresh(open, with: items(cut))
    let one = open.first { $0.title == "Cut to Camera 1" }
    let two = open.first { $0.title == "Cut to Camera 2" }
    verifier.check("menu bar refresh: an automatic cut updates the open rows in place",
      refreshed && two?.state == .on && two?.isEnabled == false && one?.state == .off && one?.isEnabled == true,
      "refreshed \(refreshed), 1 \(one?.state.rawValue ?? -1)/\(one?.isEnabled ?? false), 2 \(two?.state.rawValue ?? -1)/\(two?.isEnabled ?? false)")
    let nested = open.first { $0.title == "Camera 2" }?.submenu?.items.first { $0.title.hasPrefix("Cut to") }
    verifier.check("menu bar refresh: camera submenus follow too", nested?.state == .on && nested?.isEnabled == false)
    // Rows that come or go (a stopped camera loses its Pause row) need a rebuild instead.
    var stopped = meeting
    stopped.cameras[1].recording.status = .idle
    let before = open.map(\.title)
    verifier.check("menu bar refresh: a changed shape is refused untouched",
      !UIMenuBarController.refresh(open, with: items(stopped)) && open.map(\.title) == before)
  }

  // MARK: Views

  static func views(_ verifier: Verifier, render: (String, AnyView, CGSize, Bool) -> Void) {
    let sidebar = CGSize(width: 260, height: 860)
    for (name, session) in [("output-locked-separate", lockedSeparate()), ("output-locked-program-manual", lockedProgramManual()),
      ("output-stopped-program", stoppedProgram())] {
      render("component-sidebar-\(name)", AnyView(UISessionSidebarView(context: .fixture(session))), sidebar, false)
    }
    var recording = UIFixtures.standalone()
    recording.canEditTopology = false
    render("component-sidebar-output-recording", AnyView(UISessionSidebarView(context: .fixture(recording))), sidebar, false)
    for (name, session) in [("output-locked-separate", lockedSeparate()), ("output-program-manual", lockedProgramManual())] {
      let context = UIContext.fixture(session)
      render("main-\(name)", AnyView(UIMainWindowView(context: context).toolbar { UIToolbarContent(context: context) }),
        CGSize(width: 1320, height: 860), true)
    }
    let presentation = UIPresentationBuilder.session(lockedProgramManual())
    render("menubar-preview-program-manual", AnyView(UIMenuPreviewContent(presentation: presentation, session: lockedProgramManual(),
      pictures: UIFixturePictures(), showLive: true).fixedSize(horizontal: false, vertical: true)),
      CGSize(width: UIMenuPreviewContent.minimumWidth, height: 330), false)

    // Accessibility: the control, its lock and the one-click way out. (A sidebar List hosted
    // offscreen exposes no rows, so the control is read on its own.)
    let size = CGSize(width: 236, height: 140)
    let hosted = HostedView(UIOutputModeControlView(context: .fixture(lockedSeparate())), size: size, dark: false)
    let nodes = Accessibility.nodes(in: hosted.host)
    hosted.close()
    let text = nodes.map(\.text)
    verifier.check("output control locked: Stop Cameras and Switch button",
      nodes.contains { $0.text.contains("Stop Cameras and Switch") && $0.enabled }, text.joined(separator: "; "), viewDependent: true)
    verifier.check("output control locked: says to stop the cameras",
      text.contains { $0.contains("Stop the cameras to change the output") }, text.joined(separator: "; "), viewDependent: true)
    verifier.check("output control: Separate (ISO) and Program segments",
      text.contains { $0.contains("Separate (ISO)") } && text.contains { $0.contains("Program") }, text.joined(separator: "; "),
      viewDependent: true)
    let free = HostedView(UIOutputModeControlView(context: .fixture(stoppedProgram())), size: size, dark: false)
    let freeText = Accessibility.nodes(in: free.host).map(\.text)
    free.close()
    verifier.check("output control free: no Stop offer", !freeText.contains { $0.contains("Stop Cameras") },
      freeText.joined(separator: "; "), viewDependent: true)
  }
}
