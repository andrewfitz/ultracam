import Foundation
import MonitorKitAudio
import XCTest

/// EBU Tech 3341 (2023) and Tech 3342 (2023) minimum-requirements cases,
/// synthesized here, at 44.1, 48 and 96 kHz.
final class LoudnessTests: XCTestCase {
  static let rates: [Double] = [44100, 48000, 96000]

  func testKWeightingMatchesBS1770ReferenceCoefficientsAt48k() {
    let (shelf, highPass) = KWeighting.filters(sampleRate: 48000)
    // ITU-R BS.1770-4 Annex 1, Tables 1 and 2.
    XCTAssertEqual(shelf.b0, 1.53512485958697, accuracy: 1e-12)
    XCTAssertEqual(shelf.b1, -2.69169618940638, accuracy: 1e-12)
    XCTAssertEqual(shelf.b2, 1.19839281085285, accuracy: 1e-12)
    XCTAssertEqual(shelf.a1, -1.69065929318241, accuracy: 1e-12)
    XCTAssertEqual(shelf.a2, 0.73248077421585, accuracy: 1e-12)
    XCTAssertEqual(highPass.b0, 1)
    XCTAssertEqual(highPass.b1, -2)
    XCTAssertEqual(highPass.b2, 1)
    XCTAssertEqual(highPass.a1, -1.99004745483398, accuracy: 1e-12)
    XCTAssertEqual(highPass.a2, 0.99007225036621, accuracy: 1e-12)
  }

  func testKWeightingResponseIsRateIndependent() {
    let reference = KWeighting.filters(sampleRate: 48000)
    func gain(_ f: (shelf: Biquad, highPass: Biquad), _ hz: Double, _ fs: Double) -> Double {
      dB(f.shelf.gain(at: hz, sampleRate: fs) * f.highPass.gain(at: hz, sampleRate: fs))
    }
    for fs in [8000.0, 11025, 16000, 22050, 32000, 44100, 88200, 96000, 192_000, 768_000] {
      let f = KWeighting.filters(sampleRate: fs)
      for hz in [20.0, 38, 100, 500, 1000, 2000, 5000, 10000] where hz <= fs / 4 {
        let error = gain(f, hz, fs) - gain(reference, hz, 48000)
        // The high-pass's passband gain is the same at every rate, so at low
        // frequencies the response is the 48 kHz one; the matched shelf stays
        // within 0.04 dB at 8 kHz (bilinear: 0.2 dB), the bilinear one above
        // 48 kHz within 0.006 dB.
        XCTAssertEqual(error, 0, accuracy: hz <= 100 ? 0.002 : 0.04, "\(fs) Hz at \(hz) Hz")
        if fs >= 16000 { XCTAssertEqual(error, 0, accuracy: 0.006, "\(fs) Hz at \(hz) Hz") }
      }
      // The passband gain itself: Table 2's a0 at 48 kHz, at every rate.
      XCTAssertEqual(
        f.highPass.gain(at: fs / 2, sampleRate: fs), reference.highPass.gain(at: 24000, sampleRate: 48000),
        accuracy: 1e-12, "\(fs)")
    }
  }

  /// The tones of Tech 3341 cases 1 and 2 at the low rates the meters accept.
  func testLowSampleRatesReadTheSameLoudness() throws {
    for fs in [8000.0, 11025, 16000, 22050, 32000] {
      for hz in [100.0, 1000] {
        let m = try meter(fs)
        m.feed(.tone(frequency: hz, dBFS: -23, seconds: 4, sampleRate: fs))
        let reference = try meter(48000)
        reference.feed(.tone(frequency: hz, dBFS: -23, seconds: 4, sampleRate: 48000))
        // Unscaled high-pass numerator and bilinear shelf: 0.22 LU and 0.2 LU off at 8 kHz.
        XCTAssertEqual(m.snapshot().integrated, reference.snapshot().integrated, accuracy: 0.04, "\(hz) Hz at \(fs)")
      }
    }
  }

  private func meter(_ fs: Double, _ channels: [LoudnessChannel] = [.left, .right]) throws -> LoudnessMeter {
    try LoudnessMeter(sampleRate: fs, channels: channels)
  }

