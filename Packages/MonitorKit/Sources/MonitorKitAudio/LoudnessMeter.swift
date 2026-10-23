import CoreAudioTypes
import Synchronization

/// ITU-R BS.1770-4 / EBU R 128 loudness meter: momentary (400 ms), short-term
/// (3 s), gated integrated loudness and EBU Tech 3342 loudness range.
///
/// Realtime-safe: everything is allocated at init. Call `process` from one
/// thread at a time (the audio thread); `snapshot()` and the reset requests
/// work from any thread. `AudioMeter` embeds the same engine, so use this
/// type when only loudness is wanted.
public final class LoudnessMeter: @unchecked Sendable {
  // @unchecked: the producer state is confined to the `process` caller; the
  // only state shared with readers is the atomic publisher, reset requests
  // and pause flag.
  public let sampleRate: Double
  public let channels: [LoudnessChannel]
  private let stage: PlanarStage
  private let engine: LoudnessEngine
  private let publisher: SnapshotPublisher<Published<LoudnessSnapshot>>
  private let staging: UnsafeMutablePointer<Published<LoudnessSnapshot>>
  private let requests = ResetRequests()
  private let paused = Atomic<Bool>(false)

  static let chunkFrames = 512

  /// `channels` gives each input channel's role, in input order.
  public init(sampleRate: Double, channels: [LoudnessChannel]) throws(AudioMeterError) {
    try validateFormat(sampleRate: sampleRate, channelCount: channels.count)
    try validateLoudnessChannels(channels, channelCount: channels.count)
    self.sampleRate = sampleRate
    self.channels = channels
    stage = PlanarStage(channelCount: channels.count, history: 0, capacity: Self.chunkFrames)
    engine = LoudnessEngine(sampleRate: sampleRate, weights: channels.map(\.weight), stage: stage)
    publisher = SnapshotPublisher(Published(readings: LoudnessSnapshot()))
    staging = .allocate(capacity: 1)
    staging.initialize(to: Published(readings: LoudnessSnapshot()))
  }

  /// The standard layout for the channel count (see `LoudnessChannel.standardLayout`).
  public convenience init(sampleRate: Double, channelCount: Int) throws(AudioMeterError) {
    try self.init(sampleRate: sampleRate, channels: LoudnessChannel.standardLayout(channelCount: channelCount))
  }

  deinit {
    stage.deallocate()
    staging.deallocate()
  }

  public var channelCount: Int { stage.channelCount }

  // MARK: Input

  /// Deinterleaved Float32, e.g. `AVAudioPCMBuffer.floatChannelData`.
  public func process(planar channels: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
    forEachIndex(stage.channelCount) { stage.bindPlanar($0, channels[$0]) }
    run(frameCount, .float32)
  }

  public func process(planar channels: UnsafePointer<UnsafePointer<Float>>, frameCount: Int) {
    forEachIndex(stage.channelCount) { stage.bindPlanar($0, channels[$0]) }
    run(frameCount, .float32)
  }

  public func process(planar channels: UnsafePointer<UnsafeMutablePointer<Int16>>, frameCount: Int) {
    forEachIndex(stage.channelCount) { stage.bindPlanar($0, channels[$0]) }
    run(frameCount, .int16)
  }

  public func process(planar channels: UnsafePointer<UnsafeMutablePointer<Int32>>, frameCount: Int) {
    forEachIndex(stage.channelCount) { stage.bindPlanar($0, channels[$0]) }
    run(frameCount, .int32)
  }

  /// Interleaved samples; `frameStride` (default: the channel count) is the
  /// number of samples per frame, so the first channels of a wider stream can be metered.
  public func process(interleaved samples: UnsafePointer<Float>, frameCount: Int, frameStride: Int? = nil) {
    stage.bindInterleaved(samples, format: .float32, frameStride: checkedStride(frameStride))
    run(frameCount, .float32)
  }

  public func process(interleaved samples: UnsafePointer<Int16>, frameCount: Int, frameStride: Int? = nil) {
    stage.bindInterleaved(samples, format: .int16, frameStride: checkedStride(frameStride))
    run(frameCount, .int16)
  }

  public func process(interleaved samples: UnsafePointer<Int32>, frameCount: Int, frameStride: Int? = nil) {
    stage.bindInterleaved(samples, format: .int32, frameStride: checkedStride(frameStride))
    run(frameCount, .int32)
  }

