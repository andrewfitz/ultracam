// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import XCTest
import simd

@testable import MonitorKit

/// False-colour scenarios on wrapped CoreVideo pictures: Sony Pattern 2 at every
/// native code, through full and legal containers and the rescaled transport,
/// behind flat output looks, and point-sampled through scaled, magnified, panned
/// and de-squeezed geometry. Fixtures and conventions are in
/// `PictureFixtures.swift`. The ARRI-style S-Log3 mode (`.arriStyleSLog3`) is
/// covered by `FalseColorTests` and the geometry cases here.
final class SonyPattern2PixelTests: XCTestCase {
  func render(_ gpu: TestGPU, _ frame: MonitorFrame, feed: MonitorFeed? = nil) throws -> (Pixels, MonitorPass) {
    var state = MonitorState()
    state.falseColor.mode = .sonySLog3
    let pass = gpu.engine.makePass()
    return (try gpu.render(frame, state: state, feed: feed, pass: pass), pass)
  }

  /// Sony's published anchors (95, 420, 496, 550) through a full and a legal
  /// container, natively and squeezed into the legal range. Catches classifying
  /// the transport code instead of the native code, and applying the EI as gain.
  func testAnchorsAcrossNativeAndRescaledLegalTransport() throws {
    let gpu = try requireGPU()
    for (range, transport) in [(CodeRange.full, LogTransport.native), (.legal, .native), (.legal, .fullRescaledToLegal)] {
      let codes = [95, 420, 496, 550].map { Fixtures.transported($0, transport) }
      let picture = SyntheticFrame.neutral(.v210, width: 24, height: 2) { x, _ in codes[x / 6] }
      let frame = try Fixtures.wrapped(gpu, picture, signal: Fixtures.signal(Fixtures.sLog3(.sGamut3Cine, transport: transport), range: range))
      let (out, pass) = try render(gpu, frame)
      XCTAssertTrue(pass.status.isActive(.falseColor))
      XCTAssertNil(pass.status.reason(for: .falseColor))
      for x in 0..<24 {
        let native = Fixtures.native(transported: codes[x / 6], transport)
        let color = try XCTUnwrap(SonySLog3FalseColor.color(nativeSignalLuma: native))
        assertFixturePixel(out.rgb(x, 0), color, exact: SonySLog3FalseColor.category(nativeSignalLuma: native) != nil,
                           "\(range) \(transport) code \(codes[x / 6])")
      }
    }
  }

