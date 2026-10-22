import Foundation
import SystemExtensions
import XCTest

@MainActor private final class InstallerHarness {
  var signing = ExtensionInstallPreflight(developerSigned: true, hasInstallEntitlement: true)
  var changes = [ExtensionInstaller.Change]()
  var submitted = [OSSystemExtensionRequest]()

  func services() -> ExtensionInstaller.Services {
    ExtensionInstaller.Services(preflight: { self.signing }, makeRequest: { change in
      self.changes.append(change)
      // Creating a request is inert; submission is replaced below. The tests
      // never call OSSystemExtensionManager or ask macOS to install anything.
      switch change {
      case .install: return .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
      case .remove: return .deactivationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
      }
    }, submit: { self.submitted.append($0) })
  }
}

@MainActor @objcMembers final class InstallerChecks: XCTestCase {
  private func callbacks() {
    let completed = expectation(description: "Installer delegate tasks processed")
    DispatchQueue.main.async { DispatchQueue.main.async { completed.fulfill() } }
    wait(for: [completed], timeout: 2)
  }

  func testUnsignedAndMissingEntitlementNeverConstructOrSubmitRequests() {
    for (signed, entitled) in [(false, false), (false, true), (true, false)] {
      let harness = InstallerHarness()
      harness.signing = ExtensionInstallPreflight(developerSigned: signed, hasInstallEntitlement: entitled)
      let installer = ExtensionInstaller(services: harness.services())
      XCTAssertFalse(installer.canRequestChanges)
      XCTAssertTrue(installer.unavailableReason?.contains("developer-signed") == true)
      XCTAssertTrue(installer.unavailableReason?.contains("entitlement") == true)
      XCTAssertTrue(installer.status.contains("Capture and preview still work"))
      installer.install()
      installer.uninstall()
      XCTAssertFalse(installer.pending)
      XCTAssertEqual(installer.status, installer.unavailableReason)
      XCTAssertEqual(harness.changes.count, 0)
      XCTAssertEqual(harness.submitted.count, 0)
    }
  }

  func testValidLocalDevelopmentSignatureAndEntitlementPermitOneRequest() throws {
    let harness = InstallerHarness()
    harness.signing = ExtensionInstallPreflight(developerSigned: false, hasInstallEntitlement: true,
      validLocalSignature: true, localDevelopmentBuild: true)
    let installer = ExtensionInstaller(services: harness.services())
    XCTAssertTrue(installer.canRequestChanges)
    XCTAssertNil(installer.unavailableReason)
    XCTAssertTrue(installer.status.contains("Local camera-extension development build"))
    XCTAssertTrue(installer.status.contains("macOS still controls"))
    XCTAssertFalse(installer.status.contains("developer-signed"))
    installer.install()
    installer.install()
    installer.uninstall()
    XCTAssertTrue(installer.pending)
    XCTAssertEqual(harness.submitted.count, 1)
    XCTAssertTrue(installer.status.contains("local development"))
    installer.request(try XCTUnwrap(harness.submitted.first), didFinishWithResult: .completed)
    callbacks()
    XCTAssertFalse(installer.pending)
  }

  func testLocalSignatureCannotBypassBuildPolicyOrMissingRights() {
    for (valid, entitled, localBuild) in [(false, true, true), (true, false, true),
      (true, true, false), (false, false, true)] {
      let harness = InstallerHarness()
      harness.signing = ExtensionInstallPreflight(developerSigned: false, hasInstallEntitlement: entitled,
        validLocalSignature: valid, localDevelopmentBuild: localBuild)
      let installer = ExtensionInstaller(services: harness.services())
      XCTAssertFalse(installer.canRequestChanges)
      XCTAssertTrue(installer.status.contains("Capture and preview still work"))
      installer.install()
      installer.uninstall()
      XCTAssertFalse(installer.pending)
      XCTAssertEqual(harness.changes.count, 0)
      XCTAssertEqual(harness.submitted.count, 0)
    }
  }

  func testCurrentBuildPolicyComesFromCompilation() {
    let current = ExtensionInstallPreflight.current()
#if ULTRACAM_LOCAL_DEVELOPMENT
    XCTAssertTrue(current.localDevelopmentBuild)
#else
    XCTAssertFalse(current.localDevelopmentBuild)
#endif
    let defaults = ExtensionInstallPreflight(developerSigned: false, hasInstallEntitlement: true)
    XCTAssertFalse(defaults.validLocalSignature)
    XCTAssertFalse(defaults.localDevelopmentBuild)
    XCTAssertNotNil(defaults.unavailableReason)
  }

  func testSigningIsRecheckedBeforeConstructingARequest() {
    let harness = InstallerHarness()
    let installer = ExtensionInstaller(services: harness.services())
    XCTAssertTrue(installer.canRequestChanges)
    XCTAssertNil(installer.unavailableReason)
    harness.signing = ExtensionInstallPreflight(developerSigned: true, hasInstallEntitlement: false)
    installer.install()
    XCTAssertFalse(installer.canRequestChanges)
    XCTAssertFalse(installer.pending)
    XCTAssertEqual(harness.changes.count, 0)
    XCTAssertEqual(harness.submitted.count, 0)
  }

