import AppKit
import Combine
import MonitorKit
import MonitorKitUI
import SwiftUI

/// Detached monitor windows. The main window and the menu bar use the new interface;
/// a detached window keeps this monitor tile with its full tool chrome.
private struct MonitorBoundTile: View {
  @ObservedObject var coordinator: MonitorCoordinator
  @ObservedObject var presenter: MonitorSurfacePresenter
  let surfaceID: UUID
  let target: MonitorTargetID
  let targetBinding: Binding<MonitorTargetID?>
  let preferences: Binding<MonitorFeedPreferences>
  var compact: Bool
  var focused = false
  @State private var scopeExpanded = false
  @State private var scopesVisible = true
  @State private var zoom = 1.0
  @State private var cleanBeforeHold: Bool?
  private var displayed: MonitorFeedPreferences {
    presenter.isFrozen ? presenter.shownPreferences : preferences.wrappedValue
  }
  private var previewEnabled: Bool { coordinator.isPreviewEnabled(for: target) }
  private var status: String { previewEnabled ? presenter.status : "Preview hidden" }
  var body: some View {
    MonitorDetachedChrome(
      target: targetBinding, preferences: preferences, choices: coordinator.targets, status: status,
      detail: presenter.detail + " · " + presenter.pictureInterpretation, compact: compact,
      frozenPreferences: presenter.isFrozen ? presenter.shownPreferences : nil, presenter: presenter,
      showsScopes: scopesVisible
    ) {
      if !previewEnabled {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay { Text("Preview hidden").foregroundStyle(.secondary) }
          .overlay { MonitorSurfaceVisibility(presenter: presenter).allowsHitTesting(false) }
      } else {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay {
            MonitorNativePicture(presenter: presenter)
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
          Button(presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze") {
            toggleFreeze()
          }
          .disabled(!previewEnabled)
          .keyboardShortcut(focused ? KeyboardShortcut("f", modifiers: [.control, .option]) : nil)
          Button(presenter.isClean ? "Decorated view" : "Clean view") { presenter.toggleClean() }
            .keyboardShortcut(focused ? KeyboardShortcut("c", modifiers: [.control, .option]) : nil)
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
            Button("Detach") { MonitorDetachedWindows.open(coordinator: coordinator, target: target) }
          }
        }.fixedSize(horizontal: true, vertical: false)
        HStack(spacing: 8) {
          Button(previewEnabled ? "Hide" : "Show") { coordinator.setPreviewEnabled(!previewEnabled, for: target) }
          Button(presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze") {
            toggleFreeze()
          }.disabled(!previewEnabled)
          Menu("View") {
            surfaceViewActions
            Button(presenter.isClean ? "Decorated view" : "Clean view") { presenter.toggleClean() }
            if !compact {
              Button("Detach") { MonitorDetachedWindows.open(coordinator: coordinator, target: target) }
            }
          }.menuStyle(.borderlessButton).fixedSize()
          Spacer(minLength: 0)
        }
      }.font(.caption).controlSize(.mini)
        .contextMenu {
          Button(presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze") {
            toggleFreeze()
          }
          .disabled(!previewEnabled)
          Button(presenter.isClean ? "Decorated view" : "Clean view") { presenter.toggleClean() }
          Button("Reset monitor tools") { coordinator.resetSettings(for: target) }
          Menu("Copy settings to") {
            ForEach(coordinator.targets.filter { $0.id != target }) { choice in
              Button(choice.title) { coordinator.copySettings(from: target, to: choice.id) }
            }
          }
        }
      MonitorDiagnosticsDisclosure(snapshot: coordinator.diagnostics(for: target), surfaceScopeTiming: presenter.scopeTiming)
    } scopes: {
      if previewEnabled {
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text("\(displayed.scopes.title) · \(scopeStageTitle)").font(.caption)
            Spacer()
            Button(scopeExpanded ? "Dock" : "Expand") { scopeExpanded.toggle() }.font(.caption)
          }
          MonitorNativeScope(presenter: presenter).frame(height: scopeExpanded ? 240 : 120)
            .overlay { ScopeIREScaleView(scale: displayed.scopes.ireScale, showsGrid: false) }
          Text(presenter.scopeTiming).font(.caption2).foregroundStyle(.secondary)
          Text(presenter.scopeInterpretation).font(.caption2).foregroundStyle(.secondary)
          Text(displayed.scopes.ireScale.caption).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .onAppear {
      presenter.setMagnification(.centered(zoom: zoom))
      register()
    }
    .onDisappear { coordinator.unregisterSurface(id: surfaceID, target: target) }
    .onChange(of: zoom) { _, value in presenter.setMagnification(.centered(zoom: value)) }
    .onChange(of: previewEnabled) { _, _ in register() }
    .onChange(of: presenter.isFreezePending) { _, _ in register() }
    .onChange(of: presenter.isFrozen) { _, _ in register() }
    .onChange(of: scopesVisible) { _, _ in register() }
    .onChange(of: preferences.wrappedValue.scopesShown) { _, _ in register() }
  }
  private var scopeStageTitle: String {
    if target.isProgram { return "Program Output" }
    switch displayed.scopes.settings.stage {
    case .source: return "Source"
    case .output: return "Output (LUT)"
    case .monitor: return "Monitor"
    }
  }
  @ViewBuilder private var surfaceViewActions: some View {
    if displayed.scopes.enabled {
      Button(scopesVisible ? "Hide scopes in this view" : "Show scopes in this view") { scopesVisible.toggle() }
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
      scopeVisible: preferences.wrappedValue.scopesShown && scopesVisible && !presenter.isFrozen && previewEnabled)
  }
}

