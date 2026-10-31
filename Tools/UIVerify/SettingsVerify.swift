import AppKit
import SwiftUI

/// Settings: eight tabs in order, each pane as tall as its content (no fixed heights), the tab
/// saved and reopened, "Settings › X" links choosing the tab, and every pane rendered at 820 pt
/// in its states. The real model; alert permission and shortcuts are fixtures, so nothing asks
/// macOS for permission or registers a global key.
@MainActor enum SettingsVerify {
  static func run(verifier: Verifier, model: AppModel, interface: UIInterfaceState, defaults: UserDefaults,
    render: (String, AnyView, CGSize) -> Void) {
    verifier.check("settings: eight tabs in order",
      UISettingsTab.allCases.map(\.title) == ["General", "Hardware", "Virtual Cameras", "Recording", "Audio", "Switching", "Alerts", "Advanced"],
      UISettingsTab.allCases.map(\.title).joined(separator: ", "))

    // The tab is saved and comes back; a link chooses it before opening.
    let previous = interface.settingsTab
    interface.settingsTab = .audio
    verifier.check("settings: reopens on the last tab", UIInterfaceState(defaults: defaults).settingsTab == .audio)
    var opened = 0
    var bridge = UISessionBridge(model: model, interface: interface)
    bridge.openSettings = { opened += 1 }
    bridge.perform(.openSettingsTab(.alerts))
    verifier.check("settings: a link opens Settings at its tab", interface.settingsTab == .alerts && opened == 1,
      "\(interface.settingsTab.rawValue), opened \(opened)")
    interface.settingsTab = previous

    let shortcuts = UIBackgroundShortcuts(defaults: defaults)
    let alerts = UIAlertPreferences(defaults: defaults)
    alerts.permission = UIAlertPermission(status: .allowed, banners: true, timeSensitive: false)

    // Each pane measures its content: the window takes that height, so panes differ.
    var heights: [UISettingsTab: CGFloat] = [:]
    for tab in UISettingsTab.allCases {
      let height = measure(pane(tab, model: model, interface: interface, shortcuts: shortcuts, alerts: alerts))
      heights[tab] = height
      verifier.check("settings: \(tab.title) is as tall as its content",
        height >= UISettingsLayout.minimumHeight && height != UISettingsLayout.initialHeight && height <= UISettingsLayout.maximumHeight,
        "\(Int(height)) pt", viewDependent: true)
      render("settings-\(tab.rawValue)", AnyView(pane(tab, model: model, interface: interface, shortcuts: shortcuts, alerts: alerts)),
        CGSize(width: UISettingsLayout.width, height: max(height, UISettingsLayout.minimumHeight)))
    }
    verifier.check("settings: the window resizes between tabs", Set(heights.values.map { Int($0) }).count >= 4,
      heights.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \(Int($0.value))" }.joined(separator: ", "),
      viewDependent: true)

    // Alerts in each permission state, read from the fixture.
    for (name, permission) in [("not-asked", UIAlertPermission(status: .notDetermined)), ("denied", UIAlertPermission(status: .denied))] {
      alerts.permission = permission
      let view = UISettingsAlertsPane(model: model, interface: interface, preferences: alerts)
      render("settings-alerts-\(name)", AnyView(view), CGSize(width: UISettingsLayout.width, height: measure(view)))
    }
    alerts.permission = UIAlertPermission(status: .notDetermined)
    let asking = HostedView(UISettingsAlertsPane(model: model, interface: interface, preferences: alerts),
      size: CGSize(width: UISettingsLayout.width, height: 700), dark: false)
    let askNodes = Accessibility.nodes(in: asking.host)
    asking.close()
    verifier.check("settings: alerts not yet asked offer Turn On Alerts",
      askNodes.contains { $0.text.contains("Turn On Alerts") }, "", viewDependent: true)

    // The tabs themselves, in the window as the scene shows them.
    interface.settingsTab = .general
    render("settings-window", AnyView(UISettingsView(model: model, interface: interface, shortcuts: shortcuts, alerts: alerts)),
      CGSize(width: UISettingsLayout.width, height: (heights[.general] ?? 400) + 60))
    interface.settingsTab = previous

    // Words the panes must carry.
    let expected: [(UISettingsTab, [String])] = [
      (.general, ["Show Ultracam in", "Ask before ending a recording or on-air video", "Use background shortcuts"]),
      (.virtualCameras, ["Program color"]),
      (.recording, ["Timecode", "Default folder", "Name pattern", "Camera subfolders"]),
      (.audio, ["True-peak warning", "As Detected"]),
      (.switching, ["Interval", "Minimum shot", "Advanced cut decisions", "Restore Defaults"]),
      (.alerts, ["Take ended early", "Alert panel", "Warn when time left is under"]),
      (.advanced, ["Allow CPU conversion (compatibility)", "Forget Saved LUTs…", "Reset…"]),
    ]
    for (tab, words) in expected {
      let hosted = HostedView(pane(tab, model: model, interface: interface, shortcuts: shortcuts, alerts: alerts),
        size: CGSize(width: UISettingsLayout.width, height: 900), dark: false)
      let text = Accessibility.nodes(in: hosted.host).map(\.text)
      hosted.close()
      let missing = words.filter { word in !text.contains { $0.contains(word) } }
      verifier.check("settings: \(tab.title) shows its rows", missing.isEmpty, "missing \(missing.joined(separator: ", "))",
        viewDependent: true)
    }
    // Gone from Settings: they live in the main window, the Diagnostics window or nowhere.
    var gone: [String] = []
    for tab in UISettingsTab.allCases {
      let hosted = HostedView(pane(tab, model: model, interface: interface, shortcuts: shortcuts, alerts: alerts),
        size: CGSize(width: UISettingsLayout.width, height: 900), dark: false)
      let text = Accessibility.nodes(in: hosted.host).map(\.text)
      hosted.close()
      for word in ["Codec", "Published Cameras", "Copy Diagnostics", "Open Diagnostics", "New camera strips", "Coming later",
        "Crash Recovery", "Automatic strategy", "Director mode", "Sync cameras"] where text.contains(where: { $0.contains(word) }) {
        gone.append("\(tab.title): \(word)")
      }
    }
    verifier.check("settings: rows that left Settings are gone", gone.isEmpty, gone.joined(separator: "; "), viewDependent: true)
  }

