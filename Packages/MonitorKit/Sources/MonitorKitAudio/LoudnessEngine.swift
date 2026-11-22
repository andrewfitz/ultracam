// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Accelerate
import Foundation

/// The meters' internal tick: 100 ms split into the most parts that keep it a
/// whole number of frames (5 ms at 48/96 kHz, 10 ms at 44.1 kHz). Momentary
/// and short-term windows slide one tick at a time, so a 400 ms tone that
/// starts anywhere on a 5 ms grid is measured whole (EBU Tech 3341 cases 13/14).
func meterTick(sampleRate: Double) -> (frames: Int, perHundredMilliseconds: Int) {
  let block = max(1, Int((sampleRate / 10).rounded()))
  for parts in [20, 10, 8, 5, 4, 2] where block % parts == 0 {
    return (block / parts, parts)
  }
  return (block, 1)
}

/// Combines and clears one tick's channel energies. Unit-scale layouts skip
/// division; normalized layouts preserve the multiply/divide order.
@inline(__always) func weightedTickEnergy(
  _ energies: UnsafeMutablePointer<Double>, weights: UnsafePointer<Double>,
  scale: Double, channelCount: Int
) -> Double {
  var energy = 0.0
  var c = 0
  if scale == 1 {
    while c < channelCount {
      energy += energies[c] * weights[c]
      energies[c] = 0
      c += 1
    }
  } else {
    while c < channelCount {
      // Small weights multiply first: dividing them by a huge scale first
      // could underflow even when their actual channel energy passes -70 LUFS.
      // Large weights divide first, avoiding an overflowing product.
      energy += weights[c] <= 1
        ? (energies[c] * weights[c]) / scale
        : energies[c] * (weights[c] / scale)
      energies[c] = 0
      c += 1
    }
  }
  return energy
}

/// Fixed-memory loudness histogram: 0.02 LU bins through +150 LUFS.
/// Exotic custom channel weights extend the upper domain in 0.1 LU bins,
/// allocated only when configured. Per-bin energy sums keep gated means
/// exact; only gate boundaries and LRA percentiles are quantized.
struct LoudnessHistogram {
  static let floor = -70.0
  static let binWidth = 0.02
  static let fineCeiling = 150.0
  static let fineBinCount = 11000
  static let upperBinWidth = 0.1
  let binCount: Int

  struct Totals {
    var count = 0
    var energy = 0.0
    var lowBin = Int.max
    var highBin = -1
  }

  let energyLoudnessOffset: Double
  let counts: UnsafeMutablePointer<UInt32>
  /// Per-bin energy sums; only the integrated-loudness histogram keeps them
  /// (the LRA gate needs just the running total).
  let energies: UnsafeMutablePointer<Double>?
  let totals: UnsafeMutablePointer<Totals>

  init(storesEnergy: Bool, energyLoudnessOffset: Double = 0, maximumLoudness: Double = 150) {
    self.energyLoudnessOffset = energyLoudnessOffset
    let upperBins = Int(ceil(max(0, min(maximumLoudness, 3300) - Self.fineCeiling) / Self.upperBinWidth))
    binCount = Self.fineBinCount + upperBins
    counts = .allocate(capacity: binCount)
    counts.initialize(repeating: 0, count: binCount)
    if storesEnergy {
      let e = UnsafeMutablePointer<Double>.allocate(capacity: binCount)
      e.initialize(repeating: 0, count: binCount)
      energies = e
    } else {
      energies = nil
    }
    totals = .allocate(capacity: 1)
    totals.initialize(to: Totals())
  }

  func deallocate() {
    counts.deallocate()
    energies?.deallocate()
    totals.deallocate()
  }

  func clear() {
    let t = totals.pointee
    if t.highBin >= t.lowBin {
      (counts + t.lowBin).update(repeating: 0, count: t.highBin - t.lowBin + 1)
      if let energies { (energies + t.lowBin).update(repeating: 0, count: t.highBin - t.lowBin + 1) }
    }
    totals.pointee = Totals()
  }

  /// `energy` is the block's channel-weighted mean square.
  func add(loudness: Double, energy: Double) {
    guard loudness.isFinite, energy.isFinite, energy > 0 else { return }
    let position = loudness < Self.fineCeiling
      ? ((loudness - Self.floor) / Self.binWidth).rounded(.down)
      : Double(Self.fineBinCount) + ((loudness - Self.fineCeiling) / Self.upperBinWidth).rounded(.down)
    let b = Int(min(max(position, 0), Double(binCount - 1)))
    counts[b] &+= 1
    energies?[b] += energy
    totals.pointee.count += 1
    totals.pointee.energy += energy
    totals.pointee.lowBin = min(totals.pointee.lowBin, b)
    totals.pointee.highBin = max(totals.pointee.highBin, b)
  }