  /// Core Audio buffers, planar or interleaved; channels are taken in order
  /// and channels the list does not carry read as silence.
  public func process(bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, format: AudioSampleFormat) {
    stage.bindBufferList(bufferList, frameCount: frameCount, format: format)
    run(frameCount, format)
  }

  private func checkedStride(_ stride: Int?) -> Int {
    let s = stride ?? stage.channelCount
    precondition(s >= stage.channelCount, "frameStride is smaller than the channel count")
    return s
  }

  private func run(_ frameCount: Int, _ format: AudioSampleFormat) {
    precondition(frameCount >= 0, "negative frameCount")
    let reset = applyResetRequests()
    engine.setMeasuring(!paused.load(ordering: .relaxed))
    guard frameCount > 0 || reset else { return }
    var offset = 0
    while offset < frameCount {
      let n = min(frameCount - offset, Self.chunkFrames)
      stage.load(offset: offset, frames: n, format: format)
      engine.process(frames: n)
      offset += n
    }
    staging.pointee.readings = engine.state.pointee.readings
    publisher.publish(&staging.pointee)
  }

  /// True when a reading reset was applied; the generations go out with the next publish.
  private func applyResetRequests() -> Bool {
    let requested = requests.load()
    let applied = staging.pointee.resets
    guard requested != applied else { return false }
    staging.pointee.resets = requested
    let resets = requested.resetsReadings(since: applied)
    if requested.all != applied.all {
      engine.resetFilters()
      engine.resetReadings()
    } else if requested.loudness != applied.loudness {
      engine.resetMeasurement()
    }
    // After a full reset's zeroing: the audio after the break starts the filters.
    if requested.discontinuities != applied.discontinuities { engine.primeFilters() }
    return resets
  }

  // MARK: Output and control

  /// The latest readings. Lock-free; safe from any thread. A reset already
  /// shows here from the moment it is requested, before `process` applies it
  /// (audio stopped, say, or a call in progress).
  public func snapshot() -> LoudnessSnapshot {
    var value = Published(readings: LoudnessSnapshot())
    publisher.read(into: &value)
    let requested = requests.load()
    if requested.all != value.resets.all { return LoudnessSnapshot() }
    if requested.loudness != value.resets.loudness { return value.readings.startingNewMeasurement }
    return value.readings
  }

  /// Advances on every publish and every reset request, so a display can
  /// skip redrawing while it is unchanged.
  public var publishCount: UInt64 {
    publisher.publishCount &+ requests.load().total
  }

  /// Starts a new programme measurement: integrated, LRA, the maxima and
  /// `duration` start over from the next 5 or 10 ms tick boundary, while
  /// momentary and short-term slide on over the continuous audio (EBU Tech
  /// 3341 resets the measurement; M and S are sliding windows).
  public func resetMeasurement() { requests.requestLoudness() }

  /// Clears every reading, momentary and short-term included, and the
  /// K-weighting's signal memory, as if the meter were new (for a new
  /// source; `resetMeasurement()` is the one for a new programme).
  public func reset() { requests.requestAll() }

  /// The audio the next `process` call brings does not follow the last call's
  /// (a dropped, skipped or rejected packet, a source switch without a reset):
  /// the K-weighting starts from that call's first sample, as if the signal had
  /// held it, instead of filtering on from the stale memory, which would put a
  /// step and its decay into momentary loudness. Every reading carries on. Any
  /// thread; applied by the next `process` call that brings audio.
  public func noteDiscontinuity() { requests.requestDiscontinuity() }

  /// Puts integrated loudness, loudness range and `duration` on stand-by
  /// (EBU Tech 3341 section 2.2): audio from now on is left out of them as if
  /// it were cut, while momentary, short-term and their maxima keep running.
  /// Any thread; takes effect at the first 5 or 10 ms tick boundary the
  /// next `process` call reaches. A reset keeps the meter paused, so reset
  /// then resume starts a measurement.
  public func pauseMeasurement() { paused.store(true, ordering: .relaxed) }

  /// Continues a paused measurement from where it stood.
  public func resumeMeasurement() { paused.store(false, ordering: .relaxed) }

  /// True between `pauseMeasurement()` and `resumeMeasurement()`.
  public var isMeasurementPaused: Bool { paused.load(ordering: .relaxed) }
}
