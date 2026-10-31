#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

/// A camera that stops itself, a take that ends early, and an error that used to reach only
/// Diagnostics: each reaches the problem list and stays until someone has seen it.
@MainActor @objcMembers final class UnexpectedStopChecks: XCTestCase {
  private func appModel() -> AppModel {
    let suite = "org.ultracam.tests.stops.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    return AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: StopsRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      hardware: .offline)
  }

  private func stopped(_ cause: CaptureStopCause) -> CaptureUpdate {
    var update = CaptureUpdate(message: "Stopped")
    update.stopped = true
    update.stopCause = cause
    return update
  }

  func testOnlyAFailureIsUnexpected() {
    let model = appModel()
    let id = model.selectedFeedID
    model.deliverCaptureUpdateForTesting(id, stopped(.requested))
    XCTAssertNil(model.unexpectedStops[id], "Comparing messages can't tell these apart; the cause can")
    model.deliverCaptureUpdateForTesting(id, stopped(.failed("input disconnected")))
    XCTAssertEqual(model.unexpectedStops[id]?.reason, "input disconnected")
    XCTAssertEqual(model.unexpectedStops[id]?.cameraStopped, true)
    XCTAssertNil(model.unexpectedStops[id]?.take)
  }

  func testTakeResultFollowsAndDetailsAcknowledges() throws {
    let model = appModel()
    let id = model.selectedFeedID
    model.deliverCaptureUpdateForTesting(id, stopped(.failed("input disconnected")))
    let url = URL(fileURLWithPath: "/Volumes/8TB/Takes/Camera 1.mov")
    model.recordingModel.onRecordingFinished?(id, url)
    XCTAssertEqual(model.unexpectedStops[id]?.take, .saved(url, duration: 0, lostFrames: 0))
    model.acknowledgeUnexpectedStop(id)
    XCTAssertEqual(model.unexpectedStops[id]?.cameraStopped, true, "It's still stopped")
    XCTAssertNil(model.unexpectedStops[id]?.take, "The take is seen")
    XCTAssertTrue(model.acknowledgedTakes.contains(id))
    model.recordingModel.onRecordingStarted?(id, url)
    XCTAssertFalse(model.acknowledgedTakes.contains(id), "A new take starts clean")
  }

  func testAStoppedCameraWithNoTakeHasNoTakeResult() {
    let model = appModel()
    let id = model.selectedFeedID
    model.deliverCaptureUpdateForTesting(id, stopped(.failed("x")))
    model.recordingModel.onRecordingFinished?(id, nil)
    XCTAssertNil(model.unexpectedStops[id]?.take, "No frames written, nothing to recover")
  }

  func testRemovingTheCameraClearsIt() {
    let model = appModel()
    let id = model.selectedFeedID
    let other = model.addFeed()!
    model.deliverCaptureUpdateForTesting(id, stopped(.failed("x")))
    XCTAssertTrue(model.removeFeed(id))
    XCTAssertNil(model.unexpectedStops[id])
    XCTAssertEqual(model.selectedFeedID, other)
  }

  func testShownStopSeparatesCameraFromTake() {
    var stop = UnexpectedStop(reason: "input disconnected", at: Date(), cameraStopped: true, wasOnAir: true,
      take: .saved(URL(fileURLWithPath: "/a.mov"), duration: 751, lostFrames: 0))
    var shown = UISessionBridge.unexpectedStop(stop)
    XCTAssertEqual(shown.reason, "input disconnected")
    XCTAssertTrue(shown.take)
    XCTAssertEqual(shown.savedDuration, 751)
    stop.cameraStopped = false
    shown = UISessionBridge.unexpectedStop(stop)
    XCTAssertNil(shown.reason, "A restart clears the camera part")
    XCTAssertTrue(shown.take, "The take result stays until acknowledged")
    stop.take = .interrupted
    XCTAssertTrue(UISessionBridge.unexpectedStop(stop).take)
    XCTAssertNil(UISessionBridge.unexpectedStop(stop).savedDuration)
  }

  // MARK: As shown

  private func camera(_ stop: UIUnexpectedStop? = nil) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-1", name: "Camera 1")
    camera.unexpectedStop = stop
    camera.deviceAvailable = true
    camera.recording.folderPath = "/Volumes/8TB/Takes"
    return camera
  }

  private func session(_ cameras: UICameraSnapshot...) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.cameras = cameras
    return session
  }

  func testCameraStoppedWithItsTake() throws {
    let snapshot = camera(UIUnexpectedStop(reason: "input disconnected", take: true, savedDuration: 751))
    let problem = try XCTUnwrap(UIPresentationBuilder.problems(session(snapshot)).first)
    XCTAssertEqual(problem.title, "Camera 1 stopped: input disconnected")
    XCTAssertEqual(problem.detail, "Take ended early, 12:31 saved")
    XCTAssertEqual(problem.action, UIProblemAction(title: "Start", action: .startCamera(cameraID: "camera-1")))
    XCTAssertEqual(problem.level, .damage)
    XCTAssertEqual(UIPresentationBuilder.stripState(for: snapshot), .failed)
  }

  func testRestartedCameraKeepsItsTakeResultUntilDetails() throws {
    var snapshot = camera(UIUnexpectedStop(take: true, savedDuration: 751))
    snapshot.running = true
    snapshot.signal = .live(format: "2160p 59.94")
    let problem = try XCTUnwrap(UIPresentationBuilder.problems(session(snapshot)).first)
    XCTAssertEqual(problem.title, "Take ended early")
    XCTAssertEqual(problem.detail, "Camera 1, 12:31 saved")
    XCTAssertEqual(problem.action, UIProblemAction(title: "Details", action: .acknowledgeStop(cameraID: "camera-1")))
    let shown = UIPresentationBuilder.camera(snapshot, index: 0, in: session(snapshot))
    XCTAssertEqual(shown.recordTitle, "Take ended early")
    XCTAssertEqual(shown.recordDetail, "12:31 saved")
    XCTAssertEqual(shown.stripState, .failed)
  }

  func testFailedTakeWording() {
    var snapshot = camera()
    snapshot.recording.failed = true
    snapshot.recording.savedDuration = 1138
    let shown = UIPresentationBuilder.camera(snapshot, index: 0, in: session(snapshot))
    XCTAssertEqual(shown.recordTitle, "Take ended early", "Everywhere, by ruling 27")
    XCTAssertEqual(shown.recordDetail, "18:58 saved")
  }

  func testStopOnAirGetsThePanel() throws {
    let snapshot = camera(UIUnexpectedStop(reason: "x", wasOnAir: true))
    let alert = try XCTUnwrap(UIPresentationBuilder.problems(session(snapshot)).first?.alert)
    XCTAssertEqual(alert.event, .cameraStopped)
    XCTAssertTrue(alert.showsPanel)
    XCTAssertEqual(alert.title, "Camera 1 stopped")
    XCTAssertEqual(alert.body, "Was on Program")
    let quiet = camera(UIUnexpectedStop(reason: "x"))
    XCTAssertEqual(UIPresentationBuilder.problems(session(quiet)).first?.alert?.showsPanel, false)
  }
}

private final class StopsRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
