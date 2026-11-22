// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import MonitorKitAudio
import XCTest

final class LoudnessNumericalAuditTests: XCTestCase {
  func testBiquadGainPreservesRepresentableExtremeMagnitudes() {
    for magnitude in [1e-200, 1e200] {
      let filter = Biquad(b0: magnitude, b1: 0, b2: 0, a1: 0, a2: 0)
      XCTAssertEqual(filter.gain(at: 1000, sampleRate: 48000) / magnitude, 1, accuracy: 1e-12)
    }
  }

  func testHistogramClampsExtremeFiniteLoudnessBeforeIntegerConversion() {
    let histogram = LoudnessHistogram(storesEnergy: true)
    defer { histogram.deallocate() }
    histogram.add(loudness: Double.greatestFiniteMagnitude, energy: 1)
    XCTAssertEqual(histogram.gatedMeanEnergy(), 1)
    histogram.clear()
    histogram.add(loudness: -Double.greatestFiniteMagnitude, energy: 1)
    XCTAssertEqual(histogram.totals.pointee.count, 1)
  }

  func testHistogramOverflowedTotalsDoNotTrapRelativeGateConversion() {
    let histogram = LoudnessHistogram(storesEnergy: true)
    defer { histogram.deallocate() }
    histogram.add(loudness: 3000, energy: .greatestFiniteMagnitude)
    histogram.add(loudness: 3000, energy: .greatestFiniteMagnitude)
    XCTAssertEqual(histogram.gatedMeanEnergy(), 0)
    XCTAssertEqual(histogram.loudnessRange(), 0)
  }

  func testHistogramRejectsInvalidEnergiesWithoutCorruptingMeasurement() {
    let histogram = LoudnessHistogram(storesEnergy: true)
    defer { histogram.deallocate() }
    histogram.add(loudness: .infinity, energy: .infinity)
    histogram.add(loudness: .nan, energy: .nan)
    histogram.add(loudness: -20, energy: -1)
    histogram.add(loudness: -20, energy: 0.01)
    XCTAssertEqual(histogram.gatedMeanEnergy(), 0.01, accuracy: 1e-12)
    XCTAssertEqual(histogram.totals.pointee.count, 1)
  }
}
