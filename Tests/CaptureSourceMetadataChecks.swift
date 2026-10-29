#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureSourceMetadataChecks: XCTestCase {
  func testVideoPreflightRemainsAvailableWhileAudioIsUnknown() throws {
    let format = try SourceFormat(width: 1280, height: 720, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 25)))
    let source = FakeCaptureSession(format: format, audio: .unknown)
    let feed = FeedID(rawValue: "pending-video-preflight")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    XCTAssertNil(controller.recordingVideoFormat)
    let ready = expectation(description: "Unknown-audio source ready")
    let declared = expectation(description: "Video declaration barrier")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "preflight barrier" { declared.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.info("preflight barrier"))))
    wait(for: [declared], timeout: 1)
    XCTAssertNil(controller.recordingTakeContext, "Audio discovery must remain unresolved")
    XCTAssertEqual(controller.recordingVideoFormat, format,
      "Known video content must remain available for pending-format preflight")
    controller.stop()
    XCTAssertNil(controller.recordingVideoFormat)
  }

  func testSourceGapLimitUsesElapsedTimeAndDisablesVFRSkipInference() throws {
    for (fps, elapsed, variable, expected) in [(25, 12, false, UInt64(0)),
      (120, 8, false, UInt64(959)), (25, 2, true, UInt64(0))] {
      let duration = CMTime(value: 1, timescale: Int32(fps))
      let rate: FrameRate = variable ? .variable(nominal: duration, shortest: duration, longest: duration) : .constant(duration)
      let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: rate)
      let source = FakeCaptureSession(format: format, audio: .absent)
      let feed = FeedID(rawValue: "gap-\(fps)-\(variable)")
      let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
      controller.setCameraOutputEnabled(false)
      let ready = expectation(description: "Gap source ready")
      let measured = expectation(description: "Gap accounting barrier")
      controller.onUpdate = { update in
        if update.message.hasPrefix("Waiting") { ready.fulfill() }
        if update.message == "gap barrier" {
          XCTAssertEqual(update.sourceDrops, expected, "\(fps)fps, \(elapsed)s, VFR=\(variable)")
          measured.fulfill()
        }
      }
      controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
      wait(for: [ready], timeout: 1)
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
      let buffer = CapturedPixelBuffer(immutable: try XCTUnwrap(image))
      let context = source.context
      for seconds in [0, elapsed] {
        let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
          presentationTime: CMTime(value: Int64(seconds), timescale: 1), duration: duration, signalValid: true, timecode: nil)
        XCTAssertTrue(source.submit(.frame(buffer, info)))
      }
      XCTAssertTrue(source.submit(.event(.info("gap barrier"))))
      wait(for: [measured], timeout: 1)
      controller.onUpdate = nil
      controller.stop()
    }
  }

  /// A signal dropout (no-signal event, then frames again) is measured on
  /// the source clock and counted apart from a device skip, which is still
  /// a source gap; both are video losses.
  func testSignalDropoutIsCountedApartFromDeviceSkips() throws {
    let duration = CMTime(value: 1, timescale: 25)
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(duration))
    let source = FakeCaptureSession(format: format, audio: .absent)
    let feed = FeedID(rawValue: "signal-dropout")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Dropout source ready")
    let measured = expectation(description: "Dropout accounting barrier")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "dropout barrier" {
        XCTAssertEqual(update.signalDropouts, 1)
        XCTAssertEqual(update.signalLostFrames, 3, "Frames 3, 4 and 5 never arrived")
        XCTAssertEqual(update.sourceDrops, 1, "Only frame 8 is a device skip")
        XCTAssertEqual(update.dropped, 4)
        measured.fulfill()
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
    let buffer = CapturedPixelBuffer(immutable: try XCTUnwrap(image))
    let context = source.context
    func frame(_ index: Int64) {
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: CMTimeMultiply(duration, multiplier: Int32(index)), duration: duration, signalValid: true, timecode: nil)
      XCTAssertTrue(source.submit(.frame(buffer, info)))
    }
    for index in 0...2 { frame(Int64(index)) }
    XCTAssertTrue(source.submit(.event(.signalLost(reason: "No HDMI video signal"))))
    // A second report during the same dropout is not a second dropout.
    XCTAssertTrue(source.submit(.event(.signalLost(reason: "No HDMI video signal"))))
    frame(6); frame(7); frame(9)
    XCTAssertTrue(source.submit(.event(.info("dropout barrier"))))
    wait(for: [measured], timeout: 1)
  }

  func testLossLoggingIsBoundedAndKeepsTotals() {
    var limiter = LossLogLimiter(burst: 3, interval: 60)
    XCTAssertEqual(limiter.note(frames: 2, at: 0), .log)
    XCTAssertEqual(limiter.note(frames: 1, at: 1), .log)
    XCTAssertEqual(limiter.note(frames: 4, at: 2), .logLast)
    XCTAssertEqual(limiter.note(frames: 1, at: 3), .quiet)
    XCTAssertEqual(limiter.note(frames: 2, at: 30), .quiet)
    XCTAssertEqual(limiter.note(frames: 3, at: 62), .summary(events: 3, frames: 6))
    XCTAssertEqual(limiter.note(frames: 5, at: 70), .quiet)
    XCTAssertEqual(limiter.events, 7)
    XCTAssertEqual(limiter.frames, 18)
    XCTAssertEqual(limiter.flush()?.events, 1)
    XCTAssertNil(limiter.flush())
    // A thousand losses an hour log 3 + one per minute, never a thousand lines.
    var flood = LossLogLimiter(burst: 3, interval: 60)
    let lines = (0..<1000).filter { flood.note(frames: 1, at: Double($0) * 3.6) != .quiet }.count
    XCTAssertLessThanOrEqual(lines, 3 + 61)
  }

  func testDeclared24FPSDoesNotMasqueradeAsLegacySlowInput() throws {
    let duration = CMTime(value: 1, timescale: 24)
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(duration))
    let source = FakeCaptureSession(format: format, audio: .absent)
    let feed = FeedID(rawValue: "declared-24fps-source")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "24 fps source ready")
    let measured = expectation(description: "Actual source rate published")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "frame rate barrier" {
        XCTAssertEqual(update.sourceDuration, duration)
        XCTAssertEqual(update.sourceFormat?.rate, .constant(duration))
        measured.fulfill()
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let context = source.context
    let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: CMTime(value: 20, timescale: 1), duration: duration, signalValid: true, timecode: nil)
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)), info)))
    XCTAssertTrue(source.submit(.event(.info("frame rate barrier"))))
    wait(for: [measured], timeout: 1)
    source.stop()
  }

  func testSourceEpochChangeReanchorsLegacyHostClockBeforeNewFrames() throws {
    let first = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let second = try SourceFormat(width: 1280, height: 720, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: first, audio: .absent)
    let feed = FeedID(rawValue: "epoch-host-anchor")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Epoch source ready")
    let initial = expectation(description: "Initial source declarations processed")
    let changed = expectation(description: "Changed source declarations processed")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "initial anchor barrier" { initial.fulfill() }
      if update.message == "changed anchor barrier" { changed.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.info("initial anchor barrier"))))
    wait(for: [initial], timeout: 1)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    CVBufferSetAttachment(buffer, DeviceAPI.captureHostTimeAttachmentKey as CFString, NSNumber(value: 100.0), .shouldNotPropagate)
    let old = controller.hostTimeForTesting(sourceTime: CMTime(value: 20, timescale: 1), duration: VideoContract.fastDuration,
      image: buffer, reference: .presentationStart)
    XCTAssertEqual(old.seconds, 100)
    XCTAssertTrue(source.submit(.event(.formatChanged(second))))
    XCTAssertTrue(source.submit(.event(.info("changed anchor barrier"))))
    wait(for: [changed], timeout: 1)
    CVBufferSetAttachment(buffer, DeviceAPI.captureHostTimeAttachmentKey as CFString, NSNumber(value: 200.0), .shouldNotPropagate)
    let current = controller.hostTimeForTesting(sourceTime: CMTime(value: 21, timescale: 1), duration: VideoContract.fastDuration,
      image: buffer, reference: .presentationStart)
    XCTAssertEqual(current.seconds, 200, "A new epoch must not reuse the previous epoch's source/host origin")
    source.stop()
  }

  func testPauseAllowanceIsSampledAtStartAndDoesNotAlterGPUWatchdogContract() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: format)
    let feed = FeedID(rawValue: "pausable-source")
    var services = CaptureServices.registryBridge(feedID: feed, makeSession: { _ in source })
    services.sourcePauseAllowance = { _ in 10 }
    let controller = CaptureController(services: services)
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Pause policy sampled")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    defer { controller.onUpdate = nil; controller.stop() }
    XCTAssertEqual(controller.sourceSignalTimeoutForTesting, 2)
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertEqual(controller.sourceSignalTimeoutForTesting, 10)
    source.stop()
  }

  func testStrongestDeclaredChannelDrivesActivityWithoutReplacingLeftRightMeters() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let audio = try SourceAudioFormat(sampleRate: 96000, channels: 8, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let source = FakeCaptureSession(format: format, audio: .present(audio))
    let feed = FeedID(rawValue: "all-channel-activity")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Activity source ready")
    let measured = expectation(description: "All-channel activity published")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "meter barrier" {
        XCTAssertEqual(update.audioPeakLeft, 0.1, accuracy: 0.000001)
        XCTAssertEqual(update.audioPeakRight, 0.2, accuracy: 0.000001)
        XCTAssertEqual(update.audioActivityPeak, 0.9, accuracy: 0.000001)
        XCTAssertEqual(update.audioActivityRMS, 0.8, accuracy: 0.000001)
        XCTAssertEqual(update.audioSampleRate, 96000)
        measured.fulfill()
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.media(CaptureMediaInfo(timecode: nil, pairedFrameSequence: nil,
      audioDeclaration: .present(audio), audioPacketTime: .zero, audioClockInstance: source.context.clockBindings.audio,
      sampleFrameCount: 800, byteCount: 25600, peaks: [0.1, 0.2, 0.9, 0, 0, 0, 0, 0],
      rms: [0.1, 0.2, 0.8, 0, 0, 0, 0, 0]))))
    XCTAssertTrue(source.submit(.event(.info("meter barrier"))))
    wait(for: [measured], timeout: 1)
    source.stop()
  }
}
#endif
