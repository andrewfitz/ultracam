// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Metal
import MonitorKitCore
import Synchronization

/// The attachments of the render pass the picture is drawn into. The picture
/// goes to colour attachment 0; any further colour attachments are left untouched,
/// and depth and stencil are neither tested nor written.
public struct MonitorRenderTargetFormat: Hashable, Sendable {
  /// Format of colour attachment 0, which the picture is drawn into.
  public var colorPixelFormat: MTLPixelFormat
  /// Depth attachment format of the host's pass, or `.invalid`.
  public var depthPixelFormat: MTLPixelFormat
  /// Stencil attachment format of the host's pass, or `.invalid`.
  public var stencilPixelFormat: MTLPixelFormat
  /// Samples per pixel of the host's pass (1 without MSAA).
  public var sampleCount: Int
  /// Formats of colour attachments 1, 2, … of the host's pass (`.invalid` for a gap).
  public var additionalColorPixelFormats: [MTLPixelFormat]

  /// The attachments of a host pass; `sampleCount` is at least 1.
  public init(
    colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat = .invalid,
    stencilPixelFormat: MTLPixelFormat = .invalid, sampleCount: Int = 1,
    additionalColorPixelFormats: [MTLPixelFormat] = []
  ) {
    self.colorPixelFormat = colorPixelFormat
    self.depthPixelFormat = depthPixelFormat
    self.stencilPixelFormat = stencilPixelFormat
    self.sampleCount = max(1, sampleCount)
    self.additionalColorPixelFormats = additionalColorPixelFormats
  }

  /// The formats of a host's render pass. Read it when the pass changes, not per frame.
  public init(_ descriptor: MTLRenderPassDescriptor) {
    let first = descriptor.colorAttachments[0].texture
    var extra: [MTLPixelFormat] = []
    for i in 1..<8 {
      if let t = descriptor.colorAttachments[i].texture {
        while extra.count < i - 1 { extra.append(.invalid) }
        extra.append(t.pixelFormat)
      }
    }
    let depth = descriptor.depthAttachment.texture, stencil = descriptor.stencilAttachment.texture
    self.init(
      colorPixelFormat: first?.pixelFormat ?? .invalid, depthPixelFormat: depth?.pixelFormat ?? .invalid,
      stencilPixelFormat: stencil?.pixelFormat ?? .invalid,
      sampleCount: first?.sampleCount ?? depth?.sampleCount ?? stencil?.sampleCount ?? 1, additionalColorPixelFormats: extra)
  }

  var hasDepthOrStencil: Bool { depthPixelFormat != .invalid || stencilPixelFormat != .invalid }
}

/// How the engine builds pipelines specialized to a surface's tool set.
public enum PipelineSpecialization: Sendable {
  /// Draw with the all-tools pipeline while the specialized one compiles on
  /// Metal's compiler threads, then switch. Never stalls a frame (the default):
  /// the all-tools pipeline reads the output colour and display transform from
  /// the uniforms, so one per target format and layout serves every colour
  /// setting, and `prepare` builds it ahead of the first frame.
  case asynchronous
  /// Compile the specialized pipeline on first use, on the calling thread.
  case synchronous
  /// Always use the all-tools pipeline (colour stages driven by the uniforms).
  case off
}

/// One per GPU, shared by every feed and surface. Compiles the shaders once and
/// builds the pipelines; immutable after init apart from locked pipeline caches,
/// which passes look up only when their target, layout or tool set changes.
/// Safe to share across threads.
public final class MonitorEngine: @unchecked Sendable {
  public let device: MTLDevice
  public let specialization: PipelineSpecialization
  /// Uniform slots per pass and feed on the Metal 4 path: the submissions a host
  /// keeps in flight. A host that has more grows the rings once, never per frame.
  public let framesInFlight: Int
  /// Every allocation the library owns or reads for the host on the Metal 4 path,
  /// and their deferred release. Attach `residency.set` to the host's
  /// `MTL4CommandQueue` once; all of an engine's Metal 4 work goes on that queue.
  public let residency: MonitorResidency
  /// MKLUT + MKDecode + MKMonitor, compiled once with `MK_LAYOUT` and the tool
  /// tiers bound to function constants: every entry point must be specialized.
  let library: MTLLibrary
  /// The host's Metal 4 compiler, when the engine was built with one: the library
  /// and every pipeline then come from it (`MTL4LibraryDescriptor`,
  /// `MTL4RenderPipelineDescriptor`, `MTL4ComputePipelineDescriptor`, its
  /// asynchronous compiler tasks for specialization), so they land in its
  /// pipeline data set serializer and lookup archives. With a `cacheDirectory` it
  /// is `pipelineArchive`'s compiler. Nil: the device builds them.
  public let compiler: (any MTL4Compiler)?
  /// The persistent warm start, when the engine was made with a `cacheDirectory`:
  /// every pipeline is looked up in it first, and new ones are saved to it.
  public let pipelineArchive: MonitorPipelineArchive?

