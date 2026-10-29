#if ULTRACAM_TEST_SUPPORT
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureTakeContextChecks: XCTestCase {
  private func format() throws -> SourceFormat {
    try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration))
  }
  private func image() throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &value), kCVReturnSuccess)
    return try XCTUnwrap(value)
  }
  private func emit(_ source: FakeCaptureSession, image: CVPixelBuffer, time: CMTime = .zero) {
    let context = source.context
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: image),
      CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: time, duration: VideoContract.fastDuration, signalValid: true, timecode: nil))))
  }

  private func clockContractRefusal(mappingDelay: UInt64 = 0, revisionOverride: UInt64? = nil,
    maximumEventSequence: Bool = false, sendFrame: Bool = false) throws -> (messages: [String], videoCalls: Int) {
    let source = TakeContextFixtureSession(format: try format(), audio: .absent,
      revisionOverride: revisionOverride, mappingDelay: mappingDelay, maximumEventSequence: maximumEventSequence)
    let feed = FeedID(rawValue: "clock-next-delivery-contract")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let observed = TakeContextObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in observed.video(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
      takeContext: { context in observed.context(context); return true }))
    let ready = expectation(description: "Clock contract source ready")
    let refused = expectation(description: "Invalid clock scheduling refused without media")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.stopped { observed.failure(update.message); refused.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let context = source.source.context
    let mapping = try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    XCTAssertTrue(source.source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: context.epochID,
      clockID: context.clockBindings.video, revision: 1, effectiveSequence: context.nextSequence + 1, mapping: mapping)))))
    if sendFrame { emit(source.source, image: try image()) }
    wait(for: [refused], timeout: 0.5)
    XCTAssertEqual(controller.retentionSnapshotForTesting.accepted, 0)
    source.stop()
    return (observed.failures, observed.videoCalls)
  }

  func testFutureEffectiveClockMappingIsExplicitlyRefusedByCurrentNextDeliveryContract() throws {
    let result = try clockContractRefusal(mappingDelay: 10)
    XCTAssertTrue(result.messages.first?.contains("next delivery") == true)
    XCTAssertEqual(result.videoCalls, 0)
  }

  func testNextDeliveryMustCarryTheDeclaredMappingRevisionBeforeRecordingMedia() throws {
    let result = try clockContractRefusal(revisionOverride: 0, sendFrame: true)
    XCTAssertTrue(result.messages.first?.contains("revision") == true)
    XCTAssertEqual(result.videoCalls, 0)
  }

  func testMaximumMappingEnvelopeSequenceRefusesWithoutOverflow() throws {
    let result = try clockContractRefusal(maximumEventSequence: true)
    XCTAssertTrue(result.messages.first?.contains("clock mapping") == true)
    XCTAssertEqual(result.videoCalls, 0)
  }

  func testClockEventDuringBindingIsJournaledBeforeFirstRecordingFrame() throws {
    let source = FakeCaptureSession(format: try format(), audio: .absent)
    let feed = FeedID(rawValue: "clock-during-context-binding")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Clock source ready")
    let declared = expectation(description: "Clock declarations ready")
    let eventSeen = expectation(description: "Clock event delivered while binder held")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "declaration barrier" { declared.fulfill() }
      if update.message == "clock barrier" { eventSeen.fulfill() }
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let installed = DispatchSemaphore(value: 0)
    defer { release.signal(); controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.info("declaration barrier"))))
    wait(for: [declared], timeout: 1)
    let observed = TakeContextObservation()
    DispatchQueue.global().async {
      controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
        video: { _, _, _, _ in observed.video(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
        takeContext: { context in
          observed.context(context)
          if observed.contexts.count == 1 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
          return true
        }, clockMapping: { event in observed.clock(event); return true }))
      installed.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    let context = source.context
    let mapping = try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    let update = CaptureClockMappingUpdate(epochID: context.epochID, clockID: context.clockBindings.video,
      revision: 4, effectiveSequence: context.nextSequence + 1, mapping: mapping)
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(update))))
    XCTAssertTrue(source.submit(.event(.info("clock barrier"))))
    wait(for: [eventSeen], timeout: 1)
    XCTAssertTrue(observed.mappingEvents.isEmpty, "Journal operations cannot precede initial context admission")
    release.signal()
    XCTAssertEqual(installed.wait(timeout: .now() + 1), .success)
    emit(source, image: try image())
    source.stop()
    XCTAssertEqual(observed.mappingEvents.count, 1)
    XCTAssertEqual(observed.mappingEvents.first?.clockID, update.clockID)
    XCTAssertEqual(observed.mappingEvents.first?.effectiveSequence, update.effectiveSequence)
    if let clock = observed.order.firstIndex(of: "mapping"), let video = observed.order.firstIndex(of: "video") { XCTAssertLessThan(clock, video) }
    else { XCTFail("The real clock event and first recording frame must both survive binding") }
  }

  func testPendingClockMetadataIsBoundedAndOverflowFailsTakeWithoutVideoLoss() throws {
    let source = FakeCaptureSession(format: try format(), audio: .absent)
    let feed = FeedID(rawValue: "pending-clock-metadata-overflow")
    let writer = TakeContextWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(fileURLWithPath: "/tmp/unused-context-overflow.mov"), width: 3840, height: 2160)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: core)
    try adapter.start()
    let actual = adapter.callbacks
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Overflow source ready")
    let declared = expectation(description: "Overflow declarations ready")
    let eventsSeen = expectation(description: "All clock events passed the held context")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "declaration barrier" { declared.fulfill() }
      if update.message == "clock overflow barrier" { eventsSeen.fulfill() }
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let installed = DispatchSemaphore(value: 0)
    defer { release.signal(); controller.onUpdate = nil; controller.stop(); try? adapter.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.info("declaration barrier"))))
    wait(for: [declared], timeout: 1)
    let observed = TakeContextObservation()
    DispatchQueue.global().async {
      var callbacks = actual
      callbacks.takeContext = { context in
        observed.context(context)
        if observed.contexts.count == 1 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        return actual.takeContext?(context) ?? false
      }
      callbacks.metadataFailure = { message in observed.failure(message); actual.metadataFailure?(message) }
      controller.setRecordingCallbacks(feedID: feed, callbacks: callbacks)
      installed.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    for revision in 1...65 {
      let context = source.context
      let mapping = try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: Int64(100 + revision), timescale: 1), rate: .one)
      XCTAssertTrue(source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: context.epochID,
        clockID: context.clockBindings.video, revision: UInt64(revision), effectiveSequence: context.nextSequence + 1, mapping: mapping)))))
    }
    XCTAssertTrue(source.submit(.event(.info("clock overflow barrier"))))
    wait(for: [eventsSeen], timeout: 1)
    XCTAssertEqual(observed.failures.count, 1)
    XCTAssertTrue(observed.failures.first?.contains("clock metadata") == true)
    release.signal()
    XCTAssertEqual(installed.wait(timeout: .now() + 1), .success)
    emit(source, image: try image())
    source.stop()
    try? adapter.stop()
    XCTAssertEqual(core.state, .failed)
    XCTAssertEqual(core.telemetry.enqueuedVideo, 0)
    XCTAssertEqual(core.telemetry.droppedVideo, 0)
    XCTAssertEqual(core.telemetry.droppedInvalidSample, 0)
    XCTAssertEqual(observed.contexts.count, 1)
  }

  func testRejectedTakeContextIsNotRetriedForEverySourceFrame() throws {
    let source = FakeCaptureSession(format: try format(), audio: .absent)
    let feed = FeedID(rawValue: "rejected-take-context")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let observed = TakeContextObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in observed.video(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
      takeContext: { context in observed.context(context); return false }))
    let ready = expectation(description: "Rejected take source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let buffer = try image()
    for index in 0..<5 { emit(source, image: buffer, time: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(index))) }
    source.stop()
    XCTAssertEqual(observed.contexts.count, 1, "A failed take must not create repeated metadata work on every frame")
    XCTAssertEqual(observed.videoCalls, 0)
  }

  func testMidstreamBindingInFlightCannotBeBypassedByConcurrentFrame() throws {
    let source = FakeCaptureSession(format: try format(), audio: .absent)
    let feed = FeedID(rawValue: "concurrent-take-context")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Concurrent source ready")
    let declared = expectation(description: "Declarations ready for midstream install")
    let frameDrained = expectation(description: "Frame offered while context is in flight")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "declaration barrier" { declared.fulfill() }
      if update.message == "media barrier" { frameDrained.fulfill() }
    }
    let bindingEntered = DispatchSemaphore(value: 0)
    let releaseBinding = DispatchSemaphore(value: 0)
    let installed = DispatchSemaphore(value: 0)
    defer { releaseBinding.signal(); controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.info("declaration barrier"))))
    wait(for: [declared], timeout: 1)
    let observed = TakeContextObservation()
    DispatchQueue.global().async {
      controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
        video: { _, _, _, _ in observed.video(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
        takeContext: { context in
          observed.context(context)
          if observed.contexts.count == 1 { bindingEntered.signal(); _ = releaseBinding.wait(timeout: .now() + 3) }
          return true
        }))
      installed.signal()
    }
    XCTAssertEqual(bindingEntered.wait(timeout: .now() + 1), .success)
    let buffer = try image()
    emit(source, image: buffer)
    XCTAssertTrue(source.submit(.event(.info("media barrier"))))
    wait(for: [frameDrained], timeout: 1)
    XCTAssertEqual(observed.videoCalls, 0, "A second binder must not publish readiness before the first metadata enqueue")
    XCTAssertEqual(observed.contexts.count, 1)
    releaseBinding.signal()
    XCTAssertEqual(installed.wait(timeout: .now() + 1), .success)
    emit(source, image: buffer, time: VideoContract.fastDuration)
    source.stop()
    XCTAssertEqual(observed.videoCalls, 2, "The held opening frame is replayed before the following live frame")
    XCTAssertEqual(observed.contexts.count, 1)
  }

  func testIndependentPCMUsesActualMappingsAndRetainsSourceFormatOnRecordingQueue() throws {
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    let source = FakeCaptureSession(format: try format(), audio: .present(audio))
    let feed = FeedID(rawValue: "independent-pcm-routing")
    let writer = TakeContextWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(fileURLWithPath: "/tmp/unused-independent-pcm.mov"), width: 3840, height: 2160)
    let recorder = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: recorder)
    try adapter.start()
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    controller.setRecordingCallbacks(feedID: feed, callbacks: adapter.callbacks)
    let ready = expectation(description: "Independent audio source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    defer { controller.onUpdate = nil; controller.stop(); try? adapter.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let initial = source.context
    let video = try ClockMapping(sourceAnchor: CMTime(value: 20, timescale: 1), hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    let audioMap = try ClockMapping(sourceAnchor: CMTime(value: 50, timescale: 1), hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: initial.epochID,
      clockID: initial.clockBindings.video, revision: 1, effectiveSequence: initial.nextSequence + 1, mapping: video)))))
    let audioContext = source.context
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: audioContext.epochID,
      clockID: try XCTUnwrap(audioContext.clockBindings.audio), revision: 2,
      effectiveSequence: audioContext.nextSequence + 1, mapping: audioMap)))))
    let pcm = [Float](repeating: 0.5, count: 8).withUnsafeBytes { Data($0) }
    XCTAssertTrue(source.submit(.rawAudio(try CaptureAudioPacket(planes: [pcm], sampleFrameCount: 8,
      format: audio, packetTime: CMTime(value: 50, timescale: 1)))))
    emit(source, image: try image(), time: CMTime(value: 20, timescale: 1))
    source.stop()
    try? adapter.stop()
    XCTAssertEqual(writer.sourceAudioCount, 1)
    XCTAssertEqual(writer.order.first, "context")
    if let audioIndex = writer.order.firstIndex(of: "sourceAudio"), let videoIndex = writer.order.firstIndex(of: "video") {
      XCTAssertLessThan(audioIndex, videoIndex, "Independent audio must reach the bounded writer hold before the first video")
    } else { XCTFail("Both pre-video audio and video must reach the writer") }
    XCTAssertEqual(writer.sourceAudioFormat?.mChannelsPerFrame, 1)
    XCTAssertEqual(writer.sourceAudioFormat?.mSampleRate, 48000)
    XCTAssertEqual(writer.sourceAudioMapping?.video, video)
    XCTAssertEqual(writer.sourceAudioMapping?.audio, audioMap)
  }

  func testUnknownAudioDoesNotInvokeRecordingMediaOrInventAbsence() throws {
    let source = FakeCaptureSession(format: try format(), audio: .unknown)
    let feed = FeedID(rawValue: "unknown-take-context")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let observed = TakeContextObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in observed.video(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
      takeContext: { context in observed.context(context); return true }))
    let ready = expectation(description: "Unknown-audio source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    emit(source, image: try image())
    source.stop()
    XCTAssertEqual(observed.videoCalls, 0)
    XCTAssertTrue(observed.contexts.isEmpty)
    XCTAssertEqual(controller.retentionSnapshotForTesting.accepted, 1, "Unknown audio must not prevent video capture/monitor work")
  }

  func testActualAbsentAndPresentContextsPrecedeVideoForEitherDeclarationOrder() throws {
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    for declaration in [SourceAudioDeclaration.absent, .present(audio)] {
      for audioFirst in [false, true] {
        let source = TakeContextFixtureSession(format: try format(), audio: declaration, audioFirst: audioFirst)
        let feed = FeedID(rawValue: "resolved-take-context")
        let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
        controller.setCameraOutputEnabled(false)
        let observed = TakeContextObservation()
        controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
          video: { _, _, _, _ in observed.video(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
          takeContext: { context in observed.context(context); return true }))
        let ready = expectation(description: "Resolved source ready")
        controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
        defer { controller.onUpdate = nil; controller.stop() }
        controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
        wait(for: [ready], timeout: 1)
        emit(source.source, image: try image())
        source.stop()
        XCTAssertEqual(observed.order, ["context", "video"])
        XCTAssertEqual(observed.contexts.first?.audioDeclaration, declaration)
        XCTAssertEqual(observed.contexts.first?.sourceAdmission.epochID, source.source.context.epochID)
        XCTAssertEqual(observed.contexts.first?.sourceAdmission.clockBindings, source.source.context.clockBindings)
        XCTAssertEqual(observed.contexts.first?.mappingRevision, 0)
        XCTAssertNil(observed.contexts.first?.videoMapping)
        XCTAssertNil(observed.contexts.first?.audioMapping)
      }
    }
  }

  func testMidstreamInstallUsesActualRevisionWithoutInventingMappingValues() throws {
    let source = TakeContextFixtureSession(format: try format(), audio: .absent, revisionOverride: 7)
    let feed = FeedID(rawValue: "midstream-take-context")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Source ready")
    let barrier = expectation(description: "Actual declarations consumed")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "take context barrier" { barrier.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.source.submit(.event(.info("take context barrier"))))
    wait(for: [barrier], timeout: 1)
    let observed = TakeContextObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in observed.video(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false },
      takeContext: { context in observed.context(context); return true }))
    XCTAssertEqual(observed.contexts.count, 1, "Installing a take must synchronously enqueue its metadata before media")
    XCTAssertEqual(observed.contexts.first?.mappingRevision, 7)
    XCTAssertNil(observed.contexts.first?.videoMapping)
    XCTAssertNil(observed.contexts.first?.audioMapping)
    source.stop()
  }

  func testActualClockMappingEventKeepsExactClockRevisionAndEffectiveSequence() throws {
    let source = FakeCaptureSession(format: try format(), audio: .absent)
    let feed = FeedID(rawValue: "mapping-take-context")
    let writer = TakeContextWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(fileURLWithPath: "/tmp/unused-take-context.mov"), width: 3840, height: 2160)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: core)
    try adapter.start()
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    controller.setRecordingCallbacks(feedID: feed, callbacks: adapter.callbacks)
    let ready = expectation(description: "Mapping source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    defer { controller.onUpdate = nil; controller.stop(); try? adapter.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let context = source.context
    let mapping = try ClockMapping(sourceAnchor: CMTime(value: 20, timescale: 1), hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    let update = CaptureClockMappingUpdate(epochID: context.epochID, clockID: context.clockBindings.video,
      revision: 4, effectiveSequence: context.nextSequence + 1, mapping: mapping)
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(update))))
    emit(source, image: try image(), time: CMTime(value: 20, timescale: 1))
    source.stop()
    try adapter.stop()
    XCTAssertEqual(writer.initialContext?.mappingRevision, 0)
    XCTAssertEqual(writer.initialContext?.audioDeclaration, .absent)
    XCTAssertEqual(writer.mappingEvents.first?.clockID, update.clockID)
    XCTAssertEqual(writer.mappingEvents.first?.revision, 4)
    XCTAssertEqual(writer.mappingEvents.first?.effectiveSequence, update.effectiveSequence)
    XCTAssertEqual(writer.mappingEvents.first?.mapping, mapping)
    let order = writer.order
    XCTAssertNotNil(order.firstIndex(of: "context"))
    XCTAssertNotNil(order.firstIndex(of: "mapping"))
    XCTAssertNotNil(order.firstIndex(of: "video"))
    if let mapped = order.firstIndex(of: "mapping"), let video = order.firstIndex(of: "video") { XCTAssertLessThan(mapped, video) }
  }

  func testInitialUnknownAudioWaitsAcrossResolutionEpochWithoutBindingAnEmptyTake() throws {
    let source = FakeCaptureSession(format: try format(), audio: .unknown)
    let feed = FeedID(rawValue: "initial-audio-discovery")
    let writer = TakeContextWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(fileURLWithPath: "/tmp/unused-discovery-context.mov"), width: 3840, height: 2160)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: core)
    try adapter.start()
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    controller.setRecordingCallbacks(feedID: feed, callbacks: adapter.callbacks)
    let ready = expectation(description: "Discovery source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    defer { controller.onUpdate = nil; controller.stop(); try? adapter.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let buffer = try image()
    emit(source, image: buffer)
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    XCTAssertTrue(source.submit(.event(.audioFormatChanged(.present(audio)))))
    emit(source, image: buffer, time: VideoContract.fastDuration)
    source.stop()
    XCTAssertEqual(core.state, .recording, "Initial unresolved discovery must not bind the pre-take epoch irreversibly")
    XCTAssertEqual(core.telemetry.enqueuedVideo, 2, "Discovery preserves the original opening frame and the resolved-epoch frame")
    XCTAssertEqual(core.telemetry.droppedInvalidSample, 0)
    try? adapter.stop()
    XCTAssertEqual(writer.initialContext?.audioDeclaration, .present(audio))
    XCTAssertEqual(writer.initialContext?.sourceAdmission.epochID, source.context.epochID)
    XCTAssertEqual(writer.contextContracts.count, 1)
  }

  func testLateUnknownAudioEndsBoundTakeBeforeAudioFirstVideoRedeclaration() throws {
    let source = TakeContextFixtureSession(format: try format(), audio: .absent, lateUnknownFirst: true)
    let feed = FeedID(rawValue: "late-unknown-audio")
    let writer = TakeContextWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(fileURLWithPath: "/tmp/unused-late-unknown.mov"), width: 3840, height: 2160)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: core)
    try adapter.start()
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    controller.setRecordingCallbacks(feedID: feed, callbacks: adapter.callbacks)
    let ready = expectation(description: "Bound take source ready")
    let barrier = expectation(description: "Initial take media admitted")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "bound take barrier" { barrier.fulfill() }
    }
    defer { source.releaseUnknown.signal(); controller.onUpdate = nil; controller.stop(); try? adapter.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    emit(source.source, image: try image())
    XCTAssertTrue(source.source.submit(.event(.info("bound take barrier"))))
    wait(for: [barrier], timeout: 1)
    XCTAssertTrue(source.source.submit(.event(.audioFormatChanged(.unknown))))
    XCTAssertEqual(source.unknownDelivered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(core.state, .failed, "A bound take must fail on the first new-epoch audio declaration, even while video redeclaration is paused")
    XCTAssertTrue(core.telemetry.lastError?.contains("audio") == true)
    source.releaseUnknown.signal()
    source.stop()
    try? adapter.stop()
    XCTAssertEqual(writer.initialContext?.audioDeclaration, .absent)
    XCTAssertEqual(writer.contextContracts.count, 1)
  }

  func testLateAudioChangeFailsTakeWithoutReplacingItsInitialContext() throws {
    let source = FakeCaptureSession(format: try format(), audio: .absent)
    let feed = FeedID(rawValue: "changed-audio-take-context")
    let writer = TakeContextWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(fileURLWithPath: "/tmp/unused-changed-context.mov"), width: 3840, height: 2160)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: core)
    try adapter.start()
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    controller.setRecordingCallbacks(feedID: feed, callbacks: adapter.callbacks)
    let ready = expectation(description: "Take source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    defer { controller.onUpdate = nil; controller.stop(); try? adapter.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    emit(source, image: try image())
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    XCTAssertTrue(source.submit(.event(.audioFormatChanged(.present(audio)))))
    source.stop()
    try? adapter.stop()
    XCTAssertEqual(core.state, .failed)
    XCTAssertEqual(writer.initialContext?.audioDeclaration, .absent)
    XCTAssertEqual(writer.contextContracts.count, 1)
  }
}

