import CoreMedia
import Foundation

/// The media kind carried by a recording packet.
public enum RecordingMediaKind: UInt8, Sendable {
  case video = 1
  case audio = 2
}

/// A packet presented to the recording session.
///
/// Invalid packets fail the session. Late audio from a previous segment and
/// video that maps before the last written frame are dropped to preserve the
/// media already written.
public struct RecordingPacket: Sendable, Equatable {
  public let mediaKind: RecordingMediaKind
  public let presentationTime: CMTime
  public let duration: CMTime
  public let payload: Data

  public init(mediaKind: RecordingMediaKind, presentationTime: CMTime,
              duration: CMTime, payload: Data = Data()) {
    self.mediaKind = mediaKind
    self.presentationTime = presentationTime
    self.duration = duration
    self.payload = payload
  }

  /// Size reserved by the atomic writer before the packet is accepted.
  public var encodedByteCount: Int64 {
    // kind (1), PTS (8), duration (8), payload length (8), payload.
    Int64(25) + Int64(payload.count)
  }
}

public struct NormalizedRecordingPacket: Sendable, Equatable {
  public let packet: RecordingPacket
  public let presentationTime: CMTime
  public let duration: CMTime

  public init(packet: RecordingPacket, presentationTime: CMTime, duration: CMTime) {
    self.packet = packet
    self.presentationTime = presentationTime
    self.duration = duration
  }

  public var endTime: CMTime { CMTimeAdd(presentationTime, duration) }
}

public enum RecordingTimestampError: Error, Equatable {
  case invalidPresentationTime
  case invalidDuration
  case unsupportedEpoch(Int64)
  case timestampRegressed
  case timestampNotMonotonic
}

/// Converts source timestamps to one fixed timebase and rejects regressions.
///
/// A separate instance is used for audio and video. Conversion happens before
/// comparison, so 48 kHz audio and 60 kHz video cannot accumulate floating
/// point drift over a long session.
public struct RecordingTimestampNormalizer: Sendable {
  public let timescale: Int32
  public private(set) var lastPresentationTime: CMTime?
  public private(set) var lastDuration: CMTime?

  /// 480000 divides 48 kHz audio and both 1001-based video rates, so alternating
  /// 1601/1602-sample packets stay monotonic. 60000 rounds those durations
  /// independently and eventually overlaps the next PTS.
  public init(timescale: Int32 = 480_000) {
    precondition(timescale > 0, "Recording timescale must be positive")
    self.timescale = timescale
  }

  public mutating func normalize(_ packet: RecordingPacket)
    -> Result<NormalizedRecordingPacket, RecordingTimestampError> {
    guard packet.presentationTime.isValid, packet.presentationTime.isNumeric,
      packet.presentationTime.timescale > 0, packet.presentationTime.value >= 0 else {
      return .failure(.invalidPresentationTime)
    }
    guard packet.duration.isValid, packet.duration.isNumeric,
      packet.duration.timescale > 0, packet.duration.value > 0,
      packet.duration.epoch == 0 else {
      return .failure(.invalidDuration)
    }
    guard packet.presentationTime.epoch == 0 else {
      return .failure(.unsupportedEpoch(packet.presentationTime.epoch))
    }

    let presentation = CMTimeConvertScale(packet.presentationTime, timescale: timescale,
      method: .roundHalfAwayFromZero)
    let duration = CMTimeConvertScale(packet.duration, timescale: timescale,
      method: .roundHalfAwayFromZero)
    guard presentation.isValid, presentation.isNumeric, duration.isValid,
      duration.isNumeric, duration.value > 0 else {
      return .failure(.invalidDuration)
    }
    if let lastPresentationTime {
      guard CMTimeCompare(presentation, lastPresentationTime) > 0 else {
        return .failure(.timestampRegressed)
      }
      // A duration that extends beyond the next PTS is valid for variable-rate
      // media, but a duplicate or backwards end time is never valid.
      if let lastDuration,
        CMTimeCompare(CMTimeAdd(lastPresentationTime, lastDuration), presentation) > 0 {
        return .failure(.timestampNotMonotonic)
      }
    }
    lastPresentationTime = presentation
    lastDuration = duration
    return .success(NormalizedRecordingPacket(packet: packet,
      presentationTime: presentation, duration: duration))
  }

