import CoreMedia
import XCTest
@objcMembers final class RecordingChecks: XCTestCase {
  func testProductionTimebaseMaintainsExactLongRunCadence() throws {
    let rate = FrameRate.constant(CMTime(value: 1001, timescale: 60000))
    let configuration = try RecordingTimebase.Configuration(frameRate: rate, declaredTimebases: [60000])
    XCTAssertEqual(configuration.timescale, 60000)
  }
}
