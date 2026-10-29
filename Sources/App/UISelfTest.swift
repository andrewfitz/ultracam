import AppKit

/// Entry point found by AppDelegate through the Objective-C runtime when the
/// app is launched with `--ui-self-test <output folder>`.
@objc(UISelfTestRunner) final class UISelfTestRunner: NSObject {
  @objc static func run() {
    // AppDelegate calls this from applicationDidFinishLaunching, on the main thread.
    MainActor.assumeIsolated {
      UISelfTest.runIfRequested(model: UIAppEnvironment.model, interface: UIAppEnvironment.interface)
    }
  }
}

/// In-app verification of the real scenes: the main menu (titles, shortcuts,
/// duplicates), the main, Settings and Diagnostics windows rendered in light
/// and dark, and the menu bar item. It never starts cameras or records.
/// Results go to `<output>/report.json` plus PNGs; then the app quits.
@MainActor enum UISelfTest {
  struct Check: Encodable {
    var name: String
    var pass: Bool
    var detail: String
  }

  private static var checks: [Check] = []
  private static var output = URL(fileURLWithPath: NSTemporaryDirectory())

  static func runIfRequested(model: AppModel, interface: UIInterfaceState) {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--ui-self-test") else { return }
    let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : NSTemporaryDirectory() + "ultracam-ui-self-test"
    output = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    Task { @MainActor in
      await run(model: model, interface: interface)
    }
  }

  private static func record(_ name: String, _ pass: Bool, _ detail: String = "") {
    checks.append(Check(name: name, pass: pass, detail: detail))
  }

  /// Opt-in (`--live`): starts the selected camera through the same action the
  /// interface sends, reads the state the interface shows, then stops it.
  /// Reads HDMI only; never records.
  private static func liveCameraCheck(model: AppModel, interface: UIInterfaceState) async {
    let bridge = UISessionBridge.live(model: model, interface: interface)
    guard let camera = bridge.snapshot().cameras.first(where: { $0.id == model.selectedFeedID.rawValue }) else {
      record("live: a camera is configured", false, "")
      return
    }
    guard camera.deviceAvailable else {
      record("live: capture input present", false, "no capture input for \(camera.name)")
      return
    }
    bridge.send(.startCamera(cameraID: camera.id))
    var timeline: [String] = []
    for second in 1...8 {
      await wait(1)
      let now = bridge.snapshot().cameras.first { $0.id == camera.id }
      timeline.append("\(second)s running=\(now?.running == true) signal=\(String(describing: now?.signal)) message=\(now?.message ?? "")")
    }
    try? timeline.joined(separator: "\n").write(to: output.appendingPathComponent("live-timeline.txt"), atomically: true, encoding: .utf8)
    let started = bridge.snapshot().cameras.first { $0.id == camera.id }
    record("live: Start Camera starts capture", started?.running == true, "")
    let tile = started.map { UIPresentationBuilder.tileState(for: $0) }
    record("live: the picture shows a real state", tile != nil && tile != .stopped,
      "signal \(String(describing: started?.signal)), tile \(String(describing: tile))")
    let liveLabels = appWindows().filter { identifier(of: $0).hasPrefix("main") }
      .flatMap { window in window.contentView.map { accessibilityLabels(in: $0) } ?? [] }
    try? liveLabels.joined(separator: "\n").write(to: output.appendingPathComponent("accessibility-live.txt"), atomically: true, encoding: .utf8)
    // The picture's own label carries the camera state ("Camera 1, No signal"); the
    // inspector column's accessibility values can lag behind what it draws.
    record("live: the window shows the running camera",
      liveLabels.contains { $0.hasPrefix("\(camera.name),") && !$0.localizedCaseInsensitiveContains("stopped") },
      liveLabels.filter { $0.localizedCaseInsensitiveContains("signal") || $0.localizedCaseInsensitiveContains("stopped") }.joined(separator: " | "))
    await renderWindows(suffix: "-live")
    bridge.send(.stopCamera(cameraID: camera.id))
    await wait(2)
    let stopped = bridge.snapshot().cameras.first { $0.id == camera.id }
    record("live: Stop Camera stops capture", stopped?.running == false, "")
  }

  private static func wait(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
  }

