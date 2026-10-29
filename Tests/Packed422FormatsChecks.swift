import XCTest

@objcMembers final class Packed422FormatsChecks: XCTestCase {
  func testPackedRowsRoundUpOddWidths() throws {
    XCTAssertEqual(try Packed422Format.twoVuy.minimumRowBytes(width: 1920), 3840)
    XCTAssertEqual(try Packed422Format.yuvs.minimumRowBytes(width: 5), 12)
    XCTAssertEqual(try Packed422Format.r210.minimumRowBytes(width: 5), 20)
    XCTAssertEqual(try Packed422Format.r12L.minimumRowBytes(width: 5), 23)
    XCTAssertEqual(try Packed422Format.uyva.minimumRowBytes(width: 5), 12)
    XCTAssertEqual(try Packed422Format.p216.minimumRowBytes(width: 5), 10)
  }

  func testAdmissionRejectsShortRowsAndWrongPlanes() {
    XCTAssertThrowsError(try Packed422Format.twoVuy.validate(width: 4, height: 2, rowBytes: 7))
    XCTAssertThrowsError(try Packed422Format.twoVuy.validate(width: 4, height: 2, rowBytes: 8, planeCount: 2))
    XCTAssertThrowsError(try Packed422Format.p216.validate(width: 4, height: 2, rowBytes: 8, planeCount: 0))
    XCTAssertThrowsError(try Packed422Format.uyva.validate(width: 4, height: 2, rowBytes: 8, dataSize: 23, alphaRowBytes: 4))
    XCTAssertNoThrow(try Packed422Format.uyva.validate(width: 4, height: 2, rowBytes: 8, dataSize: 24, alphaRowBytes: 4))
    XCTAssertThrowsError(try Packed422Format.r12L.minimumRowBytes(width: Int.max))
    XCTAssertNoThrow(try Packed422Format.p216.validate(width: 4, height: 2, rowBytes: 8, dataSize: 32, planeCount: 2))
  }
}
