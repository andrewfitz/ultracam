// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKit
import XCTest

extension LUTTests {
  func testAuditExtremeFiniteInputsAndAsymmetricDomainsMatchGPU() throws {
    let gpu = try requireGPU()
    var text = "LUT_3D_SIZE 2\nDOMAIN_MIN -1e37 -2 -0.5\nDOMAIN_MAX 1e37 3 0.5\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
    let cube = try CubeLUT(text: text)
    let inputs: [SIMD3<Float>] = [
      SIMD3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude),
      SIMD3(repeating: Float.greatestFiniteMagnitude),
      SIMD3(0, 0.5, 0), SIMD3(-1e37, 3, -0.5), SIMD3(1e37, -2, 0.5),
    ]
    for mode in [LUTInterpolation.tetrahedral, .trilinear] {
      let lut = try MonitorLUT(device: gpu.device, cube: cube, interpolation: mode)
      for (input, output) in zip(inputs, try gpuApply(lut, inputs)) {
        let expected = cube.apply(input, interpolation: mode)
        for channel in 0..<3 {
          XCTAssertEqual(output[channel], expected[channel], accuracy: 2e-6, "\(mode), \(input)")
        }
      }
    }
  }
}
