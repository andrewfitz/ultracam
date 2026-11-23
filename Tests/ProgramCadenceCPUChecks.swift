import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import XCTest

@objcMembers final class ProgramCadenceCPUChecks: XCTestCase {
  func testCadenceRefusesSpanBeyondFixedProgramClock() throws {
    let id = FeedID(rawValue: "long-running")
    let route = ProgramOutputRoute(feedIDs: [id])
    let consumer = try route.addConsumerRoute()
    let image = try cadenceImage()
    let duration = CMTime(value: 1, timescale: 60)
    let pixel = CVPixelBufferGetPixelFormatType(image)
    route.setOutput(contract: .init(width: 2, height: 2, pixelFormat: pixel, duration: duration), active: true)
    for ticks in [Int64(0), Int64.max - 1] {
      route.ingest(feedID: id, frame: ProcessedFrame(payload: image, metadata: .init(
        presentationTime: CMTime(value: ticks, timescale: 240_000), duration: duration,
        width: 2, height: 2, pixelFormat: pixel)))
    }
    XCTAssertEqual(consumer.pendingCount, 1)
    XCTAssertEqual(route.statistics.accepted, 2)
    XCTAssertEqual(route.statistics.cadenceSkipped, 1)
  }

  func testMonitorStartsNewGenerationWhenProgramSelectionOrTimelineChanges() throws {
    let a = FeedID(rawValue: "a"), b = FeedID(rawValue: "b"), other = FeedID(rawValue: "other")
    let route = ProgramOutputRoute(feedIDs: [a, b, other])
    let image = try cadenceImage()
    let pixel = CVPixelBufferGetPixelFormatType(image)
    var boundaries: [Bool] = []
    route.onMonitorFrame = { _, _, _, _, boundary in boundaries.append(boundary) }
    func send(_ id: FeedID, at ticks: Int64) {
      route.ingest(feedID: id, frame: ProcessedFrame(payload: image, metadata: .init(
        presentationTime: CMTime(value: ticks, timescale: 60), duration: CMTime(value: 1, timescale: 60),
        width: 2, height: 2, pixelFormat: pixel)))
    }

    send(a, at: 100)
    route.updateFeeds([a, b])
    send(a, at: 101)
    route.updateFeeds([b])
    send(b, at: 1)
    send(b, at: 2)
    route.reset()
    send(b, at: 0)

    XCTAssertEqual(boundaries, [false, false, true, false, true])
  }

  func testNewProgramTimelineRearmsOutputFailureReporting() throws {
    let id = FeedID(rawValue: "invalid-timing")
    let route = ProgramOutputRoute(feedIDs: [id])
    let errors = Mutex(0)
    route.onEvent = { event in
      if case .outputError = event { errors.withLock { $0 += 1 } }
    }
    let image = try cadenceImage()
    let invalid = ProcessedFrame(payload: image, metadata: .init(
      presentationTime: .invalid, duration: CMTime(value: 1, timescale: 60),
      width: 2, height: 2, pixelFormat: CVPixelBufferGetPixelFormatType(image)))
    func failTiming() {
      for _ in 0..<ProgramOutputRoute.onAirSkipReportThreshold {
        route.ingest(feedID: id, frame: invalid)
      }
    }

    failTiming()
    route.setOutput(contract: nil, active: true)
    failTiming()
    XCTAssertEqual(errors.withLock { $0 }, 1)
    route.reset()
    failTiming()
    XCTAssertEqual(errors.withLock { $0 }, 2)
  }

  func testUHD60ConversionBacklogSkipsSupersededPicturesAndPreservesCutBoundaries() throws {
    let contract = ProgramOutputFormat(width: 3840, height: 2160,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: FrameRateTarget.fps60.duration)
    let outputImage = try cadenceImage(width: contract.width, height: contract.height)
    let inputs = try (0..<20).map { _ in try cadenceImage() }
    // Conversion resumes either before the first cut deadline or after it has passed.
    // All source pictures are unexpired; playout still skips obsolete work.
    for (shortCut, firstCompletion) in [(false, 8), (true, 8), (true, 3)] {
      let clock = StreamClockFixture(), origin = clock.now
      let ids = inputs.map(ObjectIdentifier.init)
      let submissions = Mutex<[ObjectIdentifier]>([])
      let conversion = StreamConversionFixture { image in submissions.withLock { $0.append(ObjectIdentifier(image)) } }
      let stream = ProgramStreamVideo(contract: contract, normalizer: conversion, black: outputImage,
        send: { sample, fresh in clock.accept(sample, live: fresh) }, hostNow: { clock.now })
      defer { stream.stop() }
      for wall in inputs.indices {
        let slot = CMTime(value: Int64(wall), timescale: 60)
        clock.advance(toTime: origin + slot)
        let feed = FeedID(rawValue: shortCut && wall == 2 ? "B" : "A")
        let frame = ProcessedFrame(payload: inputs[wall], metadata: .init(presentationTime: slot,
          duration: contract.duration, width: 2, height: 2, pixelFormat: contract.pixelFormat, captureHostTime: clock.now))
        stream.offer(frame, feedID: feed, programTime: slot, repeatWindow: .seconds(2))
        if wall >= firstCompletion { conversion.finish(outputImage) }
        stream.tickForTesting()
        if clock.lastLive { XCTAssertEqual(clock.deliveredFeed, shortCut && wall - 4 == 2 ? "B" : "A") }
        if shortCut && firstCompletion == 3 && wall == 6 {
          XCTAssertTrue(clock.lastLive)
          XCTAssertEqual(clock.deliveredFeed, "B", "A future one-frame cut retains its conversion slot")
        }
      }
      let jobs = submissions.withLock { $0.compactMap(ids.firstIndex(of:)) }
      if firstCompletion == 3 {
        XCTAssertEqual(jobs, Array(0...17), "Every cut still inside the playout window is processed in order")
        XCTAssertEqual(stream.droppedFrames, 0)
      } else {
        XCTAssertEqual(jobs, [0] + Array(3...14), "Skip jobs whose last deadline passed, including pictures from obsolete cuts")
        XCTAssertEqual(stream.droppedFrames, 2)
      }
    }
  }

