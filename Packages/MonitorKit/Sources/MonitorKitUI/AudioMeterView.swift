import MonitorKitAudio
import SwiftUI

/// What a meter bar shows. Each reads one `AudioChannelLevels` field.
public enum AudioMeterBarKind: String, CaseIterable, Sendable {
  case samplePeak, truePeak, rms, vu, ppm

  /// The meter kind that must be on in the `AudioMeterConfiguration`.
  public var meterKind: AudioMeterKinds {
    switch self {
    case .samplePeak: return .samplePeak
    case .truePeak: return .truePeak
    case .rms: return .rms
    case .vu: return .vu
    case .ppm: return .ppm
    }
  }

  public var title: String {
    switch self {
    case .samplePeak: return "Peak"
    case .truePeak: return "True peak"
    case .rms: return "RMS"
    case .vu: return "VU"
    case .ppm: return "PPM"
    }
  }

  /// The standard scale for the meter as configured: IEC 60268-18 digital peak
  /// (sample peak to 0 dBFS, true peak with EBU R 128's −1 dBTP maximum, RMS),
  /// the IEC 60268-17 VU face, or the PPM type's own scale (IEC 60268-10).
  public func defaultScale(for c: AudioMeterConfiguration) -> MeterScale {
    switch self {
    case .samplePeak: return .digitalPeak(unit: .dBFS, alignment: c.ppmAlignment, maximumPeak: 0)
    case .truePeak: return .digitalPeak(unit: .dBTP, alignment: c.ppmAlignment, maximumPeak: -1)
    case .rms: return .digitalPeak(unit: .dBFS, alignment: c.vuReference, maximumPeak: 0)
    case .vu: return .vu
    case .ppm: return .ppm(c.ppmType)
    }
  }
}

/// One bar's reading on a scale. Allocation-free: built per channel per frame.
public struct MeterBarReading: Equatable, Sendable {
  /// In the scale's unit; `-infinity` for silence.
  public var value: Double
  /// The bar's top, 0 (bottom) to 1.
  public var position: Double
  /// The peak-hold marker (sample and true peak only), in the scale's unit and on the travel.
  public var holdValue: Double?
  public var holdPosition: Double?
  public var zone: MeterZoneKind?
  /// Samples at or above the clip level since the last peak reset (the clip LED).
  public var isClipping: Bool

  public init(levels: AudioChannelLevels, kind: AudioMeterBarKind, scale: MeterScale) {
    let reading: Float
    var hold: Float?
    switch kind {
    case .samplePeak:
      reading = levels.samplePeak
      hold = levels.samplePeakHold
    case .truePeak:
      reading = levels.truePeak
      hold = levels.truePeakHold
    case .rms: reading = levels.rms
    case .vu: reading = levels.vu
    case .ppm: reading = levels.ppm
    }
    value = scale.value(forReading: Double(reading))
    position = scale.position(of: value)
    holdValue = hold.map { scale.value(forReading: Double($0)) }
    holdPosition = holdValue.map { scale.position(of: $0) }
    zone = scale.zone(of: value)
    isClipping = levels.clipCount > 0
  }
}

/// BS.1770 / EBU R 128 readings as a meter prints them.
public struct LoudnessReadout: Equatable, Sendable {
  public var momentary: Double
  public var shortTerm: Double
  public var integrated: Double
  public var loudnessRange: Double
  /// The programme's maximum true peak (EBU Tech 3341 "Max TP"), dBTP.
  public var maximumTruePeak: Double

  public init(_ s: AudioMeterSnapshot) {
    momentary = Double(s.loudness.momentary)
    shortTerm = Double(s.loudness.shortTerm)
    integrated = Double(s.loudness.integrated)
    loudnessRange = Double(s.loudness.loudnessRange)
    maximumTruePeak = Double(s.programmeMaximumTruePeak)
  }

