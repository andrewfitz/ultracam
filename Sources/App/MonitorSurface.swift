import AppKit
import Combine
import Metal
import MonitorKit
import MonitorKitScopes
import MonitorKitUI
import QuartzCore
import SwiftUI

/// One monitor surface on MonitorKit: a picture (and optionally a scope) of one
/// target. The feed host hands it every frame with `accept`; the newest one waits
/// in a single slot until the surface's display link draws it on the next refresh.
/// Nothing is copied on the way in. A frozen surface takes no new frames, and a
/// surface that stops being drawable drops the one it had, so neither keeps a
/// capture buffer.
///
/// The tools come from the target's `MonitorFeedPreferences` (shared by every
/// surface of the target), with this surface's Clean View and magnification. A
/// freeze keeps the tools it was frozen with, and a GPU copy of the frame
/// (`MonitorFeed.freeze`, into a feed of its own), so it pins no capture buffer.
final class MonitorSurfacePresenter: ObservableObject, MonitorFeedConsumer, @unchecked Sendable {
  let target: MonitorTargetID
  let host: MonitorFeedHost
  let gpu: MonitorGPUContext
  private let lock = NSLock()

  /// A held picture. `owned` (a copy in `feed`) replaces `live` once the render
  /// thread has copied it on the GPU.
  struct Frozen {
    let token: UInt64
    let preferences: MonitorFeedPreferences
    let state: MonitorState
    var live: MonitorFeedHost.Delivery?
    var owned: MonitorFrame?
    var feed: MonitorFeed?
    let stamp: MonitorFeedHost.Stamp
    let signal: SignalDescription
    /// The Output and Monitor stages' reading (`Delivery.outputSignal`); the owned
    /// copy carries `signal` and takes this one for a pass on those stages.
    let outputSignal: SignalDescription
    let geometry: MonitorFrameGeometry
    var fromPendingRequest = false
  }
  private var latest: MonitorFeedHost.Delivery?
  private var latestVersion: UInt64 = 0
  private var takenVersion: UInt64 = 0
  private var stateVersion: UInt64 = 1
  private var lastAcceptedStamp: MonitorFeedHost.Stamp?
  private var unavailableReason = "No Signal"
  /// Set by setUnavailable until the next accepted frame.
  private var signalLost = false
  /// Set while the surface is reported not drawable (hidden, occluded, minimized):
  /// its display link is paused and it holds no capture frame.
  private var hidden = false
  /// The hidden surface dropped its frame; shown as resuming, not as no signal.
  private var resuming = false
  private var frozen: Frozen?
  /// A just-released hold, still drawn until the next live frame arrives so
  /// unfreezing never flashes black.
  private var lingering: Frozen?
  private var nextFreezeToken: UInt64 = 0
  private var pendingFreeze = false
  /// The target's tools, this surface's Clean View and magnification, and the
  /// state they make (built when one of them changes, never per frame).
  private var preferences = MonitorFeedPreferences()
  private var clean = false
  private var magnification = Magnification()
  private var encodeState = MonitorFeedPreferences().surfaceState(isProgram: false)
  /// Where the target's burn-in LUT is read at each encode (nil: the host's as set).
  private var burnInSource: (@Sendable () -> MonitorLUT?)?
  private var rendererStatus: [String] = []
  private var pictureStatus = MonitorStatus()
  private var counters = MonitorSurfaceStatistics()
  private var lastFailureTime = -Double.infinity
  /// Scope commits on the GPU; drawables are requested only while one is free.
  private var scopesInFlight = 0
  private var window = (start: 0.0, accepted: UInt64(0), presented: UInt64(0), scopes: UInt64(0))
  private var gpuTime = (picture: 0.0, pictures: 0, scope: 0.0, scopes: 0)
  private var published = MonitorSurfaceStatistics()
  private var refreshScheduled = false
  private weak var scopeLayer: CAMetalLayer?
  private var lastStatusUpdate = 0.0

  @MainActor @Published private(set) var status = "No Signal"
  @MainActor @Published private(set) var detail = ""
  @MainActor @Published private(set) var isFrozen = false
  @MainActor @Published private(set) var isFreezePending = false
  @MainActor @Published private(set) var isClean = false
  @MainActor @Published private(set) var zoom = Magnification()
  @MainActor @Published private(set) var pictureInterpretation = "Range / transfer interpretation unavailable"
  @MainActor @Published private(set) var scopeTiming = "No scope signal"
  @MainActor @Published private(set) var scopeInterpretation = "Range / transfer interpretation unavailable"
  @MainActor @Published private(set) var pictureAspectRatio = 16.0 / 9.0
  /// The tools of the picture on screen: the frozen ones while frozen.
  @MainActor @Published private(set) var shownPreferences = MonitorFeedPreferences()
  /// The signal of the picture on screen, and what MonitorKit says about its tools.
  @MainActor @Published private(set) var shownSignal: SignalDescription?
  @MainActor @Published private(set) var shownStatus = MonitorStatus()
  /// The statistics (clip readout) of this surface's scope accumulator, readable
  /// from any thread; nil until its first scope.
  @MainActor @Published private(set) var scopeStatisticsReader: ScopeStatisticsReader?
  @MainActor var onVisibilityChange: ((Bool, Bool) -> Void)?
  @MainActor private weak var visibilityView: MonitorVisibilityNSView?
  @MainActor private var visibility = (presented: false, drawable: false)
  @MainActor private var visibilityReported = false

