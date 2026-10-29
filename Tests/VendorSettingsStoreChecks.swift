#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@MainActor private final class MemoryVendorSettings: VendorSettingsPersisting {
    var snapshot = VendorSettingsSnapshot()
    var writes = 0
    func load() throws -> VendorSettingsSnapshot { snapshot }
    func save(_ snapshot: VendorSettingsSnapshot) throws { self.snapshot = snapshot; writes += 1 }
}
private actor SettingsFake: VendorSettingsProviding {
    nonisolated let descriptor = VendorDescriptor(id: "decklink", displayName: "Capture", badgeText: "CAPTURE", signalHint: nil, sdkVersion: nil, sdkPresent: true)
    var values: [String: Bool] = [:]
    var unapplied = false
    var readOnly = false
    var failed = false
    var ignoreWrites = false
    var writes = 0
    private var holdRead = false
    private var pendingRead: CheckedContinuation<[VendorSetting], Never>?
    private var pendingSnapshot: [VendorSetting] = []
    func holdNextRead() { holdRead = true }
    func readIsPending() -> Bool { pendingRead != nil }
    func releaseRead() { pendingRead?.resume(returning: pendingSnapshot); pendingRead = nil }
    func settings(deviceID device: String) async -> [VendorSetting] {
        let snapshot: [VendorSetting] = [.init(id: "decklink:advertiseHDRToCameras", labelKey: "Advertise HDR to cameras", value: .boolean(values[device] ?? false), allowedValues: .unrestricted, mutable: !readOnly, availabilityReason: nil, interruptsCapture: true, applicationError: unapplied ? .failed("Synthetic EDID application failed") : nil)]
        if holdRead {
            holdRead = false; pendingSnapshot = snapshot
            return await withCheckedContinuation { pendingRead = $0 }
        }
        return snapshot
    }
    func apply(_ value: VendorSettingValue, to setting: String, deviceID device: String) throws {
        writes += 1
        if failed { throw PluginError.busy("Device is in use") }
        if !ignoreWrites, case .boolean(let enabled) = value { values[device] = enabled; unapplied = false }
    }
    func seedUnapplied(_ device: String) { values[device] = true; unapplied = true }
    func seedReadOnly(_ device: String) { values[device] = true; readOnly = true }
    func fail(_ enabled: Bool) { failed = enabled }
    func ignore(_ enabled: Bool) { ignoreWrites = enabled }
    func count() -> Int { writes }

}

