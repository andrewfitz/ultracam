import Foundation
import XCTest

// The settings boundary with MonitorTools' old configuration (the package is
// retired, W4 step 8): `LegacyMonitorConfiguration` must read every blob exactly
// as MonitorTools' `MonitorConfiguration` did, pinned below as the JSON that
// MonitorToolsCore produced, and a configuration must survive the trip through
// `MonitorFeedPreferences`. The coordinator itself keeps `MonitorFeedPreferences`
// (MonitorKit) and reports them whole.
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
  /// What MonitorToolsCore's `MonitorConfiguration` decoded each of `boundaryBlobs`
  /// to, re-encoded with sorted keys. Captured from the package at 001c229, before
  /// it was retired. Its decoder always normalized, so these are also the
  /// normalized configurations.
  private static let monitorToolsDecoded = [
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":true,"contrast":0.4,"enabled":true,"opacity":1,"safeArea":true,"thirds":false},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","toolsEnabled":true,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","toolsEnabled":false,"zebra":{"enabled":true,"mode":"band","opacity":0.2,"thresholdIRE":120,"widthIRE":30}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"sonySLog3","profileID":"sony-slog3-false-color-v1","referenceOffsetStops":10,"specificationVersion":"sony-monitor-control-pattern2-v1"},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","sourceProfileID":"sony-slog3-sgamut3cine","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"elZone","profileID":"ultracam-elzone-public-chart-v1","referenceOffsetStops":0,"specificationVersion":"Ultracam-PanasonicFW9-Midpoints-v1"},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","sourceProfileID":"sony-slog3-sgamut3","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"sonySLog3","profileID":"sony-slog3-false-color-v1","referenceOffsetStops":0,"specificationVersion":"sony-monitor-control-pattern2-v1"},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","sourceProfileID":"sony-slog3-sgamut3cine","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"arri","profileID":"arri-logc3-ei800","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","sourceProfileID":"arri-logc3-ei800","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":1600,"mode":"off","profileID":"arri-alexa35-logc4-ei800","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","sourceProfileID":"arri-alexa35-logc4-ei800","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"arri","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","sourceProfileID":"arri-logc3-ei800","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"yellow","enabled":true,"noiseRejection":0.5,"opacity":0.3,"sensitivity":0},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"source","scopes":{"enabled":true,"gain":4,"graticule":false,"mode":"lumaWaveform","refreshHz":30},"sourceLogMapping":"native10Bit","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"source","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceCodeRange":"full","sourceLogMapping":"fullRescaledToLegal10Bit","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
    #"{"falseColor":{"exposureIndex":800,"mode":"off","referenceOffsetStops":0},"focus":{"color":"red","enabled":false,"noiseRejection":0.02,"opacity":0.85,"sensitivity":0.5},"guides":{"centerCross":false,"contrast":1,"enabled":false,"opacity":0.65,"safeArea":false,"thirds":true},"pictureStage":"processedOutput","schemaVersion":1,"scopeStage":"processedOutput","scopes":{"enabled":false,"gain":1,"graticule":true,"mode":"rgbParade","refreshHz":15},"sourceLogMapping":"native10Bit","toolsEnabled":false,"zebra":{"enabled":false,"mode":"aboveThreshold","opacity":0.65,"thresholdIRE":95,"widthIRE":5}}"#,
  ]
  /// MonitorToolsCore's `MonitorWorkspaceState` JSON for the workspace built in
  /// `testBoundaryWorkspaceConvertsBothWaysWithTheSameJSON` (captured at 001c229).
  private static let monitorToolsWorkspace =
    #"{"isConfigured":true,"layout":"sideBySide","schemaVersion":1,"splitRatio":0.35,"tileBindings":["a",null,"program",null]}"#

  func testBoundaryLegacyDecoderMatchesMonitorTools() throws {
    XCTAssertEqual(Self.boundaryBlobs.count, Self.monitorToolsDecoded.count)
    for (blob, golden) in zip(Self.boundaryBlobs, Self.monitorToolsDecoded) {
      let legacy = try JSONDecoder().decode(LegacyMonitorConfiguration.self, from: Data(blob.utf8))
      let toolsJSON = Self.withoutELZone(
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(golden.utf8)) as? NSDictionary, blob))
      let legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? NSDictionary
      XCTAssertEqual(legacyJSON, toolsJSON, blob)
      let normalizedJSON =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy.normalized())) as? NSDictionary
      XCTAssertEqual(normalizedJSON, toolsJSON, blob)
      // MonitorTools' JSON reads back as the same configuration.
      XCTAssertEqual(try JSONDecoder().decode(LegacyMonitorConfiguration.self, from: Data(golden.utf8)), legacy, blob)
    }
  }

  /// `json` as Ultracam reads it now: the one departure from MonitorTools is
  /// that EL Zone false colour is gone, so its selection (with its profile
  /// "ultracam-elzone-public-chart-v1" and specification) reads as off.
  private static func withoutELZone(_ json: NSDictionary) -> NSDictionary {
    guard let falseColor = json["falseColor"] as? NSDictionary, falseColor["mode"] as? String == "elZone" else {
      return json
    }
    let off = NSMutableDictionary(dictionary: falseColor)
    off["mode"] = "off"
    off.removeObjects(forKeys: ["profileID", "specificationVersion"])
    let value = NSMutableDictionary(dictionary: json)
    value["falseColor"] = off
    return value
  }

  func testBoundaryConfigurationSurvivesThePreferences() throws {
    for blob in Self.monitorToolsDecoded {
      // MonitorTools' own decoding of each blob (the parity test above pins it).
      let tools = try JSONDecoder().decode(LegacyMonitorConfiguration.self, from: Data(blob.utf8))
      let preferences = MonitorFeedPreferences(migrating: tools)
      var expected = tools.normalized()
      // MonitorKit's exposure offset range is ±6 stops.
      expected.falseColor.referenceOffsetStops = min(6, max(-6, expected.falseColor.referenceOffsetStops))
      if expected.falseColor.mode == .arri && expected.falseColor.profileID == nil {
        expected.falseColor.mode = .off  // Never drawn: no ARRI profile to classify by.
      }
      let back = preferences.legacyConfiguration
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
    let state = Data(Self.monitorToolsWorkspace.utf8)  // MonitorTools' `MonitorWorkspaceState`
    var preferences = MonitorWorkspacePreferences()
    preferences.isConfigured = true
    preferences.layout = .sideBySide
    preferences.tileBindings = ["a", nil, "program", nil]
    preferences.splitRatio = 0.35
    let stateJSON = try JSONSerialization.jsonObject(with: state) as? NSDictionary
    let preferencesJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? NSDictionary
    XCTAssertEqual(stateJSON, preferencesJSON)
    XCTAssertEqual(try JSONDecoder().decode(MonitorWorkspacePreferences.self, from: state), preferences)
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