  /// One decimal, as Tech 3341 meters show: "−23.0 LUFS", or relative to
  /// `target` in LU ("+1.2 LU"). Silence (−∞) prints "—".
  public static func text(_ lufs: Double, unit: MeterScaleUnit = .lufs, target: Double = -23) -> String {
    guard lufs.isFinite else { return "—" }
    if unit == .lu { return signed(lufs - target) + " LU" }
    return signed(lufs) + " LUFS"
  }

  /// "+1.2", "−0.4", "0.0" (a typographic minus).
  public static func signed(_ v: Double) -> String {
    let t = (v * 10).rounded() / 10
    let text = String(format: "%.1f", abs(t))
    return t > 0 ? "+" + text : t < 0 ? "−" + text : text
  }
}

/// Formats a reading only when its printed value changes, so a readout
/// refreshing at 10 Hz builds a new string only when a digit moves.
final class ReadoutText {
  private var key = Int.min
  private var text = "—"
  private let format: (Double) -> String

  init(_ format: @escaping (Double) -> String) { self.format = format }

  func callAsFunction(_ value: Double) -> String {
    let k = value.isFinite ? Int((value * 10).rounded()) : Int.min + 1
    if k != key {
      key = k
      text = format(value)
    }
    return text
  }
}

/// The colours of a meter's zones (no standard sets them; these follow the
/// green / amber / red convention both reference devices use).
public struct MeterPalette: Sendable {
  public var normal: Color
  public var target: Color
  public var caution: Color
  public var over: Color
  public var track: Color

  public init(
    normal: Color = Color(red: 0.2, green: 0.85, blue: 0.35), target: Color = Color(red: 0.25, green: 0.8, blue: 0.95),
    caution: Color = Color(red: 1, green: 0.75, blue: 0.1), over: Color = Color(red: 1, green: 0.2, blue: 0.15),
    track: Color = Color(white: 0.16)
  ) {
    self.normal = normal
    self.target = target
    self.caution = caution
    self.over = over
    self.track = track
  }

  public static let standard = MeterPalette()

  public func color(_ zone: MeterZoneKind?) -> Color {
    switch zone {
    case .normal?, nil: return normal
    case .target?: return target
    case .caution?: return caution
    case .over?: return over
    }
  }
}

/// Bar meters per channel with the standard scale marks, peak hold and clip
/// LEDs, plus the R 128 loudness panel (momentary and short-term bars on the
/// EBU +9 or +18 scale; M, S, I, LRA and Max TP readouts).
///
/// Bars redraw at display rate from the meter's lock-free `snapshot()`, and only
/// when its `sequence` moves; the scales are built once, the readouts refresh
/// at 10 Hz (EBU Tech 3341's minimum) and format a string only when a digit
/// changes. Click or tap the bars to reset the peaks.
public struct AudioMeterView: View {
  let meter: AudioMeter
  let kind: AudioMeterBarKind
  let scale: MeterScale
  let loudnessScale: MeterScale?
  let loudnessUnit: MeterScaleUnit
  let target: Double
  let channelLabels: [String]
  let palette: MeterPalette
  let zones: MeterZoneSpans

  /// `scale` defaults to `kind.defaultScale(for:)`; `loudness` nil hides the panel.
  public init(
    meter: AudioMeter, kind: AudioMeterBarKind = .truePeak, scale: MeterScale? = nil,
    loudness: LoudnessScaleRange? = .ebuPlus9, loudnessUnit: MeterScaleUnit = .lu, target: Double = -23,
    channelLabels: [String]? = nil, palette: MeterPalette = .standard
  ) {
    self.meter = meter
    self.kind = kind
    self.scale = scale ?? kind.defaultScale(for: meter.configuration)
    let showsLoudness = meter.configuration.meters.contains(.loudness)
    loudnessScale = showsLoudness ? loudness.map { MeterScale.loudness($0, unit: loudnessUnit, target: target) } : nil
    self.loudnessUnit = loudnessUnit
    self.target = target
    self.channelLabels = Self.labels(channelLabels, channelCount: meter.configuration.channelCount)
    self.palette = palette
    zones = MeterZoneSpans(self.scale)
  }

