// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitAudio
import SwiftUI

/// How a `LevelMeterView` is laid out.
public enum LevelMeterStyle: String, Sendable, Hashable, CaseIterable {
  /// About 56 pt wide: thin stacked rows with zones and a hold tick, and an
  /// over dot. No numbers: the tooltip and VoiceOver carry them.
  case compact
  /// Stacked full-width rows over a tick ruler, each channel's held maximum
  /// in dBTP underneath and the over latch at the right.
  case strip
  /// Vertical bars beside a ruler with the reference line, each channel's
  /// held maximum under its bar and the over latch above.
  case full
}

/// What one rectangle of a level meter shows.
public enum LevelMeterPart: Equatable, Sendable {
  /// A channel's empty well.
  case well
  /// A zone's stretch above the bar, dimmed, so the scale's zones show without signal.
  case unlit(MeterZoneKind)
  /// A zone's stretch up to the bar.
  case lit(MeterZoneKind)
  /// The peak-hold line, coloured by its level's zone.
  case hold(MeterZoneKind?)
  /// The reference level's line across every channel.
  case reference
}

/// A broadcast level meter for 1 to 16 channels: true-peak bars (instant
/// attack, IEC 60268-18 fall of 20 dB in 1.7 s), a hold line (2 s, then the
/// same fall), hard colour zones fixed in dB on `MeterScale.expandedPeak()`
/// (green below −9, amber to −1, red from −1 dBTP) and an over latch that
/// lights on a clipped sample or a true-peak maximum at −1 dBTP or above and
/// stays lit until clicked.
///
/// The bars are Core Animation layers that the display link moves, one
/// `snapshot()` per frame; between snapshots the fall is extrapolated from
/// elapsed time (`MeterDisplayBallistics`), so bars move smoothly at the
/// display rate when audio arrives once per video frame. A frame touches only
/// the layers that moved and never re-evaluates a SwiftUI view, so a meter
/// costs the window nothing per frame. Readouts are checked at 10 Hz and
/// change (re-evaluating only their own text) when a digit moves.
/// VoiceOver sees one element whose value (checked once a second) reads,
/// for example, "left max −6.2 dBTP, right −7.0, over", with a Reset Peaks
/// action; the compact style shows the same text as its tooltip.
public struct LevelMeterView: View {
  let source: LevelMeterSource
  let style: LevelMeterStyle
  let present: Bool
  let name: String?
  let labels: [String]
  let scale: MeterScale
  let spans: [MeterZoneSpan]
  let reference: Double?
  let palette: MeterPalette

  /// A live meter. `present` false (no audio on the input) pauses and dims
  /// the meter and prints "No audio"; present but silent reads "−∞". `name`
  /// leads the accessibility label ("Camera 1 audio").
  public init(
    meter: AudioMeter, style: LevelMeterStyle = .strip, present: Bool = true, name: String? = nil,
    channelLabels: [String]? = nil, scale: MeterScale = .expandedPeak(), palette: MeterPalette = .standard
  ) {
    self.init(
      source: LevelMeterSource(meter: meter, fixed: AudioMeterSnapshot()), style: style, present: present, name: name,
      channelLabels: channelLabels, scale: scale, palette: palette)
  }

  /// Fixed readings, for a host that measures elsewhere (or a preview): the
  /// bars show `snapshot`'s true peak and hold, without ballistics or reset.
  public init(
    snapshot: AudioMeterSnapshot, style: LevelMeterStyle = .strip, present: Bool = true, name: String? = nil,
    channelLabels: [String]? = nil, scale: MeterScale = .expandedPeak(), palette: MeterPalette = .standard
  ) {
    self.init(
      source: LevelMeterSource(meter: nil, fixed: snapshot), style: style, present: present, name: name,
      channelLabels: channelLabels, scale: scale, palette: palette)
  }

