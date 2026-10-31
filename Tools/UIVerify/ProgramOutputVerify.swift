import AppKit
import SwiftUI

/// The switching menus and states: the menu bar item's Strategy submenu, refreshing its
/// open rows in place, and renders of the sidebar, toolbar and menu card in states the
/// shared fixtures don't cover.
@MainActor enum ProgramOutputVerify {
  static func run(verifier: Verifier, render: (String, AnyView, CGSize, Bool) -> Void) {
    rules(verifier)
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

  // MARK: Menu bar item

  static func items(_ session: UISessionSnapshot) -> [NSMenuItem] {
    UIMenuBarController.buildItems(presentation: UIPresentationBuilder.session(session), session: session,
      inputs: UIFixtures.inputs, stats: "CPU 31% · GPU 18%", target: nil, previewItem: nil, showLivePreview: false)
  }

  static func menuBar(_ verifier: Verifier) {
    verifier.check("menu bar: no Output submenu", !items(programManual()).contains { $0.title == "Output" })

    // Program: Strategy submenu beside a disabled Automatic Switching.
    let manual = items(programManual())
    let strategy = manual.first { $0.title == "Strategy" }
    verifier.check("menu bar Program: Strategy submenu with Manual checked",
      strategy?.submenu?.items.map(\.title) == ["Manual", "Fixed interval", "Natural talking head"]
        && strategy?.submenu?.items.first?.state == .on, strategy?.submenu?.items.map(\.title).joined(separator: " | ") ?? "none")
    verifier.check("menu bar Program: Automatic Switching disabled under Manual",
      manual.first { $0.title == "Automatic Switching" }?.isEnabled == false)
    verifier.check("menu bar one camera: no Strategy submenu", !items(oneCamera()).contains { $0.title == "Strategy" })

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
    for (name, session) in [("output-idle", idleTwoCameras()), ("output-program-manual", programManual()),
      ("output-stopped-program", stoppedProgram()), ("output-one-camera", oneCamera()), ("output-recording", UIFixtures.standalone())] {
      render("component-sidebar-\(name)", AnyView(UISessionSidebarView(context: .fixture(session))), sidebar, false)
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
