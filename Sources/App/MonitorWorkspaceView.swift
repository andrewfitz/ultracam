import AppKit
import Combine
import MonitorKit
import MonitorKitUI
import SwiftUI

/// The detached tile's rules that are not drawing, internal so ui-verify checks them.
enum MonitorDetachedRules {
  static func stageTitle(_ stage: SignalStage) -> String {
    switch stage {
    case .source: return "Source"
    case .output: return "Output (LUT)"
    case .monitor: return "Monitor"
    }
  }

  /// The caption under the picture: its stage ("Program Output" on Program),
  /// or, with false colour on a camera, the stage false colour analyses (the
  /// Source for log modes, else the mode's own stage).
  static func pictureCaption(isProgram: Bool, preferences: MonitorFeedPreferences) -> String {
    let stage = isProgram ? "Program Output" : stageTitle(preferences.state.pictureStage)
    let mode = preferences.state.falseColor.mode
    if !isProgram && preferences.toolsEnabled && mode != .off {
      let analysed = stageTitle(mode.needsLogSource ? .source : preferences.state.falseColor.stage)
      return "False color: \(analysed) analysis · selected picture signal: \(stage)"
    }
    return "Picture: \(stage)"
  }

  /// Whether a tile registers its scope as visible: the feed's tools show
  /// scopes, this tile has not hidden them locally ("Hide Scopes in This
  /// View", which never changes the feed's tools), the picture is not held and
  /// the preview is shown.
  static func registersScope(preferences: MonitorFeedPreferences, locallyVisible: Bool, frozen: Bool,
    previewEnabled: Bool) -> Bool {
    preferences.scopesShown && locallyVisible && !frozen && previewEnabled
  }
}

