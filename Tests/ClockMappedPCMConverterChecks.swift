import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import XCTest

@objcMembers final class ClockMappedPCMConverterChecks: XCTestCase {
  private func mapping(_ rate: Rational = .one) throws -> AudioVideoClockMapping {
    try AudioVideoClockMapping(
      audio: ClockMapping(sourceAnchor: CMTime(seconds: 100, preferredTimescale: 48000), hostAnchor: CMTime(seconds: 900, preferredTimescale: 48000), rate: rate),
      video: ClockMapping(sourceAnchor: CMTime(seconds: 500, preferredTimescale: 48000), hostAnchor: CMTime(seconds: 900, preferredTimescale: 48000), rate: .one))
  }
  private func format(_ sample: AudioSampleType = .int16, channels: Int = 1, interleaved: Bool = true, rate: Double = 48000) throws -> SourceAudioFormat {
    try SourceAudioFormat(sampleRate: rate, channels: channels, sample: sample,
      interleaved: interleaved, layout: AudioChannelMap(), clock: .deviceClock)
  }
  func testNonZeroClockOriginsAndInt16Conversion() throws {
    var converter = try ClockMappedPCMConverter(format: format(), outputSampleRate: 48000)
    let data = [Int16(16384), 0, -16384].withUnsafeBytes { Data($0) }
    let chunk = try converter.convert(planes: [data], sampleFrameCount: 3,
      audioTime: CMTime(seconds: 100, preferredTimescale: 48000), mapping: mapping())
    XCTAssertEqual(chunk.presentationTime.seconds, 500, accuracy: 1e-9)
    XCTAssertEqual(chunk.sampleFrameCount, 2)
    XCTAssertEqual(chunk.samples.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, 0.5)
  }
  func testFractionalPhaseSurvivesPacketsAtDifferentSampleRate() throws {
    let f = try format(.float32, rate: 44100)
    var split = try ClockMappedPCMConverter(format: f, outputSampleRate: 48000)
    var whole = split
    let values = (0..<882).map { Float($0) / 1000 }
    let all = try whole.convert(planes: [values.withUnsafeBytes { Data($0) }], sampleFrameCount: values.count,
      audioTime: CMTime(seconds: 100, preferredTimescale: 44100), mapping: mapping())
    var joined = Data()
    for offset in stride(from: 0, to: 882, by: 147) {
      let packet = Array(values[offset..<(offset + 147)])
      let chunk = try split.convert(planes: [packet.withUnsafeBytes { Data($0) }], sampleFrameCount: 147,
        audioTime: CMTime(value: 4_410_000 + Int64(offset), timescale: 44100), mapping: mapping())
      joined.append(chunk.samples)
    }
    XCTAssertEqual(joined.count, all.samples.count)
    let left = joined.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let right = all.samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    for (a, b) in zip(left, right) { XCTAssertEqual(a, b, accuracy: 1e-6) }
  }

  func testExactResamplingIntervalHasSameLengthAcrossPacketSizes() throws {
    let source = try format(.float32, rate: 44_100)
    let clock = try mapping()
    for packetSize in [1, 147, 441] {
      var converter = try ClockMappedPCMConverter(format: source, outputSampleRate: 48_000)
      let packet = [Float](repeating: 0.5, count: packetSize).withUnsafeBytes { Data($0) }
      var outputFrames = 0
      for offset in stride(from: 0, to: 441, by: packetSize) {
        let time = CMTime(value: 4_410_000 + Int64(offset), timescale: 44_100)
        let chunk = try converter.convert(planes: [packet], sampleFrameCount: packetSize,
          audioTime: time, mapping: clock)
        outputFrames += chunk.sampleFrameCount
      }
      outputFrames += converter.finish()?.sampleFrameCount ?? 0
      XCTAssertEqual(outputFrames, 480, "packet size \(packetSize)")
    }
  }
  func testAudioSegmentRestartReanchorsFractionalPhaseAndRejectsClockRegression() throws {
    let mic = try format(.float32, rate: 44100)
    var converter = try ClockMappedPCMConverter(format: mic, outputSampleRate: 48000)
    let clock = PCMClockTransform.mapped(try mapping())
    let before = [Float](repeating: -0.5, count: 37).withUnsafeBytes { Data($0) }
    _ = try converter.convert(planes: [before], sampleFrameCount: 37,
      audioTime: CMTime(value: 100, timescale: 1), mapping: clock)
    XCTAssertThrowsError(try converter.restartSegment(audioTime: CMTime(value: 99, timescale: 1), mapping: clock)) {
      XCTAssertEqual($0 as? ClockMappedPCMError, .discontinuity)
    }
    let restart = CMTime(value: 105, timescale: 1)
    try converter.restartSegment(audioTime: restart, mapping: clock)
    let after = [Float](repeating: 0.5, count: 37).withUnsafeBytes { Data($0) }
    let result = try converter.convert(planes: [after], sampleFrameCount: 37, audioTime: restart, mapping: clock)
    XCTAssertEqual(result.presentationTime, CMTime(value: 505, timescale: 1))
    XCTAssertGreaterThan(result.sampleFrameCount, 0)
    XCTAssertTrue(result.samples.withUnsafeBytes { $0.bindMemory(to: Float.self).allSatisfy { $0 == 0.5 } })
  }

