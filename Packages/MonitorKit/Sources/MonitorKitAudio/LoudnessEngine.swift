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

/// Histogram of block loudness over -70 ... +30 LUFS in 0.02 LU bins, with
/// the exact energy sum per bin when the gated mean is needed. Integrated
/// loudness and LRA need every block since reset; a programme of any length
/// fits in fixed memory, the means stay exact and only the gate boundary is
/// quantized to 0.02 LU. Louder blocks land in the top bin, which every gate
/// keeps, so even absurd input cannot gate everything out.
struct LoudnessHistogram {
  static let floor = -70.0
  static let binWidth = 0.02
  static let binCount = 5000

  struct Totals {
    var count = 0
    var energy = 0.0
    var lowBin = LoudnessHistogram.binCount
    var highBin = -1
  }

  let counts: UnsafeMutablePointer<UInt32>
  /// Per-bin energy sums; only the integrated-loudness histogram keeps them
  /// (the LRA gate needs just the running total).
  let energies: UnsafeMutablePointer<Double>?
  let totals: UnsafeMutablePointer<Totals>

  init(storesEnergy: Bool) {
    counts = .allocate(capacity: Self.binCount)
    counts.initialize(repeating: 0, count: Self.binCount)
    if storesEnergy {
      let e = UnsafeMutablePointer<Double>.allocate(capacity: Self.binCount)
      e.initialize(repeating: 0, count: Self.binCount)
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
    let b = min(max(Int(((loudness - Self.floor) / Self.binWidth).rounded(.down)), 0), Self.binCount - 1)
    counts[b] &+= 1
    energies?[b] += energy
    totals.pointee.count += 1
    totals.pointee.energy += energy
    totals.pointee.lowBin = min(totals.pointee.lowBin, b)
    totals.pointee.highBin = max(totals.pointee.highBin, b)
  }

  /// First bin whose centre lies above `threshold`; never past the top bin.
  private static func firstBin(above threshold: Double) -> Int {
    let b = Int(((threshold - floor) / binWidth - 0.5).rounded(.down)) + 1
    return min(max(b, 0), binCount - 1)
  }

  /// The relative gate: `offset` LU below the loudness of the mean energy of all blocks.
  private func relativeThreshold(_ offset: Double) -> Double? {
    let t = totals.pointee
    guard t.count > 0, t.energy > 0 else { return nil }
    return -0.691 + 10 * log10(t.energy / Double(t.count)) + offset
  }

  /// BS.1770-4 eq. 7: mean energy of the blocks above the -10 LU relative gate
  /// (every stored block already passed the -70 LUFS absolute gate).
  func gatedMeanEnergy() -> Double {
    guard let energies, let threshold = relativeThreshold(-10) else { return 0 }
    let t = totals.pointee
    let first = max(t.lowBin, Self.firstBin(above: threshold))
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
    let first = max(t.lowBin, Self.firstBin(above: threshold))
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
      let center = Self.floor + (Double(b) + 0.5) * Self.binWidth
      if low.isNaN, cumulative > lowRank { low = center }
      if cumulative > highRank { return center - low }
      b += 1
    }
    return 0
  }
}

/// BS.1770-4 loudness over planar chunks owned by a `PlanarStage`. Channels
/// with weight 0 are not filtered at all. The K-weighting runs through vDSP
/// (both sections in one `vDSP_biquadD` call per channel and tick segment),
/// in Double, so it costs the same in debug and release builds of a host.
final class LoudnessEngine {
  struct State {
    var tickPosition = 0
    var ringHead = 0
    var ticks = 0
    var frames = 0
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
  /// The shelf and high-pass as one two-section cascade.
  private let kWeighting: vDSP_biquad_SetupD
  /// Per active channel: the cascade's 2 * 2 + 2 delay values.
  private let delays: UnsafeMutablePointer<Double>
  /// Per active channel: K-weighted energy of the current tick.
  private let energies: UnsafeMutablePointer<Double>
  private let wide: UnsafeMutablePointer<Double>
  private let weighted: UnsafeMutablePointer<Double>
  private let ring: UnsafeMutablePointer<Double>
  private let blocks = LoudnessHistogram(storesEnergy: true)
  private let shortTerms = LoudnessHistogram(storesEnergy: false)
  let state: UnsafeMutablePointer<State>

  static let delaysPerChannel = 6

  init(sampleRate: Double, weights channelWeights: [Double], stage: PlanarStage) {
    self.sampleRate = sampleRate
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
    blocks.deallocate()
    shortTerms.deallocate()
    state.deallocate()
  }

  /// Measures the first `frames` samples of the stage's current chunk.
  func process(frames: Int) {
    var i = 0
    while i < frames {
      let n = min(frames - i, tickFrames - state.pointee.tickPosition)
      filter(offset: i, count: n)
      i += n
      state.pointee.tickPosition += n
      state.pointee.frames += n
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

  /// Sum of the newest `count` ring entries.
  private func windowSum(_ count: Int) -> Double {
    let head = state.pointee.ringHead
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

  private func finishTick() {
    var energy = 0.0
    forEachIndex(activeCount) { c in
      energy += weights[c] * energies[c]
      energies[c] = 0
    }
    let st = state
    ring[st.pointee.ringHead] = energy
    st.pointee.ringHead = st.pointee.ringHead + 1 == shortTermTicks ? 0 : st.pointee.ringHead + 1
    st.pointee.ticks += 1
    let ticks = st.pointee.ticks

    var momentary = 0.0
    if ticks >= momentaryTicks {
      momentary = windowSum(momentaryTicks) / Double(momentaryTicks * tickFrames)
      let l = loudnessLUFS(momentary)
      st.pointee.readings.momentary = l
      st.pointee.readings.momentaryMax = max(st.pointee.readings.momentaryMax, l)
    }
    var shortTerm = 0.0
    if ticks >= shortTermTicks {
      shortTerm = windowSum(shortTermTicks) / Double(shortTermTicks * tickFrames)
      let l = loudnessLUFS(shortTerm)
      st.pointee.readings.shortTerm = l
      st.pointee.readings.shortTermMax = max(st.pointee.readings.shortTermMax, l)
    }
    // Gating blocks: 400 ms, 75 % overlap (BS.1770-4 eq. 3-7); LRA input: 3 s at 10 Hz.
    guard ticks % ticksPerBlock == 0 else { return }
    var changed = false
    if ticks >= momentaryTicks, momentary > 0 {
      let l = -0.691 + 10 * log10(momentary)
      if l > -70 {
        blocks.add(loudness: l, energy: momentary)
        changed = true
      }
    }
    if ticks >= shortTermTicks, shortTerm > 0 {
      let l = -0.691 + 10 * log10(shortTerm)
      if l >= -70 {
        shortTerms.add(loudness: l, energy: shortTerm)
        st.pointee.readings.loudnessRange = Float(shortTerms.loudnessRange())
      }
    }
    if changed { st.pointee.readings.integrated = loudnessLUFS(blocks.gatedMeanEnergy()) }
  }

  /// Starts a new measurement (integrated, LRA, maxima); the filters keep running.
  func resetMeasurement() {
    ring.update(repeating: 0, count: shortTermTicks)
    blocks.clear()
    shortTerms.clear()
    energies.update(repeating: 0, count: max(activeCount, 1))
    // The tick grid restarts at the reset, so windows align with the measurement start.
    state.pointee = State()
  }

  /// Clears the K-weighting's signal memory (only for a meter that starts over on a new source).
  func resetFilters() {
    delays.update(repeating: 0, count: max(activeCount, 1) * Self.delaysPerChannel)
  }
}