  // Tech 3341 cases 1 and 2.
  func testCase1And2SteadyToneReadsLevel() throws {
    for fs in Self.rates {
      for level in [-23.0, -33.0] {
        let m = try meter(fs)
        m.feed(.tone(dBFS: level, seconds: 20, sampleRate: fs))
        let s = m.snapshot()
        XCTAssertEqual(Double(s.momentary), level, accuracy: 0.1, "M \(fs)")
        XCTAssertEqual(Double(s.shortTerm), level, accuracy: 0.1, "S \(fs)")
        XCTAssertEqual(Double(s.integrated), level, accuracy: 0.1, "I \(fs)")
        XCTAssertEqual(s.duration, 20, accuracy: 1e-9)
        XCTAssertEqual(Double(s.loudnessRange), 0, accuracy: 0.1)
      }
    }
  }

  // Tech 3341 cases 3, 4 and 5: relative and absolute gating.
  func testCases3To5Gating() throws {
    let cases: [[(dBFS: Double?, seconds: Double)]] = [
      [(-36, 10), (-23, 60), (-36, 10)],
      [(-72, 10), (-36, 10), (-23, 60), (-36, 10), (-72, 10)],
      [(-26, 20), (-20, 20.1), (-26, 20)],
    ]
    for fs in Self.rates {
      for (i, segments) in cases.enumerated() {
        let m = try meter(fs)
        m.feed(.toneSequence(segments, sampleRate: fs), blockSize: 1024)
        XCTAssertEqual(Double(m.snapshot().integrated), -23, accuracy: 0.1, "case \(i + 3) at \(fs)")
      }
    }
  }

  // Tech 3341 case 6: 5.0 channel weights (Ls/Rs 1.41).
  func testCase6SurroundWeights() throws {
    for fs in Self.rates {
      let levels: [Double] = [-28, -28, -24, -30, -30]
      let channels = levels.map { Signal.sine(frequency: 1000, dBFS: $0, seconds: 20, sampleRate: fs) }
      let m = try LoudnessMeter(sampleRate: fs, channelCount: 5)
      m.feed(Signal(sampleRate: fs, channels: channels))
      XCTAssertEqual(Double(m.snapshot().integrated), -23, accuracy: 0.1, "\(fs)")
    }
  }

  func testLFEIsExcludedIn51() throws {
    let fs = 48000.0
    let levels: [Double?] = [-28, -28, -24, 0, -30, -30]
    let channels = levels.map { level in
      level.map { Signal.sine(frequency: 1000, dBFS: $0, seconds: 5, sampleRate: fs) }
        ?? [Float](repeating: 0, count: Int(5 * fs))
    }
    let m = try LoudnessMeter(sampleRate: fs, channelCount: 6)
    m.feed(Signal(sampleRate: fs, channels: channels))
    XCTAssertEqual(Double(m.snapshot().integrated), -23, accuracy: 0.1)
  }

  // Tech 3341 case 9: short-term constant after 3 s.
  func testCase9ShortTermIsConstant() throws {
    for fs in Self.rates {
      let m = try meter(fs)
      let period: [(dBFS: Double?, seconds: Double)] = [(-20, 1.34), (-30, 1.66)]
      let signal = Signal.toneSequence(Array(repeating: period, count: 5).flatMap { $0 }, sampleRate: fs)
      var checked = 0
      m.feed(signal, blockSize: 480) { s in
        guard s.duration >= 3.01 else { return }
        XCTAssertEqual(Double(s.shortTerm), -23, accuracy: 0.1, "\(fs) at \(s.duration)")
        checked += 1
      }
      XCTAssertGreaterThan(checked, 100)
    }
  }

  // Tech 3341 case 11 ("live" form of case 10): maximum short-term per tone.
  func testCase11ShortTermMaxima() throws {
    for fs in Self.rates {
      let m = try meter(fs)
      for i in 0..<20 {
        let silence = Double(i) * 0.15
        m.feed(
          .toneSequence([(nil, silence), (-38 + Double(i), 3), (nil, 3 - silence)], sampleRate: fs),
          blockSize: 1000)
        XCTAssertEqual(Double(m.snapshot().shortTermMax), -38 + Double(i), accuracy: 0.1, "tone \(i) at \(fs)")
      }
    }
  }

  // Tech 3341 case 12: momentary constant after 1 s.
  func testCase12MomentaryIsConstant() throws {
    for fs in Self.rates {
      let m = try meter(fs)
      let period: [(dBFS: Double?, seconds: Double)] = [(-20, 0.18), (-30, 0.22)]
      let signal = Signal.toneSequence(Array(repeating: period, count: 25).flatMap { $0 }, sampleRate: fs)
      var checked = 0
      m.feed(signal, blockSize: 256) { s in
        guard s.duration >= 1 else { return }
        XCTAssertEqual(Double(s.momentary), -23, accuracy: 0.1, "\(fs) at \(s.duration)")
        checked += 1
      }
      XCTAssertGreaterThan(checked, 100)
    }
  }

