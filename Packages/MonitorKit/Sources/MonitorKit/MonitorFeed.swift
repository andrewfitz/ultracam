import Metal
import MonitorKitCore

/// One per video feed: the feed's LUTs and its once-per-frame analysis, shared by
/// every surface that shows the feed.
///
/// Confined: use from one thread at a time (not `Sendable`; move it with
/// `sending` or keep it on the host's render actor). No internal locks.
///
/// Classic command buffers should retain their references (the default). With
/// unretained-reference command buffers the host keeps its `MonitorLUT`s alive
/// until the GPU is done; a focus mask replaced on a size change is kept for
/// `retiredFrames` more analyses.
///
/// Metal 4 (`MonitorSubmission` overloads): the feed makes its mask, Freeze
/// planes and LUT textures resident in `engine.residency` and releases replaced
/// ones (and, on deinit, its own) only once their last submission completed.
public final class MonitorFeed {
  public let engine: MonitorEngine
  /// Output stage: what the real output carries. A host that burns the LUT into
  /// its output uses this same `MonitorLUT` with `mk_applyLUT`, so the preview matches.
  public var burnInLUT: MonitorLUT?
  /// Monitor stage only, stacked on top of `burnInLUT`. Never reaches output.
  public var monitorLUT: MonitorLUT?

  /// Edge confidence at source resolution (`r8Unorm`). Recreated only when the
  /// frame size changes.
  public private(set) var focusMask: MTLTexture?

  /// What the mask was computed from: the frame (by `MonitorFrame.id`), the LUTs
  /// applied before edge detection (none for the source stage) and every uniform
  /// of the analysis (frame decode, thresholds, LUT parameters).
  struct MaskKey {
    var frame: UInt64
    var width: Int
    var height: Int
    var layout: PixelLayout
    var burn: MonitorLUT?
    var monitor: MonitorLUT?
    var uniforms: AnalysisUniforms

    func matches(_ f: MonitorFrame) -> Bool {
      frame == f.id && width == f.width && height == f.height && layout == f.layout
    }
  }
  var maskKey: MaskKey?
  /// Analyses dispatched: an analysis the mask already holds (the same frame and
  /// settings, e.g. a frozen frame every display tick) dispatches nothing.
  public private(set) var analysisCount = 0
  /// Metal 4: the last submissions that wrote and read the mask (0: none), so a
  /// barrier is encoded only while one of them may still run.
  var maskLastWrite: UInt64 = 0
  var maskLastRead: UInt64 = 0
  private var focusPipeline: MTLComputePipelineState?
  private var focusPipelineKey = MonitorEngine.FocusKey(layout: 0, burnInLUT: false, monitorLUT: false)

  /// Analyses a replaced mask stays referenced for: covers the frames a host keeps in flight.
  public static let retiredFrames = 3
  /// Replaced or released masks, each with the analyses since it was retired. At
  /// most one is retired per analysis and each leaves after `retiredFrames`, so
  /// `retiredFrames` slots always suffice.
  private var retired = InlineArray<3, MTLTexture?>(repeating: nil)
  private var retiredAges = InlineArray<3, Int>(repeating: 0)

  init(engine: MonitorEngine) { self.engine = engine }

  deinit {
    // Metal 4 retains nothing: what the GPU may still read lives until its
    // submission completes. Each is nil unless a Metal 4 encode used it.
    let residency = engine.residency
    // A frozen frame the host still holds is made resident again where it is drawn.
    frozenPlanes?.markReleased()
    retireResident(&resident.mask)
    retireResident(&resident.plane0)
    retireResident(&resident.plane1)
    if let lut = resident.burn { residency.retire(lut, resident: lut.texture) }
    if let lut = resident.monitor { residency.retire(lut, resident: lut.texture) }
    ring.retire(to: residency)
    residency.retire(metal4?.table, resident: nil)
  }

