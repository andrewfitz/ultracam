import Metal
import XCTest
import simd

@testable import MonitorKit

/// The picture pass without overlays: sampling, geometry and target encoding.
final class PictureTests: XCTestCase {
  /// In-range codes so clamping never hides a decode difference.
  static func picture(_ layout: PixelLayout = .v210, width: Int, height: Int, seed: UInt64 = 3) -> SyntheticFrame {
    var p = SyntheticFrame.random(layout, width: width, height: height, seed: seed)
    let lo = 16 << (layout.bitDepth - 8), hi = 235 << (layout.bitDepth - 8)
    p.y = p.y.map { lo + $0 % (hi - lo) }
    p.cb = p.cb.map { 1 << (layout.bitDepth - 1) + ($0 % 64) - 32 }
    p.cr = p.cr.map { 1 << (layout.bitDepth - 1) + ($0 % 64) - 32 }
    return p
  }

  static func clamped(_ v: SIMD4<Float>) -> SIMD3<Float> {
    simd_clamp(SIMD3(v.x, v.y, v.z), .zero, SIMD3(repeating: 1))
  }

  func testIdentityIsTheDecodeBitForBit() throws {
    let gpu = try requireGPU()
    for layout in [PixelLayout.v210, .p010, .nv12, .bgra8, .rgba16Float] {
      let source = layout.isRGB ? SyntheticFrame.random(layout, width: 64, height: 36, seed: 4) : Self.picture(layout, width: 64, height: 36)
      let frame = try source.frame(gpu, signal: .rec709)
      let decoded = gpu.decode(frame)
      let out = try gpu.render(frame, state: MonitorState())
      for i in 0..<decoded.count {
        XCTAssertEqual(out.values[i].x, Self.clamped(decoded[i]).x, "\(layout) \(i)")
        XCTAssertEqual(out.values[i].y, Self.clamped(decoded[i]).y)
        XCTAssertEqual(out.values[i].z, Self.clamped(decoded[i]).z)
        XCTAssertEqual(out.values[i].w, 1)
      }
    }
  }