  /// BGRA carries S-Log3 as 8-bit codes. A legal-labelled BGRA value is range-expanded
  /// like any integer container (not read as native code/255), so 8-bit 105 is 10-bit
  /// code 420 (40.64 IRE, MATH.md §1 "native log code"), and rescaled 106 is
  /// (106 - 16)/219 native (40.68 IRE). Both are green.
  func testBGRANativeAndExplicitRescaledTransport() throws {
    let gpu = try requireGPU()
    for (value, transport) in [(105, LogTransport.native), (106, .fullRescaledToLegal)] {
      let frame = try Fixtures.wrapped(gpu, Fixtures.grey(width: 6, height: 4) { _, _ in value },
                                       signal: Fixtures.signal(Fixtures.sLog3(.sGamut3Cine, transport: transport), range: .legal))
      let (out, _) = try render(gpu, frame)
      let native = DecodeReference.nativeLog(expanded: (Double(value) - 16) / 219, range: .legal, transport: transport)
      XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: native), .green)
      XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 1, 0), "\(value) \(transport)")
    }
    XCTAssertEqual(DecodeReference.nativeLog(expanded: (105.0 - 16) / 219, range: .legal, transport: .native), 420.0 / 1023, accuracy: 1e-15)
  }

  /// Pattern 2 reads transport signal luma, not scene-linear Y: both Sony gamuts give
  /// the same colour for (105, 105, 140) (41.9 IRE, green).
  func testPublishedIREUsesSignalLumaIndependentlyOfTheSceneGamut() throws {
    let gpu = try requireGPU()
    let picture = Fixtures.bgra(width: 6, height: 4) { _, _ in (105, 105, 140) }
    for gamut in [ColorGamut.sGamut3Cine, .sGamut3] {
      let frame = try Fixtures.wrapped(gpu, picture, signal: Fixtures.signal(Fixtures.sLog3(gamut), range: .full))
      let (out, _) = try render(gpu, frame)
      XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 1, 0), "\(gamut)")
    }
  }

  /// Catches classifying the output look instead of the source: a flat burn-in LUT
  /// at two levels leaves the false colour of code 420 green.
  func testFalseColourIgnoresTheOutputLook() throws {
    let gpu = try requireGPU()
    let frame = try Fixtures.wrapped(gpu, SyntheticFrame.neutral(.v210, width: 6, height: 2) { _, _ in 420 },
                                     signal: Fixtures.signal(Fixtures.sLog3Cine, range: .legal))
    for level in Fixtures.flatLevels {
      let feed = gpu.engine.makeFeed()
      feed.burnInLUT = try Fixtures.constantLUT(gpu, level)
      let (out, _) = try render(gpu, frame, feed: feed)
      XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 1, 0), "output \(level)")
    }
  }

  /// Pattern 2 fails closed where the input cannot be classified, and classifies
  /// where it can:
  /// - A non-log transfer (`Rec709`): `.requiresLogSource`, and the picture (the
  ///   flat output look) is drawn without false colour.
  /// - Another camera's log encoding on the frame (LogC3): `.unsupportedLogEncoding`,
  ///   picture drawn.
  /// - A picture that is not the camera's own signal (`isProcessed`): refused with
  ///   `.requiresCameraSignal`, picture drawn.
  /// - `.fullRescaledToLegal` on a full container is classified: MonitorKit
  ///   unsqueezes the container's own legal range (MATH.md 9.6), so code 420 there
  ///   is (420 - 64)/876 native, 40.15 IRE, green.
  func testQualificationFailsClosedWhereMonitorKitHasTheInput() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 6, height: 2) { _, _ in 420 }
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try Fixtures.constantLUT(gpu, Fixtures.flatLevels[0])
    let refused: [(SignalEncoding, MonitorUnavailableReason)] = [
      (.display(.bt709), .requiresLogSource),
      (Fixtures.logC(.arriLogC3), .unsupportedLogEncoding(LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3))),
    ]
    for (encoding, reason) in refused {
      let frame = try Fixtures.wrapped(gpu, picture, signal: Fixtures.signal(encoding, range: .legal))
      let (out, pass) = try render(gpu, frame, feed: feed)
      XCTAssertEqual(pass.status.reason(for: .falseColor), reason)
      XCTAssertFalse(pass.status.isActive(.falseColor))
      XCTAssertEqual(out.rgb(0, 0), SIMD3(repeating: Fixtures.flatLevels[0]), accuracy: 1e-6, "\(encoding): the output look is drawn")
    }
    var processed = try Fixtures.wrapped(gpu, picture, signal: Fixtures.signal(Fixtures.sLog3Cine, range: .legal))
    processed.isProcessed = true
    let (drawn, refusing) = try render(gpu, processed, feed: feed)
    XCTAssertEqual(refusing.status.reason(for: .falseColor), .requiresCameraSignal)
    XCTAssertEqual(drawn.rgb(0, 0), SIMD3(repeating: Fixtures.flatLevels[0]), accuracy: 1e-6, "processed: the output look is drawn")
    let rescaled = try Fixtures.wrapped(gpu, picture, signal: Fixtures.signal(Fixtures.sLog3(.sGamut3Cine, transport: .fullRescaledToLegal), range: .full))
    let (out, pass) = try render(gpu, rescaled, feed: feed)
    XCTAssertTrue(pass.status.isActive(.falseColor))
    let native = DecodeReference.nativeLog(expanded: 420.0 / 1023, range: .full, transport: .fullRescaledToLegal)
    XCTAssertEqual(native, 356.0 / 876, accuracy: 1e-12)
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: native), .green)
    XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 1, 0))
  }

  /// Every native 10-bit code in a legal container, both Sony gamuts, from raw
  /// v210 textures (the IOSurface path is `PictureQualityTests`), against the Core
  /// reference on R'G'B' through the BT.709 matrix.
  func testEveryNativeTenBitCodeMatchesTheCPUReference() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 2) { x, _ in x }
    for gamut in [ColorGamut.sGamut3Cine, .sGamut3] {
      let frame = try picture.frame(gpu, signal: Fixtures.signal(Fixtures.sLog3(gamut), range: .legal))
      let (out, _) = try render(gpu, frame)
      for code in 0..<1024 {
        let grey = Double(code) / 1023
        let rgb = try XCTUnwrap(SonySLog3FalseColor.color(rgb: Fixtures.grey(grey), matrix: .bt709))
        assertFixturePixel(out.rgb(code, 1), rgb, exact: SonySLog3FalseColor.category(nativeSignalLuma: grey) != nil,
                           "\(gamut) native code \(code)")
      }
    }
  }
}

