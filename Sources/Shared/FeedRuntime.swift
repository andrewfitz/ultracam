import CoreMedia
import CoreVideo
import Foundation
import MonitorToolsCore

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

  init(width: Int, height: Int, pixelFormat: OSType, duration: CMTime) {
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
    self.duration = duration
  }

  /// Mirrors `CameraSink.connect`: an untouched configuration negotiates the
  /// passthrough format, otherwise the processed format.
  init(configuration: PipelineConfiguration, passthroughFormat: OSType) {
    width = configuration.width
    height = configuration.height
    pixelFormat = configuration.untouched ? passthroughFormat : configuration.pixelFormat
    duration = configuration.duration
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
  /// Frames awaiting GPU conversion or publication. A real GPU stall of this
  /// many frames (~0.4 s at 59.94) is an error, reported and counted.
  static let stageCapacity = 24
  /// Consecutive skipped frames of the on-air source before it is reported.
  /// One or two can race a source being retired; more is a broken stream.
  static let onAirSkipReportThreshold = 3
  /// Consecutive frames sent to the camera after which the error latch
  /// re-arms (~1 s at 59.94): the next failure is reported again. Shorter
  /// would turn an intermittent fault into one main-actor event per frame.
  static let healthyPublishesToRearm = 60

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
  private var healthyPublishes = 0
  /// Program time of the next contract-cadence slot.
  private var nextSlot: CMTime?
  private var onAirSkips = 0
  let fanOut: FrameFanOut<CVPixelBuffer>

  init(settings: SwitcherSettings = .init(), feedIDs: [FeedID],
       routeLabel: String = "org.ultracam.program-output") {
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
    case let .accepted(mapped), let .cutApplied(mapped, _):
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
                                  step: CMTime) -> (first: CMTime, count: Int) {
    guard step.isNumeric, step.value > 0, duration.isNumeric, duration.value > 0 else {
      return (start, 1)
    }
    let end = CMTimeAdd(start, duration)
    var slot = nextSlot ?? start
    // A gap of half a slot or more (source frames missing, or output was off)
    // restarts the grid at this frame. A slot behind the frame by less than
    // that is clock jitter: keep the grid. A slot past this frame's span by a
    // whole step cannot come from a monotonic Program clock: restart too.
    if CMTimeCompare(CMTimeAdd(slot, CMTimeMultiplyByRatio(step, multiplier: 1, divisor: 2)), start) <= 0 ||
      CMTimeCompare(slot, CMTimeAdd(end, step)) > 0 {
      slot = start
    }
    let first = slot
    var count = 0
    // Bounded: a source at a quarter of the contract rate is the slowest
    // supported ratio by far (29.97 into 59.94 sends each frame twice).
    while CMTimeCompare(slot, end) < 0, count < 4 {
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
      (sendTime, sends) = cadenceSlotsLocked(start: source.presentationTime, duration: source.duration, step: step)
      guard sends > 0 else {
        // Faster than the contract: this frame falls between two slots.
        stats.cadenceSkipped &+= 1
        return (FrameFanOutSummary(), false)
      }
    }
    guard stage.count < Self.stageCapacity else {
      stats.overflowRejected &+= 1
      reportErrorLocked("Program output is behind: the GPU stage is full, so a frame was dropped.",
        events: &events)
      return (FrameFanOutSummary(), false)
    }
    nextSequence &+= 1
    // The contract's frame duration labels every sample.
    let metadata = ProcessedFrameMetadata(presentationTime: sendTime,
      duration: contract?.duration ?? source.duration,
      width: contract?.width ?? source.width, height: contract?.height ?? source.height,
      pixelFormat: contract.map { UInt32($0.pixelFormat) } ?? source.pixelFormat,
      processingRevision: source.processingRevision)
    var entry = StageEntry(sequence: nextSequence, timeline: timeline, metadata: metadata,
      sends: sends, acceptedAt: acceptedAt)
    if let contract, !contract.matches(source) {
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
        try normalizer.normalize(frame.payload, to: contract) { [weak self] result in
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
        stage[index].ready = ProcessedFrame(payload: output, metadata: stage[index].metadata)
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
      for index in 0..<head.sends {
        let frame: ProcessedFrame<CVPixelBuffer>
        if index == 0 {
          frame = ready
        } else {
          let metadata = ready.metadata
          frame = ProcessedFrame(payload: ready.payload, metadata: ProcessedFrameMetadata(
            presentationTime: CMTimeAdd(metadata.presentationTime,
              CMTimeMultiply(metadata.duration, multiplier: Int32(index))),
            duration: metadata.duration, width: metadata.width, height: metadata.height,
            pixelFormat: metadata.pixelFormat, processingRevision: metadata.processingRevision))
        }
        let summary = fanOut.publishSummary(frame)
        last = summary
        if summary.rejected > 0 {
          stats.overflowRejected &+= 1
          reportErrorLocked("Program output is behind: the camera queue is full, so a frame was dropped.",
            events: &events)
        }
        if summary.enqueued > 0 {
          stats.published &+= 1
          published = true
          healthyPublishes += 1
          if healthyPublishes >= Self.healthyPublishesToRearm { errorReported = false }
          let elapsed = (ProcessInfo.processInfo.systemUptime - head.acceptedAt) * 1_000
          stats.lastStageMilliseconds = elapsed
          stats.maxStageMilliseconds = max(stats.maxStageMilliseconds, elapsed)
          stats.totalStageMilliseconds += elapsed
        }
      }
    }
    return (last, published)
  }

  /// Reports the first failure after a healthy stretch. Every failure, shown
  /// or not, restarts the stretch.
  private func reportErrorLocked(_ message: String, events: inout [ProgramRouteEvent]) {
    healthyPublishes = 0
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

  func addConsumerRoute(id: String = "program-camera", capacity: Int = stageCapacity,
                        policy: FrameQueueOverflowPolicy = .reject)
    throws -> FrameRoute<CVPixelBuffer> {
    try fanOut.addRoute(id: id, capacity: capacity, policy: policy)
  }

  func reset() {
    // Resetting the scheduler starts a new Program timeline. Any queued
    // leases belong to the old timeline and must not be delivered afterward.
    locked {
      flushOutputLocked()
      state.reset()
      nextSlot = nil
      onAirSkips = 0
    }
  }
}

/// The lifecycle owned by one configured feed. Capture and camera transport
/// are deliberately outside this contract for now; they advance this state
/// through the coordinator while retaining their existing single-feed path.
enum FeedSessionState: Equatable, Sendable {
  case idle
  case running
  case unavailable(String)
  case failed(String)
}

/// Runtime state and output ownership for one feed descriptor.
///
/// A session owns its fan-out instance so stopping one feed drains only that
/// feed's pending leases. The capture implementation can publish processed
/// frames here when the descriptor-driven output routes are integrated.
@MainActor
final class FeedSession: Identifiable {
  let id: FeedID
  private(set) var descriptor: FeedDescriptor
  private(set) var state: FeedSessionState = .idle
  private(set) var generation: UInt64 = 0
  let frameFanOut: FrameFanOut<CVPixelBuffer>

  var isRunning: Bool { state == .running }

  init(descriptor: FeedDescriptor,
       frameFanOut: FrameFanOut<CVPixelBuffer> = FrameFanOut()) {
    id = descriptor.id
    self.descriptor = descriptor
    self.frameFanOut = frameFanOut
  }

  func update(descriptor: FeedDescriptor) {
    guard descriptor.id == id else { return }
    self.descriptor = descriptor
    if !descriptor.enabled, isRunning { stop() }
  }

  /// Starts a configured feed and returns false when the descriptor is
  /// disabled or the session is already active.
  @discardableResult
  func start() -> Bool {
    guard descriptor.enabled else {
      state = .unavailable("Feed is disabled")
      return false
    }
    guard !isRunning else { return false }
    generation &+= 1
    state = .running
    return true
  }

  /// Stops this feed and drains queued route leases while leaving route
  /// registration intact for a later start.
  func stop() {
    guard state != .idle else { return }
    generation &+= 1
    frameFanOut.drain()
    state = .idle
  }

  func fail(_ message: String) {
    generation &+= 1
    frameFanOut.drain()
    state = .failed(message)
  }

  func publish(_ frame: ProcessedFrame<CVPixelBuffer>) -> FrameFanOutReport {
    guard isRunning else {
      return FrameFanOutReport(outcomes: [:], routerClosed: false)
    }
    return frameFanOut.publish(frame)
  }

  func addRoute(id: String, capacity: Int,
                policy: FrameQueueOverflowPolicy) throws -> FrameRoute<CVPixelBuffer> {
    try frameFanOut.addRoute(id: id, capacity: capacity, policy: policy)
  }

  func removeRoute(_ route: FrameRoute<CVPixelBuffer>) {
    route.cancel()
  }
}

/// Main-actor collection of stable feed descriptors, runtime sessions, and
/// capture owners. Persisted ordering remains the source of truth for the
/// collection; sessions and controllers are created only for descriptors that
/// are accessed. Each controller owns an independent DeckLink backend.
@MainActor
final class FeedCoordinator {
  private(set) var descriptors: [FeedDescriptor]
  private(set) var selectedFeedID: FeedID
  private(set) var outputMode: FeedOutputMode
  /// Live switcher state, read from the route that ingests frames. There is
  /// no second copy that could disagree with what is on air.
  var switcher: SwitcherSettings { programOutput.switcher.settings }
  private(set) var virtualCameraRegistryVersion: Int
  var switcherCoordinator: SwitcherCoordinator { programOutput.switcher }
  private(set) var virtualCameraRegistrySnapshot: VirtualCameraRegistrySnapshot
  private let registryStore: VirtualCameraRegistryStore?
  var programMonitorConfiguration: MonitorConfiguration
  var monitorWorkspace: MonitorWorkspaceState
  private var sessions: [FeedID: FeedSession] = [:]
  let capturePool: FeedCapturePool
  let programOutput: ProgramOutputRoute
  private var programBridge: ProgramOutputBridge?
  private var demandCoordinator: RouteDemandCoordinator
  private var programConsumerActive = false
  private let programNormalizer = ProgramNormalizerLoader()
  var onProgramCutApplied: ((FeedID, CMTime, CMTime) -> Void)?
  /// A requested cut that will not land: the target failed to start, stopped,
  /// or never produced a qualifying frame. The selection did not change.
  var onProgramCutAbandoned: ((FeedID, ProgramCutAbandonReason) -> Void)?
  var onProgramOutputError: ((String) -> Void)?

  init(snapshot: AppSettingsSnapshot = AppSettingsSnapshot(),
       capturePool: FeedCapturePool = FeedCapturePool(),
       registryStore: VirtualCameraRegistryStore? = nil) {
    let safe = snapshot.validated() ?? AppSettingsSnapshot()
    programMonitorConfiguration = safe.programMonitorConfiguration
    monitorWorkspace = safe.monitorWorkspace
    descriptors = safe.feeds
    // A persisted selection can point at a disabled descriptor. Keep the
    // collection and the live Program route on the same usable source so a
    // restart cannot select a feed that `start` is guaranteed to reject.
    selectedFeedID = safe.feeds.first(where: { $0.id == safe.selectedFeedID && $0.enabled })?.id
      ?? safe.feeds.first(where: \.enabled)?.id
      ?? safe.feeds[0].id
    outputMode = safe.outputMode
    virtualCameraRegistryVersion = safe.virtualCameraRegistryVersion
    programOutput = ProgramOutputRoute(settings: safe.switcher,
      feedIDs: safe.feeds.filter(\.enabled).map(\.id))
    demandCoordinator = RouteDemandCoordinator()
    self.registryStore = registryStore
    self.capturePool = capturePool
    let initialDevices = Self.registryDevices(for: safe.outputMode, feeds: safe.feeds)
    let stored = registryStore?.load()
    let generation = max(stored?.generation ?? 0, UInt64(max(1, safe.virtualCameraRegistryVersion)))
    // The registry store can be pointed at a test or staging app group. Keep
    // the in-memory baseline on that same suite when it has no valid slots;
    // otherwise the first publication would fail the store's app-group fence.
    let registryGroup = registryStore?.groupIdentifier
      ?? VirtualCameraRegistrySnapshot.defaultAppGroupIdentifier
    virtualCameraRegistrySnapshot = VirtualCameraRegistrySnapshot(generation: generation,
      appGroupIdentifier: registryGroup, devices: initialDevices)
    if registryStore != nil { publishVirtualCameraRegistry() }
    let loader = programNormalizer
    // Never compiles: the route calls this under its lock on a capture
    // delivery thread. The converter is built in the background (`warm`).
    programOutput.setNormalizerProvider { loader.loadedNormalizer }
    if outputMode == .program { loader.warm() }
    programOutput.setAcceptingCapture(outputMode == .program)
    programOutput.onEvent = { [weak self] event in
      // State changes only; frames never take this hop.
      Task { @MainActor [weak self] in self?.handleProgramEvent(event) }
    }
  }

  private func handleProgramEvent(_ event: ProgramRouteEvent) {
    switch event {
    case let .cutApplied(feedID, sourceTime, programTime):
      // Program routing selection is owned by ProgramOutputRoute. Keep the
      // app's selected feed/UI editing identity stable across an automatic
      // A→B cut; changing it here makes status callbacks and persisted device
      // settings switch to the wrong source.
      if programConsumerActive, outputMode == .program {
        demandCoordinator.selectProgram(feedID: feedID.rawValue)
        _ = demandCoordinator.drainTransitions()
      }
      onProgramCutApplied?(feedID, sourceTime, programTime)
    case let .cutAbandoned(feedID, reason):
      onProgramCutAbandoned?(feedID, reason)
    case let .outputError(message):
      onProgramOutputError?(message)
    }
  }

  var selectedDescriptor: FeedDescriptor {
    descriptors.first(where: { $0.id == selectedFeedID }) ?? descriptors[0]
  }

  var orderedSessions: [FeedSession] {
    descriptors.filter(\.enabled).compactMap { sessions[$0.id] }
  }

  var selectedSession: FeedSession { session(for: selectedFeedID) }

  /// Stable capture owner for one feed.  Calling this for one feed never
  /// changes or reuses another feed's UltracamBackend.
  func capture(for id: FeedID) -> CaptureController {
    capturePool.controller(for: id)
  }

  func isFeedRunning(_ id: FeedID) -> Bool {
    sessions[id]?.isRunning == true
  }

  /// Installs the single consumer for the Program CMIO stream. The route is
  /// persistent across demand transitions so queued leases can be drained and
  /// reused without recreating a fan-out while a source callback is active.
  func prepareProgramOutputBridge() throws {
    guard programBridge == nil else { return }
    let route = try programOutput.addConsumerRoute(id: "program-camera",
      capacity: ProgramOutputRoute.stageCapacity, policy: .reject)
    let bridge = ProgramOutputBridge(route: route)
    attachProgramBridge(bridge)
  }

  /// Wires a bridge to the route: the bridge's negotiated contract becomes the
  /// route's conversion target, and every publication pumps the bridge from
  /// the publishing thread (never the main actor).
  func attachProgramBridge(_ bridge: ProgramOutputBridge) {
    programBridge = bridge
    bridge.enforceContract = true
    let route = programOutput
    // Nothing is offered to the camera route until a client is connected.
    route.setOutput(contract: nil, active: false)
    bridge.onContractChange = { contract in
      route.setOutput(contract: contract, active: contract != nil)
    }
    route.onPublished = { [weak bridge] in bridge?.schedulePump() }
    programNormalizer.warm()
  }

  /// Synchronous variant for tests; the app uses `requestProgramOutputDemand`.
  func setProgramOutputDemand(_ active: Bool, configuration: PipelineConfiguration,
                              passthroughFormat: OSType) throws {
    try prepareProgramOutputBridge()
    try programBridge?.setDemand(active, configuration: configuration,
      passthroughFormat: passthroughFormat)
  }

  /// Connects or closes the Program camera on the bridge's control queue so
  /// CMIO discovery (up to 3 s) never blocks the main actor. `completion`
  /// runs on the main actor.
  func requestProgramOutputDemand(_ active: Bool, configuration: PipelineConfiguration,
                                  passthroughFormat: OSType, renegotiate: Bool = false,
                                  completion: @escaping @MainActor @Sendable (Error?) -> Void) {
    do { try prepareProgramOutputBridge() } catch { completion(error); return }
    programBridge?.requestDemand(active, configuration: configuration,
      passthroughFormat: passthroughFormat, renegotiate: renegotiate) { error in
      Task { @MainActor in completion(error) }
    }
  }

  func pumpProgramOutput() { programBridge?.schedulePump() }

  var programOutputStatistics: ProgramOutputBridge.Statistics {
    programBridge?.currentStatistics ?? .init()
  }

  var programRouteStatistics: ProgramRouteStatistics { programOutput.statistics }

  var programNormalizerStatistics: ProgramNormalizer.Statistics? {
    programNormalizer.loadedNormalizer?.currentStatistics
  }

  /// Connects one feed's processed frames to the Program route. The capture
  /// delivery thread ingests directly: no main-actor hop, no latest-frame
  /// slot, nothing dropped on the way. The capture generation token fences out
  /// a callback already in flight from a previous start.
  func installProgramFrameDelivery(feedID: FeedID) {
    let controller = capture(for: feedID)
    let route = programOutput
    controller.onProcessedFrame = { [weak controller] frame, generation in
      guard let controller, controller.isAccepting(feedID: feedID),
        controller.generationToken == generation else { return }
      route.ingest(fromCapture: feedID, frame: frame)
    }
  }

  func removeProgramFrameDelivery(feedID: FeedID) {
    capture(for: feedID).onProcessedFrame = nil
  }

  func setCameraOutputEnabled(feedID: FeedID, enabled: Bool) {
    capture(for: feedID).setCameraOutputEnabled(enabled)
  }

  /// Updates the live Program scheduler. Capture failure of one source must
  /// not leave that source eligible for the next cut.
  func setProgramSourceHealth(_ feedID: FeedID, healthy: Bool) {
    guard descriptors.contains(where: { $0.id == feedID }) else { return }
    programOutput.setSourceHealth(feedID, healthy: healthy)
  }

  /// Lazily creates a session while preserving descriptor ordering.
  func session(for id: FeedID) -> FeedSession {
    if let session = sessions[id] { return session }
    let descriptor = descriptors.first(where: { $0.id == id }) ?? FeedDescriptor(id: id)
    if !descriptors.contains(where: { $0.id == id }) { descriptors.append(descriptor) }
    let session = FeedSession(descriptor: descriptor)
    sessions[id] = session
    return session
  }

  @discardableResult
  func select(_ id: FeedID) -> Bool {
    guard descriptors.contains(where: { $0.id == id && $0.enabled }) else { return false }
    selectedFeedID = id
    if programOutput.selectedFeedID == nil { programOutput.select(id) }
    return true
  }

  func update(_ descriptor: FeedDescriptor) {
    guard let index = descriptors.firstIndex(where: { $0.id == descriptor.id }) else {
      descriptors.append(descriptor)
      if !descriptor.enabled {
        capturePool.stop(descriptor.id)
      }
      programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
        publishVirtualCameraRegistry()
      return
    }
    descriptors[index] = descriptor
    // A descriptor can be disabled while its session is idle (for example,
    // when a capture owner was started directly by a camera demand callback).
    // Stopping only the FeedSession in that case leaves the native capture
    // owner active and allows late frames to outlive the descriptor.
    if !descriptor.enabled {
      capturePool.stop(descriptor.id)
      if selectedFeedID == descriptor.id {
        selectedFeedID = descriptors.first(where: \.enabled)?.id ?? descriptor.id
      }
    }
    sessions[descriptor.id]?.update(descriptor: descriptor)
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    if programConsumerActive {
      let selected = outputMode == .program ? programOutput.selectedFeedID?.rawValue : nil
      demandCoordinator.selectProgram(feedID: selected)
      _ = demandCoordinator.drainTransitions()
    }
    publishVirtualCameraRegistry()
  }

  @discardableResult
  func add(name: String? = nil) -> FeedID {
    var id = FeedID(uuid: UUID())
    while descriptors.contains(where: { $0.id == id }) { id = FeedID(uuid: UUID()) }
    let descriptor = FeedDescriptor(id: id, name: name ?? "Camera \(descriptors.count + 1)")
    descriptors.append(descriptor)
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    publishVirtualCameraRegistry()
    return id
  }

  /// Removes an idle feed. A running feed remains configured until its owner
  /// explicitly stops it, preventing a dangling route or camera client.
  @discardableResult
  func remove(_ id: FeedID) -> Bool {
    guard descriptors.count > 1, let index = descriptors.firstIndex(where: { $0.id == id }) else {
      return false
    }
    guard sessions[id]?.isRunning != true else { return false }
    // Dedicated/manual consumers represent external owners of this feed. A
    // topology removal must wait until those owners release their demand;
    // otherwise the demand coordinator retains an orphaned source ID.
    let demand = demandCoordinator.snapshot(for: id.rawValue)
    guard !demand.dedicatedCamera, !demand.manualOutput else { return false }
    guard capturePool.remove(id) else { return false }
    sessions.removeValue(forKey: id)?.stop()
    descriptors.remove(at: index)
    if selectedFeedID == id {
      selectedFeedID = descriptors.first(where: \.enabled)?.id ?? descriptors[0].id
    }
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    if programConsumerActive {
      demandCoordinator.selectProgram(feedID: programOutput.selectedFeedID?.rawValue)
      _ = demandCoordinator.drainTransitions()
    }
    publishVirtualCameraRegistry()
    return true
  }

  @discardableResult
  func start(_ id: FeedID) -> Bool {
    guard descriptors.contains(where: { $0.id == id }) else { return false }
    let started = session(for: id).start()
    if started {
      // Starting until its first frame: a cut to it waits for that frame.
      programOutput.setSourceLive(id, live: true)
      programOutput.setSourceHealth(id, healthy: true)
    }
    return started
  }

  func stop(_ id: FeedID) {
    guard descriptors.contains(where: { $0.id == id }) else { return }
    retireProgramSource(id)
    capturePool.stop(id)
    session(for: id).stop()
  }

  /// Starts the session and its independent native capture owner as one
  /// operation. The native controller reports asynchronous signal failures in
  /// its update stream, matching the established single-feed behavior.
  @discardableResult
  func startCapture(feedID: FeedID, deviceID: String, configuration: PipelineConfiguration,
                    pipelineEnabled: Bool = true, previewEnabled: Bool = true) -> Bool {
    guard start(feedID) else { return false }
    capture(for: feedID).start(feedID: feedID, deviceID: deviceID,
      configuration: configuration, pipelineEnabled: pipelineEnabled,
      previewEnabled: previewEnabled)
    return true
  }

  /// A stopped source takes no new frames and can't be cut to; a pending cut
  /// to it is abandoned and reported.
  private func retireProgramSource(_ id: FeedID) {
    programOutput.setSourceLive(id, live: false)
    programOutput.setSourceHealth(id, healthy: false)
  }

  func stopCapture(feedID: FeedID) {
    guard descriptors.contains(where: { $0.id == feedID }) else { return }
    retireProgramSource(feedID)
    capturePool.stop(feedID)
    session(for: feedID).stop()
  }

  func reconfigureCapture(feedID: FeedID, configuration: PipelineConfiguration,
                          pipelineEnabled: Bool) {
    capture(for: feedID).reconfigure(configuration: configuration, pipelineEnabled: pipelineEnabled)
  }

  func setPreviewEnabled(feedID: FeedID, enabled: Bool) {
    capture(for: feedID).setPreviewEnabled(enabled)
  }

  func setRecordingCallbacks(feedID: FeedID,
                             callbacks: SourceRecordingCallbackAdapter.Callbacks?) {
    capture(for: feedID).setRecordingCallbacks(feedID: feedID, callbacks: callbacks)
  }

  func addOutputRoute(feedID: FeedID, routeID: String, capacity: Int,
                      policy: FrameQueueOverflowPolicy) throws -> FrameRoute<CVPixelBuffer> {
    try session(for: feedID).addRoute(id: routeID, capacity: capacity, policy: policy)
  }

  func publish(_ frame: ProcessedFrame<CVPixelBuffer>, to feedID: FeedID)
    -> FrameFanOutReport {
    let feedSession = session(for: feedID)
    let report = feedSession.publish(frame)
    if feedSession.isRunning { _ = ingestProgramFrame(feedID: feedID, frame: frame) }
    return report
  }

  func setOutputMode(_ mode: FeedOutputMode) {
    guard outputMode != mode else { return }
    outputMode = mode
    // Keep the Program scheduler aligned with the persisted selection when the
    // program route is enabled. A feed can be selected while operating in
    // separate-camera mode, so the live scheduler may still point at an older
    // source when the mode changes.
    programOutput.updateFeeds(descriptors.filter(\.enabled).map(\.id))
    // Nothing is on air until a source delivers a frame in the new mode.
    programOutput.markSourcesIdle()
    programOutput.setAcceptingCapture(mode == .program)
    if mode == .program { programNormalizer.warm() }
    // A Program consumer is a source-demand route. Release it when leaving
    // Program mode and rebind it to the live scheduler when entering Program
    // mode, so a mode toggle cannot leave a removed/old feed running.
    if programConsumerActive {
      let selected = mode == .program ? programOutput.selectedFeedID?.rawValue : nil
      demandCoordinator.selectProgram(feedID: selected)
      _ = demandCoordinator.drainTransitions()
    }
    publishVirtualCameraRegistry()
  }

  func setSwitcher(_ settings: SwitcherSettings) {
    let requested = settings.selectedFeedID.flatMap { candidate in
      descriptors.contains(where: { $0.id == candidate && $0.enabled }) ? candidate : nil
    } ?? selectedFeedID
    // Policy first; the selection changes only through a cut (or at once when
    // nothing is on air), so the saved value always names the on-air source.
    programOutput.updateSettings(settings)
    if programOutput.selectedFeedID != requested { _ = requestProgramSelection(requested) }
    publishVirtualCameraRegistry()
  }

  /// A cut when something is on air in Program mode; otherwise the selection
  /// just changes, since there is no picture to cut away from.
  private func requestProgramSelection(_ feedID: FeedID,
                                       noEarlierThan: CMTime? = nil) -> ProgramCutRequestResult<FeedID> {
    guard descriptors.contains(where: { $0.id == feedID && $0.enabled }) else {
      return .rejectedMissingSource
    }
    return programOutput.requestSelection(feedID, noEarlierThan: noEarlierThan,
      cutsAllowed: outputMode == .program)
  }

  /// Requests a frame-boundary Program cut. The selection changes when the
  /// target's first valid frame lands; a target that is still starting keeps
  /// the cut pending until then, or until it fails (`onProgramCutAbandoned`).
  @discardableResult
  func requestProgramCut(to feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    requestProgramSelection(feedID)
  }

  @discardableResult
  func requestProgramCut(to feedID: FeedID, noEarlierThan: CMTime?)
    -> ProgramCutRequestResult<FeedID> {
    requestProgramSelection(feedID, noEarlierThan: noEarlierThan)
  }

  func cancelProgramCut() {
    programOutput.cancelPendingCut()
  }

  @discardableResult
  func evaluateSwitcher(at mediaTime: CMTime) -> SwitcherEvaluation {
    programOutput.evaluate(at: mediaTime)
  }

  /// Publishes a processed frame to the Program route when Program mode is
  /// active. Separate-camera mode leaves the frame on its feed route only.
  /// Test entry point; the app ingests through `installProgramFrameDelivery`.
  /// Cut events reach the main actor through
  /// `ProgramOutputRoute.onEvent`.
  @discardableResult
  func ingestProgramFrame(feedID: FeedID, frame: ProcessedFrame<CVPixelBuffer>)
    -> ProgramRouteResult? {
    guard outputMode == .program, descriptors.contains(where: { $0.id == feedID && $0.enabled }) else {
      return nil
    }
    return programOutput.ingest(feedID: feedID, frame: frame)
  }

  @discardableResult
  func addProgramOutputRoute(id: String = "program-camera", capacity: Int = ProgramOutputRoute.stageCapacity,
                             policy: FrameQueueOverflowPolicy = .reject)
    throws -> FrameRoute<CVPixelBuffer> {
    try programOutput.addConsumerRoute(id: id, capacity: capacity, policy: policy)
  }

  /// Ties source demand to the Program camera's consumer lifecycle. The
  /// caller executes returned start/stop transitions against its capture pool.
  @discardableResult
  func setProgramConsumer(_ active: Bool, at time: TimeInterval? = nil)
    -> [SourceDemandTransition] {
    programConsumerActive = active
    let selected = active && outputMode == .program
      ? programOutput.selectedFeedID?.rawValue : nil
    demandCoordinator.selectProgram(feedID: selected,
      at: time)
    return demandCoordinator.drainTransitions()
  }

  @discardableResult
  func setDedicatedCameraConsumer(feedID: FeedID, active: Bool,
                                  ownerID: String? = nil, at time: TimeInterval? = nil)
    -> [SourceDemandTransition] {
    // Releases must remain possible after a descriptor is disabled so an
    // existing consumer can relinquish its lease before topology removal.
    let known = descriptors.contains(where: { $0.id == feedID })
    guard known && (!active || descriptors.contains(where: { $0.id == feedID && $0.enabled })) else {
      return []
    }
    if active {
      _ = demandCoordinator.acquire(feedID: feedID.rawValue, route: .dedicatedCamera,
        ownerID: ownerID, at: time)
    } else {
      _ = demandCoordinator.release(feedID: feedID.rawValue, route: .dedicatedCamera,
        ownerID: ownerID, at: time)
    }
    return demandCoordinator.drainTransitions()
  }

  @discardableResult
  func advanceDemand(to time: TimeInterval) -> [SourceDemandTransition] {
    demandCoordinator.advance(to: time)
  }

  /// Feed IDs that currently keep a source capture demanded. Preview-only
  /// leases are intentionally omitted from this runtime-facing view.
  var activeDemandFeedIDs: Set<String> { demandCoordinator.activeSourceFeedIDs }

  /// Complete registry state published to the camera extension. Separate
  /// mode exposes one stable device per enabled feed; Program mode exposes one
  /// Program device while feed captures remain internal sources.
  var virtualCameraDescriptors: [VirtualCameraDescriptor] {
    Self.registryDevices(for: outputMode, feeds: descriptors)
  }

  var snapshot: AppSettingsSnapshot {
    AppSettingsSnapshot(feeds: descriptors, selectedFeedID: selectedFeedID,
      outputMode: outputMode, switcher: switcher,
      virtualCameraRegistryVersion: virtualCameraRegistryVersion,
      programMonitorConfiguration: programMonitorConfiguration, monitorWorkspace: monitorWorkspace)
  }

  @discardableResult
  private func publishVirtualCameraRegistry() -> Bool {
    let devices = virtualCameraDescriptors
    let next: VirtualCameraRegistrySnapshot
    if let current = registryStore?.load() {
      next = current.advancing(to: devices)
    } else {
      let generation = max(virtualCameraRegistrySnapshot.generation + 1, 1)
      next = VirtualCameraRegistrySnapshot(generation: generation, devices: devices)
    }
    virtualCameraRegistrySnapshot = next
    virtualCameraRegistryVersion = Int(min(next.generation, UInt64(Int.max)))
    guard let registryStore else { return true }
    do {
      try registryStore.save(next)
      return true
    } catch {
      return false
    }
  }

  private static func registryDevices(for mode: FeedOutputMode,
                                      feeds: [FeedDescriptor]) -> [VirtualCameraDescriptor] {
    switch mode {
    case .separateCameras:
      return feeds.filter(\.enabled).map { feed in
        VirtualCameraDescriptor.feed(feedID: feed.id.rawValue, displayName: "Ultracam · \(feed.name)")
      }
    case .program:
      return [VirtualCameraDescriptor.program()]
    }
  }
}
