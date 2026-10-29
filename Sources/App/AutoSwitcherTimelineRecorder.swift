import CoreMedia
import Foundation

struct AutoSwitcherAudioCue: Codable, Sendable {
  let id: UInt64
  let time: Double
  let duration: Double
  let speechEnergy: Float
  let pauseDuration: Double
  let emphasis: Float
  let laughter: Float
  let speechStart: Bool
  let speechStop: Bool
  let sessionGeneration: UInt64

  enum CodingKeys: String, CodingKey {
    case id, time, duration
    case speechEnergy = "speech_energy"
    case pauseDuration = "pause_duration"
    case emphasis, laughter
    case speechStart = "speech_start"
    case speechStop = "speech_stop"
    case sessionGeneration = "session_generation"
  }
}

private struct AutoSwitcherTimelineTimebase: Codable {
  var kind = "media"
  var units = "seconds"
  let timescale: Int32
  var epoch: Int64 = 0
  var origin = "source_pts"
}

private struct AutoSwitcherTimelineConfig: Codable {
  let anchorCameraID: String
  let emphasisCameraID: String
  let minimumShotDuration: Double
  let cooldown: Double
  let emphasisHold: Double
  let softMaximumShotDuration: Double
  let maximumShotDuration: Double
  let forcedCutGracePeriod: Double
  let forcedBoundaryLookback: Double
  let boundaryWindow: Double
  let candidateDwell: Double
  let transcriptConfidenceThreshold: Float
  let pauseBoundaryDuration: Double
  let cutThreshold: Float
  let hysteresisMargin: Float
  let transcriptOutputDelay: Double
  let mode: String
  let manualHold: Bool
  let sessionGeneration: UInt64 = 1

  enum CodingKeys: String, CodingKey {
    case anchorCameraID = "anchor_camera_id"
    case emphasisCameraID = "emphasis_camera_id"
    case minimumShotDuration = "minimum_shot_duration"
    case cooldown
    case emphasisHold = "emphasis_hold"
    case softMaximumShotDuration = "soft_maximum_shot_duration"
    case maximumShotDuration = "maximum_shot_duration"
    case forcedCutGracePeriod = "forced_cut_grace_period"
    case forcedBoundaryLookback = "forced_boundary_lookback"
    case boundaryWindow = "boundary_window"
    case candidateDwell = "candidate_dwell"
    case transcriptConfidenceThreshold = "transcript_confidence_threshold"
    case pauseBoundaryDuration = "pause_boundary_duration"
    case cutThreshold = "cut_threshold"
    case hysteresisMargin = "hysteresis_margin"
    case transcriptOutputDelay = "transcript_output_delay"
    case mode
    case manualHold = "manual_hold"
    case sessionGeneration = "session_generation"
  }
}

private struct AutoSwitcherTimelineSource: Codable {
  let cameraID: String
  let role: String
  var label: String?
  var mediaFile: String?
  var mediaStart: Double?
  var mediaEnd: Double?
  let timebase: AutoSwitcherTimelineTimebase

  enum CodingKeys: String, CodingKey {
    case cameraID = "camera_id"
    case role, label
    case mediaFile = "media_file"
    case mediaStart = "media_start"
    case mediaEnd = "media_end"
    case timebase
  }
}

private struct AutoSwitcherTimelineRecording: Codable {
  let recordingID: UUID
  let cameraID: String
  let path: String
  let kind: String
  let format: String?
  var mediaStart: Double?
  var mediaEnd: Double?

  enum CodingKeys: String, CodingKey {
    case recordingID = "recording_id"
    case cameraID = "camera_id"
    case path, kind, format
    case mediaStart = "media_start"
    case mediaEnd = "media_end"
  }
}

private struct AutoSwitcherTimelineInstruction: Codable {
  let decisionID: UUID
  let sessionGeneration: UInt64
  let targetCameraID: String
  let cutTime: Double
  let cutTimeTicks: Int64
  let expiresAt: Double
  let expiresAtTicks: Int64
  let confidence: Float
  let reason: String
  let forced: Bool

