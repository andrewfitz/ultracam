import MonitorKitCore
import SwiftUI
import XCTest

@testable import MonitorKit
@testable import MonitorKitUI

/// The tile toolbar's false colour follows what the pass can draw on the shown
/// signal, the modes the host allows, and the frame's layout for the legend.
@MainActor
final class TileToolbarFalseColorTests: XCTestCase {
  func signal(_ curve: LogCurve, _ gamut: ColorGamut) -> SignalDescription {
    SignalDescription(encoding: .log(LogEncoding(curve: curve, gamut: gamut)))
  }

  /// Turns false colour on with `remembered` in memory and returns the mode.
  func turnOn(remembered: FalseColorMode, signal: SignalDescription?) -> FalseColorMode {
    var memory = MonitorTileMemory()
    memory.falseColor = remembered
    var s = MonitorState()
    memory.toggle(.falseColor, in: &s, signal: signal)
    return s.falseColor.mode
  }

  /// Regression: a remembered mode came back on even when the new signal could
  /// not draw it (S-Log3's Pattern 2 on a LogC3 source): on, but not drawn.
  func testRememberedModeTheSignalCannotDrawFallsBack() {
    var memory = MonitorTileMemory()
    var s = MonitorState()
    let slog3 = signal(.sLog3, .sGamut3Cine)
    memory.toggle(.falseColor, in: &s, signal: slog3)
    XCTAssertEqual(s.falseColor.mode, .sonySLog3)
    memory.toggle(.falseColor, in: &s, signal: slog3)
    XCTAssertEqual(s.falseColor.mode, .off)
    memory.toggle(.falseColor, in: &s, signal: signal(.arriLogC3, .arriWideGamut3))
    XCTAssertEqual(s.falseColor.mode, .arriLogC, "LogC3 cannot draw Pattern 2: the signal's suggestion")
  }

  /// Every remembered mode against every signal: it comes back only where the
  /// pass draws it, else the signal's suggestion.
  func testRememberedModeFollowsThePassRule() {
    let logC3 = signal(.arriLogC3, .arriWideGamut3), logC4 = signal(.arriLogC4, .arriWideGamut4)
    let cine = signal(.sLog3, .sGamut3Cine), sg3 = signal(.sLog3, .sGamut3)
    let s709 = signal(.sLog3, .rec709), s2020 = signal(.sLog3, .rec2020)
    let plain = SignalDescription()
    XCTAssertEqual(turnOn(remembered: .sonySLog3, signal: logC4), .arriLogC)
    XCTAssertEqual(turnOn(remembered: .sonySLog3, signal: s709), .sonySLog3, "Pattern 2 reads any S-Log3 gamut")
    XCTAssertEqual(turnOn(remembered: .elZone, signal: s709), .sonySLog3, "EL Zone needs S-Gamut3")
    XCTAssertEqual(turnOn(remembered: .arriStyleSLog3, signal: s2020), .sonySLog3)
    XCTAssertEqual(turnOn(remembered: .elZone, signal: sg3), .elZone)
    XCTAssertEqual(turnOn(remembered: .arriStyleSLog3, signal: cine), .arriStyleSLog3)
    XCTAssertEqual(turnOn(remembered: .arriLogC, signal: cine), .sonySLog3, "no ARRI table for S-Log3")
    XCTAssertEqual(turnOn(remembered: .arriLogC, signal: logC3), .arriLogC)
    XCTAssertEqual(turnOn(remembered: .elZone, signal: logC3), .arriLogC)
    XCTAssertEqual(turnOn(remembered: .sonySLog3, signal: plain), .sixBand, "a non-log source")
    XCTAssertEqual(turnOn(remembered: .arriLogC, signal: plain), .sixBand)
    XCTAssertEqual(turnOn(remembered: .custom, signal: plain), .custom, "custom needs no log source")
    XCTAssertEqual(turnOn(remembered: .sixBand, signal: logC3), .sixBand)
    XCTAssertEqual(turnOn(remembered: .elZone, signal: nil), .elZone, "no signal: nothing judged")

    // The rule is the pass's: wherever the pass draws a log mode, `draws` agrees.
    let signals = [logC3, logC4, cine, sg3, s709, s2020, plain]
    for sig in signals {
      for mode in FalseColorMode.allCases where mode.needsLogSource {
        var st = MonitorState()
        st.falseColor.mode = mode
        let pass = MonitorPass.resolveFalseColor(st, signal: sig, full: false)
        var drawn = false
        if case .active = pass { drawn = true }
        XCTAssertEqual(MonitorTileTool.draws(mode, on: sig), drawn, "\(mode) on \(sig.encoding)")
      }
    }
  }

