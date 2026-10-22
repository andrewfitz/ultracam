import AppKit
import MonitorToolsCore
import SwiftUI
import SystemExtensions

// Offscreen verification of the new interface. See README.md.

@MainActor private final class CapturingRegistryPublisher: AppVirtualCameraRegistryPublishing {
  private(set) var snapshots: [VirtualCameraRegistrySnapshot] = []
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) { snapshots.append(snapshot) }
}

/// Camera extension requests that are recorded and never submitted to macOS.
@MainActor private final class RecordingInstallerServices {
  private(set) var submitted: [OSSystemExtensionRequest] = []
  func services() -> ExtensionInstaller.Services {
    ExtensionInstaller.Services(preflight: { ExtensionInstallPreflight(developerSigned: true, hasInstallEntitlement: true) },
      makeRequest: { change in
        switch change {
        case .install: return .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        case .remove: return .deactivationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        }
      }, submit: { self.submitted.append($0) })
  }
}

@MainActor private struct UIVerify {
  let verifier: Verifier

  // MARK: Rendering

  @discardableResult
  func render<V: View>(_ name: String, _ view: V, size: CGSize, titled: Bool = false, both: Bool = true,
    viewDependent: Bool = true) -> [HostedView] {
    var hosts: [HostedView] = []
    for dark in both ? [false, true] : [false] {
      let renderStart = Date()
      defer {
        if ProcessInfo.processInfo.environment["UI_VERIFY_TIMING"] != nil {
          print("TIME \(name)-\(dark ? "dark" : "light") \(Int(Date().timeIntervalSince(renderStart) * 1000)) ms")
        }
      }
      let hosted = HostedView(view, size: size, dark: dark, titled: titled)
      let file = "\(name)-\(dark ? "dark" : "light").png"
      if let rep = hosted.render() {
        Images.write(rep, to: verifier.pngDirectory.appendingPathComponent(file))
        verifier.savedImage()
        let colors = UISelfTest.distinctColors(rep)
        let dominant = Images.dominantFraction(rep)
        verifier.check("render \(file) is not blank", colors > 12 && dominant < 0.97,
          "\(colors) colors, dominant \(String(format: "%.2f", dominant))", viewDependent: viewDependent)
        if titled {
          // The window chrome alone must not pass: the content area has to draw too.
          let center = Images.dominantFraction(rep, region: 0.5)
          verifier.check("render \(file) draws its content area", center < 0.99,
            "center dominant \(String(format: "%.2f", center))", viewDependent: viewDependent)
        }
        verifier.check("render \(file) has the requested size", rep.pixelsWide >= Int(size.width) && rep.pixelsHigh >= Int(size.height),
          "\(rep.pixelsWide)×\(rep.pixelsHigh)")
      } else {
        verifier.check("render \(file)", false, "no bitmap", viewDependent: viewDependent)
      }
      // Close before the next appearance: a second live window of the same split view
      // renders an empty detail column.
      hosted.close()
      hosts.append(hosted)
    }
    return hosts
  }

  func mainWindow(_ context: UIContext) -> some View {
    UIMainWindowView(context: context).toolbar { UIToolbarContent(context: context) }
  }

  // MARK: Fixtures

  func stripFixture(_ state: UIStripState) -> UISessionSnapshot {
    var session = UIFixtures.singleMeeting()
    var camera = UIFixtures.camera(1, recording: .idle, inUse: true)
    switch state {
    case .ready: break
    case .recording:
      camera.recording.status = .recording
      camera.recording.elapsed = 751
    case .paused:
      camera.recording.status = .paused
      camera.recording.elapsed = 252
    case .finishing: camera.recording.status = .finishing
    case .saved:
      camera.recording.savedFileName = "Camera 1_2026-10-21_09-41-03_001.mov"
      camera.recording.savedURL = URL(fileURLWithPath: "/Volumes/8TB/Takes/Camera 1/Camera 1_2026-10-21_09-41-03_001.mov")
      camera.recording.savedDuration = 2292
    case .noFolder: camera.recording.folderPath = nil
    case .failed: camera.recording.error = "The drive was disconnected. Saved up to 00:12:20."
    case .recordingNoSignal:
      camera.recording.status = .recording
      camera.recording.elapsed = 751
      camera.signal = .noSignal
    case .stopped:
      camera.running = false
      camera.signal = .none
      camera.inUse = false
    case .waiting: camera.signal = .noSignal
    case .updating:
      camera.recording.status = .recording
      camera.recording.elapsed = 751
      camera.applying = true
    }
    session.cameras = [camera]
    return session
  }

  // MARK: Screens

