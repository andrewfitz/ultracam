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

private struct AutoSwitcherTimelineTimebase: Codable, Sendable {
  var kind = "media"
  var units = "seconds"
  let timescale: Int32
  var epoch: Int64 = 0
  var origin = "source_pts"
}

private struct AutoSwitcherTimelineConfig: Codable, Sendable {
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

private struct AutoSwitcherTimelineSource: Codable, Sendable {
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

private struct AutoSwitcherTimelineRecording: Codable, Sendable {
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

private struct AutoSwitcherTimelineInstruction: Codable, Sendable {
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

private struct AutoSwitcherTimelineOutput: Codable, Sendable {
  let type: String
  let instruction: AutoSwitcherTimelineInstruction?
  let decisionID: UUID?
  let message: String?

  enum CodingKeys: String, CodingKey {
    case type, instruction, message
    case decisionID = "decision_id"
  }
}

private struct AutoSwitcherTimelineObservation: Codable, Sendable {
  let time: Double
  let camera_id: String
  let healthy: Bool
  var motion: Double = 0
  var scene_change: Double = 0
  var session_generation: UInt64 = 0
}

private struct AutoSwitcherTimelineEvent: Codable, Sendable {
  let type: String
  let cue: AutoSwitcherAudioCue?
  let transcript: AutoSwitcherTranscriptCue?
  let observation: AutoSwitcherTimelineObservation?
  let time: Double?
  let timeTicks: Int64?
  let decisionID: UUID?
  let appliedAt: Double?
  let appliedAtTicks: Int64?
  let cameraID: String?

  enum CodingKeys: String, CodingKey {
    case type, cue, transcript, observation, time
    case timeTicks = "time_ticks"
    case decisionID = "decision_id"
    case appliedAt = "applied_at"
    case appliedAtTicks = "applied_at_ticks"
    case cameraID = "camera_id"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    type = try c.decode(String.self, forKey: .type)
    cue = type == "audio" ? try c.decodeIfPresent(AutoSwitcherAudioCue.self, forKey: .cue) : nil
    transcript = type == "transcript" ? try c.decodeIfPresent(AutoSwitcherTranscriptCue.self, forKey: .cue) : nil
    observation = try c.decodeIfPresent(AutoSwitcherTimelineObservation.self, forKey: .observation)
    time = try c.decodeIfPresent(Double.self, forKey: .time)
    timeTicks = try c.decodeIfPresent(Int64.self, forKey: .timeTicks)
    decisionID = try c.decodeIfPresent(UUID.self, forKey: .decisionID)
    appliedAt = try c.decodeIfPresent(Double.self, forKey: .appliedAt)
    appliedAtTicks = try c.decodeIfPresent(Int64.self, forKey: .appliedAtTicks)
    cameraID = try c.decodeIfPresent(String.self, forKey: .cameraID)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(type, forKey: .type)
    try c.encodeIfPresent(observation, forKey: .observation)
    if let transcript { try c.encode(transcript, forKey: .cue) }
    else { try c.encodeIfPresent(cue, forKey: .cue) }
    try c.encodeIfPresent(time, forKey: .time)
    try c.encodeIfPresent(timeTicks, forKey: .timeTicks)
    try c.encodeIfPresent(decisionID, forKey: .decisionID)
    try c.encodeIfPresent(appliedAt, forKey: .appliedAt)
    try c.encodeIfPresent(appliedAtTicks, forKey: .appliedAtTicks)
    try c.encodeIfPresent(cameraID, forKey: .cameraID)
  }

  init(type: String, cue: AutoSwitcherAudioCue? = nil,
       transcript: AutoSwitcherTranscriptCue? = nil, observation: AutoSwitcherTimelineObservation? = nil, time: Double? = nil,
       timeTicks: Int64? = nil, decisionID: UUID? = nil, appliedAt: Double? = nil,
       appliedAtTicks: Int64? = nil, cameraID: String? = nil) {
    self.type = type
    self.cue = cue
    self.transcript = transcript
    self.observation = observation
    self.time = time
    self.timeTicks = timeTicks
    self.decisionID = decisionID
    self.appliedAt = appliedAt
    self.appliedAtTicks = appliedAtTicks
    self.cameraID = cameraID
  }
}

private struct AutoSwitcherTimelineEventRecord: Codable, Sendable {
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

private struct AutoSwitcherTimelineCut: Codable, Sendable {
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

private struct AutoSwitcherTimelineDocument: Codable, Sendable {
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
    case duration, config, sources, recordings
    case eventsProcessed = "events_processed"
    case cuts, instructions, statuses, metadata
  }
}

// All mutable state is confined to queue, including writes for the old folder during a move.
private final class AutoSwitcherTimelineWriter: @unchecked Sendable {
  enum Result: Sendable {
    case written
    case failed(String, retryAt: DispatchTime)
  }

