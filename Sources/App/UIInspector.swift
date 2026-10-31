import SwiftUI

/// On-demand inspector for the selected camera's deeper settings (D5).
/// Rebuilds the context inside its own body so this column refreshes with the models.
struct UIInspectorView: View {
  let context: UIContext
  var body: some View {
    let _ = UIRenderProbe.count("UIInspectorView")
    UIInspectorViewContent(context: context.current)
  }
}

struct UIInspectorViewContent: View {
  let context: UIContext


  var body: some View {
    let _ = UIRenderProbe.count("UIInspectorViewContent")
    if let camera = context.presentation.selected, let snapshot = context.snapshot(camera.id) {
      form(camera: camera, snapshot: snapshot)
    } else {
      ContentUnavailableView("No Camera Selected", systemImage: UISymbol.camera,
        description: Text("Select a camera to see its settings."))
    }
  }

  private func form(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Form {
      Section {
        header(camera: camera, snapshot: snapshot)
      }
      // Signal order: what comes in, what controls it, what's done to it, what's kept.
      inputSection(camera: camera, snapshot: snapshot)
      if let store = context.cameraControls {
        Section {
          if let assignment = store.assignment(for: camera.id) {
            let state = store.state(for: camera.id)
            HStack(spacing: 6) {
              Label(assignment.camera.name, systemImage: UISymbol.cameraBody)
              Spacer(minLength: 4)
              Label(state.connected ? "Connected" : "Disconnected", systemImage: UISymbol.wifi(connected: state.connected))
                .font(.uiMeta).foregroundStyle(state.connected ? .secondary : .primary)
                .symbolRenderingMode(.palette).tint(state.connected ? .secondary : .orange)
            }
            LabeledContent(state.cacheStatus) {
              UICameraControlButton(feedID: camera.id, name: camera.name, store: store, viewFactories: context.controlViewFactories)
            }
          } else {
            UICameraControlButton(feedID: camera.id, name: camera.name, store: store, viewFactories: context.controlViewFactories)
          }
        } header: {
          UIInspectorHeader(title: "Camera Control", symbol: UISymbol.cameraControl)
        }
      }
      lutSection(camera: camera, snapshot: snapshot)
      effectsSection(camera: camera, snapshot: snapshot)
      recordingSection(camera: camera, snapshot: snapshot)
      automationSection(camera: camera, snapshot: snapshot)
      Section {
        HStack {
          // The shared rename alert (uiRenameAlert) asks for the name.
          Button("Rename…") { context.send(.beginRename(cameraID: camera.id)) }
            .help("Rename this camera.")
          Spacer()
          // The bridge asks for confirmation before removing.
          Button("Remove Camera…", role: .destructive) { context.send(.removeCamera(cameraID: camera.id)) }
            .disabled(!camera.canRemove)
            .help(camera.removeHelp)
        }
      }
    }
    .formStyle(.grouped)
    // Even margins wide enough for the scroller, so it runs beside the sections and never over their controls.
    .contentMargins(.horizontal, 16, for: .scrollContent)
    // Like the app's other scroll views: no rubber band when everything fits.
    .scrollBounceBehavior(.basedOnSize)
  }

  /// The camera's name and state, in place of a "Camera" row. The Input picker
  /// and Signal row below say which device it uses and what arrives.
  private func header(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(camera.name).font(.uiTitle).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 4)
      UIBadge(text: camera.statusBadge, tone: camera.statusTone)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: Sections

  @ViewBuilder private func inputOptions(_ inputs: [UIInput], options: [UIInputOption], selectedID: String?) -> some View {
    ForEach(inputs) { input in
      if let option = options.first(where: { $0.id == input.id }) {
        Text(option.usedBy.map { "\(option.label) (used by \($0))" } ?? option.label)
          .lineLimit(1).truncationMode(.middle).tag(option.id)
          .disabled(!UIInputPicker.selectable(input, usedBy: option.usedBy, selectedID: selectedID))
      }
    }
  }

