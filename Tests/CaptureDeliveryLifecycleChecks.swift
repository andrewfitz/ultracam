#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest

@objcMembers final class CaptureDeliveryLifecycleChecks: XCTestCase {
  func testStoppedOrSupersededProcessedDeliveryRechecksEveryExternalConsumerBoundary() throws {
    guard MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) == true else { throw XCTSkip("Metal 4 required") }
    for epochChange in [false, true] {
      for stage in LifecycleStage.allCases {
        let observation = LifecycleObservation(held: stage)
        let fixture = try LifecycleCaptureFixture(observation: observation)
        defer { observation.release.signal(); fixture.stop() }
        try fixture.start(self)
        try fixture.frame()
        XCTAssertEqual(observation.entered.wait(timeout: .now() + 3), .success)
        if epochChange {
          let changed = try SourceFormat(width: 256, height: 144, pixel: .v210, rate: .constant(VideoContract.fastDuration))
          XCTAssertTrue(fixture.source.submit(.event(.formatChanged(changed))))
          fixture.source.stop()
        } else { fixture.controller.stop() }
        observation.release.signal()
        XCTAssertEqual(observation.finished.wait(timeout: .now() + 3), .success)
        for later in LifecycleStage.allCases where later.rawValue > stage.rawValue {
          XCTAssertEqual(observation.count(later), 0, "\(later) crossed \(epochChange ? "epoch change" : "stop") after blocking \(stage)")
        }
        XCTAssertEqual(observation.programs, 0)
        fixture.stop()
      }
    }
  }

  func testExplicitMeasuredFrameEndHostTimeWinsOverArrivalFallback() throws {
    guard MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) == true else { throw XCTSkip("Metal 4 required") }
    let observation = LifecycleObservation(held: nil)
    let fixture = try LifecycleCaptureFixture(observation: observation)
    defer { fixture.stop() }
    try fixture.start(self)
    try fixture.frame(hostTime: CMTime(value: 100, timescale: 1))
    XCTAssertEqual(observation.finished.wait(timeout: .now() + 3), .success)
    let pts = try XCTUnwrap(observation.previewTime)
    XCTAssertEqual(CMTimeCompare(pts, CMTimeSubtract(CMTime(value: 100, timescale: 1), VideoContract.fastDuration)), 0)
  }
}

private enum LifecycleStage: Int, CaseIterable, Sendable { case monitor, processingReport, preview, camera }
private final class LifecycleObservation: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private let held: LifecycleStage?
  private var counts: [LifecycleStage: Int] = [:]
  private var programCount = 0
  private var time: CMTime?
  init(held: LifecycleStage?) { self.held = held }
  func invoke(_ stage: LifecycleStage) {
    lock.withLock { counts[stage, default: 0] += 1 }
    if held == stage { entered.signal(); _ = release.wait(timeout: .now() + 3) }
  }
  func notePreview(_ sample: CMSampleBuffer) { lock.withLock { time = CMSampleBufferGetPresentationTimeStamp(sample) }; invoke(.preview) }
  func noteProgram() { lock.withLock { programCount += 1 } }
  func count(_ stage: LifecycleStage) -> Int { lock.withLock { counts[stage, default: 0] } }
  var programs: Int { lock.withLock { programCount } }
  var previewTime: CMTime? { lock.withLock { time } }
}
private final class LifecycleMonitor: MonitorFrameSink, @unchecked Sendable {
  let observation: LifecycleObservation
  init(_ observation: LifecycleObservation) { self.observation = observation }
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64, untouched: Bool) {
    observation.invoke(.monitor)
  }
  func invalidate(rejectingCaptureGeneration: UInt64?) {}
}
private final class LifecycleCaptureFixture {
  let source: FakeCaptureSession
  let controller: CaptureController
  let feed = FeedID(rawValue: "processed-delivery-audit")
  init(observation: LifecycleObservation) throws {
    let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    source = FakeCaptureSession(format: format, audio: .absent)
    let source = self.source
    var services = CaptureServices.registryBridge(feedID: feed, makeSession: { _ in source })
    services.connect = { _, _ in }
    services.connectWithSource = { _, _, _ in }
    services.disconnect = {}
    services.preview = { observation.notePreview($0) }
    services.send = { _ in observation.invoke(.camera); return true }
    services.didProcess = { _, _ in observation.invoke(.processingReport) }
    services.hostTime = { CMTime(value: 999, timescale: 1) }
    controller = CaptureController(services: services)
    controller.setMonitorSink(LifecycleMonitor(observation))
    controller.onProcessedFrame = { _, _ in observation.noteProgram() }
    controller.setAuditHooksForTesting(CaptureController.AuditHooks(deliveryFinished: { observation.finished.signal() }))
  }
  func start(_ test: XCTestCase) throws {
    let ready = test.expectation(description: "Processed source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture",
      configuration: PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false, reduceFrameRate: false),
      pipelineEnabled: false, previewEnabled: true)
    test.wait(for: [ready], timeout: 3)
    controller.onUpdate = nil
  }
  func frame(hostTime: CMTime? = nil) throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
    let context = source.context
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: try XCTUnwrap(image)),
      CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: CMTime(value: 20, timescale: 1), duration: VideoContract.fastDuration,
        signalValid: true, timecode: nil, hostTimeReference: .presentationEnd, captureHostTime: hostTime))))
  }
  func stop() { controller.onUpdate = nil; controller.stop() }
}
#endif
