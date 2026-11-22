// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import AppKit
import MonitorKitAudio
import SwiftUI
import XCTest

@testable import MonitorKitUI

final class MeterTests: XCTestCase {
  let config = AudioMeterConfiguration(sampleRate: 48000, channelCount: 2)

  func testDefaultScalesFollowTheConfiguration() {
    XCTAssertEqual(AudioMeterBarKind.samplePeak.defaultScale(for: config).unit, .dBFS)
    XCTAssertEqual(AudioMeterBarKind.truePeak.defaultScale(for: config).unit, .dBTP)
    XCTAssertEqual(AudioMeterBarKind.vu.defaultScale(for: config), .vu)
    XCTAssertEqual(AudioMeterBarKind.ppm.defaultScale(for: config), .ppm(.typeIIb))
    var bbc = config
    bbc.ppmType = .typeIIa
    XCTAssertEqual(AudioMeterBarKind.ppm.defaultScale(for: bbc), .ppm(.typeIIa))
    // EBU R 128's −1 dBTP maximum: over above it.
    XCTAssertEqual(AudioMeterBarKind.truePeak.defaultScale(for: config).zone(of: -0.5), .over)
    XCTAssertEqual(AudioMeterBarKind.truePeak.defaultScale(for: config).zone(of: -5), .caution, "above the PML (−9)")
    XCTAssertEqual(AudioMeterBarKind.truePeak.defaultScale(for: config).zone(of: -20), .normal)
    XCTAssertEqual(AudioMeterBarKind.samplePeak.defaultScale(for: config).zone(of: -0.5), .caution)
  }

  func testBarReadings() {
    let peak = AudioMeterBarKind.samplePeak.defaultScale(for: config)
    let levels = AudioChannelLevels(samplePeak: -12, samplePeakHold: -6, truePeak: -11, truePeakHold: -0.5, ppm: 0, clipCount: 0)
    let r = MeterBarReading(levels: levels, kind: .samplePeak, scale: peak)
    XCTAssertEqual(r.value, -12)
    XCTAssertEqual(r.position, peak.position(of: -12))
    XCTAssertEqual(r.position, 48.0 / 60, accuracy: 1e-12, "dB-linear from −60 to 0")
    XCTAssertEqual(r.holdPosition ?? -1, 54.0 / 60, accuracy: 1e-12)
    XCTAssertEqual(r.holdValue, -6)
    XCTAssertEqual(r.zone, .normal)
    XCTAssertFalse(r.isClipping)

    let tp = MeterBarReading(levels: levels, kind: .truePeak, scale: AudioMeterBarKind.truePeak.defaultScale(for: config))
    XCTAssertEqual(tp.holdValue, -0.5)

    // BBC PPM: the alignment level reads mark 4, half way up marks 1 to 7.
    let bbc = MeterScale.ppm(.typeIIa)
    let ppm = MeterBarReading(levels: levels, kind: .ppm, scale: bbc)
    XCTAssertEqual(ppm.value, 4)
    XCTAssertEqual(ppm.position, 0.5, accuracy: 1e-12)
    XCTAssertNil(ppm.holdPosition)

    // VU: deflection proportional to voltage; 0 VU is 10^(−3/20) of the travel.
    var vuLevels = AudioChannelLevels()
    vuLevels.vu = 0
    let vu = MeterBarReading(levels: vuLevels, kind: .vu, scale: .vu)
    XCTAssertEqual(vu.position, pow(10, -3.0 / 20), accuracy: 1e-12)
    XCTAssertEqual(vu.zone, .over, "red from 0 VU")

    let silent = MeterBarReading(levels: AudioChannelLevels(clipCount: 3), kind: .samplePeak, scale: peak)
    XCTAssertEqual(silent.value, -.infinity)
    XCTAssertEqual(silent.position, 0)
    XCTAssertEqual(silent.zone, .normal)
    XCTAssertTrue(silent.isClipping, "the clip LED stays lit until a peak reset")
  }

