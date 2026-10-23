import CoreVideo
import Darwin
import Metal
import XCTest

@testable import MonitorKit

/// Counts heap allocations made on the calling thread, through libmalloc's logger hook.
enum AllocationCounter {
  typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
  nonisolated(unsafe) static var count = 0
  nonisolated(unsafe) static var thread: pthread_t?
  nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")
    .map { $0.assumingMemoryBound(to: Logger?.self) }

  /// Allocations made by `body` on this thread, or nil when the hook is unavailable.
  static func measure(_ body: () throws -> Void) rethrows -> Int? {
    guard let slot, slot.pointee == nil else { try body(); return nil }
    count = 0
    thread = pthread_self()
    slot.pointee = { type, _, _, _, _, _ in
      // MALLOC_LOG_TYPE_ALLOCATE
      if type & 2 != 0, let t = AllocationCounter.thread, pthread_equal(pthread_self(), t) != 0 { AllocationCounter.count += 1 }
    }
    defer { slot.pointee = nil; thread = nil }
    try body()
    return count
  }
}

/// Every surface tool on, on a 4K-shaped (but small) frame.
func everyTool(_ state: inout MonitorState) {
  state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 95, stage: .output)
  state.zebras[1] = ZebraSet(mode: .band, level: 70, range: 5, stage: .source)
  state.falseColor.mode = .sixBand
  state.focus.enabled = true
  state.guides.enabled = true
  state.guides.thirds = true
  state.guides.centerCross = true
  state.guides.safeAreas = [90]
  state.guides.frameGuides = [FrameGuide(aspect: 2.39, style: .linesAndMatte)]
  state.display.saturation = 1.2
}

