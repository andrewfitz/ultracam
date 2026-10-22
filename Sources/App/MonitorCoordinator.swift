import AppKit
import Combine
import MonitorToolsCore
import MonitorToolsMetal
import MonitorToolsUI

/// Main-actor control/persistence adapter; raw frames use MonitorCaptureSink directly.
@MainActor final class MonitorCoordinator: ObservableObject {
  @Published var workspace: MonitorWorkspaceState {
    didSet {
      guard workspace != oldValue else { return }
      if !workspace.isConfigured { workspace.isConfigured = true }
      for target in sinks.keys { refreshSink(target) }
      onWorkspaceChange?(MonitorWorkspacePreferences(workspace))
    }
  }
  @Published private(set) var targets: [MonitorTargetOption] = []
  @Published private var configurations: [MonitorTargetID: MonitorConfiguration]
  @Published private var previewEnabled: [MonitorTargetID: Bool] = [:]
  /// A target's tools changed; merge them into its `MonitorFeedPreferences`.
  var onConfigurationChange: ((MonitorTargetID, LegacyMonitorConfiguration) -> Void)?
  var onWorkspaceChange: ((MonitorWorkspacePreferences) -> Void)?
  var onDemandChange: ((Set<MonitorTargetID>) -> Void)?
  var onPreviewEnabledChange: ((MonitorTargetID, Bool) -> Void)?
  @Published private var diagnosticSnapshots: [MonitorTargetID: MonitorDiagnostics] = [:]
  /// The shared GPU context every surface encodes through.
  let runtime: MonitorRuntime
  private var diagnosticsTimer: Timer?
  private var sinks: [MonitorTargetID: MonitorCaptureSink] = [:]
  private struct Surface {
    let target: MonitorTargetID
    let presenter: MonitorSurfacePresenter
    var visible = false
    var scopeVisible = false
    var presented: Bool?
    var drawable: Bool?
    var usesNativePreview = false
  }
  private var surfaces: [UUID: Surface] = [:]
  private var lastDemand: Set<MonitorTargetID> = []
  private var assignedDevices: [MonitorTargetID: String] = [:]