  init(target: MonitorTargetID, host: MonitorFeedHost, gpu: MonitorGPUContext) {
    self.target = target
    self.host = host
    self.gpu = gpu
    DispatchQueue.main.async { [weak self] in
      guard self != nil else { return }
      // The timer invalidates itself, on the main run loop it runs on, once the
      // presenter is gone: the last release may be on a Metal completion thread.
      Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
        guard let self else { return timer.invalidate() }
        MainActor.assumeIsolated { self.refresh(force: true) }
      }
    }
  }

  var isProgram: Bool { target.isProgram }

  var currentStamp: MonitorFeedHost.Stamp? {
    lock.withLock { frozen?.stamp ?? latest?.stamp ?? lingering?.stamp }
  }

  /// True while the surface keeps a capture buffer: a live frame waiting to be
  /// drawn, or a hold not yet copied on the GPU.
  var holdsProducerFrame: Bool {
    lock.withLock { latest != nil || frozen?.live != nil || lingering?.live != nil }
  }

  /// Whether the surface holds a picture (frozen) instead of taking live frames.
  var holdsFreeze: Bool { lock.withLock { frozen != nil } }

  /// A snapshot of this surface's counters.
  var statistics: MonitorSurfaceStatistics {
    lock.withLock {
      var value = published
      value.refreshes = counters.refreshes
      value.acceptedFrames = counters.acceptedFrames
      value.presentedFrames = counters.presentedFrames
      value.supersededFrames = counters.supersededFrames
      value.scopeUpdates = counters.scopeUpdates
      value.scopeSkippedBusy = counters.scopeSkippedBusy
      value.scopeSkippedNoDrawable = counters.scopeSkippedNoDrawable
      value.failures = counters.failures
      value.lastPresented = counters.lastPresented
      value.lastScope = counters.lastScope
      value.lastFailure = counters.lastFailure
      return value
    }
  }

  /// The state the next live frame is drawn with (tests).
  var currentEncodeState: MonitorState { lock.withLock { encodeState } }

  // MARK: Ingest (the delivery thread, under the host's lock)

  /// Makes `delivery` the newest frame. It only swaps a slot under a short lock.
  /// Out-of-order frames are ignored. A frozen surface shows its hold, so it does
  /// not keep the frame (or its capture buffer). While hidden the display link is
  /// paused and replaced frames are not counted as superseded.
  func accept(_ delivery: MonitorFeedHost.Delivery) {
    var released: MonitorFeedHost.Delivery?
    var releasedHold: Frozen?
    var copyToken: UInt64?
    lock.lock()
    let stamp = delivery.stamp
    guard frozen == nil, stamp.follows(lastAcceptedStamp) else {
      lock.unlock()
      return
    }
    lastAcceptedStamp = stamp
    if latest != nil && latestVersion > takenVersion && !hidden { counters.supersededFrames += 1 }
    var transition = latest == nil || resuming
    released = latest
    latestVersion &+= 1
    counters.acceptedFrames += 1
    unavailableReason = "No Signal"
    signalLost = false
    resuming = false
    // A live frame ends any lingering hold.
    releasedHold = lingering
    lingering = nil
    if pendingFreeze {
      // The held frame lives in `frozen` alone; the render thread replaces it with
      // a GPU copy at once, so a freeze pins no capture buffer.
      pendingFreeze = false
      nextFreezeToken &+= 1
      frozen = Frozen(
        token: nextFreezeToken, preferences: preferences, state: encodeState, live: delivery, stamp: stamp,
        signal: delivery.signal, outputSignal: delivery.outputSignal, geometry: delivery.geometry,
        fromPendingRequest: true)
      copyToken = nextFreezeToken
      latest = nil
      stateVersion &+= 1
      transition = true
    } else {
      latest = delivery
    }
    let schedule = transition && !refreshScheduled
    if schedule { refreshScheduled = true }
    lock.unlock()
    withExtendedLifetime(released) {}
    if let copyToken { scheduleFreezeCopy(token: copyToken) }
    if let releasedHold { retire(releasedHold) }
    if schedule {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.refresh(force: true) }
      }
    }
  }

  // MARK: Render side (the render thread)

  struct RenderWork {
    enum Content {
      case none
      case live(MonitorFeedHost.Delivery)
      case frozenLive(MonitorFeedHost.Delivery, token: UInt64)
      /// The owned copy carries the Source reading; `outputSignal` is the other.
      case frozenOwned(MonitorFrame, MonitorFeed, token: UInt64, outputSignal: SignalDescription)
    }
    let content: Content
    /// The shown frame's stamp (a hold's, while frozen or lingering).
    let stamp: MonitorFeedHost.Stamp?
    let state: MonitorState
    let preferences: MonitorFeedPreferences
    let latestVersion: UInt64
    let stateVersion: UInt64
    var frozenToken: UInt64? {
      switch content {
      case .frozenLive(_, let token), .frozenOwned(_, _, let token, _): token
      default: nil
      }
    }
    /// The shown picture's signal; nil when there is none.
    var signal: SignalDescription? {
      switch content {
      case .none: nil
      case .live(let delivery), .frozenLive(let delivery, _): delivery.signal
      case .frozenOwned(let frame, _, _, _): frame.signal
      }
    }
  }

  /// What to draw, or nil when nothing changed since `versions`.
  func renderWork(after versions: (UInt64, UInt64), force: Bool) -> RenderWork? {
    lock.withLock {
      counters.refreshes &+= 1
      guard force || versions.0 != latestVersion || versions.1 != stateVersion else { return nil }
      takenVersion = latestVersion
      if let held = frozen ?? (latest == nil ? lingering : nil) {
        let content: RenderWork.Content
        if let owned = held.owned, let feed = held.feed {
          content = .frozenOwned(owned, feed, token: held.token, outputSignal: held.outputSignal)
        } else if let live = held.live {
          content = .frozenLive(live, token: held.token)
        } else {
          content = .none
        }
        return RenderWork(
          content: content, stamp: held.stamp, state: frozenState(held), preferences: held.preferences,
          latestVersion: latestVersion, stateVersion: stateVersion)
      }
      return RenderWork(
        content: latest.map { .live($0) } ?? .none, stamp: latest?.stamp, state: encodeState,
        preferences: preferences, latestVersion: latestVersion, stateVersion: stateVersion)
    }
  }

  /// A hold's tools with this surface's current Clean View and magnification:
  /// both belong to the surface, not to the tools, so they apply to a held
  /// picture too (zooming in on a frozen frame checks its focus). Called with
  /// the lock held.
  private func frozenState(_ held: Frozen) -> MonitorState {
    guard held.state.clean != clean || held.state.geometry.magnification != magnification else {
      return held.state
    }
    var value = held.state
    value.clean = clean
    value.geometry.magnification = magnification
    return value
  }

  /// An owned copy (`owned`, which carries the Source reading) as a pass that
  /// measures `stage` reads it: the same planes and ID with that stage's signal.
  static func reading(_ owned: MonitorFrame, _ stage: SignalStage, outputSignal: SignalDescription) -> MonitorFrame {
    guard stage != .source else { return owned }
    var frame = owned
    frame.signal = outputSignal
    return frame
  }

  /// Copies the held frame on the GPU, on the render thread, as soon as a freeze
  /// begins (visible or not), so the capture buffer goes back to its pool.
  private func scheduleFreezeCopy(token: UInt64) {
    gpu.renderThread.perform { [weak self] in self?.makeFreezeCopy(token: token) }
  }

  /// Render thread. The copy goes into a feed of the hold's own (with the target's
  /// LUTs as they are now), so other surfaces of the target, and later freezes,
  /// never touch it. It is adopted only once encoded and committed; on failure the
  /// hold keeps the capture frame and the failure is counted.
  func makeFreezeCopy(token: UInt64) {
    let source: MonitorFeedHost.Delivery? = lock.withLock {
      guard let value = frozen, value.token == token, value.owned == nil else { return nil }
      return value.live
    }
    guard let source else { return }
    let core: MonitorGPUContext.Core
    let context: MonitorGPUContext.EncodeContext
    do {
      core = try gpu.core()
      context = try core.begin()
    } catch {
      recordFailure(error)
      return
    }
    let feed = core.engine.makeFeed()
    refreshBurnInLUT()
    let live = host.feed(engine: core.engine)
    feed.burnInLUT = live.burnInLUT
    feed.monitorLUT = live.monitorLUT
    let owned: MonitorFrame
    do {
      let frame = try host.frame(source, in: context, core: core)
      context.keep(frame)
      owned = try feed.freeze(frame, into: context.submission)
    } catch {
      core.abandon(context)
      recordFailure(error)
      return
    }
    core.commit(context, completion: self, kind: MonitorSurfaceRenderLoop.freezeKind)
    if !adoptOwnedFreeze(owned, feed: feed, token: token) {
      // The freeze ended meanwhile; the copy's planes retire once it completes.
      feed.unfreeze()
    }
  }

  /// Replaces the held capture frame with its owned GPU copy. Returns false if
  /// the freeze ended meanwhile.
  private func adoptOwnedFreeze(_ frame: MonitorFrame, feed: MonitorFeed, token: UInt64) -> Bool {
    var released: MonitorFeedHost.Delivery?
    let adopted: Bool = lock.withLock {
      guard var value = frozen, value.token == token, value.owned == nil else { return false }
      released = value.live
      value.live = nil
      value.owned = frame
      value.feed = feed
      frozen = value
      return true
    }
    withExtendedLifetime(released) {}
    return adopted
  }

  /// Ends a hold's copy on the render thread (its feed is confined there). The
  /// planes leave residency once the submissions that read them complete.
  private func retire(_ hold: Frozen) {
    guard let feed = hold.feed else { return }
    nonisolated(unsafe) let unsafeFeed = feed
    gpu.renderThread.perform { unsafeFeed.unfreeze() }
  }

  var currentScopeLayer: CAMetalLayer? { lock.withLock { scopeLayer } }

  /// Render thread, before an encode: hands the camera's current burn-in LUT to
  /// the host, whose feed applies it when it changed (an identity check otherwise).
  func refreshBurnInLUT() {
    guard let source = lock.withLock({ burnInSource }) else { return }
    host.burnInLUT = source()
  }

  func setBurnInLUTSource(_ source: (@Sendable () -> MonitorLUT?)?) {
    lock.withLock { burnInSource = source }
  }

  func recordPresented(_ stamp: MonitorFeedHost.Stamp?) {
    lock.withLock {
      if let stamp, stamp != counters.lastPresented {
        counters.presentedFrames += 1
        counters.lastPresented = stamp
      }
    }
  }

  /// MonitorKit's account of the drawn picture's tools, kept when it changes
  /// (rarely: the status is rebuilt only when the state, signal or feed change).
  func recordStatus(_ status: MonitorStatus) {
    lock.withLock {
      guard status != pictureStatus else { return }
      pictureStatus = status
      rendererStatus = Self.describe(status)
    }
  }

  /// Render thread: a new scope accumulator was made; its statistics reader is
  /// published on the main thread.
  func publishScopeStatisticsReader(_ reader: ScopeStatisticsReader) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.scopeStatisticsReader !== reader else { return }
        self.scopeStatisticsReader = reader
      }
    }
  }

  /// Whether a scope of `preferences` measures a LUT's output (then Rec.709):
  /// `MonitorState.pictureHasLUT`'s rule for the scope's stage, with the LUTs
  /// the host has now (the burn-in LUT on Output and Monitor, the monitor LUT
  /// on Monitor while it is shown).
  func scopeMeasuresLUT(_ preferences: MonitorFeedPreferences) -> Bool {
    var state = preferences.state
    state.pictureStage = preferences.scopes.settings.stage
    return state.pictureHasLUT(burnInLUT: host.burnInLUT != nil, monitorLUT: host.monitorLUT != nil)
  }

  func recordScope(_ stamp: MonitorFeedHost.Stamp) {
    lock.withLock {
      counters.scopeUpdates += 1
      counters.lastScope = stamp
    }
  }

  func recordScopeSkip(busy: Bool) {
    lock.withLock {
      if busy { counters.scopeSkippedBusy += 1 } else { counters.scopeSkippedNoDrawable += 1 }
    }
  }

  func recordGPU(kind: Int, milliseconds: Double, failed: Bool) {
    lock.withLock {
      if kind == MonitorSurfaceRenderLoop.scopeKind { scopesInFlight = max(0, scopesInFlight - 1) }
      if failed {
        counters.failures += 1
        counters.lastFailure = "GPU work failed"
        lastFailureTime = ProcessInfo.processInfo.systemUptime
      } else if kind == MonitorSurfaceRenderLoop.pictureKind {
        gpuTime.picture += milliseconds
        gpuTime.pictures += 1
      } else if kind == MonitorSurfaceRenderLoop.scopeKind {
        gpuTime.scope += milliseconds
        gpuTime.scopes += 1
      }
    }
  }

  func recordFailure(_ error: Error) {
    lock.withLock {
      counters.failures += 1
      counters.lastFailure = "\(error)"
      lastFailureTime = ProcessInfo.processInfo.systemUptime
    }
  }

  /// Claims a scope slot if fewer than `limit` scope commits are on the GPU.
  func beginScope(limit: Int) -> Bool {
    lock.withLock {
      guard scopesInFlight < limit else { return false }
      scopesInFlight += 1
      return true
    }
  }

  func cancelScope() { lock.withLock { scopesInFlight = max(0, scopesInFlight - 1) } }

  // MARK: Controls (main actor)

  /// The target's tools. Called by the coordinator whenever they change; a held
  /// picture keeps the tools it was frozen with.
  @MainActor func setPreferences(_ value: MonitorFeedPreferences) {
    let changed: Bool = lock.withLock {
      guard preferences != value else { return false }
      preferences = value
      rebuildState()
      return true
    }
    if changed { refresh(force: true) }
  }

  /// Called with the lock held.
  private func rebuildState() {
    encodeState = preferences.surfaceState(isProgram: isProgram, clean: clean, magnification: magnification)
    stateVersion &+= 1
  }

  /// This surface's magnification (Fit, a zoom about the centre, pixel exact).
  @MainActor func setMagnification(_ value: Magnification) {
    let changed: Bool = lock.withLock {
      guard magnification != value else { return false }
      magnification = value
      rebuildState()
      return true
    }
    if zoom != value { zoom = value }
    if changed { refresh(force: true) }
  }

  @MainActor func reportVisibility(presented: Bool, drawable: Bool) {
    let first = !visibilityReported
    guard first || visibility.presented != presented || visibility.drawable != drawable else { return }
    visibilityReported = true
    visibility = (presented, drawable)
    // A first "not presented" report arrives before the view reaches its window.
    // Passing it on drops monitor demand, which stops and restarts automatic capture.
    let beforeWindow = first && !presented && !drawable
    // The owner stops offering frames first (synchronously), so nothing new lands
    // in the slot after it is dropped.
    if !beforeWindow { onVisibilityChange?(presented, drawable) }
    setHidden(!drawable && !beforeWindow)
    refresh(force: true)
  }

  /// A surface that cannot be seen keeps no capture frame: its slot and any
  /// uncopied lingering hold are dropped. A freeze keeps its GPU copy.
  private func setHidden(_ value: Bool) {
    var released: MonitorFeedHost.Delivery?
    var releasedLingering: Frozen?
    lock.withLock {
      let changed = hidden != value
      hidden = value
      guard changed && value else { return }
      released = latest
      if latest != nil { resuming = true }
      latest = nil
      if let held = lingering, held.owned == nil {
        releasedLingering = held
        lingering = nil
        resuming = true
      }
      latestVersion &+= 1
      stateVersion &+= 1
    }
    withExtendedLifetime((released, releasedLingering)) {}
  }

  @MainActor func setUnavailable(_ reason: String) {
    var released: MonitorFeedHost.Delivery?
    lock.withLock {
      released = latest
      latest = nil
      latestVersion &+= 1
      unavailableReason = reason
      signalLost = true
      resuming = false
      pendingFreeze = false
      stateVersion &+= 1
    }
    withExtendedLifetime(released) {}
    if let hold = dropLingering() { retire(hold) }
    refresh(force: true)
  }

  @MainActor func requestFreezeOnNextFrame() {
    let retired = endFreeze()
    lock.withLock {
      pendingFreeze = true
      stateVersion &+= 1
    }
    if let retired { retire(retired) }
    refresh(force: true)
  }

  /// Cancel wins even if a frame already satisfied the request but the UI still
  /// shows it as pending.
  @MainActor func cancelPendingFreeze() {
    let wasPending = isFreezePending
    let fromRequest: Bool = lock.withLock {
      pendingFreeze = false
      stateVersion &+= 1
      return frozen?.fromPendingRequest == true
    }
    if wasPending && fromRequest, let retired = endFreeze() { retire(retired) }
    refresh(force: true)
  }

  @MainActor func toggleFreeze() {
    var retired: Frozen?
    var message: String?
    var copyToken: UInt64?
    lock.lock()
    if frozen != nil {
      lock.unlock()
      retired = endFreeze()
    } else if let held = latest {
      nextFreezeToken &+= 1
      frozen = Frozen(
        token: nextFreezeToken, preferences: preferences, state: encodeState, live: held, stamp: held.stamp,
        signal: held.signal, outputSignal: held.outputSignal, geometry: held.geometry)
      // Hand the slot's buffer to the freeze; the render thread swaps it for a GPU copy.
      latest = nil
      latestVersion &+= 1
      stateVersion &+= 1
      copyToken = nextFreezeToken
      lock.unlock()
    } else if let hold = lingering {
      // Re-freeze the picture still on screen.
      frozen = hold
      lingering = nil
      stateVersion &+= 1
      if hold.owned == nil { copyToken = hold.token }
      lock.unlock()
    } else {
      lock.unlock()
      message = "Freeze unavailable: no picture"
    }
    if let copyToken { scheduleFreezeCopy(token: copyToken) }
    if let retired { retire(retired) }
    refresh(force: true)
    if let message { detail = message }
  }

  /// Ends any freeze; returns a hold whose copy the caller retires.
  private func endFreeze() -> Frozen? {
    lock.withLock {
      guard let held = frozen else { return nil }
      stateVersion &+= 1
      frozen = nil
      // A hidden surface never keeps an uncopied capture frame.
      if latest == nil && !signalLost && !(hidden && held.owned == nil) {
        // Keep drawing the hold until live frames resume.
        let retired = lingering
        lingering = held
        return retired
      }
      return held
    }
  }

  /// Drops a lingering hold; returns it for the caller to retire.
  private func dropLingering() -> Frozen? {
    lock.withLock {
      let held = lingering
      if lingering != nil { stateVersion &+= 1 }
      lingering = nil
      return held
    }
  }

  @MainActor func setClean(_ enabled: Bool) {
    lock.withLock {
      guard clean != enabled else { return }
      clean = enabled
      rebuildState()
    }
    isClean = enabled
    refresh(force: true)
  }

  @MainActor func toggleClean() { setClean(!isClean) }

  // MARK: Views

  @MainActor func makeView() -> NSView {
    let view = MonitorPictureNSView(presenter: self)
    view.visibilityChanged = { [weak self, weak view] presented, drawable in
      guard let self, self.visibilityView === view else { return }
      self.reportVisibility(presented: presented, drawable: drawable)
    }
    visibilityView = view
    refresh(force: true)
    return view
  }

  @MainActor func makeVisibilityView() -> NSView {
    let view = MonitorVisibilityNSView()
    view.visibilityChanged = { [weak self, weak view] presented, drawable in
      guard let self, self.visibilityView === view else { return }
      self.reportVisibility(presented: presented, drawable: drawable)
    }
    visibilityView = view
    return view
  }

  @MainActor func makeScopeView() -> NSView {
    let view = MonitorScopeNSView(gpu: gpu)
    view.removedFromPresenter = { [weak self] layer in self?.scopeViewRemoved(layer) }
    // The render thread draws scopes only while the view is in a window, so it
    // never waits on drawables nobody will display.
    view.windowChanged = { [weak self, weak view] inWindow in
      guard let self, let view else { return }
      self.lock.withLock {
        if inWindow {
          self.scopeLayer = view.metalLayer
          self.stateVersion &+= 1
        } else if self.scopeLayer === view.metalLayer {
          self.scopeLayer = nil
        }
      }
    }
    refresh(force: true)
    return view
  }

  @MainActor func scopeViewRemoved(_ layer: CAMetalLayer) {
    lock.withLock { if scopeLayer === layer { scopeLayer = nil } }
  }

  /// The picture view's layer while it exists (tests and diagnostics).
  @MainActor var pictureLayer: CAMetalLayer? { (visibilityView as? MonitorPictureNSView)?.metalLayer }

  /// The picture view's render loop while it exists (tests and diagnostics).
  @MainActor var renderLoop: MonitorSurfaceRenderLoop? { (visibilityView as? MonitorPictureNSView)?.renderLoop }

  // MARK: Published state (main actor, about twice a second)

  /// "Legal range · BT.709 · BT.709 matrix", as MonitorTools described a signal.
  static func describe(_ signal: SignalDescription?) -> String {
    guard let signal else { return "Range / transfer interpretation unavailable" }
    let range = signal.range == .full ? "Full range" : "Legal range"
    let transfer: String
    switch signal.encoding {
    case .display(let t):
      switch t {
      case .bt709: transfer = "BT.709"
      case .sRGB: transfer = "sRGB"
      case .pq: transfer = "PQ"
      case .hlg: transfer = "HLG"
      case .linear: transfer = "Linear"
      }
    case .log(let e): transfer = "\(e.curve.rawValue) / \(e.gamut.rawValue)"
    case .unknown: transfer = "unknown transfer"
    }
    let matrix: String
    switch signal.matrix {
    case .bt709: matrix = "BT.709"
    case .bt601: matrix = "BT.601"
    case .bt2020: matrix = "BT.2020"
    case .smpte240m: matrix = "SMPTE 240M"
    }
    return "\(range) · \(transfer) · \(matrix) matrix"
  }

  /// MonitorKit's status as lines for the tile: what is drawn, and why a tool
  /// that is on is not.
  static func describe(_ status: MonitorStatus) -> [String] {
    var lines = status.activeLabels
    for entry in status.unavailable { lines.append("\(entry.tool.statusTitle) unavailable: \(entry.reason)") }
    return lines
  }

  @MainActor private func refresh(force: Bool) {
    lock.lock()
    refreshScheduled = false
    let live = latest
    let frozenValue = frozen
    let held = latest == nil ? lingering : nil
    let pending = pendingFreeze
    let unavailable = resuming ? "Resuming" : unavailableReason
    let statuses = rendererStatus
    let drawnStatus = pictureStatus
    let currentPreferences = preferences
    let state = encodeState
    let now = ProcessInfo.processInfo.systemUptime
    // Rates over the last window.
    if window.start == 0 { window.start = now }
    if now - window.start >= 1 {
      let elapsed = now - window.start
      published.acceptedFPS = Double(counters.acceptedFrames - window.accepted) / elapsed
      published.presentedFPS = Double(counters.presentedFrames - window.presented) / elapsed
      published.scopeFPS = Double(counters.scopeUpdates - window.scopes) / elapsed
      published.pictureGPUMilliseconds = gpuTime.pictures > 0 ? gpuTime.picture / Double(gpuTime.pictures) : nil
      published.scopeGPUMilliseconds = gpuTime.scopes > 0 ? gpuTime.scope / Double(gpuTime.scopes) : nil
      gpuTime = (0, 0, 0, 0)
      window = (now, counters.acceptedFrames, counters.presentedFrames, counters.scopeUpdates)
    }
    let lastScope = counters.lastScope
    let failure = now - lastFailureTime < 1 ? counters.lastFailure : nil
    lock.unlock()
    let frozenNow = frozenValue != nil
    if isFrozen != frozenNow { isFrozen = frozenNow }
    if isFreezePending != pending { isFreezePending = pending }
    let shown = frozenValue ?? held
    let shownTools = shown?.preferences ?? currentPreferences
    if shownPreferences != shownTools { shownPreferences = shownTools }
    if shownStatus != drawnStatus { shownStatus = drawnStatus }
    let occluded = !frozenNow && visibilityReported && !visibility.drawable
    if pending {
      status = "Waiting to freeze next picture"
      detail = status
      return
    }
    let stamp = shown?.stamp ?? live?.stamp
    guard let stamp else {
      scopeTiming = "No scope signal"
      status = occluded ? (visibility.presented ? "Occluded" : "Paused / hidden") : unavailable
      detail = status
      return
    }
    if occluded {
      status = visibility.presented ? "Occluded" : "Paused / hidden"
      detail = status
      return
    }
    guard force || now - lastStatusUpdate >= 0.5 else { return }
    lastStatusUpdate = now
    // A picture that fails to draw is reported on the tile, never shown as Live.
    if let reason = gpu.unavailableReason ?? failure, !frozenNow {
      status = "Monitor error"
      detail = reason
      return
    }
    let signal = shown?.signal ?? live?.signal
    let outputSignal = shown?.outputSignal ?? live?.outputSignal
    let geometry = shown?.geometry ?? live?.geometry
    if shownSignal != signal { shownSignal = signal }
    /// How a pass on `stage` reads the frame (a declared range is the Source's alone).
    func reading(_ stage: SignalStage) -> SignalDescription? { stage == .source ? signal : outputSignal }
    let interpretation = Self.describe(
      signal.flatMap { reading(MonitorFeedHost.pictureReading(shown?.state ?? state, signal: $0)) })
    if pictureInterpretation != interpretation { pictureInterpretation = interpretation }
    // Scopes measure the stage their settings name; with no LUT on it that is the signal itself.
    let scopeSignal = scopeMeasuresLUT(shownTools) ? nil : reading(shownTools.scopes.settings.stage)
    let scopeText = scopeSignal.map { Self.describe($0) } ?? "Rec.709 (after the LUT)"
    if scopeInterpretation != scopeText { scopeInterpretation = scopeText }
    if let geometry {
      let aspect = geometry.displayAspectRatio(for: shown?.state ?? state)
      if aspect.isFinite, aspect > 0, abs(aspect - pictureAspectRatio) > 0.0001 { pictureAspectRatio = aspect }
    }
    let age = max(0, now - stamp.hostTime)
    status = frozenNow ? "Frozen" : age > 0.25 ? "Stale" : "Live"
    var text = "Picture PTS \(String(format: "%.3f", stamp.sourcePTS)) · \(String(format: "%.1f", age)) s old"
    if shownTools.scopesShown, let lastScope {
      let scopeAge = max(0, now - lastScope.hostTime)
      let scopeState =
        frozenNow ? "Frozen" : scopeAge > max(0.25, 3.0 / Double(max(1, shownTools.scopes.refreshHz))) ? "Stale" : "Live"
      scopeTiming =
        "\(scopeState) · Scope PTS \(String(format: "%.3f", lastScope.sourcePTS)) · \(String(format: "%.1f", scopeAge)) s old"
      text += " · Scope PTS \(String(format: "%.3f", lastScope.sourcePTS))"
    } else {
      scopeTiming = "No scope signal"
    }
    if let reason = gpu.unavailableReason { text += " · " + reason }
    if let lut = host.lutMismatch { text += " · " + lut }
    if !statuses.isEmpty { text += " · " + statuses.joined(separator: " · ") }
    detail = text
  }
}

