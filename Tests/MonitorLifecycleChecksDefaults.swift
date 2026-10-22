import Foundation
import MonitorKitCore
import MonitorKitScopes
import XCTest

// Ultracam's default monitor tools look like MonitorTools' on every path a
// target gets them, and reset and copy replace the whole preferences, settings
// MonitorTools cannot express included.
extension MonitorLifecycleChecks {
  func testDefaultsMatchMonitorToolsOnEveryPath() throws {
    let legacy = LegacyMonitorConfiguration().normalized()
    XCTAssertEqual(MonitorFeedPreferences().legacyConfiguration, legacy)
    XCTAssertEqual(MonitorFeedPreferences().state.zebras[0].range, 2.5, "A 5 IRE band, as before")
    XCTAssertEqual(MonitorFeedPreferences().legacyConfiguration.zebra.widthIRE, 5)
    let missingKey = try JSONDecoder().decode(
      FeedDescriptor.self, from: Data(#"{"version":1,"id":"a","name":"A"}"#.utf8))
    let paths: [(String, MonitorFeedPreferences)] = [
      ("fresh install", AppSettingsSnapshot().feeds[0].monitor),
      ("fresh Program", AppSettingsSnapshot().programMonitor),
      ("feed added in the session", FeedDescriptor(id: FeedID(rawValue: "b"), name: "Camera 2").monitor),
      ("v1 AppSettings migration", FeedDescriptor(legacy: AppSettings()).monitor),
      ("saved feed without monitor keys", missingKey.monitor),
      ("migrated default blob", MonitorFeedPreferences(migrating: LegacyMonitorConfiguration())),
    ]
    for (path, value) in paths {
      XCTAssertEqual(value, MonitorFeedPreferences(), path)
      XCTAssertEqual(value.legacyConfiguration, legacy, path)
    }
    // The band itself: [92.5, 97.5) around the default 95 IRE level.
    var band = MonitorFeedPreferences().state.zebras[0]
    band.enabled = true
    band.mode = .band
    XCTAssertFalse(band.covers(ire: 92.4))
    XCTAssertTrue(band.covers(ire: 92.5))
    XCTAssertTrue(band.covers(ire: 97.4))
    XCTAssertFalse(band.covers(ire: 97.5))
  }

  /// MonitorKit-only settings no MonitorTools control can reach.
  private func monitorKitOnly(_ value: inout MonitorFeedPreferences) {
    value.state.zebras[1] = ZebraSet(mode: .lowerLimit, level: 100)
    value.state.guides.frameGuides = [FrameGuide(aspect: 2.39)]
    value.state.guides.safeAreas = [80, 93]
    value.state.geometry.desqueeze = 2
    value.state.displayTransform.mode = .logToRec709
    value.scopes.settings = ScopeSettings(kind: .vectorscope)
  }

  func testResetToolsClearsMonitorKitOnlySettings() {
    var value = MonitorFeedPreferences(toolsEnabled: true)
    value.state.zebras[0].enabled = true
    value.state.falseColor.referenceOffsetStops = 1.5
    value.signal = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine", range: .full)
    monitorKitOnly(&value)
    value.resetTools()
    XCTAssertEqual(value, MonitorFeedPreferences(), "A full reset, the signal declaration included")
  }

  func testCopyToolsTakesEverythingButTheDestinationsCamera() {
    var source = MonitorFeedPreferences(toolsEnabled: true)
    source.state.zebras[0].enabled = true
    source.state.zebras[0].range = 4
    source.state.falseColor.mode = .sixBand
    source.state.falseColor.referenceOffsetStops = 2
    source.scopes.enabled = true
    source.signal = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine")
    monitorKitOnly(&source)
    var destination = MonitorFeedPreferences()
    destination.state.falseColor.referenceOffsetStops = -1
    destination.state.focus.enabled = true
    destination.signal = MonitorSignalDeclaration(logProfileID: "arri-logc3-ei800", range: .legal)
    let keptSignal = destination.signal
    destination.copyTools(from: source)
    XCTAssertTrue(destination.toolsEnabled)
    XCTAssertEqual(destination.signal, keptSignal, "The destination's camera is kept")
    XCTAssertEqual(destination.state.falseColor.referenceOffsetStops, -1, "So is its exposure offset")
    var expected = source.state
    expected.falseColor.referenceOffsetStops = -1
    XCTAssertEqual(destination.state, expected)
    XCTAssertEqual(destination.scopes, source.scopes)
    XCTAssertEqual(destination.state.geometry.desqueeze, 2)
    XCTAssertEqual(destination.state.guides.frameGuides.count, 1)
    XCTAssertFalse(destination.state.focus.enabled)
  }

  func testCopyToolsDropsALogModeTheDestinationCannotShow() {
    var source = MonitorFeedPreferences(toolsEnabled: true)
    source.state.falseColor.mode = .sonySLog3
    source.signal = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine")
    var arri = MonitorFeedPreferences()
    arri.signal = MonitorSignalDeclaration(logProfileID: "arri-logc3-ei800")
    arri.copyTools(from: source)
    XCTAssertEqual(arri.state.falseColor.mode, .off)
    var program = MonitorFeedPreferences()
    program.copyTools(from: source)
    XCTAssertEqual(program.state.falseColor.mode, .off, "No declared camera")
    var sony = MonitorFeedPreferences()
    sony.signal = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3")
    sony.copyTools(from: source)
    XCTAssertEqual(sony.state.falseColor.mode, .sonySLog3)
  }

  func testFalseColorSuppressesZebraOnlyWhenItCanShow() {
    var value = MonitorFeedPreferences(toolsEnabled: true)
    value.state.zebras[0].enabled = true
    for (mode, profile, shows) in [
      (FalseColorMode.sonySLog3, "sony-slog3-sgamut3cine", true),
      (.sonySLog3, "arri-logc3-ei800", false),
      (.sonySLog3, nil, false),
      (.elZone, "sony-slog3-sgamut3", true),
      (.elZone, nil, false),
      (.arriLogC, "arri-alexa35-logc4-ei800", true),
      (.arriLogC, "sony-slog3-sgamut3cine", false),
      (.arriStyleSLog3, "sony-slog3-sgamut3cine", true),
      (.sixBand, nil, true),
      (.off, "sony-slog3-sgamut3cine", false),
    ] as [(FalseColorMode, String?, Bool)] {
      value.state.falseColor.mode = mode
      value.signal.logProfileID = profile
      XCTAssertEqual(value.falseColorDeclared, shows, "\(mode) \(profile ?? "nil")")
      XCTAssertEqual(value.surfaceState(isProgram: false).zebras[0].enabled, !shows, "\(mode) \(profile ?? "nil")")
    }
  }
}
