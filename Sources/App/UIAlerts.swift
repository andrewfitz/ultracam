import AppKit
import Observation
import SwiftUI
@preconcurrency import UserNotifications

// Problems that leave the window: system notifications for five events, and a floating
// panel for the three worst. No channel reaches everywhere: a banner may be held back
// while a screen is shared, and the panel only reaches a full-screen meeting while
// Ultracam's windows are closed. Text is treated as public, because viewers may see either.

/// What Settings › Alerts binds to. Off by default is only ever sound.
@MainActor @Observable final class UIAlertPreferences {
  /// Time Sensitive needs a capability the current provisioning profiles don't include,
  /// and an entitlement a profile lacks fails the signed build. Until the profile has
  /// it, notifications go out at the `.active` level.
  static let timeSensitiveEntitled = false
  static let lowSpaceMinutesKey = "ui.alerts.lowSpaceMinutes"
  /// Settings' choices for Low Space, in minutes.
  static let lowSpaceChoices = [15, 30, 60, 120]

  private let defaults: UserDefaults
  var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "ui.alerts.notifications") } }
  var panelEnabled: Bool { didSet { defaults.set(panelEnabled, forKey: "ui.alerts.panel") } }
  var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "ui.alerts.sound") } }
  /// "Not Now" on the Attention prompt: don't ask again from there.
  var promptDismissed: Bool { didSet { defaults.set(promptDismissed, forKey: "ui.alerts.promptDismissed") } }
  /// Events that notify. All five by default; the panel follows its own switch.
  var events: Set<UIAlertEvent> {
    didSet {
      let off = UIAlertEvent.allCases.filter { !events.contains($0) }.map(\.rawValue)
      defaults.set(off, forKey: "ui.alerts.eventsOff")
    }
  }
  /// Less recording time left than this is low: the drive rows turn orange and a problem is raised.
  var lowSpaceMinutes: Int { didSet { defaults.set(lowSpaceMinutes, forKey: Self.lowSpaceMinutesKey) } }
  /// What macOS says Ultracam may do, read from the notification center, never assumed.
  var permission = UIAlertPermission()
  /// Reads `permission` again (Settings appearing, the app coming back to the front).
  @ObservationIgnored var refreshPermission: (@MainActor () -> Void)?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    notificationsEnabled = defaults.object(forKey: "ui.alerts.notifications") as? Bool ?? true
    panelEnabled = defaults.object(forKey: "ui.alerts.panel") as? Bool ?? true
    soundEnabled = defaults.object(forKey: "ui.alerts.sound") as? Bool ?? false
    promptDismissed = defaults.object(forKey: "ui.alerts.promptDismissed") as? Bool ?? false
    let off = Set((defaults.stringArray(forKey: "ui.alerts.eventsOff") ?? []).compactMap(UIAlertEvent.init(rawValue:)))
    events = Set(UIAlertEvent.allCases).subtracting(off)
    let minutes = defaults.object(forKey: Self.lowSpaceMinutesKey) as? Int
    lowSpaceMinutes = minutes.flatMap { Self.lowSpaceChoices.contains($0) ? $0 : nil } ?? 30
  }

  func notifies(_ event: UIAlertEvent) -> Bool { events.contains(event) }

  func setNotifies(_ event: UIAlertEvent, _ on: Bool) {
    if on { events.insert(event) } else { events.remove(event) }
  }
}

/// Notification permission as macOS reports it, for Settings › Alerts.
struct UIAlertPermission: Sendable, Equatable {
  enum Status: Sendable, Equatable { case unknown, notDetermined, denied, allowed }
  var status: Status = .unknown
  /// Banners or alerts are shown, not only Notification Center.
  var banners = false
  /// macOS lets them through Focus as Time Sensitive.
  var timeSensitive = false
}

