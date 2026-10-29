import SwiftUI

struct UICameraControlButton: View {
    let feedID: String
    let name: String
    let store: CameraControlStore
    var viewFactories: [String: ControlViewFactory] = [:]
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label("Camera Control", systemImage: "camera.aperture") }
            .help("Assign a control camera to \(name) and change its settings")
            .accessibilityLabel("Camera settings for \(name)")
            .sheet(isPresented: $presented) { UICameraControlSettings(feedID: feedID, name: name, store: store, viewFactories: viewFactories) }
    }
}

struct UICameraControlSettings: View {
    let feedID: String
    let name: String
    let store: CameraControlStore
    var viewFactories: [String: ControlViewFactory] = [:]
    @Environment(\.dismiss) private var dismiss
    @State private var pluginID = ""
    @State private var selectedID = ""
    @State private var user = ""
    @State private var password = ""
    @State private var manualAddress = ""
    @State private var manualIdentity = ""
    @State private var manualAuthentication = true
    private var state: CameraControlFeedState { store.state(for: feedID) }
    private var assignment: CameraControlAssignment? { store.assignment(for: feedID) }
    private var candidates: [ControlCamera] { store.cameras[pluginID] ?? [] }
    private var selectedCamera: ControlCamera? { candidates.first { $0.id == selectedID } }
    private var selectedIdentity: String { pluginID + "|" + selectedID + "|" + (selectedCamera?.fingerprint ?? "") }
    private var scanning: Bool { store.scanning.contains(pluginID) }
    private var vendor: VendorDescriptor? { store.descriptor(for: pluginID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Camera Control · \(name)").font(.title2.weight(.semibold))
                    Text("Camera controls are separate from the captured picture.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.descriptors.isEmpty {
                        Label("No camera-control plugins are available.", systemImage: "exclamationmark.triangle")
                    } else {
                        if store.descriptors.count > 1 {
                            Picker("Control vendor", selection: $pluginID) {
                                ForEach(store.descriptors) { Text($0.localizedDisplayName()).tag($0.id) }
                            }.disabled(assignment != nil || state.busy)
                        }
                        if vendor?.sdkPresent == false {
                            Label("\(vendor?.localizedDisplayName() ?? "Camera control") is unavailable in this build.", systemImage: "exclamationmark.triangle")
                        } else { connection }
                        if let message = state.message {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if assignment != nil {
                            if let factory = viewFactories[pluginID] { factory(vendorContext) }
                            else { properties }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
            }
            if state.busy || scanning {
                HStack { ProgressView().controlSize(.small); Text(scanning ? "Finding cameras…" : "Contacting camera…") }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 640, height: 690)
        .onAppear {
            pluginID = assignment?.camera.pluginID ?? store.descriptors.first?.id ?? ""
            selectedID = assignment?.camera.id ?? ""
            if let camera = assignment?.camera {
                manualAddress = camera.address; manualIdentity = camera.id
                manualAuthentication = camera.authenticationMode == .usernamePassword
            }
        }
        .task(id: pluginID) { guard !pluginID.isEmpty, !state.connected else { return }; await detect(force: false) }
        .onChange(of: selectedIdentity) { _, _ in user = ""; password = "" }
        .task(id: selectedIdentity) {
            if let camera = selectedCamera { await store.checkSavedCredentials(for: camera, feedID: feedID) }
        }
    }
    private var vendorContext: ControlViewContext {
        ControlViewContext(feedID: feedID, pluginID: pluginID, properties: state.properties,
            connected: state.connected, busy: state.busy, message: state.message,
            prepare: { id, request in await store.prepare(pluginID: id, request: request, feedID: feedID) },
            connect: { camera, credentials, save in await store.connect(camera: camera, to: feedID, credentials: credentials, saveCredentials: save) },
            set: { property, value in await store.set(property, value: value, feedID: feedID) },
            refresh: { await store.refresh(feedID) })
    }
    @ViewBuilder private var properties: some View {
        Divider()
        HStack {
            Toggle("Show camera settings over this feed", isOn: Binding(get: { assignment?.showOverlay ?? false }, set: { store.showOverlay($0, for: feedID) }))
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh(feedID) } }.disabled(!state.connected || state.busy)
        }
        HStack {
            Label(state.cacheStatus, systemImage: state.connected ? "wifi" : "wifi.slash")
            if let date = state.lastRefresh { Text("Read \(date.formatted(date: .omitted, time: .standard))") }
        }.font(.caption).foregroundStyle(.secondary)
        if state.properties.isEmpty {
            Text("Connect and read settings to see the values available in the camera’s current mode.").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                ForEach(state.properties.filter { $0.role != .hidden && $0.role != .cameraDisplay }) { property in
                    GridRow { Text(property.localizedLabel()); UIControlPropertyField(property: property, connected: state.connected, busy: state.busy) { value in
                        Task { await store.set(property, value: value, feedID: feedID) }
                    } }
                }
            }
        }
        Text("Settings update when the camera reports a change. Refresh is available if needed. Unavailable settings are read-only; camera mode or physical control priority may prevent editing.")
            .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var connection: some View {
        if let assignment {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label(assignment.camera.name, systemImage: state.connected ? "wifi" : "wifi.slash").font(.headline)
                    Text("Assigned to \(name)").font(.caption).foregroundStyle(.secondary)
                }.help(detail(assignment.camera))
                Spacer()
                if state.connected {
                    Button("Disconnect") { Task { await store.disconnect(feedID) } }
                } else {
                    Button("Reconnect") { Task { await store.reconnect(feedID) } }.disabled(state.busy || scanning)
                }
                Button("Unassign") { Task { await store.disconnect(feedID, forget: true) } }.disabled(state.busy)
            }
            if state.hasSavedCredentials {
                HStack {
                    Label("Camera sign-in saved in macOS Keychain", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget Saved Sign-In", role: .destructive) { Task { await store.forgetCredentials(feedID) } }.disabled(state.busy)
                }
            }
        }
        if !state.connected {
            HStack {
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await detect(force: true) } }.disabled(scanning || state.busy)
                if !candidates.isEmpty {
                    Picker("Camera", selection: $selectedID) {
                        Text("Choose a camera").tag("")
                        ForEach(candidates) { camera in Text(title(camera)).tag(camera.id).help(detail(camera)) }
                    }.labelsHidden().accessibilityLabel("Control camera").disabled(scanning || state.busy)
                }
            }
            DisclosureGroup("Add camera by address") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Camera network address", text: $manualAddress).textFieldStyle(.roundedBorder).accessibilityLabel("Camera IP address")
                    TextField("Expected stable identity (for example MAC address)", text: $manualIdentity).textFieldStyle(.roundedBorder).accessibilityLabel("Camera stable identity")
                    Toggle("Camera access authentication is enabled", isOn: $manualAuthentication)
                    Text("Check Camera resolves its identity before connecting. Sign-in is sent when you press Connect.").font(.caption).foregroundStyle(.secondary)
                    Button("Check Camera") { Task {
                        let identity = manualIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
                        let request = ControlPreparationRequest.endpoint(.init(address: manualAddress.trimmingCharacters(in: .whitespacesAndNewlines), expectedIdentity: identity.isEmpty ? nil : identity, authenticationMode: manualAuthentication ? .usernamePassword : .none))
                        if let prepared = await store.prepare(pluginID: pluginID, request: request, feedID: feedID) { selectedID = prepared.camera.id }
                    } }.disabled(scanning || state.busy || manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 8)
            }
            if let message = store.discoveryMessages[pluginID] { Text(message).foregroundStyle(.secondary) }
            if let camera = selectedCamera {
                if store.holder(of: camera.id, pluginID: camera.pluginID, excluding: feedID) != nil {
                    Text("This camera is assigned to another feed. Unassign it there first.").foregroundStyle(.orange)
                } else {
                    if store.hasSavedCredentials(for: camera) {
                        Button("Connect Using Saved Sign-In") { Task { await store.connectUsingSavedCredentials(camera, to: feedID) } }.disabled(state.busy || scanning)
                        DisclosureGroup("Change camera sign-in") { signIn(camera) }
                    } else { signIn(camera) }
                }
            }
        }
    }
    @ViewBuilder private func signIn(_ camera: ControlCamera) -> some View {
        if camera.authenticationMode == .usernamePassword {
            TextField("Camera user name", text: $user).textContentType(.username)
            SecureField("Camera password", text: $password).textContentType(.password)
            if let fingerprint = camera.fingerprint { Text("Camera fingerprint: \(fingerprint)").font(.caption.monospaced()).textSelection(.enabled) }
            Text("Successful sign-in is saved in macOS Keychain. Unassigning keeps it; Forget Saved Sign-In removes it.").font(.caption).foregroundStyle(.secondary)
        }
        Button(assignment == nil ? "Connect and Assign to \(name)" : "Connect Assigned Camera") {
            let credential: ControlCredentials? = camera.authenticationMode == .usernamePassword ? .usernamePassword(username: user, password: password) : nil
            password = ""
            Task { await store.connect(camera: camera, to: feedID, credentials: credential) }
        }.disabled(scanning || state.busy || (assignment != nil && assignment?.camera.id != camera.id) || (camera.authenticationMode == .usernamePassword && (user.isEmpty || password.isEmpty)))
    }
    private func detect(force: Bool) async {
        if force { await store.discover(pluginID: pluginID) } else { await store.discoverIfNeeded(pluginID: pluginID) }
        if let saved = assignment?.camera.id, candidates.contains(where: { $0.id == saved }) { selectedID = saved }
        else if !candidates.contains(where: { $0.id == selectedID }) { selectedID = candidates.count == 1 ? candidates[0].id : "" }
    }
    private func title(_ camera: ControlCamera) -> String {
        candidates.filter { $0.name == camera.name }.count > 1 ? "\(camera.name) · \(camera.address)" : camera.name
    }
    private func detail(_ camera: ControlCamera) -> String { "\(camera.name) · \(camera.address) · \(camera.id)" }
}

