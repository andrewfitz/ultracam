import CoreMedia
import CoreVideo
import Foundation
import os

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
  /// The head of the first packet that overlapped placed audio: what that
  /// audio would have continued with. Under `clockLock`.
  private var continuation: [Int32]?
  private static let log = Logger(subsystem: "org.ultracam.app", category: "recording")

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
        return self.appendDeckLinkAudio(sourcePCM32, sampleFrameCount: sampleFrameCount,
          packetTime: presentationTime, channelCount: channelCount)
      })
  }

  /// Places one DeckLink packet on the video clock (see
  /// ``EmbeddedAudioClockAnchor``) and queues it. The ordinary packet costs
  /// one short lock; silence, trimming and the crossfade happen only around
  /// a clock jump, and every one is logged and counted on the take.
  private func appendDeckLinkAudio(_ sourcePCM32: Data, sampleFrameCount: Int, packetTime: CMTime,
    channelCount: Int) -> Bool {
    let (placement, continuation) = clockLock.withLock { () -> (EmbeddedAudioPlacement, [Int32]?) in
      let placement = audioClock.place(packetTime, sampleFrameCount: sampleFrameCount)
      if placement.keepsContinuation {
        self.continuation = Self.head(of: sourcePCM32, frames: EmbeddedAudioClockAnchor.crossfadeFrames,
          channelCount: channelCount)
      }
      guard placement.crossfades else { return (placement, nil) }
      defer { self.continuation = nil }
      return (placement, self.continuation)
    }
    let ordinary = placement.trimmedFrames == 0 && placement.silenceFrames == 0 &&
      placement.reanchorShift == nil && placement.drift == nil && !placement.crossfades
    guard ordinary else {
      return appendResyncedAudio(sourcePCM32, placement: placement, continuation: continuation,
        channelCount: channelCount)
    }
    return appendEmbeddedAudio(sourcePCM32: sourcePCM32, sampleFrameCount: sampleFrameCount,
      presentationTime: placement.start, channelCount: channelCount)
  }

  private func appendResyncedAudio(_ sourcePCM32: Data, placement: EmbeddedAudioPlacement,
    continuation: [Int32]?, channelCount: Int) -> Bool {
    let feed = feedID.rawValue
    let at = String(format: "%.3f", placement.takeTime)
    if let shift = placement.reanchorShift {
      let ms = String(format: "%.1f", Double(abs(shift)) / 48)
      let way = shift < 0 ? "earlier" : "later"
      if placement.backward {
        Self.log.error("\(feed, privacy: .public): audio re-synced backward: re-anchored \(ms, privacy: .public) ms \(way, privacy: .public) at \(at, privacy: .public) s of the take, into audio already recorded; its overlap is left out")
      } else {
        Self.log.notice("\(feed, privacy: .public): audio re-anchored \(ms, privacy: .public) ms \(way, privacy: .public) at \(at, privacy: .public) s of the take")
      }
    }
    if placement.trimmedFrames > 0 {
      Self.log.notice("\(feed, privacy: .public): left out \(placement.trimmedFrames) audio frames already covered at \(at, privacy: .public) s of the take")
    }
    if let drift = placement.drift {
      Self.log.fault("\(feed, privacy: .public): audio placed \(drift) samples from its frame at \(at, privacy: .public) s of the take, beyond the re-anchor")
    }
    if placement.silenceFrames > 0 {
      Self.log.notice("\(feed, privacy: .public): filled a \(placement.silenceFrames)-frame audio hole with silence at \(at, privacy: .public) s of the take")
    }
    recorder.noteAudioResync(reanchored: placement.reanchorShift != nil, backward: placement.backward,
      trimmedFrames: placement.trimmedFrames, silenceFrames: placement.silenceFrames)
    var silenceStart = placement.silenceStart.value
    var silenceLeft = placement.silenceFrames
    while silenceLeft > 0 {
      let frames = min(silenceLeft, 48_000)
      guard let silence = try? EmbeddedAudioRecording.makeSilenceSampleBuffer(sampleFrameCount: frames,
        presentationTime: CMTime(value: silenceStart, timescale: EmbeddedAudioFormat.sampleRateTimescale)) else {
        return reject(video: false)
      }
      _ = recorder.appendAudio(silence)
      silenceStart += Int64(frames)
      silenceLeft -= frames
    }
    guard placement.keptFrames > 0 else { return true }
    let sample: CMSampleBuffer
    do {
      sample = try continuation.withUnsafeBufferPointerIfPresent { fade in
        try EmbeddedAudioRecording.makeSampleBuffer(sourcePCM32: sourcePCM32,
          skippingFrames: placement.trimmedFrames, sampleFrameCount: placement.keptFrames,
          presentationTime: placement.start, channelCount: channelCount, crossfadingFrom: fade)
      }
    } catch {
      return reject(video: false)
    }
    return recorder.appendAudio(sample)
  }

  /// The first `frames` sample frames of a packet, or fewer if it is shorter.
  private static func head(of sourcePCM32: Data, frames: Int, channelCount: Int) -> [Int32] {
    let available = sourcePCM32.count / EmbeddedAudioFormat.sourceBytesPerSample
    let count = min(available - available % max(1, channelCount), frames * channelCount)
    guard count > 0 else { return [] }
    return sourcePCM32.withUnsafeBytes { bytes in
      (0..<count).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self) }
    }
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