  private static func run(model: AppModel, interface: UIInterfaceState) async {
    await wait(2)
    checkMenus()
    record("no camera started by the self-test", !model.running, model.running ? "selected camera is running" : "")
    openWindows()
    await wait(1.5)
    checkStatusItem()
    // The inspector opens in the real scene window (an offscreen NSHostingView can't host it).
    interface.inspectorOpen = true
    await wait(1)
    record("main window survives opening the inspector", appWindows().contains { identifier(of: $0).hasPrefix("main") })
    record("inspector stays open after opening", interface.inspectorOpen, interface.inspectorOpen ? "" : "something closed it")
    // Enhanced user interface makes SwiftUI publish its accessibility tree in-process.
    NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    await wait(0.5)
    let mainLabels = appWindows().filter { identifier(of: $0).hasPrefix("main") }
      .flatMap { window in window.contentView.map { accessibilityLabels(in: $0) } ?? [] }
    try? mainLabels.joined(separator: "\n").write(to: output.appendingPathComponent("accessibility-main.txt"), atomically: true, encoding: .utf8)
    record("inspector shows the selected camera's settings", mainLabels.contains("Refresh capture devices"),
      "\(mainLabels.count) labels")
    for label in ["Processing", "Start Camera"] {
      record("main window exposes \"\(label)\"", mainLabels.contains { $0.hasPrefix(label) }, "")
    }
    await renderWindows()
    if CommandLine.arguments.contains("--live") { await liveCameraCheck(model: model, interface: interface) }
    interface.inspectorOpen = false
    finish()
  }

  // MARK: Menus

  struct MenuEntry {
    var path: String
    var title: String
    var shortcut: String
    var enabled: Bool
  }

