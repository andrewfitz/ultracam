import CoreMedia
import Foundation

struct AutoSwitcherInstruction: Equatable, Sendable {
  let decisionID: UUID
  let sessionGeneration: UInt64
  let targetCameraID: FeedID
  let cutTime: CMTime
  let expiresAt: CMTime
  let confidence: Float
  let reason: String
  let forced: Bool
}

/// A transcript boundary accepted by the realtime director.  Keeping this
/// value type independent of CoreMedia lets ASR adapters deliver cues from
/// their own callback queues without sharing mutable state with the bridge.
struct AutoSwitcherTranscriptCue: Codable, Equatable, Sendable {
  let segmentID: String
  let revision: UInt32
  let start: Double
  let end: Double
  let kind: String
  let confidence: Float
  let isFinal: Bool
  let sessionGeneration: UInt64

  enum CodingKeys: String, CodingKey {
    case segmentID = "segment_id"
    case revision, start, end, kind, confidence
    case isFinal = "is_final"
    case sessionGeneration = "session_generation"
  }
}

/// Serializes the Rust director behind a small C ABI. The bridge owns no
/// frames and never applies a cut itself; the host acknowledges a cut after
/// ProgramOutputRoute applies the target frame.
final class AutoSwitcherBridge: @unchecked Sendable {
  typealias InstructionHandler = @Sendable (AutoSwitcherInstruction) -> Void
  typealias ErrorHandler = @Sendable (String) -> Void
  typealias ExpiredHandler = @Sendable (UUID) -> Void
  typealias AudioCueHandler = @Sendable (AutoSwitcherAudioCue) -> Void
  typealias TranscriptCueHandler = @Sendable (AutoSwitcherTranscriptCue) -> Void

  private let queue = DispatchQueue(label: "org.ultracam.auto-switcher",
    qos: .userInteractive)
  private let queueKey = DispatchSpecificKey<UInt8>()
  private var handle: OpaquePointer?
  private var nextAudioID: UInt64 = 1
  private var silenceStartedAt: CMTime?
  private var speaking = false
  private var lastCueSeconds: Double?
  private(set) var lastError: String?
  var onInstruction: InstructionHandler?
  var onError: ErrorHandler?
  var onDecisionExpired: ExpiredHandler?
  var onAudioCue: AudioCueHandler?
  var onTranscriptCue: TranscriptCueHandler?

  init?(settings: NaturalTalkingHeadSettings, anchor: FeedID, emphasis: FeedID) {
    queue.setSpecific(key: queueKey, value: 1)
    let config: [String: Any] = [
      "anchor_camera_id": anchor.rawValue,
      "emphasis_camera_id": emphasis.rawValue,
      "minimum_shot_duration": max(10, settings.minimumShotDuration),
      "cooldown": settings.cooldown,
      "emphasis_hold": settings.emphasisHold,
      "soft_maximum_shot_duration": settings.softMaximumShotDuration,
      "maximum_shot_duration": settings.maximumShotDuration,
      "forced_cut_grace_period": settings.forcedCutGracePeriod,
      "forced_boundary_lookback": settings.forcedBoundaryLookback,
      "boundary_window": settings.boundaryWindow,
      "candidate_dwell": settings.candidateDwell,
      "transcript_confidence_threshold": settings.transcriptConfidenceThreshold,
      "pause_boundary_duration": settings.pauseBoundaryDuration,
      "cut_threshold": settings.cutThreshold,
      "hysteresis_margin": settings.hysteresisMargin,
      "transcript_output_delay": settings.transcriptOutputDelay,
      "mode": settings.mode.rawValue,
      "manual_hold": settings.manualHold,
      "session_generation": 1,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: config),
      let json = String(data: data, encoding: .utf8) else { return nil }
    handle = json.withCString { auto_switcher_create($0) }
    guard handle != nil else { return nil }
  }

  deinit { stop() }

  func stop() {
    let release = {
      if let handle = self.handle { auto_switcher_destroy(handle) }
      self.handle = nil
      self.silenceStartedAt = nil
      self.speaking = false
      self.lastCueSeconds = nil
    }
    // deinit can run on this queue when the last release happens inside a
    // queued callback. queue.sync from that queue deadlocks.
    if DispatchQueue.getSpecific(key: queueKey) != nil { release() }
    else { queue.sync(execute: release) }
  }

