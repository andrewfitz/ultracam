#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureSourceAdmissionChecks: XCTestCase {
  func testProvenSourceFormatsReachRecordingThroughTypedController() throws {
    for pixel in [PixelFormatID.twoVuy, .yuvs, .video420, .full420, .bgra8, .r210, .r12L, .uyva, .p216, .i420, .pa16] {
      let fixture = try SourceRouteFixture(pixel: pixel)
      let expectedFormat = fixture.format
      let session = FakeCaptureSession(format: fixture.format, audio: .absent)
      let feed = FeedID(rawValue: "proven-source-\(pixel.rawValue)")
      let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in session }))
      controller.setCameraOutputEnabled(false)
      let received = expectation(description: "Actual declared source reaches recording: \(pixel)")
      var callbacks = SourceRecordingCallbackAdapter.Callbacks(
        video: { _, _, _, _ in XCTFail("Typed admission must accompany the source frame"); return false },
        audio: { _ in false }, rawAudio: { _, _, _, _, _ in false })
      callbacks.videoWithAdmission = { image, metadata, source, valid in
        XCTAssertTrue(valid)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), pixel.rawValue)
        XCTAssertEqual(CVPixelBufferGetWidth(image), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(image), 72)
        XCTAssertEqual(source.format, expectedFormat)
        XCTAssertEqual(source.format.pixel, pixel)
        XCTAssertEqual(source.epochID, session.context.epochID)
        XCTAssertEqual(source.formatSignature, session.context.formatSignature)
        XCTAssertEqual(metadata.formatSignature, source.format.signature)
        XCTAssertEqual(metadata.epochID, source.epochID)
        received.fulfill()
        return true
      }
      controller.setRecordingCallbacks(feedID: feed, callbacks: callbacks)
      let ready = expectation(description: "Typed source ready")
      let observations = SourceAdmissionCaptureObservation()
      controller.onUpdate = { update in
        observations.record(update)
        if update.message.hasPrefix("Waiting") { ready.fulfill() }
      }
      controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
        pipelineEnabled: false, previewEnabled: false)
      wait(for: [ready], timeout: 1)
      let context = session.context
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: .zero, duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
      XCTAssertTrue(session.submit(.frame(CapturedPixelBuffer(immutable: fixture.image), info)))
      wait(for: [received], timeout: 1)
      XCTAssertNil(observations.lastFailure)
      controller.onUpdate = nil
      controller.stop()
    }
  }

  private func packedSource() throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
    return try XCTUnwrap(image)
  }

  func testMediaAudioFormatMismatchRefusesBeforeMetersOrRecording() throws {
    try assertAudioPayloadMismatchIsRefused(mediaPayload: true)
  }
  func testRawAudioFormatMismatchIsAnActionableRefusal() throws {
    try assertAudioPayloadMismatchIsRefused(mediaPayload: false)
  }
  private func assertAudioPayloadMismatchIsRefused(mediaPayload: Bool) throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let declared = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let mismatch = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let source = FakeCaptureSession(format: format, audio: .present(declared))
    let feed = FeedID(rawValue: "audio-payload-mismatch")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let observations = SourceAdmissionCaptureObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in false }, audio: { _ in observations.noteAudio(); return true },
      rawAudio: { _, _, _, _, _ in observations.noteAudio(); return true }))
    let ready = expectation(description: "Declared audio source ready")
    let refused = expectation(description: "Audio payload format differs from its immutable declaration")
    controller.onUpdate = { update in
      observations.record(update)
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.stopped { refused.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    if mediaPayload {
      XCTAssertTrue(source.submit(.media(CaptureMediaInfo(timecode: nil, pairedFrameSequence: nil,
        audioDeclaration: .present(mismatch), audioPacketTime: .zero, audioClockInstance: nil,
        sampleFrameCount: 1, byteCount: 4, peaks: [0.8], rms: [0.5]))))
    } else {
      XCTAssertTrue(source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 4)], sampleFrameCount: 1,
        format: mismatch, packetTime: .zero))))
    }
    wait(for: [refused], timeout: 0.5)
    XCTAssertTrue(observations.lastFailure?.contains("audio") == true)
    XCTAssertEqual(observations.audioCalls, 0)
    XCTAssertEqual(controller.retentionSnapshotForTesting.accepted, 0)
    XCTAssertEqual(controller.retentionSnapshotForTesting.rejected, 0)
    source.stop()
  }

  func testChangedAudioClockBindingRefusesBeforeRecordingAudio() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    let source = AdmissionFixtureSession(format: format, audio: .present(audio), mutateRawClock: true)
    let feed = FeedID(rawValue: "changed-audio-clock")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let observations = SourceAdmissionCaptureObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, valid in observations.noteAcceptedVideo(valid); return valid }, audio: { _ in false },
      rawAudio: { _, _, _, _, _ in observations.noteAudio(); return true }))
    let ready = expectation(description: "Bound audio source ready")
    let refused = expectation(description: "Changing an audio binding requires a new epoch")
    controller.onUpdate = { update in
      observations.record(update)
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.stopped { refused.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let context = source.source.context
    let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: .zero, duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
    let packet = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1, format: audio,
      packetTime: .zero, pairedFrameSequence: 3)
    XCTAssertTrue(source.source.submitGroup([.frame(CapturedPixelBuffer(immutable: try packedSource()), info), .rawAudio(packet)]))
    wait(for: [refused], timeout: 0.5)
    XCTAssertEqual(observations.audioCalls, 0)
    XCTAssertTrue(observations.lastFailure?.contains("clock") == true)
    XCTAssertEqual(observations.last?.coreRejectedFrames, 0)
  }

  func testFatalClosesRecordingAdmissionWhileCaptureQueueIsHeld() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let source = AdmissionFixtureSession(format: format, holdStart: true)
    let feed = FeedID(rawValue: "fatal-before-frame")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let observations = SourceAdmissionCaptureObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in observations.noteVideo(); return true }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false }))
    let refused = expectation(description: "Terminal source error published after queue release")
    controller.onUpdate = { update in observations.record(update); if update.stopped { refused.fulfill() } }
    defer { source.releaseStart.signal(); controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    XCTAssertEqual(source.startEntered.wait(timeout: .now() + 1), .success)
    let context = source.source.context
    let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: .zero, duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
    XCTAssertTrue(source.source.submitGroup([.event(.fatal("Fixture terminal error")), .frame(CapturedPixelBuffer(immutable: try packedSource()), info)]))
    source.source.stop()
    XCTAssertEqual(observations.videoCalls, 0)
    XCTAssertEqual(controller.retentionSnapshotForTesting.accepted, 0)
    source.releaseStart.signal()
    wait(for: [refused], timeout: 1)
    XCTAssertEqual(observations.lastFailure, "Fixture terminal error")
  }

  func testAudioDeclarationBeforeVideoFormatIsBoundedAndAppliedWithoutInventingAudio() throws {
    for unknownVideoSignature in [false, true] {
      let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration))
      let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
        interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
      let source = AdmissionFixtureSession(format: format, audio: .present(audio), reorderAudioFirst: true,
        unknownVideoSignature: unknownVideoSignature)
      let feed = FeedID(rawValue: "audio-first-\(unknownVideoSignature)")
      let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
      controller.setCameraOutputEnabled(false)
      let observations = SourceAdmissionCaptureObservation()
      controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
        video: { _, _, _, valid in observations.noteAcceptedVideo(valid); return valid }, audio: { _ in false },
        rawAudio: { _, _, _, _, _ in observations.noteAudio(); return true }))
      let ready = expectation(description: "Audio-first source ready")
      controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
      defer { controller.onUpdate = nil; controller.stop() }
      controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
      wait(for: [ready], timeout: 1)
      let context = source.source.context
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: .zero, duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
      let packet = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1, format: audio, packetTime: .zero, pairedFrameSequence: 3)
      XCTAssertTrue(source.source.submitGroup([.frame(CapturedPixelBuffer(immutable: try packedSource()), info), .rawAudio(packet)]))
      source.stop()
      XCTAssertEqual(observations.acceptedVideos, 1)
      XCTAssertEqual(observations.audioCalls, 1)
    }
  }

  func testDiscontinuityImmediatelyRetiresQueuedFramesBeforeRedeclaration() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let source = AdmissionFixtureSession(format: format, gateReset: true)
    let feed = FeedID(rawValue: "reset-before-redeclaration")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    let sink = AdmissionBlockingMonitor()
    controller.setCameraOutputEnabled(false)
    controller.setMonitorSink(sink)
    let ready = expectation(description: "Reset source ready")
    let captureBarrier = expectation(description: "Second source-only offer queued")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "capture barrier" { captureBarrier.fulfill() }
    }
    defer { sink.release.signal(); source.releaseReset.signal(); controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let image = try packedSource()
    let context = source.source.context
    for index in 0..<2 {
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(index)),
        duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
      XCTAssertTrue(source.source.submit(.frame(CapturedPixelBuffer(immutable: image), info)))
      if index == 0 { XCTAssertEqual(sink.entered.wait(timeout: .now() + 1), .success) }
    }
    XCTAssertTrue(source.source.submit(.event(.info("capture barrier"))))
    wait(for: [captureBarrier], timeout: 1)
    XCTAssertTrue(source.source.submit(.event(.discontinuity)))
    XCTAssertEqual(source.resetObserved.wait(timeout: .now() + 1), .success)
    sink.release.signal()
    let deadline = Date().addingTimeInterval(0.5)
    while controller.retentionSnapshotForTesting.currentSlots > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(controller.retentionSnapshotForTesting.currentSlots, 0)
    XCTAssertEqual(sink.offers, 1, "Old queued work must retire at reset, even before the new format declaration")
    source.releaseReset.signal()
    source.stop()
  }

  func testAdapterRejectsActualStaleEnvelopeBeforeRecordingQueueAdmission() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let snapshot = try SourceAdmissionSnapshot(format: format, epochID: epoch,
      clockBindings: CaptureClockBindings(video: ClockInstanceID(), audio: nil), stage: .capture)
    let writer = AdmissionBindingWriter()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("stale-recording-frame"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-stale-contract.mov"), width: 3840, height: 2160)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: config.feedID, recorder: core)
    try adapter.start()
    defer { try? adapter.stop() }
    let callbacks = adapter.callbacks
    XCTAssertTrue(callbacks.sourceAdmission?(snapshot) == true)
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    let metadata = SourceAdmissionMetadata(pixelBuffer: image, presentationTime: .zero,
      duration: VideoContract.fastDuration, epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
      formatSignature: format.signature)
    XCTAssertFalse(callbacks.videoWithAdmission?(image, metadata, snapshot, true) ?? true)
    XCTAssertEqual(core.state, .failed)
    XCTAssertEqual(core.telemetry.enqueuedVideo, 0)
    XCTAssertEqual(core.telemetry.droppedInvalidSample, 1)
    XCTAssertEqual(core.telemetry.droppedVideo, 1)
    XCTAssertTrue(core.telemetry.lastError?.contains("recording source refused") == true)
  }

  func testRecordingTakeBindsDeclaredSnapshotBeforeAnyMediaIncludingMidstreamInstall() throws {
    for installBeforeStart in [true, false] {
      let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
        rate: .constant(VideoContract.fastDuration))
      let source = FakeCaptureSession(format: format)
      let feed = FeedID(rawValue: "recording-contract-binding-\(installBeforeStart)")
      let writer = AdmissionBindingWriter()
      let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
        outputURL: URL(fileURLWithPath: "/tmp/unused-source-contract.mov"), width: 3840, height: 2160)
      let core = try SourceRecorderCore(configuration: config, writerFactory: { writer })
      let adapter = SourceRecordingCallbackAdapter(feedID: SourceRecordingFeedID(feed.rawValue), recorder: core)
      try adapter.start()
      let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
      controller.setCameraOutputEnabled(false)
      defer { controller.onUpdate = nil; controller.stop(); try? adapter.stop() }
      if installBeforeStart { controller.setRecordingCallbacks(feedID: feed, callbacks: adapter.callbacks) }
      let ready = expectation(description: "Binding source ready")
      let declared = expectation(description: "Ordered declarations reached the controller")
      controller.onUpdate = { update in
        if update.message.hasPrefix("Waiting") { ready.fulfill() }
        if update.message == "contract barrier" { declared.fulfill() }
      }
      controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
        pipelineEnabled: false, previewEnabled: false)
      wait(for: [ready], timeout: 1)
      XCTAssertTrue(source.submit(.event(.info("contract barrier"))))
      wait(for: [declared], timeout: 1)
      if !installBeforeStart { controller.setRecordingCallbacks(feedID: feed, callbacks: adapter.callbacks) }
      XCTAssertEqual(core.sourceAdmission?.epochID, source.context.epochID)
      XCTAssertEqual(core.sourceAdmission?.formatSignature, format.signature)
      XCTAssertEqual(writer.snapshot?.epochID, source.context.epochID)
      XCTAssertEqual(core.telemetry.enqueuedVideo, 0)
      source.stop()
    }
  }

  func testExplicitHostMappingUsesNonzeroOriginAndFrozenDriftRevision() throws {
    let controller = CaptureController(services: CaptureServices(startTyped: { _, _, _ in }, stop: {},
      connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    let old = try ClockMapping(sourceAnchor: CMTime(value: 20, timescale: 1),
      hostAnchor: CMTime(value: 100, timescale: 1), rate: Rational(1001, 1000))
    let refined = try ClockMapping(sourceAnchor: CMTime(value: 20, timescale: 1),
      hostAnchor: CMTime(value: 200, timescale: 1), rate: .one)
    let source = CMTime(value: 21, timescale: 1)
    let delayedOld = controller.hostTimeForTesting(sourceTime: source, duration: VideoContract.fastDuration,
      image: buffer, reference: .presentationStart, mapping: old)
    let new = controller.hostTimeForTesting(sourceTime: source, duration: VideoContract.fastDuration,
      image: buffer, reference: .presentationStart, mapping: refined)
    XCTAssertEqual(delayedOld.seconds, 101.001, accuracy: 0.000000001)
    XCTAssertEqual(new.seconds, 201, accuracy: 0.000000001)
    XCTAssertEqual(try old.hostTime(for: source), delayedOld)
  }

  func testExplicitFrameEndHostAnchorMapsPresentationStartWithoutChangingStartReferences() throws {
    for reference in [CaptureHostTimeReference.presentationStart, .presentationEnd] {
      let services = CaptureServices(startTyped: { _, _, _ in }, stop: {}, connect: { _, _ in },
        disconnect: {}, send: { _ in true })
      let controller = CaptureController(services: services)
      var made: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &made), kCVReturnSuccess)
      let image = try XCTUnwrap(made)
      CVBufferSetAttachment(image, DeviceAPI.captureHostTimeAttachmentKey as CFString,
        NSNumber(value: 100.0), .shouldNotPropagate)
      let duration = VideoContract.fastDuration
      let actual = controller.hostTimeForTesting(sourceTime: CMTime(value: 20, timescale: 1),
        duration: duration, image: image, reference: reference)
      let end = CMTime(value: 100, timescale: 1)
      let expected = reference == .presentationEnd ? CMTimeSubtract(end, duration) : end
      XCTAssertEqual(CMTimeSubtract(actual, expected).seconds, 0, accuracy: 0.000000001,
        "An explicitly end-referenced native attachment must subtract exactly one rational source duration")
    }
  }

  func testHostClockFallbackIsNotReinterpretedAsAnAttachedFrameEnd() throws {
    var services = CaptureServices(startTyped: { _, _, _ in }, stop: {}, connect: { _, _ in },
      disconnect: {}, send: { _ in true })
    services.hostTime = { CMTime(value: 123, timescale: 1) }
    let controller = CaptureController(services: services)
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &made), kCVReturnSuccess)
    let actual = controller.hostTimeForTesting(sourceTime: .zero, duration: VideoContract.fastDuration,
      image: try XCTUnwrap(made), reference: .presentationEnd)
    XCTAssertEqual(actual, CMTime(value: 123, timescale: 1))
  }

  func testMidstreamSizeAndAspectUseNewImmutableEpochSnapshot() throws {
    let first = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let second = try SourceFormat(width: 1280, height: 720, pixelAspect: Rational(4, 3), pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: first, audio: .absent)
    let feed = FeedID(rawValue: "midstream-size-aspect")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Source session ready")
    let initial = expectation(description: "Initial declaration")
    let changed = expectation(description: "Changed declaration")
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "initial size barrier" { initial.fulfill() }
      if update.message == "changed size barrier" { changed.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    XCTAssertTrue(source.submit(.event(.info("initial size barrier"))))
    wait(for: [initial], timeout: 1)
    let old = try XCTUnwrap(controller.recordingTakeContext)
    XCTAssertTrue(source.submit(.event(.formatChanged(second))))
    XCTAssertTrue(source.submit(.event(.info("changed size barrier"))))
    wait(for: [changed], timeout: 1)
    let current = try XCTUnwrap(controller.recordingTakeContext)
    XCTAssertEqual(old.sourceAdmission.sourceSize.width, 1920)
    XCTAssertEqual(old.sourceAdmission.sourceSize.pixelAspect, .one)
    XCTAssertEqual(current.sourceAdmission.sourceSize.width, 1280)
    XCTAssertEqual(current.sourceAdmission.sourceSize.pixelAspect, try Rational(4, 3))
    XCTAssertNotEqual(current.sourceAdmission.epochID, old.sourceAdmission.epochID)
    XCTAssertNotEqual(current.sourceAdmission.formatSignature, old.sourceAdmission.formatSignature)
    source.stop()
  }

  func testDeclared1080SourcePublishesActualSizeAndAspectWithoutRefusal() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixelAspect: Rational(4, 3), pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: format)
    let feed = FeedID(rawValue: "declared-1080-source")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let published = expectation(description: "Actual declaration dimensions published before video")
    let observations = SourceAdmissionCaptureObservation()
    controller.onUpdate = { update in
      observations.record(update)
      if update.input.contains("1920") && update.input.contains("1080") { published.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [published], timeout: 0.5)
    XCTAssertNil(observations.lastFailure)
    XCTAssertEqual(controller.retentionSnapshotForTesting.accepted, 0)
    XCTAssertEqual(controller.retentionSnapshotForTesting.rejected, 0)
  }

  func testMalformedFrameRefusesBeforeRecordingAndRetentionAdmission() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: format)
    let feed = FeedID(rawValue: "malformed-source-frame")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let observations = SourceAdmissionCaptureObservation()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in observations.noteVideo(); return false }, audio: { _ in false },
      rawAudio: { _, _, _, _, _ in false }))
    let ready = expectation(description: "Source session ready")
    let refused = expectation(description: "Malformed buffer is an actionable contract failure")
    controller.onUpdate = { update in
      observations.record(update)
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.stopped { refused.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    let context = source.context
    let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: .zero, duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)), info)))
    wait(for: [refused], timeout: 0.5)
    XCTAssertTrue(observations.lastFailure?.contains("capture refused") == true)
    XCTAssertTrue(observations.lastFailure?.contains("3840") == true)
    XCTAssertEqual(observations.videoCalls, 0)
    XCTAssertEqual(controller.retentionSnapshotForTesting.accepted, 0)
    XCTAssertEqual(controller.retentionSnapshotForTesting.rejected, 0)
    XCTAssertEqual(observations.last?.coreRejectedFrames, 0)
  }
}

