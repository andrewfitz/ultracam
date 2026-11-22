import AppKit
import SwiftUI

// The session's shared rows. The left pane that used to draw them is gone: the pictures are
// the camera list, the status bar reports the session, and Record's popover sets up
// recording. What remains here is what those surfaces share: a virtual camera's row, the
// format menu, a drive's row, the Interrupted Takes sheet and the extension's setup state.

/// One line: its state glyph, its name, and "In use" only when true.
struct UIVirtualCameraRow: View {
  let row: UIVirtualCamera

  static let microphoneReminder = "Video only — select your microphone in your meeting app."

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

/// The session's one format: the same menu in Record's popover, the Record app menu and the
/// menu bar. Each row shows its rate and time left for the current sources. It applies to
/// the next take.
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

/// Every interrupted take, one Recover each. Record's popover and the Record menu open it.
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

// MARK: - Camera extension setup

enum UIExtensionBanner: Equatable {
  case unavailable(String)
  case pending(String)
  case needsApproval(String)
  case notInstalled
  /// macOS has enabled the extension but hasn't started its cameras yet.
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