  private let vertexFunction: MTLFunction
  private let renderPipelines = Mutex<[PipelineKey: MTLRenderPipelineState]>([:])
  private enum BuildKey: Hashable {
    case render(PipelineKey), compute(PipelineKey), focus(FocusKey), copy(Bool)
  }
  private let pendingPipelines = Mutex<Set<BuildKey>>([])
  /// Asynchronous specializations that failed: not started again for the
  /// engine's lifetime (the pass keeps the stand-in, which draws the same pixels),
  /// rather than once a frame. A synchronous build of the key (`warmUp`,
  /// `.synchronous`) still runs, and its success is what later lookups find.
  private let failedPipelines = Mutex<Set<BuildKey>>([])
  private let asynchronousBuilds = Atomic<Int>(0)
  /// Asynchronous specializations started (render and compute), for tests.
  var asynchronousBuildsStarted: Int { asynchronousBuilds.load(ordering: .relaxed) }
  /// Asynchronous specializations that failed, for tests.
  var failedPipelineCount: Int { failedPipelines.withLock { $0.count } }
  private let buildFinished = NSCondition()
  /// The pending builds owned by a background task or Metal completion handler.
  private let asynchronousOwners = Mutex<Set<BuildKey>>([])
  /// Seconds a synchronous caller waits for a background build of its key before
  /// it compiles the pipeline itself (internal, so tests can shorten it). A task
  /// owner needs a free cooperative-pool thread to finish: callers blocked here
  /// must never be all that stands between it and one.
  let asynchronousJoinTimeout = Mutex<Double>(5)
  /// Synchronous builds that gave up waiting for a background owner, for tests.
  private let abandonedJoins = Atomic<Int>(0)
  var asynchronousJoinsAbandoned: Int { abandonedJoins.load(ordering: .relaxed) }
  private let focusPipelines = Mutex<[FocusKey: MTLComputePipelineState]>([:])
  private let computePipelines = Mutex<[PipelineKey: MTLComputePipelineState]>([:])
  private let copyPipelines = Mutex<(uint: MTLComputePipelineState?, float: MTLComputePipelineState?)>((nil, nil))
  private let createdResources = Atomic<Int>(0)
  private let builtPipelines = Atomic<Int>(0)
  private let callerBuiltPipelines = Atomic<Int>(0)
  private let callerComputeBuilds = Atomic<Int>(0)
  /// Synchronous compute compiler invocations, including focus and Freeze.
  var computeCompilationsOnCaller: Int { callerComputeBuilds.load(ordering: .relaxed) }
  /// Depth and stencil always pass and are never written, so the picture draws
  /// the same inside any host pass.
  let depthStencil: MTLDepthStencilState

  /// A tool set: the tiers of `mk_picture` a pipeline compiles in.
  struct Variant: Hashable {
    /// Bit 0: the burn-in LUT is read, bit 1: the monitor LUT, bit 2: no distinct
    /// output reading is read (`MK_LUTS` bit 2: the Output and Monitor stages share
    /// the source decode, or nothing drawn reads them), so no second decode is compiled.
    var luts: UInt32
    var zebras: Bool
    var peaking: Bool
    var guides: Bool
    /// Bit 0: log modes, bit 1: stage modes.
    var falseColor: UInt32
    var interpolates: Bool
    var navigator: Bool
    var adjust: Bool
    var clip: Bool = false
    /// The stage the picture shows (0 source, 1 output, 2 monitor); 3 reads it from the uniforms.
    var pictureStage: UInt32 = 2
    static let uber = Variant(
      luts: 3, zebras: true, peaking: true, guides: true, falseColor: 3, interpolates: true, navigator: true,
      adjust: true, clip: true, pictureStage: 3)
  }

  /// How the surface's picture becomes target values (`MonitorColorPipeline` codes),
  /// fixed in a specialized pipeline. The all-tools stand-in uses `uniforms`: the
  /// same code reads the codes from `PassParameters.color`, so it draws the same
  /// pixels and a colour change never needs a new stand-in.
  struct ColorKey: Hashable {
    var transform: UInt32 = 0
    var picture: UInt32 = 1
    var target: UInt32 = 0
    var rolloff = false
    /// The log curve of the display assist (`transform` 1; `PassParameters.luts.z`
    /// codes), 0 otherwise or to read it from the uniforms.
    var logCurve: UInt32 = 0
    /// The colour stages follow the uniforms instead of these codes.
    var uniforms = false
    static let fromUniforms = ColorKey(uniforms: true)
  }

  struct PipelineKey: Hashable {
    var target: MonitorRenderTargetFormat
    var layout: UInt32
    var variant: Variant
    var color = ColorKey()
  }

  struct FocusKey: Hashable {
    var layout: UInt32
    /// `MK_LUTS` of the analysis: 0 the source, 1 after the burn-in LUT, 3 after
    /// both (a missing one is disabled at run time). The output stage, the common
    /// LUT stage, compiles only the one LUT it applies.
    var luts: UInt32

    init(layout: UInt32, burnInLUT: Bool, monitorLUT: Bool) {
      self.layout = layout
      luts = monitorLUT ? 3 : (burnInLUT ? 1 : 0)
    }
  }

