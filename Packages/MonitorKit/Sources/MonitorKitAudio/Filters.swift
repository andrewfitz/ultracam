import Accelerate
import Foundation

/// A second-order section, a0 normalized to 1:
/// H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2).
public struct Biquad: Sendable, Hashable {
  public var b0, b1, b2, a1, a2: Double

  public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
    self.b0 = b0
    self.b1 = b1
    self.b2 = b2
    self.a1 = a1
    self.a2 = a2
  }

  /// Magnitude response at `frequency`.
  public func gain(at frequency: Double, sampleRate: Double) -> Double {
    let w = 2 * Double.pi * frequency / sampleRate
    let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
    let nr = b0 + b1 * c1 + b2 * c2
    let ni = -(b1 * s1 + b2 * s2)
    let dr = 1 + a1 * c1 + a2 * c2
    let di = -(a1 * s1 + a2 * s2)
    return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
  }

  /// The section in vDSP_biquad order.
  var vDSPCoefficients: [Double] { [b0, b1, b2, a1, a2] }
}

/// The BS.1770-4 K-weighting pre-filter, designed for any sample rate.
///
/// BS.1770-4 Annex 1 only lists 48 kHz coefficients. They are the bilinear
/// transforms (prewarped at f0) of an analog high shelf and an RLB high-pass
/// whose parameters below reproduce Table 1 and Table 2 to 1e-15; the same
/// derivation is used by libebur128 and pyloudnorm.
public enum KWeighting {
  /// Stage 1: high shelf, f0 = 1681.97 Hz, +4.0 dB, Q = 0.7072. At 48 kHz and
  /// above it is the bilinear design. Below, bilinear warping would squeeze
  /// the shelf against the lower Nyquist frequency (+/-0.2 dB at 1-2 kHz at
  /// 8 kHz), so the stage is matched to the 48 kHz filter instead: the same
  /// continuous-time poles, magnitude equal at DC, f0 and Nyquist (M. Vicanek,
  /// "Matched Second Order Digital Filters", 2016). That stays within 0.04 dB
  /// of the 48 kHz response over the whole band at 8 kHz, 0.003 dB at 16 kHz.
  ///
  /// Stage 2: RLB high-pass, f0 = 38.135 Hz, Q = 0.5003. Table 2's numerator
  /// is [1, -2, 1] without a0 normalization, which leaves the stage a
  /// passband gain of a0 = 1 + k/Q + k^2 (+0.043 dB at 48 kHz, which the
  /// -0.691 of eq. 2 absorbs). The numerator is scaled by a0(48 kHz) / a0(fs),
  /// so it is exactly Table 2 at 48 kHz and the passband gain is the same at
  /// every rate (unscaled, 8 kHz would read 0.22 LU loud, as libebur128 does).
  public static func filters(sampleRate fs: Double) -> (shelf: Biquad, highPass: Biquad) {
    let shelf = fs >= 48000 ? bilinearShelf(sampleRate: fs) : matchedShelf(sampleRate: fs)

    let hpQ = 0.5003270373238773
    func highPassPrototype(_ fs: Double) -> (k: Double, a0: Double) {
      let k = tan(Double.pi * 38.13547087602444 / fs)
      return (k, 1 + k / hpQ + k * k)
    }
    let (hk, ha0) = highPassPrototype(fs)
    // The same expression at both rates, so the ratio is exactly 1 at 48 kHz.
    let g = highPassPrototype(48000).a0 / ha0
    let highPass = Biquad(
      b0: g, b1: -2 * g, b2: g,
      a1: 2 * (hk * hk - 1) / ha0,
      a2: (1 - hk / hpQ + hk * hk) / ha0)
    return (shelf, highPass)
  }

  private static let shelfF0 = 1681.974450955533

  private static func bilinearShelf(sampleRate fs: Double) -> Biquad {
    let gainDB = 3.999843853973347
    let q = 0.7071752369554196
    let k = tan(Double.pi * shelfF0 / fs)
    let vh = pow(10, gainDB / 20)
    let vb = pow(vh, 0.4996667741545416)
    let a0 = 1 + k / q + k * k
    return Biquad(
      b0: (vh + vb * k / q + k * k) / a0,
      b1: 2 * (k * k - vh) / a0,
      b2: (vh - vb * k / q + k * k) / a0,
      a1: 2 * (k * k - 1) / a0,
      a2: (1 - k / q + k * k) / a0)
  }

