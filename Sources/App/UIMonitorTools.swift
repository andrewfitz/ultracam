import MonitorKitCore
import MonitorKitScopes
import MonitorKitUI
import SwiftUI

/// A popover of the monitor tool bar: one of the toggled tools, clip
/// indicators, or the picture's own settings.
enum UIMonitorPanel: Hashable {
  case tool(UIMonitorTool)
  case clipIndicators
  case picture

  var title: String {
    switch self {
    case .tool(let tool): return tool.title
    case .clipIndicators: return "Clip Indicators"
    case .picture: return "Picture"
    }
  }

  var symbol: String {
    switch self {
    case .tool(let tool): return tool.symbol
    case .clipIndicators: return "exclamationmark.triangle"
    case .picture: return "camera.filters"
    }
  }
}

/// Split-button monitor tools for one camera: the icon toggles the tool, the
/// chevron opens that tool's settings. The last button opens the picture's
/// settings. Settings are remembered per camera.
struct UIMonitorToolButtons: View {
  let targetID: String
  let name: String
  let activeTools: [UIMonitorTool]
  /// Program has no source correspondence, so source-only tools are disabled there.
  let isProgram: Bool
  let toggle: @MainActor (UIMonitorTool) -> Void
  let monitor: any UIMonitorSettingsProviding
  @State private var openPanel: UIMonitorPanel?
  /// The popover opened from the collapsed menu's Settings items.
  @State private var menuPanel: UIMonitorPanel?

  /// A camera's tools; toggles go through the interface's actions.
  init(camera: UICameraPresentation, context: UIContext) {
    targetID = camera.id
    name = camera.name
    activeTools = camera.activeTools
    isProgram = camera.id == "program"
    let send = context.send
    let id = camera.id
    toggle = { send(.toggleTool(cameraID: id, $0)) }
    monitor = context.monitor
  }

  /// Any monitor target, for example "program".
  init(targetID: String, name: String, activeTools: [UIMonitorTool], isProgram: Bool,
    toggle: @escaping @MainActor (UIMonitorTool) -> Void, monitor: any UIMonitorSettingsProviding) {
    self.targetID = targetID
    self.name = name
    self.activeTools = activeTools
    self.isProgram = isProgram
    self.toggle = toggle
    self.monitor = monitor
  }

  /// Clip indicators and the picture settings aren't interface tools; they are
  /// read from the camera's preferences, which re-render this bar when they change.
  private var preferences: MonitorFeedPreferences { monitor.preferences(for: targetID) }
  private var clipOn: Bool { UIMonitorBridge.clipIndicatorsOn(preferences) }

  private func toggleClip() {
    monitor.setPreferences(UIMonitorBridge.toggledClipIndicators(in: preferences), for: targetID)
  }

  private var activeTitles: [String] {
    activeTools.map(\.title) + (clipOn ? [UIMonitorPanel.clipIndicators.title] : [])
  }

  var body: some View {
    // A narrow picture (Four Up, a small window) gets one menu button instead of the full bar.
    ViewThatFits(in: .horizontal) {
      bar
      menu
    }
  }

