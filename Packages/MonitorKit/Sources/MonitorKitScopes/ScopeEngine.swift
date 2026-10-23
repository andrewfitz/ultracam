import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import Synchronization

/// Compiled scope kernels and render pipelines for one device. Immutable after
/// init apart from locked pipeline caches, and safe to share across feeds,
/// surfaces and threads. Uses the host's device; creates no queues or threads.
///
/// Every kernel and the fragment shader work for any frame layout and scope
/// from general pipelines. The compute ones are built at init; a render
/// pipeline is built per host render-pass format on first use (on this thread,
/// or with `.asynchronous` on Metal's compiler threads: the common colour
/// formats start building at init, and a renderer draws nothing until its
/// format's pipeline is ready). Specialized pipelines (one frame layout's
/// decode; one scope kind's drawing; a group's fused pass) are built as
/// `specialization` says and replace the general ones once ready.
///
/// Every accumulator, group and renderer also encodes on Metal 4
/// (`MonitorSubmission`), with the same pipelines and results.
public final class ScopeEngine: @unchecked Sendable {
  public let device: MTLDevice
  public let library: MTLLibrary
  public let specialization: PipelineSpecialization
  /// Uniform slots per accumulator, group and renderer on the Metal 4 path: the
  /// submissions a host keeps in flight. A host that has more grows the rings once.
  public let framesInFlight: Int
  /// Everything the scopes own or read for the host on the Metal 4 path (bins,
  /// statistics, traces, graticules, uniform rings, placeholders, LUT textures),
  /// with deferred release. Attach `residency.set` to the host's `MTL4CommandQueue`
  /// once, or pass `MonitorEngine.residency` at init so one set covers both.
  public let residency: MonitorResidency
  /// The persistent warm start, when the engine was made with a `cacheDirectory`:
  /// the library and every pipeline are built by its `MTL4Compiler`, looked up in
  /// it first, and new ones are saved to it.
  public let pipelineArchive: MonitorPipelineArchive?
  /// Clear and finalize of one accumulation, and of a fused group's members (function constant 4).
  let clearPipeline: MTLComputePipelineState
  let finalizePipeline: MTLComputePipelineState
  let groupClearPipeline: MTLComputePipelineState
  let groupFinalizePipeline: MTLComputePipelineState
  let resolvePipeline: MTLComputePipelineState
  /// Rasterizes graticule shapes into an r8 coverage texture (max blend).
  let graticulePipeline: MTLRenderPipelineState
  let vertexFunction: MTLFunction
  /// Bound when the host's pass has depth or stencil: always passes, never writes.
  let depthStencil: MTLDepthStencilState
  /// Bound in place of textures a layout or stage does not read, so API
  /// validation never sees a missing binding.
  let placeholderPacked: MTLTexture
  let placeholderPlane: MTLTexture
  let placeholderLUT: MTLTexture
  /// Bound as the trace before a renderer has one.
  let placeholderTrace: MTLTexture
  /// Threadgroup memory a scope kernel may use for its private bins.
  let threadgroupMemoryBudget: Int

  /// Accumulation kernels.
  enum Kernel: String, CaseIterable, Sendable {
    case waveform = "mk_scopeWaveform"
    case vectorscope = "mk_scopeVector"
    case histogram = "mk_scopeHistogram"
    case fused = "mk_scopeFused"
  }

  /// A compute pipeline: the kernel, the frame layout it decodes (nil: any,
  /// read at run time) and, for the fused kernel, which scopes it feeds.
  struct ComputeKey: Hashable, Sendable {
    var kernel: Kernel
    var layout: UInt32?
    var scopes: FusedScopes = []
  }

  /// A render pipeline: the host pass's formats and, when specialized, the scope it draws.
  struct RenderKey: Hashable, Sendable {
    var target: MonitorRenderTargetFormat
    var scope: DrawVariant?
  }

  struct DrawVariant: Hashable, Sendable {
    var kind: UInt32
    var mode: UInt32
  }

  /// Colour formats whose general render pipeline an asynchronous engine starts
  /// building at init: drawables, EDR layers and the common offscreen formats.
  static let prewarmedPixelFormats: [MTLPixelFormat] = [
    .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float, .bgr10a2Unorm, .rgba8Unorm,
  ]

  private let generalCompute: [Kernel: MTLComputePipelineState]
  private let computePipelines = Mutex<[ComputeKey: MTLComputePipelineState]>([:])
  private let renderPipelines = Mutex<[RenderKey: MTLRenderPipelineState]>([:])
  /// Builds started and not finished; a failed one stays here, so it is never
  /// retried. Internal for tests.
  let pendingCompute = Mutex<Set<ComputeKey>>([])
  let pendingRender = Mutex<Set<RenderKey>>([])
  /// Builds that failed, asynchronous or on this thread; none is retried.
  /// Callers fall back to the general pipeline for good. Internal for tests.
  let failedCompute = Mutex<Set<ComputeKey>>([])
  let failedRender = Mutex<Set<RenderKey>>([])
  private let failures = Mutex<[String]>([])
  /// Broadcast whenever an asynchronous build stores or fails, so warm-up on
  /// another thread joins a build already running instead of compiling it again.
  private let buildFinished = NSCondition()
  /// Pipelines built on the calling thread (compute, render). Internal for tests.
  let builtOnCallerThread = Mutex<(compute: Int, render: Int)>((0, 0))

