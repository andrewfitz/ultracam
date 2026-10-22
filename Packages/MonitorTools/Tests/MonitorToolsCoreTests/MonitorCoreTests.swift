import XCTest

@testable import MonitorToolsCore

final class MonitorCoreTests: XCTestCase {


  func testMissingConfigurationRestoresSafeDefaults() throws {
    let config = try JSONDecoder().decode(MonitorConfiguration.self, from: Data("{}".utf8))
    XCTAssertFalse(config.toolsEnabled)
    XCTAssertFalse(config.needsAnalysis)
    XCTAssertEqual(config.pictureStage, .processedOutput)
    XCTAssertEqual(config.scopeStage, .processedOutput)
    XCTAssertEqual(
      try JSONDecoder().decode(MonitorConfiguration.self, from: JSONEncoder().encode(config)),
      config)
  }
  func testUnknownPreferencesFailClosedWithoutInvalidatingOuterPreferences() throws {
    struct SavedFeed: Decodable {
      let camera: String
      let lut: String
      let monitor: MonitorConfiguration
    }
    let payloads = [
      "{\"toolsEnabled\":true,\"falseColor\":{\"mode\":\"future-mode\"}}",
      "{\"toolsEnabled\":true,\"scopes\":{\"mode\":\"future-scope\"}}",
      "{\"toolsEnabled\":true,\"schemaVersion\":999}",
      "{\"toolsEnabled\":true,\"sourceCodeRange\":\"future-range\"}",
      "{\"toolsEnabled\":true,\"focus\":{\"sensitivity\":\"corrupt\"}}",
      "[]",
    ]
    for payload in payloads {
      let saved =
        "{\"camera\":\"saved-camera\",\"lut\":\"creative.cube\",\"monitor\":" + payload + "}"
      let feed = try JSONDecoder().decode(SavedFeed.self, from: Data(saved.utf8))
      XCTAssertEqual(feed.camera, "saved-camera")
      XCTAssertEqual(feed.lut, "creative.cube")
      XCTAssertEqual(feed.monitor, MonitorConfiguration())
    }
  }
  func testNumericValidationAndIncompatibleProfileDisable() throws {
    var value = MonitorConfiguration()
    value.toolsEnabled = true
    value.focus.sensitivity = .nan
    value.focus.noiseRejection = -.infinity
    value.guides.opacity = 9
    value.zebra.thresholdIRE = .infinity
    value.zebra.widthIRE = -5
    value.scopes.gain = 1e300
    value.scopes.refreshHz = Int.max
    value.falseColor.mode = .arri
    value.falseColor.profileID = ARRIFalseColorProfile.logC3EI800.rawValue
    value.sourceProfileID = "slog3-sgamut3cine"
    let normalized = value.normalized()
    XCTAssertEqual(normalized.focus.sensitivity, 0.5)
    XCTAssertEqual(normalized.focus.noiseRejection, 0.02)
    XCTAssertEqual(normalized.guides.opacity, 1)
    XCTAssertEqual(normalized.zebra.thresholdIRE, 95)
    XCTAssertEqual(normalized.zebra.widthIRE, 0)
    XCTAssertEqual(normalized.scopes.gain, 4)
    XCTAssertEqual(normalized.scopes.refreshHz, 15)
    XCTAssertEqual(normalized.falseColor.mode, .off)
    XCTAssertNoThrow(try JSONEncoder().encode(normalized))
    let decoded = try JSONDecoder().decode(
      MonitorConfiguration.self,
      from: Data(
        "{\"toolsEnabled\":true,\"scopes\":{\"gain\":99999,\"refreshHz\":-1},\"sourceCodeRange\":\"legal\"}"
          .utf8))
    XCTAssertEqual(decoded.scopes.gain, 4)
    XCTAssertEqual(decoded.scopes.refreshHz, 15)
    XCTAssertEqual(decoded.sourceCodeRange, .legal)
  }
  func testSavedSonyARRIStyleMigratesToSonyPresetWithoutMatchingCameraEI() throws {
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      var value = MonitorConfiguration()
      value.toolsEnabled = true
      value.sourceProfileID = source
      value.falseColor.mode = .arri
      value.falseColor.profileID = "arri-style-slog3-logc3-ei800-v1"
      value.falseColor.exposureIndex = 12800
      let normalized = value.normalized()
      XCTAssertEqual(normalized.falseColor.mode.rawValue, "sonySLog3")
      XCTAssertEqual(normalized.falseColor.profileID, "sony-slog3-false-color-v1")
      XCTAssertEqual(normalized.falseColor.exposureIndex, 12800)
      XCTAssertEqual(
        try JSONDecoder().decode(
          MonitorConfiguration.self, from: JSONEncoder().encode(normalized)), normalized)
    }
  }
  func testSonyARRIStyleReferenceRejectsUnsupportedSource() {
    for source in [nil, "slog3-sgamut3cine", "unknown", "arri-logc3-ei800"] as [String?] {
      var value = MonitorConfiguration()
      value.sourceProfileID = source
      value.falseColor.mode = .arri
      value.falseColor.profileID = "arri-style-slog3-logc3-ei800-v1"
      XCTAssertEqual(value.normalized().falseColor.mode, .off)
    }
  }
  func testSourceInterpretationDefaultsAndRoundTrip() throws {
    let legacy = try JSONDecoder().decode(MonitorConfiguration.self, from: Data("{}".utf8))
    XCTAssertNil(legacy.sourceCodeRange)
    XCTAssertEqual(legacy.sourceLogMapping, .native10Bit)
    var declared = legacy
    declared.sourceCodeRange = .legal
    declared.sourceLogMapping = .fullRescaledToLegal10Bit
    declared.sourceProfileID = "arri-logc3-ei800"
    let restored = try JSONDecoder().decode(
      MonitorConfiguration.self, from: JSONEncoder().encode(declared))
    XCTAssertEqual(restored, declared)
    XCTAssertEqual(
      restored.sourceLogMapping.nativeCodeMapping.nativeNormalized(transportCode: 64), 0)
    XCTAssertEqual(
      restored.sourceLogMapping.nativeCodeMapping.nativeNormalized(transportCode: 940), 1)
    XCTAssertEqual(
      legacy.sourceLogMapping.nativeCodeMapping.nativeNormalized(transportCode: 420), 420.0 / 1023.0
    )
  }
  func testAdditiveSettingsMigration() throws {
    let config = try JSONDecoder().decode(
      MonitorConfiguration.self,
      from: Data("{\"guides\":{\"enabled\":true},\"falseColor\":{\"mode\":\"arri\"}}".utf8))
    XCTAssertTrue(config.guides.enabled)
    XCTAssertTrue(config.guides.thirds)
    XCTAssertEqual(config.falseColor.exposureIndex, 800)
    XCTAssertFalse(config.toolsEnabled)
  }
  func testWorkspaceCorruptionPreservesOuterCameraPreferences() throws {
    struct Saved: Decodable {
      let camera: String
      let lut: String
      let workspace: MonitorWorkspaceState
    }
    for payload in [
      "[]", "{\"layout\":\"future-layout\"}", "{\"schemaVersion\":999}", "{\"tileBindings\":3}",
    ] {
      let json = "{\"camera\":\"camera-a\",\"lut\":\"saved.cube\",\"workspace\":" + payload + "}"
      let saved = try JSONDecoder().decode(Saved.self, from: Data(json.utf8))
      XCTAssertEqual(saved.camera, "camera-a")
      XCTAssertEqual(saved.lut, "saved.cube")
      XCTAssertEqual(saved.workspace, MonitorWorkspaceState())
    }
  }
  func testWorkspaceConfiguredEmptyBindingsSurviveRoundtrip() throws {
    var workspace = MonitorWorkspaceState()
    XCTAssertFalse(workspace.isConfigured)
    workspace.isConfigured = true
    let restored = try JSONDecoder().decode(
      MonitorWorkspaceState.self, from: JSONEncoder().encode(workspace))
    XCTAssertTrue(restored.isConfigured)
    XCTAssertTrue(restored.tileBindings.allSatisfy { $0 == nil })
    XCTAssertFalse(
      try JSONDecoder().decode(MonitorWorkspaceState.self, from: Data("{}".utf8)).isConfigured)
  }
  func testWorkspaceDefaultsAndSavedMissingBindings() throws {
    let empty = try JSONDecoder().decode(MonitorWorkspaceState.self, from: Data("{}".utf8))
    XCTAssertEqual(empty.tileBindings.count, 4)
    var workspace = empty
    workspace.layout = .sideBySide
    workspace.tileBindings[0] = MonitorTargetID("missing-feed")
    workspace.splitRatio = 10
    let restored = try JSONDecoder().decode(
      MonitorWorkspaceState.self, from: JSONEncoder().encode(workspace))
    XCTAssertEqual(restored.tileBindings[0], MonitorTargetID("missing-feed"))
    XCTAssertEqual(restored.normalizedSplitRatio, 0.8)
    XCTAssertEqual(restored.layout.tileCount, 2)
  }
  func testProcessingChangeInvalidatesInflightResults() {
    let target = MonitorTargetID("a")
    var gate = MonitorResultGate(target: target)
    let old = MonitorFrameStamp(
      target: target, generation: 0, sequence: 1, sourcePTS: 0, hostTime: 0,
      configurationRevision: 0)
    gate.updateProcessing(revision: 1)
    XCTAssertFalse(gate.accept(old))
    var current = old
    current.processingRevision = 1
    XCTAssertTrue(gate.accept(current))
  }
  func testFeedCopiesRemainIndependentAndFalseColorSuppressesZebraOnly() {
    var first = MonitorConfiguration()
    first.toolsEnabled = true
    first.zebra.enabled = true
    var second = first
    second.falseColor.mode = .arri
    second.falseColor.exposureIndex = 1600
    second.pictureStage = .source
    XCTAssertTrue(first.effectiveZebraEnabled)
    XCTAssertFalse(second.effectiveZebraEnabled)
    XCTAssertTrue(second.zebra.enabled)
    XCTAssertEqual(first.falseColor.mode, .off)
    XCTAssertEqual(second.scopeStage, .processedOutput)
  }
  func testAspectFitApertureAndPixelCenterMapping() throws {
    let geometry = MonitorGeometry(
      width: 4000, height: 2200, cleanAperture: MonitorRect(x: 80, y: 20, width: 3840, height: 2160)
    )
    let viewport = MonitorRect(width: 1000, height: 1000)
    let fit = try XCTUnwrap(geometry.aspectFit(in: viewport))
    XCTAssertEqual(fit.width, 1000, accuracy: 0.0001)
    XCTAssertEqual(fit.height, 562.5, accuracy: 0.0001)
    let center = try XCTUnwrap(
      geometry.mapToView(MonitorPoint(x: 2000, y: 1100), viewport: viewport))
    XCTAssertEqual(center.x, 500, accuracy: 0.0001)
    XCTAssertEqual(center.y, 500, accuracy: 0.0001)
    let mapping = MonitorCorrespondence(scaleX: 0.5, scaleY: 0.5, offsetX: -40, offsetY: -10)
    XCTAssertEqual(mapping.map(MonitorPoint(x: 80.5, y: 20.5)), MonitorPoint(x: 0.25, y: 0.25))
    XCTAssertNil(
      MonitorGeometry(width: 100, height: 100, pixelAspectRatio: .nan).aspectFit(in: viewport))
  }
  func testRotationAndNonSquarePixels() throws {
    let geometry = MonitorGeometry(width: 100, height: 50, pixelAspectRatio: 2, orientation: .right)
    let fit = try XCTUnwrap(geometry.aspectFit(in: MonitorRect(width: 400, height: 400)))
    XCTAssertEqual(fit.width, 100)
    XCTAssertEqual(fit.height, 400)
    let point = try XCTUnwrap(
      geometry.mapToView(MonitorPoint(x: 0, y: 0), viewport: MonitorRect(width: 400, height: 400)))
    XCTAssertEqual(point, MonitorPoint(x: 250, y: 0))
  }
  func testCancellationRevisionAndSequenceRejectStaleResults() {
    let target = MonitorTargetID("feed")
    var gate = MonitorResultGate(target: target, generation: 1, configurationRevision: 2)
    func stamp(_ sequence: UInt64, _ generation: UInt64 = 1, _ revision: UInt64 = 2)
      -> MonitorFrameStamp
    {
      MonitorFrameStamp(
        target: target, generation: generation, sequence: sequence, sourcePTS: 1, hostTime: 2,
        configurationRevision: revision)
    }
    XCTAssertTrue(gate.accept(stamp(2)))
    XCTAssertFalse(gate.accept(stamp(1)))
    gate.reconfigure(revision: 3)
    XCTAssertFalse(gate.accept(stamp(3)))
    XCTAssertTrue(gate.accept(stamp(3, 1, 3)))
    gate.cancel()
    XCTAssertFalse(gate.accept(stamp(4, 1, 3)))
    gate.restart(generation: 2)
    XCTAssertFalse(gate.accept(stamp(5, 1, 3)))
    XCTAssertTrue(gate.accept(stamp(1, 2, 3)))
  }
}
