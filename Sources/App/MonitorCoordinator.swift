import AppKit
import Combine
import MonitorKit

/// Main-actor control of the monitor on MonitorKit: the tools of every target
/// (`MonitorFeedPreferences`, persisted by the owner), the workspace, preview
/// enable, the targets, the feed hosts the producers offer frames to, and the
/// surface registry with its demand. Frames never pass through here: producers
/// offer them to a target's `MonitorFeedHost`, which hands them to its live
/// surfaces on the delivery thread.
@MainActor final class MonitorCoordinator: ObservableObject {
  @Published var workspace: MonitorWorkspacePreferences {
    didSet {
      guard workspace != oldValue else { return }
      if !workspace.isConfigured { workspace.isConfigured = true }
      for target in hosts.keys { refreshHost(target) }
      onWorkspaceChange?(workspace)
    }
  }
  @Published private(set) var targets: [MonitorTargetOption] = []
  @Published private var preferences: [MonitorTargetID: MonitorFeedPreferences]
  @Published private var previewEnabled: [MonitorTargetID: Bool] = [:]
  /// A target's tools changed (from the interface): its whole preferences, which
  /// replace the saved ones.
  var onConfigurationChange: ((MonitorTargetID, MonitorFeedPreferences) -> Void)?
  /// Reset and copy: the owner applies them to its saved preferences (the
  /// coordinator applies the same change to its own) and returns true; false
  /// for a target it does not know. Without an owner the change is reported
  /// through `onConfigurationChange`.
  var onResetSettings: ((MonitorTargetID) -> Bool)?
  var onCopySettings: ((_ source: MonitorTargetID, _ destination: MonitorTargetID) -> Bool)?
  var onWorkspaceChange: ((MonitorWorkspacePreferences) -> Void)?
  var onDemandChange: ((Set<MonitorTargetID>) -> Void)?
  var onPreviewEnabledChange: ((MonitorTargetID, Bool) -> Void)?
  /// Refreshed once a second. Not published by the coordinator: its rates and ages change
  /// every second while a camera runs, and the main window observes the coordinator for
  /// tool changes. Views that show diagnostics observe `diagnosticsPublisher`; a change of a
  /// monitor LUT's state (which the camera's LUT menu shows) is published by both.
  private var diagnosticSnapshots: [MonitorTargetID: MonitorDiagnostics] = [:]
  /// Tells the views that show diagnostics (`diagnostics(for:)`) when they change.
  let diagnosticsPublisher = ObservableObjectPublisher()
  /// The shared GPU context every surface encodes through.
  let gpu: MonitorGPUContext
  /// The process's monitor GPU context: one device, queue, engine and render
  /// thread, built and warmed once however many coordinators there are, with the
  /// app's pipeline warm start (`MonitorGPUContext.appPipelineCacheDirectory`).
  nonisolated static let sharedGPU = MonitorGPUContext(
    pipelineCacheDirectory: MonitorGPUContext.appPipelineCacheDirectory)
  /// Where each camera's burn-in LUT is read (its capture controller).
  private var burnInSources: [MonitorTargetID: @Sendable () -> MonitorLUT?] = [:]
  private var diagnosticsTimer: Timer?
  private var hosts: [MonitorTargetID: MonitorFeedHost] = [:]
  private struct Surface {
    let target: MonitorTargetID
    let presenter: MonitorSurfacePresenter
    var visible = false
    var scopeVisible = false
    var presented: Bool?
    var drawable: Bool?
  }
  private var surfaces: [UUID: Surface] = [:]
  private var lastDemand: Set<MonitorTargetID> = []
  private var assignedDevices: [MonitorTargetID: String] = [:]

