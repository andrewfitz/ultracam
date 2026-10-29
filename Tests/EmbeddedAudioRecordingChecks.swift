import AVFoundation
import CoreMedia
import Foundation
import XCTest

@objcMembers final class EmbeddedAudioRecordingChecks: XCTestCase {
  func testExactSigned32ToPacked24Conversion() throws {
    let values: [Int32] = [
      0,
      0x12345678,
      0x7FFFFF00,
      Int32(bitPattern: 0x80000000),
      -1,
      -0x12345678,
    ]
    var source = Data()
    for value in values {
      var littleEndian = UInt32(bitPattern: value).littleEndian
      withUnsafeBytes(of: &littleEndian) { source.append(contentsOf: $0) }
    }

    let packed = try EmbeddedAudioConverter.convert32BitIntegerPCMTo24BitPacked(source, channelCount: 2)
    XCTAssertEqual(Array(packed), [
      0x00, 0x00, 0x00,
      0x56, 0x34, 0x12,
      0xFF, 0xFF, 0x7F,
      0x00, 0x00, 0x80,
      0xFF, 0xFF, 0xFF,
      0xA9, 0xCB, 0xED,
    ])
  }

  func testConversionRejectsPartialInterleavedFrame() {
    XCTAssertThrowsError(try EmbeddedAudioConverter.convert32BitIntegerPCMTo24BitPacked(
      Data(repeating: 0, count: 9), channelCount: 2)) { error in
      XCTAssertEqual(error as? EmbeddedAudioError,
        .byteCountMismatch(expected: 16, actual: 9))
    }
  }

  func testPacketRejectsSampleCountSizeOverflow() {
    XCTAssertThrowsError(try EmbeddedAudioPacket(sourcePCM32: Data(),
      sampleFrameCount: Int.max,
      presentationTime: CMTime(value: 0, timescale: EmbeddedAudioFormat.sampleRateTimescale))) { error in
      XCTAssertEqual(error as? EmbeddedAudioError, .sizeOverflow)
    }
  }

  func testTimelineKeepsInteger48KHzClockWithoutDrift() throws {
    var timeline = EmbeddedAudioTimeline()
    var frameOffset: Int64 = 0
    var lastEnd = CMTime.zero
    for packetIndex in 0..<12_000 {
      // Deliberately vary packet sizes like a capture callback does. Every
      // packet still advances by an exact integer number of audio frames.
      let frameCount = [799, 800, 801][packetIndex % 3]
      let timing = try timeline.nextPacketTiming(sampleFrameCount: frameCount)
      XCTAssertEqual(timing.presentationTime,
        CMTime(value: frameOffset, timescale: EmbeddedAudioFormat.sampleRateTimescale))
      XCTAssertEqual(timing.duration,
        CMTime(value: Int64(frameCount), timescale: EmbeddedAudioFormat.sampleRateTimescale))
      XCTAssertEqual(timing.presentationTime, lastEnd)
      frameOffset += Int64(frameCount)
      lastEnd = CMTime(value: frameOffset, timescale: EmbeddedAudioFormat.sampleRateTimescale)
    }
    XCTAssertEqual(timeline.emittedSampleFrames, frameOffset)
    XCTAssertEqual(EmbeddedAudioTimeline.time(forSampleFrameOffset: frameOffset), lastEnd)
  }

  func testWriterSettingsDescribe48KHzInterleaved24BitPCM() {
    let settings = EmbeddedAudioFormat.assetWriterSettings
    XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
    XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48_000)
    XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 24)
    XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
    XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
    XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
  }

  func testPacketAndSampleBufferRetainExactPTS() throws {
    let sampleFrames = 800
    let source = Data(repeating: 0, count: sampleFrames * EmbeddedAudioFormat.channelCount * 4)
    let pts = CMTime(value: 1_234_567, timescale: EmbeddedAudioFormat.sampleRateTimescale)
    let packet = try EmbeddedAudioPacket(sourcePCM32: source, sampleFrameCount: sampleFrames,
      presentationTime: pts)
    XCTAssertEqual(packet.pcm24.count, sampleFrames * EmbeddedAudioFormat.recordingBytesPerFrame)
    XCTAssertEqual(packet.duration, CMTime(value: 800, timescale: 48_000))

    let sampleBuffer = try EmbeddedAudioRecording.makeSampleBuffer(for: packet)
    XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), sampleFrames)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), pts)
    XCTAssertEqual(CMSampleBufferGetDuration(sampleBuffer), packet.duration)
  }

  func testDirectSourceSampleBufferPacks24BitWithoutChangingPayload() throws {
    let values: [Int32] = [0x12345678, Int32(bitPattern: 0x80000000), -1, -0x12345678]
    var source = Data()
    for value in values {
      var littleEndian = UInt32(bitPattern: value).littleEndian
      withUnsafeBytes(of: &littleEndian) { source.append(contentsOf: $0) }
    }
    let sample = try EmbeddedAudioRecording.makeSampleBuffer(sourcePCM32: source,
      sampleFrameCount: 2,
      presentationTime: CMTime(value: 0, timescale: EmbeddedAudioFormat.sampleRateTimescale))
    XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 2)
    XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 12)
    var bytes = [UInt8](repeating: 0, count: 12)
    let byteCount = bytes.count
    let status = bytes.withUnsafeMutableBytes { destination in
      guard let block = CMSampleBufferGetDataBuffer(sample),
        let base = destination.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
        destination: base)
    }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    XCTAssertEqual(bytes, [
      0x56, 0x34, 0x12, 0x00, 0x00, 0x80,
      0xFF, 0xFF, 0xFF, 0xA9, 0xCB, 0xED,
    ])
  }


  /// The vectorized packer must equal the scalar `sample >> 8` reference for
  /// every bit pattern, including negative full-scale values.
  func testVectorizedPackingMatchesScalarReference() throws {
    var state: UInt32 = 0x1234_5678
    var samples: [Int32] = [Int32.min, Int32.max, -1, 0, 255, 256, -256, -257]
    for _ in 0..<(1_601 * 2 - samples.count) {
      state = state &* 1_664_525 &+ 1_013_904_223
      samples.append(Int32(bitPattern: state))
    }
    var reference = [UInt8]()
    for sample in samples {
      let packed = UInt32(bitPattern: sample >> 8)
      reference += [UInt8(truncatingIfNeeded: packed), UInt8(truncatingIfNeeded: packed >> 8),
        UInt8(truncatingIfNeeded: packed >> 16)]
    }
    XCTAssertEqual([UInt8](EmbeddedAudioConverter.convert32BitIntegerSamplesTo24BitPacked(samples)), reference)
    let raw = samples.withUnsafeBytes { Data($0) }
    XCTAssertEqual([UInt8](try EmbeddedAudioConverter.convert32BitIntegerPCMTo24BitPacked(raw)), reference)
    let first = try EmbeddedAudioRecording.makeSampleBuffer(sourcePCM32: raw, sampleFrameCount: 1_601,
      presentationTime: CMTime(value: 0, timescale: 48_000))
    let second = try EmbeddedAudioRecording.makeSampleBuffer(sourcePCM32: raw, sampleFrameCount: 1_601,
      presentationTime: CMTime(value: 1_601, timescale: 48_000))
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(first))
    var bytes = [UInt8](repeating: 0, count: reference.count)
    XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes),
      kCMBlockBufferNoErr)
    XCTAssertEqual(bytes, reference)
    XCTAssertTrue(CMSampleBufferGetFormatDescription(first) === CMSampleBufferGetFormatDescription(second),
      "Every packet shares one audio format description")
  }
}
