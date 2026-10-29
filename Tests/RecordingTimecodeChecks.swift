import CoreMedia
import XCTest

@objcMembers final class RecordingTimecodeChecks: XCTestCase {
  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func utc(_ hour: Int, _ minute: Int = 0, _ second: Int = 0, _ nanosecond: Int = 0) -> Date {
    let calendar = utcCalendar
    return calendar.date(
      from: DateComponents(year: 2026, month: 1, day: 2, hour: hour, minute: minute,
        second: second, nanosecond: nanosecond))!
  }

  private func sourceFrame(_ frame: Int64, rate: RecordingFrameRate) -> CMTime {
    CMTime(value: frame * rate.frameDuration.value, timescale: rate.frameDuration.timescale)
  }

  func testWallClockNDFUsesNominalFramesAndSeparatelyStartedFeeds() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let first = RecordingTimecodeSession(frameRate: .fps2997, dropFrame: false,
      startDate: utc(12, 34, 56, 500_000_000), calendar: calendar)
    let second = RecordingTimecodeSession(frameRate: .fps2997, dropFrame: false,
      startDate: utc(12, 34, 57, 500_000_000), calendar: calendar)

    XCTAssertEqual(first.startTimecode.stringValue, "12:34:56:15")
    XCTAssertEqual(first.timecode(for: .zero)?.stringValue, "12:34:56:15")
    XCTAssertEqual(first.timecode(for: sourceFrame(1, rate: .fps2997))?.stringValue, "12:34:56:16")
    XCTAssertEqual(second.timecode(for: .zero)?.stringValue, "12:34:57:15")
    XCTAssertNotEqual(first.timecode(for: .zero), second.timecode(for: .zero))
  }

  func testDropFrameBoundariesAtTenMinutesAndMidnight() {
    let session = RecordingTimecodeSession(frameRate: .fps2997, dropFrame: true,
      startDate: utc(0), calendar: utcCalendar)
    XCTAssertEqual(session.timecode(for: sourceFrame(1_798, rate: .fps2997))?.stringValue,
      "00:00:59;28")
    XCTAssertEqual(session.timecode(for: sourceFrame(1_800, rate: .fps2997))?.stringValue,
      "00:01:00;02")
    XCTAssertEqual(session.timecode(for: sourceFrame(17_982, rate: .fps2997))?.stringValue,
      "00:10:00;00")

    let midnight = RecordingTimecodeSession(frameRate: .fps2997, dropFrame: true,
      startDate: utc(23, 59, 59, 900_000_000), calendar: utcCalendar)
    XCTAssertEqual(midnight.startTimecode.stringValue, "23:59:59;29")
    XCTAssertEqual(midnight.timecode(for: sourceFrame(4, rate: .fps2997))?.stringValue,
      "00:00:00;03")
  }

  func test5994DropFrameUsesFourDroppedLabels() {
    let session = RecordingTimecodeSession(frameRate: .fps5994, dropFrame: true,
      startDate: utc(0), calendar: utcCalendar)
    XCTAssertEqual(session.timecode(for: sourceFrame(3_600, rate: .fps5994))?.stringValue,
      "00:01:00;04")
    XCTAssertEqual(session.timecode(for: sourceFrame(35_964, rate: .fps5994))?.stringValue,
      "00:10:00;00")
  }

  func testSourcePolicyPreservesEmbeddedValueAndRejectsMissingSourceTime() {
    let wallClock = RecordingTimecodeSession(frameRate: .fps2997, dropFrame: true,
      startDate: utc(4), calendar: utcCalendar)
    let embedded = wallClock.startTimecode
    let source = RecordingTimecodeSession(frameRate: .fps2997, dropFrame: true,
      policy: .source, startDate: utc(20), calendar: utcCalendar)
    XCTAssertEqual(source.timecode(for: .zero, sourceTimecode: embedded), embedded)
    XCTAssertNil(source.timecode(for: .zero))
    XCTAssertNil(wallClock.timecode(for: .invalid))
  }

  func testTimecodeParsingAndInvalidDropLabels() {
    let frame = RecordingTimecode(string: "01:02:03;04", frameRate: .fps2997, dropFrame: true)
    XCTAssertEqual(frame?.stringValue, "01:02:03;04")
    XCTAssertNil(RecordingTimecode(string: "00:01:00;00", frameRate: .fps2997, dropFrame: true))
    XCTAssertNil(RecordingTimecode(string: "00:00:00;00", frameRate: .fps2997, dropFrame: false))
    XCTAssertEqual(RecordingTimecode(string: "00:01:00:00", frameRate: .fps2997, dropFrame: false)?.stringValue,
      "00:01:00:00")
    for rate in [RecordingFrameRate.fps2997, .fps5994] {
      XCTAssertEqual(RecordingTimecode(string: "01:02:03;04", frameRate: rate, dropFrame: true)?.stringValue,
        "01:02:03;04")
      XCTAssertEqual(RecordingTimecode(string: "01:02:03:04", frameRate: rate, dropFrame: false)?.stringValue,
        "01:02:03:04")
      for malformed in ["01;02;03;04", "01;02:03;04", "01:02;03;04"] {
        XCTAssertNil(RecordingTimecode(string: malformed, frameRate: rate, dropFrame: true), malformed)
      }
      XCTAssertNil(RecordingTimecode(string: "01;02:03:04", frameRate: rate, dropFrame: false))
    }
  }

  func testQuickTimeTimecodeTrackWritesBigEndianTimeCode32Sample() throws {
    let track = try QuickTimeTimecodeTrack(frameRate: .fps2997, dropFrame: true)
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(track.formatDescription), kCMTimeCodeFormatType_TimeCode32)
    XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(track.formatDescription), 30)
    XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameDuration(track.formatDescription),
      RecordingFrameRate.fps2997.frameDuration)
    XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(track.formatDescription),
      UInt32(kCMTimeCodeFlag_DropFrame | kCMTimeCodeFlag_24HourMax))

    let timecode = RecordingTimecode(frameNumber: 1_800, frameRate: .fps2997, dropFrame: true)
    let sample = try track.sample(for: timecode, at: CMTime(value: 1_800, timescale: 30_000))
    XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 1_800, timescale: 30_000))
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
    var bytes = [UInt8](repeating: 0, count: 4)
    let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    XCTAssertEqual(bytes, [0, 0, 7, 8])
  }

  func testSourceWriterCreatesWallClockAndRecordStartTracksAtBothRates() throws {
    for rate in [RecordingFrameRate.fps2997, .fps5994] {
      let wallClockConfiguration = try SourceRecordingConfiguration(
        feedID: SourceRecordingFeedID("tc-wall-(rate)"),
        outputURL: URL(fileURLWithPath: "/tmp/tc-wall.mov"),
        width: 1_920, height: 1_080, frameRate: rate,
        timecodePolicy: .wallClock, timecodeStartDate: utc(12, 34, 56, 500_000_000))
      let wallClockTrack = try XCTUnwrap(
        AVAssetSourceRecordingWriter.makeTimecodeTrack(for: wallClockConfiguration))
      XCTAssertEqual(wallClockTrack.frameRate, rate)
      XCTAssertTrue(wallClockTrack.dropFrame)
      XCTAssertEqual(wallClockTrack.makeInput().mediaType, .timecode)

      let recordStartConfiguration = try SourceRecordingConfiguration(
        feedID: SourceRecordingFeedID("tc-start-(rate)"),
        outputURL: URL(fileURLWithPath: "/tmp/tc-start.mov"),
        width: 1_920, height: 1_080, frameRate: rate,
        timecodePolicy: .recordStart)
      let recordStartTrack = try XCTUnwrap(
        AVAssetSourceRecordingWriter.makeTimecodeTrack(for: recordStartConfiguration))
      XCTAssertEqual(recordStartTrack.frameRate, rate)
      let session = RecordingTimecodeSession(frameRate: rate, dropFrame: true,
        policy: .recordStart)
      XCTAssertEqual(session.timecode(for: rate.frameDuration)?.frameNumber, 1)

      let sourceConfiguration = try SourceRecordingConfiguration(
        feedID: SourceRecordingFeedID("tc-source-(rate)"),
        outputURL: URL(fileURLWithPath: "/tmp/tc-source.mov"),
        width: 1_920, height: 1_080, frameRate: rate,
        timecodePolicy: .source)
      XCTAssertNil(try AVAssetSourceRecordingWriter.makeTimecodeTrack(for: sourceConfiguration))
    }
  }

  func testPCTimeAnchorSamplesTheComputerClockAndKeepsExplicitDates() throws {
    let explicit = utc(12, 34, 56, 500_000_000)
    let now = utc(8, 15, 30, 250_000_000)
    let anchored = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID("pc-time"),
      outputURL: URL(fileURLWithPath: "/tmp/pc-time.mov"),
      width: 1_920, height: 1_080,
      timecodePolicy: .wallClock, timecodeStartDate: explicit,
      timecodeSamplesComputerClockAtFirstFrame: true)
    XCTAssertEqual(AVAssetSourceRecordingWriter.timecodeAnchorDate(for: anchored, now: now), now)

    let preserved = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID("explicit-clock"),
      outputURL: URL(fileURLWithPath: "/tmp/explicit-clock.mov"),
      width: 1_920, height: 1_080,
      timecodePolicy: .wallClock, timecodeStartDate: explicit)
    XCTAssertFalse(preserved.timecodeSamplesComputerClockAtFirstFrame)
    XCTAssertEqual(AVAssetSourceRecordingWriter.timecodeAnchorDate(for: preserved, now: now), explicit)

    let recordStart = try SourceRecordingConfiguration(
      feedID: SourceRecordingFeedID("record-start"),
      outputURL: URL(fileURLWithPath: "/tmp/record-start.mov"),
      width: 1_920, height: 1_080,
      timecodePolicy: .recordStart, timecodeStartDate: explicit,
      timecodeSamplesComputerClockAtFirstFrame: true)
    XCTAssertEqual(AVAssetSourceRecordingWriter.timecodeAnchorDate(for: recordStart, now: now), explicit)

    let firstFrame = sourceFrame(100, rate: .fps5994)
    let session = RecordingTimecodeSession(frameRate: .fps5994, dropFrame: true,
      policy: .wallClock, startDate: now, sourceStartTime: firstFrame, calendar: utcCalendar)
    XCTAssertEqual(session.timecode(for: firstFrame)?.stringValue, session.startTimecode.stringValue)
    XCTAssertEqual(session.timecode(for: sourceFrame(101, rate: .fps5994))?.frameNumber,
      session.startTimecode.frameNumber + 1)
  }

}
