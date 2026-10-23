import CoreVideo
import Metal
import XCTest
import simd

@testable import MonitorKit

/// `MonitorToolsMetalTests/SourcePictureGeometryTests` (3),
/// `SourceInterpretationGuardTests` (2) and `MonitorSamplingTests` (2), ported
/// (map §8.2). The processed-output and correspondence mapping is in `PortedSupport.swift`.
///
/// | MonitorTools case | Here |
/// | --- | --- |
/// | `testSourceFocusStaysOnSourceEdgesWhenProcessedOutputIsScaledOrCropped` | `PortedSourcePictureGeometryTests.testSourceFocusStaysOnSourceEdgesWhateverTheOutputLook` |
/// | `testSourceFalseColorClassifiesTheDisplayedSourcePixelWithScaledOrCroppedOutput` | `…testSourceFalseColourClassifiesTheDisplayedSourcePixelWhateverTheOutputLook` |
/// | `testProcessedPictureKeepsSourceFocusMappedToTheDownscaledOutput` | `…testMinifiedPictureKeepsSourceFocusOnTheSourceEdge` |
/// | `testSonyAndFocusRejectSourceGeometryThatDoesNotDescribeSourceBuffer` | `PortedSourceInterpretationGuardTests.testToolsNeverReadOutsideTheDeclaredFrame` |
/// | `testELZoneRejectsFiniteDoubleCorrespondenceThatBecomesZeroOrInfiniteFloat` | `…testExtremeFiniteGeometryStaysFiniteOnTheGPU` |
/// | `testScopeLatticeCountsEveryPixelOnceIncludingPartialEdgeCells` | `MonitorKitScopesTests`: `ScopeAccumulationTests.testWaveformLumaEveryLayout` and `ScopeGroupTests.testOddAndTinyFrames` (see `ScopePortedMonitorToolsTests`) |
/// | `testDirectYMatchesMatrixWeightedRGBForEverySupportedLayoutAndRange` | `PortedSamplingTests.testTransportLumaMatchesTheMatrixWeightedRGBForEveryLayoutAndRange` |
///
/// The scaled and cropped processed outputs (`MonitorCorrespondence` 0.5× with and
/// without an offset) have no MonitorKit input: the output stage is computed at
/// source resolution in the same pass (map §7 item 2). What those cases protected
/// (tools follow the source, not the look) is asserted with flat burn-in LUTs; the
/// scaled display is asserted by minifying the picture itself.
final class PortedSourcePictureGeometryTests: XCTestCase {
  static let formats: [PixelLayout] = [.bgra8, .v210]

  /// The original's fixture: a bright 48 × 24 patch at (96, 48) in a 192 × 96
  /// picture, a short bright run up the right edge and along the bottom row.
  static func fixture(_ layout: PixelLayout) -> SyntheticFrame {
    let width = 192, height = 96
    func bright(_ x: Int, _ y: Int) -> Bool {
      (96..<144).contains(x) && (48..<72).contains(y) || x == width - 1 && y >= height - 8 || y == height - 1 && x >= width - 16
    }
    if layout == .bgra8 { return Ported.grey(width: width, height: height) { x, y in bright(x, y) ? 244 : 100 } }
    return SyntheticFrame.neutral(.v210, width: width, height: height) { x, y in bright(x, y) ? 980 : 400 }
  }