  init(
    configurations: [MonitorTargetID: MonitorConfiguration] = [:],
    workspace: MonitorWorkspaceState = MonitorWorkspaceState()
  ) {
    self.configurations = configurations
    self.workspace = workspace
    runtime = MonitorRuntime(gpuTiming: { start, end in
      AppGPUActivity.shared.record(start: start, end: end)
    })
    // Compile the monitor shaders off the main thread before the first surface.
    runtime.prepare()
    diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      MainActor.assumeIsolated { self.refreshDiagnostics() }
    }
  }

  /// Restores the persisted preferences of every feed, Program and the workspace.
  convenience init(
    feeds: [FeedDescriptor], program: MonitorFeedPreferences, workspace: MonitorWorkspacePreferences
  ) {
    var configurations = Dictionary(uniqueKeysWithValues: feeds.map {
      (MonitorTargetID($0.id.rawValue), MonitorConfiguration($0.monitor.legacyConfiguration))
    })
    configurations[MonitorTargetID("program")] = MonitorConfiguration(program.legacyConfiguration)
    self.init(configurations: configurations, workspace: MonitorWorkspaceState(workspace))
  }

  /// Once a second: source rate from the sink, presented rate and GPU time
  /// from the busiest live surface of each target.
  private func refreshDiagnostics() {
    var next: [MonitorTargetID: MonitorDiagnostics] = [:]
    let now = ProcessInfo.processInfo.systemUptime
    for (target, sink) in sinks {
      var value = MonitorDiagnostics()
      let offers = sink.offerStatistics
      value.offeredFrames = offers.frames
      value.offeredFPS = offers.fps
      let stats = surfaces.values.filter { $0.target == target }.map(\.presenter.statistics)
      if let best = stats.max(by: { $0.presentedFPS < $1.presentedFPS }) {
        value.pictureFPS = best.presentedFPS
        value.scopeFPS = stats.map(\.scopeFPS).max() ?? 0
        value.gpuMilliseconds = best.pictureGPUMilliseconds
        value.scopeGPUMilliseconds = stats.compactMap(\.scopeGPUMilliseconds).max()
        value.presentedFrames = best.presentedFrames
        value.supersededFrames = best.supersededFrames
        value.scopeSkippedBusy = stats.reduce(0) { $0 + $1.scopeSkippedBusy }
        value.scopeSkippedNoDrawable = stats.reduce(0) { $0 + $1.scopeSkippedNoDrawable }
        value.failures = stats.reduce(0) { $0 + $1.failures }
        value.pictureAge = best.lastPresented.map { max(0, now - $0.hostTime) }
        value.scopeAge = stats.compactMap(\.lastScope).map { max(0, now - $0.hostTime) }.min()
        if let failure = stats.compactMap(\.lastFailure).first {
          value.availability = .degraded(failure)
        } else if let age = value.pictureAge {
          value.availability = age > 1 ? .stale : .live
        }
      }
      if let reason = runtime.unavailableReason { value.availability = .failed(reason) }
      next[target] = value
    }
    if next != diagnosticSnapshots { diagnosticSnapshots = next }
  }

  func diagnostics(for target: MonitorTargetID) -> MonitorDiagnostics {
    var snapshot = diagnosticSnapshots[target] ?? MonitorDiagnostics()
    snapshot.requestedPictureHz = sinks[target]?.observedSourceFrameHz ?? 0
    snapshot.requestedScopeHz = configuration(for: target).scopes.refreshHz
    let registered = surfaces.values.filter { $0.target == target }
    if !registered.isEmpty && (!isPreviewEnabled(for: target) || registered.allSatisfy({
      !$0.visible || !($0.presented ?? true) || !($0.drawable ?? true) || $0.presenter.isFrozen
    })) { snapshot.availability = .paused }
    return snapshot
  }

  func configuration(for target: MonitorTargetID) -> MonitorConfiguration {
    configurations[target] ?? MonitorConfiguration()
  }

  func setConfiguration(_ configuration: MonitorConfiguration, for target: MonitorTargetID) {
    let value = configuration.normalized()
    guard configurations[target] != value else { return }
    configurations[target] = value
    refreshSink(target)
    onConfigurationChange?(target, LegacyMonitorConfiguration(value))
  }

  func copySettings(from source: MonitorTargetID, to destination: MonitorTargetID) {
    var value = configuration(for: source)
    let previous = configuration(for: destination)
    value.sourceProfileID = previous.sourceProfileID
    value.sourceCodeRange = previous.sourceCodeRange
    value.sourceLogMapping = previous.sourceLogMapping
    // Sony/EL profile identity belongs to the copied display mode, while source
    // interpretation, camera EI and the manual reference offset belong to this feed.
    if value.falseColor.mode != .sonySLog3 && value.falseColor.mode != .elZone {
      value.falseColor.profileID = previous.falseColor.profileID
      value.falseColor.specificationVersion = previous.falseColor.specificationVersion
    }
    value.falseColor.exposureIndex = previous.falseColor.exposureIndex
    value.falseColor.referenceOffsetStops = previous.falseColor.referenceOffsetStops
    setConfiguration(value, for: destination)
  }

  func isPreviewEnabled(for target: MonitorTargetID) -> Bool { previewEnabled[target] ?? true }

  func setPreviewEnabled(_ enabled: Bool, for target: MonitorTargetID) {
    guard isPreviewEnabled(for: target) != enabled else { return }
    previewEnabled[target] = enabled
    refreshSink(target)
    if !enabled {
      for surface in surfaces.values where surface.target == target {
        surface.presenter.setUnavailable("Preview hidden")
      }
    }
    refreshDemand()
    onPreviewEnabledChange?(target, enabled)
  }

  func updateTargets(feeds: [FeedDescriptor], programAvailable: Bool) {
    targets = feeds.map {
      MonitorTargetOption(
        id: MonitorTargetID($0.id.rawValue), title: $0.name, isAvailable: $0.enabled)
    }
    if programAvailable {
      targets.append(
        MonitorTargetOption(id: MonitorTargetID("program"), title: "Program", isAvailable: true))
    }
    let available = Set(targets.filter(\.isAvailable).map(\.id))
    for feed in feeds {
      let target = MonitorTargetID(feed.id.rawValue)
      previewEnabled[target] = feed.previewEnabled
      if let oldDevice = assignedDevices[target], oldDevice != feed.selectedDevice {
        configurations[target] = MonitorConfiguration(feed.monitor.legacyConfiguration)
        sinks[target]?.invalidate()
        refreshSink(target)
      } else if configurations[target] == nil {
        configurations[target] = MonitorConfiguration(feed.monitor.legacyConfiguration)
      }
      assignedDevices[target] = feed.selectedDevice
      refreshSink(target)
      if !feed.previewEnabled {
        for surface in surfaces.values where surface.target == target {
          surface.presenter.setUnavailable("Preview hidden")
        }
      }
    }
    for target in Array(sinks.keys) where !available.contains(target) {
      sinks[target]?.invalidate()
      refreshSink(target)
      for surface in surfaces.values where surface.target == target {
        surface.presenter.setUnavailable("Missing feed")
      }
    }
    if !workspace.isConfigured, let first = targets.first {
      var value = workspace
      if value.tileBindings.allSatisfy({ $0 == nil }) {
        value.tileBindings = (0..<4).map { index in index < targets.count ? targets[index].id : nil
        }
      }
      if value.tileBindings.isEmpty { value.tileBindings = [first.id] }
      value.isConfigured = true
      workspace = value
    }
    refreshDemand()
  }

  func captureSink(for target: MonitorTargetID) -> MonitorCaptureSink {
    if let sink = sinks[target] { return sink }
    let sink = MonitorCaptureSink(target: target, runtime: runtime)
    sinks[target] = sink
    refreshSink(target)
    return sink
  }

  func surface(id: UUID, target: MonitorTargetID) -> MonitorSurfacePresenter {
    if let existing = surfaces[id], existing.target == target { return existing.presenter }
    let previousTarget = surfaces[id]?.target
    let presenter = MonitorSurfacePresenter(runtime: runtime)
    surfaces[id] = Surface(target: target, presenter: presenter)
    if let previousTarget { refreshSink(previousTarget) }
    presenter.onVisibilityChange = { [weak self] presented, drawable in
      self?.setSurfaceVisibility(id: id, target: target, presented: presented, drawable: drawable)
    }
    return presenter
  }

  /// `usesNativePreview` marks a surface whose picture comes from elsewhere;
  /// it takes no monitor frames. `presentationScopeVisible` is accepted for
  /// source compatibility and no longer used.
  func registerSurface(
    id: UUID, target: MonitorTargetID, isVisible: Bool, scopeVisible: Bool,
    usesNativePreview: Bool = false, presentationScopeVisible: Bool? = nil
  ) {
    let presenter = surface(id: id, target: target)
    var value = surfaces[id] ?? Surface(target: target, presenter: presenter)
    value.visible = isVisible
    value.scopeVisible = scopeVisible
    value.usesNativePreview = usesNativePreview
    surfaces[id] = value
    _ = captureSink(for: target)
    refreshSink(target)
    refreshDemand()
  }

  func unregisterSurface(id: UUID, target: MonitorTargetID? = nil) {
    if let target, surfaces[id]?.target != target { return }
    guard let old = surfaces.removeValue(forKey: id) else { return }
    refreshSink(old.target)
    refreshDemand()
  }

  private func refreshSink(_ target: MonitorTargetID) {
    let available = targets.contains { $0.id == target && $0.isAvailable }
    // Every visible, unfrozen monitor picture takes every camera frame.
    let live = surfaces.values.filter {
      $0.target == target && $0.visible && !$0.presenter.isFrozen && !$0.usesNativePreview
        && available && isPreviewEnabled(for: target) && ($0.presented ?? true)
        && ($0.drawable ?? true)
    }
    sinks[target]?.configure(
      configuration(for: target), consumers: live.map(\.presenter),
      scopeVisible: live.contains(where: \.scopeVisible))
  }

  private func refreshDemand() {
    let available = Set(targets.filter(\.isAvailable).map(\.id))
    let demand = Set(
      surfaces.values.filter {
        $0.visible && ($0.presented ?? true) && available.contains($0.target)
          && isPreviewEnabled(for: $0.target)
      }.map(\.target))
    guard demand != lastDemand else { return }
    lastDemand = demand
    onDemandChange?(demand)
  }

  private func setSurfaceVisibility(
    id: UUID, target: MonitorTargetID, presented: Bool, drawable: Bool
  ) {
    guard var value = surfaces[id], value.target == target else { return }
    value.presented = presented
    value.drawable = drawable
    surfaces[id] = value
    refreshSink(target)
    refreshDemand()
  }

  func sourceStateChanged(target: MonitorTargetID, running: Bool, message: String) {
    if !running {
      sinks[target]?.invalidate()
      for surface in surfaces.values where surface.target == target {
        surface.presenter.setUnavailable("Feed stopped")
      }
    }
  }
}

