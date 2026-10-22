import MonitorKitCore
import MonitorKitScopes
import SwiftUI
import XCTest

@testable import MonitorKit
@testable import MonitorKitUI

#if canImport(AppKit)
  import AppKit
#endif

/// R15: the legend captions, the scope IRE scale and the tile toolbar match the
/// app's monitor chrome (Packages/MonitorTools, UIMonitorTools.swift).
@MainActor
final class LegendCaptionTests: XCTestCase {
  func settings(_ mode: FalseColorMode, offset: Double = 0) -> FalseColorSettings {
    var s = FalseColorSettings()
    s.mode = mode
    s.referenceOffsetStops = offset
    return s
  }

  let cine = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
  let sgamut3 = SignalDescription(encoding: .log(.sLog3SGamut3))

  /// Sony Pattern 2: the app's swatch labels, computed here from Sony's table
  /// with the app's own format, and its captions.
  func testSonyPattern2Captions() throws {
    let legend = try XCTUnwrap(FalseColorLegend(settings: settings(.sonySLog3), signal: cine))
    XCTAssertEqual(legend.headline, "Sony S-Log3 · Source IRE · Sony S-Gamut3.Cine / S-Log3")
    XCTAssertEqual(legend.analysis, "Source IRE")
    XCTAssertEqual(legend.sourceName, "Sony S-Gamut3.Cine / S-Log3")
    XCTAssertEqual(legend.captions, ["Sony Monitor & Control Pattern 2 thresholds · MonitorKit display colours"])
    XCTAssertTrue(SonySLog3FalseColor.specificationVersion.contains("pattern2"), "the captions name the spec the table is")
    XCTAssertEqual(
      legend.footnotes,
      [
        "Lower edge included; upper excluded. Unassigned IRE stays grey.",
        "EI-independent source IRE bands do not guarantee Sony sensor clipping.",
      ])
    let names = [
      "Red", "Orange", "Yellow", "Cyan", "Pink", "Light pink", "Green", "Light blue", "Blue", "Purple",
    ]
    let expected = zip(SonySLog3FalseColor.zones, names).map { zone, name in
      "\(name): \(String(format: "%.1f", zone.lowerIRE))–\(String(format: "%.1f", zone.upperIRE)) IRE"
    }
    XCTAssertEqual(legend.entries.map(\.swatchLabel), expected)
    XCTAssertEqual(legend.entries[6].swatchLabel, "Green: 38.9–42.2 IRE")
    XCTAssertEqual(legend.entries[9].swatchLabel, "Purple: -7.0–3.5 IRE")
    XCTAssertEqual(legend.entries[4].swatchLabel, "Pink: 54.3–58.0 IRE")
    XCTAssertNil(legend.unavailableNote)
    XCTAssertFalse(legend.isProvisional)
    XCTAssertNil(legend.provisionalReason)
    XCTAssertFalse(legend.showsSwatchesAsGrid)

    let sg3 = try XCTUnwrap(FalseColorLegend(settings: settings(.sonySLog3), signal: sgamut3))
    XCTAssertEqual(sg3.headline, "Sony S-Log3 · Source IRE · Sony S-Gamut3 / S-Log3")
  }