  init(
    preferences: [MonitorTargetID: MonitorFeedPreferences] = [:],
    workspace: MonitorWorkspacePreferences = MonitorWorkspacePreferences(),
    gpu: MonitorGPUContext = MonitorCoordinator.sharedGPU
  ) {
    self.preferences = preferences
    self.workspace = workspace
    self.gpu = gpu
    // Build the GPU context and warm every pipeline the three layer formats need
    // off the main thread, before the first surface.
    gpu.prepare()
    diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      MainActor.assumeIsolated { self.refreshDiagnostics() }
    }
  }

  /// Restores the persisted preferences of every feed, Program and the workspace.
  convenience init(
    feeds: [FeedDescriptor], program: MonitorFeedPreferences, workspace: MonitorWorkspacePreferences
  ) {
    var preferences = Dictionary(uniqueKeysWithValues: feeds.map { (MonitorTargetID($0.id.rawValue), $0.monitor) })
    preferences[.program] = program
    self.init(preferences: preferences, workspace: workspace)
  }

  /// Once a second: source rate from the feed host, presented rate and GPU time
  /// from the busiest live surface of each target. A surface is degraded only by
  /// a recent failure (`MonitorSurfacePresenter.failureShownFor`). Internal for tests.
  func refreshDiagnostics() {
    var next: [MonitorTargetID: MonitorDiagnostics] = [:]
    let now = ProcessInfo.processInfo.systemUptime
    for (target, host) in hosts {
      var value = MonitorDiagnostics()
      let offers = host.offerStatistics
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
      if let reason = gpu.unavailableReason { value.availability = .failed(reason) }
      value.monitorLUT = host.monitorLUTState
      next[target] = value
    }
    guard next != diagnosticSnapshots else { return }
    if next.mapValues(\.monitorLUT) != diagnosticSnapshots.mapValues(\.monitorLUT) { objectWillChange.send() }
    diagnosticsPublisher.send()
    diagnosticSnapshots = next
  }

  func diagnostics(for target: MonitorTargetID) -> MonitorDiagnostics {
    var snapshot = diagnosticSnapshots[target] ?? MonitorDiagnostics()
    snapshot.requestedPictureHz = hosts[target]?.observedSourceFrameHz ?? 0
    // Scopes follow the video: one per source frame (the saved refresh rate is ignored).
    snapshot.requestedScopeHz = Int(snapshot.requestedPictureHz.rounded())
    let registered = surfaces.values.filter { $0.target == target }
    if !registered.isEmpty
      && (!isPreviewEnabled(for: target)
        || registered.allSatisfy({
          !$0.visible || !($0.presented ?? true) || !($0.drawable ?? true) || $0.presenter.holdsFreeze
        }))
    {
      snapshot.availability = .paused
    }
    return snapshot
  }

  /// Where the target's monitor-only LUT file stands: loading, shown, or why it
  /// failed. Also in its diagnostics, so a change is published within a second.
  func monitorLUTState(for target: MonitorTargetID) -> MonitorFeedHost.MonitorLUTState {
    hosts[target]?.monitorLUTState ?? .none
  }

  /// What the target's scope measures: the signal of a picture of it on screen
  /// with both its readings (nil before a frame), and whether a LUT is on the
  /// scope's stage (`MonitorSurfacePresenter.scopeMeasuresLUT`). The signal is
  /// not resolved to a stage here: the scope's description picks its own stage's
  /// reading (`SignalDescription.signal(for:)`, as `ScopeAccumulator` does) from
  /// the stage the settings form shows, which reaches this coordinator a change
  /// later, and a resolved Output reading cannot be read back as the Source's.
  func scopeMeasurement(for target: MonitorTargetID) -> (signal: SignalDescription?, stageLUT: Bool) {
    let presenter = surfaces.values.first { $0.target == target && $0.presenter.shownSignal != nil }?.presenter
      ?? surfaces.values.first { $0.target == target }?.presenter
    guard let presenter else { return (nil, false) }
    return (presenter.shownSignal, presenter.scopeMeasuresLUT(preferences(for: target)))
  }

  /// A target's tools, signal declaration and scopes.
  func preferences(for target: MonitorTargetID) -> MonitorFeedPreferences {
    preferences[target] ?? MonitorFeedPreferences()
  }

  /// Changes a target's tools from the interface and reports them to the owner.
  func setPreferences(_ value: MonitorFeedPreferences, for target: MonitorTargetID) {
    guard preferences[target] != value else { return }
    show(value, for: target)
    onConfigurationChange?(target, value)
  }

  /// Shows `value` on the target's surfaces and feed host (already saved, or about to be).
  private func show(_ value: MonitorFeedPreferences, for target: MonitorTargetID) {
    guard preferences[target] != value else { return }
    preferences[target] = value
    refreshHost(target)
  }

  /// "Reset monitor tools" for `target`.
  func resetSettings(for target: MonitorTargetID) {
    var value = preferences(for: target)
    value.resetTools()
    guard let onResetSettings else { return setPreferences(value, for: target) }
    // The owner resets its saved preferences the same way (false: not its target).
    guard onResetSettings(target) else { return setPreferences(value, for: target) }
    show(value, for: target)
  }

  /// "Copy settings to": the source's tools and scopes; the destination keeps its
  /// own camera (signal declaration and exposure offset).
  func copySettings(from source: MonitorTargetID, to destination: MonitorTargetID) {
    var value = preferences(for: destination)
    value.copyTools(from: preferences(for: source))
    if let onCopySettings, onCopySettings(source, destination) {
      return show(value, for: destination)
    }
    setPreferences(value, for: destination)
  }

  func isPreviewEnabled(for target: MonitorTargetID) -> Bool { previewEnabled[target] ?? true }

  func setPreviewEnabled(_ enabled: Bool, for target: MonitorTargetID) {
    guard isPreviewEnabled(for: target) != enabled else { return }
    previewEnabled[target] = enabled
    refreshHost(target)
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
      MonitorTargetOption(id: MonitorTargetID($0.id.rawValue), title: $0.name, isAvailable: $0.enabled)
    }
    if programAvailable {
      targets.append(MonitorTargetOption(id: .program, title: "Program", isAvailable: true))
    }
    let available = Set(targets.filter(\.isAvailable).map(\.id))
    for feed in feeds {
      let target = MonitorTargetID(feed.id.rawValue)
      previewEnabled[target] = feed.previewEnabled
      if let oldDevice = assignedDevices[target], oldDevice != feed.selectedDevice {
        // Another camera: the owner forgot the old one's calibration.
        preferences[target] = feed.monitor
        hosts[target]?.invalidate(rejectingCaptureGeneration: nil)
      } else if preferences[target] == nil {
        preferences[target] = feed.monitor
      }
      assignedDevices[target] = feed.selectedDevice
      refreshHost(target)
      if !feed.previewEnabled {
        for surface in surfaces.values where surface.target == target {
          surface.presenter.setUnavailable("Preview hidden")
        }
      }
    }
    // A removed camera's host, tools and LUTs go (re-adding it makes a new feed).
    let listed = Set(feeds.map { MonitorTargetID($0.id.rawValue) })
    for target in Array(assignedDevices.keys) where !listed.contains(target) && !target.isProgram {
      release(target)
    }
    for target in Array(hosts.keys) where !available.contains(target) {
      hosts[target]?.invalidate(rejectingCaptureGeneration: nil)
      refreshHost(target)
      for surface in surfaces.values where surface.target == target {
        surface.presenter.setUnavailable("Missing feed")
      }
    }
    if !workspace.isConfigured, let first = targets.first {
      var value = workspace
      if value.tileBindings.allSatisfy({ $0 == nil }) {
        value.tileBindings = (0..<4).map { index in index < targets.count ? targets[index].id.rawValue : nil }
      }
      if value.tileBindings.isEmpty { value.tileBindings = [first.id.rawValue] }
      value.isConfigured = true
      workspace = value
    }
    refreshDemand()
  }

  /// Lets go of a camera that is no longer listed: its host stops taking frames
  /// and drops its LUTs and render state (the feed, its focus mask, their GPU
  /// residency), and its tools, burn-in source and assignment are forgotten (the
  /// owner keeps the saved ones). Surfaces still bound to it say so.
  private func release(_ target: MonitorTargetID) {
    if let host = hosts.removeValue(forKey: target) {
      host.onMonitorLUTChoiceRefresh = nil
      host.setMonitorLUT(nil)
      host.burnInLUT = nil
      host.setConsumers([])
      host.invalidate(rejectingCaptureGeneration: nil)
      host.releaseRenderState()
    }
    preferences[target] = nil
    if burnInSources.removeValue(forKey: target) != nil {
      lutLog.notice("Monitor burn-in LUT source cleared: \(target.rawValue, privacy: .public) (camera removed)")
    }
    assignedDevices[target] = nil
    previewEnabled[target] = nil
    diagnosticSnapshots[target] = nil
    for surface in surfaces.values where surface.target == target {
      surface.presenter.setBurnInLUTSource(nil)
      surface.presenter.setUnavailable("Missing feed")
    }
  }

  /// Feed hosts (tests): one per camera listed or bound, and Program.
  var hostTargets: Set<MonitorTargetID> { Set(hosts.keys) }

  /// The target's feed host: the endpoint its producer offers frames to.
  func captureSink(for target: MonitorTargetID) -> MonitorFeedHost {
    if let host = hosts[target] { return host }
    let host = MonitorFeedHost(target: target.rawValue, gpu: gpu)
    host.onMonitorLUTChoiceRefresh = { [weak self] old, new in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.monitorLUTChoiceRefreshed(target, from: old, to: new) }
      }
    }
    hosts[target] = host
    refreshHost(target)
    return host
  }

  /// The host resolved the target's monitor LUT to a refreshed bookmark or name
  /// (the file moved or was renamed): saved through the owner, unless the choice
  /// changed meanwhile. The host already holds it, so this does not reload.
  private func monitorLUTChoiceRefreshed(_ target: MonitorTargetID, from old: MonitorLUTChoice, to new: MonitorLUTChoice) {
    var value = preferences(for: target)
    guard value.monitorLUT == old else { return }
    value.monitorLUT = new
    setPreferences(value, for: target)
  }

  /// Where `target`'s burn-in LUT is read: the camera's capture controller
  /// (`CaptureController.burnInLUT`), so the Output (LUT) picture shows the very
  /// `MonitorLUT` the camera burns in. Surfaces read it at each encode, so a LUT
  /// load or Apply LUT change shows on the next picture. Nil for Program.
  func setBurnInLUTSource(for target: MonitorTargetID, _ source: (@Sendable () -> MonitorLUT?)?) {
    let wasSet = burnInSources[target] != nil
    burnInSources[target] = target.isProgram ? nil : source
    let isSet = burnInSources[target] != nil
    if wasSet != isSet || isSet {
      lutLog.notice("Monitor burn-in LUT source \(isSet ? (wasSet ? "replaced" : "set") : "cleared", privacy: .public): \(target.rawValue, privacy: .public), \(self.surfaces.values.filter { $0.target == target }.count, privacy: .public) surfaces")
    }
    for surface in surfaces.values where surface.target == target {
      surface.presenter.setBurnInLUTSource(burnInSources[target])
    }
    hosts[target]?.burnInLUT = burnInSources[target]?()
  }

  func surface(id: UUID, target: MonitorTargetID) -> MonitorSurfacePresenter {
    if let existing = surfaces[id], existing.target == target { return existing.presenter }
    let previousTarget = surfaces[id]?.target
    let presenter = MonitorSurfacePresenter(target: target, host: captureSink(for: target), gpu: gpu)
    presenter.setPreferences(preferences(for: target))
    presenter.setBurnInLUTSource(burnInSources[target])
    surfaces[id] = Surface(target: target, presenter: presenter)
    if let previousTarget { refreshHost(previousTarget) }
    presenter.onVisibilityChange = { [weak self] presented, drawable in
      self?.setSurfaceVisibility(id: id, target: target, presented: presented, drawable: drawable)
    }
    return presenter
  }

  func registerSurface(id: UUID, target: MonitorTargetID, isVisible: Bool, scopeVisible: Bool) {
    let presenter = surface(id: id, target: target)
    var value = surfaces[id] ?? Surface(target: target, presenter: presenter)
    value.visible = isVisible
    value.scopeVisible = scopeVisible
    surfaces[id] = value
    refreshHost(target)
    refreshDemand()
  }

  func unregisterSurface(id: UUID, target: MonitorTargetID? = nil) {
    if let target, surfaces[id]?.target != target { return }
    guard let old = surfaces.removeValue(forKey: id) else { return }
    refreshHost(old.target)
    refreshDemand()
  }

  /// Every visible, unfrozen monitor picture of an available, shown target takes
  /// every frame; the declaration and the burn-in LUT stay with the host.
  private func refreshHost(_ target: MonitorTargetID) {
    let value = preferences(for: target)
    let all = surfaces.values.filter { $0.target == target }
    for surface in all { surface.presenter.setPreferences(value) }
    guard let host = hosts[target] else { return }
    host.setSignalDeclaration(value.signal)
    // The whole choice, pick included, so choosing the same file again reloads
    // it; an unchanged choice does nothing, and Program ignores it.
    host.setMonitorLUT(value.monitorLUT)
    let available = targets.contains { $0.id == target && $0.isAvailable }
    let live = all.filter {
      $0.visible && !$0.presenter.holdsFreeze && available
        && isPreviewEnabled(for: target) && ($0.presented ?? true) && ($0.drawable ?? true)
    }
    host.setConsumers(live.map(\.presenter))
  }

  private func refreshDemand() {
    let available = Set(targets.filter(\.isAvailable).map(\.id))
    let demand = Set(
      surfaces.values.filter {
        $0.visible && ($0.presented ?? true) && available.contains($0.target) && isPreviewEnabled(for: $0.target)
      }.map(\.target))
    guard demand != lastDemand else { return }
    lastDemand = demand
    onDemandChange?(demand)
  }

  private func setSurfaceVisibility(id: UUID, target: MonitorTargetID, presented: Bool, drawable: Bool) {
    guard var value = surfaces[id], value.target == target else { return }
    value.presented = presented
    value.drawable = drawable
    surfaces[id] = value
    refreshHost(target)
    refreshDemand()
  }

  func sourceStateChanged(target: MonitorTargetID, running: Bool, message: String) {
    if !running {
      hosts[target]?.invalidate(rejectingCaptureGeneration: nil)
      for surface in surfaces.values where surface.target == target {
        surface.presenter.setUnavailable("Feed stopped")
      }
    }
  }
}

extension MonitorFeedPreferences {
  /// Shows `stage` as the picture. Zebra measures the picture shown, as in
  /// MonitorTools (map §5.3), so the first zebra set's stage follows it; every
  /// picture menu changes the stage through here.
  mutating func setPictureStage(_ stage: SignalStage) {
    state.pictureStage = stage
    if state.zebras.isEmpty { state.zebras = Self.defaultState.zebras }
    state.zebras[0].stage = stage
  }

  /// Whether a tool the master switch shows is on (clip indicators and the
  /// second zebra are set in a detached monitor's tool bar).
  var anyToolOn: Bool {
    state.guides.enabled || state.zebras.contains(where: \.enabled) || state.falseColor.mode != .off
      || state.focus.enabled || scopes.enabled || state.clipIndicators.enabled
  }

  /// Every tool the master switch shows, off: what turning the switch back on
  /// starts from, so tools left enabled underneath it stay off.
  mutating func hideAllTools() {
    state.guides.enabled = false
    for index in state.zebras.indices { state.zebras[index].enabled = false }
    state.focus.enabled = false
    state.falseColor.mode = .off
    state.clipIndicators.enabled = false
    scopes.enabled = false
  }
}