private final class TakeContextObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var contextsValue: [RecordingTakeContext] = []
  private var orderValue: [String] = []
  private var videos = 0
  private var mappings: [RecordingClockMappingEvent] = []
  private var failureMessages: [String] = []
  func context(_ context: RecordingTakeContext) { lock.withLock { contextsValue.append(context); orderValue.append("context") } }
  func video() { lock.withLock { videos += 1; orderValue.append("video") } }
  func clock(_ event: RecordingClockMappingEvent) { lock.withLock { mappings.append(event); orderValue.append("mapping") } }
  func failure(_ message: String) { lock.withLock { failureMessages.append(message) } }
  var mappingEvents: [RecordingClockMappingEvent] { lock.withLock { mappings } }
  var failures: [String] { lock.withLock { failureMessages } }
  var contexts: [RecordingTakeContext] { lock.withLock { contextsValue } }
  var videoCalls: Int { lock.withLock { videos } }
  var order: [String] { lock.withLock { orderValue } }
}

private final class TakeContextWriter: SourceRecordingWriter, @unchecked Sendable {
  private let lock = NSLock()
  private var first: RecordingTakeContext?
  private var events: [RecordingClockMappingEvent] = []
  private var contracts: [RecordingTakeContext] = []
  private var ordering: [String] = []
  private var sourceAudio = 0
  private var sourceFormat: AudioStreamBasicDescription?
  private var sourceMapping: AudioVideoClockMapping?
  var sourceAudioCount: Int { lock.withLock { sourceAudio } }
  var sourceAudioFormat: AudioStreamBasicDescription? { lock.withLock { sourceFormat } }
  var sourceAudioMapping: AudioVideoClockMapping? { lock.withLock { sourceMapping } }
  var initialContext: RecordingTakeContext? { lock.withLock { first } }
  var mappingEvents: [RecordingClockMappingEvent] { lock.withLock { events } }
  var contextContracts: [RecordingTakeContext] { lock.withLock { contracts } }
  var order: [String] { lock.withLock { ordering } }
  func start() throws {}
  func bindTakeContext(_ context: RecordingTakeContext) throws {
    lock.withLock { if first == nil { first = context }; contracts.append(context); ordering.append("context") }
  }
  func noteClockMapping(_ event: RecordingClockMappingEvent) throws { lock.withLock { events.append(event); ordering.append("mapping") } }
  func appendVideo(_ sample: CMSampleBuffer) throws { lock.withLock { ordering.append("video") } }
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func appendSourceAudio(_ sample: CMSampleBuffer, mapping: AudioVideoClockMapping) throws {
    let description = CMSampleBufferGetFormatDescription(sample).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    lock.withLock { sourceAudio += 1; sourceFormat = description; sourceMapping = mapping; ordering.append("sourceAudio") }
  }
  func finish() throws {}
}

