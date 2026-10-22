import Foundation
import Metal
import MonitorKitCore

/// One per surface: draws a feed's frame with this surface's tools.
///
/// Everything derived from the inputs (layout, guide strokes, shader parameters,
/// status) is cached behind `Equatable` keys, so a steady-state frame allocates
/// nothing and encodes one draw. A change rebuilds only what depends on it: a
/// slider or a pinch recomputes uniforms, the status only when its text changes.
///
/// Confined: use from one thread at a time (not `Sendable`). Guides are drawn
/// analytically, so the pass owns no GPU memory.
public final class MonitorPass {
  public let engine: MonitorEngine
  /// Why a tool that is on is not drawn, and the labels of what is.
  public private(set) var status = MonitorStatus()
  /// Where the picture lands in the viewport, for hit testing and panning.
  public private(set) var layout: MonitorLayout?

  private let passDescriptor = MTLRenderPassDescriptor()
  private let colorAttachment: MTLRenderPassColorAttachmentDescriptor
  private var key: Key?
  private var guideKey: GuideKey?
  private var guides = GuideParameters()
  private var falseColorKey: FalseColorKey?
  private var falseColor = FalseColorResolution.off
  private var statusKey: StatusKey?
  private var parameters = PassParameters()
  private var variant = MonitorEngine.Variant.uber
  private var pipeline: MTLRenderPipelineState?
  private var pipelineKey: MonitorEngine.PipelineKey?
  /// Whether `pipeline` is the one built for `pipelineKey` (not the all-tools stand-in).
  private var pipelineIsSpecialized = false
  private var drawsDepthStencil = false
  /// Bindings from `prepare`, released by `draw` so no host texture outlives its frame here.
  private var pending: Pending?
  /// Times the cached state was rebuilt: once per change of the inputs, never per frame.
  public private(set) var rebuildCount = 0
  /// Times the status was rebuilt: only when a label or reason changes.
  public private(set) var statusRebuildCount = 0
  /// Times the guide strokes were rebuilt: only when their geometry changes.
  public private(set) var guideBuildCount = 0

  struct Pending {
    var frame: MonitorFrame
    var frameParameters: FrameParameters
    var burnInLUT: MonitorLUT?
    var monitorLUT: MonitorLUT?
    var focusMask: MTLTexture?
    var viewport: MonitorViewport
  }

  /// Everything the cached state depends on: the normalized state (so no NaN,
  /// which never equals itself, can force a rebuild per frame). LUTs compare by identity.
  struct Key: Equatable {
    var state: MonitorState
    var layout: PixelLayout
    var width: Int
    var height: Int
    var pixelAspectRatio: Double
    var signal: SignalDescription
    var viewport: MonitorViewport
    var target: MonitorRenderTargetFormat
    var burnInLUT: MonitorLUT?
    var monitorLUT: MonitorLUT?
    var maskValid: Bool

    static func == (a: Key, b: Key) -> Bool {
      a.maskValid == b.maskValid && a.burnInLUT === b.burnInLUT && a.monitorLUT === b.monitorLUT
        && a.width == b.width && a.height == b.height && a.target == b.target
        && a.viewport == b.viewport && a.layout == b.layout
        && a.pixelAspectRatio == b.pixelAspectRatio && a.signal == b.signal && a.state == b.state
    }
  }

  struct GuideKey: Equatable {
    var layout: MonitorLayout
    var guides: GuideSettings
    var pixelsPerPoint: Double
  }

  struct FalseColorKey: Equatable {
    var settings: FalseColorSettings
    var clean: Bool
    var signal: SignalDescription
    var floatLayout: Bool
    /// Whether a LUT produces the stage display-referred modes measure.
    var stageHasLUT: Bool
  }

