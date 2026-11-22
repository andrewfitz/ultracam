// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKitCore
import XCTest

@testable import MonitorKit

/// Audit 3 (picture): one test per defect fixed in the picture pass's shaders.
final class Audit3PictureTests: XCTestCase {
  /// One row of a float RGB frame, drawn 1:1 or magnified into `width`.
  func draw(
    _ gpu: TestGPU, _ values: [SIMD3<Double>], encoding: SignalEncoding = .display(.bt709),
    state: MonitorState = MonitorState(), output: MonitorOutputColor = .signalNative,
    format: MTLPixelFormat = .rgba32Float, width: Int? = nil, height: Int = 1
  ) throws -> Pixels {
    let signal = SignalDescription(range: .full, encoding: encoding)
    var picture = SyntheticFrame(layout: .rgba32Float, width: values.count, height: height)
    picture.rgb = (0..<height).flatMap { _ in values }
    let frame = try picture.frame(gpu, signal: signal)
    let pass = gpu.engine.makePass()
    pass.outputColor = output
    return try gpu.render(
      frame, state: state, pass: pass, width: width ?? values.count, height: height, format: format)
  }

  /// A float RGB sample of +inf or NaN reached the overlay mixes as is:
  /// mix(inf, colour, a) is NaN, so a clipped +inf highlight drew black under the
  /// clip indicator meant to flag it (and under a zebra), and the clip indicator's
  /// "off" level (+inf) still flagged it. A NaN on an extended-linear target wrote
  /// -65504. Non-finite samples now read as ±65504 (inf) or 0 (NaN).
  func testAudit3NonFiniteFloatSamplesKeepTheirOverlays() throws {
    let gpu = try requireGPU()
    let inf = Double.infinity, nan = Double.nan
    let values: [SIMD3<Double>] = [
      SIMD3(inf, inf, inf), SIMD3(2, 2, 2), SIMD3(-inf, -inf, -inf), SIMD3(-1, -1, -1),
      SIMD3(nan, nan, nan), SIMD3(0, 0, 0), SIMD3(0.5, nan, 0.5), SIMD3(0.5, 0, 0.5),
    ]
    // No overlay: inf is the widest finite value a target keeps, NaN is 0.
    let linear = try draw(gpu, values, encoding: .display(.linear))
    XCTAssertEqual(linear.rgb(0, 0), SIMD3(repeating: 65504))
    XCTAssertEqual(linear.rgb(2, 0), SIMD3(repeating: -65504))
    XCTAssertEqual(linear.rgb(4, 0), SIMD3(repeating: 0), "NaN is 0, not -65504")
    XCTAssertEqual(linear.rgb(6, 0), linear.rgb(7, 0))

    for format in [MTLPixelFormat.rgba32Float, .bgra8Unorm] {
      var clip = MonitorState()
      clip.clipIndicators.enabled = true
      clip.clipIndicators.stage = .source
      let c = try draw(gpu, values, state: clip, format: format)
      XCTAssertEqual(c.rgb(0, 0), c.rgb(1, 0), "+inf is over, as a finite super-white")
      XCTAssertEqual(c.rgb(0, 0), SIMD3(1, 1, 1), "every channel over: white")
      XCTAssertEqual(c.rgb(2, 0), c.rgb(3, 0), "-inf is under")
      XCTAssertEqual(c.rgb(4, 0), c.rgb(5, 0), "NaN reads as black")
      XCTAssertEqual(c.rgb(6, 0), c.rgb(7, 0))

      // Over off: its level is +inf, which a +inf sample used to reach.
      var under = clip
      under.clipIndicators.showsOver = false
      let u = try draw(gpu, values, state: under, format: format)
      XCTAssertEqual(u.rgb(0, 0), u.rgb(1, 0))
      XCTAssertEqual(u.rgb(0, 0), SIMD3(1, 1, 1), "an over-range sample is not flagged with over off")

      var zebra = MonitorState()
      zebra.zebras[1].enabled = true
      zebra.zebras[1].mode = .lowerLimit
      zebra.zebras[1].level = 95
      zebra.zebras[1].opacity = 1
      zebra.zebras[1].stage = .source
      // Set 2 stripes run along x - y: pixel (1, y + 1) has (0, y)'s stripe phase.
      let z = try draw(gpu, values, state: zebra, format: format, height: 16)
      var striped = 0
      for y in 0..<15 {
        XCTAssertEqual(z.rgb(0, y), z.rgb(1, y + 1), "zebra at row \(y)")
        if z.rgb(0, y) != SIMD3(1, 1, 1) { striped += 1 }
      }
      XCTAssertGreaterThan(striped, 0)
    }
  }

  /// Catmull-Rom on a flat +inf area computed inf - inf = NaN: a magnified
  /// clipped float highlight drew black inside, white at 1:1.
  func testAudit3MagnifiedInfiniteAreaStaysWhite() throws {
    let gpu = try requireGPU()
    let row = [SIMD3<Double>](repeating: SIMD3(repeating: .infinity), count: 4)
    // A 4 × 4 frame fills a 16 × 16 target: 4× magnified, Catmull-Rom.
    let signal = SignalDescription(range: .full, encoding: .display(.bt709))
    var picture = SyntheticFrame(layout: .rgba32Float, width: 4, height: 4)
    picture.rgb = (0..<4).flatMap { _ in row }
    let frame = try picture.frame(gpu, signal: signal)
    let out = try gpu.render(frame, state: MonitorState(), width: 16, height: 16, format: .bgra8Unorm)
    XCTAssertEqual(out.values.count, 256)
    for v in out.values { XCTAssertEqual(SIMD3(v.x, v.y, v.z), SIMD3(1, 1, 1)) }
  }

