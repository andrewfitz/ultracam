import Foundation
import Metal
import MonitorKit
import MonitorKitCore

/// Several scopes of one feed accumulated together: the usual waveform,
/// vectorscope and histogram of one signal stage in a single pass that decodes
/// each pixel, applies the stage's LUTs and measures its statistics once.
///
/// One waveform, one histogram and one vectorscope are fused when they share
/// the first member's stage, colorimetry and clip levels (and the histogram's
/// private bins fit beside the waveform's); every other member is accumulated
/// on its own in the same encoder. Each member ends up exactly as if it had
/// been accumulated alone: bins, statistics, generation and context. Members
/// stay usable on their own. Confined like its accumulators. Encodes on Metal 4
/// too (`accumulate(…, into: MonitorSubmission)`), with the same results.
public final class ScopeGroup {
  public let engine: ScopeEngine
  public let accumulators: [ScopeAccumulator]

  /// Which members the last accumulation fused, by index into `accumulators`.
  var fused = Members()

  private var pipeline: MTLComputePipelineState?
  private var pipelineKey: ScopeEngine.ComputeKey?
  /// Whether `pipeline` (nil: unfused) is final for `pipelineKey`, so the engine is not asked again.
  private var pipelineIsFinal = false
  private var tile = Tile()
  /// Every member's bins and statistics; rebuilt only when a member's bins are.
  private var barrierResources: [any MTLResource] = []

  // Metal 4 state of the fused pass, made on first use.
  var ring = MonitorUniformRing(slotLength: ScopeGroup.uniformLength, label: "MonitorKit scope group uniforms")
  var uniformGeneration: UInt64 = 0
  var metal4Table: (any MTL4ArgumentTable)?

  private struct Tile {
    var key = Key()
    var columns = 0, rows = 0, threadgroupBytes = 0
    var groups = MTLSize(width: 1, height: 1, depth: 1)

    struct Key: Equatable {
      var width = 0, height = 0
      var waveform: ScopeBinLayout?
      var histogram: ScopeBinLayout?
    }
  }

  /// Which member feeds each fused scope.
  struct Members {
    var waveform: Int?
    var histogram: Int?
    var vectorscope: Int?
    var count: Int { (waveform == nil ? 0 : 1) + (histogram == nil ? 0 : 1) + (vectorscope == nil ? 0 : 1) }
    var scopes: FusedScopes {
      var s: FusedScopes = []
      if waveform != nil { s.insert(.waveform) }
      if histogram != nil { s.insert(.histogram) }
      if vectorscope != nil { s.insert(.vectorscope) }
      return s
    }
    func contains(_ i: Int) -> Bool { waveform == i || histogram == i || vectorscope == i }
    /// Slot 0, 1, 2: the waveform, histogram and vectorscope member.
    func member(_ slot: Int) -> Int? { slot == 0 ? waveform : (slot == 1 ? histogram : vectorscope) }
  }

  /// Members the last accumulation fused into one pass (0 when none were).
  public var fusedMemberCount: Int { fused.count }

  /// Whether the last accumulation fused `accumulator` with other members.
  public func isFused(_ accumulator: ScopeAccumulator) -> Bool {
    var i = 0
    while i < 3 {
      if let m = fused.member(i), accumulators[m] === accumulator { return true }
      i += 1
    }
    return false
  }

  init(engine: ScopeEngine, accumulators: [ScopeAccumulator]) throws {
    guard accumulators.allSatisfy({ $0.engine === engine }) else {
      throw MonitorKitError.gpu("A scope group's accumulators must come from its engine.")
    }
    guard Set(accumulators.map(ObjectIdentifier.init)).count == accumulators.count else {
      throw MonitorKitError.gpu("A scope group lists an accumulator more than once.")
    }
    self.engine = engine
    self.accumulators = accumulators
    rebuildBarrierResources()
  }

  deinit {
    guard metal4Table != nil else { return }
    ring.retire(to: engine.residency)
    engine.residency.retire(metal4Table, resident: nil)
  }

  /// Encodes one accumulation of every member with the feed's LUTs, into its
  /// own compute encoder on `commandBuffer`. `monitorLUTEnabled` is the
  /// surface's `MonitorState.monitorLUT`, as for `ScopeAccumulator`.
  public func accumulate(
    _ frame: MonitorFrame, feed: MonitorFeed, monitorLUTEnabled: Bool = true, into commandBuffer: MTLCommandBuffer
  ) throws {
    try accumulate(
      frame, burnInLUT: feed.burnInLUT, monitorLUT: monitorLUTEnabled ? feed.monitorLUT : nil, into: commandBuffer)
  }

