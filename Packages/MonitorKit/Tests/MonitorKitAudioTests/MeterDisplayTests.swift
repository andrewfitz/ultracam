// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MonitorKitAudio
import XCTest

/// The level-meter display model: the expanded-top scale, zones, ticks, the
/// display ballistics, the over latch, PLR, readout text and correlation.
final class MeterDisplayTests: XCTestCase {
  let scale = MeterScale.expandedPeak()

  /// Exact positions on the piecewise travel and the zone each level reads in.
  func testBarFractionsAndZones() {
    let expected: [(Double, Double, MeterZoneKind)] = [
      (-20, 0.40, .normal), (-18, 0.46, .normal), (-9, 0.73, .caution), (-1, 0.97, .over), (0, 1, .over),
    ]
    for (level, fraction, zone) in expected {
      let layout = scale.layout(level: level)
      XCTAssertEqual(layout.bar, fraction, accuracy: 1e-12, "\(level) dBTP")
      XCTAssertEqual(layout.zone, zone, "\(level) dBTP")
    }
    XCTAssertEqual(scale.position(of: -40), 0.12, accuracy: 1e-12)
    XCTAssertEqual(scale.position(of: -60), 0)
    XCTAssertEqual(scale.layout(level: -.infinity).bar, 0)
    XCTAssertNil(scale.layout(level: -.infinity).zone, "silence has no zone")
    XCTAssertEqual(scale.layout(level: 3).bar, 1, "above full scale pins to the top")
    XCTAssertEqual(scale.layout(level: 3).zone, .over)
  }

  /// −9.0 is amber, −9.0001 green; −1.0 red, −1.0001 amber.
  func testZoneBoundaries() {
    XCTAssertEqual(scale.zone(of: -9.0), .caution)
    XCTAssertEqual(scale.zone(of: -9.0001), .normal)
    XCTAssertEqual(scale.zone(of: -1.0), .over)
    XCTAssertEqual(scale.zone(of: -1.0001), .caution)
    let spans = scale.zoneSpans
    XCTAssertEqual(spans.map(\.kind), [.normal, .caution, .over])
    XCTAssertEqual(spans[0].lower, 0)
    XCTAssertEqual(spans[0].upper, 0.73, accuracy: 1e-12)
    XCTAssertEqual(spans[1].upper, 0.97, accuracy: 1e-12)
    XCTAssertEqual(spans[2].upper, 1)
  }

  /// Lit spans are each zone's own stretch clipped at the bar: colours never move.
  func testLitSpansClipAtTheBar() {
    let spans = scale.zoneSpans
    let lit = scale.layout(level: -6).litSpans(spans)
    XCTAssertEqual(lit.count, 2)
    XCTAssertEqual(lit[0], MeterZoneSpan(lower: 0, upper: spans[0].upper, kind: .normal))
    XCTAssertEqual(lit[1].lower, spans[1].lower)
    XCTAssertEqual(lit[1].upper, 0.82, accuracy: 1e-12)
    XCTAssertEqual(lit[1].kind, .caution)
    XCTAssertTrue(scale.layout(level: -.infinity).litSpans(spans).isEmpty)
    XCTAssertEqual(scale.layout(level: 0).litSpans(spans), spans)
  }

  func testTicks() {
    let ticks = scale.ticks
    XCTAssertEqual(ticks.map(\.value), [-40, -30, -20, -18, -12, -9, -6, -3, 0])
    let positions: [Double] = [0.12, 0.26, 0.40, 0.46, 0.64, 0.73, 0.82, 0.91, 1.0]
    for (tick, p) in zip(ticks, positions) { XCTAssertEqual(tick.position, p, accuracy: 1e-12, "\(tick.value)") }
    XCTAssertEqual(ticks.map(\.label), ["−40", "−30", "−20", nil, "−12", "−9", "−6", "−3", "0"])
    XCTAssertEqual(ticks.filter(\.isReference).map(\.value), [-20], "SMPTE RP 155 reference")
    XCTAssertEqual(ticks.filter { !$0.isMajor }.map(\.value), [-18], "EBU alignment is a minor tick")
    XCTAssertEqual(scale.alignment, -20)
    XCTAssertEqual(scale.unit, .dBTP)
    // An EBU reference moves the line to −18 and keeps −20 labelled.
    let ebu = MeterScale.expandedPeak(reference: .ebu)
    XCTAssertEqual(ebu.ticks.filter(\.isReference).map(\.value), [-18])
  }