  /// One label per channel: the host's, then channel numbers for any it left out.
  nonisolated static func labels(_ given: [String]?, channelCount n: Int) -> [String] {
    guard let given else { return standardLabels(channelCount: n) }
    var out = Array(given.prefix(n))
    while out.count < n { out.append(String(out.count + 1)) }
    return out
  }

  /// L/R, 5.1 and 7.1 names for those layouts, numbers otherwise.
  nonisolated public static func standardLabels(channelCount n: Int) -> [String] {
    switch n {
    case 1: return ["M"]
    case 2: return ["L", "R"]
    case 6: return ["L", "R", "C", "LFE", "Ls", "Rs"]
    case 8: return ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs"]
    default: return (1...max(1, n)).map(String.init)
    }
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 6) {
      MeterRuler(scale: scale)
        .frame(width: 30)
      TimelineView(.animation) { _ in
        MeterBars(
          snapshot: meter.snapshot(), kind: kind, scale: scale, zones: zones, channels: channelLabels.count,
          palette: palette)
        .equatable()
      }
      .frame(minWidth: CGFloat(channelLabels.count) * 8)
      .overlay(alignment: .bottom) { ChannelLabels(labels: channelLabels) }
      .contentShape(Rectangle())
      .onTapGesture { meter.resetPeaks() }
      if let loudnessScale {
        LoudnessPanel(meter: meter, scale: loudnessScale, unit: loudnessUnit, target: target, palette: palette)
      }
    }
    .accessibilityHidden(true)
    .overlay {
      // VoiceOver reads a summary refreshed once a second, not per frame.
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        Color.clear
          .allowsHitTesting(false)
          .accessibilityElement()
          .accessibilityLabel("Audio meters, \(kind.title)")
          .accessibilityValue(summary(meter.snapshot()))
          .accessibilityAction(named: "Reset peaks") { meter.resetPeaks() }
          .accessibilityAction(named: "Reset loudness") { meter.resetLoudness() }
      }
    }
    .contextMenu {
      Button("Reset peaks") { meter.resetPeaks() }
      if loudnessScale != nil { Button("Reset loudness") { meter.resetLoudness() } }
    }
  }

  private func summary(_ s: AudioMeterSnapshot) -> String {
    var parts: [String] = []
    var c = 0
    while c < s.channelCount && c < channelLabels.count {
      let r = MeterBarReading(levels: s.channels[c], kind: kind, scale: scale)
      let v = r.value.isFinite ? LoudnessReadout.signed(r.value) : "silent"
      parts.append("\(channelLabels[c]) \(v)\(r.isClipping ? ", clipped" : "")")
      c += 1
    }
    if loudnessScale != nil {
      parts.append("integrated \(LoudnessReadout.text(Double(s.loudness.integrated), unit: loudnessUnit, target: target))")
    }
    return parts.joined(separator: "; ")
  }
}

/// Vertical layout shared by rulers and bars: a clip LED on top, labels below.
enum MeterMetrics {
  static let ledHeight: CGFloat = 5
  static let top: CGFloat = 8
  static let bottom: CGFloat = 14

  static func y(_ position: Double, height: CGFloat) -> CGFloat {
    top + CGFloat(1 - position) * max(1, height - top - bottom)
  }
}

/// The scale's marks and labels. Static: redrawn only on a size change.
struct MeterRuler: View {
  let scale: MeterScale

  var body: some View {
    Canvas { context, size in
      for mark in scale.marks {
        let y = MeterMetrics.y(scale.position(of: mark.value), height: size.height)
        let length: CGFloat = mark.isMajor ? 5 : 3
        var tick = Path()
        tick.move(to: CGPoint(x: size.width - length, y: y))
        tick.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(tick, with: .color(.secondary), lineWidth: 1)
        if let label = mark.label {
          context.draw(
            Text(label).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary),
            at: CGPoint(x: size.width - length - 2, y: y), anchor: .trailing)
        }
      }
    }
  }
}