private final class TakeContextFixtureSession: CaptureSession, @unchecked Sendable {
  let source: FakeCaptureSession
  private let audioFirst: Bool
  private let revisionOverride: UInt64?
  private let mappingDelay: UInt64
  private let maximumEventSequence: Bool
  private let lateUnknownFirst: Bool
  let unknownDelivered = DispatchSemaphore(value: 0)
  let releaseUnknown = DispatchSemaphore(value: 0)
  private var heldLateFormat: CaptureDelivery?
  private var held: CaptureDelivery?
  private var reordered = false
  init(format: SourceFormat, audio: SourceAudioDeclaration, audioFirst: Bool = false, revisionOverride: UInt64? = nil,
    mappingDelay: UInt64 = 0, maximumEventSequence: Bool = false, lateUnknownFirst: Bool = false) {
    source = FakeCaptureSession(format: format, audio: audio)
    self.audioFirst = audioFirst; self.revisionOverride = revisionOverride
    self.mappingDelay = mappingDelay; self.maximumEventSequence = maximumEventSequence
    self.lateUnknownFirst = lateUnknownFirst
  }
  var counters: CaptureCounters { source.counters }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    try source.start(deviceID: deviceID, timing: timing, handlers: CaptureHandlers { [self] value in
      let delivery = CaptureDelivery(sequence: value.sequence, epochID: value.epochID, formatSignature: value.formatSignature,
        clockBindings: value.clockBindings, mappingRevision: revisionOverride ?? value.mappingRevision, payload: value.payload)
      if lateUnknownFirst, delivery.epochID.epoch > 0 {
        if case .event(.formatChanged) = delivery.payload { heldLateFormat = delivery; return }
        if case .event(.audioFormatChanged(.unknown)) = delivery.payload, let format = heldLateFormat {
          handlers.deliver(CaptureDelivery(sequence: format.sequence, epochID: delivery.epochID,
            formatSignature: delivery.formatSignature, clockBindings: delivery.clockBindings,
            mappingRevision: delivery.mappingRevision, payload: delivery.payload))
          unknownDelivered.signal(); _ = releaseUnknown.wait(timeout: .now() + 3)
          handlers.deliver(CaptureDelivery(sequence: delivery.sequence, epochID: format.epochID,
            formatSignature: format.formatSignature, clockBindings: format.clockBindings,
            mappingRevision: format.mappingRevision, payload: format.payload))
          heldLateFormat = nil
          return
        }
      }
      if case .event(.clockMappingChanged(let update)) = delivery.payload,
        mappingDelay > 0 || maximumEventSequence {
        let changed = CaptureClockMappingUpdate(epochID: update.epochID, clockID: update.clockID, revision: update.revision,
          effectiveSequence: maximumEventSequence ? .max : update.effectiveSequence + mappingDelay, mapping: update.mapping)
        handlers.deliver(CaptureDelivery(sequence: maximumEventSequence ? .max : delivery.sequence,
          epochID: delivery.epochID, formatSignature: delivery.formatSignature, clockBindings: delivery.clockBindings,
          mappingRevision: delivery.mappingRevision, payload: .event(.clockMappingChanged(changed))))
        return
      }
      if audioFirst && !reordered {
        if case .event(.formatChanged) = delivery.payload { held = delivery; return }
        if case .event(.audioFormatChanged) = delivery.payload, let format = held {
          reordered = true
          handlers.deliver(CaptureDelivery(sequence: format.sequence, epochID: delivery.epochID, formatSignature: "",
            clockBindings: delivery.clockBindings, mappingRevision: delivery.mappingRevision, payload: delivery.payload))
          handlers.deliver(CaptureDelivery(sequence: delivery.sequence, epochID: format.epochID, formatSignature: format.formatSignature,
            clockBindings: format.clockBindings, mappingRevision: format.mappingRevision, payload: format.payload))
          return
        }
      }
      handlers.deliver(delivery)
    })
  }
  func stop() { source.stop() }
}
#endif
