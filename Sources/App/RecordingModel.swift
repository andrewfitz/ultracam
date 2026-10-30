import Foundation
import Observation
import CoreMedia
import CoreVideo

/// The codecs exposed by the recording UI. The media writer is injected through
/// `RecordingSessionDriver`, so this model does not own capture or file I/O.
enum RecordingCodec: String, CaseIterable, Codable, Equatable, Sendable {
  case proResLT, proRes422, proRes42210Bit, proRes4444
  case hevcMain, hevcMain10, hevcMain10_422

  var matrixProfile: RecordingProfileMatrixProfile {
    switch self {
    case .proResLT: return .proResLT
    case .proRes422: return .proRes422
    case .proRes42210Bit: return .proRes422HQ
    case .proRes4444: return .proRes4444
    case .hevcMain: return .hevcMain
    case .hevcMain10: return .hevcMain10
    case .hevcMain10_422: return .hevcMain10_422
    }
  }
  var title: String { matrixProfile.displayName }
  var fileExtension: String { "mov" }
  var sizeEstimatorCodec: RecordingSizeEstimator.Codec {
    switch self {
    case .proResLT: return .proResLT
    case .proRes422: return .proRes422
    case .proRes42210Bit: return .proRes422HQ
    case .proRes4444: return .proRes4444
    case .hevcMain: return .hevcMain
    case .hevcMain10: return .hevcMain10
    case .hevcMain10_422: return .hevcMain10_422
    }
  }
  func isAvailable(for source: SourceFormat) -> Bool { RecordingProfileMatrix.supports(matrixProfile, source: source) }
  static func available(for source: SourceFormat) -> [Self] { allCases.filter { $0.isAvailable(for: source) } }

}

enum RecordingTimecodeMode: String, CaseIterable, Codable, Equatable, Sendable {
  case source
  case recordStart
  case wallClock

  var title: String {
    switch self {
    case .source: return "Source timecode"
    case .recordStart: return "Record start"
    case .wallClock: return "PC time"
    }
  }

  var help: String {
    switch self {
    case .source:
      return "Preserves available native source timecode. Variable-rate or late-arriving labels are retained in the sidecar when no movie timecode track exists."
    case .recordStart:
      return "Writes a timecode track that starts at 00:00:00:00."
    case .wallClock:
      return "Writes the computer's clock into the file, aligned to the first frame."
    }
  }
}

struct RecordingConfiguration: Equatable, Sendable {
  var codec: RecordingCodec = .proRes42210Bit
  var outputFolder: URL?
  var timecodeMode: RecordingTimecodeMode = .wallClock
  var feedName: String?
  var compatibilityPolicy = RecordingCompatibilityPolicy()
  var recordingConstantFrameRate = false
  /// Explicit bounded rounding for variable source timestamps; sampled per take.
  var variableRateQuantizationPolicy: RecordingTimebase.QuantizationPolicy = .nearest240000

  init(codec: RecordingCodec = .proRes42210Bit, outputFolder: URL? = nil,
    timecodeMode: RecordingTimecodeMode = .wallClock, feedName: String? = nil,
    compatibilityPolicy: RecordingCompatibilityPolicy = .init(),
    recordingConstantFrameRate: Bool = false,
    variableRateQuantizationPolicy: RecordingTimebase.QuantizationPolicy = .nearest240000) {
    self.recordingConstantFrameRate = recordingConstantFrameRate
    self.variableRateQuantizationPolicy = variableRateQuantizationPolicy
    self.codec = codec
    self.outputFolder = outputFolder
    self.timecodeMode = timecodeMode
    self.feedName = feedName
    self.compatibilityPolicy = compatibilityPolicy
  }
}

struct RecordingFeedDescriptor: Identifiable, Hashable, Sendable {
  let id: FeedID
  var name: String

  var recordingConstantFrameRate: Bool
  init(id: FeedID, name: String, recordingConstantFrameRate: Bool = false) {
    self.id = id
    self.name = name
    self.recordingConstantFrameRate = recordingConstantFrameRate
  }
}

enum RecordingStatus: String, Equatable, Sendable {
  case idle
  case recording
  case paused
  case finishing

  var title: String {
    switch self {
    case .idle: return "Idle"
    case .recording: return "Recording"
    case .paused: return "Paused"
    case .finishing: return "Finishing…"
    }
  }
}

struct RecordingFeedState: Identifiable, Equatable, Sendable {
  let id: FeedID
  var name: String
  var status: RecordingStatus = .idle
  var error: String?

  var statistics: RecordingStatistics?
  /// The last take that finished and was written, kept until the next take starts.
  var savedURL: URL?
  /// Record was pressed and the take is being prepared off the main thread
  /// (output file, encoder). `status` is already `.recording`; capture
  /// connects to the recorder only once it is ready.
  var isStarting = false
  var isActive: Bool { status != .idle }
  var displayStatus: String {
    if statistics?.failed == true { return "Failed" }
    if isStarting && status == .recording { return "Starting…" }
    if status == .idle && statistics != nil { return error == nil ? "Finished" : "Failed" }
    if status == .recording && statistics?.encodedFrames == 0 { return "Waiting for video" }
    return status.title
  }
}

enum RecordingUIError: LocalizedError, Equatable {
  case unavailable
  case outputFolderRequired
  case rawAudioUnavailable
  case feedNotActive

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Recording is unavailable until a recording backend is connected."
    case .outputFolderRequired: return "Choose an output folder before recording."
    case .rawAudioUnavailable:
      return "Raw input audio recording is unavailable; video will be recorded without audio."
    case .feedNotActive:
      return "Start this camera before recording it. Only a running camera can produce media."
    }
  }
}