  /// Tells the director a configured camera can or cannot be cut to. The
  /// following audio or program tick applies the health change, so this does
  /// not invent a clock sample of its own.
  func setCameraHealth(cameraID: FeedID, healthy: Bool, at time: CMTime) {
    guard let seconds = seconds(time) else { return }
    queue.async { [weak self] in
      guard let self, self.handle != nil else { return }
      self.send([
        "type": "video",
        "observation": [
          "time": seconds,
          "camera_id": cameraID.rawValue,
          "healthy": healthy,
          "motion": 0.0,
          "scene_change": 0.0,
          "session_generation": 0,
        ],
      ])
    }
  }

  func ingestAudio(time: CMTime, rms: Float, peak: Float, present: Bool) {
    guard let seconds = seconds(time), seconds >= 0 else { return }
    let energy = max(0, min(1, rms))
    let emphasis = max(0, min(1, peak))
    queue.async { [weak self] in
      guard let self, self.handle != nil else { return }
      let threshold: Float = 0.035
      let isSpeech = present && energy >= threshold
      let wasSpeaking = self.speaking
      let speechStart = isSpeech && !wasSpeaking
      let speechStop = !isSpeech && wasSpeaking
      if isSpeech { self.silenceStartedAt = nil }
      else if self.silenceStartedAt == nil { self.silenceStartedAt = time }
      let pause = self.silenceStartedAt.map { max(0, seconds - (secondsValue($0) ?? seconds)) } ?? 0
      self.speaking = isSpeech
      // Status updates arrive in bursts, not once per audio sample. A
      // 1/sampleRate duration records a 20 µs cue for a packet that actually
      // covers the gap since the previous update.
      let duration = self.cueDuration(endingAt: seconds)
      self.lastCueSeconds = seconds
      let event: [String: Any] = [
        "type": "audio",
        "cue": [
          "id": self.nextAudioID,
          "time": seconds,
          "duration": duration,
          "speech_energy": energy,
          "pause_duration": pause,
          "emphasis": emphasis,
          "laughter": 0.0,
          "speech_start": speechStart,
          "speech_stop": speechStop,
          // Zero asks the Rust director to bind the cue to its current
          // session. The director can advance generations after a clock
          // discontinuity, so hard-coding 1 would permanently reject all
          // subsequent cues.
          "session_generation": 0,
        ],
      ]
      self.onAudioCue?(AutoSwitcherAudioCue(id: self.nextAudioID, time: seconds,
        duration: duration,
        speechEnergy: energy, pauseDuration: pause, emphasis: emphasis, laughter: 0,
        speechStart: speechStart, speechStop: speechStop,
        sessionGeneration: 0))
      self.nextAudioID &+= 1
      self.send(event)
      self.send(["type": "tick", "time": seconds])
    }
  }

  func ingestTranscript(segmentID: String, revision: UInt32, start: CMTime, end: CMTime,
                        kind: String, confidence: Float, isFinal: Bool) {
    guard let start = seconds(start), let end = seconds(end), end >= start,
      !segmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      ["phraseEnd", "sentenceEnd", "question", "transition"].contains(kind),
      confidence.isFinite else { return }
    let cue = AutoSwitcherTranscriptCue(segmentID: segmentID, revision: revision,
      start: start, end: end, kind: kind,
      confidence: max(0, min(1, confidence)), isFinal: isFinal, sessionGeneration: 0)
    queue.async { [weak self] in
      guard let self, self.handle != nil else { return }
      self.onTranscriptCue?(cue)
      self.send([
        "type": "transcript",
        "cue": ["segment_id": segmentID, "revision": revision, "start": start,
                 "end": end, "kind": kind, "confidence": cue.confidence,
                 "is_final": isFinal, "session_generation": 0],
      ])
    }
  }

  func acknowledge(decisionID: UUID, appliedAt: CMTime?) {
    queue.async { [weak self] in
      guard let self else { return }
      var event: [String: Any] = ["type": "acknowledge", "decision_id": decisionID.uuidString]
      if let appliedAt, let seconds = seconds(appliedAt) { event["applied_at"] = seconds }
      self.send(event)
    }
  }

