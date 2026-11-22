// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

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
  /// Peak-to-loudness ratio, Max TP − I, in LU; nil until both exist.
  public var peakToLoudnessRatio: Double?

  public init(_ s: AudioMeterSnapshot) {
    momentary = Double(s.loudness.momentary)
    shortTerm = Double(s.loudness.shortTerm)
    integrated = Double(s.loudness.integrated)
    loudnessRange = Double(s.loudness.loudnessRange)
    maximumTruePeak = Double(s.programmeMaximumTruePeak)
    peakToLoudnessRatio = s.peakToLoudnessRatio
  }

  /// One decimal, as Tech 3341 meters show: "−23.0 LUFS", or relative to
  /// `target` in LU ("+1.2 LU"). Silence (−∞) prints "—".
  public static func text(_ lufs: Double, unit: MeterScaleUnit = .lufs, target: Double = -23) -> String {
    guard lufs.isFinite else { return "—" }
    if unit == .lu {
      let relative = lufs - target
      guard relative.isFinite else { return "—" }
      return signed(relative) + " LU"
    }
    return signed(lufs) + " LUFS"
  }

  /// "+1.2", "−0.4", "0.0" (a typographic minus).
  public static func signed(_ v: Double) -> String { MeterText.signed(v) }
}

/// Formats a reading only when its printed value changes, so a readout
/// refreshing at 10 Hz builds a new string only when a digit moves.
final class ReadoutText {
  private enum Key: Equatable {
    case number(Double), nan
  }
  private var key: Key?
  private var text = "—"
  private let format: (Double) -> String
  private let offset: Double

  init(offset: Double = 0, _ format: @escaping (Double) -> String) {
    self.offset = offset
    self.format = format
  }

  func callAsFunction(_ value: Double) -> String {
    // Keep the cache key in floating point: converting a large finite reading
    // to Int traps, and nonfinite inputs must remain distinct for formatters.
    let scaled = (value - offset) * 10
    let k: Key = value.isNaN ? .nan : .number(scaled.isFinite ? scaled.rounded() : value)
    if k != key {
      key = k
      text = format(value)
    }
    return text
  }
}

/// The colours of a meter. No standard sets them; these follow the green /
/// amber / red convention, chosen for a dark meter well in both light and dark
/// appearance. The zones step in luminance as well as hue (green about 0.45,
/// amber 0.6, red 0.25 relative luminance; each at least 4.5:1 on the dark
/// appearance's well and 3:1 on the light appearance's), so they stay apart
/// for colour-blind viewers, and the over latch also says "OVER" in words.
/// A red readout on the window background uses the darker `latch` in light
/// appearance and a lighter `over` in dark, so small text keeps 4.5:1 in both.
public struct MeterPalette: Sendable {
  public var normal: Color
  public var target: Color
  public var caution: Color
  public var over: Color
  /// The meter well in dark appearance.
  public var track: Color
  /// The meter well in light appearance: still dark, so the zone colours keep their contrast.
  public var lightTrack: Color
  /// A zone's stretch above the bar is drawn in its colour at this opacity.
  public var unlitOpacity: Double
  /// The reference and loudness-target lines inside the well.
  public var reference: Color
  /// The lit over latch's badge (white text, 5:1).
  public var latch: Color

