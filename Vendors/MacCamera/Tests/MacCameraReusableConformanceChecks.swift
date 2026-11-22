#if CAPTURE_LIFECYCLE_TESTS
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class MacCameraReusableConformanceChecks: XCTestCase {
  func testIdentifiesDevicesByUIDAndExcludesPublishedOutputs() {
    XCTAssertFalse(MacCameraCapturePlugin.includes(uid: ""))
    XCTAssertFalse(MacCameraCapturePlugin.includes(uid: VirtualCameraDescriptor.deviceUID(for: .feed, feedID: "default")))
    XCTAssertFalse(MacCameraCapturePlugin.includes(uid: VirtualCameraDescriptor.deviceUID(for: .program)))
    XCTAssertFalse(MacCameraCapturePlugin.includes(uid: VirtualCameraDescriptor.deviceUID(for: .feed, feedID: "camera/2")))
    let uid = "USB:1234"
    XCTAssertTrue(MacCameraCapturePlugin.includes(uid: uid))
    XCTAssertEqual(MacCameraCapturePlugin.id(for: uid), "maccamera:USB:1234")
  }

  func testDuplicateDeviceIdentityRemainsQuarantinedAfterRemovalAndRelaunch() throws {
    let suite = "ultracam.macCamera.identity-test.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = NSObject()
    let second = NSObject()
    let uid = "fixture-camera"
    let id = MacCameraCapturePlugin.id(for: uid)
    let plugin = MacCameraCapturePlugin(identityDefaults: defaults)
    let sameObject = ObjectIdentifier(first)
    plugin.observeFixtureIdentities([(uid, sameObject), (uid, sameObject)])
    XCTAssertEqual(plugin.unavailableDeviceError(id), .unavailable("The assigned Mac Camera is disconnected."))
    plugin.observeFixtureIdentities([(uid, sameObject), (uid, ObjectIdentifier(second))])
    plugin.observeFixtureIdentities([(uid, ObjectIdentifier(second))])
    let quarantined = plugin.unavailableDeviceError(id)
    XCTAssertTrue(quarantined.localizedDescription.contains("same device ID"))
    let restarted = MacCameraCapturePlugin(identityDefaults: defaults)
    restarted.observeFixtureIdentities([(uid, ObjectIdentifier(second))])
    XCTAssertEqual(restarted.unavailableDeviceError(id), quarantined)
  }

  func testSerializedStopBarrier() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    try PluginConformanceHarness.serializedStopBarrier(session: session,
      start: { session.startFixture(handlers: $0) },
      emit: {
        do { session.deliverFixtureFrame(try Self.sample(at: CMTime(value: 1, timescale: 1))) }
        catch { XCTFail("Fixture sample creation failed: \(error)") }
      })
  }

  func testDeinitializingSessionKeepsClaimUntilTeardownFinishes() throws {
    let plugin = MacCameraCapturePlugin()
    let id = MacCameraCapturePlugin.id(for: "claim-fixture")
    let entered = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    var first: MacCameraCaptureSession? = MacCameraCaptureSession(plugin: plugin)
    try first?.claimFixture(deviceID: id) {
      entered.signal()
      _ = finish.wait(timeout: .now() + 3)
    }
    weak let retired = first
    let storage = SessionReleaseBox(first)
    first = nil
    DispatchQueue.global().async {
      storage.releaseSession()
      stopped.signal()
    }
    defer { finish.signal() }
    XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
    XCTAssertNil(retired)
    let replacement = MacCameraCaptureSession(plugin: plugin)
    XCTAssertThrowsError(try replacement.claimFixture(deviceID: id))
    finish.signal()
    XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
    XCTAssertNoThrow(try replacement.claimFixture(deviceID: id))
    replacement.stop()
  }

  func testRetiredClaimCannotPublishIntoReplacementStatus() throws {
    let plugin = MacCameraCapturePlugin()
    let id = MacCameraCapturePlugin.id(for: "status-fixture")
    let diagnostics = DeviceDiagnostics(counters: CaptureCounters(), temperatureCelsius: nil,
      signalPresent: nil, hostTimeMapped: false, vendorFields: [])
    let session = MacCameraCaptureSession(plugin: plugin)
    let token = UUID()
    try plugin.beginSession(id, token: token, owner: session)
    plugin.endSession(id, token: token)
    let replacement = UUID()
    try plugin.beginSession(id, token: replacement, owner: session)
    defer { plugin.endSession(id, token: replacement) }
    let current = CaptureDeviceStatus(availability: .inUseHere)
    plugin.publishSessionStatus(current, id: id, diagnostics: diagnostics, token: replacement)
    plugin.publishSessionStatus(CaptureDeviceStatus(availability: .free), id: id, diagnostics: diagnostics, token: token)
    plugin.endSession(id, token: token)
    XCTAssertEqual(plugin.status(deviceID: id), current)
  }

  func testNativeFramePassesSharedTranscriptOracle() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let recorder = MacCameraConformanceRecorder()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    let time = CMTime(value: 137, timescale: 30)
    let sample = try Self.sample(at: time)
    session.deliverFixtureFrame(sample)
    session.stop()
    let transcript = recorder.values
    var oracle = PluginConformanceHarness.Transcript()
    for delivery in transcript { try oracle.accept(delivery) }
    let frames = transcript.compactMap { delivery -> (CapturedPixelBuffer, CaptureFrameInfo)? in
      if case .frame(let frame, let info) = delivery.payload { return (frame, info) }
      return nil
    }
    XCTAssertEqual(frames.count, 1)
    let (frame, info) = try XCTUnwrap(frames.first)
    XCTAssertTrue(frame.value === CMSampleBufferGetImageBuffer(sample))
    XCTAssertEqual(info.presentationTime, time)
    XCTAssertThrowsError(try oracle.accept(try XCTUnwrap(transcript.last)))
    session.deliverFixtureFrame(try Self.sample(at: CMTimeAdd(time, CMTime(value: 1, timescale: 30))))
    XCTAssertEqual(recorder.values.count, transcript.count)
  }

  func testPendingVideoEpochUsesFirstPacketOfNewAudioFormat() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let recorder = MacCameraConformanceRecorder()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    let first = try Self.packet(rate: 48_000, milliseconds: 10_000)
    let changed = try Self.packet(rate: 44_100, milliseconds: 10_034)
    let continued = try Self.packet(rate: 44_100, milliseconds: 10_044)
    session.deliverFixtureAudio(first)
    session.deliverFixtureFrame(try Self.sample(at: CMTime(value: 300, timescale: 30)))
    session.reportFixtureDrop(kCMSampleBufferDroppedFrameReason_Discontinuity as String)
    session.deliverFixtureAudio(changed)
    session.deliverFixtureFrame(try Self.sample(at: CMTime(value: 301, timescale: 30)))
    session.deliverFixtureAudio(continued)
    session.deliverFixtureFrame(try Self.sample(at: CMTime(value: 302, timescale: 30)))

    var oracle = PluginConformanceHarness.Transcript()
    for delivery in recorder.values { try oracle.accept(delivery) }
    let declarations = Self.audioDeclarations(recorder.values)
    XCTAssertEqual(declarations.map(\.format), [.present(first.format), .present(changed.format)])
    let packets = Self.audioPackets(recorder.values)
    XCTAssertEqual(packets.map { $0.packet.packetTime }, [first.packetTime, changed.packetTime, continued.packetTime])
    XCTAssertEqual(packets.map(\.epoch), [declarations.first?.epoch, declarations.last?.epoch, declarations.last?.epoch])
  }

  func testInterruptedMicrophoneOverlapStartsANewEpoch() throws {
    let session = MacCameraCaptureSession(plugin: MacCameraCapturePlugin())
    let recorder = MacCameraConformanceRecorder()
    defer { session.stop() }
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    let expected = try Self.packet(rate: 48_000, milliseconds: 10_000)
    let overlapping = try Self.packet(rate: 48_000, milliseconds: 10_005)
    session.deliverFixtureAudio(expected)
    session.deliverFixtureFrame(try Self.sample(at: CMTime(value: 300, timescale: 30)))
    session.interruptFixtureAudio()
    session.deliverFixtureAudio(overlapping)
    session.deliverFixtureFrame(try Self.sample(at: CMTime(value: 301, timescale: 30)))

    var oracle = PluginConformanceHarness.Transcript()
    for delivery in recorder.values { try oracle.accept(delivery) }
    let packets = Self.audioPackets(recorder.values)
    XCTAssertEqual(packets.map { $0.packet.packetTime }, [expected.packetTime, overlapping.packetTime])
    XCTAssertNotEqual(packets.first?.epoch, packets.last?.epoch)
    XCTAssertFalse(recorder.values.contains { if case .event(.audioResumed) = $0.payload { return true }; return false })
  }

  private static func packet(rate: Int, milliseconds: Int64) throws -> CaptureAudioPacket {
    let format = try SourceAudioFormat(sampleRate: Double(rate), channels: 1, sample: .float32,
      interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
    return try CaptureAudioPacket(ownedInterleavedPCM: Data(count: rate / 100 * 4), sampleFrameCount: rate / 100,
      format: format, packetTime: CMTime(value: milliseconds, timescale: 1_000))
  }

  private static func audioDeclarations(_ values: [CaptureDelivery])
    -> [(epoch: CaptureEpochID, format: SourceAudioDeclaration)] {
    values.compactMap { delivery in
      if case .event(.audioFormatChanged(let format)) = delivery.payload { return (delivery.epochID, format) }
      return nil
    }
  }

  private static func audioPackets(_ values: [CaptureDelivery]) -> [(epoch: CaptureEpochID, packet: CaptureAudioPacket)] {
    values.compactMap { delivery in
      if case .rawAudio(let packet) = delivery.payload { return (delivery.epochID, packet) }
      return nil
    }
  }

  private static func sample(at time: CMTime) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
      nil, &pixelBuffer), kCVReturnSuccess)
    let image = try XCTUnwrap(pixelBuffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil,
      imageBuffer: image, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
}

private final class SessionReleaseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var session: MacCameraCaptureSession?

  init(_ session: MacCameraCaptureSession?) { self.session = session }
  func releaseSession() { lock.withLock { session = nil } }
}

private final class MacCameraConformanceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CaptureDelivery] = []
  var values: [CaptureDelivery] { lock.withLock { storage } }
  func append(_ value: CaptureDelivery) { lock.withLock { storage.append(value) } }
}
#endif
