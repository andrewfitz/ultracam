import Foundation
import Metal
import MonitorKit
import MonitorKitCore

/// Shape of an accumulator's device bins, for hosts that read or draw them
/// in their own shaders. Bin (channel, row, column) is at
/// `(channel * rows + row) * columns + column`, as a 16-bit counter when
/// `bytesPerBin` is 2 (two per little-endian word) or a 32-bit one otherwise.
public struct ScopeBinLayout: Equatable, Sendable {
  public var kind: ScopeKind
  /// Waveform columns per channel, histogram bins, or vectorscope Cb bins.
  public var columns: Int
  /// Waveform levels (bottom to top), vectorscope Cr bins (bottom to top), 1 for the histogram.
  public var rows: Int
  public var channels: Int
  public var bytesPerBin: Int

  public var binCount: Int { channels * rows * columns }
  /// Whole 16-byte rows, so the clear kernel can write `uint4`s.
  public var byteLength: Int { (binCount * bytesPerBin + 15) / 16 * 16 }
  public func index(channel: Int, row: Int, column: Int) -> Int { (channel * rows + row) * columns + column }
}

/// Persistent scope bins for one scope, fed from any frame.
///
/// `accumulate` is called whenever the host wants new scope data (every frame
/// or less often); a renderer can redraw the last bins every frame. Each
/// accumulation clears the bins on the GPU and counts every source pixel. It
/// encodes into the host's command buffer and never commits, waits or reads
/// back. Confined: use from one thread at a time; read statistics from other
/// threads through `statisticsReader`.
public final class ScopeAccumulator {
  public let engine: ScopeEngine
  /// Changes to anything but `display` apply at the next accumulation.
  public var settings: ScopeSettings {
    didSet { settings = settings.normalized() }
  }
  /// Device bins of the last accumulation. Private storage, scope-sized.
  public private(set) var bins: MTLBuffer {
    didSet { barrierResources = [bins, statisticsBuffer] }
  }
  public private(set) var layout: ScopeBinLayout
  /// Two `ScopeStatistics` slots, alternating per accumulation. Shared storage.
  public let statisticsBuffer: MTLBuffer
  /// Reads `statistics` from any thread.
  public let statisticsReader: ScopeStatisticsReader
  /// What the last accumulation measured.
  public private(set) var context = ScopeContext()
  /// Whether the last accumulation applied the burn-in and the monitor LUT.
  /// An output- or monitor-stage scope given no LUT measures the signal
  /// before it, which a host may want to label.
  public private(set) var appliedBurnInLUT = false
  public private(set) var appliedMonitorLUT = false
  /// Counts accumulations; 0 until the first. Skips 0 when it wraps.
  public private(set) var generation: UInt32 = 0
  public private(set) var frameWidth = 0
  public private(set) var frameHeight = 0
  /// Settings of the last accumulation; what the bins hold.
  public private(set) var accumulatedSettings: ScopeSettings

  public var hasData: Bool { generation != 0 }

  /// Bytes of GPU memory this accumulator owns: the bins and the statistics slots.
  public var persistentMemoryBytes: Int { bins.allocatedSize + statisticsBuffer.allocatedSize }

  /// Most pixels a 16-bit device bin may need to hold. Internal so tests can
  /// force the 32-bit path on small frames.
  var packedBinLimit = 0xFFFF
  private var binKey: BinKey
  private var tile = Tile()
  /// What a concurrent encoder's barriers cover; rebuilt only with the bins.
  private var barrierResources: [any MTLResource]
  private var pipeline: MTLComputePipelineState?
  private var pipelineKey: ScopeEngine.ComputeKey?
  /// Whether `pipeline` is the specialized one `pipelineKey` asks for.
  private var pipelineIsFinal = false

  private struct BinKey: Equatable {
    var accumulation: ScopeSettings.AccumulationKey
    var layout: ScopeBinLayout
  }
  private struct Tile {
    var width = 0, height = 0, groups = MTLSize(width: 1, height: 1, depth: 1)
    var threadgroupBytes = 0, columns = 0, rows = 0, run = 0
    var key = SIMD4<Int>.zero
  }