  public init(
    normal: Color = Color(red: 0.19, green: 0.80, blue: 0.35), target: Color = Color(red: 0.30, green: 0.75, blue: 1),
    caution: Color = Color(red: 1, green: 0.76, blue: 0), over: Color = Color(red: 1, green: 0.23, blue: 0.19),
    track: Color = Color(white: 0.11), lightTrack: Color = Color(white: 0.2), unlitOpacity: Double = 0.16,
    reference: Color = Color(white: 1, opacity: 0.6), latch: Color = Color(red: 0.80, green: 0.11, blue: 0.09)
  ) {
    self.normal = normal
    self.target = target
    self.caution = caution
    self.over = over
    self.track = track
    self.lightTrack = lightTrack
    self.unlitOpacity = unlitOpacity
    self.reference = reference
    self.latch = latch
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

  /// The well for an appearance.
  public func track(for scheme: ColorScheme) -> Color { scheme == .dark ? track : lightTrack }

  /// A readout's red on the window background, where `over` reads at about
  /// 3.5:1 in both appearances: `latch` in light (5.6:1 on white) and `over`
  /// mixed a fifth of the way to white in dark (4.8:1 on a #323232 window).
  func readoutOver(_ scheme: ColorScheme) -> Color { scheme == .dark ? over.mix(with: .white, by: 0.2) : latch }

  /// The colour of one rectangle of a level meter.
  public func color(_ part: LevelMeterPart, scheme: ColorScheme) -> Color {
    switch part {
    case .well: return track(for: scheme)
    case .unlit(let zone): return color(zone).opacity(unlitOpacity)
    case .lit(let zone): return color(zone)
    case .hold(let zone): return color(zone)
    case .reference: return reference
    }
  }
}

/// The full broadcast panel: per-channel bars beside a ruler (true peak by
/// default, on `MeterScale.expandedPeak()` with the −20 dBFS reference line,
/// hard zones and a hold line), each channel's held maximum, the over latch;
/// the EBU R 128 panel (momentary and short-term bars in absolute LUFS with
/// the −23 LUFS target line; M, S, I, LRA, Max TP and PLR readouts); and a
/// phase-correlation meter for a stereo pair when the meter runs `.correlation`.
///
/// Bars are Core Animation layers the display link moves from the meter's
/// lock-free `snapshot()`, one snapshot per frame with the fall extrapolated
/// between snapshots (see `LevelMeterView`), without re-evaluating a SwiftUI
/// view; readouts are checked at 10 Hz (EBU Tech 3341's minimum) and change
/// only when a digit does. Click the over latch to
/// reset the peaks; the context menu resets peaks or loudness.
public struct AudioMeterView: View {
  let meter: AudioMeter
  let kind: AudioMeterBarKind
  let scale: MeterScale
  let loudnessScale: MeterScale?
  let loudnessUnit: MeterScaleUnit
  let target: Double
  let channelLabels: [String]
  let palette: MeterPalette
  let present: Bool
  let name: String?
  @State private var spoken = MeterSummaryStore()

  /// `scale` defaults to `MeterScale.expandedPeak()` for the peak kinds and
  /// `kind.defaultScale(for:)` for the others; `loudness` nil hides the R 128
  /// panel. `present` false (no audio on the input) dims the meters and
  /// prints "No audio".
  public init(
    meter: AudioMeter, kind: AudioMeterBarKind = .truePeak, scale: MeterScale? = nil,
    loudness: LoudnessScaleRange? = .ebuPlus9, loudnessUnit: MeterScaleUnit = .lufs, target: Double = -23,
    channelLabels: [String]? = nil, palette: MeterPalette = .standard, present: Bool = true, name: String? = nil
  ) {
    self.meter = meter
    self.kind = kind
    switch kind {
    case .truePeak: self.scale = scale ?? .expandedPeak(unit: .dBTP)
    case .samplePeak: self.scale = scale ?? .expandedPeak(unit: .dBFS)
    default: self.scale = scale ?? kind.defaultScale(for: meter.configuration)
    }
    let showsLoudness = meter.configuration.meters.contains(.loudness)
    loudnessScale = showsLoudness ? loudness.map { MeterScale.loudness($0, unit: loudnessUnit, target: target) } : nil
    self.loudnessUnit = loudnessUnit
    self.target = target
    self.channelLabels = Self.labels(channelLabels, channelCount: meter.configuration.channelCount)
    self.palette = palette
    self.present = present
    self.name = name
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

  private var showsCorrelation: Bool {
    meter.configuration.meters.contains(.correlation) && meter.configuration.correlationChannels != nil
  }

  public var body: some View {
    let spoken = spoken
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 14) {
        PeakColumns(
          meter: meter, kind: kind, scale: scale, labels: channelLabels, palette: palette, present: present,
          onTick: { time in spoken.update(at: time) { summary(meter.snapshot()) } })
        if let loudnessScale {
          LoudnessPanel(
            meter: meter, scale: loudnessScale, unit: loudnessUnit, target: target, palette: palette, present: present)
        }
      }
      if showsCorrelation {
        CorrelationMeter(meter: meter, palette: palette, present: present).frame(height: 24)
      }
    }
    .accessibilityHidden(true)
    .overlay {
      // VoiceOver reads a summary the bars' ticks refresh once a second, not per frame.
      AudioMeterAccessibility(
        name: name.map { "\($0) audio meters" } ?? "Audio meters", summary: spoken,
        fixed: present ? nil : summary(meter.snapshot()), current: { summary(meter.snapshot()) }, meter: meter)
    }
    .contextMenu {
      Button("Reset Peaks") { meter.resetPeaks() }
      if loudnessScale != nil { Button("Reset Loudness") { meter.resetLoudness() } }
    }
  }

