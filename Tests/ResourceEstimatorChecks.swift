import XCTest

@objcMembers final class ResourceEstimatorChecks: XCTestCase {
  func testHandoffOwnerIsCountedOnce() throws {
    let limits = ResourceLimits(bytes: 100, duration: 2, slots: 3)
    let demands = [ResourceDemand(owner: "frame", stage: .capture, bytes: 60, duration: 1), ResourceDemand(owner: "frame", stage: .gpu, bytes: 60, duration: 1)]
    XCTAssertEqual(try ResourceEstimator.estimate(Set(demands)), ResourceEstimate(bytes: 60, duration: 1, slots: 1))
    var estimator = ResourceEstimator(limits: limits)
    XCTAssertTrue(estimator.admit(demands[0]).isSuccess)
    XCTAssertTrue(estimator.admit(demands[1]).isSuccess)
    XCTAssertEqual(estimator.estimate.bytes, 60)
  }
  func testExplainableLimitRejection() {
    var estimator = ResourceEstimator(limits: .init(bytes: 10, duration: 1, slots: 1))
    let result = estimator.admit(.init(owner: "x", stage: .recording, bytes: 11, duration: 0.1))
    guard case .failure(let error) = result else { return XCTFail("expected refusal") }
    XCTAssertEqual(error, .bytes(required: 11, limit: 10)); XCTAssertTrue(error.description.contains("byte limit"))
  }
  func testInvalidAndOverflowAreChecked() {
    XCTAssertThrowsError(try ResourceEstimator.estimate([.init(owner: "x", stage: .capture, bytes: Int.max, duration: 1), .init(owner: "y", stage: .gpu, bytes: 1, duration: 1)])) { error in
      XCTAssertEqual(error as? ResourceRejection, .overflow("bytes"))
    }
    var estimator = ResourceEstimator(limits: .init(bytes: 10, duration: 1, slots: 1))
    if case .failure(.invalid) = estimator.admit(.init(owner: "", stage: .capture, bytes: 1, duration: 1)) {} else { XCTFail("expected invalid demand") }
  }
  func testAdmissionRejectsOverflowWithoutChangingReservations() {
    var estimator = ResourceEstimator(limits: .init(bytes: Int.max, duration: .greatestFiniteMagnitude, slots: Int.max))
    XCTAssertTrue(estimator.admit(owner: "first", stage: .capture, bytes: Int.max, duration: 0, slots: Int.max).isSuccess)
    XCTAssertEqual(estimator.admit(owner: "bytes", stage: .gpu, bytes: 1, duration: 0, slots: 0), .failure(.overflow("bytes")))
    XCTAssertEqual(estimator.admit(owner: "slots", stage: .gpu, bytes: 0, duration: 0, slots: 1), .failure(.overflow("slots")))
    XCTAssertEqual(estimator.activeOwners, ["first"])
    XCTAssertEqual(estimator.estimate, .init(bytes: Int.max, duration: 0, slots: Int.max))
  }

}
private extension Result { var isSuccess: Bool { if case .success = self { return true }; return false } }
