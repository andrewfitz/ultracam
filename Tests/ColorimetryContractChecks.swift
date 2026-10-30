import XCTest

@objcMembers final class ColorimetryContractChecks: XCTestCase {
  func testPrimariesTransferAndMatrixAreRetained() {
    let c = ColorimetryContract(primaries: .rec2020, transfer: .pq, matrix: .rec2020)
    XCTAssertEqual(c.primaries, .rec2020); XCTAssertEqual(c.transfer, .pq); XCTAssertEqual(c.matrix, .rec2020)
  }
  func testIdentityContractIsRepresentable() {
    XCTAssertEqual(ColorimetryContract.identity.matrix, .identity)
    XCTAssertEqual(ColorimetryContract.identity.colorimetry.matrix, .identity)
  }
  func testSignatureIsStableAndContainsNoRuntimeIdentity() {
    let a = ColorimetryContract.rec709Video
    let b = ColorimetryContract(Colorimetry.rec709Video)
    XCTAssertEqual(a.signature, b.signature)
    XCTAssertEqual(a.signature.count, 64)
  }
  func testSourceProfilePreservesFullRangeMatrixAndBothChromaLocations() {
    let source = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec601,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .top)
    let profile = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .bottom)
    let merged = source.overridingRGBEncoding(with: profile)
    XCTAssertEqual(merged.primaries, .rec2020)
    XCTAssertEqual(merged.transfer, .pq)
    XCTAssertEqual(merged.range, source.range)
    XCTAssertEqual(merged.matrix, source.matrix)
    XCTAssertEqual(merged.horizontalChromaSiting, source.horizontalChromaSiting)
    XCTAssertEqual(merged.verticalChromaSiting, source.verticalChromaSiting)
  }
  func testSourceProfileNilOrMatchingRGBPreservesSourceExactly() {
    let source = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec601,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .top)
    XCTAssertEqual(source.overridingRGBEncoding(with: nil), source)
    XCTAssertEqual(source.overridingRGBEncoding(with: .rec709Video), source)
  }

}
