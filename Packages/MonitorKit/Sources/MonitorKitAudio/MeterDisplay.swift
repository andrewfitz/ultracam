// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation

// What a level-meter display needs on top of `MeterScale`: the expanded-top
// peak scale, zone spans and ticks on the travel, one channel's layout, the
// display ballistics that keep bars smooth between snapshots, the over latch,
// PLR and readout text. Pure values (no UI framework), so any renderer can
// use them and the tests check them directly. `MonitorKitUI`'s
// `LevelMeterView` and `AudioMeterView` draw them.

/// One zone's stretch of the travel, 0 (bottom) to 1 (top).
public struct MeterZoneSpan: Sendable, Hashable {
  public var lower: Double
  public var upper: Double
  public var kind: MeterZoneKind

  public init(lower: Double, upper: Double, kind: MeterZoneKind) {
    self.lower = lower
    self.upper = upper
    self.kind = kind
  }
}

/// A scale mark placed on the travel.
public struct MeterTick: Sendable, Hashable {
  /// In the scale's unit.
  public var value: Double
  /// 0 (bottom) to 1 (top).
  public var position: Double
  /// The printed text (with a typographic minus); nil for an unlabelled tick.
  public var label: String?
  public var isMajor: Bool
  /// The scale's alignment or reference level (SMPTE RP 155 −20 dBFS on
  /// `expandedPeak`): drawn as a line across the bars.
  public var isReference: Bool

  public init(value: Double, position: Double, label: String?, isMajor: Bool, isReference: Bool) {
    self.value = value
    self.position = position
    self.label = label
    self.isMajor = isMajor
    self.isReference = isReference
  }
}

/// One channel laid out on a scale's travel.
public struct MeterChannelLayout: Sendable, Hashable {
  /// The bar's length, 0…1; 0 at or below the bottom and in silence.
  public var bar: Double
  /// The hold line, nil when there is nothing to hold.
  public var hold: Double?
  /// The zone of the bar's level; nil in silence.
  public var zone: MeterZoneKind?
  /// The zone of the hold line's level.
  public var holdZone: MeterZoneKind?

  public init(bar: Double = 0, hold: Double? = nil, zone: MeterZoneKind? = nil, holdZone: MeterZoneKind? = nil) {
    self.bar = bar
    self.hold = hold
    self.zone = zone
    self.holdZone = holdZone
  }

  /// The lit part of each zone: the zone's own fixed stretch clipped at the
  /// bar, so colours stay put on the scale and never stretch with the level.
  public func litSpans(_ spans: [MeterZoneSpan]) -> [MeterZoneSpan] {
    spans.compactMap { span in
      bar > span.lower ? MeterZoneSpan(lower: span.lower, upper: min(span.upper, bar), kind: span.kind) : nil
    }
  }
}

