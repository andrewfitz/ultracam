// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import MonitorKitAudio
import XCTest

final class LoudnessWideDomainRegressionTests: XCTestCase {
  /// Exact block storage, independent of the production histogram's grid.
  private func reference(_ levels: [Double], relativeGate: Double) -> [Double] {
    let absolute = levels.filter { $0 > -70 }
    let peak = absolute.max()!
    let mean = absolute.map { pow(10, ($0 - peak) / 10) }.reduce(0, +) / Double(absolute.count)
    let threshold = peak + 10 * log10(mean) + relativeGate
    return absolute.filter { $0 > threshold }.sorted()
  }

  func testHighLevelHistogramMatchesStoredBlockReference() {
    for shift in [0.0, 80, 3050] {
      let levels = Array(repeating: [-50.0, -20, -10, -5], count: 100).flatMap { $0 }.map { $0 + shift }
      let histogram = LoudnessHistogram(storesEnergy: true, energyLoudnessOffset: shift, maximumLoudness: 150 + shift)
      defer { histogram.deallocate() }
      for level in levels {
        histogram.add(loudness: level, energy: pow(10, (level - shift + 0.691) / 10))
      }
      let integratedBlocks = reference(levels, relativeGate: -10)
      let expectedEnergy = integratedBlocks.map { pow(10, ($0 - shift + 0.691) / 10) }.reduce(0, +) / Double(integratedBlocks.count)
      XCTAssertEqual(histogram.gatedMeanEnergy(), expectedEnergy, accuracy: expectedEnergy * 1e-12)
      let rangeBlocks = reference(levels, relativeGate: -20)
      let low = Int((Double(rangeBlocks.count - 1) * 0.10).rounded())
      let high = Int((Double(rangeBlocks.count - 1) * 0.95).rounded())
      XCTAssertEqual(histogram.loudnessRange(), rangeBlocks[high] - rangeBlocks[low], accuracy: shift > 150 ? 0.101 : 0.021)
    }
  }

  func testSupportedOverrangeAudioMatchesDirectIntegratedReference() throws {
    let fs = 8000.0
    let signal = Signal.toneSequence([(40, 8), (60, 8), (40, 8)], sampleRate: fs)
    let meter = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    meter.feed(signal)
    let expected = LoudnessTests.referenceIntegrated(signal.channels, weights: [1, 1], sampleRate: fs)
    XCTAssertEqual(Double(meter.snapshot().integrated), expected, accuracy: 0.021)
    // Eight-second plateaus leave over 10% of the complete 3 s windows
    // entirely at 40 LUFS and over 5% entirely at 60 LUFS, so the exact
    // P10/P95 range is 20 LU (the -20 LU relative gate retains both).
    XCTAssertEqual(meter.snapshot().loudnessRange, 20, accuracy: 0.1)
  }

  func testLargestFiniteWeightIsRestoredInLogSpace() throws {
    let fs = 8000.0
    let signal = Signal.tone(dBFS: -23, seconds: 4, sampleRate: fs, channels: 1)
    let baseline = try LoudnessMeter(sampleRate: fs, channels: [.weighted(1)])
    let weighted = try LoudnessMeter(sampleRate: fs, channels: [.weighted(.greatestFiniteMagnitude)])
    baseline.feed(signal)
    weighted.feed(signal)
    let expectedOffset = 10 * log10(Double.greatestFiniteMagnitude)
    for pair in [(weighted.snapshot().integrated, baseline.snapshot().integrated),
                 (weighted.snapshot().momentary, baseline.snapshot().momentary),
                 (weighted.snapshot().shortTerm, baseline.snapshot().shortTerm)] {
      XCTAssertTrue(pair.0.isFinite)
      XCTAssertEqual(Double(pair.0) - Double(pair.1), expectedOffset, accuracy: 0.002)
    }
  }

  func testSilentHugeWeightDoesNotEraseSmallAudibleChannel() throws {
    let fs = 8000.0
    let signal = Signal(sampleRate: fs, channels: [
      Array(repeating: 0, count: Int(4 * fs)),
      Signal.sine(frequency: 1000, dBFS: 120, seconds: 4, sampleRate: fs),
    ])
    let baseline = try LoudnessMeter(sampleRate: fs, channels: [.excluded, .weighted(1e-18)])
    let weighted = try LoudnessMeter(sampleRate: fs, channels: [.weighted(.greatestFiniteMagnitude), .weighted(1e-18)])
    baseline.feed(signal)
    weighted.feed(signal)
    XCTAssertGreaterThan(baseline.snapshot().integrated, -70)
    XCTAssertEqual(weighted.snapshot().integrated, baseline.snapshot().integrated, accuracy: 0.002)
  }
}