  init(
    source: LevelMeterSource, style: LevelMeterStyle, present: Bool, name: String?, channelLabels: [String]?,
    scale: MeterScale, palette: MeterPalette
  ) {
    self.source = source
    self.style = style
    self.present = present
    self.name = name
    labels = Self.labels(channelLabels, channelCount: source.channelCount)
    self.scale = scale
    spans = scale.zoneSpans
    reference = scale.alignment.map { scale.position(of: $0) }
    self.palette = palette
  }

  /// One label per channel: the host's, then numbers for any it left out;
  /// L and R for a pair, 1 to n otherwise.
  nonisolated static func labels(_ given: [String]?, channelCount n: Int) -> [String] {
    var out = Array((given ?? (n == 2 ? ["L", "R"] : [])).prefix(n))
    while out.count < n { out.append(String(out.count + 1)) }
    return out
  }

  public var body: some View {
    LevelMeterBody(
      source: source, style: style, present: present, labels: labels, scale: scale, spans: spans,
      reference: reference, palette: palette, accessibilityName: name.map { "\($0) audio" } ?? "Audio levels",
      tooltipName: name
    )
  }

  // MARK: Layout

  /// Every rectangle of one frame of bars, in drawing order: the Canvas body
  /// without the drawing, so a test can measure it. `axis` is the travel's
  /// direction: horizontal rows (compact, strip) or vertical bars (full).
  /// `reference` is the reference line's position on the travel.
  nonisolated public static func layout(
    _ channels: [MeterChannelLayout], spans: [MeterZoneSpan], reference: Double?, axis: Axis, size: CGSize,
    gap: CGFloat = 2, holdWidth: CGFloat = 2, _ emit: (CGRect, LevelMeterPart) -> Void
  ) {
    layoutChannels(.array(channels), spans: spans, reference: reference, axis: axis, size: size,
      gap: gap, holdWidth: holdWidth, emit)
  }

  /// Shared renderer for array-backed peak channels and the fixed loudness pair.
  nonisolated static func layoutChannels(
    _ channels: LevelMeterChannels, spans: [MeterZoneSpan], reference: Double?, axis: Axis, size: CGSize,
    gap: CGFloat = 2, holdWidth: CGFloat = 2, _ emit: (CGRect, LevelMeterPart) -> Void
  ) {
    let n = channels.count
    guard n > 0, size.width > 0, size.height > 0 else { return }
    let across = axis == .horizontal ? size.height : size.width
    let along = axis == .horizontal ? size.width : size.height
    let thickness = max(0.5, (across - gap * CGFloat(n - 1)) / CGFloat(n))
    // A stretch of the travel (0…1) of the channel at `offset` across.
    func rect(_ offset: CGFloat, _ p0: Double, _ p1: Double) -> CGRect {
      let a = CGFloat(p0) * along, b = CGFloat(p1) * along
      return axis == .horizontal
        ? CGRect(x: a, y: offset, width: b - a, height: thickness)
        : CGRect(x: offset, y: along - b, width: thickness, height: b - a)
    }
    var c = 0
    while c < n {
      let offset = CGFloat(c) * (thickness + gap)
      let channel = channels[c]
      // A NaN bar is no reading: `min(upper, .nan)` is `upper`, which would light every zone.
      let bar = channel.bar.isNaN ? 0 : channel.bar
      emit(rect(offset, 0, 1), .well)
      var z = 0
      while z < spans.count {
        let span = spans[z]
        let top = min(span.upper, bar)
        if top > span.lower { emit(rect(offset, span.lower, top), .lit(span.kind)) }
        let bottom = max(span.lower, bar)
        if span.upper > bottom { emit(rect(offset, bottom, span.upper), .unlit(span.kind)) }
        z += 1
      }
      // As `MeterScale.layout` places it: a line only above the bottom (not NaN or −∞).
      if let hold = channel.hold, hold > 0 {
        let half = Double(holdWidth / 2 / along)
        let p = min(max(hold, half), 1 - half)
        emit(rect(offset, p - half, p + half), .hold(channel.holdZone))
      }
      c += 1
    }
    if let reference, reference > 0, reference < 1 {
      let p = CGFloat(reference) * along
      emit(
        axis == .horizontal
          ? CGRect(x: p - 0.5, y: 0, width: 1, height: size.height)
          : CGRect(x: 0, y: along - p - 0.5, width: size.width, height: 1),
        .reference)
    }
  }

