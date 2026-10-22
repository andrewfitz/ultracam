import Metal
import MonitorKitCore

/// Several surfaces in one render pass into one target: one clear (or load) and
/// one store of the attachment for all of them. Each `MonitorPass.encode` into a
/// shared target is its own render pass, which on a tile-based GPU loads and
/// stores the whole attachment and, on Metal 4 with `clear` false, waits for all
/// earlier fragment and dispatch work on the queue. Four 4K feeds' eight surfaces
/// into a 4K target take 1.56 ms of GPU time this way against 1.96 ms as eight
/// passes (M4 Max, analyses included). This is the multiview path; the pixels are
/// those of the per-pass encodes.
///
/// ```swift
/// try multiview.encode(target: drawable.texture, into: commandBuffer) { canvas in
///   try canvas.draw(left, frame: a, feed: feedA, state: stateA, viewport: leftHalf)
///   try canvas.draw(right, frame: b, feed: feedB, state: stateB, viewport: rightHalf)
/// }
/// ```
///
/// Each surface keeps its own `MonitorPass` (one per surface, as always). Owns no
/// GPU memory; confined like a pass. Adds no allocation of its own per frame
/// beyond Metal's encoder: the closure does not escape and the descriptors are reused.
public final class MonitorMultiview {
  private let descriptor = MTLRenderPassDescriptor()
  private let metal4Descriptor = MTL4RenderPassDescriptor()
  /// Counts encodes; a canvas draws only during its own.
  private var generation: UInt64 = 0
  private var open = false

  public init() {
    for attachment in [descriptor.colorAttachments[0]!, metal4Descriptor.colorAttachments[0]!] {
      attachment.storeAction = .store
      attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }
  }

  /// What `surfaces` draws through: valid only inside the `encode` call that made it.
  public struct Canvas {
    /// The target's colour format, which every surface's pipeline is built for.
    public let format: MonitorRenderTargetFormat
    public let width: Int
    public let height: Int
    let owner: MonitorMultiview
    let generation: UInt64
    let classic: (encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer)?
    let metal4: (encoder: any MTL4RenderCommandEncoder, submission: MonitorSubmission)?

    /// Draws one surface into `viewport` (default: the whole target): `pass`'s
    /// prepare, then its draw in the shared render pass. Every pixel of the
    /// viewport is written (black outside the picture).
    public func draw(
      _ pass: MonitorPass, frame: MonitorFrame, feed: MonitorFeed, state: MonitorState,
      viewport: MonitorViewport? = nil
    ) throws {
      guard owner.open, owner.generation == generation else {
        throw MonitorKitError.gpu("MonitorMultiview.Canvas.draw outside its encode(…) call.")
      }
      let vp = viewport ?? MonitorViewport(width: width, height: height)
      guard vp.x >= 0, vp.y >= 0, vp.x + vp.width <= width, vp.y + vp.height <= height else {
        throw MonitorKitError.invalidFrame("viewport \(vp) is outside the \(width)×\(height) target")
      }
      if let c = classic {
        try pass.prepare(frame: frame, feed: feed, state: state, viewport: vp, target: format, into: c.commandBuffer)
        try pass.draw(with: c.encoder)
      } else if let m = metal4 {
        try pass.prepare(frame: frame, feed: feed, state: state, viewport: vp, target: format, submission: m.submission)
        try pass.draw(with: m.encoder)
      }
    }
  }

  /// One render pass into `target` (cleared to black when `clear`, else loaded),
  /// in which `surfaces` draws every surface through the canvas.
  public func encode(
    target: MTLTexture, clear: Bool = true, into commandBuffer: MTLCommandBuffer,
    _ surfaces: (Canvas) throws -> Void
  ) throws {
    try checkClosed()
    let attachment = descriptor.colorAttachments[0]!
    attachment.texture = target
    attachment.loadAction = clear ? .clear : .load
    let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    attachment.texture = nil
    guard let encoder else { throw MonitorKitError.gpu("Cannot create a render encoder.") }
    defer { encoder.endEncoding() }
    try run(target, classic: (encoder, commandBuffer), metal4: nil, surfaces)
  }

  /// `encode(target:clear:into:_:)` on Metal 4. The host makes `target` and the
  /// frames resident, as for `MonitorPass.encode(…, into: MonitorSubmission)`.
  /// With `clear` false one consumer barrier first waits for earlier fragment and
  /// dispatch work on the queue, once for all the surfaces.
  public func encode(
    target: MTLTexture, clear: Bool = true, into submission: MonitorSubmission, _ surfaces: (Canvas) throws -> Void
  ) throws {
    try checkClosed()
    let attachment = metal4Descriptor.colorAttachments[0]!
    attachment.texture = target
    attachment.loadAction = clear ? .clear : .load
    let encoder = submission.commandBuffer.makeRenderCommandEncoder(descriptor: metal4Descriptor)
    attachment.texture = nil
    guard let encoder else { throw MonitorKitError.gpu("Cannot create a Metal 4 render encoder.") }
    defer { encoder.endEncoding() }
    if !clear {
      encoder.barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .fragment, visibilityOptions: .device)
    }
    try run(target, classic: nil, metal4: (encoder, submission), surfaces)
  }

  /// A canvas cannot open a second render pass on its own command buffer.
  private func checkClosed() throws {
    if open { throw MonitorKitError.gpu("MonitorMultiview.encode inside its own encode(…) call.") }
  }

  private func run(
    _ target: MTLTexture, classic: (encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer)?,
    metal4: (encoder: any MTL4RenderCommandEncoder, submission: MonitorSubmission)?, _ surfaces: (Canvas) throws -> Void
  ) throws {
    generation &+= 1
    open = true
    defer { open = false }
    try surfaces(
      Canvas(
        format: MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat, sampleCount: target.sampleCount),
        width: target.width, height: target.height, owner: self, generation: generation, classic: classic,
        metal4: metal4))
  }
}
