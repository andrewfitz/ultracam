import AppKit
import ServiceManagement
import SwiftUI

/// Settings window (⌘,): General, Recording, Camera, Switcher, Monitor, Advanced.
/// Settings change app-wide state, so these panes work on the models directly.
struct UISettingsView: View {
  let model: AppModel

  var body: some View {
    TabView {
      UISettingsGeneralPane(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
      UISettingsRecordingPane(model: model)
        .tabItem { Label("Recording", systemImage: "record.circle") }
      UISettingsCameraPane(model: model)
        .tabItem { Label("Camera", systemImage: "video") }
      UISettingsSwitcherPane(model: model)
        .tabItem { Label("Switcher", systemImage: "tv") }
      UISettingsMonitorPane()
        .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
      UISettingsAdvancedPane(model: model)
        .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
    }
    // Each pane sets its own height, so the window resizes to fit the tab like other Settings windows.
    .frame(width: 640)
  }
}

private struct UISettingsFootnote: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - General

struct UISettingsGeneralPane: View {
  @Bindable var model: AppModel
  @AppStorage("ui.layout") private var defaultLayout = UILayout.sideBySide.rawValue
  /// "collapsed" or "expanded"; the app reads it when a new camera is added.
  @AppStorage("ui.collapsed.default") private var stripDensity = "expanded"
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?

  private var showInDock: Binding<Bool> {
    Binding(get: { !model.hideFromDock }, set: { model.hideFromDock = !$0 })
  }

