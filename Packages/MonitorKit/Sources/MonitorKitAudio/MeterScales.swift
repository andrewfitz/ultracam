import Foundation

// What a meter view needs besides the readings: the scale's marks, how a
// value maps onto the meter's travel, and its colour zones. Pure data, built
// once (not on the audio path); a UI draws it however it likes.
//
// Marks follow the standards' scale drawings as published for each meter
// type (IEC 60268-18 digital peak meters, IEC 60268-10 / EBU Tech 3205 PPMs,
// IEC 60268-17 VU, EBU Tech 3341 loudness scales). The IEC texts themselves
// are paywalled, so the IEC marks are as the BBC, EBU and the secondary
// literature list them (e.g. the comparison of scales in "Peak programme
// meter", Wikipedia). Zone colours are not standardized anywhere; the
// thresholds here sit on the levels the standards do define (alignment,
// permitted maximum level, R 128 target and maximum true peak), and a host
// can replace them.

/// The unit a scale's values are in.
public enum MeterScaleUnit: Sendable, Hashable {
  /// dB re full scale: sample peak, RMS.
  case dBFS
  /// dB re full scale, true peak (BS.1770 Annex 2).
  case dBTP
  /// Volume units (0 VU at the reference level).
  case vu
  /// BBC PPM mark number, 1 to 7 (IEC 60268-10 Type IIa).
  case ppmMark
  /// dB relative to the alignment level (EBU and Nordic PPM scales, TEST = 0).
  case dBRelativeToAlignment
  /// dB relative to the permitted maximum level (DIN PPM scale, PML = 0).
  case dBRelativeToPML
  /// Loudness units relative to the target (EBU R 128: 0 LU = -23 LUFS).
  case lu
  /// Absolute loudness, LUFS.
  case lufs
}

/// How a value maps onto the meter's travel, 0 (bottom) to 1 (top).
public enum MeterScaleMapping: Sendable, Hashable {
  /// Linear in the value between the scale's bounds (dB-linear scales).
  case linear
  /// Proportional to amplitude, 10^(value / 20), with the top of the scale
  /// at 1: a moving coil deflecting with current, as on a VU meter's face.
  case amplitude
  /// Linear between (value, position) breakpoints in ascending order; a
  /// semi-logarithmic scale such as the DIN PPM's.
  case piecewise([MeterScalePoint])
}

public struct MeterScalePoint: Sendable, Hashable {
  public var value: Double
  public var position: Double
  public init(_ value: Double, _ position: Double) {
    self.value = value
    self.position = position
  }
}

public struct MeterScaleMark: Sendable, Hashable {
  /// In the scale's unit.
  public var value: Double
  /// The text printed at the mark; nil for an unlabelled tick.
  public var label: String?
  public var isMajor: Bool

  public init(value: Double, label: String? = nil, isMajor: Bool = true) {
    self.value = value
    self.label = label
    self.isMajor = isMajor
  }
}

/// What a zone means; a UI picks the colours (conventionally green, a
/// target colour, amber and red).
public enum MeterZoneKind: Sendable, Hashable, CaseIterable {
  /// Normal programme level.
  case normal
  /// The level aimed for (around the loudness target).
  case target
  /// Above the permitted maximum or target tolerance: allowed on peaks, watch it.
  case caution
  /// Beyond what the standard permits (over the maximum true peak, past the PML).
  case over
}

public struct MeterZone: Sendable, Hashable {
  /// The zone covers `lower ..< upper`, in the scale's unit.
  public var lower: Double
  public var upper: Double
  public var kind: MeterZoneKind

  public init(lower: Double, upper: Double, kind: MeterZoneKind) {
    self.lower = lower
    self.upper = upper
    self.kind = kind
  }
}

/// The two EBU Tech 3341 loudness scale ranges.
public enum LoudnessScaleRange: Sendable, Hashable {
  /// EBU +9: -18 LU to +9 LU (-41 to -14 LUFS at the -23 LUFS target), for most programmes.
  case ebuPlus9
  /// EBU +18: -36 LU to +18 LU (-59 to -5 LUFS), for programmes with a wide loudness range.
  case ebuPlus18
}