extension MonitorSurfacePresenter: MonitorGPUCompletion {
  /// A freeze copy's completion: a failed copy is a counted surface failure.
  func gpuCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    recordGPU(kind: kind, milliseconds: (gpuEnd - gpuStart) * 1000, failed: failed)
  }
}

extension MonitorTool {
  /// The tool's name in the tile's status lines.
  var statusTitle: String {
    switch self {
    case .falseColor: return "False color"
    case .zebra1: return "Zebra"
    case .zebra2: return "Second zebra"
    case .focusPeaking: return "Focus peaking"
    case .guides: return "Guides"
    case .burnInLUT: return "LUT"
    case .monitorLUT: return "Monitor LUT"
    case .magnification: return "Zoom"
    case .desqueeze: return "De-squeeze"
    case .flip: return "Flip"
    case .displayAdjustments: return "Display adjustments"
    case .displayTransform: return "Display transform"
    case .clipIndicators: return "Clip indicators"
    case .picture: return "Picture"
    }
  }
}

// MARK: - Views

private final class MonitorWindowObservations: @unchecked Sendable {
  var tokens: [NSObjectProtocol] = []
  func clear() {
    tokens.forEach { NotificationCenter.default.removeObserver($0) }
    tokens = []
  }
  deinit { clear() }
}