  /// Regression: the host could only disable false colour as a whole, so a
  /// programme tile lost six band too. `falseColorModes` narrows the modes.
  func testAllowedModesNarrowTheToggleAndPickers() {
    let noLog = FalseColorMode.allCases.filter { !$0.needsLogSource }
    let slog3 = signal(.sLog3, .sGamut3Cine)
    var memory = MonitorTileMemory()
    var s = MonitorState()
    memory.toggle(.falseColor, in: &s, signal: slog3, allowedFalseColor: noLog)
    XCTAssertEqual(s.falseColor.mode, .sixBand, "Pattern 2 is not allowed: six band")
    memory.toggle(.falseColor, in: &s, signal: slog3, allowedFalseColor: noLog)
    XCTAssertEqual(s.falseColor.mode, .off)

    // A log mode restored onto the tile turns off, then back on as six band.
    memory = MonitorTileMemory()
    s.falseColor.mode = .sonySLog3
    memory.toggle(.falseColor, in: &s, signal: slog3, allowedFalseColor: noLog)
    XCTAssertEqual(s.falseColor.mode, .off)
    XCTAssertEqual(memory.falseColor, .sonySLog3)
    memory.toggle(.falseColor, in: &s, signal: slog3, allowedFalseColor: noLog)
    XCTAssertEqual(s.falseColor.mode, .sixBand)
    // Allowed again (the tile shows a camera), the remembered custom mode returns.
    memory.select(.custom, in: &s)
    memory.toggle(.falseColor, in: &s, signal: slog3)
    memory.toggle(.falseColor, in: &s, signal: slog3, allowedFalseColor: noLog)
    XCTAssertEqual(s.falseColor.mode, .custom)

    XCTAssertEqual(
      MonitorTileTool.falseColorModeToTurnOn(remembered: nil, signal: slog3, allowed: [.custom]), .custom,
      "neither suggestion nor six band allowed: the first allowed mode")
    XCTAssertEqual(
      MonitorTileTool.falseColorModeToTurnOn(remembered: nil, signal: slog3, allowed: [.elZone, .arriLogC]), .elZone,
      "a drawable allowed mode first")
    XCTAssertNil(MonitorTileTool.falseColorModeToTurnOn(remembered: .sixBand, signal: nil, allowed: [.off]))
    var none = MonitorTileMemory()
    var untouched = MonitorState()
    none.toggle(.falseColor, in: &untouched, signal: slog3, allowedFalseColor: [])
    XCTAssertEqual(untouched, MonitorState(), "no mode allowed: the toggle does nothing")

    XCTAssertEqual(MonitorTileTool.falseColorChoices(allowed: nil, current: .off), FalseColorMode.allCases)
    XCTAssertEqual(MonitorTileTool.falseColorChoices(allowed: noLog, current: .off), [.off, .sixBand, .custom])
    XCTAssertEqual(
      MonitorTileTool.falseColorChoices(allowed: noLog, current: .elZone), [.off, .elZone, .sixBand, .custom],
      "the current mode keeps its tag")

    // The collapsed menu's picker writes only allowed modes.
    let box = Box(MonitorState())
    let bar = MonitorTileToolbar(state: box.binding, signal: slog3, falseColorModes: noLog)
    bar.falseColorSelection.wrappedValue = .sonySLog3
    XCTAssertEqual(box.value.falseColor.mode, .off)
    bar.falseColorSelection.wrappedValue = .custom
    XCTAssertEqual(box.value.falseColor.mode, .custom)
    XCTAssertFalse(bar.isFalseColorModeAllowed(.arriLogC))
    XCTAssertTrue(bar.isFalseColorModeAllowed(.off))
    bar.toggle(.falseColor)
    bar.toggle(.falseColor)
    XCTAssertEqual(box.value.falseColor.mode, .sixBand, "the bar's toggle honours the allowed modes")
    XCTAssertTrue(MonitorTileToolbar(state: box.binding).isFalseColorModeAllowed(.elZone), "nil allows all")

    // The settings popover's picker too.
    let controls = FalseColorControls(state: box.binding, signal: slog3, modes: noLog)
    controls.modeSelection.wrappedValue = .elZone
    XCTAssertEqual(box.value.falseColor.mode, .sixBand)
    controls.modeSelection.wrappedValue = .off
    XCTAssertEqual(box.value.falseColor.mode, .off)
    FalseColorControls(state: box.binding).modeSelection.wrappedValue = .elZone
    XCTAssertEqual(box.value.falseColor.mode, .elZone)
  }

  /// Regression: the toolbar's legend showed ARRI's legal-range table for a
  /// float frame, which the GPU classifies with the full-range one.
  func testLegendFollowsTheFrameLayout() throws {
    let box = Box(MonitorState())
    box.value.falseColor.mode = .arriLogC
    let logC3 = signal(.arriLogC3, .arriWideGamut3)
    XCTAssertEqual(logC3.range, .legal)
    let legal = try XCTUnwrap(FalseColorControls(state: box.binding, signal: logC3).legend)
    XCTAssertTrue(legal.title.hasSuffix("· legal range"), legal.title)
    let float = try XCTUnwrap(FalseColorControls(state: box.binding, signal: logC3, layout: .rgba16Float).legend)
    XCTAssertTrue(float.title.hasSuffix("· full range"), float.title)
    XCTAssertEqual(
      float, FalseColorLegend(settings: box.value.falseColor, signal: logC3, arriFullRange: true),
      "the full-range table, as the pass picks")
    XCTAssertTrue(FalseColorTable.usesFullRangeARRI(signal: logC3, layout: .rgba16Float))
    XCTAssertEqual(
      try XCTUnwrap(FalseColorControls(state: box.binding, signal: logC3, layout: .v210).legend), legal)

    // The toolbar hands its layout and modes to the settings it shows.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Sources/MonitorKitUI/SwiftUI/TileToolbar.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(
      source.contains(
        "FalseColorControls(state: $state, status: status, signal: signal, layout: layout, modes: falseColorModes)"))
    let bar = MonitorTileToolbar(state: box.binding, signal: logC3, layout: .rgba32Float)
    XCTAssertEqual(bar.layout, .rgba32Float)
  }
}