  /// Draws a prepared frame twice with the same state: the second draw keeps the
  /// hand-edited `guides` and `parameters` (nothing is rebuilt).
  func drawEdited(_ gpu: TestGPU, state: MonitorState, edit: (MonitorPass) -> Void) throws -> Pixels {
    let frame = try SyntheticFrame.neutral(.v210, width: 96, height: 48) { x, _ in 64 + x * 9 }
      .frame(gpu, signal: .rec709)
    let pass = gpu.engine.makePass(), feed = gpu.engine.makeFeed()
    _ = try gpu.render(frame, state: state, feed: feed, pass: pass)
    edit(pass)
    return try gpu.render(frame, state: state, feed: feed, pass: pass)
  }

  /// The shader read `GuideParameters.counts` and `PassParameters.modes.z` as
  /// they were: a hand-filled struct with larger counts read past the 128 lines,
  /// 8 others or 16 bands (past the bound bytes: a GPU fault, or garbage strokes
  /// and bands). They are now clamped as `updateCells` clamps them.
  func testAudit3HandFilledCountsAreClampedInTheShader() throws {
    let gpu = try requireGPU()
    var state = MonitorState()
    state.guides.enabled = true
    state.guides.squareGrid = true
    state.guides.diagonals = true
    state.guides.centerDot = true
    state.guides.opacity = 1
    state.falseColor.mode = .sixBand
    let edited = try drawEdited(gpu, state: state) { pass in
      XCTAssertEqual(pass.parameters.modes.z, 6)
      XCTAssertGreaterThan(pass.guides.counts.z, 0)
      pass.parameters.modes.z = 1000
      var g = pass.guides
      // Every line in the verticals' slot, as the clamped counts read them.
      let total = g.counts.x + g.counts.y
      g.counts = SIMD4(total, 500, g.counts.z, 0)
      pass.guides = g
    }
    let clamped = try drawEdited(gpu, state: state) { pass in
      var g = pass.guides
      let total = g.counts.x + g.counts.y
      g.counts = SIMD4(total, min(500, 128 - total), g.counts.z, 0)
      pass.guides = g
    }
    XCTAssertEqual(edited.values, clamped.values, "128 lines and 16 bands at most")

    let tooMany = try drawEdited(gpu, state: state) { pass in
      var g = pass.guides
      g.counts = SIMD4(.max, .max, .max, 0)
      pass.guides = g
    }
    let full = try drawEdited(gpu, state: state) { pass in
      var g = pass.guides
      g.counts = SIMD4(128, 0, 8, 0)
      pass.guides = g
    }
    XCTAssertEqual(tooMany.values, full.values)
  }

  /// The guard before the overlays: a finite float value near Float.greatestFiniteMagnitude
  /// passes the tap guard, then the display adjustments (contrast 2) overflow it
  /// to inf on a signal-native target (no target encode clamps it), and the
  /// overlay mix computed NaN: the clipped pixel drew black. It now shows the
  /// overlay as a finite super-white does. (A zebra cannot show it here: such a
  /// value's IRE, luma · 100, is itself inf, above a lower-limit zebra's +inf top.)
  func testAudit3AdjustmentOverflowKeepsTheOverlay() throws {
    let gpu = try requireGPU()
    let values: [SIMD3<Double>] = [SIMD3(repeating: 3e38), SIMD3(repeating: 2)]
    var clip = MonitorState()
    clip.display.contrast = 2
    clip.clipIndicators.enabled = true
    clip.clipIndicators.stage = .source
    for format in [MTLPixelFormat.rgba32Float, .bgra8Unorm] {
      let c = try draw(gpu, values, state: clip, format: format)
      XCTAssertEqual(c.rgb(0, 0), c.rgb(1, 0), "over, in the clip colour")
      XCTAssertEqual(c.rgb(0, 0), SIMD3(1, 1, 1), "every channel over: white, not black")
    }
  }

  /// The band count clamp: in `PassParameters`, `bandEdges[16 + i]` is
  /// `bandColors[i]`, so an unclamped `modes.z = 17` read `bandColors[0]` as a
  /// band containing every value and drew `bandColors[16]` (the `color` codes).
  func testAudit3BandCountIsClampedInTheShader() throws {
    let gpu = try requireGPU()
    var state = MonitorState()
    state.falseColor.mode = .sixBand
    func edit(_ count: UInt32) -> (MonitorPass) -> Void {
      { pass in
        XCTAssertEqual(pass.parameters.modes.z, 6)
        var i = 0
        while i < PassParameters.maximumBands {
          pass.parameters.bandEdges[i] = .zero
          i += 1
        }
        pass.parameters.bandColors[0] = SIMD4(-1e9, 1e9, 0, 0)
        pass.parameters.modes.z = count
      }
    }
    let sixteen = try drawEdited(gpu, state: state, edit: edit(16))
    let seventeen = try drawEdited(gpu, state: state, edit: edit(17))
    XCTAssertEqual(seventeen.values, sixteen.values, "16 bands at most")
    XCTAssertNotEqual(sixteen.rgb(60, 20), SIMD3(0, 0, 0), "no band: the grey fallback")
  }
}