/// Reports whether a surface can be seen: in a window, not hidden, the window
/// visible, not minimized and not fully covered. Invisible surfaces do no GPU work.
@MainActor class MonitorVisibilityNSView: NSView {
  var visibilityChanged: ((Bool, Bool) -> Void)?
  private let windowObservers = MonitorWindowObservations()
  private var closing = false
  private(set) var isDrawable = false
  override var isHidden: Bool { didSet { reportVisibility() } }
  override func viewDidHide() {
    super.viewDidHide()
    reportVisibility()
  }
  override func viewDidUnhide() {
    super.viewDidUnhide()
    reportVisibility()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowObservers.clear()
    closing = false
    if let window {
      for name in [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
        NSWindow.didChangeScreenNotification,
      ] {
        windowObservers.tokens.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] notification in
            let isClosing = notification.name == NSWindow.willCloseNotification
            MainActor.assumeIsolated {
              if isClosing { self?.closing = true }
              self?.reportVisibility()
            }
          })
      }
    }
    reportVisibility()
  }
  /// Test hook: a test runner that is not the active app gets no occlusion updates
  /// for its windows although Core Animation still draws them, so tests that need
  /// the display link treat every presented view as drawable.
  static var treatsPresentedViewsAsDrawable = false
  func reportVisibility() {
    let presented = window != nil && !isHiddenOrHasHiddenAncestor && !closing
    let drawable =
      presented
      && (Self.treatsPresentedViewsAsDrawable
        || (window?.isVisible == true && window?.isMiniaturized == false
          && window?.occlusionState.contains(.visible) == true))
    isDrawable = drawable
    drawableChanged(drawable)
    visibilityChanged?(presented, drawable)
  }
  func drawableChanged(_ drawable: Bool) {}
}

