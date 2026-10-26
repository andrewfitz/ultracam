import CoreMedia
import Foundation

typealias CameraID = String

enum CueKind: String, Equatable {
  case phraseEnd
  case sentenceEnd
  case question
  case transition
}

struct AudioCue {
  let time: CMTime
  let speechEnergy: Float
  let pauseDuration: TimeInterval
  let emphasis: Float
  let laughter: Float
}

struct TranscriptCue {
  let timeRange: CMTimeRange
  let kind: CueKind
  let confidence: Float
  let isFinal: Bool
}

struct CutDecision: Equatable {
  let targetCameraID: CameraID
  let cutTime: CMTime
  let confidence: Float
  let reason: String
}

enum TalkingHeadDirectorMode: String, Codable, Equatable, Sendable {
  case lowLatency
  case transcriptAssisted
}

struct NaturalTalkingHeadDirectorSettings: Equatable {
  var minimumShotDuration: TimeInterval = 10
  var cooldown: TimeInterval = 1.5
  var emphasisHold: TimeInterval = 5
  var softMaximumShotDuration: TimeInterval = 20
  var boundaryWindow: TimeInterval = 0.24
  var candidateDwell: TimeInterval = 0.3
  var transcriptConfidenceThreshold: Float = 0.72
  var pauseBoundaryDuration: TimeInterval = 0.22
  var cutThreshold: Float = 0.68
  var hysteresisMargin: Float = 0.12
  var mode: TalkingHeadDirectorMode = .transcriptAssisted

  init() {}
}

struct NaturalTalkingHeadDirectorInput {
  let mediaTime: CMTime
  let currentCameraID: CameraID
  let anchorCameraID: CameraID
  let emphasisCameraID: CameraID
  let cameraHealth: [CameraID: Bool]
  let audioCues: [AudioCue]
  let transcriptCues: [TranscriptCue]

  init(mediaTime: CMTime, currentCameraID: CameraID, anchorCameraID: CameraID,
    emphasisCameraID: CameraID, cameraHealth: [CameraID: Bool] = [:],
    audioCues: [AudioCue] = [], transcriptCues: [TranscriptCue] = []) {
    self.mediaTime = mediaTime
    self.currentCameraID = currentCameraID
    self.anchorCameraID = anchorCameraID
    self.emphasisCameraID = emphasisCameraID
    self.cameraHealth = cameraHealth
    self.audioCues = audioCues
    self.transcriptCues = transcriptCues
  }
}

/// A queue-confined, deterministic director. It only selects camera IDs and
/// timestamps; it never owns or touches media buffers, rendering, or outputs.
struct NaturalTalkingHeadDirector {
  enum State: Equatable {
    case holdCurrent
    case candidateCut
    case waitForSafeBoundary
    case cut
    case holdNewShot
    case candidateReturn
    case holdAnchor
  }

  private struct TimestampKey: Hashable {
    let value: Int64
    let timescale: Int32
    let epoch: Int64
  }

  private struct TranscriptKey: Hashable {
    let kind: CueKind
    let start: TimestampKey
  }

  private struct Boundary {
    let time: CMTime
    let confidence: Float
    let label: String
    let key: TranscriptKey?
    let isPause: Bool
  }

  private struct Candidate {
    let targetCameraID: CameraID
    let startedAt: TimeInterval
    var score: Float
    var boundary: Boundary
    var returnToAnchor: Bool
  }

  private struct CommittedBoundary {
    let kind: CueKind
    let seconds: TimeInterval
  }

  let settings: NaturalTalkingHeadDirectorSettings
  private(set) var state: State = .holdCurrent
  private(set) var lastDecision: CutDecision?

