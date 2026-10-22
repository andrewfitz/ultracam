import Accelerate
import CoreAudioTypes
import Synchronization

/// Broadcast level meters for 1 to 16 channels: sample peak and true peak
/// (BS.1770-4 Annex 2) with hold and decay, RMS, VU (IEC 60268-17), quasi-peak
/// PPM (IEC 60268-10 Type I / IIa / IIb) and, optionally, BS.1770-4 programme
/// loudness over a configurable channel layout, with EBU Tech 3341 pause
/// and continue of the integrated measurement.
///
/// Realtime-safe: everything is allocated at init; `process` does no heap
/// allocation, takes no lock and uses no Swift concurrency. Call `process` from
/// one thread at a time (the audio thread). `snapshot()` and the reset requests
/// work from any thread and never block it.
///
/// Work per channel and chunk of up to 256 frames, almost all of it in vDSP
/// (which runs at full speed in debug builds of a host too): conversion to
/// planar Float32, the sample peak, the Annex 2 phases and their envelope,
/// the RMS energy, the VU movement's closed-form state update and the clip
/// count. Only the PPM's nonlinear charge is a Swift loop, four channels at a
/// time and written to stay cheap unoptimized. The loudness engine K-weights
/// the same planar buffers. Readings are published at most once per
/// `publishInterval` of audio (5 ms by default), so tiny callbacks do not pay
/// the dB conversions and snapshot stores on every call.
public final class AudioMeter: @unchecked Sendable {
  // @unchecked: the producer state is confined to the `process` caller; the
  // only state shared with readers is the atomic publisher, reset requests
  // and pause flag.
  public let configuration: AudioMeterConfiguration

  struct ChannelState {
    var sampleBar = 0.0
    var sampleHold = 0.0
    var sampleHoldAge = 0
    var trueBar = 0.0
    var trueHold = 0.0
    var trueHoldAge = 0
    var trueMax = 0.0
    var clipCount: UInt32 = 0
    /// The current chunk's peaks, between the filter pass and the ballistics.
    var chunkPeak: Float = 0
    var chunkTruePeak: Float = 0
    /// Energy of the current RMS tick.
    var rmsEnergy = 0.0
  }

  /// The RMS window's energy, kept as a running sum so a publish reads one
  /// value whatever the window length. Neumaier-compensated, so adding each
  /// new tick and subtracting the one it replaces stays exact to rounding
  /// after any number of ticks; the count of nonzero ticks makes a window of
  /// digital silence read exactly 0 after loud audio has left it.
  struct RMSWindow {
    var sum = 0.0
    var compensation = 0.0
    var nonzeroTicks = 0

    @inline(__always) mutating func add(_ x: Double) {
      let t = sum + x
      compensation += abs(sum) >= abs(x) ? (sum - t) + x : (x - t) + sum
      sum = t
    }

    @inline(__always) mutating func replace(_ old: Double, with new: Double) {
      add(new)
      add(-old)
      nonzeroTicks += (new != 0 ? 1 : 0) - (old != 0 ? 1 : 0)
    }

    var energy: Double { nonzeroTicks > 0 ? max(sum + compensation, 0) : 0 }
  }

  struct Scalars {
    var tickPosition = 0
    var rmsHead = 0
    /// Ticks closed into the RMS ring since reset, up to its length; older
    /// entries read as 0, so a reset does not have to clear the ring.
    var rmsFilled = 0
    var frameCount: UInt64 = 0
    var publishes: UInt64 = 0
    var framesSincePublish = 0
    /// Samples of a PPM step still open at the end of the last chunk (folded input only).
    var ppmCarry = 0
    /// False until the first chunk after init has filled the interpolator's
    /// history with each channel's first sample. Zeros there would put a step
    /// into the filter that a stream already running when metering starts
    /// never had; a stream that starts from silence starts at 0 either way.
    var primed = false
  }

  static let chunkFrames = 256

