import Metal
import MonitorKitCore
import Synchronization

/// The attachments of the render pass the picture is drawn into. The picture
/// goes to colour attachment 0; any further colour attachments are left untouched,
/// and depth and stencil are neither tested nor written.
public struct MonitorRenderTargetFormat: Hashable, Sendable {
  public var colorPixelFormat: MTLPixelFormat
  public var depthPixelFormat: MTLPixelFormat
  public var stencilPixelFormat: MTLPixelFormat
  public var sampleCount: Int
  /// Formats of colour attachments 1, 2, … of the host's pass (`.invalid` for a gap).
  public var additionalColorPixelFormats: [MTLPixelFormat]

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
      sampleCount: first?.sampleCount ?? depth?.sampleCount ?? 1, additionalColorPixelFormats: extra)
  }

  var hasDepthOrStencil: Bool { depthPixelFormat != .invalid || stencilPixelFormat != .invalid }
}

/// How the engine builds pipelines specialized to a surface's tool set.
public enum PipelineSpecialization: Sendable {
  /// Draw with the all-tools pipeline while the specialized one compiles on
  /// Metal's compiler threads, then switch. Never stalls a frame (the default).
  case asynchronous
  /// Compile the specialized pipeline on first use, on the calling thread.
  case synchronous
  /// Always use the all-tools pipeline.
  case off
}

/// One per GPU, shared by every feed and surface. Compiles the shaders once and
/// builds the pipelines; immutable after init apart from locked pipeline caches,
/// which passes look up only when their target, layout or tool set changes.
/// Safe to share across threads.
public final class MonitorEngine: @unchecked Sendable {
  public let device: MTLDevice
  public let specialization: PipelineSpecialization
  /// MKLUT + MKDecode + MKMonitor, compiled once with `MK_LAYOUT` and the tool
  /// tiers bound to function constants: every entry point must be specialized.
  let library: MTLLibrary

  private let vertexFunction: MTLFunction
  private let renderPipelines = Mutex<[PipelineKey: MTLRenderPipelineState]>([:])
  private let pendingPipelines = Mutex<Set<PipelineKey>>([])
  private let focusPipelines = Mutex<[FocusKey: MTLComputePipelineState]>([:])
  private let createdResources = Atomic<Int>(0)
  private let builtPipelines = Atomic<Int>(0)
  /// Depth and stencil always pass and are never written, so the picture draws
  /// the same inside any host pass.
  let depthStencil: MTLDepthStencilState

  /// A tool set: the tiers of `mk_picture` a pipeline compiles in.
  struct Variant: Hashable {
    /// Bit 0: the burn-in LUT is read, bit 1: the monitor LUT.
    var luts: UInt32
    var zebras: Bool
    var peaking: Bool
    var guides: Bool
    /// Bit 0: log modes, bit 1: stage modes.
    var falseColor: UInt32
    var interpolates: Bool
    var navigator: Bool
    var adjust: Bool
    static let uber = Variant(
      luts: 3, zebras: true, peaking: true, guides: true, falseColor: 3, interpolates: true, navigator: true,
      adjust: true)
  }

  struct PipelineKey: Hashable {
    var target: MonitorRenderTargetFormat
    var layout: UInt32
    var variant: Variant
  }

  struct FocusKey: Hashable {
    var layout: UInt32
    var lutStage: Bool
  }

