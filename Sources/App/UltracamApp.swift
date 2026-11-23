import AppKit
import Network
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  private var menuBar: UIMenuBarController?
  private var alerts: UIAlertCoordinator?
  private var cameraControlRetries: CameraControlRetryTriggers?
  /// A Quit the operator has confirmed, so the second pass through here doesn't ask again.
  private var quitConfirmed = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = UIAppEnvironment.model
    self.model = model
    let interface = UIAppEnvironment.interface
    interface.pruneLayoutPreferences(for: Set(model.feedDescriptors.map(\.id.rawValue)))
    model.stripOrder = { ids in
      interface.ordered(ids.map(\.rawValue), id: { $0 }).map { FeedID(rawValue: $0) }
    }
    UIDockPresence.update(hideFromDock: model.hideFromDock)
    // In the Dock while a window is open; with "Menu bar when closed", only the menu bar
    // item once the last one closes (it is still visible while it closes, so look after).
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { UIDockPresence.update(hideFromDock: UIAppEnvironment.model.hideFromDock) }
        }
      }
    }
    menuBar = UIMenuBarController(model: model, interface: UIAppEnvironment.interface)
    if !CommandLine.arguments.contains("--ui-self-test"), !CommandLine.arguments.contains("--ui-tour") {
      Task { @MainActor in await model.cameraControls.restoreConnections() }
      cameraControlRetries = CameraControlRetryTriggers(store: model.cameraControls)
      // Here, before launch finishes: the system asks for the delegate that early.
      let notifications = UIUserNotifications()
      notifications.opened = { [weak self] in self?.showMainWindow() }
      alerts = UIAlertCoordinator(model: model, interface: UIAppEnvironment.interface,
        preferences: UIAppEnvironment.alertPreferences, delivery: notifications, panel: UIAlertPanelController())
      let shortcuts = UIAppEnvironment.backgroundShortcuts
      shortcuts.perform = { shortcut in
        let bridge = UISessionBridge.live(model: model, interface: interface)
        shortcut.actions(in: bridge.presentation()).forEach { bridge.perform($0) }
      }
      shortcuts.start()
    }
    // scripts/ui-tour.sh reviews both appearances without changing the system setting.
    if let flag = CommandLine.arguments.firstIndex(of: "--ui-appearance"), CommandLine.arguments.indices.contains(flag + 1) {
      NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments[flag + 1] == "dark" ? .darkAqua : .aqua)
    }
    // The self-test lives in its own file and is found through the Objective-C
    // runtime, so the app builds with or without it.
    if CommandLine.arguments.contains("--ui-self-test"),
      let runner = NSClassFromString("UISelfTestRunner") as? NSObject.Type {
      _ = runner.perform(NSSelectorFromString("run"))
    }
  }

  /// A notification clicked: into the Dock first, so the window opens with its menus.
  private func showMainWindow() {
    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    UIAppEnvironment.openWindow?("main")
    NSApp.activate(ignoringOtherApps: true)
  }

  /// A Dock click with every window closed opens the main window again.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { UIAppEnvironment.openWindow?("main") }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    if model.terminating { return .terminateLater }
    // Ending takes or on-air video asks first, behind Settings › General's switch. Cancel is
    // the default, so Return never ends a take.
    let bridge = UISessionBridge.live(model: model, interface: UIAppEnvironment.interface)
    let presentation = bridge.presentation()
    if !quitConfirmed, !model.settingsResetPending, presentation.askBeforeEnding, let message = UIAction.endingMessage(in: presentation) {
      let alert = UISessionBridge.confirmationAlert(for: .quit, message: message, in: presentation)
      NSApplication.shared.activate(ignoringOtherApps: true)
      let escape = UISessionBridge.cancelOnEscape(alert)
      let response = alert.runModal()
      if let escape { NSEvent.removeMonitor(escape) }
      guard response == .alertSecondButtonReturn else { return .terminateCancel }
      quitConfirmed = true
    }
    let streaming = model.streamNeedsShutdown
    let recording = model.recordingModel.hasActiveRecordings
    guard streaming || recording || model.cameraControls.needsShutdown else { return .terminateNow }
    model.beginTermination()
    if model.streamSnapshot.active { model.stopProgramStream() }
    // Finishing a take can take a while; without this the app would look hung.
    let progress = recording ? UIQuitProgressPanel.show() : nil
    if recording { model.saveSettings() }
    if streaming || recording { model.stopAllCameras() }
    Task { @MainActor in
      async let controlCleanup = model.cameraControls.shutdown()
      async let streamCleanup: Void = model.finishProgramStreamShutdown()
      if recording {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          model.recordingModel.stopAll { continuation.resume() }
        }
      }
      if let message = await controlCleanup { NSLog("Camera control cleanup on quit: %@", message) }
      await streamCleanup
      progress?.close()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// "Finishing recordings…" with a spinner while Quit waits for takes to finish. Nothing in it
