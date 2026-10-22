import Foundation
import XCTest

final class DeckLinkChecks: XCTestCase {
  func testAutomaticInputDetectionAndTransitions() {
    var error: NSError?
    XCTAssertTrue(UltracamRunAutoSyntheticChecks(&error), error?.localizedDescription ?? "Native auto detection failed")
  }
  func testNativeSDKCallbacksAndLifecycle() {
    var error: NSError?
    XCTAssertTrue(UltracamRunOwnershipSyntheticChecks(&error),
      error?.localizedDescription ?? "Native lifecycle checks failed")
  }

  func testInputOwnershipAndReentrantControlQueue() {
    var error: NSError?
    XCTAssertTrue(UltracamRunOwnershipSyntheticChecks(&error),
      error?.localizedDescription ?? "Native ownership checks failed")
  }

  func testRawEmbeddedAudioBridge() {
    var error: NSError?
    XCTAssertTrue(UltracamRunRawAudioSyntheticChecks(&error), error?.localizedDescription ?? "Raw embedded audio bridge failed")
  }

  func testStopBeforeStartIsIdempotent() {
    let backend = UltracamBackend()
    backend.stop()
    backend.stop()
  }

  func testMissingAutoDeviceFailsCleanly() {
    let backend = UltracamBackend()
    XCTAssertThrowsError(try backend.startAuto(deviceID: "synthetic:missing-device",
      frameHandler: { _, _, _, _ in XCTFail("Missing auto device delivered a frame") },
      eventHandler: { _ in XCTFail("Missing auto device started a callback") }))
    backend.stop()
  }

  func testMissingDeviceFailsCleanlyAndCanStop() {
    let backend = UltracamBackend()
    XCTAssertThrowsError(try backend.start(deviceID: "synthetic:missing-device", inputFast: true,
      frameHandler: { _, _, _ in XCTFail("Missing device delivered a frame") },
      eventHandler: { _ in XCTFail("Missing device unexpectedly started its callback") }))
    backend.stop()
  }

  func testVideoContractCarriesRangeAndTimingMetadata() throws {
    XCTAssertEqual(VideoContract.fastDuration, CMTime(value: 1001, timescale: 60_000))
    XCTAssertEqual(VideoContract.slowDuration, CMTime(value: 1001, timescale: 30_000))
    XCTAssertThrowsError(try VideoContract.formatDescription(width: 0, height: 1080,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange))
    XCTAssertThrowsError(try VideoContract.formatDescription(width: Int.max, height: 1080,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange))
    XCTAssertThrowsError(try VideoContract.formatDescription(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_32BGRA))
    XCTAssertThrowsError(try VideoContract.formatDescription(width: 1919, height: 1080,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
      "4:2:2 bi-planar descriptions require paired luma samples")
    XCTAssertThrowsError(try VideoContract.formatDescription(width: 1920, height: 1079,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      "4:2:0 bi-planar descriptions require paired rows")

    let videoRange = try VideoContract.formatDescription(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    let fullRange = try VideoContract.formatDescription(width: 1920, height: 1080,
      pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
    XCTAssertEqual(CMFormatDescriptionGetExtension(videoRange,
      extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    XCTAssertTrue(CFEqual(CMFormatDescriptionGetExtension(videoRange,
      extensionKey: kCMFormatDescriptionExtension_FullRangeVideo), kCFBooleanFalse))
    XCTAssertTrue(CFEqual(CMFormatDescriptionGetExtension(fullRange,
      extensionKey: kCMFormatDescriptionExtension_FullRangeVideo), kCFBooleanTrue))
  }

  static let allTests = [
    ("automatic HDMI detection and live transitions", testAutomaticInputDetectionAndTransitions),
    ("missing automatic device fails cleanly", testMissingAutoDeviceFailsCleanly),
    ("native SDK callbacks, frame ownership, lifecycle and HDMI restore", testNativeSDKCallbacksAndLifecycle),
    ("input ownership and reentrant control queue", testInputOwnershipAndReentrantControlQueue),
    ("raw embedded audio bridge", testRawEmbeddedAudioBridge),
    ("native stop before start is idempotent", testStopBeforeStartIsIdempotent),
    ("native missing-device startup cleans up", testMissingDeviceFailsCleanlyAndCanStop),
    ("video contract preserves range and timing metadata", testVideoContractCarriesRangeAndTimingMetadata),
  ]
}
