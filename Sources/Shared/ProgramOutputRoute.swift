import CoreMedia
import CoreVideo
import Foundation
import IOSurface

/// The result of routing one processed frame through the Program output.
/// The scheduler decision remains available to diagnostics while the route
/// itself owns the bounded queue and retains the frame for its consumers.
/// A frame that needs GPU conversion is published when the GPU finishes, so
/// its `fanOut` summary is empty here.
struct ProgramRouteResult: @unchecked Sendable {
  let decision: ProgramFrameDecision<FeedID>
  let fanOut: FrameFanOutSummary
}

/// The Program camera's one output contract, fixed while a client is
/// connected. Every source frame is converted to it before the camera route.
struct ProgramOutputFormat: Equatable, Sendable, CustomStringConvertible {
  let width: Int
  let height: Int
  let pixelFormat: OSType
  let duration: CMTime
  let scalingMode: ProgramScalingMode
  let colour: Colorimetry

  init(width: Int, height: Int, pixelFormat: OSType, duration: CMTime, scalingMode: ProgramScalingMode = .fit, colour: Colorimetry = .rec709Video) {
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
    self.duration = duration
    self.scalingMode = scalingMode
    self.colour = Colorimetry(primaries: colour.primaries, transfer: colour.transfer, matrix: colour.matrix,
      range: colour.range, horizontalChromaSiting: .center, verticalChromaSiting: .center)
  }

  /// Mirrors `CameraSink.connect`: an untouched configuration negotiates the
  /// passthrough format, otherwise the processed format.
  init(configuration: PipelineConfiguration, passthroughFormat: OSType) {
    width = configuration.width
    height = configuration.height
    let nativeProgramPixels: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange]
    pixelFormat = configuration.untouched && nativeProgramPixels.contains(passthroughFormat)
      ? passthroughFormat : configuration.pixelFormat
    duration = configuration.reduceFrameRate ? configuration.frameRateTarget.duration : configuration.duration
    scalingMode = configuration.scalingMode
    let target = configuration.programColorimetry
    colour = Colorimetry(primaries: target.primaries, transfer: target.transfer, matrix: target.matrix,
      range: target.range, horizontalChromaSiting: .center, verticalChromaSiting: .center)
  }

  /// Geometry and pixel format. Cadence is converted separately, on the
  /// Program clock (`ProgramOutputRoute`).
  func matches(_ metadata: ProcessedFrameMetadata) -> Bool {
    metadata.width == width && metadata.height == height && OSType(metadata.pixelFormat) == pixelFormat
  }

  var description: String {
    "\(width)×\(height) \(VideoContract.fourCC(pixelFormat)) @ \(duration.value)/\(duration.timescale)"
  }
}

/// GPU conversion of one frame into the Program contract. Implementations
/// encode, commit and return without waiting for the GPU (the route calls
/// this under its lock); `completion` runs once, on any thread, after the GPU
/// has written the output. A GPU too far behind throws a stall instead.
protocol ProgramFrameNormalizing: AnyObject, Sendable {
  func canNormalize(_ metadata: ProcessedFrameMetadata, to contract: ProgramOutputFormat) -> Bool
  func normalize(_ source: CVPixelBuffer, to contract: ProgramOutputFormat,
                 completion: @escaping @Sendable (Result<CVPixelBuffer, Error>) -> Void) throws
  /// Frees cached GPU resources once no conversion uses them; work still on
  /// the GPU keeps its resources. Called when Program output goes idle.
  func releaseIdleResources()
}

extension ProgramFrameNormalizing {
  func releaseIdleResources() {}
}

/// Events the route reports to the main actor. Per-frame work never hops to
/// the main actor; only these state changes do.
enum ProgramRouteEvent: Sendable {
  case cutApplied(feedID: FeedID, sourceTime: CMTime, programTime: CMTime)
  case cutAbandoned(feedID: FeedID, reason: ProgramCutAbandonReason)
  /// The first failure after a healthy stretch; counts are in statistics.
  case outputError(String)
}