  /// A real meter: sines at each level read their level, position and zone.
  func testSinesReadOnTheScale() throws {
    for level in [-20.0, -18, -9, -1, 0] {
      let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
      // fs/4 at 90°: the samples land on the peaks, so sample and true peak agree.
      let signal = Signal.tone(frequency: 12000, dBFS: level, seconds: 0.5, sampleRate: 48000)
      meter.feed(signal)
      let reading = Double(meter.snapshot().channels[0].truePeak)
      XCTAssertEqual(reading, level, accuracy: 0.05, "\(level) dBFS")
      XCTAssertEqual(scale.layout(level: reading).bar, scale.position(of: level), accuracy: 0.002, "\(level)")
    }
  }

  /// Between snapshots the bar falls at 20 dB per 1.7 s after its lead.
  func testExtrapolatedDecay() {
    var b = MeterDisplayBallistics()
    XCTAssertEqual(b.fallRate, 20 / 1.7, accuracy: 1e-12)
    b.ingest(0, at: 10)
    let lead = b.lead
    XCTAssertEqual(b.value(at: 10), 0, "attack shows at once")
    XCTAssertEqual(b.value(at: 10 + lead), 0, accuracy: 1e-9, "held for the lead")
    XCTAssertEqual(b.value(at: 10 + lead + 1.7), -20, accuracy: 1e-9)
    XCTAssertEqual(b.value(at: 10 + lead + 0.85), -10, accuracy: 1e-9)
    // A higher snapshot attacks at once; a lower one floors the fall.
    b.ingest(-3, at: 11)
    XCTAssertEqual(b.value(at: 11), max(-3, -20 / 1.7 * (1 - lead)), accuracy: 1e-9)
    // After a transient, a steady lower level (re-published each snapshot) floors the fall.
    var floor = MeterDisplayBallistics()
    floor.ingest(-6, at: 0)
    floor.ingest(-30, at: 1.0 / 30)
    XCTAssertGreaterThan(floor.value(at: 1.0 / 30), -7, "the transient's curve stays on top")
    var t = 2.0 / 30
    while t < 4 {
      floor.ingest(-30, at: t)
      t += 1.0 / 30
    }
    XCTAssertEqual(floor.value(at: t), -30, accuracy: 1e-9, "then the lower level holds")
  }

  /// A steady tone re-attacked by every snapshot stands still between them.
  func testSteadyToneStandsStill() {
    var b = MeterDisplayBallistics()
    var t = 0.0
    var worst = 0.0
    for _ in 0..<120 {
      b.ingest(-20, at: t)
      for k in 0..<4 { worst = max(worst, abs(b.value(at: t + Double(k) / 120) + 20)) }
      t += 1 / 30
    }
    XCTAssertLessThan(worst, 1e-9, "no sag between 30 Hz snapshots")
    XCTAssertGreaterThan(b.lead, 1 / 30, "the lead learned the snapshot interval")
    XCTAssertLessThan(b.lead, 0.1)
  }

  func testHoldLine() {
    var h = MeterHoldLine()
    h.offer(-6, at: 0)
    XCTAssertEqual(h.value(at: 1.99), -6)
    XCTAssertEqual(h.value(at: 2 + 1.7), -26, accuracy: 1e-9, "after 2 s it falls at 20 dB / 1.7 s")
    h.offer(-10, at: 1)
    XCTAssertEqual(h.value(at: 1), -6, "a lower level does not move it")
    h.offer(-3, at: 1)
    XCTAssertEqual(h.value(at: 2.5), -3, "a higher one takes it and restarts the hold")
    h.reset()
    XCTAssertEqual(h.value(at: 0), -.infinity)
  }

