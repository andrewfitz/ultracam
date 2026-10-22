import Foundation
import MonitorKitCore
import MonitorKitScopes
import XCTest

// W4 step 4: the MonitorTools `MonitorConfiguration` blob migrates field by
// field to `MonitorFeedPreferences` (integration map §5.3, one test per row),
// never decodes as a `MonitorState`, and is written back untouched.
extension MonitorLifecycleChecks {
  private static let sonyCine = "sony-slog3-sgamut3cine"

  /// A feed whose only monitor settings are the old blob `configuration` (JSON object text).
  private func migratedFeed(_ configuration: String) throws -> FeedDescriptor {
    let json = #"{"version":1,"id":"a","name":"A","monitorConfiguration":"# + configuration + "}"
    return try JSONDecoder().decode(FeedDescriptor.self, from: Data(json.utf8))
  }

  private func migrated(_ configuration: String) throws -> MonitorFeedPreferences {
    try migratedFeed(configuration).monitor
  }

  private func jsonObject(_ data: Data) throws -> NSDictionary {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  // MARK: schemaVersion: the trap (map §5.2)

  func testMigrationOldBlobNeverDecodesAsMonitorState() throws {
    let blob = #"""
      {"schemaVersion":1,"toolsEnabled":false,
       "guides":{"enabled":true,"thirds":true,"opacity":0.5},
       "zebra":{"enabled":true,"thresholdIRE":80},
       "focus":{"enabled":true,"color":"green"},
       "falseColor":{"mode":"sonySLog3","referenceOffsetStops":2},
       "sourceProfileID":"sony-slog3-sgamut3cine"}
      """#
    XCTAssertThrowsError(try JSONDecoder().decode(MonitorState.self, from: Data(blob.utf8)))
    XCTAssertEqual(MonitorState.decodedOrDefault(from: Data(blob.utf8)), MonitorState())

    // The old blob under the new key is rejected as a whole, not partly read:
    // the feed migrates from the legacy key and keeps everything else.
    let json = #"{"version":1,"id":"a","name":"Kept","monitor":{"schemaVersion":1,"toolsEnabled":true,"state":"#
      + blob + #"},"monitorConfiguration":"# + blob + "}"
    let feed = try JSONDecoder().decode(FeedDescriptor.self, from: Data(json.utf8))
    XCTAssertEqual(feed.name, "Kept")
    XCTAssertEqual(feed.monitor, try migrated(blob))
    XCTAssertFalse(feed.monitor.toolsEnabled, "The master switch comes from the legacy blob")
    let shown = feed.monitor.surfaceState(isProgram: false)
    XCTAssertFalse(shown.guides.enabled, "Tools switched off by the master switch must not come back on")
    XCTAssertFalse(shown.focus.enabled)
    XCTAssertEqual(shown.falseColor.mode, .off)
    XCTAssertFalse(shown.zebras.contains(where: \.enabled))

    let snapshot = #"{"version":2,"selectedFeedID":"a","feeds":["# + json + "]}"
    let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: Data(snapshot.utf8))
    XCTAssertNotNil(decoded.validated(), "A foreign monitor blob must not cost the feeds")
  }

  func testMigrationOtherSchemaVersionMigratesAsDefaults() throws {
    let value = try migrated(#"{"schemaVersion":2,"toolsEnabled":true,"zebra":{"enabled":true}}"#)
    XCTAssertEqual(value, MonitorFeedPreferences(migrating: LegacyMonitorConfiguration()))
    XCTAssertFalse(value.toolsEnabled)
  }

  // MARK: toolsEnabled

  func testMigrationMasterSwitchOffKeepsToolSettingsButHidesThem() throws {
    let blob = #"""
      {"toolsEnabled":false,"guides":{"enabled":true},"zebra":{"enabled":true},
       "focus":{"enabled":true},"scopes":{"enabled":true},
       "falseColor":{"mode":"elZone"},"sourceProfileID":"sony-slog3-sgamut3cine"}
      """#
    let off = try migrated(blob)
    XCTAssertFalse(off.toolsEnabled)
    XCTAssertTrue(off.state.guides.enabled, "Sub-values are kept")
    XCTAssertTrue(off.state.zebras[0].enabled)
    XCTAssertTrue(off.state.focus.enabled)
    XCTAssertTrue(off.scopes.enabled)
    XCTAssertEqual(off.state.falseColor.mode, .elZone)
    XCTAssertFalse(off.state.clean, "The master switch is not Clean View")
    let hidden = off.surfaceState(isProgram: false)
    XCTAssertFalse(hidden.guides.enabled)
    XCTAssertFalse(hidden.zebras.contains(where: \.enabled))
    XCTAssertFalse(hidden.focus.enabled)
    XCTAssertEqual(hidden.falseColor.mode, .off)
    XCTAssertFalse(hidden.clipIndicators.enabled)
    XCTAssertFalse(off.scopesShown)

    let on = try migrated(blob.replacingOccurrences(of: #""toolsEnabled":false"#, with: #""toolsEnabled":true"#))
    let shown = on.surfaceState(isProgram: false)
    XCTAssertTrue(on.toolsEnabled)
    XCTAssertTrue(shown.guides.enabled)
    XCTAssertTrue(shown.focus.enabled)
    XCTAssertEqual(shown.falseColor.mode, .elZone)
    XCTAssertTrue(on.scopesShown)
  }

  // MARK: guides

  func testMigrationGuidesKeepTheirValues() throws {
    let guides = try migrated(
      #"{"guides":{"enabled":true,"thirds":false,"centerCross":true,"opacity":0.4,"contrast":0.3}}"#
    ).state.guides
    XCTAssertTrue(guides.enabled)
    XCTAssertFalse(guides.thirds)
    XCTAssertTrue(guides.centerCross)
    XCTAssertEqual(guides.opacity, 0.4)
    XCTAssertEqual(guides.contrast, 0.3)
    let clamped = try migrated(#"{"guides":{"opacity":3,"contrast":-1}}"#).state.guides
    XCTAssertEqual(clamped.opacity, 1)
    XCTAssertEqual(clamped.contrast, 0)
    let defaults = try migrated("{}").state.guides
    XCTAssertFalse(defaults.enabled)
    XCTAssertTrue(defaults.thirds)
    XCTAssertFalse(defaults.centerCross)
    XCTAssertEqual(defaults.opacity, 0.65)
    XCTAssertEqual(defaults.contrast, 1)
  }

  func testMigrationSafeAreaBecomesTheNinetyPercentArea() throws {
    XCTAssertEqual(try migrated(#"{"guides":{"safeArea":true}}"#).state.guides.safeAreas, [90])
    XCTAssertEqual(try migrated(#"{"guides":{"safeArea":false}}"#).state.guides.safeAreas, [])
  }

  func testMigrationNewGuideFieldsTakeMonitorKitDefaults() throws {
    let guides = try migrated(#"{"guides":{"enabled":true,"safeArea":true}}"#).state.guides
    let defaults = GuideSettings()
    XCTAssertEqual(guides.frameGuides, defaults.frameGuides)
    XCTAssertEqual(guides.squareGrid, defaults.squareGrid)
    XCTAssertEqual(guides.diagonals, defaults.diagonals)
    XCTAssertEqual(guides.centerDot, defaults.centerDot)
    XCTAssertEqual(guides.color, defaults.color)
    XCTAssertEqual(guides.lineWidth, defaults.lineWidth)
    XCTAssertEqual(guides.followsFrameGuide, defaults.followsFrameGuide)
  }

  // MARK: zebra

  func testMigrationZebraEnableMovesToTheFirstSet() throws {
    let zebras = try migrated(#"{"toolsEnabled":true,"zebra":{"enabled":true}}"#).state.zebras
    XCTAssertEqual(zebras.count, 2)
    XCTAssertTrue(zebras[0].enabled)
    XCTAssertEqual(zebras[1], ZebraSet(), "The second set stays off")
    XCTAssertFalse(try migrated(#"{"zebra":{"enabled":false}}"#).state.zebras[0].enabled)
  }

  func testMigrationZebraThresholdBecomesLevelWithTheSameClamp() throws {
    XCTAssertEqual(try migrated(#"{"zebra":{"thresholdIRE":89}}"#).state.zebras[0].level, 89)
    XCTAssertEqual(try migrated(#"{"zebra":{"thresholdIRE":130}}"#).state.zebras[0].level, 120)
    XCTAssertEqual(try migrated(#"{"zebra":{"thresholdIRE":-30}}"#).state.zebras[0].level, -20)
    XCTAssertEqual(try migrated("{}").state.zebras[0].level, 95)
  }

  func testMigrationZebraFullWidthBecomesHalfWidthRange() throws {
    XCTAssertEqual(try migrated("{}").state.zebras[0].range, 2.5, "The old default band was 5 IRE wide")
    XCTAssertEqual(try migrated(#"{"zebra":{"widthIRE":12}}"#).state.zebras[0].range, 6)
    XCTAssertEqual(try migrated(#"{"zebra":{"widthIRE":40}}"#).state.zebras[0].range, 15)
    XCTAssertEqual(try migrated(#"{"zebra":{"widthIRE":-1}}"#).state.zebras[0].range, 0)
    // The old band [t - w/2, t + w/2) is the new [level - range, level + range).
    let threshold = 70.0, width = 9.0
    let zebra = try migrated(#"{"zebra":{"enabled":true,"mode":"band","thresholdIRE":70,"widthIRE":9}}"#)
      .state.zebras[0]
    for ire in stride(from: 60.0, through: 80.0, by: 0.25) {
      let old = ire >= threshold - width / 2 && ire < threshold + width / 2
      XCTAssertEqual(zebra.covers(ire: ire), old, "IRE \(ire)")
    }
  }

  func testMigrationZebraModes() throws {
    XCTAssertEqual(try migrated(#"{"zebra":{"mode":"aboveThreshold"}}"#).state.zebras[0].mode, .lowerLimit)
    XCTAssertEqual(try migrated(#"{"zebra":{"mode":"band"}}"#).state.zebras[0].mode, .band)
  }

  func testMigrationZebraOpacity() throws {
    XCTAssertEqual(try migrated(#"{"zebra":{"opacity":0.3}}"#).state.zebras[0].opacity, 0.3)
    XCTAssertEqual(try migrated("{}").state.zebras[0].opacity, 0.65)
  }

  func testMigrationZebraMeasuresThePictureStage() throws {
    XCTAssertEqual(try migrated(#"{"pictureStage":"source"}"#).state.zebras[0].stage, .source)
    XCTAssertEqual(try migrated(#"{"pictureStage":"processedOutput"}"#).state.zebras[0].stage, .output)
    XCTAssertEqual(try migrated("{}").state.zebras[0].stage, .output)
  }

  func testMigrationFalseColorStillSuppressesZebra() throws {
    let both = try migrated(#"""
      {"toolsEnabled":true,"zebra":{"enabled":true},"falseColor":{"mode":"sonySLog3"},
       "sourceProfileID":"sony-slog3-sgamut3cine"}
      """#)
    XCTAssertTrue(both.state.zebras[0].enabled, "Saved as it was")
    let shown = both.surfaceState(isProgram: false)
    XCTAssertEqual(shown.falseColor.mode, .sonySLog3)
    XCTAssertFalse(shown.zebras.contains(where: \.enabled), "False colour suppresses zebra")
    let zebraOnly = try migrated(#"{"toolsEnabled":true,"zebra":{"enabled":true}}"#)
    XCTAssertTrue(zebraOnly.surfaceState(isProgram: false).zebras[0].enabled)
  }

  // MARK: false colour

  func testMigrationSonyAndELZoneModesCarryOver() throws {
    let source = #""sourceProfileID":"sony-slog3-sgamut3cine""#
    XCTAssertEqual(try migrated(#"{"falseColor":{"mode":"off"},"# + source + "}").state.falseColor.mode, .off)
    XCTAssertEqual(
      try migrated(#"{"falseColor":{"mode":"sonySLog3"},"# + source + "}").state.falseColor.mode, .sonySLog3)
    XCTAssertEqual(
      try migrated(#"{"falseColor":{"mode":"elZone"},"# + source + "}").state.falseColor.mode, .elZone)
    // As MonitorTools' normalization did: no supported log source, no false colour.
    XCTAssertEqual(try migrated(#"{"falseColor":{"mode":"sonySLog3"}}"#).state.falseColor.mode, .off)
    XCTAssertEqual(try migrated(#"{"falseColor":{"mode":"elZone"}}"#).state.falseColor.mode, .off)
  }

  func testMigrationARRIStyleProfileBecomesSony() throws {
    let value = try migrated(#"""
      {"falseColor":{"mode":"arri","profileID":"arri-style-slog3-logc3-ei800-v1"},
       "sourceProfileID":"sony-slog3-sgamut3cine"}
      """#)
    XCTAssertEqual(value.state.falseColor.mode, .sonySLog3)
  }

  func testMigrationLiteralARRIBecomesLogCWithItsSignal() throws {
    for profile in ARRIFalseColorProfile.allCases {
      let value = try migrated(#"{"falseColor":{"mode":"arri","profileID":""# + profile.rawValue
        + #"","exposureIndex":800},"sourceProfileID":""# + profile.rawValue + #""}"#)
      XCTAssertEqual(value.state.falseColor.mode, .arriLogC, profile.rawValue)
      XCTAssertEqual(value.signal.logProfileID, profile.rawValue)
      XCTAssertEqual(value.signal.logEncoding?.curve, profile == .logC3EI800 ? .arriLogC3 : .arriLogC4)
    }
    let logC3 = ARRIFalseColorProfile.logC3EI800.rawValue
    let otherEI = try migrated(#"{"falseColor":{"mode":"arri","profileID":""# + logC3
      + #"","exposureIndex":1600},"sourceProfileID":""# + logC3 + #""}"#)
    XCTAssertEqual(otherEI.state.falseColor.mode, .off)
    let mismatch = try migrated(#"{"falseColor":{"mode":"arri","profileID":""# + logC3
      + #""},"sourceProfileID":"arri-alexa35-logc4-ei800"}"#)
    XCTAssertEqual(mismatch.state.falseColor.mode, .off)
    let noProfile = try migrated(#"{"falseColor":{"mode":"arri"},"sourceProfileID":""# + logC3 + #""}"#)
    XCTAssertEqual(noProfile.state.falseColor.mode, .off)
  }

  func testMigrationFalseColorProfileAndExposureIndexAreDropped() throws {
    let value = try migrated(#"""
      {"falseColor":{"mode":"sonySLog3","profileID":"sony-slog3-false-color-v1",
        "specificationVersion":"sony-monitor-control-pattern2-v1","exposureIndex":1600},
       "sourceProfileID":"sony-slog3-sgamut3cine"}
      """#)
    XCTAssertEqual(value.state.falseColor.mode, .sonySLog3)
    let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    for key in ["profileID\"", "specificationVersion", "exposureIndex"] {
      XCTAssertFalse(encoded.contains(key), key)
    }
    // A foreign Sony profile was refused before and still is.
    let foreign = try migrated(#"""
      {"falseColor":{"mode":"sonySLog3","profileID":"someone-else"},"sourceProfileID":"sony-slog3-sgamut3cine"}
      """#)
    XCTAssertEqual(foreign.state.falseColor.mode, .off)
  }

  func testMigrationReferenceOffsetClampsToSixStops() throws {
    XCTAssertEqual(try migrated(#"{"falseColor":{"referenceOffsetStops":3}}"#).state.falseColor.referenceOffsetStops, 3)
    XCTAssertEqual(try migrated(#"{"falseColor":{"referenceOffsetStops":8}}"#).state.falseColor.referenceOffsetStops, 6)
    XCTAssertEqual(
      try migrated(#"{"falseColor":{"referenceOffsetStops":-10}}"#).state.falseColor.referenceOffsetStops, -6)
  }

  func testMigrationNewFalseColorFieldsTakeDefaults() throws {
    let falseColor = try migrated(#"""
      {"falseColor":{"mode":"elZone"},"sourceProfileID":"sony-slog3-sgamut3cine"}
      """#).state.falseColor
    XCTAssertEqual(falseColor.stage, .output)
    XCTAssertEqual(falseColor.customUnit, .ire)
    XCTAssertEqual(falseColor.customBands, [])
  }

  // MARK: focus

  func testMigrationFocusValuesCarryOver() throws {
    for color in ["red", "green", "blue", "yellow", "white"] {
      let focus = try migrated(#"""
        {"focus":{"enabled":true,"color":"\#(color)","sensitivity":0.8,"noiseRejection":0.1,"opacity":0.4}}
        """#).state.focus
      XCTAssertTrue(focus.enabled)
      XCTAssertEqual(focus.color.rawValue, color)
      XCTAssertEqual(focus.sensitivity, 0.8)
      XCTAssertEqual(focus.noiseRejection, 0.1)
      XCTAssertEqual(focus.opacity, 0.4)
      XCTAssertEqual(focus.edgeThreshold, 0.02 + (1 - 0.8) * 0.3, accuracy: 1e-12)
    }
    let defaults = try migrated("{}").state.focus
    XCTAssertFalse(defaults.enabled)
    XCTAssertEqual(defaults.color, .red)
    XCTAssertEqual(defaults.sensitivity, 0.5)
    XCTAssertEqual(defaults.noiseRejection, 0.02)
    XCTAssertEqual(defaults.opacity, 0.85)
  }

  func testMigrationFocusDefaultsToColoredSourceEdges() throws {
    let focus = try migrated(#"{"focus":{"enabled":true}}"#).state.focus
    XCTAssertEqual(focus.style, .coloredEdges)
    XCTAssertEqual(focus.stage, .source, "MonitorTools always peaked the source luma")
  }

  // MARK: scopes

  func testMigrationScopeEnableAndRefreshRate() throws {
    let scopes = try migrated(#"{"scopes":{"enabled":true,"refreshHz":30}}"#).scopes
    XCTAssertTrue(scopes.enabled)
    XCTAssertEqual(scopes.refreshHz, 30)
    XCTAssertEqual(try migrated(#"{"scopes":{"refreshHz":20}}"#).scopes.refreshHz, 15)
    XCTAssertEqual(try migrated(#"{"scopes":{"refreshHz":10}}"#).scopes.refreshHz, 10)
    XCTAssertFalse(try migrated("{}").scopes.enabled)
  }

  func testMigrationScopeModeKeepsTheLegacyLook() throws {
    let parade = try migrated(#"{"scopes":{"mode":"rgbParade"}}"#).scopes.settings
    XCTAssertEqual(parade.kind, .waveform)
    XCTAssertEqual(parade.waveformMode, .rgbParade)
    XCTAssertEqual(parade.waveformColumns, ScopeSettings.ultracamLegacyImageWidth)
    XCTAssertEqual(parade.waveformLevels, ScopeSettings.ultracamLegacyImageHeight)
    XCTAssertEqual(parade.levelRange, .minus10To110)
    XCTAssertEqual(parade.display.palette, .ultracamLegacy)
    let luma = try migrated(#"{"scopes":{"mode":"lumaWaveform"}}"#).scopes.settings
    XCTAssertEqual(luma.kind, .waveform)
    XCTAssertEqual(luma.waveformMode, .luma)
    XCTAssertEqual(luma.levelRange, .minus10To110)
  }

  func testMigrationScopeGainAndGraticule() throws {
    let scopes = try migrated(#"{"scopes":{"gain":2.5,"graticule":false}}"#).scopes.settings.display
    XCTAssertEqual(scopes.gain, 2.5)
    XCTAssertFalse(scopes.showsGraticule)
    XCTAssertEqual(try migrated(#"{"scopes":{"gain":10}}"#).scopes.settings.display.gain, 4)
    XCTAssertEqual(try migrated(#"{"scopes":{"gain":0.1}}"#).scopes.settings.display.gain, 0.25)
    XCTAssertTrue(try migrated("{}").scopes.settings.display.showsGraticule)
  }

  func testMigrationScopeStage() throws {
    XCTAssertEqual(try migrated(#"{"scopeStage":"processedOutput"}"#).scopes.settings.stage, .output)
    XCTAssertEqual(try migrated(#"{"scopeStage":"source"}"#).scopes.settings.stage, .source)
  }

  // MARK: picture stage and the signal declaration

  func testMigrationPictureStage() throws {
    let source = try migrated(#"{"pictureStage":"source"}"#).state
    XCTAssertEqual(source.pictureStage, .source)
    XCTAssertFalse(source.pictureHasLUT(burnInLUT: true, monitorLUT: false), "Source: no burn-in")
    let output = try migrated(#"{"pictureStage":"processedOutput"}"#).state
    XCTAssertEqual(output.pictureStage, .output, "Output (LUT): the source with the burn-in LUT")
    XCTAssertTrue(output.pictureHasLUT(burnInLUT: true, monitorLUT: false))
    XCTAssertFalse(output.pictureHasLUT(burnInLUT: false, monitorLUT: true), "Never the monitor-only LUT")
    XCTAssertEqual(try migrated("{}").state.pictureStage, .output)
    XCTAssertEqual(MonitorFeedPreferences().state.pictureStage, .output, "Fresh feeds agree")
  }

  func testMigrationSourceProfileBecomesTheSignalDeclaration() throws {
    let sony = try migrated(#"{"sourceProfileID":"sony-slog3-sgamut3cine"}"#).signal
    XCTAssertEqual(sony.logProfileID, Self.sonyCine)
    XCTAssertEqual(sony.logEncoding, .sLog3SGamut3Cine)
    XCTAssertEqual(sony.applied(to: .rec709).encoding, .log(.sLog3SGamut3Cine))
    let none = try migrated("{}").signal
    XCTAssertNil(none.logProfileID)
    XCTAssertNil(none.logEncoding)
    XCTAssertEqual(none.applied(to: .rec709), .rec709, "Nothing declared: the frame's tags decide")
  }

  func testMigrationSourceCodeRange() throws {
    XCTAssertEqual(try migrated(#"{"sourceCodeRange":"full"}"#).signal.range, .full)
    XCTAssertEqual(try migrated(#"{"sourceCodeRange":"legal"}"#).signal.range, .legal)
    XCTAssertNil(try migrated("{}").signal.range)
    var tagged = SignalDescription.rec709
    tagged.range = .full
    XCTAssertEqual(try migrated(#"{"sourceCodeRange":"legal"}"#).signal.applied(to: tagged).range, .legal)
    XCTAssertEqual(try migrated("{}").signal.applied(to: tagged).range, .full)
  }

  func testMigrationSourceLogMappingBecomesTheTransport() throws {
    let rescaled = try migrated(#"""
      {"sourceProfileID":"sony-slog3-sgamut3cine","sourceLogMapping":"fullRescaledToLegal10Bit"}
      """#).signal
    XCTAssertEqual(rescaled.transport, .fullRescaledToLegal)
    XCTAssertEqual(rescaled.logEncoding?.transport, .fullRescaledToLegal)
    XCTAssertEqual(try migrated(#"{"sourceLogMapping":"native10Bit"}"#).signal.transport, .native)
  }

  // MARK: ephemeral and new MonitorKit fields

  func testMigrationCleanAndMagnificationAreNeverPersisted() throws {
    var value = MonitorFeedPreferences(toolsEnabled: true)
    value.state.clean = true
    value.state.geometry.magnification.zoom = 4
    value.state.geometry.desqueeze = 2
    let decoded = try JSONDecoder().decode(MonitorFeedPreferences.self, from: JSONEncoder().encode(value))
    XCTAssertFalse(decoded.state.clean)
    XCTAssertEqual(decoded.state.geometry.magnification, Magnification())
    XCTAssertEqual(decoded.state.geometry.desqueeze, 2, "De-squeeze is a saved setting")
    var zoom = Magnification()
    zoom.zoom = 3
    let surface = decoded.surfaceState(isProgram: false, clean: true, magnification: zoom)
    XCTAssertTrue(surface.clean)
    XCTAssertEqual(surface.geometry.magnification.zoom, 3)
  }

  func testMigrationNewMonitorKitFeaturesTakeDefaults() throws {
    let state = try migrated(#"{"toolsEnabled":true,"guides":{"enabled":true}}"#).state
    let defaults = MonitorState()
    XCTAssertEqual(state.geometry, defaults.geometry)
    XCTAssertEqual(state.display, defaults.display)
    XCTAssertEqual(state.monitorLUT, defaults.monitorLUT)
    XCTAssertEqual(state.displayTransform, defaults.displayTransform)
    XCTAssertEqual(state.clipIndicators, defaults.clipIndicators)
  }

  // MARK: Program and the workspace

  func testMigrationProgramConfigurationMovesToProgramMonitor() throws {
    let program = #"""
      {"toolsEnabled":true,"zebra":{"enabled":true,"thresholdIRE":90},"focus":{"enabled":true},
       "falseColor":{"mode":"sonySLog3"},"sourceProfileID":"sony-slog3-sgamut3cine"}
      """#
    let json = #"{"version":2,"selectedFeedID":"a","feeds":[{"id":"a","name":"A"}],"programMonitorConfiguration":"#
      + program + "}"
    let snapshot = try JSONDecoder().decode(AppSettingsSnapshot.self, from: Data(json.utf8))
    XCTAssertTrue(snapshot.programMonitor.toolsEnabled)
    XCTAssertEqual(snapshot.programMonitor.state.zebras[0].level, 90)
    XCTAssertNotNil(snapshot.legacyProgramMonitorConfiguration)
    let shown = snapshot.programMonitor.surfaceState(isProgram: true)
    XCTAssertFalse(shown.focus.enabled, "No peaking on Program")
    XCTAssertEqual(shown.falseColor.mode, .off, "No log false colour on Program")
    XCTAssertFalse(shown.zebras[0].enabled, "The configured false colour still suppresses zebra")
  }

  func testMigrationWorkspaceKeepsItsJSON() throws {
    let json = #"{"schemaVersion":1,"isConfigured":true,"layout":"fourUp","tileBindings":["a",null,"program",null],"splitRatio":0.3}"#
    let workspace = try JSONDecoder().decode(MonitorWorkspacePreferences.self, from: Data(json.utf8))
    XCTAssertTrue(workspace.isConfigured)
    XCTAssertEqual(workspace.layout, .fourUp)
    XCTAssertEqual(workspace.layout.tileCount, 4)
    XCTAssertEqual(workspace.tileBindings, ["a", nil, "program", nil])
    XCTAssertEqual(workspace.splitRatio, 0.3)
    XCTAssertEqual(try jsonObject(JSONEncoder().encode(workspace)), try jsonObject(Data(json.utf8)))
    let short = try JSONDecoder().decode(MonitorWorkspacePreferences.self,
      from: Data(#"{"tileBindings":["a"],"splitRatio":5}"#.utf8))
    XCTAssertEqual(short.tileBindings, ["a", nil, nil, nil])
    XCTAssertEqual(short.splitRatio, 0.8)
    let future = try JSONDecoder().decode(MonitorWorkspacePreferences.self,
      from: Data(#"{"schemaVersion":2,"layout":"fourUp"}"#.utf8))
    XCTAssertEqual(future, MonitorWorkspacePreferences())
  }

  // MARK: persistence rules (map §5.2)

  func testMigrationLegacyKeysRoundTripUntouched() throws {
    let blob = #"""
      {"schemaVersion":1,"toolsEnabled":true,"zebra":{"enabled":true,"thresholdIRE":95,"widthIRE":7.5},
       "falseColor":{"mode":"arri","profileID":null,"exposureIndex":800,"referenceOffsetStops":-8.25},
       "futureField":[1,0,true,false,null,"x",{"nested":[2.5e-7,12345678901]}],"scopes":{}}
      """#
    let json = #"{"version":2,"selectedFeedID":"a","feeds":[{"version":1,"id":"a","name":"A","monitorConfiguration":"#
      + blob + #"}],"programMonitorConfiguration":"# + blob + "}"
    let original = try jsonObject(Data(json.utf8))
    let originalBlob = try XCTUnwrap((original["feeds"] as? [NSDictionary])?.first?["monitorConfiguration"])
    var snapshot = try JSONDecoder().decode(AppSettingsSnapshot.self, from: Data(json.utf8))
    // A change through the MonitorTools UI updates only the new key.
    var changed = snapshot.feeds[0].monitor.legacyConfiguration
    changed.zebra.thresholdIRE = 80
    snapshot.feeds[0].monitor.merge(changed)
    XCTAssertEqual(snapshot.feeds[0].monitor.state.zebras[0].level, 80)
    let written = try jsonObject(JSONEncoder().encode(snapshot))
    let feed = try XCTUnwrap((written["feeds"] as? [NSDictionary])?.first)
    XCTAssertEqual(feed["monitorConfiguration"] as? NSDictionary, originalBlob as? NSDictionary)
    XCTAssertEqual(written["programMonitorConfiguration"] as? NSDictionary,
      original["programMonitorConfiguration"] as? NSDictionary)
    XCTAssertNotNil(feed["monitor"])
    XCTAssertNotNil(written["programMonitor"])
    // Read again, the new keys win and the old ones are still carried.
    let reread = try JSONDecoder().decode(AppSettingsSnapshot.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(reread, snapshot)
    XCTAssertEqual(reread.feeds[0].monitor.state.zebras[0].level, 80)
    // Booleans stay booleans and integers integers (JSONSerialization conflates them).
    XCTAssertEqual(
      try JSONDecoder().decode(PreservedJSON.self, from: Data(#"[1,0,true,false,2.5,null]"#.utf8)),
      .array([.integer(1), .integer(0), .bool(true), .bool(false), .number(2.5), .null]))
    // A fresh install writes no legacy keys.
    let fresh = try jsonObject(JSONEncoder().encode(AppSettingsSnapshot()))
    XCTAssertNil(fresh["programMonitorConfiguration"])
    XCTAssertNil((fresh["feeds"] as? [NSDictionary])?.first?["monitorConfiguration"])
  }

  func testMigrationNewKeyWinsOverTheLegacyKey() throws {
    var saved = MonitorFeedPreferences(toolsEnabled: true)
    saved.state.focus.enabled = true
    let monitor = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
    let json = #"{"id":"a","name":"A","monitor":"# + monitor
      + #","monitorConfiguration":{"toolsEnabled":false,"focus":{"enabled":false}}}"#
    let feed = try JSONDecoder().decode(FeedDescriptor.self, from: Data(json.utf8))
    XCTAssertEqual(feed.monitor, saved)
    XCTAssertNotNil(feed.legacyMonitorConfiguration)
  }

  func testMigrationFeedDescriptorVersionStaysOne() throws {
    let feed = try migratedFeed(#"{"toolsEnabled":true}"#)
    XCTAssertEqual(feed.version, 1)
    let encoded = try jsonObject(JSONEncoder().encode(feed))
    XCTAssertEqual(encoded["version"] as? Int, 1)
    let suite = "MonitorLifecycleChecks.migration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = #"{"version":2,"selectedFeedID":"a","feeds":[{"version":1,"id":"a","name":"Old","monitorConfiguration":{"toolsEnabled":true,"guides":{"enabled":true,"safeArea":true}}}]}"#
    defaults.set(Data(legacy.utf8), forKey: "ultracam.settings.v2")
    MainActor.assumeIsolated {
      let store = AppSettingsStore(defaults: defaults)
      let loaded = store.loadSnapshot()
      XCTAssertEqual(loaded.feeds.map(\.name), ["Old"], "The v2 snapshot must still validate")
      XCTAssertEqual(loaded.feeds[0].monitor.state.guides.safeAreas, [90])
      store.saveSnapshot(loaded)
      let again = store.loadSnapshot()
      XCTAssertEqual(again, loaded)
      XCTAssertEqual(again.feeds[0].version, 1)
    }
  }

  // MARK: the coordinator boundary

  func testMigrationMergeIsIdempotentAndKeepsMonitorKitOnlySettings() throws {
    let blobs = [
      "{}",
      #"{"toolsEnabled":true,"zebra":{"enabled":true,"mode":"band","widthIRE":3},"guides":{"safeArea":true}}"#,
      #"{"falseColor":{"mode":"sonySLog3"},"sourceProfileID":"sony-slog3-sgamut3","pictureStage":"source"}"#,
      #"{"falseColor":{"mode":"arri","profileID":"arri-logc3-ei800"},"sourceProfileID":"arri-logc3-ei800"}"#,
      #"{"scopes":{"enabled":true,"mode":"lumaWaveform","gain":3},"scopeStage":"source","sourceCodeRange":"full"}"#,
    ]
    for blob in blobs {
      let value = try migrated(blob)
      var again = value
      again.merge(value.legacyConfiguration)
      XCTAssertEqual(again, value, blob)
    }
    var rich = try migrated(#"{"toolsEnabled":true,"guides":{"safeArea":true}}"#)
    rich.state.zebras[1] = ZebraSet(mode: .lowerLimit, level: 100)
    rich.state.guides.safeAreas = [80, 93]
    rich.state.guides.frameGuides = [FrameGuide(aspect: 2.39)]
    rich.state.displayTransform.mode = .logToRec709
    rich.state.falseColor.mode = .sixBand
    rich.scopes.settings = ScopeSettings(kind: .vectorscope)
    var change = rich.legacyConfiguration
    change.focus.enabled = true
    rich.merge(change)
    XCTAssertTrue(rich.state.focus.enabled)
    XCTAssertEqual(rich.state.zebras[1].level, 100)
    XCTAssertEqual(rich.state.guides.safeAreas, [80, 93])
    XCTAssertEqual(rich.state.guides.frameGuides.count, 1)
    XCTAssertEqual(rich.state.displayTransform.mode, .logToRec709)
    XCTAssertEqual(rich.state.falseColor.mode, .sixBand)
    XCTAssertEqual(rich.scopes.settings.kind, .vectorscope)
    change.guides.safeArea = false
    rich.merge(change)
    XCTAssertEqual(rich.state.guides.safeAreas, [])
  }

  func testMigrationNewCameraForgetsCalibration() throws {
    var value = try migrated(#"""
      {"toolsEnabled":true,"falseColor":{"mode":"sonySLog3","referenceOffsetStops":2},
       "sourceProfileID":"sony-slog3-sgamut3cine","sourceCodeRange":"full","zebra":{"enabled":true}}
      """#)
    XCTAssertTrue(value.falseColorDeclared)
    value.forgetCameraCalibration()
    XCTAssertEqual(value.signal, MonitorSignalDeclaration())
    XCTAssertEqual(value.state.falseColor.referenceOffsetStops, 0)
    XCTAssertTrue(value.state.zebras[0].enabled, "Tools stay")
    XCTAssertTrue(value.toolsEnabled)
    // The mode stays selected but cannot show, so zebra shows instead
    // (MonitorTools normalized it away at render time).
    XCTAssertEqual(value.state.falseColor.mode, .sonySLog3)
    XCTAssertFalse(value.falseColorDeclared)
    XCTAssertTrue(value.surfaceState(isProgram: false).zebras[0].enabled)
    XCTAssertEqual(value.legacyConfiguration.falseColor.mode, .sonySLog3, "Still selected in the tools")
    XCTAssertEqual(value.legacyConfiguration.sourceProfileID, nil)
    // Declaring the camera again brings it back, as before.
    var declared = value.legacyConfiguration
    declared.sourceProfileID = Self.sonyCine
    value.merge(declared)
    XCTAssertEqual(value.signal.logProfileID, Self.sonyCine)
    XCTAssertEqual(value.state.falseColor.mode, .sonySLog3)
    XCTAssertTrue(value.falseColorDeclared)
    XCTAssertEqual(value.legacyConfiguration, declared.normalized())
    XCTAssertFalse(value.surfaceState(isProgram: false).zebras[0].enabled, "False colour suppresses zebra again")
    // Any other change made while no source is declared drops it, as MonitorTools'
    // normalized configuration did.
    value.forgetCameraCalibration()
    var other = value.legacyConfiguration
    other.focus.enabled = true
    value.merge(other)
    XCTAssertEqual(value.state.falseColor.mode, .off)
  }
}