  /// Binds MK_LAYOUT to function constant 0 when a pipeline defines it.
  static let specializationPrefix = """
    #include <metal_stdlib>
    using namespace metal;
    constant uint mk_layoutConstant [[function_constant(0)]];
    constant bool mk_layoutDefined = is_function_constant_defined(mk_layoutConstant);
    #define MK_LAYOUT(f) (mk_layoutDefined ? mk_layoutConstant : (f).shape.x)
    """

  /// `residency` nil makes the engine its own set; pass a `MonitorEngine`'s to
  /// share it (all of its Metal 4 work then goes on that engine's queue).
  public convenience init(
    device: MTLDevice, specialization: PipelineSpecialization = .asynchronous, framesInFlight: Int = 3,
    residency: MonitorResidency? = nil
  ) throws {
    try self.init(
      device: device, specialization: specialization, framesInFlight: framesInFlight, residency: residency,
      cacheDirectory: nil)
  }

  /// `init(device:specialization:framesInFlight:residency:)` with a persistent
  /// warm start in `cacheDirectory` (created when missing; it may be the
  /// `MonitorEngine`'s: the files are named per engine). The library and every
  /// pipeline are then built by `pipelineArchive`'s `MTL4Compiler`, looked up in
  /// the archive files of earlier launches first, and new ones are saved at the
  /// end of `prepare(pixelFormats:)` and `prepare(settings:layouts:pixelFormats:)`
  /// (the start-up warm-up calls: they block for the file I/O) and shortly after
  /// any built otherwise, `prepare(target:)` included (off the caller's thread and
  /// the frame path). A stale or damaged archive is ignored. Pixels are identical with or
  /// without one. Nil: no cache, as the other initializer.
  public init(
    device: MTLDevice, specialization: PipelineSpecialization = .asynchronous, framesInFlight: Int = 3,
    residency: MonitorResidency? = nil, cacheDirectory: URL?
  ) throws {
    self.device = device
    self.specialization = specialization
    self.framesInFlight = min(16, max(1, framesInFlight))
    self.residency = try residency ?? MonitorResidency(device: device, label: "MonitorKit scopes")
    let libraryDescriptor = try MonitorShaders.libraryDescriptor(
      parts: [.lut, .decode], prefix: Self.specializationPrefix, extra: Self.scopeSource(), name: "MonitorKitScopes")
    let archive = try cacheDirectory.map {
      try MonitorPipelineArchive(
        device: device, directory: $0, name: "MonitorKitScopes", source: libraryDescriptor.source ?? "",
        options: MonitorShaders.compileOptions)
    }
    pipelineArchive = archive
    let library: MTLLibrary
    if let archive {
      do {
        library = try archive.makeLibrary(descriptor: libraryDescriptor)
      } catch {
        throw MonitorKitError.gpu("The MTL4Compiler cannot build the MonitorKit scope library: \(error)")
      }
    } else {
      library = try MonitorShaders.makeLibrary(
        device: device, parts: [.lut, .decode], prefix: Self.specializationPrefix, extra: Self.scopeSource())
    }
    self.library = library
    func function(_ name: String, group: Bool? = nil) throws -> MTLFunction {
      do {
        return try library.makeFunction(name: name, constantValues: Self.groupConstants(group))
      } catch {
        throw MonitorKitError.gpu("MonitorKit scope function \(name) is missing: \(error)")
      }
    }
    func pipeline(_ name: String, group: Bool? = nil) throws -> MTLComputePipelineState {
      if let archive {
        return try archive.makeComputePipelineState(
          descriptor: Self.computeDescriptor(library, name, Self.groupConstants(group)))
      }
      return try device.makeComputePipelineState(function: function(name, group: group))
    }
    var general: [Kernel: MTLComputePipelineState] = [:]
    for kernel in [Kernel.waveform, .vectorscope, .histogram] { general[kernel] = try pipeline(kernel.rawValue) }
    generalCompute = general
    clearPipeline = try pipeline("mk_scopeClear", group: false)
    finalizePipeline = try pipeline("mk_scopeFinalize", group: false)
    groupClearPipeline = try pipeline("mk_scopeClear", group: true)
    groupFinalizePipeline = try pipeline("mk_scopeFinalize", group: true)
    resolvePipeline = try pipeline("mk_scopeResolve")
    vertexFunction = try function("mk_scopeVertex")

    if let archive {
      let graticule = MTL4RenderPipelineDescriptor()
      graticule.label = "MonitorKit scope graticule"
      graticule.vertexFunctionDescriptor = Self.functionDescriptor(library, "mk_graticuleVertex", nil)
      graticule.fragmentFunctionDescriptor = Self.functionDescriptor(library, "mk_graticuleFragment", nil)
      let coverage = graticule.colorAttachments[0]!
      coverage.pixelFormat = .r8Unorm
      coverage.blendingState = .enabled
      coverage.rgbBlendOperation = .max
      coverage.alphaBlendOperation = .max
      coverage.sourceRGBBlendFactor = .one
      coverage.destinationRGBBlendFactor = .one
      coverage.sourceAlphaBlendFactor = .one
      coverage.destinationAlphaBlendFactor = .one
      graticulePipeline = try archive.makeRenderPipelineState(descriptor: graticule)
    } else {
      let graticule = MTLRenderPipelineDescriptor()
      graticule.label = "MonitorKit scope graticule"
      graticule.vertexFunction = try function("mk_graticuleVertex")
      graticule.fragmentFunction = try function("mk_graticuleFragment")
      let coverage = graticule.colorAttachments[0]!
      coverage.pixelFormat = .r8Unorm
      // Overlapping shapes keep the larger coverage, as one pass over all of them would.
      coverage.isBlendingEnabled = true
      coverage.rgbBlendOperation = .max
      coverage.alphaBlendOperation = .max
      coverage.sourceRGBBlendFactor = .one
      coverage.destinationRGBBlendFactor = .one
      coverage.sourceAlphaBlendFactor = .one
      coverage.destinationAlphaBlendFactor = .one
      graticulePipeline = try device.makeRenderPipelineState(descriptor: graticule)
    }

    let ds = MTLDepthStencilDescriptor()
    ds.depthCompareFunction = .always
    ds.isDepthWriteEnabled = false
    guard let state = device.makeDepthStencilState(descriptor: ds) else {
      throw MonitorKitError.gpu("Cannot create the scope depth-stencil state.")
    }
    depthStencil = state

    func texture(_ format: MTLPixelFormat, type: MTLTextureType = .type2D, size: Int = 1) throws -> MTLTexture {
      let d = MTLTextureDescriptor()
      d.textureType = type
      d.pixelFormat = format
      d.width = size
      d.height = size
      d.depth = type == .type3D ? size : 1
      d.usage = .shaderRead
      d.storageMode = .private
      guard let t = device.makeTexture(descriptor: d) else {
        throw MonitorKitError.gpu("Cannot allocate a scope placeholder texture.")
      }
      return t
    }
    placeholderPacked = try texture(.rgba32Uint)
    placeholderPlane = try texture(.r8Unorm)
    placeholderLUT = try texture(.rgba32Float, type: .type3D, size: 2)
    placeholderTrace = try texture(.r16Unorm)
    for t in [placeholderPacked, placeholderPlane, placeholderLUT, placeholderTrace] { self.residency.add(t) }
    // Dynamic threadgroup memory shares the limit with each kernel's static
    // statistics block (the fused kernel's is the same 12 words; 64 bytes of
    // headroom cover a compiler that pads it differently per specialization).
    let statics = general.values.map(\.staticThreadgroupMemoryLength).max() ?? 0
    threadgroupMemoryBudget = (min(device.maxThreadgroupMemoryLength, 32 * 1024) - statics - 64) / 16 * 16

    switch specialization {
    case .asynchronous:
      for format in Self.prewarmedPixelFormats {
        buildAsync(RenderKey(target: MonitorRenderTargetFormat(colorPixelFormat: format), scope: nil))
      }
    case .off:
      // The all-tools fused kernels, so a group fuses without compiling on a frame.
      for scopes in [FusedScopes([.waveform, .histogram]), [.waveform, .vectorscope], [.histogram, .vectorscope],
        [.waveform, .histogram, .vectorscope]]
      {
        buildAsync(ComputeKey(kernel: .fused, layout: nil, scopes: scopes))
      }
    case .synchronous: break
    }
  }

