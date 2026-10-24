import Metal
import XCTest

@testable import MonitorKit

/// HDR → SDR on the GPU (BT.2446 Method C for HLG, the BT.2408 EETF for PQ) against
/// Core's reference, in the SDR signal the pass writes: every 10-bit neutral and
/// thousands of colours, in and out of BT.709, within half a 10-bit code.
final class HDRDownConversionGPUTests: XCTestCase {
  func floatFrame(_ gpu: TestGPU, _ values: [SIMD3<Double>], signal: SignalDescription) throws -> MonitorFrame {
    var picture = SyntheticFrame(layout: .rgba32Float, width: values.count, height: 1)
    picture.rgb = values.map { SIMD3(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) }
    return try picture.frame(gpu, signal: signal)
  }

  /// Every 10-bit code as a neutral, the cube's corners and edges, and random colours.
  static let values: [SIMD3<Double>] = {
    var v = (0...1023).map { SIMD3<Double>(repeating: Double($0) / 1023) }
    for i in 0...32 {
      let t = Double(i) / 32
      for corner in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 0, 1)] {
        v.append(corner * t)
        v.append(corner * t + (SIMD3(repeating: 1) - corner) * (t / 2))
      }
    }
    var rng = SeededRandom(23)
    for _ in 0..<3000 {
      v.append(SIMD3(Double.random(in: 0...1, using: &rng), Double.random(in: 0...1, using: &rng), Double.random(in: 0...1, using: &rng)))
    }
    return v
  }()

  func testHDRToSDRIsWithinHalfA10BitCodeOfTheReference() throws {
    let gpu = try requireGPU()
    let cases: [(String, SignalDescription, Double)] = [
      ("HLG 2020", SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.hlg)), 1000),
      ("HLG 709", SignalDescription(range: .full, encoding: .display(.hlg), primaries: .rec709), 1000),
      ("PQ 2020 1000", SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq)), 1000),
      ("PQ 2020 4000", SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq)), 4000),
      ("PQ P3", SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq), primaries: .displayP3), 1000),
    ]
    for (name, signal, peak) in cases {
      let frame = try floatFrame(gpu, Self.values, signal: signal)
      var state = MonitorState()
      state.displayTransform = DisplayTransformSettings(mode: .hdrToSDR, pqSourcePeak: peak)
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertTrue(pass.status.isActive(.displayTransform), name)
      var worst = 0.0, at = 0
      for (i, v) in Self.values.enumerated() {
        let cpu = pass.colorPipeline.present(ColorRGB(r: v.x, g: v.y, b: v.z))
        let g = out.rgb(i, 0)
        let e = max(abs(Double(g.x) - cpu.r), abs(Double(g.y) - cpu.g), abs(Double(g.z) - cpu.b))
        if e > worst { (worst, at) = (e, i) }
      }
      print("HDR → SDR \(name): worst GPU-CPU " + String(format: "%.2e (%.3f of a 10-bit code) at #%d", worst, worst * 1023, at))
      let v = Self.values[at]
      XCTAssertLessThan(
        worst * 1023, 0.5,
        "\(name) at \(v): GPU \(out.rgb(at, 0)), CPU \(pass.colorPipeline.present(ColorRGB(r: v.x, g: v.y, b: v.z)))")
    }
  }
}
