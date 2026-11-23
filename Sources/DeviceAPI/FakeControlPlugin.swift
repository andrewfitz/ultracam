#if ULTRACAM_TEST_SUPPORT
import Foundation

/// Main-actor isolation serializes all fixture commands without actor reentrancy:
/// no command suspends while reading or mutating connection state.
@MainActor final class FakeControlPlugin: CameraControlPlugin {
    nonisolated let descriptor: VendorDescriptor
    nonisolated let credentialService = "org.ultracam.fake-camera-control.credentials.v1"
    private var cameras: [ControlCamera]
    private var values: [ControlProperty]
    private var connections: [String: (generation: UInt64, camera: ControlCamera)] = [:]
    private var retired: [String: UInt64] = [:]
    private var closed = false
    private var handler: (@MainActor @Sendable (ControlEvent) -> Void)?

    init(descriptor: VendorDescriptor, cameras: [ControlCamera] = [], properties: [ControlProperty] = []) {
        self.descriptor = descriptor
        self.cameras = cameras
        self.values = properties
    }
    nonisolated func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String {
        guard camera.pluginID == descriptor.id, !camera.id.isEmpty, !fingerprint.isEmpty else {
            throw ControlError(code: .invalidRequest, retryable: false, message: "Invalid camera identity.")
        }
        return "\(camera.id.utf8.count):\(camera.id)\(fingerprint)"
    }
    func setEventHandler(_ handler: @escaping @MainActor @Sendable (ControlEvent) -> Void) {
        precondition(self.handler == nil, "The control event handler is installed once.")
        self.handler = handler
    }
    func replaceCameras(_ cameras: [ControlCamera]) {
        self.cameras = cameras
        for (feed, connection) in connections where !cameras.contains(where: { $0.id == connection.camera.id }) {
            connections.removeValue(forKey: feed)
            retired[feed] = max(retired[feed] ?? 0, connection.generation)
            handler?(.disconnected(feedID: feed, generation: connection.generation,
                reason: .init(code: .removed, retryable: true, message: "Camera removed.")))
        }
    }
    /// A notice from a connected body, as a vendor warning callback would send it.
    func postNotice(_ message: String, severity: DeviceSeverity, feedID: String) {
        guard let connection = connections[feedID] else { return }
        handler?(.notice(feedID: feedID, generation: connection.generation, message: message, severity: severity))
    }
    /// Scripted readings: the next read returns these.
    func replaceProperties(_ properties: [ControlProperty]) { values = properties }
    /// How many scans were asked for.
    private(set) var discoveries = 0
    func discover() async throws -> [ControlCamera] {
        try admit()
        try checkCancellation()
        discoveries += 1
        return cameras
    }
    func prepare(_ request: ControlPreparationRequest) async throws -> ControlPreparationResult {
        try admit()
        try checkCancellation()
        let camera: ControlCamera
        switch request {
        case .camera(let candidate):
            guard candidate.pluginID == descriptor.id,
                let resolved = cameras.first(where: { $0.pluginID == descriptor.id && $0.id == candidate.id }) else {
                throw ControlError(code: .removed, retryable: true, message: "Camera is unavailable.")
            }
            if let fingerprint = candidate.fingerprint, fingerprint != resolved.fingerprint { throw changedIdentity() }
            camera = resolved
        case .endpoint(let endpoint):
            guard let resolved = cameras.first(where: {
                $0.pluginID == descriptor.id && $0.address == endpoint.address && $0.transport == endpoint.transport
            }) else {
                throw ControlError(code: .unavailable, retryable: true, message: "Could not resolve camera identity.")
            }
            guard endpoint.expectedIdentity == nil || endpoint.expectedIdentity == resolved.id else {
                throw changedIdentity()
            }
            var candidate = resolved
            candidate.authenticationMode = endpoint.authenticationMode
            camera = candidate
        }
        let pairing: PairingRequirement
        if camera.authenticationMode == .usernamePassword {
            guard let fingerprint = camera.fingerprint, !fingerprint.isEmpty else {
                throw ControlError(code: .authentication, retryable: false, message: "Camera fingerprint is unavailable.")
            }
            pairing = .usernamePassword(fingerprint: fingerprint)
        } else { pairing = .none }
        return .init(camera: camera, pairingRequirement: pairing)
    }
    func connect(feedID: String, generation: UInt64, camera: ControlCamera, credentials: ControlCredentials?) async throws {
        try admit()
        guard camera.pluginID == descriptor.id, !camera.id.isEmpty else {
            throw ControlError(code: .invalidRequest, retryable: false, message: "Invalid camera identity.")
        }
        guard retired[feedID].map({ generation > $0 }) ?? true,
              connections[feedID].map({ generation > $0.generation }) ?? true else { throw stale() }
        if Task.isCancelled {
            retired[feedID] = generation
            try checkCancellation()
        }
        guard let current = cameras.first(where: { $0.pluginID == descriptor.id && $0.id == camera.id }) else {
            throw ControlError(code: .removed, retryable: true, message: "Camera is unavailable.")
        }
        if let fingerprint = camera.fingerprint, fingerprint != current.fingerprint { throw changedIdentity() }
        if camera.authenticationMode == .usernamePassword {
            guard let fingerprint = camera.fingerprint, !fingerprint.isEmpty, credentials != nil else {
                throw ControlError(code: .authentication, retryable: false, message: "Credentials and camera fingerprint required.")
            }
        }
        connections[feedID] = (generation, camera)
    }
    func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty] {
        try check(feedID, generation); return values
    }
    func set(_ property: String, value: ControlValue, feedID: String, generation: UInt64) async throws {
        try check(feedID, generation)
        guard let index = values.firstIndex(where: { $0.id == property }), Self.accepts(value, for: values[index]) else {
            throw ControlError(code: .invalidRequest, retryable: false, message: "Property is not writable or value is invalid.")
        }
        values[index].value = value
        handler?(.changed(feedID: feedID, generation: generation))
    }
    func disconnect(feedID: String, generation: UInt64) async throws {
        retired[feedID] = max(retired[feedID] ?? 0, generation)
        guard connections[feedID]?.generation == generation else { return }
        connections.removeValue(forKey: feedID)
        handler?(.disconnected(feedID: feedID, generation: generation,
            reason: .init(code: .manual, retryable: false, message: "Disconnected.")))
    }
    func shutdown() async throws {
        closed = true
        for (feed, connection) in connections {
            retired[feed] = max(retired[feed] ?? 0, connection.generation)
            handler?(.disconnected(feedID: feed, generation: connection.generation,
                reason: .init(code: .manual, retryable: false, message: "Control shut down.")))
        }
        connections.removeAll()
    }
    private func admit() throws {
        if closed { throw ControlError(code: .invalidState, retryable: false, message: "Control is shut down.") }
    }
    private func check(_ feed: String, _ generation: UInt64) throws {
        try admit()
        try checkCancellation()
        guard connections[feed]?.generation == generation else { throw stale() }
    }
    private func checkCancellation() throws {
        if Task.isCancelled {
            throw ControlError(code: .cancelled, retryable: false, message: "Camera operation was cancelled.")
        }
    }
    private static func accepts(_ value: ControlValue, for property: ControlProperty) -> Bool {
        guard property.writable, value.isValid,
            property.options.isEmpty || property.options.contains(where: { $0.value == value }) else { return false }
        if let range = property.range {
            switch (range.minimum, value, range.maximum) {
            case (.integer(let minimum), .integer(let value), .integer(let maximum)): return minimum <= value && value <= maximum
            case (.unsignedInteger(let minimum), .unsignedInteger(let value), .unsignedInteger(let maximum)): return minimum <= value && value <= maximum
            case (.decimal(let minimum), .decimal(let value), .decimal(let maximum)): return minimum <= value && value <= maximum
            default: return false
            }
        }
        switch (property.value, value) {
        case (.boolean, .boolean), (.integer, .integer), (.unsignedInteger, .unsignedInteger),
             (.decimal, .decimal), (.text, .text), (.choice, .choice): return true
        default: return false
        }
    }
    private func changedIdentity() -> ControlError {
        .init(code: .changedIdentity, retryable: false, message: "Camera identity changed.")
    }
    private func stale() -> ControlError {
        .init(code: .staleGeneration, retryable: false, message: "Connection generation is retired.")
    }
}
#endif