  func testSRGBTargetsStoreTheDisplayValue() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 1) { x, _ in min(940, max(64, x)) }
    let frame = try picture.frame(gpu, signal: .rec709)
    let plain = try gpu.render(frame, state: MonitorState(), format: .bgra8Unorm)
    let srgb = try gpu.render(frame, state: MonitorState(), format: .bgra8Unorm_srgb)
    for x in 0..<1024 {
      let v = Float(min(940, max(64, x)) - 64) / 876
      XCTAssertEqual(plain[x, 0].x, v, accuracy: 0.5 / 255 + 1e-6)
      // The hardware encode of the linearized value lands within one code of the display value.
      XCTAssertEqual(srgb[x, 0].x, v, accuracy: 1.01 / 255, "code \(x)")
    }
  }

  func testIntegralMinificationIsAnExactBox() throws {
    let gpu = try requireGPU()
    let picture = Self.picture(width: 96, height: 54)
    let frame = try picture.frame(gpu, signal: .rec709)
    let decoded = gpu.decode(frame)
    for factor in [2, 3, 6] {
      let out = try gpu.render(frame, state: MonitorState(), width: 96 / factor, height: 54 / factor)
      for y in 0..<(54 / factor) {
        for x in 0..<(96 / factor) {
          var sum = SIMD3<Float>.zero
          for j in 0..<factor { for i in 0..<factor { let v = decoded[(y * factor + j) * 96 + x * factor + i]; sum += SIMD3(v.x, v.y, v.z) } }
          let expected = simd_clamp(sum / Float(factor * factor), .zero, SIMD3(repeating: 1))
          XCTAssertLessThan(simd_length(out.rgb(x, y) - expected), 1e-5, "\(factor)× at \(x),\(y)")
        }
      }
    }
  }

  func testFlipsMirrorExactly() throws {
    let gpu = try requireGPU()
    let picture = Self.picture(width: 40, height: 20)
    let frame = try picture.frame(gpu, signal: .rec709)
    let decoded = gpu.decode(frame)
    for flip in FlipMode.allCases {
      var state = MonitorState()
      state.geometry.flip = flip
      let out = try gpu.render(frame, state: state)
      for y in 0..<20 {
        for x in 0..<40 {
          let sx = flip.flipsX ? 39 - x : x, sy = flip.flipsY ? 19 - y : y
          XCTAssertEqual(out.rgb(x, y), Self.clamped(decoded[sy * 40 + sx]), "\(flip) \(x),\(y)")
        }
      }
    }
  }

  func testPixelExactShowsEveryPictureRowOnceAndPans() throws {
    let gpu = try requireGPU()
    let picture = Self.picture(width: 120, height: 80)
    let frame = try picture.frame(gpu, signal: .rec709)
    let decoded = gpu.decode(frame)
    for (cx, cy) in [(0.5, 0.5), (0.0, 0.0), (1.0, 1.0), (0.3, 0.8)] {
      var state = MonitorState()
      state.geometry.magnification.pixelExact = true
      state.geometry.magnification.centerX = cx
      state.geometry.magnification.centerY = cy
      state.geometry.magnification.showsNavigator = false
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass, width: 50, height: 30)
      let layout = try XCTUnwrap(pass.layout)
      XCTAssertTrue(layout.isMagnified)
      XCTAssertEqual(layout.imageRect.width, 120)
      XCTAssertEqual(layout.imageRect.x, layout.imageRect.x.rounded())
      for y in 0..<30 {
        for x in 0..<50 {
          let p = layout.displayToPicture.apply(x: Double(x) + 0.5, y: Double(y) + 0.5)
          let sx = Int(p.x.rounded(.down)), sy = Int(p.y.rounded(.down))
          XCTAssertEqual(p.x - Double(sx), 0.5, "centres align")
          XCTAssertEqual(out.rgb(x, y), Self.clamped(decoded[sy * 120 + sx]), "\(cx),\(cy) at \(x),\(y)")
        }
      }
    }
  }

  /// CPU reference for `mk_filtered`: per axis nearest at 1:1, Catmull-Rom when
  /// magnified, a box of stratified taps when minified, applied to decoded values
  /// (decoding is affine in the codes, so this equals filtering codes). Tap
  /// positions in Float, as on the GPU; weights and sums in Double. Nil when a
  /// box tap lands within rounding of a pixel edge, where either side is right.
  static func filtered(
    _ decoded: [SIMD4<Float>], width: Int, height: Int, map: AxisMap, x: Int, y: Int,
    nearest: Bool = false, maxTaps: Int = 8
  ) -> SIMD3<Double>? {
    var ambiguous = false
    func taps(_ i: Int, _ scale: Double, _ offset: Double, _ size: Int) -> [(Int, Double)] {
      let centre = (Float(i) + 0.5) * Float(scale) + Float(offset), footprint = abs(Float(scale))
      func clamp(_ p: Float) -> Int { min(size - 1, max(0, Int(p.rounded(.down)))) }
      if nearest || footprint == 1 { return [(clamp(centre), 1)] }
      if footprint < 1 {
        let p = centre - 0.5, base = p.rounded(.down), t = Double(p - base)
        let w = [(2 * t * t - t * t * t - t) / 2, (3 * t * t * t - 5 * t * t + 2) / 2,
                 (4 * t * t - 3 * t * t * t + t) / 2, (t * t * t - t * t) / 2]
        return (0..<4).map { (clamp(base - 0.5 + Float($0)), w[$0]) }
      }
      let n = Int(min(Float(maxTaps), max(1, (footprint - 0.001).rounded(.up))))
      let step = footprint / Float(n), first = centre - footprint * 0.5 + step * 0.5
      return (0..<n).map {
        let p = first + Float($0) * step
        if abs(p - p.rounded()) < 1e-4 { ambiguous = true }
        return (clamp(p), 1 / Double(n))
      }
    }
    var sum = SIMD3<Double>.zero
    let columns = taps(x, map.scaleX, map.offsetX, width)
    for (py, wy) in taps(y, map.scaleY, map.offsetY, height) {
      for (px, wx) in columns {
        let v = decoded[py * width + px]
        sum += SIMD3(Double(v.x), Double(v.y), Double(v.z)) * (wx * wy)
      }
    }
    return ambiguous ? nil : sum
  }

  /// Every display pixel against the CPU filter, clamped as the target stores it.
  func checkFiltered(
    _ frame: MonitorFrame, state: MonitorState, width: Int, height: Int, tolerance: Double = 2e-5,
    _ what: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let gpu = try requireGPU()
    let decoded = gpu.decode(frame)
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass, width: width, height: height)
    let layout = try XCTUnwrap(pass.layout)
    var worst = 0.0, checked = 0, inside = 0
    for y in 0..<height {
      for x in 0..<width {
        let d = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
        let r = layout.imageRect
        guard d.x >= r.x, d.x < r.maxX, d.y >= r.y, d.y < r.maxY else { continue }
        inside += 1
        guard let filtered = Self.filtered(
          decoded, width: frame.width, height: frame.height, map: layout.displayToPicture, x: x, y: y,
          nearest: state.geometry.magnification.pixelExact)
        else { continue }
        checked += 1
        let ref = simd_clamp(filtered, .zero, SIMD3(repeating: 1))
        let g = out.rgb(x, y)
        worst = max(worst, simd_reduce_max(simd_abs(SIMD3(Double(g.x), Double(g.y), Double(g.z)) - ref)))
      }
    }
    XCTAssertLessThanOrEqual(worst, tolerance, what, file: file, line: line)
    XCTAssertGreaterThanOrEqual(checked, max(1, inside / 10), "\(what): too few unambiguous pixels", file: file, line: line)
  }

  func testZoomIsBicubicAndClampsPanToThePicture() throws {
    let gpu = try requireGPU()
    for layout in [PixelLayout.v210, .uyvy8, .p010, .bgra8, .rgba16Float] {
      let source = layout.isRGB ? SyntheticFrame.random(layout, width: 32, height: 18, seed: 8) : Self.picture(layout, width: 32, height: 18)
      let frame = try source.frame(gpu, signal: .rec709)
      var state = MonitorState()
      state.geometry.magnification.zoom = 4
      state.geometry.magnification.centerX = 0
      state.geometry.magnification.centerY = 1
      state.geometry.magnification.showsNavigator = false
      let pass = gpu.engine.makePass()
      _ = try gpu.render(frame, state: state, pass: pass, width: 64, height: 36)
      let l = try XCTUnwrap(pass.layout)
      // Panned to the bottom-left corner, never past it.
      XCTAssertEqual(l.imageRect.x, 0)
      XCTAssertEqual(l.imageRect.maxY, 36)
      try checkFiltered(frame, state: state, width: 64, height: 36, "4× \(layout)")
      // Continuous zoom, panned off-centre.
      state.geometry.magnification.zoom = 2.37
      state.geometry.magnification.centerX = 0.4
      state.geometry.magnification.centerY = 0.55
      try checkFiltered(frame, state: state, width: 64, height: 36, "2.37× \(layout)")
    }
  }

  /// Interpolation never shifts a flat area: a 100 IRE field magnified stays exactly 100 IRE.
  func testMagnifiedFlatFieldsStayExact() throws {
    let gpu = try requireGPU()
    for layout in [PixelLayout.v210, .p010, .bgra8] {
      let picture = SyntheticFrame.neutral(layout, width: 64, height: 36) { _, _ in layout.isRGB ? 255 : 940 << (layout.bitDepth - 10) }
      let frame = try picture.frame(gpu, signal: .rec709)
      var state = MonitorState()
      state.geometry.magnification.zoom = 3.3
      state.geometry.magnification.showsNavigator = false
      state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 100, opacity: 1, stage: .source)
      state.zebras[0].enabled = false
      let plain = try gpu.render(frame, state: state, width: 64, height: 36)
      XCTAssertTrue(plain.values.allSatisfy { $0 == SIMD4(1, 1, 1, 1) }, "\(layout)")
      // Zebras at 100+ stripe the whole field: no pixel lands below 100 IRE.
      state.zebras[0].enabled = true
      state.zebras[0].opacity = 0.5
      let striped = try gpu.render(frame, state: state, width: 64, height: 36)
      for y in 0..<36 {
        for x in 0..<64 where (x + y) % 16 < 8 { XCTAssertEqual(striped.rgb(x, y), SIMD3(repeating: 1), "\(layout) \(x),\(y)") }
      }
    }
  }

  /// De-squeeze and pixel aspect give a different footprint per axis: each axis
  /// filters on its own (box, nearest or bicubic), never a 2 × 2 guess.
  func testAnisotropicFootprintsFilterEachAxis() throws {
    let gpu = try requireGPU()
    // The auditor's probe: an 8 × 32 row gradient, de-squeezed 4× into 9 × 9, footprint (0.89, 3.56).
    var gradient = SyntheticFrame(layout: .rgba32Float, width: 8, height: 32)
    gradient.rgb = (0..<(8 * 32)).map { SIMD3(repeating: Double($0 / 8) / 31) }
    let frame = try gradient.frame(gpu, signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.geometry.desqueeze = 4
    try checkFiltered(frame, state: state, width: 9, height: 9, "8×32 de-squeezed 4× into 9×9")
    let out = try gpu.render(frame, state: state, width: 9, height: 9)
    // Row 0 averages source rows 0…3 (a box), not two rows and a stray column.
    XCTAssertEqual(Double(out.rgb(4, 0).x), (0 + 1 + 2 + 3) / 4 / 31.0, accuracy: 0.02)
    // v210 at footprint (1, 4): the case where the old 2 × 2 pair path also fired.
    let v210 = try Self.picture(width: 96, height: 64).frame(gpu, signal: .rec709)
    let pass = gpu.engine.makePass()
    _ = try gpu.render(v210, state: state, pass: pass, width: 96, height: 16)
    XCTAssertEqual(try XCTUnwrap(pass.layout).footprintX, 1, accuracy: 1e-12)
    XCTAssertEqual(try XCTUnwrap(pass.layout).footprintY, 4, accuracy: 1e-12)
    try checkFiltered(v210, state: state, width: 96, height: 16, "v210 (1, 4)")
    // Pixel aspect 2 with de-squeeze 2, and magnified anamorphic (bicubic x, box y).
    for layout in [PixelLayout.v210, .yuyv8, .nv12, .rgba16Float] {
      let source = layout.isRGB ? SyntheticFrame.random(layout, width: 48, height: 40, seed: 12) : Self.picture(layout, width: 48, height: 40)
      var f = try source.frame(gpu, signal: .rec709)
      f.pixelAspectRatio = 2
      var s = MonitorState()
      s.geometry.desqueeze = 2
      try checkFiltered(f, state: s, width: 50, height: 13, "PAR 2 × de-squeeze 2 \(layout)")
      try checkFiltered(f, state: s, width: 300, height: 30, "anamorphic magnified \(layout)")
    }
  }

  /// Non-integral minification at common window sizes, every packed and planar layout.
  func testNonIntegralMinificationMatchesTheReference() throws {
    let gpu = try requireGPU()
    for layout in [PixelLayout.v210, .uyvy8, .yuyv8, .p010, .nv12, .p410, .bgra8, .rgba16Float] {
      let source = layout.isRGB ? SyntheticFrame.random(layout, width: 192, height: 108, seed: 21) : Self.picture(layout, width: 192, height: 108)
      let frame = try source.frame(gpu, signal: .rec709)
      for (w, h) in [(80, 45), (48, 27), (96, 54), (64, 36), (128, 72), (24, 13)] {
        try checkFiltered(frame, state: MonitorState(), width: w, height: h, "\(layout) → \(w)×\(h)")
      }
    }
  }

  func testNavigatorShowsTheWholePictureAndOutlinesTheVisibleRegion() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 192, height: 108) { _, _ in 502 }  // 50%
    let frame = try picture.frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.geometry.magnification.zoom = 3
    state.geometry.magnification.centerX = 0.25
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass, width: 192, height: 108)
    let layout = try XCTUnwrap(pass.layout)
    let nav = try XCTUnwrap(layout.navigatorRect)
    let p = pass.currentParameters.navigatorVisible
    // Inside the navigator, away from the outlines: the dimmed picture.
    let inner = (Int(nav.midX), Int(nav.y) + 3)
    XCTAssertTrue(Float(inner.0) < p.x - 2 || Float(inner.0) > p.z + 2 || Float(inner.1) < p.y - 2)
    XCTAssertEqual(out.rgb(inner.0, inner.1), SIMD3(repeating: 0.5 * 0.85), "dimmed picture")
    // Its border.
    XCTAssertEqual(out.rgb(Int(nav.x), Int(nav.midY)), SIMD3(repeating: 0.85))
    // The visible region's outline: the left edge of the box, mid-height.
    let left = Int(p.x.rounded(.down)), mid = Int((p.y + p.w) / 2)
    XCTAssertEqual(out.rgb(left, mid), SIMD3(1, 0.8, 0))
    // The region is a third of the picture, centred a quarter of the way across.
    XCTAssertEqual(Double(p.z - p.x), nav.width / 3, accuracy: 0.01)
    XCTAssertEqual(layout.visiblePictureRect.midX, 192 * 0.25, accuracy: 1e-9)
    XCTAssertEqual(layout.visiblePictureRect.width, 64, accuracy: 1e-9)
    // The main picture outside the navigator is untouched.
    XCTAssertEqual(out.rgb(5, 5), SIMD3(repeating: 0.5))
  }

  /// The navigator is an overlay: a clean feed shows only the zoomed picture.
  func testCleanFeedHidesTheNavigator() throws {
    let gpu = try requireGPU()
    let frame = try Self.picture(width: 192, height: 108).frame(gpu, signal: .rec709)
    var state = MonitorState()
    state.geometry.magnification.zoom = 2
    state.clean = true
    let pass = gpu.engine.makePass()
    let clean = try gpu.render(frame, state: state, pass: pass)
    XCTAssertNotNil(pass.layout?.navigatorRect, "the layout still has room for it")
    XCTAssertEqual(pass.currentParameters.navigatorRect, .zero)
    state.geometry.magnification.showsNavigator = false
    XCTAssertEqual(clean.values, try gpu.render(frame, state: state).values)
    state.clean = false
    state.geometry.magnification.showsNavigator = true
    XCTAssertNotEqual(clean.values, try gpu.render(frame, state: state).values, "shown when not clean")
  }

  func testLetterboxAndPillarboxAreBlackAndNothingSpillsOutsideTheViewport() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 64, height: 36) { _, _ in 940 }
    let frame = try picture.frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let t = gpu.target(100, 100)
    // Fill the target white first, then draw a 64×64 viewport at (20, 10) without clearing.
    let white = try SyntheticFrame.neutral(.v210, width: 100, height: 100) { _, _ in 940 }.frame(gpu, signal: .rec709)
    try gpu.run { cb in
      try pass.encode(frame: white, feed: feed, state: MonitorState(), target: t, into: cb)
      try pass.encode(
        frame: frame, feed: feed, state: MonitorState(), target: t,
        viewport: MonitorViewport(x: 20, y: 10, width: 64, height: 64), clear: false, into: cb)
    }
    let out = Pixels(t)
    // 16:9 in a square: rows 10+0..<14 and 10+50..<64 are letterbox.
    XCTAssertEqual(out.rgb(50, 12), .zero)
    XCTAssertEqual(out.rgb(50, 72), .zero)
    XCTAssertEqual(out.rgb(50, 40), SIMD3(repeating: 1))
    // Outside the viewport the earlier white survives.
    XCTAssertEqual(out.rgb(19, 40), SIMD3(repeating: 1))
    XCTAssertEqual(out.rgb(84, 40), SIMD3(repeating: 1))
    XCTAssertEqual(out.rgb(50, 9), SIMD3(repeating: 1))
    XCTAssertEqual(out.rgb(50, 74), SIMD3(repeating: 1))
    XCTAssertThrowsError(
      try gpu.run { cb in
        try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: t,
          viewport: MonitorViewport(x: 50, y: 50, width: 64, height: 64), into: cb)
      })
  }

  /// The host-render-pass tier draws exactly what `encode` draws, at the viewport.
  func testDrawingInsideAHostRenderPassMatchesEncode() throws {
    let gpu = try requireGPU()
    let frame = try Self.picture(width: 120, height: 68).frame(gpu, signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed()
    let viewport = MonitorViewport(x: 30, y: 20, width: 120, height: 68)
    let own = gpu.target(200, 120), host = gpu.target(200, 120)
    let a = gpu.engine.makePass(), b = gpu.engine.makePass()
    try gpu.run { cb in
      try feed.analyze(frame, focus: state.focus, into: cb)
      try a.encode(frame: frame, feed: feed, state: state, target: own, viewport: viewport, into: cb)
      try b.prepare(frame: frame, feed: feed, state: state, viewport: viewport, targetPixelFormat: .rgba32Float, into: cb)
      let d = MTLRenderPassDescriptor()
      d.colorAttachments[0].texture = host
      d.colorAttachments[0].loadAction = .clear
      d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      let e = cb.makeRenderCommandEncoder(descriptor: d)!
      try b.draw(with: e)
      e.endEncoding()
    }
    XCTAssertEqual(Pixels(own).values, Pixels(host).values)
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = host
    let e = gpu.queue.makeCommandBuffer()!.makeRenderCommandEncoder(descriptor: d)!
    XCTAssertThrowsError(try b.draw(with: e), "draw needs a fresh prepare")
    e.endEncoding()
  }

  func testHalfFloatTargetsCarryTheDisplayValue() throws {
    let gpu = try requireGPU()
    let frame = try Self.picture(width: 64, height: 36).frame(gpu, signal: .rec709)
    let full = try gpu.render(frame, state: MonitorState())
    let t = gpu.target(64, 36, format: .rgba16Float)
    try gpu.run { try gpu.engine.makePass().encode(frame: frame, feed: gpu.engine.makeFeed(), state: MonitorState(), target: t, into: $0) }
    var halves = [Float16](repeating: 0, count: 64 * 36 * 4)
    halves.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: 64 * 8, from: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0) }
    for i in 0..<(64 * 36) {
      XCTAssertEqual(Float(halves[i * 4]), full.values[i].x, accuracy: 1e-3)
      XCTAssertEqual(Float(halves[i * 4 + 3]), 1)
    }
  }

  func testDisplayAdjustmentsMonochromeAndBlueOnly() throws {
    let gpu = try requireGPU()
    var picture = SyntheticFrame(layout: .rgba32Float, width: 4, height: 1)
    picture.rgb = [SIMD3(0.2, 0.5, 0.8), SIMD3(0.9, 0.1, 0.3), SIMD3(0.5, 0.5, 0.5), SIMD3(0, 0, 1)]
    let frame = try picture.frame(gpu, signal: SignalDescription(range: .full))
    func luma(_ c: SIMD3<Double>) -> Double { c.y + 0.2126 * (c.x - c.y) + 0.0722 * (c.z - c.y) }
    for mode in MonochromeMode.allCases {
      var state = MonitorState()
      state.display.monochrome = mode
      state.display.brightness = 0.05
      state.display.contrast = 1.2
      state.display.saturation = 0.5
      let out = try gpu.render(frame, state: state)
      for (i, c) in picture.rgb.enumerated() {
        var v = mode == .luma ? SIMD3(repeating: luma(c)) : mode == .blueOnly ? SIMD3(repeating: c.z) : c
        let y = luma(v)
        v = SIMD3(repeating: y) + (v - SIMD3(repeating: y)) * 0.5
        v = (v - 0.5) * 1.2 + 0.5 + 0.05
        let expected = simd_clamp(SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)), .zero, SIMD3(repeating: 1))
        XCTAssertLessThan(simd_length(out.rgb(i, 0) - expected), 1e-5, "\(mode) \(i)")
      }
    }
  }
}
