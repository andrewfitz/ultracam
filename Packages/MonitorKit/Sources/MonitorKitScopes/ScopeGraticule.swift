import Foundation
import MonitorKitCore

/// The span of the signal-level axis shared by the waveform (vertical) and the
/// histogram (horizontal), in normalized signal (0 black, 1 nominal white).
/// The bins are uniform over it, so it is part of the accumulation.
public enum ScopeLevelRange: String, Codable, Sendable, CaseIterable {
  /// -7% to 109%: every legal 10-bit code (4…1019) with the conventional SDR
  /// graticule range. The default.
  case standard
  /// -10% to 110% (-10…110 IRE for SDR): the range of Ultracam's earlier
  /// MonitorTools scopes, whose graticule marks -10, 0, 50, 100 and 110.
  case minus10To110

  /// The level at the bottom (waveform) or left (histogram) edge of the axis.
  public var low: Double {
    switch self {
    case .standard: return -0.07
    case .minus10To110: return -0.10
    }
  }

  /// The level at the top (waveform) or right (histogram) edge of the axis.
  public var high: Double {
    switch self {
    case .standard: return 1.09
    case .minus10To110: return 1.10
    }
  }
}

/// The signal-level axis shared by the waveform (vertical) and the histogram
/// (horizontal). The statics without a `range` are the default range
/// (`ScopeLevelRange.standard`): normalized signal from -7% to 109%, which
/// covers every legal 10-bit code (4…1019) with the conventional SDR graticule range.
public enum ScopeLevelAxis {
  public static let low = ScopeLevelRange.standard.low
  public static let high = ScopeLevelRange.standard.high

  /// 0 at the bottom of the axis, 1 at the top.
  public static func fraction(ofLevel level: Double) -> Double { fraction(ofLevel: level, range: .standard) }
  public static func level(atFraction fraction: Double) -> Double { level(atFraction: fraction, range: .standard) }

  /// Where a pixel at exactly `level` is drawn on an axis of `bins` uniform
  /// bins: the centre of the bin it is counted in, with the kernels' Float
  /// arithmetic (`mk_levelBin`). Graticule ticks sit there, so legal white
  /// traces on the 100% line at any bin count instead of up to half a bin off.
  public static func drawnFraction(ofLevel level: Double, bins: Int) -> Double {
    drawnFraction(ofLevel: level, bins: bins, range: .standard)
  }

  /// 0 at the bottom of an axis spanning `range`, 1 at the top.
  public static func fraction(ofLevel level: Double, range: ScopeLevelRange) -> Double {
    (level - range.low) / (range.high - range.low)
  }
  public static func level(atFraction fraction: Double, range: ScopeLevelRange) -> Double {
    range.low + fraction * (range.high - range.low)
  }

  /// `drawnFraction(ofLevel:bins:)` on an axis spanning `range`: the same Float
  /// operations as the kernels' bin (`mk_levelBin` with `mk_ScopeParams.level`).
  public static func drawnFraction(ofLevel level: Double, bins: Int, range: ScopeLevelRange) -> Double {
    let n = max(1, bins)
    let scale = Float(Double(n) / (range.high - range.low))
    let bin = min(max(((Float(level) - Float(range.low)) * scale).rounded(.down), 0), Float(n - 1))
    return (Double(bin) + 0.5) / Double(n)
  }
}

/// Vectorscope plane: Cb to the right, Cr up. At 1× the plot spans ±0.55, so
/// the 100% targets of every matrix (|C| ≤ 0.53 for BT.601 red) fit.
public enum VectorscopeGeometry {
  public static let halfExtent = 0.55

  /// Plot units (−1…1 across the plot square) of a Cb/Cr pair at `zoom`.
  public static func plotPosition(cb: Double, cr: Double, zoom: Int) -> SIMD2<Double> {
    SIMD2(cb, cr) * Double(zoom) / halfExtent
  }
}

/// Transfer functions behind the HDR graticules.
public enum ScopeTransfer {
  // SMPTE ST 2084:2014, equations 4.1 and 5.2.
  static let m1 = 2610.0 / 16384
  static let m2 = 2523.0 / 4096 * 128
  static let c1 = 3424.0 / 4096
  static let c2 = 2413.0 / 4096 * 32
  static let c3 = 2392.0 / 4096 * 32

