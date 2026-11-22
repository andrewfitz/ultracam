import CoreMedia
import CoreVideo
import IOSurface
import XCTest

@objcMembers final class ProgramStageRetentionChecks: XCTestCase {
  func testProgramValidatesDeclaredPixelAspectBeforePassthrough() throws {
    let (_, _, image) = try timingRoute()
    let horizontal = kCVImageBufferPixelAspectRatioHorizontalSpacingKey
    let vertical = kCVImageBufferPixelAspectRatioVerticalSpacingKey
    XCTAssertEqual(try ProgramOutputFormat.pixelAspect(of: image), .one)
    for fields: [CFString: NSNumber] in [[horizontal: 1.5, vertical: 1],
                                         [horizontal: 0, vertical: 1]] {
      CVBufferSetAttachment(image, kCVImageBufferPixelAspectRatioKey, fields as CFDictionary, .shouldPropagate)
      XCTAssertThrowsError(try ProgramOutputFormat.pixelAspect(of: image), String(describing: fields))
    }
    CVBufferSetAttachment(image, kCVImageBufferPixelAspectRatioKey,
      [horizontal: 4, vertical: 3] as CFDictionary, .shouldPropagate)
    XCTAssertEqual(try ProgramOutputFormat.pixelAspect(of: image), try Rational(4, 3))
  }

