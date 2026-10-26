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

  var body: some Commands {
    let bridge = self.bridge
    let session = bridge.snapshot()
    let presentation = UIPresentationBuilder.session(session)
    let selected = presentation.selected
    let selectedSnapshot = session.cameras.first { $0.id == session.selectedID }
    let send: @MainActor (UIAction) -> Void = { bridge.send($0) }

    CommandGroup(after: .appSettings) {
      Toggle("Hide from Dock", isOn: Binding(get: { model.hideFromDock }, set: { model.hideFromDock = $0 }))
    }

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
          Toggle("Processing", isOn: Binding(get: { selected.processing },
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
          .disabled(!session.canEditTopology)
          .help(session.canEditTopology ? "Rename this camera." : "Stop all cameras and recordings to rename.")
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
        .disabled(!session.canEditTopology)
        .help(session.canEditTopology ? "Add a camera." : "Stop all cameras and recordings to add a camera.")
      if let selected {
        // The bridge asks for confirmation before removing.
        Button("Remove \(selected.name)…") { send(.removeCamera(cameraID: selected.id)) }
          .disabled(!session.canEditTopology || !several)
          .help(!session.canEditTopology ? "Stop all cameras and recordings to remove a camera."
            : !several ? "Ultracam needs at least one camera." : "Remove this camera and its settings.")
      }
    }

    CommandMenu("Record") {
      Button(recordTitle(selectedSnapshot)) { send(.toggleRecordingSelected) }
        .keyboardShortcut("r")
        .disabled(!(selected?.recordButtonEnabled ?? false))
      switch presentation.recordControl {
      case .record(_, let enabled):
        Button("Record All") { send(.recordAll) }
          .keyboardShortcut("r", modifiers: [.command, .option])
          .disabled(!enabled)
      case .stop, .stopAll:
        Button("Stop All Recordings") { send(.stopAllRecordings) }
          .keyboardShortcut("r", modifiers: [.command, .option])
      }
      if let selected, selected.pauseTitle != nil {
        Button("\(selected.pauseTitle == "Resume" ? "Resume" : "Pause") Recording \(selected.name)") {
          send(.pauseOrResume(cameraID: selected.id))
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
      // Pause All turns into Resume All once every take is paused.
      let takes = session.cameras.filter { $0.recording.status == .recording || $0.recording.status == .paused }
      if !takes.isEmpty && takes.allSatisfy({ $0.recording.status == .paused }) {
        Button("Resume All") { send(.resumeAll) }
      } else {
        Button("Pause All") { send(.pauseAll) }
          .disabled(takes.isEmpty)
      }
      Divider()
      Button("Choose Default Folder…") { send(.chooseRecordingFolder(cameraID: nil)) }
      Button("Show Recordings in Finder") { send(.revealRecordings) }
        .disabled(!presentation.canRevealRecordings)
        .help(presentation.canRevealRecordings ? "Open the recording folder in Finder." : "Choose a recording folder first.")
      Button("Recover Interrupted Takes…") {
        // Settings › Recording lists every interrupted take with its own Recover button.
        send(.openSettings)
        NotificationCenter.default.post(name: Notification.Name("UIShowRecovery"), object: nil)
      }
      .disabled(session.interruptedTakes.isEmpty)
    }

    CommandMenu("Program") {
      // The output mode as two checked items, not a Picker: a Picker's submenu title stays
      // enabled while it's locked, so choosing Program there did nothing and said nothing.
      let availability = UIOutputModeControl.availability(session)
      Section("Output") {
        ForEach([UIOutputMode.separate, .program], id: \.self) { mode in
          Toggle(mode == .program ? "Program" : "Separate Cameras (ISO)",
            isOn: Binding(get: { session.outputMode == mode }, set: { if $0 { send(.setOutputMode(mode)) } }))
            .disabled(availability != .available)
        }
        switch availability {
        case .available:
          EmptyView()
        case .stopCamerasFirst:
          let other: UIOutputMode = session.outputMode == .program ? .separate : .program
          Button("Stop Cameras and Switch to \(UIOutputModeControl.title(other))") {
            UIOutputModeSwitch.shared.stopCamerasAndSwitch(to: other, send: send, session: { bridge.snapshot() })
          }
        case .blocked(let reason):
          Text(reason)
        }
      }
      Divider()
      // The camera on Program is checked; cuts need Program and a running camera with a picture.
      ForEach(Array(presentation.cameras.prefix(4))) { camera in
        let onAir = session.outputMode == .program && session.onAirID == camera.id
        Toggle("Cut to \(camera.name)", isOn: Binding(get: { onAir }, set: { _ in send(.cut(cameraID: camera.id)) }))
          .keyboardShortcut(KeyEquivalent(Character("\(camera.number)")), modifiers: .control)
          .disabled(!camera.cutEnabled)
      }
      Divider()
      // Auto only acts with a strategy that switches on its own; Hold only reaches the natural talking head.
      Toggle("Automatic Switching", isOn: Binding(get: { presentation.autoSwitching }, set: { send(.setAutoSwitching($0)) }))
        .keyboardShortcut("a", modifiers: [.control, .option])
        .disabled(!presentation.canAutoSwitch)
        .help(presentation.canAutoSwitch || session.outputMode != .program ? "Cut automatically using the chosen strategy."
          : "Choose a switching strategy in Program › Strategy first.")
      Toggle("Hold Current Shot", isOn: Binding(get: { session.autoHold }, set: { send(.setAutoHold($0)) }))
        .disabled(!presentation.canHoldShot)
      // A Picker's own submenu title doesn't grey out when disabled; a Menu's does.
      Menu("Strategy") {
        Picker("Strategy", selection: Binding(get: { session.strategy }, set: { send(.setStrategy($0)) })) {
          ForEach(UIOutputModeControl.strategies, id: \.self) { strategy in
            Text(UIStrategy.title(strategy)).tag(strategy)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .disabled(session.outputMode != .program)
      if session.outputMode == .program && session.strategy == .naturalTalkingHead {
        Menu("Anchor") {
          Picker("Anchor", selection: Binding(get: { session.anchorID }, set: { send(.setAnchor(cameraID: $0)) })) {
            Text("Automatic").tag(String?.none)
            ForEach(presentation.cameras) { camera in Text(camera.name).tag(String?.some(camera.id)) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
        Menu("Emphasis") {
          Picker("Emphasis", selection: Binding(get: { session.emphasisID }, set: { send(.setEmphasis(cameraID: $0)) })) {
            Text("Automatic").tag(String?.none)
            ForEach(presentation.cameras) { camera in Text(camera.name).tag(String?.some(camera.id)) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
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
        Menu("Monitor Tools") {
          ForEach(UIMonitorTool.allCases, id: \.self) { tool in
            let toggle = Toggle(tool.title, isOn: Binding(get: { selected.activeTools.contains(tool) },
              set: { _ in send(.toggleTool(cameraID: selected.id, tool)) }))
            if tool == .scopes { toggle.keyboardShortcut("k", modifiers: [.command, .option]) } else { toggle }
          }
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