  /// PQ signal E' (0…1) for absolute luminance in cd/m².
  public static func pqSignal(nits: Double) -> Double {
    let y = pow(max(0, nits) / 10000, m1)
    return pow((c1 + c2 * y) / (1 + c3 * y), m2)
  }
  /// Absolute luminance in cd/m² of PQ signal E'.
  public static func pqNits(signal: Double) -> Double {
    let e = pow(min(1, max(0, signal)), 1 / m2)
    return 10000 * pow(max(0, e - c1) / (c2 - c3 * e), 1 / m1)
  }

  // ITU-R BT.2100-2, Table 5 (HLG).
  static let hlgA = 0.17883277
  static let hlgB = 1 - 4 * hlgA
  static let hlgC = 0.5 - hlgA * log(4 * hlgA)

  /// HLG OETF: scene-linear E (0…1) to signal E'.
  public static func hlgOETF(_ e: Double) -> Double {
    let e = max(0, e)
    return e <= 1.0 / 12 ? sqrt(3 * e) : hlgA * log(12 * e - hlgB) + hlgC
  }
  public static func hlgInverseOETF(_ signal: Double) -> Double {
    let s = max(0, signal)
    return s <= 0.5 ? s * s / 3 : (exp((s - hlgC) / hlgA) + hlgB) / 12
  }
  /// System gamma of the HLG OOTF for a display of `peak` cd/m² (BT.2100 note 5f).
  public static func hlgGamma(peak: Double) -> Double { 1.2 + 0.42 * log10(peak / 1000) }
  /// Displayed luminance of an achromatic HLG signal on a `peak`-nit display
  /// with zero black level: Lw · E^γ.
  public static func hlgNits(signal: Double, peak: Double = 1000) -> Double {
    peak * pow(hlgInverseOETF(signal), hlgGamma(peak: peak))
  }
  public static func hlgSignal(nits: Double, peak: Double = 1000) -> Double {
    hlgOETF(pow(max(0, nits) / peak, 1 / hlgGamma(peak: peak)))
  }
}

/// One graticule line on the level axis.
public struct ScopeTick: Equatable, Sendable {
  /// In the scale's unit: percent, code value or cd/m².
  public var value: Double
  /// Normalized signal level.
  public var level: Double
  public var label: String
  public var isMajor: Bool
}

extension WaveformScale {
  /// Graticule ticks for a frame of `range`, inside the default level axis
  /// (`ScopeLevelRange.standard`).
  public func ticks(range: CodeRange) -> [ScopeTick] { ticks(range: range, levelRange: .standard) }

  /// Graticule ticks for a frame of `range` on an axis spanning `levelRange`.
  /// Percent ticks run every 10% from -10 to 110 and keep those on the axis
  /// (0…100 on the standard range, all thirteen on `.minus10To110`).
  public func ticks(range: CodeRange, levelRange: ScopeLevelRange) -> [ScopeTick] {
    func number(_ v: Double) -> String {
      v == v.rounded() ? String(Int(v)) : String(format: v < 1 ? "%.1f" : "%g", v)
    }
    var ticks: [ScopeTick]
    switch self {
    case .percent:
      ticks = stride(from: -10.0, through: 110, by: 10).map {
        ScopeTick(value: $0, level: $0 / 100, label: number($0), isMajor: $0 == 0 || $0 == 50 || $0 == 100)
      }
    case .codeValues:
      let legal = range == .legal
      let codes: [Double] =
        legal ? [4, 64, 128, 256, 384, 512, 640, 768, 896, 940, 1019] : [0, 128, 256, 384, 512, 640, 768, 896, 1023]
      let majors: Set<Double> = legal ? [64, 512, 940] : [0, 512, 1023]
      ticks = codes.map {
        ScopeTick(
          value: $0, level: legal ? ($0 - 64) / 876 : $0 / 1023, label: number($0), isMajor: majors.contains($0))
      }
    case .pqNits:
      let majors: [Double] = [0.1, 1, 10, 100, 203, 1000, 4000, 10000]
      let minors: [Double] = [0.2, 0.5, 2, 5, 20, 50, 500, 2000]
      ticks = (majors.map { ($0, true) } + minors.map { ($0, false) }).sorted { $0.0 < $1.0 }.map {
        ScopeTick(value: $0.0, level: ScopeTransfer.pqSignal(nits: $0.0), label: number($0.0), isMajor: $0.1)
      }
    case .hlgNits:
      let majors: [Double] = [1, 10, 100, 203, 1000]
      let minors: [Double] = [0.1, 2, 5, 20, 50, 500]
      ticks = (majors.map { ($0, true) } + minors.map { ($0, false) }).sorted { $0.0 < $1.0 }.map {
        ScopeTick(value: $0.0, level: ScopeTransfer.hlgSignal(nits: $0.0), label: number($0.0), isMajor: $0.1)
      }
    }
    return Self.clamped(ticks, levelRange)
  }

