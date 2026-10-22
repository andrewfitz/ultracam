import CoreVideo
import Metal
import QuartzCore
import XCTest

@testable import MonitorKit

/// R12 (the IOSurface-keyed texture cache), R6/R7 (pipeline warm-up, the
/// MTL4Compiler build path, framebufferOnly drawables on the classic path).
final class TextureCacheWarmUpTests: XCTestCase {
  // MARK: - R12 texture cache

  func buffers() -> [(PixelLayout, CVPixelBuffer)] {
    let layouts: [PixelLayout] = [.v210, .uyvy8, .biplanar(.s420, bitDepth: 10), .biplanar(.s422, bitDepth: 8), .bgra8]
    return layouts.compactMap { layout in
      PictureTests.picture(layout, width: 66, height: 38, seed: 9).pixelBuffer(range: .legal).map { (layout, $0) }
    }
  }

  /// Frames from the cache draw exactly what `wrap(_:cache:)` frames do, in every
  /// layout, with each plane made once and made resident once.
  func testCacheFramesMatchWrappedFrames() throws {
    let gpu = try requireGPU()
    let residency = try MonitorResidency(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: residency)
    var state = MonitorState()
    everyTool(&state)
    var planes = 0
    for (layout, pb) in buffers() {
      let cached = try cache.frame(pb, now: 10)
      let wrapped = try MonitorFrame.wrap(pb, cache: gpu.cache)
      XCTAssertEqual(cached.layout, wrapped.layout)
      XCTAssertEqual(cached.signal, wrapped.signal)
      XCTAssertEqual(cached.geometry, wrapped.geometry)
      XCTAssertEqual(cached.packed?.pixelFormat, wrapped.packed?.pixelFormat)
      XCTAssertEqual(cached.luma?.pixelFormat, wrapped.luma?.pixelFormat)
      XCTAssertEqual(cached.chroma?.pixelFormat, wrapped.chroma?.pixelFormat)
      let a = try gpu.render(cached, state: state, width: 48, height: 27, analyze: true)
      let b = try gpu.render(wrapped, state: state, width: 48, height: 27, analyze: true)
      assertSamePixels(a.values, b.values, "\(layout)")
      planes += cached.packed != nil ? 1 : (cached.chroma != nil ? 2 : 1)
      for t in [cached.packed, cached.luma, cached.chroma] { if let t { XCTAssertTrue(residency.contains(t)) } }
      // The same buffer again: the same textures, nothing made.
      let made = cache.texturesMade, commits = residency.commitCount
      let again = try cache.frame(pb, now: 10.5)
      XCTAssertTrue((again.packed ?? again.luma) === (cached.packed ?? cached.luma))
      XCTAssertNotEqual(again.id, cached.id, "a fresh frame identity per picture")
      XCTAssertEqual(cache.texturesMade, made)
      XCTAssertEqual(residency.commitCount, commits, "no residency change in steady state")
    }
    XCTAssertEqual(cache.count, planes)
    XCTAssertEqual(cache.texturesMade, planes)
  }

