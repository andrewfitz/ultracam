// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import MonitorKitCore

final class CoreColorOverflowAuditTests: XCTestCase {
  func testFiniteInputsCannotReturnNonfiniteOptionalColorValues() {
    let huge = Double.greatestFiniteMagnitude
    for range in [CodeRange.full, .legal] {
      for sign in [1.0, -1.0] {
        XCTAssertNil(range.lumaCode(normalized: sign * huge, bitDepth: 10))
      }
    }
    for matrix in [YCbCrMatrix.bt601, .bt709, .bt2020, .smpte240m] {
      XCTAssertNil(ColorMath.yCbCrToRGB(y: huge, cb: huge, cr: huge, matrix: matrix))
    }
    // Wide-gamut Y rows contain negative blue coefficients, so even finite RGB
    // can overflow when positive red/green and negative blue reinforce each other.
    let rgb = ColorRGB(r: huge, g: huge, b: -huge)
    for gamut in [ColorGamut.sGamut3, .sGamut3Cine, .arriWideGamut3, .arriWideGamut4] {
      XCTAssertNil(ColorMath.linearLuminance(rgb, gamut: gamut))
    }
  }
}