  /// Spoken readings follow the selected bars; true-peak bars retain their maximum summary.
  nonisolated static func channelSummary(
    _ s: AudioMeterSnapshot, kind: AudioMeterBarKind, scale: MeterScale, channels: Int, present: Bool
  ) -> String {
    if kind == .truePeak { return MeterText.peakSummary(s, channels: channels, present: present) }
    guard present else { return "no audio" }
    let n = min(channels, s.channelCount)
    guard n > 0 else { return "no reading" }
    let unit: String
    switch scale.unit {
    case .dBFS: unit = "dBFS"
    case .dBTP: unit = "dBTP"
    case .vu: unit = "VU"
    case .ppmMark: unit = "PPM mark"
    case .dBRelativeToAlignment: unit = "dB relative to alignment"
    case .dBRelativeToPML: unit = "dB relative to PML"
    case .lu: unit = "LU"
    case .lufs: unit = "LUFS"
    }
    var parts: [String] = []
    for c in 0..<n {
      let r = MeterBarReading(levels: s.channels[c], kind: kind, scale: scale)
      parts.append("\(MeterText.spokenChannel(c, of: n)) \(kind.title) \(MeterText.level(r.value)) \(unit)")
    }
    if s.isOver() { parts.append("over") }
    return parts.joined(separator: ", ")
  }

  private func summary(_ s: AudioMeterSnapshot) -> String {
    var parts = [Self.channelSummary(s, kind: kind, scale: scale, channels: channelLabels.count, present: present)]
    if present, loudnessScale != nil {
      parts.append("integrated \(LoudnessReadout.text(Double(s.loudness.integrated), unit: loudnessUnit, target: target))")
      if let plr = s.peakToLoudnessRatio { parts.append("PLR \(MeterText.amount(plr))") }
    }
    if present, showsCorrelation, s.correlation.isFinite {
      parts.append("correlation \(MeterText.correlation(Double(s.correlation)))")
    }
    return parts.joined(separator: "; ")
  }
}

/// The panel's one accessibility element, reading the summary the bars' ticks
/// refresh: a new summary re-evaluates this leaf, not the panel.
struct AudioMeterAccessibility: View {
  let name: String
  let summary: MeterSummaryStore
  /// The summary while nothing moves (no audio); nil while live.
  let fixed: String?
  /// The summary now: until the first display tick has written one (and in a render that never ticks).
  let current: () -> String
  let meter: AudioMeter

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(name)
      .accessibilityValue(fixed ?? (summary.text.isEmpty ? current() : summary.text))
      .accessibilityAction(named: "Reset Peaks") { meter.resetPeaks() }
      .accessibilityAction(named: "Reset Loudness") { meter.resetLoudness() }
  }
}

/// The panel's peak bars: `LevelMeterView`'s full style for any bar kind.
struct PeakColumns: View {
  let meter: AudioMeter
  let kind: AudioMeterBarKind
  let scale: MeterScale
  let labels: [String]
  let palette: MeterPalette
  let present: Bool
  var onTick: (@MainActor (Double) -> Void)? = nil

