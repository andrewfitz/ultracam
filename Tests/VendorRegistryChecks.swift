#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class VendorRegistryChecks: XCTestCase {
  @MainActor func testPartialFailureAndOrderedUpdates() throws {
    let good = RegistryFixture(id: "good", devices: [Self.device("good:a")])
    let bad = RegistryFixture(id: "bad", devices: [], fails: true)
    let registry = try VendorRegistry(capture: [good, bad])
    XCTAssertEqual(registry.snapshot.devices.map(\.id), ["good:a"])
    XCTAssertNotNil(registry.snapshot.capture[1].error)
    var counts: [Int] = []
    let token = registry.observe { counts.append($0.devices.count) }
    good.emit([Self.device("good:b"), Self.device("good:c")])
    good.emit([], error: .failed("lost enumeration"))
    XCTAssertEqual(counts, [1, 2, 0])
    XCTAssertNotNil(registry.snapshot.capture[1].error)
    token.cancel()
    good.emit([Self.device("good:a")])
    XCTAssertEqual(counts, [1, 2, 0])
  }
  @MainActor func testIdentityValidationAndOpaqueSuffix() throws {
    XCTAssertThrowsError(try VendorRegistry(capture: [RegistryFixture(id: "Bad", devices: [])]))
    XCTAssertThrowsError(try VendorRegistry(capture: [RegistryFixture(id: "a", devices: []), RegistryFixture(id: "a", devices: [])]))
    let registry = try VendorRegistry(capture: [RegistryFixture(id: "a", devices: [Self.device("a:legacy:name:0")])])
    XCTAssertEqual(try registry.capturePlugin(for: "a:legacy:name:0").descriptor.id, "a")
    for id in ["a", ":x", "a:", "Bad:x", "unknown:x"] { XCTAssertThrowsError(try registry.capturePlugin(for: id)) }
    let malformed = try VendorRegistry(capture: [RegistryFixture(id: "a", devices: [Self.device("other:x")])])
    XCTAssertTrue(malformed.snapshot.devices.isEmpty)
    XCTAssertNotNil(malformed.snapshot.capture[0].error)
    let duplicates = try VendorRegistry(capture: [RegistryFixture(id: "a", devices: [Self.device("a:x"), Self.device("a:x")])])
    XCTAssertTrue(duplicates.snapshot.devices.isEmpty)
  }
  func testClaimsSharingFailureAndStop() throws {
    let claims = CaptureDeviceClaims()
    let exclusive = Self.device("a:x")
    try claims.claim(device: exclusive, ownerID: "one")
    XCTAssertThrowsError(try claims.claim(device: exclusive, ownerID: "two"))
    claims.releaseAll(ownerID: "one")
    try claims.claim(device: exclusive, ownerID: "two")
    claims.releaseAll(ownerID: "two")
    let shared = Self.device("a:shared", shareable: true)
    try claims.claim(device: shared, ownerID: "one")
    try claims.claim(device: shared, ownerID: "two")
    let plugin = RegistryFixture(id: "a", devices: [exclusive])
    plugin.session.fail = true
    let failed = claims.makeSession(plugin: plugin, device: exclusive, ownerID: "one")
    XCTAssertThrowsError(try failed.start(deviceID: exclusive.id, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in })))
    try claims.claim(device: exclusive, ownerID: "two")
    claims.releaseAll(ownerID: "two")
    plugin.session.fail = false
    let running = claims.makeSession(plugin: plugin, device: exclusive, ownerID: "one")
    try running.start(deviceID: exclusive.id, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in }))
    XCTAssertThrowsError(try claims.claim(device: exclusive, ownerID: "two"))
    running.stop()
    try claims.claim(device: exclusive, ownerID: "two")
  }
  func testSameOwnerCannotOpenTwoExclusiveSessions() throws {
    let claims = CaptureDeviceClaims()
    let device = Self.device("a:x")
    let plugin = RegistryFixture(id: "a", devices: [device])
    let first = claims.makeSession(plugin: plugin, device: device, ownerID: "feed")
    let second = claims.makeSession(plugin: plugin, device: device, ownerID: "feed")
    try first.start(deviceID: device.id, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in }))
    let neverStarted = claims.makeSession(plugin: plugin, device: device, ownerID: "feed")
    neverStarted.stop()
    XCTAssertThrowsError(try claims.claim(device: device, ownerID: "other"))
    do {
      let abandoned = claims.makeSession(plugin: plugin, device: device, ownerID: "feed")
      withExtendedLifetime(abandoned) {}
    }
    XCTAssertThrowsError(try claims.claim(device: device, ownerID: "other"))
    XCTAssertThrowsError(try second.start(deviceID: device.id, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in })))
    second.stop()
    XCTAssertThrowsError(try claims.claim(device: device, ownerID: "other"))
    first.stop()
    try claims.claim(device: device, ownerID: "other")
  }
  static func device(_ id: String, shareable: Bool = false) -> CaptureDeviceInfo {
    CaptureDeviceInfo(id: id, name: id, connectors: [], shareable: shareable, mayPause: nil, supportedModes: "")
  }
}
private final class RegistryFixture: CaptureSourcePlugin, @unchecked Sendable {
  let descriptor: VendorDescriptor
  let list: [CaptureDeviceInfo]
  let fails: Bool
  let session = RegistrySession()
  @MainActor private var observations: [DeviceObservation] = []
  init(id: String, devices: [CaptureDeviceInfo], fails: Bool = false) {
    descriptor = VendorDescriptor(id: id, displayName: id, badgeText: id, signalHint: nil, sdkVersion: nil, sdkPresent: true)
    list = devices; self.fails = fails
  }
  func driverStatus() -> DriverStatus { DriverStatus(installed: true, supported: true, version: nil, reason: nil) }
  func devices() throws -> [CaptureDeviceInfo] { if fails { throw PluginError.failed("enumeration") }; return list }
  @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation {
    let token = DeviceObservation(handler); observations.append(token); return token
  }
  @MainActor func emit(_ devices: [CaptureDeviceInfo], error: PluginError? = nil) {
    observations.forEach { $0.deliver(CaptureDeviceSnapshot(status: driverStatus(), devices: devices, error: error)) }
  }
  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat? { nil }
  func makeSession() -> any CaptureSession { session }
  func diagnostics(deviceID: String) -> DeviceDiagnostics? { nil }
  func settings(deviceID: String) async throws -> [VendorSetting] { [] }
  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String) async throws {}
}
private final class RegistrySession: CaptureSession, @unchecked Sendable {
  var fail = false
  var counters: CaptureCounters { CaptureCounters() }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws { if fail { throw PluginError.failed("start") } }
  func stop() {}
}
#endif
