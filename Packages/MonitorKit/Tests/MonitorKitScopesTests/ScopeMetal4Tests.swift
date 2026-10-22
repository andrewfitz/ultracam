import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// The scopes' Metal 4 encode path: the classic path's bins, statistics, traces
/// and pixels, encode-only into a host `MTL4CommandBuffer`, with library-owned
/// argument tables, uniform rings, residency and barriers.
final class ScopeMetal4Tests: XCTestCase {
  static func luts() throws -> (MonitorLUT, MonitorLUT) {
    let (device, _, _) = try GPU.require()
    let burn = try MonitorLUT(
      device: device, cube: ScopeAccumulationTests.makeCube(size: 17) { SIMD3(pow($0.x, 0.9), $0.y, pow($0.z, 1.1)) })
    let monitor = try MonitorLUT(
      device: device, cube: ScopeAccumulationTests.makeCube(size: 33) { SIMD3($0.y * 0.95, $0.z, $0.x * 0.9 + 0.05) })
    return (burn, monitor)
  }

  /// Every scope kind and mode, on every stage.
  static var settings: [ScopeSettings] {
    var luma = ScopeSettings(kind: .waveform, stage: .source)
    luma.waveformColumns = 256
    luma.waveformLevels = 256
    var parade = ScopeSettings(kind: .waveform, stage: .output)
    parade.waveformMode = .rgbParade
    var ycbcr = ScopeSettings(kind: .waveform, stage: .monitor)
    ycbcr.waveformMode = .ycbcrParade
    var overlay = ScopeSettings(kind: .waveform, stage: .source)
    overlay.waveformMode = .rgbOverlay
    var histogram = ScopeSettings(kind: .histogram, stage: .output)
    histogram.histogramMode = .rgbOverlay
    var histogramParade = ScopeSettings(kind: .histogram, stage: .monitor)
    histogramParade.histogramMode = .rgbParade
    var vector = ScopeSettings(kind: .vectorscope, stage: .monitor)
    vector.vectorscopeZoom = 2
    return [luma, parade, ycbcr, overlay, histogram, histogramParade, ScopeSettings(kind: .histogram), vector,
            ScopeSettings(kind: .vectorscope, stage: .source)]
  }

  static func frames(_ m: ScopeMTL4, width: Int = 320, height: Int = 180) throws -> [TestFrame] {
    let frames = try [
      TestFrame.natural(.v210, width: width, height: height, seed: 5, mirror: false),
      TestFrame.natural(.biplanar(.s420, 10), width: width, height: height, seed: 6, mirror: false),
      TestFrame.natural(.uyvy8, width: width - 2, height: height - 1, seed: 7, mirror: false),
      TestFrame.natural(.bgra8, width: width, height: height, seed: 8),
      TestFrame.natural(.rgba16Float, width: width, height: height, seed: 9),
    ]
    for f in frames { m.resident(f.frame) }
    return frames
  }

  func assertSameAccumulation(
    _ a: ScopeAccumulator, _ b: ScopeAccumulator, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    XCTAssertEqual(a.layout, b.layout, message, file: file, line: line)
    XCTAssertEqual(try readBins(a), try readBins(b), "bins: \(message)", file: file, line: line)
    XCTAssertEqual(statisticsWords(a), statisticsWords(b), "statistics: \(message)", file: file, line: line)
    XCTAssertEqual(a.generation, b.generation, message, file: file, line: line)
    XCTAssertEqual(a.context, b.context, message, file: file, line: line)
    XCTAssertEqual(a.appliedBurnInLUT, b.appliedBurnInLUT, message, file: file, line: line)
    XCTAssertEqual(a.appliedMonitorLUT, b.appliedMonitorLUT, message, file: file, line: line)
  }