/// Where one DeckLink audio packet goes on the video clock.
struct EmbeddedAudioPlacement: Equatable {
  /// Video-clock start of the packet's first kept sample frame.
  var start: CMTime
  /// Leading frames left out: their instants are already covered by audio
  /// placed before. Only ever an overlap; nothing else is discarded.
  var trimmedFrames = 0
  /// Frames recorded from this packet (zero when all of it overlaps).
  var keptFrames: Int
  /// Silence placed first, from the end of the audio already placed up to
  /// `start`. The movie's LPCM track has no gaps (AVAssetWriter writes its
  /// samples back to back whatever their timestamps), so a hole must be
  /// filled for the audio after it to stay on its frames.
  var silenceFrames = 0
  /// This packet's head continues the audio already placed (the first
  /// packet that overlaps it): keep it for the crossfade.
  var keepsContinuation = false
  /// Crossfade the kept head from the kept continuation.
  var crossfades = false
  /// Samples the audio moved on the video clock at a re-anchor, against
  /// where the previous anchor would have put it: positive later, negative
  /// earlier. Nil when the anchor held.
  var reanchorShift: Int64?
  /// The re-anchor put the audio more than half a frame inside audio
  /// already placed: a backward re-sync, whose overlap is left out.
  var backward = false
  /// Paired audio that lands more than a frame from its frame's video time,
  /// in samples (audio minus video). Nil when within a frame.
  var drift: Int64?
  /// Seconds of video clock since the take's first frame.
  var takeTime: Double = 0

  var silenceStart: CMTime {
    CMTime(value: start.value - Int64(trimmedFrames) - Int64(silenceFrames),
      timescale: EmbeddedAudioFormat.sampleRateTimescale)
  }
}

/// Moves DeckLink audio packet times onto the video stream clock of the same
/// input. A packet that follows a frame from the same input callback is that
/// frame's audio, so each such pair measures the offset between the clocks.
/// The first pair sets it; a later pair moves it only when it disagrees by
/// more than half a frame (the device re-based a clock, for example across an
/// HDMI re-lock). Ordinary pairs agree to a sample: a 59.94 frame is 800.8
/// samples and its packets carry 800 or 801.
///
/// The placed audio stays one gapless run, as the movie's LPCM track is:
/// - a packet that starts past the audio already placed has the hole before
///   it filled with silence of exactly its length;
/// - a packet that starts inside it (the audio delivered more than the video
///   clock advanced, then re-anchored earlier) has only its overlapping
///   frames left out, and its first kept frames are crossfaded in from the
///   natural continuation of the placed audio, so there is no click.
struct EmbeddedAudioClockAnchor {
  /// The crossfade at a backward re-sync: 3 ms.
  static let crossfadeFrames = 144
  /// The longest hole filled with silence: a minute. Longer holes are left
  /// for the writer (and logged); no input takes that long to re-lock.
  static let maximumSilenceFrames = 60 * 48_000

