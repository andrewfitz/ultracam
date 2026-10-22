import Metal
import MonitorKit
import MonitorKitCore

/// The Metal 4 encode path of an accumulator: the classic path's kernels and
/// bins, into the host's `MTL4CommandBuffer`. Each accumulation writes one ring
/// slot (its generation is in the parameters) and binds the accumulator's own
/// argument table (5 textures, 6 buffers).
extension ScopeAccumulator {
  /// Offsets of the uniform blocks in one accumulation's uniforms: frame, burn-in
  /// LUT and monitor LUT parameters (buffers 0–2), then the kernel's and the
  /// clear and finalize's (both buffer 3).
  static let parametersOffset = 768
  static let maintenanceOffset = parametersOffset + scopeAlign256(MemoryLayout<ScopeKernelParameters>.stride)
  /// Uniform bytes per accumulation, asked of a host `MonitorUniformAllocator` once per accumulation.
  public static let uniformLength = maintenanceOffset + scopeAlign256(MemoryLayout<ScopeMaintenanceParameters>.stride)

  /// `accumulate(_:feed:monitorLUTEnabled:into:)` on Metal 4, in its own compute
  /// encoder. The host makes the frame resident; the LUT textures, bins and
  /// statistics are in `engine.residency`.
  public func accumulate(
    _ frame: MonitorFrame, feed: MonitorFeed, monitorLUTEnabled: Bool = true, into submission: MonitorSubmission
  ) throws {
    try accumulateMetal4(
      frame, burnInLUT: feed.burnInLUT, monitorLUT: monitorLUTEnabled ? feed.monitorLUT : nil, submission: submission,
      host: nil)
  }

