import Foundation
import Observation

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

@MainActor @Observable
final class SonyFeedState {
  var connected = false
  var busy = false
  var dirty = false
  var properties: [SonyCameraProperty] = []
  var lastRefresh: Date?
  var message: String?
  var hasSavedCredentials = false
  var invalidationRevision: UInt64 = 0

  var cacheStatus: String {
    if !connected { return "Disconnected · cached values" }
    if dirty { return message == nil ? "Updating settings…" : "Settings update failed" }
    return "Settings up to date"
  }
}

/// A control plane alongside HDMI capture. No periodic polling or video requests.
/// Property callbacks schedule coalesced reads; an idle camera causes no reads.
@MainActor @Observable
final class SonyCameraStore {
  static let preferencesKey = "ui.sony.controls.v1"
  private(set) var assignments: [String: SonyFeedAssignment]
  private(set) var cameras: [SonyDiscoveredCamera] = []
  private(set) var scanning = false
  private(set) var discoveryMessage: String?
  private(set) var lastSuccessfulDiscovery: Date?
  private(set) var shuttingDown = false
  @ObservationIgnored private var discoveryTask: Task<Void, Never>?
  @ObservationIgnored private var restoreTask: Task<Void, Never>?
  @ObservationIgnored private var restoredAtLaunch = false
  @ObservationIgnored private var reconnectTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var reconnectIDs: [String: UUID] = [:]
  @ObservationIgnored private var manuallyDisconnected: Set<String> = []
  private var savedCredentialCameras: Set<String> = []
  @ObservationIgnored private var shutdownTask: Task<String?, Never>?
  @ObservationIgnored private var requestedSDKWork = false
  @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var pendingRefreshes: Set<String> = []
  @ObservationIgnored private var states: [String: SonyFeedState] = [:]
  private var connecting: [String: String] = [:]
  /// Explicit recovery entries remain available if SSDP still misses them.
  private var manuallyAddedCameraIDs: Set<String> = []
  private var removedFeeds: Set<String> = []
  @ObservationIgnored private var preferencesReset = false
  private let backend: UCSonyCameraControl
  private let defaults: UserDefaults
  private let credentials: any SonyCameraCredentialStoring
  private let now: @MainActor () -> Date
  private static let discoveryCacheLifetime: TimeInterval = 30
  var available: Bool { backend.available }
  var needsShutdown: Bool { requestedSDKWork }

  init(defaults: UserDefaults = .standard, backend: UCSonyCameraControl = UCSonyCameraControl(),
    credentials: any SonyCameraCredentialStoring = SonyCameraKeychain(), now: @escaping @MainActor () -> Date = { Date() }) {
    self.defaults = defaults
    self.backend = backend
    self.credentials = credentials
    self.now = now
    assignments = defaults.data(forKey: Self.preferencesKey)
      .flatMap { try? JSONDecoder().decode([String: SonyFeedAssignment].self, from: $0) } ?? [:]
    backend.eventHandler = { [weak self] feedID, kind, message in
      // The bridge contract delivers events on main. Handle them in queue order
      // so a retired session's disconnect cannot overtake a reconnect reply.
      MainActor.assumeIsolated {
        guard let self, !self.shuttingDown, !self.removedFeeds.contains(feedID) else { return }
        let state = self.state(for: feedID)
        state.invalidationRevision &+= 1
        switch kind {
        case "changed":
          state.dirty = true
          self.pendingRefreshes.insert(feedID)
          self.scheduleRefresh(feedID)
        case "disconnected":
          state.connected = false; state.dirty = true; state.message = message
          self.cancelRefresh(feedID)
          self.lastSuccessfulDiscovery = nil
        default: state.dirty = true; state.message = message
        }
      }
    }
  }

  func state(for feedID: String) -> SonyFeedState {
    if let state = states[feedID] { return state }
    let state = SonyFeedState()
    states[feedID] = state
    return state
  }

  func assignment(for feedID: String) -> SonyFeedAssignment? { assignments[feedID] }

  func holder(of cameraID: String, excluding feedID: String) -> String? {
    assignments.first { $0.key != feedID && $0.value.camera.id == cameraID }?.key
      ?? connecting.first { $0.key != feedID && $0.value == cameraID }?.key
  }

  /// Multiple settings sheets share one scan. No timer refreshes this cache;
  /// freshness is checked only when opening a sheet or pressing Rescan.
  func discoverIfNeeded() async { await discover(force: false) }