  let queue = DispatchQueue(label: "Ultracam.AutoSwitcherTimeline", qos: .utility)
  private let encoder = JSONEncoder()
  private var encodedEvents = Data()
  private var eventEncodingError: (any Error)?
  private var failure: (message: String, retryAt: DispatchTime)?
  private var writtenRevision: UInt64?

  init() {
    encoder.outputFormatting = [.sortedKeys]
  }

  func write(_ document: AutoSwitcherTimelineDocument, events: [AutoSwitcherTimelineEventRecord],
             to url: URL, folder: URL?, revision: UInt64, urgent: Bool) -> Result {
    dispatchPrecondition(condition: .onQueue(queue))
    // Transfer each batch once, even while the destination is unavailable.
    if eventEncodingError == nil, !events.isEmpty {
      do {
        let batch = try encoder.encode(events)
        if !encodedEvents.isEmpty { encodedEvents.append(0x2C) }
        encodedEvents.append(contentsOf: batch.dropFirst().dropLast()) // strip array brackets
      } catch {
        eventEncodingError = error
      }
    }
    if writtenRevision == revision { return .written }
    if !urgent, let failure, DispatchTime.now() < failure.retryAt {
      return .failed(failure.message, retryAt: failure.retryAt)
    }
    do {
      if let eventEncodingError { throw eventEncodingError }
      var data = try encoder.encode(document)
      data.removeLast() // closing object brace
      data.append(contentsOf: Data(",\"events\":[".utf8))
      data.append(encodedEvents)
      data.append(contentsOf: Data("]}\n".utf8))
      let accessed = folder?.startAccessingSecurityScopedResource() ?? false
      defer { if accessed { folder?.stopAccessingSecurityScopedResource() } }
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      writtenRevision = revision
      failure = nil
      return .written
    } catch {
      let message = error.localizedDescription
      let retryAt = DispatchTime.now() + .seconds(1)
      failure = (message, retryAt)
      return .failed(message, retryAt: retryAt)
    }
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
  /// The folder as it was chosen. A file URL made from it carries no sandbox grant, so
  /// every write starts access on this one.
  private var folder: URL?
  private var lastDirectorMediaTime: Double?
  private var sessionGeneration: UInt64 = 1
  private var nextSequence: UInt64 = 1
  private var pending: [UUID: Int] = [:]
  private var recordingIDs: [FeedID: UUID] = [:]
  private var currentCameraID: FeedID
  private let writer = AutoSwitcherTimelineWriter()
  private var unsubmittedEvents: [AutoSwitcherTimelineEventRecord] = []
  private var revision: UInt64 = 0
  private var persistedRevision: UInt64?
  private var inFlightRevision: UInt64?
  private var retryAt: DispatchTime?
  private var announcedError: String?

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
      ], recordings: [], eventsProcessed: 0, cuts: [], instructions: [],
      statuses: [], metadata: ["clock": "source_pts"])
    folder = outputFolder
    outputURL = Self.scoped(outputFolder) { Self.makeOutputURL(folder: outputFolder) }
    persistImmediately(urgent: true)
  }

  func setOutputFolder(_ folder: URL?) {
    if self.folder?.standardizedFileURL.path == folder?.standardizedFileURL.path {
      self.folder = folder
      return
    }
    let nextURL = Self.scoped(folder) { Self.makeOutputURL(folder: folder) }
    if persistedRevision != revision { persistImmediately(urgent: true) }
    self.folder = folder
    outputURL = nextURL
    revision &+= 1
    persistImmediately(urgent: true)
  }

