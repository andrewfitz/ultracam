import Foundation
import Metal
import Synchronization
import simd

/// Mirrors `mk_ScopeParams` in MKScopes.msl. 16-byte rows.
struct ScopeKernelParameters {
  var shape = SIMD4<UInt32>.zero
  var bins = SIMD4<UInt32>.zero
  var tile = SIMD4<UInt32>.zero
  var luts = SIMD4<UInt32>.zero
  var level = SIMD4<Float>.zero
  var weights = SIMD4<Float>.zero
  var chroma = SIMD4<Float>.zero
  var clip = SIMD4<Float>.zero
}

/// Mirrors `mk_ScopeMaintain`: the clear and finalize of up to three
/// accumulations (a fused group's members in kind order, or one accumulator)
/// in one dispatch each.
struct ScopeMaintenanceParameters {
  /// xyz: `uint4` words of each member's bins to clear (0: none), w: members
  /// present (bit k: member k).
  var words = SIMD4<UInt32>.zero
  /// xyz: each member's statistics slot, in words.
  var slots = SIMD4<UInt32>.zero
  /// xyz: each member's generation (the slot stamps).
  var generation = SIMD4<UInt32>.zero
  /// xyz: histogram bins per channel (0: not a histogram), w: the member
  /// whose slot the fused pass measured into, + 1 (0: each measured its own).
  var histogram = SIMD4<UInt32>.zero
  /// xyz: channels of each member.
  var channels = SIMD4<UInt32>.zero
}

/// Mirrors `mk_ScopeShape`. Positions in viewport pixels.
struct ScopeShape {
  var geometry = SIMD4<Float>.zero
  var style = SIMD4<Float>.zero
}

/// Mirrors `mk_ScopeDraw`, the fragment shader's parameters (`setFragmentBytes`
/// per draw, a uniform ring slot on Metal 4).
struct ScopeDrawParameters: Equatable {
  var viewport = SIMD4<Float>.zero
  var plot = SIMD4<Float>.zero
  var shape = SIMD4<UInt32>.zero
  var flags = SIMD4<UInt32>.zero
  var intensity = SIMD4<Float>.zero
  var background = SIMD4<Float>.zero
  var chroma = SIMD4<Float>.zero
  /// xy: trace texels per unit of plot (or of a parade panel) on an axis drawn
  /// from the bins, zw: the texel offset. A minified axis was reduced to plot
  /// pixels by the resolve and is read texel by texel instead (`flags.w`).
  var traceMap = SIMD4<Float>.zero
  /// The plot's pixels, in viewport pixels: xy the first, zw one past the last
  /// (those whose centre is inside it). Integers, so a reduced axis's texel of
  /// each pixel is exactly the one the resolve wrote for it.
  var pixels = SIMD4<UInt32>.zero
  var color0 = SIMD4<Float>.zero
  var color1 = SIMD4<Float>.zero
  var color2 = SIMD4<Float>.zero
  var graticuleColor = SIMD4<Float>.zero
  /// The output encoding of the composited colour (`ScopeRenderer.colorPipeline`):
  /// x: `MonitorColorPipeline.Transfer` code (0: as authored), y: graphics white
  /// in cd/m², z: HLG nominal peak, w: HLG system gamma.
  var encode = SIMD4<Float>.zero
  /// Linear Rec.709 to the target primaries, by rows.
  var toTarget0 = SIMD4<Float>(1, 0, 0, 0)
  var toTarget1 = SIMD4<Float>(0, 1, 0, 0)
  var toTarget2 = SIMD4<Float>(0, 0, 1, 0)
  /// Luminance weights of the target primaries (the HLG inverse OOTF).
  var targetWeights = SIMD4<Float>.zero
}

/// Mirrors `mk_ScopeGraticuleParams`; bound only while the graticule is rasterized.
struct ScopeGraticuleParameters {
  static let maximumShapes = 64
  /// The plot in viewport pixels: x, y, width, height.
  var plot = SIMD4<Float>.zero
  /// xy: viewport size in pixels, z: shape count.
  var size = SIMD4<Float>.zero
  var shapes = InlineArray<64, ScopeShape>(repeating: ScopeShape())
}

/// Mirrors `mk_ScopeResolve`.
struct ScopeResolveParameters: Equatable {
  var shape = SIMD4<UInt32>.zero
  var bins = SIMD4<UInt32>.zero
  /// xy: trace texels written, zw: source texels per axis.
  var size = SIMD4<UInt32>.zero
  var intensity = SIMD4<Float>.zero
  /// xy: plot pixels a minified axis is reduced to (0: one texel per source
  /// texel), z: parade panels across x (1 or 3), w: 1 when footprints start half
  /// a source texel in (vectorscope).
  var reduce = SIMD4<UInt32>.zero
}

/// Words of one statistics slot. Mirrors the `MK_ST_*` constants.
enum ScopeStatisticsWord {
  static let begin = 0, count = 1, minimum = 2, maximum = 3, sumLow = 4, sumHigh = 5
  static let high = 6, low = 10, peak = 14, end = 17, peakAll = 18, check = 19
  static let slotWords = 32

