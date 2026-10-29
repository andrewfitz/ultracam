#if CAMERA_STANDBY_TIMING_CHECKS
import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class CameraStandbyTimingChecks: XCTestCase {
  func testGraceTracksPublishedCadenceAndLegitimatePause() {
    XCTAssertEqual(CameraStandbyTimingPolicy.delay(frameDuration: CMTime(value: 1, timescale: 120), pauseAllowance: nil), 0.1, accuracy: 0.000001)
    XCTAssertEqual(CameraStandbyTimingPolicy.delay(frameDuration: CMTime(value: 1, timescale: 24), pauseAllowance: nil), 0.5, accuracy: 0.000001)
    XCTAssertEqual(CameraStandbyTimingPolicy.delay(frameDuration: CMTime(value: 1, timescale: 60), pauseAllowance: 10), 10 + 2.0 / 60, accuracy: 0.000001)
  }

  func testUntrustedAllowancesAreFiniteAndBounded() {
    for value in [Double.nan, .infinity, -.infinity, -1] {
      XCTAssertEqual(CameraStandbyTimingPolicy.clampedPauseAllowance(value), 0)
    }
    XCTAssertEqual(CameraStandbyTimingPolicy.clampedPauseAllowance(1_000_000), 60)
  }

  func testCameraTransportAttachesPolicyWithoutChangingCallerSample() throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
    var description: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(image), formatDescriptionOut: &description), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: try XCTUnwrap(image), formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    let original = try XCTUnwrap(sample)
    let outgoing = try CameraSink.transportSample(original, pauseAllowance: 10)
    XCTAssertNil(CMGetAttachment(original, key: VideoContract.sourcePauseAllowanceAttachmentKey, attachmentModeOut: nil))
    XCTAssertEqual((CMGetAttachment(outgoing, key: VideoContract.sourcePauseAllowanceAttachmentKey, attachmentModeOut: nil) as? NSNumber)?.doubleValue, 10)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(outgoing) === CMSampleBufferGetImageBuffer(original))
    let reset = try CameraSink.transportSample(outgoing, pauseAllowance: nil)
    XCTAssertEqual((CMGetAttachment(reset, key: VideoContract.sourcePauseAllowanceAttachmentKey, attachmentModeOut: nil) as? NSNumber)?.doubleValue, 0)
  }
}
#endif
