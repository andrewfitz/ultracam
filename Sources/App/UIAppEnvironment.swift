import AppKit

/// The app's long-lived models, shared by the scenes, the menu bar item and the
/// self-test. Created lazily on first use, so test harnesses that compile every
/// app source don't create them.
@MainActor enum UIAppEnvironment {
  static let model = AppModel()
  static let interface = UIInterfaceState()
  /// SwiftUI's scene actions, for AppKit (the menu bar item, a Dock click). The app's menu
  /// commands set them at launch, before any window opens, and they keep working after
  /// every window has closed.
  static var openWindow: ((String) -> Void)?
  static var openSettings: (() -> Void)?
}

/// Where Ultracam shows itself. "Menu bar when closed" (`hideFromDock`) keeps the Dock icon
/// and the app's menus while any of its windows is open, and leaves only the menu bar item
/// once they are all closed, so a window is never open without its menus and there is always
/// a way back. Otherwise Ultracam is always in the Dock.
@MainActor enum UIDockPresence {
  static func update(hideFromDock: Bool) {
    let app = NSApplication.shared
    let policy: NSApplication.ActivationPolicy = !hideFromDock || hasOpenWindow ? .regular : .accessory
    guard app.activationPolicy() != policy else { return }
    app.setActivationPolicy(policy)
  }

  /// A visible titled window: the main window, Settings, Diagnostics, Help or a detached
  /// monitor. Not the menu bar item's menu or a panel.
  static var hasOpenWindow: Bool {
    NSApplication.shared.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
  }
}
