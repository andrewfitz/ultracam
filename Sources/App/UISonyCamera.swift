import SwiftUI

/// One settings sheet per HDMI camera. Detection runs once on opening when
/// needed; connected settings update automatically from camera notifications.
struct UISonyCameraButton: View {
  let feedID: String
  let name: String
  let store: SonyCameraStore
  @State private var presented = false

  var body: some View {
    Button { presented = true } label: {
      Label("Sony Camera", systemImage: "camera.aperture")
    }
    .help("Assign a Sony Wi-Fi camera to \(name) and control its settings")
    .accessibilityLabel("Sony camera settings for \(name)")
    .sheet(isPresented: $presented) {
      UISonyCameraSettings(feedID: feedID, name: name, store: store)
    }
  }
}

struct UISonyCameraSettings: View {
  let feedID: String
  let name: String
  let store: SonyCameraStore
  @Environment(\.dismiss) private var dismiss
  @State private var selectedID = ""
  @State private var user = ""
  @State private var password = ""
  @State private var manualAddress = ""
  @State private var manualMAC = ""
  @State private var manualAuthentication = true
  private var state: SonyFeedState { store.state(for: feedID) }
  private var assignment: SonyFeedAssignment? { store.assignment(for: feedID) }
  private var selectedCamera: SonyDiscoveredCamera? { store.cameras.first { $0.id == selectedID } }
  private var selectedIdentity: String { selectedCamera.map { $0.id + "|" + $0.fingerprint } ?? selectedID }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sony Camera · \(name)").font(.title2.weight(.semibold))
          Text("Wi-Fi controls the camera. HDMI supplies the picture.").foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if !store.available {
            Label("Sony SDK is unavailable in this build.", systemImage: "exclamationmark.triangle")
            Text("Install the downloaded macOS Camera Remote SDK with scripts/install-sony-sdk.py, then rebuild Ultracam.")
              .foregroundStyle(.secondary).textSelection(.enabled)
          } else {
            connection
            if let message = state.message {
              Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if assignment != nil {
              Divider()
              HStack {
                Toggle("Show camera settings over this feed", isOn: Binding(
                  get: { assignment?.showOverlay ?? false },
                  set: { store.showOverlay($0, for: feedID) }))
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh(feedID) } }
                  .disabled(!state.connected || state.busy)
              }
              HStack {
                Label(state.cacheStatus, systemImage: state.connected ? "wifi" : "wifi.slash")
                if let date = state.lastRefresh {
                  Text("Read \(date.formatted(date: .omitted, time: .standard))")
                }
              }.font(.caption).foregroundStyle(.secondary)
              if state.properties.isEmpty {
                Text("Connect and read settings to see the values available in the camera’s current mode.").foregroundStyle(.secondary)
              } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                  ForEach(state.properties.filter { !["faceEyeFrameDisplay", "monitoringDisplayHDMI"].contains($0.id) }) { property in
                    GridRow {
                      Text(property.title)
                      propertyControl(property)
                    }
                  }
                }
              }
              Text("Settings update automatically when the camera reports a change. Rapid changes are combined into one update, with no continuous polling. Refresh is also available if needed. Unavailable settings are read-only; use Remote control priority if a camera dial prevents editing.")
                .font(.caption).foregroundStyle(.secondary)
              Text("HDMI timing is camera-mode dependent. On the FX3, 4K HDMI frame rate is reported as HDMI 4K output timing and may only be available in Movie mode with a 4K HDMI output selected.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
      }
      if state.busy || store.scanning {
        HStack { ProgressView().controlSize(.small); Text(store.scanning ? "Finding network cameras…" : "Contacting camera…") }
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(width: 640, height: 690)
    .onAppear {
      selectedID = assignment?.camera.id ?? ""
      if let camera = assignment?.camera {
        manualAddress = camera.address
        manualMAC = camera.id
        manualAuthentication = camera.authentication
      }
    }
    .task(id: feedID) {
      guard store.available, !state.connected else { return }
      await detectCameras(force: false)
    }
    .onChange(of: selectedIdentity) { _, _ in
      user = ""
      password = ""
    }
    .task(id: selectedIdentity) {
      if let camera = selectedCamera { await store.checkSavedCredentials(for: camera, feedID: feedID) }
    }
  }

  @ViewBuilder private var connection: some View {
    if let assignment {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Label(assignment.camera.displayName, systemImage: state.connected ? "wifi" : "wifi.slash").font(.headline)
            .help(cameraDetail(assignment.camera))
          Text("Assigned to \(name)").font(.caption).foregroundStyle(.secondary)
            .help(cameraDetail(assignment.camera))
        }
        Spacer()
        if state.connected {
          Button("Disconnect") { Task { await store.disconnect(feedID) } }.disabled(state.busy)
        } else if state.hasSavedCredentials {
          Button("Reconnect") { Task { await store.reconnect(feedID) } }.disabled(state.busy || store.scanning)
        }
        Button("Unassign") { Task { await store.disconnect(feedID, forget: true) } }.disabled(state.busy)
      }
      if state.hasSavedCredentials {
        HStack {
          Label("Camera sign-in saved in macOS Keychain", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Forget Saved Sign-In", role: .destructive) { Task { await store.forgetCredentials(feedID) } }
            .disabled(state.busy)
        }
      }
    }
    if !state.connected {
      Text("Cameras on your Wi-Fi network are detected when this panel opens. Configure Remote Shoot Function for computer control on each FX3. Camera menus vary with firmware.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Rescan", systemImage: "arrow.clockwise") { Task { await detectCameras(force: true) } }
          .disabled(store.scanning || state.busy)
        if !store.cameras.isEmpty {
          Picker("Camera", selection: $selectedID) {
            Text("Choose a camera").tag("")
            ForEach(store.cameras) { camera in
              Text(cameraTitle(camera)).tag(camera.id).help(cameraDetail(camera))
            }
          }.labelsHidden().accessibilityLabel("Sony Wi-Fi camera")
            .disabled(store.scanning || state.busy)
            .help(selectedCamera.map(cameraDetail) ?? "Choose a detected Wi-Fi camera")
        }
      }
      DisclosureGroup("Add FX3 by IP") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Use a camera address only if automatic detection cannot find it.")
            .font(.caption).foregroundStyle(.secondary)
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
              Text("IP address")
              TextField("Camera IPv4 address", text: $manualAddress)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Camera IP address")
            }
            GridRow {
              Text("MAC address")
              TextField("Camera MAC address", text: $manualMAC)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Camera MAC address")
            }
          }
          Toggle("Camera access authentication is enabled", isOn: $manualAuthentication)
          Text("Use the addresses shown by the camera. Check Camera reads its identity before connecting; your camera user name and password are sent only when you press Connect.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Check Camera") {
            Task {
              if let camera = await store.prepareCamera(address: manualAddress, macAddress: manualMAC,
                authentication: manualAuthentication) {
                selectedID = camera.id
              }
            }
          }
          .disabled(store.scanning || state.busy || manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            manualMAC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.top, 8)
      }
      if let message = store.discoveryMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
      if let camera = selectedCamera {
        if store.holder(of: camera.id, excluding: feedID) != nil {
          Text("This camera is assigned to another feed. Unassign it there first.").foregroundStyle(.orange)
        } else {
          if store.hasSavedCredentials(for: camera) {
            if assignment == nil {
              Button("Connect Using Saved Sign-In") { Task { await store.connectUsingSavedCredentials(camera, to: feedID) } }
                .disabled(state.busy || store.scanning || !camera.fingerprintError.isEmpty)
            }
            DisclosureGroup("Change camera sign-in") { manualSignIn(camera) }
          } else { manualSignIn(camera) }
        }
      } else if assignment != nil {
        Text("Detecting the saved camera uses its MAC address even if its IP address changes. Use Rescan if it has just joined the network.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func manualSignIn(_ camera: SonyDiscoveredCamera) -> some View {
    if camera.authentication {
      TextField("Camera user name", text: $user).textContentType(.username)
      SecureField("Camera password", text: $password).textContentType(.password)
      if !camera.fingerprint.isEmpty {
        Text("Camera fingerprint: \(camera.fingerprint)").font(.caption.monospaced()).textSelection(.enabled)
      }
      Text("After a successful connection, the camera sign-in is saved securely in macOS Keychain. Saved cameras reconnect when Ultracam opens. Unassigning a feed keeps its saved sign-in; Forget Saved Sign-In removes it.")
        .font(.caption).foregroundStyle(.secondary)
    }
    if !camera.fingerprintError.isEmpty { Text(camera.fingerprintError).foregroundStyle(.orange) }
    Button(assignment == nil ? "Connect and Assign to \(name)" : "Connect Assigned Camera") {
      let connectionPassword = password
      password = ""
      Task { await store.connect(camera, to: feedID, user: user, password: connectionPassword) }
    }
    .disabled(store.scanning || state.busy || !camera.fingerprintError.isEmpty ||
      (assignment != nil && assignment?.camera.id != camera.id) ||
      (camera.authentication && (user.isEmpty || password.isEmpty)))
  }

  private func detectCameras(force: Bool) async {
    if force { await store.discover() } else { await store.discoverIfNeeded() }
    if let savedID = assignment?.camera.id, store.cameras.contains(where: { $0.id == savedID }) {
      selectedID = savedID
    } else if !store.cameras.contains(where: { $0.id == selectedID }) {
      selectedID = store.cameras.count == 1 ? store.cameras[0].id : ""
    }
  }

  private func cameraTitle(_ camera: SonyDiscoveredCamera) -> String {
    let sameName = store.cameras.lazy.filter { $0.displayName == camera.displayName }.prefix(2).count > 1
    return sameName ? "\(camera.displayName) · \(camera.address)" : camera.displayName
  }

  private func cameraDetail(_ camera: SonyDiscoveredCamera) -> String {
    "\(camera.model) · IP \(camera.address) · MAC \(camera.id)"
  }

  @ViewBuilder private func propertyControl(_ property: SonyCameraProperty) -> some View {
    if property.writable && state.connected {
      Picker(property.title, selection: Binding(
        get: { property.value },
        set: { value in Task { await store.set(property, value: value, feedID: feedID) } })) {
        if !property.choices.contains(where: { $0.value == property.value }) {
          Text(property.label).tag(property.value)
        }
        ForEach(property.choices) { choice in Text(choice.label).tag(choice.value) }
      }
      .labelsHidden().accessibilityLabel(property.title).disabled(state.busy)
    } else {
      Text(property.label).monospacedDigit().textSelection(.enabled)
        .foregroundStyle(state.connected ? .primary : .secondary)
    }
  }
}

