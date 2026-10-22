import Foundation
import MonitorKitAudio
import XCTest

/// Straightforward Double evaluations of the published algorithms, sample by
/// sample with no shortcuts, that the vDSP and block-skipping paths must match.
enum Reference {
  /// ITU-R BS.1770-4 Annex 2: the 48-tap interpolator as 4 phases of 12.
  static let annex2: [[Double]] = [
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

  /// BS.1770-4 Annex 2 oversampling to about 192 kHz.
  static func oversampling(_ fs: Double) -> Int { fs < 88_200 ? 4 : fs < 176_400 ? 2 : 1 }

  /// The phases each factor evaluates (evenly spaced in time).
  static func phases(_ oversampling: Int) -> [Int] {
    oversampling == 4 ? [0, 1, 2, 3] : oversampling == 2 ? [0, 2] : []
  }

  /// The interpolated values of every sample, `values[i]` holding one per
  /// phase, or the sample itself at 1x. The signal before `x[0]` is taken as
  /// `x[0]` held, as a meter attached to a running stream has to assume.
  static func interpolated(_ x: [Float], oversampling: Int) -> [[Double]] {
    let taps = 12
    let held = [Double](repeating: Double(x.first ?? 0), count: taps - 1) + x.map(Double.init)
    let phases = phases(oversampling)
    return x.indices.map { i in
      if phases.isEmpty { return [Double(x[i])] }
      return phases.map { p in
        var acc = 0.0
        for k in 0..<taps { acc += annex2[p][k] * held[i + taps - 1 - k] }
        return acc
      }
    }
  }

  /// Annex 2 true peak of samples `from...`, with the sample peak as a floor.
  static func truePeak(_ x: [Float], sampleRate fs: Double, from start: Int = 0) -> Double {
    let sample = x[start...].map { abs(Double($0)) }.max() ?? 0
    let values = interpolated(x, oversampling: oversampling(fs))[start...]
    return max(sample, values.map { $0.map(abs).max()! }.max() ?? 0)
  }

  /// The PPM recursion of `PPMBallistics`, evaluated directly: each path
  /// decays by r and charges by a toward every one of the sample's L values
  /// above the decayed state. Returns the uncalibrated reading's maximum over
  /// each `periods` slice.
  static func ppmMaxima(_ x: [Float], sampleRate fs: Double, ballistics b: PPMBallistics, periods: [Int]) -> [Double] {
    let l = oversampling(fs)
    let r = pow(10, -b.returnRate / (20 * fs))
    let fastA = 1 - exp(-1 / (b.fastTimeConstant * Double(l) * fs))
    let slowA = 1 - exp(-1 / (b.slowTimeConstant * Double(l) * fs))
    let values = interpolated(x, oversampling: l)
    var fast = 0.0
    var slow = 0.0
    var out: [Double] = []
    var i = 0
    for length in periods {
      var top = 0.0
      for _ in 0..<length {
        let rf = r * fast
        let rs = r * slow
        fast = rf + fastA * values[i].reduce(0) { $0 + max(abs($1) - rf, 0) }
        slow = rs + slowA * values[i].reduce(0) { $0 + max(abs($1) - rs, 0) }
        top = max(top, b.fastWeight * fast + (1 - b.fastWeight) * slow)
        i += 1
      }
      out.append(top)
    }
    return out
  }

  static func filter(_ f: Biquad, _ x: [Double]) -> [Double] {
    var y = [Double](repeating: 0, count: x.count)
    var x1 = 0.0
    var x2 = 0.0
    var y1 = 0.0
    var y2 = 0.0
    for i in x.indices {
      y[i] = f.b0 * x[i] + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
      x2 = x1
      x1 = x[i]
      y2 = y1
      y1 = y[i]
    }
    return y
  }
}

final class ReferenceTests: XCTestCase {
  static let rates: [Double] = [44100, 48000, 96000, 192_000]

  /// A signal that charges, holds and releases: noise bursts, a sine with a
  /// crest on every grid offset, a step, silence and a full-scale fs/4 tone.
  private func program(_ fs: Double, seed: UInt64) -> [Float] {
    let n = Int(0.25 * fs)
    let noise = Signal.noise(amplitude: 0.8, frames: n, seed: seed)
    return (0..<n).map { i -> Float in
      let t = Double(i) / fs
      switch t {
      case ..<0.03: return noise[i] * Float(t / 0.03)
      case ..<0.08: return Float(0.7 * sin(2 * Double.pi * 3517 * t + 0.3))
      case ..<0.1: return 0.6
      case ..<0.15: return 0
      case ..<0.2: return Float(sin(Double.pi / 2 * Double(i) + Double.pi / 4))
      default: return noise[i] * 0.05
      }
    }
  }

