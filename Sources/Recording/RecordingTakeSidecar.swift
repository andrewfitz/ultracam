import Foundation
import AudioToolbox
import CryptoKit
import CoreVideo

/// The encoded route's format content. Source packing/provenance is stored
/// separately in Metadata and cannot change an otherwise identical output ID.
struct RecordingOutputContract: Codable {
  var version = 2
  let width: Int
  let height: Int
  let pixelAspect: Rational
  let scan: Scan
  let rate: FrameRate
  let clock: VideoClockDomain
  let encoderInputPixelFormat: UInt32
  let codec: UInt32
  let outputColour: Colorimetry

  init(sourceFormat: SourceFormat, outputRate: FrameRate? = nil, encoderInputPixelFormat: UInt32, codec: UInt32) {
    width = sourceFormat.width; height = sourceFormat.height
    pixelAspect = sourceFormat.pixelAspect; scan = sourceFormat.scan
    rate = outputRate ?? sourceFormat.rate; clock = sourceFormat.clock
    self.encoderInputPixelFormat = encoderInputPixelFormat; self.codec = codec
    let source = sourceFormat.colour
    let rgb = [kCVPixelFormatType_64RGBALE, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA].contains(encoderInputPixelFormat)
    let video = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange].contains(encoderInputPixelFormat)
    outputColour = Colorimetry(primaries: source.primaries, transfer: source.transfer,
      matrix: rgb ? .identity : source.matrix, range: rgb ? .full : (video ? .video : source.range),
      horizontalChromaSiting: rgb ? .unspecified : source.horizontalChromaSiting,
      verticalChromaSiting: rgb ? .unspecified : source.verticalChromaSiting)
  }
  var signature: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try! encoder.encode(self)
    return SHA256.hash(data: Data("ultracam-recording-output-v2:".utf8) + data).map { String(format: "%02x", $0) }.joined()
  }
}

struct RecordingClockMappingEvent: Sendable {
  let epochID: CaptureEpochID
  let clockID: ClockInstanceID
  let revision: UInt64
  let effectiveSequence: UInt64
  let mapping: ClockMapping
}

struct RecordingTakeContext: Sendable {
  let sourceAdmission: SourceAdmissionSnapshot
  let audioDeclaration: SourceAudioDeclaration
  let mappingRevision: UInt64?
  let videoMapping: ClockMapping?
  let audioMapping: ClockMapping?
  /// The explicit A→host→V⁻¹ composition used for independently clocked audio.
  /// A missing mapping remains missing; callers must not invent a zero origin.
  func audioVideoClockMapping() throws -> AudioVideoClockMapping? {
    guard let audioMapping, let videoMapping else { return nil }
    return try AudioVideoClockMapping(audio: audioMapping, video: videoMapping)
  }
  init(sourceAdmission: SourceAdmissionSnapshot, audioDeclaration: SourceAudioDeclaration,
    mappingRevision: UInt64? = nil, videoMapping: ClockMapping? = nil, audioMapping: ClockMapping? = nil) {
    self.sourceAdmission = sourceAdmission; self.audioDeclaration = audioDeclaration
    self.mappingRevision = mappingRevision; self.videoMapping = videoMapping; self.audioMapping = audioMapping
  }
  func validateCurrentAudio() throws {
    switch audioDeclaration {
    case .unknown: throw SourceRecordingError.unsupportedSample("Recording requires a resolved audio declaration before media.")
    case .absent: return
    case .present(let audio):
      let outputRate = try recordingPCMOutputSampleRate(for: audio)
      _ = try sourceAudioChannelLayoutData(audio)
      _ = try ClockMappedPCMBridge(format: audio, outputSampleRate: outputRate)
      if audio.clock != .pairedWithFrames {
        guard try audioVideoClockMapping() != nil else {
          throw SourceRecordingError.unsupportedSample("Recording independently clocked audio requires actual audio and video clock mappings.")
        }
      }

    }
  }
  func sameContract(as other: Self) -> Bool {
    sourceAdmission.epochID == other.sourceAdmission.epochID &&
      sourceAdmission.formatSignature == other.sourceAdmission.formatSignature &&
      sourceAdmission.clockBindings == other.sourceAdmission.clockBindings && audioDeclaration == other.audioDeclaration
  }
}

