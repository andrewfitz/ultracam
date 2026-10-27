import Foundation

/// SDK commands must be serialized per feed, including across suspension points.
/// Each queued command checks its generation before touching SDK state. Disconnect
/// retires a generation permanently; repeated disconnect is harmless, and an old
/// disconnect never touches its replacement. Cancellation retires the operation
/// and releases late connections without deleting credentials.
protocol CameraControlPlugin: Sendable {
    var descriptor: VendorDescriptor { get }
    var credentialService: String { get }
    func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String
    func discover() async throws -> [ControlCamera]
    func prepare(_ request: ControlPreparationRequest) async throws -> ControlPreparationResult
    func connect(feedID: String, generation: UInt64, camera: ControlCamera, credentials: ControlCredentials?) async throws
    func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty]
    func set(_ property: ControlProperty.ID, value: ControlValue, feedID: String, generation: UInt64) async throws
    func disconnect(feedID: String, generation: UInt64) async throws
    /// Closes admission. Pending cleanup throws cleanupPending and retains callback owners.
    func shutdown() async throws
    /// Set once. Events are ordered per feed; task reply order is not event order.
    @MainActor func setEventHandler(_ handler: @escaping @MainActor @Sendable (ControlEvent) -> Void)
}