struct UIControlPropertyField: View {
    let property: ControlProperty
    let connected: Bool
    let busy: Bool
    let apply: @MainActor @Sendable (ControlValue) -> Void
    var body: some View {
        Group {
            if property.writable && connected {
                if !property.options.isEmpty {
                    Picker(property.localizedLabel(), selection: Binding(get: { property.value }, set: apply)) {
                        if !property.options.contains(where: { $0.value == property.value }) { Text(UIControlPresentation.value(property)).tag(property.value) }
                        ForEach(property.options) { Text($0.localizedLabel()).tag($0.value) }
                    }.labelsHidden()
                } else if case .boolean(let value) = property.value {
                    Toggle(property.localizedLabel(), isOn: Binding(get: { value }, set: { apply(.boolean($0)) })).labelsHidden()
                } else { UIControlScalarEditor(property: property, apply: apply) }
            } else { Text(UIControlPresentation.value(property)).foregroundStyle(connected ? .primary : .secondary) }
        }.disabled(busy).accessibilityLabel(property.localizedLabel()).help(property.localizedUnavailableReason() ?? property.localizedLabel())
    }
}

struct UICameraSettingsOverlay: View {
    let feedID: String
    let store: CameraControlStore
    var body: some View {
        let state = store.state(for: feedID)
        if store.assignment(for: feedID)?.showOverlay == true, state.connected, state.properties.contains(where: { $0.overlayOrder != nil }) {
            ViewThatFits(in: .horizontal) {
                Text(UIControlPresentation.overlay(state.properties)).lineLimit(1)
                Text(UIControlPresentation.overlay(state.properties, compact: true)).lineLimit(1)
            }.font(.caption.monospacedDigit()).foregroundStyle(.white).padding(6)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .combine).allowsHitTesting(false)
        }
    }
}

private struct UIControlScalarEditor: View {
    let property: ControlProperty
    let apply: @MainActor @Sendable (ControlValue) -> Void
    @State private var draft = ""
    private var parsed: ControlValue? {
        switch property.value {
        case .integer: return Int64(draft).map(ControlValue.integer)
        case .unsignedInteger: return UInt64(draft).map(ControlValue.unsignedInteger)
        case .decimal:
            guard let value = Double(draft), value.isFinite else { return nil }
            return .decimal(value)
        case .text: return .text(draft)
        case .choice: return .choice(draft)
        case .boolean: return nil
        }
    }
    var body: some View {
        HStack {
            TextField(property.localizedLabel(), text: $draft).textFieldStyle(.roundedBorder).onSubmit(commit)
            Button("Apply", action: commit).disabled(parsed == nil || parsed == property.value)
        }.onAppear { draft = UIControlPresentation.value(property.value) }
            .onChange(of: property.value) { _, value in draft = UIControlPresentation.value(value) }
    }
    private func commit() { if let value = parsed { apply(value) } }
}