  private var lastMediaTime: TimeInterval?
  private var shotStartedAt: TimeInterval?
  private var trackedCameraID: CameraID?
  private var anchorCameraID: CameraID?
  private var lastEmittedCutTime: CMTime = .invalid
  private var pendingOutput: CutDecision?
  private var candidate: Candidate?
  private var audioByTime: [TimestampKey: AudioCue] = [:]
  private var transcriptByStart: [TranscriptKey: TranscriptCue] = [:]
  private var committedBoundaries: Set<TranscriptKey> = []
  private var committedBoundaryTimes: [CommittedBoundary] = []

  init(settings: NaturalTalkingHeadDirectorSettings = .init()) {
    self.settings = settings
  }

  mutating func reset() {
    state = .holdCurrent
    lastDecision = nil
    lastMediaTime = nil
    shotStartedAt = nil
    trackedCameraID = nil
    anchorCameraID = nil
    lastEmittedCutTime = .invalid
    pendingOutput = nil
    candidate = nil
    audioByTime.removeAll(keepingCapacity: true)
    transcriptByStart.removeAll(keepingCapacity: true)
    committedBoundaries.removeAll(keepingCapacity: true)
    committedBoundaryTimes.removeAll(keepingCapacity: true)
  }

  /// Manual changes are explicit output acknowledgements and clear volatile
  /// candidates so a stale transcript cannot immediately reverse the change.
  mutating func manualOverride(cameraID: CameraID, at time: CMTime) {
    guard let seconds = validSeconds(time) else {
      reset()
      return
    }
    trackedCameraID = cameraID
    shotStartedAt = seconds
    lastMediaTime = seconds
    // A manual override is an output event too: prevent an automatic reversal
    // during the configured cooldown, while retaining the prior monotonic cut
    // timestamp when the override clock is older.
    if !lastEmittedCutTime.isValid || CMTimeCompare(time, lastEmittedCutTime) > 0 {
      lastEmittedCutTime = time
    }
    candidate = nil
    pendingOutput = nil
    state = cameraID == anchorCameraID ? .holdAnchor : .holdNewShot
  }

  /// Confirm that the output coordinator applied the exact decision emitted by
  /// `evaluate`. A decision is never emitted twice while awaiting this ack.
  @discardableResult
  mutating func acknowledgeOutput(_ decision: CutDecision, appliedAt: CMTime? = nil) -> Bool {
    guard let pendingOutput, pendingOutput == decision else { return false }
    self.pendingOutput = nil
    trackedCameraID = decision.targetCameraID
    let appliedSeconds = max(validSeconds(decision.cutTime) ?? 0,
      appliedAt.flatMap(validSeconds) ?? validSeconds(decision.cutTime) ?? 0)
    shotStartedAt = appliedSeconds
    lastMediaTime = max(lastMediaTime ?? appliedSeconds, appliedSeconds)
    state = decision.targetCameraID == anchorCameraID ? .holdAnchor : .holdNewShot
    return true
  }

  /// Short alias for callers that use the output-coordinator vocabulary.
  @discardableResult
  mutating func acknowledge(_ decision: CutDecision, appliedAt: CMTime? = nil) -> Bool {
    acknowledgeOutput(decision, appliedAt: appliedAt)
  }

