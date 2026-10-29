import Foundation
import MonitorKitCore
import XCTest

@objcMembers final class MonitorLifecycleChecks: XCTestCase {
  func testLegacySnapshotsDefaultMonitoringOff() throws {
    let data = Data(#"{"feeds":[{"id":"default","name":"Legacy"}]}"#.utf8)
    let snapshot = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
    XCTAssertFalse(snapshot.feeds[0].monitor.toolsEnabled)
    XCTAssertFalse(snapshot.programMonitor.toolsEnabled)
    XCTAssertEqual(snapshot.feeds[0].monitor, MonitorFeedPreferences())
    XCTAssertEqual(snapshot.monitorWorkspacePreferences.layout, .single)
  }

  func testIndependentFeedProgramAndWorkspaceRoundTrip() throws {
    var first = MonitorFeedPreferences(toolsEnabled: true)
    first.state.zebras[0].enabled = true
    first.state.zebras[0].level = 89
    var second = MonitorFeedPreferences()
    second.scopes.enabled = true
    var program = MonitorFeedPreferences()
    program.state.pictureStage = .source
    var workspace = MonitorWorkspacePreferences()
    workspace.layout = .sideBySide
    workspace.tileBindings = ["a", "b", nil, nil]
    let snapshot = AppSettingsSnapshot(
      feeds: [
        FeedDescriptor(id: FeedID(rawValue: "a"), monitor: first),
        FeedDescriptor(id: FeedID(rawValue: "b"), monitor: second),
      ], programMonitor: program, monitorWorkspace: workspace)
    let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(decoded, snapshot)
    XCTAssertEqual(decoded.feeds[0].monitor.state.zebras[0].level, 89)
    XCTAssertTrue(decoded.feeds[1].monitor.scopes.enabled)
    XCTAssertEqual(decoded.programMonitor.state.pictureStage, .source)
    XCTAssertEqual(decoded.monitorWorkspacePreferences.tileBindings, ["a", "b", nil, nil])
  }

  func testClosingOneMonitorPreservesRecordingAndOtherFeedDemand() {
    var first = AutomaticFeedPolicy()
    var second = AutomaticFeedPolicy()
    first.previewDemand(true)
    second.previewDemand(true)
    XCTAssertEqual(first.action(ready: true, running: false), .start)
    XCTAssertEqual(second.action(ready: true, running: false), .start)
    first.demand(true)  // Independent recording/camera requirement.
    first.previewDemand(false)
    XCTAssertNil(first.action(ready: true, running: true))
    XCTAssertNil(second.action(ready: true, running: true))
    first.demand(false)
    XCTAssertEqual(first.action(ready: true, running: true), .stop)
    XCTAssertNil(second.action(ready: true, running: true))
  }
  func testProgramTransportUsesOnAirProducerRatherThanSettingsSelection() {
    XCTAssertTrue(
      FeedLifecycleDemandPolicy.programTransportRequired(
        programMode: true,
        cameraRequested: true, onAirProducerRunning: true))
    XCTAssertFalse(
      FeedLifecycleDemandPolicy.programTransportRequired(
        programMode: true,
        cameraRequested: true, onAirProducerRunning: false))
    XCTAssertFalse(
      FeedLifecycleDemandPolicy.programTransportRequired(
        programMode: true,
        cameraRequested: false, onAirProducerRunning: true))
  }

  func testManualHandoffReleasesAutomaticOwnership() {
    XCTAssertFalse(
      FeedLifecycleDemandPolicy.retainsAutomaticOwnership(
        automaticEnabled: false,
        wasAutomaticallyStarted: true))
    XCTAssertTrue(
      FeedLifecycleDemandPolicy.retainsAutomaticOwnership(
        automaticEnabled: true,
        wasAutomaticallyStarted: true))
  }

  func testUnavailableDeviceDoesNotConsumeAutomaticStartAttempt() {
    var policy = AutomaticFeedPolicy()
    policy.previewDemand(true)
    let unavailable = FeedLifecycleDemandPolicy.canStartSource(
      automaticEnabled: true,
      manuallyStopped: false, deviceAvailable: false, loading: false)
    XCTAssertNil(policy.action(ready: unavailable, running: false))
    let connected = FeedLifecycleDemandPolicy.canStartSource(
      automaticEnabled: true,
      manuallyStopped: false, deviceAvailable: true, loading: false)
    XCTAssertEqual(policy.action(ready: connected, running: false), .start)
    XCTAssertNil(policy.action(ready: connected, running: false))
  }

  func testOtherFeedCaptureAndFinishingRecordingBlockTopologyChanges() {
    XCTAssertFalse(
      FeedLifecycleDemandPolicy.canEditTopology(
        loading: false,
        sourceActive: true, recordingActive: false))
    XCTAssertFalse(
      FeedLifecycleDemandPolicy.canEditTopology(
        loading: false,
        sourceActive: false, recordingActive: true))
    XCTAssertTrue(
      FeedLifecycleDemandPolicy.canEditTopology(
        loading: false,
        sourceActive: false, recordingActive: false))
  }

  func testBypassedHeadlessProgramUsesUntouchedSourceContractAndDetectedCadence() {
    let saved = PipelineConfiguration(
      applyLUT: true, downscale: true,
      convertTo420: true, reduceFrameRate: true)
    let bypass = FeedLifecycleDemandPolicy.programContract(
      configuration: saved,
      pipelineEnabled: false, detectedSourceDuration: VideoContract.slowDuration)
    XCTAssertFalse(bypass.applyLUT)
    XCTAssertFalse(bypass.downscale)
    XCTAssertFalse(bypass.convertTo420)
    XCTAssertFalse(bypass.reduceFrameRate)
    XCTAssertEqual(bypass.sourceDuration, VideoContract.slowDuration)
    XCTAssertEqual(bypass.width, 3840)
    XCTAssertEqual(bypass.height, 2160)
    XCTAssertTrue(bypass.untouched)
    var expectedProcessed = saved
    expectedProcessed.sourceDuration = VideoContract.slowDuration
    XCTAssertEqual(
      FeedLifecycleDemandPolicy.programContract(
        configuration: saved,
        pipelineEnabled: true, detectedSourceDuration: VideoContract.slowDuration), expectedProcessed)
    XCTAssertEqual(
      FeedLifecycleDemandPolicy.programContract(
        configuration: saved,
        pipelineEnabled: false, detectedSourceDuration: nil
      ).sourceDuration, saved.sourceDuration)
  }

}
