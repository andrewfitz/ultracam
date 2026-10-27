import Foundation
import AppKit
import SwiftUI

private actor MemoryCredentials: SonyCameraCredentialStoring {
  enum Failure: LocalizedError {
    case unavailable
    var errorDescription: String? { "Test Keychain unavailable" }
  }
  private var values: [String: SonyCameraCredential] = [:]
  private var loadFailure = false
  private var saveFailure = false
  private var deleteFailure = false
  private var holdDelete = false
  private var pendingDelete: CheckedContinuation<Void, Error>?
  private(set) var loads = 0
  private(set) var saves = 0
  private(set) var deletes = 0
  private func key(_ cameraID: String, _ fingerprint: String) -> String { cameraID.lowercased() + "|" + fingerprint }
  func load(cameraID: String, fingerprint: String) async throws -> SonyCameraCredential? {
    loads += 1
    if loadFailure { throw Failure.unavailable }
    return values[key(cameraID, fingerprint)]
  }
  func save(_ credential: SonyCameraCredential, cameraID: String, fingerprint: String) async throws {
    saves += 1
    if saveFailure { throw Failure.unavailable }
    values[key(cameraID, fingerprint)] = credential
  }
  func delete(cameraID: String, fingerprint: String) async throws {
    deletes += 1
    if holdDelete {
      holdDelete = false
      try await withCheckedThrowingContinuation { pendingDelete = $0 }
    }
    if deleteFailure { throw Failure.unavailable }
    values.removeValue(forKey: key(cameraID, fingerprint))
  }
  func holdNextDeletion() { holdDelete = true }
  func deletionIsPending() -> Bool { pendingDelete != nil }
  func failPendingDeletion() {
    let reply = pendingDelete
    pendingDelete = nil
    reply?.resume(throwing: Failure.unavailable)
  }
  func seed(_ credential: SonyCameraCredential, for camera: SonyDiscoveredCamera) {
    values[key(camera.id, camera.fingerprint)] = credential
  }
  func stored(for camera: SonyDiscoveredCamera) -> SonyCameraCredential? { values[key(camera.id, camera.fingerprint)] }
  func failures(load: Bool = false, save: Bool = false, delete: Bool = false) {
    loadFailure = load; saveFailure = save; deleteFailure = delete
  }
}

