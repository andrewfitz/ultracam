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
  // only state shared with readers is the atomic publisher and reset flags.
  public let sampleRate: Double
  public let channels: [LoudnessChannel]
  private let stage: PlanarStage
  private let engine: LoudnessEngine
  private let publisher: SnapshotPublisher<LoudnessSnapshot>
  private let staging: UnsafeMutablePointer<LoudnessSnapshot>
  private let resetRequest = Atomic<UInt32>(0)
  private let resetRequestCount = Atomic<UInt64>(0)

  static let chunkFrames = 512

  /// `channels` gives each input channel's role, in input order.
  public init(sampleRate: Double, channels: [LoudnessChannel]) throws(AudioMeterError) {
    try validateFormat(sampleRate: sampleRate, channelCount: channels.count)
    try validateLoudnessChannels(channels, channelCount: channels.count)
    self.sampleRate = sampleRate
    self.channels = channels
    stage = PlanarStage(channelCount: channels.count, history: 0, capacity: Self.chunkFrames)
    engine = LoudnessEngine(sampleRate: sampleRate, weights: channels.map(\.weight), stage: stage)
    publisher = SnapshotPublisher(LoudnessSnapshot())
    staging = .allocate(capacity: 1)
    staging.initialize(to: LoudnessSnapshot())
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
    guard frameCount > 0 || reset else { return }
    var offset = 0
    while offset < frameCount {
      let n = min(frameCount - offset, Self.chunkFrames)
      stage.load(offset: offset, frames: n, format: format)
      engine.process(frames: n)
      offset += n
    }
    staging.pointee = engine.state.pointee.readings
    publisher.publish(&staging.pointee)
  }

  /// True when a request was applied.
  private func applyResetRequests() -> Bool {
    let request = resetRequest.exchange(0, ordering: .acquiring)
    guard request != 0 else { return false }
    if request & ResetRequest.all != 0 { engine.resetFilters() }
    engine.resetMeasurement()
    return true
  }

  // MARK: Output and control

  /// The latest readings. Lock-free; safe from any thread. A reset that
  /// `process` has not applied yet (audio stopped, say) already shows here.
  public func snapshot() -> LoudnessSnapshot {
    var value = LoudnessSnapshot()
    publisher.read(into: &value)
    return resetRequest.load(ordering: .acquiring) != 0 ? LoudnessSnapshot() : value
  }

  /// Advances on every publish and every reset request, so a display can
  /// skip redrawing while it is unchanged.
  public var publishCount: UInt64 {
    publisher.publishCount &+ resetRequestCount.load(ordering: .acquiring)
  }

  /// Starts a new programme measurement.
  public func resetMeasurement() { request(ResetRequest.loudness) }

  /// Also clears the K-weighting's signal memory, as if the meter were new
  /// (for a new source; `resetMeasurement()` is the one for a new programme).
  public func reset() { request(ResetRequest.all) }

  /// Readers see the request at once; the next `process` applies it.
  private func request(_ bits: UInt32) {
    resetRequest.bitwiseOr(bits, ordering: .releasing)
    resetRequestCount.add(1, ordering: .releasing)
  }
}

enum ResetRequest {
  static let peaks: UInt32 = 1
  static let loudness: UInt32 = 2
  static let all: UInt32 = 4
}
