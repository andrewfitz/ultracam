import CoreMedia
import CoreVideo
import Foundation
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
    let count = 21
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
    // The monitor's endpoint and one surface, without a GPU: offers stop at its slot.
    let gpu = MonitorGPUContext(device: { nil })
    let sink = MonitorFeedHost(target: target.rawValue, gpu: gpu)
    let presenter = MonitorSurfacePresenter(target: target, host: sink, gpu: gpu)
    var tools = MonitorFeedPreferences(toolsEnabled: true)
    tools.state.pictureStage = .source
    tools.state.zebras[0].enabled = true
    presenter.setPreferences(tools)
    // Hidden surface: frames reach the recorder, not the monitor.
    sink.setConsumers([])
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
    let callbackStart = ProcessInfo.processInfo.systemUptime
    harness.emit(image, pts: duration, duration: duration)
    XCTAssertLessThan(
      ProcessInfo.processInfo.systemUptime - callbackStart, 0.5,
      "Capture callback must return promptly with a monitor attached")
    pumpUntil { recorder.telemetry.appendedVideo == 2 }
    pumpFor(0.1)
    XCTAssertNil(presenter.currentStamp)
    sink.setConsumers([presenter])
    harness.emit(image, pts: CMTimeMultiply(duration, multiplier: 2), duration: duration)
    pumpUntil {
      presenter.currentStamp?.sourcePTS == CMTimeMultiply(duration, multiplier: 2).seconds
    }
    let source = try XCTUnwrap(presenter.currentStamp)
    XCTAssertEqual(source.target, target.rawValue)
    XCTAssertGreaterThan(source.generation, 0)
    XCTAssertGreaterThan(source.sequence, 0)
    // A changed capture pipeline does not restart the monitor's stream: the next
    // source frame follows in the same generation (the picture stage is the
    // monitor's own: the source, or the source plus the burn-in LUT in its shader).
    tools.state.pictureStage = .output
    presenter.setPreferences(tools)
    controller.reconfigure(configuration: bypass, pipelineEnabled: false)
    pumpFor(0.03)
    harness.emit(image, pts: CMTimeMultiply(duration, multiplier: 3), duration: duration)
    pumpUntil {
      presenter.currentStamp?.sourcePTS == CMTimeMultiply(duration, multiplier: 3).seconds
    }
    let output = try XCTUnwrap(presenter.currentStamp)
    XCTAssertEqual(output.generation, source.generation)
    XCTAssertGreaterThan(output.sequence, source.sequence)
    XCTAssertEqual(output.revision, source.revision, "The same signal and consumers: the same revision")
    // Detaching demand leaves the recorder receiving the untouched source.
    sink.setConsumers([])
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


  /// The published feed (meeting apps, Program, the preview) never inherits a 4K
  /// source's clean aperture or display dimensions on its 1080p downscale, which
  /// would crop or offset it; an output at source size keeps both.
  func testDownscaleDropsTheSourceApertureAndFullSizeKeepsIt() throws {
    let source = try packedSyntheticSource()
    let aperture = [kCVImageBufferCleanApertureWidthKey: 3500,
      kCVImageBufferCleanApertureHeightKey: 1900,
      kCVImageBufferCleanApertureHorizontalOffsetKey: -47,
      kCVImageBufferCleanApertureVerticalOffsetKey: 53] as CFDictionary
    let display = [kCVImageBufferDisplayWidthKey: 3500,
      kCVImageBufferDisplayHeightKey: 1900] as CFDictionary
    CVBufferSetAttachment(source, kCVImageBufferCleanApertureKey, aperture, .shouldPropagate)
    CVBufferSetAttachment(source, kCVImageBufferDisplayDimensionsKey, display, .shouldPropagate)
    CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    let processor = try LUTProcessor()
    let downscaled = try processor.process(source, configuration:
      PipelineConfiguration(downscale: true, convertTo420: true, inputFast: false))
    XCTAssertEqual(CVPixelBufferGetWidth(downscaled), 1920)
    XCTAssertEqual(CVPixelBufferGetHeight(downscaled), 1080)
    XCTAssertNil(CVBufferCopyAttachment(downscaled, kCVImageBufferCleanApertureKey, nil))
    XCTAssertNil(CVBufferCopyAttachment(downscaled, kCVImageBufferDisplayDimensionsKey, nil))
    let fullSize = try processor.process(source, configuration:
      PipelineConfiguration(downscale: false, convertTo420: true, inputFast: false))
    XCTAssertEqual(CVPixelBufferGetWidth(fullSize), 3840)
    XCTAssertEqual(CVPixelBufferGetHeight(fullSize), 2160)
    let keptAperture = try XCTUnwrap(CVBufferCopyAttachment(fullSize, kCVImageBufferCleanApertureKey, nil))
    XCTAssertTrue(CFEqual(keptAperture, aperture))
    let keptDisplay = try XCTUnwrap(CVBufferCopyAttachment(fullSize, kCVImageBufferDisplayDimensionsKey, nil))
    XCTAssertTrue(CFEqual(keptDisplay, display))
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
      let gpu = MonitorCoordinator.sharedGPU
      let sink = MonitorFeedHost(target: target.rawValue, gpu: gpu)
      let presenter = MonitorSurfacePresenter(target: target, host: sink, gpu: gpu)
      if enabled {
        var tools = MonitorFeedPreferences(toolsEnabled: true)
        tools.state.pictureStage = .output
        tools.state.zebras[0].enabled = true
        tools.scopes.enabled = true
        tools.scopes.refreshHz = 15
        presenter.setPreferences(tools)
        sink.setConsumers([presenter])
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

  /// A monitor endpoint that records every offer (any thread).
  private final class SourceOfferLog: MonitorFrameSink, @unchecked Sendable {
    struct Offer {
      let image: CVPixelBuffer
      let pts: CMTime
      let captureGeneration: UInt64
      let sequence: UInt64
      let untouched: Bool
    }
    let lock = NSLock()
    private var values: [Offer] = []
    private var rejections: [UInt64?] = []
    var offers: [Offer] { lock.withLock { values } }
    var invalidations: [UInt64?] { lock.withLock { rejections } }
    func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64, untouched: Bool) {
      lock.withLock {
        values.append(Offer(image: image, pts: pts, captureGeneration: captureGeneration, sequence: sequence,
          untouched: untouched))
      }
    }
    func invalidate(rejectingCaptureGeneration rejected: UInt64?) {
      lock.withLock { rejections.append(rejected) }
    }
  }

  /// The monitor is a source-only consumer: alone it never makes a frame do GPU
  /// work (even with a processing pipeline configured), and it still gets every
  /// source frame, in capture order, under one capture generation. Each offer says
  /// whether the camera publishes the frame processed.
  @MainActor func testMonitorAloneTakesEverySourceFrameWithoutProcessing() throws {
    let offers = try monitorAloneOffers(
      PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true), pipelineEnabled: true)
    XCTAssertTrue(offers.allSatisfy { !$0.untouched }, "Downscaled and 4:2:0: published processed")
  }

  /// A camera that publishes its frames untouched (here with processing off) tells
  /// the monitor, whose Output stage then reads the frame's own tags.
  @MainActor func testMonitorOffersSayWhenTheCameraPublishesUntouched() throws {
    let offers = try monitorAloneOffers(
      PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true), pipelineEnabled: false)
    XCTAssertTrue(offers.allSatisfy(\.untouched), "Processing off: published untouched")
  }

  @MainActor private func monitorAloneOffers(
    _ configuration: PipelineConfiguration, pipelineEnabled: Bool
  ) throws -> [SourceOfferLog.Offer] {
    let image = try syntheticRamp()
    let harness = Harness(entered: XCTestExpectation(description: "Unused preview gate"))
    var services = harness.services
    services.preview = nil
    let controller = CaptureController(services: services, previewRenderer: nil)
    let sink = SourceOfferLog()
    controller.setCameraOutputEnabled(false)
    controller.setMonitorSink(sink)
    defer {
      controller.onUpdate = nil
      controller.stop()
    }
    final class Updates: @unchecked Sendable {
      let lock = NSLock()
      var values: [CaptureUpdate] = []
      var ready: XCTestExpectation?
    }
    let log = Updates()
    log.ready = expectation(description: "Synthetic controller ready")
    let started = try XCTUnwrap(log.ready)
    controller.onUpdate = { update in
      let ready = log.lock.withLock { () -> XCTestExpectation? in
        log.values.append(update)
        guard update.message.hasPrefix("Waiting") else { return nil }
        defer { log.ready = nil }
        return log.ready
      }
      ready?.fulfill()
    }
    var updates: [CaptureUpdate] { log.lock.withLock { log.values } }
    controller.start(
      feedID: FeedID(rawValue: "monitor-only"), deviceID: "synthetic",
      configuration: configuration, pipelineEnabled: pipelineEnabled)
    wait(for: [started], timeout: 3)
    let duration = VideoContract.fastDuration
    let count = 6
    for frame in 0..<count {
      harness.emit(image, pts: CMTimeMultiply(duration, multiplier: Int32(frame)), duration: duration)
    }
    pumpUntil { sink.offers.count == count }
    pumpUntil { updates.contains { $0.message == "Camera ready — no active video destination." } }
    let offers = sink.offers
    XCTAssertEqual(offers.count, count)
    for (index, offer) in offers.enumerated() {
      XCTAssertTrue(offer.image === image, "The monitor gets the capture buffer itself")
      XCTAssertEqual(offer.pts, CMTimeMultiply(duration, multiplier: Int32(index)))
      XCTAssertEqual(offer.captureGeneration, offers[0].captureGeneration)
      if index > 0 { XCTAssertEqual(offer.sequence, offers[index - 1].sequence + 1) }
    }
    XCTAssertTrue(updates.allSatisfy { $0.framesInFlight == 0 && $0.gpuMS == 0 },
      "A monitor-only feed submits no GPU work")
    controller.stop()
    pumpUntil { !sink.invalidations.isEmpty }
    XCTAssertEqual(sink.invalidations.first ?? nil, offers.first?.captureGeneration,
      "Stop rejects the stopped capture generation at the monitor")
    return offers
  }

  /// Program's monitor gets each Program frame once, as its only picture, and a
  /// new generation at every cut and restart.
  func testProgramMonitorTapOffersEachFrameOnceAndRestartsAtCuts() throws {
    var made: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &made), kCVReturnSuccess)
    let buffer = try XCTUnwrap(made)
    let frame = ProcessedFrame(
      payload: buffer,
      metadata: ProcessedFrameMetadata(
        presentationTime: .zero, duration: VideoContract.fastDuration, width: 16, height: 16,
        pixelFormat: kCVPixelFormatType_32BGRA))
    let sink = SourceOfferLog()
    let tap = ProgramMonitorTap(sink: sink)
    tap.offer(frame: frame, sourcePTS: CMTime(value: 1, timescale: 60), cutApplied: false)
    tap.offer(frame: frame, sourcePTS: CMTime(value: 2, timescale: 60), cutApplied: false)
    tap.offer(frame: frame, sourcePTS: CMTime(value: 3, timescale: 60), cutApplied: true)
    tap.restart()
    tap.offer(frame: frame, sourcePTS: CMTime(value: 4, timescale: 60), cutApplied: false)
    let offers = sink.offers
    XCTAssertEqual(offers.map(\.captureGeneration), [1, 1, 2, 3])
    XCTAssertEqual(offers.map(\.sequence), [1, 2, 3, 4])
    XCTAssertEqual(offers.map(\.pts.value), [1, 2, 3, 4])
    XCTAssertTrue(offers.allSatisfy { $0.image === buffer })
  }

}
