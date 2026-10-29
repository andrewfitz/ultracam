#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@MainActor @objcMembers final class VendorSettingsHardwareChecks: XCTestCase {
    func testSavedSelectionCannotStartQuarantinedPlugin() throws {
        let plugin = QuarantinedHardwareSpy()
        let registry = try VendorRegistry(capture: [plugin])
        let hardware = AppHardware.registry(registry)
        let services = hardware.captureServices(.primary)
        let start = try XCTUnwrap(services.startTyped)
        XCTAssertThrowsError(try start("blocked:saved-device", .automatic, .init(deliver: { _ in })))
        XCTAssertEqual(plugin.deviceReads, 0)
        XCTAssertEqual(plugin.sessionStarts, 0)
        XCTAssertTrue(hardware.settingsPlugins().isEmpty)
        guard plugin.deviceReads == 0, plugin.sessionStarts == 0 else {
            throw PluginError.failed("Hardware routing bypassed failed configuration")
        }
    }
}
private final class QuarantinedHardwareSpy: CaptureSourcePlugin, CaptureSession, @unchecked Sendable {
    let descriptor = VendorDescriptor(id: "blocked", displayName: "Blocked", badgeText: "BLOCKED", signalHint: nil, sdkVersion: nil, sdkPresent: true)
    private let lock = NSLock()
    private var reads = 0
    private var starts = 0
    var deviceReads: Int { lock.withLock { reads } }
    var sessionStarts: Int { lock.withLock { starts } }
    var counters: CaptureCounters { .init() }
    func configureSettings(_ policy: VendorSettingsPolicy) throws { throw PluginError.failed("Configuration rejected") }
    func driverStatus() -> DriverStatus { .init(installed: true, supported: true, version: nil, reason: nil) }
    func devices() throws -> [CaptureDeviceInfo] {
        lock.withLock { reads += 1 }
        return [.init(id: "blocked:saved-device", name: "Saved input", connectors: [], shareable: true, mayPause: nil, supportedModes: "")]
    }
    @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation { DeviceObservation(handler) }
    func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat? { nil }
    func makeSession() -> any CaptureSession { self }
    func diagnostics(deviceID: String) -> DeviceDiagnostics? { nil }
    func settings(deviceID: String) async throws -> [VendorSetting] { [] }
    func apply(_ value: VendorSettingValue, to setting: String, deviceID: String) async throws {}
    func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws { lock.withLock { starts += 1 } }
    func stop() {}
}
#endif
