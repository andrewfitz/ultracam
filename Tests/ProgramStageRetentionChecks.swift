import CoreMedia
import CoreVideo
import IOSurface
import XCTest

@objcMembers final class ProgramStageRetentionChecks: XCTestCase {
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
  func finish() {
    let pending = completions
    completions.removeAll()
    pending.forEach { $0(.failure(VideoError.message("retired"))) }
  }
}

private final class RetentionErrorLog: @unchecked Sendable { var count = 0 }