  init(engine: ScopeEngine, settings: ScopeSettings) throws {
    let s = settings.normalized()
    self.engine = engine
    self.settings = s
    accumulatedSettings = s
    layout = Self.layout(for: s, packed: false)
    binKey = BinKey(accumulation: s.accumulationKey, layout: layout)
    let bins = try Self.makeBins(engine.device, layout)
    self.bins = bins
    let length = 2 * ScopeStatisticsWord.slotWords * 4
    guard let stats = engine.device.makeBuffer(length: length, options: .storageModeShared) else {
      throw MonitorKitError.gpu("Cannot allocate the scope statistics buffer.")
    }
    memset(stats.contents(), 0, length)
    statisticsBuffer = stats
    statisticsReader = ScopeStatisticsReader(buffer: stats)
    barrierResources = [bins, stats]
  }

  static func layout(for s: ScopeSettings, packed: Bool) -> ScopeBinLayout {
    switch s.kind {
    case .waveform:
      return ScopeBinLayout(
        kind: .waveform, columns: s.waveformColumnsPerChannel, rows: s.waveformLevels,
        channels: s.waveformMode.channelCount, bytesPerBin: packed ? 2 : 4)
    case .histogram:
      return ScopeBinLayout(
        kind: .histogram, columns: s.histogramBins, rows: 1, channels: s.histogramMode.channelCount,
        bytesPerBin: 4)
    case .vectorscope:
      return ScopeBinLayout(
        kind: .vectorscope, columns: s.vectorscopeSize, rows: s.vectorscopeSize, channels: 1, bytesPerBin: 4)
    }
  }

  static func makeBins(_ device: MTLDevice, _ layout: ScopeBinLayout) throws -> MTLBuffer {
    guard let buffer = device.makeBuffer(length: layout.byteLength, options: .storageModePrivate) else {
      throw MonitorKitError.gpu("Cannot allocate \(layout.byteLength) bytes of scope bins.")
    }
    return buffer
  }

  /// The latest complete statistics, or nil before the first one lands. Read
  /// after the command buffer completes for this accumulation's numbers; while
  /// the GPU writes a slot, the previous accumulation's are returned.
  public var statistics: ScopeStatistics? { statisticsReader.statistics }

  /// The graticule for this scope in a viewport of `width` × `height` pixels.
  public func graticule(width: Double, height: Double, display: ScopeDisplay? = nil) -> ScopeGraticule {
    var s = accumulatedSettings
    if let display { s.display = display } else { s.display = settings.display }
    return ScopeGraticule(settings: s, context: context, viewportWidth: width, viewportHeight: height)
  }

  /// Encodes one accumulation of `settings.stage` with the feed's LUTs, into
  /// its own compute encoder on `commandBuffer`.
  public func accumulate(_ frame: MonitorFrame, feed: MonitorFeed, into commandBuffer: MTLCommandBuffer) throws {
    try accumulate(frame, burnInLUT: feed.burnInLUT, monitorLUT: feed.monitorLUT, into: commandBuffer)
  }

  /// Encodes one accumulation of `settings.stage` with the feed's LUTs, into
  /// the host's compute encoder (see `accumulate(_:burnInLUT:monitorLUT:using:)`).
  public func accumulate(_ frame: MonitorFrame, feed: MonitorFeed, using encoder: MTLComputeCommandEncoder) throws {
    try accumulate(frame, burnInLUT: feed.burnInLUT, monitorLUT: feed.monitorLUT, using: encoder)
  }