/// The live picture: a `framebufferOnly` CAMetalLayer that MonitorKit's picture
/// pass renders into, driven by a display link on the monitor render thread.
/// Each refresh with a new frame (or a changed tool, size or freeze state) encodes
/// one picture into the drawable. The layer's format, colour space and EDR follow
/// the shown picture's signal (MonitorKit's output-colour resolver).
@MainActor final class MonitorPictureNSView: MonitorVisibilityNSView {
  let metalLayer = CAMetalLayer()
  let renderLoop: MonitorSurfaceRenderLoop
  private weak var presenter: MonitorSurfacePresenter?
  private var aspectObservation: AnyCancellable?

  init(presenter: MonitorSurfacePresenter) {
    self.presenter = presenter
    renderLoop = MonitorSurfaceRenderLoop(presenter: presenter, layer: metalLayer)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    MonitorSurfaceRenderLoop.initialColor.apply(to: metalLayer)
    // MonitorKit renders the picture: every drawable write is a render-target write.
    metalLayer.framebufferOnly = true
    metalLayer.maximumDrawableCount = 3
    metalLayer.device = presenter.gpu.layerDevice
    metalLayer.isOpaque = true
    metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    layer?.addSublayer(metalLayer)
    aspectObservation = presenter.$pictureAspectRatio.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.needsLayout = true }
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The layer is the picture's aspect-fit rectangle, so the drawable holds only
  /// picture pixels.
  override func layout() {
    super.layout()
    let aspect = presenter?.pictureAspectRatio ?? 16.0 / 9.0
    let fit = MonitorRect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
      .fitting(aspect: aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0)
    let frame = CGRect(x: fit.x, y: fit.y, width: fit.width, height: fit.height)
    let scale = window?.backingScaleFactor ?? 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    metalLayer.frame = frame.integral
    if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
    let size = CGSize(
      width: max(1, (metalLayer.frame.width * scale).rounded()),
      height: max(1, (metalLayer.frame.height * scale).rounded()))
    if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    CATransaction.commit()
  }