// The settings boundary while surfaces still render with MonitorTools: the
// app persists `MonitorFeedPreferences` (MonitorKit) and converts through
// `LegacyMonitorConfiguration`, its app-owned copy of `MonitorConfiguration`.
// No file imports both packages.

extension MonitorConfiguration {
  init(_ legacy: LegacyMonitorConfiguration) {
    self.init()
    schemaVersion = legacy.schemaVersion
    toolsEnabled = legacy.toolsEnabled
    guides.enabled = legacy.guides.enabled
    guides.thirds = legacy.guides.thirds
    guides.centerCross = legacy.guides.centerCross
    guides.safeArea = legacy.guides.safeArea
    guides.opacity = legacy.guides.opacity
    guides.contrast = legacy.guides.contrast
    zebra.enabled = legacy.zebra.enabled
    zebra.thresholdIRE = legacy.zebra.thresholdIRE
    zebra.widthIRE = legacy.zebra.widthIRE
    zebra.mode = legacy.zebra.mode == .band ? .band : .aboveThreshold
    zebra.opacity = legacy.zebra.opacity
    falseColor.mode = MonitorFalseColorMode(rawValue: legacy.falseColor.mode.rawValue) ?? .off
    falseColor.profileID = legacy.falseColor.profileID
    falseColor.specificationVersion = legacy.falseColor.specificationVersion
    falseColor.exposureIndex = legacy.falseColor.exposureIndex
    falseColor.referenceOffsetStops = legacy.falseColor.referenceOffsetStops
    focus.enabled = legacy.focus.enabled
    focus.color = MonitorPeakingColor(rawValue: legacy.focus.color.rawValue) ?? .red
    focus.sensitivity = legacy.focus.sensitivity
    focus.noiseRejection = legacy.focus.noiseRejection
    focus.opacity = legacy.focus.opacity
    scopes.enabled = legacy.scopes.enabled
    scopes.mode = legacy.scopes.mode == .lumaWaveform ? .lumaWaveform : .rgbParade
    scopes.gain = legacy.scopes.gain
    scopes.graticule = legacy.scopes.graticule
    scopes.refreshHz = legacy.scopes.refreshHz
    pictureStage = legacy.pictureStage == .source ? .source : .processedOutput
    scopeStage = legacy.scopeStage == .source ? .source : .processedOutput
    sourceProfileID = legacy.sourceProfileID
    sourceCodeRange = legacy.sourceCodeRange.map { $0 == .full ? .full : .legal }
    sourceLogMapping = legacy.sourceLogMapping == .fullRescaledToLegal10Bit
      ? .fullRescaledToLegal10Bit : .native10Bit
  }
}