/// Counted outcomes of the Program output stage. Nothing here is a silent
/// drop: `overflowRejected`, `normalizationFailures` and on-air skips are
/// errors that are also reported through `ProgramRouteEvent.outputError`.
struct ProgramRouteStatistics: Equatable, Sendable {
  /// Selected-source frames accepted onto the Program clock.
  var accepted: UInt64 = 0
  /// Frames handed to the Program camera route, in Program order. A repeated
  /// frame (slower source) counts once per send.
  var published: UInt64 = 0
  /// Frames converted on the GPU to the contract before publishing.
  var normalized: UInt64 = 0
  /// Frames rejected because the camera route or the GPU stage was full.
  var overflowRejected: UInt64 = 0
  var normalizationFailures: UInt64 = 0
  /// Frames not converted because the GPU converter was not built yet. It is
  /// compiled in the background when Program output is prepared, never on
  /// the frame path. Also counted in `normalizationFailures`.
  var normalizerNotReady: UInt64 = 0
  /// Cadence conversion to the contract's frame rate on the Program clock.
  /// A faster source (59.94 into 29.97) sends every other frame; a slower
  /// one (29.97 into 59.94) sends each frame again at the next slot (the same
  /// IOSurface). Intentional, not errors.
  var cadenceSkipped: UInt64 = 0
  var cadenceRepeats: UInt64 = 0
  /// Source spans longer than the bounded repeat window.
  var cadenceDiscontinuities: UInt64 = 0
  /// Frames the scheduler skipped, by reason. Non-selected and stale-queued
  /// skips are normal (another source is on air, or a timed cut has not been
  /// reached). Missing-source and invalid-timestamp skips of the on-air
  /// source are errors and are also reported.
  var skippedNonSelected: UInt64 = 0
  var skippedStaleQueued: UInt64 = 0
  var skippedMissingSource: UInt64 = 0
  var skippedInvalidTimestamp: UInt64 = 0
  /// Frames released by a Program reset or topology change (not errors).
  var flushedOnReset: UInt64 = 0
  /// Accepted while no Program camera client was connected (not errors).
  var withoutConsumer: UInt64 = 0
  var maxStageDepth = 0
  /// Capture callback to publication, including any GPU conversion.
  var lastStageMilliseconds: Double = 0
  var maxStageMilliseconds: Double = 0
  var totalStageMilliseconds: Double = 0
  /// Per-frame calls made on the main thread. Should stay 0 in the app.
  var mainThreadIngests: UInt64 = 0
  var meanStageMilliseconds: Double { published == 0 ? 0 : totalStageMilliseconds / Double(published) }
}

/// Program output shared by all configured feeds. A source frame is
/// evaluated by `SwitcherCoordinator` first; only the selected source (or the
/// target at a valid cut boundary) is published to Program consumers.
///
/// Threading: every method may be called from any thread. Capture delivery
/// threads call `ingest` directly; the main actor calls the control methods.
/// One lock serializes the scheduler and the ordered output stage, so the
/// order in which frames are accepted onto the Program clock is the order in
/// which they are published, even when some need GPU conversion and finish
/// out of order. Callbacks that can re-enter the app (`onEvent`,
/// `onPublished`) run after the lock is released. `onMonitorFrame` runs under
/// the lock so the monitor sees frames in Program order; it must not block.
///
/// Non-selected sources: their frames only feed the scheduler (which needs
/// to see the target's first valid frame to land a cut) and are skipped with
/// no pixel work. They take the same direct path as the selected source; a
/// separate "latest frame only" hop for them would race at the cut boundary
/// (the target's first frame could be replaced before the scheduler saw it).
///
/// Cadence: with a contract, Program output runs on a grid of the contract's
/// frame duration on the Program clock. Each accepted frame covers
/// [programTime, programTime + its source duration) and is sent once for
/// every grid slot that starts inside that span: none for the odd frames of
/// a faster source, twice for a source at half the rate. Sent timestamps are
/// strictly increasing and spaced by the contract duration, which labels
/// every sample, so samples never overlap and a cut lands on the next slot.
final class ProgramOutputRoute: @unchecked Sendable {
  /// Metadata safety ceiling; media admission is independently time/byte bounded.
  static let stageMaximumMetadataSlots = 256
  /// Compatibility for the normalizer preconversion metadata ceiling.
  static let stageCapacity = stageMaximumMetadataSlots
  static let consumerCapacity = 24
  static let stagePolicy = try! MediaRetentionPolicy(maximumBytes: 512 * 1024 * 1024,
    maximumDuration: 0.4, maximumSlots: stageMaximumMetadataSlots, minimumSlots: 2)
  static let onAirSkipReportThreshold = 3
  static let healthyPublishDurationToRearm = 1.0

  private struct StageEntry {
    let sequence: UInt64
    let timeline: UInt64
    /// Timing of the first send; `sends` slots follow at the contract
    /// duration, all carrying the same image.
    let metadata: ProcessedFrameMetadata
    let sends: Int
    let acceptedAt: TimeInterval
    /// The source frame stays retained until its conversion completes.
    var source: ProcessedFrame<CVPixelBuffer>?
    var ready: ProcessedFrame<CVPixelBuffer>?
    var retention: MediaRetentionLedger.Lease?
    var backing: GPUAllocationBudget.Lease?
    var failed = false
  }