  /// Binds MK_LAYOUT, the tool tiers, the target's sRGB encode and the output
  /// colour to function constants 0–15 (15: the colour stages read the uniforms,
  /// for the all-tools stand-in), the picture stage to 16 (3: the uniforms) and the
  /// display assist's log curve to 17 (0: the uniforms).
  static let specializationPrefix = """
    #include <metal_stdlib>
    using namespace metal;
    constant uint mk_layoutConstant [[function_constant(0)]];
    constant uint mk_lutsConstant [[function_constant(1)]];
    constant bool mk_zebrasConstant [[function_constant(2)]];
    constant uint mk_falseColorConstant [[function_constant(3)]];
    constant bool mk_interpolatesConstant [[function_constant(4)]];
    constant bool mk_navigatorConstant [[function_constant(5)]];
    constant bool mk_peakingConstant [[function_constant(6)]];
    constant bool mk_guidesConstant [[function_constant(7)]];
    constant bool mk_adjustConstant [[function_constant(8)]];
    constant bool mk_srgbConstant [[function_constant(9)]];
    constant uint mk_transformConstant [[function_constant(10)]];
    constant uint mk_pictureTFConstant [[function_constant(11)]];
    constant uint mk_targetTFConstant [[function_constant(12)]];
    constant bool mk_rolloffConstant [[function_constant(13)]];
    constant bool mk_clipConstant [[function_constant(14)]];
    constant bool mk_colorUniformsConstant [[function_constant(15)]];
    constant uint mk_pictureStageConstant [[function_constant(16)]];
    constant uint mk_logCurveConstant [[function_constant(17)]];
    #define MK_LAYOUT(f) mk_layoutConstant
    #define MK_LUTS mk_lutsConstant
    #define MK_ZEBRAS mk_zebrasConstant
    #define MK_PEAKING mk_peakingConstant
    #define MK_GUIDES mk_guidesConstant
    #define MK_ADJUST mk_adjustConstant
    #define MK_SRGB_TARGET mk_srgbConstant
    #define MK_FALSE_COLOR mk_falseColorConstant
    #define MK_INTERPOLATES mk_interpolatesConstant
    #define MK_NAVIGATOR mk_navigatorConstant
    #define MK_TRANSFORM (mk_colorUniformsConstant ? p.color.x : mk_transformConstant)
    #define MK_PICTURE_TF (mk_colorUniformsConstant ? p.color.y : mk_pictureTFConstant)
    #define MK_TARGET_TF (mk_colorUniformsConstant ? p.color.z : mk_targetTFConstant)
    #define MK_ROLLOFF (mk_colorUniformsConstant ? p.colorFlags.x != 0 : mk_rolloffConstant)
    #define MK_CLIP mk_clipConstant
    #define MK_PICTURE_STAGE (mk_pictureStageConstant > 2u ? uint(p.falseColor.z) : mk_pictureStageConstant)
    #define MK_LOG_CURVE (mk_colorUniformsConstant || mk_logCurveConstant == 0u ? p.luts.z : mk_logCurveConstant)
    """

  /// Bound in place of inputs a pass does not use, so every argument is valid.
  let emptyPacked: MTLTexture
  let emptyFloat: MTLTexture
  let emptyLUT: MTLTexture

  /// Compiles the library. Pipelines are built on first use or by `prepare` /
  /// `warmUp`. `framesInFlight` sizes the Metal 4 uniform rings (default 3).
  /// With `compiler` (a Metal 4 host's `MTL4Compiler`, made from `device`) the
  /// library and pipelines are built by it, with `MonitorShaders.compileOptions`;
  /// the pixels are the same either way. Its pipelines draw in Metal 4 and classic
  /// encoders alike; a Metal 4 render pipeline carries no depth or stencil format,
  /// which suits any host pass.
  public convenience init(
    device: MTLDevice, specialization: PipelineSpecialization = .asynchronous, framesInFlight: Int = 3,
    compiler: (any MTL4Compiler)? = nil
  ) throws {
    try self.init(
      device: device, specialization: specialization, framesInFlight: framesInFlight, compiler: compiler,
      cacheDirectory: nil)
  }

  /// `init(device:specialization:framesInFlight:compiler:)` with a persistent warm
  /// start in `cacheDirectory` (the host's caches directory, e.g. a subdirectory
  /// of `.cachesDirectory`; created when missing). The engine then builds with
  /// `pipelineArchive`'s own `MTL4Compiler`, which records every pipeline (a host
  /// `compiler` is not used), looks each one up in the archive files saved by
  /// earlier launches, and saves new ones at the end of `warmUp` and shortly after
  /// any built later (off the frame path). An archive of other shaders, another
  /// OS build or another GPU, or a damaged file, is ignored: those pipelines
  /// compile as without a cache. Pixels are identical with or without one. Nil:
  /// no cache, as the other initializer.
  public init(
    device: MTLDevice, specialization: PipelineSpecialization = .asynchronous, framesInFlight: Int = 3,
    compiler: (any MTL4Compiler)? = nil, cacheDirectory: URL?
  ) throws {
    self.device = device
    self.specialization = specialization
    self.framesInFlight = min(16, max(1, framesInFlight))
    residency = try MonitorResidency(device: device)
    let libraryDescriptor = try MonitorShaders.libraryDescriptor(
      parts: [.lut, .decode, .monitor], prefix: Self.specializationPrefix, name: "MonitorKit")
    let archive = try cacheDirectory.map {
      try MonitorPipelineArchive(
        device: device, directory: $0, name: "MonitorKit", source: libraryDescriptor.source ?? "",
        options: MonitorShaders.compileOptions)
    }
    pipelineArchive = archive
    let compiler = archive?.compiler ?? compiler
    self.compiler = compiler
    let library: MTLLibrary
    if let compiler {
      do {
        library = try compiler.makeLibrary(descriptor: libraryDescriptor)
      } catch let error as MonitorKitError {
        throw error
      } catch {
        throw MonitorKitError.gpu("The MTL4Compiler cannot build the MonitorKit library: \(error)")
      }
    } else {
      library = try MonitorShaders.makeLibrary(
        device: device, parts: [.lut, .decode, .monitor], prefix: Self.specializationPrefix)
    }
    self.library = library
    guard let vertex = library.makeFunction(name: "mk_fullscreen") else {
      throw MonitorKitError.gpu("MonitorKit shader function mk_fullscreen is missing.")
    }
    vertexFunction = vertex
    let ds = MTLDepthStencilDescriptor()
    ds.depthCompareFunction = .always
    ds.isDepthWriteEnabled = false
    guard let state = device.makeDepthStencilState(descriptor: ds) else {
      throw MonitorKitError.gpu("Cannot create the MonitorKit depth-stencil state.")
    }
    depthStencil = state

    func placeholder(_ type: MTLTextureType, _ format: MTLPixelFormat, _ size: Int, _ bytesPerPixel: Int)
      throws -> MTLTexture
    {
      let d = MTLTextureDescriptor()
      d.textureType = type
      d.pixelFormat = format
      d.width = size
      d.height = size
      d.depth = type == .type3D ? size : 1
      d.usage = .shaderRead
      d.storageMode = .shared
      guard let t = device.makeTexture(descriptor: d) else {
        throw MonitorKitError.gpu("Cannot allocate a MonitorKit placeholder texture.")
      }
      let count = size * size * d.depth * bytesPerPixel
      let zeros = [UInt8](repeating: 0, count: count)
      zeros.withUnsafeBytes {
        t.replace(
          region: MTLRegionMake3D(0, 0, 0, size, size, d.depth), mipmapLevel: 0, slice: 0,
          withBytes: $0.baseAddress!, bytesPerRow: size * bytesPerPixel,
          bytesPerImage: size * size * bytesPerPixel)
      }
      t.label = "MonitorKit placeholder"
      return t
    }
    emptyPacked = try placeholder(.type2D, .rgba32Uint, 1, 16)
    emptyFloat = try placeholder(.type2D, .rgba8Unorm, 1, 4)
    emptyLUT = try placeholder(.type3D, .rgba32Float, 2, 16)
    residency.add(emptyPacked)
    residency.add(emptyFloat)
    residency.add(emptyLUT)
    if specialization == .asynchronous { buildCopyPipelinesAsynchronously() }
  }

