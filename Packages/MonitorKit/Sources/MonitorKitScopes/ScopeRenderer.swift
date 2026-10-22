import Foundation
import Metal
import MonitorKit
import MonitorKitCore

extension ScopeIntensityCurve {
  /// Trace brightness (0…1) for a bin `density` times the uniform density.
  /// Mirrors `mk_scopeIntensity`.
  public func value(density: Double) -> Double {
    let x = max(0, density)
    switch self {
    case .logarithmic: return min(1, log(1 + 16 * x) / log(257))
    case .gamma: return pow(min(x / 16, 1), 1 / 2.2)
    }
  }
}

/// Draws an accumulator's bins with graticule into any render target. One per
/// surface; confined to one thread at a time.
///
/// After each accumulation (or display or plot size change) a small compute
/// pass resolves the bins into a trace texture: one texel per bin on an axis
/// the plot shows at bin resolution or larger, the maximum of the bins under
/// each plot pixel on a minified one. Every draw is then one full-viewport
/// triangle taking one sample per pixel, with no allocation. The graticule is
/// rasterized into an r8 coverage texture only when it changes.
///
/// Textures replaced by a settings or size change stay referenced for
/// `MonitorFeed.retiredFrames` more `prepare`s, so command buffers without
/// retained references stay valid; keep the renderer itself alive until its
/// last command buffer completes. On Metal 4 (`render(…, into: MonitorSubmission)`)
/// the engine's residency keeps replaced textures, and on deinit everything the
/// renderer owns, until the submissions that used them complete.
///
/// Colours are authored as Rec.709 SDR display values at graphics white and
/// written in `colorPipeline`'s overlay encoding, like the picture pass's overlays.
public final class ScopeRenderer {
  public let engine: ScopeEngine
  /// How the scope's colours become target values: set it to the surface's
  /// `MonitorPass.colorPipeline` when the scope shares the picture's layer, or
  /// use `setOutputColor` for a layer of its own. On a PQ, HLG or extended
  /// linear target (or a signal-native layer tagged PQ or HLG) the graticule,
  /// trace and background are encoded per pixel from BT.1886 display light, with
  /// graphics white at `referenceWhite` (Report ITU-R BT.2408-8: 203 cd/m², 58%
  /// PQ, 75% HLG). The default is an SDR layer: colours as authored. Changing it
  /// rebuilds nothing.
  public var colorPipeline = MonitorColorPipeline(output: .signalNative, signal: .rec709) {
    didSet { if colorPipeline != oldValue { outputEncoding = Self.outputEncoding(colorPipeline) } }
  }
  /// The graticule of the last `prepare`/`render`, with label positions for the UI.
  public private(set) var graticule: ScopeGraticule
  /// Anti-aliased graticule coverage, one byte per viewport pixel from the
  /// top-left corner. It grows in 64-pixel steps, so a live resize rarely
  /// reallocates; the texels outside the viewport are zero.
  public private(set) var graticuleTexture: MTLTexture?
  /// Trace intensity, one texel per bin (fewer written on a minified axis):
  /// r16Unorm for one channel, rgb10a2Unorm or rgba16Unorm (histogram) for three.
  public private(set) var traceTexture: MTLTexture?
  /// Whether `draw(with:)` draws anything. False only while an asynchronous
  /// engine builds the first pipeline for this target's formats; `draw` encodes
  /// nothing until then (call `ScopeEngine.prepare(target:)` to build it up front).
  public var isReady: Bool { pipeline != nil }
  private var graticuleKey: GraticuleKey?
  private var resolveKey: ResolveKey?
  var parameters = ScopeDrawParameters()
  var shapes = ScopeGraticuleParameters()
  var pipeline: MTLRenderPipelineState?
  private var pipelineKey: ScopeEngine.RenderKey?
  /// Whether `pipeline` is the specialized one `pipelineKey` asks for.
  private var pipelineIsFinal = false
  var drawsDepthStencil = false
  /// The bins the trace was resolved from, kept alive so their identity in
  /// `resolveKey` cannot be reused.
  private var bins: MTLBuffer?
  var hasTrace = false
  var viewport = MTLViewport()
  /// The viewport as a scissor rectangle, so a host's scissor cannot clip the scope.
  var scissor = MTLScissorRect()
  private let pass = MTLRenderPassDescriptor()
  private let graticulePass = MTLRenderPassDescriptor()
  private var retired = RetiredResources()
  /// `colorPipeline` as draw parameters.
  private var outputEncoding = OutputEncoding()