  func testStreamOnlyCutsSurviveCMIODemandChangesAndEmitBlackAfterSignalLoss() throws {
    let time = StreamClockFixture()
    let imageA = try cadenceImage(), imageB = try cadenceImage(), black = try cadenceImage()
    let a = FeedID(rawValue: "a"), b = FeedID(rawValue: "b")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    let duration = CMTime(value: 1, timescale: 30)
    let contract = ProgramOutputFormat(width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: duration)
    let stream = ProgramStreamVideo(contract: contract, normalizer: StreamConversionFixture(), black: black, playoutFrames: 0,
      send: { sample, live in time.accept(sample, live: live) }, hostNow: { time.now })
    defer { stream.stop() }
    route.setStreamSink(stream)
    route.setOutput(contract: nil, active: false)
    func offer(_ id: FeedID, _ image: CVPixelBuffer, index: Int64) {
      let frame = ProcessedFrame(payload: image, metadata: ProcessedFrameMetadata(
        presentationTime: CMTime(value: index, timescale: 30), duration: duration,
        width: 2, height: 2, pixelFormat: contract.pixelFormat))
      route.ingest(feedID: id, frame: frame)
    }
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === black)
    XCTAssertFalse(time.lastLive)
    time.advance(to: 1)
    offer(a, imageA, index: 0)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === imageA)
    XCTAssertTrue(time.lastLive)
    time.advance(to: 2)
    route.setOutput(contract: contract, active: true)
    _ = route.requestSelection(b)
    offer(b, imageB, index: 0)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === imageB)
    route.setOutput(contract: nil, active: false)
    time.advance(to: 3)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === imageB)
    time.advance(to: 90)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === black)
    XCTAssertFalse(time.lastLive)
    XCTAssertEqual(stream.droppedFrames, 86, "Missed slots skip directly to the live edge")
    time.advance(to: 91)
    offer(b, imageB, index: 90)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === imageB)
    XCTAssertEqual(time.deliveredSlots, [0, 1, 2, 3, 90, 91])
    route.updateFeeds([a])
    time.advance(to: 92)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === black)
  }

  func testStreamHoldsStalePictureUntilRepeatWindowAndKeepsSlowSourceFresh() throws {
    let image = try cadenceImage(), replacement = try cadenceImage(), black = try cadenceImage()
    let id = FeedID(rawValue: "source")
    let contract = ProgramOutputFormat(width: 2, height: 2,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: CMTime(value: 1, timescale: 30))
    let cases: [(CMTime, Int64, Int64)] = [
      (CMTime(value: 1, timescale: 24), 22, 23), (CMTime(value: 1, timescale: 1), 30, 31)
    ]
    for (sourceDuration, freshSlot, staleSlot) in cases {
      let clock = StreamClockFixture()
      let stream = ProgramStreamVideo(contract: contract, normalizer: StreamConversionFixture(), black: black,
        playoutFrames: 0, send: { sample, live in clock.accept(sample, live: live) }, hostNow: { clock.now })
      defer { stream.stop() }
      func offer(_ picture: CVPixelBuffer, slot: Int64) {
        let pts = CMTime(value: slot, timescale: 30)
        stream.offer(ProcessedFrame(payload: picture, metadata: .init(presentationTime: pts, duration: sourceDuration,
          width: 2, height: 2, pixelFormat: contract.pixelFormat, captureHostTime: clock.now)),
          feedID: id, programTime: pts, repeatWindow: .seconds(2))
      }
      offer(image, slot: 0)
      stream.tickForTesting()
      clock.advance(to: freshSlot)
      stream.tickForTesting()
      XCTAssertTrue(clock.lastLive, "Normal repeats and an explicitly slow source remain fresh")
      clock.advance(to: staleSlot)
      stream.tickForTesting()
      XCTAssertFalse(clock.lastLive, "Repeating the old pixels cannot keep Program on-air")
      XCTAssertTrue(clock.lastImage === image, "The bounded repeat policy still holds the picture")
      clock.advance(to: 61)
      stream.tickForTesting()
      XCTAssertTrue(clock.lastImage === black)
      clock.advance(to: 62)
      offer(replacement, slot: 62)
      stream.tickForTesting()
      XCTAssertTrue(clock.lastLive)
      XCTAssertTrue(clock.lastImage === replacement)
    }
  }

  /// The virtual camera and publisher consume different canvases and clocks from one Program.
  /// Alternating buffer identities prove each 60 Hz source picture survives the camera's 24 Hz gate.
  func testUHD60StreamRetainsEverySourcePictureAlongside720p24VirtualCamera() throws {
    let clock = StreamClockFixture()
    let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let uhd = ProgramOutputFormat(width: 3840, height: 2160, pixelFormat: format, duration: FrameRateTarget.fps60.duration)
    let hd = ProgramOutputFormat(width: 1280, height: 720, pixelFormat: format, duration: FrameRateTarget.fps24.duration)
    let images = try [cadenceImage(width: uhd.width, height: uhd.height), cadenceImage(width: uhd.width, height: uhd.height)]
    let cameraImage = try cadenceImage(width: hd.width, height: hd.height)
    let source = FeedID(rawValue: "uhd60")
    let route = ProgramOutputRoute(feedIDs: [source])
    let conversion = StreamConversionFixture()
    route.setNormalizerProvider { conversion }
    let camera = try route.addConsumerRoute()
    route.setOutput(contract: hd, active: true)
    let stream = ProgramStreamVideo(contract: uhd, normalizer: conversion, black: images[0], playoutFrames: 0,
      send: { sample, fresh in clock.accept(sample, live: fresh) }, hostNow: { clock.now })
    route.setStreamSink(stream)
    defer { stream.stop() }
    var cameraSlots = 0
    let origin = clock.now
    for index in 0..<60 {
      let time = CMTime(value: Int64(index), timescale: 60)
      clock.advance(toTime: origin + time)
      let image = images[index % images.count]
      route.ingest(feedID: source, frame: ProcessedFrame(payload: image, metadata: .init(presentationTime: time,
        duration: uhd.duration, width: uhd.width, height: uhd.height, pixelFormat: format, captureHostTime: clock.now)))
      conversion.finish(cameraImage)
      stream.tickForTesting()
      XCTAssertTrue(clock.lastLive)
      XCTAssertTrue(clock.lastImage === image, "Stream missed source picture \(index)")
      if let lease = camera.dequeue() {
        XCTAssertTrue(lease.payload === cameraImage)
        XCTAssertEqual(lease.metadata?.duration, hd.duration)
        cameraSlots += 1
        lease.release()
      }
    }
    XCTAssertEqual(cameraSlots, 24)
    XCTAssertEqual(clock.deliveredSlots.count, 60)
    XCTAssertEqual(stream.droppedFrames, 0)
  }

  func testStreamWakeJitterKeepsDueSlotsAndDoesNotPublishEarly() throws {
    let clock = StreamClockFixture()
    let contract = ProgramOutputFormat(width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      duration: CMTime(value: 1, timescale: 30))
    let stream = ProgramStreamVideo(contract: contract, normalizer: StreamConversionFixture(), black: try cadenceImage(),
      playoutFrames: 0, send: { sample, live in clock.accept(sample, live: live) }, hostNow: { clock.now })
    defer { stream.stop() }
    for milliseconds: Int64 in [0, 32, 52, 60, 66, 67, 84, 99, 100] {
      let before = clock.deliveredSlots.count
      clock.advance(milliseconds: milliseconds)
      stream.tickForTesting()
      if [32, 60, 66, 84, 99].contains(milliseconds) {
        XCTAssertEqual(clock.deliveredSlots.count, before, "Early wake at \(milliseconds) ms")
      }
    }
    XCTAssertEqual(clock.deliveredSlots, [0, 1, 2, 3])
    XCTAssertEqual(stream.droppedFrames, 0)
    clock.advance(milliseconds: 1_060)
    stream.tickForTesting()
    clock.advance(milliseconds: 1_067)
    stream.tickForTesting()
    XCTAssertEqual(clock.deliveredSlots, [0, 1, 2, 3, 31, 32])
    XCTAssertEqual(stream.droppedFrames, 27)
  }

  func testPassthroughRejectsAnAlternateColourProfileEvenWhenStandardTagsMatch() throws {
    let image = try cadenceImage()
    let contract = ProgramOutputFormat(width: 2, height: 2, pixelFormat: CVPixelBufferGetPixelFormatType(image),
      duration: CMTime(value: 1, timescale: 30))
    let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData())
    let alternateTags: [(CFString, CFTypeRef)] = [
      (kCVImageBufferICCProfileKey, profile),
      (kCVImageBufferGammaLevelKey, 2.4 as CFNumber),
    ]
    for (key, value) in alternateTags {
      XCTAssertTrue(contract.matchesColourAndAspect(image))
      CVBufferSetAttachment(image, key, value, .shouldPropagate)
      let sample = try VideoContract.sample(image, at: .zero, duration: contract.duration)
      let description = try XCTUnwrap(sample.formatDescription)
      XCTAssertNotNil(CMFormatDescriptionGetExtension(description, extensionKey: key))
      XCTAssertFalse(contract.matchesColourAndAspect(image))
      CVBufferRemoveAttachment(image, key)
    }
  }

  func testRealStreamTimerKeepsMediaCadenceWithoutIncomingFrames() throws {
    let clock = StreamClockFixture()
    let black = try cadenceImage()
    let contract = ProgramOutputFormat(width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      duration: CMTime(value: 1, timescale: 30))
    let reached = DispatchSemaphore(value: 0)
    let stream = ProgramStreamVideo(contract: contract, normalizer: StreamConversionFixture(), black: black,
      send: { sample, fresh in
        clock.accept(sample, live: fresh)
        if clock.deliveredSlots.count == 31 { reached.signal() }
      })
    stream.start()
    defer { stream.stop() }
    XCTAssertEqual(reached.wait(timeout: .now() + 2), .success, "Background timer coalescing must not cut the stream to 10 fps")
    let slots = clock.deliveredSlots
    if let first = slots.first, let last = slots.last {
      XCTAssertLessThanOrEqual(last - first, 36, "Thirty real media intervals should take about one second")
    }
  }

  func testStreamPresentsCaptureContentAtItsHostSlotAcrossCutsAndVariableRenderDelay() throws {
    let clock = StreamClockFixture()
    let black = try cadenceImage()
    let images = try (0..<16).map { _ in try cadenceImage() }
    let a = FeedID(rawValue: "first"), b = FeedID(rawValue: "second")
    let route = ProgramOutputRoute(feedIDs: [a, b])
    let contract = ProgramOutputFormat(width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      duration: CMTime(value: 1, timescale: 30))
    let stream = ProgramStreamVideo(contract: contract, normalizer: StreamConversionFixture(), black: black,
      send: { sample, fresh in clock.accept(sample, live: fresh) }, hostNow: { clock.now })
    defer { stream.stop() }
    route.setOutput(contract: nil, active: false)
    route.setStreamSink(stream)
    // A camera frame and its paired audio pulse share capture time. Varying GPU delays
    // produce burst delivery; the encoder must receive each image at the matching PCM slot.
    let delays = [1, 2, 3, 2, 1, 1, 2, 3, 2, 1, 2, 3, 2, 1, 1, 2]
    for wall in 0..<(images.count + 4) {
      clock.advance(to: Int64(wall))
      for index in images.indices where index + delays[index] == wall {
        if index == 8 { _ = route.requestSelection(b) }
        let host = CMTime(value: Int64(300 + index), timescale: 30)
        let pts = CMTime(value: Int64(index % 8), timescale: 30)
        route.ingest(feedID: index < 8 ? a : b, frame: ProcessedFrame(payload: images[index],
          metadata: ProcessedFrameMetadata(presentationTime: pts, duration: contract.duration,
            width: 2, height: 2, pixelFormat: contract.pixelFormat, captureHostTime: host)))
      }
      stream.tickForTesting()
      let index = wall - 4
      XCTAssertEqual(clock.deliveredSlots.last, Int64(index))
      if index >= 0 {
        XCTAssertTrue(clock.lastImage === images[index], "Wrong picture at capture/PCM slot \(index)")
        XCTAssertEqual(clock.deliveredFeed, index < 8 ? a.rawValue : b.rawValue)
        XCTAssertTrue(clock.lastLive)
      } else {
        XCTAssertTrue(clock.lastImage === black)
        XCTAssertNil(clock.deliveredFeed)
      }
    }
    XCTAssertEqual(stream.droppedFrames, 0)
  }

  func testStreamConversionRetiresOldCutAndIgnoresLateCompletionAfterStop() throws {
    let time = StreamClockFixture(), conversion = StreamConversionFixture()
    let black = try cadenceImage(), converted = try cadenceImage()
    let a = FeedID(rawValue: "a"), b = FeedID(rawValue: "b")
    let contract = ProgramOutputFormat(width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      duration: CMTime(value: 1, timescale: 30))
    let stream = ProgramStreamVideo(contract: contract, normalizer: conversion, black: black, playoutFrames: 0,
      send: { sample, live in time.accept(sample, live: live) }, hostNow: { time.now })
    var source: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &source), kCVReturnSuccess)
    let frame = ProcessedFrame(payload: try XCTUnwrap(source), metadata: ProcessedFrameMetadata(presentationTime: .zero,
      duration: contract.duration, width: 4, height: 4, pixelFormat: kCVPixelFormatType_32BGRA))
    stream.offer(frame, feedID: a, programTime: .zero, repeatWindow: .seconds(2))
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === black)
    time.advance(to: 1)
    stream.offer(frame, feedID: b, programTime: contract.duration, repeatWindow: .seconds(2))
    conversion.finish(converted)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === black, "An old GPU completion must not cross a cut")
    conversion.finish(converted)
    time.advance(to: 2)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === converted)
    stream.offer(frame, feedID: a, programTime: CMTime(value: 2, timescale: 30), repeatWindow: .seconds(2))
    time.advance(to: 3)
    stream.tickForTesting()
    XCTAssertTrue(time.lastImage === converted, "A cut awaiting GPU conversion holds the last valid picture")
    XCTAssertFalse(time.lastLive, "The held image does not establish tally for the newly selected camera")
    stream.stop()
    conversion.finish(converted)
    time.advance(to: 4)
    stream.tickForTesting()
    XCTAssertEqual(time.deliveredSlots, [0, 1, 2, 3])
  }

  func testStreamPassthroughKeepsProducerThroughSampleAndAsynchronousEncoderOwnership() throws {
    struct Sample: @unchecked Sendable { let buffer: CMSampleBuffer }
    let clock = StreamClockFixture()
    let image = try cadenceImage(), black = try cadenceImage()
    let released = Mutex(0)
    let sent = Mutex<[Sample]>([])
    let duration = CMTime(value: 1, timescale: 30)
    let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let contract = ProgramOutputFormat(width: 2, height: 2, pixelFormat: pixelFormat, duration: duration)
    let stream = ProgramStreamVideo(contract: contract, normalizer: StreamConversionFixture(), black: black,
      playoutFrames: 0, send: { sample, _ in sent.withLock { $0.append(Sample(buffer: sample)) } }, hostNow: { clock.now })
    defer { stream.stop() }
    let feed = FeedID(rawValue: "producer")
    let metadata = ProcessedFrameMetadata(presentationTime: .zero, duration: duration,
      width: 2, height: 2, pixelFormat: pixelFormat)
    stream.offer(ProcessedFrame(payload: image, metadata: metadata,
      onReleased: { released.withLock { $0 += 1 } }), feedID: feed, programTime: .zero, repeatWindow: .seconds(2))
    stream.tickForTesting()
    clock.advance(to: 1)
    stream.offer(ProcessedFrame(payload: black, metadata: metadata), feedID: feed, programTime: duration, repeatWindow: .seconds(2))
    stream.tickForTesting()
    stream.stop()
    XCTAssertEqual(released.withLock { $0 }, 0, "The first sample outlives the renderer's held picture")
    var encoderOwner = sent.withLock { samples in
      XCTAssertNil(samples.last?.buffer.retainedImageFrame, "An owned pool buffer needs no separate producer lease")
      return samples.first?.buffer.retainedImageFrame
    }
    sent.withLock { $0.removeAll() }
    XCTAssertTrue(encoderOwner?.payload === image)
    XCTAssertEqual(released.withLock { $0 }, 0)
    encoderOwner = nil
    XCTAssertEqual(released.withLock { $0 }, 1, "The source retires exactly once when the encoder releases it")
  }

  func testLowRateSchedulesAreCompactAndPacedAt60And120Hz() throws {
    for rate in [60, 120] {
      for seconds in [1, 2] {
        let rig = try CadenceRig(rate: rate)
        rig.send(index: 0, duration: CMTime(value: Int64(seconds), timescale: 1))
        rig.bridge.waitUntilIdle()
        XCTAssertEqual(rig.sent.count, 1, "The initial frame cannot burst its whole repeat window into CMIO")
        XCTAssertEqual(rig.route.statistics.overflowRejected, 0)
        XCTAssertEqual(rig.route.statistics.published, UInt64(seconds * rate))
        XCTAssertEqual(rig.route.stageAllocationSnapshot.allocations, 1)
        for index in 1..<(seconds * rate) { rig.advance(to: Double(index) / Double(rate)) }
        XCTAssertEqual(rig.sent.count, seconds * rate)
        XCTAssertEqual(rig.bridge.currentStatistics.dropped, 0)
        XCTAssertEqual(rig.bridge.currentStatistics.clockSkipped, 0)
        XCTAssertEqual(rig.bridge.currentStatistics.clockRepeated, 0)
        for (index, time) in rig.sent.enumerated() { XCTAssertEqual(time, Double(index) / Double(rate), accuracy: 1e-8) }
        XCTAssertLessThanOrEqual(rig.consumer.pendingCount, 1)
        XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 1, "The schedule stays charged through the final paced send")
        XCTAssertEqual(rig.route.stageRetentionSnapshot.currentDuration, Double(seconds), accuracy: 1e-12,
          "One low-rate image uses the explicit minimum-slot exception, not a globally enlarged time budget")
        rig.bridge.disconnect()
        XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 0)
      }
    }
  }

  func testHostGridBoundsTenMinutesOfPositiveAndNegativeClockDrift() throws {
    for speed in [1.001, 0.999] {
      let rate = 60
      let rig = try CadenceRig(rate: rate)
      let samples = Int(600 * Double(rate) * speed)
      for index in 0..<samples {
        let arrival = Double(index) / (Double(rate) * speed)
        rig.advance(to: arrival)
        rig.send(index: index)
        rig.bridge.waitUntilIdle()
      }
      rig.advance(to: 600 - 1 / Double(rate))
      XCTAssertGreaterThan(rig.sent.count, 35_990)
      XCTAssertEqual(rig.route.statistics.overflowRejected, 0)
      XCTAssertEqual(rig.bridge.currentStatistics.dropped, 0)
      for index in 1..<rig.sent.count {
        XCTAssertEqual(rig.sent[index] - rig.sent[index - 1], 1 / Double(rate), accuracy: 1e-8)
      }
      XCTAssertLessThanOrEqual(rig.maximumLead, 1 / Double(rate) + 1e-8)
      if speed > 1 { XCTAssertGreaterThan(rig.bridge.currentStatistics.clockSkipped, 25) }
      else { XCTAssertGreaterThan(rig.bridge.currentStatistics.clockRepeated, 25) }
      rig.bridge.disconnect()
      XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 0)
    }
  }

  func testResetAndTopologyChangesFenceTheCurrentRepeatSchedule() throws {
    for topologyChange in [false, true] {
      let rig = try CadenceRig(rate: 60)
      rig.send(index: 0, duration: CMTime(value: 2, timescale: 1))
      rig.bridge.waitUntilIdle()
      XCTAssertEqual(rig.sent.count, 1)
      if topologyChange { rig.route.updateFeeds([FeedID(rawValue: "replacement")]) }
      else { rig.route.reset() }
      rig.advance(to: 0.5)
      XCTAssertEqual(rig.sent.count, 1, "Retired source images must not survive an output generation change")
      XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 0)
      XCTAssertEqual(rig.route.stageAllocationSnapshot.bytes, 0)
      rig.bridge.disconnect()
    }
  }

  func testMissedWakeConsumesScheduleAndExpiredImageCannotResume() throws {
    let rig = try CadenceRig(rate: 60)
    rig.send(index: 0, duration: CMTime(value: 2, timescale: 1))
    rig.bridge.waitUntilIdle()
    rig.jump(to: 1)
    rig.advance(to: 119.0 / 60)
    XCTAssertEqual(rig.sent.count, 61)
    XCTAssertEqual(rig.bridge.currentStatistics.clockSkipped, 59)
    XCTAssertEqual(rig.sent[1], 1, accuracy: 1e-8)
    rig.bridge.disconnect()

    let expired = try CadenceRig(rate: 60)
    expired.send(index: 0, duration: CMTime(value: 2, timescale: 1))
    expired.bridge.waitUntilIdle()
    expired.jump(to: 5)
    expired.advance(to: 6)
    XCTAssertEqual(expired.sent.count, 1, "A queued two-second schedule expires even with repeats remaining")
    XCTAssertEqual(expired.bridge.currentStatistics.clockSkipped, 119)
    XCTAssertEqual(expired.bridge.currentStatistics.pacingDiscontinuities, 1)
    XCTAssertEqual(expired.route.stageAllocationSnapshot.bytes, 0)
    expired.bridge.disconnect()
  }

  func testMissedWakeBetweenSlotsWaitsForTheNextDeadline() throws {
    let rig = try CadenceRig(rate: 60)
    rig.send(index: 0, duration: CMTime(value: 2, timescale: 1))
    rig.bridge.waitUntilIdle()
    rig.jump(to: 60.5 / 60)
    XCTAssertEqual(rig.sent.count, 1)
    rig.advance(to: 61.0 / 60)
    XCTAssertEqual(rig.sent.count, 2)
    XCTAssertEqual(rig.sent.last ?? -1, 61.0 / 60, accuracy: 1e-8)
    XCTAssertEqual(rig.bridge.currentStatistics.clockSkipped, 60)
    rig.bridge.disconnect()
  }

  func testMissedWakeExactlyOnGridStillSendsThatSlot() throws {
    let rig = try CadenceRig(rate: 60)
    defer { rig.bridge.disconnect() }
    rig.send(index: 0, duration: CMTime(value: 2, timescale: 1))
    rig.bridge.waitUntilIdle()
    rig.jump(to: 24.0 / 60)
    XCTAssertEqual(rig.sent.count, 2)
    XCTAssertEqual(rig.sent.last ?? -1, 24.0 / 60, accuracy: 1e-8)
    XCTAssertEqual(rig.bridge.currentStatistics.clockSkipped, 23)
  }

  func testMissedWakeDrivenByPumpStillSchedulesTheNextDeadline() throws {
    let rig = try CadenceRig(rate: 60)
    defer { rig.bridge.disconnect() }
    rig.send(index: 0, duration: CMTime(value: 2, timescale: 1))
    rig.bridge.waitUntilIdle()
    rig.jump(to: 1.0 / 60, deliversWake: false)
    rig.bridge.pump()
    XCTAssertEqual(rig.sent.count, 2)
    rig.jump(to: 2.0 / 60)
    XCTAssertEqual(rig.sent.count, 3)
    XCTAssertEqual(rig.sent.last ?? -1, 2.0 / 60, accuracy: 1e-8)
  }

  func testPendingMediaTimeIsBoundedEquallyAt25And120Hz() throws {
    for rate in [25, 120] {
      let image = try cadenceImage()
      let route = ProgramOutputRoute(feedIDs: [FeedID(rawValue: "held")])
      let consumer = try route.addConsumerRoute(capacity: 128, compactRepeats: true)
      for index in 0..<(rate / 2) {
        route.ingest(feedID: FeedID(rawValue: "held"), frame: ProcessedFrame(payload: image,
          metadata: ProcessedFrameMetadata(presentationTime: CMTime(value: Int64(index), timescale: Int32(rate)),
            duration: CMTime(value: 1, timescale: Int32(rate)), width: 2, height: 2,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
      }
      XCTAssertEqual(consumer.pendingCount, Int(0.4 * Double(rate)))
      XCTAssertEqual(route.stageRetentionSnapshot.currentDuration, 0.4, accuracy: 1e-12)
      XCTAssertEqual(route.stageAllocationSnapshot.allocations, 1, "Repeated ownership of one backing is physically charged once")
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, try ProgramOutputRoute.storageBytes(image))
      route.reset()
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 0)
    }
  }

  func testFanoutAndInFlightOwnersRemainByteAndTimeCharged() throws {
    for rate in [25, 120] {
      let image = try cadenceImage()
      let bytes = try ProgramOutputRoute.storageBytes(image)
      let budget = try MediaRetentionPolicy(maximumBytes: bytes * 3, maximumDuration: 0.4, maximumSlots: 256, minimumSlots: 2)
      let id = FeedID(rawValue: "held")
      let route = ProgramOutputRoute(feedIDs: [id], retentionPolicy: budget)
      let consumer = try route.addConsumerRoute(capacity: 128, compactRepeats: true)
      let step = CMTime(value: 1, timescale: Int32(rate))
      route.setOutput(contract: ProgramOutputFormat(width: 2, height: 2,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: step), active: true)
      for index in 0..<10 {
        let payload = index == 0 ? image : try cadenceImage()
        route.ingest(feedID: id, frame: ProcessedFrame(payload: payload, metadata: ProcessedFrameMetadata(
          presentationTime: CMTime(value: Int64(index), timescale: Int32(rate)), duration: step,
          width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
      }
      XCTAssertEqual(consumer.pendingCount, 3)
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 3)
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, bytes * 3)
      XCTAssertGreaterThan(route.statistics.overflowRejected, 0)
      let inFlight = try XCTUnwrap(consumer.dequeue())
      route.reset()
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, bytes, "Reset only releases pending leases; an in-flight send still owns its surface")
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 1)
      inFlight.release()
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, 0)
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 0)
    }
  }
}

