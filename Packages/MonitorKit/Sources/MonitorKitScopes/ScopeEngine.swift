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
/// from the pipelines built at init. Specialized pipelines (one frame layout's
/// decode; one scope kind's drawing) are built on first use as `specialization`
/// says, and replace the general ones once ready.
public final class ScopeEngine: @unchecked Sendable {
  public let device: MTLDevice
  public let library: MTLLibrary
  public let specialization: PipelineSpecialization
  let clearPipeline: MTLComputePipelineState
  let finalizePipeline: MTLComputePipelineState
  let graticulePipeline: MTLComputePipelineState
  let resolvePipeline: MTLComputePipelineState
  let vertexFunction: MTLFunction
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

  /// A render pipeline: the target format and, when specialized, the scope it draws.
  struct RenderKey: Hashable, Sendable {
    var pixelFormat: MTLPixelFormat
    var scope: DrawVariant?
  }

  struct DrawVariant: Hashable, Sendable {
    var kind: UInt32
    var mode: UInt32
  }

  private let generalCompute: [Kernel: MTLComputePipelineState]
  private let computePipelines = Mutex<[ComputeKey: MTLComputePipelineState]>([:])
  private let renderPipelines = Mutex<[RenderKey: MTLRenderPipelineState]>([:])
  /// Builds started and not finished (or failed: those are never retried).
  private let pendingCompute = Mutex<Set<ComputeKey>>([])
  private let pendingRender = Mutex<Set<RenderKey>>([])

  /// Binds MK_LAYOUT to function constant 0 when a pipeline defines it.
  static let specializationPrefix = """
    #include <metal_stdlib>
    using namespace metal;
    constant uint mk_layoutConstant [[function_constant(0)]];
    constant bool mk_layoutDefined = is_function_constant_defined(mk_layoutConstant);
    #define MK_LAYOUT(f) (mk_layoutDefined ? mk_layoutConstant : (f).shape.x)
    """

