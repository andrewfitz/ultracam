import CoreMedia
import Foundation

enum TalkingHeadDirectorMode: String, Codable, Equatable, Sendable {
  case lowLatency
  case transcriptAssisted
}

/// The state returned by a switcher evaluation. The coordinator never owns a
/// timer; callers provide the media clock when they evaluate it.
enum SwitcherEvaluation: Equatable {
  case idle
  case cutQueued(FeedID)
  case noHealthyFeed
  case dynamicAnalysisUnavailable
}

/// A pure Program route. It owns only the scheduler's value state and leaves
/// frame queues, capture and CMIO resources to their existing owners.
struct ProgramOutput<SourceID: Hashable> {
  private(set) var scheduler: ProgramCutScheduler<SourceID>

  init(selectedSource: SourceID? = nil, programTimescale: Int32 = 240_000) {
    scheduler = ProgramCutScheduler(selectedSource: selectedSource,
      programTimescale: programTimescale)
  }

  init(selectedFeedID: SourceID?, programTimescale: Int32 = 240_000) {
    self.init(selectedSource: selectedFeedID, programTimescale: programTimescale)
  }

  var selectedSource: SourceID? { scheduler.selectedSource }
  var isOnAir: Bool { scheduler.isOnAir }
  func readiness(of sourceID: SourceID) -> ProgramSourceReadiness { scheduler.readiness(of: sourceID) }

  mutating func takeAbandonedCut() -> (SourceID, ProgramCutAbandonReason)? {
    scheduler.takeAbandonedCut()
  }

  @discardableResult
  mutating func expirePendingCutIfNeeded() -> Bool { scheduler.expirePendingCutIfNeeded() }

  mutating func select(_ sourceID: SourceID) { scheduler.select(sourceID) }

  mutating func setClock(_ clock: @escaping () -> TimeInterval) { scheduler.setClock(clock) }

  var pendingCutTimeout: TimeInterval {
    get { scheduler.pendingCutTimeout }
    set { scheduler.pendingCutTimeout = newValue }
  }
  var startingCutTimeout: TimeInterval {
    get { scheduler.startingCutTimeout }
    set { scheduler.startingCutTimeout = newValue }
  }
  var pendingCut: SourceID? { scheduler.pendingCut }
  var pendingCutTime: CMTime? { scheduler.pendingCutTime }
  var hasPendingCut: Bool { scheduler.hasPendingCut }
  var selectedFeedID: SourceID? { selectedSource }
  var pendingFeedID: SourceID? { pendingCut }

  mutating func setSource(_ sourceID: SourceID, available: Bool) {
    scheduler.setSource(sourceID, available: available)
  }

  mutating func setSourceHealth(_ sourceID: SourceID, healthy: Bool) {
    setSource(sourceID, available: healthy)
  }

  func isSourceAvailable(_ sourceID: SourceID) -> Bool {
    scheduler.isSourceAvailable(sourceID)
  }

  mutating func requestCut(to sourceID: SourceID) -> ProgramCutRequestResult<SourceID> {
    scheduler.requestCut(to: sourceID)
  }

  mutating func requestCut(to sourceID: SourceID,
                           noEarlierThan: CMTime?) -> ProgramCutRequestResult<SourceID> {
    scheduler.requestCut(to: sourceID, noEarlierThan: noEarlierThan)
  }

  mutating func cancelPendingCut() {
    scheduler.cancelPendingCut()
  }

  mutating func ingest(_ frame: ProgramSourceFrame<SourceID>)
    -> ProgramFrameDecision<SourceID> {
    scheduler.ingest(frame)
  }

  mutating func reset(selectedSource: SourceID? = nil) {
    let timeout = scheduler.pendingCutTimeout
    let startingTimeout = scheduler.startingCutTimeout
    scheduler = ProgramCutScheduler(selectedSource: selectedSource,
      programTimescale: scheduler.mapper.programTimescale)
    scheduler.pendingCutTimeout = timeout
    scheduler.startingCutTimeout = startingTimeout
  }

  mutating func carryTimeline(from previous: ProgramOutput<SourceID>,
                              keeping sources: Set<SourceID>? = nil) {
    scheduler.carryTimeline(from: previous.scheduler, keeping: sources)
  }
}

