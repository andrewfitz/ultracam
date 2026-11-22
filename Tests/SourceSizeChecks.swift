#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import XCTest

@objcMembers final class SourceSizeChecks: XCTestCase {
  func testPixelAspectDrivesFitWithoutStretching() throws {
    let source = try SourceSize(width: 1440, height: 1080, pixelAspect: try Rational(4, 3))
    let plan = try SourceScalePlan(source: source, destinationWidth: 1920, destinationHeight: 1080)
    XCTAssertEqual(plan.scaledWidth, 1920, accuracy: 0.001)
    XCTAssertEqual(plan.scaledHeight, 1080, accuracy: 0.001)
    XCTAssertEqual(plan.offsetY, 0, accuracy: 0.001)
  }
  func testFitPillarboxesPortraitAndFillCrops() throws {
    let source = try SourceSize(width: 1080, height: 1920)
    let fit = try SourceScalePlan(source: source, destinationWidth: 1920, destinationHeight: 1080, policy: .fit)
    XCTAssertEqual(fit.scaledWidth, 607.5, accuracy: 0.001)
    XCTAssertEqual(fit.offsetX, 656.25, accuracy: 0.001)
    let fill = try SourceScalePlan(source: source, destinationWidth: 1920, destinationHeight: 1080, policy: .fill)
    XCTAssertEqual(fill.scaledWidth, 1920, accuracy: 0.001)
    XCTAssertLessThan(fill.offsetY, 0)
  }
  func testDisplayAspectRejectsInt64Overflow() throws {
    let huge = Int.max
    let pixelAspect = try Rational(Int64.max, 1)
    XCTAssertThrowsError(try SourceSize(width: huge, height: 1, pixelAspect: pixelAspect))
  }
  func testAdmissionSnapshotReusesValidatedAspect() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 30)))
    let snapshot = try SourceSizeAdmission.snapshot(format, destination: (1920, 1080))
    XCTAssertEqual(snapshot.displayAspect, snapshot.source.displayAspect)
    XCTAssertEqual(snapshot.destination?.width, 1920)
  }
  func testAdmissionAllowsLargerCanvasWithNativeOrMagnifiedPicture() throws {
    let format = try SourceFormat(width: 640, height: 480, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 30)))
    let native = try XCTUnwrap(SourceSizeAdmission.snapshot(format, destination: (1280, 720)).fit)
    XCTAssertEqual(native.scaledWidth, 640)
    XCTAssertEqual(native.scaledHeight, 480)
    XCTAssertEqual(native.offsetX, 320)
    XCTAssertEqual(native.offsetY, 120)
    let enlarged = try XCTUnwrap(SourceSizeAdmission.snapshot(format, destination: (1280, 720), allowUpscale: true).fit)
    XCTAssertEqual(enlarged.scaledWidth, 960)
    XCTAssertEqual(enlarged.scaledHeight, 720)
    XCTAssertEqual(enlarged.offsetX, 160)
    XCTAssertEqual(enlarged.offsetY, 0)
  }
}
#endif