  /// Encodes one accumulation of every member with the feed's LUTs, into the host's compute encoder.
  public func accumulate(
    _ frame: MonitorFrame, feed: MonitorFeed, monitorLUTEnabled: Bool = true, using encoder: MTLComputeCommandEncoder
  ) throws {
    try accumulate(frame, burnInLUT: feed.burnInLUT, monitorLUT: monitorLUTEnabled ? feed.monitorLUT : nil, using: encoder)
  }

  /// Encodes one accumulation of every member into its own compute encoder.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, into commandBuffer: MTLCommandBuffer
  ) throws {
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a compute encoder for the scopes.")
    }
    defer { encoder.endEncoding() }
    try accumulate(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, using: encoder)
  }

  /// Encodes one accumulation of every member into the host's compute encoder.
  /// Sets pipelines, buffer bindings 0–10 and 12–14, texture bindings 0–4 and
  /// threadgroup memory 0. On a concurrent encoder it adds barriers on the
  /// members' bins and statistics only.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, using encoder: MTLComputeCommandEncoder
  ) throws {
    let members = fusable()
    // Set again only once a fused pass is encoded, so a throw leaves no stale fusion.
    fused = Members()
    if let fusedPipeline = fusedPipeline(frame, members) {
      try encodeFused(
        frame, members: members, pipeline: fusedPipeline, burnInLUT: burnInLUT, monitorLUT: monitorLUT, encoder: encoder)
    }
    // Index loops: iterators allocate in unoptimized builds, and this runs every frame.
    var i = 0
    while i < accumulators.count {
      if !fused.contains(i) {
        try accumulators[i].accumulate(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, using: encoder)
      }
      i += 1
    }
  }

  /// The fused kernel for `members` (at least two), once it can be used. Nil
  /// while it builds or after its builds failed: every member is then
  /// accumulated on its own.
  func fusedPipeline(_ frame: MonitorFrame, _ members: Members) -> MTLComputePipelineState? {
    guard members.count >= 2 else { return nil }
    let key = ScopeEngine.ComputeKey(kernel: .fused, layout: frame.layout.scopeLayoutCode, scopes: members.scopes)
    if pipelineKey != key || !pipelineIsFinal {
      (pipeline, pipelineIsFinal) = engine.fusedPipeline(for: key)
      pipelineKey = key
    }
    return pipeline
  }

  /// Builds the fused pipelines the current settings need for frames of
  /// `layouts` on this thread, so the first frames are fused.
  public func prepare(layouts: [PixelLayout]) throws {
    let members = fusable()
    guard members.count >= 2 else { return }
    for layout in layouts {
      _ = try engine.computePipeline(
        ScopeEngine.ComputeKey(
          kernel: .fused, layout: engine.specialization == .off ? nil : layout.scopeLayoutCode, scopes: members.scopes))
    }
  }

  /// The first waveform, histogram and vectorscope that measure what the first
  /// member measures, the histogram only if its private bins fit.
  func fusable() -> Members {
    var m = Members()
    guard !accumulators.isEmpty else { return m }
    let lead = accumulators[0].settings
    var i = 0
    while i < accumulators.count {
      let s = accumulators[i].settings
      if s.stage == lead.stage, s.colorimetry == lead.colorimetry, s.clipHighPercent == lead.clipHighPercent,
        s.clipLowPercent == lead.clipLowPercent
      {
        switch s.kind {
        case .waveform where m.waveform == nil: m.waveform = i
        case .histogram where m.histogram == nil: m.histogram = i
        case .vectorscope where m.vectorscope == nil: m.vectorscope = i
        default: break
        }
      }
      i += 1
    }
    if let h = m.histogram {
      let s = accumulators[h].settings
      let histogramBytes = Self.histogramBytes(bins: s.histogramBins, channels: s.histogramMode.channelCount)
      let budget = engine.threadgroupMemoryBudget
      // At most half the budget, so the waveform keeps wide column bands.
      var fits = histogramBytes <= budget / 2
      if let w = m.waveform {
        let ws = settingsLayout(accumulators[w].settings)
        let columns = Self.waveformColumns(budget: budget, histogramBytes: histogramBytes, layout: ws)
        fits = fits && Self.threadgroupBytes(columns: columns, layout: ws, histogramBytes: histogramBytes) <= budget
      }
      if !fits { m.histogram = nil }
    }
    return m
  }

  /// The waveform bin shape `s` accumulates into (rows, channels and columns
  /// do not depend on the frame).
  private func settingsLayout(_ s: ScopeSettings) -> ScopeBinLayout { ScopeAccumulator.layout(for: s, packed: false) }

  static func histogramBytes(bins: Int, channels: Int) -> Int { (bins * channels * 2 + 15) / 16 * 16 }

  /// Scope columns per fused threadgroup: as many as fit beside the histogram, at least 2.
  static func waveformColumns(budget: Int, histogramBytes: Int, layout w: ScopeBinLayout) -> Int {
    let k = ((budget - histogramBytes) / (w.rows * w.channels * 2)) & ~1
    return min(max(k, 2), w.columns)
  }

  static func threadgroupBytes(columns k: Int, layout w: ScopeBinLayout, histogramBytes: Int) -> Int {
    (k * w.rows * w.channels * 2 + 15) / 16 * 16 + histogramBytes
  }

  /// One fused accumulation being encoded: a pass per fused scope (kind order),
  /// the lead (the first member, whose slot receives the statistics) and the
  /// clear and finalize parameters.
  struct Fused {
    var passes: (ScopeAccumulator.Pass?, ScopeAccumulator.Pass?, ScopeAccumulator.Pass?)
    var leadIndex: Int
    var leadPass: ScopeAccumulator.Pass
    var maintenance: ScopeMaintenanceParameters

    func pass(_ slot: Int) -> ScopeAccumulator.Pass? { slot == 0 ? passes.0 : (slot == 1 ? passes.1 : passes.2) }
  }

  /// Begins every fused member's accumulation and shapes the dispatch. No
  /// closures or collections: this runs every frame and must not allocate.
  func beginFused(_ frame: MonitorFrame, members: Members, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?) throws
    -> Fused?
  {
    var passes: (ScopeAccumulator.Pass?, ScopeAccumulator.Pass?, ScopeAccumulator.Pass?) = (nil, nil, nil)
    var leadIndex = Int.max, lead = 0
    var slot = 0
    while slot < 3 {
      defer { slot += 1 }
      guard let i = members.member(slot) else { continue }
      let pass = try accumulators[i].begin(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
      switch slot {
      case 0: passes.0 = pass
      case 1: passes.1 = pass
      default: passes.2 = pass
      }
      if i < leadIndex { (leadIndex, lead) = (i, slot) }
    }
    guard leadIndex != .max, let leadPass = lead == 0 ? passes.0 : (lead == 1 ? passes.1 : passes.2) else { return nil }
    // One clear and one finalize for all members. Member k of those kernels is
    // fused slot k (kind order), so its bins sit where the fused kernel reads
    // them; an absent kind's bindings repeat the lead's, so none is missing.
    var f = Fused(passes: passes, leadIndex: leadIndex, leadPass: leadPass, maintenance: ScopeMaintenanceParameters())
    slot = 0
    while slot < 3 {
      if let i = members.member(slot), let p = f.pass(slot) { accumulators[i].addMember(p, to: &f.maintenance, at: slot) }
      slot += 1
    }
    f.maintenance.histogram.w = UInt32(lead + 1)
    updateTile(frame: frame, members: members)
    return f
  }

  /// The waveform member's parameters with the fused tile (buffer 8).
  func fusedWaveformParameters(_ f: Fused) -> ScopeKernelParameters? {
    guard var p = f.passes.0?.params else { return nil }
    p.tile.x = UInt32(tile.columns)
    p.tile.y = UInt32(tile.rows)
    return p
  }

  var fusedDispatch: (grid: MTLSize, threadgroupBytes: Int) { (tile.groups, tile.threadgroupBytes) }

  /// Publishes every fused member's accumulation.
  func finishFused(_ f: Fused, members: Members, frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?) {
    var slot = 0
    while slot < 3 {
      if let i = members.member(slot), let p = f.pass(slot) {
        accumulators[i].finish(p, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
      }
      slot += 1
    }
    fused = members
  }

  private func encodeFused(
    _ frame: MonitorFrame, members: Members, pipeline: MTLComputePipelineState, burnInLUT: MonitorLUT?,
    monitorLUT: MonitorLUT?, encoder: MTLComputeCommandEncoder
  ) throws {
    guard var f = try beginFused(frame, members: members, burnInLUT: burnInLUT, monitorLUT: monitorLUT) else { return }
    if barrierResourcesAreStale { rebuildBarrierResources() }
    let leader = accumulators[f.leadIndex]
    ScopeAccumulator.bindInputs(&f.leadPass, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, engine: engine, encoder)
    var slot = 0
    while slot < 3 {
      if let i = members.member(slot) {
        accumulators[i].bindMember(at: slot, encoder)
      } else {
        leader.bindMember(at: slot, encoder)
      }
      slot += 1
    }
    let concurrent = encoder.dispatchType == .concurrent
    // Also orders these clears after an earlier accumulation into the same encoder.
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }
    ScopeAccumulator.encodeClear(&f.maintenance, pipeline: engine.groupClearPipeline, encoder)
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }

    encoder.setComputePipelineState(pipeline)
    encoder.setBytes(&f.leadPass.params, length: MemoryLayout<ScopeKernelParameters>.stride, index: 3)
    encoder.setBuffer(leader.statisticsBuffer, offset: 0, index: 14)
    // Bins 4, 6 and 7 are bound as members 0–2 above.
    if var p = fusedWaveformParameters(f) {
      encoder.setBytes(&p, length: MemoryLayout<ScopeKernelParameters>.stride, index: 8)
    }
    if var p = f.passes.1?.params { encoder.setBytes(&p, length: MemoryLayout<ScopeKernelParameters>.stride, index: 9) }
    if var p = f.passes.2?.params { encoder.setBytes(&p, length: MemoryLayout<ScopeKernelParameters>.stride, index: 10) }
    encoder.setThreadgroupMemoryLength(tile.threadgroupBytes, index: 0)
    encoder.dispatchThreadgroups(
      tile.groups,
      threadsPerThreadgroup: MTLSize(
        width: min(pipeline.maxTotalThreadsPerThreadgroup, Self.threads), height: 1, depth: 1))
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }

    ScopeAccumulator.encodeFinalize(&f.maintenance, pipeline: engine.groupFinalizePipeline, encoder)
    finishFused(f, members: members, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
  }

  /// The fused dispatch geometry: the waveform's column bands (with room for
  /// the histogram's private bins), or the histogram's tiles without one.
  private func updateTile(frame: MonitorFrame, members: Members) {
    let key = Tile.Key(
      width: frame.width, height: frame.height, waveform: members.waveform.map { accumulators[$0].layout },
      histogram: members.histogram.map { accumulators[$0].layout })
    guard key != tile.key else { return }
    var t = Tile()
    t.key = key
    let fw = frame.width, fh = frame.height
    let histogramBytes = key.histogram.map { Self.histogramBytes(bins: $0.columns, channels: $0.channels) } ?? 0
    if let w = key.waveform {
      // The same arithmetic `fusable` admitted the histogram with.
      let k = Self.waveformColumns(budget: engine.threadgroupMemoryBudget, histogramBytes: histogramBytes, layout: w)
      let perColumn = (fw + w.columns - 1) / w.columns
      let tileWidth = max(1, (k * fw + w.columns - 1) / w.columns)
      // No private 16-bit counter may wrap: a waveform column's or the histogram's.
      var maxRows = max(1, 0xFFFF / max(1, perColumn))
      if histogramBytes > 0 { maxRows = min(maxRows, max(1, 0xFFFF / tileWidth)) }
      let rows = min(fh, maxRows, max(1, ScopeAccumulator.targetPixelsPerThreadgroup / tileWidth))
      t.columns = k
      t.rows = rows
      t.threadgroupBytes = Self.threadgroupBytes(columns: k, layout: w, histogramBytes: histogramBytes)
      t.groups = MTLSize(width: (w.columns + k - 1) / k, height: (fh + rows - 1) / rows, depth: 1)
    } else {
      let side = ScopeAccumulator.histogramTile
      t.threadgroupBytes = max(16, histogramBytes)
      t.groups = MTLSize(width: (fw + side.x - 1) / side.x, height: (fh + side.y - 1) / side.y, depth: 1)
    }
    assert(t.threadgroupBytes <= max(engine.threadgroupMemoryBudget, 16), "fused bins exceed threadgroup memory")
    tile = t
  }

  private var barrierResourcesAreStale: Bool {
    guard barrierResources.count == 2 * accumulators.count else { return true }
    var i = 0
    while i < accumulators.count {
      if barrierResources[2 * i] !== accumulators[i].bins { return true }
      i += 1
    }
    return false
  }

  private func rebuildBarrierResources() {
    barrierResources = accumulators.flatMap { [$0.bins as any MTLResource, $0.statisticsBuffer] }
  }

  /// Threads per fused threadgroup.
  static let threads = 512
}
