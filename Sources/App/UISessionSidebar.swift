import AppKit
import SwiftUI

/// The session board: what is connected, what's going out, where it's saving and what's wrong,
/// in signal order. Attention pins above the list. Nothing about switching lives here:
/// Auto, Strategy, Anchor, Emphasis and Hold are in the toolbar, shot time in the status bar.
/// Rebuilds the context inside its own body so this column refreshes with the models.
struct UISessionSidebarView: View {
  let context: UIContext
  var body: some View {
    let _ = UIRenderProbe.count("UISessionSidebarView")
    UISessionSidebarViewContent(context: context.current)
  }
}

struct UISessionSidebarViewContent: View {
  let context: UIContext

  private var session: UISessionSnapshot { context.session }
  private var presentation: UISessionPresentation { context.presentation }

  var body: some View {
    let _ = UIRenderProbe.count("UISessionSidebarViewContent")
    List(selection: selection) {
      camerasSection
      virtualCamerasSection
      recordingSection
      if let take = session.recentTakes.first { takesSection(take) }
    }
    .listStyle(.sidebar)
    .accessibilityLabel("Session")
    // An inset, not a stack: the list scrolls under it and the column keeps its own sizing.
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        UIAttentionSection(context: context)
        if presentation.offersAlerts {
          UIAlertsPrompt(context: context).padding(.horizontal, 10).padding(.bottom, 8)
        }
      }
    }
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

  /// Only what the strip doesn't show: capture device and camera body. The tally is the
  /// picture's and the status bar's, and the signal badge owns format and dropouts.
  private var camerasSection: some View {
    Section {
      ForEach(presentation.cameras) { camera in
        UISidebarCameraRow(camera: camera, snapshot: context.snapshot(camera.id))
          .tag(camera.id)
          .accessibilityHint("Shows \(camera.name) in the inspector")
      }
    } header: {
      HStack {
        Text("Cameras")
        Spacer()
        Button { context.send(.addCamera) } label: {
          Image(systemName: UISymbol.add).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!session.canAddCamera)
        .help(UIPresentationBuilder.addCameraHelp(session))
        .accessibilityLabel("Add Camera")
      }
    }
  }

  // MARK: Virtual Cameras

  /// The one section that collapses, by hand only. Closed, its header keeps the count, so
  /// collapsing hides no state.
  private var virtualCamerasSection: some View {
    Section {
      if !session.virtualCamerasCollapsed {
        ForEach(presentation.virtualCameras) { row in
          if let cameraID = row.cameraID {
            UIVirtualCameraRow(row: row)
              .uiSidebarInspectButton(cameraName: row.name) { inspect(cameraID) }
              .selectionDisabled()
          } else {
            UIVirtualCameraRow(row: row)
              .help("One switched camera for meeting apps. Cut with the toolbar or ⌃1–⌃\(min(4, max(1, presentation.cameras.count))).")
              .selectionDisabled()
          }
        }
        if presentation.virtualCamerasInUse == 0 {
          Label { Text(Self.microphoneReminder).lineLimit(3) } icon: { Image(systemName: UISymbol.microphoneReminder) }
            .font(.uiMeta).foregroundStyle(.secondary)
            .selectionDisabled()
        }
      }
    } header: {
      Button { context.send(.setVirtualCamerasCollapsed(!session.virtualCamerasCollapsed)) } label: {
        HStack(spacing: 6) {
          Text("Virtual Cameras")
          Spacer(minLength: 4)
          if session.virtualCamerasCollapsed {
            Text("\(presentation.virtualCamerasInUse) of \(presentation.virtualCameras.count) in use").font(.uiMeta)
          }
          Image(systemName: session.virtualCamerasCollapsed ? UISymbol.expandStrip : UISymbol.collapseStrip).imageScale(.small)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(session.virtualCamerasCollapsed ? "Show the virtual cameras" : "Hide the virtual cameras")
      .accessibilityLabel(session.virtualCamerasCollapsed ? "Show Virtual Cameras" : "Hide Virtual Cameras")
      .accessibilityValue("\(presentation.virtualCamerasInUse) of \(presentation.virtualCameras.count) in use")
    }
  }

  static let microphoneReminder = "Video only — select your microphone in your meeting app."

  // MARK: Recording

  private var recordingSection: some View {
    Section("Recording") {
      UIFormatMenu(context: context)
        .selectionDisabled()
      HStack(spacing: 8) {
        Text("Camera original")
        // Timecode is set once per rig: the caption opens Settings › Recording.
        Button { context.send(.openSettingsTab(.recording)) } label: {
          Label { Text(session.timecodeTitle) } icon: { Image(systemName: UISymbol.timecode) }
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .help("Timecode is set in Settings › Recording. Click to open it.")
        .accessibilityLabel("Timecode \(session.timecodeTitle)")
        .accessibilityHint("Opens Settings › Recording")
      }
      .font(.uiMeta).foregroundStyle(.secondary)
      .help("Records the camera original, without LUT or effects. Timecode is set in Settings › Recording.")
      .selectionDisabled()
      ForEach(session.drives) { drive in
        UILiveDriveRow(drive: drive, cameras: UIPresentationBuilder.cameras(on: drive, in: session), context: context)
          .selectionDisabled()
      }
      if session.drives.isEmpty {
        Text("—").font(.uiRow).foregroundStyle(.secondary)
          .accessibilityLabel("No recording drive")
          .selectionDisabled()
      }
      destinationRow.selectionDisabled()
    }
  }

  /// A change applies to the next take, so during one the button says so.
  private var destinationRow: some View {
    HStack(spacing: 6) {
      Image(systemName: UISymbol.folder).foregroundStyle(.secondary).imageScale(.small)
        .accessibilityHidden(true)
      Text(session.defaultFolderPath.map(UIFormat.folderName) ?? "No folder")
        .font(.uiMeta).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle)
        .help(session.defaultFolderPath ?? "Choose where takes are saved.")
      Spacer(minLength: 4)
      if presentation.canPauseAll || session.defaultFolderPath != nil {
        Button(UIPresentationBuilder.folderAction(session)) { context.send(.chooseRecordingFolder(cameraID: nil)) }
          .controlSize(.small)
          .fixedSize()
          .help("Choose the default recording folder. Changes apply to the next take.")
      }
    }
  }

  // MARK: Takes

  /// The latest only, so Recording stays above the fold. Show All reveals the rest in Finder.
  private func takesSection(_ take: UITake) -> some View {
    Section("Takes") {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Image(systemName: UISymbol.take).foregroundStyle(.secondary).imageScale(.small).accessibilityHidden(true)
          Text("Last take").font(.uiMeta).foregroundStyle(.secondary)
          if let duration = take.duration { UIValue(parts: [UIValuePart(number: UIFormat.shortElapsed(duration))]) }
          Spacer(minLength: 4)
          Button("Show All") { context.send(.revealRecordings) }
            .controlSize(.small)
            .fixedSize()
            .disabled(!presentation.canRevealRecordings)
            .help("Show the takes in Finder")
        }
        HStack(spacing: 6) {
          Text(take.date, format: .dateTime.hour().minute())
          if let lost = take.lostFrames {
            Image(systemName: lost > 0 ? UISymbol.warning : UISymbol.saved)
              .imageScale(.small).foregroundStyle(lost > 0 ? Color.orange : .green)
              .accessibilityHidden(true)
            Text("\(lost) lost").foregroundStyle(lost > 0 ? .primary : .secondary)
          }
        }
        .font(.uiMeta).foregroundStyle(.secondary)
      }
      .help(take.url.path)
      .accessibilityElement(children: .combine)
      .selectionDisabled()
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

/// A camera's state, name and hardware: the capture device's nickname, then the camera body
/// when one is paired. A camera with no body draws one line, not an empty one.
struct UISidebarCameraRow: View {
  let camera: UICameraPresentation
  let snapshot: UICameraSnapshot?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      UIStateGlyph(state: camera.state).frame(width: 12)
      VStack(alignment: .leading, spacing: 1) {
        Text(camera.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
        HStack(spacing: 6) {
          Text(camera.inputName).lineLimit(1).truncationMode(.middle).help(camera.inputName)
          // The connector only when it isn't HDMI (ruling 23).
          if let connector = snapshot?.inputConnector { Text(connector).fixedSize() }
        }
        .font(.uiMeta).foregroundStyle(.secondary)
        if let body = snapshot?.body {
          HStack(spacing: 6) {
            Label { Text(body.name).lineLimit(1) } icon: { Image(systemName: UISymbol.cameraBody).imageScale(.small) }
            if !body.connected {
              // Wi-Fi only when degraded: a healthy link draws nothing.
              Image(systemName: UISymbol.wifi(connected: false)).imageScale(.small).foregroundStyle(.orange)
              Text("Disconnected").foregroundStyle(.primary).fixedSize()
            } else if let battery = body.battery {
              UIBatteryGlyph(battery: battery)
            }
          }
          .font(.uiMeta).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(camera.accessibilityLabel)
  }
}

/// One line: its state glyph, its name, and "In use" only when true.
struct UIVirtualCameraRow: View {
  let row: UIVirtualCamera

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: UISymbol.virtualCamera(inUse: row.inUse)).foregroundStyle(row.inUse ? Color.green : .secondary)
      Text(row.name).lineLimit(1).truncationMode(.middle)
        .foregroundStyle(row.inUse ? .primary : .secondary)
        .fontWeight(row.inUse ? .semibold : .regular)
      Spacer(minLength: 4)
      if row.inUse { Text("In use").font(.uiMeta).fixedSize() }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(row.name), \(row.clientLine)")
  }
}

/// The session's one format: the same menu in the left pane, the Record toolbar menu, the
/// Record app menu and the menu bar. Each row shows its rate and time left for the current
/// sources. It applies to the next take; each strip shows its own, read-only.
struct UIFormatMenu: View {
  let context: UIContext

  var body: some View {
    Menu {
      UIFormatChoices(session: context.session, send: context.send)
      Divider()
      Button("Timecode and Folders…") { context.send(.openSettingsTab(.recording)) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: UISymbol.format)
        Text(context.session.codec.title).lineLimit(1)
        Spacer(minLength: 0)
      }
    }
    .help("The format every camera records. Applies to the next take.")
    .accessibilityLabel("Recording format")
    .accessibilityValue(context.session.codec.title)
  }
}

/// A Format menu's rows.
struct UIFormatChoices: View {
  let session: UISessionSnapshot
  let send: @MainActor (UIAction) -> Void

  var body: some View {
    Section("Applies to the next take") {
      ForEach(UIPresentationBuilder.formatChoices(session)) { choice in
        Toggle(isOn: Binding(get: { choice.selected }, set: { _ in send(.setCodec(choice.codec)) })) {
          Text(choice.title)
        }
        .badge(Text(choice.reason ?? [choice.rate, choice.left].compactMap { $0 }.joined(separator: "   ")))
        .disabled(choice.reason != nil)
      }
    }
  }
}

/// Every interrupted take, one Recover each. Attention's row opens it.
struct UIInterruptedTakesSheet: View {
  let context: UIContext

  private var session: UISessionSnapshot { context.session }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Interrupted Takes").font(.uiTitle)
      if session.interruptedTakes.isEmpty {
        Text("No interrupted takes were found in the saved folders.").font(.uiRow).foregroundStyle(.secondary)
      }
      ForEach(session.interruptedTakes) { take in
        HStack(spacing: 8) {
          Image(systemName: UISymbol.take).foregroundStyle(.secondary).accessibilityHidden(true)
          Text(take.title).font(.uiRow).lineLimit(1).truncationMode(.middle).help(take.title)
          Spacer(minLength: 4)
          if session.recoveringID == take.id {
            ProgressView().controlSize(.small).accessibilityLabel("Recovering")
          } else {
            Button("Recover") { context.send(.recover(id: take.id)) }
              .controlSize(.small)
              .disabled(session.recoveringID != nil)
          }
        }
      }
      Text(session.recoveryMessage ?? "Recovery copies complete fragments into a separate _Recovered.mov without re-encoding and keeps the original.")
        .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      HStack {
        if let url = session.recoveredURL {
          Button("Show Recovered Movie in Finder") { context.send(.revealInFinder(url)) }
        }
        Spacer()
        Button("Done") { context.send(.hideInterruptedTakes) }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460, alignment: .leading)
  }
}

