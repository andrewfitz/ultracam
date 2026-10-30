import AudioToolbox
import MonitorKitAudio
import CoreMedia
import XCTest

@objcMembers final class SourceAudioMeterChecks: XCTestCase {
#if ULTRACAM_TEST_SUPPORT
  func testHeldProducerCoalescesUnusedSessionsAndPreservesItsPacket() {
    final class WeakMeter { weak var value: AudioMeter?; init(_ value: AudioMeter) { self.value = value } }
    let tap = AudioMeterTap()
    let original = tap.attach()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    tap.meterQueue.suspend()
    tap.producerAdmissionHook = { entered.signal(); release.wait() }
    DispatchQueue.global().async {
      tap.ingest(samples: Data(count: 16), sampleFrames: 2, channels: 2, bytesPerSample: 4)
      done.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
    tap.detach()
    var unused: [WeakMeter] = []
    for _ in 0..<100 { unused.append(WeakMeter(tap.attach())); tap.detach() }
    XCTAssertLessThanOrEqual(tap.retainedSessionCount, 2, "One queued/in-flight session and one coalesced replacement")
    XCTAssertEqual(unused.filter { $0.value != nil }.count, 1)
    release.signal()
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    tap.producerAdmissionHook = nil
    tap.meterQueue.resume()
    tap.waitUntilMetered()
    original.flush()
    XCTAssertEqual(original.snapshot().frameCount, 2, "The producer's old session cannot retire before publication")
    XCTAssertEqual(tap.counters.stale, 0)
    XCTAssertEqual(tap.queuedPCMBytes, 0)
  }

  func testProducerCannotPublishInsideSessionRetirementTransaction() throws {
    let tap = AudioMeterTap()
    tap.attach()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    tap.sessionMutationHook = { entered.signal(); release.wait() }
    let mono = try SourceAudioFormat(sampleRate: 44_100, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    DispatchQueue.global().async {
      try! tap.configure(format: mono)
      done.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
    tap.ingest(samples: Data(count: 16), sampleFrames: 2, channels: 2, bytesPerSample: 4)
    // The control transaction is deliberately blocked: ingest must still return.
    XCTAssertTrue(tap.handoffClaimedForTesting, "Retirement owns the same atomic claim as packet publication")
    XCTAssertEqual(tap.counters.overlapped, 1)
    XCTAssertEqual(tap.queuedPackets, 0)
    release.signal()
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    tap.sessionMutationHook = nil
    let samples = [Float](repeating: 0.25, count: 2).withUnsafeBytes { Data($0) }
    tap.ingest(try CaptureAudioPacket(planes: [samples], sampleFrameCount: 2, format: mono, packetTime: .zero))
    tap.waitUntilMetered()
    let meter = try XCTUnwrap(tap.meter)
    meter.flush()
    XCTAssertEqual(meter.snapshot().frameCount, 2)
    XCTAssertEqual(tap.counters.rejected, 0)
    tap.detach()
  }
#endif

  func testAttachmentCloseReleasesDemandWhileHandleIsStillRetained() {
    let tap = AudioMeterTap()
    let attachment = AudioMeterTap.Attachment(tap: tap)
    XCTAssertEqual(tap.viewerCount, 1)
    attachment.close()
    XCTAssertEqual(tap.viewerCount, 0)
    XCTAssertFalse(tap.isMetering)
    XCTAssertNil(attachment.meter)
    attachment.close()
    XCTAssertEqual(tap.viewerCount, 0, "Repeated close must not detach another owner")
    let another = AudioMeterTap.Attachment(tap: tap)
    attachment.close()
    XCTAssertEqual(tap.viewerCount, 1)
    another.close()
    XCTAssertEqual(tap.viewerCount, 0)
  }

  func testStableAttachmentFollowsDeclarationWithoutAddingViewers() throws {
    let tap = AudioMeterTap()
    let attachment = AudioMeterTap.Attachment(tap: tap)
    let old = try XCTUnwrap(attachment.meter)
    let mono = try SourceAudioFormat(sampleRate: 44_100, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    try tap.configure(format: mono)
    let current = try XCTUnwrap(attachment.meter)
    XCTAssertFalse(old === current)
    XCTAssertTrue(current === tap.meter)
    XCTAssertEqual(current.configuration.channelCount, 1)
    XCTAssertEqual(tap.viewerCount, 1)
    let samples = [Float](repeating: 0.25, count: 512).withUnsafeBytes { Data($0) }
    tap.ingest(try CaptureAudioPacket(planes: [samples], sampleFrameCount: 512,
      format: mono, packetTime: .zero))
    tap.waitUntilMetered()
    current.flush()
    XCTAssertEqual(attachment.meter?.snapshot().frameCount, 512)
    XCTAssertEqual(old.snapshot().frameCount, 0)
  }

  func testQueuedFirstSessionSurvivesUnusedLaterSessions() {
    let tap = AudioMeterTap()
    let first = tap.attach()
    tap.meterQueue.suspend()
    tap.ingest(samples: Data(count: 16), sampleFrames: 2, channels: 2, bytesPerSample: 4)
    tap.detach()
    for _ in 0..<30 { tap.attach(); tap.detach() }
    tap.meterQueue.resume()
    tap.waitUntilMetered()
    first.flush()
    XCTAssertEqual(first.snapshot().frameCount, 2)
    XCTAssertEqual(tap.counters.stale, 0)
    XCTAssertEqual(tap.queuedPCMBytes, 0)
  }

  func testNoAudioAttachAndDeclarationHistoryDoesNotRetainOldMeters() throws {
    final class WeakMeter { weak var value: AudioMeter?; init(_ value: AudioMeter) { self.value = value } }
    let tap = AudioMeterTap()
    var previous: [WeakMeter] = []
    for _ in 0..<30 {
      previous.append(WeakMeter(tap.attach()))
      tap.detach()
    }
    XCTAssertEqual(previous.filter { $0.value != nil }.count, 1)
    tap.attach()
    for channels in [1, 2, 3, 4, 5, 6] {
      previous.append(WeakMeter(try XCTUnwrap(tap.meter)))
      try tap.configure(format: SourceAudioFormat(sampleRate: 44_100, channels: channels,
        sample: .float32, interleaved: true, layout: AudioChannelMap(), clock: .hostTime))
    }
    XCTAssertEqual(previous.filter { $0.value != nil }.count, 0)
    tap.detach()
  }

  func testPausedPacketsAreExcludedAtEnqueueEvenWhenDrainRunsAfterResume() throws {
    let tap = AudioMeterTap()
    tap.beginTake()
    tap.meterQueue.suspend()
    let quiet = [Int32](repeating: 1 << 20, count: 9_600).withUnsafeBytes { Data($0) }
    let loud = [Int32](repeating: .max, count: 9_600).withUnsafeBytes { Data($0) }
    tap.ingest(samples: quiet, sampleFrames: 4_800, channels: 2, bytesPerSample: 4)
    tap.pauseTake(true)
    tap.ingest(samples: loud, sampleFrames: 4_800, channels: 2, bytesPerSample: 4)
    tap.pauseTake(false)
    tap.ingest(samples: quiet, sampleFrames: 4_800, channels: 2, bytesPerSample: 4)
    tap.pauseTake(true)
    tap.meterQueue.resume()
    let result = try XCTUnwrap(tap.endTake())
    XCTAssertEqual(result.duration, 0.2, accuracy: 0.000001)
    XCTAssertLessThan(result.maximumTruePeak, -40)
    XCTAssertEqual(result.overs, 0)
  }

  func testPausedLoudPacketStaysExcludedAfterResumeBeforeDrain() throws {
    let tap = AudioMeterTap()
    tap.beginTake()
    tap.meterQueue.suspend()
    tap.pauseTake(true)
    let loud = [Int32](repeating: .max, count: 9_600).withUnsafeBytes { Data($0) }
    tap.ingest(samples: loud, sampleFrames: 4_800, channels: 2, bytesPerSample: 4)
    tap.pauseTake(false)
    let quiet = Data(count: 9_600 * 4)
    tap.ingest(samples: quiet, sampleFrames: 4_800, channels: 2, bytesPerSample: 4)
    tap.meterQueue.resume()
    let result = try XCTUnwrap(tap.endTake())
    XCTAssertEqual(result.duration, 0.1, accuracy: 0.000001)
    XCTAssertEqual(result.maximumTruePeak, -.infinity)
    XCTAssertEqual(result.overs, 0)
  }

  func testPlanarFloatMetersEveryChannelAtDeclaredRate() throws {
    let format = try SourceAudioFormat(sampleRate: 44_100, channels: 3, sample: .float32,
      interleaved: false, layout: AudioChannelMap(), clock: .hostTime)
    let planes = [Float(0.125), 0.25, 0.5].map { value in
      Array(repeating: value, count: 512).withUnsafeBytes { Data($0) }
    }
    let packet = try CaptureAudioPacket(planes: planes, sampleFrameCount: 512,
      format: format, packetTime: .zero)
    let tap = AudioMeterTap()
    try tap.configure(format: format)
    let meter = tap.attach()
    tap.ingest(packet)
    tap.waitUntilMetered()
    meter.flush()
    let snapshot = meter.snapshot()
    XCTAssertEqual(snapshot.channelCount, 3)
    XCTAssertEqual(snapshot.frameCount, 512)
    XCTAssertGreaterThan(snapshot.channels[2].samplePeak, snapshot.channels[0].samplePeak)
    tap.detach()
  }

  func testSecondsBudgetRejectsOversizedPacketIndependentlyOfPacketCount() throws {
    let format = try SourceAudioFormat(sampleRate: 8_000, channels: 1, sample: .int16,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    let packet = try CaptureAudioPacket(planes: [Data(count: 1600)], sampleFrameCount: 800,
      format: format, packetTime: .zero)
    let tap = AudioMeterTap(maxBufferedSeconds: 0.05)
    try tap.configure(format: format)
    tap.attach()
    tap.ingest(packet)
    tap.waitUntilMetered()
    XCTAssertEqual(tap.counters.coalesced, 1)
    XCTAssertEqual(tap.counters.metered, 0)
    tap.detach()
  }

  func testByteBudgetCountsAllPlanarPlanesAndReleasesAfterFormatReset() throws {
    let mono = try SourceAudioFormat(sampleRate: 8_000, channels: 1, sample: .int16,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    let surround = try SourceAudioFormat(sampleRate: 96_000, channels: 4, sample: .float32,
      interleaved: false, layout: AudioChannelMap(), clock: .hostTime)
    let small = try CaptureAudioPacket(planes: [Data(count: 160)], sampleFrameCount: 80,
      format: mono, packetTime: .zero)
    let large = try CaptureAudioPacket(planes: Array(repeating: Data(count: 160), count: 4),
      sampleFrameCount: 40, format: surround, packetTime: .zero)
    let tap = AudioMeterTap(maxBufferedBytes: 700)
    try tap.configure(format: mono)
    tap.attach()
    tap.meterQueue.suspend()
    tap.ingest(small)
    try tap.configure(format: surround)
    tap.ingest(large)
    XCTAssertEqual(tap.queuedPCMBytes, 160)
    XCTAssertEqual(tap.counters.coalesced, 1)
    tap.meterQueue.resume()
    tap.waitUntilMetered()
    XCTAssertEqual(tap.queuedPCMBytes, 0)
    tap.ingest(large)
    tap.waitUntilMetered()
    XCTAssertEqual(tap.queuedPCMBytes, 0)
    XCTAssertEqual(tap.counters.coalesced, 1)
    tap.detach()
  }

  func testLegacyStereoRejectsPaddedPayloadAndReleasesAcceptedBytes() {
    let tap = AudioMeterTap(maxBufferedBytes: 32)
    tap.attach()
    tap.meterQueue.suspend()
    tap.ingest(samples: Data(count: 32), sampleFrames: 2, channels: 2, bytesPerSample: 4)
    XCTAssertEqual(tap.counters.rejected, 1)
    XCTAssertEqual(tap.queuedPCMBytes, 0)
    tap.ingest(samples: Data(count: 16), sampleFrames: 2, channels: 2, bytesPerSample: 4)
    XCTAssertEqual(tap.queuedPCMBytes, 16)
    tap.meterQueue.resume()
    tap.waitUntilMetered()
    XCTAssertEqual(tap.queuedPCMBytes, 0)
    XCTAssertEqual(tap.counters.metered, 1)
    tap.detach()
  }

  func testDeclaredPermutedSurroundLayoutPreservesRolesAndAllChannels() throws {
    let labels: [UInt32] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
      kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen]
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 6, sample: .float32,
      interleaved: true, layout: AudioChannelMap(labels: labels), clock: .hostTime)
    let tap = AudioMeterTap()
    try tap.configure(format: format)
    let meter = tap.attach()
    XCTAssertEqual(meter.configuration.loudnessChannels,
      [.left, .right, .center, .leftSurround, .rightSurround, .lfe])
    XCTAssertEqual(meter.configuration.channelCount, 6)
    XCTAssertEqual(SourceAudioMeterInput.activity(peaks: [0, 0, 0, 0.9, 0, 0],
      rms: [0, 0, 0, 0.3, 0, 0]).peak, 0.9, accuracy: 0.0001)
    tap.detach()
  }

  func testPermutedSurroundToneMatchesCanonicalLoudnessAndLFEKeepsPeak() throws {
    let orders: [[UInt32]] = [
      [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
       kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround],
      [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
       kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen]]
    var integrated: [Float] = []
    for labels in orders {
      let format = try SourceAudioFormat(sampleRate: 48_000, channels: 6, sample: .float32,
        interleaved: true, layout: AudioChannelMap(labels: labels), clock: .hostTime)
      let tap = AudioMeterTap()
      try tap.configure(format: format)
      let meter = tap.attach()
      var samples = [Float](repeating: 0, count: 48_000 * 6)
      let surround = labels.firstIndex(of: kAudioChannelLabel_LeftSurround)!
      let lfe = labels.firstIndex(of: kAudioChannelLabel_LFEScreen)!
      for frame in 0..<48_000 {
        let tone = Float(sin(Double(frame) * 2 * .pi * 1000 / 48_000))
        samples[frame * 6 + surround] = 0.1 * tone
        samples[frame * 6 + lfe] = 0.5 * tone
      }
      for _ in 0..<3 {
        samples.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: 48_000) }
      }
      meter.flush()
      let snapshot = meter.snapshot()
      XCTAssertTrue(snapshot.loudness.integrated.isFinite)
      XCTAssertGreaterThan(snapshot.channels[lfe].samplePeak, snapshot.channels[surround].samplePeak,
        "LFE remains in per-channel peaks even when excluded from programme loudness")
      integrated.append(snapshot.loudness.integrated)
      tap.detach()
    }
    XCTAssertEqual(integrated[0], integrated[1], accuracy: 0.0001)
  }

  func testDiscreteAndUnlabelledInputsUseExplicitProgrammePolicies() throws {
    let discrete = try SourceAudioFormat(sampleRate: 48_000, channels: 3, sample: .float32,
      interleaved: true, layout: AudioChannelMap(labels: [kAudioChannelLabel_Discrete_0,
        kAudioChannelLabel_Discrete_1, kAudioChannelLabel_Discrete_2]), clock: .hostTime)
    XCTAssertEqual(try SourceAudioMeterInput.loudnessChannels(for: discrete), [.weighted(1), .weighted(1), .weighted(1)])
    let unknownOrder = try SourceAudioFormat(sampleRate: 48_000, channels: 6, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    XCTAssertEqual(try SourceAudioMeterInput.loudnessChannels(for: unknownOrder),
      [.left, .right, .excluded, .excluded, .excluded, .excluded])
  }

  func testStandardLayoutTagIsExpandedAndUnsupportedLabelsRefused() throws {
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 6, sample: .float32,
      interleaved: true, layout: AudioChannelMap(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_D), clock: .hostTime)
    let tap = AudioMeterTap()
    try tap.configure(format: format)
    let meter = tap.attach()
    XCTAssertEqual(meter.configuration.loudnessChannels,
      [.center, .left, .right, .leftSurround, .rightSurround, .lfe])
    let unknown = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(labels: [kAudioChannelLabel_Unknown]), clock: .hostTime)
    XCTAssertThrowsError(try tap.configure(format: unknown))
    XCTAssertTrue(tap.meter === meter)
    tap.detach()
  }

  func testPCMIntegerContainersUseTheirDeclaredFullScale() throws {
    for (sample, values) in [(AudioSampleType.int16, [Int32(16_384), -16_384]),
      (.int24in32, [4_194_304, -4_194_304]), (.int32, [1_073_741_824, -1_073_741_824])] {
      let format = try SourceAudioFormat(sampleRate: 48_000, channels: 2, sample: sample,
        interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
      let bytes = sample == .int16 ? values.map { Int16($0) }.withUnsafeBytes { Data($0) }
        : values.withUnsafeBytes { Data($0) }
      let packet = try CaptureAudioPacket(planes: [bytes], sampleFrameCount: 1,
        format: format, packetTime: .zero)
      XCTAssertEqual(SourceAudioMeterInput.interleavedSamples(packet), [0.5, -0.5])
    }
  }

  func testAutoSwitchActivityIncludesChannelsBeyondStereo() {
    let result = SourceAudioMeterInput.activity(peaks: [0, 0, 0.8], rms: [0, 0, 0.4])
    XCTAssertEqual(result.peak, 0.8, accuracy: 0.0001)
    XCTAssertEqual(result.rms, 0.4, accuracy: 0.0001)
  }

  func testRejectsUnsupportedChannelCountWithoutChangingLiveMeter() throws {
    let tap = AudioMeterTap()
    let meter = tap.attach()
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 17, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    XCTAssertThrowsError(try tap.configure(format: format))
    XCTAssertTrue(tap.meter === meter)
    tap.detach()
  }
}