private final class AdmissionFixtureSession: CaptureSession, @unchecked Sendable {
  let source: FakeCaptureSession
  let startEntered = DispatchSemaphore(value: 0)
  let releaseStart = DispatchSemaphore(value: 0)
  let resetObserved = DispatchSemaphore(value: 0)
  let releaseReset = DispatchSemaphore(value: 0)
  private let mutateRawClock: Bool
  private let holdStart: Bool
  private let reorderAudioFirst: Bool
  private let unknownVideoSignature: Bool
  private let gateReset: Bool
  private var heldInitialFormat: CaptureDelivery?
  private var reordered = false
  init(format: SourceFormat, audio: SourceAudioDeclaration = .absent, mutateRawClock: Bool = false,
    holdStart: Bool = false, reorderAudioFirst: Bool = false, unknownVideoSignature: Bool = false,
    gateReset: Bool = false) {
    source = FakeCaptureSession(format: format, audio: audio)
    self.mutateRawClock = mutateRawClock; self.holdStart = holdStart
    self.reorderAudioFirst = reorderAudioFirst; self.unknownVideoSignature = unknownVideoSignature
    self.gateReset = gateReset
  }
  var counters: CaptureCounters { source.counters }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    try source.start(deviceID: deviceID, timing: timing, handlers: CaptureHandlers { [self] delivery in
      if reorderAudioFirst, !reordered {
        if case .event(.formatChanged) = delivery.payload { heldInitialFormat = delivery; return }
        if case .event(.audioFormatChanged) = delivery.payload, let format = heldInitialFormat {
          reordered = true
          handlers.deliver(CaptureDelivery(sequence: format.sequence, epochID: delivery.epochID,
            formatSignature: unknownVideoSignature ? "" : delivery.formatSignature,
            clockBindings: delivery.clockBindings, mappingRevision: delivery.mappingRevision, payload: delivery.payload))
          handlers.deliver(CaptureDelivery(sequence: delivery.sequence, epochID: format.epochID,
            formatSignature: format.formatSignature, clockBindings: format.clockBindings,
            mappingRevision: format.mappingRevision, payload: format.payload))
          return
        }
      }
      if mutateRawClock, case .rawAudio = delivery.payload {
        handlers.deliver(CaptureDelivery(sequence: delivery.sequence, epochID: delivery.epochID,
          formatSignature: delivery.formatSignature,
          clockBindings: CaptureClockBindings(video: delivery.clockBindings.video, audio: ClockInstanceID()),
          mappingRevision: delivery.mappingRevision, payload: delivery.payload))
      } else { handlers.deliver(delivery) }
      if gateReset, case .event(.discontinuity) = delivery.payload {
        resetObserved.signal(); _ = releaseReset.wait(timeout: .now() + 3)
      }
    })
    if holdStart { startEntered.signal(); _ = releaseStart.wait(timeout: .now() + 3) }
  }
  func stop() { source.stop() }
}