  /// First bin whose centre lies above `threshold`; never past the top bin.
  private func firstBin(above threshold: Double) -> Int {
    let position = threshold < Self.fineCeiling
      ? ((threshold - Self.floor) / Self.binWidth - 0.5).rounded(.down) + 1
      : Double(Self.fineBinCount) + ((threshold - Self.fineCeiling) / Self.upperBinWidth - 0.5).rounded(.down) + 1
    return Int(min(max(position, 0), Double(binCount - 1)))
  }

  private func center(of bin: Int) -> Double {
    bin < Self.fineBinCount
      ? Self.floor + (Double(bin) + 0.5) * Self.binWidth
      : Self.fineCeiling + (Double(bin - Self.fineBinCount) + 0.5) * Self.upperBinWidth
  }

  /// The relative gate: `offset` LU below the loudness of the mean energy of all blocks.
  private func relativeThreshold(_ offset: Double) -> Double? {
    let t = totals.pointee
    guard t.count > 0, t.energy > 0, t.energy.isFinite else { return nil }
    return -0.691 + 10 * log10(t.energy / Double(t.count)) + energyLoudnessOffset + offset
  }

  /// BS.1770-4 eq. 7: mean energy of the blocks above the -10 LU relative gate
  /// (every stored block already passed the -70 LUFS absolute gate).
  func gatedMeanEnergy() -> Double {
    guard let energies, let threshold = relativeThreshold(-10) else { return 0 }
    let t = totals.pointee
    let first = max(t.lowBin, firstBin(above: threshold))
    guard first <= t.highBin else { return 0 }
    var energy = 0.0
    var count = 0
    forEachIndex(t.highBin - first + 1) {
      energy += energies[first + $0]
      count += Int(counts[first + $0])
    }
    return count > 0 ? energy / Double(count) : 0
  }

  /// EBU Tech 3342: the 10th to 95th percentile spread of the short-term values
  /// above the -20 LU relative gate, ranked as in its reference MATLAB code.
  func loudnessRange() -> Double {
    guard let threshold = relativeThreshold(-20) else { return 0 }
    let t = totals.pointee
    let first = max(t.lowBin, firstBin(above: threshold))
    guard first <= t.highBin else { return 0 }
    var n = 0
    forEachIndex(t.highBin - first + 1) { n += Int(counts[first + $0]) }
    guard n > 0 else { return 0 }
    let lowRank = Int((Double(n - 1) * 0.10).rounded())
    let highRank = Int((Double(n - 1) * 0.95).rounded())
    var cumulative = 0
    var low = Double.nan
    var b = first
    while b <= t.highBin {
      cumulative += Int(counts[b])
      if low.isNaN, cumulative > lowRank { low = center(of: b) }
      if cumulative > highRank { return center(of: b) - low }
      b += 1
    }
    return 0
  }
}

/// BS.1770-4 loudness over planar chunks owned by a `PlanarStage`. Channels
/// with weight 0 are not filtered at all. The K-weighting runs through vDSP
/// (both sections in one `vDSP_biquadD` call per channel and tick segment),
/// in Double, so it costs the same in debug and release builds of a host.
///
/// EBU Tech 3341 section 2.2 asks for start, pause and continue of the
/// integrated loudness and LRA measurement. Momentary and short-term (and
/// their maxima) follow all the audio; the gating blocks and LRA's
/// short-term values are cut from a second ring that only receives ticks
/// measured while running, so a paused stretch leaves the measurement exactly
/// as if that audio had never been there. Pause and continue take effect at
/// the next tick boundary (5 or 10 ms), so every tick, and `duration`, is
/// either wholly measured or wholly left out. A measurement reset starts the
/// gating and the maxima over the same way, while momentary and short-term
/// slide on over the continuous audio.
final class LoudnessEngine {
  struct State {
    var tickPosition = 0
    var ringHead = 0
    var ticks = 0
    /// Whole ticks since the last measurement reset (-1 while the tick the
    /// reset fell in is open). The maxima take only windows of these.
    var resetTicks = 0
    /// The gating ring's head and the ticks it has received since reset.
    var gateHead = 0
    var gateTicks = 0
    /// Frames measured (not paused) since reset.
    var frames = 0
    /// False while the measurement is paused.
    var measuring = true
    /// What `setMeasuring` asked for; becomes `measuring` when a tick starts.
    var requestedMeasuring = true
    var readings = LoudnessSnapshot()
  }

