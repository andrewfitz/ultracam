import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import Metal

/// AVAssetWriter/VideoToolbox implementation for one source feed.
///
/// Three stages, each on its own thread of control, so no stage ever waits
/// for a slower one while holding something another stage needs:
/// 1. Encoder stage (`appendVideo`, called on the recorder's serial queue):
///    repacks the capture v210 IOSurface into the encoder's native x422 on
///    the GPU (no CPU pixel access) and submits it to VideoToolbox.
/// 2. VideoToolbox output callback: only queues the compressed sample.
/// 3. Writer queue: creates the file, starts the session and appends video,
///    audio and timecode, waiting for input readiness on this queue only.
///
/// Nothing is dropped for being busy. Compressed media waits in memory up to
/// `maximumBufferedBytes` (about 4.8 s of ProRes 422 HQ 2160p59.94 at the
/// default); going past that fails the take visibly and keeps what was
/// written for recovery.
///
/// Pause: the movie continues without a gap. The time spent paused is taken
/// out of every later timestamp (video, audio and the movie's timeline), so
/// a paused take plays straight through; a wall-clock timecode track still
/// labels every frame with the time it was captured, so it jumps at the cut.
final class AVAssetSourceRecordingWriter: SourceRecordingWriter, @unchecked Sendable {
  struct ConversionOperations {
    var supportedPixelFormats: ((VTCompressionSession) -> [OSType])? = nil
    var allocateBuffer: ((CVPixelBufferPool) throws -> CVPixelBuffer)? = nil
    var convert: ((RecordingPixelConverter, CVPixelBuffer, CVPixelBuffer) throws -> Double)? = nil
    var requireMetal: (() throws -> RecordingPixelConverter)? = nil
  }
  private let maximumSidecarJournalBytes: Int
  private let conversionOperations: ConversionOperations
  private var takeContext: RecordingTakeContext?
  private var lastMappingRevision: UInt64?
  private var finalSourceCounters: [String: UInt64] = [:]
  private var lastNativeFieldMark: Bool?
  private var hadNativeFieldMark = false
  private var lastOriginalSourceEpoch: CaptureEpochID?
  private var lastOriginalAudioEpoch: CaptureEpochID?
  private var takeSidecar: RecordingTakeSidecar?
  private var lastSidecarCounterUpdate: TimeInterval = 0
  private var recordingTimebase: RecordingTimebase?
  private var variableFrameTimeline: VariableFrameTimeline?
  private struct CadenceFrame {
    let image: CVPixelBuffer
    let nativeTimecode: Data?
  }
  // One prepared GPU image is retained between source callbacks; repeats
  // share that image and encoder submissions remain separately bounded.
  private var cadenceConformer: RecordingCadenceConformer<CadenceFrame>?
  private var cadenceResumePending = false
  private var cadenceOutputEnd: CMTime = .zero

  private var timebaseOrigin: CMTime?
  private var mappedPCMBridge: ClockMappedPCMBridge?
  private var mappedPCMResumePending = false
  private var mappedAudioFrames: UInt64 = 0
  private var mappedAudioDiscontinuities: UInt64 = 0
  private var heldMappedAudio: [CMSampleBuffer] = []
  private var firstSourceVideoPTS: CMTime?
  private var sourceNativeTrackExpected: Bool?
  private var nativeTimecodeMetadata: TimecodeMetadata?
  private var nativeTimecodeOrigin: CMTime?
  private var submittedNativeTimecodes: [Rational: Data] = [:]
  private var selectedTrackTimescale: Int32?
  typealias EncodeFrame = (VTCompressionSession, CVImageBuffer, CMTime, CMTime) -> OSStatus

  /// 1 GiB of compressed media: ProRes 422 HQ 2160p59.94 writes about
  /// 221 MB/s, so this rides out a 4–5 s disk stall.
  static let defaultMaximumBufferedBytes = 1 << 30
  /// Encoder-pool buffers (x422, 33 MB each at 2160p) VideoToolbox may hold.
  static let encoderPoolThreshold = 16
  /// When a frame hands VideoToolbox the capture buffer itself (pass-through,
  /// VideoToolbox conversion, or a GPU repack that could not run), the
  /// frames VideoToolbox may hold before that frame waits. Together with the recorder's queue this
  /// bounds the driver frames recording can keep from the capture pool.
  static let maximumCaptureFramesInEncoder = 6
  /// An encoder that returns no frame for this long has stalled.
  private static let encoderStallTimeout: TimeInterval = 2
  /// The writer queue retries a busy input after 2 ms, backing off to 32 ms.
  private static let minimumRetryMS = 2
  private static let maximumRetryMS = 32
  /// At stop, the writer must make progress at least this often.
  private static let finishStallTimeout: TimeInterval = 10
  nonisolated(unsafe) private static let poolAuxiliaryAttributes =
    [kCVPixelBufferPoolAllocationThresholdKey: encoderPoolThreshold] as CFDictionary
  /// Image-description attachments a capture buffer may carry in the
  /// should-not-propagate set. The pass-through route hands VideoToolbox the
  /// capture buffer, so it sees these; the GPU route copies them over. Other
  /// non-propagated attachments (such as an object that owns the driver
  /// frame) must not follow the frame into the encoder.
  private static let imageDescriptionKeys: Set<String> = [
    kCVImageBufferFieldCountKey as String, kCVImageBufferFieldDetailKey as String,
    kCVImageBufferPixelAspectRatioKey as String, kCVImageBufferCleanApertureKey as String,
    kCVImageBufferPreferredCleanApertureKey as String, kCVImageBufferDisplayDimensionsKey as String,
  ]

  private enum EncoderInput {
    /// The encoder takes v210 natively; hand it the capture buffer.
    case passThrough
    /// GPU repack into the encoder's own x422 pool.
    case gpu(RecordingPixelConverter, CVPixelBufferPool)
    case gpuRGB(RecordingRGBPixelConverter, CVPixelBufferPool, RGBFormat)
    case gpuPlanar(PlanarRecordingConverter, CVPixelBufferPool)
    case gpuPacked422(Packed422RecordingConverter, CVPixelBufferPool)
    /// No native route: compatibility mode permits opaque system conversion.
    case videoToolboxConverts(String)
  }

  /// A prepared compression session, built without any lock held.
  private struct PreparedEncoder {
    let session: VTCompressionSession
    let input: EncoderInput
    let hardware: Bool?
    let encoderID: String?
    let inputDescription: String
  }