  private func inputSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      // Selected by ID: two units of one model share a name. An input another camera
      // has is shown but disabled; None frees this camera's input for another.
      let options = UIInputLabels.options(context.inputs.map { ($0.id, $0.name) }, cameras: context.session.cameras,
        for: camera.id)
      let missingID = snapshot.inputID.flatMap { id in options.contains { $0.id == id } ? nil : id }
      Picker("Device", selection: Binding(
        get: { snapshot.inputID ?? "" },
        set: { context.send(.setInput(cameraID: camera.id, deviceID: $0)) })) {
        Text("None").tag("")
        Divider()
        ForEach(UIInputPicker.groups(context.inputs)) { group in
          if let title = group.title {
            Section(title) { inputOptions(group.inputs, options: options, selectedID: snapshot.inputID) }
          } else { inputOptions(group.inputs, options: options, selectedID: snapshot.inputID) }
        }
        if let missingID { Text("\(snapshot.inputName ?? missingID) (disconnected)").tag(missingID) }
      }
      // One row: a long device name truncates instead of widening the inspector.
      .lineLimit(1)
      .disabled(snapshot.running)
      .help(snapshot.running ? "Stop the camera to change its input."
        : "Choose an input device. Shared inputs may serve more than one camera.")
      LabeledContent("Signal") {
        // The tone goes on the symbol; small orange text is hard to read in light mode.
        HStack(spacing: 4) {
          if camera.statusTone == .warning { UIStateGlyph(state: .warning) }
          Text(Self.signalText(snapshot)).lineLimit(1).fontWeight(.semibold)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Signal")
      .accessibilityValue(Self.signalText(snapshot))
      // Always present ("—" while stopped): a row that comes and goes with Start and Stop
      // moved everything below it under the pointer.
      LabeledContent("Timecode") {
        // Follows the camera's updates here, not in the inspector.
        UILiveCamera(camera: camera, context: context, follows: .capture) { live in
          Text(live.camera.timecode).monospacedDigit().textSelection(.enabled)
        }
      }
      Picker("Camera log", selection: Binding(get: { snapshot.sourceProfileID }, set: { context.send(.setSourceProfile(cameraID: camera.id, $0)) })) {
        Text("Not declared").tag("unspecified")
        colorSpaceOptions(selected: snapshot.sourceProfileID)
      }
      .help("Declares the captured signal for monitoring and capture. This does not declare either LUT edge.")
      if snapshot.sourceProfileID != "unspecified", !SourceColorSpaceCatalog.entries.contains(where: { $0.id == snapshot.sourceProfileID }) {
        Label { Text("This saved camera log is unavailable. Choose a supported one before processing.") } icon: { UIStateGlyph(state: .warning) }
          .font(.uiMeta)
      }
      Toggle("Video preview", isOn: Binding(get: { snapshot.previewEnabled },
        set: { context.send(.setPreviewEnabled(cameraID: camera.id, $0)) }))
        .help("Hidden previews do no rendering work. Camera output continues.")
    } header: {
      HStack {
        UIInspectorHeader(title: "Input", symbol: UISymbol.input)
        Spacer()
        Button { context.send(.refreshInputs) } label: {
          Image(systemName: UISymbol.retry).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Refresh capture devices")
        .accessibilityLabel("Refresh capture devices")
      }
    } footer: {
      if snapshot.running {
        Text("Stop the camera to change its input.").font(.uiMeta).foregroundStyle(.secondary)
      } else if let input = context.inputs.first(where: { $0.id == snapshot.inputID }),
        !input.supportedModes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // A device that reports nothing gets no row: the list goes here only when there is one.
        Text("Supported formats: \(input.supportedModes)").font(.uiMeta).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
    }
  }

  /// One row per effect, its checkbox and value merged, in pipeline order. The master
  /// switch heads the section. Sync cameras lives only here, and asks first.
  private func effectsSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Toggle(isOn: Binding(get: { context.session.syncCameras }, set: { context.send(.setSyncCameras($0)) })) {
        Text("Sync cameras")
        if context.session.syncCameras { Text("Editing all cameras") }
      }
      .help("Copies this camera's effects, LUT, monitor tools, source declarations and preview setting to every camera, then keeps edits in sync. Input devices and recording folders stay separate.")
      effectRow(camera, index: 0, title: "LUT", enabled: snapshot.lutName != nil) {
        Text(snapshot.lutName.map { ($0 as NSString).deletingPathExtension } ?? "None").foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      effectRow(camera, index: 1, title: "Output size") {
        HStack(spacing: 4) {
          Picker("Output size", selection: Binding(get: { snapshot.resizeTarget },
            set: { context.send(.setResizeTarget(cameraID: camera.id, $0)) })) {
            ForEach(ResizeTarget.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .labelsHidden().fixedSize()
          Picker("Aspect", selection: Binding(get: { snapshot.scalingMode },
            set: { context.send(.setScalingMode(cameraID: camera.id, $0)) })) {
            Text("Fit").tag(ProgramScalingMode.fit)
            Text("Crop").tag(ProgramScalingMode.crop)
          }
          .labelsHidden().fixedSize()
          .help("Fit or Crop keeps the source's aspect ratio.")
        }
      }
      effectRow(camera, index: 2, title: "Color format") {
        Picker("Color format", selection: Binding(get: { snapshot.colorTarget },
          set: { context.send(.setColorTarget(cameraID: camera.id, $0)) })) {
          ForEach(ColorTarget.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden().fixedSize()
      }
      effectRow(camera, index: 3, title: "Frame-rate cap") {
        Picker("Frame-rate cap", selection: Binding(get: { snapshot.frameRateTarget },
          set: { context.send(.setFrameRateTarget(cameraID: camera.id, $0)) })) {
          ForEach(FrameRateTarget.allCases, id: \.self) { Text($0.title + " fps").tag($0) }
        }
        .labelsHidden().fixedSize()
        .help("Never exceeds the detected source rate. Turn the cap off to keep source timing.")
      }
      Picker("Program color", selection: Binding(get: { snapshot.programColorSpaceID },
        set: { context.send(.setProgramColorSpace(cameraID: camera.id, $0)) })) {
        Text("Rec.709").tag("rec709-video")
        Text("Rec.2020 / PQ").tag("rec2020-pq-video")
        Text("Rec.2020 / HLG").tag("rec2020-hlg-video")
      }
      .help("The color space this camera sends on Program.")
    } header: {
      HStack {
        UIInspectorHeader(title: "Effects", symbol: snapshot.processing ? UISymbol.effects : UISymbol.effectsOff)
        Spacer()
        Toggle("Effects", isOn: Binding(get: { snapshot.processing }, set: { context.send(.setProcessing(cameraID: camera.id, $0)) }))
          .toggleStyle(.switch).labelsHidden().controlSize(.small)
          .help("Effects Off sends the camera original unchanged. Your effect choices stay saved. ⇧⌘B")
      }
    } footer: {
      Group {
        if camera.applying {
          Label("Updating output…", systemImage: UISymbol.updating)
        } else if !snapshot.processing {
          Text("Camera original goes out unchanged.")
        } else {
          Text(["Applied top to bottom.", snapshot.outputFormat.map { "Output \($0)." },
            snapshot.lutName == nil ? "Load a LUT above to turn it on." : nil].compactMap { $0 }.joined(separator: " "))
        }
      }
      .font(.uiMeta).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// An effect's checkbox and its value on one row; the value is off while its checkbox is.
  private func effectRow<Value: View>(_ camera: UICameraPresentation, index: Int, title: String, enabled: Bool = true,
    @ViewBuilder value: () -> Value) -> some View {
    let chip = camera.chips.indices.contains(index) ? camera.chips[index] : nil
    return LabeledContent {
      value().disabled(!(chip?.isOn ?? false) || !camera.processing)
    } label: {
      Toggle(title, isOn: Binding(get: { chip?.isOn ?? false }, set: { context.send(.setEffect(cameraID: camera.id, index: index, $0)) }))
        .toggleStyle(.checkbox)
        .disabled(!enabled || !camera.processing)
        .help(chip?.help ?? "")
    }
  }

  private func lutSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      // One row whatever the file name's length: the name gives way (truncating in the middle)
      // before the label or the button. LabeledContent would drop a long name onto a second line.
      HStack(spacing: 6) {
        Text("File").layoutPriority(2)
        Spacer(minLength: 8)
        if snapshot.lutLoading { ProgressView().controlSize(.small) }
        Text(snapshot.lutLoading ? "Loading…" : snapshot.lutName.map { ($0 as NSString).deletingPathExtension } ?? "None")
          .lineLimit(1).truncationMode(.middle).fontWeight(.semibold)
          .help(snapshot.lutName ?? "")
        Button(snapshot.lutName == nil ? "Load…" : "Change…") { context.send(.chooseLUT(cameraID: camera.id)) }
          .layoutPriority(2)
          .disabled(snapshot.lutLoading)
          .help("Choose a .cube LUT. Your selection is remembered between launches. ⌘O")
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("LUT file")
      if let error = snapshot.lutError {
        Label { Text(error) } icon: { UIStateGlyph(state: .warning) }
          .font(.uiMeta)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      Picker("Input space", selection: Binding(get: { snapshot.lutInputSpaceID }, set: { context.send(.setLUTInputSpace(cameraID: camera.id, $0)) })) {
        colorSpaceOptions(selected: snapshot.lutInputSpaceID)
      }
      Picker("Output space", selection: Binding(get: { snapshot.lutOutputSpaceID }, set: { context.send(.setLUTOutputSpace(cameraID: camera.id, $0)) })) {
        colorSpaceOptions(selected: snapshot.lutOutputSpaceID)
      }
      if snapshot.lutName != nil || snapshot.lutError != nil {
        HStack {
          Spacer()
          Button("Remove LUT") { context.send(.forgetLUT(cameraID: camera.id)) }
            .help("Stop applying a LUT to \(camera.name). The file on disk is kept.")
        }
      }
    } header: {
      UIInspectorHeader(title: "LUT", symbol: UISymbol.lut(on: camera.lutIsOn))
    } footer: {
      Text("Choose the spaces specified by the LUT author. LUT spaces are never inferred from its file name; legacy LUTs keep Rec.709 input and output.")
        .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private func colorSpaceOptions(selected: String) -> some View {
    if selected != "unspecified", !SourceColorSpaceCatalog.entries.contains(where: { $0.id == selected }) {
      Text("Unknown: \(selected)").tag(selected)
    }
    ForEach(SourceColorSpaceCatalog.entries) { Text($0.title).tag($0.id) }
  }

  private func recordingSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      if snapshot.showsRecordingConstantFrameRateCompatibility {
        Toggle("Constant frame rate (compatibility)", isOn: Binding(
          get: { snapshot.recordingConstantFrameRate },
          set: { context.send(.setRecordingConstantFrameRate(cameraID: camera.id, $0)) }))
          .help("Recording only, from the next take. Repeats or skips whole frames onto the source’s nominal rate. Capture, preview and monitoring keep the original source cadence.")
      }
      let folder = snapshot.recording
      LabeledContent {
        // With its own folder, Choose… also offers the way back to the default folder.
        if folder.folderIsCustom {
          Menu("Choose…") {
            Button("Use Default Folder") { context.send(.useDefaultFolder(cameraID: camera.id)) }
          } primaryAction: { context.send(.chooseRecordingFolder(cameraID: camera.id)) }
            .fixedSize()
            .help("Choose a recording folder for \(camera.name), or go back to the default folder. Applies to the next take.")
        } else {
          Button("Choose…") { context.send(.chooseRecordingFolder(cameraID: camera.id)) }
            .help("Choose a recording folder for \(camera.name). Applies to the next take.")
        }
      } label: {
        Text(folder.folderPath == nil ? "No folder chosen" : camera.folderLine).lineLimit(1).truncationMode(.middle)
        Text(folder.folderPath == nil ? "Choose a folder to record"
          : folder.folderIsCustom ? "This camera's folder" : "Default folder")
      }
      .help(folder.folderPath ?? "")
      UILiveCamera(camera: camera, context: context, follows: .take, refresh: 5) { live in
        if let seconds = live.snapshot?.recording.secondsLeft {
          LabeledContent("Time left") { UIValue(parts: UIFormat.durationParts(seconds)) }
        }
      }
    } header: {
      UIInspectorHeader(title: "Recording", symbol: UISymbol.record)
    } footer: {
      Text("Records the camera original with embedded audio: no LUT or effects.")
        .font(.uiMeta).foregroundStyle(.secondary)
    }
  }

  private func automationSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Toggle("Start with meeting apps", isOn: Binding(get: { snapshot.automaticStart },
        set: { context.send(.setAutomaticStart(cameraID: camera.id, $0)) }))
        .help("Starts when a meeting app opens this camera; stops when the last app closes.")
      if snapshot.automaticStartFailed {
        HStack {
          Label { Text("Couldn't start") } icon: { UIStateGlyph(state: .warning) }
          Spacer()
          Button("Retry") { context.send(.retryAutomaticStart(cameraID: camera.id)) }
            .help("Try starting the camera again.")
        }
      }
    } header: {
      UIInspectorHeader(title: "Automation", symbol: UISymbol.startWithApps)
    } footer: {
      if let status = snapshot.automaticStatus, !status.isEmpty {
        Text(status).font(.uiMeta).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
    }
  }

  static func signalText(_ snapshot: UICameraSnapshot) -> String {
    switch snapshot.signal {
    case .none: return snapshot.deviceAvailable ? "Camera stopped" : "Input disconnected"
    case .connecting: return "Starting…"
    case .live(let format): return [format, snapshot.sourcePixel].compactMap { $0 }.joined(separator: "  ")
    case .noSignal: return "No signal"
    case .unsupported(let mode): return mode
    case .deviceMissing: return "Input disconnected"
    }
  }
}

/// A section header with its noun's symbol: a long pane is scanned by its headers.
struct UIInspectorHeader: View {
  let title: String
  let symbol: String

  var body: some View {
    Label(title, systemImage: symbol)
  }
}
