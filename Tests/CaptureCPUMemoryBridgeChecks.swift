#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import XCTest

@objcMembers final class CaptureCPUMemoryBridgeChecks: XCTestCase {
  func testCPUIngestAndFollowingEventRemainOrderedWithNativePixelIdentity() throws {
    try checkBridge(allowCopy: false, vmEvidence: true)
  }
  func testExplicitCompatibilityCopyIsCountedAndNeverChangesPixelIdentity() throws {
    try checkBridge(allowCopy: true, vmEvidence: false)
  }
  func testStopCancelsLateGPUCompletionAndQueuedMetadata() throws {
    let source = CPUMemoryBridgeSession()
    let fixture = try auditFixture()
    let pending = CPUBridgePendingCompletion()
    let unexpected = expectation(description: "No asynchronous publication after stop"); unexpected.isInverted = true
    let bridge = CaptureServicesBridge(makeSession: { _ in source }, cpuIngest: { _, done in pending.set(done) })
    try bridge.start(deviceID: "cpu:fixture", timing: .automatic,
      callbacks: CaptureLegacyCallbacks(typed: { _ in unexpected.fulfill() }))
    source.emit(fixture.delivery)
    source.emit(CaptureDelivery(sequence: 2, epochID: fixture.delivery.epochID, formatSignature: "fixture",
      clockBindings: fixture.delivery.clockBindings, mappingRevision: 0, payload: .event(.info("queued"))))
    bridge.stop()
    pending.finish(.success(fixture.output))
    wait(for: [unexpected], timeout: 0.1)
  }

  func testFailedStartCancelsStalledGPUCompletion() throws {
    let source = CPUMemoryBridgeSession()
    let fixture = try auditFixture()
    source.startDelivery = fixture.delivery
    source.failStart = true
    let pending = CPUBridgePendingCompletion()
    let unexpected = expectation(description: "No publication after failed start"); unexpected.isInverted = true
    let bridge = CaptureServicesBridge(makeSession: { _ in source }, cpuIngest: { _, done in pending.set(done) })
    XCTAssertThrowsError(try bridge.start(deviceID: "cpu:fixture", timing: .automatic,
      callbacks: CaptureLegacyCallbacks(typed: { _ in unexpected.fulfill() })))
    pending.finish(.success(fixture.output))
    wait(for: [unexpected], timeout: 0.1)
  }

  func testTerminalTimingRejectionSuppressesOlderGPUCompletion() throws {
    let source = CPUMemoryBridgeSession()
    let fixture = try auditFixture()
    let pending = CPUBridgePendingCompletion()
    let late = expectation(description: "No normal frame after terminal error"); late.isInverted = true
    let terminal = expectation(description: "Terminal error")
    let bridge = CaptureServicesBridge(makeSession: { _ in source }, cpuIngest: { _, done in pending.set(done) })
    try bridge.start(deviceID: "cpu:fixture", timing: .automatic, callbacks: CaptureLegacyCallbacks(typed: { delivery in
      if case .event(.fatal) = delivery.payload { terminal.fulfill() }
      else { late.fulfill() }
    }))
    source.emit(fixture.delivery)
    let info = CaptureFrameInfo(epochID: fixture.delivery.epochID, formatSignature: "fixture",
      presentationTime: .zero, duration: .invalid, signalValid: true, timecode: nil)
    source.emit(CaptureDelivery(sequence: 2, epochID: info.epochID, formatSignature: "fixture",
      clockBindings: fixture.delivery.clockBindings, mappingRevision: 0, payload: .cpuMemory(fixture.frame, info)))
    pending.finish(.success(fixture.output))
    wait(for: [terminal, late], timeout: 0.1)
    bridge.stop()
  }

