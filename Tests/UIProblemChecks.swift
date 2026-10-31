import Foundation
import XCTest

/// One problem list: worst first, one action each, two levels, the same list everywhere.
/// The strip's row never changes the strip's height, so a problem never moves Cut.
@objcMembers final class UIProblemChecks: XCTestCase {
  private func camera(_ index: Int, running: Bool = true, signal: UISignal = .live(format: "2160p 59.94"),
    recording: UIRecordingStatus = .idle) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-\(index)", name: "Camera \(index)")
    camera.running = running
    camera.signal = running ? signal : .none
    camera.recording.status = recording
    camera.recording.folderPath = "/Volumes/8TB/Takes"
    return camera
  }

  private func program(_ cameras: [UICameraSnapshot], auto: Bool = false, client: Bool = true) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.cameras = cameras
    session.onAirID = cameras.first?.id
    session.programInUse = client
    session.programSinkConnected = client
    session.autoSwitching = auto
    session.strategy = auto ? .naturalTalkingHead : .manual
    return session
  }

  private func separate(_ cameras: [UICameraSnapshot]) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.cameras = cameras
    return session
  }

  private func problems(_ session: UISessionSnapshot) -> [UIProblem] { UIPresentationBuilder.problems(session) }

  func testHealthySessionHasNoProblems() {
    XCTAssertTrue(problems(program([camera(1), camera(2)])).isEmpty)
    XCTAssertTrue(problems(separate([camera(1)])).isEmpty)
    XCTAssertEqual(UIPresentationBuilder.session(separate([camera(1)])).menuBarIcon, .live)
  }

  func testListIsWorstFirstAndEveryRowHasOneAction() {
    var stalled = camera(2, signal: .noSignal, recording: .recording)
    stalled.queueStalled = true
    var lut = camera(3)
    lut.lutError = "Saved LUT could not be restored: the file was moved."
    var waiting = camera(4)
    waiting.clientWaiting = true
    var session = program([camera(1, signal: .noSignal), stalled, lut, waiting])
    session.drives = [UIDrive(name: "8TB", availableBytes: 100, totalBytes: 1000, secondsLeft: 600)]
    let list = problems(session)
    XCTAssertEqual(list.first?.title, "Camera 1 on air: no signal", "What the meeting sees comes first")
    XCTAssertEqual(list.map(\.id), ["onair.camera-1", "signal.camera-2", "stall.camera-2", "waiting.camera-4", "drive.8TB", "lut.camera-3"])
    XCTAssertTrue(list.allSatisfy { $0.action != nil }, "\(list.filter { $0.action == nil })")
  }

  func testTwoLevels() {
    let rolling = problems(separate([camera(1, signal: .noSignal, recording: .recording)]))
    XCTAssertEqual(rolling.map(\.level), [.damage], "Rolling damage")
    XCTAssertEqual(problems(separate([camera(1, signal: .noSignal)])).map(\.level), [.notice], "Nothing on air or rolling")
    XCTAssertEqual(problems(program([camera(1, signal: .noSignal), camera(2)])).map(\.level), [.damage], "On-air damage")
    var drive = separate([camera(1, recording: .recording)])
    drive.drives = [UIDrive(name: "8TB", availableBytes: 100, totalBytes: 1000, secondsLeft: 600)]
    XCTAssertEqual(problems(drive).map(\.level), [.damage], "A low drive under a rolling take")
    drive.cameras = [camera(1)]
    XCTAssertEqual(problems(drive).map(\.level), [.notice], "A low drive with nothing rolling")
  }

  func testDriveActionNamesWhatItDoes() {
    var session = separate([camera(1, recording: .recording)])
    session.drives = [UIDrive(name: "8TB", availableBytes: 100, totalBytes: 1000, secondsLeft: 600)]
    XCTAssertEqual(problems(session).first?.action?.title, "Folder for Next Take…")
    XCTAssertEqual(problems(session).first?.detail, "Camera 1 records here.")
    session.cameras = [camera(1)]
    XCTAssertEqual(problems(session).first?.action?.title, "Change…")
    session.drives[0].availableBytes = 0
    session.drives[0].secondsLeft = nil
    XCTAssertEqual(problems(session).first?.title, "8TB is full")
  }

  func testStatusBarLeadsWithTheWorstProblemAndItsAction() {
    var session = separate([camera(1, signal: .noSignal), camera(2, signal: .unsupported("x"))])
    let bar = UIPresentationBuilder.session(session)
    XCTAssertEqual(bar.statusSegments.first?.kind, .warning)
    XCTAssertEqual(bar.statusSegments.first?.text, "Camera 1: no signal  +1")
    XCTAssertEqual(bar.statusSegments.first?.action?.title, "Details")
    XCTAssertEqual(bar.statusSegments.first?.level, .notice)
    XCTAssertEqual(bar.problems.count, 2, "The bar, Attention and the menu bar render one list")
    session.cameras = [camera(1)]
    XCTAssertFalse(UIPresentationBuilder.session(session).statusSegments.contains { $0.kind == .warning })
  }

  func testOneCameraProblemStillReachesTheBar() {
    let bar = UIPresentationBuilder.session(separate([camera(1, signal: .noSignal)]))
    XCTAssertEqual(bar.statusSegments.first?.text, "Camera 1: no signal", "One list everywhere, one camera or several")
    XCTAssertEqual(bar.menuBarIcon, .attention)
  }

  func testStripRowShowsWhatToDoAndCountsWhenThereIsMore() throws {
    var one = camera(2, signal: .noSignal, recording: .recording)
    var strip = try XCTUnwrap(UIPresentationBuilder.stripProblem(one, in: separate([one])))
    XCTAssertEqual(strip.text, "Check Camera 2's HDMI", "The picture says what happened, the strip what to do")
    XCTAssertEqual(strip.level, .damage)
    XCTAssertEqual(strip.count, 1)
    one.lutError = "gone"
    strip = try XCTUnwrap(UIPresentationBuilder.stripProblem(one, in: separate([one])))
    XCTAssertEqual(strip.count, 2)
    XCTAssertNil(UIPresentationBuilder.stripProblem(camera(1), in: separate([camera(1)])))
  }

  func testTakeProblemsStayOnTheRecordRow() {
    var failed = camera(1)
    failed.recording.failed = true
    XCTAssertEqual(problems(separate([failed])).first?.title, "Take ended early")
    XCTAssertNil(UIPresentationBuilder.stripProblem(failed, in: separate([failed])),
      "The record row says it, so the folder row stays")
  }

  func testWaitingClientAsksForARestart() {
    var waiting = camera(1)
    waiting.clientWaiting = true
    let problem = problems(separate([waiting])).first
    XCTAssertEqual(problem?.title, "A meeting app is waiting for Camera 1")
    XCTAssertEqual(problem?.detail, "It's connected, but no frames are reaching it.")
    XCTAssertEqual(problem?.action, UIProblemAction(title: "Restart Camera", action: .restartCamera(cameraID: "camera-1")))
    var stopped = camera(1, running: false)
    stopped.clientWaiting = true
    XCTAssertEqual(problems(separate([stopped])).first?.action, UIProblemAction(title: "Start", action: .startCamera(cameraID: "camera-1")))
  }

  func testConnectFailureOnlyWithAClientOrUnknown() {
    var failing = camera(1)
    failing.sinkFailure = "The camera extension isn't running."
    XCTAssertTrue(problems(separate([failing])).isEmpty, "No client, so nobody is affected")
    failing.clientUnknown = true
    XCTAssertEqual(problems(separate([failing])).first?.title, "Camera 1 isn't reaching meeting apps")
    XCTAssertEqual(problems(separate([failing])).first?.detail, "The camera extension isn't running.")
    failing.clientUnknown = false
    failing.clientWaiting = true
    XCTAssertEqual(problems(separate([failing])).map(\.id), ["waiting.camera-1"], "A waiting client says it once")
  }

  func testAWaitingClientSaysWhyItsConnectFailed() {
    var failing = camera(1)
    failing.clientWaiting = true
    failing.sinkFailure = "Install and enable the Ultracam camera extension."
    var session = separate([failing])
    XCTAssertEqual(problems(session).first?.detail, "Install and enable the Ultracam camera extension.")
    session.install.installed = false
    session.install.system = ExtensionSystemState(records: [ExtensionSystemRecord(bundleVersion: "10", enabled: true,
      awaitingApproval: false, uninstalling: false)], bundledVersion: "10")
    XCTAssertEqual(problems(session).first?.detail, "Restart your Mac to finish installing the camera extension.",
      "Enabled and publishing nothing: installing again wouldn't help")
  }

  func testAppProblemsReachTheListAndAcknowledge() {
    var session = separate([camera(1)])
    session.appProblems = [UIAppProblem(id: "director", text: "Auto director: lost")]
    let problem = problems(session).first
    XCTAssertEqual(problem?.title, "Auto director: lost")
    XCTAssertEqual(problem?.action?.action, .acknowledgeProblem(id: "director"))
  }

  func testStillRecordingNamesTheTakes() {
    var session = separate([camera(1, recording: .recording), camera(2, recording: .recording)])
    session.unusedTake = true
    let problem = problems(session).first
    XCTAssertEqual(problem?.title, "Still recording: no meeting app is using Ultracam")
    XCTAssertEqual(problem?.action?.title, "Stop 2 Recordings")
    XCTAssertEqual(problem?.level, .notice, "It never stops the take, and nothing is damaged")
  }

  func testCutsNotReachingAClient() {
    var iso = camera(2)
    iso.inUse = true
    var session = program([camera(1), iso], client: false)
    XCTAssertTrue(problems(session).isEmpty, "No cut yet")
    session.cutsMissClient = true
    XCTAssertEqual(problems(session).first?.title, "Meeting app is on Camera 2, not Program")
    XCTAssertEqual(problems(session).first?.detail, "Cuts aren't reaching it. Choose Program in that app.")
  }

  /// Text that can land on a shared display: camera names and state, nothing else.
  func testAlertTextIsMeetingSafe() {
    var failed = camera(1)
    failed.recording.failed = true
    failed.recording.savedDuration = 1138
    failed.recording.folderPath = "/Volumes/Secret Client/Takes"
    var session = separate([failed])
    session.drives = [UIDrive(name: "Secret Client", availableBytes: 100, totalBytes: 1000, secondsLeft: 600)]
    for problem in problems(session) {
      let alert = problem.alert
      XCTAssertNotNil(alert)
      XCTAssertFalse((alert?.title ?? "").contains("Secret"), "\(problem.id)")
      XCTAssertFalse((alert?.body ?? "").contains("Secret"), "\(problem.id)")
    }
  }
}
