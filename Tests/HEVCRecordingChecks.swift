import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest

@objcMembers final class HEVCRecordingChecks: XCTestCase {
  func testAutomaticConversionRefusesUnknownPrimariesAndOddGeometryAtAdmission() throws {
    let colour = Colorimetry(primaries: .unspecified, transfer: .linear, matrix: .identity, range: .full,
      horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified)
    for (width, encoding) in [(320, colour), (321, .rec709Video)] {
      let format = try SourceFormat(width: width, height: 240, pixel: .bgra8, colour: encoding,
        rate: .constant(RecordingFrameRate.fps30.frameDuration))
      XCTAssertThrowsError(try SourceRecordingConfiguration(feedID: .init("admission"),
        outputURL: URL(fileURLWithPath: "/tmp/unused-admission.mp4"), width: width, height: 240,
        videoProfile: .matrix(.hevcMain), fileType: .mp4, render420: { _, _, _ in 0 }, expectedSourceFormat: format))
    }
  }

  func testNativeHEVCPreservesDeclaredAspectAndSourceLabelsInMOVAndMP4() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let rate = RecordingFrameRate.fps30
    for fileType in [AVFileType.mov, .mp4] {
      for aspect in [try Rational(1, 1), try Rational(4, 3)] {
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileType == .mov ? "mov" : "mp4")
        let format = try SourceFormat(width: 320, height: 240, pixelAspect: aspect, pixel: .video420,
          colour: .rec709Video, rate: .constant(rate.frameDuration))
        let source = try SourceAdmissionSnapshot(format: format, epochID: .init(sessionID: UUID(), epoch: 1),
          clockBindings: .init(video: .init()), stage: .recordingSource)
        let render420: SourceRecordingConfiguration.Render420?
        if fileType == .mp4 {
          render420 = { _, _, _ in
            XCTFail("Native video-range 4:2:0 should bypass the renderer")
            return 0
          }
        } else { render420 = nil }
        let configuration = try SourceRecordingConfiguration(feedID: .init("native"), outputURL: url, width: 320, height: 240,
          videoProfile: .matrix(.hevcMain), fileType: fileType, render420: render420, frameRate: rate, timecodePolicy: .source,
          sourceAdmission: source, sidecarMovieURL: url)
        let adapter = try SourceRecordingCallbackAdapter(configuration: configuration)
        try adapter.start()
        XCTAssertEqual(adapter.telemetry.encoderInputFormat, "420v (native)")
        XCTAssertTrue(try XCTUnwrap(adapter.callbacks.takeContext)(.init(sourceAdmission: source, audioDeclaration: .absent)))
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, format.pixel.rawValue,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        for i in 0..<6 {
          let metadata = SourceAdmissionMetadata(pixelBuffer: buffer, presentationTime: CMTimeMultiply(rate.frameDuration, multiplier: Int32(i)),
            duration: rate.frameDuration, epochID: source.epochID, formatSignature: source.formatSignature)
          let label = i == 4 ? nil : try Timecode(hours: 12, minutes: 0, seconds: i < 3 ? 10 : 12, frames: i, dropFrame: false)
          XCTAssertTrue(adapter.appendNativeVideo(buffer, metadata: metadata, source: source, signalValid: true, timecode: label))
        }
        try adapter.stop()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let descriptions = try await video.load(.formatDescriptions)
        let desc = try XCTUnwrap(descriptions.first)
        let size = CMVideoFormatDescriptionGetPresentationDimensions(desc, usePixelAspectRatio: true, useCleanAperture: false)
        XCTAssertEqual(size.width, 320 * CGFloat(aspect.numerator) / CGFloat(aspect.denominator), accuracy: 0.01)
        XCTAssertEqual(size.height, 240)
        let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
        XCTAssertEqual(timecodeTracks.count, fileType == .mov ? 1 : 0)
        if fileType == .mp4 {
          let sidecar = try RecordingTakeSidecar.readSnapshot(for: url)
          XCTAssertEqual(sidecar.metadata.outputContract?.outputColour, format.colour)
          let lines = try String(contentsOf: RecordingTakeSidecar.url(for: url).appendingPathExtension("journal"), encoding: .utf8)
          let events = try lines.split(separator: "\n").map { try JSONDecoder().decode(RecordingTakeSidecar.Event.self, from: Data($0.utf8)) }
          let labels = events.compactMap { $0.nativeTimecodeMetadata?.label }
          XCTAssertTrue(labels.contains("12:00:10:00"))
          XCTAssertTrue(labels.contains("12:00:12:03"))
          XCTAssertTrue(labels.contains("12:00:12:05"))
          XCTAssertTrue(events.contains { $0.kind == "nativeTimecodeGap" && $0.labelSource == "native" })
        }
      }
    }
  }

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
    for width in [0, Int(Int32.max) + 1] {
      XCTAssertThrowsError(try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("invalid-hevc"),
        outputURL: URL(fileURLWithPath: "/tmp/unused-hevc.mov"), width: width, height: 1080,
        videoProfile: .matrix(.hevcMain10_422)))
    }
  }
}
