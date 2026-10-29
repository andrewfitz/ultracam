#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureTypedAdmissionChecks: XCTestCase {
  func testEpochRetiresQueuedFramesAndRejectsStaleDeclarationWithNewSequence() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let source = EpochInterceptSession(format: format)
    let feed = FeedID(rawValue: "epoch-retirement")
    let budget = CaptureAdmissionBudget(maximumSlots: 4, maximumBytes: 128 * 1024 * 1024,
      maximumDuration: 1, minimumSlots: 1)
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }),
      retentionBudget: budget)
    let sink = BlockingTypedMonitor()
    controller.setCameraOutputEnabled(false)
    controller.setMonitorSink(sink)
    defer { sink.release.signal(); controller.onUpdate = nil; controller.stop() }
    let recording = TypedRecordingAdmission()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, admitted in recording.note(admitted); return admitted }, audio: { _ in false },
      rawAudio: { _, _, _, _, _ in false }))
    let started = expectation(description: "Epoch source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    for index in 0..<2 {
      let context = source.source.context
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(index)),
        duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
      XCTAssertTrue(source.source.submit(.frame(CapturedPixelBuffer(immutable: image), info)))
      if index == 0 { XCTAssertEqual(sink.entered.wait(timeout: .now() + 2), .success) }
    }
    controller.setCameraOutputEnabled(false)
    XCTAssertTrue(source.source.submitGroup([.event(.discontinuity), .event(.info("stale declaration"))]))
    let context = source.source.context
    let newTime = CMTime(value: 1, timescale: 1)
    XCTAssertTrue(source.source.submit(.frame(CapturedPixelBuffer(immutable: image),
      CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: newTime, duration: VideoContract.fastDuration, signalValid: true, timecode: nil))))
    source.stop()
    controller.setCameraOutputEnabled(false)
    XCTAssertEqual(recording.accepted, 3, "A stale declaration cannot roll the current contract backwards")
    sink.release.signal()
    let deadline = Date().addingTimeInterval(2)
    while budget.snapshot.currentSlots > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(budget.snapshot.currentSlots, 0)
    XCTAssertEqual(sink.offeredTimes, [.zero, newTime], "Queued old-epoch work must retire before the new epoch delivers")
  }
  func testExplicitEarlierPairSurvivesUnrelatedNoSignalFrame() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let source = FakeCaptureSession(format: format, audio: .present(audio))
    let feed = FeedID(rawValue: "typed-pairs")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    defer { controller.onUpdate = nil; controller.stop() }
    let pairs = TypedAudioPairs()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in pairs.video() }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in true },
      audioPair: { time, _ in pairs.note(time) }))
    let started = expectation(description: "Paired source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    let context = source.context
    let firstTime = CMTime(value: 20, timescale: 1)
    let secondTime = CMTimeAdd(firstTime, VideoContract.fastDuration)
    for (index, time) in [firstTime, secondTime].enumerated() {
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: time, duration: VideoContract.fastDuration, signalValid: index == 0, timecode: nil)
      let packet = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
        format: audio, packetTime: CMTime(value: Int64(480000 + index), timescale: 48000),
        pairedFrameSequence: 3)
      XCTAssertTrue(source.submitGroup([.frame(CapturedPixelBuffer(immutable: image), info), .rawAudio(packet)]))
    }
    XCTAssertTrue(source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
      format: audio, packetTime: CMTime(value: 480002, timescale: 48000), pairedFrameSequence: 5))))
    XCTAssertTrue(source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
      format: audio, packetTime: CMTime(value: 480002, timescale: 48000)))))
    source.stop()
    controller.stop()
    let values = pairs.values
    XCTAssertEqual(values.count, 4)
    XCTAssertEqual(values[0], firstTime)
    XCTAssertEqual(values[1], firstTime, "Explicit sequence3 still names a valid earlier frame after unrelated no-signal frame5")
    XCTAssertNil(values[2], "An explicit no-signal frame sequence cannot borrow earlier validframe metadata")
    XCTAssertNil(values[3], "Unpaired audio must explicitly clear inferred pending video")
  }
  func testExplicitPairSurvivesRecorderRejectionAndUnpairedPacketHasNoStalePair() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    let source = FakeCaptureSession(format: format, audio: .present(audio))
    let feed = FeedID(rawValue: "typed-pairs")
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    controller.setCameraOutputEnabled(false)
    defer { controller.onUpdate = nil; controller.stop() }
    let pairs = TypedAudioPairs()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, _ in pairs.video() }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in true },
      audioPair: { time, _ in pairs.note(time) }))
    let started = expectation(description: "Paired source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    let context = source.context
    let firstTime = CMTime(value: 20, timescale: 1)
    let secondTime = CMTimeAdd(firstTime, VideoContract.fastDuration)
    for (index, time) in [firstTime, secondTime].enumerated() {
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: time, duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
      let packet = try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
        format: audio, packetTime: CMTime(value: Int64(480000 + index), timescale: 48000),
        pairedFrameSequence: UInt64(3 + index * 2))
      XCTAssertTrue(source.submitGroup([.frame(CapturedPixelBuffer(immutable: image), info), .rawAudio(packet)]))
    }
    XCTAssertTrue(source.submit(.rawAudio(try CaptureAudioPacket(planes: [Data(count: 8)], sampleFrameCount: 1,
      format: audio, packetTime: CMTime(value: 480002, timescale: 48000)))))
    source.stop()
    controller.stop()
    let values = pairs.values
    XCTAssertEqual(values.count, 3)
    XCTAssertEqual(values[0], firstTime)
    XCTAssertEqual(values[1], secondTime, "The second frame was rejected by the recorder but still names its packet")
    XCTAssertNil(values[2], "Unpaired audio must explicitly clear inferred pending video")
  }
  func testSourceOnlyRetentionIsBoundedRecordingIndependentAndStopRejectsQueuedOffers() throws {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let source = FakeCaptureSession(format: format)
    let feed = FeedID(rawValue: "bounded-source-only")
    let budget = CaptureAdmissionBudget(maximumSlots: 3, maximumBytes: 128 * 1024 * 1024,
      maximumDuration: 1, minimumSlots: 1)
    let controller = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }),
      retentionBudget: budget)
    let sink = BlockingTypedMonitor()
    controller.setCameraOutputEnabled(false)
    controller.setMonitorSink(sink)
    defer { sink.release.signal(); controller.onUpdate = nil; controller.stop() }
    let recording = TypedRecordingAdmission()
    controller.setRecordingCallbacks(feedID: feed, callbacks: SourceRecordingCallbackAdapter.Callbacks(
      video: { _, _, _, admitted in recording.note(admitted); return admitted },
      audio: { _ in false }, rawAudio: { _, _, _, _, _ in false }))
    let started = expectation(description: "Bounded source ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    let context = source.context
    for frame in 0..<20 {
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: CMTimeMultiply(VideoContract.fastDuration, multiplier: Int32(frame)),
        duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
      XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: image), info)))
      if frame == 0 { XCTAssertEqual(sink.entered.wait(timeout: .now() + 2), .success) }
    }
    source.stop()
    controller.setCameraOutputEnabled(false) // capture-queue barrier
    XCTAssertEqual(recording.accepted, 20, "Core retention refusal must not gate recording")
    XCTAssertEqual(budget.snapshot.currentSlots, 3)
    XCTAssertEqual(budget.snapshot.accepted, 3)
    XCTAssertEqual(budget.snapshot.rejected, 17)
    controller.stop()
    sink.release.signal()
    let deadline = Date().addingTimeInterval(2)
    while budget.snapshot.currentSlots > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(budget.snapshot.currentSlots, 0)
    XCTAssertEqual(budget.snapshot.accepted, budget.snapshot.released)
    XCTAssertEqual(sink.staleOffers, 0, "Queued source-only work must check generation before calling the sink")
  }
  /// The ordered declaration must govern recording admission on the callback
  /// thread, before the asynchronous processing queue inspects this buffer.
  func testDeclaredFormatIsAppliedBeforeRecordingCallbackAdmission() throws {
    let declared = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.slowDuration))
    let source = FakeCapturePlugin(format: declared, audio: .absent).makeSession() as! FakeCaptureSession
    let feed = FeedID(rawValue: "typed-admission")
    let services = CaptureServices.registryBridge(feedID: feed, makeSession: { _ in source })
    let controller = CaptureController(services: services)
    controller.setCameraOutputEnabled(false)
    defer { controller.onUpdate = nil; controller.stop() }
    let admission = TypedRecordingAdmission()
    controller.setRecordingCallbacks(feedID: feed,
      callbacks: SourceRecordingCallbackAdapter.Callbacks(video: { _, _, _, admitted in
        admission.note(admitted)
        return false
      }, audio: { _ in false }, rawAudio: { _, _, _, _, _ in false }))
    let started = expectation(description: "Headless capture ready")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    try VideoBufferLayout.validate(image)
    let context = source.context
    let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
      presentationTime: .zero, duration: VideoContract.fastDuration, signalValid: true, timecode: nil)
    XCTAssertTrue(source.submit(.frame(CapturedPixelBuffer(immutable: image), info)))
    source.stop()
    controller.stop()
    XCTAssertEqual(admission.accepted, 0,
      "A legacy-valid fast frame contradicts the ordered slow-rate declaration")
  }
}
private final class EpochInterceptSession: CaptureSession, @unchecked Sendable {
  let source: FakeCaptureSession
  private let lock = NSLock()
  private var initial: CaptureEpochID?
  private let format: SourceFormat
  init(format: SourceFormat) { self.format = format; source = FakeCaptureSession(format: format) }
  var counters: CaptureCounters { source.counters }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    try source.start(deviceID: deviceID, timing: timing, handlers: CaptureHandlers { [self] delivery in
      if case .event(.formatChanged) = delivery.payload {
        lock.withLock { if initial == nil { initial = delivery.epochID } }
      }
      if case .event(.info("stale declaration")) = delivery.payload, let epoch = lock.withLock({ initial }) {
        handlers.deliver(CaptureDelivery(sequence: delivery.sequence, epochID: epoch,
          formatSignature: format.signature, clockBindings: delivery.clockBindings,
          mappingRevision: delivery.mappingRevision, payload: .event(.formatChanged(format))))
      } else { handlers.deliver(delivery) }
    })
  }
  func stop() { source.stop() }
}
private final class TypedAudioPairs: @unchecked Sendable {
  private let lock = NSLock()
  private var videoCalls = 0
  private var pairs: [CMTime?] = []
  func video() -> Bool { lock.withLock { videoCalls += 1; return videoCalls == 1 } }
  func note(_ time: CMTime?) { lock.withLock { pairs.append(time) } }
  var values: [CMTime?] { lock.withLock { pairs } }
}
private final class BlockingTypedMonitor: MonitorFrameSink, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var invalidated = false
  private var count = 0
  private var stale = 0
  private var times: [CMTime] = []
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64, untouched: Bool) {
    let first = lock.withLock { () -> Bool in
      if invalidated { stale += 1 }
      count += 1
      times.append(pts)
      return count == 1
    }
    if first { entered.signal(); _ = release.wait(timeout: .now() + 5) }
  }
  func invalidate(rejectingCaptureGeneration: UInt64?) { lock.withLock { invalidated = true } }
  var staleOffers: Int { lock.withLock { stale } }
  var offeredTimes: [CMTime] { lock.withLock { times } }
}
private final class TypedRecordingAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func note(_ admitted: Bool) { lock.withLock { if admitted { count += 1 } } }
  var accepted: Int { lock.withLock { count } }
}
#endif
