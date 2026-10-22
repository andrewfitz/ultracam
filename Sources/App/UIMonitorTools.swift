import MonitorKitCore
import MonitorKitScopes
import MonitorKitUI
import SwiftUI

/// Split-button monitor tools for one camera: the icon toggles the tool, the
/// chevron opens that tool's settings. Settings are remembered per camera.
struct UIMonitorToolButtons: View {
  let targetID: String
  let name: String
  let activeTools: [UIMonitorTool]
  /// Program has no source correspondence, so source-only tools are disabled there.
  let isProgram: Bool
  let toggle: @MainActor (UIMonitorTool) -> Void
  let monitor: any UIMonitorSettingsProviding
  @State private var openTool: UIMonitorTool?

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
    } label: {
      Image(systemName: activeTools.isEmpty ? "slider.horizontal.3" : "slider.horizontal.below.square.filled.and.square")
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
    .help(activeTools.isEmpty ? "Monitor tools" : "Monitor tools: " + activeTools.map(\.title).joined(separator: ", "))
    .accessibilityLabel("Monitor tools for \(name)")
  }

  private var bar: some View {
    HStack(spacing: 2) {
      ForEach(UIMonitorTool.allCases, id: \.self) { tool in
        UIMonitorToolSplitButton(tool: tool, isOn: activeTools.contains(tool),
          unavailableReason: UIMonitorToolSettingsView.unavailableReason(tool, isProgram: isProgram),
          toggle: { toggle(tool) },
          openSettings: { openTool = tool })
          .popover(isPresented: Binding(get: { openTool == tool }, set: { if !$0 { openTool = nil } }),
            arrowEdge: .bottom) {
            UIMonitorToolSettingsView(tool: tool, cameraID: targetID, cameraName: name,
              isProgram: isProgram, provider: monitor)
          }
      }
    }
    .uiPictureControls()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Monitor tools for \(name)")
  }
}

private struct UIMonitorToolSplitButton: View {
  let tool: UIMonitorTool
  let isOn: Bool
  let unavailableReason: String?
  let toggle: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: toggle) {
        Image(systemName: tool.symbol)
          .font(.callout.weight(.medium))
          .frame(width: 24, height: 24)
          .foregroundStyle(.white)
          .background(isOn ? Color.white.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(unavailableReason != nil)
      .help(unavailableReason ?? "\(isOn ? "Turn off" : "Turn on") \(tool.title)")
      .accessibilityLabel(tool.title)
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
      .help("\(tool.title) settings")
      .accessibilityLabel("\(tool.title) settings")
    }
    .opacity(unavailableReason == nil ? 1 : 0.45)
  }
}

/// Settings for one monitor tool, bound to the camera's monitor preferences.
struct UIMonitorToolSettingsView: View {
  let tool: UIMonitorTool
  let cameraID: String
  let cameraName: String
  let isProgram: Bool
  let provider: any UIMonitorSettingsProviding
  @State private var preferences: MonitorFeedPreferences

  init(tool: UIMonitorTool, cameraID: String, cameraName: String, isProgram: Bool, provider: any UIMonitorSettingsProviding) {
    self.tool = tool
    self.cameraID = cameraID
    self.cameraName = cameraName
    self.isProgram = isProgram
    self.provider = provider
    _preferences = State(initialValue: provider.preferences(for: cameraID))
  }

  static func unavailableReason(_ tool: UIMonitorTool, isProgram: Bool) -> String? {
    guard isProgram else { return nil }
    switch tool {
    case .falseColor: return "False color needs a camera's source picture. It is unavailable on Program."
    case .focus: return "Focus peaking needs a camera's source picture. It is unavailable on Program."
    default: return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(tool.title, systemImage: tool.symbol).font(.headline)
        Spacer()
        Text(cameraName).font(.uiMeta).foregroundStyle(.secondary)
      }
      if let reason = Self.unavailableReason(tool, isProgram: isProgram) {
        Text(reason).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Form { settings }
        .formStyle(.grouped)
        .disabled(Self.unavailableReason(tool, isProgram: isProgram) != nil)
    }
    .padding(14)
    .frame(width: 320)
    .controlSize(.small)
    .onChange(of: preferences) { _, value in provider.setPreferences(value, for: cameraID) }
  }