  /// Without a signal the source is left out; on an unsupported one the legend says so.
  func testSourceNameAndAvailability() throws {
    let bare = try XCTUnwrap(FalseColorLegend(settings: settings(.sonySLog3)))
    XCTAssertEqual(bare.headline, "Sony S-Log3 · Source IRE")
    XCTAssertNil(bare.sourceName)
    XCTAssertNil(bare.unavailableNote, "no signal: nothing to judge")

    let unsupported = "Unavailable: choose a supported Sony S-Log3 source profile"
    let rec709 = SignalDescription()
    for mode in [FalseColorMode.sonySLog3, .elZone, .arriStyleSLog3] {
      let l = try XCTUnwrap(FalseColorLegend(settings: settings(mode), signal: rec709))
      XCTAssertEqual(l.sourceName, "Unknown source profile")
      XCTAssertEqual(l.unavailableNote, unsupported, "\(mode)")
      let logC = SignalDescription(encoding: .log(LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3)))
      XCTAssertEqual(FalseColorLegend(settings: settings(mode), signal: logC)?.unavailableNote, unsupported)
      let slog3In2020 = SignalDescription(encoding: .log(LogEncoding(curve: .sLog3, gamut: .rec2020)))
      let odd = try XCTUnwrap(FalseColorLegend(settings: settings(mode), signal: slog3In2020))
      if mode == .sonySLog3 {
        XCTAssertNil(odd.unavailableNote, "Pattern 2 is native S-Log3 IRE: the pass draws it in any gamut")
      } else {
        XCTAssertEqual(odd.unavailableNote, unsupported, "\(mode): S-Log3 outside S-Gamut3 is not a supported profile")
      }
      XCTAssertEqual(odd.sourceName, "Sony Rec.2020 / S-Log3")
      XCTAssertNil(FalseColorLegend(settings: settings(mode), signal: cine)?.unavailableNote)
    }
    XCTAssertNil(FalseColorLegend(settings: settings(.sixBand), signal: rec709)?.unavailableNote)
  }

  /// Regression: the legend says "Unavailable" exactly when the pass refuses
  /// the mode for the source, for every curve and gamut (it said so for Sony
  /// Pattern 2 on S-Log3 in Rec.2020 or Rec.709, which the pass draws).
  func testUnavailableNoteMatchesThePass() throws {
    let gamuts: [ColorGamut] = [.rec709, .rec2020, .sGamut3, .sGamut3Cine, .arriWideGamut3, .arriWideGamut4]
    var encodings: [SignalEncoding] = [.unknown, SignalDescription().encoding]
    for curve in LogCurve.allCases {
      for gamut in gamuts {
        for transport in [LogTransport.native, .fullRescaledToLegal] {
          encodings.append(.log(LogEncoding(curve: curve, gamut: gamut, transport: transport)))
        }
      }
    }
    for mode in [FalseColorMode.sonySLog3, .elZone, .arriStyleSLog3] {
      for encoding in encodings {
        let signal = SignalDescription(encoding: encoding)
        var state = MonitorState()
        state.falseColor = settings(mode)
        let drawn: Bool
        switch MonitorPass.resolveFalseColor(state, signal: signal, full: false) {
        case .active: drawn = true
        case .unavailable, .off: drawn = false
        }
        let legend = try XCTUnwrap(FalseColorLegend(settings: settings(mode), signal: signal))
        XCTAssertEqual(legend.unavailableNote == nil, drawn, "\(mode) on \(encoding)")
      }
    }
  }

  /// EL Zone (provisional): the chart's stop labels exactly as the app prints
  /// them, the offset line and the chart caption.
  func testELZoneCaptions() throws {
    let legend = try XCTUnwrap(FalseColorLegend(settings: settings(.elZone, offset: 1.25), signal: sgamut3))
    XCTAssertEqual(legend.headline, "EL Zone · Source stops · Sony S-Gamut3 / S-Log3")
    XCTAssertEqual(
      legend.captions,
      [
        "Public-chart mapping · Sony M&C match not tested",
        "18% grey = 0 stops before monitor offset",
        "Additive monitor offset: +1.25 stops · camera EI independent",
      ])
    XCTAssertEqual(legend.footnotes, ["Chart labels in stops · midpoint interior bands · black ≤−6, white ≥+6"])
    XCTAssertEqual(
      legend.entries.map(\.swatchLabel),
      ["≤−6", "-5", "-4", "-3", "-2", "-1", "-0.5", "+0", "+0.5", "+1", "+2", "+3", "+4", "+5", "≥+6"])
    // The app's chips: `%+g` of each chart label, the ends written out.
    let app = ELZoneProfile.stopLabels.indices.map { i in
      i == 0 ? "≤−6" : i == ELZoneProfile.stopLabels.count - 1 ? "≥+6" : String(format: "%+g", ELZoneProfile.stopLabels[i])
    }
    XCTAssertEqual(legend.entries.map(\.swatchLabel), app)
    XCTAssertTrue(legend.isProvisional)
    XCTAssertEqual(legend.provisionalReason, ELZoneReferenceStatus.reason)
    XCTAssertTrue(legend.showsSwatchesAsGrid)
    XCTAssertEqual(
      FalseColorLegend(settings: settings(.elZone, offset: -0.5))?.captions[2],
      "Additive monitor offset: -0.50 stops · camera EI independent")
    XCTAssertEqual(
      FalseColorLegend(settings: settings(.elZone))?.captions[2],
      "Additive monitor offset: +0.00 stops · camera EI independent")
  }

  /// ARRI: the published table, its version, EI and range; the S-Log3 adaptation says what it is.
  func testARRICaptions() throws {
    let version = ARRIFalseColorProfile.specificationVersion
    for (curve, gamut, name, source) in [
      (LogCurve.arriLogC3, ColorGamut.arriWideGamut3, "ARRI LogC3 EI800", "ARRI Wide Gamut 3 / LogC3"),
      (.arriLogC4, .arriWideGamut4, "ARRI ALEXA 35 LogC4 EI800", "ARRI Wide Gamut 4 / LogC4"),
    ] {
      for range in [CodeRange.legal, .full] {
        let signal = SignalDescription(range: range, encoding: .log(LogEncoding(curve: curve, gamut: gamut)))
        let legend = try XCTUnwrap(FalseColorLegend(settings: settings(.arriLogC), signal: signal))
        XCTAssertEqual(legend.headline, "\(name) · Source 10-bit code · \(source)")
        XCTAssertEqual(
          legend.captions,
          [
            "ARRI published 10-bit code table (\(version)) · EI 800",
            range == .full ? "Full-range codes (0–1023)" : "Legal-range codes (64–940)",
          ])
        XCTAssertEqual(legend.footnotes, ["Lower edge included; upper excluded."])
        XCTAssertEqual(legend.entries.first?.swatchLabel, "White clipping: \(legend.entries[0].range)")
        XCTAssertNil(legend.unavailableNote)
      }
    }
    let rescaled = SignalDescription(
      range: .legal,
      encoding: .log(LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3, transport: .fullRescaledToLegal)))
    let r = try XCTUnwrap(FalseColorLegend(settings: settings(.arriLogC), signal: rescaled))
    XCTAssertEqual(r.captions[1], "Full-range codes (0–1023)", "the table the pass uses")
    XCTAssertEqual(r.footnotes.last, "Log transport: full codes rescaled to legal")

    let style = try XCTUnwrap(FalseColorLegend(settings: settings(.arriStyleSLog3), signal: cine))
    XCTAssertEqual(style.headline, "ARRI-style — S-Log3 · LogC3 EI 800 reference code · Sony S-Gamut3.Cine / S-Log3")
    XCTAssertEqual(
      style.captions,
      [
        "ARRI LogC3 EI 800 reference bands from S-Log3 scene luminance · not an ARRI or Sony mode",
        "Full-range 10-bit reference codes (\(version))",
      ])
    XCTAssertEqual(style.footnotes.count, 2)
  }

  func testOtherModesHaveCaptions() throws {
    var six = settings(.sixBand)
    six.stage = .source
    let l = try XCTUnwrap(FalseColorLegend(settings: six))
    XCTAssertEqual(l.headline, "Six band · Source IRE")
    XCTAssertEqual(l.captions, ["Six bands on source IRE"])
    var custom = settings(.custom)
    custom.customUnit = .stops
    custom.customBands = [FalseColorBand(lower: -1, upper: 1, color: ColorRGB(r: 0, g: 1, b: 0))]
    let c = try XCTUnwrap(FalseColorLegend(settings: custom))
    XCTAssertEqual(c.analysis, "Output stops")
    XCTAssertEqual(c.entries[0].swatchLabel, "Band 1: −1 – +1")
    XCTAssertTrue(c.captions[0].contains("first match wins"))
  }

  /// The view shows the surface's reason over its own note.
  func testCaptionedViewUnavailableText() throws {
    let legend = try XCTUnwrap(FalseColorLegend(settings: settings(.sonySLog3), signal: SignalDescription()))
    XCTAssertEqual(
      FalseColorLegendView(legend: legend, style: .captioned).unavailableText,
      "Unavailable: choose a supported Sony S-Log3 source profile")
    XCTAssertEqual(
      FalseColorLegendView(legend: legend, style: .captioned, unavailable: .requiresLogSource).unavailableText,
      "Unavailable: " + MonitorUnavailableReason.requiresLogSource.description)
    let ok = try XCTUnwrap(FalseColorLegend(settings: settings(.sonySLog3), signal: cine))
    XCTAssertNil(FalseColorLegendView(legend: ok, style: .captioned).unavailableText)
  }
}