  private let lock = NSLock()
  private var state: SwitcherCoordinator
  private var monitorHandler: ((FeedID, ProcessedFrame<CVPixelBuffer>, CMTime, CMTime, Bool) -> Void)?
  private var eventHandler: (@Sendable (ProgramRouteEvent) -> Void)?
  private var publishedHandler: (@Sendable () -> Void)?
  private var outputContract: ProgramOutputFormat?
  private var outputActive = true
  private var normalizerProvider: (@Sendable () -> ProgramFrameNormalizing?)?
  private var liveSources: Set<FeedID>?
  private var acceptingCapture = true
  private var timeline: UInt64 = 0
  private var nextSequence: UInt64 = 0
  private var stage: [StageEntry] = []
  private var stats = ProgramRouteStatistics()
  private var errorReported = false
  /// Frames sent since the last failure; re-arms `errorReported`.
  private var healthyPublishedDuration = 0.0
  private var healthyPublishedEnd: CMTime?
  private let stageRetention: MediaRetentionLedger
  private let stageBacking: GPUAllocationBudget
  var stageRetentionSnapshot: MediaRetentionLedger.Snapshot { stageRetention.snapshot }
  var stageAllocationSnapshot: GPUAllocationBudget.Snapshot { stageBacking.snapshot() }
  /// Program time of the next contract-cadence slot.
  private var nextSlot: CMTime?
  /// Furthest bounded source span covered on this output timeline.
  private var coveredSourceEnd: CMTime?
  private var sourcePauseTolerances: [FeedID: Duration] = [:]
  /// A long or paused source cannot manufacture an unbounded burst of output.
  private let maximumRepeatDuration: Duration
  private var onAirSkips = 0
  let fanOut: FrameFanOut<CVPixelBuffer>

  init(settings: SwitcherSettings = .init(), feedIDs: [FeedID],
       routeLabel: String = "org.ultracam.program-output",
       maximumRepeatDuration: Duration = .seconds(2), retentionPolicy: MediaRetentionPolicy = stagePolicy) {
    stageRetention = MediaRetentionLedger(policy: retentionPolicy)
    stageBacking = GPUAllocationBudget(policy: try! GPUAllocationBudgetPolicy(maximumBytes: retentionPolicy.maximumBytes, minimumSlots: max(1, retentionPolicy.minimumSlots)))
    self.maximumRepeatDuration = max(.zero, maximumRepeatDuration)
    state = SwitcherCoordinator(settings: settings, feedIDs: feedIDs)
    fanOut = FrameFanOut(label: routeLabel)
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// A snapshot of the live scheduler for the UI and persistence.
  var switcher: SwitcherCoordinator { locked { state } }
  var selectedFeedID: FeedID? { locked { state.selectedFeedID } }
  var pendingFeedID: FeedID? { locked { state.pendingCut } }
  var pendingCutTime: CMTime? { locked { state.pendingCutTime } }
  var hasPendingCut: Bool { locked { state.hasPendingCut } }
  var isOnAir: Bool { locked { state.isOnAir } }
  var statistics: ProgramRouteStatistics { locked { stats } }
  var contract: ProgramOutputFormat? { locked { outputContract } }

  /// Declared source gaps may shorten, but never extend, the configured limit.
  func setSourcePauseTolerance(_ feedID: FeedID, mayPause: Duration?) {
    locked { sourcePauseTolerances[feedID] = mayPause.map { max(.zero, $0) } }
  }

  /// Called under the route lock, in Program order, from the ingesting thread.
  var onMonitorFrame: ((FeedID, ProcessedFrame<CVPixelBuffer>, CMTime, CMTime, Bool) -> Void)? {
    get { locked { monitorHandler } }
    set { locked { monitorHandler = newValue } }
  }

  /// Called after the lock is released, on the thread that caused the event.
  var onEvent: (@Sendable (ProgramRouteEvent) -> Void)? {
    get { locked { eventHandler } }
    set { locked { eventHandler = newValue } }
  }

  /// Called after frames reach the camera route; used to pump the bridge.
  var onPublished: (@Sendable () -> Void)? {
    get { locked { publishedHandler } }
    set { locked { publishedHandler = newValue } }
  }

  /// Sets the Program camera contract. Nil means no conversion (frames are
  /// published as they arrive). `active` false means no camera client: frames
  /// are not offered to the camera route at all.
  func setOutput(contract: ProgramOutputFormat?, active: Bool) {
    locked {
      let changed = outputContract != contract || outputActive != active
      if changed {
        // Frames already staged under the previous output contract (or while
        // the output was inactive) must never be published after the contract
        // changes. Invalidate the ordered stage and cadence clock together.
        flushOutputLocked()
        nextSlot = nil
        coveredSourceEnd = nil
      }
      outputContract = contract
      outputActive = active
      if active { errorReported = false }
      // No client, or a new contract: the converter's surfaces and output
      // pool for the old one are done with once their GPU work completes.
      if changed { normalizerProvider?()?.releaseIdleResources() }
    }
  }

  func setNormalizerProvider(_ provider: (@Sendable () -> ProgramFrameNormalizing?)?) {
    locked { normalizerProvider = provider }
  }

  /// Program mode on or off. Capture delivery is ignored while off, so
  /// separate-camera mode never feeds the Program scheduler.
  func setAcceptingCapture(_ accepting: Bool) {
    locked { acceptingCapture = accepting }
  }

  /// Capture delivery gating. When set, `ingest(fromCapture:)` accepts frames
  /// only from these sources; `nil` (the default) accepts all.
  func setSourceLive(_ feedID: FeedID, live: Bool) {
    locked {
      var sources = liveSources ?? []
      if live { sources.insert(feedID) } else { sources.remove(feedID) }
      liveSources = sources
    }
  }

  func updateFeeds(_ feedIDs: [FeedID]) {
    // Descriptor edits (name, LUT, format) arrive through the same coordinator
    // as topology edits. Do not reset the Program clock or drain a live queue
    // when the ordered feed identity set is unchanged.
    lock.lock()
    guard state.feedIDs != feedIDs else { lock.unlock(); return }
    let valid = Set(feedIDs)
    // Topology is authoritative for capture gating. In particular, a source
    // removed and later re-added must not inherit its old live state.
    if let liveSources {
      self.liveSources = liveSources.intersection(valid)
    }
    let selected = state.selectedFeedID.flatMap { valid.contains($0) ? $0 : nil }
    var settings = state.settings
    settings.selectedFeedID = selected ?? feedIDs.first
    // A topology change invalidates every queued source frame. Keeping those
    // leases would let a removed feed leak into the next Program segment and
    // would retain pixel buffers until the consumer happened to dequeue them.
    flushOutputLocked()
    let previous = state
    state = SwitcherCoordinator(settings: settings, feedIDs: feedIDs)
    // Readiness and a pending cut carry over; a cut whose target was removed
    // is reported, so its requester (the automatic director) is released.
    state.carryProgramTimeline(from: previous)
    let abandoned = state.takeAbandonedCut()
    let handler = eventHandler
    lock.unlock()
    if let (feedID, reason) = abandoned { handler?(.cutAbandoned(feedID: feedID, reason: reason)) }
  }

  /// Updates switch policy on the same coordinator that ingests Program
  /// frames. The selection is not changed here (see `SwitcherCoordinator`).
  func updateSettings(_ settings: SwitcherSettings) {
    mutate { $0.updateSettings(settings) }
  }

  @discardableResult
  func requestCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    mutate { $0.requestManualCut(to: feedID) }
  }

