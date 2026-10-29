#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class CaptureNativeTimecodeChecks: XCTestCase {
  func testNativeLabelsAt25And37FPSUseTheirActualRateWithoutInventingDropFrameMetadata() throws {
    for fps in [25, 37] {
      let writer = SampleTimecodeWriter()
      let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("native-generic-rate"),
        outputURL: URL(fileURLWithPath: "/tmp/unused-native-generic-rate.mov"), width: 128, height: 72)
      let recorder = try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
      let adapter = SourceRecordingCallbackAdapter(feedID: configuration.feedID, recorder: recorder)
      try adapter.start()
      defer { try? adapter.stop() }
      let duration = CMTime(value: 1, timescale: Int32(fps))
      let format = try SourceFormat(width: 128, height: 72, pixel: .v210, rate: .constant(duration))
      let epoch = CaptureEpochID(sessionID: UUID(), epoch: 2)
      let snapshot = try SourceAdmissionSnapshot(format: format, epochID: epoch,
        clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .recordingSource)
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_422YpCbCr10,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &image), kCVReturnSuccess)
      let buffer = try XCTUnwrap(image)
      for (index, drop) in [false, true].enumerated() {
        let metadata = SourceAdmissionMetadata(pixelBuffer: buffer, presentationTime: CMTimeMultiply(duration, multiplier: Int32(index)),
          duration: duration, epochID: epoch, formatSignature: format.signature)
        let label = try Timecode(hours: 1, minutes: 2, seconds: 3, frames: fps - 1, dropFrame: drop)
        XCTAssertTrue(adapter.appendNativeVideo(buffer, metadata: metadata, source: snapshot, signalValid: true, timecode: label))
      }
      try adapter.stop()
      XCTAssertEqual(writer.nativeLabels.count, 1, "Unsupported DF flags remain raw provenance and cannot become tmcd metadata")
      XCTAssertEqual(writer.nativeLabels.first?.frameRate, RecordingFrameRate(numerator: Int64(fps), denominator: 1))
      XCTAssertEqual(writer.nativeLabels.first?.label, String(format: "01:02:03:%02d", fps - 1))
      XCTAssertEqual(writer.rawLabels.map { $0.dropFrame }, [false, true])
    }
  }

  func testNativeLabelBelongsToItsExactRecordingSample() throws {
    let writer = SampleTimecodeWriter()
    let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("native-label"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-native-label.mov"), width: 3840, height: 2160)
    let recorder = try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
    let adapter = SourceRecordingCallbackAdapter(feedID: configuration.feedID, recorder: recorder)
    try adapter.start()
    defer { try? adapter.stop() }
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    let epoch = CaptureEpochID(sessionID: UUID(), epoch: 2)
    let snapshot = try SourceAdmissionSnapshot(format: format, epochID: epoch,
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .recordingSource)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    let metadata = SourceAdmissionMetadata(pixelBuffer: buffer, presentationTime: .zero,
      duration: VideoContract.fastDuration, epochID: epoch, formatSignature: format.signature)
    let label = try Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, dropFrame: false)
    XCTAssertTrue(adapter.appendNativeVideo(buffer, metadata: metadata, source: snapshot, signalValid: true, timecode: label))
    try adapter.stop()
    XCTAssertEqual(writer.nativeLabels.first?.label, "01:02:03:04")
    XCTAssertEqual(writer.nativeLabels.first?.epoch, 2)
  }
}
private final class SampleTimecodeWriter: SourceRecordingWriter {
  var nativeLabels: [TimecodeMetadata] = []
  var rawLabels: [Timecode] = []
  func start() throws {}
  func appendVideo(_ sample: CMSampleBuffer) throws {
    if let data = CMGetAttachment(sample, key: SourceRecordingConfiguration.sourceTimecodeAttachmentKey as CFString,
      attachmentModeOut: nil) as? Data { rawLabels.append(try JSONDecoder().decode(Timecode.self, from: data)) }
    if let data = CMGetAttachment(sample, key: SourceRecordingConfiguration.nativeTimecodeAttachmentKey as CFString,
      attachmentModeOut: nil) as? Data {
      nativeLabels.append(try JSONDecoder().decode(TimecodeMetadata.self, from: data))
    }
  }
  func appendAudio(_ sample: CMSampleBuffer) throws {}
  func finish() throws {}
}
#endif