final class ScopeIREScaleTests: XCTestCase {
  /// On a −10…110 axis, the app's five levels where the app drew them:
  /// y = h · (110 − level) / 120.
  func testLegacyAxisMatchesTheAppsScale() {
    let scale = ScopeIREScale(axis: ScopeIREScale.legacyAxis)
    XCTAssertEqual(scale.marks.map(\.ire), [-10, 0, 50, 100, 110])
    XCTAssertEqual(scale.marks.map(\.label), ["-10", "0", "50", "100", "110"])
    for m in scale.marks {
      XCTAssertEqual(m.y, (110 - m.ire) / 120, accuracy: 1e-12)
    }
    XCTAssertEqual(scale.marks.map(\.isMajor), [false, true, true, true, false])
    XCTAssertEqual(scale.rangeText, "−10…110")
    XCTAssertEqual(scale.caption, "Sampled signal · −10…110 IRE · endpoints clamp outside scale")
    XCTAssertEqual(scale.accessibilityLabel, "Scope scale minus 10 to 110 IRE")
  }

  /// On MonitorKit's axis, levels it cannot show are left out (never pinned to
  /// an edge), and the rest sit where `ScopeLevelAxis` puts them.
  func testMonitorKitAxisDropsLevelsOffTheAxis() {
    let scale = ScopeIREScale()
    XCTAssertEqual(scale.axis, ScopeLevelAxis.low...ScopeLevelAxis.high)
    XCTAssertEqual(scale.marks.map(\.ire), [0, 50, 100])
    XCTAssertEqual(scale.marks.map(\.id), [1, 2, 3], "ids are the indices of the levels given")
    for m in scale.marks {
      XCTAssertEqual(1 - m.y, ScopeLevelAxis.fraction(ofLevel: m.ire / 100), accuracy: 1e-12)
    }
    XCTAssertEqual(scale.caption, "Sampled signal · −7…109 IRE · endpoints clamp outside scale")
    XCTAssertEqual(scale.accessibilityLabel, "Scope scale minus 7 to 109 IRE")
    let edges = ScopeIREScale(levels: [-7, 109, 109.5, .nan, .infinity])
    XCTAssertEqual(edges.marks.map(\.ire), [-7, 109], "the axis ends are on it; beyond and non-finite are not")
    XCTAssertEqual(edges.marks.first?.y ?? 0, 1, accuracy: 1e-12)
    XCTAssertEqual(edges.marks.last?.y ?? 1, 0, accuracy: 1e-12)
    XCTAssertEqual(ScopeIREScale(levels: [12.5]).marks.first?.label, "12.5")
  }