  var body: some View {
    if kind == .truePeak {
      LevelMeterBody(
        source: LevelMeterSource(meter: meter, fixed: AudioMeterSnapshot()), style: .full, present: present,
        labels: labels, scale: scale, spans: scale.zoneSpans, reference: scale.alignment.map { scale.position(of: $0) },
        palette: palette, showsContextMenu: false, onTick: onTick
      )
      .frame(minWidth: Self.width(labels.count, column: 12), idealWidth: Self.width(labels.count, column: 22),
        maxWidth: Self.width(labels.count, column: 30))
    } else {
      KindColumns(
        meter: meter, kind: kind, scale: scale, labels: labels, palette: palette, present: present, onTick: onTick)
        .frame(minWidth: Self.width(labels.count, column: 12), idealWidth: Self.width(labels.count, column: 22),
          maxWidth: Self.width(labels.count, column: 30))
    }
  }
}

extension PeakColumns {
  /// The ruler and `n` columns `column` points wide.
  nonisolated static func width(_ n: Int, column: CGFloat) -> CGFloat {
    29 + CGFloat(n) * column + LevelMeterView.rows(.full, channels: n).gap * CGFloat(max(0, n - 1))
  }
}

/// Bars for a kind other than true peak (sample peak, RMS, VU, PPM): the same
/// renderer, the kind's own reading and scale, no maximum readouts.
struct KindColumns: View {
  let meter: AudioMeter
  let kind: AudioMeterBarKind
  let scale: MeterScale
  let labels: [String]
  let palette: MeterPalette
  let present: Bool
  var onTick: (@MainActor (Double) -> Void)? = nil
  @State private var animator = LevelMeterAnimator()

  var body: some View {
    // Copies for the drawing closure, declared before any use of the properties they shadow.
    let meter = meter, kind = kind, scale = scale, n = labels.count, present = present
    let animator = animator, onTick = onTick
    let spans = scale.zoneSpans
    let reference = scale.alignment.map { scale.position(of: $0) }
    let gap = LevelMeterView.rows(.full, channels: n).gap
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 3) {
        LevelMeterRuler(ticks: scale.ticks, axis: .vertical, inset: 5).frame(width: 26)
        MeterLayerRepresentable(live: present, palette: palette) { frame, layers, colors in
          animator.configure(fallRate: meter.configuration.peakDecayRate, holdTime: meter.configuration.peakHoldTime)
          if present {
            animator.advance(meter.snapshot(), channels: n, kind: kind, scale: scale, at: frame.time, animate: true)
          } else {
            animator.showNothing(channels: n)
          }
          LevelMeterView.layout(
            animator.layouts, spans: spans, reference: reference, axis: .vertical, size: frame.size, gap: gap
          ) { rect, part in layers.fill(rect, colors(part)) }
          if frame.isTick { onTick?(frame.time) }
        }
        .padding(.vertical, 5)
        .opacity(present ? 1 : 0.4)
      }
      .frame(maxHeight: .infinity)
      HStack(spacing: 3) {
        Color.clear.frame(width: 26, height: 1)
        HStack(spacing: gap) {
          ForEach(0..<labels.count, id: \.self) { c in
            Text(labels[c]).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
              .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
          }
        }
      }
    }
  }
}

/// Momentary and short-term bars on the loudness scale with the target line, and the readouts.
struct LoudnessPanel: View {
  let meter: AudioMeter
  let scale: MeterScale
  let unit: MeterScaleUnit
  let target: Double
  let palette: MeterPalette
  let present: Bool
  @State private var readouts = LoudnessReadouts()

