import AppKit
import Combine
import Metal
import MonitorToolsCore
import MonitorToolsMetal
import QuartzCore
import SwiftUI

/// Counters for one surface. Rates are refreshed about once a second.
public struct MonitorSurfaceStatistics: Equatable, Sendable {
  public var acceptedFrames: UInt64 = 0
  public var presentedFrames: UInt64 = 0
  /// Frames replaced by a newer one before any display refresh took them.
  public var supersededFrames: UInt64 = 0
  public var scopeUpdates: UInt64 = 0
  /// Scope updates that were due but not drawn: the previous scopes were still
  /// on the GPU (busy), or the scope layer gave no drawable for a whole scope
  /// interval. Scopes are analysis; a skip never delays the picture.
  public var scopeSkippedBusy: UInt64 = 0
  public var scopeSkippedNoDrawable: UInt64 = 0
  public var failures: UInt64 = 0
  public var acceptedFPS = 0.0
  public var presentedFPS = 0.0
  public var scopeFPS = 0.0
  /// Mean GPU milliseconds over the last window.
  public var pictureGPUMilliseconds: Double?
  public var scopeGPUMilliseconds: Double?
  public var lastPresented: MonitorFrameStamp?
  public var lastScope: MonitorFrameStamp?
  public var lastFailure: String?
  public init() {}
}

/// One monitor surface. Producers hand it frames with `accept`; the newest one
/// waits in a single slot until the surface's display link draws it on the
/// next refresh. Nothing is copied on the way in. A frozen surface takes no
/// new frames, and a surface that stops being drawable drops the one it had,
/// so neither keeps a producer buffer.
public final class MonitorSurfacePresenter: ObservableObject, @unchecked Sendable {
  public let runtime: MonitorRuntime
  private let lock = NSLock()
  private struct Live {
    let bundle: MonitorFrameBundle
    let configuration: MonitorConfiguration
  }
  /// A held picture. `owned` replaces `live` once a view has copied it on the GPU.
  private struct Frozen {
    let token: UInt64
    let configuration: MonitorConfiguration
    var live: MonitorFrameBundle?
    var owned: MonitorGPUFrame?
    var stamp: MonitorFrameStamp
    var fromPendingRequest = false
  }
  private var latest: Live?
  private var latestVersion: UInt64 = 0
  private var takenVersion: UInt64 = 0
  private var stateVersion: UInt64 = 1
  private var lastAcceptedStamp: MonitorFrameStamp?
  private var unavailableReason = "No Signal"
  /// Set by setUnavailable until the next accepted frame.
  private var signalLost = false
  /// Set while the surface is reported not drawable (hidden, occluded,
  /// minimized): its display link is paused and it holds no producer frame.
  private var hidden = false
  /// The hidden surface dropped its frame; shown as resuming, not as no signal.
  private var resuming = false
  private var frozen: Frozen?
  /// A just-released hold, still drawn until the next live frame arrives so
  /// unfreezing never flashes black.
  private var lingering: Frozen?
  private var nextFreezeToken: UInt64 = 0
  private var pendingFreeze = false
  private var clean = false
  private var rendererStatus: [String] = []
  private var counters = MonitorSurfaceStatistics()
  private var lastFailureTime = -Double.infinity
  /// Scope commits on the GPU; drawables are requested only while one is free.
  private var scopesInFlight = 0
  private var window = (start: 0.0, accepted: UInt64(0), presented: UInt64(0), scopes: UInt64(0))
  private var gpu = (picture: 0.0, pictures: 0, scope: 0.0, scopes: 0)
  private var published = MonitorSurfaceStatistics()
  private var refreshScheduled = false
  private weak var scopeLayer: CAMetalLayer?
  private var statusTimer: Timer?
  private var lastStatusUpdate = 0.0
  /// Makes freeze copies on the render thread; it never draws.
  private let freezeCopier: MonitorToolsRenderer

  @MainActor @Published public private(set) var status = "No Signal"
  @MainActor @Published public private(set) var detail = ""
  @MainActor @Published public private(set) var isFrozen = false
  @MainActor @Published public private(set) var isFreezePending = false
  @MainActor @Published public private(set) var isClean = false
  @MainActor @Published public private(set) var pictureInterpretation =
    "Range / transfer interpretation unavailable"
  @MainActor @Published public private(set) var scopeTiming = "No scope signal"
  @MainActor @Published public private(set) var scopeInterpretation =
    "Range / transfer interpretation unavailable"
  @MainActor @Published public private(set) var pictureAspectRatio = 16.0 / 9.0
  @MainActor @Published public private(set) var configuration = MonitorConfiguration()
  @MainActor public var onVisibilityChange: ((Bool, Bool) -> Void)?
  @MainActor private weak var visibilityView: MonitorVisibilityNSView?
  @MainActor private var visibility = (presented: false, drawable: false)
  @MainActor private var visibilityReported = false