/// A meter's scale: range, marks, mapping onto the travel and colour zones.
public struct MeterScale: Sendable, Hashable {
  public var unit: MeterScaleUnit
  public var lowerBound: Double
  public var upperBound: Double
  public var mapping: MeterScaleMapping
  /// Ascending by value.
  public var marks: [MeterScaleMark]
  /// Ascending and contiguous over the scale's bounds.
  public var zones: [MeterZone]
  /// The alignment level (EBU R 68 / Tech 3205 AL, TEST, 0 VU, the loudness
  /// target) in the scale's unit, for a UI that marks it; nil when off the scale.
  public var alignment: Double?
  /// The permitted maximum level (AL + 9 dB, PPM 6, the DIN 0), in the scale's
  /// unit; nil when the scale has none or it is off the scale.
  public var permittedMaximum: Double?
  /// Converts a meter reading into this scale's unit: `value = readingOffset
  /// + readingScale * reading`. Readings are what `AudioChannelLevels` and
  /// `LoudnessSnapshot` hold (dBFS, dBTP, VU, PPM dB re alignment, LUFS).
  public var readingScale: Double
  public var readingOffset: Double

  public init(
    unit: MeterScaleUnit, lowerBound: Double, upperBound: Double, mapping: MeterScaleMapping = .linear,
    marks: [MeterScaleMark], zones: [MeterZone], alignment: Double? = nil, permittedMaximum: Double? = nil,
    readingScale: Double = 1, readingOffset: Double = 0
  ) {
    self.unit = unit
    self.lowerBound = lowerBound
    self.upperBound = upperBound
    self.mapping = mapping
    self.marks = marks
    self.zones = zones
    self.alignment = alignment
    self.permittedMaximum = permittedMaximum
    self.readingScale = readingScale
    self.readingOffset = readingOffset
  }

  /// A meter reading in this scale's unit. `-infinity` (silence) stays `-infinity`.
  public func value(forReading reading: Double) -> Double {
    readingOffset + readingScale * reading
  }

  /// Where `value` (in the scale's unit) sits on the travel: 0 at the
  /// bottom, 1 at the top, clamped. Silence and NaN sit at 0. On an
  /// amplitude scale 0 is no signal, so the lowest mark sits above it.
  public func position(of value: Double) -> Double {
    guard !value.isNaN, value > -.infinity else { return 0 }
    let p: Double
    switch mapping {
    case .linear:
      p = (value - lowerBound) / (upperBound - lowerBound)
    case .amplitude:
      p = pow(10, (value - upperBound) / 20)
    case .piecewise(let points):
      p = Self.interpolate(points, value)
    }
    return min(max(p, 0), 1)
  }

  /// `position(of: value(forReading:))`.
  public func position(forReading reading: Double) -> Double {
    position(of: value(forReading: reading))
  }

  /// The zone `value` falls in; values beyond the bounds take the outermost zone.
  public func zone(of value: Double) -> MeterZoneKind? {
    guard !zones.isEmpty else { return nil }
    if value.isNaN || value < zones[0].upper { return zones[0].kind }
    var i = 1
    while i < zones.count {
      if value < zones[i].upper { return zones[i].kind }
      i += 1
    }
    return zones[zones.count - 1].kind
  }

  private static func interpolate(_ points: [MeterScalePoint], _ value: Double) -> Double {
    guard !points.isEmpty else { return 0 }
    if value <= points[0].value { return points[0].position }
    var i = 1
    while i < points.count {
      let a = points[i - 1]
      let b = points[i]
      if value <= b.value {
        return b.value > a.value ? a.position + (value - a.value) / (b.value - a.value) * (b.position - a.position) : b.position
      }
      i += 1
    }
    return points[points.count - 1].position
  }
}