extension UIAlertEvent {
  /// The event's name in Settings › Alerts.
  var title: String {
    switch self {
    case .cameraStopped: return "Camera stopped unexpectedly"
    case .takeEndedEarly: return "Take ended early"
    case .recordingNoSignal: return "Recording with no signal"
    case .onAirLost: return "On-air camera lost"
    case .driveLow: return "Drive low or full"
    }
  }
}

struct UIAlertRequest: Sendable, Equatable {
  var id: String
  var title: String
  var body: String
  var timeSensitive = false
  var sound = false
}

struct UIPanelAlert: Sendable, Equatable {
  var id: String
  var title: String
  var body: String
  var action: UIProblemAction?
}

/// What changed since the last look: new alerts to send, cleared ones to take back.
struct UIAlertPlan: Sendable, Equatable {
  var post: [UIAlertRequest] = []
  var remove: [String] = []
  /// The panel to show, nil for none. It follows the worst problem that wants one.
  var panel: UIPanelAlert?
}

/// One request per problem, so a repeat replaces it, and a clear removes the notification.
struct UIAlertTracker {
  private var active: Set<String> = []

  /// `events` are the ones Settings › Alerts leaves on for notifications; the panel ignores it.
  mutating func plan(problems: [UIProblem], live: Bool, notifications: Bool, panel: Bool, sound: Bool,
    timeSensitiveEntitled: Bool, events: Set<UIAlertEvent> = Set(UIAlertEvent.allCases)) -> UIAlertPlan {
    var plan = UIAlertPlan()
    var current: Set<String> = []
    for problem in problems {
      guard let alert = problem.alert else { continue }
      let key = alert.key ?? problem.id
      guard current.insert(key).inserted else { continue }
      if notifications, events.contains(alert.event), !active.contains(key) {
        plan.post.append(UIAlertRequest(id: key, title: alert.title, body: alert.body,
          timeSensitive: timeSensitiveEntitled && live, sound: sound))
      }
      if panel, plan.panel == nil, alert.showsPanel {
        plan.panel = UIPanelAlert(id: key, title: alert.title, body: alert.body, action: problem.action)
      }
    }
    plan.remove = active.subtracting(current).sorted()
    active = current
    return plan
  }
}

/// The notification center behind a seam: harnesses compile every app source, and the
/// real center can't be touched without a bundle.
@MainActor protocol UIAlertDelivering: AnyObject {
  func post(_ request: UIAlertRequest)
  func remove(_ ids: [String])
  /// Calls back with whether Ultracam may ask for permission: nothing has been decided yet.
  func checkPermissionUndetermined(_ result: @escaping @MainActor (Bool) -> Void)
  func requestPermission(_ done: @escaping @MainActor (Bool) -> Void)
  /// Calls back with the permission macOS reports now.
  func readPermission(_ result: @escaping @MainActor (UIAlertPermission) -> Void)
}

extension UIAlertDelivering {
  func readPermission(_ result: @escaping @MainActor (UIAlertPermission) -> Void) { result(UIAlertPermission()) }
}

@MainActor protocol UIAlertPanelPresenting: AnyObject {
  func show(_ alert: UIPanelAlert, send: @escaping @MainActor (UIAction) -> Void)
  func hide()
}

/// Watches the problem list and sends what's new. Created in `didFinishLaunching`, never
/// from AppModel: permission and the notification center belong to the running app.
@MainActor final class UIAlertCoordinator {
  private let model: AppModel
  private let interface: UIInterfaceState
  private let preferences: UIAlertPreferences
  private let delivery: any UIAlertDelivering
  private let panel: any UIAlertPanelPresenting
  private var tracker = UIAlertTracker()
  private var updateScheduled = false

