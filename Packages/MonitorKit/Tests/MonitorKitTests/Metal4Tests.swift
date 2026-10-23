import Metal
import QuartzCore
import XCTest

@testable import MonitorKit

/// Metal's debug layer allocates inside its own calls, so allocation counts mean
/// nothing under `MTL_DEBUG_LAYER`.
func skipUnderTheDebugLayer() throws {
  if ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] != nil {
    throw XCTSkip("the Metal debug layer allocates inside Metal calls")
  }
}

/// Timing budgets mean nothing under Metal's API or shader validation, which
/// slows encoding and every shader several times; the benchmark classes skip.
func skipTimingUnderValidation() throws {
  let env = ProcessInfo.processInfo.environment
  for name in ["MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"] where env[name].map({ $0 != "0" }) ?? false {
    throw XCTSkip("\(name) is set: GPU and CPU timings are not representative")
  }
}

/// The machine's run queue against its performance cores: (1-minute load average,
/// performance cores). Other agents' builds and test runs push the load past the
/// performance cores, and then this process's encode thread and GPU work share
/// them, so a timing says nothing about MonitorKit.
func machineLoad() -> (load: Double, cores: Int) {
  var load = [0.0, 0.0, 0.0]
  let n = getloadavg(&load, 3)
  var cores: Int32 = 0
  var size = MemoryLayout<Int32>.size
  if sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
    cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
  }
  return (n > 0 ? load[0] : 0, Int(cores))
}

/// For a timing budget that every re-measured round missed: fails on a quiet
/// machine, skips (with the numbers) on one whose load average exceeds its
/// performance cores, where the miss measures the other load. Call it only
/// after the re-measured rounds, so a quiet machine still fails a regression.
func assertWithinBudget(
  _ value: Double, _ budget: Double, _ message: @autoclosure () -> String, file: StaticString = #filePath,
  line: UInt = #line
) throws {
  guard value > budget else { return }
  let (load, cores) = machineLoad()
  if load > Double(cores) {
    throw XCTSkip(
      "\(message()): \(String(format: "%.3g", value)) over the budget of \(String(format: "%.3g", budget)) on a loaded machine (load \(String(format: "%.1f", load)) on \(cores) performance cores)")
  }
  XCTFail("\(message()): \(value) is over the budget of \(budget) (load \(String(format: "%.1f", load)) on \(cores) performance cores)", file: file, line: line)
}

/// Counts differing pixels instead of printing whole images.
func assertSamePixels(
  _ a: [SIMD4<Float>], _ b: [SIMD4<Float>], _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertEqual(a.count, b.count, message, file: file, line: line)
  XCTAssertEqual(zip(a, b).filter { $0 != $1 }.count, 0, "differing pixels \(message)", file: file, line: line)
}

/// The Metal 4 encode path: the classic path's pixels, encode-only into a host
/// `MTL4CommandBuffer`, library-owned tables, uniforms and residency.
final class Metal4Tests: XCTestCase {
  struct Case {
    var name: String
    var frame: MonitorFrame
    var state = MonitorState()
    var output = MonitorOutputColor.signalNative
    var format = MTLPixelFormat.rgba32Float
    var luts = false
    var width = 96
    var height = 54
  }

  static let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
  static let pq = SignalDescription(matrix: .bt2020, encoding: .display(.pq), primaries: .rec2020)
  static let hlg = SignalDescription(matrix: .bt2020, encoding: .display(.hlg), primaries: .rec2020)

