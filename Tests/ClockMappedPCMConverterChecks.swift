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
  func testPlanarChannelsRemainDistinct() throws {
    var converter = try ClockMappedPCMConverter(format: format(.float32, channels: 2, interleaved: false), outputSampleRate: 48000)
    let chunk = try converter.convert(planes: [[Float](repeating: 0.25, count: 3).withUnsafeBytes { Data($0) },
      [Float](repeating: -0.5, count: 3).withUnsafeBytes { Data($0) }], sampleFrameCount: 3,
      audioTime: CMTime(value: 100, timescale: 1), mapping: mapping())
    XCTAssertEqual(chunk.samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, [0.25, -0.5, 0.25, -0.5])
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
