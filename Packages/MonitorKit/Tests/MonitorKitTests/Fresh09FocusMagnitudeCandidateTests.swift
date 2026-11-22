// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Metal
import XCTest

@testable import MonitorKit

/// Experimental L2 magnitude only. Production shaders and thresholds stay unchanged.
final class Fresh09FocusMagnitudeCandidateTests: XCTestCase {
  private func pipelines(_ gpu: TestGPU, v210: Bool = false) throws -> [MTLComputePipelineState] {
    let source = try MonitorShaders.source([.lut, .decode, .monitor])
    let old = "max(abs(gx), abs(gy)) - threshold"
    XCTAssertEqual(source.components(separatedBy: old).count, 2, "candidate substitution must change exactly one expression")
    let prefix = "#define MK_LUTS 0u\n" + (v210 ? "#define MK_LAYOUT(f) 0u\n" : "")
    return try [source, source.replacingOccurrences(of: old, with: "length(float2(gx, gy)) - threshold")].map {
      let library = try gpu.device.makeLibrary(source: prefix + $0, options: MonitorShaders.compileOptions)
      return try gpu.device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "mk_focusMask")))
    }
  }

  private func encode(_ gpu: TestGPU, _ command: MTLCommandBuffer, _ pipeline: MTLComputePipelineState,
                      _ frame: MonitorFrame, _ mask: MTLTexture, _ sensitivity: Double) {
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(frame.packed ?? gpu.engine.emptyPacked, index: 0)
    encoder.setTexture(frame.luma ?? gpu.engine.emptyFloat, index: 1)
    encoder.setTexture(frame.chroma ?? gpu.engine.emptyFloat, index: 2)
    encoder.setTexture(mask, index: 3)
    encoder.setTexture(gpu.engine.emptyLUT, index: 4)
    encoder.setTexture(gpu.engine.emptyLUT, index: 5)
    var f = frame.parameters
    var thresholds = SIMD2(Float(0.02 + (1 - sensitivity) * 0.3), Float(0.02))
    var lut = LUTParameters.disabled
    encoder.setBytes(&f, length: MemoryLayout<FrameParameters>.stride, index: 0)
    encoder.setBytes(&thresholds, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.setBytes(&lut, length: MemoryLayout<LUTParameters>.stride, index: 2)
    encoder.setBytes(&lut, length: MemoryLayout<LUTParameters>.stride, index: 3)
    let dispatch = MonitorFeed.focusDispatch(frame, pipeline)
    encoder.dispatchThreadgroups(dispatch.groups, threadsPerThreadgroup: dispatch.threads)
    encoder.endEncoding()
  }

  /// Independent scalar CPU oracle; same support gate and sensitivity, only the
  /// gradient norm differs. Inputs are Float-round-tripped before differentiation.
  private func confidence(_ values: [Float], _ width: Int, _ x: Int, _ y: Int,
                          _ threshold: Double, _ l2: Bool) -> Double {
    let height = values.count / width
    func value(_ dx: Int, _ dy: Int) -> Double {
      Double(values[max(0, min(height - 1, y + dy)) * width + max(0, min(width - 1, x + dx))])
    }
    var dx: [Double] = [], dy: [Double] = []
    for i in -1...1 {
      dx.append(value(1, i) - value(-1, i))
      dy.append(value(i, 1) - value(i, -1))
    }
    let gx = (3 * dx[0] + 10 * dx[1] + 3 * dx[2]) / 16
    let gy = (3 * dy[0] + 10 * dy[1] + 3 * dy[2]) / 16
    let support = max(abs(dx.sorted()[1]), abs(dy.sorted()[1]))
    guard support > 0.02 else { return 0 }
    let magnitude = l2 ? sqrt(gx * gx + gy * gy) : max(abs(gx), abs(gy))
    return min(1, max(0, (magnitude - threshold) / max(0.0001, threshold / 2)))
  }

  func testCandidateGPUAgreesWithCPUAcrossAnglesBlurNoiseAndSensitivity() throws {
    let gpu = try requireGPU(), pipeline = try pipelines(gpu)
    let width = 80, height = 80
    // Fixed seeds make every orientation and candidate see identical noise.
    for kind in ["ramp", "blur0.8", "blur1.6", "noise0.02", "noise0.08", "impulse"] {
      for angle in [0.0, 22.5, 45.0, 67.5, 90.0] {
        if kind.hasPrefix("noise") || kind == "impulse" { if angle != 0 { continue } }
        let radians = angle * .pi / 180
        var random = SeededRandom(0xF009)
        var values = [Float](), distances = [Double]()
        for y in 0..<height {
          for x in 0..<width {
            let distance = (Double(x) - 39.5) * cos(radians) + (Double(y) - 39.5) * sin(radians)
            distances.append(distance)
            let unitNoise = Double(random.next() % 65536) / 65535 * 2 - 1
            let value: Double
            if kind == "ramp" { value = min(0.9, max(0.1, 0.5 + distance * 0.14)) }
            else if kind.hasPrefix("blur") {
              let sigma = kind == "blur0.8" ? 0.8 : 1.6
              value = 0.5 + 0.3 * erf(distance / (sigma * sqrt(2))) + unitNoise * 0.008
            } else if kind.hasPrefix("noise") {
              value = 0.5 + unitNoise * (kind == "noise0.02" ? 0.02 : 0.08)
            } else { value = x % 17 == 8 && y % 17 == 8 ? 1 : 0.5 }
            values.append(Float(value))
          }
        }
        var picture = SyntheticFrame(layout: .rgba32Float, width: width, height: height)
        picture.rgb = values.map { SIMD3(repeating: Double($0)) }
        let frame = try picture.frame(gpu, signal: SignalDescription(range: .full))
        for sensitivity in [0.25, 0.5, 0.75] {
          var metrics: [(mean: Double, detected: Int, background: Int)] = []
          for candidate in 0...1 {
            let mask = gpu.texture(.r8Unorm, width, height, usage: [.shaderRead, .shaderWrite])
            gpu.run { encode(gpu, $0, pipeline[candidate], frame, mask, sensitivity) }
            var bytes = [UInt8](repeating: 0, count: width * height)
            bytes.withUnsafeMutableBytes {
              mask.getBytes($0.baseAddress!, bytesPerRow: width, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            var centreSum = 0.0, centreCount = 0, detected = 0, background = 0
            for y in 2..<(height - 2) {
              for x in 2..<(width - 2) {
                let index = y * width + x
                let expected = confidence(values, width, x, y, 0.02 + (1 - sensitivity) * 0.3, candidate == 1)
                let actual = Double(bytes[index]) / 255
                XCTAssertEqual(actual, expected, accuracy: 1.0 / 255 + 1e-5, "\(kind), \(angle)°, sensitivity \(sensitivity), candidate \(candidate), (\(x),\(y))")
                if abs(distances[index]) < 0.75 { centreSum += actual; centreCount += 1 }
                if actual > 0 { detected += 1; if abs(distances[index]) > 6 { background += 1 } }
              }
            }
            metrics.append((centreSum / Double(max(1, centreCount)), detected, background))
          }
          print(String(format: "QUALITY Fresh09 %@ angle %.1f sensitivity %.2f: centre L∞ %.5f L2 %.5f; detections %d/%d; background %d/%d",
                       kind, angle, sensitivity, metrics[0].mean, metrics[1].mean, metrics[0].detected,
                       metrics[1].detected, metrics[0].background, metrics[1].background))
          XCTAssertGreaterThanOrEqual(metrics[1].detected, metrics[0].detected, "L2 cannot reduce magnitude with the same gate/threshold")
          if kind == "impulse" { XCTAssertEqual(metrics[1].detected, 0, "directional median must still reject isolated impulses") }
        }
      }
    }
  }

  /// Paired production-sized source analysis, with the very same v210 input,
  /// dispatch, r8 output and shader except for one norm expression. No timed compile.
  func testBenchmarkCandidatePaired4KFocusAnalysis() throws {
    try skipUnrepresentativeTiming()
    let gpu = try requireGPU(), pipeline = try pipelines(gpu, v210: true)
    let frame = try Benchmarks.frame4K(gpu)
    let masks = (0...1).map { _ in gpu.texture(.r8Unorm, frame.width, frame.height, usage: [.shaderRead, .shaderWrite]) }
    var times: [[Double]] = [[], []]
    for round in 0..<50 {
      for candidate in round % 2 == 0 ? [0, 1] : [1, 0] {
        let command = gpu.queue.makeCommandBuffer()!
        // Repeated dispatches amortize command-buffer scheduling/timestamp overhead.
        for _ in 0..<8 { encode(gpu, command, pipeline[candidate], frame, masks[candidate], 0.5) }
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        if round >= 10 { times[candidate].append((command.gpuEndTime - command.gpuStartTime) * 1000 / 8) }
      }
    }
    let minimum = times.map { $0.min()! }, median = times.map { $0.sorted()[$0.count / 2] }
    print(String(format: "BENCH Fresh09 paired 4K source focus L∞/L2: min %.5f/%.5f ms ratio %.4f; median %.5f/%.5f ms ratio %.4f",
                 minimum[0], minimum[1], minimum[1] / minimum[0], median[0], median[1], median[1] / median[0]))
  }
}
