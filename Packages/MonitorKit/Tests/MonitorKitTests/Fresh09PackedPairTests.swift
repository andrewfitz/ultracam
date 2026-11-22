// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class Fresh09PackedPairTests: XCTestCase {
  /// Pair averaging must include the odd pixel's next chroma site, clamp the
  /// final site, and advance cached groups correctly on every partial-group tail.
  func testV210PairOptimizationsEqualIndependentPixelMeans() throws {
    let gpu = try requireGPU()
    let source = """
      kernel void fresh09_pairs(texture2d<uint, access::read> packed [[texture(0)]],
                                 constant mk_FrameParams& f [[buffer(0)]],
                                 device float4* result [[buffer(1)]], uint pair [[thread_position_in_grid]]) {
        uint x = pair * 2;
        if (x + 1 >= f.shape.y) return;
        uint2 p = uint2(x, 0);
        float3 expected = (mk_v210Codes(packed, p, f) + mk_v210Codes(packed, p + uint2(1, 0), f)) * .5f;
        float3 standalone = mk_v210PairCodes(packed, p, f);
        float3 picture = mk_v210PixelPairCodes(packed, p, f);
        mk_V210Row row = mk_v210Row(packed, 0, 0, f);
        float3 cached = mk_v210RowPairCodes(row, x, packed, f);
        cached.yz += f.levels.z;
        result[pair] = float4(max(max(abs(expected - standalone), abs(expected - picture)), abs(expected - cached)), 0);
      }
      """
    let library = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode, .monitor], extra: source)
    let pipeline = try gpu.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "fresh09_pairs")))
    for width in 2...67 {
      let frame = try SyntheticFrame.random(.v210, width: width, height: 1, seed: UInt64(width)).frame(
        gpu, signal: SignalDescription())
      let count = width / 2
      let result = gpu.buffer(length: count * MemoryLayout<SIMD4<Float>>.stride)
      gpu.run { command in
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frame.packed, index: 0)
        var parameters = frame.parameters
        encoder.setBytes(&parameters, length: MemoryLayout<FrameParameters>.stride, index: 0)
        encoder.setBuffer(result, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
        encoder.endEncoding()
      }
      let values = result.contents().assumingMemoryBound(to: SIMD4<Float>.self)
      for pair in 0..<count {
        XCTAssertEqual(values[pair], .zero, "width \(width), pair \(pair)")
      }
    }
  }
}