  func reject(decisionID: UUID) {
    queue.async { [weak self] in
      self?.send(["type": "reject", "decision_id": decisionID.uuidString])
    }
  }

  func tick(time: CMTime) {
    guard let seconds = seconds(time) else { return }
    queue.async { [weak self] in self?.send(["type": "tick", "time": seconds]) }
  }

  func reset() {
    queue.async { [weak self] in
      guard let self else { return }
      self.speaking = false
      self.silenceStartedAt = nil
      self.lastCueSeconds = nil
      self.send(["type": "reset"])
    }
  }

  func manualOverride(cameraID: FeedID, at time: CMTime) {
    guard let seconds = seconds(time) else { return }
    queue.async { [weak self] in
      self?.send(["type": "manualOverride", "camera_id": cameraID.rawValue, "time": seconds])
    }
  }

  private func send(_ event: [String: Any]) {
    guard let handle,
      let data = try? JSONSerialization.data(withJSONObject: event),
      let json = String(data: data, encoding: .utf8) else { return }
    let outputPointer: UnsafeMutablePointer<CChar>? = json.withCString {
      auto_switcher_process_json(handle, $0)
    }
    guard let outputPointer else { return }
    let output = String(cString: outputPointer)
    auto_switcher_free_string(outputPointer)
    guard let data = output.data(using: .utf8),
      let values = try? JSONDecoder().decode([RustOutput].self, from: data) else {
      report("Rust auto-switcher returned invalid JSON")
      return
    }
    for value in values {
      switch value.type {
      case "cut":
        guard let instruction = value.instruction,
          let target = instruction.targetCameraID,
          let decisionID = UUID(uuidString: instruction.decisionID),
          let cutTime = CMTime(seconds: instruction.cutTime, preferredTimescale: 60_000).validValue,
          let expiresAt = CMTime(seconds: instruction.expiresAt, preferredTimescale: 60_000).validValue else { continue }
        onInstruction?(AutoSwitcherInstruction(decisionID: decisionID,
          sessionGeneration: instruction.sessionGeneration,
          targetCameraID: FeedID(rawValue: target), cutTime: cutTime,
          expiresAt: expiresAt, confidence: instruction.confidence,
          reason: instruction.reason, forced: instruction.forced))
      case "error": report(value.message ?? "Rust auto-switcher error")
      case "decisionExpired":
        if let decisionID = value.decisionID.flatMap(UUID.init(uuidString:)) {
          onDecisionExpired?(decisionID)
        }
      default: break
      }
    }
  }

  private func report(_ message: String) {
    lastError = message
    onError?(message)
  }

  private func seconds(_ time: CMTime) -> Double? { secondsValue(time) }

  private func cueDuration(endingAt seconds: Double) -> Double {
    guard let previous = lastCueSeconds, seconds >= previous else { return 0.02 }
    let delta = seconds - previous
    return delta > 0 && delta <= 1 ? delta : 0.02
  }
}

private struct RustOutput: Decodable {
  let type: String
  let instruction: RustInstruction?
  let decisionID: String?
  let message: String?

  enum CodingKeys: String, CodingKey {
    case type, instruction, message
    case decisionID = "decision_id"
  }
}

private struct RustInstruction: Decodable {
  let decisionID: String
  let sessionGeneration: UInt64
  let targetCameraID: String?
  let cutTime: Double
  let expiresAt: Double
  let confidence: Float
  let reason: String
  let forced: Bool

  enum CodingKeys: String, CodingKey {
    case decisionID = "decision_id"
    case sessionGeneration = "session_generation"
    case targetCameraID = "target_camera_id"
    case cutTime = "cut_time"
    case expiresAt = "expires_at"
    case confidence, reason, forced
  }
}

private func secondsValue(_ time: CMTime) -> Double? {
  guard time.isValid, time.isNumeric, time.epoch == 0, time.timescale > 0 else { return nil }
  let value = CMTimeGetSeconds(time)
  return value.isFinite && value >= 0 ? value : nil
}

private extension CMTime {
  var validValue: CMTime? {
    guard isValid, isNumeric, epoch == 0, timescale > 0,
      CMTimeGetSeconds(self).isFinite, CMTimeGetSeconds(self) >= 0 else { return nil }
    return self
  }
}