  /// A FIFO with amortized O(1) removal from the front.
  private struct SampleQueue {
    private(set) var items: [CMSampleBuffer] = []
    private var head = 0
    private(set) var retainedDuration: Double = 0
    private(set) var retainedBytes: Int = 0
    var isEmpty: Bool { head == items.count }
    var count: Int { items.count - head }
    var first: CMSampleBuffer? { isEmpty ? nil : items[head] }
    mutating func append(_ sample: CMSampleBuffer) { items.append(sample); retainedDuration += CMSampleBufferGetDuration(sample).seconds; retainedBytes += CMSampleBufferGetTotalSampleSize(sample) }
    /// Keeps PTS order. Media normally arrives in order, so the scan from the
    /// back stops at once; only an early packet moves forward.
    mutating func insertOrdered(_ sample: CMSampleBuffer) {
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      var index = items.count
      while index > head,
        CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(items[index - 1]), pts) > 0 {
        index -= 1
      }
      items.insert(sample, at: index)
      retainedBytes += CMSampleBufferGetTotalSampleSize(sample)
      retainedDuration += CMSampleBufferGetDuration(sample).seconds
    }
    mutating func removeFirst() {
      guard !isEmpty else { return }
      retainedBytes = max(0, retainedBytes - CMSampleBufferGetTotalSampleSize(items[head]))
      retainedDuration = max(0, retainedDuration - CMSampleBufferGetDuration(items[head]).seconds)
      head += 1
      if head == items.count { items.removeAll(keepingCapacity: true); head = 0 }
      else if head >= 256, head * 2 >= items.count { items.removeFirst(head); head = 0 }
    }
    mutating func removeAll() { items.removeAll(); head = 0; retainedDuration = 0; retainedBytes = 0 }
  }

  /// Submission times of frames inside VideoToolbox, oldest first. The
  /// encoder returns frames in submission order (no reordering), so a fixed
  /// ring replaces a per-frame dictionary.
  private struct FrameStartRing {
    static let capacity = 256
    private var keys = [Rational?](repeating: nil, count: capacity)
    private var starts = [UInt64](repeating: 0, count: capacity)
    private var head = 0
    private(set) var count = 0

    mutating func push(_ key: Rational, start: UInt64) {
      if count == Self.capacity { head = (head + 1) % Self.capacity; count -= 1 }
      let index = (head + count) % Self.capacity
      keys[index] = key
      starts[index] = start
      count += 1
    }

    /// Removes the newest entry if it is `key` (a submission that failed).
    mutating func removeNewest(_ key: Rational) {
      guard count > 0, keys[(head + count - 1) % Self.capacity] == key else { return }
      count -= 1
    }

    /// Removes `key` and every older entry (frames VideoToolbox dropped), and
    /// returns its submission time.
    mutating func remove(through key: Rational) -> UInt64? {
      for offset in 0..<count {
        let index = (head + offset) % Self.capacity
        guard keys[index] == key else { continue }
        let start = starts[index]
        head = (index + 1) % Self.capacity
        count -= offset + 1
        return start
      }
      return nil
    }

    mutating func removeAll() { head = 0; count = 0 }
  }

  /// Pause bookkeeping, in capture time. Recorder-queue writes under
  /// `timelineLock`; the writer queue reads `segments`.
  private struct PauseTimeline {
    /// Capture time minus output time.
    var offset = CMTime.zero
    var resumePending = false
    var lastVideoEnd: CMTime?
    var lastVideoNormalizedEnd: CMTime?
    var lastAudioEnd: CMTime?
    /// Output end of the last audio packet accepted.
    var lastAudioOutputEnd: CMTime?
    /// Post-resume audio that arrived before the first post-resume frame.
    var heldAudio: [CMSampleBuffer] = []
    /// Output time each pause offset starts at, oldest first.
    var segments: [(start: CMTime, offset: CMTime)] = []

    func offset(atOutput time: CMTime) -> CMTime {
      segments.last { CMTimeCompare($0.start, time) <= 0 }?.offset ?? .zero
    }
  }

  private static let maximumHeldAudio = 64
  private static let maximumPendingTimecode = 64

  private let configuration: SourceRecordingConfiguration
  private let encodeFrame: EncodeFrame
  private let completeFrames: (VTCompressionSession) -> OSStatus
  private let inputReady: (AVAssetWriterInput) -> Bool
  private let appendSample: (CMSampleBuffer, AVAssetWriterInput) -> Bool
  private let maximumBufferedBytes: Int
  private let writerQueue: DispatchQueue

  // Telemetry: a short lock, never held across encode, GPU or file work.
  private let telemetryLock = RecordingLock()
  private var telemetryValue = SourceRecordingWriterTelemetry()
  private var frameStarts = FrameStartRing()
  /// When the first frame was captured (from its host capture time), for a
  /// wall-clock timecode anchor.
  private var firstFrameDate: Date?
  // VideoToolbox and the writer queue fail asynchronously. Preserve the first
  // fatal error until `finish()` so the recorder cannot publish a partial
  // movie after `appendVideo` already returned successfully.
  private var terminalError: SourceRecordingError?

  // Encoder stage. `appendVideo` and `finish` run on the recorder's serial
  // queue; the lock only covers the lifecycle flags and session handle and is
  // never held while a session is created or a frame is converted.
  private let encoderLock = RecordingLock()
  private var started = false
  private var finishing = false
  private var finished = false
  private var compressionSession: VTCompressionSession?
  private var encoderInput: EncoderInput = .passThrough
  private var lastVideoPTS: CMTime?
  private var boundSourceAdmission: SourceAdmissionSnapshot?
  private var sourceMediaAdmitted = false
  /// The shared GPU converter while this take uses it; released once at
  /// finish (or deinit) so the converter can drop the take's surfaces.
  private var converterInUse: RecordingPixelConverter?

  private let timelineLock = RecordingLock()
  private var timeline = PauseTimeline()

  /// Signalled whenever VideoToolbox returns a frame or the encoder pool
  /// frees a buffer, so the encoder stage waits for that instead of polling.
  private let encoderProgress = NSCondition()
  private var encoderProgressCount: UInt64 = 0
  private var poolObserver: NSObjectProtocol?

  // Hand-off between the stages: a short lock around the queues only.
  private let fifoLock = RecordingLock()
  private var pendingVideo = SampleQueue()
  private var pendingAudio = SampleQueue()
  private var bufferedBytes = 0
  private var maxBufferedBytesSeen = 0
  private var acceptedBytes: UInt64 = 0
  private var pumpScheduled = false
  private var acceptingMedia = true
  private var lastWrittenAudioPTS: CMTime?

  // Writer-queue confined.
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var timecodeInput: AVAssetWriterInput?
  private var timecodeTrack: QuickTimeTimecodeTrack?
  private var timecodeSession: RecordingTimecodeSession?
  private var pendingTimecode = SampleQueue()
  private var sessionStarted = false
  private var writerClosed = false
  private var writtenItems: UInt64 = 0
  private var retryDelayMS = AVAssetSourceRecordingWriter.minimumRetryMS

  init(configuration: SourceRecordingConfiguration,
    encodeFrame: @escaping EncodeFrame = { session, image, pts, duration in
      var flags = VTEncodeInfoFlags()
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image,
        presentationTimeStamp: pts, duration: duration, frameProperties: nil,
        sourceFrameRefcon: nil, infoFlagsOut: &flags)
    }, inputReady: @escaping (AVAssetWriterInput) -> Bool = AVAssetSourceRecordingWriter.inputIsReady,
    appendSample: @escaping (CMSampleBuffer, AVAssetWriterInput) -> Bool = AVAssetSourceRecordingWriter.append,
    maximumBufferedBytes: Int? = nil, conversionOperations: ConversionOperations = .init(),
    maximumSidecarJournalBytes: Int = 16 * 1024 * 1024,
    completeFrames: @escaping (VTCompressionSession) -> OSStatus = { VTCompressionSessionCompleteFrames($0, untilPresentationTimeStamp: .invalid) }) throws {
    self.maximumSidecarJournalBytes = maximumSidecarJournalBytes
    self.conversionOperations = conversionOperations
    self.configuration = configuration
    self.boundSourceAdmission = configuration.sourceAdmission
    self.encodeFrame = encodeFrame
    self.completeFrames = completeFrames
    self.inputReady = inputReady
    self.appendSample = appendSample
    self.maximumBufferedBytes = max(1, maximumBufferedBytes ?? configuration.maximumBufferedWriterBytes)
    self.writerQueue = DispatchQueue(label: "org.ultracam.recording.writer.\(configuration.feedID.rawValue)",
      qos: .userInitiated)
  }

  /// Returns the generated track description for modes that do not depend on
  /// an embedded source timecode. Source mode remains absent until the capture
  /// boundary supplies a source timecode value.
  static func makeTimecodeTrack(for configuration: SourceRecordingConfiguration,
    frameRate: RecordingFrameRate? = nil) throws -> QuickTimeTimecodeTrack? {
    guard configuration.timecodePolicy != .source || configuration.nativeTimecodeMetadata != nil else { return nil }
    return try QuickTimeTimecodeTrack(frameRate: frameRate ?? configuration.frameRate,
      dropFrame: configuration.timecodeDropFrame)
  }

  /// Wall-clock recordings that ask for computer-clock alignment take the
  /// time the first frame was captured (`firstFrame`, from the capture
  /// backend's host time), or `now` without one. Every other configuration
  /// keeps the date the caller supplied, including an explicit wall-clock anchor.
  static func timecodeAnchorDate(for configuration: SourceRecordingConfiguration, now: Date = Date(),
    firstFrame: Date? = nil) -> Date {
    guard configuration.timecodeSamplesComputerClockAtFirstFrame,
      configuration.timecodePolicy == .wallClock else {
      return configuration.timecodeStartDate
    }
    return firstFrame ?? now
  }

  /// The wall-clock moment a frame was captured: its host capture time
  /// attachment mapped onto the computer clock, or `now` without one.
  static func captureDate(of image: CVBuffer, now: Date = Date(),
    hostNow: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) -> Date {
    guard let captured = (CVBufferCopyAttachment(image,
      SourceRecordingConfiguration.captureHostTimeAttachmentKey as CFString, nil) as? NSNumber)?.doubleValue,
      captured.isFinite, captured > 0, hostNow.isFinite else { return now }
    // A capture time from the future or from long ago is not this frame's.
    let age = hostNow - captured
    guard age >= 0, age < 10 else { return now }
    return now.addingTimeInterval(-age)
  }

  /// Matches a source frame duration to the capture contract. Anything else
  /// keeps the configuration's rate instead of inventing a third cadence.
  static func matchingFrameRate(_ duration: CMTime) -> RecordingFrameRate? {
    guard duration.isNumeric, duration.timescale > 0, duration.value > 0, duration.epoch == 0 else { return nil }
    return RecordingFrameRate(numerator: Int64(duration.timescale), denominator: duration.value)
  }

  var telemetry: SourceRecordingWriterTelemetry {
    let (buffered, peak, samples, accepted) = fifoLock.withLock {
      (bufferedBytes, maxBufferedBytesSeen, pendingVideo.count + pendingAudio.count, acceptedBytes)
    }
    return telemetryLock.withLock {
      var result = telemetryValue
      result.encoderPendingFrames = frameStarts.count
      result.failed = terminalError != nil
      result.bufferedBytes = buffered
      result.maxBufferedBytes = peak
      result.bufferedSamples = samples
      result.bufferCapacityBytes = maximumBufferedBytes
      result.acceptedBytes = accepted
      return result
    }
  }

  /// Cheap failure probe for the capture thread: one short lock, no copies.
  var hasFailed: Bool { telemetryLock.withLock { terminalError != nil } }

  deinit {
    releaseConverter()
    if let poolObserver { NotificationCenter.default.removeObserver(poolObserver) }
    if let compressionSession {
      VTCompressionSessionInvalidate(compressionSession)
    }
  }

  /// Admission starts the writer lazily. A pass-through AVAssetWriter input
  /// needs a compressed format hint, which is available only after the first
  /// VideoToolbox callback; delaying file initialization preserves that hint
  /// and avoids a format-conversion path.
  ///
  /// The encoder itself is prepared here, before the capture callbacks are
  /// connected: a cold ProRes session plus the GPU converter take a few
  /// hundred milliseconds, and frames that waited for them at the start of a
  /// take would hold capture buffers. If early preparation fails, the first
  /// frame retries and reports the error. Call off the main thread.
  func start() throws {
    let needsSession = try encoderLock.withLock { () throws -> Bool in
      guard !started else { throw SourceRecordingError.invalidState(.recording, operation: "start writer") }
      started = true
      return compressionSession == nil
    }
    if needsSession {
      do { install(try makeCompressionSession(frameRate: configuration.frameRate)) }
      catch { encoderLock.withLock { started = false }; throw error }
    }
    EmbeddedAudioRecording.prepareFormat()
  }

  /// The recorder resumed a paused take: the next frame continues the movie
  /// straight after the last one written before the pause.
  func resumeAfterPause() {
    mappedPCMResumePending = mappedPCMBridge != nil
    cadenceResumePending = cadenceConformer != nil
    timelineLock.withLock {
      guard timeline.lastVideoEnd != nil || timeline.lastAudioEnd != nil else { return }
      timeline.resumePending = true
    }
  }

  // MARK: - Encoder stage

  /// Recorder-queue ordered before the first media submission. Missing mapping
  /// values remain nil; an unavailable mapping is never a zero-origin mapping.
  func bindTakeContext(_ context: RecordingTakeContext) throws {
    try context.validateCurrentAudio()
    try bindSourceAdmission(context.sourceAdmission)
    if let previous = takeContext {
      guard previous.sameContract(as: context) else {
        throw SourceRecordingError.unsupportedSample("Recording audio declaration changed during the take; start a new take.")
      }
      if lastMappingRevision != context.mappingRevision {
        try takeSidecar?.append(.init(kind: "clockMapping", detail: "Ordered mapping revision update",
          mapping: context.videoMapping, mappingRevision: context.mappingRevision))
      }
      lastMappingRevision = context.mappingRevision
      return
    }
    if let movieURL = configuration.sidecarMovieURL {
      let source = context.sourceAdmission
      let output = RecordingOutputContract(sourceFormat: source.format, outputRate: configuration.recordingConstantFrameRate && source.format.rate.isVariable ? .constant((Self.matchingFrameRate(source.format.rate.nominal) ?? configuration.frameRate).frameDuration) : source.format.rate,
        encoderInputPixelFormat: configuration.videoProfile.encoderPixelFormat, codec: configuration.videoCodec)
      var metadata = RecordingTakeSidecar.Metadata(sourceSignature: source.formatSignature, outputSignature: output.signature)
      metadata.epoch = source.epochID; metadata.clockBindings = source.clockBindings
      metadata.audioDeclaration = context.audioDeclaration; metadata.policy = configuration.compatibilityPolicy
      if case .present(let audio) = context.audioDeclaration {
        let outputRate = try recordingPCMOutputSampleRate(for: audio)
        metadata.audioOutputSampleRate = outputRate
        if Self.usesLegacyPairedPCM(audio) {
          metadata.conversionNotes.append("Paired signed Int32 PCM is stored as its exact high 24 bits.")
        }
        if outputRate != audio.sampleRate {
          metadata.conversionNotes.append("Source PCM rate \(audio.sampleRate) is resampled onto the explicit \(outputRate) Hz output grid.")
        }
      }
      if configuration.sourceFrameRate != nil || configuration.declaredTimebases != nil || configuration.quantizationPolicy != nil {
        let selected = try RecordingTimebase.Configuration(frameRate: configuration.sourceFrameRate ?? source.format.rate,
          declaredTimebases: configuration.declaredTimebases, quantizationPolicy: configuration.quantizationPolicy)
        metadata.timestampTimescale = selected.timescale
      } else {
        guard let selectedRate = Self.matchingFrameRate(source.format.rate.nominal) else {
          throw SourceRecordingError.unsupportedSample("Recording source cadence requires declared timestamp timebases or an explicit quantization policy.")
        }
        metadata.timestampTimescale = selectedRate.frameDuration.timescale
      }
      if configuration.recordingConstantFrameRate, source.format.rate.isVariable {
        metadata.timestampTimescale = (Self.matchingFrameRate(source.format.rate.nominal) ?? configuration.frameRate).frameDuration.timescale
        metadata.conversionNotes.append("Explicit constant-cadence recording repeats or skips whole source frames; source timing is retained in the journal.")
      }
      metadata.sourceFormat = source.format
      metadata.keyframeIntervalDuration = configuration.keyframeDuration(for: Self.matchingFrameRate(source.format.rate.nominal) ?? configuration.frameRate)
      if [PixelFormatID.uyva, PixelFormatID.pa16].contains(source.format.pixel) {
        metadata.conversionNotes.append("The selected 4:2:2 recording profile omits the source alpha plane.")
      }
      if source.format.pixel == .r210, source.format.colour.range == .video,
        configuration.videoProfile.encoderPixelFormat == kCVPixelFormatType_64RGBALE {
        metadata.conversionNotes.append("Video-range RGB is expanded to unsigned full-range RGBA16; out-of-range values clamp to the encoder input range.")
      }
      metadata.outputContract = output
      metadata.videoClockDomain = source.format.clock
      metadata.mappingRevision = context.mappingRevision; metadata.videoMapping = context.videoMapping
      metadata.audioMapping = context.audioMapping
      let sidecar = try RecordingTakeSidecar(movieURL: movieURL, metadata: metadata, maximumJournalBytes: maximumSidecarJournalBytes)
      do { try configuration.sidecarCreated?() }
      catch { try? sidecar.removePairMetadata(); throw error }
      takeSidecar = sidecar
    }
    takeContext = context
    lastMappingRevision = context.mappingRevision
  }

  func noteClockMapping(_ event: RecordingClockMappingEvent) throws {
    guard let sourceAdmission, event.epochID == sourceAdmission.epochID,
      event.clockID == sourceAdmission.clockBindings.video || event.clockID == sourceAdmission.clockBindings.audio else {
      throw SourceRecordingError.unsupportedSample("Recording received a stale clock mapping.")
    }
    try takeSidecar?.append(.init(kind: "clockMapping", detail: "Ordered clock mapping update",
      clockID: event.clockID, mapping: event.mapping, mappingRevision: event.revision,
      effectiveSequence: event.effectiveSequence))
  }

  private var recordingSourceFormat: SourceFormat? { sourceAdmission?.format ?? configuration.expectedSourceFormat }

  var sourceAdmission: SourceAdmissionSnapshot? { encoderLock.withLock { boundSourceAdmission } }

  func bindSourceAdmission(_ snapshot: SourceAdmissionSnapshot) throws {
    do {
      try encoderLock.withLock {
        if let bound = boundSourceAdmission {
          guard bound.epochID == snapshot.epochID, bound.formatSignature == snapshot.formatSignature,
            bound.clockBindings == snapshot.clockBindings else {
            throw SourceRecordingError.unsupportedSample("Recording source contract changed during the take; start a new take.")
          }
          return
        }
        guard !sourceMediaAdmitted, lastVideoPTS == nil else {
          throw SourceRecordingError.unsupportedSample("Recording source declaration arrived after media; start a new take.")
        }
        guard configuration.expectedSourceFormat.map({ $0.signature == snapshot.formatSignature }) ?? true else {
          throw SourceRecordingError.unsupportedSample("Recording source format changed before audio resolution; start a new take.")
        }
        guard snapshot.format.width == configuration.width, snapshot.format.height == configuration.height,
          snapshot.format.pixel.rawValue == configuration.sourcePixelFormat else {
          throw SourceRecordingError.unsupportedSample("Recording source declaration differs from configured dimensions or pixel format.")
        }
        boundSourceAdmission = snapshot
      }
    } catch {
      let failure = (error as? SourceRecordingError) ?? .unsupportedSample(error.localizedDescription)
      fail(failure)
      throw failure
    }
  }

  func appendVideo(_ sample: CMSampleBuffer) throws { _ = try appendVideoOutcome(sample) }

  func appendVideoOutcome(_ sample: CMSampleBuffer) throws -> RecordingVideoAppendOutcome {
    try appendVideoOutcome(sample, sourceAlreadyConverted: false)
  }

  private func appendVideoOutcome(_ sample: CMSampleBuffer, sourceAlreadyConverted: Bool) throws -> RecordingVideoAppendOutcome {
    if configuration.sidecarMovieURL != nil, takeContext == nil {
      throw SourceRecordingError.unsupportedSample("Recording take context is unresolved; no media was submitted.")
    }
    guard Self.hasValidTiming(sample) else {
      throw SourceRecordingError.unsupportedSample(
        "A video sample must have a non-negative epoch-zero PTS and positive duration.")
    }
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
      throw SourceRecordingError.unsupportedSample("A video sample has no image buffer.")
    }
    guard sourceAlreadyConverted || CVPixelBufferGetPixelFormatType(imageBuffer) == configuration.sourcePixelFormat else {
      throw SourceRecordingError.unsupportedSample(
        "The source recorder requires native 10-bit 4:2:2 video for \(configuration.videoProfile.displayName).")
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let duration = CMSampleBufferGetDuration(sample)

    guard pts.isNumeric else {
      throw SourceRecordingError.unsupportedSample("A video sample has no numeric presentation time.")
    }
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    guard width == configuration.width, height == configuration.height else {
      throw SourceRecordingError.unsupportedSample(
        "Video dimensions \(width) × \(height) do not match the configured source \(configuration.width) × \(configuration.height).")
    }
    if !sourceAlreadyConverted, let sourceAdmission {
      do {
        let metadata = SourceAdmissionMetadata(pixelBuffer: imageBuffer, presentationTime: pts, duration: duration,
          epochID: sourceAdmission.epochID, formatSignature: sourceAdmission.formatSignature)
        try sourceAdmission.validate(metadata, stage: .recordingSource)
      } catch {
        throw SourceRecordingError.unsupportedSample("Source metadata differs from the immutable declared rate or storage contract: " + String(describing: error))
      }
    }
    if let data = CMGetAttachment(sample, key: SourceRecordingConfiguration.sourceProvenanceAttachmentKey as CFString, attachmentModeOut: nil) as? Data {
      guard data.count <= 4096, let frozen = sourceAdmission else {
        throw SourceRecordingError.unsupportedSample("Source provenance requires a bounded declared recording source.")
      }
      let original = try JSONDecoder().decode(RecordingSourceProvenance.self, from: data)
      guard original.epochID.sessionID == frozen.epochID.sessionID, original.epochID.epoch <= frozen.epochID.epoch,
        original.formatSignature == frozen.formatSignature, original.videoClock == frozen.clockBindings.video else {
        throw SourceRecordingError.unsupportedSample("Opening source provenance changed video format or clock identity.")
      }
      if original.epochID != frozen.epochID, original.epochID != lastOriginalSourceEpoch {
        try takeSidecar?.append(.init(kind: "openingSourceProvenance", detail: "Original frame epoch before audio discovery resolved",
          originalValue: pts.value, originalTimescale: pts.timescale, sourceProvenance: original))
      }
      lastOriginalSourceEpoch = original.epochID
    }
    let declaredRate = configuration.sourceFrameRate ?? recordingSourceFormat?.rate
    let rate: RecordingFrameRate
    if let declaredRate {
      try declaredRate.validate()
      rate = Self.matchingFrameRate(declaredRate.nominal) ?? configuration.frameRate
    } else {
      guard let matched = Self.matchingFrameRate(duration), matched == .fps2997 || matched == .fps5994 else {
        throw SourceRecordingError.unsupportedSample("Recording source cadence has no route; declare its source frame rate and timebases before recording.")
      }
      rate = matched
    }
    if recordingTimebase == nil, declaredRate != nil || configuration.declaredTimebases != nil || configuration.quantizationPolicy != nil {
      let selected = try RecordingTimebase.Configuration(frameRate: declaredRate ?? .constant(duration),
        declaredTimebases: configuration.declaredTimebases, quantizationPolicy: configuration.quantizationPolicy)
      recordingTimebase = try RecordingTimebase(configuration: selected, origin: pts)
      timebaseOrigin = pts
      if case .variable = declaredRate { variableFrameTimeline = try VariableFrameTimeline(timescale: selected.timescale) }
    }
    if cadenceConformer == nil, configuration.recordingConstantFrameRate, declaredRate?.isVariable == true {
      cadenceConformer = try RecordingCadenceConformer(frameDuration: rate.frameDuration)
    }
    if cadenceResumePending, var conformer = cadenceConformer {
      let closing = try conformer.reanchor()
      try submitCadence(closing)
      cadenceConformer = conformer
      cadenceResumePending = false
      // The resumed video establishes the shared audio pause offset at the
      // exact next output tick, including any whole-frame rounding at the cut.
      timelineLock.withLock {
        timeline.lastVideoEnd = CMTimeAdd(CMTimeAdd(firstSourceVideoPTS ?? pts, cadenceOutputEnd), timeline.offset)
        timeline.lastVideoNormalizedEnd = CMTimeAdd(cadenceOutputEnd, timeline.offset)
      }
    }
    firstSourceVideoPTS = firstSourceVideoPTS ?? pts
    let normalizedTiming: RecordingTimebase.SampleTiming?
    do { normalizedTiming = try recordingTimebase?.append(pts: pts, duration: duration) }
    catch { throw SourceRecordingError.unsupportedSample("Recording timestamp validation failed: " + String(describing: error)) }
    if var variable = variableFrameTimeline {
      let projected = try variable.append(pts: pts, duration: duration)
      guard let normalizedTiming, CMTimeCompare(projected.presentationTime, normalizedTiming.presentationTime) == 0,
        CMTimeCompare(projected.duration, normalizedTiming.duration) == 0 else {
        throw SourceRecordingError.unsupportedSample("Variable recording timeline disagrees with the selected timebase.")
      }
      variableFrameTimeline = variable
    }
    if let normalizedTiming, let original = normalizedTiming.original {
      try takeSidecar?.append(.init(kind: "quantization", detail: "Original source timing retained", originalValue: pts.value,
        originalTimescale: pts.timescale, quantizationErrorSeconds: normalizedTiming.timestampErrorSeconds,
        originalTiming: original, durationErrorSeconds: normalizedTiming.durationErrorSeconds,
        intervalErrorSeconds: normalizedTiming.intervalErrorSeconds))
    }
    let (session, input, first) = try encoderSession(for: pts, rate: rate)
    if first {
      try configureEncoderColour(session)
      if rate != configuration.frameRate {
        // The session was prepared for the configured cadence; the source
        // runs at the other one. The expected rate is only a hint.
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
          value: Self.expectedFrameRate(rate))
        if configuration.maxKeyFrameInterval != nil {
          let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: configuration.keyframeDuration(for: rate)))
          guard status == noErr || configuration.videoCodec != kCMVideoCodecType_HEVC else {
            throw SourceRecordingError.writerFailure("VideoToolbox rejected the adopted key-frame duration.")
          }
        }
      }
      let captured = Self.captureDate(of: imageBuffer)
      telemetryLock.withLock { firstFrameDate = captured }
    }
    var pauseBoundaryError: Double?
    let (outputPTS, resumedAudio) = timelineLock.withLock { () -> (CMTime, [CMSampleBuffer]) in
      var held: [CMSampleBuffer] = []
      if timeline.resumePending {
        timeline.resumePending = false
        if let normalizedTiming, let previous = timeline.lastVideoNormalizedEnd {
          if let previousRaw = timeline.lastVideoEnd {
            pauseBoundaryError = CMTimeSubtract(normalizedTiming.presentationTime, previous).seconds
              - CMTimeSubtract(pts, previousRaw).seconds
          }
          // Both boundaries are on the immutable selected source grid. Using
          // raw capture time here would reintroduce discarded sub-tick error.
          resumeTimeline(at: normalizedTiming.presentationTime, previousEnd: previous)
        } else { resumeTimeline(at: pts, previousEnd: timeline.lastVideoEnd) }
        held = timeline.heldAudio
        timeline.heldAudio.removeAll()
      }
      timeline.lastVideoEnd = CMTimeAdd(pts, duration)
      timeline.lastVideoNormalizedEnd = normalizedTiming.map { CMTimeAdd($0.presentationTime, $0.duration) }
      return (CMTimeSubtract(normalizedTiming?.presentationTime ?? pts, timeline.offset), held)
    }
    if let pauseBoundaryError, pauseBoundaryError != 0 {
      try takeSidecar?.append(.init(kind: "pauseBoundaryQuantization", detail: "Pause removal uses selected-grid boundaries",
        originalValue: pts.value, originalTimescale: pts.timescale, quantizationErrorSeconds: pauseBoundaryError))
    }
    for audio in resumedAudio { appendHeldAudio(audio) }
    let openingAudio = heldMappedAudio; heldMappedAudio.removeAll()
    for audio in openingAudio { try appendMappedAudio(audio) }
    let prepared: (CVPixelBuffer, FrameRoute)? = sourceAlreadyConverted ? (imageBuffer, .gpu) : try self.encoderImage(for: imageBuffer, input: input)
    guard let (encoderImage, route) = prepared else { return .dropped }
    // Decided per frame, not per route: the GPU route also hands over the
    // capture buffer itself when its repack fails or the frame has no
    // IOSurface. A capture buffer inside VideoToolbox is a driver frame kept
    // from the capture pool, so their number stays bounded.
    if !sourceAlreadyConverted, encoderImage === imageBuffer { try waitForEncoderCapacity() }
    // Counted once the frame is really handed over, never for one that failed waiting.
    switch route {
    case .gpu: break
    case .passThrough: telemetryLock.withLock { telemetryValue.passThroughFrames &+= 1 }
    case .systemCompatibility: break
    }
    if let data = CMGetAttachment(sample, key: SourceRecordingConfiguration.sourceTimecodeAttachmentKey as CFString, attachmentModeOut: nil) as? Data {
      guard data.count <= 4096 else { throw SourceRecordingError.unsupportedSample("Source timecode metadata exceeds its bound.") }
      let raw = try JSONDecoder().decode(Timecode.self, from: data)
      let fieldMarkChanged = raw.fieldMark != lastNativeFieldMark && (raw.fieldMark != nil || hadNativeFieldMark)
      if declaredRate?.isVariable == true || Self.matchingFrameRate(duration) == nil || fieldMarkChanged {
        try takeSidecar?.append(.init(kind: "nativeTimecode", detail: "Original source timecode",
          originalValue: pts.value, originalTimescale: pts.timescale, nativeSourceTimecode: raw))
      }
      lastNativeFieldMark = raw.fieldMark
      hadNativeFieldMark = hadNativeFieldMark || raw.fieldMark != nil
    }
    let nativeData: Data?
    if let data = CMGetAttachment(sample, key: SourceRecordingConfiguration.nativeTimecodeAttachmentKey as CFString, attachmentModeOut: nil) as? Data {
      guard data.count <= 4096 else { throw SourceRecordingError.unsupportedSample("Native timecode metadata exceeds its bound.") }
      _ = try JSONDecoder().decode(TimecodeMetadata.self, from: data)
      nativeData = data
    } else if let native = configuration.nativeTimecodeMetadata, firstSourceVideoPTS.map({ CMTimeCompare($0, pts) == 0 }) == true {
      // This metadata is the observed label at take admission. Later absent
      // labels remain absent; never extrapolate native source timecode.
      nativeData = try JSONEncoder().encode(native)
    } else { nativeData = nil }
    if sourceNativeTrackExpected == nil { sourceNativeTrackExpected = configuration.timecodePolicy == .source && nativeData != nil && declaredRate?.isVariable != true }
    if let nativeData, declaredRate?.isVariable == true || sourceNativeTrackExpected == false {
      let value = try JSONDecoder().decode(TimecodeMetadata.self, from: nativeData)
      try takeSidecar?.append(.init(kind: "nativeTimecode", detail: value.label,
        originalValue: pts.value, originalTimescale: pts.timescale, nativeTimecodeMetadata: value))
    }
    if var conformer = cadenceConformer {
      // Native VFR labels describe source observations. They stay in the
      // journal; repeated CFR frames do not manufacture native labels.
      let jobs = try conformer.append(frame: CadenceFrame(image: encoderImage, nativeTimecode: nil), pts: pts, duration: duration)
      cadenceConformer = conformer
      try submitCadence(jobs)
      telemetryLock.withLock {
        telemetryValue.cadenceRepeatedFrames = UInt64(conformer.statistics.repeated)
        telemetryValue.cadenceSkippedFrames = UInt64(conformer.statistics.skipped)
      }
      try takeSidecar?.append(.init(kind: "cadenceSourceTiming", detail: "Source duration \(duration.value)/\(duration.timescale); output uses explicit constant cadence",
        originalValue: pts.value, originalTimescale: pts.timescale, sourceDurationValue: duration.value, sourceDurationTimescale: duration.timescale))
    } else {
      timelineLock.withLock { selectedTrackTimescale = normalizedTiming?.presentationTime.timescale }
      try submitVideo(session: session, image: encoderImage, pts: outputPTS,
        duration: normalizedTiming?.duration ?? duration, nativeTimecode: nativeData)
    }
    if case let .systemCompatibility(reason) = route {
      noteSystemCompatibility(reason)
      try updateSidecarCounters()
    }
    return .appended
  }

  private func submitCadence(_ jobs: [RecordingCadenceConformer<CadenceFrame>.Output]) throws {
    guard let session = encoderLock.withLock({ compressionSession }) else {
      throw SourceRecordingError.writerFailure("Constant-cadence recording has no encoder.")
    }
    for job in jobs {
      try waitForEncoderCapacity()
      timelineLock.withLock { selectedTrackTimescale = job.duration.timescale }
      try submitVideo(session: session, image: job.frame.image, pts: job.presentationTime,
        duration: job.duration, nativeTimecode: job.frame.nativeTimecode)
      cadenceOutputEnd = CMTimeAdd(job.presentationTime, job.duration)
    }
  }

  private func submitVideo(session: VTCompressionSession, image: CVPixelBuffer, pts: CMTime,
    duration: CMTime, nativeTimecode: Data?) throws {
    let key = try Self.frameKey(pts)
    try telemetryLock.withLock {
      if let nativeTimecode {
        guard submittedNativeTimecodes.count < FrameStartRing.capacity else {
          throw SourceRecordingError.writerFailure("Native timecode handoff is full.")
        }
        submittedNativeTimecodes[key] = nativeTimecode
      }
      frameStarts.push(key, start: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }
    let status = encodeFrame(session, image, pts, duration)
    guard status == noErr else {
      telemetryLock.withLock { frameStarts.removeNewest(key); submittedNativeTimecodes.removeValue(forKey: key) }
      throw SourceRecordingError.writerFailure("VideoToolbox encode failed (OSStatus \(status)).")
    }
  }

  /// The session for the next frame, creating it (outside the lock) if
  /// `start()` could not. Also checks the take is open and time moves forward.
  private func encoderSession(for pts: CMTime, rate: RecordingFrameRate) throws
    -> (VTCompressionSession, EncoderInput, Bool) {
    let existing = try encoderLock.withLock { () throws -> (VTCompressionSession, EncoderInput)? in
      try ensureCanAppend()
      if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS) < 0 {
        // The recorder ends the take first; this is the backstop.
        throw SourceRecordingError.unsupportedSample(
          "Video timestamps moved backwards: the HDMI input changed format or restarted during the take.")
      }
      return compressionSession.map { ($0, encoderInput) }
    }
    if existing == nil { install(try makeCompressionSession(frameRate: rate)) }
    return try encoderLock.withLock { () throws -> (VTCompressionSession, EncoderInput, Bool) in
      try ensureCanAppend()
      guard let compressionSession else {
        throw SourceRecordingError.writerFailure("VideoToolbox compression session is unavailable.")
      }
      let first = lastVideoPTS == nil
      lastVideoPTS = pts
      sourceMediaAdmitted = true
      return (compressionSession, encoderInput, first)
    }
  }

  /// Under `timelineLock`: the first sample after a resume at capture time
  /// `start` continues the take at `previousEnd`.
  private func resumeTimeline(at start: CMTime, previousEnd: CMTime?) {
    guard let previousEnd, CMTimeCompare(start, previousEnd) > 0 else { return }
    timeline.offset = CMTimeAdd(timeline.offset, CMTimeSubtract(start, previousEnd))
    timeline.segments.append((CMTimeSubtract(start, timeline.offset), timeline.offset))
  }

  /// Returns the buffer handed to VideoToolbox. On the GPU route the capture
  /// buffer is released as soon as the repack completes (well under a
  /// millisecond), so a source frame is never held by the encoder or disk.
  /// How a frame reaches VideoToolbox: repacked on the GPU, handed over
  /// natively, or accepted for opaque system conversion (with the reason).
  private enum FrameRoute {
    case gpu
    case passThrough
    case systemCompatibility(String)
  }

  private func encoderImage(for source: CVPixelBuffer, input: EncoderInput) throws
    -> (CVPixelBuffer, FrameRoute)? {
    switch input {
    case .passThrough:
      return (source, .passThrough)
    case let .videoToolboxConverts(reason):
      return (try CPUCompatibilityConverter(policy: configuration.compatibilityPolicy).authorize(source, reason: reason), .systemCompatibility(reason))
    case let .gpuPacked422(converter, pool):
      do {
        let destination = try makeEncoderBuffer(from: pool)
        let start = ProcessInfo.processInfo.systemUptime
        let output = try waitForPackedConversion { completion in
          try converter.convert(source, output: destination, completion: completion)
        }
        Self.copyImageAttachments(from: source, to: output)
        applyEncoderColour(to: output)
        telemetryLock.withLock {
          telemetryValue.gpuConvertedFrames &+= 1
          telemetryValue.gpuConversionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        return (output, .gpu)
      } catch { return try recoverConversionFailure(source, error: error) }
    case let .gpuPlanar(converter, pool):
      guard CVPixelBufferGetIOSurface(source) != nil else {
        let reason = "The planar source buffer is not IOSurface-backed."
        return (try CPUCompatibilityConverter(policy: configuration.compatibilityPolicy).authorize(source, reason: reason), .systemCompatibility(reason))
      }
      do {
        let destination = try makeEncoderBuffer(from: pool)
        let start = ProcessInfo.processInfo.systemUptime
        try converter.convert(source, sourceRange: recordingSourceFormat?.colour.range, into: destination)
        Self.copyImageAttachments(from: source, to: destination)
        applyEncoderColour(to: destination)
        telemetryLock.withLock {
          telemetryValue.gpuConvertedFrames &+= 1
          telemetryValue.gpuConversionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        return (destination, .gpu)
      } catch { return try recoverConversionFailure(source, error: error) }
    case let .gpuRGB(converter, pool, format):
      guard CVPixelBufferGetIOSurface(source) != nil else {
        let reason = "The RGB source buffer is not IOSurface-backed."
        return (try CPUCompatibilityConverter(policy: configuration.compatibilityPolicy).authorize(source, reason: reason), .systemCompatibility(reason))
      }
      do {
        let destination = try makeEncoderBuffer(from: pool)
        let start = ProcessInfo.processInfo.systemUptime
        try converter.convert(source, format: format, sourceRange: recordingSourceFormat?.colour.range, into: destination)
        Self.copyImageAttachments(from: source, to: destination)
        applyEncoderColour(to: destination)
        telemetryLock.withLock {
          telemetryValue.gpuConvertedFrames &+= 1
          telemetryValue.gpuConversionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        return (destination, .gpu)
      } catch { return try recoverConversionFailure(source, error: error) }
    case let .gpu(converter, pool):
      guard CVPixelBufferGetIOSurface(source) != nil else {
        let reason = "The capture buffer is not IOSurface-backed."
        return (try CPUCompatibilityConverter(policy: configuration.compatibilityPolicy).authorize(source, reason: reason), .systemCompatibility(reason))
      }
      do {
        let destination = try conversionOperations.allocateBuffer?(pool) ?? makeEncoderBuffer(from: pool)
        let gpuMS = try conversionOperations.convert?(converter, source, destination) ?? converter.convert(source, into: destination, sourceRange: recordingSourceFormat?.colour.range ?? .video)
        Self.copyImageAttachments(from: source, to: destination)
        applyEncoderColour(to: destination)
        telemetryLock.withLock {
          telemetryValue.gpuConvertedFrames &+= 1
          telemetryValue.gpuConversionMS = telemetryValue.gpuConversionMS.map { $0 * 0.9 + gpuMS * 0.1 } ?? gpuMS
        }
        return (destination, .gpu)
      } catch {
        return try recoverConversionFailure(source, error: error)
      }
    }
  }

  /// Raw NDI UYVA retains its backing owner until the asynchronous GPU helper
  /// completes. It never manufactures a CVPixelBuffer view over raw bytes.
  func appendUYVAVideo(_ source: MTLBuffer, owner: AnyObject, width: Int, height: Int,
    rowBytes: Int, alphaRowBytes: Int, presentationTime: CMTime, duration: CMTime) throws -> RecordingVideoAppendOutcome {
    guard configuration.sidecarMovieURL == nil || takeContext != nil else {
      throw SourceRecordingError.unsupportedSample("Raw UYVA recording requires a resolved take context before media.")
    }
    guard configuration.sourcePixelFormat == PixelFormatID.uyva.rawValue,
      width == configuration.width, height == configuration.height,
      presentationTime.isNumeric, presentationTime.epoch == 0, presentationTime.value >= 0,
      duration.isNumeric, duration.epoch == 0, duration.value > 0 else {
      throw SourceRecordingError.unsupportedSample("Raw UYVA media differs from its recording declaration or has invalid timing.")
    }
    if let admission = sourceAdmission {
      let metadata = SourceAdmissionMetadata(width: width, height: height, pixel: .uyva,
        isPlanar: true, planeCount: 2, rowBytes: 0, dataSize: source.length,
        presentationTime: presentationTime, duration: duration, epochID: admission.epochID,
        formatSignature: admission.formatSignature, planes: [
          .init(width: width, height: height, rowBytes: rowBytes),
          .init(width: width, height: height, rowBytes: alphaRowBytes)])
      do { try admission.validate(metadata, stage: .recordingSource) }
      catch { throw SourceRecordingError.unsupportedSample(String(describing: error)) }
    }
    let input = try encoderLock.withLock { try ensureCanAppend(); return encoderInput }
    guard case let .gpuPacked422(converter, pool) = input else {
      throw SourceRecordingError.unsupportedSample("Raw UYVA requires its proven GPU recording route.")
    }
    let output: CVPixelBuffer
    do {
      let destination = try makeEncoderBuffer(from: pool)
      output = try waitForPackedConversion { completion in
        try converter.convertUYVA(source, owner: owner, width: width, height: height, rowBytes: rowBytes,
          alphaRowBytes: alphaRowBytes, output: destination, completion: completion)
      }
      applyEncoderColour(to: output)
      telemetryLock.withLock { telemetryValue.gpuConvertedFrames &+= 1 }
    } catch {
      // Raw UYVA has no VideoToolbox buffer representation to hand over. A
      // failed GPU frame is counted; the following frame can still record.
      telemetryLock.withLock {
        telemetryValue.gpuConversionFailures &+= 1; telemetryValue.droppedGPUFrames &+= 1
        telemetryValue.warning = "Recording dropped a raw UYVA frame after a GPU error: " + String(describing: error)
      }
      try updateSidecarCounters()
      return .dropped
    }
    var description: CMVideoFormatDescription?
    var status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &description)
    guard status == noErr, let description else { throw SourceRecordingError.writerFailure("UYVA encoder description failed (\(status)).") }
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output,
      formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw SourceRecordingError.writerFailure("UYVA encoder timing failed (\(status)).") }
    return try appendVideoOutcome(sample, sourceAlreadyConverted: true)
  }

  private static func encoderColourValues(_ colour: Colorimetry) -> (CFString?, CFString?, CFString?) {
    let primaries: CFString?
    switch colour.primaries {
    case .rec709: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
    case .rec2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
    case .p3D65: primaries = kCVImageBufferColorPrimaries_P3_D65
    default: primaries = nil
    }
    let transfer: CFString?
    switch colour.transfer {
    case .rec709: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
    case .sRGB: transfer = kCVImageBufferTransferFunction_sRGB
    case .linear: transfer = kCVImageBufferTransferFunction_Linear
    case .pq: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    case .hlg: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
    default: transfer = nil
    }
    let matrix: CFString?
    switch colour.matrix {
    case .rec601: matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    case .rec709: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case .rec2020: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
    default: matrix = nil
    }
    return (primaries, transfer, matrix)
  }

  private func configureEncoderColour(_ session: VTCompressionSession) throws {
    guard let source = recordingSourceFormat else { return }
    let colour = RecordingOutputContract(sourceFormat: source, encoderInputPixelFormat: configuration.videoProfile.encoderPixelFormat,
      codec: configuration.videoCodec).outputColour
    let (primaries, transfer, matrix) = Self.encoderColourValues(colour)
    for (key, value) in [(kVTCompressionPropertyKey_ColorPrimaries, primaries),
      (kVTCompressionPropertyKey_TransferFunction, transfer), (kVTCompressionPropertyKey_YCbCrMatrix, matrix)] {
      guard let value else { continue }
      guard VTSessionSetProperty(session, key: key, value: value) == noErr else {
        throw SourceRecordingError.writerFailure("VideoToolbox rejected the declared recording colour metadata.")
      }
    }
  }

  private func applyEncoderColour(to image: CVPixelBuffer) {
    guard let source = recordingSourceFormat else { return }
    let colour = RecordingOutputContract(sourceFormat: source, encoderInputPixelFormat: configuration.videoProfile.encoderPixelFormat,
      codec: configuration.videoCodec).outputColour
    func attach(_ key: CFString, _ value: CFString?) {
      if let value { CVBufferSetAttachment(image, key, value, .shouldPropagate) }
      else { CVBufferRemoveAttachment(image, key) }
    }
    let (primaries, transfer, matrix) = Self.encoderColourValues(colour)
    attach(kCVImageBufferColorPrimariesKey, primaries)
    attach(kCVImageBufferTransferFunctionKey, transfer)
    attach(kCVImageBufferYCbCrMatrixKey, matrix)
    let chroma: CFString?
    switch (colour.horizontalChromaSiting, colour.verticalChromaSiting) {
    case (.left, .center): chroma = kCVImageBufferChromaLocation_Left
    case (.center, .center): chroma = kCVImageBufferChromaLocation_Center
    case (.left, .top): chroma = kCVImageBufferChromaLocation_TopLeft
    case (.center, .top): chroma = kCVImageBufferChromaLocation_Top
    case (.left, .bottom): chroma = kCVImageBufferChromaLocation_BottomLeft
    case (.center, .bottom): chroma = kCVImageBufferChromaLocation_Bottom
    default: chroma = nil
    }
    attach(kCVImageBufferChromaLocationTopFieldKey, chroma)
    attach(kCVImageBufferChromaLocationBottomFieldKey, chroma)
    CVBufferSetAttachment(image, kCVImageBufferPixelAspectRatioKey,
      [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: NSNumber(value: source.pixelAspect.numerator),
       kCVImageBufferPixelAspectRatioVerticalSpacingKey: NSNumber(value: source.pixelAspect.denominator)] as CFDictionary, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldPropagate)
    CVBufferSetAttachment(image, kCMFormatDescriptionExtension_FullRangeVideo,
      (colour.range == .full ? kCFBooleanTrue : kCFBooleanFalse)!, .shouldPropagate)
  }

  private final class PackedConversionResult: @unchecked Sendable {
    let completion = DispatchSemaphore(value: 0)
    var result: Result<CVPixelBuffer, Error>?
  }
  /// The recorder queue is permitted to wait for its GPU completion; capture
  /// only queues work. The asynchronous converter owns buffers through feedback
  /// even if this bounded wait times out.
  private func waitForPackedConversion(_ submit: (@escaping Packed422RecordingConverter.Completion) throws -> Void) throws -> CVPixelBuffer {
    let state = PackedConversionResult()
    try submit { result in state.result = result; state.completion.signal() }
    guard state.completion.wait(timeout: .now() + 2) == .success, let result = state.result else {
      throw SourceRecordingError.writerFailure("Packed recording conversion exceeded its two-second GPU deadline.")
    }
    return try result.get()
  }

  private func recoverConversionFailure(_ source: CVPixelBuffer, error: Error) throws -> (CVPixelBuffer, FrameRoute)? {
    telemetryLock.withLock { telemetryValue.gpuConversionFailures &+= 1 }
    if configuration.compatibilityPolicy.allowCPUConversion {
      return (try CPUCompatibilityConverter(policy: configuration.compatibilityPolicy).authorize(source,
        reason: error.localizedDescription), .systemCompatibility(error.localizedDescription))
    }
    telemetryLock.withLock {
      telemetryValue.droppedGPUFrames &+= 1
      telemetryValue.warning = "Recording dropped a frame after a GPU conversion failure: \(error.localizedDescription)"
    }
    try updateSidecarCounters()
    return nil
  }

  /// Gives a recycled pool buffer exactly the capture buffer's color, field
  /// and aspect tags, the same ones VideoToolbox sees on the pass-through
  /// route: everything that propagates, plus the image-description keys the
  /// capture buffer holds as should-not-propagate.
  static func copyImageAttachments(from source: CVBuffer, to destination: CVBuffer) {
    CVBufferRemoveAllAttachments(destination)
    CVBufferPropagateAttachments(source, destination)
    guard let others = CVBufferCopyAttachments(source, .shouldNotPropagate) as? [String: Any] else { return }
    for (key, value) in others where key.hasPrefix("CVImageBuffer") || imageDescriptionKeys.contains(key) {
      CVBufferSetAttachment(destination, key as CFString, value as AnyObject, .shouldNotPropagate)
    }
  }

  /// A healthy take that deserves attention: reported as a warning, never
  /// as the take's error.
  private func noteSystemCompatibility(_ reason: String) {
    telemetryLock.withLock {
      telemetryValue.systemCompatibilityFrames &+= 1
      telemetryValue.cpuConvertedFrames = telemetryValue.systemCompatibilityFrames
      if telemetryValue.cpuConvertedFrames == 1 {
        telemetryValue.warning = "Compatibility conversion: VideoToolbox accepted a non-native input; internal CPU/GPU processing is opaque. \(reason)"
      }
    }
  }

  // MARK: Encoder progress

  private var encoderProgressValue: UInt64 {
    encoderProgress.lock()
    defer { encoderProgress.unlock() }
    return encoderProgressCount
  }

  private func signalEncoderProgress() {
    encoderProgress.lock()
    encoderProgressCount &+= 1
    encoderProgress.broadcast()
    encoderProgress.unlock()
  }

  /// Waits (encoder queue only) until VideoToolbox or the pool reports
  /// progress after `seen`, or `limit` passes. The limit only covers a
  /// buffer returned a moment after its signal.
  private func waitForEncoderProgress(after seen: UInt64, limit: TimeInterval = 0.02) {
    encoderProgress.lock()
    defer { encoderProgress.unlock() }
    let deadline = Date(timeIntervalSinceNow: limit)
    while encoderProgressCount == seen, encoderProgress.wait(until: deadline) {}
  }

  /// Takes a native buffer from the encoder's own pool. The pool is bounded;
  /// when VideoToolbox already holds that many frames the encoder is behind,
  /// so wait here (the encoder queue, never capture) and then fail visibly.
  private func makeEncoderBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    let deadline = ProcessInfo.processInfo.systemUptime + Self.encoderStallTimeout
    while true {
      let seen = encoderProgressValue
      var buffer: CVPixelBuffer?
      let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
        Self.poolAuxiliaryAttributes, &buffer)
      if status == kCVReturnSuccess, let buffer { return buffer }
      guard status == kCVReturnWouldExceedAllocationThreshold else {
        throw SourceRecordingError.writerFailure("The encoder pool could not supply a frame (CVReturn \(status)).")
      }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw SourceRecordingError.writerFailure(
          "The encoder fell behind: \(Self.encoderPoolThreshold) frames waited in VideoToolbox for 2 s. The take stopped here and was kept for recovery.")
      }
      waitForEncoderProgress(after: seen)
    }
  }

  /// A frame that hands VideoToolbox the capture buffer itself: wait while it
  /// holds `maximumCaptureFramesInEncoder` frames (counting every frame in
  /// flight, which is conservative when the GPU route falls back for one
  /// frame), then fail visibly, so a stalled encoder ends the take before
  /// the capture pool runs dry.
  private func waitForEncoderCapacity() throws {
    let deadline = ProcessInfo.processInfo.systemUptime + Self.encoderStallTimeout
    while true {
      let seen = encoderProgressValue
      if telemetryLock.withLock({ frameStarts.count }) < Self.maximumCaptureFramesInEncoder { return }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw SourceRecordingError.writerFailure(
          "The encoder fell behind: \(Self.maximumCaptureFramesInEncoder) capture frames waited in VideoToolbox for 2 s. The take stopped here and was kept for recovery.")
      }
      waitForEncoderProgress(after: seen)
    }
  }

  /// The take converts nothing more: let the shared converter release the
  /// surfaces it cached for this take. Runs once.
  private func releaseConverter() {
    let converter = encoderLock.withLock { () -> RecordingPixelConverter? in
      defer { converterInUse = nil }
      return converterInUse
    }
    converter?.endUse()
  }

  private func ensureCanAppend() throws {
    guard started else { throw SourceRecordingError.invalidState(.idle, operation: "append sample") }
    guard !finished, !finishing else { throw SourceRecordingError.invalidState(.stopping, operation: "append sample") }
    if let failure = telemetryLock.withLock({ terminalError }) { throw failure }
  }

  private static func expectedFrameRate(_ rate: RecordingFrameRate) -> NSNumber {
    NSNumber(value: Double(rate.frameDuration.timescale) / Double(rate.frameDuration.value))
  }

  /// Installs a session prepared outside the lock. A session that lost the
  /// race (another was installed, or the take is finishing) is invalidated.
  private func install(_ prepared: PreparedEncoder) {
    let installed = encoderLock.withLock { () -> Bool in
      guard compressionSession == nil, !finished, !finishing else { return false }
      encoderInput = prepared.input
      compressionSession = prepared.session
      if case let .gpu(converter, _) = prepared.input {
        converter.beginUse()
        converterInUse = converter
      }
      return true
    }
    guard installed else {
      VTCompressionSessionInvalidate(prepared.session)
      return
    }
    telemetryLock.withLock {
      telemetryValue.hardwareEncoder = prepared.hardware
      telemetryValue.encoderID = prepared.encoderID
      telemetryValue.encoderInputFormat = prepared.inputDescription
      if case .videoToolboxConverts = prepared.input { telemetryValue.nativeEncoderInput = false }
      else { telemetryValue.nativeEncoderInput = true }
    }
    if case let .gpu(_, pool) = prepared.input {
      // The pool posts this when a buffer returns after hitting its threshold.
      poolObserver = NotificationCenter.default.addObserver(
        forName: Notification.Name(kCVPixelBufferPoolFreeBufferNotification as String), object: pool,
        queue: nil) { [weak self] _ in self?.signalEncoderProgress() }
    }
  }

  /// Creates and prepares a compression session. Slow (about 100 ms cold,
  /// plus the GPU converter's first use), so it runs with no lock held.
  private func makeCompressionSession(frameRate rate: RecordingFrameRate) throws -> PreparedEncoder {
    let width = configuration.width
    let height = configuration.height
    var session: VTCompressionSession?
    let encoderSpecification = configuration.videoProfile.encoderSpecification
    // Ask for the pool in the encoder's native layout: the hardware ProRes
    // and HEVC encoders take x422, not v210.
    let imageBufferAttributes: CFDictionary = [
      kCVPixelBufferPixelFormatTypeKey: configuration.videoProfile.encoderPixelFormat,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
      kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
      width: Int32(width), height: Int32(height), codecType: configuration.videoCodec,
      encoderSpecification: encoderSpecification, imageBufferAttributes: imageBufferAttributes,
      compressedDataAllocator: nil,
      outputCallback: sourceRecordingCompressionCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
    guard status == noErr, let session else {
      throw SourceRecordingError.writerFailure("VideoToolbox could not create a compression session (OSStatus \(status)).")
    }
    if configuration.realTimeEncoding {
      guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
        value: kCFBooleanTrue) == noErr else {
        VTCompressionSessionInvalidate(session)
        throw SourceRecordingError.writerFailure(
          "VideoToolbox rejected real-time encoding for \(configuration.videoProfile.displayName).")
      }
    }
    // Lets the encoder plan its pipeline for the actual cadence.
    _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
      value: Self.expectedFrameRate(rate))
    // ProRes encoders on macOS expose a fixed no-reordering policy and reject
    // this property even though their output is already intra-frame. HEVC
    // must accept it because the source recorder relies on deterministic PTS.
    let noReorderingStatus = VTSessionSetProperty(session,
      key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    if configuration.videoProfile.codecType == kCMVideoCodecType_HEVC,
      noReorderingStatus != noErr {
      VTCompressionSessionInvalidate(session)
      throw SourceRecordingError.writerFailure("VideoToolbox rejected the no-reordering source contract.")
    }
    // A zero frame-count limit delegates count selection to VT; the take's
    // actual policy is a duration, never a hard-coded 60-frame cadence.
    let keyFrameCountStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
      value: NSNumber(value: 0))
    let keyFrameStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
      value: NSNumber(value: configuration.keyframeDuration(for: rate)))
    if configuration.videoProfile.codecType == kCMVideoCodecType_HEVC,
      keyFrameStatus != noErr || keyFrameCountStatus != noErr {
      VTCompressionSessionInvalidate(session)
      throw SourceRecordingError.writerFailure("VideoToolbox rejected the source key-frame duration policy.")
    }
    if let profileLevel = configuration.videoProfile.profileLevel {
      guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
        value: profileLevel as CFString) == noErr else {
        VTCompressionSessionInvalidate(session)
        throw SourceRecordingError.writerFailure(
          "VideoToolbox rejected profile \(profileLevel) for \(configuration.videoProfile.displayName).")
      }
    }
    do { try configureEncoderColour(session) }
    catch { VTCompressionSessionInvalidate(session); throw error }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepareStatus == noErr else {
      VTCompressionSessionInvalidate(session)
      throw SourceRecordingError.writerFailure("VideoToolbox could not prepare the encoder (OSStatus \(prepareStatus)).")
    }
    var hardware: Unmanaged<CFTypeRef>?
    var hardwareValue: Bool?
    if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
      allocator: nil, valueOut: &hardware) == noErr {
      hardwareValue = (hardware?.takeRetainedValue() as? NSNumber)?.boolValue
    }
    var encoderIDRef: Unmanaged<CFTypeRef>?
    var encoderID: String?
    if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
      allocator: nil, valueOut: &encoderIDRef) == noErr {
      encoderID = encoderIDRef?.takeRetainedValue() as? String
    }
    // Metal 4 and resource creation remain mandatory even in compatibility mode.
    let converter: RecordingPixelConverter
    do { converter = try conversionOperations.requireMetal?() ?? RecordingPixelConverter.shared() }
    catch { VTCompressionSessionInvalidate(session); throw error }
    let input: EncoderInput
    do {
      input = try chooseEncoderInput(session: session, converter: converter,
        sourceFormat: configuration.sourcePixelFormat,
        nativeFormat: configuration.videoProfile.encoderPixelFormat)
    } catch { VTCompressionSessionInvalidate(session); throw error }
    let inputDescription: String
    switch input {
    case .passThrough: inputDescription = "v210 (native)"
    case .gpu: inputDescription = "x422 (GPU repack from v210)"
    case .gpuRGB: inputDescription = "l64r (GPU repack from original RGB)"
    case .gpuPlanar: inputDescription = "Native planar input (GPU range/depth repack)"
    case .gpuPacked422: inputDescription = "x422 (GPU repack from packed 8-bit 4:2:2)"
    case let .videoToolboxConverts(reason): inputDescription = "v210 (VideoToolbox compatibility conversion: \(reason))"
    }
    return PreparedEncoder(session: session, input: input, hardware: hardwareValue,
      encoderID: encoderID, inputDescription: inputDescription)
  }

  /// Picks the zero-copy route from what the encoder itself reports.
  private func chooseEncoderInput(session: VTCompressionSession, converter: RecordingPixelConverter, sourceFormat: OSType,
    nativeFormat: OSType) throws -> EncoderInput {
    let supported = conversionOperations.supportedPixelFormats?(session) ?? Self.encoderPixelFormats(session)
    let nativeVideoRange = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange].contains(nativeFormat)
    let needsRangeConversion = recordingSourceFormat?.colour.range == .full && nativeVideoRange
    if sourceFormat == nativeFormat, !needsRangeConversion, supported.contains(sourceFormat) { return .passThrough }
    guard sourceFormat != kCVPixelFormatType_422YpCbCr10 || supported.isEmpty || supported.contains(nativeFormat) else {
      return try compatibilityInput("the encoder takes neither v210 nor x422")
    }
    guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
      return try compatibilityInput("the encoder has no pixel buffer pool")
    }
    let attributes = CVPixelBufferPoolGetPixelBufferAttributes(pool) as? [String: Any]
    if sourceFormat == nativeFormat, !needsRangeConversion, Self.formats(in: attributes) == [nativeFormat],
      attributes?[kCVPixelBufferIOSurfacePropertiesKey as String] != nil { return .passThrough }
    if nativeFormat == Packed422RecordingConverter.outputPixelFormat,
      [kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs, PixelFormatID.uyva.rawValue].contains(sourceFormat) {
      guard recordingSourceFormat?.colour.range != .full else {
        throw SourceRecordingError.unsupportedSample("Recording has no proven full-range packed 4:2:2 to video-range encoder route.")
      }
      guard Self.formats(in: attributes) == [nativeFormat],
        attributes?[kCVPixelBufferIOSurfacePropertiesKey as String] != nil else {
        return try compatibilityInput("no IOSurface x422 encoder pool for packed 4:2:2")
      }
      return .gpuPacked422(try Packed422RecordingConverter(), pool)
    }
    if PlanarRecordingConverter.supports(source: sourceFormat, destination: nativeFormat) {
      guard Self.formats(in: attributes) == [nativeFormat],
        attributes?[kCVPixelBufferIOSurfacePropertiesKey as String] != nil,
        let device = MTLCreateSystemDefaultDevice() else { return try compatibilityInput("no IOSurface native planar encoder pool") }
      return .gpuPlanar(try PlanarRecordingConverter(device: device), pool)
    }
    if nativeFormat == RecordingRGBPixelConverter.outputPixelFormat {
      let format: RGBFormat
      switch sourceFormat {
      case kCVPixelFormatType_32BGRA: format = .bgra8
      case kCVPixelFormatType_32RGBA: format = .rgba8
      case 0x72323130: format = .r210
      case 0x5231324c: format = .r12l
      default: return try compatibilityInput("no GPU RGB-to-l64r route exists for the declared source")
      }
      guard Self.formats(in: attributes) == [nativeFormat],
        attributes?[kCVPixelBufferIOSurfacePropertiesKey as String] != nil,
        let device = MTLCreateSystemDefaultDevice() else { return try compatibilityInput("no IOSurface l64r encoder pool") }
      return .gpuRGB(try RecordingRGBPixelConverter(device: device), pool, format)
    }
    if sourceFormat == nativeFormat, needsRangeConversion {
      return try compatibilityInput("no proven GPU range conversion exists for this native source layout")
    }
    guard Self.formats(in: attributes) == [nativeFormat],
      attributes?[kCVPixelBufferIOSurfacePropertiesKey as String] != nil else {
      return try compatibilityInput("the encoder pool is not IOSurface x422")
    }
    return .gpu(converter, pool)
  }

  private func compatibilityInput(_ reason: String) throws -> EncoderInput {
    try CPUCompatibilityConverter(policy: configuration.compatibilityPolicy).authorizeAdmission(reason: reason)
    return .videoToolboxConverts(reason)
  }

  private func updateSidecarCounters(force: Bool = false) throws {
    guard takeSidecar != nil else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastSidecarCounterUpdate >= 1 else { return }
    lastSidecarCounterUpdate = now
    var counters = telemetryLock.withLock { ["recording.systemCompatibilityFrames": telemetryValue.systemCompatibilityFrames,
      "recording.gpuConversionFailures": telemetryValue.gpuConversionFailures,
      "recording.droppedGPUFrames": telemetryValue.droppedGPUFrames,
      "recording.cadenceRepeatedFrames": telemetryValue.cadenceRepeatedFrames,
      "recording.cadenceSkippedFrames": telemetryValue.cadenceSkippedFrames,
      "audio.mappedFrames": mappedAudioFrames, "audio.discontinuities": mappedAudioDiscontinuities] }
    counters.merge(finalSourceCounters) { _, final in final }
    try takeSidecar?.updateCounters(counters)
  }

  private static func encoderPixelFormats(_ session: VTCompressionSession) -> [OSType] {
    var value: Unmanaged<CFTypeRef>?
    guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_VideoEncoderPixelBufferAttributes,
      allocator: nil, valueOut: &value) == noErr,
      let attributes = value?.takeRetainedValue() as? [String: Any] else { return [] }
    return formats(in: attributes)
  }

  /// CoreVideo stores a pixel format as one number or as a list.
  private static func formats(in attributes: [String: Any]?) -> [OSType] {
    let format = attributes?[kCVPixelBufferPixelFormatTypeKey as String]
    if let list = format as? [NSNumber] { return list.map(\.uint32Value) }
    if let single = format as? NSNumber { return [single.uint32Value] }
    return []
  }

  func recordEncoderFailure(status: OSStatus) {
    telemetryLock.withLock {
      frameStarts.removeAll()
      telemetryValue.droppedEncodedVideo &+= 1
      telemetryValue.encoderErrors &+= 1
      let message = status == noErr
        ? "VideoToolbox returned no encoded sample."
        : "VideoToolbox callback failed (OSStatus \(status))."
      telemetryValue.lastError = message
      if terminalError == nil { terminalError = .writerFailure(message) }
    }
    signalEncoderProgress()
  }

  // MARK: - Hand-off (any thread; short locks only)

  /// VideoToolbox output: queue the compressed sample for the writer queue.
  func appendEncodedVideo(_ sample: CMSampleBuffer) {
    let encodedPTS = CMSampleBufferGetPresentationTimeStamp(sample)
    let nativeKey = try? Rational(encodedPTS.value, Int64(encodedPTS.timescale))
    let native = telemetryLock.withLock { nativeKey.flatMap { submittedNativeTimecodes.removeValue(forKey: $0) } }
    if let native { CMSetAttachment(sample, key: SourceRecordingConfiguration.nativeTimecodeAttachmentKey as CFString,
      value: native as CFData, attachmentMode: kCMAttachmentMode_ShouldNotPropagate) }

    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    telemetryLock.withLock {
      if let key = try? Self.frameKey(pts), let submitted = frameStarts.remove(through: key) {
        let latency = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - submitted) / 1_000_000
        telemetryValue.encoderLatencyMS = telemetryValue.encoderLatencyMS.map { $0 * 0.9 + latency * 0.1 } ?? latency
        telemetryValue.maxEncoderLatencyMS = max(telemetryValue.maxEncoderLatencyMS ?? 0, latency)
      }
    }
    signalEncoderProgress()
    guard CMSampleBufferGetFormatDescription(sample) != nil else {
      fail(.unsupportedSample("VideoToolbox returned a sample without a format description."),
        droppedVideo: 1)
      return
    }
    enqueue(sample, video: true)
  }

  func appendSourceAudio(_ sample: CMSampleBuffer, mapping: AudioVideoClockMapping) throws {
    guard let context = takeContext, case .present(let format) = context.audioDeclaration,
      format.clock != .pairedWithFrames else {
      throw SourceRecordingError.unsupportedSample("Source PCM requires a declared independently clocked audio route.")
    }
    try appendConvertedSourceAudio(sample, transform: .mapped(mapping))
  }

  private static func usesLegacyPairedPCM(_ format: SourceAudioFormat) -> Bool {
    format.clock == .pairedWithFrames && format.sampleRate == 48000 && format.sample == .int32 && format.interleaved
  }

  func appendPairedSourceAudio(_ sample: CMSampleBuffer, videoTime: CMTime) throws {
    try encoderLock.withLock { try ensureCanAppend(); sourceMediaAdmitted = true }
    guard let context = takeContext, case .present(let format) = context.audioDeclaration,
      format.clock == .pairedWithFrames, videoTime.isNumeric, videoTime.epoch == 0 else {
      throw SourceRecordingError.unsupportedSample("Paired PCM requires its declared format and an actual paired video timestamp.")
    }
    if Self.usesLegacyPairedPCM(format) {
      try validateSourceAudioProvenance(sample, context: context, paired: true)
      guard let description = CMSampleBufferGetFormatDescription(sample),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
        asbd.mSampleRate == format.sampleRate, asbd.mChannelsPerFrame == UInt32(format.channels),
        asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
        asbd.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian) == 0,
        let block = CMSampleBufferGetDataBuffer(sample) else { throw ClockMappedPCMError.invalidPacket }
      let count = CMSampleBufferGetTotalSampleSize(sample)
      guard count > 0, count <= configuration.audioRetentionPolicy.maximumBytes, CMSampleBufferGetNumSamples(sample) > 0 else { throw ClockMappedPCMError.invalidPacket }
      var bytes = Data(count: count)
      let status = bytes.withUnsafeMutableBytes { raw in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: raw.baseAddress!)
      }
      guard status == noErr else { throw ClockMappedPCMError.invalidPacket }
      let packed = try makePaired24BitSample(sourcePCM32: bytes, sampleFrameCount: CMSampleBufferGetNumSamples(sample),
        format: format, presentationTime: videoTime)
      try appendAudio(packed)
    } else {
      try appendConvertedSourceAudio(sample, transform: .paired(audioAnchor: CMSampleBufferGetPresentationTimeStamp(sample), videoAnchor: videoTime))
    }
  }

  private func validateSourceAudioProvenance(_ sample: CMSampleBuffer, context: RecordingTakeContext, paired: Bool) throws {
    if let data = CMGetAttachment(sample, key: SourceRecordingConfiguration.sourceProvenanceAttachmentKey as CFString, attachmentModeOut: nil) as? Data {
      guard data.count <= 4096 else {
        throw SourceRecordingError.unsupportedSample("Source PCM provenance exceeds its metadata bound.")
      }
      let original = try JSONDecoder().decode(RecordingSourceProvenance.self, from: data)
      let frozen = context.sourceAdmission
      guard original.epochID.sessionID == frozen.epochID.sessionID,
        original.epochID.epoch <= frozen.epochID.epoch,
        original.formatSignature == frozen.formatSignature,
        original.videoClock == frozen.clockBindings.video,
        (paired ? original.audioClock == frozen.clockBindings.audio : original.audioClock != nil && original.audioClock == frozen.clockBindings.audio) else {
        throw SourceRecordingError.unsupportedSample("Opening PCM provenance changed source identity, video contract or audio clock; its original clock cannot use this take's frozen mapping.")
      }
      if original.epochID != frozen.epochID, original.epochID != lastOriginalAudioEpoch {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        try takeSidecar?.append(.init(kind: "openingAudioSourceProvenance", detail: "Original PCM before audio discovery resolved",
          originalValue: pts.value, originalTimescale: pts.timescale,
          sourceDurationValue: duration.value, sourceDurationTimescale: duration.timescale, sourceProvenance: original))
      }
      lastOriginalAudioEpoch = original.epochID
    }
  }

  private func appendConvertedSourceAudio(_ sample: CMSampleBuffer, transform: PCMClockTransform) throws {
    try encoderLock.withLock { try ensureCanAppend(); sourceMediaAdmitted = true }
    guard let context = takeContext, case .present(let format) = context.audioDeclaration else {
      throw SourceRecordingError.unsupportedSample("Source PCM requires an actual resolved audio declaration.")
    }
    try validateSourceAudioProvenance(sample, context: context, paired: format.clock == .pairedWithFrames)
    if mappedPCMBridge == nil { mappedPCMBridge = try ClockMappedPCMBridge(format: format, outputSampleRate: try recordingPCMOutputSampleRate(for: format)) }
    do {
      if mappedPCMResumePending {
        try mappedPCMBridge!.resume(audioTime: CMSampleBufferGetPresentationTimeStamp(sample), mapping: transform)
        mappedPCMResumePending = false
      }
      if let converted = try mappedPCMBridge!.convert(sample, mapping: transform) {
        if firstSourceVideoPTS == nil {
          try validateHeldAudio(converted, held: heldMappedAudio)
          heldMappedAudio.append(converted)
        } else { try appendMappedAudio(converted) }
      }
      mappedAudioFrames = mappedPCMBridge!.convertedFrames
      telemetryLock.withLock {
        telemetryValue.mappedAudioFrames = mappedAudioFrames
        telemetryValue.audioClockDiscontinuities = mappedAudioDiscontinuities
        telemetryValue.audioCorrectionRatio = mappedPCMBridge!.correctionRatio
      }
      try updateSidecarCounters()
    } catch {
      mappedAudioDiscontinuities &+= 1
      telemetryLock.withLock { telemetryValue.audioClockDiscontinuities = mappedAudioDiscontinuities }
      try takeSidecar?.append(.init(kind: "audioDiscontinuity", detail: String(describing: error)))
      fail(.unsupportedSample("Audio clock correction exceeded its bounds: " + String(describing: error)),
        discardQueued: false, countEncoderError: false)
      throw error
    }
  }

  private func validateHeldAudio(_ candidate: CMSampleBuffer, held: [CMSampleBuffer]) throws {
    let policy = configuration.audioRetentionPolicy
    var bytes = 0
    for sample in held {
      let (sum, overflow) = bytes.addingReportingOverflow(CMSampleBufferGetTotalSampleSize(sample))
      guard !overflow else { throw SourceRecordingError.writerFailure("Held audio byte arithmetic overflowed.") }
      bytes = sum
    }
    let candidateBytes = CMSampleBufferGetTotalSampleSize(candidate)
    let (total, overflow) = bytes.addingReportingOverflow(candidateBytes)
    let duration = held.reduce(0.0) { $0 + CMSampleBufferGetDuration($1).seconds } + CMSampleBufferGetDuration(candidate).seconds
    guard !overflow, total <= policy.maximumBytes, duration.isFinite, duration <= policy.maximumDuration,
      held.count < min(Self.maximumHeldAudio, policy.maximumSlots) else {
      throw SourceRecordingError.writerFailure("Held audio exceeded its byte, duration or slot budget.")
    }
  }

  private func appendMappedAudio(_ converted: CMSampleBuffer) throws {
    guard firstSourceVideoPTS != nil else { return }
    let sourcePTS = CMSampleBufferGetPresentationTimeStamp(converted)
    // Legacy video retains absolute source PTS; an explicit B3 timebase
    // uses its recorded origin. Never subtract a separate audio origin.
    let pts = timebaseOrigin.map { CMTimeSubtract(sourcePTS, $0) } ?? sourcePTS
    // Shift each PCM timing entry; using aggregate packet duration as a
    // per-sample duration multiplies the packet length by its frame count.
    let retimed = try Self.retimed(converted, at: pts)
    let held = try timelineLock.withLock { () throws -> Bool in
      guard timeline.resumePending else { return false }
      try validateHeldAudio(retimed, held: timeline.heldAudio)
      timeline.heldAudio.append(retimed)
      return true
    }
    if !held {
      guard !timelineLock.withLock({ timeline.resumePending }) else {
        throw SourceRecordingError.writerFailure("Mapped audio filled its bounded pause queue before video resumed.")
      }
      try appendTimedAudio(retimed)
    }
  }

  func appendAudio(_ sourceSample: CMSampleBuffer) throws {
    var sample = sourceSample
    if configuration.sidecarMovieURL != nil, takeContext == nil {
      throw SourceRecordingError.unsupportedSample("Recording take context is unresolved; no audio was submitted.")
    }
    if let takeContext {
      guard case .present = takeContext.audioDeclaration else {
        throw SourceRecordingError.unsupportedSample("Recording audio was declared absent; no audio packet may enter this take.")
      }
      // The existing adapter converts declared source int32 into packed
      // signed 24-bit stereo PCM. Validate that derived input independently.
      guard let description = CMSampleBufferGetFormatDescription(sample),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
        asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 48000,
        asbd.mChannelsPerFrame == { if case .present(let f) = takeContext.audioDeclaration { return UInt32(f.channels) }; return 0 }(),
        asbd.mBitsPerChannel == 24, asbd.mBytesPerFrame == asbd.mChannelsPerFrame * 3,
        asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
        asbd.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved) == 0 else {
        throw SourceRecordingError.unsupportedSample("Recording audio packet does not match the current derived 48 kHz / 24-bit stereo PCM input.")
      }
    }
    guard Self.hasValidTiming(sample) else {
      throw SourceRecordingError.unsupportedSample(
        "An audio sample must have a non-negative epoch-zero PTS and positive duration.")
    }
    try encoderLock.withLock {
      try ensureCanAppend()
      sourceMediaAdmitted = true
    }
    // Declared B3 video starts at its selected origin. Legacy packed PCM
    // shares that origin too; an absolute hardware timestamp must never turn
    // into minutes of empty movie time. Opening packets wait within the same
    // byte/time/slot budget used by generic PCM until that origin is known.
    if firstSourceVideoPTS == nil,
      configuration.sourceFrameRate != nil || recordingSourceFormat != nil || configuration.declaredTimebases != nil || configuration.quantizationPolicy != nil {
      try validateHeldAudio(sample, held: heldMappedAudio)
      heldMappedAudio.append(sample)
      return
    }
    if let origin = timebaseOrigin {
      sample = try Self.retimed(sample, at: CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), origin))
    }
    enum Route { case held, append([CMSampleBuffer]) }
    let route = try timelineLock.withLock { () throws -> Route in
      guard timeline.resumePending else { return .append([sample]) }
      // Hold audio after a resume until the first frame sets the offset, so
      // both streams move by the same amount. Without video, audio decides.
      if timeline.heldAudio.count < Self.maximumHeldAudio {
        try validateHeldAudio(sample, held: timeline.heldAudio)
        timeline.heldAudio.append(sample)
        return .held
      }
      timeline.resumePending = false
      let held = timeline.heldAudio + [sample]
      timeline.heldAudio.removeAll()
      if let first = held.first {
        resumeTimeline(at: CMSampleBufferGetPresentationTimeStamp(first), previousEnd: timeline.lastAudioEnd)
      }
      return .append(held)
    }
    guard case let .append(samples) = route, let current = samples.last else { return }
    for held in samples.dropLast() { appendHeldAudio(held) }
    try appendTimedAudio(current)
  }

  /// A packet held across a resume: its own failure is counted here so it
  /// never fails the frame or packet that released it.
  private func appendHeldAudio(_ sample: CMSampleBuffer) {
    do { try appendTimedAudio(sample) } catch {
      telemetryLock.withLock {
        telemetryValue.droppedAudio &+= 1
        telemetryValue.lastError = error.localizedDescription
      }
    }
  }

  /// Moves an audio packet onto the output timeline and queues it. After a
  /// resume, a packet that would overlap audio already accepted is left out
  /// (the two streams stop and resume within a packet of each other).
  private func appendTimedAudio(_ sample: CMSampleBuffer) throws {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let duration = CMSampleBufferGetDuration(sample)
    enum Placement { case write(CMTime), overlap }
    let placement = timelineLock.withLock { () -> Placement in
      // Whole audio samples, so a pause never splits a sample period.
      let offset = timeline.offset == .zero ? CMTime.zero
        : CMTimeConvertScale(timeline.offset, timescale: pts.timescale, method: .roundHalfAwayFromZero)
      let output = CMTimeSubtract(pts, offset)
      if timeline.offset != .zero, let end = timeline.lastAudioOutputEnd, CMTimeCompare(output, end) < 0 {
        return .overlap
      }
      timeline.lastAudioEnd = CMTimeAdd(pts, duration)
      timeline.lastAudioOutputEnd = CMTimeAdd(output, duration)
      return .write(output)
    }
    guard case let .write(output) = placement else {
      telemetryLock.withLock { telemetryValue.pauseTrimmedAudio &+= 1 }
      return
    }
    let timed = output == pts ? sample : try Self.retimed(sample, at: output)
    let late = fifoLock.withLock { () -> Bool in
      lastWrittenAudioPTS.map { CMTimeCompare(output, $0) < 0 } ?? false
    }
    if late {
      throw SourceRecordingError.writerNotReady("The late audio sample was rejected because its timestamp moved backwards.")
    }
    enqueue(timed, video: false)
  }

  /// A copy of the sample moved to start at `time`; the audio bytes are
  /// shared. Every timing entry shifts by the same amount (an LPCM buffer
  /// often carries one per-sample entry, not the packet's total duration).
  private static func retimed(_ sample: CMSampleBuffer, at time: CMTime) throws -> CMSampleBuffer {
    let shift = CMTimeSubtract(time, CMSampleBufferGetPresentationTimeStamp(sample))
    var count: CMItemCount = 0
    var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
      entriesNeededOut: &count)
    var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
    if status == noErr, count > 0 {
      status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings,
        entriesNeededOut: &count)
    } else {
      count = 1
      timings[0] = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
      status = noErr
    }
    for index in timings.indices {
      timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, shift)
      if timings[index].decodeTimeStamp.isValid {
        timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, shift)
      }
    }
    var copy: CMSampleBuffer?
    if status == noErr {
      status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
        sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy)
    }
    guard status == noErr, let copy else {
      throw SourceRecordingError.writerFailure("An audio packet could not be retimed after a pause (OSStatus \(status)).")
    }
    return copy
  }

  private func enqueue(_ sample: CMSampleBuffer, video: Bool) {
    let bytes = CMSampleBufferGetTotalSampleSize(sample)
    enum Outcome { case queued(schedule: Bool), closed, overflow(Int) }
    let outcome = fifoLock.withLock { () -> Outcome in
      guard acceptingMedia else { return .closed }
      if !video {
        let policy = configuration.audioRetentionPolicy
        let duration = pendingAudio.retainedDuration + CMSampleBufferGetDuration(sample).seconds
        let (audioBytes, byteOverflow) = pendingAudio.retainedBytes.addingReportingOverflow(bytes)
        guard !byteOverflow, audioBytes <= policy.maximumBytes,
          pendingAudio.count < policy.maximumSlots, duration.isFinite, duration <= policy.maximumDuration else {
          acceptingMedia = false
          return .overflow(bufferedBytes)
        }
      }
      let (nextBytes, overflow) = bufferedBytes.addingReportingOverflow(bytes)
      guard !overflow, nextBytes <= maximumBufferedBytes else {
        acceptingMedia = false
        return .overflow(bufferedBytes)
      }
      if video { pendingVideo.append(sample) } else { pendingAudio.insertOrdered(sample) }
      bufferedBytes += bytes
      acceptedBytes &+= UInt64(bytes)
      maxBufferedBytesSeen = max(maxBufferedBytesSeen, bufferedBytes)
      let schedule = !pumpScheduled
      pumpScheduled = true
      return .queued(schedule: schedule)
    }
    switch outcome {
    case let .queued(schedule):
      if schedule { writerQueue.async { [weak self] in self?.pump() } }
    case .closed:
      telemetryLock.withLock {
        if video { telemetryValue.droppedEncodedVideo &+= 1 } else { telemetryValue.droppedAudio &+= 1 }
      }
    case let .overflow(waiting):
      let megabytes = waiting / 1_000_000
      fail(.writerFailure("Recording fell behind the disk: \(megabytes) MB of encoded media were waiting to be written. "
        + "The take stopped here and was kept for recovery."),
        droppedVideo: video ? 1 : 0, droppedAudio: video ? 0 : 1, discardQueued: false)
    }
  }

  /// Records the first fatal error. A writer failure discards the queue (the
  /// file can take no more); an overflow keeps draining what is queued so the
  /// preserved take holds everything up to the failure.
  private func fail(_ error: SourceRecordingError, droppedVideo: UInt64 = 0, droppedAudio: UInt64 = 0,
    discardQueued: Bool = true, countEncoderError: Bool = true) {
    let discarded = fifoLock.withLock { () -> (UInt64, UInt64) in
      guard discardQueued else { return (0, 0) }
      acceptingMedia = false
      let counts = (UInt64(pendingVideo.count), UInt64(pendingAudio.count))
      pendingVideo.removeAll()
      pendingAudio.removeAll()
      bufferedBytes = 0
      return counts
    }
    telemetryLock.withLock {
      telemetryValue.droppedEncodedVideo &+= droppedVideo &+ discarded.0
      telemetryValue.droppedAudio &+= droppedAudio &+ discarded.1
      if countEncoderError { telemetryValue.encoderErrors &+= 1 }
      telemetryValue.lastError = error.localizedDescription
      if terminalError == nil { terminalError = error }
    }
  }

  // MARK: - Writer queue

  private enum PumpResult { case idle, blocked, failed }

  private func pump() {
    fifoLock.withLock { pumpScheduled = false }
    let written = writtenItems
    guard drainOnce() == .blocked else {
      retryDelayMS = Self.minimumRetryMS
      return
    }
    // An input is not ready (disk or interleave). Wait on this queue only,
    // backing off while nothing moves; any progress restarts at 2 ms.
    if writtenItems != written { retryDelayMS = Self.minimumRetryMS }
    let retry = fifoLock.withLock { () -> Bool in
      guard !pumpScheduled else { return false }
      pumpScheduled = true
      return true
    }
    guard retry else { return }
    let delay = retryDelayMS
    retryDelayMS = min(Self.maximumRetryMS, retryDelayMS * 2)
    writerQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in self?.pump() }
  }

  /// Appends everything the inputs will take. Writer-queue only.
  private func drainOnce() -> PumpResult {
    guard !writerClosed else { return .idle }
    while true {
      var progressed = false
      do {
        // Peek only to open the file (it needs the first format hint) and to
        // start the session; a sample is popped under the lock right before
        // it is appended, so a concurrent failure or an early audio packet
        // inserted at the front can never make this remove the wrong one.
        if let video = fifoLock.withLock({ pendingVideo.first }) {
          if writer == nil { try openWriter(firstVideo: video) }
          guard let videoInput else { throw SourceRecordingError.writerFailure("Video writer input is unavailable.") }
          let pts = CMSampleBufferGetPresentationTimeStamp(video)
          try ensureSession(at: fifoLock.withLock {
            pendingAudio.first.map { audio in
              let audioPTS = CMSampleBufferGetPresentationTimeStamp(audio)
              return CMTimeCompare(audioPTS, pts) < 0 ? audioPTS : pts
            } ?? pts
          })
          if pendingTimecode.count < Self.maximumPendingTimecode, inputReady(videoInput), let next = fifoLock.withLock({ () -> (CMSampleBuffer, Int)? in
            guard let sample = pendingVideo.first else { return nil }
            let bytes = CMSampleBufferGetTotalSampleSize(sample)
            pendingVideo.removeFirst()
            bufferedBytes -= bytes
            return (sample, bytes)
          }) {
            guard appendSample(next.0, videoInput) else {
              throw Self.writerError(writer, fallback: "Video sample append failed.")
            }
            telemetryLock.withLock {
              telemetryValue.encodedVideo &+= 1
              telemetryValue.encodedVideoBytes &+= UInt64(next.1)
            }
            try queueTimecode(for: next.0)
            writtenItems &+= 1
            progressed = true
          }
        }
        if let timecodeInput {
          while let sample = pendingTimecode.first, inputReady(timecodeInput) {
            guard appendSample(sample, timecodeInput) else {
              throw Self.writerError(writer, fallback: "Timecode sample append failed.")
            }
            pendingTimecode.removeFirst()
            fifoLock.withLock { bufferedBytes = max(0, bufferedBytes - CMSampleBufferGetTotalSampleSize(sample)) }
            writtenItems &+= 1
            progressed = true
          }
        }
        if let audioInput, sessionStarted {
          // Popping also claims the PTS, so `appendAudio` rejects a packet
          // older than one already on its way into the file.
          while inputReady(audioInput), let next = fifoLock.withLock({ () -> (CMSampleBuffer, Bool)? in
            guard let sample = pendingAudio.first else { return nil }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            pendingAudio.removeFirst()
            bufferedBytes -= CMSampleBufferGetTotalSampleSize(sample)
            let late = lastWrittenAudioPTS.map { CMTimeCompare(pts, $0) < 0 } ?? false
            if !late { lastWrittenAudioPTS = pts }
            return (sample, late)
          }) {
            if next.1 {
              telemetryLock.withLock {
                telemetryValue.droppedAudio &+= 1
                telemetryValue.lastError = "An audio packet arrived after later audio was written."
              }
            } else {
              guard appendSample(next.0, audioInput) else {
                throw Self.writerError(writer, fallback: "Pending audio sample append failed.")
              }
            }
            writtenItems &+= 1
            progressed = true
          }
        }
      } catch {
        fail((error as? SourceRecordingError) ?? .writerFailure(error.localizedDescription))
        pendingTimecode.removeAll()
        return .failed
      }
      if !progressed {
        let waiting = fifoLock.withLock {
          !pendingVideo.isEmpty || (!pendingAudio.isEmpty && audioInput != nil && sessionStarted)
        } || !pendingTimecode.isEmpty
        return waiting ? .blocked : .idle
      }
    }
  }

  private func ensureSession(at time: CMTime) throws {
    guard let writer else { throw SourceRecordingError.writerFailure("AVAssetWriter has not been initialized.") }
    if !sessionStarted {
      guard writer.status == .writing else {
        throw Self.writerError(writer, fallback: "AVAssetWriter is not writing.")
      }
      writer.startSession(atSourceTime: time)
      sessionStarted = true
    }
  }

  private func openWriter(firstVideo sample: CMSampleBuffer) throws {
    guard let videoFormat = CMSampleBufferGetFormatDescription(sample) else {
      throw SourceRecordingError.unsupportedSample("VideoToolbox returned a sample without a format description.")
    }
    let adoptedFrameRate = Self.matchingFrameRate(CMSampleBufferGetDuration(sample))
    let adoptedSourceStart = CMSampleBufferGetPresentationTimeStamp(sample)
    let writer: AVAssetWriter
    do {
      let parent = configuration.outputURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: configuration.fileType)
    } catch {
      throw SourceRecordingError.writerFailure(error.localizedDescription)
    }
    // Commit an early playable checkpoint, then use larger fragments for
    // sustained external-drive throughput. Set both before startWriting.
    writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    // Declare the exact packed 48 kHz / 24-bit source format. Passing nil
    // leaves AVAssetWriter free to choose a converter and can silently reject
    // the packed 24-bit CMSampleBuffers produced from source PCM.
    let audio: AVAssetWriterInput?
    if let context = takeContext, case .absent = context.audioDeclaration { audio = nil }
    else if let context = takeContext, case .present(let format) = context.audioDeclaration, !Self.usesLegacyPairedPCM(format) {
      let outputFormat = try SourceAudioFormat(sampleRate: format.sampleRate, channels: format.channels,
        sample: .float32, interleaved: true, layout: format.layout, clock: .pairedWithFrames)
      audio = AVAssetWriterInput(mediaType: .audio,
        outputSettings: try EmbeddedAudioFormat.assetWriterSettings(format: outputFormat, outputSampleRate: try recordingPCMOutputSampleRate(for: format)))
    } else if let context = takeContext, case .present(let format) = context.audioDeclaration {
      audio = AVAssetWriterInput(mediaType: .audio, outputSettings: try EmbeddedAudioFormat.assetWriterSettings(format: format, outputSampleRate: format.sampleRate))
    } else { audio = AVAssetWriterInput(mediaType: .audio, outputSettings: EmbeddedAudioFormat.assetWriterSettings) }
    let rate = adoptedFrameRate ?? configuration.frameRate
    // The default 1/600 s timebase can't hold a 1001/60000 s frame, so every
    // 59.94 frame was rounded to 1/60 s and editors read the take as 60 fps
    // or variable rate. Use the rate's own timescale for the video track and
    // the movie, so each frame lasts exactly 1001/30000 or 1001/60000 s.
    nativeTimecodeMetadata = configuration.nativeTimecodeMetadata
    nativeTimecodeOrigin = adoptedSourceStart
    let selectedTrackScale = timelineLock.withLock { selectedTrackTimescale } ?? rate.frameDuration.timescale
    video.mediaTimeScale = selectedTrackScale
    writer.movieTimeScale = selectedTrackScale
    let attachedNative = try Self.nativeTimecode(from: sample)
    nativeTimecodeMetadata = attachedNative ?? configuration.nativeTimecodeMetadata
    let isVariable = (configuration.sourceFrameRate ?? recordingSourceFormat?.rate)?.isVariable == true
    let generatedTimecodeTrack: QuickTimeTimecodeTrack?
    if isVariable && (!configuration.recordingConstantFrameRate || configuration.timecodePolicy == .source) { generatedTimecodeTrack = nil }
    else if configuration.timecodePolicy == .source, let native = attachedNative ?? configuration.nativeTimecodeMetadata {
      generatedTimecodeTrack = try QuickTimeTimecodeTrack(frameRate: native.frameRate, dropFrame: native.dropFrame)
    } else { generatedTimecodeTrack = try Self.makeTimecodeTrack(for: configuration, frameRate: rate) }
    let timecode = generatedTimecodeTrack?.makeInput()
    video.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    audio?.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    timecode?.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    guard writer.canAdd(video), audio.map({ writer.canAdd($0) }) ?? true,
      timecode.map({ writer.canAdd($0) }) ?? true else {
      throw SourceRecordingError.writerFailure("The output container cannot add source tracks.")
    }
    Self.invokeAddInput(writer, input: video)
    if let audio { Self.invokeAddInput(writer, input: audio) }
    if let timecode {
      Self.invokeAddInput(writer, input: timecode)
      video.addTrackAssociation(withTrackOf: timecode,
        type: AVAssetTrack.AssociationType.timecode.rawValue)
    }
    guard Self.invokeStartWriting(writer) else {
      throw Self.writerError(writer, fallback: "AVAssetWriter could not start writing.")
    }
    self.writer = writer
    self.videoInput = video
    self.audioInput = audio
    self.timecodeInput = timecode
    self.timecodeTrack = generatedTimecodeTrack
    if generatedTimecodeTrack != nil {
      // A zero source start means the caller did not know the first frame's
      // PTS yet. Anchor record-start and wall-clock timecode there so capture
      // uptime is not added to the label, and so 29.97 is not counted at 59.94.
      let configuredOrigin = configuration.timecodeSourceStartTime
      let origin = configuredOrigin == .zero ? adoptedSourceStart : configuredOrigin
      let firstFrame = telemetryLock.withLock { firstFrameDate }
      self.timecodeSession = RecordingTimecodeSession(
        frameRate: rate,
        dropFrame: configuration.timecodeDropFrame,
        policy: configuration.timecodePolicy,
        startDate: Self.timecodeAnchorDate(for: configuration, firstFrame: firstFrame),
        sourceStartTime: origin)
    }
  }

  /// Timecode waits for its input like video and audio; it is never dropped.
  /// Record-start timecode counts the movie's own frames; wall-clock timecode
  /// labels each frame with its capture time, so a pause shows as a jump.
  private func enqueueTimecode(_ sample: CMSampleBuffer) throws {
    let bytes = CMSampleBufferGetTotalSampleSize(sample)
    try fifoLock.withLock {
      let (total, overflow) = bufferedBytes.addingReportingOverflow(bytes)
      guard !overflow, total <= maximumBufferedBytes, pendingTimecode.count < Self.maximumPendingTimecode else {
        throw SourceRecordingError.writerFailure("Timecode metadata exceeded its byte or slot budget.")
      }
      bufferedBytes = total
      maxBufferedBytesSeen = max(maxBufferedBytesSeen, total)
      acceptedBytes &+= UInt64(bytes)
    }
    pendingTimecode.append(sample)
  }

  private static func nativeTimecode(from sample: CMSampleBuffer) throws -> TimecodeMetadata? {
    guard let data = CMGetAttachment(sample, key: SourceRecordingConfiguration.nativeTimecodeAttachmentKey as CFString, attachmentModeOut: nil) as? Data else { return nil }
    guard data.count <= 4096 else { throw SourceRecordingError.unsupportedSample("Native timecode metadata exceeds its bound.") }
    return try JSONDecoder().decode(TimecodeMetadata.self, from: data)
  }

  private func queueTimecode(for sample: CMSampleBuffer) throws {
    let outputPTS = CMSampleBufferGetPresentationTimeStamp(sample)
    guard timecodeInput != nil, let timecodeTrack else { return }
    if configuration.timecodePolicy == .source {
      guard let native = try Self.nativeTimecode(from: sample),
        let value = RecordingTimecode(string: native.label, frameRate: native.frameRate, dropFrame: native.dropFrame) else { return }
      if let initial = nativeTimecodeMetadata, initial.frameRate != native.frameRate || initial.dropFrame != native.dropFrame {
        throw SourceRecordingError.unsupportedSample("Native timecode rate or drop-frame flag changed within the take.")
      }
      try enqueueTimecode(timecodeTrack.sample(for: value, at: outputPTS)); return
    }
    guard let timecodeSession else { return }
    let labelTime = timecodeSession.policy == .wallClock
      ? CMTimeAdd(outputPTS, timelineLock.withLock { timeline.offset(atOutput: outputPTS) })
      : outputPTS
    guard let value = timecodeSession.timecode(for: labelTime) else {
      throw SourceRecordingError.unsupportedSample("The source timestamp cannot be mapped to timecode.")
    }
    try enqueueTimecode(timecodeTrack.sample(for: value, at: outputPTS))
  }

  // MARK: - Finish

  func finish(finalError: String?, sourceCounters: [String: UInt64]) throws {
    finalSourceCounters = sourceCounters
    try finish(finalError: finalError)
  }
  func finish() throws { try finish(finalError: nil) }
  func finish(finalError: String?) throws {
    do {
      if firstSourceVideoPTS == nil { heldMappedAudio.removeAll() }
      do {
        if let final = try mappedPCMBridge?.finish() { try appendMappedAudio(final) }
      } catch {
        mappedAudioDiscontinuities &+= 1
        telemetryLock.withLock { telemetryValue.audioClockDiscontinuities = mappedAudioDiscontinuities }
        rememberFinalizationFailure(SourceRecordingError.unsupportedSample("Audio tail could not be finalized: " + String(describing: error)))
      }
      if let bridge = mappedPCMBridge {
        mappedAudioFrames = bridge.convertedFrames
        telemetryLock.withLock { telemetryValue.mappedAudioFrames = bridge.convertedFrames }
      }
      try finishMedia()
      try updateSidecarCounters(force: true)
      if let diagnostics = recordingTimebase?.diagnostics { try takeSidecar?.updateTimebaseDiagnostics(diagnostics) }
      try takeSidecar?.finish(finalError: finalError ?? telemetry.lastError)
    } catch {
      try? updateSidecarCounters(force: true)
      if let diagnostics = recordingTimebase?.diagnostics { try? takeSidecar?.updateTimebaseDiagnostics(diagnostics) }
      try? takeSidecar?.finish(finalError: error.localizedDescription)
      throw error
    }
  }
  private func rememberFinalizationFailure(_ error: Error) {
    let failure = (error as? SourceRecordingError) ?? .writerFailure(String(describing: error))
    telemetryLock.withLock {
      if terminalError == nil { terminalError = failure }
      telemetryValue.lastError = terminalError?.localizedDescription
    }
  }

  private func finishMedia() throws {
    let compressionSession = try encoderLock.withLock { () throws -> VTCompressionSession?? in
      guard started, !finished, !finishing else { return .none }
      finishing = true
      return .some(self.compressionSession)
    }
    guard let compressionSession else { return }
    defer {
      encoderLock.withLock { finished = true; finishing = false }
      cadenceConformer = nil
      releaseConverter()
    }
    do {
      if var conformer = cadenceConformer {
        let jobs = try conformer.finish()
        cadenceConformer = conformer
        try submitCadence(jobs)
        telemetryLock.withLock {
          telemetryValue.cadenceRepeatedFrames = UInt64(conformer.statistics.repeated)
          telemetryValue.cadenceSkippedFrames = UInt64(conformer.statistics.skipped)
        }
      }
    } catch { rememberFinalizationFailure(error) }
    // Audio still held for the first post-resume frame goes in as it is.
    let held = timelineLock.withLock { () -> [CMSampleBuffer] in
      defer { timeline.heldAudio.removeAll(); timeline.resumePending = false }
      guard timeline.resumePending, let first = timeline.heldAudio.first else { return [] }
      resumeTimeline(at: CMSampleBufferGetPresentationTimeStamp(first), previousEnd: timeline.lastAudioEnd)
      return timeline.heldAudio
    }
    for audio in held { appendHeldAudio(audio) }
    // CompleteFrames synchronously invokes the VideoToolbox callback, which
    // only queues samples, so no lock may be (and none is) held here.
    if let compressionSession {
      let status = completeFrames(compressionSession)
      if status != noErr {
        rememberFinalizationFailure(SourceRecordingError.writerFailure("VideoToolbox flush failed (OSStatus \(status))."))
      }
    }
    let closing = writerQueue.sync { () -> Result<AVAssetWriter?, SourceRecordingError> in
      let stalled = drainForFinish()
      fifoLock.withLock { acceptingMedia = false }
      writerClosed = true
      let leftovers = fifoLock.withLock { () -> (video: Int, audio: Int) in
        let counts = (pendingVideo.count, pendingAudio.count)
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        bufferedBytes = 0
        return counts
      }
      let pendingTimecodeCount = pendingTimecode.count
      pendingTimecode.removeAll()
      if stalled && pendingTimecodeCount > 0 {
        let message = "\(pendingTimecodeCount) timecode samples were still waiting for the disk when recording stopped."
        telemetryLock.withLock {
          telemetryValue.droppedTimecode &+= UInt64(pendingTimecodeCount)
          telemetryValue.lastError = message
          if terminalError == nil { terminalError = .writerFailure(message) }
        }
      }
      guard let writer else {
        if leftovers.video > 0 || leftovers.audio > 0 {
          return .failure(.writerFailure("Recording stopped before video established the file."))
        }
        return .success(nil)
      }
      if leftovers.video > 0 || leftovers.audio > 0 {
        let message = leftovers.video > 0
          ? "\(leftovers.video) encoded frames were still waiting for the disk when recording stopped."
          : "Audio was still queued when recording stopped."
        telemetryLock.withLock {
          telemetryValue.droppedEncodedVideo &+= UInt64(leftovers.video)
          telemetryValue.droppedAudio &+= UInt64(leftovers.audio)
          telemetryValue.lastError = message
          if terminalError == nil { terminalError = .writerFailure(message) }
        }
      }
      videoInput?.markAsFinished()
      audioInput?.markAsFinished()
      timecodeInput?.markAsFinished()
      return .success(writer)
    }
    let closedWriter: AVAssetWriter?
    do { closedWriter = try closing.get() }
    catch {
      rememberFinalizationFailure(error)
      throw telemetryLock.withLock { terminalError ?? .writerFailure(String(describing: error)) }
    }
    guard let writer = closedWriter else {
      if let callbackError = telemetryLock.withLock({ self.terminalError }) { throw callbackError }
      return
    }
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    if let callbackError = telemetryLock.withLock({ self.terminalError }) { throw callbackError }
    if writer.status == .failed {
      throw Self.writerError(writer, fallback: "AVAssetWriter finish failed.")
    }
  }

  /// Writer-queue only. Waits for every queued sample, giving up only when
  /// the writer makes no progress at all for `finishStallTimeout`.
  private func drainForFinish() -> Bool {
    var lastProgress = ProcessInfo.processInfo.systemUptime
    var lastWritten = writtenItems
    var delayMS = 1
    while true {
      let result = drainOnce()
      guard result == .blocked else { return false }
      let now = ProcessInfo.processInfo.systemUptime
      if writtenItems != lastWritten {
        lastWritten = writtenItems
        lastProgress = now
        delayMS = 1
      } else if now - lastProgress > Self.finishStallTimeout {
        return true
      }
      Thread.sleep(forTimeInterval: Double(delayMS) / 1_000)
      delayMS = min(20, delayMS * 2)
    }
  }

  /// Runs one writer-queue pass and waits for it. For tests and diagnostics.
  func flushWriterQueue() {
    writerQueue.sync { _ = drainOnce() }
  }

  // MARK: - Helpers

  private static func frameKey(_ pts: CMTime) throws -> Rational {
    guard pts.isNumeric, pts.timescale > 0 else { throw SourceRecordingError.unsupportedSample("Encoder timestamp is not numeric.") }
    return try Rational(pts.value, Int64(pts.timescale))
  }

  private static func invokeStartWriting(_ writer: AVAssetWriter) -> Bool {
    let selector = NSSelectorFromString("startWriting")
    guard let implementation = writer.method(for: selector) else { return false }
    typealias Function = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(implementation, to: Function.self)(writer, selector)
  }

  private static func invokeAddInput(_ writer: AVAssetWriter, input: AVAssetWriterInput) {
    let selector = NSSelectorFromString("addInput:")
    guard let implementation = writer.method(for: selector) else { return }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    unsafeBitCast(implementation, to: Function.self)(writer, selector, input)
  }

  private static func inputIsReady(_ input: AVAssetWriterInput) -> Bool {
    (input.value(forKey: "readyForMoreMediaData") as? NSNumber)?.boolValue ?? false
  }

  private static func hasValidTiming(_ sample: CMSampleBuffer) -> Bool {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let duration = CMSampleBufferGetDuration(sample)
    return CMSampleBufferDataIsReady(sample) &&
      pts.isValid && pts.isNumeric && pts.epoch == 0 && pts.value >= 0 &&
      duration.isValid && duration.isNumeric && duration.epoch == 0 && duration.value > 0
  }

  private static func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
    let selector = NSSelectorFromString("appendSampleBuffer:")
    guard let implementation = input.method(for: selector) else { return false }
    typealias Function = @convention(c) (AnyObject, Selector, CMSampleBuffer) -> Bool
    return unsafeBitCast(implementation, to: Function.self)(input, selector, sample)
  }

  private static func writerError(_ writer: AVAssetWriter?, fallback: String) -> SourceRecordingError {
    .writerFailure(writer?.error?.localizedDescription ?? fallback)
  }
}

private func sourceRecordingCompressionCallback(outputCallbackRefCon: UnsafeMutableRawPointer?,
  sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags,
  sampleBuffer: CMSampleBuffer?) {
  guard let outputCallbackRefCon else { return }
  let writer = Unmanaged<AVAssetSourceRecordingWriter>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
  guard status == noErr, let sampleBuffer else {
    writer.recordEncoderFailure(status: status)
    return
  }
  writer.appendEncodedVideo(sampleBuffer)
}
