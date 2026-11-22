// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import MonitorKitCore

final class Fresh01BandSerializationTests: XCTestCase {
  private let color = ColorRGB(r: 1, g: 0, b: 0)

  func testOnlyOutwardInfinityEdgesAreOmitted() throws {
    let bands = [
      FalseColorBand(lower: -.infinity, upper: 0, color: color),
      FalseColorBand(lower: 1, upper: .infinity, color: color),
      FalseColorBand(lower: -.infinity, upper: .infinity, color: color),
    ]
    let data = try JSONEncoder().encode(bands)
    XCTAssertEqual(try JSONDecoder().decode([FalseColorBand].self, from: data), bands)
  }

  func testInvalidNonfiniteEdgesCannotSilentlyBecomeOpenEnds() {
    let bands = [
      FalseColorBand(lower: .infinity, upper: .infinity, color: color),
      FalseColorBand(lower: -.infinity, upper: -.infinity, color: color),
      FalseColorBand(lower: .nan, upper: 1, color: color),
      FalseColorBand(lower: 0, upper: .nan, color: color),
    ]
    for band in bands {
      XCTAssertThrowsError(try JSONEncoder().encode(band))
    }
  }

  func testNormalizationRemovesEmptyAndReversedBandsBeforeApplyingLimit() throws {
    let valid = FalseColorBand(lower: -.infinity, upper: .infinity, color: color)
    var state = MonitorState()
    state.falseColor.customBands = Array(
      repeating: FalseColorBand(lower: 1, upper: 0, color: color), count: 16)
    state.falseColor.customBands += [
      FalseColorBand(lower: .infinity, upper: .infinity, color: color),
      FalseColorBand(lower: -.infinity, upper: -.infinity, color: color),
      FalseColorBand(lower: 1, upper: 1, color: color),
      valid,
    ]
    let normalized = state.normalized()
    XCTAssertEqual(normalized.falseColor.customBands, [valid])
    let data = try JSONEncoder().encode(normalized)
    XCTAssertEqual(try JSONDecoder().decode(MonitorState.self, from: data), normalized)
  }
}