/// The small boundary between controls and a future media writer.
/// Implementations are called on the main actor by `RecordingModel`.
protocol RecordingSessionDriver: AnyObject {
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws
  /// Starts a take without blocking the caller: the slow part (output file,
  /// encoder session, GPU converter) may run elsewhere. `completion` runs on
  /// the main actor once the take records or has failed to start.
  @MainActor func startRecording(feedID: FeedID, configuration: RecordingConfiguration,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void)
  func pauseRecording(feedID: FeedID) throws
  func resumeRecording(feedID: FeedID) throws
  func stopRecording(feedID: FeedID) throws
  @MainActor func stopRecording(feedID: FeedID,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void)
}

extension RecordingSessionDriver {
  @MainActor func startRecording(feedID: FeedID, configuration: RecordingConfiguration,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
    completion(Result { try startRecording(feedID: feedID, configuration: configuration) })
  }

  @MainActor func stopRecording(feedID: FeedID,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
    completion(Result { try stopRecording(feedID: feedID) })
  }
}

/// Optional diagnostics exposed by a driver after a successful start. Keeping
/// this separate from `RecordingSessionDriver` preserves the small injected
/// test boundary and lets older drivers continue to work unchanged.
protocol RecordingSessionDriverDiagnostics: AnyObject {
  var startWarning: RecordingUIError? { get }
}

protocol RecordingSessionDriverStatistics: AnyObject {
  @MainActor func recordingStatistics() async -> [FeedID: RecordingStatistics]
}

protocol RecordingSessionDriverArtifacts: AnyObject {
  func recordingOutputURL(feedID: FeedID) -> URL?
  /// Where the feed's last finalized take was written. A take stopped while
  /// it was still starting has no live output to ask for.
  func finishedOutputURL(feedID: FeedID) -> URL?
}

extension RecordingSessionDriverArtifacts {
  func finishedOutputURL(feedID: FeedID) -> URL? { nil }
}

