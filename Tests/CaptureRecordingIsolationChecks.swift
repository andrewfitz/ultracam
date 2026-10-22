import CoreMedia
import CoreVideo
import Foundation
import MonitorToolsCore
import MonitorToolsMetal
import MonitorToolsUI
import XCTest

/// In-memory synthetic recording: no encoder, device, or media files are opened.
@objcMembers final class CaptureRecordingIsolationChecks: XCTestCase {
  private final class Writer: SourceRecordingWriter {
    var samples: [CMSampleBuffer] = []  // recorder queue owned; read after Stop drains it
    var finished = false
    func start() throws {}
    func appendVideo(_ sample: CMSampleBuffer) throws { samples.append(sample) }
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws { finished = true }
  }

  /// Records the first shader-device attempt. Later retries return immediately.
  private final class FirstInitialization: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if started { return false }
      started = true
      return true
    }
  }

  private final class Harness: @unchecked Sendable {
    let lock = NSLock()
    var callback: ((CVPixelBuffer, CMTime, CMTime, Bool) -> Void)?
    var previewCount = 0
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(entered: XCTestExpectation) { self.entered = entered }
    var services: CaptureServices {
      var services = CaptureServices(
        start: { _, _, _, _ in }, stop: {},
        connect: { _, _ in }, disconnect: {}, send: { _ in true },
        preview: { _ in
          let first = self.lock.withLock {
            self.previewCount += 1
            return self.previewCount == 1
          }
          if first {
            self.entered.fulfill()
            _ = self.release.wait(timeout: .now() + 8)
          }
        })
      services.startAutomatic = { _, frames, _ in self.lock.withLock { self.callback = frames } }
      return services
    }
    func emit(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime, valid: Bool = true) {
      lock.withLock { callback }?(image, pts, duration, valid)
    }
  }

  func testRecordingAdmissionAndFinalizationIgnoreStalledPreview() throws {
    let image = try syntheticRamp()
    let entered = expectation(description: "Preview worker stalled")
    let harness = Harness(entered: entered)
    let controller = CaptureController(services: harness.services, previewRenderer: nil)
    defer {
      harness.release.signal()
      controller.onUpdate = nil
      controller.stop()
    }
    let feed = FeedID(rawValue: "recording-isolation")
    let writer = Writer()
    let config = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(
        fileURLWithPath: "/Volumes/8TB/cinesomatic-build/synthetic-isolation-unused.mov"),
      width: 3840, height: 2160)
    let recorder = try SourceRecordingCallbackAdapter(
      configuration: config, writerFactory: { writer })
    try recorder.start()
    controller.setRecordingCallbacks(feedID: feed, callbacks: recorder.callbacks)
    let started = expectation(description: "Synthetic capture ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(
      feedID: feed, deviceID: "synthetic",
      configuration:
        PipelineConfiguration(downscale: false, convertTo420: false), pipelineEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    let duration = VideoContract.fastDuration
    harness.emit(image, pts: .zero, duration: duration)
    wait(for: [entered], timeout: 3)
    let count = VideoContract.captureAdmissionLimit + 9
    for frame in 1..<count {
      // Pace at the actual source cadence; callback offers remain independent
      // of the deliberately stalled serial preview/processing worker.
      Thread.sleep(forTimeInterval: duration.seconds)
      harness.emit(
        image, pts: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration)
    }
    harness.emit(image, pts: .invalid, duration: duration)
    harness.emit(image, pts: .zero, duration: duration, valid: false)
    var malformed: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &malformed), kCVReturnSuccess
    )
    harness.emit(try XCTUnwrap(malformed), pts: .zero, duration: duration)
    // Recorder Stop drains only its own writer queue while preview stays stalled.
    try recorder.stop()
    XCTAssertEqual(recorder.state, .finished)
    XCTAssertTrue(writer.finished)
    XCTAssertEqual(writer.samples.count, count)
    XCTAssertEqual(recorder.telemetry.droppedQueueFull, 0)
    XCTAssertEqual(recorder.telemetry.droppedInvalidSample, 3)
    for (frame, sample) in writer.samples.enumerated() {
      XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === image)
      XCTAssertEqual(
        CMSampleBufferGetPresentationTimeStamp(sample),
        CMTimeMultiply(duration, multiplier: Int32(frame)))
      XCTAssertEqual(CMSampleBufferGetDuration(sample), duration)
    }
    XCTAssertEqual(harness.lock.withLock { harness.previewCount }, 1)
    controller.stop()  // invalidates admission synchronously, even with worker blocked
    harness.emit(image, pts: .zero, duration: duration)
    XCTAssertEqual(
      recorder.telemetry.droppedNotRecording, 0,
      "Stale callbacks must not reach recorder after capture Stop")
    harness.release.signal()
  }

  @MainActor func testProductionMonitorTapsPreserveRecordingAndRejectRetiredDemand() throws {
    let image = try syntheticRamp()
    let harness = Harness(entered: XCTestExpectation(description: "Unused preview gate"))
    var services = harness.services
    services.preview = nil
    let controller = CaptureController(services: services, previewRenderer: nil)
    let target = MonitorTargetID("capture-tap-integration")
    let initializing = expectation(description: "Monitor initialization held on utility worker")
    let initializationGate = DispatchSemaphore(value: 0)
    // Shader setup retries on every later frame while the device is missing.
    // Only the first attempt may block the worker and fulfill the expectation.
    let firstInitialization = FirstInitialization()
    let runtime = MonitorRuntime(sharedDevice: {
      if firstInitialization.claim() {
        initializing.fulfill()
        _ = initializationGate.wait(timeout: .now() + 5)
      }
      return nil  // deterministic shader/device failure must preserve clean fallback
    })
    let sink = MonitorCaptureSink(target: target, runtime: runtime)
    let presenter = MonitorSurfacePresenter()
    var monitor = MonitorConfiguration()
    monitor.pictureStage = .source
    monitor.toolsEnabled = true
    monitor.zebra.enabled = true
    sink.configure(monitor, consumers: [presenter], scopeVisible: false)
    controller.setMonitorSink(sink)
    let feed = FeedID(rawValue: target.rawValue)
    let writer = Writer()
    let recording = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID(feed.rawValue),
      outputURL: URL(fileURLWithPath: "/Volumes/8TB/cinesomatic-build/synthetic-tap-unused.mov"),
      width: 3840, height: 2160)
    let recorder = try SourceRecordingCallbackAdapter(
      configuration: recording, writerFactory: { writer })
    try recorder.start()
    defer {
      initializationGate.signal()
      controller.onUpdate = nil
      controller.stop()
      try? recorder.stop()
    }
    controller.setRecordingCallbacks(feedID: feed, callbacks: recorder.callbacks)
    let started = expectation(description: "Synthetic production controller ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    let bypass = PipelineConfiguration(downscale: false, convertTo420: false)
    controller.start(
      feedID: feed, deviceID: "synthetic", configuration: bypass, pipelineEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    let duration = VideoContract.fastDuration
    harness.emit(image, pts: .zero, duration: duration)
    wait(for: [initializing], timeout: 3)
    // Hide while a real capture-tap job is in flight. Its delayed completion
    // must not revive the removed consumer, and capture callbacks keep recording.
    let callbackStart = ProcessInfo.processInfo.systemUptime
    harness.emit(image, pts: duration, duration: duration)
    XCTAssertLessThan(
      ProcessInfo.processInfo.systemUptime - callbackStart, 0.5,
      "Capture callback must return while monitor initialization is blocked")
    sink.configure(monitor, consumers: [], scopeVisible: false)
    initializationGate.signal()
    pumpUntil { recorder.telemetry.appendedVideo == 2 }
    pumpFor(0.1)
    XCTAssertNil(presenter.currentStamp)
    sink.configure(monitor, consumers: [presenter], scopeVisible: false)
    harness.emit(image, pts: CMTimeMultiply(duration, multiplier: 2), duration: duration)
    pumpUntil {
      presenter.currentStamp?.sourcePTS == CMTimeMultiply(duration, multiplier: 2).seconds
    }
    let source = try XCTUnwrap(presenter.currentStamp)
    XCTAssertEqual(source.target, target)
    XCTAssertGreaterThan(source.generation, 0)
    XCTAssertGreaterThan(source.sequence, 0)
    XCTAssertGreaterThan(source.processingRevision, 0)
    // Switch to the paired Output tap and change the capture processing revision.
    monitor.pictureStage = .processedOutput
    sink.configure(monitor, consumers: [presenter], scopeVisible: false)
    controller.reconfigure(configuration: bypass, pipelineEnabled: false)
    pumpFor(0.03)
    harness.emit(image, pts: CMTimeMultiply(duration, multiplier: 3), duration: duration)
    pumpUntil {
      presenter.currentStamp?.sourcePTS == CMTimeMultiply(duration, multiplier: 3).seconds
    }
    let output = try XCTUnwrap(presenter.currentStamp)
    XCTAssertEqual(output.generation, source.generation)
    XCTAssertGreaterThan(output.sequence, source.sequence)
    XCTAssertGreaterThan(output.processingRevision, source.processingRevision)
    XCTAssertGreaterThan(output.configurationRevision, source.configurationRevision)
    // Detaching demand leaves the recorder receiving the untouched source.
    sink.configure(monitor, consumers: [], scopeVisible: false)
    controller.setMonitorSink(nil)
    harness.emit(image, pts: CMTimeMultiply(duration, multiplier: 4), duration: duration)
    pumpUntil { recorder.telemetry.appendedVideo == 5 }
    XCTAssertEqual(presenter.currentStamp, output)
    controller.stop()
    harness.emit(image, pts: CMTimeMultiply(duration, multiplier: 5), duration: duration)
    try recorder.stop()
    XCTAssertEqual(writer.samples.count, 5)
    XCTAssertEqual(recorder.telemetry.totalDrops, 0)
    for (index, sample) in writer.samples.enumerated() {
      XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === image)
      XCTAssertEqual(
        CMSampleBufferGetPresentationTimeStamp(sample),
        CMTimeMultiply(duration, multiplier: Int32(index)))
      XCTAssertEqual(CMSampleBufferGetDuration(sample), duration)
    }
    XCTAssertEqual(presenter.currentStamp, output)
  }

  @MainActor func testCriticalOutputPressureKeepsCleanPreviewCameraAndRecordingAlive() throws {
    // The critical-pipeline mechanism degrades and suspends monitor analysis when
    // capture falls behind. The GPU monitor rewrite (docs/GPU_PIPELINE_PLAN.md,
    // step 3) removes it; bypass now does an owned GPU copy, which changes the
    // queue timing this test provokes pressure with.
    throw XCTSkip("Monitor critical-pipeline pressure is removed by the GPU monitor rewrite.")
    let image = try packedSyntheticSource()
    CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    let original = try packedBytes(image)
    let entered = expectation(description: "First native preview deliberately stalled")
    let harness = Harness(entered: entered)
    let camera = CameraMetrics()
    var services = harness.services
    services.send = { camera.append($0); return true }
    let controller = CaptureController(services: services, previewRenderer: nil)
    let runtime = MonitorRuntime()
    let target = MonitorTargetID("critical-output-priority")
    let sink = MonitorCaptureSink(target: target, runtime: runtime)
    let presenter = MonitorSurfacePresenter()
    var tools = MonitorConfiguration()
    tools.toolsEnabled = true
    tools.pictureStage = .source
    tools.zebra.enabled = true
    sink.configure(tools, consumers: [presenter], scopeVisible: false)
    controller.setMonitorSink(sink)
    let feed = FeedID(rawValue: target.rawValue)
    let writer = Writer()
    let recorder = try SourceRecordingCallbackAdapter(configuration:
      SourceRecordingConfiguration(feedID: SourceRecordingFeedID(feed.rawValue),
        outputURL: URL(fileURLWithPath:
          "/Volumes/8TB/cinesomatic-build/synthetic-critical-priority-unused.mov"),
        width: 3840, height: 2160, frameRate: .fps2997), writerFactory: { writer })
    try recorder.start()
    defer {
      harness.release.signal()
      controller.onUpdate = nil
      controller.stop()
      try? recorder.stop()
    }
    controller.setRecordingCallbacks(feedID: feed, callbacks: recorder.callbacks)
    let ready = expectation(description: "Critical priority synthetic capture ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
    controller.start(feedID: feed, deviceID: "synthetic:v210",
      configuration: PipelineConfiguration(downscale: false, convertTo420: false),
      pipelineEnabled: false)
    wait(for: [ready], timeout: 3)
    controller.onUpdate = nil
    let duration = VideoContract.slowDuration
    harness.emit(image, pts: .zero, duration: duration)
    wait(for: [entered], timeout: 3)
    for index in 1...3 {
      Thread.sleep(forTimeInterval: duration.seconds)
      harness.emit(image, pts: CMTimeMultiply(duration, multiplier: Int32(index)),
        duration: duration)
    }
    // Queue pressure exceeds a source-frame deadline despite available monitor
    // admission. Releasing preview lets the actual controller report that delay.
    harness.release.signal()
    pumpUntil { camera.samples.count == 4 && recorder.telemetry.appendedVideo == 4 }
    pumpFor(duration.seconds)
    harness.emit(image, pts: CMTimeMultiply(duration, multiplier: 4), duration: duration)
    pumpUntil { camera.samples.count == 5 && recorder.telemetry.appendedVideo == 5 }
    pumpUntil {
      presenter.currentStamp?.sourcePTS == CMTimeMultiply(duration, multiplier: 4).seconds
    }
    pumpUntil { presenter.detail.contains("output pipeline pressure") }
    XCTAssertEqual(presenter.currentStamp?.sourcePTS,
      CMTimeMultiply(duration, multiplier: 4).seconds)
    XCTAssertTrue(presenter.configuration.toolsEnabled,
      "Pressure must preserve the user's requested tools")
    try recorder.stop()
    XCTAssertEqual(recorder.telemetry.totalDrops, 0)
    XCTAssertEqual(writer.samples.count, 5)
    XCTAssertEqual(camera.samples.count, 5)
    XCTAssertEqual(try packedBytes(image), original)
    for (index, sample) in writer.samples.enumerated() {
      XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === image)
      XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample),
        CMTimeMultiply(duration, multiplier: Int32(index)))
      XCTAssertEqual(CMSampleBufferGetDuration(sample), duration)
    }
    controller.stop()
    let other = MonitorTargetID("after-critical-producer-stop")
    runtime.configure(target: other, generation: 1, configurationRevision: 1,
      configuration: tools)
    let done = expectation(description: "Stopping producer removes shared pressure")
    let box = MonitorResultBox()
    let stamp = MonitorFrameStamp(target: other, generation: 1, sequence: 1,
      sourcePTS: 0, hostTime: ProcessInfo.processInfo.systemUptime, configurationRevision: 1)
    XCTAssertTrue(runtime.offer(MonitorFrameBundle(stamp: stamp, source: image,
      sourceSignal: MonitorCaptureSink.signal(image, profile: nil))) { result in
        box.store(result)
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
    XCTAssertNotNil(try box.take().decorated,
      "Stopped producers must not leave other feeds' analysis suspended")
  }

  func testHiddenProducerInvalidationClearsItsLatestHealthEpoch() {
    let runtime = MonitorRuntime()
    let target = MonitorTargetID("hidden-critical-epoch")
    let sink = MonitorCaptureSink(target: target, runtime: runtime)
    sink.invalidate(rejectingCaptureGeneration: 7)
    // Timing continues during hidden capture even though no visible frame offer
    // has updated the sink's presentation generation.
    sink.reportCriticalPipeline(captureGeneration: 8, queueAge: 0.1,
      processingTime: 0, frameInterval: 1 / 30, now: 1)
    XCTAssertEqual(runtime.diagnostics(for: target).availability,
      .degraded("Analysis paused: output pipeline pressure"))
    sink.invalidate()
    XCTAssertEqual(runtime.diagnostics(for: target).availability, .noSignal)
  }

  @MainActor private func pumpUntil(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !predicate(), Date() < deadline { pumpFor(0.01) }
    XCTAssertTrue(predicate())
  }

  @MainActor private func pumpFor(_ duration: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(duration))
  }

  private final class CameraMetrics: @unchecked Sendable {
    struct Sample {
      let pts: CMTime
      let duration: CMTime
      let width: Int
      let height: Int
      let arrival: Double
    }
    let lock = NSLock()
    private var values: [Sample] = []
    func append(_ sample: CMSampleBuffer) {
      guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
      lock.withLock {
        values.append(
          Sample(
            pts: CMSampleBufferGetPresentationTimeStamp(sample),
            duration: CMSampleBufferGetDuration(sample), width: CVPixelBufferGetWidth(image),
            height: CVPixelBufferGetHeight(image), arrival: ProcessInfo.processInfo.systemUptime))
      }
    }
    var samples: [Sample] { lock.withLock { values } }
  }

  private func packedSyntheticSource() throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let source = try XCTUnwrap(image)
    CVPixelBufferLockBaseAddress(source, [])
    defer { CVPixelBufferUnlockBaseAddress(source, []) }
    let stride = CVPixelBufferGetBytesPerRow(source)
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source))
    var row = [UInt32](repeating: 0, count: stride / MemoryLayout<UInt32>.stride)
    for x in Swift.stride(from: 0, to: 3840, by: 6) {
      let offset = x / 6 * 4
      row[offset] = 512 | (283 << 10) | (512 << 20)
      row[offset + 1] = 283 | (512 << 10) | (283 << 20)
      row[offset + 2] = row[offset]
      row[offset + 3] = row[offset + 1]
    }
    row.withUnsafeBytes { bytes in
      for y in 0..<2160 { memcpy(base.advanced(by: y * stride), bytes.baseAddress!, stride) }
    }
    CVBufferSetAttachment(
      source, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return source
  }

  private func packedBytes(_ image: CVPixelBuffer) throws -> Data {
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    return Data(
      bytes: try XCTUnwrap(CVPixelBufferGetBaseAddress(image)),
      count: CVPixelBufferGetBytesPerRow(image) * CVPixelBufferGetHeight(image))
  }

  private final class MonitorResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<MonitorDisplayResult, Error>?
    func store(_ result: Result<MonitorDisplayResult, Error>) { lock.withLock { value = result } }
    func take() throws -> MonitorDisplayResult {
      try lock.withLock { try XCTUnwrap(value).get() }
    }
  }

  func testActualDownscaleKeepsSourceFocusAlignedAcrossAsymmetricAperture() throws {
    let source = try packedSyntheticSource()
    // A vertical source edge at x=1416 must remain at x=708 after downscale,
    // independently of the asymmetric native display aperture.
    XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
    let words = try XCTUnwrap(CVPixelBufferGetBaseAddress(source))
      .assumingMemoryBound(to: UInt32.self)
    let stride = CVPixelBufferGetBytesPerRow(source) / MemoryLayout<UInt32>.stride
    for y in 0..<2160 {
      for x in Swift.stride(from: 1416, to: 3840, by: 6) {
        let offset = y * stride + x / 6 * 4
        words[offset] = 512 | (940 << 10) | (512 << 20)
        words[offset + 1] = 940 | (512 << 10) | (940 << 20)
        words[offset + 2] = words[offset]
        words[offset + 3] = words[offset + 1]
      }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    CVBufferSetAttachment(source, kCVImageBufferCleanApertureKey,
      [kCVImageBufferCleanApertureWidthKey: 3500,
       kCVImageBufferCleanApertureHeightKey: 1900,
       kCVImageBufferCleanApertureHorizontalOffsetKey: -47,
       kCVImageBufferCleanApertureVerticalOffsetKey: 53] as CFDictionary, .shouldPropagate)
    CVBufferSetAttachment(source, kCVImageBufferDisplayDimensionsKey,
      [kCVImageBufferDisplayWidthKey: 3500,
       kCVImageBufferDisplayHeightKey: 1900] as CFDictionary, .shouldPropagate)
    CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    let sourceGeometry = MonitorCaptureSink.geometry(source)
    XCTAssertEqual(sourceGeometry.cleanAperture,
      MonitorRect(x: 123, y: 77, width: 3500, height: 1900))
    let processor = try LUTProcessor()
    let output = try processor.process(source, configuration:
      PipelineConfiguration(downscale: true, convertTo420: true, inputFast: false))
    XCTAssertEqual(CVPixelBufferGetWidth(output), 1920)
    XCTAssertEqual(CVPixelBufferGetHeight(output), 1080)
    XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferCleanApertureKey, nil))
    XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferDisplayDimensionsKey, nil))
    let outputGeometry = MonitorCaptureSink.geometry(output)
    XCTAssertEqual(outputGeometry.cleanAperture, MonitorRect(width: 1920, height: 1080))

    let runtime = MonitorRuntime()
    let target = MonitorTargetID("asymmetric-actual-downscale")
    var configuration = MonitorConfiguration()
    configuration.toolsEnabled = true
    configuration.pictureStage = .processedOutput
    configuration.focus.enabled = true
    configuration.focus.color = .red
    configuration.focus.opacity = 1
    runtime.configure(target: target, generation: 1, configurationRevision: 1,
      configuration: configuration)
    let stamp = MonitorFrameStamp(target: target, generation: 1, sequence: 1,
      sourcePTS: 0, hostTime: ProcessInfo.processInfo.systemUptime, configurationRevision: 1)
    let done = expectation(description: "Source-resolution focus over actual downscaled picture")
    let box = MonitorResultBox()
    XCTAssertTrue(runtime.offer(MonitorFrameBundle(stamp: stamp, source: source, output: output,
      sourceGeometry: sourceGeometry, outputGeometry: outputGeometry,
      correspondence: MonitorCorrespondence(scaleX: 0.5, scaleY: 0.5, offsetX: 0, offsetY: 0),
      sourceSignal: MonitorCaptureSink.signal(source, profile: nil),
      outputSignal: MonitorCaptureSink.signal(output, profile: nil))) { result in
        box.store(result)
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
    let result = try box.take()
    XCTAssertTrue(result.availability.isEmpty, "\(result.availability)")
    let decorated = try XCTUnwrap(result.decorated).pixelBuffer
    XCTAssertEqual(MonitorCaptureSink.geometry(decorated), outputGeometry)
    XCTAssertEqual(MonitorCaptureSink.geometry(result.clean.pixelBuffer), outputGeometry)
    XCTAssertEqual(CVPixelBufferGetWidth(decorated), 1920)
    XCTAssertEqual(CVPixelBufferGetHeight(decorated), 1080)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(decorated, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(decorated, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(decorated))
      .assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(decorated)
    for y in [100, 500, 1000] {
      let edge = y * rowBytes + 708 * 4
      XCTAssertGreaterThan(base[edge + 2], 245)
      XCTAssertLessThan(base[edge + 1], 10)
      XCTAssertLessThan(base[edge], 10)
      let flat = y * rowBytes + 500 * 4
      XCTAssertEqual(base[flat], base[flat + 1])
      XCTAssertEqual(base[flat + 1], base[flat + 2])
    }
    XCTAssertEqual(MonitorCaptureSink.geometry(source), sourceGeometry,
      "Monitoring must preserve the original source display aperture")
  }

  @MainActor func testPacedProcessedCameraAndRecordingWithMonitorGPUEnabled() throws {
    let source = try packedSyntheticSource()
    let originalBytes = try packedBytes(source)
    let duration = VideoContract.slowDuration
    let frameCount = 90
    var baselineCadence: [Double] = []
    for enabled in [false, true] {
      let camera = CameraMetrics()
      let harness = Harness(entered: XCTestExpectation(description: "Unused preview gate"))
      var services = harness.services
      services.preview = nil
      services.capturePixelFormat = kCVPixelFormatType_422YpCbCr10
      services.send = {
        camera.append($0)
        return true
      }
      let controller = CaptureController(services: services, previewRenderer: nil)
      let target = MonitorTargetID("paced-combined-\(enabled)")
      let presenter = MonitorSurfacePresenter()
      let runtime = MonitorRuntime()
      let sink = MonitorCaptureSink(target: target, runtime: runtime)
      if enabled {
        var monitor = MonitorConfiguration()
        monitor.toolsEnabled = true
        monitor.pictureStage = .processedOutput
        monitor.zebra.enabled = true
        monitor.scopes.enabled = true
        monitor.scopes.refreshHz = 15
        sink.configure(monitor, consumers: [presenter], scopeVisible: true, preferredHz: 30)
        controller.setMonitorSink(sink)
      }
      let feed = FeedID(rawValue: target.rawValue)
      let writer = Writer()
      let config = try SourceRecordingConfiguration(
        feedID: SourceRecordingFeedID(feed.rawValue),
        outputURL: URL(
          fileURLWithPath: "/Volumes/8TB/cinesomatic-build/synthetic-combined-unused.mov"),
        width: 3840, height: 2160, frameRate: .fps2997)
      let recorder = try SourceRecordingCallbackAdapter(
        configuration: config, writerFactory: { writer })
      try recorder.start()
      defer {
        controller.onUpdate = nil
        controller.stop()
        try? recorder.stop()
      }
      controller.setRecordingCallbacks(feedID: feed, callbacks: recorder.callbacks)
      let loaded = expectation(description: "Combined test nonlinear LUT uploaded")
      controller.load(try CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 }))) { result in
        if case .failure(let error) = result { XCTFail(error.localizedDescription) }
        loaded.fulfill()
      }
      wait(for: [loaded], timeout: 5)
      let ready = expectation(description: "Combined production pipeline prewarmed")
      controller.onUpdate = { if $0.message.hasPrefix("Waiting") { ready.fulfill() } }
      controller.start(
        feedID: feed, deviceID: "synthetic:v210",
        configuration:
          PipelineConfiguration(
            applyLUT: true, downscale: true, convertTo420: true, inputFast: false))
      wait(for: [ready], timeout: 5)
      controller.onUpdate = nil
      harness.emit(source, pts: .zero, duration: duration)
      pumpUntil { camera.samples.count == 1 }
      if enabled {
        pumpUntil { presenter.currentStamp != nil }
        pumpFor(0.5)
        XCTAssertFalse(
          presenter.detail.contains("Analysis unavailable"),
          "Combined case requires actual monitor GPU analysis")
      }
      // The source cadence is independent of camera/monitor completions. Warmup
      // occurs above; neither downstream queue can slow these 90 offers.
      let origin = ProcessInfo.processInfo.systemUptime
      var emitted: [Double] = []
      var callbackMS: [Double] = []
      var monitorAges: [Double] = []
      var monitorSequences = Set<UInt64>()
      for frame in 1...frameCount {
        let deadline = origin + Double(frame - 1) * duration.seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
          pumpFor(min(0.002, deadline - ProcessInfo.processInfo.systemUptime))
        }
        let start = ProcessInfo.processInfo.systemUptime
        emitted.append(start)
        harness.emit(
          source, pts: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration)
        callbackMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        if let stamp = presenter.currentStamp, stamp.sourcePTS > 0 {
          monitorSequences.insert(stamp.sequence)
          monitorAges.append(ProcessInfo.processInfo.systemUptime - stamp.hostTime)
        }
      }
      pumpUntil {
        camera.samples.count == frameCount + 1
          && recorder.telemetry.appendedVideo == UInt64(frameCount + 1)
      }
      if enabled { pumpFor(0.1) }
      try recorder.stop()
      let samples = camera.samples
      XCTAssertEqual(samples.count, frameCount + 1)
      XCTAssertEqual(writer.samples.count, frameCount + 1)
      XCTAssertEqual(recorder.telemetry.totalDrops, 0)
      XCTAssertEqual(try packedBytes(source), originalBytes)
      for (index, sample) in writer.samples.enumerated() {
        XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === source)
        XCTAssertEqual(
          CMSampleBufferGetPresentationTimeStamp(sample),
          CMTimeMultiply(duration, multiplier: Int32(index)))
        XCTAssertEqual(CMSampleBufferGetDuration(sample), duration)
      }
      if let first = samples.first {
        for (index, sample) in samples.enumerated() {
          XCTAssertEqual(sample.width, 1920)
          XCTAssertEqual(sample.height, 1080)
          XCTAssertEqual(sample.duration, duration)
          XCTAssertEqual(
            CMTimeSubtract(sample.pts, first.pts).seconds,
            CMTimeMultiply(duration, multiplier: Int32(index)).seconds, accuracy: 0.000000002)
        }
      }
      let cadence = samples.dropFirst().map { CMTimeSubtract($0.pts, samples[0].pts).seconds }
      if enabled {
        XCTAssertEqual(cadence.count, baselineCadence.count)
        for (actual, expected) in zip(cadence, baselineCadence) {
          XCTAssertEqual(actual, expected, accuracy: 0.000000002)
        }
        XCTAssertGreaterThan(
          monitorSequences.count, 1, "Enabled GPU monitoring must deliver live updates")
      } else {
        baselineCadence = cadence
      }
      func distribution(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "count=0" }
        func p(_ q: Double) -> Double { sorted[Int(Double(sorted.count - 1) * q)] }
        return
          "count=\(sorted.count),p50=\(p(0.5)),p95=\(p(0.95)),p99=\(p(0.99)),max=\(sorted.last!)"
      }
      let latencyMS = zip(samples.dropFirst(), emitted).map { ($0.0.arrival - $0.1) * 1000 }
      print(
        "COMBINED_CAPTURE monitor=\(enabled) source=v210-4K2997 camera=1080p420 LUT=nonlinear frames=\(frameCount) cameraCount=\(samples.count-1) recordingCount=\(writer.samples.count-1) callbackMS=\(distribution(callbackMS)) cameraLatencyMS=\(distribution(latencyMS)) monitorUpdates=\(monitorSequences.count) monitorAgeSeconds=\(distribution(monitorAges))"
      )
    }
  }


  func testCallbacksArmedAfterStopReturnsSurviveTheNextStart() throws {
    let image = try syntheticRamp()
    let entered = expectation(description: "capture queue blocked in start")
    let release = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable {
      let lock = NSLock()
      var starts = 0
      var hits = 0
      var handler: ((CVPixelBuffer, CMTime, Bool) -> Void)?
    }
    let box = Box()
    let services = CaptureServices(
      start: { _, _, frames, _ in
        let index = box.lock.withLock { () -> Int in
          box.starts += 1
          box.handler = frames
          return box.starts
        }
        if index == 1 {
          entered.fulfill()
          _ = release.wait(timeout: .now() + 3)
        }
      },
      stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true })
    let controller = CaptureController(services: services, previewRenderer: nil)
    defer { controller.onUpdate = nil; controller.stop(); release.signal() }
    let feed = FeedID(rawValue: "callback-after-stop")
    let configuration = PipelineConfiguration(downscale: false, convertTo420: false)
    controller.start(feedID: feed, deviceID: "synthetic", configuration: configuration,
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [entered], timeout: 3)
    let stopBegan = Date()
    controller.stop()
    XCTAssertLessThan(Date().timeIntervalSince(stopBegan), 0.3,
      "stop() must invalidate admission without waiting out a blocked capture worker")
    let callbacks = SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in box.lock.withLock { box.hits += 1 }; return true },
      audio: { _ in true },
      rawAudio: { _, _, _, _, _ in true })
    controller.setRecordingCallbacks(feedID: feed, callbacks: callbacks)
    let stopped = expectation(description: "queued stop finished")
    controller.onUpdate = { if $0.stopped { stopped.fulfill() } }
    release.signal()
    wait(for: [stopped], timeout: 3)
    let restarted = expectation(description: "restarted")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { restarted.fulfill() } }
    controller.start(feedID: feed, deviceID: "synthetic", configuration: configuration,
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [restarted], timeout: 3)
    let duration = VideoContract.fastDuration
    box.lock.withLock { box.handler }?(image, .zero, true)
    let deadline = Date().addingTimeInterval(2)
    while box.lock.withLock({ box.hits }) == 0 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertEqual(box.lock.withLock { box.hits }, 1,
      "Callbacks installed after stop() returns must still receive the next take")
  }

  func testRemoveReleasesTheDeviceBeforeDroppingTheController() {
    let feed = FeedID(rawValue: "pool-release")
    final class Counters: @unchecked Sendable {
      let lock = NSLock()
      var created = 0
      var stops = 0
    }
    let counters = Counters()
    let pool = FeedCapturePool { _ in
      counters.lock.withLock { counters.created += 1 }
      return CaptureController(services: CaptureServices(
        start: { _, _, _, _ in }, stop: { counters.lock.withLock { counters.stops += 1 } },
        connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    }
    let first = pool.controller(for: feed)
    XCTAssertEqual(counters.lock.withLock { counters.created }, 1)
    XCTAssertTrue(pool.remove(feed))
    XCTAssertGreaterThanOrEqual(counters.lock.withLock { counters.stops }, 1,
      "remove must finish stopResources before it returns")
    XCTAssertNil(pool.existingController(for: feed))
    let second = pool.controller(for: feed)
    XCTAssertFalse(first === second)
    XCTAssertEqual(counters.lock.withLock { counters.created }, 2)
    first.start(deviceID: "synthetic", configuration: PipelineConfiguration())
    let ignored = expectation(description: "discarded start had time to run")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { ignored.fulfill() }
    wait(for: [ignored], timeout: 2)
    XCTAssertTrue(pool.existingController(for: feed) === second,
      "Starting a removed controller must not replace the pool's new backend")
    second.stop()
  }

  func testRemoveKeepsTheControllerWhenANewerStartWins() {
    let feed = FeedID(rawValue: "pool-live-start")
    let entered = expectation(description: "remove is inside stopResources")
    let release = DispatchSemaphore(value: 0)
    final class Flag: @unchecked Sendable {
      let lock = NSLock()
      var stops = 0
      var starts = 0
    }
    let flag = Flag()
    let pool = FeedCapturePool { _ in
      CaptureController(services: CaptureServices(
        start: { _, _, _, _ in flag.lock.withLock { flag.starts += 1 } },
        stop: {
          let block = flag.lock.withLock { () -> Bool in
            flag.stops += 1
            return flag.stops == 1
          }
          if block {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
          }
        },
        connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    }
    let controller = pool.controller(for: feed)
    defer { release.signal(); controller.stop() }
    let removed = expectation(description: "remove returned")
    final class ResultBox: @unchecked Sendable { var value = true }
    let result = ResultBox()
    DispatchQueue.global().async {
      result.value = pool.remove(feed)
      removed.fulfill()
    }
    wait(for: [entered], timeout: 3)
    controller.start(deviceID: "synthetic",
      configuration: PipelineConfiguration(downscale: false, convertTo420: false),
      pipelineEnabled: false, previewEnabled: false)
    release.signal()
    wait(for: [removed], timeout: 3)
    XCTAssertFalse(result.value, "A start that wins during remove must keep the live controller")
    XCTAssertTrue(pool.existingController(for: feed) === controller)
    let deadline = Date().addingTimeInterval(2)
    while flag.lock.withLock({ flag.starts }) == 0 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertEqual(flag.lock.withLock { flag.starts }, 1)
  }

  func testInitialCameraConnectFailureDoesNotRetry() throws {
    let image = try syntheticRamp()
    final class Harness: @unchecked Sendable {
      let lock = NSLock()
      var connects = 0
      var handler: ((CVPixelBuffer, CMTime, CMTime, Bool) -> Void)?
    }
    let harness = Harness()
    var services = CaptureServices(
      start: { _, _, _, _ in }, stop: {},
      connect: { _, _ in
        try harness.lock.withLock {
          harness.connects += 1
          throw VideoError.message("Synthetic virtual camera unavailable")
        }
      },
      disconnect: {}, send: { _ in true })
    services.startAutomatic = { _, frames, _ in harness.lock.withLock { harness.handler = frames } }
    services.cameraRetryInterval = 0
    let controller = CaptureController(services: services, previewRenderer: nil)
    defer { controller.onUpdate = nil; controller.stop() }
    let started = expectation(description: "automatic capture ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(deviceID: "synthetic",
      configuration: PipelineConfiguration(downscale: false, convertTo420: false),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    let duration = VideoContract.fastDuration
    for frame in 0..<6 {
      harness.lock.withLock { harness.handler }?(
        image, CMTimeMultiply(duration, multiplier: Int32(frame)), duration, true)
    }
    let deadline = Date().addingTimeInterval(3)
    while harness.lock.withLock({ harness.connects }) < 1 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    Thread.sleep(forTimeInterval: 0.15)
    // Each attempt blocks the capture queue; a camera that never connected
    // (extension not running) must not stall capture with retries.
    XCTAssertEqual(harness.lock.withLock { harness.connects }, 1,
      "Only a lost connection retries")
  }

  func testDisablingCameraOutputPublishesNotConnected() {
    let started = expectation(description: "capture ready")
    let services = CaptureServices(
      start: { _, _, _, _ in }, stop: {},
      connect: { _, _ in }, disconnect: {}, send: { _ in true })
    let controller = CaptureController(services: services, previewRenderer: nil)
    defer { controller.onUpdate = nil; controller.stop() }
    var sawConnected = false
    controller.onUpdate = { update in
      if update.cameraOutputActive && update.cameraMessage.contains("Ultracam camera connected") {
        sawConnected = true
      }
      if update.message.hasPrefix("Waiting") { started.fulfill() }
    }
    controller.start(deviceID: "synthetic",
      configuration: PipelineConfiguration(downscale: false, convertTo420: false),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    XCTAssertTrue(sawConnected)
    let disconnected = expectation(description: "status says not connected")
    controller.onUpdate = { update in
      if !update.cameraOutputActive && update.cameraMessage == "Ultracam camera not connected" {
        disconnected.fulfill()
      }
    }
    controller.setCameraOutputEnabled(false)
    wait(for: [disconnected], timeout: 3)
  }

  func testNeedsOutputTreatsABusyLockAsWanted() {
    let runtime = MonitorRuntime(sharedDevice: { nil })
    let sink = MonitorCaptureSink(target: MonitorTargetID("needs-output-lock"), runtime: runtime)
    var monitor = MonitorConfiguration()
    monitor.pictureStage = .processedOutput
    let presenter = MonitorSurfacePresenter()
    sink.configure(monitor, consumers: [presenter], scopeVisible: false)
    XCTAssertTrue(sink.needsOutput)
    let entered = expectation(description: "sink lock held")
    let release = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      sink.withLockHeldForTesting {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 3)
      }
    }
    wait(for: [entered], timeout: 2)
    XCTAssertTrue(sink.needsOutput, "A failed try-lock must not look like an absent monitor consumer")
    release.signal()
  }

}