  /// Builds now, instead of on first use, everything a frame of these layouts
  /// can need into `pixelFormat`: the all-tools picture pipelines, the focus
  /// analysis pipelines of each stage and Freeze's copy kernels (so the first Freeze compiles
  /// nothing on the encoding thread). All five layout kinds when `layouts` is nil.
  public func prepare(pixelFormat: MTLPixelFormat, layouts: [PixelLayout]? = nil) throws {
    try prepare(target: MonitorRenderTargetFormat(colorPixelFormat: pixelFormat), layouts: layouts)
  }

  /// `prepare(pixelFormat:layouts:)` for a host render pass with these attachments.
  public func prepare(target: MonitorRenderTargetFormat, layouts: [PixelLayout]? = nil) throws {
    try prepare(target: target, layouts: layouts, compute: false)
  }

  /// `prepare(target:layouts:)`. The all-tools pipeline reads the output colour and
  /// display transform from the uniforms, so the colour arguments need no pipeline
  /// of their own: kept for source compatibility.
  public func prepare(
    target: MonitorRenderTargetFormat, layouts: [PixelLayout]? = nil, outputColor: MonitorOutputColor,
    signal: SignalDescription, displayTransform: DisplayTransformSettings = .init(), monitorStageHasLUT: Bool = false
  ) throws {
    try prepare(target: target, layouts: layouts, compute: false)
  }

  func prepare(target: MonitorRenderTargetFormat, layouts: [PixelLayout]?, compute: Bool) throws {
    let kinds = layouts.map { $0.map(\.shaderKind) } ?? Array(0...4)
    for kind in Set(kinds) {
      let key = PipelineKey(target: target, layout: kind, variant: .uber, color: .fromUniforms)
      if compute { _ = try computePipeline(key) } else { _ = try renderPipeline(key) }
      for (burn, monitor) in [(false, false), (true, false), (true, true)] {
        _ = try focusPipeline(FocusKey(layout: kind, burnInLUT: burn, monitorLUT: monitor))
      }
    }
    _ = try copyPipeline(integer: true)
    _ = try copyPipeline(integer: false)
  }

  /// `prepare(pixelFormat:layouts:)` for `MonitorPass.encodeCompute`, which writes
  /// a shader-writable target from a compute kernel. The colour arguments need no
  /// pipeline of their own (see `prepare(target:layouts:outputColor:…)`).
  public func prepareCompute(
    pixelFormat: MTLPixelFormat, layouts: [PixelLayout]? = nil, outputColor: MonitorOutputColor = .signalNative,
    signal: SignalDescription = .rec709, displayTransform: DisplayTransformSettings = .init(),
    monitorStageHasLUT: Bool = false
  ) throws {
    try prepare(target: MonitorRenderTargetFormat(colorPixelFormat: pixelFormat), layouts: layouts, compute: true)
  }

  /// A new feed: the per-camera state (LUTs, focus mask, Freeze) that every surface
  /// showing that camera shares. Make one per source, not per frame. A feed is not
  /// `Sendable`: use it from one thread at a time (your render thread).
  public func makeFeed() -> MonitorFeed { MonitorFeed(engine: self) }
  /// A new pass: the per-surface encoder that draws one feed's frame with one
  /// `MonitorState` into a target. Make one per surface, not per frame. A pass is
  /// not `Sendable`: use it from one thread at a time (your render thread).
  public func makePass() -> MonitorPass { MonitorPass(engine: self) }

  /// GPU textures and buffers created by this engine's feeds and passes since
  /// init (pipelines and placeholders excluded). Constant in steady state.
  public var resourcesCreated: Int { createdResources.load(ordering: .relaxed) }

