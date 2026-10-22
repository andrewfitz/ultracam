import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// The classic and Metal 4 paths timed against each other on the dev machine,
/// whose GPU other processes share: rounds alternate the two paths, each round
/// is one command buffer (or submission) of `batch` encodes divided by `batch`,
/// and the minimum over the rounds is reported.
final class ScopeMetal4Benchmarks: XCTestCase {
  override func setUpWithError() throws { try skipTimingUnderValidation() }

  func interleaved(
    _ m: ScopeMTL4, rounds: Int = 15, batch: Int = 10, classic: (MTLCommandBuffer) throws -> Void,
    metal4: (MonitorSubmission) throws -> Void
  ) throws -> (classic: Double, metal4: Double) {
    let (_, queue, _) = try GPU.require()
    var a: [Double] = [], b: [Double] = []
    for round in 0..<(rounds + 1) {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      for _ in 0..<batch { try classic(cb) }
      cb.commit()
      cb.waitUntilCompleted()
      if let error = cb.error { throw error }
      let ms = try m.run { s in for _ in 0..<batch { try metal4(s) } }
      // The first round warms both paths (pipelines, rings, residency).
      if round > 0 {
        a.append((cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(batch))
        b.append(ms / Double(batch))
      }
    }
    return (a.min()!, b.min()!)
  }

  func testMetal4AccumulationGPUTime4K() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try ScopeBenchmarkTests.frame(.v210, .natural)
    m.resident(frame.frame)
    var report = ["BENCH 4K v210 accumulation, GPU ms (min of 15 × 10, interleaved), classic / Metal 4:"]
    for (name, settings) in ScopeBenchmarkTests.scopes {
      let classic = try engine.makeAccumulator(settings: settings), a = try engine.makeAccumulator(settings: settings)
      let t = try interleaved(
        m, classic: { cb in try classic.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) },
        metal4: { s in try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: s) })
      report.append(String(format: "  %@: %.3f / %.3f", name, t.classic, t.metal4))
      XCTAssertLessThan(t.metal4, t.classic * 1.25 + 0.03, "\(name): Metal 4 within noise of classic")
    }
    for stage in [SignalStage.source, .output] {
      let (device, _, _) = try GPU.require()
      let lut = try MonitorLUT(
        device: device, cube: ScopeAccumulationTests.makeCube(size: 33) { SIMD3(pow($0.x, 0.9), $0.y, pow($0.z, 1.1)) })
      func group() throws -> ScopeGroup {
        try engine.makeGroup(
          [ScopeBenchmarkTests.scopes[1].1, ScopeBenchmarkTests.scopes[4].1, ScopeBenchmarkTests.scopes[3].1].map {
            var s = $0
            s.stage = stage
            return try engine.makeAccumulator(settings: s)
          })
      }
      let classic = try group(), g = try group()
      let t = try interleaved(
        m, classic: { cb in try classic.accumulate(frame.frame, burnInLUT: lut, monitorLUT: nil, into: cb) },
        metal4: { s in try g.accumulate(frame.frame, burnInLUT: lut, monitorLUT: nil, into: s) })
      XCTAssertEqual(g.fusedMemberCount, 3)
      report.append(
        String(format: "  fused RGB parade + vectorscope + histogram, %@ stage: %.3f / %.3f", "\(stage)", t.classic, t.metal4))
      XCTAssertLessThan(t.metal4, 1, "every pixel of a 4K frame into three scopes within 1 ms")
      XCTAssertLessThan(t.metal4, t.classic * 1.25 + 0.03, "fused: Metal 4 within noise of classic")
    }
    print(report.joined(separator: "\n"))
  }

  func testMetal4DrawGPUTime() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try ScopeBenchmarkTests.frame(.v210, .natural, width: 1920, height: 1080)
    let target = try m.target(1024, 512, format: .bgra8Unorm)
    var report = ["BENCH scope draw at 1024×512 bgra8, GPU ms (min of 15 × 10, interleaved), classic / Metal 4:"]
    for (name, settings) in ScopeBenchmarkTests.scopes {
      let a = try engine.makeAccumulator(settings: settings)
      try GPU.run { cb in try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let classic = engine.makeRenderer(), r = engine.makeRenderer()
      let draw = try interleaved(
        m, classic: { cb in try classic.render(a, target: target, clear: true, into: cb) },
        metal4: { s in try r.render(a, target: target, clear: true, into: s) })
      // A new trace every draw (a display change), as after each accumulation.
      var display = a.settings.display, flip = false
      func next() -> ScopeDisplay {
        flip.toggle()
        display.gain = flip ? 1 : 1.0001
        return display
      }
      let resolve = try interleaved(
        m, classic: { cb in try classic.render(a, display: next(), target: target, clear: true, into: cb) },
        metal4: { s in try r.render(a, display: next(), target: target, clear: true, into: s) })
      report.append(
        String(
          format: "  %@: draw %.3f / %.3f; resolve + draw %.3f / %.3f", name, draw.classic, draw.metal4,
          resolve.classic, resolve.metal4))
      XCTAssertLessThan(draw.metal4, draw.classic * 1.25 + 0.02, "\(name) draw")
      XCTAssertLessThan(resolve.metal4, resolve.classic * 1.25 + 0.02, "\(name) resolve + draw")
    }
    // The per-pixel PQ encode against an SDR layer, both on Metal 4, into an EDR target.
    let edr = try m.target(1024, 512, format: .rgba16Float)
    let a = try engine.makeAccumulator(settings: ScopeBenchmarkTests.scopes[1].1)
    try GPU.run { cb in try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let sdr = engine.makeRenderer(), pq = engine.makeRenderer()
    pq.setOutputColor(MonitorOutputColor(primaries: .rec2020, encoding: .pq))
    let classicSDR = try interleaved(
      m, classic: { _ in }, metal4: { s in try sdr.render(a, target: edr, clear: true, into: s) })
    let metal4PQ = try interleaved(
      m, classic: { _ in }, metal4: { s in try pq.render(a, target: edr, clear: true, into: s) })
    report.append(
      String(format: "  RGB parade into rgba16Float, Metal 4: SDR layer %.3f, PQ BT.2020 %.3f", classicSDR.metal4, metal4PQ.metal4))
    XCTAssertLessThan(metal4PQ.metal4, classicSDR.metal4 * 1.5 + 0.02, "the PQ encode is cheap")
    print(report.joined(separator: "\n"))
  }

  /// CPU cost of one Metal 4 accumulation and one draw, after warm-up.
  func testMetal4EncodeCPUCost() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.engine)
    let frame = try ScopeBenchmarkTests.frame(.v210, .natural, width: 1920, height: 1080)
    m.resident(frame.frame)
    let target = try m.target(1024, 512, format: .bgra8Unorm)
    let a = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    let renderer = engine.makeRenderer()
    var accumulate: [Double] = [], render: [Double] = []
    for i in 0..<220 {
      try m.run { s in
        let t0 = DispatchTime.now().uptimeNanoseconds
        try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: s)
        let t1 = DispatchTime.now().uptimeNanoseconds
        try renderer.render(a, target: target, clear: true, into: s)
        let t2 = DispatchTime.now().uptimeNanoseconds
        if i >= 20 {
          accumulate.append(Double(t1 - t0) / 1000)
          render.append(Double(t2 - t1) / 1000)
        }
      }
    }
    accumulate.sort()
    render.sort()
    print(
      String(
        format: "BENCH Metal 4 CPU encode (debug build): accumulate min %.1f / median %.1f µs, render (resolve + draw) min %.1f / median %.1f µs",
        accumulate[0], accumulate[accumulate.count / 2], render[0], render[render.count / 2]))
    XCTAssertLessThan(accumulate[0], 60)
    XCTAssertLessThan(render[0], 60)
  }
}