  /// One accumulation on Metal 4, in its own compute encoder. A consumer barrier
  /// first waits for earlier dispatch, fragment and blit work on the queue (the
  /// last frame's trace resolve, and host shaders or copies reading the bins).
  /// The bins are complete when the encoder ends: `ScopeRenderer` orders its
  /// resolve after it, and a host reading them in its own shaders adds a
  /// consumer barrier on `.dispatch` first.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, into submission: MonitorSubmission
  ) throws {
    try accumulateMetal4(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, submission: submission, host: nil)
  }

  /// One accumulation with the feed's LUTs inside the host's compute encoder.
  public func accumulate(
    _ frame: MonitorFrame, feed: MonitorFeed, monitorLUTEnabled: Bool = true, submission: MonitorSubmission,
    encoder: any MTL4ComputeCommandEncoder
  ) throws {
    try accumulateMetal4(
      frame, burnInLUT: feed.burnInLUT, monitorLUT: monitorLUTEnabled ? feed.monitorLUT : nil, submission: submission,
      host: encoder)
  }

  /// One accumulation inside the host's compute encoder, which this binds its
  /// own argument table and threadgroup memory 0 on (rebind yours afterwards).
  /// Encoder barriers before the clear and after the finalize order it against
  /// the encoder's other dispatches, so a scope can be accumulated more than once
  /// into one encoder and later dispatches there see its bins.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, submission: MonitorSubmission,
    encoder: any MTL4ComputeCommandEncoder
  ) throws {
    try accumulateMetal4(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, submission: submission, host: encoder)
  }

  func accumulateMetal4(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, submission: MonitorSubmission,
    host: (any MTL4ComputeCommandEncoder)?
  ) throws {
    engine.residency.observe(submission)
    frame.keepResidentIfReleased(in: engine.residency)
    let pass = try begin(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
    guard let pipeline = try kernelPipeline(pass) else { return }
    let table = try argumentTable()
    updateResidency(burnInLUT: burnInLUT, monitorLUT: monitorLUT)
    var maintenance = ScopeMaintenanceParameters()
    addMember(pass, to: &maintenance, at: 0)
    uniformGeneration &+= 1
    let u = try scopeUniforms(
      &ring, length: Self.uniformLength, generation: uniformGeneration, submission: submission, engine: engine)
    if let base = u.contents {
      Self.writeInputs(pass.frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, base)
      scopeStore(pass.params, base, Self.parametersOffset)
      scopeStore(maintenance, base, Self.maintenanceOffset)
    }
    guard let encoder = host ?? submission.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a Metal 4 compute encoder for the scopes.")
    }
    Self.orderBeforeClear(encoder, inHostEncoder: host != nil)
    Self.bindInputs(frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, engine: engine, table, uniforms: u.address)
    bindMember(at: 0, table)
    table.setAddress(u.address + UInt64(Self.maintenanceOffset), index: 3)
    encoder.setArgumentTable(table)
    Self.dispatch(Self.clearDispatch(maintenance, pipeline: engine.clearPipeline), engine.clearPipeline, encoder)
    Self.orderDispatches(encoder)
    table.setAddress(u.address + UInt64(Self.parametersOffset), index: 3)
    Self.dispatch(kernelDispatch(pass, pipeline: pipeline, frame: frame), pipeline, encoder)
    Self.orderDispatches(encoder)
    table.setAddress(u.address + UInt64(Self.maintenanceOffset), index: 3)
    Self.dispatch(Self.finalizeDispatch(pipeline: engine.finalizePipeline), engine.finalizePipeline, encoder)
    Self.orderAfterFinalize(encoder, inHostEncoder: host != nil)
    finish(pass, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
  }

  /// Makes this accumulator's Metal 4 argument table now, at start-up, instead
  /// of in its first Metal 4 accumulation. Encodes nothing; calling it again
  /// does nothing. (The uniform ring is still made by the first accumulation
  /// that uses it; a host `MonitorUniformAllocator` needs none.)
  public func prepareMetal4() throws { _ = try argumentTable() }

  // MARK: shared with ScopeGroup

  /// The argument table, made on first use.
  func argumentTable() throws -> any MTL4ArgumentTable {
    if let t = metal4Table { return t }
    let t = try engine.makeArgumentTable(textures: 5, buffers: 6, label: "MonitorKit scope")
    metal4Table = t
    return t
  }

  /// Makes the bins, statistics and LUT textures this accumulation reads resident;
  /// replaced ones are retired until the latest submission completes.
  func updateResidency(burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?) {
    let r = engine.residency
    r.track(bins, in: &resident.bins)
    r.track(statisticsBuffer, in: &resident.statistics)
    r.track(burnInLUT, in: &resident.burn)
    r.track(monitorLUT, in: &resident.monitor)
  }

  /// The bins and statistics only, for a renderer resolving them.
  func updateBinResidency() {
    let r = engine.residency
    r.track(bins, in: &resident.bins)
    r.track(statisticsBuffer, in: &resident.statistics)
  }

  /// Frame and LUT parameters: buffers 0–2 at 256-byte offsets.
  static func writeInputs(
    _ frame: FrameParameters, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, _ base: UnsafeMutableRawPointer
  ) {
    scopeStore(frame, base, 0)
    scopeStore(burnInLUT?.parameters ?? .disabled, base, 256)
    scopeStore(monitorLUT?.parameters ?? .disabled, base, 512)
  }

  /// Textures 0–4 and buffers 0–2, as `bindInputs(_:frame:burnInLUT:monitorLUT:engine:_:)`.
  static func bindInputs(
    frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, engine: ScopeEngine,
    _ table: any MTL4ArgumentTable, uniforms: MTLGPUAddress
  ) {
    table.setTexture((frame.packed ?? engine.placeholderPacked).gpuResourceID, index: 0)
    table.setTexture((frame.luma ?? engine.placeholderPlane).gpuResourceID, index: 1)
    table.setTexture((frame.chroma ?? engine.placeholderPlane).gpuResourceID, index: 2)
    table.setTexture((burnInLUT?.texture ?? engine.placeholderLUT).gpuResourceID, index: 3)
    table.setTexture((monitorLUT?.texture ?? engine.placeholderLUT).gpuResourceID, index: 4)
    table.setAddress(uniforms, index: 0)
    table.setAddress(uniforms + 256, index: 1)
    table.setAddress(uniforms + 512, index: 2)
  }

  func bindMember(at index: Int, _ table: any MTL4ArgumentTable) {
    table.setAddress(bins.gpuAddress, index: Self.memberBins[index])
    table.setAddress(statisticsBuffer.gpuAddress, index: Self.memberStatistics[index])
  }

  static func dispatch(_ d: Dispatch, _ pipeline: MTLComputePipelineState, _ encoder: any MTL4ComputeCommandEncoder) {
    encoder.setComputePipelineState(pipeline)
    if d.threadgroupBytes > 0 { encoder.setThreadgroupMemoryLength(d.threadgroupBytes, index: 0) }
    if d.byThreadgroups {
      encoder.dispatchThreadgroups(threadgroupsPerGrid: d.grid, threadsPerThreadgroup: d.group)
    } else {
      encoder.dispatchThreads(threadsPerGrid: d.grid, threadsPerThreadgroup: d.group)
    }
  }

  /// Write after read and write: earlier encoders' resolves, host shaders and
  /// blits of the bins, and (in a host encoder) its earlier dispatches.
  static func orderBeforeClear(_ encoder: any MTL4ComputeCommandEncoder, inHostEncoder: Bool) {
    encoder.barrier(afterQueueStages: [.dispatch, .fragment, .blit], beforeStages: .dispatch, visibilityOptions: [])
    if inHostEncoder { orderDispatches(encoder) }
  }

  /// Dispatches in one Metal 4 encoder run concurrently: clear, count and finalize are ordered.
  static func orderDispatches(_ encoder: any MTL4ComputeCommandEncoder) {
    encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
  }

  /// Ends an own encoder; in a host encoder, makes the bins visible to its later dispatches.
  static func orderAfterFinalize(_ encoder: any MTL4ComputeCommandEncoder, inHostEncoder: Bool) {
    if inHostEncoder {
      orderDispatches(encoder)
    } else {
      encoder.endEncoding()
    }
  }
}
