import SwiftUI

/// Main window toolbar: Program cuts and Auto, then cameras and the record control
/// (always with a verb), layout and collapse, and the inspector toggle.
struct UIToolbarContent: ToolbarContent {
  let context: UIContext

  private var presentation: UISessionPresentation { context.presentation }

  var body: some ToolbarContent {
    if presentation.outputMode == .program && !presentation.cutButtons.isEmpty {
      ToolbarItem(placement: .principal) {
        UIToolbarCutGroup(context: context)
      }
    }

    // Grouped by function: transport (cameras, record), view (layout, collapse), then the
    // inspector toggle on its own at the trailing edge, each group on its own glass. Order
    // matters: when the window narrows, macOS moves the trailing items into the overflow menu
    // first, so the cameras and the record control stay visible; layout, collapse and the
    // inspector are also in View.
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        context.send(presentation.camerasRunning ? .stopAllCameras : .startAllCameras)
      } label: {
        Label(presentation.camerasControlTitle, systemImage: presentation.camerasRunning ? "stop.fill" : "play.fill")
          .labelStyle(.titleAndIcon)
      }
      .disabled(!presentation.canStartAny)
      .help(camerasHelp)

      UIToolbarRecordControl(context: context)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItemGroup(placement: .primaryAction) {
      if context.session.expandedFrom != nil {
        Button {
          context.send(.restoreLayout)
        } label: {
          Label("Restore Layout", systemImage: "arrow.down.right.and.arrow.up.left")
            .labelStyle(.titleAndIcon)
        }
        .help("Return to the layout you expanded this picture from")
      }

      // One camera has only the single layout, so the picker appears with a second camera.
      if presentation.layouts.count > 1 {
        Picker("Layout", selection: layoutBinding) {
          ForEach(presentation.layouts, id: \.self) { layout in
            Label(layout.title, systemImage: layout.symbol).tag(layout)
          }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Layout (⌥⌘1–⌥⌘4)")
      }

      Button {
        context.send(.setAllCollapsed(!allCollapsed))
      } label: {
        Label(allCollapsed ? "Expand All Strips" : "Collapse All Strips",
          systemImage: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
      }
      .help(allCollapsed ? "Expand All Strips (⌥⌘S)" : "Collapse All Strips (⌥⌘S)")
      .disabled(presentation.layout == .fourUp || presentation.layout == .programView)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      Button {
        context.send(.toggleInspector)
      } label: {
        Label("Inspector", systemImage: "sidebar.trailing")
      }
      .help("Show or hide the inspector for the selected camera (⌥⌘I)")
    }
  }

  private var camerasHelp: String {
    if presentation.camerasRunning {
      return "Stop capture and output for every camera (⌘↩). Asks first if a recording or on-air camera is affected."
    }
    if !presentation.canStartAny { return "No camera can start: connect its UltraStudio or choose another input in the inspector." }
    return presentation.cameras.count == 1 ? "Start the camera (⌘↩)." : "Start every camera (⌘↩)."
  }

  private var allCollapsed: Bool {
    let ids = Set(presentation.cameras.map(\.id))
    return !ids.isEmpty && ids.isSubset(of: context.session.collapsed)
  }

  private var layoutBinding: Binding<UILayout> {
    Binding(get: { presentation.layout }, set: { context.send(.setLayout($0)) })
  }
}

/// Program cut buttons (red = on air, green outline = cut pending) and the Auto switch.
struct UIToolbarCutGroup: View {
  let context: UIContext

  var body: some View {
    HStack(spacing: 6) {
      ForEach(context.presentation.cutButtons) { button in
        cutButton(button)
      }
      Divider().frame(height: 18)
      if context.presentation.canAutoSwitch {
        Toggle(isOn: Binding(get: { context.presentation.autoSwitching }, set: { context.send(.setAutoSwitching($0)) })) {
          Label("Auto", systemImage: "wand.and.sparkles")
        }
        .toggleStyle(.button)
        .help("Automatic switching with \(context.session.strategyTitle) (⌃⌥A)")
      } else {
        // Manual never cuts on its own: Auto asks how to switch, then turns on with that strategy.
        Menu {
          ForEach(UIOutputModeControl.strategies.filter { $0 != .manual }, id: \.self) { strategy in
            Button(UIStrategy.title(strategy)) {
              context.send(.setStrategy(strategy))
              context.send(.setAutoSwitching(true))
            }
          }
        } label: {
          Label("Auto", systemImage: "wand.and.sparkles")
        }
        .help("Switch automatically: choose a strategy and Auto turns on.")
      }
    }
  }

  @ViewBuilder private func cutButton(_ button: UICutButton) -> some View {
    let title = UICutButtonLabel(button: button)
    if button.onAir {
      Button { context.send(.cut(cameraID: button.id)) } label: { title }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .help("\(button.name) is on air")
        .accessibilityLabel("\(button.name), on air")
    } else {
      // A pending cut is outlined in green; the capsule shape keeps the outline on the button's edge.
      Button { context.send(.cut(cameraID: button.id)) } label: { title }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .overlay(Capsule().strokeBorder(button.pending ? Color.green : .clear, lineWidth: 1.5).allowsHitTesting(false))
        .disabled(!button.enabled)
        .help(button.pending ? "Cut to \(button.name) is pending" : "Cut to \(button.name) (⌃\(button.number))")
        .accessibilityLabel(button.pending ? "\(button.name), cut pending" : "Cut to \(button.name)")
    }
  }
}

/// A cut button's number and name, with a tally dot: red on air, green while a cut is pending.
/// The button's red fill alone isn't a tally: macOS draws prominent buttons grey whenever the
/// window isn't key, which is most of a meeting.
struct UICutButtonLabel: View {
  let button: UICutButton
  var showsNext = false

  var body: some View {
    HStack(spacing: 4) {
      if button.onAir || button.pending {
        Circle().fill(button.onAir ? Color.red : .green)
          .overlay(Circle().strokeBorder(.white.opacity(button.onAir ? 0.8 : 0), lineWidth: 1))
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
      }
      Text("\(button.number)").monospacedDigit().fontWeight(.bold)
      Text(button.name)
      if showsNext && button.pending { Text("Next").font(.subheadline).foregroundStyle(.secondary) }
    }
  }
}

/// Record control: "Record All", "Stop All (2) 12:31" or "Stop Recording 12:31".
struct UIToolbarRecordControl: View {
  let context: UIContext

  var body: some View {
    let control = context.presentation.recordControl
    switch control {
    case .record(let all, let enabled):
      Button {
        context.send(all ? .recordAll : .toggleRecordingSelected)
      } label: {
        Label(control.title, systemImage: "record.circle")
          .labelStyle(.titleAndIcon)
      }
      .disabled(!enabled)
      .help(all ? "Record every running camera (⌥⌘R)" : "Record (⌘R)")
    case .stop(let elapsed):
      Button {
        context.send(.toggleRecordingSelected)
      } label: {
        Label { HStack(spacing: 4) { Text("Stop Recording"); Text(elapsed).monospacedDigit() } } icon: { Image(systemName: "stop.fill") }
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .help("Stop Recording (⌘R)")
    case .stopAll(let count, let elapsed):
      Button {
        context.send(.stopAllRecordings)
      } label: {
        Label { HStack(spacing: 4) { Text("Stop All (\(count))"); Text(elapsed).monospacedDigit() } } icon: { Image(systemName: "stop.fill") }
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .help("Stop All Recordings (⌥⌘R)")
      .accessibilityLabel("Stop all \(count) recordings, \(elapsed)")
    }
  }
}
