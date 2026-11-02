#if ULTRACAM_TEST_SUPPORT
import AppKit
import SwiftUI
import Foundation
import UserNotifications
import XCTest

/// What leaves the window. The real notification center never runs here: harnesses have no
/// bundle, so the coordinator is driven through fakes, on a real AppModel.
@MainActor @objcMembers final class UIAlertChecks: XCTestCase {
  private func problem(_ id: String, alert: UIProblemAlert?, action: UIProblemAction? = nil) -> [UIProblem] {
    var camera = UICameraSnapshot(id: id, name: id)
    camera.unexpectedStop = UIUnexpectedStop(reason: "x", wasOnAir: alert?.showsPanel == true)
    var session = UISessionSnapshot()
    session.cameras = [camera]
    return UIPresentationBuilder.problems(session)
  }

  func testEachProblemPostsOnceAndClears() {
    var tracker = UIAlertTracker()
    let problems = problem("Camera 1", alert: nil)
    var plan = tracker.plan(problems: problems, live: false, notifications: true, panel: true, sound: false, timeSensitiveEntitled: false)
    XCTAssertEqual(plan.post.count, 1)
    XCTAssertEqual(plan.post.first?.title, "Camera 1 stopped")
    XCTAssertEqual(plan.post.first?.sound, false, "Sound is off by default")
    XCTAssertEqual(plan.post.first?.timeSensitive, false)
    plan = tracker.plan(problems: problems, live: false, notifications: true, panel: true, sound: false, timeSensitiveEntitled: false)
    XCTAssertTrue(plan.post.isEmpty, "Still the same problem")
    plan = tracker.plan(problems: [], live: false, notifications: true, panel: true, sound: false, timeSensitiveEntitled: false)
    XCTAssertEqual(plan.remove, ["incident.Camera 1"], "A cleared problem takes its notification back")
  }

  func testTimeSensitiveNeedsTheEntitlementAndALiveSession() {
    func level(live: Bool, entitled: Bool) -> Bool? {
      var tracker = UIAlertTracker()
      return tracker.plan(problems: problem("A", alert: nil), live: live, notifications: true, panel: false,
        sound: false, timeSensitiveEntitled: entitled).post.first?.timeSensitive
    }
    XCTAssertEqual(level(live: true, entitled: true), true)
    XCTAssertEqual(level(live: false, entitled: true), false)
    XCTAssertEqual(level(live: true, entitled: false), false)
    XCTAssertFalse(UIAlertPreferences.timeSensitiveEntitled, "Not until the profile carries the capability")
  }

  func testPanelOnlyForTheWorstAndOffSwitchesHold() {
    var tracker = UIAlertTracker()
    var camera = UICameraSnapshot(id: "a", name: "Camera 1")
    camera.unexpectedStop = UIUnexpectedStop(reason: "x", wasOnAir: true)
    var session = UISessionSnapshot()
    session.cameras = [camera]
    let onAir = UIPresentationBuilder.problems(session)
    XCTAssertEqual(tracker.plan(problems: onAir, live: false, notifications: true, panel: true, sound: false,
      timeSensitiveEntitled: false).panel?.title, "Camera 1 stopped")
    var off = UIAlertTracker()
    let plan = off.plan(problems: onAir, live: false, notifications: false, panel: false, sound: false, timeSensitiveEntitled: false)
    XCTAssertTrue(plan.post.isEmpty)
    XCTAssertNil(plan.panel)
    session.cameras[0].unexpectedStop = UIUnexpectedStop(reason: "x", wasOnAir: false)
    var quiet = UIAlertTracker()
    XCTAssertNil(quiet.plan(problems: UIPresentationBuilder.problems(session), live: false, notifications: true, panel: true,
      sound: false, timeSensitiveEntitled: false).panel, "Stopped off air notifies, without the panel")
  }

  func testLossAndItsCutAreOneNotification() {
    var tracker = UIAlertTracker()
    var lost = UICameraSnapshot(id: "a", name: "Camera 1")
    lost.running = true
    lost.signal = .noSignal
    var other = UICameraSnapshot(id: "b", name: "Camera 2")
    other.running = true
    other.signal = .live(format: "2160p")
    var session = UISessionSnapshot()
    session.cameras = [lost, other]
    session.onAirID = "a"
    session.programInUse = true
    let first = tracker.plan(problems: UIPresentationBuilder.problems(session), live: true, notifications: true, panel: true,
      sound: false, timeSensitiveEntitled: false)
    XCTAssertEqual(first.post.map(\.id), ["onair.Camera 1"])
    session.programMoved = UIProgramMove(from: "Camera 1", to: "Camera 2")
    session.onAirID = "b"
    let second = tracker.plan(problems: UIPresentationBuilder.problems(session), live: true, notifications: true, panel: true,
      sound: false, timeSensitiveEntitled: false)
    XCTAssertTrue(second.post.isEmpty, "The cut is the same event")
    XCTAssertEqual(second.panel?.body, "Program moved to Camera 2", "The panel keeps up")
  }

