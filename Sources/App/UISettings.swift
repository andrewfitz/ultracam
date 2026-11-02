import AppKit
import ServiceManagement
import SwiftUI

/// Settings' sections, one native toolbar tab each, in this order. The raw value is saved
/// (`UIInterfaceState.settingsTab`), so Settings reopens where it was left.
enum UISettingsTab: String, CaseIterable, Identifiable, Sendable {
  case general, hardware, virtualCameras, recording, audio, switching, alerts, advanced

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .hardware: return "Hardware"
    case .virtualCameras: return "Virtual Cameras"
    case .recording: return "Recording"
    case .audio: return "Audio"
    case .switching: return "Switching"
    case .alerts: return "Alerts"
    case .advanced: return "Advanced"
    }
  }

  /// A "Settings › Audio" link in text: `ultracam-settings:audio`.
  static let linkScheme = "ultracam-settings"

  static func linked(_ url: URL) -> UISettingsTab? {
    guard url.scheme == linkScheme else { return nil }
    return UISettingsTab(rawValue: url.absoluteString.dropFirst(linkScheme.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
  }

  var symbol: String {
    switch self {
    case .general: return UISymbol.settings
    case .hardware: return UISymbol.input
    case .virtualCameras: return UISymbol.virtualCamera(inUse: true)
    case .recording: return UISymbol.record
    case .audio: return UISymbol.audio
    case .switching: return UISymbol.cut
    case .alerts: return UISymbol.alerts
    case .advanced: return UISymbol.advancedSettings
    }
  }
}

/// Settings window (⌘,). Settings change app-wide state, so the panes work on the models
/// directly. An ordinary resizable window: it keeps its size between tabs, the user sizes it
/// with the window edges, and a pane longer than the window scrolls.
struct UISettingsView: View {
  let model: AppModel
  @Bindable var interface: UIInterfaceState
  var shortcuts: UIBackgroundShortcuts = UIAppEnvironment.backgroundShortcuts
  var alerts: UIAlertPreferences = UIAppEnvironment.alertPreferences

  var body: some View {
    TabView(selection: $interface.settingsTab) {
      ForEach(UISettingsTab.allCases) { tab in
        pane(tab)
          .tabItem { Label(tab.title, systemImage: tab.symbol) }
          .tag(tab)
      }
    }
    .frame(minWidth: UISettingsLayout.minimumWidth, idealWidth: UISettingsLayout.defaultSize.width, maxWidth: .infinity,
      minHeight: UISettingsLayout.minimumHeight, idealHeight: UISettingsLayout.defaultSize.height,
      maxHeight: .infinity)
  }

  @ViewBuilder private func pane(_ tab: UISettingsTab) -> some View {
    switch tab {
    case .general: UISettingsGeneralPane(model: model, interface: interface, shortcuts: shortcuts)
    case .hardware: UISettingsHardwarePane(model: model, interface: interface)
    case .virtualCameras: UISettingsVirtualCamerasPane(model: model)
    case .recording: UISettingsRecordingPane(model: model)
    case .audio: UISettingsAudioPane(model: model, interface: interface)
    case .switching: UISettingsSwitchingPane(model: model)
    case .alerts: UISettingsAlertsPane(model: model, interface: interface, preferences: alerts)
    case .advanced: UISettingsAdvancedPane(model: model)
    }
  }
}

enum UISettingsLayout {
  /// Wide enough for the eight tabs.
  static let minimumWidth: CGFloat = 820
  static let minimumHeight: CGFloat = 320
  /// The window's size the first time it opens; after that it keeps the user's.
  static let defaultSize = CGSize(width: 820, height: 600)
}

/// One tab: a grouped form filling the window, scrolling when it is longer. A pane may end
/// with one action at the bottom trailing edge, outside any section (Restore Defaults).
struct UISettingsPane<Content: View, Trailing: View>: View {
  let content: Content
  let trailing: Trailing

  init(@ViewBuilder content: () -> Content) where Trailing == EmptyView {
    self.content = content()
    trailing = EmptyView()
  }

  init(@ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
    self.content = content()
    self.trailing = trailing()
  }

  private var hasTrailing: Bool { Trailing.self != EmptyView.self }

  var body: some View {
    VStack(spacing: 0) {
      Form { content }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
      if hasTrailing {
        HStack {
          Spacer()
          trailing
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
      }
    }
  }
}

/// A section's one sentence, under it.
struct UISettingsFootnote: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}

/// Anything longer than a sentence: an ⓘ beside the row or header that opens it.
struct UISettingsInfoButton: View {
  let title: String
  let text: String
  @State private var shown = false

  var body: some View {
    Button { shown.toggle() } label: { Image(systemName: UISymbol.information) }
      .buttonStyle(.borderless)
      .frame(width: 24, height: 24)
      .help(title)
      .accessibilityLabel("About \(title)")
      .popover(isPresented: $shown, arrowEdge: .trailing) {
        VStack(alignment: .leading, spacing: 6) {
          Text(title).font(.uiRowEmphasis)
          Text(text).font(.uiRow).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
      }
  }
}

/// A section header with an info button at its trailing edge.
struct UISettingsHeader: View {
  let title: String
  var info: String?

  init(_ title: String, info: String? = nil) {
    self.title = title
    self.info = info
  }

  var body: some View {
    HStack {
      Text(title)
      Spacer(minLength: 4)
      if let info { UISettingsInfoButton(title: title, text: info) }
    }
  }
}

// MARK: - General

struct UISettingsGeneralPane: View {
  @Bindable var model: AppModel
  let interface: UIInterfaceState
  @Bindable var shortcuts: UIBackgroundShortcuts
  @AppStorage(UIInterfaceState.askBeforeEndingKey) private var askBeforeEnding = true
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?

  private var showInDock: Binding<Bool> {
    Binding(get: { !model.hideFromDock }, set: { model.hideFromDock = !$0 })
  }

  var body: some View {
    UISettingsPane {
      Section {
        Picker("Show Ultracam in", selection: showInDock) {
          Text("Dock and menu bar").tag(true)
          Text("Menu bar when closed").tag(false)
        }
        .help("Menu bar when closed: Ultracam is in the Dock while a window is open, and only in the menu bar once you close them. Closing the window never stops capture, camera output or recording.")
        Toggle("Open Ultracam at login", isOn: Binding(
          get: { loginStatus == .enabled || loginStatus == .requiresApproval },
          set: { setOpenAtLogin($0) }))
        .help("Starts Ultracam in the menu bar when you log in, so automatic start can work.")
        if loginStatus == .requiresApproval {
          LabeledContent {
            Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
          } label: {
            Label { Text("Needs approval") } icon: {
              Image(systemName: UISymbol.warning).foregroundStyle(.orange)
            }
            Text("System Settings › General › Login Items & Extensions")
          }
        }
        if let loginError {
          Label { Text(loginError).foregroundStyle(.secondary) } icon: {
            Image(systemName: UISymbol.warning).foregroundStyle(.orange)
          }
          .font(.uiRow)
        }
        Toggle(isOn: $askBeforeEnding) {
          Text("Ask before ending a recording or on-air video")
          Text("Covers Stop All Recordings and Quit. Plain ⌘R on one camera stays unprompted.")
        }
      } header: { Text("App") } footer: {
        UISettingsFootnote("Quitting waits for active recordings to finish writing.")
      }

      Section {
        Toggle(isOn: $shortcuts.enabled) {
          Text("Use background shortcuts")
          Text("They work while another app is in front. No Accessibility permission needed.")
        }
        if shortcuts.enabled {
          shortcutRow("Cut to Camera 1 to 7", key: "⌃⌥⌘1 to ⌃⌥⌘7",
            unavailable: shortcuts.unavailable.contains { if case .cut = $0 { return true }; return false })
          shortcutRow("Auto", key: UIBackgroundShortcut.auto.title, unavailable: shortcuts.unavailable.contains(.auto))
          shortcutRow("Hold", key: UIBackgroundShortcut.hold.title, unavailable: shortcuts.unavailable.contains(.hold))
          shortcutRow("Record", detail: "Starts a recording. Never stops one, so a stray chord can’t end a take.",
            key: UIBackgroundShortcut.record.title, unavailable: shortcuts.unavailable.contains(.record))
        }
      } header: { Text("Background Shortcuts") }
    }
    .onAppear { loginStatus = SMAppService.mainApp.status }
  }

  private func shortcutRow(_ title: String, detail: String? = nil, key: String, unavailable: Bool) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        if unavailable {
          Label("In use by another app", systemImage: UISymbol.warning)
            .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
            .symbolRenderingMode(.multicolor)
        }
        UIKeycap(key)
      }
    } label: {
      Text(title)
      if let detail { Text(detail) }
    }
  }

  private func setOpenAtLogin(_ enabled: Bool) {
    loginError = nil
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      loginError = "Couldn't change Open at login: \(error.localizedDescription)"
    }
    loginStatus = SMAppService.mainApp.status
  }
}