  init(model: AppModel, interface: UIInterfaceState, preferences: UIAlertPreferences,
    delivery: any UIAlertDelivering, panel: any UIAlertPanelPresenting) {
    self.model = model
    self.interface = interface
    self.preferences = preferences
    self.delivery = delivery
    self.panel = panel
    interface.turnOnAlerts = { [weak self] in self?.turnOn() }
    interface.dismissAlertsPrompt = { [weak self] in self?.dismissPrompt() }
    preferences.refreshPermission = { [weak self] in self?.readPermission() }
    readPermission()
    if !preferences.promptDismissed {
      delivery.checkPermissionUndetermined { [weak self] undetermined in self?.interface.offerAlerts = undetermined }
    }
    track()
    evaluate()
  }

  private func bridge() -> UISessionBridge {
    UISessionBridge.live(model: model, interface: interface,
      openWindow: { id in
        // Into the Dock first, so the window opens with its menus ("Menu bar when closed").
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        UIAppEnvironment.openWindow?(id)
        NSApp.activate(ignoringOtherApps: true)
      }, openSettings: {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        UIAppEnvironment.openSettings?()
        NSApp.activate(ignoringOtherApps: true)
      })
  }

  private func track() {
    withObservationTracking {
      _ = bridge().presentation().problems.map(\.id)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.scheduleUpdate() }
    }
  }

  /// Coalesced: a burst of changes is one look at the list.
  private func scheduleUpdate() {
    guard !updateScheduled else { return }
    updateScheduled = true
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard let self else { return }
      self.updateScheduled = false
      self.evaluate()
      self.track()
    }
  }

  private func evaluate() {
    let presentation = bridge().presentation()
    let plan = tracker.plan(problems: presentation.problems, live: presentation.isLive,
      notifications: preferences.notificationsEnabled, panel: preferences.panelEnabled,
      sound: preferences.soundEnabled, timeSensitiveEntitled: UIAlertPreferences.timeSensitiveEntitled,
      events: preferences.events)
    plan.post.forEach(delivery.post)
    if !plan.remove.isEmpty { delivery.remove(plan.remove) }
    if let alert = plan.panel {
      let bridge = bridge()
      panel.show(alert) { bridge.send($0) }
    } else {
      panel.hide()
    }
  }

  private func turnOn() {
    interface.offerAlerts = false
    // Never while live: the prompt can't show then, and a menu can't reach this.
    guard !bridge().presentation().isLive else { return }
    delivery.requestPermission { [weak self] _ in self?.readPermission() }
  }

  private func readPermission() {
    delivery.readPermission { [weak self] permission in
      guard let self else { return }
      if self.preferences.permission != permission { self.preferences.permission = permission }
      // Decided elsewhere (System Settings): Attention stops offering it.
      if permission.status != .notDetermined && permission.status != .unknown { self.interface.offerAlerts = false }
    }
  }

  private func dismissPrompt() {
    preferences.promptDismissed = true
    interface.offerAlerts = false
  }
}