  /// Exactly what the status text reads, so uniforms (opacities, brightness, pan)
  /// and continuous zoom within a label step never rebuild it.
  struct StatusKey: Equatable {
    var falseColor: FalseColorKey
    var clean: Bool
    var zebraEnabled: SIMD2<UInt8>
    var zebraModes: SIMD2<UInt8>
    var zebraLevels: SIMD4<Double>
    var focusEnabled: Bool
    var focusStyle: PeakingStyle
    var focusStage: SignalStage
    var maskValid: Bool
    var guidesEnabled: Bool
    var magnified: Bool
    var pixelExact: Bool
    var zoomLabel: Double
    var desqueeze: Double
    var flip: FlipMode
    var monochrome: MonochromeMode
    var displayIdentity: Bool
    var burnInLUT: ObjectIdentifier?
    var monitorLUT: ObjectIdentifier?
  }

  init(engine: MonitorEngine) {
    self.engine = engine
    colorAttachment = passDescriptor.colorAttachments[0]
    colorAttachment.storeAction = .store
    colorAttachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
  }

  /// Draws in its own render pass into `target`. `viewport` defaults to the whole
  /// target. `clear` clears the whole attachment first, so when several passes
  /// share a target only the first should clear; every pixel of the viewport is
  /// written either way (black outside the picture).
  ///
  /// The pass writes display-encoded SDR values (linearized for `*_srgb` targets,
  /// so the hardware encode stores them). HDR output for EDR layers is not
  /// implemented yet: give an `rgba16Float` layer a non-linear SDR colour space.
  public func encode(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, target: MTLTexture,
    viewport: MonitorViewport? = nil, clear: Bool = true, into commandBuffer: MTLCommandBuffer
  ) throws {
    let vp = viewport ?? MonitorViewport(width: target.width, height: target.height)
    guard vp.x >= 0, vp.y >= 0, vp.x + vp.width <= target.width, vp.y + vp.height <= target.height
    else { throw MonitorKitError.invalidFrame("viewport \(vp) is outside the \(target.width)×\(target.height) target") }
    let format = MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat, sampleCount: target.sampleCount)
    try prepare(frame: frame, feed: feed, state: state, viewport: vp, target: format, into: commandBuffer)
    colorAttachment.texture = target
    colorAttachment.loadAction = clear ? .clear : .load
    let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
    colorAttachment.texture = nil
    guard let encoder else {
      pending = nil
      throw MonitorKitError.gpu("Cannot create a render encoder.")
    }
    defer { encoder.endEncoding() }
    try draw(with: encoder)
  }

  /// For drawing inside the host's own render pass with a single colour
  /// attachment: call `prepare`, then `draw(with:)` inside the pass.
  public func prepare(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, viewport: MonitorViewport,
    targetPixelFormat: MTLPixelFormat, into commandBuffer: MTLCommandBuffer
  ) throws {
    try prepare(
      frame: frame, feed: feed, state: state, viewport: viewport,
      target: MonitorRenderTargetFormat(colorPixelFormat: targetPixelFormat), into: commandBuffer)
  }

  /// For drawing inside the host's own render pass, which may have depth,
  /// stencil, multisampling and further colour attachments (`target` describes
  /// them). Call before or inside the pass; it encodes nothing. Then `draw(with:)`.
  public func prepare(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, viewport: MonitorViewport,
    target: MonitorRenderTargetFormat, into commandBuffer: MTLCommandBuffer
  ) throws {
    guard viewport.width > 0, viewport.height > 0 else {
      throw MonitorKitError.invalidFrame("viewport is empty")
    }
    let s = normalized(state)
    let maskValid =
      s.focus.enabled && feed.hasFocusMask(for: frame, stage: s.focus.stage, monitorLUTEnabled: s.monitorLUT)
    let par = frame.pixelAspectRatio.isFinite && frame.pixelAspectRatio > 0 ? frame.pixelAspectRatio : 1
    let next = Key(
      state: s, layout: frame.layout, width: frame.width, height: frame.height, pixelAspectRatio: par,
      signal: frame.signal, viewport: viewport, target: target, burnInLUT: feed.burnInLUT,
      monitorLUT: feed.monitorLUT, maskValid: maskValid)
    let frameParameters = frame.parameters
    if key != next {
      rebuild(next, frameParameters: frameParameters)
      key = next
    }
    try updatePipeline(target: target, layout: frame.layout.shaderKind)
    pending = Pending(
      frame: frame, frameParameters: frameParameters, burnInLUT: feed.burnInLUT,
      monitorLUT: s.monitorLUT ? feed.monitorLUT : nil, focusMask: maskValid ? feed.focusMask : nil,
      viewport: viewport)
  }

  /// Draws the prepared frame. Sets the encoder's pipeline, viewport, fragment
  /// textures 0–5 and fragment buffers 0–4, and, when the target has depth or
  /// stencil, a depth-stencil state that always passes and never writes.
  public func draw(with encoder: MTLRenderCommandEncoder) throws {
    guard let p = pending, let pipeline else {
      throw MonitorKitError.gpu("MonitorPass.draw(with:) needs prepare(…) first.")
    }
    pending = nil
    let vp = p.viewport
    encoder.setRenderPipelineState(pipeline)
    if drawsDepthStencil { encoder.setDepthStencilState(engine.depthStencil) }
    encoder.setViewport(
      MTLViewport(
        originX: Double(vp.x), originY: Double(vp.y), width: Double(vp.width), height: Double(vp.height),
        znear: 0, zfar: 1))
    encoder.setFragmentTexture(p.frame.packed ?? engine.emptyPacked, index: 0)
    encoder.setFragmentTexture(p.frame.luma ?? engine.emptyFloat, index: 1)
    encoder.setFragmentTexture(p.frame.chroma ?? engine.emptyFloat, index: 2)
    encoder.setFragmentTexture(p.burnInLUT?.texture ?? engine.emptyLUT, index: 3)
    encoder.setFragmentTexture(p.monitorLUT?.texture ?? engine.emptyLUT, index: 4)
    encoder.setFragmentTexture(p.focusMask ?? engine.emptyFloat, index: 5)
    var frameParameters = p.frameParameters
    encoder.setFragmentBytes(&frameParameters, length: MemoryLayout<FrameParameters>.stride, index: 0)
    var burn = p.burnInLUT?.parameters ?? .disabled
    encoder.setFragmentBytes(&burn, length: MemoryLayout<LUTParameters>.stride, index: 1)
    var monitor = p.monitorLUT?.parameters ?? .disabled
    encoder.setFragmentBytes(&monitor, length: MemoryLayout<LUTParameters>.stride, index: 2)
    encoder.setFragmentBytes(&parameters, length: MemoryLayout<PassParameters>.stride, index: 3)
    encoder.setFragmentBytes(&guides, length: MemoryLayout<GuideParameters>.stride, index: 4)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
  }

  /// Bytes of GPU memory this surface owns: none (guides are analytic).
  public var persistentMemoryBytes: Int { 0 }

  /// The shader parameters in effect, for tests and diagnostics.
  public var currentParameters: PassParameters { parameters }
  /// The guide strokes in effect, for tests and diagnostics.
  public var currentGuides: GuideParameters { guides }
  /// Whether the pipeline in use is specialized to this surface's tool set
  /// (false while it compiles asynchronously and the all-tools pipeline stands in).
  public var usesSpecializedPipeline: Bool { pipelineIsSpecialized }

  private var lastInput: MonitorState?
  private var lastNormalized = MonitorState()

  /// `state.normalized()`, reused while the input is bit-for-bit the last one.
  /// Equal bytes mean the same scalars (NaN included) and the same array buffers;
  /// the check reads no array element, so a steady state allocates nothing even in
  /// debug builds, and a NaN input is normalized once, not every frame.
  private func normalized(_ state: MonitorState) -> MonitorState {
    if let last = lastInput, Self.identical(last, state) { return lastNormalized }
    lastInput = state
    lastNormalized = state.normalized()
    return lastNormalized
  }

  static func identical(_ a: MonitorState, _ b: MonitorState) -> Bool {
    withUnsafeBytes(of: a) { x in
      withUnsafeBytes(of: b) { y in memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 }
    }
  }

  // MARK: - Pipeline

  private func updatePipeline(target: MonitorRenderTargetFormat, layout kind: UInt32) throws {
    let wanted = MonitorEngine.PipelineKey(
      target: target, layout: kind, variant: engine.specialization == .off ? .uber : variant)
    if pipeline != nil, pipelineKey == wanted, pipelineIsSpecialized { return }
    if wanted.variant == .uber {
      pipeline = try engine.renderPipeline(wanted)
      pipelineIsSpecialized = true
    } else if let specialized = try engine.specializedPipeline(wanted) {
      pipeline = specialized
      pipelineIsSpecialized = true
    } else if pipelineKey != wanted || pipeline == nil {
      var uber = wanted
      uber.variant = .uber
      pipeline = try engine.renderPipeline(uber)
      pipelineIsSpecialized = false
    }
    pipelineKey = wanted
    drawsDepthStencil = target.hasDepthOrStencil
  }

  // MARK: - Rebuild on change

  private func rebuild(_ k: Key, frameParameters: FrameParameters) {
    rebuildCount += 1
    let s = k.state
    let vp = k.viewport
    let layout = MonitorLayout(
      pictureWidth: k.width, pictureHeight: k.height, pixelAspectRatio: k.pixelAspectRatio,
      viewportWidth: vp.width, viewportHeight: vp.height, geometry: s.geometry)

    let showGuides = s.guides.enabled && !s.clean && !layout.isMagnified
    // Colour, opacity and contrast are uniforms: only geometry rebuilds the strokes.
    var geometryOnly = s.guides
    geometryOnly.color = ColorRGB(r: 1, g: 1, b: 1)
    geometryOnly.opacity = 1
    geometryOnly.contrast = 1
    let nextGuideKey =
      showGuides ? GuideKey(layout: layout, guides: geometryOnly, pixelsPerPoint: vp.pixelsPerPoint) : nil
    var raster = GuideRaster()
    if nextGuideKey != guideKey {
      raster = showGuides ? GuideRaster(layout: layout, guides: s.guides, pixelsPerPoint: vp.pixelsPerPoint) : GuideRaster()
      // The dark outline is a point wide, at least a pixel.
      guides = GuideParameters(raster, outline: max(1, vp.pixelsPerPoint.rounded()))
      guideMatte = (raster.matteRect, raster.matteOpacity)
      guideKey = nextGuideKey
      guideBuildCount += 1
    }

    let monitorLUT = s.monitorLUT && k.monitorLUT != nil
    let stageHasLUT =
      (s.falseColor.stage != .source && k.burnInLUT != nil) || (s.falseColor.stage == .monitor && monitorLUT)
    let fcKey = FalseColorKey(
      settings: s.falseColor, clean: s.clean, signal: k.signal, floatLayout: k.layout.isFloat, stageHasLUT: stageHasLUT)
    if fcKey != falseColorKey {
      falseColor = Self.resolveFalseColor(
        s, signal: k.signal, full: k.signal.range == .full || k.layout.isFloat, stageHasLUT: stageHasLUT)
      falseColorKey = fcKey
    }
    parameters = Self.makeParameters(
      s, key: k, layout: layout, guides: guides, matte: guideMatte, falseColor: falseColor,
      frameParameters: frameParameters)
    variant = Self.variant(parameters, state: s, layout: layout)

    let m = s.geometry.magnification
    let nextStatusKey = StatusKey(
      falseColor: fcKey, clean: s.clean,
      zebraEnabled: SIMD2(s.zebras[0].enabled ? 1 : 0, s.zebras[1].enabled ? 1 : 0),
      zebraModes: SIMD2(s.zebras[0].mode == .band ? 1 : 0, s.zebras[1].mode == .band ? 1 : 0),
      zebraLevels: SIMD4(s.zebras[0].level, s.zebras[0].range, s.zebras[1].level, s.zebras[1].range),
      focusEnabled: s.focus.enabled, focusStyle: s.focus.style, focusStage: s.focus.stage, maskValid: k.maskValid,
      guidesEnabled: s.guides.enabled, magnified: layout.isMagnified, pixelExact: m.pixelExact,
      zoomLabel: Self.zoomLabel(m.zoom), desqueeze: s.geometry.desqueeze, flip: s.geometry.flip,
      monochrome: s.display.monochrome, displayIdentity: s.display.isIdentity,
      burnInLUT: k.burnInLUT.map(ObjectIdentifier.init),
      monitorLUT: s.monitorLUT ? k.monitorLUT.map(ObjectIdentifier.init) : nil)
    if nextStatusKey != statusKey {
      status = Self.makeStatus(s, key: k, layout: layout, falseColor: falseColor)
      statusKey = nextStatusKey
      statusRebuildCount += 1
    }
    self.layout = layout
  }

  private var guideMatte: (rect: MonitorRect?, opacity: Double) = (nil, 0)

  /// The tiers this surface's parameters reach, so the pipeline carries no other tool.
  static func variant(_ p: PassParameters, state s: MonitorState, layout: MonitorLayout) -> MonitorEngine.Variant {
    let measure = p.modes.x
    let logFalseColor = measure >= FalseColorMeasureCode.sony.rawValue && measure <= FalseColorMeasureCode.elZone.rawValue
    let stageFalseColor = measure >= FalseColorMeasureCode.stageIRE.rawValue
    let navigator = p.navigatorRect.x < p.navigatorRect.z
    let zebraBits = p.zebra.z
    let zebra0 = zebraBits & 1 != 0, zebra1 = zebraBits & 2 != 0
    // The highest stage anything reads: the picture shows the monitor stage
    // unless false colour replaces it, and the navigator always does.
    var stage: UInt32 = 0
    if measure == 0 || navigator { stage = 2 }
    if stageFalseColor { stage = max(stage, p.modes.y) }
    if zebra0 { stage = max(stage, p.zebra.x) }
    if zebra1 { stage = max(stage, p.zebra.y) }
    let luts: UInt32 = (stage >= 1 && p.luts.x != 0 ? 1 : 0) | (stage == 2 && p.luts.y != 0 ? 2 : 0)
    let nearest = p.flags.x != 0 || logFalseColor
    let magnifiedMain = !nearest && (layout.footprintX < 1 || layout.footprintY < 1)
    let navigatorMap = layout.navigatorToPicture
    let magnifiedNavigator = navigator && (abs(navigatorMap.scaleX) < 1 || abs(navigatorMap.scaleY) < 1)
    return MonitorEngine.Variant(
      luts: luts, zebras: zebraBits != 0, peaking: p.focus.z != 0, guides: p.guide.z != 0,
      falseColor: (logFalseColor ? 1 : 0) | (stageFalseColor ? 2 : 0),
      interpolates: magnifiedMain || magnifiedNavigator, navigator: navigator, adjust: p.flags.y == 0)
  }

  // MARK: - False colour

  enum FalseColorResolution {
    case off
    case unavailable(MonitorUnavailableReason)
    case active(
      measure: FalseColorMeasureCode, bands: [FalseColorBand], arriFullRange: Bool, label: String,
      provisional: Bool)
  }

  /// `full`: whether the ARRI tables are the full-range ones. The range follows
  /// how the camera's codes reached us, not only the container flag. `stageHasLUT`:
  /// a LUT produces the measured stage, which is then Rec.709 display R'G'B'.
  static func resolveFalseColor(
    _ s: MonitorState, signal: SignalDescription, full container: Bool, stageHasLUT: Bool = false
  ) -> FalseColorResolution
  {
    let fc = s.falseColor
    guard fc.mode != .off else { return .off }
    if s.clean { return .unavailable(.cleanFeed) }
    let log = signal.encoding.log
    let full = container || log?.transport == .fullRescaledToLegal
    var label: String
    var provisional = false
    if fc.mode.needsLogSource {
      guard let log else { return .unavailable(.requiresLogSource) }
      let sony = log.curve == .sLog3
      let sGamut = sony && (log.gamut == .sGamut3 || log.gamut == .sGamut3Cine)
      switch fc.mode {
      case .sonySLog3:
        guard sony else { return .unavailable(.unsupportedLogEncoding(log)) }
        label = SonySLog3FalseColor.displayName
      case .arriStyleSLog3:
        guard sGamut else { return .unavailable(.unsupportedLogEncoding(log)) }
        label = SonyARRIStyleFalseColor.displayName
      case .elZone:
        guard sGamut else { return .unavailable(.unsupportedLogEncoding(log)) }
        label = ELZoneProfile.displayName + " (provisional)"
        provisional = true
      default:
        guard let profile = FalseColorTable.arriProfile(for: log.curve) else {
          return .unavailable(.unsupportedLogEncoding(log))
        }
        label = profile.displayName + (full ? " · full range" : " · legal range")
      }
    } else if fc.mode == .sixBand {
      label = SixBandFalseColor.displayName
    } else {
      label = fc.customUnit == .ire ? "Custom false color · IRE" : "Custom false color · stops"
      // Stops need light, so an unlabelled source has none unless a LUT stage measures it.
      if fc.customUnit == .stops, !stageHasLUT, signal.encoding == .unknown {
        return .unavailable(.requiresKnownTransfer)
      }
    }
    let bands = FalseColorTable.bands(for: fc, arriCurve: log?.curve, arriFullRange: full)
    guard !bands.isEmpty else { return .unavailable(.noBands) }
    let measure: FalseColorMeasureCode
    switch FalseColorTable.measure(for: fc) {
    case .sonyNativeIRE: measure = .sony
    case .logC3ReferenceCode: measure = .arriStyle
    case .logCCode: measure = .arriLogC
    case .sLog3Stops: measure = .elZone
    case .stageIRE: measure = .stageIRE
    case .stageStops: measure = .stageStops
    case nil: return .off
    }
    return .active(measure: measure, bands: bands, arriFullRange: full, label: label, provisional: provisional)
  }

  // MARK: - Parameters

  static func rect(_ r: MonitorRect) -> SIMD4<Float> {
    SIMD4(Float(r.x), Float(r.y), Float(r.maxX), Float(r.maxY))
  }
  static func map(_ m: AxisMap) -> SIMD4<Float> {
    SIMD4(Float(m.scaleX), Float(m.scaleY), Float(m.offsetX), Float(m.offsetY))
  }
  static func color(_ c: ColorRGB, _ w: Float = 1) -> SIMD4<Float> {
    SIMD4(Float(c.r), Float(c.g), Float(c.b), w)
  }

  static func logCurveCode(_ curve: LogCurve) -> UInt32 {
    switch curve {
    case .sLog3: return 1
    case .arriLogC3: return 2
    case .arriLogC4: return 3
    }
  }

  /// `mk_exposureLinear`'s transfer code.
  static func transferCode(_ encoding: SignalEncoding) -> UInt32 {
    guard case .display(let t) = encoding else { return 0 }
    switch t {
    case .bt709: return 0
    case .sRGB: return 1
    case .pq: return 2
    case .hlg: return 3
    case .linear: return 4
    }
  }

  static func stageCode(_ stage: SignalStage) -> UInt32 {
    switch stage {
    case .source: return 0
    case .output: return 1
    case .monitor: return 2
    }
  }

  static func makeParameters(
    _ s: MonitorState, key k: Key, layout: MonitorLayout, guides: GuideParameters,
    matte: (rect: MonitorRect?, opacity: Double), falseColor: FalseColorResolution, frameParameters: FrameParameters
  ) -> PassParameters {
    var p = PassParameters()
    let vp = k.viewport
    let clean = s.clean
    p.displayToPicture = map(layout.displayToPicture)
    p.imageRect = rect(layout.imageRect)
    // The navigator is an overlay: a clean feed shows only the zoomed picture.
    if let nav = layout.navigatorRect, !clean {
      p.navigatorRect = rect(nav)
      let m = layout.navigatorToPicture, v = layout.visiblePictureRect
      let x0 = (v.x - m.offsetX) / m.scaleX, x1 = (v.maxX - m.offsetX) / m.scaleX
      let y0 = (v.y - m.offsetY) / m.scaleY, y1 = (v.maxY - m.offsetY) / m.scaleY
      p.navigatorToPicture = map(m)
      p.navigatorVisible = SIMD4(Float(min(x0, x1)), Float(min(y0, y1)), Float(max(x0, x1)), Float(max(y0, y1)))
    }
    p.viewport = SIMD4(Float(vp.x), Float(vp.y), Float(vp.width), Float(vp.height))
    p.guideRect = rect(layout.imageRect)

    // Explicit indices and `while` loops: no iterator, so a rebuild (a slider
    // drag, a pinch) allocates nothing even unoptimized. `normalized()` keeps two sets.
    var zebraBits: UInt32 = 0
    func zebra(_ z: ZebraSet, stripe: Float) -> SIMD4<Float> {
      let bounds =
        z.mode == .lowerLimit
        ? SIMD2(Float(z.level), Float.infinity) : SIMD2(Float(z.level - z.range), Float(z.level + z.range))
      return SIMD4(bounds.x, bounds.y, Float(z.opacity), stripe)
    }
    let z0 = s.zebras[0], z1 = s.zebras[1]
    // Set 1 is light stripes, set 2 dark, so overlapping sets stay readable.
    p.zebra0 = zebra(z0, stripe: 1)
    p.zebra1 = zebra(z1, stripe: 0.12)
    if z0.enabled && !clean { zebraBits |= 1 }
    if z1.enabled && !clean { zebraBits |= 2 }
    let period = UInt32(max(4, 2 * Int((8 * vp.pixelsPerPoint).rounded())))
    p.zebra = SIMD4(stageCode(z0.stage), stageCode(z1.stage), zebraBits, period)

    let log = k.signal.encoding.log
    p.gamutWeights = color(log?.gamut.luminanceCoefficients ?? ColorGamut.rec709.luminanceCoefficients, 0)
    if case .active(let measure, let bands, let full, _, _) = falseColor {
      let restore: UInt32 = frameParameters.options.w != 0 ? 1 : 0
      let count = min(bands.count, PassParameters.maximumBands)
      p.modes = SIMD4(measure.rawValue, stageCode(s.falseColor.stage), UInt32(count), restore)
      p.falseColor = SIMD4(Float(s.falseColor.referenceOffsetStops), full ? 1 : 0, 0, 0)
      var i = 0
      while i < count {
        p.bandEdges[i] = SIMD4(Float(bands[i].lower), Float(bands[i].upper), 0, 0)
        p.bandColors[i] = color(bands[i].color)
        i += 1
      }
    }

    let f = s.focus
    p.focus = SIMD4(Float(f.opacity), f.style == .peak ? 1 : 0, f.enabled && k.maskValid && !clean ? 1 : 0, 0)
    p.focusColor = color(f.color.rgb)

    let g = s.guides
    let lines = guides.counts.x + guides.counts.y + guides.counts.z > 0
    let guidesOn = g.enabled && !clean && !layout.isMagnified && (lines || matte.rect != nil)
    p.guide = SIMD4(Float(g.opacity), Float(g.contrast * g.opacity), guidesOn ? 1 : 0, Float(matte.opacity))
    p.guideColor = color(g.color, guidesOn && lines ? 1 : 0)
    if guidesOn, let m = matte.rect { p.matte = rect(m) }

    let d = s.display
    let mono: Float = d.monochrome == .luma ? 1 : (d.monochrome == .blueOnly ? 2 : 0)
    p.display = SIMD4(Float(d.brightness), Float(d.contrast), Float(d.saturation), mono)
    p.flags = SIMD4(
      s.geometry.magnification.pixelExact ? 1 : 0, d.isIdentity ? 1 : 0,
      k.target.colorPixelFormat.isSRGB ? 1 : 0, clean ? 1 : 0)
    p.luts = SIMD4(
      k.burnInLUT != nil ? 1 : 0, s.monitorLUT && k.monitorLUT != nil ? 1 : 0,
      log.map { logCurveCode($0.curve) } ?? 0, transferCode(k.signal.encoding))
    return p
  }

  // MARK: - Status

  static func number(_ v: Double) -> String {
    v.rounded() == v ? String(Int(v)) : String(format: "%.3g", v)
  }

  /// Zoom as labelled: tenths below 10×, whole steps above, so a pinch changes the label rarely.
  static func zoomLabel(_ zoom: Double) -> Double {
    zoom < 10 ? (zoom * 10).rounded() / 10 : zoom.rounded()
  }

  static func makeStatus(
    _ s: MonitorState, key k: Key, layout: MonitorLayout, falseColor: FalseColorResolution
  ) -> MonitorStatus {
    var status = MonitorStatus()
    func on(_ tool: MonitorTool, _ label: String, provisional: Bool = false) {
      status.active.append(.init(tool: tool, label: label, isProvisional: provisional))
    }
    func off(_ tool: MonitorTool, _ reason: MonitorUnavailableReason) {
      status.unavailable.append(.init(tool: tool, reason: reason))
    }
    if let lut = k.burnInLUT { on(.burnInLUT, "LUT · \(lut.cube.title)") }
    if s.monitorLUT, let lut = k.monitorLUT { on(.monitorLUT, "Monitor LUT · \(lut.cube.title)") }
    switch falseColor {
    case .off: break
    case .unavailable(let reason): off(.falseColor, reason)
    case .active(_, _, _, let label, let provisional): on(.falseColor, label, provisional: provisional)
    }
    for (i, z) in s.zebras.prefix(2).enumerated() where z.enabled {
      let tool: MonitorTool = i == 0 ? .zebra1 : .zebra2
      if s.clean {
        off(tool, .cleanFeed)
      } else {
        let range =
          z.mode == .lowerLimit
          ? "\(number(z.level))+ IRE" : "\(number(z.level - z.range))–\(number(z.level + z.range)) IRE"
        on(tool, "Zebra \(i + 1) · \(range)")
      }
    }
    if s.focus.enabled {
      if s.clean { off(.focusPeaking, .cleanFeed) }
      else if !k.maskValid { off(.focusPeaking, .focusNotAnalyzed) }
      else {
        let stage = s.focus.stage == .source ? "" : (s.focus.stage == .output ? " · output" : " · monitor")
        on(.focusPeaking, (s.focus.style == .peak ? "Peaking · peak" : "Peaking") + stage)
      }
    }
    if s.guides.enabled {
      if s.clean { off(.guides, .cleanFeed) }
      else if layout.isMagnified { off(.guides, .hiddenWhileMagnified) }
      else { on(.guides, "Guides") }
    }
    let m = s.geometry.magnification
    if m.pixelExact { on(.magnification, "1:1") }
    else if layout.isMagnified { on(.magnification, "\(number(zoomLabel(m.zoom)))×") }
    if s.geometry.desqueeze != 1 { on(.desqueeze, "De-squeeze \(number(s.geometry.desqueeze))×") }
    switch s.geometry.flip {
    case .none: break
    case .horizontal: on(.flip, "Flip H")
    case .vertical: on(.flip, "Flip V")
    case .rotate180: on(.flip, "Rotate 180°")
    }
    switch s.display.monochrome {
    case .luma: on(.displayAdjustments, "Mono")
    case .blueOnly: on(.displayAdjustments, "Blue only")
    case .off: if !s.display.isIdentity { on(.displayAdjustments, "Display adjusted") }
    }
    return status
  }
}