  func testFullQueueTerminalErrorSuppressesAcceptedOlderWork() throws {
    let source = CPUMemoryBridgeSession()
    let fixture = try auditFixture()
    let pending = CPUBridgePendingCompletion()
    let late = expectation(description: "No prior work after full queue terminal"); late.isInverted = true
    let terminal = expectation(description: "Queue terminal")
    let bridge = CaptureServicesBridge(makeSession: { _ in source }, cpuIngest: { _, done in pending.set(done) })
    try bridge.start(deviceID: "cpu:fixture", timing: .automatic, callbacks: CaptureLegacyCallbacks(typed: { delivery in
      if case .event(.fatal) = delivery.payload { terminal.fulfill() }
      else { late.fulfill() }
    }))
    source.emit(fixture.delivery)
    for sequence in 2...33 {
      source.emit(CaptureDelivery(sequence: UInt64(sequence), epochID: fixture.delivery.epochID,
        formatSignature: "fixture", clockBindings: fixture.delivery.clockBindings, mappingRevision: 0,
        payload: .event(.info("queued"))))
    }
    pending.finish(.success(fixture.output))
    wait(for: [terminal, late], timeout: 0.1)
    bridge.stop()
  }

  func testRoundedOwnershipFailureAllowsOnlyValidatedCountedFallback() throws {
    for readable in [true, false] {
      let source = CPUMemoryBridgeSession()
      let fixture = try auditFixture(readable: readable)
      let done = expectation(description: "Fallback result")
      let bridge = CaptureServicesBridge(makeSession: { _ in source },
        compatibilityPolicy: { _ in .init(allowCPUConversion: true) }, cpuIngest: { _, complete in
          complete(.failure(NoCopyIngestError.roundedRangeOutsideAllocation))
        })
      try bridge.start(deviceID: "cpu:fixture", timing: .automatic, callbacks: CaptureLegacyCallbacks(typed: { delivery in
        if case .frame = delivery.payload { XCTAssertTrue(readable) }
        else if case .event(.fatal) = delivery.payload { XCTAssertFalse(readable) }
        else { XCTFail("Unexpected result") }
        done.fulfill()
      }))
      source.emit(fixture.delivery)
      wait(for: [done], timeout: 2)
      XCTAssertEqual(bridge.ingestCPUCopyFrames, readable ? 1 : 0)
      bridge.stop()
    }
  }

