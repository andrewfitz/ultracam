import AppKit
import SwiftUI

/// The session panel: cameras (only when more than two), output, Program,
/// recording destinations, recent takes, interrupted takes and automation.
/// Rebuilds the context inside its own body so this column refreshes with the models.
struct UISessionSidebarView: View {
  let context: UIContext
  var body: some View { UISessionSidebarViewContent(context: context.current) }
}

struct UISessionSidebarViewContent: View {
  let context: UIContext

  private var session: UISessionSnapshot { context.session }
  private var presentation: UISessionPresentation { context.presentation }

  var body: some View {
    // Only the camera rows (shown with three or more cameras) are tagged, so only they select
    // through the list; other rows that name a camera are buttons that do the same.
    List(selection: selection) {
      if let banner = UIExtensionBanner.state(session.install) {
        Section { UIExtensionBannerView(state: banner, context: context) }
      }
      camerasSection
      outputSection
      recordingSection
      if !session.recentTakes.isEmpty { recentTakesSection }
      if !session.interruptedTakes.isEmpty || session.recoveryMessage != nil { interruptedSection }
      automationSection
    }
    .listStyle(.sidebar)
    .accessibilityLabel("Session")
  }

  private var selection: Binding<String?> {
    Binding(
      // The context is already the refreshed one (UISessionSidebarView builds it).
      get: { context.presentation.selected?.id },
      set: { if let id = $0 { inspect(id) } })
  }

  /// A click on a row that names a camera selects it and shows it in the inspector.
  /// (The bridge ignores selecting the camera that's already selected.)
  private func inspect(_ cameraID: String) {
    context.send(.select(cameraID: cameraID))
    context.send(.showInspector(cameraID: cameraID))
  }

  // MARK: Cameras

  private var camerasSection: some View {
    Section {
      if presentation.cameras.count > 2 {
        ForEach(presentation.cameras) { camera in
          HStack(spacing: 8) {
            Circle().fill(camera.statusTone == .positive ? Color.green : camera.statusTone.color.opacity(0.7))
              .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
              Text(camera.name).lineLimit(1).truncationMode(.middle)
              Text(camera.statusBadge).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let label = camera.tally.label {
              UIBadge(text: label, tone: camera.tally == .onAir ? .onAir : camera.tally == .next ? .positive : .neutral)
            }
          }
          .tag(camera.id)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(camera.accessibilityLabel)
          .accessibilityHint("Shows \(camera.name) in the inspector")
        }
      }
    } header: {
      HStack {
        Text("Cameras · \(presentation.cameras.count)")
        Spacer()
        Button { context.send(.addCamera) } label: { Image(systemName: "plus") }
          .buttonStyle(.borderless)
          .disabled(!session.canEditTopology)
          .help(session.canEditTopology ? "Add Camera" : "Stop all cameras and recordings to add a camera.")
          .accessibilityLabel("Add Camera")
      }
    }
  }

  // MARK: Output