/// A key combination on a keycap chip, in Help and Settings. The system font draws ⌘ ⇧ ⌥ ⌃
/// at full size, as menus do; SF Mono shrinks them.
struct UIKeycap: View {
  let key: String
  init(_ key: String) { self.key = key }
  var body: some View {
    Text(key).font(.body).padding(.horizontal, 6).frame(minHeight: 20)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 5))
  }
}

// MARK: - Virtual Cameras

struct UISettingsVirtualCamerasPane: View {
  let model: AppModel
  /// The installer's status before any request; the footer shows only what a request reported since.
  private static let readyStatus = ExtensionInstallPreflight.current().readyStatus

  var body: some View {
    let installer = model.installer
    let state = UISettingsExtensionState(installer: installer, published: UIExtensionDetector.isInstalled())
    let locked = !installer.canRequestChanges || installer.pending || model.running
    UISettingsPane {
      Section {
        LabeledContent {
          HStack(spacing: 8) {
            if installer.pending { ProgressView().controlSize(.small) }
            switch state.action {
            case .install, .update:
              Button(state.action == .update ? "Update Camera Extension…" : "Install Camera Extension…") { installer.install() }
                .disabled(locked)
                .help(installHelp)
            case .none:
              if let version = state.version { Text("Version \(version)").foregroundStyle(.secondary).monospacedDigit() }
            }
          }
        } label: {
          Label { Text(state.title) } icon: {
            Image(systemName: state.symbol).foregroundStyle(state.color)
          }
          // A request's result sits beside the control until the state changes, never in the footer.
          if let result = requestResult(needsApproval: state.needsApproval) { Text(result) }
        }
        if state.needsApproval {
          LabeledContent {
            Button("Open System Settings") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
              }
            }
          } label: {
            Text("System Settings › General › Login Items & Extensions › Camera Extensions")
          }
        }
        if state.removable {
          LabeledContent("Remove the extension") {
            Button("Remove Camera Extension…") { installer.uninstall() }
              .disabled(locked)
              .help(installHelp)
          }
        }
      } header: { Text("Camera Extension") } footer: {
        UISettingsFootnote(extensionFooter(needsApproval: state.needsApproval))
      }

