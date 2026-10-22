import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import SwiftUI

/// One source's picture with its own tools, as a SwiftUI view: a
/// `MonitorMetalView` in convenience mode with one full-size surface.
///
/// `state` is the surface's state both ways: edits flow in, gestures (pinch,
/// scroll, drag, double click) flow back out normalized. Hand frames to `source`
/// from any thread. Pass the app's `queue` so views share one; a view makes its
/// own only when none is given. Pass a render thread's `displayLinkRunLoop` to
/// keep the ticks off the main thread (a main-thread hitch then drops no monitor
/// frame). Host metadata (timecode, tally, format, LUT name) goes in an
/// `.overlay { MonitorStatusOverlay(model: …) }`: with a `MonitorOverlayModel` a
/// timecode tick redraws only the overlay's text, not this view.
///
/// Each `MonitorView` and `ScopeView` is its own renderer: two of one source each
/// run their own focus analysis and scope accumulation. To compute them once,
/// show the source's pictures and scopes as regions of one scene
/// (`MonitorSceneView` with a `MonitorMetalView`, or `ScopeStackView` for scopes).
public struct MonitorView {
  let engine: MonitorEngine
  let source: MonitorSource
  @Binding var state: MonitorState
  let outputColor: MonitorOutputColor
  let queue: MTLCommandQueue?
  let configuration: MonitorMetalViewConfiguration
  let displayLinkRunLoop: RunLoop
  let onStatusChange: ((MonitorStatus) -> Void)?

  public init(
    engine: MonitorEngine, source: MonitorSource, state: Binding<MonitorState>,
    outputColor: MonitorOutputColor = .signalNative, queue: MTLCommandQueue? = nil,
    configuration: MonitorMetalViewConfiguration = MonitorMetalViewConfiguration(),
    displayLinkRunLoop: RunLoop = .main, onStatusChange: ((MonitorStatus) -> Void)? = nil
  ) {
    self.engine = engine
    self.source = source
    _state = state
    self.outputColor = outputColor
    self.queue = queue
    self.configuration = configuration
    self.displayLinkRunLoop = displayLinkRunLoop
    self.onStatusChange = onStatusChange
  }

  @MainActor public final class Coordinator {
    var surface: MonitorSurface?
    /// The state last handed to the surface or received from it, so an unchanged
    /// binding never bumps the surface's revision.
    var lastExchanged: MonitorState?
    /// The output colour last handed to the scene: an update with the same one
    /// (a parent redrawn for its own reasons) touches nothing.
    var lastOutputColor: MonitorOutputColor?
    var state: Binding<MonitorState>
    var onStatusChange: ((MonitorStatus) -> Void)?

    init(state: Binding<MonitorState>) { self.state = state }
  }

  @MainActor public func makeCoordinator() -> Coordinator { Coordinator(state: $state) }

  @MainActor func make(_ coordinator: Coordinator) -> MonitorMetalView {
    let surface = MonitorSurface(source: source, state: state)
    let scene = MonitorScene(surfaces: [surface])
    scene.outputColor = outputColor
    coordinator.lastOutputColor = outputColor
    let view = MonitorMetalView(
      engine: engine, scene: scene, mode: .convenience(queue: queue), configuration: configuration,
      displayLinkRunLoop: displayLinkRunLoop)
    coordinator.surface = surface
    coordinator.lastExchanged = state
    view.onSurfaceStateChange = { [weak coordinator] s in
      guard let coordinator else { return }
      let next = s.state
      coordinator.lastExchanged = next
      coordinator.state.wrappedValue = next
    }
    view.onStatusChange = { [weak coordinator] in
      guard let coordinator, let surface = coordinator.surface else { return }
      coordinator.onStatusChange?(surface.status)
    }
    update(view, coordinator)
    return view
  }

