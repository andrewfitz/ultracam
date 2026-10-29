import CoreMedia
import XCTest

@objcMembers final class TimecodeMetadataChecks: XCTestCase {
  func testNativeDropFrameLabelAndEpochArePreserved() {
    let value = TimecodeMetadata.native(label: "01:02:03;04", frameRate: .fps2997, epoch: 7)
    XCTAssertEqual(value?.label, "01:02:03;04")
    XCTAssertEqual(value?.dropFrame, true)
    XCTAssertEqual(value?.epoch, 7)
    XCTAssertEqual(TimecodeMetadata.native(label: "01:02:03:04", frameRate: .fps2997)?.dropFrame, false)
  }

  func testAllRatesPreserveNativeLabelsAndRoundTripExactRational() throws {
    let rates: [RecordingFrameRate] = [.fps23976, .fps24, .fps25, .fps2997, .fps30,
      .fps47952, .fps48, .fps50, .fps5994, .fps60, .fps100, .fps11988, .fps120]
    for rate in rates {
      let value = try XCTUnwrap(TimecodeMetadata(label: "01:02:03:04", frameRate: rate, epoch: 4))
      XCTAssertEqual(value.frameNumber, (3723 * rate.nominalFramesPerSecond) + 4)
      XCTAssertEqual(try JSONDecoder().decode(TimecodeMetadata.self, from: JSONEncoder().encode(value)), value)
      if !rate.supportsDropFrame { XCTAssertNil(TimecodeMetadata(label: "01:02:03;04", frameRate: rate)) }
      let last = RecordingTimecode(frameNumber: rate.nominalFramesPerSecond * 86400 - 1,
        frameRate: rate, dropFrame: false)
      let metadata = TimecodeMetadata(timecode: last)
      XCTAssertEqual(metadata.label(at: rate.frameDuration), "00:00:00:00")
      let track = try QuickTimeTimecodeTrack(frameRate: rate, dropFrame: false)
      XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameDuration(track.formatDescription), rate.frameDuration)
      XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(track.formatDescription), UInt32(rate.nominalFramesPerSecond))
      let sample = try track.sample(for: RecordingTimecode(frameNumber: 258, frameRate: rate, dropFrame: false))
      let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
      var bytes = [UInt8](repeating: 0, count: 4)
      XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &bytes), 0)
      XCTAssertEqual(bytes, [0, 0, 1, 2])
    }
  }

  func testHighRateThreeDigitLabelsAndInvalidDropFrameTrack() throws {
    let native = try XCTUnwrap(TimecodeMetadata(label: "23:59:59:119", frameRate: .fps120))
    XCTAssertEqual(native.frameNumber, 10_367_999)
    XCTAssertEqual(native.label(at: RecordingFrameRate.fps120.frameDuration), "00:00:00:00")
    XCTAssertNil(TimecodeMetadata(label: "23:59:59;119", frameRate: .fps120))
    XCTAssertThrowsError(try QuickTimeTimecodeTrack(frameRate: .fps120, dropFrame: true))
    XCTAssertNil(TimecodeMetadata(label: "00:00:00:120", frameRate: .fps120))
  }

  func testExactRationalNormalizesAndLegacyMetadataDecodes() throws {
    XCTAssertEqual(RecordingFrameRate(numerator: 60000, denominator: 2002), .fps2997)
    let data = Data(#"{"label":"01:02:03;04","rateNumerator":30000,"rateDenominator":1001,"epoch":7,"frameNumber":0,"dropFrame":false}"#.utf8)
    let decoded = try JSONDecoder().decode(TimecodeMetadata.self, from: data)
    XCTAssertEqual(decoded.label, "01:02:03;04")
    XCTAssertTrue(decoded.dropFrame)
  }

  func testOffsetMustRemainInCaptureEpochAndAdvancesNominalFrames() {
    let value = TimecodeMetadata.native(label: "00:00:59;28", frameRate: .fps2997, epoch: 2)
    XCTAssertNil(value?.label(at: CMTime(value: 1, timescale: 1)))
    XCTAssertEqual(value?.label(at: CMTime(value: 2002, timescale: 30000, flags: .valid, epoch: 2)), "00:01:00;02")
  }
}