  var body: some View {
    Form {
      Section {
        Picker("Show Ultracam in", selection: showInDock) {
          Text("Dock and menu bar").tag(true)
          Text("Menu bar only").tag(false)
        }
        .help("Menu bar only hides the Dock icon. Closing the window never stops capture, camera output or recording.")
        Toggle("Open Ultracam at login", isOn: Binding(
          get: { loginStatus == .enabled || loginStatus == .requiresApproval },
          set: { setOpenAtLogin($0) }))
        .help("Starts Ultracam in the menu bar when you log in, so automatic start can work.")
        if loginStatus == .requiresApproval {
          LabeledContent {
            Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
          } label: {
            Text("Needs approval")
            Text("System Settings › General › Login Items & Extensions")
          }
        }
        if let loginError {
          Label { Text(loginError).foregroundStyle(.secondary) } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          .font(.callout)
        }
      } header: { Text("App") } footer: {
        UISettingsFootnote("Quitting waits for active recordings to finish writing. The menu bar icon shows a dot while recording and a triangle when something needs attention.")
      }

      Section {
        Picker("Layout", selection: $defaultLayout) {
          ForEach(UILayout.allCases, id: \.rawValue) { layout in
            Text(layout.title).tag(layout.rawValue)
          }
        }
        .help("The main window's layout; the same as View › Layout. Program View is available only in Program mode.")
        Picker("New camera strips", selection: $stripDensity) {
          Text("Expanded").tag("expanded")
          Text("Collapsed").tag("collapsed")
        }
        .pickerStyle(.segmented)
        .help("How a newly added camera's strip starts. Collapse or expand any strip at any time (⌥⌘S collapses all).")
      } header: {
        Text("Window")
      } footer: {
        UISettingsFootnote("Hide any camera's picture from its menu or with ⇧⌘P. Hidden previews do no rendering work.")
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: 400)
    .onAppear { loginStatus = SMAppService.mainApp.status }
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

// MARK: - Recording

struct UISettingsRecordingPane: View {
  let model: AppModel
  @State private var showingRecovery = false

  var body: some View {
    let recording = model.recordingModel
    let codec = Binding(get: { recording.codec }, set: { recording.codec = $0 })
    let timecode = Binding(get: { recording.timecodeMode }, set: { recording.timecodeMode = $0 })
    let folder = recording.outputFolder
    let drive = UIRecordingLibrary.drives(for: [folder], recordingRates: [],
      fallbackMegabits: UIRecordingLibrary.nominalMegabits(codec: recording.codec, fast: true)).first
    Form {
      Section {
        LabeledContent("Default folder") {
          HStack {
            Text(folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "None")
              .lineLimit(1).truncationMode(.middle)
              .foregroundStyle(folder == nil ? .secondary : .primary)
              .textSelection(.enabled)
            Button(folder == nil ? "Choose…" : "Change…") { UIPanels.chooseFolder(model: model, cameraID: nil) }
            if let folder {
              Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { Image(systemName: "magnifyingglass") }
                .help("Show in Finder").accessibilityLabel("Show default folder in Finder")
              Button("Clear") { recording.outputFolder = nil }
            }
          }
        }
        if let drive {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(drive.name)
              Spacer()
              Text(driveSummary(drive)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            ProgressView(value: usedFraction(drive))
              .accessibilityLabel("\(drive.name) space used")
          }
        }
      } header: { Text("Destination") } footer: {
        UISettingsFootnote("Folder changes apply to the next take. Read/write access is remembered between launches.")
      }

      Section("Per-Camera Folders") {
        ForEach(model.feedDescriptors) { descriptor in
          LabeledContent(descriptor.name) {
            HStack {
              if let custom = recording.customOutputFolder(for: descriptor.id) {
                Text((custom.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                Button("Change…") { UIPanels.chooseFolder(model: model, cameraID: descriptor.id) }
                Button("Use Default Folder") { recording.setOutputFolder(nil, for: descriptor.id) }
              } else {
                Text("Default folder").foregroundStyle(.secondary)
                Button("Choose…") { UIPanels.chooseFolder(model: model, cameraID: descriptor.id) }
              }
            }
          }
        }
      }

      Section {
        Picker("Codec", selection: codec) {
          ForEach(RecordingCodec.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Timecode", selection: timecode) {
          ForEach(RecordingTimecodeMode.allCases, id: \.self) { Text(UITimecode.title($0)).tag($0) }
        }
        .help(recording.timecodeMode.help)
        LabeledContent("File names") {
          Text(fileNamePreview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
      } header: { Text("Format") } footer: {
        UISettingsFootnote("Records the camera original: 2160p 10-bit 4:2:2 with embedded audio. LUT and effects are not baked in. "
          + recording.timecodeMode.help)
      }

      Section {
        Toggle(isOn: .constant(false)) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Backup recording with camera apps")
            Text("Coming later").font(.caption).foregroundStyle(.secondary)
          }
        }
        .disabled(true)
      } header: { Text("Automation") } footer: {
        UISettingsFootnote("When available: a backup take starts after 10 seconds of continuous camera use, and only takes it started stop automatically when the last camera app closes.")
      }

      Section {
        LabeledContent("Interrupted takes") {
          HStack {
            Text(recording.interruptedRecordings.isEmpty ? "None found in saved folders"
              : "\(recording.interruptedRecordings.count) found").foregroundStyle(.secondary)
            Button("Recover Interrupted Takes…") { showingRecovery = true }
              .disabled(recording.interruptedRecordings.isEmpty)
          }
        }
        if let message = recording.recoveryMessage {
          Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      } header: { Text("Crash Recovery") } footer: {
        UISettingsFootnote("Takes are always written as fragmented QuickTime movies. The first fragment is written after 1 s, then every 10 s. Hidden .partial files and journals sit beside each take until it finishes. Recovery copies complete fragments into a separate _Recovered.mov without re-encoding and keeps the original.")
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: 700)
    .sheet(isPresented: $showingRecovery) { UISettingsRecoverySheet(model: model) }
    // Record › Recover Interrupted Takes… opens Settings and asks for this sheet.
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("UIShowRecovery"))) { _ in
      showingRecovery = true
    }
  }

  private var fileNamePreview: String {
    let name = model.feedDescriptors.first?.name ?? "Camera 1"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return "\(name)/\(name)_\(formatter.string(from: Date()))_001.mov"
  }

  private func usedFraction(_ drive: UIDrive) -> Double {
    guard drive.totalBytes > 0 else { return 0 }
    return min(1, max(0, 1 - Double(drive.availableBytes) / Double(drive.totalBytes)))
  }

  private func driveSummary(_ drive: UIDrive) -> String {
    var parts = ["\(UIFormat.bytes(drive.availableBytes)) free"]
    if let seconds = drive.secondsLeft { parts.append("about \(UIFormat.duration(seconds)) per camera") }
    return parts.joined(separator: " · ")
  }
}

private struct UISettingsRecoverySheet: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let recording = model.recordingModel
    VStack(alignment: .leading, spacing: 12) {
      Text("Interrupted Takes").font(.headline)
      if recording.interruptedRecordings.isEmpty {
        Text("No interrupted takes were found in the saved folders.").foregroundStyle(.secondary)
      }
      ForEach(recording.interruptedRecordings) { take in
        HStack {
          Text(take.title).lineLimit(1).truncationMode(.middle)
          Spacer()
          if recording.recoveringID == take.id { ProgressView().controlSize(.small) }
          Button("Recover") { recording.recover(take) }.disabled(recording.recoveringID != nil)
        }
      }
      if let url = recording.recoveredURL {
        Button("Show Recovered Movie in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
      HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }
    .padding(20)
    .frame(width: 460)
  }
}

// MARK: - Camera

struct UISettingsCameraPane: View {
  let model: AppModel
  /// The installer's status before any request; the footer shows only what a request reported since.
  private static let readyStatus = ExtensionInstallPreflight.current().readyStatus

  var body: some View {
    let installer = model.installer
    let outputMode = Binding(get: { model.outputMode }, set: { model.setOutputMode($0) })
    let needsApproval = installer.status.localizedCaseInsensitiveContains("approve")
    Form {
      Section {
        LabeledContent {
          HStack {
            if installer.pending { ProgressView().controlSize(.small) }
            Button(installer.system?.outdated == true ? "Update Camera Extension…" : "Install Camera Extension…") { installer.install() }
            Button("Remove Camera Extension…") { installer.uninstall() }
          }
          .disabled(!installer.canRequestChanges || installer.pending || model.running)
          .help(installHelp)
        } label: {
          Text("Ultracam camera")
          Text(extensionStatus(needsApproval: needsApproval))
        }
        if needsApproval {
          LabeledContent {
            Button("Open System Settings") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
              }
            }
          } label: {
            Label { Text("Needs approval") } icon: {
              Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            Text("System Settings › General › Login Items & Extensions › Camera Extensions")
          }
        }
      } header: { Text("Camera Extension") } footer: {
        UISettingsFootnote(extensionFooter(needsApproval: needsApproval))
      }

      Section {
        Picker("Output mode", selection: outputMode) {
          Text("Separate cameras").tag(FeedOutputMode.separateCameras)
          Text("Program").tag(FeedOutputMode.program)
        }
        .pickerStyle(.segmented)
        .disabled(!model.canEditFeedTopology)
        .help(model.canEditFeedTopology ? "Separate cameras publishes an Ultracam camera for each camera. Program publishes one switched camera, Ultracam · Program."
          : "Change while all cameras are stopped and nothing is recording.")
      } header: { Text("Output") } footer: {
        UISettingsFootnote(model.canEditFeedTopology ? "After changing the output mode, choose the new camera in your meeting app."
          : "Change while all cameras are stopped and nothing is recording. Then choose the new camera in your meeting app.")
      }

      Section("Published Cameras") {
        if model.outputMode == .program {
          LabeledContent("Ultracam · Program") { Text(model.programInUse ? "In use" : "Not in use").foregroundStyle(.secondary) }
        } else {
          ForEach(model.feedDescriptors.filter(\.enabled)) { descriptor in
            LabeledContent("Ultracam · \(descriptor.name)") {
              Text(model.cameraInUse(descriptor.id) ? "In use" : "Not in use").foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: 430)
  }

  /// A short state under "Ultracam camera"; the footer carries the long explanation.
  private func extensionStatus(needsApproval: Bool) -> String {
    let installer = model.installer
    if installer.unavailableReason != nil { return "Needs a signed build" }
    if installer.pending { return "Waiting for macOS…" }
    if needsApproval || (installer.system?.awaitingApproval == true && installer.system?.enabled == false) { return "Needs approval" }
    let published = UIExtensionDetector.isInstalled()
    if let system = installer.system, system.enabled {
      // Enabled but not started (after an update, until a restart): installing again wouldn't help.
      if system.outdated, let installed = system.enabledVersion, let bundled = system.bundledVersion {
        return "Version \(installed) installed · \(bundled) available"
      }
      return published ? "Installed" : "Restart your Mac to finish installing"
    }
    return published ? "Installed" : "Not installed"
  }

  private func extensionFooter(needsApproval: Bool) -> String {
    let installer = model.installer
    let general = "Installing and removing go through System Settings and are unavailable while a camera is running. Capture, preview and recording work without the extension."
    // The approval row already shows where to approve; the reason or last result otherwise leads.
    let detail = installer.unavailableReason
      ?? (needsApproval || installer.pending || installer.status == Self.readyStatus ? nil : installer.status)
    guard let detail else { return general }
    // Reasons and failures already end with "Capture and preview still work."
    return detail.localizedCaseInsensitiveContains("still work") ? detail : "\(detail) \(general)"
  }

  private var installHelp: String {
    if let reason = model.installer.unavailableReason { return reason }
    if model.installer.pending { return "A camera extension request is pending." }
    if model.running { return "Stop the cameras before installing or removing the camera extension." }
    return "Install or remove the Ultracam camera extension. This doesn't add or remove your cameras."
  }
}

// MARK: - Switcher

struct UISettingsSwitcherPane: View {
  let model: AppModel
  @State private var draft = NaturalTalkingHeadSettings()
  @State private var interval = 8.0
  @State private var loaded = false

  var body: some View {
    let strategy = Binding(get: { model.switcherSettings.strategy }, set: { value in
      var settings = model.switcherSettings
      settings.strategy = value
      settings.naturalTalkingHead.enabled = settings.automatic && value == .naturalTalkingHead
      model.updateSwitcher(settings)
    })
    let mode = Binding(get: { model.switcherSettings.naturalTalkingHead.mode }, set: { value in
      draft.mode = value
      commitDirector()
    })
    // Director mode, shot timing and cut decisions only drive Natural talking head;
    // they stay visible but disabled under the other strategies.
    let natural = model.switcherSettings.strategy == .naturalTalkingHead
    Form {
      Section {
        Picker("Automatic strategy", selection: strategy) {
          Text("Manual").tag(SwitcherStrategy.manual)
          Text("Fixed interval").tag(SwitcherStrategy.fixedInterval)
          Text("Natural talking head").tag(SwitcherStrategy.naturalTalkingHead)
          Text("Dynamic analysis (Coming later)").tag(SwitcherStrategy.dynamicAnalysis).disabled(true)
        }
        if model.switcherSettings.strategy == .fixedInterval {
          UISettingsSlider(title: "Fixed interval", value: $interval, range: 1...30, step: 0.5, unit: "s") { commitInterval() }
        }
        Picker("Director mode", selection: mode) {
          Text("Low latency").tag(TalkingHeadDirectorMode.lowLatency)
          Text("Transcript assisted").tag(TalkingHeadDirectorMode.transcriptAssisted)
        }
        .disabled(!natural)
      } header: { Text("Strategy") } footer: {
        UISettingsFootnote(natural
          ? "Transcript assisted needs an external transcript source; without one it cuts on audio alone. Low latency cuts on audio cues without waiting for a transcript."
          : "Director mode, shot timing and cut decisions are used by Natural talking head.")
      }

      Section {
        UISettingsShotTimeline(minimum: draft.minimumShotDuration, softMaximum: draft.softMaximumShotDuration,
          maximum: draft.maximumShotDuration, grace: draft.forcedCutGracePeriod)
        UISettingsSlider(title: "Minimum shot", value: $draft.minimumShotDuration, range: 10...60, step: 1, unit: "s") { commitDirector() }
        UISettingsSlider(title: "Soft maximum", value: $draft.softMaximumShotDuration, range: 10...120, step: 1, unit: "s") { commitDirector() }
        UISettingsSlider(title: "Maximum shot", value: $draft.maximumShotDuration, range: 10...180, step: 1, unit: "s") { commitDirector() }
        UISettingsSlider(title: "Cooldown", value: $draft.cooldown, range: 0...10, step: 0.5, unit: "s") { commitDirector() }
        UISettingsSlider(title: "Emphasis hold", value: $draft.emphasisHold, range: 0...30, step: 0.5, unit: "s") { commitDirector() }
        UISettingsSlider(title: "Forced-cut grace", value: $draft.forcedCutGracePeriod, range: 0...10, step: 0.5, unit: "s") { commitDirector() }
      } header: { Text("Shot Timing") } footer: {
        if !natural { UISettingsFootnote("Used by Natural talking head.") }
      }
      .disabled(!natural)

      Section {
        DisclosureGroup("Advanced cut decisions") {
          UISettingsSlider(title: "Cut threshold", value: floatBinding(\.cutThreshold), range: 0...1, step: 0.01, unit: "") { commitDirector() }
          UISettingsSlider(title: "Hysteresis margin", value: floatBinding(\.hysteresisMargin), range: 0...1, step: 0.01, unit: "") { commitDirector() }
          UISettingsSlider(title: "Transcript confidence", value: floatBinding(\.transcriptConfidenceThreshold), range: 0...1, step: 0.01, unit: "") { commitDirector() }
          UISettingsSlider(title: "Pause boundary", value: $draft.pauseBoundaryDuration, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
          UISettingsSlider(title: "Boundary window", value: $draft.boundaryWindow, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
          UISettingsSlider(title: "Candidate dwell", value: $draft.candidateDwell, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
          UISettingsSlider(title: "Forced boundary lookback", value: $draft.forcedBoundaryLookback, range: 0...5, step: 0.1, unit: "s") { commitDirector() }
          UISettingsSlider(title: "Transcript output delay", value: $draft.transcriptOutputDelay, range: 0...2, step: 0.01, unit: "s") { commitDirector() }
        }
        .disabled(!natural)
        // Restores the fixed interval too, so it stays available under every strategy.
        HStack {
          Spacer()
          Button("Restore Defaults") { restoreDefaults() }
        }
      } footer: {
        UISettingsFootnote("Decisions apply at Program frame boundaries. A timeline sidecar is written to the recording folder.")
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: 660)
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
    var defaults = NaturalTalkingHeadSettings()
    defaults.mode = draft.mode
    draft = defaults
    interval = 8
    commitDirector()
    commitInterval()
  }
}

/// A slider that reports its value live but commits only when editing ends.
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

// MARK: - Monitor

/// Monitor tools are set per camera on its picture; this pane only explains them.
struct UISettingsMonitorPane: View {
  var body: some View {
    Form {
      Section {
        Label("Each camera has its own guides, zebra, false color, focus peaking and scopes. Use the tool bar at the top right of its picture, or View › Monitor Tools.",
          systemImage: "waveform.path.ecg")
        Label("New cameras start with monitor tools off. Zebra starts at 95 IRE, and the picture shows the camera's output with its LUT.",
          systemImage: "plus.rectangle.on.rectangle")
        Label("Right-click a picture to copy its tools to another camera.", systemImage: "doc.on.doc")
        Label("Monitor tools never change camera output or recordings.", systemImage: "checkmark.shield")
      } header: { Text("Monitor Tools") } footer: {
        VStack(alignment: .leading, spacing: 6) {
          UISettingsFootnote("False color works when a camera's source is declared as Sony S-Log3. Declare what the camera actually sends: declarations don't calibrate the capture device or change camera output.")
          UISettingsFootnote("Every monitor shows every camera frame with its tools, on the GPU. Only a scope may skip an update while the GPU is still drawing earlier scopes. Hidden or covered monitors do no GPU work.")
        }
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: 360)
  }
}

// MARK: - Advanced

struct UISettingsAdvancedPane: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @State private var confirmForgetLUTs = false
  @State private var copied = false

  var body: some View {
    Form {
      Section {
        Toggle("Advertise HLG to cameras", isOn: $model.advertiseHDRToCameras)
          .help("Tells cameras on the UltraStudio HDMI inputs that HLG is welcome. SDR and PQ always are.")
      } header: { Text("Inputs") } footer: {
        UISettingsFootnote("SDR and PQ are always advertised. When on, cameras can also send HLG over HDMI instead of falling back to SDR. Changing this makes connected cameras renegotiate HDMI once, so their picture drops for a few seconds.")
      }

      Section {
        LabeledContent {
          HStack {
            Button("Open Diagnostics") { openWindow(id: "diagnostics") }
            Button(copied ? "Copied" : "Copy Diagnostics") {
              UIDiagnosticsText.copy(model: model)
              copied = true
            }
          }
        } label: {
          Text("Drops per stage, audio, encoder and monitoring details")
        }
      } header: { Text("Diagnostics") } footer: {
        UISettingsFootnote("Copy Diagnostics puts a plain-text summary on the clipboard for support. It has no image data.")
      }

      Section {
        LabeledContent {
          Button("Forget Saved LUTs…") { confirmForgetLUTs = true }
        } label: {
          Text("Saved LUT access")
          Text("Read-only bookmarks for each camera's .cube files, burn-in and monitor").font(.caption).foregroundStyle(.secondary)
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
          .disabled(!model.canEditFeedTopology)
          .help(model.canEditFeedTopology ? "Reset every saved preference and quit."
            : "Stop all cameras and let recordings finish before resetting.")
        } label: {
          Text("Reset all settings")
          Text(model.canEditFeedTopology ? "Cameras, effects, folders, monitor tools and layout"
            : "Stop all cameras and let recordings finish first").font(.caption).foregroundStyle(.secondary)
        }
      } header: { Text("Reset") } footer: {
        UISettingsFootnote("Recordings are never touched. Reset asks for confirmation, then Ultracam quits so it starts fresh next time.")
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: 520)
    // "Copied" confirms the copy briefly, then the button reads Copy Diagnostics again.
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
    .confirmationDialog("Forget saved LUTs?", isPresented: $confirmForgetLUTs) {
      Button("Forget Saved LUTs", role: .destructive) { forgetLUTs() }
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

// MARK: - Plain-text diagnostics

@MainActor
enum UIDiagnosticsText {
  static func summary(model: AppModel) -> String {
    var lines = ["Ultracam diagnostics", "Output mode: \(model.outputMode == .program ? "Program" : "Separate cameras")"]
    if model.outputMode == .program {
      lines.append("Program: \(model.programInUse ? "in use" : "not in use")")
    }
    for descriptor in model.feedDescriptors {
      lines.append("")
      lines.append("[\(descriptor.name)] \(model.isCameraRunning(descriptor.id) ? "running" : "stopped")")
      if let update = model.cameraUpdate(descriptor.id) {
        lines.append("Input: \(update.input)")
        lines.append("Output: \(update.output.isEmpty ? "—" : update.output)")
        lines.append(String(format: "Delivered: %.2f fps · processing %.2f ms · video %.2f Mb/s", update.outputFPS, update.processingMS, update.videoBitrateMbps))
        lines.append("Drops: source \(update.sourceDrops), buffers \(update.poolDrops), camera \(update.cameraDrops)")
        lines.append("Audio: \(update.audioPresent ? "\(update.audioChannels) ch \(update.audioSampleRate) Hz" : "none") · drops \(update.audioDrops)")
        lines.append("Message: \(update.message)")
        lines.append("Camera: \(update.cameraMessage)")
      }
      if let state = model.recordingModel.feeds.first(where: { $0.id == descriptor.id }) {
        lines.append("Recording: \(state.displayStatus)")
        if let stats = state.statistics {
          lines.append("Take: \(stats.elapsedText) · \(stats.sizeText) · dropped \(stats.droppedVideoFrames) · encoder errors \(stats.encoderErrors) · writer errors \(stats.writerErrors)")
          if let error = stats.lastError { lines.append("Last error: \(error)") }
        }
        if let error = state.error { lines.append("Error: \(error)") }
      }
    }
    return lines.joined(separator: "\n")
  }

  static func copy(model: AppModel) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(summary(model: model), forType: .string)
  }
}
