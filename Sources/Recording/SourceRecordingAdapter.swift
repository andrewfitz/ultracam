import CoreMedia
import CoreVideo
import Foundation

/// Bridges the Blackmagic capture callback boundary to one source recorder.
///
/// The adapter deliberately has no image-processing policy. A callback's
/// `CVPixelBuffer` is retained by the resulting sample buffer and handed to
/// `SourceRecorderCore` without locking, copying, scaling, LUT application, or
/// pixel-format conversion. Audio sample buffers are forwarded unchanged. A
/// caller that receives a raw embedded packet can use the packet overload;
/// packet conversion is kept in `EmbeddedAudioRecording` where its format
/// contract is defined.
final class SourceRecordingCallbackAdapter: @unchecked Sendable {
  let feedID: SourceRecordingFeedID
  private let recorder: SourceRecorderCore
  /// The capture format is fixed for a take, so one description serves every
  /// frame; it is rebuilt only when the buffer stops matching it (size,
  /// format or color tags changed).
  private let formatLock = RecordingLock()
  private var cachedFormat: CMVideoFormatDescription?
  /// Puts the DeckLink audio packet clock on the video stream clock; see
  /// ``callbacks``.
  private let clockLock = RecordingLock()
  private var audioClock = EmbeddedAudioClockAnchor()

  init(feedID: SourceRecordingFeedID, recorder: SourceRecorderCore) {
    self.feedID = feedID
    self.recorder = recorder
  }

  init(configuration: SourceRecordingConfiguration,
    writerFactory: @escaping SourceRecorderCore.WriterFactory) throws {
    feedID = configuration.feedID
    recorder = try SourceRecorderCore(configuration: configuration,
      writerFactory: writerFactory)
  }

  convenience init(configuration: SourceRecordingConfiguration) throws {
    try self.init(feedID: configuration.feedID,
      recorder: SourceRecorderCore(configuration: configuration))
  }

  var state: SourceRecordingState { recorder.state }
  var telemetry: SourceRecordingTelemetry { recorder.telemetry }

  func start() throws { try recorder.start() }
  func pause() throws { try recorder.pause() }
  func resume() throws { try recorder.resume() }
  func stop() throws { try recorder.stop() }

  /// Appends the sample supplied by an upstream source callback without
  /// replacing its image buffer, format description, timing, or attachments.
  @discardableResult
  func appendRawVideo(sample: CMSampleBuffer) -> Bool {
    guard Self.hasValidTiming(sample) else { return reject() }
    return recorder.appendVideo(sample)
  }

  /// Convenience spelling for callback code that already owns a sample.
  @discardableResult
  func appendRawVideo(_ sample: CMSampleBuffer) -> Bool {
    appendRawVideo(sample: sample)
  }

