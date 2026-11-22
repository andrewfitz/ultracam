// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import MonitorKitAudio
import XCTest

final class Fresh15LoudnessPrecisionTests: XCTestCase {
  func testBiquadGainScalesOverflowingComponents() {
    let m = Double.greatestFiniteMagnitude
    // At DC these real polynomials reduce analytically to ratios of sums.
    // The added denominator one is below one ulp of m, so these references
    // round exactly to one and one half without any overflowing arithmetic.
    XCTAssertEqual(Biquad(b0: m, b1: m, b2: 0, a1: m, a2: m).gain(at: 0, sampleRate: 48000), 1)
    XCTAssertEqual(Biquad(b0: m, b1: 0, b2: 0, a1: m, a2: m).gain(at: 0, sampleRate: 48000), 0.5)
    XCTAssertEqual(Biquad(b0: m, b1: m, b2: 0, a1: m, a2: 0).gain(at: 0, sampleRate: 48000), 2)
    // All three numerator coefficients are identical to the denominator,
    // including a0=1: H(z)=1 at every frequency, even when hypot overflows.
    let identity = Biquad(b0: 1, b1: m, b2: m, a1: m, a2: m)
    for frequency in [0.0, 997, 6000, 12000, 20000] {
      XCTAssertEqual(identity.gain(at: frequency, sampleRate: 48000), 1, accuracy: 1e-14)
    }
  }

  private func oldWeightedEnergy(
    _ energies: UnsafeMutablePointer<Double>, weights: UnsafePointer<Double>, scale: Double, count: Int
  ) -> Double {
    var result = 0.0
    forEachIndex(count) { c in
      result += weights[c] <= 1 ? (energies[c] * weights[c]) / scale : energies[c] * (weights[c] / scale)
      energies[c] = 0
    }
    return result
  }

  func testWeightingKernelMatchesPreviousArithmeticAndBenchmarks() {
    let values = [1e-80, 1e-6, 1.0, 1e15]
    for rawWeights in [[1.0, 1, 1, 1], [1, 1.41, 1.41, 1], [1e-300, 1, 1e100, Double.greatestFiniteMagnitude]] {
      let scale = max(1, rawWeights.max()!.squareRoot())
      let old = UnsafeMutablePointer<Double>.allocate(capacity: values.count)
      let new = UnsafeMutablePointer<Double>.allocate(capacity: values.count)
      old.initialize(repeating: 0, count: values.count)
      new.initialize(repeating: 0, count: values.count)
      defer { old.deallocate(); new.deallocate() }
      rawWeights.withUnsafeBufferPointer { weights in
        values.withUnsafeBufferPointer { source in
          var oldTotal = 0.0
          var newTotal = 0.0
          let rounds = 100_000
          var iteration = 0
          let oldStart = Date.timeIntervalSinceReferenceDate
          while iteration < rounds {
            old.update(from: source.baseAddress!, count: values.count)
            oldTotal += oldWeightedEnergy(old, weights: weights.baseAddress!, scale: scale, count: values.count)
            iteration += 1
          }
          let oldTime = Date.timeIntervalSinceReferenceDate - oldStart
          iteration = 0
          let newStart = Date.timeIntervalSinceReferenceDate
          while iteration < rounds {
            new.update(from: source.baseAddress!, count: values.count)
            newTotal += weightedTickEnergy(new, weights: weights.baseAddress!, scale: scale, channelCount: values.count)
            iteration += 1
          }
          let newTime = Date.timeIntervalSinceReferenceDate - newStart
          XCTAssertEqual(newTotal, oldTotal)
          for c in 0..<values.count { XCTAssertEqual(new[c], 0) }
          print("BENCH Fresh15 weighted tick scale=\(scale) old=\(oldTime) s new=\(newTime) s rounds=\(rounds)")
        }
      }
    }
  }