  /// A recording folder restored from its bookmark grants nothing until access starts.
  private static func scoped<T>(_ folder: URL?, _ body: () throws -> T) rethrows -> T {
    let accessed = folder?.startAccessingSecurityScopedResource() ?? false
    defer { if accessed { folder?.stopAccessingSecurityScopedResource() } }
    return try body()
  }

  func recordControlEvent(_ input: AutoSwitcherControlEvent) {
    let event: AutoSwitcherTimelineEvent
    let timestamp: (seconds: Double, ticks: Int64)?
    let checkpoint: Bool
    switch input {
    case let .tick(seconds):
      guard let time = Self.timestamp(seconds: seconds) else { return }
      event = AutoSwitcherTimelineEvent(type: "tick", time: seconds, timeTicks: time.ticks)
      if let last = lastDirectorMediaTime, seconds + 1e-6 < last {
        sessionGeneration = sessionGeneration == .max ? .max : sessionGeneration + 1
      }
      lastDirectorMediaTime = seconds
      timestamp = time
      checkpoint = false
    case .reset:
      lastDirectorMediaTime = nil
      sessionGeneration = sessionGeneration == .max ? .max : sessionGeneration + 1
      for index in pending.values where document.cuts.indices.contains(index) {
        document.cuts[index].status = "cancelled"
      }
      pending.removeAll()
      currentCameraID = FeedID(rawValue: document.config.anchorCameraID)
      event = AutoSwitcherTimelineEvent(type: "reset")
      timestamp = nil
      checkpoint = false
    case let .manualOverride(cameraID, seconds):
      guard let time = Self.timestamp(seconds: seconds) else { return }
      for index in pending.values where document.cuts.indices.contains(index) {
        document.cuts[index].status = "cancelled"
      }
      pending.removeAll()
      document.cuts.append(AutoSwitcherTimelineCut(decisionID: nil,
        sessionGeneration: sessionGeneration,
        fromCameraID: currentCameraID.rawValue, targetCameraID: cameraID,
        requestedCutTime: time.seconds, requestedCutTimeTicks: time.ticks,
        appliedSourceTime: time.seconds, appliedSourceTimeTicks: time.ticks,
        appliedProgramTime: time.seconds, appliedProgramTimeTicks: time.ticks,
        expiresAt: nil, expiresAtTicks: nil, confidence: nil, reason: "manualOverride",
        forced: false, status: "applied"))
      currentCameraID = FeedID(rawValue: cameraID)
      lastDirectorMediaTime = seconds
      event = AutoSwitcherTimelineEvent(type: "manualOverride", time: seconds, timeTicks: time.ticks, cameraID: cameraID)
      timestamp = time
      checkpoint = false
    case let .health(cameraID, healthy, seconds):
      guard let time = Self.timestamp(seconds: seconds) else { return }
      if cameraID == document.config.anchorCameraID || cameraID == document.config.emphasisCameraID {
        lastDirectorMediaTime = max(lastDirectorMediaTime ?? seconds, seconds)
      }
      event = AutoSwitcherTimelineEvent(type: "video", observation:
        AutoSwitcherTimelineObservation(time: seconds, camera_id: cameraID, healthy: healthy))
      timestamp = time
      checkpoint = false
    case let .acknowledge(decisionID, seconds):
      timestamp = seconds.flatMap(Self.timestamp(seconds:))
      event = AutoSwitcherTimelineEvent(type: "acknowledge",
        time: timestamp?.seconds, timeTicks: timestamp?.ticks, decisionID: decisionID,
        appliedAt: timestamp?.seconds, appliedAtTicks: timestamp?.ticks)
      checkpoint = true
    case let .reject(decisionID):
      event = AutoSwitcherTimelineEvent(type: "reject", decisionID: decisionID)
      timestamp = nil
      checkpoint = true
    }
    append(event: event, mediaTime: timestamp, outputs: [], checkpoint: checkpoint)
  }

  func recordAudioCue(_ cue: AutoSwitcherAudioCue) {
    guard let timestamp = Self.timestamp(seconds: cue.time) else { return }
    append(event: AutoSwitcherTimelineEvent(type: "audio", cue: cue,
      time: timestamp.seconds, timeTicks: timestamp.ticks, decisionID: nil,
      appliedAt: nil, appliedAtTicks: nil, cameraID: nil), mediaTime: timestamp,
      outputs: [])
  }

