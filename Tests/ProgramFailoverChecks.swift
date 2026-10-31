#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

/// On-air loss, for every strategy: AppModel's one rule, on its own clock, with the real
/// switcher and fake capture. No frames arrive during a loss, so nothing here needs any.
@MainActor @objcMembers final class ProgramFailoverChecks: XCTestCase {
  private var fixture: AppHardwareSyntheticFixture!
  private var model: AppModel!
  private var ids: [FeedID] = []

  private func prepare() throws {
    let fixture = try AppHardwareSyntheticFixture(deviceIDs: ["fake:one", "fake:two", "fake:three"])
    self.fixture = fixture
    fixture.connect()
    let suite = "org.ultracam.tests.failover.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: FailoverRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      hardware: fixture.hardware)
    model.refresh()
    _ = model.addFeed()
    _ = model.addFeed()
    ids = model.feedDescriptors.map(\.id)
    for (id, device) in zip(ids, ["fake:one", "fake:two", "fake:three"]) {
      model.updateCamera(id, shareProcessing: false) { $0.selectedDevice = device }
    }
    model.startAllCameras()
    XCTAssertEqual(ids.filter(model.isCameraRunning).count, 3)
  }

  /// R6. Closing here would turn the next cut into a reopen under the client's lease, and
  /// a cut that fires no event used to leave Program black for good.
  func testProgramSinkOutlivesItsOnAirCameraAndACutFromThereReachesTheClient() throws {
    try prepare()
    defer { finish() }
    allLive()
    model.setProgramDemandForTesting(requested: true)
    spin("A client opens the sink") { fixture.programSink.openConnections == 1 }
    let onAir = try XCTUnwrap(model.switcherSelectedFeedID)
    model.stopCamera(onAir)
    settle()
    XCTAssertEqual(fixture.programSink.openConnections, 1, "Standby black, and the format stays locked")
    let next = try XCTUnwrap(ids.first { $0 != onAir })
    _ = model.requestProgramCut(to: next)
    settle()
    XCTAssertEqual(model.switcherSelectedFeedID, next, "Nothing on air, so it's at once")
    XCTAssertEqual(fixture.programSink.openConnections, 1)
    XCTAssertEqual(fixture.programSink.connectAttempts, 1, "No reopen")
    model.stopAllCameras()
    spin("With nothing running the sink closes") { fixture.programSink.openConnections == 0 }
  }

  func testAFailedProgramConnectRetriesEverySecondWhileItsClientWaits() throws {
    try prepare()
    defer { finish() }
    fixture.programSink.failNextConnects(1000)
    model.setProgramDemandForTesting(requested: true)
    spin("The first try fails and says so") { model.appProblems.contains { $0.id == "program-connect" } }
    let start = now + 1000
    let first = fixture.programSink.connectAttempts
    model.liveWatchTick(now: start)
    spin("It tries again") { fixture.programSink.connectAttempts == first + 1 }
    spin("Which fails too") { model.appProblems.contains { $0.id == "program-connect" } }
    model.liveWatchTick(now: start + 0.5)
    settle()
    XCTAssertEqual(fixture.programSink.connectAttempts, first + 1, "Once a second")
    fixture.programSink.failNextConnects(0)
    model.liveWatchTick(now: start + LiveWatchLimits.connectRetry)
    spin("Then connects") { fixture.programSink.openConnections == 1 }
    spin("And clears the problem") { !model.appProblems.contains { $0.id == "program-connect" } }
  }

  private func spin(_ what: String, _ done: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 10)
    while !done() {
      guard Date() < deadline else { XCTFail(what); return }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
  }