  /// The meter is exactly Annex 2 (all four phases at 4x, phases 0 and 2 at
  /// 2x, the samples at 1x) with the sample peak as a floor.
  func testTruePeakMatchesAnnex2Reference() throws {
    for fs in Self.rates {
      for seed in [1, 2] as [UInt64] {
        let x = program(fs, seed: seed)
        let m = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, meters: [.samplePeak, .truePeak]))
        m.feed(Signal(sampleRate: fs, channels: [x]), blockSize: 300)
        let expected = dB(Reference.truePeak(x, sampleRate: fs))
        XCTAssertEqual(Double(m.snapshot()[0].truePeakMax), expected, accuracy: 1e-4, "\(fs) seed \(seed)")
      }
    }
  }

  /// Steady tones swept over 48 phases at 48 kHz: every reading is the
  /// Annex 2 reading and inside Tech 3341's -0.4 dB. Annex 2 itself reads up
  /// to +0.204 dB on fs/4 at some phases (its phases 1 and 2 have gain there);
  /// Tech 3341's +0.2 dB is set for its listed phases only. The even
  /// quarter-sample grid keeps the worst under-read of fs/4 and fs/8 small
  /// (the grid with x[n - 6] in place of phase 0 read -0.24 and -0.08 dB).
  /// The first 50 ms (an abrupt start, which really does overshoot) are
  /// excluded with a peak reset.
  func testTruePeakPhaseSweep() throws {
    let fs = 48000.0
    let settle = 2400
    let worstAllowed: [Double: Double] = [12000: -0.06, 6000: -0.03]
    for frequency in [12000.0, 16000, 8000, 6000, 4800, 19200] {
      var worst = 0.0
      var best = -Double.infinity
      for k in 0..<48 {
        let phase = Double(k) * 7.5
        let x = Signal.sine(frequency: frequency, dBFS: -6, seconds: 0.1, sampleRate: fs, phaseDegrees: phase)
        let m = try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, meters: [.samplePeak, .truePeak]))
        m.feed(Signal(sampleRate: fs, channels: [Array(x.prefix(settle))]))
        m.resetPeaks()
        m.feed(Signal(sampleRate: fs, channels: [Array(x.dropFirst(settle))]))
        let reading = Double(m.snapshot()[0].truePeakMax)
        let expected = dB(Reference.truePeak(x, sampleRate: fs, from: settle))
        XCTAssertEqual(reading, expected, accuracy: 1e-4, "\(frequency) Hz at \(phase)")
        XCTAssertLessThanOrEqual(reading, -6 + 0.21, "\(frequency) Hz at \(phase)")
        XCTAssertGreaterThanOrEqual(reading, -6 - 0.4, "\(frequency) Hz at \(phase)")
        worst = min(worst, reading + 6)
        best = max(best, reading + 6)
      }
      if let allowed = worstAllowed[frequency] { XCTAssertGreaterThan(worst, allowed, "\(frequency) Hz") }
      XCTAssertLessThan(best, 0.21)
    }
  }

  /// The PPM (block-skipping vDSP path, four channels per loop) reads the
  /// direct recursion times one calibration constant, at every publish.
  func testPPMMatchesDirectRecursion() throws {
    for fs in Self.rates {
      for type in [PPMType.typeI, .typeIIb] {
        let channels = 5
        let signal = Signal(sampleRate: fs, channels: (0..<channels).map { program(fs, seed: UInt64($0 + 10)) })
        let m = try AudioMeter(configuration: .init(
          sampleRate: fs, channelCount: channels, meters: [.ppm], ppmType: type))
        var periods: [Int] = []
        var readings: [[Double]] = []
        var offset = 0
        let sizes = [97, 256, 1000, 1, 513]
        let block = PlanarBlock(channelCount: channels, capacity: 1000)
        while offset < signal.frameCount {
          let n = min(sizes[periods.count % sizes.count], signal.frameCount - offset)
          block.fill(from: signal, offset: offset, count: n)
          m.process(planar: block.pointers, frameCount: n)
          let s = m.snapshot()
          readings.append((0..<channels).map { Double(s[$0].ppm) })
          periods.append(n)
          offset += n
        }
        for c in 0..<channels {
          let expected = Reference.ppmMaxima(
            signal.channels[c], sampleRate: fs, ballistics: type.ballistics, periods: periods)
          // The calibration (and alignment) is one constant offset in dB.
          let pairs = zip(readings.map { $0[c] }, expected).filter { $0.1 > 1e-4 }
          XCTAssertGreaterThan(pairs.count, periods.count / 2)
          let offsetDB = pairs[0].0 - dB(pairs[0].1)
          for (i, pair) in pairs.enumerated() {
            XCTAssertEqual(pair.0 - dB(pair.1), offsetDB, accuracy: 2e-4, "\(type) \(fs) channel \(c) publish \(i)")
          }
        }
      }
    }
  }

  /// The vDSP K-weighting reads exactly the direct biquad cascade: momentary
  /// loudness of noise against BS.1770-4 eq. 1-2 over the last 400 ms.
  func testKWeightingMatchesDirectFilter() throws {
    for fs in [8000.0, 44100, 48000, 96000] {
      // Whole 100 ms blocks, so the last tick ends on the last sample.
      let frames = Int((fs / 10).rounded()) * 13
      let left = Signal.noise(amplitude: 0.5, frames: frames, seed: 31)
      let right = Signal.noise(amplitude: 0.2, frames: frames, seed: 32)
      let m = try LoudnessMeter(sampleRate: fs, channels: [.left, .right])
      m.feed(Signal(sampleRate: fs, channels: [left, right]), blockSize: 777)
      let (shelf, highPass) = KWeighting.filters(sampleRate: fs)
      let window = Int((0.4 * fs).rounded())
      let energy = [left, right].map { x -> Double in
        let y = Reference.filter(highPass, Reference.filter(shelf, x.map(Double.init)))
        return y.suffix(window).reduce(0) { $0 + $1 * $1 } / Double(window)
      }.reduce(0, +)
      XCTAssertEqual(Double(m.snapshot().momentary), -0.691 + 10 * log10(energy), accuracy: 1e-4, "\(fs)")
    }
  }
}