  /// Row thickness and gap for `channels` rows in a style.
  nonisolated static func rows(_ style: LevelMeterStyle, channels n: Int) -> (thickness: CGFloat, gap: CGFloat) {
    switch style {
    case .compact: return n <= 2 ? (3, 1.5) : n <= 4 ? (2, 1) : (1.5, 0.75)
    case .strip: return n <= 2 ? (5, 2) : n <= 4 ? (4, 2) : (3, 1)
    case .full: return (0, n <= 2 ? 4 : 2)
    }
  }

  /// The height of `n` rows in a horizontal style.
  nonisolated static func rowsHeight(_ style: LevelMeterStyle, channels n: Int) -> CGFloat {
    let r = rows(style, channels: n)
    return r.thickness * CGFloat(n) + r.gap * CGFloat(max(0, n - 1))
  }
}

/// Concrete storage avoids generic Collection witness boxing in debug frame paths.
enum LevelMeterChannels {
  case array([MeterChannelLayout])
  case pair(MeterChannelLayout, MeterChannelLayout)

  var count: Int {
    switch self {
    case .array(let values): return values.count
    case .pair: return 2
    }
  }

  subscript(_ index: Int) -> MeterChannelLayout {
    switch self {
    case .array(let values): return values[index]
    case .pair(let momentary, let shortTerm):
      precondition(index == 0 || index == 1)
      return index == 0 ? momentary : shortTerm
    }
  }
}

/// Where a meter's readings come from: a live meter, or fixed readings.
struct LevelMeterSource {
  let meter: AudioMeter?
  let fixed: AudioMeterSnapshot

  var channelCount: Int { min(max(meter?.configuration.channelCount ?? fixed.channelCount, 1), 16) }
  var isLive: Bool { meter != nil }
  var fallRate: Double { meter?.configuration.peakDecayRate ?? 20 / 1.7 }
  var holdTime: Double { meter?.configuration.peakHoldTime ?? 2 }

  func read() -> AudioMeterSnapshot { meter?.snapshot() ?? fixed }
}

/// The display state between frames: each channel's ballistics, hold line
/// and layout, updated in place (no allocation per frame). Held in `@State`
/// and mutated while drawing, so a frame never invalidates the view.
@MainActor final class LevelMeterAnimator {
  /// One per channel drawn; resized only when the channel count changes.
  private(set) var layouts: [MeterChannelLayout] = []
  private var bars: [MeterDisplayBallistics]
  private var holds: [MeterHoldLine]
  /// Per channel, from the last fresh snapshot: the meter's own hold, its
  /// true-peak maximum and clip count (the last two only grow until a peak reset).
  private var meterHolds: [Double]
  private var maxima: [Float]
  private var clips: [UInt32]
  private var sequence: UInt64?
  /// The display's clock: the forward steps of the time it is given, so a
  /// wall clock that steps back never freezes the bars or the hold lines.
  private var clock = 0.0
  private var lastTime: Double?
  private(set) var isOver = false

  init(fallRate: Double = 20 / 1.7, holdTime: Double = 2) {
    bars = Array(repeating: MeterDisplayBallistics(fallRate: fallRate), count: 16)
    holds = Array(repeating: MeterHoldLine(holdTime: holdTime, fallRate: fallRate), count: 16)
    meterHolds = Array(repeating: -.infinity, count: 16)
    maxima = Array(repeating: -.infinity, count: 16)
    clips = Array(repeating: 0, count: 16)
  }

