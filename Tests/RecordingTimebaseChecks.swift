import CoreMedia
import Foundation
import XCTest

@objcMembers final class RecordingTimebaseChecks: XCTestCase {
  func testMixedScalesAndReducedDurationChooseExactLCM() throws {
    let config = try RecordingTimebase.Configuration(frameRate: .constant(CMTime(value: 2002, timescale: 48000)), declaredTimebases: [1000, 24000])
    XCTAssertEqual(config.timescale, 24000)
    XCTAssertFalse(config.isQuantized)
    var mapper = try RecordingTimebase(configuration: config, origin: CMTime(value: 100, timescale: 1))
    let timing = try mapper.append(pts: CMTime(value: 2402401, timescale: 24000), duration: CMTime(value: 1001, timescale: 24000))
    XCTAssertEqual(timing.presentationTime.value, 2401)
    XCTAssertEqual(timing.presentationTime.timescale, 24000)
    XCTAssertNil(timing.original)
  }

  func testOverflowRequiresExplicitQuantizationAndCFRMustBeExact() throws {
    let vfr = FrameRate.variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    XCTAssertThrowsError(try RecordingTimebase.Configuration(frameRate: vfr, declaredTimebases: [2147483647, 2147483629]))
    let fallback = try RecordingTimebase.Configuration(frameRate: vfr, declaredTimebases: [2147483647, 2147483629], quantizationPolicy: .nearest240000)
    XCTAssertEqual(fallback.timescale, 240000)
    XCTAssertTrue(fallback.isQuantized)
    // An undeclared timestamp scale does not force a representable CFR cadence
    // onto the fallback grid. Actual source timestamps remain checked exactly.
    let exactCFR = try RecordingTimebase.Configuration(frameRate: .constant(CMTime(value: 1, timescale: 7)), declaredTimebases: nil, quantizationPolicy: .nearest240000)
    XCTAssertEqual(exactCFR.timescale, 7)
    XCTAssertFalse(exactCFR.isQuantized)
    // Overflow does require fallback, where this cadence is not exact at 240000.
    XCTAssertThrowsError(try RecordingTimebase.Configuration(frameRate: .constant(CMTime(value: 1, timescale: 7)), declaredTimebases: [2147483647, 2147483629], quantizationPolicy: .nearest240000)) { error in
      XCTAssertEqual(error as? RecordingTimebase.Failure, .exactScaleUnavailable)
    }
    XCTAssertThrowsError(try RecordingTimebase.Configuration(frameRate: vfr, declaredTimebases: [0], quantizationPolicy: .nearest240000))
  }

  func testUndeclaredCFRTimebaseRejectsUnrepresentableSamplesAtomically() throws {
    let duration = CMTime(value: 1, timescale: 7)
    let config = try RecordingTimebase.Configuration(frameRate: .constant(duration), declaredTimebases: nil)
    var mapper = try RecordingTimebase(configuration: config, origin: .zero)
    _ = try mapper.append(pts: .zero, duration: duration)
    XCTAssertThrowsError(try mapper.append(pts: CMTime(value: 1, timescale: 8), duration: duration)) { error in
      XCTAssertEqual(error as? RecordingTimebase.Failure, .unrepresentableTime)
    }
    let next = try mapper.append(pts: CMTime(value: 2, timescale: 14), duration: duration)
    XCTAssertEqual(next.presentationTime.value, 1)
    XCTAssertEqual(next.presentationTime.timescale, 7)
    XCTAssertNil(next.original)
    XCTAssertEqual(mapper.diagnostics.acceptedSamples, 2)
    XCTAssertEqual(mapper.diagnostics.rejectedSamples, 1)
  }

  func testLongVFRRoundsAbsoluteOffsetsWithoutAccumulatedDrift() throws {
    let vfr = FrameRate.variable(nominal: CMTime(value: 1001, timescale: 30000), shortest: CMTime(value: 1, timescale: 1000000), longest: CMTime(value: 1, timescale: 10))
    let config = try RecordingTimebase.Configuration(frameRate: vfr, declaredTimebases: nil, quantizationPolicy: .nearest240000)
    var mapper = try RecordingTimebase(configuration: config, origin: CMTime(value: 9000000000, timescale: 1000000))
    for frame in 0..<10000 {
      let pts = CMTime(value: 9000000000 + Int64(frame) * 33367, timescale: 1000000)
      let sample = try mapper.append(pts: pts, duration: CMTime(value: 33367, timescale: 1000000))
      XCTAssertEqual(sample.presentationTime.value, Int64((Double(frame) * 33367 * 0.24).rounded()))
      XCTAssertNotNil(sample.original)
      XCTAssertEqual(sample.presentationTime.timescale, 240000)
    }
    XCTAssertEqual(mapper.diagnostics.acceptedSamples, 10000)
    XCTAssertEqual(mapper.diagnostics.quantizedSamples, 10000)
    XCTAssertLessThanOrEqual(mapper.diagnostics.maximumTimestampErrorSeconds, 0.5 / 240000 + 1e-15)
    XCTAssertLessThanOrEqual(mapper.diagnostics.maximumIntervalErrorSeconds, 1 / 240000 + 1e-15)
  }

  func testCollisionFailsWithoutAdvancingStateOrRetiming() throws {
    let config = try RecordingTimebase.Configuration(frameRate: .variable(nominal: CMTime(value: 1, timescale: 30), shortest: CMTime(value: 1, timescale: 1000000), longest: CMTime(value: 1, timescale: 10)), declaredTimebases: nil, quantizationPolicy: .nearest240000)
    var mapper = try RecordingTimebase(configuration: config, origin: .zero)
    _ = try mapper.append(pts: .zero, duration: CMTime(value: 1, timescale: 30))
    XCTAssertThrowsError(try mapper.append(pts: CMTime(value: 1, timescale: 1000000), duration: CMTime(value: 1, timescale: 30)))
    XCTAssertEqual(mapper.diagnostics.rejectedSamples, 1)
    XCTAssertEqual(mapper.diagnostics.acceptedSamples, 1)
    let next = try mapper.append(pts: CMTime(value: 1, timescale: 30), duration: CMTime(value: 1, timescale: 30))
    XCTAssertEqual(next.presentationTime.value, 8000)
  }

  func testInvalidTimesAndCFRDurationAreRejected() throws {
    let config = try RecordingTimebase.Configuration(frameRate: .constant(CMTime(value: 1001, timescale: 60000)), declaredTimebases: [60000])
    XCTAssertThrowsError(try RecordingTimebase(configuration: config, origin: .indefinite))
    var mapper = try RecordingTimebase(configuration: config, origin: .zero)
    XCTAssertThrowsError(try mapper.append(pts: .invalid, duration: CMTime(value: 1001, timescale: 60000)))
    XCTAssertThrowsError(try mapper.append(pts: .zero, duration: CMTime(value: 1, timescale: 60)))
    XCTAssertThrowsError(try mapper.append(pts: .zero, duration: .zero))
    _ = try mapper.append(pts: CMTime(value: 1, timescale: 2), duration: CMTime(value: 2002, timescale: 120000))
    XCTAssertThrowsError(try mapper.append(pts: CMTime(value: 499, timescale: 1000), duration: CMTime(value: 1001, timescale: 60000)))
    XCTAssertEqual(mapper.configuration.timescale, 60000)
  }
}