final class FalseColorGeometryTests: XCTestCase {
  /// MonitorKit has one display-to-source map, `MonitorLayout.displayToPicture`, and
  /// a log false-colour picture is point-sampled: each display pixel classifies the
  /// source pixel containing its mapped centre (`mk_filtered` with `nearest`).
  ///
  /// The source pixel is the one the centre falls in, `floor(c)`, the same rule as
  /// the nearest filter, not the left bilinear tap `floor(c - 0.5)` (in edge
  /// coordinates); the two differ by one pixel wherever the fractional part of `c`
  /// is at least 0.5, and the test counts the pixels that tell them apart.
  ///
  /// The cases: 3:1 and 1.5:1 minification, 2× magnified (a 24 × 12 source shown
  /// at 48 × 24), an off-centre pan (a 1.25/-0.75 offset) and a de-squeezed
  /// anamorphic footprint, for Sony Pattern 2, the
  /// ARRI-style S-Log3 bands, literal LogC3 and LogC4. Pixels whose mapped centre is within float
  /// rounding of a pixel edge are skipped (either neighbour is then correct).
  /// The pixel containing `centre · scale + offset`, or nil when Double, Float and
  /// fused Float arithmetic disagree (a centre within rounding of a pixel edge).
  static func containingPixel(_ centre: Double, _ scale: Double, _ offset: Double) -> Int? {
    let d = Float(centre), s = Float(scale), o = Float(offset)
    let exact = Int((centre * scale + offset).rounded(.down))
    let plain = Int((d * s + o).rounded(.down)), fused = Int(o.addingProduct(d, s).rounded(.down))
    return exact == plain && plain == fused ? exact : nil
  }

