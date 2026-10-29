#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class VendorSettingsBootstrapChecks: XCTestCase {
    @MainActor func testPolicyPrecedesEnumerationAndObservation() throws {
        let plugin = BootstrapSettingsPlugin(id: "fixture")
        let policy = VendorSettingsPolicy(desiredByDevice: ["fixture:device": ["fixture:enabled": .boolean(true)]])
        let registry = try VendorRegistry(capture: [plugin], settingsPolicy: policy)
        XCTAssertEqual(plugin.events, ["configure", "devices", "observe"])
        XCTAssertEqual(plugin.policy, policy)
        XCTAssertEqual(registry.snapshot.devices.map(\.id), ["fixture:device"])
    }
    @MainActor func testQuarantinedPluginCannotResolveSavedDeviceForCapture() throws {
        let broken = BootstrapSettingsPlugin(id: "broken", fail: true)
        let registry = try VendorRegistry(capture: [broken])
        var refused = false
        do {
            let plugin = try registry.capturePlugin(for: "broken:device")
            _ = try plugin.devices()
            try plugin.makeSession().start(deviceID: "broken:device", timing: .automatic, handlers: .init(deliver: { _ in }))
        } catch { refused = true }
        XCTAssertTrue(refused)
        XCTAssertEqual(broken.events, ["configure"])
        XCTAssertEqual(broken.session.starts, 0)
        guard refused, broken.events == ["configure"], broken.session.starts == 0 else {
            throw PluginError.failed("A saved device bypassed failed configuration quarantine")
        }
    }
    @MainActor func testConfigurationFailureDoesNotHideHealthyPlugin() throws {
        let healthy = BootstrapSettingsPlugin(id: "healthy")
        let broken = BootstrapSettingsPlugin(id: "broken", fail: true)
        let registry = try VendorRegistry(capture: [broken, healthy])
        XCTAssertEqual(registry.snapshot.devices.map(\.id), ["healthy:device"])
        XCTAssertNotNil(registry.snapshot.capture.first?.error)
        XCTAssertEqual(broken.events, ["configure"])
    }
}
/// All mutable fixture fields are lock protected. No SDK or session is created.
private final class BootstrapSettingsPlugin: CaptureSourcePlugin, @unchecked Sendable {
    let descriptor: VendorDescriptor
    private let lock = NSLock()
    private var recorded: [String] = []
    private var configured: VendorSettingsPolicy?
    let session = BootstrapSession()
    private let fail: Bool
    var events: [String] { lock.withLock { recorded } }
    var policy: VendorSettingsPolicy? { lock.withLock { configured } }
    init(id: String, fail: Bool = false) {
        descriptor = .init(id: id, displayName: id, badgeText: id, signalHint: nil, sdkVersion: nil, sdkPresent: true)
        self.fail = fail
    }
    func configureSettings(_ policy: VendorSettingsPolicy) throws {
        lock.withLock { recorded.append("configure"); configured = policy }
        if fail { throw PluginError.failed("Synthetic configuration failure") }
    }
    func driverStatus() -> DriverStatus { .init(installed: true, supported: true, version: nil, reason: nil) }
    func devices() throws -> [CaptureDeviceInfo] {
        lock.withLock { recorded.append("devices") }
        return [.init(id: descriptor.id + ":device", name: "Fixture", connectors: [], shareable: true, mayPause: nil, supportedModes: "")]
    }
    @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation {
        lock.withLock { recorded.append("observe") }
        return DeviceObservation(handler)
    }
    func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat? { nil }
    func makeSession() -> any CaptureSession { session }
    func diagnostics(deviceID: String) -> DeviceDiagnostics? { nil }
    func settings(deviceID: String) async throws -> [VendorSetting] { [] }
    func apply(_ value: VendorSettingValue, to setting: String, deviceID: String) async throws {}
}
private final class BootstrapSession: CaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var starts: Int { lock.withLock { count } }
    var counters: CaptureCounters { .init() }
    func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws { lock.withLock { count += 1 } }
    func stop() {}
}
#endif