  @discardableResult
  func requestCut(to feedID: FeedID, noEarlierThan: CMTime?)
    -> ProgramCutRequestResult<FeedID> {
    mutate { $0.requestManualCut(to: feedID, at: noEarlierThan) }
  }

  /// Selects without a cut. Callers use this only when nothing is on air.
  @discardableResult
  func select(_ feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    mutate { $0.selectImmediately(feedID) }
  }

  /// A frame-boundary cut when something is on air and `cutsAllowed`;
  /// otherwise the selection changes at once. Decided under one lock, so a
  /// frame arriving between the check and the change cannot turn an instant
  /// selection into an unbounded cut, or the reverse.
  @discardableResult
  func requestSelection(_ feedID: FeedID, noEarlierThan: CMTime? = nil,
                        cutsAllowed: Bool) -> ProgramCutRequestResult<FeedID> {
    mutate { state in
      guard cutsAllowed, state.isOnAir else { return state.selectImmediately(feedID) }
      return state.requestManualCut(to: feedID, at: noEarlierThan)
    }
  }

  func cancelPendingCut() { mutate { $0.cancelPendingCut() } }

  func markSourcesIdle() { mutate { $0.markSourcesIdle() } }

  /// Marks a source unavailable for future Program cuts (or, when healthy,
  /// starting until its first frame). A pending cut aimed at an unavailable
  /// source is abandoned and reported; the on-air source keeps flowing.
  func setSourceHealth(_ feedID: FeedID, healthy: Bool) {
    mutate { $0.setFeedHealth(feedID, healthy: healthy) }
  }

  func setPendingCutClock(_ clock: @escaping () -> TimeInterval, timeout: TimeInterval,
                          startingTimeout: TimeInterval? = nil) {
    mutate { $0.setPendingCutClock(clock, timeout: timeout, startingTimeout: startingTimeout) }
  }