  public init(runtime: MonitorRuntime = .shared) {
    self.runtime = runtime
    freezeCopier = MonitorToolsRenderer(runtime: runtime)
    DispatchQueue.main.async { [weak self] in
      self?.statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
        [weak self] _ in
        let presenter = self
        MainActor.assumeIsolated { presenter?.refresh(force: true) }
      }
    }
  }
  deinit {
    statusTimer?.invalidate()
    if let owned = frozen?.owned { runtime.release(owned) }
    if let owned = lingering?.owned { runtime.release(owned) }
  }

  public var currentStamp: MonitorFrameStamp? {
    lock.lock()
    defer { lock.unlock() }
    return frozen?.stamp ?? latest?.bundle.stamp ?? lingering?.stamp
  }

  /// True while the surface keeps a producer (capture or processing) buffer:
  /// a live frame waiting to be drawn, or a hold not yet copied on the GPU.
  var holdsProducerFrame: Bool {
    lock.lock()
    defer { lock.unlock() }
    return latest != nil || frozen?.live != nil || lingering?.live != nil
  }

  /// A snapshot of this surface's counters.
  public var statistics: MonitorSurfaceStatistics {
    lock.lock()
    defer { lock.unlock() }
    var value = published
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

  // MARK: Ingest (any thread)

  /// Makes `bundle` the newest frame. Producers call this for every frame; it
  /// only swaps a slot under a short lock. Out-of-order frames are ignored.
  /// A frozen surface shows its hold, so it does not keep the frame (or its
  /// capture buffer). While hidden the display link is paused and replaced
  /// frames are not counted as superseded.
  public func accept(
    _ bundle: MonitorFrameBundle, configuration: MonitorConfiguration,
    ifCurrent: () -> Bool = { true }
  ) {
    var released: Live?
    var releasedHold: MonitorGPUFrame?
    var copyToken: UInt64?
    lock.lock()
    let stamp = bundle.stamp
    guard frozen == nil, ifCurrent(), acceptsInOrder(stamp) else {
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
    if pendingFreeze {
      // The held frame lives in `frozen` alone; the render thread replaces it
      // with a GPU copy at once, so a freeze pins no producer buffer.
      pendingFreeze = false
      nextFreezeToken &+= 1
      frozen = Frozen(
        token: nextFreezeToken, configuration: configuration, live: bundle, owned: nil,
        stamp: stamp, fromPendingRequest: true)
      copyToken = nextFreezeToken
      latest = nil
      stateVersion &+= 1
      transition = true
    } else {
      latest = Live(bundle: bundle, configuration: configuration)
      releasedHold = lingering?.owned
      lingering = nil
    }
    let schedule = transition && !refreshScheduled
    if schedule { refreshScheduled = true }
    lock.unlock()
    withExtendedLifetime(released) {}
    if let copyToken { scheduleFreezeCopy(token: copyToken) }
    if let releasedHold {
      // Off the producer's thread: this ends GPU residency of the old hold.
      let runtime = runtime
      runtime.renderThread.perform { runtime.release(releasedHold) }
    }
    if schedule {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.refresh(force: true) }
      }
    }
  }

  /// Called with the lock held; ordering survives display clearing.
  private func acceptsInOrder(_ stamp: MonitorFrameStamp) -> Bool {
    guard let previous = lastAcceptedStamp else { return true }
    guard stamp.target == previous.target, stamp.generation >= previous.generation else {
      return false
    }
    guard stamp.generation == previous.generation else { return true }
    guard stamp.configurationRevision >= previous.configurationRevision,
      stamp.processingRevision >= previous.processingRevision
    else { return false }
    let sameIdentity =
      stamp.configurationRevision == previous.configurationRevision
      && stamp.processingRevision == previous.processingRevision
    return !sameIdentity || stamp.sequence >= previous.sequence
  }

  // MARK: Render side (the render thread)

  struct RenderWork {
    enum Content {
      case none
      case live(MonitorFrameBundle)
      case frozenLive(MonitorFrameBundle, token: UInt64)
      case frozenOwned(MonitorGPUFrame, token: UInt64)
    }
    let content: Content
    let configuration: MonitorConfiguration
    let clean: Bool
    let latestVersion: UInt64
    let stateVersion: UInt64
    let isNewFrame: Bool
    var frozenToken: UInt64? {
      switch content {
      case .frozenLive(_, let token), .frozenOwned(_, let token): token
      default: nil
      }
    }
  }

  /// What to draw, or nil when nothing changed since `versions`.
  func renderWork(after versions: (UInt64, UInt64), force: Bool) -> RenderWork? {
    lock.lock()
    defer { lock.unlock() }
    guard force || versions.0 != latestVersion || versions.1 != stateVersion else { return nil }
    let isNew = versions.0 != latestVersion
    takenVersion = latestVersion
    let content: RenderWork.Content
    let configuration: MonitorConfiguration
    if let frozen {
      configuration = frozen.configuration
      if let owned = frozen.owned {
        content = .frozenOwned(owned, token: frozen.token)
      } else if let live = frozen.live {
        content = .frozenLive(live, token: frozen.token)
      } else {
        content = .none
      }
    } else if let latest {
      configuration = latest.configuration
      content = .live(latest.bundle)
    } else if let lingering {
      configuration = lingering.configuration
      if let owned = lingering.owned {
        content = .frozenOwned(owned, token: lingering.token)
      } else if let live = lingering.live {
        content = .live(live)
      } else {
        content = .none
      }
    } else {
      configuration = MonitorConfiguration()
      content = .none
    }
    return RenderWork(
      content: content, configuration: configuration, clean: clean,
      latestVersion: latestVersion, stateVersion: stateVersion, isNewFrame: isNew)
  }

  /// Copies the held producer frame on the GPU, on the render thread, as soon
  /// as a freeze begins (visible or not), so the capture buffer goes back to
  /// its pool. The copy is adopted only once encoded and committed; on failure
  /// the hold keeps the producer frame and the failure is counted.
  private func scheduleFreezeCopy(token: UInt64) {
    runtime.renderThread.perform { [weak self] in self?.makeFreezeCopy(token: token) }
  }

  /// Render thread.
  func makeFreezeCopy(token: UInt64) {
    lock.lock()
    guard let value = frozen, value.token == token, value.owned == nil, let live = value.live else {
      lock.unlock()
      return
    }
    lock.unlock()
    let context: MonitorEncodeContext
    do { context = try runtime.beginEncoding() } catch {
      recordFailure(error)
      return
    }
    let owned: MonitorGPUFrame
    do {
      let frame = try runtime.gpuFrame(live)
      owned = try freezeCopier.encodeFreezeCopy(of: frame, into: context)
    } catch {
      runtime.abandon(context)
      recordFailure(error)
      return
    }
    runtime.commit(
      context, completion: MonitorFreezeCopyCompletion(presenter: self),
      kind: MonitorSurfaceRenderLoop.freezeKind)
    if !adoptOwnedFreeze(owned, token: token) {
      // The freeze ended meanwhile; residency ends after the copy completes.
      runtime.release(owned)
    }
  }

  /// Replaces the held producer frame with its owned GPU copy. Returns false
  /// (and the caller releases the copy) if the freeze ended meanwhile.
  func adoptOwnedFreeze(_ frame: MonitorGPUFrame, token: UInt64) -> Bool {
    var released: MonitorFrameBundle?
    lock.lock()
    guard var value = frozen, value.token == token, value.owned == nil else {
      lock.unlock()
      return false
    }
    released = value.live
    value.live = nil
    value.owned = frame
    frozen = value
    lock.unlock()
    withExtendedLifetime(released) {}
    return true
  }

  var currentScopeLayer: CAMetalLayer? {
    lock.lock()
    defer { lock.unlock() }
    return scopeLayer
  }

  func recordPresented(_ stamp: MonitorFrameStamp?, status: [String]) {
    lock.lock()
    if let stamp, stamp != counters.lastPresented {
      counters.presentedFrames += 1
      counters.lastPresented = stamp
    }
    rendererStatus = status
    lock.unlock()
  }

  func recordScope(_ stamp: MonitorFrameStamp) {
    lock.lock()
    counters.scopeUpdates += 1
    counters.lastScope = stamp
    lock.unlock()
  }

  func recordScopeSkip(busy: Bool) {
    lock.lock()
    if busy { counters.scopeSkippedBusy += 1 } else { counters.scopeSkippedNoDrawable += 1 }
    lock.unlock()
  }

  func recordGPU(kind: Int, milliseconds: Double, failed: Bool) {
    lock.lock()
    if kind == MonitorSurfaceRenderLoop.scopeKind { scopesInFlight = max(0, scopesInFlight - 1) }
    if failed {
      counters.failures += 1
      counters.lastFailure = "GPU work failed"
      lastFailureTime = ProcessInfo.processInfo.systemUptime
    } else if kind == MonitorSurfaceRenderLoop.pictureKind {
      gpu.picture += milliseconds
      gpu.pictures += 1
    } else if kind == MonitorSurfaceRenderLoop.scopeKind {
      gpu.scope += milliseconds
      gpu.scopes += 1
    }
    lock.unlock()
  }

  func recordFailure(_ error: Error) {
    lock.lock()
    counters.failures += 1
    counters.lastFailure = "\(error)"
    lastFailureTime = ProcessInfo.processInfo.systemUptime
    lock.unlock()
  }

  /// Claims a scope slot if fewer than `limit` scope commits are on the GPU.
  func beginScope(limit: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard scopesInFlight < limit else { return false }
    scopesInFlight += 1
    return true
  }
  func cancelScope() {
    lock.lock()
    scopesInFlight = max(0, scopesInFlight - 1)
    lock.unlock()
  }

  // MARK: Controls (main actor)

  @MainActor func reportVisibility(presented: Bool, drawable: Bool) {
    let first = !visibilityReported
    guard first || visibility.presented != presented || visibility.drawable != drawable
    else { return }
    visibilityReported = true
    visibility = (presented, drawable)
    // A first "not presented" report arrives before the view reaches its window.
    // Passing it on drops monitor demand, which stops and restarts automatic capture.
    let beforeWindow = first && !presented && !drawable
    // The owner stops offering frames first (synchronously), so nothing new
    // lands in the slot after it is dropped.
    if !beforeWindow { onVisibilityChange?(presented, drawable) }
    setHidden(!drawable && !beforeWindow)
    refresh(force: true)
  }

  /// A surface that cannot be seen keeps no producer frame: its slot and any
  /// uncopied lingering hold are dropped. A freeze keeps its GPU copy.
  private func setHidden(_ value: Bool) {
    var released: Live?
    var releasedLingering: MonitorFrameBundle?
    lock.lock()
    let changed = hidden != value
    hidden = value
    if changed && value {
      released = latest
      if latest != nil { resuming = true }
      latest = nil
      if let held = lingering, held.owned == nil {
        releasedLingering = held.live
        lingering = nil
        resuming = true
      }
      latestVersion &+= 1
      stateVersion &+= 1
    }
    lock.unlock()
    withExtendedLifetime((released, releasedLingering)) {}
  }

  @MainActor public func setUnavailable(_ reason: String) {
    var released: Live?
    lock.lock()
    released = latest
    latest = nil
    latestVersion &+= 1
    unavailableReason = reason
    signalLost = true
    resuming = false
    pendingFreeze = false
    stateVersion &+= 1
    lock.unlock()
    withExtendedLifetime(released) {}
    if let hold = dropLingering() { runtime.release(hold) }
    refresh(force: true)
  }

  @MainActor public func requestFreezeOnNextFrame() {
    let retired = endFreeze()
    lock.lock()
    pendingFreeze = true
    stateVersion &+= 1
    lock.unlock()
    if let retired { runtime.release(retired) }
    refresh(force: true)
  }

  /// Cancel wins even if a frame already satisfied the request but the UI
  /// still shows it as pending.
  @MainActor public func cancelPendingFreeze() {
    let wasPending = isFreezePending
    var retired: MonitorGPUFrame?
    lock.lock()
    pendingFreeze = false
    stateVersion &+= 1
    let fromRequest = frozen?.fromPendingRequest == true
    lock.unlock()
    if wasPending && fromRequest { retired = endFreeze() }
    if let retired { runtime.release(retired) }
    refresh(force: true)
  }

  @MainActor public func toggleFreeze() {
    var retired: MonitorGPUFrame?
    var message: String?
    var copyToken: UInt64?
    lock.lock()
    if frozen != nil {
      lock.unlock()
      retired = endFreeze()
    } else if let held = latest {
      nextFreezeToken &+= 1
      frozen = Frozen(
        token: nextFreezeToken, configuration: held.configuration, live: held.bundle,
        owned: nil, stamp: held.bundle.stamp)
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
    if let retired { runtime.release(retired) }
    refresh(force: true)
    if let message { detail = message }
  }

  /// Ends any freeze; returns owned GPU copies for the caller to release.
  private func endFreeze() -> MonitorGPUFrame? {
    lock.lock()
    guard let held = frozen else {
      lock.unlock()
      return nil
    }
    stateVersion &+= 1
    frozen = nil
    var retired: MonitorGPUFrame?
    // A hidden surface never keeps an uncopied producer frame.
    if latest == nil && !signalLost && !(hidden && held.owned == nil) {
      // Keep drawing the hold until live frames resume.
      retired = lingering?.owned
      lingering = held
    } else {
      retired = held.owned
    }
    lock.unlock()
    return retired
  }

  /// Drops a lingering hold; returns its owned copy for the caller to release.
  private func dropLingering() -> MonitorGPUFrame? {
    lock.lock()
    let owned = lingering?.owned
    if lingering != nil { stateVersion &+= 1 }
    lingering = nil
    lock.unlock()
    return owned
  }

  @MainActor public func setClean(_ enabled: Bool) {
    lock.lock()
    if clean != enabled { stateVersion &+= 1 }
    clean = enabled
    lock.unlock()
    isClean = enabled
    refresh(force: true)
  }
  @MainActor public func toggleClean() { setClean(!isClean) }

  // MARK: Views

  @MainActor public func makeView() -> NSView {
    let view = MonitorPictureNSView(presenter: self)
    view.visibilityChanged = { [weak self, weak view] presented, drawable in
      guard let self, self.visibilityView === view else { return }
      self.reportVisibility(presented: presented, drawable: drawable)
    }
    visibilityView = view
    refresh(force: true)
    return view
  }

  @MainActor public func makeVisibilityView() -> NSView {
    let view = MonitorVisibilityNSView()
    view.visibilityChanged = { [weak self, weak view] presented, drawable in
      guard let self, self.visibilityView === view else { return }
      self.reportVisibility(presented: presented, drawable: drawable)
    }
    visibilityView = view
    return view
  }

  @MainActor public func makeScopeView() -> NSView {
    let view = MonitorScopeNSView(runtime: runtime)
    view.removedFromPresenter = { [weak self] layer in self?.scopeViewRemoved(layer) }
    // The render thread draws scopes only while the view is in a window, so it
    // never waits on drawables nobody will display.
    view.windowChanged = { [weak self, weak view] inWindow in
      guard let self, let view else { return }
      self.lock.lock()
      if inWindow {
        self.scopeLayer = view.metalLayer
        self.stateVersion &+= 1
      } else if self.scopeLayer === view.metalLayer {
        self.scopeLayer = nil
      }
      self.lock.unlock()
    }
    refresh(force: true)
    return view
  }

  @MainActor func scopeViewRemoved(_ layer: CAMetalLayer) {
    lock.lock()
    if scopeLayer === layer { scopeLayer = nil }
    lock.unlock()
  }

  // MARK: Published state (main actor, about twice a second)

  private static func describe(_ signal: MonitorFrameSignal?) -> String {
    guard let signal else { return "Range / transfer interpretation unavailable" }
    let range = signal.range == .full ? "Full range" : "Legal range"
    return
      "\(range) · \(signal.transfer.isEmpty ? "unknown transfer" : signal.transfer) · \(signal.matrix.rawValue) matrix"
  }

  private static func signal(
    _ bundle: MonitorFrameBundle, stage: MonitorStage, configuration: MonitorConfiguration
  ) -> MonitorFrameSignal? {
    if stage == .processedOutput, let output = bundle.output, output !== bundle.source {
      return bundle.outputSignal
    }
    return bundle.sourceSignal.map { $0.withRange(configuration.sourceCodeRange ?? $0.range) }
  }

  private static func displayAspect(
    _ bundle: MonitorFrameBundle, stage: MonitorStage
  ) -> Double? {
    let geometry: MonitorGeometry
    if stage == .processedOutput, let output = bundle.output, output !== bundle.source {
      geometry =
        bundle.outputGeometry
        ?? MonitorGeometry(
          width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
    } else {
      geometry = bundle.sourceGeometry
    }
    guard geometry.isValid else { return nil }
    let aspect = geometry.cleanAperture.width * geometry.pixelAspectRatio
      / geometry.cleanAperture.height
    return aspect.isFinite && aspect > 0 ? aspect : nil
  }

  @MainActor private func refresh(force: Bool) {
    lock.lock()
    refreshScheduled = false
    let live = latest
    let frozenValue = frozen
    let held = lingering
    let pending = pendingFreeze
    let unavailable = resuming ? "Resuming" : unavailableReason
    let statuses = rendererStatus
    let now = ProcessInfo.processInfo.systemUptime
    // Rates over the last window.
    if window.start == 0 { window.start = now }
    if now - window.start >= 1 {
      let elapsed = now - window.start
      published.acceptedFPS = Double(counters.acceptedFrames - window.accepted) / elapsed
      published.presentedFPS = Double(counters.presentedFrames - window.presented) / elapsed
      published.scopeFPS = Double(counters.scopeUpdates - window.scopes) / elapsed
      published.pictureGPUMilliseconds = gpu.pictures > 0 ? gpu.picture / Double(gpu.pictures) : nil
      published.scopeGPUMilliseconds = gpu.scopes > 0 ? gpu.scope / Double(gpu.scopes) : nil
      gpu = (0, 0, 0, 0)
      window = (now, counters.acceptedFrames, counters.presentedFrames, counters.scopeUpdates)
    }
    let lastScope = counters.lastScope
    let failure = now - lastFailureTime < 1 ? counters.lastFailure : nil
    lock.unlock()
    let frozenNow = frozenValue != nil
    if isFrozen != frozenNow { isFrozen = frozenNow }
    if isFreezePending != pending { isFreezePending = pending }
    let occluded = !frozenNow && visibilityReported && !visibility.drawable
    if pending {
      status = "Waiting to freeze next picture"
      detail = status
      return
    }
    let shownConfiguration = frozenValue?.configuration ?? live?.configuration ?? held?.configuration
    let bundle = frozenValue?.live ?? live?.bundle ?? held?.live
    let stamp = frozenValue?.stamp ?? live?.bundle.stamp ?? held?.stamp
    guard let stamp, let shownConfiguration else {
      scopeTiming = "No scope signal"
      status = occluded ? (visibility.presented ? "Occluded" : "Paused / hidden") : unavailable
      detail = status
      return
    }
    if configuration != shownConfiguration { configuration = shownConfiguration }
    if occluded {
      status = visibility.presented ? "Occluded" : "Paused / hidden"
      detail = status
      return
    }
    guard force || now - lastStatusUpdate >= 0.5 else { return }
    lastStatusUpdate = now
    // A picture that fails to draw is reported on the tile, never shown as Live.
    if let reason = runtime.unavailableReason ?? failure, !frozenNow {
      status = "Monitor error"
      detail = reason
      return
    }
    if let bundle {
      pictureInterpretation = Self.describe(
        Self.signal(bundle, stage: shownConfiguration.pictureStage, configuration: shownConfiguration))
      scopeInterpretation = Self.describe(
        Self.signal(bundle, stage: shownConfiguration.scopeStage, configuration: shownConfiguration))
      if let aspect = Self.displayAspect(bundle, stage: shownConfiguration.pictureStage),
        abs(aspect - pictureAspectRatio) > 0.0001
      {
        pictureAspectRatio = aspect
      }
    } else if let owned = frozenValue?.owned ?? held?.owned {
      // A hold already copied on the GPU keeps the frame's signal and geometry.
      pictureInterpretation = Self.describe(
        owned.signal(for: shownConfiguration.pictureStage, configuration: shownConfiguration))
      scopeInterpretation = Self.describe(
        owned.signal(for: shownConfiguration.scopeStage, configuration: shownConfiguration))
      let geometry = owned.geometry(for: shownConfiguration.pictureStage)
      let aspect =
        geometry.cleanAperture.width * geometry.pixelAspectRatio / geometry.cleanAperture.height
      if geometry.isValid, aspect.isFinite, aspect > 0, abs(aspect - pictureAspectRatio) > 0.0001 {
        pictureAspectRatio = aspect
      }
    }
    let age = max(0, now - stamp.hostTime)
    status = frozenNow ? "Frozen" : age > 0.25 ? "Stale" : "Live"
    var text =
      "Picture PTS \(String(format: "%.3f", stamp.sourcePTS)) · \(String(format: "%.1f", age)) s old"
    if shownConfiguration.toolsEnabled && shownConfiguration.scopes.enabled, let lastScope {
      let scopeAge = max(0, now - lastScope.hostTime)
      let scopeState =
        frozenNow
        ? "Frozen"
        : scopeAge > max(0.25, 3.0 / Double(max(1, shownConfiguration.scopes.refreshHz)))
          ? "Stale" : "Live"
      scopeTiming =
        "\(scopeState) · Scope PTS \(String(format: "%.3f", lastScope.sourcePTS)) · \(String(format: "%.1f", scopeAge)) s old"
      text += " · Scope PTS \(String(format: "%.3f", lastScope.sourcePTS))"
    } else {
      scopeTiming = "No scope signal"
    }
    if let reason = runtime.unavailableReason { text += " · " + reason }
    if !statuses.isEmpty { text += " · " + statuses.joined(separator: " · ") }
    detail = text
  }
}

private final class MonitorWindowObservations: @unchecked Sendable {
  var tokens: [NSObjectProtocol] = []
  func clear() {
    tokens.forEach { NotificationCenter.default.removeObserver($0) }
    tokens = []
  }
  deinit { clear() }
}

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
  /// Test hook: a test runner that is not the active app gets no occlusion
  /// updates for its windows although Core Animation still draws them, so
  /// tests that need the display link treat every presented view as drawable.
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

/// The live picture: a CAMetalLayer drawn by a display link on the monitor
/// render thread. Each refresh with a new frame (or a changed tool, size or
/// freeze state) encodes one picture pass straight into the drawable. The
/// layer's format and colorspace follow the shown frame's signal.
@MainActor final class MonitorPictureNSView: MonitorVisibilityNSView {
  let metalLayer = CAMetalLayer()
  private let loop: MonitorSurfaceRenderLoop
  private weak var presenter: MonitorSurfacePresenter?
  private var aspectObservation: AnyCancellable?
  var renderLoop: MonitorSurfaceRenderLoop { loop }

  init(presenter: MonitorSurfacePresenter) {
    self.presenter = presenter
    loop = MonitorSurfaceRenderLoop(presenter: presenter, layer: metalLayer)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    MonitorPictureColor.rec709.apply(to: metalLayer)
    metalLayer.framebufferOnly = false
    metalLayer.maximumDrawableCount = 3
    metalLayer.device = presenter.runtime.layerDevice
    metalLayer.isOpaque = true
    metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    layer?.addSublayer(metalLayer)
    aspectObservation = presenter.$pictureAspectRatio.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.needsLayout = true }
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    let aspect = presenter?.pictureAspectRatio ?? 16.0 / 9.0
    let fit = MonitorGeometry(
      width: 1000, height: max(1, Int((1000 / aspect).rounded())))
      .aspectFit(
        in: MonitorRect(width: Double(bounds.width), height: Double(bounds.height)))
    let frame = fit.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .zero
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

  /// Moving between a 1x and a 2x display changes the backing scale: resize
  /// the drawables to match. (The display link follows the layer's display
  /// and its refresh rate by itself.)
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      // Starts paused unless the window can be seen now (a hidden window
      // never runs the link until it is shown).
      loop.start(paused: !isDrawable)
    } else {
      loop.stop()
    }
  }

  override func drawableChanged(_ drawable: Bool) { loop.setPaused(!drawable) }

  func tearDown() { loop.stop() }
}

