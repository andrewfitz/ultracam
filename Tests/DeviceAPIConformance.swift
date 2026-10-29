#if ULTRACAM_TEST_SUPPORT
import Foundation
import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class DeviceAPIConformance: XCTestCase {
  func testReusableCaptureLifecycleFactory() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    try PluginConformanceHarness.captureLifecycle(CaptureConformanceFactory(name: "fake", deviceID: "fake:fixture",
      makeSession: { FakeCaptureSession(format: format) }, stimulate: { session in
        guard let fake = session as? FakeCaptureSession else { throw PluginError.failed("Wrong fixture") }
        _ = fake.submit(.event(.info("conformance stimulus")))
      }))
  }
  @MainActor func testReusableControlLifecycleFactory() async throws {
    let camera = ControlCamera(pluginID: "fake", id: "fake:camera", name: "Fixture", transport: .network,
      address: "fixture", fingerprint: nil)
    let descriptor = VendorDescriptor(id: "fake", displayName: "Fixture", badgeText: "TEST", signalHint: nil,
      sdkVersion: nil, sdkPresent: true)
    try await PluginConformanceHarness.controlLifecycle(make: { FakeControlPlugin(descriptor: descriptor, cameras: [camera]) }, camera: camera)
  }
  func testReusableTranscriptRejectsDuplicateAndLateEpochDeliveries() throws {
    let source = try fixture()
    let recorder = CaptureDeliveryRecorder()
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    XCTAssertTrue(source.submit(.event(.discontinuity)))
    source.stop()
    let deliveries = recorder.values
    var transcript = PluginConformanceHarness.Transcript()
    for delivery in deliveries { try transcript.accept(delivery) }
    XCTAssertThrowsError(try transcript.accept(try XCTUnwrap(deliveries.last)))
    let old = try XCTUnwrap(deliveries.first)
    let late = CaptureDelivery(sequence: UInt64(deliveries.count + 1), epochID: old.epochID,
      formatSignature: old.formatSignature, clockBindings: old.clockBindings, mappingRevision: old.mappingRevision, payload: old.payload)
    XCTAssertThrowsError(try transcript.accept(late))
  }
  @MainActor func testReusableDiscoveryChecksDriverCapabilityTruth() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let plugin = FakeCapturePlugin(format: format, audio: .absent)
    try PluginConformanceHarness.captureDiscovery(plugin)
    plugin.setConnected(true)
    try PluginConformanceHarness.captureDiscovery(plugin)
  }
  func testReusableLifecycleRejectsLateCallbackFixture() throws {
    let broken = LateCallbackConformanceFixture()
    XCTAssertThrowsError(try PluginConformanceHarness.captureLifecycle(CaptureConformanceFactory(
      name: "intentionally broken", deviceID: "broken:fixture", makeSession: { broken },
      stimulate: { _ in broken.emit() })))
  }
  func testReusableStopBarrierOnFakeCapture() throws {
    let session = try fixture()
    try PluginConformanceHarness.serializedStopBarrier(session: session,
      start: { try session.start(deviceID: "fake:fixture", timing: .automatic, handlers: $0) },
      emit: { _ = session.submit(.event(.info("stop barrier"))) })
  }
  private func fixture() throws -> FakeCaptureSession {
    FakeCaptureSession(format: try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000))))
  }
  func testCaptureHostTimeIsAnIndependentFrameValue() throws {
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let original = CaptureFrameInfo(epochID: epoch, formatSignature: "fixture", presentationTime: .zero,
      duration: CMTime(value: 1001, timescale: 60000), signalValid: true, timecode: nil,
      hostTimeReference: .presentationEnd, captureHostTime: CMTime(value: 123456, timescale: 1000))
    var copy = original
    copy.captureHostTime = CMTime(value: 999, timescale: 1)
    XCTAssertEqual(original.captureHostTime, CMTime(value: 123456, timescale: 1000))
    XCTAssertNotEqual(copy.captureHostTime, original.captureHostTime)
    XCTAssertEqual(original.hostTimeReference, .presentationEnd)
    let legacy = CaptureFrameInfo(epochID: epoch, formatSignature: "fixture", presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30), signalValid: true, timecode: nil)
    XCTAssertNil(legacy.captureHostTime)
  }
  func testFrameHostTimestampReferenceDefaultsToStartAndPreservesExplicitEnd() throws {
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let duration = CMTime(value: 1001, timescale: 60000)
    let start = CaptureFrameInfo(epochID: epoch, formatSignature: "fixture", presentationTime: .zero,
      duration: duration, signalValid: true, timecode: nil)
    let end = CaptureFrameInfo(epochID: epoch, formatSignature: "fixture", presentationTime: .zero,
      duration: duration, signalValid: true, timecode: nil, hostTimeReference: .presentationEnd)
    XCTAssertEqual(start.hostTimeReference, .presentationStart)
    XCTAssertEqual(end.hostTimeReference, .presentationEnd)
    XCTAssertNoThrow(try start.validate())
    XCTAssertNoThrow(try end.validate())
  }
  func testDeclarationsSequenceAndIdempotentStart() throws {
    let source = try fixture()
    let deliveries = CaptureDeliveryRecorder()
    try source.start(deviceID: "fake:fixture", timing: .automatic,
      handlers: CaptureHandlers(deliver: { deliveries.append($0) }))
    try source.start(deviceID: "fake:fixture", timing: .automatic,
      handlers: CaptureHandlers(deliver: { _ in XCTFail("Repeated start replaced original handler") }))
    XCTAssertTrue(source.submit(.event(.info("fixture"))))
    source.stop()
    let values = deliveries.values
    XCTAssertEqual(values.map(\.sequence), [1, 2, 3])
    if case .event(.formatChanged) = values[0].payload {} else { XCTFail("Missing initial video declaration") }
    if case .event(.audioFormatChanged(.absent)) = values[1].payload {} else { XCTFail("Missing initial audio declaration") }
    XCTAssertTrue(values.allSatisfy { $0.epochID == values[0].epochID })
    XCTAssertFalse(source.submit(.event(.info("after stop"))))
    XCTAssertThrowsError(try source.start(deviceID: "fake:fixture", timing: .automatic,
      handlers: CaptureHandlers(deliver: { _ in })))
    XCTAssertEqual(source.counters.currentBacklog, 0)
  }
  func testStopBeforeStartAndFreshSessionIdentity() throws {
    let stopped = try fixture()
    stopped.stop()
    stopped.stop()
    XCTAssertThrowsError(try stopped.start(deviceID: "fake:fixture", timing: .automatic,
      handlers: CaptureHandlers(deliver: { _ in })))
    let recorder = CaptureDeliveryRecorder()
    for _ in 0..<2 {
      let source = try fixture()
      try source.start(deviceID: "fake:fixture", timing: .automatic,
        handlers: CaptureHandlers(deliver: { recorder.append($0) }))
      source.stop()
    }
    XCTAssertNotEqual(recorder.values[0].epochID.sessionID, recorder.values[2].epochID.sessionID)
  }
  @MainActor func testCommandControlledHotplugObservesCompleteSnapshotsAndCancels() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 30000)))
    let plugin = FakeCapturePlugin(format: format, audio: .absent)
    let received = DeviceSnapshotRecorder()
    let observation = plugin.observeDevices { received.values.append($0.devices.map(\.id)) }
    plugin.setConnected(true)
    plugin.setConnected(false)
    observation.cancel()
    plugin.setConnected(true)
    XCTAssertEqual(received.values, [[], ["fake:fixture"], []])
    _ = plugin.makeSession()
    _ = plugin.makeSession()
    XCTAssertEqual(plugin.sessions.count, 2)
  }
  @MainActor func testDistinctSyntheticDevicesCanStartIndependentSessions() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 30000)))
    let ids = ["fake:fixture-a", "fake:fixture-b"]
    let plugin = FakeCapturePlugin(format: format, audio: .absent, deviceIDs: ids)
    plugin.setConnected(true)
    XCTAssertEqual(try plugin.devices().map(\.id), ids)
    let sessions = ids.map { _ in plugin.makeSession() }
    defer { sessions.forEach { $0.stop() } }
    for (id, session) in zip(ids, sessions) {
      XCTAssertNoThrow(try session.start(deviceID: id, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in })))
    }
  }
  func testCommandControlledPluginStartsWithoutADevice() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 30000)))
    let plugin = FakeCapturePlugin(format: format, audio: .absent)
    XCTAssertTrue(try plugin.devices().isEmpty, "Synthetic hardware must be connected explicitly")
  }
  func testMappingRevisionAndCallbackContextRemainConsistent() throws {
    let source = try fixture()
    let recorder = CaptureDeliveryRecorder()
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { delivery in
      _ = source.context // Must be callable from the serialized delivery stream.
      recorder.append(delivery)
    }))
    let context = source.context
    let update = CaptureClockMappingUpdate(epochID: context.epochID, clockID: context.clockBindings.video,
      revision: 1, effectiveSequence: context.nextSequence + 1,
      mapping: try ClockMapping(sourceAnchor: .zero, hostAnchor: CMTime(value: 10, timescale: 1), rate: .one))
    XCTAssertTrue(source.submit(.event(.clockMappingChanged(update))))
    XCTAssertTrue(source.submit(.event(.info("mapped"))))
    source.stop()
    XCTAssertEqual(recorder.values.last?.mappingRevision, 1)
    XCTAssertEqual(recorder.values.last?.epochID, context.epochID)
    XCTAssertEqual(recorder.values.last?.formatSignature, context.formatSignature)
  }
  func testIndependentAudioBindingAndAudioChangeStartEpoch() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .deviceClock)
    let source = FakeCaptureSession(format: format, audio: .present(audio))
    let recorder = CaptureDeliveryRecorder()
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    let initial = source.context
    XCTAssertNotNil(initial.clockBindings.audio)
    XCTAssertNotEqual(initial.clockBindings.audio, initial.clockBindings.video)
    XCTAssertTrue(source.submit(.event(.audioFormatChanged(.absent))))
    source.stop()
    XCTAssertEqual(recorder.values.count, 4)
    XCTAssertEqual(recorder.values.last?.epochID.epoch, 1)
    XCTAssertNil(recorder.values.last?.clockBindings.audio)
    XCTAssertEqual(recorder.values.last?.formatSignature, initial.formatSignature)
  }
  func testFormatAndClockResetPublishNewEpochDeclarations() throws {
    let source = try fixture()
    let recorder = CaptureDeliveryRecorder()
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    let initial = source.context
    let changed = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 30000)))
    XCTAssertTrue(source.submit(.event(.formatChanged(changed))))
    XCTAssertTrue(source.submit(.event(.discontinuity)))
    source.stop()
    let values = recorder.values
    XCTAssertEqual(values.count, 7)
    XCTAssertEqual(values[2].epochID.epoch, initial.epochID.epoch + 1)
    XCTAssertEqual(values[2].formatSignature, changed.signature)
    XCTAssertEqual(values.last?.epochID.epoch, initial.epochID.epoch + 2)
    XCTAssertEqual(source.context.formatSignature, changed.signature)
  }
  func testAdmissionBudgetRejectsWholeGroupBeforeRetention() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let source = FakeCaptureSession(format: format, maximumPendingDeliveries: 2)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { delivery in
      if delivery.sequence == 1 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
    }))
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(source.submitGroup([.event(.info("one")), .event(.info("two"))]))
    XCTAssertEqual(source.counters.maximumBacklog, 2)
    release.signal()
    source.stop()
  }
  func testStopWaitsForActiveDeliveryAndRejectsLaterAdmission() throws {
    let source = try fixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { delivery in
      if case .event(.info("block")) = delivery.payload {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
    }))
    XCTAssertTrue(source.submit(.event(.info("block"))))
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().async { source.stop(); stopped.signal() }
    XCTAssertEqual(stopped.wait(timeout: .now() + 0.02), .timedOut)
    release.signal()
    XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
    XCTAssertFalse(source.submit(.event(.info("late"))))
  }
  func testPublishedBufferRetainsStorageOwnerAfterStop() throws {
    let source = try fixture()
    let recorder = CaptureDeliveryRecorder()
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    var owner: NSObject? = NSObject()
    weak var weakOwner = owner
    var wrapper: CapturedPixelBuffer? = CapturedPixelBuffer(immutable: try XCTUnwrap(image), retaining: owner)
    owner = nil
    source.stop()
    XCTAssertNotNil(weakOwner)
    XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(wrapper).value), 8)
    wrapper = nil
    XCTAssertNotNil(weakOwner, "A raw pixel-buffer consumer still owns the storage lease")
    image = nil
    XCTAssertNil(weakOwner)
    weakOwner = nil
  }
  func testRejectsFrameFromAnotherEpoch() throws {
    let source = try fixture()
    try source.start(deviceID: "fake:fixture", timing: .automatic, handlers: CaptureHandlers(deliver: { _ in }))
    defer { source.stop() }
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    let info = CaptureFrameInfo(epochID: CaptureEpochID(sessionID: UUID(), epoch: 0), formatSignature: source.context.formatSignature,
      presentationTime: .zero, duration: CMTime(value: 1001, timescale: 60000), signalValid: true, timecode: nil)
    XCTAssertFalse(source.submit(.frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)), info)))
  }
  func testConcurrentAdmissionIsSerializedAndStopDrains() throws {
    let source = try fixture()
    let recorder = CaptureDeliveryRecorder()
    try source.start(deviceID: "fake:fixture", timing: .automatic,
      handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    DispatchQueue.concurrentPerform(iterations: 100) { _ in
      _ = source.submitGroup([.event(.info("first")), .event(.info("second"))])
    }
    source.stop()
    XCTAssertEqual(recorder.values.count, 202)
    XCTAssertEqual(recorder.values.map(\.sequence), Array(1...202).map(UInt64.init))
    XCTAssertEqual(source.counters.currentBacklog, 0)
  }
}

@MainActor private final class DeviceSnapshotRecorder { var values: [[String]] = [] }

private final class CaptureDeliveryRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CaptureDelivery] = []
  func append(_ value: CaptureDelivery) { lock.withLock { storage.append(value) } }
  var values: [CaptureDelivery] { lock.withLock { storage } }
}
private final class LateCallbackConformanceFixture: CaptureSession, @unchecked Sendable {
  private var handler: CaptureHandlers?
  private var stopped = false
  var counters: CaptureCounters { CaptureCounters() }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    if stopped { throw PluginError.invalidState("Stopped") }
    if handler == nil { handler = handlers }
  }
  func stop() { stopped = true } // Intentionally fails to close delivery.
  func emit() {
    handler?.deliver(CaptureDelivery(sequence: 1, epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
      formatSignature: "broken", clockBindings: CaptureClockBindings(video: ClockInstanceID()), mappingRevision: 0,
      payload: .event(.info("intentionally late"))))
  }
}
#endif