  func testLoudnessText() {
    XCTAssertEqual(LoudnessReadout.text(-23), "−23.0 LUFS")
    XCTAssertEqual(LoudnessReadout.text(-22, unit: .lu, target: -23), "+1.0 LU")
    XCTAssertEqual(LoudnessReadout.text(-23.04, unit: .lu, target: -23), "0.0 LU")
    XCTAssertEqual(LoudnessReadout.text(-.infinity), "—")
    XCTAssertEqual(LoudnessReadout.text(.nan, unit: .lu), "—")
    XCTAssertEqual(LoudnessReadout.signed(-0.06), "−0.1")
    XCTAssertEqual(LoudnessReadout.signed(3.25), "+3.3")
    var s = AudioMeterSnapshot()
    s.loudness = LoudnessSnapshot(momentary: -20, shortTerm: -21, integrated: -23, loudnessRange: 5)
    let r = LoudnessReadout(s)
    XCTAssertEqual(r.momentary, -20)
    XCTAssertEqual(r.integrated, -23)
    XCTAssertEqual(r.loudnessRange, 5)
  }

  /// A readout builds a string only when its printed digit changes.
  func testReadoutTextFormatsOnlyOnChange() {
    var formats = 0
    let text = ReadoutText { v in
      formats += 1
      return String(format: "%.1f", v)
    }
    XCTAssertEqual(text(-23.01), "-23.0")
    XCTAssertEqual(text(-23.02), "-23.0")
    XCTAssertEqual(text(-23.04), "-23.0")
    XCTAssertEqual(formats, 1)
    XCTAssertEqual(text(-22.9), "-22.9")
    XCTAssertEqual(text(-.infinity), "-inf")
    XCTAssertEqual(text(-.infinity), "-inf")
    XCTAssertEqual(formats, 3)
  }

  func testChannelLabels() {
    XCTAssertEqual(AudioMeterView.standardLabels(channelCount: 2), ["L", "R"])
    XCTAssertEqual(AudioMeterView.standardLabels(channelCount: 6), ["L", "R", "C", "LFE", "Ls", "Rs"])
    XCTAssertEqual(AudioMeterView.standardLabels(channelCount: 4), ["1", "2", "3", "4"])
    XCTAssertEqual(AudioMeterView.standardLabels(channelCount: 16).count, 16)
  }

  /// What a meter computes per frame (16 channels, every kind) allocates
  /// nothing beyond the `MeterScale` calls it makes (unoptimized, `zone(of:)`
  /// and piecewise `position(of:)` allocate in MonitorKitAudio's own code).
  func testReadingsAllocateNothing() throws {
    var s = AudioMeterSnapshot()
    s.channelCount = 16
    var c = 0
    while c < 16 {
      s.channels[c] = AudioChannelLevels(samplePeak: Float(-c), samplePeakHold: -1, truePeak: -2, truePeakHold: -1, ppm: 1)
      c += 1
    }
    let kinds = AudioMeterBarKind.allCases
    let scales = kinds.map { $0.defaultScale(for: config) }
    var sum = 0.0
    guard let readings = AllocationCounter.measure({
      var k = 0
      while k < kinds.count {
        var ch = 0
        while ch < s.channelCount {
          let r = MeterBarReading(levels: s.channels[ch], kind: kinds[k], scale: scales[k])
          sum += r.position + (r.holdPosition ?? 0)
          ch += 1
        }
        k += 1
      }
      _ = LoudnessReadout(s)
    }) else { throw XCTSkip("malloc_logger is unavailable") }
    // The same MeterScale calls alone.
    let scaleCalls = AllocationCounter.measure {
      var k = 0
      while k < kinds.count {
        var ch = 0
        while ch < s.channelCount {
          let scale = scales[k]
          let v = scale.value(forReading: -3)
          sum += scale.position(of: v) + (scale.zone(of: v) == .over ? 1 : 0)
          if k < 2 { sum += scale.position(of: scale.value(forReading: -1)) }
          ch += 1
        }
        k += 1
      }
    }!
    print("BENCH meter readings: \(readings) heap allocations per frame of 16 × 5 bars; MeterScale's calls alone: \(scaleCalls)")
    XCTAssertLessThanOrEqual(readings, scaleCalls)
    // The linear scales' value and position, and the snapshot copy, are allocation-free.
    let linear = AllocationCounter.measure {
      var ch = 0
      while ch < s.channelCount {
        let levels = s.channels[ch]
        sum += scales[0].position(forReading: Double(levels.samplePeak)) + MeterScale.vu.position(forReading: Double(levels.vu))
        ch += 1
      }
    }!
    XCTAssertEqual(linear, 0)
    XCTAssertGreaterThan(sum, 0)
  }