  /// With bins, marks sit on the centre of the bin the kernels count the level
  /// in, exactly as the scope's own graticule does.
  func testBinnedMarksMatchTheGraticule() {
    for bins in [64, 256, 511, 512, 1000, 2048] {
      let scale = ScopeIREScale(levels: [-7, 0, 10, 50, 90, 100, 109], bins: bins)
      XCTAssertEqual(scale.marks.count, 7)
      for m in scale.marks {
        // Bit-identical to the graticule's own tick (`1 - drawnFraction`).
        XCTAssertEqual(m.y, 1 - ScopeLevelAxis.drawnFraction(ofLevel: m.ire / 100, bins: bins), "\(bins) \(m.ire)")
      }
    }
    // Out-of-axis levels clamp into the end bins, as the trace does.
    XCTAssertEqual(ScopeIREScale.fraction(ofLevel: 5, axis: ScopeIREScale.legacyAxis, bins: 100), 0.995, accuracy: 1e-12)
    XCTAssertEqual(ScopeIREScale.fraction(ofLevel: -5, axis: ScopeIREScale.legacyAxis, bins: 100), 0.005, accuracy: 1e-12)
    XCTAssertEqual(ScopeIREScale.fraction(ofLevel: 0.5, axis: 1...1), 0, "an empty axis does not divide by zero")
  }

  /// Labels stay 5 pt inside the scope, as the app's did.
  func testLabelPositionsStayInside() {
    let scale = ScopeIREScale(axis: ScopeIREScale.legacyAxis)
    let size = CGSize(width: 300, height: 120)
    let points = scale.marks.map { ScopeIREScaleView.labelPosition($0, in: size) }
    XCTAssertEqual(points.first?.y, 115, "-10 at the bottom edge, kept inside")
    XCTAssertEqual(points.last?.y, 5, "110 at the top edge")
    XCTAssertEqual(points[1].y, 110, accuracy: 1e-9, "0 IRE at 110 / 120 of the height")
    XCTAssertTrue(points.allSatisfy { $0.x == 12 })
    let tiny = ScopeIREScaleView.labelPosition(scale.marks[0], in: CGSize(width: 10, height: 4))
    XCTAssertEqual(tiny.y, 5, "a tiny view does not invert the clamp")
  }
}

