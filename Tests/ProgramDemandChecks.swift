#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import Foundation
import XCTest

/// Demand decides all work: a real model, the real switcher and fake capture. Nothing here
/// sets a mode, because there isn't one.
@MainActor @objcMembers final class ProgramDemandChecks: XCTestCase {
  private var fixture: AppHardwareSyntheticFixture!
  private var model: AppModel!
  private var ids: [FeedID] = []
  private var index: Int32 = 0

  private func prepare(cameras: Int = 2) throws {
    let devices = (1...cameras).map { "fake:\($0)" }
    let fixture = try AppHardwareSyntheticFixture(deviceIDs: devices)
    self.fixture = fixture
    fixture.connect()
    let suite = "org.ultracam.tests.demand.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: DemandRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      hardware: fixture.hardware)
    model.refresh()
    while model.feedDescriptors.count < cameras { _ = model.addFeed() }
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

  private func spin(_ what: String, _ done: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while !done() {
      guard Date() < deadline else { XCTFail(what); return }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
  }

  private func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }

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

  /// Every camera has sent frames, so Program has something on air.
  private func allProducing() throws {
    model.startAllCameras()
    try emitUntil("Every camera produces") { ids.allSatisfy { model.isProgramSourceProducingForTesting($0) } }
  }

  // MARK: Sources

  func testAManualStartStartsOnlyThatCamera() throws {
    try prepare()
    defer { finish() }
    model.updateCamera(ids[1], shareProcessing: false) { $0.automaticFeed = true }
    model.startCamera(ids[0])
    XCTAssertTrue(model.isCameraRunning(ids[0]))
    XCTAssertFalse(model.isCameraRunning(ids[1]), "Start All covers that habit")
  }

  func testAProgramClientStartsAutomaticCamerasAndTheHoldReleasesThem() throws {
    try prepare()
    defer { finish() }
    model.updateCamera(ids[1], shareProcessing: false) { $0.automaticFeed = true }
    model.setProgramDemandForTesting(requested: true)
    XCTAssertTrue(model.isCameraRunning(ids[1]))
    XCTAssertFalse(model.isCameraRunning(ids[0]), "A manual camera stays the operator's")
    let now = ProcessInfo.processInfo.systemUptime
    model.setProgramDemandForTesting(requested: false)
    XCTAssertTrue(model.isCameraRunning(ids[1]), "It may be a probe")
    model.liveWatchTick(now: now + LiveWatchLimits.clientRelease + 1)
    XCTAssertFalse(model.isCameraRunning(ids[1]))
  }

  // MARK: Cuts

  /// R1. The same button does the same thing in every layout, seen or not.
  func testACutWithNoClientIsARealCut() throws {
    try prepare()
    defer { finish() }
    try allProducing()
    guard case .queued = model.requestProgramCut(to: ids[1]) else { return XCTFail("A cut, not a preselection") }
    XCTAssertEqual(model.switcherPendingFeedID, ids[1], "NEXT until it lands")
    try emitUntil("It lands on the next frame") { model.switcherSelectedFeedID == ids[1] }
    spin("And counts like any cut") { model.recentCuts.count == 1 }
    XCTAssertEqual(model.recentCuts.first?.cameraID, ids[1].rawValue)
    XCTAssertNotNil(model.programShotStartedAt)
  }

  func testACutThatMissesAnISOClientSaysSoUntilProgramHasOne() throws {
    try prepare()
    defer { finish() }
    try allProducing()
    model.setCameraDemandForTesting(ids[1], requested: true)
    _ = model.requestProgramCut(to: ids[1])
    try emitUntil("It lands") { model.switcherSelectedFeedID == ids[1] }
    spin("Attention says so") { model.cutsMissClient }
    model.setProgramDemandForTesting(requested: true)
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime)
    XCTAssertFalse(model.cutsMissClient)
  }

  // MARK: Losing the on-air source

  /// R5: a live camera sits idle while Program goes black. It no longer does.
  func testLosingTheOnAirCameraMovesProgramToOneWithAPicture() throws {
    try prepare(cameras: 3)
    defer { finish() }
    try allProducing()
    model.setProgramDemandForTesting(requested: true)
    spin("Program connects") { fixture.programSink.openConnections == 1 }
    model.stopCamera(ids[0])
    XCTAssertEqual(model.switcherSelectedFeedID, ids[1], "The next in camera order")
    XCTAssertEqual(model.programMoved?.title, "\(model.descriptor(for: ids[0])!.name) stopped")
    XCTAssertEqual(model.programMoved?.to, model.descriptor(for: ids[1])?.name)
    settle()
    XCTAssertEqual(fixture.programSink.connectAttempts, 1, "The contract owner stayed: frames convert")
    model.startCamera(ids[0])
    XCTAssertNil(model.programMoved, "It's back")
  }

  func testNobodyIsToldAboutASelectionNoClientCanSee() throws {
    try prepare()
    defer { finish() }
    try allProducing()
    model.stopCamera(ids[0])
    XCTAssertEqual(model.switcherSelectedFeedID, ids[1], "The tag follows")
    XCTAssertNil(model.programMoved)
  }