  /// Follows the meter's own fall rate and hold time (its configuration); a no-op when unchanged.
  func configure(fallRate: Double, holdTime: Double) {
    guard fallRate != bars[0].fallRate || holdTime != holds[0].holdTime else { return }
    bars = Array(repeating: MeterDisplayBallistics(fallRate: fallRate), count: 16)
    holds = Array(repeating: MeterHoldLine(holdTime: holdTime, fallRate: fallRate), count: 16)
    meterHolds = Array(repeating: -.infinity, count: 16)
    sequence = nil
  }

  /// Advances to `time` (seconds) from the snapshot read this frame. Peak
  /// kinds animate (`animate`); other kinds, and fixed readings, show the
  /// snapshot as it is.
  func advance(
    _ s: AudioMeterSnapshot, channels n: Int, kind: AudioMeterBarKind = .truePeak, scale: MeterScale, at time: Double,
    animate: Bool
  ) {
    let n = min(max(n, 0), 16)
    if layouts.count != n { layouts = Array(repeating: MeterChannelLayout(), count: n) }
    if let lastTime, time > lastTime { clock += time - lastTime }
    if time.isFinite { lastTime = time }
    let now = clock
    let fresh = s.sequence != sequence
    sequence = s.sequence
    let peakKind = kind == .truePeak || kind == .samplePeak
    var c = 0
    while c < n {
      let levels = c < s.channelCount ? s.channels[c] : AudioChannelLevels()
      if !peakKind {
        let r = MeterBarReading(levels: levels, kind: kind, scale: scale)
        layouts[c] = scale.layout(level: r.value, hold: r.holdValue)
      } else {
        let bar = Double(kind == .truePeak ? levels.truePeak : levels.samplePeak)
        let hold = Double(kind == .truePeak ? levels.truePeakHold : levels.samplePeakHold)
        if !animate {
          layouts[c] = scale.layout(level: scale.value(forReading: bar), hold: scale.value(forReading: hold))
        } else {
          if fresh {
            bars[c].ingest(bar, at: now)
            // A peak reset (here, by the host or from VoiceOver) lowers the
            // maximum or the clip count, which otherwise only grow: start the line over.
            // Under an endless hold the meter's own hold only falls on a reset too,
            // the one sign of it for sample-peak bars on a meter without true peak.
            if levels.truePeakMax < maxima[c] || levels.clipCount < clips[c]
              || (!holds[c].holdTime.isFinite && hold < meterHolds[c])
            {
              holds[c].reset()
              meterHolds[c] = -.infinity
            }
            maxima[c] = levels.truePeakMax
            clips[c] = levels.clipCount
            // The meter's own hold catches a peak between snapshots. Take it
            // only when it rises: offering the same held value with every
            // snapshot would restart the line's hold until the meter's own
            // ran out, holding the line twice as long.
            if hold > meterHolds[c] { holds[c].offer(hold, at: now) }
            meterHolds[c] = hold
          }
          let shown = bars[c].value(at: now)
          holds[c].offer(shown, at: now)
          let held = holds[c].value(at: now)
          layouts[c] = scale.layout(
            level: scale.value(forReading: shown), hold: held.isFinite ? scale.value(forReading: held) : nil)
        }
      }
      c += 1
    }
    isOver = s.isOver()
  }

  /// Empty wells: no audio on the input.
  func showNothing(channels n: Int) {
    let n = min(max(n, 0), 16)
    if layouts.count != n { layouts = Array(repeating: MeterChannelLayout(), count: n) }
    var c = 0
    while c < n {
      layouts[c] = MeterChannelLayout()
      c += 1
    }
    isOver = false
  }

  func resetHolds() {
    var c = 0
    while c < holds.count {
      holds[c].reset()
      c += 1
    }
  }
}

/// The readouts' cached strings: one per channel, rebuilt only when a digit moves.
@MainActor final class LevelMeterTexts {
  let maxima: [ReadoutText] = (0..<16).map { _ in ReadoutText { MeterText.level($0) } }
}

