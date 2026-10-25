import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import XCTest

private final class FailAfterFirstVideoWriter: SourceRecordingWriter, @unchecked Sendable {
  private let lock = NSLock()
  private let videoSignal = DispatchSemaphore(value: 0)
  private var videos = 0
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {
    let count = lock.withLock { () -> Int in
      videos += 1
      return videos
    }
    videoSignal.signal()
    if count > 1 { throw SourceRecordingError.writerFailure("second sample rejected") }
  }
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func finish() throws {}
  func waitForVideo(timeout: TimeInterval = 1) -> Bool {
    videoSignal.wait(timeout: .now() + timeout) == .success
  }
}

private final class AdapterRecordingWriter: SourceRecordingWriter, @unchecked Sendable {
  private let lock = NSLock()
  private let videoSignal = DispatchSemaphore(value: 0)
  private let audioSignal = DispatchSemaphore(value: 0)
  private(set) var videos: [CMSampleBuffer] = []
  private(set) var audios: [CMSampleBuffer] = []
  private(set) var started = false
  private(set) var finished = false

  func start() throws { lock.withLock { started = true } }

  func appendVideo(_ sample: CMSampleBuffer) throws {
    lock.withLock { videos.append(sample) }
    videoSignal.signal()
  }

  func appendAudio(_ sample: CMSampleBuffer) throws {
    lock.withLock { audios.append(sample) }
    audioSignal.signal()
  }

  func finish() throws { lock.withLock { finished = true } }

  func waitForVideo(timeout: TimeInterval = 1) -> Bool {
    videoSignal.wait(timeout: .now() + timeout) == .success
  }

  func waitForAudio(timeout: TimeInterval = 1) -> Bool {
    audioSignal.wait(timeout: .now() + timeout) == .success
  }

  var videoSnapshot: [CMSampleBuffer] { lock.withLock { videos } }
  var audioSnapshot: [CMSampleBuffer] { lock.withLock { audios } }
}

private final class BlockingStopWriter: SourceRecordingWriter, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let failure: SourceRecordingError?
  var onFinish: (() throws -> Void)?
  private(set) var finishCount = 0
  init(failure: SourceRecordingError?) { self.failure = failure }
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {}
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func finish() throws {
    finishCount += 1
    try onFinish?()
    entered.signal()
    guard release.wait(timeout: .now() + 3) == .success else {
      throw SourceRecordingError.writerFailure("Timed out waiting for test release.")
    }
    if let failure { throw failure }
  }
}

private final class AsynchronouslyFailedWriter: SourceRecordingWriter, @unchecked Sendable {
  private let lock = NSLock()
  private var failed = false
  var telemetry: SourceRecordingWriterTelemetry {
    lock.withLock { SourceRecordingWriterTelemetry(failed: failed, lastError: failed ? "callback failed" : nil) }
  }
  func fail() { lock.withLock { failed = true } }
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {}
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func finish() throws {}
}

@objcMembers final class SourceRecordingAdapterChecks: XCTestCase {
  func testRawVideoCallbackRetainsOriginalSourceBufferAndTiming() throws {
    let writer = AdapterRecordingWriter()
    let feedID = SourceRecordingFeedID("camera-a")
    let config = try SourceRecordingConfiguration(feedID: feedID,
      outputURL: URL(fileURLWithPath: "/tmp/camera-a.mov"), width: 96, height: 64,
      queueCapacity: 2)
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: feedID, recorder: recorder)
    try adapter.start()

