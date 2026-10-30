import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
import VideoToolbox

/// A writer that retains only synthetic sample timing. It makes the recording
/// boundary observable without invoking AVAssetWriter or a hardware encoder.
private final class SyntheticSourceWriter: SourceRecordingWriter, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var started = false
  private(set) var finished = false
  private(set) var videoSamples: [CMSampleBuffer] = []
  private(set) var audioSamples: [CMSampleBuffer] = []

  func start() throws {
    lock.withLock {
      precondition(!started)
      started = true
    }
  }

  func appendVideo(_ sample: CMSampleBuffer) throws {
    lock.withLock { videoSamples.append(sample) }
  }

  func appendAudio(_ sample: CMSampleBuffer) throws {
    lock.withLock { audioSamples.append(sample) }
  }

  func finish() throws {
    lock.withLock {
      precondition(started)
      finished = true
    }
  }
}

@objcMembers final class RecordingEndToEndChecks: XCTestCase {
  private func videoSample(at time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    XCTAssertEqual(status, kCVReturnSuccess)
    return try VideoContract.sample(try XCTUnwrap(pixelBuffer), at: time, duration: duration)
  }

  private func audioSample(at time: CMTime, frameCount: Int = 800) throws -> CMSampleBuffer {
    let source = Data(repeating: 0, count: frameCount * EmbeddedAudioFormat.channelCount * 4)
    let packet = try EmbeddedAudioPacket(sourcePCM32: source, sampleFrameCount: frameCount,
      presentationTime: time)
    return try EmbeddedAudioRecording.makeSampleBuffer(for: packet)
  }