  /// Vicanek's matched design of the 48 kHz shelf at a lower rate.
  private static func matchedShelf(sampleRate fs: Double) -> Biquad {
    let reference = bilinearShelf(sampleRate: 48000)
    // The 48 kHz poles (a complex pair) carried to fs through continuous
    // time: radius^(48000 / fs), angle * 48000 / fs.
    let ratio = 48000 / fs
    let radius = pow(reference.a2.squareRoot(), ratio)
    let angle = atan2((4 * reference.a2 - reference.a1 * reference.a1).squareRoot(), -reference.a1) * ratio
    let a1 = -2 * radius * cos(angle)
    let a2 = radius * radius
    // |H|^2 = (B0 phi0 + B1 phi1 + B2 phi2) / (A0 phi0 + A1 phi1 + A2 phi2) with
    // phi1 = sin^2(w / 2), phi0 = 1 - phi1, phi2 = 4 phi0 phi1, B0 = (b0 + b1 + b2)^2,
    // B1 = (b0 - b1 + b2)^2, B2 = -4 b0 b2, and A0...A2 likewise from 1, a1, a2.
    let bigA0 = (1 + a1 + a2) * (1 + a1 + a2)
    let bigA1 = (1 - a1 + a2) * (1 - a1 + a2)
    let bigA2 = -4 * a2
    func power(_ f: Double) -> Double {
      let g = reference.gain(at: f, sampleRate: 48000)
      return g * g
    }
    let bigB0 = bigA0 * power(0)
    let bigB1 = bigA1 * power(fs / 2)
    let phi1 = pow(sin(Double.pi * shelfF0 / fs), 2)
    let phi0 = 1 - phi1
    let phi2 = 4 * phi0 * phi1
    let matched = (bigA0 * phi0 + bigA1 * phi1 + bigA2 * phi2) * power(shelfF0)
    let bigB2 = (matched - bigB0 * phi0 - bigB1 * phi1) / phi2
    let w = (bigB0.squareRoot() + bigB1.squareRoot()) / 2
    let b0 = (w + (w * w + bigB2).squareRoot()) / 2
    return Biquad(
      b0: b0, b1: (bigB0.squareRoot() - bigB1.squareRoot()) / 2, b2: -bigB2 / (4 * b0), a1: a1, a2: a2)
  }
}

/// The VU movement as a digital low-pass: bilinear transform of
/// w^2 / (s^2 + 2 zeta w s + w^2). The poles sit at ~2 Hz, so the transform's
/// frequency warping is negligible at every supported rate.
func vuFilter(_ ballistics: VUBallistics, sampleRate fs: Double) -> Biquad {
  let w = ballistics.naturalFrequency
  let zeta = ballistics.dampingRatio
  let k = 2 * fs
  let a0 = k * k + 2 * zeta * w * k + w * w
  let b0 = w * w / a0
  return Biquad(
    b0: b0, b1: 2 * b0, b2: b0,
    a1: 2 * (w * w - k * k) / a0,
    a2: (k * k - 2 * zeta * w * k + w * w) / a0)
}

/// The VU movement over whole chunks of the rectified signal. Only its state
/// at the end of a chunk is read, so instead of a sample-by-sample recursion
/// the state after n samples comes in closed form. With the biquad in
/// transposed direct form II as a state-space system,
///   A = [-a1 1; -a2 0], B = [b1 - a1 b0, b2 - a2 b0], y = s_1 + b0 u,
/// s[n] = A^n s[0] + sum_k A^(n-1-k) B u[k]: two vDSP dot products with
/// precomputed kernels and a 2x2 product, exact up to rounding. Allocates at
/// init only.
struct VUMovement {
  let capacity: Int
  /// Kernel p (p = 0, 1) at `p * capacity`, reversed: entry m is component
  /// p of A^(capacity - 1 - m) B, so a chunk of n uses the last n entries.
  private let kernels: UnsafeMutablePointer<Float>
  /// A^n for n in 0...capacity, row-major.
  private let powers: UnsafeMutablePointer<Double>

