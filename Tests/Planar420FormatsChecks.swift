import CoreVideo
import XCTest

@objcMembers final class Planar420FormatsChecks: XCTestCase {
  func testOddDimensionsRoundChromaPlaneUp() throws {
    let metadata = Planar420Formats.Metadata(width: 5, height: 3, kind: .video,
      planeWidths: [5, 3], planeHeights: [3, 2], strides: [8, 8], dataSize: 40)
    XCTAssertNoThrow(try Planar420Formats.validate(metadata))
  }

  func testRejectsShortStrideAndWrongExtent() {
    let short = Planar420Formats.Metadata(width: 5, height: 3, kind: .full,
      planeWidths: [5, 3], planeHeights: [3, 2], strides: [4, 6], dataSize: 0)
    XCTAssertThrowsError(try Planar420Formats.validate(short))
    let wrong = Planar420Formats.Metadata(width: 5, height: 3, kind: .video,
      planeWidths: [5, 2], planeHeights: [3, 1], strides: [8, 8])
    XCTAssertThrowsError(try Planar420Formats.validate(wrong))
  }

  func testCheckedCeilArithmeticRejectsInvalidInputs() {
    XCTAssertEqual(try? Planar420Formats.ceilDivide(5, 2), 3)
    XCTAssertNil(try? Planar420Formats.ceilDivide(0, 2))
    XCTAssertNil(try? Planar420Formats.ceilDivide(5, 0))
  }

  func testActualPixelFormatCannotMasqueradeAs420VideoRange() throws {
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, nil, &image), kCVReturnSuccess)
    XCTAssertThrowsError(try Planar420Formats.validate(XCTUnwrap(image)))
  }

  func testBothPlanesMustFitTheAggregateAllocationAndSumCannotOverflow() {
    let short = Planar420Formats.Metadata(width: 4, height: 4, kind: .video,
      planeWidths: [4, 2], planeHeights: [4, 2], strides: [4, 4], dataSize: 20)
    XCTAssertThrowsError(try Planar420Formats.validate(short), "Each plane fits individually, but their sum does not")
    let overflow = Planar420Formats.Metadata(width: 2, height: 1, kind: .video,
      planeWidths: [2, 1], planeHeights: [1, 1], strides: [Int.max, Int.max])
    XCTAssertThrowsError(try Planar420Formats.validate(overflow))
  }
}
