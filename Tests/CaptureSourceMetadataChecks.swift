#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest

@objcMembers final class CaptureSourceMetadataChecks: XCTestCase {
  func testLiveStorageRefusalLeavesSourceRecordingAndCaptureRunning() throws {
    guard MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) == true else { throw XCTSkip("Metal 4 required") }
    let ordinary = try SourceRouteFixture(pixel: .video420, shareable: false)
    let shareable = try SourceRouteFixture(pixel: .video420)
    let source = FakeCaptureSession(format: ordinary.format, audio: .absent)
    let feed = FeedID(rawValue: "live-storage-refusal")
    var services = CaptureServices.registryBridge(feedID: feed, makeSession: { _ in source })
    let previewed = expectation(description: "Preview recovers on the next shareable frame")
    services.preview = { _ in previewed.fulfill() }
    let controller = CaptureController(services: services)
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Source ready")
    let refused = expectation(description: "Live output diagnostic")
    let recorded = expectation(description: "Both original buffers reach the source take")
    recorded.expectedFulfillmentCount = 2
    let expectedFirst = CapturedPixelBuffer(immutable: ordinary.image)
    let expectedSecond = CapturedPixelBuffer(immutable: shareable.image)
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { image, pts, _, _ in
        XCTAssertTrue(image === (pts == .zero ? expectedFirst.value : expectedSecond.value))
        recorded.fulfill()
        return true
      }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false }))
    controller.onUpdate = { update in
      XCTAssertFalse(update.stopped)
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == LiveFrameRouteError.unshareableStorage.localizedDescription { refused.fulfill() }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: true)
    wait(for: [ready], timeout: 3)
    let context = source.context
    let duration = ordinary.format.rate.nominal
    let first = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: .zero, duration: duration, signalValid: true, timecode: nil)
    XCTAssertTrue(source.submit(.frame(expectedFirst, first)))
    wait(for: [refused], timeout: 3)
    controller.onUpdate = nil
    let second = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: duration, duration: duration, signalValid: true, timecode: nil)
    XCTAssertTrue(source.submit(.frame(expectedSecond, second)))
    wait(for: [recorded, previewed], timeout: 3)
  }

  func testLUTAndEffectsTogglesRestoreNativeColourAndRecoverFromUnsupportedOutput() throws {
    guard MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) == true else { throw XCTSkip("Metal 4 required") }
    final class Connections: @unchecked Sendable {
      let lock = NSLock()
      let attempted = DispatchSemaphore(value: 0)
      var colours: [Colorimetry] = []
      var configurations: [PipelineConfiguration] = []
      var refused = 0
    }
    let observed = Connections()
    let pq = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .center)
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210, colour: pq,
      rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: format, audio: .absent)
    let feed = FeedID(rawValue: "colour-contract-transition")
    var services = CaptureServices.registryBridge(feedID: feed, makeSession: { _ in source })
    services.disconnect = {}
    services.connectWithSource = { configuration, type, sourceFormat in
      defer { observed.attempted.signal() }
      let colour = try CameraSink.resolvedOutputColour(configuration: configuration, sourceFormat: sourceFormat)
      observed.lock.withLock {
        observed.colours.append(colour)
        observed.configurations.append(configuration)
      }
      do { _ = try CameraSink.requestedFormat(configuration: configuration, passthroughFormat: type, sourceFormat: sourceFormat) }
      catch { observed.lock.withLock { observed.refused += 1 }; throw error }
    }
    let controller = CaptureController(services: services)
    controller.requestCameraOutputEnabled(true, framesWanted: false)
    defer { controller.onUpdate = nil; controller.stop() }
    let ready = expectation(description: "Source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    var configuration = PipelineConfiguration(applyLUT: false, downscale: false,
      convertTo420: true, reduceFrameRate: false)
    let sony = Colorimetry(primaries: .sGamut3Cine, transfer: .sLog3, matrix: .rec709,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    configuration.sourceColorimetryOverride = sony
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: configuration,
      previewEnabled: false)
    wait(for: [ready], timeout: 3)
    controller.onUpdate = nil
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary,
      &image), kCVReturnSuccess)
    let buffer = CapturedPixelBuffer(immutable: try XCTUnwrap(image))
    for index in 0..<8 {
      if index == 1 { configuration.applyLUT = true; configuration.lutOutputColorimetry = .rec709Video }
      if index == 2 { configuration.lutOutputColorimetry = pq }
      if index == 3 {
        configuration.lutOutputColorimetry = sony
      }
      if index == 4 {
        configuration.lutOutputColorimetry = .rec709Video
      }
      if index == 5 { configuration.applyLUT = false }
      controller.reconfigure(configuration: configuration, pipelineEnabled: index != 6)
      let context = source.context
      XCTAssertTrue(source.submit(.frame(buffer, CaptureFrameInfo(epochID: context.epochID,
        formatSignature: context.formatSignature, presentationTime: CMTime(value: Int64(index), timescale: 1),
        duration: VideoContract.fastDuration, signalValid: true, timecode: nil))))
      XCTAssertEqual(observed.attempted.wait(timeout: .now() + 3), .success,
        "Colour-only change must replace the previous camera contract")
    }
    let colours = observed.lock.withLock { observed.colours }
    XCTAssertEqual(colours.map(\.transfer), [.pq, .rec709, .pq, .sLog3, .rec709, .pq, .pq, .pq],
      "Returning from unsupported output must establish a supported contract again")
    let configurations = observed.lock.withLock { observed.configurations }
    XCTAssertEqual(configurations.map(\.sourceColorimetryOverride),
      [nil, sony, sony, sony, sony, nil, nil, nil],
      "LUT-off and Effects-off must use native encoding, preserving the configured profile for LUT-on")
    XCTAssertEqual(configurations.map(\.convertTo420), [true, true, true, true, true, true, false, true],
      "LUT-off retains selected processing; Effects-off bypasses it and Effects-on restores it")
    XCTAssertEqual(configuration.sourceColorimetryOverride, sony,
      "Deriving output policy must not erase the configured source profile")
    XCTAssertEqual(observed.lock.withLock { observed.refused }, 1,
      "Unsupported log output must be refused, never mislabeled as the previous supported output")
  }

  func testPCMOnlyAudioStatusWithMetersClosedAndPairedAccounting() throws {
    let video = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    for paired in [false, true] {
      let audio = try SourceAudioFormat(sampleRate: 44_100, channels: 1, sample: .float32,
        interleaved: true, layout: AudioChannelMap(), clock: paired ? .pairedWithFrames : .hostTime)
      let source = FakeCaptureSession(format: video, audio: .present(audio))
      let feed = FeedID(rawValue: "audio-stats-\(paired)")
      let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
      controller.setCameraOutputEnabled(false)
      let ready = expectation(description: "Audio source ready")
      let first = expectation(description: "First PCM packet published")
      let lost = paired ? nil : expectation(description: "Audio interruption published")
      let resumed = paired ? nil : expectation(description: "Returning PCM packet published")
      controller.onUpdate = { update in
        switch update.message {
        case let message where message.hasPrefix("Waiting"): ready.fulfill()
        case "first PCM barrier":
          XCTAssertTrue(update.audioPresent)
          XCTAssertEqual(update.audioActivityRMS, paired ? 0.125 : 0.5)
          XCTAssertEqual(update.audioActivityPeak, paired ? 0.25 : 0.5)
          XCTAssertEqual(update.audioPackets, 1)
          XCTAssertEqual(update.audioSamples, 8)
          XCTAssertEqual(update.audioBytes, 32)
          XCTAssertEqual(update.audioSampleRate, 44_100)
          first.fulfill()
        case "interruption barrier":
          XCTAssertFalse(update.audioPresent)
          XCTAssertTrue(update.audioInterrupted)
          XCTAssertEqual(update.audioActivityRMS, 0)
          XCTAssertEqual(update.audioActivityPeak, 0)
          XCTAssertEqual(update.audioPackets, 1)
          XCTAssertEqual(update.audioSamples, 8)
          XCTAssertEqual(update.audioBytes, 32)
          lost?.fulfill()
        case "resumed PCM barrier":
          XCTAssertTrue(update.audioPresent)
          XCTAssertFalse(update.audioInterrupted)
          XCTAssertEqual(update.audioActivityRMS, 0.125)
          XCTAssertEqual(update.audioPackets, 2)
          XCTAssertEqual(update.audioSamples, 16)
          XCTAssertEqual(update.audioBytes, 64)
          XCTAssertEqual(update.audioDrops, 0, "Intentional PCM interruption does not count as a packet loss")
          resumed?.fulfill()
        default: break
        }
      }
      defer { controller.onUpdate = nil; controller.stop() }
      controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
        pipelineEnabled: false, previewEnabled: false)
      wait(for: [ready], timeout: 1)
      let bytes = [Float](repeating: -0.5, count: 8).withUnsafeBytes { Data($0) }
      let packet = try CaptureAudioPacket(planes: [bytes], sampleFrameCount: 8, format: audio, packetTime: .zero)
      XCTAssertFalse(controller.audioMeterTap.isMetering)
      XCTAssertTrue(source.submit(.rawAudio(packet)))
      if paired {
        XCTAssertTrue(source.submit(.media(CaptureMediaInfo(timecode: nil, pairedFrameSequence: nil,
          audioDeclaration: .present(audio), audioPacketTime: .zero, audioClockInstance: source.context.clockBindings.audio,
          sampleFrameCount: 8, byteCount: 32, peaks: [0.25], rms: [0.125]))))
      }
      XCTAssertTrue(source.submit(.event(.info("first PCM barrier"))))
      wait(for: [first], timeout: 1)
      guard let lost, let resumed else { continue }
      XCTAssertTrue(source.submit(.event(.audioInterrupted(reason: "Fixture mic lost"))))
      XCTAssertTrue(source.submit(.event(.info("interruption barrier"))))
      wait(for: [lost], timeout: 1)
      let returningBytes = [Float](repeating: 0.125, count: 8).withUnsafeBytes { Data($0) }
      let returning = try CaptureAudioPacket(planes: [returningBytes], sampleFrameCount: 8,
        format: audio, packetTime: CMTime(value: 4, timescale: 1))
      XCTAssertTrue(source.submitGroup([.event(.audioResumed), .rawAudio(returning), .event(.info("resumed PCM barrier"))]))
      wait(for: [resumed], timeout: 1)
      XCTAssertEqual(controller.audioMeterTap.counters.metered, 0)
    }
  }

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

  func testAbsentAudioEpochClearsLiveStatusWhileVideoContinues() throws {
    let duration = CMTime(value: 1, timescale: 30)
    let video = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(duration))
    let audio = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    let source = FakeCaptureSession(format: video, audio: .present(audio))
    let feed = FeedID(rawValue: "absent-audio-epoch")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    let ready = expectation(description: "Source ready")
    let firstPCM = expectation(description: "First PCM published")
    let absent = expectation(description: "Audio absence published with no further media")
    let continuing = expectation(description: "Video continued through audio epoch")
    let returned = expectation(description: "New epoch PCM appears in the live meter")
    var awaitingAbsence = false
    controller.onUpdate = { update in
      if update.message.hasPrefix("Waiting") { ready.fulfill() }
      if update.message == "PCM barrier" && !awaitingAbsence {
        XCTAssertTrue(update.audioPresent)
        XCTAssertEqual(update.audioActivityRMS, 0.5)
        firstPCM.fulfill()
      }
      if awaitingAbsence, update.audioInterrupted {
        awaitingAbsence = false
        XCTAssertFalse(update.audioPresent)
        XCTAssertNil(update.audioPacketTime)
        XCTAssertEqual(update.audioActivityRMS, 0)
        XCTAssertEqual(update.audioActivityPeak, 0)
        XCTAssertEqual(update.audioChannels, 0)
        XCTAssertEqual(update.audioSampleRate, 0)
        XCTAssertEqual(update.audioPackets, 1)
        absent.fulfill()
      }
      if update.message == "ongoing video barrier" {
        XCTAssertEqual(update.frames, 1)
        XCTAssertFalse(update.audioPresent)
        XCTAssertEqual(update.audioPackets, 1)
        XCTAssertEqual(update.audioSamples, 4_800)
        XCTAssertEqual(update.audioBytes, 19_200)
        continuing.fulfill()
      }
      if update.message == "new PCM barrier" {
        XCTAssertTrue(update.audioPresent)
        XCTAssertEqual(update.audioActivityPeak, 1)
        XCTAssertEqual(update.audioPackets, 2)
        returned.fulfill()
      }
    }
    defer { controller.onUpdate = nil; controller.stop() }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 1)
    let attachment = AudioMeterTap.Attachment(tap: controller.audioMeterTap)
    var callbacks = SourceRecordingCallbackAdapter.Callbacks(video: { _, _, _, _ in true },
      audio: { _ in false }, rawAudio: { _, _, _, _, _ in false })
    callbacks.preparedEpoch = source.context.epochID
    XCTAssertTrue(controller.setRecordingCallbacks(feedID: feed, callbacks: callbacks))
    controller.audioMeterTap.beginTake()
    let bytes = [Float](repeating: 0.5, count: 4_800).withUnsafeBytes { Data($0) }
    let packet = try CaptureAudioPacket(planes: [bytes], sampleFrameCount: 4_800, format: audio, packetTime: .zero)
    XCTAssertTrue(source.submitGroup([.rawAudio(packet), .event(.info("PCM barrier"))]))
    wait(for: [firstPCM], timeout: 1)
    controller.audioMeterTap.waitUntilMetered()
    let priorMeter = try XCTUnwrap(attachment.meter)
    priorMeter.flush()
    XCTAssertEqual(priorMeter.snapshot().frameCount, 4_800)
    awaitingAbsence = true
    XCTAssertTrue(source.submit(.event(.audioFormatChanged(.absent))))
    wait(for: [absent], timeout: 1)
    XCTAssertFalse(priorMeter === attachment.meter)
    XCTAssertEqual(attachment.meter?.snapshot().frameCount, 0)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image),
      kCVReturnSuccess)
    let context = source.context
    XCTAssertTrue(source.submitGroup([
      .frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)), CaptureFrameInfo(epochID: context.epochID,
        formatSignature: context.formatSignature, presentationTime: duration, duration: duration, signalValid: true, timecode: nil)),
      .event(.info("ongoing video barrier")),
    ]))
    wait(for: [continuing], timeout: 1)
    // The detached take's writer can finish later. New source PCM must feed
    // the live meter immediately without reaching that take's summary.
    controller.audioMeterTap.pauseTake(false)
    XCTAssertTrue(source.submit(.event(.audioFormatChanged(.present(audio)))))
    let loud = [Float](repeating: 1, count: 4_800).withUnsafeBytes { Data($0) }
    let newPacket = try CaptureAudioPacket(planes: [loud], sampleFrameCount: 4_800, format: audio, packetTime: duration)
    XCTAssertTrue(source.submitGroup([.rawAudio(newPacket), .event(.info("new PCM barrier"))]))
    wait(for: [returned], timeout: 1)
    controller.audioMeterTap.waitUntilMetered()
    let summary = try XCTUnwrap(controller.audioMeterTap.endTake())
    XCTAssertEqual(summary.duration, 0.1, accuracy: 0.000001)
    XCTAssertLessThan(summary.maximumTruePeak, -2)
  }

  func testVariableCadenceFrameRateCapKeepsItsPhaseAcrossDurationChanges() throws {
    let short = CMTime(value: 1, timescale: 60)
    let long = CMTime(value: 1, timescale: 25)
    let nominal = CMTime(value: 1, timescale: 30)
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210,
      rate: .variable(nominal: nominal, shortest: short, longest: long))
    for cap in [false, true] {
      let source = FakeCaptureSession(format: format)
      let feed = FeedID(rawValue: "cadence-cap-\(cap)")
      var services = CaptureServices.registryBridge(feedID: feed, makeSession: { _ in source })
      let prepared = expectation(description: "Variable-rate camera contract checked once")
      prepared.assertForOverFulfill = true
      services.preNegotiate = { configuration, _, _ in
        XCTAssertEqual(configuration.duration, nominal)
        prepared.fulfill()
      }
      let controller = CaptureController(services: services)
      controller.setCameraOutputEnabled(false)
      var config = PipelineConfiguration(downscale: false, convertTo420: false, reduceFrameRate: cap)
      config.frameRateTarget = .fps30
      let ready = expectation(description: "Variable-cadence source ready")
      controller.onUpdate = { update in
        if update.message.hasPrefix("Waiting") { ready.fulfill() }
      }
      defer { controller.onUpdate = nil; controller.stop() }
      controller.start(feedID: feed, deviceID: "fake:fixture", configuration: config, pipelineEnabled: true, previewEnabled: false)
      wait(for: [ready], timeout: 1)
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image),
        kCVReturnSuccess)
      let buffer = CapturedPixelBuffer(immutable: try XCTUnwrap(image))
      let context = source.context
      var pts = CMTime.zero
      for batch in 0..<6 {
        let barrier = "variable cadence batch \(batch)"
        let measured = expectation(description: barrier)
        controller.onUpdate = { update in
          guard update.message == barrier else { return }
          if batch == 5 {
            if cap {
              XCTAssertTrue((7..<12).contains(update.frames), "A 30 fps cap must survive changing source durations")
            } else {
              XCTAssertEqual(update.frames, 12)
            }
            XCTAssertEqual(update.sourceDrops, 0)
            XCTAssertEqual(update.deviceDrops, 0)
            XCTAssertEqual(update.sourceFPS, 35, accuracy: 2)
          }
          measured.fulfill()
        }
        for duration in [short, long] {
          XCTAssertTrue(source.submit(.frame(buffer, CaptureFrameInfo(epochID: context.epochID,
            formatSignature: context.formatSignature, presentationTime: pts, duration: duration,
            signalValid: true, timecode: nil))))
          pts = CMTimeAdd(pts, duration)
        }
        XCTAssertTrue(source.submit(.event(.info(barrier))))
        wait(for: [measured], timeout: 1)
      }
      wait(for: [prepared], timeout: 1)
    }
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
