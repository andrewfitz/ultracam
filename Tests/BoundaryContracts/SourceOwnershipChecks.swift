#if SOURCE_OWNERSHIP_CHECKS
import XCTest

/// Compiles AppModel's actual ownership methods with lightweight session fixtures.
@objcMembers final class SourceOwnershipChecks: XCTestCase {
  func testExclusiveAndUnknownInputsBlockOtherOwners() {
    let model = OwnershipFixture()
    XCTAssertNotNil(model.inputHolder("input", excluding: .b))
    XCTAssertTrue(model.busy(.b))
    model.devices = [.init(id: "input", shareable: false)]
    XCTAssertNotNil(model.inputHolder("input", excluding: .b))
    XCTAssertTrue(model.busy(.b))
    XCTAssertFalse(model.busy(.a))
  }

  func testShareableInputAllowsSeveralCameraAssignmentsAndStarts() {
    let model = OwnershipFixture()
    model.devices = [.init(id: "input", shareable: true)]
    XCTAssertNil(model.inputHolder("input", excluding: .b))
    XCTAssertFalse(model.busy(.b))
    XCTAssertTrue(model.inputShareable("input"))
  }

  func testSharingPermissionDoesNotSurviveLostDeclaration() {
    let model = OwnershipFixture()
    model.devices = [.init(id: "input", shareable: true)]
    XCTAssertFalse(model.busy(.b))
    model.devices = []
    XCTAssertTrue(model.busy(.b))
    XCTAssertFalse(model.inputShareable("missing"))
  }
}
#endif