  func testEligibleInstallAndRemoveUseOnePendingRequestAtATime() throws {
    let harness = InstallerHarness()
    let installer = ExtensionInstaller(services: harness.services())
    XCTAssertTrue(installer.canRequestChanges)
    installer.install()
    let activation = try XCTUnwrap(harness.submitted.first)
    XCTAssertTrue(activation.delegate === installer)
    XCTAssertTrue(installer.pending)
    let requestingStatus = installer.status
    installer.install()
    installer.uninstall()
    XCTAssertEqual(harness.submitted.count, 1)
    XCTAssertEqual(harness.changes.count, 1)
    XCTAssertEqual(installer.status, requestingStatus)
    installer.requestNeedsUserApproval(activation)
    callbacks()
    XCTAssertTrue(installer.pending)
    XCTAssertTrue(installer.status.contains("Approve"))
    installer.request(activation, didFinishWithResult: .completed)
    callbacks()
    XCTAssertFalse(installer.pending)
    XCTAssertNil(activation.delegate)
    XCTAssertTrue(installer.status.contains("meeting app"))
    installer.uninstall()
    XCTAssertEqual(harness.submitted.count, 2)
    XCTAssertTrue(harness.changes.last == .remove)
    XCTAssertTrue(installer.pending)
    installer.request(try XCTUnwrap(harness.submitted.last), didFinishWithResult: .completed)
    callbacks()
    XCTAssertFalse(installer.pending)
    XCTAssertEqual(installer.status, "Camera extension removed.")
  }

  func testFailureReleasesPendingAndPermitsRetry() throws {
    let harness = InstallerHarness()
    let installer = ExtensionInstaller(services: harness.services())
    installer.install()
    let first = try XCTUnwrap(harness.submitted.first)
    installer.request(first, didFailWithError: NSError(domain: "InstallerFixture", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Synthetic request rejection"]))
    callbacks()
    XCTAssertFalse(installer.pending)
    XCTAssertNil(first.delegate)
    XCTAssertTrue(installer.status.contains("Synthetic request rejection"))
    XCTAssertTrue(installer.status.contains("Capture and preview still work"))
    installer.install()
    XCTAssertTrue(installer.pending)
    XCTAssertEqual(harness.submitted.count, 2)
    installer.request(try XCTUnwrap(harness.submitted.last), didFinishWithResult: .completed)
    callbacks()
    XCTAssertFalse(installer.pending)
  }

  func testOldCallbacksCannotFinishOrOverwriteANewerRequest() throws {
    let harness = InstallerHarness()
    let installer = ExtensionInstaller(services: harness.services())
    installer.install()
    let old = try XCTUnwrap(harness.submitted.first)
    installer.request(old, didFinishWithResult: .completed)
    callbacks()
    installer.uninstall()
    let current = try XCTUnwrap(harness.submitted.last)
    let pendingStatus = installer.status
    installer.requestNeedsUserApproval(old)
    installer.request(old, didFailWithError: NSError(domain: "StaleInstallerFixture", code: 2))
    installer.request(old, didFinishWithResult: .completed)
    callbacks()
    XCTAssertTrue(installer.pending)
    XCTAssertEqual(installer.status, pendingStatus)
    XCTAssertTrue(current.delegate === installer)
    XCTAssertEqual(harness.submitted.count, 2)
    installer.request(current, didFinishWithResult: .willCompleteAfterReboot)
    callbacks()
    XCTAssertFalse(installer.pending)
    XCTAssertTrue(installer.status.contains("restart"))
  }

  func testFinishClearsPendingWhenTheRequestTokenWasLost() throws {
    let harness = InstallerHarness()
    let installer = ExtensionInstaller(services: harness.services())
    installer.install()
    let request = try XCTUnwrap(harness.submitted.first)
    installer.testingForgetRequestToken()
    XCTAssertTrue(installer.pending)
    installer.request(request, didFinishWithResult: .completed)
    callbacks()
    XCTAssertFalse(installer.pending)
    XCTAssertTrue(installer.status.contains("meeting app"))
    installer.install()
    XCTAssertTrue(installer.pending)
  }

  func testQueuedApprovalCannotOverwriteCompletion() throws {
    let harness = InstallerHarness()
    let installer = ExtensionInstaller(services: harness.services())
    installer.install()
    let request = try XCTUnwrap(harness.submitted.first)
    installer.request(request, didFinishWithResult: .completed)
    installer.requestNeedsUserApproval(request)
    callbacks()
    XCTAssertFalse(installer.pending)
    XCTAssertTrue(installer.status.contains("completed"))
    XCTAssertFalse(installer.status.contains("Approve"))
  }
}