  static func luts(_ gpu: TestGPU) throws -> (MonitorLUT, MonitorLUT) {
    (
      try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 1)),
      try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 2))
    )
  }

  /// Tools, false colour, magnification, LUTs, output encodings, display
  /// transforms, clip indicators, layouts and target formats.
  func cases(_ m: TestMTL4) throws -> [Case] {
    func frame(_ layout: PixelLayout = .v210, _ signal: SignalDescription = .rec709, seed: UInt64 = 3) throws -> MonitorFrame {
      try m.frame(PictureTests.picture(layout, width: 192, height: 108, seed: seed), signal: signal)
    }
    var all = MonitorState()
    everyTool(&all)
    var sony = MonitorState()
    sony.falseColor.mode = .sonySLog3
    var zoom = all
    zoom.falseColor.mode = .off
    zoom.geometry.magnification.zoom = 4
    zoom.geometry.magnification.centerX = 0.3
    var clip = MonitorState()
    clip.clipIndicators.enabled = true
    clip.clipIndicators.high = 90
    clip.clipIndicators.low = 10
    var assist = MonitorState()
    assist.displayTransform.mode = .logToRec709
    assist.zebras[0] = ZebraSet(mode: .lowerLimit, level: 70, stage: .source)
    var sdr = MonitorState()
    sdr.displayTransform.mode = .hdrToSDR
    var passthrough = MonitorState()
    passthrough.displayTransform.mode = .hdrPassthrough
    let v210 = try frame()
    return [
      Case(name: "default", frame: v210),
      Case(name: "every tool + LUTs + peaking", frame: v210, state: all, luts: true),
      Case(name: "every tool bgra8", frame: v210, state: all, format: .bgra8Unorm, luts: true),
      Case(name: "every tool bgra8 sRGB", frame: v210, state: all, format: .bgra8Unorm_srgb),
      Case(name: "every tool bgr10a2", frame: v210, state: all, format: .bgr10a2Unorm, luts: true),
      Case(name: "every tool rgba16Float", frame: v210, state: all, format: .rgba16Float),
      Case(name: "magnified + navigator", frame: v210, state: zoom, luts: true, width: 160, height: 90),
      Case(name: "Sony false colour", frame: try frame(.v210, Self.slog3), state: sony),
      Case(name: "clip indicators", frame: try frame(.uyvy8), state: clip),
      Case(name: "S-Log3 display assist", frame: try frame(.p010, Self.slog3), state: assist),
      Case(name: "PQ to SDR", frame: try frame(.v210, Self.pq), state: sdr),
      Case(
        name: "PQ passthrough extended linear", frame: try frame(.v210, Self.pq), state: passthrough,
        output: MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear, headroom: 2), format: .rgba16Float),
      Case(
        name: "HLG source to PQ output", frame: try frame(.nv12, Self.hlg), state: all,
        output: MonitorOutputColor(primaries: .rec2020, encoding: .pq), format: .rgba16Float),
      Case(
        name: "HLG native", frame: try frame(.v210, Self.hlg), state: all, format: .rgba16Float, luts: false),
      Case(name: "bgra8 source", frame: try frame(.bgra8, SignalDescription(range: .full)), state: all),
      Case(name: "half-float source", frame: try frame(.rgba16Float, SignalDescription(range: .full)), state: all),
    ]
  }

  /// Draws `c` on the classic path and on Metal 4 (render, or the compute
  /// variant), twice each, and compares the raw bytes.
  func compare(_ c: Case, _ m: TestMTL4, compute: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
    let gpu = m.gpu
    let classicFeed = gpu.engine.makeFeed(), feed = gpu.engine.makeFeed()
    if c.luts {
      let (a, b) = try Self.luts(gpu)
      classicFeed.burnInLUT = a
      classicFeed.monitorLUT = b
      feed.burnInLUT = a
      feed.monitorLUT = b
    }
    let classicPass = gpu.engine.makePass(), pass = gpu.engine.makePass()
    classicPass.outputColor = c.output
    pass.outputColor = c.output
    let usage: MTLTextureUsage = compute ? [.shaderWrite, .shaderRead] : [.renderTarget, .shaderRead]
    let reference = gpu.texture(c.format, c.width, c.height, usage: usage.union(.renderTarget))
    let target = m.target(c.width, c.height, format: c.format, usage: usage)
    try gpu.run { cb in
      if c.state.focus.enabled { try classicFeed.analyze(c.frame, focus: c.state.focus, into: cb) }
      try classicPass.encode(frame: c.frame, feed: classicFeed, state: c.state, target: reference, into: cb)
    }
    let expected = rawBytes(reference)
    for round in 0..<2 {
      try m.run { s in
        if c.state.focus.enabled { try feed.analyze(c.frame, focus: c.state.focus, into: s) }
        if compute {
          try pass.encodeCompute(frame: c.frame, feed: feed, state: c.state, target: target, into: s)
        } else {
          try pass.encode(frame: c.frame, feed: feed, state: c.state, target: target, into: s)
        }
      }
      let got = rawBytes(target)
      XCTAssertEqual(got.count, expected.count)
      let differing = zip(got, expected).filter { $0 != $1 }.count
      XCTAssertEqual(differing, 0, "\(c.name) round \(round) (\(compute ? "compute" : "render"))", file: file, line: line)
    }
    XCTAssertEqual(pass.status, classicPass.status, c.name, file: file, line: line)
  }

  func testMetal4RenderMatchesClassicBitForBit() throws {
    let m = try requireMTL4()
    for c in try cases(m) { try compare(c, m) }
  }

  /// The compute variant writes what the render pass writes (any non-sRGB format).
  func testComputeVariantMatchesClassicBitForBit() throws {
    let m = try requireMTL4()
    for c in try cases(m) where !c.format.isSRGB { try compare(c, m, compute: true) }
  }

  /// A viewport of a larger target: compute writes only the viewport.
  func testComputeWritesOnlyItsViewport() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass(), reference = gpu.engine.makePass()
    let target = m.target(200, 120, usage: [.shaderWrite, .shaderRead])
    let vp = MonitorViewport(x: 37, y: 21, width: 101, height: 57)
    let sentinel = [Float](repeating: 0.25, count: 200 * 120 * 4)
    sentinel.withUnsafeBytes {
      target.replace(region: MTLRegionMake2D(0, 0, 200, 120), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 200 * 16)
    }
    try m.run { s in
      try feed.analyze(frame, focus: state.focus, into: s)
      try pass.encodeCompute(frame: frame, feed: feed, state: state, target: target, viewport: vp, into: s)
    }
    let got = Pixels(target)
    let alone = try gpu.render(frame, state: state, feed: gpu.engine.makeFeed(), pass: reference, width: 101, height: 57, analyze: true)
    var inside = 0, outside = 0
    for y in 0..<120 {
      for x in 0..<200 {
        let inViewport = x >= 37 && x < 138 && y >= 21 && y < 78
        if inViewport {
          if got[x, y] != alone[x - 37, y - 21] { inside += 1 }
        } else if got[x, y] != SIMD4(repeating: 0.25) {
          outside += 1
        }
      }
    }
    XCTAssertEqual(inside, 0)
    XCTAssertEqual(outside, 0)
  }

  /// Analysis and the compute picture in one host compute encoder, the host's
  /// own style: the analysis's encoder barrier orders the mask.
  func testAnalysisAndComputePictureShareAHostEncoder() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    state.focus.opacity = 1
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let target = m.target(96, 54, usage: [.shaderWrite, .shaderRead])
    for _ in 0..<3 {
      try m.run { s in
        let encoder = try XCTUnwrap(s.commandBuffer.makeComputeCommandEncoder())
        try feed.analyze(frame, focus: state.focus, submission: s, encoder: encoder)
        try pass.encodeCompute(frame: frame, feed: feed, state: state, target: target, submission: s, encoder: encoder)
        encoder.endEncoding()
      }
    }
    XCTAssertTrue(pass.status.active.contains { $0.tool == .focusPeaking })
    let alone = try gpu.render(frame, state: state, width: 96, height: 54, analyze: true)
    assertSamePixels(Pixels(target).values, alone.values)
  }

  /// `prepare` + `draw(with:)` inside one host Metal 4 render pass with depth, several surfaces.
  func testDrawingInsideAHostMetal4RenderPass() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed()
    let passes = [gpu.engine.makePass(), gpu.engine.makePass()]
    let target = m.target(192, 54)
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 192, height: 54, mipmapped: false)
    dd.usage = .renderTarget
    dd.storageMode = .private
    let depth = gpu.device.makeTexture(descriptor: dd)!
    m.resident(depth)
    let format = MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float, depthPixelFormat: .depth32Float)
    try m.run { s in
      try feed.analyze(frame, focus: state.focus, into: s)
      let d = MTL4RenderPassDescriptor()
      d.colorAttachments[0].texture = target
      d.colorAttachments[0].loadAction = .clear
      d.colorAttachments[0].storeAction = .store
      d.depthAttachment.texture = depth
      d.depthAttachment.loadAction = .clear
      d.depthAttachment.storeAction = .dontCare
      let encoder = try XCTUnwrap(s.commandBuffer.makeRenderCommandEncoder(descriptor: d))
      for (i, pass) in passes.enumerated() {
        var st = state
        if i == 1 { st.falseColor.mode = .off }
        try pass.prepare(
          frame: frame, feed: feed, state: st, viewport: MonitorViewport(x: i * 96, width: 96, height: 54),
          target: format, submission: s)
        try pass.draw(with: encoder)
      }
      encoder.endEncoding()
    }
    let got = Pixels(target)
    for i in 0..<2 {
      var st = state
      if i == 1 { st.falseColor.mode = .off }
      let alone = try gpu.render(frame, state: st, width: 96, height: 54, analyze: true)
      var differences = 0
      for y in 0..<54 { for x in 0..<96 where got[x + i * 96, y] != alone[x, y] { differences += 1 } }
      XCTAssertEqual(differences, 0, "surface \(i)")
    }
  }

  /// Four feeds, two surfaces each, eight viewports of one target in one Metal 4
  /// command buffer: each equals its surface drawn alone on the classic path.
  func testFourFeedsTwoSurfacesEachInOneMetal4CommandBuffer() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let size = 96
    var feeds: [(MonitorFrame, MonitorFeed)] = []
    for i in 0..<4 {
      let picture = SyntheticFrame.neutral(.v210, width: 192, height: 108) { x, _ in x < 40 + i * 30 ? 200 + i * 100 : 800 - i * 50 }
      let frame = try m.frame(picture, signal: .rec709)
      let feed = gpu.engine.makeFeed()
      if i == 1 { feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 9)) }
      if i == 2 { feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 2, seed: 4)) }
      feeds.append((frame, feed))
    }
    func surfaceState(_ feed: Int, _ surface: Int) -> MonitorState {
      var s = MonitorState()
      s.focus.enabled = true
      s.focus.opacity = 1
      if surface == 1 {
        everyTool(&s)
        s.falseColor.mode = feed % 2 == 0 ? .sixBand : .off
        s.geometry.flip = feed == 3 ? .horizontal : .none
      }
      return s
    }
    let passes = (0..<8).map { _ in gpu.engine.makePass() }
    let target = m.target(size * 4, size * 2)
    // Several frames, so the masks, tables and uniform slots are reused across submissions.
    for _ in 0..<3 {
      try m.run { s in
        for (frame, feed) in feeds { try feed.analyze(frame, focus: surfaceState(0, 0).focus, into: s) }
        for i in 0..<8 {
          let (frame, feed) = feeds[i / 2]
          let viewport = MonitorViewport(x: (i % 4) * size, y: (i / 4) * size, width: size, height: size)
          try passes[i].encode(
            frame: frame, feed: feed, state: surfaceState(i / 2, i % 2), target: target, viewport: viewport,
            clear: i == 0, into: s)
        }
      }
    }
    let combined = Pixels(target)
    for i in 0..<8 {
      let (frame, feed) = feeds[i / 2]
      let alone = try gpu.render(frame, state: surfaceState(i / 2, i % 2), feed: feed, width: size, height: size, analyze: true)
      var differences = 0
      for y in 0..<size {
        for x in 0..<size where combined[x + (i % 4) * size, y + (i / 4) * size] != alone[x, y] { differences += 1 }
      }
      XCTAssertEqual(differences, 0, "surface \(i)")
    }
    XCTAssertNotEqual(combined[size / 2, size / 2], combined[size + size / 2, size / 2])
  }

  /// Uniforms through a host allocator: same pixels, no ring.
  func testHostUniformAllocator() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let allocator = TestUniformAllocator(gpu.device, residency: m.host)
    let frame = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let target = m.target(96, 54)
    for _ in 0..<2 {
      allocator.reset()
      try m.run(uniforms: allocator) { s in
        try feed.analyze(frame, focus: state.focus, into: s)
        try pass.encode(frame: frame, feed: feed, state: state, target: target, into: s)
      }
    }
    // Two pictures and one analysis: the second frame is the same one, already analysed.
    XCTAssertEqual(allocator.allocations, 3)
    print(
      "BENCH Metal 4 uniform bytes per encode: picture \(MonitorPass.uniformLength) (pass parameters \(MemoryLayout<PassParameters>.stride), guides \(MemoryLayout<GuideParameters>.stride)), analysis \(MonitorFeed.uniformLength)"
    )
    XCTAssertNil(pass.ring.buffer)
    XCTAssertNil(feed.ring.buffer)
    XCTAssertEqual(pass.persistentMemoryBytes, 0)
    let alone = try gpu.render(frame, state: state, width: 96, height: 54, analyze: true)
    assertSamePixels(Pixels(target).values, alone.values)
  }

  /// Three submissions in flight, each with different uniforms (a slider being
  /// dragged): no slot is rewritten while a submission that reads it is on the
  /// GPU, so every target shows its own parameters.
  func testUniformRingNeverOverwritesASlotInFlight() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    func state(_ i: Int) -> MonitorState {
      var s = MonitorState()
      s.display.brightness = Double(i % 7) * 0.05 - 0.15
      s.zebras[0] = ZebraSet(mode: .lowerLimit, level: 40 + Double(i % 11) * 5, stage: .source)
      return s
    }
    let rounds = 24
    var expected: [[SIMD4<Float>]] = []
    let reference = gpu.engine.makePass()
    for i in 0..<rounds { expected.append(try gpu.render(frame, state: state(i), pass: reference, width: 96, height: 54).values) }
    // Both completion contracts: reported completions, and index + frames in flight.
    for reported in [true, false] {
      let targets = (0..<rounds).map { _ in m.target(96, 54) }
      let inFlight = DispatchSemaphore(value: gpu.engine.framesInFlight)
      for i in 0..<rounds {
        // The host's frames-in-flight limit: at most three submissions on the GPU.
        inFlight.wait()
        let p = m.begin()
        let submission =
          reported
          ? p.submission
          : MonitorSubmission(
            commandBuffer: p.commandBuffer, index: p.submission.index, framesInFlight: gpu.engine.framesInFlight)
        // Make the GPU slower than the CPU, so submissions really overlap.
        for _ in 0..<7 { try pass.encode(frame: frame, feed: feed, state: state(i), target: targets[i], into: submission) }
        m.commit(p) { _ in inFlight.signal() }
      }
      m.drain()
      for i in 0..<rounds { assertSamePixels(Pixels(targets[i]).values, expected[i], "submission \(i), reported \(reported)") }
      XCTAssertEqual(pass.ring.slots, gpu.engine.framesInFlight, "the ring never needed to grow")
    }
  }

  /// Ring slot choice on its own: never a slot whose last reader is in flight;
  /// grows only when every slot is; steady state writes nothing.
  func testUniformRingSlotChoice() throws {
    let m = try requireMTL4()
    let engine = m.gpu.engine
    let cb = m.gpu.device.makeCommandBuffer()!
    var ring = MonitorUniformRing(slotLength: 100, label: "test ring")
    XCTAssertEqual(ring.slotLength, 256)
    func s(_ index: UInt64, _ completed: UInt64) -> MonitorSubmission {
      MonitorSubmission(commandBuffer: cb, index: index, completedIndex: completed)
    }
    var addresses: [UInt64: UInt64] = [:]
    // Changing every submission with three in flight: three slots, round robin.
    for i: UInt64 in 1...12 {
      let slot = try ring.slot(for: s(i, i > 3 ? i - 3 : 0), generation: i, engine: engine)
      XCTAssertNotNil(slot.contents)
      addresses[i] = slot.address
      if i > 1 { XCTAssertNotEqual(slot.address, addresses[i - 1]) }
      if i > 2 { XCTAssertNotEqual(slot.address, addresses[i - 2]) }
    }
    XCTAssertEqual(ring.slots, 3)
    let writes = ring.writes
    // Unchanged: the same slot, nothing written, however many submissions.
    for i: UInt64 in 13...40 {
      let slot = try ring.slot(for: s(i, i - 3), generation: 12, engine: engine)
      XCTAssertNil(slot.contents)
      XCTAssertEqual(slot.address, addresses[12])
    }
    XCTAssertEqual(ring.writes, writes)
    // Nothing completes: the ring grows rather than overwrite.
    let first = try ring.slot(for: s(41, 0), generation: 100, engine: engine)
    let second = try ring.slot(for: s(41, 0), generation: 101, engine: engine)
    let third = try ring.slot(for: s(41, 0), generation: 102, engine: engine)
    XCTAssertGreaterThan(ring.slots, 3)
    XCTAssertEqual(Set([first.address, second.address, third.address]).count, 3)
    ring.retire(to: engine.residency)
  }

  /// Every allocation the library owns or reads for the host is in the residency
  /// set; replaced ones leave it once their last submission completes; steady
  /// state commits nothing.
  func testResidencySetContents() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let r = gpu.engine.residency
    XCTAssertTrue(r.contains(gpu.engine.emptyPacked))
    XCTAssertTrue(r.contains(gpu.engine.emptyFloat))
    XCTAssertTrue(r.contains(gpu.engine.emptyLUT))
    let small = try m.frame(PictureTests.picture(width: 96, height: 54), signal: .rec709)
    let large = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let (a, b) = try Self.luts(gpu)
    var feed: MonitorFeed? = gpu.engine.makeFeed()
    var pass: MonitorPass? = gpu.engine.makePass()
    feed!.burnInLUT = a
    feed!.monitorLUT = b
    let target = m.target(96, 54)
    func frame(_ f: MonitorFrame) throws {
      try m.run { s in
        try feed!.analyze(f, focus: state.focus, into: s)
        try pass!.encode(frame: f, feed: feed!, state: state, target: target, into: s)
      }
    }
    try frame(small)
    let firstMask = try XCTUnwrap(feed!.focusMask)
    let feedRing = try XCTUnwrap(feed!.ring.buffer), passRing = try XCTUnwrap(pass!.ring.buffer)
    for allocation in [firstMask, feedRing, passRing, a.texture, b.texture] as [any MTLAllocation] {
      XCTAssertTrue(r.contains(allocation))
    }
    XCTAssertFalse(r.contains(target), "host textures are the host's")
    // Steady state: no residency commit.
    let commits = r.commitCount
    for _ in 0..<5 { try frame(small) }
    XCTAssertEqual(r.commitCount, commits)
    // A size change replaces the mask; a LUT change replaces a LUT. Both stay
    // resident until the submission that last used them completes.
    try frame(large)
    feed!.burnInLUT = nil
    try frame(large)
    XCTAssertFalse(feed!.focusMask === firstMask)
    try frame(large)  // observes the completion of the earlier submissions
    XCTAssertFalse(r.contains(firstMask), "the replaced mask left the set")
    XCTAssertFalse(r.contains(a.texture), "the replaced LUT left the set")
    XCTAssertTrue(r.contains(b.texture))
    // Freeze planes join the set; releasing them retires them.
    var frozen: MonitorFrame?
    try m.run { s in frozen = try feed!.freeze(large, into: s) }
    let plane = try XCTUnwrap(frozen?.packed)
    XCTAssertTrue(r.contains(plane))
    feed!.unfreeze(releasingMemory: true)
    frozen = nil
    try m.run { s in r.observe(s) }
    try m.run { s in r.observe(s) }
    XCTAssertFalse(r.contains(plane))
    // A feed and pass dropped while their work may be in flight hand their resources over.
    let lastMask = try XCTUnwrap(feed!.focusMask)
    let lastFeedRing = try XCTUnwrap(feed!.ring.buffer), lastPassRing = try XCTUnwrap(pass!.ring.buffer)
    let p = m.begin()
    try feed!.analyze(large, focus: state.focus, into: p.submission)
    try pass!.encode(frame: large, feed: feed!, state: state, target: target, into: p.submission)
    feed = nil
    pass = nil
    XCTAssertTrue(r.contains(lastMask))
    XCTAssertTrue(r.contains(lastPassRing))
    m.commit(p)
    m.drain()
    try m.run { s in r.observe(s) }
    for allocation in [lastMask, lastFeedRing, lastPassRing, b.texture] as [any MTLAllocation] {
      XCTAssertFalse(r.contains(allocation))
    }
    XCTAssertTrue(r.contains(gpu.engine.emptyLUT))
  }

  /// A LUT shared by two feeds stays resident until both release it.
  func testSharedLUTResidencyIsCounted() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let r = gpu.engine.residency
    let lut = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 9, seed: 5))
    let frame = try m.frame(PictureTests.picture(width: 48, height: 27), signal: .rec709)
    let feeds = [gpu.engine.makeFeed(), gpu.engine.makeFeed()]
    let pass = gpu.engine.makePass()
    let target = m.target(48, 27)
    for f in feeds { f.burnInLUT = lut }
    try m.run { s in for f in feeds { try pass.encode(frame: frame, feed: f, state: MonitorState(), target: target, into: s) } }
    XCTAssertTrue(r.contains(lut.texture))
    feeds[0].burnInLUT = nil
    for _ in 0..<3 { try m.run { s in try pass.encode(frame: frame, feed: feeds[0], state: MonitorState(), target: target, into: s) } }
    XCTAssertTrue(r.contains(lut.texture), "feed 1 still reads it")
    feeds[1].burnInLUT = nil
    for _ in 0..<3 { try m.run { s in try pass.encode(frame: frame, feed: feeds[1], state: MonitorState(), target: target, into: s) } }
    XCTAssertFalse(r.contains(lut.texture))
    // A feed only ever drawn (never analysed) releases its LUT when it goes away.
    let pendingBefore = r.pendingReleaseCount
    var drawn: MonitorFeed? = gpu.engine.makeFeed()
    drawn!.monitorLUT = lut
    try m.run { s in try pass.encode(frame: frame, feed: drawn!, state: MonitorState(), target: target, into: s) }
    XCTAssertTrue(r.contains(lut.texture))
    drawn = nil
    for _ in 0..<2 { try m.run { s in r.observe(s) } }
    XCTAssertFalse(r.contains(lut.texture))
    XCTAssertLessThanOrEqual(r.pendingReleaseCount, pendingBefore)
  }

  /// Freeze on Metal 4: the frozen copy draws exactly like the live frame, in its
  /// own submission or the same one as the draw; re-freezing reuses the planes.
  func testFreezeOnMetal4() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    var state = MonitorState()
    everyTool(&state)
    for layout in FreezeTests.layouts {
      let live = try m.frame(
        SyntheticFrame.random(layout, width: 70, height: 38, seed: 21), signal: SignalDescription(range: layout.isRGB ? .full : .legal))
      let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
      let target = m.target(50, 30)
      var frozen: MonitorFrame?
      // Freeze and draw in one submission: the producer barrier orders the copy.
      try m.run { s in
        frozen = try feed.freeze(live, into: s)
        try feed.analyze(frozen!, focus: state.focus, into: s)
        try pass.encode(frame: frozen!, feed: feed, state: state, target: target, into: s)
      }
      let expected = try gpu.render(live, state: state, width: 50, height: 30, analyze: true)
      assertSamePixels(Pixels(target).values, expected.values, "\(layout)")
      // Re-freeze a different picture into the same planes while the old one may still be read.
      let created = gpu.engine.resourcesCreated
      let other = try m.frame(
        SyntheticFrame.random(layout, width: 70, height: 38, seed: 22), signal: SignalDescription(range: layout.isRGB ? .full : .legal))
      try m.run { s in
        try pass.encode(frame: frozen!, feed: feed, state: state, target: target, into: s)
        frozen = try feed.freeze(other, into: s)
        try feed.analyze(frozen!, focus: state.focus, into: s)
        try pass.encode(frame: frozen!, feed: feed, state: state, target: target, into: s)
      }
      XCTAssertEqual(gpu.engine.resourcesCreated, created, "\(layout) planes reused")
      let expectedOther = try gpu.render(other, state: state, width: 50, height: 30, analyze: true)
      assertSamePixels(Pixels(target).values, expectedOther.values, "\(layout) re-freeze")
    }
  }

  /// Picture drawables are `framebufferOnly`: the render path draws into them
  /// directly, in every picture format (the layer formats of `MonitorLayerColor`).
  func testDrawsIntoFramebufferOnlyDrawables() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 192, height: 108), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed()
    for format in [MTLPixelFormat.bgr10a2Unorm, .rgba16Float, .bgra8Unorm] {
      try gpu.engine.prepare(pixelFormat: format, layouts: [.v210])
      let layer = CAMetalLayer()
      layer.device = gpu.device
      layer.pixelFormat = format
      layer.framebufferOnly = true
      layer.drawableSize = CGSize(width: 160, height: 90)
      m.queue.addResidencySet(layer.residencySet)
      defer { m.queue.removeResidencySet(layer.residencySet) }
      guard let drawable = layer.nextDrawable() else { throw XCTSkip("no drawable without a window") }
      XCTAssertTrue(drawable.texture.usage == .renderTarget)
      let pass = gpu.engine.makePass()
      try m.run { s in
        try feed.analyze(frame, focus: state.focus, into: s)
        try pass.encode(frame: frame, feed: feed, state: state, target: drawable.texture, into: s)
      }
      XCTAssertTrue(pass.usesSpecializedPipeline)
    }
  }

  /// The library encodes only: the host can keep encoding, end and commit the
  /// command buffer afterwards (the library ending or committing it would fail
  /// validation or the host's own end).
  func testEncodeNeverEndsOrCommits() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 96, height: 54), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let target = m.target(96, 54)
    let compute = m.target(96, 54, usage: [.shaderWrite, .shaderRead])
    try m.run { s in
      try feed.analyze(frame, focus: state.focus, into: s)
      _ = try feed.freeze(frame, into: s)
      try pass.encode(frame: frame, feed: feed, state: state, target: target, into: s)
      try pass.encodeCompute(frame: frame, feed: feed, state: state, target: compute, into: s)
      // The host's own work after the library's, in the same command buffer.
      let e = try XCTUnwrap(s.commandBuffer.makeComputeCommandEncoder())
      e.endEncoding()
    }
  }

  /// MTL4Compiler with `MonitorShaders.libraryDescriptor` compiles the fused
  /// sources to the same results as the device compiler (LUTProcessor's case).
  func testMTL4CompilerBuildsTheFusedSourcesIdentically() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let compiler = try gpu.device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let library = try compiler.makeLibrary(
      descriptor: try MonitorShaders.libraryDescriptor(parts: [.lut, .decode], extra: TestGPU.kernels))
    let function = MTL4LibraryFunctionDescriptor()
    function.name = "test_hostOutput"
    function.library = library
    let descriptor = MTL4ComputePipelineDescriptor()
    descriptor.computeFunctionDescriptor = function
    let pipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
    XCTAssertEqual(MonitorShaders.compileOptions.mathMode, .safe)
    let frame = try m.frame(PictureTests.picture(width: 64, height: 32), signal: .rec709)
    let (lut, _) = try Self.luts(gpu)
    gpu.engine.residency.add(lut.texture)
    defer { gpu.engine.residency.retire(nil, resident: lut.texture, after: 0) }
    func run(_ state: MTLComputePipelineState, classic: Bool) throws -> [UInt8] {
      let out = classic
        ? gpu.texture(.rgba32Float, 64, 32, usage: [.shaderWrite, .shaderRead])
        : m.target(64, 32, usage: [.shaderWrite, .shaderRead])
      let frameParameters = frame.parameters, lutParameters = lut.parameters, disabled = LUTParameters.disabled
      if classic {
        gpu.run { cb in
          let e = cb.makeComputeCommandEncoder()!
          e.setComputePipelineState(state)
          e.setTexture(frame.packed, index: 0)
          e.setTexture(gpu.engine.emptyFloat, index: 1)
          e.setTexture(gpu.engine.emptyFloat, index: 2)
          e.setTexture(lut.texture, index: 3)
          e.setTexture(gpu.engine.emptyLUT, index: 4)
          e.setTexture(out, index: 5)
          var f = frameParameters, l = lutParameters, d = disabled
          e.setBytes(&f, length: MemoryLayout<FrameParameters>.stride, index: 0)
          e.setBytes(&l, length: MemoryLayout<LUTParameters>.stride, index: 1)
          e.setBytes(&d, length: MemoryLayout<LUTParameters>.stride, index: 2)
          e.dispatchThreads(MTLSize(width: 64, height: 32, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
          e.endEncoding()
        }
      } else {
        let allocator = TestUniformAllocator(gpu.device, residency: m.host)
        let table = try gpu.engine.makeArgumentTable(textures: 6, buffers: 3, label: "test")
        try m.run { s in
          let e = try XCTUnwrap(s.commandBuffer.makeComputeCommandEncoder())
          e.setComputePipelineState(state)
          table.setTexture(frame.packed!.gpuResourceID, index: 0)
          table.setTexture(gpu.engine.emptyFloat.gpuResourceID, index: 1)
          table.setTexture(gpu.engine.emptyFloat.gpuResourceID, index: 2)
          table.setTexture(lut.texture.gpuResourceID, index: 3)
          table.setTexture(gpu.engine.emptyLUT.gpuResourceID, index: 4)
          table.setTexture(out.gpuResourceID, index: 5)
          let u = allocator.allocateUniforms(length: 768)
          store(frameParameters, u.contents, 0)
          store(lutParameters, u.contents, 256)
          store(disabled, u.contents, 512)
          table.setAddress(u.gpuAddress, index: 0)
          table.setAddress(u.gpuAddress + 256, index: 1)
          table.setAddress(u.gpuAddress + 512, index: 2)
          e.setArgumentTable(table)
          e.dispatchThreads(threadsPerGrid: MTLSize(width: 64, height: 32, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
          e.endEncoding()
        }
      }
      return rawBytes(out)
    }
    let a = try run(gpu.hostOutput, classic: true)
    let b = try run(pipeline, classic: false)
    XCTAssertEqual(a, b)
  }

  /// Steady-state Metal 4 encode: no heap allocation by MonitorKit beyond what the
  /// same Metal 4 calls cost a host inline; `prepare` and uniform writes allocate nothing.
  func testSteadyStateMetal4EncodeMakesNoHeapAllocations() throws {
    try skipUnderTheDebugLayer()
    let m = try requireMTL4()
    let gpu = m.gpu
    var frame = try m.frame(PictureTests.picture(width: 384, height: 216), signal: .rec709)
    let feed = gpu.engine.makeFeed()
    (feed.burnInLUT, feed.monitorLUT) = try Self.luts(gpu)
    var state = MonitorState()
    everyTool(&state)
    let pass = gpu.engine.makePass(), hostPass = gpu.engine.makePass()
    let target = m.target(192, 108, format: .bgra8Unorm)
    let compute = m.target(192, 108, format: .bgra8Unorm, usage: [.shaderWrite, .shaderRead])
    let format = MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm)
    let vp = MonitorViewport(width: 192, height: 108)
    for _ in 0..<4 {
      try m.run { s in
        try feed.analyze(frame, focus: state.focus, into: s)
        try pass.encode(frame: frame, feed: feed, state: state, target: target, into: s)
        try pass.encodeCompute(frame: frame, feed: feed, state: state, target: compute, into: s)
        try hostPass.prepare(frame: frame, feed: feed, state: state, viewport: vp, target: format, submission: s)
      }
    }
    let pipeline = try XCTUnwrap(pass.currentRenderPipeline)
    let table = try gpu.engine.makeArgumentTable(textures: 7, buffers: 5, label: "control")
    let control = MTL4RenderPassDescriptor()
    control.colorAttachments[0].storeAction = .store
    let ringWrites = (pass.ring.writes, feed.ring.writes)
    let focusPipeline = try gpu.engine.focusPipeline(.init(layout: 0, burnInLUT: false, monitorLUT: false))
    let computePipeline = try XCTUnwrap(pass.currentComputePipeline)
    var library: [Int] = [], inline: [Int] = [], analysis: [Int] = [], inlineAnalysis: [Int] = []
    var prepare: [Int] = [], computed: [Int] = [], inlineCompute: [Int] = []
    for i in 0..<30 {
      // A new picture each frame, so every analysis really runs.
      frame.id = 1 << 40 + UInt64(i)
      try m.run { s in
        guard let n = try AllocationCounter.measure({ try feed.analyze(frame, focus: state.focus, into: s) }) else {
          throw XCTSkip("malloc_logger is unavailable")
        }
        analysis.append(n)
        let feedAddress = feed.ring.buffer!.gpuAddress
        // The same Metal 4 calls a host would make for one dispatch.
        func dispatch(
          _ pipeline: MTLComputePipelineState, textures: Int, buffers: Int, visibility: MTL4VisibilityOptions = []
        ) {
          let e = s.commandBuffer.makeComputeCommandEncoder()!
          e.barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .dispatch, visibilityOptions: visibility)
          e.setComputePipelineState(pipeline)
          var i = 0
          while i < textures {
            table.setTexture((i == 6 ? compute : gpu.engine.emptyFloat).gpuResourceID, index: i)
            i += 1
          }
          i = 0
          while i < buffers {
            table.setAddress(feedAddress + UInt64(i * 256), index: i)
            i += 1
          }
          e.setArgumentTable(table)
          e.dispatchThreadgroups(
            threadgroupsPerGrid: MTLSize(width: 24, height: 14, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
          e.endEncoding()
        }
        inlineAnalysis.append(AllocationCounter.measure { dispatch(focusPipeline, textures: 6, buffers: 4) }!)
        // A command buffer's first render encoder does one-time setup; keep it out of both counts.
        control.colorAttachments[0].texture = target
        s.commandBuffer.makeRenderCommandEncoder(descriptor: control)!.endEncoding()
        library.append(try AllocationCounter.measure {
          try pass.encode(frame: frame, feed: feed, state: state, target: target, into: s)
        }!)
        let address = pass.ring.buffer!.gpuAddress
        inline.append(AllocationCounter.measure {
          control.colorAttachments[0].texture = target
          control.colorAttachments[0].loadAction = .clear
          let e = s.commandBuffer.makeRenderCommandEncoder(descriptor: control)!
          control.colorAttachments[0].texture = nil
          e.barrier(afterQueueStages: .dispatch, beforeStages: .fragment, visibilityOptions: .device)
          e.setRenderPipelineState(pipeline)
          e.setViewport(MTLViewport(originX: 0, originY: 0, width: 192, height: 108, znear: 0, zfar: 1))
          table.setTexture(frame.packed!.gpuResourceID, index: 0)
          table.setTexture(gpu.engine.emptyFloat.gpuResourceID, index: 1)
          table.setTexture(gpu.engine.emptyFloat.gpuResourceID, index: 2)
          table.setTexture(feed.burnInLUT!.texture.gpuResourceID, index: 3)
          table.setTexture(feed.monitorLUT!.texture.gpuResourceID, index: 4)
          table.setTexture(feed.focusMask!.gpuResourceID, index: 5)
          table.setAddress(address, index: 0)
          table.setAddress(address + 256, index: 1)
          table.setAddress(address + 512, index: 2)
          table.setAddress(address + 768, index: 3)
          table.setAddress(address + 2048, index: 4)
          e.setArgumentTable(table, stages: .fragment)
          e.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
          e.endEncoding()
        }!)
        computed.append(try AllocationCounter.measure {
          try pass.encodeCompute(frame: frame, feed: feed, state: state, target: compute, into: s)
        }!)
        inlineCompute.append(
          AllocationCounter.measure { dispatch(computePipeline, textures: 7, buffers: 5, visibility: .device) }!)
        prepare.append(try AllocationCounter.measure {
          try hostPass.prepare(frame: frame, feed: feed, state: state, viewport: vp, target: format, submission: s)
        }!)
      }
    }
    func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
    let encode = median(library), host = median(inline)
    print(
      "BENCH Metal 4 heap allocations (median) per render encode: \(encode), the same Metal 4 calls inline: \(host); compute encode: \(median(computed)), inline: \(median(inlineCompute)); analysis: \(median(analysis)), inline: \(median(inlineAnalysis)); prepare: \(prepare.max()!)"
    )
    XCTAssertEqual(prepare.max(), 0, "prepare allocates in steady state")
    XCTAssertLessThanOrEqual(encode, host, "MonitorKit allocates beyond the Metal 4 calls it makes")
    XCTAssertLessThanOrEqual(median(computed), median(inlineCompute), "compute encode")
    XCTAssertLessThanOrEqual(median(analysis), median(inlineAnalysis), "analysis")
    XCTAssertEqual(pass.ring.writes, ringWrites.0, "steady state writes no uniforms")
    XCTAssertEqual(feed.ring.writes, ringWrites.1, "steady state writes no uniforms")
  }
}
