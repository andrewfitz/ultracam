import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Identifies one source feed in the recording catalog. A recorder instance owns
/// exactly one output file for this feed.
struct SourceRecordingFeedID: Hashable, Codable, Sendable, CustomStringConvertible {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  var description: String { rawValue }
}

enum SourceRecordingState: Equatable, Sendable {
  case idle
  case recording
  case paused
  case stopping
  case finished
  case failed
}

enum SourceRecordingDropReason: String, Equatable, Sendable {
  case queueFull
  case paused
  case notRecording
  case invalidSample
  case writerNotReady
  case appendFailure
}

/// Exact codec contract for source recording. The capture callback supplies
/// the original packed 10-bit 4:2:2 buffer; this profile selects the hardware
/// encoder and, for HEVC Main10 4:2:2, the required profile level.
enum SourceRecordingVideoProfile: Equatable, Sendable {
  case hevcMain10_422
  case proRes422(ProRes422Profile)
  /// Compatibility escape hatch for callers that provide another codec.
  /// Custom codecs still receive the native source format and hardware-only
  /// encoder specification, but do not get a profile-level property.
  case custom(CMVideoCodecType)

  var codecType: CMVideoCodecType {
    switch self {
    case .hevcMain10_422: return kCMVideoCodecType_HEVC
    case let .proRes422(profile): return profile.codecType
    case let .custom(codec): return codec
    }
  }

  var profileLevel: String? {
    switch self {
    case .hevcMain10_422: return kVTProfileLevel_HEVC_Main42210_AutoLevel as String
    case .proRes422, .custom: return nil
    }
  }

  var displayName: String {
    switch self {
    case .hevcMain10_422: return "HEVC Main 10 4:2:2"
    case let .proRes422(profile): return profile.displayName
    case let .custom(codec): return "Video codec \(codec)"
    }
  }

  /// The source buffer remains packed 10-bit 4:2:2 (v210-like) through the
  /// handoff. No LUT, scaling, or pixel format conversion occurs here.
  var sourcePixelFormat: OSType { kCVPixelFormatType_422YpCbCr10 }

  /// Require hardware instead of merely preferring it so long-running source
  /// recording cannot silently fall back to a CPU encoder.
  var encoderSpecification: CFDictionary {
    [
      kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ] as CFDictionary
  }

  static func inferred(for codec: CMVideoCodecType) -> Self {
    switch codec {
    case kCMVideoCodecType_HEVC: return .hevcMain10_422
    case kCMVideoCodecType_AppleProRes422: return .proRes422(.standard)
    case kCMVideoCodecType_AppleProRes422HQ: return .proRes422(.highQuality)
    default: return .custom(codec)
    }
  }
}

/// The recorder accepts the capture callback's original CMSampleBuffer. No
/// Core Image, Metal, pixel-buffer conversion, or color transform is performed
/// by this layer.
struct SourceRecordingConfiguration {
  let feedID: SourceRecordingFeedID
  let outputURL: URL
  let width: Int
  let height: Int
  let videoCodec: CMVideoCodecType
  let videoProfile: SourceRecordingVideoProfile
  let fileType: AVFileType
  let queueCapacity: Int
  let realTimeEncoding: Bool
  let maxKeyFrameInterval: Int
  /// Source cadence used to describe a generated QuickTime timecode track.
  /// The default matches the recorder's historically supported 59.94 mode;
  /// callers that detect 29.97 must pass `.fps2997`.
  let frameRate: RecordingFrameRate
  let timecodePolicy: RecordingTimecodePolicy
  let timecodeDropFrame: Bool
  let timecodeStartDate: Date
  let timecodeSourceStartTime: CMTime
  /// When true for wall-clock policy, the writer samples the computer clock
  /// at the first encoded frame. An explicit `timecodeStartDate` is kept when
  /// this is false, which is the default.
  let timecodeSamplesComputerClockAtFirstFrame: Bool
  let checkAvailableSpace: (() throws -> Void)?

