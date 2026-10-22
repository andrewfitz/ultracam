import Foundation
import MonitorToolsCore
import XCTest

// The settings boundary while the coordinator still renders with MonitorTools:
// `LegacyMonitorConfiguration` must read every blob exactly as MonitorTools'
// `MonitorConfiguration` did, and a configuration must survive the trip
// through `MonitorFeedPreferences`.
extension MonitorLifecycleChecks {
  private static let boundaryBlobs = [
    "{}",
    #"{"schemaVersion":2,"toolsEnabled":true}"#,
    #"{"toolsEnabled":true,"guides":{"enabled":true,"thirds":false,"centerCross":true,"safeArea":true,"opacity":2,"contrast":0.4}}"#,
    #"{"zebra":{"enabled":true,"thresholdIRE":130,"widthIRE":40,"mode":"band","opacity":0.2}}"#,
    #"{"falseColor":{"mode":"sonySLog3","referenceOffsetStops":12},"sourceProfileID":"sony-slog3-sgamut3cine"}"#,
    #"{"falseColor":{"mode":"elZone","profileID":"elzone-panasonic-varicam-fw9-public-chart"},"sourceProfileID":"sony-slog3-sgamut3"}"#,
    #"{"falseColor":{"mode":"arri","profileID":"arri-style-slog3-logc3-ei800-v1"},"sourceProfileID":"sony-slog3-sgamut3cine"}"#,
    #"{"falseColor":{"mode":"arri","profileID":"arri-logc3-ei800","exposureIndex":800},"sourceProfileID":"arri-logc3-ei800"}"#,
    #"{"falseColor":{"mode":"arri","profileID":"arri-alexa35-logc4-ei800","exposureIndex":1600},"sourceProfileID":"arri-alexa35-logc4-ei800"}"#,
    #"{"falseColor":{"mode":"arri"},"sourceProfileID":"arri-logc3-ei800"}"#,
    #"{"focus":{"enabled":true,"color":"yellow","sensitivity":-1,"noiseRejection":0.5,"opacity":0.3}}"#,
    #"{"scopes":{"enabled":true,"mode":"lumaWaveform","gain":9,"graticule":false,"refreshHz":30},"scopeStage":"source"}"#,
    #"{"pictureStage":"source","sourceCodeRange":"full","sourceLogMapping":"fullRescaledToLegal10Bit"}"#,
    #"{"zebra":{"enabled":"yes"},"guides":{"enabled":true}}"#,
    #"[1,2,3]"#,
  ]