  /// The latest frame not yet paired with a packet, in 48 kHz samples.
  private var pendingVideo: (start: Int64, duration: Int64)?
  /// The take's first frame, in 48 kHz samples.
  private var firstVideoStart: Int64?
  /// Samples subtracted from a packet time; nil before the first packet.
  private(set) var offset: Int64?
  /// Where a packet contiguous with the last one placed starts.
  private(set) var nextStart: Int64?
  /// An overlap began and its kept audio has not started yet.
  private var crossfadePending = false

  mutating func noteVideo(_ time: CMTime, duration: CMTime) {
    guard time.isNumeric, time.epoch == 0, duration.isNumeric, duration.value > 0 else { return }
    let start = Self.samples(time)
    pendingVideo = (start, max(1, Self.samples(duration)))
    if firstVideoStart == nil { firstVideoStart = start }
  }

  /// Places one packet. A packet time this contract cannot read is passed
  /// through whole for the recorder to reject.
  mutating func place(_ packetTime: CMTime, sampleFrameCount: Int) -> EmbeddedAudioPlacement {
    guard packetTime.isNumeric, packetTime.epoch == 0,
      packetTime.timescale == EmbeddedAudioFormat.sampleRateTimescale, sampleFrameCount > 0 else {
      return EmbeddedAudioPlacement(start: packetTime, keptFrames: sampleFrameCount)
    }
    let raw = packetTime.value
    let count = Int64(sampleFrameCount)
    var reanchorShift: Int64?
    var drift: Int64?
    var natural: Int64
    var frameDuration: Int64?
    if let video = pendingVideo {
      pendingVideo = nil
      frameDuration = video.duration
      let measured = raw - video.start
      if let current = offset, abs(measured - current) * 2 > video.duration {
        reanchorShift = current - measured
        offset = measured
      } else if offset == nil {
        offset = measured
      }
      natural = raw - (offset ?? measured)
      // Sanity: whatever the anchor did, paired audio sits on its frame.
      if abs(natural - video.start) > video.duration { drift = natural - video.start }
    } else {
      // Audio ahead of any frame keeps its own clock.
      if offset == nil { offset = 0 }
      natural = raw - (offset ?? 0)
    }
    var placement = EmbeddedAudioPlacement(
      start: CMTime(value: natural, timescale: EmbeddedAudioFormat.sampleRateTimescale),
      keptFrames: sampleFrameCount, reanchorShift: reanchorShift, drift: drift,
      takeTime: Double(natural - (firstVideoStart ?? natural)) / EmbeddedAudioFormat.sampleRate)
    if let next = nextStart {
      if natural < next {
        let trimmed = min(count, next - natural)
        placement.trimmedFrames = Int(trimmed)
        placement.keptFrames = sampleFrameCount - Int(trimmed)
        placement.start = CMTime(value: natural + trimmed, timescale: EmbeddedAudioFormat.sampleRateTimescale)
        if !crossfadePending {
          crossfadePending = true
          placement.keepsContinuation = true
        }
        if reanchorShift != nil, (next - natural) * 2 > (frameDuration ?? 0) { placement.backward = true }
      } else if natural > next, natural - next <= Int64(Self.maximumSilenceFrames) {
        placement.silenceFrames = Int(natural - next)
      }
    }
    if crossfadePending, placement.keptFrames > 0 {
      crossfadePending = false
      placement.crossfades = true
    }
    nextStart = max(nextStart ?? natural + count, natural + count)
    return placement
  }

  private static func samples(_ time: CMTime) -> Int64 {
    CMTimeConvertScale(time, timescale: EmbeddedAudioFormat.sampleRateTimescale,
      method: .roundHalfAwayFromZero).value
  }
}

private extension Optional where Wrapped == [Int32] {
  func withUnsafeBufferPointerIfPresent<Result>(
    _ body: (UnsafeBufferPointer<Int32>?) throws -> Result) rethrows -> Result {
    guard let array = self else { return try body(nil) }
    return try array.withUnsafeBufferPointer { try body($0) }
  }
}