  init(feedID: SourceRecordingFeedID, outputURL: URL, width: Int, height: Int,
    videoCodec: CMVideoCodecType = kCMVideoCodecType_HEVC,
    videoProfile: SourceRecordingVideoProfile? = nil,
    fileType: AVFileType = .mov, queueCapacity: Int = 12,
    realTimeEncoding: Bool = true, maxKeyFrameInterval: Int = 60,
    frameRate: RecordingFrameRate = .fps5994,
    timecodePolicy: RecordingTimecodePolicy = .source,
    timecodeDropFrame: Bool? = nil,
    timecodeStartDate: Date = Date(),
    timecodeSourceStartTime: CMTime = .zero,
    timecodeSamplesComputerClockAtFirstFrame: Bool = false,
    checkAvailableSpace: (() throws -> Void)? = nil) throws {
    guard !feedID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SourceRecordingError.invalidConfiguration("A feed ID is required.")
    }
    guard width > 0, height > 0 else {
      throw SourceRecordingError.invalidConfiguration("Video dimensions must be positive.")
    }
    guard queueCapacity > 0 else {
      throw SourceRecordingError.invalidConfiguration("Queue capacity must be positive.")
    }
    guard maxKeyFrameInterval > 0 else {
      throw SourceRecordingError.invalidConfiguration("Key-frame interval must be positive.")
    }
    guard outputURL.isFileURL else {
      throw SourceRecordingError.invalidConfiguration("The recording destination must be a file URL.")
    }
    let selectedProfile = videoProfile ?? SourceRecordingVideoProfile.inferred(for: videoCodec)
    guard selectedProfile.codecType == videoCodec else {
      throw SourceRecordingError.invalidConfiguration(
        "Video profile \(selectedProfile.displayName) does not match codec \(videoCodec).")
    }
    guard timecodeSourceStartTime.isValid, timecodeSourceStartTime.isNumeric,
      timecodeSourceStartTime.epoch == 0, timecodeSourceStartTime.value >= 0 else {
      throw SourceRecordingError.invalidConfiguration("The timecode source start must be a non-negative CMTime.")
    }
    self.feedID = feedID
    self.outputURL = outputURL
    self.width = width
    self.height = height
    self.videoCodec = videoCodec
    self.videoProfile = selectedProfile
    self.fileType = fileType
    self.queueCapacity = queueCapacity
    self.realTimeEncoding = realTimeEncoding
    self.maxKeyFrameInterval = maxKeyFrameInterval
    self.frameRate = frameRate
    self.timecodePolicy = timecodePolicy
    self.timecodeDropFrame = timecodeDropFrame ?? (frameRate == .fps2997 || frameRate == .fps5994)
    self.timecodeStartDate = timecodeStartDate
    self.timecodeSourceStartTime = timecodeSourceStartTime
    self.timecodeSamplesComputerClockAtFirstFrame = timecodeSamplesComputerClockAtFirstFrame
    self.checkAvailableSpace = checkAvailableSpace
  }
}

struct SourceRecordingTelemetry: Equatable, Sendable {
  fileprivate(set) var state: SourceRecordingState = .idle
  fileprivate(set) var enqueuedVideo: UInt64 = 0
  fileprivate(set) var enqueuedAudio: UInt64 = 0
  fileprivate(set) var appendedVideo: UInt64 = 0
  fileprivate(set) var appendedAudio: UInt64 = 0
  fileprivate(set) var droppedQueueFull: UInt64 = 0
  fileprivate(set) var droppedPaused: UInt64 = 0
  fileprivate(set) var droppedNotRecording: UInt64 = 0
  fileprivate(set) var droppedInvalidSample: UInt64 = 0
  fileprivate(set) var droppedWriterNotReady: UInt64 = 0
  fileprivate(set) var droppedAppendFailure: UInt64 = 0
  fileprivate(set) var writerErrors: UInt64 = 0
  fileprivate(set) var encodedVideo: UInt64 = 0
  fileprivate(set) var droppedEncodedVideo: UInt64 = 0
  fileprivate(set) var encoderErrors: UInt64 = 0
  fileprivate(set) var droppedVideo: UInt64 = 0
  fileprivate(set) var droppedAudio: UInt64 = 0
  fileprivate(set) var droppedTimecode: UInt64 = 0
  fileprivate(set) var queueSamples = 0
  fileprivate(set) var queueCapacity = 0
  fileprivate(set) var encodedVideoBytes: UInt64 = 0
  fileprivate(set) var encoderLatencyMS: Double?
  fileprivate(set) var maxEncoderLatencyMS: Double?
  fileprivate(set) var hardwareEncoder: Bool?
  fileprivate(set) var encoderID: String?
  fileprivate(set) var encoderPendingFrames = 0
  fileprivate(set) var lastError: String?

  var totalDrops: UInt64 {
    droppedQueueFull + droppedPaused + droppedNotRecording + droppedInvalidSample +
      droppedWriterNotReady + droppedAppendFailure
  }
}

