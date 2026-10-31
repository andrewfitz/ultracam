#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

/// The model's side of telling the truth live: who is really watching, and what can
/// only be known by the clock. Everything runs on the injected `now`, with no hardware.
@MainActor @objcMembers final class LiveWatchChecks: XCTestCase {
  private func defaults() -> UserDefaults {
    let suite = "org.ultracam.tests.livewatch.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return UserDefaults(suiteName: suite)!
  }

  private func appModel(hardware: AppHardware = .offline) -> AppModel {
    let defaults = self.defaults()
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    return AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: LiveWatchRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      hardware: hardware)
  }

  func testDemandMonitorRunsFromLaunchAndStaysOn() {
    var hardware = AppHardware.offline
    hardware.observesCameraDemand = true
    let model = appModel(hardware: hardware)
    XCTAssertTrue(model.demandMonitorIsRunning, "Separate cameras with no automatic start: the tally still needs clients")
    model.updateCamera(model.selectedFeedID) { $0.automaticFeed = true }
    model.updateCamera(model.selectedFeedID) { $0.automaticFeed = false }
    XCTAssertTrue(model.demandMonitorIsRunning, "Turning automatic start off must not stop it")
  }

  func testHarnessesStayOutOfCMIO() {
    XCTAssertFalse(appModel().demandMonitorIsRunning)
  }

  func testUnreadableDemandIsUnknownNotFalse() {
    let model = appModel()
    let id = model.selectedFeedID
    model.setCameraDemandForTesting(id, requested: nil)
    XCTAssertFalse(model.cameraInUse(id))
    XCTAssertTrue(model.cameraClientUnknown(id))
    model.setCameraDemandForTesting(id, requested: false)
    XCTAssertFalse(model.cameraClientUnknown(id))
    model.setCameraDemandForTesting(id, requested: true)
    XCTAssertTrue(model.cameraInUse(id))
    model.setProgramDemandForTesting(requested: nil)
    XCTAssertTrue(model.programClientUnknown)
    XCTAssertFalse(model.programInUse)
  }

  func testBridgeReportsClientsFromDemandNotFromTheSink() {
    let model = appModel()
    let bridge = UISessionBridge(model: model, interface: UIInterfaceState(defaults: defaults()))
    let id = model.selectedFeedID
    var update = CaptureUpdate(message: "")
    update.cameraOutputActive = true
    model.deliverCaptureUpdateForTesting(id, update)
    XCTAssertFalse(bridge.snapshot().cameras[0].inUse, "A stopped camera has no viewers, whatever its last update said")
    model.setCameraDemandForTesting(id, requested: nil)
    XCTAssertTrue(bridge.snapshot().cameras[0].clientUnknown)
  }

  func testAFullQueueCountsOnlyWhenItStaysFull() {
    let model = appModel()
    let id = model.selectedFeedID
    var update = CaptureUpdate(message: "")
    update.cameraQueueFullSince = 100
    model.deliverCaptureUpdateForTesting(id, update)
    model.liveWatchTick(now: 100 + LiveWatchLimits.queueStall - 0.1)
    XCTAssertFalse(model.stalledCameras.contains(id))
    model.liveWatchTick(now: 100 + LiveWatchLimits.queueStall)
    XCTAssertTrue(model.stalledCameras.contains(id))
    update.cameraQueueFullSince = nil
    model.deliverCaptureUpdateForTesting(id, update)
    model.liveWatchTick(now: 200)
    XCTAssertFalse(model.stalledCameras.contains(id), "Any accepted frame ends it")
  }

  /// A client with no frames waits out the grace, then raises a problem, and clears with demand.
  func testWaitingClientIsRaisedAfterItsGraceAndClearsWhenItLeaves() {
    let model = appModel()
    let id = model.selectedFeedID
    model.setCameraDemandForTesting(id, requested: true)
    model.liveWatchTick(now: 100)
    XCTAssertTrue(model.waitingClients.isEmpty, "Joining takes a moment")
    model.liveWatchTick(now: 100 + LiveWatchLimits.clientWaiting - 0.1)
    XCTAssertTrue(model.waitingClients.isEmpty)
    model.liveWatchTick(now: 100 + LiveWatchLimits.clientWaiting)
    XCTAssertEqual(model.waitingClients, [id])
    model.setCameraDemandForTesting(id, requested: false)
    model.liveWatchTick(now: 110)
    XCTAssertTrue(model.waitingClients.isEmpty)
    model.setCameraDemandForTesting(id, requested: nil)
    model.liveWatchTick(now: 120)
    model.liveWatchTick(now: 130)
    XCTAssertTrue(model.waitingClients.isEmpty, "An unknown route isn't a waiting client")
  }
}

private final class LiveWatchRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
