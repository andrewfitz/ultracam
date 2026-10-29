#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import Foundation
import XCTest

@MainActor @objcMembers final class RecordingCadenceSettingsChecks: XCTestCase {
  func testConstantRateCompatibilityDefaultsOffAndUnknownPayloadIsSafe() throws {
    let missing = try JSONDecoder().decode(FeedDescriptor.self, from: Data(#"{"id":"feed"}"#.utf8))
    XCTAssertFalse(missing.recordingConstantFrameRate)
    let malformed = try JSONDecoder().decode(FeedDescriptor.self, from: Data(#"{"id":"feed","selectedDevice":"vendor:opaque","recordingConstantFrameRate":"future-mode"}"#.utf8))
    XCTAssertFalse(malformed.recordingConstantFrameRate)
    XCTAssertEqual(malformed.selectedDevice, "vendor:opaque")
  }
  func testCompatibilityIsStoredPerCameraWithoutChangingCapturePipeline() throws {
    var first = FeedDescriptor(id: .init(rawValue: "first")), second = FeedDescriptor(id: .init(rawValue: "second"))
    let pipeline = first.configuration
    first.recordingConstantFrameRate = true
    second.recordingConstantFrameRate = false
    let snapshot = AppSettingsSnapshot(feeds: [first, second])
    let suite = "RecordingCadenceSettingsChecks." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    AppSettingsStore(defaults: defaults).saveSnapshot(snapshot)
    let decoded = AppSettingsStore(defaults: defaults).loadSnapshot()
    XCTAssertTrue(decoded.feeds[0].recordingConstantFrameRate)
    XCTAssertFalse(decoded.feeds[1].recordingConstantFrameRate)
    XCTAssertEqual(first.configuration, pipeline)
  }
  func testRecordingCompatibilityControlIsVisibleOnlyForVariableSource() {
    var snapshot = UICameraSnapshot(id: "feed", name: "Camera")
    XCTAssertFalse(snapshot.showsRecordingConstantFrameRateCompatibility)
    snapshot.sourceFrameRate = .constant(CMTime(value: 1, timescale: 25))
    XCTAssertFalse(snapshot.showsRecordingConstantFrameRateCompatibility)
    snapshot.sourceFrameRate = .variable(nominal: CMTime(value: 1, timescale: 25), shortest: CMTime(value: 1, timescale: 30), longest: CMTime(value: 1, timescale: 20))
    XCTAssertTrue(snapshot.showsRecordingConstantFrameRateCompatibility)
  }
}
#endif