  enum CodingKeys: String, CodingKey {
    case decisionID = "decision_id"
    case sessionGeneration = "session_generation"
    case targetCameraID = "target_camera_id"
    case cutTime = "cut_time"
    case cutTimeTicks = "cut_time_ticks"
    case expiresAt = "expires_at"
    case expiresAtTicks = "expires_at_ticks"
    case confidence, reason, forced
  }
}

private struct AutoSwitcherTimelineOutput: Codable {
  let type: String
  let instruction: AutoSwitcherTimelineInstruction?
  let decisionID: UUID?
  let message: String?

  enum CodingKeys: String, CodingKey {
    case type, instruction, message
    case decisionID = "decision_id"
  }
}

private struct AutoSwitcherTimelineEvent: Codable {
  let type: String
  let cue: AutoSwitcherAudioCue?
  let transcript: AutoSwitcherTranscriptCue?
  let time: Double?
  let timeTicks: Int64?
  let decisionID: UUID?
  let appliedAt: Double?
  let appliedAtTicks: Int64?
  let cameraID: String?

  enum CodingKeys: String, CodingKey {
    case type, cue, transcript, time
    case timeTicks = "time_ticks"
    case decisionID = "decision_id"
    case appliedAt = "applied_at"
    case appliedAtTicks = "applied_at_ticks"
    case cameraID = "camera_id"
  }

  init(type: String, cue: AutoSwitcherAudioCue? = nil,
       transcript: AutoSwitcherTranscriptCue? = nil, time: Double? = nil,
       timeTicks: Int64? = nil, decisionID: UUID? = nil, appliedAt: Double? = nil,
       appliedAtTicks: Int64? = nil, cameraID: String? = nil) {
    self.type = type
    self.cue = cue
    self.transcript = transcript
    self.time = time
    self.timeTicks = timeTicks
    self.decisionID = decisionID
    self.appliedAt = appliedAt
    self.appliedAtTicks = appliedAtTicks
    self.cameraID = cameraID
  }
}

private struct AutoSwitcherTimelineEventRecord: Codable {
  let sequence: UInt64
  let mediaTime: Double?
  let mediaTimeTicks: Int64?
  let event: AutoSwitcherTimelineEvent
  let outputs: [AutoSwitcherTimelineOutput]

  enum CodingKeys: String, CodingKey {
    case sequence
    case mediaTime = "media_time"
    case mediaTimeTicks = "media_time_ticks"
    case event, outputs
  }
}

private struct AutoSwitcherTimelineCut: Codable {
  let decisionID: UUID?
  let sessionGeneration: UInt64
  let fromCameraID: String?
  let targetCameraID: String
  let requestedCutTime: Double?
  let requestedCutTimeTicks: Int64?
  var appliedSourceTime: Double?
  var appliedSourceTimeTicks: Int64?
  var appliedProgramTime: Double?
  var appliedProgramTimeTicks: Int64?
  let expiresAt: Double?
  let expiresAtTicks: Int64?
  let confidence: Float?
  let reason: String
  let forced: Bool
  var status: String

  enum CodingKeys: String, CodingKey {
    case decisionID = "decision_id"
    case sessionGeneration = "session_generation"
    case fromCameraID = "from_camera_id"
    case targetCameraID = "target_camera_id"
    case requestedCutTime = "requested_cut_time"
    case requestedCutTimeTicks = "requested_cut_time_ticks"
    case appliedSourceTime = "applied_source_time"
    case appliedSourceTimeTicks = "applied_source_time_ticks"
    case appliedProgramTime = "applied_program_time"
    case appliedProgramTimeTicks = "applied_program_time_ticks"
    case expiresAt = "expires_at"
    case expiresAtTicks = "expires_at_ticks"
    case confidence, reason, forced, status
  }
}

