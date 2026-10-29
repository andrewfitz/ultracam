#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class VendorHardwareChecks: XCTestCase {
  @MainActor func testRegistryHardwarePreservesIDsAndIndependentFailure() throws {
    let plugin = HardwareFixture()
    let registry = try VendorRegistry(capture: [plugin, HardwareFixture(id: "broken", fails: true)])
    var feeds: [FeedID] = []
    let hardware = AppHardware.registry(registry, captureServices: { id in
      feeds.append(id)
      return AppHardware.offline.captureServices(id)
    })
    XCTAssertEqual(try hardware.devices().map(\.id), ["fixture:persistent", "fixture:Legacy Device:0"])
    XCTAssertNotNil(hardware.driverWarning())
    _ = hardware.captureServices(.primary)
    _ = hardware.captureServices(FeedID(rawValue: "second"))
    XCTAssertEqual(feeds.map(\.rawValue), [FeedID.primary.rawValue, "second"])
    var snapshots: [[String]] = []
    let token = hardware.observeDevices { snapshots.append($0.map(\.id)) }
    plugin.emit([])
    XCTAssertEqual(snapshots, [["fixture:persistent", "fixture:Legacy Device:0"], []])
    withExtendedLifetime(token) {}
    // Missing saved selections remain opaque IDs; the seam never substitutes one.
    XCTAssertTrue(try hardware.devices().isEmpty)
    XCTAssertEqual(try registry.capturePlugin(for: "fixture:Legacy Device:0").descriptor.id, "fixture")
  }
  @MainActor func testRegistryHardwarePropagatesCapabilitiesToInitialAndObservedDevices() throws {
    let plugin = HardwareFixture()
    let hardware = AppHardware.registry(try VendorRegistry(capture: [plugin]))
    let initial = try XCTUnwrap(try hardware.devices().first)
    XCTAssertFalse(initial.shareable)
    XCTAssertNil(initial.mayPause)
    let received = HardwareDeviceRecorder()
    let token = hardware.observeDevices { received.devices = $0 }
    plugin.emit([CaptureDeviceInfo(id: "fixture:shared", name: "Shared", connectors: [.network],
      shareable: true, mayPause: .seconds(12), supportedModes: "")])
    XCTAssertTrue(try XCTUnwrap(received.devices.first).shareable)
    XCTAssertEqual(received.devices.first?.mayPause, .seconds(12))
    withExtendedLifetime(token) {}
    let legacy = InputDevice(id: "legacy", name: "Legacy")
    XCTAssertFalse(legacy.shareable)
    XCTAssertNil(legacy.mayPause)
  }
  @MainActor func testDiagnosticsMappingAndOffline() throws {
    let registry = try VendorRegistry(capture: [HardwareFixture()])
    let hardware = AppHardware.registry(registry)
    let diagnostics = try XCTUnwrap(hardware.diagnostics("fixture:persistent"))
    XCTAssertEqual(diagnostics.counters.deviceDroppedFrames, 7)
    XCTAssertEqual(diagnostics.temperatureCelsius, 42)
    XCTAssertEqual(diagnostics.signalPresent, true)
    XCTAssertTrue(diagnostics.hostTimeMapped)
    XCTAssertEqual(diagnostics.vendorFields, [.init(label: "Driver", value: "1.2")])
    XCTAssertNil(hardware.diagnostics("unknown:unresolved"))
    XCTAssertNil(hardware.diagnostics("malformed"))
    XCTAssertTrue(try AppHardware.offline.devices().isEmpty)
    XCTAssertNil(AppHardware.offline.diagnostics("fixture:persistent"))
  }
}
@MainActor private final class HardwareDeviceRecorder { var devices: [InputDevice] = [] }

private final class HardwareFixture: CaptureSourcePlugin, @unchecked Sendable {
  let descriptor: VendorDescriptor
  let fails: Bool
  private let lock = NSLock()
  private var currentIDs = ["fixture:persistent", "fixture:Legacy Device:0"]
  @MainActor private var tokens: [DeviceObservation] = []
  init(id: String = "fixture", fails: Bool = false) {
    descriptor = VendorDescriptor(id: id, displayName: id, badgeText: id, signalHint: nil, sdkVersion: nil, sdkPresent: true)
    self.fails = fails
  }
  func driverStatus() -> DriverStatus { DriverStatus(installed: !fails, supported: !fails, version: nil, reason: fails ? "Missing driver" : nil) }
  func devices() throws -> [CaptureDeviceInfo] {
    if fails { throw PluginError.unavailable("Missing driver") }
    return lock.withLock { currentIDs }.map {
      CaptureDeviceInfo(id: $0, name: $0, connectors: [.hdmi], shareable: false, mayPause: nil, supportedModes: "")
    }
  }
  @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation {
    let token = DeviceObservation(handler); tokens.append(token); return token
  }
  @MainActor func emit(_ devices: [CaptureDeviceInfo]) {
    lock.withLock { currentIDs = devices.map(\.id) }
    tokens.forEach { $0.deliver(CaptureDeviceSnapshot(status: driverStatus(), devices: devices, error: nil)) }
  }
  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat? { nil }
  func makeSession() -> any CaptureSession { fatalError("Hardware seam checks never start capture") }
  func diagnostics(deviceID: String) -> DeviceDiagnostics? {
    DeviceDiagnostics(counters: CaptureCounters(deviceDroppedFrames: 7), temperatureCelsius: 42,
      signalPresent: true, hostTimeMapped: true, vendorFields: [.init(label: "Driver", value: "1.2")])
  }
  func settings(deviceID: String) async throws -> [VendorSetting] { [] }
  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String) async throws {}
}
#endif