/// Native source recorder used by the app. Each feed owns one callback adapter
/// and one `SourceRecorderCore`, so pause/stop on one feed cannot affect any
/// other feed. Capture callbacks are connected only after the adapter starts.
final class NativeRecordingSessionDriver: RecordingSessionDriver, RecordingSessionDriverDiagnostics,
  RecordingSessionDriverArtifacts, RecordingSessionDriverStatistics, @unchecked Sendable {
  typealias RecorderFactory = (SourceRecordingConfiguration) throws -> SourceRecorderCore

  // The immutable session crosses to a finalization worker. Its recorder and
  // output own their synchronization; the catalog is protected by sessionLock.
  private struct Session: @unchecked Sendable {
    let adapter: SourceRecordingCallbackAdapter
    let feedID: FeedID
    /// The AVAssetWriter writes into this session's temporary path. Keeping
    /// the owner here guarantees that its reservation survives until the
    /// writer is finalized or cancelled.
    let output: RecordingOutputSession
    let folderAccess: RecordingFolderAccess
    let compatibilityPolicy: RecordingCompatibilityPolicy
    let clock = RecordingSessionClock()
    let statistics = StatisticsOwner()
  }

  private final class StatisticsOwner: @unchecked Sendable {
    let lock = NSLock()
    var sampler = RecordingStatisticsSampler()
  }

  // Hold the selected directory's permission until its writer and final
  // rename have both finished, even if the user selects another folder.
  private final class RecordingFolderAccess {
    let url: URL
    private let accessed: Bool
    init(_ url: URL) {
      self.url = url
      accessed = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
  }

  private let captureForFeed: (FeedID) -> CaptureController
  private let recorderFactory: RecorderFactory
  private let rawAudioCallbackAvailable: Bool
  // Capture callbacks may arrive off the main actor while the recording
  // controls start/stop sessions on it. Keep the catalog and the output
  // reservations behind one lock so a callback can never race a session
  // teardown. Managers are shared by folder/extension (path allocation);
  // free-space reservations and headroom are pooled per volume across every
  // manager (`RecordingVolumeSpaceRegistry`), so feeds recording to
  // different folders on one drive are all counted against its free space.
  private let sessionLock = NSLock()
  private var sessions: [FeedID: Session] = [:]
  private var stoppingFeeds = Set<FeedID>()
  /// Feeds whose take is being prepared on a worker, and stops that arrived
  /// meanwhile (run by that worker once the take exists).
  private var startingFeeds = Set<FeedID>()
  private var stopsAfterStart: [FeedID: [StopCompletion]] = [:]
  private var completedStatistics: [FeedID: RecordingStatistics] = [:]
  private var finishedOutputs: [FeedID: URL] = [:]
  private var outputManagers: [String: RecordingOutputManager] = [:]

  init(captureForFeed: @escaping (FeedID) -> CaptureController, rawAudioCallbackAvailable: Bool = false,
    recorderFactory: @escaping RecorderFactory = { try SourceRecorderCore(configuration: $0) }) {
    self.captureForFeed = captureForFeed
    self.rawAudioCallbackAvailable = rawAudioCallbackAvailable
    self.recorderFactory = recorderFactory
    // The first take would otherwise compile the GPU repack kernel at start.
    RecordingPixelConverter.prewarm()
  }

  var startWarning: RecordingUIError? {
    rawAudioCallbackAvailable ? nil : .rawAudioUnavailable
  }

  func recordingOutputURL(feedID: FeedID) -> URL? {
    sessionLock.withLock { sessions[feedID]?.output.finalURL }
  }

  func finishedOutputURL(feedID: FeedID) -> URL? {
    sessionLock.withLock { finishedOutputs[feedID] }
  }

  // MARK: Start

  typealias StopCompletion = @MainActor @Sendable (Result<Void, Error>) -> Void

  /// What the main actor resolved for a start; the rest runs on a worker.
  private struct StartRequest: @unchecked Sendable {
    let feedID: FeedID
    let configuration: RecordingConfiguration
    let folder: URL
    let capture: CaptureController
    let sourceTimecode: String?
    let takeContext: RecordingTakeContext?
    let videoFormat: SourceFormat?
    let nativeTimecode: Timecode?
  }

  /// Synchronous start, for callers that may block (tests, tools).
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
    let request = try beginStart(feedID: feedID, configuration: configuration)
    let (result, stops, stopResult) = completeStart(request)
    if !stops.isEmpty {
      DispatchQueue.main.async { for stop in stops { stop(stopResult ?? .success(())) } }
    }
    try result.get()
  }

  /// Returns at once. The output file, the recorder and its encoder (about
  /// 100 ms cold, more if the GPU converter is still compiling) are prepared
  /// on a worker; capture connects to the recorder only once it is ready, so
  /// no frame waits for the encoder and none is lost at the start.
  @MainActor func startRecording(feedID: FeedID, configuration: RecordingConfiguration,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
    let request: StartRequest
    do { request = try beginStart(feedID: feedID, configuration: configuration) }
    catch { completion(.failure(error)); return }
    DispatchQueue.global(qos: .userInitiated).async {
      let (result, stops, stopResult) = self.completeStart(request)
      DispatchQueue.main.async {
        completion(result)
        for stop in stops { stop(stopResult ?? .success(())) }
      }
    }
  }

  /// Caller's thread (the main actor for the app): cheap checks, then the
  /// feed's slot is claimed so a second start or a stop sees it.
  private func beginStart(feedID: FeedID, configuration: RecordingConfiguration) throws -> StartRequest {
    let capture = captureForFeed(feedID)
    guard !capture.hasActiveFeed || capture.isAccepting(feedID: feedID) else {
      throw RecordingUIError.feedNotActive
    }
    guard sessionLock.withLock({ sessions[feedID] == nil && !startingFeeds.contains(feedID) }) else {
      throw SourceRecordingError.invalidState(.recording, operation: "start recording")
    }
    guard let folder = configuration.outputFolder else {
      throw RecordingUIError.outputFolderRequired
    }
    try sessionLock.withLock {
      guard sessions[feedID] == nil, startingFeeds.insert(feedID).inserted else {
        throw SourceRecordingError.invalidState(.recording, operation: "start recording")
      }
      completedStatistics.removeValue(forKey: feedID)
      finishedOutputs.removeValue(forKey: feedID)
    }
    // Only record-start timecode follows the camera's drop-frame flag.
    return StartRequest(feedID: feedID, configuration: configuration, folder: folder, capture: capture,
      sourceTimecode: configuration.timecodeMode == .recordStart ? capture.latestSourceTimecode : nil,
      takeContext: capture.recordingTakeContext, videoFormat: capture.recordingVideoFormat,
      nativeTimecode: capture.latestNativeTimecode)
  }

  /// Worker: builds and starts the session, then publishes it. A stop that
  /// arrived meanwhile finalizes it here, before capture ever connects.
  private func completeStart(_ request: StartRequest)
    -> (Result<Void, Error>, [StopCompletion], Result<Void, Error>?) {
    let prepared = Result { try prepareSession(request) }
    let (stops, session) = sessionLock.withLock { () -> ([StopCompletion], Session?) in
      startingFeeds.remove(request.feedID)
      let stops = stopsAfterStart.removeValue(forKey: request.feedID) ?? []
      guard case let .success(session) = prepared else { return (stops, nil) }
      sessions[request.feedID] = session
      if stops.isEmpty {
        // Installed under the session lock: a stop that finds this session
        // removes the callbacks only after they are in place.
        request.capture.setRecordingCallbacks(feedID: request.feedID, callbacks: session.adapter.callbacks)
      } else {
        stoppingFeeds.insert(request.feedID)
      }
      return (stops, session)
    }
    guard let session else {
      if case let .failure(error) = prepared { return (.failure(error), stops, nil) }
      return (.success(()), stops, nil)
    }
    guard !stops.isEmpty else { return (.success(()), [], nil) }
    session.clock.pause()
    return (.success(()), stops, Result { try finalize(session, feedID: request.feedID) })
  }

  static func nativeTimecodeMetadata(_ timecode: Timecode?, rate: FrameRate?) -> TimecodeMetadata? {
    guard let timecode, let rate, !rate.isVariable,
      let exactRate = RecordingFrameRate(numerator: Int64(rate.nominal.timescale), denominator: rate.nominal.value) else { return nil }
    let separator = timecode.dropFrame ? ";" : ":"
    let label = String(format: "%02d:%02d:%02d%@%02d", timecode.hours, timecode.minutes,
      timecode.seconds, separator, timecode.frames)
    return TimecodeMetadata(label: label, frameRate: exactRate)
  }

  static func legacyFrameRate(for rate: FrameRate?) -> RecordingFrameRate {
    guard let rate else { return .fps5994 }
    return RecordingFrameRate(numerator: Int64(rate.nominal.timescale), denominator: rate.nominal.value) ?? .fps5994
  }

  /// Worker: the output reservation (file system), the recorder and its
  /// prepared encoder.
  private func prepareSession(_ request: StartRequest) throws -> Session {
    let folderAccess = RecordingFolderAccess(request.folder)
    // Allocate a per-feed atomic output before creating the writer. The
    // writer only sees the temporary path; a completed session is renamed to
    // its final path after all queued samples have drained.
    let outputManager = try manager(for: request.folder, fileExtension: request.configuration.codec.fileExtension)
    let output = try outputManager.beginExternalWriterSession(
      feedID: Self.safeComponent(request.configuration.feedName ?? "Feed"))
    do {
      let sourceConfiguration = try SourceRecordingConfiguration(
        feedID: SourceRecordingFeedID(request.feedID.rawValue), outputURL: output.temporaryURL,
        width: request.videoFormat?.width ?? 3840,
        height: request.videoFormat?.height ?? 2160,
        videoCodec: request.configuration.codec.matrixProfile.codec,
        videoProfile: .matrix(request.configuration.codec.matrixProfile),
        frameRate: Self.legacyFrameRate(for: request.videoFormat?.rate),
        quantizationPolicy: request.videoFormat?.rate.isVariable == true
          ? request.configuration.variableRateQuantizationPolicy : nil,
        sourceFrameRate: request.videoFormat?.rate,
        recordingConstantFrameRate: request.configuration.recordingConstantFrameRate,
        nativeTimecodeMetadata: Self.nativeTimecodeMetadata(request.nativeTimecode,
          rate: request.videoFormat?.rate),
        timecodePolicy: Self.timecodePolicy(for: request.configuration.timecodeMode),
        sourceTimecode: request.sourceTimecode,
        timecodeSamplesComputerClockAtFirstFrame: request.configuration.timecodeMode == .wallClock,
        checkAvailableSpace: { try output.checkExternalWriterCapacity(headroom: $0) },
        sourceAdmission: request.takeContext?.sourceAdmission,
        expectedSourceFormat: request.videoFormat,
        compatibilityPolicy: request.configuration.compatibilityPolicy, sidecarMovieURL: output.finalURL,
        sidecarCreated: { try output.claimSidecar() })
      let recorder = try recorderFactory(sourceConfiguration)
      let adapter = SourceRecordingCallbackAdapter(feedID: sourceConfiguration.feedID, recorder: recorder)
      try adapter.start()
      return Session(adapter: adapter, feedID: request.feedID, output: output, folderAccess: folderAccess,
        compatibilityPolicy: request.configuration.compatibilityPolicy)
    } catch {
      try? output.cancel()
      throw error
    }
  }

  func pauseRecording(feedID: FeedID) throws {
    guard let session = sessionLock.withLock({ sessions[feedID] }) else {
      throw SourceRecordingError.invalidState(.idle, operation: "pause recording")
    }
    try session.adapter.pause()
    do {
      try session.output.pause()
      session.clock.pause()
    } catch {
      // Keep the recorder usable if the filesystem pause operation fails.
      try? session.adapter.resume()
      throw error
    }
  }

  func resumeRecording(feedID: FeedID) throws {
    guard let session = sessionLock.withLock({ sessions[feedID] }) else {
      throw SourceRecordingError.invalidState(.idle, operation: "resume recording")
    }
    try session.output.resume()
    do {
      try session.adapter.resume()
      session.clock.resume()
    } catch {
      try? session.output.pause()
      throw error
    }
  }

  // MARK: Stop

  private enum StopPlan {
    case nothing
    case afterStart
    case session(Session)
  }

  func stopRecording(feedID: FeedID) throws {
    switch try beginStop(feedID: feedID, deferring: nil) {
    case .nothing, .afterStart: return
    case let .session(session): try finalize(session, feedID: feedID)
    }
  }

  @MainActor func stopRecording(feedID: FeedID,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
    do {
      // Resolve the app-owned capture controller on the caller's main actor.
      // Only detached media finalization crosses to the worker.
      switch try beginStop(feedID: feedID, deferring: completion) {
      case .nothing: completion(.success(()))
      case .afterStart: break  // The starting worker finalizes and calls back.
      case let .session(session):
        DispatchQueue.global(qos: .userInitiated).async {
          let result = Result { try self.finalize(session, feedID: feedID) }
          DispatchQueue.main.async { completion(result) }
        }
      }
    } catch { completion(.failure(error)) }
  }

  private func beginStop(feedID: FeedID, deferring completion: StopCompletion?) throws -> StopPlan {
    let plan = try sessionLock.withLock { () throws -> StopPlan in
      if startingFeeds.contains(feedID) {
        guard let completion, stopsAfterStart[feedID] == nil else {
          throw SourceRecordingError.invalidState(.stopping, operation: "stop recording")
        }
        stopsAfterStart[feedID] = [completion]
        return .afterStart
      }
      guard let session = sessions[feedID] else { return .nothing }
      guard stoppingFeeds.insert(feedID).inserted else {
        throw SourceRecordingError.invalidState(.stopping, operation: "stop recording")
      }
      return .session(session)
    }
    guard case let .session(session) = plan else { return plan }
    session.clock.pause()
    captureForFeed(feedID).setRecordingCallbacks(feedID: feedID, callbacks: nil)
    return plan
  }

  /// Audio may be staged before the first picture. It cannot start a movie.
  static func canPublishMovie(appendedVideo: UInt64) -> Bool { appendedVideo > 0 }

  private func finalize(_ session: Session, feedID: FeedID) throws {
    defer {
      let final = snapshot(session, stopped: true)
      sessionLock.withLock {
        completedStatistics[feedID] = final
        finishedOutputs[feedID] = session.output.finalURL
        sessions.removeValue(forKey: feedID)
        stoppingFeeds.remove(feedID)
      }
    }
    var stopError: Error?
    do {
      try session.adapter.stop()
    } catch {
      stopError = error
    }
    let telemetry = session.adapter.telemetry
    let hadVideo = Self.canPublishMovie(appendedVideo: telemetry.appendedVideo)
    // A failed flush must never publish an unfinished movie as a successful
    // take, nor delete its completed fragments. Recovery owns it after stop.
    do {
      if stopError != nil || session.adapter.state == .failed {
        session.output.preserveForRecovery()
      } else if hadVideo {
        _ = try session.output.finish()
      } else {
        try session.output.cancel()
      }
    } catch {
      session.output.preserveForRecovery()
      throw stopError ?? error
    }
    if let stopError { throw stopError }
    if session.adapter.state == .failed {
      throw SourceRecordingError.writerFailure(telemetry.lastError
        ?? "Recording stopped after a source error.")
    }
  }

  @MainActor func recordingStatistics() async -> [FeedID: RecordingStatistics] {
    await Task.detached(priority: .utility) { [self] in
      let (live, completed) = sessionLock.withLock { (sessions, completedStatistics) }
      var result = completed
      for (id, session) in live { result[id] = snapshot(session) }
      return result
    }.value
  }

  private func snapshot(_ session: Session, stopped: Bool = false) -> RecordingStatistics {
    // File I/O and telemetry locks stay on a worker, including final snapshots.
    session.statistics.lock.withLock {
      let url = FileManager.default.fileExists(atPath: session.output.finalURL.path)
        ? session.output.finalURL : session.output.temporaryURL
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      let bytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
      return session.statistics.sampler.sample(session.adapter.telemetry,
        elapsed: session.clock.elapsed, fileBytes: bytes, fileURL: url, stopped: stopped, compatibilityPolicy: session.compatibilityPolicy)
    }
  }

  private static func safeComponent(_ value: String) -> String {
    let words = value.split(whereSeparator: { character in
      !(character.isLetter || character.isNumber || character == "-" || character == "_")
    })
    let result = String(words.joined(separator: " ").prefix(80))
      .trimmingCharacters(in: .whitespaces)
    return result.isEmpty ? "Feed" : result
  }

  private func manager(for folder: URL, fileExtension: String) throws -> RecordingOutputManager {
    let root = folder.standardizedFileURL.resolvingSymlinksInPath()
    let key = "\(root.path)\u{0}\(fileExtension.lowercased())"
    sessionLock.lock()
    defer { sessionLock.unlock() }
    if let existing = outputManagers[key] { return existing }
    let manager = try RecordingOutputManager(rootDirectory: root, fileExtension: fileExtension)
    outputManagers[key] = manager
    return manager
  }

  private static func timecodePolicy(for mode: RecordingTimecodeMode) -> RecordingTimecodePolicy {
    switch mode {
    case .source: return .source
    case .recordStart: return .recordStart
    case .wallClock: return .wallClock
    }
  }
}