private struct AutoSwitcherTimelineDocument: Codable {
  let schemaVersion = 3
  let sessionID: UUID
  let mode: String
  let timebase: AutoSwitcherTimelineTimebase
  let startedAtUnixMS: Int64
  var endedAtUnixMS: Int64?
  var duration: Double
  let config: AutoSwitcherTimelineConfig
  var sources: [AutoSwitcherTimelineSource]
  var recordings: [AutoSwitcherTimelineRecording]
  var events: [AutoSwitcherTimelineEventRecord]
  var eventsProcessed: Int
  var cuts: [AutoSwitcherTimelineCut]
  var instructions: [AutoSwitcherTimelineInstruction]
  var statuses: [AutoSwitcherTimelineOutput]
  var metadata: [String: String]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sessionID = "session_id"
    case mode, timebase
    case startedAtUnixMS = "started_at_unix_ms"
    case endedAtUnixMS = "ended_at_unix_ms"
    case duration, config, sources, recordings, events
    case eventsProcessed = "events_processed"
    case cuts, instructions, statuses, metadata
  }
}

@MainActor
final class AutoSwitcherTimelineRecorder {
  let sessionID: UUID
  private(set) var lastError: String?
  var onError: ((String) -> Void)?
  var outputFileURL: URL { outputURL }
  private var document: AutoSwitcherTimelineDocument
  private var outputURL: URL
  private var nextSequence: UInt64 = 1
  private var pending: [UUID: Int] = [:]
  private var recordingIDs: [FeedID: UUID] = [:]
  private var currentCameraID: FeedID
  private var lastPersistedEventCount = 0

  init(settings: NaturalTalkingHeadSettings, anchor: FeedID, emphasis: FeedID,
       outputFolder: URL?) {
    sessionID = UUID()
    currentCameraID = anchor
    let config = AutoSwitcherTimelineConfig(
      anchorCameraID: anchor.rawValue, emphasisCameraID: emphasis.rawValue,
      minimumShotDuration: max(10, settings.minimumShotDuration), cooldown: settings.cooldown,
      emphasisHold: settings.emphasisHold,
      softMaximumShotDuration: settings.softMaximumShotDuration,
      maximumShotDuration: settings.maximumShotDuration,
      forcedCutGracePeriod: settings.forcedCutGracePeriod,
      forcedBoundaryLookback: settings.forcedBoundaryLookback,
      boundaryWindow: settings.boundaryWindow, candidateDwell: settings.candidateDwell,
      transcriptConfidenceThreshold: settings.transcriptConfidenceThreshold,
      pauseBoundaryDuration: settings.pauseBoundaryDuration,
      cutThreshold: settings.cutThreshold, hysteresisMargin: settings.hysteresisMargin,
      transcriptOutputDelay: settings.transcriptOutputDelay, mode: settings.mode.rawValue,
      manualHold: settings.manualHold)
    let timebase = AutoSwitcherTimelineTimebase(timescale: 240_000)
    document = AutoSwitcherTimelineDocument(
      sessionID: sessionID, mode: "realtime", timebase: timebase,
      startedAtUnixMS: Self.unixMS(), endedAtUnixMS: nil, duration: 0,
      config: config,
      sources: [
        AutoSwitcherTimelineSource(cameraID: anchor.rawValue, role: "anchor", label: nil,
          mediaFile: nil, mediaStart: nil, mediaEnd: nil, timebase: timebase),
        AutoSwitcherTimelineSource(cameraID: emphasis.rawValue, role: "emphasis", label: nil,
          mediaFile: nil, mediaStart: nil, mediaEnd: nil, timebase: timebase),
      ], recordings: [], events: [], eventsProcessed: 0, cuts: [], instructions: [],
      statuses: [], metadata: ["clock": "source_pts"])
    outputURL = Self.makeOutputURL(folder: outputFolder, sessionID: sessionID)
    persist(force: true)
  }

  func setOutputFolder(_ folder: URL?) {
    let nextURL = Self.makeOutputURL(folder: folder, sessionID: sessionID)
    guard nextURL != outputURL else { return }
    persist(force: true)
    outputURL = nextURL
    persist(force: true)
  }

