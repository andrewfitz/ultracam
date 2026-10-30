import Foundation
import Observation

struct CameraControlAssignment: Codable, Equatable, Sendable {
    var camera: ControlCamera
    var showOverlay = false
    var preparationRequest: ControlPreparationRequest? = nil
}
struct CameraControlAssignmentSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var plugins: [String: [String: CameraControlAssignment]] = [:]
}
@MainActor protocol CameraControlAssignmentPersisting {
    func load() throws -> CameraControlAssignmentSnapshot
    func save(_ snapshot: CameraControlAssignmentSnapshot) throws
}

/// A verified write precedes the migration marker; legacy data remains recoverable.
@MainActor final class CameraControlPreferences: CameraControlAssignmentPersisting {
    static let preferencesKey = "ui.camera.controls.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> CameraControlAssignmentSnapshot {
        if let data = defaults.data(forKey: Self.preferencesKey) {
            let snapshot = try JSONDecoder().decode(CameraControlAssignmentSnapshot.self, from: data)
            guard snapshot.version == 1 else { throw ControlError(code: .unsupported, retryable: false, message: "Unsupported camera assignment version.") }
            return snapshot
        }
        guard let data = defaults.data(forKey: "ui.sony.controls.v1") else { return .init() }
        struct LegacyCamera: Decodable { var id: String; var model: String; var address: String; var authentication: Bool; var fingerprint: String; var name: String? }
        struct LegacyAssignment: Decodable { var camera: LegacyCamera; var showOverlay: Bool? }
        let legacy = try JSONDecoder().decode([String: LegacyAssignment].self, from: data)
        let assignments = legacy.mapValues { entry in
            CameraControlAssignment(camera: .init(pluginID: "sony", id: entry.camera.id,
                name: entry.camera.name.flatMap { $0.isEmpty ? nil : $0 } ?? entry.camera.model,
                transport: .network, address: entry.camera.address, fingerprint: entry.camera.fingerprint,
                authenticationMode: entry.camera.authentication ? .usernamePassword : .none), showOverlay: entry.showOverlay ?? false)
        }
        let snapshot = CameraControlAssignmentSnapshot(plugins: ["sony": assignments])
        try save(snapshot)
        guard let written = defaults.data(forKey: Self.preferencesKey),
            try JSONDecoder().decode(CameraControlAssignmentSnapshot.self, from: written) == snapshot else {
            throw ControlError(code: .sdkFailure, retryable: true, message: "Camera assignment migration could not be verified.")
        }
        defaults.set(true, forKey: "ui.camera.controls.sony-migrated.v1")
        return snapshot
    }
    func save(_ snapshot: CameraControlAssignmentSnapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.preferencesKey)
    }
}

@MainActor @Observable final class CameraControlFeedState {
    var connected = false
    var busy = false
    var dirty = false
    var properties: [ControlProperty] = []
    var message: String?
    var lastRefresh: Date?
    var hasSavedCredentials = false
    var generation: UInt64 = 0
    var invalidationRevision: UInt64 = 0
    var cacheStatus: String {
        if !connected { return "Disconnected · cached values" }
        if dirty { return message == nil ? "Updating settings…" : "Settings update failed" }
        return "Settings up to date"
    }
}

