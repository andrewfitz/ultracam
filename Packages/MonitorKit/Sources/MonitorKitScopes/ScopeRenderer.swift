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
/// After each accumulation (or display change) a small compute pass resolves
/// the bins into a scope-resolution trace texture; every draw is then one
/// full-viewport triangle that samples it, with no allocation. The graticule is
/// rasterized into a viewport-sized r8 texture only when it changes.
public final class ScopeRenderer {
  public let engine: ScopeEngine
  /// The graticule of the last `prepare`/`render`, with label positions for the UI.
  public private(set) var graticule: ScopeGraticule
  /// Anti-aliased graticule coverage, one byte per viewport pixel.
  public private(set) var graticuleTexture: MTLTexture?
  /// Trace intensity per bin: r16Unorm for one channel, rgb10a2Unorm or
  /// rgba16Unorm (histogram) for three.
  public private(set) var traceTexture: MTLTexture?
  private var graticuleKey: GraticuleKey?
  private var resolveKey: ResolveKey?
  private var parameters = ScopeDrawParameters()
  private var pipeline: MTLRenderPipelineState?
  private var pipelineKey: ScopeEngine.RenderKey?
  /// Whether `pipeline` is the specialized one `pipelineKey` asks for.
  private var pipelineIsFinal = false
  /// The bins the trace was resolved from, kept alive so their identity in
  /// `resolveKey` cannot be reused.
  private var bins: MTLBuffer?
  private var hasTrace = false
  private var viewport = MTLViewport()
  private let pass = MTLRenderPassDescriptor()

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
  }

  /// Bytes of GPU memory this renderer owns: the graticule and trace textures.
  public var persistentMemoryBytes: Int { (graticuleTexture?.allocatedSize ?? 0) + (traceTexture?.allocatedSize ?? 0) }

  /// Draws in its own render pass into `target`. `viewport` defaults to the
  /// whole target and must lie inside it. `clear` clears the whole target
  /// first; otherwise the scope composites over its contents.
  public func render(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, target: MTLTexture,
    viewport: MonitorViewport? = nil, clear: Bool = false, into commandBuffer: MTLCommandBuffer
  ) throws {
    let area = viewport ?? MonitorViewport(width: target.width, height: target.height)
    guard area.x >= 0, area.y >= 0, area.x + area.width <= target.width, area.y + area.height <= target.height
    else { throw MonitorKitError.invalidFrame("viewport \(area) is outside the \(target.width)×\(target.height) target") }
    try prepare(
      accumulator, display: display, viewport: area, targetPixelFormat: target.pixelFormat, into: commandBuffer)
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

  /// For drawing inside the host's render pass: call before the host's
  /// render encoder starts, then `draw(with:)`. Encode it after the
  /// accumulation it shows. When the bins, the display or the graticule
  /// changed it encodes small compute passes into `commandBuffer`. The viewport
  /// must lie inside the host's target; an empty one throws.
  public func prepare(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, viewport area: MonitorViewport,
    targetPixelFormat: MTLPixelFormat, into commandBuffer: MTLCommandBuffer
  ) throws {
    guard area.width > 0, area.height > 0 else { throw MonitorKitError.invalidFrame("viewport is empty") }
    var s = accumulator.accumulatedSettings
    s.display = (display ?? accumulator.settings.display).normalized()
    let wantedKey = ScopeEngine.RenderKey(
      pixelFormat: targetPixelFormat, scope: ScopeEngine.DrawVariant(kind: s.kind.shaderCode, mode: s.shaderMode))
    if pipeline == nil || pipelineKey != wantedKey || !pipelineIsFinal {
      (pipeline, pipelineIsFinal) = try engine.renderPipeline(for: wantedKey)
      pipelineKey = wantedKey
    }
    if accumulator.hasData {
      try resolve(accumulator, settings: s, into: commandBuffer)
    } else {
      hasTrace = false
    }

    let w = Double(area.width), h = Double(area.height)
    var keySettings = s
    keySettings.display = s.display.graticuleKey
    // Brightness, gain or opacity changes never redraw the graticule.
    let key = GraticuleKey(
      settings: keySettings, context: accumulator.context, width: area.width, height: area.height,
      pixelsPerPoint: area.pixelsPerPoint)
    let redraw = key != graticuleKey || graticuleTexture?.width != area.width || graticuleTexture?.height != area.height
    if redraw {
      graticule = ScopeGraticule(settings: s, context: accumulator.context, viewportWidth: w, viewportHeight: h)
      writeShapes(width: w, height: h, pixelsPerPoint: area.pixelsPerPoint)
    }
    viewport = MTLViewport(
      originX: Double(area.x), originY: Double(area.y), width: w, height: h, znear: 0, zfar: 1)
    var p = parameters
    p.viewport = SIMD4(Float(area.x), Float(area.y), Float(w), Float(h))
    let plot = graticule.plot
    p.plot = SIMD4(Float(plot.x * w), Float(plot.y * h), Float(plot.z * w), Float(plot.w * h))
    let d = s.display
    p.shape.x = s.kind.shaderCode
    p.shape.y = s.shaderMode
    p.shape.z = UInt32(accumulator.layout.channels)
    let trace: UInt32 =
      d.trace == .white ? 1 : (d.trace == .colorized && s.kind == .vectorscope ? 2 : 0)
    p.flags = SIMD4(hasTrace ? 1 : 0, targetPixelFormat.isSRGB ? 1 : 0, trace, 0)
    p.intensity = SIMD4(Float(d.brightness), 0, 0, 0)
    p.background = SIMD4(
      Float(d.backgroundOpacity), d.showsGraticule ? Float(d.graticuleOpacity) : 0, 0, 0)
    let k = accumulator.context.matrix.coefficients
    p.chroma = SIMD4(Float(k.r), Float(k.b), Float(VectorscopeGeometry.halfExtent / Double(s.vectorscopeZoom)), 0)
    let colors = Self.colors(settings: s)
    p.color0 = colors.0
    p.color1 = colors.1
    p.color2 = colors.2
    p.graticuleColor = SIMD4(0.86, 0.82, 0.7, 1)
    parameters = p
    // The graticule kernel reads the plot and shapes just written.
    if redraw {
      try rasterizeGraticule(width: area.width, height: area.height, into: commandBuffer)
      graticuleKey = key
    }
  }

  /// Encodes the prepared scope into the host's render encoder. Sets the
  /// viewport, pipeline, fragment bytes 0 and fragment textures 0–1.
  public func draw(with encoder: MTLRenderCommandEncoder) {
    guard let pipeline, let graticuleTexture else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setViewport(viewport)
    encoder.setFragmentBytes(&parameters, length: MemoryLayout<ScopeDrawParameters>.stride, index: 0)
    encoder.setFragmentTexture(graticuleTexture, index: 0)
    encoder.setFragmentTexture(hasTrace ? traceTexture : engine.placeholderTrace, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
  }

  /// The resolve parameters and trace texture shape for the accumulator's last bins.
  static func resolveParameters(_ accumulator: ScopeAccumulator, settings s: ScopeSettings)
    -> (ScopeResolveParameters, MTLPixelFormat)
  {
    let layout = accumulator.layout
    let d = s.display
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
    var size = SIMD2(UInt32(layout.columns), UInt32(layout.rows))
    switch s.kind {
    case .waveform:
      unit = Double(frameHeight) / Double(layout.rows)
      r.bins = SIMD4(UInt32(layout.columns), UInt32(layout.rows), UInt32(frameWidth), UInt32(frameHeight))
      // One texel column per frame column when the frame is narrower.
      size.x = UInt32(min(layout.columns, frameWidth))
    case .vectorscope:
      unit = pixels / Double(layout.columns * layout.rows) * vectorscopeConcentration
      r.bins = SIMD4(UInt32(layout.columns), UInt32(layout.rows), 0, 0)
    case .histogram:
      unit = 1
      r.bins = SIMD4(UInt32(layout.columns), 1, 0, 0)
      size.y = 1
    }
    r.size = SIMD4(size.x, size.y, 0, 0)
    r.intensity = SIMD4(
      Float(d.gain / unit), d.intensity == .logarithmic ? 0 : 1, Float(d.gain), d.histogramScale == .logarithmic ? 1 : 0)
    let format: MTLPixelFormat =
      layout.channels == 1 ? .r16Unorm : (s.kind == .histogram ? .rgba16Unorm : .rgb10a2Unorm)
    return (r, format)
  }

  /// Resolves the accumulator's bins into the trace texture when they or the
  /// display changed since the last resolve.
  private func resolve(_ accumulator: ScopeAccumulator, settings s: ScopeSettings, into commandBuffer: MTLCommandBuffer)
    throws
  {
    var (r, format) = Self.resolveParameters(accumulator, settings: s)
    let key = ResolveKey(bins: ObjectIdentifier(accumulator.bins), generation: accumulator.generation, parameters: r)
    let width = Int(r.size.x), height = Int(r.size.y)
    if key == resolveKey, let t = traceTexture, t.width == width, t.height == height, t.pixelFormat == format {
      hasTrace = true
      return
    }
    if traceTexture?.width != width || traceTexture?.height != height || traceTexture?.pixelFormat != format {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: width, height: height, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]
      d.storageMode = .private
      guard let texture = engine.device.makeTexture(descriptor: d) else {
        throw MonitorKitError.gpu("Cannot allocate a \(width)×\(height) scope trace texture.")
      }
      traceTexture = texture
    }
    guard let texture = traceTexture, let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot encode the scope trace.")
    }
    let pipeline = engine.resolvePipeline
    encoder.setComputePipelineState(pipeline)
    encoder.setBytes(&r, length: MemoryLayout<ScopeResolveParameters>.stride, index: 0)
    encoder.setBuffer(accumulator.bins, offset: 0, index: 1)
    encoder.setBuffer(accumulator.statisticsBuffer, offset: 0, index: 2)
    encoder.setTexture(texture, index: 0)
    let w = pipeline.threadExecutionWidth
    encoder.dispatchThreads(
      MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(
        width: w, height: max(1, min(height, pipeline.maxTotalThreadsPerThreadgroup / w / 2)), depth: 1))
    encoder.endEncoding()
    bins = accumulator.bins
    resolveKey = key
    hasTrace = true
  }

  private func rasterizeGraticule(width: Int, height: Int, into commandBuffer: MTLCommandBuffer) throws {
    if graticuleTexture?.width != width || graticuleTexture?.height != height {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]
      d.storageMode = .private
      guard let texture = engine.device.makeTexture(descriptor: d) else {
        throw MonitorKitError.gpu("Cannot allocate a \(width)×\(height) graticule texture.")
      }
      graticuleTexture = texture
    }
    guard let texture = graticuleTexture, let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot encode the scope graticule.")
    }
    let pipeline = engine.graticulePipeline
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&parameters, length: MemoryLayout<ScopeDrawParameters>.stride, index: 0)
    let w = pipeline.threadExecutionWidth
    encoder.dispatchThreads(
      MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w / 4), depth: 1))
    encoder.endEncoding()
  }

  /// Real pictures concentrate their chroma; this keeps a typical scene's
  /// vectorscope cloud out of saturation at gain 1.
  static let vectorscopeConcentration = 32.0

  private func writeShapes(width w: Double, height h: Double, pixelsPerPoint: Double) {
    let side = min(w, h)
    let halfWidth = Float(max(0.5, pixelsPerPoint * 0.5))
    var count = 0
    for element in graticule.elements where count < ScopeDrawParameters.maximumShapes {
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
      parameters.shapes[count] = shape
      count += 1
    }
    parameters.shape.w = UInt32(count)
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