  func screens() {
    let fixtures: [(String, UISessionSnapshot)] = [("program-meeting", UIFixtures.programMeeting()),
      ("single-meeting", UIFixtures.singleMeeting()), ("standalone", UIFixtures.standalone()),
      ("four-up", UIFixtures.fourUp()), ("stopped", UIFixtures.stopped()), ("problems", UIFixtures.problems())]
    for (name, session) in fixtures {
      for size in [CGSize(width: 1320, height: 860), CGSize(width: 980, height: 680)] {
        // The smallest window is used without the sidebar. (A fixed-size offscreen window
        // can't grow to fit both columns, so AppKit would loop on the split view's minimums.)
        var session = session
        if size.width < 1000 { session.sidebarVisible = false }
        let hosts = render("main-\(name)-\(Int(size.width))", mainWindow(.fixture(session)), size: size, titled: true)
        hosts.forEach { $0.close() }
      }
    }
    for layout in UILayout.allCases {
      var session = UIFixtures.programMeeting()
      session.layout = layout
      render("layout-\(layout.rawValue)", mainWindow(.fixture(session)), size: CGSize(width: 1320, height: 860), titled: true)
        .forEach { $0.close() }
    }
    var collapsed = UIFixtures.programMeeting()
    collapsed.collapsed = Set(collapsed.cameras.map(\.id))
    render("main-collapsed", mainWindow(.fixture(collapsed)), size: CGSize(width: 1320, height: 860), titled: true).forEach { $0.close() }
    var inspector = UIFixtures.programMeeting()
    inspector.inspectorOpen = true
    // `.inspector` inside a bare NSHostingView (no SwiftUI scene) throws during AppKit layout, so the
    // whole-window inspector render is verified by the in-app self-test instead. RENDER_INSPECTOR=1 tries it here.
    if ProcessInfo.processInfo.environment["RENDER_INSPECTOR"] == "1" {
      render("main-inspector", UIMainWindowView(context: .fixture(inspector)), size: CGSize(width: 1600, height: 900))
        .forEach { $0.close() }
    }

    // Components
    let meeting = UIContext.fixture(UIFixtures.programMeeting())
    if let first = meeting.presentation.cameras.first {
      render("component-camera-column", UICameraColumnView(camera: first, context: meeting), size: CGSize(width: 560, height: 720))
        .forEach { $0.close() }
    }
    for state in [UIStripState.ready, .recording, .paused, .finishing, .saved, .noFolder, .failed, .recordingNoSignal, .stopped,
      .waiting, .updating] {
      var session = stripFixture(state)
      let derived = session.cameras.first.map(UIPresentationBuilder.stripState(for:))
      verifier.check("strip fixture derives \(state.rawValue)", derived == state, "derived \(String(describing: derived))")
      for collapsedStrip in [false, true] {
        session.collapsed = collapsedStrip ? [session.cameras[0].id] : []
        let context = UIContext.fixture(session)
        guard let camera = context.presentation.cameras.first else { continue }
        render("strip-\(state.rawValue)\(collapsedStrip ? "-collapsed" : "")", UIChannelStripView(camera: camera, context: context),
          size: CGSize(width: 560, height: collapsedStrip ? 52 : 230)).forEach { $0.close() }
      }
    }
    render("component-sidebar", UISessionSidebarView(context: meeting), size: CGSize(width: 260, height: 860)).forEach { $0.close() }
    render("component-sidebar-problems", UISessionSidebarView(context: .fixture(UIFixtures.problems())),
      size: CGSize(width: 260, height: 860)).forEach { $0.close() }
    render("component-inspector", UIInspectorView(context: meeting), size: CGSize(width: 320, height: 860)).forEach { $0.close() }
    render("component-status-bar", UIStatusBarView(context: meeting), size: CGSize(width: 1320, height: 40)).forEach { $0.close() }
    render("component-program-view", UIProgramView(context: meeting), size: CGSize(width: 1060, height: 800)).forEach { $0.close() }
    // The menu bar item's preview card, for every fixture (the live preview stays off while waiting).
    for (name, session) in [("program-meeting", UIFixtures.programMeeting()), ("single-meeting", UIFixtures.singleMeeting()),
      ("standalone", UIFixtures.standalone()), ("stopped", UIFixtures.stopped())] {
      let presentation = UIPresentationBuilder.session(session)
      render("menubar-preview-\(name)", UIMenuPreviewContent(presentation: presentation, session: session,
        pictures: UIFixturePictures(), showLive: true).fixedSize(horizontal: false, vertical: true),
        size: CGSize(width: UIMenuPreviewContent.minimumWidth, height: 330)).forEach { $0.close() }
    }
  }

  // MARK: Accessibility and interaction

  func names(_ nodes: [AXNode]) -> [String] { nodes.map(\.text) }

  func contains(_ nodes: [AXNode], _ needle: String) -> Bool {
    nodes.contains { $0.label == needle || $0.title == needle || $0.value == needle || $0.text.contains(needle) }
  }

  func accessibility() {
    let session = UIFixtures.programMeeting()
    let context = UIContext.fixture(session)
    let hosted = HostedView(mainWindow(context), size: CGSize(width: 1320, height: 860), dark: false, titled: true)
    defer { hosted.close() }
    let nodes = Accessibility.nodes(in: hosted.host)
    let dump = nodes.map { "\($0.role)\t\($0.text)\t\($0.enabled ? "" : "disabled")" }.joined(separator: "\n")
    try? dump.write(to: verifier.pngDirectory.deletingLastPathComponent().appendingPathComponent("accessibility-program-meeting.tsv"),
      atomically: true, encoding: .utf8)
    for label in ["Camera 1", "Camera 2", "On Air", "Stop Recording", "Stop Camera 1", "Processing", "LUT", "1080p",
      "Ultracam · Program · In use", "Cut to Camera 2"] {
      verifier.check("accessibility contains \"\(label)\"", contains(nodes, label), "", viewDependent: true)
    }
    verifier.check("no app names in accessibility text", !nodes.contains { node in
      ["Zoom", "Teams", "FaceTime", "Webex"].contains { node.text.contains($0) }
    })

    let stopped = HostedView(mainWindow(.fixture(UIFixtures.stopped())), size: CGSize(width: 1320, height: 860), dark: true, titled: true)
    defer { stopped.close() }
    let stoppedNodes = Accessibility.nodes(in: stopped.host)
    verifier.check("stopped window offers Start Camera", contains(stoppedNodes, "Start Camera") || contains(stoppedNodes, "Start Camera 1"),
      "", viewDependent: true)

    // Problem states offer their one recovery action, and pressing it sends the right action.
    let log = ActionLog()
    let problems = HostedView(mainWindow(.fixture(UIFixtures.problems()) { log.append($0) }), size: CGSize(width: 1320, height: 860),
      dark: false, titled: true)
    defer { problems.close() }
    let problemNodes = Accessibility.nodes(in: problems.host)
    try? problemNodes.map { "\($0.role)\t\($0.text)" }.joined(separator: "\n")
      .write(to: verifier.pngDirectory.deletingLastPathComponent().appendingPathComponent("accessibility-problems.tsv"), atomically: true, encoding: .utf8)
    for label in ["Retry Preview", "Locate…"] {
      verifier.check("problems window offers \"\(label)\"", contains(problemNodes, label), "", viewDependent: true)
    }
    // Sidebar List rows aren't exposed to accessibility offscreen (the render
    // component-sidebar-problems shows the banner), so check the banner's state and its view directly.
    let problemsSession = UIFixtures.problems()
    if case .notInstalled? = UIExtensionBanner.state(problemsSession.install) {
      verifier.check("sidebar shows the Install banner when the camera isn't installed", true)
    } else {
      verifier.check("sidebar shows the Install banner when the camera isn't installed", false,
        "\(String(describing: UIExtensionBanner.state(problemsSession.install)))")
    }
    let sidebar = HostedView(UIExtensionBannerView(state: .notInstalled, context: .fixture(problemsSession) { log.append($0) }),
      size: CGSize(width: 260, height: 160), dark: false)
    defer { sidebar.close() }
    let sidebarNodes = Accessibility.nodes(in: sidebar.host)
    try? sidebarNodes.map { "\($0.role)\t\($0.text)" }.joined(separator: "\n")
      .write(to: verifier.pngDirectory.deletingLastPathComponent().appendingPathComponent("accessibility-sidebar-problems.tsv"), atomically: true, encoding: .utf8)
    verifier.check("problems sidebar offers \"Install Camera\"", contains(sidebarNodes, "Install Camera"), "", viewDependent: true)
    if let install = sidebarNodes.first(where: { $0.text == "Install Camera" && $0.enabled }) {
      log.clear()
      _ = Accessibility.press(install)
      verifier.check("pressing Install Camera sends its action", log.actions.contains(.installCameraExtension), "\(log.actions)",
        viewDependent: true)
    }
    verifier.check("problems window offers Retry for the failed start", problemNodes.contains { $0.text.hasPrefix("Retry") && $0.text != "Retry Preview" },
      "", viewDependent: true)
    for (label, expected) in [("Retry Preview", UIAction.retryPreview)] {
      if let node = problemNodes.first(where: { $0.text == label && $0.enabled }) {
        log.clear()
        _ = Accessibility.press(node)
        verifier.check("pressing \(label) sends its action", log.actions.contains(expected), "\(log.actions)", viewDependent: true)
      }
    }
  }