  /// Once per frame, before any pass that shows peaking. Analyses `focus.stage`:
  /// the source luma, or the luma after the burn-in LUT (output) and the monitor
  /// LUT too (monitor). Encodes one compute pass; never commits. With
  /// `focus.enabled` false (peaking is off on every surface of the feed) it encodes
  /// nothing and releases the mask, an r8 texture at source size (8.3 MB at 4K),
  /// once the frames in flight are done with it; turning peaking back on makes a
  /// new one. When the mask already holds this frame's analysis with these
  /// settings it encodes nothing either (a frozen frame, or a display refreshing
  /// faster than the source). A processed frame (`MonitorFrame.isProcessed`) is
  /// treated like peaking off: peaking needs the camera's own signal.
  public func analyze(_ frame: MonitorFrame, focus: FocusSettings, into commandBuffer: MTLCommandBuffer)
    throws
  {
    ageRetired()
    guard focus.enabled, !frame.isProcessed else { return releaseFocusMask() }
    let a = try prepareAnalysis(frame, focus: focus)
    if holds(frame, a) { return }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a compute encoder for focus analysis.")
    }
    encoder.setComputePipelineState(a.pipeline)
    encoder.setTexture(frame.packed ?? engine.emptyPacked, index: 0)
    encoder.setTexture(frame.luma ?? engine.emptyFloat, index: 1)
    encoder.setTexture(frame.chroma ?? engine.emptyFloat, index: 2)
    encoder.setTexture(a.mask, index: 3)
    encoder.setTexture(a.burn?.texture ?? engine.emptyLUT, index: 4)
    encoder.setTexture(a.monitor?.texture ?? engine.emptyLUT, index: 5)
    var u = a.uniforms
    encoder.setBytes(&u.frame, length: MemoryLayout<FrameParameters>.stride, index: 0)
    encoder.setBytes(&u.thresholds, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    encoder.setBytes(&u.burn, length: MemoryLayout<LUTParameters>.stride, index: 2)
    encoder.setBytes(&u.monitor, length: MemoryLayout<LUTParameters>.stride, index: 3)
    let grid = Self.focusDispatch(frame, a.pipeline)
    encoder.dispatchThreadgroups(grid.groups, threadsPerThreadgroup: grid.threads)
    encoder.endEncoding()
    finishAnalysis(frame, a)
  }

  /// What one analysis reads besides the frame.
  struct Analysis {
    var mask: MTLTexture
    var pipeline: MTLComputePipelineState
    var burn: MonitorLUT?
    var monitor: MonitorLUT?
    var uniforms: AnalysisUniforms
  }

  /// `mk_focusMask`'s buffers 0–3.
  struct AnalysisUniforms: Equatable {
    var frame: FrameParameters
    var thresholds: SIMD2<Float>
    var burn: LUTParameters
    var monitor: LUTParameters
  }

  /// `MK_FOCUS_ROWS`: mask rows per thread of `mk_focusMask` (a mismatch would
  /// leave rows unwritten, which the W1 mask comparison test catches).
  static let focusRows = 16
  /// Rows of a focus threadgroup (fewer if the pipeline cannot take that many threads).
  static let focusGroupRows = 4

  /// Threadgroups and their size for one analysis of `frame`. The kernel takes its
  /// left and right neighbours from the adjacent SIMD lanes, so a threadgroup row
  /// must be exactly one SIMD-group (`threadExecutionWidth` lanes, whose outer two
  /// only read halo); each thread covers `focusRows` rows.
  static func focusDispatch(_ frame: MonitorFrame, _ pipeline: MTLComputePipelineState)
    -> (groups: MTLSize, threads: MTLSize)
  {
    let lanes = pipeline.threadExecutionWidth, columns = lanes - 2
    let groupRows = max(1, min(focusGroupRows, pipeline.maxTotalThreadsPerThreadgroup / lanes))
    let rows = (frame.height + focusRows - 1) / focusRows
    return (
      MTLSize(width: (frame.width + columns - 1) / columns, height: (rows + groupRows - 1) / groupRows, depth: 1),
      MTLSize(width: lanes, height: groupRows, depth: 1)
    )
  }

