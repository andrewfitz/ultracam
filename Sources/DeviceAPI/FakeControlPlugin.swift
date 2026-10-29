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
    func discover() async throws -> [ControlCamera] { try admit(); return cameras }
    func prepare(_ request: ControlPreparationRequest) async throws -> ControlPreparationResult {
        try admit()
        try Task.checkCancellation()
        let camera: ControlCamera
        switch request {
        case .camera(let candidate):
            guard candidate.pluginID == descriptor.id,
                let resolved = cameras.first(where: { $0.id == candidate.id }) else {
                throw ControlError(code: .removed, retryable: true, message: "Camera is unavailable.")
            }
            camera = resolved
        case .endpoint(let endpoint):
            guard let resolved = cameras.first(where: { $0.address == endpoint.address && $0.transport == endpoint.transport }) else {
                throw ControlError(code: .unavailable, retryable: true, message: "Could not resolve camera identity.")
            }
            guard endpoint.expectedIdentity == nil || endpoint.expectedIdentity == resolved.id else {
                throw ControlError(code: .changedIdentity, retryable: false, message: "Camera identity changed.")
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
        try Task.checkCancellation()
        guard camera.pluginID == descriptor.id, !camera.id.isEmpty else {
            throw ControlError(code: .invalidRequest, retryable: false, message: "Invalid camera identity.")
        }
        guard retired[feedID].map({ generation > $0 }) ?? true,
              connections[feedID].map({ generation >= $0.generation }) ?? true else { throw stale() }
        if camera.authenticationMode == .usernamePassword && credentials == nil {
            throw ControlError(code: .authentication, retryable: false, message: "Credentials required.")
        }
        connections[feedID] = (generation, camera)
    }
    func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty] {
        try check(feedID, generation); return values
    }
    func set(_ property: String, value: ControlValue, feedID: String, generation: UInt64) async throws {
        try check(feedID, generation)
        guard value.isValid, let index = values.firstIndex(where: { $0.id == property }), values[index].writable else {
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
        try admit(); try Task.checkCancellation()
        guard connections[feed]?.generation == generation else { throw stale() }
    }
    private func stale() -> ControlError {
        .init(code: .staleGeneration, retryable: false, message: "Connection generation is retired.")
    }
}
#endif