/// Coordinates persisted switcher settings with the frame-boundary Program
/// route. This type is deliberately independent from capture and CMIO.
struct SwitcherCoordinator {
  private(set) var settings: SwitcherSettings
  private(set) var feedIDs: [FeedID]
  private(set) var feedHealth: [FeedID: Bool]
  /// Running sources no cut may go to: a lost signal, until it has been steady a while. Unlike
  /// `feedHealth` this leaves the scheduler alone, so the one on air keeps sending its frames.
  private(set) var cutIneligible: Set<FeedID> = []
  private(set) var selectedFeedID: FeedID?
  private(set) var programOutput: ProgramOutput<FeedID>

  private var fixedIntervalOrigin = Double.nan
  private var automaticRequestPending = false
  /// The most recent cut dropped without landing, kept until the route
  /// reports it. The scheduler reports each one once.
  private var abandonedCut: (FeedID, ProgramCutAbandonReason)?

  init(settings: SwitcherSettings = .init(), feedIDs: [FeedID] = []) {
    let ids = Self.unique(feedIDs)
    let initial = settings.selectedFeedID.flatMap { ids.contains($0) ? $0 : nil }
      ?? ids.first
    var normalizedSettings = settings
    normalizedSettings.selectedFeedID = initial
    self.settings = normalizedSettings
    self.feedIDs = ids
    self.feedHealth = Dictionary(uniqueKeysWithValues: self.feedIDs.map { ($0, true) })
    self.selectedFeedID = initial
    self.programOutput = ProgramOutput(selectedSource: initial)
  }

  init(settings: SwitcherSettings = .init(), feeds: [FeedDescriptor]) {
    self.init(settings: settings, feedIDs: feeds.filter(\.enabled).map(\.id))
  }

  /// The UI can use this message without presenting dynamic analysis as an
  /// active mode. The strategy remains persisted for a future implementation.
  var statusMessage: String {
    settings.strategy == .dynamicAnalysis ? "Coming later." : "Ready"
  }

  var pendingCut: FeedID? { programOutput.pendingCut }
  var pendingCutTime: CMTime? { programOutput.pendingCutTime }
  var hasPendingCut: Bool { programOutput.hasPendingCut }
  var isOnAir: Bool { programOutput.isOnAir }
  var isAutomaticRequestPending: Bool { automaticRequestPending }
  func readiness(of feedID: FeedID) -> ProgramSourceReadiness { programOutput.readiness(of: feedID) }

  /// Returns, once, the cut most recently dropped without landing (expired,
  /// cancelled by health, or a target that failed to start).
  mutating func takeAbandonedCut() -> (FeedID, ProgramCutAbandonReason)? {
    defer { abandonedCut = nil }
    return abandonedCut
  }

  /// Test hook for the pending-cut expiry clock. `startingTimeout` bounds
  /// the wait for a target that has not sent its first frame.
  mutating func setPendingCutClock(_ clock: @escaping () -> TimeInterval, timeout: TimeInterval,
                                   startingTimeout: TimeInterval? = nil) {
    programOutput.setClock(clock)
    programOutput.pendingCutTimeout = timeout
    if let startingTimeout { programOutput.startingCutTimeout = startingTimeout }
  }

  /// Keeps the automatic latch in step with the scheduler. Any pending cut that disappears without landing (expiry,
  /// health, cancel) must release `automaticRequestPending`; otherwise the
  /// fixed-interval policy stays idle forever (PROG-2).
  private mutating func reconcilePendingState() {
    if let (target, reason) = programOutput.takeAbandonedCut() {
      abandonedCut = (target, reason)
    }
    if !programOutput.hasPendingCut { automaticRequestPending = false }
  }

  /// Changes the selection without a cut, for when nothing is on air. The
  /// saved and on-air selection stay the same value.
  mutating func selectImmediately(_ feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    guard feedIDs.contains(feedID) else { return .rejectedMissingSource }
    programOutput.select(feedID)
    selectedFeedID = feedID
    settings.selectedFeedID = feedID
    automaticRequestPending = false
    return .selectedImmediately
  }

  mutating func setFeedHealth(_ feedID: FeedID, healthy: Bool) {
    guard feedIDs.contains(feedID) else { return }
    feedHealth[feedID] = healthy
    programOutput.setSourceHealth(feedID, healthy: healthy)
    // Health can drop the pending cut inside the scheduler. The automatic
    // latch has to drop with it, or later ticks stay idle forever.
    reconcilePendingState()
  }