  func interactions() {
    let log = ActionLog()
    let session = UIFixtures.programMeeting()
    let context = UIContext.fixture(session) { log.append($0) }
    let presentation = context.presentation

    // Picture press selects and never cuts (D1).
    for camera in presentation.cameras {
      let hosted = HostedView(UICameraPictureView(camera: camera, context: context), size: CGSize(width: 520, height: 292), dark: false)
      let nodes = Accessibility.nodes(in: hosted.host)
      let picture = nodes.first { $0.label == camera.accessibilityLabel }
      verifier.check("\(camera.name) picture is an accessibility element", picture != nil,
        names(nodes).prefix(12).joined(separator: "; "), viewDependent: true)
      if let picture {
        log.clear()
        _ = Accessibility.press(picture)
        hosted.settle()
        verifier.check("pressing \(camera.name)'s picture selects it", log.actions.contains(.select(cameraID: camera.id)),
          "\(log.actions)", viewDependent: true)
        verifier.check("pressing \(camera.name)'s picture never cuts", !log.actions.contains { if case .cut = $0 { return true }; return false },
          "\(log.actions)")
      }
      hosted.close()
    }

    // Strip controls.
    func pressInStrip(_ camera: UICameraPresentation, _ label: String, expect: UIAction) {
      let hosted = HostedView(UIChannelStripView(camera: camera, context: context), size: CGSize(width: 560, height: 230), dark: false)
      defer { hosted.close() }
      let nodes = Accessibility.nodes(in: hosted.host)
      guard let node = nodes.first(where: { ($0.label == label || $0.title == label) && !$0.role.contains("Menu") && !$0.role.contains("PopUp") }) else {
        verifier.check("strip of \(camera.name) has \"\(label)\"", false, names(nodes).prefix(20).joined(separator: "; "), viewDependent: true)
        return
      }
      log.clear()
      let pressed = Accessibility.press(node)
      hosted.settle()
      verifier.check("strip \(camera.name) \"\(label)\" sends \(expect)", log.actions.contains(expect),
        "pressed=\(pressed) actions=\(log.actions)", viewDependent: true)
    }
    let one = presentation.cameras[0]
    let two = presentation.cameras[1]
    pressInStrip(one, "Stop Recording", expect: .toggleRecording(cameraID: one.id))
    pressInStrip(one, "Pause", expect: .pauseOrResume(cameraID: one.id))
    pressInStrip(one, "Stop Camera 1", expect: .stopCamera(cameraID: one.id))
    pressInStrip(one, "1080p", expect: .setEffect(cameraID: one.id, index: 1, false))
    pressInStrip(two, "4:2:0", expect: .setEffect(cameraID: two.id, index: 2, false))
    // Camera 2 has no LUT loaded, so its LUT chip is disabled and must not act.
    do {
      let hosted = HostedView(UIChannelStripView(camera: two, context: context), size: CGSize(width: 560, height: 230), dark: false)
      let lut = Accessibility.nodes(in: hosted.host).first { $0.label == "LUT" }
      verifier.check("Camera 2 LUT chip is disabled without a LUT", lut?.enabled == false, "", viewDependent: true)
      if let lut {
        log.clear()
        _ = Accessibility.press(lut)
        hosted.settle()
        verifier.check("disabled LUT chip sends nothing", log.actions.isEmpty, "\(log.actions)")
      }
      hosted.close()
    }
    pressInStrip(two, "Collapse Camera 2", expect: .toggleCollapsed(cameraID: two.id))

    // The ⋯ menu shows ⌃1 beside Cut to Camera 1 as a label only: the Program menu owns the key.
    do {
      func isCut(_ action: UIAction) -> Bool { if case .cut = action { return true }; return false }
      // A shortcut in the window must be caught here, or the check below proves nothing.
      let control = HostedView(Button("Cut") { log.append(.cut(cameraID: one.id)) }.keyboardShortcut("1", modifiers: .control),
        size: CGSize(width: 120, height: 40), dark: false)
      log.clear()
      Keys.performKeyEquivalent("1", keyCode: 18, modifiers: .control, in: control.window)
      control.settle()
      verifier.check("a ⌃1 shortcut in a window is caught", log.actions.contains(where: isCut), "\(log.actions)")
      control.close()
      let hosted = HostedView(UIChannelStripView(camera: one, context: context), size: CGSize(width: 560, height: 230), dark: false)
      log.clear()
      Keys.performKeyEquivalent("1", keyCode: 18, modifiers: .control, in: hosted.window)
      hosted.settle()
      verifier.check("strip ⋯ menu has no ⌃1 handler", !log.actions.contains(where: isCut), "\(log.actions)")
      let items = Menus.items(in: hosted.host, containing: "Cut to \(one.name)")
      let cut = items.first { $0.title == "Cut to \(one.name)" }
      verifier.check("strip ⋯ menu labels Cut to \(one.name) ⌃1 without a shortcut",
        cut?.badge?.stringValue == "⌃1" && cut?.keyEquivalent.isEmpty == true,
        cut.map { "badge \($0.badge?.stringValue ?? "none"), key \($0.keyEquivalent.debugDescription)" } ?? "no item", viewDependent: true)
      verifier.check("strip ⋯ menu registers no shortcuts", !items.isEmpty && items.allSatisfy { $0.keyEquivalent.isEmpty },
        items.filter { !$0.keyEquivalent.isEmpty }.map(\.title).joined(separator: ", "), viewDependent: true)
      hosted.close()
    }

    // Toolbar controls (rendered standalone; the window toolbar hosts the same views).
    func pressIn<V: View>(_ name: String, _ view: V, _ label: String, expect: UIAction) {
      let hosted = HostedView(view, size: CGSize(width: 520, height: 60), dark: false)
      defer { hosted.close() }
      let nodes = Accessibility.nodes(in: hosted.host)
      guard let node = nodes.first(where: { $0.label == label || $0.title == label }) else {
        verifier.check("\(name) has \"\(label)\"", false, names(nodes).prefix(20).joined(separator: "; "), viewDependent: true)
        return
      }
      log.clear()
      _ = Accessibility.press(node)
      hosted.settle()
      verifier.check("\(name) \"\(label)\" sends \(expect)", log.actions.contains(expect), "\(log.actions)", viewDependent: true)
    }
    pressIn("toolbar cut group", UIToolbarCutGroup(context: context), "Cut to Camera 2", expect: .cut(cameraID: two.id))
    pressIn("toolbar record control", UIToolbarRecordControl(context: context), "Stop all 2 recordings, 12:31", expect: .stopAllRecordings)
    let idle = UIContext.fixture(UIFixtures.stopped()) { log.append($0) }
    let idleCamera = idle.presentation.cameras[0]
    let hosted = HostedView(UIChannelStripView(camera: idleCamera, context: idle), size: CGSize(width: 560, height: 230), dark: false)
    let idleNodes = Accessibility.nodes(in: hosted.host)
    if let start = idleNodes.first(where: { $0.label == "Start Camera 1" || $0.title == "Start Camera" }) {
      log.clear()
      _ = Accessibility.press(start)
      hosted.settle()
      verifier.check("stopped strip Start sends startCamera", log.actions.contains(.startCamera(cameraID: idleCamera.id)), "\(log.actions)",
        viewDependent: true)
    } else {
      verifier.check("stopped strip has Start", false, names(idleNodes).prefix(20).joined(separator: "; "), viewDependent: true)
    }
    if let record = idleNodes.first(where: { $0.label == "Record" }) {
      verifier.check("record is disabled when the camera is stopped", !record.enabled, "", viewDependent: true)
    }
    hosted.close()
  }

