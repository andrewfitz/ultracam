import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Recording: timecode, the burned-in LUT, where takes go and what they're called.
/// Format lives in the main window (Record's popover, Record menus), because it is chosen per session.
struct UISettingsRecordingPane: View {
  let model: AppModel
  var interface: UIInterfaceState = UIAppEnvironment.interface
  @State private var folderErrors: [String: String] = [:]
  @State private var confirmingRemoval: String?

  func recordWithCameraApps(for camera: FeedID) -> Binding<Bool> {
    Binding(get: { model.descriptor(for: camera)?.recordWithCameraApps ?? false }, set: { enabled in
      model.updateCamera(camera, shareProcessing: false) { $0.recordWithCameraApps = enabled }
    })
  }

  var body: some View {
    let recording = model.recordingModel
    let timecode = Binding(get: { recording.timecodeMode }, set: { recording.timecodeMode = $0 })
    let naming = Binding(get: { recording.naming }, set: { recording.naming = $0 })
    let burnInLUT = Binding(get: { recording.burnInLUT }, set: { recording.burnInLUT = $0 })
    let cameras = interface.ordered(model.feedDescriptors, id: \.id.rawValue)
    UISettingsPane {
      Section {
        Picker("Timecode", selection: timecode) {
          ForEach(RecordingTimecodeMode.allCases, id: \.self) { Text(UITimecode.title($0)).tag($0) }
        }
      } header: { Text("Timecode") } footer: {
        UISettingsFootnote(Self.firstSentence(recording.timecodeMode.help))
      }

      Section {
        Toggle(isOn: burnInLUT) {
          Text("Burn LUT into recordings")
          Text("Each camera records with the LUT it burns in, as Program shows it")
        }
      } header: { Text("LUT") } footer: {
        UISettingsFootnote(Self.burnInLUTHelp)
      }

      Section {
        ForEach(model.recordingApps.keys.sorted(), id: \.self) { id in
          appSettings(id: id, name: model.recordingApps[id] ?? id)
        }
        Button("Add App…") { chooseRecordingApp() }
      } header: { Text("Recording Triggers") } footer: {
        if let system = model.installer.system, !system.enabled || system.outdated {
          UISettingsFootnote("Install the current camera extension in Settings › Virtual Cameras to identify meeting apps.")
        } else {
          UISettingsFootnote("A selected app’s video preview can trigger recording. For web meetings, select the browser.")
        }
      }

      Section {
        ForEach(cameras) { camera in
          Toggle(camera.name, isOn: recordWithCameraApps(for: camera.id))
        }
      } header: { Text("Record with Meeting Apps") } footer: {
        UISettingsFootnote("Choose a camera folder below or a destination under Recording Triggers. Two seconds of use starts a take. Program records each enabled camera. Five seconds after the app stops using the camera, its take ends.")
      }

      Section {
        folderRow(number: nil, title: "Default folder", folder: recording.outputFolder, isDefault: true,
          rolling: recording.hasActiveRecordings, choose: { UIPanels.chooseFolder(model: model, cameraID: nil) },
          clear: { recording.outputFolder = nil })
        ForEach(Array(cameras.enumerated()), id: \.element.id) { index, descriptor in
          let custom = recording.customOutputFolder(for: descriptor.id)
          let rolling = recording.feeds.first { $0.id == descriptor.id }?.isActive == true
          folderRow(number: index + 1, title: descriptor.name, folder: custom, isDefault: false,
            rolling: rolling, choose: { UIPanels.chooseFolder(model: model, cameraID: descriptor.id) },
            clear: { recording.setOutputFolder(nil, for: descriptor.id) })
        }
      } header: { Text("Folders") } footer: {
        UISettingsFootnote("Changes apply to the next take. Read and write access is remembered between launches.")
      }

      Section {
        LabeledContent("Name pattern") {
          UISettingsNamePattern(naming: naming)
        }
        LabeledContent("Preview") {
          Text(Self.preview(naming: recording.naming, camera: cameras.first?.name ?? "Camera 1"))
            .font(.uiMeta.monospaced()).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
        }
        Toggle(isOn: naming.cameraSubfolders) {
          Text("Camera subfolders")
          Text("Each camera’s takes go in a folder with its name")
        }
      } header: { Text("File Names") } footer: {
        UISettingsFootnote("Every name ends with the take’s ID, so two takes never share a name.")
      }
    }
  }

