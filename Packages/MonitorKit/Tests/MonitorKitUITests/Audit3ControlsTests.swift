// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitAudio
import SwiftUI
import XCTest

@testable import MonitorKitUI

/// Third audit round: controls and level meters. No test puts a view in a window.
final class Audit3ControlsTests: XCTestCase {
  // MARK: ValueSlider

  /// Core keeps some values past a slider's range (a pinch zoom to 32× on the
  /// 1…16 Zoom slider, a host's zebra level below 0). A VoiceOver increment
  /// used to clamp 32 to 16, a drop; a decrement below the range used to raise it.
  @MainActor func testVoiceOverStepNeverMovesAgainstItsDirection() {
    XCTAssertEqual(ValueSlider.adjusted(32, increment: true, in: 1...16, step: 0.1), 32)
    XCTAssertEqual(ValueSlider.adjusted(32, increment: false, in: 1...16, step: 0.1), 31.9, accuracy: 1e-12)
    XCTAssertEqual(ValueSlider.adjusted(-10, increment: false, in: 0...109, step: 1), -10)
    XCTAssertEqual(ValueSlider.adjusted(-10, increment: true, in: 0...109, step: 1), -9)
    // In range: one step, clamped at the ends.
    XCTAssertEqual(ValueSlider.adjusted(5, increment: true, in: 1...16, step: 1), 6)
    XCTAssertEqual(ValueSlider.adjusted(16, increment: true, in: 1...16, step: 1), 16)
    XCTAssertEqual(ValueSlider.adjusted(1.5, increment: false, in: 1...16, step: 1), 1)
    // No step: a twentieth of the range.
    XCTAssertEqual(ValueSlider.adjusted(0.5, increment: true, in: 0...1, step: nil), 0.55, accuracy: 1e-12)
  }

  // MARK: Level meter geometry

  private func parts(
    _ channels: [MeterChannelLayout], axis: Axis = .vertical, size: CGSize = CGSize(width: 10, height: 100)
  ) -> [(CGRect, LevelMeterPart)] {
    let scale = MeterScale.expandedPeak()
    var out: [(CGRect, LevelMeterPart)] = []
    LevelMeterView.layout(
      channels, spans: scale.zoneSpans, reference: scale.alignment.map { scale.position(of: $0) }, axis: axis,
      size: size
    ) { out.append(($0, $1)) }
    return out
  }

  private func isLit(_ part: LevelMeterPart) -> Bool {
    if case .lit = part { return true }
    return false
  }

  private func isHold(_ part: LevelMeterPart) -> Bool {
    if case .hold = part { return true }
    return false
  }

  /// A NaN bar used to light every zone (`min(upper, .nan)` is `upper`) and a
  /// NaN hold drew a NaN rectangle; −∞ drew a hold line at the bottom.
  func testNonfiniteBarAndHoldDrawNothing() {
    for axis in [Axis.vertical, .horizontal] {
      for hold in [Double.nan, -Double.infinity, -0.5, 0] {
        let out = parts([MeterChannelLayout(bar: .nan, hold: hold)], axis: axis)
        XCTAssertFalse(out.contains { isLit($0.1) }, "\(axis) \(hold)")
        XCTAssertFalse(out.contains { isHold($0.1) }, "\(axis) \(hold)")
        for (rect, part) in out {
          XCTAssertTrue(
            rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite, "\(part)")
        }
      }
    }
  }

  /// Silence, levels over full scale and degenerate sizes from the scale's own layout.
  func testSilenceAndOverFullScaleStayInsideTheWell() {
    let scale = MeterScale.expandedPeak()
    let size = CGSize(width: 10, height: 100)
    let silent = parts([scale.layout(level: -.infinity, hold: -.infinity)])
    XCTAssertFalse(silent.contains { isLit($0.1) || isHold($0.1) })
    let over = parts([scale.layout(level: 6, hold: .infinity)])
    let hold = over.first { isHold($0.1) }
    XCTAssertEqual(hold?.0.minY ?? -1, 0, accuracy: 1e-9, "the hold line sits at the top, inside the well")
    for (rect, _) in over {
      XCTAssertGreaterThanOrEqual(rect.minY, 0)
      XCTAssertLessThanOrEqual(rect.maxY, size.height + 1e-9)
    }
    for bad in [CGSize.zero, CGSize(width: -10, height: 100), CGSize(width: CGFloat.nan, height: 100)] {
      XCTAssertTrue(parts([scale.layout(level: -6, hold: -3)], size: bad).isEmpty, "\(bad)")
    }
  }

  // MARK: Hold line and peak resets

  /// Under an endless hold (`peakHoldTime: .infinity`) a sample-peak bar on a
  /// meter without true peak had no sign of a peak reset (its maximum stays −∞
  /// and nothing clipped), so the display's line stayed at the old peak forever.
  @MainActor func testEndlessHoldFollowsAPeakResetOnSamplePeakBars() {
    let scale = MeterScale.expandedPeak(unit: .dBFS)
    let animator = LevelMeterAnimator(holdTime: .infinity)
    var s = AudioMeterSnapshot()
    s.channelCount = 1
    s.sequence = 1
    s.channels[0] = AudioChannelLevels(samplePeak: -6, samplePeakHold: -6)
    animator.advance(s, channels: 1, kind: .samplePeak, scale: scale, at: 0, animate: true)
    XCTAssertEqual(animator.layouts[0].hold ?? 0, scale.position(of: -6), accuracy: 1e-9)
    // The meter's reset sets its hold to its falling bar.
    s.sequence = 2
    s.channels[0] = AudioChannelLevels(samplePeak: -30, samplePeakHold: -30)
    animator.advance(s, channels: 1, kind: .samplePeak, scale: scale, at: 3, animate: true)
    animator.advance(s, channels: 1, kind: .samplePeak, scale: scale, at: 60, animate: true)
    XCTAssertEqual(animator.layouts[0].hold ?? 0, scale.position(of: -30), accuracy: 1e-9)
  }

  /// The same with a real meter: sample peak only, endless hold, a reset from the host.
  @MainActor func testEndlessHoldFollowsAHostResetOnALiveMeter() throws {
    let meter = try AudioMeter(
      configuration: AudioMeterConfiguration(
        sampleRate: 48000, channelCount: 1, meters: [.samplePeak], peakHoldTime: .infinity))
    let scale = MeterScale.expandedPeak(unit: .dBFS)
    let animator = LevelMeterAnimator(
      fallRate: meter.configuration.peakDecayRate, holdTime: meter.configuration.peakHoldTime)
    var samples = [Float](repeating: 0, count: 800)
    for frame in 0..<400 {
      if frame == 200 { meter.resetPeaks() }
      let amplitude: Float = frame < 3 ? 0.5 : 0.01
      for k in 0..<800 { samples[k] = amplitude * Float(sin(2 * Double.pi * 1000 * Double(k) / 48000)) }
      samples.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: 800) }
      animator.advance(meter.snapshot(), channels: 1, kind: .samplePeak, scale: scale, at: Double(frame) / 60, animate: true)
      if frame == 199 { XCTAssertGreaterThan(animator.layouts[0].hold ?? 0, scale.position(of: -7), "held") }
    }
    XCTAssertLessThan(animator.layouts[0].hold ?? 1, scale.position(of: -30), "the line followed the reset")
  }
}