  func testSourceFocusStaysOnSourceEdgesWhateverTheOutputLook() throws {
    let gpu = try requireGPU()
    for layout in Self.formats {
      let frame = try Ported.wrapped(gpu, Self.fixture(layout), signal: SignalDescription(range: .full))
      var state = MonitorState()
      state.focus.enabled = true
      state.focus.color = .yellow
      state.focus.opacity = 1
      state.focus.stage = .source
      let feed = gpu.engine.makeFeed()
      let reference = try gpu.render(frame, state: state, feed: feed, analyze: true)
      XCTAssertEqual(reference.rgb(95, 55), SIMD3(1, 1, 0), "\(layout): the patch's left edge is peaked")
      let mask = gpu.readMask(feed)
      var plain = state
      plain.focus.enabled = false
      let picture = try gpu.render(frame, state: plain, feed: feed)
      for level in Ported.flatLevels {
        feed.burnInLUT = try Ported.constantLUT(gpu, level)
        let actual = try gpu.render(frame, state: state, feed: feed, analyze: true)
        XCTAssertEqual(gpu.readMask(feed), mask, "\(layout): the source-stage mask ignores the look")
        for y in 0..<96 {
          for x in 0..<192 {
            // Peaking mixes each picture toward yellow by the same source confidence.
            let k = mask[y * 192 + x]
            let flat = SIMD3<Float>(repeating: level)
            XCTAssertEqual(actual.rgb(x, y), flat + (SIMD3(1, 1, 0) - flat) * k, accuracy: 1e-6, "\(layout) \(level) at \(x),\(y)")
            let c = picture.rgb(x, y)
            XCTAssertEqual(reference.rgb(x, y), c + (SIMD3(1, 1, 0) - c) * k, accuracy: 1e-6, "\(layout) reference at \(x),\(y)")
          }
        }
        // The original's own form: a source picture (`pictureStage = .source`) is
        // the same image whatever the output look.
        var source = state
        source.pictureStage = .source
        let shown = try gpu.render(frame, state: source, feed: feed, analyze: true)
        XCTAssertEqual(shown.values, reference.values, "\(layout) \(level): the source picture ignores the output look")
        feed.burnInLUT = nil
      }
    }
  }

  func testSourceFalseColourClassifiesTheDisplayedSourcePixelWhateverTheOutputLook() throws {
    let gpu = try requireGPU()
    let profile = ARRIFalseColorProfile.logC3EI800
    for layout in Self.formats {
      let frame = try Ported.wrapped(gpu, Self.fixture(layout), signal: Ported.signal(Ported.logC(.arriLogC3), range: .full))
      var state = MonitorState()
      state.falseColor.mode = .arriLogC
      let reference = try gpu.render(frame, state: state)
      // 244/255 and 980/1023 of a full container are full-table codes 978.9 and 980: red.
      XCTAssertEqual(profile.category(achromaticCode: layout == .bgra8 ? 244.0 / 255 * 1023 : 980, range: .full), .red)
      XCTAssertEqual(reference.rgb(110, 55), SIMD3(1, 0, 0))
      for level in Ported.flatLevels {
        let feed = gpu.engine.makeFeed()
        feed.burnInLUT = try Ported.constantLUT(gpu, level)
        let actual = try gpu.render(frame, state: state, feed: feed)
        XCTAssertEqual(actual.values, reference.values, "\(layout) output \(level): false colour classifies its own source pixel")
        var source = state
        source.pictureStage = .source
        XCTAssertEqual(try gpu.render(frame, state: source, feed: feed).values, reference.values, "\(layout) source picture")
      }
    }
  }