  func recordAudioCue(_ cue: AutoSwitcherAudioCue) {
    let timestamp = Self.timestamp(CMTime(seconds: cue.time, preferredTimescale: document.timebase.timescale))
    guard let timestamp else { return }
    append(event: AutoSwitcherTimelineEvent(type: "audio", cue: cue,
      time: timestamp.seconds, timeTicks: timestamp.ticks, decisionID: nil,
      appliedAt: nil, appliedAtTicks: nil, cameraID: nil), mediaTime: timestamp,
      outputs: [])
    append(event: AutoSwitcherTimelineEvent(type: "tick", cue: nil,
      time: timestamp.seconds, timeTicks: timestamp.ticks, decisionID: nil,
      appliedAt: nil, appliedAtTicks: nil, cameraID: nil), mediaTime: timestamp,
      outputs: [])
  }

  /// Records the same transcript cue delivered to the Rust director so an
  /// offline replay can reproduce transcript-assisted decisions exactly.
  func recordTranscript(_ cue: AutoSwitcherTranscriptCue) {
    guard cue.end >= cue.start,
      cue.start.isFinite, cue.end.isFinite, cue.start >= 0 else { return }
    let timestamp = Self.timestamp(CMTime(seconds: cue.end,
      preferredTimescale: document.timebase.timescale))
    guard let timestamp else { return }
    append(event: AutoSwitcherTimelineEvent(type: "transcript", transcript: cue,
      time: timestamp.seconds, timeTicks: timestamp.ticks, decisionID: nil,
      appliedAt: nil, appliedAtTicks: nil, cameraID: nil), mediaTime: timestamp,
      outputs: [])
  }

  func recordTick(time: CMTime) {
    guard let timestamp = Self.timestamp(time) else { return }
    append(event: AutoSwitcherTimelineEvent(type: "tick", cue: nil,
      time: timestamp.seconds, timeTicks: timestamp.ticks, decisionID: nil,
      appliedAt: nil, appliedAtTicks: nil, cameraID: nil), mediaTime: timestamp,
      outputs: [])
  }

  func recordInstruction(_ instruction: AutoSwitcherInstruction, from source: FeedID?) {
    guard pending[instruction.decisionID] == nil,
      !document.instructions.contains(where: { $0.decisionID == instruction.decisionID }) else { return }
    guard let cut = Self.cutRecord(instruction: instruction, from: source ?? currentCameraID,
      timebase: document.timebase) else { return }
    pending[instruction.decisionID] = document.cuts.count
    document.cuts.append(cut)
    document.instructions.append(Self.instruction(instruction, timebase: document.timebase))
    let output = AutoSwitcherTimelineOutput(type: "cut",
      instruction: Self.instruction(instruction, timebase: document.timebase),
      decisionID: instruction.decisionID, message: nil)
    append(event: AutoSwitcherTimelineEvent(type: "directorOutput", cue: nil,
      time: instruction.cutTime.secondsValue, timeTicks: Self.timestamp(instruction.cutTime)?.ticks,
      decisionID: instruction.decisionID, appliedAt: nil, appliedAtTicks: nil,
      cameraID: instruction.targetCameraID.rawValue),
      mediaTime: Self.timestamp(instruction.cutTime), outputs: [output])
  }

  func recordApplied(decisionID: UUID, target: FeedID, sourceTime: CMTime, programTime: CMTime) {
    guard let index = pending[decisionID], document.cuts.indices.contains(index),
      let source = Self.timestamp(sourceTime), let program = Self.timestamp(programTime) else { return }
    pending.removeValue(forKey: decisionID)
    document.cuts[index].status = "applied"
    document.cuts[index].appliedSourceTime = source.seconds
    document.cuts[index].appliedSourceTimeTicks = source.ticks
    document.cuts[index].appliedProgramTime = program.seconds
    document.cuts[index].appliedProgramTimeTicks = program.ticks
    currentCameraID = target
    // `applied_at` is the director clock. Program time is already stored on
    // the cut record and must not be replayed as the source-clock ack.
    let event = AutoSwitcherTimelineEvent(type: "acknowledge", cue: nil,
      time: source.seconds, timeTicks: source.ticks, decisionID: decisionID,
      appliedAt: source.seconds, appliedAtTicks: source.ticks, cameraID: target.rawValue)
    append(event: event, mediaTime: source, outputs: [])
    persist(force: true)
  }