  /// Starts a fresh source clock after an intentional pause/resume boundary.
  public mutating func reset() {
    lastPresentationTime = nil
    lastDuration = nil
  }
}

public enum RecordingDriftError: Error, Equatable {
  case invalidLimit
  case exceedsLimit(CMTime)
}

/// Tracks the latest audio/video end times and enforces a bounded drift.
public struct RecordingAVDriftTracker: Sendable {
  public let maximumDrift: CMTime
  public private(set) var latestVideoEnd: CMTime?
  public private(set) var latestAudioEnd: CMTime?

  public init(maximumDrift: CMTime = CMTime(value: 1, timescale: 10)) {
    precondition(maximumDrift.isValid && maximumDrift.isNumeric && maximumDrift.epoch == 0 &&
      maximumDrift.timescale > 0 && maximumDrift.value >= 0,
      "A/V drift limit must be finite and non-negative")
    self.maximumDrift = maximumDrift
  }

  public var currentDrift: CMTime? {
    guard let video = latestVideoEnd, let audio = latestAudioEnd else { return nil }
    return CMTimeSubtract(audio, video)
  }

  @discardableResult
  public mutating func observe(_ packet: NormalizedRecordingPacket) throws -> CMTime? {
    let end = packet.endTime
    var candidateVideoEnd = latestVideoEnd
    var candidateAudioEnd = latestAudioEnd
    switch packet.packet.mediaKind {
    case .video: candidateVideoEnd = end
    case .audio: candidateAudioEnd = end
    }
    guard let video = candidateVideoEnd, let audio = candidateAudioEnd else {
      latestVideoEnd = candidateVideoEnd
      latestAudioEnd = candidateAudioEnd
      return nil
    }
    let drift = CMTimeSubtract(audio, video)
    let magnitude = abs(CMTimeGetSeconds(drift))
    let limit = abs(CMTimeGetSeconds(maximumDrift))
    guard magnitude.isFinite, limit.isFinite else { throw RecordingDriftError.invalidLimit }
    guard magnitude <= limit else { throw RecordingDriftError.exceedsLimit(drift) }
    latestVideoEnd = candidateVideoEnd
    latestAudioEnd = candidateAudioEnd
    return drift
  }

  public mutating func reset() {
    latestVideoEnd = nil
    latestAudioEnd = nil
  }
}

public enum RecordingQueueError: Error, Equatable {
  case invalidCapacity
  case closed
  case full
}

/// A lock-protected FIFO with a hard capacity and no implicit drop policy.
public final class BoundedRecordingQueue<Element>: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private var elements: [Element] = []
  private var closed = false

  public init(capacity: Int) throws {
    guard capacity > 0 else { throw RecordingQueueError.invalidCapacity }
    self.capacity = capacity
    elements.reserveCapacity(capacity)
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return elements.count
  }

  public var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  @discardableResult
  public func enqueue(_ element: Element) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { throw RecordingQueueError.closed }
    guard elements.count < capacity else { throw RecordingQueueError.full }
    elements.append(element)
    return true
  }

  public func dequeue() -> Element? {
    lock.lock()
    defer { lock.unlock() }
    guard !elements.isEmpty else { return nil }
    return elements.removeFirst()
  }

  /// Closes admission and returns all pending elements in FIFO order. The
  /// caller must process them before treating a recording as finalized.
  @discardableResult
  public func closeAndDrain() -> [Element] {
    lock.lock()
    defer { lock.unlock() }
    closed = true
    let pending = elements
    elements.removeAll(keepingCapacity: false)
    return pending
  }

  public func close() {
    lock.lock()
    closed = true
    lock.unlock()
  }
}

public struct RecordingSegmentInfo: Sendable, Equatable {
  public let index: Int
  public let startTime: CMTime
  public let endTime: CMTime
  public let url: URL?

  public init(index: Int, startTime: CMTime, endTime: CMTime, url: URL? = nil) {
    self.index = index
    self.startTime = startTime
    self.endTime = endTime
    self.url = url
  }

