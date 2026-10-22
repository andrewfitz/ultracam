import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// Resource lifetimes under unretained command buffers, host render passes of
/// any format, and pipelines that are never compiled on a frame.
final class ScopeLifetimeTests: XCTestCase {
  func makeTarget(
    _ format: MTLPixelFormat = .bgra8Unorm, width: Int, height: Int, samples: Int = 1, shared: Bool = true
  ) throws -> MTLTexture {
    let (device, _, _) = try GPU.require()
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = shared && samples == 1 ? .shared : .private
    if samples > 1 {
      d.textureType = .type2DMultisample
      d.sampleCount = samples
    }
    return try XCTUnwrap(device.makeTexture(descriptor: d))
  }

  func pixels(_ t: MTLTexture) -> [SIMD4<UInt8>] {
    var out = [SIMD4<UInt8>](repeating: .zero, count: t.width * t.height)
    out.withUnsafeMutableBytes {
      t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    }
    return out
  }

  // MARK: retirement

  /// Bins, trace and graticule textures replaced while an unretained command
  /// buffer that uses them is still unsubmitted stay alive for
  /// `MonitorFeed.retiredFrames` more encodes, then are released.
  func testReplacedResourcesOutliveUnretainedCommandBuffers() throws {
    let (_, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, mirror: false)
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformLevels = 256
    let accumulator = try engine.makeAccumulator(settings: s)
    let renderer = engine.makeRenderer()
    let target = try makeTarget(width: 640, height: 400)
    var pending: [MTLCommandBuffer] = []
    weak var oldBins: MTLBuffer?, oldTrace: MTLTexture?, oldGraticule: MTLTexture?
    try autoreleasepool {
      let cb = try XCTUnwrap(queue.makeCommandBufferWithUnretainedReferences())
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.render(accumulator, target: target, viewport: MonitorViewport(width: 200, height: 100), into: cb)
      oldBins = accumulator.bins
      oldTrace = renderer.traceTexture
      oldGraticule = renderer.graticuleTexture
      pending.append(cb)
    }
    // New bin shape, trace format and graticule size while that buffer is not even committed.
    accumulator.settings.waveformLevels = 1024
    accumulator.settings.waveformMode = .rgbParade
    try autoreleasepool {
      let cb = try XCTUnwrap(queue.makeCommandBufferWithUnretainedReferences())
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.render(accumulator, target: target, viewport: MonitorViewport(width: 330, height: 170), into: cb)
      pending.append(cb)
    }
    let bins = try XCTUnwrap(oldBins, "replaced bins are still referenced")
    let trace = try XCTUnwrap(oldTrace, "the replaced trace texture is still referenced")
    let graticule = try XCTUnwrap(oldGraticule, "the replaced graticule texture is still referenced")
    XCTAssertFalse(bins === accumulator.bins)
    XCTAssertFalse(trace === renderer.traceTexture)
    XCTAssertFalse(graticule === renderer.graticuleTexture)
    XCTAssertTrue(accumulator.isRetired(bins))
    XCTAssertTrue(renderer.isRetired(trace))
    XCTAssertTrue(renderer.isRetired(graticule))
    XCTAssertEqual(
      accumulator.persistentMemoryBytes, accumulator.bins.allocatedSize + accumulator.statisticsBuffer.allocatedSize,
      "retired bins are transient")
    for cb in pending {
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertNil(cb.error)
    }
    // Held for exactly `retiredFrames` more encodes.
    for encode in 1...MonitorFeed.retiredFrames {
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try renderer.render(accumulator, target: target, viewport: MonitorViewport(width: 330, height: 170), into: cb)
      }
      let held = encode < MonitorFeed.retiredFrames
      XCTAssertEqual(accumulator.isRetired(bins), held, "after \(encode) more accumulations")
      XCTAssertEqual(renderer.isRetired(trace), held, "after \(encode) more prepares")
      XCTAssertEqual(renderer.isRetired(graticule), held, "after \(encode) more prepares")
    }
    XCTAssertEqual(accumulator.retiredResourceCount, 0)
    XCTAssertEqual(renderer.retiredResourceCount, 0)
  }

  /// Settings, scope mode and viewport size change on every frame, with three
  /// unretained command buffers in flight, scopes alone and grouped: every
  /// buffer completes without error (run under MTL_DEBUG_LAYER=1 to have the
  /// validation layer check each access), and the rings never grow.
  func testEveryFrameChangesWithThreeUnretainedFramesInFlight() throws {
    let (_, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.biplanar(.s420, 10), width: 480, height: 270, mirror: false)
    let accumulators = try [ScopeKind.waveform, .histogram, .vectorscope].map {
      try engine.makeAccumulator(settings: ScopeSettings(kind: $0, stage: .source))
    }
    let group = try engine.makeGroup(accumulators)
    let renderers = accumulators.map { _ in engine.makeRenderer() }
    let target = try makeTarget(width: 900, height: 600, shared: false)
    var inFlight: [MTLCommandBuffer] = []
    for i in 0..<36 {
      if inFlight.count == 3 {
        let oldest = inFlight.removeFirst()
        oldest.waitUntilCompleted()
        XCTAssertNil(oldest.error, "frame \(i - 3)")
      }
      accumulators[0].settings.waveformLevels = [256, 512, 1024][i % 3]
      accumulators[0].settings.waveformMode = WaveformMode.allCases[i % 4]
      accumulators[1].settings.histogramBins = [256, 1024][i % 2]
      accumulators[2].settings.vectorscopeSize = [256, 512, 1024][(i / 2) % 3]
      try autoreleasepool {
        let cb = try XCTUnwrap(queue.makeCommandBufferWithUnretainedReferences())
        if i % 2 == 0 {
          try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        } else {
          for a in accumulators { try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
        }
        for (k, renderer) in renderers.enumerated() {
          let viewport = MonitorViewport(x: k * 300, y: 0, width: 200 + (i * 7) % 100, height: 150 + (i * 11) % 300)
          try renderer.render(accumulators[k], target: target, viewport: viewport, into: cb)
        }
        cb.commit()
        inFlight.append(cb)
      }
      for a in accumulators { XCTAssertLessThanOrEqual(a.retiredResourceCount, MonitorFeed.retiredFrames) }
      for r in renderers { XCTAssertLessThanOrEqual(r.retiredResourceCount, 2 * MonitorFeed.retiredFrames) }
    }
    for cb in inFlight {
      cb.waitUntilCompleted()
      XCTAssertNil(cb.error)
    }
  }

  /// A live resize reallocates the graticule texture only every 64 pixels.
  func testLiveResizeRarelyReallocatesTheGraticule() throws {
    let (_, _, engine) = try GPU.require()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .vectorscope))
    let renderer = engine.makeRenderer()
    let target = try makeTarget(width: 1200, height: 800)
    var allocations = 0
    var last: MTLTexture?
    try GPU.run { cb in
      for width in stride(from: 400, through: 655, by: 1) {
        try renderer.render(accumulator, target: target, viewport: MonitorViewport(width: width, height: 300), into: cb)
        if renderer.graticuleTexture !== last {
          allocations += 1
          last = renderer.graticuleTexture
        }
        XCTAssertGreaterThanOrEqual(renderer.graticuleTexture!.width, width)
      }
    }
    XCTAssertLessThanOrEqual(allocations, 5, "256 sizes, 64-pixel steps")
  }

  // MARK: host render passes

  /// Inside a host pass with depth, stencil, a second colour attachment or 4×
  /// MSAA, the scope draws exactly what its own pass draws. Its depth-stencil
  /// state always passes (the host's own `.never` test is replaced), and the
  /// other attachments are left untouched.
  func testDrawsInsideDepthStencilMultisampleAndMultipleAttachmentPasses() throws {
    let (_, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 640, height: 360, mirror: false)
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformMode = .rgbParade
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let viewport = MonitorViewport(x: 20, y: 10, width: 300, height: 180)
    let reference = try makeTarget(width: 340, height: 200)
    try GPU.run { cb in
      try engine.makeRenderer().render(accumulator, target: reference, viewport: viewport, clear: true, into: cb)
    }
    let expected = pixels(reference)

    let (device, _, _) = try GPU.require()
    let never = MTLDepthStencilDescriptor()
    never.depthCompareFunction = .never
    let hostState = try XCTUnwrap(device.makeDepthStencilState(descriptor: never))
    enum Variant: CaseIterable { case depth, depthStencil, stencil, extraColor, multisample, multisampleDepth }
    for variant in Variant.allCases {
      let color = try makeTarget(width: 340, height: 200)
      let pass = MTLRenderPassDescriptor()
      let samples = variant == .multisample || variant == .multisampleDepth ? 4 : 1
      if samples > 1 {
        pass.colorAttachments[0].texture = try makeTarget(width: 340, height: 200, samples: 4)
        pass.colorAttachments[0].resolveTexture = color
        pass.colorAttachments[0].storeAction = .multisampleResolve
      } else {
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].storeAction = .store
      }
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      func depthTexture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 340, height: 200, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        if samples > 1 {
          d.textureType = .type2DMultisample
          d.sampleCount = samples
        }
        return try XCTUnwrap(device.makeTexture(descriptor: d))
      }
      switch variant {
      case .depth, .multisampleDepth: pass.depthAttachment.texture = try depthTexture(.depth32Float)
      case .depthStencil:
        let t = try depthTexture(.depth32Float_stencil8)
        pass.depthAttachment.texture = t
        pass.stencilAttachment.texture = t
      case .stencil: pass.stencilAttachment.texture = try depthTexture(.stencil8)
      case .extraColor:
        let extra = try makeTarget(.rgba8Unorm, width: 340, height: 200)
        pass.colorAttachments[1].texture = extra
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        pass.colorAttachments[1].storeAction = .store
      case .multisample: break
      }
      let format = MonitorRenderTargetFormat(pass)
      XCTAssertEqual(format.sampleCount, samples)
      try engine.prepare(target: format)
      let renderer = engine.makeRenderer()
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      try renderer.prepare(accumulator, viewport: viewport, target: format, into: cb)
      XCTAssertTrue(renderer.isReady, "\(variant)")
      let encoder = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
      if format.depthPixelFormat != .invalid || format.stencilPixelFormat != .invalid {
        encoder.setDepthStencilState(hostState)
      }
      renderer.draw(with: encoder)
      encoder.endEncoding()
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertNil(cb.error, "\(variant)")
      let got = pixels(color)
      let differing = got.indices.filter { got[$0] != expected[$0] }
      XCTAssertTrue(differing.isEmpty, "\(variant): \(differing.count) pixels differ")
      if variant == .extraColor, let extra = pass.colorAttachments[1].texture {
        XCTAssertTrue(pixels(extra).allSatisfy { $0 == SIMD4(51, 102, 153, 255) }, "the extra attachment is untouched")
      }
    }
  }

  /// `render(target:)` into a multisampled texture uses a pipeline with its sample count.
  func testOwnPassIntoAMultisampleTarget() throws {
    let (_, _, engine) = try GPU.require()
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram))
    let frame = try TestFrame.natural(.bgra8, width: 64, height: 64, mirror: false)
    let target = try makeTarget(width: 128, height: 64, samples: 4)
    try engine.prepare(target: MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm, sampleCount: 4))
    let renderer = engine.makeRenderer()
    try GPU.run { cb in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.render(accumulator, target: target, clear: true, into: cb)
    }
    XCTAssertTrue(renderer.isReady)
  }

  // MARK: pipelines

  /// An asynchronous engine never compiles a render pipeline on the calling
  /// thread: the first draw into a format it has not built encodes nothing,
  /// and once the pipeline is built the draw matches a synchronous engine's.
  func testAsynchronousEngineSkipsDrawsUntilItsPipelineIsReady() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let sync = try XCTUnwrap(GPU.synchronousEngine)
    XCTAssertFalse(ScopeEngine.prewarmedPixelFormats.contains(.rgba32Float))
    let frame = try TestFrame.natural(.bgra8, width: 320, height: 180, mirror: false)
    var s = ScopeSettings(kind: .vectorscope, stage: .source)
    s.display.backgroundOpacity = 1
    let target = try makeTarget(.rgba32Float, width: 256, height: 256)
    func render(_ renderer: ScopeRenderer, _ accumulator: ScopeAccumulator) throws -> [SIMD4<Float>] {
      try GPU.run { cb in
        try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try renderer.render(accumulator, target: target, clear: true, into: cb)
      }
      var out = [SIMD4<Float>](repeating: .zero, count: 256 * 256)
      out.withUnsafeMutableBytes {
        target.getBytes($0.baseAddress!, bytesPerRow: 256 * 16, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
      }
      return out
    }
    let renderer = engine.makeRenderer(), accumulator = try engine.makeAccumulator(settings: s)
    var image = try render(renderer, accumulator)
    XCTAssertFalse(renderer.isReady, "the first draw into a new format does not wait for the compiler")
    XCTAssertTrue(image.allSatisfy { $0 == .zero }, "nothing is drawn meanwhile")
    let deadline = Date().addingTimeInterval(20)
    while !renderer.isReady && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
      image = try render(renderer, accumulator)
    }
    XCTAssertTrue(renderer.isReady)
    XCTAssertEqual(image, try render(sync.makeRenderer(), try sync.makeAccumulator(settings: s)))
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty, "\(engine.pipelineBuildFailures)")
  }

  /// With specialization off, a group fuses without anyone calling
  /// `prepare(layouts:)`: the all-tools fused kernels build at init on Metal's
  /// compiler threads, and the group accumulates scope by scope until then.
  func testGeneralEngineFusesWithoutPrepare() throws {
    let (device, queue, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .off)
    let frame = try TestFrame.natural(.v210, width: 320, height: 90, seed: 2, mirror: false)
    let settings = ScopeGroupTests.settings([.waveform, .histogram, .vectorscope])
    let alone = try settings.map { try engine.makeAccumulator(settings: $0) }
    try GPU.run { cb in for a in alone { try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) } }
    let expected = try ScopeGroupTests.result(alone)
    let members = try settings.map { try engine.makeAccumulator(settings: $0) }
    let group = try engine.makeGroup(members)
    let deadline = Date().addingTimeInterval(20)
    repeat {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertEqual(try ScopeGroupTests.result(members), expected)
      if group.fusedMemberCount == 0 { Thread.sleep(forTimeInterval: 0.01) }
    } while group.fusedMemberCount == 0 && Date() < deadline
    XCTAssertEqual(group.fusedMemberCount, 3)
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty, "\(engine.pipelineBuildFailures)")
  }

  /// A render build that fails (a sample count no GPU supports) is recorded
  /// once and never retried: an asynchronous renderer settles on drawing
  /// nothing and `prepare` reports it, instead of asking on every frame.
  func testFailedBuildsAreRecordedAndNotRetried() throws {
    let (device, queue, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    let format = MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm, sampleCount: 3)
    let renderer = engine.makeRenderer()
    let deadline = Date().addingTimeInterval(20)
    var thrown = false
    while !thrown && Date() < deadline {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      do {
        try renderer.prepare(accumulator, viewport: MonitorViewport(width: 64, height: 32), target: format, into: cb)
        XCTAssertFalse(renderer.isReady)
        Thread.sleep(forTimeInterval: 0.01)
      } catch {
        thrown = true
      }
      cb.commit()
    }
    XCTAssertTrue(thrown, "a failed build surfaces as an error")
    XCTAssertFalse(engine.pipelineBuildFailures.isEmpty)
    let count = engine.pipelineBuildFailures.count
    let cb = try XCTUnwrap(queue.makeCommandBuffer())
    XCTAssertThrowsError(
      try renderer.prepare(accumulator, viewport: MonitorViewport(width: 64, height: 32), target: format, into: cb))
    cb.commit()
    XCTAssertEqual(engine.pipelineBuildFailures.count, count, "never retried")
  }

  // MARK: LUT switch and colorimetry

  /// `monitorLUTEnabled: false` (a surface with `MonitorState.monitorLUT` off)
  /// measures the monitor stage without the feed's monitor LUT, as that
  /// surface's picture and zebras do; on, it applies it.
  func testFeedOverloadsFollowTheSurfaceMonitorLUTSwitch() throws {
    let (device, _, engine) = try GPU.require()
    let monitorEngine = try MonitorEngine(device: device, specialization: .off)
    let feed = monitorEngine.makeFeed()
    feed.burnInLUT = try MonitorLUT(
      device: device, cube: try ScopeAccumulationTests.makeCube(size: 17) { SIMD3(pow($0.x, 0.8), $0.y, $0.z) })
    feed.monitorLUT = try MonitorLUT(
      device: device, cube: try ScopeAccumulationTests.makeCube(size: 17) { SIMD3($0.x * 0.5, 1 - $0.y, $0.z) })
    let frame = try TestFrame.natural(.v210, width: 200, height: 60, seed: 8, mirror: false)
    var s = ScopeSettings(kind: .waveform, stage: .monitor)
    s.waveformMode = .rgbParade
    for enabled in [true, false] {
      let viaFeed = try engine.makeAccumulator(settings: s), explicit = try engine.makeAccumulator(settings: s)
      let grouped = try engine.makeAccumulator(settings: s)
      var h = s
      h.kind = .histogram
      let partner = try engine.makeAccumulator(settings: h)
      let group = try engine.makeGroup([grouped, partner])
      try GPU.run { cb in
        try viaFeed.accumulate(frame.frame, feed: feed, monitorLUTEnabled: enabled, into: cb)
        try explicit.accumulate(
          frame.frame, burnInLUT: feed.burnInLUT, monitorLUT: enabled ? feed.monitorLUT : nil, into: cb)
        try group.accumulate(frame.frame, feed: feed, monitorLUTEnabled: enabled, into: cb)
      }
      XCTAssertEqual(viaFeed.appliedMonitorLUT, enabled)
      XCTAssertTrue(viaFeed.appliedBurnInLUT)
      XCTAssertEqual(grouped.appliedMonitorLUT, enabled)
      let bins = try readBins(explicit)
      XCTAssertEqual(try readBins(viaFeed), bins, "enabled \(enabled)")
      XCTAssertEqual(try readBins(grouped), bins, "grouped, enabled \(enabled)")
    }
  }

  /// The SMPTE 240M override weighs luma, the Y'CbCr parade and the vectorscope with 240M.
  func testSMPTE240MOverride() throws {
    let (_, _, engine) = try GPU.require()
    XCTAssertEqual(ScopeColorimetry.smpte240m.matrix(source: .bt709, lutApplied: false), .smpte240m)
    XCTAssertEqual(ScopeColorimetry.smpte240m.matrix(source: .bt2020, lutApplied: true), .smpte240m)
    let frame = try TestFrame.natural(.biplanar(.s422, 10), width: 160, height: 40, seed: 3)
    for kind in ScopeKind.allCases {
      var s = ScopeSettings(kind: kind, stage: .source)
      s.colorimetry = .smpte240m
      s.waveformMode = .ycbcrParade
      s.vectorscopeSize = 256
      s.waveformColumns = 120
      s.waveformLevels = 256
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      XCTAssertEqual(accumulator.context.matrix, .smpte240m, "\(kind)")
      let p = accumulator.kernelParameters(settings: s, frame: frame.frame, burnInLUT: nil, monitorLUT: nil, generation: 1)
      XCTAssertEqual(p.weights, SIMD4(0.212, 0.701, 0.087, 0), "\(kind): Y' from R'G'B' with 240M weights")
      ScopeAccumulationTests.reference(accumulator, frame).check(try readBins(accumulator), "240M \(kind)")
    }
    var v = ScopeSettings(kind: .vectorscope)
    v.colorimetry = .smpte240m
    let accumulator = try engine.makeAccumulator(settings: v)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertEqual(
      accumulator.graticule(width: 512, height: 512).targets.first?.cb,
      VectorscopeTarget.bars(matrix: .smpte240m, amplitude: 0.75).first?.cb)
    let data = try JSONEncoder().encode(v)
    XCTAssertEqual(try JSONDecoder().decode(ScopeSettings.self, from: data).colorimetry, .smpte240m)
  }

  // MARK: failures

  /// An accumulation that reshaped the bins and then failed to encode (its
  /// `begin` ran, its `finish` never did) leaves nothing to draw, rather than
  /// the new bins read with the old settings; the next accumulation restores it.
  func testAnAccumulationFailingAfterAReshapeDrawsNoTrace() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, mirror: false)
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform, stage: .source))
    let renderer = engine.makeRenderer()
    let target = try makeTarget(width: 256, height: 128)
    try GPU.run { cb in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.render(accumulator, target: target, clear: true, into: cb)
    }
    XCTAssertTrue(renderer.hasTrace)
    accumulator.settings.waveformMode = .rgbParade
    _ = try accumulator.begin(frame.frame, burnInLUT: nil, monitorLUT: nil)
    XCTAssertEqual(accumulator.layout.channels, 3, "the bins are reshaped")
    XCTAssertEqual(accumulator.accumulatedSettings.waveformMode, .luma, "and hold no parade")
    XCTAssertFalse(accumulator.hasData)
    try GPU.run { cb in try renderer.render(accumulator, target: target, clear: true, into: cb) }
    XCTAssertFalse(renderer.hasTrace)
    try GPU.run { cb in
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.render(accumulator, target: target, clear: true, into: cb)
    }
    XCTAssertTrue(accumulator.hasData)
    XCTAssertTrue(renderer.hasTrace)
    XCTAssertEqual(renderer.parameters.shape.z, 3)
  }

  /// With `.synchronous`, a fused kernel that failed to build (specialized and
  /// all-tools) leaves the group accumulating every member on its own, with
  /// the same bins; a failed specialized draw falls back to the general one.
  func testFailedSynchronousBuildsFallBack() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, mirror: false)
    let waveform = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform, stage: .source))
    let histogram = try engine.makeAccumulator(settings: ScopeSettings(kind: .histogram, stage: .source))
    let group = try engine.makeGroup([waveform, histogram])
    let members = group.fusable()
    XCTAssertEqual(members.count, 2)
    let key = ScopeEngine.ComputeKey(kernel: .fused, layout: frame.frame.layout.scopeLayoutCode, scopes: members.scopes)
    var general = key
    general.layout = nil
    engine.failedCompute.withLock { $0.formUnion([key, general]) }
    XCTAssertNil(engine.fusedPipeline(for: key).0)
    try GPU.run { cb in try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertEqual(group.fusedMemberCount, 0)
    for a in [waveform, histogram] {
      let solo = try engine.makeAccumulator(settings: a.settings)
      try GPU.run { cb in try solo.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      XCTAssertTrue(a.hasData)
      XCTAssertEqual(try readBins(a), try readBins(solo), "\(a.settings.kind)")
    }

    let target = MonitorRenderTargetFormat(colorPixelFormat: .rgba8Unorm)
    let draw = ScopeEngine.RenderKey(target: target, scope: ScopeEngine.DrawVariant(kind: 0, mode: 0))
    engine.failedRender.withLock { _ = $0.insert(draw) }
    let (pipeline, final) = try engine.renderPipeline(for: draw)
    XCTAssertTrue(final)
    XCTAssertTrue(pipeline === (try engine.renderPipeline(ScopeEngine.RenderKey(target: target, scope: nil))))
  }

  /// A real build failure on this thread is recorded once and not retried; only
  /// the general pipeline failing makes a draw throw.
  func testFailedSynchronousBuildsAreRecordedOnce() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    // No GPU renders 3 samples per pixel.
    let draw = ScopeEngine.RenderKey(
      target: MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm, sampleCount: 3),
      scope: ScopeEngine.DrawVariant(kind: 0, mode: 0))
    XCTAssertThrowsError(try engine.renderPipeline(for: draw))
    let failures = engine.pipelineBuildFailures.count
    XCTAssertEqual(failures, 2, "the specialized and the general pipeline")
    XCTAssertThrowsError(try engine.renderPipeline(for: draw))
    XCTAssertEqual(engine.pipelineBuildFailures.count, failures, "neither is built again")
  }

  // MARK: shared residency

  /// An engine sharing a longer-lived residency set takes its placeholders out
  /// of it when released, so a set shared with a `MonitorEngine` holds nothing
  /// of an engine that no longer exists.
  func testReleasedEngineLeavesASharedResidencySet() throws {
    let (device, _, _) = try GPU.require()
    let shared = try MonitorResidency(device: device, label: "shared")
    let before = shared.set.allocationCount
    try autoreleasepool {
      let engine = try ScopeEngine(device: device, specialization: .synchronous, residency: shared)
      XCTAssertTrue(shared.contains(engine.placeholderTrace))
      XCTAssertEqual(shared.set.allocationCount, before + 4)
    }
    // No submission was observed, so nothing waits on the GPU.
    shared.release(through: shared.latestSubmission)
    XCTAssertEqual(shared.pendingReleaseCount, 0)
    XCTAssertEqual(shared.set.allocationCount, before)
  }
}