/// What a live meter's readouts show, written by its display ticks (at most
/// 10 Hz, the summary once a second) and only when a printed value changes,
/// so the texts that read it re-evaluate when a digit moves and at no other time.
@MainActor @Observable final class LevelMeterReadouts {
  /// Per channel: the held true-peak maximum, and whether it is at or above −1 dBTP.
  private(set) var maxima: [String] = Array(repeating: MeterText.level(-.infinity), count: 16)
  private(set) var hot: [Bool] = Array(repeating: false, count: 16)
  private(set) var isOver = false
  let summary = MeterSummaryStore()
  @ObservationIgnored private let texts = LevelMeterTexts()
  @ObservationIgnored private var last = -Double.infinity

  func update(_ s: AudioMeterSnapshot, channels n: Int, at time: Double) {
    guard time - last >= 0.1 || time < last else { return }
    last = time
    var c = 0
    while c < min(n, 16) {
      let value = c < s.channelCount ? Double(s.channels[c].truePeakMax) : -.infinity
      let text = texts.maxima[c](value)
      if text != maxima[c] { maxima[c] = text }
      if (value >= -1) != hot[c] { hot[c] = value >= -1 }
      c += 1
    }
    let over = s.isOver()
    if over != isOver { isOver = over }
  }
}

/// The meter's three layouts.
struct LevelMeterBody: View {
  let source: LevelMeterSource
  let style: LevelMeterStyle
  let present: Bool
  let labels: [String]
  let scale: MeterScale
  let spans: [MeterZoneSpan]
  let reference: Double?
  let palette: MeterPalette
  /// False inside a host that offers its own menu (`AudioMeterView`: Reset Peaks and Reset Loudness).
  var showsContextMenu = true
  /// The accessibility element's label; nil inside a host that makes its own element (`AudioMeterView`).
  var accessibilityName: String? = nil
  /// Leads the compact style's tooltip ("Camera 1: …").
  var tooltipName: String? = nil
  /// Called on each display tick, after the bars (`AudioMeterView` refreshes its summary).
  var onTick: (@MainActor (Double) -> Void)? = nil
  @State private var animator = LevelMeterAnimator()
  @State private var readouts = LevelMeterReadouts()

  private var n: Int { labels.count }
  private var live: Bool { present && source.isLive }

  var body: some View {
    // Readings that don't move (no audio, or fixed readings) are read here, once per update.
    let fixed = live ? nil : source.read()
    Group {
      switch style {
      case .compact: compact
      case .strip: strip(fixed)
      case .full: full(fixed)
      }
    }
    .contextMenu {
      if source.isLive && showsContextMenu { Button("Reset Peaks") { resetPeaks() } }
    }
    .modifier(
      LevelMeterAccessibility(
        name: accessibilityName, tooltip: style == .compact ? (tooltipName.map { "\($0): " } ?? "") : nil,
        summary: readouts.summary,
        fixed: fixed.map { MeterText.peakSummary($0, channels: n, present: present) },
        current: { MeterText.peakSummary(source.read(), channels: n, present: present) },
        reset: source.isLive ? { resetPeaks() } : nil))
  }

  private func resetPeaks() {
    source.meter?.resetPeaks()
    animator.resetHolds()
  }