private func cadenceImage(width: Int = 2, height: Int = 2) throws -> CVPixelBuffer {
  var image: CVPixelBuffer?
  guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess, let image else {
    throw VideoError.message("CPU timing fixture allocation failed")
  }
  try ProgramOutputFormat(width: width, height: height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    duration: CMTime(value: 1, timescale: 60)).stampColour(on: image)
  return image
}

private final class CadenceRig: @unchecked Sendable {
  let route: ProgramOutputRoute
  let consumer: FrameRoute<CVPixelBuffer>
  let image: CVPixelBuffer
  let rate: Int
  var bridge: ProgramOutputBridge!
  private let lock = NSLock()
  private var time = 0.0
  private var wakes: [(Double, @Sendable () -> Void)] = []
  private var timestamps: [Double] = []
  private var lead = 0.0
  var sent: [Double] { lock.withLock { timestamps } }
  var maximumLead: Double { lock.withLock { lead } }
  init(rate: Int) throws {
    self.rate = rate
    image = try cadenceImage()
    route = ProgramOutputRoute(feedIDs: [FeedID(rawValue: "paced")])
    let baseline = ProcessInfo.processInfo.environment["ULTRACAM_CADENCE_BASELINE"] == "1"
    consumer = try route.addConsumerRoute(capacity: ProgramOutputRoute.consumerCapacity, compactRepeats: !baseline)
    bridge = ProgramOutputBridge(route: consumer, connect: { _, _ in }, disconnect: {}, send: { [weak self] sample in
      guard let self else { return false }
      self.lock.withLock {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        self.timestamps.append(pts)
        self.lead = max(self.lead, pts - self.time)
      }
      return true
    }, hostClock: { [weak self] in
      let seconds = self?.lock.withLock { self?.time ?? 0 } ?? 0
      return CMTime(value: Int64((seconds * 240_000_000).rounded()), timescale: 240_000_000)
    },
      paced: !baseline, scheduleHostWake: { [weak self] deadline, callback in
        self?.lock.withLock { self?.wakes.append((deadline.seconds, callback)) }
      })
    route.onPublished = { [weak bridge] in bridge?.schedulePump() }
    bridge.onContractChange = { [weak route] contract in route?.setOutput(contract: contract, active: contract != nil) }
    bridge.enforceContract = true
    var configuration = PipelineConfiguration()
    configuration.downscale = false; configuration.convertTo420 = false
    configuration.sourceWidth = 2; configuration.sourceHeight = 2
    configuration.sourceDuration = CMTime(value: 1, timescale: Int32(rate))
    try bridge.setDemand(true, configuration: configuration, passthroughFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    bridge.waitUntilIdle()
  }
  func send(index: Int, duration: CMTime? = nil) {
    route.ingest(feedID: FeedID(rawValue: "paced"), frame: ProcessedFrame(payload: image,
      metadata: ProcessedFrameMetadata(presentationTime: CMTime(value: Int64(index), timescale: Int32(rate)),
        duration: duration ?? CMTime(value: 1, timescale: Int32(rate)), width: 2, height: 2,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
  }
  func jump(to target: Double, deliversWake: Bool = true) {
    let wake = lock.withLock { () -> (@Sendable () -> Void)? in
      time = target
      wakes.sort { $0.0 < $1.0 }
      guard let first = wakes.first, first.0 <= target else { return nil }
      wakes.removeFirst()
      return first.1
    }
    if deliversWake { wake?() }
    bridge.waitUntilIdle()
  }
  func advance(to target: Double) {
    var iterations = 0
    while true {
      iterations += 1
      precondition(iterations < 1000, "Pacer rescheduled an already due deadline at target \(target)")
      let wake = lock.withLock { () -> (@Sendable () -> Void)? in
        wakes.sort { $0.0 < $1.0 }
        guard let first = wakes.first, first.0 <= target + 1e-10 else { time = target; return nil }
        wakes.removeFirst(); time = first.0
        return first.1
      }
      guard let wake else { break }
      wake()
      bridge.waitUntilIdle()
    }
    bridge.pump()
  }
}

private final class StreamClockFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var time = CMTime(value: 300, timescale: 30)
  private var image: CVPixelBuffer?
  private var live = false
  private var slots: [Int64] = []
  private var feed: String?
  var deliveredFeed: String? { lock.withLock { feed } }
  var lastImage: CVPixelBuffer? { lock.withLock { image } }
  var lastLive: Bool { lock.withLock { live } }
  var deliveredSlots: [Int64] { lock.withLock { slots } }
  var now: CMTime { lock.withLock { time } }
  func advance(to slot: Int64) { lock.withLock { time = CMTime(value: slot + 300, timescale: 30) } }
  func advance(toTime time: CMTime) { lock.withLock { self.time = time } }
  func advance(milliseconds: Int64) { lock.withLock { time = CMTime(value: milliseconds + 10_000, timescale: 1_000) } }
  func accept(_ sample: CMSampleBuffer, live: Bool) {
    lock.withLock {
      image = sample.imageBuffer
      feed = CMGetAttachment(sample, key: "org.ultracam.program-stream.feed-id" as CFString, attachmentModeOut: nil) as? String
      self.live = live
      slots.append(CMTimeConvertScale(sample.presentationTimeStamp, timescale: 30, method: .roundHalfAwayFromZero).value - 300)
    }
  }
}

private final class StreamConversionFixture: ProgramFrameNormalizing, @unchecked Sendable {
  private let lock = NSLock()
  private let submitted: @Sendable (CVPixelBuffer) -> Void
  private var callback: (@Sendable (Result<CVPixelBuffer, Error>) -> Void)?
  init(submitted: @escaping @Sendable (CVPixelBuffer) -> Void = { _ in }) { self.submitted = submitted }
  func canNormalize(_ metadata: ProcessedFrameMetadata, to contract: ProgramOutputFormat) -> Bool { true }
  func normalize(_ source: CVPixelBuffer, to contract: ProgramOutputFormat,
                 completion: @escaping @Sendable (Result<CVPixelBuffer, Error>) -> Void) throws {
    submitted(source)
    lock.withLock { callback = completion }
  }
  func finish(_ image: CVPixelBuffer) {
    let completed = lock.withLock { let current = callback; callback = nil; return current }
    completed?(.success(image))
  }
}
