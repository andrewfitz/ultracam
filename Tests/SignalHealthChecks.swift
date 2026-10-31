import Foundation
import XCTest

/// The clocks behind failover, and how a loss and its way out are shown.
@objcMembers final class SignalHealthChecks: XCTestCase {
  private let id = FeedID(rawValue: "camera-1")

  func testLossCountsFromWhenFramesStopped() {
    var tracker = SignalHealthTracker()
    tracker.note(id, signal: .lost(since: 100), now: 100.9)
    XCTAssertTrue(tracker.isWithinLossHold(id))
    XCTAssertEqual(tracker.tick(now: 100.9), [])
    XCTAssertEqual(tracker.tick(now: 101), [.unhealthy(id)])
    XCTAssertEqual(tracker.tick(now: 102), [], "Once")
    XCTAssertFalse(tracker.isWithinLossHold(id))
    XCTAssertTrue(tracker.isUnhealthy(id))
  }

  func testAReportOfTheSameLossDoesNotRestartIt() {
    var tracker = SignalHealthTracker()
    tracker.note(id, signal: .lost(since: 100), now: 100)
    tracker.note(id, signal: .lost(since: 100.8), now: 100.8)
    XCTAssertEqual(tracker.tick(now: 101), [.unhealthy(id)])
  }

  func testReturnNeedsSteadySignal() {
    var tracker = SignalHealthTracker()
    tracker.note(id, signal: .lost(since: 0), now: 0)
    _ = tracker.tick(now: 1)
    tracker.note(id, signal: .live, now: 10)
    XCTAssertEqual(tracker.secondsUntilEligible(id, now: 12), 3)
    XCTAssertEqual(tracker.tick(now: 14.9), [])
    tracker.note(id, signal: .lost(since: 14.9), now: 14.9)
    XCTAssertNil(tracker.secondsUntilEligible(id, now: 15), "Lost again: nothing is being watched")
    tracker.note(id, signal: .live, now: 15)
    XCTAssertEqual(tracker.tick(now: 19.9), [])
    XCTAssertEqual(tracker.tick(now: 20), [.eligible(id)])
    XCTAssertFalse(tracker.isUnhealthy(id))
  }

  func testUnsupportedIsNoPictureFromWhenItWasSeen() {
    var tracker = SignalHealthTracker()
    tracker.note(id, signal: .unsupported("1080i"), now: 50)
    XCTAssertEqual(tracker.tick(now: 51), [.unhealthy(id)])
  }

  func testStoppingForgetsIt() {
    var tracker = SignalHealthTracker()
    tracker.note(id, signal: .lost(since: 0), now: 0)
    tracker.remove(id)
    XCTAssertEqual(tracker.tick(now: 9), [])
  }

  func testNextLiveWrapsAndSkipsTheDead() {
    let (a, b, c) = (FeedID(rawValue: "a"), FeedID(rawValue: "b"), FeedID(rawValue: "c"))
    XCTAssertEqual(ProgramFailover.nextLive(after: b, order: [a, b, c]) { _ in true }, c)
    XCTAssertEqual(ProgramFailover.nextLive(after: c, order: [a, b, c]) { _ in true }, a)
    XCTAssertEqual(ProgramFailover.nextLive(after: a, order: [a, b, c]) { $0 == c }, c)
    XCTAssertNil(ProgramFailover.nextLive(after: a, order: [a, b, c]) { _ in false })
    XCTAssertEqual(ProgramFailover.nextLive(after: FeedID(rawValue: "gone"), order: [a, b]) { $0 == b }, b)
  }

  // MARK: Showing it

