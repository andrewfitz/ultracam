import AVFoundation
import CoreVideo
import XCTest

@objcMembers final class RecordingCPUAdmissionChecks: XCTestCase {
  private enum Injected: Error { case gpu, pool, metal }
  func testDefaultPolicyRefusesNonSurfaceFrameBeforeEncoderSubmission() throws {
    var submitted = 0
    let writer = try makeWriter(encode: { submitted += 1 })
    try writer.start()
    XCTAssertThrowsError(try writer.appendVideoOutcome(sample(surface: false))) { error in
      XCTAssertTrue(error.localizedDescription.contains("compatibility"), error.localizedDescription)
    }
    XCTAssertEqual(submitted, 0)
    XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 0)
    try writer.finish()
  }
  func testMissingRouteRefusesAtStartUnlessExplicitlyOptedIn() throws {
    let operations = AVAssetSourceRecordingWriter.ConversionOperations(supportedPixelFormats: { _ in [kCVPixelFormatType_32BGRA] })
    let writer = try makeWriter(operations: operations)
    XCTAssertThrowsError(try writer.start()) { error in
      XCTAssertTrue(error.localizedDescription.contains("compatibility"), error.localizedDescription)
    }
    var submitted = 0
    let allowed = try makeWriter(allow: true, operations: operations, encode: { submitted += 1 })
    try allowed.start()
    XCTAssertEqual(try allowed.appendVideoOutcome(sample()), .appended)
    XCTAssertEqual(submitted, 1)
    XCTAssertEqual(allowed.telemetry.systemCompatibilityFrames, 1)
    try allowed.finish()
  }
  func testGPUCommandFailureDropsOnlyOneFrameAndNextFrameWorks() throws { try checkRecoverableFailure(pool: false) }
  func testPoolAllocationFailureDropsOnlyOneFrameAndNextFrameWorks() throws { try checkRecoverableFailure(pool: true) }
  private func checkRecoverableFailure(pool: Bool) throws {
    var shouldFail = true
    var operations = AVAssetSourceRecordingWriter.ConversionOperations()
    if pool {
      operations.allocateBuffer = { pool in
        if shouldFail { shouldFail = false; throw Injected.pool }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Injected.pool }
        return buffer
      }
    } else {
      operations.convert = { converter, source, destination in
        if shouldFail { shouldFail = false; throw Injected.gpu }
        return try converter.convert(source, into: destination)
      }
    }
    var submitted = 0
    let writer = try makeWriter(operations: operations, encode: { submitted += 1 })
    try writer.start()
    XCTAssertEqual(try writer.appendVideoOutcome(sample()), .dropped)
    XCTAssertFalse(writer.hasFailed)
    XCTAssertEqual(try writer.appendVideoOutcome(sample(index: 1)), .appended)
    XCTAssertEqual(submitted, 1)
    XCTAssertEqual(writer.telemetry.gpuConversionFailures, 1)
    XCTAssertEqual(writer.telemetry.droppedGPUFrames, 1)
    XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 0)
    XCTAssertEqual(writer.telemetry.cpuConvertedFrames, 0)
    try writer.finish()
  }
  func testOptInGPUFailureUsesSystemConversionAndMetalRemainsRequired() throws {
    for poolFailure in [false, true] {
      let operations = poolFailure
        ? AVAssetSourceRecordingWriter.ConversionOperations(allocateBuffer: { _ in throw Injected.pool })
        : AVAssetSourceRecordingWriter.ConversionOperations(convert: { _, _, _ in throw Injected.gpu })
      let writer = try makeWriter(allow: true, operations: operations)
      try writer.start()
      XCTAssertEqual(try writer.appendVideoOutcome(sample()), .appended)
      XCTAssertEqual(writer.telemetry.systemCompatibilityFrames, 1)
      XCTAssertEqual(writer.telemetry.gpuConversionFailures, 1)
      XCTAssertEqual(writer.telemetry.droppedGPUFrames, 0)
      try writer.finish()
    }
    let missingMetal = try makeWriter(allow: true,
      operations: .init(supportedPixelFormats: { _ in [kCVPixelFormatType_422YpCbCr10] },
        requireMetal: { throw Injected.metal }))
    XCTAssertThrowsError(try missingMetal.start())
    XCTAssertEqual(missingMetal.telemetry.systemCompatibilityFrames, 0)
  }
  func testCoreDoesNotCountGPUDropAsAppendedOrSourceGap() throws {
    var shouldFail = true
    let operations = AVAssetSourceRecordingWriter.ConversionOperations(convert: { converter, source, destination in
      if shouldFail { shouldFail = false; throw Injected.gpu }
      return try converter.convert(source, into: destination)
    })
    let configuration = try config()
    let writer = try AVAssetSourceRecordingWriter(configuration: configuration,
      encodeFrame: { _, _, _, _ in noErr }, conversionOperations: operations)
    let core = try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
    try core.start()
    XCTAssertTrue(core.appendVideo(try sample()))
    XCTAssertTrue(core.appendVideo(try sample(index: 1)))
    try core.stop()
    XCTAssertEqual(core.telemetry.appendedVideo, 1)
    XCTAssertEqual(core.telemetry.droppedVideo, 1)
    XCTAssertEqual(core.telemetry.droppedGPUFrames, 1)
    XCTAssertEqual(core.telemetry.deviceSkippedFrames, 0)
    XCTAssertEqual(core.telemetry.writerErrors, 0)
  }
  private func config(allow: Bool = false) throws -> SourceRecordingConfiguration {
    try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("cpu-policy"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-cpu-\(UUID().uuidString).mov"),
      width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ,
      compatibilityPolicy: .init(allowCPUConversion: allow))
  }
  private func makeWriter(allow: Bool = false, operations: AVAssetSourceRecordingWriter.ConversionOperations = .init(),
    encode: @escaping () -> Void = {}) throws -> AVAssetSourceRecordingWriter {
    try AVAssetSourceRecordingWriter(configuration: config(allow: allow),
      encodeFrame: { _, _, _, _ in encode(); return noErr }, conversionOperations: operations)
  }
  private func sample(surface: Bool = true, index: Int32 = 0) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr10,
      surface ? [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary : nil, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
      formatDescriptionOut: &format), noErr)
    let duration = RecordingFrameRate.fps5994.frameDuration
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: CMTimeMultiply(duration, multiplier: index),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
}
