import CoreMedia
import XCTest

@objcMembers final class LiveTelemetryChecks: XCTestCase {
  func testSourceFormatChangePublishesWithUnchangedDisplayStrings() throws {
    var update = CaptureUpdate(message: "Capturing")
    let noDeclaration = CaptureUpdateState(update)
    update.sourceFormat = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    XCTAssertNotEqual(CaptureUpdateState(update), noDeclaration)
    let declared = CaptureUpdateState(update)
    update.sourceFormat = try SourceFormat(width: 1920, height: 1080, pixel: .twoVuy,
      rate: .constant(VideoContract.fastDuration))
    XCTAssertNotEqual(CaptureUpdateState(update), declared)
  }

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