@MainActor
final class TileToolbarTests: XCTestCase {
  func testIsOnAndToggled() throws {
    var s = MonitorState()
    for tool in [MonitorTileTool.guides, .zebra, .falseColor, .focusPeaking, .clipIndicators, .magnify, .clean] {
      XCTAssertEqual(tool.isOn(in: s), false, "\(tool)")
      let on = try XCTUnwrap(tool.toggled(s, falseColorMode: .elZone, magnify: .zoom(4)))
      XCTAssertEqual(tool.isOn(in: on), true, "\(tool)")
      XCTAssertEqual(on, on.normalized())
      let off = try XCTUnwrap(tool.toggled(on))
      XCTAssertEqual(tool.isOn(in: off), false, "\(tool)")
      // Only that tool changed.
      var expected = s
      switch tool {
      case .guides: expected.guides.enabled = true
      case .zebra: expected.zebras[0].enabled = true
      case .falseColor: expected.falseColor.mode = .elZone
      case .focusPeaking: expected.focus.enabled = true
      case .clipIndicators: expected.clipIndicators.enabled = true
      case .magnify: expected.geometry.magnification.zoom = 4
      case .clean: expected.clean = true
      default: break
      }
      XCTAssertEqual(on, expected.normalized(), "\(tool)")
    }
    XCTAssertNil(MonitorTileTool.scopes.isOn(in: s))
    XCTAssertNil(MonitorTileTool.freeze.isOn(in: s))
    XCTAssertNil(MonitorTileTool.scopes.toggled(s))
    XCTAssertNil(MonitorTileTool.freeze.toggled(s))

    // Zebra: on is set 1; off turns both off.
    s.zebras[1].enabled = true
    XCTAssertEqual(MonitorTileTool.zebra.isOn(in: s), true)
    let zOff = try XCTUnwrap(MonitorTileTool.zebra.toggled(s))
    XCTAssertEqual(zOff.zebras.map(\.enabled), [false, false])
    // A host's state with fewer zebra sets is normalized first.
    var short = MonitorState()
    short.zebras = []
    XCTAssertEqual(MonitorTileTool.zebra.toggled(short)?.zebras.map(\.enabled), [true, false])
    // False colour on with `.off` falls back to six band; magnify on with `.fit` to 2×.
    XCTAssertEqual(MonitorTileTool.falseColor.toggled(MonitorState(), falseColorMode: .off)?.falseColor.mode, .sixBand)
    XCTAssertEqual(MonitorTileTool.magnify.toggled(MonitorState(), magnify: .fit)?.geometry.magnification.zoom, 2)
    // Magnify off returns to fit and keeps the navigator choice.
    var zoomed = MonitorState()
    zoomed.geometry.magnification.pixelExact = true
    zoomed.geometry.magnification.showsNavigator = false
    zoomed.geometry.magnification.centerX = 0.2
    let fit = try XCTUnwrap(MonitorTileTool.magnify.toggled(zoomed)).geometry.magnification
    XCTAssertFalse(fit.isActive)
    XCTAssertFalse(fit.showsNavigator)
    XCTAssertEqual(fit.centerX, 0.5)
  }