  /// The bars: layers the display link moves, one snapshot per frame.
  private func bars(_ axis: Axis, gap: CGFloat, holdWidth: CGFloat, overDot: CGFloat = 0) -> some View {
    let source = source, present = present, n = n, scale = scale, spans = spans, reference = reference
    let animator = animator, readouts = readouts, onTick = onTick
    return MeterLayerRepresentable(live: live, palette: palette) { frame, layers, colors in
      animator.configure(fallRate: source.fallRate, holdTime: source.holdTime)
      let s = source.read()
      if present {
        animator.advance(s, channels: n, scale: scale, at: frame.time, animate: source.isLive)
      } else {
        animator.showNothing(channels: n)
      }
      let size = frame.size
      let barsSize = CGSize(width: size.width - (overDot > 0 ? overDot + 3 : 0), height: size.height)
      LevelMeterView.layout(
        animator.layouts, spans: spans, reference: reference, axis: axis, size: barsSize, gap: gap,
        holdWidth: holdWidth
      ) { rect, part in
        layers.fill(rect, colors(part))
      }
      if overDot > 0 {
        let d = min(overDot, size.height)
        let dot = CGRect(x: size.width - d, y: (size.height - d) / 2, width: d, height: d)
        if animator.isOver {
          layers.fill(dot, colors.over, radius: d / 2)
        } else {
          layers.outline(dot, colors.outline, radius: d / 2)
        }
      }
      if frame.isTick {
        readouts.update(s, channels: n, at: frame.time)
        readouts.summary.update(at: frame.time) { MeterText.peakSummary(s, channels: n, present: present) }
        onTick?(frame.time)
      }
    }
  }

  // MARK: Compact

  private var compact: some View {
    let r = LevelMeterView.rows(.compact, channels: n)
    return bars(.horizontal, gap: r.gap, holdWidth: 1.5, overDot: 6)
      .frame(width: 56, height: max(6, LevelMeterView.rowsHeight(.compact, channels: n)))
      .opacity(present ? 1 : 0.4)
      .contentShape(Rectangle())
      .onTapGesture { resetPeaks() }
  }

  // MARK: Strip

