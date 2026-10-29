import Foundation
import XCTest

@objcMembers final class RGBFormatsChecks: XCTestCase {
  func testPackingOrders() throws {
    XCTAssertEqual(try RGBFormatValidator.packRGBA8(red: 1, green: 2, blue: 3, alpha: 4), [1, 2, 3, 4])
    XCTAssertEqual(try RGBFormatValidator.packRGBA8(red: 1, green: 2, blue: 3, alpha: 4, format: .bgra8), [3, 2, 1, 4])
  }

  func testR12LLittleEndianRoundTrip() throws {
    let packed = RGBFormatValidator.packR12L(red: 0x123, green: 0x456, blue: 0x789)
    XCTAssertEqual(packed, [0x23, 0x61, 0x45, 0x89, 0x07])
    let values = try RGBFormatValidator.unpackR12L(packed[...])
    XCTAssertEqual(values.red, 0x123); XCTAssertEqual(values.green, 0x456); XCTAssertEqual(values.blue, 0x789)
  }

  func testMetadataAndStorageValidation() throws {
    let bgra = try RGBFormatMetadata(format: .bgra8, color: .rec709Video, alpha: .premultiplied)
    XCTAssertEqual(bgra.alpha, .premultiplied)
    let data = Data(repeating: 0, count: 16)
    XCTAssertNoThrow(try RGBFormatValidator.validate(data, width: 2, height: 2, bytesPerRow: 8, metadata: bgra))
    XCTAssertThrowsError(try RGBFormatValidator.validate(data, width: 3, height: 2, bytesPerRow: 8, metadata: bgra))
    XCTAssertThrowsError(try RGBFormatMetadata(format: .r12l, alpha: .straight))
    XCTAssertThrowsError(try RGBFormatValidator.packRGBA8(red: 1, green: 2, blue: 3, format: .r12l))
    XCTAssertThrowsError(try RGBFormatValidator.validate(Data(), width: Int.max, height: 1, bytesPerRow: Int.max, metadata: bgra))
  }
}
