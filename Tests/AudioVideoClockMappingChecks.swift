import XCTest
import CoreMedia

@objcMembers final class AudioVideoClockMappingChecks: XCTestCase {
  func testComposesAudioThroughHostAndInverseVideo() throws {
    let audio = try ClockMapping(sourceAnchor: CMTime(value: 1_000, timescale: 100), hostAnchor: CMTime(value: 10_000, timescale: 100), rate: try Rational(1, 1))
    let video = try ClockMapping(sourceAnchor: CMTime(value: 2_000, timescale: 100), hostAnchor: CMTime(value: 9_000, timescale: 100), rate: try Rational(1, 1))
    let mapping = try AudioVideoClockMapping(audio: audio, video: video)
    XCTAssertEqual(try mapping.videoTime(forAudioTime: CMTime(value: 1_100, timescale: 100)).seconds, 31, accuracy: 1e-9)
  }

  func testPreservesNonZeroOriginsAndRejectsMismatchedHostEpoch() throws {
    let a = try ClockMapping(sourceAnchor: CMTime(value: 500, timescale: 1), hostAnchor: CMTime(value: 7_000, timescale: 1), rate: .one)
    let b = try ClockMapping(sourceAnchor: CMTime(value: 900, timescale: 1), hostAnchor: CMTime(value: 7_000, timescale: 1, flags: .valid, epoch: 1), rate: .one)
    XCTAssertThrowsError(try AudioVideoClockMapping(audio: a, video: b))
  }

  func testSampleRateDriftUsesMappingRatioWithoutFloatingAccumulation() throws {
    let a = try ClockMapping(sourceAnchor: CMTime(value: 10, timescale: 1), hostAnchor: CMTime(value: 100, timescale: 1), rate: try Rational(1001, 1000))
    let v = try ClockMapping(sourceAnchor: CMTime(value: 20, timescale: 1), hostAnchor: CMTime(value: 100, timescale: 1), rate: try Rational(1, 1))
    let mapping = try AudioVideoClockMapping(audio: a, video: v)
    let samples = try mapping.audioSamples(forVideoDuration: CMTime(value: 10, timescale: 1), sampleRate: 48_000)
    XCTAssertEqual(samples, 480_000 / 1.001, accuracy: 1e-6)
  }
}