/// Where each zone of a scale starts and ends on the travel (0…1): fixed per
/// scale, so the bars compute them once, not per channel per frame.
struct MeterZoneSpans: Equatable, Sendable {
  let from: [Double]
  let to: [Double]
  let kinds: [MeterZoneKind]

  init(_ scale: MeterScale) {
    from = scale.zones.map { scale.position(of: $0.lower) }
    to = scale.zones.map { scale.position(of: $0.upper) }
    kinds = scale.zones.map(\.kind)
  }
}

/// What one rectangle of the bars shows.
enum MeterBarPart: Equatable {
  case track
  case zone(MeterZoneKind)
  /// The peak-hold marker, coloured by the zone of its value.
  case hold(MeterZoneKind?)
  case led(clipping: Bool)
}

/// The bars; equal (and so not redrawn) while the snapshot's sequence stands still.
struct MeterBars: View, Equatable {
  let snapshot: AudioMeterSnapshot
  let kind: AudioMeterBarKind
  let scale: MeterScale
  let zones: MeterZoneSpans
  let channels: Int
  let palette: MeterPalette

  nonisolated static func == (a: MeterBars, b: MeterBars) -> Bool {
    a.snapshot.sequence == b.snapshot.sequence && a.kind == b.kind && a.channels == b.channels && a.scale == b.scale
  }

  var body: some View {
    Canvas { context, size in
      Self.layout(snapshot: snapshot, kind: kind, scale: scale, zones: zones, channels: channels, size: size) {
        rect, part in
        let color: Color
        switch part {
        case .track: color = palette.track
        case .zone(let k): color = palette.color(k)
        case .hold(let k): color = palette.color(k)
        case .led(let clipping): color = clipping ? palette.over : palette.track
        }
        context.fill(Path(rect), with: .color(color))
      }
    }
  }

  /// Every rectangle of one frame of bars, in drawing order: the Canvas body
  /// without the drawing, so a test can measure it.
  nonisolated static func layout(
    snapshot: AudioMeterSnapshot, kind: AudioMeterBarKind, scale: MeterScale, zones: MeterZoneSpans, channels: Int,
    size: CGSize, _ emit: (CGRect, MeterBarPart) -> Void
  ) {
    // Every configured channel gets a bar; one not yet published reads silence.
    let n = max(1, min(channels, snapshot.channels.count))
    let gap: CGFloat = 2
    let width = max(2, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
    let zero = MeterMetrics.y(0, height: size.height)
    let topY = MeterMetrics.y(1, height: size.height)
    var c = 0
    while c < n {
      let x = CGFloat(c) * (width + gap)
      let levels = c < snapshot.channelCount ? snapshot.channels[c] : AudioChannelLevels()
      let r = MeterBarReading(levels: levels, kind: kind, scale: scale)
      emit(CGRect(x: x, y: topY, width: width, height: zero - topY), .track)
      // The lit part, coloured zone by zone.
      var z = 0
      while z < zones.kinds.count {
        let from = zones.from[z], to = min(zones.to[z], r.position)
        if to > from {
          let y0 = MeterMetrics.y(to, height: size.height), y1 = MeterMetrics.y(from, height: size.height)
          emit(CGRect(x: x, y: y0, width: width, height: y1 - y0), .zone(zones.kinds[z]))
        }
        z += 1
      }
      if let hold = r.holdPosition, let value = r.holdValue, hold > 0 {
        let y = MeterMetrics.y(hold, height: size.height)
        emit(CGRect(x: x, y: y - 1, width: width, height: 2), .hold(scale.zone(of: value)))
      }
      emit(CGRect(x: x, y: 0, width: width, height: MeterMetrics.ledHeight), .led(clipping: r.isClipping))
      c += 1
    }
  }
}

struct ChannelLabels: View {
  let labels: [String]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
        Text(label)
          .font(.system(.caption2, design: .monospaced).weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .frame(maxWidth: .infinity)
      }
    }
    .frame(height: MeterMetrics.bottom)
  }
}

