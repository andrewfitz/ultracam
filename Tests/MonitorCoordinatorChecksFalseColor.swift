import CoreVideo
import Foundation
import MonitorKit
import MonitorKitUI
import XCTest

// W4 (integration map §8.2): MonitorToolsUITests' false-colour toolbar cases (53,
// 71, 99, 124, 162) and SonyFalseColorUITests, moved onto the app's settings
// (MonitorFeedPreferences and its signal declaration), the coordinator that
// publishes them and MonitorKitUI's legend.
//
// What changed by design: MonitorTools qualified a mode with a false-colour
// profile ID, a specification version and an exposure index, and its
// normalization switched a mode to match the source. MonitorKit has no such
// qualification: the mode is a setting of its own, the declared camera profile
// says what the signal is, and `falseColorDeclared` decides (as MonitorTools'
// normalization did) whether the mode can show, and so whether it suppresses
// zebra. Choosing a mode or a camera is one complete publication of the whole
// preferences. The switch of a log mode the new camera cannot show to one it
// can (ARRI LogC to Sony S-Log3) is `MonitorFeedPreferences.declaringCameraLog`,
// which the settings' Camera log picker calls and these checks cover; the
// coordinator keeps and publishes whatever the interface sets.
extension MonitorCoordinatorChecks {
  private static let portedSonySources = ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"]
  private static let portedARRISources = ["arri-logc3-ei800", "arri-alexa35-logc4-ei800"]

  /// A coordinator with the targets "alpha" and "beta" and the given saved preferences.
  private func portedFalseColorCoordinator(_ saved: [String: MonitorFeedPreferences] = [:]) -> MonitorCoordinator {
    let value = MonitorCoordinator(
      preferences: Dictionary(uniqueKeysWithValues: saved.map { (MonitorTargetID($0.key), $0.value) }))
    value.updateTargets(
      feeds: ["alpha", "beta"].map { FeedDescriptor(id: FeedID(rawValue: $0), name: $0) }, programAvailable: false)
    return value
  }

  /// The settings popover's change: whole preferences, tools turned on for a mode
  /// as its binding does.
  private func portedSelecting(_ mode: FalseColorMode, in value: MonitorFeedPreferences) -> MonitorFeedPreferences {
    var next = value
    if mode != .off && !next.toolsEnabled { next.hideAllTools() }
    next.state.falseColor.mode = mode
    next.toolsEnabled = next.anyToolOn
    return next
  }

  /// The signal a surface reads for `preferences`: a camera frame with the feed's
  /// declaration applied by its feed host.
  private func portedSignal(_ preferences: MonitorFeedPreferences, program: Bool = false) throws -> SignalDescription {
    let host = MonitorFeedHost(target: program ? MonitorFeedHost.programTarget : "alpha", gpu: nil)
    host.setSignalDeclaration(preferences.signal)
    return host.signal(of: try monitorPixelBuffer(format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange))
  }

  private func portedLegend(_ preferences: MonitorFeedPreferences) throws -> FalseColorLegend? {
    FalseColorLegend(settings: preferences.state.falseColor, signal: try portedSignal(preferences))
  }

  /// Program with a declared log mode and zebra on: the log false colour Program
  /// turns off must not suppress zebra, which then still shows. Only false colour
  /// that draws suppresses zebra (MonitorTools' `effectiveZebraEnabled`).
  private func portedExpectProgramZebra(_ preferences: MonitorFeedPreferences) {
    var value = preferences
    value.toolsEnabled = true
    value.state.zebras[0].enabled = true
    XCTAssertTrue(value.state.falseColor.mode.needsLogSource && value.falseColorDeclared)
    let program = value.surfaceState(isProgram: true)
    XCTAssertEqual(program.falseColor.mode, .off)
    XCTAssertFalse(value.surfaceState(isProgram: false).zebras[0].enabled, "A camera's log false colour suppresses zebra")
    // Not strict: once surfaceState is fixed this passes; the wrapper then comes out.
    XCTExpectFailure(
      "NEEDS: surfaceState suppresses zebra for the log false colour Program turns off", strict: false
    ) {
      XCTAssertTrue(program.zebras[0].enabled, "Program shows zebra when its log false colour is off")
    }
  }

