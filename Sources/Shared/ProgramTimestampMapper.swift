import CoreMedia

/// A source frame presented to the Program route before it has a Program PTS.
public struct ProgramSourceFrame<SourceID: Hashable> {
  public let sourceID: SourceID
  public let sourceTime: CMTime
  public let duration: CMTime

  public init(sourceID: SourceID, sourceTime: CMTime, duration: CMTime) {
    self.sourceID = sourceID
    self.sourceTime = sourceTime
    self.duration = duration
  }
}

/// A source frame with a timestamp in the single Program timeline.
public struct ProgramMappedFrame<SourceID: Hashable> {
  public let sourceID: SourceID
  public let sourceTime: CMTime
  public let sourceDuration: CMTime
  public let programTime: CMTime
  public let programDuration: CMTime

  public init(sourceID: SourceID, sourceTime: CMTime, sourceDuration: CMTime,
              programTime: CMTime, programDuration: CMTime) {
    self.sourceID = sourceID
    self.sourceTime = sourceTime
    self.sourceDuration = sourceDuration
    self.programTime = programTime
    self.programDuration = programDuration
  }
}

public enum ProgramTimestampMappingError: Error, Equatable {
  case noSelectedSource
  case sourceMismatch
  case invalidSourceTimestamp
  case invalidSourceDuration
  case sourceEpochUnsupported(Int64)
  case sourceTimebaseChanged(expected: Int32, actual: Int32)
  case sourceTimestampRegressed
  case programTimestampNotMonotonic
}

/// Maps each selected source timeline into one monotonic Program timeline.
///
/// A cut leaves the last Program timestamp intact and starts a new source
/// origin. The first accepted frame after the cut therefore begins at the next
/// Program frame boundary even when the new source starts at zero.
public struct ProgramTimestampMapper<SourceID: Hashable> {
  private struct SourceClock {
    let epoch: Int64
    let timescale: Int32
  }

  public let programTimescale: Int32
  public private(set) var selectedSource: SourceID?
  public private(set) var lastProgramTime: CMTime?
  public private(set) var lastProgramDuration: CMTime?
  /// The selected source's last accepted timestamp, on its own clock.
  public private(set) var lastSourceTime: CMTime?

  private var activeClock: SourceClock?
  private var sourceOrigin: CMTime?
  private var programOrigin: CMTime?

  public init(programTimescale: Int32 = 60_000, selectedSource: SourceID? = nil) {
    precondition(programTimescale > 0, "Program timescale must be positive")
    self.programTimescale = programTimescale
    self.selectedSource = selectedSource
  }

  /// Starts a source or establishes a new source-to-Program mapping at a cut.
  /// Existing Program time is deliberately retained.
  public mutating func cut(to sourceID: SourceID) {
    selectedSource = sourceID
    activeClock = nil
    sourceOrigin = nil
    programOrigin = nil
    lastSourceTime = nil
  }

  /// Clears both the selected source and Program timeline.
  public mutating func reset() {
    selectedSource = nil
    lastProgramTime = nil
    lastProgramDuration = nil
    activeClock = nil
    sourceOrigin = nil
    programOrigin = nil
    lastSourceTime = nil
  }