  /// Expires a pending cut whose target has stopped qualifying, without
  /// needing a frame. Called from the switcher tick.
  func expirePendingCutIfNeeded() { mutate { $0.expirePendingCutIfNeeded() } }

  @discardableResult
  func evaluate(at mediaTime: CMTime) -> SwitcherEvaluation {
    mutate { $0.evaluate(at: mediaTime) }
  }

  private func mutate<T>(_ body: (inout SwitcherCoordinator) -> T) -> T {
    lock.lock()
    let result = body(&state)
    let abandoned = state.takeAbandonedCut()
    let handler = eventHandler
    lock.unlock()
    if let (feedID, reason) = abandoned { handler?(.cutAbandoned(feedID: feedID, reason: reason)) }
    return result
  }

  /// Capture delivery entry point. Ignores sources that are not live.
  /// The capture controller calls this last for each frame, after its own
  /// preview and camera, and nothing here waits for the GPU.
  @discardableResult
  func ingest(fromCapture feedID: FeedID, frame: ProcessedFrame<CVPixelBuffer>) -> ProgramRouteResult? {
    route(feedID: feedID, frame: frame, captureGate: true)
  }

  /// Routes a processed frame. Frames that already match the contract (or
  /// when no contract is set) are published before this returns, with no
  /// pixel work. Other frames are converted on the GPU and published in
  /// Program order when the conversion completes. The caller keeps its own
  /// reference to `frame`; every accepted consumer gets its own lease.
  @discardableResult
  func ingest(feedID: FeedID, frame: ProcessedFrame<CVPixelBuffer>) -> ProgramRouteResult {
    route(feedID: feedID, frame: frame, captureGate: false)!
  }

  /// One lock covers the capture gate, the scheduler decision and the stage
  /// append, so a source stopped on the main actor cannot slip a frame in
  /// between the gate and the decision.
  private func route(feedID: FeedID, frame: ProcessedFrame<CVPixelBuffer>,
                     captureGate: Bool) -> ProgramRouteResult? {
    let acceptedAt = ProcessInfo.processInfo.systemUptime
    let metadata = frame.metadata
    let source = ProgramSourceFrame(sourceID: feedID,
      sourceTime: metadata.presentationTime, duration: metadata.duration)
    var events: [ProgramRouteEvent] = []
    lock.lock()
    if captureGate, !acceptingCapture || liveSources.map({ !$0.contains(feedID) }) == true {
      lock.unlock()
      return nil
    }
    if Thread.isMainThread { stats.mainThreadIngests &+= 1 }
    let decision = state.ingest(source)
    if let (target, reason) = state.takeAbandonedCut() {
      events.append(.cutAbandoned(feedID: target, reason: reason))
    }
    var report = FrameFanOutSummary()
    var published = false
    switch decision {
    case let .accepted(mapped), let .cutApplied(mapped):
      let cut: Bool
      if case .cutApplied = decision { cut = true } else { cut = false }
      onAirSkips = 0
      let mappedMetadata = ProcessedFrameMetadata(
        presentationTime: mapped.programTime,
        duration: mapped.programDuration,
        width: metadata.width,
        height: metadata.height,
        pixelFormat: metadata.pixelFormat, processingRevision: metadata.processingRevision)
      let programFrame = ProcessedFrame(payload: frame.payload, metadata: mappedMetadata)
      stats.accepted &+= 1
      monitorHandler?(feedID, programFrame, mapped.sourceTime, mapped.programTime, cut)
      (report, published) = enqueueLocked(programFrame, acceptedAt: acceptedAt, events: &events)
      if cut {
        events.append(.cutApplied(feedID: feedID, sourceTime: mapped.sourceTime,
          programTime: mapped.programTime))
      }
    case let .skipped(reason):
      recordSkipLocked(reason, feedID: feedID, events: &events)
    }
    let eventHandler = self.eventHandler
    let publishedHandler = self.publishedHandler
    lock.unlock()
    events.forEach { eventHandler?($0) }
    if published { publishedHandler?() }
    return ProgramRouteResult(decision: decision, fanOut: report)
  }

  private func recordSkipLocked(_ reason: ProgramFrameSkipReason, feedID: FeedID,
                                events: inout [ProgramRouteEvent]) {
    let onAirError: String?
    switch reason {
    case .nonSelectedSource:
      stats.skippedNonSelected &+= 1
      onAirError = nil
    case .staleQueuedFrame:
      stats.skippedStaleQueued &+= 1
      onAirError = nil
    case .missingSource:
      stats.skippedMissingSource &+= 1
      onAirError = "its camera is marked unavailable"
    case let .invalidTimestamp(error):
      stats.skippedInvalidTimestamp &+= 1
      onAirError = "its frames have invalid timing (\(error))"
    }
    guard let onAirError, feedID == state.selectedFeedID else { return }
    onAirSkips += 1
    // At and past the threshold: once the latch re-arms (a healthy stretch,
    // or a new client) a stream that is still broken is reported again.
    // Reset when the on-air source is accepted again.
    guard onAirSkips >= Self.onAirSkipReportThreshold else { return }
    reportErrorLocked("Program is skipping the on-air camera's frames: \(onAirError).", events: &events)
  }