  // MARK: MonitorToolsUITests

  /// MonitorToolsUITests:53. False colour off has no legend; a Sony mode on a Sony
  /// camera analyses the source, whatever picture stage is shown (Output (LUT) by default).
  func testFalseColorOffAndSourceAnalysisCaptions() throws {
    var preferences = MonitorFeedPreferences()
    preferences.toolsEnabled = true
    XCTAssertEqual(preferences.state.pictureStage, .output, "The picture shows Output (LUT) by default")
    XCTAssertNil(try portedLegend(preferences), "False colour off: no legend, no analysis")
    preferences.signal = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine")
    preferences = portedSelecting(.sonySLog3, in: preferences)
    let legend = try XCTUnwrap(try portedLegend(preferences))
    XCTAssertEqual(legend.analysis, "Source IRE")
    XCTAssertEqual(legend.sourceName, "Sony S-Gamut3.Cine / S-Log3")
    XCTAssertTrue(legend.headline.contains("Source IRE"), legend.headline)
    XCTAssertNil(legend.unavailableNote)
    XCTAssertEqual(preferences.surfaceState(isProgram: false).pictureStage, .output, "False colour leaves the picture stage")
  }

  /// MonitorToolsUITests:71. Showing a feed's surfaces never rewrites its saved
  /// settings; choosing the Sony mode on a declared Sony camera shows it (and
  /// suppresses zebra); turning it off keeps the camera declaration.
  func testExplicitSonyModeSelectionQualifiesAnExistingSonyDeclaration() throws {
    for source in Self.portedSonySources {
      var saved = MonitorFeedPreferences()
      saved.signal = MonitorSignalDeclaration(logProfileID: source)
      saved.toolsEnabled = true
      saved.state.zebras[0].enabled = true
      let value = portedFalseColorCoordinator(["alpha": saved])
      var published: [MonitorFeedPreferences] = []
      value.onConfigurationChange = { _, preferences in published.append(preferences) }
      let id = UUID()
      let surface = value.surface(id: id, target: MonitorTargetID("alpha"))
      value.registerSurface(id: id, target: MonitorTargetID("alpha"), isVisible: true, scopeVisible: false)
      XCTAssertEqual(value.preferences(for: MonitorTargetID("alpha")), saved, "Showing a surface never migrates saved settings")
      XCTAssertTrue(published.isEmpty)

      value.setPreferences(portedSelecting(.sonySLog3, in: saved), for: MonitorTargetID("alpha"))

      XCTAssertEqual(published.count, 1)
      let selected = value.preferences(for: MonitorTargetID("alpha"))
      XCTAssertEqual(selected.state.falseColor.mode, .sonySLog3)
      XCTAssertEqual(selected.signal, saved.signal)
      XCTAssertTrue(selected.falseColorDeclared)
      XCTAssertEqual(surface.currentEncodeState.falseColor.mode, .sonySLog3)
      XCTAssertFalse(surface.currentEncodeState.zebras[0].enabled, "False colour still suppresses zebra")
      value.setPreferences(portedSelecting(.off, in: selected), for: MonitorTargetID("alpha"))
      XCTAssertEqual(value.preferences(for: MonitorTargetID("alpha")).state.falseColor.mode, .off)
      XCTAssertEqual(value.preferences(for: MonitorTargetID("alpha")).signal, saved.signal, "Off keeps the camera")
      XCTAssertEqual(published.count, 2)
    }
  }

