// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreAudioTypes
import XCTest
@testable import MonitorKitAudio

final class Fresh16AudioStageTests: XCTestCase {
  func testIntegerGatherUsesFrameOffsetAndPaddedStride() {
    let stage = PlanarStage(channelCount: 2, history: 0, capacity: 2)
    defer { stage.deallocate() }
    let input16: [Int16] = [99, 99, 99, .min, .max, 99, 16384, -16384, 99]
    input16.withUnsafeBytes {
      stage.bindInterleaved($0.baseAddress!, format: .int16, frameStride: 3)
      stage.load(offset: 1, frames: 2, format: .int16)
    }
    XCTAssertEqual(stage.samples(0)[0], -1)
    XCTAssertEqual(stage.samples(0)[1], 0.5)
    XCTAssertEqual(stage.samples(1)[0], Float(Int16.max) / 32768)
    XCTAssertEqual(stage.samples(1)[1], -0.5)

    let input32: [Int32] = [99, 99, 99, .min, .max, 99, 1_073_741_824, -1_073_741_824, 99]
    input32.withUnsafeBytes {
      stage.bindInterleaved($0.baseAddress!, format: .int32, frameStride: 3)
      stage.load(offset: 1, frames: 2, format: .int32)
    }
    XCTAssertEqual(stage.samples(0)[0], -1)
    XCTAssertEqual(stage.samples(0)[1], 0.5)
    XCTAssertEqual(stage.samples(1)[0], Float(Int32.max) / 2_147_483_648)
    XCTAssertEqual(stage.samples(1)[1], -0.5)
  }

  func testRebindingAbsentAndUnrenderedChannelsClearsPreviousSources() {
    let stage = PlanarStage(channelCount: 2, history: 0, capacity: 2)
    defer { stage.deallocate() }
    let old: [Float] = [1, 2, 3, 4]
    old.withUnsafeBytes {
      stage.bindInterleaved($0.baseAddress!, format: .float32, frameStride: 2)
      stage.load(offset: 0, frames: 2, format: .float32)
    }
    let mono: [Float] = [0.25, 0.5]
    mono.withUnsafeBytes { bytes in
      var list = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count),
          mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress!)))
      withUnsafePointer(to: &list) { stage.bindBufferList($0, frameCount: 2, format: .float32) }
      stage.load(offset: 0, frames: 2, format: .float32)
    }
    XCTAssertEqual(stage.samples(0)[0], 0.25)
    XCTAssertEqual(stage.samples(0)[1], 0.5)
    XCTAssertEqual(stage.samples(1)[0], 0)
    XCTAssertEqual(stage.samples(1)[1], 0)

    var unrendered = AudioBufferList(
      mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil))
    withUnsafePointer(to: &unrendered) { stage.bindBufferList($0, frameCount: 2, format: .float32) }
    stage.load(offset: 0, frames: 2, format: .float32)
    for channel in 0..<2 {
      XCTAssertEqual(stage.samples(channel)[0], 0)
      XCTAssertEqual(stage.samples(channel)[1], 0)
    }
  }
}