    var source: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 96, 64,
      kCVPixelFormatType_422YpCbCr10, nil, &source), kCVReturnSuccess)
    let image = try XCTUnwrap(source)
    let pts = CMTime(value: 12_345, timescale: 60_000)
    let duration = CMTime(value: 1_001, timescale: 60_000)
    XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: image, presentationTime: pts,
      duration: duration))
    XCTAssertTrue(writer.waitForVideo())

    let sample = try XCTUnwrap(writer.videoSnapshot.first)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === image,
      "The source CVPixelBuffer must be handed to the writer unchanged")
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_422YpCbCr10)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), pts)
    XCTAssertEqual(CMSampleBufferGetDuration(sample), duration)
    XCTAssertEqual(adapter.feedID, feedID)
    XCTAssertEqual(adapter.telemetry.enqueuedVideo, 1)
    XCTAssertEqual(adapter.telemetry.appendedVideo, 1)
    XCTAssertFalse(adapter.appendRawVideo(pixelBuffer: image, presentationTime: pts,
      duration: duration, signalValid: false))
    XCTAssertEqual(adapter.telemetry.droppedInvalidSample, 1)

    try adapter.stop()
    XCTAssertEqual(adapter.state, .finished)
    XCTAssertTrue(writer.finished)
  }

  func testAppendFailureWhileStoppingStaysFailed() throws {
    let writer = FailAfterFirstVideoWriter()
    let feedID = SourceRecordingFeedID("camera-fail")
    let config = try SourceRecordingConfiguration(feedID: feedID,
      outputURL: URL(fileURLWithPath: "/tmp/camera-fail.mov"), width: 96, height: 64,
      queueCapacity: 4)
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: feedID, recorder: recorder)
    try adapter.start()
    var source: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 96, 64, kCVPixelFormatType_422YpCbCr10, nil, &source), kCVReturnSuccess)
    let image = try XCTUnwrap(source)
    let duration = CMTime(value: 1_001, timescale: 60_000)
    XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: image,
      presentationTime: CMTime(value: 0, timescale: 60_000), duration: duration))
    XCTAssertTrue(adapter.appendRawVideo(pixelBuffer: image,
      presentationTime: CMTime(value: 1_001, timescale: 60_000), duration: duration))
    XCTAssertTrue(writer.waitForVideo())
    XCTAssertNoThrow(try adapter.stop())
    XCTAssertEqual(adapter.state, .failed)
    XCTAssertFalse(adapter.appendRawVideo(pixelBuffer: image,
      presentationTime: CMTime(value: 2_002, timescale: 60_000), duration: duration))
    XCTAssertEqual(adapter.state, .failed)
  }

  func testEmbeddedAudioCallbackForwardsSampleBufferAndPayload() throws {
    let writer = AdapterRecordingWriter()
    let feedID = SourceRecordingFeedID("audio-camera")
    let config = try SourceRecordingConfiguration(feedID: feedID,
      outputURL: URL(fileURLWithPath: "/tmp/audio-camera.mov"), width: 96, height: 64)
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: feedID, recorder: recorder)
    try adapter.start()

    let payload = Data([0x01, 0x02, 0x80, 0x7f, 0xff, 0x00, 0xaa, 0x55])
    let source = try audioSample(payload: payload,
      presentationTime: CMTime(value: 2_400, timescale: 48_000))
    XCTAssertTrue(adapter.appendEmbeddedAudio(sample: source))
    XCTAssertTrue(writer.waitForAudio())

    let sample = try XCTUnwrap(writer.audioSnapshot.first)
    XCTAssertTrue(sample === source,
      "An already formed embedded-audio sample must cross the adapter unchanged")
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample),
      CMTime(value: 2_400, timescale: 48_000))
    XCTAssertEqual(try blockBytes(sample), payload)
    XCTAssertEqual(adapter.telemetry.enqueuedAudio, 1)
    XCTAssertEqual(adapter.telemetry.appendedAudio, 1)
    try adapter.stop()
  }

  func testFeedCallbacksRemainIndependent() throws {
    let firstWriter = AdapterRecordingWriter()
    let secondWriter = AdapterRecordingWriter()
    let firstID = SourceRecordingFeedID("feed-one")
    let secondID = SourceRecordingFeedID("feed-two")
    let firstConfig = try SourceRecordingConfiguration(feedID: firstID,
      outputURL: URL(fileURLWithPath: "/tmp/feed-one.mov"), width: 32, height: 32)
    let secondConfig = try SourceRecordingConfiguration(feedID: secondID,
      outputURL: URL(fileURLWithPath: "/tmp/feed-two.mov"), width: 32, height: 32)
    let first = SourceRecordingCallbackAdapter(feedID: firstID,
      recorder: try SourceRecorderCore(configuration: firstConfig, writerFactory: { firstWriter }))
    let second = SourceRecordingCallbackAdapter(feedID: secondID,
      recorder: try SourceRecorderCore(configuration: secondConfig, writerFactory: { secondWriter }))
    try first.start()
    try second.start()

    let firstImage = try image(width: 32, height: 32)
    let secondImage = try image(width: 32, height: 32)
    let firstCallbacks = first.callbacks
    let secondCallbacks = second.callbacks
    XCTAssertTrue(firstCallbacks.video(firstImage, .zero,
      CMTime(value: 1_001, timescale: 60_000), true))
    XCTAssertTrue(secondCallbacks.video(secondImage, CMTime(value: 1_001, timescale: 60_000),
      CMTime(value: 1_001, timescale: 60_000), true))
    XCTAssertTrue(firstWriter.waitForVideo())
    XCTAssertTrue(secondWriter.waitForVideo())

    XCTAssertEqual(first.feedID, firstID)
    XCTAssertEqual(second.feedID, secondID)
    XCTAssertNotEqual(first.feedID, second.feedID)
    XCTAssertEqual(firstWriter.videoSnapshot.count, 1)
    XCTAssertEqual(secondWriter.videoSnapshot.count, 1)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(firstWriter.videoSnapshot[0]) === firstImage)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(secondWriter.videoSnapshot[0]) === secondImage)
    XCTAssertEqual(first.telemetry.enqueuedVideo, 1)
    XCTAssertEqual(second.telemetry.enqueuedVideo, 1)

    try first.stop()
    try second.stop()
    XCTAssertEqual(first.state, .finished)
    XCTAssertEqual(second.state, .finished)
  }

  func testConcurrentStopWaitsAndRepeatsFinishOutcome() throws {
    for failure: SourceRecordingError? in [nil, .writerFailure("finish failed")] {
      let writer = BlockingStopWriter(failure: failure)
      let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("stop"),
        outputURL: URL(fileURLWithPath: "/tmp/stop.mov"), width: 32, height: 32)
      let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
      writer.onFinish = { [weak recorder] in try recorder?.stop() }
      try recorder.start()
      let first = expectation(description: "First stop finished")
      let second = expectation(description: "Second stop finished")
      let secondEntered = DispatchSemaphore(value: 0)
      let secondReturned = DispatchSemaphore(value: 0)
      let stop = {
        do {
          try recorder.stop()
          XCTAssertNil(failure)
        } catch { XCTAssertEqual(error as? SourceRecordingError, failure) }
      }
      DispatchQueue.global().async { stop(); first.fulfill() }
      XCTAssertEqual(writer.entered.wait(timeout: .now() + 1), .success)
      DispatchQueue.global().async {
        secondEntered.signal()
        stop()
        secondReturned.signal()
        second.fulfill()
      }
      XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(secondReturned.wait(timeout: .now() + 0.05), .timedOut)
      writer.release.signal()
      wait(for: [first, second], timeout: 3)
      stop()
      XCTAssertEqual(writer.finishCount, 1)
      XCTAssertEqual(recorder.state, failure == nil ? .finished : .failed)
    }
  }

  func testWriterFailureClosesAdmissionAndMatchesTelemetry() throws {
    for readTelemetryFirst in [true, false] {
      let writer = AsynchronouslyFailedWriter()
      let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("failure"),
        outputURL: URL(fileURLWithPath: "/tmp/failure.mov"), width: 32, height: 32)
      let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
      let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: recorder)
      try adapter.start()
      writer.fail()
      if readTelemetryFirst { XCTAssertEqual(recorder.telemetry.state, .failed) }
      XCTAssertFalse(adapter.callbacks.video(try image(width: 32, height: 32), .zero,
        CMTime(value: 1, timescale: 30), true))
      XCTAssertEqual(recorder.state, .failed)
      XCTAssertEqual(recorder.telemetry.state, recorder.state)
      XCTAssertEqual(recorder.telemetry.enqueuedVideo, 0)
      try recorder.stop()
      XCTAssertEqual(recorder.state, .failed)
    }
  }

  func testRawAudioRejectsUnsupportedSampleWidthAndCountsDrop() throws {
    let writer = AdapterRecordingWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("raw-audio"),
      outputURL: URL(fileURLWithPath: "/tmp/raw-audio.mov"), width: 32, height: 32)
    let adapter = try SourceRecordingCallbackAdapter(configuration: config, writerFactory: { writer })
    try adapter.start()
    XCTAssertFalse(adapter.callbacks.rawAudio(Data(repeating: 0, count: 32), 1, .zero, 16, 2))
    XCTAssertEqual(adapter.telemetry.droppedInvalidSample, 1)
    XCTAssertEqual(adapter.telemetry.droppedAudio, 1)
    XCTAssertEqual(adapter.telemetry.droppedVideo, 0)
    XCTAssertEqual(adapter.telemetry.enqueuedAudio, 0)
    try adapter.stop()
  }

  /// The 2026-10-24 take: each DeckLink callback's audio packet time ran
  /// 42 050 samples (0.876 s) ahead of its frame's stream time, and the audio
  /// was written that far behind the picture for the whole take. A packet is
  /// its frame's audio, so it must land on that frame's time, sample-exact,
  /// with every packet contiguous and none dropped.
  func testRawAudioLandsOnItsFramesVideoTime() throws {
    for clockOffset: Int64 in [42_050, 21_132, 0, -9_600] {
      let (writer, adapter) = try rawAudioAdapter("clock-\(clockOffset)")
      let callbacks = adapter.callbacks
      let frames = 120
      let videoOrigin: Int64 = 600 * 1_001  // ten seconds of stream time
      let audioOrigin = videoOrigin * 4 / 5 + 48_000 + clockOffset  // well clear of zero
      for frame in 0..<frames {
        XCTAssertTrue(sendCallback(callbacks, frame: frame, videoOrigin: videoOrigin, audioOrigin: audioOrigin))
      }
      XCTAssertTrue(waitForAudio(writer, count: frames))
      try adapter.stop()
      try assertAudioOnVideoClock(writer.audioSnapshot, firstFrame: 0, videoOrigin: videoOrigin)
      XCTAssertEqual(adapter.telemetry.droppedAudio, 0)
      XCTAssertEqual(adapter.telemetry.appendedAudio, UInt64(frames))
    }
  }

  /// A take's first callback can carry no audio: the first packet then
  /// belongs to the second frame, not the first.
  func testRawAudioAnchorsToTheFrameOfItsOwnCallback() throws {
    let (writer, adapter) = try rawAudioAdapter("first-without-audio")
    let callbacks = adapter.callbacks
    let videoOrigin: Int64 = 1_001 * 37
    let audioOrigin: Int64 = 96_000 + 42_050
    for frame in 0..<30 {
      XCTAssertTrue(sendCallback(callbacks, frame: frame, videoOrigin: videoOrigin, audioOrigin: audioOrigin,
        audio: frame > 0))
    }
    XCTAssertTrue(waitForAudio(writer, count: 29))
    try adapter.stop()
    try assertAudioOnVideoClock(writer.audioSnapshot, firstFrame: 1, videoOrigin: videoOrigin)
  }

  /// Should the device re-base one clock mid-take (an HDMI re-lock), the next
  /// pair re-anchors. Moving later leaves a gap; moving earlier would overlap
  /// written audio, so audio stays contiguous and no sample is dropped.
  func testRawAudioReanchorsAfterAClockStepWithoutDroppingAudio() throws {
    for step: Int64 in [129_600, -4_000] {
      let (writer, adapter) = try rawAudioAdapter("step-\(step)")
      let callbacks = adapter.callbacks
      let videoOrigin: Int64 = 1_001 * 300
      let audioOrigin: Int64 = 400_000
      for frame in 0..<60 {
        XCTAssertTrue(sendCallback(callbacks, frame: frame, videoOrigin: videoOrigin,
          audioOrigin: audioOrigin + (frame >= 30 ? step : 0)))
      }
      XCTAssertTrue(waitForAudio(writer, count: 60))
      try adapter.stop()
      let audio = writer.audioSnapshot
      XCTAssertEqual(adapter.telemetry.droppedAudio, 0)
      try assertAudioOnVideoClock(Array(audio.prefix(30)), firstFrame: 0, videoOrigin: videoOrigin)
      if step > 0 {
        try assertAudioOnVideoClock(Array(audio.suffix(30)), firstFrame: 30, videoOrigin: videoOrigin)
      } else {
        for index in 1..<audio.count {
          XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(audio[index]),
            CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(audio[index - 1]),
              CMSampleBufferGetDuration(audio[index - 1])), "packet \(index) must not overlap or gap")
        }
      }
    }
  }

  /// The start of 59.94 frame `frame` in 48 kHz samples (800.8 per frame).
  private func videoSamples(_ frame: Int, videoOrigin: Int64) -> Int64 {
    CMTimeConvertScale(CMTime(value: videoOrigin + Int64(frame) * 1_001, timescale: 60_000),
      timescale: 48_000, method: .roundHalfAwayFromZero).value
  }

  /// One DeckLink callback: the frame, then its packet. Packets carry 800 or
  /// 801 samples and run contiguously on their own clock.
  private func sendCallback(_ callbacks: SourceRecordingCallbackAdapter.Callbacks, frame: Int,
    videoOrigin: Int64, audioOrigin: Int64, audio: Bool = true) -> Bool {
    let duration = CMTime(value: 1_001, timescale: 60_000)
    guard let image = try? image(width: 32, height: 32),
      callbacks.video(image, CMTime(value: videoOrigin + Int64(frame) * 1_001, timescale: 60_000),
        duration, true) else { return false }
    guard audio else { return true }
    let start = videoSamples(frame, videoOrigin: 0)
    let count = Int(videoSamples(frame + 1, videoOrigin: 0) - start)
    return callbacks.rawAudio(Data(count: count * 2 * 4), count,
      CMTime(value: audioOrigin + start, timescale: 48_000), 2, 4)
  }

  private func assertAudioOnVideoClock(_ audio: [CMSampleBuffer], firstFrame: Int, videoOrigin: Int64,
    file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertFalse(audio.isEmpty, file: file, line: line)
    for (index, sample) in audio.enumerated() {
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      XCTAssertEqual(pts.timescale, 48_000, file: file, line: line)
      let frameStart = videoSamples(firstFrame + index, videoOrigin: videoOrigin)
      XCTAssertLessThanOrEqual(abs(pts.value - frameStart), 1,
        "packet \(index) at \(pts.value), its frame at \(frameStart)", file: file, line: line)
      if index > 0 {
        let previous = audio[index - 1]
        XCTAssertEqual(pts, CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(previous),
          CMSampleBufferGetDuration(previous)), "packet \(index) must be contiguous", file: file, line: line)
      }
    }
  }

  private func rawAudioAdapter(_ name: String) throws -> (AdapterRecordingWriter, SourceRecordingCallbackAdapter) {
    let writer = AdapterRecordingWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(name),
      outputURL: URL(fileURLWithPath: "/tmp/\(name).mov"), width: 32, height: 32)
    let adapter = try SourceRecordingCallbackAdapter(configuration: config, writerFactory: { writer })
    try adapter.start()
    return (writer, adapter)
  }

  private func waitForAudio(_ writer: AdapterRecordingWriter, count: Int) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while writer.audioSnapshot.count < count {
      guard Date() < deadline else { return false }
      _ = writer.waitForAudio(timeout: 0.1)
    }
    return true
  }

  private func image(width: Int, height: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height,
      kCVPixelFormatType_422YpCbCr10, nil, &result), kCVReturnSuccess)
    return try XCTUnwrap(result)
  }

  private func audioSample(payload: Data, presentationTime: CMTime) throws -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
      blockBufferOut: &blockBuffer), kCMBlockBufferNoErr)
    let block = try XCTUnwrap(blockBuffer)
    payload.withUnsafeBytes { bytes in
      if let baseAddress = bytes.baseAddress {
        _ = CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: block,
          offsetIntoDestination: 0, dataLength: payload.count)
      }
    }

    var description = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var sampleSize = payload.count
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
      dataBuffer: block, formatDescription: try XCTUnwrap(format), sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }

  private func blockBytes(_ sample: CMSampleBuffer) throws -> Data {
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
    var total = 0
    var length = 0
    var pointer: UnsafeMutablePointer<Int8>?
    XCTAssertEqual(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
      totalLengthOut: &total, dataPointerOut: &pointer), kCMBlockBufferNoErr)
    return Data(bytes: try XCTUnwrap(pointer), count: total)
  }
}
