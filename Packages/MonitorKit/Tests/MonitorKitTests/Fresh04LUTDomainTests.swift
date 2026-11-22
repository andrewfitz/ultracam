// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKit
import XCTest

extension LUTTests {
  private func fresh04IdentityCube(span: Float, narrowChannel: Int? = nil) throws -> CubeLUT {
    var high = SIMD3<Float>(repeating: span)
    if let narrowChannel {
      high = SIMD3(repeating: 1)
      high[narrowChannel] = span
    }
    var text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX \(high.x) \(high.y) \(high.z)\n"
    for b in 0..<2 {
      for g in 0..<2 {
        for r in 0..<2 { text += "\(r) \(g) \(b)\n" }
      }
    }
    return try CubeLUT(text: text)
  }

  func testFresh04GPURejectsDomainsWhoseDenormalsWouldChangeSampling() throws {
    let gpu = try requireGPU()
    let minimumSpan = Float.leastNormalMagnitude / Float.ulpOfOne
    // Include normal spans: rejecting only subnormal spans leaves ordinary
    // quarter-domain coordinates subject to catastrophic flushing as well.
    for span in [Float(1e-38), Float(1e-37), minimumSpan.nextDown] {
      for channel in 0..<3 {
        let cube = try fresh04IdentityCube(span: span, narrowChannel: channel)
        for mode in LUTInterpolation.allCases {
          XCTAssertThrowsError(try MonitorLUT(device: gpu.device, cube: cube, interpolation: mode))
        }
      }
      let shaper = try CubeLUT(text: "LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0 \(span)\n0 0 0\n1 1 1\n")
      XCTAssertThrowsError(try MonitorLUT(device: gpu.device, cube: shaper))
      // Parsing and CPU evaluation remain valid independently of Metal.
      XCTAssertEqual(shaper.apply(SIMD3(repeating: span * 0.5)).x, 0.5, accuracy: 2e-6)
    }
  }

  func testFresh04SmallestSupportedDomainMatchesCPU() throws {
    let gpu = try requireGPU()
    let span = Float.leastNormalMagnitude / Float.ulpOfOne
    let cube = try fresh04IdentityCube(span: span)
    let shaper = try CubeLUT(text: "LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0 \(span)\n0 0 0\n1 1 1\n")
    let inputs: [SIMD3<Float>] = [
      .zero, SIMD3(repeating: span), SIMD3(repeating: span * 0.5),
      SIMD3(Float.leastNormalMagnitude.nextDown, span * 0.25, span * 0.75),
    ]
    for table in [cube, shaper] {
      for mode in [LUTInterpolation.tetrahedral, .trilinear] {
        let lut = try MonitorLUT(device: gpu.device, cube: table, interpolation: mode)
        for (input, output) in zip(inputs, try gpuApply(lut, inputs)) {
          let expected = table.apply(input, interpolation: mode)
          for c in 0..<3 { XCTAssertEqual(output[c], expected[c], accuracy: 2e-6) }
        }
      }
    }
  }
}
