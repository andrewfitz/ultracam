import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

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
    /// No zero-copy route: VideoToolbox converts (CPU). Counted and reported.
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
    var isEmpty: Bool { head == items.count }
    var count: Int { items.count - head }
    var first: CMSampleBuffer? { isEmpty ? nil : items[head] }
    mutating func append(_ sample: CMSampleBuffer) { items.append(sample) }
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
    }
    mutating func removeFirst() {
      guard !isEmpty else { return }
      head += 1
      if head == items.count { items.removeAll(keepingCapacity: true); head = 0 }
      else if head >= 256, head * 2 >= items.count { items.removeFirst(head); head = 0 }
    }
    mutating func removeAll() { items.removeAll(); head = 0 }
  }

  /// Submission times of frames inside VideoToolbox, oldest first. The
  /// encoder returns frames in submission order (no reordering), so a fixed
  /// ring replaces a per-frame dictionary.
  private struct FrameStartRing {
    static let capacity = 256
    private var keys = [Int64](repeating: 0, count: capacity)
    private var starts = [UInt64](repeating: 0, count: capacity)
    private var head = 0
    private(set) var count = 0

    mutating func push(_ key: Int64, start: UInt64) {
      if count == Self.capacity { head = (head + 1) % Self.capacity; count -= 1 }
      let index = (head + count) % Self.capacity
      keys[index] = key
      starts[index] = start
      count += 1
    }

    /// Removes the newest entry if it is `key` (a submission that failed).
    mutating func removeNewest(_ key: Int64) {
      guard count > 0, keys[(head + count - 1) % Self.capacity] == key else { return }
      count -= 1
    }

    /// Removes `key` and every older entry (frames VideoToolbox dropped), and
    /// returns its submission time.
    mutating func remove(through key: Int64) -> UInt64? {
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

  private let configuration: SourceRecordingConfiguration
  private let encodeFrame: EncodeFrame
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
    maximumBufferedBytes: Int? = nil) throws {
    self.configuration = configuration
    self.encodeFrame = encodeFrame
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
    guard configuration.timecodePolicy != .source else { return nil }
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
    let rates: [RecordingFrameRate] = [.fps2997, .fps5994]
    for rate in rates where abs(duration.seconds - rate.frameDuration.seconds) < 0.0001 {
      return rate
    }
    return nil
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
    if needsSession, let prepared = try? makeCompressionSession(frameRate: configuration.frameRate) {
      install(prepared)
    }
    EmbeddedAudioRecording.prepareFormat()
  }

  /// The recorder resumed a paused take: the next frame continues the movie
  /// straight after the last one written before the pause.
  func resumeAfterPause() {
    timelineLock.withLock {
      guard timeline.lastVideoEnd != nil || timeline.lastAudioEnd != nil else { return }
      timeline.resumePending = true
    }
  }

  // MARK: - Encoder stage

  func appendVideo(_ sample: CMSampleBuffer) throws {
    guard Self.hasValidTiming(sample) else {
      throw SourceRecordingError.unsupportedSample(
        "A video sample must have a non-negative epoch-zero PTS and positive duration.")
    }
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
      throw SourceRecordingError.unsupportedSample("A video sample has no image buffer.")
    }
    guard CVPixelBufferGetPixelFormatType(imageBuffer) == configuration.videoProfile.sourcePixelFormat else {
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
    let rate = Self.matchingFrameRate(duration) ?? configuration.frameRate
    let (session, input, first) = try encoderSession(for: pts, rate: rate)
    if first {
      if rate != configuration.frameRate {
        // The session was prepared for the configured cadence; the source
        // runs at the other one. The expected rate is only a hint.
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
          value: Self.expectedFrameRate(rate))
      }
      let captured = Self.captureDate(of: imageBuffer)
      telemetryLock.withLock { firstFrameDate = captured }
    }
    let (outputPTS, resumedAudio) = timelineLock.withLock { () -> (CMTime, [CMSampleBuffer]) in
      var held: [CMSampleBuffer] = []
      if timeline.resumePending {
        timeline.resumePending = false
        resumeTimeline(at: pts, previousEnd: timeline.lastVideoEnd)
        held = timeline.heldAudio
        timeline.heldAudio.removeAll()
      }
      timeline.lastVideoEnd = CMTimeAdd(pts, duration)
      return (CMTimeSubtract(pts, timeline.offset), held)
    }
    for audio in resumedAudio { appendHeldAudio(audio) }
    let (encoderImage, route) = try self.encoderImage(for: imageBuffer, input: input)
    // Decided per frame, not per route: the GPU route also hands over the
    // capture buffer itself when its repack fails or the frame has no
    // IOSurface. A capture buffer inside VideoToolbox is a driver frame kept
    // from the capture pool, so their number stays bounded.
    if encoderImage === imageBuffer { try waitForEncoderCapacity() }
    // Counted once the frame is really handed over, never for one that failed waiting.
    switch route {
    case .gpu: break
    case .passThrough: telemetryLock.withLock { telemetryValue.passThroughFrames &+= 1 }
    case let .cpu(reason): noteCPUConversion(reason)
    }
    let key = Self.frameKey(outputPTS)
    telemetryLock.withLock { frameStarts.push(key, start: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
    // Submission can wait for an output callback on another thread (notably
    // remote ProRes encoders). The callback only takes short locks, and none
    // is held here, so the two can never wait on each other.
    let status = encodeFrame(session, encoderImage, outputPTS, duration)
    guard status == noErr else {
      telemetryLock.withLock { frameStarts.removeNewest(key) }
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
  /// millisecond), so a DeckLink frame is never held by the encoder or disk.
  /// How a frame reaches VideoToolbox: repacked on the GPU, handed over
  /// natively, or converted by VideoToolbox on the CPU (with the reason).
  private enum FrameRoute {
    case gpu
    case passThrough
    case cpu(String)
  }

  private func encoderImage(for source: CVPixelBuffer, input: EncoderInput) throws
    -> (CVPixelBuffer, FrameRoute) {
    switch input {
    case .passThrough:
      return (source, .passThrough)
    case let .videoToolboxConverts(reason):
      return (source, .cpu(reason))
    case let .gpu(converter, pool):
      guard CVPixelBufferGetIOSurface(source) != nil else {
        return (source, .cpu("The capture buffer is not IOSurface-backed."))
      }
      let destination = try makeEncoderBuffer(from: pool)
      do {
        let gpuMS = try converter.convert(source, into: destination)
        Self.copyImageAttachments(from: source, to: destination)
        telemetryLock.withLock {
          telemetryValue.gpuConvertedFrames &+= 1
          telemetryValue.gpuConversionMS = telemetryValue.gpuConversionMS.map { $0 * 0.9 + gpuMS * 0.1 } ?? gpuMS
        }
        return (destination, .gpu)
      } catch {
        // Never lose the frame: let VideoToolbox convert it, and say so.
        return (source, .cpu(error.localizedDescription))
      }
    }
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
  private func noteCPUConversion(_ reason: String) {
    telemetryLock.withLock {
      telemetryValue.cpuConvertedFrames &+= 1
      if telemetryValue.cpuConvertedFrames == 1 {
        telemetryValue.warning = "VideoToolbox is converting frames on the CPU: \(reason)"
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
    let keyFrameInterval = configuration.maxKeyFrameInterval as CFTypeRef
    let keyFrameStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
      value: keyFrameInterval)
    if configuration.videoProfile.codecType == kCMVideoCodecType_HEVC,
      keyFrameStatus != noErr {
      VTCompressionSessionInvalidate(session)
      throw SourceRecordingError.writerFailure("VideoToolbox rejected the source key-frame interval.")
    }
    if let profileLevel = configuration.videoProfile.profileLevel {
      guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
        value: profileLevel as CFString) == noErr else {
        VTCompressionSessionInvalidate(session)
        throw SourceRecordingError.writerFailure(
          "VideoToolbox rejected profile \(profileLevel) for \(configuration.videoProfile.displayName).")
      }
    }
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
    let input = Self.chooseEncoderInput(session: session,
      sourceFormat: configuration.videoProfile.sourcePixelFormat,
      nativeFormat: configuration.videoProfile.encoderPixelFormat)
    let inputDescription: String
    switch input {
    case .passThrough: inputDescription = "v210 (native)"
    case .gpu: inputDescription = "x422 (GPU repack from v210)"
    case let .videoToolboxConverts(reason): inputDescription = "v210 (VideoToolbox CPU conversion: \(reason))"
    }
    return PreparedEncoder(session: session, input: input, hardware: hardwareValue,
      encoderID: encoderID, inputDescription: inputDescription)
  }

  /// Picks the zero-copy route from what the encoder itself reports.
  private static func chooseEncoderInput(session: VTCompressionSession, sourceFormat: OSType,
    nativeFormat: OSType) -> EncoderInput {
    let supported = encoderPixelFormats(session)
    if supported.contains(sourceFormat) { return .passThrough }
    guard supported.isEmpty || supported.contains(nativeFormat) else {
      return .videoToolboxConverts("the encoder takes neither v210 nor x422")
    }
    guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
      return .videoToolboxConverts("the encoder has no pixel buffer pool")
    }
    let attributes = CVPixelBufferPoolGetPixelBufferAttributes(pool) as? [String: Any]
    guard formats(in: attributes) == [nativeFormat],
      attributes?[kCVPixelBufferIOSurfacePropertiesKey as String] != nil else {
      return .videoToolboxConverts("the encoder pool is not IOSurface x422")
    }
    do { return .gpu(try RecordingPixelConverter.shared(), pool) }
    catch { return .videoToolboxConverts(error.localizedDescription) }
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

  fileprivate func recordEncoderFailure(status: OSStatus) {
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
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    telemetryLock.withLock {
      if let submitted = frameStarts.remove(through: Self.frameKey(pts)) {
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

  func appendAudio(_ sample: CMSampleBuffer) throws {
    guard Self.hasValidTiming(sample) else {
      throw SourceRecordingError.unsupportedSample(
        "An audio sample must have a non-negative epoch-zero PTS and positive duration.")
    }
    try encoderLock.withLock { try ensureCanAppend() }
    enum Route { case held, append([CMSampleBuffer]) }
    let route = timelineLock.withLock { () -> Route in
      guard timeline.resumePending else { return .append([sample]) }
      // Hold audio after a resume until the first frame sets the offset, so
      // both streams move by the same amount. Without video, audio decides.
      if timeline.heldAudio.count < Self.maximumHeldAudio {
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
      guard bufferedBytes + bytes <= maximumBufferedBytes else {
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
    discardQueued: Bool = true) {
    let discarded = fifoLock.withLock { () -> (UInt64, UInt64) in
      acceptingMedia = false
      guard discardQueued else { return (0, 0) }
      let counts = (UInt64(pendingVideo.count), UInt64(pendingAudio.count))
      pendingVideo.removeAll()
      pendingAudio.removeAll()
      bufferedBytes = 0
      return counts
    }
    telemetryLock.withLock {
      telemetryValue.droppedEncodedVideo &+= droppedVideo &+ discarded.0
      telemetryValue.droppedAudio &+= droppedAudio &+ discarded.1
      telemetryValue.encoderErrors &+= 1
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
          if inputReady(videoInput), let next = fifoLock.withLock({ () -> (CMSampleBuffer, Int)? in
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
            try queueTimecode(for: CMSampleBufferGetPresentationTimeStamp(next.0))
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
    // the packed 24-bit CMSampleBuffers produced from DeckLink PCM.
    let audio = AVAssetWriterInput(mediaType: .audio,
      outputSettings: EmbeddedAudioFormat.assetWriterSettings)
    let rate = adoptedFrameRate ?? configuration.frameRate
    let generatedTimecodeTrack = try Self.makeTimecodeTrack(for: configuration, frameRate: rate)
    let timecode = generatedTimecodeTrack?.makeInput()
    video.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    audio.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    timecode?.setValue(NSNumber(value: configuration.realTimeEncoding), forKey: "expectsMediaDataInRealTime")
    guard writer.canAdd(video), writer.canAdd(audio),
      timecode.map({ writer.canAdd($0) }) ?? true else {
      throw SourceRecordingError.writerFailure("The output container cannot add source tracks.")
    }
    Self.invokeAddInput(writer, input: video)
    Self.invokeAddInput(writer, input: audio)
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
  private func queueTimecode(for outputPTS: CMTime) throws {
    guard timecodeInput != nil, let timecodeTrack, let timecodeSession else { return }
    let labelTime = timecodeSession.policy == .wallClock
      ? CMTimeAdd(outputPTS, timelineLock.withLock { timeline.offset(atOutput: outputPTS) })
      : outputPTS
    guard let value = timecodeSession.timecode(for: labelTime) else {
      throw SourceRecordingError.unsupportedSample("The source timestamp cannot be mapped to timecode.")
    }
    pendingTimecode.append(try timecodeTrack.sample(for: value, at: outputPTS))
  }

  // MARK: - Finish

  func finish() throws {
    let compressionSession = try encoderLock.withLock { () throws -> VTCompressionSession?? in
      guard started, !finished, !finishing else { return .none }
      finishing = true
      return .some(self.compressionSession)
    }
    guard let compressionSession else { return }
    // Every conversion has completed: appendVideo waits for its own, and runs
    // on the recorder queue that is now finishing.
    defer { releaseConverter() }
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
      let status = VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
      guard status == noErr else {
        encoderLock.withLock { finished = true; finishing = false }
        throw SourceRecordingError.writerFailure("VideoToolbox flush failed (OSStatus \(status)).")
      }
    }
    let closing = writerQueue.sync { () -> Result<AVAssetWriter?, SourceRecordingError> in
      drainForFinish()
      fifoLock.withLock { acceptingMedia = false }
      writerClosed = true
      let leftovers = fifoLock.withLock { () -> (video: Int, audio: Int) in
        let counts = (pendingVideo.count, pendingAudio.count)
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        bufferedBytes = 0
        return counts
      }
      pendingTimecode.removeAll()
      guard let writer else {
        if leftovers.audio > 0 {
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
    encoderLock.withLock { finished = true; finishing = false }
    guard let writer = try closing.get() else { return }
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    if writer.status == .failed {
      throw Self.writerError(writer, fallback: "AVAssetWriter finish failed.")
    }
    if let callbackError = telemetryLock.withLock({ self.terminalError }) {
      throw callbackError
    }
  }

  /// Writer-queue only. Waits for every queued sample, giving up only when
  /// the writer makes no progress at all for `finishStallTimeout`.
  private func drainForFinish() {
    var lastProgress = ProcessInfo.processInfo.systemUptime
    var lastWritten = writtenItems
    var delayMS = 1
    while true {
      let result = drainOnce()
      guard result == .blocked else { return }
      let now = ProcessInfo.processInfo.systemUptime
      if writtenItems != lastWritten {
        lastWritten = writtenItems
        lastProgress = now
        delayMS = 1
      } else if now - lastProgress > Self.finishStallTimeout {
        return
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

  private static func frameKey(_ pts: CMTime) -> Int64 {
    CMTimeConvertScale(pts, timescale: 60000, method: .default).value
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