  @MainActor func update(_ view: MonitorMetalView, _ coordinator: Coordinator) {
    coordinator.state = $state
    coordinator.onStatusChange = onStatusChange
    if coordinator.surface?.source !== source {
      let surface = MonitorSurface(source: source, state: state)
      coordinator.surface = surface
      coordinator.lastExchanged = state
      view.scene.surfaces = [surface]
    } else if state != coordinator.lastExchanged {
      coordinator.surface?.state = state
      coordinator.lastExchanged = state
    }
    if outputColor != coordinator.lastOutputColor {
      view.scene.outputColor = outputColor
      coordinator.lastOutputColor = outputColor
    }
  }
}

#if canImport(AppKit)
  extension MonitorView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MonitorMetalView { make(context.coordinator) }
    public func updateNSView(_ view: MonitorMetalView, context: Context) { update(view, context.coordinator) }
  }
#elseif canImport(UIKit)
  extension MonitorView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MonitorMetalView { make(context.coordinator) }
    public func updateUIView(_ view: MonitorMetalView, context: Context) { update(view, context.coordinator) }
  }
#endif

/// Hosts a `MonitorMetalView` the app built (several surfaces, scopes, host mode).
public struct MonitorSceneView {
  let view: MonitorMetalView

  public init(view: MonitorMetalView) { self.view = view }
}

#if canImport(AppKit)
  extension MonitorSceneView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MonitorMetalView { view }
    public func updateNSView(_ view: MonitorMetalView, context: Context) {}
  }
#elseif canImport(UIKit)
  extension MonitorSceneView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MonitorMetalView { view }
    public func updateUIView(_ view: MonitorMetalView, context: Context) {}
  }
#endif

/// A scope of a source's displayed frames, drawn by `ScopeRenderer` in a Metal
/// view, with the graticule's labels drawn as SwiftUI text over it.
///
/// It accumulates the frames it displays (latest frame wins, like the picture),
/// at most once per `accumulationInterval` (0: every new frame). Analysis that
/// needs every frame belongs in the host's pipeline. Without a `scopeEngine`
/// every scope view of one `MonitorEngine` shares the engine's
/// (`MonitorRenderer.sharedScopeEngine(for:)`), built off the main thread when
/// the first one appears; pass one built up front to have the scope on the first
/// frame. Several scopes of one source belong in one `ScopeStackView`: they are
/// then accumulated together, each pixel decoded once.
public struct ScopeView: View {
  let engine: MonitorEngine
  let scopeEngine: ScopeEngine?
  let source: MonitorSource
  let settings: ScopeSettings
  let monitorLUTEnabled: Bool
  let outputColor: MonitorOutputColor
  let queue: MTLCommandQueue?
  let showsLabels: Bool
  let accumulationInterval: Double
  let displayLinkRunLoop: RunLoop
  @State private var labels: [[ScopeLabel]] = []

  public init(
    engine: MonitorEngine, scopeEngine: ScopeEngine? = nil, source: MonitorSource, settings: ScopeSettings,
    monitorLUTEnabled: Bool = true, outputColor: MonitorOutputColor = .signalNative, queue: MTLCommandQueue? = nil,
    showsLabels: Bool = true, accumulationInterval: Double = 0, displayLinkRunLoop: RunLoop = .main
  ) {
    self.engine = engine
    self.scopeEngine = scopeEngine
    self.source = source
    self.settings = settings
    self.monitorLUTEnabled = monitorLUTEnabled
    self.outputColor = outputColor
    self.queue = queue
    self.showsLabels = showsLabels
    self.accumulationInterval = accumulationInterval
    self.displayLinkRunLoop = displayLinkRunLoop
  }