  /// Binds MK_LAYOUT, the tool tiers and the target's sRGB encode to function constants 0–9.
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
    """

  /// Bound in place of inputs a pass does not use, so every argument is valid.
  let emptyPacked: MTLTexture
  let emptyFloat: MTLTexture
  let emptyLUT: MTLTexture

  /// Compiles the library. Pipelines are built on first use or by `prepare`.
  public init(device: MTLDevice, specialization: PipelineSpecialization = .asynchronous) throws {
    self.device = device
    self.specialization = specialization
    let library = try MonitorShaders.makeLibrary(
      device: device, parts: [.lut, .decode, .monitor], prefix: Self.specializationPrefix)
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
  }

  /// Builds now, instead of on first use, everything a frame of these layouts
  /// can need into `pixelFormat`: the all-tools picture pipelines and both focus
  /// analysis pipelines. All five layout kinds when `layouts` is nil.
  public func prepare(pixelFormat: MTLPixelFormat, layouts: [PixelLayout]? = nil) throws {
    try prepare(target: MonitorRenderTargetFormat(colorPixelFormat: pixelFormat), layouts: layouts)
  }

  /// `prepare(pixelFormat:layouts:)` for a host render pass with these attachments.
  public func prepare(target: MonitorRenderTargetFormat, layouts: [PixelLayout]? = nil) throws {
    let kinds = layouts.map { $0.map(\.shaderKind) } ?? Array(0...4)
    for kind in Set(kinds) {
      _ = try renderPipeline(PipelineKey(target: target, layout: kind, variant: .uber))
      for lutStage in [false, true] { _ = try focusPipeline(layout: kind, lutStage: lutStage) }
    }
  }

  public func makeFeed() -> MonitorFeed { MonitorFeed(engine: self) }
  public func makePass() -> MonitorPass { MonitorPass(engine: self) }

  /// GPU textures and buffers created by this engine's feeds and passes since
  /// init (pipelines and placeholders excluded). Constant in steady state.
  public var resourcesCreated: Int { createdResources.load(ordering: .relaxed) }

  /// Render pipelines built so far, all-tools and specialized.
  public var pipelinesBuilt: Int { builtPipelines.load(ordering: .relaxed) }
  /// Focus-analysis pipelines built so far.
  var focusPipelineCount: Int { focusPipelines.withLock { $0.count } }

  static func constants(layout: UInt32, variant: Variant, srgbTarget: Bool = false) -> MTLFunctionConstantValues {
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

  /// The picture pipeline for `key`, built on this thread if it is not cached.
  func renderPipeline(_ key: PipelineKey) throws -> MTLRenderPipelineState {
    if let cached = renderPipelines.withLock({ $0[key] }) { return cached }
    let state: MTLRenderPipelineState
    do {
      let fragment = try library.makeFunction(
        name: "mk_picture",
        constantValues: Self.constants(
          layout: key.layout, variant: key.variant, srgbTarget: key.target.colorPixelFormat.isSRGB))
      state = try device.makeRenderPipelineState(descriptor: descriptor(key, fragment: fragment))
    } catch {
      throw MonitorKitError.gpu("Cannot draw into pixel format \(key.target.colorPixelFormat.rawValue): \(error)")
    }
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
      guard pendingPipelines.withLock({ $0.insert(key).inserted }) else { return nil }
      let values = Self.constants(
        layout: key.layout, variant: key.variant, srgbTarget: key.target.colorPixelFormat.isSRGB)
      library.makeFunction(name: "mk_picture", constantValues: values) { [self] function, _ in
        guard let function else { return finish(key) }
        device.makeRenderPipelineState(descriptor: descriptor(key, fragment: function)) { [self] state, _ in
          if let state { _ = store(state, for: key) }
          finish(key)
        }
      }
      return nil
    }
  }

  /// A failed build stays pending, so it is not retried every frame; the pass keeps the all-tools pipeline.
  private func finish(_ key: PipelineKey) {
    if renderPipelines.withLock({ $0[key] }) == nil { return }
    pendingPipelines.withLock { _ = $0.remove(key) }
  }

  /// The focus-analysis pipeline for a layout kind, on the source or a LUT stage.
  func focusPipeline(layout: UInt32, lutStage: Bool) throws -> MTLComputePipelineState {
    let key = FocusKey(layout: layout, lutStage: lutStage)
    if let cached = focusPipelines.withLock({ $0[key] }) { return cached }
    var variant = Variant.uber
    variant.luts = lutStage ? 3 : 0
    let function = try library.makeFunction(
      name: "mk_focusMask", constantValues: Self.constants(layout: layout, variant: variant))
    let state = try device.makeComputePipelineState(function: function)
    return focusPipelines.withLock { cache in
      if let raced = cache[key] { return raced }
      cache[key] = state
      return state
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