  func discover(force: Bool = true) async {
    guard available, !shuttingDown else { return }
    if let task = discoveryTask { await task.value; return }
    if !force, let date = lastSuccessfulDiscovery {
      let age = now().timeIntervalSince(date)
      if age >= 0 && age < Self.discoveryCacheLifetime { return }
    }
    // A manual identity check shares the same control-plane queue. Its result
    // will populate candidates; do not queue an overlapping scan behind it.
    guard !scanning else { return }
    scanning = true
    requestedSDKWork = true
    discoveryMessage = nil
    let task = Task { @MainActor in
      defer { self.scanning = false }
      guard !self.shuttingDown else { return }
      do {
        let detected: [SonyDiscoveredCamera] = try await self.request { self.backend.discover($0) }
        guard !self.shuttingDown else { return }
        let detectedIDs = Set(detected.map(\.id))
        let manual = self.cameras.filter { self.manuallyAddedCameraIDs.contains($0.id) && !detectedIDs.contains($0.id) }
        self.cameras = detected + manual
        self.lastSuccessfulDiscovery = self.now()
        if self.cameras.isEmpty {
          self.discoveryMessage = "No network cameras found. Check Remote Shoot Function and Wi-Fi on each FX3, and allow local network access for Ultracam. Use Rescan after the camera becomes reachable."
        }
      } catch { self.discoveryMessage = error.localizedDescription }
    }
    discoveryTask = task
    await task.value
    discoveryTask = nil
  }