  /// Whether cuts may go to a source, apart from whether it runs. A cut already waiting for
  /// it is dropped and reported; its frames, on air or not, are untouched.
  mutating func setCutEligible(_ feedID: FeedID, eligible: Bool) {
    guard feedIDs.contains(feedID) else { return }
    guard !eligible else { cutIneligible.remove(feedID); return }
    cutIneligible.insert(feedID)
    if programOutput.pendingCut == feedID { dropPendingCut(.targetUnavailable) }
  }

  /// Copies the Program clock, remaining source health and readiness, and a
  /// pending cut onto a coordinator rebuilt for a feed add, remove, or
  /// disable. The new mapper would otherwise start presentation time at zero
  /// on the same sink, the on-air source would read as starting (so a request
  /// would select at once instead of cutting), and a pending cut would vanish
  /// without the abandoned report its requester waits for.
  mutating func carryProgramTimeline(from previous: SwitcherCoordinator) {
    programOutput.carryTimeline(from: previous.programOutput, keeping: Set(feedIDs))
    for (id, healthy) in previous.feedHealth where feedIDs.contains(id) {
      feedHealth[id] = healthy
      programOutput.setSourceHealth(id, healthy: healthy)
    }
    cutIneligible = previous.cutIneligible.intersection(feedIDs)
    if programOutput.hasPendingCut {
      automaticRequestPending = previous.automaticRequestPending
    }
    reconcilePendingState()
  }

  mutating func setSourceHealth(_ feedID: FeedID, healthy: Bool) {
    setFeedHealth(feedID, healthy: healthy)
  }

  /// Updates policy. The selection is not a setting: it changes only when a
  /// cut lands (or by `selectImmediately` when nothing is on air), so the saved
  /// selection always names the source on air.
  mutating func updateSettings(_ settings: SwitcherSettings) {
    var settings = settings
    settings.selectedFeedID = selectedFeedID
    let changed = self.settings != settings
    self.settings = settings
    if changed {
      cancelPendingCut()
    }
    fixedIntervalOrigin = .nan
    automaticRequestPending = false
    reconcilePendingState()
  }

  /// Running and able to take a cut.
  func isFeedHealthy(_ feedID: FeedID) -> Bool {
    (feedHealth[feedID] ?? false) && !cutIneligible.contains(feedID)
  }

  /// Adds a manual cut to the Program boundary queue. `selectedFeedID` changes
  /// only once the Program route observes the target frame or an explicit ACK.
  @discardableResult
  mutating func requestManualCut(to feedID: FeedID, at: CMTime? = nil)
    -> ProgramCutRequestResult<FeedID> {
    guard feedIDs.contains(feedID), isFeedHealthy(feedID) else {
      return .rejectedMissingSource
    }
    automaticRequestPending = false
    let result = programOutput.requestCut(to: feedID, noEarlierThan: at)
    reconcilePendingState()
    return result
  }

  @discardableResult
  mutating func manualOverride(to feedID: FeedID, at time: CMTime)
    -> ProgramCutRequestResult<FeedID> {
    requestManualCut(to: feedID, at: time)
  }

  @discardableResult
  mutating func selectFeed(_ feedID: FeedID) -> ProgramCutRequestResult<FeedID> {
    requestManualCut(to: feedID)
  }

  /// Evaluate fixed interval policy at a caller supplied media time. The first
  /// evaluation establishes the interval origin, making replay deterministic.
  mutating func evaluate(at mediaTime: CMTime) -> SwitcherEvaluation {
    guard let now = validSeconds(mediaTime) else { return .idle }
    guard settings.strategy != .dynamicAnalysis else { return .dynamicAnalysisUnavailable }
    // Expire first: a cut that can no longer land must release the latch
    // before the latch is consulted.
    programOutput.expirePendingCutIfNeeded()
    reconcilePendingState()
    guard settings.automatic, settings.strategy == .fixedInterval else { return .idle }
    let health: [UInt8] = feedIDs.map { isFeedHealthy($0) ? 1 : 0 }
    let current = selectedFeedID.flatMap { feedIDs.firstIndex(of: $0) } ?? -1
    let index = auto_switcher_interval(&fixedIntervalOrigin, now, settings.intervalSeconds,
      settings.naturalTalkingHead.manualHold, automaticRequestPending || programOutput.hasPendingCut,
      health, health.count, current)
    if index == -2 { return .noHealthyFeed }
    guard feedIDs.indices.contains(index) else { return .idle }
    let target = feedIDs[index]
    let result = programOutput.requestCut(to: target)
    guard case .queued = result else { return .idle }
    automaticRequestPending = true
    return .cutQueued(target)
  }

