import Metal
import MonitorKitCore
import XCTest

@testable import MonitorKit

/// `mk_quotient(a, b, 1 / b)` (two fused Newton steps from the reciprocal) is the
/// correctly rounded `a / b` the safe-math division gives, bit for bit, on the GPU:
/// every code numerator and divisor the decode and the box filter use, and random
/// finite operands. The picture and the focus mask rely on it to replace divisions.
final class ExactQuotientTests: XCTestCase {
  static let kernel = """
    kernel void test_quotient(device const float2* input [[buffer(0)]], device uint2* out [[buffer(1)]],
                              constant uint& count [[buffer(2)]], uint i [[thread_position_in_grid]]) {
      if (i >= count) return;
      float a = input[i].x, b = input[i].y;
      out[i] = uint2(as_type<uint>(a / b), as_type<uint>(mk_quotient(a, b, 1.0f / b)));
    }
    // A 16-bit unorm plane's value as mk_lumaCode reads it (texel × codeScale.x), less
    // the black level, over the span: every stored sample of a biplanar layout.
    kernel void test_planeQuotient(texture2d<float, access::read> plane [[texture(0)]], device uint2* out [[buffer(1)]],
                                   constant float4& p [[buffer(2)]], uint2 xy [[thread_position_in_grid]]) {
      float code = plane.read(xy).r * p.x, a = code - p.y;
      uint i = xy.y * 256 + xy.x;
      out[i] = uint2(as_type<uint>(a / p.z), as_type<uint>(mk_quotient(a, p.z, 1.0f / p.z)));
    }
    """