final class UnavailableRecordingSessionDriver: RecordingSessionDriver {
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
    throw RecordingUIError.unavailable
  }

  func pauseRecording(feedID: FeedID) throws { throw RecordingUIError.unavailable }
  func resumeRecording(feedID: FeedID) throws { throw RecordingUIError.unavailable }
  func stopRecording(feedID: FeedID) throws { throw RecordingUIError.unavailable }
}

@MainActor @Observable
final class RecordingModel {
  var codec: RecordingCodec = .proRes42210Bit
  var outputFolder: URL? {
    didSet {
      do { try folderStore?.save(outputFolder) }
      catch { recoveryMessage = "Choose the recording folder again after restarting: \(error.localizedDescription)" }
      onOutputFolderChanged?(outputFolder)
      refreshRecovery()
    }
  }
  private(set) var interruptedRecordings: [InterruptedRecording] = []
  private(set) var recoveringID: URL?
  private(set) var recoveryMessage: String? { didSet { recoveryMessageIsScanError = false } }
  /// The current message is an earlier scan's failure. Only that kind clears on a
  /// successful scan; folder warnings and recovery results stay until replaced.
  private var recoveryMessageIsScanError = false
  private(set) var recoveredURL: URL?
  private let folderStore: RecordingFolderStore?
  private var recoveryScanGeneration = 0
  private var feedOutputFolders: [FeedID: URL] = [:]
  /// Original bookmarked roots survive changes to next-take destinations.
  private var activeTakeFolders: [FeedID: URL] = [:]
  private var retainedTakeRoots: [String: URL] = [:]
  private var activeRecoveryRoot: URL?
  private var feedConstantFrameRate: [FeedID: Bool] = [:]
  private var loadedFolderFeedIDs = Set<FeedID>()
  private var interruptedRecordingRoots: [URL: URL] = [:]
  var timecodeMode: RecordingTimecodeMode = .wallClock
  /// Copied into RecordingConfiguration before asynchronous take preparation.
  var compatibilityPolicy = RecordingCompatibilityPolicy()
  /// Observers are told when a take's state changes; its running statistics (2 Hz) are
  /// stored without telling them (`RecordingStatisticsState`) and published as telemetry.
  private(set) var feeds: [RecordingFeedState] = []
  /// The takes' running statistics, for the views that show them (`liveStatistics`).
  @ObservationIgnored let telemetry = UITelemetryStore()

