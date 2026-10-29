import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import os
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
  case matrix(RecordingProfileMatrixProfile)
  /// Compatibility escape hatch for callers that provide another codec.
  /// Custom codecs still receive the native source format and hardware-only
  /// encoder specification, but do not get a profile-level property.
  case custom(CMVideoCodecType)

  var codecType: CMVideoCodecType {
    switch self {
    case .hevcMain10_422: return kCMVideoCodecType_HEVC
    case let .proRes422(profile): return profile.codecType
    case let .matrix(profile): return profile.codec
    case let .custom(codec): return codec
    }
  }

  var profileLevel: String? {
    switch self {
    case .hevcMain10_422: return kVTProfileLevel_HEVC_Main42210_AutoLevel as String
    case let .matrix(profile): return profile.profileLevel
    case .proRes422, .custom: return nil
    }
  }

  var displayName: String {
    switch self {
    case .hevcMain10_422: return "HEVC Main 10 4:2:2"
    case let .proRes422(profile): return profile.displayName
    case let .matrix(profile): return profile.displayName
    case let .custom(codec): return "Video codec \(codec)"
    }
  }

  /// The declarative B5 profile represented by this source recorder profile.
  /// Custom codecs remain an explicit compatibility escape hatch and are not
  /// silently assigned a matrix contract.
  var recordingMatrixProfile: RecordingProfileMatrixProfile? {
    switch self {
    case .hevcMain10_422: return .hevcMain10_422
    case .proRes422(.standard): return .proRes422
    case .proRes422(.highQuality): return .proRes422HQ
    case let .matrix(profile): return profile
    case .custom: return nil
    }
  }

  /// The source buffer remains packed 10-bit 4:2:2 (v210-like) through the
  /// handoff. No LUT, scaling, or pixel format conversion occurs here.

  var sourcePixelFormat: OSType { kCVPixelFormatType_422YpCbCr10 }

  /// The layout the Apple Silicon hardware encoders take natively ('x422',
  /// 10-bit 4:2:2 biplanar video range). The hardware ProRes and HEVC encoders
  /// do not list v210, so the writer repacks v210 into this on the GPU;
  /// otherwise VideoToolbox would convert every frame on the CPU.
  var encoderPixelFormat: OSType {
    if case .matrix(let profile) = self { return profile.encoderPixelFormat }
    return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
  }

  /// Require hardware instead of merely preferring it so long-running source
  /// recording cannot silently fall back to a CPU encoder.
  var encoderSpecification: CFDictionary {
    [
      kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ] as CFDictionary
  }

  /// Bytes per pixel per frame the encoder writes at most for typical camera
  /// content. ProRes 422 HQ at 3840 × 2160 59.94 is about 221 MB/s (0.444);
  /// ProRes 422 two thirds of that; HEVC well under. Only the free-space
  /// guard uses it, before a take has measured its own rate.
  var nominalBytesPerPixel: Double {
    switch self {
    case .hevcMain10_422: return 0.15
    case .proRes422(.standard): return 0.30
    case .proRes422(.highQuality), .custom: return 0.444
    case .matrix(let profile):
      switch profile {
      case .proResLT: return 0.21
      case .proRes422: return 0.30
      case .proRes422HQ: return 0.444
      case .proRes4444: return 0.889
      case .hevcMain, .hevcMain10, .hevcMain10_422: return 0.15
      }
    }
  }

  static func inferred(for codec: CMVideoCodecType) -> Self {
    switch codec {
    case kCMVideoCodecType_HEVC: return .hevcMain10_422
    case kCMVideoCodecType_AppleProRes422: return .proRes422(.standard)
    case kCMVideoCodecType_AppleProRes422HQ: return .proRes422(.highQuality)
    case kCMVideoCodecType_AppleProRes422LT: return .matrix(.proResLT)
    case kCMVideoCodecType_AppleProRes4444: return .matrix(.proRes4444)
    default: return .custom(codec)
    }
  }
}

/// The recorder accepts the capture callback's original CMSampleBuffer. No
/// Core Image, Metal, pixel-buffer conversion, or color transform is performed
/// by this layer.
struct RecordingSourceProvenance: Codable, Equatable, Sendable {
  let epochID: CaptureEpochID
  let formatSignature: String
  let videoClock: ClockInstanceID
  let audioClock: ClockInstanceID?
  init(epochID: CaptureEpochID, formatSignature: String, videoClock: ClockInstanceID, audioClock: ClockInstanceID? = nil) {
    self.epochID = epochID; self.formatSignature = formatSignature
    self.videoClock = videoClock; self.audioClock = audioClock
  }
}

struct SourceRecordingConfiguration {
  let feedID: SourceRecordingFeedID
  let outputURL: URL
  /// Immutable original-source contract; derived encoder buffers are not source frames.
  let sourceAdmission: SourceAdmissionSnapshot?
  let expectedSourceFormat: SourceFormat?
  let compatibilityPolicy: RecordingCompatibilityPolicy
  let sidecarMovieURL: URL?
  let sidecarCreated: (() throws -> Void)?
  let videoRetentionPolicy: MediaRetentionPolicy
  let audioRetentionPolicy: MediaRetentionPolicy
  let width: Int
  let height: Int
  let videoCodec: CMVideoCodecType
  let videoProfile: SourceRecordingVideoProfile
  let fileType: AVFileType
  /// Video frames that may wait for the encoder stage. Each one holds a
  /// source capture buffer of about 22 MB at 2160p v210 that the driver
  /// cannot reuse, so this is kept to 12 (0.2 s at 59.94): an encoder that
  /// stalls fails the take visibly before the driver's own pool runs dry and
  /// the device starts dropping frames. Disk stalls are absorbed after the
  /// encoder instead, by `maximumBufferedWriterBytes`.
  let queueCapacity: Int
  /// Audio packets that may wait for the encoder stage (about 4 s at 59.94).
  let audioQueueCapacity: Int
  /// Supplemental metadata cap; PCM retention is primarily limited by seconds and bytes.
  static let defaultAudioMetadataSlots = 32_768
  /// Compressed media that may wait for the disk (1 GiB, about 4.8 s of
  /// ProRes 422 HQ 2160p59.94 at 221 MB/s). Going past it fails the take.
  let maximumBufferedWriterBytes: Int
  /// How often `checkAvailableSpace` runs while recording, off the media path.
  let spaceCheckInterval: TimeInterval
  let realTimeEncoding: Bool
  /// Legacy explicit frame-count request, converted at the actual source cadence.
  let maxKeyFrameInterval: Int?
  let maxKeyFrameIntervalDuration: TimeInterval
  /// Source cadence used to describe a generated QuickTime timecode track.
  /// The default matches the recorder's historically supported 59.94 mode;
  /// callers that detect 29.97 must pass `.fps2997`.
  let frameRate: RecordingFrameRate
  let declaredTimebases: [Int32]?
  let quantizationPolicy: RecordingTimebase.QuantizationPolicy?
  let sourceFrameRate: FrameRate?
  let recordingConstantFrameRate: Bool
  let nativeTimecodeMetadata: TimecodeMetadata?
  let timecodePolicy: RecordingTimecodePolicy
  let timecodeDropFrame: Bool
  let timecodeStartDate: Date
  let timecodeSourceStartTime: CMTime
  /// When true for wall-clock policy, the writer samples the computer clock
  /// at the first encoded frame. An explicit `timecodeStartDate` is kept when
  /// this is false, which is the default.
  let timecodeSamplesComputerClockAtFirstFrame: Bool
  /// Checks the volume keeps its free-space floor plus the given headroom:
  /// everything already accepted but not yet on disk, and what the take will
  /// write before the next check. Throws when it does not.
  let checkAvailableSpace: ((UInt64) throws -> Void)?

