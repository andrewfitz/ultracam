// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest
import simd

@testable import MonitorKit

/// The literal ARRI tables' red zone is open-ended upward and purple downward
/// (MATH.md 4.2). Read literally as `< Bzu` with Bzu = A' = 1.0, the most clipped
/// codes (full 1023, legal 940 and super-whites) fell back to grey instead of red;
/// with purple's floor at legal 64, sub-blacks fell back to grey instead of purple.
final class Audit3ARRIRedTests: XCTestCase {
  /// One neutral pixel per 10-bit code, 0…1023, through `layout`.
  func sweep(
    _ curve: LogCurve, range: CodeRange, transport: LogTransport = .native, layout: PixelLayout = .v210
  ) throws -> Pixels {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(layout, width: 1024, height: 2) { x, _ in x }
    let encoding = SignalEncoding.log(LogEncoding(curve: curve, gamut: .rec2020, transport: transport))
    let frame = try picture.frame(gpu, signal: SignalDescription(range: range, matrix: .bt709, encoding: encoding))
    var state = MonitorState()
    state.falseColor.mode = .arriLogC
    return try gpu.render(frame, state: state, pass: gpu.engine.makePass())
  }

  func testClippedTopCodesRenderRedInEveryARRITable() throws {
    let red: SIMD3<Float> = SIMD3(1, 0, 0)
    for curve in [LogCurve.arriLogC3, .arriLogC4] {
      for layout in [PixelLayout.v210, .p010, .rgb10a2] {
        let full = try sweep(curve, range: .full, layout: layout)
        XCTAssertEqual(full.rgb(1023, 0), red, "\(curve) \(layout) full 1023")

        let legal = try sweep(curve, range: .legal, layout: layout)
        let legalCodes: [Int] = [940, 1019]
        for code in legalCodes {
          XCTAssertEqual(legal.rgb(code, 0), red, "\(curve) \(layout) legal \(code)")
        }

        // Full-range camera codes squeezed into legal: 940 is native 1023, above it super-white.
        let rescaled = try sweep(curve, range: .legal, transport: .fullRescaledToLegal, layout: layout)
        for code in legalCodes {
          XCTAssertEqual(rescaled.rgb(code, 0), red, "\(curve) \(layout) rescaled legal \(code)")
        }
      }
    }
  }

  func testSubBlackCodesRenderPurpleInEveryARRITable() throws {
    let purple = SIMD3<Float>(ARRIFalseColorCategory.purple.color)
    for curve in [LogCurve.arriLogC3, .arriLogC4] {
      for layout in [PixelLayout.v210, .p010, .rgb10a2] {
        let full = try sweep(curve, range: .full, layout: layout)
        XCTAssertEqual(full.rgb(0, 0), purple, "\(curve) \(layout) full 0")

        // Legal sub-blacks: below 64, and in the rescaled transport below native 0.
        let legalCodes: [Int] = [4, 40, 64]
        let legal = try sweep(curve, range: .legal, layout: layout)
        let rescaled = try sweep(curve, range: .legal, transport: .fullRescaledToLegal, layout: layout)
        for code in legalCodes {
          XCTAssertEqual(legal.rgb(code, 0), purple, "\(curve) \(layout) legal \(code)")
          XCTAssertEqual(rescaled.rgb(code, 0), purple, "\(curve) \(layout) rescaled legal \(code)")
        }
      }
    }
  }
}
