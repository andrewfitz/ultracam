import XCTest

@objcMembers final class NDIPlanarLayoutChecks: XCTestCase {
  func testI420UsesThreePhysicalCeilPlanes() throws {
    let planes = try NDIPlanarLayout.i420.planes(width: 5, height: 3)
    XCTAssertEqual(planes.map(\.width), [5, 3, 3])
    XCTAssertEqual(planes.map(\.height), [3, 2, 2])
    XCTAssertEqual(planes.map(\.minimumRowBytes), [5, 3, 3])
  }
  func testPA16KeepsFullResolutionAlphaAndInterleaved422Chroma() throws {
    let planes = try NDIPlanarLayout.pa16.planes(width: 5, height: 3)
    XCTAssertEqual(planes.map(\.width), [5, 3, 5])
    XCTAssertEqual(planes.map(\.height), [3, 3, 3])
    XCTAssertEqual(planes.map(\.minimumRowBytes), [10, 12, 10])
    XCTAssertThrowsError(try NDIPlanarLayout.pa16.planes(width: Int.max, height: 3))
  }
  func testOffsetsCannotOverlapOrOverflowEvenWithPaddedStrides() throws {
    XCTAssertNoThrow(try NDIPlanarLayout.i420.validate(width: 5, height: 3, offsets: [0, 32, 48], strides: [8, 8, 8], allocationBytes: 64))
    XCTAssertThrowsError(try NDIPlanarLayout.i420.validate(width: 5, height: 3, offsets: [0, 16, 48], strides: [8, 8, 8], allocationBytes: 64))
    XCTAssertThrowsError(try NDIPlanarLayout.pa16.validate(width: 5, height: 3, offsets: [0, 64, 128], strides: [16, 16, Int.max - 1], allocationBytes: Int.max))
  }
}
