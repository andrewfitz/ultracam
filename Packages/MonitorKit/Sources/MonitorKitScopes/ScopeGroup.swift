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
/// stay usable on their own. Confined like its accumulators.
public final class ScopeGroup {
  public let engine: ScopeEngine
  public let accumulators: [ScopeAccumulator]

  /// Which members the last accumulation fused, by index into `accumulators`.
  private var fused = Members()

  private var pipeline: MTLComputePipelineState?
  private var pipelineKey: ScopeEngine.ComputeKey?
  private var tile = Tile()
  /// Every member's bins and statistics; rebuilt only when a member's bins are.
  private var barrierResources: [any MTLResource] = []

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
  private struct Members {
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
    (0..<3).contains { fused.member($0).map { accumulators[$0] === accumulator } ?? false }
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

  /// Encodes one accumulation of every member with the feed's LUTs, into its
  /// own compute encoder on `commandBuffer`.
  public func accumulate(_ frame: MonitorFrame, feed: MonitorFeed, into commandBuffer: MTLCommandBuffer) throws {
    try accumulate(frame, burnInLUT: feed.burnInLUT, monitorLUT: feed.monitorLUT, into: commandBuffer)
  }

  /// Encodes one accumulation of every member with the feed's LUTs, into the host's compute encoder.
  public func accumulate(_ frame: MonitorFrame, feed: MonitorFeed, using encoder: MTLComputeCommandEncoder) throws {
    try accumulate(frame, burnInLUT: feed.burnInLUT, monitorLUT: feed.monitorLUT, using: encoder)
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
  /// Sets pipelines, buffer bindings 0–11, texture bindings 0–4 and
  /// threadgroup memory 0. On a concurrent encoder it adds barriers on the
  /// members' bins and statistics only.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, using encoder: MTLComputeCommandEncoder
  ) throws {
    let members = fusable()
    var fusedPipeline: MTLComputePipelineState?
    if members.count >= 2 {
      let key = ScopeEngine.ComputeKey(kernel: .fused, layout: frame.layout.scopeLayoutCode, scopes: members.scopes)
      if pipeline == nil || pipelineKey != key {
        pipeline = try engine.fusedPipeline(for: key)
        pipelineKey = pipeline == nil ? nil : key
      }
      fusedPipeline = pipeline
    }
    if let fusedPipeline {
      try encodeFused(
        frame, members: members, pipeline: fusedPipeline, burnInLUT: burnInLUT, monitorLUT: monitorLUT, encoder: encoder)
    } else {
      fused = Members()
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
  private func fusable() -> Members {
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

  private func encodeFused(
    _ frame: MonitorFrame, members: Members, pipeline: MTLComputePipelineState, burnInLUT: MonitorLUT?,
    monitorLUT: MonitorLUT?, encoder: MTLComputeCommandEncoder
  ) throws {
    // One pass per fused scope, in kind order (no closures or collections:
    // this runs every frame and must not allocate).
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
      // The first member leads: its slot receives the statistics.
      if i < leadIndex { (leadIndex, lead) = (i, slot) }
    }
    guard leadIndex != .max, var leadPass = lead == 0 ? passes.0 : (lead == 1 ? passes.1 : passes.2) else { return }
    if barrierResourcesAreStale { rebuildBarrierResources() }
    let leader = accumulators[leadIndex]
    ScopeAccumulator.bindInputs(&leadPass, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, engine: engine, encoder)
    let concurrent = encoder.dispatchType == .concurrent
    // Also orders these clears after an earlier accumulation into the same encoder.
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }
    if let i = members.waveform, var p = passes.0 { accumulators[i].encodeClear(&p, encoder) }
    if let i = members.histogram, var p = passes.1 { accumulators[i].encodeClear(&p, encoder) }
    if let i = members.vectorscope, var p = passes.2 { accumulators[i].encodeClear(&p, encoder) }
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }

    updateTile(frame: frame, members: members)
    encoder.setComputePipelineState(pipeline)
    encoder.setBytes(&leadPass.params, length: MemoryLayout<ScopeKernelParameters>.stride, index: 3)
    encoder.setBuffer(leader.statisticsBuffer, offset: 0, index: 5)
    if let i = members.waveform, var p = passes.0?.params {
      p.tile.x = UInt32(tile.columns)
      p.tile.y = UInt32(tile.rows)
      encoder.setBuffer(accumulators[i].bins, offset: 0, index: 4)
      encoder.setBytes(&p, length: MemoryLayout<ScopeKernelParameters>.stride, index: 8)
    }
    if let i = members.histogram, var p = passes.1?.params {
      encoder.setBuffer(accumulators[i].bins, offset: 0, index: 6)
      encoder.setBytes(&p, length: MemoryLayout<ScopeKernelParameters>.stride, index: 9)
    }
    if let i = members.vectorscope, var p = passes.2?.params {
      encoder.setBuffer(accumulators[i].bins, offset: 0, index: 7)
      encoder.setBytes(&p, length: MemoryLayout<ScopeKernelParameters>.stride, index: 10)
    }
    encoder.setThreadgroupMemoryLength(tile.threadgroupBytes, index: 0)
    encoder.dispatchThreadgroups(
      tile.groups,
      threadsPerThreadgroup: MTLSize(
        width: min(pipeline.maxTotalThreadsPerThreadgroup, Self.threads), height: 1, depth: 1))
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }

    let source = (buffer: leader.statisticsBuffer, slot: leadPass.params.bins.w)
    slot = 0
    while slot < 3 {
      defer { slot += 1 }
      guard let i = members.member(slot), var p = slot == 0 ? passes.0 : (slot == 1 ? passes.1 : passes.2) else {
        continue
      }
      accumulators[i].encodeFinalize(&p, lead: i == leadIndex ? nil : source, encoder)
      accumulators[i].finish(p, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
    }
    fused = members
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