  var body: some View {
    // Copies for the drawing closure, declared before any use of the properties they shadow.
    let meter = meter, scale = scale, unit = unit, target = target, readouts = readouts
    let spans = scale.zoneSpans
    let reference = scale.alignment.map { scale.position(of: $0) }
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text(unit == .lu ? "LU" : "LUFS").font(.system(size: 9)).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 3) {
          LevelMeterRuler(ticks: scale.ticks, axis: .vertical, inset: 5).frame(width: 26)
          MeterLayerRepresentable(live: present, palette: palette) { frame, layers, colors in
            let s = meter.snapshot()
            let m = scale.layout(level: scale.value(forReading: Double(s.loudness.momentary)))
            let st = scale.layout(level: scale.value(forReading: Double(s.loudness.shortTerm)))
            LevelMeterView.layoutChannels(
              .pair(m, st), spans: spans, reference: reference, axis: .vertical, size: frame.size, gap: 3
            ) { rect, part in layers.fill(rect, colors(part)) }
            if frame.isTick { readouts.update(s, unit: unit, target: target, at: frame.time) }
          }
          .frame(width: 24)
          .padding(.vertical, 5)
          .opacity(present ? 1 : 0.4)
        }
        .frame(maxHeight: .infinity)
        HStack(spacing: 3) {
          Color.clear.frame(width: 26, height: 1)
          HStack(spacing: 3) {
            Text("M").frame(maxWidth: .infinity)
            Text("S").frame(maxWidth: .infinity)
          }
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
          .frame(width: 24)
        }
      }
      LoudnessGrid(readouts: readouts, present: present, palette: palette)
        .fixedSize()
    }
  }
}

/// The loudness readouts the bars' ticks write, at most 10 Hz and only when a
/// printed value changes.
@MainActor @Observable final class LoudnessReadouts {
  /// M, S, I, LRA, Max TP and PLR, as printed.
  private(set) var strings: [String] = Array(repeating: "—", count: 6)
  /// Whether Max TP is at or above −1 dBTP.
  private(set) var peakOver = false
  @ObservationIgnored private let texts = LoudnessTexts()
  @ObservationIgnored private var last = -Double.infinity

  func update(_ s: AudioMeterSnapshot, unit: MeterScaleUnit, target: Double, at time: Double) {
    guard time - last >= 0.1 || time < last else { return }
    last = time
    let r = LoudnessReadout(s)
    let t = texts.strings(r, unit: unit, target: target)
    set(0, t.momentary)
    set(1, t.shortTerm)
    set(2, t.integrated)
    set(3, t.range)
    set(4, t.peak)
    set(5, t.ratio)
    let over = r.maximumTruePeak >= -1
    if over != peakOver { peakOver = over }
  }

  private func set(_ i: Int, _ text: String) {
    if strings[i] != text { strings[i] = text }
  }
}

/// M, S, I, LRA, Max TP and PLR.
struct LoudnessGrid: View {
  let readouts: LoudnessReadouts
  let present: Bool
  let palette: MeterPalette
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let t = readouts.strings
    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
      row("M", present ? t[0] : "—")
      row("S", present ? t[1] : "—")
      row("I", present ? t[2] : "—")
      row("LRA", present ? t[3] : "—")
      row("Max TP", present ? t[4] : "—", over: present && readouts.peakOver)
      row("PLR", present ? t[5] : "—")
    }
    .font(.caption.monospacedDigit())
    .help("EBU R 128: integrated loudness target −23 LUFS, maximum true peak −1 dBTP. PLR is Max TP − I.")
  }

  private func row(_ name: String, _ value: String, over: Bool = false) -> some View {
    GridRow {
      Text(name).foregroundStyle(.secondary)
      Text(value).gridColumnAlignment(.trailing)
        .foregroundStyle(over ? AnyShapeStyle(palette.readoutOver(scheme)) : AnyShapeStyle(.primary))
    }
  }
}

/// The readouts' cached strings, rebuilt when the unit or target changes.
@MainActor final class LoudnessTexts {
  private var cache: [ReadoutText] = []
  private var unit: MeterScaleUnit?
  private var target = -23.0