  var onOutputFolderChanged: ((URL?) -> Void)?
  var onRecordingStarted: ((FeedID, URL) -> Void)?
  var onRecordingFinished: ((FeedID, URL?) -> Void)?
  /// A take paused (`true`) or resumed (`false`).
  var onRecordingPaused: ((FeedID, Bool) -> Void)?

  private let driver: RecordingSessionDriver
  private let resolveFinishedFile: (URL?, URL?) -> URL?
  private var finishedCallbacks: [() -> Void] = []
  @ObservationIgnored private var statisticsTask: Task<Void, Never>?
  private var recordingGenerations: [FeedID: UInt64] = [:]

  init(feeds: [RecordingFeedDescriptor] = [], driver: RecordingSessionDriver = UnavailableRecordingSessionDriver(),
    folderStore: RecordingFolderStore? = nil,
    resolveFinishedFile: @escaping (URL?, URL?) -> URL? = RecordingModel.existingFile) {
    self.resolveFinishedFile = resolveFinishedFile
    self.driver = driver
    self.folderStore = folderStore
    updateFeeds(feeds)
    do {
      for root in try folderStore?.loadRecoveryRoots() ?? [] {
        retainedTakeRoots[root.standardizedFileURL.path] = root
      }
      if let warnings = folderStore?.recoveryRootWarnings, !warnings.isEmpty {
        recoveryMessage = "Choose original recording folders again to check interrupted recordings: " + warnings.joined(separator: ", ")
      }
    } catch { recoveryMessage = "Choose the original recording folder to check interrupted recordings: \(error.localizedDescription)" }
    do { _outputFolder = try folderStore?.load() }
    catch { recoveryMessage = "Choose your recording folder to check for interrupted recordings." }
    refreshRecovery()
  }