  deinit {
    // The placeholders were added to `residency` with counts; a shared one
    // (`MonitorEngine.residency`) outlives this engine, so they leave it once
    // the submissions that may still read them complete.
    for t in [placeholderPacked, placeholderPlane, placeholderLUT, placeholderTrace] { residency.retire(t, resident: t) }
  }

  /// MKScopes.msl alone. It needs `MonitorShaders.source([.lut, .decode])` before it.
  public static func scopeSource() throws -> String {
    guard
      let url = Bundle.module.url(forResource: "MKScopes", withExtension: "msl", subdirectory: "Shaders")
        ?? Bundle.module.url(forResource: "MKScopes", withExtension: "msl")
    else { throw MonitorKitError.gpu("MonitorKit shader MKScopes is missing from the bundle.") }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The layer formats a monitor host draws scopes into: `bgr10a2Unorm` (SDR
  /// and wide-gamut layers), `rgba16Float` (EDR layers for PQ and HLG) and
  /// `bgra8Unorm` (8-bit drawables). The default of `prepare(pixelFormats:)`.
  public static let drawablePixelFormats: [MTLPixelFormat] = [.bgr10a2Unorm, .rgba16Float, .bgra8Unorm]

  /// Warm-up at start-up: makes the general render pipeline of every format
  /// in `pixelFormats` ready before returning, so a layer switched to EDR draws
  /// on its first frame. A built one costs a lookup; one an asynchronous engine
  /// is already building (it starts every `drawablePixelFormats` format at
  /// init) is waited for, not compiled again; any other is built on this
  /// thread. The output colour (`ScopeRenderer.colorPipeline`) is a uniform, so
  /// one pipeline per format covers SDR, PQ and HLG. Pipelines are shared by
  /// the classic and Metal 4 paths; `prepareMetal4()` on each object makes its
  /// argument table.
  ///
  /// On `.asynchronous` and `.off` engines no draw into these formats then
  /// waits for the compiler. A `.synchronous` engine still builds each scope's
  /// specialized pipeline on the thread of its first draw: warm it with
  /// `prepare(settings:layouts:pixelFormats:)` for the kinds and modes it draws.
  ///
  /// A format that fails does not stop the others: every format is tried, then
  /// the first error is thrown (`pipelineBuildFailures` lists each).
  public func prepare(pixelFormats: [MTLPixelFormat] = ScopeEngine.drawablePixelFormats) throws {
    defer { pipelineArchive?.save() }
    var firstError: (any Error)?
    var i = 0
    while i < pixelFormats.count {
      do {
        let target = MonitorRenderTargetFormat(colorPixelFormat: pixelFormats[i])
        _ = try preparedRenderPipeline(RenderKey(target: target, scope: nil))
      } catch {
        firstError = firstError ?? error
      }
      i += 1
    }
    if let firstError { throw firstError }
  }

  /// `prepare(settings:layouts:pixelFormat:)` for every format in
  /// `pixelFormats`. Every pipeline is tried even after one fails; the first
  /// error is thrown at the end.
  public func prepare(settings: [ScopeSettings], layouts: [PixelLayout], pixelFormats: [MTLPixelFormat]) throws {
    defer { pipelineArchive?.save() }
    if pixelFormats.isEmpty { return try prepareUnsaved(settings: settings, layouts: layouts, target: nil) }
    var firstError: (any Error)?
    var i = 0
    while i < pixelFormats.count {
      do {
        try prepareUnsaved(
          settings: settings, layouts: layouts, target: MonitorRenderTargetFormat(colorPixelFormat: pixelFormats[i]))
      } catch {
        firstError = firstError ?? error
      }
      i += 1
    }
    if let firstError { throw firstError }
  }

  /// Whether the general render pipeline for `target` is built, so a draw into
  /// it renders now (an asynchronous engine draws nothing until it is).
  public func isPrepared(target: MonitorRenderTargetFormat) -> Bool {
    renderPipelines.withLock { $0[RenderKey(target: target, scope: nil)] != nil }
  }

  /// `isPrepared(target:)` for a single-attachment pass of `pixelFormat`.
  public func isPrepared(pixelFormat: MTLPixelFormat) -> Bool {
    isPrepared(target: MonitorRenderTargetFormat(colorPixelFormat: pixelFormat))
  }

  /// Makes the general render pipeline for `pixelFormat` ready ahead of the
  /// first draw: built on this thread, or waited for when an asynchronous
  /// build of it is already running.
  public func prepare(pixelFormat: MTLPixelFormat) throws {
    try prepare(target: MonitorRenderTargetFormat(colorPixelFormat: pixelFormat))
  }

  /// Makes the general render pipeline for a host render pass with these
  /// formats (depth, stencil, sample count, extra colour attachments) ready
  /// ahead of the first draw: built on this thread, or waited for when an
  /// asynchronous build of it is already running.
  public func prepare(target: MonitorRenderTargetFormat) throws {
    _ = try preparedRenderPipeline(RenderKey(target: target, scope: nil))
  }

  /// Makes every pipeline `settings` needs for frames of `layouts` drawn into
  /// `pixelFormat` ready (built on this thread, or waited for when already
  /// building asynchronously), so the first frames use specialized ones. A
  /// `.off` engine draws with the general pipelines only, so it builds just
  /// the general render pipeline for `pixelFormat` (its general kernels are
  /// made at init).
  public func prepare(settings: [ScopeSettings], layouts: [PixelLayout], pixelFormat: MTLPixelFormat?) throws {
    try prepare(
      settings: settings, layouts: layouts, target: pixelFormat.map { MonitorRenderTargetFormat(colorPixelFormat: $0) })
  }

  /// `prepare(settings:layouts:pixelFormat:)` for a host render pass with these
  /// formats. Every pipeline is tried even after one fails; the first error is
  /// thrown at the end.
  public func prepare(settings: [ScopeSettings], layouts: [PixelLayout], target: MonitorRenderTargetFormat?) throws {
    try prepareUnsaved(settings: settings, layouts: layouts, target: target)
  }

  /// `prepare(settings:layouts:target:)`; the bulk callers save the archive once at the end.
  private func prepareUnsaved(settings: [ScopeSettings], layouts: [PixelLayout], target: MonitorRenderTargetFormat?)
    throws
  {
    var firstError: (any Error)?
    func attempt(_ build: () throws -> Void) {
      do { try build() } catch { firstError = firstError ?? error }
    }
    if let target { attempt { _ = try preparedRenderPipeline(RenderKey(target: target, scope: nil)) } }
    // `.off` never draws with a specialized pipeline: building one would only
    // cost start-up compile time and memory.
    if specialization != .off {
      for s in settings.map({ $0.normalized() }) {
        for layout in layouts {
          attempt { _ = try preparedComputePipeline(ComputeKey(kernel: s.kind.kernel, layout: layout.scopeLayoutCode)) }
        }
        if let target {
          attempt {
            _ = try preparedRenderPipeline(
              RenderKey(target: target, scope: DrawVariant(kind: s.kind.shaderCode, mode: s.shaderMode)))
          }
        }
      }
    }
    if let firstError { throw firstError }
  }

  /// `computePipeline(_:)` for warm-up: first waits for an asynchronous build
  /// of `key` that is already running, so it is not compiled twice. Never on a frame.
  func preparedComputePipeline(_ key: ComputeKey) throws -> MTLComputePipelineState {
    awaitBuild { pendingCompute.withLock { $0.contains(key) } && !isFinished(key) }
    return try computePipeline(key)
  }

  /// `renderPipeline(_:)` for warm-up: first waits for an asynchronous build
  /// of `key` that is already running, so it is not compiled twice. Never on a frame.
  func preparedRenderPipeline(_ key: RenderKey) throws -> MTLRenderPipelineState {
    awaitBuild { pendingRender.withLock { $0.contains(key) } && !isFinished(key) }
    return try renderPipeline(key)
  }

  private func isFinished(_ key: ComputeKey) -> Bool {
    computePipelines.withLock { $0[key] != nil } || failedCompute.withLock { $0.contains(key) }
  }

  private func isFinished(_ key: RenderKey) -> Bool {
    renderPipelines.withLock { $0[key] != nil } || failedRender.withLock { $0.contains(key) }
  }

  /// Waits while `running` (an asynchronous build of the key started and has
  /// neither stored nor failed). Metal calls every completion handler; after a
  /// minute without one the caller builds the pipeline itself instead.
  private func awaitBuild(while running: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 60)
    buildFinished.lock()
    defer { buildFinished.unlock() }
    while running() {
      if !buildFinished.wait(until: deadline) { return }
    }
  }

  /// Wakes warm-up waiting for an asynchronous build. Called after the caches
  /// and the pending and failed sets are updated, so no wake-up is lost.
  private func signalBuildFinished() {
    buildFinished.lock()
    buildFinished.broadcast()
    buildFinished.unlock()
  }

  /// Pipeline builds that failed (asynchronous and synchronous), oldest first.
  /// None is retried. Each falls back to the general pipeline (a group whose
  /// fused kernels failed accumulates its members one by one), so nothing is
  /// drawn wrong; only a failed general render pipeline makes drawing into that
  /// format throw. The list is for logs.
  public var pipelineBuildFailures: [String] { failures.withLock { $0 } }

  // MARK: compute pipelines

  /// The pipeline for `key` if built (or built here when synchronous),
  /// otherwise the general one while it builds. The bool is whether the result
  /// is final: the one asked for, or the general one for good after its build
  /// failed (on this thread too: a failed synchronous build is not retried).
  /// `.off` returns the general one even when `key` itself is cached.
  func computePipeline(for key: ComputeKey) throws -> (MTLComputePipelineState, Bool) {
    if specialization != .off, let cached = computePipelines.withLock({ $0[key] }) { return (cached, true) }
    var general = key
    general.layout = nil
    switch specialization {
    case .off: return (try computePipeline(general), true)
    case .synchronous:
      if key.layout != nil, let specialized = try? computePipeline(key) { return (specialized, true) }
      return (try computePipeline(general), true)
    case .asynchronous:
      if key.layout == nil { return (try computePipeline(key), true) }
      if failedCompute.withLock({ $0.contains(key) }) { return (try computePipeline(general), true) }
      buildAsync(key)
      return (try computePipeline(general), false)
    }
  }

  /// The fused pipeline for `key` if it can be used now: specialized when
  /// built (or built here when synchronous), the all-tools one when
  /// specialization is off or the specialized build failed. Nil while an
  /// asynchronous build runs: the group accumulates scope by scope meanwhile,
  /// so no frame waits for the compiler. The bool is whether the result is
  /// final (nil and final: this group cannot be fused, e.g. both builds failed).
  func fusedPipeline(for key: ComputeKey) -> (MTLComputePipelineState?, Bool) {
    if specialization != .off, let cached = computePipelines.withLock({ $0[key] }) { return (cached, true) }
    var general = key
    general.layout = nil
    switch specialization {
    case .synchronous:
      if let specialized = try? computePipeline(key) { return (specialized, true) }
      if key.layout != nil, let all = try? computePipeline(general) { return (all, true) }
      return (nil, true)
    case .off: return cachedOrBuilding(general)
    case .asynchronous:
      if !failedCompute.withLock({ $0.contains(key) }) {
        buildAsync(key)
        return (nil, false)
      }
      return cachedOrBuilding(general)
    }
  }

  /// `key` if cached; otherwise starts its asynchronous build. Nil and final once it failed.
  private func cachedOrBuilding(_ key: ComputeKey) -> (MTLComputePipelineState?, Bool) {
    if let cached = computePipelines.withLock({ $0[key] }) { return (cached, true) }
    if failedCompute.withLock({ $0.contains(key) }) { return (nil, true) }
    buildAsync(key)
    return (nil, false)
  }

  /// Builds `key` on this thread if it is not cached. A failure is recorded,
  /// and asking again throws without rebuilding.
  func computePipeline(_ key: ComputeKey) throws -> MTLComputePipelineState {
    if key.layout == nil, key.scopes.isEmpty, let general = generalCompute[key.kernel] { return general }
    if let cached = computePipelines.withLock({ $0[key] }) { return cached }
    if failedCompute.withLock({ $0.contains(key) }) {
      throw MonitorKitError.gpu("The scope kernel \(key.kernel.rawValue) \(key) failed to build.")
    }
    builtOnCallerThread.withLock { $0.compute += 1 }
    do {
      if let pipelineArchive {
        return store(try pipelineArchive.makeComputePipelineState(descriptor: computeDescriptor(key)), for: key)
      }
      let function = try library.makeFunction(name: key.kernel.rawValue, constantValues: Self.constants(key))
      return store(try device.makeComputePipelineState(function: function), for: key)
    } catch {
      failed(key, error)
      throw MonitorKitError.gpu("Cannot build the scope kernel \(key.kernel.rawValue): \(error)")
    }
  }

  /// Starts building `key` on Metal's compiler threads unless it is cached or already started.
  private func buildAsync(_ key: ComputeKey) {
    guard pendingCompute.withLock({ $0.insert(key).inserted }) else { return }
    if let pipelineArchive {
      // The compiler's asynchronous build (Metal's compiler threads) awaited from a
      // task; no thread or queue of the library's own.
      Task.detached(priority: .utility) { [self] in
        do {
          built(try await pipelineArchive.makeComputePipelineState(descriptor: computeDescriptor(key)), for: key)
        } catch {
          failed(key, error)
        }
      }
      return
    }
    library.makeFunction(name: key.kernel.rawValue, constantValues: Self.constants(key)) { [self] function, error in
      guard let function else { return failed(key, error) }
      device.makeComputePipelineState(function: function) { [self] state, error in
        guard let state else { return failed(key, error) }
        built(state, for: key)
      }
    }
  }

  /// An asynchronous build of `key` finished. Internal for tests.
  func built(_ state: MTLComputePipelineState, for key: ComputeKey) {
    store(state, for: key)
    _ = pendingCompute.withLock { $0.remove(key) }
    signalBuildFinished()
  }

  /// A build of `key` failed. Internal for tests.
  func failed(_ key: ComputeKey, _ error: (any Error)?) {
    _ = failedCompute.withLock { $0.insert(key) }
    record("scope kernel \(key.kernel.rawValue) \(key): \(error.map { "\($0)" } ?? "unknown error")")
    signalBuildFinished()
  }

  private func record(_ failure: String) { failures.withLock { $0.append(failure) } }

  @discardableResult
  private func store(_ state: MTLComputePipelineState, for key: ComputeKey) -> MTLComputePipelineState {
    computePipelines.withLock { cache in
      if let raced = cache[key] { return raced }
      cache[key] = state
      return state
    }
  }

  static func constants(_ key: ComputeKey) -> MTLFunctionConstantValues {
    let values = MTLFunctionConstantValues()
    if var layout = key.layout { values.setConstantValue(&layout, type: .uint, index: 0) }
    if key.kernel == .fused {
      var waveform = key.scopes.contains(.waveform), histogram = key.scopes.contains(.histogram)
      var vectorscope = key.scopes.contains(.vectorscope)
      values.setConstantValue(&waveform, type: .bool, index: 1)
      values.setConstantValue(&histogram, type: .bool, index: 2)
      values.setConstantValue(&vectorscope, type: .bool, index: 3)
    }
    return values
  }

  // MARK: render pipelines

  /// The specialized pipeline for `key` if built (or built here when
  /// synchronous), otherwise the general one for its target while it builds,
  /// or for good once the specialized build failed. With `.asynchronous` the
  /// general one is never built here either: nil until it is ready. The bool
  /// is whether the result is final. Throws only when the general one failed.
  /// `.off` returns the general one even when `key` itself is cached.
  func renderPipeline(for key: RenderKey) throws -> (MTLRenderPipelineState?, Bool) {
    if specialization != .off, let cached = renderPipelines.withLock({ $0[key] }) { return (cached, true) }
    let general = RenderKey(target: key.target, scope: nil)
    switch specialization {
    case .off: return (try renderPipeline(general), true)
    case .synchronous:
      if key.scope != nil, let specialized = try? renderPipeline(key) { return (specialized, true) }
      return (try renderPipeline(general), true)
    case .asynchronous:
      let specializedFailed = key.scope == nil || failedRender.withLock { $0.contains(key) }
      if !specializedFailed { buildAsync(key) }
      if let cached = renderPipelines.withLock({ $0[general] }) { return (cached, specializedFailed) }
      if failedRender.withLock({ $0.contains(general) }) {
        throw MonitorKitError.gpu("Cannot draw scopes into \(key.target): the pipeline build failed.")
      }
      buildAsync(general)
      return (nil, false)
    }
  }

  /// Builds `key` on this thread if it is not cached. A failure is recorded,
  /// and asking again throws without rebuilding.
  func renderPipeline(_ key: RenderKey) throws -> MTLRenderPipelineState {
    if let cached = renderPipelines.withLock({ $0[key] }) { return cached }
    if failedRender.withLock({ $0.contains(key) }) {
      throw MonitorKitError.gpu("Cannot draw scopes into \(key.target): the pipeline build failed.")
    }
    builtOnCallerThread.withLock { $0.render += 1 }
    do {
      if let pipelineArchive {
        return store(try pipelineArchive.makeRenderPipelineState(descriptor: metal4Descriptor(key)), for: key)
      }
      let fragment = try library.makeFunction(name: "mk_scopeFragment", constantValues: Self.constants(key))
      return store(try device.makeRenderPipelineState(descriptor: descriptor(key, fragment: fragment)), for: key)
    } catch {
      failed(key, error)
      throw MonitorKitError.gpu("Cannot draw scopes into \(key.target): \(error)")
    }
  }

  private func buildAsync(_ key: RenderKey) {
    guard pendingRender.withLock({ $0.insert(key).inserted }) else { return }
    if let pipelineArchive {
      Task.detached(priority: .utility) { [self] in
        do {
          built(try await pipelineArchive.makeRenderPipelineState(descriptor: metal4Descriptor(key)), for: key)
        } catch {
          failed(key, error)
        }
      }
      return
    }
    library.makeFunction(name: "mk_scopeFragment", constantValues: Self.constants(key)) { [self] function, error in
      guard let function else { return failed(key, error) }
      device.makeRenderPipelineState(descriptor: descriptor(key, fragment: function)) { [self] state, error in
        guard let state else { return failed(key, error) }
        built(state, for: key)
      }
    }
  }

  /// An asynchronous build of `key` finished. Internal for tests.
  func built(_ state: MTLRenderPipelineState, for key: RenderKey) {
    store(state, for: key)
    _ = pendingRender.withLock { $0.remove(key) }
    signalBuildFinished()
  }

  /// A build of `key` failed. Internal for tests.
  func failed(_ key: RenderKey, _ error: (any Error)?) {
    _ = failedRender.withLock { $0.insert(key) }
    record("scope render pipeline \(key): \(error.map { "\($0)" } ?? "unknown error")")
    signalBuildFinished()
  }

  @discardableResult
  private func store(_ state: MTLRenderPipelineState, for key: RenderKey) -> MTLRenderPipelineState {
    renderPipelines.withLock { cache in
      if let raced = cache[key] { return raced }
      cache[key] = state
      return state
    }
  }

  static func constants(_ key: RenderKey) -> MTLFunctionConstantValues {
    let values = MTLFunctionConstantValues()
    if let scope = key.scope {
      var kind = scope.kind, mode = scope.mode
      values.setConstantValue(&kind, type: .uint, index: 10)
      values.setConstantValue(&mode, type: .uint, index: 11)
    }
    return values
  }

  func descriptor(_ key: RenderKey, fragment: MTLFunction) -> MTLRenderPipelineDescriptor {
    let d = MTLRenderPipelineDescriptor()
    d.label = "MonitorKit scope"
    d.vertexFunction = vertexFunction
    d.fragmentFunction = fragment
    let target = key.target
    let attachment = d.colorAttachments[0]!
    attachment.pixelFormat = target.colorPixelFormat
    // Premultiplied over: the scope background darkens what is behind it and
    // the trace adds light.
    attachment.isBlendingEnabled = true
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    // The host pass's other attachments are left untouched.
    var i = 0
    while i < min(target.additionalColorPixelFormats.count, 7) {
      d.colorAttachments[i + 1].pixelFormat = target.additionalColorPixelFormats[i]
      d.colorAttachments[i + 1].writeMask = []
      i += 1
    }
    d.depthAttachmentPixelFormat = target.depthPixelFormat
    d.stencilAttachmentPixelFormat = target.stencilPixelFormat
    d.rasterSampleCount = target.sampleCount
    return d
  }

  /// `descriptor(_:fragment:)` for the archive's `MTL4Compiler`: the same functions,
  /// constants, blending and attachments (a Metal 4 render pipeline has no depth
  /// or stencil format, so it draws in any host pass).
  func metal4Descriptor(_ key: RenderKey) -> MTL4RenderPipelineDescriptor {
    let d = MTL4RenderPipelineDescriptor()
    d.label = "MonitorKit scope"
    d.vertexFunctionDescriptor = Self.functionDescriptor(library, "mk_scopeVertex", nil)
    d.fragmentFunctionDescriptor = Self.functionDescriptor(library, "mk_scopeFragment", Self.constants(key))
    let target = key.target
    let attachment = d.colorAttachments[0]!
    attachment.pixelFormat = target.colorPixelFormat
    attachment.blendingState = .enabled
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    var i = 0
    while i < min(target.additionalColorPixelFormats.count, 7) {
      d.colorAttachments[i + 1].pixelFormat = target.additionalColorPixelFormats[i]
      d.colorAttachments[i + 1].writeMask = []
      i += 1
    }
    d.rasterSampleCount = target.sampleCount
    return d
  }

  /// The compute pipeline for `key`, for the archive's `MTL4Compiler`.
  func computeDescriptor(_ key: ComputeKey) -> MTL4ComputePipelineDescriptor {
    Self.computeDescriptor(library, key.kernel.rawValue, Self.constants(key))
  }

  static func computeDescriptor(_ library: MTLLibrary, _ name: String, _ values: MTLFunctionConstantValues)
    -> MTL4ComputePipelineDescriptor
  {
    let d = MTL4ComputePipelineDescriptor()
    d.label = "MonitorKit \(name)"
    d.computeFunctionDescriptor = functionDescriptor(library, name, values)
    return d
  }

  /// `name` in `library`, specialized with `values` (empty when nil), as
  /// `makeFunction(name:constantValues:)` makes it on the device path.
  static func functionDescriptor(_ library: MTLLibrary, _ name: String, _ values: MTLFunctionConstantValues?)
    -> MTL4FunctionDescriptor
  {
    let function = MTL4LibraryFunctionDescriptor()
    function.name = name
    function.library = library
    let specialized = MTL4SpecializedFunctionDescriptor()
    specialized.functionDescriptor = function
    specialized.constantValues = values ?? MTLFunctionConstantValues()
    return specialized
  }

  /// Function constant 4 (a fused group's clear and finalize) when `group` is set.
  static func groupConstants(_ group: Bool?) -> MTLFunctionConstantValues {
    let values = MTLFunctionConstantValues()
    if var group { values.setConstantValue(&group, type: .bool, index: 4) }
    return values
  }

  /// Specialized pipelines built so far (compute: one frame layout's kernels,
  /// fused or not; render: one scope's drawing). The all-tools fused kernels
  /// are general and not counted.
  var specializedPipelineCount: (compute: Int, render: Int) {
    (
      computePipelines.withLock { $0.keys.filter { $0.layout != nil }.count },
      renderPipelines.withLock { $0.keys.filter { $0.scope != nil }.count }
    )
  }

  /// An argument table for one of the scopes' Metal 4 encoders, made once per object.
  func makeArgumentTable(textures: Int, buffers: Int, label: String) throws -> any MTL4ArgumentTable {
    let d = MTL4ArgumentTableDescriptor()
    d.maxTextureBindCount = textures
    d.maxBufferBindCount = buffers
    d.label = label
    do {
      return try device.makeArgumentTable(descriptor: d)
    } catch {
      throw MonitorKitError.gpu("Cannot create the \(label) argument table: \(error)")
    }
  }

  public func makeAccumulator(settings: ScopeSettings = ScopeSettings()) throws -> ScopeAccumulator {
    try ScopeAccumulator(engine: self, settings: settings)
  }

  public func makeRenderer() -> ScopeRenderer { ScopeRenderer(engine: self) }

  /// A group that accumulates `accumulators` (made by this engine) together.
  public func makeGroup(_ accumulators: [ScopeAccumulator]) throws -> ScopeGroup {
    try ScopeGroup(engine: self, accumulators: accumulators)
  }
}

extension MonitorRenderTargetFormat {
  var needsDepthStencilState: Bool { depthPixelFormat != .invalid || stencilPixelFormat != .invalid }
}

/// Scopes one fused accumulation pass feeds.
struct FusedScopes: OptionSet, Hashable, Sendable {
  let rawValue: UInt8
  static let waveform = FusedScopes(rawValue: 1)
  static let histogram = FusedScopes(rawValue: 2)
  static let vectorscope = FusedScopes(rawValue: 4)
}

extension ScopeKind {
  var kernel: ScopeEngine.Kernel {
    switch self {
    case .waveform: return .waveform
    case .vectorscope: return .vectorscope
    case .histogram: return .histogram
    }
  }
}

extension PixelLayout {
  /// `mk_FrameParams.shape.x`, the value MK_LAYOUT is specialized to.
  var scopeLayoutCode: UInt32 {
    switch self {
    case .v210: return 0
    case .uyvy8: return 1
    case .yuyv8: return 2
    case .biplanar: return 3
    case .rgb: return 4
    }
  }
}

extension MTLPixelFormat {
  /// Formats whose stores encode with the sRGB curve.
  var isSRGB: Bool {
    switch self {
    case .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgr10_xr_srgb, .bgra10_xr_srgb, .r8Unorm_srgb, .rg8Unorm_srgb:
      return true
    default: return false
    }
  }
}