/// Scope picture. Its own display link on the render thread draws it at the
/// user's scope rate, so the picture never waits for a scope drawable.
@MainActor final class MonitorScopeNSView: NSView {
  let metalLayer = CAMetalLayer()
  var removedFromPresenter: ((CAMetalLayer) -> Void)?
  var windowChanged: ((Bool) -> Void)?
  private let runtime: MonitorRuntime
  /// The layer's drawable residency set; nil until the layer has a device.
  nonisolated(unsafe) private let drawableSet: MTLResidencySet?
  init(runtime: MonitorRuntime) {
    let device = runtime.layerDevice
    metalLayer.device = device
    // CAMetalLayer.residencySet is nil until a device is set, though Swift
    // imports it as non-optional. Read it only once the device is assigned.
    drawableSet = device == nil ? nil : metalLayer.residencySet
    self.runtime = runtime
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    metalLayer.pixelFormat = .bgra8Unorm
    // Scope traces are display graphics: color-managed as sRGB.
    metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metalLayer.framebufferOnly = false
    metalLayer.maximumDrawableCount = 3
    metalLayer.drawableSize = CGSize(
      width: MonitorToolsRenderer.scopeWidth, height: MonitorToolsRenderer.scopeHeight)
    metalLayer.contentsGravity = .resize
    metalLayer.isOpaque = false
    metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    layer?.addSublayer(metalLayer)
    if let drawableSet { runtime.attachDrawables(drawableSet) }
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
    let runtime = runtime
    guard let drawableSet else { return }
    nonisolated(unsafe) let set = drawableSet
    runtime.renderThread.perform { runtime.detachDrawables(set) }
  }
}