/// can be clicked: the wait ends on its own.
@MainActor private enum UIQuitProgressPanel {
  static func show() -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    panel.title = "Quitting Ultracam"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isIndeterminate = true
    spinner.startAnimation(nil)
    let label = NSTextField(labelWithString: "Finishing recordings…")
    let stack = NSStackView(views: [spinner, label])
    stack.orientation = .horizontal
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
    ])
    panel.contentView = content
    panel.center()
    panel.orderFrontRegardless()
    return panel
  }
}

@main
struct UltracamApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let model = UIAppEnvironment.model
  private let interface = UIAppEnvironment.interface

  var body: some Scene {
    // A single main window keeps the selected camera's native video layer attached to one view.
    Window("Ultracam", id: "main") {
      UILiveRoot(model: model, interface: interface) { context in
        UIMainWindowView(context: context)
          .toolbar { UIToolbarContent(context: context) }
          .uiWatchesHardware(model.hardwareInventory)
          .defaultAppStorage(UIAppEnvironment.defaults)
      }
    }
    // The Window menu's Show Main Window (⌘0) and Diagnostics (⌃⌥D) items are UICommands', so
    // these scenes drop their own Window menu items, which would list each window twice.
    // UICommands sits outside this, so it stays.
    .commandsRemoved()
    .defaultSize(width: 1320, height: 860)
    .windowToolbarStyle(.unified)
    .commands { UICommands(model: model, interface: interface) }

    Window("Diagnostics", id: "diagnostics") {
      UIDiagnosticsView(model: model, interface: interface)
    }
    .commandsRemoved()
    .defaultSize(width: 1100, height: 760)
    .restorationBehavior(.disabled)

    // A picture's scope in its own window (the card's Pop Out): one per camera or Program,
    // resizable, at native resolution. Closing it puts the card back on the picture.
    WindowGroup("Scope", id: UIScopeWindow.id, for: String.self) { $target in
      if let target {
        UIScopeWindowView(model: model, target: target, coordinator: model.monitorCoordinator)
      }
    }
    .defaultSize(UIScopeWindow.defaultSize(.wide))
    .windowToolbarStyle(.unifiedCompact)
    .restorationBehavior(.disabled)

    // Help › Ultracam Help (⌘?) opens it.
    Window("Ultracam Help", id: "help") {
      UIHelpView()
    }
    .commandsRemoved()
    .defaultSize(width: 560, height: 640)
    .windowResizability(.contentSize)
    .restorationBehavior(.disabled)

    // Eight toolbar tabs in an ordinary resizable window; a long tab scrolls.
    Settings {
      UISettingsView(model: model, interface: interface)
        .defaultAppStorage(UIAppEnvironment.defaults)
    }
    .defaultSize(UISettingsLayout.defaultSize)
    .windowResizability(.contentMinSize)
  }
}

/// A wake, or the network coming back, retries camera bodies waiting to reconnect now rather
/// than after their backoff.
@MainActor private final class CameraControlRetryTriggers {
  private let path = NWPathMonitor()
  private var satisfied: Bool?

  init(store: CameraControlStore) {
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak store] _ in
      MainActor.assumeIsolated { store?.retryPendingReconnects() }
    }
    path.pathUpdateHandler = { [weak self, weak store] update in
      let now = update.status == .satisfied
      MainActor.assumeIsolated {
        guard let self else { return }
        // The first report is the current state, not a change.
        if now, self.satisfied == false { store?.retryPendingReconnects() }
        self.satisfied = now
      }
    }
    path.start(queue: .main)
  }
}