  func library(_ gpu: TestGPU) throws -> MTLLibrary {
    try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode], extra: Self.kernel)
  }

  /// Bit patterns of GPU `a / b` and `mk_quotient` for each pair; the count that differ.
  func mismatches(_ gpu: TestGPU, _ pipeline: MTLComputePipelineState, _ pairs: [SIMD2<Float>]) -> (Int, String) {
    let input = gpu.buffer(pairs), out = gpu.buffer(length: pairs.count * 8)
    var count = UInt32(pairs.count)
    gpu.run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(pipeline)
      e.setBuffer(input, offset: 0, index: 0)
      e.setBuffer(out, offset: 0, index: 1)
      e.setBytes(&count, length: 4, index: 2)
      e.dispatchThreads(MTLSize(width: pairs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
      e.endEncoding()
    }
    let r = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD2<UInt32>.self), count: pairs.count)
    var wrong = 0, first = ""
    var i = 0
    while i < pairs.count {
      if r[i].x != r[i].y {
        if wrong == 0 {
          first = "\(pairs[i].x) / \(pairs[i].y): \(Float(bitPattern: r[i].x)) vs \(Float(bitPattern: r[i].y))"
        }
        wrong += 1
      }
      i += 1
    }
    return (wrong, first)
  }

  /// Every level set of every range and depth: each luma code (quarter codes, as the
  /// pair boxes make) less black over the luma span, each chroma code less the centre
  /// over the chroma span; every matrix's kg; the box filter's means.
  func testCodeQuotientsAreExact() throws {
    let gpu = try requireGPU()
    let pipeline = try gpu.device.makeComputePipelineState(function: XCTUnwrap(library(gpu).makeFunction(name: "test_quotient")))
    var pairs: [SIMD2<Float>] = []
    for range in [CodeRange.full, .legal] {
      for depth in [8, 10, 12, 16] {
        let l = range.levels(bitDepth: depth)
        let maximum = Float((1 << depth) - 1)
        var code: Float = -4
        while code <= maximum + 4 {
          pairs.append(SIMD2(code - Float(l.black), Float(l.span)))
          pairs.append(SIMD2(code - Float(l.center), Float(l.chromaSpan)))
          // Centred chroma after a box or the rescaled 10-bit levels: still codes.
          code += depth == 16 ? 0.25 : 0.125
        }
      }
    }
    // Box means: sums of up to 8 taps (pairs double them) by each tap count.
    for count in 1...8 {
      var sum: Float = -64
      while sum <= 8 * 1023 * 2 {
        pairs.append(SIMD2(sum, Float(count)))
        sum += 0.125
      }
    }
    let (wrong, first) = mismatches(gpu, pipeline, pairs)
    XCTAssertEqual(wrong, 0, "of \(pairs.count); first: \(first)")
  }

  /// Every 16-bit plane sample, at each biplanar depth's code scale, over each luma
  /// and chroma level set (the texel × scale product is not an integer there).
  func testPlaneSampleQuotientsAreExact() throws {
    let gpu = try requireGPU()
    let pipeline = try gpu.device.makeComputePipelineState(
      function: XCTUnwrap(library(gpu).makeFunction(name: "test_planeQuotient")))
    var values = [UInt16](repeating: 0, count: 65536)
    var k = 0
    while k < 65536 {
      values[k] = UInt16(k)
      k += 1
    }
    let plane = values.withUnsafeBytes { gpu.texture(.r16Unorm, 256, 256, bytes: $0, bytesPerRow: 512) }
    let out = gpu.buffer(length: 65536 * 8)
    var checked = 0
    for depth in [10, 12, 16] {
      let scale: Float = 65535 / Float(1 << (16 - depth))
      for range in [CodeRange.full, .legal] {
        let l = range.levels(bitDepth: depth)
        for (black, span) in [(Float(l.black), Float(l.span)), (Float(l.center), Float(l.chromaSpan))] {
          var p = SIMD4<Float>(scale, black, span, 0)
          gpu.run { cb in
            let e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pipeline)
            e.setTexture(plane, index: 0)
            e.setBuffer(out, offset: 0, index: 1)
            e.setBytes(&p, length: 16, index: 2)
            e.dispatchThreads(MTLSize(width: 256, height: 256, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            e.endEncoding()
          }
          let r = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD2<UInt32>.self), count: 65536)
          var wrong = 0
          var i = 0
          while i < 65536 {
            if r[i].x != r[i].y { wrong += 1 }
            i += 1
          }
          XCTAssertEqual(wrong, 0, "\(depth)-bit \(range) black \(black) span \(span)")
          checked += 1
        }
      }
    }
    XCTAssertEqual(checked, 12)
  }

  /// Random finite numerators of every magnitude the decode meets (and well beyond),
  /// signed zeros, over every divisor class: spans, kg of each matrix, tap counts,
  /// footprints and random divisors.
  func testRandomQuotientsAreExact() throws {
    let gpu = try requireGPU()
    let pipeline = try gpu.device.makeComputePipelineState(function: XCTUnwrap(library(gpu).makeFunction(name: "test_quotient")))
    var divisors: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 219, 224, 876, 896, 3504, 3584, 56064, 57344, 255, 1023, 4095, 65535]
    for m in [YCbCrMatrix.bt601, .bt709, .bt2020, .smpte240m] { divisors.append(Float(m.coefficients.g)) }
    var rng = SeededRandom(77)
    for _ in 0..<64 { divisors.append(Float(Double(rng.next() % 1_000_000) / 1000 + 0.001)) }
    var pairs: [SIMD2<Float>] = [SIMD2(0, 876), SIMD2(-0.0, 876), SIMD2(0, 0.7152), SIMD2(-0.0, 0.7152)]
    let perDivisor = (1 << 22) / divisors.count
    for b in divisors {
      var n = 0
      while n < perDivisor {
        // Exponents 2^-40 … 2^40, full random mantissas, both signs.
        let mantissa = UInt32(truncatingIfNeeded: rng.next()) & 0x7F_FFFF
        let exponent = UInt32(127 - 40 + Int(rng.next() % 81))
        let sign = UInt32(truncatingIfNeeded: rng.next()) & 0x8000_0000
        pairs.append(SIMD2(Float(bitPattern: sign | exponent << 23 | mantissa), b))
        n += 1
      }
    }
    let (wrong, first) = mismatches(gpu, pipeline, pairs)
    XCTAssertEqual(wrong, 0, "of \(pairs.count); first: \(first)")
  }
}
