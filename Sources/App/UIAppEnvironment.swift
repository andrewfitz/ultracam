import AppKit

/// The app's long-lived models, shared by the scenes, the menu bar item and the
/// self-test. Created lazily on first use, so test harnesses that compile every
/// app source don't create them.
@MainActor enum UIAppEnvironment {
  private static let selfTestDomain: String? = {
    let args = CommandLine.arguments
    guard args.contains("--ui-tour") || (args.contains("--ui-self-test") && !args.contains("--live")) else { return nil }
    let domain = "org.ultracam.ui-self-test.\(UUID().uuidString)"
    // cfprefsd still writes named suites to the user's real preferences directory
    // under CFFIXED_USER_HOME. An absolute suite lives inside the run itself.
    if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], home.hasPrefix("/") {
      return URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/\(domain)").path
    }
    return domain
  }()
  static let defaults = selfTestDomain.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  static func clearSelfTestPreferences() {
    if let selfTestDomain { defaults.removePersistentDomain(forName: selfTestDomain) }
  }
  static let model: AppModel = {
    guard selfTestDomain != nil else { return AppModel() }
    return AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: VirtualCameraRegistryPublisher(observeTopology: false, apply: { _ in }),
      recordingFolderStore: RecordingFolderStore(defaults: defaults),
      hardware: CommandLine.arguments.contains("--live") ? .live : .offline)
  }()
  static let interface = UIInterfaceState(defaults: defaults)
  static let alertPreferences = UIAlertPreferences(defaults: defaults)
  /// Settings › General's switch binds this.
  static let backgroundShortcuts = UIBackgroundShortcuts(defaults: defaults)
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