  private var menu: some View {
    Menu {
      ForEach(UIMonitorTool.allCases, id: \.self) { tool in
        Toggle(tool.title, isOn: Binding(get: { activeTools.contains(tool) }, set: { _ in toggle(tool) }))
          .disabled(UIMonitorToolSettingsView.unavailableReason(tool, isProgram: isProgram) != nil)
      }
      Toggle(UIMonitorPanel.clipIndicators.title, isOn: Binding(get: { clipOn }, set: { _ in toggleClip() }))
      Divider()
      // A menu can't hold the settings, so these open the same popover the
      // bar's chevrons do, from this button.
      Menu("Settings") {
        ForEach(Self.panels, id: \.self) { panel in
          Button("\(panel.title)\u{2026}") { menuPanel = panel }
        }
      }
    } label: {
      Image(systemName: activeTitles.isEmpty ? "slider.horizontal.3" : "slider.horizontal.below.square.filled.and.square")
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .frame(width: 28, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .uiPictureControls()
    .help(activeTitles.isEmpty ? "Monitor tools" : "Monitor tools: " + activeTitles.joined(separator: ", "))
    .accessibilityLabel("Monitor tools for \(name)")
    .popover(isPresented: Binding(get: { menuPanel != nil }, set: { if !$0 { menuPanel = nil } }),
      arrowEdge: .bottom) {
      if let menuPanel { settings(menuPanel) }
    }
  }

  /// Every popover of the bar, in its order.
  static let panels: [UIMonitorPanel] = UIMonitorTool.allCases.map { .tool($0) } + [.clipIndicators, .picture]

  private var bar: some View {
    HStack(spacing: 2) {
      ForEach(UIMonitorTool.allCases, id: \.self) { tool in
        UIMonitorToolSplitButton(panel: .tool(tool), isOn: activeTools.contains(tool),
          unavailableReason: UIMonitorToolSettingsView.unavailableReason(tool, isProgram: isProgram),
          toggle: { toggle(tool) },
          openSettings: { openPanel = .tool(tool) })
          .popover(isPresented: presented(.tool(tool)), arrowEdge: .bottom) { settings(.tool(tool)) }
      }
      UIMonitorToolSplitButton(panel: .clipIndicators, isOn: clipOn, unavailableReason: nil,
        toggle: toggleClip, openSettings: { openPanel = .clipIndicators })
        .popover(isPresented: presented(.clipIndicators), arrowEdge: .bottom) { settings(.clipIndicators) }
      UIMonitorPictureButton(isAdjusted: UIPictureSettingsForm.isAdjusted(preferences.state)) { openPanel = .picture }
        .popover(isPresented: presented(.picture), arrowEdge: .bottom) { settings(.picture) }
    }
    .uiPictureControls()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Monitor tools for \(name)")
  }

  private func presented(_ panel: UIMonitorPanel) -> Binding<Bool> {
    Binding(get: { openPanel == panel }, set: { if !$0 { openPanel = nil } })
  }

  private func settings(_ panel: UIMonitorPanel) -> some View {
    UIMonitorToolSettingsView(panel: panel, cameraID: targetID, cameraName: name, isProgram: isProgram, provider: monitor)
  }
}

private struct UIMonitorToolSplitButton: View {
  let panel: UIMonitorPanel
  let isOn: Bool
  let unavailableReason: String?
  let toggle: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: toggle) {
        Image(systemName: panel.symbol)
          .font(.callout.weight(.medium))
          .frame(width: 24, height: 24)
          .foregroundStyle(.white)
          .background(isOn ? Color.white.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(unavailableReason != nil)
      .help(unavailableReason ?? "\(isOn ? "Turn off" : "Turn on") \(panel.title)")
      .accessibilityLabel(panel.title)
      .accessibilityValue(isOn ? "On" : "Off")
      .accessibilityAddTraits(isOn ? .isSelected : [])
      // The settings half of the split button. A system split-button Menu can't
      // host the settings form, so this stays a button, wide enough to hit.
      Button(action: openSettings) {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.bold)).imageScale(.small)
          .frame(width: 16, height: 24)
          .foregroundStyle(.white.opacity(0.75))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("\(panel.title) settings")
      .accessibilityLabel("\(panel.title) settings")
    }
    .opacity(unavailableReason == nil ? 1 : 0.45)
  }
}

/// Opens the picture's settings (signal, display transform, geometry, display).
/// Lit while any of them changes the picture from the one published.
private struct UIMonitorPictureButton: View {
  let isAdjusted: Bool
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      Image(systemName: UIMonitorPanel.picture.symbol)
        .font(.callout.weight(.medium))
        .frame(width: 24, height: 24)
        .foregroundStyle(.white)
        .background(isAdjusted ? Color.white.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isAdjusted ? "Picture settings (adjusted)" : "Picture settings")
    .accessibilityLabel("Picture settings")
    .accessibilityValue(isAdjusted ? "Adjusted" : "As published")
  }
}