@MainActor @Observable final class CameraControlStore {
    private(set) var assignments: [String: [String: CameraControlAssignment]] = [:]
    private(set) var cameras: [String: [ControlCamera]] = [:]
    private(set) var discoveryMessages: [String: String] = [:]
    private(set) var scanning: Set<String> = []
    private(set) var shuttingDown = false
    @ObservationIgnored private let plugins: [String: any CameraControlPlugin]
    @ObservationIgnored private let credentials: any CameraControlCredentialStoring
    @ObservationIgnored private let persistence: any CameraControlAssignmentPersisting
    @ObservationIgnored private let now: @MainActor () -> Date
    private var states: [String: CameraControlFeedState] = [:]
    private var routes: [String: String] = [:]
    private var preparedRequests: [String: ControlPreparationRequest] = [:]
    private var persistenceWritable = true
    private var pendingCameras: [String: ControlCamera] = [:]
    private var removed: Set<String> = []
    private var manuallyDisconnected: Set<String> = []
    private var savedCredentialIdentities: Set<String> = []
    private var restored = false
    private var requestedWork = false
    private final class PendingCleanup {
        let generation: UInt64
        let plugin: any CameraControlPlugin
        var task: Task<String?, Never>?
        init(generation: UInt64, plugin: any CameraControlPlugin) { self.generation = generation; self.plugin = plugin }
    }
    @ObservationIgnored private var pendingCleanup: [String: [UInt64: PendingCleanup]] = [:]
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var discoveryTasks: [String: Task<Void, Never>] = [:]
    private var lastSuccessfulDiscovery: [String: Date] = [:]
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<String?, Never>?
    var needsShutdown: Bool { requestedWork }
    var available: Bool { plugins.values.contains { $0.descriptor.sdkPresent } }
    var descriptors: [VendorDescriptor] { plugins.values.map(\.descriptor).sorted { $0.localizedDisplayName() < $1.localizedDisplayName() } }