extension MeterScale {
  /// A digital peak meter with an expanded top, for programme metering at a
  /// glance: −60…0 on a piecewise mapping (−60 → 0, −40 → 0.12, −20 → 0.40,
  /// 0 → 1), so the 20 dB that matter take 60 % of the travel. Marks at
  /// −40/−30/−20/−12/−9/−6/−3/0 (labelled) and a minor tick at −18 (EBU R 68
  /// alignment). Zones fixed in dB: normal below `cautionLevel` (−9, EBU R 68's
  /// permitted maximum), caution up to `maximumPeak` (−1 dBTP, EBU R 128's
  /// maximum true peak), over from there. `reference` (SMPTE RP 155, −20 dBFS,
  /// the reference tone of most cameras) is the alignment, drawn as a line.
  public static func expandedPeak(
    unit: MeterScaleUnit = .dBTP, reference: AlignmentLevel = .smpte, cautionLevel: Double = -9,
    maximumPeak: Double = -1
  ) -> MeterScale {
    precondition(unit == .dBFS || unit == .dBTP, "a digital peak scale is in dBFS or dBTP")
    precondition(-60 < cautionLevel && cautionLevel <= maximumPeak && maximumPeak <= 0, "zones out of order")
    var values: [Double] = [-40, -30, -20, -18, -12, -9, -6, -3, 0]
    if (-60...0).contains(reference.dBFS), !values.contains(reference.dBFS) { values.append(reference.dBFS) }
    values.sort()
    let labelled: Set<Double> = [-40, -30, -20, -12, -9, -6, -3, 0]
    return MeterScale(
      unit: unit, lowerBound: -60, upperBound: 0,
      mapping: .piecewise([
        MeterScalePoint(-60, 0), MeterScalePoint(-40, 0.12), MeterScalePoint(-20, 0.40), MeterScalePoint(0, 1),
      ]),
      marks: values.map { v in
        let major = labelled.contains(v)
        return MeterScaleMark(value: v, label: major ? MeterText.number(v) : nil, isMajor: major)
      },
      zones: [
        MeterZone(lower: -60, upper: cautionLevel, kind: .normal),
        MeterZone(lower: cautionLevel, upper: maximumPeak, kind: .caution),
        MeterZone(lower: maximumPeak, upper: 0, kind: .over),
      ].filter { $0.upper > $0.lower },
      alignment: (-60...0).contains(reference.dBFS) ? reference.dBFS : nil, permittedMaximum: cautionLevel)
  }

  /// The zones on the travel, bottom up. Fixed per scale: compute once, not per frame.
  public var zoneSpans: [MeterZoneSpan] {
    zones.map { MeterZoneSpan(lower: position(of: $0.lower), upper: position(of: $0.upper), kind: $0.kind) }
  }

  /// The marks on the travel; the one at `alignment` is the reference.
  public var ticks: [MeterTick] {
    marks.map {
      MeterTick(
        value: $0.value, position: position(of: $0.value), label: $0.label, isMajor: $0.isMajor,
        isReference: $0.value == alignment)
    }
  }

  /// One channel's bar and hold line from levels in the scale's unit
  /// (−∞ is silence). The hold never sits below the bar.
  public func layout(level: Double, hold: Double? = nil) -> MeterChannelLayout {
    let bar = position(of: level)
    let holdLevel = hold.map { Swift.max($0, level) }
    var holdPosition: Double?
    if let holdLevel {
      let p = position(of: holdLevel)
      if p > 0 { holdPosition = p }
    }
    return MeterChannelLayout(
      bar: bar, hold: holdPosition, zone: bar > 0 ? zone(of: level) : nil,
      holdZone: holdPosition == nil ? nil : holdLevel.flatMap { zone(of: $0) })
  }
}

/// Smooth display of a peak meter between snapshots.
///
/// A meter publishes when audio arrives, often once per video frame (24 to 60
/// a second), while a display draws at up to 120 Hz. Between snapshots the
/// fall is extrapolated from elapsed time (the fall is the meter's own,
/// `fallRate` dB per second); an attack shows the frame its snapshot
/// arrives. Each snapshot's value holds for `lead`, a little over one
/// snapshot interval (learned from the arrivals, 8 to 100 ms), before it
/// falls: a steady tone, re-attacked by every snapshot, then stands still
/// instead of sagging and snapping back at the snapshot rate, at the cost of
/// a fall that starts one snapshot late. Two curves are kept: the strongest
/// attack still in play and the latest snapshot, which floors the display at
/// a lower level that holds after a transient.
public struct MeterDisplayBallistics: Sendable, Equatable {
  public let fallRate: Double

  private struct Curve: Sendable, Equatable {
    var value = -Double.infinity
    var anchor: Double = 0
    func at(_ time: Double, lead: Double, rate: Double) -> Double {
      value - rate * Swift.max(0, time - anchor - lead)
    }
  }

  private var attack = Curve()
  private var latest = Curve()
  private var lastArrival: Double?
  /// How long a snapshot holds before it falls.
  public private(set) var lead: Double = 1.25 / 24

