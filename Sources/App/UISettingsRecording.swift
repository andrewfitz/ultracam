import AppKit
import SwiftUI

/// Settings › Recording: timecode, where takes go and what they're called. Format lives in the
/// main window (sidebar, Record menus), because it is chosen per session.
struct UISettingsRecordingPane: View {
  let model: AppModel
  var interface: UIInterfaceState = UIAppEnvironment.interface

  var body: some View {
    let recording = model.recordingModel
    let timecode = Binding(get: { recording.timecodeMode }, set: { recording.timecodeMode = $0 })
    let naming = Binding(get: { recording.naming }, set: { recording.naming = $0 })
    let cameras = interface.ordered(model.feedDescriptors, id: \.id.rawValue)
    UISettingsPane {
      Section {
        Picker("Timecode", selection: timecode) {
          ForEach(RecordingTimecodeMode.allCases, id: \.self) { Text(UITimecode.title($0)).tag($0) }
        }
      } footer: {
        UISettingsFootnote(Self.firstSentence(recording.timecodeMode.help))
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

  /// What the next take of the first camera will be called. The ID is an example: each take gets its own.
  static func preview(naming: RecordingFileNaming, camera: String, date: Date = Date()) -> String {
    naming.relativePath(camera: NativeRecordingSessionDriver.safeComponent(camera), date: date, take: 1,
      sessionID: UUID(uuidString: "9F2C41D0-5B7E-4E0A-8C3D-2A61F0B7C9E4")!)
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