  public var body: some View {
    ZStack {
      ScopeLayer(
        engine: engine, scopeEngine: scopeEngine, source: source, settings: [settings], regions: [.full],
        monitorLUTEnabled: monitorLUTEnabled, outputColor: outputColor, queue: queue,
        accumulationInterval: accumulationInterval, displayLinkRunLoop: displayLinkRunLoop, labels: $labels)
      if showsLabels {
        ScopeLabelsView(labels: labels.first ?? []).allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityName(settings))
  }

  static func accessibilityName(_ s: ScopeSettings) -> String {
    switch s.kind {
    case .waveform: return "Waveform"
    case .vectorscope: return "Vectorscope"
    case .histogram: return "Histogram"
    }
  }
}

/// Several scopes of one source side by side (or stacked) in one Metal view:
/// one renderer, one display link and one command buffer per tick, and the
/// scopes accumulated together in one `ScopeGroup` (a waveform, vectorscope and
/// histogram of a stage decode each pixel once), instead of a `ScopeView` each.
public struct ScopeStackView: View {
  let engine: MonitorEngine
  let scopeEngine: ScopeEngine?
  let source: MonitorSource
  let settings: [ScopeSettings]
  let axis: Axis
  let monitorLUTEnabled: Bool
  let outputColor: MonitorOutputColor
  let queue: MTLCommandQueue?
  let showsLabels: Bool
  let accumulationInterval: Double
  let displayLinkRunLoop: RunLoop
  @State private var labels: [[ScopeLabel]] = []
  @Environment(\.displayScale) private var displayScale

  public init(
    engine: MonitorEngine, scopeEngine: ScopeEngine? = nil, source: MonitorSource, settings: [ScopeSettings],
    axis: Axis = .horizontal, monitorLUTEnabled: Bool = true, outputColor: MonitorOutputColor = .signalNative,
    queue: MTLCommandQueue? = nil, showsLabels: Bool = true, accumulationInterval: Double = 0,
    displayLinkRunLoop: RunLoop = .main
  ) {
    self.engine = engine
    self.scopeEngine = scopeEngine
    self.source = source
    self.settings = settings
    self.axis = axis
    self.monitorLUTEnabled = monitorLUTEnabled
    self.outputColor = outputColor
    self.queue = queue
    self.showsLabels = showsLabels
    self.accumulationInterval = accumulationInterval
    self.displayLinkRunLoop = displayLinkRunLoop
  }

  /// `count` equal tiles along `axis`.
  public static func regions(count: Int, axis: Axis) -> [MonitorRegion] {
    guard count > 0 else { return [] }
    let step = 1 / Double(count)
    return (0..<count).map { i in
      axis == .horizontal
        ? MonitorRegion(x: Double(i) * step, y: 0, width: step, height: 1)
        : MonitorRegion(x: 0, y: Double(i) * step, width: 1, height: step)
    }
  }