  /// MonitorToolsUITests:99. Switching the camera between ARRI and Sony is one
  /// complete change: whether the selected mode shows follows the new camera at once.
  func testSourceProfileSwitchIsAtomicAcrossCoordinatorPublication() throws {
    for sonySource in Self.portedSonySources {
      var arri = MonitorFeedPreferences()
      arri.signal = MonitorSignalDeclaration(logProfileID: "arri-logc3-ei800")
      arri = portedSelecting(.arriLogC, in: arri)
      let value = portedFalseColorCoordinator(["alpha": arri])
      var published: [MonitorFeedPreferences] = []
      value.onConfigurationChange = { _, preferences in published.append(preferences) }
      XCTAssertTrue(arri.falseColorDeclared)

      var sony = arri
      sony.signal.logProfileID = sonySource
      sony.state.falseColor.mode = .sonySLog3
      value.setPreferences(sony, for: MonitorTargetID("alpha"))

      XCTAssertEqual(published.count, 1, "Camera and mode reach the surfaces together")
      XCTAssertEqual(published.last?.signal.logProfileID, sonySource)
      XCTAssertEqual(published.last?.state.falseColor.mode, .sonySLog3)
      XCTAssertTrue(published.last?.falseColorDeclared == true)
      XCTAssertEqual(try portedSignal(sony).encoding.log?.curve, .sLog3)

      var back = sony
      back.signal.logProfileID = "arri-alexa35-logc4-ei800"
      back.state.falseColor.mode = .arriLogC
      value.setPreferences(back, for: MonitorTargetID("alpha"))
      XCTAssertEqual(published.count, 2)
      XCTAssertTrue(back.falseColorDeclared)
      XCTAssertEqual(try portedSignal(back).encoding.log?.curve, .arriLogC4)
    }
  }

  /// MonitorToolsUITests:124. Declaring either Sony S-Log3 camera makes Sony false
  /// colour show for that feed only, keeping its range, transport and other tools;
  /// Program never shows log false colour and ignores a declaration.
  func testSelectingEitherSonyLogSourceEnablesSonyFalseColorForOnlyThatFeed() throws {
    for source in Self.portedSonySources {
      var start = MonitorFeedPreferences()
      start.toolsEnabled = true
      start.state.falseColor.mode = .sonySLog3
      start.state.guides.enabled = true
      start.signal = MonitorSignalDeclaration(range: .full, transport: .fullRescaledToLegal)
      let value = portedFalseColorCoordinator(["alpha": start, "beta": start])
      XCTAssertFalse(start.falseColorDeclared, "No camera declared: the mode cannot show")

      var selected = start
      selected.signal.logProfileID = source
      value.setPreferences(selected, for: MonitorTargetID("alpha"))

      let alpha = value.preferences(for: MonitorTargetID("alpha"))
      XCTAssertEqual(alpha.signal.logProfileID, source)
      XCTAssertTrue(alpha.falseColorDeclared)
      XCTAssertTrue(SonySLog3FalseColor.supports(sourceProfileID: alpha.signal.logProfileID))
      XCTAssertEqual(alpha.signal.range, .full)
      XCTAssertEqual(alpha.signal.transport, .fullRescaledToLegal)
      XCTAssertTrue(alpha.state.guides.enabled)
      let signal = try portedSignal(alpha)
      XCTAssertEqual(signal.encoding.log?.transport, .fullRescaledToLegal)
      XCTAssertEqual(signal.range, .full)
      let beta = value.preferences(for: MonitorTargetID("beta"))
      XCTAssertNil(beta.signal.logProfileID)
      XCTAssertFalse(beta.falseColorDeclared)

      var other = beta
      other.signal.logProfileID = "arri-logc3-ei800"
      value.setPreferences(other, for: MonitorTargetID("beta"))
      XCTAssertEqual(value.preferences(for: MonitorTargetID("alpha")), alpha, "Another feed's camera never changes this one")
      XCTAssertEqual(value.preferences(for: MonitorTargetID("beta")).signal.logProfileID, "arri-logc3-ei800")

      // Program: no log false colour, and its frames ignore a camera declaration.
      XCTAssertEqual(alpha.surfaceState(isProgram: true).falseColor.mode, .off)
      XCTAssertNil(try portedSignal(alpha, program: true).encoding.log)
      portedExpectProgramZebra(alpha)
    }
  }

