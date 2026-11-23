#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@MainActor private final class MemoryControlAssignments: CameraControlAssignmentPersisting {
    var value: CameraControlAssignmentSnapshot = .init()
    func load() throws -> CameraControlAssignmentSnapshot { value }
    func save(_ snapshot: CameraControlAssignmentSnapshot) throws { value = snapshot }
}
private actor MemoryControlCredentials: CameraControlCredentialStoring {
    var loads = 0
    var saves = 0
    var failSave = false
    var saved: ControlCredentials?
    var holdLoad = false
    var pendingLoad: CheckedContinuation<ControlCredentials?, Never>?
    var holdDelete = false
    var pendingDelete: CheckedContinuation<Void, Never>?
    func suspendLoad(with credentials: ControlCredentials) { saved = credentials; holdLoad = true }
    func resumeLoad() { pendingLoad?.resume(returning: saved); pendingLoad = nil }
    func load(service: String, account: String) async throws -> ControlCredentials? { loads += 1; if holdLoad { return await withCheckedContinuation { pendingLoad = $0 } }; return saved }
    func save(_ credentials: ControlCredentials, service: String, account: String) async throws {
        saves += 1
        if failSave { throw ControlError(code: .unavailable, retryable: true, message: "Synthetic vault unavailable") }
        saved = credentials
    }
    func saveCount() -> Int { saves }
    func setSaveFailure(_ value: Bool) { failSave = value }
    func suspendDelete() { holdDelete = true }
    func deleteIsPending() -> Bool { pendingDelete != nil }
    func resumeDelete() { pendingDelete?.resume(); pendingDelete = nil }
    func delete(service: String, account: String) async throws {
        if holdDelete { await withCheckedContinuation { pendingDelete = $0 } }
        saved = nil
    }
    func loadCount() -> Int { loads }
}
@MainActor private final class SuspendedControlPlugin: CameraControlPlugin {
    nonisolated let descriptor = VendorDescriptor(id: "test", displayName: "Test", badgeText: "TEST", signalHint: nil, sdkVersion: nil, sdkPresent: true)
    nonisolated let credentialService = "test"
    var camera = ControlCamera(pluginID: "test", id: "camera", name: "Camera", transport: .network, address: "192.0.2.1", fingerprint: "pin", authenticationMode: .usernamePassword)
    var handler: (@MainActor @Sendable (ControlEvent) -> Void)?
    var connection: CheckedContinuation<Void, Never>?
    var read: CheckedContinuation<[ControlProperty], Never>?
    var holdConnect = false
    var requests: [ControlPreparationRequest] = []
    var holdRead = false
    var propertyFailures = 0
    var propertyCalls = 0
    var propertyValues: [ControlProperty] = []
    var setCalls = 0
    var connectCount = 0
    var admittedCamera: ControlCamera?
    var admittedCredentials: ControlCredentials?
    var connectedGeneration: UInt64?
    var connectedFeedID: String?
    var disconnects: [UInt64] = []
    var disconnectFailures = 0
    var shutdownFailures = 0
    var shutdownCalls = 0
    var holdShutdown = false
    var shutdownContinuation: CheckedContinuation<Void, Never>?
    nonisolated func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String { camera.id + fingerprint }
    func discover() async throws -> [ControlCamera] { [camera] }
    func prepare(_ request: ControlPreparationRequest) async throws -> ControlPreparationResult { requests.append(request); return .init(camera: camera, pairingRequirement: .usernamePassword(fingerprint: camera.fingerprint!)) }
    func connect(feedID: String, generation: UInt64, camera: ControlCamera, credentials: ControlCredentials?) async throws {
        if connectedGeneration != nil { throw ControlError(code: .staleGeneration, retryable: false, message: "Previous SDK handle still active") }
        connectCount += 1
        admittedCamera = camera; admittedCredentials = credentials
        if holdConnect { await withCheckedContinuation { connection = $0 } }
        connectedGeneration = generation; connectedFeedID = feedID
    }
    func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty] {
        propertyCalls += 1
        if propertyFailures > 0 { propertyFailures -= 1; throw ControlError(code: .sdkFailure, retryable: true, message: "Synthetic property read failed") }
        if holdRead { return await withCheckedContinuation { read = $0 } }
        return propertyValues
    }
    var setFailures = 0
    func set(_ property: String, value: ControlValue, feedID: String, generation: UInt64) async throws {
        setCalls += 1
        if setFailures > 0 { setFailures -= 1; throw ControlError(code: .sdkFailure, retryable: false, message: "Synthetic write failed") }
    }
    func disconnect(feedID: String, generation: UInt64) async throws {
        disconnects.append(generation)
        if disconnectFailures > 0 {
            disconnectFailures -= 1
            throw ControlError(code: .cleanupPending, retryable: true, message: "Synthetic disconnect cleanup pending")
        }
        if connectedGeneration == generation && connectedFeedID == feedID { connectedGeneration = nil; connectedFeedID = nil }
    }
    func shutdown() async throws {
        shutdownCalls += 1
        if holdShutdown { await withCheckedContinuation { shutdownContinuation = $0 } }
        if shutdownFailures > 0 {
            shutdownFailures -= 1
            throw ControlError(code: .cleanupPending, retryable: true, message: "Synthetic shutdown cleanup pending")
        }
        connectedGeneration = nil; connectedFeedID = nil
    }
    func setEventHandler(_ handler: @escaping @MainActor @Sendable (ControlEvent) -> Void) { self.handler = handler }
}

/// Automatic reconnection's waits, released by the test instead of the clock.
@MainActor private final class RetrySleeper {
    private(set) var requested: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var pending: Int { waiting.count }
    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        await withCheckedContinuation { waiting.append($0) }
        try Task.checkCancellation()
    }
    func release() { let resumed = waiting; waiting = []; resumed.forEach { $0.resume() } }
}