  /// A 192 × 96 source shown at 96 × 48 (the original's 0.5× processed output):
  /// display pixel (48, 27) covers source (96…97, 54…55), the patch's left edge,
  /// and is fully peaked; a flat area is untouched.
  func testMinifiedPictureKeepsSourceFocusOnTheSourceEdge() throws {
    let gpu = try requireGPU()
    let frame = try Ported.wrapped(gpu, Self.fixture(.v210), signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.color = .yellow
    state.focus.opacity = 1
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try Ported.constantLUT(gpu, Ported.flatLevels[0])
    let out = try gpu.render(frame, state: state, feed: feed, width: 96, height: 48, analyze: true)
    XCTAssertEqual(out.rgb(48, 27), SIMD3(1, 1, 0))
    XCTAssertEqual(out.rgb(10, 10), SIMD3(repeating: Ported.flatLevels[0]), accuracy: 1e-6)
    // The patch's interior has no edge either.
    XCTAssertEqual(out.rgb(60, 30), SIMD3(repeating: Ported.flatLevels[0]), accuracy: 1e-6)
  }
}

final class PortedSourceInterpretationGuardTests: XCTestCase {
  /// MonitorTools refused Sony false colour and focus when the declared source
  /// geometry (16 × 32) did not describe the 32 × 32 buffer. In MonitorKit the frame
  /// is the geometry declaration: a frame larger than its textures cannot be made,
  /// and a smaller one (textures may be padded) is the top-left region, which every
  /// tool reads and nothing past. Semantic difference: a smaller declaration is a
  /// valid frame, not a refusal; the guard is that no tool reads outside it.
  func testToolsNeverReadOutsideTheDeclaredFrame() throws {
    let gpu = try requireGPU()
    // Left half code 105 (Sony green), right half 17: a hard edge at x = 16.
    let picture = Ported.grey(width: 32, height: 32) { x, _ in x < 16 ? 105 : 17 }
    let texture = try picture.frame(gpu, signal: SignalDescription(range: .full)).luma
    let signal = Ported.signal(Ported.sLog3Cine, range: .full)
    XCTAssertThrowsError(try MonitorFrame(layout: .bgra8, width: 33, height: 32, luma: texture, signal: signal)) {
      guard case MonitorKitError.invalidFrame = $0 else { return XCTFail("\($0)") }
    }
    XCTAssertThrowsError(try MonitorFrame(layout: .bgra8, width: 32, height: 33, luma: texture, signal: signal))
    let frame = try MonitorFrame(layout: .bgra8, width: 16, height: 32, luma: texture, signal: signal)
    var state = MonitorState()
    state.falseColor.mode = .sonySLog3
    state.focus.enabled = true
    state.focus.opacity = 1
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass, width: 16, height: 32, analyze: true)
    XCTAssertTrue(pass.status.isActive(.falseColor))
    XCTAssertTrue(pass.status.isActive(.focusPeaking))
    // Every pixel is the declared region's green: no edge at its right border, no
    // value from the texels past it.
    for y in 0..<32 { for x in 0..<16 { XCTAssertEqual(out.rgb(x, y), SIMD3(0, 1, 0), "\(x),\(y)") } }
    // A picture that does not describe the camera's signal (MonitorTools' failed
    // interpretation) is a processed frame: Sony false colour and peaking refuse
    // it and the picture is drawn plain, as MonitorTools drew its valid output.
    var processed = try MonitorFrame(layout: .bgra8, width: 32, height: 32, luma: texture, signal: signal)
    processed.isProcessed = true
    let feed = gpu.engine.makeFeed(), refusing = gpu.engine.makePass()
    let drawn = try gpu.render(processed, state: state, feed: feed, pass: refusing, analyze: true)
    XCTAssertEqual(refusing.status.reason(for: .falseColor), .requiresCameraSignal)
    XCTAssertEqual(refusing.status.reason(for: .focusPeaking), .requiresCameraSignal)
    XCTAssertNil(feed.focusMask, "analysis encodes nothing for a processed frame")
    var clean = state
    clean.clean = true
    XCTAssertEqual(drawn.values, try gpu.render(processed, state: clean).values)
    XCTAssertEqual(drawn.rgb(0, 0), SIMD3(repeating: 105.0 / 255), accuracy: 1e-6)
  }

