#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@MainActor @objcMembers final class CameraControlUIStateChecks: XCTestCase {
    func testVendorBadgeUsesDeclaredAssetAndTextFallback() {
        let image = VendorDescriptor(id: "fixture", displayName: "Fixture", badgeText: "FIX", signalHint: nil, sdkVersion: nil, sdkPresent: true, badgeAssetName: "FixtureBadge")
        let text = VendorDescriptor(id: "other", displayName: "Other", badgeText: "OTHER", signalHint: nil, sdkVersion: nil, sdkPresent: true)
        XCTAssertEqual(UIControlPresentation.badge(image), .asset("FixtureBadge"))
        XCTAssertEqual(UIControlPresentation.badge(text), .text("OTHER"))
        XCTAssertEqual(UIControlPresentation.badge(image, assetAvailable: { _ in false }), .text("FIX"))
    }
    func testSelectionPinIsRecheckedBeforeInitialCredentialLookup() async throws {
        let plugin = UIChangedIdentityPlugin()
        let selected = plugin.camera
        plugin.camera.fingerprint = "replacement"
        let credentials = UIControlCredentials()
        let store = CameraControlStore(plugins: ["test": plugin], credentials: credentials, persistence: UIControlPersistence())
        await store.connect(camera: selected, to: "feed")
        let count = await credentials.loads
        XCTAssertEqual(count, 0)
        XCTAssertEqual(plugin.connectCount, 0)
        XCTAssertNil(store.assignment(for: "feed"))
        guard count == 0, plugin.connectCount == 0 else { throw UIControlFailure.identityWasNotPinned }
    }
}
private enum UIControlFailure: Error { case identityWasNotPinned }
@MainActor private final class UIControlPersistence: CameraControlAssignmentPersisting {
    func load() throws -> CameraControlAssignmentSnapshot { .init() }
    func save(_ snapshot: CameraControlAssignmentSnapshot) throws {}
}
private actor UIControlCredentials: CameraControlCredentialStoring {
    var loads = 0
    func load(service: String, account: String) async throws -> ControlCredentials? { loads += 1; return .usernamePassword(username: "user", password: "secret") }
    func save(_ credentials: ControlCredentials, service: String, account: String) async throws {}
    func delete(service: String, account: String) async throws {}
}
@MainActor private final class UIChangedIdentityPlugin: CameraControlPlugin {
    nonisolated let descriptor = VendorDescriptor(id: "test", displayName: "Test", badgeText: "TEST", signalHint: nil, sdkVersion: nil, sdkPresent: true)
    nonisolated let credentialService = "test"
    var camera = ControlCamera(pluginID: "test", id: "camera", name: "Camera", transport: .network, address: "192.0.2.1", fingerprint: "pin", authenticationMode: .usernamePassword)
    var connectCount = 0
    nonisolated func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String { camera.id + fingerprint }
    func discover() async throws -> [ControlCamera] { [camera] }
    func prepare(_ request: ControlPreparationRequest) async throws -> ControlPreparationResult { .init(camera: camera, pairingRequirement: .usernamePassword(fingerprint: camera.fingerprint!)) }
    func connect(feedID: String, generation: UInt64, camera: ControlCamera, credentials: ControlCredentials?) async throws { connectCount += 1 }
    func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty] { [] }
    func set(_ property: String, value: ControlValue, feedID: String, generation: UInt64) async throws {}
    func disconnect(feedID: String, generation: UInt64) async throws {}
    func shutdown() async throws {}
    func setEventHandler(_ handler: @escaping @MainActor @Sendable (ControlEvent) -> Void) {}
}
#endif