@MainActor @objcMembers final class CameraControlStoreChecks: XCTestCase {
    func testCredentialAwaitRetainsPreparedEndpointAndAuthentication() async throws {
        let plugin = SuspendedControlPlugin()
        let approved = plugin.camera
        let credentials = MemoryControlCredentials()
        await credentials.suspendLoad(with: .usernamePassword(username: "user", password: "mock-secret"))
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        let connection = Task { await store.connect(camera: approved, to: "approved", saveCredentials: false) }
        while await credentials.loadCount() == 0 { await Task.yield() }
        XCTAssertTrue(store.state(for: "approved").busy)
        var conflicting = approved
        conflicting.address = "192.0.2.99"
        conflicting.authenticationMode = .none
        plugin.camera = conflicting
        let result = await store.prepare(pluginID: "test", request: .camera(conflicting), feedID: "conflicting")
        XCTAssertNil(result, "A second feed cannot claim a camera whose verified connection is pending")
        XCTAssertNotNil(store.state(for: "conflicting").message)
        XCTAssertEqual(plugin.connectCount, 0)
        await credentials.resumeLoad()
        await connection.value
        XCTAssertEqual(plugin.admittedCamera, approved, "Connect must forward the approved endpoint/authentication, never mutable discovery metadata")
        XCTAssertEqual(plugin.admittedCredentials, .usernamePassword(username: "user", password: "mock-secret"))
        XCTAssertTrue(store.state(for: "approved").connected)
        XCTAssertEqual(store.assignment(for: "approved")?.camera, approved)
        XCTAssertNil(store.assignment(for: "conflicting"))
        _ = await store.shutdown()
    }

