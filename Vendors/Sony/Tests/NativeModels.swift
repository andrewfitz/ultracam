import Foundation

// Native JSON fixtures only; behavior runs through the production generic store.
struct SonyCameraCredential: Equatable, Sendable { var user: String; var password: String }

struct SonyDiscoveredCamera: Codable, Identifiable, Equatable, Sendable {
  var id: String // Stable MAC address, never the discovery index or DHCP address.
  var model: String
  var address: String
  var authentication: Bool
  var fingerprint: String
  var fingerprintError: String
  var name: String? = nil

  var displayName: String {
    let friendlyName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return friendlyName.isEmpty ? model : friendlyName
  }
}

struct SonyCameraChoice: Codable, Identifiable, Equatable, Sendable {
  var value: UInt64
  var label: String
  var id: UInt64 { value }
}

struct SonyCameraProperty: Codable, Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var code: UInt32
  var value: UInt64
  var label: String
  var writable: Bool
  var choices: [SonyCameraChoice]
}

struct SonyFeedAssignment: Codable, Equatable, Sendable {
  var camera: SonyDiscoveredCamera
  var showOverlay = false

  private enum CodingKeys: String, CodingKey { case camera, showOverlay }
  init(camera: SonyDiscoveredCamera, showOverlay: Bool = false) {
    self.camera = camera; self.showOverlay = showOverlay
  }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    camera = try container.decode(SonyDiscoveredCamera.self, forKey: .camera)
    showOverlay = try container.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? false
  }
}


extension SonyDiscoveredCamera {
  var controlCamera: ControlCamera {
    ControlCamera(pluginID: "sony", id: id, name: displayName, transport: .network, address: address,
      fingerprint: fingerprintError.isEmpty ? fingerprint : nil,
      authenticationMode: authentication ? .usernamePassword : .none)
  }
}
extension ControlCamera { var displayName: String { name } }

// Small argument adapters keep the original behavioral assertion vocabulary;
// all state, persistence, scheduling and lifecycle belong to production code.
@MainActor extension CameraControlStore {
  static var preferencesKey: String { CameraControlPreferences.preferencesKey }
  convenience init(defaults: UserDefaults, backend: UCSonyCameraControl,
    credentials: any CameraControlCredentialStoring, now: @escaping @MainActor () -> Date = { Date() }) {
    self.init(plugins: ["sony": SonyControlPlugin(backend: backend)], credentials: credentials,
      persistence: CameraControlPreferences(defaults: defaults), now: now)
  }
  func discover() async { await discover(pluginID: "sony") }
  func discoverIfNeeded() async { await discoverIfNeeded(pluginID: "sony") }
  func connect(_ camera: SonyDiscoveredCamera, to feedID: String, user: String, password: String,
    saveCredentials: Bool = true) async {
    await connect(camera: camera.controlCamera, to: feedID,
      credentials: camera.authentication ? .usernamePassword(username: user, password: password) : nil,
      saveCredentials: saveCredentials)
  }
  func connectUsingSavedCredentials(_ camera: SonyDiscoveredCamera, to feedID: String) async {
    await connectUsingSavedCredentials(camera.controlCamera, to: feedID)
  }
  func checkSavedCredentials(for camera: SonyDiscoveredCamera, feedID: String?) async {
    await checkSavedCredentials(for: camera.controlCamera, feedID: feedID ?? "credential-check")
  }
  func hasSavedCredentials(for camera: SonyDiscoveredCamera) -> Bool { hasSavedCredentials(for: camera.controlCamera) }
  func set(_ property: ControlProperty, value: UInt64, feedID: String) async {
    await set(property, value: .unsignedInteger(value), feedID: feedID)
  }
  func prepareCamera(address: String, macAddress: String, authentication: Bool, feedID: String = "manual-preparation") async -> ControlCamera? {
    await prepare(pluginID: "sony", request: .endpoint(.init(address: address, expectedIdentity: macAddress,
      authenticationMode: authentication ? .usernamePassword : .none)), feedID: feedID)?.camera
  }
}