  /// The latch stays lit through silence until a peak reset, and lights on a
  /// true-peak over that no sample reaches.
  func testOverLatchThroughSilenceAndOnTruePeak() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    // fs/4 at 45°: every sample is at 0.707 of the peak. Samples at −0.5 dBFS,
    // so the waveform between them peaks at +2.5 dBTP.
    let samples = Signal.sine(frequency: 12000, dBFS: -0.5 + 20 * log10(2.0.squareRoot()), seconds: 0.5,
      sampleRate: 48000, phaseDegrees: 45)
    meter.feed(Signal(sampleRate: 48000, channels: [samples, samples]))
    var s = meter.snapshot()
    XCTAssertEqual(Double(s.channels[0].samplePeak), -0.5, accuracy: 0.01)
    XCTAssertGreaterThan(s.channels[0].truePeakMax, -1)
    XCTAssertEqual(s.channels[0].clipCount, 0, "no sample clips")
    XCTAssertTrue(s.isOver(), "a true-peak over lights the latch")
    meter.feed(Signal.silence(seconds: 5, sampleRate: 48000))
    s = meter.snapshot()
    XCTAssertLessThan(s.channels[0].truePeak, -50, "the bar has fallen")
    XCTAssertTrue(s.isOver(), "still lit after 5 s of silence")
    meter.resetPeaks()
    XCTAssertFalse(meter.snapshot().isOver(), "a reset clears it at once")
    meter.feed(Signal.silence(seconds: 0.1, sampleRate: 48000))
    XCTAssertFalse(meter.snapshot().isOver())

