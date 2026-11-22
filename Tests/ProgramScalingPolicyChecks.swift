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

  func testFitPadsNativePictureUnlessUpscalingIsEnabled() throws {
    let native = try ProgramScalingPolicy.plan(sourceWidth: 640, sourceHeight: 480,
      targetWidth: 1280, targetHeight: 720)
    XCTAssertEqual([native.scaledWidth, native.scaledHeight, native.offsetX, native.offsetY], [640, 480, 320, 120])
    let enlarged = try ProgramScalingPolicy.plan(sourceWidth: 640, sourceHeight: 480,
      targetWidth: 1280, targetHeight: 720, allowUpscale: true)
    XCTAssertEqual([enlarged.scaledWidth, enlarged.scaledHeight, enlarged.offsetX, enlarged.offsetY], [960, 720, 160, 0])
    let crop = try ProgramScalingPolicy.plan(sourceWidth: 640, sourceHeight: 480,
      targetWidth: 1280, targetHeight: 720, mode: .crop)
    XCTAssertEqual([crop.scaledWidth, crop.scaledHeight, crop.cropLeft, crop.cropTop], [1280, 960, 0, 120])
  }

  func testRejectsInvalidAndOverflowingGeometry() {
    XCTAssertThrowsError(try ProgramScalingPolicy.plan(sourceWidth: 0, sourceHeight: 1,
                                                        targetWidth: 1, targetHeight: 1))
    XCTAssertThrowsError(try ProgramScalingPolicy.plan(sourceWidth: Int.max, sourceHeight: 1,
                                                        targetWidth: 1, targetHeight: Int.max))
  }
}