  mutating func evaluate(at seconds: TimeInterval) -> SwitcherEvaluation {
    evaluate(at: CMTime(seconds: seconds, preferredTimescale: 240_000))
  }

  mutating func tick(at mediaTime: CMTime) -> SwitcherEvaluation {
    evaluate(at: mediaTime)
  }

  mutating func tick(at seconds: TimeInterval) -> SwitcherEvaluation {
    evaluate(at: seconds)
  }

  /// Forward one source frame to the Program scheduler. A cut is applied only
  /// when the target source presents a valid frame boundary.
  mutating func ingest(_ frame: ProgramSourceFrame<FeedID>)
    -> ProgramFrameDecision<FeedID> {
    let decision = programOutput.ingest(frame)
    if case let .cutApplied(mapped) = decision {
      selectedFeedID = mapped.sourceID
      settings.selectedFeedID = mapped.sourceID
      automaticRequestPending = false
    }
    reconcilePendingState()
    return decision
  }

  /// Acknowledges a manual or fixed-interval cut by feed ID. The route should
  /// normally call `ingest` first; this method is useful for output adapters
  /// that report an applied boundary separately from frame delivery.
  @discardableResult
  mutating func acknowledgeCut(to feedID: FeedID, appliedAt: CMTime? = nil) -> Bool {
    _ = appliedAt
    guard feedIDs.contains(feedID), isFeedHealthy(feedID) else { return false }
    guard programOutput.selectedSource == feedID || programOutput.pendingCut == feedID else {
      return false
    }
    // An output adapter may acknowledge before the target frame reaches the
    // scheduler. Treat that acknowledgement as the applied boundary: move the
    // route on air immediately and clear the queued cut so it cannot later
    // land a second time.
    if programOutput.pendingCut == feedID {
      programOutput.select(feedID)
      _ = programOutput.takeAbandonedCut()
    }
    selectedFeedID = feedID
    settings.selectedFeedID = feedID
    automaticRequestPending = false
    return true
  }

  @discardableResult
  mutating func acknowledgeCut(_ feedID: FeedID, appliedAt: CMTime? = nil) -> Bool {
    acknowledgeCut(to: feedID, appliedAt: appliedAt)
  }

  mutating func reset() {
    selectedFeedID = feedIDs.first
    settings.selectedFeedID = selectedFeedID
    programOutput.reset(selectedSource: selectedFeedID)
    for (feedID, healthy) in feedHealth {
      programOutput.setSourceHealth(feedID, healthy: healthy)
    }
    abandonedCut = nil
    _ = programOutput.takeAbandonedCut()
    fixedIntervalOrigin = .nan
    automaticRequestPending = false
  }

  /// Withdraws a pending cut. Its requester still hears of it, as cancelled: nothing failed.
  mutating func cancelPendingCut() { dropPendingCut(.cancelled) }

  private mutating func dropPendingCut(_ reason: ProgramCutAbandonReason) {
    // Dropping is still an outcome for whoever requested the cut. The
    // scheduler's public cancellation API clears silently, so preserve the
    // target here and report it through the coordinator's one-shot channel.
    if let target = programOutput.pendingCut {
      abandonedCut = (target, reason)
    }
    programOutput.cancelPendingCut()
    automaticRequestPending = false
  }

  mutating func expirePendingCutIfNeeded() {
    programOutput.expirePendingCutIfNeeded()
    reconcilePendingState()
  }

  private static func unique(_ ids: [FeedID]) -> [FeedID] {
    var seen = Set<FeedID>()
    return ids.filter { seen.insert($0).inserted }
  }
}

private func validSeconds(_ time: CMTime) -> TimeInterval? {
  guard time.isValid, time.isNumeric else { return nil }
  let seconds = CMTimeGetSeconds(time)
  return seconds.isFinite && seconds >= 0 ? seconds : nil
}
