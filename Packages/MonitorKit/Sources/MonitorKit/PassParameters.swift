import MonitorKitCore

/// Mirrors `mk_PassParams` in MKMonitor.msl field for field (16-byte rows). A
/// test checks every offset against the compiled shader's reflection. Built by
/// `MonitorPass` only when its inputs change.
public struct PassParameters: Sendable {
  public static let maximumBands = 16

  public var displayToPicture = SIMD4<Float>.zero
  public var imageRect = SIMD4<Float>.zero
  public var navigatorRect = SIMD4<Float>.zero
  public var navigatorToPicture = SIMD4<Float>.zero
  public var navigatorVisible = SIMD4<Float>.zero
  public var viewport = SIMD4<Float>.zero
  public var guideRect = SIMD4<Float>.zero
  public var matte = SIMD4<Float>.zero
  public var zebra0 = SIMD4<Float>.zero
  public var zebra1 = SIMD4<Float>.zero
  public var zebra = SIMD4<UInt32>.zero
  public var modes = SIMD4<UInt32>.zero
  /// x: offset stops, y: ARRI tables are full range, z: the picture stage (0 source,
  /// 1 output, 2 monitor; `MK_PICTURE_STAGE` of a host compiling MKMonitor itself).
  public var falseColor = SIMD4<Float>.zero
  public var gamutWeights = SIMD4<Float>.zero
  public var focus = SIMD4<Float>.zero
  public var focusColor = SIMD4<Float>.zero
  public var guide = SIMD4<Float>.zero
  public var guideColor = SIMD4<Float>.zero
  public var display = SIMD4<Float>.zero
  public var flags = SIMD4<UInt32>.zero
  /// x: burn-in LUT on, y: monitor LUT on, z: source log curve, w: source display transfer.
  public var luts = SIMD4<UInt32>.zero
  public var bandEdges = InlineArray<16, SIMD4<Float>>(repeating: .zero)
  /// In target values.
  public var bandColors = InlineArray<16, SIMD4<Float>>(repeating: .zero)
  /// x: display transform, y: picture transfer, z: target transfer (0: none), w: overlay
  /// transfer (0: as authored; the colours are encoded on the CPU, so the shader
  /// does not read it); `MonitorColorPipeline` codes.
  public var color = SIMD4<UInt32>(0, 1, 0, 0)
  /// x: roll-off, y: clip indicators on, z: clip channels (bit 0 R, 1 G, 2 B, 3 Y'), w: clip stage.
  public var colorFlags = SIMD4<UInt32>.zero
  /// x: graphics white cd/m², y: its inverse, z: HLG output peak, w: its system gamma.
  public var colorLevels = SIMD4<Float>(203, 1 / 203, 1000, 1.2)
  /// x: HLG decode peak, y: its system gamma, z: 1 / scene light of 75% HLG.
  public var hlgSource = SIMD4<Float>(1000, 1.2, 1, 0)
  /// The BT.2408 Annex 5 EETF: x: PQ signal of the source peak, y: maxLum, z: knee start, w: identity.
  public var toneMap = SIMD4<Float>(1, 1, 1, 1)
  /// Display assist v1: x: knee scene light, y: knee signal, z: shoulder exponent, w: log2 of x.
  public var assist = SIMD4<Float>.zero
  public var pictureWeights = SIMD4<Float>.zero
  public var targetWeights = SIMD4<Float>.zero
  /// Rows: linear picture primaries to target primaries.
  public var toTarget: InlineArray<3, SIMD4<Float>> = [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)]
  /// Rows: linear source gamut to Rec.709 for the display transforms.
  public var transformMatrix: InlineArray<3, SIMD4<Float>> = [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)]
  /// Graphics white in target values.
  public var overlayWhite = SIMD4<Float>(1, 1, 1, 1)
  public var zebraColors = InlineArray<2, SIMD4<Float>>(repeating: .zero)
  /// Navigator frame and visible box.
  public var navigatorColors = InlineArray<2, SIMD4<Float>>(repeating: .zero)
  /// x: over at or above (percent, +inf when off), y: under at or below (-inf when off), z: opacity.
  public var clipLevels = SIMD4<Float>.zero
  /// 0-7 over, 8-15 under, indexed by the flagged channels' bits (0: luma alone). In target values.
  public var clipColors = InlineArray<16, SIMD4<Float>>(repeating: .zero)
  /// White-point trim: xyz the linear-light gains in the picture primaries, w the
  /// picture's transfer code (`MonitorColorPipeline.Transfer`; 0: no trim).
  public var whiteGain = SIMD4<Float>(1, 1, 1, 0)
  /// The same gains on the signal of a power-law picture (BT.1886: g^(1/2.4),
  /// gamma 2.2: g^(1/2.2), linear: g), where a signal gain is exact.
  public var whiteSignalGain = SIMD4<Float>(1, 1, 1, 0)
  /// Correctly rounded reciprocals the shader divides by exactly (`mk_quotient`):
  /// x 1 / the frame's luma span (`FrameParameters.levels.y`), y 1 / its chroma
  /// span (`levels.w`), z 1 / its kg (`matrix.y`), w 1 / the zebra stripe period.
  /// `MonitorPass` sets them from the frame and the zebras. Zero (the default, as
  /// in a host's own parameters) makes the shader compute them per pixel: the same
  /// pixels, slower.
  public var reciprocals = SIMD4<Float>.zero

  public init() {}

  /// `reciprocals` for `frame`'s parameters and the stripe period `zebra.w`.
  static func reciprocals(_ frame: FrameParameters, zebraPeriod: UInt32) -> SIMD4<Float> {
    func inverse(_ v: Float) -> Float { v == 0 || !v.isFinite ? 0 : 1 / v }
    return SIMD4(inverse(frame.levels.y), inverse(frame.levels.w), inverse(frame.matrix.y), inverse(Float(zebraPeriod)))
  }
}