  func refreshRecovery(clearMessage: Bool = true) {
    recoveryScanGeneration += 1
    let generation = recoveryScanGeneration
    var seenPaths = Set<String>()
    // Keep the original bookmarked URLs so their sandbox grants survive.
    let roots = ([outputFolder].compactMap { $0 } + Array(feedOutputFolders.values) + Array(retainedTakeRoots.values))
      .filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
      .sorted { $0.path < $1.path }
    guard !roots.isEmpty else {
      interruptedRecordings = []
      interruptedRecordingRoots = [:]
      return
    }
    Task { [weak self] in
      let results = await Task.detached(priority: .utility) {
        roots.map { root in (root, Result { try RecordingRecovery.scanReport(root: root) }) }
      }.value
      guard let self, self.recoveryScanGeneration == generation else { return }
      var takesByID: [URL: InterruptedRecording] = [:]
      self.interruptedRecordingRoots = [:]
      if clearMessage, self.recoveryMessageIsScanError {
        self.recoveryMessage = nil
      }
      for (root, result) in results {
        switch result {
        case let .success(report):
          let takes = report.takes
          if !report.mayPruneRoot {
            // Discovery also restores access after a folder is reselected. Keep
            // its original grant, including when a journal is currently busy,
            // before next-take destinations can replace this scan's roots.
            self.retainedTakeRoots[root.standardizedFileURL.path] = root
          } else if self.activeRecoveryRoot?.resolvingSymlinksInPath().path != root.resolvingSymlinksInPath().path && !self.activeTakeFolders.values.contains(where: { $0.standardizedFileURL.path == root.standardizedFileURL.path }) {
            self.retainedTakeRoots.removeValue(forKey: root.standardizedFileURL.path)
          }
          for take in takes {
            takesByID[take.id] = take
            self.interruptedRecordingRoots[take.id] = root
          }
        case let .failure(error):
          self.recoveryMessage = "Could not check interrupted recordings in \(root.path): \(error.localizedDescription)"
          self.recoveryMessageIsScanError = true
        }
      }
      do { try self.folderStore?.saveRecoveryRoots(Array(self.retainedTakeRoots.values)) }
      catch { self.recoveryMessage = "Could not save recovery folder access: \(error.localizedDescription)" }
      self.interruptedRecordings = takesByID.values.sorted { $0.id.path < $1.id.path }
    }
  }

