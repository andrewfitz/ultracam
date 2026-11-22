// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import MonitorKitCore

final class Fresh03ReferenceTests: XCTestCase {
  /// Independent full Method C path: eqs. (2)–(4), (5), (11)–(14).
  static func fullMethodC(_ rgb: ColorRGB, primaries: ColorPrimaries, alpha: Double) -> ColorRGB {
    let b = 1 - 2 * alpha
    let x = ColorMatrix(
      red: ColorRGB(r: b, g: alpha, b: alpha),
      green: ColorRGB(r: alpha, g: b, b: alpha),
      blue: ColorRGB(r: alpha, g: alpha, b: b))
    var m = primaries.toXYZ
    m.green = primaries.luminanceCoefficients
    let xyz = m.apply(x.apply(rgb))
    let sum = xyz.r + xyz.g + xyz.b
    guard xyz.g > 0, sum > 0 else { return ColorRGB(r: 0, g: 0, b: 0) }
    let cx = xyz.r / sum, cy = xyz.g / sum
    let ip = 100 * pow(0.8, 2.4) / 0.83802
    let y = xyz.g < ip ? 0.83802 * xyz.g : 15.09968 * log(xyz.g / ip - 0.74204) + 78.99439
    return x.inverse.apply(m.inverse.apply(ColorRGB(r: cx / cy * y, g: y, b: (1 - cx - cy) / cy * y)))
  }

  func testMethodCScalarMatchesIndependentFullSpecification() {
    for primaries in [ColorPrimaries.rec709, .rec2020, .displayP3] {
      for alpha in [0.0, 0.1, 0.33] {
        for i in 0..<200 {
          let rgb = ColorRGB(r: Double(i * 17 % 1001), g: Double(i * 41 % 1001), b: Double(i * 73 % 1001))
          let expected = Self.fullMethodC(rgb, primaries: primaries, alpha: alpha)
          let actual = BT2446MethodC.toneMap(rgb, primaries: primaries, crosstalk: alpha)
          XCTAssertEqual(actual.r, expected.r, accuracy: 1e-9 * max(1, abs(expected.r)))
          XCTAssertEqual(actual.g, expected.g, accuracy: 1e-9 * max(1, abs(expected.g)))
          XCTAssertEqual(actual.b, expected.b, accuracy: 1e-9 * max(1, abs(expected.b)))
        }
      }
    }
  }

  func testExtremeCompressionIsMonotoneAndStaysWithinTarget() {
    for target in [0.0, 0.01, 1.0, 5.0, 10.0] {
      let curve = ToneMapEETF(sourcePeak: 10_000, targetPeak: target)
      var previous = 0.0
      for i in 0...1000 {
        let output = curve.normalized(Double(i) / 1000)
        XCTAssertGreaterThanOrEqual(output, previous - 1e-15)
        XCTAssertLessThanOrEqual(output, curve.maxLum + 1e-15)
        previous = output
      }
      XCTAssertEqual(curve.normalized(0), 0)
      XCTAssertEqual(curve.normalized(1), curve.maxLum)
    }
  }

  func testOrdinaryCompressionRetainsOriginalHermiteEvaluation() {
    for target in [100.0, 203.0, 400.0, 999.0] {
      let curve = ToneMapEETF(sourcePeak: 1000, targetPeak: target)
      for i in 0...1000 {
        let e = Double(i) / 1000
        let t = (min(e, 1) - curve.kneeStart) / (1 - curve.kneeStart), t2 = t * t, t3 = t2 * t
        let expected = e < curve.kneeStart ? e :
          (2 * t3 - 3 * t2 + 1) * curve.kneeStart + (t3 - 2 * t2 + t) * (1 - curve.kneeStart)
          + (-2 * t3 + 3 * t2) * curve.maxLum
        XCTAssertEqual(curve.normalized(e), expected)
      }
    }
  }
}

final class Fresh03MethodCBenchmarks: XCTestCase {
  private func benchmark(fullSpecification: Bool) {
    var checksum = 0.0
    measure {
      var i = 0
      while i < 10_000 {
        let rgb = ColorRGB(r: Double(i % 1000), g: 203, b: 75)
        let result = fullSpecification
          ? Fresh03ReferenceTests.fullMethodC(rgb, primaries: .rec2020, alpha: 0)
          : BT2446MethodC.toneMap(rgb, primaries: .rec2020)
        checksum += result.r
        i += 1
      }
    }
    XCTAssertGreaterThan(checksum, 0)
  }

  func testFullSpecificationBaseline() { benchmark(fullSpecification: true) }
  func testScalarImplementation() { benchmark(fullSpecification: false) }
}