  public var duration: CMTime { CMTimeSubtract(endTime, startTime) }
}

public protocol RecordingSegmentWriter: AnyObject {
  func beginSegment(index: Int, startTime: CMTime) throws
  func append(_ packet: NormalizedRecordingPacket) throws
  func finalizeSegment(endTime: CMTime) throws -> RecordingSegmentInfo
  func abortSegment()
}

public protocol RecordingDiskSpaceProvider: Sendable {
  func availableBytes(at directory: URL) throws -> Int64
}

public struct FileManagerRecordingDiskSpaceProvider: RecordingDiskSpaceProvider {
  public init() {}

  public func availableBytes(at directory: URL) throws -> Int64 {
    let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let available = values.volumeAvailableCapacityForImportantUsage, available >= 0 else {
      throw RecordingError.diskSpaceUnavailable
    }
    return available
  }
}

public enum RecordingError: Error, Equatable {
  case invalidConfiguration
  case invalidState
  case paused
  case failed
  case queueFull
  case queueBytesFull
  case queueClosed
  case diskSpaceUnavailable
  case insufficientDiskSpace(required: Int64, available: Int64)
  case timestamp(RecordingTimestampError)
  case drift(RecordingDriftError)
  case writer(String)
}

public struct LongRunRecordingConfiguration: Sendable {
  public let timescale: Int32
  public let maximumSegmentDuration: CMTime
  public let maximumAVDrift: CMTime
  public let queueCapacity: Int
  public let maximumQueueBytes: Int64
  public let minimumFreeBytes: Int64
  public let outputDirectory: URL

  public init(timescale: Int32 = 480_000,
              maximumSegmentDuration: CMTime = CMTime(value: 3_600, timescale: 1),
              maximumAVDrift: CMTime = CMTime(value: 1, timescale: 10),
              queueCapacity: Int = 256,
              maximumQueueBytes: Int64 = 256 * 1_048_576,
              minimumFreeBytes: Int64 = 1_073_741_824,
              outputDirectory: URL) {
    self.timescale = timescale
    self.maximumSegmentDuration = maximumSegmentDuration
    self.maximumAVDrift = maximumAVDrift
    self.queueCapacity = queueCapacity
    self.maximumQueueBytes = maximumQueueBytes
    self.minimumFreeBytes = minimumFreeBytes
    self.outputDirectory = outputDirectory
  }

  fileprivate func validate() throws {
    guard timescale > 0, maximumSegmentDuration.isValid,
      maximumSegmentDuration.isNumeric, maximumSegmentDuration.value > 0,
      maximumSegmentDuration.timescale > 0, maximumSegmentDuration.epoch == 0,
      maximumAVDrift.isValid, maximumAVDrift.isNumeric, maximumAVDrift.value >= 0,
      maximumAVDrift.timescale > 0, maximumAVDrift.epoch == 0,
      queueCapacity > 0, maximumQueueBytes > 0, minimumFreeBytes >= 0, outputDirectory.isFileURL,
      !outputDirectory.path.isEmpty else {
      throw RecordingError.invalidConfiguration
    }
  }
}

public enum LongRunRecordingState: Equatable, Sendable {
  case idle
  case recording
  case paused
  case failed
  case finalized
}

public struct LongRunRecordingSummary: Sendable, Equatable {
  public let segments: [RecordingSegmentInfo]
  public let packetCount: Int
  public let finalState: LongRunRecordingState

  public init(segments: [RecordingSegmentInfo], packetCount: Int,
              finalState: LongRunRecordingState) {
    self.segments = segments
    self.packetCount = packetCount
    self.finalState = finalState
  }
}