  /// Picture pipelines built so far (render, and compute for `encodeCompute`),
  /// all-tools and specialized. Focus-analysis and Freeze kernels are not counted.
  public var pipelinesBuilt: Int { builtPipelines.load(ordering: .relaxed) }
  /// Picture pipelines compiled on the calling thread (by `prepare`, a first frame
  /// of a new target format or layout, or `.synchronous` specialization). With
  /// `.asynchronous`, a colour, transform or tool change never adds to it.
  var pipelinesBuiltOnCaller: Int { callerBuiltPipelines.load(ordering: .relaxed) }
  /// Focus-analysis pipelines built so far.
  var focusPipelineCount: Int { focusPipelines.withLock { $0.count } }

  static func constants(layout: UInt32, variant: Variant, srgbTarget: Bool = false, color: ColorKey = ColorKey())
    -> MTLFunctionConstantValues
  {
    let values = MTLFunctionConstantValues()
    var kind = layout, luts = variant.luts, zebras = variant.zebras, falseColor = variant.falseColor
    var interpolates = variant.interpolates, navigator = variant.navigator
    var peaking = variant.peaking, guides = variant.guides, adjust = variant.adjust
    values.setConstantValue(&kind, type: .uint, index: 0)
    values.setConstantValue(&luts, type: .uint, index: 1)
    values.setConstantValue(&zebras, type: .bool, index: 2)
    values.setConstantValue(&falseColor, type: .uint, index: 3)
    values.setConstantValue(&interpolates, type: .bool, index: 4)
    values.setConstantValue(&navigator, type: .bool, index: 5)
    values.setConstantValue(&peaking, type: .bool, index: 6)
    values.setConstantValue(&guides, type: .bool, index: 7)
    values.setConstantValue(&adjust, type: .bool, index: 8)
    var srgb = srgbTarget
    values.setConstantValue(&srgb, type: .bool, index: 9)
    var transform = color.transform, picture = color.picture, target = color.target
    var rolloff = color.rolloff, clip = variant.clip, uniforms = color.uniforms
    values.setConstantValue(&transform, type: .uint, index: 10)
    values.setConstantValue(&picture, type: .uint, index: 11)
    values.setConstantValue(&target, type: .uint, index: 12)
    values.setConstantValue(&rolloff, type: .bool, index: 13)
    values.setConstantValue(&clip, type: .bool, index: 14)
    values.setConstantValue(&uniforms, type: .bool, index: 15)
    var pictureStage = variant.pictureStage
    values.setConstantValue(&pictureStage, type: .uint, index: 16)
    var logCurve = color.logCurve
    values.setConstantValue(&logCurve, type: .uint, index: 17)
    return values
  }

  func descriptor(_ key: PipelineKey, fragment: MTLFunction) -> MTLRenderPipelineDescriptor {
    let d = MTLRenderPipelineDescriptor()
    d.label = "MonitorKit picture"
    d.vertexFunction = vertexFunction
    d.fragmentFunction = fragment
    d.colorAttachments[0].pixelFormat = key.target.colorPixelFormat
    for (i, format) in key.target.additionalColorPixelFormats.prefix(7).enumerated() {
      d.colorAttachments[i + 1].pixelFormat = format
      d.colorAttachments[i + 1].writeMask = []
    }
    d.depthAttachmentPixelFormat = key.target.depthPixelFormat
    d.stencilAttachmentPixelFormat = key.target.stencilPixelFormat
    d.rasterSampleCount = key.target.sampleCount
    return d
  }

  /// `descriptor(_:fragment:)` for the host's `MTL4Compiler`: the same functions,
  /// attachments and constants (a Metal 4 render pipeline has no depth or stencil format).
  func metal4Descriptor(_ key: PipelineKey, values: MTLFunctionConstantValues) -> MTL4RenderPipelineDescriptor {
    let d = MTL4RenderPipelineDescriptor()
    d.label = "MonitorKit picture"
    let vertex = MTL4LibraryFunctionDescriptor()
    vertex.name = "mk_fullscreen"
    vertex.library = library
    let fragment = MTL4LibraryFunctionDescriptor()
    fragment.name = "mk_picture"
    fragment.library = library
    let specialized = MTL4SpecializedFunctionDescriptor()
    specialized.functionDescriptor = fragment
    specialized.constantValues = values
    d.vertexFunctionDescriptor = vertex
    d.fragmentFunctionDescriptor = specialized
    d.colorAttachments[0].pixelFormat = key.target.colorPixelFormat
    for (i, format) in key.target.additionalColorPixelFormats.prefix(7).enumerated() {
      d.colorAttachments[i + 1].pixelFormat = format
      d.colorAttachments[i + 1].writeMask = []
    }
    d.rasterSampleCount = key.target.sampleCount
    return d
  }

  /// A compute function, specialized when `values` is given, for the host's `MTL4Compiler`.
  func metal4ComputeDescriptor(_ name: String, _ values: MTLFunctionConstantValues?) -> MTL4ComputePipelineDescriptor {
    let function = MTL4LibraryFunctionDescriptor()
    function.name = name
    function.library = library
    let d = MTL4ComputePipelineDescriptor()
    d.label = "MonitorKit \(name)"
    if let values {
      let specialized = MTL4SpecializedFunctionDescriptor()
      specialized.functionDescriptor = function
      specialized.constantValues = values
      d.computeFunctionDescriptor = specialized
    } else {
      d.computeFunctionDescriptor = function
    }
    return d
  }

