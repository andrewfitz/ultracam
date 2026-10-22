import Metal
import XCTest
import simd

@testable import MonitorKit

/// `MonitorToolsMetalTests/ELZoneMetalTests` (2), `SonyARRIStyleMetalTests` (6,
/// class `SonySLog3MetalTests`) and `ProcessedFalseColorGeometryTests` (1), ported
/// (map §8.2). The processed-output and correspondence mapping is in `PortedSupport.swift`.
///
/// `SonyARRIStyleMetalTests` selected the ARRI-style profile, which MonitorTools
/// migrates to Sony Pattern 2 (its file comment: "Saved Sony ARRI-style selections
/// now intentionally migrate to published Sony Pattern2"), so its six cases assert
/// Pattern 2 colours and are ported as `.sonySLog3`. MonitorKit keeps ARRI-style
/// as its own mode (`.arriStyleSLog3`), covered by `FalseColorTests`.
final class PortedELZoneTests: XCTestCase {
  /// Every native code in a full and a legal container, natively and rescaled into
  /// the legal range, both Sony gamuts, offsets -1, 0 and +1 stops, against
  /// `ELZoneProfile.color`. The original sampled one pixel per 6-pixel group with a
  /// ±1-code tolerance; every pixel is compared exactly here, except codes whose
  /// exposure is within 1e-4 stops of a transition (float may land either side).
  func testEveryNativeCodeAndRescaledTransportMatchTheVersionedCPUConvention() throws {
    let gpu = try requireGPU()
    for gamut in [ColorGamut.sGamut3Cine, .sGamut3] {
      for (range, transport) in [(CodeRange.full, LogTransport.native), (.legal, .native), (.legal, .fullRescaledToLegal)] {
        let codes = (0..<1024).map { Ported.transported($0, transport) }
        let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 2) { x, _ in codes[x] }
        let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3(gamut, transport: transport), range: range))
        for offset in [-1.0, 0, 1] {
          var state = MonitorState()
          state.falseColor.mode = .elZone
          state.falseColor.referenceOffsetStops = offset
          let pass = gpu.engine.makePass()
          let out = try gpu.render(frame, state: state, pass: pass)
          XCTAssertTrue(pass.status.isActive(.falseColor))
          var nearTransition = 0
          for x in 0..<1024 {
            let value = Ported.native(transported: codes[x], transport)
            if let stops = ColorMath.sLog3ExposureStops(Ported.grey(value), gamut: gamut),
              ELZoneProfile.transitions.contains(where: { abs($0 - (stops + offset)) < 1e-4 })
            {
              nearTransition += 1
              continue
            }
            let expected = try XCTUnwrap(ELZoneProfile.color(rgb: Ported.grey(value), gamut: gamut, referenceOffsetStops: offset))
            XCTAssertEqual(out.rgb(x, 0), Ported.vector(expected), "EL code \(codes[x]), \(range) \(transport), offset \(offset), \(gamut)")
          }
          XCTAssertLessThan(nearTransition, 4)
        }
      }
    }
  }

  /// Coloured pixels decode each channel from S-Log3 before the source gamut's Y,
  /// and the output look (the burn-in LUT, flat at two levels) changes nothing.
  /// The surface shows the monitor stage, MonitorKit's `.processedOutput`.
  func testColouredRGBDecodesBeforeGamutLuminanceAndIgnoresTheOutputLook() throws {
    let gpu = try requireGPU()
    for (r, g, b) in [(140, 24, 24), (24, 24, 146), (105, 105, 105)] {
      let picture = Ported.bgra(width: 6, height: 4) { _, _ in (r, g, b) }
      for gamut in [ColorGamut.sGamut3Cine, .sGamut3] {
        let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3(gamut), range: .full))
        let expected = try XCTUnwrap(
          ELZoneProfile.color(rgb: ColorRGB(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255), gamut: gamut))
        var state = MonitorState()
        state.falseColor.mode = .elZone
        // MonitorTools' `.processedOutput` picture: the default monitor stage.
        XCTAssertEqual(state.pictureStage, .monitor)
        for level in Ported.flatLevels {
          let feed = gpu.engine.makeFeed()
          feed.burnInLUT = try Ported.constantLUT(gpu, level)
          let out = try gpu.render(frame, state: state, feed: feed)
          for x in 0..<6 { XCTAssertEqual(out.rgb(x, 0), Ported.vector(expected), "(\(r),\(g),\(b)) \(gamut) output \(level)") }
          // The look does reach the picture once false colour is off.
          let plain = try gpu.render(frame, state: MonitorState(), feed: feed)
          XCTAssertEqual(plain.rgb(0, 0), SIMD3(repeating: level), accuracy: 1e-6)
        }
      }
    }
  }
}

