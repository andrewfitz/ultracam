// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest

@testable import MonitorKit

final class PictureShaderLaneAuditTests: XCTestCase {
  /// The picture pass's optimized v210 extraction must match the standalone
  /// decoder, including partial groups and the row's final chroma pair.
  func testOptimizedV210LanesAndRowCacheMatchGenericDecodeAtEveryTail() throws {
    let gpu = try requireGPU()
    let source = """
      kernel void audit_v210(texture2d<uint, access::read> packed [[texture(0)]],
                             constant mk_FrameParams& f [[buffer(0)]],
                             device uint4* result [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= f.shape.y || p.y >= f.shape.z) return;
        uint index = (p.y * f.shape.y + p.x) * 3;
        float3 expected = mk_v210Codes(packed, p, f);
        result[index] = uint4(as_type<uint3>(expected), 0);
        result[index + 1] = uint4(as_type<uint3>(mk_v210PixelCodes(packed, p, f)), 0);
        // Walk from column zero to exercise advance across every group boundary.
        mk_V210Row row = mk_v210Row(packed, 0, p.y, f);
        float3 cached = mk_v210RowCodes(row, p.x, packed, f);
        result[index + 2] = uint4(as_type<uint3>(float3(expected.x, expected.yz - f.levels.z)), 0)
                             ^ uint4(as_type<uint3>(cached), 0);
      }
      """
    let library = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode, .monitor], extra: source)
    let pipeline = try gpu.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "audit_v210")))
    for width in 1...67 {
      let height = 3
      let frame = try SyntheticFrame.random(.v210, width: width, height: height, seed: UInt64(width)).frame(gpu, signal: SignalDescription())
      let result = gpu.buffer(length: width * height * 3 * MemoryLayout<SIMD4<UInt32>>.stride)
      gpu.run { command in
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frame.packed, index: 0)
        var parameters = frame.parameters
        encoder.setBytes(&parameters, length: MemoryLayout<FrameParameters>.stride, index: 0)
        encoder.setBuffer(result, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
        encoder.endEncoding()
      }
      let values = result.contents().assumingMemoryBound(to: SIMD4<UInt32>.self)
      for pixel in 0..<(width * height) {
        XCTAssertEqual(values[pixel * 3], values[pixel * 3 + 1], "width \(width), pixel \(pixel)")
        XCTAssertEqual(values[pixel * 3 + 2], .zero, "cached width \(width), pixel \(pixel)")
      }
    }
  }
}