    init(plugins: [String: any CameraControlPlugin], credentials: any CameraControlCredentialStoring = CameraControlKeychain(),
        persistence: any CameraControlAssignmentPersisting = CameraControlPreferences(),
        now: @escaping @MainActor () -> Date = { Date() }) {
        self.plugins = plugins; self.credentials = credentials; self.persistence = persistence; self.now = now
        do { assignments = try persistence.load().plugins }
        catch { persistenceWritable = false; discoveryMessages["persistence"] = error.localizedDescription }
        for (id, plugin) in plugins {
            plugin.setEventHandler { [weak self] event in self?.handle(event, pluginID: id) }
        }
    }
    func descriptor(for pluginID: String) -> VendorDescriptor? { plugins[pluginID]?.descriptor }
    func state(for feedID: String) -> CameraControlFeedState {
        if let state = states[feedID] { return state }
        let state = CameraControlFeedState(); states[feedID] = state; return state
    }
    func assignment(for feedID: String, pluginID: String? = nil) -> CameraControlAssignment? {
        if let pluginID { return assignments[pluginID]?[feedID] }
        return assignments.keys.sorted().compactMap { assignments[$0]?[feedID] }.first
    }
    func holder(of cameraID: String, pluginID: String, excluding feedID: String) -> String? {
        assignments[pluginID]?.first { $0.key != feedID && $0.value.camera.id == cameraID }?.key
            ?? pendingCameras.first { $0.key != feedID && $0.value.pluginID == pluginID && $0.value.id == cameraID }?.key
    }
    func discover(pluginID: String, force: Bool = true) async {
        guard !shuttingDown, let plugin = plugins[pluginID] else { return }
        if let task = discoveryTasks[pluginID] { await task.value; return }
        if !force, let date = lastSuccessfulDiscovery[pluginID] {
            let age = now().timeIntervalSince(date)
            if age >= 0 && age < 30 { return }
        }
        scanning.insert(pluginID); requestedWork = true
        let task = Task { @MainActor in
            defer { self.scanning.remove(pluginID) }
            do {
                let discovered = try await plugin.discover()
                guard !self.shuttingDown, !Task.isCancelled else { return }
                let detected = Set(discovered.map(\.id))
                let manual = (self.cameras[pluginID] ?? []).filter { camera in
                    guard !detected.contains(camera.id), let request = self.preparedRequests[self.cameraKey(camera)] else { return false }
                    if case .endpoint = request { return true }
                    return false
                }
                self.cameras[pluginID] = discovered + manual
                self.lastSuccessfulDiscovery[pluginID] = self.now()
                self.discoveryMessages.removeValue(forKey: pluginID)
            } catch {
                guard !self.shuttingDown else { return }
                self.discoveryMessages[pluginID] = error.localizedDescription
            }
        }
        discoveryTasks[pluginID] = task
        await task.value
        discoveryTasks.removeValue(forKey: pluginID)
    }
    func discoverIfNeeded(pluginID: String) async { await discover(pluginID: pluginID, force: false) }
    func prepare(pluginID: String, request: ControlPreparationRequest, feedID: String) async -> ControlPreparationResult? {
        let state = state(for: feedID)
        guard !state.busy, !state.connected, !shuttingDown, !removed.contains(feedID), let plugin = plugins[pluginID] else { return nil }
        let generation = begin(feedID, pluginID)
        defer {
            if Task.isCancelled, state.generation == generation { retire(feedID) }
            finish(feedID, generation)
        }
        do {
            var result = try await plugin.prepare(request)
            guard current(feedID, generation) else { return nil }
            if case .endpoint = request, let known = cameras[pluginID]?.first(where: { $0.id == result.camera.id }), !known.name.isEmpty { result.camera.name = known.name }
            try validate(result.camera, feedID: feedID, pluginID: pluginID)
            preparedRequests[cameraKey(result.camera)] = request
            addCamera(result.camera)
            return result
        } catch { report(error, feedID, generation); return nil }
    }
    func connect(camera: ControlCamera, to feedID: String, credentials supplied: ControlCredentials? = nil, saveCredentials: Bool = true) async {
        let state = state(for: feedID)
        guard !state.busy, !state.connected, !shuttingDown, !removed.contains(feedID), let plugin = plugins[camera.pluginID] else { return }
        manuallyDisconnected.remove(feedID)
        let generation = begin(feedID, camera.pluginID)
        defer {
            if state.generation == generation { pendingCameras.removeValue(forKey: feedID) }
            if Task.isCancelled {
                Task { @MainActor [weak self] in await self?.cancel(feedID: feedID, generation: generation, plugin: plugin) }
            }
            finish(feedID, generation)
        }
        do {
            try await drainCleanup(feedID)
            // A reset/removal may have retired another feed that still owns
            // this plugin's camera. Retry those exact owners before SDK connect.
            let retiredFeeds = pendingCleanup.keys.sorted().filter { otherFeed in
                otherFeed != feedID && pendingCleanup[otherFeed]?.values.contains(where: { $0.plugin.descriptor.id == camera.pluginID }) == true
            }
            for retiredFeed in retiredFeeds {
                try await drainCleanup(retiredFeed)
                guard current(feedID, generation) else { return }
            }
            guard current(feedID, generation) else { return }
            let request = preparedRequests[cameraKey(camera)] ?? assignment(for: feedID)?.preparationRequest ?? .camera(camera)
            var prepared = try await plugin.prepare(request)
            guard current(feedID, generation) else { return }
            try validate(prepared.camera, feedID: feedID, pluginID: camera.pluginID)
            guard prepared.camera.id == camera.id, camera.fingerprint == nil || prepared.camera.fingerprint == camera.fingerprint else {
                throw ControlError(code: .changedIdentity, retryable: false, message: "Camera identity changed after selection. Check the camera again before signing in.")
            }
            if case .endpoint = request, !camera.name.isEmpty { prepared.camera.name = camera.name }
            let resolved = prepared.camera
            pendingCameras[feedID] = resolved
            let credential: ControlCredentials?
            switch prepared.pairingRequirement {
            case .none: credential = nil
            case .unsupported(let reason): throw ControlError(code: .unsupported, retryable: false, message: reason)
            case .usernamePassword(let fingerprint):
                guard resolved.fingerprint == fingerprint, !fingerprint.isEmpty else {
                    throw ControlError(code: .changedIdentity, retryable: false, message: "Camera identity could not be verified.")
                }
                if let supplied { credential = supplied }
                else {
                    credential = try await credentials.load(service: plugin.credentialService,
                        account: plugin.credentialAccount(for: resolved, fingerprint: fingerprint))
                    guard current(feedID, generation) else { return }
                    state.hasSavedCredentials = credential != nil
                }
                guard credential != nil else { throw ControlError(code: .authentication, retryable: false, message: "Camera sign-in is required.") }
            }
            try await withTaskCancellationHandler {
                try await plugin.connect(feedID: feedID, generation: generation, camera: resolved, credentials: credential)
            } onCancel: {
                Task { @MainActor [weak self] in await self?.cancel(feedID: feedID, generation: generation, plugin: plugin) }
            }
            guard current(feedID, generation) else {
                _ = await cleanupConnection(feedID: feedID, generation: generation, plugin: plugin); return
            }
            assignments[resolved.pluginID, default: [:]][feedID] = .init(camera: resolved, showOverlay: assignment(for: feedID)?.showOverlay ?? false, preparationRequest: request)
            persist(); addCamera(resolved)
            state.connected = true; state.dirty = true
            // Pairing succeeded independently of whether the camera can read
            // properties right now. Save only after confirmed connect, and do
            // not let a vault failure prevent the initial settings read.
            if saveCredentials, let supplied, let fingerprint = resolved.fingerprint, resolved.authenticationMode == .usernamePassword {
                do {
                    try await credentials.save(supplied, service: plugin.credentialService,
                        account: plugin.credentialAccount(for: resolved, fingerprint: fingerprint))
                    guard current(feedID, generation) else { return }
                    state.hasSavedCredentials = true
                    savedCredentialIdentities.insert(credentialKey(resolved))
                } catch {
                    guard current(feedID, generation) else { return }
                    state.message = "Connected, but the camera sign-in could not be saved. \(error.localizedDescription)"
                }
            }
            let revision = state.invalidationRevision
            let properties = try await plugin.properties(feedID: feedID, generation: generation)
            guard current(feedID, generation) else { return }
            apply(properties, state: state, revision: revision)
        } catch {
            if !current(feedID, generation) { _ = await cleanupConnection(feedID: feedID, generation: generation, plugin: plugin); return }
            state.message = [state.message, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            state.dirty = true
            if !state.connected { _ = await cleanupConnection(feedID: feedID, generation: generation, plugin: plugin) }
        }
    }
    func hasSavedCredentials(for camera: ControlCamera) -> Bool { savedCredentialIdentities.contains(credentialKey(camera)) }
    private func credentialKey(_ camera: ControlCamera) -> String { cameraKey(camera) + "|" + (camera.fingerprint ?? "") }
    func checkSavedCredentials(for camera: ControlCamera, feedID: String) async {
        guard camera.authenticationMode == .usernamePassword, !shuttingDown,
            let plugin = plugins[camera.pluginID] else { return }
        guard let prepared = await prepare(pluginID: camera.pluginID,
            request: preparedRequests[cameraKey(camera)] ?? .camera(camera), feedID: feedID),
            prepared.camera.id == camera.id, prepared.camera.fingerprint == camera.fingerprint,
            let fingerprint = camera.fingerprint else { return }
        let generation = state(for: feedID).generation
        do {
            let saved = try await credentials.load(service: plugin.credentialService,
                account: plugin.credentialAccount(for: camera, fingerprint: fingerprint)) != nil
            guard current(feedID, generation) else { return }
            if saved { savedCredentialIdentities.insert(credentialKey(camera)) }
            else { savedCredentialIdentities.remove(credentialKey(camera)) }
            state(for: feedID).hasSavedCredentials = saved
        } catch { report(error, feedID, generation) }
    }
    func connectUsingSavedCredentials(_ camera: ControlCamera, to feedID: String) async {
        await connect(camera: camera, to: feedID, saveCredentials: false)
    }
    func reset() {
        let cleanup = states.map { feed, state in (feed, state.generation, plugin(for: feed)) }
        for feed in Array(states.keys) {
            retire(feed); manuallyDisconnected.insert(feed)
            let state = state(for: feed)
            state.properties = []; state.lastRefresh = nil
            state.hasSavedCredentials = false; state.message = nil
        }
        assignments = [:]; persist()
        for (feed, generation, plugin) in cleanup {
            if let plugin {
                enqueueCleanup(feedID: feed, generation: generation, plugin: plugin)
                Task {
                    let message = await self.cleanupConnection(feedID: feed, generation: generation, plugin: plugin)
                    if self.state(for: feed).generation == generation &+ 1, !self.shuttingDown {
                        self.state(for: feed).message = message
                    }
                }
            }
        }
    }
    func reconnect(_ feedID: String) async {
        guard let assignment = assignment(for: feedID) else { return }
        await connect(camera: assignment.camera, to: feedID, saveCredentials: false)
    }
    func restoreConnections() async {
        if let restoreTask { await restoreTask.value; return }
        guard !restored, !shuttingDown else { return }
        restored = true
        let feeds = Set(assignments.values.flatMap { $0.keys }).sorted()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for feed in feeds where !self.manuallyDisconnected.contains(feed) {
                guard !self.shuttingDown, !Task.isCancelled else { return }
                await self.reconnect(feed)
            }
        }
        restoreTask = task; await task.value; restoreTask = nil
    }
    func refresh(_ feedID: String) async {
        let state = state(for: feedID)
        guard state.connected, !state.busy, !shuttingDown, let plugin = plugin(for: feedID) else { return }
        let generation = state.generation, revision = state.invalidationRevision
        state.busy = true; state.message = nil
        defer { finish(feedID, generation) }
        do {
            let properties = try await plugin.properties(feedID: feedID, generation: generation)
            guard current(feedID, generation) else { return }
            apply(properties, state: state, revision: revision)
        } catch { report(error, feedID, generation) }
    }
    func set(_ property: ControlProperty, value: ControlValue, feedID: String) async {
        let state = state(for: feedID)
        guard state.connected, !state.busy, !shuttingDown,
            let currentProperty = state.properties.first(where: { $0.id == property.id }),
            currentProperty.writable, value.isValid,
            currentProperty.options.isEmpty || currentProperty.options.contains(where: { $0.value == value }),
            let plugin = plugin(for: feedID) else { return }
        let generation = state.generation
        state.busy = true; state.message = nil
        refreshTasks.removeValue(forKey: feedID)?.cancel()
        defer { finish(feedID, generation) }
        do {
            try await plugin.set(property.id, value: value, feedID: feedID, generation: generation)
            guard current(feedID, generation) else { return }
            state.dirty = true
        } catch {
            report(error, feedID, generation)
            return
        }
        // Read once after a successful write. Failed writes keep the last confirmed
        // snapshot stale until a later camera notification or explicit refresh.
        if current(feedID, generation) { state.busy = false; await refresh(feedID) }
    }
    func disconnect(_ feedID: String, forget: Bool = false) async {
        let state = state(for: feedID)
        let generation = state.generation
        let plugin = plugin(for: feedID)
        manuallyDisconnected.insert(feedID)
        retire(feedID)
        if forget {
            for id in Array(assignments.keys) { assignments[id]?.removeValue(forKey: feedID) }
            state.properties = []; state.lastRefresh = nil; state.hasSavedCredentials = false; persist()
        }
        if let plugin {
            let message = await cleanupConnection(feedID: feedID, generation: generation, plugin: plugin)
            if state.generation == generation &+ 1 { state.message = message }
        }
    }
    func removeFeed(_ feedID: String) async { removed.insert(feedID); await disconnect(feedID, forget: true) }
    func showOverlay(_ show: Bool, for feedID: String) {
        guard let camera = assignment(for: feedID)?.camera else { return }
        assignments[camera.pluginID]?[feedID]?.showOverlay = show; persist()
    }
    func forgetCredentials(_ feedID: String) async {
        let state = state(for: feedID)
        guard let camera = assignment(for: feedID)?.camera, let fingerprint = camera.fingerprint,
            let plugin = plugins[camera.pluginID], !shuttingDown, !state.busy else { return }
        let generation = state.generation, revision = state.invalidationRevision
        manuallyDisconnected.insert(feedID)
        state.busy = true; state.message = nil
        refreshTasks.removeValue(forKey: feedID)?.cancel()
        defer {
            finish(feedID, generation)
            if current(feedID, generation), state.invalidationRevision != revision { scheduleRefresh(feedID) }
        }
        do {
            try await credentials.delete(service: plugin.credentialService, account: plugin.credentialAccount(for: camera, fingerprint: fingerprint))
            guard current(feedID, generation) else { return }
            state.hasSavedCredentials = false
            savedCredentialIdentities.remove(credentialKey(camera))
            await disconnect(feedID)
        } catch { report(error, feedID, generation) }
    }
    func shutdown() async -> String? {
        if let shutdownTask { return await shutdownTask.value }
        shuttingDown = true; restoreTask?.cancel()
        for task in discoveryTasks.values { task.cancel() }
        for feed in Array(states.keys) { retire(feed) }
        guard requestedWork else { return nil }
        let task = Task { @MainActor in
            var messages: [String] = []
            for id in self.plugins.keys.sorted() {
                do { try await self.plugins[id]?.shutdown() }
                catch { messages.append(error.localizedDescription) }
            }
            if messages.isEmpty { self.requestedWork = false }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
        shutdownTask = task
        let message = await task.value
        if message != nil { shutdownTask = nil }
        else { pendingCleanup.removeAll() }
        return message
    }
    private func validate(_ camera: ControlCamera, feedID: String, pluginID: String) throws {
        guard camera.pluginID == pluginID, !camera.id.isEmpty else { throw ControlError(code: .invalidRequest, retryable: false, message: "Camera identity could not be resolved.") }
        if let saved = assignment(for: feedID), saved.camera.pluginID != camera.pluginID || saved.camera.id != camera.id || saved.camera.fingerprint != camera.fingerprint {
            throw ControlError(code: .changedIdentity, retryable: false, message: "Camera identity differs from the saved assignment. Unassign and pair again after verifying the camera.")
        }
        if holder(of: camera.id, pluginID: pluginID, excluding: feedID) != nil {
            throw ControlError(code: .busy, retryable: false, message: "Camera is assigned to another feed.")
        }
    }
    private func begin(_ feed: String, _ pluginID: String) -> UInt64 {
        let state = state(for: feed); state.generation &+= 1; state.busy = true; state.message = nil
        routes[feed] = pluginID; requestedWork = true; return state.generation
    }
    private func current(_ feed: String, _ generation: UInt64) -> Bool {
        !Task.isCancelled && !shuttingDown && !removed.contains(feed) && state(for: feed).generation == generation
    }
    private func plugin(for feed: String) -> (any CameraControlPlugin)? {
        (routes[feed] ?? assignment(for: feed)?.camera.pluginID).flatMap { plugins[$0] }
    }
    private func retire(_ feed: String) {
        refreshTasks.removeValue(forKey: feed)?.cancel()
        let state = state(for: feed); state.generation &+= 1; state.invalidationRevision &+= 1
        state.connected = false; state.busy = false; state.dirty = true
        pendingCameras.removeValue(forKey: feed)
    }
    private func cancel(feedID: String, generation: UInt64, plugin: any CameraControlPlugin) async {
        if state(for: feedID).generation == generation { retire(feedID) }
        let message = await cleanupConnection(feedID: feedID, generation: generation, plugin: plugin)
        if state(for: feedID).generation == generation &+ 1, !shuttingDown {
            state(for: feedID).message = message
        }
    }
    private func report(_ error: Error, _ feed: String, _ generation: UInt64) {
        guard current(feed, generation) else { return }
        let state = state(for: feed); state.message = error.localizedDescription; state.dirty = true
    }
    private func finish(_ feed: String, _ generation: UInt64) {
        guard !shuttingDown, !removed.contains(feed), state(for: feed).generation == generation else { return }
        state(for: feed).busy = false
        if !Task.isCancelled, state(for: feed).dirty, state(for: feed).message == nil { scheduleRefresh(feed) }
    }
    private func apply(_ properties: [ControlProperty], state: CameraControlFeedState, revision: UInt64) {
        state.properties = properties; state.lastRefresh = now(); state.dirty = state.invalidationRevision != revision
    }
    private func cameraKey(_ camera: ControlCamera) -> String { "\(camera.pluginID.utf8.count):\(camera.pluginID)\(camera.id)" }
    private func addCamera(_ camera: ControlCamera) {
        cameras[camera.pluginID, default: []].removeAll { $0.id == camera.id }
        cameras[camera.pluginID, default: []].append(camera)
    }
    private func persist() {
        guard persistenceWritable else { return }
        do { try persistence.save(.init(plugins: assignments)) }
        catch { discoveryMessages["persistence"] = error.localizedDescription }
    }
    private func handle(_ event: ControlEvent, pluginID: String) {
        let feed: String, generation: UInt64
        switch event {
        case .changed(let id, let value), .disconnected(let id, let value, _), .error(let id, let value, _): feed = id; generation = value
        }
        guard !shuttingDown, !removed.contains(feed), routes[feed] == pluginID, state(for: feed).generation == generation else { return }
        let state = state(for: feed); state.invalidationRevision &+= 1; state.dirty = true
        switch event {
        case .changed: scheduleRefresh(feed)
        case .disconnected(_, _, let reason):
            retire(feed); state.message = reason.message
            if let plugin = plugins[pluginID] {
                enqueueCleanup(feedID: feed, generation: generation, plugin: plugin)
                Task { _ = await self.cleanupConnection(feedID: feed, generation: generation, plugin: plugin) }
            }
        case .error(_, _, let error): state.message = error.message
        }
    }
    private func startCleanup(_ cleanup: PendingCleanup, feedID: String) {
        guard cleanup.task == nil else { return }
        cleanup.task = Task {
            do { try await cleanup.plugin.disconnect(feedID: feedID, generation: cleanup.generation); return nil }
            catch { return error.localizedDescription }
        }
    }
    private func enqueueCleanup(feedID: String, generation: UInt64, plugin: any CameraControlPlugin) {
        if pendingCleanup[feedID]?[generation] == nil {
            pendingCleanup[feedID, default: [:]][generation] = PendingCleanup(generation: generation, plugin: plugin)
        }
    }
    private func cleanupConnection(feedID: String, generation: UInt64, plugin: any CameraControlPlugin) async -> String? {
        enqueueCleanup(feedID: feedID, generation: generation, plugin: plugin)
        do { try await drainCleanup(feedID); return nil }
        catch { return error.localizedDescription }
    }
    private func drainCleanup(_ feedID: String) async throws {
        // Preserve every retired generation, including cleanup from an old
        // operation that completes after a replacement was admitted.
        let cleanups = (pendingCleanup[feedID] ?? [:]).values.sorted { $0.generation < $1.generation }
        for cleanup in cleanups {
            startCleanup(cleanup, feedID: feedID)
            let message = await cleanup.task?.value
            if let message {
                cleanup.task = nil
                throw ControlError(code: .cleanupPending, retryable: true, message: message)
            }
            if pendingCleanup[feedID]?[cleanup.generation] === cleanup {
                pendingCleanup[feedID]?.removeValue(forKey: cleanup.generation)
                if pendingCleanup[feedID]?.isEmpty == true { pendingCleanup.removeValue(forKey: feedID) }
            }
        }
    }
    private func scheduleRefresh(_ feed: String) {
        let state = state(for: feed)
        guard state.connected, !state.busy, !shuttingDown, refreshTasks[feed] == nil else { return }
        refreshTasks[feed] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.refreshTasks.removeValue(forKey: feed)
            await self.refresh(feed)
        }
    }
}