  /// Sony's supported manual-IP factory is also useful when its network
  /// enumeration omits a reachable camera. Preparing reads identity only.
  func prepareCamera(address: String, macAddress: String, authentication: Bool) async -> SonyDiscoveredCamera? {
    guard !scanning, !shuttingDown else { return nil }
    scanning = true
    requestedSDKWork = true
    discoveryMessage = nil
    defer { scanning = false }
    do {
      var camera: SonyDiscoveredCamera = try await request {
        backend.prepareCamera(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
          macAddress: macAddress.trimmingCharacters(in: .whitespacesAndNewlines), authentication: authentication, completion: $0)
      }
      if camera.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
        camera.name = cameras.first { $0.id == camera.id }?.name
      }
      cameras.removeAll { $0.id == camera.id }
      manuallyAddedCameraIDs.insert(camera.id)
      cameras.append(camera)
      lastSuccessfulDiscovery = now()
      return camera
    } catch { discoveryMessage = error.localizedDescription; return nil }
  }

  func connect(_ camera: SonyDiscoveredCamera, to feedID: String, user: String, password: String,
    saveCredentials: Bool = true) async {
    let state = state(for: feedID)
    guard !state.busy, !state.connected, !removedFeeds.contains(feedID), !shuttingDown else { return }
    guard holder(of: camera.id, excluding: feedID) == nil else {
      state.message = "This Sony camera is assigned to another HDMI feed. Unassign it there first."
      return
    }
    if let saved = assignments[feedID], saved.camera.id != camera.id {
      state.message = "Unassign the saved Sony camera before choosing another camera."
      return
    }
    if let saved = assignments[feedID], saved.camera.fingerprint != camera.fingerprint {
      state.message = "The camera fingerprint differs from the saved assignment. Verify the camera, then unassign and pair again if its identity changed."
      return
    }
    guard camera.fingerprintError.isEmpty else { state.message = camera.fingerprintError; return }
    manuallyDisconnected.remove(feedID)
    state.busy = true
    requestedSDKWork = true
    state.message = nil
    connecting[feedID] = camera.id
    defer { connecting.removeValue(forKey: feedID); finishOperation(feedID) }
    do {
      // Clean up a handle retained after a physical network disconnect.
      let _: [SonyCameraProperty] = try await request { backend.disconnectFeed(feedID, completion: $0) }
      guard !removedFeeds.contains(feedID), !shuttingDown else { return }
      let properties: [SonyCameraProperty] = try await request {
        backend.connectFeed(feedID, camera: camera.id, user: user, password: password,
          fingerprint: camera.fingerprint, completion: $0)
      }
      guard !removedFeeds.contains(feedID), !shuttingDown else { return }
      assignments[feedID] = SonyFeedAssignment(camera: camera, showOverlay: assignments[feedID]?.showOverlay ?? false)
      persist()
      state.connected = true
      state.message = nil
      apply(properties, to: state, preserveInvalidation: pendingRefreshes.contains(feedID))
      if camera.authentication && saveCredentials {
        do {
          try await credentials.save(SonyCameraCredential(user: user, password: password),
            cameraID: camera.id, fingerprint: camera.fingerprint)
          markSavedCredentials(true, camera: camera)
        } catch {
          if !removedFeeds.contains(feedID), !shuttingDown {
            state.message = "Connected, but the camera sign-in could not be saved in macOS Keychain. \(error.localizedDescription)"
          }
        }
      }
    } catch { state.connected = false; state.dirty = true; state.message = error.localizedDescription }
  }

  private func credentialKey(_ camera: SonyDiscoveredCamera) -> String {
    camera.id.lowercased().replacingOccurrences(of: "-", with: ":") + "|" + camera.fingerprint
  }

  func hasSavedCredentials(for camera: SonyDiscoveredCamera) -> Bool {
    savedCredentialCameras.contains(credentialKey(camera))
  }

  private func markSavedCredentials(_ saved: Bool, camera: SonyDiscoveredCamera) {
    let key = credentialKey(camera)
    if saved { savedCredentialCameras.insert(key) } else { savedCredentialCameras.remove(key) }
    for (feedID, assignment) in assignments where credentialKey(assignment.camera) == key {
      state(for: feedID).hasSavedCredentials = saved
    }
  }

  /// Presence stays in memory; the username/password never enter preferences.
  func checkSavedCredentials(for camera: SonyDiscoveredCamera, feedID: String? = nil) async {
    guard available, camera.authentication, camera.fingerprintError.isEmpty, !camera.fingerprint.isEmpty, !shuttingDown else { return }
    do {
      let saved = try await credentials.load(cameraID: camera.id, fingerprint: camera.fingerprint) != nil
      guard !shuttingDown else { return }
      markSavedCredentials(saved, camera: camera)
    } catch {
      if let feedID, !removedFeeds.contains(feedID), !shuttingDown {
        state(for: feedID).message = error.localizedDescription
      }
    }
  }

  /// Exactly one startup pass. Concurrent callers share it; a failed/offline
  /// camera waits for an explicit Reconnect instead of starting a retry loop.
  func restoreConnections() async {
    guard available, !shuttingDown else { return }
    if let task = restoreTask { await task.value; return }
    guard !restoredAtLaunch else { return }
    restoredAtLaunch = true
    let feedIDs = assignments.keys.sorted()
    guard !feedIDs.isEmpty else { return }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      for feedID in feedIDs {
        guard !self.shuttingDown else { return }
        if !self.manuallyDisconnected.contains(feedID) { await self.reconnectAssigned(feedID, forceDiscovery: false) }
      }
    }
    restoreTask = task
    await task.value
    restoreTask = nil
  }

  func reconnect(_ feedID: String) async {
    guard !shuttingDown, !removedFeeds.contains(feedID) else { return }
    manuallyDisconnected.remove(feedID)
    await reconnectAssigned(feedID, forceDiscovery: true)
  }

  private func cancelReconnect(_ feedID: String) {
    reconnectIDs.removeValue(forKey: feedID)
    reconnectTasks.removeValue(forKey: feedID)?.cancel()
  }

  private func reconnectAssigned(_ feedID: String, forceDiscovery: Bool) async {
    if let task = reconnectTasks[feedID] { await task.value; return }
    guard let assignment = assignments[feedID], !shuttingDown, !removedFeeds.contains(feedID),
      !manuallyDisconnected.contains(feedID), !state(for: feedID).connected, !state(for: feedID).busy else { return }
    let requestID = UUID()
    reconnectIDs[feedID] = requestID
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.reconnectIDs[feedID] == requestID {
          self.reconnectIDs.removeValue(forKey: feedID)
          self.reconnectTasks.removeValue(forKey: feedID)
        }
      }
      @MainActor func current() -> Bool {
        !Task.isCancelled && !self.shuttingDown && self.reconnectIDs[feedID] == requestID &&
          !self.removedFeeds.contains(feedID) && !self.manuallyDisconnected.contains(feedID) &&
          self.assignments[feedID]?.camera.id == assignment.camera.id &&
          self.assignments[feedID]?.camera.fingerprint == assignment.camera.fingerprint
      }
      do {
        let credential: SonyCameraCredential?
        if assignment.camera.authentication {
          credential = try await self.credentials.load(cameraID: assignment.camera.id, fingerprint: assignment.camera.fingerprint)
          guard current() else { return }
          self.markSavedCredentials(credential != nil, camera: assignment.camera)
          guard credential != nil else { return }
        } else { credential = nil }
        guard current() else { return }
        await self.discover(force: forceDiscovery)
        guard current(), !self.state(for: feedID).connected, !self.state(for: feedID).busy else { return }
        guard let camera = self.cameras.first(where: { $0.id == assignment.camera.id }) else {
          self.state(for: feedID).message = "The saved Sony camera is not reachable. Use Reconnect when it is back on the network."
          return
        }
        // connect rechecks the saved fingerprint BEFORE passing any credential
        // to the SDK, so DHCP changes are fine and changed identities are not.
        await self.connect(camera, to: feedID, user: credential?.user ?? "", password: credential?.password ?? "", saveCredentials: false)
      } catch {
        guard current() else { return }
        self.state(for: feedID).message = error.localizedDescription
      }
    }
    reconnectTasks[feedID] = task
    await task.value
  }

  func connectUsingSavedCredentials(_ camera: SonyDiscoveredCamera, to feedID: String) async {
    let state = state(for: feedID)
    guard available, !shuttingDown, !removedFeeds.contains(feedID), !state.busy, !state.connected else { return }
    let assignment = assignments[feedID]
    state.busy = true
    defer { finishOperation(feedID) }
    do {
      guard let credential = try await credentials.load(cameraID: camera.id, fingerprint: camera.fingerprint) else {
        markSavedCredentials(false, camera: camera)
        state.message = "No saved camera sign-in was found. Enter its access authentication credentials."
        return
      }
      guard !shuttingDown, !removedFeeds.contains(feedID), assignments[feedID] == assignment else { return }
      markSavedCredentials(true, camera: camera)
      state.busy = false
      await connect(camera, to: feedID, user: credential.user, password: credential.password, saveCredentials: false)
      markSavedCredentials(true, camera: camera)
    } catch { state.message = error.localizedDescription }
  }

  /// Disconnect/unassign retain the camera's login. Only this explicit action
  /// deletes it from Keychain; a failed deletion never claims success.
  func forgetCredentials(_ feedID: String) async {
    let state = state(for: feedID)
    guard let camera = assignments[feedID]?.camera, !state.busy, !shuttingDown else { return }
    manuallyDisconnected.insert(feedID)
    cancelReconnect(feedID)
    state.busy = true
    defer { finishOperation(feedID) }
    do {
      try await credentials.delete(cameraID: camera.id, fingerprint: camera.fingerprint)
      guard !shuttingDown, !removedFeeds.contains(feedID) else { return }
      markSavedCredentials(false, camera: camera)
      state.busy = false
      if state.connected { await disconnect(feedID) }
      if !state.connected { state.message = "Saved camera sign-in removed from macOS Keychain." }
    } catch { state.message = error.localizedDescription }
  }

  func refresh(_ feedID: String) async {
    let state = state(for: feedID)
    guard state.connected, !state.busy, !shuttingDown else { return }
    cancelRefresh(feedID)
    state.busy = true
    state.message = nil
    let revision = state.invalidationRevision
    defer { finishOperation(feedID) }
    do {
      let properties: [SonyCameraProperty] = try await request { backend.refreshFeed(feedID, completion: $0) }
      guard !removedFeeds.contains(feedID), !shuttingDown else { return }
      apply(properties, to: state, preserveInvalidation: state.invalidationRevision != revision)
    } catch { state.dirty = true; state.message = error.localizedDescription }
  }

  func set(_ property: SonyCameraProperty, value: UInt64, feedID: String) async {
    let state = state(for: feedID)
    guard state.connected, !state.busy, !shuttingDown, property.writable,
      property.choices.contains(where: { $0.value == value }) else { return }
    state.busy = true
    state.message = nil
    defer { finishOperation(feedID) }
    do {
      let properties: [SonyCameraProperty] = try await request {
        backend.setFeed(feedID, code: property.code, value: value, completion: $0)
      }
      guard !removedFeeds.contains(feedID), !shuttingDown else { return }
      apply(properties, to: state, preserveInvalidation: pendingRefreshes.contains(feedID))
    } catch { state.dirty = true; state.message = error.localizedDescription }
  }

  func disconnect(_ feedID: String, forget: Bool = false) async {
    let state = state(for: feedID)
    guard !state.busy, !shuttingDown else { return }
    manuallyDisconnected.insert(feedID)
    cancelReconnect(feedID)
    cancelRefresh(feedID)
    state.busy = true
    requestedSDKWork = true
    defer { finishOperation(feedID) }
    do {
      let _: [SonyCameraProperty] = try await request { backend.disconnectFeed(feedID, completion: $0) }
      state.connected = false
      state.dirty = true
      state.message = nil
      if forget {
        assignments.removeValue(forKey: feedID)
        state.properties = []
        state.lastRefresh = nil
        persist()
      }
    } catch { state.message = error.localizedDescription }
  }

  func showOverlay(_ show: Bool, for feedID: String) {
    guard assignments[feedID] != nil else { return }
    assignments[feedID]?.showOverlay = show
    persist()
  }

  /// Removing a feed must also release its wireless control connection.
  func removeFeed(_ feedID: String) {
    cancelReconnect(feedID)
    manuallyDisconnected.insert(feedID)
    cancelRefresh(feedID)
    removedFeeds.insert(feedID)
    assignments.removeValue(forKey: feedID)
    persist()
    guard !shuttingDown, requestedSDKWork else {
      states[feedID]?.connected = false
      states[feedID]?.properties = []
      return
    }
    // Enqueue cleanup even during an in-flight operation. The SDK queue puts it
    // after that operation, and removedFeeds prevents its reply restoring state.
    backend.disconnectFeed(feedID) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.states[feedID]?.connected = false
        self?.states[feedID]?.properties = []
      }
    }
  }

  func reset() {
    preferencesReset = true
    for feedID in Set(assignments.keys).union(states.keys).union(connecting.keys) { removeFeed(feedID) }
    defaults.removeObject(forKey: Self.preferencesKey)
  }

  /// Quit waits for one SDK cleanup request, coalescing repeated quit events.
  /// An untouched store performs no SDK work at all. Failed disconnects are
  /// reported once; no timer or retry loop extends application termination.
  func shutdown() async -> String? {
    if let task = shutdownTask { return await task.value }
    shuttingDown = true
    for feedID in Array(reconnectTasks.keys) { cancelReconnect(feedID) }
    for feedID in Array(refreshTasks.keys) { cancelRefresh(feedID) }
    pendingRefreshes.removeAll()
    guard requestedSDKWork else { return nil }
    let task = Task { @MainActor in
      let message: String?
      do {
        let _: [SonyCameraProperty] = try await self.request { self.backend.shutdown($0) }
        self.requestedSDKWork = false
        message = nil
      } catch { message = error.localizedDescription }
      for state in self.states.values {
        state.connected = false
        state.dirty = true
        if let message { state.message = message }
      }
      return message
    }
    shutdownTask = task
    return await task.value
  }

  /// A one-shot 500 ms window combines callback bursts without postponing the
  /// read indefinitely while a dial is moving. No task runs while idle, and
  /// each feed has at most one scheduled read or in-flight operation.
  private func scheduleRefresh(_ feedID: String) {
    let state = state(for: feedID)
    guard pendingRefreshes.contains(feedID), state.connected, !state.busy,
      !shuttingDown, !removedFeeds.contains(feedID), refreshTasks[feedID] == nil else { return }
    refreshTasks[feedID] = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.refreshTasks.removeValue(forKey: feedID)
      await self.refresh(feedID)
    }
  }

  private func cancelRefresh(_ feedID: String) {
    refreshTasks.removeValue(forKey: feedID)?.cancel()
    pendingRefreshes.remove(feedID)
  }

  private func finishOperation(_ feedID: String) {
    state(for: feedID).busy = false
    scheduleRefresh(feedID)
  }

  private func apply(_ properties: [SonyCameraProperty], to state: SonyFeedState, preserveInvalidation: Bool = false) {
    state.properties = properties
    state.lastRefresh = Date()
    state.dirty = preserveInvalidation || !state.connected
  }

  private func persist() {
    guard !preferencesReset else { return }
    guard let data = try? JSONEncoder().encode(assignments) else { return }
    defaults.set(data, forKey: Self.preferencesKey)
  }

  private func request<T: Decodable & Sendable>(_ call: (@escaping @Sendable (String?, String?) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      call { json, message in
        if let message { continuation.resume(throwing: SonyControlError(message: message)); return }
        guard let data = json?.data(using: .utf8) else {
          continuation.resume(throwing: SonyControlError(message: "Sony returned no settings.")); return
        }
        do { continuation.resume(returning: try JSONDecoder().decode(T.self, from: data)) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }
}

private struct SonyControlError: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}