private final class AdmissionBlockingMonitor: MonitorFrameSink, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0
  var offers: Int { lock.withLock { count } }
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64, untouched: Bool) {
    let first = lock.withLock { count += 1; return count == 1 }
    if first { entered.signal(); _ = release.wait(timeout: .now() + 3) }
  }
  func invalidate(rejectingCaptureGeneration: UInt64?) {}
}

private final class AdmissionBindingWriter: SourceRecordingWriter, @unchecked Sendable {
  private let lock = NSLock()
  private var bound: SourceAdmissionSnapshot?
  var snapshot: SourceAdmissionSnapshot? { lock.withLock { bound } }
  func start() throws {}
  func bindSourceAdmission(_ snapshot: SourceAdmissionSnapshot) throws { lock.withLock { bound = snapshot } }
  func appendVideo(_ sample: CMSampleBuffer) throws {}
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func finish() throws {}
}

private final class SourceAdmissionCaptureObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var updates: [CaptureUpdate] = []
  private var videos = 0
  private var accepted = 0
  private var audio = 0
  func record(_ update: CaptureUpdate) { lock.withLock { updates.append(update) } }
  func noteVideo() { lock.withLock { videos += 1 } }
  func noteAcceptedVideo(_ valid: Bool) { lock.withLock { if valid { accepted += 1 } } }
  func noteAudio() { lock.withLock { audio += 1 } }
  var acceptedVideos: Int { lock.withLock { accepted } }
  var audioCalls: Int { lock.withLock { audio } }
  var last: CaptureUpdate? { lock.withLock { updates.last } }
  var lastFailure: String? { lock.withLock { updates.last(where: \.stopped)?.message } }
  var videoCalls: Int { lock.withLock { videos } }
}
#endif
