import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// AVAssetWriter/VideoToolbox implementation for one source feed. Source
/// pixel buffers are handed directly to VideoToolbox; this type does not lock,
/// copy, convert, or otherwise process image pixels.
final class AVAssetSourceRecordingWriter: SourceRecordingWriter {
  typealias EncodeFrame = (VTCompressionSession, CVImageBuffer, CMTime, CMTime) -> OSStatus
  private let configuration: SourceRecordingConfiguration
  private let encodeFrame: EncodeFrame
  private let inputReady: (AVAssetWriterInput) -> Bool
  private let appendSample: (CMSampleBuffer, AVAssetWriterInput) -> Bool
  private let lock = NSRecursiveLock()
  private var pendingFrameStarts: [Int64: UInt64] = [:]
  private static func frameKey(_ pts: CMTime) -> Int64 {
    CMTimeConvertScale(pts, timescale: 60000, method: .default).value
  }
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var timecodeInput: AVAssetWriterInput?
  private var timecodeTrack: QuickTimeTimecodeTrack?
  private var timecodeSession: RecordingTimecodeSession?
  private var compressionSession: VTCompressionSession?
  private var telemetryValue = SourceRecordingWriterTelemetry()
  private var started = false
  private var sessionStarted = false
  private var finishing = false
  private var finished = false
  // VideoToolbox delivers encoded samples asynchronously. Preserve a fatal
  // callback/append error until `finish()` so the owning recorder cannot
  // publish a partial movie after the synchronous `appendVideo` call already
  // returned successfully.
  private var terminalError: SourceRecordingError?
  private var lastVideoPTS: CMTime?
  private var lastAudioPTS: CMTime?
  private var pendingAudio: [CMSampleBuffer] = []
  private static let pendingAudioCapacity = 64
  private var adoptedFrameRate: RecordingFrameRate?
  private var adoptedSourceStart: CMTime?