enum SourceRecordingError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration(String)
  case invalidState(SourceRecordingState, operation: String)
  case writerFailure(String)
  case writerNotReady(String)
  case unsupportedSample(String)

  var errorDescription: String? {
    switch self {
    case let .invalidConfiguration(message): return "Invalid recording configuration: \(message)"
    case let .invalidState(state, operation): return "Cannot \(operation) while recorder is \(state)."
    case let .writerFailure(message): return "Recording writer failed: \(message)"
    case let .writerNotReady(message): return "Recording writer is not ready: \(message)"
    case let .unsupportedSample(message): return "Unsupported recording sample: \(message)"
    }
  }
}

/// A testable boundary around AVAssetWriter. Implementations must preserve the
/// source sample timing and must not mutate or replace the source buffers.
struct SourceRecordingWriterTelemetry: Equatable, Sendable {
  var failed = false
  var droppedAudio: UInt64 = 0
  var droppedTimecode: UInt64 = 0
  var encodedVideoBytes: UInt64 = 0
  var encoderLatencyMS: Double?
  var maxEncoderLatencyMS: Double?
  var hardwareEncoder: Bool?
  var encoderID: String?
  var encoderPendingFrames = 0
  var encodedVideo: UInt64 = 0
  var droppedEncodedVideo: UInt64 = 0
  var encoderErrors: UInt64 = 0
  var lastError: String?
}

protocol SourceRecordingWriter: AnyObject {
  var telemetry: SourceRecordingWriterTelemetry { get }
  func start() throws
  func appendVideo(_ sample: CMSampleBuffer) throws
  func appendAudio(_ sample: CMSampleBuffer) throws
  func finish() throws
}

extension SourceRecordingWriter {
  var telemetry: SourceRecordingWriterTelemetry { SourceRecordingWriterTelemetry() }
}

/// Queue-confined recording controller. Callback callers only perform bounded
/// admission work; writing and VideoToolbox encoding happen on the private
/// serial queue. One instance maps to one feed and one output file.
final class SourceRecorderCore: @unchecked Sendable {
  typealias WriterFactory = () throws -> SourceRecordingWriter

  private enum SampleKind {
    case video
    case audio
  }

  // Core Media samples are reference-counted and are intentionally handed to
  // one serial writer queue. The SDK does not annotate CMSampleBuffer as
  // Sendable, so keep the cross-queue handoff explicit at this boundary.
  private struct QueuedSample: @unchecked Sendable {
    let value: CMSampleBuffer
  }

  private let queue: DispatchQueue
  private let stateLock = NSLock()
  /// Counts an admission that has not yet reached `queue.async`. `stop` waits
  /// for it so finish cannot run in that gap, and the lock is not held across
  /// the async submit.
  private let admission = DispatchGroup()
  private let stopCompletion = DispatchGroup()
  private let queueKey = DispatchSpecificKey<Bool>()
  private var stopStarted = false
  private var stopResult: Result<Void, SourceRecordingError>?
  private let configuration: SourceRecordingConfiguration
  private let writer: SourceRecordingWriter
  private var telemetryValue = SourceRecordingTelemetry()
  private var pending = 0

  init(configuration: SourceRecordingConfiguration, writerFactory: @escaping WriterFactory) throws {
    self.configuration = configuration
    self.writer = try writerFactory()
    self.queue = DispatchQueue(label: "org.ultracam.recording.\(configuration.feedID.rawValue)",
      qos: .userInitiated)
    self.queue.setSpecific(key: queueKey, value: true)
  }

  convenience init(configuration: SourceRecordingConfiguration) throws {
    try self.init(configuration: configuration, writerFactory: {
      try AVAssetSourceRecordingWriter(configuration: configuration)
    })
  }