/// The detached tile's chrome: target chooser and status, the picture, its signal
/// stage, MonitorKit's tile toolbar for the tools, the false-colour legend and the
/// scopes.
private struct MonitorDetachedChrome<Picture: View, Scopes: View>: View {
  @Binding var target: MonitorTargetID?
  @Binding var preferences: MonitorFeedPreferences
  var choices: [MonitorTargetOption]
  var status: String
  var detail = ""
  var compact = false
  /// The tools a held picture was frozen with.
  var frozenPreferences: MonitorFeedPreferences?
  var presenter: MonitorSurfacePresenter?
  var showsScopes = true
  @ViewBuilder var picture: () -> Picture
  @ViewBuilder var scopes: () -> Scopes

  private var isProgram: Bool { target?.isProgram == true }
  private var displayed: MonitorFeedPreferences { frozenPreferences ?? preferences }

  private static func stageTitle(_ stage: SignalStage) -> String {
    switch stage {
    case .source: return "Source"
    case .output: return "Output (LUT)"
    case .monitor: return "Monitor"
    }
  }

  var pictureCaption: String {
    let stage = isProgram ? "Program Output" : Self.stageTitle(displayed.state.pictureStage)
    if !isProgram && displayed.toolsEnabled && displayed.state.falseColor.mode != .off {
      return "False color: Source analysis · selected picture signal: \(stage)"
    }
    return "Picture: \(stage)"
  }

  /// The tools as the toolbar shows them: hidden while the master switch is off.
  /// A change turns the switch on for the tools that are then on; Clean View and
  /// magnification belong to this surface.
  private var toolState: Binding<MonitorState> {
    Binding(
      get: {
        var value = preferences
        if !value.toolsEnabled { value.hideAllTools() }
        return value.state
      },
      set: { state in
        var next = preferences
        if !next.toolsEnabled { next.hideAllTools() }
        next.state = state.persisted
        next.toolsEnabled = next.anyToolOn
        if next != preferences { preferences = next }
      })
  }