/// Synchronized across recorder and writer queues. No sample arrays are retained: exceptional
/// timing and mapping records go to a capped on-disk JSON-lines journal. The
/// journal is forensic: nothing reads it back, so it never gets to end a take.
final class RecordingTakeSidecar: @unchecked Sendable {
  struct Metadata: Codable {
    var sourceSignature: String
    var outputSignature: String
    var epoch: CaptureEpochID? = nil
    var clockBindings: CaptureClockBindings? = nil
    var audioDeclaration: SourceAudioDeclaration? = nil
    var audioOutputSampleRate: Double? = nil
    var policy = RecordingCompatibilityPolicy()
    var timestampTimescale: Int32? = nil
    var videoClockDomain: VideoClockDomain? = nil
    var outputContract: RecordingOutputContract? = nil
    var sourceFormat: SourceFormat? = nil
    var keyframeIntervalDuration: Double? = nil
    var conversionNotes: [String] = []
    var mappingRevision: UInt64? = nil
    var videoMapping: ClockMapping? = nil
    var audioMapping: ClockMapping? = nil
    private enum CodingKeys: String, CodingKey {
      case sourceSignature, outputSignature, epoch, clockBindings, audioDeclaration, policy, timestampTimescale
      case videoClockDomain, outputContract, sourceFormat, keyframeIntervalDuration, conversionNotes, mappingRevision, videoMapping, audioMapping, audioOutputSampleRate
    }
    init(sourceSignature: String, outputSignature: String) {
      self.sourceSignature = sourceSignature; self.outputSignature = outputSignature
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      sourceSignature = try c.decodeIfPresent(String.self, forKey: .sourceSignature) ?? ""
      outputSignature = try c.decodeIfPresent(String.self, forKey: .outputSignature) ?? ""
      epoch = try c.decodeIfPresent(CaptureEpochID.self, forKey: .epoch)
      clockBindings = try c.decodeIfPresent(CaptureClockBindings.self, forKey: .clockBindings)
      audioDeclaration = try? c.decodeIfPresent(SourceAudioDeclaration.self, forKey: .audioDeclaration)
      policy = try c.decodeIfPresent(RecordingCompatibilityPolicy.self, forKey: .policy) ?? .init()
      timestampTimescale = try c.decodeIfPresent(Int32.self, forKey: .timestampTimescale)
      videoClockDomain = try? c.decodeIfPresent(VideoClockDomain.self, forKey: .videoClockDomain)
      // A future output descriptor must not make historical metadata unreadable.
      // Recovery copies the original bytes and never rewrites unknown fields.
      outputContract = try? c.decodeIfPresent(RecordingOutputContract.self, forKey: .outputContract)
      sourceFormat = try? c.decodeIfPresent(SourceFormat.self, forKey: .sourceFormat)
      keyframeIntervalDuration = try c.decodeIfPresent(Double.self, forKey: .keyframeIntervalDuration)
      conversionNotes = try c.decodeIfPresent([String].self, forKey: .conversionNotes) ?? []
      mappingRevision = try c.decodeIfPresent(UInt64.self, forKey: .mappingRevision)
      videoMapping = try? c.decodeIfPresent(ClockMapping.self, forKey: .videoMapping)
      audioMapping = try? c.decodeIfPresent(ClockMapping.self, forKey: .audioMapping)
      audioOutputSampleRate = try? c.decodeIfPresent(Double.self, forKey: .audioOutputSampleRate)
    }
  }
  struct Event: Codable {
    var kind: String
    var detail: String
    var clockID: ClockInstanceID? = nil
    var mapping: ClockMapping? = nil
    var mappingRevision: UInt64? = nil
    var effectiveSequence: UInt64? = nil
    // Exact original timestamp/duration values; no floating-point rounding.
    var originalValue: Int64? = nil
    var originalTimescale: Int32? = nil
    var quantizationErrorSeconds: Double? = nil
    var originalTiming: RecordingTimebase.OriginalTiming? = nil
    var durationErrorSeconds: Double? = nil
    var intervalErrorSeconds: Double? = nil
    var nativeSourceTimecode: Timecode? = nil
    var nativeTimecodeMetadata: TimecodeMetadata? = nil
    var sourceDurationValue: Int64? = nil
    var sourceDurationTimescale: Int32? = nil
    var sourceProvenance: RecordingSourceProvenance? = nil
    /// `run` on a `nativeTimecode` record kept only where its run breaks: the frames after
    /// it count on from its label at the run's stride, up to the next record for the same
    /// label or a `nativeTimecodeGap`. Nil in journals from before it was written.
    var labelEncoding: String? = nil
    /// The frames a second a raw label (`nativeSourceTimecode`) counts to.
    var timecodeBase: Int64? = nil
    /// Which label a `nativeTimecodeGap` ends: `source` (`nativeSourceTimecode`) or
    /// `native` (`nativeTimecodeMetadata`). The frame it's at has none, and no reader
    /// counts a run across it.
    var labelSource: String? = nil
  }
  /// Where the journal stopped keeping records, and how many it didn't keep.
  struct JournalTruncation: Codable, Equatable {
    var firstOriginalValue: Int64? = nil
    var firstOriginalTimescale: Int32? = nil
    var suppressed: [String: UInt64] = [:]
  }
  struct Snapshot: Codable {
    var version = 1
    var metadata: Metadata
    var finished = false
    var finalError: String? = nil
    var counters: [String: UInt64] = [:]
    var journalBytes: Int = 0
    var timebaseDiagnostics: RecordingTimebase.Diagnostics? = nil
    var journalTruncation: JournalTruncation? = nil
    private enum CodingKeys: String, CodingKey { case version, metadata, finished, finalError, counters, journalBytes, timebaseDiagnostics, journalTruncation }
    init(metadata: Metadata) { self.metadata = metadata }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
      metadata = try c.decode(Metadata.self, forKey: .metadata)
      finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
      finalError = try c.decodeIfPresent(String.self, forKey: .finalError)
      counters = try c.decodeIfPresent([String: UInt64].self, forKey: .counters) ?? [:]
      journalBytes = try c.decodeIfPresent(Int.self, forKey: .journalBytes) ?? 0
      timebaseDiagnostics = try c.decodeIfPresent(RecordingTimebase.Diagnostics.self, forKey: .timebaseDiagnostics)
      journalTruncation = try c.decodeIfPresent(JournalTruncation.self, forKey: .journalTruncation)
    }
  }
  enum Failure: LocalizedError {
    case occupied, closed, journalFull, unresolvedAudio, journalFailure
    var errorDescription: String? {
      switch self {
      case .journalFailure: return "The recording metadata journal could not be written. Recording continued; timing records after that point were not kept."
      case .unresolvedAudio: return "Recording requires a resolved audio declaration."
      case .occupied: return "Take metadata already exists; it was preserved."
      case .closed: return "Take metadata is already finalized."
      case .journalFull: return "The recording metadata journal reached its limit. Recording continued; timing records after that point were not kept."
      }
    }
  }
  /// The end of the journal only takes `reserved` records: labels and other
  /// per-frame timing stop short of it, so clock history always has room.
  static let reservedJournalBytes = 1024 * 1024
  static func url(for movie: URL) -> URL { movie.appendingPathExtension("ultracam.json") }
  let url: URL
  let journalURL: URL
  let maximumJournalBytes: Int
  // Recorder admission and writer-queue native timecode can journal together.
  // Hold one lock across the journal write and its snapshot publication.
  private let lock = NSRecursiveLock()
  private var snapshotValue: Snapshot
  private(set) var snapshot: Snapshot {
    get { lock.withLock { snapshotValue } }
    set { lock.withLock { snapshotValue = newValue } }
  }
  private let journal: FileHandle
  private var journalFailed = false
  init(movieURL: URL, metadata: Metadata, maximumJournalBytes: Int = 16 * 1024 * 1024) throws {
    if case .unknown? = metadata.audioDeclaration { throw Failure.unresolvedAudio }
    url = Self.url(for: movieURL)
    journalURL = url.appendingPathExtension("journal")
    self.maximumJournalBytes = max(0, maximumJournalBytes)
    snapshotValue = Snapshot(metadata: metadata)
    // Exclusive journal creation reserves this pair, including concurrent starts.
    let descriptor = open(journalURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw Failure.occupied }
    journal = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.occupied }
      try save()
    } catch { try? journal.close(); try? FileManager.default.removeItem(at: journalURL); throw error }
  }
  private func save() throws { try save(snapshot) }
  private func save(_ candidate: Snapshot) throws {
    try JSONEncoder().encode(candidate).write(to: url, options: .atomic)
  }
  private func ensureWritable() throws {
    guard !journalFailed else { throw Failure.journalFailure }
    guard !snapshot.finished else { throw Failure.closed }
  }
  func append(_ event: Event) throws {
    lock.lock()
    defer { lock.unlock() }
    try ensureWritable()
    var data = try JSONEncoder().encode(event); data.append(0x0A)
    guard data.count <= maximumJournalBytes - snapshot.journalBytes else { throw Failure.journalFull }
    try commit(data)
  }
  /// The writer's way in. Metadata must never end a take: a record past its
  /// budget, or one the disk refused, is counted and dropped. False when it
  /// wasn't kept. Creating the sidecar at take start stays fatal.
  @discardableResult func journal(_ event: Event, reserved: Bool = false) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let budget = reserved ? maximumJournalBytes : maximumJournalBytes - Self.reservedJournalBytes
    do {
      try ensureWritable()
      var data = try JSONEncoder().encode(event); data.append(0x0A)
      guard data.count <= budget - snapshot.journalBytes else { suppress(event); return false }
      try commit(data)
      return true
    } catch {
      suppress(event)
      return false
    }
  }
  var suppressedRecords: UInt64 { snapshot.journalTruncation?.suppressed.values.reduce(0, &+) ?? 0 }
  /// Saved on the first record only, or a full journal would rewrite this file
  /// for every frame. Later counts reach the disk with the counters and at finish.
  private func suppress(_ event: Event) {
    guard !snapshot.finished else { return }
    let first = snapshot.journalTruncation == nil
    var truncation = snapshot.journalTruncation ?? JournalTruncation(firstOriginalValue: event.originalValue,
      firstOriginalTimescale: event.originalTimescale)
    truncation.suppressed[event.kind, default: 0] &+= 1
    snapshot.journalTruncation = truncation
    guard first else { return }
    snapshot.metadata.conversionNotes = snapshot.metadata.conversionNotes.map {
      $0.replacingOccurrences(of: "retained in the journal", with: "retained in the journal up to the point in journalTruncation")
    }
    snapshot.metadata.conversionNotes.append(Failure.journalFull.errorDescription ?? "")
    try? save()
  }
  private func commit(_ data: Data) throws {
    var candidate = snapshot
    candidate.journalBytes += data.count
    do {
      try journal.write(contentsOf: data)
      try journal.synchronize()
      try save(candidate)
      snapshot = candidate
    } catch {
      let originalError = error
      // Snapshot publication failed (or a partial journal write failed).
      // Roll back to the last committed boundary before permitting a retry.
      do {
        try journal.truncate(atOffset: UInt64(snapshot.journalBytes))
        try journal.seek(toOffset: UInt64(snapshot.journalBytes))
        try journal.synchronize()
      } catch {
        journalFailed = true
        throw Failure.journalFailure
      }
      throw originalError
    }
  }
  func updateTimebaseDiagnostics(_ diagnostics: RecordingTimebase.Diagnostics) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !snapshot.finished else { throw Failure.closed }
    var candidate = snapshot
    candidate.timebaseDiagnostics = diagnostics
    try save(candidate)
    snapshot = candidate
  }

  func updateCounters(_ counters: [String: UInt64]) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !snapshot.finished else { throw Failure.closed }
    var candidate = snapshot
    candidate.counters = counters
    try save(candidate)
    snapshot = candidate
  }
  /// A journal that failed doesn't stop this: the sidecar is its own file, and
  /// a movie can't be published until it reads finished.
  func finish(finalError: String? = nil) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !snapshot.finished else { throw Failure.closed }
    if !journalFailed {
      do { try journal.synchronize() }
      catch { suppress(Event(kind: "journalSynchronize", detail: String(describing: error))) }
    }
    var candidate = snapshot
    candidate.finished = true; candidate.finalError = finalError
    try save(candidate)
    snapshot = candidate
  }
  /// Caller holds the movie recovery lock. Original metadata stays in place.
  /// Exclusive copies never overwrite an unrelated destination.
  func copyForRecoveredMovie(_ movie: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    try Self.copyPairedMetadata(from: url, toMovie: movie)
  }
  static func copyPairedMetadata(from source: URL, toMovie movie: URL) throws {
    let journalURL = source.appendingPathExtension("journal")
    for file in [source, journalURL] {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.occupied }
    }
    let destination = Self.url(for: movie)
    let destinationJournal = destination.appendingPathExtension("journal")
    guard !FileManager.default.fileExists(atPath: destination.path),
      !FileManager.default.fileExists(atPath: destinationJournal.path) else { throw Failure.occupied }
    try FileManager.default.copyItem(at: journalURL, to: destinationJournal)
    do { try FileManager.default.copyItem(at: source, to: destination) }
    catch { try? FileManager.default.removeItem(at: destinationJournal); throw error }
  }
  static func readSnapshot(for movie: URL) throws -> Snapshot {
    let file = url(for: movie)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 1_048_576 else { throw Failure.occupied }
    return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
  }

  static func removePairedMetadata(for movie: URL) throws {
    let sidecar = url(for: movie)
    let journal = sidecar.appendingPathExtension("journal")
    for file in [sidecar, journal] {
      if FileManager.default.fileExists(atPath: file.path) {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.occupied }
      }
    }
    for file in [sidecar, journal] where FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }

  /// Called only for this already-owned take after movie deletion succeeds.
  func removePairMetadata() throws {
    lock.lock()
    defer { lock.unlock() }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.removeItem(at: journalURL)
  }
}
