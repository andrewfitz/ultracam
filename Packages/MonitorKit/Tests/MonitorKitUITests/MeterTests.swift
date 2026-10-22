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
    let snapshot = meter.snapshot()
    let scale = AudioMeterBarKind.truePeak.defaultScale(for: meter.configuration)
    let zones = MeterZoneSpans(scale)
    let a = MeterBars(snapshot: snapshot, kind: .truePeak, scale: scale, zones: zones, channels: 2, palette: .standard)
    var moved = snapshot
    moved.sequence &+= 1
    XCTAssertTrue(a == MeterBars(snapshot: snapshot, kind: .truePeak, scale: scale, zones: zones, channels: 2, palette: .standard))
    XCTAssertFalse(a == MeterBars(snapshot: moved, kind: .truePeak, scale: scale, zones: zones, channels: 2, palette: .standard))
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
  /// body without the drawing) allocates nothing beyond its readings' own
  /// `MeterScale` calls, as the zone edges are computed once per scale, and the
  /// lit segments cover the travel up to each reading, zone by zone.
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
    for kind in AudioMeterBarKind.allCases {
      let scale = kind.defaultScale(for: config)
      let zones = MeterZoneSpans(scale)
      XCTAssertEqual(zones.kinds, scale.zones.map(\.kind))
      var lit = [CGFloat](repeating: 0, count: 16), rects = 0
      func run() {
        lit = [CGFloat](repeating: 0, count: 16)
        rects = 0
        MeterBars.layout(snapshot: s, kind: kind, scale: scale, zones: zones, channels: 16, size: size) { rect, part in
          rects += 1
          if case .zone = part { lit[Int((rect.minX / (rect.width + 2)).rounded())] += rect.height }
        }
      }
      // Once first: the first use of a type instantiates its metadata.
      run()
      guard
        let layout = AllocationCounter.measure({
          // In place: assigning a new array would copy on the first write.
          var i = 0
          while i < 16 {
            lit[i] = 0
            i += 1
          }
          rects = 0
          MeterBars.layout(snapshot: s, kind: kind, scale: scale, zones: zones, channels: 16, size: size) { rect, part in
            rects += 1
            if case .zone = part { lit[Int((rect.minX / (rect.width + 2)).rounded())] += rect.height }
          }
        })
      else { throw XCTSkip("malloc_logger is unavailable") }
      var sum = 0.0
      let readings = AllocationCounter.measure {
        var ch = 0
        while ch < 16 {
          let r = MeterBarReading(levels: s.channels[ch], kind: kind, scale: scale)
          if let v = r.holdValue, (r.holdPosition ?? 0) > 0 { sum += scale.zone(of: v) == .over ? 1 : 0 }
          sum += r.position
          ch += 1
        }
      }!
      XCTAssertLessThanOrEqual(layout, readings, "\(kind)")
      XCTAssertGreaterThan(rects, 16 * 2)
      let travel = size.height - MeterMetrics.top - MeterMetrics.bottom
      for ch in 0..<16 {
        let r = MeterBarReading(levels: s.channels[ch], kind: kind, scale: scale)
        let expected = CGFloat(max(0, min(r.position, zones.to.last ?? 1) - (zones.from.first ?? 0))) * travel
        XCTAssertEqual(lit[ch], expected, accuracy: 1e-6, "\(kind) channel \(ch)")
      }
    }
  }
}
