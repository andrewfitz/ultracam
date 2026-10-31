#if ULTRACAM_TEST_SUPPORT
import AppKit
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
    XCTAssertEqual(plan.remove, ["stopped.Camera 1"], "A cleared problem takes its notification back")
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

  func testCoordinatorSendsNewProblemsAndNeverAsksWhileLive() {
    let suite = "org.ultracam.tests.alerts.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    let model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: AlertsRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer, hardware: .offline)
    let interface = UIInterfaceState(defaults: defaults)
    interface.alertsDisabled = true
    let delivery = FakeAlertDelivery()
    let panel = FakeAlertPanel()
    let coordinator = UIAlertCoordinator(model: model, interface: interface,
      preferences: UIAlertPreferences(defaults: defaults), delivery: delivery, panel: panel)
    XCTAssertTrue(interface.offerAlerts, "Undecided, and nothing is live")

    var update = CaptureUpdate(message: "Stopped")
    update.stopped = true
    update.stopCause = .failed("x")
    model.deliverCaptureUpdateForTesting(model.selectedFeedID, update)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    XCTAssertEqual(delivery.posted.map(\.title), ["\(model.feedDescriptors[0].name) stopped"])

    let bridge = UISessionBridge(model: model, interface: interface)
    XCTAssertTrue(UIPresentationBuilder.session(bridge.snapshot()).offersAlerts)
    bridge.perform(.dismissAlertsPrompt)
    XCTAssertFalse(interface.offerAlerts)
    XCTAssertEqual(delivery.requested, 0)
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
