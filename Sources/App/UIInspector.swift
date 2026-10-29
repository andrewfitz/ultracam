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
      ContentUnavailableView("No Camera Selected", systemImage: "video.slash",
        description: Text("Select a camera to see its settings."))
    }
  }

  private func form(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Form {
      Section {
        header(camera: camera, snapshot: snapshot)
      }
      sourceSection(camera: camera, snapshot: snapshot)
      if let store = context.cameraControls {
        Section("Camera Control") {
          UICameraControlButton(feedID: camera.id, name: camera.name, store: store, viewFactories: context.controlViewFactories)
          if let assignment = store.assignment(for: camera.id) {
            Text("\(assignment.camera.name) · \(store.state(for: camera.id).cacheStatus)")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      processingSection(camera: camera, snapshot: snapshot)
      lutSection(camera: camera, snapshot: snapshot)
      recordingSection(camera: camera, snapshot: snapshot)
      automationSection(camera: camera, snapshot: snapshot)
      Section {
        HStack {
          // The shared rename alert (uiRenameAlert) asks for the name.
          Button("Rename…") { context.send(.beginRename(cameraID: camera.id)) }
            .disabled(!context.session.canEditTopology)
            .help(context.session.canEditTopology ? "Rename this camera." : "Stop all cameras and recordings to rename.")
          Spacer()
          // The bridge asks for confirmation before removing.
          Button("Remove Camera…", role: .destructive) { context.send(.removeCamera(cameraID: camera.id)) }
            .disabled(!context.session.canEditTopology || context.presentation.cameras.count < 2)
            .help(!context.session.canEditTopology ? "Stop all cameras and recordings to remove a camera."
              : context.presentation.cameras.count < 2 ? "Ultracam needs at least one camera." : "Remove this camera and its settings.")
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
      Text(camera.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
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

  private func sourceSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      // Selected by ID: two units of one model share a name. An input another camera
      // has is shown but disabled; None frees this camera's input for another.
      let options = UIInputLabels.options(context.inputs.map { ($0.id, $0.name) }, cameras: context.session.cameras,
        for: camera.id)
      let missingID = snapshot.inputID.flatMap { id in options.contains { $0.id == id } ? nil : id }
      Picker("Input", selection: Binding(
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
      LabeledContent("Supported source formats") {
        Text(UIInputPicker.supportedModes(context.inputs.first { $0.id == snapshot.inputID }))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      LabeledContent("Signal") {
        // The tone goes on the symbol; small orange text is hard to read in light mode.
        HStack(spacing: 4) {
          if camera.statusTone == .warning {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          Text(signalText(snapshot)).lineLimit(1).foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Signal")
      .accessibilityValue(signalText(snapshot))
      // Always present ("—" while stopped): a row that comes and goes with Start and Stop
      // moved everything below it under the pointer.
      LabeledContent("Timecode") {
        // Follows the camera's updates here, not in the inspector.
        UILiveCamera(camera: camera, context: context, follows: .capture) { live in
          Text(live.camera.timecode).monospacedDigit().textSelection(.enabled)
        }
      }
      Toggle("Video preview", isOn: Binding(get: { snapshot.previewEnabled },
        set: { context.send(.setPreviewEnabled(cameraID: camera.id, $0)) }))
        .help("Hidden previews do no rendering work. Camera output continues.")
    } header: {
      HStack {
        Text("Source")
        Spacer()
        Button { context.send(.refreshInputs) } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .disabled(snapshot.running)
          .help("Refresh capture devices")
          .accessibilityLabel("Refresh capture devices")
      }
    }
  }

  private func processingSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Toggle("Sync cameras", isOn: Binding(get: { context.session.syncCameras },
        set: { context.send(.setSyncCameras($0)) }))
        .help("Copies this camera’s processing and monitor effects to enabled cameras, then keeps edits in sync. Input devices and recording folders stay separate.")
      Toggle("Processing", isOn: Binding(get: { snapshot.processing }, set: { context.send(.setProcessing(cameraID: camera.id, $0)) }))
        .help("Off is a complete bypass: original resolution, color, pixels and frame rate. Your effect choices stay saved. ⇧⌘B")
      ForEach(camera.chips) { chip in
        Toggle(isOn: Binding(get: { chip.isOn }, set: { context.send(.setEffect(cameraID: camera.id, index: chip.id, $0)) })) {
          HStack(spacing: 6) {
            Text("\(chip.id + 1)").monospacedDigit().foregroundStyle(.tertiary)
            Text(UIPresentationBuilder.effectLongTitles[chip.id]).lineLimit(1)
          }
        }
        .toggleStyle(.checkbox)
        .disabled(!chip.enabled || !snapshot.processing)
        .help(chip.help)
      }
      Picker("Output size", selection: Binding(get: { snapshot.resizeTarget },
        set: { context.send(.setResizeTarget(cameraID: camera.id, $0)) })) {
        ForEach(ResizeTarget.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Program color", selection: Binding(get: { snapshot.programColorSpaceID },
        set: { context.send(.setProgramColorSpace(cameraID: camera.id, $0)) })) {
        Text("Rec.709").tag("rec709-video")
        Text("Rec.2020 / PQ").tag("rec2020-pq-video")
        Text("Rec.2020 / HLG").tag("rec2020-hlg-video")
      }
      Picker("Aspect", selection: Binding(get: { snapshot.scalingMode },
        set: { context.send(.setScalingMode(cameraID: camera.id, $0)) })) {
        Text("Fit").tag(ProgramScalingMode.fit)
        Text("Crop").tag(ProgramScalingMode.crop)
      }
      Picker("Color format", selection: Binding(get: { snapshot.colorTarget },
        set: { context.send(.setColorTarget(cameraID: camera.id, $0)) })) {
        ForEach(ColorTarget.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Frame-rate cap", selection: Binding(get: { snapshot.frameRateTarget },
        set: { context.send(.setFrameRateTarget(cameraID: camera.id, $0)) })) {
        ForEach(FrameRateTarget.allCases, id: \.self) { Text($0.title + " fps").tag($0) }
      }
      Text("Source size chooses the nearest supported camera size; Fit or Crop preserves the source aspect ratio. Frame-rate caps never exceed the detected source rate; turn off the rate effect to preserve source timing.")
        .font(.caption).foregroundStyle(.secondary)
    } header: {
      Text("Effects")
    } footer: {
      Group {
        if camera.applying {
          Label("Updating output…", systemImage: "arrow.triangle.2.circlepath")
        } else if !snapshot.processing {
          Label { Text("Complete bypass: the camera original goes out unchanged.") } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
          }
        } else {
          VStack(alignment: .leading, spacing: 2) {
            if let output = snapshot.outputFormat { Text("Applied in order. Output \(output).") }
            if snapshot.lutName == nil { Text("Load a LUT below to use effect 1.") }
          }
        }
      }
      .font(.subheadline).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func lutSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section("LUT") {
      // Label and value like the Input gamut row below; the section header already says LUT.
      // One row whatever the file name's length: the name gives way (truncating in the middle)
      // before the label or the button. LabeledContent would drop a long name onto a second line.
      HStack(spacing: 6) {
        Text("File").layoutPriority(2)
        Spacer(minLength: 8)
        if snapshot.lutLoading { ProgressView().controlSize(.small) }
        Text(snapshot.lutLoading ? "Loading…" : snapshot.lutName.map { ($0 as NSString).deletingPathExtension } ?? "None")
          .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
          .help(snapshot.lutName ?? "")
        Button(snapshot.lutName == nil ? "Load…" : "Change…") { context.send(.chooseLUT(cameraID: camera.id)) }
          .layoutPriority(2)
          .disabled(snapshot.lutLoading)
          .help("Choose a .cube LUT. Your selection is remembered between launches. ⌘O")
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("LUT file")
      if let error = snapshot.lutError {
        Label { Text(error).foregroundStyle(.secondary) } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      Picker("Source profile", selection: Binding(get: { snapshot.sourceProfileID }, set: { context.send(.setSourceProfile(cameraID: camera.id, $0)) })) {
        Text("From source tags / unspecified").tag("unspecified")
        colorSpaceOptions(selected: snapshot.sourceProfileID)
      }
      .help("Declares the captured signal for monitoring and capture. This does not declare either LUT edge.")
      if snapshot.sourceProfileID != "unspecified", !SourceColorSpaceCatalog.entries.contains(where: { $0.id == snapshot.sourceProfileID }) {
        Text("This saved source profile is unavailable. Choose a supported declaration before processing.").font(.caption).foregroundStyle(.orange)
      }
      Picker("LUT input space", selection: Binding(get: { snapshot.lutInputSpaceID }, set: { context.send(.setLUTInputSpace(cameraID: camera.id, $0)) })) {
        colorSpaceOptions(selected: snapshot.lutInputSpaceID)
      }
      Picker("LUT output space", selection: Binding(get: { snapshot.lutOutputSpaceID }, set: { context.send(.setLUTOutputSpace(cameraID: camera.id, $0)) })) {
        colorSpaceOptions(selected: snapshot.lutOutputSpaceID)
      }
      Text("Choose the spaces specified by the LUT author. LUT spaces are never inferred from its file name; legacy LUTs keep Rec.709 input and output.").font(.caption).foregroundStyle(.secondary)

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
        if let left = live.camera.timeLeftLine { LabeledContent("Time left", value: left) }
      }
    } header: {
      Text("Recording")
    } footer: {
      Text("Records the camera original with embedded audio: no LUT or effects.")
        .font(.subheadline).foregroundStyle(.secondary)
    }
  }

  private func automationSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      Toggle("Start with camera apps", isOn: Binding(get: { snapshot.automaticStart },
        set: { context.send(.setAutomaticStart(cameraID: camera.id, $0)) }))
        .help("Starts when a meeting app opens this camera; stops when the last app closes.")
      if snapshot.automaticStartFailed {
        HStack {
          Label { Text("Couldn't start") } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          Spacer()
          Button("Retry") { context.send(.retryAutomaticStart(cameraID: camera.id)) }
            .help("Try starting the camera again.")
        }
      }
    } header: {
      Text("Automation")
    } footer: {
      if let status = snapshot.automaticStatus, !status.isEmpty {
        Text(status).font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
    }
  }

  private func signalText(_ snapshot: UICameraSnapshot) -> String {
    switch snapshot.signal {
    case .none: return snapshot.deviceAvailable ? "Camera stopped" : "Input missing"
    case .connecting: return "Starting…"
    case .live(let format): return "\(format) · 4:2:2"
    case .noSignal: return "No signal"
    case .unsupported(let mode): return mode
    case .deviceMissing: return "Input disconnected"
    }
  }
}