    // A clipped sample lights it whatever the true peak.
    var clipped = AudioChannelLevels(truePeakMax: -12, clipCount: 1)
    XCTAssertTrue(clipped.isOver())
    clipped.clipCount = 0
    XCTAssertFalse(clipped.isOver())
    XCTAssertTrue(AudioChannelLevels(truePeakMax: -1).isOver(), "−1 dBTP is over")
    XCTAssertFalse(AudioChannelLevels(truePeakMax: -1.0001).isOver())
  }

  func testReadoutText() {
    XCTAssertEqual(MeterText.level(-.infinity), "−∞")
    XCTAssertEqual(MeterText.level(.nan), "—")
    XCTAssertEqual(MeterText.level(-6.2, present: false), "—")
    XCTAssertEqual(MeterText.level(-6.24), "−6.2")
    XCTAssertEqual(MeterText.level(-6.25), "−6.3")
    XCTAssertEqual(MeterText.level(-0.04), "0.0")
    XCTAssertEqual(MeterText.level(0.36), "+0.4")
    XCTAssertEqual(MeterText.level(-23), "−23.0")
    XCTAssertFalse(MeterText.level(-1).contains("-"), "typographic minus, not a hyphen")
    XCTAssertEqual(MeterText.amount(6.25), "6.3")
    XCTAssertEqual(MeterText.amount(nil), "—")
    XCTAssertEqual(MeterText.amount(.infinity), "—")
    XCTAssertEqual(MeterText.number(-40), "−40")
    XCTAssertEqual(MeterText.number(0), "0")
    XCTAssertEqual(MeterText.correlation(0.824), "+0.82")
    XCTAssertEqual(MeterText.correlation(-0.4), "−0.40")
    XCTAssertEqual(MeterText.correlation(.nan), "—")
  }

  func testPeakToLoudnessRatio() {
    XCTAssertEqual(MeterText.peakToLoudnessRatio(maximumTruePeak: -1, integrated: -23), 22)
    XCTAssertEqual(MeterText.peakToLoudnessRatio(maximumTruePeak: -6.5, integrated: -16), 9.5)
    XCTAssertNil(MeterText.peakToLoudnessRatio(maximumTruePeak: -1, integrated: -.infinity))
    XCTAssertNil(MeterText.peakToLoudnessRatio(maximumTruePeak: -.infinity, integrated: -23))
    var s = AudioMeterSnapshot()
    s.channelCount = 2
    s.programmeChannelMask = 0b11
    s.channels[0] = AudioChannelLevels(truePeakMax: -3)
    s.channels[1] = AudioChannelLevels(truePeakMax: -2)
    s.loudness = LoudnessSnapshot(integrated: -24)
    XCTAssertEqual(s.peakToLoudnessRatio ?? .nan, 22, accuracy: 1e-6, "the programme's Max TP (−2) − I")
  }

  func testPeakSummary() {
    var s = AudioMeterSnapshot()
    s.channelCount = 2
    s.channels[0] = AudioChannelLevels(truePeakMax: -6.2)
    s.channels[1] = AudioChannelLevels(truePeakMax: -7.04)
    XCTAssertEqual(MeterText.peakSummary(s, channels: 2), "left max −6.2 dBTP, right −7.0")
    s.channels[1].clipCount = 2
    XCTAssertEqual(MeterText.peakSummary(s, channels: 2), "left max −6.2 dBTP, right −7.0, over")
    XCTAssertEqual(MeterText.peakSummary(s, channels: 2, present: false), "no audio")
    XCTAssertEqual(MeterText.peakSummary(AudioMeterSnapshot(), channels: 2), "no reading")
    var silent = AudioMeterSnapshot()
    silent.channelCount = 3
    XCTAssertEqual(MeterText.peakSummary(silent, channels: 3), "channel 1 max silent, channel 2 silent, channel 3 silent")
  }

  // MARK: Correlation

  private func correlation(left: [Float], right: [Float], channels: Int = 2, meters: AudioMeterKinds = .all) throws -> Float {
    var config = AudioMeterConfiguration(sampleRate: 48000, channelCount: channels, meters: meters)
    if channels > 2 { config.loudnessChannels = LoudnessChannel.programmePair(channelCount: channels, first: 0) }
    let meter = try AudioMeter(configuration: config)
    var planar = [left, right]
    while planar.count < channels { planar.append([Float](repeating: 0, count: left.count)) }
    meter.feed(Signal(sampleRate: 48000, channels: Array(planar.prefix(channels))))
    return meter.snapshot().correlation
  }

  func testCorrelation() throws {
    let sine = Signal.sine(frequency: 997, dBFS: -12, seconds: 2, sampleRate: 48000)
    let cosine = Signal.sine(frequency: 997, dBFS: -12, seconds: 2, sampleRate: 48000, phaseDegrees: 90)
    let silence = [Float](repeating: 0, count: sine.count)
    let noise = Signal.noise(amplitude: 0.3, frames: sine.count, seed: 7)
    let other = Signal.noise(amplitude: 0.3, frames: sine.count, seed: 99)
    XCTAssertEqual(try correlation(left: sine, right: sine), 1, accuracy: 1e-4, "mono")
    XCTAssertEqual(try correlation(left: sine, right: sine.map { -$0 }), -1, accuracy: 1e-4, "out of phase")
    XCTAssertEqual(try correlation(left: sine, right: cosine), 0, accuracy: 0.02, "quadrature")
    XCTAssertEqual(try correlation(left: noise, right: other), 0, accuracy: 0.1, "unrelated")
    XCTAssertEqual(try correlation(left: sine, right: silence), 0, "one side silent")
    XCTAssertTrue(try correlation(left: silence, right: silence).isNaN, "nothing to correlate")
    XCTAssertTrue(try correlation(left: sine, right: sine, meters: [.truePeak]).isNaN, "off")
    let mono = try AudioMeter(sampleRate: 48000, channelCount: 1)
    mono.feed(Signal(sampleRate: 48000, channels: [sine]))
    XCTAssertTrue(mono.snapshot().correlation.isNaN, "one channel")
  }

  func testCorrelationChannels() {
    XCTAssertNil(AudioMeterConfiguration(sampleRate: 48000, channelCount: 1).correlationChannels)
    XCTAssertEqual(AudioMeterConfiguration(sampleRate: 48000, channelCount: 2).correlationChannels?.left, 0)
    XCTAssertEqual(AudioMeterConfiguration(sampleRate: 48000, channelCount: 6).correlationChannels?.right, 1)
    var pair = AudioMeterConfiguration(sampleRate: 48000, channelCount: 4)
    pair.loudnessChannels = LoudnessChannel.programmePair(channelCount: 4, first: 2)
    XCTAssertEqual(pair.correlationChannels?.left, 2)
    XCTAssertEqual(pair.correlationChannels?.right, 3)
    var bad = AudioMeterConfiguration(sampleRate: 48000, channelCount: 2)
    bad.correlationTime = 0
    XCTAssertThrowsError(try AudioMeter(configuration: bad))
  }

  /// A full reset clears the correlation; it builds again from new audio.
  func testCorrelationResets() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let sine = Signal.sine(frequency: 997, dBFS: -12, seconds: 1, sampleRate: 48000)
    meter.feed(Signal(sampleRate: 48000, channels: [sine, sine]))
    XCTAssertEqual(meter.snapshot().correlation, 1, accuracy: 1e-4)
    meter.reset()
    XCTAssertTrue(meter.snapshot().correlation.isNaN)
    meter.feed(Signal(sampleRate: 48000, channels: [sine, sine.map { -$0 }]))
    XCTAssertEqual(meter.snapshot().correlation, -1, accuracy: 1e-4)
  }
}