/// Settings for one monitor tool, bound to the camera's monitor preferences.
struct UIMonitorToolSettingsView: View {
  let panel: UIMonitorPanel
  let cameraID: String
  let cameraName: String
  let isProgram: Bool
  let provider: any UIMonitorSettingsProviding
  @State private var preferences: MonitorFeedPreferences
  /// The provider snapshot represented by `preferences` when the popover last synchronized.
  /// Keeping this separately lets us distinguish an external update from our own write.
  @State private var synchronizedPreferences: MonitorFeedPreferences

  init(panel: UIMonitorPanel, cameraID: String, cameraName: String, isProgram: Bool,
    provider: any UIMonitorSettingsProviding) {
    self.panel = panel
    self.cameraID = cameraID
    self.cameraName = cameraName
    self.isProgram = isProgram
    self.provider = provider
    let initial = provider.preferences(for: cameraID)
    _preferences = State(initialValue: initial)
    _synchronizedPreferences = State(initialValue: initial)
  }

  init(tool: UIMonitorTool, cameraID: String, cameraName: String, isProgram: Bool, provider: any UIMonitorSettingsProviding) {
    self.init(panel: .tool(tool), cameraID: cameraID, cameraName: cameraName, isProgram: isProgram, provider: provider)
  }

  /// Focus needs a camera source. False color remains editable on Program:
  /// its mode picker disables log modes while six band and custom are available.
  static func unavailableReason(_ tool: UIMonitorTool, isProgram: Bool) -> String? {
    guard isProgram else { return nil }
    switch tool {
    case .focus: return "Focus peaking needs a camera's source picture. It is unavailable on Program."
    default: return nil
    }
  }

  static func unavailableReason(_ panel: UIMonitorPanel, isProgram: Bool) -> String? {
    if case .tool(let tool) = panel { return unavailableReason(tool, isProgram: isProgram) }
    return nil
  }

  /// What the popover's header names beside the camera: the signal the tool reads.
  private var subtitle: String {
    Self.subtitle(panel, cameraName: cameraName, isProgram: isProgram, preferences: preferences)
  }

  /// The header's camera and the signal `panel` measures. Log false color reads
  /// the source; six band and custom bands, clip indicators and focus peaking
  /// read their own stage, as does each zebra set that is on; guides and the
  /// picture follow the picture.
  /// Off, false color names the signal its toggle would read.
  static func subtitle(_ panel: UIMonitorPanel, cameraName: String, isProgram: Bool,
    preferences: MonitorFeedPreferences) -> String {
    let state = preferences.state
    func on(_ stage: SignalStage) -> String { "\(cameraName) · \(UIMonitorToolText.stage(stage))" }
    func analysis(_ stage: SignalStage) -> String { "\(cameraName) · analysis on \(UIMonitorToolText.stage(stage))" }
    switch panel {
    case .tool(.scopes): return "\(cameraName) · below the picture"
    case _ where isProgram: return "\(cameraName) · Program Output"
    case .tool(.falseColor):
      let mode = state.falseColor.mode == .off
        ? UIFalseColorChoices.suggestedMode(profile: preferences.signal.logProfileID) : state.falseColor.mode
      return analysis(mode.needsLogSource ? .source : state.falseColor.stage)
    case .tool(.focus): return analysis(state.focus.stage)
    case .clipIndicators: return on(state.clipIndicators.stage)
    case .tool(.zebra):
      // Each set on measures its own stage (zebra 1's follows the picture).
      var stages: [SignalStage] = []
      for zebra in state.zebras where zebra.enabled && !stages.contains(zebra.stage) { stages.append(zebra.stage) }
      if stages.isEmpty { stages = [state.pictureStage] }
      return "\(cameraName) · " + stages.map(UIMonitorToolText.stage).joined(separator: " + ")
    case .tool(.guides), .picture: return on(state.pictureStage)
    }
  }