extension MeterScale {
  /// A digital peak meter in dBFS or dBTP, dB-linear with 0 dBFS at the
  /// top. Labelled marks as IEC 60268-18 draws them: every 5 dB down to -40,
  /// every 10 dB below (0, -5 ... -40, -50, -60), shifted with the top of
  /// `range`; unlabelled ticks at the alignment level and the permitted
  /// maximum level (alignment + 9 dB, EBU R 68 / Tech 3205) where they are
  /// not already labelled marks (`alignment` and `permittedMaximum` carry
  /// them either way). Zones: normal
  /// below the PML, caution up to `maximumPeak`, over above it (EBU R 128:
  /// -1 dBTP for true peak; 0 or the clip level suits a sample-peak meter).
  public static func digitalPeak(
    unit: MeterScaleUnit = .dBTP, range: ClosedRange<Double> = -60...0, alignment: AlignmentLevel = .ebu,
    maximumPeak: Double = -1
  ) -> MeterScale {
    precondition(unit == .dBFS || unit == .dBTP, "a digital peak scale is in dBFS or dBTP")
    let pml = alignment.dBFS + 9
    var marks: [MeterScaleMark] = []
    let top = (range.upperBound / 5).rounded(.down) * 5
    var v = top
    while v >= range.lowerBound {
      marks.append(MeterScaleMark(value: v, label: Self.format(v)))
      v -= v > top - 40 ? 5 : 10
    }
    for tick in [alignment.dBFS, pml] where range.contains(tick) && !marks.contains(where: { $0.value == tick }) {
      marks.append(MeterScaleMark(value: tick, label: nil, isMajor: false))
    }
    marks.sort { $0.value < $1.value }
    let caution = min(max(pml, range.lowerBound), range.upperBound)
    let over = min(max(maximumPeak, caution), range.upperBound)
    return MeterScale(
      unit: unit, lowerBound: range.lowerBound, upperBound: range.upperBound, marks: marks,
      zones: Self.zones([(range.lowerBound, .normal), (caution, .caution), (over, .over)], top: range.upperBound),
      alignment: range.contains(alignment.dBFS) ? alignment.dBFS : nil,
      permittedMaximum: range.contains(pml) ? pml : nil)
  }

  /// IEC 60268-17 VU meter: -20 to +3 VU, the classic face (-20, -10, -7, -5,
  /// -3, -2, -1, 0, +1, +2, +3), deflection proportional to voltage, red from 0 VU.
  public static let vu = MeterScale(
    unit: .vu, lowerBound: -20, upperBound: 3, mapping: .amplitude,
    marks: [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3].map {
      MeterScaleMark(value: $0, label: $0 > 0 ? "+\(Int($0))" : "\(Int($0))")
    },
    zones: [MeterZone(lower: -20, upper: 0, kind: .normal), MeterZone(lower: 0, upper: 3, kind: .over)],
    alignment: 0)

  /// The quasi-peak meter's own scale (IEC 60268-10, EBU Tech 3205):
  /// - Type I (DIN 45406): -50 to +5 dB re PML, alignment at -9; semi-log,
  ///   the top 10 dB taking about half the travel (the breakpoints are a
  ///   rendering of the DIN face's shape, not normative); over above 0.
  /// - Type IIa (BBC): marks 1 to 7, 4 dB apart, alignment 4, PML 6 (+8 dB); over above 6.
  /// - Type IIb (EBU): -12 to +12 dB re alignment (TEST), 4 dB labels, 2 dB
  ///   ticks and a +9 tick at the PML; over above +9.
  public static func ppm(_ type: PPMType) -> MeterScale {
    switch type {
    case .typeI:
      let labelled: [Double] = [-50, -40, -30, -20, -10, -5, 0, 5]
      var marks = labelled.map { MeterScaleMark(value: $0, label: $0 > 0 ? "+\(Int($0))" : "\(Int($0))") }
      marks.append(MeterScaleMark(value: -9, label: nil, isMajor: false))
      marks.sort { $0.value < $1.value }
      return MeterScale(
        unit: .dBRelativeToPML, lowerBound: -50, upperBound: 5,
        mapping: .piecewise([
          MeterScalePoint(-50, 0), MeterScalePoint(-40, 0.1), MeterScalePoint(-30, 0.2),
          MeterScalePoint(-20, 0.32), MeterScalePoint(-10, 0.5), MeterScalePoint(0, 0.82),
          MeterScalePoint(5, 1),
        ]),
        marks: marks,
        zones: [MeterZone(lower: -50, upper: 0, kind: .normal), MeterZone(lower: 0, upper: 5, kind: .over)],
        alignment: -9, permittedMaximum: 0, readingScale: 1, readingOffset: -9)
    case .typeIIa:
      return MeterScale(
        unit: .ppmMark, lowerBound: 1, upperBound: 7,
        marks: (1...7).map { MeterScaleMark(value: Double($0), label: "\($0)") },
        zones: [MeterZone(lower: 1, upper: 6, kind: .normal), MeterZone(lower: 6, upper: 7, kind: .over)],
        alignment: 4, permittedMaximum: 6, readingScale: 0.25, readingOffset: 4)
    case .typeIIb:
      var marks: [MeterScaleMark] = []
      var v = -12.0
      while v <= 12 {
        let major = Int(v) % 4 == 0
        marks.append(MeterScaleMark(
          value: v, label: major ? (v == 0 ? "TEST" : v > 0 ? "+\(Int(v))" : "\(Int(v))") : nil, isMajor: major))
        if v == 8 { marks.append(MeterScaleMark(value: 9, label: nil, isMajor: false)) }
        v += 2
      }
      return MeterScale(
        unit: .dBRelativeToAlignment, lowerBound: -12, upperBound: 12, marks: marks,
        zones: [MeterZone(lower: -12, upper: 9, kind: .normal), MeterZone(lower: 9, upper: 12, kind: .over)],
        alignment: 0, permittedMaximum: 9)
    }
  }