  /// Ingest cues and evaluate one media-clock position. Repeated or revised
  /// transcript updates for the same start/kind replace the volatile cue.
  mutating func evaluate(_ input: NaturalTalkingHeadDirectorInput) -> CutDecision? {
    guard let now = validSeconds(input.mediaTime) else { return nil }
    guard !input.currentCameraID.isEmpty, !input.anchorCameraID.isEmpty,
      !input.emphasisCameraID.isEmpty else { return nil }
    anchorCameraID = input.anchorCameraID

    if let previous = lastMediaTime, now + 0.000_001 < previous {
      // A source-clock discontinuity invalidates all candidate timing. Do not
      // manufacture a cut at the reset point; wait for a fresh safe cue. The
      // transcript/audio stores and boundary tombstones belong to the prior
      // timeline too: retaining them would suppress a legitimate cue when a
      // new session reuses timestamps from zero.
      candidate = nil
      pendingOutput = nil
      lastEmittedCutTime = .invalid
      audioByTime.removeAll(keepingCapacity: true)
      transcriptByStart.removeAll(keepingCapacity: true)
      committedBoundaries.removeAll(keepingCapacity: true)
      committedBoundaryTimes.removeAll(keepingCapacity: true)
      trackedCameraID = input.anchorCameraID
      shotStartedAt = now
      state = .holdAnchor
    }
    lastMediaTime = now

    if trackedCameraID != input.currentCameraID {
      trackedCameraID = input.currentCameraID
      shotStartedAt = now
      candidate = nil
      if pendingOutput == nil { state = input.currentCameraID == input.anchorCameraID ? .holdAnchor : .holdNewShot }
    }
    if shotStartedAt == nil { shotStartedAt = now }

    ingest(audio: input.audioCues)
    ingest(transcript: input.transcriptCues)
    prune(now: now)
    guard pendingOutput == nil else { return nil }

    let current = input.currentCameraID
    let anchorHealthy = input.cameraHealth[input.anchorCameraID] ?? true
    let emphasisHealthy = input.cameraHealth[input.emphasisCameraID] ?? true
    let holdDuration = max(0, now - (shotStartedAt ?? now))
    let cooldownReady: Bool = {
      guard let last = validSeconds(lastEmittedCutTime) else { return true }
      return now - last >= settings.cooldown
    }()
    let minimumHoldReady = holdDuration >= settings.minimumShotDuration
    guard cooldownReady, minimumHoldReady else {
      candidate = nil
      state = current == input.anchorCameraID ? .holdAnchor : .holdNewShot
      return nil
    }

    let audio = latestAudio(near: now)
    // Keep the edit window attached to a live candidate for the dwell period;
    // callers commonly evaluate again after the boundary has left the small
    // look-around window.
    let boundary = nearestBoundary(near: now) ?? candidate?.boundary
    guard let audio else {
      // Audio is the primary timing stream. Without it we hold the safe shot;
      // transcript-only edits would otherwise cut mid-word after an outage.
      candidate = nil
      state = .holdAnchor
      return nil
    }

    if current == input.anchorCameraID {
      guard emphasisHealthy, input.emphasisCameraID != current,
        let boundary, audio.emphasisScore >= 0.55 else {
        candidate = nil
        state = .holdAnchor
        return nil
      }
      let score = cutScore(audio: audio, boundary: boundary, holdDuration: holdDuration)
      guard score >= settings.cutThreshold,
        score - currentShotScore(audio: audio) >= settings.hysteresisMargin else {
        candidate = nil
        state = boundary.key == nil ? .holdAnchor : .waitForSafeBoundary
        return nil
      }
      return considerCandidate(target: input.emphasisCameraID, score: score,
        boundary: boundary, now: now, returnToAnchor: false)
    }

    guard current == input.emphasisCameraID, anchorHealthy,
      input.anchorCameraID != current else {
      candidate = nil
      state = .holdNewShot
      return nil
    }
    guard holdDuration >= settings.emphasisHold,
      let boundary, resolved(boundary: boundary, audio: audio) else {
      candidate = nil
      state = .holdNewShot
      return nil
    }
    let settleScore = returnScore(audio: audio, boundary: boundary)
    guard settleScore >= settings.cutThreshold - 0.08 else {
      candidate = nil
      state = .holdNewShot
      return nil
    }
    return considerCandidate(target: input.anchorCameraID, score: settleScore,
      boundary: boundary, now: now, returnToAnchor: true)
  }

  private mutating func ingest(audio cues: [AudioCue]) {
    for cue in cues {
      guard let key = timestampKey(cue.time), validSeconds(cue.time) != nil,
        cue.speechEnergy.isFinite, cue.pauseDuration.isFinite,
        cue.emphasis.isFinite, cue.laughter.isFinite else { continue }
      audioByTime[key] = cue
    }
  }