/// Momentary and short-term bars on the loudness scale, and the readouts.
struct LoudnessPanel: View {
  let meter: AudioMeter
  let scale: MeterScale
  let unit: MeterScaleUnit
  let target: Double
  let palette: MeterPalette
  @State private var texts = LoudnessTexts()

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      MeterRuler(scale: scale).frame(width: 30)
      TimelineView(.animation) { _ in
        LoudnessBars(snapshot: meter.snapshot(), scale: scale, palette: palette).equatable()
      }
      .frame(width: 22)
      .overlay(alignment: .bottom) { ChannelLabels(labels: ["M", "S"]) }
      TimelineView(.periodic(from: .now, by: 0.1)) { _ in
        let t = texts.strings(LoudnessReadout(meter.snapshot()), unit: unit, target: target)
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
          row("M", t.momentary)
          row("S", t.shortTerm)
          row("I", t.integrated)
          row("LRA", t.range)
          row("TP", t.peak)
        }
        .font(.caption.monospacedDigit())
      }
      .fixedSize()
    }
  }

  private func row(_ name: String, _ value: String) -> some View {
    GridRow {
      Text(name).foregroundStyle(.secondary)
      Text(value).gridColumnAlignment(.trailing)
    }
  }
}

/// The readouts' cached strings, rebuilt when the unit or target changes.
@MainActor final class LoudnessTexts {
  private var cache: [ReadoutText] = []
  private var unit: MeterScaleUnit?
  private var target = -23.0

  func strings(_ r: LoudnessReadout, unit: MeterScaleUnit, target: Double) -> (
    momentary: String, shortTerm: String, integrated: String, range: String, peak: String
  ) {
    if self.unit != unit || self.target != target || cache.isEmpty {
      self.unit = unit
      self.target = target
      let loudness = { (v: Double) in LoudnessReadout.text(v, unit: unit, target: target) }
      cache = [
        ReadoutText(loudness), ReadoutText(loudness), ReadoutText(loudness),
        ReadoutText { $0.isFinite ? String(format: "%.1f LU", $0) : "—" },
        ReadoutText { $0.isFinite ? LoudnessReadout.signed($0) + " dBTP" : "—" },
      ]
    }
    return (
      cache[0](r.momentary), cache[1](r.shortTerm), cache[2](r.integrated), cache[3](r.loudnessRange),
      cache[4](r.maximumTruePeak)
    )
  }
}

struct LoudnessBars: View, Equatable {
  let snapshot: AudioMeterSnapshot
  let scale: MeterScale
  let palette: MeterPalette

  nonisolated static func == (a: LoudnessBars, b: LoudnessBars) -> Bool {
    a.snapshot.sequence == b.snapshot.sequence && a.scale == b.scale
  }

  var body: some View {
    Canvas { context, size in
      let width = (size.width - 2) / 2
      let readings = (Double(snapshot.loudness.momentary), Double(snapshot.loudness.shortTerm))
      var c = 0
      while c < 2 {
        let x = CGFloat(c) * (width + 2)
        let value = scale.value(forReading: c == 0 ? readings.0 : readings.1)
        let p = scale.position(of: value)
        let top = MeterMetrics.y(1, height: size.height), zero = MeterMetrics.y(0, height: size.height)
        context.fill(Path(CGRect(x: x, y: top, width: width, height: zero - top)), with: .color(palette.track))
        let y = MeterMetrics.y(p, height: size.height)
        if p > 0 {
          context.fill(Path(CGRect(x: x, y: y, width: width, height: zero - y)), with: .color(palette.color(scale.zone(of: value))))
        }
        c += 1
      }
      // The target (alignment) line across both bars.
      if let a = scale.alignment {
        let y = MeterMetrics.y(scale.position(of: a), height: size.height)
        context.fill(Path(CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)), with: .color(.white.opacity(0.7)))
      }
    }
  }
}