  private func auditFixture(readable: Bool = true) throws -> (frame: CapturedCPUMemoryFrame, delivery: CaptureDelivery, output: CapturedPixelBuffer) {
    let storage = CPUMemoryFixtureStorage()
    let pointer = storage.pointer.advanced(by: 17)
    let frame = CapturedCPUMemoryFrame(pointer: pointer, width: 1, height: 1, bytesPerRow: 4,
      allocation: NoCopyIngestAllocation(baseAddress: pointer, length: readable ? 4 : 3, generation: 1),
      inspectVM: { _, _ in nil }, frameOwner: storage)
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let info = CaptureFrameInfo(epochID: epoch, formatSignature: "fixture", presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30), signalValid: true, timecode: nil)
    let delivery = CaptureDelivery(sequence: 1, epochID: epoch, formatSignature: "fixture",
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), mappingRevision: 0, payload: .cpuMemory(frame, info))
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    return (frame, delivery, CapturedPixelBuffer(immutable: try XCTUnwrap(image)))
  }

  private func checkBridge(allowCopy: Bool, vmEvidence: Bool) throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    let source = CPUMemoryBridgeSession()
    let storage = CPUMemoryFixtureStorage()
    let frame = CapturedCPUMemoryFrame(pointer: storage.pointer, width: 1, height: 1, bytesPerRow: 4,
      allocation: NoCopyIngestAllocation(baseAddress: storage.pointer, length: storage.length, generation: 1),
      inspectVM: { base, length in vmEvidence ? NoCopyVMRange(baseAddress: base, length: length, generation: 1) : nil },
      frameOwner: storage)
    let bridge = CaptureServicesBridge(makeSession: { _ in source },
      compatibilityPolicy: { _ in RecordingCompatibilityPolicy(allowCPUConversion: allowCopy) })
    let observed = CPUMemoryBridgeOrder()
    let delivered = expectation(description: "Frame and following metadata in source order")
    try bridge.start(deviceID: "cpu:fixture", timing: .automatic, callbacks: CaptureLegacyCallbacks(typed: { delivery in
      switch delivery.payload {
      case .frame(let buffer, let info):
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer.value), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer.value))
        XCTAssertEqual(info.formatSignature, "unregistered-bgra-fixture")
        XCTAssertEqual(info.captureHostTime, CMTime(value: 123, timescale: 1))
        XCTAssertEqual((CVBufferCopyAttachment(buffer.value, DeviceAPI.captureHostTimeAttachmentKey as CFString, nil) as? NSNumber)?.doubleValue, 123)
        observed.append("frame")
      case .event(.info("after CPU frame")):
        observed.append("event"); if observed.complete() { delivered.fulfill() }
      case .event(.fatal(let reason)): XCTFail(reason); if observed.complete() { delivered.fulfill() }
      default: break
      }
    }))
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
    let bindings = CaptureClockBindings(video: ClockInstanceID())
    let info = CaptureFrameInfo(epochID: epoch, formatSignature: "unregistered-bgra-fixture",
      presentationTime: .zero, duration: CMTime(value: 1, timescale: 30), signalValid: true, timecode: nil, captureHostTime: CMTime(value: 123, timescale: 1))
    source.emit(CaptureDelivery(sequence: 1, epochID: epoch, formatSignature: info.formatSignature,
      clockBindings: bindings, mappingRevision: 0, payload: .cpuMemory(frame, info)))
    source.emit(CaptureDelivery(sequence: 2, epochID: epoch, formatSignature: info.formatSignature,
      clockBindings: bindings, mappingRevision: 0, payload: .event(.info("after CPU frame"))))
    wait(for: [delivered], timeout: 5)
    bridge.stop()
    XCTAssertEqual(observed.values, ["frame", "event"])
    XCTAssertEqual(bridge.ingestCPUCopyFrames, allowCopy ? 1 : 0)
    // This bridge proof preserves BGRA identity. The production source catalog
    // separately refuses it until all downstream BGRA routes are declared.
  }
}
private final class CPUMemoryFixtureStorage: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer
  let length = Int(getpagesize())
  init() {
    pointer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: length)
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: length)
  }
  deinit { pointer.deallocate() }
}
private final class CPUMemoryBridgeOrder: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String] = []
  private var completed = false
  func complete() -> Bool { lock.withLock { if completed { return false }; completed = true; return true } }
  func append(_ value: String) { lock.withLock { entries.append(value) } }
  var values: [String] { lock.withLock { entries } }
}
private final class CPUMemoryBridgeSession: CaptureSession, @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: CaptureHandlers?
  var startDelivery: CaptureDelivery?
  var failStart = false
  var counters: CaptureCounters { CaptureCounters() }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    lock.withLock { self.handlers = handlers }
    if let startDelivery { handlers.deliver(startDelivery) }
    if failStart { throw PluginError.failed("Injected partial start failure") }
  }
  func stop() { lock.withLock { handlers = nil } }
  func emit(_ delivery: CaptureDelivery) { lock.withLock { handlers }?.deliver(delivery) }
}
private final class CPUBridgePendingCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: (@Sendable (Result<CapturedPixelBuffer, Error>) -> Void)?
  func set(_ value: @escaping @Sendable (Result<CapturedPixelBuffer, Error>) -> Void) { lock.withLock { completion = value } }
  func finish(_ result: Result<CapturedPixelBuffer, Error>) {
    let callback = lock.withLock { () -> (@Sendable (Result<CapturedPixelBuffer, Error>) -> Void)? in
      defer { completion = nil }; return completion
    }
    callback?(result)
  }
}
#endif
