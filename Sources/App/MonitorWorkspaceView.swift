import AppKit
import Combine
import MonitorToolsCore
import MonitorToolsUI
import SwiftUI

/// Detached monitor windows. The main window and the menu bar use the new interface;
/// a detached window keeps this monitor tile with its full tool chrome.
private struct MonitorBoundTile: View {
  @ObservedObject var coordinator: MonitorCoordinator
  @ObservedObject var presenter: MonitorSurfacePresenter
  let surfaceID: UUID
  let target: MonitorTargetID
  let targetBinding: Binding<MonitorTargetID?>
  let configuration: Binding<MonitorConfiguration>
  var compact: Bool
  var focused = false
  var model: AppModel? = nil
  @State private var scopeExpanded = false
  @State private var scopesVisible = true
  @State private var zoom = 1.0
  @State private var cleanBeforeHold: Bool?
  private var displayConfiguration: MonitorConfiguration {
    presenter.isFrozen ? presenter.configuration : configuration.wrappedValue
  }
  private var previewEnabled: Bool { coordinator.isPreviewEnabled(for: target) }
  private var status: String { previewEnabled ? presenter.status : "Preview hidden" }
  var body: some View {
    MonitorTileChrome(
      target: targetBinding, configuration: configuration, choices: coordinator.targets,
      status: status,
      detail: presenter.detail + " · " + presenter.pictureInterpretation, compact: compact,
      legendConfiguration: presenter.isFrozen ? presenter.configuration : nil,
      showsScopes: scopesVisible
    ) {
      if !previewEnabled {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay { Text("Preview hidden").foregroundStyle(.secondary) }
          .overlay { MonitorSurfaceVisibility(presenter: presenter).allowsHitTesting(false) }
      } else {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay {
            ZStack {
              MonitorNativePicture(presenter: presenter)
              if (presenter.isFrozen ? presenter.configuration : configuration.wrappedValue)
                .toolsEnabled
                && (presenter.isFrozen ? presenter.configuration : configuration.wrappedValue)
                  .guides
                  .enabled
                && !presenter.isClean
              {
                MonitorGuideOverlay(
                  settings: (presenter.isFrozen
                    ? presenter.configuration : configuration.wrappedValue).guides
                )
                .aspectRatio(presenter.pictureAspectRatio, contentMode: .fit)
              }
            }.modifier(MonitorPictureZoom(zoom))
            if presenter.status == "No Signal" || presenter.status == "Feed stopped"
              || presenter.status == "Missing feed" || presenter.status == "Stale"
            {
              Text(presenter.status).foregroundStyle(.secondary)
            }
          }.clipped()
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          Button(previewEnabled ? "Hide preview" : "Show preview") {
            coordinator.setPreviewEnabled(!previewEnabled, for: target)
          }
          Button(
            presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze"
          ) { toggleFreeze() }
          .disabled(!previewEnabled)
          .keyboardShortcut(focused ? KeyboardShortcut("f", modifiers: [.control, .option]) : nil)
          Button(presenter.isClean ? "Decorated view" : "Clean view") { presenter.toggleClean() }
            .keyboardShortcut(
              focused ? KeyboardShortcut("c", modifiers: [.control, .option]) : nil)
          Menu("View") { surfaceViewActions }
          if !compact {
            Text("Hold Clean").padding(.horizontal, 4).padding(.vertical, 2)
              .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
              .gesture(
                DragGesture(minimumDistance: 0).onChanged { _ in
                  if cleanBeforeHold == nil { cleanBeforeHold = presenter.isClean }
                  presenter.setClean(true)
                }.onEnded { _ in
                  presenter.setClean(cleanBeforeHold ?? false)
                  cleanBeforeHold = nil
                }
              )
              .accessibilityLabel("Hold for clean view; Control Option C toggles clean view")
          }
          if !compact {
            Button("Detach") {
              MonitorDetachedWindows.open(coordinator: coordinator, target: target)
            }
          }
        }.fixedSize(horizontal: true, vertical: false)
        HStack(spacing: 8) {
          Button(previewEnabled ? "Hide" : "Show") {
            coordinator.setPreviewEnabled(!previewEnabled, for: target)
          }
          Button(
            presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze"
          ) { toggleFreeze() }.disabled(!previewEnabled)
          Menu("View") {
            surfaceViewActions
            Button(presenter.isClean ? "Decorated view" : "Clean view") { presenter.toggleClean() }
            if !compact {
              Button("Detach") {
                MonitorDetachedWindows.open(coordinator: coordinator, target: target)
              }
            }
          }.menuStyle(.borderlessButton).fixedSize()
          Spacer(minLength: 0)
        }
      }.font(.caption).controlSize(.mini)
        .contextMenu {
          Button(
            presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze"
          ) { toggleFreeze() }
          .disabled(!previewEnabled)
          Button(presenter.isClean ? "Decorated view" : "Clean view") { presenter.toggleClean() }
          Button("Reset monitor tools") { configuration.wrappedValue = MonitorConfiguration() }
          Menu("Copy settings to") {
            ForEach(coordinator.targets.filter { $0.id != target }) { choice in
              Button(choice.title) { coordinator.copySettings(from: target, to: choice.id) }
            }
          }
        }
      MonitorDiagnosticsView(
        snapshot: coordinator.diagnostics(for: target), surfaceScopeTiming: presenter.scopeTiming)
    } scopes: {
      if previewEnabled {
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(
              "\(displayConfiguration.scopes.mode == .rgbParade ? "RGB parade" : "Luma waveform") · \(target.rawValue == "program" ? "Program Output" : displayConfiguration.scopeStage == .source ? "Source" : "Processed Output")"
            ).font(.caption)
            Spacer()
            Button(scopeExpanded ? "Dock" : "Expand") { scopeExpanded.toggle() }.font(.caption)
          }
          MonitorNativeScope(presenter: presenter).frame(height: scopeExpanded ? 240 : 120)
            .overlay { MonitorScopeGraticule(showGrid: displayConfiguration.scopes.graticule) }
          Text(presenter.scopeTiming).font(.caption2).foregroundStyle(.secondary)
          Text(presenter.scopeInterpretation).font(.caption2).foregroundStyle(.secondary)
          Text("Sampled signal · −10…110 IRE · endpoints clamp outside scale").font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .onAppear { register() }
    .onDisappear { coordinator.unregisterSurface(id: surfaceID, target: target) }
    .onChange(of: previewEnabled) { _, _ in register() }
    .onChange(of: presenter.isFreezePending) { _, _ in register() }
    .onChange(of: presenter.isFrozen) { _, _ in register() }
    .onChange(of: scopesVisible) { _, _ in register() }
    .onChange(of: configuration.wrappedValue.scopes.enabled) { _, _ in register() }
    .onChange(of: configuration.wrappedValue.toolsEnabled) { _, _ in register() }
  }
  @ViewBuilder private var surfaceViewActions: some View {
    if displayConfiguration.scopes.enabled {
      Button(scopesVisible ? "Hide scopes in this view" : "Show scopes in this view") {
        scopesVisible.toggle()
      }
    }
    Picker("Picture zoom (center crop)", selection: $zoom) {
      Text("Fit").tag(1.0)
      Text("150%").tag(1.5)
      Text("200%").tag(2.0)
      Text("400%").tag(4.0)
    }
  }
  private func toggleFreeze() {
    if presenter.isFreezePending {
      presenter.cancelPendingFreeze()
    } else {
      presenter.toggleFreeze()
    }
    register()
  }
  private func register() {
    coordinator.registerSurface(
      id: surfaceID, target: target, isVisible: previewEnabled,
      scopeVisible: configuration.wrappedValue.toolsEnabled
        && configuration.wrappedValue.scopes.enabled && scopesVisible && !presenter.isFrozen
        && previewEnabled)
  }
}