  public var body: some View {
    let regions = Self.regions(count: settings.count, axis: axis)
    ZStack(alignment: .topLeading) {
      ScopeLayer(
        engine: engine, scopeEngine: scopeEngine, source: source, settings: settings, regions: regions,
        monitorLUTEnabled: monitorLUTEnabled, outputColor: outputColor, queue: queue,
        accumulationInterval: accumulationInterval, displayLinkRunLoop: displayLinkRunLoop, labels: $labels)
      if showsLabels {
        // Each scope's labels over the pixels its region draws into (the renderer's rounding).
        GeometryReader { geo in
          ForEach(regions.indices, id: \.self) { i in
            if i < labels.count, let rect = MonitorStatusOverlay.frame(of: regions[i], in: geo.size, scale: displayScale) {
              ScopeLabelsView(labels: labels[i])
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
          }
        }
        .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(settings.map(ScopeView.accessibilityName).joined(separator: ", "))
  }
}

/// Graticule labels at their normalized positions and anchors.
public struct ScopeLabelsView: View {
  let labels: [ScopeLabel]

  public init(labels: [ScopeLabel]) { self.labels = labels }

  static func anchor(_ a: ScopeLabelAnchor) -> UnitPoint {
    switch a {
    case .leading: return UnitPoint(x: 0, y: 0.5)
    case .top: return UnitPoint(x: 0.5, y: 0)
    case .bottom: return UnitPoint(x: 0.5, y: 1)
    case .center: return .center
    }
  }

  public var body: some View {
    Canvas { context, size in
      for label in labels {
        let text = Text(label.text)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(Color.white.opacity(label.isMajor ? 0.8 : 0.55))
        let point = CGPoint(x: label.position.x * size.width, y: label.position.y * size.height)
        context.draw(text, at: point, anchor: Self.anchor(label.anchor))
      }
    }
  }
}

/// One Metal view drawing `settings[i]` of `source` in `regions[i]`.
struct ScopeLayer {
  let engine: MonitorEngine
  let scopeEngine: ScopeEngine?
  let source: MonitorSource
  let settings: [ScopeSettings]
  let regions: [MonitorRegion]
  let monitorLUTEnabled: Bool
  let outputColor: MonitorOutputColor
  let queue: MTLCommandQueue?
  let accumulationInterval: Double
  let displayLinkRunLoop: RunLoop
  @Binding var labels: [[ScopeLabel]]

  @MainActor final class Coordinator {
    var overlays: [MonitorScopeOverlay] = []
    var lastOutputColor: MonitorOutputColor?
    var labels: Binding<[[ScopeLabel]]>
    init(labels: Binding<[[ScopeLabel]]>) { self.labels = labels }
  }

  @MainActor func makeCoordinator() -> Coordinator { Coordinator(labels: $labels) }

  @MainActor func makeOverlays() -> [MonitorScopeOverlay] {
    var out: [MonitorScopeOverlay] = []
    var i = 0
    while i < min(settings.count, regions.count) {
      out.append(
        MonitorScopeOverlay(
          source: source, settings: settings[i], region: regions[i], monitorLUTEnabled: monitorLUTEnabled,
          accumulationInterval: accumulationInterval))
      i += 1
    }
    return out
  }

  @MainActor func make(_ coordinator: Coordinator) -> MonitorMetalView {
    let overlays = makeOverlays()
    let scene = MonitorScene(scopes: overlays)
    scene.outputColor = outputColor
    coordinator.lastOutputColor = outputColor
    let view = MonitorMetalView(
      engine: engine, scene: scene, mode: .convenience(queue: queue),
      configuration: MonitorMetalViewConfiguration(gesturesEnabled: false), scopeEngine: scopeEngine,
      displayLinkRunLoop: displayLinkRunLoop)
    coordinator.overlays = overlays
    view.onGraticuleChange = { [weak coordinator] in
      guard let coordinator else { return }
      coordinator.labels.wrappedValue = coordinator.overlays.map { $0.graticule?.labels ?? [] }
    }
    return view
  }

  @MainActor func update(_ view: MonitorMetalView, _ coordinator: Coordinator) {
    coordinator.labels = $labels
    let count = min(settings.count, regions.count)
    if coordinator.overlays.count != count || (count > 0 && coordinator.overlays[0].source !== source) {
      let overlays = makeOverlays()
      coordinator.overlays = overlays
      view.scene.scopes = overlays
    } else {
      var i = 0
      while i < count {
        let o = coordinator.overlays[i]
        o.settings = settings[i]
        o.region = regions[i]
        o.monitorLUTEnabled = monitorLUTEnabled
        o.accumulationInterval = accumulationInterval
        i += 1
      }
    }
    if outputColor != coordinator.lastOutputColor {
      view.scene.outputColor = outputColor
      coordinator.lastOutputColor = outputColor
    }
  }
}

#if canImport(AppKit)
  extension ScopeLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorMetalView { make(context.coordinator) }
    func updateNSView(_ view: MonitorMetalView, context: Context) { update(view, context.coordinator) }
  }
#elseif canImport(UIKit)
  extension ScopeLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> MonitorMetalView { make(context.coordinator) }
    func updateUIView(_ view: MonitorMetalView, context: Context) { update(view, context.coordinator) }
  }
#endif