      Section {
        Picker(selection: Binding(get: { model.programColorSpaceID }, set: { model.setProgramColorSpace($0) })) {
          ForEach(UIProgramColor.choices, id: \.id) { Text($0.title).tag($0.id) }
        } label: {
          Text("Program color")
          Text("The color space Ultracam · Program sends")
        }
      } header: { Text("Program") }
    }
  }

  /// The last request's result, while it says something the status line doesn't.
  private func requestResult(needsApproval: Bool) -> String? {
    let installer = model.installer
    guard installer.unavailableReason == nil, !needsApproval, !installer.pending,
      installer.status != Self.readyStatus else { return nil }
    return installer.status
  }

  /// One sentence; a reason it can't install replaces it, as that already says capture still works.
  private func extensionFooter(needsApproval: Bool) -> String {
    model.installer.unavailableReason
      ?? "Installing and removing go through System Settings and are unavailable while a camera is running. Capture, preview and recording work without the extension."
  }

  private var installHelp: String {
    if let reason = model.installer.unavailableReason { return reason }
    if model.installer.pending { return "A camera extension request is pending." }
    if model.running { return "Stop the cameras before installing or removing the camera extension." }
    return "Install or remove the Ultracam camera extension. This doesn't add or remove your cameras."
  }
}

/// Program's three color spaces, by the catalog's IDs.
enum UIProgramColor {
  static let choices: [(id: String, title: String)] = [
    ("rec709-video", "Rec.709"), ("rec2020-pq-video", "Rec.2020 PQ"), ("rec2020-hlg-video", "Rec.2020 HLG"),
  ]
}