/// Serial recording coordinator for hour-scale sessions.
///
/// Producers call `enqueue`; a writer thread or deterministic test calls
/// `processNext`/`drain`. Queue overflow, timing violations, drift, disk
/// exhaustion and writer failures transition the session to `.failed` instead
/// of dropping media or silently continuing with a damaged timeline.
public final class LongRunRecordingSession: @unchecked Sendable {
  private let configuration: LongRunRecordingConfiguration
  private let disk: any RecordingDiskSpaceProvider
  private let writer: any RecordingSegmentWriter
  private let queue: BoundedRecordingQueue<RecordingPacket>
  private var videoNormalizer: RecordingTimestampNormalizer
  private var audioNormalizer: RecordingTimestampNormalizer
  private var drift: RecordingAVDriftTracker
  private var state = LongRunRecordingState.idle
  private var segmentIndex = 0
  private var segmentStart: CMTime?
  private var latestOutputEnd: CMTime?
  private var latestVideoPTS: CMTime?
  private var segmentHasPackets = false
  private var segments: [RecordingSegmentInfo] = []
  private var packetCount = 0
  private var pendingBytes: Int64 = 0
  private var resumeSourceOrigin: CMTime?
  private var resumeOutputOrigin: CMTime?
  private let lock = NSLock()

  public init(configuration: LongRunRecordingConfiguration,
              diskSpace: any RecordingDiskSpaceProvider = FileManagerRecordingDiskSpaceProvider(),
              writer: any RecordingSegmentWriter) throws {
    try configuration.validate()
    self.configuration = configuration
    self.disk = diskSpace
    self.writer = writer
    self.queue = try BoundedRecordingQueue(capacity: configuration.queueCapacity)
    self.videoNormalizer = RecordingTimestampNormalizer(timescale: configuration.timescale)
    self.audioNormalizer = RecordingTimestampNormalizer(timescale: configuration.timescale)
    self.drift = RecordingAVDriftTracker(maximumDrift: configuration.maximumAVDrift)
  }

  public var currentState: LongRunRecordingState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  public var pendingCount: Int { queue.count }

