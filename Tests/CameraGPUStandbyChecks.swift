#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import Metal
import XCTest

@objcMembers final class CameraGPUStandbyChecks: XCTestCase {
#if GPU_STANDBY_STANDALONE_TESTS
  // The full suite creates the process singleton in CameraContractChecks.
  // Only an isolated xctest process needs its own one-time bootstrap.
  private static let standaloneBootstrap = CameraProvider(automaticTimers: false)
  override class func setUp() { super.setUp(); _ = standaloneBootstrap }
#endif
  private final class Pending {
    var formats: [CMVideoFormatDescription] = []
    var callbacks: [@Sendable (Result<GPUStandbyImage, Error>) -> Void] = []
    func submit(_ format: CMVideoFormatDescription, completion: @escaping @Sendable (Result<GPUStandbyImage, Error>) -> Void) {
      formats.append(format); callbacks.append(completion)
    }
  }
  private func image(_ description: CMVideoFormatDescription) throws -> GPUStandbyImage {
    let size = CMVideoFormatDescriptionGetDimensions(description)
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, Int(size.width), Int(size.height), CMFormatDescriptionGetMediaSubType(description),
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made), kCVReturnSuccess)
    let result = try XCTUnwrap(made)
    for (source, destination) in [(kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimariesKey),
      (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunctionKey),
      (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrixKey)] {
      if let value = CMFormatDescriptionGetExtension(description, extensionKey: source) {
        CVBufferSetAttachment(result, destination, value, .shouldPropagate)
      }
    }
    return GPUStandbyImage(pixelBuffer: result)
  }

  func testAllPublishedSlotsAdvertiseThirteenRatesIncluding120And23976() throws {
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    XCTAssertEqual(runtime.formats.count, OutputFormatCatalog.published.count)
    XCTAssertEqual(FrameRateTarget.allCases.count, 13)
    for format in runtime.formats {
      XCTAssertTrue(DerivedOutputContract.sameDuration(format.minFrameDuration, FrameRateTarget.fps120.duration))
      XCTAssertTrue(DerivedOutputContract.sameDuration(format.maxFrameDuration, FrameRateTarget.fps23976.duration))
      XCTAssertEqual(format.validFrameDurations?.count, 13)
    }
  }

  func testStandbyAnchorsToCommon240000ClockAndKeepsLong120Cadence() throws {
    let pending = Pending()
    var now = CMTime(value: 2_400_001, timescale: 240_000)
    var times: [CMTime] = []
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
      clock: { now }, output: { sample, _, _ in times.append(CMSampleBufferGetPresentationTimeStamp(sample)) })
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting(submit: pending.submit)
      try runtime.setProperties(index: nil, frameDuration: FrameRateTarget.fps120.duration)
      try runtime.source.startStream(); runtime.emitStandby()
    }
    pending.callbacks[0](.success(try image(pending.formats[0])))
    try runtime.queue.sync {
      XCTAssertEqual(try XCTUnwrap(times.first), now, "Standby must not truncate its common-clock anchor to60000")
      let first = try XCTUnwrap(times.first)
      for index in 1...10_000 {
        now = CMTimeAdd(first, CMTimeMultiply(FrameRateTarget.fps120.duration, multiplier: Int32(index)))
        runtime.emitStandby()
      }
      XCTAssertEqual(times.count, 10_001)
      XCTAssertEqual(CMTimeSubtract(try XCTUnwrap(times.last), first), CMTimeMultiply(FrameRateTarget.fps120.duration, multiplier: 10_000))
      try runtime.source.stopStream()
    }
  }

  func testDefaultStandbyRouteIsAsynchronousGPUWithoutOptIn() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    let completed = expectation(description: "default standby GPU completion")
    var sent = 0
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
      clock: { CMTime(value: 10, timescale: 1) }, output: { _, _, _ in sent += 1; completed.fulfill() })
    try runtime.queue.sync {
      try runtime.source.startStream()
      XCTAssertTrue(runtime.gpuStandbyPreparedForTesting, "Normal source start must prepare GPU standby without test opt-in")
      runtime.emitStandby()
      XCTAssertEqual(sent, 0, "Default standby cannot synchronously fill pixels on the CPU")
    }
    wait(for: [completed], timeout: 10)
    try runtime.queue.sync { XCTAssertEqual(sent, 1); try runtime.source.stopStream() }
  }

  func testGPUCapabilityFailureRefusesConsumerStartWithoutDemandLease() throws {
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false)
    try runtime.queue.sync {
      runtime.makeGPUStandbyProducerForTesting = { throw VideoError.message("Metal 4 unavailable in capability fixture") }
      XCTAssertThrowsError(try runtime.source.startStream()) { error in
        XCTAssertTrue(error.localizedDescription.contains("Metal 4"))
      }
      XCTAssertEqual(runtime.consumers, 0, "Capability failure must occur before acquiring a consumer lease")
      XCTAssertFalse(runtime.inUse)
    }
  }

  func testProducerPauseAllowanceSuppressesStandbyAndNextFrameClearsIt() throws {
    let pending = Pending()
    var now = CMTime(value: 10, timescale: 1)
    var sent: [CMSampleBuffer] = []
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
      clock: { now }, output: { sample, _, _ in sent.append(sample) })
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting(submit: pending.submit)
      try runtime.source.startStream()
      runtime.emitStandby()
      let live = try VideoSampleFactory().sample(image(runtime.formats[0].formatDescription).pixelBuffer,
        at: now, duration: runtime.duration)
      CMSetAttachment(live, key: VideoContract.sourcePauseAllowanceAttachmentKey,
        value: NSNumber(value: 10), attachmentMode: kCMAttachmentMode_ShouldPropagate)
      XCTAssertTrue(runtime.receive(live, discontinuity: []))
    }
    pending.callbacks[0](.success(try image(pending.formats[0])))
    try runtime.queue.sync {
      now = CMTime(value: 11, timescale: 1)
      runtime.emitStandby()
      XCTAssertEqual(sent.count, 1, "A legitimate pause must not flash black after 0.5 seconds")
      now = CMTime(value: 21, timescale: 1)
      runtime.emitStandby()
      XCTAssertEqual(sent.count, 2, "Standby resumes after the bounded pause allowance")
      now = CMTime(value: 211, timescale: 10)
      let live = try VideoSampleFactory().sample(image(runtime.formats[0].formatDescription).pixelBuffer,
        at: now, duration: runtime.duration)
      XCTAssertTrue(runtime.receive(live, discontinuity: []))
      now = CMTime(value: 215, timescale: 10)
      runtime.emitStandby()
      XCTAssertEqual(sent.count, 4, "A new producer frame without an allowance clears the old pause policy")
      try runtime.source.stopStream()
    }
  }

  func testLiveArrivalWhileFillPendingDoesNotEmitStandbyOnCompletion() throws {
    let pending = Pending()
    var now = CMTime(value: 10, timescale: 1)
    var sent: [CMSampleBuffer] = []
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
      clock: { now }, output: { sample, _, _ in sent.append(sample) })
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting(submit: pending.submit)
      try runtime.source.startStream()
      runtime.emitStandby()
      XCTAssertEqual(pending.callbacks.count, 1)
      let live = try VideoSampleFactory().sample(image(runtime.formats[0].formatDescription).pixelBuffer,
        at: now, duration: runtime.duration)
      XCTAssertTrue(runtime.receive(live, discontinuity: []))
      XCTAssertEqual(sent.count, 1)
    }
    pending.callbacks[0](.success(try image(pending.formats[0])))
    runtime.queue.sync { XCTAssertEqual(sent.count, 1, "GPU completion cannot overwrite a newly arrived live frame") }
    try runtime.queue.sync {
      now = CMTime(value: 11, timescale: 1)
      runtime.emitStandby()
      XCTAssertEqual(sent.count, 2)
      XCTAssertEqual(pending.callbacks.count, 1, "Completed black can be reused after real source loss")
      try runtime.source.stopStream()
    }
  }

  func testFormatABAAndStopRestartIgnoreOldCompletionAndUseCurrentCadence() throws {
    let pending = Pending()
    var sent: [CMSampleBuffer] = []
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
      clock: { CMTime(value: 10, timescale: 1) }, output: { sample, _, _ in sent.append(sample) })
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting(submit: pending.submit)
      try runtime.source.startStream(); runtime.emitStandby()
      try runtime.setProperties(index: 1, frameDuration: nil); runtime.emitStandby()
      try runtime.setProperties(index: 0, frameDuration: nil); runtime.emitStandby()
      try runtime.source.stopStream(); try runtime.source.startStream(); runtime.emitStandby()
      try runtime.setProperties(index: nil, frameDuration: VideoContract.slowDuration)
      XCTAssertEqual(pending.callbacks.count, 1, "Format and stop generations share one outstanding fill")
    }
    pending.callbacks[0](.success(try image(pending.formats[0])))
    runtime.queue.sync { XCTAssertTrue(sent.isEmpty); XCTAssertEqual(pending.callbacks.count, 2) }
    pending.callbacks[1](.success(try image(pending.formats[1])))
    try runtime.queue.sync {
      XCTAssertEqual(sent.count, 1)
      XCTAssertTrue(DerivedOutputContract.sameDuration(CMSampleBufferGetDuration(try XCTUnwrap(sent.first)), VideoContract.slowDuration))
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(try XCTUnwrap(sent.first.flatMap(CMSampleBufferGetImageBuffer))),
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      try runtime.source.stopStream()
    }
  }

  func testFailedGPUModeNeverUsesLegacyCPUStandby() throws {
    var sent = 0
    var attempts = 0
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
      clock: { CMTime(value: 10, timescale: 1) }, output: { _, _, _ in sent += 1 })
    try runtime.queue.sync {
      runtime.enableGPUStandbyForTesting { _, _ in attempts += 1; throw VideoError.message("injected GPU refusal") }
      try runtime.source.startStream()
      for _ in 0..<5 { runtime.emitStandby() }
      XCTAssertEqual(sent, 0, "A GPU refusal must not enter the CPU standby path")
      XCTAssertEqual(attempts, 1)
      XCTAssertEqual(runtime.gpuStandbyFailuresForTesting, 1)
      XCTAssertTrue(runtime.gpuStandbyErrorForTesting?.contains("GPU refusal") == true)
      try runtime.source.stopStream()
    }
  }
  func testDefaultMetal4ProducerCompletesEveryPublishedRuntimeSlot() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      throw XCTSkip("Metal 4 hardware required; no CPU fallback")
    }
    var now = CMTime(value: 10, timescale: 1)
    var onOutput: ((CMSampleBuffer) -> Void)?
    let runtime = CameraDeviceRuntime(automaticTimers: false, createNativeProvider: false,
      clock: { now }, output: { sample, _, _ in onOutput?(sample) })
    try runtime.queue.sync {
      try runtime.source.startStream()
      XCTAssertEqual(runtime.formats.count, OutputFormatCatalog.published.count)
    }
    for index in 0..<OutputFormatCatalog.published.count {
      let completed = expectation(description: "real GPU runtime slot \(index)")
      try runtime.queue.sync {
        now = CMTime(value: Int64(10 + index), timescale: 1)
        try runtime.setProperties(index: index, frameDuration: VideoContract.fastDuration)
        let expected = DerivedOutputContract(format: runtime.formats[index].formatDescription, duration: runtime.duration)
        onOutput = { sample in
          XCTAssertNil(expected.mismatch(sample))
          completed.fulfill()
        }
        runtime.emitStandby()
      }
      wait(for: [completed], timeout: 10)
    }
    try runtime.queue.sync {
      XCTAssertTrue(runtime.gpuStandbyPreparedForTesting)
      XCTAssertEqual(runtime.gpuStandbyFailuresForTesting, 0)
      try runtime.source.stopStream()
    }
  }

}
#endif
