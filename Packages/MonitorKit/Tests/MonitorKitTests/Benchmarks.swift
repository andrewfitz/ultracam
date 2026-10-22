import Metal
import XCTest

@testable import MonitorKit

/// GPU time from the command buffer's GPU timestamps (commit and wait happen
/// only here, in the test). Budgets are from ARCHITECTURE.md, M4 Max.
final class Benchmarks: XCTestCase {
  static let width = 3840, height = 2160

  /// A 4K v210 frame with detail everywhere (gradients plus noise), built word by word.
  static func frame4K(_ gpu: TestGPU, seed: UInt64 = 1) throws -> MonitorFrame {
    let groups = (width + 5) / 6
    var words = [UInt32](repeating: 0, count: groups * 4 * height)
    var rng = SeededRandom(seed)
    words.withUnsafeMutableBufferPointer { w in
      for y in 0..<height {
        for g in 0..<groups {
          let base = UInt32(64 + (g * 6 + y) % 800)
          var v = [UInt32](repeating: 0, count: 12)
          for i in 0..<12 { v[i] = base + UInt32(rng.next() % 64) }
          let o = (y * groups + g) * 4
          w[o] = v[0] | v[1] << 10 | v[2] << 20
          w[o + 1] = v[3] | v[4] << 10 | v[5] << 20
          w[o + 2] = v[6] | v[7] << 10 | v[8] << 20
          w[o + 3] = v[9] | v[10] << 10 | v[11] << 20
        }
      }
    }
    let t = words.withUnsafeBytes { gpu.texture(.rgba32Uint, groups, height, bytes: $0, bytesPerRow: groups * 16) }
    return try MonitorFrame(layout: .v210, width: width, height: height, packed: t, signal: .rec709)
  }

  func privateTarget(_ gpu: TestGPU, _ w: Int, _ h: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = .renderTarget
    d.storageMode = .private
    return gpu.device.makeTexture(descriptor: d)!
  }

  /// GPU milliseconds of `encode` over `runs` command buffers after warm-up: the
  /// minimum (the uncontended cost; other processes share this GPU) and the median.
  func gpuTimes(_ gpu: TestGPU, runs: Int = 60, _ encode: (MTLCommandBuffer) throws -> Void) throws -> (min: Double, median: Double) {
    var times: [Double] = []
    for i in 0..<(runs + 10) {
      let cb = gpu.queue.makeCommandBuffer()!
      try encode(cb)
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertNil(cb.error)
      if i >= 10 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
    }
    return (times.min()!, times.sorted()[times.count / 2])
  }

  func gpuTime(_ gpu: TestGPU, runs: Int = 60, _ label: String, _ encode: (MTLCommandBuffer) throws -> Void) throws -> Double {
    let t = try gpuTimes(gpu, runs: runs, encode)
    print(String(format: "BENCH %@: min %.3f ms, median %.3f ms", label, t.min, t.median))
    return t.min
  }

