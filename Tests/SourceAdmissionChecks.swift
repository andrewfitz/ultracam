import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class SourceAdmissionChecks: XCTestCase {
  func testQualifiedNDISnapshotCanValidateAllProvenStages() throws {
    let format = try SourceFormat(width: 8, height: 4, pixel: .i420,
      rate: .constant(CMTime(value: 1, timescale: 30)))
    let lut = try SourceAdmissionSnapshot(format: format, epochID: epoch(),
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut)
    XCTAssertNoThrow(try SourceAdmissionSnapshot(format: format, epochID: epoch(),
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture))
    XCTAssertNoThrow(try SourceAdmissionSnapshot(format: format, epochID: epoch(),
      clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .recordingSource))
    let frame = SourceAdmissionMetadata(width: 8, height: 4, pixel: .i420, isPlanar: true,
      planeCount: 3, rowBytes: 0, dataSize: 48, presentationTime: .zero,
      duration: format.rate.nominal, epochID: lut.epochID, formatSignature: format.signature,
      planes: [.init(width: 8, height: 4, rowBytes: 8), .init(width: 4, height: 2, rowBytes: 4),
        .init(width: 4, height: 2, rowBytes: 4)])
    XCTAssertNoThrow(try lut.validate(frame, stage: .lut))
    XCTAssertNoThrow(try lut.validate(frame, stage: .recordingSource))
    XCTAssertNoThrow(try lut.validate(frame, stage: .capture))
  }

  func testNDIWriterProofsQualifyCompleteCapture() throws {
    for pixel in [PixelFormatID.uyva, .p216, .i420, .pa16] {
      let entry = try XCTUnwrap(PixelFormatTable.entry(for: pixel))
      XCTAssertEqual(entry.gpuRoutes, ["input", "lut", "program", "recording", "monitor", "extension"])
      XCTAssertTrue(entry.captureQualified)
    }
  }

  func testNDILUTAndCaptureStagesAreBothQualified() throws {
    for pixel in [PixelFormatID.uyva, .i420, .pa16] {
      let format = try SourceFormat(width: 128, height: 64, pixel: pixel,
        rate: .constant(CMTime(value: 1, timescale: 30)))
      XCTAssertNoThrow(try SourceAdmissionSnapshot(format: format, epochID: epoch(),
        clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .lut))
      XCTAssertNoThrow(try SourceAdmissionSnapshot(format: format, epochID: epoch(),
        clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture))
    }
  }

  func testOperationalRestrictionDoesNotNarrowRepresentableFormat() throws {
    let unsupported = try SourceFormat(width: 1920, height: 1080, scan: .interlaced, pixel: .v210, rate: .constant(CMTime(value: 1, timescale: 25)))
    XCTAssertThrowsError(try SourceAdmissionSnapshot(format: unsupported, epochID: epoch(), clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)) { error in
      let text = String(describing: error)
      XCTAssertTrue(text.contains("capture")); XCTAssertTrue(text.contains("1920")); XCTAssertTrue(text.contains("interlaced"))
    }
    XCTAssertNoThrow(try snapshot(rate: .constant(CMTime(value: 1, timescale: 60))))
    XCTAssertNoThrow(try snapshot(rate: .variable(nominal: CMTime(value: 1001, timescale: 60000), shortest: CMTime(value: 1001, timescale: 60000), longest: CMTime(value: 1001, timescale: 60000))))
    XCTAssertNoThrow(try snapshot(rate: .constant(CMTime(value: 2002, timescale: 120000))))
  }

  func testConstantRationalRatesRequireEquivalentDeclaredDuration() throws {
    for duration in [CMTime(value: 1, timescale: 24), CMTime(value: 1001, timescale: 24000),
      CMTime(value: 1, timescale: 120), CMTime(value: 7, timescale: 173)] {
      let contract = try snapshot(rate: .constant(duration))
      var frame = metadata(); frame.formatSignature = contract.formatSignature
      frame.duration = CMTimeMultiply(duration, multiplier: 2)
      XCTAssertThrowsError(try contract.validate(frame, stage: .capture))
      frame.duration = CMTime(value: duration.value * 2, timescale: duration.timescale * 2)
      XCTAssertNoThrow(try contract.validate(frame, stage: .capture))
    }
  }

  func testVariableDurationsMustFallWithinInclusiveDeclaredBounds() throws {
    let shortest = CMTime(value: 1, timescale: 120)
    let longest = CMTime(value: 1, timescale: 24)
    let contract = try snapshot(rate: .variable(nominal: CMTime(value: 1, timescale: 60),
      shortest: shortest, longest: longest))
    var frame = metadata(); frame.formatSignature = contract.formatSignature
    for duration in [shortest, CMTime(value: 1, timescale: 50), longest] {
      frame.duration = duration
      XCTAssertNoThrow(try contract.validate(frame, stage: .recordingSource))
    }
    for duration in [CMTime(value: 1, timescale: 121), CMTime(value: 1, timescale: 23), .zero, .invalid] {
      frame.duration = duration
      XCTAssertThrowsError(try contract.validate(frame, stage: .capture))
    }
  }

  func testVerifiedRecordingRoutesDoNotImplyCompleteCaptureAdmission() throws {
    for pixel in [PixelFormatID.bgra8, .r210, .r12L, .twoVuy, .yuvs, .uyva, .video420, .full420, .p216] {
      let entry = try XCTUnwrap(PixelFormatTable.entry(for: pixel))
      XCTAssertTrue(entry.gpuRoutes.contains("recording"))
      if pixel == .uyva || pixel == .p216 { XCTAssertTrue(entry.captureQualified) }
    }
    for pixel in [PixelFormatID.rgba8] {
      XCTAssertFalse(try XCTUnwrap(PixelFormatTable.entry(for: pixel)).gpuRoutes.contains("recording"))
    }
  }

  func testApprovedCompleteFormatsAdmit720And1080Capture() throws {
    for pixel in [PixelFormatID.twoVuy, .yuvs, .video420, .full420, .bgra8, .r210, .r12L, .uyva, .p216, .i420, .pa16] {
      for (width, height) in [(1280, 720), (1920, 1080)] {
        let format = try SourceFormat(width: width, height: height, pixel: pixel,
          rate: .constant(CMTime(value: 1001, timescale: 60000)))
        let snapshot = try SourceAdmissionSnapshot(format: format, epochID: epoch(),
          clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)
        XCTAssertEqual(snapshot.entry.gpuRoutes, ["input", "lut", "program", "recording", "monitor", "extension"])
      }
    }
  }

  func testDeclaredPartialFormatsRemainRefusedBeforeCapture() throws {
    for pixel in [PixelFormatID.rgba8] {
      let format = try SourceFormat(width: 1920, height: 1080, pixel: pixel,
        rate: .constant(CMTime(value: 1, timescale: 30)))
      XCTAssertThrowsError(try SourceAdmissionSnapshot(format: format, epochID: epoch(),
        clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)) { error in
        XCTAssertTrue(String(describing: error).contains("GPU route"))
      }
    }
  }

  func testPartialPlanarGeometryAndPackedFractionalStrideValidation() throws {
    let planar = try XCTUnwrap(PixelFormatTable.entry(for: .p216))
    var frame = metadata(); frame.width = 5; frame.height = 3; frame.pixel = .p216
    frame.isPlanar = true; frame.planeCount = 2; frame.dataSize = 66
    frame.planes = [.init(width: 5, height: 3, rowBytes: 10), .init(width: 3, height: 3, rowBytes: 12)]
    XCTAssertNoThrow(try SourceAdmissionSnapshot.validateLayout(frame, entry: planar))
    frame.planes[1].rowBytes = 10
    XCTAssertThrowsError(try SourceAdmissionSnapshot.validateLayout(frame, entry: planar))
    frame.planes[1].rowBytes = 12; frame.planes[1].width = 2
    XCTAssertThrowsError(try SourceAdmissionSnapshot.validateLayout(frame, entry: planar))
    frame.planes[1].width = 3; frame.dataSize = 65
    XCTAssertThrowsError(try SourceAdmissionSnapshot.validateLayout(frame, entry: planar))
    frame.dataSize = 0; frame.planes[1].rowBytes = Int.max - 1
    XCTAssertThrowsError(try SourceAdmissionSnapshot.validateLayout(frame, entry: planar))
    let rgb = try XCTUnwrap(PixelFormatTable.entry(for: .r12L))
    XCTAssertEqual(try SourceAdmissionSnapshot.minimumPackedRowBytes(entry: rgb, width: 1), 5)
    XCTAssertEqual(try SourceAdmissionSnapshot.minimumPackedRowBytes(entry: rgb, width: 3), 14)
  }

  func testNDIPhysicalPlanesMatchVerifiedIngestStorage() throws {
    let i420 = try XCTUnwrap(PixelFormatTable.entry(for: .i420))
    let pa16 = try XCTUnwrap(PixelFormatTable.entry(for: .pa16))
    let uyva = try XCTUnwrap(PixelFormatTable.entry(for: .uyva))
    var frame = metadata(); frame.width = 8; frame.height = 4; frame.isPlanar = true
    for (entry, planes, bytes) in [(i420,
      [VideoBufferLayout.Plane(width: 8, height: 4, rowBytes: 8), .init(width: 4, height: 2, rowBytes: 4), .init(width: 4, height: 2, rowBytes: 4)], 48),
      (pa16, [.init(width: 8, height: 4, rowBytes: 16), .init(width: 4, height: 4, rowBytes: 16), .init(width: 8, height: 4, rowBytes: 16)], 192),
      (uyva, [.init(width: 8, height: 4, rowBytes: 16), .init(width: 8, height: 4, rowBytes: 8)], 96)] {
      frame.pixel = entry.id; frame.planes = planes; frame.planeCount = planes.count; frame.dataSize = bytes
      XCTAssertNoThrow(try SourceAdmissionSnapshot.validateLayout(frame, entry: entry))
      frame.planes.removeLast()
      XCTAssertThrowsError(try SourceAdmissionSnapshot.validateLayout(frame, entry: entry))
      frame.planes = planes; frame.dataSize -= 1
      XCTAssertThrowsError(try SourceAdmissionSnapshot.validateLayout(frame, entry: entry))
    }
  }

  func testPartialPlanarMetadataExtractionUsesActualCoreVideoPlanes() throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      nil, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    let metadata = SourceAdmissionMetadata(pixelBuffer: buffer, presentationTime: .zero,
      duration: CMTime(value: 1, timescale: 30), epochID: epoch(), formatSignature: "layout-only")
    XCTAssertEqual(metadata.planes.count, 2)
    XCTAssertEqual(metadata.planes[1].width, 64)
    XCTAssertEqual(metadata.planes[1].height, 32)
    XCTAssertNoThrow(try SourceAdmissionSnapshot.validateLayout(metadata,
      entry: XCTUnwrap(PixelFormatTable.entry(for: .full420))))
  }

  func testPackedChromaSubsamplingDoesNotHalvePhysicalPlaneWidth() throws {
    let entry = try XCTUnwrap(PixelFormatTable.entry(for: .v210))
    XCTAssertEqual(entry.planes[0].horizontalSubsampling, 2, "Describes chroma sampling, not packed plane width")
    let extent = try SourceAdmissionSnapshot.physicalPlaneExtent(entry: entry, plane: 0, width: 3840, height: 2160)
    XCTAssertEqual(extent.width, 3840)
    XCTAssertEqual(extent.height, 2160)
    XCTAssertEqual(try SourceAdmissionSnapshot.minimumPackedRowBytes(entry: entry, width: 3840), 10240)
    XCTAssertThrowsError(try SourceAdmissionSnapshot.minimumPackedRowBytes(entry: entry, width: Int.max))
  }

  func testMetadataMismatchAndMalformedTimingHaveActionableRefusal() throws {
    let contract = try snapshot()
    let valid = metadata()
    XCTAssertNoThrow(try contract.validate(valid, stage: .recordingSource))
    var misaligned = valid; misaligned.rowBytes = 10244; misaligned.dataSize = 10244 * 2160
    XCTAssertThrowsError(try contract.validate(misaligned, stage: .recordingSource)) { error in
      XCTAssertTrue(String(describing: error).contains("alignment"))
    }
    var short = valid; short.rowBytes = 10236
    XCTAssertThrowsError(try contract.validate(short, stage: .recordingSource)) { error in
      XCTAssertTrue(String(describing: error).contains("recording source"))
      XCTAssertTrue(String(describing: error).contains("stride"))
    }
    var invalid = valid; invalid.duration = .invalid
    XCTAssertThrowsError(try contract.validate(invalid, stage: .capture)) { error in
      XCTAssertTrue(String(describing: error).contains("duration"))
    }
    var changed = valid; changed.width = 1920
    XCTAssertThrowsError(try contract.validate(changed, stage: .capture))
    changed = valid; changed.pixel = PixelFormatID(rawValue: 0x34323076)
    XCTAssertThrowsError(try contract.validate(changed, stage: .capture))
    changed = valid; changed.duration = CMTime(value: 1001, timescale: 30000)
    XCTAssertThrowsError(try contract.validate(changed, stage: .capture))
    changed = valid; changed.epochID = epoch()
    XCTAssertThrowsError(try contract.validate(changed, stage: .capture))
    changed = valid; changed.formatSignature = "wrong"
    XCTAssertThrowsError(try contract.validate(changed, stage: .capture))
  }

  func testLayoutExtentAndAllocationChecksUseCheckedArithmetic() throws {
    let contract = try snapshot()
    var frame = metadata(); frame.rowBytes = Int.max
    XCTAssertThrowsError(try contract.validate(frame, stage: .capture))
    frame = metadata(); frame.dataSize -= 1
    XCTAssertThrowsError(try contract.validate(frame, stage: .capture))
    frame = metadata(); frame.isPlanar = true
    XCTAssertThrowsError(try contract.validate(frame, stage: .capture))
    frame = metadata(); frame.dataSize = 0
    XCTAssertNoThrow(try contract.validate(frame, stage: .capture), "CoreVideo may report no aggregate size; retained allocation admission stays separate")
  }

  func testImmutableOldSnapshotRejectsNewEpochWithoutChangingSignature() throws {
    let old = try snapshot()
    let new = try SourceAdmissionSnapshot(format: old.format, epochID: epoch(), clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)
    XCTAssertEqual(old.formatSignature, new.formatSignature)
    XCTAssertNotEqual(old.epochID, new.epochID)
    XCTAssertNoThrow(try old.validate(metadata(), stage: .capture))
    XCTAssertThrowsError(try new.validate(metadata(), stage: .capture))
  }

  func testEpochSnapshotCarriesImmutableSourceSizeProjection() throws {
    let contract = try snapshot()
    XCTAssertEqual(contract.sourceSize.width, 3840)
    XCTAssertEqual(contract.sourceSize.height, 2160)
    XCTAssertEqual(contract.sourceSize.pixelAspect, .one)
    XCTAssertEqual(contract.sourceSize.displayAspect, try! Rational(16, 9))
  }

  func testAdmissionPreservesDeclaredSizesAndPixelAspect() throws {
    for (width, height, aspect) in [(1280, 720, Rational.one), (1920, 1080, .one),
      (4096, 2160, .one), (1080, 1920, .one), (1440, 1080, try Rational(4, 3)),
      (641, 479, .one)] {
      let format = try SourceFormat(width: width, height: height, pixelAspect: aspect,
        pixel: .v210, rate: .constant(CMTime(value: 1001, timescale: 60000)))
      for stage in [SourceAdmissionStage.capture, .lut, .recordingSource] {
        let snapshot = try SourceAdmissionSnapshot(format: format, epochID: epoch(),
          clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: stage)
        XCTAssertEqual(snapshot.sourceSize, try SourceSize(format))
        let minimum = try SourceAdmissionSnapshot.minimumPackedRowBytes(entry: snapshot.entry, width: width)
        let stride = (minimum + 127) / 128 * 128
        let frame = SourceAdmissionMetadata(width: width, height: height, pixel: .v210,
          isPlanar: false, planeCount: 0, rowBytes: stride, dataSize: stride * height,
          presentationTime: .zero, duration: format.rate.nominal, epochID: snapshot.epochID,
          formatSignature: snapshot.formatSignature)
        XCTAssertNoThrow(try snapshot.validate(frame, stage: stage))
      }
    }
  }

  func testPlanarExtentRoundsUpWithoutOverflowOrInvalidDivisors() throws {
    XCTAssertEqual(try SourceAdmissionSnapshot.subsampledExtent(5, divisor: 2), 3)
    XCTAssertEqual(try SourceAdmissionSnapshot.subsampledExtent(Int.max, divisor: 2), Int.max / 2 + 1)
    XCTAssertThrowsError(try SourceAdmissionSnapshot.subsampledExtent(5, divisor: 0))
    XCTAssertThrowsError(try SourceAdmissionSnapshot.subsampledExtent(0, divisor: 2))
  }

  func testMetadataExtractionReadsActualPixelBufferGeometry() throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_422YpCbCr10, nil, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    let contract = try snapshot()
    let metadata = SourceAdmissionMetadata(pixelBuffer: buffer, presentationTime: .zero, duration: contract.format.rate.nominal, epochID: contract.epochID, formatSignature: contract.formatSignature)
    XCTAssertEqual(metadata.width, 1280)
    XCTAssertEqual(metadata.height, 720)
    XCTAssertEqual(metadata.pixel, .v210)
    XCTAssertFalse(metadata.isPlanar)
    XCTAssertEqual(metadata.rowBytes, CVPixelBufferGetBytesPerRow(buffer))
    XCTAssertThrowsError(try contract.validate(metadata, stage: .capture))
  }

  private let sessionID = UUID()
  private func epoch() -> CaptureEpochID { CaptureEpochID(sessionID: UUID(), epoch: 0) }
  private func snapshot(rate: FrameRate = .constant(CMTime(value: 1001, timescale: 60000))) throws -> SourceAdmissionSnapshot {
    try SourceAdmissionSnapshot(format: SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: rate), epochID: CaptureEpochID(sessionID: sessionID, epoch: 0), clockBindings: CaptureClockBindings(video: ClockInstanceID()), stage: .capture)
  }
  private func metadata() -> SourceAdmissionMetadata {
    SourceAdmissionMetadata(width: 3840, height: 2160, pixel: .v210, isPlanar: false, planeCount: 0, rowBytes: 10240, dataSize: 10240 * 2160, presentationTime: .zero, duration: CMTime(value: 1001, timescale: 60000), epochID: CaptureEpochID(sessionID: sessionID, epoch: 0), formatSignature: try! snapshot().formatSignature)
  }
}