  init(_ ballistics: VUBallistics, sampleRate fs: Double, capacity: Int) {
    self.capacity = capacity
    let f = vuFilter(ballistics, sampleRate: fs)
    let a = (-f.a1, 1.0, -f.a2, 0.0)
    kernels = .allocate(capacity: 2 * capacity)
    powers = .allocate(capacity: 4 * (capacity + 1))
    var g = (f.b1 - f.a1 * f.b0, f.b2 - f.a2 * f.b0)
    var p = (1.0, 0.0, 0.0, 1.0)
    for k in 0...capacity {
      if k < capacity {
        (kernels + capacity - 1 - k).initialize(to: Float(g.0))
        (kernels + 2 * capacity - 1 - k).initialize(to: Float(g.1))
        g = (a.0 * g.0 + a.1 * g.1, a.2 * g.0 + a.3 * g.1)
      }
      (powers + 4 * k).initialize(to: p.0)
      (powers + 4 * k + 1).initialize(to: p.1)
      (powers + 4 * k + 2).initialize(to: p.2)
      (powers + 4 * k + 3).initialize(to: p.3)
      p = (a.0 * p.0 + a.1 * p.2, a.0 * p.1 + a.1 * p.3, a.2 * p.0 + a.3 * p.2, a.2 * p.1 + a.3 * p.3)
    }
  }

  func deallocate() {
    kernels.deallocate()
    powers.deallocate()
  }

  /// Advances the state `s` (2 values) over `count` rectified samples;
  /// `s[0]` is then the movement's deflection.
  func advance(_ s: UnsafeMutablePointer<Double>, rectified u: UnsafePointer<Float>, count n: Int) {
    assert(n <= capacity, "chunk longer than the VU kernels")
    var d0: Float = 0
    var d1: Float = 0
    vDSP_dotpr(u, 1, kernels + capacity - n, 1, &d0, vDSP_Length(n))
    vDSP_dotpr(u, 1, kernels + 2 * capacity - n, 1, &d1, vDSP_Length(n))
    let p = powers + 4 * n
    let (s0, s1) = (s[0], s[1])
    s[0] = p[0] * s0 + p[1] * s1 + Double(d0)
    s[1] = p[2] * s0 + p[3] * s1 + Double(d1)
  }
}

/// ITU-R BS.1770-4 Annex 2 true-peak interpolator: 48 taps, 4 phases of 12.
///
/// The prototype is symmetric with a group delay of 23.5 samples at 4x, so
/// phase p estimates the signal at n - 5.875 + p/4 from x[n - 11 ... n]: the
/// four phases are evenly spaced a quarter sample apart and none of them
/// reproduces an input sample (phase 0 is a 1/8-sample fractional delay).
enum TruePeakFilter {
  static let tapsPerPhase = 12
  static let phases: [[Float]] = [
    [
      0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875,
      0.1373291015625, 0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250,
      0.0148925781250, -0.0083007812500,
    ],
    [
      -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500,
      0.4650878906250, 0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625,
      0.0330810546875, -0.0189208984375,
    ],
    [
      -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125,
      0.7797851562500, 0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000,
      0.0292968750000, -0.0291748046875,
    ],
    [
      -0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750,
      0.9721679687500, 0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125,
      0.0109863281250, 0.0017089843750,
    ],
  ]
  /// Past input samples each output needs.
  static let history = tapsPerPhase - 1

  /// BS.1770-4 Annex 2 oversamples to about 192 kHz: 4x at 44.1 and 48 kHz,
  /// 2x at 88.2 and 96 kHz, none from 176.4 kHz (and 4x below 44.1 kHz). From
  /// 44.1 kHz up every rate then sees nearly the same interpolation grid in
  /// time (5.2 to 5.7 us), so the readings and the PPM ballistics do not
  /// depend on the rate, and the cost stops growing with it.
  static func oversampling(sampleRate fs: Double) -> Int {
    fs < 88_200 ? 4 : fs < 176_400 ? 2 : 1
  }

  /// The phases a factor runs: all four at 4x; at 2x phases 0 and 2, which
  /// are half a sample apart, so the grid stays even.
  static func phaseIndices(oversampling: Int) -> [Int] {
    switch oversampling {
    case 4: return [0, 1, 2, 3]
    case 2: return [0, 2]
    default: return []
    }
  }
}

/// The Annex 2 phases one oversampling factor needs, run by vDSP over planar
/// Float32 that has `TruePeakFilter.history` samples before each chunk.
/// Allocates at init only.
struct TruePeakInterpolator {
  let oversampling: Int
  /// Phases computed; 0 when the rate needs no interpolation.
  let phaseCount: Int
  /// The phases' taps reversed, because vDSP_conv correlates.
  private let reversedTaps: UnsafeMutablePointer<Float>