  /// Moving between a 1x and a 2x display changes the backing scale: resize the
  /// drawables to match. (The display link follows the layer's display and its
  /// refresh rate by itself.)
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      // Starts paused unless the window can be seen now (a hidden window never
      // runs the link until it is shown).
      renderLoop.start(paused: !isDrawable)
    } else {
      renderLoop.stop()
    }
  }

  override func drawableChanged(_ drawable: Bool) { renderLoop.setPaused(!drawable) }

  func tearDown() { renderLoop.stop() }
}

/// The scope picture: MonitorKit's scope image (MonitorTools' look: 768 × 256,
/// −10…110 IRE) in a `framebufferOnly` layer of its own. The picture's render
/// loop draws it with a second display link at the user's scope rate, so the
/// picture never waits for a scope drawable.
@MainActor final class MonitorScopeNSView: NSView {
  let metalLayer = CAMetalLayer()
  var removedFromPresenter: ((CAMetalLayer) -> Void)?
  var windowChanged: ((Bool) -> Void)?
  private let gpu: MonitorGPUContext
  /// The layer's drawable residency set; nil until the layer has a device.
  nonisolated(unsafe) private let drawableSet: MTLResidencySet?

  init(gpu: MonitorGPUContext) {
    let device = gpu.layerDevice
    metalLayer.device = device
    // CAMetalLayer.residencySet is nil until a device is set, though Swift imports
    // it as non-optional. Read it only once the device is assigned.
    drawableSet = device == nil ? nil : metalLayer.residencySet
    self.gpu = gpu
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    metalLayer.pixelFormat = .bgra8Unorm
    // Scope traces are display graphics: colour-managed as sRGB.
    metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metalLayer.framebufferOnly = true
    metalLayer.maximumDrawableCount = 3
    metalLayer.drawableSize = CGSize(
      width: ScopeSettings.ultracamLegacyImageWidth, height: ScopeSettings.ultracamLegacyImageHeight)
    metalLayer.contentsGravity = .resize
    metalLayer.isOpaque = false
    metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    layer?.addSublayer(metalLayer)
    if let drawableSet { gpu.attachDrawables(drawableSet) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    metalLayer.frame = bounds
    CATransaction.commit()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowChanged?(window != nil)
  }
  deinit {
    // Detaching is thread-safe; never through a render-thread block, which a stop drops.
    if let drawableSet { gpu.detachDrawables(drawableSet) }
  }
}

/// Render-thread side of one picture surface and its scope. Confined to the
/// render thread except `start`, `stop` and `setPaused`, which hop onto it.
///
/// Per refresh with something new: wrap the frame (resident texture cache, no
/// allocation), analyse focus once per frame per feed, and render one MonitorKit
/// picture pass into the drawable in one submission on the monitor queue. Scopes
/// accumulate and draw in their own submission at the scope rate, with at most
/// two on the GPU.
final class MonitorSurfaceRenderLoop: NSObject, CAMetalDisplayLinkDelegate, MonitorGPUCompletion,
  @unchecked Sendable
{
  static let pictureKind = 1
  static let scopeKind = 2
  static let freezeKind = 3
  /// Every picture layer starts as Rec.709 SDR, as MonitorTools' did.
  static let initialColor = MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886))

  private weak var presenter: MonitorSurfacePresenter?
  private let gpu: MonitorGPUContext
  private let host: MonitorFeedHost
  private let layer: CAMetalLayer
  private var link: CAMetalDisplayLink?
  /// Draws the scope layer; created while a scope view is in a window.
  private var scopeLink: CAMetalDisplayLink?
  private var scopeLinkLayer: CAMetalLayer?
  private var scopeLinkHz = 0
  private var paused = false
  private var versions: (UInt64, UInt64) = (UInt64.max, UInt64.max)
  private var drawnSize = (width: 0, height: 0)
  private var nextScopeTime = 0.0
  private var attached = false
  private var drawableSet: MTLResidencySet?
  private var pass: MonitorPass?
  private var clearPass: MTL4RenderPassDescriptor?
  private var accumulator: ScopeAccumulator?
  private var scopeRenderer: ScopeRenderer?
  /// The layer's colour and what it was chosen for.
  private(set) var appliedColor = MonitorSurfaceRenderLoop.initialColor
  private struct ColorKey: Equatable {
    let signal: SignalDescription
    let transform: DisplayTransform
    let monitorStageHasLUT: Bool
  }
  private var colorKey: ColorKey?
  /// Layer colour changes so far (tests).
  private(set) var colorChanges = 0

  /// The newest drawn picture, held only until its scope has been drawn.
  enum ScopeSource {
    case live(MonitorFeedHost.Delivery)
    /// An owned copy (the Source reading), the feed it belongs to, and the Output reading.
    case frozen(MonitorFrame, MonitorFeed, outputSignal: SignalDescription)
  }
  private var scopePending: (source: ScopeSource, key: ScopeKey)?
  /// When the pending live frame was drawn. Its cached textures leave residency
  /// once idle, so a frame the scope link could not draw for this long is dropped.
  private var scopePendingAt = 0.0
  private static let pendingScopeLifetime = 0.5
  private var scopedKey: ScopeKey?
  /// When the pending scope became due, and when the next skip may be counted.
  private var scopeDueAt = 0.0
  private var nextSkipCount = 0.0

  init(presenter: MonitorSurfacePresenter, layer: CAMetalLayer) {
    self.presenter = presenter
    gpu = presenter.gpu
    host = presenter.host
    self.layer = layer
  }

  func start(paused: Bool) {
    gpu.renderThread.perform { [self] in
      self.paused = paused
      guard link == nil else {
        link?.isPaused = paused
        return
      }
      // No device means no Metal: leave the picture black rather than crash.
      guard layer.device != nil, let runLoop = gpu.renderThread.runLoopForDisplayLinks else { return }
      if !attached {
        drawableSet = layer.residencySet
        gpu.attachDrawables(layer.residencySet)
        attached = true
      }
      let link = CAMetalDisplayLink(metalLayer: layer)
      link.delegate = self
      link.preferredFrameLatency = 2
      link.isPaused = paused
      link.add(to: runLoop, forMode: .default)
      self.link = link
      versions = (UInt64.max, UInt64.max)
    }
  }

  func stop() {
    gpu.renderThread.perform { [self] in
      link?.invalidate()
      link = nil
      setScopeLayer(nil)
      scopePending = nil
    }
  }

  func setPaused(_ paused: Bool) {
    gpu.renderThread.perform { [self] in
      self.paused = paused
      link?.isPaused = paused
      scopeLink?.isPaused = paused
      if paused {
        // A surface nobody can see holds no frame for a scope.
        scopePending = nil
      } else {
        // Redraw on resume: the layer may have been cleared while hidden.
        versions = (UInt64.max, UInt64.max)
      }
    }
  }

  deinit {
    nonisolated(unsafe) let links = (link, scopeLink)
    nonisolated(unsafe) let confined = (pass, accumulator, scopeRenderer)
    // Detaching is thread-safe; the links and MonitorKit objects end on the render thread.
    if let set = drawableSet { gpu.detachDrawables(set) }
    gpu.renderThread.perform {
      links.0?.invalidate()
      links.1?.invalidate()
      withExtendedLifetime(confined) {}
    }
  }

  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    if link === scopeLink {
      drawScope(update)
      return
    }
    guard link === self.link, let presenter else { return }
    setScopeLayer(presenter.currentScopeLayer)
    noteMissedScope(now: update.targetTimestamp)
    let drawable = update.drawable
    let size = (width: drawable.texture.width, height: drawable.texture.height)
    let resized = size != drawnSize
    guard let work = presenter.renderWork(after: versions, force: resized) else { return }
    let core: MonitorGPUContext.Core
    do {
      core = try gpu.core()
    } catch {
      presenter.recordFailure(error)
      return
    }
    presenter.refreshBurnInLUT()
    // What the picture shows, and with which feed (its LUTs and focus mask).
    let feed = drawingFeed(for: work, core: core)
    if let signal = work.signal, applyColor(signal: signal, state: work.state, feed: feed) {
      // This drawable has the old pixel format: draw the next one, in the new.
      versions = (UInt64.max, UInt64.max)
      return
    }
    versions = (work.latestVersion, work.stateVersion)
    drawnSize = size
    let context: MonitorGPUContext.EncodeContext
    do {
      context = try core.begin()
    } catch {
      presenter.recordFailure(error)
      versions = (UInt64.max, UInt64.max)
      return
    }
    let scopeSource: ScopeSource?
    do {
      scopeSource = try encode(work, feed: feed, target: drawable.texture, core: core, context: context)
    } catch {
      core.abandon(context, drawable: drawable)
      presenter.recordFailure(error)
      versions = (UInt64.max, UInt64.max)
      return
    }
    core.commit(context, drawable: drawable, completion: self, kind: Self.pictureKind)
    presenter.recordPresented(work.stamp)
    if let pass, scopeSource != nil { presenter.recordStatus(pass.status) }
    guard let scopeSource, let stamp = work.stamp, Self.wantsScopes(work), let scopeLinkLayer else { return }
    let key = ScopeKey(
      stamp: stamp, frozenToken: work.frozenToken, layer: ObjectIdentifier(scopeLinkLayer),
      scopes: work.preferences.scopes, monitorLUT: work.state.monitorLUT)
    guard key != scopedKey else { return }
    let now = update.targetTimestamp
    if scopePending == nil { scopeDueAt = isImmediate(key) ? now : max(now, nextScopeTime) }
    scopePending = (scopeSource, key)
    scopePendingAt = now
    setScopeRate(key.scopes.refreshHz)
  }

  /// Encodes `work`'s picture into `target` (a drawable, or an offscreen texture
  /// in tests) in `context`; returns what its scope would show. `feed` is the one
  /// the picture is drawn with (the host's, or a hold's own). Render thread.
  func encode(
    _ work: MonitorSurfacePresenter.RenderWork, feed: MonitorFeed, target: MTLTexture,
    core: MonitorGPUContext.Core, context: MonitorGPUContext.EncodeContext
  ) throws -> ScopeSource? {
    switch work.content {
    case .none:
      try encodeClear(target, into: context)
      return nil
    case .live(let delivery), .frozenLive(let delivery, _):
      let stage = MonitorFeedHost.pictureReading(work.state, signal: delivery.signal)
      let frame = try host.frame(delivery, in: context, core: core, reading: stage)
      try drawPicture(
        frame, feed: feed, state: work.state, target: target, core: core, context: context,
        focusSignal: delivery.signal(reading: work.state.focus.stage))
      return .live(delivery)
    case .frozenOwned(let owned, let owner, _, let outputSignal):
      let stage = MonitorFeedHost.pictureReading(work.state, signal: owned.signal)
      try drawPicture(
        MonitorSurfacePresenter.reading(owned, stage, outputSignal: outputSignal), feed: owner, state: work.state,
        target: target, core: core, context: context,
        focusSignal: MonitorSurfacePresenter.reading(owned, work.state.focus.stage, outputSignal: outputSignal).signal)
      return .frozen(owned, owner, outputSignal: outputSignal)
    }
  }

  /// The feed `work` is drawn with: a hold's own, else the host's (made on first use).
  func drawingFeed(for work: MonitorSurfacePresenter.RenderWork, core: MonitorGPUContext.Core) -> MonitorFeed {
    if case .frozenOwned(_, let owner, _, _) = work.content { return owner }
    return host.feed(engine: core.engine)
  }

  /// The picture of `frame` into `target`: focus analysis (once per frame and
  /// feed: MonitorKit skips a frame it already analysed), then the picture pass.
  /// The analysis reads the frame as its own stage does (`focusSignal`).
  private func drawPicture(
    _ frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, target: MTLTexture,
    core: MonitorGPUContext.Core, context: MonitorGPUContext.EncodeContext, focusSignal: SignalDescription
  ) throws {
    let pass = try picturePass(core)
    context.keep(frame)
    if state.focus.enabled && !state.clean {
      var analysed = frame
      analysed.signal = focusSignal
      try feed.analyze(analysed, focus: state.focus, into: context.submission)
    }
    try pass.encode(frame: frame, feed: feed, state: state, target: target, clear: true, into: context.submission)
  }

  private func picturePass(_ core: MonitorGPUContext.Core) throws -> MonitorPass {
    if let pass, pass.engine === core.engine { return pass }
    let made = core.engine.makePass()
    pass = made
    return made
  }

  /// A black drawable (no signal).
  private func encodeClear(_ target: MTLTexture, into context: MonitorGPUContext.EncodeContext) throws {
    let descriptor: MTL4RenderPassDescriptor
    if let clearPass {
      descriptor = clearPass
    } else {
      descriptor = MTL4RenderPassDescriptor()
      let attachment = descriptor.colorAttachments[0]!
      attachment.loadAction = .clear
      attachment.storeAction = .store
      attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      clearPass = descriptor
    }
    let attachment = descriptor.colorAttachments[0]!
    attachment.texture = target
    let encoder = context.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    attachment.texture = nil
    guard let encoder else { throw MonitorKitError.gpu("Cannot create a render encoder to clear the picture.") }
    encoder.endEncoding()
  }

  /// Tags the layer for the picture MonitorKit writes (signal-native: the signal's
  /// own encoding; Rec.709 after a LUT; EDR for HLG and PQ; primaries from the
  /// signal's label, independently of its transfer) when that changes. Returns
  /// whether the pixel format changed. Render thread (tests call it directly).
  @discardableResult
  func applyColor(signal: SignalDescription, state: MonitorState, feed: MonitorFeed) -> Bool {
    let key = ColorKey(
      signal: signal, transform: state.displayTransform.mode,
      monitorStageHasLUT: feed.monitorStageHasLUT(for: state))
    guard key != colorKey else { return false }
    colorKey = key
    let color = MonitorOutputColor.signalNative.layer(
      for: signal, displayTransform: key.transform, monitorStageHasLUT: key.monitorStageHasLUT)
    guard color != appliedColor else { return false }
    let formatChanged = color.pixelFormat != appliedColor.pixelFormat
    appliedColor = color
    colorChanges += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    color.apply(to: layer)
    CATransaction.commit()
    // Keep the drawables resident if the layer made a new set for the new format.
    if attached, let set = drawableSet, layer.residencySet !== set {
      gpu.detachDrawables(set)
      drawableSet = layer.residencySet
      gpu.attachDrawables(layer.residencySet)
    }
    return formatChanged
  }

  // MARK: Scopes

  private struct ScopeKey: Equatable {
    let stamp: MonitorFeedHost.Stamp
    let frozenToken: UInt64?
    let layer: ObjectIdentifier?
    let scopes: MonitorScopePreferences
    let monitorLUT: Bool
  }

  private static func wantsScopes(_ work: MonitorSurfacePresenter.RenderWork) -> Bool {
    work.preferences.scopesShown && !work.state.clean
  }

  /// A held picture, a new scope view or changed scope settings draw at once.
  private func isImmediate(_ key: ScopeKey) -> Bool {
    key.frozenToken != nil || scopedKey?.layer != key.layer || scopedKey?.scopes != key.scopes
      || scopedKey?.monitorLUT != key.monitorLUT
  }

  /// Follows the presenter's scope layer: one scope display link per layer.
  private func setScopeLayer(_ scopeLayer: CAMetalLayer?) {
    guard scopeLayer !== scopeLinkLayer else { return }
    scopeLink?.invalidate()
    scopeLink = nil
    scopeLinkLayer = scopeLayer
    scopeLinkHz = 0
    guard let scopeLayer, scopeLayer.device != nil, let runLoop = gpu.renderThread.runLoopForDisplayLinks else {
      scopePending = nil
      return
    }
    let link = CAMetalDisplayLink(metalLayer: scopeLayer)
    link.delegate = self
    link.preferredFrameLatency = 2
    link.isPaused = paused
    link.add(to: runLoop, forMode: .default)
    scopeLink = link
  }

  /// Asks the scope link for the user's scope rate rather than every refresh.
  private func setScopeRate(_ hz: Int) {
    let rate = max(1, min(60, hz))
    guard let scopeLink, rate != scopeLinkHz else { return }
    scopeLinkHz = rate
    scopeLink.preferredFrameRateRange = CAFrameRateRange(
      minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
  }

  private func scopeInterval(_ key: ScopeKey) -> Double {
    1.0 / Double(max(1, min(60, key.scopes.refreshHz)))
  }

  /// A due scope the scope link has not drawn for a whole scope interval had no
  /// drawable: counted, at most once per interval. The frame stays pending.
  private func noteMissedScope(now: Double) {
    guard let key = scopePending?.key, let presenter else { return }
    let interval = scopeInterval(key)
    guard now - scopeDueAt > interval + 0.004, now >= nextSkipCount else { return }
    nextSkipCount = now + interval
    presenter.recordScopeSkip(busy: false)
  }

  /// Scopes get their own submission at the user's rate, drawn into the scope
  /// link's drawable, which never blocks. The newest drawn frame waits here until
  /// its scope is due, so the scope always catches up to the last picture (for
  /// example the final frame before a feed stops).
  private func drawScope(_ update: CAMetalDisplayLink.Update) {
    guard let pending = scopePending, let presenter else { return }
    let key = pending.key
    guard key.scopes.enabled, let scopeLinkLayer, key.layer == ObjectIdentifier(scopeLinkLayer) else {
      scopePending = nil
      return
    }
    let now = update.targetTimestamp
    // A live frame the scope link couldn't draw for this long is dropped, counted,
    // rather than encoded from textures that may be gone; it also stops pinning
    // the capture buffer. Held (frozen) frames own theirs.
    if key.frozenToken == nil, now - scopePendingAt > Self.pendingScopeLifetime {
      scopePending = nil
      presenter.recordScopeSkip(busy: false)
      return
    }
    let interval = scopeInterval(key)
    guard isImmediate(key) || now >= nextScopeTime - 0.002 else { return }
    // At most two scope submissions on the GPU. Beyond that the GPU is behind:
    // this update is skipped (counted) and the newest frame's scope drawn later.
    guard presenter.beginScope(limit: 2) else {
      if now >= nextSkipCount {
        nextSkipCount = now + interval
        presenter.recordScopeSkip(busy: true)
      }
      return
    }
    scopePending = nil
    scopedKey = key
    // Keep the user's cadence; after a gap, restart it from now.
    nextScopeTime = nextScopeTime + interval > now ? nextScopeTime + interval : now + interval
    let drawable = update.drawable
    let core: MonitorGPUContext.Core
    let context: MonitorGPUContext.EncodeContext
    do {
      core = try gpu.core()
      context = try core.begin()
    } catch {
      presenter.cancelScope()
      presenter.recordFailure(error)
      return
    }
    do {
      let frame: MonitorFrame
      let feed: MonitorFeed
      switch pending.source {
      case .live(let delivery):
        frame = try host.frame(delivery, in: context, core: core, reading: key.scopes.settings.stage)
        feed = host.feed(engine: core.engine)
      case .frozen(let held, let owner, let outputSignal):
        frame = MonitorSurfacePresenter.reading(held, key.scopes.settings.stage, outputSignal: outputSignal)
        feed = owner
      }
      context.keep(frame)
      let (accumulator, renderer) = try scopeObjects(core, settings: key.scopes.settings)
      try accumulator.accumulate(frame, feed: feed, monitorLUTEnabled: key.monitorLUT, into: context.submission)
      try renderer.render(accumulator, target: drawable.texture, clear: true, into: context.submission)
    } catch {
      core.abandon(context, drawable: drawable)
      presenter.cancelScope()
      presenter.recordFailure(error)
      return
    }
    core.commit(context, drawable: drawable, completion: self, kind: Self.scopeKind)
    presenter.recordScope(key.stamp)
  }

  /// The surface's scope accumulator and renderer, made on first use; a settings
  /// change only updates the accumulator's settings.
  private func scopeObjects(_ core: MonitorGPUContext.Core, settings: ScopeSettings) throws
    -> (ScopeAccumulator, ScopeRenderer)
  {
    if let accumulator, let scopeRenderer, accumulator.engine === core.scopeEngine {
      if accumulator.settings != settings { accumulator.settings = settings }
      return (accumulator, scopeRenderer)
    }
    let made = try core.scopeEngine.makeAccumulator(settings: settings)
    let renderer = core.scopeEngine.makeRenderer()
    accumulator = made
    scopeRenderer = renderer
    presenter?.publishScopeStatisticsReader(made.statisticsReader)
    return (made, renderer)
  }

  func gpuCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    presenter?.recordGPU(kind: kind, milliseconds: (gpuEnd - gpuStart) * 1000, failed: failed)
  }
}