  func testSuggestedFalseColorMode() {
    func signal(_ curve: LogCurve, _ gamut: ColorGamut) -> SignalDescription {
      SignalDescription(encoding: .log(LogEncoding(curve: curve, gamut: gamut)))
    }
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: signal(.sLog3, .sGamut3Cine)), .sonySLog3)
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: signal(.sLog3, .sGamut3)), .sonySLog3)
    // Pattern 2 is native S-Log3 IRE, which the pass draws in any gamut.
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: signal(.sLog3, .rec709)), .sonySLog3)
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: signal(.sLog3, .rec2020)), .sonySLog3)
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: signal(.arriLogC3, .arriWideGamut3)), .arriLogC)
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: signal(.arriLogC4, .arriWideGamut4)), .arriLogC)
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: SignalDescription()), .sixBand)
    XCTAssertEqual(MonitorTileTool.suggestedFalseColorMode(for: nil), .sixBand)
  }

  /// The toolbar turns false colour and magnify back on as they were.
  func testMemoryRestoresWhatWasTurnedOff() {
    var memory = MonitorTileMemory()
    var s = MonitorState()
    let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
    memory.toggle(.falseColor, in: &s, signal: slog3)
    XCTAssertEqual(s.falseColor.mode, .sonySLog3, "first time: the signal's suggestion")
    memory.select(.elZone, in: &s)
    XCTAssertEqual(s.falseColor.mode, .elZone)
    memory.toggle(.falseColor, in: &s, signal: slog3)
    XCTAssertEqual(s.falseColor.mode, .off)
    memory.toggle(.falseColor, in: &s, signal: slog3)
    XCTAssertEqual(s.falseColor.mode, .elZone, "back to the mode turned off")
    memory.select(.off, in: &s)
    memory.toggle(.falseColor, in: &s, signal: nil)
    XCTAssertEqual(s.falseColor.mode, .elZone, "off from the menu keeps the remembered mode")

    s.geometry.magnification = MonitorMagnifyChoice.zoom(4).applied(to: s.geometry.magnification)
    memory.toggle(.magnify, in: &s, signal: nil)
    XCTAssertFalse(s.geometry.magnification.isActive)
    memory.toggle(.magnify, in: &s, signal: nil)
    XCTAssertEqual(MonitorMagnifyChoice(s.geometry.magnification), .zoom(4))
    s.geometry.magnification.pixelExact = true
    memory.toggle(.magnify, in: &s, signal: nil)
    memory.toggle(.magnify, in: &s, signal: nil)
    XCTAssertEqual(MonitorMagnifyChoice(s.geometry.magnification), .pixelExact)

    memory.toggle(.guides, in: &s, signal: nil)
    XCTAssertTrue(s.guides.enabled)
    let before = s
    memory.toggle(.scopes, in: &s, signal: nil)
    memory.toggle(.freeze, in: &s, signal: nil)
    XCTAssertEqual(s, before, "host tools never edit the state")
  }

  func testMagnifyChoices() {
    var m = Magnification()
    XCTAssertEqual(MonitorMagnifyChoice(m), .fit)
    m.zoom = 3
    XCTAssertEqual(MonitorMagnifyChoice(m), .zoom(3))
    m.pixelExact = true
    XCTAssertEqual(MonitorMagnifyChoice(m), .pixelExact)
    XCTAssertEqual(MonitorMagnifyChoice.choices(current: .zoom(2)), MonitorMagnifyChoice.standard)
    XCTAssertEqual(MonitorMagnifyChoice.choices(current: .zoom(3)).last, .zoom(3), "a pinch zoom is listed")
    XCTAssertEqual(MonitorMagnifyChoice.standard.map(\.title), ["Fit", "1:1", "2.0×", "4.0×", "8.0×"])
    XCTAssertEqual(MonitorMagnifyChoice.zoom(1000).applied(to: Magnification()).zoom, MonitorMagnifier.zoomRange.upperBound)
    XCTAssertEqual(MonitorMagnifyChoice.zoom(.nan).applied(to: Magnification()).zoom, 1)
    var centred = Magnification()
    centred.centerX = 0.3
    XCTAssertEqual(MonitorMagnifyChoice.zoom(2).applied(to: centred).centerX, 0.3, "a zoom keeps the centre")
    XCTAssertEqual(MonitorMagnifyChoice.fit.applied(to: centred).centerX, 0.5)
  }

  func testFreezeTitles() {
    XCTAssertEqual(MonitorFreezeState.allCases.map(\.actionTitle), ["Freeze", "Cancel Freeze", "Unfreeze"])
    XCTAssertEqual(MonitorFreezeState.allCases.map(\.accessibilityValue), ["Live", "Freeze pending", "Frozen"])
  }

  /// Regression: VoiceOver read "Frozen" (and the selected trait) while a
  /// freeze was only pending and the picture still live.
  func testFreezeAccessibilityFollowsThePicture() {
    let box = Box(MonitorState())
    func bar(_ f: MonitorFreezeState) -> MonitorTileToolbar<EmptyView> {
      MonitorTileToolbar(state: box.binding, freeze: f, onFreeze: {})
    }
    XCTAssertEqual(bar(.live).accessibilityValue(.freeze), "Live")
    XCTAssertEqual(bar(.pending).accessibilityValue(.freeze), "Freeze pending")
    XCTAssertEqual(bar(.frozen).accessibilityValue(.freeze), "Frozen")
    XCTAssertFalse(bar(.live).isSelected(.freeze))
    XCTAssertFalse(bar(.pending).isSelected(.freeze), "a pending freeze is not frozen")
    XCTAssertTrue(bar(.frozen).isSelected(.freeze))
    XCTAssertTrue(bar(.pending).isOn(.freeze), "the button still shows the pending freeze as engaged")
    XCTAssertEqual(bar(.live).accessibilityValue(.guides), "Off")
    box.value.guides.enabled = true
    XCTAssertEqual(bar(.live).accessibilityValue(.guides), "On")
    XCTAssertTrue(bar(.live).isSelected(.guides))
  }

  /// Regression: the collapsed menu reaches every tool's settings (the bar's
  /// chevrons are not on screen when it shows), and its Freeze item honours
  /// `unavailable` like the other items.
  func testCollapsedMenuReachesSettings() throws {
    let box = Box(MonitorState())
    let all: [MonitorTileTool] = MonitorTileTool.standard + [.clipIndicators, .clean]
    let plain = MonitorTileToolbar(state: box.binding, tools: all, onScopes: { _ in }, onFreeze: {})
    XCTAssertEqual(
      plain.settingsTools, [.guides, .zebra, .falseColor, .focusPeaking, .magnify, .clipIndicators],
      "no Scopes settings without content; Freeze and Clean have none")
    let withScopes = MonitorTileToolbar(state: box.binding, tools: all, onScopes: { _ in }, onFreeze: {}) {
      Text("Scope settings")
    }
    XCTAssertEqual(
      withScopes.settingsTools, [.guides, .zebra, .falseColor, .focusPeaking, .scopes, .magnify, .clipIndicators])

    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Sources/MonitorKitUI/SwiftUI/TileToolbar.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let menu = try XCTUnwrap(source.range(of: "private var menu: some View"))
    let items = try XCTUnwrap(source.range(of: "private func menuItem"))
    let menuBody = String(source[menu.upperBound..<items.lowerBound])
    XCTAssertTrue(menuBody.contains("Menu(\"Settings\")"), "a Settings submenu in the collapsed menu")
    XCTAssertTrue(menuBody.contains("ForEach(settingsTools)"))
    XCTAssertTrue(menuBody.contains("openFromMenu = true"))
    XCTAssertTrue(menuBody.contains(".popover("), "the popover hangs off the menu's button")
    let freezeItem = try XCTUnwrap(source.range(of: "Button(freeze.actionTitle) { toggle(.freeze) }"))
    let next = source[freezeItem.upperBound...].prefix(80)
    XCTAssertTrue(next.contains(".disabled(unavailable[tool] != nil)"), "the Freeze item is disabled when unavailable")
  }

  func testVisibleToolsNeedTheHost() {
    let all = MonitorTileTool.standard + [.guides, .clean]
    XCTAssertEqual(
      MonitorTileToolbar<EmptyView>.visibleTools(all, scopes: false, freeze: false),
      [.guides, .zebra, .falseColor, .focusPeaking, .magnify, .clean])
    XCTAssertEqual(
      MonitorTileToolbar<EmptyView>.visibleTools(all, scopes: true, freeze: true),
      [.guides, .zebra, .falseColor, .focusPeaking, .scopes, .magnify, .freeze, .clean])
    let box = Box(MonitorState())
    XCTAssertEqual(MonitorTileToolbar(state: box.binding).visible, [.guides, .zebra, .falseColor, .focusPeaking, .magnify])
    XCTAssertEqual(MonitorTileToolbar(state: box.binding, onScopes: { _ in }, onFreeze: {}).visible, MonitorTileTool.standard)
  }

  /// Scopes and Freeze go to the host; a tool the host disabled does nothing.
  func testCallbacksAndDisabledTools() {
    let box = Box(MonitorState())
    var scopes: [Bool] = []
    var freezes = 0
    let toolbar = MonitorTileToolbar(
      state: box.binding, name: "Program",
      unavailable: [.focusPeaking: "Focus peaking needs a camera's source picture.", .scopes: "No scopes here"],
      scopesEnabled: true, onScopes: { scopes.append($0) }, freeze: .pending, onFreeze: { freezes += 1 })
    toolbar.toggle(.freeze)
    XCTAssertEqual(freezes, 1)
    toolbar.toggle(.scopes)
    XCTAssertEqual(scopes, [], "disabled")
    toolbar.toggle(.focusPeaking)
    XCTAssertEqual(box.value, MonitorState(), "a disabled tool does not write")
    XCTAssertTrue(toolbar.isOn(.scopes))
    XCTAssertTrue(toolbar.isOn(.freeze))
    XCTAssertFalse(toolbar.isOn(.guides))

    let open = MonitorTileToolbar(state: box.binding, scopesEnabled: false, onScopes: { scopes.append($0) })
    open.toggle(.scopes)
    XCTAssertEqual(scopes, [true], "asks for the opposite of what it shows")
    XCTAssertFalse(open.hasSettings(.scopes), "no scope settings given")
    XCTAssertFalse(open.hasSettings(.freeze))
    XCTAssertFalse(open.hasSettings(.clean))
    XCTAssertTrue(open.hasSettings(.falseColor))
    let withSettings = MonitorTileToolbar(state: box.binding, onScopes: { _ in }) { Text("Scope settings") }
    XCTAssertTrue(withSettings.hasSettings(.scopes))
  }

  /// The surface status marks a tool that is on but not drawn.
  func testStatusReasons() {
    var state = MonitorState()
    state.falseColor.mode = .sonySLog3
    state.zebras[1].enabled = true
    var status = MonitorStatus()
    status.unavailable.append(.init(tool: .falseColor, reason: .requiresLogSource))
    status.unavailable.append(.init(tool: .zebra2, reason: .cleanFeed))
    let box = Box(state)
    let toolbar = MonitorTileToolbar(state: box.binding, status: status)
    XCTAssertEqual(toolbar.statusReason(.falseColor), .requiresLogSource)
    XCTAssertEqual(toolbar.statusReason(.zebra), .cleanFeed, "either zebra set")
    XCTAssertNil(toolbar.statusReason(.guides))
    XCTAssertNil(toolbar.statusReason(.scopes))
    XCTAssertNil(MonitorTileToolbar(state: box.binding).statusReason(.falseColor))
  }

  func testPlacementAppearance() {
    XCTAssertNil(MonitorTileToolbarPlacement.chrome.forcedColorScheme, "chrome follows the system appearance")
    XCTAssertEqual(MonitorTileToolbarPlacement.overPicture.forcedColorScheme, .dark)
  }

  /// Contract: in chrome the bar uses system materials and label colours, no
  /// fixed white or forced appearance (the over-picture capsule is the one
  /// deliberate dark backing).
  func testToolbarSourceUsesSystemAppearance() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Sources/MonitorKitUI/SwiftUI/TileToolbar.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(source.contains(".white"), "no fixed white foreground")
    XCTAssertEqual(source.components(separatedBy: "environment(\\.colorScheme").count - 1, 1, "only over the picture")
    XCTAssertEqual(source.components(separatedBy: "Color.black").count - 1, 1, "only over the picture")
    XCTAssertTrue(source.contains(".regularMaterial"))
  }
}

