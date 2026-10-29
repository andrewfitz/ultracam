#if ULTRACAM_TEST_SUPPORT
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureAuditChecks: XCTestCase {
  func testDiscoveryDeadlineCannotRejectAContextResolvedAfterItsObservation() throws {
    let fixture = try AuditCaptureFixture(deadline: 0.03)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let observation = AuditObservation()
    fixture.controller.setAuditHooksForTesting(CaptureController.AuditHooks(
      discoveryDeadlineObserved: { entered.signal(); _ = release.wait(timeout: .now() + 2) },
      discoveryDeadlineFinished: { finished.signal() }))
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: fixture.callbacks(failure: { observation.failure($0) }))
    defer { release.signal(); fixture.stop() }
    try fixture.start(self)
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(fixture.source.submit(.event(.audioFormatChanged(.absent))))
    fixture.source.stop()
    XCTAssertNotNil(fixture.controller.recordingTakeContext)
    release.signal()
    XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(observation.failures.isEmpty, "A stale deadline must not reject an already resolved take")
  }

  func testPoppedDiscoveryAudioCannotCrossIntoReplacementTakeForEitherClockRoute() throws {
    for paired in [false, true] {
      let audio = try SourceAudioFormat(sampleRate: 48000, channels: paired ? 2 : 1,
        sample: paired ? .int32 : .float32, interleaved: true, layout: AudioChannelMap(),
        clock: paired ? .pairedWithFrames : .deviceClock)
      let fixture = try AuditCaptureFixture(audio: .present(audio))
      try fixture.start(self)
      if !paired { try fixture.resolveMappings(); try fixture.barrier(self, message: "initial mappings") { _ in } }
      let binding = DispatchSemaphore(value: 0), releaseBinding = DispatchSemaphore(value: 0)
      let popped = DispatchSemaphore(value: 0), releaseAudio = DispatchSemaphore(value: 0), installed = DispatchSemaphore(value: 0)
      let old = AuditObservation(), replacement = AuditObservation()
      fixture.controller.setAuditHooksForTesting(CaptureController.AuditHooks(pendingAudioDequeued: {
        popped.signal(); _ = releaseAudio.wait(timeout: .now() + 2)
      }))
      var callbacks = fixture.callbacks(failure: { old.failure($0) }, audio: { old.audio($0) })
      callbacks.takeContext = { _ in binding.signal(); _ = releaseBinding.wait(timeout: .now() + 2); return true }
      let installing = callbacks
      DispatchQueue.global().async {
        fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: installing)
        installed.signal()
      }
      defer { releaseBinding.signal(); releaseAudio.signal(); fixture.stop() }
      XCTAssertEqual(binding.wait(timeout: .now() + 1), .success)
      try fixture.packet(audio, time: CMTime(value: 50, timescale: 1))
      try fixture.barrier(self, message: "opening PCM retained") { _ in }
      releaseBinding.signal()
      XCTAssertEqual(popped.wait(timeout: .now() + 1), .success)
      fixture.controller.setRecordingCallbacks(feedID: fixture.feed,
        callbacks: fixture.callbacks(failure: { replacement.failure($0) }, audio: { replacement.audio($0) }))
      try fixture.frame()
      try fixture.barrier(self, message: "replacement first video") { _ in }
      releaseAudio.signal()
      XCTAssertEqual(installed.wait(timeout: .now() + 1), .success)
      try fixture.packet(audio, time: CMTime(value: 51, timescale: 1))
      fixture.source.stop()
      XCTAssertTrue(old.audioTimes.isEmpty)
      XCTAssertEqual(replacement.audioTimes, [CMTime(value: 51, timescale: 1)], "Old queued PCM belongs to its original recording install")
      XCTAssertTrue(replacement.failures.isEmpty)
      fixture.stop()
    }
  }

  func testGenericPairedPCMUsesItsActualPacketAndExplicitVideoAnchorThroughAdapter() throws {
    let audio = try SourceAudioFormat(sampleRate: 44100, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let fixture = try AuditCaptureFixture(audio: .present(audio))
    let writer = AuditPairedWriter()
    let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("generic-paired-audit"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-generic-paired-audit.mov"), width: 128, height: 72)
    let recorder = try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: configuration.feedID, recorder: recorder)
    try adapter.start()
    defer { fixture.stop(); try? adapter.stop() }
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: adapter.callbacks)
    try fixture.start(self)
    try fixture.frame(time: CMTime(value: 20, timescale: 1))
    let sequence = fixture.source.context.nextSequence - 1
    try fixture.packet(audio, time: CMTime(value: 7, timescale: 1), pairedFrameSequence: sequence)
    fixture.source.stop()
    try adapter.stop()
    XCTAssertEqual(writer.packetTime, CMTime(value: 7, timescale: 1))
    XCTAssertEqual(writer.videoTime, CMTime(value: 20, timescale: 1))
    XCTAssertEqual(writer.sampleRate, 44100)
    XCTAssertEqual(writer.sampleFrames, 8)
    XCTAssertEqual(writer.genericPackets, 1)
    XCTAssertEqual(writer.legacyPackets, 0)
    XCTAssertEqual(recorder.telemetry.droppedAudio, 0)
  }

  func testGenericPairedPCMWithoutAnExplicitMatchingFrameRefusesTheTake() throws {
    let audio = try SourceAudioFormat(sampleRate: 44100, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let fixture = try AuditCaptureFixture(audio: .present(audio))
    let observed = AuditObservation()
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: fixture.callbacks(failure: { observed.failure($0) }))
    try fixture.start(self)
    try fixture.packet(audio, time: CMTime(value: 7, timescale: 1))
    fixture.source.stop()
    XCTAssertEqual(observed.failures.count, 1)
    XCTAssertTrue(observed.failures.first?.contains("paired") == true)
    XCTAssertTrue(fixture.controller.hasActiveFeed)
    fixture.stop()
  }

  func testDeclaredAudioRatesCountOnlyActualMissingSamplesAndResetEpochBaseline() throws {
    for (rate, frames) in [(44100.0, 441), (96000.0, 960)] {
      let audio = try SourceAudioFormat(sampleRate: rate, channels: 2, sample: .int32,
        interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
      let fixture = try AuditCaptureFixture(audio: .present(audio))
      try fixture.start(self)
      for tick in [0, 1] { try fixture.media(audio, frames: frames, time: CMTime(value: Int64(tick), timescale: 100)) }
      try fixture.barrier(self, message: "continuous packets") { XCTAssertEqual($0.audioDrops, 0) }
      try fixture.media(audio, frames: frames, time: CMTime(value: 3, timescale: 100))
      try fixture.barrier(self, message: "missing packet") { XCTAssertEqual($0.audioDrops, UInt64(frames)) }
      XCTAssertTrue(fixture.source.submit(.event(.discontinuity)))
      try fixture.media(audio, frames: frames, time: CMTime(value: 100, timescale: 1))
      try fixture.barrier(self, message: "new clock epoch") { XCTAssertEqual($0.audioDrops, UInt64(frames)) }
      fixture.stop()
    }
  }
}

