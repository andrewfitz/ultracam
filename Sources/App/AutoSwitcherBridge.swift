import Darwin
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

enum AutoSwitcherControlEvent: Equatable, Sendable {
  case health(cameraID: String, healthy: Bool, time: Double)
  case manualOverride(cameraID: String, time: Double)
  case reset
}

/// Serializes events to the standalone Rust director. The bridge owns no
/// frames and never applies a cut itself; the host acknowledges a cut after
/// ProgramOutputRoute applies the target frame.
final class AutoSwitcherBridge: @unchecked Sendable {
  typealias InstructionHandler = @Sendable (AutoSwitcherInstruction) -> Void
  typealias ErrorHandler = @Sendable (String) -> Void
  typealias ExpiredHandler = @Sendable (UUID) -> Void
  typealias AudioCueHandler = @Sendable (AutoSwitcherAudioCue) -> Void
  typealias ControlEventHandler = @Sendable (AutoSwitcherControlEvent) -> Void
  typealias TranscriptCueHandler = @Sendable (AutoSwitcherTranscriptCue) -> Void

  private let queue = DispatchQueue(label: "org.ultracam.auto-switcher",
    qos: .userInteractive)
  private let stateLock = NSLock()
  private let queueKey = DispatchSpecificKey<UInt8>()
  private var handle: SwitcherProcess?
  private var _connectionLost = false
  var connectionLost: Bool { stateLock.withLock { _connectionLost } }
  private var _lastError: String?
  private var _onInstruction: InstructionHandler?
  private var _onError: ErrorHandler?
  private var _onDecisionExpired: ExpiredHandler?
  private var _onAudioCue: AudioCueHandler?
  private var _onControlEvent: ControlEventHandler?
  private var _onTranscriptCue: TranscriptCueHandler?

  private(set) var lastError: String? {
    get { stateLock.withLock { _lastError } }
    set { stateLock.withLock { _lastError = newValue } }
  }
  var onInstruction: InstructionHandler? {
    get { stateLock.withLock { _onInstruction } }
    set { stateLock.withLock { _onInstruction = newValue } }
  }
  var onError: ErrorHandler? {
    get { stateLock.withLock { _onError } }
    set { stateLock.withLock { _onError = newValue } }
  }
  var onDecisionExpired: ExpiredHandler? {
    get { stateLock.withLock { _onDecisionExpired } }
    set { stateLock.withLock { _onDecisionExpired = newValue } }
  }
  var onAudioCue: AudioCueHandler? {
    get { stateLock.withLock { _onAudioCue } }
    set { stateLock.withLock { _onAudioCue = newValue } }
  }
  var onControlEvent: ControlEventHandler? {
    get { stateLock.withLock { _onControlEvent } }
    set { stateLock.withLock { _onControlEvent = newValue } }
  }
  var onTranscriptCue: TranscriptCueHandler? {
    get { stateLock.withLock { _onTranscriptCue } }
    set { stateLock.withLock { _onTranscriptCue = newValue } }
  }