  /// The view hosts and lays out against a live meter; the bars redraw only when
  /// the snapshot's sequence moves.
  @MainActor
  func testMeterViewLaysOut() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    var samples = [Float](repeating: 0, count: 4800 * 2)
    for i in 0..<4800 {
      let v = Float(0.125 * sin(2 * Double.pi * 1000 * Double(i) / 48000))
      samples[2 * i] = v
      samples[2 * i + 1] = v
    }
    for _ in 0..<10 { samples.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: 4800) } }
    meter.flush()
    for kind in AudioMeterBarKind.allCases {
      let hosting = NSHostingView(rootView: AudioMeterView(meter: meter, kind: kind, loudness: .ebuPlus18).frame(width: 260, height: 180))
      hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 180)
      hosting.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(hosting.fittingSize.width, 0)
    }
    for style in LevelMeterStyle.allCases {
      let hosting = NSHostingView(rootView: LevelMeterView(meter: meter, style: style, name: "Camera 1").frame(width: 260, height: 120))
      hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 120)
      hosting.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(hosting.fittingSize.width, 0, "\(style)")
    }
    let snapshot = meter.snapshot()
    // A −18 dBFS sine reads its level on the peak meter.
    let r = MeterBarReading(levels: snapshot.channels[0], kind: .samplePeak, scale: AudioMeterBarKind.samplePeak.defaultScale(for: meter.configuration))
    XCTAssertEqual(r.value, 20 * log10(0.125), accuracy: 0.1)
  }
}

extension MeterTests {
  func testShortLabelListsArePadded() {
    XCTAssertEqual(AudioMeterView.labels(["Dlg", "M&E"], channelCount: 4), ["Dlg", "M&E", "3", "4"])
    XCTAssertEqual(AudioMeterView.labels(["A", "B", "C"], channelCount: 2), ["A", "B"])
    XCTAssertEqual(AudioMeterView.labels(nil, channelCount: 2), ["L", "R"])
  }
}

extension MeterTests {
  /// One frame of 16 bars on every kind's scale: the bars' layout (the Canvas
  /// body without the drawing) allocates nothing beyond the channel layouts'
  /// own `MeterScale` calls, as the zone spans are computed once per scale, and
  /// the lit segments cover the travel up to each reading, zone by zone.
  func testBarLayoutAllocatesNothingBeyondItsReadings() throws {
    var s = AudioMeterSnapshot()
    s.channelCount = 16
    var c = 0
    while c < 16 {
      let level = Float(-2 * c)
      s.channels[c] = AudioChannelLevels(
        samplePeak: level, samplePeakHold: level + 1, truePeak: level, truePeakHold: level + 1, rms: level - 3,
        vu: level / 4, ppm: 4 - level / 2)
      c += 1
    }
    let size = CGSize(width: 200, height: 220)
    let gap: CGFloat = 2
    for kind in AudioMeterBarKind.allCases {
      let scale = kind == .truePeak ? MeterScale.expandedPeak() : kind.defaultScale(for: config)
      let spans = scale.zoneSpans
      XCTAssertEqual(spans.map(\.kind), scale.zones.map(\.kind))
      let layouts = (0..<16).map { ch -> MeterChannelLayout in
        let r = MeterBarReading(levels: s.channels[ch], kind: kind, scale: scale)
        return scale.layout(level: r.value, hold: r.holdValue)
      }
      let width = (size.width - gap * 15) / 16
      var lit = [CGFloat](repeating: 0, count: 16), rects = 0
      func run() {
        LevelMeterView.layout(layouts, spans: spans, reference: 0.4, axis: .vertical, size: size, gap: gap) { rect, part in
          rects += 1
          if case .lit = part { lit[Int((rect.minX / (width + gap)).rounded())] += rect.height }
        }
      }
      // Once first: the first use of a type instantiates its metadata.
      run()
      guard
        let layout = AllocationCounter.measure({
          var i = 0
          while i < 16 {
            lit[i] = 0
            i += 1
          }
          rects = 0
          run()
        })
      else { throw XCTSkip("malloc_logger is unavailable") }
      XCTAssertEqual(layout, 0, "\(kind)")
      XCTAssertGreaterThan(rects, 16 * 2)
      for ch in 0..<16 {
        let expected = CGFloat(max(0, min(layouts[ch].bar, spans.last?.upper ?? 1) - (spans.first?.lower ?? 0))) * size.height
        XCTAssertEqual(lit[ch], expected, accuracy: 1e-6, "\(kind) channel \(ch)")
      }
    }
  }
}