  public var pendingByteCount: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return pendingBytes
  }

  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard state == .idle else { throw RecordingError.invalidState }
    do {
      try FileManager.default.createDirectory(at: configuration.outputDirectory,
        withIntermediateDirectories: true)
    } catch {
      throw RecordingError.writer("Cannot create recording output directory: \(error)")
    }
    try checkDiskSpace(reserve: 0)
    state = .recording
  }

  /// Admission is synchronous and bounded. A full queue fails the session so
  /// the caller must surface the condition instead of losing a media packet.
  public func enqueue(_ packet: RecordingPacket) -> Result<Void, RecordingError> {
    lock.lock()
    defer { lock.unlock() }
    guard state == .recording else {
      switch state {
      case .paused: return .failure(.paused)
      case .failed: return .failure(.failed)
      default: return .failure(.invalidState)
      }
    }
    guard packet.encodedByteCount <= configuration.maximumQueueBytes,
      pendingBytes <= configuration.maximumQueueBytes - packet.encodedByteCount else {
      transitionToFailure(.queueBytesFull)
      return .failure(.queueBytesFull)
    }
    do {
      try queue.enqueue(packet)
      pendingBytes += packet.encodedByteCount
      return .success(())
    } catch RecordingQueueError.full {
      transitionToFailure(.queueFull)
      return .failure(.queueFull)
    } catch RecordingQueueError.closed {
      transitionToFailure(.queueClosed)
      return .failure(.queueClosed)
    } catch {
      transitionToFailure(.failed)
      return .failure(.failed)
    }
  }

  @discardableResult
  public func processNext() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state == .recording else {
      if state == .failed { throw RecordingError.failed }
      return false
    }
    guard let packet = dequeuePending() else { return false }
    do {
      try process(packet)
      return true
    } catch let error as RecordingError {
      transitionToFailure(error)
      throw error
    } catch {
      transitionToFailure(.writer(String(describing: error)))
      throw RecordingError.writer(String(describing: error))
    }
  }

  public func drain() throws {
    while try processNext() {}
  }

  /// Drains queued media before pausing. Packets received while paused are
  /// rejected, and the next accepted packet starts at the previous output end
  /// so a long wall-clock pause cannot create a timeline gap.
  public func pause() throws {
    lock.lock()
    defer { lock.unlock() }
    guard state == .recording else {
      if state == .failed { throw RecordingError.failed }
      throw RecordingError.invalidState
    }
    do {
      while let packet = dequeuePending() { try process(packet) }
      state = .paused
      videoNormalizer.reset()
      audioNormalizer.reset()
      drift.reset()
      resumeSourceOrigin = nil
      resumeOutputOrigin = latestOutputEnd
    } catch let error as RecordingError {
      transitionToFailure(error)
      throw error
    } catch {
      transitionToFailure(.writer(String(describing: error)))
      throw RecordingError.writer(String(describing: error))
    }
  }

  public func resume() throws {
    lock.lock()
    defer { lock.unlock() }
    guard state == .paused else {
      if state == .failed { throw RecordingError.failed }
      throw RecordingError.invalidState
    }
    state = .recording
  }

  public func finish() throws -> LongRunRecordingSummary {
    lock.lock()
    defer { lock.unlock() }
    guard state == .recording || state == .paused else {
      if state == .failed { throw RecordingError.failed }
      if state == .finalized { throw RecordingError.invalidState }
      throw RecordingError.invalidState
    }
    do {
      while let packet = dequeuePending() { try process(packet) }
      try finalizeCurrentSegment()
      queue.close()
      state = .finalized
      return LongRunRecordingSummary(segments: segments, packetCount: packetCount,
        finalState: state)
    } catch let error as RecordingError {
      transitionToFailure(error)
      throw error
    } catch {
      let failure = RecordingError.writer(String(describing: error))
      transitionToFailure(failure)
      throw failure
    }
  }

  /// Finishes the session after draining all admitted packets.
  public func stop() throws -> LongRunRecordingSummary { try finish() }

  public func fail() {
    lock.lock()
    transitionToFailure(.failed)
    lock.unlock()
  }

  private func process(_ packet: RecordingPacket) throws {
    if packet.mediaKind == .audio,
      packet.presentationTime.isNumeric, packet.presentationTime.epoch == 0,
      let resumeSourceOrigin, let resumeOutputOrigin, let segmentStart {
      let mappedTime = CMTimeAdd(resumeOutputOrigin,
        CMTimeSubtract(packet.presentationTime, resumeSourceOrigin))
      if CMTimeCompare(mappedTime, segmentStart) < 0 { return }
    }
    var normalizer = packet.mediaKind == .video ? videoNormalizer : audioNormalizer
    let result = normalizer.normalize(packet)
    let normalized: NormalizedRecordingPacket
    switch result {
    case let .success(packet): normalized = packet
    case let .failure(error): throw RecordingError.timestamp(error)
    }

    guard let timelinePacket = try mapToOutputTimeline(normalized) else { return }
    if packet.mediaKind == .audio, let segmentStart,
      CMTimeCompare(timelinePacket.presentationTime, segmentStart) < 0 { return }
    if packet.mediaKind == .video, let latestVideoPTS,
      CMTimeCompare(timelinePacket.presentationTime, latestVideoPTS) < 0 { return }
    switch packet.mediaKind {
    case .video: videoNormalizer = normalizer
    case .audio: audioNormalizer = normalizer
    }
    do {
      try drift.observe(timelinePacket)
    } catch let error as RecordingDriftError {
      throw RecordingError.drift(error)
    }

    if segmentStart == nil {
      try beginSegment(at: timelinePacket.presentationTime)
    } else if let segmentStart,
      segmentHasPackets,
      CMTimeCompare(CMTimeSubtract(timelinePacket.presentationTime, segmentStart),
        configuration.maximumSegmentDuration) >= 0 {
      try finalizeCurrentSegment()
      segmentIndex += 1
      try beginSegment(at: timelinePacket.presentationTime)
    }

    try checkDiskSpace(reserve: timelinePacket.packet.encodedByteCount)
    try writer.append(timelinePacket)
    segmentHasPackets = true
    packetCount += 1
    if packet.mediaKind == .video { latestVideoPTS = timelinePacket.presentationTime }
    if latestOutputEnd == nil || CMTimeCompare(timelinePacket.endTime, latestOutputEnd!) > 0 {
      latestOutputEnd = timelinePacket.endTime
    }
  }

  private func mapToOutputTimeline(_ packet: NormalizedRecordingPacket) throws -> NormalizedRecordingPacket? {
    guard let resumeSourceOrigin else {
      // Every recording starts at zero even when the capture device's source
      // clock began before admission. A resumed segment intentionally starts
      // at the prior output end, preserving a gap-free paused timeline.
      let outputOrigin = resumeOutputOrigin ?? .zero
      self.resumeSourceOrigin = packet.presentationTime
      self.resumeOutputOrigin = outputOrigin
      let mapped = RecordingPacket(mediaKind: packet.packet.mediaKind,
        presentationTime: outputOrigin, duration: packet.duration,
        payload: packet.packet.payload)
      return NormalizedRecordingPacket(packet: mapped, presentationTime: outputOrigin,
        duration: packet.duration)
    }
    let delta = CMTimeSubtract(packet.presentationTime, resumeSourceOrigin)
    let outputOrigin = resumeOutputOrigin ?? .zero
    var mappedTime = CMTimeAdd(outputOrigin, delta)
    // The other essence can carry an earlier PTS when audio is admitted first.
    // A lead inside the drift limit starts at the segment origin. A larger gap
    // is still a broken timeline.
    if CMTimeCompare(mappedTime, outputOrigin) < 0 {
      if packet.packet.mediaKind == .audio || latestVideoPTS != nil { return nil }
      let lead = CMTimeSubtract(outputOrigin, mappedTime)
      guard CMTimeCompare(lead, configuration.maximumAVDrift) <= 0 else {
        throw RecordingError.timestamp(.timestampRegressed)
      }
      mappedTime = outputOrigin
    }
    let mapped = RecordingPacket(mediaKind: packet.packet.mediaKind,
      presentationTime: mappedTime, duration: packet.duration, payload: packet.packet.payload)
    return NormalizedRecordingPacket(packet: mapped, presentationTime: mappedTime,
      duration: packet.duration)
  }

  private func beginSegment(at start: CMTime) throws {
    try checkDiskSpace(reserve: 0)
    try writer.beginSegment(index: segmentIndex, startTime: start)
    segmentStart = start
    segmentHasPackets = false
  }

  private func dequeuePending() -> RecordingPacket? {
    guard let packet = queue.dequeue() else { return nil }
    pendingBytes -= packet.encodedByteCount
    return packet
  }

  private func finalizeCurrentSegment() throws {
    guard segmentStart != nil, segmentHasPackets, let end = latestOutputEnd else { return }
    let info = try writer.finalizeSegment(endTime: end)
    segments.append(info)
    segmentStart = nil
    segmentHasPackets = false
  }

  private func checkDiskSpace(reserve: Int64) throws {
    let minimum = max(0, configuration.minimumFreeBytes)
    let additional = max(0, reserve)
    let (required, overflow) = minimum.addingReportingOverflow(additional)
    let available: Int64
    do {
      available = try disk.availableBytes(at: configuration.outputDirectory)
    } catch let error as RecordingError {
      throw error
    } catch {
      throw RecordingError.diskSpaceUnavailable
    }
    guard !overflow, available >= required else {
      if overflow {
        throw RecordingError.insufficientDiskSpace(required: Int64.max, available: available)
      }
      throw RecordingError.insufficientDiskSpace(required: required, available: available)
    }
  }

  private func transitionToFailure(_ error: RecordingError) {
    _ = error
    guard state != .failed && state != .finalized else { return }
    let discarded = queue.closeAndDrain()
    pendingBytes -= discarded.reduce(Int64(0)) { $0 + $1.encodedByteCount }
    pendingBytes = max(0, pendingBytes)
    writer.abortSegment()
    state = .failed
  }
}