final class PortedSonyPattern2Tests: XCTestCase {
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
      let codes = [95, 420, 496, 550].map { Ported.transported($0, transport) }
      let picture = SyntheticFrame.neutral(.v210, width: 24, height: 2) { x, _ in codes[x / 6] }
      let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3(.sGamut3Cine, transport: transport), range: range))
      let (out, pass) = try render(gpu, frame)
      XCTAssertTrue(pass.status.isActive(.falseColor))
      XCTAssertNil(pass.status.reason(for: .falseColor))
      for x in 0..<24 {
        let native = Ported.native(transported: codes[x / 6], transport)
        let color = try XCTUnwrap(SonySLog3FalseColor.color(nativeSignalLuma: native))
        assertPorted(out.rgb(x, 0), color, exact: SonySLog3FalseColor.category(nativeSignalLuma: native) != nil,
                     "\(range) \(transport) code \(codes[x / 6])")
      }
    }
  }

  /// BGRA carries S-Log3 as 8-bit codes. Semantic difference: MonitorTools read a
  /// legal-labelled BGRA value as native code/255 without range expansion; MonitorKit
  /// expands the legal range like any integer container, so 8-bit 105 is 10-bit code
  /// 420 (40.64 IRE, MATH.md §1 "native log code"), and rescaled 106 is
  /// (106 - 16)/219 native (40.68 IRE). Both are green either way, as the original asserted.
  func testBGRANativeAndExplicitRescaledTransport() throws {
    let gpu = try requireGPU()
    for (value, transport) in [(105, LogTransport.native), (106, .fullRescaledToLegal)] {
      let frame = try Ported.wrapped(gpu, Ported.grey(width: 6, height: 4) { _, _ in value },
                                     signal: Ported.signal(Ported.sLog3(.sGamut3Cine, transport: transport), range: .legal))
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
    let picture = Ported.bgra(width: 6, height: 4) { _, _ in (105, 105, 140) }
    for gamut in [ColorGamut.sGamut3Cine, .sGamut3] {
      let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3(gamut), range: .full))
      let (out, _) = try render(gpu, frame)
      XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 1, 0), "\(gamut)")
    }
  }

  /// Catches classifying the output look instead of the source: a flat burn-in LUT
  /// at two levels leaves the false colour of code 420 green.
  func testFalseColourIgnoresTheOutputLook() throws {
    let gpu = try requireGPU()
    let frame = try Ported.wrapped(gpu, SyntheticFrame.neutral(.v210, width: 6, height: 2) { _, _ in 420 },
                                   signal: Ported.signal(Ported.sLog3Cine, range: .legal))
    for level in Ported.flatLevels {
      let feed = gpu.engine.makeFeed()
      feed.burnInLUT = try Ported.constantLUT(gpu, level)
      let (out, _) = try render(gpu, frame, feed: feed)
      XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 1, 0), "output \(level)")
    }
  }

  /// MonitorTools failed closed on four inputs. In MonitorKit:
  /// - A non-log transfer (`Rec709`): `.requiresLogSource`, and the picture (the
  ///   flat output look) is drawn without false colour, as before.
  /// - Another camera's profile on the frame (MonitorTools: S-Gamut3 against a
  ///   Cine selection; the signal is the only declaration in MonitorKit, so a
  ///   LogC3 frame is the closest input): `.unsupportedLogEncoding`, picture drawn.
  /// - A missing correspondence (MonitorTools could not tie the shown picture to
  ///   the camera's signal): a processed frame (`isProcessed`), refused with
  ///   `.requiresCameraSignal`, picture drawn.
  /// - Semantic difference: `.fullRescaledToLegal` on a full container. MonitorTools
  ///   refused it; MonitorKit unsqueezes the container's own legal range
  ///   (MATH.md 9.6, fixed and tested) and classifies, so code 420 there is
  ///   (420 - 64)/876 native, 40.15 IRE, green.
  func testQualificationFailsClosedWhereMonitorKitHasTheInput() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 6, height: 2) { _, _ in 420 }
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try Ported.constantLUT(gpu, Ported.flatLevels[0])
    let refused: [(SignalEncoding, MonitorUnavailableReason)] = [
      (.display(.bt709), .requiresLogSource),
      (Ported.logC(.arriLogC3), .unsupportedLogEncoding(LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3))),
    ]
    for (encoding, reason) in refused {
      let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(encoding, range: .legal))
      let (out, pass) = try render(gpu, frame, feed: feed)
      XCTAssertEqual(pass.status.reason(for: .falseColor), reason)
      XCTAssertFalse(pass.status.isActive(.falseColor))
      XCTAssertEqual(out.rgb(0, 0), SIMD3(repeating: Ported.flatLevels[0]), accuracy: 1e-6, "\(encoding): the output look is drawn")
    }
    var processed = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3Cine, range: .legal))
    processed.isProcessed = true
    let (drawn, refusing) = try render(gpu, processed, feed: feed)
    XCTAssertEqual(refusing.status.reason(for: .falseColor), .requiresCameraSignal)
    XCTAssertEqual(drawn.rgb(0, 0), SIMD3(repeating: Ported.flatLevels[0]), accuracy: 1e-6, "processed: the output look is drawn")
    let rescaled = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3(.sGamut3Cine, transport: .fullRescaledToLegal), range: .full))
    let (out, pass) = try render(gpu, rescaled, feed: feed)
    XCTAssertTrue(pass.status.isActive(.falseColor))
    let native = DecodeReference.nativeLog(expanded: 420.0 / 1023, range: .full, transport: .fullRescaledToLegal)
    XCTAssertEqual(native, 356.0 / 876, accuracy: 1e-12)
    XCTAssertEqual(SonySLog3FalseColor.category(nativeSignalLuma: native), .green)
    XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 1, 0))
  }

  /// Every native 10-bit code in a legal container, both Sony gamuts, from raw
  /// v210 textures (the IOSurface path is `PortedQualityTests`), against the Core
  /// reference on R'G'B' through the BT.709 matrix.
  func testEveryNativeTenBitCodeMatchesTheCPUReference() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 2) { x, _ in x }
    for gamut in [ColorGamut.sGamut3Cine, .sGamut3] {
      let frame = try picture.frame(gpu, signal: Ported.signal(Ported.sLog3(gamut), range: .legal))
      let (out, _) = try render(gpu, frame)
      for code in 0..<1024 {
        let grey = Double(code) / 1023
        let rgb = try XCTUnwrap(SonySLog3FalseColor.color(rgb: Ported.grey(grey), matrix: .bt709))
        assertPorted(out.rgb(code, 1), rgb, exact: SonySLog3FalseColor.category(nativeSignalLuma: grey) != nil,
                     "\(gamut) native code \(code)")
      }
    }
  }
}

