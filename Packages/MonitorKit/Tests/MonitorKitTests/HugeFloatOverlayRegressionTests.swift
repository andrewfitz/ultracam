// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKitCore
import XCTest

@testable import MonitorKit

/// A finite float RGB sample past Float.greatestFiniteMagnitude / 100 (an
/// rgba32Float frame can carry one) overflowed to +inf when the overlays scaled
/// it to percent. The clip indicator's "off" level is ±inf, so with over (or
/// under) switched off such a pixel was still painted in the over (under)
/// colour, and a lower-limit zebra, whose top is +inf, never striped it; the
/// CPU references (`ClipIndicatorSettings`, `ZebraSettings`) say the opposite.
final class HugeFloatOverlayRegressionTests: XCTestCase {
  private func draw(_ gpu: TestGPU, _ values: [SIMD3<Double>], state: MonitorState, height: Int = 1) throws -> Pixels {
    let signal = SignalDescription(range: .full, encoding: .display(.bt709))
    var picture = SyntheticFrame(layout: .rgba32Float, width: values.count, height: height)
    picture.rgb = (0..<height).flatMap { _ in values }
    let frame = try picture.frame(gpu, signal: signal)
    return try gpu.render(frame, state: state, width: values.count, height: height, format: .bgra8Unorm)
  }

  func testHugeFiniteSampleIsNotFlaggedByASwitchedOffClipLevel() throws {
    let gpu = try requireGPU()
    // 3e38 · 100 overflows Float; 2 is an ordinary super-white; -3e38 its mirror.
    let values: [SIMD3<Double>] = [SIMD3(repeating: 3e38), SIMD3(repeating: 2), SIMD3(repeating: -3e38), SIMD3(repeating: -1)]
    var clip = MonitorState()
    clip.clipIndicators.enabled = true
    clip.clipIndicators.stage = .source
    clip.clipIndicators.coloring = .uniform
    clip.clipIndicators.overColor = ColorRGB(r: 1, g: 0, b: 0)
    clip.clipIndicators.underColor = ColorRGB(r: 0, g: 0, b: 1)
    clip.clipIndicators.opacity = 1

    let both = try draw(gpu, values, state: clip)
    XCTAssertEqual(both.rgb(0, 0), SIMD3(1, 0, 0), "over on: flagged over")
    XCTAssertEqual(both.rgb(2, 0), SIMD3(0, 0, 1), "under on: flagged under")

    var underOnly = clip
    underOnly.clipIndicators.showsOver = false
    let u = try draw(gpu, values, state: underOnly)
    XCTAssertEqual(u.rgb(1, 0), SIMD3(1, 1, 1), "an ordinary super-white is not flagged with over off")
    XCTAssertEqual(u.rgb(0, 0), u.rgb(1, 0), "a huge super-white is not flagged with over off either")

    var overOnly = clip
    overOnly.clipIndicators.showsUnder = false
    let o = try draw(gpu, values, state: overOnly)
    XCTAssertEqual(o.rgb(3, 0), SIMD3(0, 0, 0), "an ordinary sub-black is not flagged with under off")
    XCTAssertEqual(o.rgb(2, 0), o.rgb(3, 0), "a huge sub-black is not flagged with under off either")
  }

  func testLowerLimitZebraStripesAHugeFiniteSample() throws {
    let gpu = try requireGPU()
    let values: [SIMD3<Double>] = [SIMD3(repeating: 3e38), SIMD3(repeating: 2)]
    var zebra = MonitorState()
    zebra.zebras[1].enabled = true
    zebra.zebras[1].mode = .lowerLimit
    zebra.zebras[1].level = 95
    zebra.zebras[1].opacity = 1
    zebra.zebras[1].stage = .source
    XCTAssertTrue(zebra.zebras[1].covers(ire: 3e38 * 100), "the CPU reference stripes it")
    // Set 2 (dark, on white) stripes run along x - y: pixel (1, y + 1) has (0, y)'s phase.
    let z = try draw(gpu, values, state: zebra, height: 16)
    var striped = 0
    for y in 0..<15 {
      XCTAssertEqual(z.rgb(0, y), z.rgb(1, y + 1), "row \(y): the huge sample stripes like a super-white")
      if z.rgb(1, y + 1) != SIMD3(1, 1, 1) { striped += 1 }
    }
    XCTAssertGreaterThan(striped, 0)
  }
}