/// The camera extension's one status line and which button its row offers.
struct UISettingsExtensionState: Equatable {
  enum Action: Equatable { case none, install, update }
  var title: String
  var symbol: String
  var color: Color
  var action: Action
  /// Installed, or installed and waiting for a restart: Remove gets its own row.
  var removable: Bool
  var needsApproval = false
  var version: String?

  @MainActor init(installer: ExtensionInstaller, published: Bool) {
    let system = installer.system
    needsApproval = installer.status.localizedCaseInsensitiveContains("approve")
      || (system?.awaitingApproval == true && system?.enabled == false)
    version = system?.enabledVersion ?? system?.bundledVersion
    if installer.unavailableReason != nil {
      (title, symbol, color, action, removable) = ("Needs a signed build", UISymbol.warning, .orange, .install, false)
    } else if installer.pending {
      (title, symbol, color, action, removable) = ("Waiting for macOS…", UISymbol.waitingCamera, .secondary, .install, false)
    } else if needsApproval {
      (title, symbol, color, action, removable) = ("Needs approval", UISymbol.warning, .orange, .none, false)
      version = nil
    } else if let system, system.enabled {
      if system.outdated, let installed = system.enabledVersion, let bundled = system.bundledVersion {
        (title, symbol, color, action, removable) = ("\(installed) installed   \(bundled) available", UISymbol.updateExtension, .orange, .update, true)
        version = nil
      } else if published {
        (title, symbol, color, action, removable) = ("Installed", UISymbol.saved, .green, .none, true)
      } else {
        // Enabled but not started until a restart: installing again wouldn't help.
        (title, symbol, color, action, removable) = ("Restart your Mac to finish installing", UISymbol.restartNeeded, .orange, .none, true)
        version = nil
      }
    } else if published {
      (title, symbol, color, action, removable) = ("Installed", UISymbol.saved, .green, .none, true)
    } else {
      (title, symbol, color, action, removable) = ("Not installed", UISymbol.installExtension, .secondary, .install, false)
      version = nil
    }
  }
}

// MARK: - Switching

struct UISettingsSwitchingPane: View {
  let model: AppModel
  @State private var draft = NaturalTalkingHeadSettings()
  @State private var interval = UISettingsSwitchingPane.defaultInterval
  @State private var loaded = false
  @State private var advancedOpen = false
  /// What Restore Defaults puts the fixed interval back to: what a first run has.
  static let defaultInterval = SwitcherSettings().intervalSeconds

