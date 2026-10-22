import Foundation
import Observation
import CoreMedia
import CoreVideo

/// The codecs exposed by the recording UI. The media writer is injected through
/// `RecordingSessionDriver`, so this model does not own capture or file I/O.
enum RecordingCodec: String, CaseIterable, Codable, Equatable, Sendable {
  case proRes42210Bit
  case hevcMain10_422

  var title: String {
    switch self {
    case .proRes42210Bit: return "ProRes 422 HQ"
    case .hevcMain10_422: return "HEVC Main10 4:2:2"
    }
  }

  var fileExtension: String {
    switch self {
    case .proRes42210Bit, .hevcMain10_422: return "mov"
    }
  }
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
      return "No timecode track is written. Camera timecode still appears in the metadata panel when the signal has it."
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

  init(codec: RecordingCodec = .proRes42210Bit, outputFolder: URL? = nil,
    timecodeMode: RecordingTimecodeMode = .wallClock, feedName: String? = nil) {
    self.codec = codec
    self.outputFolder = outputFolder
    self.timecodeMode = timecodeMode
    self.feedName = feedName
  }
}

struct RecordingFeedDescriptor: Identifiable, Hashable, Sendable {
  let id: FeedID
  var name: String

  init(id: FeedID, name: String) {
    self.id = id
    self.name = name
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
  var isActive: Bool { status != .idle }
  var displayStatus: String {
    if statistics?.failed == true { return "Failed" }
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
      return "Blackmagic raw audio recording is unavailable; video will be recorded without audio."
    case .feedNotActive:
      return "Start this camera before recording it. Only a running camera can produce media."
    }
  }
}

/// The small boundary between controls and a future media writer.
/// Implementations are called on the main actor by `RecordingModel`.
protocol RecordingSessionDriver: AnyObject {
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws
  func pauseRecording(feedID: FeedID) throws
  func resumeRecording(feedID: FeedID) throws
  func stopRecording(feedID: FeedID) throws
  @MainActor func stopRecording(feedID: FeedID,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void)
}

extension RecordingSessionDriver {
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
  // teardown. Managers are shared by folder/extension so disk reservations
  // account for all feeds recording to the same volume.
  private let sessionLock = NSLock()
  private var sessions: [FeedID: Session] = [:]
  private var stoppingFeeds = Set<FeedID>()
  private var completedStatistics: [FeedID: RecordingStatistics] = [:]
  private var outputManagers: [String: RecordingOutputManager] = [:]

  init(capture: CaptureController, rawAudioCallbackAvailable: Bool = false,
    captureForFeed: ((FeedID) -> CaptureController)? = nil,
    recorderFactory: @escaping RecorderFactory = { try SourceRecorderCore(configuration: $0) }) {
    self.captureForFeed = captureForFeed ?? { _ in capture }
    self.rawAudioCallbackAvailable = rawAudioCallbackAvailable
    self.recorderFactory = recorderFactory
  }

  var startWarning: RecordingUIError? {
    rawAudioCallbackAvailable ? nil : .rawAudioUnavailable
  }