  /// Wraps the original Blackmagic pixel buffer in a timed sample. Core Media
  /// retains the original buffer; no image bytes are read or transformed.
  /// `signalValid` mirrors the backend callback and rejects no-signal frames.
  @discardableResult
  func appendRawVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
    duration: CMTime, signalValid: Bool = true) -> Bool {
    guard signalValid else { return reject() }
    guard presentationTime.isValid, presentationTime.isNumeric,
      presentationTime.epoch == 0, presentationTime.value >= 0,
      duration.isValid, duration.isNumeric, duration.epoch == 0,
      duration.value > 0 else { return reject() }
    guard let sample = makeSample(pixelBuffer: pixelBuffer,
      presentationTime: presentationTime, duration: duration) else {
      return reject()
    }
    return recorder.appendVideo(sample)
  }

  /// Accepts a Blackmagic frame callback using the unlabeled buffer spelling.
  @discardableResult
  func appendRawVideo(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
    duration: CMTime, signalValid: Bool = true) -> Bool {
    appendRawVideo(pixelBuffer: pixelBuffer, presentationTime: presentationTime,
      duration: duration, signalValid: signalValid)
  }

  /// Forwards an embedded audio CMSampleBuffer without changing bytes or
  /// timing. The recorder retains the sample until its callback queue drains.
  @discardableResult
  func appendEmbeddedAudio(sample: CMSampleBuffer) -> Bool {
    guard Self.hasValidTiming(sample) else { return reject(video: false) }
    return recorder.appendAudio(sample)
  }

  @discardableResult
  func appendEmbeddedAudio(_ sample: CMSampleBuffer) -> Bool {
    appendEmbeddedAudio(sample: sample)
  }

  /// Builds the Core Media sample for an embedded packet, then forwards it to
  /// the recorder. The packet overload is useful directly from a Blackmagic
  /// audio callback that has copied its bounded PCM payload.
  @discardableResult
  func appendEmbeddedAudio(packet: EmbeddedAudioPacket) -> Bool {
    guard let sample = try? EmbeddedAudioRecording.makeSampleBuffer(for: packet) else {
      return reject(video: false)
    }
    return recorder.appendAudio(sample)
  }

  @discardableResult
  func appendEmbeddedAudio(_ packet: EmbeddedAudioPacket) -> Bool {
    appendEmbeddedAudio(packet: packet)
  }

  /// Copies one bounded Blackmagic PCM payload into the embedded-audio packet
  /// contract and queues its exact source timestamp. Invalid packet metadata
  /// is rejected before anything reaches the writer.
  @discardableResult
  func appendEmbeddedAudio(sourcePCM32: Data, sampleFrameCount: Int,
    presentationTime: CMTime,
    channelCount: Int = EmbeddedAudioFormat.channelCount) -> Bool {
    guard let sample = try? EmbeddedAudioRecording.makeSampleBuffer(sourcePCM32: sourcePCM32,
      sampleFrameCount: sampleFrameCount, presentationTime: presentationTime,
      channelCount: channelCount) else { return reject(video: false) }
    return recorder.appendAudio(sample)
  }

  /// Returns the adapter's raw callback closures. They capture this adapter,
  /// preserving the per-feed routing while leaving callback callers free to
  /// pass them to a backend without any controller changes.
  ///
  /// The closures carry one DeckLink input callback each: its frame, then its
  /// audio packet, on one thread. The frame's stream time and the packet's
  /// packet time are separate device clocks whose origins can differ by a
  /// large, device-dependent amount (0.44 s and 0.88 s were measured on two
  /// UltraStudios opened together), so the raw packet time is moved onto the
  /// video clock: a packet that follows a frame is that frame's audio. Audio
  /// keeps its own sample-exact spacing; only its origin moves.
  var callbacks: Callbacks {
    Callbacks(
      video: { [weak self] pixelBuffer, presentationTime, duration, signalValid in
        guard let self else { return false }
        if signalValid {
          self.clockLock.withLock { self.audioClock.noteVideo(presentationTime, duration: duration) }
        }
        return self.appendRawVideo(pixelBuffer: pixelBuffer, presentationTime: presentationTime,
          duration: duration, signalValid: signalValid)
      },
      audio: { [weak self] sample in self?.appendEmbeddedAudio(sample: sample) ?? false },
      rawAudio: { [weak self] sourcePCM32, sampleFrameCount, presentationTime, channelCount, bytesPerSample in
        guard let self else { return false }
        guard bytesPerSample == EmbeddedAudioFormat.sourceBytesPerSample else {
          return self.reject(video: false)
        }
        let videoTime = self.clockLock.withLock {
          self.audioClock.place(presentationTime, sampleFrameCount: sampleFrameCount)
        }
        return self.appendEmbeddedAudio(sourcePCM32: sourcePCM32, sampleFrameCount: sampleFrameCount,
          presentationTime: videoTime, channelCount: channelCount)
      })
  }

  struct Callbacks: @unchecked Sendable {
    let video: @Sendable (CVPixelBuffer, CMTime, CMTime, Bool) -> Bool
    let audio: @Sendable (CMSampleBuffer) -> Bool
    let rawAudio: @Sendable (Data, Int, CMTime, Int, Int) -> Bool
  }

  private func makeSample(pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
    duration: CMTime) -> CMSampleBuffer? {
    guard let formatDescription = formatDescription(for: pixelBuffer) else { return nil }

    var timing = CMSampleTimingInfo(duration: duration,
      presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescription: formatDescription, sampleTiming: &timing,
      sampleBufferOut: &sample)
    guard status == noErr else { return nil }
    return sample
  }

  private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
    if let cached = formatLock.withLock({ cachedFormat }),
      CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer) {
      return cached
    }
    var created: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescriptionOut: &created) == noErr, let created else { return nil }
    formatLock.withLock { cachedFormat = created }
    return created
  }

  private static func hasValidTiming(_ sample: CMSampleBuffer) -> Bool {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
    let duration = CMSampleBufferGetDuration(sample)
    return presentationTime.isValid && presentationTime.isNumeric &&
      presentationTime.epoch == 0 && presentationTime.value >= 0 &&
      duration.isValid && duration.isNumeric && duration.epoch == 0 && duration.value > 0
  }

  private func reject(video: Bool = true) -> Bool {
    recorder.recordDrop(.invalidSample, video: video)
    return false
  }
}

/// Moves DeckLink audio packet times onto the video stream clock of the same
/// input. A packet that follows a frame from the same input callback is that
/// frame's audio, so each such pair measures the offset between the clocks.
/// The first pair sets it; a later pair moves it only when it disagrees by
/// more than half a frame (the device re-based a clock, for example across an
/// HDMI re-lock). Ordinary pairs agree to a sample: a 59.94 frame is 800.8
/// samples and its packets carry 800 or 801. Packets are never moved back
/// over audio already placed, so every sample is kept.
struct EmbeddedAudioClockAnchor {
  /// The latest frame not yet paired with a packet, in 48 kHz samples.
  private var pendingVideo: (start: Int64, duration: Int64)?
  /// Samples subtracted from a packet time; nil before the first packet.
  private(set) var offset: Int64?
  /// Where a packet contiguous with the last one placed starts.
  private var nextStart: Int64?

  mutating func noteVideo(_ time: CMTime, duration: CMTime) {
    guard time.isNumeric, time.epoch == 0, duration.isNumeric, duration.value > 0 else { return }
    pendingVideo = (Self.samples(time), max(1, Self.samples(duration)))
  }

  /// The packet's start on the video clock. A packet time this contract
  /// cannot read is returned unchanged for the recorder to reject.
  mutating func place(_ packetTime: CMTime, sampleFrameCount: Int) -> CMTime {
    guard packetTime.isNumeric, packetTime.epoch == 0,
      packetTime.timescale == EmbeddedAudioFormat.sampleRateTimescale, sampleFrameCount > 0 else {
      return packetTime
    }
    let raw = packetTime.value
    if let video = pendingVideo {
      pendingVideo = nil
      let measured = raw - video.start
      if offset.map({ abs(measured - $0) * 2 > video.duration }) ?? true {
        var anchored = measured
        if let nextStart, raw - anchored < nextStart { anchored = raw - nextStart }
        offset = anchored
      }
    }
    // Audio ahead of any frame keeps its own clock.
    let applied = offset ?? 0
    offset = applied
    let start = raw - applied
    nextStart = start + Int64(sampleFrameCount)
    return CMTime(value: start, timescale: EmbeddedAudioFormat.sampleRateTimescale)
  }

  private static func samples(_ time: CMTime) -> Int64 {
    CMTimeConvertScale(time, timescale: EmbeddedAudioFormat.sampleRateTimescale,
      method: .roundHalfAwayFromZero).value
  }
}