    func testChangedPinPrecedesCredentialLookup() async throws {
        let plugin = SuspendedControlPlugin()
        let persistence = MemoryControlAssignments()
        persistence.value.plugins = ["test": ["feed": .init(camera: plugin.camera)]]
        plugin.camera.fingerprint = "changed"
        let credentials = MemoryControlCredentials()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: persistence)
        await store.reconnect("feed")
        let count = await credentials.loadCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(plugin.connectCount, 0)
        XCTAssertFalse(store.state(for: "feed").connected)
    }

    func testChangedAuthenticationAndMissingSelectedFingerprintPrecedeCredentialLookup() async {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        let selected = plugin.camera
        plugin.camera.authenticationMode = .none
        await store.connect(camera: selected, to: "changed-authentication")
        plugin.camera = selected
        var unverified = selected
        unverified.fingerprint = nil
        await store.connect(camera: unverified, to: "missing-pin")
        let loads = await credentials.loadCount()
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(plugin.connectCount, 0)
        XCTAssertNotNil(store.state(for: "changed-authentication").message)
        XCTAssertNotNil(store.state(for: "missing-pin").message)
    }

    func testInvalidCandidateKeepsOriginalAssignmentDisconnected() async {
        let plugin = SuspendedControlPlugin(), persistence = MemoryControlAssignments()
        persistence.value.plugins = ["test": ["feed": .init(camera: plugin.camera, autoReconnect: false)]]
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: persistence)
        var other = plugin.camera
        other.id = "wrong-camera"
        await store.connect(camera: other, to: "feed")
        XCTAssertEqual(store.assignment(for: "feed")?.autoReconnect, false)
        XCTAssertTrue(plugin.requests.isEmpty)
        XCTAssertNotNil(store.state(for: "feed").message)
    }

    func testDisconnectDuringConnectCannotResurrectGeneration() async throws {
        let plugin = SuspendedControlPlugin(); plugin.holdConnect = true
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        let task = Task { await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false) }
        while plugin.connection == nil { await Task.yield() }
        let generation = store.state(for: "feed").generation
        await store.disconnect("feed")
        plugin.connection?.resume(); plugin.connection = nil
        await task.value
        XCTAssertFalse(store.state(for: "feed").connected)
        XCTAssertNil(store.assignment(for: "feed"))
        XCTAssertTrue(plugin.disconnects.contains(generation))
    }

    func testReadCannotClearNewerInvalidation() async throws {
        let plugin = SuspendedControlPlugin()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false)
        plugin.holdRead = true
        let task = Task { await store.refresh("feed") }
        while plugin.read == nil { await Task.yield() }
        plugin.handler?(.changed(feedID: "feed", generation: store.state(for: "feed").generation))
        plugin.read?.resume(returning: []); plugin.read = nil
        await task.value
        XCTAssertTrue(store.state(for: "feed").dirty)
        _ = await store.shutdown()
    }
    func testManualPreparationSurvivesPersistence() async throws {
        let plugin = SuspendedControlPlugin()
        let persistence = MemoryControlAssignments()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: persistence)
        let request = ControlPreparationRequest.endpoint(.init(address: plugin.camera.address, expectedIdentity: plugin.camera.id, authenticationMode: .usernamePassword))
        let prepared = await store.prepare(pluginID: "test", request: request, feedID: "feed")
        XCTAssertNotNil(prepared)
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false)
        XCTAssertEqual(plugin.requests.last, request)
        XCTAssertEqual(persistence.value.plugins["test"]?["feed"]?.preparationRequest, request)
        _ = await store.shutdown()
    }

    func testReconnectUsesSavedEndpointUntilAddressChangeIsSelected() async {
        let plugin = SuspendedControlPlugin(), persistence = MemoryControlAssignments()
        let original = plugin.camera
        let originalRequest = ControlPreparationRequest.endpoint(.init(address: original.address, expectedIdentity: original.id,
            authenticationMode: original.authenticationMode))
        persistence.value.plugins = ["test": ["feed": .init(camera: original, preparationRequest: originalRequest)]]
        let credentials = MemoryControlCredentials()
        let secret = ControlCredentials.usernamePassword(username: "user", password: "mock-secret")
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: persistence)
        plugin.camera.address = "192.0.2.99"
        let updated = plugin.camera
        let updatedRequest = ControlPreparationRequest.endpoint(.init(address: updated.address, expectedIdentity: updated.id,
            authenticationMode: updated.authenticationMode))
        let prepared = await store.prepare(pluginID: "test", request: updatedRequest, feedID: "feed")
        XCTAssertEqual(prepared?.camera, updated)
        plugin.camera = original
        await store.connect(camera: original, to: "feed", credentials: secret, saveCredentials: false)
        XCTAssertEqual(plugin.requests.last, originalRequest)
        await store.disconnect("feed")
        plugin.camera = updated
        await store.connect(camera: updated, to: "feed", credentials: secret, saveCredentials: false)
        XCTAssertEqual(plugin.requests.last, updatedRequest)
        XCTAssertEqual(store.assignment(for: "feed")?.camera, updated)
        _ = await store.shutdown()
    }

    func testCancellationReleasesLateConnection() async throws {
        let plugin = SuspendedControlPlugin(); plugin.holdConnect = true
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        let task = Task { await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false) }
        while plugin.connection == nil { await Task.yield() }
        task.cancel()
        plugin.connection?.resume(); plugin.connection = nil
        await task.value
        while plugin.disconnects.isEmpty { await Task.yield() }
        XCTAssertFalse(store.state(for: "feed").connected)
        XCTAssertNil(store.assignment(for: "feed"))
        _ = await store.shutdown()
    }

    func testLegacyMigrationRetainsDataAndIsIdempotent() throws {
        let suite = "CameraControlStoreChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"feed":{"camera":{"id":"02:00:00:00:00:01","model":"Camera","address":"192.0.2.1","authentication":true,"fingerprint":"pin","fingerprintError":""},"showOverlay":true}}"#.utf8)
        defaults.set(legacy, forKey: "ui.sony.controls.v1")
        let persistence = CameraControlPreferences(defaults: defaults)
        let migrated = try persistence.load()
        XCTAssertEqual(migrated.plugins["sony"]?["feed"]?.camera.id, "02:00:00:00:00:01")
        XCTAssertEqual(migrated.plugins["sony"]?["feed"]?.showOverlay, true)
        XCTAssertEqual(defaults.data(forKey: "ui.sony.controls.v1"), legacy)
        XCTAssertTrue(defaults.bool(forKey: "ui.camera.controls.sony-migrated.v1"))
        XCTAssertEqual(try persistence.load(), migrated)
    }

    func testFakeReconnectAtLaunchRunsOnce() async throws {
        let descriptor = VendorDescriptor(id: "fake", displayName: "Fake", badgeText: "FAKE", signalHint: nil, sdkVersion: nil, sdkPresent: true)
        let camera = ControlCamera(pluginID: "fake", id: "camera", name: "Camera", transport: .usb, address: "usb", fingerprint: nil)
        let persistence = MemoryControlAssignments()
        persistence.value.plugins = ["fake": ["feed": .init(camera: camera)]]
        let plugin = FakeControlPlugin(descriptor: descriptor, cameras: [camera])
        let store = CameraControlStore(plugins: ["fake": plugin], credentials: MemoryControlCredentials(), persistence: persistence)
        await store.restoreConnections()
        XCTAssertTrue(store.state(for: "feed").connected)
        await store.disconnect("feed")
        await store.restoreConnections()
        XCTAssertFalse(store.state(for: "feed").connected)
        XCTAssertNotNil(store.assignment(for: "feed"))
        _ = await store.shutdown()
    }

    func testDisconnectEventMakesPendingConnectTerminal() async throws {
        let plugin = SuspendedControlPlugin(); plugin.holdConnect = true
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        let task = Task { await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false) }
        while plugin.connection == nil { await Task.yield() }
        let generation = store.state(for: "feed").generation
        plugin.handler?(.disconnected(feedID: "feed", generation: generation, reason: .init(code: .transport, retryable: true, message: "Lost camera")))
        plugin.connection?.resume(); plugin.connection = nil
        await task.value
        XCTAssertFalse(store.state(for: "feed").connected)
        XCTAssertNil(store.assignment(for: "feed"))
        XCTAssertEqual(store.state(for: "feed").message, "Lost camera")
        XCTAssertTrue(plugin.disconnects.contains(generation))
        _ = await store.shutdown()
    }

    func testTransportDisconnectReleasesHandleBeforeReconnect() async throws {
        let plugin = SuspendedControlPlugin()
        let credentials = MemoryControlCredentials()
        try await credentials.save(.usernamePassword(username: "user", password: "secret"), service: "test", account: "test")
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false)
        let oldGeneration = store.state(for: "feed").generation
        plugin.handler?(.disconnected(feedID: "feed", generation: oldGeneration, reason: .init(code: .transport, retryable: true, message: "Lost connection")))
        await store.reconnect("feed")
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertTrue(plugin.disconnects.contains(oldGeneration))
        guard store.state(for: "feed").connected, plugin.disconnects.contains(oldGeneration) else {
            throw ControlError(code: .invalidState, retryable: false, message: "Reconnect did not release the old SDK handle")
        }
        _ = await store.shutdown()
    }

    func testFailedExplicitDisconnectRetriesOriginalGenerationBeforeReconnect() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        let secret = ControlCredentials.usernamePassword(username: "user", password: "secret")
        try await credentials.save(secret, service: "test", account: "test")
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: secret, saveCredentials: false)
        let generation = store.state(for: "feed").generation
        plugin.disconnectFailures = 1
        await store.disconnect("feed")
        XCTAssertFalse(store.state(for: "feed").connected)
        XCTAssertNotNil(store.state(for: "feed").message)
        await store.reconnect("feed")
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertEqual(plugin.disconnects.filter { $0 == generation }.count, 2)
        XCTAssertEqual(plugin.connectCount, 2)
        _ = await store.shutdown()
    }
    func testSecondExplicitDisconnectRetriesPendingGeneration() async throws {
        let plugin = SuspendedControlPlugin()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false)
        let generation = store.state(for: "feed").generation
        plugin.disconnectFailures = 1
        await store.disconnect("feed")
        await store.disconnect("feed")
        XCTAssertEqual(plugin.disconnects.filter { $0 == generation }.count, 2)
        XCTAssertNil(plugin.connectedGeneration)
        _ = await store.shutdown()
    }
    func testFailedShutdownCanRetryWhileAdmissionStaysClosed() async throws {
        let plugin = SuspendedControlPlugin()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        await store.discover(pluginID: "test")
        plugin.shutdownFailures = 1
        let first = await store.shutdown()
        XCTAssertNotNil(first)
        XCTAssertTrue(store.needsShutdown)
        let second = await store.shutdown()
        XCTAssertNil(second)
        XCTAssertFalse(store.needsShutdown)
        XCTAssertEqual(plugin.shutdownCalls, 2)
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false)
        XCTAssertEqual(plugin.connectCount, 0)
        _ = await store.shutdown()
        XCTAssertEqual(plugin.shutdownCalls, 2)
    }

    func testResetRetainsFailedCleanupUntilNextConnectionWithoutDeletingCredentials() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        let secret = ControlCredentials.usernamePassword(username: "user", password: "secret")
        try await credentials.save(secret, service: "test", account: "test")
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: secret, saveCredentials: false)
        let generation = store.state(for: "feed").generation
        plugin.disconnectFailures = 1
        store.reset()
        while store.state(for: "feed").message == nil { await Task.yield() }
        XCTAssertNil(store.assignment(for: "feed"))
        await store.connect(camera: plugin.camera, to: "replacement", credentials: secret, saveCredentials: false)
        XCTAssertTrue(store.state(for: "replacement").connected)
        XCTAssertEqual(plugin.disconnects.filter { $0 == generation }.count, 2)
        let saved = try await credentials.load(service: "test", account: "test")
        XCTAssertEqual(saved, secret)
        _ = await store.shutdown()
    }
    func testCancelledConnectionRetainsOriginalCleanupGenerationOnFailure() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        let secret = ControlCredentials.usernamePassword(username: "user", password: "secret")
        try await credentials.save(secret, service: "test", account: "test")
        plugin.holdConnect = true
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        let task = Task { await store.connect(camera: plugin.camera, to: "feed", credentials: secret, saveCredentials: false) }
        while plugin.connection == nil { await Task.yield() }
        let generation = store.state(for: "feed").generation
        plugin.disconnectFailures = 1
        task.cancel()
        while store.state(for: "feed").message == nil { await Task.yield() }
        plugin.connection?.resume(); plugin.connection = nil
        await task.value
        plugin.holdConnect = false
        await store.connect(camera: plugin.camera, to: "feed", credentials: secret, saveCredentials: false)
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertTrue(plugin.disconnects.allSatisfy { $0 == generation })
        let saved = try await credentials.load(service: "test", account: "test")
        XCTAssertEqual(saved, secret)
        _ = await store.shutdown()
    }

    func testConcurrentShutdownCoalescesOnlyInFlightAttempt() async throws {
        let plugin = SuspendedControlPlugin()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        await store.discover(pluginID: "test")
        plugin.holdShutdown = true; plugin.shutdownFailures = 1
        let first = Task { await store.shutdown() }
        let second = Task { await store.shutdown() }
        while plugin.shutdownContinuation == nil { await Task.yield() }
        XCTAssertEqual(plugin.shutdownCalls, 1)
        plugin.shutdownContinuation?.resume(); plugin.shutdownContinuation = nil
        let firstMessage = await first.value, secondMessage = await second.value
        XCTAssertNotNil(firstMessage); XCTAssertEqual(firstMessage, secondMessage)
        XCTAssertEqual(plugin.shutdownCalls, 1)
        plugin.holdShutdown = false
        let retry = await store.shutdown()
        XCTAssertNil(retry)
        XCTAssertEqual(plugin.shutdownCalls, 2)
        XCTAssertFalse(store.needsShutdown)
    }

    func testConfirmedSignInIsSavedEvenWhenInitialPropertyReadFails() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        let secret = ControlCredentials.usernamePassword(username: "user", password: "secret")
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        plugin.propertyFailures = 1
        await store.connect(camera: plugin.camera, to: "feed", credentials: secret)
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertTrue(store.state(for: "feed").dirty)
        XCTAssertTrue(store.state(for: "feed").hasSavedCredentials)
        let saves = await credentials.saveCount()
        XCTAssertEqual(saves, 1)
        let saved = try await credentials.load(service: "test", account: "test")
        XCTAssertEqual(saved, secret)
        await store.disconnect("feed")
        await store.reconnect("feed")
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertEqual(plugin.connectCount, 2)
        _ = await store.shutdown()
    }
    func testResetClearsCameraSnapshotBeforeReplacementReadFailure() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        let stale = ControlProperty(id: "test:exposure", label: "Exposure", writable: true, value: .unsignedInteger(123), options: [.init(id: "456", label: "456", value: .unsignedInteger(456))])
        plugin.propertyValues = [stale]
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"))
        XCTAssertEqual(store.state(for: "feed").properties, [stale])
        XCTAssertNotNil(store.state(for: "feed").lastRefresh)
        XCTAssertTrue(store.state(for: "feed").hasSavedCredentials)
        store.reset()
        XCTAssertTrue(store.state(for: "feed").properties.isEmpty)
        XCTAssertNil(store.state(for: "feed").lastRefresh)
        XCTAssertFalse(store.state(for: "feed").hasSavedCredentials)
        plugin.camera.id = "replacement"; plugin.camera.name = "Replacement"
        plugin.propertyFailures = 1
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "replacement", password: "replacement-secret"), saveCredentials: false)
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertTrue(store.state(for: "feed").properties.isEmpty)
        XCTAssertNil(store.state(for: "feed").lastRefresh)
        XCTAssertFalse(store.state(for: "feed").hasSavedCredentials)
        await store.set(stale, value: .unsignedInteger(456), feedID: "feed")
        XCTAssertEqual(plugin.setCalls, 0)
        _ = await store.shutdown()
    }
    /// Showing the sign-in row (a tab switch back, a row expanded again) reads the Keychain
    /// only: it never prepares, so it never scans or contacts the body.
    func testSavedSignInCheckReadsTheKeychainWithoutContactingTheBody() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        try await credentials.save(.usernamePassword(username: "user", password: "secret"), service: "test", account: "camerapin")
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        for _ in 0..<3 { await store.checkSavedCredentials(for: plugin.camera, feedID: "feed") }
        XCTAssertTrue(plugin.requests.isEmpty, "No preparation, so no scan")
        XCTAssertEqual(plugin.connectCount, 0)
        XCTAssertTrue(store.hasSavedCredentials(for: plugin.camera))
        XCTAssertTrue(store.state(for: "feed").hasSavedCredentials)
        try await credentials.delete(service: "test", account: "camerapin")
        await store.checkSavedCredentials(for: plugin.camera, feedID: "feed")
        XCTAssertFalse(store.hasSavedCredentials(for: plugin.camera))
        // Connecting is the explicit action: it prepares, verifying the body, before the sign-in is read.
        try await credentials.save(.usernamePassword(username: "user", password: "secret"), service: "test", account: "camerapin")
        await store.connectUsingSavedCredentials(plugin.camera, to: "feed")
        XCTAssertEqual(plugin.requests.count, 1)
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertTrue(store.hasSavedCredentials(for: plugin.camera))
        _ = await store.shutdown()
    }

    func testCredentialAvailabilityIsScopedToExactCameraAndFingerprint() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        plugin.camera.id = "body|lens"
        plugin.camera.fingerprint = "pin"
        var other = plugin.camera
        other.id = "body"
        other.fingerprint = "lens|pin"
        try await credentials.save(.usernamePassword(username: "user", password: "secret"), service: "test", account: "body|lenspin")
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        await store.checkSavedCredentials(for: plugin.camera, feedID: "feed")
        XCTAssertTrue(store.hasSavedCredentials(for: plugin.camera))
        XCTAssertFalse(store.hasSavedCredentials(for: other))
    }

    func testCompletedCredentialDeletionDisconnectsEvenIfCallerCancels() async {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"))
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertTrue(store.hasSavedCredentials(for: plugin.camera))
        await credentials.suspendDelete()
        let deletion = Task { await store.forgetCredentials("feed") }
        while !(await credentials.deleteIsPending()) { await Task.yield() }
        deletion.cancel()
        await credentials.resumeDelete()
        await deletion.value
        XCTAssertFalse(store.state(for: "feed").connected)
        XCTAssertFalse(store.state(for: "feed").hasSavedCredentials)
        XCTAssertFalse(store.hasSavedCredentials(for: plugin.camera))
        XCTAssertEqual(store.assignment(for: "feed")?.autoReconnect, false)
        _ = await store.shutdown()
    }
    func testCredentialSaveFailureDoesNotPreventPropertySnapshot() async throws {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials()
        plugin.propertyValues = [.init(id: "test:iso", label: "ISO", writable: false, value: .unsignedInteger(800))]
        await credentials.setSaveFailure(true)
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"))
        XCTAssertTrue(store.state(for: "feed").connected)
        XCTAssertEqual(store.state(for: "feed").properties, plugin.propertyValues)
        XCTAssertEqual(plugin.propertyCalls, 1)
        XCTAssertFalse(store.state(for: "feed").hasSavedCredentials)
        XCTAssertTrue(store.state(for: "feed").message?.contains("sign-in") == true)
        _ = await store.shutdown()
    }

    // MARK: Automatic reconnection

    private static let fakeDescriptor = VendorDescriptor(id: "fake", displayName: "Fake", badgeText: "FAKE", signalHint: nil, sdkVersion: nil, sdkPresent: true)
    private static let fakeCamera = ControlCamera(pluginID: "fake", id: "camera", name: "Camera", transport: .usb, address: "usb", fingerprint: nil)
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    func testReconnectWaitsGrowToAMinuteWithSmallJitterAndStopAfterTenMinutes() {
        let steps = (0..<6).map { CameraControlReconnectPolicy.delay(step: $0, jitter: 0) }
        XCTAssertEqual(steps, [.seconds(10), .seconds(20), .seconds(30), .seconds(60), .seconds(60), .seconds(60)])
        XCTAssertEqual(CameraControlReconnectPolicy.delay(step: 0, jitter: 1), .seconds(11), "Jitter adds at most a tenth")
        XCTAssertEqual(CameraControlReconnectPolicy.delay(step: 99, jitter: 5), .seconds(66), "Jitter is clamped")
        XCTAssertEqual(CameraControlReconnectPolicy.delay(step: 0, jitter: .nan), .seconds(10))
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(CameraControlReconnectPolicy.givesUp(startedAt: start, now: start.addingTimeInterval(599)))
        XCTAssertTrue(CameraControlReconnectPolicy.givesUp(startedAt: start, now: start.addingTimeInterval(600)))
    }

    func testOnlyPassingFailuresAreRetried() {
        func error(_ code: ControlReasonCode, _ retryable: Bool = true) -> ControlError { .init(code: code, retryable: retryable, message: "") }
        for code in [ControlReasonCode.transport, .removed, .unavailable, .sdkFailure, .cleanupPending] {
            XCTAssertTrue(CameraControlReconnectPolicy.retries(after: error(code)), "\(code)")
            XCTAssertFalse(CameraControlReconnectPolicy.retries(after: error(code, false)), "\(code) marked final")
        }
        for code in [ControlReasonCode.authentication, .changedIdentity, .unsupported, .invalidRequest, .busy, .manual, .staleGeneration] {
            XCTAssertFalse(CameraControlReconnectPolicy.retries(after: error(code)), "\(code) waits for the operator")
        }
        XCTAssertFalse(CameraControlReconnectPolicy.retries(after: CameraControlCredentialError(action: "load", status: -25308)),
            "A Keychain error waits for the operator")
    }

    func testReconnectDecisionStopsForTheOperatorAndWaitsWhileBusy() {
        typealias Policy = CameraControlReconnectPolicy
        func decide(shuttingDown: Bool = false, assigned: Bool = true, autoReconnect: Bool = true, manual: Bool = false,
            removed: Bool = false, connected: Bool = false, busy: Bool = false) -> Policy.Decision {
            Policy.decision(shuttingDown: shuttingDown, assigned: assigned, autoReconnect: autoReconnect, manuallyDisconnected: manual,
                removed: removed, connected: connected, busy: busy)
        }
        XCTAssertEqual(decide(), .attempt)
        XCTAssertEqual(decide(busy: true), .wait)
        for stopped in [decide(shuttingDown: true), decide(assigned: false), decide(autoReconnect: false), decide(manual: true),
            decide(removed: true), decide(connected: true), decide(connected: true, busy: true)] {
            XCTAssertEqual(stopped, .stop)
        }
    }

    func testSavedPairingsWithoutTheFlagReconnectAndDisconnectIsSaved() throws {
        let old = Data(#"{"version":1,"plugins":{"fake":{"feed":{"camera":{"pluginID":"fake","id":"camera","name":"Camera","transport":"usb","address":"usb","authenticationMode":"none"},"showOverlay":true}}}}"#.utf8)
        let decoded = try JSONDecoder().decode(CameraControlAssignmentSnapshot.self, from: old)
        XCTAssertEqual(decoded.plugins["fake"]?["feed"]?.autoReconnect, true, "Saved before the flag: reconnects")
        XCTAssertEqual(decoded.plugins["fake"]?["feed"]?.showOverlay, true)
        var off = try XCTUnwrap(decoded.plugins["fake"]?["feed"]); off.autoReconnect = false
        XCTAssertEqual(try JSONDecoder().decode(CameraControlAssignment.self, from: JSONEncoder().encode(off)), off)
    }

    func testFailedLaunchRestoreRetriesWithBackoffUntilTheBodyAnswers() async throws {
        let persistence = MemoryControlAssignments()
        persistence.value.plugins = ["fake": ["feed": .init(camera: Self.fakeCamera)]]
        let plugin = FakeControlPlugin(descriptor: Self.fakeDescriptor, cameras: [])
        let sleeper = RetrySleeper()
        let store = CameraControlStore(plugins: ["fake": plugin], credentials: MemoryControlCredentials(), persistence: persistence,
            sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        await store.restoreConnections()
        let state = store.state(for: "feed")
        XCTAssertFalse(state.connected)
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.requested, [.seconds(10)])
        XCTAssertNotNil(state.retryAt)
        XCTAssertNotNil(state.lostAt, "A body that didn't answer at launch reads as lost, so Problems lists it")
        XCTAssertEqual(state.reconnectStatus(at: state.retryAt!.addingTimeInterval(-1.5)), "Trying again in 2 s")
        sleeper.release()
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.requested, [.seconds(10), .seconds(20)], "Still away: the wait grows")
        plugin.replaceCameras([Self.fakeCamera])
        sleeper.release()
        await settle { state.connected }
        XCTAssertTrue(state.connected, "Back: the retry connects with no button pressed")
        XCTAssertNil(state.retryAt); XCTAssertNil(state.lostAt); XCTAssertFalse(state.retrying)
        XCTAssertEqual(sleeper.pending, 0)
        _ = await store.shutdown()
    }

    func testDroppedBodyRetriesAndAnOperatorDisconnectCancelsIt() async throws {
        let plugin = SuspendedControlPlugin(), sleeper = RetrySleeper()
        let secret = ControlCredentials.usernamePassword(username: "user", password: "secret")
        let credentials = MemoryControlCredentials()
        try await credentials.save(secret, service: "test", account: "test")
        let persistence = MemoryControlAssignments()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: persistence,
            sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        await store.connect(camera: plugin.camera, to: "feed", credentials: secret, saveCredentials: false)
        let state = store.state(for: "feed")
        plugin.handler?(.disconnected(feedID: "feed", generation: state.generation, reason: .init(code: .transport, retryable: true, message: "Lost camera")))
        XCTAssertTrue(state.retrying)
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.requested, [.seconds(10)], "A body that drops on its own is tried again")
        await settle { plugin.connectedGeneration == nil }
        sleeper.release()
        await settle { state.connected }
        XCTAssertTrue(state.connected)
        XCTAssertEqual(plugin.connectCount, 2)
        // The operator's Disconnect: no retry now, and none on the next launch.
        plugin.handler?(.disconnected(feedID: "feed", generation: state.generation, reason: .init(code: .transport, retryable: true, message: "Lost camera")))
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.pending, 1)
        await store.disconnect("feed")
        XCTAssertNil(state.retryAt)
        sleeper.release()
        await settle { false }
        XCTAssertEqual(plugin.connectCount, 2, "A cancelled retry never connects")
        XCTAssertEqual(persistence.value.plugins["test"]?["feed"]?.autoReconnect, false)
        let relaunchPlugin = SuspendedControlPlugin()
        let relaunched = CameraControlStore(plugins: ["test": relaunchPlugin], credentials: credentials, persistence: persistence,
            sleep: { try await sleeper.sleep($0) })
        await relaunched.restoreConnections()
        XCTAssertTrue(relaunchPlugin.requests.isEmpty, "A manual Disconnect stays off across launches")
        await relaunched.reconnect("feed")
        XCTAssertTrue(relaunched.state(for: "feed").connected)
        XCTAssertEqual(persistence.value.plugins["test"]?["feed"]?.autoReconnect, true, "Reconnect turns it back on")
        _ = await relaunched.shutdown()
        _ = await store.shutdown()
    }

    func testMissingSignInStopsWithItsMessageAndShutdownCancelsAWaitingRetry() async throws {
        let plugin = SuspendedControlPlugin(), sleeper = RetrySleeper()
        let persistence = MemoryControlAssignments()
        persistence.value.plugins = ["test": ["feed": .init(camera: plugin.camera)]]
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: persistence,
            sleep: { try await sleeper.sleep($0) })
        await store.restoreConnections()
        XCTAssertTrue(sleeper.requested.isEmpty, "No saved sign-in: nothing to retry")
        XCTAssertFalse(store.state(for: "feed").retrying)
        XCTAssertNotNil(store.state(for: "feed").message)
        XCTAssertNil(store.state(for: "feed").lostAt)
        let requests = plugin.requests.count
        await store.connect(camera: plugin.camera, to: "feed", credentials: .usernamePassword(username: "user", password: "secret"), saveCredentials: false)
        plugin.handler?(.disconnected(feedID: "feed", generation: store.state(for: "feed").generation,
            reason: .init(code: .transport, retryable: true, message: "Lost camera")))
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.pending, 1)
        _ = await store.shutdown()
        XCTAssertNil(store.state(for: "feed").retryAt)
        sleeper.release()
        await settle { false }
        XCTAssertEqual(plugin.requests.count, requests + 1, "Quitting cancels the waiting retry")
    }

    func testWakeRetriesAWaitingBodyNowWithItsBackoffReset() async throws {
        let persistence = MemoryControlAssignments()
        persistence.value.plugins = ["fake": ["feed": .init(camera: Self.fakeCamera)]]
        let plugin = FakeControlPlugin(descriptor: Self.fakeDescriptor, cameras: [])
        let sleeper = RetrySleeper()
        let store = CameraControlStore(plugins: ["fake": plugin], credentials: MemoryControlCredentials(), persistence: persistence,
            sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        await store.restoreConnections()
        await settle { sleeper.pending == 1 }
        sleeper.release()
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested.last, .seconds(20))
        store.retryPendingReconnects()
        await settle { sleeper.requested.count == 3 }
        XCTAssertEqual(sleeper.requested.last, .zero, "A wake tries now")
        sleeper.release()
        await settle { sleeper.pending == 1 && sleeper.requested.count == 4 }
        XCTAssertEqual(sleeper.requested.last, .seconds(10), "and starts the backoff over")
        _ = await store.shutdown()
    }

    func testABodyThatStaysAwayIsTriedForTenMinutesThenWaitsForReconnectOrAWake() async throws {
        let persistence = MemoryControlAssignments()
        persistence.value.plugins = ["fake": ["feed": .init(camera: Self.fakeCamera)]]
        let plugin = FakeControlPlugin(descriptor: Self.fakeDescriptor, cameras: [])
        let sleeper = RetrySleeper()
        final class Clock { var date = Date(timeIntervalSinceReferenceDate: 0) }
        let clock = Clock()
        let store = CameraControlStore(plugins: ["fake": plugin], credentials: MemoryControlCredentials(), persistence: persistence,
            now: { clock.date }, sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        await store.restoreConnections()
        let state = store.state(for: "feed")
        await settle { sleeper.pending == 1 }
        clock.date = clock.date.addingTimeInterval(9 * 60)
        sleeper.release()
        await settle { sleeper.pending == 1 && sleeper.requested.count == 2 }
        XCTAssertTrue(state.retrying, "Nine minutes in: still trying")
        clock.date = clock.date.addingTimeInterval(60)
        sleeper.release()
        await settle { !state.retrying }
        XCTAssertFalse(state.retrying, "Ten minutes in: it stops")
        XCTAssertEqual(sleeper.pending, 0)
        XCTAssertNil(state.retryAt)
        XCTAssertNotNil(state.lostAt, "Still lost, so Problems offers Reconnect")
        XCTAssertEqual(state.message, CameraControlReconnectPolicy.gaveUpMessage)
        // A wake (or the network coming back) starts a new round.
        store.retryPendingReconnects()
        await settle { sleeper.requested.count == 3 }
        XCTAssertEqual(sleeper.requested.last, .zero)
        plugin.replaceCameras([Self.fakeCamera])
        sleeper.release()
        await settle { state.connected }
        XCTAssertTrue(state.connected)
        _ = await store.shutdown()
    }

    // MARK: Settings refresh

    private static let iso = ControlProperty(id: "iso", label: "ISO", writable: true, value: .unsignedInteger(800))
    private static let secret = ControlCredentials.usernamePassword(username: "user", password: "secret")
    private final class RefreshClock { var date = Date(timeIntervalSinceReferenceDate: 1_000) }

    func testRefreshIntervalWaitsOutTheRestOfItsIntervalAndNeverWaits() {
        typealias Interval = CameraControlRefreshInterval
        let read = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(Interval.allCases.map(\.seconds), [15, 30, 60, 120, 300, nil])
        XCTAssertEqual(Interval.allCases.map(\.title),
            ["Every 15 s", "Every 30 s", "Every 60 s", "Every 2 min", "Every 5 min", "Never (only when you press Refresh)"])
        XCTAssertEqual(Interval.standard, .seconds60)
        XCTAssertEqual(Interval.seconds60.delay(lastRefresh: read, now: read.addingTimeInterval(20)), 40, "The rest of the minute")
        XCTAssertEqual(Interval.seconds15.delay(lastRefresh: read, now: read.addingTimeInterval(90)), 0, "Stale for longer: read now")
        XCTAssertEqual(Interval.minutes5.delay(lastRefresh: read, now: read.addingTimeInterval(-30)), 300, "A clock that went back waits one interval, no more")
        XCTAssertEqual(Interval.seconds30.delay(lastRefresh: nil, now: read), 0)
        XCTAssertNil(Interval.never.delay(lastRefresh: read, now: read.addingTimeInterval(3_600)))
        XCTAssertNil(Interval.never.delay(lastRefresh: nil, now: read))
    }

    func testChangeNoticesOnlyMarkSettingsStaleAndOneReadFollowsAtTheInterval() async {
        let plugin = SuspendedControlPlugin(), sleeper = RetrySleeper(), clock = RefreshClock()
        plugin.propertyValues = [Self.iso]
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments(),
            now: { clock.date }, refreshSleep: { try await sleeper.sleep($0) })
        await store.connect(camera: plugin.camera, to: "feed", credentials: Self.secret, saveCredentials: false)
        let state = store.state(for: "feed")
        XCTAssertEqual(plugin.propertyCalls, 1, "Read on connecting")
        XCTAssertFalse(state.dirty)
        XCTAssertEqual(state.cacheStatus, "Updated \(clock.date.formatted(date: .omitted, time: .standard))")
        clock.date = clock.date.addingTimeInterval(20)
        for _ in 0..<5 { plugin.handler?(.changed(feedID: "feed", generation: state.generation)) }
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(plugin.propertyCalls, 1, "A notice never reads on its own")
        XCTAssertTrue(state.dirty)
        XCTAssertFalse(state.busy)
        XCTAssertNotEqual(state.cacheStatus, "Updating settings…", "Stale isn't updating")
        XCTAssertEqual(sleeper.requested, [.seconds(40)], "Five notices, one read, the rest of the minute away")
        sleeper.release()
        await settle { plugin.propertyCalls == 2 && !state.busy }
        XCTAssertEqual(plugin.propertyCalls, 2)
        XCTAssertFalse(state.dirty)
        XCTAssertEqual(sleeper.pending, 0, "Nothing new: no further read waits")
        // A read that fails still counts: a failing body isn't read on every notice.
        plugin.propertyFailures = 1
        clock.date = clock.date.addingTimeInterval(90)
        plugin.handler?(.changed(feedID: "feed", generation: state.generation))
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.requested.last, .zero, "Stale for longer than the interval: read now")
        sleeper.release()
        await settle { plugin.propertyCalls == 3 && !state.busy }
        XCTAssertEqual(state.cacheStatus, "Settings update failed")
        plugin.handler?(.changed(feedID: "feed", generation: state.generation))
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.requested.last, .seconds(60), "The next read waits a whole interval after the failed one")
        _ = await store.shutdown()
    }

    func testUpdatingShowsOnlyWhileTheBodyIsRead() async {
        let plugin = SuspendedControlPlugin()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments())
        await store.connect(camera: plugin.camera, to: "feed", credentials: Self.secret, saveCredentials: false)
        let state = store.state(for: "feed")
        XCTAssertTrue(state.cacheStatus.hasPrefix("Updated "))
        plugin.holdRead = true
        let reading = Task { await store.refresh("feed") }
        await settle { plugin.read != nil }
        XCTAssertEqual(state.cacheStatus, "Updating settings…")
        plugin.read?.resume(returning: []); plugin.read = nil
        await reading.value
        plugin.holdRead = false
        XCTAssertTrue(state.cacheStatus.hasPrefix("Updated "))
        plugin.propertyFailures = 1
        await store.refresh("feed")
        XCTAssertEqual(state.cacheStatus, "Settings update failed")
        _ = await store.shutdown()
        XCTAssertEqual(state.cacheStatus, "Disconnected · cached values")
    }

    func testNeverReadsOnlyOnConnectRefreshAndAfterAChangeMadeHereAndIsSaved() async {
        let suite = "org.ultracam.tests.control-refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plugin = SuspendedControlPlugin(), sleeper = RetrySleeper()
        plugin.propertyValues = [Self.iso]
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(),
            persistence: CameraControlPreferences(defaults: defaults), refreshSleep: { try await sleeper.sleep($0) })
        XCTAssertEqual(store.refreshInterval, .seconds60, "Unset reads as the standard minute")
        store.refreshInterval = .never
        XCTAssertEqual(defaults.string(forKey: CameraControlPreferences.refreshIntervalKey), "never")
        XCTAssertEqual(CameraControlStore(plugins: [:], credentials: MemoryControlCredentials(),
            persistence: CameraControlPreferences(defaults: defaults)).refreshInterval, .never, "Kept across launches")
        defaults.set("fortnightly", forKey: CameraControlPreferences.refreshIntervalKey)
        XCTAssertNil(CameraControlPreferences(defaults: defaults).loadRefreshInterval(), "An unknown choice reads as unset")
        await store.connect(camera: plugin.camera, to: "feed", credentials: Self.secret, saveCredentials: false)
        let state = store.state(for: "feed")
        XCTAssertEqual(plugin.propertyCalls, 1, "Still read on connecting")
        for _ in 0..<3 { plugin.handler?(.changed(feedID: "feed", generation: state.generation)) }
        await settle { false }
        XCTAssertTrue(sleeper.requested.isEmpty, "Never: no read waits")
        XCTAssertEqual(plugin.propertyCalls, 1)
        XCTAssertTrue(state.dirty)
        await store.set(Self.iso, value: .unsignedInteger(1_600), feedID: "feed")
        XCTAssertEqual(plugin.setCalls, 1)
        XCTAssertEqual(plugin.propertyCalls, 2, "Read right after a change made here")
        plugin.handler?(.changed(feedID: "feed", generation: state.generation))
        await store.refresh("feed")
        XCTAssertEqual(plugin.propertyCalls, 3, "Refresh reads")
        XCTAssertFalse(state.dirty)
        XCTAssertTrue(sleeper.requested.isEmpty)
        _ = await store.shutdown()
    }

    func testChangingTheIntervalRetimesAWaitingReadAndRefreshReplacesIt() async {
        let plugin = SuspendedControlPlugin(), sleeper = RetrySleeper(), clock = RefreshClock()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments(),
            now: { clock.date }, refreshSleep: { try await sleeper.sleep($0) })
        await store.connect(camera: plugin.camera, to: "feed", credentials: Self.secret, saveCredentials: false)
        let state = store.state(for: "feed")
        plugin.handler?(.changed(feedID: "feed", generation: state.generation))
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.requested, [.seconds(60)])
        store.refreshInterval = .seconds15
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested.last, .seconds(15), "A shorter interval shortens the wait")
        store.refreshInterval = .never
        sleeper.release()
        await settle { false }
        XCTAssertEqual(plugin.propertyCalls, 1, "Never cancels the waiting read")
        store.refreshInterval = .minutes5
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.requested.last, .seconds(300), "Still stale: a longer interval waits again")
        await store.refresh("feed")
        XCTAssertEqual(plugin.propertyCalls, 2)
        sleeper.release()
        await settle { false }
        XCTAssertEqual(plugin.propertyCalls, 2, "Refresh stands in for the read that was waiting")
        _ = await store.shutdown()
    }

    /// "Settings update failed" is about the last read. A sign-in that couldn't be saved is its
    /// own message, and a notice after a good read only makes the values stale.
    func testOnlyAFailedReadSaysTheSettingsUpdateFailed() async {
        let plugin = SuspendedControlPlugin(), credentials = MemoryControlCredentials(), sleeper = RetrySleeper()
        await credentials.setSaveFailure(true)
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: MemoryControlAssignments(),
            refreshSleep: { try await sleeper.sleep($0) })
        await store.connect(camera: plugin.camera, to: "feed", credentials: Self.secret)
        let state = store.state(for: "feed")
        XCTAssertTrue(state.connected)
        XCTAssertNotNil(state.message, "The sign-in that couldn't be saved says so")
        plugin.handler?(.changed(feedID: "feed", generation: state.generation))
        XCTAssertTrue(state.dirty)
        XCTAssertTrue(state.cacheStatus.hasPrefix("Updated "), "The read worked: stale isn't failed")
        plugin.propertyFailures = 1
        await store.refresh("feed")
        XCTAssertEqual(state.cacheStatus, "Settings update failed")
        await store.refresh("feed")
        XCTAssertTrue(state.cacheStatus.hasPrefix("Updated "), "A read that works clears it")
        _ = await store.shutdown()
    }

    /// A write that fails doesn't take the waiting read with it: it follows on the interval,
    /// and Never still waits for Refresh.
    func testAFailedWriteKeepsTheWaitingRead() async {
        let plugin = SuspendedControlPlugin(), sleeper = RetrySleeper(), clock = RefreshClock()
        plugin.propertyValues = [Self.iso]
        let store = CameraControlStore(plugins: ["test": plugin], credentials: MemoryControlCredentials(), persistence: MemoryControlAssignments(),
            now: { clock.date }, refreshSleep: { try await sleeper.sleep($0) })
        await store.connect(camera: plugin.camera, to: "feed", credentials: Self.secret, saveCredentials: false)
        let state = store.state(for: "feed")
        clock.date = clock.date.addingTimeInterval(20)
        plugin.handler?(.changed(feedID: "feed", generation: state.generation))
        await settle { sleeper.requested.count == 1 }
        XCTAssertEqual(sleeper.requested, [.seconds(40)])
        plugin.setFailures = 1
        await store.set(Self.iso, value: .unsignedInteger(1_600), feedID: "feed")
        XCTAssertEqual(plugin.setCalls, 1)
        XCTAssertNotNil(state.message)
        await settle { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested, [.seconds(40), .seconds(40)], "Waits again, the rest of the minute since the last read")
        sleeper.release()
        await settle { plugin.propertyCalls == 2 && !state.busy }
        XCTAssertEqual(plugin.propertyCalls, 2, "The stale values are read")
        store.refreshInterval = .never
        plugin.handler?(.changed(feedID: "feed", generation: state.generation))
        plugin.setFailures = 1
        await store.set(Self.iso, value: .unsignedInteger(1_600), feedID: "feed")
        await settle { false }
        XCTAssertEqual(sleeper.requested.count, 2, "Never: nothing waits")
        XCTAssertEqual(plugin.propertyCalls, 2)
        _ = await store.shutdown()
    }
}
#endif
