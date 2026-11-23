// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import MonitorKitUI

final class RegionBoundaryTests: XCTestCase {
  func testFullRegionAcceptsLargestIntegerDimensions() throws {
    let viewport = try XCTUnwrap(MonitorRegion.full.viewport(width: .max, height: .max))
    XCTAssertEqual(viewport.width, .max)
    XCTAssertEqual(viewport.height, .max)
    XCTAssertEqual(viewport.x, 0)
    XCTAssertEqual(viewport.y, 0)
  }

  func testRoundedTilesStillShareTheSameBoundary() throws {
    for width in [1, 101, Int.max] {
      let left = MonitorRegion(x: 0, y: 0, width: 0.5, height: 1).viewport(width: width, height: 3)
      let right = MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1).viewport(width: width, height: 3)
      if width == 1 {
        XCTAssertEqual(left?.width, 1)
        XCTAssertNil(right)
      } else {
        let a = try XCTUnwrap(left), b = try XCTUnwrap(right)
        XCTAssertEqual(a.width, b.x)
        XCTAssertEqual(a.width + b.width, width)
      }
    }
  }
}