  /// The capture backend's per-frame host capture time (a CFNumber of host
  /// clock seconds). Matches `UltracamCaptureHostTimeAttachmentKey`, which
  /// this module cannot import: it also builds without the bridging header.
  static let sourceProvenanceAttachmentKey = "UltracamRecordingSourceProvenance"
  static let sourceTimecodeAttachmentKey = "UltracamSourceTimecode"
  static let nativeTimecodeAttachmentKey = "UltracamNativeTimecodeMetadata"
  static let captureHostTimeAttachmentKey = "UltracamCaptureHostTime"

  func keyframeDuration(for rate: RecordingFrameRate) -> TimeInterval {
    guard let maxKeyFrameInterval else { return maxKeyFrameIntervalDuration }
    let duration = sourceFrameRate?.nominal ?? sourceAdmission?.format.rate.nominal ?? rate.frameDuration
    return Double(maxKeyFrameInterval) * duration.seconds
  }

  var outputFrameRate: FrameRate? {
    let source = sourceFrameRate ?? sourceAdmission?.format.rate ?? expectedSourceFormat?.rate
    guard recordingConstantFrameRate, let source, source.isVariable else { return source }
    return .constant(source.nominal)
  }

  var sourcePixelFormat: OSType { sourceAdmission?.format.pixel.rawValue ?? expectedSourceFormat?.pixel.rawValue ?? videoProfile.sourcePixelFormat }

  /// The most this take is expected to write per second before it has
  /// measured its own rate (see `SourceRecordingVideoProfile.nominalBytesPerPixel`).
  var nominalBytesPerSecond: Double {
    let duration = sourceFrameRate?.nominal ?? frameRate.frameDuration
    let codec: RecordingSizeEstimator.Codec?
    switch videoProfile {
    case .hevcMain10_422: codec = .hevcMain10_422
    case .proRes422(.standard): codec = .proRes422
    case .proRes422(.highQuality): codec = .proRes422HQ
    case .matrix(let profile):
      switch profile {
      case .proResLT: codec = .proResLT
      case .proRes422: codec = .proRes422
      case .proRes422HQ: codec = .proRes422HQ
      case .proRes4444: codec = .proRes4444
      case .hevcMain: codec = .hevcMain
      case .hevcMain10: codec = .hevcMain10
      case .hevcMain10_422: codec = .hevcMain10_422
      }
    case .custom: codec = nil
    }
    if let codec, let estimate = RecordingSizeEstimator(codec: codec, width: width, height: height, frameDuration: duration) {
      return estimate.bytesPerSecond
    }
    return videoProfile.nominalBytesPerPixel * Double(width) * Double(height) / duration.seconds
  }