  func testIdleSweepFlushAndRemoveAll() throws {
    let gpu = try requireGPU()
    let residency = try MonitorResidency(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: residency, idleLifetime: 2)
    XCTAssertEqual(cache.idleLifetime, 2)
    XCTAssertEqual(cache.sweepInterval, 1)
    let all = buffers()
    let (_, a) = all[0], (_, b) = all[2]
    let fa = try cache.frame(a, owner: 1, now: 100)
    let fb = try cache.frame(b, owner: 2, now: 100)
    XCTAssertEqual(cache.count, 3)
    XCTAssertEqual(cache.count(owner: 1), 1)
    XCTAssertEqual(cache.count(owner: 2), 2)
    // A used texture survives the sweep; an idle one goes.
    _ = try cache.frame(b, owner: 2, now: 101.5)
    cache.sweep(now: 103)
    XCTAssertEqual(cache.count, 2)
    XCTAssertFalse(residency.contains(fa.packed!), "an idle texture leaves the residency set once released")
    XCTAssertTrue(residency.contains(fb.luma!))
    // A lookup after the sweep interval sweeps by itself: b, last used at 101.5, is idle at 104.
    _ = try cache.frame(a, owner: 1, now: 104)
    XCTAssertEqual(cache.count, 1, "a made again, b swept by the lookup")
    XCTAssertFalse(residency.contains(fb.luma!))
    // Within the sweep interval a lookup does not scan.
    _ = try cache.frame(b, owner: 2, now: 104.5)
    XCTAssertEqual(cache.count, 3)
    _ = try cache.frame(b, owner: 2, now: 105.9)
    XCTAssertEqual(cache.count, 3, "a (104) is not yet idle at 105.9")
    // Flush per owner.
    cache.flush(owner: 1)
    XCTAssertEqual(cache.count(owner: 1), 0)
    XCTAssertEqual(cache.count(owner: 2), 2)
    cache.removeAll()
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(residency.pendingReleaseCount, 0)
  }

  /// A retired texture stays resident until the submissions that may read it complete.
  func testRetiredTexturesWaitForTheirSubmissions() throws {
    let gpu = try requireMTL4().gpu
    let residency = try MonitorResidency(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: residency)
    let pb = buffers()[0].1
    let frame = try cache.frame(pb, now: 0)
    // Submission 5 read the frame and has not completed.
    let cb = try XCTUnwrap(gpu.device.makeCommandBuffer())
    residency.observe(MonitorSubmission(commandBuffer: cb, index: 5, completedIndex: 0))
    cache.flush(owner: 0)
    XCTAssertEqual(cache.count, 0)
    XCTAssertTrue(residency.contains(frame.packed!), "still resident while submission 5 may run")
    residency.release(through: 4)
    XCTAssertTrue(residency.contains(frame.packed!))
    residency.release(through: 5)
    XCTAssertFalse(residency.contains(frame.packed!))
  }

  func testConcurrentLookupsMakeEachTextureOnce() throws {
    let gpu = try requireGPU()
    let residency = try MonitorResidency(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: residency)
    nonisolated(unsafe) let all = buffers()
    DispatchQueue.concurrentPerform(iterations: 64) { i in
      _ = try? cache.frame(all[i % all.count].1, now: 1)
    }
    let planes = all.reduce(0) { n, b in n + (b.0.isRGB || b.0 == .v210 || b.0 == .uyvy8 ? 1 : 2) }
    XCTAssertEqual(cache.count, planes)
    XCTAssertEqual(cache.texturesMade, planes, "a racing duplicate is dropped, not kept or made resident")
  }