  public mutating func map(_ frame: ProgramSourceFrame<SourceID>)
    -> Result<ProgramMappedFrame<SourceID>, ProgramTimestampMappingError> {
    guard let selectedSource else { return .failure(.noSelectedSource) }
    guard frame.sourceID == selectedSource else { return .failure(.sourceMismatch) }
    guard frame.sourceTime.isValid, frame.sourceTime.isNumeric,
      frame.sourceTime.timescale > 0, frame.sourceTime.value >= 0 else {
      return .failure(.invalidSourceTimestamp)
    }
    guard frame.duration.isValid, frame.duration.isNumeric,
      frame.duration.timescale > 0, frame.duration.epoch == 0,
      frame.duration.value > 0 else {
      return .failure(.invalidSourceDuration)
    }
    guard frame.sourceTime.epoch == 0 else {
      return .failure(.sourceEpochUnsupported(frame.sourceTime.epoch))
    }

    let clock = SourceClock(epoch: frame.sourceTime.epoch, timescale: frame.sourceTime.timescale)
    if let activeClock, activeClock.timescale != clock.timescale {
      return .failure(.sourceTimebaseChanged(expected: activeClock.timescale,
        actual: clock.timescale))
    }
    if let lastSourceTime, CMTimeCompare(frame.sourceTime, lastSourceTime) <= 0 {
      return .failure(.sourceTimestampRegressed)
    }

    // Derive a candidate mapping first and commit it only after every output
    // invariant has passed.  A malformed first frame must not establish a
    // source origin or consume a Program boundary for later frames.
    let candidateSourceOrigin = sourceOrigin ?? frame.sourceTime
    let candidateProgramOrigin = programOrigin ?? nextProgramTime()
    guard candidateSourceOrigin.isValid, candidateProgramOrigin.isValid else {
      return .failure(.programTimestampNotMonotonic)
    }

    let offset = CMTimeConvertScale(CMTimeSubtract(frame.sourceTime, candidateSourceOrigin),
      timescale: programTimescale, method: .roundHalfAwayFromZero)
    let mappedTime = CMTimeAdd(candidateProgramOrigin, offset)
    let mappedDuration = CMTimeConvertScale(frame.duration, timescale: programTimescale,
      method: .roundHalfAwayFromZero)
    guard mappedTime.isValid, mappedTime.isNumeric, mappedDuration.isValid,
      mappedDuration.isNumeric, mappedDuration.value > 0 else {
      return .failure(.programTimestampNotMonotonic)
    }
    if let lastProgramTime, CMTimeCompare(mappedTime, lastProgramTime) <= 0 {
      return .failure(.programTimestampNotMonotonic)
    }

    if activeClock == nil {
      activeClock = clock
      sourceOrigin = candidateSourceOrigin
      programOrigin = candidateProgramOrigin
    }
    lastSourceTime = frame.sourceTime
    lastProgramTime = mappedTime
    lastProgramDuration = mappedDuration
    return .success(ProgramMappedFrame(sourceID: frame.sourceID,
      sourceTime: frame.sourceTime, sourceDuration: frame.duration,
      programTime: mappedTime, programDuration: mappedDuration))
  }

  /// Keeps the Program clock across a scheduler rebuild. Source origins are
  /// not copied: the next frame establishes those against this Program time.
  public mutating func carryTimeline(from other: ProgramTimestampMapper<SourceID>) {
    guard programTimescale == other.programTimescale else { return }
    lastProgramTime = other.lastProgramTime
    lastProgramDuration = other.lastProgramDuration
  }

  private func nextProgramTime() -> CMTime {
    guard let lastProgramTime else { return .zero }
    guard let lastProgramDuration else { return lastProgramTime }
    return CMTimeAdd(lastProgramTime, lastProgramDuration)
  }
}

public enum ProgramCutRequestResult<SourceID: Hashable> {
  case queued
  case coalesced(previous: SourceID, replacement: SourceID)
  case ignoredSameSource
  case rejectedMissingSource
  /// Nothing was on air, so the selection changed at once without a cut.
  case selectedImmediately
}

public enum ProgramFrameSkipReason: Equatable {
  case missingSource
  case nonSelectedSource
  case staleQueuedFrame
  case invalidTimestamp(ProgramTimestampMappingError)
}

public enum ProgramFrameDecision<SourceID: Hashable> {
  case accepted(ProgramMappedFrame<SourceID>)
  /// The cut's first frame. Frames the old source already put on air precede
  /// it on the Program clock and are still delivered, in order.
  case cutApplied(ProgramMappedFrame<SourceID>)
  case skipped(ProgramFrameSkipReason)
}

/// Where a Program source is in its lifecycle, as far as cuts are concerned.
public enum ProgramSourceReadiness: Equatable, Sendable {
  /// Never reported. Treated as available; a pending cut to it can expire.
  case unknown
  /// Started but no frame yet ("Opening UltraStudio…"). A pending cut waits
  /// up to `startingCutTimeout` for its first frame.
  case starting
  /// Has delivered at least one frame since it last became available.
  case producing
  case unavailable
}