  func recordExpired(decisionID: UUID) {
    if let index = pending.removeValue(forKey: decisionID), document.cuts.indices.contains(index) {
      document.cuts[index].status = "expired"
    }
    let output = AutoSwitcherTimelineOutput(type: "decisionExpired", instruction: nil,
      decisionID: decisionID, message: nil)
    append(event: AutoSwitcherTimelineEvent(type: "directorOutput", cue: nil,
      time: nil, timeTicks: nil, decisionID: decisionID, appliedAt: nil,
      appliedAtTicks: nil, cameraID: nil), mediaTime: nil, outputs: [output])
    persist(force: true)
  }

  func recordRejected(decisionID: UUID) {
    if let index = pending.removeValue(forKey: decisionID), document.cuts.indices.contains(index) {
      document.cuts[index].status = "rejected"
    }
    let output = AutoSwitcherTimelineOutput(type: "reject", instruction: nil,
      decisionID: decisionID, message: nil)
    append(event: AutoSwitcherTimelineEvent(type: "directorOutput", cue: nil,
      time: nil, timeTicks: nil, decisionID: decisionID, appliedAt: nil,
      appliedAtTicks: nil, cameraID: nil), mediaTime: nil, outputs: [output])
    persist(force: true)
  }

  func recordError(_ message: String) {
    let output = AutoSwitcherTimelineOutput(type: "error", instruction: nil,
      decisionID: nil, message: message)
    append(event: AutoSwitcherTimelineEvent(type: "directorOutput", cue: nil,
      time: nil, timeTicks: nil, decisionID: nil, appliedAt: nil,
      appliedAtTicks: nil, cameraID: nil), mediaTime: nil, outputs: [output])
    persist(force: true)
  }

  func recordingStarted(feedID: FeedID, url: URL, mediaStart: CMTime?) {
    let id = UUID()
    recordingIDs[feedID] = id
    let start = mediaStart.flatMap(Self.timestamp)
    document.recordings.append(AutoSwitcherTimelineRecording(
      recordingID: id, cameraID: feedID.rawValue, path: url.path,
      kind: "source", format: url.pathExtension, mediaStart: start?.seconds, mediaEnd: nil))
    updateSource(feedID: feedID, url: url, start: start)
    persist(force: true)
  }

  func recordingFinished(feedID: FeedID, url: URL?, mediaEnd: CMTime?) {
    guard let id = recordingIDs[feedID],
      let index = document.recordings.firstIndex(where: { $0.recordingID == id }) else { return }
    document.recordings[index].mediaEnd = mediaEnd.flatMap(Self.timestamp)?.seconds
    updateSource(feedID: feedID, url: url, start: nil, end: mediaEnd.flatMap(Self.timestamp))
    recordingIDs.removeValue(forKey: feedID)
    persist(force: true)
  }

  func finish() {
    for index in pending.values where document.cuts.indices.contains(index) {
      document.cuts[index].status = "cancelled"
    }
    pending.removeAll()
    document.endedAtUnixMS = Self.unixMS()
    persist(force: true)
  }

  private func updateSource(feedID: FeedID, url: URL?, start: (seconds: Double, ticks: Int64)?, end: (seconds: Double, ticks: Int64)? = nil) {
    let index: Int
    if let existing = document.sources.firstIndex(where: { $0.cameraID == feedID.rawValue }) {
      index = existing
    } else {
      document.sources.append(AutoSwitcherTimelineSource(cameraID: feedID.rawValue,
        role: "source", label: nil, mediaFile: nil, mediaStart: nil, mediaEnd: nil,
        timebase: document.timebase))
      index = document.sources.count - 1
    }
    if let url { document.sources[index].mediaFile = url.path }
    if let start { document.sources[index].mediaStart = start.seconds }
    if let end { document.sources[index].mediaEnd = end.seconds }
  }