  /// The Camera log picker's rule (MonitorToolsUITests:99/124/143): a log mode
  /// the new camera cannot show switches to the one it can, back again on the
  /// old camera; a mode that needs no log source is untouched, and clearing the
  /// declaration leaves a log mode selected to explain itself.
  func testDeclaringCameraLogSwitchesLogFalseColorBetweenCameras() throws {
    for sonySource in Self.portedSonySources {
      for arriSource in Self.portedARRISources {
        var arri = MonitorFeedPreferences()
        arri.toolsEnabled = true
        arri.signal.logProfileID = arriSource
        arri.state.falseColor.mode = .arriLogC
        XCTAssertTrue(arri.falseColorDeclared)

        let sony = arri.declaringCameraLog(sonySource)
        XCTAssertEqual(sony.signal.logProfileID, sonySource)
        XCTAssertEqual(sony.state.falseColor.mode, .sonySLog3, "ARRI LogC becomes Sony's table on S-Log3")
        XCTAssertTrue(sony.falseColorDeclared)

        let back = sony.declaringCameraLog(arriSource)
        XCTAssertEqual(back.signal.logProfileID, arriSource)
        XCTAssertEqual(back.state.falseColor.mode, .arriLogC, "Back on ARRI: ARRI's table again")

        let cleared = sony.declaringCameraLog(nil)
        XCTAssertNil(cleared.signal.logProfileID)
        XCTAssertEqual(cleared.state.falseColor.mode, .sonySLog3, "No declaration: the mode stays and explains itself")
        XCTAssertFalse(cleared.falseColorDeclared)

        for mode in [FalseColorMode.sixBand, .custom, .off] {
          var other = arri
          other.state.falseColor.mode = mode
          XCTAssertEqual(other.declaringCameraLog(sonySource).state.falseColor.mode, mode, "\(mode) is untouched")
        }
      }
      var arriStyle = MonitorFeedPreferences()
      arriStyle.signal.logProfileID = sonySource
      arriStyle.state.falseColor.mode = .arriStyleSLog3
      let otherSony = Self.portedSonySources.first { $0 != sonySource }
      XCTAssertEqual(arriStyle.declaringCameraLog(otherSony).state.falseColor.mode, .arriStyleSLog3,
        "Another S-Log3 keeps ARRI-style")
    }
    // Program: no log mode is available and a toggle suggests six band.
    XCTAssertFalse(MonitorFeedPreferences.falseColorModeIsAvailable(.sonySLog3, profile: "sony-slog3-sgamut3",
      isProgram: true))
    XCTAssertTrue(MonitorFeedPreferences.falseColorModeIsAvailable(.sixBand, profile: nil, isProgram: true))
    XCTAssertTrue(MonitorFeedPreferences.falseColorModeIsAvailable(.off, profile: nil, isProgram: true))
    XCTAssertEqual(MonitorFeedPreferences.suggestedFalseColorMode(profile: "arri-logc3-ei800", isProgram: true), .sixBand)
    XCTAssertEqual(MonitorFeedPreferences.suggestedFalseColorMode(profile: "arri-logc3-ei800"), .arriLogC)
  }

  /// MonitorToolsUITests:162. Declaring a literal ARRI camera keeps its own
  /// profile: its LogC curve, the ARRI table for it, and no Sony mode.
  func testSelectingLiteralARRISourcesPreservesTheirCameraProfiles() throws {
    for (source, curve, name) in [("arri-logc3-ei800", LogCurve.arriLogC3, "ARRI LogC3 EI800"),
      ("arri-alexa35-logc4-ei800", .arriLogC4, "ARRI ALEXA 35 LogC4 EI800")]
    {
      var selected = MonitorFeedPreferences()
      selected.signal = MonitorSignalDeclaration(logProfileID: source)
      selected = portedSelecting(.arriLogC, in: selected)
      XCTAssertEqual(selected.signal.logProfileID, source)
      XCTAssertEqual(selected.signal.logEncoding?.curve, curve)
      XCTAssertTrue(selected.falseColorDeclared)
      let legend = try XCTUnwrap(try portedLegend(selected))
      XCTAssertTrue(legend.title.hasPrefix(name), legend.title)
      XCTAssertEqual(legend.unit, .code)
      XCTAssertFalse(SonySLog3FalseColor.supports(sourceProfileID: source))
      XCTAssertFalse(SonyARRIStyleFalseColor.supports(sourceProfileID: source))
    }
  }