private final class AuditCaptureFixture: @unchecked Sendable {
  let feed = FeedID(rawValue: "capture-audit")
  let source: FakeCaptureSession
  let controller: CaptureController
  init(audio: SourceAudioDeclaration = .unknown, deadline: TimeInterval = 2) throws {
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    source = FakeCaptureSession(format: format, audio: audio)
    let source = self.source
    controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }),
      recordingDiscoveryPolicy: try CaptureRecordingDiscoveryPolicy(deadline: deadline,
        maximumBytes: 64 * 1024 * 1024, maximumDuration: 1, maximumSlots: 64))
    controller.setCameraOutputEnabled(false)
  }
  func callbacks(failure: @escaping @Sendable (String) -> Void,
    audio: @escaping @Sendable (CMTime) -> Void = { _ in }) -> SourceRecordingCallbackAdapter.Callbacks {
    SourceRecordingCallbackAdapter.Callbacks(video: { _, _, _, _ in true }, audio: { _ in false },
      rawAudio: { _, _, time, _, _ in audio(time); return true }, sourceAdmission: { _ in true }, takeContext: { _ in true },
      sourceAudio: { _, _, _, time, _ in audio(time); return true }, metadataFailure: failure)
  }
  func packet(_ audio: SourceAudioFormat, time: CMTime, pairedFrameSequence: UInt64? = nil) throws {
    XCTAssertTrue(source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 8 * audio.channels * 4)],
      sampleFrameCount: 8, format: audio, packetTime: time, pairedFrameSequence: pairedFrameSequence))))
  }
  func frame(time: CMTime = .zero) throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
    let context = source.context
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)),
      CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: time, duration: VideoContract.fastDuration, signalValid: true, timecode: nil))))
  }
  func resolveMappings() throws {
    let video = source.context
    let mapping = try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: 100, timescale: 1), rate: .one)
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: video.epochID,
      clockID: video.clockBindings.video, revision: 1, effectiveSequence: video.nextSequence + 1, mapping: mapping)))))
    let audio = source.context
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: audio.epochID,
      clockID: try XCTUnwrap(audio.clockBindings.audio), revision: 2, effectiveSequence: audio.nextSequence + 1, mapping: mapping)))))
  }
  func start(_ test: XCTestCase) throws {
    let ready = test.expectation(description: "Audit source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    test.wait(for: [ready], timeout: 1)
  }
  func barrier(_ test: XCTestCase, message: String, check: @escaping @Sendable (CaptureUpdate) -> Void) throws {
    let done = test.expectation(description: message)
    controller.onUpdate = { update in if update.message == message { check(update); done.fulfill() } }
    XCTAssertTrue(source.submit(.event(.info(message))))
    test.wait(for: [done], timeout: 1)
  }
  func media(_ audio: SourceAudioFormat, frames: Int, time: CMTime) throws {
    XCTAssertTrue(source.submit(.media(CaptureMediaInfo(timecode: nil, pairedFrameSequence: nil,
      audioDeclaration: .present(audio), audioPacketTime: time, audioClockInstance: nil,
      sampleFrameCount: frames, byteCount: frames * 8, peaks: [0, 0], rms: [0, 0]))))
  }
  func stop() { controller.onUpdate = nil; controller.stop() }
  deinit { stop() }
}
private final class AuditPairedWriter: SourceRecordingWriter {
  var packetTime: CMTime?
  var videoTime: CMTime?
  var sampleRate: Double?
  var sampleFrames = 0
  var genericPackets = 0
  var legacyPackets = 0
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {}
  func appendAudio(_ sample: CMSampleBuffer) throws { legacyPackets += 1 }
  func appendPairedSourceAudio(_ sample: CMSampleBuffer, videoTime: CMTime) throws {
    genericPackets += 1
    packetTime = CMSampleBufferGetPresentationTimeStamp(sample)
    self.videoTime = videoTime
    sampleFrames = CMSampleBufferGetNumSamples(sample)
    let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    sampleRate = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee.mSampleRate
  }
  func finish() throws {}
}
private final class AuditObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []
  private var times: [CMTime] = []
  func failure(_ message: String) { lock.withLock { messages.append(message) } }
  func audio(_ time: CMTime) { lock.withLock { times.append(time) } }
  var failures: [String] { lock.withLock { messages } }
  var audioTimes: [CMTime] { lock.withLock { times } }
}
#endif