  let sampleRate: Double
  let tickFrames: Int
  let ticksPerBlock: Int
  let momentaryTicks: Int
  let shortTermTicks: Int
  /// Channels with a nonzero weight.
  private let activeCount: Int
  private let inputs: UnsafeMutablePointer<UnsafePointer<Float>>
  private let weights: UnsafeMutablePointer<Double>
  /// Factor common to every weighted energy. Keep energy arithmetic bounded
  /// even for finite custom weights near Double.max; restore it in log space.
  private let weightScale: Double
  private let energyLoudnessOffset: Double
  /// The shelf and high-pass as one two-section cascade.
  private let kWeighting: vDSP_biquad_SetupD
  /// The cascade's gain at DC after the shelf and after both stages: H(1) =
  /// (b0 + b1 + b2) / (1 + a1 + a2) per section.
  private let dcGains: (shelf: Double, cascade: Double)
  /// Set by `primeFilters()`: the next `process` starts the cascade from its first sample.
  /// Only the processing thread touches it. Unchecked: a dynamic exclusivity check here
  /// made `process` call `swift_beginAccess`, whose first use on a thread allocates on
  /// macOS 26 (every other mutable field lives behind `state`).
  @exclusivity(unchecked) private var primesFilters = false
  /// Per active channel: the cascade's 2 * 2 + 2 delay values.
  private let delays: UnsafeMutablePointer<Double>
  /// Per active channel: K-weighted energy of the current tick.
  private let energies: UnsafeMutablePointer<Double>
  private let wide: UnsafeMutablePointer<Double>
  private let weighted: UnsafeMutablePointer<Double>
  /// Tick energies: all audio (momentary, short-term) and measured audio only (gating, LRA).
  private let ring: UnsafeMutablePointer<Double>
  private let gateRing: UnsafeMutablePointer<Double>
  private let blocks: LoudnessHistogram
  private let shortTerms: LoudnessHistogram
  let state: UnsafeMutablePointer<State>

  static let delaysPerChannel = 6

  init(sampleRate: Double, weights channelWeights: [Double], stage: PlanarStage) {
    self.sampleRate = sampleRate
    // The stage clamps |sample| to 1e6. With at most 16 channels, +150
    // LUFS leaves ample headroom for the supported K-weighting cascade even
    // at that input limit. A larger custom weight only shifts this bound;
    // allocate its extra histogram tail once, never on the audio thread.
    // Scaling all the way to the largest weight needlessly underflows a
    // quiet channel when a different, heavily weighted channel is silent.
    // Half its exponent leaves both ends room: even Double.max weights
    // and the stage's bounded samples keep tick energies far below overflow,
    // while ordinary Float32 signals retain their full amplitude range.
    let maximumWeight = max(1, channelWeights.max() ?? 1)
    weightScale = maximumWeight.squareRoot()
    energyLoudnessOffset = 10 * log10(weightScale)
    blocks = LoudnessHistogram(storesEnergy: true, energyLoudnessOffset: energyLoudnessOffset, maximumLoudness: 150 + 10 * log10(maximumWeight))
    shortTerms = LoudnessHistogram(storesEnergy: false, energyLoudnessOffset: energyLoudnessOffset, maximumLoudness: 150 + 10 * log10(maximumWeight))
    let (shelf, highPass) = KWeighting.filters(sampleRate: sampleRate)
    (tickFrames, ticksPerBlock) = meterTick(sampleRate: sampleRate)
    momentaryTicks = 4 * ticksPerBlock
    shortTermTicks = 30 * ticksPerBlock

    let active = channelWeights.indices.filter { channelWeights[$0] > 0 }
    activeCount = active.count
    inputs = .allocate(capacity: max(active.count, 1))
    weights = .allocate(capacity: max(active.count, 1))
    for (i, c) in active.enumerated() {
      (inputs + i).initialize(to: UnsafePointer(stage.samples(c)))
      (weights + i).initialize(to: channelWeights[c])
    }
    guard let setup = vDSP_biquad_CreateSetupD(shelf.vDSPCoefficients + highPass.vDSPCoefficients, 2) else {
      fatalError("vDSP_biquad_CreateSetupD failed")
    }
    kWeighting = setup
    func dcGain(_ b: Biquad) -> Double { (b.b0 + b.b1 + b.b2) / (1 + b.a1 + b.a2) }
    dcGains = (dcGain(shelf), dcGain(shelf) * dcGain(highPass))
    delays = .allocate(capacity: max(active.count, 1) * Self.delaysPerChannel)
    delays.initialize(repeating: 0, count: max(active.count, 1) * Self.delaysPerChannel)
    energies = .allocate(capacity: max(active.count, 1))
    energies.initialize(repeating: 0, count: max(active.count, 1))
    wide = .allocate(capacity: stage.capacity)
    wide.initialize(repeating: 0, count: stage.capacity)
    weighted = .allocate(capacity: stage.capacity)
    weighted.initialize(repeating: 0, count: stage.capacity)
    ring = .allocate(capacity: shortTermTicks)
    ring.initialize(repeating: 0, count: shortTermTicks)
    gateRing = .allocate(capacity: shortTermTicks)
    gateRing.initialize(repeating: 0, count: shortTermTicks)
    state = .allocate(capacity: 1)
    state.initialize(to: State())
  }