  init(oversampling: Int) {
    self.oversampling = oversampling
    let indices = TruePeakFilter.phaseIndices(oversampling: oversampling)
    phaseCount = indices.count
    let taps = TruePeakFilter.tapsPerPhase
    reversedTaps = .allocate(capacity: max(indices.count, 1) * taps)
    reversedTaps.initialize(repeating: 0, count: max(indices.count, 1) * taps)
    for (k, phase) in indices.enumerated() {
      for (i, tap) in TruePeakFilter.phases[phase].reversed().enumerated() { reversedTaps[k * taps + i] = tap }
    }
  }

  func deallocate() { reversedTaps.deallocate() }

  /// `outputs[k]` receives `count` samples of phase k; `x` is the chunk's first sample.
  func interpolate(_ x: UnsafePointer<Float>, count: Int, into outputs: UnsafePointer<UnsafeMutablePointer<Float>>) {
    let taps = TruePeakFilter.tapsPerPhase
    var k = 0
    while k < phaseCount {
      vDSP_conv(
        x - TruePeakFilter.history, 1, reversedTaps + k * taps, 1, outputs[k], 1,
        vDSP_Length(count), vDSP_Length(taps))
      k += 1
    }
  }

  /// `envelope[i]` = the largest magnitude of the phases at sample i, or of
  /// `x` itself when nothing is interpolated.
  func envelope(
    _ x: UnsafePointer<Float>, phases: UnsafePointer<UnsafeMutablePointer<Float>>, count: Int,
    into envelope: UnsafeMutablePointer<Float>
  ) {
    let n = vDSP_Length(count)
    switch phaseCount {
    case 0:
      vDSP_vabs(x, 1, envelope, 1, n)
    case 1:
      vDSP_vabs(phases[0], 1, envelope, 1, n)
    default:
      vDSP_vmaxmg(phases[0], 1, phases[1], 1, envelope, 1, n)
      var k = 2
      while k < phaseCount {
        vDSP_vmaxmg(envelope, 1, phases[k], 1, envelope, 1, n)
        k += 1
      }
    }
  }
}

/// A PPM's two charge paths and the highest reading since the last publish.
struct PPMState {
  var fast = 0.0
  var slow = 0.0
  var top = 0.0
}

/// The PPM's per-sample recursion. Each input sample brings L envelope
/// values (its interpolated points at L x oversampling, or the sample itself
/// at L = 1); each path decays by r and charges with its L x-rate coefficient
/// a toward every value above the decayed state:
///   z' = r z + a sum_p max(|y_p| - r z, 0) = r (1 - L a) z + a sum_p max(|y_p|, r z),
/// which keeps one dependent step per input sample.
///
/// When no value exceeds r z this is z' = r z. Most samples of programme are
/// like that, so `run` finds charge-free stretches with vDSP and only runs the
/// exact step where a charge is possible. That step advances four channels
/// per sample: their chains are independent, so an optimized build overlaps
/// them, and an unoptimized one still runs only scalar Double code.
/// Allocates at init only.
struct PPMCoefficients {
  /// `run` works through this many samples at a time.
  static let segment = 256
  /// Granularity of the charge-free test.
  static let block = 32
  /// Channels per `run`.
  static let width = 4

  /// L: values per input sample.
  let oversampling: Int
  let release: Double
  let fastKeep: Double
  let fastCharge: Double
  let slowKeep: Double
  let slowCharge: Double
  let fastWeight: Double
  /// Makes a steady sine read its peak.
  private(set) var calibration = 1.0
  /// r^-(j + 1) for j < segment: an envelope value divided by it is the
  /// state at the segment start it would charge above.
  private let ramp: UnsafeMutablePointer<Float>
  /// r^-k and r^k for k <= segment.
  private let inversePowers: UnsafeMutablePointer<Double>
  private let powers: UnsafeMutablePointer<Double>
  /// Per channel: the envelope over the ramp, for the current segment.
  private let scaled: UnsafeMutablePointer<Float>