extension MeterTests {
  func testLevelMeterLabels() {
    XCTAssertEqual(LevelMeterView.labels(nil, channelCount: 2), ["L", "R"])
    XCTAssertEqual(LevelMeterView.labels(nil, channelCount: 8), ["1", "2", "3", "4", "5", "6", "7", "8"])
    XCTAssertEqual(LevelMeterView.labels(["Mic"], channelCount: 2), ["Mic", "2"])
  }

  /// Horizontal rows: zones fixed on the travel, the hold line where it
  /// belongs and the −20 reference line across every row.
  func testLevelMeterRowLayout() {
    let scale = MeterScale.expandedPeak()
    let channels = [scale.layout(level: -6, hold: -3), scale.layout(level: -.infinity)]
    let size = CGSize(width: 100, height: 12)
    var parts: [(CGRect, LevelMeterPart)] = []
    LevelMeterView.layout(
      channels, spans: scale.zoneSpans, reference: scale.position(of: -20), axis: .horizontal, size: size, gap: 2
    ) { parts.append(($0, $1)) }
    let wells = parts.filter { $0.1 == .well }.map(\.0)
    XCTAssertEqual(wells, [CGRect(x: 0, y: 0, width: 100, height: 5), CGRect(x: 0, y: 7, width: 100, height: 5)])
    let lit = parts.filter { if case .lit = $0.1 { true } else { false } }
    XCTAssertEqual(lit.map(\.1), [.lit(.normal), .lit(.caution)], "only the first row is lit")
    XCTAssertEqual(lit[0].0.maxX, 73, accuracy: 1e-9, "green ends at −9 whatever the level")
    XCTAssertEqual(lit[1].0.maxX, 82, accuracy: 1e-9, "the bar ends at −6")
    let hold = parts.first { if case .hold = $0.1 { true } else { false } }
    XCTAssertEqual(hold?.1, .hold(.caution))
    XCTAssertEqual(hold?.0.midX ?? 0, 91, accuracy: 1e-9, "the hold line at −3")
    let reference = parts.last
    XCTAssertEqual(reference?.1, .reference)
    XCTAssertEqual(reference?.0, CGRect(x: 39.5, y: 0, width: 1, height: 12))
    // Vertical bars run bottom up.
    var top = CGFloat.infinity
    LevelMeterView.layout([scale.layout(level: 0)], spans: scale.zoneSpans, reference: nil, axis: .vertical,
      size: CGSize(width: 10, height: 100)) { rect, part in if case .lit(.over) = part { top = rect.minY } }
    XCTAssertEqual(top, 0, accuracy: 1e-9)
  }

  /// The animator ingests a new snapshot once, extrapolates between, and
  /// restarts the hold line when the meter's maximum is reset.
  @MainActor func testLevelMeterAnimator() {
    let scale = MeterScale.expandedPeak()
    let animator = LevelMeterAnimator()
    var s = AudioMeterSnapshot()
    s.channelCount = 2
    s.sequence = 1
    s.channels[0] = AudioChannelLevels(truePeak: -6, truePeakHold: -6, truePeakMax: -6)
    animator.advance(s, channels: 2, scale: scale, at: 100, animate: true)
    XCTAssertEqual(animator.layouts.count, 2)
    XCTAssertEqual(animator.layouts[0].bar, scale.position(of: -6), accuracy: 1e-9)
    XCTAssertFalse(animator.isOver)
    // One second later with no new snapshot: fallen, the hold line still up.
    animator.advance(s, channels: 2, scale: scale, at: 101, animate: true)
    XCTAssertLessThan(animator.layouts[0].bar, scale.position(of: -15))
    XCTAssertEqual(animator.layouts[0].hold ?? 0, scale.position(of: -6), accuracy: 1e-9)
    // A peak reset clears the maximum: the line starts over from the bar.
    s.sequence = 2
    s.channels[0] = AudioChannelLevels(truePeak: -30, truePeakHold: -30, truePeakMax: -.infinity)
    animator.advance(s, channels: 2, scale: scale, at: 101.1, animate: true)
    XCTAssertLessThan(animator.layouts[0].hold ?? 0, scale.position(of: -15))
    s.sequence = 3
    s.channels[1] = AudioChannelLevels(truePeak: -0.5, truePeakHold: -0.5, truePeakMax: -0.5)
    animator.advance(s, channels: 2, scale: scale, at: 101.2, animate: true)
    XCTAssertTrue(animator.isOver)
    animator.showNothing(channels: 2)
    XCTAssertEqual(animator.layouts, [MeterChannelLayout(), MeterChannelLayout()])
  }
}

