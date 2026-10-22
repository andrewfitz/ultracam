import Metal
import XCTest

@testable import MonitorKit

/// Metal 4 against the classic path: CPU encode cost per surface and GPU time,
/// measured interleaved (one submission per path per round, minimum of N) so
/// other load on the shared GPU hits both alike.
final class Metal4Benchmarks: XCTestCase {
  override func setUpWithError() throws { try skipTimingUnderValidation() }

  static func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }

  /// Steady-state CPU cost per surface, wall clock, including Metal's own encoder
  /// creation: classic, Metal 4 render, Metal 4 compute, analysis, and prepare +
  /// draw in a host render pass.
  func testMetal4CPUEncodeCost() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 384, height: 216), signal: .rec709)
    let feed = gpu.engine.makeFeed(), classicFeed = gpu.engine.makeFeed()
    let lut = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 1))
    feed.burnInLUT = lut
    classicFeed.burnInLUT = lut
    var state = MonitorState()
    everyTool(&state)
    state.falseColor.mode = .off
    let pass = gpu.engine.makePass(), computePass = gpu.engine.makePass(), hostPass = gpu.engine.makePass()
    let classic = gpu.engine.makePass()
    let target = m.target(192, 108, format: .bgra8Unorm)
    let computeTarget = m.target(192, 108, format: .bgra8Unorm, usage: [.shaderWrite, .shaderRead])
    let classicTarget = gpu.texture(.bgra8Unorm, 192, 108, usage: .renderTarget)
    let host = MTL4RenderPassDescriptor()
    host.colorAttachments[0].texture = target
    host.colorAttachments[0].loadAction = .load
    host.colorAttachments[0].storeAction = .store
    let format = MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm)
    let vp = MonitorViewport(width: 192, height: 108)
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    #if DEBUG
      let build = "debug", renderBudget = 15.0
    #else
      let build = "release", renderBudget = 10.0
    #endif
    // The CPU is shared with other processes: a block lost to contention is
    // measured again (three blocks at most); each figure is its best block's median.
    var best = (classic: Double.infinity, render: Double.infinity, compute: Double.infinity,
                analysis: Double.infinity, draw: Double.infinity)
    func withinBudget() -> Bool {
      best.render <= renderBudget && best.draw <= 10 && best.compute <= 10 && best.analysis <= 10
    }
    for _ in 0..<3 where !withinBudget() {
      var t = (classic: [Double](), render: [Double](), compute: [Double](), analysis: [Double](), draw: [Double]())
      for i in 0..<300 {
        let cb = gpu.queue.makeCommandBuffer()!
        classicFeed.invalidateFocusMask()
        try classicFeed.analyze(frame, focus: state.focus, into: cb)
        let c0 = now()
        try classic.encode(frame: frame, feed: classicFeed, state: state, target: classicTarget, into: cb)
        let c1 = now()
        cb.commit()
        try m.run { s in
          feed.invalidateFocusMask()
          let t0 = now()
          try feed.analyze(frame, focus: state.focus, into: s)
          let t1 = now()
          try pass.encode(frame: frame, feed: feed, state: state, target: target, into: s)
          let t2 = now()
          try computePass.encodeCompute(frame: frame, feed: feed, state: state, target: computeTarget, into: s)
          let t3 = now()
          let encoder = s.commandBuffer.makeRenderCommandEncoder(descriptor: host)!
          let t4 = now()
          try hostPass.prepare(frame: frame, feed: feed, state: state, viewport: vp, target: format, submission: s)
          try hostPass.draw(with: encoder)
          let t5 = now()
          encoder.endEncoding()
          if i >= 30 {
            t.analysis.append(Double(t1 - t0) / 1000)
            t.render.append(Double(t2 - t1) / 1000)
            t.compute.append(Double(t3 - t2) / 1000)
            t.draw.append(Double(t5 - t4) / 1000)
            t.classic.append(Double(c1 - c0) / 1000)
          }
        }
      }
      gpu.run { _ in }
      best = (
        min(best.classic, Self.median(t.classic)), min(best.render, Self.median(t.render)),
        min(best.compute, Self.median(t.compute)), min(best.analysis, Self.median(t.analysis)),
        min(best.draw, Self.median(t.draw))
      )
    }
    let classicMedian = best.classic, render = best.render
    print(
      String(
        format:
          "BENCH Metal 4 CPU per surface (median, %@ build): render encode %.1f µs, compute encode %.1f µs, prepare + draw in a host pass %.1f µs, analysis %.1f µs; classic encode %.1f µs",
        build, render, best.compute, best.draw, best.analysis, classicMedian))
    // ≤ 10 µs per surface in steady state. Metal's own render encoder creation is
    // about 4 µs of an unoptimized build's render encode, so it gets 15 there.
    XCTAssertLessThanOrEqual(render, renderBudget, "Metal 4 render encode")
    XCTAssertLessThanOrEqual(best.draw, 10, "Metal 4 prepare + draw")
    XCTAssertLessThanOrEqual(best.compute, 10, "Metal 4 compute encode")
    XCTAssertLessThanOrEqual(best.analysis, 10, "Metal 4 analysis")
  }

  /// GPU time, 4K v210 to a 1080p target with every tool and the focus analysis,
  /// interleaved: classic render, Metal 4 render, Metal 4 compute. Metal 4 adds no
  /// GPU work beyond its barriers.
  func testMetal4GPUTime() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try Benchmarks.frame4K(gpu)
    m.resident(frame)
    try Benchmarks().warmUp(gpu, frame)
    for (label, format) in [("bgra8Unorm", MTLPixelFormat.bgra8Unorm), ("rgba16Float", .rgba16Float)] {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1920, height: 1080, mipmapped: false)
      d.storageMode = .private
      d.usage = .renderTarget
      let renderTarget = gpu.device.makeTexture(descriptor: d)!
      d.usage = .shaderWrite
      let computeTarget = gpu.device.makeTexture(descriptor: d)!
      m.resident(renderTarget, computeTarget)
      for (name, tools) in [("tools off", false), ("every tool + analysis", true)] {
        var state = MonitorState()
        if tools { everyTool(&state) }
        let feeds = (0..<3).map { _ in gpu.engine.makeFeed() }
        let passes = (0..<3).map { _ in gpu.engine.makePass() }
        var times = [[Double]](repeating: [], count: 3)
        for round in 0..<70 {
          let cb = gpu.queue.makeCommandBuffer()!
          // Every round is a new picture: analyses always run.
          if tools {
            feeds[0].invalidateFocusMask()
            try feeds[0].analyze(frame, focus: state.focus, into: cb)
          }
          try passes[0].encode(frame: frame, feed: feeds[0], state: state, target: renderTarget, into: cb)
          cb.commit()
          cb.waitUntilCompleted()
          let classic = (cb.gpuEndTime - cb.gpuStartTime) * 1000
          let render = try m.run { s in
            if tools {
              feeds[1].invalidateFocusMask()
              try feeds[1].analyze(frame, focus: state.focus, into: s)
            }
            try passes[1].encode(frame: frame, feed: feeds[1], state: state, target: renderTarget, into: s)
          }
          let compute = try m.run { s in
            if tools {
              feeds[2].invalidateFocusMask()
              try feeds[2].analyze(frame, focus: state.focus, into: s)
            }
            try passes[2].encodeCompute(frame: frame, feed: feeds[2], state: state, target: computeTarget, into: s)
          }
          if round >= 10 {
            times[0].append(classic)
            times[1].append(render)
            times[2].append(compute)
          }
        }
        let mins = times.map { $0.min()! }
        print(
          String(
            format: "BENCH 4K v210 -> 1080p %@ %@ GPU (min of 60): classic %.3f ms, Metal 4 render %.3f ms (%+.1f%%), Metal 4 compute %.3f ms (%+.1f%%)",
            label, name, mins[0], mins[1], (mins[1] / mins[0] - 1) * 100, mins[2], (mins[2] / mins[0] - 1) * 100))
        // Same pipelines and work; allow timer and barrier noise.
        XCTAssertLessThanOrEqual(mins[1], mins[0] * 1.1 + 0.02, "\(label) \(name) Metal 4 render")
      }
    }
  }
}
