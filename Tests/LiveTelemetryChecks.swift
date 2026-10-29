import CoreMedia
import XCTest

@objcMembers final class LiveTelemetryChecks: XCTestCase {
  func testCaptureStatePublishesExactDeclaredCadenceChanges() {
    var update = CaptureUpdate(message: "Capturing")
    update.sourceDuration = CMTime(value: 1001, timescale: 24_000)
    let film = CaptureUpdateState(update)
    update.sourceDuration = CMTime(value: 1, timescale: 25)
    let pal = CaptureUpdateState(update)
    XCTAssertNotEqual(film, pal)
    XCTAssertEqual(pal.sourceDuration, CMTime(value: 1, timescale: 25))
    update.frames = 100
    let firstFrame = CaptureUpdateState(update)
    update.frames = 101
    XCTAssertEqual(firstFrame, CaptureUpdateState(update))
  }
}
