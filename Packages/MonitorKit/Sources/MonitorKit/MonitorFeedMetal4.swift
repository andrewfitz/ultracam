import Metal

/// The Metal 4 encode path of a feed: the same kernels and pixels as the classic
/// path, into the host's `MTL4CommandBuffer`, with library-owned argument table,
/// uniforms, residency and barriers.
extension MonitorFeed {
  /// Uniform bytes per analysis: `mk_focusMask`'s buffers 0–3 at 256-byte offsets
  /// (frame 80 B, thresholds 8 B, two LUT parameter blocks of 80 B).
  public static let uniformLength = 4 * 256

  /// `analyze(_:focus:into:)` on Metal 4, in its own compute encoder. While a
  /// submission that read or wrote the mask may still run, a consumer barrier
  /// first waits for earlier fragment and dispatch work on the queue (pictures
  /// still reading the previous mask); once they completed it encodes none.
  public func analyze(_ frame: MonitorFrame, focus: FocusSettings, into submission: MonitorSubmission) throws {
    try analyze(frame, focus: focus, submission: submission, host: nil)
  }

  /// The analysis inside the host's compute encoder (which this binds its own
  /// argument table on: rebind yours afterwards). An encoder barrier after the
  /// dispatch makes the mask visible to later dispatches in the same encoder,
  /// e.g. `MonitorPass.encodeCompute(…, encoder:)`.
  public func analyze(
    _ frame: MonitorFrame, focus: FocusSettings, submission: MonitorSubmission,
    encoder: any MTL4ComputeCommandEncoder
  ) throws {
    try analyze(frame, focus: focus, submission: submission, host: encoder)
  }