  func testPreferenceDefaultsAndPersistence() {
    let suite = "org.ultracam.tests.alerts.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let preferences = UIAlertPreferences(defaults: defaults)
    XCTAssertTrue(preferences.notificationsEnabled)
    XCTAssertTrue(preferences.panelEnabled)
    XCTAssertFalse(preferences.soundEnabled, "Sound off by default")
    preferences.soundEnabled = true
    preferences.panelEnabled = false
    let again = UIAlertPreferences(defaults: defaults)
    XCTAssertTrue(again.soundEnabled)
    XCTAssertFalse(again.panelEnabled)
    XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("ui.alerts.") }.count, 2,
      "ui.* keys go with Reset All Settings")
  }

  func testForegroundPresentation() {
    XCTAssertEqual(UIUserNotifications.presentation(mainWindowKey: true), [.list], "Attention already shows it")
    XCTAssertEqual(UIUserNotifications.presentation(mainWindowKey: false), [.banner, .list])
  }

  /// Created, inspected, never ordered in: test windows stay invisible.
  func testPanelCannotActivateOrLeaveTheFullScreenMeeting() {
    let panel = UIAlertPanelController.makePanel()
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
    XCTAssertTrue(panel.isFloatingPanel)
    XCTAssertEqual(panel.level, .screenSaver)
    XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary])
    XCTAssertEqual(panel.sharingType, .none)
    XCTAssertFalse(panel.isVisible)
  }

  /// One problem whose words change (a loss, then the cut away from it; a Details that becomes
  /// a Cut) is one panel saying what it says now, left where the operator put it. Its panel
  /// is ordered in at alpha 0, ignoring the mouse: test windows stay invisible.
  func testThePanelSaysWhatItsProblemSaysNow() throws {
    let panel = UIAlertPanelController.makePanel()
    panel.alphaValue = 0
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.animationBehavior = .none
    let controller = UIAlertPanelController(panel: panel)
    defer { controller.hide() }
    func said() -> UIPanelAlert? { (panel.contentView as? NSHostingView<UIAlertPanelView>)?.rootView.alert }
    let lost = UIPanelAlert(id: "onair.Camera 1", title: "Camera 1 signal lost", body: "Still on Program",
      action: UIProblemAction(title: "Details", action: .openDiagnostics))
    controller.show(lost) { _ in }
    XCTAssertEqual(said(), lost)
    XCTAssertTrue(panel.isVisible)
    let placed = NSPoint(x: 40, y: 40)
    panel.setFrameOrigin(placed)
    var moved = lost
    moved.body = "Program moved to Camera 2"
    controller.show(moved) { _ in }
    XCTAssertEqual(said(), moved, "The same problem, saying something new")
    XCTAssertEqual(panel.frame.origin, placed, "Where it was put")
    var cut = moved
    cut.action = UIProblemAction(title: "Cut to Camera 2", action: .cut(cameraID: "b"))
    controller.show(cut) { _ in }
    XCTAssertEqual(said()?.action?.title, "Cut to Camera 2")
    controller.hide()
    XCTAssertNil(controller.shown)
    XCTAssertFalse(panel.isVisible)
  }

  /// A camera that stops by itself, and the early take it leaves once it's started again,
  /// are one incident: one notification, and no panel for a camera that wasn't on air.
  func testAStopAndTheTakeItLeftAreOneNotification() {
    var tracker = UIAlertTracker()
    var camera = UICameraSnapshot(id: "a", name: "Camera 1")
    camera.unexpectedStop = UIUnexpectedStop(reason: "input disconnected", take: true, savedDuration: 751)
    var session = UISessionSnapshot()
    session.cameras = [camera]
    let first = tracker.plan(problems: UIPresentationBuilder.problems(session), live: false, notifications: true, panel: true,
      sound: false, timeSensitiveEntitled: false)
    XCTAssertEqual(first.post.map(\.title), ["Camera 1 stopped"])
    XCTAssertNil(first.panel, "Off air")
    session.cameras[0].running = true
    session.cameras[0].unexpectedStop = UIUnexpectedStop(take: true, savedDuration: 751, restarted: true)
    let started = tracker.plan(problems: UIPresentationBuilder.problems(session), live: false, notifications: true, panel: true,
      sound: false, timeSensitiveEntitled: false)
    XCTAssertTrue(started.post.isEmpty, "Start fixed the camera; the take's half is the same incident")
    XCTAssertTrue(started.remove.isEmpty)
    XCTAssertNil(started.panel, "Nothing pops up just after the operator fixed it")
    XCTAssertTrue(UIPresentationBuilder.problems(session).contains { $0.id == "take.a" }, "The take still asks for a look")
    var takeOnly = UIAlertTracker()
    session.cameras[0].unexpectedStop = UIUnexpectedStop(take: true, savedDuration: 751)
    XCTAssertEqual(takeOnly.plan(problems: UIPresentationBuilder.problems(session), live: false, notifications: true, panel: true,
      sound: false, timeSensitiveEntitled: false).panel?.title, "Camera 1 take ended", "A take that ended on its own still gets it")
  }

  /// An early take nobody has looked at yet doesn't swallow a stop that comes after it.
  func testALaterStopIsANewNotification() {
    var tracker = UIAlertTracker()
    var camera = UICameraSnapshot(id: "a", name: "Camera 1")
    camera.unexpectedStop = UIUnexpectedStop(take: true, savedDuration: 751)
    var session = UISessionSnapshot()
    session.cameras = [camera]
    func plan() -> UIAlertPlan {
      tracker.plan(problems: UIPresentationBuilder.problems(session), live: false, notifications: true, panel: true,
        sound: false, timeSensitiveEntitled: false)
    }
    XCTAssertEqual(plan().post.map(\.title), ["Camera 1 take ended"])
    session.cameras[0].unexpectedStop = UIUnexpectedStop(reason: "input disconnected", incident: 1)
    XCTAssertEqual(plan().post.map(\.title), ["Camera 1 stopped"], "A new stop is a new incident")
    session.cameras[0].running = true
    session.cameras[0].unexpectedStop = UIUnexpectedStop(take: true, savedDuration: 20, restarted: true, incident: 1)
    XCTAssertTrue(plan().post.isEmpty, "Its take after Start is still the stop's")
    session.cameras[0].running = false
    session.cameras[0].unexpectedStop = UIUnexpectedStop(reason: "input disconnected", take: true, savedDuration: 20, incident: 2)
    XCTAssertEqual(plan().post.map(\.title), ["Camera 1 stopped"], "Stopping again, before the last take was seen")
  }

  /// With Camera stopped off, the stop sends nothing; its take after Start, with Take ended
  /// early on, is the first notification the incident has, so it goes.
  func testAStopWhoseEventIsOffLeavesItsTakeToNotify() {
    var tracker = UIAlertTracker()
    var camera = UICameraSnapshot(id: "a", name: "Camera 1")
    camera.unexpectedStop = UIUnexpectedStop(reason: "input disconnected", take: true, savedDuration: 751, incident: 1)
    var session = UISessionSnapshot()
    session.cameras = [camera]
    func plan() -> UIAlertPlan {
      tracker.plan(problems: UIPresentationBuilder.problems(session), live: false, notifications: true, panel: true,
        sound: false, timeSensitiveEntitled: false, events: [.takeEndedEarly])
    }
    let stopped = plan()
    XCTAssertTrue(stopped.post.isEmpty, "Camera stopped is off")
    XCTAssertTrue(stopped.remove.isEmpty)
    session.cameras[0].running = true
    session.cameras[0].unexpectedStop = UIUnexpectedStop(take: true, savedDuration: 751, restarted: true, incident: 1)
    XCTAssertEqual(plan().post.map(\.title), ["Camera 1 take ended"], "Take ended early is on")
    XCTAssertTrue(plan().post.isEmpty, "Once")
    session.cameras[0].unexpectedStop = nil
    XCTAssertEqual(plan().remove, ["incident.a.1"], "Seen: it's taken back")
  }

  /// The model's stop is the incident: a stop and its take after Start share it, a new stop
  /// doesn't, and a take that ended alone has none to lose when its record appears.
  func testTheBridgeStampsEachStop() {
    let at = Date(timeIntervalSinceReferenceDate: 1_000)
    var stop = UnexpectedStop(reason: "x", at: at, cameraStopped: true)
    let first = UISessionBridge.unexpectedStop(stop).incident
    XCTAssertEqual(first, 1_000_000)
    stop.cameraStopped = false
    stop.restarted = true
    stop.take = .interrupted
    XCTAssertEqual(UISessionBridge.unexpectedStop(stop).incident, first, "Started again: the same incident")
    XCTAssertNotEqual(UISessionBridge.unexpectedStop(UnexpectedStop(reason: "x", at: at.addingTimeInterval(5), cameraStopped: true)).incident,
      first)
    XCTAssertNil(UISessionBridge.unexpectedStop(UnexpectedStop(reason: "x", at: at, cameraStopped: false, take: .interrupted)).incident)
  }

  /// Live is a meeting app taking frames from a camera, on a real model with fake capture.
  func testCoordinatorSendsNewProblemsAndNeverAsksWhileLive() throws {
    let suite = "org.ultracam.tests.alerts.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let fixture = try AppHardwareSyntheticFixture(deviceIDs: ["fake:alerts"])
    fixture.connect()
    defer { fixture.stop() }
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    let model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: AlertsRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer, hardware: fixture.hardware)
    defer { model.stopAllCameras() }
    model.refresh()
    let id = model.selectedFeedID
    model.updateCamera(id, shareProcessing: false) { $0.selectedDevice = "fake:alerts" }
    let interface = UIInterfaceState(defaults: defaults)
    interface.alertsDisabled = true
    let delivery = FakeAlertDelivery()
    let panel = FakeAlertPanel()
    let preferences = UIAlertPreferences(defaults: defaults)
    preferences.notificationsEnabled = false
    let coordinator = UIAlertCoordinator(model: model, interface: interface,
      preferences: preferences, delivery: delivery, panel: panel)
    XCTAssertTrue(interface.offerAlerts, "Undecided, and nothing is live")
    let bridge = UISessionBridge(model: model, interface: interface)
    XCTAssertTrue(bridge.presentation().offersAlerts)

    model.startCamera(id)
    model.setCameraDemandForTesting(id, requested: true)
    let pattern = try fixture.makePattern()
    var index: Int32 = 0
    let deadline = Date(timeIntervalSinceNow: 10)
    while !bridge.presentation().isLive, Date() < deadline {
      try fixture.emit(pattern, index: index)
      index += 1
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.016))
    }
    XCTAssertTrue(bridge.presentation().isLive, "A meeting app is taking this camera's frames")
    XCTAssertFalse(bridge.presentation().offersAlerts, "Never offered while live")
    bridge.perform(.turnOnAlerts)
    XCTAssertEqual(delivery.requested, 0, "And never asked, even if something sends the action")

    var update = CaptureUpdate(message: "Stopped")
    update.stopped = true
    update.stopCause = .failed("x")
    model.deliverCaptureUpdateForTesting(id, update)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    XCTAssertTrue(delivery.posted.isEmpty, "Notifications are off when the problem starts")
    preferences.notificationsEnabled = true
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    XCTAssertEqual(delivery.posted.map(\.title), ["\(model.feedDescriptors[0].name) stopped"],
      "Enabling notifications sends an existing problem without a model change")
    XCTAssertFalse(bridge.presentation().isLive)
    bridge.perform(.turnOnAlerts)
    XCTAssertEqual(delivery.requested, 1, "Off air it asks")
    bridge.perform(.dismissAlertsPrompt)
    XCTAssertFalse(interface.offerAlerts)
    withExtendedLifetime(coordinator) {}
  }

  func testPromptHidesWhileLive() {
    var camera = UICameraSnapshot(id: "a", name: "Camera 1")
    camera.running = true
    camera.signal = .live(format: "2160p")
    var session = UISessionSnapshot()
    session.cameras = [camera]
    session.offerAlerts = true
    XCTAssertTrue(UIPresentationBuilder.session(session).offersAlerts)
    session.cameras[0].recording.status = .recording
    XCTAssertFalse(UIPresentationBuilder.session(session).offersAlerts, "Never while rolling")
    session.cameras[0].recording.status = .idle
    session.cameras[0].inUse = true
    session.cameras[0].sinkConnected = true
    XCTAssertFalse(UIPresentationBuilder.session(session).offersAlerts, "Never while on air")
  }
}

@MainActor private final class FakeAlertDelivery: UIAlertDelivering {
  var posted: [UIAlertRequest] = []
  var removed: [String] = []
  var requested = 0
  func post(_ request: UIAlertRequest) { posted.append(request) }
  func remove(_ ids: [String]) { removed += ids }
  func checkPermissionUndetermined(_ result: @escaping @MainActor (Bool) -> Void) { result(true) }
  func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) { requested += 1; done(true) }
}

@MainActor private final class FakeAlertPanel: UIAlertPanelPresenting {
  var shown: UIPanelAlert?
  func show(_ alert: UIPanelAlert, send: @escaping @MainActor (UIAction) -> Void) { shown = alert }
  func hide() { shown = nil }
}

private final class AlertsRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}
#endif