/// The zero-overhead rules of ARCHITECTURE.md, each checked.
final class ContractTests: XCTestCase {
  func setUp(_ gpu: TestGPU) throws -> (MonitorFrame, MonitorFeed, MonitorPass, MonitorState, MTLTexture) {
    let frame = try PictureTests.picture(width: 384, height: 216).frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 1))
    feed.monitorLUT = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 2))
    var state = MonitorState()
    everyTool(&state)
    return (frame, feed, gpu.engine.makePass(), state, gpu.target(192, 108, format: .bgra8Unorm))
  }

  func testEncodeNeverCommitsWaitsOrAddsHandlers() throws {
    let gpu = try requireGPU()
    let (frame, feed, pass, state, target) = try setUp(gpu)
    let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    try feed.analyze(frame, focus: state.focus, into: cb)
    try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
    let pass2 = gpu.engine.makePass()
    try pass2.prepare(frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 96, height: 54),
                      targetPixelFormat: .bgra8Unorm, into: cb)
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = target
    d.colorAttachments[0].loadAction = .load
    let encoder = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: d))
    try pass2.draw(with: encoder)
    encoder.endEncoding()
    XCTAssertEqual(cb.status, .notEnqueued)
    cb.commit()
    cb.waitUntilCompleted()
    XCTAssertEqual(cb.status, .completed)
    XCTAssertNil(cb.error)
  }

  /// The library makes no queue, device, thread, blit, command buffer, commit or
  /// wait, on either path. Checked in the sources, since a command buffer cannot
  /// report which encoders it holds. The only commit is of the library's own
  /// residency set (when an allocation joins or leaves it); the only buffer is the
  /// Metal 4 uniform ring, made on first use (and when a host outruns it).
  func testSourcesNeverCreateQueuesCommitWaitOrBlit() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Sources/MonitorKit").resolvingSymlinksInPath()
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    XCTAssertGreaterThan(files.count, 5)
    var buffers: [String] = []
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      for banned in [
        "makeBlitCommandEncoder", "waitUntilCompleted", "waitUntilScheduled", "addCompletedHandler",
        "addScheduledHandler", "makeCommandQueue", "makeMTL4CommandQueue", "makeCommandBuffer", "makeCommandAllocator",
        "beginCommandBuffer", "endCommandBuffer", "addFeedbackHandler", "waitForDrawable", "signalDrawable",
        "addResidencySet", "useResidencySet", "MTLCreateSystemDefaultDevice", "DispatchQueue", "Thread(",
        "presentDrawable", ".present(", "SharedEvent",
      ] {
        XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) uses \(banned)")
      }
      XCTAssertFalse(
        text.replacingOccurrences(of: "set.commit()", with: "").contains(".commit("),
        "\(file.lastPathComponent) commits something other than the residency set")
      if text.contains("makeBuffer(") { buffers.append(file.lastPathComponent) }
    }
    XCTAssertEqual(buffers, ["Metal4.swift"])
    let ring = try String(contentsOf: root.appendingPathComponent("Metal4.swift"), encoding: .utf8)
    XCTAssertEqual(ring.components(separatedBy: "makeBuffer(").count, 2, "one buffer allocation site")
    let grow = try XCTUnwrap(ring.range(of: "private mutating func grow("))
    XCTAssertNotNil(ring.range(of: "makeBuffer(", range: grow.upperBound..<ring.index(grow.upperBound, offsetBy: 300)))
  }

  /// Every encoder MonitorKit opens is closed before anything after it can throw
  /// (or by a `defer`): a host's commit or `endCommandBuffer` must never meet an
  /// encoder the library left open (an assertion under the Metal debug layer,
  /// undefined in release). Scans every module's sources.
  func testEveryEncoderIsClosedBeforeAnythingCanThrow() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Sources").resolvingSymlinksInPath()
    var sites = 0
    for module in ["MonitorKit", "MonitorKitScopes", "MonitorKitUI"] {
      let root = sources.appendingPathComponent(module)
      let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
      for file in files {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("CommandEncoder(") && line.contains("let encoder") {
          sites += 1
          // From the encoder's creation to its end (a `defer`, an `endEncoding()`, or
          // a helper that ends it at the end of the function), nothing may throw.
          var j = i + 1
          var depth = 0
          while j < lines.count {
            let next = lines[j].trimmingCharacters(in: .whitespaces)
            if next.hasPrefix("//") || next.hasPrefix("///") {
              j += 1
              continue
            }
            if next.contains("encoder.endEncoding()") { break }
            XCTAssertFalse(
              next.contains("try "),
              "\(file.lastPathComponent):\(j + 1) can throw while the encoder opened at line \(i + 1) is open")
            depth += next.filter { $0 == "{" }.count - next.filter { $0 == "}" }.count
            if depth < 0 { break }  // the function ends
            j += 1
          }
        }
      }
    }
    XCTAssertGreaterThan(sites, 15)
  }

  /// `MonitorKitError` is a `LocalizedError`: a host's `localizedDescription` is the description.
  func testErrorsDescribeThemselvesToHosts() {
    for error in [
      MonitorKitError.unsupportedPixelFormat(kCVPixelFormatType_OneComponent8), .invalidFrame("empty frame"),
      .textureMapping(plane: 1, status: -6660), .gpu("Cannot create a compute encoder for Freeze."),
    ] {
      XCTAssertEqual((error as Error).localizedDescription, error.description)
      XCTAssertEqual(error.errorDescription, error.description)
    }
  }

  func testSteadyStateAllocatesNoGPUMemory() throws {
    let gpu = try requireGPU()
    let (frame, feed, pass, state, target) = try setUp(gpu)
    func frameOnce() throws {
      try gpu.run { cb in
        try feed.analyze(frame, focus: state.focus, into: cb)
        try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
      }
    }
    for _ in 0..<5 { try frameOnce() }
    let created = gpu.engine.resourcesCreated
    let bytes = gpu.device.currentAllocatedSize
    let rebuilds = pass.rebuildCount
    for _ in 0..<100 { try frameOnce() }
    XCTAssertEqual(gpu.engine.resourcesCreated, created)
    XCTAssertEqual(pass.rebuildCount, rebuilds)
    XCTAssertLessThanOrEqual(gpu.device.currentAllocatedSize, bytes, "device memory grew in steady state")
    // Persistent memory: the r8 mask at source size; guides are analytic, so the surface owns nothing.
    XCTAssertEqual(feed.persistentMemoryBytes, feed.focusMask!.allocatedSize)
    XCTAssertGreaterThanOrEqual(feed.persistentMemoryBytes, 384 * 216)
    XCTAssertEqual(pass.persistentMemoryBytes, 0)
  }

  /// Steady-state CPU encode: no heap allocation by MonitorKit. Metal allocates
  /// inside its own encoder calls, so the control is a host making exactly the
  /// same Metal calls inline; MonitorKit must add nothing on top.
  func testSteadyStateEncodeMakesNoHeapAllocations() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    let (frame, feed, pass, state, target) = try setUp(gpu)
    for _ in 0..<3 {
      try gpu.run { cb in
        try feed.analyze(frame, focus: state.focus, into: cb)
        try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
      }
    }
    let pipeline = try gpu.engine.renderPipeline(
      .init(target: .init(colorPixelFormat: .bgra8Unorm), layout: 0, variant: .uber))
    let control = MTLRenderPassDescriptor()
    control.colorAttachments[0].texture = target
    control.colorAttachments[0].loadAction = .clear
    control.colorAttachments[0].storeAction = .store
    var parameters = pass.currentParameters, frameParameters = frame.parameters, guides = pass.currentGuides
    var lut = feed.burnInLUT!.parameters
    var library: [Int] = [], inline: [Int] = [], prepare: [Int] = []
    for _ in 0..<30 {
      let cb = gpu.queue.makeCommandBuffer()!
      try feed.analyze(frame, focus: state.focus, into: cb)
      // A command buffer's first render encoder does one-time setup; keep it out of both counts.
      cb.makeRenderCommandEncoder(descriptor: control)!.endEncoding()
      guard let a = try AllocationCounter.measure({
        try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
      }) else { throw XCTSkip("malloc_logger is unavailable") }
      let b = AllocationCounter.measure {
        let e = cb.makeRenderCommandEncoder(descriptor: control)!
        e.setRenderPipelineState(pipeline)
        e.setViewport(MTLViewport(originX: 0, originY: 0, width: 192, height: 108, znear: 0, zfar: 1))
        e.setFragmentTexture(frame.packed, index: 0)
        e.setFragmentTexture(gpu.engine.emptyFloat, index: 1)
        e.setFragmentTexture(gpu.engine.emptyFloat, index: 2)
        e.setFragmentTexture(feed.burnInLUT!.texture, index: 3)
        e.setFragmentTexture(feed.monitorLUT!.texture, index: 4)
        e.setFragmentTexture(feed.focusMask, index: 5)
        e.setFragmentBytes(&frameParameters, length: MemoryLayout<FrameParameters>.stride, index: 0)
        e.setFragmentBytes(&lut, length: MemoryLayout<LUTParameters>.stride, index: 1)
        e.setFragmentBytes(&lut, length: MemoryLayout<LUTParameters>.stride, index: 2)
        e.setFragmentBytes(&parameters, length: MemoryLayout<PassParameters>.stride, index: 3)
        e.setFragmentBytes(&guides, length: MemoryLayout<GuideParameters>.stride, index: 4)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
      }!
      let c = try AllocationCounter.measure {
        try pass.prepare(frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 192, height: 108),
                         targetPixelFormat: .bgra8Unorm, into: cb)
      }!
      let e = cb.makeRenderCommandEncoder(descriptor: control)!
      try pass.draw(with: e)
      e.endEncoding()
      cb.commit()
      library.append(a)
      inline.append(b)
      prepare.append(c)
    }
    gpu.run { _ in }  // drain
    let encode = library.sorted()[library.count / 2], host = inline.sorted()[inline.count / 2]
    print("BENCH heap allocations per encode: \(encode); the same Metal calls inline: \(host); per prepare: \(prepare.max()!)")
    XCTAssertEqual(prepare.max(), 0, "prepare allocates in steady state")
    XCTAssertLessThanOrEqual(encode, host, "MonitorKit allocates beyond the Metal calls it makes")
  }

  /// Heap allocations of `prepare` over `frames`, each with `state(i)`, after `warm` frames.
  func prepareAllocations(
    _ gpu: TestGPU, frame: MonitorFrame, feed: MonitorFeed, pass: MonitorPass, frames: Int = 40,
    _ state: (Int) -> MonitorState
  ) throws -> [Int] {
    var counts: [Int] = []
    let cb = gpu.queue.makeCommandBuffer()!
    for i in 0..<frames {
      let s = state(i)
      guard let n = try AllocationCounter.measure({
        try pass.prepare(frame: frame, feed: feed, state: s, viewport: MonitorViewport(width: 192, height: 108),
                         targetPixelFormat: .bgra8Unorm, into: cb)
      }) else { throw XCTSkip("malloc_logger is unavailable") }
      if i >= 3 { counts.append(n) }
    }
    return counts
  }

  /// A NaN anywhere (a slider, a band edge, the pixel aspect) never equals itself:
  /// the pass keys on normalized values, so it neither rebuilds nor allocates.
  func testNaNInputsNeitherRebuildNorAllocate() throws {
    let gpu = try requireGPU()
    var (frame, feed, pass, state, _) = try setUp(gpu)
    state.zebras[0].level = .nan
    state.display.brightness = .nan
    state.geometry.magnification.centerX = .nan
    state.falseColor.mode = .custom
    state.falseColor.customBands = [FalseColorBand(lower: .nan, upper: 1, color: ColorRGB(r: 1, g: 0, b: 0)),
                                    FalseColorBand(lower: 20, upper: 40, color: ColorRGB(r: 0, g: 1, b: 0))]
    frame.pixelAspectRatio = .nan
    let snapshot = state
    let counts = try prepareAllocations(gpu, frame: frame, feed: feed, pass: pass) { _ in snapshot }
    XCTAssertEqual(counts.max(), 0)
    XCTAssertEqual(pass.rebuildCount, 1)
    XCTAssertTrue(pass.status.isActive(.falseColor))
  }

  /// A pinch (zoom every frame) and a slider drag (a uniform every frame) rebuild
  /// uniforms only: no allocation, and the status only when its text changes.
  func testContinuousGesturesAllocateNothing() throws {
    let gpu = try requireGPU()
    let (frame, feed, pass, base, _) = try setUp(gpu)
    var zoomed = base
    zoomed.geometry.magnification.zoom = 2
    let pinch = try prepareAllocations(gpu, frame: frame, feed: feed, pass: pass) { i in
      var s = zoomed
      s.geometry.magnification.zoom = 2 + Double(i) * 0.001
      s.geometry.magnification.centerX = 0.4 + Double(i) * 0.002
      return s
    }
    XCTAssertEqual(pinch.max(), 0, "pinch")
    let statusBuilds = pass.statusRebuildCount, rebuilds = pass.rebuildCount
    let slider = try prepareAllocations(gpu, frame: frame, feed: feed, pass: pass) { i in
      var s = zoomed
      s.geometry.magnification.zoom = 2.04
      s.display.brightness = Double(i) * 0.01
      s.zebras[0].opacity = 0.5 + Double(i) * 0.01
      s.guides.opacity = Double(i) / 40
      return s
    }
    XCTAssertEqual(slider.max(), 0, "slider")
    XCTAssertGreaterThan(pass.rebuildCount, rebuilds + 30, "uniforms did change")
    XCTAssertEqual(pass.statusRebuildCount, statusBuilds, "no status text changed")
    XCTAssertTrue(pass.status.activeLabels.contains("2×"))
  }

  /// The host-render-pass tier with depth, stencil, multisampling and a second
  /// colour attachment: the pipeline matches the pass, depth and stencil are
  /// neither tested nor written, and the other attachment is untouched.
  func testDrawingInsideARichHostRenderPass() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed()
    let reference = try gpu.render(frame, state: state, feed: feed, analyze: true)
    func texture(_ format: MTLPixelFormat, samples: Int = 1, usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 96, height: 54, mipmapped: false)
      d.usage = usage
      d.sampleCount = samples
      d.textureType = samples > 1 ? .type2DMultisample : .type2D
      d.storageMode = samples > 1 ? .private : (format == .depth32Float_stencil8 ? .private : .shared)
      return gpu.device.makeTexture(descriptor: d)!
    }
    for samples in [1, 4] {
      let color = texture(.rgba32Float, samples: samples), extra = texture(.rgba8Unorm, samples: samples)
      let depth = texture(.depth32Float_stencil8, samples: samples, usage: .renderTarget)
      let resolved = texture(.rgba32Float), extraResolved = texture(.rgba8Unorm)
      let d = MTLRenderPassDescriptor()
      d.colorAttachments[0].texture = color
      d.colorAttachments[0].loadAction = .clear
      d.colorAttachments[1].texture = extra
      d.colorAttachments[1].loadAction = .clear
      d.colorAttachments[1].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
      if samples > 1 {
        d.colorAttachments[0].resolveTexture = resolved
        d.colorAttachments[0].storeAction = .multisampleResolve
        d.colorAttachments[1].resolveTexture = extraResolved
        d.colorAttachments[1].storeAction = .multisampleResolve
      }
      d.depthAttachment.texture = depth
      d.depthAttachment.clearDepth = 0  // a depth test against 0 would reject everything
      d.stencilAttachment.texture = depth
      let format = MonitorRenderTargetFormat(d)
      XCTAssertEqual(format.depthPixelFormat, .depth32Float_stencil8)
      XCTAssertEqual(format.stencilPixelFormat, .depth32Float_stencil8)
      XCTAssertEqual(format.sampleCount, samples)
      XCTAssertEqual(format.additionalColorPixelFormats, [.rgba8Unorm])
      let pass = gpu.engine.makePass()
      try gpu.run { cb in
        try feed.analyze(frame, focus: state.focus, into: cb)
        try pass.prepare(frame: frame, feed: feed, state: state, viewport: MonitorViewport(width: 96, height: 54),
                         target: format, into: cb)
        let e = cb.makeRenderCommandEncoder(descriptor: d)!
        // The host's own state: a depth test that passes nothing, which MonitorKit must override.
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .never
        e.setDepthStencilState(gpu.device.makeDepthStencilState(descriptor: ds))
        try pass.draw(with: e)
        e.endEncoding()
      }
      let picture = Pixels(samples > 1 ? resolved : color)
      XCTAssertEqual(picture.values, reference.values, "\(samples)× MSAA")
      let other = Pixels(samples > 1 ? extraResolved : extra)
      XCTAssertEqual(other.rgb(10, 10), SIMD3(Float(51) / 255, Float(102) / 255, Float(153) / 255), "attachment 1 untouched")
    }
  }

  /// Tool sets that reach every pipeline tier.
  static func toolSets() -> [(String, MonitorState)] {
    func state(_ f: (inout MonitorState) -> Void) -> MonitorState { var s = MonitorState(); f(&s); return s }
    return [
      ("off", MonitorState()),
      ("every tool", state { everyTool(&$0) }),
      ("zebras", state { $0.zebras[0] = ZebraSet(mode: .band, level: 50, range: 20, stage: .source) }),
      ("peaking", state { $0.focus.enabled = true }),
      ("guides", state { $0.guides.enabled = true; $0.guides.diagonals = true; $0.guides.centerDot = true }),
      ("six band on the monitor", state { $0.falseColor.mode = .sixBand; $0.falseColor.stage = .monitor }),
      ("zoom + navigator", state { everyTool(&$0); $0.geometry.magnification.zoom = 2.5 }),
      ("1:1", state { $0.geometry.magnification.pixelExact = true }),
      ("clean", state { everyTool(&$0); $0.clean = true }),
      ("display", state { $0.display.monochrome = .blueOnly; $0.display.contrast = 1.3 }),
    ]
  }

  /// A specialized pipeline draws exactly what the all-tools pipeline draws.
  func testSpecializedPipelinesDrawExactlyWhatTheAllToolsPipelineDraws() throws {
    let gpu = try requireGPU()
    let uber = try MonitorEngine(device: gpu.device, specialization: .off)
    let lut = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 3))
    for layout in [PixelLayout.v210, .p010, .rgba16Float] {
      let source = layout.isRGB ? SyntheticFrame.random(layout, width: 120, height: 68, seed: 5) : PictureTests.picture(layout, width: 120, height: 68)
      let frame = try source.frame(gpu, signal: .rec709)
      for (name, state) in Self.toolSets() {
        for withLUT in [false, true] {
          func draw(_ engine: MonitorEngine) throws -> (Pixels, MonitorPass) {
            let feed = engine.makeFeed(), pass = engine.makePass()
            if withLUT { feed.burnInLUT = lut; feed.monitorLUT = lut }
            let t = gpu.target(100, 70)
            try gpu.run { cb in
              try feed.analyze(frame, focus: state.focus, into: cb)
              try pass.encode(frame: frame, feed: feed, state: state, target: t, into: cb)
            }
            return (Pixels(t), pass)
          }
          let (special, pass) = try draw(gpu.engine), (all, _) = try draw(uber)
          XCTAssertTrue(pass.usesSpecializedPipeline)
          XCTAssertEqual(special.values, all.values, "\(layout) \(name) LUT \(withLUT)")
        }
      }
    }
  }

  /// With asynchronous specialization the first frames draw with the all-tools
  /// pipeline, then switch, without a stall or a difference in the picture.
  func testAsynchronousSpecializationSwitchesWithoutChangingThePicture() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 60, stage: .source)
    let pass = engine.makePass(), feed = engine.makeFeed()
    let t = gpu.target(96, 54)
    var frames: [Pixels] = []
    let start = Date()
    while !pass.usesSpecializedPipeline && Date().timeIntervalSince(start) < 60 {
      try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: t, into: $0) }
      frames.append(Pixels(t))
      Thread.sleep(forTimeInterval: 0.005)
    }
    XCTAssertTrue(pass.usesSpecializedPipeline, "the specialized pipeline never arrived")
    try gpu.run { try pass.encode(frame: frame, feed: feed, state: state, target: t, into: $0) }
    let final = Pixels(t)
    for f in frames { XCTAssertEqual(f.values, final.values) }
    print("BENCH asynchronous specialization: \(frames.count) frames drawn with the all-tools pipeline")
  }

  /// The plan's inline-host check: the same frame through a host's own fragment
  /// (MonitorKit's MSL prepended, decode + filter + burned-in LUT inline) and
  /// through the library gives identical pixels, and the library costs no more GPU time.
  func testLibraryMatchesAHostsInlineShaderInPixelsAndGPUTime() throws {
    let gpu = try requireGPU()
    let host = """
      fragment float4 host_inline(mk_VertexOut v [[stage_in]],
                                  texture2d<uint, access::read> packed [[texture(0)]],
                                  texture2d<float, access::read> luma [[texture(1)]],
                                  texture2d<float, access::read> chroma [[texture(2)]],
                                  texture3d<float, access::sample> lut [[texture(3)]],
                                  constant mk_FrameParams& frame [[buffer(0)]],
                                  constant mk_LUTParams& burn [[buffer(1)]],
                                  constant mk_PassParams& unused [[buffer(2)]],
                                  constant float4& map [[buffer(3)]]) {
        mk_Inputs in = {packed, luma, chroma, lut, lut, frame, burn, burn, unused};
        float4 c = mk_filtered(v.position.xy, map, false, 8, in);
        return float4(clamp(mk_applyLUT(c.rgb, lut, burn), 0.0f, 1.0f), 1);
      }
      """
    // The host specializes at compile time, as an app with one input format would.
    let prefix = """
      #define MK_LAYOUT(f) 0u
      #define MK_ZEBRAS false
      #define MK_PEAKING false
      #define MK_GUIDES false
      #define MK_FALSE_COLOR 0u
      #define MK_INTERPOLATES false
      #define MK_NAVIGATOR false
      """
    let library = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode, .monitor], prefix: prefix, extra: host)
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "mk_fullscreen")
    d.fragmentFunction = library.makeFunction(name: "host_inline")
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    let inline = try gpu.device.makeRenderPipelineState(descriptor: d)
    let frame = try Benchmarks.frame4K(gpu)
    try Benchmarks().warmUp(gpu, frame)
    let lut = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 33, seed: 1))
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = lut
    for (w, h) in [(1920, 1080), (1600, 900)] {
      func target() -> MTLTexture {
        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        t.usage = [.renderTarget, .shaderRead]
        t.storageMode = .shared
        return gpu.device.makeTexture(descriptor: t)!
      }
      let a = target(), b = target()
      let pass = gpu.engine.makePass()
      let layout = MonitorLayout(pictureWidth: frame.width, pictureHeight: frame.height, viewportWidth: w, viewportHeight: h,
                                 geometry: ViewGeometry())
      var map = PassParameters()
      let m = layout.displayToPicture
      map.displayToPicture = SIMD4(Float(m.scaleX), Float(m.scaleY), Float(m.offsetX), Float(m.offsetY))
      func encodeInline(_ cb: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = b
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        let e = cb.makeRenderCommandEncoder(descriptor: rp)!
        e.setRenderPipelineState(inline)
        e.setFragmentTexture(frame.packed, index: 0)
        e.setFragmentTexture(gpu.engine.emptyFloat, index: 1)
        e.setFragmentTexture(gpu.engine.emptyFloat, index: 2)
        e.setFragmentTexture(lut.texture, index: 3)
        var f = frame.parameters, l = lut.parameters, unused = PassParameters(), v = map.displayToPicture
        e.setFragmentBytes(&f, length: MemoryLayout<FrameParameters>.stride, index: 0)
        e.setFragmentBytes(&l, length: MemoryLayout<LUTParameters>.stride, index: 1)
        e.setFragmentBytes(&unused, length: MemoryLayout<PassParameters>.stride, index: 2)
        e.setFragmentBytes(&v, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
      }
      try gpu.run { try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: a, into: $0) }
      gpu.run { encodeInline($0) }
      XCTAssertTrue(pass.usesSpecializedPipeline)
      XCTAssertEqual(Pixels(a).values, Pixels(b).values, "\(w)×\(h): identical pixels")
      // Interleaved minima. The GPU is shared with other processes during a full
      // test run, so a round that loses to contention is measured again (three
      // rounds at most); identical code cannot lose all three.
      var l = Double.infinity, hst = 0.0
      for _ in 0..<3 {
        if l <= hst * 1.05 + 0.005 { break }
        var library: [Double] = [], host: [Double] = []
        for i in 0..<70 {
          for useLibrary in [true, false] {
            let cb = gpu.queue.makeCommandBuffer()!
            if useLibrary { try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: a, into: cb) } else { encodeInline(cb) }
            cb.commit()
            cb.waitUntilCompleted()
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if i >= 10 { if useLibrary { library.append(ms) } else { host.append(ms) } }
          }
        }
        (l, hst) = (library.min()!, host.min()!)
        print(String(format: "BENCH inline host vs library, 4K v210 -> %dx%d + LUT: host %.3f ms, library %.3f ms", w, h, hst, l))
      }
      XCTAssertLessThanOrEqual(l, hst * 1.05 + 0.005, "\(w)×\(h): the library costs more than inline code")
    }
  }

  func testStatusAndParametersAreCachedNotRebuiltPerFrame() throws {
    let gpu = try requireGPU()
    let (frame, feed, pass, state, target) = try setUp(gpu)
    try gpu.run { cb in
      try feed.analyze(frame, focus: state.focus, into: cb)
      try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb)
    }
    let labels = pass.status.activeLabels
    XCTAssertTrue(labels.contains("Six band"))
    XCTAssertTrue(labels.contains { $0.hasPrefix("Zebra 1 · 95+ IRE") })
    XCTAssertTrue(labels.contains { $0.hasPrefix("Zebra 2 · 65–75 IRE") })
    XCTAssertTrue(labels.contains("Peaking"))
    XCTAssertTrue(labels.contains("Guides"))
    XCTAssertTrue(labels.contains { $0.hasPrefix("LUT · ") })
    // Six-band false colour on the output stage replaces the picture, and no tool
    // reads the monitor stage: nothing drawn passes the monitor LUT, so it is not listed.
    XCTAssertFalse(labels.contains { $0.hasPrefix("Monitor LUT · ") })
    XCTAssertTrue(labels.contains("Display adjusted"))
    XCTAssertTrue(pass.status.unavailable.isEmpty, "\(pass.status.unavailable)")
    let rebuilds = pass.statusRebuildCount
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: state, target: target, into: cb) }
    XCTAssertEqual(pass.statusRebuildCount, rebuilds, "the same inputs rebuild no status")
    var monitorStage = state
    monitorStage.falseColor.stage = .monitor
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: monitorStage, target: target, into: cb) }
    XCTAssertTrue(pass.status.activeLabels.contains { $0.hasPrefix("Monitor LUT · ") })
  }

  func testEngineIsSharedAcrossThreads() throws {
    let gpu = try requireGPU()
    let engine = gpu.engine
    DispatchQueue.concurrentPerform(iterations: 8) { i in
      let format: MTLPixelFormat = [.bgra8Unorm, .rgba16Float, .rgba8Unorm, .bgra8Unorm_srgb][i % 4]
      do { try engine.prepare(pixelFormat: format, layouts: [.v210]) } catch { XCTFail("\(error)") }
      _ = engine.makeFeed()
      _ = engine.makePass()
    }
  }
}