  /// The mask (made or reused at the frame's size), pipeline and inputs of an analysis.
  func prepareAnalysis(_ frame: MonitorFrame, focus: FocusSettings) throws -> Analysis {
    let mask: MTLTexture
    if let existing = focusMask, existing.width == frame.width, existing.height == frame.height {
      mask = existing
    } else {
      retire(focusMask)
      focusMask = nil
      maskKey = nil
      mask = try engine.makeTexture(
        .r8Unorm, width: frame.width, height: frame.height, usage: [.shaderRead, .shaderWrite],
        label: "MonitorKit focus mask")
      focusMask = mask
    }
    let burn = focus.stage != .source ? burnInLUT : nil
    let monitor = focus.stage == .monitor ? monitorLUT : nil
    let key = MonitorEngine.FocusKey(layout: frame.layout.shaderKind, burnInLUT: burn != nil, monitorLUT: monitor != nil)
    if focusPipeline == nil || focusPipelineKey != key {
      focusPipeline = try engine.focusPipeline(key)
      focusPipelineKey = key
    }
    guard let pipeline = focusPipeline else { throw MonitorKitError.gpu("No focus-analysis pipeline.") }
    let uniforms = AnalysisUniforms(
      frame: frame.parameters,
      thresholds: SIMD2(Float(focus.edgeThreshold), Float(min(1, max(0, focus.noiseRejection)))),
      burn: burn?.parameters ?? .disabled, monitor: monitor?.parameters ?? .disabled)
    return Analysis(mask: mask, pipeline: pipeline, burn: burn, monitor: monitor, uniforms: uniforms)
  }

  func finishAnalysis(_ frame: MonitorFrame, _ a: Analysis) {
    maskKey = MaskKey(
      frame: frame.id, width: frame.width, height: frame.height, layout: frame.layout, burn: a.burn,
      monitor: a.monitor, uniforms: a.uniforms)
    analysisCount += 1
  }

  /// Whether the mask already holds analysis `a` of `frame`.
  func holds(_ frame: MonitorFrame, _ a: Analysis) -> Bool {
    guard let key = maskKey, focusMask === a.mask, key.matches(frame) else { return false }
    return key.burn === a.burn && key.monitor === a.monitor && key.uniforms == a.uniforms
  }

  /// Whether `focusMask` was analysed from `frame` (on any stage).
  public func hasFocusMask(for frame: MonitorFrame) -> Bool {
    focusMask != nil && maskKey?.matches(frame) == true
  }

  /// Whether `focusMask` was analysed from `frame` on the stage a surface shows:
  /// the LUTs it applied are the ones that surface's stage has.
  func hasFocusMask(for frame: MonitorFrame, stage: SignalStage, monitorLUTEnabled: Bool) -> Bool {
    guard focusMask != nil, let key = maskKey, key.matches(frame) else { return false }
    let burn = stage != .source ? burnInLUT : nil
    let monitor = stage == .monitor && monitorLUTEnabled ? monitorLUT : nil
    return key.burn === burn && key.monitor === monitor
  }

  /// Marks the mask stale, e.g. when the host stops analysing.
  public func invalidateFocusMask() { maskKey = nil }

  /// Whether the picture a surface showing this feed with `state` draws came out
  /// of a LUT (`state.pictureHasLUT`: the burn-in LUT unless the picture shows the
  /// source, the monitor LUT too when it shows the monitor stage and
  /// `state.monitorLUT`), which makes it Rec.709 SDR: the `monitorStageHasLUT`
  /// argument of `MonitorOutputColor.layer(for:…)` and `MonitorEngine.prepare(…)`.
  public func monitorStageHasLUT(for state: MonitorState) -> Bool {
    state.pictureHasLUT(burnInLUT: burnInLUT != nil, monitorLUT: monitorLUT != nil)
  }