/// A crash-safe packet segment writer. The temporary file is closed and
/// atomically renamed only after all bytes have been flushed successfully.
public final class AtomicRecordingSegmentWriter: RecordingSegmentWriter {
  private let directory: URL
  private let sessionID: String
  private var handle: FileHandle?
  private var temporaryURL: URL?
  private var finalURL: URL?
  private var segmentIndex: Int?
  private var segmentStart: CMTime?

  public init(directory: URL, sessionID: String = UUID().uuidString) {
    self.directory = directory
    self.sessionID = sessionID
  }

  public func beginSegment(index: Int, startTime: CMTime) throws {
    guard index >= 0, startTime.isValid, startTime.isNumeric,
      startTime.epoch == 0, startTime.timescale > 0, startTime.value >= 0 else {
      throw RecordingError.invalidState
    }
    guard handle == nil else { throw RecordingError.invalidState }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let safeSessionID = sessionID.map { character in
      character.isLetter || character.isNumber || character == "-" || character == "_"
        ? String(character) : "_"
    }.joined()
    let stem = "recording-\(safeSessionID.isEmpty ? "session" : safeSessionID)-segment-\(String(format: "%06d", index))"
    let temporary = directory.appendingPathComponent(stem + ".part", isDirectory: false)
    let final = directory.appendingPathComponent(stem + ".media", isDirectory: false)
    guard !FileManager.default.fileExists(atPath: temporary.path) else {
      throw RecordingError.writer("Refusing to replace an unfinished segment \(temporary.lastPathComponent).")
    }
    guard !FileManager.default.fileExists(atPath: final.path) else {
      throw RecordingError.writer("Refusing to replace finalized segment \(final.lastPathComponent).")
    }
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    guard let next = FileHandle(forWritingAtPath: temporary.path) else {
      throw RecordingError.writer("Cannot open temporary segment.")
    }
    handle = next
    temporaryURL = temporary
    finalURL = final
    segmentIndex = index
    segmentStart = startTime
    var magic = Data("ULTRAREC1\n".utf8)
    appendInt64(startTime.value, to: &magic)
    appendInt32(startTime.timescale, to: &magic)
    do {
      try next.write(contentsOf: magic)
    } catch {
      next.closeFile()
      try? FileManager.default.removeItem(at: temporary)
      handle = nil
      temporaryURL = nil
      finalURL = nil
      segmentIndex = nil
      segmentStart = nil
      throw RecordingError.writer("Cannot write temporary segment header: \(error)")
    }
  }