  /// The output mode (Separate (ISO) or Program), the cameras it publishes and, in Program,
  /// the switching controls: Auto, its strategy, Hold and the shot timer. Cuts are in the toolbar.
  private var outputSection: some View {
    Section("Output") {
      UIOutputModeControlView(context: context)
      switch session.outputMode {
      case .program:
        UISidebarRow(symbol: "video.badge.checkmark", title: "Ultracam · Program",
          detail: session.programInUse ? "In use" : "Not in use", positive: session.programInUse)
          .help("One switched camera for meeting apps. Cut with the toolbar buttons or ⌃1–⌃\(min(4, max(1, presentation.cameras.count))).")
        Toggle("Auto switching", isOn: Binding(get: { presentation.autoSwitching }, set: { context.send(.setAutoSwitching($0)) }))
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(!presentation.canAutoSwitch)
          .help(presentation.canAutoSwitch ? "Cut automatically using the strategy below (⌃⌥A)."
            : "Choose a strategy below to switch automatically.")
        Picker("Strategy", selection: Binding(get: { session.strategy }, set: { context.send(.setStrategy($0)) })) {
          ForEach(UIOutputModeControl.strategies, id: \.self) { strategy in
            Text(UIStrategy.title(strategy)).tag(strategy)
          }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .help("How Auto chooses the next camera. Manual only cuts when you do.")
        if presentation.canHoldShot {
          Toggle("Hold current shot", isOn: Binding(get: { session.autoHold }, set: { context.send(.setAutoHold($0)) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Auto stays on but makes no cuts.")
        }
        if presentation.autoSwitching {
          UIShotTimerView(shot: session.shot, onAirName: presentation.cameras.first { $0.id == session.onAirID }?.name)
        }
      case .separate:
        // Each output is its camera: a click selects the camera and shows it in the inspector.
        ForEach(session.cameras) { camera in
          UISidebarRow(symbol: "video.badge.checkmark", title: "Ultracam · \(camera.name)",
            detail: camera.inUse ? "In use" : "Not in use", positive: camera.inUse)
            .uiSidebarInspectButton(cameraName: camera.name) { inspect(camera.id) }
            .selectionDisabled()
        }
      }
    }
  }

  // MARK: Recording

  private var recordingSection: some View {
    Section("Recording") {
      let active = session.cameras.filter { $0.recording.status == .recording || $0.recording.status == .paused }
      let paused = active.filter { $0.recording.status == .paused }.count
      HStack(spacing: 8) {
        Circle().fill(active.isEmpty ? Color.secondary.opacity(0.4) : .red).frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(active.isEmpty ? "Not recording" : paused > 0 ? "\(active.count - paused) recording · \(paused) paused" : "\(active.count) recording")
          Text("\(session.codecTitle) · \(session.timecodeTitle)").font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      ForEach(session.drives) { drive in UIDriveRow(drive: drive).selectionDisabled() }
      HStack(spacing: 8) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        // The folder's name, and where it is underneath: a whole path doesn't fit the sidebar.
        VStack(alignment: .leading, spacing: 1) {
          if let path = session.defaultFolderPath {
            Text(UIFormat.folderName(path)).lineLimit(1).truncationMode(.middle)
            Text(UIFormat.folderLocation(path)).font(.subheadline).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
          } else {
            Text("No folder").foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .combine)
        .help(session.defaultFolderPath ?? "Choose where recordings are saved.")
        Spacer(minLength: 4)
        Button(session.defaultFolderPath == nil ? "Choose…" : "Change…") { context.send(.chooseRecordingFolder(cameraID: nil)) }
          .controlSize(.small)
          .help("Choose the default recording folder. Changes apply to the next take.")
      }
    }
  }

  private var recentTakesSection: some View {
    Section("Recent Takes") {
      ForEach(session.recentTakes) { take in
        HStack(spacing: 8) {
          Image(systemName: "film").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(take.date.formatted(date: .abbreviated, time: .shortened)
              + (take.duration.map { " · \(UIFormat.shortElapsed($0))" } ?? ""))
              .lineLimit(1)
            Text(take.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 4)
          Button { context.send(.revealInFinder(take.url)) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(take.name) in Finder")
        }
        .help(take.url.path)
        .selectionDisabled()
      }
    }
  }

  private var interruptedSection: some View {
    Section("Interrupted Takes") {
      ForEach(session.interruptedTakes) { take in
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Text(take.title).lineLimit(1).truncationMode(.middle).help(take.title)
          Spacer(minLength: 4)
          if session.recoveringID == take.id {
            ProgressView().controlSize(.small).accessibilityLabel("Recovering")
          } else {
            Button("Recover") { context.send(.recover(id: take.id)) }
              .controlSize(.small)
              .disabled(session.recoveringID != nil)
              .help("Copy the complete fragments into a separate _Recovered.mov. The original is kept.")
          }
        }
        .selectionDisabled()
      }
      if let message = session.recoveryMessage {
        Text(message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Automation

  private var automationCamera: UICameraSnapshot? {
    let automatic = session.cameras.filter(\.automaticStart)
    let selected = session.cameras.first { $0.id == session.selectedID }
    if let selected, automatic.isEmpty || selected.automaticStart { return selected }
    return automatic.first ?? session.cameras.first
  }

  private var automationSection: some View {
    Section("Automation") {
      let automatic = session.cameras.filter(\.automaticStart).map(\.name)
      VStack(alignment: .leading, spacing: 1) {
        Text("Start with camera apps")
        Text(automatic.isEmpty ? "Off" : automatic.joined(separator: ", "))
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        // Sidebar rows are one line unless told otherwise, which cut this note off mid-word.
        if let status = session.cameras.first(where: { $0.id == session.selectedID })?.automaticStatus, !status.isEmpty {
          Text(status).font(.subheadline).foregroundStyle(.secondary)
            .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
        }
      }
      .accessibilityElement(children: .combine)
      .help("A camera starts when a meeting app opens its Ultracam camera and stops when the last app closes. Set it per camera in the inspector.")
      // The setting is per camera in the inspector: open the selected camera if it's one of
      // those named (or none is), otherwise the first one named.
      .modifier(UISidebarAutomationButton(camera: automationCamera, inspect: inspect))
      VStack(alignment: .leading, spacing: 1) {
        Text("Backup recording")
        Text("Coming later").font(.subheadline)
      }
      .foregroundStyle(.secondary)
      .help("Recording that starts with a meeting is designed but not built yet.")
      .accessibilityElement(children: .combine)
    }
  }
}

// MARK: - Pieces

extension View {
  /// Makes a whole sidebar row (its empty space too) one button that shows a camera in the inspector.
  func uiSidebarInspectButton(cameraName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show \(cameraName) in the inspector")
    .accessibilityHint("Shows \(cameraName) in the inspector")
  }
}

/// The Automation row opens its camera's inspector, where the setting lives.
private struct UISidebarAutomationButton: ViewModifier {
  let camera: UICameraSnapshot?
  let inspect: (String) -> Void
  func body(content: Content) -> some View {
    if let camera {
      content.uiSidebarInspectButton(cameraName: camera.name) { inspect(camera.id) }
    } else {
      content
    }
  }
}

struct UISidebarRow: View {
  let symbol: String
  let title: String
  let detail: String
  var positive = false
  var body: some View {
    HStack(spacing: 8) {
      // The tone is on the symbol; the words stay in label colors so they read in light mode.
      Image(systemName: symbol).foregroundStyle(positive ? Color.green : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1).truncationMode(.middle)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct UIDriveRow: View {
  let drive: UIDrive
  var body: some View {
    let used = drive.totalBytes > 0 ? 1 - Double(drive.availableBytes) / Double(drive.totalBytes) : 0
    let low = (drive.secondsLeft ?? .infinity) < 30 * 60 || UIPresentationBuilder.isFull(drive)
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: low ? "exclamationmark.triangle.fill" : "externaldrive").foregroundStyle(low ? Color.orange : .secondary)
        Text(drive.name).lineLimit(1)
        Spacer()
        Text(Self.freeText(drive))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(low ? .primary : .secondary)
      }
      ProgressView(value: min(1, max(0, used)))
        .progressViewStyle(.linear)
        .tint(low ? .orange : .secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Drive \(drive.name)")
    .accessibilityValue(drive.secondsLeft.map { "\(UIFormat.duration($0)) of recording left" } ?? Self.freeText(drive))
    .help(Self.unknown(drive) ? "Ultracam couldn't read this drive's free space."
      : "\(UIFormat.bytes(drive.availableBytes)) free. Time left is estimated from the bitrate of the takes recording to this drive.")
  }

  /// An unreadable volume reports no size at all; that is unknown, not a full drive.
  private static func unknown(_ drive: UIDrive) -> Bool { drive.totalBytes == 0 && drive.availableBytes == 0 }

  private static func freeText(_ drive: UIDrive) -> String {
    if let seconds = drive.secondsLeft { return "\(UIFormat.duration(seconds)) left" }
    return unknown(drive) ? "Free space unknown" : "\(UIFormat.bytes(drive.availableBytes)) free"
  }
}

/// Length of the current Program shot against the director's minimum, soft maximum and maximum.
struct UIShotTimerView: View {
  let shot: UIShotTiming
  let onAirName: String?
  /// When the current shot started, anchored when the snapshot was taken.
  private let anchor: Date?

  init(shot: UIShotTiming, onAirName: String?) {
    self.shot = shot
    self.onAirName = onAirName
    anchor = shot.currentShot.map { Date().addingTimeInterval(-$0) }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      bar(seconds: anchor.map { max(0, timeline.date.timeIntervalSince($0)) })
    }
  }

  private func bar(seconds: TimeInterval?) -> some View {
    let maximum = max(shot.maximum, 1)
    let fraction = min(1, (seconds ?? 0) / maximum)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("\(onAirName ?? "Program") · shot \(seconds.map { String(format: "%.0f s", $0) } ?? "—")")
        Spacer()
        Text("min \(Int(shot.minimum)) s")
      }
      .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(.fill.tertiary)
          Capsule().fill(LinearGradient(colors: [.green, .green, .yellow], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(2, width * fraction))
          ForEach([shot.minimum, shot.softMaximum], id: \.self) { mark in
            Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5, height: 12)
              .offset(x: width * min(1, mark / maximum) - 0.75)
          }
          // The maximum is a full-strength primary tick, as in Settings › Switcher; red means on air or recording.
          Rectangle().fill(Color.primary).frame(width: 1.5, height: 12).offset(x: width - 1.5)
        }
      }
      .frame(height: 6)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Shot timer")
    .accessibilityValue(seconds.map { String(format: "%.0f seconds; minimum %.0f, soft maximum %.0f, maximum %.0f",
      $0, shot.minimum, shot.softMaximum, shot.maximum) } ?? "No shot")
    .help("Minimum \(Int(shot.minimum)) s · soft maximum \(Int(shot.softMaximum)) s · maximum \(Int(shot.maximum)) s")
  }
}

// MARK: - Camera extension banner

enum UIExtensionBanner: Equatable {
  case unavailable(String)
  case pending(String)
  case needsApproval(String)
  case notInstalled
  /// macOS has the extension enabled but hasn't started it, so it has no cameras yet
  /// (after an update, until the Mac restarts). Installing again wouldn't help.
  case needsRestart
  /// The enabled extension is older than the one in this app.
  case outdated(installed: String, bundled: String)

  static let approvalText = "Approve Ultracam in System Settings › General › Login Items & Extensions › Camera Extensions."

  static func state(_ install: UIInstallState) -> UIExtensionBanner? {
    if install.needsApproval { return .needsApproval(install.status) }
    if install.pending { return .pending(install.status.isEmpty ? "Requesting camera activation…" : install.status) }
    if let reason = install.unavailableReason, !install.canRequestChanges { return .unavailable(reason) }
    if let system = install.system {
      if system.awaitingApproval && !system.enabled { return .needsApproval(approvalText) }
      if system.enabled {
        if system.outdated, install.canRequestChanges, let installed = system.enabledVersion, let bundled = system.bundledVersion {
          return .outdated(installed: installed, bundled: bundled)
        }
        return install.installed ? nil : .needsRestart
      }
    }
    if install.canRequestChanges && !install.installed { return .notInstalled }
    return nil
  }
}

struct UIExtensionBannerView: View {
  let state: UIExtensionBanner
  let context: UIContext

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch state {
      case .unavailable(let reason):
        // The reason already says what still works, so it isn't repeated here.
        Label("Camera needs a signed build", systemImage: "info.circle").font(.body.weight(.semibold)).lineLimit(2)
        Text(reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
      case .pending(let status):
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(status).lineLimit(3)
        }
      case .notInstalled:
        Label("Install the Ultracam camera", systemImage: "video.badge.plus").font(.body.weight(.semibold)).lineLimit(2)
        Text("Install the Ultracam camera to use it in your meeting app. macOS asks you to approve it in System Settings.")
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
        Button("Install Camera") { context.send(.installCameraExtension) }
          .controlSize(.small)
          .help("Request installation of the Ultracam camera extension.")
      case .needsRestart:
        Label("Finish installing the camera", systemImage: "arrow.clockwise.circle").font(.body.weight(.semibold)).lineLimit(2)
        Text("Restart your Mac to start the Ultracam camera.")
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
          .help("macOS has the camera extension enabled but hasn't started it yet, which usually happens after an update. Capture, preview and recording work meanwhile.")
      case .outdated(let installed, let bundled):
        Label("Update the Ultracam camera", systemImage: "arrow.down.circle").font(.body.weight(.semibold)).lineLimit(2)
        Text("Version \(installed) is installed; this app has \(bundled).")
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
        Button("Update Camera") { context.send(.installCameraExtension) }
          .controlSize(.small)
          .help("Replace the installed camera extension with this app's version. macOS may ask you to restart.")
      case .needsApproval(let status):
        Label {
          Text("Approve the Ultracam camera")
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.body.weight(.semibold)).lineLimit(2)
        Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
        Button("Open System Settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
          }
        }
        .controlSize(.small)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Output mode

/// When the output mode can change, and what to offer when it can't. The model's rule
/// (`canEditTopology`: no camera running or stopping, nothing recording, no LUT loading)
/// decides; this only says why and whether one click can clear the way safely.
enum UIOutputModeControl {
  enum Availability: Equatable {
    case available
    /// Only running cameras are in the way: nothing records and no meeting app shows Ultracam,
    /// so stopping them asks nothing and ends nothing.
    case stopCamerasFirst
    /// Something the user has to finish first; the text says what.
    case blocked(String)
  }

  /// The strategies the switching controls offer (Dynamic analysis isn't built yet).
  static let strategies: [SwitcherStrategy] = [.manual, .fixedInterval, .naturalTalkingHead]

  static func title(_ mode: UIOutputMode) -> String { mode == .program ? "Program" : "Separate (ISO)" }

  static func availability(_ session: UISessionSnapshot) -> Availability {
    if session.canEditTopology { return .available }
    if session.cameras.contains(where: { $0.recording.status != .idle }) {
      return .blocked("Stop recording, then stop the cameras, to change the output.")
    }
    let running = session.cameras.contains(where: \.running)
    let inUse = session.outputMode == .program ? session.programInUse : session.cameras.contains { $0.running && $0.inUse }
    if running && inUse { return .blocked("A meeting app is showing Ultracam. Stop the cameras to change the output.") }
    if running { return .stopCamerasFirst }
    return .blocked("Change the output once the cameras have stopped and the LUT has loaded.")
  }

  static func help(_ session: UISessionSnapshot) -> String {
    let modes = "Separate (ISO) publishes an Ultracam camera for each camera. Program publishes one switched camera, Ultracam · Program."
    switch availability(session) {
    case .available: return "\(modes) Choose the new camera in your meeting app after changing."
    case .stopCamerasFirst: return "Stop the cameras to change the output. \(modes)"
    case .blocked(let reason): return "\(reason) \(modes)"
    }
  }
}

/// Stops every camera, then changes the output once they have stopped. A stopping camera
/// holds the topology for a moment, so the two actions can't be sent back to back; this
/// waits (briefly) for the model to allow the change and gives up if a camera keeps running.
@MainActor @Observable final class UIOutputModeSwitch {
  static let shared = UIOutputModeSwitch()

  /// The mode being switched to while the cameras stop.
  private(set) var pending: UIOutputMode?
  @ObservationIgnored private var task: Task<Void, Never>?

  func stopCamerasAndSwitch(to mode: UIOutputMode, send: @escaping @MainActor (UIAction) -> Void,
    session: @escaping @MainActor () -> UISessionSnapshot, timeout: Duration = .seconds(8),
    stillRunningAfter: Duration = .seconds(2), poll: Duration = .milliseconds(100)) {
    // Only when nothing records and nothing is on air, so Stop asks no question.
    guard UIOutputModeControl.availability(session()) == .stopCamerasFirst else { return }
    task?.cancel()
    pending = mode
    send(.stopAllCameras)
    task = Task { @MainActor [weak self] in
      let clock = ContinuousClock()
      let start = clock.now
      while !Task.isCancelled, clock.now - start < timeout {
        let current = session()
        if current.outputMode == mode { break }
        if current.canEditTopology {
          send(.setOutputMode(mode))
          break
        }
        // The stop didn't happen (or a camera started again): don't switch later by surprise.
        if clock.now - start > stillRunningAfter, current.cameras.contains(where: \.running) { break }
        try? await Task.sleep(for: poll)
      }
      guard !Task.isCancelled else { return }
      self?.pending = nil
    }
  }
}

/// The Separate (ISO) / Program control, with the reason it's locked and, when that's
/// safe, one click that stops the cameras and switches.
struct UIOutputModeControlView: View {
  let context: UIContext

  var body: some View {
    let session = context.session
    let availability = UIOutputModeControl.availability(session)
    let pending = UIOutputModeSwitch.shared.pending
    let other: UIOutputMode = session.outputMode == .program ? .separate : .program
    VStack(alignment: .leading, spacing: 6) {
      Picker("Output", selection: Binding(get: { pending ?? session.outputMode },
        set: { if $0 != session.outputMode { context.send(.setOutputMode($0)) } })) {
        Text(UIOutputModeControl.title(.separate)).tag(UIOutputMode.separate)
        Text(UIOutputModeControl.title(.program)).tag(UIOutputMode.program)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(availability != .available)
      .help(UIOutputModeControl.help(session))
      switch availability {
      case .available:
        EmptyView()
      case .stopCamerasFirst:
        if pending != nil {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Stopping cameras…").font(.subheadline).foregroundStyle(.secondary)
          }
        } else {
          Text("Stop the cameras to change the output.")
            .font(.subheadline).foregroundStyle(.secondary)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
          Button("Stop Cameras and Switch") {
            let refreshed = context
            UIOutputModeSwitch.shared.stopCamerasAndSwitch(to: other, send: context.send,
              session: { refreshed.current.session })
          }
          .controlSize(.small)
          .help("Stop every camera, then switch to \(UIOutputModeControl.title(other)). Nothing is recording or on air.")
        }
      case .blocked(let reason):
        // Sidebar rows are one line unless told otherwise.
        Text(reason)
          .font(.subheadline).foregroundStyle(.secondary)
          .lineLimit(4).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 2)
  }
}