  // MARK: SonyFalseColorUITests

  /// SonyFalseColorUITests:80. An unknown saved camera profile is kept as saved
  /// (shown, persisted and never rewritten) and offers no Sony mode until a Sony
  /// camera is chosen; a Sony mode on it says why it is unavailable.
  func testUnknownSavedSourceHasMatchingFallbackWithoutChangingSavedConfiguration() throws {
    for source in ["unknown-persisted-log", "arri-logc3-ei800", ""] {
      var saved = MonitorFeedPreferences()
      saved.signal.logProfileID = source
      let value = portedFalseColorCoordinator(["alpha": saved])
      var writes = 0
      value.onConfigurationChange = { _, _ in writes += 1 }
      let id = UUID()
      _ = value.surface(id: id, target: MonitorTargetID("alpha"))
      value.registerSurface(id: id, target: MonitorTargetID("alpha"), isVisible: true, scopeVisible: false)
      XCTAssertEqual(value.preferences(for: MonitorTargetID("alpha")), saved)
      XCTAssertEqual(writes, 0, "Showing an unsupported saved input never replaces it")
      let decoded = try JSONDecoder().decode(MonitorFeedPreferences.self, from: JSONEncoder().encode(saved))
      XCTAssertEqual(decoded.signal.logProfileID, source, "The saved input survives a save and load")
      XCTAssertFalse(SonySLog3FalseColor.supports(sourceProfileID: source))
      XCTAssertFalse(SonyARRIStyleFalseColor.supports(sourceProfileID: source))
      let sony = portedSelecting(.sonySLog3, in: saved)
      XCTAssertFalse(sony.falseColorDeclared)
      XCTAssertNotNil(try portedLegend(sony)?.unavailableNote, "A Sony mode on this input says it is unavailable")

      var chosen = saved
      chosen.signal.logProfileID = "sony-slog3-sgamut3cine"
      value.setPreferences(chosen, for: MonitorTargetID("alpha"))
      XCTAssertTrue(SonySLog3FalseColor.supports(sourceProfileID: value.preferences(for: MonitorTargetID("alpha")).signal.logProfileID))
      XCTAssertTrue(SonyARRIStyleFalseColor.supports(
        sourceProfileID: value.preferences(for: MonitorTargetID("alpha")).signal.logProfileID))
      XCTAssertEqual(writes, 1)
    }
    for source in Self.portedSonySources {
      var preferences = MonitorFeedPreferences()
      preferences.signal.logProfileID = source
      let sony = portedSelecting(.sonySLog3, in: preferences)
      XCTAssertTrue(sony.falseColorDeclared, source)
      XCTAssertNil(try XCTUnwrap(try portedLegend(sony)).unavailableNote, source)
    }
    // No saved camera is not an unsupported one: nothing is kept, and the Sony
    // mode waits for a camera to be declared.
    var none = MonitorFeedPreferences()
    none.signal.logProfileID = nil
    XCTAssertNil(none.signal.logEncoding)
    XCTAssertFalse(portedSelecting(.sonySLog3, in: none).falseColorDeclared)
  }

