import AVFoundation
import VideoToolbox
import XCTest
@objcMembers final class RecordingB3TimecodeChecks: XCTestCase {
  func testVariableSourceRateIsRetainedAsImmutableTakeConfiguration() throws {
    let variable = FrameRate.variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    let configuration = try SourceRecordingConfiguration(feedID: .init("b3-vfr"), outputURL: URL(fileURLWithPath: "/tmp/b3-vfr.mov"), width: 16, height: 16, declaredTimebases: [240_000], quantizationPolicy: .nearest240000, sourceFrameRate: variable)
    XCTAssertEqual(configuration.sourceFrameRate, variable)
    let timebase = try RecordingTimebase.Configuration(frameRate: variable, declaredTimebases: [240_000], quantizationPolicy: .nearest240000)
    XCTAssertEqual(timebase.timescale, 240_000)
  }
  func testNativeTimecodeMetadataValidatesAndPreservesDropFrame() throws {
    let native = try XCTUnwrap(TimecodeMetadata.native(label: "01:02:03;04", frameRate: .fps2997, epoch: 7))
    XCTAssertTrue(native.dropFrame)
    let configuration = try SourceRecordingConfiguration(feedID: .init("b3-tmcd"), outputURL: URL(fileURLWithPath: "/tmp/b3-tmcd.mov"), width: 16, height: 16, nativeTimecodeMetadata: native, timecodePolicy: .source)
    XCTAssertEqual(configuration.nativeTimecodeMetadata, native)
    XCTAssertNotNil(try AVAssetSourceRecordingWriter.makeTimecodeTrack(for: configuration, frameRate: .fps2997))
    let actualConfig = try SourceRecordingConfiguration(feedID: .init("native-epoch"), outputURL: URL(fileURLWithPath: "/tmp/native-epoch-\(UUID().uuidString).mov"), width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ, frameRate: .fps2997, nativeTimecodeMetadata: native, timecodePolicy: .source)
    let writer = try AVAssetSourceRecordingWriter(configuration: actualConfig, encodeFrame: { _, _, _, _ in noErr })
    try writer.start()
    XCTAssertNoThrow(try writer.appendVideo(sample(pts: CMTime(value: 10, timescale: 1), duration: RecordingFrameRate.fps2997.frameDuration)))
    try writer.finish()
  }
  func testQuantizedSampleEventRetainsOriginalTimestampAndError() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sidecar = try RecordingTakeSidecar(movieURL: folder.appendingPathComponent("take.mov"), metadata: .init(sourceSignature: "source", outputSignature: "output"), maximumJournalBytes: 4096)
    try sidecar.append(.init(kind: "quantization", detail: "Original timing retained", originalValue: 1001, originalTimescale: 30000, quantizationErrorSeconds: 1.0 / 240000.0))
    let line = try String(contentsOf: sidecar.journalURL, encoding: .utf8)
    XCTAssertTrue(line.contains("1001")); XCTAssertTrue(line.contains("quantizationErrorSeconds"))
  }
  func testActualWriterMapsMixedScaleVFRBeforeFirstEncode() throws {
    let variable = FrameRate.variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    let config = try SourceRecordingConfiguration(feedID: .init("actual-vfr"), outputURL: URL(fileURLWithPath: "/tmp/unused-vfr-\(UUID().uuidString).mov"), width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ,
      declaredTimebases: [60000, 90000], sourceFrameRate: variable)
    var times: [CMTime] = [], durations: [CMTime] = []
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, _, pts, duration in times.append(pts); durations.append(duration); return noErr })
    try writer.start()
    try writer.appendVideo(sample(pts: CMTime(value: 900000, timescale: 90000), duration: CMTime(value: 1000, timescale: 60000)))
    try writer.appendVideo(sample(pts: CMTime(value: 901500, timescale: 90000), duration: CMTime(value: 3000, timescale: 90000)))
    XCTAssertEqual(times.count, 2)
    XCTAssertEqual(times.map(\.timescale), [180000, 180000])
    XCTAssertEqual(times.map(\.value), [0, 3000])
    XCTAssertEqual(durations.map(\.value), [3000, 6000])
    try writer.finish()
  }


  func testActualWriterPreservesEachNativeTimecodeThroughDelayedWriting() throws {
    let config = try SourceRecordingConfiguration(feedID: .init("native-tmcd"), outputURL: URL(fileURLWithPath: "/tmp/native-tmcd-\(UUID().uuidString).mov"),
      width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ, frameRate: .fps2997, timecodePolicy: .source)
    let values = RecordingNativeValues()
    let writer = try AVAssetSourceRecordingWriter(configuration: config, inputReady: { _ in true }, appendSample: { sample, input in
      if input.mediaType == .timecode, let block = CMSampleBufferGetDataBuffer(sample) {
        var bytes: UInt32 = 0
        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &bytes)
        values.lock.lock(); values.frames.append(Int64(UInt32(bigEndian: bytes))); values.lock.unlock()
      }
      return true
    })
    try writer.start()
    let first = try sample(pts: CMTime(value: 300000, timescale: 30000), duration: RecordingFrameRate.fps2997.frameDuration)
    let second = try sample(pts: CMTime(value: 301001, timescale: 30000), duration: RecordingFrameRate.fps2997.frameDuration)
    let labels = ["01:02:03:04", "05:06:07:08"]
    for (sample, label) in zip([first, second], labels) {
      let native = try XCTUnwrap(TimecodeMetadata.native(label: label, frameRate: .fps2997))
      CMSetAttachment(sample, key: SourceRecordingConfiguration.nativeTimecodeAttachmentKey as CFString,
        value: try JSONEncoder().encode(native) as CFData, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
      try writer.appendVideo(sample)
    }
    try? writer.finish() // append hook observes writer input without writing bytes.
    values.lock.lock(); let actual = values.frames; values.lock.unlock()
    XCTAssertEqual(actual, labels.map { RecordingTimecode(string: $0, frameRate: .fps2997)!.frameNumber })
  }

  func testActualWriterJournalsFullOriginalQuantizedTiming() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let variable = FrameRate.variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: variable),
      epochID: .init(sessionID: UUID(), epoch: 0), clockBindings: .init(video: .init(), audio: nil), stage: .recordingSource)
    let movie = folder.appendingPathComponent("take.mov")
    let config = try SourceRecordingConfiguration(feedID: .init("quantized-real"), outputURL: movie, width: 1920, height: 1080,
      videoCodec: kCMVideoCodecType_AppleProRes422HQ, quantizationPolicy: .nearest240000, sourceFrameRate: variable,
      sourceAdmission: source, sidecarMovieURL: movie)
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, _, _, _ in noErr })
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    let sourceDuration = CMTime(value: 33333333, timescale: 1000000000)
    try writer.appendVideo(sample(pts: CMTime(value: 10, timescale: 1), duration: sourceDuration))
    try writer.finish()
    let path = RecordingTakeSidecar.url(for: movie).appendingPathExtension("journal")
    let data = try Data(contentsOf: path)
    let event = try JSONDecoder().decode(RecordingTakeSidecar.Event.self, from: data.split(separator: 10).first.map(Data.init)!)
    XCTAssertEqual(event.originalTiming?.duration.value, sourceDuration.value)
    XCTAssertEqual(event.originalTiming?.duration.timescale, sourceDuration.timescale)
    XCTAssertEqual(event.originalTiming?.takeOrigin.value, 10)
    XCTAssertNotNil(event.durationErrorSeconds)
    XCTAssertEqual(try RecordingTakeSidecar.readSnapshot(for: movie).metadata.timestampTimescale, 240000)
  }

  func testCFRWithoutDeclaredFutureTicksSelectsExactCadenceScale() throws {
    let configuration = try RecordingTimebase.Configuration(frameRate: .constant(CMTime(value: 2002, timescale: 60000)), declaredTimebases: nil)
    XCTAssertEqual(configuration.timescale, 30000)
    var mapper = try RecordingTimebase(configuration: configuration, origin: CMTime(value: 10, timescale: 1))
    XCTAssertEqual(try mapper.append(pts: CMTime(value: 900000, timescale: 90000), duration: CMTime(value: 1001, timescale: 30000)).presentationTime.value, 0)
    XCTAssertThrowsError(try mapper.append(pts: CMTime(value: 10000001, timescale: 1000000), duration: CMTime(value: 1001, timescale: 30000)))
  }

  func testMappedPCMUsesVideoOriginAndSurvivesAudioFirstResume() throws {
    let f = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .int16, interleaved: true, layout: .init(), clock: .deviceClock)
    let videoMap = try ClockMapping(sourceAnchor: CMTime(value: 500, timescale: 1), hostAnchor: CMTime(value: 900, timescale: 1), rate: .one)
    let audioMap = try ClockMapping(sourceAnchor: CMTime(value: 100, timescale: 1), hostAnchor: CMTime(value: 900, timescale: 1), rate: .one)
    let mapping = try AudioVideoClockMapping(audio: audioMap, video: videoMap)
    let duration = RecordingFrameRate.fps2997.frameDuration
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(duration)), epochID: .init(sessionID: UUID(), epoch: 0), clockBindings: .init(video: .init(), audio: .init()), stage: .recordingSource)
    let config = try SourceRecordingConfiguration(feedID: .init("mapped-pause"), outputURL: URL(fileURLWithPath: "/tmp/mapped-pause-\(UUID().uuidString).mov"), width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ, frameRate: .fps2997, sourceFrameRate: .constant(duration), sourceAdmission: source)
    let values = RecordingNativeValues()
    let writer = try AVAssetSourceRecordingWriter(configuration: config, inputReady: { _ in true }, appendSample: { sample, input in
      if input.mediaType == .audio { values.lock.lock(); values.audioPTS.append(CMSampleBufferGetPresentationTimeStamp(sample)); values.lock.unlock() }
      return true
    })
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .present(f), mappingRevision: 1, videoMapping: videoMap, audioMapping: audioMap))
    let bytes = [Int16](repeating: 12000, count: 480).withUnsafeBytes { Data($0) }
    try writer.appendVideo(sample(pts: CMTime(value: 500, timescale: 1), duration: duration))
    try writer.appendSourceAudio(makeSourceSample(planes: [bytes], sampleFrameCount: 480, format: f, presentationTime: CMTime(value: 100, timescale: 1)), mapping: mapping)
    writer.resumeAfterPause()
    XCTAssertNoThrow(try writer.appendSourceAudio(makeSourceSample(planes: [bytes], sampleFrameCount: 480, format: f, presentationTime: CMTime(value: 110, timescale: 1)), mapping: mapping))
    try writer.appendVideo(sample(pts: CMTime(value: 510, timescale: 1), duration: duration))
    do { try writer.finish() } catch {
      if writer.hasFailed { XCTFail("Writer failed before audio observation: \(error); \(writer.telemetry)") }
    }
    values.lock.lock(); let audioPTS = values.audioPTS; values.lock.unlock()
    XCTAssertGreaterThanOrEqual(audioPTS.count, 2)
    XCTAssertEqual(audioPTS.first?.seconds ?? -1, 0, accuracy: 1e-9)
    if audioPTS.count > 1 { XCTAssertEqual(audioPTS[1].seconds, duration.seconds, accuracy: 1.0 / 48000) }
  }

  func testCoreRefusesOneAudioPacketBeyondDurationBudgetBeforeRetention() throws {
    let format = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .int16, interleaved: true, layout: .init(), clock: .pairedWithFrames)
    let config = try SourceRecordingConfiguration(feedID: .init("audio-retention"), outputURL: URL(fileURLWithPath: "/tmp/unused-retention.mov"), width: 1920, height: 1080)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { RecordingNoopWriter() })
    try core.start()
    let packet = try makeSourceSample(planes: [Data(count: 480000 * 2)], sampleFrameCount: 480000,
      format: format, presentationTime: .zero)
    XCTAssertFalse(core.appendAudio(packet))
    XCTAssertEqual(core.telemetry.enqueuedAudio, 0)
    XCTAssertEqual(core.state, .failed)
    try core.stop()
    XCTAssertEqual(core.audioRetentionSnapshot.currentBytes, 0)
    let accepted = try SourceRecorderCore(configuration: config, writerFactory: { RecordingNoopWriter() })
    try accepted.start()
    XCTAssertTrue(accepted.appendAudio(try makeSourceSample(planes: [Data(count: 480 * 2)], sampleFrameCount: 480, format: format, presentationTime: .zero)))
    try accepted.stop()
    XCTAssertEqual(accepted.audioRetentionSnapshot.currentBytes, 0)
    XCTAssertEqual(accepted.audioRetentionSnapshot.released, 1)
  }

  func testActualWriterUsesDeclaredRationalCFRCadenceWithoutInventedTicks() throws {
    for rate in [RecordingFrameRate.fps25, .fps23976, .fps47952, .fps11988] {
      let config = try SourceRecordingConfiguration(feedID: .init("rational-cfr"), outputURL: URL(fileURLWithPath: "/tmp/rational-\(UUID().uuidString).mov"), width: 1920, height: 1080,
        videoCodec: kCMVideoCodecType_AppleProRes422HQ, frameRate: rate, sourceFrameRate: .constant(rate.frameDuration), timecodePolicy: .wallClock)
      var encodedPTS: CMTime?, encodedDuration: CMTime?
      let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, _, pts, duration in encodedPTS = pts; encodedDuration = duration; return noErr })
      try writer.start()
      try writer.appendVideo(sample(pts: CMTime(value: 10, timescale: 1), duration: rate.frameDuration))
      XCTAssertEqual(encodedPTS?.value, 0)
      XCTAssertEqual(encodedDuration.map { CMTimeCompare($0, rate.frameDuration) }, 0)
      XCTAssertEqual(encodedDuration?.timescale, rate.frameDuration.timescale)
      let track = try XCTUnwrap(AVAssetSourceRecordingWriter.makeTimecodeTrack(for: config, frameRate: rate))
      XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(track.formatDescription), UInt32(rate.nominalFramesPerSecond))
      XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(track.formatDescription) & UInt32(kCMTimeCodeFlag_DropFrame), 0)
      try writer.finish()
    }
  }

  func testTinyPCMCallbacksAreBoundedByTimeRatherThanLegacy256Packets() throws {
    for rate in [96000.0, 192000.0] {
      let format = try SourceAudioFormat(sampleRate: rate, channels: 1, sample: .int16, interleaved: true, layout: .init(), clock: .deviceClock)
      let config = try SourceRecordingConfiguration(feedID: .init("tiny-pcm"), outputURL: URL(fileURLWithPath: "/tmp/unused-tiny.mov"), width: 16, height: 16)
      let blocked = RecordingHoldingAudioWriter()
      let core = try SourceRecorderCore(configuration: config, writerFactory: { blocked })
      try core.start()
      let packet = try makeSourceSample(planes: [Data(count: 256)], sampleFrameCount: 128, format: format, presentationTime: .zero)
      let allowed = Int(rate * 4) / 128
      var admitted = 0
      for _ in 0..<allowed {
        guard core.appendAudio(packet) else { break }
        admitted += 1
      }
      XCTAssertEqual(admitted, allowed)
      XCTAssertGreaterThan(admitted, 256)
      XCTAssertFalse(core.appendAudio(packet))
      XCTAssertLessThanOrEqual(core.audioRetentionSnapshot.peakDuration, 4.000000001)
      XCTAssertLessThanOrEqual(core.audioRetentionSnapshot.peakBytes, 64 * 1024 * 1024)
      blocked.release.signal()
      try core.stop()
      XCTAssertEqual(core.audioRetentionSnapshot.currentSlots, 0)
    }
  }

  func testActualWriterPreservesPairedEightAndSixteenChannelPCM() throws {
    for channels in [8, 16] {
      let format = try SourceAudioFormat(sampleRate: 48000, channels: channels, sample: .int32, interleaved: true, layout: .init(), clock: .pairedWithFrames)
      let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(RecordingFrameRate.fps5994.frameDuration)), epochID: .init(sessionID: UUID(), epoch: 0), clockBindings: .init(video: .init(), audio: nil), stage: .recordingSource)
      let config = try SourceRecordingConfiguration(feedID: .init("paired-n"), outputURL: URL(fileURLWithPath: "/tmp/paired-n-\(UUID().uuidString).mov"), width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ, sourceAdmission: source)
      let values = RecordingNativeValues()
      let writer = try AVAssetSourceRecordingWriter(configuration: config, inputReady: { _ in true }, appendSample: { sample, input in
        if input.mediaType == .audio, let description = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
          values.lock.lock(); values.audioChannels.append(Int(asbd.mChannelsPerFrame)); values.audioBytes.append(CMSampleBufferGetTotalSampleSize(sample)); values.lock.unlock()
        }
        return true
      })
      try writer.start()
      try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .present(format)))
      let pcm = [Int32](repeating: 0x11223300, count: 16 * channels).withUnsafeBytes { Data($0) }
      try writer.appendAudio(makePaired24BitSample(sourcePCM32: pcm, sampleFrameCount: 16, format: format, presentationTime: .zero))
      try writer.appendVideo(sample(pts: .zero, duration: RecordingFrameRate.fps5994.frameDuration))
      try? writer.finish()
      values.lock.lock(); let actualChannels = values.audioChannels; let actualBytes = values.audioBytes; values.lock.unlock()
      XCTAssertEqual(actualChannels, [channels])
      XCTAssertEqual(actualBytes, [16 * channels * 3])
    }
  }

  func testActualEncoderUsesOneSecondKeyframePolicyAt25And120() throws {
    for rate in [RecordingFrameRate.fps25, .fps120] {
      let config = try SourceRecordingConfiguration(feedID: .init("keyframe-seconds"), outputURL: URL(fileURLWithPath: "/tmp/keyframe-seconds-\(UUID().uuidString).mov"), width: 1920, height: 1080,
        frameRate: rate, sourceFrameRate: .constant(rate.frameDuration))
      var seconds: Double?, frames: Int?
      let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, _, _, _ in
        var value: Unmanaged<CFTypeRef>?
        if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, allocator: nil, valueOut: &value) == noErr {
          seconds = (value?.takeRetainedValue() as? NSNumber)?.doubleValue
        }
        value = nil
        if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, allocator: nil, valueOut: &value) == noErr {
          frames = (value?.takeRetainedValue() as? NSNumber)?.intValue
        }
        return noErr
      })
      try writer.start()
      try writer.appendVideo(sample(pts: .zero, duration: rate.frameDuration))
      XCTAssertEqual(seconds, 1)
      XCTAssertNotEqual(frames, 60)
      try writer.finish()
    }
  }

  func testCoreGapPolicyUsesElapsedSecondsAndDoesNotInventVFRSkips() throws {
    for rate in [RecordingFrameRate.fps25, .fps120] {
      let config = try SourceRecordingConfiguration(feedID: .init("gap-seconds"), outputURL: URL(fileURLWithPath: "/tmp/unused-gap.mov"), width: 1920, height: 1080,
        frameRate: rate, sourceFrameRate: .constant(rate.frameDuration))
      let core = try SourceRecorderCore(configuration: config, writerFactory: { RecordingNoopWriter() })
      try core.start()
      XCTAssertTrue(core.appendVideo(try sample(pts: .zero, duration: rate.frameDuration)))
      let accepted = core.appendVideo(try sample(pts: CMTime(value: rate == .fps25 ? 12 : 8, timescale: 1), duration: rate.frameDuration))
      if rate == .fps25 {
        XCTAssertFalse(accepted)
        XCTAssertEqual(core.state, .failed)
        XCTAssertEqual(core.telemetry.deviceSkippedFrames, 0)
        XCTAssertTrue(core.telemetry.lastError?.contains("discontinuity") == true)
      } else {
        XCTAssertTrue(accepted)
        XCTAssertEqual(core.state, .recording)
        XCTAssertEqual(core.telemetry.deviceSkippedFrames, 959)
      }
      try core.stop()
    }
    let vfr = FrameRate.variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    let config = try SourceRecordingConfiguration(feedID: .init("vfr-no-skips"), outputURL: URL(fileURLWithPath: "/tmp/unused-vfr-skips.mov"), width: 1920, height: 1080, declaredTimebases: [30000], sourceFrameRate: vfr)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { RecordingNoopWriter() })
    try core.start()
    XCTAssertTrue(core.appendVideo(try sample(pts: .zero, duration: vfr.nominal)))
    XCTAssertTrue(core.appendVideo(try sample(pts: CMTime(value: 8, timescale: 1), duration: vfr.nominal)))
    XCTAssertEqual(core.telemetry.deviceSkippedFrames, 0)
    XCTAssertEqual(core.state, .recording)
    try core.stop()
  }

  func testExplicitConstantRecordingConformsVFRIntoActualMovieGrid() throws {
    for frequency in [30, 37] {
    let ticks: Int32 = Int32(frequency * 2000)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cfr-option-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("take.mov")
    let rate = FrameRate.variable(nominal: CMTime(value: 1, timescale: Int32(frequency)), shortest: CMTime(value: 1, timescale: Int32(frequency * 2)), longest: frequency == 37 ? CMTime(value: 2, timescale: 37) : CMTime(value: 1, timescale: 10))
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: rate),
      epochID: .init(sessionID: UUID(), epoch: 1), clockBindings: .init(video: .init()), stage: .recordingSource)
    let config = try SourceRecordingConfiguration(feedID: .init("cfr-option"), outputURL: url, width: 1920, height: 1080,
      videoCodec: kCMVideoCodecType_AppleProRes422HQ, frameRate: .fps5994, declaredTimebases: [ticks], sourceFrameRate: rate, recordingConstantFrameRate: true, sourceAdmission: source, compatibilityPolicy: .init(allowCPUConversion: true), sidecarMovieURL: url)
    var times: [CMTime] = [], durations: [CMTime] = []
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, pts, duration in
      times.append(pts); durations.append(duration)
      return VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    })
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    for (pts, duration) in [(0, 1000), (1000, frequency == 37 ? 4000 : 5000), (6000, 2000)] {
      let frame = try sample(pts: CMTime(value: Int64(pts), timescale: ticks), duration: CMTime(value: Int64(duration), timescale: ticks))
      if pts == 0 {
        let original = RecordingSourceProvenance(epochID: .init(sessionID: source.epochID.sessionID, epoch: 0),
          formatSignature: source.formatSignature, videoClock: source.clockBindings.video)
        CMSetAttachment(frame, key: SourceRecordingConfiguration.sourceProvenanceAttachmentKey as CFString,
          value: try JSONEncoder().encode(original) as CFData, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
      }
      try writer.appendVideo(frame)
    }
    writer.resumeAfterPause()
    try writer.appendVideo(sample(pts: CMTime(value: 10, timescale: 1), duration: rate.nominal))
    try writer.finish()
    XCTAssertEqual(times.count, 5)
    for (index, time) in times.enumerated() { XCTAssertEqual(CMTimeCompare(time, CMTime(value: Int64(index), timescale: Int32(frequency))), 0) }
    XCTAssertTrue(durations.allSatisfy { CMTimeCompare($0, rate.nominal) == 0 })
    XCTAssertEqual(writer.telemetry.encodedVideo, 5)
    XCTAssertEqual(writer.telemetry.cadenceRepeatedFrames, 1)
    XCTAssertEqual(writer.telemetry.cadenceSkippedFrames, 0)
    let sidecar = try RecordingTakeSidecar.readSnapshot(for: url)
    XCTAssertEqual(sidecar.metadata.sourceFormat?.rate, rate)
    XCTAssertEqual(sidecar.metadata.outputContract?.rate, .constant(rate.nominal))
    XCTAssertEqual(sidecar.counters["recording.cadenceRepeatedFrames"], 1)
    XCTAssertEqual(sidecar.counters["recording.cadenceSkippedFrames"], 0)
    let journal = try String(contentsOf: RecordingTakeSidecar.url(for: url).appendingPathExtension("journal"), encoding: .utf8)
    XCTAssertTrue(journal.contains("cadenceSourceTiming"))
    XCTAssertTrue(journal.contains("sourceDurationValue"))
    let events = try journal.split(separator: "\n").map { try JSONDecoder().decode(RecordingTakeSidecar.Event.self, from: Data($0.utf8)) }
    let provenance = try XCTUnwrap(events.first { $0.kind == "openingSourceProvenance" }?.sourceProvenance)
    XCTAssertEqual(provenance.epochID.epoch, 0)
    XCTAssertEqual(provenance.epochID.sessionID, source.epochID.sessionID)
    XCTAssertEqual(sidecar.metadata.epoch, source.epochID)
    let asset = AVURLAsset(url: url)
    let loaded = RecordingMovieTrackResult()
    Task {
      do { loaded.track = try await asset.loadTracks(withMediaType: .video).first }
      catch { loaded.error = error }
      loaded.done.signal()
    }
    XCTAssertEqual(loaded.done.wait(timeout: .now() + 5), .success)
    if let error = loaded.error { throw error }
    let track = try XCTUnwrap(loaded.track)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var movieTimes: [CMTime] = [], movieDurations: [CMTime] = []
    while let sample = output.copyNextSampleBuffer() {
      // Fragmented MOV readers also emit empty boundary markers.
      guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
      movieTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
      movieDurations.append(CMSampleBufferGetDuration(sample))
    }
    XCTAssertEqual(movieTimes.count, 5)
    for (index, time) in movieTimes.enumerated() { XCTAssertEqual(CMTimeCompare(time, CMTime(value: Int64(index), timescale: Int32(frequency))), 0) }
    XCTAssertTrue(movieDurations.allSatisfy { CMTimeCompare($0, rate.nominal) == 0 })
    XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0, 0)
    }
  }

  func testQuantizedVFRResumeStaysOnItsSelectedTrackGrid() throws {
    let variable = FrameRate.variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    let config = try SourceRecordingConfiguration(feedID: .init("quantized-pause"), outputURL: URL(fileURLWithPath: "/tmp/unused-quantized-pause-\(UUID().uuidString).mov"),
      width: 1920, height: 1080, quantizationPolicy: .nearest240000, sourceFrameRate: variable)
    var times: [CMTime] = []
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, _, pts, _ in times.append(pts); return noErr })
    try writer.start()
    try writer.appendVideo(sample(pts: .zero, duration: variable.nominal))
    writer.resumeAfterPause()
    try writer.appendVideo(sample(pts: CMTime(value: 1_000_000_001, timescale: 1_000_000_000), duration: variable.nominal))
    XCTAssertEqual(times.count, 2)
    XCTAssertEqual(CMTimeCompare(times[1], variable.nominal), 0)
    XCTAssertEqual(times[1].timescale, 240000)
    try writer.finish()
  }

  func testOpeningPCMRetainsOriginalClockEpochAndTimestampBeforeConversion() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-provenance-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("take.mov")
    let duration = RecordingFrameRate.fps2997.frameDuration
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .int16, interleaved: true, layout: .init(), clock: .deviceClock)
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(duration)),
      epochID: .init(sessionID: UUID(), epoch: 1), clockBindings: .init(video: .init(), audio: .init()), stage: .recordingSource)
    let aMap = try ClockMapping(sourceAnchor: CMTime(value: 100, timescale: 1), hostAnchor: .zero, rate: .one)
    let vMap = try ClockMapping(sourceAnchor: CMTime(value: 500, timescale: 1), hostAnchor: .zero, rate: .one)
    let mapping = try AudioVideoClockMapping(audio: aMap, video: vMap)
    let config = try SourceRecordingConfiguration(feedID: .init("pcm-provenance"), outputURL: movie, width: 1920, height: 1080,
      sourceFrameRate: .constant(duration), sourceAdmission: source, sidecarMovieURL: movie)
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    try writer.start()
    try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .present(audio), mappingRevision: 1, videoMapping: vMap, audioMapping: aMap))
    func packet(at time: CMTime, clock: ClockInstanceID) throws -> CMSampleBuffer {
      let sample = try makeSourceSample(planes: [Data(count: 960)], sampleFrameCount: 480, format: audio, presentationTime: time)
      let original = RecordingSourceProvenance(epochID: .init(sessionID: source.epochID.sessionID, epoch: 0),
        formatSignature: source.formatSignature, videoClock: source.clockBindings.video)
      var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
      json["audioClock"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clock))
      CMSetAttachment(sample, key: SourceRecordingConfiguration.sourceProvenanceAttachmentKey as CFString,
        value: try JSONSerialization.data(withJSONObject: json) as CFData, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
      return sample
    }
    let originalPTS = CMTime(value: 100, timescale: 1)
    let first = try packet(at: originalPTS, clock: XCTUnwrap(source.clockBindings.audio))
    try writer.appendSourceAudio(first, mapping: mapping)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first), originalPTS)
    try writer.appendSourceAudio(packet(at: CMTime(value: 10001, timescale: 100), clock: XCTUnwrap(source.clockBindings.audio)), mapping: mapping)
    let converted = writer.telemetry.mappedAudioFrames
    XCTAssertThrowsError(try writer.appendSourceAudio(packet(at: CMTime(value: 10002, timescale: 100), clock: .init()), mapping: mapping))
    XCTAssertEqual(writer.telemetry.mappedAudioFrames, converted, "Refused provenance must not advance the PCM bridge")
    try writer.appendVideo(sample(pts: CMTime(value: 500, timescale: 1), duration: duration))
    try writer.finish()
    let data = try String(contentsOf: RecordingTakeSidecar.url(for: movie).appendingPathExtension("journal"), encoding: .utf8)
    let events = try data.split(separator: "\n").map { try JSONDecoder().decode(RecordingTakeSidecar.Event.self, from: Data($0.utf8)) }
    XCTAssertEqual(events.filter { $0.kind == "openingAudioSourceProvenance" }.count, 1, "Opening PCM provenance is journaled per epoch, not per packet")
    let event = try XCTUnwrap(events.first { $0.kind == "openingAudioSourceProvenance" })
    XCTAssertEqual(event.originalValue, originalPTS.value)
    XCTAssertEqual(event.originalTimescale, originalPTS.timescale)
    XCTAssertEqual(event.sourceProvenance?.epochID.epoch, 0)
    XCTAssertEqual(event.sourceProvenance?.audioClock, source.clockBindings.audio)
    XCTAssertEqual(event.sourceDurationValue, CMSampleBufferGetDuration(first).value)
    XCTAssertEqual(event.sourceDurationTimescale, CMSampleBufferGetDuration(first).timescale)
    XCTAssertEqual(try RecordingTakeSidecar.readSnapshot(for: movie).metadata.epoch, source.epochID)
  }

  func testFinishRethrowsFirstEncoderCallbackFailureWithoutCreatingMovie() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("take.mov")
    let duration = RecordingFrameRate.fps2997.frameDuration
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(duration)),
      epochID: .init(sessionID: UUID(), epoch: 0), clockBindings: .init(video: .init()), stage: .recordingSource)
    let config = try SourceRecordingConfiguration(feedID: .init("callback-failure"), outputURL: movie, width: 1920, height: 1080,
      sourceFrameRate: .constant(duration), sourceAdmission: source, sidecarMovieURL: movie)
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    try writer.start(); try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    writer.recordEncoderFailure(status: -50)
    XCTAssertTrue(writer.hasFailed)
    XCTAssertThrowsError(try writer.finish()) { XCTAssertTrue($0.localizedDescription.contains("-50")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
    let sidecar = try RecordingTakeSidecar.readSnapshot(for: movie)
    XCTAssertTrue(sidecar.finished)
    XCTAssertTrue(sidecar.finalError?.contains("-50") == true)
  }

  func testFailedTimecodeDrainStillFinalizesAcceptedMovieVideo() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("timecode-stall-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("take.mov")
    let config = try SourceRecordingConfiguration(feedID: .init("timecode-stall"), outputURL: movie, width: 1920, height: 1080, timecodePolicy: .recordStart)
    let writer = try AVAssetSourceRecordingWriter(configuration: config, inputReady: { $0.mediaType != .timecode })
    try writer.start()
    try writer.appendVideo(sample(pts: .zero, duration: RecordingFrameRate.fps2997.frameDuration))
    XCTAssertThrowsError(try writer.finish()) { XCTAssertTrue($0.localizedDescription.contains("timecode")) }
    let asset = AVURLAsset(url: movie)
    let loaded = RecordingMovieTrackResult()
    Task {
      do { loaded.track = try await asset.loadTracks(withMediaType: .video).first }
      catch { loaded.error = error }
      loaded.done.signal()
    }
    XCTAssertEqual(loaded.done.wait(timeout: .now() + 5), .success)
    if let error = loaded.error { throw error }
    let track = try XCTUnwrap(loaded.track, "Accepted video must remain readable after timecode failure")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output); XCTAssertTrue(reader.startReading())
    var frames = 0
    while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
    XCTAssertEqual(frames, 1)
  }

  func testNativeMetadataJournalRetainsLateCFRAndFullVFREpochs() throws {
    for variable in [false, true] {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-metadata-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let movie = folder.appendingPathComponent("take.mov")
      let duration = RecordingFrameRate.fps2997.frameDuration
      let rate: FrameRate = variable ? .variable(nominal: duration, shortest: CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2), longest: CMTimeMultiply(duration, multiplier: 2)) : .constant(duration)
      let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: rate),
        epochID: .init(sessionID: UUID(), epoch: 1), clockBindings: .init(video: .init()), stage: .recordingSource)
      let config = try SourceRecordingConfiguration(feedID: .init("native-metadata"), outputURL: movie, width: 1920, height: 1080,
        declaredTimebases: [30000], sourceFrameRate: rate, sourceAdmission: source, sidecarMovieURL: movie)
      let writer = try AVAssetSourceRecordingWriter(configuration: config)
      try writer.start(); try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
      for index in 0..<3 {
        let frame = try sample(pts: CMTimeMultiply(duration, multiplier: Int32(index)), duration: duration)
        if index > 0 {
          let native = try XCTUnwrap(TimecodeMetadata.native(label: "01:02:03:04", frameRate: index == 1 ? .fps2997 : .fps5994, epoch: Int64(index + 6)))
          CMSetAttachment(frame, key: SourceRecordingConfiguration.nativeTimecodeAttachmentKey as CFString,
            value: try JSONEncoder().encode(native) as CFData, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        }
        try writer.appendVideo(frame)
      }
      try writer.finish()
      let lines = try String(contentsOf: RecordingTakeSidecar.url(for: movie).appendingPathExtension("journal"), encoding: .utf8)
      let events = try lines.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
      let labels = events.filter { $0["kind"] as? String == "nativeTimecode" }
      XCTAssertEqual(labels.count, 2, "Missing first label must not erase later observations")
      let metadata = labels.compactMap { $0["nativeTimecodeMetadata"] as? [String: Any] }
      XCTAssertEqual(metadata.count, 2)
      XCTAssertEqual(metadata.compactMap { ($0["epoch"] as? NSNumber)?.intValue }, [7, 8])
      XCTAssertEqual(metadata.compactMap { ($0["rateNumerator"] as? NSNumber)?.intValue }, [30000, 60000])
      let typed = try lines.split(separator: "\n").map { try JSONDecoder().decode(RecordingTakeSidecar.Event.self, from: Data($0.utf8)) }.compactMap(\.nativeTimecodeMetadata)
      XCTAssertEqual(typed.map(\.epoch), [7, 8])
      XCTAssertEqual(typed.map(\.frameRate), [.fps2997, .fps5994])
    }
  }

  func testGenericPairedPCMRecordsActualFormatsWithoutHostMappings() throws {
    let formats = [
      try SourceAudioFormat(sampleRate: 44100, channels: 1, sample: .int16, interleaved: true, layout: .init(), clock: .pairedWithFrames),
      try SourceAudioFormat(sampleRate: 96000, channels: 6, sample: .float32, interleaved: false, layout: .init(), clock: .pairedWithFrames),
      try SourceAudioFormat(sampleRate: 48000.5, channels: 2, sample: .float32, interleaved: true, layout: .init(), clock: .pairedWithFrames),
      try SourceAudioFormat(sampleRate: 48000, channels: 8, sample: .int32, interleaved: true, layout: .init(), clock: .pairedWithFrames)
    ]
    for format in formats {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paired-generic-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let movie = folder.appendingPathComponent("take.mov")
      let duration = RecordingFrameRate.fps2997.frameDuration
      let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(duration)),
        epochID: .init(sessionID: UUID(), epoch: 0), clockBindings: .init(video: .init()), stage: .recordingSource)
      let config = try SourceRecordingConfiguration(feedID: .init("paired-generic"), outputURL: movie, width: 1920, height: 1080,
        sourceFrameRate: .constant(duration), sourceAdmission: source, sidecarMovieURL: movie)
      let writer = try AVAssetSourceRecordingWriter(configuration: config)
      try writer.start(); try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .present(format)))
      let frames = 480
      let planes = (0..<(format.interleaved ? 1 : format.channels)).map { _ in Data(count: frames * format.sample.bytesPerSample * (format.interleaved ? format.channels : 1)) }
      let packet = try makeSourceSample(planes: planes, sampleFrameCount: frames, format: format, presentationTime: CMTime(value: 100, timescale: 1))
      XCTAssertNoThrow(try writer.appendPairedSourceAudio(packet, videoTime: CMTime(value: 500, timescale: 1)))
      try writer.appendVideo(sample(pts: CMTime(value: 500, timescale: 1), duration: duration))
      try writer.finish()
      if format.sample != .int32 { XCTAssertGreaterThan(writer.telemetry.mappedAudioFrames, 0) }
      let metadata = try RecordingTakeSidecar.readSnapshot(for: movie).metadata
      XCTAssertEqual(metadata.audioOutputSampleRate, format.sampleRate.rounded())
      let asset = AVURLAsset(url: movie)
      let loaded = RecordingMovieTrackResult()
      Task {
        do {
          loaded.track = try await asset.loadTracks(withMediaType: .audio).first
          loaded.assetDuration = try await asset.load(.duration)
          if let track = loaded.track { loaded.range = try await track.load(.timeRange) }
        }
        catch { loaded.error = error }
        loaded.done.signal()
      }
      XCTAssertEqual(loaded.done.wait(timeout: .now() + 5), .success)
      if let error = loaded.error { throw error }
      let track = try XCTUnwrap(loaded.track)
      XCTAssertLessThan(loaded.assetDuration?.seconds ?? .infinity, 1, "The measured source origin must not become an empty movie gap")
      XCTAssertEqual(loaded.range?.start.seconds ?? -1, 0, accuracy: 1.0 / format.sampleRate)
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      reader.add(output); XCTAssertTrue(reader.startReading())
      var found = false
      while let packet = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(packet) > 0 else { continue }
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(packet))
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        XCTAssertEqual(asbd.mSampleRate, format.sampleRate.rounded())
        XCTAssertEqual(asbd.mChannelsPerFrame, UInt32(format.channels))
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, format.sample == .int32 ? 0 : kAudioFormatFlagIsFloat)
        if format.sample == .int32 { XCTAssertEqual(asbd.mBitsPerChannel, 24) }
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(packet), .zero), 0)
        found = true; break
      }
      XCTAssertTrue(found, "Actual MOV must contain paired PCM at the measured video origin")
    }
  }

  func testFirstMovieOpenFailureFinishesSidecarWithOriginalError() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("open-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("occupied.mov")
    try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: true)
    let duration = RecordingFrameRate.fps2997.frameDuration
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(duration)),
      epochID: .init(sessionID: UUID(), epoch: 0), clockBindings: .init(video: .init()), stage: .recordingSource)
    let config = try SourceRecordingConfiguration(feedID: .init("open-failure"), outputURL: movie, width: 1920, height: 1080,
      sourceFrameRate: .constant(duration), sourceAdmission: source, sidecarMovieURL: movie)
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    try writer.start(); try writer.bindTakeContext(.init(sourceAdmission: source, audioDeclaration: .absent))
    try writer.appendVideo(sample(pts: .zero, duration: duration))
    XCTAssertThrowsError(try writer.finish())
    XCTAssertTrue(writer.hasFailed)
    let sidecar = try RecordingTakeSidecar.readSnapshot(for: movie)
    XCTAssertTrue(sidecar.finished)
    XCTAssertNotNil(sidecar.finalError)
  }

  private func sample(pts: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }

}

private final class RecordingNativeValues: @unchecked Sendable {
  let lock = NSLock()
  var frames: [Int64] = []
  var audioPTS: [CMTime] = []
  var audioChannels: [Int] = []
  var audioBytes: [Int] = []
}

private final class RecordingNoopWriter: SourceRecordingWriter {
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {}
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func finish() throws {}
}

private final class RecordingHoldingAudioWriter: SourceRecordingWriter, @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private var first = true
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {}
  func appendAudio(_ sample: CMSampleBuffer) throws {
    if first { first = false; release.wait() }
  }
  func finish() throws {}
}

private final class RecordingMovieTrackResult: @unchecked Sendable {
  let done = DispatchSemaphore(value: 0)
  var track: AVAssetTrack?
  var range: CMTimeRange?
  var assetDuration: CMTime?
  var error: Error?
}