  var body: some View {
    UISettingsPane {
      Section("Fixed Interval") {
        UISettingsNumberRow(title: "Interval", value: $interval, range: 1...30, step: 0.5, unit: "s") { commitInterval() }
      }

      Section {
        UISettingsShotTimeline(minimum: draft.minimumShotDuration, softMaximum: draft.softMaximumShotDuration,
          maximum: draft.maximumShotDuration, grace: draft.forcedCutGracePeriod)
        UISettingsNumberRow(title: "Minimum shot", value: $draft.minimumShotDuration, range: 10...60, step: 1, unit: "s") { commitDirector() }
        UISettingsNumberRow(title: "Soft maximum", value: $draft.softMaximumShotDuration, range: 10...120, step: 1, unit: "s") { commitDirector() }
        UISettingsNumberRow(title: "Maximum shot", value: $draft.maximumShotDuration, range: 10...180, step: 1, unit: "s") { commitDirector() }
        UISettingsNumberRow(title: "Cooldown", value: $draft.cooldown, range: 0...10, step: 0.5, unit: "s") { commitDirector() }
        UISettingsNumberRow(title: "Emphasis hold", value: $draft.emphasisHold, range: 0...30, step: 0.5, unit: "s") { commitDirector() }
        UISettingsNumberRow(title: "Forced-cut grace", value: $draft.forcedCutGracePeriod, range: 0...10, step: 0.5, unit: "s") { commitDirector() }
      } header: {
        UISettingsHeader("Natural Talking Head", info: "Before the minimum shot nothing cuts. Cuts are allowed after it, encouraged after the soft maximum, and forced within the grace after the maximum. Strategy, Anchor, Emphasis and Hold are in the toolbar's Auto menu.")
      }

      Section {
        DisclosureGroup("Advanced cut decisions", isExpanded: $advancedOpen) {
          UISettingsSlider(title: "Cut threshold", value: floatBinding(\.cutThreshold), range: 0...1, step: 0.01, unit: "") { commitDirector() }
          UISettingsSlider(title: "Hysteresis margin", value: floatBinding(\.hysteresisMargin), range: 0...1, step: 0.01, unit: "") { commitDirector() }
          UISettingsNumberRow(title: "Pause boundary", value: $draft.pauseBoundaryDuration, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
          UISettingsNumberRow(title: "Boundary window", value: $draft.boundaryWindow, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
          UISettingsNumberRow(title: "Candidate dwell", value: $draft.candidateDwell, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
          UISettingsNumberRow(title: "Forced boundary lookback", value: $draft.forcedBoundaryLookback, range: 0...5, step: 0.1, unit: "s") { commitDirector() }
          // Nothing feeds the director a transcript yet, so these do nothing until a source exists (B14).
          if NaturalTalkingHeadSettings.transcriptSourceAvailable {
            UISettingsSlider(title: "Transcript confidence", value: floatBinding(\.transcriptConfidenceThreshold), range: 0...1, step: 0.01, unit: "") { commitDirector() }
            UISettingsNumberRow(title: "Transcript output delay", value: $draft.transcriptOutputDelay, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
          }
        }
      } footer: {
        UISettingsFootnote("Decisions apply at Program frame boundaries. A timeline sidecar is written to the recording folder.")
      }
    } trailing: {
      // Restores the fixed interval too.
      Button("Restore Defaults") { restoreDefaults() }
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      draft = model.switcherSettings.naturalTalkingHead
      interval = model.switcherSettings.intervalSeconds
    }
  }

  private func floatBinding(_ keyPath: WritableKeyPath<NaturalTalkingHeadSettings, Float>) -> Binding<Double> {
    Binding(get: { Double(draft[keyPath: keyPath]) }, set: { draft[keyPath: keyPath] = Float($0) })
  }

  /// Writes the director settings once an edit ends. updateSwitcher recreates the director.
  private func commitDirector() {
    var settings = model.switcherSettings
    let current = settings.naturalTalkingHead
    var next = draft
    next.enabled = current.enabled
    next.anchorFeedID = current.anchorFeedID
    next.emphasisFeedID = current.emphasisFeedID
    next.manualHold = current.manualHold
    next.mode = current.mode
    guard next != current else { return }
    settings.naturalTalkingHead = next
    model.updateSwitcher(settings)
  }

  private func commitInterval() {
    var settings = model.switcherSettings
    guard settings.intervalSeconds != interval else { return }
    settings.intervalSeconds = interval
    model.updateSwitcher(settings)
  }

  private func restoreDefaults() {
    draft = NaturalTalkingHeadSettings()
    interval = Self.defaultInterval
    commitDirector()
    commitInterval()
  }
}

/// A number typed into a field or stepped, with its unit: shot limits and the other seconds.
/// Commits on Return, on leaving the field and on each step. While editing, the row says the range.
struct UISettingsNumberRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: String
  let onCommit: () -> Void
  @FocusState private var focused: Bool

  private var digits: Int { step < 0.1 ? 2 : step < 1 ? 1 : 0 }

  private var committed: Binding<Double> {
    Binding(get: { value }, set: { newValue in
      let stepped = (min(max(newValue, range.lowerBound), range.upperBound) / step).rounded() * step
      guard stepped != value else { return }
      value = stepped
      onCommit()
    })
  }

  var body: some View {
    LabeledContent {
      HStack(spacing: 4) {
        TextField(title, value: committed, format: .number.precision(.fractionLength(digits)))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 56)
          .focused($focused)
        Text(unit).foregroundStyle(.secondary)
        Stepper(title, value: committed, in: range, step: step).labelsHidden()
      }
    } label: {
      Text(title)
      if focused { Text("\(Self.number(range.lowerBound, digits: digits)) to \(Self.number(range.upperBound, digits: digits)) \(unit)") }
    }
    .accessibilityElement(children: .contain)
  }

  private static func number(_ value: Double, digits: Int) -> String {
    value.formatted(.number.precision(.fractionLength(0...digits)))
  }
}

/// A slider for a 0–1 scale, where exact values matter less. Reports its value live and
/// commits once editing ends.
struct UISettingsSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: String
  let onCommit: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    LabeledContent {
      HStack {
        // Rounded through the binding: a stepped Slider draws a tick for every step.
        Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range) { editing in
          if !editing { onCommit() }
        }
          .accessibilityLabel(title)
          .accessibilityValue(formatted)
        Text(formatted).monospacedDigit().foregroundStyle(isEnabled ? .secondary : .tertiary).frame(width: 56, alignment: .trailing)
      }
    } label: {
      // A disabled form label doesn't dim by itself; this shows the row doesn't apply.
      Text(title).foregroundStyle(isEnabled ? .primary : .tertiary)
    }
  }

  private var formatted: String {
    let number = step < 0.1 ? String(format: "%.2f", value) : step < 1 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    return unit.isEmpty ? number : "\(number) \(unit)"
  }
}

