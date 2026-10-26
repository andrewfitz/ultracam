import CoreMedia
import Foundation

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

  init(selectedSource: SourceID? = nil, programTimescale: Int32 = 60_000) {
    scheduler = ProgramCutScheduler(selectedSource: selectedSource,
      programTimescale: programTimescale)
  }

  init(selectedFeedID: SourceID?, programTimescale: Int32 = 60_000) {
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

  mutating func markSourcesIdle() { scheduler.markSourcesIdle() }

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
  private(set) var selectedFeedID: FeedID?
  private(set) var programOutput: ProgramOutput<FeedID>

  private var director: NaturalTalkingHeadDirector
  private var pendingDirectorDecision: CutDecision?
  private var fixedIntervalOrigin: TimeInterval?
  private var automaticRequestPending = false
  private var anchorFeedID: FeedID?
  private var emphasisFeedID: FeedID?
  /// The most recent cut dropped without landing, kept until the route
  /// reports it. The scheduler reports each one once.
  private var abandonedCut: (FeedID, ProgramCutAbandonReason)?

  init(settings: SwitcherSettings = .init(), feedIDs: [FeedID] = [],
    anchorFeedID: FeedID? = nil, emphasisFeedID: FeedID? = nil,
    directorSettings: NaturalTalkingHeadDirectorSettings = .init()) {
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
    self.director = NaturalTalkingHeadDirector(settings: directorSettings)
    self.anchorFeedID = anchorFeedID ?? settings.naturalTalkingHead.anchorFeedID
      ?? self.feedIDs.first
    self.emphasisFeedID = emphasisFeedID ?? settings.naturalTalkingHead.emphasisFeedID
      ?? self.feedIDs.dropFirst().first
  }

  init(settings: SwitcherSettings = .init(), feeds: [FeedDescriptor],
    anchorFeedID: FeedID? = nil, emphasisFeedID: FeedID? = nil,
    directorSettings: NaturalTalkingHeadDirectorSettings = .init()) {
    self.init(settings: settings,
      feedIDs: feeds.filter(\.enabled).map(\.id), anchorFeedID: anchorFeedID,
      emphasisFeedID: emphasisFeedID, directorSettings: directorSettings)
  }

  /// The UI can use this message without presenting dynamic analysis as an
  /// active mode. The strategy remains persisted for a future implementation.
  var statusMessage: String {
    settings.strategy == .dynamicAnalysis ? "Coming later." : "Ready"
  }

  var anchorID: FeedID? { anchorFeedID }
  var emphasisID: FeedID? { emphasisFeedID }

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

  /// Keeps the automatic latch and the director decision in step with the
  /// scheduler. Any pending cut that disappears without landing (expiry,
  /// health, cancel) must release `automaticRequestPending`; otherwise the
  /// fixed-interval policy stays idle forever (PROG-2).
  private mutating func reconcilePendingState() {
    if let (target, reason) = programOutput.takeAbandonedCut() {
      abandonedCut = (target, reason)
      if pendingDirectorDecision?.targetCameraID == target.rawValue {
        pendingDirectorDecision = nil
      }
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
    pendingDirectorDecision = nil
    return .selectedImmediately
  }

  /// Producing sources return to starting; nothing is on air until a frame.
  mutating func markSourcesIdle() { programOutput.markSourcesIdle() }

  mutating func setFeedHealth(_ feedID: FeedID, healthy: Bool) {
    guard feedIDs.contains(feedID) else { return }
    feedHealth[feedID] = healthy
    programOutput.setSourceHealth(feedID, healthy: healthy)
    // Health can drop the pending cut inside the scheduler. The automatic
    // latch has to drop with it, or later ticks stay idle forever.
    reconcilePendingState()
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
    if let target = programOutput.pendingCut {
      automaticRequestPending = previous.automaticRequestPending
      if previous.pendingDirectorDecision?.targetCameraID == target.rawValue {
        pendingDirectorDecision = previous.pendingDirectorDecision
      }
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
      anchorFeedID = settings.naturalTalkingHead.anchorFeedID
        .flatMap { feedIDs.contains($0) ? $0 : nil } ?? feedIDs.first
      emphasisFeedID = settings.naturalTalkingHead.emphasisFeedID
        .flatMap { feedIDs.contains($0) ? $0 : nil } ?? feedIDs.dropFirst().first
      director.reset()
      pendingDirectorDecision = nil
      programOutput.cancelPendingCut()
    }
    fixedIntervalOrigin = nil
    automaticRequestPending = false
    reconcilePendingState()
  }

  func isFeedHealthy(_ feedID: FeedID) -> Bool {
    feedHealth[feedID] ?? false
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
    let result = requestManualCut(to: feedID, at: time)
    if case .queued = result {
      director.manualOverride(cameraID: feedID.rawValue, at: time)
    } else if case .coalesced = result {
      director.manualOverride(cameraID: feedID.rawValue, at: time)
    }
    return result
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
    guard !automaticRequestPending, !programOutput.hasPendingCut else { return .idle }

    if fixedIntervalOrigin == nil {
      fixedIntervalOrigin = now
      return .idle
    }
    let interval = max(settings.intervalSeconds.isFinite ? settings.intervalSeconds : 0, 0.001)
    guard now - (fixedIntervalOrigin ?? now) >= interval else { return .idle }

    guard let target = nextHealthyFeed(after: selectedFeedID) else {
      fixedIntervalOrigin = now
      return .noHealthyFeed
    }
    let result = programOutput.requestCut(to: target)
    fixedIntervalOrigin = now
    guard case .queued = result else { return .idle }
    automaticRequestPending = true
    return .cutQueued(target)
  }

  mutating func evaluate(at seconds: TimeInterval) -> SwitcherEvaluation {
    evaluate(at: CMTime(seconds: seconds, preferredTimescale: 1_000))
  }

  mutating func evaluate(at mediaTime: CMTime, audioCues: [AudioCue],
    transcriptCues: [TranscriptCue]) -> SwitcherEvaluation {
    _ = audioCues
    _ = transcriptCues
    return evaluate(at: mediaTime)
  }

  /// Evaluate the natural director with the coordinator's feed IDs and health
  /// map. Dynamic analysis remains an explicit disabled strategy; this method
  /// is for callers that opt into the already implemented director directly.
  mutating func evaluateDirector(at mediaTime: CMTime, currentFeedID: FeedID,
    audioCues: [AudioCue] = [], transcriptCues: [TranscriptCue] = [])
    -> SwitcherEvaluation {
    guard settings.strategy != .dynamicAnalysis else {
      return .dynamicAnalysisUnavailable
    }
    guard let anchorFeedID, let emphasisFeedID else { return .idle }
    let input = NaturalTalkingHeadDirectorInput(mediaTime: mediaTime,
      currentCameraID: currentFeedID.rawValue, anchorCameraID: anchorFeedID.rawValue,
      emphasisCameraID: emphasisFeedID.rawValue,
      cameraHealth: Dictionary(uniqueKeysWithValues: feedHealth.map { ($0.key.rawValue, $0.value) }),
      audioCues: audioCues, transcriptCues: transcriptCues)
    guard let decision = evaluateDirector(input) else { return .idle }
    return .cutQueued(FeedID(rawValue: decision.targetCameraID))
  }

  mutating func evaluate(at mediaTime: CMTime, currentFeedID: FeedID,
    audioCues: [AudioCue] = [], transcriptCues: [TranscriptCue] = [])
    -> SwitcherEvaluation {
    evaluateDirector(at: mediaTime, currentFeedID: currentFeedID,
      audioCues: audioCues, transcriptCues: transcriptCues)
  }

  mutating func tick(at mediaTime: CMTime) -> SwitcherEvaluation {
    evaluate(at: mediaTime)
  }

  mutating func tick(at seconds: TimeInterval) -> SwitcherEvaluation {
    evaluate(at: seconds)
  }

  /// Runs the existing natural director when an integration explicitly opts
  /// into it. Persisted dynamicAnalysis still reports its disabled stub above.
  mutating func evaluateDirector(_ input: NaturalTalkingHeadDirectorInput)
    -> CutDecision? {
    guard settings.strategy != .dynamicAnalysis else { return nil }
    guard let decision = director.evaluate(input) else { return nil }
    let target = FeedID(rawValue: decision.targetCameraID)
    guard feedIDs.contains(target), isFeedHealthy(target) else { return nil }
    // Test-only path: `cutTime` is the director's clock, and the scheduler
    // compares the bound with the target's own video PTS. It is a valid bound
    // only when the two share one clock, as in these checks. The live director
    // (AutoSwitcherBridge via AppModel) requests its cuts with no bound.
    let result = programOutput.requestCut(to: target, noEarlierThan: decision.cutTime)
    switch result {
    case .queued, .coalesced:
      pendingDirectorDecision = decision
      return decision
    case .ignoredSameSource, .rejectedMissingSource, .selectedImmediately:
      return nil
    }
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

  /// Acknowledges the natural director's exact decision after the output route
  /// applies it. Replaying the same decision returns false.
  @discardableResult
  mutating func acknowledgeCut(_ decision: CutDecision, appliedAt: CMTime? = nil) -> Bool {
    guard pendingDirectorDecision == decision else { return false }
    guard director.acknowledgeOutput(decision, appliedAt: appliedAt) else { return false }
    pendingDirectorDecision = nil
    let target = FeedID(rawValue: decision.targetCameraID)
    if programOutput.selectedSource == target {
      selectedFeedID = target
      settings.selectedFeedID = target
    }
    automaticRequestPending = false
    return true
  }

  @discardableResult
  mutating func acknowledgeOutput(_ decision: CutDecision, appliedAt: CMTime? = nil) -> Bool {
    acknowledgeCut(decision, appliedAt: appliedAt)
  }

  @discardableResult
  mutating func acknowledge(_ decision: CutDecision, appliedAt: CMTime? = nil) -> Bool {
    acknowledgeCut(decision, appliedAt: appliedAt)
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
    selectedFeedID = feedID
    settings.selectedFeedID = feedID
    automaticRequestPending = false
    if pendingDirectorDecision?.targetCameraID == feedID.rawValue {
      pendingDirectorDecision = nil
    }
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
    director.reset()
    pendingDirectorDecision = nil
    fixedIntervalOrigin = nil
    automaticRequestPending = false
  }

  mutating func cancelPendingCut() {
    programOutput.cancelPendingCut()
    pendingDirectorDecision = nil
    automaticRequestPending = false
  }

  mutating func expirePendingCutIfNeeded() {
    programOutput.expirePendingCutIfNeeded()
    reconcilePendingState()
  }

  private func nextHealthyFeed(after feedID: FeedID?) -> FeedID? {
    guard !feedIDs.isEmpty else { return nil }
    let start = feedID.flatMap { feedIDs.firstIndex(of: $0) } ?? -1
    for offset in 1...feedIDs.count {
      let candidate = feedIDs[(start + offset) % feedIDs.count]
      if candidate != feedID, isFeedHealthy(candidate) { return candidate }
    }
    return nil
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