  init(configuration: SourceRecordingConfiguration,
    encodeFrame: @escaping EncodeFrame = { session, image, pts, duration in
      var flags = VTEncodeInfoFlags()
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image,
        presentationTimeStamp: pts, duration: duration, frameProperties: nil,
        sourceFrameRefcon: nil, infoFlagsOut: &flags)
    }, inputReady: @escaping (AVAssetWriterInput) -> Bool = AVAssetSourceRecordingWriter.inputIsReady,
    appendSample: @escaping (CMSampleBuffer, AVAssetWriterInput) -> Bool = AVAssetSourceRecordingWriter.append) throws {
    self.configuration = configuration
    self.encodeFrame = encodeFrame
    self.inputReady = inputReady
    self.appendSample = appendSample
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

  /// Wall-clock recordings that ask for computer-clock alignment take `now`
  /// at the first encoded frame. Every other configuration keeps the date
  /// the caller supplied, including an explicit wall-clock anchor.
  static func timecodeAnchorDate(for configuration: SourceRecordingConfiguration, now: Date = Date()) -> Date {
    guard configuration.timecodeSamplesComputerClockAtFirstFrame,
      configuration.timecodePolicy == .wallClock else {
      return configuration.timecodeStartDate
    }
    return now
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
    let result = lock.withLock { () -> SourceRecordingWriterTelemetry in
      var result = telemetryValue
      result.encoderPendingFrames = pendingFrameStarts.count
      result.failed = terminalError != nil
      return result
    }
    return result
  }

  deinit {
    if let compressionSession {
      VTCompressionSessionInvalidate(compressionSession)
    }
  }

  /// Admission starts the writer lazily. A pass-through AVAssetWriter input
  /// needs a compressed format hint, which is available only after the first
  /// VideoToolbox callback; delaying file initialization preserves that hint
  /// and avoids a format-conversion path.
  func start() throws {
    try lock.withLock {
      guard !started else { throw SourceRecordingError.invalidState(.recording, operation: "start writer") }
      started = true
    }
  }

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
    guard pts.isNumeric else {
      throw SourceRecordingError.unsupportedSample("A video sample has no numeric presentation time.")
    }
    let session = try lock.withLock { () -> VTCompressionSession in
      try ensureCanAppend()
      if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS) < 0 {
        throw SourceRecordingError.unsupportedSample("Video timestamps moved backwards.")
      }
      try ensureCompressionSession(for: imageBuffer)
      guard let compressionSession else {
        throw SourceRecordingError.writerFailure("VideoToolbox compression session is unavailable.")
      }
      lastVideoPTS = pts
      if pendingFrameStarts.count >= 256, let oldest = pendingFrameStarts.min(by: { $0.value < $1.value })?.key {
        pendingFrameStarts.removeValue(forKey: oldest)
      }
      pendingFrameStarts[Self.frameKey(pts)] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      return compressionSession
    }
    // Submission can wait for an output callback on another thread (notably
    // remote ProRes encoders). That callback takes `lock`; holding it across
    // EncodeFrame deadlocks both workers and every stop queued behind them.
    // SourceRecorderCore serializes submission and finish on its writer queue.
    let status = encodeFrame(session, imageBuffer, pts, CMSampleBufferGetDuration(sample))
    guard status == noErr else {
      _ = lock.withLock { pendingFrameStarts.removeValue(forKey: Self.frameKey(pts)) }
      throw SourceRecordingError.writerFailure("VideoToolbox encode failed (OSStatus \(status)).")
    }
  }

  func appendAudio(_ sample: CMSampleBuffer) throws {
    guard Self.hasValidTiming(sample) else {
      throw SourceRecordingError.unsupportedSample(
        "An audio sample must have a non-negative epoch-zero PTS and positive duration.")
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    try lock.withLock {
      try ensureCanAppend()
      if let lastAudioPTS, CMTimeCompare(pts, lastAudioPTS) < 0 {
        throw SourceRecordingError.writerNotReady("The late audio sample was rejected because its timestamp moved backwards.")
      }
      // Keep early and later audio in one ordered queue. A temporarily blocked
      // input must never let newer audio overtake the early packets.
      guard pendingAudio.count < Self.pendingAudioCapacity else {
        throw SourceRecordingError.writerNotReady("The pending audio queue is full.")
      }
      pendingAudio.append(sample)
      pendingAudio.sort {
        CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0),
          CMSampleBufferGetPresentationTimeStamp($1)) < 0
      }
      if audioInput != nil {
        try ensureSession(at: CMSampleBufferGetPresentationTimeStamp(pendingAudio[0]))
        try appendPendingAudio()
      }
    }
  }

  func finish() throws {
    let compressionSession = lock.withLock { () -> VTCompressionSession? in
      guard started, !finished else { return nil }
      guard !finishing else { return nil }
      finishing = true
      return self.compressionSession
    }
    // CompleteFrames synchronously invokes the VideoToolbox callback. Never
    // hold `lock` here: the callback needs the same lock to append its final
    // compressed sample, otherwise stop deadlocks indefinitely on HEVC.
    if let compressionSession {
      let status = VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
      guard status == noErr else {
        lock.withLock { finished = true; finishing = false }
        throw SourceRecordingError.writerFailure("VideoToolbox flush failed (OSStatus \(status)).")
      }
    }
    try drainPendingAudio()
    let writer = try lock.withLock { () -> AVAssetWriter? in
      guard let writer else {
        finished = true
        finishing = false
        if !pendingAudio.isEmpty {
          throw SourceRecordingError.writerFailure(
            "Recording stopped before video established the file.")
        }
        return nil
      }
      if !pendingAudio.isEmpty {
        pendingAudio.removeAll()
        let message = "Audio was still queued when recording stopped."
        telemetryValue.lastError = message
        if terminalError == nil { terminalError = .writerFailure(message) }
      }
      videoInput?.markAsFinished()
      audioInput?.markAsFinished()
      timecodeInput?.markAsFinished()
      finished = true
      finishing = false
      return writer
    }
    guard let writer else { return }
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    if writer.status == .failed {
      throw Self.writerError(writer, fallback: "AVAssetWriter finish failed.")
    }
    if let callbackError = lock.withLock({ self.terminalError }) {
      throw callbackError
    }
  }

  private func ensureCanAppend() throws {
    guard started else { throw SourceRecordingError.invalidState(.idle, operation: "append sample") }
    guard !finished, !finishing else { throw SourceRecordingError.invalidState(.stopping, operation: "append sample") }
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

  private func ensureWriter(videoFormat: CMFormatDescription) throws {
    guard writer == nil else { return }
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
      let origin = configuredOrigin == .zero ? (adoptedSourceStart ?? configuredOrigin) : configuredOrigin
      self.timecodeSession = RecordingTimecodeSession(
        frameRate: rate,
        dropFrame: configuration.timecodeDropFrame,
        policy: configuration.timecodePolicy,
        startDate: Self.timecodeAnchorDate(for: configuration),
        sourceStartTime: origin)
    }
  }

  private func ensureCompressionSession(for imageBuffer: CVImageBuffer) throws {
    guard compressionSession == nil else { return }
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    guard width == configuration.width, height == configuration.height else {
      throw SourceRecordingError.unsupportedSample(
        "Video dimensions \(width) × \(height) do not match the configured source \(configuration.width) × \(configuration.height).")
    }
    var session: VTCompressionSession?
    let encoderSpecification = configuration.videoProfile.encoderSpecification
    let imageBufferAttributes: CFDictionary = [
      kCVPixelBufferPixelFormatTypeKey: configuration.videoProfile.sourcePixelFormat,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
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
    if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
      allocator: nil, valueOut: &hardware) == noErr {
      telemetryValue.hardwareEncoder = (hardware?.takeRetainedValue() as? NSNumber)?.boolValue
    }
    var encoderID: Unmanaged<CFTypeRef>?
    if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
      allocator: nil, valueOut: &encoderID) == noErr {
      telemetryValue.encoderID = encoderID?.takeRetainedValue() as? String
    }
    compressionSession = session
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

  fileprivate func recordEncoderFailure(status: OSStatus) {
    lock.withLock {
      pendingFrameStarts.removeAll(keepingCapacity: true)
      telemetryValue.droppedEncodedVideo &+= 1
      telemetryValue.encoderErrors &+= 1
      let message = status == noErr
        ? "VideoToolbox returned no encoded sample."
        : "VideoToolbox callback failed (OSStatus \(status))."
      telemetryValue.lastError = message
      terminalError = .writerFailure(message)
    }
  }

  func appendEncodedVideo(_ sample: CMSampleBuffer) {
    lock.withLock {
      do {
        guard !finished else {
          telemetryValue.droppedEncodedVideo &+= 1
          return
        }
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
          throw SourceRecordingError.unsupportedSample("VideoToolbox returned a sample without a format description.")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if let submitted = pendingFrameStarts.removeValue(forKey: Self.frameKey(pts)) {
          let latency = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - submitted) / 1_000_000
          telemetryValue.encoderLatencyMS = telemetryValue.encoderLatencyMS.map { $0 * 0.9 + latency * 0.1 } ?? latency
          telemetryValue.maxEncoderLatencyMS = max(telemetryValue.maxEncoderLatencyMS ?? 0, latency)
        }
        if adoptedFrameRate == nil {
          adoptedFrameRate = Self.matchingFrameRate(CMSampleBufferGetDuration(sample))
        }
        if adoptedSourceStart == nil {
          adoptedSourceStart = pts
        }
        try ensureWriter(videoFormat: format)
        guard let videoInput else { throw SourceRecordingError.writerFailure("Video writer input is unavailable.") }
        // Audio is intentionally allowed to arrive before the first encoded
        // video frame while VideoToolbox establishes its format hint. Start
        // the AVAssetWriter session at the earliest admitted media timestamp;
        // starting at the video PTS would make a valid leading audio packet
        // appear to precede the writer session and be rejected.
        let sessionTime = pendingAudio.first.map { audio in
          let audioPTS = CMSampleBufferGetPresentationTimeStamp(audio)
          return CMTimeCompare(audioPTS, pts) < 0 ? audioPTS : pts
        } ?? pts
        try ensureSession(at: sessionTime)
        guard inputReady(videoInput) else {
          telemetryValue.droppedEncodedVideo &+= 1
          telemetryValue.encoderErrors &+= 1
          telemetryValue.lastError = SourceRecordingError.writerNotReady("Video writer input is not ready.").localizedDescription
          return
        }
        guard appendSample(sample, videoInput) else {
          throw Self.writerError(writer, fallback: "Video sample append failed.")
        }
        telemetryValue.encodedVideo &+= 1
        telemetryValue.encodedVideoBytes &+= UInt64(CMSampleBufferGetTotalSampleSize(sample))
        try appendTimecode(for: pts)
        try appendPendingAudio()
      } catch {
        telemetryValue.droppedEncodedVideo &+= 1
        telemetryValue.encoderErrors &+= 1
        telemetryValue.lastError = error.localizedDescription
        // A writer-not-ready result is a bounded backpressure drop and may
        // recover on a later callback. Other failures invalidate the movie's
        // media contract and must be surfaced during finalization.
        if let sourceError = error as? SourceRecordingError,
          case .writerNotReady = sourceError {
          // Keep recording; telemetry already records the dropped frame.
        } else {
          terminalError = (error as? SourceRecordingError)
            ?? .writerFailure(error.localizedDescription)
        }
      }
    }
  }

  /// Writes audio that arrived before the first encoded video frame. Stop must
  /// not abandon a movie that already has video when the input is briefly not
  /// ready; `finish()` still closes the file if a tail remains after the wait.
  private func drainPendingAudio() throws {
    let deadline = Date().addingTimeInterval(2)
    while true {
      let idle = try lock.withLock { () -> Bool in
        try appendPendingAudio()
        return pendingAudio.isEmpty || audioInput == nil
      }
      if idle || Date() >= deadline { return }
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  /// Called under `lock`; all audio paths share this FIFO and written PTS.
  private func appendPendingAudio() throws {
    guard let audioInput else { return }
    while let sample = pendingAudio.first {
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      if let lastAudioPTS, CMTimeCompare(pts, lastAudioPTS) < 0 {
        pendingAudio.removeFirst()
        telemetryValue.droppedAudio &+= 1
        continue
      }
      guard inputReady(audioInput) else { return }
      guard appendSample(sample, audioInput) else {
        throw Self.writerError(writer, fallback: "Pending audio sample append failed.")
      }
      lastAudioPTS = pts
      pendingAudio.removeFirst()
    }
  }

  private func appendTimecode(for sourcePTS: CMTime) throws {
    guard let timecodeInput, let timecodeTrack, let timecodeSession else { return }
    guard inputReady(timecodeInput) else {
      telemetryValue.droppedTimecode &+= 1
      telemetryValue.lastError = SourceRecordingError.writerNotReady("Timecode writer input is not ready.").localizedDescription
      return
    }
    guard let value = timecodeSession.timecode(for: sourcePTS) else {
      throw SourceRecordingError.unsupportedSample("The source timestamp cannot be mapped to timecode.")
    }
    let sample = try timecodeTrack.sample(for: value, at: sourcePTS)
    guard appendSample(sample, timecodeInput) else {
      throw Self.writerError(writer, fallback: "Timecode sample append failed.")
    }
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