  /// Encodes one accumulation into its own compute encoder on `commandBuffer`.
  /// The output stage applies `burnInLUT`, the monitor stage both; pass the
  /// feed's LUTs (or use the `feed:` overload), nil where it has none.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, into commandBuffer: MTLCommandBuffer
  ) throws {
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Cannot create a compute encoder for the scopes.")
    }
    defer { encoder.endEncoding() }
    try accumulate(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, using: encoder)
  }

  /// Encodes one accumulation into the host's compute encoder, so several
  /// scopes (or the host's own kernels) can share it. Sets pipelines, buffer
  /// bindings 0–5 and 11, texture bindings 0–4 and threadgroup memory 0. On a
  /// concurrent encoder it adds barriers on its own bins and statistics only,
  /// so it may be accumulated more than once into one encoder.
  public func accumulate(
    _ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, using encoder: MTLComputeCommandEncoder
  ) throws {
    var pass = try begin(frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
    let key = ScopeEngine.ComputeKey(kernel: pass.settings.kind.kernel, layout: pass.frame.shape.x)
    if pipeline == nil || pipelineKey != key || !pipelineIsFinal {
      (pipeline, pipelineIsFinal) = try engine.computePipeline(for: key)
      pipelineKey = key
    }
    guard let pipeline else { return }
    Self.bindInputs(&pass, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, engine: engine, encoder)
    let concurrent = encoder.dispatchType == .concurrent
    // Also orders this clear after an earlier accumulation into the same encoder.
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }
    encodeClear(&pass, encoder)
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }

    encoder.setBytes(&pass.params, length: MemoryLayout<ScopeKernelParameters>.stride, index: 3)
    encoder.setComputePipelineState(pipeline)
    switch pass.settings.kind {
    case .waveform, .histogram:
      let limit = pass.settings.kind == .waveform ? Self.waveformThreads : Self.histogramThreads
      encoder.setThreadgroupMemoryLength(tile.threadgroupBytes, index: 0)
      encoder.dispatchThreadgroups(
        tile.groups,
        threadsPerThreadgroup: MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, limit), height: 1, depth: 1))
    case .vectorscope:
      let height = max(1, min(Self.vectorscopeGroup.y, pipeline.maxTotalThreadsPerThreadgroup / tile.width))
      encoder.dispatchThreads(
        MTLSize(width: (frame.width + tile.run - 1) / tile.run, height: frame.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: tile.width, height: height, depth: 1))
    }
    if concurrent { encoder.memoryBarrier(resources: barrierResources) }
    encodeFinalize(&pass, lead: nil, encoder)
    finish(pass, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT)
  }

  // MARK: encode steps, shared with ScopeGroup

  /// One accumulation being encoded.
  struct Pass {
    var settings: ScopeSettings
    var frame: FrameParameters
    var params: ScopeKernelParameters
    var generation: UInt32
  }

  /// Shapes the bins for `frame` and computes this accumulation's parameters.
  /// Changes nothing a reader sees until `finish`.
  func begin(_ frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?) throws -> Pass {
    let s = settings
    try prepareBins(settings: s, frame: frame)
    let next = generation >= 0xFFFF_FFFE ? 1 : generation + 1
    let params = kernelParameters(
      settings: s, frame: frame, burnInLUT: burnInLUT, monitorLUT: monitorLUT, generation: next)
    return Pass(settings: s, frame: frame.parameters, params: params, generation: next)
  }

  /// The frame and LUT bindings every accumulation kernel reads: textures 0–4, bytes 0–2.
  static func bindInputs(
    _ pass: inout Pass, frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?, engine: ScopeEngine,
    _ encoder: MTLComputeCommandEncoder
  ) {
    var burn = burnInLUT?.parameters ?? .disabled
    var monitor = monitorLUT?.parameters ?? .disabled
    encoder.setTexture(frame.packed ?? engine.placeholderPacked, index: 0)
    encoder.setTexture(frame.luma ?? engine.placeholderPlane, index: 1)
    encoder.setTexture(frame.chroma ?? engine.placeholderPlane, index: 2)
    encoder.setTexture(burnInLUT?.texture ?? engine.placeholderLUT, index: 3)
    encoder.setTexture(monitorLUT?.texture ?? engine.placeholderLUT, index: 4)
    encoder.setBytes(&pass.frame, length: MemoryLayout<FrameParameters>.stride, index: 0)
    encoder.setBytes(&burn, length: MemoryLayout<LUTParameters>.stride, index: 1)
    encoder.setBytes(&monitor, length: MemoryLayout<LUTParameters>.stride, index: 2)
  }

  /// Zeroes the bins and opens the statistics slot. Binds bytes 3 and buffers 4–5.
  func encodeClear(_ pass: inout Pass, _ encoder: MTLComputeCommandEncoder) {
    encoder.setBytes(&pass.params, length: MemoryLayout<ScopeKernelParameters>.stride, index: 3)
    encoder.setBuffer(bins, offset: 0, index: 4)
    encoder.setBuffer(statisticsBuffer, offset: 0, index: 5)
    let clear = engine.clearPipeline
    encoder.setComputePipelineState(clear)
    let clearThreads = max(Int(pass.params.tile.w) / 4, ScopeStatisticsWord.slotWords)
    encoder.dispatchThreads(
      MTLSize(width: clearThreads, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(256, clear.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
  }

  /// Histogram peaks and the closing stamp; with `lead`, first copies the
  /// statistics a fused pass measured into that accumulator's slot. Binds
  /// bytes 3 and buffers 4, 5 and 11.
  func encodeFinalize(_ pass: inout Pass, lead: (buffer: MTLBuffer, slot: UInt32)?, _ encoder: MTLComputeCommandEncoder) {
    var params = pass.params
    params.luts.w = lead.map { $0.slot + 1 } ?? 0
    encoder.setBytes(&params, length: MemoryLayout<ScopeKernelParameters>.stride, index: 3)
    encoder.setBuffer(bins, offset: 0, index: 4)
    encoder.setBuffer(statisticsBuffer, offset: 0, index: 5)
    encoder.setBuffer(lead?.buffer ?? statisticsBuffer, offset: 0, index: 11)
    let finalize = engine.finalizePipeline
    encoder.setComputePipelineState(finalize)
    encoder.dispatchThreadgroups(
      MTLSize(width: 1, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(1024, finalize.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
  }

  /// Publishes what an encoded accumulation measured.
  func finish(_ pass: Pass, frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?) {
    let s = pass.settings
    generation = pass.generation
    frameWidth = frame.width
    frameHeight = frame.height
    let (burnApplied, monitorApplied) = lutApplied(stage: s.stage, burnInLUT, monitorLUT)
    appliedBurnInLUT = burnApplied
    appliedMonitorLUT = monitorApplied
    let measured = ScopeContext(range: frame.signal.range, matrix: matrix(settings: s, frame: frame, burnInLUT, monitorLUT))
    if context != measured { context = measured }
    if accumulatedSettings != s { accumulatedSettings = s }
  }

  func lutApplied(stage: SignalStage, _ burnInLUT: MonitorLUT?, _ monitorLUT: MonitorLUT?) -> (Bool, Bool) {
    let burn = stage != .source && burnInLUT != nil
    let monitor = stage == .monitor && monitorLUT != nil
    return (burn, monitor)
  }

  func matrix(settings s: ScopeSettings, frame: MonitorFrame, _ burnInLUT: MonitorLUT?, _ monitorLUT: MonitorLUT?)
    -> YCbCrMatrix
  {
    let (burn, monitor) = lutApplied(stage: s.stage, burnInLUT, monitorLUT)
    return s.colorimetry.matrix(source: frame.signal.matrix, lutApplied: burn || monitor)
  }

  /// Recreates the bins only when their shape changes, and the dispatch
  /// geometry only when the frame size or bin shape changes.
  func prepareBins(settings s: ScopeSettings, frame: MonitorFrame) throws {
    var packed = false
    if s.kind == .waveform {
      // A 16-bit device bin can hold every pixel of one scope column.
      let columns = s.waveformColumnsPerChannel
      let perColumn = (frame.width + columns - 1) / columns
      packed = perColumn * frame.height <= packedBinLimit
    }
    let key = BinKey(accumulation: s.accumulationKey, layout: Self.layout(for: s, packed: packed))
    if key != binKey {
      // Same size, different shape (e.g. RGB to Y'CbCr parade): reuse the buffer.
      if key.layout.byteLength != bins.length { bins = try Self.makeBins(engine.device, key.layout) }
      layout = key.layout
      binKey = key
      tile = Tile()
    }
    let tileKey = SIMD4(frame.width, frame.height, layout.columns * 4 + layout.channels, layout.rows)
    if tile.key != tileKey { tile = makeTile(settings: s, frame: frame, key: tileKey) }
  }

  private func makeTile(settings s: ScopeSettings, frame: MonitorFrame, key: SIMD4<Int>) -> Tile {
    var t = Tile()
    t.key = key
    let fw = frame.width, fh = frame.height
    let budget = engine.threadgroupMemoryBudget
    switch s.kind {
    case .waveform:
      let columns = layout.columns, levels = layout.rows, channels = layout.channels
      // Scope columns per threadgroup: as many as fit the private bins.
      var k = (budget / (levels * channels * 2)) & ~1
      k = min(max(k, 2), columns)
      let perColumn = (fw + columns - 1) / columns
      let tileWidth = max(1, (k * fw + columns - 1) / columns)
      // Rows per band: about `targetPixels` per threadgroup, and few enough
      // that no private 16-bit counter can wrap.
      let maxRows = max(1, 0xFFFF / max(1, perColumn))
      let rows = min(fh, maxRows, max(1, Self.targetPixelsPerThreadgroup / tileWidth))
      t.columns = k
      t.rows = rows
      t.threadgroupBytes = (k * levels * channels * 2 + 15) / 16 * 16
      t.groups = MTLSize(width: (columns + k - 1) / k, height: (fh + rows - 1) / rows, depth: 1)
    case .histogram:
      t.width = Self.histogramTile.x
      t.height = Self.histogramTile.y
      // At most 4096 bins × 3 channels × 2 bytes = 24 KB, inside every Apple GPU's budget.
      t.threadgroupBytes = min(budget, (layout.columns * layout.channels * 2 + 15) / 16 * 16)
      t.groups = MTLSize(width: (fw + t.width - 1) / t.width, height: (fh + t.height - 1) / t.height, depth: 1)
    case .vectorscope:
      t.run = Self.vectorscopeRun
      t.width = Self.vectorscopeGroup.x
    }
    return t
  }

  // Dispatch geometry, from GPU-timestamp sweeps on an M4 Max at 4K (the
  // results were flat within ±10% around these values).
  static let targetPixelsPerThreadgroup = 16384
  static let waveformThreads = 512
  static let histogramThreads = 256
  /// 128 × 128 = 16384 pixels: well under the 65535 a private 16-bit counter holds.
  static let histogramTile = SIMD2(128, 128)
  /// Pixels per histogram work item, side by side along a row.
  static let pixelRun = 4
  /// Pixels per vectorscope thread; repeated bins fold into one atomic.
  static let vectorscopeRun = 8
  static let vectorscopeGroup = SIMD2(32, 8)

  /// The kernel parameters for `frame`; internal so tests can mirror them exactly.
  func kernelParameters(
    settings s: ScopeSettings, frame: MonitorFrame, burnInLUT: MonitorLUT?, monitorLUT: MonitorLUT?,
    generation: UInt32
  ) -> ScopeKernelParameters {
    var p = ScopeKernelParameters()
    let (burn, monitor) = lutApplied(stage: s.stage, burnInLUT, monitorLUT)
    let k = matrix(settings: s, frame: frame, burnInLUT, monitorLUT).coefficients
    let stage: UInt32 = s.stage == .source ? 0 : (s.stage == .output ? 1 : 2)
    p.shape = SIMD4(s.kind.shaderCode, s.shaderMode, stage, UInt32(layout.channels))
    let slot = UInt32(generation & 1) * UInt32(ScopeStatisticsWord.slotWords)
    p.bins = SIMD4(UInt32(layout.columns), UInt32(layout.rows), layout.bytesPerBin == 2 ? 1 : 0, slot)
    let words = UInt32(layout.byteLength / 4)
    switch s.kind {
    case .waveform: p.tile = SIMD4(UInt32(tile.columns), UInt32(tile.rows), 0, words)
    case .histogram: p.tile = SIMD4(UInt32(tile.width), UInt32(tile.height), UInt32(Self.pixelRun), words)
    case .vectorscope: p.tile = SIMD4(0, 0, UInt32(tile.run), words)
    }
    p.luts = SIMD4(burn ? 1 : 0, monitor ? 1 : 0, generation, 0)
    let levels = s.kind == .waveform ? layout.rows : layout.columns
    p.level = SIMD4(
      Float(ScopeLevelAxis.low), Float(Double(levels) / (ScopeLevelAxis.high - ScopeLevelAxis.low)),
      Float(1 / Double(max(1, frame.width))), 0)
    // The transport luma is the stage's Y' when nothing re-graded the pixel and
    // the scope weighs with the frame's own matrix.
    let transport = !burn && !monitor && matrix(settings: s, frame: frame, burnInLUT, monitorLUT) == frame.signal.matrix
    p.weights = SIMD4(Float(k.r), Float(k.g), Float(k.b), transport ? 1 : 0)
    let side = Double(layout.columns)
    p.chroma = SIMD4(
      Float(1 / (2 * (1 - k.b))), Float(1 / (2 * (1 - k.r))),
      Float(side * Double(s.vectorscopeZoom) / (2 * VectorscopeGeometry.halfExtent)), Float(side / 2))
    p.clip = SIMD4(Float(s.clipHighPercent / 100), Float(s.clipLowPercent / 100), 0, 0)
    return p
  }
}

extension ScopeKind {
  var shaderCode: UInt32 {
    switch self {
    case .waveform: return 0
    case .vectorscope: return 1
    case .histogram: return 2
    }
  }
}

extension ScopeSettings {
  /// `mk_ScopeParams.shape.y`.
  var shaderMode: UInt32 {
    switch kind {
    case .waveform:
      switch waveformMode {
      case .luma: return 0
      case .rgbOverlay: return 1
      case .rgbParade: return 2
      case .ycbcrParade: return 3
      }
    case .histogram:
      switch histogramMode {
      case .luma: return 0
      case .rgbOverlay: return 1
      case .rgbParade: return 2
      }
    case .vectorscope: return 0
    }
  }
}