  private let stage: PlanarStage
  private let loudness: LoudnessEngine?
  private let publisher: SnapshotPublisher<Published<AudioMeterSnapshot>>
  private let staging: UnsafeMutablePointer<Published<AudioMeterSnapshot>>
  private let requests = ResetRequests()
  private let loudnessPaused = Atomic<Bool>(false)

  private let channelCount: Int
  private let groupCount: Int
  private let channelState: UnsafeMutablePointer<ChannelState>
  private let ppmStates: UnsafeMutablePointer<PPMState>
  private let interpolator: TruePeakInterpolator
  /// The current group's interpolated phases: channel l, phase k at
  /// `phases[l * 4 + k]`, one chunk each; magnitudes once the PPM runs (they
  /// are its lanes). Entries past the phase count alias the envelope.
  private let phases: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  /// The current group's interpolated envelopes, then scratch for the VU and clip count.
  private let envelopes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  private let ppmInput: PPMInput
  /// What the PPM charges from, laid out like `phases` and `envelopes`: the
  /// same buffers for `.phases`, its own folded magnitudes for `.samples`.
  private let ppmLanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  private let ppmEnvelopes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  private let vu: VUMovement
  /// Per channel: the VU movement's two state values.
  private let vuStates: UnsafeMutablePointer<Double>
  private let rmsRing: UnsafeMutablePointer<Double>
  private let rmsWindows: UnsafeMutablePointer<RMSWindow>
  private let scalars: UnsafeMutablePointer<Scalars>

  private let runsFIR: Bool
  private let runsVU: Bool
  private let runsPPM: Bool
  private let runsRMS: Bool
  private let tickFrames: Int
  private let publishFrames: Int
  private let rmsTicks: Int
  private let rmsGain: Double
  private let vuGain: Double
  private let ppm: PPMCoefficients
  private let ppmGain: Double
  private let decayPerFrame: Double
  private let holdFrames: Int
  private let clipLevel: Float

  public init(configuration: AudioMeterConfiguration) throws(AudioMeterError) {
    try configuration.validate()
    self.configuration = configuration
    let fs = configuration.sampleRate
    let kinds = configuration.meters
    channelCount = configuration.channelCount
    runsVU = kinds.contains(.vu)
    runsPPM = kinds.contains(.ppm)
    runsRMS = kinds.contains(.rms)
    interpolator = TruePeakInterpolator(oversampling: TruePeakFilter.oversampling(sampleRate: fs))
    ppmInput = PPMInput.forSampleRate(fs)
    precondition(ppmInput.lanes <= 4, "the PPM takes at most four values per step")
    let ppmFromPhases = if case .phases = ppmInput { true } else { false }
    runsFIR = kinds.contains(.truePeak) || (runsPPM && ppmFromPhases)

    // The history also holds a folded PPM's open step.
    stage = PlanarStage(
      channelCount: channelCount, history: runsFIR || (runsPPM && ppmInput.fold > 1) ? TruePeakFilter.history : 0,
      capacity: Self.chunkFrames)
    loudness =
      kinds.contains(.loudness)
      ? LoudnessEngine(sampleRate: fs, weights: configuration.loudnessChannels.map(\.weight), stage: stage)
      : nil
    var initial = AudioMeterSnapshot()
    initial.channelCount = channelCount
    initial.programmeChannelMask = Self.programmeChannelMask(configuration)
    initial.vuReferenceDBFS = Float(configuration.vuReference.dBFS)
    initial.ppmAlignmentDBFS = Float(configuration.ppmAlignment.dBFS)
    publisher = SnapshotPublisher(Published(readings: initial))
    staging = .allocate(capacity: 1)
    staging.initialize(to: Published(readings: initial))

    groupCount = (channelCount + 3) / 4
    channelState = .allocate(capacity: channelCount)
    channelState.initialize(repeating: ChannelState(), count: channelCount)
    ppmStates = .allocate(capacity: channelCount)
    ppmStates.initialize(repeating: PPMState(), count: channelCount)
    func chunk() -> UnsafeMutablePointer<Float> {
      let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkFrames)
      p.initialize(repeating: 0, count: Self.chunkFrames)
      return p
    }
    phases = .allocate(capacity: 16)
    envelopes = .allocate(capacity: 4)
    for l in 0..<4 {
      let envelope = chunk()
      (envelopes + l).initialize(to: envelope)
      for k in 0..<4 { (phases + l * 4 + k).initialize(to: k < interpolator.phaseCount ? chunk() : envelope) }
    }
    if ppmFromPhases {
      ppmLanes = phases
      ppmEnvelopes = envelopes
    } else {
      // A step needs at most chunkFrames / fold + 1 values per lane.
      ppmLanes = .allocate(capacity: 16)
      ppmEnvelopes = .allocate(capacity: 4)
      for l in 0..<4 {
        for k in 0..<4 { (ppmLanes + l * 4 + k).initialize(to: chunk()) }
        // At one value per step the envelope is the lane.
        (ppmEnvelopes + l).initialize(to: ppmInput.lanes == 1 ? ppmLanes[l * 4] : chunk())
      }
    }
    vu = VUMovement(configuration.vuBallistics, sampleRate: fs, capacity: Self.chunkFrames)
    vuStates = .allocate(capacity: 2 * channelCount)
    vuStates.initialize(repeating: 0, count: 2 * channelCount)