  private func configuration(feed: String, url: URL, queueCapacity: Int = 12,
                             realTimeEncoding: Bool = true,
                             maxKeyFrameInterval: Int = 60) throws -> SourceRecordingConfiguration {
    try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed), outputURL: url,
      width: 16, height: 16, videoCodec: kCMVideoCodecType_HEVC, fileType: .mov,
      queueCapacity: queueCapacity, realTimeEncoding: realTimeEncoding,
      maxKeyFrameInterval: maxKeyFrameInterval)
  }

  func testTwoFeedsRecordSimultaneouslyAndFinalizeAfterPauseResume() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ultracam-recording-e2e-\(UUID().uuidString)")
    let writerA = SyntheticSourceWriter()
    let writerB = SyntheticSourceWriter()
    let duration = RecordingFrameRate.fps2997.frameDuration
    let recorderA = try SourceRecorderCore(configuration: configuration(
      feed: "camera-a", url: root.appendingPathComponent("a.mov")), writerFactory: { writerA })
    let recorderB = try SourceRecorderCore(configuration: configuration(
      feed: "camera-b", url: root.appendingPathComponent("b.mov")), writerFactory: { writerB })

    try recorderA.start()
    try recorderB.start()
    for index in 0..<4 {
      let pts = CMTimeMultiply(duration, multiplier: Int32(index))
      XCTAssertTrue(recorderA.appendVideo(try videoSample(at: pts, duration: duration)))
      XCTAssertTrue(recorderB.appendVideo(try videoSample(at: pts, duration: duration)))
    }
    try recorderA.pause()
    XCTAssertFalse(recorderA.appendVideo(try videoSample(at: CMTime(value: 10_010,
      timescale: 30_000), duration: duration)))
    XCTAssertTrue(recorderB.appendVideo(try videoSample(at: CMTime(value: 4_004,
      timescale: 30_000), duration: duration)))
    try recorderA.resume()
    XCTAssertTrue(recorderA.appendVideo(try videoSample(at: CMTime(value: 10_010,
      timescale: 30_000), duration: duration)))

    try recorderA.stop()
    try recorderB.stop()
    XCTAssertTrue(writerA.finished)
    XCTAssertTrue(writerB.finished)
    XCTAssertEqual(recorderA.state, .finished)
    XCTAssertEqual(recorderB.state, .finished)
    XCTAssertEqual(recorderA.telemetry.appendedVideo, 5)
    XCTAssertEqual(recorderB.telemetry.appendedVideo, 5)
    XCTAssertEqual(recorderA.telemetry.droppedPaused, 1)
    XCTAssertEqual(writerA.videoSamples.count, 5)
    XCTAssertEqual(writerB.videoSamples.count, 5)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(writerA.videoSamples.last!),
      CMTime(value: 10_010, timescale: 30_000))
  }

  func testDropFrameTimecodeAndSourceAlignmentAtBothRates() throws {
    let expected: [(RecordingFrameRate, Int64, String)] = [
      (.fps2997, 1_800, "00:01:00;02"),
      (.fps5994, 3_600, "00:01:00;04"),
    ]
    for (rate, frame, label) in expected {
      let timecode = RecordingTimecode(frameNumber: frame, frameRate: rate, dropFrame: true)
      XCTAssertEqual(timecode.stringValue, label)
      XCTAssertEqual(RecordingTimecode(string: label, frameRate: rate, dropFrame: true), timecode)
      XCTAssertNil(RecordingTimecode(string: label.replacingOccurrences(of: ";02", with: ";00")
        .replacingOccurrences(of: ";04", with: ";00"), frameRate: rate, dropFrame: true))

      let session = RecordingTimecodeSession(frameRate: rate, dropFrame: true,
        policy: .wallClock, startDate: Date(timeIntervalSince1970: 0), sourceStartTime: .zero,
        calendar: Calendar(identifier: .gregorian))
      let mapped = try XCTUnwrap(session.timecode(for: CMTimeMultiply(rate.frameDuration,
        multiplier: Int32(frame))))
      XCTAssertEqual(mapped.frameNumber, session.startTimecode.frameNumber + frame,
        "Source PTS must advance timecode by exact media frames")
    }

    let sourceSession = RecordingTimecodeSession(frameRate: .fps2997, policy: .source,
      startDate: Date(timeIntervalSince1970: 0))
    let sourceTimecode = RecordingTimecode(frameNumber: 123, frameRate: .fps2997, dropFrame: true)
    XCTAssertEqual(sourceSession.timecode(for: .zero, sourceTimecode: sourceTimecode), sourceTimecode)
    XCTAssertNil(sourceSession.timecode(for: .zero, sourceTimecode: nil))
  }

  func testStopDrainsSyntheticBuffersBeforeFinalization() throws {
    let writer = SyntheticSourceWriter()
    // Room for all 20 frames: this checks the drain at stop, so a busy machine
    // that runs the recorder queue late must not fail the take for falling behind.
    let recorder = try SourceRecorderCore(configuration: configuration(
      feed: "finalization", url: URL(fileURLWithPath: "/tmp/finalization.mov"), queueCapacity: 32),
      writerFactory: { writer })
    try recorder.start()
    let duration = RecordingFrameRate.fps5994.frameDuration
    for index in 0..<20 {
      let pts = CMTimeMultiply(duration, multiplier: Int32(index))
      XCTAssertTrue(recorder.appendVideo(try videoSample(at: pts, duration: duration)))
      XCTAssertTrue(recorder.appendAudio(try audioSample(at: CMTime(value: Int64(index) * 800,
        timescale: 48_000))))
    }
    try recorder.stop()
    XCTAssertTrue(writer.finished)
    XCTAssertEqual(recorder.telemetry.appendedVideo, 20)
    XCTAssertEqual(recorder.telemetry.appendedAudio, 20)
    XCTAssertEqual(recorder.telemetry.totalDrops, 0)
  }

  private func encodedVideoSample(at time: CMTime) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      codecType: kCMVideoCodecType_JPEG, width: 16, height: 16, extensions: nil,
      formatDescriptionOut: &format), noErr)
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: 4, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: 0,
      blockBufferOut: &block), noErr)
    var timing = CMSampleTimingInfo(duration: RecordingFrameRate.fps2997.frameDuration,
      presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var size = 4
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
      dataBuffer: try XCTUnwrap(block), formatDescription: try XCTUnwrap(format), sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }

  func testEarlyAudioDrainsBeforeLaterAudioAfterInputBackpressure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-audio-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = try configuration(feed: "audio-order", url: root.appendingPathComponent("take.mov"))
    var audioReady = false
    var audioPTS: [CMTime] = []
    let writer = try AVAssetSourceRecordingWriter(configuration: config,
      inputReady: { $0.mediaType != .audio || audioReady }, appendSample: { sample, input in
        if input.mediaType == .audio { audioPTS.append(CMSampleBufferGetPresentationTimeStamp(sample)) }
        return true
      })
    try writer.start()
    // Embedded audio is 48 kHz. These stamps are 0.1s, 0s, then 0.2s.
    let early = CMTime(value: 4_800, timescale: 48_000)
    let first = CMTime(value: 0, timescale: 48_000)
    let later = CMTime(value: 9_600, timescale: 48_000)
    try writer.appendAudio(audioSample(at: early))
    try writer.appendAudio(audioSample(at: first))
    writer.appendEncodedVideo(try encodedVideoSample(at: .zero))
    writer.flushWriterQueue()
    XCTAssertEqual(writer.telemetry.encodedVideo, 1)
    XCTAssertTrue(audioPTS.isEmpty)
    audioReady = true
    try writer.appendAudio(audioSample(at: later))
    writer.flushWriterQueue()
    XCTAssertEqual(audioPTS, [first, early, later])
    XCTAssertThrowsError(try writer.appendAudio(audioSample(at: first))) { error in
      guard case .writerNotReady = error as? SourceRecordingError else {
        return XCTFail("Late audio must be a recoverable rejection")
      }
    }
    XCTAssertFalse(writer.telemetry.failed)
    XCTAssertEqual(writer.telemetry.encodedVideo, 1, "Audio ordering must keep the appended picture")
    XCTAssertEqual(writer.telemetry.droppedEncodedVideo, 0)
  }

  /// Timecode backpressure used to drop the tmcd sample. It now waits for
  /// its input on the writer queue, and the picture is never held back.
  func testTimecodeBackpressureWaitsInsteadOfDropping() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-timecode-drop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("timecode-drop"),
      outputURL: root.appendingPathComponent("take.mov"), width: 16, height: 16, timecodePolicy: .recordStart)
    let lock = NSLock()
    var pictures = 0
    var timecodes = 0
    var timecodeReady = false
    let writer = try AVAssetSourceRecordingWriter(configuration: config,
      inputReady: { input in lock.withLock { input.mediaType != .timecode || timecodeReady } },
      appendSample: { _, input in
        lock.withLock {
          if input.mediaType == .video { pictures += 1 }
          if input.mediaType == .timecode { timecodes += 1 }
        }
        return true
      })
    try writer.start()
    writer.appendEncodedVideo(try encodedVideoSample(at: .zero))
    writer.flushWriterQueue()
    XCTAssertEqual(lock.withLock { pictures }, 1)
    XCTAssertEqual(lock.withLock { timecodes }, 0)
    XCTAssertEqual(writer.telemetry.encodedVideo, 1)
    XCTAssertEqual(writer.telemetry.droppedEncodedVideo, 0)
    XCTAssertEqual(writer.telemetry.encoderErrors, 0)
    XCTAssertEqual(writer.telemetry.droppedTimecode, 0)
    XCTAssertFalse(writer.telemetry.failed)
    lock.withLock { timecodeReady = true }
    writer.flushWriterQueue()
    XCTAssertEqual(lock.withLock { timecodes }, 1, "The waiting timecode sample is written once its input is ready")
    XCTAssertEqual(writer.telemetry.droppedTimecode, 0)
  }

  // MARK: - Recording pipeline: zero copy, no blocking, no silent drops

  private func v210Frame(width: Int, height: Int, seed: UInt32 = 7) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    let words = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt32.self)
    var state = seed
    for index in 0..<(CVPixelBufferGetDataSize(image) / 4) {
      state = state &* 1_664_525 &+ 1_013_904_223
      words[index] = state & 0x3fff_ffff
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return image
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
  }

  private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool {
      get { lock.withLock { value } }
      set { lock.withLock { value = newValue } }
    }
  }

  /// The hardware encoders do not take v210; the writer repacks it on the
  /// GPU. The repack must equal VideoToolbox's own conversion bit for bit.
  func testGPURepackMatchesVideoToolboxConversionBitForBit() throws {
    let converter = try RecordingPixelConverter.shared()
    var transfer: VTPixelTransferSession?
    XCTAssertEqual(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer), noErr)
    for (width, height) in [(3_840, 2_160), (96, 64), (100, 10)] {
      let source = try v210Frame(width: width, height: height, seed: UInt32(width))
      func x422() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
      }
      let reference = try x422()
      let converted = try x422()
      XCTAssertEqual(VTPixelTransferSessionTransferImage(try XCTUnwrap(transfer), from: source, to: reference), noErr)
      try converter.convert(source, into: converted)
      CVPixelBufferLockBaseAddress(reference, .readOnly)
      CVPixelBufferLockBaseAddress(converted, .readOnly)
      defer {
        CVPixelBufferUnlockBaseAddress(reference, .readOnly)
        CVPixelBufferUnlockBaseAddress(converted, .readOnly)
      }
      var mismatchedRows = 0
      for plane in 0..<2 {
        let rowBytes = (plane == 0 ? width : (width + 1) / 2 * 2) * 2
        for row in 0..<height {
          let expected = CVPixelBufferGetBaseAddressOfPlane(reference, plane)!
            + row * CVPixelBufferGetBytesPerRowOfPlane(reference, plane)
          let actual = CVPixelBufferGetBaseAddressOfPlane(converted, plane)!
            + row * CVPixelBufferGetBytesPerRowOfPlane(converted, plane)
          if memcmp(expected, actual, rowBytes) != 0 { mismatchedRows += 1 }
        }
      }
      XCTAssertEqual(mismatchedRows, 0, "\(width) × \(height) repack differs from VideoToolbox")
    }
  }

  /// VideoToolbox must receive an IOSurface in the encoder's native layout
  /// carrying the source's color tags, with the expected cadence declared.
  func testEncoderReceivesNativeIOSurfaceWithSourceTags() throws {
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("native-input"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-native-\(UUID().uuidString).mov"),
      width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
    let lock = NSLock()
    var received: [CVImageBuffer] = []
    var expectedRate: Double?
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { session, image, _, _ in
      var value: Unmanaged<CFTypeRef>?
      _ = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
        allocator: nil, valueOut: &value)
      lock.withLock {
        received.append(image)
        expectedRate = (value?.takeRetainedValue() as? NSNumber)?.doubleValue
      }
      return noErr
    })
    try writer.start()
    let source = try v210Frame(width: 1_920, height: 1_080)
    try writer.appendVideo(try VideoContract.sample(source, at: .zero, duration: VideoContract.fastDuration))
    let image = try XCTUnwrap(lock.withLock { received.first })
    XCTAssertFalse(image === source, "The encoder gets its own pool buffer, filled on the GPU")
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    XCTAssertNotNil(CVPixelBufferGetIOSurface(image))
    XCTAssertEqual(CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    XCTAssertEqual(CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil) as? String,
      kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    XCTAssertEqual(try XCTUnwrap(lock.withLock { expectedRate }), 60_000.0 / 1_001.0, accuracy: 0.01)
    let telemetry = writer.telemetry
    XCTAssertEqual(telemetry.gpuConvertedFrames, 1)
    XCTAssertEqual(telemetry.cpuConvertedFrames, 0)
    XCTAssertEqual(telemetry.nativeEncoderInput, true)
    XCTAssertEqual(telemetry.hardwareEncoder, true)
  }

  /// A stalled disk must never reach the capture thread: every callback
  /// returns at once, the encoder keeps going, and when the disk recovers
  /// every frame is in the file.
  func testCaptureCallbacksNeverWaitWhileTheWriterIsStalled() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-stall-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("stall.mov")
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("stall"), outputURL: url,
      width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
    let stalled = Switch(true)
    let writer = try AVAssetSourceRecordingWriter(configuration: config, inputReady: { input in
      if input.mediaType == .video, stalled.isOn { return false }
      return input.isReadyForMoreMediaData
    })
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: recorder)
    try adapter.start()
    let callbacks = adapter.callbacks
    let image = try v210Frame(width: 1_920, height: 1_080)
    let duration = VideoContract.fastDuration
    let frames = 90
    var slowest = 0.0
    for frame in 0..<frames {
      let started = ProcessInfo.processInfo.systemUptime
      XCTAssertTrue(callbacks.video(image, CMTimeMultiply(duration, multiplier: Int32(frame)), duration, true))
      XCTAssertTrue(callbacks.rawAudio(Data(count: 800 * 2 * 4), 800,
        CMTime(value: Int64(frame) * 800, timescale: 48_000), 2, 4))
      _ = adapter.telemetry // diagnostics stay readable during the stall
      slowest = max(slowest, ProcessInfo.processInfo.systemUptime - started)
      Thread.sleep(forTimeInterval: duration.seconds)
    }
    XCTAssertTrue(waitUntil(10) { writer.telemetry.bufferedSamples >= frames },
      "Encoded frames wait in memory for the disk: \(writer.telemetry)")
    XCTAssertEqual(writer.telemetry.encodedVideo, 0, "The disk was stalled for the whole run")
    XCTAssertLessThan(slowest, 0.05, "A capture callback waited \(slowest * 1000) ms behind the stalled writer")
    stalled.isOn = false
    try adapter.stop()
    let telemetry = adapter.telemetry
    XCTAssertEqual(adapter.state, .finished, telemetry.lastError ?? "")
    XCTAssertEqual(telemetry.encodedVideo, UInt64(frames))
    XCTAssertEqual(telemetry.appendedAudio, UInt64(frames))
    XCTAssertEqual(telemetry.totalDrops, 0)
    XCTAssertEqual(telemetry.droppedEncodedVideo, 0)
    XCTAssertEqual(telemetry.droppedAudio, 0)
    XCTAssertEqual(telemetry.gpuConvertedFrames, UInt64(frames))
    XCTAssertGreaterThan(telemetry.writerMaxBufferedBytes, 0)
    let asset = AVURLAsset(url: url)
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var frames = 0.0 }
    let box = Box()
    Task {
      if let track = try? await asset.loadTracks(withMediaType: .video).first,
        let range = try? await track.load(.timeRange) {
        box.frames = range.duration.seconds / duration.seconds
      }
      done.signal()
    }
    done.wait()
    XCTAssertEqual(box.frames, Double(frames), accuracy: 0.5, "Every frame must be in the file")
  }

  /// The 2026-10-24 takes began their audio 0.876 s and 0.440 s after the
  /// picture (an empty `elst` edit) and ran it that far past the last frame:
  /// each DeckLink callback's audio packet time was ahead of its frame's
  /// stream time by a device-dependent amount, and the movie was written on
  /// the raw packet clock. The movie must start both tracks together and end
  /// the audio with the video, whatever the two device clocks' origins are.
  /// Editors read a take's rate from its video track. A 1/600 s timebase can't
  /// hold a 1001/60000 s frame, so 59.94 takes were stamped at exactly 1/60 s
  /// and read as 60 fps or variable rate. Each rate gets its own timescale.
  func testTakesAreStampedAtTheirBroadcastRate() throws {
    for duration in [VideoContract.fastDuration, VideoContract.slowDuration] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-rate-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("rate.mov")
      let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("rate"), outputURL: url,
        width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
      let adapter = try SourceRecordingCallbackAdapter(configuration: config)
      try adapter.start()
      let image = try v210Frame(width: 1_920, height: 1_080)
      let frames = 30
      for frame in 0..<frames {
        let pts = CMTime(value: Int64(frame) * duration.value, timescale: duration.timescale)
        XCTAssertTrue(adapter.callbacks.video(image, pts, duration, true))
        Thread.sleep(forTimeInterval: duration.seconds)
      }
      try adapter.stop()
      XCTAssertEqual(adapter.state, .finished, adapter.telemetry.lastError ?? "")

      final class Track: @unchecked Sendable {
        var timescale: CMTimeScale = 0, minFrame: CMTime = .invalid, rate: Float = 0
      }
      let track = Track()
      let asset = AVURLAsset(url: url)
      let done = DispatchSemaphore(value: 0)
      Task {
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
          track.timescale = (try? await video.load(.naturalTimeScale)) ?? 0
          track.minFrame = (try? await video.load(.minFrameDuration)) ?? .invalid
          track.rate = (try? await video.load(.nominalFrameRate)) ?? 0
        }
        done.signal()
      }
      done.wait()
      XCTAssertEqual(track.timescale, duration.timescale, "the video track is timed in \(duration.timescale)ths")
      XCTAssertEqual(track.minFrame, duration, "every frame lasts exactly \(duration.value)/\(duration.timescale) s")
      XCTAssertEqual(Double(track.rate), Double(duration.timescale) / Double(duration.value), accuracy: 0.001)
    }
  }

  func testMovieKeepsDeckLinkAudioInSyncWhenItsClockOriginDiffers() throws {
    for clockOffset: Int64 in [42_050, 0] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-avsync-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("avsync.mov")
      let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("avsync"), outputURL: url,
        width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
      let adapter = try SourceRecordingCallbackAdapter(configuration: config)
      try adapter.start()
      let callbacks = adapter.callbacks
      let image = try v210Frame(width: 1_920, height: 1_080)
      let duration = VideoContract.fastDuration
      let frames = 60
      // Stream time 2.1 s in, as after the first frame of a real open.
      let videoOrigin = Int64(126) * duration.value
      let audioOrigin = CMTimeConvertScale(CMTime(value: videoOrigin, timescale: duration.timescale),
        timescale: 48_000, method: .roundHalfAwayFromZero).value + clockOffset
      var audioSamples: Int64 = 0
      for frame in 0..<frames {
        let pts = CMTime(value: videoOrigin + Int64(frame) * duration.value, timescale: duration.timescale)
        XCTAssertTrue(callbacks.video(image, pts, duration, true))
        // 800.8 samples per frame: packets of 800 and 801, contiguous.
        let end = (Int64(frame + 1) * 48_000 * duration.value + Int64(duration.timescale) / 2) /
          Int64(duration.timescale)
        let count = Int(end - audioSamples)
        XCTAssertTrue(callbacks.rawAudio(Data(count: count * 2 * 4), count,
          CMTime(value: audioOrigin + audioSamples, timescale: 48_000), 2, 4))
        audioSamples = end
        Thread.sleep(forTimeInterval: duration.seconds)
      }
      try adapter.stop()
      let telemetry = adapter.telemetry
      XCTAssertEqual(adapter.state, .finished, telemetry.lastError ?? "")
      XCTAssertEqual(telemetry.totalDrops, 0)
      XCTAssertEqual(telemetry.droppedAudio, 0)
      XCTAssertEqual(telemetry.appendedAudio, UInt64(frames))

      final class Ranges: @unchecked Sendable {
        var video: CMTimeRange?, audio: CMTimeRange?, movie: CMTime?
      }
      let ranges = Ranges()
      let asset = AVURLAsset(url: url)
      let done = DispatchSemaphore(value: 0)
      Task {
        ranges.video = try? await asset.loadTracks(withMediaType: .video).first?.load(.timeRange)
        ranges.audio = try? await asset.loadTracks(withMediaType: .audio).first?.load(.timeRange)
        ranges.movie = try? await asset.load(.duration)
        done.signal()
      }
      done.wait()
      let video = try XCTUnwrap(ranges.video)
      let audio = try XCTUnwrap(ranges.audio)
      let movie = try XCTUnwrap(ranges.movie)
      let onePacket = 801.0 / 48_000
      // A track's time range includes a leading empty edit, so a late start
      // shows as a longer audio track that ends after the video.
      XCTAssertEqual(audio.duration.seconds, Double(audioSamples) / 48_000, accuracy: 1.0 / 48_000,
        "Every audio sample is in the movie")
      XCTAssertEqual(audio.end.seconds, video.end.seconds, accuracy: onePacket,
        "offset \(clockOffset): audio ends \(audio.end.seconds - video.end.seconds) s after the video")
      XCTAssertEqual(movie.seconds, video.end.seconds, accuracy: onePacket,
        "offset \(clockOffset): the movie runs on past its last frame")
    }
  }

  /// Mid-take clock jumps, in a real movie. `audioOnly`: ten callbacks bring
  /// audio while the video clock stands still, so the audio re-anchors
  /// earlier and the overlap is left out. `skipped`: ten callbacks never
  /// arrive, so a hole is filled with silence (AVAssetWriter would otherwise
  /// close it up and pull every later sample early). Either way the audio
  /// must end with the video, and the movie must not outlast its frames.
  func testMovieStaysInSyncAcrossAMidTakeClockJump() throws {
    for scenario in ["audioOnly", "skipped"] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-avjump-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let url = root.appendingPathComponent("avjump.mov")
      let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("avjump"), outputURL: url,
        width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
      let adapter = try SourceRecordingCallbackAdapter(configuration: config)
      try adapter.start()
      let callbacks = adapter.callbacks
      let image = try v210Frame(width: 1_920, height: 1_080)
      let duration = VideoContract.fastDuration
      let videoOrigin = Int64(126) * duration.value
      var audioClock: Int64 = 300_000 + 42_050
      var videoFrame: Int64 = 0
      var sent: Int64 = 0
      var gap: Int64 = 0
      func packet(_ index: Int64) -> Int { Int(((index + 1) * 8_008 + 5) / 10 - (index * 8_008 + 5) / 10) }
      for index: Int64 in 0..<70 {
        let count = packet(index)
        let inGap = (30..<40).contains(index)
        if inGap, scenario == "skipped" {
          videoFrame += 1
          audioClock += Int64(count)
          gap += Int64(count)
          continue
        }
        if !inGap {
          XCTAssertTrue(callbacks.video(image, CMTime(value: videoOrigin + videoFrame * duration.value,
            timescale: duration.timescale), duration, true))
          videoFrame += 1
        } else {
          gap += Int64(count)
        }
        XCTAssertTrue(callbacks.rawAudio(Data(count: count * 2 * 4), count,
          CMTime(value: audioClock, timescale: 48_000), 2, 4))
        audioClock += Int64(count)
        sent += Int64(count)
        Thread.sleep(forTimeInterval: duration.seconds)
      }
      try adapter.stop()
      let telemetry = adapter.telemetry
      XCTAssertEqual(adapter.state, .finished, telemetry.lastError ?? "")
      XCTAssertEqual(telemetry.droppedAudio, 0)
      if scenario == "audioOnly" {
        XCTAssertEqual(telemetry.audioBackwardResyncs, 1)
        XCTAssertEqual(telemetry.audioResyncTrimmedFrames, UInt64(gap))
      } else {
        XCTAssertEqual(telemetry.audioSilenceFilledFrames, UInt64(gap))
      }
      let expectedAudio = scenario == "audioOnly" ? sent - gap : sent + gap

      final class Ranges: @unchecked Sendable {
        var video: CMTimeRange?, audio: CMTimeRange?, movie: CMTime?
      }
      let ranges = Ranges()
      let asset = AVURLAsset(url: url)
      let done = DispatchSemaphore(value: 0)
      Task {
        ranges.video = try? await asset.loadTracks(withMediaType: .video).first?.load(.timeRange)
        ranges.audio = try? await asset.loadTracks(withMediaType: .audio).first?.load(.timeRange)
        ranges.movie = try? await asset.load(.duration)
        done.signal()
      }
      done.wait()
      let video = try XCTUnwrap(ranges.video)
      let audio = try XCTUnwrap(ranges.audio)
      let movie = try XCTUnwrap(ranges.movie)
      let onePacket = 801.0 / 48_000
      XCTAssertEqual(audio.duration.seconds, Double(expectedAudio) / 48_000, accuracy: 1.0 / 48_000,
        "\(scenario): only the overlap is left out, only the hole is added")
      XCTAssertEqual(audio.end.seconds, video.end.seconds, accuracy: onePacket,
        "\(scenario): audio ends \(audio.end.seconds - video.end.seconds) s after the video")
      XCTAssertEqual(movie.seconds, video.end.seconds, accuracy: onePacket,
        "\(scenario): the movie runs on past its last frame")
    }
  }

  /// When the disk stays stalled past the memory bound the take fails
  /// visibly; it is never a silent drop. What was queued is still written.
  func testWriterOverflowFailsTheTakeVisiblyAndKeepsTheFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-overflow-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("overflow.mov")
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("overflow"), outputURL: url,
      width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ,
      maximumBufferedWriterBytes: 8_000_000)
    let stalled = Switch(false)
    let writer = try AVAssetSourceRecordingWriter(configuration: config, inputReady: { input in
      if input.mediaType == .video, stalled.isOn { return false }
      return input.isReadyForMoreMediaData
    })
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    let image = try v210Frame(width: 1_920, height: 1_080)
    let duration = VideoContract.fastDuration
    var frame = 0
    func offer() -> Bool {
      defer { frame += 1 }
      guard let sample = try? VideoContract.sample(image, at: CMTimeMultiply(duration, multiplier: Int32(frame)),
        duration: duration) else { return false }
      return recorder.appendVideo(sample)
    }
    for _ in 0..<10 { XCTAssertTrue(offer()) }
    // The hardware encoder may hold its newest frame until the next arrives.
    XCTAssertTrue(waitUntil(10) { writer.telemetry.encodedVideo >= 8 }, "\(writer.telemetry)")
    stalled.isOn = true
    var rejected = false
    for _ in 0..<300 where !rejected {
      rejected = !offer()
      Thread.sleep(forTimeInterval: 0.005)
    }
    XCTAssertTrue(rejected || waitUntil(5) { recorder.state == .failed }, "Overflow must fail the take")
    XCTAssertTrue(waitUntil(5) { recorder.state == .failed })
    let failure = recorder.telemetry
    XCTAssertTrue(failure.lastError?.contains("fell behind") == true, failure.lastError ?? "no error")
    XCTAssertGreaterThan(failure.droppedEncodedVideo, 0, "The frame that did not fit is counted")
    stalled.isOn = false
    XCTAssertThrowsError(try recorder.stop()) { error in
      XCTAssertTrue(error.localizedDescription.contains("fell behind"), error.localizedDescription)
    }
    XCTAssertEqual(recorder.state, .failed)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    XCTAssertGreaterThan(size, 0, "The failed take's media is kept for recovery")
  }

  /// The encoder stage's own bound also fails the take instead of dropping,
  /// and a writer blocked in the encoder never blocks the capture thread.
  func testEncoderStageOverflowFailsTheTakeWithoutBlockingCapture() throws {
    final class BlockingWriter: SourceRecordingWriter, @unchecked Sendable {
      let release = DispatchSemaphore(value: 0)
      let entered = DispatchSemaphore(value: 0)
      private let lock = NSLock()
      private var blocked = false
      private(set) var finished = false
      func start() throws {}
      func appendVideo(_ sample: CMSampleBuffer) throws {
        let first = lock.withLock { () -> Bool in defer { blocked = true }; return !blocked }
        if first { entered.signal(); release.wait() }
      }
      func appendAudio(_ sample: CMSampleBuffer) throws {}
      func finish() throws { lock.withLock { finished = true } }
    }
    let writer = BlockingWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("encoder-overflow"),
      outputURL: URL(fileURLWithPath: "/tmp/encoder-overflow.mov"), width: 16, height: 16, queueCapacity: 4)
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    let duration = VideoContract.fastDuration
    XCTAssertTrue(recorder.appendVideo(try videoSample(at: .zero, duration: duration)))
    XCTAssertEqual(writer.entered.wait(timeout: .now() + 5), .success)
    var slowest = 0.0
    var results: [Bool] = []
    for frame in 1...5 {
      let sample = try videoSample(at: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration)
      let started = ProcessInfo.processInfo.systemUptime
      results.append(recorder.appendVideo(sample))
      slowest = max(slowest, ProcessInfo.processInfo.systemUptime - started)
    }
    // The frame inside the blocked encoder stage counts toward the bound of
    // 4, so the fourth offer overflows; after that the take is failed.
    XCTAssertEqual(results, [true, true, true, false, false])
    XCTAssertLessThan(slowest, 0.05)
    let telemetry = recorder.telemetry
    XCTAssertEqual(telemetry.state, .failed)
    XCTAssertEqual(telemetry.droppedQueueFull, 1)
    XCTAssertTrue(telemetry.lastError?.contains("fell behind") == true, telemetry.lastError ?? "")
    writer.release.signal()
    XCTAssertNoThrow(try recorder.stop())
    XCTAssertEqual(recorder.state, .failed, "A failed take stays failed so it is preserved for recovery")
    XCTAssertTrue(writer.finished)
    let final = recorder.telemetry
    XCTAssertEqual(final.appendedVideo, 4, "Frames admitted before the failure are still written")
    XCTAssertEqual(final.droppedVideo, 2, "The overflowing frame and the one offered after the failure")
  }

  private final class CountingSpaceCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var headrooms: [UInt64] = []
    var failing = false
    /// Checks after this many pass fail (the first is the start check).
    var failAfter: Int?
    var calls: Int { lock.withLock { count } }
    var lastHeadroom: UInt64? { lock.withLock { headrooms.last } }
    var recordedHeadrooms: [UInt64] { lock.withLock { headrooms } }
    func check(_ headroom: UInt64) throws {
      let shouldFail = lock.withLock { () -> Bool in
        count += 1
        headrooms.append(headroom)
        return failing || failAfter.map { count > $0 } == true
      }
      if shouldFail { throw RecordingOutputError.insufficientDiskSpace(required: 100, available: 1) }
    }
  }

  /// Free space used to be checked before every sample (about 120 a second)
  /// on the media queue. It now runs on a timer, off the media path.
  func testFreeSpaceIsCheckedOnATimerNotPerSample() throws {
    let space = CountingSpaceCheck()
    let writer = SyntheticSourceWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("space-rate"),
      outputURL: URL(fileURLWithPath: "/tmp/space-rate.mov"), width: 16, height: 16,
      queueCapacity: 256, spaceCheckInterval: 0.2, checkAvailableSpace: { try space.check($0) })
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    let duration = VideoContract.fastDuration
    for index in 0..<120 {
      XCTAssertTrue(recorder.appendVideo(try videoSample(at: CMTimeMultiply(duration, multiplier: Int32(index)),
        duration: duration)))
      XCTAssertTrue(recorder.appendAudio(try audioSample(at: CMTime(value: Int64(index) * 800, timescale: 48_000))))
    }
    XCTAssertTrue(waitUntil(5) { recorder.telemetry.appendedVideo == 120 })
    // One check at start, then at most one timer tick.
    XCTAssertLessThanOrEqual(space.calls, 2, "240 samples must not trigger 240 space checks")
    Thread.sleep(forTimeInterval: 0.7)
    let afterTicks = space.calls
    XCTAssertGreaterThanOrEqual(afterTicks, 3, "The timer keeps checking while recording")
    XCTAssertLessThanOrEqual(afterTicks, 7)
    XCTAssertEqual(recorder.telemetry.spaceChecks, UInt64(afterTicks - 1), "Timer ticks, after the start check")
    try recorder.pause()
    let paused = space.calls
    Thread.sleep(forTimeInterval: 0.7)
    XCTAssertLessThanOrEqual(space.calls, paused + 1, "A paused take skips the check")
    try recorder.resume()
    try recorder.stop()
    let stopped = space.calls
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(space.calls, stopped, "Stop cancels the timer")
    XCTAssertEqual(recorder.state, .finished)
  }

  func testFailedSpaceCheckFailsTheTake() throws {
    let space = CountingSpaceCheck()
    space.failAfter = 1
    let writer = SyntheticSourceWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("space-fail"),
      outputURL: URL(fileURLWithPath: "/tmp/space-fail.mov"), width: 16, height: 16,
      spaceCheckInterval: 0.05, checkAvailableSpace: { try space.check($0) })
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    XCTAssertTrue(waitUntil(5) { recorder.state == .failed })
    XCTAssertTrue(recorder.telemetry.lastError?.contains("free space") == true, recorder.telemetry.lastError ?? "")
    XCTAssertTrue(recorder.telemetry.lastError?.contains("almost full") == true, recorder.telemetry.lastError ?? "")
    // A drive already too full for the first seconds refuses the take before
    // anything is written.
    let full = CountingSpaceCheck()
    full.failing = true
    let refused = try SourceRecorderCore(configuration: SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID("space-refused"), outputURL: URL(fileURLWithPath: "/tmp/space-refused.mov"),
      width: 16, height: 16, checkAvailableSpace: { try full.check($0) }), writerFactory: { SyntheticSourceWriter() })
    XCTAssertThrowsError(try refused.start()) { error in
      XCTAssertTrue(error.localizedDescription.contains("almost full"), error.localizedDescription)
      XCTAssertTrue(error.localizedDescription.contains("Free up space"), error.localizedDescription)
    }
    XCTAssertEqual(refused.state, .failed)
    XCTAssertFalse(recorder.appendVideo(try videoSample(at: .zero, duration: VideoContract.fastDuration)))
    try? recorder.stop()
    XCTAssertEqual(recorder.state, .failed)
  }

  func testAdapterReusesOneFormatDescriptionForTheTake() throws {
    let writer = SyntheticSourceWriter()
    let config = try configuration(feed: "format-cache", url: URL(fileURLWithPath: "/tmp/format-cache.mov"))
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: recorder)
    try adapter.start()
    let first = try v210Frame(width: 16, height: 16)
    let second = try v210Frame(width: 16, height: 16, seed: 99)
    let duration = VideoContract.fastDuration
    XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: first, presentationTime: .zero, duration: duration))
    XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: second, presentationTime: duration, duration: duration))
    CVBufferSetAttachment(second, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: second, presentationTime: CMTimeMultiply(duration, multiplier: 2),
      duration: duration))
    try adapter.stop()
    let formats = writer.videoSamples.map { CMSampleBufferGetFormatDescription($0)! }
    XCTAssertEqual(formats.count, 3)
    XCTAssertTrue(formats[0] === formats[1], "An unchanged capture format reuses its description")
    XCTAssertFalse(formats[1] === formats[2], "Changed color tags get a new description")
    XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(formats[2], imageBuffer: second))
  }

  func testSourceTimecodeAcceptsFrames0Through59At5994() throws {
    for frames in [0, 29, 30, 59] {
      let label = String(format: "01:02:03;%02d", frames)
      let timecode = try XCTUnwrap(RecordingTimecode(string: label, frameRate: .fps5994, dropFrame: true), label)
      XCTAssertEqual(timecode.frames, frames)
      XCTAssertEqual(timecode.stringValue, label)
      XCTAssertEqual(RecordingTimecode(frameNumber: timecode.frameNumber, frameRate: .fps5994,
        dropFrame: true), timecode)
    }
    XCTAssertNil(RecordingTimecode(string: "01:02:03;60", frameRate: .fps5994, dropFrame: true))
    XCTAssertNil(RecordingTimecode(string: "01:02:03;30", frameRate: .fps2997, dropFrame: true))
    // RP188 arrives as HH:MM:SS;FF when the source flags drop-frame and
    // HH:MM:SS:FF otherwise; the separator alone decides.
    let dropFrame = try XCTUnwrap(RecordingTimecode(string: "10:20:30;59", frameRate: .fps5994))
    XCTAssertTrue(dropFrame.dropFrame)
    XCTAssertEqual(dropFrame.frames, 59)
    let nonDrop = try XCTUnwrap(RecordingTimecode(string: "10:20:30:59", frameRate: .fps5994))
    XCTAssertFalse(nonDrop.dropFrame)
    XCTAssertEqual(nonDrop.stringValue, "10:20:30:59")
    XCTAssertNil(RecordingTimecode(string: "10:20:30.59", frameRate: .fps5994))
    XCTAssertNil(RecordingTimecode(string: "10:20:30:60", frameRate: .fps5994))
    XCTAssertEqual(RecordingTimecode.dropFrame(declaredBy: "00:00:00;00"), true)
    XCTAssertEqual(RecordingTimecode.dropFrame(declaredBy: "00:00:00:00"), false)
    XCTAssertNil(RecordingTimecode.dropFrame(declaredBy: "bad"))
  }

  func testRecordingDropFrameFollowsTheSourceTimecodeFlag() throws {
    func configuration(rate: RecordingFrameRate, source: String?, explicit: Bool? = nil) throws -> SourceRecordingConfiguration {
      try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("df"),
        outputURL: URL(fileURLWithPath: "/tmp/df.mov"), width: 16, height: 16,
        frameRate: rate, timecodePolicy: .recordStart, timecodeDropFrame: explicit, sourceTimecode: source)
    }
    XCTAssertFalse(try configuration(rate: .fps5994, source: "01:00:00:12").timecodeDropFrame,
      "An NDF source keeps NDF at 59.94")
    XCTAssertTrue(try configuration(rate: .fps5994, source: "01:00:00;12").timecodeDropFrame)
    XCTAssertFalse(try configuration(rate: .fps2997, source: "01:00:00:12").timecodeDropFrame)
    XCTAssertTrue(try configuration(rate: .fps2997, source: nil).timecodeDropFrame,
      "Without source timecode, 29.97/59.94 default to drop-frame")
    XCTAssertTrue(try configuration(rate: .fps5994, source: "01:00:00:12", explicit: true).timecodeDropFrame,
      "An explicit choice wins")
    // Wall-clock timecode counts the computer's clock: the camera's NDF flag
    // does not apply, so 29.97/59.94 keep the drop-frame convention.
    for rate in [RecordingFrameRate.fps2997, .fps5994] {
      let wallClock = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("df-wall"),
        outputURL: URL(fileURLWithPath: "/tmp/df-wall.mov"), width: 16, height: 16,
        frameRate: rate, timecodePolicy: .wallClock, sourceTimecode: "01:00:00:12")
      XCTAssertTrue(wallClock.timecodeDropFrame, "Wall-clock \(rate) ignores an NDF source flag")
      XCTAssertTrue(try XCTUnwrap(AVAssetSourceRecordingWriter.makeTimecodeTrack(for: wallClock)).dropFrame)
    }
    let track = try XCTUnwrap(AVAssetSourceRecordingWriter.makeTimecodeTrack(
      for: configuration(rate: .fps5994, source: "01:00:00:12")))
    XCTAssertFalse(track.dropFrame, "The written tmcd track carries the source's NDF flag")
  }

  // MARK: - Review fixes: free space, pause, tags, anchors, telemetry

  /// A writer whose telemetry the test sets directly.
  private final class TelemetryWriter: SourceRecordingWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var value = SourceRecordingWriterTelemetry()
    var telemetry: SourceRecordingWriterTelemetry { lock.withLock { value } }
    func update(_ change: (inout SourceRecordingWriterTelemetry) -> Void) { lock.withLock { change(&value) } }
    func start() throws {}
    func appendVideo(_ sample: CMSampleBuffer) throws {}
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws {}
  }

  /// The guard must cover what is in memory (up to 1 GiB) and two intervals
  /// of writing at the take's real rate, not just the 128 MiB floor.
  func testSpaceHeadroomCoversBufferedMediaAndTwoIntervals() throws {
    let writer = TelemetryWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("headroom"),
      outputURL: URL(fileURLWithPath: "/tmp/headroom.mov"), width: 3_840, height: 2_160,
      videoCodec: kCMVideoCodecType_AppleProRes422HQ, spaceCheckInterval: 1)
    let nominal = config.nominalBytesPerSecond
    XCTAssertEqual(nominal, 221_000_000, accuracy: 2_000_000, "ProRes 422 HQ 2160p59.94")
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    writer.update { $0.bufferedBytes = 500_000_000; $0.encoderPendingFrames = 3; $0.acceptedBytes = 0 }
    let frame = config.frameRate.frameDuration.seconds
    let first = Double(recorder.spaceHeadroom(now: 100))
    XCTAssertEqual(first, 500_000_000 + 3 * nominal * frame + 2 * nominal, accuracy: 1_000)
    // The take measures 400 MB/s, above the nominal rate: that rate counts.
    writer.update { $0.acceptedBytes = 400_000_000 }
    let measured = Double(recorder.spaceHeadroom(now: 101))
    XCTAssertEqual(measured, 500_000_000 + 3 * 400_000_000 * frame + 2 * 400_000_000, accuracy: 1_000)
    // A slower take never counts below the nominal rate.
    writer.update { $0.acceptedBytes = 410_000_000 }
    XCTAssertEqual(Double(recorder.spaceHeadroom(now: 102)), first, accuracy: 1_000)
  }

  /// A nearly full drive: the take fails with a clear message while there is
  /// still room, and every frame already accepted is written, not discarded.
  func testFullDriveFailsEarlyAndWritesEverythingAlreadyAccepted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-full-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("full.mov")
    final class Disk: @unchecked Sendable {
      weak var writer: AVAssetSourceRecordingWriter?
      let capacity: UInt64 = 40_000_000
      func check(_ headroom: UInt64) throws {
        let used = writer?.telemetry.encodedVideoBytes ?? 0
        let available = capacity > used ? capacity - used : 0
        if available < headroom {
          throw RecordingOutputError.insufficientDiskSpace(required: headroom, available: available)
        }
      }
    }
    let disk = Disk()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("full"), outputURL: url,
      width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ,
      spaceCheckInterval: 0.05, checkAvailableSpace: { try disk.check($0) })
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    disk.writer = writer
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    let image = try v210Frame(width: 1_920, height: 1_080)
    let duration = VideoContract.fastDuration
    var rejected = false
    for frame in 0..<300 where !rejected {
      let sample = try VideoContract.sample(image, at: CMTimeMultiply(duration, multiplier: Int32(frame)),
        duration: duration)
      rejected = !recorder.appendVideo(sample)
      Thread.sleep(forTimeInterval: duration.seconds)
    }
    XCTAssertTrue(rejected, "The guard must stop the take before the drive fills")
    XCTAssertEqual(recorder.state, .failed)
    let failure = recorder.telemetry.lastError ?? ""
    XCTAssertTrue(failure.contains("almost full") && failure.contains("free space"), failure)
    try? recorder.stop()
    let telemetry = recorder.telemetry
    XCTAssertGreaterThan(telemetry.appendedVideo, 5)
    XCTAssertEqual(telemetry.encodedVideo, telemetry.appendedVideo, "Every admitted frame reached the file")
    XCTAssertEqual(telemetry.droppedEncodedVideo, 0)
    XCTAssertLessThanOrEqual(telemetry.encodedVideoBytes, disk.capacity, "The take never needed more than the drive had")
    XCTAssertEqual(try videoFrameCount(url, frameDuration: duration), Double(telemetry.encodedVideo), accuracy: 0.5)
  }

  private func trackDuration(_ url: URL, _ type: AVMediaType) throws -> Double {
    let asset = AVURLAsset(url: url)
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var seconds = -1.0 }
    let box = Box()
    Task {
      if let track = try? await asset.loadTracks(withMediaType: type).first,
        let range = try? await track.load(.timeRange) { box.seconds = range.duration.seconds }
      done.signal()
    }
    done.wait()
    return box.seconds
  }

  private func videoFrameCount(_ url: URL, frameDuration: CMTime) throws -> Double {
    try trackDuration(url, .video) / frameDuration.seconds
  }

  /// Pause leaves no hole in the movie: the frames after the resume follow
  /// the last frame before it, and audio moves by the same amount.
  func testPausedTakeContinuesWithoutAGap() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-pause-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("pause.mov")
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("pause"), outputURL: url,
      width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ, timecodePolicy: .recordStart)
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    let image = try v210Frame(width: 1_920, height: 1_080)
    let duration = VideoContract.fastDuration
    func offer(_ frames: Range<Int>) throws {
      for frame in frames {
        XCTAssertTrue(recorder.appendAudio(try audioSample(at: CMTime(value: Int64(frame) * 801, timescale: 48_000),
          frameCount: 801)))
        XCTAssertTrue(recorder.appendVideo(try VideoContract.sample(image,
          at: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration)),
          recorder.telemetry.lastError ?? "")
        Thread.sleep(forTimeInterval: duration.seconds)  // Capture cadence.
      }
    }
    try offer(0..<30)
    try recorder.pause()
    XCTAssertFalse(recorder.appendVideo(try VideoContract.sample(image,
      at: CMTimeMultiply(duration, multiplier: 100), duration: duration)))
    try recorder.resume()
    // Five seconds later on the capture clock.
    try offer(330..<360)
    try recorder.stop()
    XCTAssertEqual(recorder.state, .finished, recorder.telemetry.lastError ?? "")
    XCTAssertEqual(recorder.telemetry.encodedVideo, 60)
    XCTAssertEqual(try videoFrameCount(url, frameDuration: duration), 60, accuracy: 0.5,
      "The movie holds the 60 recorded frames back to back, not the 5 s pause")
    let audio = try trackDuration(url, .audio)
    XCTAssertEqual(audio, 60 * 801 / 48_000, accuracy: 0.03, "Audio continues without a silent gap")
    XCTAssertEqual(writer.telemetry.droppedAudio, 0)
  }

  /// The GPU route hands VideoToolbox a pool buffer; it must carry the same
  /// image tags the capture buffer does, including should-not-propagate ones,
  /// but never an attachment that owns the capture frame.
  func testGPURouteCopiesEveryImageTagButNotFrameOwnership() throws {
    var created: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created), kCVReturnSuccess)
    let source = try XCTUnwrap(created)
    CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
      .shouldNotPropagate)
    CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left,
      .shouldNotPropagate)
    CVBufferSetAttachment(source, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldNotPropagate)
    CVBufferSetAttachment(source, "UltracamTestFrameLifetime" as CFString, NSObject(), .shouldNotPropagate)
    var destination: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &destination), kCVReturnSuccess)
    let target = try XCTUnwrap(destination)
    CVBufferSetAttachment(target, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    AVAssetSourceRecordingWriter.copyImageAttachments(from: source, to: target)
    var mode = CVAttachmentMode.shouldPropagate
    XCTAssertEqual(CVBufferCopyAttachment(target, kCVImageBufferTransferFunctionKey, &mode) as? String,
      kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    XCTAssertEqual(mode, .shouldNotPropagate)
    XCTAssertEqual(CVBufferCopyAttachment(target, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
      kCVImageBufferChromaLocation_Left as String)
    XCTAssertEqual(CVBufferCopyAttachment(target, kCVImageBufferFieldCountKey, nil) as? NSNumber, 1)
    XCTAssertEqual(CVBufferCopyAttachment(target, kCVImageBufferColorPrimariesKey, nil) as? String,
      kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    XCTAssertNil(CVBufferCopyAttachment(target, kCVImageBufferYCbCrMatrixKey, nil), "A recycled buffer's stale tag")
    XCTAssertNil(CVBufferCopyAttachment(target, "UltracamTestFrameLifetime" as CFString, nil),
      "The capture frame's owner must not follow the frame into the encoder")

    // And through the real encoder stage.
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("tags"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-tags-\(UUID().uuidString).mov"),
      width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
    let lock = NSLock()
    var received: CVImageBuffer?
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, image, _, _ in
      lock.withLock { received = image }
      return noErr
    })
    try writer.start()
    let frame = try v210Frame(width: 1_920, height: 1_080)
    CVBufferSetAttachment(frame, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left,
      .shouldNotPropagate)
    try writer.appendVideo(try VideoContract.sample(frame, at: .zero, duration: VideoContract.fastDuration))
    let image = try XCTUnwrap(lock.withLock { received })
    XCTAssertFalse(image === frame)
    XCTAssertEqual(CVBufferCopyAttachment(image, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
      kCVImageBufferChromaLocation_Left as String)
  }

  /// Wall-clock timecode starts at the moment the first frame was captured,
  /// not when the file opened after the encoder's first output.
  func testWallClockAnchorUsesTheFirstFramesCaptureTime() throws {
    let image = try v210Frame(width: 16, height: 16)
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(AVAssetSourceRecordingWriter.captureDate(of: image, now: now, hostNow: 50), now,
      "Without a capture time the encoder stage's arrival is used")
    CVBufferSetAttachment(image, SourceRecordingConfiguration.captureHostTimeAttachmentKey as CFString,
      NSNumber(value: 49.75), .shouldPropagate)
    XCTAssertEqual(AVAssetSourceRecordingWriter.captureDate(of: image, now: now, hostNow: 50)
      .timeIntervalSince(now), -0.25, accuracy: 1e-9)
    XCTAssertEqual(AVAssetSourceRecordingWriter.captureDate(of: image, now: now, hostNow: 49), now,
      "A capture time in the future is not this frame's")
    let anchored = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("anchor"),
      outputURL: URL(fileURLWithPath: "/tmp/anchor.mov"), width: 16, height: 16,
      timecodePolicy: .wallClock, timecodeSamplesComputerClockAtFirstFrame: true)
    let captured = now.addingTimeInterval(-0.25)
    XCTAssertEqual(AVAssetSourceRecordingWriter.timecodeAnchorDate(for: anchored, now: now, firstFrame: captured),
      captured)
    XCTAssertEqual(AVAssetSourceRecordingWriter.timecodeAnchorDate(for: anchored, now: now), now)
  }

  /// A step of several frame durations between capture timestamps means the
  /// device skipped frames: they are dropped video, with a warning. A
  /// rejected no-signal frame in between explains its own gap.
  func testSkippedCaptureFramesAreCountedAndExplained() throws {
    let writer = SyntheticSourceWriter()
    let config = try configuration(feed: "skips", url: URL(fileURLWithPath: "/tmp/skips.mov"))
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: recorder)
    try adapter.start()
    let duration = VideoContract.fastDuration
    let image = try v210Frame(width: 16, height: 16)
    for frame in [0, 1, 2, 5, 6] {
      XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: image,
        presentationTime: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration))
    }
    XCTAssertFalse(adapter.appendRawVideo(pixelBuffer: image,
      presentationTime: CMTimeMultiply(duration, multiplier: 7), duration: duration, signalValid: false))
    XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: image,
      presentationTime: CMTimeMultiply(duration, multiplier: 12), duration: duration))
    let telemetry = adapter.telemetry
    XCTAssertEqual(telemetry.deviceSkippedFrames, 2)
    XCTAssertEqual(telemetry.droppedVideo, 3, "Two skipped frames and one no-signal frame")
    XCTAssertTrue(telemetry.warning?.contains("missing 2 frames in 1 gap ") == true, telemetry.warning ?? "")
    XCTAssertEqual(telemetry.sourceGaps, 1)
    XCTAssertEqual(telemetry.largestSourceGap, 2)
    XCTAssertEqual(telemetry.state, .recording, "A device skip is reported, not a recorder failure")
    XCTAssertNil(telemetry.lastError)
    try adapter.stop()
  }

  /// Media admitted and then discarded because the file writer failed is
  /// lost media: it counts as dropped video, not only "not recording".
  func testDiscardsAfterAWriterFailureCountAsDroppedVideo() throws {
    final class FailingWriter: SourceRecordingWriter, @unchecked Sendable {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      private let lock = NSLock()
      private var calls = 0
      func start() throws {}
      func appendVideo(_ sample: CMSampleBuffer) throws {
        let call = lock.withLock { () -> Int in calls += 1; return calls }
        if call == 1 { entered.signal(); release.wait() }
        if call == 2 { throw SourceRecordingError.writerFailure("synthetic disk error") }
      }
      func appendAudio(_ sample: CMSampleBuffer) throws {}
      func finish() throws {}
    }
    let writer = FailingWriter()
    let config = try configuration(feed: "discards", url: URL(fileURLWithPath: "/tmp/discards.mov"))
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    try recorder.start()
    let duration = VideoContract.fastDuration
    XCTAssertTrue(recorder.appendVideo(try videoSample(at: .zero, duration: duration)))
    XCTAssertEqual(writer.entered.wait(timeout: .now() + 5), .success)
    for frame in 1...4 {
      XCTAssertTrue(recorder.appendVideo(try videoSample(at: CMTimeMultiply(duration, multiplier: Int32(frame)),
        duration: duration)))
    }
    writer.release.signal()
    XCTAssertTrue(waitUntil(5) { recorder.telemetry.queueSamples == 0 })
    XCTAssertFalse(recorder.appendVideo(try videoSample(at: CMTimeMultiply(duration, multiplier: 5), duration: duration)))
    let telemetry = recorder.telemetry
    XCTAssertEqual(telemetry.state, .failed)
    XCTAssertEqual(telemetry.appendedVideo, 1)
    XCTAssertEqual(telemetry.droppedAppendFailure, 1)
    XCTAssertEqual(telemetry.droppedVideo, 5, "The failed frame, three discarded behind it and one offered after")
    try? recorder.stop()
  }

  /// The converter wraps each recycled IOSurface once; repeated frames reuse
  /// the cached textures.
  func testConverterReusesTexturesForRecycledSurfaces() throws {
    let converter = try RecordingPixelConverter()
    let source = try v210Frame(width: 96, height: 64)
    func x422() throws -> CVPixelBuffer {
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 96, 64, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
      return try XCTUnwrap(buffer)
    }
    let first = try x422(), second = try x422()
    for _ in 0..<4 { XCTAssertGreaterThanOrEqual(try converter.convert(source, into: first), 0) }
    XCTAssertEqual(converter.cachedTextureCount, 3, "One source texture and two destination planes")
    try converter.convert(source, into: second)
    XCTAssertEqual(converter.cachedTextureCount, 5)
  }

  /// The shared converter kept every IOSurface it wrapped (x422 pool and
  /// capture surfaces, about 0.5 GB for a 4K take) after the take ended. The
  /// cache empties once the last recorder using it finishes.
  func testConverterReleasesSurfacesWhenTheLastTakeFinishes() throws {
    let converter = try RecordingPixelConverter()
    let source = try v210Frame(width: 96, height: 64)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 96, 64, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let destination = try XCTUnwrap(buffer)
    converter.beginUse()
    converter.beginUse()
    try converter.convert(source, into: destination)
    XCTAssertEqual(converter.cachedTextureCount, 3)
    converter.endUse()
    Thread.sleep(forTimeInterval: RecordingPixelConverter.purgeRetryInterval * 2)
    XCTAssertEqual(converter.cachedTextureCount, 3, "Another take still converts through the cache")
    converter.endUse()
    XCTAssertTrue(waitUntil(3) { converter.cachedTextureCount == 0 }, "The last take released every surface")
    // A later take wraps its surfaces again.
    converter.beginUse()
    try converter.convert(source, into: destination)
    XCTAssertEqual(converter.cachedTextureCount, 3)
    converter.endUse()
    XCTAssertTrue(waitUntil(3) { converter.cachedTextureCount == 0 })
  }

  /// On the GPU route a frame without an IOSurface (or whose repack fails)
  /// goes to VideoToolbox as the capture buffer itself. Those frames used to
  /// skip the capture-buffer bound, so VideoToolbox could hold any number of
  /// driver frames. The bound is now decided per frame.
  func testGPURouteFallbackFramesRespectTheCaptureBufferBound() throws {
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("gpu-fallback"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-fallback-\(UUID().uuidString).mov"),
      width: 1_920, height: 1_080, videoCodec: kCMVideoCodecType_AppleProRes422HQ,
      compatibilityPolicy: .init(allowCPUConversion: true))
    let lock = NSLock()
    var received: [CVImageBuffer] = []
    // VideoToolbox never returns a frame: everything submitted stays inside.
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, image, _, _ in
      lock.withLock { received.append(image) }
      return noErr
    })
    try writer.start()
    XCTAssertEqual(writer.telemetry.encoderInputFormat, "x422 (GPU repack from v210)")
    let duration = VideoContract.fastDuration
    // GPU-repacked frames hold no capture buffer.
    let surfaceBacked = try v210Frame(width: 1_920, height: 1_080)
    for index in 0..<2 {
      try writer.appendVideo(try VideoContract.sample(surfaceBacked,
        at: CMTimeMultiply(duration, multiplier: Int32(index)), duration: duration))
    }
    // A capture buffer without an IOSurface cannot be repacked.
    var plain: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1_920, 1_080, kCVPixelFormatType_422YpCbCr10, nil, &plain),
      kCVReturnSuccess)
    let capture = try XCTUnwrap(plain)
    XCTAssertNil(CVPixelBufferGetIOSurface(capture))
    let limit = AVAssetSourceRecordingWriter.maximumCaptureFramesInEncoder
    for index in 2..<limit {
      try writer.appendVideo(try VideoContract.sample(capture,
        at: CMTimeMultiply(duration, multiplier: Int32(index)), duration: duration))
    }
    XCTAssertEqual(lock.withLock { received.filter { $0 === capture }.count }, limit - 2,
      "The fallback hands VideoToolbox the capture buffer itself")
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(try writer.appendVideo(try VideoContract.sample(capture,
      at: CMTimeMultiply(duration, multiplier: Int32(limit)), duration: duration))) { error in
      XCTAssertTrue(error.localizedDescription.contains("capture frames waited in VideoToolbox"),
        error.localizedDescription)
    }
    XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - started, 1.5,
      "The frame waited for the encoder before failing")
    XCTAssertEqual(lock.withLock { received.count }, limit, "The over-limit frame never reached VideoToolbox")
    XCTAssertEqual(writer.telemetry.cpuConvertedFrames, UInt64(limit - 2))
  }

  /// A restarted input (a new HDMI format) starts its capture clock over.
  /// The take used to fail inside the writer with "Video timestamps moved
  /// backwards" and lose what was queued; the recorder now ends it itself,
  /// says why, still writes everything admitted before, and withdraws its
  /// free-space headroom.
  func testRestartedCaptureClockEndsTheTakeVisibly() throws {
    let space = CountingSpaceCheck()
    let writer = SyntheticSourceWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("clock-restart"),
      outputURL: URL(fileURLWithPath: "/tmp/clock-restart.mov"), width: 16, height: 16,
      spaceCheckInterval: 0.05, checkAvailableSpace: { try space.check($0) })
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: recorder)
    try adapter.start()
    let duration = VideoContract.fastDuration
    let image = try v210Frame(width: 16, height: 16)
    for frame in 100..<110 {
      XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: image,
        presentationTime: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration))
    }
    // A pause does not hide the restart.
    try adapter.pause()
    try adapter.resume()
    XCTAssertTrue(waitUntil(2) { space.lastHeadroom.map { $0 > 0 } == true })
    XCTAssertFalse(adapter.appendRawVideo(pixelBuffer: image, presentationTime: duration, duration: duration))
    let telemetry = adapter.telemetry
    XCTAssertEqual(telemetry.state, .failed)
    XCTAssertTrue(telemetry.lastError?.contains("changed format or restarted") == true, telemetry.lastError ?? "")
    XCTAssertFalse(telemetry.lastError?.contains("moved backwards") == true)
    XCTAssertEqual(telemetry.droppedVideo, 1)
    XCTAssertTrue(waitUntil(2) { writer.videoSamples.count == 10 }, "Frames admitted before are still written")
    // The failed take reports what it still owes until that is 0, then stops checking.
    XCTAssertTrue(waitUntil(2) { space.lastHeadroom == 0 })
    let calls = space.calls
    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertEqual(space.calls, calls)
    XCTAssertEqual(space.recordedHeadrooms.filter { $0 == 0 }.count, 1)
    try? adapter.stop()
    XCTAssertEqual(adapter.telemetry.state, .failed)
  }

}

private extension Result where Failure: Error {
  var successValue: Success? {
    guard case let .success(value) = self else { return nil }
    return value
  }
}
