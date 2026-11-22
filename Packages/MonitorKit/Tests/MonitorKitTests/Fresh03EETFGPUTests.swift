// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class Fresh03EETFGPUTests: XCTestCase {
  func testExtremeCompressionRampAndOrdinaryBitPreservation() throws {
    let gpu = try requireGPU()
    let kernel = """
      float fresh03_baseline(float e1, float4 t) {
        if (t.w != 0 || e1 < t.z) return e1;
        if (t.z >= 1) return t.y;
        float x = mk_div(min(e1, 1.0f) - t.z, 1 - t.z), x2 = x * x, x3 = x2 * x;
        return (2 * x3 - 3 * x2 + 1) * t.z + (x3 - 2 * x2 + x) * (1 - t.z) + (-2 * x3 + 3 * x2) * t.y;
      }
      kernel void fresh03_eetf(device const float* input [[buffer(0)]],
                              constant float4& tone [[buffer(1)]],
                              device float2* output [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        output[i] = float2(mk_eetf(input[i], tone), fresh03_baseline(input[i], tone));
      }
      """
    let library = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode, .monitor], extra: kernel)
    let pipeline = try gpu.device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "fresh03_eetf")))
    let values = (0...4096).map { Float($0) / 4096 }
    let input = gpu.buffer(values), output = gpu.buffer(length: values.count * MemoryLayout<SIMD2<Float>>.stride)
    for target in [0.01, 1.0, 5.0, 10.0, 100.0, 203.0, 400.0, 9999.0] {
      let curve = ToneMapEETF(sourcePeak: 10_000, targetPeak: target)
      let tone = gpu.buffer([SIMD4<Float>(Float(curve.sourceSignal), Float(curve.maxLum), Float(curve.kneeStart), curve.isIdentity ? 1 : 0)])
      gpu.run { cb in
        let encoder = cb.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(tone, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: values.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding()
      }
      let result = UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD2<Float>.self), count: values.count)
      var previous: Float = 0
      for i in values.indices {
        let actual = result[i].x
        XCTAssertTrue(actual.isFinite)
        XCTAssertEqual(Double(actual), curve.normalized(Double(values[i])), accuracy: 1e-5)
        XCTAssertGreaterThanOrEqual(actual, previous - 2e-7)
        XCTAssertLessThanOrEqual(actual, Float(curve.maxLum) + 2e-7)
        if curve.maxLum >= 1.0 / 3 {
          XCTAssertEqual(actual.bitPattern, result[i].y.bitPattern)
        }
        previous = actual
      }
    }
  }
}
