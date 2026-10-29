#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

/// B1d regression contract: unknown append-only enum values must not discard
/// the feed, LUT bookmark, device identity, or unrelated settings. Legacy
/// gamut display text is migrated to a stable source profile ID; unknown IDs
/// remain opaque and survive a round trip.
@MainActor @objcMembers final class B1dSettingsMigrationChecks: XCTestCase {
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
#endif
