// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreFoundation
import Foundation
import MonitorKitAudio
import XCTest

final class Fresh14CorrelationTests: XCTestCase {
  /// Independent scalar exponential recurrence, one update per input sample.
  private func reference(_ left: [Float], _ right: [Float], tau: Double) -> Float {
    let keep = exp(-1 / (48000 * tau))
    let take = -expm1(-1 / (48000 * tau))
    var weight = 0.0
    var l = 0.0
    var r = 0.0
    var ll = 0.0
    var rr = 0.0
    var lr = 0.0
    for i in left.indices {
      let x = Double(left[i])
      let y = Double(right[i])
      weight = keep * weight + take
      l = keep * l + take * x
      r = keep * r + take * y
      ll = keep * ll + take * x * x
      rr = keep * rr + take * y * y
      lr = keep * lr + take * x * y
    }
    let vl = max(0, ll / weight - (l / weight) * (l / weight))
    let vr = max(0, rr / weight - (r / weight) * (r / weight))
    if vl < 1e-7 && vr < 1e-7 { return .nan }
    if vl < 1e-10 || vr < 1e-10 { return 0 }
    return Float(max(-1, min(1, (lr / weight - l * r / (weight * weight)) / sqrt(vl * vr))))
  }

  private func reading(_ left: [Float], _ right: [Float], tau: Double, partition: Int) throws -> Float {
    let meter = try AudioMeter(configuration: .init(
      sampleRate: 48000, channelCount: 2, meters: [.correlation], publishInterval: 0, correlationTime: tau))
    let signal = Signal(sampleRate: 48000, channels: [left, right])
    meter.feed(signal, blockSize: partition)
    return meter.snapshot().correlation
  }

  func testExponentialCorrelationMatchesScalarAcrossCallbackPartitions() throws {
    let left = (0..<1024).map { Float(0.4 * sin(2 * Double.pi * 1500 * Double($0) / 48000) + 0.125) }
    let right = left.enumerated().map { i, x in i < 896 ? x : -x }
    for tau in [0.001, 0.3] {
      let expected = reference(left, right, tau: tau)
      for partition in [16, 64, 256] {
        XCTAssertEqual(try reading(left, right, tau: tau, partition: partition), expected, accuracy: 0.000001)
      }
    }
  }

  func testSilenceAndOneSidedSignalAtEveryPartition() throws {
    let tone = (0..<1024).map { Float(0.4 * sin(Double($0) * 0.3)) }
    let silence = [Float](repeating: 0, count: tone.count)
    for tau in [0.001, 0.3] {
      for partition in [16, 64, 256] {
        XCTAssertTrue(try reading(silence, silence, tau: tau, partition: partition).isNaN)
        XCTAssertEqual(try reading(tone, silence, tau: tau, partition: partition), 0)
      }
      let mono = try AudioMeter(configuration: .init(
        sampleRate: 48000, channelCount: 1, meters: [.correlation], correlationTime: tau))
      mono.feed(Signal(sampleRate: 48000, channels: [tone]), blockSize: 64)
      XCTAssertTrue(mono.snapshot().correlation.isNaN)
    }
  }

  /// Run the same opt-in benchmark on the saved baseline and working tree;
  /// BENCH rows pair by tau/kinds. Input, warmup and measurement are identical.
  func testCorrelationAndInitializationMicrobenchmark() throws {
    guard ProcessInfo.processInfo.environment["MONITORKIT_FRESH14_BENCH"] == "1" else {
      throw XCTSkip("Set MONITORKIT_FRESH14_BENCH=1 for paired baseline/current timing")
    }
    let block = PlanarBlock(channelCount: 16, capacity: 1024)
    for c in 0..<16 {
      for i in 0..<1024 { block.pointers[c][i] = Float(0.4 * sin(Double(i + c) * 0.13)) }
    }
    for tau in [0.001, 0.3] {
      for correlation in [false, true] {
        let kinds: AudioMeterKinds = correlation ? .all : .all.subtracting(.correlation)
        let configuration = AudioMeterConfiguration(
          sampleRate: 48000, channelCount: 16, meters: kinds, correlationTime: tau)
        let meter = try AudioMeter(configuration: configuration)
        for _ in 0..<100 { meter.process(planar: block.pointers, frameCount: 1024) }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 { meter.process(planar: block.pointers, frameCount: 1024) }
        let microseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("BENCH Fresh14 audio tau=\(tau) correlation=\(correlation) us/1024=\(microseconds)")
      }
    }
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<100 {
      let meter = try AudioMeter(sampleRate: 48000, channelCount: 16)
      XCTAssertEqual(meter.configuration.channelCount, 16)
    }
    print("BENCH Fresh14 init us=\((CFAbsoluteTimeGetCurrent() - start) * 10000)")
  }
}
