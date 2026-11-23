#if ULTRACAM_TEST_SUPPORT
import AppKit
import CoreMedia
import Foundation
import Observation
import Synchronization
import XCTest

/// Demand decides all work: a real model, the real switcher and fake capture. Nothing here
/// sets a mode, because there isn't one.
@MainActor @objcMembers final class ProgramDemandChecks: XCTestCase {
  private var fixture: AppHardwareSyntheticFixture!
  private var model: AppModel!
  private var ids: [FeedID] = []
  private var index: Int32 = 0
  private var publisher: DemandRegistryPublisher!
  private var defaults: UserDefaults!

  private func prepare(cameras: Int = 2, recordingDriver: RecordingSessionDriver? = nil,
                       authorization: TestCaptureAuthorization? = nil) throws {
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
    self.defaults = defaults
    publisher = DemandRegistryPublisher()
    var hardware = fixture.hardware
    if let authorization {
      let listedDevices = hardware.devices
      hardware.devices = {
        authorization.refreshCount += 1
        return authorization.status == .authorized ? try listedDevices() : []
      }
      hardware.observeDevices = { _ in nil }
      hardware.captureAuthorization = { _, _ in authorization.status }
      hardware.authorizeCapture = { _, deviceID in try await authorization.request(deviceID: deviceID) }
    }
    model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: publisher,
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      recordingDriver: recordingDriver, hardware: hardware)
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
    try emitUntil("Every camera produces, and says it's live") {
      ids.allSatisfy { model.isProgramSourceProducingForTesting($0) && model.cameraUpdate($0)?.signal == .live }
    }
  }

  // MARK: Sources

  func testCapturePreferencesSaveWithoutRepublishingIdenticalVirtualCameras() throws {
    try prepare()
    defer { finish() }
    let id = ids[0]
    let published = publisher.published
    model.updateCamera(id, shareProcessing: false) { $0.automaticFeed = true }
    XCTAssertEqual(publisher.published, published)
    let saved = AppSettingsStore(defaults: defaults).loadSnapshot()
    XCTAssertEqual(saved.feeds.first(where: { $0.id == id })?.automaticFeed, true)
    XCTAssertTrue(model.renameFeed(id, name: "Renamed Camera"))
    XCTAssertEqual(publisher.published, published + 1)
  }

  func testAManualStartStartsOnlyThatCamera() throws {
    try prepare()
    defer { finish() }
    model.updateCamera(ids[1], shareProcessing: false) { $0.automaticFeed = true }
    model.startCamera(ids[0])
    XCTAssertTrue(model.isCameraRunning(ids[0]))
    XCTAssertFalse(model.isCameraRunning(ids[1]), "Start All covers that habit")
  }

  func testColdManualStartOpensHiddenInputOnceAfterGrant() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    XCTAssertTrue(model.devices.isEmpty)
    XCTAssertTrue(model.canRequestCaptureStart(id))
    model.startCamera(id)
    model.startCamera(id)
    spin("Authorization was requested") { authorization.requests.count == 1 }
    XCTAssertEqual(authorization.requests, ["fake:1"])
    XCTAssertFalse(model.isCameraRunning(id))
    authorization.grant()
    spin("Capture opens after grant") { model.isCameraRunning(id) }
    XCTAssertFalse(model.isCaptureAuthorizationPending(id))
    XCTAssertFalse(model.isCameraRunning(ids[1]))
  }

  func testStopAllDiscardsPendingManualCapture() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    model.startCamera(ids[0])
    spin("Authorization was requested") { authorization.requests.count == 1 }
    model.stopAllCameras()
    let refresh = authorization.refreshCount
    authorization.grant()
    spin("Grant refreshed inventory") { authorization.refreshCount > refresh }
    XCTAssertFalse(model.isCameraRunning(ids[0]))
  }

  func testAnOldPermissionCompletionCannotConsumeANewerStart() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    model.startCamera(id)
    spin("First authorization was requested") { authorization.requests.count == 1 }
    model.stopCamera(id)
    model.startCamera(id)
    spin("Second authorization was requested") { authorization.requests.count == 2 }
    let refresh = authorization.refreshCount
    authorization.grant()
    spin("Old grant refreshed inventory") { authorization.refreshCount > refresh }
    XCTAssertTrue(model.isCaptureAuthorizationPending(id))
    XCTAssertFalse(model.isCameraRunning(id))
    authorization.grant()
    spin("Only the current request opens capture") { model.isCameraRunning(id) }
  }

  func testReassigningPendingCaptureDiscardsTheGrant() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    model.startCamera(id)
    spin("Authorization was requested") { authorization.requests.count == 1 }
    model.updateCamera(id, shareProcessing: false) { $0.selectedDevice = "" }
    let refresh = authorization.refreshCount
    authorization.grant()
    spin("Grant refreshed inventory") { authorization.refreshCount > refresh }
    XCTAssertEqual(model.descriptor(for: id)?.selectedDevice, "")
    XCTAssertFalse(model.isCameraRunning(id))
  }

  func testReassigningAutomaticCaptureStartsOnlyTheNewInputUnderHeldDemand() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    model.updateCamera(id, shareProcessing: false) { $0.automaticFeed = true }
    model.setCameraDemandForTesting(id, requested: true)
    spin("The first input requested authorization") { authorization.requests.count == 1 }
    model.assignExclusiveInput("fake:2", to: id)
    spin("The reassigned input requested authorization") { authorization.requests.count == 2 }
    XCTAssertEqual(authorization.requests, ["fake:1", "fake:2"])
    let refresh = authorization.refreshCount
    authorization.grant()
    spin("The old request refreshed inventory") { authorization.refreshCount > refresh }
    XCTAssertTrue(model.isCaptureAuthorizationPending(id))
    XCTAssertFalse(model.isCameraRunning(id))
    XCTAssertTrue(fixture.plugin.sessions.isEmpty)
    authorization.grant()
    spin("Capture opened only the reassigned input") { fixture.plugin.sessions.first?.deviceID == "fake:2" }
    XCTAssertEqual(fixture.plugin.sessions.map(\.deviceID), ["fake:2"])
    XCTAssertFalse(model.isCaptureAuthorizationPending(id))
  }

  func testAutomaticPendingCaptureEndsAsSoonAsClientLeaves() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    model.updateCamera(id, shareProcessing: false) { $0.automaticFeed = true }
    model.setCameraDemandForTesting(id, requested: true)
    spin("Authorization was requested") { authorization.requests.count == 1 }
    model.setCameraDemandForTesting(id, requested: false)
    XCTAssertFalse(model.isCaptureAuthorizationPending(id))
    let refresh = authorization.refreshCount
    authorization.grant()
    spin("Grant refreshed inventory") { authorization.refreshCount > refresh }
    XCTAssertFalse(model.isCameraRunning(id))
  }

  func testColdAutomaticCaptureStartsOnGrantAndReleasesAfterTheClientLeaves() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    model.updateCamera(id, shareProcessing: false) { $0.automaticFeed = true }
    model.setCameraDemandForTesting(id, requested: true)
    spin("Authorization was requested") { authorization.requests.count == 1 }
    authorization.grant()
    spin("Current automatic demand started capture") { model.isCameraRunning(id) }
    model.setCameraDemandForTesting(id, requested: false)
    XCTAssertTrue(model.isCameraRunning(id))
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + LiveWatchLimits.clientRelease + 1)
    XCTAssertFalse(model.isCameraRunning(id))
  }

  func testAutomaticPermissionDenialStaysLatchedThroughStatusRefresh() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    model.updateCamera(id, shareProcessing: false) { $0.automaticFeed = true }
    model.setCameraDemandForTesting(id, requested: true)
    spin("Authorization was requested") { authorization.requests.count == 1 }
    authorization.deny()
    spin("Denied authorization was consumed") { !model.isCaptureAuthorizationPending(id) }
    XCTAssertEqual(model.automaticStatus(id), "Allow Camera in Privacy & Security.")
    authorization.status = .authorized
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    spin("Activation refreshed previously hidden inventory") { !model.devices.isEmpty }
    XCTAssertFalse(model.isCameraRunning(id))
    model.retryAutomaticFeed(feedID: id)
    XCTAssertTrue(model.isCameraRunning(id))
  }

  func testExistingPermissionDenialDoesNotConsumeTheFirstAutomaticAttempt() throws {
    let authorization = TestCaptureAuthorization()
    authorization.status = .unavailable(.unavailable("Allow Camera in Privacy & Security."))
    try prepare(authorization: authorization)
    defer { finish() }
    let id = ids[0]
    model.updateCamera(id, shareProcessing: false) { $0.automaticFeed = true }
    model.setCameraDemandForTesting(id, requested: true)
    XCTAssertEqual(model.automaticStatus(id), "Allow Camera in Privacy & Security.")
    XCTAssertFalse(model.isCaptureAuthorizationPending(id))
    authorization.status = .authorized
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    spin("Activation started capture under current demand") { model.isCameraRunning(id) }
    XCTAssertTrue(authorization.requests.isEmpty)
  }

  func testHardwareCanUnlockDiscoveryBeforeAnyFeedStarts() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    XCTAssertTrue(model.devices.isEmpty)
    XCTAssertEqual(model.captureAuthorizationStatus(pluginID: "fake"), .requestable)
    model.requestCaptureAccess(pluginID: "fake")
    model.requestCaptureAccess(pluginID: "fake")
    spin("Hardware requested capture access") { authorization.requests.count == 1 }
    XCTAssertNil(authorization.requests.first ?? nil)
    authorization.grant()
    spin("Grant refreshed previously hidden inventory") { !model.devices.isEmpty }
    XCTAssertFalse(model.isRequestingCaptureAccess(pluginID: "fake"))
    XCTAssertFalse(ids.contains(where: model.isCameraRunning))
  }

  func testHardwarePermissionDenialStaysInDriverStatus() throws {
    let authorization = TestCaptureAuthorization()
    try prepare(authorization: authorization)
    defer { finish() }
    model.requestCaptureAccess(pluginID: "fake")
    spin("Hardware requested capture access") { authorization.requests.count == 1 }
    authorization.deny()
    spin("Hardware refreshed permission status") { !model.isRequestingCaptureAccess(pluginID: "fake") }
    XCTAssertEqual(model.captureAuthorizationStatus(pluginID: "fake"), authorization.status)
    XCTAssertFalse(model.appProblems.contains { $0.id == "capture-authorization.fake" })
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

  /// Down to one camera, Program and its client are gone, and so is what they started.
  func testRemovingTheSecondCameraReleasesWhatProgramStarted() throws {
    try prepare()
    defer { finish() }
    model.updateCamera(ids[1], shareProcessing: false) { $0.automaticFeed = true }
    model.setProgramDemandForTesting(requested: true)
    XCTAssertTrue(model.isCameraRunning(ids[1]))
    XCTAssertTrue(model.removeFeed(ids[0]))
    XCTAssertFalse(model.programAvailable)
    XCTAssertFalse(model.programInUse)
    XCTAssertFalse(model.isCameraRunning(ids[1]), "Nothing needs it now")
    XCTAssertFalse(model.cameraRequested(ids[1]))
  }

  /// Program's camera gets the on-air camera's format before a client finds it: when it is
  /// published, when it's published again after a spell with one camera, and after a session.
  func testProgramIsPreparedEachTimeItIsPublishedAndAfterEachSession() throws {
    try prepare(cameras: 1)
    defer { finish() }
    model.startCamera(ids[0])
    try emitUntil("Its cadence is known") { model.cameraUpdate(ids[0])?.sourceDuration != nil }
    settle()
    XCTAssertEqual(fixture.programSink.preNegotiations, 0, "One camera: no Program")
    let second = try XCTUnwrap(model.addFeed())
    spin("Published, and prepared") { fixture.programSink.preNegotiations == 1 }
    XCTAssertTrue(model.removeFeed(second))
    _ = try XCTUnwrap(model.addFeed())
    spin("Published again, and prepared again") { fixture.programSink.preNegotiations == 2 }
    model.setProgramDemandForTesting(requested: true)
    spin("A client opens it") { fixture.programSink.openConnections == 1 }
    let now = ProcessInfo.processInfo.systemUptime
    model.setProgramDemandForTesting(requested: false)
    model.liveWatchTick(now: now + LiveWatchLimits.clientRelease + 1)
    spin("It closes") { fixture.programSink.openConnections == 0 }
    spin("And is prepared for the next client") { fixture.programSink.preNegotiations == 3 }
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

  /// A cut saves the selection alone. The full save walked CMIO's devices and the extension's
  /// registry on the main thread before the cut was queued: the lag between click and cut.
  func testACutSavesTheSelectionWithoutPublishingTheCameras() throws {
    try prepare()
    defer { finish() }
    try allProducing()
    let published = publisher.published
    guard case .queued = model.requestProgramCut(to: ids[1]) else { return XCTFail("A cut") }
    try emitUntil("It lands") { model.switcherSelectedFeedID == ids[1] }
    settle()
    XCTAssertEqual(publisher.published, published, "No camera changed: nothing to publish")
    XCTAssertEqual(AppSettingsStore(defaults: defaults).loadSnapshot().switcher.selectedFeedID, ids[1],
      "What is on air is saved")
  }

  /// The window follows the selection and a requested cut the moment they change. Both live
  /// in the capture coordinator, which SwiftUI can't observe, so a click on another camera
  /// showed only once something else in the window changed.
  func testSelectingAndCuttingTellTheWindowAtOnce() throws {
    try prepare()
    defer { finish() }
    func changes(_ read: () -> Void, when change: () -> Void) -> Bool {
      let fired = Mutex(false)
      withObservationTracking(read) { fired.withLock { $0 = true } }
      change()
      return fired.withLock { $0 }
    }
    XCTAssertTrue(changes({ _ = model.selectedFeedID }) { _ = model.selectFeed(ids[1]) }, "Selection")
    try allProducing()
    XCTAssertTrue(changes({ _ = model.switcherPendingFeedID }) { _ = model.requestProgramCut(to: ids[1]) }, "NEXT")
    try emitUntil("It lands") { model.switcherSelectedFeedID == ids[1] }
  }

  /// Removing the selected camera, the one on air, moves the selection and Program to the
  /// camera left. Nothing else tells the window: no cut lands, so no event follows.
  func testRemovingTheSelectedCameraTellsTheWindow() throws {
    try prepare()
    defer { finish() }
    XCTAssertEqual(model.switcherSelectedFeedID, ids[0])
    let fired = Mutex(false)
    withObservationTracking { _ = model.selectedFeedID } onChange: { fired.withLock { $0 = true } }
    XCTAssertTrue(model.removeFeed(ids[0]))
    settle()
    XCTAssertEqual(model.selectedFeedID, ids[1])
    XCTAssertEqual(model.switcherSelectedFeedID, ids[1])
    XCTAssertTrue(fired.withLock { $0 }, "The selection and Program moved")
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

  /// Auto off, the on-air HDMI drops past the hold and comes back. Cuts to it wait out
  /// the 5 s; Program shows its frames again from the first one.
  func testTheOnAirCameraIsBackOnProgramTheMomentItsSignalIs() throws {
    try prepare()
    defer { finish() }
    try allProducing()
    let onAir = try XCTUnwrap(model.switcherSelectedFeedID)
    let start = ProcessInfo.processInfo.systemUptime
    var lost = CaptureUpdate(message: "")
    lost.signal = .lost(since: start)
    model.deliverCaptureUpdateForTesting(onAir, lost)
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    XCTAssertTrue(model.isSignalUnhealthy(onAir))
    XCTAssertEqual(model.switcherSelectedFeedID, onAir, "Auto off: Program stays")
    let before = model.programOutputDiagnostics.route
    try emitUntil("The signal is back, and so is Program") {
      model.programOutputDiagnostics.route.accepted >= before.accepted + 10
    }
    XCTAssertTrue(model.isSignalUnhealthy(onAir), "Still inside the 5 s")
    XCTAssertEqual(model.programOutputDiagnostics.route.skippedMissingSource, before.skippedMissingSource)
    XCTAssertNil(model.programIssue)
    let other = try XCTUnwrap(ids.first { $0 != onAir })
    _ = model.requestProgramCut(to: other)
    try emitUntil("A cut away lands") { model.switcherSelectedFeedID == other }
    if case .rejectedMissingSource = model.requestProgramCut(to: onAir) {} else {
      XCTFail("But no cut goes back to it until it has been steady")
    }
  }

  /// A stop moves Program by the same rule as a lost signal: strip order, and a live signal.
  func testAStopMovesProgramByTheLossRule() throws {
    try prepare(cameras: 3)
    defer { finish() }
    try allProducing()
    model.stripOrder = { [ids] _ in [ids[0], ids[2], ids[1]] }
    model.stopCamera(ids[0])
    XCTAssertEqual(model.switcherSelectedFeedID, ids[2], "Next in the strip, not next in the settings")
    var lost = CaptureUpdate(message: "")
    lost.signal = .lost(since: ProcessInfo.processInfo.systemUptime)
    model.deliverCaptureUpdateForTesting(ids[1], lost)
    model.stopCamera(ids[2])
    XCTAssertEqual(model.switcherSelectedFeedID, ids[2], "A camera whose signal just dropped is no picture to move to")
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
    try emitUntil("One camera has a picture") {
      model.isProgramSourceProducingForTesting(ids[1]) && model.cameraUpdate(ids[1])?.signal == .live
    }
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

  func testDirectorWaitsForItsFirstCaptureClockBeforeAgingTheShot() throws {
    try prepare()
    defer { finish() }
    natural(true)
    model.startAllCameras()
    model.setProgramDemandForTesting(requested: true)
    XCTAssertTrue(model.directorRunningForTesting)
    let clock = try XCTUnwrap(model.directorClockFeedIDForTesting)
    XCTAssertNil(model.cameraUpdate(clock)?.mediaTime, "Capture is opening, without a clock sample")
    let onAir = model.switcherSelectedFeedID
    var update = CaptureUpdate(message: "First capture clock")
    update.mediaTime = CMTime(seconds: 1000, preferredTimescale: 240_000)
    update.audioPacketTime = update.mediaTime
    model.deliverCaptureUpdateForTesting(clock, update)
    settle()
    XCTAssertEqual(model.switcherSelectedFeedID, onAir,
      "An absolute source PTS is the start of the shot, not a thousand-second shot")
    XCTAssertNil(model.switcherPendingFeedID)
  }

  private func natural(_ on: Bool) {
    model.naturalTalkingHeadEnabled = on
  }

  func testRunningDirectorKeepsSurvivingCameraWhenAnchorStops() throws {
    try prepare()
    defer { finish() }
    natural(true)
    model.startAllCameras()
    model.setProgramDemandForTesting(requested: true)
    XCTAssertTrue(model.directorRunningForTesting)
    XCTAssertEqual(model.directorClockFeedIDForTesting, ids[0])
    model.stopCamera(ids[0])
    XCTAssertTrue(model.directorRunningForTesting)
    XCTAssertEqual(model.directorClockFeedIDForTesting, ids[1])
    model.stopCamera(ids[1])
    XCTAssertFalse(model.directorRunningForTesting)
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

  /// A director's cut withdrawn before it lands, its decision lapsed or Auto turned off, is no
  /// failure: NEXT goes and nothing is reported. A cut whose camera stops still says so.
  func testAWithdrawnDirectorCutIsQuietAndAStoppedTargetIsNot() throws {
    try prepare()
    defer { finish() }
    natural(true)
    try allProducing()
    model.setProgramDemandForTesting(requested: true)
    XCTAssertTrue(model.directorRunningForTesting)
    func ask() -> UUID {
      let decision = UUID()
      model.deliverDirectorInstructionForTesting(AutoSwitcherInstruction(decisionID: decision, sessionGeneration: 1,
        targetCameraID: ids[1], cutTime: .zero, expiresAt: .zero, confidence: 1, reason: "test", forced: false))
      spin("The director's cut waits") { model.switcherPendingFeedID == ids[1] }
      return decision
    }
    model.expireDirectorDecisionForTesting(ask())
    spin("Its decision lapsed") { model.switcherPendingFeedID == nil }
    settle()
    XCTAssertEqual(model.switcherSelectedFeedID, ids[0], "Dropped, not landed")
    XCTAssertNil(model.programIssue, "A lapsed decision is no failure")
    _ = ask()
    natural(false)
    settle()
    XCTAssertNil(model.switcherPendingFeedID)
    XCTAssertNil(model.programIssue, "Turning Auto off is no failure")
    guard case .queued = model.requestProgramCut(to: ids[1]) else { return XCTFail("A cut") }
    model.stopCamera(ids[1])
    settle()
    XCTAssertNil(model.switcherPendingFeedID)
    XCTAssertNotNil(model.programIssue, "A camera that stopped under its cut still says so")
  }

  private func prepareRecordingFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    model.recordingModel.outputFolder = folder
  }

  func testBackupDemandSurvivesLateDiscoveryAndInspectorSelection() throws {
    let driver = DemandRecordingDriver()
    try prepare(recordingDriver: driver)
    defer { finish() }
    try prepareRecordingFolder()
    let first = ids[0], second = ids[1]
    model.updateCamera(second) { $0.selectedDevice = "" }
    fixture.disconnect()
    spin("The assigned input disconnected") { model.devices.isEmpty }
    for camera in ids {
      model.updateCamera(camera) { $0.recordWithCameraApps = true }
      model.setCameraDemandForTesting(camera, requested: true, apps: ["us.zoom.xos"])
      XCTAssertFalse(model.isCameraRunning(camera))
    }
    fixture.connect()
    spin("The returning input starts its camera") { model.isCameraRunning(first) }
    XCTAssertFalse(model.isCameraRunning(second))
    model.updateCamera(second) { $0.selectedDevice = "fake:2" }
    XCTAssertTrue(model.isCameraRunning(second))
    for camera in ids {
      var update = CaptureUpdate(message: "")
      update.signal = .live
      model.deliverCaptureUpdateForTesting(camera, update)
    }
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + CameraAppRecordingDemand.startDelay + 1)
    XCTAssertEqual(Set(driver.started), Set(ids))
    XCTAssertTrue(model.recordingModel.feeds.allSatisfy { $0.status == .recording && $0.triggerAppID == "us.zoom.xos" })
    for camera in ids { model.recordingModel.stop(feedID: camera) }
  }

  func testAutoDuringManualTakeStartsAndReleasesOtherCamera() throws {
    try prepare(recordingDriver: DemandRecordingDriver())
    defer { finish() }
    try prepareRecordingFolder()
    let first = ids[0], second = ids[1]
    model.updateCamera(second) { $0.previewEnabled = false; $0.automaticFeed = true }
    model.startCamera(first)
    model.recordingModel.record(feedID: first)
    XCTAssertEqual(model.recordingModel.feeds.first { $0.id == first }?.status, .recording)
    var switcher = model.switcherSettings
    switcher.strategy = .fixedInterval
    XCTAssertFalse(model.isCameraRunning(second))
    switcher.automatic = true
    model.updateSwitcher(switcher)
    XCTAssertTrue(model.isCameraRunning(second))
    switcher.automatic = false
    model.updateSwitcher(switcher)
    XCTAssertFalse(model.isCameraRunning(second))
    XCTAssertTrue(model.isCameraRunning(first))
    model.recordingModel.stop(feedID: first)
  }

  func testExplicitEmphasisReservesFirstLiveCamera() throws {
    try prepare()
    defer { finish() }
    model.naturalEmphasisFeedID = ids[0]
    model.naturalAnchorFeedID = ids[0]
    XCTAssertNil(model.naturalAnchorFeedID)
    natural(true)
    model.startAllCameras()
    model.setProgramDemandForTesting(requested: true)
    XCTAssertTrue(model.directorRunningForTesting)
    XCTAssertEqual(model.directorClockFeedIDForTesting, ids[1])
  }

  func testInputChangeAndMonitorResetClearBothSourceDeclarations() throws {
    try prepare()
    defer { finish() }
    let id = ids[0], peer = ids[1]
    let target = MonitorTargetID(id.rawValue)
    let store = AppSettingsStore(defaults: defaults)
    model.setSyncCameras(true, sourceID: id)
    model.updateCamera(peer, shareProcessing: false) { $0.setSourceProfile("rec709-video") }
    for profile in ["sony-slog3-sgamut3cine", "rec2020-hlg-video"] {
      for reset in [false, true] {
        model.updateCamera(id, shareProcessing: false) { $0.setSourceProfile(profile) }
        XCTAssertEqual(store.loadSnapshot().feeds.first { $0.id == id }?.sourceProfileID, profile)
        if reset { model.monitorCoordinator.resetSettings(for: target) }
        else { model.updateCamera(id) { $0.selectedDevice = $0.selectedDevice == "fake:1" ? "fake:2" : "fake:1" } }
        for item in [model.descriptor(for: id), store.loadSnapshot().feeds.first { $0.id == id }] {
          let descriptor = try XCTUnwrap(item)
          XCTAssertEqual(descriptor.sourceProfileID, "unspecified")
          XCTAssertNil(descriptor.monitor.signal.logProfileID)
          XCTAssertNil(descriptor.monitor.signal.sourceProfileID)
          XCTAssertEqual(descriptor.monitor, model.monitorCoordinator.preferences(for: target))
        }
        XCTAssertEqual(model.descriptor(for: peer)?.sourceProfileID, "rec709-video")
      }
    }
  }

  func testConfirmedSyncUsesTheCameraThatOpenedThePrompt() throws {
    try prepare()
    defer { finish() }
    let source = ids[0], peer = ids[1]
    model.updateCamera(source, shareProcessing: false) { $0.previewEnabled = false }
    model.updateCamera(peer, shareProcessing: false) { $0.previewEnabled = true }
    let bridge = UISessionBridge(model: model, interface: UIInterfaceState(defaults: defaults))
    XCTAssertTrue(model.selectFeed(source))
    let action = UIAction.setSyncCameras(true, sourceID: source.rawValue)
    XCTAssertTrue(model.selectFeed(peer))
    bridge.send(action, confirmed: true)
    XCTAssertTrue(model.syncCameras)
    XCTAssertEqual(model.selectedFeedID, peer)
    XCTAssertEqual(model.descriptor(for: peer)?.previewEnabled, false)
  }

  func testRecordingBindingObservesRepeatedTriggerEdits() throws {
    try prepare(cameras: 1)
    defer { finish() }
    let pane = UISettingsRecordingPane(model: model, interface: UIInterfaceState(defaults: defaults))
    let binding = pane.recordWithCameraApps(for: ids[0])
    for enabled in [true, false] {
      let fired = Mutex(false)
      withObservationTracking { _ = binding.wrappedValue } onChange: { fired.withLock { $0 = true } }
      binding.wrappedValue = enabled
      XCTAssertTrue(fired.withLock { $0 })
      XCTAssertEqual(binding.wrappedValue, enabled)
    }
  }

  func testSharedHardwareMenuChangesOnlyChosenCamera() throws {
    try prepare(cameras: 3)
    defer { finish() }
    let pane = UISettingsHardwarePane(model: model, interface: UIInterfaceState(defaults: defaults))
    let device = "fake:1"
    XCTAssertTrue(model.inputShareable(device))
    let bindings = ids.map { pane.membership(of: $0, in: device) }
    bindings[1].wrappedValue = true
    bindings[2].wrappedValue = true
    XCTAssertEqual(bindings.map(\.wrappedValue), [true, true, true])
    bindings[1].wrappedValue = false
    XCTAssertEqual(bindings.map(\.wrappedValue), [true, false, true])
    model.updateCamera(ids[1]) { $0.selectedDevice = "fake:2" }
    bindings[1].wrappedValue = false
    XCTAssertEqual(model.descriptor(for: ids[1])?.selectedDevice, "fake:2")
  }

  func testExclusiveHardwareTransferChecksDestinationBeforeReleasingOwner() throws {
    try prepare()
    defer { finish() }
    let source = ids[0], destination = ids[1]
    let device = "fake:offline"
    model.updateCamera(source) { $0.selectedDevice = device }
    model.startCamera(destination)
    XCTAssertFalse(model.canChangeCameraInput(destination))
    model.assignExclusiveInput(device, to: destination)
    XCTAssertEqual(model.descriptor(for: source)?.selectedDevice, device)
    XCTAssertEqual(model.descriptor(for: destination)?.selectedDevice, "fake:2")

    model.stopCamera(destination)
    spin("Capture no longer owns the input") { model.canChangeCameraInput(destination) }
    model.assignExclusiveInput(device, to: destination)
    XCTAssertEqual(model.descriptor(for: source)?.selectedDevice, "")
    XCTAssertEqual(model.descriptor(for: destination)?.selectedDevice, device)
    let saved = AppSettingsStore(defaults: defaults).loadSnapshot().feeds
    XCTAssertEqual(saved.first { $0.id == source }?.selectedDevice, "")
    XCTAssertEqual(saved.first { $0.id == destination }?.selectedDevice, device)
  }

  func testSelectedAppRecordsCameraAndProgramWithoutOwningManualTakes() throws {
    try prepare()
    defer { finish() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let recording = model.recordingModel
    recording.outputFolder = folder
    let first = ids[0], second = ids[1]
    func state(_ id: FeedID) -> RecordingFeedState { recording.feeds.first { $0.id == id }! }
    for id in ids { model.updateCamera(id) { $0.recordWithCameraApps = true } }
    let store = AppSettingsStore(defaults: defaults)
    XCTAssertTrue(store.loadSnapshot().feeds.allSatisfy(\.recordWithCameraApps))
    XCTAssertEqual(model.recordingApps, ["us.zoom.xos": "Zoom"])
    model.setCameraDemandForTesting(first, requested: true, apps: ["com.example.viewer"])
    XCTAssertFalse(model.isCameraRunning(first))
    model.setCameraDemandForTesting(first, requested: true, apps: ["us.zoom.ZoomMeeting"])
    XCTAssertTrue(model.isCameraRunning(first))
    XCTAssertFalse(model.isCameraRunning(second))
    try emitUntil("Camera has a source") { model.cameraUpdate(first)?.signal == .live }
    func tick(_ offset: TimeInterval) {
      model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + offset)
    }
    tick(CameraAppRecordingDemand.startDelay + 0.1)
    try emitUntil("Zoom's helper starts an automatic take") { state(first).status == .recording && !state(first).isStarting }
    try emitUntil("The automatic take writes video before the client disconnects") {
      (state(first).statistics?.encodedFrames ?? 0) > 0
    }
    XCTAssertTrue(state(first).startedByCameraApp)
    XCTAssertEqual(state(first).takeVideoMbps, 10)
    XCTAssertTrue([RecordingCodec.hevcMain, .hevcMain10].contains(state(first).takeCodec ?? .hevcMain10_422))
    model.setCameraDemandForTesting(first, requested: true, apps: ["com.example.viewer"])
    tick(1)
    XCTAssertEqual(state(first).status, .recording)
    tick(LiveWatchLimits.clientRelease + 1)
    try emitUntil("The unselected viewer cannot keep the take alive") { state(first).status == .idle }
    let zoomMovie = try XCTUnwrap(state(first).savedURL)
    XCTAssertEqual(zoomMovie.pathExtension, "mp4")
    XCTAssertEqual(zoomMovie.deletingLastPathComponent().lastPathComponent, "Zoom")
    XCTAssertTrue(zoomMovie.lastPathComponent.contains("Ultracam ("))
    model.recordingApps = ["com.example.viewer": "Viewer"]
    XCTAssertEqual(store.recordingApps, model.recordingApps)
    model.setProgramDemandForTesting(requested: true, apps: ["com.example.viewer"])
    try emitUntil("Both camera inputs are live for Program") { ids.allSatisfy { model.cameraUpdate($0)?.signal == .live } }
    recording.record(feedID: second)
    tick(CameraAppRecordingDemand.startDelay + 0.1)
    try emitUntil("Program rolls the armed sources") {
      ids.allSatisfy { state($0).status == .recording && !state($0).isStarting }
    }
    XCTAssertFalse(state(second).startedByCameraApp)
    model.recordingApps["com.example.other"] = "Other"
    model.setCameraDemandForTesting(first, requested: true, apps: ["com.example.other"])
    tick(CameraAppRecordingDemand.startDelay + 0.1)
    XCTAssertEqual(state(first).triggerAppID, "com.example.viewer")
    recording.stop(feedID: first)
    try emitUntil("Manual Stop closes the automatic take") { state(first).status == .idle }
    tick(10)
    XCTAssertEqual(state(first).status, .idle, "A manual stop lasts through the session")
    model.setProgramDemandForTesting(requested: false, apps: [])
    model.setCameraDemandForTesting(first, requested: false, apps: [])
    tick(LiveWatchLimits.clientRelease + 1)
    XCTAssertEqual(state(second).status, .recording)
    recording.stop(feedID: second)
    try emitUntil("Manual take closes") { state(second).status == .idle }
  }

  func testPerAppFolderWithoutManualFolderAndEmailFreeNaming() throws {
    try prepare(cameras: 1)
    defer { finish() }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var profile = AppRecordingProfile()
    try profile.chooseFolder(folder)
    let time = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-06T15:05:24Z"))
    let take = AppRecordingTake(appID: "us.zoom.xos", appName: "Zoom", profile: profile, started: time)
    let title = ZoomSessionTitle.topic(in: [("Zoom Meeting – Dharun Mohan (dharun@example.test)", true)])
    XCTAssertEqual(take.filename(camera: "Camera A", session: title, timeZone: TimeZone(secondsFromGMT: 0)!),
      "2026-11-06 15.05.24 Dharun Mohan - Ultracam (Camera A)")
    XCTAssertNil(ZoomSessionTitle.topic(in: [("Zoom Workplace", false), ("Zoom Meeting", true)]))
    XCTAssertEqual(take.filename(camera: "Camera A", session: "<dharun@example.test>", timeZone: TimeZone(secondsFromGMT: 0)!),
      "2026-11-06 15.05.24 Zoom Meeting - Ultracam (Camera A)")
    profile.videoMbps = 4
    profile.pattern = "{app} {camera} - synced"
    model.recordingProfiles["us.zoom.xos"] = profile
    let id = ids[0]
    let recording = model.recordingModel
    XCTAssertNil(recording.outputFolder(for: id))
    XCTAssertEqual(AppSettingsStore(defaults: defaults).recordingProfiles["us.zoom.xos"]?.videoMbps, 4)
    model.updateCamera(id) { $0.recordWithCameraApps = true }
    model.setCameraDemandForTesting(id, requested: true, apps: ["us.zoom.xos"])
    XCTAssertTrue(model.isCameraRunning(id))
    try emitUntil("Camera ready") { model.cameraUpdate(id)?.signal == .live }
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + 3)
    try emitUntil("Automatic take gets frames") { recording.feeds[0].isActive && !recording.feeds[0].isStarting }
    let pattern = try fixture.makePattern()
    for _ in 0..<8 {
      try fixture.emit(pattern, index: index)
      index += 1
      settle()
    }
    recording.stop(feedID: id)
    try emitUntil("Movie closed") { recording.feeds[0].status == .idle }
    let movie = try XCTUnwrap(recording.feeds[0].savedURL)
    XCTAssertEqual(movie.deletingLastPathComponent().resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    XCTAssertEqual(movie.lastPathComponent, "Zoom Camera 1 - synced.mp4")
  }

  func testCameraRecordingDemandRequiresContinuousIdentifiedUse() {
    var demand = CameraAppRecordingDemand()
    demand.update(true, now: 1)
    demand.update(false, now: 1.5)
    XCTAssertFalse(demand.shouldStart(at: 4))
    demand.update(true, now: 4)
    XCTAssertFalse(demand.shouldStart(at: 5))
    XCTAssertTrue(demand.shouldStart(at: 6))
    demand.update(nil, now: 7)
    XCTAssertFalse(demand.shouldStart(at: 20))
    XCTAssertTrue(demand.keepsSession(at: 20))
    demand.update(false, now: 21)
    XCTAssertFalse(demand.keepsSession(at: 26))
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

/// Records trigger requests without opening a writer.
@MainActor private final class TestCaptureAuthorization {
  var status = CaptureAuthorizationStatus.requestable
  var refreshCount = 0
  private(set) var requests: [String?] = []
  private var continuations: [CheckedContinuation<Void, Error>] = []

  func request(deviceID: String?) async throws {
    requests.append(deviceID)
    try await withCheckedThrowingContinuation { continuations.append($0) }
  }

  func grant() {
    guard !continuations.isEmpty else { XCTFail("No pending authorization request"); return }
    status = .authorized
    continuations.removeFirst().resume()
  }

  func deny() {
    guard !continuations.isEmpty else { XCTFail("No pending authorization request"); return }
    let error = PluginError.unavailable("Allow Camera in Privacy & Security.")
    status = .unavailable(error)
    continuations.removeFirst().resume(throwing: error)
  }
}

private final class DemandRecordingDriver: RecordingSessionDriver {
  var started: [FeedID] = []
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws { started.append(feedID) }
  func pauseRecording(feedID: FeedID) throws {}
  func resumeRecording(feedID: FeedID) throws {}
  func stopRecording(feedID: FeedID) throws {}
}

@MainActor private final class DemandRegistryPublisher: AppVirtualCameraRegistryPublishing {
  private(set) var published = 0
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) { published += 1 }
}
#endif
