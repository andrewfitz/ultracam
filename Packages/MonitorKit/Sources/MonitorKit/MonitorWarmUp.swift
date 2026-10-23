import Metal
import MonitorKitCore

/// A surface to build pipelines for before its first frame: the inputs a
/// `MonitorPass` specializes its pipeline on (target, layout, tool set, colour
/// path), without textures. See `MonitorEngine.warmUp(targets:layouts:surfaces:)`.
public struct MonitorSurfaceConfiguration: Sendable {
  public var target: MonitorRenderTargetFormat
  public var layout: PixelLayout
  public var state: MonitorState
  public var signal: SignalDescription
  public var outputColor: MonitorOutputColor
  public var hasBurnInLUT: Bool
  public var hasMonitorLUT: Bool
  /// Frame and viewport sizes decide the filter (a magnified picture interpolates),
  /// with `pixelAspectRatio` and `cleanAperture`. When either size is nil both
  /// filter variants are built.
  public var frameSize: (width: Int, height: Int)?
  public var viewportSize: (width: Int, height: Int)?
  /// The frames' pixel aspect ratio (`MonitorFrame.pixelAspectRatio`): anamorphic
  /// pixels change the footprint, so e.g. 1440×1080 HDV (4/3) in a 1920×1080 view
  /// interpolates where square pixels would not.
  public var pixelAspectRatio: Double
  /// The frames' clean aperture (`MonitorFrame.cleanAperture`, frame pixels); used
  /// with `frameSize` only.
  public var cleanAperture: MonitorRect?
  /// The compute picture (`MonitorPass.encodeCompute`) instead of the render pipeline.
  public var compute: Bool

  public init(
    target: MonitorRenderTargetFormat, layout: PixelLayout, state: MonitorState = MonitorState(),
    signal: SignalDescription = .rec709, outputColor: MonitorOutputColor = .signalNative, hasBurnInLUT: Bool = false,
    hasMonitorLUT: Bool = false, frameSize: (width: Int, height: Int)? = nil,
    viewportSize: (width: Int, height: Int)? = nil, compute: Bool = false, pixelAspectRatio: Double = 1,
    cleanAperture: MonitorRect? = nil
  ) {
    self.pixelAspectRatio = pixelAspectRatio
    self.cleanAperture = cleanAperture
    self.target = target
    self.layout = layout
    self.state = state
    self.signal = signal
    self.outputColor = outputColor
    self.hasBurnInLUT = hasBurnInLUT
    self.hasMonitorLUT = hasMonitorLUT
    self.frameSize = frameSize
    self.viewportSize = viewportSize
    self.compute = compute
  }
}

extension MonitorEngine {
  /// The layer formats a monitor uses: `bgr10a2Unorm` (SDR pictures),
  /// `rgba16Float` (HDR/EDR pictures) and `bgra8Unorm` (scopes, sRGB graphics).
  public static let standardTargetFormats: [MTLPixelFormat] = [.bgr10a2Unorm, .rgba16Float, .bgra8Unorm]

  /// Builds now, on the calling thread, every pipeline a first frame could need,
  /// so no frame ever waits for a compile (a switch to an HLG layer included):
  /// - for each of `targets` and `layouts` (nil: all five layout kinds), the
  ///   all-tools picture pipeline, the focus-analysis pipelines and Freeze's copy
  ///   kernels (`prepare(target:layouts:)`);
  /// - for each of `surfaces`, the pipeline specialized to its tool set and colour
  ///   path, the one `MonitorPass` switches to once it is ready (peaking counted as
  ///   drawn when `state.focus.enabled`, i.e. the frame analysed).
  ///
  /// Call it off the frame path, e.g. from a background task at start-up: it may
  /// take a few hundred milliseconds. Thread-safe; concurrent encodes keep drawing
  /// with whatever is built. Already built pipelines are skipped. Returns the
  /// number of pipelines built by this call.
  @discardableResult
  public func warmUp(
    targets: [MonitorRenderTargetFormat] = standardTargetFormats.map { MonitorRenderTargetFormat(colorPixelFormat: $0) },
    layouts: [PixelLayout]? = nil, surfaces: [MonitorSurfaceConfiguration] = []
  ) throws -> Int {
    let before = pipelinesBuilt
    for target in targets { try prepare(target: target, layouts: layouts) }
    for surface in surfaces {
      for key in try Self.pipelineKeys(for: surface, placeholder: warmUpLUT()) {
        if surface.compute { _ = try computePipeline(key) } else { _ = try renderPipeline(key) }
      }
    }
    return pipelinesBuilt - before
  }

