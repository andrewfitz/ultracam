// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitAudio
import SwiftUI
import XCTest

@testable import MonitorKitUI

final class Fresh20ReadoutTests: XCTestCase {
  func testFixedLoudnessPairLayoutAllocatesNothing() throws {
    let scale = MeterScale.loudness(.ebuPlus9)
    let spans = scale.zoneSpans
    let m = scale.layout(level: -3)
    let st = scale.layout(level: 3)
    var rectangles = 0
    func run() {
      LevelMeterView.layoutChannels(
        .pair(m, st), spans: spans, reference: 0.4, axis: .vertical,
        size: CGSize(width: 24, height: 180), gap: 3
      ) { _, _ in rectangles += 1 }
    }
    run()
    guard let allocations = AllocationCounter.measure({ run() }) else {
      throw XCTSkip("malloc_logger is unavailable")
    }
    XCTAssertEqual(allocations, 0)
    XCTAssertGreaterThan(rectangles, 0)
  }

  func testFixedLoudnessPairMatchesArrayRenderer() {
    let scale = MeterScale.loudness(.ebuPlus9)
    let spans = scale.zoneSpans
    let reference = scale.alignment.map { scale.position(of: $0) }
    for axis in [Axis.horizontal, .vertical] {
      for level in [-Double.infinity, -24, -18, -1, 0, 3, 9, 15] {
        let m = scale.layout(level: level, hold: 3)
        let st = scale.layout(level: -6, hold: 0)
        for size in [CGSize(width: 24, height: 180), CGSize(width: 220, height: 17), .zero] {
          var expectedRects: [CGRect] = []
          var expectedParts: [LevelMeterPart] = []
          var actualRects: [CGRect] = []
          var actualParts: [LevelMeterPart] = []
          LevelMeterView.layout([m, st], spans: spans, reference: reference, axis: axis, size: size, gap: 3) {
            expectedRects.append($0)
            expectedParts.append($1)
          }
          LevelMeterView.layoutChannels(
            .pair(m, st), spans: spans, reference: reference, axis: axis, size: size, gap: 3
          ) {
            actualRects.append($0)
            actualParts.append($1)
          }
          XCTAssertEqual(actualRects, expectedRects)
          XCTAssertEqual(actualParts, expectedParts)
        }
      }
    }
  }

  func testSelectedMeterKindControlsSpokenReading() {
    var snapshot = AudioMeterSnapshot()
    snapshot.channelCount = 1
    snapshot.channels[0] = AudioChannelLevels(truePeakMax: -1, rms: -18)
    let scale = MeterScale.digitalPeak(unit: .dBFS, alignment: .init(dBFS: -20), maximumPeak: 0)
    let text = AudioMeterView.channelSummary(snapshot, kind: .rms, scale: scale, channels: 1, present: true)
    XCTAssertTrue(text.contains("RMS −18.0 dBFS"))
    XCTAssertFalse(text.contains("dBTP"))
  }

  @MainActor
  func testRelativeReadoutsInvalidateAtRelativeDigitBoundaries() {
    let texts = LoudnessTexts()
    var snapshot = AudioMeterSnapshot()
    snapshot.loudness = LoudnessSnapshot(momentary: -23.03, shortTerm: -23.03, integrated: -23.03)
    let first = texts.strings(LoudnessReadout(snapshot), unit: .lu, target: -23.04)
    XCTAssertEqual(first.momentary, "0.0 LU")
    snapshot.loudness = LoudnessSnapshot(momentary: -22.96, shortTerm: -22.96, integrated: -22.96)
    let second = texts.strings(LoudnessReadout(snapshot), unit: .lu, target: -23.04)
    XCTAssertEqual(second.momentary, "+0.1 LU")
    XCTAssertEqual(second.shortTerm, "+0.1 LU")
    XCTAssertEqual(second.integrated, "+0.1 LU")
  }
}
