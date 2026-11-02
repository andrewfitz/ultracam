#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

/// Signals seen, and a time, across the controller's callback.
private final class SignalLog: @unchecked Sendable {
  private let lock = NSLock()
  private var signals: [CaptureSignal] = []
  private var stored: TimeInterval = 0
  var time: TimeInterval {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
  func note(_ signal: CaptureSignal) -> (count: Int, wasLost: Bool) {
    lock.withLock {
      if signals.last != signal { signals.append(signal) }
      return (signals.count, signals.contains { if case .lost = $0 { return true }; return false })
    }
  }
}

/// The typed signal: what the capture publishes, on each transition, and how the
/// interface reads it. HDMI loss must be visible after the first frame.
@objcMembers final class CaptureSignalChecks: XCTestCase {
  private let duration = CMTime(value: 1, timescale: 25)

  private func image() throws -> CapturedPixelBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
    return CapturedPixelBuffer(immutable: try XCTUnwrap(image))
  }

  private func frame(_ index: Int64, _ source: FakeCaptureSession, _ buffer: CapturedPixelBuffer) {
    let context = source.context
    let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: CMTimeMultiply(duration, multiplier: Int32(index)), duration: duration, signalValid: true, timecode: nil)
    XCTAssertTrue(source.submit(.frame(buffer, info)))
  }

  private func harness(_ name: String) throws -> (source: FakeCaptureSession, controller: CaptureController, feed: FeedID) {
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(duration))
    let source = FakeCaptureSession(format: format, audio: .absent)
    let feed = FeedID(rawValue: name)
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    return (source, controller, feed)
  }

  private func start(_ controller: CaptureController, _ feed: FeedID) {
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
  }

  // MARK: Reading it

  func testInterfaceReadsTheTypedSignalBeforeAnyLabel() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    var update = CaptureUpdate(message: "")
    update.sourceFormat = format
    // A format stays declared through a dropout: it names the picture, nothing more.
    update.signal = .lost(since: 1)
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update), .noSignal)
    update.signal = .lost(since: 1)
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: false, update: update), .deviceMissing)
    update.signal = .unsupported("1080i 59.94 isn't supported.")
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update),
      .unsupported("1080i 59.94 isn't supported."))
    update.signal = .live
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update), .live(format: "1080p 59.94"))
  }

  /// The words no longer decide anything: only the signal does.
  func testMessagesAndLabelsNoLongerDecideTheSignal() {
    var update = CaptureUpdate(message: "No video signal: unsupported")
    update.input = "No signal"
    update.frames = 12
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update), .connecting)
    update.signal = .live
    update.input = "1920 × 1080 · v210 · 59.94 fps"
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update), .live(format: "1080p 59.94"))
    // Live with nothing to name it yet is still starting.
    update.input = "No signal"
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: true, update: update), .connecting)
    XCTAssertEqual(UIFormatLabels.signal(running: true, deviceAvailable: false, update: update), .deviceMissing)
  }

  func testSignalIsStateNotTelemetry() {
    var first = CaptureUpdate(message: "")
    first.signal = .live
    first.frames = 1
    var second = first
    second.frames = 99
    XCTAssertEqual(CaptureUpdateState(first), CaptureUpdateState(second))
    second.signal = .lost(since: 5)
    XCTAssertNotEqual(CaptureUpdateState(first), CaptureUpdateState(second), "A loss has to tell observers")
  }

  // MARK: Why it stopped

  func testAUserStopIsToldApartFromAFailure() throws {
    let (_, controller, feed) = try harness("stop-requested")
    let ready = expectation(description: "Started")
    ready.assertForOverFulfill = false
    let stopped = expectation(description: "Stopped")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.stopped {
        XCTAssertEqual(update.stopCause, .requested)
        stopped.fulfill()
      }
    }
    start(controller, feed)
    wait(for: [ready], timeout: 1)
    controller.stop()
    wait(for: [stopped], timeout: 2)
    controller.onUpdate = nil
  }

  func testAFailureSaysWhy() throws {
    let (source, controller, feed) = try harness("stop-failed")
    let ready = expectation(description: "Started")
    ready.assertForOverFulfill = false
    let stopped = expectation(description: "Stopped")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.stopped {
        XCTAssertEqual(update.stopCause, .failed("The capture device stopped responding."))
        stopped.fulfill()
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    start(controller, feed)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.fatal("The capture device stopped responding."))))
    wait(for: [stopped], timeout: 2)
  }

  // MARK: Publishing it

  func testEachTransitionPublishes() throws {
    let (source, controller, feed) = try harness("signal-transitions")
    let buffer = try image()
    let seen = SignalLog()
    let waiting = expectation(description: "Waiting first")
    waiting.assertForOverFulfill = false
    let live = expectation(description: "Live with the first frame")
    live.assertForOverFulfill = false
    let lost = expectation(description: "Lost on the source's report, with no barrier behind it")
    lost.assertForOverFulfill = false
    let back = expectation(description: "Live again with the next frame")
    back.assertForOverFulfill = false
    controller.onUpdate = { update in
      let (count, wasLost) = seen.note(update.signal)
      switch update.signal {
      case .waiting: if count == 1 { waiting.fulfill() }
      case .live: if wasLost { back.fulfill() } else { live.fulfill() }
      case .lost: lost.fulfill()
      case .unsupported: XCTFail("Nothing unsupported here")
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    start(controller, feed)
    wait(for: [waiting], timeout: 1)
    frame(0, source, buffer)
    frame(1, source, buffer)
    wait(for: [live], timeout: 1)
    XCTAssertTrue(source.submit(.event(.signalLost(reason: "No HDMI video signal"))))
    wait(for: [lost], timeout: 1)
    frame(5, source, buffer)
    wait(for: [back], timeout: 1)
  }

  /// A format doesn't make a camera live: declared before its first frame, it's still waiting.
  func testNoSignalBeforeTheFirstFrameIsAReportedLoss() throws {
    let (source, controller, feed) = try harness("signal-never")
    let ready = expectation(description: "Started")
    ready.assertForOverFulfill = false
    let lost = expectation(description: "No signal reported")
    lost.assertForOverFulfill = false
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") {
        XCTAssertEqual(update.signal, .waiting)
        ready.fulfill()
      }
      if case .lost = update.signal {
        XCTAssertEqual(update.frames, 0, "Never had a picture: setup advice, not a dropout")
        XCTAssertEqual(update.signalDropouts, 0)
        lost.fulfill()
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    start(controller, feed)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.signalLost(reason: "No HDMI video signal"))))
    wait(for: [lost], timeout: 1)
  }

  func testUnsupportedInputIsTyped() throws {
    let (source, controller, feed) = try harness("signal-unsupported")
    let ready = expectation(description: "Started")
    ready.assertForOverFulfill = false
    let unsupported = expectation(description: "Unsupported")
    unsupported.assertForOverFulfill = false
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.signal == .unsupported("1080i") { unsupported.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    start(controller, feed)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.unsupportedInput("1080i"))))
    wait(for: [unsupported], timeout: 1)
  }

  /// The watchdog path: frames just stop, with no report. The loss dates from the
  /// last frame, and is the same dropout to everything that counts them.
  func testFramesStoppingWithNoReportIsALoss() throws {
    let (source, controller, feed) = try harness("signal-watchdog")
    let buffer = try image()
    let ready = expectation(description: "Started")
    ready.assertForOverFulfill = false
    let live = expectation(description: "Live")
    live.assertForOverFulfill = false
    let lost = expectation(description: "Watchdog reported the loss")
    lost.assertForOverFulfill = false
    let sentAt = SignalLog()
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.signal == .live { live.fulfill() }
      if case .lost(let since) = update.signal {
        XCTAssertEqual(since, sentAt.time, accuracy: 0.5, "From the last frame, not from when the watchdog noticed")
        XCTAssertEqual(update.signalDropouts, 1)
        lost.fulfill()
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    start(controller, feed)
    wait(for: [ready], timeout: 1)
    frame(0, source, buffer)
    sentAt.time = ProcessInfo.processInfo.systemUptime
    wait(for: [live], timeout: 1)
    wait(for: [lost], timeout: 6)
  }

  func testResumedFrameRetiresQueuedWatchdogTimeout() throws {
    let (source, controller, feed) = try harness("signal-watchdog-resumed")
    let buffer = try image()
    let ready = expectation(description: "Started")
    ready.assertForOverFulfill = false
    let live = expectation(description: "Live")
    live.assertForOverFulfill = false
    let resumed = expectation(description: "Frame resumed after timeout snapshot")
    let resumedFrameDelivered = DispatchSemaphore(value: 0)
    let staleLoss = expectation(description: "Stale watchdog must not clear the resumed input")
    staleLoss.isInverted = true
    controller.onObservedFrame = { pts, _, _ in
      if pts == CMTime(value: 1, timescale: 25) { resumedFrameDelivered.signal() }
    }
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.signal == .live { live.fulfill() }
      if update.message == "No video signal — waiting for source." { staleLoss.fulfill() }
    }
    controller.setAuditHooksForTesting(CaptureController.AuditHooks(watchdogSignalTimeoutObserved: {
      let context = source.context
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: CMTime(value: 1, timescale: 25), duration: CMTime(value: 1, timescale: 25),
        signalValid: true, timecode: nil)
      XCTAssertTrue(source.submit(.frame(buffer, info)))
      XCTAssertEqual(resumedFrameDelivered.wait(timeout: .now() + 1), .success)
      resumed.fulfill()
    }))
    defer { controller.onUpdate = nil; controller.stop() }
    start(controller, feed)
    wait(for: [ready], timeout: 1)
    frame(0, source, buffer)
    wait(for: [live], timeout: 1)
    wait(for: [resumed], timeout: 6)
    // Synchronize with capture work, including the watchdog action queued after
    // the hook's resumed frame delivery, before checking its publication.
    _ = controller.gpuPreparedForTesting
    wait(for: [staleLoss], timeout: 0.1)
  }

  func testFrameAfterWatchdogClaimKeepsItsSourceClockBaseline() throws {
    let (source, controller, feed) = try harness("signal-watchdog-claimed")
    let buffer = try image()
    let ready = expectation(description: "Started")
    ready.assertForOverFulfill = false
    let live = expectation(description: "Live")
    live.assertForOverFulfill = false
    let claimed = expectation(description: "Watchdog claimed timeout")
    let received = DispatchSemaphore(value: 0)
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.signal == .live { live.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    start(controller, feed)
    wait(for: [ready], timeout: 1)
    frame(0, source, buffer)
    wait(for: [live], timeout: 1)
    controller.setAuditHooksForTesting(CaptureController.AuditHooks(watchdogSignalTimeoutClaimed: {
      let context = source.context
      // Resume after the timeout claim but before capture-side signal clearing.
      // The second frame skips one source interval and establishes a baseline
      // that must survive the remainder of timeout handling.
      for index: Int64 in [1, 3] {
        let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
          presentationTime: CMTime(value: index, timescale: 25), duration: CMTime(value: 1, timescale: 25),
          signalValid: true, timecode: nil)
        XCTAssertTrue(source.submit(.frame(buffer, info)))
      }
      XCTAssertEqual(received.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(received.wait(timeout: .now() + 1), .success)
      claimed.fulfill()
    }, sourceFrameReceived: { received.signal() }))
    wait(for: [claimed], timeout: 6)
    _ = controller.gpuPreparedForTesting
    // A second one-frame skip must still compare with frame 3, even though
    // watchdog cleanup ran after that frame arrived on the driver thread.
    frame(5, source, buffer)
    XCTAssertEqual(received.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(controller.sourceDropsForTesting, 2)
  }
}
#endif
