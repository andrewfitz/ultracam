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
      try fixture.frame()
      let originalVideoSequence = fixture.source.context.nextSequence - 1
      try fixture.packet(audio, time: CMTime(value: 50, timescale: 1), pairedFrameSequence: paired ? originalVideoSequence : nil)
      try fixture.barrier(self, message: "opening PCM retained") { _ in }
      releaseBinding.signal()
      XCTAssertEqual(popped.wait(timeout: .now() + 1), .success)
      fixture.controller.setRecordingCallbacks(feedID: fixture.feed,
        callbacks: fixture.callbacks(failure: { replacement.failure($0) }, audio: { replacement.audio($0) }))
      try fixture.frame(time: VideoContract.fastDuration)
      let replacementVideoSequence = fixture.source.context.nextSequence - 1
      try fixture.barrier(self, message: "replacement first video") { _ in }
      releaseAudio.signal()
      XCTAssertEqual(installed.wait(timeout: .now() + 1), .success)
      try fixture.packet(audio, time: CMTime(value: 51, timescale: 1), pairedFrameSequence: paired ? replacementVideoSequence : nil)
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

  func testPairedEightAndSixteenChannelPCMKeepRawIdentityLayoutAndMeasuredJumpAnchors() throws {
    for channels in [8, 16] {
      let labels = (0..<channels).map { UInt32(kAudioChannelLabel_Discrete_0) + UInt32($0) }
      let audio = try SourceAudioFormat(sampleRate: 48000, channels: channels, sample: .int32,
        interleaved: true, layout: AudioChannelMap(labels: labels), clock: .pairedWithFrames)
      let samples = (0..<(8 * channels)).map { index -> Int32 in
        let value = Int32((index % channels + 1) * 0x01010000 + (index / channels) * 0x100 + 0x55)
        return index % 2 == 0 ? value : -value
      }
      let data = samples.withUnsafeBytes { Data($0) }
      let writer = try routePairedPackets(audio, packets: [(CMTime(value: 48000, timescale: 48000), CMTime(value: 20, timescale: 1)),
        (CMTimeAdd(CMTime(value: 1, timescale: 1), VideoContract.fastDuration),
         CMTimeAdd(CMTime(value: 20, timescale: 1), VideoContract.fastDuration))], data: data)
      XCTAssertEqual(writer.genericPackets, 2)
      XCTAssertEqual(writer.legacyPackets, 0, "Typed multichannel PCM must use the declaration-aware writer path")
      XCTAssertEqual(writer.channels, channels)
      XCTAssertEqual(writer.channelLabels, labels)
      XCTAssertEqual(writer.packetBytes, [data, data], "All source bits and channel positions reach the high24 converter unchanged")
      XCTAssertEqual(writer.packetTimes, [CMTime(value: 48000, timescale: 48000), CMTimeAdd(CMTime(value: 1, timescale: 1), VideoContract.fastDuration)])
      XCTAssertEqual(writer.videoTimes, [CMTime(value: 20, timescale: 1), CMTimeAdd(CMTime(value: 20, timescale: 1), VideoContract.fastDuration)])
    }
  }

  func testEquivalentPairedStereoPacketTimesUseAnyValidRationalGrid() throws {
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    for scale: Int32 in [48000, 1_000_000_000, 60000] {
      let time = CMTime(value: Int64(scale), timescale: scale)
      let writer = try routePairedPackets(audio, packets: [(time, CMTime(value: 20, timescale: 1))], data: Data(count: 64))
      XCTAssertEqual(writer.genericPackets, 1)
      XCTAssertEqual(writer.legacyPackets, 0)
      XCTAssertEqual(writer.sampleFrames, 8)
      XCTAssertEqual(writer.packetTime.map { CMTimeCompare($0, CMTime(value: 1, timescale: 1)) }, 0)
      XCTAssertEqual(writer.videoTime, CMTime(value: 20, timescale: 1))
    }
  }

  func testEveryTypedPairedFormatRefusesMissingStaleOrInvalidFrameReferencesBeforeAudioCallbacks() throws {
    for sample in [AudioSampleType.int32, .float32] {
      for reference in ["missing", "stale", "invalid"] {
        let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: sample,
          interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
        let fixture = try AuditCaptureFixture(audio: .present(audio))
        let observed = AuditObservation()
        var callbacks = fixture.callbacks(failure: { observed.failure($0) }, audio: { observed.audio($0) })
        callbacks.sourceAudioWithAdmission = { _, _, _, time, _, _, _ in observed.audio(time); return true }
        fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: callbacks)
        try fixture.start(self)
        try fixture.frame(time: CMTime(value: 20, timescale: 1))
        var sequence: UInt64?
        if reference == "stale" { sequence = UInt64.max - 1 }
        if reference == "invalid" {
          try fixture.frame(time: CMTime(value: 21, timescale: 1), signalValid: false)
          sequence = fixture.source.context.nextSequence - 1
        }
        try fixture.packet(audio, time: CMTime(value: 48000, timescale: 48000), pairedFrameSequence: sequence)
        fixture.source.stop()
        XCTAssertTrue(observed.audioTimes.isEmpty, "\(sample), \(reference) must not reach either audio callback")
        XCTAssertEqual(observed.failures.count, 1)
        XCTAssertTrue(observed.failures.first?.contains("matching video frame") == true)
        fixture.stop()
      }
    }
  }

  private func routePairedPackets(_ audio: SourceAudioFormat, packets: [(CMTime, CMTime)], data: Data) throws -> AuditPairedWriter {
    let fixture = try AuditCaptureFixture(audio: .present(audio))
    let writer = AuditPairedWriter()
    let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("paired-routing-audit"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-paired-routing-audit.mov"), width: 128, height: 72)
    let recorder = try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: configuration.feedID, recorder: recorder)
    try adapter.start()
    defer { fixture.stop(); try? adapter.stop() }
    fixture.controller.setRecordingCallbacks(feedID: fixture.feed, callbacks: adapter.callbacks)
    try fixture.start(self)
    for (packetTime, videoTime) in packets {
      try fixture.frame(time: videoTime)
      let sequence = fixture.source.context.nextSequence - 1
      XCTAssertTrue(fixture.source.submit(.rawAudio(try CaptureAudioPacket(planes: [data], sampleFrameCount: 8,
        format: audio, packetTime: packetTime, pairedFrameSequence: sequence))))
    }
    fixture.source.stop()
    try adapter.stop()
    XCTAssertEqual(recorder.telemetry.droppedInvalidSample, 0)
    XCTAssertEqual(recorder.telemetry.droppedAudio, 0)
    return writer
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
      sourceAudio: { _, _, _, time, _ in audio(time); return true }, metadataFailure: failure,
      sourceAudioWithAdmission: { _, _, _, time, _, _, _ in audio(time); return true })
  }
  func packet(_ audio: SourceAudioFormat, time: CMTime, pairedFrameSequence: UInt64? = nil) throws {
    XCTAssertTrue(source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 8 * audio.channels * 4)],
      sampleFrameCount: 8, format: audio, packetTime: time, pairedFrameSequence: pairedFrameSequence))))
  }
  func frame(time: CMTime = .zero, signalValid: Bool = true) throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
    let context = source.context
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)),
      CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: time, duration: VideoContract.fastDuration, signalValid: signalValid, timecode: nil))))
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
  var channels: Int?
  var channelLabels: [UInt32] = []
  var packetBytes: [Data] = []
  var packetTimes: [CMTime] = []
  var videoTimes: [CMTime] = []
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
    channels = Int(try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee.mChannelsPerFrame)
    if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: nil), layout.pointee.mNumberChannelDescriptions > 0 {
      let offset = try XCTUnwrap(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions))
      let descriptions = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
      channelLabels = (0..<Int(layout.pointee.mNumberChannelDescriptions)).map { descriptions[$0].mChannelLabel }
    }
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
    var bytes = Data(count: CMBlockBufferGetDataLength(block))
    let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    XCTAssertEqual(status, noErr)
    packetBytes.append(bytes)
    packetTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
    videoTimes.append(videoTime)
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
