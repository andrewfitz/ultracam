#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureDiscoveryChecks: XCTestCase {
  func testOpeningVideoSurvivesAudioDiscoveryEpochWithOriginalProvenance() throws {
    let fixture = try DiscoveryFixture()
    let received = expectation(description: "Opening and subsequent video retained in order")
    received.expectedFulfillmentCount = 2
    let observation = DiscoveryObservation()
    var callbacks = fixture.callbacks(failure: { XCTFail($0) })
    callbacks.videoWithAdmission = { _, metadata, source, _ in
      observation.note(metadata.presentationTime, epoch: source.epochID)
      received.fulfill(); return true
    }
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: callbacks)
    try fixture.start(self)
    let original = fixture.source.context.epochID
    try fixture.frame(.zero)
    XCTAssertTrue(fixture.source.submit(.event(.audioFormatChanged(.absent))))
    try fixture.frame(VideoContract.fastDuration)
    wait(for: [received], timeout: 1)
    XCTAssertEqual(observation.times, [.zero, VideoContract.fastDuration])
    XCTAssertEqual(observation.epochs.first, original)
    XCTAssertNotEqual(observation.epochs.last, original)
    fixture.stop()
  }

  func testMixedOpeningVideoAndPCMKeepOriginalOrderUntilMappingsResolve() throws {
    let fixture = try DiscoveryFixture()
    let received = expectation(description: "Mixed discovery media replayed")
    received.expectedFulfillmentCount = 3
    let observed = DiscoveryObservation()
    var callbacks = fixture.callbacks(failure: { XCTFail($0) })
    callbacks.videoWithAdmission = { _, metadata, source, _ in
      observed.note(metadata.presentationTime, epoch: source.epochID); received.fulfill(); return true
    }
    callbacks.sourceAudio = { planes, frames, format, time, context in
      XCTAssertEqual(planes, [Data(count: 32)])
      XCTAssertEqual(frames, 8)
      XCTAssertEqual(format.channels, 1)
      XCTAssertNotNil(context.videoMapping)
      XCTAssertNotNil(context.audioMapping)
      XCTAssertEqual(time, CMTime(value: 50, timescale: 1))
      observed.noteAudio(); received.fulfill(); return true
    }
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: callbacks)
    try fixture.start(self)
    try fixture.frame(.zero)
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    XCTAssertTrue(fixture.source.submit(.event(.audioFormatChanged(.present(audio)))))
    XCTAssertTrue(fixture.source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 32)],
      sampleFrameCount: 8, format: audio, packetTime: CMTime(value: 50, timescale: 1)))))
    try fixture.frame(VideoContract.fastDuration)
    try fixture.resolveMappings()
    wait(for: [received], timeout: 1)
    XCTAssertEqual(observed.order, ["video", "audio", "video"])
    fixture.stop()
  }

  func testPCMDiscoveryBudgetRefusesOnceInsteadOfDiscardingOpeningAudio() throws {
    let fixture = try DiscoveryFixture(policy: CaptureRecordingDiscoveryPolicy(deadline: 10,
      maximumBytes: 1, maximumDuration: 1, maximumSlots: 64))
    let refused = expectation(description: "Raw PCM discovery byte limit")
    let observed = DiscoveryObservation()
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: fixture.callbacks(failure: {
      XCTAssertTrue($0.contains("pending-media")); observed.failure($0); refused.fulfill()
    }))
    try fixture.start(self)
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    XCTAssertTrue(fixture.source.submit(.event(.audioFormatChanged(.present(audio)))))
    for _ in 0..<2 {
      XCTAssertTrue(fixture.source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 32)],
        sampleFrameCount: 8, format: audio, packetTime: .zero))))
    }
    wait(for: [refused], timeout: 0.5)
    fixture.source.stop()
    XCTAssertEqual(observed.failures.count, 1)
    XCTAssertTrue(fixture.controller.hasActiveFeed)
    fixture.stop()
  }

  func testMixedDiscoveryAdapterPreservesOriginalPCMClockAndVideoEpoch() throws {
    let fixture = try DiscoveryFixture()
    let writer = DiscoverySampleWriter()
    let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("mixed-discovery-provenance"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-mixed-discovery.mov"), width: 128, height: 72)
    let recorder = try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: configuration.feedID, recorder: recorder)
    try adapter.start()
    defer { try? adapter.stop() }
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: adapter.callbacks)
    try fixture.start(self)
    let videoEpoch = fixture.source.context.epochID
    try fixture.frame(.zero)
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    XCTAssertTrue(fixture.source.submit(.event(.audioFormatChanged(.present(audio)))))
    let audioContext = fixture.source.context
    XCTAssertTrue(fixture.source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 32)],
      sampleFrameCount: 8, format: audio, packetTime: CMTime(value: 50, timescale: 1)))))
    try fixture.resolveMappings()
    fixture.source.stop()
    try adapter.stop()
    XCTAssertEqual(writer.provenance.first?.epochID, videoEpoch)
    XCTAssertEqual(writer.audioProvenance.first?.epochID, audioContext.epochID)
    XCTAssertEqual(writer.audioProvenance.first?.audioClock, audioContext.clockBindings.audio)
    XCTAssertEqual(writer.order, ["video", "audio"])
    XCTAssertEqual(recorder.telemetry.droppedVideo, 0)
    fixture.stop()
  }

  func testDiscoveryRejectsChangedVideoContentOrClockWithoutReplayingOldFrames() throws {
    for changeClock in [false, true] {
      let fixture = try DiscoveryFixture()
      let refused = expectation(description: "Changed video contract refuses pending take")
      fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: fixture.callbacks(failure: {
        XCTAssertTrue($0.contains("video format or clock")); refused.fulfill()
      }))
      try fixture.start(self)
      try fixture.frame(.zero)
      if changeClock {
        XCTAssertTrue(fixture.source.submit(.event(.discontinuity)))
      } else {
        let changed = try SourceFormat(width: 256, height: 144, pixel: .v210, rate: .constant(VideoContract.fastDuration))
        XCTAssertTrue(fixture.source.submit(.event(.formatChanged(changed))))
      }
      wait(for: [refused], timeout: 1)
      XCTAssertTrue(fixture.controller.hasActiveFeed)
      fixture.stop()
    }
  }

  func testDiscoveryReplayPreservesOriginalProvenanceThroughRecordingAdapter() throws {
    let fixture = try DiscoveryFixture()
    let writer = DiscoverySampleWriter()
    let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("discovery-provenance"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-discovery-provenance.mov"), width: 128, height: 72)
    let recorder = try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: configuration.feedID, recorder: recorder)
    try adapter.start()
    defer { try? adapter.stop() }
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: adapter.callbacks)
    try fixture.start(self)
    let original = fixture.source.context.epochID
    try fixture.frame(.zero)
    XCTAssertTrue(fixture.source.submit(.event(.audioFormatChanged(.absent))))
    try fixture.frame(VideoContract.fastDuration)
    let resolved = fixture.source.context.epochID
    fixture.source.stop()
    try adapter.stop()
    XCTAssertEqual(writer.provenance.map { $0.epochID }, [original, resolved])
    XCTAssertEqual(writer.times, [.zero, VideoContract.fastDuration])
    XCTAssertEqual(recorder.telemetry.droppedVideo, 0)
    fixture.stop()
  }

  func testPendingDiscoveryByteDurationAndSlotExhaustionFailOnceWithoutStoppingPreview() throws {
    for policy in [
      try CaptureRecordingDiscoveryPolicy(deadline: 1, maximumBytes: 1, maximumDuration: 1, maximumSlots: 64),
      try CaptureRecordingDiscoveryPolicy(deadline: 1, maximumBytes: 64 * 1024 * 1024, maximumDuration: 0.001, maximumSlots: 64),
      try CaptureRecordingDiscoveryPolicy(deadline: 1, maximumBytes: 64 * 1024 * 1024, maximumDuration: 1, maximumSlots: 1)] {
      let fixture = try DiscoveryFixture(policy: policy)
      let refused = expectation(description: "Pending media budget refuses the take")
      let observation = DiscoveryObservation()
      fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: fixture.callbacks(failure: {
        observation.failure($0); refused.fulfill()
      }))
      try fixture.start(self)
      try fixture.frame(.zero)
      try fixture.frame(VideoContract.fastDuration)
      wait(for: [refused], timeout: 1)
      fixture.source.stop()
      XCTAssertEqual(observation.failures.count, 1)
      XCTAssertTrue(observation.failures.first?.contains("discovery") == true)
      XCTAssertTrue(fixture.controller.hasActiveFeed)
      let retained = try XCTUnwrap(fixture.controller.recordingDiscoverySnapshotForTesting(feedID: fixture.feed))
      XCTAssertEqual(retained.currentSlots, 0)
      XCTAssertEqual(retained.currentBytes, 0)
      XCTAssertEqual(retained.accepted, retained.released)
      fixture.stop()
    }
  }

  func testUnknownAudioDiscoveryHasADeadlineWithoutRequiringAnotherFrame() throws {
    let fixture = try DiscoveryFixture(policy: CaptureRecordingDiscoveryPolicy(deadline: 0.03,
      maximumBytes: 64 * 1024 * 1024, maximumDuration: 1, maximumSlots: 64))
    let refused = expectation(description: "Discovery deadline expires without a following packet")
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: fixture.callbacks(failure: {
      XCTAssertTrue($0.contains("discovery")); refused.fulfill()
    }))
    try fixture.start(self)
    wait(for: [refused], timeout: 0.5)
    XCTAssertTrue(fixture.controller.hasActiveFeed)
    fixture.stop()
  }
}

