// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import MonitorKitCore

final class CoreReferenceBoundaryRegressionTests: XCTestCase {
  func testConstantBT1886DisplayHasFiniteConstantLuminance() {
    for luminance in [0.0, 0.1, 100.0] {
      for signal in [-1.0, 0, 0.5, 1, 2] {
        XCTAssertEqual(
          ColorMath.bt1886EOTF(signal, black: luminance, white: luminance),
          luminance, accuracy: 1e-10)
      }
    }
  }

  func testBT1886RetainsBlackWhiteAndInteriorLuminance() {
    let black = 0.1, white = 100.0
    XCTAssertEqual(ColorMath.bt1886EOTF(0, black: black, white: white), black, accuracy: 1e-12)
    XCTAssertEqual(ColorMath.bt1886EOTF(1, black: black, white: white), white, accuracy: 1e-10)
    let w = pow(white, 1 / 2.4), k = pow(black, 1 / 2.4)
    let a = pow(w - k, 2.4), b = k / (w - k)
    XCTAssertEqual(ColorMath.bt1886EOTF(0.5, black: black, white: white), a * pow(0.5 + b, 2.4), accuracy: 1e-12)
  }

  func testTintAtOutOfDomainTemperatureUsesClampedLocusNormal() {
    for (temperature, endpoint) in [(-1000.0, 4000.0), (0, 4000), (3000, 4000), (30_000, 25_000)] {
      for tint in [-0.02, 0.02] {
        let actual = WhitePointTrim.white(temperature: temperature, tint: tint)
        let expected = WhitePointTrim.white(temperature: endpoint, tint: tint)
        XCTAssertTrue(actual.x.isFinite)
        XCTAssertTrue(actual.y.isFinite)
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12)
      }
    }
  }
}
