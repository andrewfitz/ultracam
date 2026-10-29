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
    var saved: ControlCredentials?
    func load(service: String, account: String) async throws -> ControlCredentials? { loads += 1; return saved }
    func save(_ credentials: ControlCredentials, service: String, account: String) async throws { saved = credentials }
    func delete(service: String, account: String) async throws { saved = nil }
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
    var connectCount = 0
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
        if holdConnect { await withCheckedContinuation { connection = $0 } }
        connectedGeneration = generation; connectedFeedID = feedID
    }
    func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty] {
        if holdRead { return await withCheckedContinuation { read = $0 } }
        return []
    }
    func set(_ property: String, value: ControlValue, feedID: String, generation: UInt64) async throws {}
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

@MainActor @objcMembers final class CameraControlStoreChecks: XCTestCase {
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

}
#endif
