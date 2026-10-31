import AppKit
import SwiftUI

/// Settings › Alerts: what macOS lets Ultracam do, which events notify, how, and when a drive
/// counts as low. The permission is read from the notification center each time the pane
/// shows and when Ultracam comes back to the front, so it's never assumed.
struct UISettingsAlertsPane: View {
  let model: AppModel
  let interface: UIInterfaceState
  @Bindable var preferences: UIAlertPreferences

  var body: some View {
    let permission = preferences.permission
    let allowed = permission.status == .allowed
    UISettingsPane {
      Section("Permission") { permissionRow(permission) }

      Section("Notify Me About") {
        ForEach(UIAlertEvent.allCases, id: \.self) { event in
          Toggle(event.title, isOn: Binding(get: { preferences.notifies(event) }, set: { preferences.setNotifies(event, $0) }))
        }
      }
      // Events wait for permission: they dim until macOS allows notifications.
      .disabled(!allowed)

      Section("Delivery") {
        Toggle("Play a sound", isOn: $preferences.soundEnabled).disabled(!allowed)
        Toggle(isOn: $preferences.panelEnabled) {
          Text("Alert panel")
          Text("On-air camera lost, take ended early, or a camera stopped while on air")
        }
      }

      Section("Low Space") {
        Picker("Warn when time left is under", selection: $preferences.lowSpaceMinutes) {
          ForEach(UIAlertPreferences.lowSpaceChoices, id: \.self) { Text(Self.minutesTitle($0)).tag($0) }
        }
      }
    }
    .onAppear { preferences.refreshPermission?() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      preferences.refreshPermission?()
    }
  }

  @ViewBuilder private func permissionRow(_ permission: UIAlertPermission) -> some View {
    switch permission.status {
    case .allowed:
      LabeledContent {
        HStack(spacing: 6) {
          if permission.timeSensitive { chip("Time Sensitive") }
          chip(permission.banners ? "Banners" : "Notification Center only")
          openSystemSettings
        }
      } label: {
        Label { Text("Alerts are on") } icon: { Image(systemName: UISymbol.saved).foregroundStyle(.green) }
      }
    case .denied:
      LabeledContent {
        openSystemSettings
      } label: {
        Label { Text("Alerts are turned off in System Settings") } icon: {
          Image(systemName: UISymbol.warning).foregroundStyle(.orange)
        }
      }
    case .notDetermined:
      let live = UISessionBridge.live(model: model, interface: interface).presentation().isLive
      LabeledContent {
        Button("Turn On Alerts") { interface.turnOnAlerts?() }
          .disabled(live || interface.turnOnAlerts == nil)
          .help(live ? "Ultracam asks only while nothing is on air or rolling." : "macOS asks once.")
      } label: {
        Label { Text("Alerts aren’t on yet") } icon: { Image(systemName: UISymbol.alerts).foregroundStyle(.secondary) }
        Text("macOS asks once. Ultracam never asks while a camera is on air or rolling.")
      }
    case .unknown:
      LabeledContent("Checking with macOS…") { ProgressView().controlSize(.small) }
    }
  }

  private var openSystemSettings: some View {
    Button("Open System Settings") {
      if let url = UIUserNotifications.settingsURL { NSWorkspace.shared.open(url) }
    }
  }

  private func chip(_ text: String) -> some View {
    Text(text).font(.uiMeta).foregroundStyle(.secondary)
      .padding(.horizontal, 6).frame(minHeight: 18)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 5))
  }

  /// "30 minutes", "1 hour", "2 hours".
  static func minutesTitle(_ minutes: Int) -> String {
    guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes) minutes" }
    return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
  }
}