/// `UNUserNotificationCenter`. Assigned as delegate in `didFinishLaunching`, as Apple asks.
@MainActor final class UIUserNotifications: NSObject, UIAlertDelivering, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  /// A click opens the main window.
  var opened: (@MainActor () -> Void)?

  override init() {
    super.init()
    center.delegate = self
  }

  func post(_ request: UIAlertRequest) {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.sound = request.sound ? .default : nil
    content.interruptionLevel = request.timeSensitive ? .timeSensitive : .active
    center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
  }

  func remove(_ ids: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  func checkPermissionUndetermined(_ result: @escaping @MainActor (Bool) -> Void) {
    Task { @MainActor in
      let settings = await center.notificationSettings()
      result(settings.authorizationStatus == .notDetermined)
    }
  }

  func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
    Task { @MainActor in
      // No `.provisional`: those deliver quietly to Notification Center only.
      let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
      done(granted)
    }
  }

  func readPermission(_ result: @escaping @MainActor (UIAlertPermission) -> Void) {
    Task { @MainActor in
      let settings = await center.notificationSettings()
      result(Self.permission(status: settings.authorizationStatus, style: settings.alertStyle,
        timeSensitive: settings.timeSensitiveSetting))
    }
  }

  /// Provisional delivers quietly to Notification Center only, which can't reach anyone live.
  static func permission(status: UNAuthorizationStatus, style: UNAlertStyle, timeSensitive: UNNotificationSetting) -> UIAlertPermission {
    var permission = UIAlertPermission()
    switch status {
    case .notDetermined: permission.status = .notDetermined
    case .denied: permission.status = .denied
    case .authorized, .ephemeral: permission.status = .allowed
    case .provisional: permission.status = .notDetermined
    @unknown default: permission.status = .unknown
    }
    permission.banners = style != .none
    permission.timeSensitive = timeSensitive == .enabled
    return permission
  }

  /// System Settings at Ultracam's notifications.
  static var settingsURL: URL? {
    URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "org.ultracam.app")")
  }

  /// Attention already shows it when the main window is key.
  static func presentation(mainWindowKey: Bool) -> UNNotificationPresentationOptions {
    mainWindowKey ? [.list] : [.banner, .list]
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
    await MainActor.run { Self.presentation(mainWindowKey: NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true) }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    await MainActor.run { opened?() }
  }
}

/// A small panel for the three worst events. It never activates Ultracam, so it can't pull
/// a meeting out of full screen. It reaches a full-screen meeting only while Ultracam is in
/// the accessory state; with a window open, assume it doesn't. `sharingType` is best effort,
/// so its text is written for viewers too.
@MainActor final class UIAlertPanelController: UIAlertPanelPresenting {
  static let size = NSSize(width: 340, height: 64)
  private var panel: NSPanel?
  /// What the panel says now. One problem can change what it says (a loss, then the cut away
  /// from it) without becoming another problem.
  private(set) var shown: UIPanelAlert?

  /// Tests hand in a panel they keep invisible.
  init(panel: NSPanel? = nil) { self.panel = panel }

  static func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false  // An NSPanel hides on deactivate by default.
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
    panel.sharingType = .none
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    return panel
  }

  func show(_ alert: UIPanelAlert, send: @escaping @MainActor (UIAction) -> Void) {
    guard shown != alert else { return }
    let sameProblem = shown?.id == alert.id
    shown = alert
    let panel = panel ?? Self.makePanel()
    self.panel = panel
    panel.contentView = NSHostingView(rootView: UIAlertPanelView(alert: alert, send: send))
    // The same problem saying something new stays where it is, and where it was moved to.
    guard !sameProblem || !panel.isVisible else { return }
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - 16, y: frame.maxY - Self.size.height - 16))
    }
    panel.orderFrontRegardless()  // Never NSApp.activate: that would leave a full-screen meeting.
  }

  func hide() {
    shown = nil
    panel?.orderOut(nil)
  }
}

struct UIAlertPanelView: View {
  let alert: UIPanelAlert
  let send: @MainActor (UIAction) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(alert.title).font(.uiRowEmphasis).lineLimit(1)
        Text(alert.body).font(.uiMeta).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if let action = alert.action {
        Button(action.title) { send(action.action) }.controlSize(.small).fixedSize()
      }
    }
    .padding(.horizontal, 12)
    .frame(width: UIAlertPanelController.size.width, height: UIAlertPanelController.size.height)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(alert.title)
  }
}

/// Before a session, while nothing's on air or rolling: the one place Ultracam asks.
struct UIAlertsPrompt: View {
  let context: UIContext

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Turn on alerts").font(.uiRowEmphasis)
      Text("See a lost camera or an early take while another app is in front.")
        .font(.uiMeta).foregroundStyle(.secondary).lineLimit(3)
      HStack {
        Spacer(minLength: 0)
        Button("Not Now") { context.send(.dismissAlertsPrompt) }.controlSize(.small)
        Button("Turn On Alerts") { context.send(.turnOnAlerts) }.controlSize(.small)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}