  var state: SourceRecordingState { telemetry.state }
  var telemetry: SourceRecordingTelemetry {
    let writerSnapshot = writer.telemetry
    return stateLock.withLock {
      if writerSnapshot.failed {
        telemetryValue.state = .failed
        if telemetryValue.lastError == nil { telemetryValue.lastError = writerSnapshot.lastError }
      }
      var snapshot = telemetryValue
      snapshot.encodedVideo = writerSnapshot.encodedVideo
      snapshot.droppedEncodedVideo = writerSnapshot.droppedEncodedVideo
      snapshot.encoderErrors = writerSnapshot.encoderErrors
      snapshot.droppedAudio &+= writerSnapshot.droppedAudio
      snapshot.droppedTimecode = writerSnapshot.droppedTimecode
      snapshot.encodedVideoBytes = writerSnapshot.encodedVideoBytes
      snapshot.encoderLatencyMS = writerSnapshot.encoderLatencyMS
      snapshot.maxEncoderLatencyMS = writerSnapshot.maxEncoderLatencyMS
      snapshot.hardwareEncoder = writerSnapshot.hardwareEncoder
      snapshot.encoderID = writerSnapshot.encoderID
      snapshot.encoderPendingFrames = writerSnapshot.encoderPendingFrames
      snapshot.queueSamples = pending
      snapshot.queueCapacity = configuration.queueCapacity
      if snapshot.lastError == nil { snapshot.lastError = writerSnapshot.lastError }
      return snapshot
    }
  }

  func start() throws {
    try queue.sync {
      let current = stateLock.withLock { telemetryValue.state }
      guard current == .idle else {
        throw SourceRecordingError.invalidState(current, operation: "start")
      }
      do {
        try writer.start()
        stateLock.withLock { telemetryValue.state = .recording }
      } catch {
        let failure = Self.recordingError(error)
        stateLock.withLock {
          telemetryValue.state = .failed
          telemetryValue.writerErrors &+= 1
          telemetryValue.lastError = failure.localizedDescription
        }
        throw failure
      }
    }
  }

  @discardableResult
  func appendVideo(_ sample: CMSampleBuffer) -> Bool {
    enqueue(sample, kind: .video)
  }

  @discardableResult
  func appendAudio(_ sample: CMSampleBuffer) -> Bool {
    enqueue(sample, kind: .audio)
  }

  func pause() throws {
    try stateLock.withLock {
      guard telemetryValue.state == .recording else {
        throw SourceRecordingError.invalidState(telemetryValue.state, operation: "pause")
      }
      telemetryValue.state = .paused
    }
  }

  func resume() throws {
    try stateLock.withLock {
      guard telemetryValue.state == .paused else {
        throw SourceRecordingError.invalidState(telemetryValue.state, operation: "resume")
      }
      telemetryValue.state = .recording
    }
  }

  /// Drains already admitted samples before finalizing the writer. New callback
  /// samples are rejected once stopping begins. Calls on the recorder queue
  /// (including writer callbacks on that queue) return without waiting, since
  /// waiting there would deadlock the caller performing finalization.
  func stop() throws {
    guard DispatchQueue.getSpecific(key: queueKey) != true else { return }
    let failedBeforeStop = state == .failed
    let shouldStop = stateLock.withLock { () -> Bool in
      guard !stopStarted, telemetryValue.state != .idle else { return false }
      stopStarted = true
      stopCompletion.enter()
      telemetryValue.state = .stopping
      return true
    }
    guard shouldStop else {
      stopCompletion.wait()
      try stateLock.withLock { try stopResult?.get() }
      return
    }
    admission.wait()
    let result: Result<Void, SourceRecordingError> = queue.sync {
      do {
        try writer.finish()
        let writerFailed = writer.telemetry.failed
        stateLock.withLock {
          // A sample that failed while this stop was draining must stay failed.
          telemetryValue.state = failedBeforeStop || writerFailed || telemetryValue.state == .failed
            ? .failed : .finished
        }
        return .success(())
      } catch {
        let failure = Self.recordingError(error)
        stateLock.withLock {
          telemetryValue.state = .failed
          telemetryValue.writerErrors &+= 1
          telemetryValue.lastError = failure.localizedDescription
        }
        return .failure(failure)
      }
    }
    stateLock.withLock { stopResult = result }
    stopCompletion.leave()
    try result.get()
  }

