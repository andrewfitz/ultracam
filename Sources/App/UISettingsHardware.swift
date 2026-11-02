import SwiftUI

/// Settings › Hardware: every capture device and camera body, one section per vendor in
/// registry order, each an expanding row with its health, name, camera, state and link.
/// Absent hardware a camera is assigned to stays listed by its last known name, with its
/// plugin's hint. Pairing lives here: a body's camera pop-up pairs it, sign-in opens in its
/// row, and Find Camera Bodies scans only when pressed. Vendor words come from the plugins.
struct UISettingsHardwarePane: View {
  let model: AppModel
  var interface: UIInterfaceState = UIAppEnvironment.interface
  /// Rows open when the pane appears, besides any `openHardware` link asks for.
  var initiallyExpanded: Set<String> = []
  @State private var expanded: Set<String> = []
  /// Bodies being paired: body ID → the camera chosen in its pop-up.
  @State private var pairing: [String: String] = [:]
  /// Control vendors whose Add by Address form is open.
  @State private var addingByAddress: Set<String> = []
  @State private var controlSheet: ControlSheet?
  /// The one confirmation the pane shows (Advertise HDR while its camera runs).
  @State private var confirmation: UIDeviceSettingConfirmation?
  private struct ControlSheet: Identifiable { var id: String; var name: String }

