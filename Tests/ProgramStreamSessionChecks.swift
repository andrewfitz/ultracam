#if ULTRACAM_TEST_SUPPORT
@preconcurrency import AVFoundation
import XCTest

@MainActor @objcMembers final class ProgramStreamSessionChecks: XCTestCase {
  private final class Storage: ProgramStreamCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
    func remove() throws { lock.withLock { data = nil } }
  }

  private final class Sink: ProgramStreamPublishing, @unchecked Sendable {
    let lock = NSLock()
    var connects = 0
    var formats: [ProgramStreamFormat] = []
    var startupFailure: ProgramStreamPublisherError?
    var holdConnect = false
    var pendingConnect: CheckedContinuation<Void, Never>?
    var closeDelay: TimeInterval = 0
    var closed = 0
    var encodedFPS: Int?
    var statisticsDelay: TimeInterval = 0
    var reportsUpload = true
    var lose: (@Sendable (ProgramStreamDisconnectReason) -> Void)?
    var epochs: [(time: CMTime, includesAudio: Bool)] = []
    var pictures: [CMTime] = []
    var pcm: [(UInt64, [Float])] = []
    var pcmRight: [[Float]] = []
    func connect(server: String, key: String, format: ProgramStreamFormat, onDisconnect: @escaping @Sendable (ProgramStreamDisconnectReason) -> Void) async throws {
      try lock.withLock {
        connects += 1
        if let startupFailure { throw startupFailure }
        lose = onDisconnect
        formats.append(format)
      }
      await withCheckedContinuation { continuation in
        lock.withLock {
          if holdConnect { pendingConnect = continuation }
          else { continuation.resume() }
        }
      }
    }
    func setMediaEpoch(_ epoch: CMTime, includesAudio: Bool) {
      lock.withLock { epochs.append((epoch, includesAudio)) }
    }
    func appendVideo(_ sample: CMSampleBuffer) { lock.withLock { pictures.append(sample.presentationTimeStamp) } }
    func appendAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
      let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
      let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
      lock.withLock {
        pcm.append((time.hostTime, samples))
        pcmRight.append(right)
      }
    }
    func statistics() async -> ProgramStreamTransportStatistics {
      let delay = lock.withLock { statisticsDelay }
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      return lock.withLock {
        .init(connected: true, bytesSent: reportsUpload ? UInt64(pictures.count * 1000) : 0,
          encodedVideoFramesPerSecond: encodedFPS)
      }
    }
    func close() async {
      let delay = lock.withLock { closeDelay }
      try? await Task.sleep(for: .seconds(delay))
      let pending = lock.withLock {
        closed += 1
        holdConnect = false
        defer { pendingConnect = nil }
        return pendingConnect
      }
      pending?.resume()
    }
  }

  private func defaults() -> UserDefaults {
    let name = "org.ultracam.tests.program-stream.\(UUID())"
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }
  private func config(audio: Bool = false) -> ProgramStreamConfiguration {
    .init(name: "Studio", server: "rtmps://ingest.invalid/live?token=private", audioFeedID: audio ? "a" : nil)
  }
  private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !predicate() {
      if Date() >= deadline { XCTFail("Timed out", file: file, line: line); return }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
  }
  func testSettingsIsolationRestoreAndCredentialReplacement() throws {
    let store = Storage(), suite = defaults()
    let session = ProgramStreamSession(defaults: suite, credentials: store)
    var value = config()
    try session.save(value, key: "secret-stream-key")
    XCTAssertFalse(suite.dictionaryRepresentation().description.contains("ingest.invalid"))
    XCTAssertFalse(suite.dictionaryRepresentation().description.contains("secret-stream-key"))
    let restored = ProgramStreamSession(defaults: suite, credentials: store)
    XCTAssertEqual(restored.configuration, value)
    XCTAssertEqual(restored.snapshot.phase, .idle)
    value.name = "Next show"
    try restored.save(value, key: "")
    value.server = "rtmps://replacement.invalid/live"
    XCTAssertThrowsError(try restored.save(value, key: ""))
    value.server = "rtmps://ingest.invalid:100000/live"
    XCTAssertThrowsError(try restored.save(value, key: "example"))
    value.server = "rtmps://ingest.invalid:9999999999999999999999/live"
    XCTAssertThrowsError(try restored.save(value, key: "example"))
    value.server = "http://replacement.invalid/live"
    XCTAssertThrowsError(try restored.save(value, key: "example"))
    try restored.resetConfiguration()
    XCTAssertNil(try store.read())
  }
  func testLegacyDestinationRestoresOriginalFormatAndUpgradesWithoutReenteringKey() throws {
    let suite = defaults(), store = Storage()
    suite.set(UUID().uuidString, forKey: "programStream.credentialAccount")
    let legacy = #"{"configuration":{"name":"Studio","server":"rtmps://ingest.invalid/live","audioFeedID":"camera-2","firstChannel":2},"key":"legacy-secret"}"#
    try store.write(Data(legacy.utf8))
    let restored = ProgramStreamSession(defaults: suite, credentials: store)
    XCTAssertEqual(restored.configuration.format, ProgramStreamFormat(size: .hd1080, rate: .fps30, codec: .h264, videoMbps: 6))
    XCTAssertEqual(restored.configuration.audioFeedID, "camera-2")
    XCTAssertEqual(restored.configuration.firstChannel, 2)
    XCTAssertTrue(restored.snapshot.configured)
    XCTAssertEqual(restored.snapshot.phase, .idle)
    var upgraded = restored.configuration
    upgraded.format = .init(size: .dci4K, rate: .fps5994, codec: .hevcMain10, videoMbps: 32)
    upgraded.format.colorSpaceID = "rec2020-hlg-video"
    upgraded.format.scalingMode = .crop
    try restored.save(upgraded, key: "")
    let next = ProgramStreamSession(defaults: suite, credentials: store)
    XCTAssertEqual(next.configuration, upgraded)
    XCTAssertEqual(next.snapshot.format, upgraded.format)
    XCTAssertTrue(String(decoding: try XCTUnwrap(store.read()), as: UTF8.self).contains("legacy-secret"))
    XCTAssertFalse(suite.dictionaryRepresentation().description.contains("legacy-secret"))
  }

  func testInvalidOrMissingKeychainRecordRequiresSetupWithoutExposingItsPayload() throws {
    let suite = defaults(), store = Storage()
    suite.set(UUID().uuidString, forKey: "programStream.credentialAccount")
    let missing = ProgramStreamSession(defaults: suite, credentials: store)
    XCTAssertTrue(missing.snapshot.needsSetup)
    XCTAssertFalse(missing.snapshot.configured)
    let invalid = #"{"configuration":{"name":"Studio","server":"rtmps://ingest.invalid/live?private-endpoint","firstChannel":-2},"key":"private-key"}"#
    try store.write(Data(invalid.utf8))
    let restored = ProgramStreamSession(defaults: suite, credentials: store)
    XCTAssertFalse(restored.snapshot.configured)
    XCTAssertTrue(restored.snapshot.needsSetup)
    XCTAssertThrowsError(try restored.start()) {
      XCTAssertEqual($0.localizedDescription, "Save the stream destination again.")
    }
    try restored.save(config(), key: "replacement")
    XCTAssertTrue(restored.snapshot.configured)
  }

  func testStartValidatesTheCurrentCredentialConfiguration() throws {
    let suite = defaults(), store = Storage()
    let first = ProgramStreamSession(defaults: suite, credentials: store)
    try first.save(config(), key: "example")
    let second = ProgramStreamSession(defaults: suite, credentials: store)
    var edited = config(audio: true)
    edited.firstChannel = 6
    try second.save(edited, key: "")
    try first.start { XCTAssertEqual($0, edited) }
    defer { first.stop() }
    XCTAssertEqual(first.snapshot.audioFeedID, edited.audioFeedID)
    XCTAssertEqual(first.snapshot.firstChannel, 6)
  }

  func testSavingAnInvalidFormatPreservesTheLastValidDestination() throws {
    let suite = defaults(), store = Storage()
    let session = ProgramStreamSession(defaults: suite, credentials: store)
    let original = config()
    try session.save(original, key: "fixture-key")
    let saved = try XCTUnwrap(store.read())
    var invalid = original
    for bitrate in [-1, 0, 51, Int.max] {
      invalid.format.videoMbps = bitrate
      XCTAssertThrowsError(try session.save(invalid, key: ""))
      XCTAssertEqual(try store.read(), saved)
      XCTAssertEqual(session.configuration, original)
    }
    invalid = original
    for colour in ["rec2020-pq-video", "unrecognized"] {
      invalid.format.colorSpaceID = colour
      XCTAssertThrowsError(try session.save(invalid, key: ""))
      XCTAssertEqual(try store.read(), saved)
    }
    for bitrate in [1, 50] {
      var boundary = original
      boundary.format.videoMbps = bitrate
      try session.save(boundary, key: "")
      XCTAssertEqual(ProgramStreamSession(defaults: suite, credentials: store).configuration, boundary)
    }
  }

  func testFormatCatalogRoundTripsEveryRateAndCodecAndRejectsMalformedSavedFormats() throws {
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    for size in ProgramStreamFormat.sizes {
      for rate in ProgramStreamFormat.rates {
        for codec in ProgramStreamVideoCodec.allCases {
          var destination = config()
          destination.format = .init(size: size, rate: rate, codec: codec, videoMbps: 23)
          XCTAssertEqual(try decoder.decode(ProgramStreamConfiguration.self, from: encoder.encode(destination)), destination)
        }
      }
    }
    var invalid = config()
    invalid.format.videoMbps = 0
    XCTAssertThrowsError(try decoder.decode(ProgramStreamConfiguration.self, from: encoder.encode(invalid)))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(config())) as? [String: Any])
    var format = try XCTUnwrap(object["format"] as? [String: Any])
    format["codec"] = "unrecognized"
    object["format"] = format
    let raw = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(try decoder.decode(ProgramStreamConfiguration.self, from: raw))
  }

  func testAudioPreflightFailureDoesNotOpenConnection() throws {
    let sink = Sink()
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      preflightTimeout: 0.04)
    try session.save(config(audio: true), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 0)
    XCTAssertTrue(session.snapshot.needsSetup)
  }
  func testMissingProgramPictureFailsBeforePublish() throws {
    let sink = Sink()
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      preflightTimeout: 0.04)
    try session.save(config(), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), false)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertFalse(session.snapshot.needsSetup)
    XCTAssertTrue(session.snapshot.lastError?.contains("No Program picture") == true)
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 0)
  }

  func testSourceSizeWaitsForResolutionAndRemainsFixedThroughReconnect() throws {
    let sink = Sink()
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [0.02])
    defer { session.stop() }
    var source = config()
    source.format.size = .source
    try session.save(source, key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
    XCTAssertEqual(session.snapshot.phase, .connecting)
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 0)
    session.resolveSourceSize(.uhd4K)
    session.resolveSourceSize(.hd720)
    waitUntil { sink.lock.withLock { sink.connects == 1 } }
    sink.lock.withLock { sink.lose }?(.connectionClosed)
    waitUntil { sink.lock.withLock { sink.connects == 2 } }
    XCTAssertEqual(sink.lock.withLock { sink.formats.map(\.size) }, [.uhd4K, .uhd4K])
    XCTAssertEqual(session.configuration.format.size, .source)
  }

  func testConnectDeadlineClosesAndIgnoresTheLateSuccessfulConnect() throws {
    let sink = Sink()
    sink.lock.withLock { sink.holdConnect = true }
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [0.02], connectionTimeout: 0.08)
    defer { session.stop() }
    try session.save(config(), key: "example")
    try session.start()
    let push = session.makeVideoHandler()
    push(try video(48_000), true)
    waitUntil { sink.lock.withLock { sink.pendingConnect != nil } }
    let stale = try XCTUnwrap(sink.lock.withLock { sink.lose })
    waitUntil { sink.lock.withLock { sink.closed == 1 && sink.connects == 2 } }
    XCTAssertEqual(session.snapshot.lastInterruption, .connectionTimedOut)
    stale(.rejected)
    for slot in 1...6 {
      push(try video(48_000 + Int64(slot) * 1_600), true)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    waitUntil { session.snapshot.phase == .streaming }
  }

  func testPublisherConnectionTimeoutRetainsItsSpecificReason() throws {
    let sink = Sink()
    sink.lock.withLock { sink.startupFailure = .timedOut }
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [])
    try session.save(config(), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertEqual(session.snapshot.lastInterruption, .connectionTimedOut)
    XCTAssertTrue(session.snapshot.lastError?.contains("did not respond in time") == true)
  }

  func testPublisherHealthTimeoutsIdentifyTheStalledStage() throws {
    let reasons: [ProgramStreamDisconnectReason] = [.videoDeliveryStalled, .encoderFailure, .uploadStalled]
    for reason in reasons {
      let sink = Sink()
      sink.lock.withLock {
        sink.encodedFPS = reason == .encoderFailure ? 0 : 30
        sink.reportsUpload = reason != .uploadStalled
      }
      let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
        retryDelays: [], progressTimeout: 0.6)
      try session.save(config(), key: "example")
      try session.start()
      let push = session.makeVideoHandler()
      push(try video(48_000), true)
      waitUntil { sink.lock.withLock { sink.connects == 1 } }
      for i in 1...40 where session.snapshot.active {
        if reason != .videoDeliveryStalled { push(try video(48_000 + Int64(i) * 1_600), true) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      }
      XCTAssertEqual(session.snapshot.phase, .failed)
      XCTAssertEqual(session.snapshot.lastInterruption, reason)
      XCTAssertFalse(session.snapshot.pictureFresh)
    }
  }

  func testStuckStatisticsAreClosedAndDoNotKeepTheSessionConnecting() throws {
    let sink = Sink()
    sink.lock.withLock { sink.statisticsDelay = 10 }
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [], progressTimeout: 0.2)
    try session.save(config(), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertEqual(session.snapshot.lastInterruption, .uploadStalled)
    waitUntil { !session.needsShutdown }
  }
  func testReconnectRejectAndIgnoreStaleCallbacks() throws {
    let sink = Sink()
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [0.04])
    try session.save(config(), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { sink.lock.withLock { sink.lose != nil } }
    let stale = try XCTUnwrap(sink.lock.withLock { sink.lose })
    stale(.connectionClosed)
    waitUntil { session.snapshot.phase == .reconnecting }
    waitUntil { sink.lock.withLock { sink.connects == 2 } }
    stale(.rejected)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    XCTAssertTrue(session.snapshot.active)
    sink.lock.withLock { sink.lose }?(.rejected)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertTrue(session.snapshot.needsSetup)
    session.stop()
    stale(.connectionClosed)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 2)
    XCTAssertEqual(session.snapshot.phase, .idle)
  }
  func testStopDuringBackoffCancelsRetryAndRejectDuringConnectDoesNotRetry() throws {
    let sink = Sink()
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [0.06])
    try session.save(config(), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { sink.lock.withLock { sink.lose != nil } }
    sink.lock.withLock { sink.lose }?(.connectionClosed)
    waitUntil { session.snapshot.phase == .reconnecting }
    session.stop()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 1)
    sink.lock.withLock { sink.startupFailure = .rejected }
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertTrue(session.snapshot.needsSetup)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 2)
  }

  func testConnectionRetriesPreserveTheInitiatingMediaOrNetworkInterruption() throws {
    for reason in [ProgramStreamDisconnectReason.audioDiscontinuity, .encoderFailure, .socketBacklog, .uploadStalled] {
      let sink = Sink()
      let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
        retryDelays: [0.03])
      try session.save(config(), key: "sensitive-test-key")
      try session.start()
      session.makeVideoHandler()(try video(48_000), true)
      waitUntil { sink.lock.withLock { sink.lose != nil } }
      sink.lock.withLock { sink.startupFailure = .unavailable }
      sink.lock.withLock { sink.lose }?(reason)
      waitUntil { session.snapshot.phase == .failed }
      XCTAssertEqual(session.snapshot.lastInterruption, reason)
      XCTAssertTrue(session.snapshot.lastError?.contains(reason.rawValue) == true)
      XCTAssertFalse(session.snapshot.lastError?.contains("sensitive-test-key") == true)
      XCTAssertEqual(sink.lock.withLock { sink.connects }, 2)
    }
  }

  func testDestinationCodecRefusalOpensSetupWithoutRetrying() throws {
    let sink = Sink()
    sink.lock.withLock { sink.startupFailure = .unsupportedCodec }
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [0.01])
    var destination = config()
    destination.format.codec = .av1
    try session.save(destination, key: "sensitive-key")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertTrue(session.snapshot.needsSetup)
    XCTAssertTrue(session.snapshot.lastError?.contains(destination.name) == true)
    XCTAssertTrue(session.snapshot.lastError?.contains("AV1") == true)
    XCTAssertTrue(session.snapshot.lastError?.contains("Streaming settings") == true)
    XCTAssertFalse(session.snapshot.lastError?.contains("sensitive-key") == true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 1)
  }

  func testHardwareEncoderUnavailableEndsSessionWithoutNetworkRetry() throws {
    let sink = Sink()
    sink.lock.withLock { sink.startupFailure = .encoderUnavailable }
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink },
      retryDelays: [0.02])
    try session.save(config(), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { session.snapshot.phase == .failed }
    XCTAssertTrue(session.snapshot.needsSetup)
    XCTAssertTrue(session.snapshot.lastError?.contains("encoder is unavailable") == true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 1)
  }

  func testNewStreamWaitsForPreviousCloseAndQuitWaitsAfterStop() throws {
    let sink = Sink()
    sink.lock.withLock { sink.closeDelay = 0.12 }
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink })
    try session.save(config(), key: "example")
    try session.start()
    session.makeVideoHandler()(try video(48_000), true)
    waitUntil { sink.lock.withLock { sink.connects == 1 } }
    session.stop()
    XCTAssertTrue(session.needsShutdown)
    try session.start()
    session.makeVideoHandler()(try video(96_000), true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    XCTAssertEqual(sink.lock.withLock { sink.connects }, 1)
    waitUntil { sink.lock.withLock { sink.connects == 2 && sink.closed == 1 } }
    session.stop()
    var quitReady = false
    Task { @MainActor in await session.shutdown(); quitReady = true }
    waitUntil { quitReady }
    XCTAssertFalse(session.needsShutdown)
    XCTAssertEqual(sink.lock.withLock { sink.closed }, 2)
  }

  func testLiveEvidenceRequiresEncodedPictureAndKeepsActiveDestinationWhenSettingsChange() throws {
    let sink = Sink()
    sink.lock.withLock { sink.encodedFPS = 0 }
    let session = ProgramStreamSession(defaults: defaults(), credentials: Storage(), makePublisher: { sink })
    defer { session.stop() }
    try session.save(config(), key: "example")
    try session.start()
    let push = session.makeVideoHandler()
    push(try video(48_000), true)
    waitUntil { sink.lock.withLock { sink.connects == 1 } }
    push(try video(49_600), true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.45))
    XCTAssertEqual(session.snapshot.phase, .connecting)
    XCTAssertFalse(session.snapshot.pictureFresh)
    sink.lock.withLock { sink.encodedFPS = 30 }
    push(try video(51_200), true)
    waitUntil { session.snapshot.phase == .streaming }
    XCTAssertTrue(session.snapshot.pictureFresh)
    XCTAssertNotNil(session.snapshot.startedAt)
    var next = config()
    next.name = "Another destination"
    try session.save(next, key: "")
    XCTAssertEqual(session.snapshot.name, "Studio")
    session.stop()
    XCTAssertEqual(session.snapshot.name, next.name)
  }

  private func video(_ index: Int64) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixel), noErr)
    let image = try XCTUnwrap(pixel)
    var description: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
      formatDescriptionOut: &description), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(value: index, timescale: 48_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
  private func tone() throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.5, count: 1600) }
    return buffer
  }

  func testAudioTapRejectsPartialOverlapAndKeepsItsSampleGrid() throws {
    let tap = ProgramStreamAudioTap(pairIndex: 0) { _, _ in }
    defer { tap.stop() }
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .int16,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 1)
    let start = 120 * Int64(48_000)
    for offset: Int64 in [0, 240, 480] {
      let packet = try CaptureAudioPacket(planes: [Data(count: 960)], sampleFrameCount: 480,
        format: format, packetTime: CMTime(value: start + offset, timescale: 48_000))
      tap.ingest(packet, epoch: epoch, pairedHostTime: nil, audioMapping: nil)
      tap.drainForTesting()
    }
    XCTAssertEqual(tap.statistics.packets, 2)
    XCTAssertEqual(tap.statistics.dropped, 1)
    XCTAssertEqual(tap.statistics.lastHostTime, CMTime(value: start + 479, timescale: 48_000))
  }

  func testAudioTapRequiresARealPacketToEstablishItsPairedClock() throws {
    let tap = ProgramStreamAudioTap(pairIndex: 0) { _, _ in }
    defer { tap.stop() }
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 1, sample: .int16,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 1)
    let host = CMTime(value: 120, timescale: 1)
    let empty = try CaptureAudioPacket(planes: [Data()], sampleFrameCount: 0, format: format, packetTime: .zero)
    let valid = try CaptureAudioPacket(planes: [Data(count: 960)], sampleFrameCount: 480,
      format: format, packetTime: CMTime(value: 480, timescale: 48_000))
    tap.ingest(empty, epoch: epoch, pairedHostTime: host, audioMapping: nil)
    tap.ingest(valid, epoch: epoch, pairedHostTime: nil, audioMapping: nil)
    tap.drainForTesting()
    XCTAssertEqual(tap.statistics.dropped, 2)
    XCTAssertEqual(tap.statistics.packets, 0)
    tap.ingest(valid, epoch: epoch, pairedHostTime: host, audioMapping: nil)
    tap.drainForTesting()
    XCTAssertEqual(tap.statistics.packets, 1)
    XCTAssertEqual(tap.statistics.lastHostTime, host)
  }
  func testMediaEpochCarriesTheProfilesAudioSetting() throws {
    for includesAudio in [false, true] {
      let media = ProgramStreamMedia(wantsAudio: includesAudio)
      let sink = Sink()
      media.attach(sink)
      for frame in 0..<5 {
        media.video(try video(48_000 + Int64(frame * 1_600)), fresh: true)
      }
      XCTAssertEqual(sink.epochs.count, 1)
      let epoch = try XCTUnwrap(sink.epochs.first)
      XCTAssertEqual(epoch.time, sink.pictures.first)
      XCTAssertEqual(epoch.includesAudio, includesAudio)
      XCTAssertEqual(sink.pcm.isEmpty, !includesAudio)
    }
  }

  func testEveryStreamCadenceEmitsExactContinuousStereoPCMIntervals() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let base: Int64 = 48_000
    let template = try video(base)
    for rate in FrameRateTarget.allCases {
      let duration = rate.duration
      let sink = Sink()
      let media = ProgramStreamMedia(wantsAudio: true)
      media.attach(sink)
      func start(_ slot: Int) -> CMTime {
        CMTimeAdd(CMTime(value: base, timescale: 48_000), CMTimeMultiply(duration, multiplier: Int32(slot)))
      }
      func sampleIndex(_ slot: Int) -> Int64 {
        // Integer-only oracle for the rounded boundary on the 48 kHz sample clock.
        let scale = Int64(duration.timescale)
        return base + (Int64(slot) * duration.value * 48_000 + scale / 2) / scale
      }
      for slot in 0..<104 {
        let first = sampleIndex(slot)
        let length = Int(sampleIndex(slot + 1) - first)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<length {
          let value = Float((first + Int64(i)) % 997) / 1024
          buffer.floatChannelData![0][i] = value
          buffer.floatChannelData![1][i] = -value
        }
        media.audio(buffer, at: CMTime(value: first, timescale: 48_000))
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start(slot), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: template,
          sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &sample), noErr)
        media.video(try XCTUnwrap(sample), fresh: true)
      }
      XCTAssertEqual(sink.pcm.count, 101, rate.title)
      for (slot, chunk) in sink.pcm.enumerated() {
        let first = sampleIndex(slot)
        let expected = (first..<sampleIndex(slot + 1)).map { Float($0 % 997) / 1024 }
        XCTAssertTrue(chunk.1 == expected, "PCM sample mismatch at \(rate.title) fps, slot \(slot)")
        XCTAssertTrue(sink.pcmRight[slot] == expected.map { -$0 }, rate.title)
        let time = CMClockMakeHostTimeFromSystemUnits(chunk.0).seconds
        XCTAssertEqual(time, Double(first) / 48_000, accuracy: 1e-7)
      }
      XCTAssertEqual(media.health.audioGaps, 0, rate.title)
      media.stop()
    }
  }

  func testFixedPCMContinuesAcrossOneToThreeMissingVideoSlots() throws {
    let base: Int64 = 48_000
    for missing in 1...3 {
      let media = ProgramStreamMedia(wantsAudio: true)
      let sink = Sink()
      media.attach(sink)
      for slot in 0..<12 {
        let pos = base + Int64(slot * 1_600)
        let buffer = try tone()
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<1_600 {
          for channel in 0..<2 { samples[channel][i] = Float(slot * 1_600 + i) / 32_768 }
        }
        media.audio(buffer, at: CMTime(value: pos, timescale: 48_000))
        if !(2..<(2 + missing)).contains(slot) {
          media.video(try video(pos), fresh: true)
        }
      }
      // The three frames retained for playout leave slot 8 as the last published picture.
      let lastPicture = try XCTUnwrap(sink.pictures.last)
      XCTAssertEqual(lastPicture, CMTime(value: base + 8 * 1_600, timescale: 48_000))
      var received = 0
      for (hostTime, data) in sink.pcm {
        let expectedStart = CMTime(value: base + Int64(received), timescale: 48_000)
        XCTAssertEqual(CMClockMakeHostTimeFromSystemUnits(hostTime).seconds, expectedStart.seconds, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(data.count, 4_096)
        let expected = (received..<(received + data.count)).map { Float($0) / 32_768 }
        XCTAssertTrue(data == expected, "Duplicate, missing or padded PCM with \(missing) missing video slots")
        received += data.count
      }
      XCTAssertEqual(received, 9 * 1_600)
      XCTAssertEqual(media.health.audioGaps, 0)
      media.stop()
    }
  }

  func testLongPictureStallBoundsRecoveryBeforeTheNextPicture() throws {
    let media = ProgramStreamMedia(wantsAudio: true)
    let sink = Sink()
    media.attach(sink)
    let base: Int64 = 48_000
    // Three retained pictures mean the final push releases slot 300 after slot 0.
    for slot in [0, 300, 301, 302, 303] {
      let pos = base + Int64(slot * 1_600)
      media.audio(try tone(), at: CMTime(value: pos, timescale: 48_000))
      media.video(try video(pos), fresh: true)
    }
    let recovered = sink.pcm.dropFirst()
    XCTAssertEqual(recovered.map { $0.1.count }.reduce(0, +), 12_000)
    XCTAssertTrue(recovered.allSatisfy { $0.1.count <= 4_096 })
    XCTAssertEqual(media.health.audioGaps, 1)
    XCTAssertFalse(media.health.missingAudio)
    let latest = try XCTUnwrap(recovered.last)
    let lastPicture = try XCTUnwrap(sink.pictures.last)
    XCTAssertEqual(CMClockMakeHostTimeFromSystemUnits(latest.0).seconds, lastPicture.seconds, accuracy: 0.00001)
    XCTAssertTrue(latest.1.allSatisfy { $0 == 0.5 })
    media.stop()
  }

  func testAudioGapCountTracksDistinctLossesInsideOnePicture() throws {
    let media = ProgramStreamMedia(wantsAudio: true)
    let sink = Sink()
    media.attach(sink)
    let base: Int64 = 48_000
    for offset in [0, 600, 1_200] {
      let buffer = try tone()
      buffer.frameLength = 400
      media.audio(buffer, at: CMTime(value: base + Int64(offset), timescale: 48_000))
    }
    for slot in 0..<4 { media.video(try video(base + Int64(slot * 1_600)), fresh: true) }
    let samples = try XCTUnwrap(sink.pcm.first).1
    XCTAssertEqual(samples, (0..<1_600).map { (400..<600).contains($0) || (1_000..<1_200).contains($0) ? 0 : 0.5 })
    XCTAssertEqual(media.health.audioGaps, 2)
    XCTAssertFalse(media.health.missingAudio)
    XCTAssertEqual(media.health.peak, 0.5)
    XCTAssertNotNil(media.health.lastVideoSentAt)
    media.attach(nil)
    XCTAssertNil(media.health.lastVideoSentAt)
    XCTAssertEqual(media.health.audioGaps, 2)
  }

  func testCommonBoundaryAudioLateAndEarlyAcrossReconnectAndOneMissedFrame() throws {
    let media = ProgramStreamMedia(wantsAudio: true)
    for early in [true, false] {
      let sink = Sink()
      media.attach(sink)
      let offset: Int64 = early ? -800 : 800
      let base: Int64 = early ? 48_000 : 96_000
      if !early { media.video(try video(base), fresh: true) }
      media.audio(try tone(), at: CMTime(value: base + offset, timescale: 48_000))
      for frame in (early ? 0 : 1)..<8 where frame != 2 {
        let sample = try video(base + Int64(frame * 1600))
        CMSetAttachment(sample, key: "org.ultracam.program-stream.feed-id" as CFString,
          value: (frame < 5 ? "first" : "second") as CFString, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        media.video(sample, fresh: true)
      }
      let samples = try XCTUnwrap(sink.pcm.first).1
      XCTAssertEqual(samples.count, 1600)
      XCTAssertTrue(samples.prefix(800).allSatisfy { $0 == (early ? 0.5 : 0) })
      XCTAssertTrue(samples.suffix(800).allSatisfy { $0 == (early ? 0 : 0.5) })
      XCTAssertEqual(sink.pcm.count, 5)
      for (slot, sound) in sink.pcm.enumerated() {
        let expected = CMTime(value: base + Int64(slot * 1_600), timescale: 48_000)
        XCTAssertEqual(CMClockMakeHostTimeFromSystemUnits(sound.0).seconds, expected.seconds, accuracy: 0.00001)
      }
      XCTAssertTrue(media.health.missingAudio)
      XCTAssertTrue(media.health.freshPicture)
      XCTAssertEqual(media.health.pictureFeedID, "first", "The pending cut has not reached the publisher yet")
      XCTAssertGreaterThan(media.health.audioGaps, 0)
      media.video(try video(base + 7 * 1600), fresh: true)
      XCTAssertEqual(sink.pictures.count, 4)
      media.attach(nil)
    }
    media.stop()
    let late = Sink()
    media.attach(late)
    media.video(try video(144_000), fresh: true)
    XCTAssertTrue(late.pictures.isEmpty)
  }
}
#endif
