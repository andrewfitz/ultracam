import CoreMedia
import XCTest

@objcMembers final class VariableFrameTimelineChecks: XCTestCase {
  private func t(_ value: Int64, _ scale: Int32) -> CMTime { CMTime(value: value, timescale: scale) }

  func testMixedTimescalesRemainMonotonicWithBoundedRounding() throws {
    var timeline = try VariableFrameTimeline()
    let a = try timeline.append(pts: t(0, 30), duration: t(1, 30))
    let b = try timeline.append(pts: t(1001, 30_000), duration: t(1001, 30_000))
    XCTAssertEqual(a.presentationTime.value, 0)
    XCTAssertGreaterThan(b.presentationTime.value, a.presentationTime.value)
    XCTAssertLessThanOrEqual(abs(Double(b.presentationTime.value) / 240_000 - 1001.0 / 30_000), 0.5 / 240_000)
  }

  func testPauseReanchorsAtNextBoundary() throws {
    var timeline = try VariableFrameTimeline()
    _ = try timeline.append(pts: t(10, 1_000), duration: t(40, 1_000))
    timeline.pause()
    let resumed = try timeline.append(pts: t(0, 90_000), duration: t(1, 90_000))
    XCTAssertEqual(resumed.presentationTime.value, 9_600)
    XCTAssertTrue(timeline.isPaused == false)
  }

  func testInvalidAndRegressedFramesDoNotAdvanceState() throws {
    var timeline = try VariableFrameTimeline()
    _ = try timeline.append(pts: t(10, 1_000), duration: t(1, 1_000))
    XCTAssertThrowsError(try timeline.append(pts: t(9, 1_000), duration: t(1, 1_000))) { XCTAssertEqual($0 as? VariableFrameTimeline.Failure, .timestampRegression) }
    XCTAssertEqual(timeline.lastSample?.presentationTime.value, 0)
  }
}