/// Completion of a freeze copy: a failed copy is a counted surface failure.
private final class MonitorFreezeCopyCompletion: MonitorEncodeCompletion, @unchecked Sendable {
  weak var presenter: MonitorSurfacePresenter?
  init(presenter: MonitorSurfacePresenter) { self.presenter = presenter }
  func encodeCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    presenter?.recordGPU(kind: kind, milliseconds: (gpuEnd - gpuStart) * 1000, failed: failed)
  }
}

/// Render-thread side of one picture surface and its scope. Confined to the
/// render thread except `start`, `stop` and `setPaused`, which hop onto it.
final class MonitorSurfaceRenderLoop: NSObject, CAMetalDisplayLinkDelegate,
  MonitorEncodeCompletion, @unchecked Sendable
{
  static let pictureKind = 1
  static let scopeKind = 2
  static let freezeKind = 3
  private weak var presenter: MonitorSurfacePresenter?
  private let runtime: MonitorRuntime
  private let layer: CAMetalLayer
  private let renderer: MonitorToolsRenderer
  private var link: CAMetalDisplayLink?
  /// Draws the scope layer; created while a scope view is in a window.
  private var scopeLink: CAMetalDisplayLink?
  private var scopeLinkLayer: CAMetalLayer?
  private var scopeLinkHz = 0
  private var paused = false
  private var versions: (UInt64, UInt64) = (UInt64.max, UInt64.max)
  private var drawnSize = CGSize.zero
  private var nextScopeTime = 0.0
  private var attached = false
  private var drawableSet: MTLResidencySet?
  /// The layer's current presentation and the signal it was chosen for.
  private(set) var appliedColor = MonitorPictureColor.rec709
  private var colorSignal: MonitorFrameSignal??
  /// The last drawn frame, held only until its scope has been drawn.
  private var scopePendingFrame: MonitorGPUFrame?
  private var scopePendingKey: ScopeKey?
  /// When the pending live frame was wrapped. Its cached textures leave
  /// residency once idle (1 s after a flush), so it must be drawn well before.
  private var scopePendingAt = 0.0
  private static let pendingScopeLifetime = 0.5
  private var scopedKey: ScopeKey?
  /// When the pending scope became due, and when the next skip may be counted.
  private var scopeDueAt = 0.0
  private var nextSkipCount = 0.0

  init(presenter: MonitorSurfacePresenter, layer: CAMetalLayer) {
    self.presenter = presenter
    runtime = presenter.runtime
    self.layer = layer
    renderer = MonitorToolsRenderer(runtime: presenter.runtime)
  }

  func start(paused: Bool) {
    runtime.renderThread.perform { [self] in
      self.paused = paused
      guard link == nil else {
        link?.isPaused = paused
        return
      }
      // No device means no Metal: leave the picture black rather than crash.
      guard layer.device != nil else { return }
      if !attached {
        drawableSet = layer.residencySet
        runtime.attachDrawables(layer.residencySet)
        attached = true
      }
      let link = CAMetalDisplayLink(metalLayer: layer)
      link.delegate = self
      link.preferredFrameLatency = 2
      link.isPaused = paused
      link.add(to: .current, forMode: .default)
      self.link = link
      versions = (UInt64.max, UInt64.max)
    }
  }

  func stop() {
    runtime.renderThread.perform { [self] in
      link?.invalidate()
      link = nil
      setScopeLayer(nil)
      dropPendingScope()
    }
  }

  func setPaused(_ paused: Bool) {
    runtime.renderThread.perform { [self] in
      self.paused = paused
      link?.isPaused = paused
      scopeLink?.isPaused = paused
      if paused {
        // A surface nobody can see holds no frame for a scope.
        dropPendingScope()
      } else {
        // Redraw on resume: the layer may have been cleared while hidden.
        versions = (UInt64.max, UInt64.max)
      }
    }
  }

  deinit {
    let link = link
    let scopeLink = scopeLink
    let runtime = runtime
    let set = drawableSet
    let renderer = renderer
    runtime.renderThread.perform {
      link?.invalidate()
      scopeLink?.invalidate()
      if let set { runtime.detachDrawables(set) }
      renderer.invalidate()
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
    let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
    guard let work = presenter.renderWork(after: versions, force: size != drawnSize) else { return }
    versions = (work.latestVersion, work.stateVersion)
    drawnSize = size
    let state = MonitorRenderState(configuration: work.configuration, clean: work.clean)
    var shownFrame: MonitorGPUFrame?
    let context: MonitorEncodeContext
    do { context = try runtime.beginEncoding() } catch {
      presenter.recordFailure(error)
      versions = (UInt64.max, UInt64.max)
      return
    }
    do {
      switch work.content {
      case .none:
        try renderer.encodeClear(target: drawable.texture, into: context)
      case .live(let bundle), .frozenLive(let bundle, _):
        // A hold not yet copied still reads its producer frame; the copy is
        // made (once) by the presenter on this thread, never here.
        shownFrame = try runtime.gpuFrame(bundle)
      case .frozenOwned(let frame, _):
        shownFrame = frame
      }
      if let shownFrame {
        applyColor(
          shownFrame.signal(
            for: state.configuration.pictureStage, configuration: state.configuration))
        try renderer.encode(
          frame: shownFrame, state: state, target: drawable.texture,
          viewport: MonitorViewport(width: drawable.texture.width, height: drawable.texture.height),
          into: context)
      }
    } catch {
      runtime.abandon(context)
      presenter.recordFailure(error)
      versions = (UInt64.max, UInt64.max)
      return
    }
    runtime.commit(context, drawable: drawable, completion: self, kind: Self.pictureKind)
    presenter.recordPresented(shownFrame?.stamp, status: renderer.status)
    if let shownFrame, renderer.wantsScopes(state), let scopeLinkLayer {
      let key = ScopeKey(
        stamp: shownFrame.stamp, frozenToken: work.frozenToken,
        layer: ObjectIdentifier(scopeLinkLayer), state: state)
      if key != scopedKey {
        let now = update.targetTimestamp
        if scopePendingFrame == nil {
          scopeDueAt = isImmediate(key) ? now : max(now, nextScopeTime)
        }
        scopePendingFrame = shownFrame
        scopePendingKey = key
        scopePendingAt = now
        setScopeRate(key.state.configuration.scopes.refreshHz)
      }
    }
  }

  /// Sets the layer's format, colorspace and EDR state for `signal` when the
  /// presentation it needs changes. Render thread (tests call it directly).
  func applyColor(_ signal: MonitorFrameSignal?) {
    if let colorSignal, colorSignal == signal { return }
    colorSignal = .some(signal)
    let color = MonitorPictureColor(signal: signal)
    guard color != appliedColor else { return }
    appliedColor = color
    color.apply(to: layer)
    // Keep the drawables resident if the layer made a new set for the new format.
    if attached, let set = drawableSet, layer.residencySet !== set {
      runtime.detachDrawables(set)
      drawableSet = layer.residencySet
      runtime.attachDrawables(layer.residencySet)
    }
  }

  private struct ScopeKey: Equatable {
    let stamp: MonitorFrameStamp
    let frozenToken: UInt64?
    let layer: ObjectIdentifier?
    let state: MonitorRenderState
  }

  /// A held picture, a new scope view or changed scope settings draw at once.
  private func isImmediate(_ key: ScopeKey) -> Bool {
    key.frozenToken != nil || scopedKey?.layer != key.layer || scopedKey?.state != key.state
  }

  private func dropPendingScope() {
    scopePendingFrame = nil
    scopePendingKey = nil
  }

  /// Follows the presenter's scope layer: one scope display link per layer.
  private func setScopeLayer(_ scopeLayer: CAMetalLayer?) {
    guard scopeLayer !== scopeLinkLayer else { return }
    scopeLink?.invalidate()
    scopeLink = nil
    scopeLinkLayer = scopeLayer
    scopeLinkHz = 0
    guard let scopeLayer, scopeLayer.device != nil else {
      dropPendingScope()
      return
    }
    let link = CAMetalDisplayLink(metalLayer: scopeLayer)
    link.delegate = self
    link.preferredFrameLatency = 2
    link.isPaused = paused
    link.add(to: .current, forMode: .default)
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
    1.0 / Double(max(1, min(60, key.state.configuration.scopes.refreshHz)))
  }

  /// A due scope the scope link has not drawn for a whole scope interval had
  /// no drawable: counted, at most once per interval. The frame stays pending.
  private func noteMissedScope(now: Double) {
    guard let key = scopePendingKey, let presenter else { return }
    let interval = scopeInterval(key)
    guard now - scopeDueAt > interval + 0.004, now >= nextSkipCount else { return }
    nextSkipCount = now + interval
    presenter.recordScopeSkip(busy: false)
  }

  /// Scopes get their own command buffer at the user's rate, drawn into the
  /// scope link's drawable, which never blocks. The newest drawn frame waits
  /// here until its scope is due, so the scope always catches up to the last
  /// picture (for example the final frame before a feed stops).
  private func drawScope(_ update: CAMetalDisplayLink.Update) {
    guard let frame = scopePendingFrame, let key = scopePendingKey, let presenter else { return }
    guard renderer.wantsScopes(key.state), let scopeLinkLayer,
      key.layer == ObjectIdentifier(scopeLinkLayer)
    else {
      dropPendingScope()
      return
    }
    let now = update.targetTimestamp
    // A live frame the scope link couldn't draw for this long is dropped,
    // counted, rather than encoded from textures that may be gone; it also
    // stops pinning the producer's buffer. Held (frozen) frames own theirs.
    if key.frozenToken == nil, now - scopePendingAt > Self.pendingScopeLifetime {
      dropPendingScope()
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
    dropPendingScope()
    scopedKey = key
    // Keep the user's cadence; after a gap, restart it from now.
    nextScopeTime = nextScopeTime + interval > now ? nextScopeTime + interval : now + interval
    let drawable = update.drawable
    let context: MonitorEncodeContext
    do { context = try runtime.beginEncoding() } catch {
      presenter.cancelScope()
      presenter.recordFailure(error)
      return
    }
    do {
      try renderer.encodeScopes(
        frame: frame, state: key.state, target: drawable.texture, into: context)
    } catch {
      runtime.abandon(context)
      presenter.cancelScope()
      presenter.recordFailure(error)
      return
    }
    runtime.commit(context, drawable: drawable, completion: self, kind: Self.scopeKind)
    presenter.recordScope(frame.stamp)
  }

  func encodeCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    presenter?.recordGPU(kind: kind, milliseconds: (gpuEnd - gpuStart) * 1000, failed: failed)
  }
}

public struct MonitorNativePicture: NSViewRepresentable {
  public let presenter: MonitorSurfacePresenter
  public init(presenter: MonitorSurfacePresenter) { self.presenter = presenter }
  public func makeNSView(context: Context) -> NSView { presenter.makeView() }
  public func updateNSView(_ nsView: NSView, context: Context) {}
  public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    (nsView as? MonitorPictureNSView)?.tearDown()
  }
}
public struct MonitorNativeScope: NSViewRepresentable {
  public let presenter: MonitorSurfacePresenter
  public init(presenter: MonitorSurfacePresenter) { self.presenter = presenter }
  public func makeNSView(context: Context) -> NSView { presenter.makeScopeView() }
  public func updateNSView(_ nsView: NSView, context: Context) {}
  public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    guard let view = nsView as? MonitorScopeNSView else { return }
    view.removedFromPresenter?(view.metalLayer)
  }
}

/// Tracks visibility for a surface without a picture of its own.
public struct MonitorSurfaceVisibility: NSViewRepresentable {
  public let presenter: MonitorSurfacePresenter
  public init(presenter: MonitorSurfacePresenter) { self.presenter = presenter }
  public func makeNSView(context: Context) -> NSView { presenter.makeVisibilityView() }
  public func updateNSView(_ nsView: NSView, context: Context) {}
}