  /// `fallRate` in dB per second; the default is IEC 60268-18's 20 dB in 1.7 s
  /// (`AudioMeterConfiguration.peakDecayRate`).
  public init(fallRate: Double = 20 / 1.7) {
    self.fallRate = fallRate
  }

  /// A new snapshot's value arrived at `time` (seconds, any monotonic origin).
  /// A time before the last arrival (a clock that stepped back) is a new
  /// origin: the curves move with it, so the display carries on from where it
  /// stood instead of holding until the clock catches up.
  public mutating func ingest(_ value: Double, at time: Double) {
    if let lastArrival, time > lastArrival {
      let interval = Swift.min(time - lastArrival, 0.1)
      lead = Swift.min(Swift.max(lead * 0.9 + 1.25 * interval * 0.1, 0.008), 0.1)
    } else if let lastArrival, time < lastArrival {
      let shift = time - lastArrival
      attack.anchor += shift
      latest.anchor += shift
    }
    lastArrival = time
    // A floor that is on top carries on as the attack curve: continuous, never lower.
    if latest.at(time, lead: lead, rate: fallRate) > attack.at(time, lead: lead, rate: fallRate) { attack = latest }
    let incoming = Curve(value: value.isNaN ? -.infinity : value, anchor: time)
    if incoming.value >= attack.at(time, lead: lead, rate: fallRate) { attack = incoming }
    latest = incoming
  }

  /// The displayed value at `time`.
  public func value(at time: Double) -> Double {
    Swift.max(attack.at(time, lead: lead, rate: fallRate), latest.at(time, lead: lead, rate: fallRate))
  }

  /// Back to silence.
  public mutating func reset() { self = MeterDisplayBallistics(fallRate: fallRate) }
}

/// A display's peak-hold line: takes the bar's peaks (and the meter's own
/// hold, which catches a peak inside a snapshot), holds `holdTime`, then falls
/// at `fallRate`. A renderer draws `max(value(at:), bar)`.
public struct MeterHoldLine: Sendable, Equatable {
  public let holdTime: Double
  public let fallRate: Double
  private var peak = -Double.infinity
  private var anchor: Double = 0

  /// The defaults match `AudioMeterConfiguration`: 2 s, then 20 dB in 1.7 s.
  public init(holdTime: Double = 2, fallRate: Double = 20 / 1.7) {
    self.holdTime = holdTime
    self.fallRate = fallRate
  }

  public func value(at time: Double) -> Double {
    peak - fallRate * Swift.max(0, time - anchor - holdTime)
  }

  /// Takes `level` if it is at or above the line. A time before the line's
  /// anchor (a clock that stepped back) restarts the hold from `time`, so the
  /// line never waits for the clock to catch up.
  public mutating func offer(_ level: Double, at time: Double) {
    if time < anchor { anchor = time }
    guard level.isFinite, level >= value(at: time) else { return }
    peak = level
    anchor = time
  }

  public mutating func reset() { self = MeterHoldLine(holdTime: holdTime, fallRate: fallRate) }
}

extension AudioChannelLevels {
  /// The over latch for this channel: a sample clipped, or the true-peak
  /// maximum reached `maximumTruePeak` (EBU R 128: −1 dBTP), since the last
  /// peak reset. Both stay until `AudioMeter.resetPeaks()`, so it stays lit
  /// through silence.
  public func isOver(maximumTruePeak: Float = -1) -> Bool {
    clipCount > 0 || truePeakMax >= maximumTruePeak
  }
}

extension AudioMeterSnapshot {
  /// Any channel's over latch (`AudioChannelLevels.isOver`).
  public func isOver(maximumTruePeak: Float = -1) -> Bool {
    var c = 0
    while c < storedChannelCount {
      if channels[c].isOver(maximumTruePeak: maximumTruePeak) { return true }
      c += 1
    }
    return false
  }