  /// A compute pipeline for `name` (specialized with `values`), by the compiler or the device.
  func makeComputeState(_ name: String, _ values: MTLFunctionConstantValues?) throws -> MTLComputePipelineState {
    callerComputeBuilds.add(1, ordering: .relaxed)
    if let compiler {
      return try makeComputeState(metal4ComputeDescriptor(name, values), compiler)
    }
    let function: MTLFunction
    if let values {
      function = try library.makeFunction(name: name, constantValues: values)
    } else {
      guard let f = library.makeFunction(name: name) else {
        throw MonitorKitError.gpu("MonitorKit shader function \(name) is missing.")
      }
      function = f
    }
    return try device.makeComputePipelineState(function: function)
  }

  /// Builds with `pipelineArchive` (looked up in its files first, recorded for the
  /// next save) when the engine has one, else with the host's `compiler`.
  private func makeRenderState(_ d: MTL4RenderPipelineDescriptor, _ compiler: any MTL4Compiler) throws
    -> MTLRenderPipelineState
  {
    if let pipelineArchive { return try pipelineArchive.makeRenderPipelineState(descriptor: d) }
    return try compiler.makeRenderPipelineState(descriptor: d)
  }

  private func makeRenderState(_ d: MTL4RenderPipelineDescriptor, _ compiler: any MTL4Compiler) async throws
    -> MTLRenderPipelineState
  {
    if let pipelineArchive { return try await pipelineArchive.makeRenderPipelineState(descriptor: d) }
    return try await compiler.makeRenderPipelineState(descriptor: d)
  }

  private func makeComputeState(_ d: MTL4ComputePipelineDescriptor, _ compiler: any MTL4Compiler) throws
    -> MTLComputePipelineState
  {
    if let pipelineArchive { return try pipelineArchive.makeComputePipelineState(descriptor: d) }
    return try compiler.makeComputePipelineState(descriptor: d)
  }

  private func makeComputeState(_ d: MTL4ComputePipelineDescriptor, _ compiler: any MTL4Compiler) async throws
    -> MTLComputePipelineState
  {
    if let pipelineArchive { return try await pipelineArchive.makeComputePipelineState(descriptor: d) }
    return try await compiler.makeComputePipelineState(descriptor: d)
  }

  /// The picture pipeline for `key`, built on this thread if it is not cached.
  func renderPipeline(_ key: PipelineKey) throws -> MTLRenderPipelineState {
    if let cached = renderPipelines.withLock({ $0[key] }) { return cached }
    let buildKey = BuildKey.render(key)
    let owns = beginBuild(buildKey)
    defer { if owns { finishBuild(buildKey) } }
    if let cached = renderPipelines.withLock({ $0[key] }) { return cached }
    let state: MTLRenderPipelineState
    do {
      let values = Self.constants(
        layout: key.layout, variant: key.variant, srgbTarget: key.target.colorPixelFormat.isSRGB, color: key.color)
      if let compiler {
        state = try makeRenderState(metal4Descriptor(key, values: values), compiler)
      } else {
        let fragment = try library.makeFunction(name: "mk_picture", constantValues: values)
        state = try device.makeRenderPipelineState(descriptor: descriptor(key, fragment: fragment))
      }
    } catch {
      throw MonitorKitError.gpu("Cannot draw into pixel format \(key.target.colorPixelFormat.rawValue): \(error)")
    }
    callerBuiltPipelines.add(1, ordering: .relaxed)
    return store(state, for: key)
  }

  private func store(_ state: MTLRenderPipelineState, for key: PipelineKey) -> MTLRenderPipelineState {
    renderPipelines.withLock { cache in
      if let raced = cache[key] { return raced }
      cache[key] = state
      builtPipelines.add(1, ordering: .relaxed)
      return state
    }
  }

  /// The specialized pipeline for `key` if it is ready. Otherwise starts building
  /// it (once) and returns nil; with `.synchronous` it is built here.
  func specializedPipeline(_ key: PipelineKey) throws -> MTLRenderPipelineState? {
    switch specialization {
    case .off: return nil
    case .synchronous: return try renderPipeline(key)
    case .asynchronous:
      if let cached = renderPipelines.withLock({ $0[key] }) { return cached }
      let buildKey = BuildKey.render(key)
      guard claimAsynchronous(buildKey) else { return nil }
      if let cached = renderPipelines.withLock({ $0[key] }) {
        finishBuild(buildKey)
        return cached
      }
      asynchronousBuilds.add(1, ordering: .relaxed)
      if compiler != nil {
        // The compiler's asynchronous build (Metal's compiler threads) awaited from
        // a task; no thread or queue of the library's own.
        Task.detached(priority: .utility) { [self] in
          // Keep the claim terminal on every exit, including task cancellation or
          // an unexpected compiler failure. A stranded claim makes all future
          // callers treat this key as permanently in flight.
          defer { finishBuild(buildKey) }
          guard let compiler else {
            failedPipelines.withLock { _ = $0.insert(buildKey) }
            return
          }
          let descriptor = metal4Descriptor(key, values: Self.constants(
            layout: key.layout, variant: key.variant, srgbTarget: key.target.colorPixelFormat.isSRGB, color: key.color))
          do {
            let state = try await makeRenderState(descriptor, compiler)
            _ = store(state, for: key)
          } catch {
            failedPipelines.withLock { _ = $0.insert(buildKey) }
          }
        }
        return nil
      }
      let values = Self.constants(
        layout: key.layout, variant: key.variant, srgbTarget: key.target.colorPixelFormat.isSRGB, color: key.color)
      library.makeFunction(name: "mk_picture", constantValues: values) { [self] function, _ in
        guard let function else { return finishFailed(buildKey) }
        device.makeRenderPipelineState(descriptor: descriptor(key, fragment: function)) { [self] state, _ in
          guard let state else { return finishFailed(buildKey) }
          _ = store(state, for: key)
          finish(key)
        }
      }
      return nil
    }
  }