  init?(settings: NaturalTalkingHeadSettings, anchor: FeedID, emphasis: FeedID, availableRoutes: [FeedID] = []) {
    queue.setSpecific(key: queueKey, value: 1)
    let config: [String: Any] = [
      "available_routes": availableRoutes.map(\.rawValue),
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
    handle = try? SwitcherProcess(configuration: json)
    guard handle != nil else { return nil }
  }

  deinit { stop() }

  func stop() {
    let release = {
      self.handle?.close()
      self.handle = nil
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
      self.sendHealth(cameraID: cameraID, healthy: healthy, seconds: seconds)
    }
  }

  /// The director's clock moved to another camera's stream clock. Each input keeps its own,
  /// so the new one can be minutes from the last: later reads as a shot held that long and
  /// forces a cut at once, earlier drops every cue until it catches up. The director starts
  /// its timing over on the new clock, with `onAir` still the shot and each camera's health
  /// as given. One block on the queue, so nothing on either clock lands in between.
  func rebaseClock(at time: CMTime, onAir: FeedID?, health: [(FeedID, Bool)]) {
    guard let seconds = seconds(time) else { return }
    queue.async { [weak self] in
      guard let self, self.handle != nil else { return }
      self.send(["type": "reset"])
      for (cameraID, healthy) in health { self.sendHealth(cameraID: cameraID, healthy: healthy, seconds: seconds) }
      if let onAir { self.send(["type": "manualOverride", "camera_id": onAir.rawValue, "time": seconds]) }
    }
  }

  private func sendHealth(cameraID: FeedID, healthy: Bool, seconds: Double) {
    send([
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

  func ingestAudio(time: CMTime, rms: Float, peak: Float, present: Bool) {
    guard let seconds = seconds(time), seconds >= 0 else { return }
    guard rms.isFinite, peak.isFinite else { return }
    queue.async { [weak self] in
      guard let self, self.handle != nil else { return }
      self.send(["type": "levels", "time": seconds, "rms": rms, "peak": peak, "present": present])
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
      let transcriptCueHandler = self.onTranscriptCue
      transcriptCueHandler?(cue)
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
      self.send(["type": "reset"])
    }
  }

  func manualOverride(cameraID: FeedID, at time: CMTime) {
    guard let seconds = seconds(time) else { return }
    queue.async { [weak self] in
      self?.send(["type": "manualOverride", "camera_id": cameraID.rawValue, "time": seconds])
    }
  }

  /// Rust decisions carry absolute seconds. Quantize each absolute boundary
  /// once onto the same clock as Program and the durable session timeline.
  static func instructionTime(seconds: Double) -> CMTime? {
    guard seconds.isFinite, seconds >= 0 else { return nil }
    // CMTime(seconds:preferredTimescale:) can truncate a binary Double just
    // below an integral tick. Explicit nearest rounding preserves boundaries
    // that crossed the director's seconds-based JSON API.
    let ticks = (seconds * 240_000).rounded(.toNearestOrAwayFromZero)
    guard let value = Int64(exactly: ticks) else { return nil }
    return CMTime(value: value, timescale: 240_000).validValue
  }

  private func send(_ event: [String: Any]) {
    guard let handle,
      let data = try? JSONSerialization.data(withJSONObject: event),
      let json = String(data: data, encoding: .utf8) else { return }
    let output: String?
    do {
      let response = try handle.exchange(json)
      output = response == "[]" ? nil : response
    } catch {
      stateLock.withLock { _connectionLost = true }
      report("Auto Switcher connection closed: \(error.localizedDescription)")
      handle.close()
      self.handle = nil
      return
    }
    // Capture control inputs on the same serialized path as audio. In
    // particular, a clock rebase is reset + health + manual override.
    switch event["type"] as? String {
    case "reset": onControlEvent?(.reset)
    case "video":
      if let observation = event["observation"] as? [String: Any],
        let camera = observation["camera_id"] as? String,
        let healthy = observation["healthy"] as? Bool, let time = observation["time"] as? Double {
        onControlEvent?(.health(cameraID: camera, healthy: healthy, time: time))
      }
    default: break
    }
    guard let output else { return }
    guard let data = output.data(using: .utf8),
      let values = try? JSONDecoder().decode([RustOutput].self, from: data) else {
      report("Rust auto-switcher returned invalid JSON")
      return
    }
    for value in values {
      switch value.type {
      case "audioCue":
        if let cue = value.cue { onAudioCue?(cue) }
      case "cut":
        guard let instruction = value.instruction,
          let target = instruction.targetCameraID,
          let decisionID = UUID(uuidString: instruction.decisionID),
          let cutTime = Self.instructionTime(seconds: instruction.cutTime),
          let expiresAt = Self.instructionTime(seconds: instruction.expiresAt) else { continue }
        let instructionHandler = onInstruction
        instructionHandler?(AutoSwitcherInstruction(decisionID: decisionID,
          sessionGeneration: instruction.sessionGeneration,
          targetCameraID: FeedID(rawValue: target), cutTime: cutTime,
          expiresAt: expiresAt, confidence: instruction.confidence,
          reason: instruction.reason, forced: instruction.forced))
      case "status":
        // An override can be rejected or snapped forward by the director.
        // Persist its accepted clock and camera, rather than the raw request.
        if event["type"] as? String == "manualOverride",
          let camera = value.currentCameraID, let time = value.time,
          value.pendingDecisionID == nil {
          onControlEvent?(.manualOverride(cameraID: camera, time: time))
        }
      case "error": report(value.message ?? "Rust auto-switcher error")
      case "decisionExpired":
        if let decisionID = value.decisionID.flatMap(UUID.init(uuidString:)) {
          let expiredHandler = onDecisionExpired
          expiredHandler?(decisionID)
        }
      default: break
      }
    }
  }

  private func report(_ message: String) {
    lastError = message
    let errorHandler = onError
    errorHandler?(message)
  }

  private func seconds(_ time: CMTime) -> Double? { secondsValue(time) }


}

private struct RustOutput: Decodable {
  let type: String
  let cue: AutoSwitcherAudioCue?
  let instruction: RustInstruction?
  let decisionID: String?
  let message: String?
  let time: Double?
  let currentCameraID: String?
  let pendingDecisionID: UUID?

  enum CodingKeys: String, CodingKey {
    case type, instruction, message, cue
    case decisionID = "decision_id"
    case time
    case currentCameraID = "current_camera_id"
    case pendingDecisionID = "pending_decision_id"
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

/// One private request at a time on the bridge queue. The helper exits on EOF.
/// A stalled or failed peer ends the session before another cut can be sent.
private final class SwitcherProcess {
  private let child = Process()
  private let input = Pipe()
  private let output = Pipe()

  init(configuration: String) throws {
    let env = ProcessInfo.processInfo.environment
    let binary = Bundle.main.url(forAuxiliaryExecutable: "auto-switcher")
      ?? env["CARGO_TARGET_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("release/auto-switcher") }
    guard let binary else { throw CocoaError(.fileNoSuchFile) }
    child.executableURL = binary
    let port = UserDefaults.standard.integer(forKey: "AutoSwitcherServerPort")
    child.arguments = port > 0 ? ["attach", "--port", String(port)] : ["worker"]
    child.standardInput = input
    child.standardOutput = output
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try child.run()
    do {
      guard try exchange(configuration) == "[]" else { throw CocoaError(.fileReadCorruptFile) }
    } catch {
      close()
      throw error
    }
  }

  func exchange(_ json: String) throws -> String {
    try input.fileHandleForWriting.write(contentsOf: Data((json + "\n").utf8))
    let handle = output.fileHandleForReading
    var bytes = Data()
    while bytes.count < 262144 {
      var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, 2500) > 0 else { throw CocoaError(.fileReadUnknown) }
      let chunk = handle.availableData
      guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
      bytes.append(chunk)
      if bytes.last == 10 { return String(decoding: bytes.dropLast(), as: UTF8.self) }
    }
    throw CocoaError(.fileReadCorruptFile)
  }

  func close() {
    try? input.fileHandleForWriting.close()
    if child.isRunning { child.terminate() }
    try? output.fileHandleForReading.close()
  }
}