  private func enqueue(_ sample: CMSampleBuffer, kind: SampleKind) -> Bool {
    guard Self.isReady(sample, kind: kind) else {
      recordDrop(.invalidSample, video: kind == .video)
      return false
    }
    _ = telemetry // Observe asynchronous writer failures before admitting media.
    let queuedSample = QueuedSample(value: sample)
    let admitted = stateLock.withLock { () -> Bool in
      guard telemetryValue.state == .recording else {
        switch telemetryValue.state {
        case .paused: telemetryValue.droppedPaused &+= 1
        case .idle, .finished, .failed, .stopping: telemetryValue.droppedNotRecording &+= 1
        case .recording: break
        }
        return false
      }
      guard pending < configuration.queueCapacity else {
        telemetryValue.droppedQueueFull &+= 1
        if kind == .video { telemetryValue.droppedVideo &+= 1 } else { telemetryValue.droppedAudio &+= 1 }
        return false
      }
      pending += 1
      admission.enter()
      switch kind {
      case .video: telemetryValue.enqueuedVideo &+= 1
      case .audio: telemetryValue.enqueuedAudio &+= 1
      }
      return true
    }
    guard admitted else { return false }
    defer { admission.leave() }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.stateLock.withLock { self.pending -= 1 } }
      _ = self.telemetry
      let shouldAppend = self.stateLock.withLock { () -> Bool in
        switch self.telemetryValue.state {
        case .recording, .paused, .stopping: return true
        case .idle, .finished, .failed: return false
        }
      }
      guard shouldAppend else {
        self.recordDrop(.notRecording, video: kind == .video)
        return
      }
      do {
        try self.configuration.checkAvailableSpace?()
        switch kind {
        case .video:
          try self.writer.appendVideo(queuedSample.value)
          self.stateLock.withLock { self.telemetryValue.appendedVideo &+= 1 }
        case .audio:
          try self.writer.appendAudio(queuedSample.value)
          self.stateLock.withLock { self.telemetryValue.appendedAudio &+= 1 }
        }
      } catch {
        let failure = Self.recordingError(error)
        self.stateLock.withLock {
          if kind == .video { self.telemetryValue.droppedVideo &+= 1 } else { self.telemetryValue.droppedAudio &+= 1 }
          if case .writerNotReady = failure {
            self.telemetryValue.droppedWriterNotReady &+= 1
            self.telemetryValue.lastError = failure.localizedDescription
          } else {
            self.telemetryValue.droppedAppendFailure &+= 1
            self.telemetryValue.writerErrors &+= 1
            self.telemetryValue.lastError = failure.localizedDescription
            self.telemetryValue.state = .failed
          }
        }
      }
    }
    return true
  }

  /// Records a rejection made before a CMSampleBuffer exists, such as an invalid
  /// Blackmagic signal flag or packet metadata.
  func recordDrop(_ reason: SourceRecordingDropReason, video: Bool = true) {
    stateLock.withLock {
      // Paused/stopped callbacks are intentionally ignored, not lost frames.
      if reason != .paused && reason != .notRecording {
        if video { telemetryValue.droppedVideo &+= 1 } else { telemetryValue.droppedAudio &+= 1 }
      }
      switch reason {
      case .invalidSample: telemetryValue.droppedInvalidSample &+= 1
      case .queueFull: telemetryValue.droppedQueueFull &+= 1
      case .paused: telemetryValue.droppedPaused &+= 1
      case .notRecording: telemetryValue.droppedNotRecording &+= 1
      case .writerNotReady: telemetryValue.droppedWriterNotReady &+= 1
      case .appendFailure: telemetryValue.droppedAppendFailure &+= 1
      }
    }
  }

  private static func isReady(_ sample: CMSampleBuffer, kind: SampleKind) -> Bool {
    guard CMSampleBufferDataIsReady(sample),
      CMSampleBufferGetPresentationTimeStamp(sample).isValid,
      CMSampleBufferGetPresentationTimeStamp(sample).isNumeric,
      CMSampleBufferGetPresentationTimeStamp(sample).epoch == 0,
      CMSampleBufferGetPresentationTimeStamp(sample).value >= 0,
      CMSampleBufferGetDuration(sample).isValid,
      CMSampleBufferGetDuration(sample).isNumeric,
      CMSampleBufferGetDuration(sample).epoch == 0,
      CMSampleBufferGetDuration(sample).value > 0 else { return false }
    switch kind {
    case .video:
      return CMSampleBufferGetImageBuffer(sample) != nil &&
        CMSampleBufferGetFormatDescription(sample) != nil
    case .audio:
      return CMSampleBufferGetFormatDescription(sample) != nil &&
        CMSampleBufferGetNumSamples(sample) > 0
    }
  }

  private static func recordingError(_ error: Error) -> SourceRecordingError {
    if let error = error as? SourceRecordingError { return error }
    return .writerFailure(error.localizedDescription)
  }
}

/// Product-facing name for the per-feed source recorder. The typealias keeps
/// the queue and writer contracts available to synthetic tests without pulling
/// capture or UI dependencies into this module.
typealias DirectSourceRecorder = SourceRecorderCore