  /// Completes an asynchronous build that stored its pipeline.
  private func finish(_ key: PipelineKey) { finishBuild(.render(key)) }

  /// Completes an asynchronous specialization that failed: remembered, so the
  /// next prepare does not start the same failing compile again (once a frame).
  private func finishFailed(_ key: BuildKey) {
    failedPipelines.withLock { _ = $0.insert(key) }
    finishBuild(key)
  }

  /// Cold synchronous callers join an existing build of the key. Cache hits never
  /// reach this condition, and different keys compile independently. True: the
  /// caller owns the key and must `finishBuild` it. A synchronous owner is waited
  /// for as long as it takes; a background owner only `asynchronousJoinTimeout`
  /// seconds, after which the caller compiles without the key (false), so a
  /// starved task pool or a lost completion never hangs the frame for good.
  private func beginBuild(_ key: BuildKey) -> Bool {
    let timeout = asynchronousJoinTimeout.withLock { $0 }
    var deadline = Date(timeIntervalSinceNow: timeout)
    buildFinished.lock()
    defer { buildFinished.unlock() }
    while !pendingPipelines.withLock({ $0.insert(key).inserted }) {
      if buildFinished.wait(until: deadline) { continue }
      guard asynchronousOwners.withLock({ $0.contains(key) }) else {
        deadline = Date(timeIntervalSinceNow: timeout)
        continue
      }
      abandonedJoins.add(1, ordering: .relaxed)
      return false
    }
    return true
  }

  /// Takes `key` for a background build, or false when a build of it is pending.
  private func claimAsynchronous(_ key: BuildKey) -> Bool {
    buildFinished.lock()
    defer { buildFinished.unlock() }
    // A completion records its failure before clearing its claim under this
    // condition. Check both here so a stale lookup cannot restart a failed build.
    guard !failedPipelines.withLock({ $0.contains(key) }),
      pendingPipelines.withLock({ $0.insert(key).inserted }) else { return false }
    asynchronousOwners.withLock { _ = $0.insert(key) }
    return true
  }

  private func finishBuild(_ key: BuildKey) {
    buildFinished.lock()
    pendingPipelines.withLock { _ = $0.remove(key) }
    asynchronousOwners.withLock { _ = $0.remove(key) }
    buildFinished.broadcast()
    buildFinished.unlock()
  }

  /// Tests only: holds the copy kernel's key as a background build that never
  /// finishes, as a task starved of a pool thread would. `finishHeldCopyBuild` ends it.
  func holdCopyBuildForTesting(integer: Bool) -> Bool { claimAsynchronous(.copy(integer)) }
  func finishHeldCopyBuild(integer: Bool) { finishBuild(.copy(integer)) }

  /// The compute picture pipeline for `key` (its target's colour format only), built here if not cached.
  func computePipeline(_ key: PipelineKey) throws -> MTLComputePipelineState {
    let key = Self.computeKey(key)
    if let cached = computePipelines.withLock({ $0[key] }) { return cached }
    let buildKey = BuildKey.compute(key)
    let owns = beginBuild(buildKey)
    defer { if owns { finishBuild(buildKey) } }
    if let cached = computePipelines.withLock({ $0[key] }) { return cached }
    let state: MTLComputePipelineState
    do {
      state = try makeComputeState(
        "mk_pictureKernel",
        Self.constants(layout: key.layout, variant: key.variant, srgbTarget: false, color: key.color))
    } catch {
      throw MonitorKitError.gpu("Cannot build the compute picture pipeline: \(error)")
    }
    callerBuiltPipelines.add(1, ordering: .relaxed)
    return storeCompute(state, for: key)
  }

  /// A kernel writes any float or unorm format the same way: one pipeline for all of them.
  static func computeKey(_ key: PipelineKey) -> PipelineKey {
    var k = key
    k.target = MonitorRenderTargetFormat(colorPixelFormat: .invalid)
    return k
  }

  private func storeCompute(_ state: MTLComputePipelineState, for key: PipelineKey) -> MTLComputePipelineState {
    computePipelines.withLock { cache in
      if let raced = cache[key] { return raced }
      cache[key] = state
      builtPipelines.add(1, ordering: .relaxed)
      return state
    }
  }

  /// `specializedPipeline` for the compute picture.
  func specializedComputePipeline(_ key: PipelineKey) throws -> MTLComputePipelineState? {
    let key = Self.computeKey(key)
    switch specialization {
    case .off: return nil
    case .synchronous: return try computePipeline(key)
    case .asynchronous:
      if let cached = computePipelines.withLock({ $0[key] }) { return cached }
      let pendingKey = BuildKey.compute(key)
      guard claimAsynchronous(pendingKey) else { return nil }
      if let cached = computePipelines.withLock({ $0[key] }) {
        finishBuild(pendingKey)
        return cached
      }
      asynchronousBuilds.add(1, ordering: .relaxed)
      if compiler != nil {
        Task.detached(priority: .utility) { [self] in
          defer { finishBuild(pendingKey) }
          guard let compiler else {
            failedPipelines.withLock { _ = $0.insert(pendingKey) }
            return
          }
          let d = metal4ComputeDescriptor(
            "mk_pictureKernel",
            Self.constants(layout: key.layout, variant: key.variant, srgbTarget: false, color: key.color))
          do {
            let state = try await makeComputeState(d, compiler)
            _ = storeCompute(state, for: key)
          } catch {
            failedPipelines.withLock { _ = $0.insert(pendingKey) }
          }
        }
        return nil
      }
      let values = Self.constants(layout: key.layout, variant: key.variant, srgbTarget: false, color: key.color)
      library.makeFunction(name: "mk_pictureKernel", constantValues: values) { [self] function, _ in
        guard let function else {
          finishFailed(pendingKey)
          return
        }
        device.makeComputePipelineState(function: function) { [self] state, _ in
          guard let state else {
            finishFailed(pendingKey)
            return
          }
          _ = storeCompute(state, for: key)
          finishBuild(pendingKey)
        }
      }
      return nil
    }
  }

