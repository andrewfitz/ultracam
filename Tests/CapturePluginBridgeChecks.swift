#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CapturePluginBridgeChecks: XCTestCase {
  func testLegacyRawConsumerRetainsExplicitOwnerBeyondWrapperAndStop() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let source = FakeCapturePlugin(format: format, audio: .absent).makeSession() as! FakeCaptureSession
    let consumer = BridgeImageConsumer()
    let bridge = CaptureServicesBridge(makeSession: { _ in source })
    try bridge.start(deviceID: "fake:fixture", timing: .automatic,
      callbacks: CaptureLegacyCallbacks(frame: { image, _, _, _ in consumer.hold(image) }))
    weak var owner: NSObject?
    try autoreleasepool {
      var made: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &made), kCVReturnSuccess)
      let image = try XCTUnwrap(made)
      let storage = NSObject()
      owner = storage
      let context = source.context
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: .zero, duration: format.rate.nominal, signalValid: true, timecode: nil)
      XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: image, retaining: storage), info)))
    }
    bridge.stop()
    // Only the asynchronous legacy consumer's raw CVPixelBuffer remains.
    XCTAssertTrue(consumer.hasImage)
    XCTAssertNotNil(owner, "Raw CV consumers must keep the SDK storage lease alive")
    autoreleasepool { consumer.releaseImage() }
    XCTAssertNil(owner, "The lease must release when the final raw CV reference releases")
  }
  func testSynchronousStartupCallbackCanReadCounters() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let source = SynchronousDeclarationSession(format: format)
    let bridge = CaptureServicesBridge(makeSession: { _ in source })
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      do {
        try bridge.start(deviceID: "fake:fixture", timing: .automatic,
          callbacks: CaptureLegacyCallbacks(typed: { _ in _ = bridge.deviceDroppedFrames }))
        bridge.stop()
        completed.signal()
      } catch { XCTFail("Unexpected startup error: \(error)") }
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
  }
  func testCountersRemainReadableWhileStopDrainsCallback() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let source = FakeCapturePlugin(format: format, audio: .absent).makeSession() as! FakeCaptureSession
    let observed = ObservedStopSession(source: source)
    let bridge = CaptureServicesBridge(makeSession: { _ in observed })
    let entered = DispatchSemaphore(value: 0)
    let readCounters = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    try bridge.start(deviceID: "fake:fixture", timing: .automatic,
      callbacks: CaptureLegacyCallbacks(typed: { delivery in
        if case .event(.info("read counters")) = delivery.payload {
          entered.signal()
          _ = readCounters.wait(timeout: .now() + 2)
          _ = bridge.deviceDroppedFrames
          completed.signal()
        }
      }))
    XCTAssertTrue(source.submit(.event(.info("read counters"))))
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().async { bridge.stop(); stopped.signal() }
    // Stop has entered its session quiescence barrier while the callback is held.
    XCTAssertEqual(observed.stopEntered.wait(timeout: .now() + 1), .success)
    readCounters.signal()
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(stopped.wait(timeout: .now() + 1), .success)
  }
  func testMediaOnlyPreservesIndependentPacketClockAndStopBarrier() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let plugin = FakeCapturePlugin(format: format, audio: .absent)
    let source = plugin.makeSession() as! FakeCaptureSession
    let result = BridgePacketTimes()
    let bridge = CaptureServicesBridge(makeSession: { _ in source })
    try bridge.start(deviceID: "fake:fixture", timing: .automatic,
      callbacks: CaptureLegacyCallbacks(media: { result.append($0.audioPacketTime) }))
    let packetTime = CMTime(value: 48123, timescale: 48000)
    XCTAssertTrue(source.submit(.media(CaptureMediaInfo(timecode: nil, pairedFrameSequence: nil,
      audioDeclaration: .absent, audioPacketTime: packetTime, audioClockInstance: nil,
      sampleFrameCount: 800, byteCount: 6400, peaks: [], rms: []))))
    bridge.stop()
    XCTAssertEqual(result.values, [packetTime])
    XCTAssertFalse(source.submit(.event(.info("late"))))
    XCTAssertEqual(result.values.count, 1)
  }
  func testRejectedFrameStillPrecedesPairedAudioAndUnpairedStaysExplicit() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let source = FakeCaptureSession(format: format, audio: .present(audio))
    let recorder = BridgeDeliveries()
    let bridge = CaptureServicesBridge(makeSession: { _ in source })
    try bridge.start(deviceID: "fake:fixture", timing: .automatic,
      callbacks: CaptureLegacyCallbacks(typed: { recorder.append($0) }))
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    let context = source.context
    let frame = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: .zero, duration: format.rate.nominal, signalValid: false, timecode: nil)
    let paired = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
      format: audio, packetTime: .zero, pairedFrameSequence: 3)
    let unpaired = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
      format: audio, packetTime: CMTime(value: 1, timescale: 48000))
    XCTAssertTrue(source.submitGroup([.frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)), frame),
      .rawAudio(paired), .rawAudio(unpaired)]))
    bridge.stop()
    let values = recorder.values
    XCTAssertEqual(values.map(\.sequence), [1, 2, 3, 4, 5])
    guard values.count == 5 else { return } // The failed assertion must not crash later regression suites.
    if case .frame(_, let info) = values[2].payload { XCTAssertFalse(info.signalValid) }
    else { XCTFail("Rejected frame was lost before audio pairing") }
    if case .rawAudio(let packet) = values[3].payload { XCTAssertEqual(packet.pairedFrameSequence, 3) }
    else { XCTFail("Missing paired packet") }
    if case .rawAudio(let packet) = values[4].payload { XCTAssertNil(packet.pairedFrameSequence) }
    else { XCTFail("Missing unpaired packet") }
  }
  func testMissingPacketTimeMapsToInvalidWithoutBorrowingVideoTime() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    let source = FakeCaptureSession(format: format)
    let result = BridgePacketTimes()
    let bridge = CaptureServicesBridge(makeSession: { _ in source })
    try bridge.start(deviceID: "fake:fixture", timing: .automatic,
      callbacks: CaptureLegacyCallbacks(media: { result.append($0.audioPacketTime) }))
    XCTAssertTrue(source.submit(.media(CaptureMediaInfo(timecode: nil, pairedFrameSequence: nil,
      audioDeclaration: .absent, audioPacketTime: nil, audioClockInstance: nil,
      sampleFrameCount: 0, byteCount: 0, peaks: [], rms: []))))
    bridge.stop()
    XCTAssertFalse(try XCTUnwrap(result.values.first).isValid)
  }
}
private final class BridgeImageConsumer: @unchecked Sendable {
  private let lock = NSLock()
  private var image: CVPixelBuffer?
  func hold(_ value: CVPixelBuffer) { lock.withLock { image = value } }
  func releaseImage() { lock.withLock { image = nil } }
  var hasImage: Bool { lock.withLock { image != nil } }
}
private final class ObservedStopSession: CaptureSession, @unchecked Sendable {
  let source: FakeCaptureSession
  let stopEntered = DispatchSemaphore(value: 0)
  init(source: FakeCaptureSession) { self.source = source }
  var counters: CaptureCounters { source.counters }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    try source.start(deviceID: deviceID, timing: timing, handlers: handlers)
  }
  func stop() { stopEntered.signal(); source.stop() }
}
private final class SynchronousDeclarationSession: CaptureSession, @unchecked Sendable {
  let source: FakeCaptureSession
  let format: SourceFormat
  init(format: SourceFormat) { self.format = format; source = FakeCaptureSession(format: format) }
  var counters: CaptureCounters { source.counters }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    handlers.deliver(CaptureDelivery(sequence: 0,
      epochID: CaptureEpochID(sessionID: UUID(), epoch: 0), formatSignature: format.signature,
      clockBindings: CaptureClockBindings(video: ClockInstanceID(), audio: nil), mappingRevision: 0,
      payload: .event(.audioFormatChanged(.absent))))
    try source.start(deviceID: deviceID, timing: timing, handlers: handlers)
  }
  func stop() { source.stop() }
}
private final class BridgePacketTimes: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [CMTime] = []
  func append(_ time: CMTime) { lock.withLock { stored.append(time) } }
  var values: [CMTime] { lock.withLock { stored } }
}
private final class BridgeDeliveries: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [CaptureDelivery] = []
  func append(_ value: CaptureDelivery) { lock.withLock { stored.append(value) } }
  var values: [CaptureDelivery] { lock.withLock { stored } }
}
#endif