  /// Ticks for the Cb and Cr panels of the Y'CbCr parade, which plot chroma
  /// offset by one half. Code values label chroma codes (512 + 896·C legal,
  /// 512 + 1023·C full, 10-bit); every other scale labels them in percent,
  /// since luminance has no meaning for chroma.
  public func chromaTicks(range: CodeRange) -> [ScopeTick] { chromaTicks(range: range, levelRange: .standard) }

  /// `chromaTicks(range:)` on an axis spanning `levelRange`.
  public func chromaTicks(range: CodeRange, levelRange: ScopeLevelRange) -> [ScopeTick] {
    guard self == .codeValues else { return WaveformScale.percent.ticks(range: range, levelRange: levelRange) }
    let legal = range == .legal
    let codes: [Double] =
      legal ? [64, 128, 256, 384, 512, 640, 768, 896, 960] : [0, 128, 256, 384, 512, 640, 768, 896, 1023]
    let majors: Set<Double> = legal ? [64, 512, 960] : [0, 512, 1023]
    let span = legal ? 896.0 : 1023.0
    return Self.clamped(
      codes.map {
        ScopeTick(value: $0, level: ($0 - 512) / span + 0.5, label: String(Int($0)), isMajor: majors.contains($0))
      }, levelRange)
  }

  private static func clamped(_ ticks: [ScopeTick], _ range: ScopeLevelRange) -> [ScopeTick] {
    // Code 1019 sits 0.02% above the standard axis top; snap anything that close onto it.
    let tolerance = 0.001
    return ticks.compactMap { tick in
      guard tick.level >= range.low - tolerance, tick.level <= range.high + tolerance else { return nil }
      var t = tick
      t.level = min(range.high, max(range.low, t.level))
      return t
    }
  }
}

/// A colour-bar target: where a bar of `amplitude` lands in Cb/Cr.
public struct VectorscopeTarget: Equatable, Sendable {
  public var name: String
  public var amplitude: Double
  public var rgb: ColorRGB
  public var cb: Double
  public var cr: Double
  /// Degrees counter-clockwise from +Cb, 0 ≤ angle < 360 (Docs/MATH.md section 7).
  public var angle: Double {
    let degrees = atan2(cr, cb) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
  }
  public var magnitude: Double { (cb * cb + cr * cr).squareRoot() }

  /// The six bars (R, Mg, B, Cy, G, Yl) at `amplitude` (0.75 or 1) for `matrix`.
  public static func bars(matrix: YCbCrMatrix, amplitude: Double) -> [VectorscopeTarget] {
    let k = matrix.coefficients
    let bars: [(String, ColorRGB)] = [
      ("R", ColorRGB(r: 1, g: 0, b: 0)), ("Mg", ColorRGB(r: 1, g: 0, b: 1)),
      ("B", ColorRGB(r: 0, g: 0, b: 1)), ("Cy", ColorRGB(r: 0, g: 1, b: 1)),
      ("G", ColorRGB(r: 0, g: 1, b: 0)), ("Yl", ColorRGB(r: 1, g: 1, b: 0)),
    ]
    return bars.map { name, unit in
      let rgb = ColorRGB(r: unit.r * amplitude, g: unit.g * amplitude, b: unit.b * amplitude)
      let y = k.r * rgb.r + k.g * rgb.g + k.b * rgb.b
      return VectorscopeTarget(
        name: name, amplitude: amplitude, rgb: rgb, cb: (rgb.b - y) / (2 * (1 - k.b)),
        cr: (rgb.r - y) / (2 * (1 - k.r)))
    }
  }
}

