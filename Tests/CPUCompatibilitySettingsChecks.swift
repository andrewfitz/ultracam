import Foundation
import XCTest

@MainActor @objcMembers final class CPUCompatibilitySettingsChecks: XCTestCase {
  func testCPUCompatibilityDefaultsOffPersistsAndResets() throws {
    let suite = "CPUCompatibilitySettingsChecks." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettingsStore(defaults: defaults)
    XCTAssertFalse(settings.allowCPUConversion)
    settings.allowCPUConversion = true
    XCTAssertTrue(AppSettingsStore(defaults: defaults).allowCPUConversion)
    settings.allowCPUConversion = false
    XCTAssertFalse(AppSettingsStore(defaults: defaults).allowCPUConversion)
    settings.allowCPUConversion = true
    settings.resetAll()
    XCTAssertFalse(AppSettingsStore(defaults: defaults).allowCPUConversion)
  }

  func testEachTakeSamplesPolicyBeforeDriverPreparation() throws {
    let driver = PolicyDriver()
    let first = FeedID(rawValue: "compatibility-first")
    let second = FeedID(rawValue: "compatibility-second")
    let model = RecordingModel(feeds: [.init(id: first, name: "First"), .init(id: second, name: "Second")], driver: driver)
    model.outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    model.compatibilityPolicy = RecordingCompatibilityPolicy(allowCPUConversion: false)
    model.record(feedID: first)
    model.compatibilityPolicy = RecordingCompatibilityPolicy(allowCPUConversion: true)
    model.record(feedID: second)
    XCTAssertEqual(driver.configurations.count, 2)
    XCTAssertFalse(try XCTUnwrap(driver.configurations.first).compatibilityPolicy.allowCPUConversion)
    XCTAssertTrue(try XCTUnwrap(driver.configurations.last).compatibilityPolicy.allowCPUConversion)
    // A later preference change must not alter either admitted request.
    model.compatibilityPolicy = RecordingCompatibilityPolicy(allowCPUConversion: false)
    XCTAssertTrue(try XCTUnwrap(driver.configurations.last).compatibilityPolicy.allowCPUConversion)
  }

  func testCapturePolicyHolderKeepsAdmittedValueImmutable() {
    let holder = CaptureCompatibilityPolicySnapshot()
    let admitted = holder.snapshot
    holder.update(.init(allowCPUConversion: true))
    XCTAssertFalse(admitted.allowCPUConversion)
    XCTAssertTrue(holder.snapshot.allowCPUConversion)
  }

  func testAppModelPreferenceChangesOnlyTheNextPolicySnapshot() throws {
    let suite = "CPUCompatibilityAppModelChecks." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    let model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults),
      registryPublisher: NoCompatibilityRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      hardware: .offline)
    let admitted = model.sampledRecordingCompatibilityPolicy
    XCTAssertFalse(admitted.allowCPUConversion)
    model.allowCPUConversion = true
    XCTAssertTrue(AppSettingsStore(defaults: defaults).allowCPUConversion)
    XCTAssertTrue(model.sampledRecordingCompatibilityPolicy.allowCPUConversion)
    XCTAssertTrue(model.recordingModel.compatibilityPolicy.allowCPUConversion)
    XCTAssertFalse(admitted.allowCPUConversion)
  }
}

@MainActor private final class NoCompatibilityRegistryPublisher: AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
}

/// Lock protects the captured immutable request snapshots even if a future
/// driver entry point prepares requests on a worker queue.
private final class PolicyDriver: RecordingSessionDriver, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [RecordingConfiguration] = []
  var configurations: [RecordingConfiguration] { lock.withLock { values } }
  func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws { lock.withLock { values.append(configuration) } }
  func pauseRecording(feedID: FeedID) throws {}
  func resumeRecording(feedID: FeedID) throws {}
  func stopRecording(feedID: FeedID) throws {}
}