extension LegacyMonitorConfiguration {
  init(_ configuration: MonitorConfiguration) {
    self.init()
    schemaVersion = configuration.schemaVersion
    toolsEnabled = configuration.toolsEnabled
    guides.enabled = configuration.guides.enabled
    guides.thirds = configuration.guides.thirds
    guides.centerCross = configuration.guides.centerCross
    guides.safeArea = configuration.guides.safeArea
    guides.opacity = configuration.guides.opacity
    guides.contrast = configuration.guides.contrast
    zebra.enabled = configuration.zebra.enabled
    zebra.thresholdIRE = configuration.zebra.thresholdIRE
    zebra.widthIRE = configuration.zebra.widthIRE
    zebra.mode = configuration.zebra.mode == .band ? .band : .aboveThreshold
    zebra.opacity = configuration.zebra.opacity
    falseColor.mode = FalseColorMode(rawValue: configuration.falseColor.mode.rawValue) ?? .off
    falseColor.profileID = configuration.falseColor.profileID
    falseColor.specificationVersion = configuration.falseColor.specificationVersion
    falseColor.exposureIndex = configuration.falseColor.exposureIndex
    falseColor.referenceOffsetStops = configuration.falseColor.referenceOffsetStops
    focus.enabled = configuration.focus.enabled
    focus.color = PeakingColor(rawValue: configuration.focus.color.rawValue) ?? .red
    focus.sensitivity = configuration.focus.sensitivity
    focus.noiseRejection = configuration.focus.noiseRejection
    focus.opacity = configuration.focus.opacity
    scopes.enabled = configuration.scopes.enabled
    scopes.mode = configuration.scopes.mode == .lumaWaveform ? .lumaWaveform : .rgbParade
    scopes.gain = configuration.scopes.gain
    scopes.graticule = configuration.scopes.graticule
    scopes.refreshHz = configuration.scopes.refreshHz
    pictureStage = configuration.pictureStage == .source ? .source : .processedOutput
    scopeStage = configuration.scopeStage == .source ? .source : .processedOutput
    sourceProfileID = configuration.sourceProfileID
    sourceCodeRange = configuration.sourceCodeRange.map { $0 == .full ? .full : .legal }
    sourceLogMapping = configuration.sourceLogMapping == .fullRescaledToLegal10Bit
      ? .fullRescaledToLegal10Bit : .native10Bit
  }
}