  private func strip(_ fixed: AudioMeterSnapshot?) -> some View {
    let r = LevelMeterView.rows(.strip, channels: n)
    let height = LevelMeterView.rowsHeight(.strip, channels: n)
    return VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .top, spacing: 4) {
        // Row labels while they fit their rows (up to four channels); the readouts name every channel.
        if n <= 4 {
          VStack(spacing: r.gap) {
            ForEach(0..<n, id: \.self) { c in
              Text(labels[c]).font(.system(size: n <= 2 ? 8 : 6.5, weight: .semibold)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(height: r.thickness)
            }
          }
          // A long label truncates rather than squeezing the bars.
          .frame(minWidth: 9, maxWidth: 28, alignment: .leading)
        }
        VStack(spacing: 2) {
          bars(.horizontal, gap: r.gap, holdWidth: 2).frame(height: height)
          LevelMeterRuler(ticks: scale.ticks, axis: .horizontal).frame(height: 14)
        }
      }
      .opacity(present ? 1 : 0.4)
      HStack(alignment: .top, spacing: 8) {
        if present {
          // Four channels to a line.
          VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<(n + 3) / 4, id: \.self) { line in
              HStack(spacing: 8) {
                ForEach(line * 4..<min(n, line * 4 + 4), id: \.self) { c in
                  // The number stays whole; a long label truncates to fit the strip.
                  HStack(spacing: 3) {
                    Text(labels[c]).foregroundStyle(.secondary).truncationMode(.tail)
                    maximum(fixed, c).fixedSize()
                  }
                }
                if line == (n - 1) / 4 { Text("dBTP").foregroundStyle(.secondary).fixedSize() }
              }
            }
          }
        } else {
          Text("No audio").foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        latch(fixed).fixedSize()
      }
      .font(.system(size: 10).monospacedDigit())
      .lineLimit(1)
    }
  }

  /// A channel's held maximum, red at or above −1 dBTP.
  private func maximum(_ fixed: AudioMeterSnapshot?, _ c: Int) -> some View {
    LevelMeterMaximum(
      readouts: readouts, channel: c,
      fixed: fixed.map { c < $0.channelCount ? Double($0.channels[c].truePeakMax) : -.infinity }, palette: palette)
  }

  private func latch(_ fixed: AudioMeterSnapshot?) -> some View {
    LevelMeterLatch(
      readouts: readouts, fixed: fixed.map { present && $0.isOver() }, palette: palette,
      action: source.isLive ? { resetPeaks() } : nil)
  }

  // MARK: Full

  private func full(_ fixed: AudioMeterSnapshot?) -> some View {
    let gap = LevelMeterView.rows(.full, channels: n).gap
    let ruler: CGFloat = 26
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("dBTP").font(.system(size: 9)).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        latch(fixed)
      }
      HStack(alignment: .top, spacing: 3) {
        LevelMeterRuler(ticks: scale.ticks, axis: .vertical, inset: 5).frame(width: ruler)
        bars(.vertical, gap: gap, holdWidth: 2).padding(.vertical, 5)
          .opacity(present ? 1 : 0.4)
          .overlay {
            if !present {
              Text("No audio").font(.caption).foregroundStyle(.secondary).padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
          }
      }
      .frame(maxHeight: .infinity)
      HStack(spacing: 3) {
        Color.clear.frame(width: ruler, height: 1)
        HStack(spacing: gap) {
          ForEach(0..<n, id: \.self) { c in
            Text(labels[c]).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
              .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
          }
        }
      }
      HStack(spacing: 3) {
        Color.clear.frame(width: ruler, height: 1)
        HStack(spacing: gap) {
          ForEach(0..<n, id: \.self) { c in
            Group { if present { maximum(fixed, c) } else { Text("—").foregroundStyle(.secondary) } }
              .font(.system(size: 9).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
  }
}

/// A channel's held maximum: from the live readouts, or the fixed reading.
/// Its own view, so a new digit re-evaluates this text and nothing around it.
struct LevelMeterMaximum: View {
  let readouts: LevelMeterReadouts
  let channel: Int
  let fixed: Double?
  let palette: MeterPalette
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let text = fixed.map { MeterText.level($0) } ?? readouts.maxima[channel]
    let hot = fixed.map { $0 >= -1 } ?? readouts.hot[channel]
    Text(text).foregroundStyle(hot ? AnyShapeStyle(palette.readoutOver(scheme)) : AnyShapeStyle(.primary))
  }
}

/// The over latch on the live readouts, or lit from the fixed reading.
struct LevelMeterLatch: View {
  let readouts: LevelMeterReadouts
  let fixed: Bool?
  let palette: MeterPalette
  let action: (() -> Void)?

  var body: some View {
    OverLatch(lit: fixed ?? readouts.isOver, palette: palette, action: action)
  }
}

/// The meter's one accessibility element (and the compact style's tooltip),
/// reading the summary its ticks refresh: a new summary re-evaluates this
/// modifier, not the meter.
struct LevelMeterAccessibility: ViewModifier {
  let name: String?
  let tooltip: String?
  let summary: MeterSummaryStore
  /// The summary of readings that don't move; nil for a live meter.
  let fixed: String?
  /// The live meter's summary now: until its first display tick has written one (and in a
  /// render that never ticks, such as a snapshot).
  let current: () -> String
  let reset: (() -> Void)?

  func body(content: Content) -> some View {
    let text = fixed ?? (summary.text.isEmpty ? current() : summary.text)
    if let name {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(text)
        .accessibilityActions {
          // Fixed readings have nothing to reset.
          if let reset { Button("Reset Peaks") { reset() } }
        }
        .modifier(LevelMeterTooltip(text: tooltip.map { $0 + text }))
    } else {
      content
    }
  }
}

/// The over latch: "OVER" in red while lit, an outline otherwise. Clicking resets the peaks.
struct OverLatch: View {
  let lit: Bool
  let palette: MeterPalette
  let action: (() -> Void)?

  var body: some View {
    Button {
      action?()
    } label: {
      Text("OVER")
        .font(.system(size: 9, weight: .heavy))
        .tracking(0.5)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(lit ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tertiary))
        .background(RoundedRectangle(cornerRadius: 3).fill(lit ? palette.latch : .clear))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lit ? .clear : Color.secondary.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .help(
      lit
        ? "An over since the last reset: a sample clipped or the true peak reached −1 dBTP. Click to reset the peaks."
        : "Lights on a clipped sample or a true peak at −1 dBTP or above, and stays lit until clicked.")
    .accessibilityLabel(lit ? "Over" : "No over")
  }
}

/// A scale's ticks and labels beside the bars. Static: redrawn only on a size change.
struct LevelMeterRuler: View {
  let ticks: [MeterTick]
  let axis: Axis
  /// Space kept at both ends of the travel for the end labels (vertical).
  var inset: CGFloat = 0

  var body: some View {
    Canvas { context, size in
      let along = (axis == .horizontal ? size.width : size.height) - 2 * inset
      var lastLabel = -CGFloat.infinity
      // Labels from the top down, so the top of the scale keeps its labels when they crowd.
      for tick in ticks.reversed() {
        let p = CGFloat(tick.position) * along
        let length: CGFloat = tick.isReference ? 4 : tick.isMajor ? 3 : 2
        let shading: GraphicsContext.Shading = .color(tick.isReference ? .primary : .secondary)
        var line = Path()
        if axis == .horizontal {
          line.move(to: CGPoint(x: inset + p, y: 0))
          line.addLine(to: CGPoint(x: inset + p, y: length))
        } else {
          let y = inset + along - p
          line.move(to: CGPoint(x: size.width - length, y: y))
          line.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(line, with: shading, lineWidth: tick.isReference ? 1.5 : 1)
        guard let label = tick.label else { continue }
        let text = context.resolve(
          Text(label).font(.system(size: 8, weight: tick.isReference ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(tick.isReference ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
        let measured = text.measure(in: size)
        if axis == .horizontal {
          let x = min(max(inset + p - measured.width / 2, 0), size.width - measured.width)
          // Right to left: skip a label that would touch the one to its right.
          if lastLabel.isFinite && x + measured.width + 3 > lastLabel { continue }
          context.draw(text, in: CGRect(x: x, y: 4, width: measured.width, height: measured.height))
          lastLabel = x
        } else {
          let y = min(max(inset + along - p - measured.height / 2, 0), size.height - measured.height)
          if lastLabel.isFinite && y < lastLabel + 1 { continue }
          context.draw(
            text, in: CGRect(x: size.width - length - 2 - measured.width, y: y, width: measured.width, height: measured.height))
          lastLabel = y + measured.height
        }
      }
    }
    .accessibilityHidden(true)
  }
}

/// The compact style's tooltip; no tooltip for the other styles, which print their numbers.
struct LevelMeterTooltip: ViewModifier {
  let text: String?

  func body(content: Content) -> some View {
    if let text { content.help(text) } else { content }
  }
}

/// A palette resolved for one appearance: every part's colour built once per
/// body evaluation, so drawing a frame builds no colour (a zone's dimmed
/// colour, `Color.opacity`, allocates each time it is made).
struct LevelMeterColors {
  let well: Color
  let reference: Color
  /// The compact style's unlit over dot.
  let outline: Color
  /// By `MeterZoneKind`: normal, target, caution, over.
  private let lit: [Color]
  private let unlit: [Color]

  init(_ palette: MeterPalette, scheme: ColorScheme) {
    well = palette.track(for: scheme)
    reference = palette.reference
    outline = Color.secondary.opacity(0.7)
    let zones: [MeterZoneKind] = [.normal, .target, .caution, .over]
    lit = zones.map { palette.color($0) }
    unlit = zones.map { palette.color($0).opacity(palette.unlitOpacity) }
  }

  private static func index(_ zone: MeterZoneKind?) -> Int {
    switch zone {
    case .normal?, nil: return 0
    case .target?: return 1
    case .caution?: return 2
    case .over?: return 3
    }
  }

  /// `MeterPalette.color(_:scheme:)` without building a colour.
  func callAsFunction(_ part: LevelMeterPart) -> Color {
    switch part {
    case .well: return well
    case .unlit(let zone): return unlit[Self.index(zone)]
    case .lit(let zone), .hold(let zone?): return lit[Self.index(zone)]
    case .hold(nil): return lit[0]
    case .reference: return reference
    }
  }
}
