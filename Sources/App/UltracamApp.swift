import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  private var menuBar: UIMenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = UIAppEnvironment.model
    self.model = model
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

  /// A Dock click with every window closed opens the main window again.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { UIAppEnvironment.openWindow?("main") }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model, model.recordingModel.hasActiveRecordings else { return .terminateNow }
    model.saveSettings()
    model.stopAllCameras()
    model.recordingModel.stopAll {
      DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
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
      }
    }
    .defaultSize(width: 1320, height: 860)
    .windowToolbarStyle(.unified)
    // Window › Ultracam (⌘0) brings the main window back.
    .commands { UICommands(model: model, interface: interface) }

    Window("Diagnostics", id: "diagnostics") {
      UIDiagnosticsView(model: model)
    }
    .defaultSize(width: 1100, height: 760)

    Window("Ultracam Help", id: "help") {
      UIHelpView()
    }
    .defaultSize(width: 560, height: 640)
    .windowResizability(.contentSize)

    Settings {
      UISettingsView(model: model)
    }
  }
}