/// Visual of the shot limits: minimum, soft maximum, maximum and the forced-cut grace.
/// Bands: before the minimum no cut happens, then cuts are allowed (green), encouraged
/// after the soft maximum (yellow) and forced within the grace after the maximum (gray).
/// No red: red means on air or recording (D8).
struct UISettingsShotTimeline: View {
  let minimum: Double
  let softMaximum: Double
  let maximum: Double
  let grace: Double
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    let span = max(maximum + grace, 1)
    let fraction = { (value: Double) in CGFloat(min(max(value / span, 0), 1)) }
    VStack(spacing: 3) {
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .leading) {
          ZStack(alignment: .leading) {
            Rectangle().fill(.fill.tertiary)
            band(from: fraction(minimum), to: fraction(softMaximum), width: width, color: .green)
            band(from: fraction(softMaximum), to: fraction(maximum), width: width, color: .yellow)
            band(from: fraction(maximum), to: 1, width: width, color: .gray)
          }
          .frame(height: 8)
          .clipShape(Capsule())
          tick(at: width * fraction(minimum), color: .secondary)
          tick(at: width * fraction(softMaximum), color: .secondary)
          tick(at: width * fraction(maximum), color: .primary)
        }
      }
      .frame(height: 14)
      UIShotTimelineLabels(positions: [fraction(minimum), fraction(softMaximum), fraction(maximum)]) {
        Text("min \(Int(minimum)) s")
        Text("soft max \(Int(softMaximum)) s")
        Text("max \(Int(maximum)) s")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .opacity(isEnabled ? 1 : 0.5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Shot limits")
    .accessibilityValue("Minimum \(Int(minimum)) seconds, soft maximum \(Int(softMaximum)) seconds, maximum \(Int(maximum)) seconds plus \(Int(grace)) seconds grace")
  }

  private func band(from start: CGFloat, to end: CGFloat, width: CGFloat, color: Color) -> some View {
    Rectangle().fill(color.opacity(0.75))
      .frame(width: max(0, end - start) * width)
      .offset(x: start * width)
  }

  private func tick(at x: CGFloat, color: Color) -> some View {
    Rectangle().fill(color).frame(width: 1.5, height: 14).offset(x: x - 0.75)
  }
}