  func recordingOutputURL(feedID: FeedID) -> URL? {
    sessionLock.withLock { sessions[feedID]?.output.finalURL }
  }

  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
    let capture = captureForFeed(feedID)
    guard !capture.hasActiveFeed || capture.isAccepting(feedID: feedID) else {
      throw RecordingUIError.feedNotActive
    }
    guard sessionLock.withLock({ sessions[feedID] == nil }) else {
      throw SourceRecordingError.invalidState(.recording, operation: "start recording")
    }
    guard let folder = configuration.outputFolder else {
      throw RecordingUIError.outputFolderRequired
    }
    let folderAccess = RecordingFolderAccess(folder)
    defer { withExtendedLifetime(folderAccess) {} }
    // Allocate a per-feed atomic output before creating the writer. The
    // writer only sees the temporary path; a completed session is renamed to
    // its final path after all queued samples have drained.
    let outputManager = try manager(for: folder, fileExtension: configuration.codec.fileExtension)
    let output = try outputManager.beginExternalWriterSession(
      feedID: Self.safeComponent(configuration.feedName ?? "Feed"))
    do {
      let sourceConfiguration = try SourceRecordingConfiguration(
        feedID: SourceRecordingFeedID(feedID.rawValue), outputURL: output.temporaryURL,
        width: 3840, height: 2160,
        videoCodec: configuration.codec == .proRes42210Bit
          ? kCMVideoCodecType_AppleProRes422HQ : kCMVideoCodecType_HEVC,
        timecodePolicy: Self.timecodePolicy(for: configuration.timecodeMode),
        timecodeSamplesComputerClockAtFirstFrame: configuration.timecodeMode == .wallClock,
        checkAvailableSpace: { try output.checkExternalWriterCapacity() })
      let recorder = try recorderFactory(sourceConfiguration)
      let adapter = SourceRecordingCallbackAdapter(feedID: sourceConfiguration.feedID, recorder: recorder)
      try adapter.start()
      sessionLock.lock()
      // A concurrent start for the same feed may have won while the writer
      // was being constructed. Never overwrite that live session or leak its
      // output reservation.
      let available = sessions[feedID] == nil
      if available {
        completedStatistics.removeValue(forKey: feedID)
        sessions[feedID] = Session(adapter: adapter, feedID: feedID, output: output, folderAccess: folderAccess)
      }
      sessionLock.unlock()
      guard available else {
        throw SourceRecordingError.invalidState(.recording, operation: "start recording")
      }
      // Install the callback only after winning the session slot. Otherwise a
      // losing concurrent start could replace the active recorder's callback
      // and leave the winning session unable to receive media.
      capture.setRecordingCallbacks(feedID: feedID, callbacks: adapter.callbacks)
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

  func stopRecording(feedID: FeedID) throws {
    guard let session = try beginStop(feedID: feedID) else { return }
    try finalize(session, feedID: feedID)
  }

  @MainActor func stopRecording(feedID: FeedID,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
    do {
      // Resolve the app-owned capture controller on the caller's main actor.
      // Only detached media finalization crosses to the worker.
      guard let session = try beginStop(feedID: feedID) else {
        completion(.success(()))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result { try self.finalize(session, feedID: feedID) }
        DispatchQueue.main.async { completion(result) }
      }
    } catch { completion(.failure(error)) }
  }

  private func beginStop(feedID: FeedID) throws -> Session? {
    let session = try sessionLock.withLock { () throws -> Session? in
      guard let session = sessions[feedID] else { return nil }
      guard stoppingFeeds.insert(feedID).inserted else {
        throw SourceRecordingError.invalidState(.stopping, operation: "stop recording")
      }
      return session
    }
    guard let session else { return nil }
    session.clock.pause()
    captureForFeed(feedID).setRecordingCallbacks(feedID: feedID, callbacks: nil)
    return session
  }

  private func finalize(_ session: Session, feedID: FeedID) throws {
    defer {
      let final = snapshot(session, stopped: true)
      sessionLock.withLock {
        completedStatistics[feedID] = final
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
    let hadMedia = telemetry.appendedVideo > 0 || telemetry.appendedAudio > 0
    // A failed flush must never publish an unfinished movie as a successful
    // take, nor delete its completed fragments. Recovery owns it after stop.
    do {
      if stopError != nil || session.adapter.state == .failed {
        session.output.preserveForRecovery()
      } else if hadMedia {
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
        elapsed: session.clock.elapsed, fileBytes: bytes, fileURL: url, stopped: stopped)
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
  private var loadedFolderFeedIDs = Set<FeedID>()
  private var interruptedRecordingRoots: [URL: URL] = [:]
  var timecodeMode: RecordingTimecodeMode = .wallClock
  private(set) var feeds: [RecordingFeedState] = []

  var onOutputFolderChanged: ((URL?) -> Void)?
  var onRecordingStarted: ((FeedID, URL) -> Void)?
  var onRecordingFinished: ((FeedID, URL?) -> Void)?

  private let driver: RecordingSessionDriver
  private var finishedCallbacks: [() -> Void] = []
  @ObservationIgnored private var statisticsTask: Task<Void, Never>?
  private var recordingGenerations: [FeedID: UInt64] = [:]

  init(feeds: [RecordingFeedDescriptor] = [], driver: RecordingSessionDriver = UnavailableRecordingSessionDriver(),
    folderStore: RecordingFolderStore? = nil) {
    self.driver = driver
    self.folderStore = folderStore
    updateFeeds(feeds)
    do { _outputFolder = try folderStore?.load() }
    catch { recoveryMessage = "Choose your recording folder to check for interrupted recordings." }
    refreshRecovery()
  }

  func refreshRecovery(clearMessage: Bool = true) {
    recoveryScanGeneration += 1
    let generation = recoveryScanGeneration
    var seenPaths = Set<String>()
    // Keep the original bookmarked URLs so their sandbox grants survive.
    let roots = ([outputFolder].compactMap { $0 } + Array(feedOutputFolders.values))
      .filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
      .sorted { $0.path < $1.path }
    guard !roots.isEmpty else {
      interruptedRecordings = []
      interruptedRecordingRoots = [:]
      return
    }
    Task { [weak self] in
      let results = await Task.detached(priority: .utility) {
        roots.map { root in (root, Result { try RecordingRecovery.scan(root: root) }) }
      }.value
      guard let self, self.recoveryScanGeneration == generation else { return }
      var takesByID: [URL: InterruptedRecording] = [:]
      self.interruptedRecordingRoots = [:]
      if clearMessage, self.recoveryMessageIsScanError {
        self.recoveryMessage = nil
      }
      for (root, result) in results {
        switch result {
        case let .success(takes):
          for take in takes {
            takesByID[take.id] = take
            self.interruptedRecordingRoots[take.id] = root
          }
        case let .failure(error):
          self.recoveryMessage = "Could not check interrupted recordings in \(root.path): \(error.localizedDescription)"
          self.recoveryMessageIsScanError = true
        }
      }
      self.interruptedRecordings = takesByID.values.sorted { $0.id.path < $1.id.path }
    }
  }

  func recover(_ take: InterruptedRecording) {
    guard recoveringID == nil, let root = interruptedRecordingRoots[take.id] else { return }
    recoveringID = take.id
    recoveryMessage = nil
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        do { return Result<URL, Error>.success(try await RecordingRecovery.recover(take, root: root)) }
        catch { return .failure(error) }
      }.value
      guard let self else { return }
      self.recoveringID = nil
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
    RecordingConfiguration(codec: codec, outputFolder: outputFolder, timecodeMode: timecodeMode)
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

  var canPauseAny: Bool { feeds.contains { $0.status == .recording } }
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
    feeds = descriptors.compactMap { descriptor in
      guard seen.insert(descriptor.id).inserted else { return nil }
      var state = old[descriptor.id] ?? RecordingFeedState(id: descriptor.id, name: descriptor.name)
      state.name = descriptor.name
      return state
    }
    let retainedIDs = Set(descriptors.map(\.id))
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

  func record(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .idle else { return }
    guard let folder = outputFolder(for: feedID) else {
      feeds[index].error = RecordingUIError.outputFolderRequired.localizedDescription
      return
    }
    do {
      var take = configuration
      take.outputFolder = folder
      take.feedName = feeds[index].name
      try driver.startRecording(feedID: feedID, configuration: take)
      recordingGenerations[feedID, default: 0] &+= 1
      feeds[index].savedURL = nil
      feeds[index].status = .recording
      feeds[index].statistics = (driver is RecordingSessionDriverStatistics) ? RecordingStatistics() : nil
      startStatisticsUpdates()
      feeds[index].error = (driver as? RecordingSessionDriverDiagnostics)?.startWarning?.localizedDescription
      if let output = (driver as? RecordingSessionDriverArtifacts)?.recordingOutputURL(feedID: feedID) {
        onRecordingStarted?(feedID, output)
      }
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func pause(feedID: FeedID) {
    guard let index = index(of: feedID), feeds[index].status == .recording else { return }
    do {
      try driver.pauseRecording(feedID: feedID)
      feeds[index].status = .paused
      feeds[index].error = nil
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
    } catch {
      feeds[index].error = error.localizedDescription
    }
  }

  func stop(feedID: FeedID) {
    guard let index = index(of: feedID),
      feeds[index].status == .recording || feeds[index].status == .paused else { return }
    let output = (driver as? RecordingSessionDriverArtifacts)?.recordingOutputURL(feedID: feedID)
    let folder = outputFolder(for: feedID)
    feeds[index].status = .finishing
    feeds[index].error = nil
    driver.stopRecording(feedID: feedID) { [weak self] result in
      guard let self, let index = self.index(of: feedID) else { return }
      self.feeds[index].status = .idle
      let saved = Self.existingFile(output, scope: folder)
      if case let .failure(error) = result { self.feeds[index].error = error.localizedDescription }
      else { self.feeds[index].savedURL = saved }
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
      feeds[index].statistics = snapshot
    }
  }

  private static func existingFile(_ url: URL?, scope: URL? = nil) -> URL? {
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
}