/// Detached monitor windows. The main window and the menu bar use the new interface;
/// a detached window keeps this monitor tile with its full tool chrome.
private struct MonitorBoundTile: View {
  @ObservedObject var coordinator: MonitorCoordinator
  @ObservedObject var presenter: MonitorSurfacePresenter
  let surfaceID: UUID
  let target: MonitorTargetID
  let targetBinding: Binding<MonitorTargetID?>
  let preferences: Binding<MonitorFeedPreferences>
  var cameraControls: CameraControlStore?
  var compact: Bool
  var focused = false
  @State private var scopeExpanded = false
  @State private var scopesVisible = true
  @State private var zoom = 1.0
  @State private var cleanBeforeHold: Bool?
  /// The presenter's timing texts change twice a second (`MonitorSurfacePresenter.readout`).
  @State private var readoutRevision = 0
  private var displayed: MonitorFeedPreferences {
    presenter.isFrozen ? presenter.shownPreferences : preferences.wrappedValue
  }
  private var previewEnabled: Bool { coordinator.isPreviewEnabled(for: target) }
  private var status: String { previewEnabled ? presenter.status : "Preview hidden" }
  var body: some View {
    let _ = readoutRevision
    MonitorDetachedChrome(
      target: targetBinding, preferences: preferences, choices: coordinator.targets, status: status,
      detail: presenter.detail + " · " + presenter.pictureInterpretation, compact: compact,
      frozenPreferences: presenter.isFrozen ? presenter.shownPreferences : nil, presenter: presenter,
      showsScopes: scopesVisible
    ) {
      if !previewEnabled {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay { Text("Preview hidden").foregroundStyle(.white.opacity(0.6)) }
          .overlay { MonitorSurfaceVisibility(presenter: presenter).allowsHitTesting(false) }
      } else {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay {
            MonitorNativePicture(presenter: presenter)
            if presenter.status == "No signal" || presenter.status == "Camera stopped"
              || presenter.status == "Missing camera" || presenter.status == "Stale"
            {
              Text(presenter.status).foregroundStyle(.white.opacity(0.6))
            }
          }.clipped()
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          Button(previewEnabled ? "Hide Preview" : "Show Preview") {
            coordinator.setPreviewEnabled(!previewEnabled, for: target)
          }
          Button(presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze") {
            toggleFreeze()
          }
          .disabled(!previewEnabled)
          Button(presenter.isClean ? "Show Overlays" : "Clean View") { presenter.toggleClean() }
          Menu("View") { surfaceViewActions }
          if !compact {
            // Press and hold, with the pointer or Space once focused. VoiceOver can't hold, so
            // its press turns Clean View on or off.
            Text("Hold Clean").padding(.horizontal, 4).padding(.vertical, 2)
              .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
              .contentShape(Rectangle())
              .gesture(
                DragGesture(minimumDistance: 0).onChanged { _ in beginHoldClean() }.onEnded { _ in endHoldClean() }
              )
              .focusable(interactions: .activate)
              .onKeyPress(.space, phases: .all) { press in
                switch press.phase {
                case .down: beginHoldClean()
                case .up: endHoldClean()
                default: break
                }
                return .handled
              }
              .accessibilityAddTraits(.isButton)
              .accessibilityHint("Shows Clean View while held. Control-Option-C turns Clean View on or off.")
              .accessibilityAction { presenter.toggleClean() }
          }
          if !compact {
            Button("Detach to Window") { MonitorDetachedWindows.open(coordinator: coordinator, target: target, cameraControls: cameraControls) }
          }
        }.fixedSize(horizontal: true, vertical: false)
        HStack(spacing: 8) {
          Button(previewEnabled ? "Hide" : "Show") { coordinator.setPreviewEnabled(!previewEnabled, for: target) }
          Button(presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze") {
            toggleFreeze()
          }.disabled(!previewEnabled)
          Menu("View") {
            surfaceViewActions
            Button(presenter.isClean ? "Show Overlays" : "Clean View") { presenter.toggleClean() }
            if !compact {
              Button("Detach to Window") { MonitorDetachedWindows.open(coordinator: coordinator, target: target, cameraControls: cameraControls) }
            }
          }.menuStyle(.borderlessButton).fixedSize()
          Spacer(minLength: 0)
        }
      }.font(.uiMeta).controlSize(.small)
        .background {
          // ⌃⌥F and ⌃⌥C for this window while it is key, whichever row fits, and taken even
          // with the preview hidden, so they never reach the main window's selected camera.
          if focused {
            Group {
              Button("Freeze") { if previewEnabled { toggleFreeze() } }
                .keyboardShortcut("f", modifiers: [.control, .option])
              Button("Clean View") { presenter.toggleClean() }
                .keyboardShortcut("c", modifiers: [.control, .option])
            }
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
          }
        }
        .contextMenu {
          Button(presenter.isFreezePending ? "Cancel Freeze" : presenter.isFrozen ? "Unfreeze" : "Freeze") {
            toggleFreeze()
          }
          .disabled(!previewEnabled)
          Button(presenter.isClean ? "Show Overlays" : "Clean View") { presenter.toggleClean() }
          Button("Reset Monitor Tools") { coordinator.resetSettings(for: target) }
          Menu("Copy Monitor Settings To") {
            ForEach(coordinator.targets.filter { $0.id != target }) { choice in
              Button(choice.title) { coordinator.copySettings(from: target, to: choice.id) }
            }
          }
        }
      MonitorLiveDiagnostics(coordinator: coordinator, target: target) { MonitorDiagnosticsDisclosure(snapshot: $0, surfaceScopeTiming: presenter.scopeTiming) }
    } scopes: {
      if previewEnabled {
        UIScopePanel(
          description: scopeDescription, expanded: $scopeExpanded, statistics: presenter.scopeStatisticsReader,
          isLive: !presenter.isFrozen, timing: presenter.scopeTiming, interpretation: presenter.scopeInterpretation
        ) {
          MonitorNativeScope(presenter: presenter)
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
    .onReceive(presenter.readout.objectWillChange) { _ in readoutRevision &+= 1 }
  }
  /// What the shown scope measures: the frozen settings while frozen.
  private var scopeDescription: UIScopeDescription {
    UIScopeDescription(
      scopes: displayed.scopes, signal: presenter.shownSignal, stageLUT: presenter.scopeLUTSignal(displayed),
      isProgram: target.isProgram)
  }
  @ViewBuilder private var surfaceViewActions: some View {
    if displayed.scopes.enabled {
      Button(scopesVisible ? "Hide Scopes in This View" : "Show Scopes in This View") { scopesVisible.toggle() }
    }
    Picker("Zoom (Center Crop)", selection: $zoom) {
      Text("Fit").tag(1.0)
      Text("150%").tag(1.5)
      Text("200%").tag(2.0)
      Text("400%").tag(4.0)
    }
  }
  private func beginHoldClean() {
    if cleanBeforeHold == nil { cleanBeforeHold = presenter.isClean }
    presenter.setClean(true)
  }
  private func endHoldClean() {
    guard let before = cleanBeforeHold else { return }
    presenter.setClean(before)
    cleanBeforeHold = nil
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
      scopeVisible: MonitorDetachedRules.registersScope(preferences: preferences.wrappedValue,
        locallyVisible: scopesVisible, frozen: presenter.isFrozen, previewEnabled: previewEnabled))
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

  var pictureCaption: String { MonitorDetachedRules.pictureCaption(isProgram: isProgram, preferences: displayed) }

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

  /// The picture stage, with zebra measuring the picture shown.
  private var pictureStage: Binding<SignalStage> {
    Binding(
      get: { preferences.state.pictureStage },
      set: { stage in
        var next = preferences
        next.setPictureStage(stage)
        if next != preferences { preferences = next }
      })
  }

  private var unavailableTools: [MonitorTileTool: String] {
    guard isProgram else { return [:] }
    return [
      .focusPeaking: UIMonitorToolSettingsView.unavailableReason(.focus, isProgram: true) ?? "",
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("Monitor target", selection: $target) {
          Text("Choose camera").tag(Optional<MonitorTargetID>.none)
          if let target, !choices.contains(where: { $0.id == target }) {
            Text("Missing camera").tag(Optional(target))
          }
          ForEach(choices) { Text($0.title).tag(Optional($0.id)) }
        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        Text(status).font(.uiMeta).foregroundStyle(.secondary)
      }
      picture()
      HStack {
        Picker("Picture signal", selection: pictureStage) {
          Text("Source").tag(SignalStage.source).disabled(isProgram)
          Text("Output (LUT)").tag(SignalStage.output)
          Text("Monitor").tag(SignalStage.monitor)
        }.controlSize(.small)
      }
      if frozenPreferences != nil {
        Text("Frozen · " + pictureCaption).font(.uiMeta)
      } else {
        Text(pictureCaption).font(.uiMeta)
      }
      MonitorTileToolbar(
        state: toolState, name: target.flatMap { id in choices.first { $0.id == id }?.title } ?? "Monitor",
        signal: presenter?.shownSignal, status: presenter?.shownStatus,
        tools: [.guides, .zebra, .falseColor, .focusPeaking, .clipIndicators, .scopes],
        unavailable: unavailableTools, falseColorModes: isProgram ? [.sixBand, .custom] : nil, layout: presenter?.shownLayout, placement: .chrome,
        scopesEnabled: preferences.toolsEnabled && preferences.scopes.enabled,
        onScopes: { on in
          var next = preferences
          if !next.toolsEnabled { next.hideAllTools() }
          next.scopes.enabled = on
          next.toolsEnabled = next.anyToolOn
          preferences = next
        }
      ) {
        UIScopeSettingsView(
          scopes: $preferences.scopes, isProgram: isProgram, signal: presenter?.shownSignal,
          stageLUT: presenter?.scopeLUTSignal(preferences))
      }
      .disabled(target == nil)
      if !detail.isEmpty {
        Text(detail).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if displayed.toolsEnabled && displayed.state.falseColor.mode != .off {
        if isProgram && displayed.state.falseColor.mode.needsLogSource {
          Text("Program is not a camera signal, so log false color is off. Six band and custom bands work on Program.")
            .font(.uiMeta)
        } else if let legend = FalseColorLegend(settings: displayed.state.falseColor, signal: presenter?.shownSignal,
          layout: presenter?.shownLayout) {
          FalseColorLegendView(
            legend: legend, style: .captioned, unavailable: presenter?.shownStatus.reason(for: .falseColor))
        }
      }
      if displayed.toolsEnabled && displayed.state.focus.enabled {
        Text(isProgram ? "Focus unavailable for Program" : "Focus: Source").font(.uiMeta)
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
        if let lut = MonitorFeedHost.describe(snapshot.monitorLUT) { Text(lut) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
    }.font(.uiMeta).foregroundStyle(.secondary)
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
  static func open(coordinator: MonitorCoordinator, target: MonitorTargetID,
    cameraControls: CameraControlStore? = nil) -> MonitorWindowOwner {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "Monitor · \(coordinator.targets.first(where: { $0.id == target })?.title ?? "Missing camera")"
    window.isReleasedWhenClosed = false
    let id = UUID()
    let owner = MonitorWindowOwner(window: window, target: target) {
      windows.removeValue(forKey: id)
    }
    window.contentView = NSHostingView(
      rootView: DetachedMonitorContent(coordinator: coordinator, owner: owner, cameraControls: cameraControls).padding(12))
    // A camera's window opens where it was last left. A second window on the same camera
    // can't take the name (AppKit refuses a name in use), so it opens centred.
    let autosaveName = "Monitor Window \(target.rawValue)"
    let restored = window.setFrameAutosaveName(autosaveName) && window.setFrameUsingName(autosaveName)
    if !restored { window.center() }
    // Never exactly on top of another detached window: step down and right, as AppKit cascades.
    let taken = Set(windows.values.map { [$0.window.frame.minX, $0.window.frame.maxY] })
    for _ in 0..<windows.count where taken.contains([window.frame.minX, window.frame.maxY]) {
      window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX + 22, y: window.frame.maxY - 22))
    }
    windows[id] = owner
    window.delegate = owner
    window.makeKeyAndOrderFront(nil)
    return owner
  }
}

@MainActor final class MonitorWindowOwner: NSObject, NSWindowDelegate, ObservableObject {
  let window: NSWindow
  @Published var target: MonitorTargetID?
  /// While this window is key, its Freeze and Clean View take ⌃⌥F and ⌃⌥C, which otherwise
  /// reach the View menu and the main window's selected camera.
  @Published private(set) var isKey = false
  let close: () -> Void
  init(window: NSWindow, target: MonitorTargetID, close: @escaping () -> Void) {
    self.window = window
    self.target = target
    self.close = close
  }
  func windowDidBecomeKey(_ notification: Notification) { isKey = true }
  func windowDidResignKey(_ notification: Notification) { isKey = false }
  func windowWillClose(_ notification: Notification) {
    window.contentView = nil
    close()
  }
}

private struct DetachedMonitorContent: View {
  @ObservedObject var coordinator: MonitorCoordinator
  @ObservedObject var owner: MonitorWindowOwner
  var cameraControls: CameraControlStore?
  @State private var surfaceID = UUID()
  var body: some View {
    if let target = owner.target {
      MonitorBoundTile(
        coordinator: coordinator, presenter: coordinator.surface(id: surfaceID, target: target),
        surfaceID: surfaceID, target: target, targetBinding: $owner.target,
        preferences: Binding(
          get: { coordinator.preferences(for: target) },
          set: { coordinator.setPreferences($0, for: target) }), cameraControls: cameraControls, compact: false,
        focused: owner.isKey
      ).id(target)
        .background(
          MonitorWindowTitle(
            title: "Monitor · \(coordinator.targets.first(where: { $0.id == target })?.title ?? "Missing camera")"))
    } else {
      MonitorDetachedChrome(
        target: $owner.target, preferences: .constant(MonitorFeedPreferences()),
        choices: coordinator.targets, status: "No signal", compact: false
      ) {
        Rectangle().fill(.black).aspectRatio(16.0 / 9, contentMode: .fit)
          .overlay { Text("Choose a camera or Program").foregroundStyle(.white.opacity(0.6)) }
      } scopes: {
        EmptyView()
      }
      .background(MonitorWindowTitle(title: "Monitor · Choose a camera"))
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
