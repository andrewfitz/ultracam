// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import XCTest
@testable import MonitorKitAudio

final class PCMPathRegressionTests: XCTestCase {
  private struct Reading: BitwiseCopyable, Equatable {
    var first: UInt64
    var second: UInt64
    var tail: UInt8
  }

  func testReaderCompletesWhileNextPublicationIsHeld() {
    let initial = Reading(first: 1, second: 2, tail: 3)
    let next = Reading(first: 4, second: 5, tail: 6)
    let publisher = SnapshotPublisher(initial)
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    let readerFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      var payload = next
      publisher.publish(&payload) {
        entered.signal()
        resume.wait()
      }
      writerFinished.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().async {
      var reading = next
      publisher.read(into: &reading)
      XCTAssertEqual(reading, initial)
      XCTAssertEqual(publisher.publishCount, 1)
      readerFinished.signal()
    }
    let completedWhileHeld = readerFinished.wait(timeout: .now() + 2)
    resume.signal()
    XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(completedWhileHeld, .success)
    if completedWhileHeld != .success {
      XCTAssertEqual(readerFinished.wait(timeout: .now() + 2), .success)
    }
    var reading = initial
    publisher.read(into: &reading)
    XCTAssertEqual(reading, next)
    XCTAssertEqual(publisher.publishCount, 2)
  }

  func testZeroFrameCallsApplyResetsWithoutReadingChannelPointers() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let loudness = try LoudnessMeter(sampleRate: 48000, channelCount: 2)
    let pcm = [Float](repeating: 0.25, count: 480)
    pcm.withUnsafeBufferPointer { samples in
      meter.process(interleaved: samples.baseAddress!, frameCount: 240)
      loudness.process(interleaved: samples.baseAddress!, frameCount: 240)
    }
    XCTAssertEqual(meter.snapshot().frameCount, 240)
    XCTAssertGreaterThan(loudness.snapshot().duration, 0)

    meter.reset()
    loudness.reset()
    let meterCount = meter.publishCount
    let loudnessCount = loudness.publishCount
    // A zero-frame call carries no channel pointer array.
    let unused = UnsafePointer<UnsafePointer<Float>>(bitPattern: 16)!
    meter.process(planar: unused, frameCount: 0)
    loudness.process(planar: unused, frameCount: 0)
    XCTAssertEqual(meter.snapshot().frameCount, 0)
    XCTAssertEqual(loudness.snapshot().duration, 0)
    XCTAssertEqual(meter.publishCount, meterCount + 1)
    XCTAssertEqual(loudness.publishCount, loudnessCount + 1)
  }

  func testExtremeFiniteAlignmentPublishesFiniteVUAndPPM() throws {
    var configuration = AudioMeterConfiguration(sampleRate: 48000, channelCount: 1, meters: [.vu, .ppm])
    let normal = try AudioMeter(configuration: configuration)
    let reference = -6100.0
    let vuOffset = Float(configuration.vuReference.dBFS - reference)
    let ppmOffset = Float(configuration.ppmAlignment.dBFS - reference)
    configuration.vuReference = .init(dBFS: reference)
    configuration.ppmAlignment = .init(dBFS: reference)
    let calibrated = try AudioMeter(configuration: configuration)
    let pcm = [Float](repeating: 1_000_000, count: 24000)
    pcm.withUnsafeBufferPointer { samples in
      normal.process(interleaved: samples.baseAddress!, frameCount: samples.count)
      calibrated.process(interleaved: samples.baseAddress!, frameCount: samples.count)
    }
    let baseline = normal.snapshot()[0]
    let reading = calibrated.snapshot()[0]
    XCTAssertEqual(reading.vu, baseline.vu + vuOffset, accuracy: 0.001)
    XCTAssertEqual(reading.ppm, baseline.ppm + ppmOffset, accuracy: 0.001)
  }
}
