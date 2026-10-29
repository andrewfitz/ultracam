import AVFoundation
import XCTest
@objcMembers final class ProResRecordingConfigurationChecks: XCTestCase {
  func testProfilesMatchProductionCodecMatrix() {
    XCTAssertEqual(ProRes422Profile.standard.codecType, RecordingProfileMatrixProfile.proRes422.codec)
    XCTAssertEqual(ProRes422Profile.highQuality.codecType, RecordingProfileMatrixProfile.proRes422HQ.codec)
  }
}