  func testAProgramClientMovesOffACameraThatHasNoPictureYet() throws {
    try prepare()
    defer { finish() }
    model.startCamera(ids[1])
    try emitUntil("One camera has a picture") { model.isProgramSourceProducingForTesting(ids[1]) }
    XCTAssertEqual(model.switcherSelectedFeedID, ids[0], "Stopped and on air: nothing moved it yet")
    model.setProgramDemandForTesting(requested: true)
    XCTAssertEqual(model.switcherSelectedFeedID, ids[1])
    XCTAssertEqual(model.programMoved?.cause, .notReady)
  }

  // MARK: Idle

  /// The source-only path, in the app: nobody watching, and every surface reads it as a
  /// healthy running camera, not one forever updating its output.
  func testAnIdleCameraReadsAsLiveAndCutsStillLand() throws {
    try prepare()
    defer { finish() }
    try allProducing()
    let bridge = UISessionBridge(model: model, interface: UIInterfaceState(defaults: UserDefaults(suiteName: "org.ultracam.tests.demand.ui.\(UUID().uuidString)")!))
    try emitUntil("Status arrives") {
      let camera = bridge.snapshot().cameras[0]
      return !camera.applying && camera.outputFormat != nil
    }
    let shown = bridge.presentation().cameras[0]
    XCTAssertEqual(shown.tileState, .live)
    XCTAssertEqual(model.cameraUpdate(ids[0])?.gpuMS, 0, "Nothing rendered")
    XCTAssertEqual(model.cameraUpdate(ids[0])?.processingMS, 0)
    _ = model.requestProgramCut(to: ids[1])
    try emitUntil("The cut lands on a frame nothing rendered") { model.switcherSelectedFeedID == ids[1] }
    XCTAssertEqual(model.programOutputDiagnostics.route.published, 0)
    XCTAssertGreaterThan(model.programOutputDiagnostics.route.withoutConsumer, 0)
  }

  // MARK: Both routes

  /// One frame, two clients, no copy: every frame reaches the camera's own sink and Program.
  func testISOAndProgramClientsBothGetEveryFrame() throws {
    try prepare()
    defer { finish() }
    try allProducing()
    model.setCameraDemandForTesting(ids[0], requested: true)
    model.setProgramDemandForTesting(requested: true)
    spin("Both sinks open") { fixture.sink.openConnections == 1 && fixture.programSink.openConnections == 1 }
    try emitUntil("A frame goes each way") {
      fixture.sink.sentCount > 0 && model.programOutputDiagnostics.route.published > 0
    }
    let sent = fixture.sink.sentCount, published = model.programOutputDiagnostics.route.published
    let pattern = try fixture.makePattern()
    for _ in 0..<10 {
      try fixture.emit(pattern, index: index)
      index += 1
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    spin("Each of the next ten reaches its own sink") { fixture.sink.sentCount == sent + 10 }
    spin("And Program") { model.programOutputDiagnostics.route.published >= published + 10 }
    XCTAssertEqual(model.programOutputDiagnostics.route.overflowRejected, 0)
    XCTAssertEqual(model.programOutputDiagnostics.route.normalized, 0, "The same buffer, not a copy")
  }

  // MARK: Director

  private func natural(_ on: Bool) {
    model.naturalTalkingHeadEnabled = on
  }

  /// R7: strategy, two running, and something for its cuts to reach.
  func testDirectorRunsForAPictureOrATakeNotForNobody() throws {
    try prepare()
    defer { finish() }
    natural(true)
    model.startAllCameras()
    XCTAssertFalse(model.directorRunningForTesting, "Its cuts would reach nobody")
    let now = ProcessInfo.processInfo.systemUptime
    model.setProgramDemandForTesting(requested: true)
    XCTAssertTrue(model.directorRunningForTesting)
    model.setProgramDemandForTesting(requested: false)
    model.liveWatchTick(now: now + 1)
    XCTAssertTrue(model.directorRunningForTesting, "A probe doesn't restart it, or end its timeline")
    model.liveWatchTick(now: now + LiveWatchLimits.clientRelease + 1)
    XCTAssertFalse(model.directorRunningForTesting)
    model.stopCamera(ids[1])
    model.setProgramDemandForTesting(requested: true)
    XCTAssertFalse(model.directorRunningForTesting, "One camera: nothing to cut to")
  }

  func testATakeStartsTheDirectorAndBindsToItsTimeline() throws {
    try prepare()
    defer { finish() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("demand-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    model.recordingModel.outputFolder = folder
    natural(true)
    try allProducing()
    XCTAssertFalse(model.directorRunningForTesting)
    model.recordingModel.record(feedID: ids[0])
    try emitUntil("Rolling, the director with it") { model.directorRunningForTesting }
    XCTAssertTrue(model.timelineBoundForTesting(ids[0]), "The take is bound to the timeline its start created")
    model.recordingModel.stop(feedID: ids[0])
    try emitUntil("The take closes") { model.recordingModel.feeds.first { $0.id == ids[0] }?.status == .idle }
    XCTAssertFalse(model.directorRunningForTesting)
  }
}

private final class DemandRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
