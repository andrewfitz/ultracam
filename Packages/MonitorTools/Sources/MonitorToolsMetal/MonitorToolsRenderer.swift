@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Metal
import MonitorToolsCore

/// Today's monitor tools (zebra, false color, focus peaking, waveform and RGB
/// parade) behind the renderer seam. One instance per surface: it owns the
/// source-resolution peaking mask and caches the per-configuration parameters,
/// so steady-state encoding allocates nothing.
public final class MonitorToolsRenderer: MonitorPictureRenderer, MonitorScopeRenderer,
  @unchecked Sendable
{
  public static let scopeWidth = 768
  public static let scopeHeight = 256
  private let runtime: MonitorRuntime
  private var mask: MTLTexture?
  private var emptyMask: MTLTexture?
  private var preparedKey: Key?
  private var prepared = Prepared()
  private var scopeKey: ScopeKey?
  private var scopeParameters = KernelParameters()
  public private(set) var status: [String] = []

  public init(runtime: MonitorRuntime) { self.runtime = runtime }

  public func invalidate() {
    guard let metal = runtime.builtContext else { return }
    // Residency ends once the GPU is done with any frame already using these.
    let retiring = [mask, emptyMask].compactMap { $0 }
    mask = nil
    emptyMask = nil
    guard !retiring.isEmpty else { return }
    let context = metal.acquire()
    for texture in retiring {
      context.retain(texture)
      context.retireResident(texture)
    }
    metal.commit(context, drawable: nil, completion: nil, kind: 0)
  }

  // MARK: Picture

  public func encode(
    frame: MonitorGPUFrame, state: MonitorRenderState, target: MTLTexture,
    viewport: MonitorViewport, into context: MonitorEncodeContext
  ) throws {
    let metal = try runtime.metal()
    let key = Key(frame: frame, state: state, viewport: viewport)
    if key != preparedKey {
      prepared = Self.prepare(frame: frame, state: state, viewport: viewport)
      preparedKey = key
      status = prepared.status
    }
    frame.retainResources(in: context)
    context.retain(target)
    let source = frame.source
    let picture = frame.planes(for: state.configuration.pictureStage)
    let focusMask: MTLTexture
    if prepared.focus {
      focusMask = try ensureMask(&mask, width: source.width, height: source.height, metal, context)
    } else {
      focusMask = try ensureMask(&emptyMask, width: 1, height: 1, metal, context)
    }
    guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorPreviewError.gpuFailed
    }
    let table = context.argumentTable
    encoder.setArgumentTable(table)
    let sourceAddress = context.uniform(prepared.s)
    if prepared.focus {
      // One mask serves every in-flight frame of this surface. Consumer
      // barrier: this frame's mask write waits for earlier dispatches on the
      // queue (the previous frame's compose, which reads the mask). At display
      // rate that work has long finished, so the wait is normally free.
      encoder.barrier(afterQueueStages: .dispatch, beforeStages: .dispatch, visibilityOptions: [])
      encoder.setComputePipelineState(metal.focus)
      table.setTexture(source.plane0.gpuResourceID, index: 0)
      table.setTexture(source.plane1.gpuResourceID, index: 1)
      table.setTexture(focusMask.gpuResourceID, index: 2)
      table.setAddress(sourceAddress, index: 0)
      encoder.dispatchThreads(
        threadsPerGrid: MTLSize(width: source.width, height: source.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
      encoder.barrier(
        afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
    }
    encoder.setComputePipelineState(metal.compose)
    table.setTexture(picture.plane0.gpuResourceID, index: 0)
    table.setTexture(picture.plane1.gpuResourceID, index: 1)
    table.setTexture(source.plane0.gpuResourceID, index: 2)
    table.setTexture(source.plane1.gpuResourceID, index: 3)
    table.setTexture(focusMask.gpuResourceID, index: 4)
    table.setTexture(target.gpuResourceID, index: 5)
    table.setAddress(context.uniform(prepared.p), index: 0)
    table.setAddress(sourceAddress, index: 1)
    encoder.dispatchThreads(
      threadsPerGrid: MTLSize(width: viewport.width, height: viewport.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
  }

  /// Black across `target`, for a surface with no picture.
  public func encodeClear(target: MTLTexture, into context: MonitorEncodeContext) throws {
    let metal = try runtime.metal()
    guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorPreviewError.gpuFailed
    }
    context.retain(target)
    encoder.setArgumentTable(context.argumentTable)
    encoder.setComputePipelineState(metal.clear)
    context.argumentTable.setTexture(target.gpuResourceID, index: 0)
    encoder.dispatchThreads(
      threadsPerGrid: MTLSize(width: target.width, height: target.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
  }

  /// Owned GPU copies of `frame`'s planes, for freeze. The copy is encoded
  /// into `context`; the result is valid for any work encoded after it on the
  /// queue. On failure the encoder is still ended, the copies made so far
  /// leave residency, and the caller abandons `context`.
  public func encodeFreezeCopy(of frame: MonitorGPUFrame, into context: MonitorEncodeContext)
    throws -> MonitorGPUFrame
  {
    let metal = try runtime.metal()
    frame.retainResources(in: context)
    guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorPreviewError.gpuFailed
    }
    defer { encoder.endEncoding() }
    var made: [MTLTexture] = []
    func copy(_ texture: MTLTexture) throws -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height,
        mipmapped: false)
      descriptor.usage = [.shaderRead]
      descriptor.storageMode = .private
      guard let owned = metal.device.makeTexture(descriptor: descriptor) else {
        throw MonitorPreviewError.allocationFailed
      }
      metal.makeResident(owned)
      made.append(owned)
      encoder.copy(sourceTexture: texture, destinationTexture: owned)
      return owned
    }
    func copy(_ planes: MonitorPlanes) throws -> MonitorPlanes {
      let first = try copy(planes.plane0)
      let second = planes.isBiplanar ? try copy(planes.plane1) : first
      return MonitorPlanes(
        format: planes.format, width: planes.width, height: planes.height,
        pixelFormat: planes.pixelFormat, plane0: first, plane1: second)
    }
    do {
      let source = try copy(frame.source)
      let output: MonitorPlanes? =
        frame.output.map { $0.isSameImage(as: frame.source) } == true
        ? source : try frame.output.map { try copy($0) }
      // Producer barrier: later passes on the queue (pictures, scopes) wait for these copies.
      encoder.barrier(
        afterStages: .blit, beforeQueueStages: [.dispatch, .blit], visibilityOptions: .device)
      return MonitorGPUFrame(copying: frame, source: source, output: output)
    } catch {
      // Nothing was committed; the abandoned context may still name these.
      for texture in made {
        context.retain(texture)
        context.retireResident(texture)
      }
      throw error
    }
  }

  private func ensureMask(
    _ slot: inout MTLTexture?, width: Int, height: Int, _ metal: MonitorMetalContext,
    _ context: MonitorEncodeContext
  ) throws -> MTLTexture {
    if let existing = slot, existing.width == width, existing.height == height { return existing }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard let texture = metal.device.makeTexture(descriptor: descriptor) else {
      throw MonitorPreviewError.allocationFailed
    }
    metal.makeResident(texture)
    if let old = slot {
      context.retain(old)
      context.retireResident(old)
    }
    slot = texture
    context.retain(texture)
    return texture
  }

  // MARK: Scopes

  public func wantsScopes(_ state: MonitorRenderState) -> Bool {
    state.configuration.toolsEnabled && state.configuration.scopes.enabled
  }

  /// Every pixel of the scope stage, one pass, straight into `target`
  /// (`scopeWidth` × `scopeHeight`).
  public func encodeScopes(
    frame: MonitorGPUFrame, state: MonitorRenderState, target: MTLTexture,
    into context: MonitorEncodeContext
  ) throws {
    let metal = try runtime.metal()
    let config = state.configuration
    let planes = frame.planes(for: config.scopeStage)
    let key = ScopeKey(
      configuration: config.scopes, stage: config.scopeStage,
      signal: frame.signal(for: config.scopeStage, configuration: config),
      format: planes.format, width: planes.width, height: planes.height)
    if key != scopeKey {
      var q = KernelParameters()
      q.width = UInt32(planes.width)
      q.height = UInt32(planes.height)
      q.format = planes.format
      Self.apply(key.signal ?? Self.fallbackSignal(planes), to: &q)
      if config.scopeStage == .source, let range = config.sourceCodeRange {
        q.coefficients.w = range == .full ? 1 : 0
      }
      q.scopeMode = config.scopes.mode == .lumaWaveform ? 1 : 0
      q.gain = Float(config.scopes.gain)
      q.scopeSamplingStride = 1
      q.scopeSamplingPhase = 0
      q.scopeWidth = UInt32(Self.scopeWidth)
      q.scopeHeight = UInt32(Self.scopeHeight)
      q.flags = config.scopes.graticule ? MonitorKernelFlag.scopeGraticule : 0
      scopeParameters = q
      scopeKey = key
    }
    frame.retainResources(in: context)
    context.retain(target)
    guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorPreviewError.gpuFailed
    }
    let table = context.argumentTable
    encoder.setArgumentTable(table)
    encoder.setComputePipelineState(metal.scopes)
    table.setTexture(planes.plane0.gpuResourceID, index: 0)
    table.setTexture(planes.plane1.gpuResourceID, index: 1)
    table.setTexture(target.gpuResourceID, index: 2)
    table.setAddress(context.uniform(scopeParameters), index: 0)
    let columns = scopeParameters.scopeMode == 1 ? Self.scopeWidth : Self.scopeWidth / 3
    encoder.dispatchThreadgroups(
      threadgroupsPerGrid: MTLSize(width: columns, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: Self.scopeHeight, height: 1, depth: 1))
    encoder.endEncoding()
  }

  // MARK: Qualification (ported unchanged from the composited monitor)

  private struct ScopeKey: Equatable {
    let configuration: MonitorScopeSettings
    let stage: MonitorStage
    let signal: MonitorFrameSignal?
    let format: UInt32
    let width: Int
    let height: Int
  }

  private struct Key: Equatable {
    let state: MonitorRenderState
    let viewport: MonitorViewport
    let target: MonitorTargetID
    let sourceSignal: MonitorFrameSignal?
    let outputSignal: MonitorFrameSignal?
    let sourceGeometry: MonitorGeometry
    let outputGeometry: MonitorGeometry?
    let correspondence: MonitorCorrespondence?
    let sourceShape: SIMD3<Int>
    let outputShape: SIMD3<Int>?
    let outputIsSource: Bool
    init(frame: MonitorGPUFrame, state: MonitorRenderState, viewport: MonitorViewport) {
      self.state = state
      self.viewport = viewport
      target = frame.stamp.target
      sourceSignal = frame.sourceSignal
      outputSignal = frame.outputSignal
      sourceGeometry = frame.sourceGeometry
      outputGeometry = frame.outputGeometry
      correspondence = frame.correspondence
      sourceShape = SIMD3(Int(frame.source.format), frame.source.width, frame.source.height)
      outputShape = frame.output.map { SIMD3(Int($0.format), $0.width, $0.height) }
      outputIsSource = frame.output.map { $0.isSameImage(as: frame.source) } ?? true
    }
  }

  private struct Prepared {
    var p = KernelParameters()
    var s = KernelParameters()
    var focus = false
    var status: [String] = []
  }

  static func fallbackSignal(_ planes: MonitorPlanes) -> MonitorFrameSignal {
    let full = [
      kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
    ].contains(planes.pixelFormat)
    return MonitorFrameSignal(range: full ? .full : .legal, matrix: .bt709, transfer: "Unknown")
  }

  private static func apply(_ signal: MonitorFrameSignal, to params: inout KernelParameters) {
    let c = signal.matrix.coefficients
    params.coefficients = SIMD4(Float(c.r), Float(c.g), Float(c.b), signal.range == .full ? 1 : 0)
  }

  private static func prepare(
    frame: MonitorGPUFrame, state: MonitorRenderState, viewport: MonitorViewport
  ) -> Prepared {
    let config = state.configuration
    var result = Prepared()
    let source = frame.source
    let picture = frame.planes(for: config.pictureStage)
    var statuses: [String] = []
    let pictureSignal: MonitorFrameSignal
    if let signal = frame.signal(for: config.pictureStage, configuration: config) {
      pictureSignal = signal
    } else {
      pictureSignal = fallbackSignal(picture)
      statuses.append("Range / transfer interpretation unavailable; tools disabled")
    }
    var p = KernelParameters()
    p.width = UInt32(picture.width)
    p.height = UInt32(picture.height)
    p.format = picture.format
    var s = KernelParameters()
    s.width = UInt32(source.width)
    s.height = UInt32(source.height)
    s.format = source.format
    apply(pictureSignal, to: &p)
    apply(frame.sourceSignal ?? fallbackSignal(source), to: &s)
    if let range = config.sourceCodeRange {
      s.coefficients.w = range == .full ? 1 : 0
      if config.pictureStage == .source { p.coefficients.w = s.coefficients.w }
    }
    p.outWidth = UInt32(max(1, viewport.width))
    p.outHeight = UInt32(max(1, viewport.height))
    p.originX = Float(viewport.x)
    p.originY = Float(viewport.y)
    p.threshold = Float(config.zebra.thresholdIRE)
    p.widthIRE = Float(config.zebra.widthIRE)
    p.opacity = Float(config.zebra.opacity)
    var flags: UInt32 = config.effectiveZebraEnabled ? MonitorKernelFlag.zebra : 0
    if config.zebra.mode == .band { flags |= MonitorKernelFlag.zebraBand }
    let correspondenceMapping = frame.correspondence.map {
      SIMD4<Float>(Float($0.scaleX), Float($0.scaleY), Float($0.offsetX), Float($0.offsetY))
    }
    let mappingValid: Bool = {
      guard let m = correspondenceMapping,
        [m.x, m.y, m.z, m.w].allSatisfy({ $0.isFinite }),
        abs(m.x) >= Float.leastNormalMagnitude, abs(m.y) >= Float.leastNormalMagnitude
      else { return false }
      // The shader uses Float inverse coordinates and footprints. A finite
      // Double declaration alone does not guarantee these operations are safe.
      let extent = SIMD2<Float>(Float(p.width), Float(p.height))
      let scale = SIMD2<Float>(m.x, m.y), offset = SIMD2<Float>(m.z, m.w)
      let low = -offset / scale, high = (extent - offset) / scale, span = extent / scale
      return [low.x, low.y, high.x, high.y, span.x, span.y].allSatisfy { $0.isFinite }
    }()
    let geometryValid =
      mappingValid
      && frame.correspondence?.map(MonitorPoint(x: 0, y: 0)) != nil && frame.sourceGeometry.isValid
      && frame.sourceGeometry.width == source.width
      && frame.sourceGeometry.height == source.height
      && frame.sourceGeometry.orientation == .upright
      && (frame.outputGeometry?.orientation ?? .upright) == .upright
    let isProgram = frame.stamp.target.rawValue == "program"
    let focusAllowed =
      geometryValid && frame.sourceSignal != nil && config.focus.enabled
      && frame.correspondence != nil && !isProgram && config.toolsEnabled
    if focusAllowed {
      flags |= MonitorKernelFlag.focus
    } else if config.focus.enabled && config.toolsEnabled {
      statuses.append("Focus unavailable: source correspondence is unqualified")
    }
    s.sourceLogRescaled = config.sourceLogMapping == .fullRescaledToLegal10Bit ? 1 : 0
    let arriProfile = config.falseColor.profileID.flatMap(ARRIFalseColorProfile.init(rawValue:))
    let sourceTransfer = frame.sourceSignal?.transfer.lowercased() ?? ""
    let sourceFalseColorQualified =
      geometryValid && (s.sourceLogRescaled == 0 || s.coefficients.w == 0)
      && frame.correspondence != nil && !isProgram && config.toolsEnabled
    let literalARRIAllowed =
      sourceFalseColorQualified && config.falseColor.mode == .arri && arriProfile != nil
      && frame.sourceSignal?.profileID == arriProfile?.rawValue
      && config.falseColor.exposureIndex == 800
    let sonyGamut = SonyARRIStyleFalseColor.gamut(forSourceProfileID: config.sourceProfileID)
    let sonyAllowed =
      sourceFalseColorQualified && config.falseColor.mode == .arri
      && config.falseColor.profileID == SonyARRIStyleFalseColor.profileID
      && sonyGamut != nil && frame.sourceSignal?.profileID == config.sourceProfileID
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3"))
    let sonyPatternAllowed =
      sourceFalseColorQualified && config.falseColor.mode == .sonySLog3
      && config.falseColor.profileID == SonySLog3FalseColor.profileID
      && config.falseColor.specificationVersion == SonySLog3FalseColor.specificationVersion
      && SonySLog3FalseColor.supports(sourceProfileID: config.sourceProfileID)
      && frame.sourceSignal?.profileID == config.sourceProfileID
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3"))
    let elZoneAllowed =
      sourceFalseColorQualified && config.falseColor.mode == .elZone
      && config.falseColor.profileID == ELZoneProfile.profileID
      && config.falseColor.specificationVersion == ELZoneProfile.specificationVersion
      && ELZoneProfile.supports(sourceProfileID: config.sourceProfileID)
      && frame.sourceSignal?.profileID == config.sourceProfileID
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3"))
    let arriAllowed = literalARRIAllowed || sonyAllowed || sonyPatternAllowed || elZoneAllowed
    let pictureGeometry = frame.geometry(for: config.pictureStage)
    let pictureGeometrySupported =
      pictureGeometry.isValid && (0.0625...16).contains(pictureGeometry.pixelAspectRatio)
      && pictureGeometry.orientation == .upright
      && pictureGeometry.width == picture.width
      && pictureGeometry.height == picture.height
    let transfer = pictureSignal.transfer.lowercased()
    let knownLogProfile =
      frame.sourceSignal?.profileID.map {
        [
          "sony-slog3-sgamut3cine", "sony-slog3-sgamut3", ARRIFalseColorProfile.logC3EI800.rawValue,
          ARRIFalseColorProfile.alexa35LogC4EI800.rawValue,
        ].contains($0)
      } ?? false
    let pictureIsSource =
      config.pictureStage == .source || frame.output == nil
      || frame.output!.isSameImage(as: frame.source)
    let sourceCodeView =
      pictureIsSource && knownLogProfile
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3")
        || sourceTransfer.contains("logc"))
    let compositionAllowed =
      pictureGeometrySupported
      && (arriAllowed || sourceCodeView || transfer.contains("709") || transfer.contains("srgb"))
    if sourceCodeView && !arriAllowed {
      statuses.append(
        "Source Log code-value view; no viewing transform or exposure calibration applied")
    }
    if !pictureGeometrySupported {
      statuses.append("Monitor tools unavailable: unsupported picture geometry")
    } else if !compositionAllowed {
      statuses.append(
        "Monitor tools unavailable: unsupported SDR transfer interpretation (\(pictureSignal.transfer)); showing code values"
      )
    }
    if elZoneAllowed {
      flags |= MonitorKernelFlag.elZone
      if ELZoneProfile.gamut(forSourceProfileID: config.sourceProfileID) == .sGamut3 {
        flags |= MonitorKernelFlag.sonySGamut3
      }
      p.referenceOffsetStops = Float(config.falseColor.referenceOffsetStops)
    } else if sonyPatternAllowed {
      flags |= MonitorKernelFlag.sonySLog3
    } else if sonyAllowed {
      // Sony source interpretation and the fixed LogC3 reference are independent
      // of any camera exposure-index setting and of the processed output look.
      flags |= MonitorKernelFlag.logC3 | MonitorKernelFlag.sonyARRIReference
      if sonyGamut == .sGamut3 { flags |= MonitorKernelFlag.sonySGamut3 }
    } else if literalARRIAllowed {
      flags |= arriProfile == .logC3EI800 ? MonitorKernelFlag.logC3 : MonitorKernelFlag.logC4
    } else if config.falseColor.mode != .off && config.toolsEnabled {
      statuses.append(
        "False color unavailable: source profile, signal, or correspondence is unqualified")
    }
    // Source pictures already use source pixel coordinates. Applying the
    // source-to-output transform here shifts source masks/classification and
    // stretches clamped border samples into lines when output is downscaled.
    if !pictureIsSource, geometryValid, let mapping = correspondenceMapping {
      p.mapping = mapping
    }
    p.focusOpacity = Float(config.focus.opacity)
    switch config.focus.color {
    case .red: p.peak = SIMD4(1, 0, 0, 1)
    case .green: p.peak = SIMD4(0, 1, 0, 1)
    case .blue: p.peak = SIMD4(0, 0, 1, 1)
    case .yellow: p.peak = SIMD4(1, 1, 0, 1)
    case .white: p.peak = SIMD4(1, 1, 1, 1)
    }
    s.focusThreshold = Float(0.02 + (1 - min(1, max(0, config.focus.sensitivity))) * 0.3)
    s.noise = Float(config.focus.noiseRejection)
    // The aperture shown: the stage's clean aperture unless the caller picked one.
    let aperture =
      state.aperture
      ?? (pictureGeometrySupported
        ? pictureGeometry.cleanAperture
        : MonitorRect(width: Double(picture.width), height: Double(picture.height)))
    p.aperture = SIMD4(
      Float(aperture.x), Float(aperture.y), Float(aperture.width), Float(aperture.height))
    // Clean view and unqualified pictures show the plain picture.
    let toolsDrawn = compositionAllowed && !state.clean && config.toolsEnabled
      && frame.signal(for: config.pictureStage, configuration: config) != nil
    p.flags = toolsDrawn ? flags : 0
    result.focus = toolsDrawn && (flags & MonitorKernelFlag.focus) != 0
    result.p = p
    result.s = s
    result.status = state.clean ? [] : statuses
    return result
  }
}