  func testProgramMonitorWaitsForPublishedPixelsWhenClientIsActive() throws {
    let (route, consumer, normalized) = try timingRoute()
    let id = FeedID(rawValue: "timing")
    let step = CMTime(value: 1, timescale: 60)
    var raw: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &raw), kCVReturnSuccess)
    let source = try XCTUnwrap(raw)
    var monitored: [CVPixelBuffer] = []
    route.onMonitorFrame = { _, frame, _, _, _ in monitored.append(frame.payload) }
    func offer(_ n: Int64) {
      route.ingest(feedID: id, frame: ProcessedFrame(payload: source, metadata: ProcessedFrameMetadata(
        presentationTime: CMTime(value: n, timescale: 60), duration: step,
        width: 4, height: 2, pixelFormat: kCVPixelFormatType_32BGRA)))
    }
    offer(0)
    XCTAssertTrue(monitored.isEmpty, "Unavailable normalizer")
    let converter = RetentionPausedNormalizer()
    route.setNormalizerProvider { converter }
    offer(1)
    XCTAssertTrue(monitored.isEmpty, "GPU still pending")
    converter.finish(.success(normalized))
    XCTAssertTrue(monitored.first === normalized)
    XCTAssertTrue(consumer.dequeue()?.payload === normalized)
    route.setOutput(contract: route.contract, active: false)
    offer(2)
    XCTAssertEqual(monitored.count, 2)
    XCTAssertTrue(monitored.last === source)
  }

  func testProgramRetimingKeepsPassthroughProducerUntilConsumerRelease() throws {
    let (route, consumer, image) = try timingRoute()
    var released = 0
    let id = FeedID(rawValue: "timing")
    let contract = try XCTUnwrap(route.contract)
    route.ingest(feedID: id, frame: ProcessedFrame(payload: image, metadata: .init(presentationTime: .zero,
      duration: contract.duration, width: contract.width, height: contract.height, pixelFormat: contract.pixelFormat),
      onReleased: { released += 1 }))
    XCTAssertEqual(released, 0)
    let lease = try XCTUnwrap(consumer.dequeue())
    XCTAssertTrue(lease.payload === image)
    lease.release()
    XCTAssertEqual(released, 1)
  }

  func testProgramNormalizationKeepsProducerThroughGPUFeedbackAfterReset() throws {
    let (route, _, image) = try timingRoute()
    let converter = RetentionPausedNormalizer()
    route.setNormalizerProvider { converter }
    var source: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &source), kCVReturnSuccess)
    var released = 0
    let id = FeedID(rawValue: "timing")
    route.ingest(feedID: id, frame: ProcessedFrame(payload: try XCTUnwrap(source), metadata: .init(presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 60), width: 4, height: 2, pixelFormat: kCVPixelFormatType_32BGRA),
      onReleased: { released += 1 }))
    XCTAssertEqual(released, 0)
    route.reset()
    XCTAssertEqual(released, 0, "Reset cannot return backing still read by the GPU")
    converter.finish(.success(image))
    XCTAssertEqual(released, 1)
  }

  func testStageAdmitsEquivalentTimeAt25And120HzAndKeepsLateWorkCharged() throws {
    for rate in [25, 120] {
      let id = FeedID(rawValue: "retention")
      let route = ProgramOutputRoute(feedIDs: [id])
      let converter = RetentionPausedNormalizer()
      route.setNormalizerProvider { converter }
      let duration = CMTime(value: 1, timescale: Int32(rate))
      route.setOutput(contract: ProgramOutputFormat(width: 4, height: 4,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: duration), active: true)
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
      let buffer = try XCTUnwrap(image)
      CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
      for index in 0..<(rate / 2) {
        route.ingest(feedID: id, frame: ProcessedFrame(payload: buffer, metadata: ProcessedFrameMetadata(
          presentationTime: CMTime(value: Int64(index), timescale: Int32(rate)), duration: duration,
          width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
      }
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, Int(Double(rate) * 0.4))
      XCTAssertEqual(route.stageRetentionSnapshot.currentDuration, 0.4, accuracy: 1e-9)
      XCTAssertGreaterThan(route.statistics.overflowRejected, 0)
      let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
      XCTAssertEqual(try ProgramOutputRoute.storageBytes(buffer), IOSurfaceGetAllocSize(surface))
      route.reset()
      XCTAssertGreaterThan(route.stageAllocationSnapshot.bytes, 0, "Reset cannot retire work still owned by GPU callbacks")
      XCTAssertGreaterThan(route.stageRetentionSnapshot.currentSlots, 0)
      converter.finish()
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 0)
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, 0)
      XCTAssertEqual(route.statistics.published, 0, "Late completions belong to the retired timeline")
    }
  }

  func testErrorRearmsAfterOneSecondAt25And120Hz() throws {
    for rate in [25, 120] {
      let id = FeedID(rawValue: "rearm")
      let route = ProgramOutputRoute(feedIDs: [id])
      let consumer = try route.addConsumerRoute(capacity: 2)
      let errors = RetentionErrorLog()
      route.onEvent = { if case .outputError = $0 { errors.count += 1 } }
      let duration = CMTime(value: 1, timescale: Int32(rate))
      route.setOutput(contract: ProgramOutputFormat(width: 2, height: 2,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: duration), active: true)
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
      let buffer = try XCTUnwrap(image)
      CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
      let contract = ProgramOutputFormat(width: 2, height: 2,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: duration)
      XCTAssertTrue(contract.matchesColourAndAspect(buffer), "Healthy frames must take the passthrough publish path")
      var otherImage: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &otherImage), kCVReturnSuccess)
      let otherBuffer = try XCTUnwrap(otherImage)
      var index: Int64 = 0
      func send(matching: Bool) {
        route.ingest(feedID: id, frame: ProcessedFrame(payload: matching ? buffer : otherBuffer, metadata: ProcessedFrameMetadata(
          presentationTime: CMTime(value: index, timescale: Int32(rate)), duration: duration,
          width: matching ? 2 : 4, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
        index += 1
        while let lease = consumer.dequeue() { lease.release() }
      }
      send(matching: false)
      for _ in 0..<(rate - 1) { send(matching: true) }
      send(matching: false)
      XCTAssertEqual(errors.count, 1)
      for _ in 0..<rate { send(matching: true) }
      send(matching: false)
      XCTAssertEqual(errors.count, 2)
      XCTAssertEqual(route.statistics.published, UInt64(2 * rate - 1))
      XCTAssertEqual(route.statistics.normalizationFailures, 3, "Only the deliberately different size frames fail")
    }
  }

  func testNominalSamplesAfterMissingCallbacksReportGapAndKeepGrid() throws {
    let (route, consumer, buffer) = try timingRoute()
    let errors = RetentionErrorLog()
    route.onEvent = { if case .outputError = $0 { errors.count += 1 } }
    let step = CMTime(value: 1, timescale: 60)
    func send(_ time: CMTime) {
      route.ingest(feedID: FeedID(rawValue: "timing"), frame: ProcessedFrame(payload: buffer,
        metadata: ProcessedFrameMetadata(presentationTime: time, duration: step,
          width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
    }
    send(.zero)
    // Resume half a slot off the original grid after ten seconds without callbacks.
    send(CMTime(value: 1201, timescale: 120))
    var sent: [CMTime] = []
    while let lease = consumer.dequeue() { sent.append(try XCTUnwrap(lease.metadata).presentationTime); lease.release() }
    XCTAssertEqual(sent.count, 2)
    XCTAssertEqual(CMTimeCompare(sent[0], .zero), 0)
    XCTAssertEqual(CMTimeCompare(sent[1], CMTime(value: 601, timescale: 60)), 0)
    XCTAssertEqual(route.statistics.cadenceDiscontinuities, 1)
    XCTAssertEqual(errors.count, 1)
    XCTAssertEqual(route.statistics.cadenceRepeats, 0, "Missing callbacks must not manufacture a ten-second burst")
  }

  func testOverlappingSourceSpansNeverMoveProgramOutputBackwards() throws {
    let (route, consumer, buffer) = try timingRoute()
    let step = CMTime(value: 1, timescale: 60)
    func send(_ time: CMTime, duration: CMTime) {
      route.ingest(feedID: FeedID(rawValue: "timing"), frame: ProcessedFrame(payload: buffer,
        metadata: ProcessedFrameMetadata(presentationTime: time, duration: duration,
          width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
    }
    send(.zero, duration: CMTime(value: 1, timescale: 1))
    send(step, duration: step)
    send(CMTime(value: 1, timescale: 1), duration: step)
    var sent: [CMTime] = []
    while let lease = consumer.dequeue() { sent.append(try XCTUnwrap(lease.metadata).presentationTime); lease.release() }
    XCTAssertEqual(sent.count, 61)
    for index in 1..<sent.count { XCTAssertGreaterThan(CMTimeCompare(sent[index], sent[index - 1]), 0) }
    XCTAssertEqual(CMTimeCompare(sent.last!, CMTime(value: 1, timescale: 1)), 0)
    XCTAssertEqual(route.statistics.cadenceSkipped, 1)
    XCTAssertEqual(route.statistics.cadenceRepeats, 59)
    XCTAssertEqual(route.statistics.cadenceDiscontinuities, 0)
  }

  private func timingRoute() throws -> (ProgramOutputRoute, FrameRoute<CVPixelBuffer>, CVPixelBuffer) {
    let route = ProgramOutputRoute(feedIDs: [FeedID(rawValue: "timing")])
    let consumer = try route.addConsumerRoute(capacity: 128)
    let contract = ProgramOutputFormat(width: 2, height: 2,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: CMTime(value: 1, timescale: 60))
    route.setOutput(contract: contract, active: true)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    try contract.stampColour(on: buffer)
    XCTAssertTrue(contract.matchesColourAndAspect(buffer))
    return (route, consumer, buffer)
  }

  func testFullWindowRemainsAdmissibleAcrossRepeatedReleaseAndAdmission() throws {
    for rate in [25, 120] {
      let ledger = MediaRetentionLedger(policy: ProgramOutputRoute.stagePolicy)
      let slots = Int(ProgramOutputRoute.stagePolicy.maximumDuration * Double(rate))
      var leases: [MediaRetentionLedger.Lease] = []
      for _ in 0..<slots {
        leases.append(try ledger.admit(bytes: 1, duration: 1 / Double(rate)))
      }
      XCTAssertEqual(ledger.snapshot.currentSlots, slots)
      XCTAssertEqual(ledger.snapshot.currentDuration, 0.4, accuracy: 1e-12)
      XCTAssertThrowsError(try ledger.admit(bytes: 1, duration: 1 / Double(rate))) { error in
        XCTAssertEqual(error as? MediaRetentionFailure, .durationLimit)
      }
      for _ in 0..<1_000 {
        leases.removeFirst().release()
        leases.append(try ledger.admit(bytes: 1, duration: 1 / Double(rate)))
      }
      XCTAssertEqual(ledger.snapshot.currentDuration, 0.4, accuracy: 1e-12)
      leases.removeAll()
      XCTAssertEqual(ledger.snapshot.currentDuration, 0)
      XCTAssertEqual(ledger.snapshot.currentSlots, 0)
    }
  }

  func testOversizedStorageIsRefusedEvenWithMinimumSlots() throws {
    let policy = ProgramOutputRoute.stagePolicy
    let ledger = MediaRetentionLedger(policy: policy)
    XCTAssertThrowsError(try ledger.admit(bytes: policy.maximumBytes + 1, duration: 1 / 120))
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(ledger.snapshot.currentSlots, 0)
  }
}

private final class RetentionPausedNormalizer: ProgramFrameNormalizing, @unchecked Sendable {
  private var completions: [@Sendable (Result<CVPixelBuffer, Error>) -> Void] = []
  func canNormalize(_ metadata: ProcessedFrameMetadata, to contract: ProgramOutputFormat) -> Bool { true }
  func normalize(_ source: CVPixelBuffer, to contract: ProgramOutputFormat,
    completion: @escaping @Sendable (Result<CVPixelBuffer, Error>) -> Void) throws { completions.append(completion) }
  func finish(_ result: Result<CVPixelBuffer, Error> = .failure(VideoError.message("retired"))) {
    let pending = completions
    completions.removeAll()
    pending.forEach { $0(result) }
  }
}

private final class RetentionErrorLog: @unchecked Sendable { var count = 0 }