  /// Grid slots of the contract cadence that start inside one accepted
  /// frame's span on the Program clock. Lock held.
  private func cadenceSlotsLocked(start: CMTime, duration: CMTime,
                                  step: CMTime, events: inout [ProgramRouteEvent]) -> (first: CMTime, count: Int) {
    guard step.isNumeric, step.value > 0, duration.isNumeric, duration.value > 0 else {
      return (start, 1)
    }
    let tolerance = state.selectedFeedID.flatMap { sourcePauseTolerances[$0] } ?? maximumRepeatDuration
    let window = min(tolerance, maximumRepeatDuration).components
    let seconds = Double(window.seconds) + Double(window.attoseconds) / 1e18
    // At least the original frame is allowed even when repetition is disabled.
    let limit = max(CMTimeGetSeconds(step), seconds)
    let clipped = CMTimeGetSeconds(duration) > limit
    let boundedDuration = clipped
      ? CMTime(seconds: limit, preferredTimescale: max(240_000, duration.timescale, step.timescale)) : duration
    let end = CMTimeAdd(start, boundedDuration)
    let missingDuration = coveredSourceEnd.map { CMTimeGetSeconds(CMTimeSubtract(start, $0)) } ?? 0
    if clipped || missingDuration > limit {
      stats.cadenceDiscontinuities &+= 1
      reportErrorLocked("Program source gap exceeded its repeat window; output resumes with the next source frame.", events: &events)
    }
    if coveredSourceEnd == nil || CMTimeCompare(end, coveredSourceEnd!) > 0 {
      coveredSourceEnd = end
    }
    var slot = nextSlot ?? start
    // Keep the original contract grid through missing callbacks. Jump directly
    // to its first slot at/after resume (constant work even for a long pause).
    // Sub-half-slot clock jitter keeps the pending slot, as before.
    if CMTimeCompare(CMTimeAdd(slot, CMTimeMultiplyByRatio(step, multiplier: 1, divisor: 2)), start) <= 0 {
      let delta = CMTimeSubtract(start, slot)
      let numerator = Int128(delta.value) * Int128(step.timescale)
      let denominator = Int128(delta.timescale) * Int128(step.value)
      guard numerator > 0, denominator > 0,
        let ticks = Int64(exactly: ((numerator + denominator - 1) / denominator) * Int128(step.value)) else {
        return (slot, 0)
      }
      slot = CMTimeAdd(slot, CMTime(value: ticks, timescale: step.timescale))
    }
    // An overlapping source prediction never rewinds slots already emitted.
    // A wholly covered span produces zero sends until source time catches up.
    let first = slot
    var count = 0
    // Bounded in time, so low-rate sources fill the grid without an arbitrary
    // four-frame cutoff and paused sources stop at their repeat window.
    while CMTimeCompare(slot, end) < 0 {
      count += 1
      slot = CMTimeAdd(slot, step)
    }
    nextSlot = slot
    return (first, count)
  }