  private func appSettings(id: String, name: String) -> some View {
    let profile = Binding(get: { model.recordingProfiles[id] ?? AppRecordingProfile() },
      set: { model.recordingProfiles[id] = $0 })
    let rate = profile.wrappedValue.videoMbps
    let sample = AppRecordingTake(appID: id, appName: name, profile: profile.wrappedValue)
    return DisclosureGroup(name) {
      UISettingsVideoQuality(rate: profile.videoMbps)
      Text("HEVC 4:2:0 MP4 · about \(String(format: "%.2f", (Double(rate) + 0.128) * 0.45)) GB/hour with stereo AAC")
        .font(.uiMeta).foregroundStyle(.secondary)
      LabeledContent("Save to") {
        Text(profile.wrappedValue.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Camera folder / \(name)")
          .lineLimit(1).truncationMode(.middle)
        Button("Choose…") {
          let panel = NSOpenPanel()
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          panel.canCreateDirectories = true
          guard panel.runModal() == .OK, let url = panel.url else { return }
          do {
            var next = profile.wrappedValue
            try next.chooseFolder(url)
            profile.wrappedValue = next
            folderErrors[id] = nil
          } catch { folderErrors[id] = "Could not save folder access for \(name): \(error.localizedDescription)" }
        }
        if profile.wrappedValue.hasCustomFolder {
          Button("Use Default Folder") {
            var next = profile.wrappedValue
            next.folderBookmark = nil
            next.folderPath = nil
            profile.wrappedValue = next
          }
        }
      }
      if let error = folderErrors[id] {
        Label { Text(error) } icon: { Image(systemName: UISymbol.warning).foregroundStyle(.orange) }
          .font(.uiMeta).fixedSize(horizontal: false, vertical: true)
      }
      TextField("Filename pattern", text: profile.pattern, prompt: Text(AppRecordingProfile.defaultPattern))
      Text("Available fields: {date} {time} {session} {app} {camera}").font(.uiMeta).foregroundStyle(.secondary)
      LabeledContent("Preview") { Text(sample.filename(camera: "Camera 1", session: "Meeting topic") + ".mp4").textSelection(.enabled) }
      if id == "us.zoom.xos" {
        Text("The session field uses \(name)’s meeting window title when available, otherwise a generic meeting name. Email addresses are removed.")
          .font(.uiMeta).foregroundStyle(.secondary)
        if !CGPreflightScreenCaptureAccess() {
          Button("Allow Meeting Window Titles…") { _ = CGRequestScreenCaptureAccess() }
            .help("macOS requires Screen Recording permission to read another app’s window title.")
        }
      }
      Button("Remove \(name)…") { confirmingRemoval = id }
        .confirmationDialog("Remove \(name) from Recording Triggers?",
          isPresented: Binding(get: { confirmingRemoval == id }, set: { if !$0 { confirmingRemoval = nil } }),
          titleVisibility: .visible) {
          Button("Remove", role: .destructive) {
            confirmingRemoval = nil
            model.recordingApps.removeValue(forKey: id)
          }
          Button("Cancel", role: .cancel) { confirmingRemoval = nil }.keyboardShortcut(.defaultAction)
        } message: {
          Text("Its quality, folder and file name settings are kept in case you add it again. Recordings on disk are kept.")
        }
    }
  }

  private func chooseRecordingApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.prompt = "Add App"
    guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
    model.recordingApps[id] = FileManager.default.displayName(atPath: url.path)
  }

