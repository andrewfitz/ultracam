import AppKit
import SwiftUI

/// The app's menu bar menus. State comes from the same presentation as the
/// window, and every item acts through `UISessionBridge.send`, so menus,
/// toolbar and strips stay consistent. Each key equivalent is used once.
struct UICommands: Commands {
  let model: AppModel
  let interface: UIInterfaceState
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  private var bridge: UISessionBridge {
    UISessionBridge.live(model: model, interface: interface, openWindow: { openWindow(id: $0) },
      openSettings: { openSettings() })
  }

  /// Hands SwiftUI's scene actions to AppKit (`UIAppEnvironment`).
  private func registerSceneActions() {
    let openWindow = openWindow, openSettings = openSettings
    UIAppEnvironment.openWindow = { openWindow(id: $0) }
    UIAppEnvironment.openSettings = { openSettings() }
  }

  var body: some Commands {
    let bridge = self.bridge
    let session = bridge.snapshot()
    let presentation = UIPresentationBuilder.session(session)
    let selected = presentation.selected
    let selectedSnapshot = session.cameras.first { $0.id == session.selectedID }
    let send: @MainActor (UIAction) -> Void = { bridge.send($0) }
    // The menus exist from launch, with or without a window: the menu bar item and a Dock
    // click open windows through these.
    let _ = registerSceneActions()

    // Menu Bar Only When Closed is in Settings › General. Quit asks first while a take rolls
    // or a camera is on air (AppDelegate), wherever it comes from.
    CommandGroup(replacing: .appTermination) {
      Button("Quit Ultracam") {
        model.saveSettings()
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }

    CommandGroup(replacing: .newItem) {
      Button(selected.map { "Load LUT for \($0.name)…" } ?? "Load LUT…") {
        if let selected { send(.chooseLUT(cameraID: selected.id)) }
      }
      .keyboardShortcut("o")
      .disabled(selected == nil)
    }

    CommandMenu("Camera") {
      let several = presentation.cameras.count > 1
      if let selected {
        Section(selected.name) {
          // With one camera, the Start/Stop item below already does this.
          if several {
            if selected.canStop {
              Button("Stop \(selected.name)") { send(.stopCamera(cameraID: selected.id)) }
            } else {
              Button("Start \(selected.name)") { send(.startCamera(cameraID: selected.id)) }
                .disabled(!selected.canStart)
            }
          }
          Toggle("Effects", isOn: Binding(get: { selected.processing },
            set: { send(.setProcessing(cameraID: selected.id, $0)) }))
            .keyboardShortcut("b", modifiers: [.command, .shift])
          Toggle("Video Preview", isOn: Binding(get: { selectedSnapshot?.previewEnabled ?? true },
            set: { send(.setPreviewEnabled(cameraID: selected.id, $0)) }))
            .keyboardShortcut("p", modifiers: [.command, .shift])
          // The rename prompt lives in the main window, so bring it forward first.
          Button("Rename \(selected.name)…") {
            send(.openMainWindow)
            send(.beginRename(cameraID: selected.id))
          }
          .help("Rename this camera.")
        }
      }
      Divider()
      Button(presentation.camerasControlTitle) {
        send(presentation.camerasRunning ? .stopAllCameras : .startAllCameras)
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!presentation.canStartAny)
      if several {
        Divider()
        Section("Select Camera") {
          ForEach(Array(presentation.cameras.prefix(4))) { camera in
            Toggle(camera.name, isOn: Binding(get: { camera.selected }, set: { _ in send(.select(cameraID: camera.id)) }))
              .keyboardShortcut(KeyEquivalent(Character("\(camera.number)")), modifiers: .command)
          }
        }
      }
      Divider()
      Button("Add Camera") { send(.addCamera) }
        .disabled(!session.canAddCamera)
        .help(UIPresentationBuilder.addCameraHelp(session))
      if let selected {
        // The bridge asks for confirmation before removing.
        Button("Remove \(selected.name)…") { send(.removeCamera(cameraID: selected.id)) }
          .disabled(!selected.canRemove)
          .help(selected.removeHelp)
      }
    }

    CommandMenu("Record") {
      Button(recordTitle(selectedSnapshot)) { send(.toggleRecordingSelected) }
        .keyboardShortcut("r")
        .disabled(!(selected?.recordButtonEnabled ?? false))
      switch presentation.recordControl {
      case .record(_, let enabled, _, _):
        Button(presentation.recordControl.title) { send(.recordAll) }
          .keyboardShortcut("r", modifiers: [.command, .option])
          .disabled(!enabled)
      case .stop, .stopAll:
        Button(presentation.recordControl.title) { send(.stopAllRecordings) }
          .keyboardShortcut("r", modifiers: [.command, .option])
      }
      if let selected, selected.pauseTitle != nil {
        Button("\(selected.pauseTitle == "Resume" ? "Resume" : "Pause") Recording \(selected.name)") {
          send(.pauseOrResume(cameraID: selected.id))
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
      // Pause All turns into Resume All once every take is paused, on the same key.
      Button(presentation.pauseAllTitle) { send(presentation.pauseAllTitle == "Resume All" ? .resumeAll : .pauseAll) }
        .keyboardShortcut("p", modifiers: [.command, .option])
        .disabled(!presentation.canPauseAll)
      Menu {
        UIFormatChoices(session: session, send: send)
      } label: {
        Text("Format")
      }
      .badge(Text(session.codec.title))
      Divider()
      Button("Choose Default Folder…") { send(.chooseRecordingFolder(cameraID: nil)) }
      Button("Show Recordings in Finder") { send(.revealRecordings) }
        .disabled(!presentation.canRevealRecordings)
        .help(presentation.canRevealRecordings ? "Open the recording folder in Finder." : "Choose a recording folder first.")
      Button("Recover Interrupted Takes…") {
        send(.openMainWindow)
        send(.showInterruptedTakes)
      }
      .disabled(session.interruptedTakes.isEmpty)
    }

    CommandMenu("Program") {
      // The camera on Program is checked; cuts need a running camera with a picture.
      ForEach(Array(presentation.cameras.prefix(4))) { camera in
        let onAir = session.onAirID == camera.id
        Toggle("Cut to \(camera.name)", isOn: Binding(get: { onAir }, set: { _ in send(.cut(cameraID: camera.id)) }))
          .keyboardShortcut(KeyEquivalent(Character("\(camera.number)")), modifiers: .control)
          .disabled(!camera.cutEnabled)
      }
      Divider()
      // Auto only acts with a strategy that switches on its own; Hold needs Auto on.
      Toggle("Automatic Switching", isOn: Binding(get: { presentation.autoSwitching }, set: { send(.setAutoSwitching($0)) }))
        .keyboardShortcut("a", modifiers: [.control, .option])
        .disabled(!presentation.canAutoSwitch)
        .help(presentation.canAutoSwitch || !presentation.programAvailable ? "Cut automatically using the chosen strategy."
          : "Choose a switching strategy in Program › Strategy first.")
      Toggle("Hold Current Shot", isOn: Binding(get: { presentation.canHoldShot && session.autoHold }, set: { send(.setAutoHold($0)) }))
        .keyboardShortcut("h", modifiers: [.control, .option])
        .disabled(!presentation.canHoldShot)
      // A Picker's own submenu title doesn't grey out when disabled; a Menu's does.
      Menu("Strategy") {
        Picker("Strategy", selection: Binding(get: { session.strategy }, set: { send(.setStrategy($0)) })) {
          ForEach(UIStrategy.offered, id: \.self) { strategy in
            Text(UIStrategy.title(strategy)).tag(strategy)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .disabled(!presentation.programAvailable)
      if presentation.programAvailable && session.strategy == .naturalTalkingHead {
        UICameraPickerMenu(title: "Anchor", selection: session.anchorID, cameras: presentation.cameras) { send(.setAnchor(cameraID: $0)) }
        UICameraPickerMenu(title: "Emphasis", selection: session.emphasisID, cameras: presentation.cameras) {
          send(.setEmphasis(cameraID: $0))
        }
      }
    }

    CommandGroup(after: .toolbar) {
      Section("Layout") {
        ForEach(Array(UILayout.allCases.enumerated()), id: \.element) { index, layout in
          Toggle(layout.title, isOn: Binding(get: { presentation.layout == layout }, set: { _ in send(.setLayout(layout)) }))
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            .disabled(!presentation.layouts.contains(layout))
        }
      }
      Button(session.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { send(.toggleSidebar) }
        .keyboardShortcut("s", modifiers: [.command, .control])
      Button(allCollapsed(session) ? "Expand All Strips" : "Collapse All Strips") {
        send(.setAllCollapsed(!allCollapsed(session)))
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      // Four Up and Program View always show collapsed strips.
      .disabled(presentation.layout == .fourUp || presentation.layout == .programView)
      Button(session.inspectorOpen ? "Hide Inspector" : "Show Inspector") { send(.toggleInspector) }
        .keyboardShortcut("i", modifiers: [.command, .option])
      Divider()
      Button("Swap Pictures") { send(.swapPictures) }
        .disabled(presentation.cameras.count < 2 || presentation.layout == .single || presentation.layout == .programView)
      if session.expandedFrom != nil {
        Button("Restore Layout") { send(.restoreLayout) }
      } else {
        Button(selected.map { "Expand \($0.name)" } ?? "Expand Picture") {
          if let selected { send(.expandPicture(cameraID: selected.id)) }
        }
        .disabled(selected == nil || presentation.cameras.count < 2 || presentation.layout == .single)
      }
      if let selected {
        Button("Detach to Window") { send(.detachMonitor(cameraID: selected.id)) }
      }
      Divider()
      if let selected {
        // The picture only offers these tools while it shows video.
        let showsPicture = selected.tileState.showsPicture
        Toggle("Freeze \(selected.name)", isOn: Binding(get: { UIMonitorBridge.presenter(for: selected.id)?.isFrozen == true },
          set: { _ in send(.freeze(cameraID: selected.id)) }))
          .keyboardShortcut("f", modifiers: [.control, .option])
          .disabled(!showsPicture)
        Toggle("Clean View", isOn: Binding(get: { UICleanViewState.shared.clean.contains(selected.id) },
          set: { _ in send(.toggleClean(cameraID: selected.id)) }))
          .keyboardShortcut("c", modifiers: [.control, .option])
          .disabled(!showsPicture)
        // Every tool, also with no picture yet: the choice is kept and applies when video arrives.
        // Every tool has a key, and each key has this item, the VoiceOver path.
        Menu("Monitor Tools") {
          ForEach(UIMonitorTool.menuOrder, id: \.self) { tool in
            Toggle(tool.title, isOn: Binding(get: { selected.activeTools.contains(tool) },
              set: { _ in send(.toggleTool(cameraID: selected.id, tool)) }))
              .keyboardShortcut(tool.key, modifiers: [.command, .option])
          }
          Toggle("Clip Indicators", isOn: Binding(get: { selectedSnapshot?.clipIndicators == true },
            set: { _ in send(.toggleClipIndicators(cameraID: selected.id)) }))
            .keyboardShortcut("x", modifiers: [.command, .option])
          Divider()
          Button("Hide All") { send(.hideAllTools(cameraID: selected.id)) }
            .disabled(selected.activeTools.isEmpty && selectedSnapshot?.clipIndicators != true)
          Button("Reset Monitor Tools") { send(.resetMonitorTools(cameraID: selected.id)) }
        }
      }
      Divider()
    }

    // SwiftUI lists the Ultracam and Diagnostics windows in the Window menu itself;
    // ⌘0 is attached to the main Window scene in UltracamApp.

    // macOS lists every open window below; this one item brings back the main window with ⌘0.
    CommandGroup(before: .windowList) {
      Button("Show Main Window") {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
      .keyboardShortcut("0", modifiers: .command)
      Button("Diagnostics") { send(.openDiagnostics) }
        .keyboardShortcut("d", modifiers: [.control, .option])
      Divider()
    }

    CommandGroup(replacing: .help) {
      Button("Ultracam Help") { openWindow(id: "help") }
        .keyboardShortcut("?", modifiers: .command)
    }
  }

  private func recordTitle(_ camera: UICameraSnapshot?) -> String {
    guard let camera else { return "Record" }
    switch camera.recording.status {
    case .recording, .paused: return "Stop Recording \(camera.name)"
    default: return "Record \(camera.name)"
    }
  }

  private func allCollapsed(_ session: UISessionSnapshot) -> Bool {
    let ids = Set(session.cameras.map(\.id))
    return !ids.isEmpty && ids.isSubset(of: session.collapsed)
  }
}