  func recover(_ take: InterruptedRecording) {
    guard recoveringID == nil, let root = interruptedRecordingRoots[take.id] else { return }
    recoveringID = take.id
    activeRecoveryRoot = root
    recoveryMessage = nil
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        do { return Result<URL, Error>.success(try await RecordingRecovery.recover(take, root: root)) }
        catch { return .failure(error) }
      }.value
      guard let self else { return }
      self.recoveringID = nil
      self.activeRecoveryRoot = nil
      switch result {
      case let .success(url):
        self.recoveredURL = url
        self.recoveryMessage = "Recovered \(url.lastPathComponent). The interrupted original has been kept."
      case let .failure(error): self.recoveryMessage = error.localizedDescription
      }
      self.refreshRecovery(clearMessage: false)
    }
  }

  var configuration: RecordingConfiguration {
    RecordingConfiguration(codec: codec, outputFolder: outputFolder, timecodeMode: timecodeMode,
      compatibilityPolicy: compatibilityPolicy)
  }

  func customOutputFolder(for feedID: FeedID) -> URL? { feedOutputFolders[feedID] }

  func outputFolder(for feedID: FeedID) -> URL? { feedOutputFolders[feedID] ?? outputFolder }

  /// Folder changes apply to the next take; an active writer retains its grant.
  func setOutputFolder(_ folder: URL?, for feedID: FeedID) {
    feedOutputFolders[feedID] = folder
    loadedFolderFeedIDs.insert(feedID)
    do { try folderStore?.save(folder, feedID: feedID.rawValue) }
    catch { recoveryMessage = "Choose this camera's recording folder again after restarting: \(error.localizedDescription)" }
    refreshRecovery()
  }

  var canRecordAny: Bool {
    feeds.contains { $0.status == .idle && outputFolder(for: $0.id) != nil }
  }

  var canPauseAny: Bool { feeds.contains { $0.status == .recording && !$0.isStarting } }
  var canStopAny: Bool { feeds.contains { $0.status == .recording || $0.status == .paused } }
  var hasActiveRecordings: Bool { feeds.contains(where: \.isActive) }

  /// Replace descriptors when the feed coordinator changes while retaining
  /// active state and errors for feeds that still exist. Keep an active state
  /// for a descriptor that disappeared until its recording is stopped; this
  /// prevents an in-flight session from becoming unreachable (and leaking its
  /// writer/output reservation) when a feed list refresh races recording.
  func updateFeeds(_ descriptors: [RecordingFeedDescriptor]) {
    // Feed discovery can briefly publish duplicate descriptors while a route
    // is being rebuilt. Building a dictionary with `uniqueKeysWithValues:`
    // would trap on that transient state and take down the recording UI.
    var old: [FeedID: RecordingFeedState] = [:]
    for state in feeds { old[state.id] = state }
    var seen = Set<FeedID>()
    feedConstantFrameRate = Dictionary(descriptors.map { ($0.id, $0.recordingConstantFrameRate) }, uniquingKeysWith: { first, _ in first })
    feeds = descriptors.compactMap { descriptor in
      guard seen.insert(descriptor.id).inserted else { return nil }
      var state = old[descriptor.id] ?? RecordingFeedState(id: descriptor.id, name: descriptor.name)
      state.name = descriptor.name
      return state
    }
    let retainedIDs = Set(descriptors.map(\.id))
    // Per-feed folders are keyed by the stable feed ID. Once a feed is gone,
    // discard its in-memory choice and persisted sandbox bookmark as well.
    // Keep the choice briefly for an active take that disappeared during a
    // topology refresh; its stop callback still needs the folder to resolve
    // the finished output. A later refresh removes it after the take is idle.
    let activeRetainedIDs = old.values
      .filter { $0.isActive && !retainedIDs.contains($0.id) }
      .map(\.id)
    let removableFolderIDs = Set(feedOutputFolders.keys)
      .subtracting(retainedIDs)
      .subtracting(activeRetainedIDs)
    for feedID in removableFolderIDs {
      feedOutputFolders.removeValue(forKey: feedID)
      loadedFolderFeedIDs.remove(feedID)
      try? folderStore?.save(nil, feedID: feedID.rawValue)
    }
    feeds.append(contentsOf: old.values
      .filter { $0.isActive && !retainedIDs.contains($0.id) }
      .sorted { $0.id.rawValue < $1.id.rawValue })
    var restoredFolder = false
    for descriptor in descriptors where loadedFolderFeedIDs.insert(descriptor.id).inserted {
      do {
        if let folder = try folderStore?.load(feedID: descriptor.id.rawValue) {
          feedOutputFolders[descriptor.id] = folder
          restoredFolder = true
        }
      }
      catch { recoveryMessage = "Choose the recording folder for \(descriptor.name) again." }
    }
    if restoredFolder { refreshRecovery() }
  }

  /// Returns at once: the take shows "Starting…" while the driver prepares
  /// it off the main actor, then records. Stop during the start is honoured
  /// as soon as the take exists; Pause waits for it.
  func record(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .idle else { return }
    guard let folder = outputFolder(for: feedID) else {
      feeds[index].error = RecordingUIError.outputFolderRequired.localizedDescription
      return
    }
    activeTakeFolders[feedID] = folder
    retainedTakeRoots[folder.standardizedFileURL.path] = folder
    do { try folderStore?.saveRecoveryRoots(Array(retainedTakeRoots.values)) }
    catch { recoveryMessage = "Could not retain the original recording folder for recovery: \(error.localizedDescription)" }
    var take = configuration
    take.outputFolder = folder
    take.feedName = feeds[index].name
    take.recordingConstantFrameRate = feedConstantFrameRate[feedID] ?? false
    recordingGenerations[feedID, default: 0] &+= 1
    let generation = recordingGenerations[feedID, default: 0]
    let previous = (savedURL: feeds[index].savedURL, statistics: feeds[index].statistics)
    feeds[index].savedURL = nil
    feeds[index].status = .recording
    feeds[index].isStarting = true
    feeds[index].error = nil
    feeds[index].statistics = (driver is RecordingSessionDriverStatistics) ? RecordingStatistics(compatibilityPolicy: take.compatibilityPolicy) : nil
    driver.startRecording(feedID: feedID, configuration: take) { [weak self] result in
      self?.finishStart(feedID: feedID, generation: generation, result: result,
        previousSavedURL: previous.savedURL, previousStatistics: previous.statistics)
    }
  }

  private func finishStart(feedID: FeedID, generation: UInt64, result: Result<Void, Error>,
    previousSavedURL: URL?, previousStatistics: RecordingStatistics?) {
    guard let index = index(of: feedID), recordingGenerations[feedID] == generation else { return }
    feeds[index].isStarting = false
    switch result {
    case .success:
      startStatisticsUpdates()
      // A stop that arrived while starting already moved the take on.
      guard feeds[index].status == .recording else { return }
      feeds[index].error = (driver as? RecordingSessionDriverDiagnostics)?.startWarning?.localizedDescription
      if let output = (driver as? RecordingSessionDriverArtifacts)?.recordingOutputURL(feedID: feedID) {
        onRecordingStarted?(feedID, output)
      }
    case let .failure(error):
      feeds[index].error = error.localizedDescription
      // A stop requested meanwhile completes on its own and reports idle.
      guard feeds[index].status == .recording else { return }
      feeds[index].status = .idle
      feeds[index].savedURL = previousSavedURL
      feeds[index].statistics = previousStatistics
      activeTakeFolders.removeValue(forKey: feedID)
      refreshRecovery()
      notifyFinished()
    }
  }

  func pause(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .recording,
      !feeds[index].isStarting else { return }
    do {
      try driver.pauseRecording(feedID: feedID)
      feeds[index].status = .paused
      feeds[index].error = nil
      onRecordingPaused?(feedID, true)
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func resume(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .paused else { return }
    do {
      try driver.resumeRecording(feedID: feedID)
      feeds[index].status = .recording
      feeds[index].error = nil
      onRecordingPaused?(feedID, false)
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func stop(feedID: FeedID) {
    guard let index = index(of: feedID),
      feeds[index].status == .recording || feeds[index].status == .paused else { return }
    let artifacts = driver as? RecordingSessionDriverArtifacts
    let output = artifacts?.recordingOutputURL(feedID: feedID)
    let folder = activeTakeFolders[feedID] ?? outputFolder(for: feedID)
    feeds[index].status = .finishing
    feeds[index].error = nil
    driver.stopRecording(feedID: feedID) { [weak self] result in
      guard let self, let index = self.index(of: feedID) else { return }
      self.feeds[index].status = .idle
      self.feeds[index].isStarting = false
      self.activeTakeFolders.removeValue(forKey: feedID)
      // A take stopped while it was starting had no live output to ask for.
      let saved = self.resolveFinishedFile(output ?? artifacts?.finishedOutputURL(feedID: feedID), folder)
      // A start that failed after Stop was pressed already set the error.
      if case let .failure(error) = result { self.feeds[index].error = error.localizedDescription }
      else if self.feeds[index].error == nil { self.feeds[index].savedURL = saved }
      self.onRecordingFinished?(feedID, saved)
      self.refreshRecovery()
      self.notifyFinished()
      Task { [weak self] in await self?.refreshStatistics() }
    }
  }

  private func startStatisticsUpdates() {
    guard statisticsTask == nil, driver is RecordingSessionDriverStatistics else { return }
    statisticsTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { break }
        await self.refreshStatistics()
        if !self.hasActiveRecordings { self.statisticsTask = nil; break }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
      }
    }
  }

  func refreshStatistics() async {
    guard let source = driver as? RecordingSessionDriverStatistics else { return }
    let generations = recordingGenerations
    let snapshots = await source.recordingStatistics()
    for (id, snapshot) in snapshots {
      guard generations[id] == recordingGenerations[id], let index = index(of: id) else { continue }
      let previous = _feeds[index].statistics
      guard previous != snapshot else { continue }
      if RecordingStatisticsState(previous) == RecordingStatisticsState(snapshot) {
        // Only the clock, size or rate moved: stored without telling the observers of `feeds`.
        _feeds[index].statistics = snapshot
      } else {
        feeds[index].statistics = snapshot
      }
      telemetry.statisticsChanged(id)
    }
  }

  nonisolated static func existingFile(_ url: URL?, scope: URL? = nil) -> URL? {
    guard let url else { return nil }
    // The take's security-scoped folder is released when the session ends.
    // Start it again for this existence check, or a bookmark-restored folder
    // reports the finished movie as missing.
    let accessed = scope?.startAccessingSecurityScopedResource() ?? false
    defer { if accessed { scope?.stopAccessingSecurityScopedResource() } }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func recordAll() {
    for id in feeds.map(\.id) { record(feedID: id) }
  }

  func pauseAll() {
    for id in feeds.map(\.id) { pause(feedID: id) }
  }

  func stopAll() {
    for id in feeds.map(\.id) { stop(feedID: id) }
  }

  func stopAll(completion: @escaping () -> Void) {
    finishedCallbacks.append(completion)
    stopAll()
    notifyFinished()
  }

  private func notifyFinished() {
    guard !hasActiveRecordings else { return }
    let callbacks = finishedCallbacks
    finishedCallbacks.removeAll()
    callbacks.forEach { $0() }
  }

  private func index(of id: FeedID) -> Int? {
    feeds.firstIndex { $0.id == id }
  }

  /// A take's statistics, followed with every refresh (2 Hz while recording).
  func liveStatistics(_ id: FeedID) -> RecordingStatistics? {
    _ = telemetry.camera(id).statistics
    return feeds.first { $0.id == id }?.statistics
  }
}
