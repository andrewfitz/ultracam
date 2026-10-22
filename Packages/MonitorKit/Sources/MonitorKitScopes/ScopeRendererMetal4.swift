import Metal
import MonitorKit
import MonitorKitCore

/// The Metal 4 encode path of a renderer: the classic path's resolve, graticule
/// and draw, into the host's `MTL4CommandBuffer`, with one argument table
/// (2 textures, 3 buffers) for all three and two uniform rings.
extension ScopeRenderer {
  /// Offset of the resolve parameters after the draw parameters in one slot.
  static let resolveOffset = scopeAlign256(MemoryLayout<ScopeDrawParameters>.stride)
  /// Uniform bytes per `prepare`: the draw's and the resolve's parameters. Asked
  /// of a host `MonitorUniformAllocator` once per `prepare`.
  public static let uniformLength = resolveOffset + scopeAlign256(MemoryLayout<ScopeResolveParameters>.stride)
  /// Uniform bytes of a graticule raster, asked only when the graticule changes.
  public static let graticuleUniformLength = scopeAlign256(MemoryLayout<ScopeGraticuleParameters>.stride)

  /// `render(…, into: MTLCommandBuffer)` on Metal 4: its own render pass into
  /// `target` (which may be a `framebufferOnly` drawable or multisampled). The
  /// host makes `target` resident and orders its own writes to it. With `clear`
  /// false (the default) a consumer barrier first waits for earlier fragment and
  /// dispatch work, so the scope composites over a picture drawn before it.
  public func render(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, target: MTLTexture,
    viewport: MonitorViewport? = nil, clear: Bool = false, into submission: MonitorSubmission
  ) throws {
    let area = try Self.checkedViewport(viewport, target)
    try prepare(
      accumulator, display: display, viewport: area,
      target: MonitorRenderTargetFormat(colorPixelFormat: target.pixelFormat, sampleCount: target.sampleCount),
      submission: submission)
    let attachment = metal4Pass.colorAttachments[0]!
    attachment.texture = target
    attachment.loadAction = clear ? .clear : .load
    let encoder = submission.commandBuffer.makeRenderCommandEncoder(descriptor: metal4Pass)
    // Don't keep the host's target alive past this call.
    attachment.texture = nil
    guard let encoder else { throw MonitorKitError.gpu("Cannot create a Metal 4 render encoder for the scope.") }
    if !clear {
      encoder.barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .fragment, visibilityOptions: .device)
    }
    draw(with: encoder, waited: !clear)
    encoder.endEncoding()
  }

  /// For drawing inside the host's own Metal 4 render pass: encode it after the
  /// accumulation it shows and before the host's render encoder starts, then
  /// `draw(with:)` in that pass (same submission). When the bins, the display,
  /// the plot size or the graticule changed it encodes a small compute pass
  /// (the trace resolve, after a consumer barrier on earlier dispatch and
  /// fragment work) and a render pass (the graticule) into the submission.
  public func prepare(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, viewport area: MonitorViewport,
    target: MonitorRenderTargetFormat, submission: MonitorSubmission
  ) throws {
    engine.residency.observe(submission)
    metal4Draw = nil
    let uniforms: MTLGPUAddress
    // A throw anywhere, in `update` too, leaves the trace and graticule to be redone.
    do {
      let work = try update(accumulator, display: display, viewport: area, target: target)
      uniforms = try encodeMetal4(work, accumulator, submission)
    } catch {
      forgetEncodedState()
      throw error
    }
    metal4Draw = (uniforms, max(traceWrittenIn, graticuleWrittenIn) > submission.completedIndex)
  }

  /// Residency, uniforms, then the resolve and graticule `work` asks for; the draw's uniforms.
  private func encodeMetal4(_ work: Work, _ accumulator: ScopeAccumulator, _ submission: MonitorSubmission) throws
    -> MTLGPUAddress
  {
    let table = try argumentTable()
    let r = engine.residency
    accumulator.updateBinResidency()
    r.track(traceTexture, in: &residentTrace)
    r.track(graticuleTexture, in: &residentGraticule)
    if work.resolve != nil || ringParameters != parameters {
      uniformGeneration &+= 1
      ringParameters = parameters
    }
    let u = try scopeUniforms(
      &ring, length: Self.uniformLength, generation: uniformGeneration, submission: submission, engine: engine)
    if let base = u.contents {
      scopeStore(parameters, base, 0)
      if let resolve = work.resolve { scopeStore(resolve, base, Self.resolveOffset) }
    }
    if let resolve = work.resolve {
      try encodeResolve(accumulator, resolve, uniforms: u.address + UInt64(Self.resolveOffset), table, submission)
      traceWrittenIn = submission.index
    }
    if let size = work.rasterize {
      try rasterizeGraticule(width: size.x, height: size.y, table, submission)
      graticuleWrittenIn = submission.index
    }
    return u.address
  }

  /// `prepare(…, target:, submission:)` for a pass with one single-sample colour
  /// attachment and no depth or stencil.
  public func prepare(
    _ accumulator: ScopeAccumulator, display: ScopeDisplay? = nil, viewport area: MonitorViewport,
    targetPixelFormat: MTLPixelFormat, submission: MonitorSubmission
  ) throws {
    try prepare(
      accumulator, display: display, viewport: area, target: MonitorRenderTargetFormat(colorPixelFormat: targetPixelFormat),
      submission: submission)
  }

  /// Draws the Metal 4 `prepare` into the host's Metal 4 render pass. Sets the
  /// pipeline, viewport, a scissor rectangle of the viewport, no culling, fill
  /// mode, this renderer's argument table at the fragment stage (rebind yours
  /// afterwards) and, with depth or stencil, an always-pass depth-stencil state,
  /// so the host's state never changes what is drawn. While the trace or graticule it reads may still be
  /// being written by a running submission, a consumer barrier first waits for
  /// earlier dispatch and fragment work. Encodes nothing while `isReady` is false.
  public func draw(with encoder: any MTL4RenderCommandEncoder) {
    draw(with: encoder, waited: false)
  }

  private func draw(with encoder: any MTL4RenderCommandEncoder, waited: Bool) {
    guard let pipeline, let graticuleTexture, let d = metal4Draw, let table = metal4Table else {
      return
    }
    if d.waits && !waited {
      encoder.barrier(afterQueueStages: [.dispatch, .fragment], beforeStages: .fragment, visibilityOptions: .device)
    }
    encoder.setRenderPipelineState(pipeline)
    if drawsDepthStencil { encoder.setDepthStencilState(engine.depthStencil) }
    encoder.setViewport(viewport)
    encoder.setScissorRect(scissor)
    encoder.setCullMode(.none)
    encoder.setTriangleFillMode(.fill)
    table.setAddress(d.uniforms, index: 0)
    table.setTexture(graticuleTexture.gpuResourceID, index: 0)
    table.setTexture(((hasTrace ? traceTexture : nil) ?? engine.placeholderTrace).gpuResourceID, index: 1)
    encoder.setArgumentTable(table, stages: .fragment)
    encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
  }

  private func argumentTable() throws -> any MTL4ArgumentTable {
    if let t = metal4Table { return t }
    let t = try engine.makeArgumentTable(textures: 2, buffers: 3, label: "MonitorKit scope renderer")
    metal4Table = t
    return t
  }

  private func encodeResolve(
    _ accumulator: ScopeAccumulator, _ parameters: ScopeResolveParameters, uniforms: MTLGPUAddress,
    _ table: any MTL4ArgumentTable, _ submission: MonitorSubmission
  ) throws {
    guard let texture = traceTexture, let encoder = submission.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot encode the scope trace.")
    }
    // Reads the accumulation's bins (earlier dispatches) and overwrites the
    // trace earlier draws read.
    encoder.barrier(afterQueueStages: [.dispatch, .fragment], beforeStages: .dispatch, visibilityOptions: .device)
    encoder.setComputePipelineState(engine.resolvePipeline)
    table.setAddress(uniforms, index: 0)
    table.setAddress(accumulator.bins.gpuAddress, index: 1)
    table.setAddress(accumulator.statisticsBuffer.gpuAddress, index: 2)
    table.setTexture(texture.gpuResourceID, index: 0)
    encoder.setArgumentTable(table)
    let d = resolveDispatch(parameters)
    encoder.dispatchThreads(threadsPerGrid: d.grid, threadsPerThreadgroup: d.group)
    encoder.endEncoding()
  }

  private func rasterizeGraticule(
    width: Int, height: Int, _ table: any MTL4ArgumentTable, _ submission: MonitorSubmission
  ) throws {
    let count = Int(shapes.size.z)
    var shapesAddress: MTLGPUAddress = 0
    if count > 0 {
      graticuleGeneration &+= 1
      let u = try scopeUniforms(
        &graticuleRing, length: Self.graticuleUniformLength, generation: graticuleGeneration, submission: submission,
        engine: engine)
      if let base = u.contents { scopeStore(shapes, base, 0) }
      shapesAddress = u.address
    }
    let attachment = metal4GraticulePass.colorAttachments[0]!
    attachment.texture = graticuleTexture
    let encoder = submission.commandBuffer.makeRenderCommandEncoder(descriptor: metal4GraticulePass)
    attachment.texture = nil
    guard let encoder else { throw MonitorKitError.gpu("Cannot encode the scope graticule.") }
    // Overwrites the coverage earlier draws read.
    encoder.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: [])
    if count > 0 {
      encoder.setRenderPipelineState(engine.graticulePipeline)
      encoder.setViewport(
        MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
      table.setAddress(shapesAddress, index: 0)
      encoder.setArgumentTable(table, stages: [.vertex, .fragment])
      encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }
    encoder.endEncoding()
  }
}
