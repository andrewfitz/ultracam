// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import MonitorKitCore

final class Audit3CoreTests: XCTestCase {
  /// JSON has no NaN or infinity: before, one non-finite field made the whole
  /// encode throw, so a host lost every setting it persists next to the state.
  /// The state is written normalized, which is what decoding produces anyway.
  func testNonFiniteStateFieldsEncodeAsTheirNormalizedValues() throws {
    var s = MonitorState()
    s.zebras[0].level = .nan
    s.zebras[1].opacity = .infinity
    s.falseColor.referenceOffsetStops = -.infinity
    s.falseColor.customBands = [
      FalseColorBand(lower: .nan, upper: 1, color: ColorRGB(r: 1, g: 0, b: 0)),
      FalseColorBand(lower: 0, upper: .infinity, color: ColorRGB(r: 0, g: 1, b: 0)),
    ]
    s.focus.sensitivity = .nan
    s.guides.frameGuides = [FrameGuide(aspect: .infinity), FrameGuide(aspect: 2.39, matteOpacity: .nan)]
    s.guides.safeAreas = [.nan, 90]
    s.guides.color = ColorRGB(r: .nan, g: 1, b: 1)
    s.guides.lineWidth = .infinity
    s.geometry.desqueeze = .nan
    s.geometry.magnification.centerX = .infinity
    s.display.temperature = .nan
    s.displayTransform.pqSourcePeak = .infinity
    s.clipIndicators.overColor = ColorRGB(r: 1, g: .infinity, b: 0)
    s.clipIndicators.high = .nan

    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(MonitorState.self, from: data)
    XCTAssertEqual(decoded, s.normalized())
    XCTAssertEqual(decoded.falseColor.customBands.count, 1)
    XCTAssertEqual(decoded.guides.frameGuides, [FrameGuide(aspect: 2.39, matteOpacity: 0.6)])

    // Embedded in a host type, the host's other settings are written too.
    struct Preferences: Codable, Equatable {
      var name: String
      @LenientMonitorState var monitor: MonitorState
    }
    var prefs = Preferences(name: "A", monitor: LenientMonitorState())
    prefs.monitor = s
    let back = try JSONDecoder().decode(Preferences.self, from: try JSONEncoder().encode(prefs))
    XCTAssertEqual(back.name, "A")
    XCTAssertEqual(back.monitor, s.normalized())
  }

  /// A finite state already in range is written exactly as it is.
  func testInRangeStateEncodesUnchanged() throws {
    var s = MonitorState()
    s.zebras[0] = ZebraSet(mode: .band, level: 55, range: 3)
    s.falseColor.mode = .custom
    s.falseColor.customBands = SixBandFalseColor.bands
    s.guides.enabled = true
    s.guides.safeAreas = [80, 93]
    s.display.tint = 0.01
    XCTAssertEqual(s, s.normalized())
    XCTAssertEqual(try JSONDecoder().decode(MonitorState.self, from: try JSONEncoder().encode(s)), s)
  }

  /// The same for the output colour a host persists per surface.
  func testNonFiniteOutputColorEncodesAsItsNormalizedValues() throws {
    let o = MonitorOutputColor(
      primaries: .displayP3, encoding: .pq, referenceWhite: .nan, hlgNominalPeak: .infinity, headroom: -.infinity)
    let decoded = try JSONDecoder().decode(MonitorOutputColor.self, from: try JSONEncoder().encode(o))
    XCTAssertEqual(decoded, o.normalized())
    XCTAssertEqual(decoded.primaries, .displayP3)
    XCTAssertEqual(decoded.encoding, .pq)
    XCTAssertEqual(decoded.referenceWhite, 203)

    let sdr = MonitorOutputColor(primaries: .rec2020, encoding: .sdr(.gamma22), referenceWhite: 100, headroom: 4)
    XCTAssertEqual(try JSONDecoder().decode(MonitorOutputColor.self, from: try JSONEncoder().encode(sdr)), sdr)
  }
}