  private func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }

  private func finish() {
    model.stopAllCameras()
    fixture.stop()
    model = nil
    fixture = nil
  }

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func signal(_ id: FeedID, _ signal: CaptureSignal) {
    var update = CaptureUpdate(message: "")
    update.signal = signal
    update.frames = 10
    update.input = "1920 × 1080 · v210 · 59.94 fps"
    model.deliverCaptureUpdateForTesting(id, update)
  }

  private func allLive() { ids.forEach { signal($0, .live) } }

  private func auto(_ on: Bool, hold: Bool = false) {
    var settings = model.switcherSettings
    settings.strategy = .fixedInterval
    settings.automatic = on
    model.updateSwitcher(settings)
    if hold { model.setAutoHold(true) }
  }

  /// Where Program is, or is about to be.
  private var program: FeedID? { model.switcherPendingFeedID ?? model.switcherSelectedFeedID }

  private func onAirFirst() -> FeedID {
    _ = model.selectFeed(ids[0])
    let onAir = model.switcherSelectedFeedID ?? ids[0]
    XCTAssertEqual(onAir, ids[0])
    return onAir
  }

  func testADropoutInsideTheHoldDoesNothing() throws {
    try prepare()
    defer { finish() }
    auto(true)
    let id = onAirFirst()
    allLive()
    let start = now
    signal(id, .lost(since: start))
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold - 0.1)
    XCTAssertTrue(model.signalWithinLossHold(id), "Every surface keeps calling this live")
    signal(id, .live)
    model.liveWatchTick(now: start + 5)
    XCTAssertEqual(program, id)
    XCTAssertFalse(model.isSignalUnhealthy(id))
    XCTAssertNil(model.programMoved)
  }

  func testAutoCutsToTheNextLiveCameraInStripOrder() throws {
    try prepare()
    defer { finish() }
    auto(true)
    let id = onAirFirst()
    allLive()
    model.stripOrder = { [ids] _ in [ids[0], ids[2], ids[1]] }
    let start = now
    signal(id, .lost(since: start))
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    XCTAssertEqual(program, ids[2], "Next in the strip, not next in the settings")
    XCTAssertTrue(model.isSignalUnhealthy(id))
    XCTAssertEqual(model.programMoved?.from, model.descriptor(for: id)?.name)
    XCTAssertEqual(model.programMoved?.to, model.descriptor(for: ids[2])?.name)
    XCTAssertEqual(model.programMoved?.heldShot, false)
  }

  func testNoLiveCameraStays() throws {
    try prepare()
    defer { finish() }
    auto(true)
    let id = onAirFirst()
    allLive()
    let start = now
    for other in ids { signal(other, .lost(since: start)) }
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    XCTAssertEqual(program, id, "Nowhere to go")
    XCTAssertNil(model.programMoved)
  }

  func testACameraInsideItsOwnHoldIsNotATarget() throws {
    try prepare()
    defer { finish() }
    auto(true)
    let id = onAirFirst()
    allLive()
    let start = now
    signal(id, .lost(since: start))
    signal(ids[1], .lost(since: start + 0.9))
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    XCTAssertEqual(program, ids[2], "Both cameras drop together on this rig")
  }

  func testAutoOffCutsNothing() throws {
    try prepare()
    defer { finish() }
    auto(false)
    let id = onAirFirst()
    allLive()
    let start = now
    signal(id, .lost(since: start))
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    XCTAssertEqual(program, id)
    XCTAssertTrue(model.isSignalUnhealthy(id), "Marked anyway, so nothing cuts back to it")
    XCTAssertNil(model.programMoved)
  }

  func testLossOverridesHoldOnceAndHoldStaysOn() throws {
    try prepare()
    defer { finish() }
    auto(true, hold: true)
    let id = onAirFirst()
    allLive()
    let start = now
    signal(id, .lost(since: start))
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    XCTAssertEqual(program, ids[1])
    XCTAssertEqual(model.programMoved?.heldShot, true, "You're told")
    XCTAssertTrue(model.switcherSettings.naturalTalkingHead.manualHold, "Hold stays on for the new shot")
  }

  func testUnhealthyRefusesManualCutsUntilSteadyForFiveSeconds() throws {
    try prepare()
    defer { finish() }
    auto(false)
    let id = ids[1]
    _ = onAirFirst()
    allLive()
    let start = now
    signal(id, .lost(since: start))
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    if case .rejectedMissingSource = model.requestProgramCut(to: id) {} else { XCTFail("A lost camera can't take a cut") }

    // Back, then flapping: only an unbroken 5 s counts.
    signal(id, .live)
    let back = now
    XCTAssertNotNil(model.cutBlockedFor(id))
    model.liveWatchTick(now: back + SignalHealthTracker.returnHold - 1)
    XCTAssertTrue(model.isSignalUnhealthy(id))
    signal(id, .lost(since: back + 4))
    signal(id, .live)
    let again = now
    model.liveWatchTick(now: again + SignalHealthTracker.returnHold - 1)
    XCTAssertTrue(model.isSignalUnhealthy(id), "The flap started the 5 s over")
    model.liveWatchTick(now: again + SignalHealthTracker.returnHold + 0.1)
    XCTAssertFalse(model.isSignalUnhealthy(id))
    XCTAssertNil(model.cutBlockedFor(id))
    if case .rejectedMissingSource = model.requestProgramCut(to: id) { XCTFail("Eligible again") }
  }

  func testNothingCutsBackByItself() throws {
    try prepare()
    defer { finish() }
    auto(true)
    let id = onAirFirst()
    allLive()
    let start = now
    signal(id, .lost(since: start))
    model.liveWatchTick(now: start + SignalHealthTracker.lossHold)
    let moved = program
    signal(id, .live)
    let back = now
    model.liveWatchTick(now: back + SignalHealthTracker.returnHold + 0.1)
    XCTAssertEqual(program, moved)
    XCTAssertNil(model.programMoved, "The camera is back, so the notice has served")
  }

  func testAFailedOnAirCameraDoesNotWaitOutTheHold() throws {
    try prepare()
    defer { finish() }
    auto(true)
    let id = onAirFirst()
    allLive()
    var update = CaptureUpdate(message: "The capture device stopped responding.")
    update.stopped = true
    update.stopCause = .failed("The capture device stopped responding.")
    model.deliverCaptureUpdateForTesting(id, update)
    XCTAssertEqual(program, ids[1])
  }
}

private final class FailoverRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