  private func camera(_ index: Int, signal: UISignal = .live(format: "2160p 59.94"), lost: TimeInterval? = nil,
    recording: UIRecordingStatus = .idle) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-\(index)", name: "Camera \(index)")
    camera.running = true
    camera.signal = signal
    camera.signalLostFor = lost
    camera.recording.status = recording
    camera.recording.folderPath = "/Volumes/8TB/Takes"
    return camera
  }

  private func program(_ cameras: [UICameraSnapshot], auto: Bool = false) -> UISessionSnapshot {
    var session = UISessionSnapshot()
    session.outputMode = .program
    session.cameras = cameras
    session.onAirID = cameras.first?.id
    session.programInUse = true
    session.programSinkConnected = true
    session.autoSwitching = auto
    session.strategy = auto ? .fixedInterval : .manual
    return session
  }

  private func presented(_ session: UISessionSnapshot, _ index: Int = 0) -> UICameraPresentation {
    UIPresentationBuilder.camera(session.cameras[index], index: index, in: session)
  }

  func testLostOnAirIsOrangeWithALargeCutAndACountdown() throws {
    let session = program([camera(1, signal: .noSignal, lost: 3.2, recording: .recording), camera(2)])
    let shown = presented(session)
    XCTAssertEqual(shown.tally, .noPicture)
    XCTAssertEqual(UITally.noPicture.badge, "NO PICTURE")
    XCTAssertFalse(UITally.noPicture.isRed, "Red stays reserved for frames arriving")
    XCTAssertEqual(shown.tileState, .signalLost)
    XCTAssertEqual(shown.lostTitle, "Signal lost 0:03")
    XCTAssertEqual(shown.lostDetail, "Take ends in 7 s")
    XCTAssertEqual(shown.lostCut?.id, "camera-2")
    XCTAssertEqual(shown.lostCut?.number, 2)
    let problem = try XCTUnwrap(UIPresentationBuilder.problems(session).first)
    XCTAssertEqual(problem.title, "Camera 1 signal lost 0:03")
    XCTAssertEqual(problem.detail, "Take ends in 7 s")
    XCTAssertEqual(problem.action, UIProblemAction(title: "Cut to Camera 2", action: .cut(cameraID: "camera-2")))
    XCTAssertEqual(problem.level, .damage)
    XCTAssertEqual(problem.alert?.showsPanel, true)
  }

  func testCountdownCountsAndNeverAsksAnyoneToSubtract() {
    func detail(_ lost: TimeInterval) -> String? {
      UIPresentationBuilder.takeCountdown(camera(1, signal: .noSignal, lost: lost, recording: .recording))
    }
    XCTAssertEqual(detail(6), "Take ends in 4 s")
    XCTAssertEqual(detail(9.1), "Take ends in 1 s")
    XCTAssertEqual(detail(10), "Take ends when the signal returns", "The epoch changes on the next frame, not at 10 s")
    XCTAssertEqual(detail(40), "Take ends when the signal returns")
    XCTAssertNil(UIPresentationBuilder.takeCountdown(camera(1, signal: .noSignal, lost: 6)), "Nothing rolling")
  }

  func testLosingFramesReplacesTheGreenTick() {
    let shown = presented(program([camera(1, signal: .noSignal, lost: 2, recording: .recording), camera(2)]))
    XCTAssertEqual(shown.dropsLine, "Losing frames")
    XCTAssertTrue(shown.dropsWarning)
  }

  func testAutoOnHasNoCutOnThePicture() {
    XCTAssertNil(presented(program([camera(1, signal: .noSignal, lost: 2), camera(2)], auto: true)).lostCut)
  }

  func testNothingLiveStaysAndSaysSo() throws {
    let session = program([camera(1, signal: .noSignal, lost: 3, recording: .recording), camera(2, signal: .noSignal)])
    let shown = presented(session)
    XCTAssertEqual(shown.lostDetail, "No camera has a picture. Take ends in 7 s")
    XCTAssertNil(shown.lostCut)
    XCTAssertEqual(UIPresentationBuilder.problems(session).first?.title, "No camera has a picture")
  }

  func testNeverHadAPictureIsNotALoss() {
    let shown = presented(program([camera(1, signal: .noSignal), camera(2)]))
    XCTAssertEqual(shown.tileState, .noSignal, "Setup advice, not a clock")
    XCTAssertNil(shown.lostTitle)
    XCTAssertEqual(shown.tally, .noPicture, "It's still no picture on air")
  }

  func testCutSaysWhyItIsOff() {
    var back = camera(2)
    back.cutBlockedFor = 3.2
    var session = program([camera(1), back])
    var shown = presented(session, 1)
    XCTAssertFalse(shown.cutEnabled)
    XCTAssertEqual(shown.cutHelp, "Camera 2's signal just came back. It can take a cut after 4 s more of steady signal.")
    session.cameras[1] = camera(2, signal: .noSignal)
    shown = presented(session, 1)
    XCTAssertEqual(shown.cutHelp, "Camera 2 needs a live signal before it can go on air.")
    session.cameras[1] = camera(2)
    shown = presented(session, 1)
    XCTAssertTrue(shown.cutEnabled)
    XCTAssertNil(shown.cutHelp)
  }

  func testARecoveringCameraIsNotACutTarget() {
    var back = camera(2)
    back.cutBlockedFor = 3
    let shown = presented(program([camera(1, signal: .noSignal, lost: 2), back]))
    XCTAssertNil(shown.lostCut)
  }

  func testMoveIsToldAndNamesHold() throws {
    var session = program([camera(2), camera(1, signal: .noSignal, lost: 2)])
    session.programMoved = UIProgramMove(from: "Camera 1", to: "Camera 2", heldShot: true)
    let problem = try XCTUnwrap(UIPresentationBuilder.problems(session).first { $0.id == "program.moved" })
    XCTAssertEqual(problem.title, "Camera 1 signal lost")
    XCTAssertEqual(problem.detail, "Program moved to Camera 2. Hold stays on.")
    XCTAssertEqual(problem.alert?.body, "Program moved to Camera 2")
    XCTAssertEqual(problem.action?.action, .acknowledgeProgramMove)
  }

  @MainActor func testLabelsReadTheLossHold() {
    var update = CaptureUpdate(message: "")
    update.signal = .lost(since: 1)
    update.input = "1920 × 1080 · v210 · 59.94 fps"
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update, withinLossHold: true),
      .live(format: "1080p 59.94"), "A dropout too short to count keeps the tally steady")
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update), .noSignal)
    var camera = UICameraSnapshot(id: "a", name: "A")
    camera.running = true
    update.frames = 9
    UISessionBridge.applyCapture(update, withinLossHold: true, to: &camera)
    XCTAssertNil(camera.signalLostFor)
    UISessionBridge.applyCapture(update, to: &camera)
    XCTAssertNotNil(camera.signalLostFor)
    update.frames = 0
    UISessionBridge.applyCapture(update, to: &camera)
    XCTAssertNil(camera.signalLostFor, "Only a camera that had a picture has lost one")
  }
}