  var body: some View {
    let groups = UISettingsHardwareGroups(model: model)
    UISettingsPane {
      if let warning = model.driverWarning, !groups.capture.contains(where: { Self.driverProblem($0.driver) != nil }) {
        Section {
          Label { Text(warning).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: UISymbol.warning).foregroundStyle(.orange)
          }
        }
      }
      ForEach(groups.capture, id: \.vendor.id) { group in captureSection(group) }
      if groups.capture.isEmpty {
        Section("Capture Devices") {
          Text("Connect a capture device to see it here.").foregroundStyle(.secondary)
        }
      }
      ForEach(groups.bodies, id: \.vendor.id) { group in bodySection(group, groups: groups) }
      ForEach([model.vendorSettings.persistenceMessage, model.cameraControls.discoveryMessages["persistence"]].compactMap { $0 }, id: \.self) { message in
        Section { Label(message, systemImage: UISymbol.warning).foregroundStyle(.orange) }
      }
    }
    .uiWatchesHardware(model.hardwareInventory)
    .onAppear {
      expanded.formUnion(initiallyExpanded)
      takeFocus()
    }
    .onChange(of: interface.hardwareFocus) { _, _ in takeFocus() }
    .sheet(item: $controlSheet) { sheet in
      UICameraControlSettings(feedID: sheet.id, name: sheet.name, store: model.cameraControls, viewFactories: model.controlViewFactories)
    }
    .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
      if let confirmation {
        Button(confirmation.actionTitle) { confirmation.action(); self.confirmation = nil }
      }
      Button("Cancel", role: .cancel) { confirmation = nil }.keyboardShortcut(.defaultAction)
    } message: {
      Text(confirmation?.message ?? "")
    }
  }

  private func takeFocus() {
    guard let focus = interface.hardwareFocus else { return }
    expanded.insert(focus)
    interface.hardwareFocus = nil
  }

  private func isExpanded(_ id: String) -> Binding<Bool> {
    Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
  }

  static func driverProblem(_ driver: DriverStatus?) -> String? {
    guard let driver, !driver.installed || !driver.supported else { return nil }
    return driver.reason ?? "The driver is unavailable."
  }

  // MARK: Capture devices

  private func captureSection(_ group: UISettingsHardwareGroups.Capture) -> some View {
    Section {
      if let problem = Self.driverProblem(group.driver) {
        Label { Text(problem).fixedSize(horizontal: false, vertical: true) } icon: {
          Image(systemName: UISymbol.warning).foregroundStyle(.orange)
        }
      }
      if group.devices.isEmpty {
        Text("No devices connected").foregroundStyle(.secondary)
      }
      ForEach(group.devices) { device in
        UIHardwareDisclosure(isExpanded: isExpanded(device.id), name: device.name) {
          deviceRow(device)
        } content: {
          deviceDetails(device)
        }
      }
    } header: {
      UISettingsHardwareHeader(title: group.vendor.localizedDisplayName(), trailing: group.driver?.title)
    }
  }

  private func deviceRow(_ device: UIHardwareDevice) -> some View {
    HStack(alignment: .center, spacing: 8) {
      UIHardwareHealthGlyph(health: device.health)
      Image(systemName: UISymbol.input).foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(device.name).font(.uiRowEmphasis).lineLimit(1).truncationMode(.middle)
        if !device.present {
          Text("Not connected").font(.uiMeta).foregroundStyle(.secondary)
          if let hint = device.hint {
            Text(hint).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        } else if let problem = device.status?.problems.first {
          Text([problem.localizedTitle(), problem.localizedDetail()].compactMap { $0 }.joined(separator: ". "))
            .font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if !device.summary.isEmpty {
          HStack(spacing: 6) {
            ForEach(Array(device.summary.enumerated()), id: \.offset) { index, piece in
              // The link is the last piece and plain; connector and signal are chips.
              if index == device.summary.count - 1, device.status.flatMap({ UIHardwareText.link($0.link) }) == piece {
                Text(piece).font(.uiMeta).foregroundStyle(.secondary)
              } else { UIHardwareChip(text: piece) }
            }
          }
        }
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      devicePicker(device)
    }
    .accessibilityElement(children: .contain)
  }

  /// The camera that uses the device. A running camera can't change its input.
  private func devicePicker(_ device: UIHardwareDevice) -> some View {
    let running = Set(model.feedDescriptors.filter { model.isCameraRunning($0.id) }.map(\.id.rawValue))
    return Picker("Camera", selection: Binding(get: { device.cameras.first?.id ?? "" }, set: { assign(device, to: $0) })) {
      Text("None").tag("")
      Divider()
      ForEach(model.feedDescriptors) { descriptor in
        Text(descriptor.name).tag(descriptor.id.rawValue).selectionDisabled(running.contains(descriptor.id.rawValue))
      }
    }
    .labelsHidden().fixedSize()
    .disabled(!device.runningCameras.isEmpty)
    .help(device.runningCameras.isEmpty ? "The camera that captures from \(device.name)"
      : "Stop \(UISettingsDeviceSettings.names(device.runningCameras)) to change its input.")
    .accessibilityLabel("Camera for \(device.name)")
  }

  private func assign(_ device: UIHardwareDevice, to cameraID: String) {
    guard device.cameras.first?.id != cameraID else { return }
    let bridge = UISessionBridge.live(model: model, interface: interface)
    // One camera per exclusive device: the previous camera lets go first.
    for camera in device.cameras { bridge.perform(.setInput(cameraID: camera.id, deviceID: "")) }
    if !cameraID.isEmpty { bridge.perform(.setInput(cameraID: cameraID, deviceID: device.id)) }
  }

  @ViewBuilder private func deviceDetails(_ device: UIHardwareDevice) -> some View {
    UIHardwareNicknameField(inventory: model.hardwareInventory, deviceID: device.id,
      placeholder: device.driverName ?? device.name)
    if let model = device.model {
      LabeledContent("Model") { Text(model).textSelection(.enabled) }
    }
    let facts = (device.status?.facts ?? []).filter { $0.id != "model" }.sorted { $0.group < $1.group }
    ForEach(facts.filter { $0.group <= .connection }) { fact in factRow(fact) }
    if device.present { UISettingsDeviceSettings(model: model, device: device) { confirmation = $0 } }
    ForEach(facts.filter { $0.group > .connection }) { fact in factRow(fact) }
    let formats = UIHardwareText.formatGroups(device.modes)
    if !formats.isEmpty {
      LabeledContent("Supported formats") {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
          ForEach(formats, id: \.size) { group in
            GridRow {
              Text(group.size).font(.uiMeta).foregroundStyle(.secondary)
              HStack(spacing: 4) { ForEach(group.rates, id: \.self) { UIHardwareChip(text: $0) } }
            }
          }
        }
      }
    }
    LabeledContent("Device ID") {
      Text(device.id).font(.uiMeta.monospaced()).textSelection(.enabled)
    }
  }

  private func factRow(_ fact: DeviceFact) -> some View {
    LabeledContent(fact.localizedLabel()) {
      HStack(spacing: 6) {
        ForEach(Array(fact.values.enumerated()), id: \.offset) { _, value in
          if fact.values.count > 1 { UIHardwareChip(text: value) } else { Text(value).font(.uiValue) }
        }
      }
    }
  }

  // MARK: Camera bodies

  private func bodySection(_ group: UISettingsHardwareGroups.Bodies, groups: UISettingsHardwareGroups) -> some View {
    let store = model.cameraControls
    let scanning = store.scanning.contains(group.vendor.id)
    return Section {
      if group.available, addingByAddress.contains(group.vendor.id) {
        DisclosureGroup("Add camera by address", isExpanded: Binding(get: { addingByAddress.contains(group.vendor.id) },
          set: { if !$0 { addingByAddress.remove(group.vendor.id) } })) {
          UICameraBodyAddByAddress(pluginID: group.vendor.id, store: store, cameras: feeds) { camera, feedID in
            pairing[camera.id] = feedID
            expanded.insert(camera.id)
            addingByAddress.remove(group.vendor.id)
          }
        }
      }
      if group.bodies.isEmpty {
        Text(scanning ? "Looking on this Mac’s network…" : "No camera bodies yet.").foregroundStyle(.secondary)
      }
      if group.available, let message = store.discoveryMessages[group.vendor.id] {
        Label(message, systemImage: UISymbol.warning).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(group.bodies) { body in
        if group.available {
          UIHardwareDisclosure(isExpanded: isExpanded(body.id), name: body.camera.name) {
            bodyRow(body, available: true, groups: groups)
              // Paired by whichever path: the pending choice is done, so a later unassign starts clean.
              .onChange(of: body.feedID) { _, feedID in if feedID != nil { pairing[body.id] = nil } }
          } content: {
            bodyDetails(body, vendor: group.vendor, groups: groups)
          }
        } else {
          bodyRow(body, available: false, groups: groups).padding(.leading, UIHardwareDisclosure<EmptyView, EmptyView>.indent)
        }
      }
    } header: {
      HStack(spacing: 8) {
        Text(group.vendor.localizedDisplayName())
        Spacer()
        if !group.available {
          // Muted and kept: a saved pairing in a build without this SDK is never a problem.
          Text("Not included in this build").font(.uiMeta).foregroundStyle(.secondary)
        } else {
          if scanning { ProgressView().controlSize(.small) }
          Button(scanning ? "Finding Camera Bodies…" : "Find Camera Bodies") {
            Task { await store.discover(pluginID: group.vendor.id) }
          }
          .disabled(scanning)
          .help("Looks for camera bodies on this Mac’s network. Opening Settings never does.")
          Button("Add by Address…") { addingByAddress.insert(group.vendor.id) }
            .disabled(addingByAddress.contains(group.vendor.id))
        }
      }
      .controlSize(.small)
    }
  }

  private var feeds: [(id: String, name: String)] { model.feedDescriptors.map { ($0.id.rawValue, $0.name) } }

  private func setup(for body: UIHardwareBody, groups: UISettingsHardwareGroups) -> UIBodySetup? {
    guard let feedID = body.feedID, body.connected,
      let descriptor = model.feedDescriptors.first(where: { $0.id.rawValue == feedID }) else { return nil }
    let device = groups.device(forCamera: feedID)
    let detected = model.cameraUpdate(descriptor.id)?.sourceFormat ?? device?.status?.detected
    return UIBodySetup(properties: body.properties, cameraName: descriptor.name, declaredProfileID: descriptor.sourceProfileID,
      captureName: device?.name, detected: detected, timecodeMode: model.recordingModel.timecodeMode)
  }

  private func bodyRow(_ body: UIHardwareBody, available: Bool, groups: UISettingsHardwareGroups) -> some View {
    let conflict = setup(for: body, groups: groups)?.advisory != nil
    return HStack(alignment: .center, spacing: 8) {
      UIHardwareHealthGlyph(health: available ? (conflict && body.health == .healthy ? .attention : body.health) : .absent)
      Image(systemName: UISymbol.cameraBody).foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(body.camera.name).font(.uiRowEmphasis).lineLimit(1)
        HStack(spacing: 6) {
          if !available {
            Text(body.cameraName.map { "Saved for \($0)" } ?? "Saved")
          } else if body.connected {
            Label { Text("Connected") } icon: { Image(systemName: UISymbol.wifi(connected: true)).imageScale(.small) }
            if let battery = body.battery { UIBatteryGlyph(battery: battery) }
            if let overheating = body.overheating {
              Label { Text(UIControlPresentation.value(overheating)) } icon: { Image(systemName: UISymbol.warning).foregroundStyle(.orange) }
            }
            if conflict { Text("Setup conflict").foregroundStyle(.primary) }
          } else if body.lost {
            Label { Text(body.connectionText).foregroundStyle(.primary) } icon: {
              Image(systemName: UISymbol.wifi(connected: false)).imageScale(.small).foregroundStyle(.orange)
            }
          } else {
            Text(body.connectionText)
          }
        }
        .font(.uiMeta).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      if available, let feedID = body.feedID, !body.connected {
        Button("Reconnect") { Task { await model.cameraControls.reconnect(feedID) } }
          .disabled(model.cameraControls.state(for: feedID).busy)
      }
      if available { bodyPicker(body) }
    }
    .foregroundStyle(available ? .primary : .secondary)
    .accessibilityElement(children: .contain)
  }

  /// The pairing control: None, or the camera this body controls. A camera that has another
  /// body names it and can't be chosen.
  private func bodyPicker(_ body: UIHardwareBody) -> some View {
    let store = model.cameraControls
    return Picker("Camera", selection: Binding(get: { body.feedID ?? pairing[body.id] ?? "" }, set: { choose(body, $0) })) {
      Text("None").tag("")
      Divider()
      ForEach(feeds, id: \.id) { feed in
        let holder = store.assignment(for: feed.id).flatMap { $0.camera.id == body.id ? nil : $0.camera.name }
        Text(holder.map { "\(feed.name) (has \($0))" } ?? feed.name).tag(feed.id).selectionDisabled(holder != nil)
      }
    }
    .labelsHidden().fixedSize()
    .disabled(body.feedID.map { store.state(for: $0).busy } ?? false)
    .accessibilityLabel("Camera for \(body.camera.name)")
  }

  private func choose(_ body: UIHardwareBody, _ feedID: String) {
    let store = model.cameraControls
    let previous = body.feedID
    guard previous != feedID else { return }
    pairing[body.id] = feedID.isEmpty ? nil : feedID
    if !feedID.isEmpty { expanded.insert(body.id) }
    Task {
      if let previous { await store.disconnect(previous, forget: true) }
      // A body with no sign-in pairs at once; one with sign-in waits for it in its row.
      if !feedID.isEmpty, body.camera.authenticationMode == .none {
        await store.connect(camera: body.camera, to: feedID)
      }
    }
  }

  @ViewBuilder private func bodyDetails(_ body: UIHardwareBody, vendor: VendorDescriptor, groups: UISettingsHardwareGroups) -> some View {
    let store = model.cameraControls
    if body.feedID == nil, let pending = pairing[body.id] {
      UICameraBodySignIn(camera: body.camera, feedID: pending,
        cameraName: feeds.first { $0.id == pending }?.name ?? "Camera", store: store,
        captureName: groups.device(forCamera: pending)?.name)
    } else if let feedID = body.feedID {
      let state = store.state(for: feedID)
      LabeledContent("Model") {
        HStack(spacing: 6) {
          Text(body.camera.model ?? body.camera.name)
          if let firmware = body.camera.firmware { Text("firmware \(firmware)").font(.uiMeta).foregroundStyle(.secondary) }
        }
      }
      LabeledContent("Connection") {
        HStack(spacing: 6) {
          Image(systemName: UISymbol.wifi(connected: body.connected)).imageScale(.small)
            .foregroundStyle(body.connected ? Color.secondary : .orange)
          Text(body.connected ? Self.transport(body.camera.transport) : body.connectionText)
          Text(body.camera.address).font(.uiValue).textSelection(.enabled)
        }
      }
      if state.hasSavedCredentials {
        LabeledContent("Sign-in") {
          HStack(spacing: 8) {
            Label("Saved in Keychain", systemImage: "key.fill").labelStyle(.titleAndIcon)
            Button("Forget Saved Sign-In") { Task { await store.forgetCredentials(feedID) } }.disabled(state.busy)
          }
        }
      }
      if body.connected {
        if let battery = body.battery { LabeledContent("Power") { UIBatteryGlyph(battery: battery) } }
        let media = body.properties.filter { $0.role == .media }
        if !media.isEmpty {
          LabeledContent("Media") {
            HStack(spacing: 6) {
              ForEach(media) { slot in
                let text = "\(slot.localizedLabel()) \(UIControlPresentation.value(slot))"
                if slot.severity != nil { Label(text, systemImage: UISymbol.warning) } else { UIHardwareChip(text: text) }
              }
            }
          }
        }
        if let overheating = body.overheating {
          LabeledContent("Temperature") {
            Label(UIControlPresentation.value(overheating), systemImage: UISymbol.warning).foregroundStyle(.orange)
          }
        }
        if let setup = setup(for: body, groups: groups), !setup.rows.isEmpty {
          UIBodySetupView(setup: setup) { action in perform(action, feedID: feedID) }
        }
        if let notice = body.notice {
          Label(notice, systemImage: UISymbol.information).foregroundStyle(.secondary)
        }
      } else {
        if body.lost || (body.scanned && !body.found), let hint = vendor.localizedMissingDeviceHint() {
          Text(hint).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if state.retrying {
          UICameraControlReconnectStatus(state: state)
        } else if let message = state.message {
          Label(message, systemImage: UISymbol.warning).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        DisclosureGroup("Add camera by address") {
          UICameraBodyAddByAddress(pluginID: vendor.id, store: store, cameras: feeds,
            initialAddress: body.camera.address, initialFeedID: feedID)
        }
      }
      HStack(spacing: 8) {
        Button("Camera Control…") { controlSheet = ControlSheet(id: feedID, name: body.cameraName ?? "Camera") }
          .disabled(!body.connected)
        if body.connected {
          Button("Disconnect") { Task { await store.disconnect(feedID) } }.disabled(state.busy)
        }
        Button("Unassign") {
          pairing[body.id] = nil
          Task { await store.disconnect(feedID, forget: true) }
        }.disabled(state.busy)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      LabeledContent("Model") { Text(body.camera.model ?? body.camera.name) }
      LabeledContent("Address") { Text(body.camera.address).font(.uiValue).textSelection(.enabled) }
      Text("Choose a camera for this body to pair it.").font(.uiMeta).foregroundStyle(.secondary)
    }
  }

  static func transport(_ transport: ControlTransport) -> String {
    switch transport {
    case .network: return "Wi-Fi"
    case .usb: return "USB"
    case .bluetooth: return "Bluetooth"
    case .other: return "Connected"
    }
  }

  private func perform(_ action: UIBodySetup.Action, feedID: String) {
    switch action {
    case .useSourceProfile(let id):
      UISessionBridge.live(model: model, interface: interface).perform(.setSourceProfile(cameraID: feedID, id))
    case .setProperty(let propertyID, let value):
      let store = model.cameraControls
      guard let property = store.state(for: feedID).properties.first(where: { $0.id == propertyID }) else { return }
      Task { await store.set(property, value: value, feedID: feedID) }
    }
  }
}

/// An expanding row: a chevron, the row itself, and its details below, indented. Built by hand
/// because a form's DisclosureGroup hides its label from accessibility on macOS, and the label
/// holds the row's name and its camera pop-up.
struct UIHardwareDisclosure<Label: View, Content: View>: View {
  static var indent: CGFloat { 22 }
  @Binding var isExpanded: Bool
  let name: String
  @ViewBuilder let label: Label
  @ViewBuilder let content: Content
  var body: some View {
    HStack(spacing: 6) {
      Button { isExpanded.toggle() } label: {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 16, height: 22).contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(.secondary)
      .help(isExpanded ? "Hide details" : "Show details")
      .accessibilityLabel(isExpanded ? "Hide details of \(name)" : "Show details of \(name)")
      label
    }
    if isExpanded {
      Group { content }.padding(.leading, Self.indent)
    }
  }
}

/// A vendor section's header: its name, and its driver at the trailing edge.
struct UISettingsHardwareHeader: View {
  let title: String
  var trailing: String?
  var body: some View {
    HStack {
      Text(title)
      Spacer()
      if let trailing { Text(trailing).font(.uiMeta).foregroundStyle(.secondary) }
    }
  }
}

/// Health as shape plus color: a filled dot, a hollow dot for absent, a triangle for attention.
struct UIHardwareHealthGlyph: View {
  let health: UIHardwareDevice.Health
  init(health: UIHardwareDevice.Health) { self.health = health }
  init(health: UIHardwareBody.Health) {
    switch health {
    case .healthy: self.health = .healthy
    case .attention: self.health = .attention
    case .absent: self.health = .absent
    }
  }
  var body: some View {
    Group {
      switch health {
      case .healthy: UIStateGlyph(state: .healthy)
      case .attention: UIStateGlyph(state: .warning)
      case .absent: UIStateGlyph(state: .inactive)
      }
    }
    .frame(width: 14)
    .accessibilityElement()
    .accessibilityLabel(health == .healthy ? "Healthy" : health == .attention ? "Needs attention" : "Not connected")
  }
}

/// One typed piece of a value: "2160p 59.94", "PCIe x4 Gen3".
struct UIHardwareChip: View {
  let text: String
  var body: some View {
    Text(text).font(.uiBadge.monospacedDigit()).lineLimit(1).fixedSize()
      .padding(.horizontal, 5).frame(minHeight: 16)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
  }
}

/// The name a capture device goes by on this Mac. Saved when editing ends; an empty name
/// brings the driver's back.
struct UIHardwareNicknameField: View {
  let inventory: HardwareInventory
  let deviceID: String
  let placeholder: String
  @State private var draft = ""
  @FocusState private var focused: Bool
  var body: some View {
    LabeledContent("Name") {
      HStack(spacing: 8) {
        TextField("Name", text: $draft, prompt: Text(placeholder)).labelsHidden()
          .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth: 220)
          .focused($focused)
          .onSubmit { inventory.setNickname(draft, for: deviceID) }
          .onChange(of: focused) { _, now in if !now { inventory.setNickname(draft, for: deviceID) } }
        Text("Stays on this Mac").font(.uiMeta).foregroundStyle(.secondary)
      }
    }
    .onAppear { draft = inventory.nickname(for: deviceID) ?? "" }
    // Collapsing the row while typing keeps the name typed.
    .onDisappear { if Self.commits(draft: draft, saved: inventory.nickname(for: deviceID)) { inventory.setNickname(draft, for: deviceID) } }
    // A name changed elsewhere (the other window, Reset) shows here unless it's being typed over.
    .onChange(of: inventory.nickname(for: deviceID)) { _, saved in draft = Self.resynced(draft: draft, saved: saved, editing: focused) }
  }

  /// Whether leaving saves the draft: only an edit, so a field that never changed can't
  /// write a name back after Reset.
  static func commits(draft: String, saved: String?) -> Bool {
    draft.trimmingCharacters(in: .whitespacesAndNewlines) != (saved ?? "")
  }
  /// The draft after the saved name changed: the new name, unless the person is typing.
  static func resynced(draft: String, saved: String?, editing: Bool) -> String { editing ? draft : saved ?? "" }
}

/// How a paired body meets its capture device: read-only rows, and one advisory with one
/// action when two facts conflict.
struct UIBodySetupView: View {
  let setup: UIBodySetup
  let perform: (UIBodySetup.Action) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Setup").font(.uiMeta.weight(.semibold)).foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
        ForEach(setup.rows, id: \.label) { row in
          GridRow {
            Text(row.label).foregroundStyle(.secondary)
            HStack(spacing: 6) {
              ForEach(Array(row.pieces.enumerated()), id: \.offset) { _, piece in
                if row.pieces.count > 1 || row.label == "Picture" || row.label == "HDMI output" { UIHardwareChip(text: piece) } else { Text(piece) }
              }
              if let note = row.note {
                Label { Text(note) } icon: {
                  Image(systemName: row.tone == .positive ? UISymbol.saved : UISymbol.warning)
                    .foregroundStyle(row.tone == .positive ? Color.green : .orange)
                }
                .font(.uiMeta).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      if let advisory = setup.advisory {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: UISymbol.warning).foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(advisory.title).fontWeight(.semibold)
            Text(advisory.detail).font(.uiMeta).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Button(advisory.actionTitle) { perform(advisory.action) }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
      }
    }
    .padding(8)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}

extension View {
  /// Idle hardware status is read only while a view that shows it can be seen: the main
  /// window and Settings › Hardware, shown, in a window that is neither minimized, hidden
  /// with the app, nor fully covered.
  func uiWatchesHardware(_ inventory: HardwareInventory) -> some View {
    modifier(UIHardwareWatching(inventory: inventory))
  }
}

private struct UIHardwareWatching: ViewModifier {
  let inventory: HardwareInventory
  @State private var watch = UIHardwareWatch()

  func body(content: Content) -> some View {
    content
      .background(UIWindowVisibilityReader { watch.setVisible($0) })
      .onAppear { watch.inventory = inventory; watch.setAppeared(true) }
      .onDisappear { watch.setAppeared(false) }
  }
}

/// One view's hold on the idle reader: held while the view is shown and its window can be
/// seen, so its begin and end always pair.
@MainActor final class UIHardwareWatch {
  var inventory: HardwareInventory?
  private var appeared = false
  private var visible = false
  private(set) var watching = false

  func setAppeared(_ value: Bool) { appeared = value; update() }
  func setVisible(_ value: Bool) { visible = value; update() }

  private func update() {
    let wanted = appeared && visible && inventory != nil
    guard wanted != watching else { return }
    watching = wanted
    if wanted { inventory?.beginWatching() } else { inventory?.endWatching() }
  }
}

/// Reports whether its window can be seen, from the window's occlusion state (which also
/// covers a minimized window and a hidden app), as it changes.
struct UIWindowVisibilityReader: NSViewRepresentable {
  #if UI_VERIFY
  /// Verification hook: an offscreen, transparent window is never unoccluded, so offscreen
  /// runs count a presented window as seen. Only UI_VERIFY builds have it.
  @MainActor static var treatsPresentedWindowsAsVisible = false
  #endif
  let changed: @MainActor (Bool) -> Void
  func makeNSView(context: Context) -> ReaderView { ReaderView(changed: changed) }
  func updateNSView(_ view: ReaderView, context: Context) { view.changed = changed }

  /// Removes its observers when the view goes, from any thread.
  final class Observations: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    func clear() { tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens = [] }
    deinit { clear() }
  }

  final class ReaderView: NSView {
    var changed: @MainActor (Bool) -> Void
    private let observations = Observations()
    init(changed: @escaping @MainActor (Bool) -> Void) {
      self.changed = changed
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observations.clear()
      if let window {
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
          NSWindow.didDeminiaturizeNotification] {
          observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
          })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
          observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
          })
        }
      }
      report()
    }

    private func report() {
      guard let window else { return changed(false) }
      #if UI_VERIFY
      let unoccluded = UIWindowVisibilityReader.treatsPresentedWindowsAsVisible || window.occlusionState.contains(.visible)
      #else
      let unoccluded = window.occlusionState.contains(.visible)
      #endif
      changed(window.isVisible && !window.isMiniaturized && !NSApp.isHidden && unoccluded)
    }
  }
}
