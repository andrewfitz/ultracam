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
}