  // Metal 4 state, made on first use.
  /// Draw parameters, then the resolve's: one slot per change of either.
  var ring = MonitorUniformRing(slotLength: ScopeRenderer.uniformLength, label: "MonitorKit scope draw uniforms")
  /// Graticule shapes, rewritten only when the graticule is.
  var graticuleRing = MonitorUniformRing(
    slotLength: ScopeRenderer.graticuleUniformLength, label: "MonitorKit scope graticule uniforms")
  var uniformGeneration: UInt64 = 0
  var graticuleGeneration: UInt64 = 0
  /// The draw parameters the current ring slot holds.
  var ringParameters: ScopeDrawParameters?
  var metal4Table: (any MTL4ArgumentTable)?
  let metal4Pass = MTL4RenderPassDescriptor()
  let metal4GraticulePass = MTL4RenderPassDescriptor()
  var residentTrace: MTLTexture?
  var residentGraticule: MTLTexture?
  /// The submissions that last wrote the trace and the graticule on Metal 4.
  var traceWrittenIn: UInt64 = 0
  var graticuleWrittenIn: UInt64 = 0
  /// The prepared Metal 4 draw: its uniforms, and whether it must wait for the
  /// trace or graticule writes (only while their submission may be running).
  var metal4Draw: (uniforms: MTLGPUAddress, waits: Bool)?

  /// The output encoding in `mk_ScopeDraw`.
  struct OutputEncoding: Equatable {
    var encode = SIMD4<Float>.zero
    var rows = (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0))
    var weights = SIMD4<Float>.zero

