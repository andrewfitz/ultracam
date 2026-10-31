import SwiftUI

// Vendor test groups compile this file on its own, without the shared components, so it
// uses plain SwiftUI and system symbol names only.

struct UICameraControlButton: View {
    let feedID: String
    let name: String
    let store: CameraControlStore
    var viewFactories: [String: ControlViewFactory] = [:]
    /// Settings › Hardware, where pairing lives.
    var openHardware: (() -> Void)? = nil
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label("Camera Control…", systemImage: "camera.aperture") }
            .help("Change the settings of \(name)'s camera body")
            .accessibilityLabel("Camera Control for \(name)")
            .sheet(isPresented: $presented) {
                UICameraControlSettings(feedID: feedID, name: name, store: store, viewFactories: viewFactories, openHardware: openHardware)
            }
    }
}

/// Operates a camera's paired body: its settings, Reconnect, Disconnect, Unassign and its saved
/// sign-in. Pairing lives in Settings › Hardware, so opening this never scans the network.
struct UICameraControlSettings: View {
    let feedID: String
    let name: String
    let store: CameraControlStore
    var viewFactories: [String: ControlViewFactory] = [:]
    var openHardware: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private var state: CameraControlFeedState { store.state(for: feedID) }
    private var assignment: CameraControlAssignment? { store.assignment(for: feedID) }
    private var pluginID: String { assignment?.camera.pluginID ?? "" }
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
                    if let assignment {
                        if vendor?.sdkPresent == false {
                            Label("\(vendor?.localizedDisplayName() ?? "Camera control") is not included in this build.", systemImage: "info.circle")
                        } else { connection(assignment) }
                        if let message = state.message {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if let factory = viewFactories[pluginID] { factory(vendorContext) }
                        else { properties }
                    } else {
                        Text("No camera body is paired with \(name). Pair one in Settings › Hardware, then its settings appear here.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let openHardware {
                            Button("Open Hardware…") { dismiss(); openHardware() }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
            }
            if state.busy {
                HStack { ProgressView().controlSize(.small); Text("Contacting camera…") }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 640, height: 690)
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
            Toggle("Show camera settings over this picture", isOn: Binding(get: { assignment?.showOverlay ?? false }, set: { store.showOverlay($0, for: feedID) }))
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
                ForEach(state.properties.filter { $0.role != .hidden && $0.role != .cameraDisplay && $0.role != .firmware }) { property in
                    GridRow { Text(property.localizedLabel()); UIControlPropertyField(property: property, connected: state.connected, busy: state.busy) { value in
                        Task { await store.set(property, value: value, feedID: feedID) }
                    } }
                }
            }
        }
        Text("Settings update when the camera reports a change. Refresh is available if needed. Unavailable settings are read-only; camera mode or physical control priority may prevent editing.")
            .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private func connection(_ assignment: CameraControlAssignment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(assignment.camera.name, systemImage: state.connected ? "wifi" : "wifi.slash").font(.headline)
                Text("Assigned to \(name)").font(.caption).foregroundStyle(.secondary)
            }.help("\(assignment.camera.name) · \(assignment.camera.address) · \(assignment.camera.id)")
            Spacer()
            if state.connected {
                Button("Disconnect") { Task { await store.disconnect(feedID) } }
            } else {
                // Reconnect uses the saved sign-in: a body dropping mid-show never sends anyone to Settings.
                Button("Reconnect") { Task { await store.reconnect(feedID) } }.disabled(state.busy)
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
}

/// Sign-in for pairing one body with one camera, inline in its Settings › Hardware row: the
/// saved sign-in when there is one, otherwise user name, password and the fingerprint.
struct UICameraBodySignIn: View {
    let camera: ControlCamera
    let feedID: String
    let cameraName: String
    let store: CameraControlStore
    /// The capture device the camera uses, so the person checks the cable before signing in.
    var captureName: String? = nil
    @State private var user = ""
    @State private var password = ""
    private var state: CameraControlFeedState { store.state(for: feedID) }