  func testPlanarChannelsRemainDistinct() throws {
    var converter = try ClockMappedPCMConverter(format: format(.float32, channels: 2, interleaved: false), outputSampleRate: 48000)
    let chunk = try converter.convert(planes: [[Float](repeating: 0.25, count: 3).withUnsafeBytes { Data($0) },
      [Float](repeating: -0.5, count: 3).withUnsafeBytes { Data($0) }], sampleFrameCount: 3,
      audioTime: CMTime(value: 100, timescale: 1), mapping: mapping())
    XCTAssertEqual(chunk.samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, [0.25, -0.5, 0.25, -0.5])
  }

  func testLowAligned24BitConversionIgnoresPaddingAndExtendsSign() throws {
    let source = try format(.int24in32)
    let start = CMTime(value: 100, timescale: 1)
    let words: [UInt32] = [0x88400000, 0x00C00000, 0xFFC00000, 0xAB000000]
    let sample = try makeSourceSample(planes: [words.withUnsafeBytes { Data($0) }],
      sampleFrameCount: words.count, format: source, presentationTime: start)
    var bridge = try ClockMappedPCMBridge(format: source, outputSampleRate: 48_000)
    let converted = try XCTUnwrap(bridge.convert(sample, mapping: mapping()))
    let tail = try XCTUnwrap(bridge.finish())
    var expected: [[Float]] = [[0.5, -0.5, -0.5], [0]]
    for output in [converted, tail] {
      let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(output))
      let frames = CMSampleBufferGetNumSamples(output)
      var values = [Float](repeating: 0, count: frames)
      XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0,
        dataLength: frames * MemoryLayout<Float>.stride, destination: &values), noErr)
      XCTAssertEqual(values, expected.removeFirst())
    }
  }

  func testContiguousIntegralRatePacketsPassZeroSourceClockTolerance() throws {
    let rate: CMTimeScale = 48_000
    var converter = try ClockMappedPCMConverter(format: format(.float32), outputSampleRate: Double(rate),
      maximumAVErrorSeconds: 0)
    let clock = try mapping()
    let pcm = [Float(0.25), 0.5].withUnsafeBytes { Data($0) }
    for offset in stride(from: 0, to: 6, by: 2) {
      let chunk = try converter.convert(planes: [pcm], sampleFrameCount: 2,
        audioTime: CMTime(value: 100 * Int64(rate) + Int64(offset), timescale: rate),
        mapping: clock)
      XCTAssertEqual(chunk.sampleFrameCount, offset == 0 ? 1 : 2)
    }
    XCTAssertEqual(converter.finish()?.sampleFrameCount, 1)
  }

  func testSelectedStereoMatchesFullConversionAcrossPacketsAndFinish() throws {
    let clock = try mapping(Rational(1_000_047, 1_000_000))
    for sample: AudioSampleType in [.int16, .int24in32, .int32, .float32] {
      for isInterleaved in [true, false] {
        for rate in [44_100.0, 48_000.5, 96_000.0] {
          let f = try format(sample, channels: 16, interleaved: isInterleaved, rate: rate)
          var full = try ClockMappedPCMConverter(format: f, outputSampleRate: 48_000)
          var selected = try ClockMappedPCMConverter(format: f, outputSampleRate: 48_000, selectedChannels: 14..<16)
          var start = 0
          for count in [1, 3, 272, 2, 110, 20, 1] {
            let planes = pcmPlanes(format: f, start: start, frames: count)
            let time = CMTime(seconds: 100 + Double(start) / rate, preferredTimescale: 1_000_000_000)
            let all = try full.convert(planes: planes, sampleFrameCount: count, audioTime: time, mapping: clock)
            let pair = try selected.convert(planes: planes, sampleFrameCount: count, audioTime: time, mapping: clock)
            assertSelectedStereo(pair, matches: all)
            start += count
          }
          if let tail = full.finish() {
            try assertSelectedStereo(XCTUnwrap(selected.finish()), matches: tail)
          } else {
            XCTAssertNil(selected.finish())
          }
          XCTAssertNil(selected.finish())
        }
      }
    }
  }

  func testSelectionValidatesWholePacketShapeAndOnlyConsumedFloatSamples() throws {
    let clock = try mapping()
    let time = CMTime(value: 100, timescale: 1)
    for isInterleaved in [true, false] {
      let f = try format(.float32, channels: 4, interleaved: isInterleaved)
      for invalid in [-1..<1, 2..<2, 3..<5] {
        XCTAssertThrowsError(try ClockMappedPCMConverter(format: f, outputSampleRate: 48_000, selectedChannels: invalid)) {
          XCTAssertEqual($0 as? ClockMappedPCMError, .invalidPacket)
        }
      }
      let values: [Float] = [.nan, .infinity, 0.25, -0.5]
      let planes = isInterleaved
        ? [(values + values).withUnsafeBytes { Data($0) }]
        : values.map { [$0, $0].withUnsafeBytes { Data($0) } }
      var full = try ClockMappedPCMConverter(format: f, outputSampleRate: 48_000)
      var selected = try ClockMappedPCMConverter(format: f, outputSampleRate: 48_000, selectedChannels: 2..<4)
      var malformed = planes
      malformed[0].removeLast()
      XCTAssertThrowsError(try selected.convert(planes: malformed, sampleFrameCount: 2, audioTime: time, mapping: clock)) {
        XCTAssertEqual($0 as? ClockMappedPCMError, .invalidPacket)
      }
      XCTAssertThrowsError(try full.convert(planes: planes, sampleFrameCount: 2, audioTime: time, mapping: clock)) {
        XCTAssertEqual($0 as? ClockMappedPCMError, .nonFiniteSample)
      }
      var nonFiniteSelection = planes
      let offset = isInterleaved ? 2 * MemoryLayout<Float>.size : 0
      let nan = [Float.nan].withUnsafeBytes { Data($0) }
      nonFiniteSelection[isInterleaved ? 0 : 2].replaceSubrange(offset..<(offset + nan.count), with: nan)
      XCTAssertThrowsError(try selected.convert(planes: nonFiniteSelection, sampleFrameCount: 2, audioTime: time, mapping: clock)) {
        XCTAssertEqual($0 as? ClockMappedPCMError, .nonFiniteSample)
      }
      let chunk = try selected.convert(planes: planes, sampleFrameCount: 2, audioTime: time, mapping: clock)
      XCTAssertEqual(chunk.presentationTime.seconds, 500)
      XCTAssertEqual(chunk.sampleFrameCount, 1)
      XCTAssertEqual(chunk.samples, [Float(0.25), -0.5].withUnsafeBytes { Data($0) })
    }
  }

  func testSelectedWorkspaceBudgetIncludesAllSourceBytes() throws {
    let f = try format(.float32, channels: 16)
    let clock = try mapping()
    // 3 source frames, 3 decoded stereo frames, and 4 stereo output frames.
    let exact = try ClockMappedPCMConverter(format: f, outputSampleRate: 48_000,
      selectedChannels: 14..<16, maximumWorkspaceBytes: 360)
    let below = try ClockMappedPCMConverter(format: f, outputSampleRate: 48_000,
      selectedChannels: 14..<16, maximumWorkspaceBytes: 359)
    XCTAssertEqual(try exact.preflight(sampleFrameCount: 3, mapping: clock), 4)
    XCTAssertThrowsError(try below.preflight(sampleFrameCount: 3, mapping: clock)) {
      XCTAssertEqual($0 as? ClockMappedPCMError, .workspaceLimit)
    }
  }

  private func assertSelectedStereo(_ stereo: ClockMappedPCMChunk, matches full: ClockMappedPCMChunk,
    file: StaticString = #filePath, line: UInt = #line) {
    let expected = full.samples.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Float.self)
      var selected = [Float]()
      for frame in 0..<full.sampleFrameCount {
        selected.append(samples[frame * full.channels + 14])
        selected.append(samples[frame * full.channels + 15])
      }
      return selected.withUnsafeBytes { Data($0) }
    }
    XCTAssertEqual(stereo.samples, expected, file: file, line: line)
    XCTAssertEqual(stereo.presentationTime, full.presentationTime, file: file, line: line)
    XCTAssertEqual(stereo.correctionRatio, full.correctionRatio, file: file, line: line)
    XCTAssertEqual(stereo.sampleFrameCount, full.sampleFrameCount, file: file, line: line)
    XCTAssertEqual(stereo.channels, 2, file: file, line: line)
  }

  private func pcmPlanes(format: SourceAudioFormat, start: Int, frames: Int) -> [Data] {
    let count = format.interleaved ? 1 : format.channels
    return (0..<count).map { plane in
      let span = format.interleaved ? format.channels : 1
      let samples = (0..<(frames * span)).map { index in
        let frame = start + index / span
        let channel = format.interleaved ? index % span : plane
        return (frame * 619 + channel * 4093) % 65_535 - 32_767
      }
      switch format.sample {
      case .int16: return samples.map { Int16($0).littleEndian }.withUnsafeBytes { Data($0) }
      case .int24in32: return samples.map { (Int32($0) << 8).littleEndian }.withUnsafeBytes { Data($0) }
      case .int32: return samples.map { (Int32($0) << 16).littleEndian }.withUnsafeBytes { Data($0) }
      case .float32: return samples.map { (Float($0) / 20011).bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
      }
    }
  }

  func testExcessiveDriftFailsBeforeConsumingPacket() throws {
    var converter = try ClockMappedPCMConverter(format: format(), outputSampleRate: 48000)
    let data = [Int16](repeating: 0, count: 10).withUnsafeBytes { Data($0) }
    XCTAssertThrowsError(try converter.convert(planes: [data], sampleFrameCount: 10,
      audioTime: CMTime(value: 100, timescale: 1), mapping: mapping(Rational(101, 100))))
    let good = try converter.convert(planes: [data], sampleFrameCount: 10,
      audioTime: CMTime(value: 100, timescale: 1), mapping: mapping())
    XCTAssertEqual(good.presentationTime.seconds, 500, accuracy: 1e-9)
  }
  func testFinishDrainsFinalSampleOnce() throws {
    var converter = try ClockMappedPCMConverter(format: format(), outputSampleRate: 48000)
    let data = [Int16](repeating: 16384, count: 3).withUnsafeBytes { Data($0) }
    let chunk = try converter.convert(planes: [data], sampleFrameCount: 3,
      audioTime: CMTime(value: 100, timescale: 1), mapping: mapping())
    let tail = try XCTUnwrap(converter.finish())
    XCTAssertEqual(chunk.sampleFrameCount + tail.sampleFrameCount, 3)
    XCTAssertEqual(tail.presentationTime.seconds, 500 + 2.0 / 48000, accuracy: 1e-9)
    XCTAssertNil(converter.finish())
    XCTAssertThrowsError(try converter.convert(planes: [data], sampleFrameCount: 3,
      audioTime: CMTime(value: 100, timescale: 1), mapping: mapping()))
  }

  func testLongRunDriftProducesBoundedFixedGridWithExactFinalCount() throws {
    var converter = try ClockMappedPCMConverter(format: format(.float32, rate: 44100), outputSampleRate: 48000)
    let data = [Float](repeating: 0.25, count: 441).withUnsafeBytes { Data($0) }
    let m = try mapping(Rational(1001, 1000))
    var count = 0
    for packet in 0..<1000 {
      let chunk = try converter.convert(planes: [data], sampleFrameCount: 441,
        audioTime: CMTime(value: 4_410_000 + Int64(packet * 441), timescale: 44100), mapping: m)
      XCTAssertEqual(chunk.presentationTime.seconds, 500 + Double(count) / 48000, accuracy: 1e-9)
      count += chunk.sampleFrameCount
    }
    count += converter.finish()?.sampleFrameCount ?? 0
    XCTAssertEqual(Double(count), 480_480, accuracy: 1)
  }

  func testBridgeDecodesInt16EncodesFloat32AndRetainsLayout() throws {
    let f = try format(.int16, channels: 2)
    var bridge = try ClockMappedPCMBridge(format: f, outputSampleRate: 96000)
    let sample = try inputSample([Int16](repeating: 16384, count: 20), channels: 2)
    let output = try XCTUnwrap(bridge.convert(sample, mapping: mapping()))
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(output))
    let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
    XCTAssertEqual(asbd.mSampleRate, 96000)
    XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0)
    var layoutSize = 0
    let layout = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize))
    XCTAssertEqual(layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_Stereo)
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(output))
    var value: Float = 0
    XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &value), noErr)
    XCTAssertEqual(value, 0.5)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(output).seconds, 500, accuracy: 1e-9)
    let tail = try XCTUnwrap(bridge.finish())
    XCTAssertEqual(CMSampleBufferGetNumSamples(output) + CMSampleBufferGetNumSamples(tail), 20)
    XCTAssertEqual(bridge.convertedFrames, 20)
    XCTAssertEqual(bridge.discontinuities, 0)
  }

  func testSourceWrapperPreservesPlanarChannelsBytesRateAndLayout() throws {
    let f = try SourceAudioFormat(sampleRate: 44100, channels: 3, sample: .int16, interleaved: false,
      layout: AudioChannelMap(labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center]), clock: .deviceClock)
    var planes = (1...3).map { channel in [Int16](repeating: Int16(channel * 4000), count: 8).withUnsafeBytes { Data($0) } }
    let originals = planes
    let sample = try makeSourceSample(planes: planes, sampleFrameCount: 8, format: f,
      presentationTime: CMTime(value: 100, timescale: 1))
    XCTAssertEqual(planes, originals)
    planes[0][0] = 0
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
    var copied = Data(count: originals.reduce(0) { $0 + $1.count })
    let status = copied.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0,
      dataLength: $0.count, destination: $0.baseAddress!) }
    XCTAssertEqual(status, noErr)
    XCTAssertEqual(copied, originals.reduce(into: Data()) { $0.append($1) })
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
    XCTAssertEqual(asbd.mSampleRate, 44100)
    XCTAssertEqual(asbd.mChannelsPerFrame, 3)
    XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
    var layoutSize = 0
    let layout = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize))
    XCTAssertEqual(layout.pointee.mNumberChannelDescriptions, 3)
    var bridge = try ClockMappedPCMBridge(format: f, outputSampleRate: 48000)
    let output = try XCTUnwrap(bridge.convert(sample, mapping: mapping()))
    XCTAssertEqual(CMSampleBufferGetNumSamples(output), 8)
    let outputBlock = try XCTUnwrap(CMSampleBufferGetDataBuffer(output))
    var firstFrame = [Float](repeating: 0, count: 3)
    XCTAssertEqual(CMBlockBufferCopyDataBytes(outputBlock, atOffset: 0, dataLength: 12, destination: &firstFrame), noErr)
    for channel in 0..<3 { XCTAssertEqual(firstFrame[channel], Float((channel + 1) * 4000) / 32768, accuracy: 1e-6) }
  }

  func testResumeReanchorsPauseWithoutResettingFractionalPhase() throws {
    let f = try format(.float32, rate: 44100)
    var paused = try ClockMappedPCMConverter(format: f, outputSampleRate: 48000)
    var continuous = paused
    let values = [Float](repeating: 0.5, count: 480)
    let data = values.withUnsafeBytes { Data($0) }
    let m = try mapping()
    let start = CMTime(value: 100, timescale: 1)
    let boundary = CMTimeAdd(start, CMTime(value: 480, timescale: 44100))
    let resumed = CMTimeAdd(boundary, CMTime(value: 1, timescale: 1))
    let first = try paused.convert(planes: [data], sampleFrameCount: 480, audioTime: start, mapping: m)
    _ = try continuous.convert(planes: [data], sampleFrameCount: 480, audioTime: start, mapping: m)
    try paused.resume(audioTime: resumed, mapping: m)
    let afterPause = try paused.convert(planes: [data], sampleFrameCount: 480, audioTime: resumed, mapping: m)
    let withoutPause = try continuous.convert(planes: [data], sampleFrameCount: 480, audioTime: boundary, mapping: m)
    XCTAssertEqual(afterPause.samples, withoutPause.samples)
    XCTAssertEqual(afterPause.sampleFrameCount, withoutPause.sampleFrameCount)
    XCTAssertEqual(afterPause.presentationTime.seconds - withoutPause.presentationTime.seconds, 1, accuracy: 1e-9)
    XCTAssertEqual(afterPause.presentationTime.seconds, first.presentationTime.seconds + Double(first.sampleFrameCount) / 48000 + 1, accuracy: 1e-9)
    XCTAssertEqual(paused.finish()?.samples, continuous.finish()?.samples)
  }

  func testPairedMultichannelSettingsKeep24BitAndCompleteLayout() throws {
    let labels = (0..<16).map { UInt32(kAudioChannelLabel_Discrete_0) + UInt32($0) }
    let f = try SourceAudioFormat(sampleRate: 48000, channels: 16, sample: .int32, interleaved: true,
      layout: AudioChannelMap(labels: labels), clock: .pairedWithFrames)
    let settings = try EmbeddedAudioFormat.assetWriterSettings(format: f, outputSampleRate: 48000)
    XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 16)
    XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 24)
    let layout = try XCTUnwrap(settings[AVChannelLayoutKey] as? Data)
    let count = layout.withUnsafeBytes { $0.loadUnaligned(as: AudioChannelLayout.self).mNumberChannelDescriptions }
    XCTAssertEqual(count, 16)
    let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
    let last = layout.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 15 * MemoryLayout<AudioChannelDescription>.stride, as: AudioChannelDescription.self).mChannelLabel }
    XCTAssertEqual(last, labels[15])
    let values = (0..<32).map { Int32($0 + 1) << 8 }
    let source = values.withUnsafeBytes { Data($0) }
    let sample = try makePaired24BitSample(sourcePCM32: source, sampleFrameCount: 2,
      format: f, presentationTime: CMTime(value: 500, timescale: 1))
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
    XCTAssertEqual(CMBlockBufferGetDataLength(block), 32 * 3)
    var packed = Data(count: 32 * 3)
    XCTAssertEqual(packed.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0,
      dataLength: $0.count, destination: $0.baseAddress!) }, noErr)
    XCTAssertEqual(packed, try EmbeddedAudioConverter.convert32BitIntegerPCMTo24BitPacked(source,
      channelCount: f.channels))
    for channel in 0..<16 { XCTAssertEqual(packed[channel * 3], UInt8(channel + 1)) }
    XCTAssertEqual(source, values.withUnsafeBytes { Data($0) })

  }

  func testWorkspaceBudgetRejectsBeforeConsumptionAtExactBoundary() throws {
    let f = try format(.float32)
    let m = try mapping()
    // 3 mono frames: 12 source + 3*12 decoded + 3*16 output bound.
    var exact = try ClockMappedPCMConverter(format: f, outputSampleRate: 48000, maximumWorkspaceBytes: 96)
    var below = try ClockMappedPCMConverter(format: f, outputSampleRate: 48000, maximumWorkspaceBytes: 95)
    let data = [Float](repeating: 0.25, count: 3).withUnsafeBytes { Data($0) }
    XCTAssertThrowsError(try below.convert(planes: [data], sampleFrameCount: 3,
      audioTime: CMTime(value: 100, timescale: 1), mapping: m)) { error in
      XCTAssertEqual(error as? ClockMappedPCMError, .workspaceLimit)
    }
    let chunk = try exact.convert(planes: [data], sampleFrameCount: 3,
      audioTime: CMTime(value: 100, timescale: 1), mapping: m)
    XCTAssertEqual(chunk.sampleFrameCount, 2)
    let tiny = [Float](repeating: 0.25, count: 2).withUnsafeBytes { Data($0) }
    XCTAssertEqual(try below.convert(planes: [tiny], sampleFrameCount: 2,
      audioTime: CMTime(value: 100, timescale: 1), mapping: m).presentationTime.seconds, 500)
    XCTAssertThrowsError(try exact.preflight(sampleFrameCount: Int.max, mapping: m))
    let multichannel = try format(.float32, channels: 65535)
    let huge = try ClockMappedPCMConverter(format: multichannel, outputSampleRate: 48000)
    XCTAssertThrowsError(try huge.preflight(sampleFrameCount: Int.max / 2, mapping: m))
  }

  func testFloatHeadroomSurvivesBridgeAndFinishWithoutClipping() throws {
    let f = try format(.float32)
    let values: [Float] = [1.25, -1.25, 0]
    let sample = try makeSourceSample(planes: [values.withUnsafeBytes { Data($0) }], sampleFrameCount: 3,
      format: f, presentationTime: CMTime(value: 100, timescale: 1))
    var bridge = try ClockMappedPCMBridge(format: f, outputSampleRate: 48000)
    let first = try XCTUnwrap(bridge.convert(sample, mapping: mapping()))
    let last = try XCTUnwrap(bridge.finish())
    var output = [Float]()
    for sample in [first, last] {
      let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
      var floats = [Float](repeating: 0, count: CMSampleBufferGetNumSamples(sample))
      XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats.count * 4,
        destination: &floats), noErr)
      output += floats
    }
    XCTAssertEqual(output, values)
  }

  func testGenericPairedFormatMatrixUsesMeasuredPairWithoutHostMapping() throws {
    for sampleType: AudioSampleType in [.int16, .int24in32, .int32, .float32] {
      for rate: Double in [44100, 96000, 48000.5] {
        let f = try SourceAudioFormat(sampleRate: rate, channels: 6, sample: sampleType, interleaved: false,
          layout: AudioChannelMap(), clock: .pairedWithFrames)
        let plane: Data
        switch sampleType {
        case .int16: plane = [Int16](repeating: 16384, count: 120).withUnsafeBytes { Data($0) }
        case .int24in32: plane = [Int32](repeating: 4194304, count: 120).withUnsafeBytes { Data($0) }
        case .int32: plane = [Int32](repeating: 1073741824, count: 120).withUnsafeBytes { Data($0) }
        case .float32: plane = [Float](repeating: 0.5, count: 120).withUnsafeBytes { Data($0) }
        }
        let source = try makeSourceSample(planes: Array(repeating: plane, count: 6), sampleFrameCount: 120,
          format: f, presentationTime: CMTime(value: 100, timescale: 1))
        if sampleType == .int24in32 {
          let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(source))
          let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
          XCTAssertEqual(asbd.mBitsPerChannel, 24)
          XCTAssertEqual(asbd.mBytesPerFrame, 4)
          XCTAssertEqual(asbd.mFormatFlags & (kAudioFormatFlagIsPacked | kAudioFormatFlagIsAlignedHigh), 0)
        }
        let outputRate = try recordingPCMOutputSampleRate(for: f)
        XCTAssertEqual(outputRate, rate.rounded())
        var bridge = try ClockMappedPCMBridge(format: f, outputSampleRate: outputRate)
        let pair = PCMClockTransform.paired(audioAnchor: CMTime(value: 100, timescale: 1), videoAnchor: CMTime(value: 500, timescale: 1))
        let output = try XCTUnwrap(bridge.convert(source, mapping: pair))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(output).seconds, 500)
        let tailCount = try bridge.finish().map { CMSampleBufferGetNumSamples($0) } ?? 0
        XCTAssertEqual(Double(CMSampleBufferGetNumSamples(output) + tailCount), 120 * outputRate / rate, accuracy: 1)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(output))
        var frame = [Float](repeating: 0, count: 6)
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 24, destination: &frame), noErr)
        XCTAssertEqual(frame, [Float](repeating: 0.5, count: 6))
      }
    }
  }

  private func inputSample(_ values: [Int16], channels: Int) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    var description: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
      layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
    let bytes = values.withUnsafeBytes { Data($0) }
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
      blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
      offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), noErr)
    let owned = try XCTUnwrap(block)
    XCTAssertEqual(bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: owned,
      offsetIntoDestination: 0, dataLength: $0.count) }, noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
      presentationTimeStamp: CMTime(value: 100, timescale: 1), decodeTimeStamp: .invalid)
    var size = channels * 2
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: owned,
      formatDescription: description, sampleCount: values.count / channels, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }

}
