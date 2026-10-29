import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class RecordingProfileMatrixChecks: XCTestCase {
  private func source(pixel: PixelFormatID = .v210) throws -> SourceFormat {
    try SourceFormat(width: 3840, height: 2160, pixel: pixel,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
  }

  func testCurrentV210RouteAdmitsTenBit422Profiles() throws {
    let source = try source()
    for profile in [.proRes422, .proRes422HQ, .proResLT, .hevcMain10_422] as [RecordingProfileMatrixProfile] {
      XCTAssertNoThrow(try RecordingProfileMatrix.validate(profile, source: source), profile.rawValue)
      XCTAssertTrue(RecordingProfileMatrix.supports(profile, source: source))
    }
  }

  func testUnimplementedChromaConversionsAreRefusedBeforeEncoderAdmission() throws {
    let source = try source()
    for profile in [.hevcMain, .hevcMain10, .proRes4444] as [RecordingProfileMatrixProfile] {
      XCTAssertThrowsError(try RecordingProfileMatrix.validate(profile, source: source)) { error in
        XCTAssertEqual(error as? RecordingProfileMatrixError,
          .unsupportedRepack(profile: profile, source: .v210))
      }
    }
  }

  func testExactCodecAndEncoderContractsDoNotAliasProResVariants() {
    XCTAssertEqual(RecordingProfileMatrixProfile.proResLT.codec, kCMVideoCodecType_AppleProRes422LT)
    XCTAssertEqual(RecordingProfileMatrixProfile.proRes422HQ.codec, kCMVideoCodecType_AppleProRes422HQ)
    XCTAssertEqual(RecordingProfileMatrixProfile.proRes4444.codec, kCMVideoCodecType_AppleProRes4444)
    XCTAssertEqual(RecordingProfileMatrixProfile.proRes4444.encoderPixelFormat, kCVPixelFormatType_64RGBALE)
    XCTAssertEqual(RecordingProfileMatrixProfile.hevcMain.encoderPixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertEqual(RecordingProfileMatrixProfile.hevcMain10.encoderPixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
  }

  func testRGBRepackRoutesRequire4444AndPreserveSourcePacking() throws {
    for (pixel, format) in [(kCVPixelFormatType_32BGRA, RGBFormat.bgra8),
      (kCVPixelFormatType_32RGBA, .rgba8), (OSType(0x72323130), .r210), (OSType(0x5231324c), .r12l)] {
      let sourcePixel = PixelFormatID(rawValue: pixel)
      XCTAssertEqual(try RecordingProfileMatrix.repackRoute(.proRes4444, sourcePixel: sourcePixel), .packedRGB(format))
      XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(.hevcMain10_422, sourcePixel: sourcePixel))
    }
  }

  func testProvenPacked422AndP216RoutesMatchOnly422EncoderProfiles() throws {
    let routes: [(PixelFormatID, RecordingRepackRoute)] = [
      (.twoVuy, .packed422(.twoVuy)), (.yuvs, .packed422(.yuvs)),
      (.uyva, .packed422(.uyva)), (.p216, .p216To422)
    ]
    for (pixel, route) in routes {
      for profile in [.proResLT, .proRes422, .proRes422HQ, .hevcMain10_422] as [RecordingProfileMatrixProfile] {
        XCTAssertEqual(try RecordingProfileMatrix.repackRoute(profile, sourcePixel: pixel), route)
      }
      for profile in [.hevcMain, .hevcMain10, .proRes4444] as [RecordingProfileMatrixProfile] {
        XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(profile, sourcePixel: pixel))
      }
    }
    XCTAssertTrue(RecordingRepackRoute.p216To422.quantizesSource)
    XCTAssertFalse(RecordingRepackRoute.packed422(.twoVuy).quantizesSource)
  }

  func testEightBit420RoutesDoNotAdvertiseMissingMain10Conversion() throws {
    XCTAssertEqual(try RecordingProfileMatrix.repackRoute(.hevcMain, sourcePixel: .video420), .native)
    XCTAssertEqual(try RecordingProfileMatrix.repackRoute(.hevcMain, sourcePixel: .full420), .full420ToVideo420)
    XCTAssertTrue(RecordingRepackRoute.full420ToVideo420.quantizesSource)
    for pixel in [PixelFormatID.video420, .full420] {
      for profile in [.hevcMain10, .hevcMain10_422, .proRes422, .proRes4444] as [RecordingProfileMatrixProfile] {
        XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(profile, sourcePixel: pixel))
      }
    }
  }

  func testPartialSourceMetadataAdmitsRecordingOnlyAfterRecordingProofIsRegistered() throws {
    for (pixel, profile) in [(PixelFormatID.twoVuy, RecordingProfileMatrixProfile.proRes422),
      (.yuvs, .proRes422HQ), (.uyva, .hevcMain10_422), (.p216, .proResLT),
      (.video420, .hevcMain), (.full420, .hevcMain)] {
      let declaration = try source(pixel: pixel)
      let entry = try XCTUnwrap(PixelFormatTable.entry(for: pixel))
      XCTAssertTrue(entry.routes.contains("recording"), "Missing recording proof for \(pixel)")
      XCTAssertTrue(entry.gpuRoutes.contains("recording"), "Missing GPU recording proof for \(pixel)")
      XCTAssertNoThrow(try RecordingProfileMatrix.validate(profile, source: declaration))
    }
    // Pixel metadata alone must never turn an unimplemented recording route on.
    XCTAssertThrowsError(try RecordingProfileMatrix.validate(.hevcMain10, source: source(pixel: .i420)))
  }

  func testNDIPlanarRoutesUseOnlyProvenEncoderContracts() throws {
    XCTAssertEqual(try RecordingProfileMatrix.repackRoute(.hevcMain, sourcePixel: .i420), .i420ToVideo420)
    for profile in [.proResLT, .proRes422, .proRes422HQ, .hevcMain10_422] as [RecordingProfileMatrixProfile] {
      XCTAssertEqual(try RecordingProfileMatrix.repackRoute(profile, sourcePixel: .pa16), .pa16To422)
      XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(profile, sourcePixel: .i420))
    }
    XCTAssertTrue(RecordingRepackRoute.pa16To422.quantizesSource)
    for profile in [.hevcMain, .hevcMain10, .proRes4444] as [RecordingProfileMatrixProfile] {
      XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(profile, sourcePixel: .pa16))
    }
    XCTAssertThrowsError(try RecordingProfileMatrix.repackRoute(.hevcMain10, sourcePixel: .i420))
  }

  func testProfileMatrixEnumeratesSupportedAndPlannedProfiles() {
    XCTAssertEqual(RecordingProfileMatrixProfile.allCases.count, 7)
    XCTAssertEqual(RecordingProfileMatrixProfile.hevcMain10_422.codec, kCMVideoCodecType_HEVC)
    XCTAssertTrue(RecordingProfileMatrixProfile.proRes4444.displayName.contains("4444"))
  }
}