  deinit {
    vDSP_biquad_DestroySetupD(kWeighting)
    inputs.deallocate()
    weights.deallocate()
    delays.deallocate()
    energies.deallocate()
    wide.deallocate()
    weighted.deallocate()
    ring.deallocate()
    gateRing.deallocate()
    blocks.deallocate()
    shortTerms.deallocate()
    state.deallocate()
  }

  /// Measures the first `frames` samples of the stage's current chunk.
  func process(frames: Int) {
    if primesFilters && frames > 0 { applyFilterPriming() }
    var i = 0
    while i < frames {
      if state.pointee.tickPosition == 0 { state.pointee.measuring = state.pointee.requestedMeasuring }
      let n = min(frames - i, tickFrames - state.pointee.tickPosition)
      filter(offset: i, count: n)
      i += n
      state.pointee.tickPosition += n
      if state.pointee.measuring { state.pointee.frames += n }
      if state.pointee.tickPosition == tickFrames {
        state.pointee.tickPosition = 0
        finishTick()
      }
    }
    state.pointee.readings.duration = Double(state.pointee.frames) / sampleRate
  }

  private func filter(offset: Int, count: Int) {
    let n = vDSP_Length(count)
    var c = 0
    while c < activeCount {
      vDSP_vspdp(inputs[c] + offset, 1, wide, 1, n)
      vDSP_biquadD(kWeighting, delays + c * Self.delaysPerChannel, wide, 1, weighted, 1, n)
      var energy = 0.0
      vDSP_svesqD(weighted, 1, &energy, n)
      energies[c] += energy
      c += 1
    }
  }

  /// Sum of the newest `count` entries of a ring whose next write goes to `head`.
  private func windowSum(_ ring: UnsafeMutablePointer<Double>, head: Int, _ count: Int) -> Double {
    var sum = 0.0
    var part = 0.0
    if count <= head {
      vDSP_sveD(ring + head - count, 1, &sum, vDSP_Length(count))
    } else {
      if head > 0 { vDSP_sveD(ring, 1, &sum, vDSP_Length(head)) }
      let rest = count - head
      vDSP_sveD(ring + shortTermTicks - rest, 1, &part, vDSP_Length(rest))
      sum += part
    }
    return sum
  }

  private func scaledLoudness(_ energy: Double) -> Float {
    energy > 0 ? Float(-0.691 + 10 * log10(energy) + energyLoudnessOffset) : -.infinity
  }

  private func finishTick() {
    let energy = weightedTickEnergy(
      energies, weights: weights, scale: weightScale, channelCount: activeCount)
    let st = state
    ring[st.pointee.ringHead] = energy
    st.pointee.ringHead = st.pointee.ringHead + 1 == shortTermTicks ? 0 : st.pointee.ringHead + 1
    st.pointee.ticks += 1
    st.pointee.resetTicks += 1
    let ticks = st.pointee.ticks
    let resetTicks = st.pointee.resetTicks
    if ticks >= momentaryTicks {
      let l = scaledLoudness(windowSum(ring, head: st.pointee.ringHead, momentaryTicks) / Double(momentaryTicks * tickFrames))
      st.pointee.readings.momentary = l
      if resetTicks >= momentaryTicks { st.pointee.readings.momentaryMax = max(st.pointee.readings.momentaryMax, l) }
    }
    if ticks >= shortTermTicks {
      let l = scaledLoudness(windowSum(ring, head: st.pointee.ringHead, shortTermTicks) / Double(shortTermTicks * tickFrames))
      st.pointee.readings.shortTerm = l
      if resetTicks >= shortTermTicks { st.pointee.readings.shortTermMax = max(st.pointee.readings.shortTermMax, l) }
    }

    guard st.pointee.measuring else { return }
    gateRing[st.pointee.gateHead] = energy
    st.pointee.gateHead = st.pointee.gateHead + 1 == shortTermTicks ? 0 : st.pointee.gateHead + 1
    st.pointee.gateTicks += 1
    let gateTicks = st.pointee.gateTicks
    // Gating blocks: 400 ms, 75 % overlap (BS.1770-4 eqs. 3-7); LRA input: 3 s at 10 Hz.
    guard gateTicks % ticksPerBlock == 0 else { return }
    let head = st.pointee.gateHead
    if gateTicks >= momentaryTicks {
      let momentary = windowSum(gateRing, head: head, momentaryTicks) / Double(momentaryTicks * tickFrames)
      if momentary > 0 {
        let l = -0.691 + 10 * log10(momentary) + energyLoudnessOffset
        if l > -70 {
          blocks.add(loudness: l, energy: momentary)
          st.pointee.readings.integrated = scaledLoudness(blocks.gatedMeanEnergy())
        }
      }
    }
    if gateTicks >= shortTermTicks {
      let shortTerm = windowSum(gateRing, head: head, shortTermTicks) / Double(shortTermTicks * tickFrames)
      if shortTerm > 0 {
        let l = -0.691 + 10 * log10(shortTerm) + energyLoudnessOffset
        if l >= -70 {
          shortTerms.add(loudness: l, energy: shortTerm)
          st.pointee.readings.loudnessRange = Float(shortTerms.loudnessRange())
        }
      }
    }
  }