  /// Peaking is off: the mask goes (kept for `retiredFrames` more analyses on the
  /// classic path; on Metal 4 until its last submission completes).
  func releaseFocusMask() {
    maskKey = nil
    guard let mask = focusMask else { return }
    retire(mask)
    focusMask = nil
    if resident.mask != nil { retireResident(&resident.mask) }
  }

  /// Bytes of GPU memory this feed owns: the focus mask while peaking is on, the
  /// Freeze planes while frozen (unless kept) and, once it encodes on Metal 4, its
  /// uniform ring (`framesInFlight` KB). LUTs are counted by their own
  /// `MonitorLUT`, which may be shared. A replaced or released mask still held for
  /// the frames in flight is not counted.
  public var persistentMemoryBytes: Int {
    (focusMask?.allocatedSize ?? 0) + (freezePlanes.0?.allocatedSize ?? 0) + (freezePlanes.1?.allocatedSize ?? 0)
      + (ring.buffer?.allocatedSize ?? 0)
  }

  // MARK: - Freeze

  /// The frame `freeze` captured, until `unfreeze`.
  public private(set) var frozenFrame: MonitorFrame?
  /// Owned copies of the planes, reused while the size and formats stay the same.
  var freezePlanes: (MTLTexture?, MTLTexture?) = (nil, nil)
  /// Marks the frames frozen into the current planes; released with them.
  private var frozenPlanes: FrozenPlanes?