  func testSparseHistogramPercentilesMatchOracleAndBenchmark() {
    let histogram = LoudnessHistogram(storesEnergy: false)
    defer { histogram.deallocate() }
    // Both levels pass the -20 LU gate (their mean is about -12.97).
    // Equal populations give P10=-30 and P95=-10, independently of bins.
    for _ in 0..<100 {
      histogram.add(loudness: -30, energy: pow(10, (-30 + 0.691) / 10))
      histogram.add(loudness: -10, energy: pow(10, (-10 + 0.691) / 10))
    }
    XCTAssertEqual(histogram.loudnessRange(), 20, accuracy: 1e-12)
    let t = histogram.totals.pointee
    func previousPercentiles() -> Double {
      var n = 0
      forEachIndex(t.highBin - t.lowBin + 1) { n += Int(histogram.counts[t.lowBin + $0]) }
      let lowRank = Int((Double(n - 1) * 0.10).rounded())
      let highRank = Int((Double(n - 1) * 0.95).rounded())
      var cumulative = 0
      var low = Double.nan
      var b = t.lowBin
      while b <= t.highBin {
        cumulative += Int(histogram.counts[b])
        let center = LoudnessHistogram.floor + (Double(b) + 0.5) * LoudnessHistogram.binWidth
        if low.isNaN, cumulative > lowRank { low = center }
        if cumulative > highRank { return center - low }
        b += 1
      }
      return 0
    }
    var previous = 0.0
    var current = 0.0
    let rounds = 1000
    var i = 0
    let oldStart = Date.timeIntervalSinceReferenceDate
    while i < rounds { previous += previousPercentiles(); i += 1 }
    let oldTime = Date.timeIntervalSinceReferenceDate - oldStart
    i = 0
    let newStart = Date.timeIntervalSinceReferenceDate
    while i < rounds { current += histogram.loudnessRange(); i += 1 }
    let newTime = Date.timeIntervalSinceReferenceDate - newStart
    XCTAssertEqual(current, previous)
    print("BENCH Fresh15 sparse LRA old=\(oldTime) s new=\(newTime) s rounds=\(rounds)")
  }

  func testExtremeWeightHistogramCoversTheRestoredLoudness() throws {
    let fs = 8000.0
    let signal = Signal.toneSequence([(-30, 8), (-10, 8), (-30, 8)], sampleRate: fs, channels: 1)
    let baseline = try LoudnessMeter(sampleRate: fs, channels: [.weighted(1)])
    let weighted = try LoudnessMeter(sampleRate: fs, channels: [.weighted(.greatestFiniteMagnitude)])
    baseline.feed(signal)
    weighted.feed(signal)
    XCTAssertEqual(weighted.snapshot().loudnessRange, baseline.snapshot().loudnessRange, accuracy: 0.101)
    XCTAssertEqual(
      Double(weighted.snapshot().integrated) - Double(baseline.snapshot().integrated),
      10 * log10(Double.greatestFiniteMagnitude), accuracy: 0.002)
  }

  func testSilentExtremeWeightPreservesQuietSlidingLoudness() throws {
    let fs = 8000.0
    for level in [-200.0, -700.0] {
      let signal = Signal(sampleRate: fs, channels: [
        Array(repeating: 0, count: Int(4 * fs)),
        Signal.sine(frequency: 1000, dBFS: level, seconds: 4, sampleRate: fs),
      ])
      let baseline = try LoudnessMeter(sampleRate: fs, channels: [.excluded, .weighted(1)])
      let weighted = try LoudnessMeter(sampleRate: fs, channels: [.weighted(.greatestFiniteMagnitude), .weighted(1)])
      baseline.feed(signal)
      weighted.feed(signal)
      let reference = baseline.snapshot()
      let actual = weighted.snapshot()
      // M and S are ungated, so these finite Float32 tones must remain
      // measurable even though they are below the integrated absolute gate.
      XCTAssertTrue(reference.momentary.isFinite)
      XCTAssertTrue(reference.shortTerm.isFinite)
      XCTAssertEqual(actual.momentary, reference.momentary, accuracy: 0.002)
      XCTAssertEqual(actual.shortTerm, reference.shortTerm, accuracy: 0.002)
      XCTAssertEqual(actual.momentaryMax, reference.momentaryMax, accuracy: 0.002)
      XCTAssertEqual(actual.shortTermMax, reference.shortTermMax, accuracy: 0.002)
      XCTAssertEqual(actual.integrated, -.infinity)
    }
  }
}