  public init(device: MTLDevice, specialization: PipelineSpecialization = .asynchronous) throws {
    self.device = device
    self.specialization = specialization
    let library = try MonitorShaders.makeLibrary(
      device: device, parts: [.lut, .decode], prefix: Self.specializationPrefix, extra: Self.scopeSource())
    self.library = library
    func function(_ name: String) throws -> MTLFunction {
      do {
        return try library.makeFunction(name: name, constantValues: MTLFunctionConstantValues())
      } catch {
        throw MonitorKitError.gpu("MonitorKit scope function \(name) is missing: \(error)")
      }
    }
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      try device.makeComputePipelineState(function: function(name))
    }
    var general: [Kernel: MTLComputePipelineState] = [:]
    for kernel in [Kernel.waveform, .vectorscope, .histogram] { general[kernel] = try pipeline(kernel.rawValue) }
    generalCompute = general
    clearPipeline = try pipeline("mk_scopeClear")
    finalizePipeline = try pipeline("mk_scopeFinalize")
    graticulePipeline = try pipeline("mk_scopeGraticule")
    resolvePipeline = try pipeline("mk_scopeResolve")
    vertexFunction = try function("mk_scopeVertex")

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
    // Dynamic threadgroup memory shares the limit with each kernel's static
    // statistics block (the fused kernel's is the same 12 words; 64 bytes of
    // headroom cover a compiler that pads it differently per specialization).
    let statics = general.values.map(\.staticThreadgroupMemoryLength).max() ?? 0
    threadgroupMemoryBudget = (min(device.maxThreadgroupMemoryLength, 32 * 1024) - statics - 64) / 16 * 16
  }

  /// MKScopes.msl alone. It needs `MonitorShaders.source([.lut, .decode])` before it.
  public static func scopeSource() throws -> String {
    guard
      let url = Bundle.module.url(forResource: "MKScopes", withExtension: "msl", subdirectory: "Shaders")
        ?? Bundle.module.url(forResource: "MKScopes", withExtension: "msl")
    else { throw MonitorKitError.gpu("MonitorKit shader MKScopes is missing from the bundle.") }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// Builds the general render pipeline for `pixelFormat` ahead of the first draw.
  public func prepare(pixelFormat: MTLPixelFormat) throws {
    _ = try renderPipeline(RenderKey(pixelFormat: pixelFormat, scope: nil))
  }

  /// Builds every pipeline `settings` needs for frames of `layouts` drawn into
  /// `pixelFormat` on this thread, so the first frames use specialized ones.
  public func prepare(settings: [ScopeSettings], layouts: [PixelLayout], pixelFormat: MTLPixelFormat?) throws {
    for s in settings.map({ $0.normalized() }) {
      for layout in layouts {
        _ = try computePipeline(ComputeKey(kernel: s.kind.kernel, layout: layout.scopeLayoutCode))
      }
      if let pixelFormat {
        _ = try renderPipeline(
          RenderKey(pixelFormat: pixelFormat, scope: DrawVariant(kind: s.kind.shaderCode, mode: s.shaderMode)))
      }
    }
  }

  // MARK: compute pipelines

  /// The pipeline for `key` if built (or built here when synchronous),
  /// otherwise the general one while it builds. The bool is whether the result
  /// is the one asked for.
  func computePipeline(for key: ComputeKey) throws -> (MTLComputePipelineState, Bool) {
    if let cached = computePipelines.withLock({ $0[key] }) { return (cached, true) }
    var general = key
    general.layout = nil
    switch specialization {
    case .off: return (try computePipeline(general), true)
    case .synchronous: return (try computePipeline(key), true)
    case .asynchronous:
      if key.layout == nil { return (try computePipeline(key), true) }
      if pendingCompute.withLock({ $0.insert(key).inserted }) {
        library.makeFunction(name: key.kernel.rawValue, constantValues: Self.constants(key)) { [self] function, _ in
          guard let function else { return }
          device.makeComputePipelineState(function: function) { [self] state, _ in
            if let state { store(state, for: key) }
            if state != nil { _ = pendingCompute.withLock { $0.remove(key) } }
          }
        }
      }
      return (try computePipeline(general), false)
    }
  }

  /// The fused pipeline for `key` if it can be used now: specialized when
  /// built (or built here when synchronous; the general one, built here, when
  /// specialization is off). Nil while an asynchronous build runs: the group
  /// accumulates scope by scope meanwhile, so no frame waits for the compiler.
  func fusedPipeline(for key: ComputeKey) throws -> MTLComputePipelineState? {
    if let cached = computePipelines.withLock({ $0[key] }) { return cached }
    switch specialization {
    case .off:
      var general = key
      general.layout = nil
      return try computePipeline(general)
    case .synchronous: return try computePipeline(key)
    case .asynchronous:
      if pendingCompute.withLock({ $0.insert(key).inserted }) {
        library.makeFunction(name: key.kernel.rawValue, constantValues: Self.constants(key)) { [self] function, _ in
          guard let function else { return }
          device.makeComputePipelineState(function: function) { [self] state, _ in
            if let state { store(state, for: key) }
            if state != nil { _ = pendingCompute.withLock { $0.remove(key) } }
          }
        }
      }
      return nil
    }
  }

  /// Builds `key` on this thread if it is not cached.
  func computePipeline(_ key: ComputeKey) throws -> MTLComputePipelineState {
    if key.layout == nil, key.scopes.isEmpty, let general = generalCompute[key.kernel] { return general }
    if let cached = computePipelines.withLock({ $0[key] }) { return cached }
    do {
      let function = try library.makeFunction(name: key.kernel.rawValue, constantValues: Self.constants(key))
      return store(try device.makeComputePipelineState(function: function), for: key)
    } catch {
      throw MonitorKitError.gpu("Cannot build the scope kernel \(key.kernel.rawValue): \(error)")
    }
  }

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
  /// synchronous), otherwise the general one for its format while it builds.
  /// The bool is whether the result is the one asked for.
  func renderPipeline(for key: RenderKey) throws -> (MTLRenderPipelineState, Bool) {
    if let cached = renderPipelines.withLock({ $0[key] }) { return (cached, true) }
    let general = RenderKey(pixelFormat: key.pixelFormat, scope: nil)
    switch specialization {
    case .off: return (try renderPipeline(general), true)
    case .synchronous: return (try renderPipeline(key), true)
    case .asynchronous:
      if key.scope == nil { return (try renderPipeline(key), true) }
      if pendingRender.withLock({ $0.insert(key).inserted }) {
        library.makeFunction(name: "mk_scopeFragment", constantValues: Self.constants(key)) { [self] function, _ in
          guard let function else { return }
          device.makeRenderPipelineState(descriptor: descriptor(key, fragment: function)) { [self] state, _ in
            if let state { store(state, for: key) }
            if state != nil { _ = pendingRender.withLock { $0.remove(key) } }
          }
        }
      }
      return (try renderPipeline(general), false)
    }
  }

  /// Builds `key` on this thread if it is not cached.
  func renderPipeline(_ key: RenderKey) throws -> MTLRenderPipelineState {
    if let cached = renderPipelines.withLock({ $0[key] }) { return cached }
    do {
      let fragment = try library.makeFunction(name: "mk_scopeFragment", constantValues: Self.constants(key))
      return store(try device.makeRenderPipelineState(descriptor: descriptor(key, fragment: fragment)), for: key)
    } catch {
      throw MonitorKitError.gpu("Cannot draw scopes into pixel format \(key.pixelFormat.rawValue): \(error)")
    }
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
    let attachment = d.colorAttachments[0]!
    attachment.pixelFormat = key.pixelFormat
    // Premultiplied over: the scope background darkens what is behind it and
    // the trace adds light.
    attachment.isBlendingEnabled = true
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return d
  }

  /// Specialized pipelines built so far (compute, render).
  var specializedPipelineCount: (compute: Int, render: Int) {
    (computePipelines.withLock { $0.count }, renderPipelines.withLock { $0.keys.filter { $0.scope != nil }.count })
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