  func strings(_ r: LoudnessReadout, unit: MeterScaleUnit, target: Double) -> (
    momentary: String, shortTerm: String, integrated: String, range: String, peak: String, ratio: String
  ) {
    if self.unit != unit || self.target != target || cache.isEmpty {
      self.unit = unit
      self.target = target
      let loudness = { (v: Double) in LoudnessReadout.text(v, unit: unit, target: target) }
      cache = [
        ReadoutText(offset: unit == .lu ? target : 0, loudness),
        ReadoutText(offset: unit == .lu ? target : 0, loudness),
        ReadoutText(offset: unit == .lu ? target : 0, loudness),
        ReadoutText { $0.isFinite ? MeterText.amount($0) + " LU" : "—" },
        // Like the level meters' maxima: "−∞" for silence, "—" for no reading.
        ReadoutText { $0.isNaN ? "—" : MeterText.level($0) + " dBTP" },
        ReadoutText { $0.isFinite ? MeterText.amount($0) + " LU" : "—" },
      ]
    }
    return (
      cache[0](r.momentary), cache[1](r.shortTerm), cache[2](r.integrated), cache[3](r.loudnessRange),
      cache[4](r.maximumTruePeak), cache[5](r.peakToLoudnessRatio ?? .nan)
    )
  }
}

/// The stereo pair's phase correlation, −1 to +1: a bar from the centre to
/// the reading (green when positive, amber to −0.5, red below), with the value.
struct CorrelationMeter: View {
  let meter: AudioMeter
  let palette: MeterPalette
  let present: Bool
  @State private var readout = CorrelationReadout()

  /// Where `value` (−1…1) sits on the track (0…1), and the zone it reads in.
  nonisolated static func layout(_ value: Double) -> (position: Double, zone: MeterZoneKind)? {
    guard value.isFinite else { return nil }
    let v = min(max(value, -1), 1)
    return ((v + 1) / 2, v >= 0 ? .normal : v >= -0.5 ? .caution : .over)
  }

  var body: some View {
    let meter = meter, readout = readout
    HStack(spacing: 6) {
      Text("Phase").font(.system(size: 9)).foregroundStyle(.secondary)
      VStack(spacing: 1) {
        MeterLayerRepresentable(live: present, palette: palette) { frame, layers, colors in
          let size = frame.size
          let correlation = Double(meter.snapshot().correlation)
          layers.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height), colors.well)
          let mid = size.width / 2
          if let r = Self.layout(correlation) {
            let x = CGFloat(r.position) * size.width
            layers.fill(
              CGRect(x: min(x, mid), y: 0, width: max(2, abs(x - mid)), height: size.height), colors.lit(r.zone))
          }
          layers.fill(CGRect(x: mid - 0.5, y: 0, width: 1, height: size.height), colors.reference)
          if frame.isTick { readout.update(correlation, at: frame.time) }
        }
        .frame(height: 6)
        HStack {
          Text(MeterText.minus + "1")
          Spacer()
          Text("0")
          Spacer()
          Text("+1")
        }
        .font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
      }
      .opacity(present ? 1 : 0.4)
      CorrelationText(readout: readout, present: present)
    }
    .help("Phase correlation of the stereo pair: +1 mono, 0 unrelated, −1 out of phase.")
  }
}

/// The correlation's printed value, written by the bar's ticks at most 10 Hz
/// and only when it changes.
@MainActor @Observable final class CorrelationReadout {
  private(set) var text = "—"
  // ReadoutText keys on tenths: scale by 10 so it moves on hundredths.
  @ObservationIgnored private let format = ReadoutText { MeterText.correlation($0 / 10) }
  @ObservationIgnored private var last = -Double.infinity

  func update(_ correlation: Double, at time: Double) {
    guard time - last >= 0.1 || time < last else { return }
    last = time
    let t = format(correlation * 10)
    if t != text { text = t }
  }
}

struct CorrelationText: View {
  let readout: CorrelationReadout
  let present: Bool

  var body: some View {
    Text(present ? readout.text : "—").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
  }
}
