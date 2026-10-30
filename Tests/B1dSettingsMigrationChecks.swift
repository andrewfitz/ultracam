#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

/// B1d regression contract: unknown append-only enum values must not discard
/// the feed, LUT bookmark, device identity, or unrelated settings. Legacy
/// gamut display text is migrated to a stable source profile ID; unknown IDs
/// remain opaque and survive a round trip.
@MainActor @objcMembers final class B1dSettingsMigrationChecks: XCTestCase {
    func testExplicitNoneUsesRealDescriptorCodableAndLegacyDefault() throws {
        var feed = FeedDescriptor(selectedDevice: "")
        feed.inputClearedByChoice = true
        let restored = try JSONDecoder().decode(FeedDescriptor.self, from: JSONEncoder().encode(feed))
        XCTAssertTrue(restored.inputClearedByChoice)
        XCTAssertTrue(restored.selectedDevice.isEmpty)
        let legacy = try JSONDecoder().decode(FeedDescriptor.self, from: Data(#"{"selectedDevice":""}"#.utf8))
        XCTAssertFalse(legacy.inputClearedByChoice, "Legacy snapshots keep their prior autoassignment policy")
        XCTAssertFalse(FeedDescriptor().inputClearedByChoice)
    }

    func testOfflineModelKeepsEveryExplicitNoneAfterRelaunchAndDiscovery() throws {
        for count in [1, 2] {
            let suite = "B1dNoneIntent." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let feeds = (0..<count).map { index in
                FeedDescriptor(id: FeedID(rawValue: "intent-\(index)"), name: "Camera \(index + 1)",
                    selectedDevice: "fixture:input-\(index)")
            }
            AppSettingsStore(defaults: defaults).saveSnapshot(AppSettingsSnapshot(feeds: feeds))
            let inputs = feeds.map { InputDevice(id: $0.selectedDevice, name: "Fixture") }
            var model: AppModel? = intentModel(defaults: defaults, inputs: inputs)
            for feed in feeds { model?.updateCamera(feed.id) { $0.selectedDevice = "" } }
            model = nil
            let relaunched = intentModel(defaults: defaults, inputs: inputs)
            XCTAssertTrue(relaunched.feedDescriptors.allSatisfy { $0.selectedDevice.isEmpty && $0.inputClearedByChoice })
            relaunched.refresh()
            XCTAssertTrue(relaunched.feedDescriptors.allSatisfy { $0.selectedDevice.isEmpty })
        }
    }

    func testFreshOfflineModelStillAssignsAvailableInput() throws {
        let suite = "B1dFreshInput." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = intentModel(defaults: defaults, inputs: [InputDevice(id: "fixture:available", name: "Fixture")])
        XCTAssertEqual(model.feedDescriptors.first?.selectedDevice, "fixture:available")
        XCTAssertEqual(model.feedDescriptors.first?.inputClearedByChoice, false)
    }

    func testMonitorPickerUpdatesAuthoritativeSourceThroughActualModelCallback() throws {
        for initial in ["unspecified", "sony-slog3-sgamut3cine"] {
            let suite = "B1dLogPicker." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let feed = FeedDescriptor(sourceProfileID: initial)
            AppSettingsStore(defaults: defaults).saveSnapshot(AppSettingsSnapshot(feeds: [feed]))
            let model = intentModel(defaults: defaults, inputs: [])
            let target = MonitorTargetID(feed.id.rawValue)
            for picked: String? in ["panasonic-vlog-vgamut", "arri-logc3-ei800", nil] {
                var preferences = model.monitorCoordinator.preferences(for: target)
                preferences.signal.range = .full
                preferences.signal.transport = .fullRescaledToLegal
                model.monitorCoordinator.setPreferences(preferences.declaringCameraLog(picked), for: target)
                let live = try XCTUnwrap(model.descriptor(for: feed.id))
                let restored = try XCTUnwrap(AppSettingsStore(defaults: defaults).loadSnapshot().feeds.first)
                for value in [live, restored] {
                    XCTAssertEqual(value.sourceProfileID, picked ?? "unspecified")
                    XCTAssertEqual(value.monitor.signal.logProfileID, picked)
                    XCTAssertNil(value.monitor.signal.sourceProfileID)
                    XCTAssertEqual(value.monitor.signal.range, .full)
                    XCTAssertEqual(value.monitor.signal.transport, .fullRescaledToLegal)
                }
            }
        }
    }

    func testSyncedMonitorPickerKeepsCameraDeclarationsIsolated() throws {
        let suite = "B1dSyncedLogPicker." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = FeedDescriptor(id: FeedID(rawValue: "alpha"))
        let beta = FeedDescriptor(id: FeedID(rawValue: "beta"))
        var snapshot = AppSettingsSnapshot(feeds: [alpha, beta])
        snapshot.syncCameras = true
        AppSettingsStore(defaults: defaults).saveSnapshot(snapshot)
        let model = intentModel(defaults: defaults, inputs: [])
        let alphaTarget = MonitorTargetID(alpha.id.rawValue)
        let betaTarget = MonitorTargetID(beta.id.rawValue)
        var tools = model.monitorCoordinator.preferences(for: alphaTarget)
        tools = tools.declaringCameraLog("sony-slog3-sgamut3cine")
        tools.toolsEnabled = true
        tools.state.falseColor.mode = .sonySLog3
        model.monitorCoordinator.setPreferences(tools, for: alphaTarget)
        let saved = AppSettingsStore(defaults: defaults).loadSnapshot()
        for descriptors in [model.feedDescriptors, saved.feeds] {
            let declared = try XCTUnwrap(descriptors.first { $0.id == alpha.id })
            let undeclared = try XCTUnwrap(descriptors.first { $0.id == beta.id })
            XCTAssertEqual(declared.sourceProfileID, "sony-slog3-sgamut3cine")
            XCTAssertEqual(declared.configuration.sourceColorimetryOverride?.transfer, .sLog3)
            XCTAssertTrue(declared.monitor.falseColorDeclared)
            XCTAssertEqual(undeclared.sourceProfileID, "unspecified")
            XCTAssertNil(undeclared.configuration.sourceColorimetryOverride)
            XCTAssertNil(undeclared.monitor.signal.logProfileID)
            XCTAssertEqual(undeclared.monitor.state.falseColor.mode, .sonySLog3)
            XCTAssertFalse(undeclared.monitor.falseColorDeclared)
        }
        var peerTools = model.monitorCoordinator.preferences(for: betaTarget)
        peerTools.toolsEnabled = false
        model.monitorCoordinator.setPreferences(peerTools, for: betaTarget)
        XCTAssertTrue(model.monitorCoordinator.preferences(for: alphaTarget).falseColorDeclared)
        XCTAssertEqual(model.descriptor(for: alpha.id)?.sourceProfileID, "sony-slog3-sgamut3cine")
    }

    private func intentModel(defaults: UserDefaults, inputs: [InputDevice]) -> AppModel {
        var hardware = AppHardware.offline
        hardware.devices = { inputs }
        let installer = ExtensionInstaller(services: .init(
            preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
            makeRequest: { _ in fatalError("No installer requests in settings tests") },
            submit: { _ in XCTFail("No installer submissions in settings tests") },
            queryProperties: { $0([]) }))
        return AppModel(settingsStore: AppSettingsStore(defaults: defaults),
            registryStore: VirtualCameraRegistryStore(defaults: defaults),
            registryPublisher: SettingsIntentRegistryPublisher(),
            recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
            hardware: hardware)
    }

    func testDisplaySourceProfilesReachMonitorOnInitDecodeAndChange() throws {
        for id in ["rec709-video", "rec2020-hlg-video", "rec2020-pq-video"] {
            var feed = FeedDescriptor(id: .primary, name: "Camera", sourceProfileID: id)
            XCTAssertEqual(feed.monitor.signal.sourceProfileID, id)
            XCTAssertNil(feed.monitor.signal.logProfileID)
            let decoded = try JSONDecoder().decode(FeedDescriptor.self, from: JSONEncoder().encode(feed))
            XCTAssertEqual(decoded.monitor.signal.sourceProfileID, id)
            feed.setSourceProfile("sony-slog3-sgamut3cine")
            XCTAssertEqual(feed.monitor.signal.logProfileID, "sony-slog3-sgamut3cine")
            XCTAssertNil(feed.monitor.signal.sourceProfileID)
            feed.setSourceProfile(id)
            XCTAssertEqual(feed.monitor.signal.sourceProfileID, id)
            feed.setSourceProfile("unspecified")
            XCTAssertNil(feed.monitor.signal.sourceProfileID)
            XCTAssertNil(feed.monitor.signal.logProfileID)
        }
    }
    func testUnknownLegacyTargetsPreserveFeedAndBookmark() throws {
        let suite = "B1dSettingsMigrationChecks." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmark = Data([7, 8, 9])
        let legacy: [String: Any] = [
            "version": 1, "selectedDevice": "vendor:opaque:input",
            "applyLUT": true, "lutBookmark": bookmark.base64EncodedString(),
            "resizeTarget": "future-size", "colorTarget": "future-packing",
            "frameRateTarget": "future-rate", "gamut": "S-Gamut3.Cine / S-Log3",
            "pipelineEnabled": false, "previewEnabled": true
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: AppSettingsStore.key)
        let snapshot = AppSettingsStore(defaults: defaults).loadSnapshot()
        let feed = try XCTUnwrap(snapshot.feeds.first)
        XCTAssertEqual(feed.selectedDevice, "vendor:opaque:input")
        XCTAssertEqual(feed.lutBookmark, bookmark)
        XCTAssertFalse(feed.pipelineEnabled)
        XCTAssertEqual(feed.resizeTarget, .hd1080)
        XCTAssertEqual(feed.colorTarget, .yuv4208)
        XCTAssertEqual(feed.frameRateTarget, .fps2997)
        XCTAssertEqual(feed.sourceProfileID, "sony-slog3-sgamut3cine")
    }

    func testUnknownStableProfileIDSurvivesRoundTripAndLegacyKeyRemains() throws {
        let suite = "B1dSettingsMigrationChecks." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = AppSettingsSnapshot(feeds: [
            FeedDescriptor(id: .primary, name: "Camera 1", selectedDevice: "vendor:device", sourceProfileID: "future-profile-v9", resizeTarget: .hd1080, colorTarget: .yuv4208, frameRateTarget: .fps2997)
        ], selectedFeedID: .primary)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: AppSettingsStore.snapshotKey)
        let loaded = AppSettingsStore(defaults: defaults).loadSnapshot()
        XCTAssertEqual(loaded.feeds.first?.sourceProfileID, "future-profile-v9")
        XCTAssertEqual(try JSONDecoder().decode(AppSettingsSnapshot.self, from: try XCTUnwrap(defaults.data(forKey: AppSettingsStore.snapshotKey))), snapshot)
    }

    func testMissingTargetsMaterializeOnlyDuringMigration() throws {
        let suite = "B1dSettingsMigrationChecks." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = ["version": 1, "selectedDevice": "vendor:device", "gamut": "Unspecified / custom LUT"]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: AppSettingsStore.key)
        let loaded = AppSettingsStore(defaults: defaults).loadSnapshot()
        let feed = try XCTUnwrap(loaded.feeds.first)
        XCTAssertEqual(feed.resizeTarget, .hd1080)
        XCTAssertEqual(feed.colorTarget, .yuv4208)
        XCTAssertEqual(feed.frameRateTarget, .fps2997)
        XCTAssertEqual(feed.sourceProfileID, "unspecified")
    }
    func testExistingV2MissingTargetsAreWrittenExplicitlyOnce() throws {
        let suite = "B1dSettingsMigrationChecks." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = AppSettingsSnapshot(feeds: [.init(selectedDevice: "vendor:opaque", gamut: "S-Gamut3 / S-Log3", resizeTarget: nil, colorTarget: nil, frameRateTarget: nil)])
        defaults.set(try JSONEncoder().encode(original), forKey: AppSettingsStore.snapshotKey)
        let loaded = AppSettingsStore(defaults: defaults).loadSnapshot()
        XCTAssertEqual(loaded.feeds[0].resizeTarget, .hd1080)
        XCTAssertEqual(loaded.feeds[0].colorTarget, .yuv4208)
        XCTAssertEqual(loaded.feeds[0].frameRateTarget, .fps2997)
        let bytes = try XCTUnwrap(defaults.data(forKey: AppSettingsStore.snapshotKey))
        let stored = try JSONDecoder().decode(AppSettingsSnapshot.self, from: bytes)
        guard stored.feeds[0].resizeTarget == .hd1080 else { throw MigrationFailure.implicitDefault }
        XCTAssertEqual(AppSettingsStore(defaults: defaults).loadSnapshot(), loaded)
        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.snapshotKey), bytes)
    }
    func testSourceSizeAndExplicitRegionalRateRoundTrip() throws {
        let suite = "B1dSettingsMigrationChecks." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let feed = FeedDescriptor(selectedDevice: "vendor:input", resizeTarget: .source,
            colorTarget: .yuv42210, frameRateTarget: .fps25)
        let snapshot = AppSettingsSnapshot(feeds: [feed])
        AppSettingsStore(defaults: defaults).saveSnapshot(snapshot)
        let loaded = AppSettingsStore(defaults: defaults).loadSnapshot()
        XCTAssertEqual(loaded.feeds[0].resizeTarget, .source)
        XCTAssertEqual(loaded.feeds[0].frameRateTarget, .fps25)
        XCTAssertEqual(loaded.feeds[0].colorTarget, .yuv42210)
        XCTAssertEqual(loaded.feeds[0].selectedDevice, "vendor:input")
    }
    func testAspectModePersistsAndUnknownModeFallsBackWithoutLosingInput() throws {
        let feed = FeedDescriptor(selectedDevice: "vendor:opaque", scalingMode: .crop)
        let data = try JSONEncoder().encode(feed)
        XCTAssertEqual(try JSONDecoder().decode(FeedDescriptor.self, from: data).scalingMode, .crop)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["scalingMode"] = "future-aspect"
        let decoded = try JSONDecoder().decode(FeedDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.scalingMode, .fit)
        XCTAssertEqual(decoded.selectedDevice, "vendor:opaque")
    }
    private enum MigrationFailure: Error { case implicitDefault }

}
@MainActor private final class SettingsIntentRegistryPublisher: AppVirtualCameraRegistryPublishing {
    func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