  /// The Nordic PPM scale (a DIN variant; Type I ballistics with a 20 dB in
  /// 1.7 s return): -36 to +9 dB re alignment (TEST), PML at +9.
  public static let ppmNordic = MeterScale(
    unit: .dBRelativeToAlignment, lowerBound: -36, upperBound: 9,
    marks: [-36, -30, -24, -18, -12, -6, 0, 6, 9].map {
      MeterScaleMark(value: $0, label: $0 == 0 ? "TEST" : $0 > 0 ? "+\(Int($0))" : "\(Int($0))")
    },
    zones: [MeterZone(lower: -36, upper: 9, kind: .normal)], alignment: 0, permittedMaximum: 9)

  /// An EBU Tech 3341 loudness scale for momentary, short-term or integrated
  /// loudness, in LU relative to `target` or in absolute LUFS (Tech 3341
  /// allows either). Major marks every 3 LU (+9) or 6 LU (+18), minor every
  /// 1 or 2 LU. Zones: normal below target - 1 LU, target within +/- 1 LU
  /// (the R 128 tolerance for live programmes), caution above.
  public static func loudness(
    _ range: LoudnessScaleRange = .ebuPlus9, unit: MeterScaleUnit = .lu, target: Double = -23
  ) -> MeterScale {
    precondition(unit == .lu || unit == .lufs, "a loudness scale is in LU or LUFS")
    let (low, high, major, minor): (Double, Double, Double, Double) =
      range == .ebuPlus9 ? (-18, 9, 3, 1) : (-36, 18, 6, 2)
    // Marks are laid out in LU and shifted for LUFS.
    let shift = unit == .lufs ? target : 0
    var marks: [MeterScaleMark] = []
    var v = low
    while v <= high {
      let isMajor = (v / major).rounded() * major == v
      let shown = v + shift
      marks.append(MeterScaleMark(
        value: shown, label: isMajor ? (shown > 0 && unit == .lu ? "+\(Self.format(shown))" : Self.format(shown)) : nil,
        isMajor: isMajor))
      v += minor
    }
    return MeterScale(
      unit: unit, lowerBound: low + shift, upperBound: high + shift, marks: marks,
      zones: Self.zones([(low + shift, .normal), (shift - 1, .target), (shift + 1, .caution)], top: high + shift),
      alignment: shift, readingScale: 1, readingOffset: unit == .lu ? -target : 0)
  }

  /// Contiguous zones from (start, kind) pairs; empty ones are dropped.
  private static func zones(_ starts: [(Double, MeterZoneKind)], top: Double) -> [MeterZone] {
    var out: [MeterZone] = []
    for (i, start) in starts.enumerated() {
      let end = i + 1 < starts.count ? starts[i + 1].0 : top
      if end > start.0 { out.append(MeterZone(lower: start.0, upper: end, kind: start.1)) }
    }
    return out
  }

  private static func format(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }
}