#if canImport(AppKit)
  /// The chrome views lay out in both appearances, wide and narrow.
  @MainActor
  final class ChromeHostingTests: XCTestCase {
    func host<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme) -> NSHostingView<some View> {
      let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: width))
      hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
      hosting.layoutSubtreeIfNeeded()
      return hosting
    }

    func testToolbarHostsInBothAppearances() {
      let box = Box(MonitorState())
      for scheme in [ColorScheme.light, .dark] {
        for placement in [MonitorTileToolbarPlacement.chrome, .overPicture] {
          let bar = MonitorTileToolbar(
            state: box.binding, name: "Camera 1", signal: SignalDescription(encoding: .log(.sLog3SGamut3Cine)),
            placement: placement, scopesEnabled: true, onScopes: { _ in }, freeze: .frozen, onFreeze: {})
          let wide = host(bar, width: 600, scheme: scheme)
          let narrow = host(bar, width: 60, scheme: scheme)
          XCTAssertEqual(wide.fittingSize.height, 28, "the bar's height")
          XCTAssertEqual(narrow.fittingSize.height, 28)
          // Unconstrained, the full bar is far wider than the 60 pt tile, which
          // therefore shows the one-button menu instead.
          let ideal = NSHostingView(rootView: bar.environment(\.colorScheme, scheme)).fittingSize
          XCTAssertGreaterThan(ideal.width, 200)
        }
      }
    }

    func testLegendAndScaleHostInBothAppearances() throws {
      let cine = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
      for mode in [FalseColorMode.sonySLog3, .elZone, .arriStyleSLog3] {
        var s = FalseColorSettings()
        s.mode = mode
        let legend = try XCTUnwrap(FalseColorLegend(settings: s, signal: cine))
        for scheme in [ColorScheme.light, .dark] {
          for width in [CGFloat(220), 900] {
            let captioned = host(FalseColorLegendView(legend: legend, style: .captioned), width: width, scheme: scheme)
            XCTAssertGreaterThan(captioned.fittingSize.height, 20)
            let list = host(FalseColorLegendView(legend: legend), width: width, scheme: scheme)
            XCTAssertGreaterThan(list.fittingSize.height, 20)
          }
        }
      }
      let scale = host(ScopeIREScaleView(scale: ScopeIREScale(axis: ScopeIREScale.legacyAxis)).frame(height: 120), width: 300, scheme: .light)
      XCTAssertEqual(scale.fittingSize.height, 120)
    }
  }
#endif