  /// MonitorTools refused finite Double correspondences that become 0 or ∞ as
  /// Float. MonitorKit's map comes from `MonitorLayout`: a pixel aspect ratio
  /// outside `MonitorFrameGeometry.pixelAspectRatioRange` (1e-300, 1e300) is refused
  /// as `.unsupportedGeometry` on the picture and shown with square pixels, and the
  /// state's zoom, pan and de-squeeze (±1e300) are clamped (`normalized()`).
  /// Semantic difference: the tools stay on, because the map they use is finite and
  /// correct. Every pixel is black outside the shown picture and EL Zone's colour
  /// for the source inside it.
  func testExtremeFiniteGeometryStaysFiniteOnTheGPU() throws {
    let gpu = try requireGPU()
    let picture = Ported.grey(width: 32, height: 32) { _, _ in 105 }
    let expected = Ported.vector(try XCTUnwrap(ELZoneProfile.color(rgb: Ported.grey(105.0 / 255), gamut: .sGamut3Cine)))
    var cases: [(Double, ViewGeometry)] = []
    for par in [1e-300, 1e300] { cases.append((par, ViewGeometry())) }
    for extreme in [1e-300, 1e300, -1e300] {
      var g = ViewGeometry()
      g.desqueeze = extreme
      g.magnification.zoom = extreme
      g.magnification.centerX = extreme
      g.magnification.centerY = -extreme
      // The navigator inset is a picture of its own; this checks the main picture.
      g.magnification.showsNavigator = false
      cases.append((1, g))
    }
    for (par, geometry) in cases {
      var frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3Cine, range: .full))
      frame.pixelAspectRatio = par
      var state = MonitorState()
      state.falseColor.mode = .elZone
      state.geometry = geometry
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass, width: 32, height: 32)
      XCTAssertTrue(pass.status.isActive(.falseColor))
      let layout = try XCTUnwrap(pass.layout)
      if par != 1 {
        XCTAssertEqual(pass.status.reason(for: .picture), .unsupportedGeometry, "PAR \(par)")
        XCTAssertEqual(layout, MonitorLayout(pictureWidth: 32, pictureHeight: 32, viewportWidth: 32, viewportHeight: 32, geometry: ViewGeometry()))
      } else {
        XCTAssertNil(pass.status.reason(for: .picture))
      }
      let m = layout.displayToPicture
      for v in [m.scaleX, m.scaleY, m.offsetX, m.offsetY] {
        XCTAssertTrue(Float(v).isFinite, "PAR \(par), \(geometry): map \(m)")
      }
      XCTAssertNotEqual(Float(m.scaleX), 0)
      XCTAssertNotEqual(Float(m.scaleY), 0)
      let r = layout.imageRect
      var inside = 0
      for y in 0..<32 {
        for x in 0..<32 {
          let c = out.rgb(x, y)
          let shown = Double(x) + 0.5 >= r.x && Double(x) + 0.5 < r.maxX && Double(y) + 0.5 >= r.y && Double(y) + 0.5 < r.maxY
          if shown { inside += 1 }
          XCTAssertEqual(c, shown ? expected : .zero, "PAR \(par), \(geometry) at \(x),\(y)")
        }
      }
      XCTAssertGreaterThan(inside, 0)
    }
  }
}

final class PortedSamplingTests: XCTestCase {
  /// MonitorTools read Y' directly (`readSignalY`) and checked it against the
  /// matrix-weighted R'G'B' (`signalLuma(readRGB)`). MonitorKit's `mk_decode` returns
  /// both (R'G'B' in xyz, transport Y' in w); they agree for every layout, both
  /// ranges and every matrix, on random codes including footroom and headroom.
  func testTransportLumaMatchesTheMatrixWeightedRGBForEveryLayoutAndRange() throws {
    let gpu = try requireGPU()
    let layouts: [PixelLayout] = [
      .v210, .uyvy8, .yuyv8, .nv12, .p010, .p210, .p410, .biplanar(.s422, bitDepth: 8), .biplanar(.s444, bitDepth: 8),
      .biplanar(.s422, bitDepth: 16), .bgra8, .rgb10a2, .rgb(bitDepth: 16, float: false), .rgba16Float, .rgba32Float,
    ]
    for layout in layouts {
      let picture = SyntheticFrame.random(layout, width: 12, height: 4, seed: 41)
      for range in [CodeRange.legal, .full] {
        for matrix in [YCbCrMatrix.bt709, .bt2020, .bt601, .smpte240m] {
          let frame = try picture.frame(gpu, signal: SignalDescription(range: range, matrix: matrix))
          let decoded = gpu.decode(frame)
          let k = matrix.coefficients
          for (i, v) in decoded.enumerated() {
            let weighted = Double(v.x) * k.r + Double(v.y) * k.g + Double(v.z) * k.b
            XCTAssertEqual(Double(v.w), weighted, accuracy: 4e-6, "\(layout) \(range) \(matrix) pixel \(i)")
          }
        }
      }
    }
  }
}