  private mutating func ingest(transcript cues: [TranscriptCue]) {
    for cue in cues {
      guard cue.timeRange.isValid, let start = timestampKey(cue.timeRange.start),
        let startSeconds = validSeconds(cue.timeRange.start),
        let endSeconds = validSeconds(cue.timeRange.end), endSeconds >= startSeconds,
        cue.confidence.isFinite else { continue }
      let key = TranscriptKey(kind: cue.kind, start: start)
      if let existing = transcriptByStart[key], existing.isFinal && !cue.isFinal { continue }
      transcriptByStart[key] = cue
    }
  }

  private func latestAudio(near now: TimeInterval) -> (emphasisScore: Float, pause: TimeInterval)? {
    let candidates = audioByTime.values.filter {
      guard let seconds = validSeconds($0.time) else { return false }
      return seconds <= now + settings.boundaryWindow && now - seconds <= 1.2
    }
    guard let cue = candidates.max(by: { ($0.time.seconds) < ($1.time.seconds) }) else { return nil }
    let score = clamp(max(cue.emphasis, cue.speechEnergy * 0.65) + cue.laughter * 0.08)
    return (score, max(0, cue.pauseDuration))
  }

  private func nearestBoundary(near now: TimeInterval) -> Boundary? {
    let upper = settings.mode == .transcriptAssisted ? settings.boundaryWindow : 0
    let transcript = transcriptByStart.compactMap { key, cue -> Boundary? in
      guard cue.confidence >= settings.transcriptConfidenceThreshold,
        settings.mode == .lowLatency ? cue.isFinal : (cue.isFinal || cue.confidence >= 0.9),
        let end = validSeconds(cue.timeRange.end), abs(end - now) <= settings.boundaryWindow,
        end <= now + upper,
        !committedBoundaries.contains(key),
        !committedBoundaryTimes.contains(where: {
          $0.kind == cue.kind && abs($0.seconds - end) <= max(settings.boundaryWindow, 0.5)
        }) else { return nil }
      let label: String
      switch cue.kind {
      case .sentenceEnd: label = "sentence boundary"
      case .question: label = "question boundary"
      case .transition: label = "transition boundary"
      case .phraseEnd: label = "phrase boundary"
      }
      return Boundary(time: cue.timeRange.end, confidence: clamp(cue.confidence), label: label,
        key: key, isPause: false)
    }
    let bestTranscript = transcript.min(by: { distance($0.time, now) < distance($1.time, now) })

    let pause = audioByTime.values.compactMap { cue -> Boundary? in
      guard cue.pauseDuration >= settings.pauseBoundaryDuration,
        let seconds = validSeconds(cue.time), abs(seconds - now) <= settings.boundaryWindow,
        seconds <= now + upper else { return nil }
      return Boundary(time: cue.time, confidence: clamp(Float(cue.pauseDuration / 0.5)),
        label: "breath or pause", key: nil, isPause: true)
    }.min(by: { distance($0.time, now) < distance($1.time, now) })
    if let bestTranscript, let pause { return bestTranscript.confidence >= pause.confidence ? bestTranscript : pause }
    return bestTranscript ?? pause
  }

