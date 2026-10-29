import CoreMedia
import Foundation
import XCTest

@objcMembers final class SourceFormatContractChecks: XCTestCase {
  func testExistingCanonicalSignatureRemainsStable() throws {
    XCTAssertEqual(try format(.constant(CMTime(value: 1001, timescale: 60000))).signature,
      "ebf758677db19bb80184683cbc83f718bb161bcfc66a976af9f8bbaa9c412a73")
  }

  func testLogAndGamutIDsRoundTripAndRemainDistinct() throws {
    let transfers: [Colorimetry.Transfer] = [.canonLog, .canonLog2, .canonLog3,
      .vLog, .blackmagicFilmGen5, .redLog3G10]
    let gamuts: [Colorimetry.Primaries] = [.canonCinemaGamut, .vGamut,
      .blackmagicWideGamutGen5, .redWideGamutRGB]
    XCTAssertEqual(transfers.map(\.rawValue), ["canonLog", "canonLog2", "canonLog3", "vLog", "blackmagicFilmGen5", "redLog3G10"])
    XCTAssertEqual(gamuts.map(\.rawValue), ["canonCinemaGamut", "vGamut", "blackmagicWideGamutGen5", "redWideGamutRGB"])
    var signatures: Set<String> = []
    for transfer in transfers {
      for gamut in gamuts {
        let colour = Colorimetry(primaries: gamut, transfer: transfer, matrix: .rec709,
          range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
        let declared = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
          colour: colour, rate: .constant(CMTime(value: 1, timescale: 24)))
        let decoded = try JSONDecoder().decode(SourceFormat.self, from: JSONEncoder().encode(declared))
        XCTAssertEqual(decoded, declared)
        XCTAssertEqual(decoded.signature, declared.signature)
        signatures.insert(declared.signature)
      }
    }
    XCTAssertEqual(signatures.count, transfers.count * gamuts.count)
  }

  func testSonyAndARRIIDsAreExplicitAndCanonical() throws {
    let profiles: [(Colorimetry.Primaries, Colorimetry.Transfer)] = [
      (.sGamut3, .sLog3), (.sGamut3Cine, .sLog3),
      (.arriWideGamut3, .arriLogC3), (.arriWideGamut4, .arriLogC4)]
    XCTAssertEqual(profiles.map { $0.0.rawValue }, ["sGamut3", "sGamut3Cine", "arriWideGamut3", "arriWideGamut4"])
    XCTAssertEqual(profiles.map { $0.1.rawValue }, ["sLog3", "sLog3", "arriLogC3", "arriLogC4"])
    var signatures: Set<String> = []
    for (primaries, transfer) in profiles {
      let colour = Colorimetry(primaries: primaries, transfer: transfer, matrix: .rec709,
        range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
      let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
        colour: colour, rate: .constant(CMTime(value: 1, timescale: 24)))
      let decoded = try JSONDecoder().decode(SourceFormat.self, from: JSONEncoder().encode(format))
      XCTAssertEqual(decoded.signature, format.signature)
      XCTAssertEqual(decoded.colour, colour)
      signatures.insert(format.signature)
    }
    XCTAssertEqual(signatures.count, profiles.count)
  }