  // Tech 3341 case 14 ("live" form of case 13): maximum momentary per tone.
  func testCase14MomentaryMaxima() throws {
    for fs in Self.rates {
      let m = try meter(fs)
      for i in 0..<20 {
        let silence = Double(i) * 0.02
        m.feed(
          .toneSequence([(nil, silence), (-38 + Double(i), 0.4), (nil, 0.4 - silence)], sampleRate: fs),
          blockSize: 333)
        XCTAssertEqual(Double(m.snapshot().momentaryMax), -38 + Double(i), accuracy: 0.1, "tone \(i) at \(fs)")
      }
    }
  }

  func testMomentaryAndShortTermWaitForFullWindows() throws {
    let fs = 48000.0
    let m = try meter(fs)
    m.feed(.tone(dBFS: -23, seconds: 0.39, sampleRate: fs))
    XCTAssertEqual(m.snapshot().momentary, -.infinity)
    m.feed(.tone(dBFS: -23, seconds: 0.02, sampleRate: fs))
    XCTAssertEqual(Double(m.snapshot().momentary), -23, accuracy: 0.1)
    XCTAssertEqual(m.snapshot().shortTerm, -.infinity)
    m.feed(.tone(dBFS: -23, seconds: 2.6, sampleRate: fs))
    XCTAssertEqual(Double(m.snapshot().shortTerm), -23, accuracy: 0.1)
  }

  func testSilenceStaysUngated() throws {
    let m = try meter(48000)
    m.feed(.silence(seconds: 5, sampleRate: 48000))
    let s = m.snapshot()
    XCTAssertEqual(s.integrated, -.infinity)
    XCTAssertEqual(s.momentary, -.infinity)
    XCTAssertEqual(s.loudnessRange, 0)
  }

  // Tech 3342 cases 1-4.
  func testTech3342LoudnessRange() throws {
    let cases: [(levels: [Double], lra: Double)] = [
      ([-20, -30], 10), ([-20, -15], 5), ([-40, -20], 20), ([-50, -35, -20, -35, -50], 15),
    ]
    for fs in Self.rates {
      for (i, c) in cases.enumerated() {
        let m = try meter(fs)
        m.feed(.toneSequence(c.levels.map { ($0, 20) }, sampleRate: fs), blockSize: 2048)
        // The standard allows +/- 1 LU; pure tones land within the 0.02 LU bins.
        XCTAssertEqual(Double(m.snapshot().loudnessRange), c.lra, accuracy: 0.05, "case \(i + 1) at \(fs)")
      }
    }
  }

  func testMonoAndSixteenChannelSums() throws {
    let fs = 48000.0
    let mono = try LoudnessMeter(sampleRate: fs, channelCount: 1)
    mono.feed(.tone(dBFS: -23, seconds: 5, sampleRate: fs, channels: 1))
    XCTAssertEqual(Double(mono.snapshot().integrated), -23 - 10 * log10(2), accuracy: 0.1)

    // 16 front channels of weight 1, each at -23 - 9.03 dBFS, sum to -23 LUFS.
    let wide = try LoudnessMeter(sampleRate: fs, channelCount: 16)
    let level = -23 - 10 * log10(8.0)
    wide.feed(.tone(dBFS: level, seconds: 5, sampleRate: fs, channels: 16))
    XCTAssertEqual(Double(wide.snapshot().integrated), -23, accuracy: 0.1)

    // Excluded channels contribute nothing.
    var layout = [LoudnessChannel](repeating: .excluded, count: 16)
    layout[4] = .left
    layout[5] = .right
    let pair = try LoudnessMeter(sampleRate: fs, channels: layout)
    var signal = Signal.silence(seconds: 5, sampleRate: fs, channels: 16)
    for c in 0..<16 { signal.channels[c] = Signal.sine(frequency: 1000, dBFS: c == 4 || c == 5 ? -23 : -6, seconds: 5, sampleRate: fs) }
    pair.feed(signal)
    XCTAssertEqual(Double(pair.snapshot().integrated), -23, accuracy: 0.1)
  }