  // MARK: Real model bridge

  func bridge() throws {
    let suiteName = "org.ultracam.ui-verify.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { verifier.check("defaults suite", false); return }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettingsStore(defaults: defaults)
    let alpha = FeedID(rawValue: "ui-verify-alpha")
    let beta = FeedID(rawValue: "ui-verify-beta")
    settings.saveSnapshot(AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: alpha, name: "Camera 1", selectedDevice: "ui-verify-device-a", applyLUT: false, automaticFeed: false),
      FeedDescriptor(id: beta, name: "Camera 2", selectedDevice: "ui-verify-device-b", applyLUT: false, automaticFeed: false),
    ], selectedFeedID: alpha, outputMode: .separateCameras))
    let installerServices = RecordingInstallerServices()
    let model = AppModel(settingsStore: settings, registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: CapturingRegistryPublisher(), recordingFolderStore: RecordingFolderStore(defaults: defaults),
      installer: ExtensionInstaller(services: installerServices.services()), hardware: .offline)
    let interface = UIInterfaceState(defaults: defaults)
    interface.alertsDisabled = true
    let bridge = UISessionBridge(model: model, interface: interface)

    let snapshot = bridge.snapshot()
    verifier.check("bridge: two cameras with names", snapshot.cameras.map(\.name) == ["Camera 1", "Camera 2"], "\(snapshot.cameras.map(\.name))")
    verifier.check("bridge: selection", snapshot.selectedID == alpha.rawValue)
    verifier.check("bridge: separate mode", snapshot.outputMode == .separate)
    verifier.check("bridge: idle recording", snapshot.cameras.allSatisfy { $0.recording.status == .idle })
    verifier.check("bridge: stopped cameras have no signal", snapshot.cameras.allSatisfy { !$0.running && $0.signal == .none })
    verifier.check("bridge: presentation builds", bridge.presentation().cameras.count == 2)

    bridge.perform(.select(cameraID: beta.rawValue))
    verifier.check("bridge: select", model.selectedFeedID == beta && bridge.snapshot().selectedID == beta.rawValue)
    bridge.perform(.select(cameraID: alpha.rawValue))

    bridge.perform(.setLayout(.single))
    verifier.check("bridge: layout", interface.layout == .single && bridge.snapshot().layout == .single)
    verifier.check("bridge: layout persists", UIInterfaceState(defaults: defaults).layout == .single)
    bridge.perform(.setLayout(.programView))
    verifier.check("bridge: Program View falls back in Separate mode", bridge.snapshot().layout == .sideBySide)
    bridge.perform(.setAllCollapsed(true))
    verifier.check("bridge: collapse all", interface.collapsed == [alpha.rawValue, beta.rawValue])
    bridge.perform(.toggleCollapsed(cameraID: alpha.rawValue))
    verifier.check("bridge: toggle collapsed", interface.collapsed == [beta.rawValue])
    bridge.perform(.setAllCollapsed(false))
    verifier.check("bridge: expand all", interface.collapsed.isEmpty)
    bridge.perform(.toggleSidebar)
    verifier.check("bridge: toggle sidebar", interface.sidebarVisible == false)
    bridge.perform(.toggleInspector)
    verifier.check("bridge: toggle inspector", interface.inspectorOpen)
    // Narrow window: the column opened last stays, the other closes.
    bridge.perform(.setSidebarVisible(true))
    bridge.perform(.makeRoomForPictures)
    verifier.check("bridge: make room keeps the sidebar just opened", interface.sidebarVisible && !interface.inspectorOpen)
    bridge.perform(.setInspectorOpen(true))
    bridge.perform(.makeRoomForPictures)
    verifier.check("bridge: make room keeps the inspector just opened", interface.inspectorOpen && !interface.sidebarVisible)
    bridge.perform(.makeRoomForPictures)
    verifier.check("bridge: make room with one column open changes nothing", interface.inspectorOpen && !interface.sidebarVisible)

    // Per-camera settings on the camera that isn't selected must persist without selecting it.
    let downscaleBefore = model.descriptor(for: beta)?.downscale ?? true
    bridge.perform(.setEffect(cameraID: beta.rawValue, index: 1, !downscaleBefore))
    verifier.check("bridge: effect on non-selected camera keeps selection", model.selectedFeedID == alpha)
    let reloaded = AppSettingsStore(defaults: defaults).loadSnapshot().feeds.first { $0.id == beta }
    verifier.check("bridge: effect on non-selected camera persists", reloaded?.downscale == !downscaleBefore,
      "downscale \(String(describing: reloaded?.downscale))")
    verifier.check("bridge: snapshot reflects the effect", bridge.snapshot().cameras[1].effects[1] == !downscaleBefore)
    bridge.perform(.setProcessing(cameraID: beta.rawValue, false))
    verifier.check("bridge: processing persists", AppSettingsStore(defaults: defaults).loadSnapshot().feeds.first { $0.id == beta }?.pipelineEnabled == false)
    verifier.check("bridge: snapshot reflects processing", bridge.snapshot().cameras[1].processing == false)
    bridge.perform(.setAutomaticStart(cameraID: beta.rawValue, true))
    verifier.check("bridge: automatic start persists", model.descriptor(for: beta)?.automaticFeed == true)
    bridge.perform(.setAutomaticStart(cameraID: beta.rawValue, false))
    bridge.perform(.setEffect(cameraID: alpha.rawValue, index: 2, false))
    verifier.check("bridge: effect on selected camera", model.configuration.convertTo420 == false && bridge.snapshot().cameras[0].effects[2] == false)
    bridge.perform(.setGamut(cameraID: beta.rawValue, "S-Gamut3 / S-Log3"))
    verifier.check("bridge: gamut", model.descriptor(for: beta)?.gamut == "S-Gamut3 / S-Log3")

    // Stopping cameras that aren't running does nothing.
    bridge.perform(.stopCamera(cameraID: beta.rawValue))
    bridge.perform(.stopCamera(cameraID: alpha.rawValue))
    bridge.perform(.stopAllCameras)
    verifier.check("bridge: stop on stopped cameras is a no-op", !model.running && !model.isCameraRunning(beta))
    bridge.send(.stopCamera(cameraID: beta.rawValue))
    verifier.check("bridge: no confirmation for an idle camera", interface.confirmation == nil)

    // A Start that can't start says why, on any camera. The device list is the real
    // one (the selected camera adopts the first real input), so both cameras are
    // pointed at inputs that don't exist first: nothing here may open hardware.
    bridge.perform(.setInput(cameraID: alpha.rawValue, deviceID: "ui-verify-device-a"))
    bridge.perform(.setInput(cameraID: beta.rawValue, deviceID: "ui-verify-device-b"))
    let missingInputs = model.selectedDevice == "ui-verify-device-a" && model.descriptor(for: beta)?.selectedDevice == "ui-verify-device-b"
      && !model.devices.contains { $0.id.hasPrefix("ui-verify-device-") }
    verifier.check("bridge: cameras point at missing inputs", missingInputs, model.selectedDevice)
    if missingInputs {
      bridge.perform(.startCamera(cameraID: beta.rawValue))
      let refused = bridge.snapshot().cameras[1]
      verifier.check("bridge: a refused Start says why", !model.isCameraRunning(beta) && refused.automaticStartFailed
        && refused.automaticStatus?.isEmpty == false && model.selectedFeedID == alpha, refused.automaticStatus ?? "no status")
      bridge.perform(.startCamera(cameraID: alpha.rawValue))
      let refusedSelected = bridge.snapshot().cameras[0]
      verifier.check("bridge: a refused Start on the selected camera says why", !model.running && refusedSelected.automaticStartFailed
        && refusedSelected.automaticStatus?.isEmpty == false, refusedSelected.automaticStatus ?? "no status")
      verifier.check("bridge: a refused Start shows in the status bar",
        UIPresentationBuilder.warning(bridge.snapshot())?.contains("couldn't start") == true, UIPresentationBuilder.warning(bridge.snapshot()) ?? "none")
      bridge.perform(.stopCamera(cameraID: beta.rawValue))
      bridge.perform(.stopCamera(cameraID: alpha.rawValue))
      verifier.check("bridge: Stop clears a refused Start", bridge.snapshot().cameras.allSatisfy { !$0.automaticStartFailed })

      // LUT loads are per camera: one camera's load neither blocks nor cancels another's.
      model.updateCamera(beta) { $0.lutBookmark = Data([1, 2, 3]) }
      bridge.perform(.select(cameraID: beta.rawValue))
      verifier.check("bridge: selecting a camera restores its LUT", model.loading)
      bridge.perform(.startCamera(cameraID: beta.rawValue))
      verifier.check("bridge: Start while the LUT loads says so",
        bridge.snapshot().cameras[1].automaticStatus?.contains("LUT") == true, bridge.snapshot().cameras[1].automaticStatus ?? "no status")
      let missingCube = FileManager.default.temporaryDirectory.appendingPathComponent("ui-verify-missing-\(UUID().uuidString).cube")
      model.loadLUT(url: missingCube, feedID: alpha)
      let lutDeadline = Date().addingTimeInterval(5)
      // Both loads fail (a bogus bookmark, a missing file); wait for both.
      while (model.lutError == nil || !model.canEditFeedTopology) && Date() < lutDeadline { MainLoop.run(seconds: 0.01) }
      verifier.check("bridge: another camera's LUT load doesn't drop the selected camera's restore",
        model.lutError?.contains("Saved LUT could not be restored") == true && model.canEditFeedTopology, model.lutError ?? "no error")
      // A failed restore keeps the bookmark, so selecting the camera again restores it again.
      bridge.perform(.select(cameraID: alpha.rawValue))
      bridge.perform(.select(cameraID: beta.rawValue))
      bridge.perform(.select(cameraID: alpha.rawValue))
      verifier.check("bridge: a camera without a LUT isn't blocked by another camera's load",
        !model.loading && !bridge.snapshot().cameras[0].lutLoading)
      // Forgetting the LUT also drops its restore still in flight.
      bridge.perform(.forgetLUT(cameraID: beta.rawValue))
      bridge.perform(.stopCamera(cameraID: beta.rawValue))
    }

    // Topology while idle.
    bridge.perform(.setOutputMode(.program))
    verifier.check("bridge: output mode while idle", model.outputMode == .program && bridge.snapshot().outputMode == .program)
    bridge.perform(.setLayout(.programView))
    verifier.check("bridge: Program View in Program mode", bridge.snapshot().layout == .programView)
    bridge.perform(.setOutputMode(.separate))
    bridge.perform(.addCamera)
    verifier.check("bridge: add camera", model.feedDescriptors.count == 3)
    if let added = model.feedDescriptors.last?.id {
      bridge.perform(.renameCamera(cameraID: added.rawValue, name: "Wide"))
      verifier.check("bridge: rename", model.descriptor(for: added)?.name == "Wide")
      bridge.perform(.removeCamera(cameraID: added.rawValue))
      verifier.check("bridge: remove", model.feedDescriptors.count == 2)
    }
    bridge.perform(.setAutoHold(true))
    verifier.check("bridge: auto hold", model.switcherSettings.naturalTalkingHead.manualHold)
    bridge.perform(.setAutoHold(false))
    // Auto can't switch with the Manual strategy, so it stays off until a strategy is chosen.
    bridge.perform(.setStrategy(.manual))
    bridge.perform(.setAutoSwitching(true))
    verifier.check("bridge: auto stays off with the Manual strategy", !model.switcherSettings.automatic)
    bridge.perform(.setStrategy(.fixedInterval))
    bridge.perform(.setAutoSwitching(true))
    verifier.check("bridge: auto switching", model.switcherSettings.automatic && bridge.snapshot().autoSwitching)
    bridge.perform(.setStrategy(.naturalTalkingHead))
    verifier.check("bridge: strategy", bridge.snapshot().strategyTitle == "Natural talking head")
    bridge.perform(.setAutoSwitching(false))

    // Conformance-review additions: swap, expand/restore, anchor/emphasis, forget LUT,
    // confirmations for remove, default strip density for new cameras.
    bridge.perform(.swapPictures)
    verifier.check("bridge: swap pictures", bridge.snapshot().cameras.map(\.id) == [beta.rawValue, alpha.rawValue])
    bridge.perform(.swapPictures)
    verifier.check("bridge: swap back", bridge.snapshot().cameras.map(\.id) == [alpha.rawValue, beta.rawValue])
    bridge.perform(.setLayout(.sideBySide))
    bridge.perform(.expandPicture(cameraID: beta.rawValue))
    verifier.check("bridge: expand picture", interface.layout == .single && model.selectedFeedID == beta
      && bridge.snapshot().expandedFrom == .sideBySide)
    bridge.perform(.restoreLayout)
    verifier.check("bridge: restore layout", interface.layout == .sideBySide && bridge.snapshot().expandedFrom == nil)
    bridge.perform(.select(cameraID: alpha.rawValue))
    bridge.perform(.setStrategy(.naturalTalkingHead))
    bridge.perform(.setAnchor(cameraID: alpha.rawValue))
    bridge.perform(.setEmphasis(cameraID: beta.rawValue))
    verifier.check("bridge: anchor and emphasis", bridge.snapshot().anchorID == alpha.rawValue && bridge.snapshot().emphasisID == beta.rawValue)
    bridge.perform(.setAnchor(cameraID: nil))
    bridge.perform(.setEmphasis(cameraID: nil))
    verifier.check("bridge: automatic anchor and emphasis", bridge.snapshot().anchorID == nil && bridge.snapshot().emphasisID == nil)
    model.updateCamera(beta) { $0.lutBookmark = Data([1, 2, 3]); $0.applyLUT = true }
    bridge.perform(.forgetLUT(cameraID: beta.rawValue))
    verifier.check("bridge: forget LUT on another camera", model.descriptor(for: beta)?.lutBookmark == nil
      && model.descriptor(for: beta)?.applyLUT == false)
    verifier.check("bridge: forget LUT persists",
      AppSettingsStore(defaults: defaults).loadSnapshot().feeds.first { $0.id == beta }?.lutBookmark == nil)
    bridge.send(.removeCamera(cameraID: beta.rawValue))
    verifier.check("bridge: remove asks first", interface.confirmation != nil && model.feedDescriptors.count == 2)
    interface.confirmation = nil
    defaults.set("collapsed", forKey: "ui.collapsed.default")
    let collapsedInterface = UIInterfaceState(defaults: defaults)
    collapsedInterface.alertsDisabled = true
    UISessionBridge(model: model, interface: collapsedInterface).perform(.addCamera)
    if let added = model.feedDescriptors.last?.id, model.feedDescriptors.count == 3 {
      verifier.check("bridge: new camera starts collapsed when that is the default", collapsedInterface.collapsed.contains(added.rawValue))
      verifier.check("bridge: new cameras are named Camera N", model.descriptor(for: added)?.name == "Camera 3",
        model.descriptor(for: added)?.name ?? "")
      bridge.perform(.removeCamera(cameraID: added.rawValue))
    } else {
      verifier.check("bridge: add camera for default density", false, "\(model.feedDescriptors.count)")
    }
    defaults.removeObject(forKey: "ui.collapsed.default")

    // The sidebar's camera banner follows the installer: two failed removals, then an
    // install, leave no "Requesting … removal…" behind. List rows aren't exposed to
    // accessibility offscreen, so this reads what the sidebar's body reads, and checks
    // that each change notifies Observation, which is what redraws the sidebar.
    do {
      let live = UISessionBridge.live(model: model, interface: interface).context()
      final class Flag: @unchecked Sendable { var raised = false }
      func banner(after step: () -> Void) -> (state: UIExtensionBanner?, observed: Bool) {
        let flag = Flag()
        withObservationTracking { _ = live.current.session.install } onChange: { flag.raised = true }
        step()
        // Delegate callbacks finish on the main actor.
        let deadline = Date().addingTimeInterval(1)
        while !flag.raised && Date() < deadline { MainLoop.run(seconds: 0.01) }
        MainLoop.run(seconds: 0.02)
        return (UIExtensionBanner.state(live.current.session.install), flag.raised)
      }
      func isPending(_ state: UIExtensionBanner?) -> Bool { if case .pending = state { return true }; return false }
      for code in [13, 4] {
        let requested = banner { model.installer.uninstall() }
        var removalText = false
        if case .pending(let text)? = requested.state { removalText = text.contains("Requesting camera extension removal") }
        verifier.check("sidebar shows the removal request", removalText && requested.observed, "\(String(describing: requested.state))")
        let failed = banner {
          if let removal = installerServices.submitted.last {
            model.installer.request(removal, didFailWithError: NSError(domain: OSSystemExtensionErrorDomain, code: code))
          }
        }
        verifier.check("sidebar drops the removal request after error \(code)", !isPending(failed.state) && failed.observed
          && !model.installer.status.contains("Requesting"), "\(String(describing: failed.state)) · \(model.installer.status)")
      }
      _ = banner { model.installer.install() }
      let installed = banner {
        if let activation = installerServices.submitted.last { model.installer.request(activation, didFinishWithResult: .completed) }
      }
      verifier.check("sidebar shows no request after the install completes", !isPending(installed.state) && installed.observed
        && !model.installer.status.contains("removal"), "\(String(describing: installed.state)) · \(model.installer.status)")
      verifier.check("installer requests stay in the verifier", installerServices.submitted.count == 3, "\(installerServices.submitted.count)")
    }

    // Settings and Diagnostics with the real model.
    render("settings-general", UISettingsGeneralPane(model: model), size: CGSize(width: 640, height: 720)).forEach { $0.close() }
    render("settings-recording", UISettingsRecordingPane(model: model), size: CGSize(width: 640, height: 720)).forEach { $0.close() }
    render("settings-camera", UISettingsCameraPane(model: model), size: CGSize(width: 640, height: 720)).forEach { $0.close() }
    render("settings-switcher", UISettingsSwitcherPane(model: model), size: CGSize(width: 640, height: 720)).forEach { $0.close() }
    render("settings-monitor", UISettingsMonitorPane(), size: CGSize(width: 640, height: 720)).forEach { $0.close() }
    render("settings-advanced", UISettingsAdvancedPane(model: model), size: CGSize(width: 640, height: 720)).forEach { $0.close() }
    render("settings-window", UISettingsView(model: model), size: CGSize(width: 640, height: 720)).forEach { $0.close() }
    render("diagnostics", UIDiagnosticsView(model: model), size: CGSize(width: 1100, height: 760)).forEach { $0.close() }
    interface.inspectorOpen = false
    interface.sidebarVisible = true
    let live = UISessionBridge.live(model: model, interface: interface).context()
    render("main-live-model", mainWindow(live), size: CGSize(width: 1320, height: 860), titled: true).forEach { $0.close() }
  }

  // MARK: Menu bar

  func menuItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
    items.flatMap { item in [item] + menuItems(item.submenu?.items ?? []) }
  }

  func menuBar() {
    let fixtures: [(String, UISessionSnapshot)] = [("program-meeting", UIFixtures.programMeeting()),
      ("single-meeting", UIFixtures.singleMeeting()), ("standalone", UIFixtures.standalone()),
      ("four-up", UIFixtures.fourUp()), ("stopped", UIFixtures.stopped()), ("problems", UIFixtures.problems())]
    for (name, session) in fixtures {
      let presentation = UIPresentationBuilder.session(session)
      let topLevel = UIMenuBarController.buildItems(presentation: presentation, session: session, inputs: UIFixtures.inputs,
        stats: "CPU 31% · GPU 18%", target: nil, previewItem: nil, showLivePreview: false)
      let topLevelIDs = Set(topLevel.map(ObjectIdentifier.init))
      let items = menuItems(topLevel)
      let titles = items.filter { !$0.isSeparatorItem }.map(\.title)
      try? titles.joined(separator: "\n").write(to: verifier.pngDirectory.deletingLastPathComponent()
        .appendingPathComponent("menubar-\(name).txt"), atomically: true, encoding: .utf8)
      verifier.check("menu bar \(name): has rows", items.count > 5, "\(items.count)")
      if name == "problems" {
        verifier.check("menu bar problems: Retry Camera Start row", titles.contains { $0.hasPrefix("Retry Camera Start") }, titles.joined(separator: " | "))
        verifier.check("menu bar problems: warning banner", titles.contains { $0.contains("couldn't start") || $0.contains("LUT unavailable") }, titles.joined(separator: " | "))
      }
      for required in ["Settings…", "Quit Ultracam"] {
        verifier.check("menu bar \(name): \(required)", titles.contains { $0.hasPrefix(required) }, titles.joined(separator: " | "))
      }
      verifier.check("menu bar \(name): opens the window", titles.contains { $0.hasPrefix("Open Ultracam") || $0.hasPrefix("Show Ultracam") },
        titles.joined(separator: " | "))
      // Cuts only come from explicit "Cut to …" rows (D1).
      for item in items {
        let cuts = UIMenuBarController.commands(for: item).contains { command in
          if case .action(.cut) = command { return true }
          if case .action(.cutNumber) = command { return true }
          return false
        }
        if cuts {
          verifier.check("menu bar \(name): cut lives on a Cut row (\(item.title))", item.title.hasPrefix("Cut to"))
          // The top-level cut rows carry ⌃n; the copy inside each camera's submenu has
          // no shortcut, so every key equivalent stays unique.
          if topLevelIDs.contains(ObjectIdentifier(item)) {
            verifier.check("menu bar \(name): cut row has ⌃n", item.keyEquivalentModifierMask.contains(.control) && !item.keyEquivalent.isEmpty,
              "\(item.title) key=\(item.keyEquivalent)")
          }
        }
      }
      if session.outputMode == .separate {
        verifier.check("menu bar \(name): no cut rows in Separate mode", !titles.contains { $0.hasPrefix("Cut to") })
      } else {
        verifier.check("menu bar \(name): cut row for the off-air camera", titles.contains("Cut to Camera 2"), titles.joined(separator: " | "))
      }
      let shortcuts = items.filter { !$0.keyEquivalent.isEmpty }.map {
        UISelfTest.shortcut(key: $0.keyEquivalent, modifiers: $0.keyEquivalentModifierMask)
      }
      let duplicates = Dictionary(grouping: shortcuts, by: { $0 }).filter { $0.value.count > 1 }.keys
      verifier.check("menu bar \(name): no duplicate shortcuts", duplicates.isEmpty, duplicates.sorted().joined(separator: ", "))
      verifier.check("menu bar \(name): no consumer app names", !titles.contains { $0.contains("Zoom") || $0.contains("Teams") })
    }
    let icons: [UIMenuBarIcon] = [.stopped, .waiting, .live, .bypass, .recording, .attention]
    for icon in icons {
      let image = UIMenuBarController.image(for: icon)
      verifier.check("menu bar icon \(icon.rawValue) renders", image != nil)
      verifier.check("menu bar icon \(icon.rawValue) is a template", image?.isTemplate == true)
      // The menu bar is 24 pt tall; the badged icons must still fit it with room to spare.
      verifier.check("menu bar icon \(icon.rawValue) fits the menu bar", (image?.size.height ?? 99) <= 22,
        "\(image?.size ?? .zero)")
    }
    // Every state side by side on a menu bar's light and dark backgrounds, at 2× and magnified 4× more, to look at.
    let cell = NSSize(width: 40, height: 24), magnify: CGFloat = 8
    let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(icons.count) * magnify, height: cell.height * 2 * magnify), flipped: false) { _ in
      for (row, dark) in [(0, true), (1, false)] {
        NSColor(white: dark ? 0.16 : 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: CGFloat(row) * cell.height * magnify, width: cell.width * CGFloat(icons.count) * magnify, height: cell.height * magnify).fill()
        for (index, icon) in icons.enumerated() {
          guard let image = UIMenuBarController.image(for: icon) else { continue }
          let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            (dark ? NSColor.white : NSColor.black).set()
            rect.fill(using: .sourceIn)
            return true
          }
          let size = NSSize(width: image.size.width * magnify, height: image.size.height * magnify)
          tinted.draw(in: NSRect(x: (CGFloat(index) * cell.width * magnify) + (cell.width * magnify - size.width) / 2,
            y: CGFloat(row) * cell.height * magnify + (cell.height * magnify - size.height) / 2, width: size.width, height: size.height))
        }
      }
      return true
    }
    if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
      Images.write(rep, to: verifier.pngDirectory.appendingPathComponent("menubar-icons.png"))
      verifier.savedImage()
    }
  }
}

