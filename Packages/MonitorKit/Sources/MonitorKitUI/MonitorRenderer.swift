import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import Synchronization

/// Draws a `MonitorScene` into any target texture: the engine room of
/// `MonitorMetalView`, usable without it (a host's own layer, an offscreen
/// texture, a test). Classic command buffers and Metal 4 submissions both work;
/// keep to one of them per renderer.
///
/// Per display tick: `update()` once, then `needsDisplay(…)`, then `encode(…)`.
/// A steady tick (no new frame, no edit) reads a few revision counters under
/// short locks and allocates nothing; an unchanged scene needs no encode at all.
///
/// One encode: the focus analyses, then the scope accumulations (one `ScopeGroup`
/// per source and monitor-LUT choice, so a waveform, vectorscope and histogram of
/// one stage decode each pixel once), then every surface's and scope's prepare,
/// then a single render pass that clears the target and draws the pictures in
/// order and the scopes over them. The pass waits for the accumulations (it
/// draws their traces), so a host that must not delay its pictures splits the
/// encode: `encodePictures(…)` into one command buffer, committed, then
/// `encodeScopes(into:)` into a second, committed after it. The pictures then
/// show their frame at once and the scopes the previous accumulation (one tick
/// behind); the next tick draws the new bins. `MonitorMetalView` does this on
/// its own queue.
///
/// Scope rate: each overlay's `accumulationInterval` (0: every new frame).
///
/// Each source gets one `MonitorFeed`, plus one more per further distinct focus
/// analysis its surfaces ask for (stage, level and noise rejection): surfaces
/// with the same analysis share it, and each surface draws with its own mask.
/// Each surface gets one `MonitorPass`; each scope overlay an accumulator and a
/// scope renderer.
///
/// Confined: use from one thread at a time (the view's display-link thread).
/// Frames, LUTs and settings arrive through the scene's thread-safe handles.
///
/// Lifetimes: a frame, LUT or feed replaced in a source stays referenced until the
/// encode that last used it has completed: `engine.framesInFlight` (at least 3)
/// encodes later on the classic path, or sooner when the host reports completion
/// (`noteCompleted(through:)`, which `MonitorMetalView` does for its own command
/// buffers); the submission's `completedIndex` on Metal 4. A classic host must
/// therefore keep no more encodes than that in flight (an encode being its
/// pictures' and its scopes' command buffers when split).
///
/// Focus masks no surface draws with (peaking off, clean, nothing drawn) are
/// freed with their feed once the GPU work that read them completed.
public final class MonitorRenderer {
  public let engine: MonitorEngine
  public let scene: MonitorScene
  /// Given to `init`, or the engine's shared one (`sharedScopeEngine(for:)`), built
  /// off the display thread when the first scope overlay arrives: until it is
  /// ready the pictures draw and the scopes wait.
  public private(set) var scopeEngine: ScopeEngine?
  /// Target pixels per UI point: guide strokes and zebra stripes scale with it.
  public var pixelsPerPoint = 1.0
  /// The EDR headroom of the display this renderer draws for, instead of the
  /// scene's: a view sets its own screen's here, so one scene can be shown on two
  /// screens. Nil uses `scene.headroom`.
  public var displayHeadroom: Double?
  /// What the target should be tagged with, resolved by `update()`.
  public private(set) var layerColor = MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886))
  /// The headroom in effect.
  public private(set) var headroom = 1.0
  /// Encodes so far.
  public private(set) var encodeCount: UInt64 = 0
  /// The last error: a scope engine or accumulator that failed to build, a
  /// surface or scope that could not encode (it is skipped; the rest still draw).
  public private(set) var lastError: (any Error)?
  /// Counts the errors recorded in `lastError`.
  public private(set) var errorCount: UInt64 = 0

  private var sceneRevision: UInt64 = .max
  private var output = MonitorOutputColor.signalNative
  private var sceneClean = false
  private var sources: [SourceState] = []
  private var surfaces: [SurfaceState] = []
  private var overlays: [OverlayState] = []
  private var groups: [GroupState] = []
  private var needsRegroup = false
  private var layerKey: LayerKey?
  private var generation: UInt64 = 0
  private var drawnKey: DrawKey?
  private var retired: [Retired] = []
  /// Encodes (classic) or submissions (Metal 4) known to have completed.
  private var completed: UInt64 = 0
  private var statusChanged = false
  private var graticuleChanged = false
  private let pass = MTLRenderPassDescriptor()
  private let pass4 = MTL4RenderPassDescriptor()
  private var usedMetal4 = false
  private let scopeBuild = ScopeEngineBuild()
  private var scopeBuildState = ScopeBuildState.idle

  enum ScopeBuildState { case idle, building, failed }

  public init(engine: MonitorEngine, scene: MonitorScene = MonitorScene(), scopeEngine: ScopeEngine? = nil) {
    self.engine = engine
    self.scene = scene
    self.scopeEngine = scopeEngine
    retired.reserveCapacity(32)
    let a = pass.colorAttachments[0]!
    a.loadAction = .clear
    a.storeAction = .store
    a.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    let a4 = pass4.colorAttachments[0]!
    a4.loadAction = .clear
    a4.storeAction = .store
    a4.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
  }

  deinit {
    // Metal 4 retains nothing: what an in-flight submission may read lives until it completes.
    guard usedMetal4 else { return }
    let r = engine.residency
    for s in sources { Self.retire(s.frame, s.feed.burnInLUT, s.feed.monitorLUT, to: r) }
    for x in retired { Self.retire(x.frame, x.burnIn, x.monitor, to: r) }
  }

  private static func retire(_ f: MonitorFrame?, _ a: MonitorLUT?, _ b: MonitorLUT?, to r: MonitorResidency) {
    if let f {
      r.retire(f.packed, resident: nil)
      r.retire(f.luma, resident: nil)
      r.retire(f.chroma, resident: nil)
    }
    r.retire(a, resident: nil)
    r.retire(b, resident: nil)
  }

  /// The scope engine every renderer of `engine` shares, built on first use on the
  /// calling thread (it compiles the scope library: call it up front, off the
  /// display thread, to have scopes on the first frame). Lives while a renderer
  /// or the caller holds it.
  public static func sharedScopeEngine(for engine: MonitorEngine) throws -> ScopeEngine {
    try ScopeEngineCache.engine(for: engine)
  }

  // MARK: - Per tick

  /// Reads the scene: membership, edits, new frames and LUTs, the headroom.
  /// Returns whether anything a draw shows changed. Allocates only when the
  /// scene's membership or a scope's grouping changes (new passes, feeds, scopes).
  /// Does not throw: what fails to build is skipped and recorded in `lastError`.
  @discardableResult
  public func update() throws -> Bool {
    var changed = false
    let revision = scene.revision()
    if revision != sceneRevision {
      // Recorded first: a membership that fails to build is not retried every tick.
      sceneRevision = revision
      if scopeBuildState == .failed { scopeBuildState = .idle }
      changed = true
      reconcile(scene.snapshot())
    }
    if scopeBuildState == .building, let result = scopeBuild.take() {
      switch result {
      case .success(let scopes):
        scopeEngine = scopes
        scopeBuildState = .idle
        reconcile(scene.snapshot())
        changed = true
      case .failure(let error):
        scopeBuildState = .failed
        record(error)
      }
    }
    let h = displayHeadroom.map(MonitorDisplayHeadroom.sanitized) ?? scene.headroomValue()
    if h != headroom {
      headroom = h
      // Only an EDR layer's pictures depend on it (the HDR passthrough roll-off).
      if layerColor.wantsExtendedDynamicRange { changed = true }
    }
    var i = 0
    while i < sources.count {
      if refresh(sources[i]) { changed = true }
      i += 1
    }
    i = 0
    while i < surfaces.count {
      let s = surfaces[i]
      if let next = s.surface.read(after: s.revision) {
        s.state = next.state
        s.drawState = cleaned(next.state)
        s.region = next.region
        s.revision = next.revision
        changed = true
      }
      i += 1
    }
    i = 0
    while i < overlays.count {
      if updateOverlay(overlays[i]) { changed = true }
      i += 1
    }
    if needsRegroup { regroup() }
    // A frame held back by a scope's rate is accumulated once its interval passed.
    var now: UInt64 = 0
    i = 0
    while i < groups.count {
      let due = groups[i].dueAt
      i += 1
      guard due != 0 else { continue }
      if now == 0 { now = Self.now() }
      if now >= due { changed = true }
    }
    resolveLayer()
    if changed { generation &+= 1 }
    return changed
  }

  /// Whether a draw into a target of this size and format would differ from the
  /// last one: an unchanged scene can keep the picture already on screen.
  public func needsDisplay(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> Bool {
    drawnKey != DrawKey(
      width: width, height: height, pixelFormat: pixelFormat, pixelsPerPoint: pixelsPerPoint, generation: generation)
  }

  /// Forgets the last draw, so `needsDisplay` is true until the next encode.
  public func setNeedsDisplay() { drawnKey = nil }

  /// Draws the scene into `target` on a classic command buffer: focus analyses,
  /// scope accumulations, then one render pass that clears the target and draws
  /// the surfaces in order and the scopes. Encodes only; the caller commits.
  /// Throws only when no render pass could be made; a surface or scope that fails
  /// is skipped and recorded in `lastError`.
  public func encode(target: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
    try encodeClassic(target: target, commandBuffer, scopes: true)
  }

  /// `encode(target:into:)` without the scope accumulations: the scopes are drawn
  /// from the bins already accumulated, so nothing in this command buffer waits
  /// for them. Follow it with `encodeScopes(into:)` in a command buffer committed
  /// after this one, on the same queue, and report completion
  /// (`noteCompleted(through:)`) only once that one completed too: it reads the
  /// frames of this encode.
  public func encodePictures(target: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
    try encodeClassic(target: target, commandBuffer, scopes: false)
  }

  /// The scope accumulations of the last `encodePictures(…)`, for the scopes
  /// the next draw shows. Returns whether it encoded any (`scopesDue` says so
  /// beforehand, to skip making a command buffer). Errors are recorded in `lastError`.
  @discardableResult
  public func encodeScopes(into commandBuffer: MTLCommandBuffer) -> Bool {
    scopesEncoded(accumulate(path: .classic(commandBuffer), use: encodeCount))
  }

  /// `encode(target:into:)` into a host's Metal 4 submission. The host makes the
  /// frames and `target` resident (`MonitorFrame.addResidency(to:)`) and attaches
  /// `engine.residency.set` to its queue.
  public func encode(target: MTLTexture, into submission: MonitorSubmission) throws {
    try encodeMetal4(target: target, submission, scopes: true)
  }

  /// `encodePictures(target:into:)` on Metal 4: follow it with
  /// `encodeScopes(into:)` in a later submission.
  public func encodePictures(target: MTLTexture, into submission: MonitorSubmission) throws {
    try encodeMetal4(target: target, submission, scopes: false)
  }

  /// `encodeScopes(into:)` on Metal 4, in a submission after the pictures'.
  @discardableResult
  public func encodeScopes(into submission: MonitorSubmission) -> Bool {
    usedMetal4 = true
    if submission.completedIndex > completed { completed = submission.completedIndex }
    defer { release(through: completed) }
    return scopesEncoded(accumulate(path: .metal4(submission), use: submission.index))
  }

  /// Whether `encodeScopes` would encode an accumulation now. Reading it also
  /// records when a frame held back by a scope's rate is due.
  public var scopesDue: Bool {
    var now: UInt64 = 0
    var i = 0
    while i < groups.count {
      if groupDue(groups[i], now: &now) { return true }
      i += 1
    }
    return false
  }

  private func encodeClassic(target: MTLTexture, _ commandBuffer: MTLCommandBuffer, scopes: Bool) throws {
    encodeCount &+= 1
    let use = encodeCount
    let window = UInt64(max(3, engine.framesInFlight))
    defer { release(through: max(completed, use > window ? use - window : 0)) }
    try encode(target: target, path: .classic(commandBuffer), use: use, scopes: scopes)
  }

  private func encodeMetal4(target: MTLTexture, _ submission: MonitorSubmission, scopes: Bool) throws {
    encodeCount &+= 1
    usedMetal4 = true
    if submission.completedIndex > completed { completed = submission.completedIndex }
    defer { release(through: completed) }
    try encode(target: target, path: .metal4(submission), use: submission.index, scopes: scopes)
  }

  /// New bins are drawn by the next draw, whatever else changes.
  private func scopesEncoded(_ encoded: Bool) -> Bool {
    if encoded { drawnKey = nil }
    return encoded
  }

  /// Reports that the GPU finished the encodes up to `index`: classic, the
  /// `encodeCount` after the encode in question; Metal 4, a submission index.
  /// What only those encodes still held is released now, not a few encodes later.
  public func noteCompleted(through index: UInt64) {
    guard index > completed else { return }
    completed = index
    release(through: index)
  }

  /// For a paused or hidden view: releases what only completed GPU work held,
  /// including each source's current frame and focus masks, so no host buffer
  /// stays pinned while nothing draws. The next `update()` takes every source's
  /// latest frame again.
  public func releaseIdleResources() {
    release(through: completed)
    var i = 0
    while i < sources.count {
      let s = sources[i]
      i += 1
      guard s.frame != nil, s.lastUse <= completed else { continue }
      s.frame = nil
      s.frameVersion &+= 1
      // Never a real sequence: the next refresh reads the slot whatever it holds.
      s.sequence = .max
      // Nothing draws: the masks go too, remade on the first frame after.
      var k = 0
      while k < s.feeds.count {
        if s.feeds[k].feed.focusMask != nil { dropMask(s, k) }
        k += 1
      }
    }
    drawnKey = nil
  }

  /// Whether a surface's status changed since the last call (published to its handle).
  public func takeStatusChanges() -> Bool {
    defer { statusChanged = false }
    return statusChanged
  }

  /// Whether a scope overlay's graticule changed since the last call (published to its handle).
  public func takeGraticuleChanges() -> Bool {
    defer { graticuleChanged = false }
    return graticuleChanged
  }

  // MARK: - Diagnostics

  /// The pass drawing `surface`, once `update()` has seen it.
  public func pass(for surface: MonitorSurface) -> MonitorPass? {
    surfaceState(surface)?.pass
  }

  /// The main feed of `source`, once `update()` has seen it: its LUTs, its scopes'
  /// input, and the focus analysis of the first surfaces of it with peaking.
  public func feed(for source: MonitorSource) -> MonitorFeed? {
    sourceState(source)?.feed
  }

  /// The feed `surface` draws with (its focus analysis), as of the last encode.
  public func feed(for surface: MonitorSurface) -> MonitorFeed? {
    guard let s = surfaceState(surface), s.feedIndex >= 0, s.feedIndex < s.source.feeds.count else { return nil }
    return s.source.feeds[s.feedIndex].feed
  }

  /// Feeds of `source`: one, plus one per further distinct focus analysis.
  public func feedCount(for source: MonitorSource) -> Int {
    sourceState(source)?.feeds.count ?? 0
  }

  /// The frame of `source` the next encode draws.
  public func frame(for source: MonitorSource) -> MonitorFrame? {
    sourceState(source)?.frame
  }

  public func accumulator(for overlay: MonitorScopeOverlay) -> ScopeAccumulator? {
    overlayState(overlay)?.accumulator
  }

  public func scopeRenderer(for overlay: MonitorScopeOverlay) -> ScopeRenderer? {
    overlayState(overlay)?.renderer
  }

  /// The group `overlay` is accumulated in: every scope of its source with the same monitor-LUT choice.
  public func scopeGroup(for overlay: MonitorScopeOverlay) -> ScopeGroup? {
    guard let o = overlayState(overlay) else { return nil }
    for g in groups where g.members.contains(where: { $0 === o }) { return g.group }
    return nil
  }

  /// Frames, LUTs and feeds held for in-flight GPU work.
  public var retiredCount: Int { retired.count }

  /// GPU memory owned here: focus masks, Freeze planes, pass rings, scope bins and textures.
  public var persistentMemoryBytes: Int {
    var n = 0
    for s in sources { for f in s.feeds { n += f.feed.persistentMemoryBytes } }
    for s in surfaces { n += s.pass.persistentMemoryBytes }
    for o in overlays { n += o.accumulator.persistentMemoryBytes + o.renderer.persistentMemoryBytes }
    return n
  }

  // MARK: - State

  final class SourceState {
    let source: MonitorSource
    /// `feeds[0]` carries the LUTs every surface and scope of the source sees;
    /// each holds at most one focus analysis per encode.
    var feeds: [FeedState]
    var frame: MonitorFrame?
    /// Moves whenever `frame` is replaced, a resubmitted frame with a new signal included.
    var frameVersion: UInt64 = 0
    var sequence: UInt64 = 0
    var lutRevision: UInt64 = 0
    /// The encode or submission that last read the frame and LUTs.
    var lastUse: UInt64 = 0
    var feed: MonitorFeed { feeds[0].feed }
    init(source: MonitorSource, feed: MonitorFeed) {
      self.source = source
      feeds = [FeedState(feed: feed)]
    }
  }

  final class FeedState {
    let feed: MonitorFeed
    /// The analysis it holds or is about to (nil: none).
    var spec: AnalysisSpec?
    /// Whether a surface draws with it in this encode.
    var claimed = false
    var analyzed: AnalysisKey?
    init(feed: MonitorFeed) { self.feed = feed }
  }

  /// What a focus mask depends on besides the frame: the LUTs and reading of the
  /// effective stage (a monitor stage without a monitor LUT is the output stage,
  /// an output stage without a burn-in LUT the source unless the frame's signal
  /// has a distinct output reading) and the two thresholds. A change of reading
  /// comes with a new frame, which `AnalysisKey.frame` already moves on.
  struct AnalysisSpec: Equatable {
    var stage: SignalStage
    var sensitivity: Double
    var noiseRejection: Double
  }

  struct AnalysisKey: Equatable {
    var frame: UInt64
    var lutRevision: UInt64
    var spec: AnalysisSpec
  }

  final class SurfaceState {
    let surface: MonitorSurface
    let source: SourceState
    let pass: MonitorPass
    var revision: UInt64 = .max
    var state = MonitorState()
    var region = MonitorRegion.full
    /// `state` as drawn: clean too while the scene is.
    var drawState = MonitorState()
    /// This encode's: where it draws, its analysis, the feed it draws with, and
    /// whether its prepare succeeded (it is drawn only then).
    var viewport: MonitorViewport?
    var spec: AnalysisSpec?
    var feedIndex = 0
    var prepared = false
    /// What the handle holds (shares the pass's arrays, so comparing is an identity check).
    var publishedStatus: MonitorStatus?
    var publishedLayout: MonitorLayout?
    var publishedViewport: MonitorViewport?
    init(surface: MonitorSurface, source: SourceState, pass: MonitorPass) {
      self.surface = surface
      self.source = source
      self.pass = pass
    }
  }

  final class OverlayState {
    let overlay: MonitorScopeOverlay
    let source: SourceState
    let accumulator: ScopeAccumulator
    let renderer: ScopeRenderer
    var revision: UInt64 = .max
    var settings = ScopeSettings()
    var region = MonitorRegion.full
    var monitorLUTEnabled = true
    var hidden = false
    /// `accumulationInterval` in nanoseconds.
    var interval: UInt64 = 0
    /// This encode's: whether it is drawn, and whether it is accumulated.
    var draws = false
    var measures = false
    /// When its bins were last accumulated (`MonitorRenderer.now()`).
    var accumulatedAt: UInt64 = 0
    /// What the bins depend on in the settings, and a counter that moves with it:
    /// display edits and region moves never re-accumulate.
    var settingsKey: ScopeSettings.AccumulationKey?
    var settingsRevision: UInt64 = 0
    var accumulated: AccumulationKey?
    var viewport: MonitorViewport?
    var prepared = false
    var publishedGraticule: ScopeGraticule?
    var publishedViewport: MonitorViewport?
    init(overlay: MonitorScopeOverlay, source: SourceState, accumulator: ScopeAccumulator, renderer: ScopeRenderer) {
      self.overlay = overlay
      self.source = source
      self.accumulator = accumulator
      self.renderer = renderer
    }
  }

  final class GroupState {
    let source: SourceState
    let monitorLUTEnabled: Bool
    let members: [OverlayState]
    let group: ScopeGroup
    /// When a frame held back by the members' rate is due (0: none held back).
    var dueAt: UInt64 = 0
    init(source: SourceState, monitorLUTEnabled: Bool, members: [OverlayState], group: ScopeGroup) {
      self.source = source
      self.monitorLUTEnabled = monitorLUTEnabled
      self.members = members
      self.group = group
    }
  }

  struct AccumulationKey: Equatable {
    var frame: UInt64
    var lutRevision: UInt64
    var settings: UInt64
  }

  struct Retired {
    var frame: MonitorFrame?
    var burnIn: MonitorLUT?
    var monitor: MonitorLUT?
    /// A feed that left (its mask and Freeze planes may still be read).
    var feed: MonitorFeed?
    var lastUse: UInt64
  }

  struct LayerKey: Equatable {
    var output: MonitorOutputColor
    var signal: SignalDescription?
    var transform: DisplayTransform
    var monitorStageHasLUT: Bool
    var primary: Int
  }

  struct DrawKey: Equatable {
    var width: Int
    var height: Int
    var pixelFormat: MTLPixelFormat
    var pixelsPerPoint: Double
    var generation: UInt64
  }

  enum Path {
    case classic(MTLCommandBuffer)
    case metal4(MonitorSubmission)
  }

  private func sourceState(_ source: MonitorSource) -> SourceState? {
    var i = 0
    while i < sources.count {
      if sources[i].source === source { return sources[i] }
      i += 1
    }
    return nil
  }

  private func surfaceState(_ surface: MonitorSurface) -> SurfaceState? {
    var i = 0
    while i < surfaces.count {
      if surfaces[i].surface === surface { return surfaces[i] }
      i += 1
    }
    return nil
  }

  private func overlayState(_ overlay: MonitorScopeOverlay) -> OverlayState? {
    var i = 0
    while i < overlays.count {
      if overlays[i].overlay === overlay { return overlays[i] }
      i += 1
    }
    return nil
  }

  private func record(_ error: any Error) {
    lastError = error
    errorCount &+= 1
  }

  /// Rebuilds the state lists for a new membership, keeping what still belongs.
  /// A scope that cannot be built yet (its engine compiles off this thread) or at
  /// all (recorded) is left out; the pictures are committed either way.
  private func reconcile(_ snapshot: MonitorScene.Snapshot) {
    output = snapshot.outputColor
    sceneClean = snapshot.clean
    var nextSources: [SourceState] = []
    func source(_ s: MonitorSource) -> SourceState {
      if let found = nextSources.first(where: { $0.source === s }) { return found }
      let state = sourceState(s) ?? SourceState(source: s, feed: engine.makeFeed())
      nextSources.append(state)
      return state
    }
    var nextSurfaces: [SurfaceState] = []
    for surface in snapshot.surfaces where !nextSurfaces.contains(where: { $0.surface === surface }) {
      let src = source(surface.source)
      if let old = surfaces.first(where: { $0.surface === surface }), old.source === src {
        nextSurfaces.append(old)
      } else {
        nextSurfaces.append(SurfaceState(surface: surface, source: src, pass: engine.makePass()))
      }
    }
    var nextOverlays: [OverlayState] = []
    for overlay in snapshot.scopes where !nextOverlays.contains(where: { $0.overlay === overlay }) {
      let src = source(overlay.source)
      if let old = overlays.first(where: { $0.overlay === overlay }), old.source === src {
        nextOverlays.append(old)
        continue
      }
      guard let scopes = scopeEngineOrBuild() else { continue }
      do {
        let accumulator = try scopes.makeAccumulator(settings: overlay.settings)
        nextOverlays.append(
          OverlayState(overlay: overlay, source: src, accumulator: accumulator, renderer: scopes.makeRenderer()))
        overlay.publish(statisticsReader: accumulator.statisticsReader)
      } catch {
        record(error)
      }
    }
    for s in nextSurfaces { s.drawState = cleaned(s.state) }
    // Sources leaving the scene hand their frame, LUTs and feeds to the retired list.
    for old in sources where !nextSources.contains(where: { $0 === old }) {
      retire(old.frame, old.feed.burnInLUT, old.feed.monitorLUT, lastUse: old.lastUse)
      for f in old.feeds { retire(feed: f.feed, lastUse: old.lastUse) }
    }
    sources = nextSources
    surfaces = nextSurfaces
    overlays = nextOverlays
    layerKey = nil
    needsRegroup = true
  }

  /// The scope engine, or nil while it builds off the display thread.
  private func scopeEngineOrBuild() -> ScopeEngine? {
    if let scopeEngine { return scopeEngine }
    if let shared = ScopeEngineCache.existing(for: engine) {
      scopeEngine = shared
      return shared
    }
    if scopeBuildState == .idle {
      scopeBuildState = .building
      scopeBuild.start(engine)
    }
    return nil
  }

  /// Takes an overlay's edits. Display and region edits only redraw.
  private func updateOverlay(_ o: OverlayState) -> Bool {
    guard let next = o.overlay.read(after: o.revision) else { return false }
    if next.lut != o.monitorLUTEnabled || o.revision == .max { needsRegroup = true }
    o.settings = next.settings
    o.region = next.region
    o.monitorLUTEnabled = next.lut
    o.hidden = next.hidden
    o.interval = UInt64(next.interval * 1e9)
    o.revision = next.revision
    if o.accumulator.settings != next.settings { o.accumulator.settings = next.settings }
    let key = next.settings.accumulationKey
    if key != o.settingsKey {
      o.settingsKey = key
      o.settingsRevision &+= 1
    }
    return true
  }

  /// One group per source and monitor-LUT choice, in overlay order; a group whose
  /// members did not change is kept (with its fused pipeline).
  private func regroup() {
    needsRegroup = false
    guard let scopes = scopeEngine else {
      groups = []
      return
    }
    var next: [GroupState] = []
    // Scope cadence is a property of the accumulation, not just of the source
    // and LUT.  Keeping different intervals in one fused group causes the
    // group's single dispatch to advance a slow member whenever a fast member
    // is due, so that member never observes its requested cadence.  Partition
    // by interval as well; each group can then be advanced atomically.
    var pending: [(source: SourceState, lut: Bool, interval: UInt64, members: [OverlayState])] = []
    for o in overlays {
      if let k = pending.firstIndex(where: {
        $0.source === o.source && $0.lut == o.monitorLUTEnabled && $0.interval == o.interval
      }) {
        pending[k].members.append(o)
      } else {
        pending.append((o.source, o.monitorLUTEnabled, o.interval, [o]))
      }
    }
    for p in pending {
      if let old = groups.first(where: {
        $0.source === p.source && $0.monitorLUTEnabled == p.lut && $0.members.count == p.members.count
          && zip($0.members, p.members).allSatisfy { $0 === $1 }
      }) {
        next.append(old)
        continue
      }
      do {
        let group = try scopes.makeGroup(p.members.map(\.accumulator))
        next.append(GroupState(source: p.source, monitorLUTEnabled: p.lut, members: p.members, group: group))
        // A new grouping accumulates afresh.
        for m in p.members { m.accumulated = nil }
      } catch {
        record(error)
      }
    }
    groups = next
  }

  /// Takes a source's newer frame and LUTs. A resubmitted frame (same id) with a
  /// new signal, pixel aspect or textures replaces the one held.
  private func refresh(_ s: SourceState) -> Bool {
    var changed = false
    if let next = s.source.frame(after: s.sequence) {
      if !Self.same(s.frame, next.frame) {
        // The same id on new textures (or a new signal) is a new picture: a mask
        // keyed by the id alone would otherwise be kept.
        if let old = s.frame, let frame = next.frame, old.id == frame.id {
          var k = 0
          while k < s.feeds.count {
            s.feeds[k].feed.invalidateFocusMask()
            k += 1
          }
        }
        retire(s.frame, nil, nil, lastUse: s.lastUse)
        s.frame = next.frame
        s.frameVersion &+= 1
        changed = true
      }
      s.sequence = next.sequence
    }
    if let luts = s.source.luts(after: s.lutRevision) {
      let feed = s.feed
      if feed.burnInLUT !== luts.burnIn || feed.monitorLUT !== luts.monitor {
        retire(
          nil, feed.burnInLUT === luts.burnIn ? nil : feed.burnInLUT,
          feed.monitorLUT === luts.monitor ? nil : feed.monitorLUT, lastUse: s.lastUse)
        var k = 0
        while k < s.feeds.count {
          s.feeds[k].feed.burnInLUT = luts.burnIn
          s.feeds[k].feed.monitorLUT = luts.monitor
          k += 1
        }
        changed = true
      }
      s.lutRevision = luts.revision
    }
    return changed
  }

  /// `state` as the scene draws it: clean while the scene is.
  private func cleaned(_ state: MonitorState) -> MonitorState {
    guard sceneClean, !state.clean else { return state }
    var s = state
    s.clean = true
    return s
  }

  /// Whether `a` and `b` draw the same: the same picture, signal, pixel aspect and textures.
  static func same(_ a: MonitorFrame?, _ b: MonitorFrame?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.id == b.id && a.signal == b.signal && a.pixelAspectRatio == b.pixelAspectRatio && a.packed === b.packed
      && a.luma === b.luma && a.chroma === b.chroma
  }

  private func retire(_ frame: MonitorFrame?, _ burnIn: MonitorLUT?, _ monitor: MonitorLUT?, lastUse: UInt64) {
    // Never drawn, or its last encode completed: nothing on the GPU can still read it.
    guard lastUse > completed, frame != nil || burnIn != nil || monitor != nil else { return }
    retired.append(Retired(frame: frame, burnIn: burnIn, monitor: monitor, feed: nil, lastUse: lastUse))
  }

  private func retire(feed: MonitorFeed, lastUse: UInt64) {
    guard lastUse > completed else { return }
    retired.append(Retired(frame: nil, burnIn: nil, monitor: nil, feed: feed, lastUse: lastUse))
  }

  private func release(through done: UInt64) {
    var i = 0
    while i < retired.count {
      if retired[i].lastUse <= done {
        let last = retired.count - 1
        if i != last { retired[i] = retired[last] }
        retired.removeLast()
      } else {
        i += 1
      }
    }
  }

  /// The layer tag and each surface's output colour. With a signal-native output
  /// the first surface with a frame keeps its native encoding and tags the layer;
  /// the rest are encoded explicitly for that tag.
  private func resolveLayer() {
    var primary = -1
    var i = 0
    while i < surfaces.count {
      if surfaces[i].source.frame != nil {
        primary = i
        break
      }
      i += 1
    }
    var key = LayerKey(output: output, signal: nil, transform: .none, monitorStageHasLUT: false, primary: primary)
    if output.encoding == .signalNative, primary >= 0 {
      let s = surfaces[primary]
      key.signal = s.source.frame?.signal
      key.transform = s.state.displayTransform.mode
      key.monitorStageHasLUT = s.source.feed.monitorStageHasLUT(for: s.state)
    }
    guard key != layerKey else { return }
    layerKey = key
    layerColor = output.layer(
      for: key.signal ?? .rec709, displayTransform: key.transform, monitorStageHasLUT: key.monitorStageHasLUT)
    let explicit = output.explicit(for: layerColor)
    i = 0
    while i < surfaces.count {
      surfaces[i].pass.outputColor = i == primary ? output : explicit
      i += 1
    }
    for o in overlays { o.renderer.setOutputColor(explicit) }
  }

  // MARK: - Encode

  private func encode(target: MTLTexture, path: Path, use: UInt64, scopes: Bool) throws {
    let width = target.width, height = target.height
    let format = MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat, sampleCount: target.sampleCount)
    assignFeeds(width: width, height: height)
    analyze(path: path, use: use)
    layoutOverlays(width: width, height: height)
    if scopes { _ = accumulate(path: path, use: use) }

    // Everything the render pass draws, prepared before it starts: a scope's
    // prepare may encode its trace resolve and graticule raster.
    var i = 0
    while i < surfaces.count {
      let s = surfaces[i]
      i += 1
      s.prepared = false
      guard let frame = s.source.frame, let viewport = s.viewport else { continue }
      if s.pass.outputColor.headroom != headroom {
        var output = s.pass.outputColor
        output.headroom = headroom
        s.pass.outputColor = output
      }
      let feed = s.source.feeds[s.feedIndex].feed
      do {
        switch path {
        case .classic(let cb):
          try s.pass.prepare(frame: frame, feed: feed, state: s.drawState, viewport: viewport, target: format, into: cb)
        case .metal4(let submission):
          try s.pass.prepare(
            frame: frame, feed: feed, state: s.drawState, viewport: viewport, target: format, submission: submission)
        }
        s.prepared = true
        s.source.lastUse = use
      } catch {
        record(error)
      }
    }
    i = 0
    while i < overlays.count {
      let o = overlays[i]
      i += 1
      o.prepared = false
      guard o.draws, let viewport = o.viewport else { continue }
      do {
        switch path {
        case .classic(let cb): try o.renderer.prepare(o.accumulator, viewport: viewport, target: format, into: cb)
        case .metal4(let submission):
          try o.renderer.prepare(o.accumulator, viewport: viewport, target: format, submission: submission)
        }
        o.prepared = true
      } catch {
        record(error)
      }
    }

    switch path {
    case .classic(let cb):
      let a = pass.colorAttachments[0]!
      a.texture = target
      let encoder = cb.makeRenderCommandEncoder(descriptor: pass)
      a.texture = nil
      guard let encoder else { throw MonitorKitError.gpu("Cannot create a render encoder for the view.") }
      defer { encoder.endEncoding() }
      i = 0
      while i < surfaces.count {
        if surfaces[i].prepared { draw(surfaces[i]) { try $0.draw(with: encoder) } }
        i += 1
      }
      i = 0
      while i < overlays.count {
        if overlays[i].prepared { overlays[i].renderer.draw(with: encoder) }
        i += 1
      }
    case .metal4(let submission):
      let a = pass4.colorAttachments[0]!
      a.texture = target
      let encoder = submission.commandBuffer.makeRenderCommandEncoder(descriptor: pass4)
      a.texture = nil
      guard let encoder else { throw MonitorKitError.gpu("Cannot create a Metal 4 render encoder for the view.") }
      defer { encoder.endEncoding() }
      i = 0
      while i < surfaces.count {
        if surfaces[i].prepared { draw(surfaces[i]) { try $0.draw(with: encoder) } }
        i += 1
      }
      i = 0
      while i < overlays.count {
        if overlays[i].prepared { overlays[i].renderer.draw(with: encoder) }
        i += 1
      }
    }

    var waitingForPipeline = false
    i = 0
    while i < overlays.count {
      let o = overlays[i]
      i += 1
      guard o.prepared, let viewport = o.viewport else { continue }
      if !o.renderer.isReady { waitingForPipeline = true }
      publish(o, viewport: viewport)
    }
    // A scope whose pipeline is still compiling drew nothing: draw again next tick.
    drawnKey =
      waitingForPipeline
      ? nil
      : DrawKey(
        width: width, height: height, pixelFormat: target.pixelFormat, pixelsPerPoint: pixelsPerPoint,
        generation: generation)
  }

  private func draw(_ s: SurfaceState, _ body: (MonitorPass) throws -> Void) {
    do {
      try body(s.pass)
      if let viewport = s.viewport { publish(s, viewport: viewport) }
    } catch {
      record(error)
    }
  }

  /// Each surface's viewport and analysis, and the feed it draws with: surfaces of
  /// a source asking for the same analysis share a feed, the first keeping the one
  /// it had. A surface that draws nothing asks for none. Allocates only when a new
  /// distinct analysis appears.
  private func assignFeeds(width: Int, height: Int) {
    var i = 0
    while i < sources.count {
      let s = sources[i]
      var k = 0
      while k < s.feeds.count {
        s.feeds[k].claimed = false
        k += 1
      }
      i += 1
    }
    i = 0
    while i < surfaces.count {
      let s = surfaces[i]
      i += 1
      s.viewport =
        s.source.frame == nil ? nil : s.region.viewport(width: width, height: height, pixelsPerPoint: pixelsPerPoint)
      s.spec = s.viewport != nil && s.drawState.focus.enabled && !s.drawState.clean ? spec(s) : nil
      s.feedIndex = s.spec == nil ? 0 : -1
    }
    // Exact matches first, so a surface keeps the mask it already has.
    i = 0
    while i < surfaces.count {
      let s = surfaces[i]
      i += 1
      guard let spec = s.spec else { continue }
      let feeds = s.source.feeds
      var k = 0
      while k < feeds.count {
        if feeds[k].spec == spec {
          feeds[k].claimed = true
          s.feedIndex = k
          break
        }
        k += 1
      }
    }
    i = 0
    while i < surfaces.count {
      let s = surfaces[i]
      i += 1
      guard s.feedIndex < 0, let spec = s.spec else { continue }
      let src = s.source
      // A feed another surface just claimed for this analysis, else the first free one.
      var match = -1, free = -1
      var k = 0
      while k < src.feeds.count {
        let f = src.feeds[k]
        if f.claimed {
          if f.spec == spec {
            match = k
            break
          }
        } else if free < 0 {
          free = k
        }
        k += 1
      }
      var found = match >= 0 ? match : free
      if found < 0 {
        let feed = engine.makeFeed()
        feed.burnInLUT = src.feed.burnInLUT
        feed.monitorLUT = src.feed.monitorLUT
        src.feeds.append(FeedState(feed: feed))
        found = src.feeds.count - 1
      }
      src.feeds[found].spec = spec
      src.feeds[found].claimed = true
      s.feedIndex = found
    }
    // Feeds no surface needs any more go, after the GPU work that may read them.
    i = 0
    while i < sources.count {
      let s = sources[i]
      i += 1
      while s.feeds.count > 1, !s.feeds[s.feeds.count - 1].claimed {
        retire(feed: s.feeds[s.feeds.count - 1].feed, lastUse: s.lastUse)
        s.feeds.removeLast()
      }
      if !s.feeds[0].claimed { s.feeds[0].spec = nil }
      var k = 0
      while k < s.feeds.count {
        if !s.feeds[k].claimed && s.feeds[k].feed.focusMask != nil { dropMask(s, k) }
        k += 1
      }
    }
  }

  /// Replaces feed `k` of `s`, whose focus mask no surface draws with (peaking
  /// off, clean, nothing drawn), by a fresh one with the same LUTs; the old one
  /// goes once the GPU work that may read it completed, and its mask (8.3 MB at
  /// 4K) with it. `MonitorFeed.analyze` with peaking off would need a frame and
  /// keeps a released mask for three more analyses, which an unused feed never runs.
  private func dropMask(_ s: SourceState, _ k: Int) {
    let old = s.feeds[k].feed
    let feed = engine.makeFeed()
    feed.burnInLUT = old.burnInLUT
    feed.monitorLUT = old.monitorLUT
    s.feeds[k] = FeedState(feed: feed)
    retire(feed: old, lastUse: s.lastUse)
  }

  /// The analysis `s` asks for, its stage reduced to the LUTs that stage actually
  /// has. A Monitor stage with no monitor LUT is the Output stage (both read the
  /// codes with the output reading); an Output stage with no burn-in LUT is the
  /// source only when the signal has no distinct output reading
  /// (`SignalDescription.outputReading`), else it decodes the codes its own way and
  /// `MonitorFeed` keeps its mask apart from the source's.
  private func spec(_ s: SurfaceState) -> AnalysisSpec {
    let focus = s.state.focus
    let feed = s.source.feed
    var stage = focus.stage
    if stage == .monitor && !(s.state.monitorLUT && feed.monitorLUT != nil) { stage = .output }
    let distinctReading = s.source.frame?.signal.hasDistinctOutputReading ?? false
    if stage == .output && feed.burnInLUT == nil && !distinctReading { stage = .source }
    return AnalysisSpec(stage: stage, sensitivity: focus.sensitivity, noiseRejection: focus.noiseRejection)
  }

  /// One focus analysis per claimed feed and new frame (or new LUTs or settings).
  private func analyze(path: Path, use: UInt64) {
    var i = 0
    while i < sources.count {
      let s = sources[i]
      i += 1
      guard let frame = s.frame else { continue }
      var k = 0
      while k < s.feeds.count {
        let f = s.feeds[k]
        k += 1
        guard f.claimed, let spec = f.spec else { continue }
        let key = AnalysisKey(frame: s.frameVersion, lutRevision: s.lutRevision, spec: spec)
        guard key != f.analyzed else { continue }
        var focus = FocusSettings()
        focus.enabled = true
        focus.stage = spec.stage
        focus.sensitivity = spec.sensitivity
        focus.noiseRejection = spec.noiseRejection
        do {
          switch path {
          case .classic(let cb): try f.feed.analyze(frame, focus: focus, into: cb)
          case .metal4(let submission): try f.feed.analyze(frame, focus: focus, into: submission)
          }
          f.analyzed = key
        } catch {
          f.analyzed = nil
          record(error)
        }
        // Encoded reads of the frame and LUTs, whether or not a surface then draws.
        s.lastUse = use
      }
    }
  }

  /// Each scope's viewport in this target, and whether it is drawn and measured:
  /// a hidden one is measured only, none is drawn while the scene is clean.
  private func layoutOverlays(width: Int, height: Int) {
    var i = 0
    while i < overlays.count {
      let o = overlays[i]
      i += 1
      let hasFrame = o.source.frame != nil
      o.viewport = hasFrame ? o.region.viewport(width: width, height: height, pixelsPerPoint: pixelsPerPoint) : nil
      o.draws = o.viewport != nil && !o.hidden && !sceneClean
      o.measures = hasFrame && (o.hidden || o.draws)
    }
  }

  /// Whether `g` accumulates now: a measured member's LUTs or bin settings moved,
  /// or its frame did and its interval passed. Records when a frame held back by
  /// the interval is due. Reads the clock into `now` (0: not yet) only for that.
  private func groupDue(_ g: GroupState, now: inout UInt64) -> Bool {
    guard g.source.frame != nil else {
      // Nothing to accumulate: a frame held back before is gone, nothing is due.
      g.dueAt = 0
      return false
    }
    var due = false
    var heldUntil = UInt64.max
    var m = 0
    while m < g.members.count {
      let o = g.members[m]
      m += 1
      guard o.measures else { continue }
      let k = key(o)
      guard k != o.accumulated else { continue }
      if o.interval > 0, let a = o.accumulated, a.lutRevision == k.lutRevision, a.settings == k.settings {
        // Only the frame moved: at the scope's rate.
        if now == 0 { now = Self.now() }
        let next = o.accumulatedAt &+ o.interval
        if now < next {
          heldUntil = min(heldUntil, next)
          continue
        }
      }
      due = true
    }
    g.dueAt = due || heldUntil == .max ? 0 : heldUntil
    return due
  }

  /// One accumulation per group that is due. Returns whether it encoded any.
  private func accumulate(path: Path, use: UInt64) -> Bool {
    var encoded = false
    var now: UInt64 = 0
    var i = 0
    while i < groups.count {
      let g = groups[i]
      i += 1
      guard groupDue(g, now: &now), let frame = g.source.frame else { continue }
      do {
        switch path {
        case .classic(let cb):
          try g.group.accumulate(frame, feed: g.source.feed, monitorLUTEnabled: g.monitorLUTEnabled, into: cb)
        case .metal4(let submission):
          try g.group.accumulate(frame, feed: g.source.feed, monitorLUTEnabled: g.monitorLUTEnabled, into: submission)
        }
        if now == 0 { now = Self.now() }
        var m = 0
        while m < g.members.count {
          g.members[m].accumulated = key(g.members[m])
          g.members[m].accumulatedAt = now
          m += 1
        }
        encoded = true
      } catch {
        record(error)
      }
      g.source.lastUse = use
    }
    return encoded
  }

  /// Monotonic nanoseconds, for the scopes' rates.
  static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  private func key(_ o: OverlayState) -> AccumulationKey {
    AccumulationKey(frame: o.source.frameVersion, lutRevision: o.source.lutRevision, settings: o.settingsRevision)
  }

  private func publish(_ s: SurfaceState, viewport: MonitorViewport) {
    let layout = s.pass.layout
    let statusDiffers = s.publishedStatus != s.pass.status
    guard statusDiffers || layout != s.publishedLayout || viewport != s.publishedViewport else { return }
    s.surface.publish(status: statusDiffers ? s.pass.status : nil, layout: layout, viewport: viewport)
    if statusDiffers { s.publishedStatus = s.pass.status }
    s.publishedLayout = layout
    s.publishedViewport = viewport
    if statusDiffers { statusChanged = true }
  }

  private func publish(_ o: OverlayState, viewport: MonitorViewport) {
    let graticuleDiffers = o.publishedGraticule != o.renderer.graticule
    guard graticuleDiffers || viewport != o.publishedViewport else { return }
    o.overlay.publish(graticule: graticuleDiffers ? o.renderer.graticule : nil, viewport: viewport)
    if graticuleDiffers { o.publishedGraticule = o.renderer.graticule }
    o.publishedViewport = viewport
    if graticuleDiffers { graticuleChanged = true }
  }
}

