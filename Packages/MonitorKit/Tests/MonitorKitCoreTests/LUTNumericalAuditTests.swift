// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitCore
import XCTest

final class LUTNumericalAuditTests: XCTestCase {
  func testUnrepresentableDomainReciprocalIsRejectedBeforeSampling() {
    let text = "LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0 1e-40\n0 0 0\n1 1 1\n"
    XCTAssertThrowsError(try CubeLUT(text: text))
  }

  func testExtremeFiniteShaperValuesInterpolateWithoutOverflow() throws {
    let lut = try CubeLUT(text: "LUT_1D_SIZE 2\n-1e37 1e37 -1e37\n1e37 -1e37 1e37\n")
    XCTAssertEqual(lut.apply(SIMD3(repeating: 0.5)), .zero)
    XCTAssertEqual(lut.apply(SIMD3(-Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, 0)),
                   SIMD3(-1e37, -1e37, -1e37))
  }

  func testBOMCommentsAndCRLFDoNotChangeTableOrQuotedTitle() throws {
    let lut = try CubeLUT(text: "\u{FEFF}TITLE \"Look #1\" # comment\r\nLUT_1D_SIZE 2\r\n0 0 0 # black\r\n1 1 1\r\n")
    XCTAssertEqual(lut.title, "Look #1")
    XCTAssertEqual(lut.apply(SIMD3(0.25, 0.5, 0.75)), SIMD3(0.25, 0.5, 0.75))
  }
}
