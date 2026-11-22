// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MonitorKitAudio
import XCTest

final class AudioMeterBoundaryRegressionTests: XCTestCase {
  func testOutOfRangeProgrammePairDoesNotOverflow() {
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: 2, first: .max), [.excluded, .excluded])
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: 2, first: .min), [.excluded, .excluded])
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: 2), LoudnessChannel.stereo)
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: .min), [])
  }

  func testHoldDecaysOnlyAfterItsBoundary() throws {
    let meter = try AudioMeter(configuration: .init(
      sampleRate: 48000, channelCount: 1, meters: [.samplePeak],
      peakHoldTime: 300.0 / 48000, peakDecayRate: 480,
      publishInterval: 0))
    func feed(_ value: Float, count: Int) {
      let samples = [Float](repeating: value, count: count)
      samples.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: count) }
    }
    feed(1, count: 1)
    feed(0, count: 256)
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, 0, accuracy: 0.00001)
    feed(0, count: 44)
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, 0, accuracy: 0.00001)
    feed(0, count: 100)
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, -1, accuracy: 0.00001)
  }

  func testPartChunkHoldExpirationUsesOnlyReleasedFrames() throws {
    let meter = try AudioMeter(configuration: .init(
      sampleRate: 48000, channelCount: 1, meters: [.samplePeak],
      peakHoldTime: 300.0 / 48000, peakDecayRate: 480,
      publishInterval: 0))
    let crest: [Float] = [1]
    crest.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: 1) }
    let silence = [Float](repeating: 0, count: 400)
    silence.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: 400) }
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, -1, accuracy: 0.00001)
  }

  func testUnrepresentableCalibrationsAreRejected() {
    var configuration = AudioMeterConfiguration(sampleRate: 48000, channelCount: 1)
    for value in [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude] {
      configuration.clipLevelDBFS = value
      XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    }
    configuration.clipLevelDBFS = -0.01
    configuration.vuReference = .init(dBFS: -Double.greatestFiniteMagnitude)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    configuration.vuReference = .ebu
    configuration.ppmAlignment = .init(dBFS: Double.greatestFiniteMagnitude)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    configuration.ppmAlignment = .ebu
    for riseTime in [Double.leastNonzeroMagnitude, 1e-200, Double.greatestFiniteMagnitude] {
      configuration.vuBallistics.riseTime = riseTime
      XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    }
    configuration.vuBallistics = .iec60268_17
    // A tiny positive overshoot still has representable, stable damping;
    // it is valid even though extreme rise times above are not.
    configuration.vuBallistics.overshoot = Double.leastNonzeroMagnitude
    XCTAssertNoThrow(try AudioMeter(configuration: configuration))
  }
  func testExtremeScaleInputsHaveBoundedMarks() {
    let wide = MeterScale.digitalPeak(range: -1e20...0)
    XCTAssertLessThanOrEqual(wide.marks.count, 1026)
    let enormous = MeterScale.digitalPeak(range: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
    XCTAssertLessThanOrEqual(enormous.marks.count, 1026)
    let infinite = MeterScale.digitalPeak(range: -Double.infinity...Double.infinity)
    XCTAssertLessThanOrEqual(infinite.marks.count, 1026)
    XCTAssertFalse(MeterScale.loudness(target: Double.greatestFiniteMagnitude).marks.isEmpty)
  }

  func testUnrepresentablePPMCoefficientsAreRejected() {
    var configuration = AudioMeterConfiguration(sampleRate: 48000, channelCount: 1)
    configuration.customPPMBallistics = .init(
      fastTimeConstant: Double.greatestFiniteMagnitude,
      slowTimeConstant: Double.greatestFiniteMagnitude, fastWeight: 0.5, returnRate: 10)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    configuration.customPPMBallistics = .init(
      fastTimeConstant: 0.001, slowTimeConstant: 0.005, fastWeight: 0.5,
      returnRate: Double.greatestFiniteMagnitude)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
  }

}