  /// A folder: its path, one Choose or Change, and a menu with Show in Finder and Clear (or Use
  /// Default Folder). During a take the button says it sets the folder for the next take.
  private func folderRow(number: Int?, title: String, folder: URL?, isDefault: Bool, rolling: Bool,
    choose: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        Group {
          if let folder {
            Text((folder.path as NSString).abbreviatingWithTildeInPath).help(folder.path)
          } else {
            Text(isDefault ? "None" : "Default folder").foregroundStyle(.secondary)
          }
        }
        .lineLimit(1).truncationMode(.middle)
        Button(Self.folderAction(hasFolder: folder != nil, rolling: rolling), action: choose)
        Menu {
          if let folder {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
          }
          Button(isDefault ? "Clear" : "Use Default Folder", action: clear).disabled(folder == nil)
        } label: {
          Image(systemName: UISymbol.more)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More for this folder")
      }
    } label: {
      HStack(spacing: 6) {
        if let number { UINumberCapsule(number: number) }
        Text(title)
      }
    }
  }

  static let burnInLUTHelp = "Applies to the next take, which keeps the LUT it starts with. A camera with no LUT records unchanged. ProRes 4444 can’t burn a LUT in."

  /// `Choose…` with no folder, `Change…` when idle and `Folder for Next Take…` during a take,
  /// which keeps the folder it started in.
  static func folderAction(hasFolder: Bool, rolling: Bool) -> String {
    rolling ? "Folder for Next Take…" : hasFolder ? "Change…" : "Choose…"
  }

  /// The help's first sentence: the footnote says what the choice does, no more.
  static func firstSentence(_ text: String) -> String {
    guard let end = text.range(of: ". ") else { return text }
    return String(text[..<end.lowerBound]) + "."
  }

  /// What the next take of the first camera will be called.
  static func preview(naming: RecordingFileNaming, camera: String, date: Date = Date()) -> String {
    naming.relativePath(camera: NativeRecordingSessionDriver.safeComponent(camera), date: date, take: 1)
  }
}

/// The name's pieces as chips joined by "_", each with a menu to move or remove it, and Add for
/// the pieces it doesn't use.
struct UISettingsNamePattern: View {
  @Binding var naming: RecordingFileNaming

  var body: some View {
    let tokens = naming.tokens
    HStack(spacing: 4) {
      ForEach(Array(tokens.enumerated()), id: \.element) { index, token in
        if index > 0 { Text("_").foregroundStyle(.secondary) }
        Menu {
          Button("Move Left") { move(index, by: -1) }.disabled(index == 0)
          Button("Move Right") { move(index, by: 1) }.disabled(index == tokens.count - 1)
          Divider()
          Button("Remove") { naming.tokens.remove(at: index) }.disabled(tokens.count == 1)
        } label: {
          Text(token.title)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .font(.uiMeta.weight(.medium))
        .padding(.horizontal, 7).frame(height: 20)
        .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("\(token.title), piece \(index + 1) of \(tokens.count)")
      }
      let missing = RecordingFileNaming.Token.allCases.filter { !tokens.contains($0) }
      Menu {
        ForEach(missing, id: \.self) { token in
          Button(token.title) { naming.tokens.append(token) }
        }
      } label: {
        Label("Add", systemImage: UISymbol.add)
      }
      .fixedSize()
      .disabled(missing.isEmpty)
    }
  }

  private func move(_ index: Int, by offset: Int) {
    let target = index + offset
    guard naming.tokens.indices.contains(target) else { return }
    naming.tokens.swapAt(index, target)
  }
}

struct UISettingsVideoQuality: View {
  @Binding var rate: Int
  var streaming = false

  var body: some View {
    Picker("Video quality", selection: $rate) {
      Text(streaming ? "Low · 5 Mbps" : "Storage saver · 5 Mbps").tag(5)
      Text("Standard · 10 Mbps").tag(AppRecordingProfile.defaultVideoMbps)
      Text("High · 20 Mbps").tag(20)
      if ![5, AppRecordingProfile.defaultVideoMbps, 20].contains(rate) { Text("Custom · \(rate) Mbps").tag(rate) }
    }
    Stepper(streaming ? "Target bitrate · \(rate) Mbps" : "Variable bitrate target · \(rate) Mbps", value: $rate, in: 1...50)
  }
}
