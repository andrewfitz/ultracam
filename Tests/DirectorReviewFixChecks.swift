#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import Foundation
import XCTest

/// Regressions from the November 14 review: a real model, the real switcher and fake capture.
@MainActor @objcMembers final class DirectorReviewFixChecks: XCTestCase {
  private var fixture: AppHardwareSyntheticFixture!
  private var model: AppModel!
  private var ids: [FeedID] = []
  private var index: Int32 = 0

  private func prepare() throws {
    let devices = ["fake:1", "fake:2"]
    let fixture = try AppHardwareSyntheticFixture(deviceIDs: devices)
    self.fixture = fixture
    fixture.connect()
    let suite = "org.ultracam.tests.director-review.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: DirectorReviewRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      hardware: fixture.hardware)
    model.refresh()
    while model.feedDescriptors.count < devices.count { _ = model.addFeed() }
    ids = model.feedDescriptors.map(\.id)
    for (id, device) in zip(ids, devices) {
      model.updateCamera(id, shareProcessing: false) { $0.selectedDevice = device }
    }
    _ = model.selectFeed(ids[0])
  }

  private func finish() {
    model.stopAllCameras()
    fixture.stop()
    model = nil
    fixture = nil
  }

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

  /// The Inspector's camera log reaches the monitor's copy, so a later tool edit keeps it.
  func testACameraLogSetOutsideTheMonitorSurvivesTheNextToolEdit() throws {
    try prepare()
    defer { finish() }
    let target = MonitorTargetID(ids[0].rawValue)
    model.updateCamera(ids[0]) { $0.setSourceProfile("sony-slog3-sgamut3cine") }
    let declared = try XCTUnwrap(model.feedDescriptors.first { $0.id == ids[0] }?.monitor.signal.logProfileID)
    XCTAssertEqual(model.monitorCoordinator.preferences(for: target).signal.logProfileID, declared)
    var edited = model.monitorCoordinator.preferences(for: target)
    edited.toolsEnabled.toggle()
    model.monitorCoordinator.setPreferences(edited, for: target)
    XCTAssertEqual(model.feedDescriptors.first { $0.id == ids[0] }?.monitor.signal.logProfileID, declared)
  }

  /// Demand rose with no camera producing, so there was nothing to move to. The camera that
  /// gets its picture afterwards takes Program from the one that isn't running.
  func testProgramMovesOffAStoppedCameraWhenAnotherGetsItsPictureLater() throws {
    try prepare()
    defer { finish() }
    model.setProgramDemandForTesting(requested: true)
    XCTAssertEqual(model.switcherSelectedFeedID, ids[0], "Nothing has a picture yet")
    model.startCamera(ids[1])
    try emitUntil("Program moves to the camera that now has a picture") { model.switcherSelectedFeedID == ids[1] }
    XCTAssertEqual(model.programMoved?.cause, .notReady)
  }

  /// A director recreated under a rolling take writes a new timeline file; the take binds to it.
  func testARollingTakeFollowsARecreatedDirectorsTimeline() throws {
    try prepare()
    defer { finish() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("director-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    model.recordingModel.outputFolder = folder
    model.naturalTalkingHeadEnabled = true
    model.startAllCameras()
    try emitUntil("Every camera produces, and says it's live") {
      ids.allSatisfy { model.isProgramSourceProducingForTesting($0) && model.cameraUpdate($0)?.signal == .live }
    }
    model.recordingModel.record(feedID: ids[0])
    try emitUntil("Rolling, the director with it") {
      model.directorRunningForTesting && model.timelineBoundForTesting(ids[0])
    }
    let first = model.timelineFileForTesting(ids[0])
    XCTAssertNotNil(first)
    model.setAutoHold(true)
    XCTAssertTrue(model.directorRunningForTesting, "Hold recreates the director; the take keeps it wanted")
    let second = model.timelineFileForTesting(ids[0])
    XCTAssertNotNil(second)
    XCTAssertNotEqual(first, second, "The take is bound to the new director's timeline")
    model.recordingModel.stop(feedID: ids[0])
    try emitUntil("The take closes") { model.recordingModel.feeds.first { $0.id == ids[0] }?.status == .idle }
  }
}

@MainActor private final class DirectorReviewRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