/// What the bins were measured on; graticule labels depend on it.
public struct ScopeContext: Equatable, Sendable {
  public var range: CodeRange
  /// Matrix used for luma, the Y'CbCr parade and the vectorscope.
  public var matrix: YCbCrMatrix
  public init(range: CodeRange = .legal, matrix: YCbCrMatrix = .bt709) {
    self.range = range
    self.matrix = matrix
  }
}

public enum ScopeLabelAnchor: String, Sendable {
  /// The label's leading edge sits at `position`, vertically centred.
  case leading
  /// The label's top edge is centred on `position`.
  case top
  /// The label's bottom edge is centred on `position`.
  case bottom
  /// The label is centred on `position`.
  case center
}

public enum ScopeLabelRole: String, Sendable { case tick, target, channel }

/// A graticule label for the UI layer to draw as text.
public struct ScopeLabel: Equatable, Sendable {
  public var text: String
  /// Tick value in the scale's unit, or the target amplitude.
  public var value: Double
  /// Normalized viewport coordinates: (0, 0) top left, (1, 1) bottom right.
  public var position: SIMD2<Double>
  public var anchor: ScopeLabelAnchor
  public var role: ScopeLabelRole
  public var isMajor: Bool
}

/// Graticule geometry for one scope in one viewport. Lines are drawn on the
/// GPU; labels are returned as data for the UI to draw. Level ticks sit where
/// a pixel at exactly their level is drawn (`ScopeLevelAxis.drawnFraction`),
/// within half a bin of `ScopeLevelAxis.fraction`, on the settings' `levelRange`.
public struct ScopeGraticule: Equatable, Sendable {
  public enum Element: Equatable, Sendable {
    /// Normalized viewport coordinates.
    case line(from: SIMD2<Double>, to: SIMD2<Double>, major: Bool)
    /// Centre in normalized viewport coordinates; radius as a fraction of the
    /// plot side (min(width, height) pixels).
    case circle(center: SIMD2<Double>, radius: Double, major: Bool)
    /// Square target box; half-size like `circle`'s radius.
    case box(center: SIMD2<Double>, halfSize: Double, major: Bool)
  }

  public var elements: [Element] = []
  public var labels: [ScopeLabel] = []
  /// The plot inside the viewport, normalized: x, y, width, height.
  public var plot = SIMD4<Double>(0, 0, 1, 1)
  public var targets: [VectorscopeTarget] = []