struct UISonySettingsOverlay: View {
  let feedID: String
  let store: SonyCameraStore
  private let keys = ["iso", "aperture", "shutter", "shutterAngle", "whiteBalance", "temperature", "focusMode"]

  var body: some View {
    let state = store.state(for: feedID)
    if store.assignment(for: feedID)?.showOverlay == true, state.connected,
      state.properties.contains(where: { keys.contains($0.id) }) {
      ViewThatFits(in: .horizontal) {
        Text(summary(state)).lineLimit(1)
        Text(shortSummary(state)).lineLimit(1)
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.white)
      .padding(6)
      .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
      .accessibilityElement(children: .combine)
      .allowsHitTesting(false)
    }
  }

  private func summary(_ state: SonyFeedState) -> String {
    let fields = keys.compactMap { key in state.properties.first { $0.id == key } }
    return fields.map { property in
      switch property.id {
      case "iso": return "ISO \(property.label)"
      case "whiteBalance": return "WB \(property.label)"
      default: return property.label
      }
    }.joined(separator: " · ")
  }

  private func shortSummary(_ state: SonyFeedState) -> String {
    let fields = ["iso", "aperture", "shutter"].compactMap { key in state.properties.first { $0.id == key } }
    return fields.isEmpty ? summary(state) : fields.map { $0.id == "iso" ? "ISO \($0.label)" : $0.label }.joined(separator: " · ")
  }
}