  /// `mk_statsChecksum`: words `begin`…`peakAll` but `end`, FNV-1a by word with a
  /// final avalanche. A copy whose words do not all belong to one accumulation fails it.
  static func checksum(_ words: InlineArray<32, UInt32>) -> UInt32 {
    var h: UInt32 = 2_166_136_261
    var i = begin
    while i <= peakAll {
      if i != end { h = (h ^ words[i]) &* 16_777_619 }
      i += 1
    }
    h ^= h >> 16
    h = h &* 0x85EB_CA6B
    h ^= h >> 13
    h = h &* 0xC2B2_AE35
    return h ^ (h >> 16)
  }
  static let extremeScale = 1_048_576.0
  static let sumScale = 4096.0
}

/// Numbers measured on the GPU during an accumulation, read from a small
/// shared buffer without stalling the frame path. Levels are normalized
/// (0 black, 1 nominal white).
public struct ScopeStatistics: Equatable, Sendable {
  /// The accumulation these numbers belong to (`ScopeAccumulator.generation`).
  public var generation: UInt32
  /// Pixels measured: the frame's width × height when every pixel was read.
  public var pixelCount: Int
  /// Stage luma, quantized to 2^-20 for the extremes and 2^-12 for the mean,
  /// clamped to -1…3.
  public var lumaMinimum: Double
  public var lumaMaximum: Double
  public var lumaAverage: Double
  /// Fraction of pixels at or above `clipHighPercent`: R, G, B, luma.
  public var clippedHigh: SIMD4<Double>
  /// Fraction of pixels at or below `clipLowPercent`: R, G, B, luma.
  public var clippedLow: SIMD4<Double>
  /// Largest histogram bin per channel; zero for other scopes.
  public var histogramPeak: SIMD3<UInt32>

  /// Decodes one slot; nil while the GPU is writing it. A seqlock read: the
  /// words are copied between two reads of the stamps, and the copy counts only
  /// if no accumulation opened the slot in between and its checksum holds (the
  /// GPU's stores reach the host in no guaranteed order, so the stamps alone
  /// can pass a copy that caught a word of the next accumulation).
  init?(slot: UnsafePointer<UInt32>) {
    typealias W = ScopeStatisticsWord
    let end = slot[W.end]
    guard end != 0, end != 0xFFFF_FFFF else { return nil }
    atomicMemoryFence(ordering: .acquiring)
    var words = InlineArray<32, UInt32>(repeating: 0)
    var i = 0
    while i < W.slotWords {
      words[i] = slot[i]
      i += 1
    }
    atomicMemoryFence(ordering: .acquiring)
    guard words[W.begin] == end, slot[W.begin] == end, slot[W.end] == end, words[W.check] == W.checksum(words)
    else { return nil }
    self.init(words: words)
  }

  private init(words slot: InlineArray<32, UInt32>) {
    typealias W = ScopeStatisticsWord
    let count = Int(slot[W.count])
    generation = slot[W.begin]
    pixelCount = count
    guard count > 0 else {
      lumaMinimum = 0
      lumaMaximum = 0
      lumaAverage = 0
      clippedHigh = .zero
      clippedLow = .zero
      histogramPeak = .zero
      return
    }
    lumaMinimum = Double(~slot[W.minimum]) / W.extremeScale - 1
    lumaMaximum = Double(slot[W.maximum]) / W.extremeScale - 1
    let sum = Double(UInt64(slot[W.sumHigh]) << 32 | UInt64(slot[W.sumLow]))
    lumaAverage = sum / Double(count) / W.sumScale - 1
    let n = Double(count)
    clippedHigh = SIMD4(
      Double(slot[W.high]) / n, Double(slot[W.high + 1]) / n, Double(slot[W.high + 2]) / n,
      Double(slot[W.high + 3]) / n)
    clippedLow = SIMD4(
      Double(slot[W.low]) / n, Double(slot[W.low + 1]) / n, Double(slot[W.low + 2]) / n,
      Double(slot[W.low + 3]) / n)
    histogramPeak = SIMD3(slot[W.peak], slot[W.peak + 1], slot[W.peak + 2])
  }
}

/// Reads an accumulator's statistics from any thread, e.g. a UI polling clip
/// percentages while the render thread accumulates. It only reads the shared
/// statistics buffer, which the GPU writes as a seqlock.
public final class ScopeStatisticsReader: Sendable {
  /// Two `ScopeStatistics` slots, alternating per accumulation. Shared storage.
  public nonisolated(unsafe) let buffer: MTLBuffer
  /// The newest statistics returned so far, so reads never go back in time: a
  /// reader paused between the two slots can otherwise find the newer one
  /// reopened and only the older one complete.
  private let latest = Mutex<ScopeStatistics?>(nil)

  init(buffer: MTLBuffer) { self.buffer = buffer }

  /// The latest complete statistics, or nil before the first one lands. A
  /// slot the GPU is writing is skipped, so this returns the one before it.
  public var statistics: ScopeStatistics? {
    let words = UnsafePointer(buffer.contents().bindMemory(to: UInt32.self, capacity: 2 * ScopeStatisticsWord.slotWords))
    let a = ScopeStatistics(slot: words)
    let b = ScopeStatistics(slot: words + ScopeStatisticsWord.slotWords)
    // Generations count up and wrap: the newer one is a small step ahead.
    func newer(_ x: ScopeStatistics, _ y: ScopeStatistics) -> Bool { Int32(bitPattern: x.generation &- y.generation) > 0 }
    let read: ScopeStatistics?
    if let a, let b { read = newer(a, b) ? a : b } else { read = a ?? b }
    return latest.withLock { cached in
      if let read, cached.map({ !newer($0, read) }) ?? true { cached = read }
      return cached
    }
  }
}
