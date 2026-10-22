import Foundation
import MonitorToolsCore
import XCTest

// The settings boundary with MonitorTools' old configuration: until MonitorTools
// is retired, `LegacyMonitorConfiguration` must read every blob exactly as
// MonitorTools' `MonitorConfiguration` did, and a configuration must survive the
// trip through `MonitorFeedPreferences`. The coordinator itself now keeps
// `MonitorFeedPreferences` (MonitorKit) and reports them whole.
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
    state.tileBindings = [MonitorToolsCore.MonitorTargetID("a"), nil, MonitorToolsCore.MonitorTargetID("program"), nil]
    state.splitRatio = 0.35
    var preferences = MonitorWorkspacePreferences()
    preferences.isConfigured = true
    preferences.layout = .sideBySide
    preferences.tileBindings = ["a", nil, "program", nil]
    preferences.splitRatio = 0.35
    let stateJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? NSDictionary
    let preferencesJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? NSDictionary
    XCTAssertEqual(stateJSON, preferencesJSON)
    XCTAssertEqual(try JSONDecoder().decode(MonitorWorkspacePreferences.self, from: JSONEncoder().encode(state)), preferences)
    let snapshot = AppSettingsSnapshot(monitorWorkspace: preferences)
    XCTAssertEqual(snapshot.monitorWorkspacePreferences, preferences)
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
      XCTAssertEqual(coordinator.preferences(for: alpha), camera)
      XCTAssertEqual(coordinator.preferences(for: .program).state.pictureStage, .source)
      XCTAssertEqual(coordinator.workspace.layout, .sideBySide)
      XCTAssertEqual(coordinator.workspace.tileBindings[1], "program")

      var reported: [(MonitorTargetID, MonitorFeedPreferences)] = []
      var reportedWorkspace: MonitorWorkspacePreferences?
      coordinator.onConfigurationChange = { reported.append(($0, $1)) }
      coordinator.onWorkspaceChange = { reportedWorkspace = $0 }
      var next = coordinator.preferences(for: alpha)
      next.state.focus.enabled = true
      next.state.pictureStage = .monitor
      coordinator.setPreferences(next, for: alpha)
      XCTAssertEqual(reported.count, 1)
      XCTAssertEqual(reported.first?.0, alpha)
      // The whole preferences are reported; the owner saves them as they are.
      let merged = try XCTUnwrap(reported.first?.1)
      XCTAssertTrue(merged.state.focus.enabled)
      XCTAssertEqual(merged.state.zebras[0].range, 4)
      XCTAssertEqual(merged.state.displayTransform.mode, .logToRec709, "MonitorKit-only settings survive")
      XCTAssertEqual(merged.state.pictureStage, .monitor, "So does the Monitor picture stage")
      coordinator.workspace.layout = .fourUp
      XCTAssertEqual(reportedWorkspace?.layout, .fourUp)
      XCTAssertEqual(reportedWorkspace?.tileBindings, ["alpha", "program", nil, nil])
    }
  }

  func testBoundaryResetAndCopyReplaceTheWholePreferences() throws {
    try MainActor.assumeIsolated {
      var alpha = MonitorFeedPreferences(toolsEnabled: true)
      alpha.state.zebras[0].enabled = true
      alpha.state.geometry.desqueeze = 2
      alpha.signal = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine")
      var beta = MonitorFeedPreferences()
      beta.state.falseColor.referenceOffsetStops = 1
      beta.signal = MonitorSignalDeclaration(logProfileID: "arri-logc3-ei800")
      var owned = ["alpha": alpha, "beta": beta]
      let coordinator = MonitorCoordinator(
        feeds: [
          FeedDescriptor(id: FeedID(rawValue: "alpha"), name: "A", monitor: alpha),
          FeedDescriptor(id: FeedID(rawValue: "beta"), name: "B", monitor: beta),
        ], program: MonitorFeedPreferences(), workspace: MonitorWorkspacePreferences())
      var merges = 0
      coordinator.onConfigurationChange = { _, _ in merges += 1 }
      coordinator.onCopySettings = { source, destination in
        guard let tools = owned[source.rawValue], owned[destination.rawValue] != nil else { return nil }
        owned[destination.rawValue]?.copyTools(from: tools)
        return owned[destination.rawValue]?.legacyConfiguration
      }
      coordinator.onResetSettings = { target in
        owned[target.rawValue]?.resetTools()
        return owned[target.rawValue]?.legacyConfiguration
      }

      coordinator.copySettings(from: MonitorTargetID("alpha"), to: MonitorTargetID("beta"))
      let copied = try XCTUnwrap(owned["beta"])
      XCTAssertEqual(copied.state.geometry.desqueeze, 2, "MonitorKit-only settings are copied")
      XCTAssertEqual(copied.signal, beta.signal)
      XCTAssertEqual(copied.state.falseColor.referenceOffsetStops, 1)
      XCTAssertEqual(coordinator.preferences(for: MonitorTargetID("beta")), copied, "The coordinator shows what the owner saved")

      coordinator.resetSettings(for: MonitorTargetID("alpha"))
      XCTAssertEqual(owned["alpha"], MonitorFeedPreferences(), "Desqueeze and the signal are reset too")
      XCTAssertEqual(coordinator.preferences(for: MonitorTargetID("alpha")), MonitorFeedPreferences())
      XCTAssertEqual(merges, 0, "Applied by the owner, not merged back")

      // A target the owner does not know is reported as a change, as before.
      var program = coordinator.preferences(for: .program)
      program.toolsEnabled = true
      program.state.guides.enabled = true
      coordinator.setPreferences(program, for: .program)
      XCTAssertEqual(merges, 1)
      coordinator.resetSettings(for: .program)
      XCTAssertEqual(merges, 2)
      XCTAssertEqual(coordinator.preferences(for: .program), MonitorFeedPreferences())
      coordinator.copySettings(from: MonitorTargetID("beta"), to: .program)
      XCTAssertEqual(merges, 3)
      XCTAssertTrue(coordinator.preferences(for: .program).state.zebras[0].enabled)
    }
  }
}

