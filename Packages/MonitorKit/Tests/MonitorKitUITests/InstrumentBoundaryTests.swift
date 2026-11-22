// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitCore
import XCTest

@testable import MonitorKitUI

final class InstrumentBoundaryTests: XCTestCase {
  func testReadoutCacheAcceptsExtremeValuesAndDistinguishesNonfiniteInputs() {
    var calls = 0
    let text = ReadoutText { value in
      calls += 1
      return String(value)
    }
    XCTAssertEqual(text(.greatestFiniteMagnitude), String(Double.greatestFiniteMagnitude))
    XCTAssertEqual(text(-.greatestFiniteMagnitude), String(-Double.greatestFiniteMagnitude))
    XCTAssertEqual(text(.infinity), "inf")
    XCTAssertEqual(text(-.infinity), "-inf")
    XCTAssertEqual(text(.nan), "nan")
    _ = text(.nan)
    XCTAssertEqual(calls, 5)
  }

  func testRelativeLoudnessRejectsNonfiniteTargetAndOverflow() {
    XCTAssertEqual(LoudnessReadout.text(-23, unit: .lu, target: .nan), "—")
    XCTAssertEqual(LoudnessReadout.text(-23, unit: .lu, target: .infinity), "—")
    XCTAssertEqual(LoudnessReadout.text(.greatestFiniteMagnitude, unit: .lu, target: -.greatestFiniteMagnitude), "—")
  }

  func testMagnifierIgnoresNonfiniteGesturePositions() {
    var m = Magnification()
    m.zoom = 4
    let layout = MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 960, viewportHeight: 540,
      geometry: ViewGeometry())
    for value in [Double.nan, .infinity, -.infinity] {
      for point in [(x: value, y: 100.0), (x: 100.0, y: value)] {
        XCTAssertEqual(MonitorMagnifier.zoom(m, by: 2, about: point, layout: layout), m)
        XCTAssertEqual(MonitorMagnifier.togglePixelExact(m, at: point, layout: layout), m)
      }
    }
  }
}