  /// Pauses (false) or continues (true) integrated loudness, LRA and
  /// duration from the next tick boundary.
  func setMeasuring(_ measuring: Bool) { state.pointee.requestedMeasuring = measuring }

  /// Ends the current input run without inventing samples for an incomplete
  /// tick. A partial tick cannot participate in the fixed 5/10 ms windows, so
  /// its accumulated energy is discarded and the next stream starts on a
  /// fresh tick boundary.
  func flush() {
    let partial = state.pointee.tickPosition
    guard partial > 0 else { return }
    energies.update(repeating: 0, count: max(activeCount, 1))
    if state.pointee.measuring { state.pointee.frames -= partial }
    state.pointee.tickPosition = 0
    state.pointee.readings.duration = Double(state.pointee.frames) / sampleRate
  }

  /// Starts a new measurement (integrated, LRA, maxima, duration) from the
  /// next tick boundary; momentary, short-term and the filters run on. The
  /// tick in progress holds audio from before the reset, so it is left out
  /// of the new measurement like a paused one. A paused measurement stays paused.
  func resetMeasurement() {
    gateRing.update(repeating: 0, count: shortTermTicks)
    blocks.clear()
    shortTerms.clear()
    let st = state
    st.pointee.gateHead = 0
    st.pointee.gateTicks = 0
    st.pointee.frames = 0
    if st.pointee.tickPosition == 0 {
      st.pointee.resetTicks = 0
    } else {
      st.pointee.resetTicks = -1
      st.pointee.measuring = false
    }
    st.pointee.readings = st.pointee.readings.startingNewMeasurement
  }

  /// Clears every reading, the sliding windows included, and restarts the
  /// tick grid here (a full meter reset); the filters keep running.
  func resetReadings() {
    ring.update(repeating: 0, count: shortTermTicks)
    gateRing.update(repeating: 0, count: shortTermTicks)
    blocks.clear()
    shortTerms.clear()
    energies.update(repeating: 0, count: max(activeCount, 1))
    let requested = state.pointee.requestedMeasuring
    state.pointee = State(measuring: requested, requestedMeasuring: requested)
  }

  /// Clears the K-weighting's signal memory (only for a meter that starts over on a new source).
  func resetFilters() {
    primesFilters = false
    delays.update(repeating: 0, count: max(activeCount, 1) * Self.delaysPerChannel)
  }

  /// The input breaks here (a dropped or skipped packet): the next `process`
  /// starts the K-weighting from its first sample instead of the stale memory.
  func primeFilters() { primesFilters = true }

  /// Sets each channel's cascade to its steady state for a constant input equal
  /// to the chunk's first sample, as if the signal had held it: the new audio
  /// starts with no step (zeros, or the old audio's memory, would put one into
  /// the filter, and its decay into momentary loudness). vDSP's direct-form I
  /// delays hold the cascade's input pair, then each section's output pair.
  private func applyFilterPriming() {
    primesFilters = false
    var c = 0
    while c < activeCount {
      let u = Double(inputs[c][0])
      let d = delays + c * Self.delaysPerChannel
      d[0] = u
      d[1] = u
      d[2] = dcGains.shelf * u
      d[3] = dcGains.shelf * u
      d[4] = dcGains.cascade * u
      d[5] = dcGains.cascade * u
      c += 1
    }
  }
}