/// Places each label centered under its position, pushed apart so they don't overlap
/// and kept inside the row so the last one never runs past the trailing inset.
private struct UIShotTimelineLabels: Layout {
  let positions: [CGFloat]
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    return CGSize(width: proposal.width ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    var origins = sizes.indices.map { index in
      bounds.width * (positions.indices.contains(index) ? positions[index] : 0) - sizes[index].width / 2
    }
    // Left to right: stay inside the leading edge and clear of the previous label.
    for index in origins.indices {
      let floor = index == 0 ? 0 : origins[index - 1] + sizes[index - 1].width + spacing
      origins[index] = max(origins[index], floor)
    }
    // Right to left: stay inside the trailing edge, pushing earlier labels back if needed.
    for index in origins.indices.reversed() {
      let ceiling = index == origins.count - 1 ? bounds.width - sizes[index].width
        : origins[index + 1] - spacing - sizes[index].width
      origins[index] = max(0, min(origins[index], ceiling))
    }
    for (index, subview) in subviews.enumerated() {
      subview.place(at: CGPoint(x: bounds.minX + origins[index], y: bounds.minY), proposal: ProposedViewSize(sizes[index]))
    }
  }
}

// MARK: - Advanced

struct UISettingsAdvancedPane: View {
  @Bindable var model: AppModel
  @State private var confirmForgetLUTs = false

  var body: some View {
    UISettingsPane {
      Section {
        Toggle("Allow CPU conversion (compatibility)", isOn: $model.allowCPUConversion)
      } header: {
        UISettingsHeader("Video Compatibility", info: "Allows system conversion only when the required GPU conversion route can’t be used. Metal 4 is still required. It may use the CPU or GPU internally, and it’s shown on the camera and counted in diagnostics and take metadata.")
      } footer: {
        UISettingsFootnote("Applies to the next capture or take.")
      }

      Section {
        LabeledContent {
          Button("Forget Saved LUTs…") { confirmForgetLUTs = true }
        } label: {
          Text("Saved LUT access")
          Text("Read-only bookmarks for each camera’s .cube files, burn-in and monitor")
        }
      } header: { Text("LUTs") } footer: {
        UISettingsFootnote("A missing LUT never blocks capture. The camera keeps its choice so it can be located again.")
      }

      Section {
        LabeledContent {
          Button("Reset…", role: .destructive) {
            // The bridge asks for confirmation (in the main window, or as an alert), then resets and quits.
            UISessionBridge.live(model: model, interface: UIAppEnvironment.interface).send(.resetAllSettings)
          }
          .disabled(!model.canResetSettings)
          .help(model.canResetSettings ? "Reset every saved preference and quit."
            : "Stop all cameras and let recordings finish before resetting.")
        } label: {
          Text("Reset all settings")
          Text(model.canResetSettings ? "Cameras, effects, folders, monitor tools and layout"
            : "Stop all cameras and let recordings finish first")
        }
      } header: { Text("Reset") } footer: {
        UISettingsFootnote("Recordings are never touched. Reset asks first, then Ultracam quits so it starts fresh.")
      }
    }
    .confirmationDialog("Forget saved LUTs?", isPresented: $confirmForgetLUTs) {
      Button("Forget Saved LUTs", role: .destructive) { forgetLUTs() }
      Button("Cancel", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
    } message: {
      Text("Each camera stops applying its saved LUT and its monitor LUT until you choose a .cube file again.")
    }
  }

  private func forgetLUTs() {
    // forgetLUT also clears the selected camera's loaded LUT, which updateCamera can't.
    for descriptor in model.feedDescriptors { model.forgetLUT(descriptor.id) }
    // Monitor LUTs live in each camera's monitor preferences; the coordinator saves them.
    let monitor = UIAppMonitorSettings(model: model)
    for descriptor in model.feedDescriptors {
      UIMonitorLUTMenu.remove(cameraID: descriptor.id.rawValue, monitor: monitor)
    }
  }
}