/// Mirrors `mk_Guides` in MKMonitor.msl: the guide strokes the picture pass
/// draws analytically, bound with `setFragmentBytes` (2592 B, under the 4 KB
/// limit) or, on Metal 4, from the pass's uniforms.
///
/// A host that fills `counts`, `reach` and `lines` itself (the fused tier) gets
/// every stroke drawn: `cells` starts all set (search everywhere). Call
/// `updateCells()` after editing `lines` to let clear cells skip the search.
public struct GuideParameters: Sendable {
  public static let maximumLines = 128
  public static let maximumOthers = 8

  /// x: verticals, y: horizontals, z: others.
  public var counts = SIMD4<UInt32>.zero
  /// x: search radius in pixels, y: outline width.
  public var reach = SIMD4<Float>.zero
  /// Verticals (x, y0, y1, half width) sorted by x, then horizontals (y, x0, x1, half width) sorted by y.
  public var lines = InlineArray<128, SIMD4<Float>>(repeating: .zero)
  /// Pairs of (x0, y0, x1, y1), (half width, 0, 0, 0): diagonals and dots.
  public var others = InlineArray<16, SIMD4<Float>>(repeating: .zero)
  /// Which `cellSize`-pixel cells an axis-aligned stroke can reach: bit k of words
  /// 0–31 covers viewport x in [16k, 16k + 16) for the verticals, words 32–63 y for
  /// the horizontals. A pixel in a clear cell skips that axis's search, so a
  /// cleared bit under a stroke hides it.
  public var cells = InlineArray<64, UInt32>(repeating: .max)

  /// Pixels per cell of `cells` along each axis (1024 cells, 16 384 pixels).
  public static let cellSize = 16

  public init() {}

  /// Packs `raster`'s segments. `outline` is the dark outline's width in pixels.
  public init(_ raster: GuideRaster, outline: Double) {
    var verticals: [SIMD4<Float>] = [], horizontals: [SIMD4<Float>] = [], others: [GuideRaster.Segment] = []
    var widest = 0.0
    for s in raster.segments {
      widest = max(widest, s.halfWidth)
      if s.x0 == s.x1 && s.y0 != s.y1 {
        verticals.append(SIMD4(Float(s.x0), Float(min(s.y0, s.y1)), Float(max(s.y0, s.y1)), Float(s.halfWidth)))
      } else if s.y0 == s.y1 && s.x0 != s.x1 {
        horizontals.append(SIMD4(Float(s.y0), Float(min(s.x0, s.x1)), Float(max(s.x0, s.x1)), Float(s.halfWidth)))
      } else {
        others.append(s)
      }
    }
    verticals.sort { $0.x < $1.x }
    horizontals.sort { $0.x < $1.x }
    let lines = (verticals + horizontals).prefix(Self.maximumLines)
    for (i, l) in lines.enumerated() { self.lines[i] = l }
    let nv = min(verticals.count, Self.maximumLines)
    counts.x = UInt32(nv)
    counts.y = UInt32(lines.count - nv)
    for (i, s) in others.prefix(Self.maximumOthers).enumerated() {
      self.others[2 * i] = SIMD4(Float(s.x0), Float(s.y0), Float(s.x1), Float(s.y1))
      self.others[2 * i + 1] = SIMD4(Float(s.halfWidth), 0, 0, 0)
    }
    counts.z = UInt32(min(others.count, Self.maximumOthers))
    reach = SIMD4(Float(widest + outline + 1), Float(outline), 0, 0)
    updateCells()
  }

  /// Recomputes `cells` from `counts`, `reach` and `lines`: a bit is set wherever
  /// a vertical (by x) or horizontal (by y) stroke can cover a pixel centre.
  public mutating func updateCells() {
    cells = InlineArray(repeating: 0)
    // A stroke at s affects pixel centres within `reach` of it; one more pixel of
    // margin keeps float rounding on the safe side.
    let margin = Double(reach.x) + 1
    // Each count clamped before adding: a hand-filled struct may hold anything.
    let nv = Int(min(counts.x, UInt32(Self.maximumLines)))
    let total = min(nv + Int(min(counts.y, UInt32(Self.maximumLines))), Self.maximumLines)
    var i = 0
    while i < total {
      let axis = i < nv ? 0 : 1, position = Double(lines[i].x)
      if !position.isFinite {
        i += 1
        continue
      }
      let low = Int(max(-1, ((position - margin) / Double(Self.cellSize)).rounded(.down)))
      let high = Int(min(1024, ((position + margin) / Double(Self.cellSize)).rounded(.down)))
      var k = max(0, low)
      while k <= min(high, 1023) {
        cells[axis * 32 + k / 32] |= 1 << UInt32(k % 32)
        k += 1
      }
      i += 1
    }
  }
}

/// False-colour measures, matching `MK_FC_*` in MKMonitor.msl.
enum FalseColorMeasureCode: UInt32 {
  case off = 0, sony, arriStyle, arriLogC, elZone, stageIRE, stageStops
}
