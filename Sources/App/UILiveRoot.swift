import SwiftUI

/// Builds a live `UIContext` from the app's models and hands it to its content.
/// Reading the models inside `body` lets Observation refresh the interface.
struct UILiveRoot<Content: View>: View {
  let model: AppModel
  let interface: UIInterfaceState
  @ViewBuilder let content: (UIContext) -> Content
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @ObservedObject private var monitor: MonitorCoordinator
  /// Running values for the views that show them (see UILiveTelemetry.swift); one for the window's life.
  @State private var live: UILiveSource

  init(model: AppModel, interface: UIInterfaceState, @ViewBuilder content: @escaping (UIContext) -> Content) {
    self.model = model
    self.interface = interface
    self.content = content
    _monitor = ObservedObject(wrappedValue: model.monitorCoordinator)
    _live = State(initialValue: UILiveSource(model: model, interface: interface))
  }

  var body: some View {
    let _ = UIRenderProbe.count("UILiveRoot")
    let bridge = UISessionBridge.live(model: model, interface: interface, openWindow: { openWindow(id: $0) },
      openSettings: { openSettings() })
    content(bridge.context())
      .environment(\.uiAudioMeters, UIAudioMeterSource { [model] in model.audioMeterTap(for: FeedID(rawValue: $0)) })
      .environment(\.uiLive, live)
  }
}

extension UISessionBridge {
  static func live(model: AppModel, interface: UIInterfaceState, openWindow: @escaping (String) -> Void = { _ in },
    openSettings: @escaping () -> Void = {}) -> UISessionBridge {
    var bridge = UISessionBridge(model: model, interface: interface)
    bridge.openWindow = openWindow
    bridge.openSettings = openSettings
    return bridge
  }

  func context() -> UIContext {
    var session = snapshot()
    // Its cameras alone can't tell "not installed" from "enabled, not started yet".
    session.install.system = model.installer.system
    let interface = self.interface
    let bridge = self
    return UIContext(session: session, presentation: UIPresentationBuilder.session(session),
      inputs: model.devices.map { UIInput(id: $0.id, name: $0.name) },
      send: { bridge.send($0) },
      pictures: UIAppPictures(model: model), monitor: UIAppMonitorSettings(model: model),
      confirmation: interface.confirmation,
      confirm: {
        if let pending = interface.confirmation { interface.confirmation = nil; bridge.send(pending.action, confirmed: true) }
      },
      cancelConfirmation: { interface.confirmation = nil },
      refreshed: { bridge.context() })
  }
}