private final class DiscoverySampleWriter: SourceRecordingWriter {
  var provenance: [RecordingSourceProvenance] = []
  var times: [CMTime] = []
  var audioProvenance: [RecordingSourceProvenance] = []
  var order: [String] = []
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {
    let data = try XCTUnwrap(CMGetAttachment(sample, key: SourceRecordingConfiguration.sourceProvenanceAttachmentKey as CFString,
      attachmentModeOut: nil) as? Data)
    provenance.append(try JSONDecoder().decode(RecordingSourceProvenance.self, from: data))
    times.append(CMSampleBufferGetPresentationTimeStamp(sample))
    order.append("video")
  }
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func appendSourceAudio(_ sample: CMSampleBuffer, mapping: AudioVideoClockMapping) throws {
    order.append("audio")
    let data = try XCTUnwrap(CMGetAttachment(sample, key: SourceRecordingConfiguration.sourceProvenanceAttachmentKey as CFString,
      attachmentModeOut: nil) as? Data)
    audioProvenance.append(try JSONDecoder().decode(RecordingSourceProvenance.self, from: data))
  }
  func finish() throws {}
}

private final class DiscoveryFixture {
  let feed = FeedID(rawValue: "audio-discovery")
  let source: FakeCaptureSession
  let controller: CaptureController
  let image: CVPixelBuffer
  init(policy: CaptureRecordingDiscoveryPolicy = .standard) throws {
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    source = FakeCaptureSession(format: format, audio: .unknown)
    let source = self.source
    controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }), recordingDiscoveryPolicy: policy)
    controller.setCameraOutputEnabled(false)
    var value: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &value), kCVReturnSuccess)
    image = try XCTUnwrap(value)
  }
  func callbacks(failure: @escaping @Sendable (String) -> Void) -> SourceRecordingCallbackAdapter.Callbacks {
    SourceRecordingCallbackAdapter.Callbacks(video: { _, _, _, _ in false }, audio: { _ in false },
      rawAudio: { _, _, _, _, _ in false }, sourceAdmission: { _ in true }, takeContext: { _ in true }, metadataFailure: failure)
  }
  func start(_ test: XCTestCase) throws {
    let ready = test.expectation(description: "Discovery source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    test.wait(for: [ready], timeout: 1)
  }
  func frame(_ time: CMTime) throws {
    let context = source.context
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: image), CaptureFrameInfo(epochID: context.epochID,
      formatSignature: context.formatSignature, presentationTime: time, duration: VideoContract.fastDuration, signalValid: true, timecode: nil))))
  }
  func resolveMappings() throws {
    let video = source.context
    let videoMap = try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: video.epochID,
      clockID: video.clockBindings.video, revision: 1, effectiveSequence: video.nextSequence + 1, mapping: videoMap)))))
    let audio = source.context
    let audioMap = try ClockMapping(sourceAnchor: CMTime(value: 50, timescale: 1), hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: audio.epochID,
      clockID: try XCTUnwrap(audio.clockBindings.audio), revision: 2, effectiveSequence: audio.nextSequence + 1, mapping: audioMap)))))
    XCTAssertTrue(source.submit(.event(.info("mapping effectiveness barrier"))))
  }
  func stop() { controller.onUpdate = nil; controller.stop() }
  deinit { stop() }
}
private final class DiscoveryObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [(CMTime, CaptureEpochID)] = []
  private var messages: [String] = []
  private var eventOrder: [String] = []
  func note(_ time: CMTime, epoch: CaptureEpochID) { lock.withLock { samples.append((time, epoch)); eventOrder.append("video") } }
  func noteAudio() { lock.withLock { eventOrder.append("audio") } }
  var order: [String] { lock.withLock { eventOrder } }
  func failure(_ message: String) { lock.withLock { messages.append(message) } }
  var times: [CMTime] { lock.withLock { samples.map { $0.0 } } }
  var epochs: [CaptureEpochID] { lock.withLock { samples.map { $0.1 } } }
  var failures: [String] { lock.withLock { messages } }
}
#endif
