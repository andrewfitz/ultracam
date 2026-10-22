import Metal
import XCTest

@testable import MonitorKit

/// GPU time from the command buffer's GPU timestamps (commit and wait happen
/// only here, in the test). Budgets are from ARCHITECTURE.md, M4 Max.
final class Benchmarks: XCTestCase {
  override func setUpWithError() throws { try skipTimingUnderValidation() }

  static let width = 3840, height = 2160

  /// A 4K v210 frame with detail everywhere (gradients plus noise), built word by word.
  static func frame4K(_ gpu: TestGPU, seed: UInt64 = 1, linear: Bool = false) throws -> MonitorFrame {
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
    let t: MTLTexture
    if linear {
      // A linear texture over a buffer, as one wrapped from an IOSurface `CVPixelBuffer` is.
      let rowBytes = (groups * 16 + 255) / 256 * 256
      let buffer = gpu.device.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
      words.withUnsafeBytes { w in
        for y in 0..<height {
          memcpy(buffer.contents() + y * rowBytes, w.baseAddress! + y * groups * 16, groups * 16)
        }
      }
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Uint, width: groups, height: height, mipmapped: false)
      d.usage = .shaderRead
      d.storageMode = .shared
      t = buffer.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes)!
    } else {
      t = words.withUnsafeBytes { gpu.texture(.rgba32Uint, groups, height, bytes: $0, bytesPerRow: groups * 16) }
    }
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
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 1))
    feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 2))
    let plainFeed = gpu.engine.makeFeed()
    // Common window sizes, not only the exact 2:1 and 1:1 cases.
    let sizes = [("960×540", 960, 540), ("1280×720", 1280, 720), ("1600×900", 1600, 900), ("1080p", 1920, 1080),
                 ("2560×1440", 2560, 1440), ("4K", 3840, 2160)]
    var runs: [(String, MonitorPass, MonitorFeed, MonitorState, MTLTexture)] = []
    for (name, w, h) in sizes {
      let target = privateTarget(gpu, w, h)
      let cases: [(String, MonitorFeed, MonitorState)] = [
        ("tools off", plainFeed, MonitorState()),
        ("LUTs + zebras + peaking + guides", feed, allTools(falseColor: false)),
        ("every tool + six-band false colour", feed, allTools(falseColor: true)),
      ]
      for (label, f, state) in cases { runs.append(("\(name) \(label)", gpu.engine.makePass(), f, state, target)) }
    }
    // Every pipeline compiles before the clocks ramp up: a compile on the way lets the GPU idle down.
    try gpu.run { cb in
      // Peaking needs the mask; analyse once outside the timing, as the mask is per feed, not per pass.
      try feed.analyze(frame, focus: allTools(falseColor: false).focus, into: cb)
      for r in runs { try r.1.encode(frame: frame, feed: r.2, state: r.3, target: r.4, into: cb) }
    }
    try warmUp(gpu, frame)
    var results: [String: Double] = [:]
    for (label, pass, f, state, target) in runs {
      results[label] = try gpuTime(gpu, "4K v210 -> \(label)") {
        try pass.encode(frame: frame, feed: f, state: state, target: target, into: $0)
      }
    }
    // Budgets, every tool on: 1080p ≤ 0.35 ms and the 1600 × 900 window (a 2.4× box,
    // the costliest minification) ≤ 0.40 ms; any smaller window ≤ 0.5 ms.
    for name in ["960×540", "1280×720", "1600×900", "1080p"] {
      let budget = name == "1080p" ? 0.35 : (name == "1600×900" ? 0.40 : 0.5)
      XCTAssertLessThanOrEqual(results["\(name) every tool + six-band false colour"]!, budget, name)
      XCTAssertLessThanOrEqual(results["\(name) LUTs + zebras + peaking + guides"]!, budget, name)
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

  /// The analysis on the output stage (after a 33³ burn-in LUT) decodes R'G'B'
  /// and applies the LUT at every source pixel, not only luma: 0.48 ms tetrahedral,
  /// 0.55 ms trilinear on M4 Max (0.51 and 0.61 before the analysis's own v210
  /// decode and its one-LUT pipeline), over the 0.4 ms source-stage focus budget.
  /// Guarded against regressions; the decode alone is about 0.31 ms of it.
  func testFocusMaskOnALUTStageGPUTime() throws {
    let gpu = try requireGPU()
    let frame = try Self.frame4K(gpu)
    try warmUp(gpu, frame)
    var focus = FocusSettings()
    focus.enabled = true
    focus.stage = .output
    for mode in [LUTInterpolation.tetrahedral, .trilinear] {
      let feed = gpu.engine.makeFeed()
      feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 3), interpolation: mode)
      let ms = try gpuTime(gpu, "focus mask 4K v210, output stage (33³ \(mode))") {
        feed.invalidateFocusMask()
        try feed.analyze(frame, focus: focus, into: $0)
      }
      XCTAssertLessThanOrEqual(ms, mode == .tetrahedral ? 0.52 : 0.6, "\(mode)")
    }
  }

  func testFocusMaskGPUTime() throws {
    let gpu = try requireGPU()
    // Also a linear texture, as a frame wrapped from an IOSurface pixel buffer is.
    let frames = [("", try Self.frame4K(gpu)), (", linear texture", try Self.frame4K(gpu, linear: true))]
    try warmUp(gpu, frames[0].1)
    var focus = FocusSettings()
    focus.enabled = true
    for (label, f) in frames {
      let feed = gpu.engine.makeFeed()
      // A new picture every frame: the mask is never already current.
      let ms = try gpuTime(gpu, "focus mask 4K v210\(label)") {
        feed.invalidateFocusMask()
        try feed.analyze(f, focus: focus, into: $0)
      }
      XCTAssertLessThanOrEqual(ms, 0.24, label)
    }
  }

  /// Four live 4K feeds into one 4K multiview: per feed one analysis, a 1080p
  /// quadrant with every tool and a 540p thumbnail, all eight surfaces in one
  /// render pass (`MonitorMultiview`). The same surfaces as eight chained
  /// `encode(clear: false)` passes, each loading and storing the whole target,
  /// are measured interleaved for comparison.
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
    let multiview = MonitorMultiview()
    func quadrant(_ i: Int) -> MonitorViewport { MonitorViewport(x: (i % 2) * 1920, y: (i / 2) * 1080, width: 1920, height: 1080) }
    func thumbnail(_ i: Int) -> MonitorViewport { MonitorViewport(x: (i % 2) * 1920, y: (i / 2) * 1080, width: 960, height: 540) }
    func analyze(_ cb: MTLCommandBuffer) throws {
      for (frame, feed, _, _) in feeds {
        // Live feeds: every frame is new, so every analysis runs.
        feed.invalidateFocusMask()
        try feed.analyze(frame, focus: state.focus, into: cb)
      }
    }
    func shared(_ cb: MTLCommandBuffer) throws {
      try analyze(cb)
      try multiview.encode(target: target, into: cb) { canvas in
        for (i, (frame, feed, big, small)) in feeds.enumerated() {
          try canvas.draw(big, frame: frame, feed: feed, state: state, viewport: quadrant(i))
          try canvas.draw(small, frame: frame, feed: feed, state: MonitorState(), viewport: thumbnail(i))
        }
      }
    }
    func chained(_ cb: MTLCommandBuffer) throws {
      try analyze(cb)
      for (i, (frame, feed, big, small)) in feeds.enumerated() {
        try big.encode(frame: frame, feed: feed, state: state, target: target, viewport: quadrant(i), clear: i == 0, into: cb)
        try small.encode(frame: frame, feed: feed, state: MonitorState(), target: target, viewport: thumbnail(i), clear: false, into: cb)
      }
    }
    for _ in 0..<10 {
      try gpu.run(shared)
      try gpu.run(chained)
    }
    var one: [Double] = [], eight: [Double] = []
    for _ in 0..<30 {
      for (encode, times) in [(shared, 0), (chained, 1)] as [((MTLCommandBuffer) throws -> Void, Int)] {
        let cb = gpu.queue.makeCommandBuffer()!
        try encode(cb)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        if times == 0 { one.append(ms) } else { eight.append(ms) }
      }
    }
    let ms = one.min()!, perPass = eight.min()!
    print(String(format: "BENCH 4 feeds (4 × analysis + 4 × 1080p all tools + 4 × 540p) into 4K, one render pass: min %.3f ms", ms))
    print(String(format: "BENCH 4 feeds into 4K, eight chained render passes: min %.3f ms (%+.0f%%)", perPass, (perPass / ms - 1) * 100))
    XCTAssertLessThan(ms, 1000.0 / 60)
    XCTAssertLessThanOrEqual(ms, 2.0, "four feeds' monitoring in under 2 ms of a 16.7 ms frame")
    XCTAssertLessThanOrEqual(ms, perPass * 1.02, "one render pass costs no more than one per surface")
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
      feed.invalidateFocusMask()
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

  /// The picture pass per output encoding and display transform against the
  /// signal-native SDR baseline, 4K v210 to a 1080p rgba16Float target, measured
  /// interleaved (one command buffer per case per round) so other GPU load hits all alike.
  func testOutputEncodingsGPUTime() throws {
    let gpu = try requireGPU()
    let sdr = try Self.frame4K(gpu)
    try warmUp(gpu, sdr)
    func relabel(_ signal: SignalDescription) throws -> MonitorFrame {
      try MonitorFrame(layout: .v210, width: Self.width, height: Self.height, packed: sdr.packed, signal: signal)
    }
    let log = try relabel(SignalDescription(encoding: .log(.sLog3SGamut3Cine)))
    let pq = try relabel(SignalDescription(matrix: .bt2020, encoding: .display(.pq)))
    let hlg = try relabel(SignalDescription(matrix: .bt2020, encoding: .display(.hlg)))
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1920, height: 1080, mipmapped: false)
    d.usage = .renderTarget
    d.storageMode = .private
    let target = gpu.device.makeTexture(descriptor: d)!
    func output(_ p: ColorPrimaries, _ e: MonitorOutputColor.Encoding, headroom: Double = 1) -> MonitorOutputColor {
      MonitorOutputColor(primaries: p, encoding: e, headroom: headroom)
    }
    let none = DisplayTransform.none
    let cases: [(String, MonitorFrame, MonitorOutputColor, DisplayTransform)] = [
      ("signal-native SDR (baseline)", sdr, .signalNative, none),
      ("sdr BT.1886 BT.2020", sdr, output(.rec2020, .sdr(.bt1886)), none),
      ("sdr sRGB P3", sdr, output(.displayP3, .sdr(.sRGB)), none),
      ("extended linear P3", sdr, output(.displayP3, .extendedLinear), none),
      ("PQ BT.2020", sdr, output(.rec2020, .pq), none),
      ("HLG BT.2020", sdr, output(.rec2020, .hlg), none),
      ("signal-native PQ", pq, .signalNative, none),
      ("S-Log3 → 709 (display assist)", log, .signalNative, .logToRec709),
      ("PQ → SDR (EETF)", pq, .signalNative, .hdrToSDR),
      ("HLG → SDR", hlg, .signalNative, .hdrToSDR),
      ("PQ passthrough → extended linear", pq, output(.rec2020, .extendedLinear, headroom: 2), .hdrPassthrough),
      ("HLG → PQ", hlg, output(.rec2020, .pq), none),
    ]
    for (label, base) in [("tools off", MonitorState()), ("LUTs + zebras + peaking + guides", allTools(falseColor: false))] {
      let feed = gpu.engine.makeFeed(), plainFeed = gpu.engine.makeFeed()
      if base.focus.enabled {
        feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 1))
        feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 2))
      }
      // A display transform needs the camera's signal (no LUT on the surface): those
      // cases show the other tools from a feed without LUTs.
      let passes = cases.map { c -> (MonitorPass, MonitorState) in
        let pass = gpu.engine.makePass()
        pass.outputColor = c.2
        var state = base
        state.displayTransform.mode = c.3
        return (pass, state)
      }
      var times = [[Double]](repeating: [], count: cases.count)
      for round in 0..<70 {
        for (i, c) in cases.enumerated() {
          let cb = gpu.queue.makeCommandBuffer()!
          let f = c.3 == .none ? feed : plainFeed
          if base.focus.enabled {
            // Every round analyses, so subtracting one analysis is right for all.
            f.invalidateFocusMask()
            try f.analyze(c.1, focus: base.focus, into: cb)
          }
          try passes[i].0.encode(frame: c.1, feed: f, state: passes[i].1, target: target, into: cb)
          cb.commit()
          cb.waitUntilCompleted()
          XCTAssertNil(cb.error)
          if round >= 10 { times[i].append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
      }
      // Analysis costs the same in every case; measure it alone to subtract it.
      var analysis = Double.infinity
      if base.focus.enabled {
        for _ in 0..<40 {
          let cb = gpu.queue.makeCommandBuffer()!
          feed.invalidateFocusMask()
          try feed.analyze(sdr, focus: base.focus, into: cb)
          cb.commit()
          cb.waitUntilCompleted()
          analysis = min(analysis, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
      } else {
        analysis = 0
      }
      let baseline = times[0].min()! - analysis
      for (i, c) in cases.enumerated() {
        XCTAssertTrue(passes[i].0.usesSpecializedPipeline, c.0)
        let ms = times[i].min()! - analysis
        // Interpolated labels: `%@` with Swift strings garbled and dropped lines here.
        print("BENCH 4K v210 -> 1080p f16 \(label), \(c.0): " + String(format: "%.3f ms (%+.1f%%)", ms, (ms / baseline - 1) * 100))
        // Every output encoding, PQ and HLG included, within 10% of the baseline (plus
        // 10 µs of timer noise): about +8% on a bare picture, less with tools.
        if i <= 6 { XCTAssertLessThanOrEqual(ms, baseline * 1.1 + 0.01, "\(label) \(c.0)") }
      }
    }
  }

  /// Freeze's compute copy of a 4K v210 frame (22 MB), into planes allocated once.
  func testFreezeCopyGPUTime() throws {
    let gpu = try requireGPU()
    let frame = try Self.frame4K(gpu)
    try warmUp(gpu, frame)
    let feed = gpu.engine.makeFeed()
    try gpu.run { _ = try feed.freeze(frame, into: $0) }
    let created = gpu.engine.resourcesCreated
    let ms = try gpuTime(gpu, "freeze 4K v210 (compute copy)") { _ = try feed.freeze(frame, into: $0) }
    XCTAssertEqual(gpu.engine.resourcesCreated, created)
    print("BENCH freeze 4K v210 persistent memory: \(feed.persistentMemoryBytes) bytes")
    XCTAssertLessThanOrEqual(ms, 0.5)
  }
}
