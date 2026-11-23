#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest
import Synchronization

@objcMembers final class LUTSourceAdmissionChecks: XCTestCase {
  func testProcessorRejectsStaleMetadataBeforePassthroughSubmission() throws {
    let (processor, source, image, valid) = try fixture()
    var stale = valid; stale.epochID = CaptureEpochID(sessionID: UUID(), epoch: 1)
    XCTAssertThrowsError(try processor.submitPassthrough(image, source: source, metadata: stale) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("lut"))
      XCTAssertTrue(String(describing: error).contains("epoch"))
    }
    processor.releaseIdleResources()
  }

  func testProcessorChecksActualBufferRatherThanTrustingMetadata() throws {
    let (processor, source, _, valid) = try fixture()
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made), kCVReturnSuccess)
    let wrong = try XCTUnwrap(made)
    XCTAssertThrowsError(try processor.submitPassthrough(wrong, source: source, metadata: valid) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("lut"))
    }
    processor.releaseIdleResources()
  }

  func testProcessorRejectsAValidPlaneStrideFromAnotherBuffer() throws {
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 96, height: 64, pixel: .video420,
      rate: .constant(VideoContract.fastDuration)), epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 96, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary,
      &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    var metadata = SourceAdmissionMetadata(pixelBuffer: image, presentationTime: .zero,
      duration: VideoContract.fastDuration, epochID: source.epochID, formatSignature: source.formatSignature)
    XCTAssertGreaterThan(metadata.planes[1].rowBytes, 96)
    metadata.planes[1].rowBytes = 96
    try source.validate(metadata, stage: .lut)
    let processor = try LUTProcessor()
    XCTAssertThrowsError(try processor.submitPassthrough(image, source: source, metadata: metadata) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("actual pixel buffer layout"))
    }
    XCTAssertEqual(processor.framesInFlight, 0)
  }

  func testProcessorRejectsInvalidTimingBeforeProcessedSubmission() throws {
    let (processor, source, image, valid) = try fixture()
    var invalid = valid; invalid.duration = .invalid
    XCTAssertThrowsError(try processor.submit(image, configuration: PipelineConfiguration(),
      source: source, metadata: invalid) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("duration"))
    }
    processor.releaseIdleResources()
  }

  func testStoppedCaptureReturnsTheAcquiredSlotWithoutSubmitting() throws {
    let (processor, source, image, metadata) = try fixture()
    XCTAssertThrowsError(try processor.submitPassthrough(image, source: source, metadata: metadata,
      isCurrent: { false }) { _ in XCTFail("A cancelled frame must not complete") }) { error in
      guard case VideoError.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
    }
    XCTAssertEqual(processor.framesInFlight, 0)
    XCTAssertTrue(processor.waitUntilIdle(timeout: 1))
  }

  func testDeclaredSourceCanProduceDerivedPlanarOutputAndIndependentPassthrough() throws {
    let (processor, source, image, valid) = try fixture()
    let configurations: [PipelineConfiguration?] = [PipelineConfiguration(resizeTarget: .hd720), nil]
    for configuration in configurations {
      let done = expectation(description: "declared source output")
      let result = Mutex<LUTProcessor.Completed?>(nil)
      let completed: LUTProcessor.Completion = { frame in result.withLock { $0 = frame }; done.fulfill() }
      if let configuration {
        try processor.submit(image, configuration: configuration, source: source, metadata: valid, completion: completed)
      } else {
        try processor.submitPassthrough(image, source: source, metadata: valid, completion: completed)
      }
      wait(for: [done], timeout: 5)
      let output = try XCTUnwrap(result.withLock { $0 }).result.get()
      XCTAssertEqual(CVPixelBufferGetWidth(output), configuration?.width ?? 3840)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), configuration?.pixelFormat ?? kCVPixelFormatType_422YpCbCr10)
      XCTAssertFalse(output === image, "Source ownership must not leak through derived outputs")
      try VideoBufferLayout.validate(output)
    }
    processor.releaseIdleResources()
  }

  private func fixture() throws -> (LUTProcessor, SourceAdmissionSnapshot, CVPixelBuffer, SourceAdmissionMetadata) {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    let source = try SourceAdmissionSnapshot(format: SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration)), epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut)
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    let metadata = SourceAdmissionMetadata(width: 3840, height: 2160, pixel: .v210, isPlanar: false,
      planeCount: 0, rowBytes: CVPixelBufferGetBytesPerRow(image), dataSize: CVPixelBufferGetDataSize(image),
      presentationTime: .zero, duration: VideoContract.fastDuration, epochID: source.epochID, formatSignature: source.formatSignature)
    return (try LUTProcessor(), source, image, metadata)
  }
}
#endif