  func testBlockSizeDoesNotChangeResults() throws {
    let fs = 48000.0
    var signal = Signal(sampleRate: fs, channels: [
      Signal.noise(amplitude: 0.3, frames: Int(7 * fs), seed: 1),
      Signal.noise(amplitude: 0.1, frames: Int(7 * fs), seed: 2),
    ])
    signal = signal.appending(.toneSequence([(-30, 2)], sampleRate: fs))
    var results: [LoudnessSnapshot] = []
    for block in [1, 37, 512, 4096] {
      let m = try meter(fs)
      m.feed(signal, blockSize: block)
      results.append(m.snapshot())
    }
    for r in results.dropFirst() {
      XCTAssertEqual(r.integrated, results[0].integrated, accuracy: 1e-4)
      XCTAssertEqual(r.momentary, results[0].momentary, accuracy: 1e-4)
      XCTAssertEqual(r.shortTerm, results[0].shortTerm, accuracy: 1e-4)
      XCTAssertEqual(r.loudnessRange, results[0].loudnessRange, accuracy: 1e-4)
      XCTAssertEqual(r.momentaryMax, results[0].momentaryMax, accuracy: 1e-4)
    }
  }

  /// White noise through the K filter: integrated equals a direct CPU
  /// evaluation of BS.1770-4 eqs. 1-7 over stored blocks.
  func testNoiseMatchesDirectReferenceImplementation() throws {
    let fs = 48000.0
    let frames = Int(12 * fs)
    let left = Signal.noise(amplitude: 0.5, frames: frames, seed: 7)
    // A level change in the middle exercises the relative gate.
    var right = Signal.noise(amplitude: 0.5, frames: frames, seed: 8)
    for i in (frames / 2)..<frames { right[i] *= 0.02 }
    let m = try meter(fs)
    m.feed(Signal(sampleRate: fs, channels: [left, right]), blockSize: 1000)
    let expected = Self.referenceIntegrated([left, right], weights: [1, 1], sampleRate: fs)
    XCTAssertEqual(Double(m.snapshot().integrated), expected, accuracy: 0.02)
  }

  /// BS.1770-4 integrated loudness evaluated directly (sorted-free, every block stored).
  static func referenceIntegrated(_ channels: [[Float]], weights: [Double], sampleRate fs: Double) -> Double {
    let (shelf, hp) = KWeighting.filters(sampleRate: fs)
    func run(_ f: Biquad, _ x: [Double]) -> [Double] {
      var y = [Double](repeating: 0, count: x.count)
      var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
      for i in x.indices {
        y[i] = f.b0 * x[i] + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
        x2 = x1; x1 = x[i]; y2 = y1; y1 = y[i]
      }
      return y
    }
    let filtered = channels.map { run(hp, run(shelf, $0.map(Double.init))) }
    let block = Int(0.4 * fs)
    let step = Int(0.1 * fs)
    var energies: [Double] = []
    var start = 0
    while start + block <= filtered[0].count {
      var e = 0.0
      for (c, y) in filtered.enumerated() {
        var z = 0.0
        for i in start..<(start + block) { z += y[i] * y[i] }
        e += weights[c] * z / Double(block)
      }
      energies.append(e)
      start += step
    }
    func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(e) }
    let absolute = energies.filter { lufs($0) > -70 }
    let gate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
    let relative = absolute.filter { lufs($0) > gate }
    return lufs(relative.reduce(0, +) / Double(relative.count))
  }

  func testResetMeasurementStartsOver() throws {
    let fs = 48000.0
    let m = try meter(fs)
    m.feed(.tone(dBFS: -10, seconds: 5, sampleRate: fs))
    m.resetMeasurement()
    m.feed(.tone(dBFS: -30, seconds: 5, sampleRate: fs))
    let s = m.snapshot()
    XCTAssertEqual(Double(s.integrated), -30, accuracy: 0.1)
    XCTAssertEqual(Double(s.momentaryMax), -30, accuracy: 0.1)
    XCTAssertEqual(s.duration, 5, accuracy: 1e-9)
  }

  func testInvalidConfigurationsThrow() {
    XCTAssertThrowsError(try LoudnessMeter(sampleRate: 1000, channelCount: 2))
    XCTAssertThrowsError(try LoudnessMeter(sampleRate: 48000, channelCount: 0))
    XCTAssertThrowsError(try LoudnessMeter(sampleRate: 48000, channelCount: 17))
    XCTAssertThrowsError(try LoudnessMeter(sampleRate: 48000, channels: [.weighted(-1)]))
    XCTAssertThrowsError(
      try AudioMeter(configuration: .init(sampleRate: 48000, channelCount: 2, loudnessChannels: [.left])))
  }
}