/// Why a pending cut was dropped without landing.
public enum ProgramCutAbandonReason: Equatable, Sendable {
  /// The target never produced a frame that qualified in time: a live target
  /// within `pendingCutTimeout`, or a starting one (opened but no signal)
  /// within `startingCutTimeout`.
  case expired
  /// The target stopped or failed to start.
  case targetUnavailable
}

/// Decides when a pending cut can land at a valid frame boundary.
///
/// The scheduler has no queue or media ownership. The on-air source keeps
/// flowing while a cut is pending; the cut lands on the target's first valid
/// frame. A target that is still starting waits for its first frame up to
/// `startingCutTimeout` (a camera that opened but has no signal never sends
/// one), or until it is marked unavailable. A live target that produces no
/// qualifying frame within `pendingCutTimeout` expires. Every dropped cut is
/// reported once through `takeAbandonedCut()`.
public struct ProgramCutScheduler<SourceID: Hashable> {
  public private(set) var selectedSource: SourceID?
  public private(set) var pendingCut: SourceID?
  public private(set) var pendingCutTime: CMTime? = nil
  public private(set) var mapper: ProgramTimestampMapper<SourceID>
  /// How long a pending cut to a live (not starting) target may wait for a
  /// qualifying frame. The on-air source is never held while it waits.
  public var pendingCutTimeout: TimeInterval = 2
  /// How long a pending cut to a starting target waits for its first frame.
  /// Opening an UltraStudio and locking to its signal takes a second or two;
  /// a camera that opened without a signal must not hold the cut (and the
  /// automatic switcher's latch) forever.
  public var startingCutTimeout: TimeInterval = 8

  private var readiness: [SourceID: ProgramSourceReadiness] = [:]
  /// Start of the expiry clock, set when the cut is requested and restarted
  /// when a starting target sends its first frame.
  private var pendingCutRequestedAt: TimeInterval?
  /// The pending target had not sent a frame yet when the clock started.
  private var pendingTargetStarting = false
  private var abandoned: (SourceID, ProgramCutAbandonReason)?
  private var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

  public mutating func setClock(_ clock: @escaping () -> TimeInterval) {
    self.clock = clock
  }

  public init(selectedSource: SourceID? = nil, programTimescale: Int32 = 60_000) {
    self.selectedSource = selectedSource
    self.mapper = ProgramTimestampMapper(programTimescale: programTimescale,
      selectedSource: selectedSource)
  }

  public var hasPendingCut: Bool { pendingCut != nil }

  /// Updates source health. An unavailable pending target is abandoned before
  /// the next frame so it cannot cause a stale or duplicate cut later.
  /// Becoming available marks a source as starting until its first frame.
  public mutating func setSource(_ sourceID: SourceID, available: Bool) {
    if available {
      if readiness[sourceID] != .producing { readiness[sourceID] = .starting }
    } else {
      readiness[sourceID] = .unavailable
      if pendingCut == sourceID { abandonPendingCut(.targetUnavailable) }
    }
  }

  public func readiness(of sourceID: SourceID) -> ProgramSourceReadiness {
    readiness[sourceID] ?? .unknown
  }

  public func isSourceAvailable(_ sourceID: SourceID) -> Bool {
    readiness[sourceID] != .unavailable
  }

  /// True when the selected source has delivered a frame since it became
  /// available: something is actually on air.
  public var isOnAir: Bool {
    guard let selectedSource else { return false }
    return readiness[selectedSource] == .producing
  }

  /// Producing sources go back to starting, e.g. when Program mode is left and
  /// re-entered: nothing is on air until the next frame arrives.
  public mutating func markSourcesIdle() {
    for (id, state) in readiness where state == .producing { readiness[id] = .starting }
  }

  /// Returns, once, the cut most recently dropped without landing.
  public mutating func takeAbandonedCut() -> (SourceID, ProgramCutAbandonReason)? {
    defer { abandoned = nil }
    return abandoned
  }

  /// Changes the selection without a cut. Only valid while nothing is on air.
  public mutating func select(_ sourceID: SourceID) {
    clearPendingCut()
    selectedSource = sourceID
    mapper.cut(to: sourceID)
  }