  /// About half a second of GPU work first, so the GPU's clocks have ramped up.
  func warmUp(_ gpu: TestGPU, _ frame: MonitorFrame) throws {
    let pass = gpu.engine.makePass(), feed = gpu.engine.makeFeed(), target = privateTarget(gpu, 3840, 2160)
    let start = Date()
    while Date().timeIntervalSince(start) < 0.5 {
      try gpu.run { cb in for _ in 0..<4 { try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: target, into: cb) } }
    }
  }

  func allTools(falseColor: Bool) -> MonitorState {
    var s = MonitorState()
    everyTool(&s)
    if !falseColor { s.falseColor.mode = .off }
    return s
  }

  func testPicturePassGPUTime() throws {
    let gpu = try requireGPU()
    let frame = try Self.frame4K(gpu)
    try warmUp(gpu, frame)
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 1))
    feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 2))
    let plainFeed = gpu.engine.makeFeed()
    var results: [String: Double] = [:]
    // Common window sizes, not only the exact 2:1 and 1:1 cases.
    let sizes = [("960×540", 960, 540), ("1280×720", 1280, 720), ("1600×900", 1600, 900), ("1080p", 1920, 1080),
                 ("2560×1440", 2560, 1440), ("4K", 3840, 2160)]
    for (name, w, h) in sizes {
      let target = privateTarget(gpu, w, h)
      let cases: [(String, MonitorFeed, MonitorState)] = [
        ("tools off", plainFeed, MonitorState()),
        ("LUTs + zebras + peaking + guides", feed, allTools(falseColor: false)),
        ("every tool + six-band false colour", feed, allTools(falseColor: true)),
      ]
      for (label, f, state) in cases {
        let pass = gpu.engine.makePass()
        // Peaking needs the mask; analyse once outside the timing, as the mask is per feed, not per pass.
        if state.focus.enabled { try gpu.run { try f.analyze(frame, focus: state.focus, into: $0) } }
        results["\(name) \(label)"] = try gpuTime(gpu, "4K v210 -> \(name), \(label)") {
          try pass.encode(frame: frame, feed: f, state: state, target: target, into: $0)
        }
      }
    }
    // Budget: the full picture pass, 4K v210 to 1080p (or any smaller window) with every tool, ≤ 0.5 ms.
    for name in ["960×540", "1280×720", "1600×900", "1080p"] {
      XCTAssertLessThanOrEqual(results["\(name) every tool + six-band false colour"]!, 0.5, name)
      XCTAssertLessThanOrEqual(results["\(name) LUTs + zebras + peaking + guides"]!, 0.5, name)
    }
  }

  /// A pipeline specialized to the surface's tools against the all-tools one,
  /// measured interleaved so other GPU load affects both alike.
  func testSpecializedPipelinesCostLessThanTheAllToolsPipeline() throws {
    let gpu = try requireGPU()
    let frame = try Self.frame4K(gpu)
    try warmUp(gpu, frame)
    let uber = try MonitorEngine(device: gpu.device, specialization: .off)
    let target = privateTarget(gpu, 1920, 1080)
    for (label, state) in [("tools off", MonitorState()), ("zebras only", { var s = MonitorState(); s.zebras[0] = ZebraSet(mode: .lowerLimit, level: 95); return s }())] {
      let a = gpu.engine.makePass(), b = uber.makePass(), fa = gpu.engine.makeFeed(), fb = uber.makeFeed()
      var special: [Double] = [], all: [Double] = []
      for i in 0..<80 {
        for (pass, feed, engineIsSpecial) in [(a, fa, true), (b, fb, false)] {
          let cb = gpu.queue.makeCommandBuffer()!
          try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
          cb.commit()
          cb.waitUntilCompleted()
          if i >= 10 { (engineIsSpecial ? { special.append($0) } : { all.append($0) })((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
      }
      XCTAssertTrue(a.usesSpecializedPipeline)
      let s = special.min()!, u = all.min()!
      print(String(format: "BENCH 4K v210 -> 1080p %@: specialized %.3f ms, all-tools %.3f ms", label, s, u))
      XCTAssertLessThanOrEqual(s, u * 1.05, label)
    }
  }

  func testFocusMaskGPUTime() throws {
    let gpu = try requireGPU()
    let frame = try Self.frame4K(gpu)
    try warmUp(gpu, frame)
    let feed = gpu.engine.makeFeed()
    var focus = FocusSettings()
    focus.enabled = true
    let ms = try gpuTime(gpu, "focus mask 4K v210") { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertLessThanOrEqual(ms, 0.4)
  }

  func testFourFeedsHold60Hz() throws {
    let gpu = try requireGPU()
    var feeds: [(MonitorFrame, MonitorFeed, MonitorPass, MonitorPass)] = []
    for i in 0..<4 {
      let feed = gpu.engine.makeFeed()
      feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: UInt64(i)))
      feeds.append((try Self.frame4K(gpu, seed: UInt64(i + 10)), feed, gpu.engine.makePass(), gpu.engine.makePass()))
    }
    let target = privateTarget(gpu, 3840, 2160)
    let state = allTools(falseColor: false)
    // Each feed: one analysis, a 1920 × 1080 quadrant of a 4K multiview and a 960 × 540 thumbnail.
    let ms = try gpuTime(gpu, runs: 30, "4 feeds (4 × analysis + 4 × 1080p all tools + 4 × 540p) into 4K") { cb in
      for (i, (frame, feed, big, small)) in feeds.enumerated() {
        try feed.analyze(frame, focus: state.focus, into: cb)
        try big.encode(frame: frame, feed: feed, state: state, target: target,
                       viewport: MonitorViewport(x: (i % 2) * 1920, y: (i / 2) * 1080, width: 1920, height: 1080),
                       clear: i == 0, into: cb)
        try small.encode(frame: frame, feed: feed, state: MonitorState(), target: target,
                         viewport: MonitorViewport(x: (i % 2) * 1920, y: (i / 2) * 1080, width: 960, height: 540),
                         clear: false, into: cb)
      }
    }
    XCTAssertLessThan(ms, 1000.0 / 60)
  }

  /// CPU cost of a steady-state `encode`: wall-clock median, including Metal's own encoder creation.
  func testCPUEncodeCost() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 384, height: 216).frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 1))
    let pass = gpu.engine.makePass()
    let state = allTools(falseColor: false)
    let target = privateTarget(gpu, 192, 108)
    var encode: [Double] = [], prepare: [Double] = []
    for i in 0..<300 {
      let cb = gpu.queue.makeCommandBuffer()!
      try feed.analyze(frame, focus: state.focus, into: cb)
      let t0 = DispatchTime.now().uptimeNanoseconds
      try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
      let t1 = DispatchTime.now().uptimeNanoseconds
      try pass.prepare(frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 192, height: 108),
                       targetPixelFormat: .bgra8Unorm, into: cb)
      let t2 = DispatchTime.now().uptimeNanoseconds
      let e = cb.makeRenderCommandEncoder(descriptor: { let d = MTLRenderPassDescriptor(); d.colorAttachments[0].texture = target; return d }())!
      try pass.draw(with: e)
      e.endEncoding()
      cb.commit()
      if i >= 20 {
        encode.append(Double(t1 - t0) / 1000)
        prepare.append(Double(t2 - t1) / 1000)
      }
      if i % 50 == 0 { cb.waitUntilCompleted() }
    }
    gpu.run { _ in }
    let e = encode.sorted()[encode.count / 2], p = prepare.sorted()[prepare.count / 2]
    print(String(format: "BENCH CPU per encode (median): %.1f µs; prepare alone: %.1f µs", e, p))
    XCTAssertLessThan(e, 30, "CPU encode budget (debug build)")
  }
}