@MainActor @objcMembers final class VendorSettingsStoreChecks: XCTestCase {
    func testInheritancePreservesOverridesAndFutureDevices() async throws {
        let fake = SettingsFake(), persistence = MemoryVendorSettings()
        let setting = "decklink:advertiseHDRToCameras"
        persistence.snapshot.inheritedByPlugin = ["decklink": [setting: .boolean(true)]]
        persistence.snapshot.desiredByDevice = ["decklink:override": [setting: .boolean(false)]]
        let store = VendorSettingsStore(plugins: ["decklink": fake], persistence: persistence)
        await store.restore(deviceID: "decklink:override", pluginID: "decklink")
        await store.restore(deviceID: "decklink:first", pluginID: "decklink")
        await store.restore(deviceID: "decklink:future", pluginID: "decklink")
        XCTAssertEqual(store.state(for: "decklink:override").settings.first?.value, .boolean(false))
        XCTAssertEqual(store.state(for: "decklink:future").settings.first?.value, .boolean(true))
        XCTAssertEqual(persistence.snapshot.desiredByDevice["decklink:first"]?[setting], .boolean(true))
        let count = await fake.count()
        XCTAssertEqual(count, 2)
        guard count == 2, persistence.snapshot.desiredByDevice["decklink:future"]?[setting] == .boolean(true) else {
            throw PluginError.failed("Inherited settings were not migrated per device")
        }
        await store.restore(deviceID: "decklink:first", pluginID: "decklink")
        let repeated = await fake.count()
        XCTAssertEqual(repeated, 2)
    }
    func testFailedOrUnverifiedApplyDoesNotPersistDesiredValue() async throws {
        let fake = SettingsFake(), persistence = MemoryVendorSettings()
        let store = VendorSettingsStore(plugins: ["decklink": fake], persistence: persistence)
        await store.restore(deviceID: "decklink:device", pluginID: "decklink")
        await fake.fail(true)
        await store.apply(.boolean(true), to: "decklink:advertiseHDRToCameras", deviceID: "decklink:device", pluginID: "decklink")
        XCTAssertNotNil(store.state(for: "decklink:device").message)
        XCTAssertNil(persistence.snapshot.desiredByDevice["decklink:device"]?["decklink:advertiseHDRToCameras"])
        await fake.fail(false); await fake.ignore(true)
        await store.apply(.boolean(true), to: "decklink:advertiseHDRToCameras", deviceID: "decklink:device", pluginID: "decklink")
        XCTAssertNotNil(store.state(for: "decklink:device").message)
        guard persistence.snapshot.desiredByDevice["decklink:device"]?["decklink:advertiseHDRToCameras"] == nil else {
            throw PluginError.failed("Unverified setting was persisted")
        }
    }
    func testLegacyPolicyRetainsOriginalAndVerifiedPerDeviceOverrides() throws {
        let suite = "VendorSettingsStoreChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ultracam.advertiseHDRToCameras")
        let persistence = VendorSettingsPreferences(defaults: defaults)
        var snapshot = try persistence.load()
        XCTAssertEqual(snapshot.inheritedByPlugin["decklink"]?["decklink:advertiseHDRToCameras"], .boolean(true))
        snapshot.desiredByDevice["decklink:override"] = ["decklink:advertiseHDRToCameras": .boolean(false)]
        try persistence.save(snapshot)
        defaults.set(false, forKey: "ultracam.advertiseHDRToCameras")
        let loaded = try persistence.load()
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.desiredByDevice["decklink:override"]?["decklink:advertiseHDRToCameras"], .boolean(false))
        XCTAssertNotNil(defaults.object(forKey: "ultracam.advertiseHDRToCameras"))
    }
    func testMatchingReadOnlyDefaultIsVerifiedWithoutApplying() async throws {
        let fake = SettingsFake(), persistence = MemoryVendorSettings()
        let setting = "decklink:advertiseHDRToCameras"
        persistence.snapshot.inheritedByPlugin = ["decklink": [setting: .boolean(true)]]
        await fake.seedReadOnly("decklink:readOnly")
        let store = VendorSettingsStore(plugins: ["decklink": fake], persistence: persistence)
        await store.restore(deviceID: "decklink:readOnly", pluginID: "decklink")
        guard persistence.snapshot.desiredByDevice["decklink:readOnly"]?[setting] == .boolean(true) else {
            throw PluginError.failed("A matching read-only setting was not verified")
        }
        let writes = await fake.count()
        XCTAssertEqual(writes, 0)
    }

    func testResetRetiresSuspendedRestoreBeforeHardwareApply() async throws {
        let fake = SettingsFake(), persistence = MemoryVendorSettings()
        persistence.snapshot.inheritedByPlugin = ["decklink": ["decklink:advertiseHDRToCameras": .boolean(true)]]
        let store = VendorSettingsStore(plugins: ["decklink": fake], persistence: persistence)
        await fake.holdNextRead()
        let task = Task { await store.restore(deviceID: "decklink:reset", pluginID: "decklink") }
        while !(await fake.readIsPending()) { await Task.yield() }
        store.reset()
        await fake.releaseRead(); await task.value
        let writes = await fake.count()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(persistence.writes, 0)
        XCTAssertTrue(store.state(for: "decklink:reset").settings.isEmpty)
        XCTAssertNil(store.state(for: "decklink:reset").message)
        guard writes == 0, store.state(for: "decklink:reset").settings.isEmpty, store.state(for: "decklink:reset").message == nil else {
            throw PluginError.failed("Reset did not retire suspended vendor settings restore")
        }
    }
    func testResetRetiresSuspendedApplyVerification() async throws {
        let fake = SettingsFake(), persistence = MemoryVendorSettings()
        let store = VendorSettingsStore(plugins: ["decklink": fake], persistence: persistence)
        await store.restore(deviceID: "decklink:reset", pluginID: "decklink")
        await fake.holdNextRead()
        let task = Task { await store.apply(.boolean(true), to: "decklink:advertiseHDRToCameras", deviceID: "decklink:reset", pluginID: "decklink") }
        while !(await fake.readIsPending()) { await Task.yield() }
        store.reset()
        await fake.releaseRead(); await task.value
        XCTAssertEqual(persistence.writes, 0)
        XCTAssertTrue(store.state(for: "decklink:reset").settings.isEmpty)
        XCTAssertNil(store.state(for: "decklink:reset").message)
        guard store.state(for: "decklink:reset").settings.isEmpty, store.state(for: "decklink:reset").message == nil else {
            throw PluginError.failed("Reset did not retire suspended vendor settings verification")
        }
    }

    func testDesiredValueWithApplicationErrorIsNotAcknowledged() async throws {
        let fake = SettingsFake(), persistence = MemoryVendorSettings()
        let setting = "decklink:advertiseHDRToCameras"
        persistence.snapshot.inheritedByPlugin = ["decklink": [setting: .boolean(true)]]
        await fake.seedUnapplied("decklink:failure"); await fake.ignore(true)
        let store = VendorSettingsStore(plugins: ["decklink": fake], persistence: persistence)
        await store.restore(deviceID: "decklink:failure", pluginID: "decklink")
        let writes = await fake.count()
        XCTAssertEqual(writes, 1)
        XCTAssertNotNil(store.state(for: "decklink:failure").message)
        XCTAssertNil(persistence.snapshot.desiredByDevice["decklink:failure"]?[setting])
        guard writes == 1, persistence.snapshot.desiredByDevice["decklink:failure"]?[setting] == nil else {
            throw PluginError.failed("Failed SDK application was acknowledged as a verified preference")
        }
        await fake.ignore(false)
        await store.apply(.boolean(true), to: setting, deviceID: "decklink:failure", pluginID: "decklink")
        XCTAssertEqual(persistence.snapshot.desiredByDevice["decklink:failure"]?[setting], .boolean(true))
        XCTAssertNil(store.state(for: "decklink:failure").message)
    }

}
#endif
