#if ULTRACAM_TEST_SUPPORT
import AVFAudio
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureSourceAdmissionChecks: XCTestCase {
  func testNativeMediaTimecodeLabelIsPublishedAndClearedWithoutAudio() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: format, audio: .absent)
    let feed = FeedID(rawValue: "native-media-timecode")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Capture ready")
    let shown = expectation(description: "Native timecode displayed")
    let cleared = expectation(description: "Missing native timecode clears display")
    controller.onUpdate = { update in
      switch update.message {
      case let message where message.hasPrefix("Waiting"): ready.fulfill()
      case "Timecode detected":
        XCTAssertEqual(update.timecode, "01:02:03;04")
        shown.fulfill()
      case "Timecode absent":
        XCTAssertNil(update.timecode)
        cleared.fulfill()
      default: break
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    func report(_ timecode: Timecode?, message: String) {
      let media = CaptureMediaInfo(timecode: timecode, pairedFrameSequence: nil, audioDeclaration: .absent,
        audioPacketTime: nil, audioClockInstance: nil, sampleFrameCount: 0, byteCount: 0, peaks: [], rms: [])
      XCTAssertTrue(source.submitGroup([.media(media), .event(.info(message))]))
    }
    report(try Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, dropFrame: true), message: "Timecode detected")
    wait(for: [shown], timeout: 1)
    XCTAssertEqual(controller.latestSourceTimecode, "01:02:03;04")
    report(nil, message: "Timecode absent")
    wait(for: [cleared], timeout: 1)
    XCTAssertNil(controller.latestSourceTimecode)
  }

  func testProgramStreamFixedAudioUsesPairedFrameAndIndependentClockWithoutRecording() throws {
    for clock: AudioClockDomain in [.pairedWithFrames, .deviceClock] {
      let fixture = try SourceRouteFixture(pixel: .video420)
      let paired = clock == .pairedWithFrames
      let format = try SourceAudioFormat(sampleRate: 48_000, channels: paired ? 4 : 1,
        sample: .int16, interleaved: true, layout: AudioChannelMap(), clock: clock)
      let source = FakeCaptureSession(format: fixture.format, audio: .present(format))
      let feed = FeedID(rawValue: "program-stream-audio")
      let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
      controller.setCameraOutputEnabled(false)
      let host = CMTime(value: 120, timescale: 1)
      let pts = CMTime(value: 55, timescale: 1)
      let delivered = expectation(description: "Selected audio pair on the common host timeline")
      let tap = ProgramStreamAudioTap(pairIndex: paired ? 1 : 0) { pcm, time in
        XCTAssertEqual(time, host)
        XCTAssertEqual(pcm.format.channelCount, 2)
        XCTAssertEqual(pcm.format.sampleRate, 48_000)
        XCTAssertEqual(pcm.frameLength, 7)
        XCTAssertEqual(pcm.floatChannelData?[0][0], 0.25)
        XCTAssertEqual(pcm.floatChannelData?[1][0], paired ? -0.5 : 0.25)
        delivered.fulfill()
      }
      let picture = paired ? expectation(description: "Program picture and PCM share capture timestamp") : nil
      if let picture {
        controller.setProgramPictureWanted(true)
        controller.onProcessedFrame = { frame, _ in
          XCTAssertEqual(frame.metadata.captureHostTime, host)
          picture.fulfill()
        }
      }
      let ready = expectation(description: "Capture ready")
      controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
      controller.setProgramStreamAudioTap(tap)
      defer { tap.stop(); controller.setProgramStreamAudioTap(nil); controller.onUpdate = nil; controller.stop() }
      controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
        pipelineEnabled: false, previewEnabled: false)
      wait(for: [ready], timeout: 3)
      let ctx = source.context
      var payloads: [CaptureDelivery.Payload] = []
      if paired {
        let duration = fixture.format.rate.nominal
        let info = CaptureFrameInfo(epochID: ctx.epochID, formatSignature: ctx.formatSignature,
          presentationTime: .zero, duration: duration, signalValid: true, timecode: nil,
          hostTimeReference: .presentationEnd, captureHostTime: CMTimeAdd(host, duration))
        payloads.append(.frame(CapturedPixelBuffer(immutable: fixture.image), info))
      } else {
        let mapping = try ClockMapping(sourceAnchor: pts, hostAnchor: host, rate: .one)
        let clockID = try XCTUnwrap(ctx.clockBindings.audio)
        payloads.append(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: ctx.epochID,
          clockID: clockID, revision: 1, effectiveSequence: ctx.nextSequence + 1, mapping: mapping))))
      }
      let values: [Int16] = paired ? [1024, 2048, 8192, -16384] : [8192]
      let data = Array(repeating: values, count: 8).flatMap { $0 }.withUnsafeBytes { Data($0) }
      let packet = try CaptureAudioPacket(planes: [data], sampleFrameCount: 8, format: format,
        packetTime: pts, pairedFrameSequence: paired ? ctx.nextSequence : nil)
      payloads.append(.rawAudio(packet))
      XCTAssertTrue(source.submitGroup(payloads))
      wait(for: [delivered] + [picture].compactMap { $0 }, timeout: 5)
      tap.drainForTesting()
      XCTAssertEqual(tap.statistics.dropped, 0)
      XCTAssertEqual(tap.statistics.packets, 1)
      XCTAssertFalse(controller.audioMeterTap.isMetering)
    }
  }

  func testProgramStreamAudioPreservesShortPacketLossAndForgetsPreviousEpochPair() throws {
    let tap = ProgramStreamAudioTap(pairIndex: 0) { _, _ in }
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .int16,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 1)
    let anchor = CMTime(value: 120, timescale: 1)
    func packet(_ start: Int64) throws -> CaptureAudioPacket {
      try CaptureAudioPacket(planes: [Data(count: 960)], sampleFrameCount: 480, format: format,
        packetTime: CMTime(value: start, timescale: 48_000))
    }
    tap.ingest(try packet(0), epoch: epoch, pairedHostTime: anchor, audioMapping: nil)
    tap.drainForTesting()
    // Miss ten milliseconds, less than the converter's host-jitter tolerance.
    tap.ingest(try packet(960), epoch: epoch, pairedHostTime: nil, audioMapping: nil)
    tap.drainForTesting()
    XCTAssertEqual(tap.statistics.lastHostTime, CMTimeAdd(anchor, CMTime(value: 960, timescale: 48_000)))
    let newEpoch = CaptureEpochID(sessionID: epoch.sessionID, epoch: epoch.epoch + 1)
    tap.ingest(try packet(0), epoch: newEpoch, pairedHostTime: nil, audioMapping: nil)
    tap.drainForTesting()
    XCTAssertEqual(tap.statistics.packets, 2)
    XCTAssertEqual(tap.statistics.dropped, 1)
    tap.stop()
  }

  func testProgramStreamAudioTracksEmbeddedClockDriftWithoutBreakingSampleGrid() throws {
    final class Timing: @unchecked Sendable {
      var end: CMTime?
      var largestOffset = 0.0
      var observations = 0
    }
    let result = Timing()
    let tap = ProgramStreamAudioTap(pairIndex: 0) { buffer, time in
      if let end = result.end { XCTAssertEqual(time.seconds, end.seconds, accuracy: 1.0 / 48_000) }
      let expected = 100.0 + Double(result.observations) * 0.1001
      result.largestOffset = max(result.largestOffset, abs(time.seconds - expected))
      result.end = CMTimeAdd(time, CMTime(value: Int64(buffer.frameLength), timescale: 48_000))
      result.observations += 1
    }
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let data = Data(count: 4800 * 4)
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 1)
    for i in 0..<200 {
      let packet = try CaptureAudioPacket(planes: [data], sampleFrameCount: 4800,
        format: format, packetTime: CMTime(value: Int64(i), timescale: 10))
      tap.ingest(packet, epoch: epoch,
        pairedHostTime: CMTime(value: 1_000_000 + Int64(i) * 1001, timescale: 10_000), audioMapping: nil)
      tap.drainForTesting()
    }
    XCTAssertEqual(result.observations, 200)
    XCTAssertLessThan(result.largestOffset, 0.006)
    XCTAssertEqual(tap.statistics.dropped, 0)
    tap.stop()
  }

  func testAudioOnlyCallbacksKeepTheLastPictureAnchorAndDiscardDuplicatePCM() throws {
    final class Times: @unchecked Sendable { var values: [CMTime] = [] }
    let times = Times()
    let tap = ProgramStreamAudioTap(pairIndex: 0) { _, time in times.values.append(time) }
    defer { tap.stop() }
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let host = CMTime(value: 120, timescale: 1)
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .int16,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    func ingest(at frame: Int64) throws {
      let packet = try CaptureAudioPacket(planes: [Data(count: 960)], sampleFrameCount: 480,
        format: format, packetTime: CMTime(value: frame, timescale: 48_000), pairedFrameSequence: 10)
      tap.ingest(packet, epoch: epoch, pairedHostTime: host, audioMapping: nil)
      tap.drainForTesting()
    }
    for frame in stride(from: Int64(0), to: 480 * 8, by: 480) { try ingest(at: frame) }
    try ingest(at: 480 * 4)
    // A one-sample gap starts the next packet at its actual host time.
    try ingest(at: 480 * 8 + 1)
    XCTAssertEqual(tap.statistics.packets, 9)
    XCTAssertEqual(tap.statistics.dropped, 1)
    XCTAssertEqual(times.values, [host] + (1..<8).map { slot in
      CMTimeAdd(host, CMTime(value: Int64(slot * 480 - 1), timescale: 48_000))
    } + [CMTimeAdd(host, CMTime(value: 480 * 8 + 1, timescale: 48_000))])
  }

  func testProgramStreamAudioRefusesMissingClocksAndDropsBoundedBacklog() throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let tap = ProgramStreamAudioTap(pairIndex: 0) { _, _ in
      entered.signal()
      _ = release.wait(timeout: .now() + 3)
    }
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .float32,
      interleaved: false, layout: AudioChannelMap(), clock: .deviceClock)
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let pcm = Data(count: 4800 * 4)
    let packet = try CaptureAudioPacket(planes: [pcm], sampleFrameCount: 4800, format: format, packetTime: .zero)
    tap.ingest(packet, epoch: epoch, pairedHostTime: nil, audioMapping: nil)
    tap.drainForTesting()
    XCTAssertEqual(tap.statistics.dropped, 1)
    let mapping = try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: 21, timescale: 1), rate: .one)
    tap.ingest(packet, epoch: epoch, pairedHostTime: nil, audioMapping: mapping)
    XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
    for i in 1...9 {
      let p = try CaptureAudioPacket(planes: [pcm], sampleFrameCount: 4800, format: format,
        packetTime: CMTime(value: Int64(i), timescale: 10))
      tap.ingest(p, epoch: epoch, pairedHostTime: nil, audioMapping: mapping)
    }
    XCTAssertEqual(tap.statistics.dropped, 9)
    tap.stop()
    release.signal()
    tap.drainForTesting()
    XCTAssertEqual(tap.statistics.packets, 1)
  }

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
