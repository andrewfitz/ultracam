#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import Foundation
import XCTest

/// Rename, add and remove with other cameras live: each operation waits only on what it
/// touches, on a real model with fake capture. Reset alone still needs the whole app idle.
@MainActor @objcMembers final class LiveTopologyChecks: XCTestCase {
  private var fixture: AppHardwareSyntheticFixture!
  private var defaults: UserDefaults!

  private func appModel(_ snapshot: AppSettingsSnapshot? = nil, cameras: Int = 2) throws -> AppModel {
    let devices = (1...max(cameras, 1)).map { "fake:\($0)" }
    let fixture = try AppHardwareSyntheticFixture(deviceIDs: devices)
    self.fixture = fixture
    fixture.connect()
    let suite = "org.ultracam.tests.topology.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    self.defaults = defaults
    let store = AppSettingsStore(defaults: defaults)
    if let snapshot { store.saveSnapshot(snapshot) }
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    let model = AppModel(settingsStore: store, registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: TopologyRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      hardware: fixture.hardware)
    model.refresh()
    while model.feedDescriptors.count < cameras { _ = model.addFeed() }
    for (descriptor, device) in zip(model.feedDescriptors, devices) {
      model.updateCamera(descriptor.id, shareProcessing: false) { $0.selectedDevice = device }
    }
    return model
  }

