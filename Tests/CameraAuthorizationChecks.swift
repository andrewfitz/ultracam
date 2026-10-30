import XCTest

@objcMembers final class CameraAuthorizationChecks: XCTestCase {
  func testExpectedIdentifierStillRequiresVerifiedRunningSignature() {
    var checkedPID: pid_t?
    XCTAssertFalse(CameraProducerAuthorization.allows(signingID: "org.ultracam.app", pid: 123) { pid in
      checkedPID = pid
      return false
    })
    XCTAssertEqual(checkedPID, 123, "A matching code identifier does not establish the signing team")
    XCTAssertTrue(CameraProducerAuthorization.allows(signingID: "org.ultracam.app", pid: 123) { $0 == 123 })
  }

  func testMissingIdentifiersRequireVerifiedProcess() {
    for identifier: String? in [nil, "unknown"] {
      var checkedPID: pid_t?
      let allowed = CameraProducerAuthorization.allows(signingID: identifier, pid: 123) { pid in
        checkedPID = pid
        return true
      }
      XCTAssertTrue(allowed)
      XCTAssertEqual(checkedPID, 123)
    }
  }

  func testMissingIdentifiersRejectUnverifiedProcess() {
    for identifier: String? in [nil, "unknown"] {
      XCTAssertFalse(CameraProducerAuthorization.allows(signingID: identifier, pid: 123) { _ in false })
    }
  }

  func testOtherIdentifiersAndInvalidPIDsNeverUseFallback() {
    for identifier: String? in ["", "org.other.app", "UNKNOWN"] {
      XCTAssertFalse(CameraProducerAuthorization.allows(signingID: identifier, pid: 123) { _ in
        XCTFail("An explicit mismatching identifier must never use the fallback")
        return true
      })
    }
    for identifier: String? in [nil, "unknown", "org.ultracam.app"] {
      for pid: pid_t in [0, -1] {
        XCTAssertFalse(CameraProducerAuthorization.allows(signingID: identifier, pid: pid) { _ in
          XCTFail("An invalid PID must never be verified")
          return true
        })
      }
    }
  }

}