  /// The focus-analysis pipeline for a layout kind and the LUTs its stage applies.
  func focusPipeline(_ key: FocusKey) throws -> MTLComputePipelineState {
    if let cached = focusPipelines.withLock({ $0[key] }) { return cached }
    let buildKey = BuildKey.focus(key)
    let owns = beginBuild(buildKey)
    defer { if owns { finishBuild(buildKey) } }
    if let cached = focusPipelines.withLock({ $0[key] }) { return cached }
    var variant = Variant.uber
    variant.luts = key.luts
    let state = try makeComputeState("mk_focusMask", Self.constants(layout: key.layout, variant: variant))
    return focusPipelines.withLock { cache in
      if let raced = cache[key] { return raced }
      cache[key] = state
      return state
    }
  }

  /// Freeze's copy kernel for integer (`uint`) or normalized/float textures:
  /// started on Metal's compiler threads at init (unless specialization is
  /// `.synchronous` or `.off`), built by `prepare`, else here on first use.
  func copyPipeline(integer: Bool) throws -> MTLComputePipelineState {
    if let cached = cachedCopyPipeline(integer: integer) { return cached }
    let buildKey = BuildKey.copy(integer)
    let owns = beginBuild(buildKey)
    defer { if owns { finishBuild(buildKey) } }
    if let cached = cachedCopyPipeline(integer: integer) { return cached }
    return storeCopy(try makeComputeState(Self.copyFunction(integer: integer), nil), integer: integer)
  }

  func cachedCopyPipeline(integer: Bool) -> MTLComputePipelineState? {
    copyPipelines.withLock { integer ? $0.uint : $0.float }
  }

  private static func copyFunction(integer: Bool) -> String { integer ? "mk_copyUint" : "mk_copyFloat" }

  private func storeCopy(_ state: MTLComputePipelineState, integer: Bool) -> MTLComputePipelineState {
    copyPipelines.withLock { cache in
      if integer {
        if let raced = cache.uint { return raced }
        cache.uint = state
      } else {
        if let raced = cache.float { return raced }
        cache.float = state
      }
      return state
    }
  }

  /// Both copy kernels on Metal's compiler threads, so a Freeze pressed before
  /// they are needed finds them ready. Trivial kernels without constants.
  private func buildCopyPipelinesAsynchronously() {
    for integer in [true, false] {
      let buildKey = BuildKey.copy(integer)
      guard claimAsynchronous(buildKey) else { continue }
      if compiler != nil {
        Task.detached(priority: .utility) { [self] in
          defer { finishBuild(buildKey) }
          guard let compiler else { return }
          let d = metal4ComputeDescriptor(Self.copyFunction(integer: integer), nil)
          if let state = try? await makeComputeState(d, compiler) { _ = storeCopy(state, integer: integer) }
        }
        continue
      }
      guard let function = library.makeFunction(name: Self.copyFunction(integer: integer)) else {
        finishBuild(buildKey)
        continue
      }
      device.makeComputePipelineState(function: function) { [self] state, _ in
        if let state { _ = storeCopy(state, integer: integer) }
        finishBuild(buildKey)
      }
    }
  }

  /// Counts a resource a feed or pass created outside `makeTexture` (a uniform ring).
  func noteCreated() { createdResources.add(1, ordering: .relaxed) }

  /// An argument table for one of the library's Metal 4 encoders, made once.
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

  /// A private texture for library-owned persistent state, counted.
  func makeTexture(
    _ format: MTLPixelFormat, width: Int, height: Int, usage: MTLTextureUsage, label: String
  ) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = usage
    d.storageMode = .private
    guard let t = device.makeTexture(descriptor: d) else {
      throw MonitorKitError.gpu("Cannot allocate the \(width)×\(height) \(label) texture.")
    }
    t.label = label
    createdResources.add(1, ordering: .relaxed)
    return t
  }
}

extension PixelLayout {
  /// `mk_FrameParams.shape.x`.
  var shaderKind: UInt32 {
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
  /// Color formats requiring an integer shader texture declaration.
  var isIntegerColor: Bool {
    switch self {
    case .r8Uint, .r8Sint, .r16Uint, .r16Sint, .r32Uint, .r32Sint,
      .rg8Uint, .rg8Sint, .rg16Uint, .rg16Sint, .rg32Uint, .rg32Sint,
      .rgba8Uint, .rgba8Sint, .rgba16Uint, .rgba16Sint, .rgba32Uint, .rgba32Sint, .rgb10a2Uint:
      return true
    default:
      // RGB8, RGB16 and RGB32 Uint/Sint, introduced in the Metal 27 SDK.
      switch rawValue {
      case 47, 48, 97, 98, 120, 121: return true
      default: return false
      }
    }
  }

  /// Formats whose stores encode with the sRGB curve.
  var isSRGB: Bool {
    switch self {
    case .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgra10_xr_srgb, .bgr10_xr_srgb, .r8Unorm_srgb,
      .rg8Unorm_srgb:
      return true
    default: return false
    }
  }
}
