import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest

@objcMembers final class HEVCRecordingChecks: XCTestCase {
  func testProductionProfilesKeepExactHEVCDepthAndChroma() {
    let profiles: [(RecordingProfileMatrixProfile, String, OSType)] = [
      (.hevcMain, kVTProfileLevel_HEVC_Main_AutoLevel as String, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (.hevcMain10, kVTProfileLevel_HEVC_Main10_AutoLevel as String, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
      (.hevcMain10_422, kVTProfileLevel_HEVC_Main42210_AutoLevel as String, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
    ]
    for (profile, level, pixel) in profiles {
      let production = SourceRecordingVideoProfile.matrix(profile)
      XCTAssertEqual(production.codecType, kCMVideoCodecType_HEVC)
      XCTAssertEqual(production.profileLevel, level)
      XCTAssertEqual(production.encoderPixelFormat, pixel)
      let specification = production.encoderSpecification as NSDictionary
      XCTAssertEqual(specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool, true)
    }
  }
  func testProductionMain422DoesNotSilentlySelect420Route() throws {
    XCTAssertEqual(try RecordingProfileMatrix.repackRoute(.hevcMain10_422, sourcePixel: .v210), .v210To422)
    XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(.hevcMain10, sourcePixel: .v210))
    XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(.hevcMain, sourcePixel: .v210))
  }
  func testProductionConfigurationRejectsInvalidDimensionsBeforeWriterStart() {
    XCTAssertThrowsError(try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("invalid-hevc"),
      outputURL: URL(fileURLWithPath: "/tmp/unused-hevc.mov"), width: 0, height: 1080,
      videoProfile: .matrix(.hevcMain10_422)))
  }
}