  /// `noEarlierThan` is on the target's own stream clock (its video PTS):
  /// the cut lands on the first target frame at or after it. Another clock,
  /// such as the director's audio time, never qualifies; pass nil instead, as
  /// the live automatic director does.
  public mutating func requestCut(to sourceID: SourceID,
                                 noEarlierThan: CMTime? = nil) -> ProgramCutRequestResult<SourceID> {
    let noEarlierThan = noEarlierThan.flatMap(Self.validCutTime)
    guard isSourceAvailable(sourceID) else { return .rejectedMissingSource }
    if sourceID == selectedSource {
      // A rapid A → B → A request resolves to the already selected source;
      // discard the pending B cut instead of emitting a duplicate A cut.
      clearPendingCut()
      return .ignoredSameSource
    }
    if let pendingCut {
      if pendingCut == sourceID {
        if let noEarlierThan {
          // Coalescing may only move a cut later. A newer decision must not
          // weaken the safety bound established by an earlier one.
          if let existing = pendingCutTime {
            pendingCutTime = CMTimeCompare(noEarlierThan, existing) > 0
              ? noEarlierThan : existing
          } else {
            pendingCutTime = noEarlierThan
          }
        }
        // There is already a cut waiting for this target. Treat a new
        // decision as a coalesced request so the caller can replace the
        // decision ID it will acknowledge when the frame lands. Returning
        // ignoredSameSource here loses that acknowledgement and leaves the
        // director and Program route out of sync.
        return .coalesced(previous: pendingCut, replacement: sourceID)
      }
      notePendingTarget(sourceID)
      self.pendingCut = sourceID
      self.pendingCutTime = noEarlierThan
      return .coalesced(previous: pendingCut, replacement: sourceID)
    }
    notePendingTarget(sourceID)
    pendingCut = sourceID
    pendingCutTime = noEarlierThan
    return .queued
  }

  public mutating func cancelPendingCut() {
    clearPendingCut()
  }

  /// Carries the Program clock, source readiness and a pending cut onto a
  /// scheduler rebuilt for a feed add, remove or disable, so the on-air source
  /// stays on air and a requested cut still lands (or is reported). A pending
  /// cut whose target is gone, unavailable or now selected is abandoned.
  public mutating func carryTimeline(from other: ProgramCutScheduler<SourceID>,
                                     keeping sources: Set<SourceID>? = nil) {
    mapper.carryTimeline(from: other.mapper)
    clock = other.clock
    pendingCutTimeout = other.pendingCutTimeout
    startingCutTimeout = other.startingCutTimeout
    for (id, state) in other.readiness where sources?.contains(id) ?? true {
      readiness[id] = state
    }
    guard let target = other.pendingCut else { return }
    guard sources?.contains(target) ?? true, target != selectedSource,
      isSourceAvailable(target) else {
      abandoned = (target, .targetUnavailable)
      return
    }
    pendingCut = target
    pendingCutTime = other.pendingCutTime
    pendingCutRequestedAt = other.pendingCutRequestedAt
    pendingTargetStarting = other.pendingTargetStarting
  }

  /// Expires a pending cut whose live target has not qualified in time.
  /// Called on every frame and by the switcher's evaluation tick, so a cut
  /// expires even when no frame arrives.
  @discardableResult
  public mutating func expirePendingCutIfNeeded() -> Bool {
    let timeout = pendingTargetStarting ? startingCutTimeout : pendingCutTimeout
    guard pendingCut != nil, let pendingCutRequestedAt,
      clock() - pendingCutRequestedAt >= timeout else { return false }
    abandonPendingCut(.expired)
    return true
  }

  private mutating func notePendingTarget(_ sourceID: SourceID) {
    guard pendingCut != sourceID else { return }
    // A starting target gets the longer bound until its first frame.
    pendingCutRequestedAt = clock()
    pendingTargetStarting = readiness(of: sourceID) == .starting
  }

  private mutating func clearPendingCut() {
    pendingCut = nil
    pendingCutTime = nil
    pendingCutRequestedAt = nil
    pendingTargetStarting = false
  }

  private mutating func abandonPendingCut(_ reason: ProgramCutAbandonReason) {
    guard let pendingCut else { return }
    abandoned = (pendingCut, reason)
    clearPendingCut()
  }