  func testAccumulationMatchesClassicBitForBit() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let (burn, monitor) = try Self.luts()
    let allocator = ScopeUniformAllocator(m.device, residency: m.host)
    for frame in try Self.frames(m) {
      for (n, s) in Self.settings.enumerated() {
        let classic = try engine.makeAccumulator(settings: s)
        let own = try engine.makeAccumulator(settings: s)
        let hosted = try engine.makeAccumulator(settings: s)
        let bump = try engine.makeAccumulator(settings: s)
        if n == 1 {
          // The 32-bit device bins.
          for a in [classic, own, hosted, bump] { a.packedBinLimit = 0 }
        }
        for round in 0..<3 {
          try GPU.run { cb in try classic.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: cb) }
          try m.run { s in try own.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: s) }
          try m.run { s in
            let e = try XCTUnwrap(s.commandBuffer.makeComputeCommandEncoder())
            try hosted.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, submission: s, encoder: e)
            e.endEncoding()
          }
          allocator.reset()
          try m.run(uniforms: allocator) { s in
            try bump.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: s)
          }
          let name = "\(frame.frame.layout) \(s.kind) \(s.stage) #\(n) round \(round)"
          try assertSameAccumulation(own, classic, "own encoder, \(name)")
          try assertSameAccumulation(hosted, classic, "host encoder, \(name)")
          try assertSameAccumulation(bump, classic, "host uniforms, \(name)")
        }
      }
    }
    XCTAssertGreaterThan(allocator.allocations, 0)
  }

  /// Twice into one host encoder: the second clear waits for the first finalize.
  func testRepeatedAccumulationsShareAHostEncoder() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try Self.frames(m)[0]
    let a = Self.settings.map { try! engine.makeAccumulator(settings: $0) }
    let b = Self.settings.map { try! engine.makeAccumulator(settings: $0) }
    for _ in 0..<2 {
      try GPU.run { cb in for x in a { try x.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) } }
    }
    try m.run { s in
      let e = try XCTUnwrap(s.commandBuffer.makeComputeCommandEncoder())
      for _ in 0..<2 {
        for x in b { try x.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, submission: s, encoder: e) }
      }
      e.endEncoding()
    }
    for (x, y) in zip(a, b) { try assertSameAccumulation(y, x, "\(x.settings.kind) twice in one encoder") }
  }

  func makeGroup(_ engine: ScopeEngine, stage: SignalStage = .output) throws -> ScopeGroup {
    var parade = ScopeSettings(kind: .waveform, stage: stage)
    parade.waveformMode = .rgbParade
    var histogram = ScopeSettings(kind: .histogram, stage: stage)
    histogram.histogramMode = .rgbOverlay
    let vector = ScopeSettings(kind: .vectorscope, stage: stage)
    // Another stage: accumulated on its own beside the fused pass.
    let alone = ScopeSettings(kind: .waveform, stage: .source)
    return try engine.makeGroup([parade, histogram, vector, alone].map { try engine.makeAccumulator(settings: $0) })
  }

  func testGroupMatchesClassicBitForBit() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let (burn, monitor) = try Self.luts()
    for frame in try Self.frames(m) {
      for stage in [SignalStage.source, .output, .monitor] {
        let classic = try makeGroup(engine, stage: stage), own = try makeGroup(engine, stage: stage)
        let hosted = try makeGroup(engine, stage: stage)
        for round in 0..<2 {
          try GPU.run { cb in try classic.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: cb) }
          try m.run { s in try own.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: s) }
          try m.run { s in
            let e = try XCTUnwrap(s.commandBuffer.makeComputeCommandEncoder())
            try hosted.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, submission: s, encoder: e)
            e.endEncoding()
          }
          XCTAssertEqual(own.fusedMemberCount, classic.fusedMemberCount)
          XCTAssertEqual(hosted.fusedMemberCount, classic.fusedMemberCount)
          XCTAssertEqual(classic.fusedMemberCount, 3)
          for i in classic.accumulators.indices {
            let name = "\(frame.frame.layout) \(stage) member \(i) round \(round)"
            XCTAssertEqual(own.isFused(own.accumulators[i]), classic.isFused(classic.accumulators[i]), name)
            try assertSameAccumulation(own.accumulators[i], classic.accumulators[i], "group, \(name)")
            try assertSameAccumulation(hosted.accumulators[i], classic.accumulators[i], "hosted group, \(name)")
          }
        }
      }
    }
  }

  struct DrawCase {
    var name: String
    var settings: ScopeSettings
    var format: MTLPixelFormat
    var output: MonitorOutputColor = .signalNative
    var signal: SignalDescription = .rec709
  }

  static var drawCases: [DrawCase] {
    let s = settings
    var white = s[0]
    white.display.trace = .white
    var colorized = s[7]
    colorized.display.trace = .colorized
    var faint = s[4]
    faint.display.backgroundOpacity = 0.3
    faint.display.graticuleOpacity = 0.6
    faint.display.histogramScale = .logarithmic
    let pq = MonitorOutputColor(primaries: .rec2020, encoding: .pq)
    let hlg = MonitorOutputColor(primaries: .rec2020, encoding: .hlg)
    let linear = MonitorOutputColor(primaries: .displayP3, encoding: .extendedLinear, headroom: 4)
    let pqSignal = SignalDescription(matrix: .bt2020, encoding: .display(.pq), primaries: .rec2020)
    return [
      DrawCase(name: "luma waveform rgba8", settings: s[0], format: .rgba8Unorm),
      DrawCase(name: "parade bgra8 sRGB", settings: s[1], format: .bgra8Unorm_srgb),
      DrawCase(name: "YCbCr parade bgr10a2", settings: s[2], format: .bgr10a2Unorm),
      DrawCase(name: "white trace rgba32Float", settings: white, format: .rgba32Float),
      DrawCase(name: "histogram rgba16Float", settings: s[4], format: .rgba16Float),
      DrawCase(name: "histogram parade rgba8", settings: s[5], format: .rgba8Unorm),
      DrawCase(name: "vectorscope colorized rgba16Float", settings: colorized, format: .rgba16Float),
      DrawCase(name: "faint log histogram PQ", settings: faint, format: .rgba16Float, output: pq),
      DrawCase(name: "parade HLG", settings: s[1], format: .rgba32Float, output: hlg),
      DrawCase(name: "vectorscope extended linear P3", settings: colorized, format: .rgba16Float, output: linear),
      DrawCase(name: "waveform on a PQ-tagged native layer", settings: s[3], format: .rgba16Float, signal: pqSignal),
    ]
  }

  func testDrawsMatchClassicBitForBit() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let (burn, monitor) = try Self.luts()
    let frame = try Self.frames(m, width: 640, height: 360)[0]
    let (width, height) = (300, 200)
    for c in Self.drawCases {
      let accumulator = try engine.makeAccumulator(settings: c.settings)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: cb) }
      let classic = engine.makeRenderer(), renderer = engine.makeRenderer(), host = engine.makeRenderer()
      for r in [classic, renderer, host] { r.setOutputColor(c.output, signal: c.signal) }
      let reference = try makeTexture(m.device, c.format, width, height)
      let target = try m.target(width, height, format: c.format)
      let hostTarget = try m.target(width, height, format: c.format)
      // A second scope composited over the first (clear: false), as a host stacks them.
      let left = MonitorViewport(x: 0, y: 0, width: 180, height: 120, pixelsPerPoint: 2)
      let right = MonitorViewport(x: 120, y: 60, width: 180, height: 140)
      try GPU.run { cb in
        try classic.render(accumulator, target: reference, viewport: left, clear: true, into: cb)
      }
      let reference2 = try makeTexture(m.device, c.format, width, height)
      let classic2 = engine.makeRenderer()
      classic2.setOutputColor(c.output, signal: c.signal)
      try GPU.run { cb in
        try classic.render(accumulator, target: reference2, viewport: left, clear: true, into: cb)
        try classic2.render(accumulator, target: reference2, viewport: right, clear: false, into: cb)
      }
      let renderer2 = engine.makeRenderer()
      renderer2.setOutputColor(c.output, signal: c.signal)
      for round in 0..<2 {
        try m.run { s in try renderer.render(accumulator, target: target, viewport: left, clear: true, into: s) }
        XCTAssertEqual(rawBytes(target), rawBytes(reference), "\(c.name) round \(round)")
        if let a = renderer.traceTexture, let b = classic.traceTexture {
          XCTAssertEqual(try privateBytes(a), try privateBytes(b), "\(c.name) trace")
        }
        XCTAssertEqual(
          try privateBytes(XCTUnwrap(renderer.graticuleTexture)), try privateBytes(XCTUnwrap(classic.graticuleTexture)),
          "\(c.name) graticule")
        try m.run { s in
          try renderer.render(accumulator, target: target, viewport: left, clear: true, into: s)
          try renderer2.render(accumulator, target: target, viewport: right, clear: false, into: s)
        }
        XCTAssertEqual(rawBytes(target), rawBytes(reference2), "\(c.name) composited, round \(round)")
        // Inside the host's own Metal 4 render pass.
        try m.run { s in
          try host.prepare(
            accumulator, viewport: left, target: MonitorRenderTargetFormat(colorPixelFormat: c.format), submission: s)
          let pass = MTL4RenderPassDescriptor()
          pass.colorAttachments[0].texture = hostTarget
          pass.colorAttachments[0].loadAction = .clear
          pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
          pass.colorAttachments[0].storeAction = .store
          let e = try XCTUnwrap(s.commandBuffer.makeRenderCommandEncoder(descriptor: pass))
          // State a host may leave behind: GL-style culling, wireframe, a scissor.
          e.setFrontFacing(.counterClockwise)
          e.setCullMode(.back)
          e.setTriangleFillMode(.lines)
          e.setScissorRect(MTLScissorRect(x: 0, y: 0, width: 4, height: 4))
          host.draw(with: e)
          e.endEncoding()
        }
        XCTAssertEqual(rawBytes(hostTarget), rawBytes(reference), "\(c.name) in a host pass, round \(round)")
      }
    }
  }

  /// Multisampled targets: the own pass into one, and a host pass resolving one
  /// matches the classic path's resolved pixels.
  func testMultisampleTargets() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try Self.frames(m)[3]
    let a = try engine.makeAccumulator(settings: Self.settings[1])
    try GPU.run { cb in try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let msaa = try m.target(256, 128, format: .bgra8Unorm, sampleCount: 4)
    let own = engine.makeRenderer()
    try m.run { s in try own.render(a, target: msaa, clear: true, into: s) }
    XCTAssertTrue(own.isReady)
    let format = MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm, sampleCount: 4)
    let vp = MonitorViewport(width: 256, height: 128)
    let reference = try makeTexture(m.device, .bgra8Unorm, 256, 128)
    let classic = engine.makeRenderer()
    try GPU.run { cb in
      try classic.prepare(a, viewport: vp, target: format, into: cb)
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = msaa
      pass.colorAttachments[0].resolveTexture = reference
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      pass.colorAttachments[0].storeAction = .multisampleResolve
      let e = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
      classic.draw(with: e)
      e.endEncoding()
    }
    let resolved = try m.target(256, 128, format: .bgra8Unorm)
    let host = engine.makeRenderer()
    try m.run { s in
      try host.prepare(a, viewport: vp, target: format, submission: s)
      let pass = MTL4RenderPassDescriptor()
      pass.colorAttachments[0].texture = msaa
      pass.colorAttachments[0].resolveTexture = resolved
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      pass.colorAttachments[0].storeAction = .multisampleResolve
      let e = try XCTUnwrap(s.commandBuffer.makeRenderCommandEncoder(descriptor: pass))
      host.draw(with: e)
      e.endEncoding()
    }
    XCTAssertEqual(rawBytes(resolved), rawBytes(reference), "4× MSAA resolve")
  }

  /// A frame changes every submission with three in flight: each one's bins
  /// (copied out by the host after a consumer barrier) and drawn scopes match
  /// the classic path's for its frame, so no accumulation, resolve or draw ever
  /// overlaps one it depends on.
  func testEveryFrameChangesWithThreeSubmissionsInFlight() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frames = try [
      TestFrame.natural(.v210, width: 960, height: 540, seed: 11, mirror: false),
      TestFrame.natural(.v210, width: 960, height: 540, seed: 12, mirror: false),
    ]
    for f in frames { m.resident(f.frame) }
    let viewports = (0..<4).map { MonitorViewport(x: ($0 % 2) * 256, y: ($0 / 2) * 128, width: 256, height: 128) }
    // The classic path's bins and picture for each frame.
    var expectedBins: [[[UInt32]]] = [], expectedPixels: [[UInt8]] = []
    let classic = try makeGroup(engine)
    let classicRenderers = classic.accumulators.map { _ in engine.makeRenderer() }
    for f in frames {
      let target = try makeTexture(m.device, .rgba8Unorm, 512, 256)
      try GPU.run { cb in
        try classic.accumulate(f.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        for (i, a) in classic.accumulators.enumerated() {
          try classicRenderers[i].render(a, target: target, viewport: viewports[i], clear: i == 0, into: cb)
        }
      }
      expectedBins.append(try classic.accumulators.map { try readBins($0) })
      expectedPixels.append(rawBytes(target))
    }
    let group = try makeGroup(engine)
    let renderers = group.accumulators.map { _ in engine.makeRenderer() }
    let submissions = 18
    let targets = try (0..<submissions).map { _ in try m.target(512, 256, format: .rgba8Unorm) }
    let copies = (0..<submissions).map { _ in
      group.accumulators.map { m.device.makeBuffer(length: $0.bins.length, options: .storageModeShared)! }
    }
    for c in copies { for b in c { m.resident(b) } }
    let inFlight = DispatchSemaphore(value: 3)
    for n in 0..<submissions {
      inFlight.wait()
      let p = m.begin()
      let s = p.submission
      let f = frames[n % 2]
      try group.accumulate(f.frame, burnInLUT: nil, monitorLUT: nil, into: s)
      for (i, a) in group.accumulators.enumerated() {
        try renderers[i].render(a, target: targets[n], viewport: viewports[i], clear: i == 0, into: s)
      }
      let e = try XCTUnwrap(s.commandBuffer.makeComputeCommandEncoder())
      e.barrier(afterQueueStages: .dispatch, beforeStages: .blit, visibilityOptions: .device)
      for (i, a) in group.accumulators.enumerated() {
        e.copy(sourceBuffer: a.bins, sourceOffset: 0, destinationBuffer: copies[n][i], destinationOffset: 0, size: a.bins.length)
      }
      e.endEncoding()
      m.commit(p) { _ in inFlight.signal() }
    }
    m.drain()
    for n in 0..<submissions {
      for (i, a) in group.accumulators.enumerated() {
        let words = a.layout.bytesPerBin == 2
          ? (0..<a.layout.binCount).map { UInt32(copies[n][i].contents().load(fromByteOffset: $0 * 2, as: UInt16.self)) }
          : (0..<a.layout.binCount).map { copies[n][i].contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
        XCTAssertEqual(words, expectedBins[n % 2][i], "submission \(n) member \(i)")
      }
      XCTAssertEqual(rawBytes(targets[n]), expectedPixels[n % 2], "submission \(n) pixels")
    }
  }

  func testResidencyAndDeferredRelease() throws {
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let r = engine.residency
    let (burn, monitor) = try Self.luts()
    let frame = try Self.frames(m)[0]
    let target = try m.target(256, 128, format: .rgba8Unorm)
    var settings = ScopeSettings(kind: .waveform, stage: .monitor)
    settings.waveformColumns = 256
    let a = try engine.makeAccumulator(settings: settings)
    let renderer = engine.makeRenderer()
    try m.run { s in
      try a.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: s)
      try renderer.render(a, target: target, into: s)
    }
    for (name, allocation) in [
      ("bins", a.bins as any MTLAllocation), ("statistics", a.statisticsBuffer), ("burn-in LUT", burn.texture),
      ("monitor LUT", monitor.texture), ("uniforms", try XCTUnwrap(a.ring.buffer)),
      ("trace", try XCTUnwrap(renderer.traceTexture)), ("graticule", try XCTUnwrap(renderer.graticuleTexture)),
      ("draw uniforms", try XCTUnwrap(renderer.ring.buffer)), ("graticule uniforms", try XCTUnwrap(renderer.graticuleRing.buffer)),
      ("placeholder", engine.placeholderLUT),
    ] {
      XCTAssertTrue(r.contains(allocation), "\(name) is resident")
    }
    // Steady state commits nothing.
    let commits = r.commitCount
    for _ in 0..<5 {
      try m.run { s in
        try a.accumulate(frame.frame, burnInLUT: burn, monitorLUT: monitor, into: s)
        try renderer.render(a, target: target, into: s)
      }
    }
    XCTAssertEqual(r.commitCount, commits, "no residency commit in steady state")

    // New bins: the old ones stay resident until the submission that used them completes.
    let oldBins = a.bins, oldTrace = try XCTUnwrap(renderer.traceTexture)
    a.settings.waveformColumns = 512
    let p = m.begin()
    try a.accumulate(frame.frame, burnInLUT: burn, monitorLUT: nil, into: p.submission)
    try renderer.render(a, target: target, into: p.submission)
    XCTAssertFalse(a.bins === oldBins)
    XCTAssertTrue(r.contains(oldBins), "replaced bins stay resident while in flight")
    XCTAssertTrue(r.contains(oldTrace), "the replaced trace too")
    XCTAssertTrue(r.contains(monitor.texture), "an unused LUT leaves only after its last use")
    m.commit(p)
    m.drain()
    r.release(through: m.completedIndex)
    XCTAssertFalse(r.contains(oldBins), "released once complete")
    XCTAssertFalse(r.contains(oldTrace))
    XCTAssertFalse(r.contains(monitor.texture))
    XCTAssertTrue(r.contains(a.bins))

    // Deinit with work in flight: everything stays until the submission completes.
    var doomed: ScopeAccumulator? = try engine.makeAccumulator(settings: settings)
    var doomedRenderer: ScopeRenderer? = engine.makeRenderer()
    let q = m.begin()
    try doomed!.accumulate(frame.frame, burnInLUT: burn, monitorLUT: nil, into: q.submission)
    try doomedRenderer!.render(doomed!, target: target, into: q.submission)
    let bins = doomed!.bins, stats = doomed!.statisticsBuffer, trace = try XCTUnwrap(doomedRenderer!.traceTexture)
    doomed = nil
    doomedRenderer = nil
    XCTAssertTrue(r.contains(bins) && r.contains(stats) && r.contains(trace), "alive while in flight")
    XCTAssertTrue(r.contains(burn.texture), "a LUT still used by another accumulator stays")
    m.commit(q)
    m.drain()
    r.release(through: m.completedIndex)
    XCTAssertFalse(r.contains(bins) || r.contains(stats) || r.contains(trace), "released after completion")
    XCTAssertTrue(r.contains(burn.texture), "still counted for the live accumulator")

    // Members only ever accumulated through a group's fused pass are released too.
    var group: ScopeGroup? = try makeGroup(engine)
    try m.run { s in try group!.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: s) }
    XCTAssertEqual(group!.fusedMemberCount, 3)
    XCTAssertNil(group!.accumulators[0].metal4Table, "accumulated only by the fused pass")
    let fusedBins = group!.accumulators[0].bins, groupRing = try XCTUnwrap(group!.ring.buffer)
    XCTAssertTrue(r.contains(fusedBins) && r.contains(groupRing))
    group = nil
    r.release(through: m.completedIndex)
    XCTAssertFalse(r.contains(fusedBins) || r.contains(groupRing), "a fused member's bins and the group's ring leave")
  }

  func testSharesAMonitorEngineResidencySet() throws {
    let m = try requireScopeMTL4()
    let monitorEngine = try MonitorEngine(device: m.device)
    let engine = try ScopeEngine(
      device: m.device, specialization: .synchronous, framesInFlight: 2, residency: monitorEngine.residency)
    XCTAssertTrue(engine.residency === monitorEngine.residency)
    XCTAssertEqual(engine.framesInFlight, 2)
    m.queue.addResidencySet(monitorEngine.residency.set)
    let frame = try Self.frames(m)[0]
    let feed = monitorEngine.makeFeed()
    feed.burnInLUT = try Self.luts().0
    let a = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram, stage: .output))
    let classic = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram, stage: .output))
    for _ in 0..<4 {
      try m.run { s in try a.accumulate(frame.frame, feed: feed, into: s) }
      try GPU.run { cb in try classic.accumulate(frame.frame, feed: feed, into: cb) }
    }
    XCTAssertTrue(monitorEngine.residency.contains(a.bins))
    XCTAssertEqual(a.ring.slots, 2, "framesInFlight slots")
    try assertSameAccumulation(a, classic, "feed overload on a shared residency set")
  }

  /// A frozen frame the host still holds after `unfreeze()` released its planes
  /// is made resident again for the accumulation that reads it, alone and in a
  /// group (it used to read non-resident memory: zeros, silently).
  func testFrozenFrameAccumulatedAfterUnfreezeIsResident() throws {
    let m = try requireScopeMTL4()
    let monitorEngine = try MonitorEngine(device: m.device)
    let engine = try ScopeEngine(device: m.device, specialization: .synchronous, residency: monitorEngine.residency)
    m.queue.addResidencySet(monitorEngine.residency.set)
    let r = monitorEngine.residency
    let live = try Self.frames(m)[0].frame
    let feed = monitorEngine.makeFeed()
    var frozen: MonitorFrame?
    try m.run { s in frozen = try feed.freeze(live, into: s) }
    let shown = try XCTUnwrap(frozen)
    let plane = try XCTUnwrap(shown.packed ?? shown.luma)
    let expected = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram))
    try m.run { s in try expected.accumulate(shown, feed: feed, into: s) }

    feed.unfreeze()
    try m.run { s in r.observe(s) }
    try m.run { s in r.observe(s) }
    XCTAssertFalse(r.contains(plane), "unfreeze released the planes")

    let alone = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram))
    try m.run { s in
      try alone.accumulate(shown, feed: feed, into: s)
      XCTAssertTrue(r.contains(plane), "resident again for the accumulation")
    }
    try assertSameAccumulation(alone, expected, "frozen frame after unfreeze")
    try m.run { s in r.observe(s) }
    try m.run { s in r.observe(s) }
    XCTAssertFalse(r.contains(plane), "and released again once it completed")

    let group = try engine.makeGroup([
      engine.makeAccumulator(settings: ScopeSettings(kind: .histogram)),
      engine.makeAccumulator(settings: ScopeSettings(kind: .vectorscope)),
    ])
    try m.run { s in
      try group.accumulate(shown, feed: feed, into: s)
      XCTAssertTrue(r.contains(plane), "resident again for the group")
    }
    try assertSameAccumulation(group.accumulators[0], expected, "grouped, frozen frame after unfreeze")
  }

  /// The library makes no queue, command buffer, allocator, commit, wait or
  /// handler on either path; checked in the sources, since a command buffer
  /// cannot report it. The only commit is of the residency set (in MonitorKit).
  func testSourcesNeverCreateQueuesCommitOrWait() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Sources/MonitorKitScopes").resolvingSymlinksInPath()
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    XCTAssertGreaterThan(files.count, 8)
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      for banned in [
        "makeBlitCommandEncoder", "waitUntilCompleted", "waitUntilScheduled", "addCompletedHandler",
        "addScheduledHandler", "makeCommandQueue", "makeMTL4CommandQueue", "makeCommandBuffer", "makeCommandAllocator",
        "beginCommandBuffer", "endCommandBuffer", "addFeedbackHandler", "addResidencySet", "useResidencySet",
        "MTLCreateSystemDefaultDevice", "DispatchQueue", "Thread(", "presentDrawable", ".present(", ".commit(",
      ] {
        XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) uses \(banned)")
      }
    }
  }

  /// Steady state on Metal 4: no GPU memory, no residency commits, no ring growth,
  /// and no heap allocation beyond the Metal 4 calls a host would make inline.
  func testSteadyStateMetal4MakesNoAllocations() throws {
    try skipUnderTheDebugLayer()
    let m = try requireScopeMTL4()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try Self.frames(m, width: 640, height: 360)[0]
    let target = try m.target(512, 256, format: .bgra8Unorm)
    let group = try makeGroup(engine)
    let single = try engine.makeAccumulator(settings: Self.settings[7])
    let renderer = engine.makeRenderer(), hostRenderer = engine.makeRenderer()
    let vp = MonitorViewport(width: 512, height: 256)
    let format = MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm)
    let pass = MTL4RenderPassDescriptor()
    pass.colorAttachments[0].storeAction = .store
    let table = try engine.makeArgumentTable(textures: 5, buffers: 15, label: "control")
    var accumulate: [Int] = [], inlineAccumulate: [Int] = [], prepareSame: [Int] = []
    var draw: [Int] = [], inlineDraw: [Int] = [], render: [Int] = []
    let pipeline = try XCTUnwrap(single.kernelPipeline(single.begin(frame.frame, burnInLUT: nil, monitorLUT: nil)))
    var bytes = 0, commits = 0, slots = (0, 0, 0)
    for round in 0..<36 {
      if round == 6 {
        bytes = m.device.currentAllocatedSize
        commits = engine.residency.commitCount
        slots = (single.ring.slots, group.ring.slots, renderer.ring.slots)
      }
      try m.run { s in
        guard
          let n = try AllocationCounter.measure({
            try single.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: s)
          })
        else { throw XCTSkip("malloc_logger is unavailable") }
        accumulate.append(n)
        // The same Metal 4 calls a host makes for one clear, count and finalize.
        let address = single.ring.buffer!.gpuAddress
        inlineAccumulate.append(
          AllocationCounter.measure {
            let e = s.commandBuffer.makeComputeCommandEncoder()!
            e.barrier(afterQueueStages: [.dispatch, .fragment, .blit], beforeStages: .dispatch, visibilityOptions: [])
            var i = 0
            while i < 5 {
              table.setTexture(engine.placeholderPlane.gpuResourceID, index: i)
              i += 1
            }
            i = 0
            while i < 6 {
              table.setAddress(address + UInt64(i * 256), index: i)
              i += 1
            }
            e.setArgumentTable(table)
            i = 0
            while i < 3 {
              e.setComputePipelineState(pipeline)
              table.setAddress(address, index: 3)
              e.dispatchThreads(
                threadsPerGrid: MTLSize(width: 64, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
              e.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
              i += 1
            }
            e.endEncoding()
          }!)
        // Nothing new to show since the last submission: prepare only reads cached state.
        prepareSame.append(
          try AllocationCounter.measure {
            try hostRenderer.prepare(group.accumulators[1], viewport: vp, target: format, submission: s)
          }!)
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        let e = try XCTUnwrap(s.commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        pass.colorAttachments[0].texture = nil
        draw.append(AllocationCounter.measure { hostRenderer.draw(with: e) }!)
        let drawPipeline = try XCTUnwrap(hostRenderer.pipeline)
        inlineDraw.append(
          AllocationCounter.measure {
            e.setRenderPipelineState(drawPipeline)
            e.setViewport(MTLViewport(originX: 0, originY: 0, width: 512, height: 256, znear: 0, zfar: 1))
            table.setAddress(address, index: 0)
            table.setTexture(target.gpuResourceID, index: 0)
            table.setTexture(target.gpuResourceID, index: 1)
            e.setArgumentTable(table, stages: .fragment)
            e.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
          }!)
        e.endEncoding()
        render.append(
          try AllocationCounter.measure {
            try renderer.render(group.accumulators[0], target: target, viewport: vp, clear: true, into: s)
          }!)
        // The next frame's scopes.
        try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: s)
        try renderer.render(group.accumulators[0], target: target, viewport: vp, clear: true, into: s)
        try hostRenderer.prepare(group.accumulators[1], viewport: vp, target: format, submission: s)
      }
    }
    accumulate.removeFirst(6)
    inlineAccumulate.removeFirst(6)
    prepareSame.removeFirst(6)
    draw.removeFirst(6)
    inlineDraw.removeFirst(6)
    render.removeFirst(6)
    func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
    print(
      "BENCH scopes Metal 4 heap allocations (median): accumulate \(median(accumulate)) vs inline \(median(inlineAccumulate)); "
        + "draw \(median(draw)) vs inline \(median(inlineDraw)); unchanged prepare \(prepareSame.max()!); render \(median(render))")
    XCTAssertEqual(prepareSame.max(), 0, "an unchanged prepare allocates nothing")
    XCTAssertLessThanOrEqual(median(accumulate), median(inlineAccumulate), "accumulate allocates beyond its Metal calls")
    XCTAssertLessThanOrEqual(median(draw), median(inlineDraw), "draw allocates beyond its Metal calls")
    XCTAssertEqual(m.device.currentAllocatedSize, bytes, "no GPU allocation")
    XCTAssertEqual(engine.residency.commitCount, commits, "no residency commits")
    XCTAssertEqual(single.ring.slots, slots.0, "no ring growth")
    XCTAssertEqual(group.ring.slots, slots.1)
    XCTAssertEqual(renderer.ring.slots, slots.2)
    XCTAssertEqual(renderer.graticuleRing.writes, 1, "the graticule uniforms are written once")
  }
}