/// Four feeds, two surfaces each, eight viewports in one target and one command
/// buffer: each viewport must equal its surface drawn alone.
final class MultiFeedTests: XCTestCase {
  func testFourFeedsTwoSurfacesEachInOneCommandBufferWithoutCrossTalk() throws {
    let gpu = try requireGPU()
    let size = 96
    var feeds: [(MonitorFrame, MonitorFeed)] = []
    for i in 0..<4 {
      // Distinct pictures: different levels and an edge at a different place for each feed.
      let picture = SyntheticFrame.neutral(.v210, width: 192, height: 108) { x, _ in x < 40 + i * 30 ? 200 + i * 100 : 800 - i * 50 }
      let frame = try picture.frame(gpu, signal: .rec709)
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
    let target = gpu.target(size * 4, size * 2)
    try gpu.run { cb in
      for (frame, feed) in feeds { try feed.analyze(frame, focus: surfaceState(0, 0).focus, into: cb) }
      for i in 0..<8 {
        let (frame, feed) = feeds[i / 2]
        let viewport = MonitorViewport(x: (i % 4) * size, y: (i / 4) * size, width: size, height: size)
        try passes[i].encode(frame: frame, feed: feed, state: surfaceState(i / 2, i % 2), target: target,
                             viewport: viewport, clear: i == 0, into: cb)
      }
      XCTAssertEqual(cb.status, .notEnqueued)
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
    // The surfaces really differ from each other.
    XCTAssertNotEqual(combined[size / 2, size / 2], combined[size + size / 2, size / 2])
  }
}