  /// The specialized pipeline keys `surface` can draw with: one, or one per
  /// filter variant when either size is not given.
  static func pipelineKeys(for surface: MonitorSurfaceConfiguration, placeholder: MonitorLUT) throws
    -> [PipelineKey]
  {
    let state = surface.state.normalized()
    let output = surface.outputColor.normalized().withoutHeadroom
    typealias Size = (width: Int, height: Int)
    // Unknown sizes: a minified (box) and a magnified (bicubic) picture, eight
    // times smaller and larger than the known size (4K when neither is known).
    func scaled(_ s: Size, _ f: Double) -> Size {
      (max(1, Int((Double(max(1, s.width)) * f).rounded())), max(1, Int((Double(max(1, s.height)) * f).rounded())))
    }
    var pairs: [(frame: Size, viewport: Size)] = []
    switch (surface.frameSize, surface.viewportSize) {
    case let (frame?, viewport?): pairs = [(frame, viewport)]
    case let (frame?, nil): pairs = [(frame, scaled(frame, 1.0 / 8)), (frame, scaled(frame, 8))]
    case let (nil, viewport?): pairs = [(scaled(viewport, 8), viewport), (scaled(viewport, 1.0 / 8), viewport)]
    case (nil, nil):
      let frame: Size = (3840, 2160)
      pairs = [(frame, scaled(frame, 1.0 / 8)), (frame, scaled(frame, 8))]
    }
    // The pass's own normalization: a broken ratio is 0 (shown square).
    let par = MonitorFrame.stablePixelAspectRatio(surface.pixelAspectRatio)
    var keys: [PipelineKey] = []
    for (frame, viewport) in pairs {
      // An aperture belongs to a known frame size, normalized as the pass does.
      let aperture =
        surface.frameSize != nil && surface.cleanAperture != nil
        ? Optional(
          MonitorFrameGeometry(width: max(1, frame.width), height: max(1, frame.height), cleanAperture: surface.cleanAperture)
            .shownRect) : nil
      let key = MonitorPass.Key(
        state: state, layout: surface.layout, width: max(1, frame.width), height: max(1, frame.height),
        pixelAspectRatio: par, cleanAperture: aperture, processed: false, signal: surface.signal,
        viewport: MonitorViewport(width: max(1, viewport.width), height: max(1, viewport.height)),
        target: surface.target, burnInLUT: surface.hasBurnInLUT ? placeholder : nil,
        monitorLUT: surface.hasMonitorLUT ? placeholder : nil, maskValid: state.focus.enabled, output: output)
      let variant = MonitorPass.specialization(for: key)
      var pipelineKey = PipelineKey(
        target: surface.compute ? MonitorRenderTargetFormat(colorPixelFormat: .invalid) : surface.target,
        layout: surface.layout.shaderKind, variant: variant.variant, color: variant.color)
      if surface.compute { pipelineKey = computeKey(pipelineKey) }
      if !keys.contains(pipelineKey) { keys.append(pipelineKey) }
    }
    return keys
  }

  /// A 2³ identity LUT standing in for a surface's LUTs while deriving its tool set.
  func warmUpLUT() throws -> MonitorLUT {
    let identity = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
    return try MonitorLUT(device: device, cube: CubeLUT(text: identity, fallbackTitle: "MonitorKit warm-up"))
  }
}

extension MonitorPass {
  /// The tool-set variant and colour key `rebuild` derives for `key`, without a pass.
  static func specialization(for k: Key) -> (variant: MonitorEngine.Variant, color: MonitorEngine.ColorKey) {
    let s = k.state
    let layout = MonitorLayout(
      frame: k.geometry, state: s, viewportWidth: k.viewport.width, viewportHeight: k.viewport.height)
    let showGuides = s.guides.isShown(on: layout) && !s.clean
    let raster =
      showGuides ? GuideRaster(layout: layout, guides: s.guides, pixelsPerPoint: k.viewport.pixelsPerPoint) : GuideRaster()
    let guides = GuideParameters(raster, outline: max(1, k.viewport.pixelsPerPoint.rounded()))
    let monitorLUT = s.monitorLUT && k.monitorLUT != nil
    let stageHasLUT =
      (s.falseColor.stage != .source && k.burnInLUT != nil) || (s.falseColor.stage == .monitor && monitorLUT)
    let falseColor = resolveFalseColor(
      s, signal: k.signal, full: FalseColorTable.usesFullRangeARRI(signal: k.signal, layout: k.layout),
      stageHasLUT: stageHasLUT, processed: k.processed)
    let color = MonitorColorPipeline(
      output: k.output, signal: k.signal, transform: s.displayTransform,
      monitorStageHasLUT: s.pictureHasLUT(burnInLUT: k.burnInLUT != nil, monitorLUT: k.monitorLUT != nil))
    let frameParameters = FrameParameters(
      shape: SIMD4(k.layout.shaderKind, UInt32(k.width), UInt32(k.height), 0), options: SIMD4(0, 0, 0, 0),
      matrix: .zero, levels: .zero, codeScale: .zero)
    let p = makeParameters(
      s, key: k, layout: layout, guides: guides, matte: (raster.matteRect, raster.matteOpacity),
      falseColor: falseColor, frameParameters: frameParameters, color: color)
    return (variant(p, state: s, layout: layout), colorKey(color))
  }
}
