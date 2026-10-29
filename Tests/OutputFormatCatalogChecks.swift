import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class OutputFormatCatalogChecks: XCTestCase {
  func testLegacyIndicesRemainStableAndVariantsAreComplete() {
    let catalog = OutputFormatCatalog.published
    XCTAssertGreaterThan(catalog.count, ExtensionFormatCatalog.legacyPublished.count)
    XCTAssertEqual(Array(catalog.prefix(ExtensionFormatCatalog.legacyPublished.count)), ExtensionFormatCatalog.legacyPublished)
    XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
    XCTAssertTrue(catalog.allSatisfy { $0.colour.primaries != .unspecified && $0.colour.transfer != .unspecified && $0.colour.matrix != .unspecified })
  }

  func testMatchingRequiresCompleteColourIdentityAndDuration() {
    let entry = OutputFormatCatalog.published.last!
    XCTAssertEqual(OutputFormatCatalog.matchingIndex(entry, duration: CMTime(value: 1, timescale: 30)), OutputFormatCatalog.published.count - 1)
    let wrongDuration = CMTime(value: 1, timescale: 27)
    XCTAssertNil(OutputFormatCatalog.matchingIndex(entry, duration: wrongDuration))
    let wrongColour = try! ExtensionFormatContract(width: entry.width, height: entry.height, pixel: entry.pixel,
      colour: .rec709Video, allowedDurations: entry.allowedDurations)
    XCTAssertNil(OutputFormatCatalog.matchingIndex(wrongColour, duration: CMTime(value: 1, timescale: 30)))
  }

  func testDescriptionsPreserveLegacyAndExposeNativeRangeHDRAndDCI() throws {
    let descriptions = try OutputFormatCatalog.descriptions()
    XCTAssertEqual(descriptions.count, 144)
    for (index, entry) in OutputFormatCatalog.published.enumerated() {
      let description = descriptions[index]
      XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(description).width, Int32(entry.width))
      XCTAssertEqual(entry.colour.range == .full,
        entry.pixel.rawValue == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
    }
    XCTAssertTrue(OutputFormatCatalog.published.contains { $0.width == 4096 && $0.colour.transfer == .hlg })
    for index in 0..<18 {
      let entry = ExtensionFormatCatalog.legacyPublished[index]
      let original = try VideoContract.formatDescription(width: entry.width, height: entry.height, pixelFormat: entry.pixel.rawValue)
      XCTAssertTrue(CFEqual(descriptions[index], original))
    }
  }

  func testUnknownAndMismatchedColourAreRefused() throws {
    let descriptions = try OutputFormatCatalog.descriptions()
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      nil, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    let unknown = try VideoContract.sample(buffer, at: .zero, duration: FrameRateTarget.fps30.duration)
    XCTAssertFalse(OutputFormatCatalog.matches(unknown, description: descriptions[0]))
    XCTAssertNotNil(DerivedOutputContract(format: descriptions[0], duration: FrameRateTarget.fps30.duration).mismatch(unknown))
    for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)] {
      CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
    }
    let pq = try VideoContract.sample(buffer, at: .zero, duration: FrameRateTarget.fps30.duration)
    XCTAssertFalse(OutputFormatCatalog.matches(pq, description: descriptions[0]))
    XCTAssertTrue(OutputFormatCatalog.matches(pq, description: descriptions[24]))
    XCTAssertNotNil(DerivedOutputContract(format: descriptions[0], duration: FrameRateTarget.fps30.duration).mismatch(pq))
    XCTAssertNil(DerivedOutputContract(format: descriptions[24], duration: FrameRateTarget.fps30.duration).mismatch(pq))
    XCTAssertEqual(DerivedOutputContract(format: descriptions[24], duration: FrameRateTarget.fps30.duration).matchingPublishedIndex(in: descriptions), 24)
  }

  func testNativeFullRangeOmissionAndContradiction() throws {
    let published = try OutputFormatCatalog.descriptions()[2]
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, nil, &image), kCVReturnSuccess)
    let buffer = try XCTUnwrap(image)
    for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
      CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
    }
    let sample = try VideoContract.sample(buffer, at: .zero, duration: FrameRateTarget.fps30.duration)
    XCTAssertNil(DerivedOutputContract(format: published, duration: FrameRateTarget.fps30.duration).mismatch(sample))
    var tags = CMFormatDescriptionGetExtensions(published) as! [String: Any]
    tags[kCMFormatDescriptionExtension_FullRangeVideo as String] = false
    var contradictory: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
      width: 1920, height: 1080, extensions: tags as CFDictionary, formatDescriptionOut: &contradictory), noErr)
    XCTAssertFalse(DerivedOutputContract.matchesFormat(try XCTUnwrap(contradictory), published))
  }

  func testCenteredChromaHasDistinctAppendOnlyIdentity() throws {
    let descriptions = try OutputFormatCatalog.descriptions()
    XCTAssertEqual(OutputFormatCatalog.published[72].colour.horizontalChromaSiting, .center)
    XCTAssertEqual(OutputFormatCatalog.published[72].colour.verticalChromaSiting, .center)
    XCTAssertNotEqual(OutputFormatCatalog.published[0].id, OutputFormatCatalog.published[72].id)
    XCTAssertFalse(DerivedOutputContract.matchesFormat(descriptions[0], descriptions[72]))
    XCTAssertTrue(DerivedOutputContract.matchesFormat(descriptions[72], descriptions[72]))
    let value = CMFormatDescriptionGetExtension(descriptions[72], extensionKey: kCMFormatDescriptionExtension_ChromaLocationTopField)
    XCTAssertTrue(CFEqual(try XCTUnwrap(value), kCVImageBufferChromaLocation_Center))
    XCTAssertTrue(OutputFormatCatalog.validateAppendOnly(previous: Array(OutputFormatCatalog.published.prefix(72)), proposed: OutputFormatCatalog.published))
  }

  func testAppendOnlyValidationRejectsReorderingAndRemoval() {
    let catalog = OutputFormatCatalog.published
    XCTAssertTrue(OutputFormatCatalog.validateAppendOnly(previous: Array(catalog.prefix(18)), proposed: catalog))
    XCTAssertFalse(OutputFormatCatalog.validateAppendOnly(previous: catalog, proposed: Array(catalog.dropLast())))
    XCTAssertFalse(OutputFormatCatalog.validateAppendOnly(previous: catalog, proposed: Array(catalog.reversed())))
  }
}