  @ViewBuilder private var settings: some View {
    switch tool {
    case .guides:
      Toggle("Guides", isOn: binding(\.state.guides.enabled))
      Toggle("Rule of thirds", isOn: $preferences.state.guides.thirds)
      Toggle("Center cross", isOn: $preferences.state.guides.centerCross)
      Toggle("Safe area", isOn: safeArea)
      slider("Opacity", value: $preferences.state.guides.opacity, range: 0...1, percent: true)
      slider("Contrast", value: $preferences.state.guides.contrast, range: 0...1, percent: true)
    case .zebra:
      Toggle("Zebra", isOn: binding(\.state.zebras[0].enabled))
      Picker("Mode", selection: $preferences.state.zebras[0].mode) {
        Text("Above threshold").tag(ZebraMode.lowerLimit)
        Text("Band").tag(ZebraMode.band)
      }
      slider("Threshold", value: $preferences.state.zebras[0].level, range: 0...109, suffix: " IRE")
      // The band's full width; MonitorKit keeps its half-width (`range`).
      slider("Width", value: Binding(get: { preferences.state.zebras[0].range * 2 },
        set: { preferences.state.zebras[0].range = $0 / 2 }), range: 0...30, suffix: " IRE")
        .disabled(preferences.state.zebras[0].mode != .band)
      slider("Opacity", value: $preferences.state.zebras[0].opacity, range: 0...1, percent: true)
      if preferences.state.falseColor.mode != .off {
        Text("Zebra is bypassed while false color is on.").font(.uiMeta).foregroundStyle(.secondary)
      }
    case .falseColor:
      falseColorSettings
    case .focus:
      Toggle("Focus peaking", isOn: binding(\.state.focus.enabled))
      Picker("Highlight", selection: $preferences.state.focus.color) {
        ForEach(PeakingColor.allCases, id: \.self) { color in
          Text(color.rawValue.capitalized).tag(color)
        }
      }
      slider("Sensitivity", value: $preferences.state.focus.sensitivity, range: 0...1, percent: true)
      slider("Noise rejection", value: $preferences.state.focus.noiseRejection, range: 0...1, percent: true)
      slider("Opacity", value: $preferences.state.focus.opacity, range: 0...1, percent: true)
      Text("Edges are found on the camera's source picture at full resolution.")
        .font(.uiMeta).foregroundStyle(.secondary)
    case .scopes:
      Toggle("Scope", isOn: binding(\.scopes.enabled))
      Picker("Type", selection: $preferences.scopes.settings.waveformMode) {
        Text("RGB parade").tag(WaveformMode.rgbParade)
        Text("Luma waveform").tag(WaveformMode.luma)
        if preferences.scopes.settings.waveformMode != .rgbParade && preferences.scopes.settings.waveformMode != .luma {
          Text(preferences.scopes.title).tag(preferences.scopes.settings.waveformMode).disabled(true)
        }
      }
      Picker("Signal", selection: $preferences.scopes.settings.stage) {
        Text("Source").tag(SignalStage.source).disabled(isProgram)
        Text("Output (LUT)").tag(SignalStage.output)
        if preferences.scopes.settings.stage == .monitor {
          Text("Monitor").tag(SignalStage.monitor)
        }
      }
      Picker("Refresh", selection: $preferences.scopes.refreshHz) {
        ForEach(MonitorScopePreferences.refreshRates, id: \.self) { Text("\($0) Hz").tag($0) }
      }
      slider("Trace gain", value: $preferences.scopes.settings.display.gain, range: 0.25...4, suffix: "×")
      Toggle("Graticule", isOn: $preferences.scopes.settings.display.showsGraticule)
      Text("One scope per camera. Every pixel, \(preferences.scopes.ireScale.rangeText) IRE.")
        .font(.uiMeta).foregroundStyle(.secondary)
    }
  }

  /// MonitorTools' one safe area, 5% in from each edge: MonitorKit's 90% area.
  private var safeArea: Binding<Bool> {
    Binding(
      get: { preferences.state.guides.safeAreas.contains(90) },
      set: { on in
        var areas = preferences.state.guides.safeAreas.filter { $0 != 90 }
        if on { areas.append(90) }
        preferences.state.guides.safeAreas = areas
      })
  }

