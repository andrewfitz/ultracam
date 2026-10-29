import AVFoundation
import CoreVideo
import XCTest

@objcMembers final class RecordingSourceAdmissionChecks: XCTestCase {
  func testWriterRefusesUndeclaredCadenceBeforeEncoderSubmission() throws {
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("source-admission"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-admission-\(UUID().uuidString).mov"),
      width: 1920, height: 1080, videoCodec: kCMVideoCodecType_AppleProRes422HQ)
    var submissions = 0
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, _, _, _ in
      submissions += 1
      return -1
    })
    try writer.start()
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
      formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25), presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    XCTAssertThrowsError(try writer.appendVideo(try XCTUnwrap(sample))) { error in
      XCTAssertTrue(error.localizedDescription.contains("cadence"), error.localizedDescription)
    }
    XCTAssertEqual(submissions, 0, "Unsupported source cadence must never reach the encoder")
  }
  func testWriterRetainsBoundEpochAndRejectsSameFormatNewClock() throws {
    let source = try snapshot()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("source-epoch"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-epoch-\(UUID().uuidString).mov"),
      width: 3840, height: 2160, videoCodec: kCMVideoCodecType_AppleProRes422HQ, sourceAdmission: source)
    let writer = try AVAssetSourceRecordingWriter(configuration: config)
    try writer.bindSourceAdmission(source)
    let changed = try SourceAdmissionSnapshot(format: source.format, epochID: source.epochID,
      clockBindings: CaptureClockBindings(video: ClockInstanceID(), audio: nil), stage: .recordingSource)
    XCTAssertThrowsError(try writer.bindSourceAdmission(changed))
    XCTAssertEqual(writer.sourceAdmission?.clockBindings, source.clockBindings)
    XCTAssertTrue(writer.hasFailed)
  }

  func testWriterValidatesActualCadenceAgainstBoundDeclaration() throws {
    let source = try snapshot()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("source-cadence"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-cadence-\(UUID().uuidString).mov"),
      width: 3840, height: 2160, videoCodec: kCMVideoCodecType_AppleProRes422HQ, sourceAdmission: source)
    var submissions = 0
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, _, _, _ in
      submissions += 1; return -1
    })
    try writer.start()
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
      formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: RecordingFrameRate.fps2997.frameDuration,
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    XCTAssertThrowsError(try writer.appendVideo(try XCTUnwrap(sample))) { error in
      XCTAssertTrue(error.localizedDescription.contains("declared rate"), error.localizedDescription)
    }
    XCTAssertEqual(submissions, 0)
  }

  func testBoundSourceStillUsesDerivedEncoderOutput() throws {
    let source = try snapshot()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("source-derived"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-derived-\(UUID().uuidString).mov"),
      width: 3840, height: 2160, videoCodec: kCMVideoCodecType_AppleProRes422HQ, sourceAdmission: source)
    var submittedFormat: OSType?
    let writer = try AVAssetSourceRecordingWriter(configuration: config, encodeFrame: { _, image, _, _ in
      submittedFormat = CVPixelBufferGetPixelFormatType(image); return -1
    })
    try writer.start()
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
      formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: config.frameRate.frameDuration,
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    XCTAssertThrowsError(try writer.appendVideo(try XCTUnwrap(sample))) { error in
      XCTAssertTrue(error.localizedDescription.contains("encode failed"), error.localizedDescription)
    }
    XCTAssertEqual(submittedFormat, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    XCTAssertEqual(writer.telemetry.gpuConvertedFrames, 1)
    XCTAssertEqual(writer.sourceAdmission?.format.pixel, .v210)
  }

  func testCoreRetainsEpochAndVisiblyStopsOnContractChange() throws {
    let source = try snapshot()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("source-core"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-core-\(UUID().uuidString).mov"),
      width: 3840, height: 2160)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { AdmissionWriterFake() })
    try core.start()
    try core.bindSourceAdmission(source)
    let changed = try SourceAdmissionSnapshot(format: source.format,
      epochID: CaptureEpochID(sessionID: source.epochID.sessionID, epoch: source.epochID.epoch + 1),
      clockBindings: source.clockBindings, stage: .recordingSource)
    XCTAssertThrowsError(try core.bindSourceAdmission(changed))
    XCTAssertEqual(core.sourceAdmission?.epochID, source.epochID)
    XCTAssertEqual(core.state, .failed)
    XCTAssertEqual(core.telemetry.writerErrors, 1)
    try core.stop()
  }

  func testCoreRefusesMalformedOriginalBeforeQueueAdmission() throws {
    let source = try snapshot()
    let config = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("source-malformed"),
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-malformed-\(UUID().uuidString).mov"),
      width: 3840, height: 2160, sourceAdmission: source)
    let core = try SourceRecorderCore(configuration: config, writerFactory: { AdmissionWriterFake() })
    try core.start()
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
      formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: config.frameRate.frameDuration,
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    XCTAssertFalse(core.appendVideo(try XCTUnwrap(sample)))
    XCTAssertEqual(core.state, .failed)
    XCTAssertEqual(core.telemetry.enqueuedVideo, 0)
    XCTAssertEqual(core.telemetry.droppedVideo, 1)
    XCTAssertTrue(core.telemetry.lastError?.contains("recording source refused") == true)
    try core.stop()
    let adapterCore = try SourceRecorderCore(configuration: config, writerFactory: { AdmissionWriterFake() })
    try adapterCore.start()
    adapterCore.failSourceAdmission("recording source refused stale epoch")
    XCTAssertEqual(adapterCore.state, .failed)
    XCTAssertEqual(adapterCore.telemetry.droppedVideo, 1)
    XCTAssertEqual(adapterCore.telemetry.enqueuedVideo, 0)
    XCTAssertEqual(adapterCore.telemetry.writerErrors, 1)
    try adapterCore.stop()
  }

  private func snapshot() throws -> SourceAdmissionSnapshot {
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(RecordingFrameRate.fps5994.frameDuration))
    return try SourceAdmissionSnapshot(format: format,
      epochID: CaptureEpochID(sessionID: UUID(), epoch: 0),
      clockBindings: CaptureClockBindings(video: ClockInstanceID(), audio: nil), stage: .recordingSource)
  }

}

private final class AdmissionWriterFake: SourceRecordingWriter {
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {}
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func finish() throws {}
}