extension MonitorWorkspaceState {
  init(_ preferences: MonitorWorkspacePreferences) {
    self.init()
    schemaVersion = preferences.schemaVersion
    isConfigured = preferences.isConfigured
    layout = MonitorWorkspaceLayout(rawValue: preferences.layout.rawValue) ?? .single
    tileBindings = preferences.tileBindings.map { $0.map(MonitorTargetID.init(rawValue:)) }
    splitRatio = preferences.splitRatio
  }
}

extension MonitorWorkspacePreferences {
  init(_ state: MonitorWorkspaceState) {
    self.init()
    schemaVersion = state.schemaVersion
    isConfigured = state.isConfigured
    layout = Layout(rawValue: state.layout.rawValue) ?? .single
    tileBindings = state.tileBindings.map { $0?.rawValue }
    splitRatio = state.splitRatio
  }
}

extension AppSettingsSnapshot {
  /// The workspace as MonitorTools' type, for callers not yet moved to
  /// `monitorWorkspacePreferences`. Removed with MonitorTools.
  var monitorWorkspace: MonitorWorkspaceState {
    get { MonitorWorkspaceState(monitorWorkspacePreferences) }
    set { monitorWorkspacePreferences = MonitorWorkspacePreferences(newValue) }
  }

  /// `init(...)` with MonitorTools' workspace type. Removed with MonitorTools.
  init(feeds: [FeedDescriptor] = [FeedDescriptor()], selectedFeedID: FeedID? = nil,
    outputMode: FeedOutputMode = .separateCameras, switcher: SwitcherSettings = SwitcherSettings(),
    virtualCameraRegistryVersion: Int = 1, monitorWorkspace: MonitorWorkspaceState) {
    self.init(feeds: feeds, selectedFeedID: selectedFeedID, outputMode: outputMode, switcher: switcher,
      virtualCameraRegistryVersion: virtualCameraRegistryVersion,
      monitorWorkspace: MonitorWorkspacePreferences(monitorWorkspace))
  }
}