  /// Records the same transcript cue delivered to the Rust director so an
  /// offline replay can reproduce transcript-assisted decisions exactly.
  func recordTranscript(_ cue: AutoSwitcherTranscriptCue) {
    guard cue.end >= cue.start,
      cue.start.isFinite, cue.end.isFinite, cue.start >= 0 else { return }
    guard let timestamp = Self.timestamp(seconds: cue.end) else { return }
    append(event: AutoSwitcherTimelineEvent(type: "transcript", transcript: cue,
      time: timestamp.seconds, timeTicks: timestamp.ticks, decisionID: nil,
      appliedAt: nil, appliedAtTicks: nil, cameraID: nil), mediaTime: timestamp,
      outputs: [])
  }

  func recordInstruction(_ instruction: AutoSwitcherInstruction, from source: FeedID?) {
    guard pending[instruction.decisionID] == nil,
      !document.instructions.contains(where: { $0.decisionID == instruction.decisionID }) else { return }
    guard let cut = Self.cutRecord(instruction: instruction, from: source ?? currentCameraID,
      timebase: document.timebase) else { return }
    sessionGeneration = instruction.sessionGeneration
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

  func markCutApplied(decisionID: UUID, target: FeedID, sourceTime: CMTime, programTime: CMTime) {
    guard let index = pending[decisionID], document.cuts.indices.contains(index),
      let source = Self.timestamp(sourceTime), let program = Self.timestamp(programTime) else { return }
    pending.removeValue(forKey: decisionID)
    document.cuts[index].status = "applied"
    document.cuts[index].appliedSourceTime = source.seconds
    document.cuts[index].appliedSourceTimeTicks = source.ticks
    document.cuts[index].appliedProgramTime = program.seconds
    document.cuts[index].appliedProgramTimeTicks = program.ticks
    currentCameraID = target
    revision &+= 1
  }

  func recordExpired(decisionID: UUID) {
    markCutRejected(decisionID: decisionID, expired: true)
    let output = AutoSwitcherTimelineOutput(type: "decisionExpired", instruction: nil,
      decisionID: decisionID, message: nil)
    append(event: AutoSwitcherTimelineEvent(type: "directorOutput", cue: nil,
      time: nil, timeTicks: nil, decisionID: decisionID, appliedAt: nil,
      appliedAtTicks: nil, cameraID: nil), mediaTime: nil, outputs: [output], checkpoint: true)
  }

  func markCutRejected(decisionID: UUID, expired: Bool = false) {
    guard let index = pending.removeValue(forKey: decisionID) else { return }
    document.cuts[index].status = expired ? "expired" : "rejected"
    revision &+= 1
  }

  func recordError(_ message: String) {
    let output = AutoSwitcherTimelineOutput(type: "error", instruction: nil,
      decisionID: nil, message: message)
    append(event: AutoSwitcherTimelineEvent(type: "directorOutput", cue: nil,
      time: nil, timeTicks: nil, decisionID: nil, appliedAt: nil,
      appliedAtTicks: nil, cameraID: nil), mediaTime: nil, outputs: [output], checkpoint: true)
  }

  func recordingStarted(feedID: FeedID, url: URL, mediaStart: CMTime?) {
    let id = UUID()
    recordingIDs[feedID] = id
    let start = mediaStart.flatMap(Self.timestamp)
    document.recordings.append(AutoSwitcherTimelineRecording(
      recordingID: id, cameraID: feedID.rawValue, path: url.path,
      kind: "source", format: url.pathExtension, mediaStart: start?.seconds, mediaEnd: nil))
    let index = sourceIndex(for: feedID)
    document.sources[index].mediaFile = url.path
    document.sources[index].mediaStart = start?.seconds
    document.sources[index].mediaEnd = nil
    revision &+= 1
    persistImmediately(urgent: true)
  }

  func recordingFinished(feedID: FeedID, url: URL?, mediaEnd: CMTime?) {
    guard let id = recordingIDs[feedID],
      let index = document.recordings.firstIndex(where: { $0.recordingID == id }) else { return }
    document.recordings[index].mediaEnd = mediaEnd.flatMap(Self.timestamp)?.seconds
    let source = sourceIndex(for: feedID)
    if let url { document.sources[source].mediaFile = url.path }
    document.sources[source].mediaEnd = document.recordings[index].mediaEnd
    recordingIDs.removeValue(forKey: feedID)
    revision &+= 1
    persistImmediately(urgent: true)
  }

  func finish() {
    if document.endedAtUnixMS == nil || !pending.isEmpty {
      for index in pending.values where document.cuts.indices.contains(index) {
        document.cuts[index].status = "cancelled"
      }
      pending.removeAll()
      document.endedAtUnixMS = document.endedAtUnixMS ?? Self.unixMS()
      revision &+= 1
    }
    persistImmediately(urgent: true)
  }

  private func sourceIndex(for feedID: FeedID) -> Int {
    if let index = document.sources.firstIndex(where: { $0.cameraID == feedID.rawValue }) { return index }
    document.sources.append(AutoSwitcherTimelineSource(cameraID: feedID.rawValue,
      role: "source", label: nil, mediaFile: nil, mediaStart: nil, mediaEnd: nil,
      timebase: document.timebase))
    return document.sources.count - 1
  }

  private func append(event: AutoSwitcherTimelineEvent, mediaTime: (seconds: Double, ticks: Int64)?,
                      outputs: [AutoSwitcherTimelineOutput], checkpoint: Bool = false) {
    document.duration = max(document.duration, mediaTime?.seconds ?? 0)
    unsubmittedEvents.append(AutoSwitcherTimelineEventRecord(sequence: nextSequence,
      mediaTime: mediaTime?.seconds, mediaTimeTicks: mediaTime?.ticks, event: event, outputs: outputs))
    nextSequence &+= 1
    document.eventsProcessed += 1
    revision &+= 1
    if checkpoint { persistImmediately() }
    else { maybePersist() }
  }

  private func takeEvents() -> [AutoSwitcherTimelineEventRecord] {
    let events = unsubmittedEvents
    unsubmittedEvents = []
    return events
  }

  private func maybePersist() {
    guard inFlightRevision == nil, !unsubmittedEvents.isEmpty else { return }
    if let retryAt {
      guard DispatchTime.now() >= retryAt else { return }
    } else {
      guard unsubmittedEvents.count >= 30 else { return }
    }
    let document = self.document
    let events = takeEvents()
    let url = outputURL
    let folder = self.folder
    let revision = self.revision
    inFlightRevision = revision
    writer.queue.async { [writer, weak self] in
      let result = writer.write(document, events: events, to: url, folder: folder, revision: revision, urgent: false)
      Task { @MainActor [weak self] in
        guard let self, self.inFlightRevision == revision else { return }
        self.inFlightRevision = nil
        self.didPersist(result, revision: revision)
        self.maybePersist()
      }
    }
  }

  private func persistImmediately(urgent: Bool = false) {
    if !urgent, let retryAt, DispatchTime.now() < retryAt { return }
    // Drain any older checkpoint before publishing the newer snapshot.
    let document = self.document
    let events = takeEvents()
    let url = outputURL
    let folder = self.folder
    inFlightRevision = nil
    let result = writer.queue.sync {
      writer.write(document, events: events, to: url, folder: folder, revision: revision, urgent: urgent)
    }
    didPersist(result, revision: revision)
  }

  private func didPersist(_ result: AutoSwitcherTimelineWriter.Result, revision: UInt64) {
    switch result {
    case .written:
      persistedRevision = revision
      retryAt = nil
      announcedError = nil
    case .failed(let message, let retryAt):
      // Recording remains usable if the optional sidecar cannot be written.
      self.retryAt = retryAt
      lastError = message
      if announcedError != message, let onError {
        announcedError = message
        onError(message)
      }
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

  private static func timestamp(seconds: Double) -> (seconds: Double, ticks: Int64)? {
    guard let projected = AutoSwitcherBridge.instructionTime(seconds: seconds) else { return nil }
    return (seconds, projected.value)
  }

  private static func makeOutputURL(folder: URL?) -> URL {
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