  /// Copies `frame`'s planes into textures this feed owns and returns the copy,
  /// which works wherever a live frame does: passes, `analyze`, scopes. It is the
  /// only frame copy MonitorKit makes, and only when asked. One compute pass is
  /// encoded into `commandBuffer` (no blit, no commit). The textures are created
  /// once per size and format and reused by later freezes; the source can be
  /// reused once `commandBuffer` completes. Repeated freezes of one size allocate
  /// nothing. The copy has a fresh `id`, kept while it is frozen.
  ///
  /// A later freeze overwrites the same textures, so encode it after (on the same
  /// queue) every command buffer that still reads the previous frozen frame.
  /// Freezing the frozen frame itself returns it unchanged.
  public func freeze(_ frame: MonitorFrame, into commandBuffer: MTLCommandBuffer) throws -> MonitorFrame {
    if let frozenFrame, let owned = freezePlanes.0, frame.primaryTexture === owned { return frozenFrame }
    let f = try prepareFreeze(frame)
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a compute encoder for Freeze.")
    }
    encoder.label = "MonitorKit freeze"
    try copy(f.sources.0, into: f.planes.0, integer: f.integer.0, encoder)
    if let b = f.planes.1 { try copy(f.sources.1, into: b, integer: f.integer.1, encoder) }
    encoder.endEncoding()
    return try finishFreeze(frame, f)
  }

  /// The owned planes of one freeze and what is copied into them.
  struct Freeze {
    var planes: (MTLTexture, MTLTexture?)
    var sources: (MTLTexture?, MTLTexture?)
    var integer: (Bool, Bool)
    /// Whether an existing plane is overwritten (so earlier readers must finish first).
    var reused: Bool
  }

  func prepareFreeze(_ frame: MonitorFrame) throws -> Freeze {
    let (first, second) = Self.planes(of: frame)
    if second == nil { replaceFreezePlane(1, with: nil) }
    let before = (freezePlanes.0, freezePlanes.1)
    let a = try plane(0, first, source: frame.packed ?? frame.luma)
    let b = try second.map { try plane(1, $0, source: frame.chroma) }
    let reused = (before.0 != nil && before.0 === a) || (b != nil && before.1 === b)
    return Freeze(
      planes: (a, b), sources: (frame.packed ?? frame.luma, frame.chroma),
      integer: (first.integer, second?.integer ?? false), reused: reused)
  }

  func finishFreeze(_ frame: MonitorFrame, _ f: Freeze) throws -> MonitorFrame {
    let packed = frame.packed != nil
    var frozen = try MonitorFrame(
      layout: frame.layout, width: frame.width, height: frame.height, packed: packed ? f.planes.0 : nil,
      luma: packed ? nil : f.planes.0, chroma: f.planes.1, signal: frame.signal,
      pixelAspectRatio: frame.declaredPixelAspectRatio, retained: (nil, nil), cleanAperture: frame.cleanAperture)
    frozen.isProcessed = frame.isProcessed
    if frozenPlanes == nil { frozenPlanes = FrozenPlanes() }
    frozen.frozenPlanes = frozenPlanes
    frozenFrame = frozen
    return frozen
  }

  /// Ends the freeze and releases the plane textures (a 4K frame is 22 MB as v210,
  /// 66 MB as rgba16Float), unless `keepingMemory`, for a host that toggles Freeze
  /// often: then they stay for the next freeze of the same size and format. The
  /// frozen `MonitorFrame` keeps them alive while the host holds it, so it can
  /// still be drawn: on Metal 4 the released planes leave the residency set once
  /// their last submission completes, and MonitorKit's encodes make a held
  /// frozen frame's planes resident again for the submission that reads them
  /// (`MonitorFrame.keepResidentIfReleased(in:)`).
  public func unfreeze(keepingMemory: Bool = false) {
    frozenFrame = nil
    if !keepingMemory {
      replaceFreezePlane(0, with: nil)
      replaceFreezePlane(1, with: nil)
      retireResident(&resident.plane0)
      retireResident(&resident.plane1)
    }
  }

  /// `unfreeze(keepingMemory: !releasingMemory)`.
  public func unfreeze(releasingMemory: Bool) { unfreeze(keepingMemory: !releasingMemory) }

  private func replaceFreezePlane(_ index: Int, with texture: MTLTexture?) {
    let existing = index == 0 ? freezePlanes.0 : freezePlanes.1
    guard existing !== texture else { return }
    if index == 0 { freezePlanes.0 = texture } else { freezePlanes.1 = texture }
    // Frames frozen into the old planes may outlive them here.
    frozenPlanes?.markReleased()
    frozenPlanes = nil
  }

  struct PlaneShape {
    var format: MTLPixelFormat
    var width: Int
    var height: Int
    var integer: Bool
  }

  /// The owned planes for `frame`: its layout's texture sizes. BGRA8 and BGR10A2
  /// are stored as RGBA8 and RGB10A2 (always shader-writable, and the frame reads
  /// them the same); a texel read and written back is the same value.
  static func planes(of frame: MonitorFrame) -> (PlaneShape, PlaneShape?) {
    let w = frame.width, h = frame.height
    switch frame.layout {
    case .v210: return (PlaneShape(format: .rgba32Uint, width: (w + 5) / 6, height: h, integer: true), nil)
    case .uyvy8, .yuyv8: return (PlaneShape(format: .rgba8Uint, width: (w + 1) / 2, height: h, integer: true), nil)
    case .biplanar(let s, let depth):
      let cw = s == .s444 ? w : (w + 1) / 2, ch = s == .s420 ? (h + 1) / 2 : h
      return (
        PlaneShape(format: depth == 8 ? .r8Unorm : .r16Unorm, width: w, height: h, integer: false),
        PlaneShape(format: depth == 8 ? .rg8Unorm : .rg16Unorm, width: cw, height: ch, integer: false)
      )
    case .rgb:
      var format = frame.luma?.pixelFormat ?? .rgba8Unorm
      if format == .bgra8Unorm { format = .rgba8Unorm }
      if format == .bgr10a2Unorm { format = .rgb10a2Unorm }
      return (PlaneShape(format: format, width: w, height: h, integer: false), nil)
    }
  }

  private func plane(_ index: Int, _ shape: PlaneShape, source: MTLTexture?) throws -> MTLTexture {
    let existing = index == 0 ? freezePlanes.0 : freezePlanes.1
    if let existing, existing.pixelFormat == shape.format, existing.width == shape.width,
      existing.height == shape.height
    {
      return existing
    }
    guard source != nil else { throw MonitorKitError.invalidFrame("the frame has no plane \(index) to freeze") }
    let t = try engine.makeTexture(
      shape.format, width: shape.width, height: shape.height, usage: [.shaderRead, .shaderWrite],
      label: "MonitorKit freeze plane \(index)")
    replaceFreezePlane(index, with: t)
    return t
  }

  private func copy(_ source: MTLTexture?, into copy: MTLTexture, integer: Bool, _ encoder: MTLComputeCommandEncoder)
    throws
  {
    guard let source else { throw MonitorKitError.invalidFrame("a frame plane is missing") }
    encoder.setComputePipelineState(try engine.copyPipeline(integer: integer))
    encoder.setTexture(source, index: 0)
    encoder.setTexture(copy, index: 1)
    encoder.dispatchThreadgroups(
      MTLSize(width: (copy.width + 15) / 16, height: (copy.height + 15) / 16, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
  }

  // MARK: - Metal 4 state

  /// Created by the first Metal 4 encode, so a classic host owns none of it.
  struct Metal4 {
    /// Textures 0–5 and buffers 0–3 of `mk_focusMask`; Freeze rebinds 0 and 1.
    var table: any MTL4ArgumentTable
  }
  var metal4: Metal4?
  /// Analysis uniforms, one slot per submission in flight.
  var ring = MonitorUniformRing(slotLength: MonitorFeed.uniformLength, label: "MonitorKit feed uniforms")
  var ringUniforms: AnalysisUniforms?
  var ringGeneration: UInt64 = 0
  /// What this feed has made resident, compared by identity on each Metal 4 encode.
  struct Resident {
    var mask: MTLTexture?
    var plane0: MTLTexture?
    var plane1: MTLTexture?
    var burn: MonitorLUT?
    var monitor: MonitorLUT?
  }
  var resident = Resident()

  /// Classic path: bytes of replaced or released masks still held for the frames
  /// in flight. They age only on `analyze`, so a feed nobody analyses any more
  /// keeps them until `releaseRetired()` or deinit.
  public var retiredMemoryBytes: Int {
    var n = 0, i = 0
    while i < retired.count {
      n += retired[i]?.allocatedSize ?? 0
      i += 1
    }
    return n
  }

  /// Classic path: drops the replaced or released masks held for the frames in
  /// flight. Call only once every command buffer that used this feed has
  /// completed (e.g. when a view goes idle after turning peaking off). Metal 4
  /// releases them by submission index on its own.
  public func releaseRetired() {
    var i = 0
    while i < retired.count {
      retired[i] = nil
      i += 1
    }
  }

  /// Replaced masks still referenced, for tests.
  var retiredMaskCount: Int {
    var n = 0, i = 0
    while i < retired.count {
      if retired[i] != nil { n += 1 }
      i += 1
    }
    return n
  }

  /// Keeps `texture` for `retiredFrames` more analyses, in a free slot, else in
  /// place of the oldest (only reachable if a host retires more than once per analysis).
  func retire(_ texture: MTLTexture?) {
    guard let texture else { return }
    var slot = 0, i = 0
    while i < retired.count {
      if retired[i] == nil {
        slot = i
        break
      }
      if retiredAges[i] > retiredAges[slot] { slot = i }
      i += 1
    }
    retired[slot] = texture
    retiredAges[slot] = 0
  }

  func ageRetired() {
    var i = 0
    while i < retired.count {
      if retired[i] != nil {
        retiredAges[i] += 1
        if retiredAges[i] >= Self.retiredFrames { retired[i] = nil }
      }
      i += 1
    }
  }
}