  func testCacheRejectsWhatItCannotRead() throws {
    let gpu = try requireGPU()
    let cache = MonitorTextureCache(device: gpu.device, residency: try MonitorResidency(device: gpu.device))
    var plain: CVPixelBuffer?
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &plain)
    XCTAssertThrowsError(try cache.frame(try XCTUnwrap(plain)), "no IOSurface")
    var odd: CVPixelBuffer?
    CVPixelBufferCreate(
      nil, 16, 16, kCVPixelFormatType_OneComponent8, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &odd)
    XCTAssertThrowsError(try cache.frame(try XCTUnwrap(odd))) { error in
      XCTAssertEqual(error as? MonitorKitError, .unsupportedPixelFormat(kCVPixelFormatType_OneComponent8))
    }
  }

  /// Steady state: a cached frame allocates nothing.
  func testSteadyStateLookupMakesNoHeapAllocations() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    let cache = MonitorTextureCache(device: gpu.device, residency: try MonitorResidency(device: gpu.device))
    for (layout, pb) in buffers() {
      _ = try cache.frame(pb, now: 1)
      var id: UInt64 = 0
      let n = try XCTUnwrap(
        AllocationCounter.measure {
          var i = 0
          while i < 8 {
            id &+= try cache.frame(pb, now: 1).id
            i += 1
          }
        })
      XCTAssertEqual(n, 0, "\(layout)")
      XCTAssertGreaterThan(id, 0)
      // The default clock too.
      _ = try cache.frame(pb)
      let m = try XCTUnwrap(AllocationCounter.measure { id &+= try cache.frame(pb).id })
      XCTAssertEqual(m, 0, "\(layout), uptime clock")
    }
  }

  // MARK: - R6/R7 warm-up

  /// After `warmUp`, a surface's first frame draws with its specialized pipeline
  /// and compiles nothing on the encoding thread.
  func testWarmUpBuildsEverySurfacePipelineAheadOfTheFirstFrame() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    let burn = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 1))
    var tools = MonitorState()
    everyTool(&tools)
    var sony = MonitorState()
    sony.falseColor.mode = .sonySLog3
    var assist = MonitorState()
    assist.displayTransform.mode = .logToRec709
    assist.pictureStage = .source
    var hdr = MonitorState()
    hdr.zebras[0].enabled = true
    let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
    let pq = SignalDescription(matrix: .bt2020, encoding: .display(.pq), primaries: .rec2020)
    struct Surface {
      var state: MonitorState, signal: SignalDescription, format: MTLPixelFormat, output: MonitorOutputColor
      var burn: Bool, sized: Bool
    }
    let surfaces = [
      Surface(state: tools, signal: .rec709, format: .bgr10a2Unorm, output: .signalNative, burn: true, sized: true),
      Surface(state: sony, signal: slog3, format: .bgr10a2Unorm, output: .signalNative, burn: false, sized: false),
      Surface(state: assist, signal: slog3, format: .bgra8Unorm, output: .signalNative, burn: true, sized: false),
      Surface(
        state: hdr, signal: pq, format: .rgba16Float, output: MonitorOutputColor(primaries: .rec2020, encoding: .pq),
        burn: false, sized: true),
    ]
    let configurations = surfaces.map {
      MonitorSurfaceConfiguration(
        target: MonitorRenderTargetFormat(colorPixelFormat: $0.format), layout: .v210, state: $0.state,
        signal: $0.signal, outputColor: $0.output, hasBurnInLUT: $0.burn,
        frameSize: $0.sized ? (width: 192, height: 108) : nil, viewportSize: $0.sized ? (width: 160, height: 90) : nil)
    }
    let built = try engine.warmUp(targets: [], layouts: [.v210], surfaces: configurations)
    XCTAssertGreaterThanOrEqual(built, surfaces.count)
    XCTAssertEqual(try engine.warmUp(targets: [], layouts: [.v210], surfaces: configurations), 0, "built once")
    try engine.warmUp(layouts: [.v210])  // the stand-ins for the three standard formats
    for (i, surface) in surfaces.enumerated() {
      let frame = try PictureTests.picture(width: 192, height: 108, seed: UInt64(i)).frame(gpu, signal: surface.signal)
      let feed = engine.makeFeed()
      feed.burnInLUT = surface.burn ? burn : nil
      let pass = engine.makePass()
      pass.outputColor = surface.output
      let target = gpu.target(160, 90, format: surface.format)
      let callerBuilt = engine.pipelinesBuiltOnCaller
      try gpu.run { cb in
        try feed.analyze(frame, focus: surface.state.focus, into: cb)
        try pass.encode(frame: frame, feed: feed, state: surface.state, target: target, into: cb)
      }
      XCTAssertTrue(pass.usesSpecializedPipeline, "surface \(i) draws specialized on its first frame")
      XCTAssertEqual(engine.pipelinesBuiltOnCaller, callerBuilt, "surface \(i) compiled nothing while encoding")
    }
    XCTAssertEqual(MonitorEngine.standardTargetFormats, [.bgr10a2Unorm, .rgba16Float, .bgra8Unorm])
  }

  /// The compute picture warms the same way.
  func testWarmUpComputePictures() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    m.queue.addResidencySet(engine.residency.set)
    defer { m.queue.removeResidencySet(engine.residency.set) }
    var state = MonitorState()
    everyTool(&state)
    state.focus.enabled = false
    try engine.warmUp(
      targets: [], layouts: [.v210],
      surfaces: [
        MonitorSurfaceConfiguration(
          target: MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float), layout: .v210, state: state,
          frameSize: (width: 96, height: 54), viewportSize: (width: 96, height: 54), compute: true)
      ])
    let frame = try m.frame(PictureTests.picture(width: 96, height: 54), signal: .rec709)
    let target = m.target(96, 54, format: .rgba16Float, usage: [.shaderWrite, .shaderRead])
    let pass = engine.makePass(), feed = engine.makeFeed()
    let callerBuilt = engine.pipelinesBuiltOnCaller
    try m.run { s in try pass.encodeCompute(frame: frame, feed: feed, state: state, target: target, into: s) }
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, callerBuilt)
  }

  // MARK: - R6 MTL4Compiler-built pipelines

  /// An engine whose library and pipelines come from the host's `MTL4Compiler`
  /// draws the same bytes as the device-built engine, on the classic and Metal 4
  /// paths, inside a host pass with depth, and as a compute picture.
  func testCompilerBuiltEngineMatchesTheDeviceEngine() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let compiler = try gpu.device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let engine = try MonitorEngine(device: gpu.device, specialization: .synchronous, compiler: compiler)
    XCTAssertNotNil(engine.compiler)
    m.queue.addResidencySet(engine.residency.set)
    defer { m.queue.removeResidencySet(engine.residency.set) }
    let (burn, monitor) = try Metal4Tests.luts(gpu)
    var all = MonitorState()
    everyTool(&all)
    var assist = MonitorState()
    assist.displayTransform.mode = .logToRec709
    var source = all
    source.pictureStage = .source
    let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))
    let cases: [(MonitorState, SignalDescription, MTLPixelFormat)] = [
      (all, .rec709, .rgba32Float), (assist, slog3, .bgra8Unorm), (source, .rec709, .bgr10a2Unorm),
    ]
    for (i, (state, signal, format)) in cases.enumerated() {
      let frame = try m.frame(PictureTests.picture(width: 96, height: 54, seed: UInt64(i)), signal: signal)
      func classic(_ e: MonitorEngine) throws -> [UInt8] {
        let feed = e.makeFeed(), pass = e.makePass()
        feed.burnInLUT = burn
        feed.monitorLUT = monitor
        let t = gpu.texture(format, 80, 45, usage: [.renderTarget, .shaderRead])
        try gpu.run { cb in
          try feed.analyze(frame, focus: state.focus, into: cb)
          try pass.encode(frame: frame, feed: feed, state: state, target: t, into: cb)
        }
        XCTAssertTrue(pass.usesSpecializedPipeline)
        return rawBytes(t)
      }
      func metal4(_ e: MonitorEngine) throws -> [UInt8] {
        let feed = e.makeFeed(), pass = e.makePass()
        feed.burnInLUT = burn
        feed.monitorLUT = monitor
        let t = m.target(80, 45, format: format)
        try m.run { s in
          try feed.analyze(frame, focus: state.focus, into: s)
          try pass.encode(frame: frame, feed: feed, state: state, target: t, into: s)
        }
        m.drain()
        return rawBytes(t)
      }
      let reference = try classic(gpu.engine)
      XCTAssertEqual(try classic(engine), reference, "classic, case \(i)")
      XCTAssertEqual(try metal4(engine), reference, "Metal 4, case \(i)")
    }
    // Inside a classic host pass with a depth attachment.
    let frame = try m.frame(PictureTests.picture(width: 96, height: 54), signal: .rec709)
    func hostPass(_ e: MonitorEngine) throws -> [UInt8] {
      let color = gpu.texture(.bgra8Unorm, 64, 36, usage: [.renderTarget, .shaderRead])
      let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 64, height: 36, mipmapped: false)
      dd.usage = .renderTarget
      dd.storageMode = .private
      let depth = try XCTUnwrap(gpu.device.makeTexture(descriptor: dd))
      let rp = MTLRenderPassDescriptor()
      rp.colorAttachments[0].texture = color
      rp.colorAttachments[0].loadAction = .clear
      rp.colorAttachments[0].storeAction = .store
      rp.depthAttachment.texture = depth
      rp.depthAttachment.loadAction = .clear
      rp.depthAttachment.storeAction = .dontCare
      let feed = e.makeFeed(), pass = e.makePass()
      try gpu.run { cb in
        try pass.prepare(
          frame: frame, feed: feed, state: all, viewport: MonitorViewport(width: 64, height: 36),
          target: MonitorRenderTargetFormat(rp), into: cb)
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rp))
        try pass.draw(with: enc)
        enc.endEncoding()
      }
      return rawBytes(color)
    }
    XCTAssertEqual(try hostPass(engine), try hostPass(gpu.engine), "classic host pass with depth")
    // The compute picture.
    func compute(_ e: MonitorEngine) throws -> [UInt8] {
      let t = m.target(80, 45, usage: [.shaderWrite, .shaderRead])
      let feed = e.makeFeed(), pass = e.makePass()
      try m.run { s in try pass.encodeCompute(frame: frame, feed: feed, state: all, target: t, into: s) }
      m.drain()
      return rawBytes(t)
    }
    XCTAssertEqual(try compute(engine), try compute(gpu.engine), "compute picture")
    // Freeze's copy kernels and the focus analysis come from the compiler too.
    let feed = engine.makeFeed()
    var frozen: MonitorFrame?
    try gpu.run { cb in frozen = try feed.freeze(frame, into: cb) }
    XCTAssertNotNil(frozen)
  }

  /// An asynchronous compiler-built engine specializes through compiler tasks: the
  /// all-tools pipeline draws until the specialized one is ready, never on the
  /// encoding thread.
  func testAsynchronousCompilerSpecialization() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let compiler = try gpu.device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous, compiler: compiler)
    try engine.prepare(pixelFormat: .rgba32Float, layouts: [.v210])
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.zebras[0].enabled = true
    let feed = engine.makeFeed(), pass = engine.makePass()
    let t = gpu.target(96, 54)
    let callerBuilt = engine.pipelinesBuiltOnCaller
    let deadline = Date().addingTimeInterval(30)
    repeat {
      try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: state, target: t, into: cb) }
      if pass.usesSpecializedPipeline { break }
      usleep(5000)
    } while Date() < deadline
    XCTAssertTrue(pass.usesSpecializedPipeline)
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, callerBuilt)
    let reference = try gpu.render(frame, state: state)
    assertSamePixels(Pixels(t).values, reference.values, "compiler-specialized picture")
  }

  // MARK: - R7 framebufferOnly drawables, classic path

  func testClassicPathDrawsIntoFramebufferOnlyDrawables() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 192, height: 108).frame(gpu, signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed()
    try gpu.engine.warmUp(layouts: [.v210])
    for format in MonitorEngine.standardTargetFormats {
      let layer = CAMetalLayer()
      layer.device = gpu.device
      layer.pixelFormat = format
      layer.framebufferOnly = true
      layer.drawableSize = CGSize(width: 160, height: 90)
      guard let drawable = layer.nextDrawable() else { throw XCTSkip("no drawable without a window") }
      XCTAssertEqual(drawable.texture.usage, .renderTarget)
      let pass = gpu.engine.makePass()
      try gpu.run { cb in
        try feed.analyze(frame, focus: state.focus, into: cb)
        try pass.encode(frame: frame, feed: feed, state: state, target: drawable.texture, into: cb)
      }
      XCTAssertTrue(pass.usesSpecializedPipeline)
    }
  }
}