  init(feedID: SourceRecordingFeedID, outputURL: URL, width: Int, height: Int,
    videoCodec: CMVideoCodecType = kCMVideoCodecType_HEVC,
    videoProfile: SourceRecordingVideoProfile? = nil,
    fileType: AVFileType = .mov, queueCapacity: Int = 12,
    audioQueueCapacity: Int = SourceRecordingConfiguration.defaultAudioMetadataSlots,
    maximumBufferedWriterBytes: Int = AVAssetSourceRecordingWriter.defaultMaximumBufferedBytes,
    spaceCheckInterval: TimeInterval = 1,
    realTimeEncoding: Bool = true, maxKeyFrameInterval: Int? = nil, maxKeyFrameIntervalDuration: TimeInterval = 1,
    frameRate: RecordingFrameRate = .fps5994,
    declaredTimebases: [Int32]? = nil, quantizationPolicy: RecordingTimebase.QuantizationPolicy? = nil, sourceFrameRate: FrameRate? = nil, recordingConstantFrameRate: Bool = false, nativeTimecodeMetadata: TimecodeMetadata? = nil,
    timecodePolicy: RecordingTimecodePolicy = .source,
    timecodeDropFrame: Bool? = nil,
    sourceTimecode: String? = nil,
    timecodeStartDate: Date = Date(),
    timecodeSourceStartTime: CMTime = .zero,
    timecodeSamplesComputerClockAtFirstFrame: Bool = false,
    checkAvailableSpace: ((UInt64) throws -> Void)? = nil,
    sourceAdmission: SourceAdmissionSnapshot? = nil, expectedSourceFormat: SourceFormat? = nil,
    compatibilityPolicy: RecordingCompatibilityPolicy = .init(), sidecarMovieURL: URL? = nil,
    sidecarCreated: (() throws -> Void)? = nil,
    videoRetentionPolicy: MediaRetentionPolicy? = nil, audioRetentionPolicy: MediaRetentionPolicy? = nil) throws {
    guard !feedID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SourceRecordingError.invalidConfiguration("A feed ID is required.")
    }
    guard width > 0, height > 0 else {
      throw SourceRecordingError.invalidConfiguration("Video dimensions must be positive.")
    }
    guard queueCapacity > 0, audioQueueCapacity > 0, maximumBufferedWriterBytes > 0 else {
      throw SourceRecordingError.invalidConfiguration("Queue capacity must be positive.")
    }
    guard spaceCheckInterval > 0 else {
      throw SourceRecordingError.invalidConfiguration("The space-check interval must be positive.")
    }
    guard maxKeyFrameInterval.map({ $0 > 0 }) ?? true,
      maxKeyFrameIntervalDuration.isFinite, maxKeyFrameIntervalDuration > 0 else {
      throw SourceRecordingError.invalidConfiguration("Key-frame interval must be positive.")
    }
    guard outputURL.isFileURL else {
      throw SourceRecordingError.invalidConfiguration("The recording destination must be a file URL.")
    }
    if let declaredRate = sourceFrameRate ?? sourceAdmission?.format.rate ?? expectedSourceFormat?.rate {
      do { _ = try RecordingTimebase.Configuration(frameRate: declaredRate, declaredTimebases: declaredTimebases, quantizationPolicy: quantizationPolicy) }
      catch { throw SourceRecordingError.invalidConfiguration("Recording timebase admission failed: " + String(describing: error)) }
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
    if let actual = sourceAdmission?.format, let expectedSourceFormat, actual.signature != expectedSourceFormat.signature {
      throw SourceRecordingError.invalidConfiguration("The recording source declaration changed while preparing the take.")
    }
    if let format = sourceAdmission?.format ?? expectedSourceFormat {
      do { try format.validate(); _ = try SourceSizeAdmission.validate(format) }
      catch { throw SourceRecordingError.invalidConfiguration("Recording source admission failed: " + String(describing: error)) }
      guard sourceFrameRate == nil || sourceFrameRate == format.rate else {
        throw SourceRecordingError.invalidConfiguration("The recording cadence differs from its source declaration.")
      }
      guard format.width == width, format.height == height,
        (selectedProfile.recordingMatrixProfile != nil || format.pixel.rawValue == selectedProfile.sourcePixelFormat) else {
        throw SourceRecordingError.invalidConfiguration("Recording source declaration differs from configured dimensions or pixel format.")
      }
      if let matrixProfile = selectedProfile.recordingMatrixProfile {
        do {
          try RecordingProfileMatrix.validate(matrixProfile, source: format)
        } catch {
          throw SourceRecordingError.invalidConfiguration(
            "Recording profile (matrixProfile.displayName) is not supported by the declared source: (error).")
        }
      }
    }
    self.compatibilityPolicy = compatibilityPolicy
    self.sidecarMovieURL = sidecarMovieURL
    self.sidecarCreated = sidecarCreated
    self.videoRetentionPolicy = try videoRetentionPolicy ?? MediaRetentionPolicy(maximumBytes: 512 * 1024 * 1024,
      maximumDuration: max(0.25, (sourceFrameRate?.nominal ?? frameRate.frameDuration).seconds * Double(queueCapacity)),
      maximumSlots: queueCapacity, minimumSlots: min(2, queueCapacity))
    self.audioRetentionPolicy = try audioRetentionPolicy ?? MediaRetentionPolicy(maximumBytes: 64 * 1024 * 1024,
      maximumDuration: 4, maximumSlots: audioQueueCapacity)

    self.sourceAdmission = sourceAdmission
    self.expectedSourceFormat = expectedSourceFormat
    self.feedID = feedID
    self.outputURL = outputURL
    self.width = width
    self.height = height
    self.videoCodec = videoCodec
    self.videoProfile = selectedProfile
    self.fileType = fileType
    self.queueCapacity = queueCapacity
    self.audioQueueCapacity = audioQueueCapacity
    self.maximumBufferedWriterBytes = maximumBufferedWriterBytes
    self.spaceCheckInterval = spaceCheckInterval
    self.realTimeEncoding = realTimeEncoding
    self.maxKeyFrameInterval = maxKeyFrameInterval
    self.maxKeyFrameIntervalDuration = maxKeyFrameIntervalDuration
    self.frameRate = frameRate
    self.declaredTimebases = declaredTimebases
    self.quantizationPolicy = quantizationPolicy
    self.sourceFrameRate = sourceFrameRate
    self.recordingConstantFrameRate = recordingConstantFrameRate
    self.nativeTimecodeMetadata = nativeTimecodeMetadata
    self.timecodePolicy = timecodePolicy
    // Drop-frame follows, in order: an explicit choice; for record-start
    // timecode (which continues the camera's count) the flag the source's own
    // timecode declares (`;` before frames); otherwise the SMPTE convention
    // for 29.97/59.94. Wall-clock timecode counts the computer's clock, so a
    // camera's NDF flag has no bearing on it: it always uses the convention.
    let sourceDropFrame = timecodePolicy == .recordStart
      ? sourceTimecode.flatMap(RecordingTimecode.dropFrame(declaredBy:)) : nil
    self.timecodeDropFrame = timecodeDropFrame ?? sourceDropFrame
      ?? (frameRate == .fps2997 || frameRate == .fps5994)
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
  fileprivate(set) var queuedAudio = 0
  /// Compressed media waiting for the disk, and its peak and limit.
  fileprivate(set) var writerBufferedBytes = 0
  fileprivate(set) var writerMaxBufferedBytes = 0
  fileprivate(set) var writerBufferCapacityBytes = 0
  /// Frames repacked on the GPU into the encoder's native format, frames
  /// handed over unchanged, and frames VideoToolbox had to convert on the CPU.
  fileprivate(set) var cadenceRepeatedFrames: UInt64 = 0
  fileprivate(set) var cadenceSkippedFrames: UInt64 = 0
  fileprivate(set) var gpuConvertedFrames: UInt64 = 0
  fileprivate(set) var passThroughFrames: UInt64 = 0
  fileprivate(set) var cpuConvertedFrames: UInt64 = 0
  fileprivate(set) var systemCompatibilityFrames: UInt64 = 0
  fileprivate(set) var gpuConversionFailures: UInt64 = 0
  fileprivate(set) var droppedGPUFrames: UInt64 = 0
  fileprivate(set) var videoClockDiscontinuities: UInt64 = 0
  fileprivate(set) var mappedAudioFrames: UInt64 = 0
  fileprivate(set) var audioClockDiscontinuities: UInt64 = 0
  fileprivate(set) var audioCorrectionRatio: Double = 1
  fileprivate(set) var gpuConversionMS: Double?
  fileprivate(set) var encoderInputFormat: String?
  fileprivate(set) var spaceChecks: UInt64 = 0
  /// Frames missing between consecutive capture timestamps during the take
  /// (counted in `droppedVideo` too): a signal dropout or a device skip. The
  /// file holds the frame before each gap; `sourceGaps` counts the gaps.
  fileprivate(set) var deviceSkippedFrames: UInt64 = 0
  fileprivate(set) var sourceGaps: UInt64 = 0
  fileprivate(set) var largestSourceGap: UInt64 = 0
  /// Times the embedded audio was re-anchored to the video clock mid-take,
  /// and how many of those moved it earlier (a backward re-sync).
  fileprivate(set) var audioReanchors: UInt64 = 0
  fileprivate(set) var audioBackwardResyncs: UInt64 = 0
  /// Audio sample frames left out because audio already recorded covered
  /// their instants, and frames of silence that filled holes in the audio.
  fileprivate(set) var audioResyncTrimmedFrames: UInt64 = 0
  fileprivate(set) var audioSilenceFilledFrames: UInt64 = 0
  /// A short note when audio was re-synced backward; joins `warning`.
  fileprivate(set) var audioSyncNote: String?
  /// The take is still healthy but something deserves attention, such as
  /// VideoToolbox converting frames on the CPU. Never a failure.
  fileprivate(set) var warning: String?
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
  var bufferedBytes = 0
  var maxBufferedBytes = 0
  var bufferedSamples = 0
  var bufferCapacityBytes = 0
  var cadenceRepeatedFrames: UInt64 = 0
  var cadenceSkippedFrames: UInt64 = 0
  var gpuConvertedFrames: UInt64 = 0
  var passThroughFrames: UInt64 = 0
  var cpuConvertedFrames: UInt64 = 0
  var systemCompatibilityFrames: UInt64 = 0
  var gpuConversionFailures: UInt64 = 0
  var droppedGPUFrames: UInt64 = 0
  var mappedAudioFrames: UInt64 = 0
  var audioClockDiscontinuities: UInt64 = 0
  var audioCorrectionRatio: Double = 1
  var gpuConversionMS: Double?
  var encoderInputFormat: String?
  var nativeEncoderInput: Bool?
  /// Every byte of encoded media handed to the file writer so far.
  var acceptedBytes: UInt64 = 0
  /// Audio packets left out at a resume because they overlapped audio
  /// already written before the pause (at most about one per resume).
  var pauseTrimmedAudio: UInt64 = 0
  var warning: String?
  var lastError: String?
}

/// A testable boundary around AVAssetWriter. Implementations must preserve the
/// source sample timing (the only change allowed is taking out the time a
/// take spent paused, see `resumeAfterPause`) and must not mutate or replace
/// the source buffers.
enum RecordingVideoAppendOutcome { case appended, dropped }

protocol SourceRecordingWriter: AnyObject {
  var telemetry: SourceRecordingWriterTelemetry { get }
  /// Read on the capture thread before admitting media. Implementations must
  /// answer without waiting on encoder, disk or any lock held across them.
  var hasFailed: Bool { get }
  func start() throws
  func bindTakeContext(_ context: RecordingTakeContext) throws
  func noteClockMapping(_ event: RecordingClockMappingEvent) throws
  func finish(finalError: String?) throws
  func finish(finalError: String?, sourceCounters: [String: UInt64]) throws
  func appendVideoOutcome(_ sample: CMSampleBuffer) throws -> RecordingVideoAppendOutcome
  func bindSourceAdmission(_ snapshot: SourceAdmissionSnapshot) throws
  func appendVideo(_ sample: CMSampleBuffer) throws
  func appendAudio(_ sample: CMSampleBuffer) throws
  func appendSourceAudio(_ sample: CMSampleBuffer, mapping: AudioVideoClockMapping) throws
  func appendPairedSourceAudio(_ sample: CMSampleBuffer, videoTime: CMTime) throws
  /// Called on the recorder queue after every sample admitted before a pause
  /// and before any sample admitted after the matching resume.
  func resumeAfterPause()
  func finish() throws
}

extension SourceRecordingWriter {
  var telemetry: SourceRecordingWriterTelemetry { SourceRecordingWriterTelemetry() }
  var hasFailed: Bool { telemetry.failed }
  func resumeAfterPause() {}
  func bindSourceAdmission(_ snapshot: SourceAdmissionSnapshot) throws {}
  func appendSourceAudio(_ sample: CMSampleBuffer, mapping: AudioVideoClockMapping) throws { try appendAudio(sample) }
  func appendPairedSourceAudio(_ sample: CMSampleBuffer, videoTime: CMTime) throws { try appendAudio(sample) }
  func bindTakeContext(_ context: RecordingTakeContext) throws {}
  func noteClockMapping(_ event: RecordingClockMappingEvent) throws {}
  func finish(finalError: String?) throws { try finish() }
  func finish(finalError: String?, sourceCounters: [String: UInt64]) throws { try finish(finalError: finalError) }
  func appendVideoOutcome(_ sample: CMSampleBuffer) throws -> RecordingVideoAppendOutcome {
    try appendVideo(sample); return .appended
  }
}

/// Queue-confined recording controller. Callback callers only perform bounded
/// admission work (metadata checks, one short lock, `queue.async`); GPU repack
/// and VideoToolbox submission happen on the private serial queue, and file
/// writing on the writer's own queue. One instance maps to one feed and file.
///
/// Nothing is dropped for being busy. If a queue's bound is ever exceeded the
/// take fails visibly (state `.failed`, `lastError` set) and the file written
/// so far is kept for recovery. A failure the recorder raises itself (a full
/// drive, an encoder that fell behind) still writes every sample it had
/// already admitted; only a failed file writer discards them.
///
/// Pause: samples arriving while paused are not recorded, and the file writer
/// is told where the take resumed so the movie continues without a gap (see
/// `AVAssetSourceRecordingWriter`). The writer still receives the capture
/// timestamps unchanged.
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
    let retention: MediaRetentionLedger.Lease
  }

  /// A gap this long or longer between capture timestamps is a discontinuity
  /// (a restarted source clock), not skipped frames.
  private static let maximumTimestampGapSeconds: Int64 = 10

  private let queue: DispatchQueue
  /// Short lock over state and counters. Never held across writer calls.
  private let stateLock = RecordingLock()
  /// Counts an admission that has not yet reached `queue.async`. `stop` waits
  /// for it so finish cannot run in that gap, and the lock is not held across
  /// the async submit.
  private let admission = DispatchGroup()
  private let stopCompletion = DispatchGroup()
  private let queueKey = DispatchSpecificKey<Bool>()
  private var stopStarted = false
  private var stopResult: Result<Void, SourceRecordingError>?
  private let configuration: SourceRecordingConfiguration
  private let videoRetention: MediaRetentionLedger
  private let audioRetention: MediaRetentionLedger
  private let writer: SourceRecordingWriter
  private var boundSourceAdmission: SourceAdmissionSnapshot?
  private var boundTakeContext: RecordingTakeContext?
  private var pendingMetadataEvents = 0
  private static let maximumMetadataEvents = 64
  private var telemetryValue = SourceRecordingTelemetry()
  private var pendingVideo = 0
  private var pendingAudio = 0
  /// The recorder itself failed the take (not the file writer): what it had
  /// already admitted is still written, so nothing accepted is lost.
  private var drainAdmittedAfterFailure = false
  /// The last admitted frame's capture time, for skipped-frame detection.
  private var lastAdmittedVideo: (pts: CMTime, duration: CMTime)?
  /// The latest capture time admitted this take. Unlike `lastAdmittedVideo`
  /// it survives a pause: capture time only moves forward within one input
  /// run, so going back means the input restarted.
  private var latestAdmittedVideoPTS: CMTime?
  private var invalidVideoSinceLastFrame = false
  /// The take's first capture time, so each gap is logged at its place in
  /// the take, and the bound on those lines for a flaky source.
  private var firstAdmittedVideoPTS: CMTime?
  private var gapLog = LossLogLimiter()
  private static let log = Logger(subsystem: "org.ultracam.app", category: "recording")
  private var spaceTimer: DispatchSourceTimer?
  /// Space-check timer state (utility queue only).
  private var lastSpaceCheck: (time: TimeInterval, acceptedBytes: UInt64)?
  /// What a paused or failed take last reported it still owes. Timer queue.
  private var reportedOwedBytes: UInt64?

  init(configuration: SourceRecordingConfiguration, writerFactory: @escaping WriterFactory) throws {
    self.configuration = configuration
    self.boundSourceAdmission = configuration.sourceAdmission
    self.videoRetention = MediaRetentionLedger(policy: configuration.videoRetentionPolicy)
    self.audioRetention = MediaRetentionLedger(policy: configuration.audioRetentionPolicy)
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

  deinit { spaceTimer?.cancel() }

  var videoRetentionSnapshot: MediaRetentionLedger.Snapshot { videoRetention.snapshot }
  var audioRetentionSnapshot: MediaRetentionLedger.Snapshot { audioRetention.snapshot }

  var state: SourceRecordingState {
    if writer.hasFailed { observeWriterFailure() }
    return stateLock.withLock { telemetryValue.state }
  }

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
      snapshot.writerBufferedBytes = writerSnapshot.bufferedBytes
      snapshot.writerMaxBufferedBytes = writerSnapshot.maxBufferedBytes
      snapshot.writerBufferCapacityBytes = writerSnapshot.bufferCapacityBytes
      snapshot.cadenceRepeatedFrames = writerSnapshot.cadenceRepeatedFrames
      snapshot.cadenceSkippedFrames = writerSnapshot.cadenceSkippedFrames
      snapshot.gpuConvertedFrames = writerSnapshot.gpuConvertedFrames
      snapshot.passThroughFrames = writerSnapshot.passThroughFrames
      snapshot.systemCompatibilityFrames = writerSnapshot.systemCompatibilityFrames
      snapshot.gpuConversionFailures = writerSnapshot.gpuConversionFailures
      snapshot.droppedGPUFrames = writerSnapshot.droppedGPUFrames
      snapshot.mappedAudioFrames = writerSnapshot.mappedAudioFrames
      snapshot.audioClockDiscontinuities = writerSnapshot.audioClockDiscontinuities
      snapshot.audioCorrectionRatio = writerSnapshot.audioCorrectionRatio
      snapshot.cpuConvertedFrames = writerSnapshot.cpuConvertedFrames
      snapshot.gpuConversionMS = writerSnapshot.gpuConversionMS
      snapshot.encoderInputFormat = writerSnapshot.encoderInputFormat
      snapshot.queueSamples = pendingVideo
      snapshot.queueCapacity = configuration.queueCapacity
      snapshot.queuedAudio = pendingAudio
      if snapshot.warning == nil { snapshot.warning = writerSnapshot.warning }
      if let note = snapshot.audioSyncNote {
        snapshot.warning = snapshot.warning.map { "\($0) \(note)" } ?? note
      }
      if snapshot.lastError == nil { snapshot.lastError = writerSnapshot.lastError }
      return snapshot
    }
  }

  /// Prepares the encoder (about 100 ms cold) and opens admission. Call it
  /// off the main thread; capture callbacks should connect only afterwards.
  /// A drive that is already too full for the first seconds of the take is
  /// refused here, before anything is written.
  func start() throws {
    if let check = configuration.checkAvailableSpace {
      do {
        try check(UInt64(2 * configuration.nominalBytesPerSecond * configuration.spaceCheckInterval))
      } catch {
        let failure = Self.spaceFailure(error, starting: true)
        stateLock.withLock {
          telemetryValue.state = .failed
          telemetryValue.writerErrors &+= 1
          telemetryValue.lastError = failure.localizedDescription
        }
        throw failure
      }
    }
    try queue.sync {
      let current = stateLock.withLock { telemetryValue.state }
      guard current == .idle else {
        throw SourceRecordingError.invalidState(current, operation: "start")
      }
      do {
        if let sourceAdmission = configuration.sourceAdmission { try writer.bindSourceAdmission(sourceAdmission) }
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
    startSpaceChecks()
  }

  var sourceAdmission: SourceAdmissionSnapshot? { stateLock.withLock { boundSourceAdmission } }

  /// Ordered declaration callback: bind once before any media. A new epoch or
  /// clock binding ends this take even if its format signature is unchanged.
  func bindSourceAdmission(_ snapshot: SourceAdmissionSnapshot) throws {
    do {
      try stateLock.withLock {
        if let bound = boundSourceAdmission {
          guard bound.epochID == snapshot.epochID, bound.formatSignature == snapshot.formatSignature,
            bound.clockBindings == snapshot.clockBindings else {
            throw SourceRecordingError.unsupportedSample("Recording source contract changed during the take; start a new take.")
          }
          return
        }
        guard telemetryValue.enqueuedVideo == 0, telemetryValue.enqueuedAudio == 0 else {
          throw SourceRecordingError.unsupportedSample("Recording source declaration arrived after media; start a new take.")
        }
        guard configuration.expectedSourceFormat.map({ $0.signature == snapshot.formatSignature }) ?? true else {
          throw SourceRecordingError.unsupportedSample("Recording source format changed before its audio declaration resolved; start a new take.")
        }
        guard snapshot.format.width == configuration.width, snapshot.format.height == configuration.height,
          snapshot.format.pixel.rawValue == configuration.sourcePixelFormat else {
          throw SourceRecordingError.unsupportedSample("Recording source declaration differs from configured dimensions or pixel format.")
        }
        boundSourceAdmission = snapshot
      }
      try writer.bindSourceAdmission(snapshot)
    } catch {
      let failure = Self.recordingError(error)
      stateLock.withLock { failLocked(failure.localizedDescription) }
      throw failure
    }
  }

  func bindTakeContext(_ context: RecordingTakeContext) throws {
    do { try context.validateCurrentAudio() }
    catch {
      stateLock.withLock { failLocked(error.localizedDescription) }
      throw error
    }
    try bindSourceAdmission(context.sourceAdmission)
    try enqueueMetadata(prepare: {
      if let previous = self.boundTakeContext, !previous.sameContract(as: context) {
        let message = "Recording audio declaration changed during the take; start a new take."
        self.failLocked(message)
        throw SourceRecordingError.unsupportedSample(message)
      }
      if let previous = self.boundTakeContext, previous.mappingRevision == context.mappingRevision,
        previous.videoMapping == context.videoMapping, previous.audioMapping == context.audioMapping { return false }
      self.boundTakeContext = context
      return true
    }) { writer in try writer.bindTakeContext(context) }
  }

  func noteClockMapping(_ event: RecordingClockMappingEvent) throws {
    try stateLock.withLock {
      guard let bound = boundSourceAdmission, bound.epochID == event.epochID,
        bound.clockBindings.video == event.clockID || bound.clockBindings.audio == event.clockID else {
        let message = "Recording received a stale clock mapping."
        failLocked(message)
        throw SourceRecordingError.unsupportedSample(message)
      }
    }
    try enqueueMetadata { writer in try writer.noteClockMapping(event) }
  }

  /// Capture-side work is bounded validation and one ordered enqueue only.
  /// Disk/JSON/fsync run here on the recorder queue before later media work.
  private func enqueueMetadata(prepare: () throws -> Bool = { true },
    _ operation: @escaping @Sendable (SourceRecordingWriter) throws -> Void) throws {
    try stateLock.withLock {
      guard telemetryValue.state == .recording || telemetryValue.state == .paused else {
        throw SourceRecordingError.invalidState(telemetryValue.state, operation: "record take metadata")
      }
      guard try prepare() else { return }
      guard pendingMetadataEvents < Self.maximumMetadataEvents else {
        let message = "Recording metadata queue is full; the take stopped to preserve clock history."
        failLocked(message)
        throw SourceRecordingError.writerFailure(message)
      }
      pendingMetadataEvents += 1
      // Publish the context and enqueue its work under the same admission
      // lock: another callback cannot see ready context and queue media first.
      queue.async { [weak self] in
        guard let self else { return }
        defer { self.stateLock.withLock { self.pendingMetadataEvents -= 1 } }
        do { try operation(self.writer) }
        catch {
          self.stateLock.withLock {
            self.failLocked("Recording metadata could not be preserved: " + error.localizedDescription)
            self.drainAdmittedAfterFailure = false
          }
        }
      }
    }
  }

  /// Adapter rejection of actual envelope metadata is a take failure, never
  /// an ordinary invalid-sample drop that silently leaves recording running.
  func failTakeMetadata(_ message: String) {
    stateLock.withLock { failLocked(message) }
  }

  func failSourceAdmission(_ message: String) {
    stateLock.withLock { failSourceAdmissionLocked(message) }
  }

  private func failSourceAdmissionLocked(_ message: String) {
    guard telemetryValue.state == .recording || telemetryValue.state == .paused else { return }
    telemetryValue.droppedInvalidSample &+= 1
    telemetryValue.droppedVideo &+= 1
    failLocked(message)
  }

  @discardableResult
  func appendVideo(_ sample: CMSampleBuffer) -> Bool {
    enqueue(sample, kind: .video)
  }

  @discardableResult
  func appendSourceAudio(_ sample: CMSampleBuffer, mapping: AudioVideoClockMapping) -> Bool {
    enqueue(sample, kind: .audio, audioMapping: mapping)
  }

  @discardableResult
  func appendPairedSourceAudio(_ sample: CMSampleBuffer, videoTime: CMTime) -> Bool {
    guard videoTime.isNumeric, videoTime.epoch == 0, videoTime.value >= 0 else {
      failTakeMetadata("Paired audio requires its actual non-negative video timestamp.")
      return false
    }
    return enqueue(sample, kind: .audio, pairedVideoTime: videoTime)
  }

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
      // Queued while still paused, so it reaches the writer after every
      // sample admitted before the pause and before any admitted from now on.
      queue.async { [weak self] in self?.writer.resumeAfterPause() }
      lastAdmittedVideo = nil
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
      if telemetryValue.state != .failed { telemetryValue.state = .stopping }
      return true
    }
    guard shouldStop else {
      stopCompletion.wait()
      try stateLock.withLock { try stopResult?.get() }
      return
    }
    stopSpaceChecks()
    admission.wait()
    let result: Result<Void, SourceRecordingError> = queue.sync {
      do {
        let final = stateLock.withLock { (telemetryValue.lastError, [
          "recording.sourceVideoLost": telemetryValue.droppedVideo,
          "recording.sourceAudioLost": telemetryValue.droppedAudio,
          "recording.sourceSkippedFrames": telemetryValue.deviceSkippedFrames,
          "recording.videoClockDiscontinuities": telemetryValue.videoClockDiscontinuities,
          "recording.queueOverflows": telemetryValue.droppedQueueFull,
          "recording.sourceErrors": telemetryValue.writerErrors,
          "audio.trimmedFrames": telemetryValue.audioResyncTrimmedFrames,
          "audio.silenceFilledFrames": telemetryValue.audioSilenceFilledFrames]) }
        try writer.finish(finalError: final.0, sourceCounters: final.1)
        let writerFailed = writer.hasFailed
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
          if telemetryValue.lastError == nil || !failedBeforeStop {
            telemetryValue.lastError = failure.localizedDescription
          }
        }
        return .failure(failure)
      }
    }
    stateLock.withLock { stopResult = result }
    logTakeSummary()
    stopCompletion.leave()
    try result.get()
  }

  /// One line per take, healthy or not, so a take's losses can be found in
  /// the log by its feed and file name long after its stats are gone.
  private func logTakeSummary() {
    let t = stateLock.withLock { telemetryValue }
    let unlogged = stateLock.withLock { gapLog.flush() }
    let feed = configuration.feedID.rawValue
    let file = configuration.outputURL.lastPathComponent
    let latency = t.maxEncoderLatencyMS.map { String(format: "%.1f", $0) } ?? "—"
    Self.log.notice("\(feed, privacy: .public): take \(t.state == .failed ? "failed" : "finished", privacy: .public), \(file, privacy: .public): frames=\(t.appendedVideo) missingFrames=\(t.deviceSkippedFrames) gaps=\(t.sourceGaps) largestGap=\(t.largestSourceGap) droppedVideo=\(t.droppedVideo) droppedAudio=\(t.droppedAudio) silenceFilledAudio=\(t.audioSilenceFilledFrames) trimmedAudio=\(t.audioResyncTrimmedFrames) clockDiscontinuities=\(t.videoClockDiscontinuities) maxEncoderMS=\(latency, privacy: .public)\(unlogged.map { " (\($0.events) gaps not logged one by one)" } ?? "", privacy: .public)")
  }

  /// Runs on the capture (driver) thread. Metadata checks, one short lock and
  /// an async submit: it never waits on the encoder, the GPU or the disk.
  private func enqueue(_ sample: CMSampleBuffer, kind: SampleKind, audioMapping: AudioVideoClockMapping? = nil, pairedVideoTime: CMTime? = nil) -> Bool {
    guard Self.isReady(sample, kind: kind) else {
      recordDrop(.invalidSample, video: kind == .video)
      return false
    }
    // Observe asynchronous writer failures before admitting media.
    if writer.hasFailed { observeWriterFailure() }
    var retained: MediaRetentionLedger.Lease?
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let duration = CMSampleBufferGetDuration(sample)
    let admitted = stateLock.withLock { () -> Bool in
      guard telemetryValue.state == .recording else {
        switch telemetryValue.state {
        case .paused: telemetryValue.droppedPaused &+= 1
        case .failed:
          // Media the take can no longer record is lost media: count it.
          telemetryValue.droppedNotRecording &+= 1
          if kind == .video { telemetryValue.droppedVideo &+= 1 } else { telemetryValue.droppedAudio &+= 1 }
        case .idle, .finished, .stopping: telemetryValue.droppedNotRecording &+= 1
        case .recording: break
        }
        return false
      }
      if configuration.sidecarMovieURL != nil, boundTakeContext == nil {
        failSourceAdmissionLocked("Recording requires a resolved take context before media.")
        return false
      }
      if kind == .video, let bound = boundSourceAdmission,
        let image = CMSampleBufferGetImageBuffer(sample) {
        do {
          try bound.validate(SourceAdmissionMetadata(pixelBuffer: image, presentationTime: pts, duration: duration,
            epochID: bound.epochID, formatSignature: bound.formatSignature), stage: .recordingSource)
        } catch {
          failSourceAdmissionLocked(String(describing: error))
          return false
        }
      }
      let waiting = kind == .video ? pendingVideo : pendingAudio
      let capacity = kind == .video ? configuration.queueCapacity : configuration.audioQueueCapacity
      guard waiting < capacity else {
        // Never a silent drop: the encoder stage cannot keep up, so the take
        // fails here and everything already written is kept for recovery.
        telemetryValue.droppedQueueFull &+= 1
        if kind == .video { telemetryValue.droppedVideo &+= 1 } else { telemetryValue.droppedAudio &+= 1 }
        failLocked(kind == .video
          ? "Recording fell behind: \(capacity) video frames were already waiting for the encoder. The take stopped here and was kept for recovery."
          : "Recording fell behind: \(capacity) audio packets were already waiting for the encoder. The take stopped here and was kept for recovery.")
        return false
      }
      do {
        let bytes: Int
        let seconds: Double
        if kind == .video, let image = CMSampleBufferGetImageBuffer(sample) {
          let planes: [MediaStorageExtent.Plane]
          if CVPixelBufferIsPlanar(image) {
            planes = (0..<CVPixelBufferGetPlaneCount(image)).map { .init(rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, $0), rows: CVPixelBufferGetHeightOfPlane(image, $0)) }
          } else { planes = [.init(rowBytes: CVPixelBufferGetBytesPerRow(image), rows: CVPixelBufferGetHeight(image))] }
          bytes = try MediaStorageExtent.allocationBytes(planes: planes, pixelBufferDataSize: CVPixelBufferGetDataSize(image),
            ioSurfaceAllocationSize: CVPixelBufferGetIOSurface(image).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) })
          seconds = duration.seconds
        } else {
          bytes = CMSampleBufferGetTotalSampleSize(sample)
          guard let format = CMSampleBufferGetFormatDescription(sample),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            asbd.mSampleRate.isFinite, asbd.mSampleRate > 0 else { throw MediaRetentionFailure.invalidMedia }
          seconds = Double(CMSampleBufferGetNumSamples(sample)) / asbd.mSampleRate
        }
        retained = try (kind == .video ? videoRetention : audioRetention).admit(bytes: bytes, duration: seconds)
      } catch {
        telemetryValue.droppedQueueFull &+= 1
        if kind == .video { telemetryValue.droppedVideo &+= 1 } else { telemetryValue.droppedAudio &+= 1 }
        failLocked("Recording retained media exceeded its byte or duration budget: " + String(describing: error))
        return false
      }
      if kind == .video, !noteCaptureTime(pts, duration: duration) { return false }
      switch kind {
      case .video:
        pendingVideo += 1
        telemetryValue.enqueuedVideo &+= 1
      case .audio:
        pendingAudio += 1
        telemetryValue.enqueuedAudio &+= 1
      }
      admission.enter()
      return true
    }
    guard admitted, let retained else { return false }
    let queuedSample = QueuedSample(value: sample, retention: retained)
    defer { admission.leave() }
    queue.async { [weak self] in
      guard let self else { return }
      defer {
        queuedSample.retention.release()
        self.stateLock.withLock {
          if kind == .video { self.pendingVideo -= 1 } else { self.pendingAudio -= 1 }
        }
      }
      let writerFailed = self.writer.hasFailed
      if writerFailed { self.observeWriterFailure() }
      let shouldAppend = self.stateLock.withLock { () -> Bool in
        switch self.telemetryValue.state {
        case .recording, .paused, .stopping: return true
        case .failed: return self.drainAdmittedAfterFailure && !writerFailed
        case .idle, .finished: return false
        }
      }
      guard shouldAppend else {
        // Admitted, then discarded because the file writer failed: lost media.
        self.stateLock.withLock {
          self.telemetryValue.droppedNotRecording &+= 1
          if kind == .video { self.telemetryValue.droppedVideo &+= 1 } else { self.telemetryValue.droppedAudio &+= 1 }
        }
        return
      }
      do {
        switch kind {
        case .video:
          let outcome = try self.writer.appendVideoOutcome(queuedSample.value)
          self.stateLock.withLock {
            switch outcome {
            case .appended: self.telemetryValue.appendedVideo &+= 1
            case .dropped: self.telemetryValue.droppedVideo &+= 1
            }
          }
        case .audio:
          if let pairedVideoTime { try self.writer.appendPairedSourceAudio(queuedSample.value, videoTime: pairedVideoTime) }
          else if let audioMapping { try self.writer.appendSourceAudio(queuedSample.value, mapping: audioMapping) }
          else { try self.writer.appendAudio(queuedSample.value) }
          self.stateLock.withLock { self.telemetryValue.appendedAudio &+= 1 }
        }
      } catch {
        let failure = Self.recordingError(error)
        self.stateLock.withLock {
          if kind == .video { self.telemetryValue.droppedVideo &+= 1 } else { self.telemetryValue.droppedAudio &+= 1 }
          if case .writerNotReady = failure {
            // Only a late (out-of-order) audio packet reports this now. It
            // never replaces the reason a take already failed for: after an
            // input restart the restarted audio arrives late too.
            self.telemetryValue.droppedWriterNotReady &+= 1
            if self.telemetryValue.state != .failed {
              self.telemetryValue.lastError = failure.localizedDescription
            }
          } else {
            self.telemetryValue.droppedAppendFailure &+= 1
            self.telemetryValue.writerErrors &+= 1
            self.telemetryValue.lastError = failure.localizedDescription
            self.telemetryValue.state = .failed
            self.drainAdmittedAfterFailure = false
          }
        }
      }
    }
    return true
  }

  /// Under `stateLock`, for an admitted video frame. A step of two or more
  /// frame durations between capture timestamps means the device skipped
  /// frames (the backend counts its device drops the same way); a rejected
  /// no-signal frame in between explains the gap instead. Skipped frames are
  /// counted as dropped video. When the recorder was itself holding half its
  /// raw-frame budget, it starved the capture pool: the take fails.
  private func noteCaptureTime(_ pts: CMTime, duration: CMTime) -> Bool {
    if let latest = latestAdmittedVideoPTS, CMTimeCompare(pts, latest) < 0 {
      // The capture clock started over: the input was reconfigured for a new
      // HDMI format (or its driver restarted). The take's cadence, timecode
      // and timeline no longer apply, so it ends here, visibly; everything
      // admitted before is still written and the file is kept for recovery.
      telemetryValue.droppedVideo &+= 1
      telemetryValue.videoClockDiscontinuities &+= 1
      failLocked("The HDMI input changed format or restarted during the take, so its capture clock started over. The take stopped here and was kept for recovery; start a new take to keep recording.")
      return false
    }
    defer {
      if firstAdmittedVideoPTS == nil { firstAdmittedVideoPTS = pts }
      lastAdmittedVideo = (pts, duration)
      latestAdmittedVideoPTS = pts
      invalidVideoSinceLastFrame = false
    }
    guard let last = lastAdmittedVideo, !invalidVideoSinceLastFrame,
      last.duration.seconds > 0 else { return true }
    // Compare elapsed rational time before considering cadence. A fixed
    // frame-count threshold changes meaning between 25 and 120 fps.
    let elapsedNumerator = Int128(pts.value) * Int128(last.pts.timescale)
      - Int128(last.pts.value) * Int128(pts.timescale)
    let elapsedDenominator = Int128(pts.timescale) * Int128(last.pts.timescale)
    guard elapsedNumerator < Int128(Self.maximumTimestampGapSeconds) * elapsedDenominator else {
      telemetryValue.videoClockDiscontinuities &+= 1
      telemetryValue.droppedVideo &+= 1
      failLocked("Recording source timestamp discontinuity: the capture clock advanced by at least 10 seconds without media. The take stopped and was kept for recovery.")
      return false
    }
    let declaration = boundSourceAdmission?.format.rate ?? configuration.sourceFrameRate ?? .constant(last.duration)
    guard case .constant(let cadence) = declaration else { return true }
    let numerator = elapsedNumerator * Int128(cadence.timescale)
    let denominator = elapsedDenominator * Int128(cadence.value)
    guard denominator > 0, numerator >= 0 else { return true }
    let steps = (numerator + denominator / 2) / denominator
    guard steps >= 2, let count = UInt64(exactly: steps) else { return true }
    let skipped = count - 1
    telemetryValue.deviceSkippedFrames &+= skipped
    telemetryValue.droppedVideo &+= skipped
    telemetryValue.sourceGaps &+= 1
    telemetryValue.largestSourceGap = max(telemetryValue.largestSourceGap, skipped)
    logGap(skipped, at: pts)
    let total = telemetryValue.deviceSkippedFrames
    let gaps = telemetryValue.sourceGaps
    guard pendingVideo < max(1, configuration.queueCapacity / 2) else {
      telemetryValue.droppedVideo &+= 1  // This frame is not recorded either.
      failLocked("The capture device skipped \(skipped) frames while \(pendingVideo) frames waited for the encoder: recording could not keep up. The take stopped here and was kept for recovery.")
      return false
    }
    // The source's own clock shows the gap; the capture log says whether
    // the signal dropped out or the device skipped.
    telemetryValue.warning = "The input was missing \(total) frame\(total == 1 ? "" : "s") in \(gaps) gap\(gaps == 1 ? "" : "s") during this take (signal dropouts or device skips); each gap holds the frame before it."
    return true
  }

  /// Under `stateLock`: one line per gap at its place in the take, bounded
  /// by `gapLog` so a flaky source cannot flood the log.
  private func logGap(_ frames: UInt64, at pts: CMTime) {
    let at = String(format: "%.3f", firstAdmittedVideoPTS.map { CMTimeSubtract(pts, $0).seconds } ?? 0)
    let feed = configuration.feedID.rawValue
    let decision = gapLog.note(frames: frames, at: ProcessInfo.processInfo.systemUptime)
    switch decision {
    case .log, .logLast:
      Self.log.notice("\(feed, privacy: .public): \(frames) frames missing from the input before \(at, privacy: .public) s of the take (gap \(self.gapLog.events), \(self.gapLog.frames) frames so far)")
      if decision == .logLast {
        Self.log.notice("\(feed, privacy: .public): further input gaps in this take are summarized at most once a minute")
      }
    case .summary(let events, let frames):
      Self.log.notice("\(feed, privacy: .public): \(events) more input gaps, \(frames) frames, by \(at, privacy: .public) s of the take (\(self.gapLog.events) gaps, \(self.gapLog.frames) frames so far)")
    case .quiet:
      break
    }
  }

  /// A failure the recorder raises itself, under `stateLock`. The file writer
  /// is fine, so samples already admitted are still written.
  private func failLocked(_ message: String) {
    guard telemetryValue.state != .failed else { return }
    telemetryValue.state = .failed
    telemetryValue.writerErrors &+= 1
    telemetryValue.lastError = message
    drainAdmittedAfterFailure = true
  }

  /// Moves the recorder to `.failed` once the writer reports a fatal error.
  private func observeWriterFailure() {
    let message = writer.telemetry.lastError
    stateLock.withLock {
      switch telemetryValue.state {
      case .recording, .paused, .stopping:
        telemetryValue.state = .failed
        if telemetryValue.lastError == nil { telemetryValue.lastError = message }
      case .idle, .finished, .failed:
        break
      }
      drainAdmittedAfterFailure = false
    }
  }

  // MARK: Free space

  /// Free space is rechecked about once a second on a utility queue, never
  /// per sample and never on the capture or encoder path. A paused take skips
  /// the check; it resumes with the next tick after `resume()`. A failed take
  /// reports a headroom of 0 once and stops checking.
  private func startSpaceChecks() {
    guard let check = configuration.checkAvailableSpace else { return }
    let interval = configuration.spaceCheckInterval
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + interval, repeating: interval,
      leeway: .milliseconds(Int(min(250, max(1, interval * 100)))))
    timer.setEventHandler { [weak self] in self?.runSpaceCheck(check) }
    stateLock.withLock { spaceTimer = timer }
    timer.resume()
  }

  private func stopSpaceChecks() {
    let timer = stateLock.withLock { () -> DispatchSourceTimer? in
      defer { spaceTimer = nil }
      return spaceTimer
    }
    timer?.cancel()
  }

  /// What must still fit on the drive beyond its floor before the next check:
  /// encoded media waiting in memory, the frames still being encoded, and two
  /// intervals of writing at the take's measured rate (never below the
  /// codec's nominal rate). With that margin the check fails while there is
  /// still room for everything already accepted, so nothing is lost to a
  /// full disk. Timer queue only.
  func spaceHeadroom(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UInt64 {
    let writerSnapshot = writer.telemetry
    let rawFrames = stateLock.withLock { pendingVideo } + writerSnapshot.encoderPendingFrames
    var rate = configuration.nominalBytesPerSecond
    if let last = lastSpaceCheck, now > last.time, writerSnapshot.acceptedBytes >= last.acceptedBytes {
      rate = max(rate, Double(writerSnapshot.acceptedBytes - last.acceptedBytes) / (now - last.time))
    }
    lastSpaceCheck = (now, writerSnapshot.acceptedBytes)
    let frameBytes = rate * (configuration.sourceFrameRate?.nominal ?? configuration.frameRate.frameDuration).seconds
    let headroom = Double(writerSnapshot.bufferedBytes) + Double(rawFrames) * frameBytes
      + 2 * rate * configuration.spaceCheckInterval
    return UInt64(min(headroom, Double(UInt64.max / 2)))
  }

  /// Media the take accepted that isn't on disk yet: encoded bytes in memory
  /// and frames still being encoded. Nothing, once the file writer failed.
  /// Timer queue only.
  func owedBytes() -> UInt64 {
    guard !writer.hasFailed else { return 0 }
    let writerSnapshot = writer.telemetry
    let rawFrames = stateLock.withLock { pendingVideo } + writerSnapshot.encoderPendingFrames
    let frameBytes = configuration.nominalBytesPerSecond * (configuration.sourceFrameRate?.nominal ?? configuration.frameRate.frameDuration).seconds
    let owed = Double(writerSnapshot.bufferedBytes) + Double(rawFrames) * frameBytes
    return UInt64(min(owed, Double(UInt64.max / 2)))
  }

  private func runSpaceCheck(_ check: (UInt64) throws -> Void) {
    if writer.hasFailed { observeWriterFailure() }
    let state = stateLock.withLock { () -> SourceRecordingState in
      if telemetryValue.state == .recording { telemetryValue.spaceChecks &+= 1 }
      return telemetryValue.state
    }
    if state == .failed || state == .paused {
      // Nothing new is accepted, but what already was is still being written:
      // the take holds only that, so other feeds on the volume get the rest.
      // A failed take stops checking once it is all on disk; its file and
      // reservation stay until Stop.
      let owed = owedBytes()
      if owed != reportedOwedBytes { try? check(owed) }
      reportedOwedBytes = owed
      if state == .failed, owed == 0 { stopSpaceChecks() }
      return
    }
    reportedOwedBytes = nil
    guard state == .recording else { return }
    do {
      try check(spaceHeadroom())
    } catch {
      let failure = Self.spaceFailure(error)
      stateLock.withLock {
        // A take that paused or stopped meanwhile is not failed by a stale check.
        guard telemetryValue.state == .recording else { return }
        failLocked(failure.localizedDescription)
      }
    }
  }

  private static func spaceFailure(_ error: Error, starting: Bool = false) -> SourceRecordingError {
    let outcome = starting
      ? "Free up space or choose another recording folder."
      : "The take stopped here and everything recorded so far was kept for recovery."
    if case let .insufficientDiskSpace(required, available)? = error as? RecordingOutputError {
      let format = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
      return .writerFailure("The recording drive is almost full: \(format(available)) of free space left, "
        + "\(format(required)) needed to keep recording safely. " + outcome)
    }
    return .writerFailure("The recording drive's free space could not be checked: \(error.localizedDescription) " + outcome)
  }

  /// Records a rejection made before a CMSampleBuffer exists, such as an invalid
  /// source signal-valid flag or packet metadata.
  /// The callback adapter re-placed this take's audio on the video clock: a
  /// re-anchor (`backward` when it reached into audio already recorded),
  /// frames left out because recorded audio already covered them, or a hole
  /// filled with silence. Counted on the take; left-out audio leaves a note.
  func noteAudioResync(reanchored: Bool, backward: Bool, trimmedFrames: Int, silenceFrames: Int) {
    stateLock.withLock {
      if reanchored { telemetryValue.audioReanchors &+= 1 }
      if backward { telemetryValue.audioBackwardResyncs &+= 1 }
      telemetryValue.audioResyncTrimmedFrames &+= UInt64(max(0, trimmedFrames))
      telemetryValue.audioSilenceFilledFrames &+= UInt64(max(0, silenceFrames))
      let trimmed = telemetryValue.audioResyncTrimmedFrames
      guard trimmed > 0 else { return }
      let times = telemetryValue.audioBackwardResyncs
      let ms = String(format: "%.0f", Double(trimmed) / 48)
      telemetryValue.audioSyncNote = times > 1
        ? "Audio was re-synced to the picture \(times) times; \(ms) ms of overlapping audio was left out."
        : "Audio was re-synced to the picture; \(ms) ms of overlapping audio was left out."
    }
  }

  func recordDrop(_ reason: SourceRecordingDropReason, video: Bool = true) {
    stateLock.withLock {
      // Paused/stopped callbacks are intentionally ignored, not lost frames.
      if reason != .paused && reason != .notRecording {
        if video { telemetryValue.droppedVideo &+= 1 } else { telemetryValue.droppedAudio &+= 1 }
      }
      if video, reason == .invalidSample { invalidVideoSinceLastFrame = true }
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
