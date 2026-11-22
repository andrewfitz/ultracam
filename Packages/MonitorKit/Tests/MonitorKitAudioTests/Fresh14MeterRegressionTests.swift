// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitAudio
import XCTest

final class Fresh14MeterRegressionTests: XCTestCase {
  func testDisabledMetersStillValidateTheirBallistics() {
    var configuration = AudioMeterConfiguration(sampleRate: 48000, channelCount: 1, meters: [])
    configuration.customPPMBallistics = .init(
      fastTimeConstant: 0.001, slowTimeConstant: 0.005, fastWeight: 0.5,
      returnRate: Double.greatestFiniteMagnitude)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration)) { error in
      XCTAssertEqual(error as? AudioMeterError, .invalidParameter("ppm ballistics"))
    }
    configuration.customPPMBallistics = nil
    configuration.vuBallistics.riseTime = 10_000_000
    XCTAssertThrowsError(try AudioMeter(configuration: configuration)) { error in
      XCTAssertEqual(error as? AudioMeterError, .invalidParameter("vuBallistics"))
    }
    configuration.vuBallistics = .iec60268_17
    XCTAssertNoThrow(try AudioMeter(configuration: configuration))
  }

  func testSlowVUMovementRejectsRoundedUnstablePoles() {
    var configuration = AudioMeterConfiguration(sampleRate: 48000, channelCount: 1)
    for riseTime in [10_000_000.0, 100_000_000.0] {
      configuration.vuBallistics.riseTime = riseTime
      XCTAssertThrowsError(try AudioMeter(configuration: configuration)) { error in
        XCTAssertEqual(error as? AudioMeterError, .invalidParameter("vuBallistics"))
      }
    }
  }

  func testCustomReadingConversionPreservesSilence() {
    var scale = MeterScale.digitalPeak()
    scale.readingOffset = 3
    for factor in [0.0, -1.0, 1.0] {
      scale.readingScale = factor
      XCTAssertEqual(scale.value(forReading: -.infinity), -.infinity)
      XCTAssertEqual(scale.position(forReading: -.infinity), 0)
      XCTAssertEqual(scale.value(forReading: -12), 3 - 12 * factor)
    }
  }
}