  public init(settings: ScopeSettings, context: ScopeContext, viewportWidth: Double, viewportHeight: Double) {
    let s = settings.normalized()
    let d = s.display
    let width = max(1, viewportWidth), height = max(1, viewportHeight)
    switch s.kind {
    case .waveform:
      // The Y'CbCr parade's chroma panels have their own ticks.
      let ycbcr = s.waveformMode == .ycbcrParade
      let levels = s.levelRange
      var panels = [
        (ticks: d.waveformScale.ticks(range: context.range, levelRange: levels), from: 0.0, to: ycbcr ? 1.0 / 3 : 1)
      ]
      if ycbcr { panels.append((d.waveformScale.chromaTicks(range: context.range, levelRange: levels), 1.0 / 3, 1)) }
      for panel in panels {
        for tick in panel.ticks {
          let y = 1 - ScopeLevelAxis.drawnFraction(ofLevel: tick.level, bins: s.waveformLevels, range: levels)
          elements.append(.line(from: SIMD2(panel.from, y), to: SIMD2(panel.to, y), major: tick.isMajor))
          labels.append(
            ScopeLabel(
              text: tick.label, value: tick.value, position: SIMD2(panel.from, y), anchor: .leading, role: .tick,
              isMajor: tick.isMajor))
        }
      }
      if s.waveformMode.isParade {
        for i in 1...2 {
          let x = Double(i) / 3
          elements.append(.line(from: SIMD2(x, 0), to: SIMD2(x, 1), major: true))
        }
        let names = s.waveformMode == .rgbParade ? ["R", "G", "B"] : ["Y", "Cb", "Cr"]
        for (i, name) in names.enumerated() {
          labels.append(
            ScopeLabel(
              text: name, value: Double(i), position: SIMD2((Double(i) + 0.5) / 3, 0), anchor: .top,
              role: .channel, isMajor: true))
        }
      }
    case .histogram:
      let ticks = d.waveformScale.ticks(range: context.range, levelRange: s.levelRange)
      for tick in ticks {
        let x = ScopeLevelAxis.drawnFraction(ofLevel: tick.level, bins: s.histogramBins, range: s.levelRange)
        elements.append(.line(from: SIMD2(x, 0), to: SIMD2(x, 1), major: tick.isMajor))
        labels.append(
          ScopeLabel(
            text: tick.label, value: tick.value, position: SIMD2(x, 1), anchor: .bottom, role: .tick,
            isMajor: tick.isMajor))
      }
      if s.histogramMode == .rgbParade {
        for i in 1...2 {
          let y = Double(i) / 3
          elements.append(.line(from: SIMD2(0, y), to: SIMD2(1, y), major: true))
        }
      }
    case .vectorscope:
      // The largest centred square.
      let side = min(width, height)
      let plotW = side / width, plotH = side / height
      plot = SIMD4((1 - plotW) / 2, (1 - plotH) / 2, plotW, plotH)
      let zoom = s.vectorscopeZoom
      func point(_ cb: Double, _ cr: Double) -> SIMD2<Double> {
        let p = VectorscopeGeometry.plotPosition(cb: cb, cr: cr, zoom: zoom)
        return SIMD2(0.5 + p.x * plotW / 2, 0.5 - p.y * plotH / 2)
      }
      // Radii are in units of the plot's half side.
      let unit = Double(zoom) / VectorscopeGeometry.halfExtent
      let halfSide = 0.5
      elements.append(.circle(center: SIMD2(0.5, 0.5), radius: 0.5 * unit * halfSide, major: true))
      elements.append(.circle(center: SIMD2(0.5, 0.5), radius: 0.25 * unit * halfSide, major: false))
      // Axes across the plot square; the skin-tone line from the centre to its edge.
      let edge = VectorscopeGeometry.halfExtent / Double(zoom)
      elements.append(.line(from: point(-edge, 0), to: point(edge, 0), major: false))
      elements.append(.line(from: point(0, -edge), to: point(0, edge), major: false))
      if d.showsSkinToneLine {
        let a = d.skinToneAngle * .pi / 180
        let reach = edge / max(abs(cos(a)), abs(sin(a)))
        elements.append(.line(from: point(0, 0), to: point(cos(a) * reach, sin(a) * reach), major: true))
      }
      for amplitude in d.vectorscopeTargets.amplitudes {
        for target in VectorscopeTarget.bars(matrix: context.matrix, amplitude: amplitude) {
          targets.append(target)
          let c = point(target.cb, target.cr)
          // Boxes at 75% and small circles at 100%, so both sets read when shown together.
          if amplitude == 1 {
            elements.append(.circle(center: c, radius: 0.015 * unit * halfSide, major: true))
          } else {
            elements.append(.box(center: c, halfSize: 0.025 * unit * halfSide, major: true))
          }
          let r = max(1e-9, target.magnitude)
          let push = 0.06 / Double(zoom)
          let position = point(target.cb * (1 + push / r), target.cr * (1 + push / r))
          // Zoomed in, outer targets leave the plot; so do their labels. A
          // label just outside the plot edge (100% at 1×) is kept for the UI to clamp.
          guard c.x >= plot.x, c.x <= plot.x + plot.z, c.y >= plot.y, c.y <= plot.y + plot.w else { continue }
          labels.append(
            ScopeLabel(
              text: target.name, value: amplitude, position: position, anchor: .center, role: .target,
              isMajor: amplitude == 0.75 || d.vectorscopeTargets == .percent100))
        }
      }
    }
  }
}