  private func append(event: AutoSwitcherTimelineEvent, mediaTime: (seconds: Double, ticks: Int64)?, outputs: [AutoSwitcherTimelineOutput]) {
    document.duration = max(document.duration, mediaTime?.seconds ?? 0)
    document.events.append(AutoSwitcherTimelineEventRecord(sequence: nextSequence,
      mediaTime: mediaTime?.seconds, mediaTimeTicks: mediaTime?.ticks, event: event, outputs: outputs))
    nextSequence &+= 1
    document.eventsProcessed = document.events.count
    maybePersist()
  }

  private func maybePersist() {
    guard document.events.count - lastPersistedEventCount >= 30 else { return }
    persist(force: false)
  }

  private func persist(force: Bool) {
    guard force || document.events.count != lastPersistedEventCount else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(document)
      try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: outputURL, options: .atomic)
      lastPersistedEventCount = document.events.count
    } catch {
      // Recording remains usable if the optional sidecar cannot be written.
      lastError = error.localizedDescription
      onError?(lastError ?? "unknown timeline write error")
    }
  }

  private static func cutRecord(instruction: AutoSwitcherInstruction, from: FeedID,
                                timebase: AutoSwitcherTimelineTimebase) -> AutoSwitcherTimelineCut? {
    guard let requested = timestamp(instruction.cutTime), let expires = timestamp(instruction.expiresAt) else { return nil }
    return AutoSwitcherTimelineCut(decisionID: instruction.decisionID,
      sessionGeneration: instruction.sessionGeneration, fromCameraID: from.rawValue,
      targetCameraID: instruction.targetCameraID.rawValue,
      requestedCutTime: requested.seconds, requestedCutTimeTicks: requested.ticks,
      appliedSourceTime: nil, appliedSourceTimeTicks: nil,
      appliedProgramTime: nil, appliedProgramTimeTicks: nil,
      expiresAt: expires.seconds, expiresAtTicks: expires.ticks,
      confidence: instruction.confidence, reason: instruction.reason,
      forced: instruction.forced, status: "proposed")
  }

  private static func instruction(_ value: AutoSwitcherInstruction,
                                  timebase: AutoSwitcherTimelineTimebase) -> AutoSwitcherTimelineInstruction {
    let cut = timestamp(value.cutTime) ?? (0, 0)
    let expires = timestamp(value.expiresAt) ?? (0, 0)
    return AutoSwitcherTimelineInstruction(decisionID: value.decisionID,
      sessionGeneration: value.sessionGeneration, targetCameraID: value.targetCameraID.rawValue,
      cutTime: cut.seconds, cutTimeTicks: cut.ticks, expiresAt: expires.seconds,
      expiresAtTicks: expires.ticks, confidence: value.confidence,
      reason: value.reason, forced: value.forced)
  }

  private static func timestamp(_ time: CMTime) -> (seconds: Double, ticks: Int64)? {
    guard time.isValid, time.isNumeric, time.epoch == 0, time.timescale > 0 else { return nil }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds >= 0 else { return nil }
    let projected = CMTimeConvertScale(time, timescale: 240_000, method: .roundHalfAwayFromZero)
    guard projected.isValid, projected.isNumeric, projected.value >= 0 else { return nil }
    return (seconds, projected.value)
  }

  private static func makeOutputURL(folder: URL?, sessionID _: UUID) -> URL {
    let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Ultracam/Sessions", isDirectory: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let stem = "auto-switcher-\(formatter.string(from: Date()))"
    var candidate = base.appendingPathComponent("\(stem).json")
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = base.appendingPathComponent("\(stem)-\(suffix).json")
      suffix += 1
    }
    return candidate
  }

  private static func unixMS() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
  }
}

private extension CMTime {
  var secondsValue: Double? {
    guard isValid, isNumeric, timescale > 0 else { return nil }
    let seconds = CMTimeGetSeconds(self)
    return seconds.isFinite ? seconds : nil
  }
}
