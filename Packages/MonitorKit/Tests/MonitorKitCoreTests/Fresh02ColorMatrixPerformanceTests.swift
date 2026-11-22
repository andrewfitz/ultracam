// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import simd
import XCTest

@testable import MonitorKitCore

final class Fresh02ColorMatrixPerformanceTests: XCTestCase {
  @inline(never)
  private func oldSIMD(_ m: ColorMatrix) -> simd_double3x3 {
    simd_double3x3(rows: [SIMD3(m.red.r, m.red.g, m.red.b),
                        SIMD3(m.green.r, m.green.g, m.green.b),
                        SIMD3(m.blue.r, m.blue.g, m.blue.b)])
  }

  @inline(never)
  private func newSIMD(_ m: ColorMatrix) -> simd_double3x3 { m.simd }

  @inline(never)
  private func uncached(_ source: ColorGamut, _ target: ColorPrimaries) -> ColorMatrix {
    let s = source.chromaticities, t = target.chromaticities
    let sourceMatrix = ColorMatrix.normalizedPrimaryMatrix(red: s.red, green: s.green, blue: s.blue)
    let targetMatrix = ColorMatrix.normalizedPrimaryMatrix(red: t.red, green: t.green, blue: t.blue)
    return ColorMatrix(oldSIMD(targetMatrix).inverse * oldSIMD(sourceMatrix))
  }

  @inline(never)
  private func cached(_ source: ColorGamut, _ target: ColorPrimaries) -> ColorMatrix {
    source.conversion(to: target)
  }

  private let gamuts: [ColorGamut] = [.rec709, .rec2020, .sGamut3, .sGamut3Cine, .arriWideGamut3, .arriWideGamut4]

  private func assertBits(_ a: ColorMatrix, _ b: ColorMatrix, file: StaticString = #filePath, line: UInt = #line) {
    let ac = [a.red.r, a.red.g, a.red.b, a.green.r, a.green.g, a.green.b, a.blue.r, a.blue.g, a.blue.b]
    let bc = [b.red.r, b.red.g, b.red.b, b.green.r, b.green.g, b.green.b, b.blue.r, b.blue.g, b.blue.b]
    XCTAssertEqual(ac.map(\.bitPattern), bc.map(\.bitPattern), file: file, line: line)
  }

  func testFixedColumnsAndAllCachedMatricesPreservePreviousBits() {
    for source in gamuts {
      let c = source.chromaticities
      let matrix = ColorMatrix.normalizedPrimaryMatrix(red: c.red, green: c.green, blue: c.blue)
      assertBits(source.toXYZ, matrix)
      assertBits(ColorMatrix(newSIMD(matrix)), ColorMatrix(oldSIMD(matrix)))
      for target in ColorPrimaries.allCases {
        assertBits(source.conversion(to: target), uncached(source, target))
      }
    }
    for source in ColorPrimaries.allCases {
      let c = source.chromaticities
      let matrix = ColorMatrix.normalizedPrimaryMatrix(red: c.red, green: c.green, blue: c.blue)
      assertBits(source.toXYZ, matrix)
      assertBits(source.fromXYZ, ColorMatrix(oldSIMD(matrix).inverse))
      for target in ColorPrimaries.allCases {
        let t = target.chromaticities
        let tm = ColorMatrix.normalizedPrimaryMatrix(red: t.red, green: t.green, blue: t.blue)
        let old = source == target ? ColorMatrix.identity : ColorMatrix(oldSIMD(tm).inverse * oldSIMD(matrix))
        assertBits(source.conversion(to: target), old)
      }
    }
    // Non-gamut matrices also exercise the general mutable matrix adapter.
    let arbitrary = ColorMatrix(red: .init(r: 1, g: -2, b: 3), green: .init(r: 4, g: 5, b: -6),
                                blue: .init(r: -7, g: 8, b: 10))
    assertBits(ColorMatrix(newSIMD(arbitrary)), ColorMatrix(oldSIMD(arbitrary)))
    assertBits(arbitrary.inverse, ColorMatrix(oldSIMD(arbitrary).inverse))
  }

  func testOldAndNewColorMatrixMicrobenchmark() throws {
    guard ProcessInfo.processInfo.environment["MONITORKIT_FRESH02_BENCH"] == "1" else {
      throw XCTSkip("Set MONITORKIT_FRESH02_BENCH=1 for the old/new color matrix microbenchmark")
    }
    // Warm lazy immutable tables before measuring steady-state work. No timing
    // assertion: report ratios for the same machine/build, separate from GPU work.
    for source in gamuts { for target in ColorPrimaries.allCases { _ = cached(source, target) } }
    let targets = ColorPrimaries.allCases
    let count = 20_000
    var oldSum = 0.0, newSum = 0.0
    let startOld = ProcessInfo.processInfo.systemUptime
    var i = 0
    while i < count {
      oldSum += uncached(gamuts[i % 6], targets[(i / 6) % 3]).red.r
      i += 1
    }
    let oldTime = ProcessInfo.processInfo.systemUptime - startOld
    let startNew = ProcessInfo.processInfo.systemUptime
    i = 0
    while i < count {
      newSum += cached(gamuts[i % 6], targets[(i / 6) % 3]).red.r
      i += 1
    }
    let newTime = ProcessInfo.processInfo.systemUptime - startNew
    XCTAssertEqual(oldSum.bitPattern, newSum.bitPattern)
    print("BENCH Fresh02 gamut conversion old=\(oldTime / Double(count) * 1e9)ns cached=\(newTime / Double(count) * 1e9)ns ratio=\(oldTime / newTime)")

    let matrix = gamuts[3].toXYZ
    oldSum = 0
    newSum = 0
    let startOldAdapter = ProcessInfo.processInfo.systemUptime
    i = 0
    while i < count { oldSum += oldSIMD(matrix)[i % 3][(i / 3) % 3]; i += 1 }
    let oldAdapterTime = ProcessInfo.processInfo.systemUptime - startOldAdapter
    let startNewAdapter = ProcessInfo.processInfo.systemUptime
    i = 0
    while i < count { newSum += newSIMD(matrix)[i % 3][(i / 3) % 3]; i += 1 }
    let newAdapterTime = ProcessInfo.processInfo.systemUptime - startNewAdapter
    XCTAssertEqual(oldSum.bitPattern, newSum.bitPattern)
    print("BENCH Fresh02 SIMD adapter old=\(oldAdapterTime / Double(count) * 1e9)ns fixed=\(newAdapterTime / Double(count) * 1e9)ns ratio=\(oldAdapterTime / newAdapterTime)")
  }
}