struct UIDriveRow: View {
  let drive: UIDrive
  /// The cameras that record here, as their numbers: names are in help.
  var cameras: [UICameraPresentation] = []

  var body: some View {
    let used = drive.totalBytes > 0 ? 1 - Double(drive.availableBytes) / Double(drive.totalBytes) : 0
    let low = UIPresentationBuilder.isLow(drive) || UIPresentationBuilder.isFull(drive)
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Image(systemName: UISymbol.drive(low: low)).imageScale(.small).foregroundStyle(low ? Color.orange : .secondary)
        Text(drive.name).font(.uiValueStrong).lineLimit(1)
        ForEach(cameras) { UINumberCapsule(number: $0.number) }
        Spacer(minLength: 4)
        if let seconds = drive.secondsLeft {
          UIValue(parts: UIFormat.durationParts(seconds))
          Text("left").font(.uiMeta).foregroundStyle(.secondary)
        } else {
          Text(Self.freeText(drive)).font(.uiMeta).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      UILevelBar(fraction: used, tint: low ? .orange : .secondary, width: nil)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Drive \(drive.name)")
    .accessibilityValue(drive.secondsLeft.map { "\(UIFormat.duration($0)) of recording left" } ?? Self.freeText(drive))
    .help(Self.help(drive, cameras: cameras))
  }

  private static func help(_ drive: UIDrive, cameras: [UICameraPresentation]) -> String {
    if unknown(drive) { return "Ultracam couldn't read this drive's free space." }
    let names = cameras.isEmpty ? "" : " \(cameras.map(\.name).joined(separator: ", ")) \(cameras.count == 1 ? "records" : "record") here."
    return "\(UIFormat.bytes(drive.availableBytes)) free. Time left is estimated from the bitrate of the takes recording to this drive.\(names)"
  }

  /// An unreadable volume reports no size at all; that is unknown, not a full drive.
  private static func unknown(_ drive: UIDrive) -> Bool { drive.totalBytes == 0 && drive.availableBytes == 0 }

  private static func freeText(_ drive: UIDrive) -> String {
    unknown(drive) ? "Free space unknown" : "\(UIFormat.bytes(drive.availableBytes)) free"
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