@MainActor enum MonitorDetachedWindows {
  private static var windows: [UUID: MonitorWindowOwner] = [:]
  @discardableResult
  static func open(coordinator: MonitorCoordinator, target: MonitorTargetID) -> MonitorWindowOwner {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title =
      "Monitor · \(coordinator.targets.first(where: { $0.id == target })?.title ?? "Missing feed")"
    window.isReleasedWhenClosed = false
    let id = UUID()
    let owner = MonitorWindowOwner(window: window, target: target) {
      windows.removeValue(forKey: id)
    }
    window.contentView = NSHostingView(
      rootView: DetachedMonitorContent(coordinator: coordinator, owner: owner).padding(12))
    windows[id] = owner
    window.delegate = owner
    window.center()
    window.makeKeyAndOrderFront(nil)
    return owner
  }
}

@MainActor final class MonitorWindowOwner: NSObject, NSWindowDelegate, ObservableObject {
  let window: NSWindow
  @Published var target: MonitorTargetID?
  let close: () -> Void
  init(window: NSWindow, target: MonitorTargetID, close: @escaping () -> Void) {
    self.window = window
    self.target = target
    self.close = close
  }
  func windowWillClose(_ notification: Notification) {
    window.contentView = nil
    close()
  }
}

private struct DetachedMonitorContent: View {
  @ObservedObject var coordinator: MonitorCoordinator
  @ObservedObject var owner: MonitorWindowOwner
  @State private var surfaceID = UUID()
  var body: some View {
    if let target = owner.target {
      MonitorBoundTile(
        coordinator: coordinator, presenter: coordinator.surface(id: surfaceID, target: target),
        surfaceID: surfaceID, target: target, targetBinding: $owner.target,
        configuration: Binding(
          get: { coordinator.configuration(for: target) },
          set: { coordinator.setConfiguration($0, for: target) }), compact: false
      ).id(target)
        .background(
          MonitorWindowTitle(
            title:
              "Monitor · \(coordinator.targets.first(where: { $0.id == target })?.title ?? "Missing feed")"
          ))
    } else {
      MonitorTileChrome(
        target: $owner.target, configuration: .constant(MonitorConfiguration()),
        choices: coordinator.targets, status: "No Signal", compact: false
      ) {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay { Text("Choose a feed or Program").foregroundStyle(.secondary) }
      } scopes: {
        EmptyView()
      }
      .background(MonitorWindowTitle(title: "Monitor · Choose a feed"))
    }
  }
}

/// The tray owns its target choice independently of main-window tile bindings.
private struct MonitorWindowTitle: NSViewRepresentable {
  let title: String
  func makeNSView(context: Context) -> MonitorTitleNSView { MonitorTitleNSView(title: title) }
  func updateNSView(_ view: MonitorTitleNSView, context: Context) {
    view.title = title
    view.window?.title = title
  }
}
private final class MonitorTitleNSView: NSView {
  var title: String
  init(title: String) {
    self.title = title
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.title = title
  }
}