final class PortedFalseColorGeometryTests: XCTestCase {
  /// MonitorTools mapped a preview pixel centre through the processed picture and
  /// the correspondence to a continuous source coordinate, then took one final
  /// floor. MonitorKit has one map, `MonitorLayout.displayToPicture`, and a log
  /// false-colour picture is point-sampled: each display pixel classifies the
  /// source pixel containing its mapped centre (`mk_filtered` with `nearest`).
  ///
  /// Semantic difference: MonitorTools' oracle floored the source coordinate after
  /// subtracting half a pixel (`floor(c - 0.5)` in edge coordinates, the left
  /// bilinear tap). MonitorKit reads the pixel the centre falls in, `floor(c)`, the
  /// same rule as its nearest filter, so the two differ by one pixel wherever the
  /// fractional part of `c` is at least 0.5.
  ///
  /// The cases follow the original's: 3:1 and 1.5:1 minification, 2× magnified (its
  /// 24 × 12 source shown at 48 × 24), an off-centre pan (its 1.25/-0.75 offset
  /// correspondence) and a de-squeezed anamorphic footprint, for Sony Pattern 2, EL
  /// Zone, literal LogC3 and LogC4. Pixels whose mapped centre is within float
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
      (.sonySLog3, Ported.sLog3Cine), (.elZone, Ported.sLog3Cine), (.arriLogC, Ported.logC(.arriLogC3)), (.arriLogC, Ported.logC(.arriLogC4)),
    ]
    var discriminating = 0
    for c in cases {
      let picture = Ported.grey(width: c.sw, height: c.sh) { x, y in codes[(x + 3 * y) % codes.count] }
      for (mode, encoding) in modes {
        let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(encoding, range: .full))
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
            case (.elZone, _):
              expected = try XCTUnwrap(ELZoneProfile.color(rgb: Ported.grey(value), gamut: .sGamut3Cine))
              exact = true
            default:
              let profile = try XCTUnwrap(FalseColorTable.arriProfile(for: try XCTUnwrap(encoding.log?.curve)))
              let category = profile.category(achromaticCode: value * 1023, range: .full)
              expected = category?.color ?? Ported.grey(value)
              exact = category != nil
            }
            assertPorted(out.rgb(x, y), expected, exact: exact,
                         "\(mode) \(encoding) \(c.sw)×\(c.sh) → \(c.ow)×\(c.oh) zoom \(c.zoom): display (\(x),\(y)) → source (\(sx),\(sy))")
            checked += 1
            // Where MonitorTools' half-pixel-left floor reads a different code, this
            // pixel tells the two conventions apart.
            let ox = min(c.sw - 1, max(0, Int((map.apply(x: d.x, y: d.y).x - 0.5).rounded(.down))))
            let oy = min(c.sh - 1, max(0, Int((map.apply(x: d.x, y: d.y).y - 0.5).rounded(.down))))
            if codes[(ox + 3 * oy) % codes.count] != codes[(sx + 3 * sy) % codes.count] { discriminating += 1 }
          }
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThanOrEqual(checked * 10, total * 8, "too many ambiguous centres")
      }
    }
    XCTAssertGreaterThan(discriminating, 100, "the cases tell MonitorKit's floor(c) from MonitorTools' floor(c - 0.5)")
  }
}