private final class SonyStub: UCSonyCameraControl {
  var discoveryCalls = 0
  var discoveredCameras = [SonyChecks.camera]
  var holdNextDiscovery = false
  var pendingDiscovery: UCSonyReply?
  var pendingDiscoveryJSON: String?
  var prepareCalls = 0
  var connectCalls = 0
  var failConnect = false
  var connectedUsers: [String] = []
  var connectedPasswords: [String] = []
  var connectedCameraIDs: [String] = []
  var connectedFeedIDs: [String] = []
  var refreshCalls = 0
  var refreshCallsByFeed: [String: Int] = [:]
  var failRefresh = false
  var setCalls = 0
  var disconnectCalls = 0
  var shutdownCalls = 0
  var holdShutdown = false
  var failShutdown = false
  var pendingShutdown: UCSonyReply?
  var failWrite = false
  var holdConnect = false
  var pendingConnect: UCSonyReply?
  var holdNextDisconnect = false
  var pendingDisconnect: UCSonyReply?
  var holdNextRefresh = false
  var pendingRefresh: UCSonyReply?
  var pendingRefreshJSON: String?
  var holdNextSet = false
  var pendingSet: UCSonyReply?
  var pendingSetValue: UInt64?
  var properties = [SonyCameraProperty(id: "iso", title: "ISO", code: 0x104, value: 800,
    label: "800", writable: true, choices: [.init(value: 800, label: "800"), .init(value: 12800, label: "12800")])]
  override var available: Bool { true }
  private func json<T: Encodable>(_ value: T) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
  override func discover(_ reply: @escaping UCSonyReply) {
    discoveryCalls += 1
    if holdNextDiscovery {
      holdNextDiscovery = false
      pendingDiscovery = reply
      pendingDiscoveryJSON = json(discoveredCameras)
      return
    }
    reply(json(discoveredCameras), nil)
  }
  override func prepareCamera(address: String, macAddress: String, authentication: Bool, completion reply: @escaping UCSonyReply) {
    prepareCalls += 1
    var camera = SonyChecks.camera
    camera.address = address
    camera.id = macAddress.lowercased()
    camera.authentication = authentication
    camera.name = nil // The manual factory may not know SSDP's friendly name.
    reply(json(camera), nil)
  }
  override func connectFeed(_ feedID: String, camera: String, user: String, password: String,
    fingerprint: String, completion reply: @escaping UCSonyReply) {
    connectCalls += 1
    connectedUsers.append(user)
    connectedPasswords.append(password)
    connectedCameraIDs.append(camera)
    connectedFeedIDs.append(feedID)
    if failConnect { reply(nil, "Camera authentication rejected"); return }
    if holdConnect { pendingConnect = reply } else { reply(json(properties), nil) }
  }
  override func refreshFeed(_ feedID: String, completion reply: @escaping UCSonyReply) {
    refreshCalls += 1
    refreshCallsByFeed[feedID, default: 0] += 1
    if holdNextRefresh {
      holdNextRefresh = false
      pendingRefresh = reply
      pendingRefreshJSON = json(properties)
      return
    }
    if failRefresh { reply(nil, "Camera settings are temporarily unavailable"); return }
    reply(json(properties), nil)
  }
  override func setFeed(_ feedID: String, code: UInt32, value: UInt64, completion reply: @escaping UCSonyReply) {
    setCalls += 1
    if holdNextSet {
      holdNextSet = false
      pendingSet = reply
      pendingSetValue = value
      return
    }
    if failWrite { reply(nil, "Camera rejected the setting"); return }
    properties[0].value = value
    properties[0].label = String(value)
    reply(json(properties), nil)
  }
  override func disconnectFeed(_ feedID: String, completion reply: @escaping UCSonyReply) {
    disconnectCalls += 1
    if holdNextDisconnect {
      holdNextDisconnect = false
      pendingDisconnect = reply
      return
    }
    reply("[]", nil)
  }
  override func shutdown(_ reply: @escaping UCSonyReply) {
    shutdownCalls += 1
    if holdShutdown { pendingShutdown = reply; return }
    reply(failShutdown ? nil : "[]", failShutdown ? "Disconnect acknowledgement pending" : nil)
  }
  func finishShutdown() { pendingShutdown?("[]", nil); pendingShutdown = nil }
  func finishConnection() { pendingConnect?(json(properties), nil); pendingConnect = nil }
  func finishDiscovery() { pendingDiscovery?(pendingDiscoveryJSON, nil); pendingDiscovery = nil; pendingDiscoveryJSON = nil }
  func finishDisconnect() { pendingDisconnect?("[]", nil); pendingDisconnect = nil }
  func finishRefresh() {
    pendingRefresh?(pendingRefreshJSON, nil)
    pendingRefresh = nil
    pendingRefreshJSON = nil
  }
  func finishSet() {
    if let value = pendingSetValue { properties[0].value = value; properties[0].label = String(value) }
    pendingSet?(json(properties), nil)
    pendingSet = nil
    pendingSetValue = nil
  }
}

@main private enum SonyChecks {
  static let camera = SonyDiscoveredCamera(id: "aa:bb:cc:dd:ee:ff", model: "ILME-FX3", address: "192.168.1.20",
    authentication: true, fingerprint: "test-camera-identity", fingerprintError: "", name: "ILME-FX3:A")

