// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Synchronization
import XCTest
@testable import MonitorKitAudio

final class AudioHandoffAuditTests: XCTestCase {
  private final class FailureCounter: Sendable {
    let count = Atomic<Int>(0)
  }

  private struct Payload: BitwiseCopyable {
    var generation: UInt64
    var inverse: UInt64
    // Exercise the publisher's partial final word as well as full words.
    var tag: UInt8
  }

  func testConcurrentPublisherReadersNeverAcceptTornPayload() {
    let publisher = SnapshotPublisher(Payload(generation: 0, inverse: ~0, tag: 0))
    let failures = FailureCounter()
    DispatchQueue.concurrentPerform(iterations: 5) { worker in
      if worker == 0 {
        for generation in UInt64(1)...20_000 {
          var payload = Payload(generation: generation, inverse: ~generation, tag: UInt8(truncatingIfNeeded: generation))
          publisher.publish(&payload)
        }
      } else {
        var payload = Payload(generation: 0, inverse: 0, tag: 0)
        for _ in 0..<20_000 {
          publisher.read(into: &payload)
          if payload.inverse != ~payload.generation || payload.tag != UInt8(truncatingIfNeeded: payload.generation) {
            failures.count.add(1, ordering: .relaxed)
          }
        }
      }
    }
    XCTAssertEqual(failures.count.load(ordering: .relaxed), 0)
    XCTAssertEqual(publisher.publishCount, 20_001)
  }

  func testShortChunksCarryOverlappingHistoryInOrder() {
    let stage = PlanarStage(channelCount: 1, history: 11, capacity: 4)
    defer { stage.deallocate() }
    let samples = stage.samples(0)
    for index in -11..<0 { samples[index] = Float(index) }
    samples[0] = 0
    samples[1] = 1
    stage.carryHistory(0, frames: 2)
    XCTAssertEqual(Array(UnsafeBufferPointer(start: samples - 11, count: 11)), (-9...1).map(Float.init))
    samples[0] = 2
    stage.carryHistory(0, frames: 1)
    XCTAssertEqual(Array(UnsafeBufferPointer(start: samples - 11, count: 11)), (-8...2).map(Float.init))
  }

  func testStridedFloatInputSanitizesEveryChannelBeforeFiltering() {
    let stage = PlanarStage(channelCount: 2, history: 0, capacity: 4)
    defer { stage.deallocate() }
    let input: [Float] = [.nan, .infinity, -.infinity, 2e6, -2e6, 0.25, 0.5, -0.5]
    input.withUnsafeBytes {
      stage.bindInterleaved($0.baseAddress!, format: .float32, frameStride: 2)
      stage.load(offset: 0, frames: 4, format: .float32)
    }
    XCTAssertEqual(Array(UnsafeBufferPointer(start: stage.samples(0), count: 4)), [0, -1, -1e6, 0.5])
    XCTAssertEqual(Array(UnsafeBufferPointer(start: stage.samples(1), count: 4)), [1, 1e6, 0.25, -0.5])
  }
}