  public func append(_ packet: NormalizedRecordingPacket) throws {
    guard let handle, let segmentStart else { throw RecordingError.invalidState }
    guard packet.presentationTime.isValid, packet.presentationTime.isNumeric,
      packet.presentationTime.epoch == 0, packet.presentationTime.timescale > 0,
      packet.duration.isValid, packet.duration.isNumeric,
      packet.duration.epoch == 0, packet.duration.timescale > 0,
      packet.duration.value > 0,
      CMTimeCompare(packet.presentationTime, segmentStart) >= 0 else {
      throw RecordingError.writer("Invalid packet timing for segment.")
    }
    var record = Data()
    record.append(packet.packet.mediaKind.rawValue)
    appendInt64(packet.presentationTime.value, to: &record)
    appendInt32(packet.presentationTime.timescale, to: &record)
    appendInt64(packet.duration.value, to: &record)
    appendInt32(packet.duration.timescale, to: &record)
    appendInt64(Int64(packet.packet.payload.count), to: &record)
    record.append(packet.packet.payload)
    do {
      try handle.write(contentsOf: record)
    } catch {
      throw RecordingError.writer("Cannot write recording packet: \(error)")
    }
  }

  public func finalizeSegment(endTime: CMTime) throws -> RecordingSegmentInfo {
    guard let handle, let temporaryURL, let finalURL,
      let segmentIndex, let segmentStart else { throw RecordingError.invalidState }
    guard endTime.isValid, endTime.isNumeric, endTime.epoch == 0,
      endTime.timescale > 0, CMTimeCompare(endTime, segmentStart) >= 0 else {
      throw RecordingError.writer("Invalid segment end time.")
    }
    handle.synchronizeFile()
    handle.closeFile()
    self.handle = nil
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    self.temporaryURL = nil
    self.finalURL = nil
    self.segmentIndex = nil
    self.segmentStart = nil
    return RecordingSegmentInfo(index: segmentIndex, startTime: segmentStart,
      endTime: endTime, url: finalURL)
  }

  public func abortSegment() {
    handle?.synchronizeFile()
    handle?.closeFile()
    handle = nil
    // Preserve the open segment for inspection/recovery after failure.
    temporaryURL = nil
    finalURL = nil
    segmentIndex = nil
    segmentStart = nil
  }

  private func appendInt32(_ value: Int32, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }

  private func appendInt64(_ value: Int64, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
}
