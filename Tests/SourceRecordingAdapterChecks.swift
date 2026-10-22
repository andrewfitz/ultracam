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