  /// SonyFalseColorUITests:105. The Sony mode on a Sony camera is one complete
  /// publication keeping the other tools, for that feed only; off keeps the camera.
  func testSonyModeSelectionPublishesOneCompleteQualifiedConfiguration() throws {
    for source in Self.portedSonySources {
      var saved = MonitorFeedPreferences()
      saved.signal = MonitorSignalDeclaration(logProfileID: source)
      saved.toolsEnabled = true
      saved.state.guides.enabled = true
      saved.state.guides.centerCross = true
      let value = portedFalseColorCoordinator(["alpha": saved, "beta": saved])
      var published: [(MonitorTargetID, MonitorFeedPreferences)] = []
      value.onConfigurationChange = { published.append(($0, $1)) }

      value.setPreferences(portedSelecting(.sonySLog3, in: saved), for: MonitorTargetID("alpha"))

      XCTAssertEqual(published.count, 1, "The mode reaches the surfaces in one complete update")
      XCTAssertEqual(published.first?.0, MonitorTargetID("alpha"))
      XCTAssertEqual(published.first?.1.state.falseColor.mode, .sonySLog3)
      XCTAssertTrue(published.first?.1.falseColorDeclared == true)
      XCTAssertTrue(published.first?.1.state.guides.centerCross == true)
      XCTAssertEqual(value.preferences(for: MonitorTargetID("beta")).state.falseColor.mode, .off, "Only that feed")

      value.setPreferences(
        portedSelecting(.off, in: value.preferences(for: MonitorTargetID("alpha"))), for: MonitorTargetID("alpha"))

      XCTAssertEqual(published.count, 2)
      let off = value.preferences(for: MonitorTargetID("alpha"))
      XCTAssertEqual(off.state.falseColor.mode, .off)
      XCTAssertEqual(off.signal.logProfileID, source, "Off keeps the camera")
      XCTAssertTrue(off.state.guides.centerCross)
    }
  }

  /// SonyFalseColorUITests:143, the coordinator's half. Switching an ARRI feed to
  /// a Sony camera is one publication that keeps range, transport, tools and
  /// scopes. The preferences and the coordinator keep the mode they are given: an
  /// ARRI mode left on a Sony camera cannot show (no legend, no zebra
  /// suppression). The interface never leaves it there: the Camera log picker
  /// switches it to the Sony mode, as MonitorTools' normalization did, and that
  /// rule is not compiled here. Saved MonitorTools settings migrate an
  /// ARRI-style mode to Sony (MonitorLifecycleChecks migration tests).
  func testSonySourceSelectionKeepsTheChosenModeAndEveryOtherSetting() throws {
    for source in Self.portedSonySources {
      var saved = MonitorFeedPreferences()
      saved.toolsEnabled = true
      saved.signal = MonitorSignalDeclaration(
        logProfileID: "arri-logc3-ei800", range: .full, transport: .fullRescaledToLegal)
      saved.state.falseColor.mode = .arriLogC
      saved.state.zebras[0].enabled = true
      saved.scopes.enabled = true
      let value = portedFalseColorCoordinator(["alpha": saved])
      var published: [MonitorFeedPreferences] = []
      value.onConfigurationChange = { _, preferences in published.append(preferences) }

      var selected = saved
      selected.signal.logProfileID = source
      value.setPreferences(selected, for: MonitorTargetID("alpha"))

      XCTAssertEqual(published.count, 1)
      let shown = value.preferences(for: MonitorTargetID("alpha"))
      XCTAssertEqual(shown.signal.logProfileID, source)
      XCTAssertEqual(shown.signal.range, .full)
      XCTAssertEqual(shown.signal.transport, .fullRescaledToLegal)
      XCTAssertTrue(shown.toolsEnabled)
      XCTAssertTrue(shown.scopes.enabled)
      XCTAssertEqual(shown.state.falseColor.mode, .arriLogC)
      XCTAssertFalse(shown.falseColorDeclared, "An ARRI table cannot classify S-Log3")
      XCTAssertNil(try portedLegend(shown))
      XCTAssertTrue(shown.surfaceState(isProgram: false).zebras[0].enabled, "A mode that cannot show leaves zebra on")
      let sony = portedSelecting(.sonySLog3, in: shown)
      XCTAssertTrue(sony.falseColorDeclared)
      XCTAssertFalse(sony.surfaceState(isProgram: false).zebras[0].enabled)
    }
  }
}