    var body: some View {
        Group {
            if store.hasSavedCredentials(for: camera) {
                Button("Connect Using Saved Sign-In") { Task { await store.connectUsingSavedCredentials(camera, to: feedID) } }
                    .buttonStyle(.borderedProminent).disabled(state.busy)
                DisclosureGroup("Change camera sign-in") { fields }
            } else { fields }
            if let message = state.message {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        // Only after a camera was chosen for this body: the check re-verifies the body's identity.
        .task(id: camera.id + "|" + feedID) { await store.checkSavedCredentials(for: camera, feedID: feedID) }
    }

    @ViewBuilder private var fields: some View {
        if camera.authenticationMode == .usernamePassword {
            TextField("Camera user name", text: $user).textContentType(.username)
            SecureField("Camera password", text: $password).textContentType(.password)
            if let fingerprint = camera.fingerprint {
                LabeledContent("Camera fingerprint") { Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        Text(["\(captureName.map { "Check that this body’s HDMI goes to \($0)." } ?? "")",
              camera.authenticationMode == .usernamePassword
                ? "A successful sign-in is saved in macOS Keychain. Unassigning keeps it; Forget Saved Sign-In removes it." : ""]
            .filter { !$0.isEmpty }.joined(separator: " "))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button("Connect and Assign to \(cameraName)") {
            let credential: ControlCredentials? = camera.authenticationMode == .usernamePassword ? .usernamePassword(username: user, password: password) : nil
            password = ""
            Task { await store.connect(camera: camera, to: feedID, credentials: credential) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.busy || (camera.authenticationMode == .usernamePassword && (user.isEmpty || password.isEmpty)))
    }
}

/// Adds a body that a scan can't find, by its address, for one camera. The identity is
/// checked before anything is sent; sign-in follows in the body's row.
struct UICameraBodyAddByAddress: View {
    let pluginID: String
    let store: CameraControlStore
    /// The cameras a body can be added for, by ID and name.
    let cameras: [(id: String, name: String)]
    var initialAddress = ""
    var initialFeedID: String? = nil
    var onPrepared: (ControlCamera, String) -> Void = { _, _ in }
    @State private var address = ""
    @State private var identity = ""
    @State private var authentication = true
    @State private var feedID = ""

    var body: some View {
        Group {
            if initialFeedID == nil {
                Picker("For", selection: $feedID) {
                    ForEach(cameras, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            TextField("Camera network address", text: $address).textFieldStyle(.roundedBorder).accessibilityLabel("Camera IP address")
            TextField("Expected stable identity (for example MAC address)", text: $identity).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Camera stable identity")
            Toggle("Camera access authentication is enabled", isOn: $authentication)
            Text("Check Camera resolves its identity before connecting. Sign-in is sent when you press Connect.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check Camera") { Task {
                let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
                let request = ControlPreparationRequest.endpoint(.init(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                    expectedIdentity: trimmed.isEmpty ? nil : trimmed, authenticationMode: authentication ? .usernamePassword : .none))
                if let prepared = await store.prepare(pluginID: pluginID, request: request, feedID: feedID) { onPrepared(prepared.camera, feedID) }
            } }
            .disabled(feedID.isEmpty || store.state(for: feedID).busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message = store.state(for: feedID).message, !feedID.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .onAppear {
            if address.isEmpty { address = initialAddress }
            if feedID.isEmpty { feedID = initialFeedID ?? cameras.first?.id ?? "" }
        }
    }
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
    /// Typed pieces set apart by spacing (J 22).
    private func pieces(_ pieces: [String]) -> some View {
        HStack(spacing: 12) { ForEach(Array(pieces.enumerated()), id: \.offset) { Text($0.element).lineLimit(1).fixedSize() } }
    }
    var body: some View {
        let state = store.state(for: feedID)
        if store.assignment(for: feedID)?.showOverlay == true, state.connected, state.properties.contains(where: { $0.overlayOrder != nil }) {
            ViewThatFits(in: .horizontal) {
                pieces(UIControlPresentation.overlayPieces(state.properties))
                pieces(UIControlPresentation.overlayPieces(state.properties, compact: true))
            }.font(.caption.monospacedDigit()).foregroundStyle(.white).padding(6)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(UIControlPresentation.overlay(state.properties))
                .allowsHitTesting(false)
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