  init(_ b: PPMBallistics, sampleRate fs: Double, oversampling: Int) {
    self.oversampling = oversampling
    let l = Double(oversampling)
    let r = pow(10, -b.returnRate / (20 * fs))
    release = r
    let fast = 1 - exp(-1 / (b.fastTimeConstant * l * fs))
    let slow = 1 - exp(-1 / (b.slowTimeConstant * l * fs))
    fastKeep = r * (1 - l * fast)
    fastCharge = fast
    slowKeep = r * (1 - l * slow)
    slowCharge = slow
    fastWeight = b.fastWeight
    let n = Self.segment
    ramp = .allocate(capacity: n)
    inversePowers = .allocate(capacity: n + 1)
    powers = .allocate(capacity: n + 1)
    scaled = .allocate(capacity: Self.width * n)
    scaled.initialize(repeating: 0, count: Self.width * n)
    for k in 0...n {
      (inversePowers + k).initialize(to: pow(r, -Double(k)))
      (powers + k).initialize(to: pow(r, Double(k)))
    }
    for j in 0..<n { (ramp + j).initialize(to: Float(pow(r, -Double(j + 1)))) }
    calibration = 1 / steadyReading(sampleRate: fs, oversampling: oversampling)
  }

  func deallocate() {
    ramp.deallocate()
    inversePowers.deallocate()
    powers.deallocate()
    scaled.deallocate()
  }

  @inline(__always) func reading(_ s: PPMState) -> Double {
    fastWeight * s.fast + (1 - fastWeight) * s.slow
  }

  /// Starts a new publish period. The next sample reads at least r times the
  /// current reading (charging only adds), and while nothing charges each
  /// reading is r times the last, so the period's maximum is exactly the
  /// larger of this and the readings of charging samples.
  @inline(__always) func restart(_ s: inout PPMState) {
    s.top = release * reading(s)
  }

  /// Runs samples `offset ..< offset + count` of `channels` (1 to 4)
  /// channels. Channel c charges from the magnitudes in
  /// `lanes[c * 4 ..< c * 4 + L]` (its interpolated phases; unused at 1x) and
  /// `envelopes[c]`, their maximum per sample (at 1x the samples' magnitudes).
  func run(
    _ states: UnsafeMutablePointer<PPMState>, channels: Int, lanes: UnsafePointer<UnsafeMutablePointer<Float>>,
    envelopes: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int
  ) {
    var start = offset
    while start < offset + count {
      let m = offset + count - start < Self.segment ? offset + count - start : Self.segment
      runSegment(states, channels: channels, lanes: lanes, envelopes: envelopes, offset: start, count: m)
      start += m
    }
  }

  private func runSegment(
    _ states: UnsafeMutablePointer<PPMState>, channels: Int, lanes: UnsafePointer<UnsafeMutablePointer<Float>>,
    envelopes: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int
  ) {
    // Without a charge, the state at sample j is z r^j, and sample j charges
    // when envelope[j] > z r^(j + 1), i.e. when scaled[j] > z.
    var c = 0
    while c < channels {
      vDSP_vmul(envelopes[c] + offset, 1, ramp, 1, scaled + c * Self.segment, 1, vDSP_Length(count))
      c += 1
    }
    var start = 0
    while start < count {
      let end = start + Self.block < count ? start + Self.block : count
      var quiet = true
      c = 0
      while c < channels, quiet {
        var largest: Float = 0
        vDSP_maxv(scaled + c * Self.segment + start, 1, &largest, vDSP_Length(end - start))
        let s = states[c]
        let lower = s.fast < s.slow ? s.fast : s.slow
        // The 1e-6 margin is far above the Float rounding of `scaled`, so
        // every sample that could charge goes through the exact step.
        quiet = largest == 0 || Double(largest) < lower * inversePowers[start] * (1 - 1e-6)
        c += 1
      }
      if quiet {
        let decay = powers[end - start]
        c = 0
        while c < channels {
          states[c].fast *= decay
          states[c].slow *= decay
          c += 1
        }
      } else {
        step(
          states, channels: channels, lanes: lanes, envelopes: envelopes, from: offset + start,
          to: offset + end)
      }
      start = end
    }
  }