  private func spin(_ what: String, _ done: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while !done() {
      guard Date() < deadline else { XCTFail(what); return }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
  }

  private var index: Int32 = 0
  private func emitUntil(_ what: String, _ done: () -> Bool) throws {
    let pattern = try fixture.makePattern()
    let deadline = Date(timeIntervalSinceNow: 10)
    while !done() {
      guard Date() < deadline else { XCTFail(what); return }
      try fixture.emit(pattern, index: index)
      index += 1
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.016))
    }
  }

  private func status(_ model: AppModel, _ id: FeedID) -> RecordingStatus? {
    model.recordingModel.feeds.first { $0.id == id }?.status
  }

  func testRenameAddAndRemovalOfAStoppedCameraWhileAnotherRecords() throws {
    let model = try appModel()
    defer { fixture.stop() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("topology-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    model.recordingModel.outputFolder = folder
    let rolling = model.feedDescriptors[0].id, idle = model.feedDescriptors[1].id
    model.startCamera(rolling)
    try emitUntil("A picture") { model.cameraUpdate(rolling)?.sourceFormat != nil }
    model.recordingModel.record(feedID: rolling)
    try emitUntil("Rolling") { status(model, rolling) == .recording }

    XCTAssertTrue(model.canAddCamera)
    XCTAssertTrue(model.canRemoveCamera(idle))
    XCTAssertFalse(model.canRemoveCamera(rolling), "Its own run and take have to end first")
    XCTAssertFalse(model.removeFeed(rolling))
    XCTAssertFalse(model.canResetSettings, "Reset alone needs the whole app idle")

    XCTAssertTrue(model.renameFeed(rolling, name: "Wide"))
    XCTAssertEqual(model.descriptor(for: rolling)?.name, "Wide")
    XCTAssertEqual(status(model, rolling), .recording)
    let added = try XCTUnwrap(model.addFeed())
    XCTAssertEqual(model.selectedFeedID, added)
    XCTAssertTrue(model.isCameraRunning(rolling))
    XCTAssertEqual(status(model, rolling), .recording)
    XCTAssertTrue(model.removeFeed(added))
    XCTAssertTrue(model.removeFeed(idle))
    XCTAssertEqual(model.feedDescriptors.map(\.id), [rolling])
    XCTAssertEqual(status(model, rolling), .recording, "The take rolled through all of it")
    try emitUntil("Still taking frames") { (model.liveCameraUpdate(rolling)?.frames ?? 0) > 0 }
    model.recordingModel.stop(feedID: rolling)
    try emitUntil("The take closes") { status(model, rolling) == .idle }
    model.stopCamera(rolling)
    spin("It stopped") { model.canResetSettings }
    XCTAssertFalse(model.canRemoveCamera(rolling), "The last camera stays")
  }

  func testThirtySecondCameraIsRefused() throws {
    let model = try appModel()
    defer { fixture.stop() }
    while model.feedDescriptors.count < FeedLifecycleDemandPolicy.maximumCameras {
      XCTAssertNotNil(model.addFeed())
    }
    XCTAssertEqual(model.feedDescriptors.count, 31, "With Program, the extension's 32 devices")
    XCTAssertFalse(model.canAddCamera)
    XCTAssertNil(model.addFeed())
    XCTAssertEqual(model.feedDescriptors.count, 31)
    XCTAssertTrue(model.appProblems.isEmpty)
  }

  /// `synchronize` refuses a snapshot past the limit, and its publisher can't report that,
  /// so the whole update would vanish. Saving says so instead.
  func testASnapshotPastTheDeviceLimitFailsLoudly() throws {
    let feeds = (0..<33).map { FeedDescriptor(id: FeedID(rawValue: "camera-\($0)"), name: "Camera \($0)") }
    let model = try appModel(AppSettingsSnapshot(feeds: feeds, selectedFeedID: feeds[0].id), cameras: 1)
    defer { fixture.stop() }
    XCTAssertTrue(model.appProblems.contains { $0.id == "registry" && $0.text.contains("32") })
  }

  /// Reset clears the input names it has seen, and a device listed before the quit doesn't
  /// write them back.
  func testResetLeavesNoInputNamesBehind() throws {
    let model = try appModel()
    defer { fixture.stop() }
    XCTAssertNotNil(defaults.dictionary(forKey: HardwareInventory.lastKnownNamesKey), "Seen and saved")
    XCTAssertTrue(model.resetAllSettings())
    XCTAssertNil(defaults.dictionary(forKey: HardwareInventory.lastKnownNamesKey))
    model.refresh()
    XCTAssertNil(defaults.dictionary(forKey: HardwareInventory.lastKnownNamesKey), "Nothing is saved after Reset")
  }

  /// Settings from a build that kept Program's color per camera: Program declares one color
  /// whichever camera is on air, the first camera's, and says so on disk too.
  func testProgramColorIsOneSettingFromLaunch() throws {
    var first = FeedDescriptor(id: FeedID(rawValue: "camera-a"), name: "Camera 1")
    first.programColorSpaceID = "rec2020-pq-video"
    var second = FeedDescriptor(id: FeedID(rawValue: "camera-b"), name: "Camera 2")
    second.programColorSpaceID = "rec709-video"
    let suite = "org.ultracam.tests.topology.color.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let store = AppSettingsStore(defaults: defaults)
    store.saveSnapshot(AppSettingsSnapshot(feeds: [first, second], selectedFeedID: first.id))
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    let model = AppModel(settingsStore: store, registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: TopologyRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer, hardware: .offline)
    XCTAssertEqual(model.feedDescriptors.map(\.programColorSpaceID), ["rec2020-pq-video", "rec2020-pq-video"])
    XCTAssertEqual(model.effectiveConfiguration(for: second.id).programColorimetry,
      model.effectiveConfiguration(for: first.id).programColorimetry, "A cut to Camera 2 declares the same color")
    XCTAssertEqual(AppSettingsStore(defaults: defaults).loadSnapshot().feeds.map(\.programColorSpaceID),
      ["rec2020-pq-video", "rec2020-pq-video"])
  }

  /// The director's clock belongs to its camera, not to whatever was clicked last.
  func testDirectorClockFollowsTheAnchorNotTheSelection() throws {
    let model = try appModel(cameras: 3)
    defer { fixture.stop() }
    let ids = model.feedDescriptors.map(\.id)
    model.naturalAnchorFeedID = ids[1]
    model.naturalEmphasisFeedID = ids[2]
    model.startAllCameras()
    XCTAssertEqual(model.directorClockFeedIDForTesting, ids[1])
    for id in ids {
      XCTAssertTrue(model.selectFeed(id))
      XCTAssertEqual(model.directorClockFeedIDForTesting, ids[1], "A click moves nothing")
    }
    model.stopCamera(ids[1])
    XCTAssertEqual(model.directorClockFeedIDForTesting, ids[2], "The anchor stopped: the emphasis camera")
    let added = try XCTUnwrap(model.addFeed())
    XCTAssertEqual(model.selectedFeedID, added)
    XCTAssertEqual(model.directorClockFeedIDForTesting, ids[2], "Adding a stopped camera doesn't starve it")
    model.stopCamera(ids[2])
    XCTAssertEqual(model.directorClockFeedIDForTesting, ids[0], "Neither runs: the one that does")
    model.stopAllCameras()
    XCTAssertNil(model.directorClockFeedIDForTesting)
  }
}

private final class TopologyRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