  static func shortcut(key: String, modifiers: NSEvent.ModifierFlags) -> String {
    guard !key.isEmpty else { return "" }
    var flags = modifiers.intersection([.control, .option, .shift, .command])
    var character = key
    if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) {
      flags.insert(.shift)
      character = key.lowercased()
    }
    var text = ""
    if flags.contains(.control) { text += "⌃" }
    if flags.contains(.option) { text += "⌥" }
    if flags.contains(.shift) { text += "⇧" }
    if flags.contains(.command) { text += "⌘" }
    switch character {
    case "\r": text += "↩"
    case "\u{1b}": text += "⎋"
    default: text += character.uppercased()
    }
    return text
  }

  static func entries(in menu: NSMenu, path: String = "") -> [MenuEntry] {
    menu.update()
    var result: [MenuEntry] = []
    for item in menu.items where !item.isSeparatorItem && !item.isHidden {
      let itemPath = path.isEmpty ? item.title : "\(path) › \(item.title)"
      result.append(MenuEntry(path: itemPath, title: item.title,
        shortcut: shortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask), enabled: item.isEnabled))
      if let submenu = item.submenu { result += entries(in: submenu, path: itemPath) }
    }
    return result
  }

  static let requiredMenus = ["Camera", "Record", "Program", "View", "Window"]
  static let requiredShortcuts = ["⌘↩", "⇧⌘B", "⇧⌘P", "⌘R", "⌥⌘R", "⌃1", "⌃⌥A", "⌥⌘1", "⌃⌘S", "⌥⌘S", "⌥⌘K", "⌥⌘I",
    "⌘0", "⌃⌥F", "⌃⌥C"]

  private static func checkMenus() {
    guard let main = NSApp.mainMenu else { record("main menu exists", false); return }
    let topTitles = main.items.map(\.title)
    for title in requiredMenus {
      record("menu \(title) exists", topTitles.contains(title), topTitles.joined(separator: ", "))
    }
    let all = entries(in: main)
    let shortcuts = all.filter { !$0.shortcut.isEmpty }
    for required in requiredShortcuts {
      let owners = shortcuts.filter { $0.shortcut == required }.map(\.path)
      record("shortcut \(required) is assigned", !owners.isEmpty, owners.joined(separator: "; "))
    }
    let grouped = Dictionary(grouping: shortcuts, by: \.shortcut).filter { $0.value.count > 1 }
    record("no duplicate key equivalents", grouped.isEmpty,
      grouped.map { "\($0.key): \($0.value.map(\.path).joined(separator: " | "))" }.sorted().joined(separator: "; "))
    let dump = all.map { "\($0.path)\t\($0.shortcut)\t\($0.enabled ? "enabled" : "disabled")" }.joined(separator: "\n")
    try? dump.write(to: output.appendingPathComponent("menus.tsv"), atomically: true, encoding: .utf8)
  }

  // MARK: Windows

  private static func performMenuItem(where predicate: (NSMenuItem) -> Bool) -> Bool {
    func search(_ menu: NSMenu) -> Bool {
      menu.update()
      for (index, item) in menu.items.enumerated() {
        if predicate(item), item.isEnabled, item.submenu == nil {
          menu.performActionForItem(at: index)
          return true
        }
        if let submenu = item.submenu, search(submenu) { return true }
      }
      return false
    }
    guard let main = NSApp.mainMenu else { return false }
    return search(main)
  }

  private static func appWindows() -> [NSWindow] {
    NSApp.windows.filter { window in
      let kind = String(describing: type(of: window))
      return window.isVisible && window.contentView != nil && !kind.contains("StatusBar") && !kind.contains("Menu")
        && window.frame.width > 200
    }
  }

  private static func openWindows() {
    if !appWindows().contains(where: { identifier(of: $0).hasPrefix("main") }) {
      _ = performMenuItem { $0.title == "Ultracam" && $0.keyEquivalent == "0" }
    }
    // SwiftUI's Settings scene opens from the app menu's Settings… item (⌘,); the old
    // showSettingsWindow: action is a no-op for it on current macOS.
    NSApp.activate(ignoringOtherApps: true)
    let settingsOpened = performMenuItem { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
      || NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    record("Settings… menu item exists and runs", settingsOpened)
    let diagnosticsOpened = performMenuItem { $0.title.hasPrefix("Diagnostics") }
    record("Diagnostics opens from the Window menu", diagnosticsOpened)
  }

  /// Labels, titles and string values of every element under `root`, read via KVC.
  static func accessibilityLabels(in root: NSObject, limit: Int = 8000) -> [String] {
    func read(_ object: NSObject, _ key: String) -> Any? {
      object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }
    var labels: [String] = []
    var queue: [NSObject] = [root]
    var seen = Set<ObjectIdentifier>()
    var visited = 0
    while !queue.isEmpty && visited < limit {
      let object = queue.removeFirst()
      guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
      visited += 1
      for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
        if let text = read(object, key) as? String, !text.isEmpty { labels.append(text) }
      }
      for child in read(object, "accessibilityChildren") as? [Any] ?? [] {
        if let child = child as? NSObject { queue.append(child) }
      }
    }
    return labels
  }

  private static func checkStatusItem() {
    let present = NSApp.windows.contains { String(describing: type(of: $0)).contains("NSStatusBarWindow") }
    record("menu bar item exists", present)
  }

  private static func identifier(of window: NSWindow) -> String {
    window.identifier?.rawValue ?? window.title
  }

  private static func renderWindows(suffix extra: String = "") async {
    let windows = appWindows()
    let titles = windows.map { identifier(of: $0) }
    record("main window is visible", titles.contains { $0.hasPrefix("main") }, titles.joined(separator: ", "))
    record("Diagnostics window is visible", titles.contains { $0.hasPrefix("diagnostics") }, titles.joined(separator: ", "))
    record("Settings window is visible", windows.contains { window in
      identifier(of: window).localizedCaseInsensitiveContains("settings") || window.title.localizedCaseInsensitiveContains("settings")
        || ["General", "Recording", "Camera", "Switcher", "Monitor", "Advanced"].contains(window.title)
    }, windows.map { "\(identifier(of: $0)) (\($0.title))" }.joined(separator: ", "))
    let previous = NSApp.appearance
    for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      NSApp.appearance = NSAppearance(named: appearanceName)
      await wait(0.6)
      for (index, window) in windows.enumerated() {
        let name = sanitized(titles[index]) + "-\(suffix)" + extra
        guard let frameView = window.contentView?.superview ?? window.contentView else { continue }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
          record("render \(name)", false, "no bitmap")
          continue
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let colors = distinctColors(rep)
        if let data = rep.representation(using: .png, properties: [:]) {
          try? data.write(to: output.appendingPathComponent("\(name).png"))
        }
        record("render \(name)", colors > 16, "\(rep.pixelsWide)×\(rep.pixelsHigh), \(colors) sampled colors")
      }
    }
    NSApp.appearance = previous
  }

  static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
    var colors = Set<UInt32>()
    let stepX = max(1, rep.pixelsWide / 64)
    let stepY = max(1, rep.pixelsHigh / 64)
    for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
      for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let r = UInt32(color.redComponent * 255), g = UInt32(color.greenComponent * 255), b = UInt32(color.blueComponent * 255)
        colors.insert(r << 16 | g << 8 | b)
      }
    }
    return colors.count
  }

  private static func sanitized(_ title: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    let cleaned = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    return String(cleaned).lowercased()
  }

  // MARK: Report

  private struct Report: Encodable {
    var pass: Bool
    var passed: Int
    var failed: Int
    var checks: [Check]
  }

  private static func finish() {
    let failed = checks.filter { !$0.pass }.count
    let report = Report(pass: failed == 0 && !checks.isEmpty, passed: checks.count - failed, failed: failed, checks: checks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report) {
      try? data.write(to: output.appendingPathComponent("report.json"))
    }
    NSApp.terminate(nil)
  }
}
