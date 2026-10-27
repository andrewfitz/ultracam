import CoreMedia
import Foundation
import XCTest

@MainActor @objcMembers final class SettingsChecks: XCTestCase {
  func testFractionalSourceReachesEverySelectableFrameRateCapWithoutDrift() {
    for target in FrameRateTarget.allCases {
      var gate = FrameRateGate()
      let configuration = PipelineConfiguration(reduceFrameRate: true, frameRateTarget: target)
      let count = (0..<600).filter {
        gate.shouldDeliver(CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32($0)), duration: configuration.duration)
      }.count
      let expected = 600 * VideoContract.fastDuration.seconds / configuration.duration.seconds
      XCTAssertEqual(Double(count), expected, accuracy: 1, target.title)
    }
  }

  func testSelectableTargetsAndSyncMigrateAndPersist() throws {
    let legacy = Data(#"{"id":"camera","name":"Camera","downscale":true,"convertTo420":true,"reduceFrameRate":true}"#.utf8)
    let migrated = try JSONDecoder().decode(FeedDescriptor.self, from: legacy)
    XCTAssertEqual(migrated.configuration.resizeTarget, .hd1080)
    XCTAssertEqual(migrated.configuration.colorTarget, .yuv4208)
    XCTAssertEqual(migrated.configuration.frameRateTarget, .fps2997)
    let feed = FeedDescriptor(resizeTarget: .hd720, colorTarget: .yuv4228, frameRateTarget: .fps24)
    let snapshot = AppSettingsSnapshot(feeds: [feed], syncCameras: true)
    let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(decoded, snapshot)
    XCTAssertTrue(FeedCoordinator(snapshot: decoded).snapshot.syncCameras)
    for target in FrameRateTarget.allCases {
      let configuration = PipelineConfiguration(reduceFrameRate: true, frameRateTarget: target)
      XCTAssertGreaterThanOrEqual(configuration.duration.seconds, VideoContract.fastDuration.seconds)
    }
    XCTAssertEqual(PipelineConfiguration(reduceFrameRate: true, frameRateTarget: .fps24).duration,
      CMTime(value: 1, timescale: 24))
  }

  func testDockVisibilityPreferencePersistsIndependentlyOfFeedSettings() throws {
    let suiteName = "org.ultracam.tests.dock.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppSettingsStore(defaults: defaults)
    XCTAssertFalse(store.hideFromDock)
    store.hideFromDock = true
    XCTAssertTrue(AppSettingsStore(defaults: defaults).hideFromDock)
    store.saveSnapshot(AppSettingsSnapshot())
    XCTAssertTrue(store.hideFromDock)
    store.hideFromDock = false
    XCTAssertFalse(AppSettingsStore(defaults: defaults).hideFromDock)
  }

  func testPreferencesRoundTripWithoutVideoOrRateState() throws {
    let suiteName = "org.ultracam.tests.settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let saved = AppSettingsSnapshot(feeds: [FeedDescriptor(selectedDevice: "synthetic-device", applyLUT: true,
      downscale: false, convertTo420: false, reduceFrameRate: true,
      gamut: "S-Gamut3 / S-Log3", pipelineEnabled: false, previewEnabled: false,
      lutBookmark: Data([1, 2, 3]), automaticFeed: true)])
    AppSettingsStore(defaults: defaults).saveSnapshot(saved)
    XCTAssertEqual(AppSettingsStore(defaults: defaults).loadSnapshot().feeds, saved.feeds)
    let text = String(data: try XCTUnwrap(defaults.data(forKey: AppSettingsStore.snapshotKey)), encoding: .utf8)!
    XCTAssertFalse(text.contains("inputFast"), "Source rate must be detected each run")
    XCTAssertFalse(text.contains("running"), "Transient running state must not be persisted")
    XCTAssertFalse(text.contains("rgba"), "LUT payload must not become a preference")
  }

  func testExistingPreferencesKeepLUTAndDefaultToManualFeed() throws {
    let original = AppSettings(selectedDevice: "saved-input", applyLUT: true,
      downscale: false, convertTo420: false, reduceFrameRate: true,
      pipelineEnabled: false, previewEnabled: false, lutBookmark: Data([7, 8, 9]))
    let data = try JSONEncoder().encode(original)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("automaticFeed"))
    let migrated = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertEqual(migrated, original)
    XCTAssertFalse(migrated.automaticFeed ?? false)
  }

  func testV1PreferencesMigrateToStablePrimaryFeedAndRetainLegacyRecord() throws {
    let suiteName = "org.ultracam.tests.settings.migration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let legacy = AppSettings(selectedDevice: "legacy-input", applyLUT: true,
      downscale: false, convertTo420: false, reduceFrameRate: true,
      gamut: "S-Gamut3 / S-Log3", pipelineEnabled: false, previewEnabled: false,
      lutBookmark: Data([4, 5, 6]), automaticFeed: true)
    let legacyData = try JSONEncoder().encode(legacy)
    defaults.set(legacyData, forKey: AppSettingsStore.key)

    let snapshot = AppSettingsStore(defaults: defaults).loadSnapshot()
    XCTAssertEqual(snapshot.version, AppSettingsSnapshot.currentVersion)
    XCTAssertEqual(snapshot.selectedFeedID, .primary)
    XCTAssertEqual(snapshot.feeds.count, 1)
    XCTAssertEqual(snapshot.feeds[0].selectedDevice, legacy.selectedDevice)
    XCTAssertEqual(snapshot.feeds[0].lutBookmark, legacy.lutBookmark)
    XCTAssertTrue(snapshot.feeds[0].automaticFeed)
    XCTAssertEqual(defaults.data(forKey: AppSettingsStore.key), legacyData,
      "Migration must retain v1 until a complete v2 snapshot is stored")
    XCTAssertNotNil(defaults.data(forKey: AppSettingsStore.snapshotKey))
  }

  func testV2SnapshotPreservesStableIDsOrderingAndGlobalSettings() throws {
    let suiteName = "org.ultracam.tests.settings.v2.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = FeedDescriptor(id: FeedID(rawValue: "feed-a"), name: "Wide", selectedDevice: "a")
    let second = FeedDescriptor(id: FeedID(rawValue: "feed-b"), name: "Tight", selectedDevice: "b", enabled: false)
    let snapshot = AppSettingsSnapshot(feeds: [first, second], selectedFeedID: second.id,
      outputMode: .program,
      switcher: SwitcherSettings(selectedFeedID: second.id, automatic: true,
        intervalSeconds: 8, strategy: .fixedInterval), virtualCameraRegistryVersion: 3)
    let store = AppSettingsStore(defaults: defaults)
    store.saveSnapshot(snapshot)
    let encoded = String(decoding: try XCTUnwrap(defaults.data(forKey: AppSettingsStore.snapshotKey)), as: UTF8.self)
    XCTAssertTrue(encoded.contains("\"id\":\"feed-a\""), "Feed IDs must remain stable string values on disk")
    XCTAssertFalse(encoded.contains("rawValue"), "Feed IDs must not depend on synthesized wrapper encoding")
    let loaded = store.loadSnapshot()
    XCTAssertEqual(loaded.feeds.map(\.id), [first.id, second.id])
    XCTAssertEqual(loaded.selectedFeedID, second.id)
    XCTAssertEqual(loaded.outputMode, .program)
    XCTAssertEqual(loaded.switcher, snapshot.switcher)
    XCTAssertEqual(loaded.virtualCameraRegistryVersion, 3)
    XCTAssertFalse(loaded.feeds[1].enabled)
  }

  func testNaturalTalkingHeadSwitcherSettingsRoundTrip() throws {
    let profile = NaturalTalkingHeadSettings(
      enabled: true, anchorFeedID: FeedID(rawValue: "wide"),
      emphasisFeedID: FeedID(rawValue: "tight"), mode: .lowLatency,
      maximumShotDuration: 18, forcedCutGracePeriod: 3)
    let switcher = SwitcherSettings(selectedFeedID: FeedID(rawValue: "wide"),
      automatic: true, strategy: .naturalTalkingHead, naturalTalkingHead: profile)
    let data = try JSONEncoder().encode(switcher)
    let loaded = try JSONDecoder().decode(SwitcherSettings.self, from: data)
    XCTAssertEqual(loaded, switcher)
    XCTAssertEqual(loaded.naturalTalkingHead.maximumShotDuration, 18)
  }

  func testPartialNaturalTalkingHeadProfileUsesSafeDefaults() throws {
    let data = Data(#"{"naturalTalkingHead":{"enabled":true}}"#.utf8)
    let loaded = try JSONDecoder().decode(SwitcherSettings.self, from: data)
    XCTAssertTrue(loaded.naturalTalkingHead.enabled)
    XCTAssertEqual(loaded.naturalTalkingHead.minimumShotDuration, 10)
    XCTAssertEqual(loaded.naturalTalkingHead.maximumShotDuration, 30)
    XCTAssertEqual(loaded.naturalTalkingHead.mode, .transcriptAssisted)
  }

  func testMissingGamutUsesCustomLUTFallback() throws {
    let feed = try JSONDecoder().decode(FeedDescriptor.self, from: Data(#"{"id":"feed-a","name":"A"}"#.utf8))
    XCTAssertEqual(feed.gamut, "Unspecified / custom LUT")
  }

  func testUnknownEnumValuesPreserveSnapshotAndRepairDanglingReferences() throws {
    let json = #"{"version":2,"feeds":[{"id":"feed-a","name":"A","resizeTarget":"future","gamut":"custom"}],"selectedFeedID":"removed","outputMode":"future","switcher":{"selectedFeedID":"removed","strategy":"future","naturalTalkingHead":{"anchorFeedID":"removed","emphasisFeedID":"removed","mode":"future"}}}"#
    let snapshot = try JSONDecoder().decode(AppSettingsSnapshot.self, from: Data(json.utf8))
    let repaired = try XCTUnwrap(snapshot.validated())
    XCTAssertEqual(repaired.feeds.count, 1)
    XCTAssertEqual(repaired.feeds[0].gamut, "custom")
    XCTAssertEqual(repaired.selectedFeedID, FeedID(rawValue: "feed-a"))
    XCTAssertNil(repaired.switcher.selectedFeedID)
    XCTAssertNil(repaired.switcher.naturalTalkingHead.anchorFeedID)
    XCTAssertNil(repaired.switcher.naturalTalkingHead.emphasisFeedID)
  }

  func testOlderShortMinimumShotDurationIsRaisedToSafeFloor() throws {
    let data = Data(#"{"naturalTalkingHead":{"minimumShotDuration":5}}"#.utf8)
    let loaded = try JSONDecoder().decode(SwitcherSettings.self, from: data)
    XCTAssertEqual(loaded.naturalTalkingHead.minimumShotDuration, 10)
  }

  func testInvalidV2SnapshotFallsBackToV1Migration() throws {
    let suiteName = "org.ultracam.tests.settings.v2-fallback.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let legacy = AppSettings(selectedDevice: "fallback-input", lutBookmark: Data([9]))
    defaults.set(try JSONEncoder().encode(legacy), forKey: AppSettingsStore.key)
    let invalid = AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: FeedID(rawValue: "duplicate")),
      FeedDescriptor(id: FeedID(rawValue: "duplicate"))
    ])
    defaults.set(try JSONEncoder().encode(invalid), forKey: AppSettingsStore.snapshotKey)

    let migrated = AppSettingsStore(defaults: defaults).loadSnapshot()
    XCTAssertEqual(migrated.feeds.count, 1)
    XCTAssertEqual(migrated.feeds[0].selectedDevice, legacy.selectedDevice)
    XCTAssertEqual(migrated.feeds[0].lutBookmark, legacy.lutBookmark)
  }

  func testInvalidSnapshotSaveDoesNotResetExistingConfiguration() throws {
    let suiteName = "org.ultracam.tests.settings.v2-save-validation.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let original = AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: FeedID(rawValue: "wide"), name: "Wide", selectedDevice: "decklink-1")
    ], selectedFeedID: FeedID(rawValue: "wide"), outputMode: .program)
    let store = AppSettingsStore(defaults: defaults)
    store.saveSnapshot(original)
    let before = try XCTUnwrap(defaults.data(forKey: AppSettingsStore.snapshotKey))

    let invalid = AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: FeedID(rawValue: "duplicate")),
      FeedDescriptor(id: FeedID(rawValue: "duplicate"))
    ])
    store.saveSnapshot(invalid)

    XCTAssertEqual(defaults.data(forKey: AppSettingsStore.snapshotKey), before)
    XCTAssertEqual(store.loadSnapshot(), original)
  }

  func testCorruptOrUnsupportedPreferencesUseSafeDefaults() throws {
    let suiteName = "org.ultracam.tests.settings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("invalid JSON".utf8), forKey: AppSettingsStore.key)
    XCTAssertEqual(AppSettingsStore(defaults: defaults).loadSnapshot(), AppSettingsSnapshot())
    var unsupported = AppSettings()
    unsupported.version = 9
    defaults.set(try JSONEncoder().encode(unsupported), forKey: AppSettingsStore.key)
    XCTAssertEqual(AppSettingsStore(defaults: defaults).loadSnapshot(), AppSettingsSnapshot())
  }

  func testBookmarkRestoreAndMissingFileRecovery() throws {
    let directory = URL(fileURLWithPath: "/Volumes/8TB/cinesomatic-director-work/tmp")
      .appendingPathComponent("settings-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("identity.cube")
    try cubeText().write(to: file, atomically: true, encoding: .utf8)
    let symbolicLink = directory.appendingPathComponent("linked-look.cube")
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: file)
    let completed = expectation(description: "Bookmark restored off the main actor")
    Task {
      // Tests use ordinary bookmarks because this executable has no sandbox
      // identity. Production always uses the app-scoped, read-only variant.
      let loader = LUTFileLoader(scopedBookmarks: false)
      do {
        let selected = try await loader.load(url: file)
        let restored = try await loader.restore(bookmark: selected.bookmark)
        XCTAssertEqual(selected.fileName, "identity.cube")
        XCTAssertEqual(restored.fileName, "identity.cube")
        XCTAssertFalse(restored.fileName.contains("/"), "Display name must not expose the source path")
        let linked = try await loader.load(url: symbolicLink)
        XCTAssertEqual(linked.fileName, "linked-look.cube")
        XCTAssertEqual(linked.cube.rgba, selected.cube.rgba)
        XCTAssertEqual(restored.cube.dimension, 2)
        XCTAssertEqual(restored.cube.rgba, selected.cube.rgba)
        try FileManager.default.removeItem(at: file)
        do {
          _ = try await loader.restore(bookmark: selected.bookmark)
          XCTFail("A missing LUT must not be reported as loaded")
        } catch { }
        // The saved bookmark remains usable if the file returns.
        try cubeText().write(to: file, atomically: true, encoding: .utf8)
        let recovered = try await loader.restore(bookmark: selected.bookmark)
        XCTAssertEqual(recovered.cube.rgba, selected.cube.rgba)
        do {
          _ = try await loader.restore(bookmark: Data([0, 1, 2]))
          XCTFail("Invalid bookmark must be rejected")
        } catch { }
      } catch { XCTFail(error.localizedDescription) }
      completed.fulfill()
    }
    wait(for: [completed], timeout: 10)
  }

  func testInvalidSelectionDoesNotReplaceSavedBookmark() throws {
    let directory = URL(fileURLWithPath: "/Volumes/8TB/cinesomatic-director-work/tmp")
      .appendingPathComponent("settings-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let good = directory.appendingPathComponent("good.cube")
    let bad = directory.appendingPathComponent("bad.cube")
    try cubeText().write(to: good, atomically: true, encoding: .utf8)
    try "LUT_3D_SIZE 2\n0 0 0".write(to: bad, atomically: true, encoding: .utf8)
    let completed = expectation(description: "Invalid replacement is rejected")
    Task {
      let loader = LUTFileLoader(scopedBookmarks: false)
      do {
        let original = try await loader.load(url: good)
        XCTAssertEqual(original.fileName, "good.cube")
        do {
          _ = try await loader.load(url: bad)
          XCTFail("Invalid cube cannot replace a valid choice")
        } catch { }
        let restored = try await loader.restore(bookmark: original.bookmark)
        XCTAssertEqual(restored.fileName, "good.cube")
        XCTAssertEqual(restored.cube.rgba, original.cube.rgba)
      } catch { XCTFail(error.localizedDescription) }
      completed.fulfill()
    }
    wait(for: [completed], timeout: 10)
  }

  func testLUTReadRejectsOversizedNonTextAndNonFileInputs() throws {
    let directory = URL(fileURLWithPath: "/Volumes/8TB/cinesomatic-director-work/tmp")
      .appendingPathComponent("settings-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oversized = directory.appendingPathComponent("oversized.cube")
    XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: 32 * 1024 * 1024 + 1)
    try handle.close()
    let invalidText = directory.appendingPathComponent("non-text.cube")
    try Data([0xff, 0xfe, 0x80]).write(to: invalidText)
    let completed = expectation(description: "Unsafe file inputs rejected off main actor")
    Task {
      let loader = LUTFileLoader(scopedBookmarks: false)
      for file in [oversized, invalidText, directory] {
        do {
          _ = try await loader.load(url: file)
          XCTFail("Unsafe input must not become a loaded LUT")
        } catch { }
      }
      completed.fulfill()
    }
    wait(for: [completed], timeout: 10)
  }
}