  @ViewBuilder private var falseColorSettings: some View {
    let profile = preferences.signal.logProfileID
    let sonySource = SonySLog3FalseColor.supports(sourceProfileID: profile)
    let elZoneAvailable = !isProgram && ELZoneProfile.supports(sourceProfileID: profile)
    let mode = preferences.state.falseColor.mode
    Picker("Mode", selection: falseColorMode) {
      Text("Off").tag(FalseColorMode.off)
      Text("Sony S-Log3").tag(FalseColorMode.sonySLog3).disabled(isProgram || !sonySource)
      Text("EL Zone").tag(FalseColorMode.elZone).disabled(!elZoneAvailable)
      if mode != .off && mode != .sonySLog3 && mode != .elZone {
        Text("Unsupported saved mode").tag(mode).disabled(true)
      }
    }
    Picker("Camera / Log", selection: sourceProfile) {
      if profile != "" { Text("Unknown").tag("") }
      Text("Sony S-Gamut3.Cine / S-Log3").tag("sony-slog3-sgamut3cine")
      Text("Sony S-Gamut3 / S-Log3").tag("sony-slog3-sgamut3")
      if let profile, !SonySLog3FalseColor.supports(sourceProfileID: profile) {
        Text("Unsupported saved input").tag(profile).disabled(true)
      }
    }
    Picker("Input code range", selection: $preferences.signal.range) {
      Text("Format native / unspecified").tag(Optional<CodeRange>.none)
      Text("Legal (64…940 at 10-bit)").tag(Optional(CodeRange.legal))
      Text("Full (0…1023 at 10-bit)").tag(Optional(CodeRange.full))
    }
    Picker("Log transport", selection: $preferences.signal.transport) {
      Text("Declared native 10-bit codes").tag(LogTransport.native)
      Text("Full codes rescaled to legal").tag(LogTransport.fullRescaledToLegal)
    }
    if mode == .elZone {
      Stepper(value: $preferences.state.falseColor.referenceOffsetStops, in: -6...6, step: 0.25) {
        Text("Exposure offset \(preferences.state.falseColor.referenceOffsetStops, specifier: "%+.2f") stops")
      }
      .disabled(!elZoneAvailable)
      .help("Adds stops to measured source exposure. Camera EI is independent.")
    }
    Text(mode == .elZone
      ? (elZoneAvailable ? "Public-chart mapping. Sony Monitor & Control match not tested." : "EL Zone needs a supported Sony S-Log3 source.")
      : sonySource ? "Sony source IRE thresholds are independent of EI and don't guarantee sensor clipping."
        : "Choose the Sony S-Log3 profile that matches the camera.")
      .font(.uiMeta).foregroundStyle(.secondary)
    Text("Match the actual camera output. These settings don't change the camera output.")
      .font(.uiMeta).foregroundStyle(.secondary)
  }

  /// Enabling a tool from its settings also turns the camera's tools on.
  private func binding(_ keyPath: WritableKeyPath<MonitorFeedPreferences, Bool>) -> Binding<Bool> {
    Binding(
      get: { preferences.toolsEnabled && preferences[keyPath: keyPath] },
      set: { on in
        var next = preferences
        if on && !next.toolsEnabled { next.hideAllTools() }
        next[keyPath: keyPath] = on
        next.toolsEnabled = next.anyToolOn
        preferences = next
      })
  }

  private var falseColorMode: Binding<FalseColorMode> {
    Binding(
      get: { preferences.toolsEnabled ? preferences.state.falseColor.mode : .off },
      set: { mode in
        var next = preferences
        if mode != .off && !next.toolsEnabled { next.hideAllTools() }
        next.state.falseColor.mode = mode
        next.toolsEnabled = next.anyToolOn
        preferences = next
      })
  }

  private var sourceProfile: Binding<String> {
    Binding(
      get: { preferences.signal.logProfileID ?? "" },
      set: { value in preferences.signal.logProfileID = value.isEmpty ? nil : value })
  }

  private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
    percent: Bool = false, suffix: String = "") -> some View {
    LabeledContent {
      HStack {
        Slider(value: value, in: range).frame(minWidth: 110)
        Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: suffix == "×" ? "%.2f" : "%.0f", value.wrappedValue) + suffix)
          .font(.uiMeta.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
      }
    } label: { Text(title) }
    .accessibilityElement(children: .combine)
  }
}
