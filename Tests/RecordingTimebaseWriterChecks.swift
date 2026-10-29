import AVFoundation
import XCTest

@objcMembers final class RecordingTimebaseWriterChecks: XCTestCase {
  func testB3TimebaseConfigurationIsOptInAndDefaultsPreserveLegacyPath() throws {
    let legacy = try SourceRecordingConfiguration(feedID: .init("tb-legacy"), outputURL: URL(fileURLWithPath: "/tmp/tb-legacy.mov"), width: 16, height: 16)
    XCTAssertNil(legacy.declaredTimebases)
    XCTAssertNil(legacy.quantizationPolicy)
    let configured = try SourceRecordingConfiguration(feedID: .init("tb-configured"), outputURL: URL(fileURLWithPath: "/tmp/tb-configured.mov"), width: 16, height: 16, declaredTimebases: [30_000], quantizationPolicy: nil)
    XCTAssertEqual(configured.declaredTimebases, [30_000])
  }

  func testVFRMapperPreservesOriginalTimingAndRejectsCollision() throws {
    let frameRate = FrameRate.variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    let config = try RecordingTimebase.Configuration(frameRate: frameRate, declaredTimebases: [240_000])
    var mapper = try RecordingTimebase(configuration: config, origin: .zero)
    _ = try mapper.append(pts: CMTime(value: 0, timescale: 1), duration: CMTime(value: 1, timescale: 60))
    let second = try mapper.append(pts: CMTime(value: 1, timescale: 30), duration: CMTime(value: 1, timescale: 15))
    XCTAssertEqual(second.presentationTime.timescale, 240_000)
    XCTAssertEqual(second.duration.timescale, 240_000)
    XCTAssertThrowsError(try mapper.append(pts: CMTime(value: 1, timescale: 30), duration: CMTime(value: 1, timescale: 60))) { error in
      XCTAssertEqual(error as? RecordingTimebase.Failure, .timestampRegression)
    }
    XCTAssertEqual(mapper.diagnostics.acceptedSamples, 2)
  }
}
