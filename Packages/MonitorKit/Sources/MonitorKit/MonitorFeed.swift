import Metal
import MonitorKitCore

/// One per video feed: the feed's LUTs and its once-per-frame analysis, shared by
/// every surface that shows the feed.
///
/// Confined: use from one thread at a time (not `Sendable`; move it with
/// `sending` or keep it on the host's render actor). No internal locks.
///
/// Command buffers should retain their references (the default). With
/// unretained-reference command buffers the host keeps its `MonitorLUT`s alive
/// until the GPU is done; a focus mask replaced on a size change is kept for
/// `retiredFrames` more analyses.
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

  /// What the mask was computed from: the frame (by `MonitorFrame.id`) and the
  /// LUTs applied before edge detection (none for the source stage).
  struct MaskKey {
    var frame: UInt64
    var width: Int
    var height: Int
    var layout: PixelLayout
    var burn: MonitorLUT?
    var monitor: MonitorLUT?

    func matches(_ f: MonitorFrame) -> Bool {
      frame == f.id && width == f.width && height == f.height && layout == f.layout
    }
  }
  private var maskKey: MaskKey?
  private var focusPipeline: MTLComputePipelineState?
  private var focusPipelineKey = MonitorEngine.FocusKey(layout: 0, lutStage: false)

  /// Analyses a replaced mask stays referenced for: covers the frames a host keeps in flight.
  public static let retiredFrames = 3
  private var retired: (MTLTexture?, MTLTexture?) = (nil, nil)
  private var retiredAge = 0

  init(engine: MonitorEngine) { self.engine = engine }

  /// Once per frame, before any pass that shows peaking. Analyses `focus.stage`:
  /// the source luma, or the luma after the burn-in LUT (output) and the monitor
  /// LUT too (monitor). Encodes one compute pass; never commits. With
  /// `focus.enabled` false it encodes nothing and marks the mask stale.
  public func analyze(_ frame: MonitorFrame, focus: FocusSettings, into commandBuffer: MTLCommandBuffer)
    throws
  {
    ageRetired()
    guard focus.enabled else {
      maskKey = nil
      return
    }
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
    let key = MonitorEngine.FocusKey(layout: frame.layout.shaderKind, lutStage: burn != nil || monitor != nil)
    if focusPipeline == nil || focusPipelineKey != key {
      focusPipeline = try engine.focusPipeline(layout: key.layout, lutStage: key.lutStage)
      focusPipelineKey = key
    }
    guard let pipeline = focusPipeline, let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a compute encoder for focus analysis.")
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(frame.packed ?? engine.emptyPacked, index: 0)
    encoder.setTexture(frame.luma ?? engine.emptyFloat, index: 1)
    encoder.setTexture(frame.chroma ?? engine.emptyFloat, index: 2)
    encoder.setTexture(mask, index: 3)
    encoder.setTexture(burn?.texture ?? engine.emptyLUT, index: 4)
    encoder.setTexture(monitor?.texture ?? engine.emptyLUT, index: 5)
    var parameters = frame.parameters
    encoder.setBytes(&parameters, length: MemoryLayout<FrameParameters>.stride, index: 0)
    var thresholds = SIMD2<Float>(Float(focus.edgeThreshold), Float(min(1, max(0, focus.noiseRejection))))
    encoder.setBytes(&thresholds, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    var burnParameters = burn?.parameters ?? .disabled, monitorParameters = monitor?.parameters ?? .disabled
    encoder.setBytes(&burnParameters, length: MemoryLayout<LUTParameters>.stride, index: 2)
    encoder.setBytes(&monitorParameters, length: MemoryLayout<LUTParameters>.stride, index: 3)
    // 16 × 16 groups match the shader's 18 × 18 halo tile.
    encoder.dispatchThreadgroups(
      MTLSize(width: (frame.width + 15) / 16, height: (frame.height + 15) / 16, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    maskKey = MaskKey(
      frame: frame.id, width: frame.width, height: frame.height, layout: frame.layout, burn: burn,
      monitor: monitor)
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

  /// Bytes of GPU memory this feed owns (the focus mask). LUTs are counted by
  /// their own `MonitorLUT`, which may be shared.
  public var persistentMemoryBytes: Int { focusMask?.allocatedSize ?? 0 }

  /// Replaced masks still referenced, for tests.
  var retiredMaskCount: Int { (retired.0 != nil ? 1 : 0) + (retired.1 != nil ? 1 : 0) }

  private func retire(_ texture: MTLTexture?) {
    guard let texture else { return }
    retired = (texture, retired.0)
    retiredAge = 0
  }

  private func ageRetired() {
    guard retired.0 != nil else { return }
    retiredAge += 1
    if retiredAge >= Self.retiredFrames { retired = (nil, nil) }
  }
}