    (tickFrames, _) = meterTick(sampleRate: fs)
    publishFrames = max(1, Int((configuration.publishInterval * fs).rounded()))
    rmsTicks = max(1, Int((configuration.rmsWindow * fs / Double(tickFrames)).rounded()))
    rmsRing = .allocate(capacity: runsRMS ? channelCount * rmsTicks : 1)
    rmsRing.initialize(repeating: 0, count: runsRMS ? channelCount * rmsTicks : 1)
    rmsWindows = .allocate(capacity: channelCount)
    rmsWindows.initialize(repeating: RMSWindow(), count: channelCount)
    rmsGain = configuration.rmsScale == .aes17 ? 2.0.squareRoot() : 1
    scalars = .allocate(capacity: 1)
    scalars.initialize(to: Scalars(primed: stage.history == 0))

    // A sine's rectified mean is 2/pi of its peak; 0 VU is a sine peaking at the reference.
    vuGain = Double.pi / 2 / pow(10, configuration.vuReference.dBFS / 20)

    ppm = PPMCoefficients(configuration.ppmBallistics, sampleRate: fs, input: ppmInput)
    ppmGain = ppm.calibration / pow(10, configuration.ppmAlignment.dBFS / 20)

    decayPerFrame = -configuration.peakDecayRate * log(10) / (20 * fs)
    let hold = configuration.peakHoldTime * fs
    holdFrames = hold >= Double(Int.max / 2) ? Int.max : Int(hold.rounded())
    clipLevel = Float(pow(10, configuration.clipLevelDBFS / 20))
  }

  /// The loudness layout's channels other than `.excluded`, or every channel
  /// when loudness is off (its layout is not validated then).
  private static func programmeChannelMask(_ configuration: AudioMeterConfiguration) -> UInt16 {
    let n = configuration.channelCount
    guard configuration.meters.contains(.loudness) else { return UInt16(truncatingIfNeeded: (1 << n) - 1) }
    var mask: UInt16 = 0
    for (c, channel) in configuration.loudnessChannels.enumerated() where channel != .excluded { mask |= 1 << c }
    return mask
  }

  /// The default configuration for a format.
  public convenience init(sampleRate: Double, channelCount: Int) throws(AudioMeterError) {
    try self.init(configuration: AudioMeterConfiguration(sampleRate: sampleRate, channelCount: channelCount))
  }

  deinit {
    stage.deallocate()
    interpolator.deallocate()
    ppm.deallocate()
    staging.deallocate()
    channelState.deallocate()
    ppmStates.deallocate()
    for l in 0..<4 {
      for k in 0..<interpolator.phaseCount { phases[l * 4 + k].deallocate() }
      envelopes[l].deallocate()
    }
    if ppmLanes != phases {
      for l in 0..<4 {
        for k in 0..<4 { ppmLanes[l * 4 + k].deallocate() }
        if ppmInput.lanes > 1 { ppmEnvelopes[l].deallocate() }
      }
      ppmLanes.deallocate()
      ppmEnvelopes.deallocate()
    }
    phases.deallocate()
    envelopes.deallocate()
    vu.deallocate()
    vuStates.deallocate()
    rmsRing.deallocate()
    rmsWindows.deallocate()
    scalars.deallocate()
  }

  // MARK: Input

  /// Deinterleaved Float32, e.g. `AVAudioPCMBuffer.floatChannelData`.
  public func process(planar channels: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
    forEachIndex(channelCount) { stage.bindPlanar($0, channels[$0]) }
    run(frameCount, .float32)
  }

  public func process(planar channels: UnsafePointer<UnsafePointer<Float>>, frameCount: Int) {
    forEachIndex(channelCount) { stage.bindPlanar($0, channels[$0]) }
    run(frameCount, .float32)
  }

  public func process(planar channels: UnsafePointer<UnsafeMutablePointer<Int16>>, frameCount: Int) {
    forEachIndex(channelCount) { stage.bindPlanar($0, channels[$0]) }
    run(frameCount, .int16)
  }

  public func process(planar channels: UnsafePointer<UnsafeMutablePointer<Int32>>, frameCount: Int) {
    forEachIndex(channelCount) { stage.bindPlanar($0, channels[$0]) }
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
    let s = stride ?? channelCount
    precondition(s >= channelCount, "frameStride is smaller than the channel count")
    return s
  }

  // MARK: Output and control

  /// The latest readings. Lock-free and allocation-free; safe from any thread.
  /// A reset shows here from the moment it is requested, before `process`
  /// applies it (audio stopped, say, or a call in progress), and its
  /// `sequence` moves with it.
  public func snapshot() -> AudioMeterSnapshot {
    var published = Published(readings: AudioMeterSnapshot())
    publisher.read(into: &published)
    let requested = requests.load()
    var value = published.readings
    Self.applyPendingResets(requested: requested, applied: published.resets, to: &value)
    value.sequence = value.sequence &+ requested.total
    return value
  }

  /// Advances on every publish and every reset request, so a display can
  /// skip redrawing while it is unchanged.
  public var publishCount: UInt64 {
    publisher.publishCount &+ requests.load().total
  }

  /// Clears peak holds, maximum true peak and clip counts.
  public func resetPeaks() { requests.requestPeaks() }

  /// Starts a new loudness measurement: integrated, LRA, the maxima and
  /// `duration` start over from the next 5 or 10 ms tick boundary, while
  /// momentary and short-term slide on over the continuous audio (EBU Tech
  /// 3341 resets the measurement; M and S are sliding windows).
  public func resetLoudness() { requests.requestLoudness() }

  /// Returns every reading and ballistic to its initial state, momentary and
  /// short-term loudness included. The filters' signal memory (the true-peak
  /// interpolator's history, the K-weighting) is kept, so a reset during
  /// programme adds no transient of its own.
  public func reset() { requests.requestAll() }

  /// Puts integrated loudness, loudness range and loudness `duration` on
  /// stand-by (EBU Tech 3341 section 2.2): audio from now on is left out of
  /// them as if it were cut, while momentary, short-term, their maxima and
  /// every level meter keep running. Any thread; takes effect at the first
  /// 5 or 10 ms tick boundary the next `process` call reaches, so measured
  /// and left-out audio are whole ticks. Resets keep the measurement paused.
  public func pauseLoudness() { loudnessPaused.store(true, ordering: .relaxed) }

  /// Continues a paused loudness measurement from where it stood.
  public func resumeLoudness() { loudnessPaused.store(false, ordering: .relaxed) }

  /// True between `pauseLoudness()` and `resumeLoudness()`.
  public var isLoudnessPaused: Bool { loudnessPaused.load(ordering: .relaxed) }

  /// Publishes audio held back by `publishInterval` and applies pending
  /// resets, without new input: call it when a stream stops, so its last
  /// few milliseconds (and any over in them) reach `snapshot()`. Producer
  /// thread only, like `process`; does nothing when nothing is pending.
  public func flush() {
    let reset = applyResetRequests()
    if reset || scalars.pointee.framesSincePublish > 0 { publish() }
  }

  /// The resets requested after `applied` (those the publish includes),
  /// applied to it as the next `process` will publish them.
  private static func applyPendingResets(
    requested: ResetGenerations, applied: ResetGenerations, to value: inout AudioMeterSnapshot
  ) {
    if requested.all != applied.all {
      forEachIndex(value.channelCount) { value.channels[$0] = AudioChannelLevels() }
      value.loudness = LoudnessSnapshot()
      value.frameCount = 0
      return
    }
    if requested.peaks != applied.peaks {
      forEachIndex(value.channelCount) { c in
        var levels = value.channels[c]
        levels.samplePeakHold = levels.samplePeak
        levels.truePeakHold = levels.truePeak
        levels.truePeakMax = -.infinity
        levels.clipCount = 0
        value.channels[c] = levels
      }
    }
    if requested.loudness != applied.loudness { value.loudness = value.loudness.startingNewMeasurement }
  }

  // MARK: Processing

  private func run(_ frameCount: Int, _ format: AudioSampleFormat) {
    precondition(frameCount >= 0, "negative frameCount")
    let reset = applyResetRequests()
    loudness?.setMeasuring(!loudnessPaused.load(ordering: .relaxed))
    var offset = 0
    while offset < frameCount {
      let n = min(frameCount - offset, Self.chunkFrames)
      stage.load(offset: offset, frames: n, format: format)
      if !scalars.pointee.primed {
        forEachIndex(channelCount) { stage.primeHistory($0) }
        scalars.pointee.primed = true
      }
      forEachIndex(groupCount) { measure(group: $0, frames: n) }
      advanceRMSTicks(n)
      scalars.pointee.ppmCarry = (scalars.pointee.ppmCarry + n) % ppmInput.fold
      loudness?.process(frames: n)
      // Last: the interpolator and a folded PPM read into the history.
      if stage.history > 0 { forEachIndex(channelCount) { stage.carryHistory($0, frames: n) } }
      offset += n
    }
    scalars.pointee.frameCount &+= UInt64(frameCount)
    scalars.pointee.framesSincePublish += frameCount
    // A reset publishes at once, and a zero-length call flushes audio not yet
    // published (a stream that stops); otherwise once per publish interval.
    let pending = scalars.pointee.framesSincePublish
    if reset || pending >= publishFrames || (frameCount == 0 && pending > 0) { publish() }
  }

  /// Every meter of four channels over the current chunk.
  private func measure(group g: Int, frames n: Int) {
    let first = g * 4
    let width = min(4, channelCount - first)
    forEachIndex(width) { measurePeaks(channel: first + $0, slot: $0, frames: n) }
    if runsPPM {
      ppm.run(
        ppmStates + first, channels: width, lanes: UnsafePointer(ppmLanes), envelopes: UnsafePointer(ppmEnvelopes),
        offset: 0, count: (scalars.pointee.ppmCarry + n) / ppmInput.fold)
    }
    forEachIndex(width) { measureLevels(channel: first + $0, slot: $0, frames: n) }
  }

  /// The sample peak and, through the group's scratch slot, the interpolated
  /// phases and envelope and the PPM's input.
  private func measurePeaks(channel c: Int, slot: Int, frames n: Int) {
    let x = UnsafePointer(stage.samples(c))
    let length = vDSP_Length(n)
    let phases = UnsafePointer(self.phases + slot * 4)
    let envelope = envelopes[slot]
    var peak: Float = 0
    vDSP_maxmgv(x, 1, &peak, length)
    // The sample peak floors the true peak; Annex 2's phases never reproduce the samples.
    var truePeak = peak
    if runsFIR {
      interpolator.interpolate(x, count: n, into: phases)
      interpolator.envelope(phases: phases, count: n, into: envelope)
      var interpolated: Float = 0
      vDSP_maxv(envelope, 1, &interpolated, length)
      if interpolated > truePeak { truePeak = interpolated }
    }
    if runsPPM {
      switch ppmInput {
      case .phases:
        // The PPM charges from the phases' magnitudes; the envelope already is one.
        forEachIndex(interpolator.phaseCount) { vDSP_vabs(phases[$0], 1, phases[$0], 1, length) }
      case .samples(let fold):
        // Step j takes samples fold * j - carry ..< fold * (j + 1) - carry; the
        // carried ones are the last chunk's, in the history.
        let carry = scalars.pointee.ppmCarry
        let steps = (carry + n) / fold
        let start = x - carry
        let lanes = ppmLanes + slot * 4
        forEachIndex(fold) { vDSP_vabs(start + $0, fold, lanes[$0], 1, vDSP_Length(steps)) }
        if fold > 1 { foldedEnvelope(lanes, laneCount: fold, count: steps, into: ppmEnvelopes[slot]) }
      }
    }
    channelState[c].chunkPeak = peak
    channelState[c].chunkTruePeak = truePeak
  }

  /// VU, RMS, peak ballistics and clip count.
  private func measureLevels(channel c: Int, slot: Int, frames n: Int) {
    let x = UnsafePointer(stage.samples(c))
    let length = vDSP_Length(n)
    let s = channelState + c
    if runsRMS { accumulateRMS(channel: c, frames: n) }
    if runsVU {
      // The envelope slot is free once the true peak and PPM have run.
      vDSP_vabs(x, 1, envelopes[slot], 1, length)
      vu.advance(vuStates + 2 * c, rectified: envelopes[slot], count: n)
    }

    let peak = s.pointee.chunkPeak
    let truePeak = s.pointee.chunkTruePeak
    let decay = exp(decayPerFrame * Double(n))
    Self.ballistics(
      bar: &s.pointee.sampleBar, hold: &s.pointee.sampleHold, age: &s.pointee.sampleHoldAge,
      peak: Double(peak), decay: decay, frames: n, holdFrames: holdFrames)
    Self.ballistics(
      bar: &s.pointee.trueBar, hold: &s.pointee.trueHold, age: &s.pointee.trueHoldAge,
      peak: Double(truePeak), decay: decay, frames: n, holdFrames: holdFrames)
    if Double(truePeak) > s.pointee.trueMax { s.pointee.trueMax = Double(truePeak) }
    if peak >= clipLevel {
      // vclipc counts strictly outside its bounds, so these count |x| >= clipLevel.
      var low = -clipLevel.nextDown
      var high = clipLevel.nextDown
      var below: vDSP_Length = 0
      var above: vDSP_Length = 0
      vDSP_vclipc(x, 1, &low, &high, envelopes[slot], 1, length, &below, &above)
      s.pointee.clipCount &+= UInt32(truncatingIfNeeded: below + above)
    }
  }

  /// Instant attack; after `holdFrames` the hold marker falls with the bar.
  @inline(__always) private static func ballistics(
    bar: inout Double, hold: inout Double, age: inout Int,
    peak: Double, decay: Double, frames: Int, holdFrames: Int
  ) {
    let decayed = bar * decay
    bar = peak > decayed ? peak : decayed
    if peak >= hold {
      hold = peak
      age = 0
    } else {
      age = age > holdFrames - frames ? holdFrames : age + frames
      if age >= holdFrames {
        let released = hold * decay
        hold = bar > released ? bar : released
      }
    }
  }

  /// Adds the chunk's energy to channel c's RMS ticks, closing each tick into
  /// the ring and the running window sum; `advanceRMSTicks` then moves the
  /// shared tick position the same way. A tick is at most 3840 samples; its
  /// Float sum is good to 1e-5 dB.
  private func accumulateRMS(channel c: Int, frames n: Int) {
    let x = stage.samples(c)
    let s = channelState + c
    let ring = rmsRing + c * rmsTicks
    var position = scalars.pointee.tickPosition
    var head = scalars.pointee.rmsHead
    var filled = scalars.pointee.rmsFilled
    var i = 0
    while i < n {
      let m = min(n - i, tickFrames - position)
      var energy: Float = 0
      vDSP_svesq(x + i, 1, &energy, vDSP_Length(m))
      s.pointee.rmsEnergy += Double(energy)
      i += m
      position += m
      if position == tickFrames {
        let new = s.pointee.rmsEnergy
        rmsWindows[c].replace(filled == rmsTicks ? ring[head] : 0, with: new)
        ring[head] = new
        s.pointee.rmsEnergy = 0
        position = 0
        head = head + 1 == rmsTicks ? 0 : head + 1
        if filled < rmsTicks { filled += 1 }
      }
    }
  }

  private func advanceRMSTicks(_ n: Int) {
    let total = scalars.pointee.tickPosition + n
    let closed = total / tickFrames
    scalars.pointee.tickPosition = total % tickFrames
    scalars.pointee.rmsHead = (scalars.pointee.rmsHead + closed) % rmsTicks
    scalars.pointee.rmsFilled = min(rmsTicks, scalars.pointee.rmsFilled + closed)
  }

  private func publish() {
    let kinds = configuration.meters
    let window = Double(rmsTicks * tickFrames)
    scalars.pointee.publishes &+= 1
    scalars.pointee.framesSincePublish = 0
    staging.pointee.readings.sequence = scalars.pointee.publishes
    staging.pointee.readings.frameCount = scalars.pointee.frameCount
    forEachIndex(channelCount) { c in
      let s = channelState + c
      var levels = AudioChannelLevels(clipCount: s.pointee.clipCount)
      if kinds.contains(.samplePeak) {
        levels.samplePeak = amplitudeDB(s.pointee.sampleBar)
        levels.samplePeakHold = amplitudeDB(s.pointee.sampleHold)
      }
      if kinds.contains(.truePeak) {
        levels.truePeak = amplitudeDB(s.pointee.trueBar)
        levels.truePeakHold = amplitudeDB(max(s.pointee.trueHold, s.pointee.sampleHold))
        levels.truePeakMax = amplitudeDB(s.pointee.trueMax)
      }
      if runsRMS { levels.rms = amplitudeDB((rmsWindows[c].energy / window).squareRoot() * rmsGain) }
      if runsVU { levels.vu = amplitudeDB(max(vuStates[2 * c], 0) * vuGain) }
      if runsPPM {
        levels.ppm = amplitudeDB(ppmStates[c].top * ppmGain)
        ppm.restart(&ppmStates[c])
      }
      staging.pointee.readings.channels[c] = levels
    }
    if let loudness { staging.pointee.readings.loudness = loudness.state.pointee.readings }
    publisher.publish(&staging.pointee)
  }

  /// True when a request was applied; the generations go out with the next publish.
  private func applyResetRequests() -> Bool {
    let requested = requests.load()
    let applied = staging.pointee.resets
    guard requested != applied else { return false }
    staging.pointee.resets = requested
    if requested.all != applied.all {
      // Readings and ballistics only; the signal memory stays (see `reset()`).
      channelState.update(repeating: ChannelState(), count: channelCount)
      ppmStates.update(repeating: PPMState(), count: channelCount)
      vuStates.update(repeating: 0, count: 2 * channelCount)
      rmsWindows.update(repeating: RMSWindow(), count: channelCount)
      scalars.pointee = Scalars(
        publishes: scalars.pointee.publishes, ppmCarry: scalars.pointee.ppmCarry, primed: scalars.pointee.primed)
      loudness?.resetReadings()
      return true
    }
    if requested.peaks != applied.peaks {
      forEachIndex(channelCount) { c in
        channelState[c].sampleHold = channelState[c].sampleBar
        channelState[c].sampleHoldAge = 0
        channelState[c].trueHold = channelState[c].trueBar
        channelState[c].trueHoldAge = 0
        channelState[c].trueMax = 0
        channelState[c].clipCount = 0
      }
    }
    if requested.loudness != applied.loudness { loudness?.resetMeasurement() }
    return true
  }
}