// MARK: Audit regressions (0.1.3)

extension MeterTests {
  /// Feeds `frames` of a 1 kHz tone at `amplitude` (0 for silence) to both channels.
  private func feed(_ meter: AudioMeter, amplitude: Float, frames: Int) {
    var left = [Float](repeating: 0, count: frames)
    for k in 0..<frames { left[k] = amplitude * Float(sin(2 * Double.pi * 1000 * Double(k) / 48000)) }
    var right = left
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        let pointers = [l.baseAddress!, r.baseAddress!]
        pointers.withUnsafeBufferPointer { meter.process(planar: $0.baseAddress!, frameCount: frames) }
      }
    }
  }

  /// A burst, then silence, one video frame of audio per display frame: the
  /// hold line holds 2 s from the burst, then falls. Offering the meter's own
  /// hold with every snapshot used to restart the line until the meter's hold
  /// ran out, so it held for 4 s.
  @MainActor func testHoldLineHoldsTwoSeconds() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let scale = MeterScale.expandedPeak()
    let animator = LevelMeterAnimator(
      fallRate: meter.configuration.peakDecayRate, holdTime: meter.configuration.peakHoldTime)
    var fell: Double?
    var peak = 0.0
    for frame in 0..<(60 * 5) {
      let t = Double(frame) / 60
      feed(meter, amplitude: frame < 3 ? 0.5 : 0, frames: 800)
      animator.advance(meter.snapshot(), channels: 2, scale: scale, at: t, animate: true)
      let hold = animator.layouts[0].hold ?? 0
      if frame == 2 { peak = hold }
      if frame > 2, fell == nil, hold < peak - 1e-6 { fell = t }
    }
    let start = try XCTUnwrap(fell, "the line fell")
    XCTAssertEqual(start, 2 + 2.0 / 60, accuracy: 0.1, "2 s after the last attack, not 4")
  }

  /// A peak reset from outside the view (the host, AudioMeterView's menu,
  /// VoiceOver) restarts the hold line even while audio keeps flowing.
  @MainActor func testHostPeakResetRestartsTheHoldLine() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let scale = MeterScale.expandedPeak()
    let animator = LevelMeterAnimator()
    for frame in 0..<110 {
      if frame == 100 { meter.resetPeaks() }
      feed(meter, amplitude: frame < 3 ? 0.5 : 0.01, frames: 800)
      animator.advance(meter.snapshot(), channels: 2, scale: scale, at: Double(frame) / 60, animate: true)
      if frame == 99 { XCTAssertGreaterThan(animator.layouts[0].hold ?? 0, scale.position(of: -7), "held") }
    }
    // 1.6 s after the burst its bar has fallen to about −25 dBTP; the line starts over there.
    XCTAssertLessThan(animator.layouts[0].hold ?? 0, scale.position(of: -20), "the line starts over from the bar")
  }

  /// A wall clock stepping back an hour neither freezes the bars nor the hold lines.
  @MainActor func testAnimatorSurvivesAClockSteppingBack() {
    let scale = MeterScale.expandedPeak()
    let animator = LevelMeterAnimator()
    var s = AudioMeterSnapshot()
    s.channelCount = 1
    s.sequence = 1
    s.channels[0] = AudioChannelLevels(truePeak: -6, truePeakHold: -6, truePeakMax: -6)
    animator.advance(s, channels: 1, scale: scale, at: 1000, animate: true)
    animator.advance(s, channels: 1, scale: scale, at: 1000 - 3600, animate: true)
    animator.advance(s, channels: 1, scale: scale, at: 1000 - 3600 + 1, animate: true)
    XCTAssertLessThan(animator.layouts[0].bar, scale.position(of: -15), "1 s of fall since the step")
    animator.advance(s, channels: 1, scale: scale, at: 1000 - 3600 + 8, animate: true)
    XCTAssertNil(animator.layouts[0].hold, "the hold line has fallen away too")
  }

  /// Drawing a frame builds no colour: the resolved colours match the
  /// palette's and cost no allocation per rectangle.
  func testLevelMeterColorsMatchThePaletteAndAllocateNothing() throws {
    let palette = MeterPalette.standard
    var parts: [LevelMeterPart] = [.well, .reference, .hold(nil)]
    for zone in MeterZoneKind.allCases { parts += [.lit(zone), .unlit(zone), .hold(zone)] }
    for scheme in [ColorScheme.light, .dark] {
      let colors = LevelMeterColors(palette, scheme: scheme)
      for part in parts { XCTAssertEqual(colors(part), palette.color(part, scheme: scheme), "\(part) \(scheme)") }
      _ = colors(.unlit(.over))
      var i = 0
      guard
        let count = AllocationCounter.measure({
          while i < parts.count {
            _ = colors(parts[i])
            i += 1
          }
        })
      else { throw XCTSkip("malloc_logger is unavailable") }
      XCTAssertEqual(count, 0, "\(scheme)")
    }
  }

  private func luminance(_ color: Color) -> Double {
    let c = color.resolve(in: EnvironmentValues())
    return 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
  }

  private func contrast(_ a: Color, _ b: Color) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }

  /// WCAG contrast: the zones on both wells (graphics, 3:1; 4.5:1 on the
  /// dark well as documented), a red readout on the window in both
  /// appearances (text, 4.5:1), the latch's white text, and luminance steps
  /// between the zones for colour-blind viewers.
  func testMeterColoursKeepTheirContrast() {
    let p = MeterPalette.standard
    for zone in [p.normal, p.caution, p.over] {
      XCTAssertGreaterThanOrEqual(contrast(zone, p.track), 4.5)
      XCTAssertGreaterThanOrEqual(contrast(zone, p.lightTrack), 3)
    }
    XCTAssertGreaterThanOrEqual(contrast(p.readoutOver(.light), .white), 4.5)
    XCTAssertGreaterThanOrEqual(contrast(p.readoutOver(.light), Color(white: 0.93)), 4.5)
    XCTAssertGreaterThanOrEqual(contrast(p.readoutOver(.dark), Color(white: 0.196)), 4.5)
    XCTAssertGreaterThanOrEqual(contrast(p.readoutOver(.dark), Color(white: 0.118)), 4.5)
    XCTAssertLessThan(contrast(p.over, .white), 4.5, "why light appearance needs the darker red")
    XCTAssertGreaterThanOrEqual(contrast(.white, p.latch), 4.5)
    let (green, amber, red) = (luminance(p.normal), luminance(p.caution), luminance(p.over))
    XCTAssertGreaterThan(amber, green)
    XCTAssertGreaterThan(green, red * 1.5)
  }

  /// Long channel labels truncate: the strip keeps to the width it is offered.
  @MainActor func testStripFitsLongLabels() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 4)
    let long = ["Camera One Left", "Camera One Right", "Lavalier Microphone", "Boom Microphone"]
    for labels in [long, ["1", "2", "3", "4"]] {
      let host = NSHostingController(rootView: LevelMeterView(meter: meter, style: .strip, channelLabels: labels))
      XCTAssertLessThanOrEqual(host.sizeThatFits(in: CGSize(width: 240, height: 400)).width, 240, "\(labels)")
    }
  }

  /// Max TP of digital silence reads "−∞ dBTP" like the level meters' maxima; "—" only without a reading.
  @MainActor func testMaximumTruePeakReadsMinusInfinityInSilence() {
    let texts = LoudnessTexts()
    var r = LoudnessReadout(AudioMeterSnapshot())
    r.maximumTruePeak = -.infinity
    XCTAssertEqual(texts.strings(r, unit: .lufs, target: -23).peak, "−∞ dBTP")
    r.maximumTruePeak = .nan
    XCTAssertEqual(texts.strings(r, unit: .lufs, target: -23).peak, "—")
    r.maximumTruePeak = -0.44
    XCTAssertEqual(texts.strings(r, unit: .lufs, target: -23).peak, "−0.4 dBTP")
  }
}