  private func analyze(
    _ frame: MonitorFrame, focus: FocusSettings, submission: MonitorSubmission,
    host: (any MTL4ComputeCommandEncoder)?
  ) throws {
    engine.residency.observe(submission)
    ageRetired()
    guard focus.enabled, !frame.isProcessed else { return releaseFocusMask() }
    let a = try prepareAnalysis(frame, focus: focus)
    if holds(frame, a) { return }
    let table = try metal4Table()
    updateResidency()
    frame.keepResidentIfReleased(in: engine.residency)
    let address = try analysisUniforms(a.uniforms, submission)
    guard let encoder = host ?? submission.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a compute encoder for focus analysis.")
    }
    // Write after read (pictures) and write after write (the last analysis), only
    // while a submission that used the mask may still run. Queue barriers order
    // whole stages, so this spares the queue's unrelated work when it can.
    if max(maskLastRead, maskLastWrite) > submission.completedIndex {
      encoder.barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .dispatch, visibilityOptions: [])
    }
    maskLastWrite = submission.index
    if host != nil {
      encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: [])
    }
    encoder.setComputePipelineState(a.pipeline)
    table.setTexture((frame.packed ?? engine.emptyPacked).gpuResourceID, index: 0)
    table.setTexture((frame.luma ?? engine.emptyFloat).gpuResourceID, index: 1)
    table.setTexture((frame.chroma ?? engine.emptyFloat).gpuResourceID, index: 2)
    table.setTexture(a.mask.gpuResourceID, index: 3)
    table.setTexture((a.burn?.texture ?? engine.emptyLUT).gpuResourceID, index: 4)
    table.setTexture((a.monitor?.texture ?? engine.emptyLUT).gpuResourceID, index: 5)
    table.setAddress(address, index: 0)
    table.setAddress(address + 256, index: 1)
    table.setAddress(address + 512, index: 2)
    table.setAddress(address + 768, index: 3)
    encoder.setArgumentTable(table)
    let grid = Self.focusDispatch(frame, a.pipeline)
    encoder.dispatchThreadgroups(threadgroupsPerGrid: grid.groups, threadsPerThreadgroup: grid.threads)
    if host != nil {
      encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
    } else {
      encoder.endEncoding()
    }
    finishAnalysis(frame, a)
  }

  /// `freeze(_:into:)` on Metal 4: the compute copy into planes made resident in
  /// `engine.residency`, then a producer barrier so later dispatch, fragment and
  /// blit work on the queue reads the finished copy. Overwriting existing planes
  /// first waits for earlier readers (a consumer barrier on fragment, dispatch
  /// and blit work), so a re-freeze needs no host ordering.
  public func freeze(_ frame: MonitorFrame, into submission: MonitorSubmission) throws -> MonitorFrame {
    engine.residency.observe(submission)
    if let frozenFrame, let owned = freezePlanes.0, frame.primaryTexture === owned { return frozenFrame }
    // A frozen frame the feed let go may be the source.
    frame.keepResidentIfReleased(in: engine.residency)
    let f = try prepareFreeze(frame)
    let table = try metal4Table()
    updateResidency()
    guard let encoder = submission.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a compute encoder for Freeze.")
    }
    encoder.label = "MonitorKit freeze"
    if f.reused {
      encoder.barrier(afterQueueStages: [.fragment, .dispatch, .blit], beforeStages: .dispatch, visibilityOptions: [])
    }
    encoder.setArgumentTable(table)
    try copy(f.sources.0, into: f.planes.0, integer: f.integer.0, encoder, table)
    if let b = f.planes.1 { try copy(f.sources.1, into: b, integer: f.integer.1, encoder, table) }
    encoder.barrier(afterStages: .dispatch, beforeQueueStages: [.dispatch, .fragment, .blit], visibilityOptions: .device)
    encoder.endEncoding()
    return try finishFreeze(frame, f)
  }

  private func copy(
    _ source: MTLTexture?, into copy: MTLTexture, integer: Bool, _ encoder: any MTL4ComputeCommandEncoder,
    _ table: any MTL4ArgumentTable
  ) throws {
    guard let source else { throw MonitorKitError.invalidFrame("a frame plane is missing") }
    encoder.setComputePipelineState(try engine.copyPipeline(integer: integer))
    table.setTexture(source.gpuResourceID, index: 0)
    table.setTexture(copy.gpuResourceID, index: 1)
    encoder.dispatchThreadgroups(
      threadgroupsPerGrid: MTLSize(width: (copy.width + 15) / 16, height: (copy.height + 15) / 16, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
  }

  // MARK: - Shared Metal 4 state

  func metal4Table() throws -> any MTL4ArgumentTable {
    if let m = metal4 { return m.table }
    let table = try engine.makeArgumentTable(textures: 6, buffers: 4, label: "MonitorKit feed")
    metal4 = Metal4(table: table)
    return table
  }

  /// Writes the analysis uniforms for `submission`: into the host's allocator, or
  /// into a ring slot only when they changed.
  private func analysisUniforms(_ u: AnalysisUniforms, _ submission: MonitorSubmission) throws -> MTLGPUAddress {
    if let host = submission.uniforms {
      let m = host.allocateUniforms(length: Self.uniformLength)
      Self.write(u, m.contents)
      return m.gpuAddress
    }
    if ringUniforms != u {
      ringUniforms = u
      ringGeneration &+= 1
    }
    let slot = try ring.slot(for: submission, generation: ringGeneration, engine: engine)
    if let contents = slot.contents { Self.write(u, contents) }
    return slot.address
  }

  private static func write(_ u: AnalysisUniforms, _ base: UnsafeMutableRawPointer) {
    store(u.frame, base, 0)
    store(u.thresholds, base, 256)
    store(u.burn, base, 512)
    store(u.monitor, base, 768)
  }

  /// Makes what the feed's encodes read resident in `engine.residency`: its LUT
  /// textures, focus mask and Freeze planes. Compared by identity, so steady state
  /// touches nothing; a replaced one is retired until the latest submission
  /// completes. Every Metal 4 encode of the feed and of passes showing it calls
  /// this; other Metal 4 work that reads the feed's textures (e.g. scopes with the
  /// feed's LUTs) calls it before encoding.
  public func updateResidency() {
    let r = engine.residency
    if resident.mask !== focusMask {
      retireResident(&resident.mask)
      if let t = focusMask {
        r.add(t)
        resident.mask = t
      }
    }
    if resident.plane0 !== freezePlanes.0 {
      retireResident(&resident.plane0)
      if let t = freezePlanes.0 {
        r.add(t)
        resident.plane0 = t
      }
    }
    if resident.plane1 !== freezePlanes.1 {
      retireResident(&resident.plane1)
      if let t = freezePlanes.1 {
        r.add(t)
        resident.plane1 = t
      }
    }
    if resident.burn !== burnInLUT {
      if let old = resident.burn { r.retire(old, resident: old.texture) }
      resident.burn = burnInLUT
      if let lut = burnInLUT { r.add(lut.texture) }
    }
    if resident.monitor !== monitorLUT {
      if let old = resident.monitor { r.retire(old, resident: old.texture) }
      resident.monitor = monitorLUT
      if let lut = monitorLUT { r.add(lut.texture) }
    }
  }

  /// A picture of `submission` reads the mask.
  func noteMaskRead(_ submission: MonitorSubmission) { maskLastRead = max(maskLastRead, submission.index) }

  /// Whether a picture of `submission` must wait for the analysis that wrote the
  /// mask: it may still run (completed submissions' writes are visible).
  func maskWritePending(_ submission: MonitorSubmission) -> Bool { maskLastWrite > submission.completedIndex }

  func retireResident(_ texture: inout MTLTexture?) {
    if let old = texture { engine.residency.retire(old, resident: old) }
    texture = nil
  }
}
