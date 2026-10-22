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

  private var activeClock: SourceClock?
  private var sourceOrigin: CMTime?
  private var programOrigin: CMTime?
  private var lastSourceTime: CMTime?

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
}

public enum ProgramFrameSkipReason: Equatable {
  case missingSource
  case nonSelectedSource
  case staleQueuedFrame
  case invalidTimestamp(ProgramTimestampMappingError)
}

public enum ProgramFrameDecision<SourceID: Hashable> {
  case accepted(ProgramMappedFrame<SourceID>)
  case cutApplied(ProgramMappedFrame<SourceID>, flushStaleFrames: Bool)
  case skipped(ProgramFrameSkipReason)
}

/// Decides when a pending cut can land at a valid frame boundary.
///
/// The scheduler has no queue or media ownership. It reports when queued
/// frames must be flushed; the route that owns the queue performs that flush.
public struct ProgramCutScheduler<SourceID: Hashable> {
  public private(set) var selectedSource: SourceID?
  public private(set) var pendingCut: SourceID?
  public private(set) var pendingCutTime: CMTime? = nil
  public private(set) var mapper: ProgramTimestampMapper<SourceID>
  /// How long the on-air source stays held while a pending target produces
  /// no valid frame. The skip itself stays in place until this elapses.
  public var pendingCutTimeout: TimeInterval = 2

  private var availability: [SourceID: Bool] = [:]
  private var pendingCutRequestedAt: TimeInterval?
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

  /// Updates source health. An unavailable pending target is discarded before
  /// the next frame so it cannot cause a stale or duplicate cut later.
  public mutating func setSource(_ sourceID: SourceID, available: Bool) {
    availability[sourceID] = available
    if !available, pendingCut == sourceID {
      clearPendingCut()
    }
  }

  public func isSourceAvailable(_ sourceID: SourceID) -> Bool {
    availability[sourceID] ?? true
  }

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

  public mutating func carryTimeline(from other: ProgramCutScheduler<SourceID>) {
    mapper.carryTimeline(from: other.mapper)
  }

  private mutating func notePendingTarget(_ sourceID: SourceID) {
    if pendingCut != sourceID { pendingCutRequestedAt = clock() }
  }

  private mutating func clearPendingCut() {
    pendingCut = nil
    pendingCutTime = nil
    pendingCutRequestedAt = nil
  }

  private func pendingCutHasExpired() -> Bool {
    guard let pendingCutRequestedAt else { return false }
    return clock() - pendingCutRequestedAt >= pendingCutTimeout
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
      clearPendingCut()
    }
    guard isSourceAvailable(frame.sourceID) else { return .skipped(.missingSource) }

    if let pendingCut {
      if frame.sourceID == pendingCut {
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
          return .cutApplied(mapped, flushStaleFrames: true)
        case let .failure(error):
          return .skipped(.invalidTimestamp(error))
        }
      }
      if frame.sourceID == selectedSource {
        // Hold A until B qualifies. If B never does, resume A instead of
        // leaving the meeting on the last Program frame forever.
        guard pendingCutHasExpired() else { return .skipped(.staleQueuedFrame) }
        clearPendingCut()
      } else {
        return .skipped(.nonSelectedSource)
      }
    }

    guard frame.sourceID == selectedSource else { return .skipped(.nonSelectedSource) }
    switch mapper.map(frame) {
    case let .success(mapped): return .accepted(mapped)
    case let .failure(error): return .skipped(.invalidTimestamp(error))
    }
  }
}
