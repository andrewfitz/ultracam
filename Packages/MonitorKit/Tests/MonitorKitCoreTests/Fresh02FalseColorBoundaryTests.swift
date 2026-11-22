// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import MonitorKitCore

final class Fresh02FalseColorBoundaryTests: XCTestCase {
  func testNormalizedNeutralRGBHonorsEveryARRITableBoundary() throws {
    // ARRI False Color specification 2025-02-04 eqs. (1)/(2), Tables 9/25.
    // Exercise the RGB entry point, not just the direct code classifier.
    for profile in ARRIFalseColorProfile.allCases {
      for range in [CodeRange.legal, .full] {
        for zone in profile.zones(range: range) {
          // Red is open-ended upward and purple downward (MATH.md 4.2): they have no
          // outer edge to cross. Red's top sample is code 1023 (super-white in legal),
          // purple's bottom a negative value (sub-black, or below zero in float).
          let lower = range.normalizeLuma(code: zone.lower, bitDepth: 10) ?? -.infinity
          let upper = range.normalizeLuma(code: zone.upper, bitDepth: 10) ?? .infinity
          XCTAssertEqual(lower.isFinite, zone.category != .purple)
          XCTAssertEqual(upper.isFinite, zone.category != .red)
          let bottom = lower.isFinite ? lower : -0.1
          let top = try XCTUnwrap(upper.isFinite ? upper.nextDown : range.normalizeLuma(code: 1023, bitDepth: 10))
          for value in [bottom, top] {
            let neutral = ColorRGB(r: value, g: value, b: value)
            XCTAssertEqual(profile.color(rgb: neutral, range: range), zone.category.color,
                           "\(profile) \(range) \(zone.category) at \(value)")
          }
          for value in [lower.nextDown, upper] where value.isFinite {
            let neutral = ColorRGB(r: value, g: value, b: value)
            XCTAssertNotEqual(profile.color(rgb: neutral, range: range), zone.category.color,
                              "\(profile) \(range) \(zone.category) at \(value)")
          }
        }
      }
    }
  }

  func testNeutralARRIFallbackRetainsExactInputOutsideTables() {
    // Between zones is the exact input as grey. Below the tables is crushed, so
    // purple; A' = 1.0 and above is clipped, so red (MATH.md 4.2).
    for profile in ARRIFalseColorProfile.allCases {
      for range in [CodeRange.legal, .full] {
        let gap = ColorRGB(r: 0.6, g: 0.6, b: 0.6)
        XCTAssertEqual(profile.color(rgb: gap, range: range), gap)
        let below = ColorRGB(r: -0.1, g: -0.1, b: -0.1)
        XCTAssertEqual(profile.color(rgb: below, range: range), ARRIFalseColorCategory.purple.color)
        for value in [1.0, 1.1] {
          let neutral = ColorRGB(r: value, g: value, b: value)
          XCTAssertEqual(profile.color(rgb: neutral, range: range), ARRIFalseColorCategory.red.color)
        }
      }
    }
  }
}