// MARK: Entry

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : NSTemporaryDirectory() + "ultracam-ui-verify"
let strict = ProcessInfo.processInfo.environment["STRICT"] != "0"

let exitCode: Int32 = MainActor.assumeIsolated {
  NSApplication.shared.setActivationPolicy(.accessory)
  NSApplication.shared.finishLaunching()
  // SwiftUI builds its accessibility tree only when an assistive client is active.
  // Enhanced user interface mode is what such a client sets; no permission is needed.
  NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
  let verifier = Verifier(output: URL(fileURLWithPath: outputPath, isDirectory: true), strict: strict)
  let run = UIVerify(verifier: verifier)
  let started = Date()
  run.screens()
  run.accessibility()
  run.interactions()
  do { try run.bridge() } catch { verifier.check("bridge tests threw", false, "\(error)") }
  run.menuBar()
  Images.waitForWrites()
  print("""

  UI verify \(strict ? "(strict)" : "(tolerant)"): \(verifier.passed) passed, \(verifier.failed) failed, \(verifier.pending) pending, \
  \(verifier.images) images in \(String(format: "%.0f", Date().timeIntervalSince(started))) s
  Images: \(verifier.pngDirectory.path)
  """)
  for failure in verifier.failures { print("  FAIL \(failure)") }
  return verifier.failed == 0 ? 0 : 1
}
exit(exitCode)