// MonitorTools' configuration and the app's legacy copy, field by field (the
// coordinator's old boundary, kept for the parity checks above).
private extension MonitorConfiguration {
  init(_ legacy: LegacyMonitorConfiguration) {
    self.init()
    schemaVersion = legacy.schemaVersion
    toolsEnabled = legacy.toolsEnabled
    guides.enabled = legacy.guides.enabled
    guides.thirds = legacy.guides.thirds
    guides.centerCross = legacy.guides.centerCross
    guides.safeArea = legacy.guides.safeArea
    guides.opacity = legacy.guides.opacity
    guides.contrast = legacy.guides.contrast
    zebra.enabled = legacy.zebra.enabled
    zebra.thresholdIRE = legacy.zebra.thresholdIRE
    zebra.widthIRE = legacy.zebra.widthIRE
    zebra.mode = legacy.zebra.mode == .band ? .band : .aboveThreshold
    zebra.opacity = legacy.zebra.opacity
    falseColor.mode = MonitorFalseColorMode(rawValue: legacy.falseColor.mode.rawValue) ?? .off
    falseColor.profileID = legacy.falseColor.profileID
    falseColor.specificationVersion = legacy.falseColor.specificationVersion
    falseColor.exposureIndex = legacy.falseColor.exposureIndex
    falseColor.referenceOffsetStops = legacy.falseColor.referenceOffsetStops
    focus.enabled = legacy.focus.enabled
    focus.color = MonitorPeakingColor(rawValue: legacy.focus.color.rawValue) ?? .red
    focus.sensitivity = legacy.focus.sensitivity
    focus.noiseRejection = legacy.focus.noiseRejection
    focus.opacity = legacy.focus.opacity
    scopes.enabled = legacy.scopes.enabled
    scopes.mode = legacy.scopes.mode == .lumaWaveform ? .lumaWaveform : .rgbParade
    scopes.gain = legacy.scopes.gain
    scopes.graticule = legacy.scopes.graticule
    scopes.refreshHz = legacy.scopes.refreshHz
    pictureStage = legacy.pictureStage == .source ? .source : .processedOutput
    scopeStage = legacy.scopeStage == .source ? .source : .processedOutput
    sourceProfileID = legacy.sourceProfileID
    sourceCodeRange = legacy.sourceCodeRange.map { $0 == .full ? .full : .legal }
    sourceLogMapping = legacy.sourceLogMapping == .fullRescaledToLegal10Bit
      ? .fullRescaledToLegal10Bit : .native10Bit
  }
}

private extension LegacyMonitorConfiguration {
  init(_ configuration: MonitorConfiguration) {
    self.init()
    schemaVersion = configuration.schemaVersion
    toolsEnabled = configuration.toolsEnabled
    guides.enabled = configuration.guides.enabled
    guides.thirds = configuration.guides.thirds
    guides.centerCross = configuration.guides.centerCross
    guides.safeArea = configuration.guides.safeArea
    guides.opacity = configuration.guides.opacity
    guides.contrast = configuration.guides.contrast
    zebra.enabled = configuration.zebra.enabled
    zebra.thresholdIRE = configuration.zebra.thresholdIRE
    zebra.widthIRE = configuration.zebra.widthIRE
    zebra.mode = configuration.zebra.mode == .band ? .band : .aboveThreshold
    zebra.opacity = configuration.zebra.opacity
    falseColor.mode = FalseColorMode(rawValue: configuration.falseColor.mode.rawValue) ?? .off
    falseColor.profileID = configuration.falseColor.profileID
    falseColor.specificationVersion = configuration.falseColor.specificationVersion
    falseColor.exposureIndex = configuration.falseColor.exposureIndex
    falseColor.referenceOffsetStops = configuration.falseColor.referenceOffsetStops
    focus.enabled = configuration.focus.enabled
    focus.color = PeakingColor(rawValue: configuration.focus.color.rawValue) ?? .red
    focus.sensitivity = configuration.focus.sensitivity
    focus.noiseRejection = configuration.focus.noiseRejection
    focus.opacity = configuration.focus.opacity
    scopes.enabled = configuration.scopes.enabled
    scopes.mode = configuration.scopes.mode == .lumaWaveform ? .lumaWaveform : .rgbParade
    scopes.gain = configuration.scopes.gain
    scopes.graticule = configuration.scopes.graticule
    scopes.refreshHz = configuration.scopes.refreshHz
    pictureStage = configuration.pictureStage == .source ? .source : .processedOutput
    scopeStage = configuration.scopeStage == .source ? .source : .processedOutput
    sourceProfileID = configuration.sourceProfileID
    sourceCodeRange = configuration.sourceCodeRange.map { $0 == .full ? .full : .legal }
    sourceLogMapping = configuration.sourceLogMapping == .fullRescaledToLegal10Bit
      ? .fullRescaledToLegal10Bit : .native10Bit
  }
}