  private mutating func considerCandidate(target: CameraID, score: Float, boundary: Boundary,
    now: TimeInterval, returnToAnchor: Bool) -> CutDecision? {
    if let existing = candidate, existing.targetCameraID == target,
      existing.returnToAnchor == returnToAnchor,
      existing.boundary.key == boundary.key || (existing.boundary.key == nil && boundary.key == nil) {
      candidate?.score = max(existing.score, score)
      if score >= existing.score { candidate?.boundary = boundary }
    } else {
      candidate = Candidate(targetCameraID: target, startedAt: now, score: score,
        boundary: boundary, returnToAnchor: returnToAnchor)
    }
    guard let candidate else { return nil }
    state = returnToAnchor ? .candidateReturn : .candidateCut
    guard now - candidate.startedAt >= settings.candidateDwell else { return nil }

    let cutTime = candidate.boundary.time
    guard let cutSeconds = validSeconds(cutTime), cutSeconds >= (shotStartedAt ?? 0),
      !lastEmittedCutTime.isValid || CMTimeCompare(cutTime, lastEmittedCutTime) > 0 else {
      return nil
    }
    let confidence = clamp(candidate.score)
    let reason = returnToAnchor
      ? "\(target) · emphasis resolved"
      : "\(target) · \(candidate.boundary.label) + strong emphasis"
    let decision = CutDecision(targetCameraID: target, cutTime: cutTime,
      confidence: confidence, reason: reason)
    pendingOutput = decision
    lastDecision = decision
    lastEmittedCutTime = cutTime
    if let key = candidate.boundary.key {
      committedBoundaries.insert(key)
      if let seconds = validSeconds(candidate.boundary.time) {
        // Keep a time-based tombstone as well as the volatile range key: a
        // revised transcript may move the range start while describing the
        // same already-committed editorial boundary.
        if let cue = transcriptByStart[key] {
          committedBoundaryTimes.append(CommittedBoundary(kind: cue.kind, seconds: seconds))
        }
      }
    }
    self.candidate = nil
    state = .cut
    return decision
  }

  private func cutScore(audio: (emphasisScore: Float, pause: TimeInterval), boundary: Boundary,
    holdDuration: TimeInterval) -> Float {
    let pauseScore = clamp(Float(audio.pause / 0.5))
    let pacingNeed: Float = holdDuration >= settings.softMaximumShotDuration ? 0.08 : 0
    return clamp(boundary.confidence * 0.48 + audio.emphasisScore * 0.4 + pauseScore * 0.12 + pacingNeed)
  }

  private func currentShotScore(audio: (emphasisScore: Float, pause: TimeInterval)) -> Float {
    clamp(0.35 + audio.emphasisScore * 0.15)
  }

  private func resolved(boundary: Boundary, audio: (emphasisScore: Float, pause: TimeInterval)) -> Bool {
    boundary.label == "sentence boundary" || boundary.label == "transition boundary"
      || audio.pause >= settings.pauseBoundaryDuration
  }

  private func returnScore(audio: (emphasisScore: Float, pause: TimeInterval), boundary: Boundary) -> Float {
    clamp(boundary.confidence * 0.6 + (1 - audio.emphasisScore) * 0.25
      + clamp(Float(audio.pause / 0.5)) * 0.15)
  }

  private func timestampKey(_ time: CMTime) -> TimestampKey? {
    guard time.isValid, time.isNumeric, time.epoch == 0, time.timescale > 0 else { return nil }
    return TimestampKey(value: time.value, timescale: time.timescale, epoch: time.epoch)
  }

  private func validSeconds(_ time: CMTime) -> TimeInterval? {
    guard time.isValid, time.isNumeric, time.epoch == 0, time.timescale > 0 else { return nil }
    let seconds = time.seconds
    return seconds.isFinite && seconds >= 0 ? seconds : nil
  }

  private func distance(_ time: CMTime, _ seconds: TimeInterval) -> TimeInterval {
    abs((validSeconds(time) ?? .infinity) - seconds)
  }

  private func clamp(_ value: Float) -> Float { min(1, max(0, value)) }

  private mutating func prune(now: TimeInterval) {
    let cutoff = max(0, now - max(60, settings.softMaximumShotDuration * 4))
    audioByTime = audioByTime.filter { validSeconds($0.value.time).map { $0 >= cutoff } ?? false }
    transcriptByStart = transcriptByStart.filter {
      validSeconds($0.value.timeRange.end).map { $0 >= cutoff } ?? false
    }
    committedBoundaryTimes.removeAll { $0.seconds < cutoff }
    committedBoundaries = committedBoundaries.filter { transcriptByStart[$0] != nil }
  }
}
