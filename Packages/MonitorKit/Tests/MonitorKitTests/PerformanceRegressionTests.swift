import Metal
import XCTest

@testable import MonitorKit

/// The performance pass changed how pixels are computed, never which: the focus
/// kernel, the v210 decode of the picture, the peaking gathers, the guide search,
/// the zebra stripes and the false-colour band scan all match the W1 shaders bit
/// for bit, and the memory policy releases what a feed no longer needs.
final class PerformanceRegressionTests: XCTestCase {
  // MARK: - Focus analysis

  /// W1's `mk_focusMask` (the 16 × 16 threadgroup tile), source stage (`MK_LUTS` 0) or LUT stage.
  static func w1FocusPipeline(_ gpu: TestGPU, lutStage: Bool) throws -> MTLComputePipelineState {
    let library = try MonitorShaders.makeLibrary(
      device: gpu.device, parts: [.lut, .decode], prefix: lutStage ? "" : "#define MK_LUTS 0u",
      extra: W1PictureShader.source)
    return try gpu.device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "mk_focusMask")))
  }

  func readR8(_ gpu: TestGPU, _ texture: MTLTexture) -> [Float] {
    let out = gpu.buffer(length: texture.width * texture.height * 4)
    gpu.run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(gpu.readMask)
      e.setTexture(texture, index: 0)
      e.setBuffer(out, offset: 0, index: 0)
      e.dispatchThreads(
        MTLSize(width: texture.width, height: texture.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
      e.endEncoding()
    }
    return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Float.self), count: texture.width * texture.height))
  }

  /// The SIMD-shuffle kernel (one column of rows per thread) writes W1's mask: every
  /// layout family, odd sizes with partial threadgroups and partial v210 groups,
  /// centred chroma, and the source, output and monitor stages.
  func testFocusMaskIsTheW1TileKernelBitForBit() throws {
    let gpu = try requireGPU()
    let w1 = (source: try Self.w1FocusPipeline(gpu, lutStage: false), lut: try Self.w1FocusPipeline(gpu, lutStage: true))
    let burn = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 4))
    let monitor = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 5))
    let layouts: [PixelLayout] = [.v210, .uyvy8, .yuyv8, .nv12, .p010, .p210, .p410, .bgra8, .rgba16Float]
    let sizes = [(37, 21), (100, 45), (191, 17), (64, 64)]
    var checked = 0
    for layout in layouts {
      for (i, (w, h)) in sizes.enumerated() {
        let signal = i == 1 ? SignalDescription(chromaSiting: .center) : SignalDescription.rec709
        let source = SyntheticFrame.random(layout, width: w, height: h, seed: UInt64(10 + i))
        let frame = try source.frame(gpu, signal: signal)
        let feed = gpu.engine.makeFeed()
        feed.burnInLUT = burn
        feed.monitorLUT = monitor
        for stage in SignalStage.allCases {
          var focus = FocusSettings()
          focus.enabled = true
          focus.sensitivity = 0.7
          focus.stage = stage
          try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
          let mask = try XCTUnwrap(feed.focusMask)
          let now = readR8(gpu, mask)
          let reference = gpu.texture(.r8Unorm, w, h, usage: [.shaderRead, .shaderWrite])
          gpu.run { cb in
            let e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(stage == .source ? w1.source : w1.lut)
            e.setTexture(frame.packed ?? gpu.engine.emptyPacked, index: 0)
            e.setTexture(frame.luma ?? gpu.engine.emptyFloat, index: 1)
            e.setTexture(frame.chroma ?? gpu.engine.emptyFloat, index: 2)
            e.setTexture(reference, index: 3)
            e.setTexture(stage != .source ? burn.texture : gpu.engine.emptyLUT, index: 4)
            e.setTexture(stage == .monitor ? monitor.texture : gpu.engine.emptyLUT, index: 5)
            var f = frame.parameters
            var thresholds = SIMD2(Float(focus.edgeThreshold), Float(min(1, max(0, focus.noiseRejection))))
            var b = stage != .source ? burn.parameters : LUTParameters.disabled
            var m = stage == .monitor ? monitor.parameters : LUTParameters.disabled
            e.setBytes(&f, length: MemoryLayout<FrameParameters>.stride, index: 0)
            e.setBytes(&thresholds, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            e.setBytes(&b, length: MemoryLayout<LUTParameters>.stride, index: 2)
            e.setBytes(&m, length: MemoryLayout<LUTParameters>.stride, index: 3)
            e.dispatchThreadgroups(
              MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
              threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            e.endEncoding()
          }
          let before = readR8(gpu, reference)
          XCTAssertGreaterThan(Set(before).count, 2, "\(layout) \(w)×\(h) \(stage): a real mask")
          var differing = 0
          for k in 0..<now.count where now[k] != before[k] { differing += 1 }
          XCTAssertEqual(differing, 0, "\(layout) \(w)×\(h) \(stage) \(signal.chromaSiting)")
          checked += 1
        }
      }
    }
    XCTAssertEqual(checked, layouts.count * sizes.count * 3)
  }

  /// Peaking off releases the mask (after the frames in flight); on again makes a new one.
  func testPeakingOffReleasesTheMask() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    var focus = FocusSettings()
    focus.enabled = true
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    let mask = try XCTUnwrap(feed.focusMask)
    XCTAssertEqual(feed.persistentMemoryBytes, mask.allocatedSize)
    let created = gpu.engine.resourcesCreated
    focus.enabled = false
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertNil(feed.focusMask)
    XCTAssertEqual(feed.persistentMemoryBytes, 0)
    XCTAssertEqual(feed.retiredMaskCount, 1, "held for the frames in flight")
    for _ in 0..<MonitorFeed.retiredFrames { try gpu.run { try feed.analyze(frame, focus: focus, into: $0) } }
    XCTAssertEqual(feed.retiredMaskCount, 0)
    // A surface asking for peaking now has no mask: it says so and draws the picture.
    var state = MonitorState()
    state.focus.enabled = true
    let pass = gpu.engine.makePass()
    _ = try gpu.render(frame, state: state, feed: feed, pass: pass)
    XCTAssertEqual(pass.status.reason(for: .focusPeaking), .focusNotAnalyzed)
    focus.enabled = true
    try gpu.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertNotNil(feed.focusMask)
    XCTAssertEqual(gpu.engine.resourcesCreated, created + 1)
  }

  func testPeakingOffReleasesTheMaskOnMetal4() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 96, height: 54), signal: .rec709)
    let feed = gpu.engine.makeFeed()
    var focus = FocusSettings()
    focus.enabled = true
    try m.run { try feed.analyze(frame, focus: focus, into: $0) }
    let mask = try XCTUnwrap(feed.focusMask)
    XCTAssertTrue(gpu.engine.residency.contains(mask))
    focus.enabled = false
    try m.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertNil(feed.focusMask)
    XCTAssertEqual(feed.persistentMemoryBytes, feed.ring.buffer?.allocatedSize ?? 0, "only the uniform ring is left")
    // Released from the residency set once the submission that may read it completed.
    try m.run { try feed.analyze(frame, focus: focus, into: $0) }
    m.drain()
    try m.run { try feed.analyze(frame, focus: focus, into: $0) }
    XCTAssertFalse(gpu.engine.residency.contains(mask))
  }

  // MARK: - Picture

  /// Every filter path of the v210 picture decode against W1: 1:1 nearest, the 2:1
  /// and 4:1 pixel-pair boxes, non-integral boxes (1.2×, 2.4×), Catmull-Rom while
  /// magnified, a width that ends inside a group, centred chroma (the generic
  /// path), with and without every tool (peaking, guides and zebras included).
  func testV210PictureAtEveryScaleIsTheW1PictureBitForBit() throws {
    let gpu = try requireGPU()
    let w1 = try OutputColorGPUTests.w1Pipeline(gpu, format: .rgba32Float)
    let reference = OutputColorGPUTests()
    var tools = MonitorState()
    everyTool(&tools)
    tools.falseColor.mode = .off
    var sixBand = tools
    sixBand.falseColor.mode = .sixBand
    var magnified = MonitorState()
    magnified.geometry.magnification.zoom = 3
    var magnifiedTools = tools
    magnifiedTools.geometry.magnification.zoom = 2.5
    var desqueezed = tools
    desqueezed.geometry.desqueeze = 2
    let frames: [(String, Int, Int, SignalDescription)] = [
      ("192×108", 192, 108, .rec709), ("194×110", 194, 110, .rec709),
      ("centred 192×108", 192, 108, SignalDescription(chromaSiting: .center)),
    ]
    let feedLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 1))
    for (name, w, h, signal) in frames {
      let frame = try PictureTests.picture(.v210, width: w, height: h).frame(gpu, signal: signal)
      let states = [
        ("plain", MonitorState()), ("tools", tools), ("six-band", sixBand), ("zoom 3", magnified),
        ("zoom 2.5 + tools", magnifiedTools), ("de-squeezed", desqueezed),
      ]
      for (label, state) in states {
        for (tw, th) in [(w, h), (w / 2, h / 2), (w / 4, h / 4), (w * 5 / 6, h * 5 / 6), (w * 5 / 12, h * 5 / 12), (w * 2, h * 2)] {
          let feed = gpu.engine.makeFeed()
          feed.burnInLUT = feedLUT
          let pass = gpu.engine.makePass()
          let now = try gpu.render(frame, state: state, feed: feed, pass: pass, width: tw, height: th, analyze: state.focus.enabled)
          let before = reference.renderW1(gpu, w1, frame: frame, feed: feed, pass: pass, state: state, size: (tw, th))
          var differing = 0
          for i in 0..<now.values.count where now.values[i] != before.values[i] { differing += 1 }
          XCTAssertEqual(differing, 0, "\(name) \(label) → \(tw)×\(th)")
        }
      }
    }
  }

  /// The benchmark's 4K v210 frame at the window sizes of the GPU budget, every tool,
  /// against W1: the row cache, the pair boxes and the guide cells at full scale.
  func testFourKPictureAtWindowSizesIsTheW1PictureBitForBit() throws {
    let gpu = try requireGPU()
    let w1 = try OutputColorGPUTests.w1Pipeline(gpu, format: .rgba32Float)
    let reference = OutputColorGPUTests()
    let frame = try Benchmarks.frame4K(gpu)
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 1))
    var state = MonitorState()
    everyTool(&state)
    for (w, h) in [(1600, 900), (1920, 1080), (960, 540), (1280, 720)] {
      let pass = gpu.engine.makePass()
      let now = try gpu.render(frame, state: state, feed: feed, pass: pass, width: w, height: h, analyze: true)
      let before = reference.renderW1(gpu, w1, frame: frame, feed: feed, pass: pass, state: state, size: (w, h))
      var differing = 0
      for i in 0..<now.values.count where now.values[i] != before.values[i] { differing += 1 }
      XCTAssertEqual(differing, 0, "\(w)×\(h)")
    }
  }

  // MARK: - Pieces

  /// `mk_modulo` (zebra stripes) is the integer remainder for every value and period in reach.
  func testFloatQuotientModuloIsExact() throws {
    let gpu = try requireGPU()
    let kernel = """
      kernel void test_modulo(device const int2* input [[buffer(0)]], device int* out [[buffer(1)]],
                              uint i [[thread_position_in_grid]]) {
        out[i] = mk_modulo(input[i].x, input[i].y, 1.0f / float(input[i].y));
      }
      """
    let library = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode, .monitor], extra: kernel)
    let pipeline = try gpu.device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "test_modulo")))
    var inputs: [SIMD2<Int32>] = []
    for m in [4, 6, 12, 16, 24, 30, 32, 48, 64, 7, 1000] {
      for v in stride(from: -20_000, through: 20_000, by: 1) where v % 7 == 0 || abs(v % m) <= 1 || abs(v) < 300 {
        inputs.append(SIMD2(Int32(v), Int32(m)))
      }
    }
    let input = gpu.buffer(inputs), out = gpu.buffer(length: inputs.count * 4)
    gpu.run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(pipeline)
      e.setBuffer(input, offset: 0, index: 0)
      e.setBuffer(out, offset: 0, index: 1)
      e.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
      e.endEncoding()
    }
    let result = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Int32.self), count: inputs.count)
    var wrong = 0
    for (i, p) in inputs.enumerated() where result[i] != ((p.x % p.y) + p.y) % p.y { wrong += 1 }
    XCTAssertEqual(wrong, 0, "of \(inputs.count)")
  }

  /// A pixel within reach of an axis-aligned stroke always finds its cell set, so
  /// skipping clear cells never drops a stroke; most of the picture is clear.
  func testGuideCellsCoverEveryStrokeReach() throws {
    var g = GuideSettings()
    g.enabled = true
    g.thirds = true
    g.centerCross = true
    g.safeAreas = [90, 80]
    g.frameGuides = [FrameGuide(aspect: 2.39, style: .linesAndMatte)]
    for (w, h, ppp) in [(1920, 1080, 1.0), (3840, 2160, 2.0), (1000, 563, 1.5), (16_000, 9_000, 1.0)] {
      let layout = MonitorLayout(
        pictureWidth: 3840, pictureHeight: 2160, pixelAspectRatio: 1, viewportWidth: w, viewportHeight: h,
        geometry: ViewGeometry())
      let p = GuideParameters(GuideRaster(layout: layout, guides: g, pixelsPerPoint: ppp), outline: max(1, ppp.rounded()))
      let nv = Int(p.counts.x), lines = nv + Int(p.counts.y), reach = Double(p.reach.x)
      func set(_ axis: Int, _ v: Double) -> Bool {
        let k = Int(max(v, 0)) / GuideParameters.cellSize
        return k >= 1024 || p.cells[axis * 32 + k / 32] & (1 << UInt32(k % 32)) != 0
      }
      for i in 0..<lines {
        let axis = i < nv ? 0 : 1, s = Double(p.lines[i].x)
        var v = (s - reach).rounded(.down) + 0.5
        while v <= s + reach {
          XCTAssertTrue(set(axis, v), "\(w)×\(h) line \(i) at \(s), pixel \(v)")
          v += 1
        }
      }
      var clear = 0
      for x in 0..<w where !set(0, Double(x) + 0.5) { clear += 1 }
      if w <= 4096 { XCTAssertGreaterThan(clear, w / 2, "\(w)×\(h): most columns skip the search") }
    }
  }
}
