import Metal

/// The Metal 4 encode path of a surface: the classic path's pipelines and
/// pixels, into the host's `MTL4CommandBuffer`. The pass owns its argument table
/// (7 textures, 5 buffers: the host's is smaller and would be clobbered) and a
/// uniform ring, so a steady-state encode writes no uniforms and allocates nothing.
extension MonitorPass {
  /// Offsets of the uniform blocks in one encode's uniforms (`mk_picture`'s buffers 0–4).
  static let passOffset = 768
  static let guidesOffset = passOffset + align256(MemoryLayout<PassParameters>.stride)
  /// Uniform bytes per encode: frame, two LUT blocks, pass and guide parameters at
  /// 256-byte offsets. Asked of a host `MonitorUniformAllocator` once per encode.
  public static let uniformLength = guidesOffset + align256(MemoryLayout<GuideParameters>.stride)

  /// `encode(…, into: MTLCommandBuffer)` on Metal 4: its own render pass into
  /// `target` (which may be a `framebufferOnly` drawable). The host makes
  /// `target` and the frame's textures resident and orders its own writes to
  /// them before this submission's work. With `clear` false a consumer barrier
  /// first waits for earlier fragment and dispatch work, so several surfaces
  /// (render or compute) can share a target; for several render surfaces,
  /// `MonitorMultiview` draws them in one render pass with at most one barrier.
  ///
  /// Metal 4 orders nothing between submissions on its own. A host that reads a
  /// persistent (non-drawable) target, e.g. samples or blits a multiview texture,
  /// ends its reading encoder with a producer barrier (after its stages, before
  /// fragment and dispatch) so the next frame's MonitorKit write does not overtake
  /// the read; with `clear` true MonitorKit encodes no barrier of its own.
  public func encode(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, target: MTLTexture,
    viewport: MonitorViewport? = nil, clear: Bool = true, into submission: MonitorSubmission
  ) throws {
    let vp = try Self.checkedViewport(viewport, target)
    let format = MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat, sampleCount: target.sampleCount)
    try prepare(frame: frame, feed: feed, state: state, viewport: vp, target: format, submission: submission)
    let attachment = metal4Descriptor.colorAttachments[0]!
    attachment.texture = target
    attachment.loadAction = clear ? .clear : .load
    let encoder = submission.commandBuffer.makeRenderCommandEncoder(descriptor: metal4Descriptor)
    attachment.texture = nil
    guard let encoder else {
      pending = nil
      throw MonitorKitError.gpu("Cannot create a Metal 4 render encoder.")
    }
    defer { encoder.endEncoding() }
    // Loading a target earlier passes wrote (other surfaces' viewports).
    if !clear {
      encoder.barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .fragment, visibilityOptions: .device)
    }
    try draw(with: encoder)
  }

  /// For drawing inside the host's own Metal 4 render pass: caches the state and
  /// writes this encode's uniforms (encodes nothing), then `draw(with:)` in the pass.
  public func prepare(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, viewport: MonitorViewport,
    target: MonitorRenderTargetFormat, submission: MonitorSubmission
  ) throws {
    try prepareMetal4(
      frame: frame, feed: feed, state: state, viewport: viewport, target: target, submission: submission,
      compute: false)
  }

  /// Draws the prepared frame in a Metal 4 render pass. Sets the pipeline,
  /// viewport, a scissor rectangle of the viewport, no culling, fill mode, this
  /// pass's argument table at the fragment stage (rebind yours afterwards) and,
  /// with depth or stencil, an always-pass depth-stencil state. The viewport must
  /// lie inside the host's target.
  /// When the picture reads a focus mask whose analysis may still run, a consumer
  /// barrier first waits for earlier dispatches on the queue (the analysis may be
  /// in another command buffer).
  public func draw(with encoder: any MTL4RenderCommandEncoder) throws {
    guard let p = pending, p.uniforms != 0, let pipeline = currentRenderPipeline else {
      throw MonitorKitError.gpu("MonitorPass.draw(with:) on Metal 4 needs prepare(…, submission:) first.")
    }
    pending = nil
    if p.focusMask != nil && p.waitsForMask {
      encoder.barrier(afterQueueStages: .dispatch, beforeStages: .fragment, visibilityOptions: .device)
    }
    let vp = p.viewport
    encoder.setRenderPipelineState(pipeline)
    if currentDrawsDepthStencil { encoder.setDepthStencilState(engine.depthStencil) }
    encoder.setViewport(
      MTLViewport(
        originX: Double(vp.x), originY: Double(vp.y), width: Double(vp.width), height: Double(vp.height),
        znear: 0, zfar: 1))
    encoder.setScissorRect(MTLScissorRect(x: vp.x, y: vp.y, width: vp.width, height: vp.height))
    encoder.setCullMode(.none)
    encoder.setTriangleFillMode(.fill)
    let table = metal4Table!
    bind(p, table)
    encoder.setArgumentTable(table, stages: .fragment)
    encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
  }

  /// The picture written by a compute kernel into `viewport` of a shader-writable,
  /// non-sRGB `target`, in its own compute encoder: the same values a render
  /// pass writes. Every viewport pixel is written (black outside the picture).
  ///
  /// `sharesTarget` (the default): a consumer barrier first waits for earlier
  /// fragment and dispatch work on the queue, as a render pass into the same target
  /// (another surface's viewport) stores whole tiles and the dispatch must not
  /// overlap it. Pass false for the target's only writer in this submission (a
  /// fresh drawable): queue barriers order whole stages, so the picture then waits
  /// only for a focus analysis that may still run. The note on persistent targets
  /// at `encode(…, into: MonitorSubmission)` applies either way.
  public func encodeCompute(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, target: MTLTexture,
    viewport: MonitorViewport? = nil, sharesTarget: Bool = true, into submission: MonitorSubmission
  ) throws {
    try encodeCompute(
      frame: frame, feed: feed, state: state, target: target, viewport: viewport, sharesTarget: sharesTarget,
      submission: submission, host: nil)
  }

  /// `encodeCompute` inside the host's compute encoder (this binds its own argument
  /// table: rebind yours afterwards). With `sharesTarget`, besides the queue
  /// barrier, an encoder barrier orders it after the encoder's earlier dispatches
  /// (e.g. the host clearing the target). `MonitorFeed.analyze(…, encoder:)` in the
  /// same encoder orders the mask with its own encoder barrier.
  public func encodeCompute(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, target: MTLTexture,
    viewport: MonitorViewport? = nil, sharesTarget: Bool = true, submission: MonitorSubmission,
    encoder: any MTL4ComputeCommandEncoder
  ) throws {
    try encodeCompute(
      frame: frame, feed: feed, state: state, target: target, viewport: viewport, sharesTarget: sharesTarget,
      submission: submission, host: encoder)
  }

  private func encodeCompute(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, target: MTLTexture, viewport: MonitorViewport?,
    sharesTarget: Bool, submission: MonitorSubmission, host: (any MTL4ComputeCommandEncoder)?
  ) throws {
    let vp = try Self.checkedViewport(viewport, target)
    guard !target.pixelFormat.isSRGB, target.usage.contains(.shaderWrite) else {
      throw MonitorKitError.invalidFrame("a compute target must be shader-writable and not sRGB-encoded")
    }
    try prepareMetal4(
      frame: frame, feed: feed, state: state, viewport: vp,
      target: MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat), submission: submission,
      compute: true)
    guard let p = pending, let pipeline = currentComputePipeline else {
      throw MonitorKitError.gpu("No compute picture pipeline.")
    }
    pending = nil
    guard let encoder = host ?? submission.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a Metal 4 compute encoder.")
    }
    if sharesTarget {
      // Earlier render passes into this target (their tile stores cover whole
      // tiles, not just their viewports), earlier dispatches, and the mask's analysis.
      encoder.barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .dispatch, visibilityOptions: .device)
      if host != nil {
        encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
      }
    } else if p.focusMask != nil && p.waitsForMask {
      encoder.barrier(afterQueueStages: .dispatch, beforeStages: .dispatch, visibilityOptions: .device)
    }
    encoder.setComputePipelineState(pipeline)
    let table = metal4Table!
    bind(p, table)
    table.setTexture(target.gpuResourceID, index: 6)
    encoder.setArgumentTable(table)
    let side = pipeline.maxTotalThreadsPerThreadgroup >= 256 ? 16 : 8
    encoder.dispatchThreads(
      threadsPerGrid: MTLSize(width: vp.width, height: vp.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
    if host == nil { encoder.endEncoding() }
  }

  // MARK: - Shared

  static func checkedViewport(_ viewport: MonitorViewport?, _ target: MTLTexture) throws -> MonitorViewport {
    let vp = viewport ?? MonitorViewport(width: target.width, height: target.height)
    guard vp.x >= 0, vp.y >= 0, vp.x + vp.width <= target.width, vp.y + vp.height <= target.height else {
      throw MonitorKitError.invalidFrame("viewport \(vp) is outside the \(target.width)×\(target.height) target")
    }
    return vp
  }

  private func prepareMetal4(
    frame: MonitorFrame, feed: MonitorFeed, state: MonitorState, viewport: MonitorViewport,
    target: MonitorRenderTargetFormat, submission: MonitorSubmission, compute: Bool
  ) throws {
    engine.residency.observe(submission)
    if metal4Table == nil {
      metal4Table = try engine.makeArgumentTable(textures: 7, buffers: 5, label: "MonitorKit pass")
    }
    try prepareState(frame: frame, feed: feed, state: state, viewport: viewport, target: target, compute: compute)
    if pending!.focusMask != nil {
      pending!.waitsForMask = feed.maskWritePending(submission)
      feed.noteMaskRead(submission)
    }
    // The pass reads the feed's LUTs, mask and Freeze planes, and the planes of
    // a frozen frame the host still draws after its feed let them go.
    feed.updateResidency()
    frame.keepResidentIfReleased(in: engine.residency)
    pending!.uniforms = try writeUniforms(pending!, submission)
  }

  /// This encode's uniforms: into the host's allocator, or a ring slot rewritten
  /// only when a parameter changed since the slot was last written.
  private func writeUniforms(_ p: Pending, _ submission: MonitorSubmission) throws -> MTLGPUAddress {
    if let host = submission.uniforms {
      let m = host.allocateUniforms(length: Self.uniformLength)
      write(p, m.contents)
      return m.gpuAddress
    }
    let slot = try ring.slot(for: submission, generation: uniformGeneration, engine: engine)
    if let contents = slot.contents { write(p, contents) }
    return slot.address
  }

  private func write(_ p: Pending, _ base: UnsafeMutableRawPointer) {
    store(p.frameParameters, base, 0)
    store(p.burnInLUT?.parameters ?? .disabled, base, 256)
    store(p.monitorLUT?.parameters ?? .disabled, base, 512)
    store(parameters, base, Self.passOffset)
    store(guides, base, Self.guidesOffset)
  }

  private func bind(_ p: Pending, _ table: any MTL4ArgumentTable) {
    table.setTexture((p.frame.packed ?? engine.emptyPacked).gpuResourceID, index: 0)
    table.setTexture((p.frame.luma ?? engine.emptyFloat).gpuResourceID, index: 1)
    table.setTexture((p.frame.chroma ?? engine.emptyFloat).gpuResourceID, index: 2)
    table.setTexture((p.burnInLUT?.texture ?? engine.emptyLUT).gpuResourceID, index: 3)
    table.setTexture((p.monitorLUT?.texture ?? engine.emptyLUT).gpuResourceID, index: 4)
    table.setTexture((p.focusMask ?? engine.emptyFloat).gpuResourceID, index: 5)
    table.setAddress(p.uniforms, index: 0)
    table.setAddress(p.uniforms + 256, index: 1)
    table.setAddress(p.uniforms + 512, index: 2)
    table.setAddress(p.uniforms + UInt64(Self.passOffset), index: 3)
    table.setAddress(p.uniforms + UInt64(Self.guidesOffset), index: 4)
  }
}