  /// The exact recursion over samples `from ..< to`, made only of scalar
  /// operations that stay inlined in unoptimized builds.
  private func step(
    _ states: UnsafeMutablePointer<PPMState>, channels: Int, lanes: UnsafePointer<UnsafeMutablePointer<Float>>,
    envelopes: UnsafePointer<UnsafeMutablePointer<Float>>, from: Int, to: Int
  ) {
    let r = release
    let fk = fastKeep
    let fc = fastCharge
    let sk = slowKeep
    let sc = slowCharge
    let fw = fastWeight
    let sw = 1 - fastWeight
    let l = oversampling
    var j = from
    while j < to {
      var c = 0
      while c < channels {
        let s = states + c
        let f = s.pointee.fast
        let w = s.pointee.slow
        let e = Double(envelopes[c][j])
        let rf = r * f
        let rw = r * w
        if e > (rf < rw ? rf : rw) {
          // sum_p max(|y_p|, r z), pairwise, for both paths.
          let sumF: Double
          let sumW: Double
          if l == 4 {
            let lane = lanes + 4 * c
            let m0 = Double(lane[0][j])
            let m1 = Double(lane[1][j])
            let m2 = Double(lane[2][j])
            let m3 = Double(lane[3][j])
            sumF = ((m0 > rf ? m0 : rf) + (m1 > rf ? m1 : rf)) + ((m2 > rf ? m2 : rf) + (m3 > rf ? m3 : rf))
            sumW = ((m0 > rw ? m0 : rw) + (m1 > rw ? m1 : rw)) + ((m2 > rw ? m2 : rw) + (m3 > rw ? m3 : rw))
          } else if l == 2 {
            let lane = lanes + 4 * c
            let m0 = Double(lane[0][j])
            let m1 = Double(lane[1][j])
            sumF = (m0 > rf ? m0 : rf) + (m1 > rf ? m1 : rf)
            sumW = (m0 > rw ? m0 : rw) + (m1 > rw ? m1 : rw)
          } else {
            sumF = e > rf ? e : rf
            sumW = e > rw ? e : rw
          }
          let nf = e > rf ? fk * f + fc * sumF : rf
          let nw = e > rw ? sk * w + sc * sumW : rw
          s.pointee.fast = nf
          s.pointee.slow = nw
          let value = fw * nf + sw * nw
          if value > s.pointee.top { s.pointee.top = value }
        } else {
          s.pointee.fast = rf
          s.pointee.slow = rw
        }
        c += 1
      }
      j += 1
    }
  }

  /// The reading of a steady full-scale sine through this rate's real signal
  /// path (the Annex 2 phases' passband sits 0.24 dB low on phases 1 and 2,
  /// and the charge droops between crests): 997 Hz, so the crests sweep the
  /// whole interpolation grid, 0.4 s to settle, maximum of the last 20 ms.
  /// Runs once at init.
  private func steadyReading(sampleRate fs: Double, oversampling: Int) -> Double {
    let interpolator = TruePeakInterpolator(oversampling: oversampling)
    let n = Int(0.4 * fs)
    let tail = Int(0.02 * fs)
    let history = TruePeakFilter.history
    let w = 2 * Double.pi * 997 / fs
    // The history holds the sine's own past, so the start does not ring.
    let x = UnsafeMutablePointer<Float>.allocate(capacity: history + n)
    for i in 0..<(history + n) { (x + i).initialize(to: Float(sin(w * Double(i - history)))) }
    let x0 = UnsafePointer(x + history)
    let phaseCount = interpolator.phaseCount
    let phases = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: max(phaseCount, 1))
    // At 1x nothing is interpolated and the lanes read the envelope.
    for k in 0..<max(phaseCount, 1) { (phases + k).initialize(to: .allocate(capacity: phaseCount > 0 ? n : 1)) }
    let envelope = UnsafeMutablePointer<Float>.allocate(capacity: n)
    let state = UnsafeMutablePointer<PPMState>.allocate(capacity: 1)
    state.initialize(to: PPMState())
    defer {
      for k in 0..<max(phaseCount, 1) { phases[k].deallocate() }
      phases.deallocate()
      envelope.deallocate()
      state.deallocate()
      x.deallocate()
      interpolator.deallocate()
    }
    interpolator.interpolate(x0, count: n, into: phases)
    interpolator.envelope(x0, phases: phases, count: n, into: envelope)
    forEachIndex(phaseCount) { vDSP_vabs(phases[$0], 1, phases[$0], 1, vDSP_Length(n)) }
    let lanes = (0..<4).map { k in k < phaseCount ? phases[k] : envelope }
    let envelopes = [envelope]
    lanes.withUnsafeBufferPointer { lane in
      envelopes.withUnsafeBufferPointer { env in
        run(state, channels: 1, lanes: lane.baseAddress!, envelopes: env.baseAddress!, offset: 0, count: n - tail)
        restart(&state.pointee)
        run(state, channels: 1, lanes: lane.baseAddress!, envelopes: env.baseAddress!, offset: n - tail, count: tail)
      }
    }
    return state.pointee.top
  }
}