  private static func validCutTime(_ time: CMTime) -> CMTime? {
    guard time.isValid, time.isNumeric, time.epoch == 0,
      time.timescale > 0, time.value >= 0 else { return nil }
    return time
  }

  private static func comparableSourceTime(_ time: CMTime) -> Bool {
    // A negative source timestamp is invalid even when it would sort before
    // an earliest-cut boundary. Let the mapper report the real timestamp
    // error instead of classifying malformed media as stale queue data.
    time.isValid && time.isNumeric && time.timescale > 0 && time.epoch == 0 &&
      time.value >= 0
  }

  public mutating func ingest(_ frame: ProgramSourceFrame<SourceID>)
    -> ProgramFrameDecision<SourceID> {
    if let pendingCut, !isSourceAvailable(pendingCut) {
      abandonPendingCut(.targetUnavailable)
    }
    expirePendingCutIfNeeded()
    guard isSourceAvailable(frame.sourceID) else { return .skipped(.missingSource) }
    if readiness[frame.sourceID] != .producing {
      readiness[frame.sourceID] = .producing
      // The target's first frame restarts its expiry clock: from here on it
      // is live and only needs a frame that qualifies.
      if pendingCut == frame.sourceID, pendingTargetStarting {
        pendingCutRequestedAt = clock()
        pendingTargetStarting = false
      }
      // The selected source (re)started, e.g. stopped and started again: its
      // clock starts over. Re-anchor it at the next Program boundary instead
      // of rejecting every new frame as a timestamp regression.
      if frame.sourceID == selectedSource, pendingCut != frame.sourceID {
        mapper.cut(to: frame.sourceID)
      }
    }

    if let pendingCut, frame.sourceID == pendingCut {
      if let pendingCutTime {
        guard Self.comparableSourceTime(frame.sourceTime) else {
          // Preserve the mapper's more specific epoch diagnostic even
          // though this fast path runs before the trial mapping.
          if frame.sourceTime.isValid, frame.sourceTime.isNumeric,
            frame.sourceTime.timescale > 0, frame.sourceTime.value >= 0,
            frame.sourceTime.epoch != 0 {
            return .skipped(.invalidTimestamp(
              .sourceEpochUnsupported(frame.sourceTime.epoch)))
          }
          return .skipped(.invalidTimestamp(.invalidSourceTimestamp))
        }
        // Same clock by contract: `pendingCutTime` is a target stream time.
        if CMTimeCompare(frame.sourceTime, pendingCutTime) < 0 {
          return .skipped(.staleQueuedFrame)
        }
      }
      // Trial the new source on a value copy. Invalid target frames are
      // skipped while the old selection and pending cut remain intact.
      var candidateMapper = mapper
      candidateMapper.cut(to: pendingCut)
      switch candidateMapper.map(frame) {
      case let .success(mapped):
        mapper = candidateMapper
        selectedSource = pendingCut
        clearPendingCut()
        return .cutApplied(mapped)
      case let .failure(error):
        return .skipped(.invalidTimestamp(error))
      }
    }

    // The on-air source keeps flowing while a cut is pending, so Program
    // never freezes waiting for a target that is still opening.
    guard frame.sourceID == selectedSource else { return .skipped(.nonSelectedSource) }
    let result = mapper.map(frame)
    if case .failure(.sourceTimestampRegressed) = result, let last = mapper.lastSourceTime,
      CMTimeCompare(frame.sourceTime, last) < 0 {
      // The on-air source's stream clock started over while it stayed live:
      // an HDMI mode change restarts the DeckLink streams, and stream time
      // goes back near zero. Re-anchor on this frame at the next Program
      // boundary, as a cut does, so Program stays strictly increasing. An
      // equal timestamp is a duplicate frame, not a restart, and stays skipped.
      var restarted = mapper
      restarted.cut(to: frame.sourceID)
      switch restarted.map(frame) {
      case let .success(mapped):
        mapper = restarted
        return .accepted(mapped)
      case let .failure(error): return .skipped(.invalidTimestamp(error))
      }
    }
    switch result {
    case let .success(mapped): return .accepted(mapped)
    case let .failure(error): return .skipped(.invalidTimestamp(error))
    }
  }
}