// MARK: Audit regressions (0.1.3)

extension MeterDisplayTests {
  /// A clock that steps back is a new origin: the bar carries on falling from
  /// where it stood instead of freezing until the clock catches up.
  func testBallisticsCarryOnWhenTheClockStepsBack() {
    var b = MeterDisplayBallistics()
    b.ingest(-6, at: 1000)
    let lead = b.lead
    // An hour back, with a quieter snapshot.
    b.ingest(-40, at: -2600)
    XCTAssertEqual(b.value(at: -2600), -6, accuracy: 1e-9, "continuous across the step")
    XCTAssertEqual(b.value(at: -2600 + 1.7 + lead), -26, accuracy: 1e-9, "and falls at 20 dB / 1.7 s")
    b.ingest(-40, at: -2595)
    XCTAssertEqual(b.value(at: -2595), -40, accuracy: 1e-9, "down to the next snapshot")
  }

  func testHoldLineCarriesOnWhenTheClockStepsBack() {
    var h = MeterHoldLine()
    h.offer(-6, at: 1000)
    h.offer(-50, at: -2600)
    XCTAssertEqual(h.value(at: -2600), -6, "still held")
    XCTAssertEqual(h.value(at: -2600 + 2 + 1.7), -26, accuracy: 1e-9, "the hold restarts from the step, then falls")
  }

  /// First snapshot: shown at once, held for the default lead (1.25 frames at 24 fps).
  func testFirstSnapshot() {
    var b = MeterDisplayBallistics()
    XCTAssertEqual(b.value(at: 0), -.infinity)
    b.ingest(-12, at: 5)
    XCTAssertEqual(b.lead, 1.25 / 24, accuracy: 1e-12)
    XCTAssertEqual(b.value(at: 5), -12)
    XCTAssertEqual(b.value(at: 5 + 1.25 / 24), -12, accuracy: 1e-12)
    b.ingest(.nan, at: 5.01)
    XCTAssertEqual(b.value(at: 5.01), -12, "a NaN snapshot is silence, not a reading")
  }

