// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitCore
import XCTest

@testable import MonitorKitUI

/// The legend lists exactly the bands the GPU classifies with.
final class LegendTests: XCTestCase {
  func settings(_ mode: FalseColorMode, unit: FalseColorUnit = .ire, bands: [FalseColorBand] = []) -> FalseColorSettings {
    var s = FalseColorSettings()
    s.mode = mode
    s.customUnit = unit
    s.customBands = bands
    return s
  }

  func assertMatchesTable(
    _ legend: FalseColorLegend?, _ s: FalseColorSettings, curve: LogCurve?, full: Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let legend = try XCTUnwrap(legend, file: file, line: line)
    let bands = FalseColorTable.bands(for: s, arriCurve: curve, arriFullRange: full)
    XCTAssertEqual(legend.entries.count, bands.count, file: file, line: line)
    for (e, b) in zip(legend.entries, bands) {
      XCTAssertEqual(e.lower, b.lower, file: file, line: line)
      XCTAssertEqual(e.upper, b.upper, file: file, line: line)
      XCTAssertEqual(e.color, b.color, file: file, line: line)
      XCTAssertFalse(e.name.isEmpty, file: file, line: line)
      XCTAssertFalse(e.range.isEmpty, file: file, line: line)
    }
    XCTAssertEqual(Set(legend.entries.map(\.id)).count, legend.entries.count, file: file, line: line)
  }

  func testEveryModeMatchesItsTable() throws {
    let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
    try assertMatchesTable(FalseColorLegend(settings: settings(.sonySLog3), signal: slog3), settings(.sonySLog3), curve: .sLog3, full: false)
    try assertMatchesTable(FalseColorLegend(settings: settings(.arriStyleSLog3), signal: slog3), settings(.arriStyleSLog3), curve: .sLog3, full: false)
    try assertMatchesTable(FalseColorLegend(settings: settings(.sixBand)), settings(.sixBand), curve: nil, full: false)
    let custom = settings(.custom, unit: .stops, bands: [
      FalseColorBand(lower: -.infinity, upper: -2, color: ColorRGB(r: 0, g: 0, b: 1)),
      FalseColorBand(lower: -0.5, upper: 0.5, color: ColorRGB(r: 0, g: 1, b: 0)),
    ])
    try assertMatchesTable(FalseColorLegend(settings: custom), custom, curve: nil, full: false)
    for curve in [LogCurve.arriLogC3, .arriLogC4] {
      for range in [CodeRange.legal, .full] {
        let gamut: ColorGamut = curve == .arriLogC3 ? .arriWideGamut3 : .arriWideGamut4
        let signal = SignalDescription(range: range, encoding: .log(LogEncoding(curve: curve, gamut: gamut)))
        let legend = FalseColorLegend(settings: settings(.arriLogC), signal: signal)
        try assertMatchesTable(legend, settings(.arriLogC), curve: curve, full: range == .full)
        XCTAssertEqual(legend?.unit, .code)
        XCTAssertTrue(legend?.title.hasSuffix(range == .full ? "full range" : "legal range") == true)
      }
    }
    // A full container rescaled to legal uses the full-range table, as the pass does.
    let rescaled = SignalDescription(
      range: .legal, encoding: .log(LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3, transport: .fullRescaledToLegal)))
    try assertMatchesTable(
      FalseColorLegend(settings: settings(.arriLogC), signal: rescaled), settings(.arriLogC), curve: .arriLogC3, full: true)
  }

  func testNoLegendWithoutBands() {
    XCTAssertNil(FalseColorLegend(settings: settings(.off)))
    XCTAssertNil(FalseColorLegend(settings: settings(.arriLogC)), "no LogC signal, no table")
    XCTAssertNil(FalseColorLegend(settings: settings(.arriLogC), signal: SignalDescription(encoding: .log(.sLog3SGamut3))))
    XCTAssertNil(FalseColorLegend(settings: settings(.custom)))
  }

  func testNamesUnitsAndRanges() throws {
    let sony = try XCTUnwrap(FalseColorLegend(settings: settings(.sonySLog3)))
    XCTAssertEqual(sony.unit, .ire)
    XCTAssertEqual(sony.entries.map(\.name), [
      "Red", "Orange", "Yellow", "Cyan", "Pink", "Light pink", "Green", "Light blue", "Blue", "Purple",
    ])
    XCTAssertEqual(sony.entries[6].range, "38.9 – 42.2")
    XCTAssertEqual(sony.title, SonySLog3FalseColor.displayName)

    let six = try XCTUnwrap(FalseColorLegend(settings: settings(.sixBand)))
    XCTAssertEqual(six.entries.first?.name, "Black clip")
    XCTAssertEqual(six.entries.first?.range, "< 2.5")
    XCTAssertEqual(six.entries.last?.range, "≥ 99")
    XCTAssertEqual(six.entries[2].name, "18% grey")
    XCTAssertEqual(six.displayOrder.first?.name, "White clip", "brightest first")
    XCTAssertEqual(six.displayOrder.last?.name, "Black clip")

    let arri = try XCTUnwrap(FalseColorLegend(settings: settings(.arriStyleSLog3)))
    XCTAssertEqual(arri.unit, .code)
    XCTAssertEqual(arri.entries.first?.name, "White clipping")
    XCTAssertEqual(arri.entries.first?.range, "≥ 951", "red is open-ended upward")
    XCTAssertEqual(arri.entries.last?.name, "Black clipping")
    XCTAssertEqual(arri.entries.last?.range, "0 – 103", "the ARRI-style adaptation keeps purple's floor")
    let logC3 = SignalDescription(range: .legal, encoding: .log(LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3)))
    let literal = try XCTUnwrap(FalseColorLegend(settings: settings(.arriLogC), signal: logC3))
    XCTAssertEqual(literal.entries.first?.range, "≥ 878", "red is open-ended upward")
    XCTAssertEqual(literal.entries.last?.range, "< 152", "purple is open-ended downward")

    let stops = try XCTUnwrap(FalseColorLegend(settings: settings(.custom, unit: .stops, bands: [
      FalseColorBand(lower: -.infinity, upper: Double(Float(-3).nextUp), color: ColorRGB(r: 0, g: 0, b: 0)),
      FalseColorBand(lower: -0.5, upper: 0.5, color: ColorRGB(r: 0.5, g: 0.5, b: 0.5)),
    ])))
    XCTAssertEqual(stops.unit, .stops)
    XCTAssertEqual(stops.entries.map(\.name), ["Band 1", "Band 2"])
    XCTAssertEqual(stops.entries[0].range, "≤ −3", "an upper edge one Float step above a printed value includes it")
    XCTAssertEqual(stops.entries[1].range, "−0.5 – +0.5")
    XCTAssertNotNil(stops.gapNote)
    XCTAssertNotNil(six.gapNote)
  }
}
