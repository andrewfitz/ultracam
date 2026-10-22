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
  public var bandColors = InlineArray<16, SIMD4<Float>>(repeating: .zero)

  public init() {}
}

/// Mirrors `mk_Guides` in MKMonitor.msl: the guide strokes the picture pass
/// draws analytically, bound with `setFragmentBytes` (2.3 KB, under the 4 KB limit).
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

  public init() {}

  /// Packs `raster`'s segments. `outline` is the dark outline's width in pixels.
  init(_ raster: GuideRaster, outline: Double) {
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
  }
}

/// False-colour measures, matching `MK_FC_*` in MKMonitor.msl.
enum FalseColorMeasureCode: UInt32 {
  case off = 0, sony, arriStyle, arriLogC, elZone, stageIRE, stageStops
}