  /// After a 2 s stall the lead is pushed up once and settles back within a
  /// second of 60 Hz snapshots; nothing ever reads above what was ingested.
  func testLeadRecoversAfterAStall() {
    var b = MeterDisplayBallistics()
    var t = 0.0
    for _ in 0..<120 {
      b.ingest(-10, at: t)
      t += 1.0 / 60
    }
    let settled = b.lead
    XCTAssertEqual(settled, 1.25 / 60, accuracy: 0.002)
    t += 2
    b.ingest(-10, at: t)
    XCTAssertLessThanOrEqual(b.lead, 0.1)
    XCTAssertGreaterThan(b.lead, settled)
    var highest = -Double.infinity
    for _ in 0..<60 {
      t += 1.0 / 60
      b.ingest(-10, at: t)
      for k in 0..<4 { highest = max(highest, b.value(at: t + Double(k) / 240)) }
    }
    XCTAssertLessThan(abs(b.lead - settled), 0.002, "settled again")
    XCTAssertLessThanOrEqual(highest, -10, "no overshoot")
  }

  /// The mapping is monotonic over the whole scale and pins outside it.
  func testExpandedScaleIsMonotonic() {
    var last = -1.0
    var v = -70.0
    while v <= 6 {
      let p = scale.position(of: v)
      XCTAssertGreaterThanOrEqual(p, last, "\(v)")
      XCTAssertTrue((0...1).contains(p))
      last = p
      v += 0.25
    }
    XCTAssertEqual(scale.position(of: .nan), 0)
    XCTAssertEqual(scale.position(of: .infinity), 1)
  }

  /// Scale labels never trap: infinities print as such and NaN as no reading.
  func testScaleNumberHandlesEveryValue() {
    XCTAssertEqual(MeterText.number(-.infinity), "−∞")
    XCTAssertEqual(MeterText.number(.infinity), "∞")
    XCTAssertEqual(MeterText.number(.nan), "—")
    XCTAssertEqual(MeterText.number(-1e300).count, 302, "a minus and 301 digits, no Int conversion")
    XCTAssertEqual(MeterText.number(-4.5), "−4.5")
    XCTAssertEqual(MeterText.number(-0.0), "0")
    XCTAssertEqual(MeterText.number(-18), "−18")
  }

  /// The PLR of a programme is the Max TP and integrated loudness of the same audio.
  func testPeakToLoudnessRatioOfAProgramme() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let sine = Signal.sine(frequency: 997, dBFS: -20, seconds: 5, sampleRate: 48000)
    meter.feed(Signal(sampleRate: 48000, channels: [sine, sine]))
    let s = meter.snapshot()
    // A stereo 997 Hz sine at −20 dBFS reads about −20 LUFS (BS.1770 calibration, +3 dB for two channels).
    let plr = try XCTUnwrap(s.peakToLoudnessRatio)
    XCTAssertEqual(plr, Double(s.programmeMaximumTruePeak) - Double(s.loudness.integrated), accuracy: 1e-9)
    XCTAssertEqual(plr, 0, accuracy: 0.3, "a sine's peak and loudness agree")
  }
}

extension MeterDisplayTests {
  /// A DC offset is not audio: it neither pulls the correlation towards +1
  /// nor counts as signal.
  func testCorrelationIgnoresDC() throws {
    let frames = 96000
    let noise = Signal.noise(amplitude: 0.01, frames: frames, seed: 3)
    let other = Signal.noise(amplitude: 0.01, frames: frames, seed: 11)
    // −40 dBFS of DC on both sides, about 5 dB above the noise (−45 dBFS RMS).
    let offset: Float = 0.01
    XCTAssertEqual(
      try correlation(left: noise.map { $0 + offset }, right: other.map { $0 + offset }), 0, accuracy: 0.1,
      "unrelated noise with a common offset")
    XCTAssertEqual(
      try correlation(left: noise.map { $0 + offset }, right: noise.map { $0 - offset }), 1, accuracy: 1e-3,
      "the same noise with opposite offsets is still mono")
    let dc = [Float](repeating: 0.25, count: frames)
    XCTAssertTrue(try correlation(left: dc, right: dc).isNaN, "DC alone is nothing to correlate")
    XCTAssertEqual(try correlation(left: noise, right: dc), 0, "DC against signal is one side silent")
  }
}