/// One scope engine per `MonitorEngine`, shared by its renderers and views, so N
/// views compile the scope library once.
enum ScopeEngineCache {
  private struct Entry {
    weak var monitor: MonitorEngine?
    weak var scopes: ScopeEngine?
  }
  /// Held only for a lookup or an insert, never across a build: the display
  /// thread's lookup must not wait for a compile.
  private static let entries = Mutex<[Entry]>([])
  /// Serializes builds, so two callers never build two.
  private static let builds = Mutex(())

  static func existing(for engine: MonitorEngine) -> ScopeEngine? {
    entries.withLock { list in
      var i = 0
      while i < list.count {
        if list[i].monitor === engine, let s = list[i].scopes { return s }
        i += 1
      }
      return nil
    }
  }

  /// The shared engine, built on this thread if none is alive.
  static func engine(for engine: MonitorEngine) throws -> ScopeEngine {
    if let found = existing(for: engine) { return found }
    return try builds.withLock { _ in
      if let found = existing(for: engine) { return found }
      let scopes = try ScopeEngine(
        device: engine.device, specialization: engine.specialization, framesInFlight: engine.framesInFlight,
        residency: engine.residency)
      entries.withLock { list in
        list.removeAll { $0.monitor == nil || $0.scopes == nil }
        list.append(Entry(monitor: engine, scopes: scopes))
      }
      return scopes
    }
  }
}

/// Builds the shared scope engine on a global queue (it compiles a library and
/// about ten pipelines) and hands it to the renderer's next tick.
final class ScopeEngineBuild: Sendable {
  private let result = Mutex<Result<ScopeEngine, any Error>?>(nil)

  func start(_ engine: MonitorEngine) {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let r = Result { try ScopeEngineCache.engine(for: engine) }
      result.withLock { $0 = r }
    }
  }

  func take() -> Result<ScopeEngine, any Error>? {
    result.withLock { r in
      defer { r = nil }
      return r
    }
  }
}