  /// Appends one accepted frame to the ordered stage. Lock held. Never waits:
  /// GPU conversion is encoded and committed here, and completes later.
  private func enqueueLocked(_ frame: ProcessedFrame<CVPixelBuffer>, acceptedAt: TimeInterval,
                             events: inout [ProgramRouteEvent]) -> (FrameFanOutSummary, Bool) {
    guard outputActive else {
      stats.withoutConsumer &+= 1
      return (FrameFanOutSummary(), false)
    }
    let contract = outputContract
    let source = frame.metadata
    var sendTime = source.presentationTime
    var sends = 1
    if let contract {
      let step = CMTimeConvertScale(contract.duration, timescale: source.presentationTime.timescale,
        method: .roundHalfAwayFromZero)
      (sendTime, sends) = cadenceSlotsLocked(start: source.presentationTime, duration: source.duration, step: step, events: &events)
      guard sends > 0 else {
        // Faster than the contract: this frame falls between two slots.
        stats.cadenceSkipped &+= 1
        return (FrameFanOutSummary(), false)
      }
    }
    let retention: MediaRetentionLedger.Lease
    let backing: GPUAllocationBudget.Lease
    do {
      let bytes = try Self.storageBytes(frame.payload)
      try stageBacking.policy.validateMinimum(bytesPerSlot: bytes)
      retention = try stageRetention.admit(bytes: bytes, duration: CMTimeGetSeconds(contract?.duration ?? source.duration) * Double(sends))
      backing = try retainBacking(frame.payload, bytes: bytes)
    } catch {
      stats.overflowRejected &+= 1
      reportErrorLocked("Program output is behind: its GPU stage retention budget refused a frame.", events: &events)
      return (FrameFanOutSummary(), false)
    }
    nextSequence &+= 1
    // The contract's frame duration labels every sample.
    let pause = min(state.selectedFeedID.flatMap { sourcePauseTolerances[$0] } ?? maximumRepeatDuration,
      maximumRepeatDuration).components
    let repeatSeconds = Double(pause.seconds) + Double(pause.attoseconds) / 1e18
    let metadata = ProcessedFrameMetadata(presentationTime: sendTime,
      duration: contract?.duration ?? source.duration,
      width: contract?.width ?? source.width, height: contract?.height ?? source.height,
      pixelFormat: contract.map { UInt32($0.pixelFormat) } ?? source.pixelFormat,
      processingRevision: source.processingRevision, maximumRepeatDuration: repeatSeconds)
    var entry = StageEntry(sequence: nextSequence, timeline: timeline, metadata: metadata,
      sends: sends, acceptedAt: acceptedAt, retention: retention, backing: backing)
    if let contract, !contract.matches(source) || !contract.matchesColourAndAspect(frame.payload) {
      guard let normalizer = normalizerProvider?() else {
        stats.normalizerNotReady &+= 1
        stats.normalizationFailures &+= 1
        reportErrorLocked("Program GPU conversion isn't ready yet, so a frame in another format was not sent.",
          events: &events)
        return (FrameFanOutSummary(), false)
      }
      guard normalizer.canNormalize(source, to: contract) else {
        stats.normalizationFailures &+= 1
        reportErrorLocked("Program can't convert \(source.width)×\(source.height) \(VideoContract.fourCC(OSType(source.pixelFormat))) to \(contract).",
          events: &events)
        return (FrameFanOutSummary(), false)
      }
      entry.source = frame
      stage.append(entry)
      let sequence = entry.sequence
      let timeline = entry.timeline
      do {
        try normalizer.normalize(frame.payload, to: contract) { [weak self, retention, backing] result in
          defer { withExtendedLifetime((retention, backing)) {} }
          self?.completeNormalization(sequence: sequence, timeline: timeline, result: result)
        }
      } catch {
        stage.removeAll { $0.sequence == sequence }
        stats.normalizationFailures &+= 1
        reportErrorLocked("Program GPU conversion failed: \(error.localizedDescription)", events: &events)
        // Frames after this one may already be ready behind it.
        return flushStageLocked(events: &events)
      }
      stats.maxStageDepth = max(stats.maxStageDepth, stage.count)
      return (FrameFanOutSummary(), false)
    }
    stats.cadenceRepeats &+= UInt64(sends - 1)
    entry.ready = ProcessedFrame(payload: frame.payload, metadata: metadata)
    stage.append(entry)
    stats.maxStageDepth = max(stats.maxStageDepth, stage.count)
    return flushStageLocked(events: &events)
  }