  /// Peak-to-loudness ratio (EBU Tech 3342 note, AES TD1004): the
  /// programme's Max TP minus its integrated loudness, in LU; nil until both exist.
  /// Max TP runs from the last peak reset and the integrated loudness from the
  /// last loudness reset: to measure one programme, reset both at its start.
  public var peakToLoudnessRatio: Double? {
    MeterText.peakToLoudnessRatio(
      maximumTruePeak: Double(programmeMaximumTruePeak), integrated: Double(loudness.integrated))
  }
}

/// Readout text as broadcast meters print it: one decimal, a typographic
/// minus, "−∞" for silence and "—" for no reading.
public enum MeterText {
  public static let minus = "\u{2212}"
  /// At or below this a level reads as silence.
  public static let silenceFloor = -200.0

  /// "−6.2", "+0.4", "0.0"; "−∞" for silence; "—" when not `present` or NaN.
  public static func level(_ decibels: Double, present: Bool = true) -> String {
    guard present, !decibels.isNaN else { return "—" }
    guard decibels > silenceFloor else { return minus + "∞" }
    return signed(decibels)
  }

  /// One decimal with a sign: "+1.2", "−0.4", "0.0".
  public static func signed(_ value: Double) -> String {
    let t = (value * 10).rounded() / 10
    let text = String(format: "%.1f", Swift.abs(t))
    return t > 0 ? "+" + text : t < 0 ? minus + text : text
  }

  /// A quantity without a plus sign (LRA, PLR): "6.2"; "—" when absent.
  public static func amount(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    let t = (value * 10).rounded() / 10
    return (t < 0 ? minus : "") + String(format: "%.1f", Swift.abs(t))
  }

  /// A scale label: "−40", "0", "−4.5"; "−∞" and "∞" at the ends, "—" for NaN.
  public static func number(_ value: Double) -> String {
    guard !value.isNaN else { return "—" }
    let magnitude = Swift.abs(value)
    let text =
      magnitude.isInfinite
      ? "∞" : String(format: magnitude == magnitude.rounded() ? "%.0f" : "%.1f", magnitude)
    return (value < 0 ? minus : "") + text
  }

  /// Phase correlation with two decimals: "+0.82", "−0.40", "0.00"; "—" without a reading.
  public static func correlation(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let t = (value * 100).rounded() / 100
    let text = String(format: "%.2f", Swift.abs(t))
    return t > 0 ? "+" + text : t < 0 ? minus + text : text
  }

  /// Max TP − I in LU; nil until both are finite.
  public static func peakToLoudnessRatio(maximumTruePeak: Double, integrated: Double) -> Double? {
    guard maximumTruePeak.isFinite, integrated.isFinite else { return nil }
    return maximumTruePeak - integrated
  }

  /// Spoken channel names for an accessibility summary: "left" and "right"
  /// for a pair, "channel n" otherwise.
  public static func spokenChannel(_ index: Int, of count: Int) -> String {
    count == 2 ? (index == 0 ? "left" : "right") : "channel \(index + 1)"
  }

  /// A peak meter's VoiceOver summary: "left max −6.2 dBTP, right −7.0, over";
  /// "no audio" when not `present`.
  public static func peakSummary(_ snapshot: AudioMeterSnapshot, channels: Int, present: Bool = true) -> String {
    guard present else { return "no audio" }
    let n = Swift.min(channels, snapshot.storedChannelCount)
    guard n > 0 else { return "no reading" }
    var parts: [String] = []
    for c in 0..<n {
      let maximum = Double(snapshot.channels[c].truePeakMax)
      let value = maximum > silenceFloor ? level(maximum) : "silent"
      let name = spokenChannel(c, of: n)
      parts.append(c == 0 ? "\(name) max \(value)\(value == "silent" ? "" : " dBTP")" : "\(name) \(value)")
    }
    if snapshot.isOver() { parts.append("over") }
    return parts.joined(separator: ", ")
  }
}
