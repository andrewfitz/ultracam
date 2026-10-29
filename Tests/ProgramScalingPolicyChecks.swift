import XCTest

@objcMembers final class ProgramScalingPolicyChecks: XCTestCase {
  func testFitPillarboxesWideSource() throws {
    let p = try ProgramScalingPolicy.plan(sourceWidth: 1920, sourceHeight: 1080,
                                          targetWidth: 1080, targetHeight: 1080)
    XCTAssertEqual(p.scaledWidth, 1080)
    XCTAssertEqual(p.scaledHeight, 607)
    XCTAssertEqual(p.offsetX, 0)
    XCTAssertEqual(p.offsetY, 236)
    XCTAssertFalse(p.hasCrop)
  }

  func testCropFillsAndCenterCropsTallSource() throws {
    let p = try ProgramScalingPolicy.plan(sourceWidth: 1080, sourceHeight: 1920,
                                          targetWidth: 1920, targetHeight: 1080, mode: .crop)
    XCTAssertEqual(p.scaledWidth, 1920)
    XCTAssertEqual(p.scaledHeight, 3414)
    XCTAssertEqual(p.cropLeft, 0)
    XCTAssertEqual(p.cropTop, 1167)
    XCTAssertEqual(p.cropWidth, 1920)
    XCTAssertEqual(p.cropHeight, 1080)
  }

  func testFitFloorsAndCropCeilsFractionalDimension() throws {
    let fit = try ProgramScalingPolicy.plan(sourceWidth: 100, sourceHeight: 59,
                                             targetWidth: 101, targetHeight: 60)
    XCTAssertLessThanOrEqual(fit.scaledWidth, fit.targetWidth)
    XCTAssertLessThanOrEqual(fit.scaledHeight, fit.targetHeight)
    let crop = try ProgramScalingPolicy.plan(sourceWidth: 100, sourceHeight: 59,
                                              targetWidth: 101, targetHeight: 60, mode: .crop)
    XCTAssertGreaterThanOrEqual(crop.scaledWidth, crop.targetWidth)
    XCTAssertGreaterThanOrEqual(crop.scaledHeight, crop.targetHeight)
  }

  func testAnamorphicSourceFitsUsingDisplayAspect() throws {
    let p = try ProgramScalingPolicy.plan(sourceWidth: 1440, sourceHeight: 1080,
      targetWidth: 1920, targetHeight: 1080, pixelAspect: Rational(4, 3))
    XCTAssertEqual(p.scaledWidth, 1920)
    XCTAssertEqual(p.scaledHeight, 1080)
    XCTAssertFalse(p.hasPillarboxOrLetterbox)
  }

  func testRejectsInvalidAndOverflowingGeometry() {
    XCTAssertThrowsError(try ProgramScalingPolicy.plan(sourceWidth: 0, sourceHeight: 1,
                                                        targetWidth: 1, targetHeight: 1))
    XCTAssertThrowsError(try ProgramScalingPolicy.plan(sourceWidth: Int.max, sourceHeight: 1,
                                                        targetWidth: 1, targetHeight: Int.max))
  }
}