  func testLogFalseColourClassifiesTheSourcePixelUnderEachDisplayCentre() throws {
    let gpu = try requireGPU()
    let codes = [24, 105, 124, 137, 212, 225, 60, 170, 91, 200, 15]
    struct Case { var sw, sh, ow, oh: Int; var zoom = 1.0, cx = 0.5, cy = 0.5, desqueeze = 1.0 }
    let cases = [
      Case(sw: 96, sh: 24, ow: 32, oh: 8),
      Case(sw: 96, sh: 24, ow: 64, oh: 16),
      Case(sw: 24, sh: 12, ow: 48, oh: 24),
      Case(sw: 96, sh: 24, ow: 48, oh: 12, zoom: 2.5, cx: 0.3, cy: 0.7),
      Case(sw: 48, sh: 24, ow: 96, oh: 12, desqueeze: 2),
    ]
    let modes: [(FalseColorMode, SignalEncoding)] = [
      (.sonySLog3, Fixtures.sLog3Cine), (.arriStyleSLog3, Fixtures.sLog3Cine), (.arriLogC, Fixtures.logC(.arriLogC3)), (.arriLogC, Fixtures.logC(.arriLogC4)),
    ]
    var discriminating = 0
    for c in cases {
      let picture = Fixtures.grey(width: c.sw, height: c.sh) { x, y in codes[(x + 3 * y) % codes.count] }
      for (mode, encoding) in modes {
        let frame = try Fixtures.wrapped(gpu, picture, signal: Fixtures.signal(encoding, range: .full))
        var state = MonitorState()
        state.falseColor.mode = mode
        state.geometry.magnification.zoom = c.zoom
        state.geometry.magnification.centerX = c.cx
        state.geometry.magnification.centerY = c.cy
        state.geometry.magnification.showsNavigator = false
        state.geometry.desqueeze = c.desqueeze
        let pass = gpu.engine.makePass()
        let out = try gpu.render(frame, state: state, pass: pass, width: c.ow, height: c.oh)
        XCTAssertTrue(pass.status.isActive(.falseColor))
        let layout = MonitorLayout(
          pictureWidth: c.sw, pictureHeight: c.sh, viewportWidth: c.ow, viewportHeight: c.oh, geometry: state.normalized().geometry)
        XCTAssertEqual(pass.layout, layout)
        let image = layout.imageRect, map = layout.displayToPicture
        var checked = 0, total = 0
        for y in 0..<c.oh {
          for x in 0..<c.ow {
            let d = (x: Double(x) + 0.5, y: Double(y) + 0.5)
            guard d.x >= image.x, d.x < image.maxX, d.y >= image.y, d.y < image.maxY else { continue }
            total += 1
            guard let px = Self.containingPixel(d.x, map.scaleX, map.offsetX), let py = Self.containingPixel(d.y, map.scaleY, map.offsetY)
            else { continue }
            let sx = min(c.sw - 1, max(0, px)), sy = min(c.sh - 1, max(0, py))
            let value = Double(codes[(sx + 3 * sy) % codes.count]) / 255
            let expected: ColorRGB, exact: Bool
            switch (mode, encoding.log?.curve) {
            case (.sonySLog3, _):
              expected = try XCTUnwrap(SonySLog3FalseColor.color(nativeSignalLuma: value))
              exact = SonySLog3FalseColor.category(nativeSignalLuma: value) != nil
            case (.arriStyleSLog3, _):
              expected = try XCTUnwrap(SonyARRIStyleFalseColor.color(rgb: Fixtures.grey(value), gamut: .sGamut3Cine))
              exact = SonyARRIStyleFalseColor.category(rgb: Fixtures.grey(value), gamut: .sGamut3Cine) != nil
            default:
              let profile = try XCTUnwrap(FalseColorTable.arriProfile(for: try XCTUnwrap(encoding.log?.curve)))
              let category = profile.category(achromaticCode: value * 1023, range: .full)
              expected = category?.color ?? Fixtures.grey(value)
              exact = category != nil
            }
            assertFixturePixel(out.rgb(x, y), expected, exact: exact,
                               "\(mode) \(encoding) \(c.sw)×\(c.sh) → \(c.ow)×\(c.oh) zoom \(c.zoom): display (\(x),\(y)) → source (\(sx),\(sy))")
            checked += 1
            // Where the half-pixel-left floor reads a different code, this pixel
            // tells the two conventions apart.
            let ox = min(c.sw - 1, max(0, Int((map.apply(x: d.x, y: d.y).x - 0.5).rounded(.down))))
            let oy = min(c.sh - 1, max(0, Int((map.apply(x: d.x, y: d.y).y - 0.5).rounded(.down))))
            if codes[(ox + 3 * oy) % codes.count] != codes[(sx + 3 * sy) % codes.count] { discriminating += 1 }
          }
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThanOrEqual(checked * 10, total * 8, "too many ambiguous centres")
      }
    }
    XCTAssertGreaterThan(discriminating, 100, "the cases tell floor(c) from the left bilinear tap floor(c - 0.5)")
  }
}