  func testBoundaryLegacyDecoderMatchesMonitorTools() throws {
    for blob in Self.boundaryBlobs {
      let data = Data(blob.utf8)
      let tools = try JSONDecoder().decode(MonitorConfiguration.self, from: data)
      let legacy = try JSONDecoder().decode(LegacyMonitorConfiguration.self, from: data)
      XCTAssertEqual(MonitorConfiguration(legacy), tools, blob)
      XCTAssertEqual(LegacyMonitorConfiguration(tools), legacy, blob)
      XCTAssertEqual(LegacyMonitorConfiguration(tools.normalized()), legacy.normalized(), blob)
      let toolsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tools)) as? NSDictionary
      let legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? NSDictionary
      XCTAssertEqual(toolsJSON, legacyJSON, blob)
    }
  }

  func testBoundaryConfigurationSurvivesThePreferences() throws {
    for blob in Self.boundaryBlobs {
      let tools = try JSONDecoder().decode(MonitorConfiguration.self, from: Data(blob.utf8))
      let preferences = MonitorFeedPreferences(migrating: LegacyMonitorConfiguration(tools))
      var expected = tools.normalized()
      // MonitorKit's exposure offset range is ±6 stops.
      expected.falseColor.referenceOffsetStops = min(6, max(-6, expected.falseColor.referenceOffsetStops))
      if expected.falseColor.mode == .arri && expected.falseColor.profileID == nil {
        expected.falseColor.mode = .off  // Never drawn: no ARRI profile to classify by.
      }
      let back = MonitorConfiguration(preferences.legacyConfiguration)
      XCTAssertEqual(back.falseColor.mode, expected.falseColor.mode, blob)
      if back.falseColor.mode != .off {
        XCTAssertEqual(back.falseColor.profileID, expected.falseColor.profileID, blob)
      }
      // The profile, its version and the exposure index are derived from the
      // mode and the signal now (map §5.3: dropped).
      expected.falseColor.profileID = back.falseColor.profileID
      expected.falseColor.specificationVersion = back.falseColor.specificationVersion
      expected.falseColor.exposureIndex = back.falseColor.exposureIndex
      XCTAssertEqual(back, expected, blob)
    }
  }

  func testBoundaryWorkspaceConvertsBothWaysWithTheSameJSON() throws {
    var state = MonitorWorkspaceState()
    state.isConfigured = true
    state.layout = .sideBySide
    state.tileBindings = [MonitorTargetID("a"), nil, MonitorTargetID("program"), nil]
    state.splitRatio = 0.35
    let preferences = MonitorWorkspacePreferences(state)
    XCTAssertEqual(preferences.tileBindings, ["a", nil, "program", nil])
    XCTAssertEqual(MonitorWorkspaceState(preferences), state)
    let stateJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? NSDictionary
    let preferencesJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? NSDictionary
    XCTAssertEqual(stateJSON, preferencesJSON)
    var snapshot = AppSettingsSnapshot(monitorWorkspace: state)
    XCTAssertEqual(snapshot.monitorWorkspacePreferences, preferences)
    XCTAssertEqual(snapshot.monitorWorkspace, state)
    snapshot.monitorWorkspace.layout = .fourUp
    XCTAssertEqual(snapshot.monitorWorkspacePreferences.layout, .fourUp)
  }

  func testBoundaryCoordinatorRestoresAndReportsPreferences() throws {
    try MainActor.assumeIsolated {
      let feedID = FeedID(rawValue: "alpha")
      var camera = MonitorFeedPreferences(toolsEnabled: true)
      camera.state.zebras[0].enabled = true
      camera.state.zebras[0].range = 4
      camera.state.displayTransform.mode = .logToRec709
      var program = MonitorFeedPreferences()
      program.state.pictureStage = .source
      var workspace = MonitorWorkspacePreferences()
      workspace.layout = .sideBySide
      workspace.tileBindings = ["alpha", "program", nil, nil]
      let coordinator = MonitorCoordinator(
        feeds: [FeedDescriptor(id: feedID, name: "Wide", monitor: camera)], program: program,
        workspace: workspace)
      let alpha = MonitorTargetID("alpha")
      XCTAssertEqual(coordinator.configuration(for: alpha), MonitorConfiguration(camera.legacyConfiguration))
      XCTAssertTrue(coordinator.configuration(for: alpha).toolsEnabled)
      XCTAssertEqual(coordinator.configuration(for: alpha).zebra.widthIRE, 8)
      XCTAssertEqual(coordinator.configuration(for: MonitorTargetID("program")).pictureStage, .source)
      XCTAssertEqual(coordinator.workspace.layout, .sideBySide)
      XCTAssertEqual(coordinator.workspace.tileBindings[1], MonitorTargetID("program"))

      var reported: [(MonitorTargetID, LegacyMonitorConfiguration)] = []
      var reportedWorkspace: MonitorWorkspacePreferences?
      coordinator.onConfigurationChange = { reported.append(($0, $1)) }
      coordinator.onWorkspaceChange = { reportedWorkspace = $0 }
      var next = coordinator.configuration(for: alpha)
      next.focus.enabled = true
      coordinator.setConfiguration(next, for: alpha)
      XCTAssertEqual(reported.count, 1)
      XCTAssertEqual(reported.first?.0, alpha)
      var merged = camera
      merged.merge(try XCTUnwrap(reported.first?.1))
      XCTAssertTrue(merged.state.focus.enabled)
      XCTAssertEqual(merged.state.zebras[0].range, 4)
      XCTAssertEqual(merged.state.displayTransform.mode, .logToRec709, "MonitorKit-only settings survive")
      coordinator.workspace.layout = .fourUp
      XCTAssertEqual(reportedWorkspace?.layout, .fourUp)
      XCTAssertEqual(reportedWorkspace?.tileBindings, ["alpha", "program", nil, nil])
    }
  }
}