  static func pane(_ tab: UISettingsTab, model: AppModel, interface: UIInterfaceState, shortcuts: UIBackgroundShortcuts,
    alerts: UIAlertPreferences) -> some View {
    Group {
      switch tab {
      case .general: UISettingsGeneralPane(model: model, interface: interface, shortcuts: shortcuts)
      case .hardware: UISettingsHardwarePane(model: model, interface: interface)
      case .virtualCameras: UISettingsVirtualCamerasPane(model: model)
      case .recording: UISettingsRecordingPane(model: model, interface: interface)
      case .audio: UISettingsAudioPane(model: model, interface: interface)
      case .switching: UISettingsSwitchingPane(model: model)
      case .alerts: UISettingsAlertsPane(model: model, interface: interface, preferences: alerts)
      case .advanced: UISettingsAdvancedPane(model: model)
      }
    }
    .frame(width: UISettingsLayout.width)
  }

  /// The height a pane gives itself once its form has laid out, in a tall offscreen window.
  private final class Box { var height: CGFloat = 0 }

  static func measure<V: View>(_ view: V) -> CGFloat {
    let box = Box()
    let probe = VStack(spacing: 0) {
      view.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.height = $0 }
      Spacer(minLength: 0)
    }
    let hosted = HostedView(probe, size: CGSize(width: UISettingsLayout.width, height: 1600), dark: false)
    hosted.settle(0.6)
    hosted.close()
    return box.height
  }
}