  @MainActor static func main() async {
    let suite = "org.ultracam.sony-checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    await discoveryBehavior(defaults: defaults)
    await credentialBehavior()
    await shutdownBehavior()
    let backend = SonyStub()
    backend.properties += [
      .init(id: "aperture", title: "Aperture", code: 0x100, value: 280, label: "ƒ/2.8", writable: true,
        choices: [.init(value: 280, label: "ƒ/2.8"), .init(value: 400, label: "ƒ/4")]),
      .init(id: "shutter", title: "Shutter speed", code: 0x103, value: 65586, label: "1/50 s", writable: true,
        choices: [.init(value: 65586, label: "1/50 s"), .init(value: 65636, label: "1/100 s")]),
      .init(id: "exposure", title: "Exposure compensation", code: 0x101, value: 0, label: "+0.00 EV", writable: false, choices: []),
      .init(id: "whiteBalance", title: "White balance", code: 0x109, value: 256, label: "Color temperature", writable: true,
        choices: [.init(value: 256, label: "Color temperature"), .init(value: 0, label: "Auto")]),
      .init(id: "temperature", title: "Color temperature", code: 0x116, value: 5600, label: "5600 K", writable: true,
        choices: [.init(value: 3200, label: "3200 K"), .init(value: 5600, label: "5600 K")]),
      .init(id: "focusMode", title: "Focus mode", code: 0x10A, value: 3, label: "AF-C", writable: true,
        choices: [.init(value: 3, label: "AF-C"), .init(value: 1, label: "MF")]),
    ]
    let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: MemoryCredentials())
    expect(backend.discoveryCalls == 0 && backend.connectCalls == 0, "initialization performs no camera work")
    await store.discover()
    expect(store.cameras.count == 1 && backend.discoveryCalls == 1, "explicit discovery")
    let manualCamera = await store.prepareCamera(address: "192.168.1.22", macAddress: "AA:BB:CC:DD:EE:FF", authentication: true)
    expect(manualCamera?.id == camera.id && store.cameras.contains { $0.id == manualCamera?.id }, "manual IP preparation adds camera candidate")
    expect(manualCamera?.displayName == "ILME-FX3:A", "manual recovery preserves a known friendly name")
    expect(backend.prepareCalls == 1 && backend.connectCalls == 0 && backend.refreshCalls == 0 && backend.setCalls == 0,
      "checking a manual camera does not connect, read settings or change settings")
    await store.connect(manualCamera ?? camera, to: "hdmi-a", user: "camera-user", password: "secret-camera-password")
    expect(store.state(for: "hdmi-a").connected && store.state(for: "hdmi-a").properties.first?.value == 800, "connection reads real snapshot")
    store.showOverlay(true, for: "hdmi-a")
    await renderControls(store)
    let saved = String(data: defaults.data(forKey: SonyCameraStore.preferencesKey)!, encoding: .utf8)!
    expect(!saved.contains("secret-camera-password") && !saved.contains("camera-user"), "credentials never enter UserDefaults")
    let restored = SonyCameraStore(defaults: defaults, backend: SonyStub(), credentials: MemoryCredentials())
    expect(restored.assignment(for: "hdmi-a")?.showOverlay == true && !restored.state(for: "hdmi-a").connected, "assignment persists without connecting on launch")
    await store.connect(camera, to: "hdmi-b", user: "", password: "")
    expect(backend.connectCalls == 1 && store.assignment(for: "hdmi-b") == nil, "duplicate assignment refused")
    backend.eventHandler?("hdmi-a", "changed", "changed")
    await drain()
    expect(store.state(for: "hdmi-a").dirty && backend.refreshCalls == 0, "notifications mark cached values stale before the coalesced read")
    await store.refresh("hdmi-a")
    expect(!store.state(for: "hdmi-a").dirty && backend.refreshCalls == 1, "manual refresh clears invalidation")
    backend.holdNextRefresh = true
    let oldRefresh = Task { await store.refresh("hdmi-a") }
    for _ in 0..<100 { if backend.pendingRefresh != nil { break }; await Task.yield() }
    expect(backend.pendingRefresh != nil, "test has a pending old snapshot")
    backend.eventHandler?("hdmi-a", "changed", "Camera changed after snapshot read")
    backend.finishRefresh()
    await oldRefresh.value
    expect(store.state(for: "hdmi-a").dirty && store.state(for: "hdmi-a").properties[0].value == 800,
      "notification during refresh keeps the returned old snapshot marked stale")
    await store.refresh("hdmi-a")
    expect(!store.state(for: "hdmi-a").dirty, "a subsequent explicit read clears the newer invalidation")
    let property = store.state(for: "hdmi-a").properties[0]
    await store.set(property, value: 999, feedID: "hdmi-a")
    expect(backend.setCalls == 0, "unsupported values are refused")
    await store.set(property, value: 12800, feedID: "hdmi-a")
    expect(store.state(for: "hdmi-a").properties[0].value == 12800, "confirmed write updates cache")
    backend.failWrite = true
    await store.set(property, value: 800, feedID: "hdmi-a")
    expect(store.state(for: "hdmi-a").properties[0].value == 12800 && store.state(for: "hdmi-a").dirty,
      "failed writes retain last confirmed value and mark stale")
    backend.eventHandler?("hdmi-a", "disconnected", "Wi-Fi lost")
    await drain()
    expect(!store.state(for: "hdmi-a").connected && store.state(for: "hdmi-a").cacheStatus.contains("cached"), "disconnect labels cache honestly")
    var changedIdentity = camera
    changedIdentity.fingerprint = "different-camera-key"
    await store.connect(changedIdentity, to: "hdmi-a", user: "", password: "")
    expect(backend.connectCalls == 1, "changed camera fingerprint refused")
    var moved = camera
    moved.address = "192.168.1.88"
    await store.connect(moved, to: "hdmi-a", user: "", password: "")
    expect(backend.connectCalls == 2 && store.assignment(for: "hdmi-a")?.camera.address == moved.address, "DHCP changes preserve stable assignment")
    await store.disconnect("hdmi-a", forget: true)
    expect(store.assignment(for: "hdmi-a") == nil && store.state(for: "hdmi-a").properties.isEmpty, "unassign clears cache")
    backend.holdNextDisconnect = true
    let cleanupConnection = Task { await store.connect(camera, to: "removed-during-cleanup", user: "", password: "") }
    for _ in 0..<100 { if backend.pendingDisconnect != nil { break }; await Task.yield() }
    expect(backend.pendingDisconnect != nil, "test has a pending initial disconnect")
    let connectionsBeforeRemoval = backend.connectCalls
    store.removeFeed("removed-during-cleanup")
    backend.finishDisconnect()
    await cleanupConnection.value
    expect(backend.connectCalls == connectionsBeforeRemoval && store.assignment(for: "removed-during-cleanup") == nil,
      "removal during initial cleanup cannot start an orphan connection")
    backend.holdConnect = true
    let connection = Task { await store.connect(camera, to: "removed-feed", user: "", password: "") }
    for _ in 0..<100 { if backend.pendingConnect != nil { break }; await Task.yield() }
    expect(backend.pendingConnect != nil, "test has a pending connection")
    let closes = backend.disconnectCalls
    store.removeFeed("removed-feed")
    expect(backend.disconnectCalls == closes + 1, "removal enqueues disconnect during connection")
    backend.finishConnection()
    await connection.value
    expect(store.assignment(for: "removed-feed") == nil && !store.state(for: "removed-feed").connected, "late connection cannot restore removed feed")
    store.reset()
    expect(defaults.data(forKey: SonyCameraStore.preferencesKey) == nil, "reset removes saved Sony assignments")
    print("Sony store checks passed: pairing, persistence, cache invalidation, writes, identity, disconnect and removal races.")
  }

  @MainActor private static func credentialBehavior() async {
    var suites: [String] = []
    func freshDefaults() -> UserDefaults {
      let suite = "org.ultracam.sony-credential-checks.\(UUID().uuidString)"
      suites.append(suite)
      return UserDefaults(suiteName: suite)!
    }
    defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
    func saveAssignment(_ defaults: UserDefaults, camera assigned: SonyDiscoveredCamera = camera, feed: String = "saved-feed") {
      defaults.set(try! JSONEncoder().encode([feed: SonyFeedAssignment(camera: assigned)]), forKey: SonyCameraStore.preferencesKey)
    }
    let secret = SonyCameraCredential(user: "persisted-camera-user", password: "persisted-camera-secret")
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      await vault.seed(secret, for: camera)
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.restoreConnections()
      let loads = await vault.loads
      expect(loads == 0 && backend.discoveryCalls == 0 && backend.connectCalls == 0,
        "credentials alone never trigger a scan without a saved HDMI assignment")
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      saveAssignment(defaults)
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.restoreConnections()
      expect(backend.discoveryCalls == 0 && backend.connectCalls == 0,
        "saved assignments without stored credentials perform no startup network work")
      expect(!store.state(for: "saved-feed").hasSavedCredentials, "missing credentials remain an explicit disconnected state")
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      let first = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await first.connect(camera, to: "saved-feed", user: secret.user, password: secret.password)
      let stored = await vault.stored(for: camera)
      expect(stored == secret && first.state(for: "saved-feed").hasSavedCredentials,
        "successful explicit authentication saves both username and password in the injected credential vault")
      let preferences = String(data: defaults.data(forKey: SonyCameraStore.preferencesKey)!, encoding: .utf8)!
      expect(!preferences.contains(secret.user) && !preferences.contains(secret.password),
        "persisted HDMI assignments contain no username or password")
      _ = await first.shutdown()
      let nextBackend = SonyStub()
      var movedCamera = camera
      movedCamera.address = "192.168.1.99"
      nextBackend.discoveredCameras = [movedCamera]
      nextBackend.holdNextDiscovery = true
      let next = SonyCameraStore(defaults: defaults, backend: nextBackend, credentials: vault)
      let restoration = Task { await next.restoreConnections() }
      await eventually("credential restoration starts one discovery") { nextBackend.pendingDiscovery != nil }
      let duplicate = Task { await next.restoreConnections() }
      await drain()
      expect(nextBackend.discoveryCalls == 1 && nextBackend.connectCalls == 0,
        "concurrent startup restoration shares one bounded scan")
      nextBackend.finishDiscovery()
      await restoration.value; await duplicate.value
      expect(next.state(for: "saved-feed").connected && nextBackend.connectCalls == 1 &&
        nextBackend.connectedUsers == [secret.user] && nextBackend.connectedPasswords == [secret.password],
        "a new store reconnects with the persisted encrypted payload after an app session or install update")
      expect(next.assignment(for: "saved-feed")?.camera.address == movedCamera.address,
        "saved reconnection matches stable MAC and fingerprint while accepting DHCP address changes")
      await next.restoreConnections()
      expect(nextBackend.discoveryCalls == 1 && nextBackend.connectCalls == 1,
        "startup restoration runs once without polling or repeated connection attempts")
      await next.disconnect("saved-feed")
      await next.restoreConnections()
      let retained = await vault.stored(for: camera)
      expect(retained == secret && !next.state(for: "saved-feed").connected && nextBackend.connectCalls == 1,
        "manual disconnect retains the secret and suppresses automatic reconnection for this session")
      await next.reconnect("saved-feed")
      expect(next.state(for: "saved-feed").connected && nextBackend.connectCalls == 2,
        "explicit reconnect consumes saved credentials without username/password reentry")
      await next.disconnect("saved-feed", forget: true)
      let retainedAfterUnassign = await vault.stored(for: camera)
      expect(retainedAfterUnassign == secret && next.assignment(for: "saved-feed") == nil,
        "unassigning an HDMI feed preserves that camera's credentials for reassignment")
      await next.checkSavedCredentials(for: movedCamera, feedID: nil)
      expect(next.hasSavedCredentials(for: movedCamera), "camera selection can identify saved credentials without exposing their contents")
      await next.connectUsingSavedCredentials(movedCamera, to: "new-feed")
      expect(next.state(for: "new-feed").connected && nextBackend.connectCalls == 3,
        "a remembered camera can be assigned to a different HDMI feed without reentering credentials")
      await next.forgetCredentials("new-feed")
      let deleted = await vault.stored(for: camera)
      expect(deleted == nil && next.assignment(for: "new-feed") != nil && !next.state(for: "new-feed").connected &&
        !next.state(for: "new-feed").hasSavedCredentials && !next.hasSavedCredentials(for: camera),
        "forgetting deletes the secret and disconnects its live session while retaining the HDMI assignment")
      let callsAfterForget = nextBackend.connectCalls
      await next.reconnect("new-feed")
      expect(nextBackend.connectCalls == callsAfterForget, "forgetting requires fresh credentials before another authenticated connection")
      _ = await next.shutdown()
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      var secondCamera = camera
      secondCamera.id = "aa:bb:cc:dd:ee:22"
      secondCamera.fingerprint = "second-camera-identity"
      secondCamera.name = "ILME-FX3:B"
      let secondSecret = SonyCameraCredential(user: "second-camera-user", password: "second-camera-secret")
      defaults.set(try! JSONEncoder().encode(["first-hdmi": SonyFeedAssignment(camera: camera),
        "second-hdmi": SonyFeedAssignment(camera: secondCamera)]), forKey: SonyCameraStore.preferencesKey)
      await vault.seed(secret, for: camera)
      await vault.seed(secondSecret, for: secondCamera)
      backend.discoveredCameras = [secondCamera, camera]
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.restoreConnections()
      expect(backend.discoveryCalls == 1 && backend.connectCalls == 2 &&
        store.state(for: "first-hdmi").connected && store.state(for: "second-hdmi").connected,
        "two remembered HDMI assignments share one startup discovery")
      for index in backend.connectedFeedIDs.indices {
        let first = backend.connectedFeedIDs[index] == "first-hdmi"
        expect(backend.connectedCameraIDs[index] == (first ? camera.id : secondCamera.id) &&
          backend.connectedUsers[index] == (first ? secret.user : secondSecret.user) &&
          backend.connectedPasswords[index] == (first ? secret.password : secondSecret.password),
          "each restored HDMI feed receives only its own pinned camera's credentials")
      }
      _ = await store.shutdown()
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      backend.failConnect = true
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.connect(camera, to: "failed-feed", user: secret.user, password: secret.password)
      let saves = await vault.saves
      expect(saves == 0 && !store.state(for: "failed-feed").connected,
        "rejected authentication never saves credentials")
      backend.failConnect = false
      await vault.failures(save: true)
      await store.connect(camera, to: "failed-feed", user: secret.user, password: secret.password)
      let absent = await vault.stored(for: camera)
      expect(store.state(for: "failed-feed").connected && absent == nil &&
        store.state(for: "failed-feed").message?.localizedCaseInsensitiveContains("Keychain") == true,
        "a Keychain save failure leaves the successful camera session connected and explains persistence failure")
      _ = await store.shutdown()
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      saveAssignment(defaults)
      await vault.seed(secret, for: camera)
      await vault.failures(load: true)
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.restoreConnections()
      expect(backend.discoveryCalls == 0 && backend.connectCalls == 0 &&
        store.state(for: "saved-feed").message?.localizedCaseInsensitiveContains("Keychain") == true,
        "a locked or unavailable Keychain never starts discovery or sends empty replacement credentials")
      await store.restoreConnections()
      expect(backend.discoveryCalls == 0, "Keychain errors do not start a retry loop")
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      saveAssignment(defaults)
      await vault.seed(secret, for: camera)
      var replacement = camera
      replacement.fingerprint = "replacement-camera-identity"
      backend.discoveredCameras = [replacement]
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.restoreConnections()
      expect(backend.discoveryCalls == 1 && backend.connectCalls == 0 && !store.state(for: "saved-feed").connected,
        "startup restoration never sends an old secret to a changed fingerprint at the same MAC")
      await store.checkSavedCredentials(for: replacement, feedID: nil)
      expect(!store.hasSavedCredentials(for: replacement), "saved-credential availability is pinned to the fingerprint as well as MAC")
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      saveAssignment(defaults)
      await vault.seed(secret, for: camera)
      backend.discoveredCameras = []
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.restoreConnections()
      await store.restoreConnections()
      await pause(0.1)
      expect(backend.discoveryCalls == 1 && backend.connectCalls == 0,
        "an offline saved camera receives one startup scan with no automatic retry")
      backend.discoveredCameras = [camera]
      await store.reconnect("saved-feed")
      expect(backend.discoveryCalls == 2 && store.state(for: "saved-feed").connected,
        "explicit reconnect rescans after the camera becomes reachable")
      await vault.failures(delete: true)
      await store.forgetCredentials("saved-feed")
      let retained = await vault.stored(for: camera)
      expect(retained == secret && store.state(for: "saved-feed").message?.localizedCaseInsensitiveContains("Keychain") == true,
        "failed credential deletion reports an error instead of falsely claiming the secret was forgotten")
      _ = await store.shutdown()
    }
    do {
      let defaults = freshDefaults(), backend = SonyStub(), vault = MemoryCredentials()
      let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: vault)
      await store.connect(camera, to: "delete-failure-feed", user: secret.user, password: secret.password)
      await vault.holdNextDeletion()
      let forgetting = Task { await store.forgetCredentials("delete-failure-feed") }
      for _ in 0..<200 {
        if await vault.deletionIsPending() { break }
        await pause(0.01)
      }
      let deletionPending = await vault.deletionIsPending()
      expect(deletionPending && store.state(for: "delete-failure-feed").busy,
        "test holds credential deletion while the feed is busy")
      backend.eventHandler?("delete-failure-feed", "changed", "ISO changed during credential deletion")
      await pause(0.65)
      expect(backend.refreshCalls == 0 && store.state(for: "delete-failure-feed").dirty,
        "a settings callback cannot overlap an in-flight credential deletion")
      await vault.failPendingDeletion()
      await forgetting.value
      expect(store.state(for: "delete-failure-feed").connected &&
        store.state(for: "delete-failure-feed").message?.localizedCaseInsensitiveContains("Keychain") == true,
        "failed deletion preserves the live session and reports the storage failure")
      await eventually("a callback held behind failed deletion refreshes after the busy operation ends") {
        backend.refreshCalls == 1 && !store.state(for: "delete-failure-feed").dirty
      }
      await pause(0.65)
      let retained = await vault.stored(for: camera)
      expect(backend.refreshCalls == 1 && retained == secret,
        "failed deletion drains one pending refresh without retrying deletion or polling")
      _ = await store.shutdown()
    }
    print("Sony credential checks passed: isolated vault persistence, startup restoration, pinning, explicit reconnect/forget and failure handling.")
  }

  @MainActor private static func pause(_ seconds: Double = 0.65) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
  @MainActor private static func eventually(_ message: String, _ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline { await pause(0.01) }
    expect(condition(), message)
  }
  @MainActor private static func drain() async { for _ in 0..<20 { await Task.yield() } }
  @MainActor private static func shutdownBehavior() async {
    let suite = "org.ultracam.sony-shutdown-checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let idleBackend = SonyStub()
    let idle = SonyCameraStore(defaults: defaults, backend: idleBackend, credentials: MemoryCredentials())
    idle.removeFeed("never-connected")
    let idleResult = await idle.shutdown()
    expect(idleResult == nil && idleBackend.shutdownCalls == 0 && idleBackend.disconnectCalls == 0,
      "quitting or removing an untouched camera performs no SDK work")

    let backend = SonyStub()
    let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: MemoryCredentials())
    await store.discover()
    await store.connect(camera, to: "quit-feed", user: "test-user", password: "test-password")
    expect(store.needsShutdown && store.state(for: "quit-feed").connected, "SDK activity requires graceful shutdown")
    let saved = defaults.data(forKey: SonyCameraStore.preferencesKey)
    backend.holdShutdown = true
    let first = Task { await store.shutdown() }
    for _ in 0..<100 { if backend.pendingShutdown != nil { break }; await Task.yield() }
    expect(backend.pendingShutdown != nil, "quit waits for pending SDK cleanup")
    let second = Task { await store.shutdown() }
    await drain()
    await store.discover()
    await store.refresh("quit-feed")
    await store.connect(camera, to: "quit-feed", user: "", password: "")
    expect(backend.shutdownCalls == 1 && backend.discoveryCalls == 1 && backend.refreshCalls == 0 && backend.connectCalls == 1,
      "concurrent quits share cleanup and prevent new camera operations")
    backend.finishShutdown()
    let firstResult = await first.value
    let secondResult = await second.value
    expect(firstResult == nil && secondResult == nil && !store.needsShutdown && !store.state(for: "quit-feed").connected,
      "graceful cleanup completes all quit waiters and disconnects UI state")
    _ = await store.shutdown()
    expect(backend.shutdownCalls == 1 && defaults.data(forKey: SonyCameraStore.preferencesKey) == saved,
      "completed shutdown is not repeated and preserves the saved assignment")

    let failedBackend = SonyStub()
    let failed = SonyCameraStore(defaults: defaults, backend: failedBackend, credentials: MemoryCredentials())
    await failed.discover()
    failedBackend.failShutdown = true
    let failure = await failed.shutdown()
    let repeatedFailure = await failed.shutdown()
    expect(failure == "Disconnect acknowledgement pending" && repeatedFailure == failure && failedBackend.shutdownCalls == 1,
      "shutdown reports pending disconnect once without retries")

    let pendingBackend = SonyStub()
    let pending = SonyCameraStore(defaults: defaults, backend: pendingBackend, credentials: MemoryCredentials())
    pendingBackend.holdNextDisconnect = true
    let connection = Task { await pending.connect(camera, to: "quit-feed", user: "", password: "") }
    for _ in 0..<100 { if pendingBackend.pendingDisconnect != nil { break }; await Task.yield() }
    _ = await pending.shutdown()
    pendingBackend.finishDisconnect()
    await connection.value
    expect(pendingBackend.connectCalls == 0 && pendingBackend.shutdownCalls == 1,
      "quitting during connection cleanup cannot start a late orphan connection")
  }
  @MainActor private static func discoveryBehavior(defaults: UserDefaults) async {
    var clock = Date(timeIntervalSince1970: 1000)
    let backend = SonyStub()
    let store = SonyCameraStore(defaults: defaults, backend: backend, credentials: MemoryCredentials(), now: { clock })
    expect(backend.discoveryCalls == 0, "store initialization performs no automatic network work")
    await store.discoverIfNeeded()
    expect(backend.discoveryCalls == 1 && store.cameras[0].displayName == "ILME-FX3:A", "first panel open detects named cameras")
    await store.discoverIfNeeded()
    clock.addTimeInterval(29)
    await store.discoverIfNeeded()
    expect(backend.discoveryCalls == 1, "reopening panels reuses a fresh discovery cache")
    clock.addTimeInterval(2)
    await store.discoverIfNeeded()
    expect(backend.discoveryCalls == 2, "an expired cache scans only when another panel opens")
    await store.discover()
    expect(backend.discoveryCalls == 3, "explicit Rescan bypasses a fresh cache")
    clock.addTimeInterval(31)
    backend.holdNextDiscovery = true
    let first = Task { await store.discoverIfNeeded() }
    for _ in 0..<100 { if backend.pendingDiscovery != nil { break }; await Task.yield() }
    expect(backend.pendingDiscovery != nil, "test has a pending discovery")
    let second = Task { await store.discoverIfNeeded() }
    let forced = Task { await store.discover() }
    await drain()
    expect(backend.discoveryCalls == 4 && store.scanning, "concurrent panel opens and Rescan share one in-flight discovery")
    backend.finishDiscovery()
    await first.value; await second.value; await forced.value
    expect(!store.scanning && backend.discoveryCalls == 4, "all discovery waiters complete without a follow-up scan")
    backend.eventHandler?("unconnected-feed", "disconnected", "Wi-Fi lost")
    await store.discoverIfNeeded()
    expect(backend.discoveryCalls == 5, "disconnect invalidation allows detection on the next panel open")
    backend.discoveredCameras = []
    await store.discover()
    await store.discoverIfNeeded()
    expect(backend.discoveryCalls == 6 && store.cameras.isEmpty, "a fresh empty scan is cached to avoid repeated scans")
    var secondCamera = camera
    secondCamera.id = "aa:bb:cc:dd:ee:21"
    secondCamera.address = "192.168.1.21"
    secondCamera.name = "ILME-FX3:B"
    backend.discoveredCameras = [camera, secondCamera]
    await store.discover()
    let manual = await store.prepareCamera(address: "192.168.1.22", macAddress: "aa:bb:cc:dd:ee:22", authentication: true)
    expect(store.cameras.count == 3 && store.cameras.contains { $0.displayName == "ILME-FX3:A" } &&
      store.cameras.contains { $0.displayName == "ILME-FX3:B" }, "manual recovery preserves both automatically detected named cameras")
    await store.discover()
    expect(store.cameras.count == 3 && store.cameras.contains { $0.id == manual?.id }, "manual recovery candidate survives automatic detection")
    expect(backend.connectCalls == 0 && backend.refreshCalls == 0 && backend.setCalls == 0,
      "automatic detection never connects or accesses camera settings")
    var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as! [String: Any]
    legacy.removeValue(forKey: "name")
    let decoded = try! JSONDecoder().decode(SonyDiscoveredCamera.self, from: JSONSerialization.data(withJSONObject: legacy))
    expect(decoded.name == nil && decoded.displayName == camera.model, "saved cameras without friendly names remain compatible")
  }

  @MainActor private static func renderControls(_ store: SonyCameraStore) async {
    guard CommandLine.arguments.count > 1 else { return }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()
    // SwiftUI lazily builds its accessibility tree when an assistive client is
    // active. Match the app's existing UI verifier without requesting AX access.
    NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for dark in [false, true] {
      let host = HostedView(UISonyCameraSettings(feedID: "hdmi-a", name: "Camera 1", store: store),
        size: CGSize(width: 640, height: 690), dark: dark)
      await drain()
      let nodes = Accessibility.nodes(in: host.host)
      expect(nodes.contains { $0.text.contains("Refresh") }, "settings sheet exposes refresh to accessibility")
      expect(nodes.contains { $0.text.contains("Show camera settings") }, "settings sheet exposes overlay toggle")
      expect(nodes.contains { $0.text.contains("ILME-FX3:A") }, "connected camera uses its friendly name")
      guard let rep = host.render(), let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not render Sony settings") }
      try! png.write(to: output.appendingPathComponent("sony-settings-\(dark ? "dark" : "light").png"))
      host.close()
    }
    let manualSuite = "org.ultracam.sony-ui-manual.\(UUID().uuidString)"
    let manualDefaults = UserDefaults(suiteName: manualSuite)!
    defer { manualDefaults.removePersistentDomain(forName: manualSuite) }
    let manualBackend = SonyStub()
    let manualStore = SonyCameraStore(defaults: manualDefaults, backend: manualBackend, credentials: MemoryCredentials())
    for dark in [false, true] {
      let host = HostedView(UISonyCameraSettings(feedID: "new-feed", name: "Camera 2", store: manualStore),
        size: CGSize(width: 640, height: 690), dark: dark)
      await drain()
      let nodes = Accessibility.nodes(in: host.host)
      expect(manualBackend.discoveryCalls == 1, "settings sheets automatically detect once and reuse the cache")
      expect(nodes.contains { $0.text.contains("Rescan") }, "automatic detection retains an explicit Rescan control")
      if let picker = nodes.first(where: { $0.text.contains("Sony Wi-Fi camera") }) {
        expect(!picker.text.contains(camera.address) && !picker.text.contains(camera.id),
          "uniquely named camera selection keeps IP and MAC out of the primary label")
      } else { fatalError("Detected camera picker is missing") }
      if let rep = host.render(), let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: output.appendingPathComponent("sony-detection-\(dark ? "dark" : "light").png"))
      }
      guard let disclosure = nodes.first(where: { $0.text.contains("Add FX3 by IP") }) else { fatalError("Manual IP disclosure is missing") }
      expect(Accessibility.press(disclosure), "manual IP disclosure opens through accessibility")
      guard let rep = host.render(), let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not render manual IP controls") }
      let expanded = Accessibility.nodes(in: host.host)
      expect(expanded.contains { $0.text.contains("Camera IP address") }, "manual IP address field has an accessible label")
      expect(expanded.contains { $0.text.contains("Camera MAC address") }, "manual MAC address field has an accessible label")
      expect(expanded.contains { $0.text.contains("Check Camera") }, "manual identity check is available")
      try! png.write(to: output.appendingPathComponent("sony-manual-ip-\(dark ? "dark" : "light").png"))
      host.close()
    }
    let overlay = HostedView(
      Color.gray.overlay(alignment: .bottomLeading) { UISonySettingsOverlay(feedID: "hdmi-a", store: store).padding() },
      size: CGSize(width: 640, height: 360), dark: true)
    expect(Accessibility.nodes(in: overlay.host).contains { $0.text.contains("ISO 800") }, "overlay exposes cached ISO")
    if let rep = overlay.render(), let png = rep.representation(using: .png, properties: [:]) {
      try! png.write(to: output.appendingPathComponent("sony-overlay.png"))
    }
    overlay.close()
    print("Sony settings rendered in light/dark and cached overlay verified.")
  }
  @MainActor private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError("FAIL: \(message)") }
  }
}