  func testRationalNormalizationAndInvalidDecode() throws {
    XCTAssertEqual(try Rational(2, -4), try Rational(-1, 2))
    XCTAssertThrowsError(try Rational(1, 0))
    XCTAssertThrowsError(try JSONDecoder().decode(Rational.self, from: Data(#"{"numerator":1,"denominator":0}"#.utf8)))
  }

  func testEquivalentTimesHaveSameIdentity() throws {
    let a = try format(.constant(CMTime(value: 1001, timescale: 60000)))
    let b = try format(.constant(CMTime(value: 2002, timescale: 120000)))
    XCTAssertEqual(a, b)
    XCTAssertEqual(a.signature, b.signature)
    XCTAssertEqual(a.signature.count, 64)
    XCTAssertEqual(try JSONDecoder().decode(SourceFormat.self, from: JSONEncoder().encode(a)), a)
    XCTAssertNotEqual(try format(.constant(CMTime(value: 1, timescale: 60))).signature, a.signature)
    XCTAssertNotEqual(CaptureEpochID(sessionID: UUID(), epoch: 0), CaptureEpochID(sessionID: UUID(), epoch: 0))
  }

  func testInvalidFormatBoundary() throws {
    XCTAssertThrowsError(try SourceFormat(width: 0, height: 2160, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 60))))
    XCTAssertThrowsError(try SourceFormat(width: 3840, height: 2160, pixel: PixelFormatID(rawValue: 0), rate: .constant(CMTime(value: 1, timescale: 60))))
    XCTAssertThrowsError(try format(.constant(.indefinite)))
    XCTAssertThrowsError(try format(.variable(nominal: CMTime(value: 1, timescale: 60), shortest: CMTime(value: 1, timescale: 30), longest: CMTime(value: 1, timescale: 24))))
    let good = try JSONEncoder().encode(format(.constant(CMTime(value: 1, timescale: 60))))
    let invalid = String(decoding: good, as: UTF8.self).replacingOccurrences(of: "3840", with: "0")
    XCTAssertThrowsError(try JSONDecoder().decode(SourceFormat.self, from: Data(invalid.utf8)))
  }

  func testClockAnchorsAndRuntimeIdentity() throws {
    let mapping = try ClockMapping(sourceAnchor: CMTime(value: 100, timescale: 1), hostAnchor: CMTime(value: 900, timescale: 1), rate: Rational(1, 1))
    XCTAssertEqual(CMTimeCompare(try mapping.hostTime(for: CMTime(value: 102, timescale: 1)), CMTime(value: 902, timescale: 1)), 0)
    XCTAssertEqual(try JSONDecoder().decode(ClockMapping.self, from: JSONEncoder().encode(mapping)), mapping)
    XCTAssertThrowsError(try ClockMapping(sourceAnchor: .invalid, hostAnchor: .zero, rate: .one))
    XCTAssertThrowsError(try ClockMapping(sourceAnchor: .zero, hostAnchor: .zero, rate: Rational(-1, 1)))
    XCTAssertNotEqual(CaptureClockBindings(video: ClockInstanceID()), CaptureClockBindings(video: ClockInstanceID()))
  }

  func testAudioDeclarationAndTimecodeValidation() throws {
    XCTAssertFalse(SourceAudioDeclaration.unknown.isResolved)
    XCTAssertTrue(SourceAudioDeclaration.absent.isResolved)
    let audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32, interleaved: true, layout: AudioChannelMap(labels: [1, 2]), clock: .pairedWithFrames)
    XCTAssertEqual(try JSONDecoder().decode(SourceAudioFormat.self, from: JSONEncoder().encode(audio)), audio)
    XCTAssertThrowsError(try SourceAudioFormat(sampleRate: .infinity, channels: 2, sample: .int32, interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames))
    XCTAssertThrowsError(try Timecode(hours: 24, minutes: 0, seconds: 0, frames: 0, dropFrame: false))
    XCTAssertFalse(try Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, dropFrame: false).dropFrame)
    XCTAssertEqual(Set(PixelFormatTable.entries.map(\.id)).count, PixelFormatTable.entries.count)
    XCTAssertTrue(PixelFormatTable.entries[0].gpuRoutes.contains("extension"), "B1 GPU proof enables the extension route")
  }

  func testTimecodeChecksDeclaredRateAndDropFrameLabels() throws {
    let rate = FrameRate.constant(CMTime(value: 1001, timescale: 30000))
    XCTAssertThrowsError(try Timecode(hours: 0, minutes: 1, seconds: 0, frames: 0, dropFrame: true).validate(rate: rate))
    XCTAssertNoThrow(try Timecode(hours: 0, minutes: 10, seconds: 0, frames: 0, dropFrame: true).validate(rate: rate))
    XCTAssertNoThrow(try Timecode(hours: 0, minutes: 1, seconds: 0, frames: 0, dropFrame: false).validate(rate: rate))
    XCTAssertThrowsError(try Timecode(hours: 0, minutes: 0, seconds: 0, frames: 30, dropFrame: false).validate(rate: rate))
    XCTAssertThrowsError(try Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, dropFrame: true).validate(rate: .constant(CMTime(value: 1, timescale: 25))))
  }

  private func format(_ rate: FrameRate) throws -> SourceFormat {
    try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: rate)
  }
}
