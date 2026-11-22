import SwiftUI

/// On-demand inspector for the selected camera's deeper settings (D5).
/// Uses the main window's current snapshot. Running telemetry updates its own rows.
struct UIInspectorView: View {
  let context: UIContext
  var body: some View {
    let _ = UIRenderProbe.count("UIInspectorView")
    UIInspectorViewContent(context: context)
  }
}

struct UIInspectorViewContent: View {
  let context: UIContext
  /// The camera whose live LUT is waiting on the Remove LUT confirmation. By ID, so a
  /// selection change while it's up can't move the removal to another camera.
  @State private var confirmingLUTRemoval: String?
  /// Which sections are open. Closed, a section is its header and one summary beside it, so
  /// the inspector reads as a line per section. Input starts open: it says what arrives, and
  /// it's where a camera gets fixed. Kept across launches.
  @AppStorage("ui.inspector.open.input") private var inputOpen = true
  @AppStorage("ui.inspector.open.control") private var controlOpen = false
  @AppStorage("ui.inspector.open.lut") private var lutOpen = false
  @AppStorage("ui.inspector.open.effects") private var effectsOpen = false
  @AppStorage("ui.inspector.open.recording") private var recordingOpen = false
  @AppStorage("ui.inspector.open.automation") private var automationOpen = false

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
        // What this pane edits: this camera, or with Sync on, every camera. It asks first.
        Toggle(isOn: Binding(get: { context.session.syncCameras },
          set: { context.send(.setSyncCameras($0, sourceID: camera.id)) })) {
          Text("Sync cameras")
          if context.session.syncCameras { Text("Editing all cameras") }
        }
        .help("Copies this camera's effects, LUT, monitor tools, source declarations and preview setting to every camera, then keeps edits in sync. Input devices and recording folders stay separate.")
      }
      // Signal order: what comes in, what controls it, what's done to it, what's kept. A build
      // without any camera-control SDK has no Camera Control: it reads as a normal build.
      let controls = context.cameraControls.flatMap { $0.available ? $0 : nil }
      let sections: [InspectorSection] = [.input] + (controls == nil ? [] : [.control]) + [.lut, .effects, .recording, .automation]
      ForEach(groups(sections), id: \.first) { group in
        if let only = group.first, group.count == 1, isOpen(only) {
          openSection(only, camera: camera, snapshot: snapshot, controls: controls)
        } else {
          Section {
            ForEach(group) { summaryRow($0, camera: camera, snapshot: snapshot, controls: controls) }
          }
        }
      }
      Section {
        // The camera itself. A strip has no menu for these: they aren't for the middle of a show.
        HStack {
          if camera.canStop {
            if snapshot.running {
              Button("Restart Camera") { context.send(.restartCamera(cameraID: camera.id)) }
                .help("Reopen \(camera.name)'s output. Capture and the take keep running.")
                .accessibilityLabel("Restart \(camera.name)")
            }
            // The bridge asks first while it's recording or on air.
            Button("Stop Capture") { context.send(.stopCamera(cameraID: camera.id)) }
              .help("Stop \(camera.name).")
              .accessibilityLabel("Stop \(camera.name)")
          } else {
            Button("Start Capture") { context.send(.startCamera(cameraID: camera.id)) }
              .disabled(!camera.canStart)
              .help(camera.canStart ? "Start capture from \(camera.inputName)."
                : snapshot.inputName == nil ? "Choose an input device first." : "Connect the camera's input first.")
              .accessibilityLabel("Start \(camera.name)")
          }
          Spacer()
        }
        HStack {
          // The shared rename alert (uiRenameAlert) asks for the name.
          Button("Rename…") { context.send(.beginRename(cameraID: camera.id)) }
            .help("Rename this camera.")
          Spacer()
          // The bridge asks for confirmation before removing.
          Button("Remove Camera…") { context.send(.removeCamera(cameraID: camera.id)) }
            .disabled(!camera.canRemove)
            .help(camera.removeHelp)
        }
      }
    }
    .formStyle(.grouped)
    // Even margins wide enough for the scroller, so it runs beside the sections and never over
    // their controls. A grouped form outside the system's inspector column insets its sections
    // 20 pt on its own; with this they sit 26 pt in, as they did in that column.
    .contentMargins(.horizontal, 6, for: .scrollContent)
    // Like the app's other scroll views: no rubber band when everything fits.
    .scrollBounceBehavior(.basedOnSize)
  }

  /// The camera's name and state, in place of a "Camera" row. The Input picker
  /// and Signal row below say which device it uses and what arrives, so while a
  /// signal is live the badge (which would only repeat its format) is left out.
  private func header(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(camera.name).font(.uiTitle).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 4)
      if !Self.signalIsLive(snapshot) {
        UIBadge(text: camera.statusBadge, tone: camera.statusTone)
      }
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: Sections

  /// The inspector's sections, in signal order: what comes in, what controls it, what's done
  /// to it, what's kept.
  private enum InspectorSection: String, Identifiable {
    case input, control, lut, effects, recording, automation
    var id: String { rawValue }

    var title: String {
      switch self {
      case .input: return "Input"
      case .control: return "Camera Control"
      case .lut: return "LUT"
      case .effects: return "Effects"
      case .recording: return "Recording"
      case .automation: return "Automation"
      }
    }

    var symbol: String {
      switch self {
      case .input: return UISymbol.input
      case .control: return UISymbol.cameraControl
      case .lut: return UISymbol.lut(on: true)
      case .effects: return UISymbol.effects
      case .recording: return UISymbol.record
      case .automation: return UISymbol.startWithApps
      }
    }
  }

  private func isOpen(_ section: InspectorSection) -> Bool {
    switch section {
    case .input: return inputOpen
    case .control: return controlOpen
    case .lut: return lutOpen
    case .effects: return effectsOpen
    case .recording: return recordingOpen
    case .automation: return automationOpen
    }
  }

  private func toggle(_ section: InspectorSection) {
    switch section {
    case .input: inputOpen.toggle()
    case .control: controlOpen.toggle()
    case .lut: lutOpen.toggle()
    case .effects: effectsOpen.toggle()
    case .recording: recordingOpen.toggle()
    case .automation: automationOpen.toggle()
    }
  }

  /// An open section is a box of its own; a run of closed ones shares a box, a line each.
  private func groups(_ sections: [InspectorSection]) -> [[InspectorSection]] {
    var groups: [[InspectorSection]] = []
    for section in sections {
      if !isOpen(section), let previous = groups.last?.last, !isOpen(previous) {
        groups[groups.count - 1].append(section)
      } else {
        groups.append([section])
      }
    }
    return groups
  }

  @ViewBuilder private func openSection(_ section: InspectorSection, camera: UICameraPresentation, snapshot: UICameraSnapshot,
    controls: CameraControlStore?) -> some View {
    switch section {
    case .input: inputSection(camera: camera, snapshot: snapshot)
    case .control: if let controls { controlSection(camera: camera, store: controls) }
    case .lut: lutSection(camera: camera, snapshot: snapshot)
    case .effects: effectsSection(camera: camera, snapshot: snapshot)
    case .recording: recordingSection(camera: camera, snapshot: snapshot)
    case .automation: automationSection(camera: camera, snapshot: snapshot)
    }
  }

  /// An open section's header: the chevron and title close it; then the control it carries.
  private func sectionHeader<Accessory: View>(_ section: InspectorSection, symbol: String? = nil,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
    HStack(spacing: 8) {
      Button { toggle(section) } label: {
        HStack(spacing: 6) {
          Image(systemName: UISymbol.collapseStrip).imageScale(.small).frame(width: 12).accessibilityHidden(true)
          UIInspectorHeader(title: section.title, symbol: symbol ?? section.symbol)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Hide \(section.title)")
      .accessibilityLabel(section.title)
      .accessibilityValue("Expanded")
      Spacer(minLength: 4)
      accessory()
    }
  }

  /// A closed section: its title, and what it holds in a line (typed pieces set apart by
  /// spacing, the last one primary). The whole row opens it.
  private func summaryRow(_ section: InspectorSection, camera: UICameraPresentation, snapshot: UICameraSnapshot,
    controls: CameraControlStore?) -> some View {
    let summary = summary(section, camera: camera, snapshot: snapshot, controls: controls)
    return Button { toggle(section) } label: {
      HStack(spacing: 8) {
        Image(systemName: UISymbol.expandStrip).imageScale(.small).foregroundStyle(.secondary)
          .frame(width: 12).accessibilityHidden(true)
        UIInspectorHeader(title: section.title, symbol: section == .lut ? UISymbol.lut(on: camera.lutIsOn)
          : section == .effects && !snapshot.processing ? UISymbol.effectsOff : section.symbol)
          .fixedSize()
        Spacer(minLength: 8)
        if summary.warns { UIStateGlyph(state: .warning) }
        ForEach(Array(summary.pieces.enumerated()), id: \.offset) { index, piece in
          Text(piece).font(.uiMeta).foregroundStyle(index == summary.pieces.count - 1 ? .primary : .secondary)
            .lineLimit(1).truncationMode(.middle)
            .layoutPriority(index == summary.pieces.count - 1 ? 1 : 0)
        }
      }
      .frame(minHeight: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show \(section.title)")
    .accessibilityLabel(section.title)
    .accessibilityValue((["Collapsed"] + summary.pieces).joined(separator: ", "))
  }

  /// What a closed section says in its line.
  private func summary(_ section: InspectorSection, camera: UICameraPresentation, snapshot: UICameraSnapshot,
    controls: CameraControlStore?) -> (pieces: [String], warns: Bool) {
    switch section {
    // One short piece where the title is long: at 280 pt a second piece only truncates both.
    case .input:
      if case .live(let format) = snapshot.signal, snapshot.running { return ([format], false) }
      return ([Self.signalText(snapshot)], camera.statusTone == .warning)
    case .control:
      guard let controls, controls.assignment(for: camera.id) != nil else { return (["Not paired"], false) }
      let state = controls.state(for: camera.id)
      return ([state.connected ? "Connected" : state.retrying ? "Reconnecting…" : "Disconnected"],
        !state.connected && !state.retrying)
    case .lut:
      if snapshot.lutLoading { return (["Loading…"], false) }
      guard let name = snapshot.lutName else { return (["None"], snapshot.lutError != nil) }
      return ([(name as NSString).deletingPathExtension, camera.lutIsOn ? "On" : "Off"], snapshot.lutError != nil)
    case .effects:
      return (snapshot.processing ? [snapshot.outputFormat.map { "Output \($0)" } ?? "On"] : ["Off"], false)
    case .recording:
      guard let path = snapshot.recording.folderPath else { return (["No folder chosen"], true) }
      return ([UIFormat.folderName(path)], false)
    case .automation:
      return ([snapshot.automaticStartFailed ? "Couldn't start" : snapshot.automaticStart ? "With meeting apps" : "Manual start"],
        snapshot.automaticStartFailed)
    }
  }

  /// The paired body: its link, the cached values' age, Reconnect and the Camera Control
  /// sheet, then what it sends over HDMI (the strip's signal badge used to list these).
  private func controlSection(camera: UICameraPresentation, store: CameraControlStore) -> some View {
    let assignment = store.assignment(for: camera.id)
    let state = store.state(for: camera.id)
    let link = state.connected ? "Connected" : state.retrying ? "Reconnecting…" : "Disconnected"
    return Section {
      if let assignment {
        HStack(spacing: 6) {
          Label(assignment.camera.name, systemImage: UISymbol.cameraBody)
          Spacer(minLength: 4)
          Label(link, systemImage: UISymbol.wifi(connected: state.connected))
            .font(.uiMeta).foregroundStyle(state.connected ? .secondary : .primary)
            .symbolRenderingMode(.palette).tint(state.connected ? .secondary : .orange)
        }
        LabeledContent(state.cacheStatus) {
          HStack(spacing: 6) {
            // Reconnect stays near the camera; it uses the saved sign-in.
            if !state.connected {
              Button("Reconnect") { context.send(.reconnectCameraBody(cameraID: camera.id)) }.disabled(state.busy)
            }
            UICameraControlButton(feedID: camera.id, name: camera.name, store: store, viewFactories: context.controlViewFactories,
              openHardware: { context.send(.openHardware(itemID: assignment.camera.id)) })
          }
        }
        UICameraOutputTimingRows(cameraID: camera.id, store: store)
      } else {
        LabeledContent("Pairing is in Settings") {
          Button("Open Hardware…") { context.send(.openHardware(itemID: nil)) }
        }
      }
    } header: {
      sectionHeader(.control)
    }
  }

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
      // The label above its menu: at the inspector's width a device name beside its label truncates.
      VStack(alignment: .leading, spacing: 4) {
      Text("Device")
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
      // One row: a long device name truncates instead of widening the inspector. Help names it in full.
      .labelsHidden()
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .disabled(snapshot.running)
      .help(Self.deviceHelp(snapshot))
      }
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
      .help(Self.signalDetail(snapshot) ?? "")
      // Explain input negotiation or refusal separately from the delivered format.
      if let detail = Self.signalDetail(snapshot) {
        Text(detail).font(.uiMeta).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      LabeledContent("Measured input rate") {
        UILiveCamera(snapshotFor: camera, context: context, follows: .capture) { snapshot in
          let fps = snapshot?.measuredInputFPS ?? 0
          Text(fps > 0 ? String(format: "%.2f fps", fps) : "—").monospacedDigit()
        }
      }
      // A plain stat like Timecode: always present, "—" while stopped, never a warning.
      LabeledContent("Dropped frames") {
        UILiveCamera(snapshotFor: camera, context: context, follows: .capture) { snapshot in
          Text(Self.droppedFramesText(snapshot)).monospacedDigit()
            .help(Self.droppedFramesHelp(snapshot))
        }
      }
      // Always present ("—" while stopped): a row that comes and goes with Start and Stop
      // moved everything below it under the pointer.
      LabeledContent("Timecode") {
        // Follows the camera's updates here, not in the inspector.
        UILiveCamera(snapshotFor: camera, context: context, follows: .capture) { snapshot in
          Text(snapshot.map { $0.timecode ?? "—" } ?? camera.timecode).monospacedDigit().textSelection(.enabled)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Camera log")
        Picker("Camera log", selection: Binding(get: { snapshot.sourceProfileID }, set: { context.send(.setSourceProfile(cameraID: camera.id, $0)) })) {
          Text("Not declared").tag("unspecified")
          colorSpaceOptions(selected: snapshot.sourceProfileID)
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
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
      sectionHeader(.input) {
        Button { context.send(.refreshInputs) } label: {
          Image(systemName: UISymbol.retry).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Refresh capture devices")
        .accessibilityLabel("Refresh capture devices")
      }
    } footer: {
      HStack {
        if snapshot.running { Text("Stop the camera to change its input.") }
        Spacer(minLength: 4)
        // Supported formats, connector and the device's name live on its Hardware row.
        if let inputID = snapshot.inputID {
          Button(snapshot.running ? "Hardware…" : "Supported formats and settings…") { context.send(.openHardware(itemID: inputID)) }
            .buttonStyle(.link)
            .help("Supported formats, the connector and this device's name, in Settings › Hardware.")
        }
      }
      .font(.uiMeta).foregroundStyle(.secondary)
    }
  }

  /// One row per effect, its checkbox and value merged, in pipeline order. The master
  /// switch heads the section, open or closed.
  private func effectsSection(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> some View {
    Section {
      // The file is named in the LUT section above, in full; here only whether there is one.
      effectRow(camera, index: 0, title: "LUT", enabled: snapshot.lutName != nil) {
        if snapshot.lutName == nil { Text("None").foregroundStyle(.secondary) }
      }
      effectRow(camera, index: 1, title: "Output size") {
        VStack(alignment: .trailing, spacing: 4) {
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
          if snapshot.showsAllowUpscale {
            Toggle("Allow upscaling", isOn: Binding(get: { snapshot.allowUpscale },
              set: { context.send(.setAllowUpscale(cameraID: camera.id, $0)) }))
              .toggleStyle(.checkbox)
              .help("Enlarge smaller pictures to fit the canvas. Otherwise, Fit pads them at native size.")
          }
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
        Picker("Frame-rate cap", selection: frameRateSelection(cameraID: camera.id, current: snapshot.frameRateTarget)) {
          ForEach(FrameRateTarget.allCases, id: \.self) { Text($0.title + " fps").tag($0) }
        }
        .labelsHidden().fixedSize()
        .help("Never exceeds the detected source rate. Turn the cap off to keep source timing.")
      }
    } header: {
      sectionHeader(.effects, symbol: snapshot.processing ? UISymbol.effects : UISymbol.effectsOff) {
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

  func frameRateSelection(cameraID: String, current: FrameRateTarget) -> Binding<FrameRateTarget> {
    Binding(get: { current }, set: { context.send(.setFrameRateTarget(cameraID: cameraID, $0)) })
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
      // The label and the button on one line, the file's name on its own full-width line under
      // them, wrapping: a long name is read whole instead of truncated at 320 pt.
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text("File")
          Spacer(minLength: 8)
          if snapshot.lutLoading { ProgressView().controlSize(.small) }
          Button(snapshot.lutName == nil ? "Load…" : "Change…") { context.send(.chooseLUT(cameraID: camera.id)) }
            .disabled(snapshot.lutLoading)
            .help("Choose a .cube LUT. Your selection is remembered between launches. ⌘O")
        }
        Text(snapshot.lutLoading ? "Loading…" : snapshot.lutName.map { ($0 as NSString).deletingPathExtension } ?? "None")
          .fontWeight(.semibold)
          .fixedSize(horizontal: false, vertical: true)
          .help(snapshot.lutName ?? "")
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("LUT file")
      if let error = snapshot.lutError {
        Label { Text(error) } icon: { UIStateGlyph(state: .warning) }
          .font(.uiMeta)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Input space")
        Picker("Input space", selection: Binding(get: { snapshot.lutInputSpaceID }, set: { context.send(.setLUTInputSpace(cameraID: camera.id, $0)) })) {
          colorSpaceOptions(selected: snapshot.lutInputSpaceID)
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Output space")
        Picker("Output space", selection: Binding(get: { snapshot.lutOutputSpaceID }, set: { context.send(.setLUTOutputSpace(cameraID: camera.id, $0)) })) {
          colorSpaceOptions(selected: snapshot.lutOutputSpaceID)
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if snapshot.lutName != nil || snapshot.lutError != nil {
        HStack {
          Spacer()
          // Asks first only while the LUT is in live use: on air, or burned into a take.
          Button(liveLUTCameras(camera, snapshot: snapshot).isEmpty ? "Remove LUT" : "Remove LUT…") {
            if !liveLUTCameras(camera, snapshot: snapshot).isEmpty {
              confirmingLUTRemoval = camera.id
            } else {
              context.send(.forgetLUT(cameraID: camera.id))
            }
          }
          .help("Stop applying a LUT to \(camera.name). The file on disk is kept.")
          .confirmationDialog("Remove the LUT from \(camera.name)?",
            isPresented: Binding(get: { confirmingLUTRemoval == camera.id }, set: { if !$0 { confirmingLUTRemoval = nil } }),
            titleVisibility: .visible) {
            Button("Remove LUT", role: .destructive) {
              confirmingLUTRemoval = nil
              context.send(.forgetLUT(cameraID: camera.id))
            }
            Button("Cancel", role: .cancel) { confirmingLUTRemoval = nil }.keyboardShortcut(.defaultAction)
          } message: {
            Text(lutRemovalMessage(camera: camera, snapshot: snapshot))
          }
        }
      }
    } header: {
      sectionHeader(.lut, symbol: UISymbol.lut(on: camera.lutIsOn))
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
      UILiveCamera(snapshotFor: camera, context: context, follows: .take, refresh: 5) { snapshot in
        if let seconds = snapshot?.recording.secondsLeft {
          LabeledContent("Time left") { UIValue(parts: UIFormat.durationParts(seconds)) }
        }
      }
    } header: {
      sectionHeader(.recording)
    } footer: {
      let audio = snapshot.captureAudio == .microphone ? " with the selected microphone when available" : " with embedded audio"
      Text(UIPresentationBuilder.recordsLUT(snapshot, in: context.session)
        ? "Records the camera original with its LUT burned in" + audio + "."
        : "Records the camera original" + audio + ". The take uses the original picture without live effects.")
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
      sectionHeader(.automation)
    } footer: {
      if let status = snapshot.automaticStatus, !status.isEmpty {
        Text(status).font(.uiMeta).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
    }
  }

  /// Video frames lost since Start, from any cause: "0", "14", or "—" while stopped.
  nonisolated static func droppedFramesText(_ snapshot: UICameraSnapshot?) -> String {
    snapshot?.droppedFrames.map { $0.formatted() } ?? "—"
  }

  nonisolated static func droppedFramesHelp(_ snapshot: UICameraSnapshot?) -> String {
    guard let snapshot, snapshot.droppedFrames != nil else { return "Video frames lost since Start, counted while the camera runs." }
    let dropouts = snapshot.signalDropouts
    let signal = dropouts == 0 ? "" : ", including the signal dropping \(dropouts == 1 ? "once" : "\(dropouts) times")"
    return "Video frames lost since Start, from any cause\(signal). Diagnostics lists each cause."
  }

  nonisolated static func signalText(_ snapshot: UICameraSnapshot) -> String {
    switch snapshot.signal {
    case .none: return snapshot.deviceAvailable ? "Capture stopped" : snapshot.inputName == nil ? "No input" : "Input disconnected"
    case .connecting: return "Starting…"
    case .live(let format): return [format, snapshot.sourcePixel].compactMap { $0 }.joined(separator: "  ")
    case .noSignal: return "No signal"
    // The backend's reason is a sentence; the row says what it is, and `signalDetail` why.
    case .unsupported: return "Unsupported format"
    case .deviceMissing: return "Input disconnected"
    }
  }

  /// The Device picker's help: the input's full name, which the picker may truncate, then what to do.
  nonisolated static func deviceHelp(_ snapshot: UICameraSnapshot) -> String {
    let action = snapshot.running ? "Stop the camera to change its input."
      : "Choose an input device. Shared inputs may serve more than one camera."
    guard snapshot.inputID != nil, let name = snapshot.inputName, !name.isEmpty else { return action }
    return "\(name). \(action)"
  }

  /// The backend's reason a format is unsupported, for the line under the Signal row.
  nonisolated static func signalDetail(_ snapshot: UICameraSnapshot) -> String? {
    if case .unsupported(let reason) = snapshot.signal, !reason.isEmpty { return reason }
    return snapshot.inputDriverWarning ?? snapshot.inputSignalDetail
  }

  /// A signal is arriving, so the Signal row already names its format.
  nonisolated static func signalIsLive(_ snapshot: UICameraSnapshot) -> Bool {
    guard snapshot.running, case .live = snapshot.signal else { return false }
    return true
  }

  /// The LUT is changing a picture someone is receiving: the LUT is on, and the camera is
  /// on air or ISO, or the LUT is burned into the take being recorded.
  static func lutInLiveUse(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> Bool {
    camera.lutIsOn && (camera.tally.isRed || burnsIntoTake(snapshot))
  }

  private static func burnsIntoTake(_ snapshot: UICameraSnapshot) -> Bool {
    (snapshot.recording.status == .recording || snapshot.recording.status == .paused) && snapshot.recording.takeBurnsInLUT
  }

  /// The cameras Remove LUT would change live: this one, or with Sync cameras on (which
  /// removes the LUT from every camera) each camera whose LUT is in live use.
  private func liveLUTCameras(_ camera: UICameraPresentation, snapshot: UICameraSnapshot)
    -> [(camera: UICameraPresentation, snapshot: UICameraSnapshot)] {
    let candidates = context.session.syncCameras ? context.presentation.cameras : [camera]
    return candidates.compactMap { candidate -> (camera: UICameraPresentation, snapshot: UICameraSnapshot)? in
      let found: UICameraSnapshot? = candidate.id == camera.id ? snapshot : context.snapshot(candidate.id)
      guard let current = found,
        Self.lutInLiveUse(camera: candidate, snapshot: current) else { return nil }
      return (camera: candidate, snapshot: current)
    }
  }

  private func lutRemovalMessage(camera: UICameraPresentation, snapshot: UICameraSnapshot) -> String {
    let lines = liveLUTCameras(camera, snapshot: snapshot).map { live -> String in
      let onAir = live.camera.tally.isRed
      let uses = [onAir ? "on air" : nil, Self.burnsIntoTake(live.snapshot) ? "burned into the recording" : nil]
        .compactMap { $0 }
      return "\(live.camera.name)'s LUT is \(uses.joined(separator: " and "))."
    }
    return (lines + ["The picture changes at once. The file on disk is kept."]).joined(separator: " ")
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
