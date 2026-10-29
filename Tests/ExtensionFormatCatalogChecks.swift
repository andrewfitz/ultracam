import CoreMedia
import CoreVideo
import XCTest

@objcMembers final class ExtensionFormatCatalogChecks: XCTestCase {
  func testEveryPublishedContractAllowsAllThirteenExactFrameRates() throws {
    let expected = Set(try FrameRateTarget.allCases.map { try Rational($0.duration.value, Int64($0.duration.timescale)) })
    XCTAssertEqual(expected.count, 13)
    for entry in ExtensionFormatCatalog.published {
      XCTAssertEqual(Set(entry.allowedDurations), expected)
      for rate in FrameRateTarget.allCases { XCTAssertTrue(entry.allows(duration: rate.duration)) }
    }
  }

  func testCompleteColourIdentityAndNoTagOnlyAdmission() throws {
    let legacy = ExtensionFormatCatalog.published[0]
    let pq = try ExtensionFormatContract(width: legacy.width, height: legacy.height, pixel: legacy.pixel,
      colour: Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020, range: .video,
        horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified), allowedDurations: legacy.allowedDurations)
    XCTAssertNotEqual(legacy.id, pq.id)
    XCTAssertNotEqual(legacy, pq)
    XCTAssertNoThrow(try ExtensionFormatCatalog.negotiate(requested: pq,
      duration: CMTime(value: 1, timescale: 30), installed: ExtensionFormatCatalog.published))
    XCTAssertTrue(ExtensionFormatCatalog.published.contains(pq))
    XCTAssertTrue(ExtensionFormatCatalog.candidates.contains(pq))
  }
  func testLegacyOrderIsAppendOnly() throws {
    let legacyPixels: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr10]
    let added = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange]
    let catalog = ExtensionFormatCatalog.legacyPublished
    let expected = [(1920,1080,legacyPixels),(3840,2160,legacyPixels),
      (1920,1080,added),(3840,2160,added),(1280,720,legacyPixels + added)]
      .flatMap { width, height, pixels in pixels.map { "\(width)x\(height):\($0)" } }
    XCTAssertEqual(catalog.map { "\($0.width)x\($0.height):\($0.pixel.rawValue)" }, expected)
    XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
    try ExtensionFormatCatalog.validateAppendOnly(previous: Array(catalog.prefix(8)), proposed: catalog)
    XCTAssertThrowsError(try ExtensionFormatCatalog.validateAppendOnly(previous: catalog, proposed: Array(catalog.reversed())))
    XCTAssertThrowsError(try ExtensionFormatCatalog.validateAppendOnly(previous: catalog, proposed: Array(catalog.dropLast())))
    XCTAssertEqual(catalog[2].colour.range, .full)
  }
  func testInstalledCatalogAndRateContractMustMatch() throws {
    let requested = ExtensionFormatCatalog.published[17]
    XCTAssertThrowsError(try ExtensionFormatCatalog.negotiate(requested: requested,
      duration: CMTime(value: 1, timescale: 30), installed: Array(ExtensionFormatCatalog.published.prefix(8))))
    XCTAssertEqual(try ExtensionFormatCatalog.negotiate(requested: requested,
      duration: CMTime(value: 2, timescale: 60), installed: ExtensionFormatCatalog.published), 17)
    XCTAssertThrowsError(try ExtensionFormatCatalog.negotiate(requested: requested,
      duration: CMTime(value: 1, timescale: 27), installed: ExtensionFormatCatalog.published))
    XCTAssertThrowsError(try ExtensionFormatCatalog.negotiate(requested: requested,
      duration: .invalid, installed: ExtensionFormatCatalog.published))
  }
  func testCanonicalIdentityAndSchemaValidation() throws {
    let original = ExtensionFormatCatalog.published[0]
    let reordered = try ExtensionFormatContract(width: original.width, height: original.height, pixel: original.pixel,
      colour: original.colour, allowedDurations: original.allowedDurations.reversed())
    XCTAssertEqual(original.id, reordered.id)
    XCTAssertEqual(try JSONDecoder().decode(ExtensionFormatContract.self, from: JSONEncoder().encode(original)), original)
    XCTAssertThrowsError(try ExtensionFormatContract(width: 0, height: 1080, pixel: original.pixel,
      colour: original.colour, allowedDurations: original.allowedDurations))
    XCTAssertThrowsError(try ExtensionFormatContract(width: 1920, height: 1080, pixel: original.pixel,
      colour: original.colour, allowedDurations: []))
    let otherScan = try ExtensionFormatContract(width: original.width, height: original.height, pixel: original.pixel,
      scan: .interlaced, colour: original.colour, allowedDurations: original.allowedDurations)
    XCTAssertNotEqual(original.id, otherScan.id)
    let otherAspect = try ExtensionFormatContract(width: original.width, height: original.height, pixelAspect: Rational(4,3),
      pixel: original.pixel, colour: original.colour, allowedDurations: original.allowedDurations)
    XCTAssertNotEqual(original.id, otherAspect.id)
  }
}