  /// The tool's own switch, in the header: one per tool that has a single one.
  /// Zebra has a switch per set, false color its mode, the picture none.
  private var headerSwitch: (label: String, isOn: Binding<Bool>)? {
    switch panel {
    case .tool(.guides): return ("Guides", UIMonitorToolBindings.enabling($preferences, \.state.guides.enabled))
    case .tool(.focus): return ("Focus peaking", UIMonitorToolBindings.enabling($preferences, \.state.focus.enabled))
    case .tool(.scopes): return ("Scope", UIMonitorToolBindings.enabling($preferences, \.scopes.enabled))
    case .clipIndicators:
      return ("Clip indicators", UIMonitorToolBindings.enabling($preferences, \.state.clipIndicators.enabled))
    case .tool(.zebra), .tool(.falseColor), .picture: return nil
    }
  }

  var body: some View {
    let reason = Self.unavailableReason(panel, isProgram: isProgram)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: panel.symbol)
          .font(.title3).foregroundStyle(.secondary).frame(width: 26)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(panel.title).font(.headline).accessibilityAddTraits(.isHeader)
          Text(subtitle).font(.uiMeta).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 12)
        if let toggle = headerSwitch {
          Toggle(toggle.label, isOn: toggle.isOn)
            .toggleStyle(.switch).labelsHidden()
            .disabled(reason != nil)
            .help(toggle.isOn.wrappedValue ? "Turn off \(panel.title)" : "Turn on \(panel.title)")
        }
      }
      if let reason {
        Label(reason, systemImage: "info.circle")
          .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      // Sized to the settings; they scroll only on a screen too short for them.
      ScrollView {
        settings
          .disabled(reason != nil)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: UIToolLayout.maximumSettingsHeight)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(UIToolLayout.padding)
    .frame(width: UIToolLayout.panelWidth, alignment: .leading)
    .controlSize(.small)
    .labeledContentStyle(UIToolLabeledContentStyle())
    // Slider updates should only redraw the value and monitor surface. Do not
    // animate the popover or its host layout while a value is being dragged.
    .transaction { transaction in transaction.animation = nil }
    .onChange(of: preferences) { _, value in
      provider.setPreferences(value, for: cameraID)
      synchronizedPreferences = value
    }
    // A provider update can arrive while this popover is open (for example from
    // another surface). Refresh the local draft before the next edit so a later
    // slider change cannot write the stale draft back over that newer state.
    .onChange(of: provider.preferences(for: cameraID)) { _, value in
      guard value != synchronizedPreferences else { return }
      preferences = value
      synchronizedPreferences = value
    }
  }

  @ViewBuilder private var settings: some View {
    switch panel {
    case .tool(.guides): UIGuideSettingsForm(preferences: $preferences, cameraID: cameraID)
    case .tool(.zebra): UIZebraSettingsForm(preferences: $preferences, cameraID: cameraID, isProgram: isProgram)
    case .tool(.falseColor): UIFalseColorSettingsForm(preferences: $preferences, cameraID: cameraID, isProgram: isProgram)
    case .tool(.focus): UIFocusSettingsForm(preferences: $preferences, cameraID: cameraID)
    case .tool(.scopes):
      UIScopeSettingsForm(preferences: $preferences, isProgram: isProgram,
        measurement: provider.scopeMeasurement(for: cameraID))
    case .clipIndicators: UIClipIndicatorSettingsForm(preferences: $preferences, cameraID: cameraID, isProgram: isProgram)
    case .picture: UIPictureSettingsForm(preferences: $preferences, cameraID: cameraID, isProgram: isProgram)
    }
  }
}