  private var unavailableTools: [MonitorTileTool: String] {
    guard isProgram else { return [:] }
    return [
      .focusPeaking: UIMonitorToolSettingsView.unavailableReason(.focus, isProgram: true) ?? "",
      .falseColor: UIMonitorToolSettingsView.unavailableReason(.falseColor, isProgram: true) ?? "",
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("Monitor target", selection: $target) {
          Text("Choose feed").tag(Optional<MonitorTargetID>.none)
          if let target, !choices.contains(where: { $0.id == target }) {
            Text("Missing feed").tag(Optional(target))
          }
          ForEach(choices) { Text($0.title).tag(Optional($0.id)) }
        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
      picture()
      HStack {
        Picker("Picture signal", selection: $preferences.state.pictureStage) {
          Text("Source").tag(SignalStage.source).disabled(isProgram)
          Text("Output (LUT)").tag(SignalStage.output)
          Text("Monitor").tag(SignalStage.monitor)
        }.controlSize(.mini)
      }
      Text(pictureCaption).font(.caption2)
      if frozenPreferences != nil {
        Text("Frozen · " + pictureCaption).font(.caption)
      }
      MonitorTileToolbar(
        state: toolState, name: target.flatMap { id in choices.first { $0.id == id }?.title } ?? "Monitor",
        signal: presenter?.shownSignal, status: presenter?.shownStatus,
        tools: [.guides, .zebra, .falseColor, .focusPeaking, .clipIndicators, .scopes],
        unavailable: unavailableTools, placement: .chrome,
        scopesEnabled: preferences.toolsEnabled && preferences.scopes.enabled,
        onScopes: { on in
          var next = preferences
          if !next.toolsEnabled { next.hideAllTools() }
          next.scopes.enabled = on
          next.toolsEnabled = next.anyToolOn
          preferences = next
        }
      )
      .disabled(target == nil)
      if !detail.isEmpty {
        Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if displayed.toolsEnabled && displayed.state.falseColor.mode != .off {
        if isProgram {
          Text("False Color unavailable for Program: source Log provenance is required").font(.caption2)
        } else if let legend = FalseColorLegend(settings: displayed.state.falseColor, signal: presenter?.shownSignal) {
          FalseColorLegendView(
            legend: legend, style: .captioned, unavailable: presenter?.shownStatus.reason(for: .falseColor))
        }
      }
      if displayed.toolsEnabled && displayed.state.focus.enabled {
        Text(isProgram ? "Focus unavailable for Program" : "Focus: Source").font(.caption2)
      }
      if showsScopes && displayed.scopesShown {
        scopes()
      }
    }.padding(7).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }
}

/// The detached tile's monitoring counters.
private struct MonitorDiagnosticsDisclosure: View {
  let snapshot: MonitorDiagnostics
  let surfaceScopeTiming: String
  var body: some View {
    DisclosureGroup("Monitoring diagnostics") {
      VStack(alignment: .leading, spacing: 3) {
        Text(
          "Camera \(rate(snapshot.requestedPictureHz)) Hz · offered \(rate(snapshot.offeredFPS)) fps · presented \(rate(snapshot.pictureFPS)) fps"
        )
        Text("Scopes requested \(snapshot.requestedScopeHz) Hz · drawn \(rate(snapshot.scopeFPS)) fps · every pixel")
        Text("Scopes skipped: GPU busy \(snapshot.scopeSkippedBusy) · no drawable \(snapshot.scopeSkippedNoDrawable)")
        Text(
          "GPU per picture \(milliseconds(snapshot.gpuMilliseconds)) · per scope \(milliseconds(snapshot.scopeGPUMilliseconds))"
        )
        Text(availability)
        Text(
          "Offered \(snapshot.offeredFrames) · presented \(snapshot.presentedFrames) · replaced before a refresh \(snapshot.supersededFrames) · failures \(snapshot.failures)"
        )
        Text("This surface: \(surfaceScopeTiming)")
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
    }.font(.caption2).foregroundStyle(.secondary)
  }
  private func rate(_ value: Double) -> String { String(format: "%.1f", value) }
  private func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.2f ms", $0) } ?? "—" }
  private var availability: String {
    switch snapshot.availability {
    case .noSignal: return "No signal"
    case .starting: return "Starting"
    case .live: return "Live"
    case .paused: return "Paused / hidden"
    case .stale: return "Stale"
    case .unsupported(let reason), .degraded(let reason), .failed(let reason): return reason
    }
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
    window.title = "Monitor · \(coordinator.targets.first(where: { $0.id == target })?.title ?? "Missing feed")"
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
        preferences: Binding(
          get: { coordinator.preferences(for: target) },
          set: { coordinator.setPreferences($0, for: target) }), compact: false
      ).id(target)
        .background(
          MonitorWindowTitle(
            title: "Monitor · \(coordinator.targets.first(where: { $0.id == target })?.title ?? "Missing feed")"))
    } else {
      MonitorDetachedChrome(
        target: $owner.target, preferences: .constant(MonitorFeedPreferences()),
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
