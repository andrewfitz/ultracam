import Metal
import MonitorKit
import MonitorKitCore

/// The Metal 4 encode path of a group: the fused pass with the group's own
/// argument table (5 textures, 15 buffers) and uniform ring, then every unfused
/// member's own Metal 4 accumulation, in one compute encoder.
extension ScopeGroup {
  /// Offsets in the fused pass's uniforms: frame and LUT parameters (buffers
  /// 0–2), the lead's parameters (3), the clear and finalize's (3), and the
  /// waveform's, histogram's and vectorscope's (8–10).
  static let leadOffset = 768
  static let maintenanceOffset = 1024
  static let memberOffsets = SIMD3(1280, 1536, 1792)
  /// Uniform bytes of the fused pass, asked of a host `MonitorUniformAllocator`
  /// once per accumulation; each unfused member asks `ScopeAccumulator.uniformLength`.
  public static let uniformLength = 2048

  /// `accumulate(_:feed:monitorLUTEnabled:into:)` on Metal 4, in its own compute
  /// encoder, ordered like `ScopeAccumulator.accumulate(…, into: MonitorSubmission)`.
  public func accumulate(
    _ frame: MonitorFrame, feed: MonitorFeed, monitorLUTEnabled: Bool = true, into submission: MonitorSubmission
  ) throws {
    try accumulate(
      frame, burnInLUT: feed.burnInLUT, monitorLUT: monitorLUTEnabled ? feed.monitorLUT : nil, into: submission)
  }

  /// Every member on Metal 4, in its own compute encoder.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, into submission: MonitorSubmission
  ) throws {
    engine.residency.observe(submission)
    guard let encoder = submission.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a Metal 4 compute encoder for the scopes.")
    }
    defer { encoder.endEncoding() }
    try accumulateMetal4(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, submission: submission, encoder: encoder)
  }

  /// Every member with the feed's LUTs inside the host's compute encoder.
  public func accumulate(
    _ frame: MonitorFrame, feed: MonitorFeed, monitorLUTEnabled: Bool = true, submission: MonitorSubmission,
    encoder: any MTL4ComputeCommandEncoder
  ) throws {
    try accumulate(
      frame, burnInLUT: feed.burnInLUT, monitorLUT: monitorLUTEnabled ? feed.monitorLUT : nil, submission: submission,
      encoder: encoder)
  }

  /// Every member inside the host's compute encoder, which this binds its own
  /// argument tables and threadgroup memory 0 on (rebind yours afterwards), with
  /// encoder barriers like `ScopeAccumulator.accumulate(…, submission:encoder:)`.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, submission: MonitorSubmission,
    encoder: any MTL4ComputeCommandEncoder
  ) throws {
    engine.residency.observe(submission)
    try accumulateMetal4(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, submission: submission, encoder: encoder)
  }

  private func accumulateMetal4(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, submission: MonitorSubmission,
    encoder: any MTL4ComputeCommandEncoder
  ) throws {
    // A frozen frame the host still holds after `unfreeze()` released its planes.
    frame.keepResidentIfReleased(in: engine.residency)
    let members = fusable()
    // Set again only once a fused pass is encoded, so a throw leaves no stale fusion.
    fused = Members()
    if let pipeline = fusedPipeline(frame, members) {
      try encodeFusedMetal4(
        frame, members: members, pipeline: pipeline, burnInLUT: burnInLUT, monitorLUT: monitorLUT,
        submission: submission, encoder: encoder)
    }
    var i = 0
    while i < accumulators.count {
      if !fused.contains(i) {
        try accumulators[i].accumulateMetal4(
          frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, submission: submission, host: encoder)
      }
      i += 1
    }
  }

  private func encodeFusedMetal4(
    _ frame: MonitorFrame, members: Members, pipeline: MTLComputePipelineState, burnInLUT: MonitorLUT?,
    monitorLUT: MonitorLUT?, submission: MonitorSubmission, encoder: any MTL4ComputeCommandEncoder
  ) throws {
    guard let f = try beginFused(frame, members: members, burnInLUT: burnInLUT, monitorLUT: monitorLUT) else { return }
    let leader = accumulators[f.leadIndex]
    let table = try argumentTable()
    var slot = 0
    while slot < 3 {
      if let i = members.member(slot) { accumulators[i].updateResidency(burnInLUT: burnInLUT, monitorLUT: monitorLUT) }
      slot += 1
    }
    uniformGeneration &+= 1
    let u = try scopeUniforms(
      &ring, length: Self.uniformLength, generation: uniformGeneration, submission: submission, engine: engine)
    if let base = u.contents {
      ScopeAccumulator.writeInputs(f.leadPass.frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, base)
      scopeStore(f.leadPass.params, base, Self.leadOffset)
      scopeStore(f.maintenance, base, Self.maintenanceOffset)
      if let p = fusedWaveformParameters(f) { scopeStore(p, base, Self.memberOffsets[0]) }
      if let p = f.passes.1?.params { scopeStore(p, base, Self.memberOffsets[1]) }
      if let p = f.passes.2?.params { scopeStore(p, base, Self.memberOffsets[2]) }
    }
    ScopeAccumulator.orderBeforeClear(encoder, inHostEncoder: true)
    ScopeAccumulator.bindInputs(
      frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, engine: engine, table, uniforms: u.address)
    slot = 0
    while slot < 3 {
      if let i = members.member(slot) {
        accumulators[i].bindMember(at: slot, table)
      } else {
        leader.bindMember(at: slot, table)
      }
      slot += 1
    }
    table.setAddress(u.address + UInt64(Self.maintenanceOffset), index: 3)
    encoder.setArgumentTable(table)
    ScopeAccumulator.dispatch(
      ScopeAccumulator.clearDispatch(f.maintenance, pipeline: engine.groupClearPipeline), engine.groupClearPipeline,
      encoder)
    ScopeAccumulator.orderDispatches(encoder)

    table.setAddress(u.address + UInt64(Self.leadOffset), index: 3)
    table.setAddress(leader.statisticsBuffer.gpuAddress, index: 14)
    // Bins 4, 6 and 7 are bound as members 0–2 above; an absent scope's parameters are not read.
    slot = 0
    while slot < 3 {
      if members.member(slot) != nil {
        table.setAddress(u.address + UInt64(Self.memberOffsets[slot]), index: 8 + slot)
      }
      slot += 1
    }
    let geometry = fusedDispatch
    ScopeAccumulator.dispatch(
      ScopeAccumulator.Dispatch(
        grid: geometry.grid,
        group: MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, Self.threads), height: 1, depth: 1),
        byThreadgroups: true, threadgroupBytes: geometry.threadgroupBytes), pipeline, encoder)
    ScopeAccumulator.orderDispatches(encoder)

    table.setAddress(u.address + UInt64(Self.maintenanceOffset), index: 3)
    ScopeAccumulator.dispatch(
      ScopeAccumulator.finalizeDispatch(pipeline: engine.groupFinalizePipeline), engine.groupFinalizePipeline, encoder)
    ScopeAccumulator.orderDispatches(encoder)
    finishFused(f, members: members, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
  }

  private func argumentTable() throws -> any MTL4ArgumentTable {
    if let t = metal4Table { return t }
    let t = try engine.makeArgumentTable(textures: 5, buffers: 15, label: "MonitorKit scope group")
    metal4Table = t
    return t
  }
}