  static func storageBytes(_ buffer: CVPixelBuffer) throws -> Int {
    let count = CVPixelBufferGetPlaneCount(buffer)
    let planes = count == 0
      ? [MediaStorageExtent.Plane(rowBytes: CVPixelBufferGetBytesPerRow(buffer), rows: CVPixelBufferGetHeight(buffer))]
      : (0..<count).map { MediaStorageExtent.Plane(rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, $0), rows: CVPixelBufferGetHeightOfPlane(buffer, $0)) }
    let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
    return try MediaStorageExtent.allocationBytes(planes: planes,
      pixelBufferDataSize: CVPixelBufferGetDataSize(buffer),
      ioSurfaceAllocationSize: surface.map { IOSurfaceGetAllocSize($0) })
  }

  private func retainBacking(_ buffer: CVPixelBuffer, bytes: Int) throws -> GPUAllocationBudget.Lease {
    if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
      return try stageBacking.acquire(backingID: UInt64(IOSurfaceGetID(surface)), bytes: bytes, generation: 0, owner: surface)
    }
    return try stageBacking.acquire(backingID: UInt64(UInt(bitPattern: Unmanaged.passUnretained(buffer).toOpaque())),
      bytes: bytes, generation: 0, owner: buffer)
  }

  private func completeNormalization(sequence: UInt64, timeline: UInt64,
                                     result: Result<CVPixelBuffer, Error>) {
    var events: [ProgramRouteEvent] = []
    lock.lock()
    var published = false
    if timeline == self.timeline, let index = stage.firstIndex(where: { $0.sequence == sequence }) {
      switch result {
      case let .success(output):
        stats.normalized &+= 1
        stats.cadenceRepeats &+= UInt64(stage[index].sends - 1)
        do {
          let bytes = try Self.storageBytes(output)
          // Acquire before releasing the source charge: both backings can coexist.
          let outputBacking = try retainBacking(output, bytes: bytes)
          stage[index].backing = outputBacking
          stage[index].ready = ProcessedFrame(payload: output, metadata: stage[index].metadata)
        } catch {
          stage[index].failed = true
          stats.overflowRejected &+= 1
          reportErrorLocked("Program normalized output exceeded its storage budget.", events: &events)
        }
      case let .failure(error):
        stage[index].failed = true
        stats.normalizationFailures &+= 1
        reportErrorLocked("Program GPU conversion failed: \(error.localizedDescription)", events: &events)
      }
      stage[index].source = nil
      published = flushStageLocked(events: &events).1
    }
    let eventHandler = self.eventHandler
    let publishedHandler = self.publishedHandler
    lock.unlock()
    events.forEach { eventHandler?($0) }
    if published { publishedHandler?() }
  }

  /// Publishes every completed frame at the head of the stage, in order. A
  /// repeated frame is sent again with the next slot's time; same image.
  private func flushStageLocked(events: inout [ProgramRouteEvent]) -> (FrameFanOutSummary, Bool) {
    var last = FrameFanOutSummary()
    var published = false
    while let head = stage.first, head.ready != nil || head.failed {
      stage.removeFirst()
      guard let ready = head.ready else { continue }
      let frame = ProcessedFrame(payload: ready.payload, metadata: ready.metadata,
        onReleased: { withExtendedLifetime((head.retention, head.backing)) {} })
      do {
        let summary = fanOut.publishRepeatedSummary(frame, count: head.sends)
        last = summary
        if summary.rejected > 0 {
          stats.overflowRejected &+= 1
          reportErrorLocked("Program output is behind: the camera queue is full, so a frame was dropped.",
            events: &events)
        }
        if summary.enqueued > 0 {
          stats.published &+= UInt64(summary.publishedSamples)
          published = true
          if summary.rejected == 0 {
            let start = frame.metadata.presentationTime
            let duration = CMTimeGetSeconds(frame.metadata.duration) * Double(head.sends)
            if let end = healthyPublishedEnd,
               abs(CMTimeGetSeconds(CMTimeSubtract(start, end))) > 0.000_001 {
              healthyPublishedDuration = 0
            }
            if duration.isFinite, duration > 0 {
              healthyPublishedDuration += duration
              healthyPublishedEnd = CMTimeAdd(start, CMTimeMultiply(frame.metadata.duration, multiplier: Int32(head.sends)))
              if healthyPublishedDuration + 1e-9 >= Self.healthyPublishDurationToRearm { errorReported = false }
            }
          }
          let elapsed = (ProcessInfo.processInfo.systemUptime - head.acceptedAt) * 1_000
          stats.lastStageMilliseconds = elapsed
          stats.maxStageMilliseconds = max(stats.maxStageMilliseconds, elapsed)
          stats.totalStageMilliseconds += elapsed * Double(summary.publishedSamples)
        }
      }
    }
    return (last, published)
  }

  /// Reports the first failure after a healthy stretch. Every failure, shown
  /// or not, restarts the stretch.
  private func reportErrorLocked(_ message: String, events: inout [ProgramRouteEvent]) {
    healthyPublishedDuration = 0
    healthyPublishedEnd = nil
    guard !errorReported else { return }
    errorReported = true
    events.append(.outputError(message))
  }

  /// Clears the "already reported" latch so the next failure is shown again.
  func acknowledgeOutputError() { locked { errorReported = false } }

  private func flushOutputLocked() {
    timeline &+= 1
    stats.flushedOnReset &+= UInt64(stage.count)
    stage.removeAll()
    fanOut.drain()
  }

  func addConsumerRoute(id: String = "program-camera", capacity: Int = consumerCapacity,
                        policy: FrameQueueOverflowPolicy = .reject, compactRepeats: Bool = false)
    throws -> FrameRoute<CVPixelBuffer> {
    try fanOut.addRoute(id: id, capacity: capacity, policy: policy, compactRepeats: compactRepeats)
  }

  func reset() {
    // Resetting the scheduler starts a new Program timeline. Any queued
    // leases belong to the old timeline and must not be delivered afterward.
    locked {
      flushOutputLocked()
      state.reset()
      nextSlot = nil
      coveredSourceEnd = nil
      onAirSkips = 0
    }
  }
}