    static func == (a: Self, b: Self) -> Bool {
      a.encode == b.encode && a.rows.0 == b.rows.0 && a.rows.1 == b.rows.1 && a.rows.2 == b.rows.2
        && a.weights == b.weights
    }
  }

  /// Shapes are viewport-relative, so moving the viewport never redraws them.
  private struct GraticuleKey: Equatable {
    var settings: ScopeSettings
    var context: ScopeContext
    var width: Int
    var height: Int
    var pixelsPerPoint: Double
  }

  /// What the trace texture holds: one accumulation, resolved with these parameters.
  private struct ResolveKey: Equatable {
    var bins: ObjectIdentifier
    var generation: UInt32
    var parameters: ScopeResolveParameters
  }

  init(engine: ScopeEngine) {
    self.engine = engine
    graticule = ScopeGraticule(
      settings: ScopeSettings(), context: ScopeContext(), viewportWidth: 1, viewportHeight: 1)
    let attachment = graticulePass.colorAttachments[0]!
    attachment.loadAction = .clear
    attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    attachment.storeAction = .store
    let metal4Graticule = metal4GraticulePass.colorAttachments[0]!
    metal4Graticule.loadAction = .clear
    metal4Graticule.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    metal4Graticule.storeAction = .store
    let metal4Attachment = metal4Pass.colorAttachments[0]!
    metal4Attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    metal4Attachment.storeAction = .store
  }

  deinit {
    // Metal 4 retains nothing: what the GPU may still use lives until its
    // submission completes. All nil unless a Metal 4 encode used them.
    let r = engine.residency
    if let t = residentTrace { r.retire(t, resident: t) }
    if let t = residentGraticule { r.retire(t, resident: t) }
    ring.retire(to: r)
    graticuleRing.retire(to: r)
    r.retire(metal4Table, resident: nil)
  }

  /// `colorPipeline` for a layer of the scope's own in `output` (a signal-native
  /// one is tagged for `signal` after `displayTransform`, as the picture's would be).
  public func setOutputColor(
    _ output: MonitorOutputColor, signal: SignalDescription = .rec709,
    displayTransform: DisplayTransformSettings = DisplayTransformSettings(), monitorStageHasLUT: Bool = false
  ) {
    colorPipeline = MonitorColorPipeline(
      output: output, signal: signal, transform: displayTransform, monitorStageHasLUT: monitorStageHasLUT)
  }

  /// Bytes of GPU memory this renderer owns: the graticule and trace textures.
  /// Replaced textures held for in-flight command buffers are transient and not counted.
  public var persistentMemoryBytes: Int { (graticuleTexture?.allocatedSize ?? 0) + (traceTexture?.allocatedSize ?? 0) }

  /// Replaced textures still referenced, for tests.
  var retiredResourceCount: Int { retired.count }
  func isRetired(_ resource: any MTLResource) -> Bool { retired.holds(resource) }

  /// Draws in its own render pass into `target`, which may be multisampled.
  /// `viewport` defaults to the whole target and must lie inside it. `clear`
  /// clears the whole target first; otherwise the scope composites over its contents.
  public func render(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, target: MTLTexture,
    viewport: MonitorViewport? = nil, clear: Bool = false, into commandBuffer: MTLCommandBuffer
  ) throws {
    let area = try Self.checkedViewport(viewport, target)
    try prepare(
      accumulator, display: display, viewport: area,
      target: MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat, sampleCount: target.sampleCount),
      into: commandBuffer)
    let attachment = pass.colorAttachments[0]!
    attachment.texture = target
    attachment.loadAction = clear ? .clear : .load
    attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    attachment.storeAction = .store
    // Don't keep the host's target alive past this call.
    defer { attachment.texture = nil }
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw MonitorKitError.gpu("Cannot create a render encoder for the scope.")
    }
    draw(with: encoder)
    encoder.endEncoding()
  }

  static func checkedViewport(_ viewport: MonitorViewport?, _ target: MTLTexture) throws -> MonitorViewport {
    let area = viewport ?? MonitorViewport(width: target.width, height: target.height)
    guard area.x >= 0, area.y >= 0, area.x + area.width <= target.width, area.y + area.height <= target.height
    else { throw MonitorKitError.invalidFrame("viewport \(area) is outside the \(target.width)×\(target.height) target") }
    return area
  }

  /// `prepare(_:display:viewport:target:into:)` for a pass with one
  /// single-sample colour attachment and no depth or stencil.
  public func prepare(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, viewport area: MonitorViewport,
    targetPixelFormat: MTLPixelFormat, into commandBuffer: MTLCommandBuffer
  ) throws {
    try prepare(
      accumulator, display: display, viewport: area, target: MonitorRenderTargetFormat(colorPixelFormat: targetPixelFormat),
      into: commandBuffer)
  }

  /// For drawing inside the host's render pass, whose formats `target`
  /// describes (`MonitorRenderTargetFormat(passDescriptor)`): call before the
  /// host's render encoder starts, then `draw(with:)`. Encode it after the
  /// accumulation it shows. When the bins, the display, the plot size or the
  /// graticule changed it encodes small compute and render passes into
  /// `commandBuffer`. The viewport must lie inside the host's target; an
  /// empty one throws.
  public func prepare(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, viewport area: MonitorViewport,
    target: MonitorRenderTargetFormat, into commandBuffer: MTLCommandBuffer
  ) throws {
    // A throw anywhere, in `update` too, leaves the trace and graticule to be redone.
    do {
      let work = try update(accumulator, display: display, viewport: area, target: target)
      if let r = work.resolve { try encodeResolve(accumulator, r, into: commandBuffer) }
      if let size = work.rasterize { try rasterizeGraticule(width: size.x, height: size.y, into: commandBuffer) }
    } catch {
      forgetEncodedState()
      throw error
    }
  }

  /// After a failed encode: the trace and graticule are redone by the next `prepare`.
  func forgetEncodedState() {
    resolveKey = nil
    hasTrace = false
    graticuleKey = nil
  }

  /// What a `prepare` encodes besides caching the draw: a resolve of the bins
  /// with these parameters, and a graticule raster of this viewport size.
  struct Work {
    var resolve: ScopeResolveParameters?
    var rasterize: SIMD2<Int>?
  }

  /// Everything `prepare` decides, shared by both encode paths: the pipeline,
  /// the graticule, the trace texture and the draw parameters. Encodes nothing.
  func update(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay?, viewport area: MonitorViewport,
    target: MonitorRenderTargetFormat
  ) throws -> Work {
    guard area.width > 0, area.height > 0 else { throw MonitorKitError.invalidFrame("viewport is empty") }
    retired.age()
    var s = accumulator.accumulatedSettings
    s.display = (display ?? accumulator.settings.display).normalized()
    let wantedKey = ScopeEngine.RenderKey(
      target: target, scope: ScopeEngine.DrawVariant(kind: s.kind.shaderCode, mode: s.shaderMode))
    if pipelineKey != wantedKey || !pipelineIsFinal {
      (pipeline, pipelineIsFinal) = try engine.renderPipeline(for: wantedKey)
      pipelineKey = wantedKey
      drawsDepthStencil = target.needsDepthStencilState
    }

    let w = Double(area.width), h = Double(area.height)
    var keySettings = s
    keySettings.display = s.display.graticuleKey
    // Brightness, gain or opacity changes never redraw the graticule.
    let key = GraticuleKey(
      settings: keySettings, context: accumulator.context, width: area.width, height: area.height,
      pixelsPerPoint: area.pixelsPerPoint)
    let redraw = key != graticuleKey || !graticuleFits(width: area.width, height: area.height)
    if redraw {
      graticule = ScopeGraticule(settings: s, context: accumulator.context, viewportWidth: w, viewportHeight: h)
      writeShapes(width: w, height: h, pixelsPerPoint: area.pixelsPerPoint)
    }
    let plot = graticule.plot
    let plotPixels = SIMD4(plot.x * w, plot.y * h, plot.z * w, plot.w * h)
    parameters.pixels = Self.pixelBounds(plotPixels)
    var work = Work()
    if accumulator.hasData {
      work.resolve = try planResolve(accumulator, settings: s, plot: plotPixels)
    } else {
      hasTrace = false
    }

    viewport = MTLViewport(
      originX: Double(area.x), originY: Double(area.y), width: w, height: h, znear: 0, zfar: 1)
    scissor = MTLScissorRect(x: area.x, y: area.y, width: area.width, height: area.height)
    parameters.viewport = SIMD4(Float(area.x), Float(area.y), Float(w), Float(h))
    parameters.plot = SIMD4<Float>(plotPixels)
    let d = s.display
    parameters.shape = SIMD4(s.kind.shaderCode, s.shaderMode, UInt32(accumulator.layout.channels), 0)
    let trace: UInt32 =
      d.trace == .white ? 1 : (d.trace == .colorized && s.kind == .vectorscope ? 2 : 0)
    parameters.flags.x = hasTrace ? 1 : 0
    parameters.flags.y = target.colorPixelFormat.isSRGB ? 1 : 0
    parameters.flags.z = trace
    parameters.intensity = SIMD4(Float(d.brightness), 0, 0, 0)
    parameters.background = SIMD4(
      Float(d.backgroundOpacity), d.showsGraticule ? Float(d.graticuleOpacity) : 0, 0, 0)
    let k = accumulator.context.matrix.coefficients
    parameters.chroma = SIMD4(
      Float(k.r), Float(k.b), Float(VectorscopeGeometry.halfExtent / Double(s.vectorscopeZoom)), 0)
    let colors = Self.colors(settings: s)
    parameters.color0 = colors.0
    parameters.color1 = colors.1
    parameters.color2 = colors.2
    parameters.graticuleColor = Self.graticuleColor
    parameters.encode = outputEncoding.encode
    parameters.toTarget0 = outputEncoding.rows.0
    parameters.toTarget1 = outputEncoding.rows.1
    parameters.toTarget2 = outputEncoding.rows.2
    parameters.targetWeights = outputEncoding.weights
    if redraw {
      shapes.plot = parameters.plot
      shapes.size = SIMD4(Float(w), Float(h), Float(shapes.size.z), 0)
      try makeGraticuleTexture(width: area.width, height: area.height)
      graticuleKey = key
      work.rasterize = SIMD2(area.width, area.height)
    }
    return work
  }

  /// The graticule's colour, as authored (Rec.709 SDR display values).
  static let graticuleColor = SIMD4<Float>(0.86, 0.82, 0.7, 1)

  /// `colorPipeline`'s overlay encoding as draw parameters: none for colours as
  /// authored (an SDR native layer, or BT.1886 Rec.709 SDR, which they already are).
  static func outputEncoding(_ c: MonitorColorPipeline) -> OutputEncoding {
    guard let o = c.overlay, o.transfer != .bt1886 || o.primaries != .rec709 else { return OutputEncoding() }
    let m = c.overlayMatrix
    func row(_ v: ColorRGB) -> SIMD4<Float> { SIMD4(Float(v.r), Float(v.g), Float(v.b), 0) }
    let w = o.primaries.luminanceCoefficients
    return OutputEncoding(
      encode: SIMD4(
        Float(o.transfer.rawValue), Float(c.referenceWhite), Float(c.hlgOutputPeak),
        Float(ColorMath.hlgSystemGamma(peak: c.hlgOutputPeak))),
      rows: (row(m.red), row(m.green), row(m.blue)), weights: SIMD4(Float(w.r), Float(w.g), Float(w.b), 0))
  }

  /// Encodes the prepared scope into the host's render encoder. Sets the
  /// pipeline, viewport, a scissor rectangle of the viewport, no culling, fill
  /// mode, fragment bytes 0 and fragment textures 0–1 and, when the pass has
  /// depth or stencil, a depth-stencil state that always passes and never
  /// writes; whatever state the host left, the scope draws the same. Encodes
  /// nothing while `isReady` is false.
  public func draw(with encoder: MTLRenderCommandEncoder) {
    guard let pipeline, let graticuleTexture else { return }
    encoder.setRenderPipelineState(pipeline)
    if drawsDepthStencil { encoder.setDepthStencilState(engine.depthStencil) }
    encoder.setViewport(viewport)
    encoder.setScissorRect(scissor)
    encoder.setCullMode(.none)
    encoder.setTriangleFillMode(.fill)
    encoder.setFragmentBytes(&parameters, length: MemoryLayout<ScopeDrawParameters>.stride, index: 0)
    encoder.setFragmentTexture(graticuleTexture, index: 0)
    encoder.setFragmentTexture(hasTrace ? traceTexture : engine.placeholderTrace, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
  }

  /// The viewport pixels whose centre lies in `plot` (x, y, width, height):
  /// xy the first, zw one past the last.
  static func pixelBounds(_ plot: SIMD4<Double>) -> SIMD4<UInt32> {
    func edge(_ v: Double) -> UInt32 { UInt32(max(0, (v - 0.5).rounded(.up))) }
    return SIMD4(edge(plot.x), edge(plot.y), edge(plot.x + plot.z), edge(plot.y + plot.w))
  }

  /// How the trace of `accumulator`'s last bins is resolved for a plot at
  /// `plot` (viewport pixels), and how the fragment shader maps plot fractions onto it.
  struct TraceShape: Equatable {
    var parameters = ScopeResolveParameters()
    var format = MTLPixelFormat.r16Unorm
    /// Allocated trace size: one texel per source texel (bin, or frame column),
    /// which also holds a reduced axis's texel per plot pixel, so a live resize
    /// never reallocates it.
    var width = 1, height = 1
    /// `ScopeDrawParameters.traceMap` and the reduced-axis bits (`flags.w`).
    var map = SIMD4<Float>.zero
    var reduced: UInt32 = 0
  }

  static func traceShape(_ accumulator: ScopeAccumulator, settings s: ScopeSettings, plot: SIMD4<Double>)
    -> TraceShape
  {
    let layout = accumulator.layout
    let d = s.display
    var t = TraceShape()
    var r = ScopeResolveParameters()
    let slot = UInt32(accumulator.generation & 1) * UInt32(ScopeStatisticsWord.slotWords)
    r.shape = SIMD4(s.kind.shaderCode, UInt32(layout.channels), layout.bytesPerBin == 2 ? 1 : 0, slot)
    let frameWidth = max(1, accumulator.frameWidth), frameHeight = max(1, accumulator.frameHeight)
    let pixels = Double(frameWidth * frameHeight)
    // Counts per bin for "uniform density": one frame column's pixels spread
    // over every level (waveform; each bin is divided by its frame columns),
    // or the frame spread over 1/32 of the plane (vectorscope: real pictures
    // cover little of it).
    let unit: Double
    var source = SIMD2(layout.columns, layout.rows)
    // Plot pixels per axis the trace spans (a waveform parade panel is a third).
    var span = SIMD2(plot.z, plot.w)
    let bounds = pixelBounds(plot)
    let plotPixels = SIMD2(Int(bounds.z) - Int(bounds.x), Int(bounds.w) - Int(bounds.y))
    let parade = s.kind == .waveform && s.waveformMode.isParade
    // Source texel coordinate at plot fraction 0: the vectorscope's bins are
    // centred on whole chroma steps, so its origin is half a texel in.
    var origin = 0.0
    switch s.kind {
    case .waveform:
      unit = Double(frameHeight) / Double(layout.rows)
      r.bins = SIMD4(UInt32(layout.columns), UInt32(layout.rows), UInt32(frameWidth), UInt32(frameHeight))
      // One texel column per frame column when the frame is narrower.
      source.x = min(layout.columns, frameWidth)
      if parade { span.x /= 3 }
    case .vectorscope:
      unit = pixels / Double(layout.columns * layout.rows) * vectorscopeConcentration
      r.bins = SIMD4(UInt32(layout.columns), UInt32(layout.rows), 0, 0)
      origin = 0.5
      r.reduce.w = 1
    case .histogram:
      unit = 1
      r.bins = SIMD4(UInt32(layout.columns), 1, 0, 0)
      source.y = 1
    }
    var size = SIMD2<UInt32>(UInt32(source.x), UInt32(source.y))
    // An axis drawn at bin resolution or smaller is reduced to one texel per
    // plot pixel here (per panel pixel in a parade), so the draw reads one
    // texel; a histogram's single row never is.
    var axis = 0
    while axis < 2 {
      let n = Double(source[axis]), extent = max(span[axis], 1e-3)
      if axis == 1 && s.kind == .histogram {
        t.map[1] = 0
        t.map[3] = 0.5
      } else if n >= extent {
        let count = max(1, plotPixels[axis])
        r.reduce[axis] = UInt32(count)
        if axis == 0 && parade {
          r.reduce.z = 3
          size.x = UInt32(maximumPanelPixels(count))
        } else {
          size[axis] = UInt32(count)
        }
        t.reduced |= 1 << UInt32(axis)
      } else {
        t.map[axis] = Float(n)
        t.map[axis + 2] = Float(origin)
      }
      axis += 1
    }
    t.width = max(source.x, Int(size.x))
    t.height = max(source.y, Int(size.y))
    r.size = SIMD4(size.x, size.y, UInt32(source.x), UInt32(source.y))
    r.intensity = SIMD4(
      Float(d.gain / unit), d.intensity == .logarithmic ? 0 : 1, Float(d.gain), d.histogramScale == .logarithmic ? 1 : 0)
    t.format = layout.channels == 1 ? .r16Unorm : (s.kind == .histogram ? .rgba16Unorm : .rgb10a2Unorm)
    t.parameters = r
    return t
  }

  /// Pixels of the widest parade panel across `width` plot pixels, split as
  /// `mk_panelOf` does (each pixel goes to the third its centre falls in).
  static func maximumPanelPixels(_ width: Int) -> Int {
    func start(_ k: Int) -> Int { (2 * k * width + 2) / 6 }
    return max(start(1) - start(0), start(2) - start(1), width - start(2))
  }

  /// The resolve the accumulator's last bins need, when they, the display or the
  /// plot size changed since the last one (the trace texture is reshaped here);
  /// nil when the trace is current.
  private func planResolve(_ accumulator: ScopeAccumulator, settings s: ScopeSettings, plot: SIMD4<Double>) throws
    -> ScopeResolveParameters?
  {
    let shape = Self.traceShape(accumulator, settings: s, plot: plot)
    parameters.traceMap = shape.map
    parameters.flags.w = shape.reduced
    let r = shape.parameters
    let key = ResolveKey(bins: ObjectIdentifier(accumulator.bins), generation: accumulator.generation, parameters: r)
    let fits =
      traceTexture?.width == shape.width && traceTexture?.height == shape.height
      && traceTexture?.pixelFormat == shape.format
    if key == resolveKey, fits {
      hasTrace = true
      return nil
    }
    if !fits {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: shape.format, width: shape.width, height: shape.height, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]
      d.storageMode = .private
      guard let texture = engine.device.makeTexture(descriptor: d) else {
        throw MonitorKitError.gpu("Cannot allocate a \(shape.width)×\(shape.height) scope trace texture.")
      }
      retired.retire(traceTexture)
      traceTexture = texture
    }
    bins = accumulator.bins
    resolveKey = key
    hasTrace = true
    return r
  }

  /// Threads: one per trace texel written, a SIMD-group wide.
  func resolveDispatch(_ r: ScopeResolveParameters) -> (grid: MTLSize, group: MTLSize) {
    let pipeline = engine.resolvePipeline
    let w = pipeline.threadExecutionWidth
    let width = Int(r.size.x), height = Int(r.size.y)
    return (
      MTLSize(width: width, height: height, depth: 1),
      MTLSize(width: w, height: max(1, min(height, pipeline.maxTotalThreadsPerThreadgroup / w / 2)), depth: 1)
    )
  }

  private func encodeResolve(
    _ accumulator: ScopeAccumulator, _ parameters: ScopeResolveParameters, into commandBuffer: MTLCommandBuffer
  ) throws {
    guard let texture = traceTexture, let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot encode the scope trace.")
    }
    var r = parameters
    encoder.setComputePipelineState(engine.resolvePipeline)
    encoder.setBytes(&r, length: MemoryLayout<ScopeResolveParameters>.stride, index: 0)
    encoder.setBuffer(accumulator.bins, offset: 0, index: 1)
    encoder.setBuffer(accumulator.statisticsBuffer, offset: 0, index: 2)
    encoder.setTexture(texture, index: 0)
    let d = resolveDispatch(r)
    encoder.dispatchThreads(d.grid, threadsPerThreadgroup: d.group)
    encoder.endEncoding()
  }

  /// Whether the graticule texture holds a `width` × `height` viewport without
  /// being more than twice the 64-pixel-rounded size it needs.
  private func graticuleFits(width: Int, height: Int) -> Bool {
    guard let t = graticuleTexture, t.width >= width, t.height >= height else { return false }
    return t.width * t.height <= 2 * Self.roundedUp(width) * Self.roundedUp(height)
  }

  private static func roundedUp(_ v: Int) -> Int { (v + 63) / 64 * 64 }

  /// Reallocates the graticule texture when it no longer fits the viewport.
  private func makeGraticuleTexture(width: Int, height: Int) throws {
    if !graticuleFits(width: width, height: height) {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm, width: Self.roundedUp(width), height: Self.roundedUp(height), mipmapped: false)
      d.usage = [.shaderRead, .renderTarget]
      d.storageMode = .private
      guard let texture = engine.device.makeTexture(descriptor: d) else {
        throw MonitorKitError.gpu("Cannot allocate a \(width)×\(height) graticule texture.")
      }
      retired.retire(graticuleTexture)
      graticuleTexture = texture
    }
  }

  private func rasterizeGraticule(width: Int, height: Int, into commandBuffer: MTLCommandBuffer) throws {
    let attachment = graticulePass.colorAttachments[0]!
    attachment.texture = graticuleTexture
    defer { attachment.texture = nil }
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: graticulePass) else {
      throw MonitorKitError.gpu("Cannot encode the scope graticule.")
    }
    let count = Int(shapes.size.z)
    if count > 0 {
      encoder.setRenderPipelineState(engine.graticulePipeline)
      encoder.setViewport(
        MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
      let length = MemoryLayout<ScopeGraticuleParameters>.stride
      encoder.setVertexBytes(&shapes, length: length, index: 0)
      encoder.setFragmentBytes(&shapes, length: length, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }
    encoder.endEncoding()
  }

  /// Real pictures concentrate their chroma; this keeps a typical scene's
  /// vectorscope cloud out of saturation at gain 1.
  static let vectorscopeConcentration = 32.0

  private func writeShapes(width w: Double, height h: Double, pixelsPerPoint: Double) {
    let side = min(w, h)
    let halfWidth = Float(max(0.5, pixelsPerPoint * 0.5))
    var count = 0
    for element in graticule.elements where count < ScopeGraticuleParameters.maximumShapes {
      var shape = ScopeShape()
      switch element {
      case .line(let a, let b, let major):
        shape.geometry = SIMD4(Float(a.x * w), Float(a.y * h), Float(b.x * w), Float(b.y * h))
        shape.style = SIMD4(0, major ? 1 : 0.45, halfWidth, 0)
      case .circle(let c, let r, let major):
        shape.geometry = SIMD4(Float(c.x * w), Float(c.y * h), Float(r * side), 0)
        shape.style = SIMD4(1, major ? 1 : 0.45, halfWidth, 0)
      case .box(let c, let half, let major):
        shape.geometry = SIMD4(Float(c.x * w), Float(c.y * h), Float(half * side), 0)
        shape.style = SIMD4(2, major ? 1 : 0.45, halfWidth, 0)
      }
      shapes.shapes[count] = shape
      count += 1
    }
    shapes.size.z = Float(count)
  }

  static func colors(settings s: ScopeSettings) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
    let single: SIMD4<Float> = s.display.trace == .white ? SIMD4(0.92, 0.92, 0.92, 1) : SIMD4(0.45, 1, 0.55, 1)
    let red = SIMD4<Float>(1, 0.18, 0.15, 1), green = SIMD4<Float>(0.2, 1, 0.25, 1)
    let blue = SIMD4<Float>(0.25, 0.45, 1, 1)
    switch s.kind {
    case .waveform:
      switch s.waveformMode {
      case .luma: return (single, single, single)
      case .rgbOverlay, .rgbParade: return (red, green, blue)
      case .ycbcrParade: return (single, SIMD4(0.35, 0.6, 1, 1), SIMD4(1, 0.4, 0.35, 1))
      }
    case .histogram:
      let neutral = SIMD4<Float>(0.85, 0.85, 0.85, 1)
      return s.histogramMode == .luma ? (neutral, neutral, neutral) : (red, green, blue)
    case .vectorscope: return (single, single, single)
    }
  }
}