// MARK: - SwiftUI

extension MonitorScopePreferences {
  /// The IRE labels beside this scope's trace, on its level axis and bins.
  var ireScale: ScopeIREScale {
    ScopeIREScale(axis: settings.levelRange.low...settings.levelRange.high, bins: settings.waveformLevels)
  }

  /// "RGB parade", "Luma waveform", …
  var title: String {
    switch settings.kind {
    case .waveform:
      switch settings.waveformMode {
      case .rgbParade: return "RGB parade"
      case .luma: return "Luma waveform"
      case .rgbOverlay: return "RGB overlay"
      case .ycbcrParade: return "YCbCr parade"
      }
    default: return settings.kind.rawValue.capitalized
    }
  }
}

struct MonitorNativePicture: NSViewRepresentable {
  let presenter: MonitorSurfacePresenter
  func makeNSView(context: Context) -> NSView { presenter.makeView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
  static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    (nsView as? MonitorPictureNSView)?.tearDown()
  }
}

struct MonitorNativeScope: NSViewRepresentable {
  let presenter: MonitorSurfacePresenter
  func makeNSView(context: Context) -> NSView { presenter.makeScopeView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
  static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    guard let view = nsView as? MonitorScopeNSView else { return }
    view.removedFromPresenter?(view.metalLayer)
  }
}

/// Tracks visibility for a surface without a picture of its own.
struct MonitorSurfaceVisibility: NSViewRepresentable {
  let presenter: MonitorSurfacePresenter
  func makeNSView(context: Context) -> NSView { presenter.makeVisibilityView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
