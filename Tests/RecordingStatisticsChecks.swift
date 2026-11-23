import AVFoundation
import Foundation
import XCTest

@objcMembers final class RecordingStatisticsChecks: XCTestCase {
  private final class Writer: SourceRecordingWriter {
    var value = SourceRecordingWriterTelemetry()
    var telemetry: SourceRecordingWriterTelemetry { value }
    func start() throws {}
    func appendVideo(_ sample: CMSampleBuffer) throws {}
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws {}
  }
  private final class Clock: @unchecked Sendable {
    var value = 100.0
  }
  private func core(_ writer: Writer) throws -> SourceRecorderCore {
    try SourceRecorderCore(configuration: SourceRecordingConfiguration(feedID: SourceRecordingFeedID("stats"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-statistics.mov"), width: 16, height: 16), writerFactory: { writer })
  }

  func testRecordingClockFreezesDuringPauseAndFinish() {
    let now = Clock()
    let clock = RecordingSessionClock(now: { now.value })
    now.value = 112
    XCTAssertEqual(clock.elapsed, 12)
    clock.pause()
    now.value = 140
    XCTAssertEqual(clock.elapsed, 12)
    clock.pause()
    clock.resume()
    now.value = 145
    XCTAssertEqual(clock.elapsed, 17)
    clock.pause()
    now.value = 200
    XCTAssertEqual(clock.elapsed, 17)
  }

  func testIntervalRatesAndStoppedCountersAreIndependentPerFeed() throws {
    let firstWriter = Writer(), secondWriter = Writer()
    let first = try core(firstWriter), second = try core(secondWriter)
    var a = RecordingStatisticsSampler(), b = RecordingStatisticsSampler()
    _ = a.sample(first.telemetry, elapsed: 0, fileBytes: 0, fileURL: nil, now: 10)
    _ = b.sample(second.telemetry, elapsed: 0, fileBytes: 0, fileURL: nil, now: 10)
    firstWriter.value.encodedVideo = 60
    firstWriter.value.encodedVideoBytes = 2_000_000
    firstWriter.value.hardwareEncoder = true
    firstWriter.value.encoderLatencyMS = 3
    firstWriter.value.maxEncoderLatencyMS = 7
    firstWriter.value.droppedEncodedVideo = 2
    first.recordDrop(.queueFull)
    first.recordDrop(.invalidSample, video: false)
    first.recordDrop(.paused)
    first.recordDrop(.notRecording)
    let live = a.sample(first.telemetry, elapsed: 2, fileBytes: 2_100_000, fileURL: nil, now: 12)
    XCTAssertEqual(live.framesPerSecond, 30)
    XCTAssertEqual(live.videoMegabitsPerSecond, 8)
    XCTAssertEqual(live.droppedVideoFrames, 3)
    XCTAssertEqual(live.droppedAudioPackets, 1)
    XCTAssertEqual(live.fileBytes, 2_100_000)
    XCTAssertEqual(live.hardwareEncoder, true)
    XCTAssertEqual(live.encoderLatencyMS, 3)
    let clean = b.sample(second.telemetry, elapsed: 2, fileBytes: 0, fileURL: nil, now: 12)
    XCTAssertEqual(clean.encodedFrames, 0)
    XCTAssertEqual(clean.droppedVideoFrames, 0)
    let final = a.sample(first.telemetry, elapsed: 2, fileBytes: 2_200_000, fileURL: nil, now: 13, stopped: true)
    XCTAssertEqual(final.encodedFrames, 60)
    XCTAssertEqual(final.framesPerSecond, 0)
    XCTAssertEqual(final.videoMegabitsPerSecond, 0)
    XCTAssertEqual(final.droppedVideoFrames, 3)
    XCTAssertEqual(final.elapsedText, "00:00:02")
  }

  func testGPUBusyTimeUnionsOverlappingFeedsAndClipsSamplingWindow() {
    XCTAssertEqual(AppGPUActivity.busyPercent([(9, 10.2), (10.1, 10.5), (10.4, 10.7)], from: 10, to: 11), 70, accuracy: 0.001)
    XCTAssertEqual(AppGPUActivity.busyPercent([(9, 12), (10, 11)], from: 10, to: 11), 100)
    XCTAssertEqual(AppGPUActivity.busyPercent([(1, 2), (12, 13)], from: 10, to: 11), 0)
    XCTAssertEqual(AppGPUActivity.busyPercent([(0, .infinity), (.nan, 1)], from: 0, to: 1), 0)
    XCTAssertEqual(AppGPUActivity.busyPercent([(0, 1)], from: 1, to: 1), 0)
    XCTAssertEqual(AppGPUActivity.busyPercent([(0, 1)], from: -.infinity, to: 1), 0)
    XCTAssertEqual(AppGPUActivity.busyPercent([(-1e308, 1e308)], from: -1e308, to: 1e308), 0)
  }

  func testCounterSumAndElapsedDisplayHandleExtremeValues() throws {
    let writer = Writer()
    writer.value.droppedEncodedVideo = .max
    let recorder = try core(writer)
    recorder.recordDrop(.queueFull)
    var sampler = RecordingStatisticsSampler()
    let stats = sampler.sample(recorder.telemetry, elapsed: Double(Int32.max) * 3600 + 3600,
      fileBytes: 0, fileURL: nil)
    XCTAssertEqual(stats.droppedVideoFrames, .max)
    XCTAssertEqual(stats.elapsedText, "2147483648:00:00")
    XCTAssertEqual(RecordingStatistics(elapsed: .nan).elapsedText, "00:00:00")
    XCTAssertEqual(RecordingStatistics(elapsed: .infinity).elapsedText, "00:00:00")
  }

  func testInvalidAudioIsNotCountedAsVideoLoss() throws {
    let writer = Writer(), recorder = try core(writer)
    let adapter = SourceRecordingCallbackAdapter(feedID: SourceRecordingFeedID("stats"), recorder: recorder)
    XCTAssertFalse(adapter.appendEmbeddedAudio(sourcePCM32: Data(), sampleFrameCount: 800, presentationTime: .zero))
    XCTAssertEqual(recorder.telemetry.droppedAudio, 1)
    XCTAssertEqual(recorder.telemetry.droppedVideo, 0)
  }
}
