import Foundation
import MonitorKitAudio
import XCTest

/// VU (IEC 60268-17) and quasi-peak PPM (IEC 60268-10) dynamics.
final class BallisticsTests: XCTestCase {
  static let rates: [Double] = [44100, 48000, 96000, 192_000]

  private func vuMeter(_ fs: Double, reference: AlignmentLevel = .ebu) throws -> AudioMeter {
    try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, meters: [.vu], vuReference: reference))
  }

  /// (time, linear deflection) after every block of about 1 ms.
  private func trace(_ meter: AudioMeter, _ signal: Signal, start: Double = 0, _ read: @escaping (AudioChannelLevels) -> Float)
    -> [(Double, Double)]
  {
    let block = Int((signal.sampleRate / 1000).rounded())
    var t = start
    var out: [(Double, Double)] = []
    meter.feed(signal, blockSize: block) { s in
      t += Double(block) / signal.sampleRate
      out.append((t, pow(10, Double(read(s[0])) / 20)))
    }
    return out
  }

  func testVUStepResponse() throws {
    for fs in Self.rates {
      let m = try vuMeter(fs)
      let rise = trace(m, .tone(dBFS: -18, seconds: 1.5, sampleRate: fs, channels: 1)) { $0.vu }
      let reach = try XCTUnwrap(rise.first { $0.1 >= 0.99 }).0
      // 300 ms +/- 10 %.
      XCTAssertEqual(reach, 0.3, accuracy: 0.03, "rise at \(fs)")
      XCTAssertEqual(reach, 0.3, accuracy: 0.005, "design rise at \(fs)")
      let overshoot = rise.map(\.1).max()! - 1
      XCTAssertGreaterThanOrEqual(overshoot, 0.01, "overshoot at \(fs)")
      XCTAssertLessThanOrEqual(overshoot, 0.015, "overshoot at \(fs)")
      XCTAssertEqual(Double(m.snapshot()[0].vu), 0, accuracy: 0.02, "0 VU at \(fs)")

      // The return mirrors the rise: 1 % of the reference deflection after 300 ms.
      let fall = trace(m, .silence(seconds: 1, sampleRate: fs, channels: 1), start: 1.5) { $0.vu }
      let drop = try XCTUnwrap(fall.first { $0.1 <= 0.01 }).0 - 1.5
      XCTAssertEqual(drop, 0.3, accuracy: 0.03, "fall at \(fs)")
    }
  }

  func testVUReferenceLevels() throws {
    let fs = 48000.0
    for (reference, tone, expected) in [(AlignmentLevel.ebu, -18.0, 0.0), (.smpte, -20, 0), (.ebu, -8, 10), (.smpte, -23, -3)] {
      let m = try vuMeter(fs, reference: reference)
      m.feed(.tone(dBFS: tone, seconds: 2, sampleRate: fs, channels: 1))
      XCTAssertEqual(Double(m.snapshot()[0].vu), expected, accuracy: 0.02)
    }
    // Average-responding: a square wave of the same peak reads pi / (2 sqrt 2) higher, +0.91 dB.
    let m = try vuMeter(fs)
    let a = Float(Signal.amplitude(-18))
    let square = (0..<96000).map { ($0 / 24) % 2 == 0 ? a : -a }
    m.feed(Signal(sampleRate: fs, channels: [square]))
    XCTAssertEqual(Double(m.snapshot()[0].vu), dB(Double.pi / 2), accuracy: 0.02)
  }

  private func ppmMeter(_ fs: Double, _ type: PPMType) throws -> AudioMeter {
    try AudioMeter(configuration: .init(sampleRate: fs, channelCount: 1, meters: [.ppm], ppmType: type))
  }

  /// Highest PPM reading for `signal`, in dB relative to alignment.
  private func maxReading(_ meter: AudioMeter, _ signal: Signal) -> Double {
    var m = -Double.infinity
    meter.feed(signal, blockSize: 64) { m = max(m, Double($0[0].ppm)) }
    return m
  }

  /// IEC 60268-10 tone-burst under-reading, 5 kHz at reference level.
  func testPPMToneBursts() throws {
    let table: [PPMType: [(ms: Double, dB: Double, tolerance: Double)]] = [
      .typeI: [(100, 0, 0.5), (10, -1, 0.5), (5, -2, 0.5), (3, -4, 1), (0.4, -15, 2)],
      .typeIIa: [(100, 0, 0.5), (10, -2, 0.5), (5, -4, 0.75), (1.5, -9, 1), (0.5, -17, 2)],
    ]
    for fs in Self.rates {
      for (type, rows) in table {
        let steady = try ppmMeter(fs, type)
        steady.feed(Signal(sampleRate: fs, channels: [Signal.sine(frequency: 5000, dBFS: -18, seconds: 1, sampleRate: fs)]))
        let reference = Double(steady.snapshot()[0].ppm)
        // The Annex 2 interpolator peaks by up to 0.2 dB around 5 kHz.
        XCTAssertEqual(reference, 0, accuracy: 0.25, "steady \(type) at \(fs)")
        for row in rows {
          let m = try ppmMeter(fs, type)
          let burst = Signal.sine(frequency: 5000, dBFS: -18, seconds: row.ms / 1000, sampleRate: fs)
          let signal = Signal(sampleRate: fs, channels: [burst]).appending(.silence(seconds: 0.2, sampleRate: fs, channels: 1))
          let under = maxReading(m, signal) - reference
          XCTAssertEqual(under, row.dB, accuracy: row.tolerance, "\(type) \(row.ms) ms at \(fs)")
        }
      }
    }
  }

  func testPPMReturnTimes() throws {
    for fs in Self.rates {
      for (type, drop, seconds) in [(PPMType.typeI, 20.0, 1.5), (.typeIIa, 24, 2.8), (.typeIIb, 24, 2.8)] {
        let m = try ppmMeter(fs, type)
        m.feed(.tone(dBFS: -18, seconds: 1, sampleRate: fs, channels: 1))
        let start = Double(m.snapshot()[0].ppm)
        let fall = trace(m, .silence(seconds: 3.5, sampleRate: fs, channels: 1)) { $0.ppm }
        let t = try XCTUnwrap(fall.first { dB($0.1) <= start - drop }).0
        // IEC 60268-10 allows +/- 0.3 s.
        XCTAssertEqual(t, seconds, accuracy: 0.02, "\(type) at \(fs)")
      }
    }
  }

  /// Calibrated at 1 kHz; above a few kHz the reading follows the Annex 2
  /// interpolator's ripple and phase-locked under-read (Tech 3341 allows +0.2/-0.4).
  func testPPMFrequencyResponseIsFlat() throws {
    for fs in Self.rates {
      for (hz, tolerance) in [(31.5, 0.1), (100, 0.05), (1000, 0.05), (3000, 0.25), (5000, 0.25), (8000, 0.3), (10000, 0.25), (15000, 0.3)] {
        let m = try ppmMeter(fs, .typeIIb)
        m.feed(Signal(sampleRate: fs, channels: [Signal.sine(frequency: hz, dBFS: -18, seconds: 1, sampleRate: fs, phaseDegrees: 11)]))
        XCTAssertEqual(Double(m.snapshot()[0].ppm), 0, accuracy: tolerance, "\(hz) Hz at \(fs)")
      }
    }
    // -20 dBFS alignment.
    let m = try AudioMeter(configuration: .init(
      sampleRate: 48000, channelCount: 1, meters: [.ppm], ppmAlignment: .smpte))
    m.feed(.tone(dBFS: -12, seconds: 1, sampleRate: 48000, channels: 1))
    XCTAssertEqual(Double(m.snapshot()[0].ppm), 8, accuracy: 0.1)
    XCTAssertEqual(m.snapshot().ppmAlignmentDBFS, -20)
  }

  func testCustomPPMBallistics() throws {
    // The Nordic variant: Type I charge, 20 dB in 1.7 s.
    var nordic = PPMBallistics.typeI
    nordic.returnRate = 20 / 1.7
    let fs = 48000.0
    let m = try AudioMeter(configuration: .init(
      sampleRate: fs, channelCount: 1, meters: [.ppm], ppmType: .typeI, customPPMBallistics: nordic))
    m.feed(.tone(dBFS: -18, seconds: 1, sampleRate: fs, channels: 1))
    XCTAssertEqual(Double(m.snapshot()[0].ppm), 0, accuracy: 0.05)
    let fall = trace(m, .silence(seconds: 2.5, sampleRate: fs, channels: 1)) { $0.ppm }
    let t = try XCTUnwrap(fall.first { dB($0.1) <= -20 }).0
    XCTAssertEqual(t, 1.7, accuracy: 0.02)

    var broken = nordic
    broken.fastTimeConstant = 1e-6
    XCTAssertThrowsError(try AudioMeter(configuration: .init(
      sampleRate: fs, channelCount: 1, customPPMBallistics: broken)))
  }

  func testPPMScales() {
    XCTAssertEqual(PPMType.typeIIa.scaleReading(dBRelativeToAlignment: 0), 4)
    XCTAssertEqual(PPMType.typeIIa.scaleReading(dBRelativeToAlignment: 8), 6)
    XCTAssertEqual(PPMType.typeIIa.scaleReading(dBRelativeToAlignment: -12), 1)
    XCTAssertEqual(PPMType.typeIIb.scaleReading(dBRelativeToAlignment: 9), 9)
    XCTAssertEqual(PPMType.typeI.scaleReading(dBRelativeToAlignment: 0), -9)
    XCTAssertEqual(PPMType.typeI.scaleReading(dBRelativeToAlignment: 9), 0)
  }

  func testVUBallisticsDesign() {
    let b = VUBallistics.iec60268_17
    let zeta = b.dampingRatio
    XCTAssertEqual(exp(-Double.pi * zeta / (1 - zeta * zeta).squareRoot()), 0.0125, accuracy: 1e-12)
    // Analytic step response at 300 ms.
    let w = b.naturalFrequency
    let wd = w * (1 - zeta * zeta).squareRoot()
    let y = 1 - exp(-zeta * w * 0.3) * (cos(wd * 0.3) + zeta * w / wd * sin(wd * 0.3))
    XCTAssertEqual(y, 0.99, accuracy: 1e-9)
  }
}
