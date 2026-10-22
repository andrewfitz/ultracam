import Metal
import XCTest
import simd

@testable import MonitorKit

/// Every false-colour mode on the GPU against the Core references. Classification
/// is exact: every integral 10-bit code lands in the same band on both. Gap
/// colours (the picture's grey) agree to float precision.
final class FalseColorTests: XCTestCase {
  static let sLog3 = SignalEncoding.log(.sLog3SGamut3Cine)

  /// One pixel per 10-bit code, 0…1023, neutral, through `layout`.
  func sweep(
    _ mode: FalseColorMode, encoding: SignalEncoding, range: CodeRange, layout: PixelLayout = .v210,
    configure: (inout MonitorState) -> Void = { _ in }
  ) throws -> (pixels: Pixels, pass: MonitorPass) {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(layout, width: 1024, height: 2) { x, _ in x }
    let frame = try picture.frame(gpu, signal: SignalDescription(range: range, matrix: .bt709, encoding: encoding))
    var state = MonitorState()
    state.falseColor.mode = mode
    configure(&state)
    let pass = gpu.engine.makePass()
    return (try gpu.render(frame, state: state, pass: pass), pass)
  }

  /// Exact colour for a classified pixel, float-close grey for a gap.
  func expect(
    _ gpu: SIMD3<Float>, classified: ColorRGB?, gap: Double, _ what: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    if let c = classified {
      XCTAssertEqual(gpu, SIMD3<Float>(c), what(), file: file, line: line)
    } else {
      let g = Float(min(1, max(0, gap)))
      XCTAssertLessThan(simd_reduce_max(simd_abs(gpu - SIMD3(repeating: g))), 2e-6, what(), file: file, line: line)
    }
  }

  func native(_ code: Int, _ range: CodeRange, _ transport: LogTransport) -> Double {
    DecodeReference.nativeLog(
      expanded: range.normalizeLuma(code: Double(code), bitDepth: 10)!, range: range, transport: transport)
  }

  func testSonyPattern2EveryCode() throws {
    for range in [CodeRange.legal, .full] {
      for transport in LogTransport.allCases {
        let encoding = SignalEncoding.log(LogEncoding(curve: .sLog3, gamut: .sGamut3Cine, transport: transport))
        let (out, pass) = try sweep(.sonySLog3, encoding: encoding, range: range)
        XCTAssertEqual(pass.status.active.first { $0.tool == .falseColor }?.label, SonySLog3FalseColor.displayName)
        for code in 0..<1024 {
          let n = native(code, range, transport)
          expect(out.rgb(code, 0), classified: SonySLog3FalseColor.category(nativeSignalLuma: n)?.color, gap: n,
                 "\(range) \(transport) code \(code)")
        }
      }
    }
  }

  func testLiteralARRILogC3AndLogC4EveryCodeInLegalFullAndRescaledTables() throws {
    for curve in [LogCurve.arriLogC3, .arriLogC4] {
      let profile = try XCTUnwrap(FalseColorTable.arriProfile(for: curve))
      for range in [CodeRange.legal, .full] {
        for transport in LogTransport.allCases {
          for layout in [PixelLayout.v210, .p010, .rgb10a2] {
            let encoding = SignalEncoding.log(LogEncoding(curve: curve, gamut: .rec2020, transport: transport))
            let (out, pass) = try sweep(.arriLogC, encoding: encoding, range: range, layout: layout)
            let full = range == .full || transport == .fullRescaledToLegal
            XCTAssertTrue(pass.status.activeLabels.contains(profile.displayName + (full ? " · full range" : " · legal range")))
            for code in 0..<1024 {
              let expanded = range.normalizeLuma(code: Double(code), bitDepth: 10)!
              let logValue = full ? native(code, range, transport) : expanded
              // Integral transport codes classify by the integer itself; rescaled codes by their native value.
              let tableCode = transport == .native ? Double(code) : logValue * 1023
              let category = profile.category(achromaticCode: tableCode, range: full ? .full : .legal)
              expect(out.rgb(code, 0), classified: category?.color, gap: logValue,
                     "\(curve) \(range) \(transport) \(layout) code \(code)")
            }
          }
        }
      }
    }
  }

  /// Every published table edge, and one code either side, through the GPU.
  func testLiteralARRIPublishedEdgesExactly() throws {
    for curve in [LogCurve.arriLogC3, .arriLogC4] {
      let profile = try XCTUnwrap(FalseColorTable.arriProfile(for: curve))
      for range in [CodeRange.legal, .full] {
        let (out, _) = try sweep(.arriLogC, encoding: .log(LogEncoding(curve: curve, gamut: .rec2020)), range: range)
        for zone in profile.zones(range: range) {
          for code in [zone.lower - 1, zone.lower, zone.upper - 1, zone.upper] where (0...1023).contains(code) {
            let category = profile.category(achromaticCode: code, range: range)
            expect(out.rgb(Int(code), 0), classified: category?.color, gap: range.normalizeLuma(code: code, bitDepth: 10)!,
                   "\(curve) \(range) edge \(code)")
          }
        }
      }
    }
  }

  func testARRIStyleOnSLog3EveryCodeAndBothGamuts() throws {
    for gamut in [ColorGamut.sGamut3, .sGamut3Cine] {
      for range in [CodeRange.legal, .full] {
        let (out, _) = try sweep(.arriStyleSLog3, encoding: .log(LogEncoding(curve: .sLog3, gamut: gamut)), range: range)
        var nearBoundary = 0
        for code in 0..<1024 {
          let n = native(code, range, .native)
          let rgb = ColorRGB(r: n, g: n, b: n)
          let category = SonyARRIStyleFalseColor.category(rgb: rgb, gamut: gamut)
          let reference = SonyARRIStyleFalseColor.referenceCode(
            sceneLinearLuma: ColorMath.linearLuminance(
              ColorRGB(r: ColorMath.sLog3Decode(n)!, g: ColorMath.sLog3Decode(n)!, b: ColorMath.sLog3Decode(n)!), gamut: gamut)!)!
          // A continuous measure: a code within float error of a table edge may fall either side.
          if abs(reference - reference.rounded()) < 2e-3 { nearBoundary += 1; continue }
          expect(out.rgb(code, 0), classified: category?.color, gap: n, "\(gamut) \(range) code \(code)")
        }
        XCTAssertLessThan(nearBoundary, 16)
      }
    }
  }

  func testELZoneEveryCodeWithOffsets() throws {
    for gamut in [ColorGamut.sGamut3, .sGamut3Cine] {
      for offset in [0.0, 1.5, -2.25] {
        let (out, pass) = try sweep(.elZone, encoding: .log(LogEncoding(curve: .sLog3, gamut: gamut)), range: .legal) {
          $0.falseColor.referenceOffsetStops = offset
        }
        let entry = try XCTUnwrap(pass.status.active.first { $0.tool == .falseColor })
        XCTAssertTrue(entry.isProvisional)
        XCTAssertTrue(entry.label.contains("provisional"))
        for code in 0..<1024 {
          let n = native(code, .legal, .native)
          let linear = ColorMath.sLog3Decode(n)! * (gamut.luminanceCoefficients.r + gamut.luminanceCoefficients.g + gamut.luminanceCoefficients.b)
          if linear > 0 {
            let stops = log2(linear) - log2(0.18) + offset
            if ELZoneProfile.transitions.contains(where: { abs($0 - stops) < 1e-4 }) { continue }
          }
          let color = try XCTUnwrap(ELZoneProfile.color(rgb: ColorRGB(r: n, g: n, b: n), gamut: gamut, referenceOffsetStops: offset))
          XCTAssertEqual(out.rgb(code, 0), SIMD3<Float>(color), "\(gamut) \(offset) code \(code)")
        }
      }
    }
  }

  /// Coloured pixels: per-channel log decode and source-gamut Y, exactly as Core.
  func testLogModesOnColouredPixels() throws {
    let gpu = try requireGPU()
    var picture = SyntheticFrame.random(.v210, width: 120, height: 40, seed: 31)
    picture.y = picture.y.map { 64 + $0 % 876 }
    picture.cb = picture.cb.map { 512 + ($0 % 200) - 100 }
    picture.cr = picture.cr.map { 512 + ($0 % 200) - 100 }
    for gamut in [ColorGamut.sGamut3, .sGamut3Cine] {
      let signal = SignalDescription(range: .legal, matrix: .bt709, encoding: .log(LogEncoding(curve: .sLog3, gamut: gamut)))
      let frame = try picture.frame(gpu, signal: signal)
      let reference = picture.reference(signal)
      for mode in [FalseColorMode.sonySLog3, .arriStyleSLog3, .elZone] {
        var state = MonitorState()
        state.falseColor.mode = mode
        let out = try gpu.render(frame, state: state)
        var mismatches = 0
        for (i, r) in reference.enumerated() {
          func n(_ v: Double) -> Double { DecodeReference.nativeLog(expanded: v, range: .legal, transport: .native) }
          let rgb = ColorRGB(r: n(r.rgb.x), g: n(r.rgb.y), b: n(r.rgb.z))
          let expected: ColorRGB?
          switch mode {
          case .sonySLog3: expected = SonySLog3FalseColor.color(rgb: rgb, matrix: .bt709)
          case .arriStyleSLog3: expected = SonyARRIStyleFalseColor.color(rgb: rgb, gamut: gamut)
          default: expected = ELZoneProfile.color(rgb: rgb, gamut: gamut)
          }
          let e = try XCTUnwrap(expected)
          let g = out.rgb(i % 120, i / 120)
          if simd_reduce_max(simd_abs(g - SIMD3<Float>(simd_clamp(SIMD3(e.r, e.g, e.b), .zero, SIMD3(repeating: 1))))) > 2e-5 { mismatches += 1 }
        }
        // Only pixels within float error of a band edge may differ.
        XCTAssertLessThanOrEqual(mismatches, 2, "\(mode) \(gamut)")
      }
    }
  }

  func testSixBandOnTheDisplaySignal() throws {
    let (out, pass) = try sweep(.sixBand, encoding: .display(.bt709), range: .legal) { $0.falseColor.stage = .source }
    XCTAssertTrue(pass.status.activeLabels.contains(SixBandFalseColor.displayName))
    for code in 0..<1024 {
      let ire = (Double(code) - 64) / 876 * 100
      expect(out.rgb(code, 0), classified: FalseColorBands.color(ire, bands: SixBandFalseColor.bands),
             gap: ire / 100, "code \(code)")
    }
  }

  static let stopBands = [
    FalseColorBand(lower: -.infinity, upper: -2, color: ColorRGB(r: 0, g: 0, b: 1)),
    FalseColorBand(lower: -2, upper: -0.5, color: ColorRGB(r: 0, g: 1, b: 1)),
    FalseColorBand(lower: -0.5, upper: 0.5, color: ColorRGB(r: 0, g: 1, b: 0)),
    FalseColorBand(lower: 1, upper: 2.5, color: ColorRGB(r: 1, g: 1, b: 0)),
    FalseColorBand(lower: 2.5, upper: .infinity, color: ColorRGB(r: 1, g: 0, b: 0)),
  ]

  func testCustomBandsInIREAndStops() throws {
    let ire = [
      FalseColorBand(lower: 20, upper: 30, color: ColorRGB(r: 0.1, g: 0.2, b: 0.3)),
      FalseColorBand(lower: 25, upper: 50, color: ColorRGB(r: 0.4, g: 0.5, b: 0.6)),  // overlap: first wins
      FalseColorBand(lower: 100, upper: .infinity, color: ColorRGB(r: 1, g: 0, b: 1)),
    ]
    let (irePixels, _) = try sweep(.custom, encoding: .display(.bt709), range: .legal) {
      $0.falseColor.customBands = ire
      $0.falseColor.stage = .source
    }
    for code in 0..<1024 {
      let v = (Double(code) - 64) / 876 * 100
      if abs(v - 25) < 1e-4 || abs(v - 50) < 1e-4 { continue }
      expect(irePixels.rgb(code, 0), classified: FalseColorBands.color(v, bands: ire), gap: v / 100, "IRE code \(code)")
    }
    // Stops on a display signal: the Rec.709 inverse OETF, plus the offset.
    let (display, _) = try sweep(.custom, encoding: .display(.bt709), range: .legal) {
      $0.falseColor.customBands = Self.stopBands
      $0.falseColor.customUnit = .stops
      $0.falseColor.referenceOffsetStops = 0.5
      $0.falseColor.stage = .source
    }
    for code in 0..<1024 {
      let y = (Double(code) - 64) / 876
      let linear = ColorMath.bt709Linear(max(0, y))
      let stops = linear > 0 ? log2(linear / 0.18) + 0.5 : -Double.infinity
      if Self.stopBands.contains(where: { abs($0.lower - stops) < 1e-4 }) { continue }
      expect(display.rgb(code, 0), classified: FalseColorBands.color(stops, bands: Self.stopBands), gap: y,
             "display stops code \(code)")
    }
    // Stops on a log source: scene-linear Y of the log decode.
    let (log, _) = try sweep(.custom, encoding: Self.sLog3, range: .legal) {
      $0.falseColor.customBands = Self.stopBands
      $0.falseColor.customUnit = .stops
    }
    for code in 0..<1024 {
      let n = native(code, .legal, .native)
      let stops = ColorMath.sLog3ExposureStops(ColorRGB(r: n, g: n, b: n), gamut: .sGamut3Cine) ?? -.infinity
      if Self.stopBands.contains(where: { abs($0.lower - stops) < 1e-4 }) { continue }
      expect(log.rgb(code, 0), classified: FalseColorBands.color(stops, bands: Self.stopBands),
             gap: (Double(code) - 64) / 876, "log stops code \(code)")
    }
  }

  /// Custom stops on LogC: the curve fills the container's range (ARRI's tables:
  /// legal code = 64 + 876 t), unlike S-Log3's code convention.
  func testCustomStopsOnLogCFollowARRIsRangeConvention() throws {
    for curve in [LogCurve.arriLogC3, .arriLogC4] {
      for range in [CodeRange.legal, .full] {
        for transport in LogTransport.allCases {
          let encoding = SignalEncoding.log(LogEncoding(curve: curve, gamut: .rec2020, transport: transport))
          let (out, pass) = try sweep(.custom, encoding: encoding, range: range) {
            $0.falseColor.customBands = Self.stopBands
            $0.falseColor.customUnit = .stops
          }
          XCTAssertTrue(pass.status.isActive(.falseColor))
          let k = ColorGamut.rec2020.luminanceCoefficients
          func stops(_ code: Int) -> Double {
            let t = curve.signal(expanded: range.normalizeLuma(code: Double(code), bitDepth: 10)!, range: range, transport: transport)
            let y = curve.decode(t)! * (k.r + k.g + k.b)
            return y > 0 ? log2(y / 0.18) : -.infinity
          }
          for code in 0..<1024 {
            let v = stops(code)
            if Self.stopBands.contains(where: { abs($0.lower - v) < 1e-4 }) { continue }
            expect(out.rgb(code, 0), classified: FalseColorBands.color(v, bands: Self.stopBands),
                   gap: (Double(code) - (range == .legal ? 64 : 0)) / (range == .legal ? 876 : 1023),
                   "\(curve) \(range) \(transport) code \(code)")
          }
          // 18% grey lands at 0 stops in either container: LogC4 0.2784 is legal code 308 and full 285.
          if transport == .native {
            let t = curve == .arriLogC4 ? 0.278396 : 0.391007
            let grey = Int((range == .legal ? 64 + 876 * t : 1023 * t).rounded())
            XCTAssertEqual(stops(grey), 0, accuracy: 0.03, "\(curve) \(range) grey")
            XCTAssertEqual(out.rgb(grey, 0), SIMD3(0, 1, 0), "\(curve) \(range) grey is green")
          }
        }
      }
    }
  }

  /// Display-referred stops use the signal's own transfer: BT.709, sRGB, PQ and
  /// HLG with BT.2408's grey card at 0 stops, linear as is.
  func testCustomStopsLinearizeWithTheSignalsTransfer() throws {
    let gpu = try requireGPU()
    var picture = SyntheticFrame(layout: .rgba32Float, width: 1024, height: 1)
    picture.rgb = (0..<1024).map { SIMD3(repeating: Double($0) / 1023) }
    for transfer in DisplayTransfer.allCases {
      let frame = try picture.frame(gpu, signal: SignalDescription(range: .full, encoding: .display(transfer)))
      var state = MonitorState()
      state.falseColor.mode = .custom
      state.falseColor.customUnit = .stops
      state.falseColor.customBands = Self.stopBands
      state.falseColor.stage = .source
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertTrue(pass.status.isActive(.falseColor), "\(transfer)")
      for i in 0..<1024 {
        let v = Double(Float(Double(i) / 1023))
        let linear = transfer.exposureLinear(v)
        let stops = linear > 0 ? log2(linear / 0.18) : -.infinity
        if Self.stopBands.contains(where: { abs($0.lower - stops) < 2e-3 }) { continue }
        // On an HDR signal's native layer the band colours are encoded into its
        // transfer (graphics white at 203 cd/m²); the grey fallback is the picture's own value.
        let band = FalseColorBands.color(stops, bands: Self.stopBands).map(pass.colorPipeline.overlayColor)
        expect(out.rgb(i, 0), classified: band, gap: v, "\(transfer) \(i)")
      }
    }
    // The grey cards: 18% linear, BT.709 0.409, PQ at 26 cd/m², HLG at 38%.
    XCTAssertEqual(log2(DisplayTransfer.linear.exposureLinear(0.18) / 0.18), 0, accuracy: 1e-12)
    XCTAssertEqual(log2(DisplayTransfer.hlg.exposureLinear(0.38) / 0.18), 0, accuracy: 1e-12)
    XCTAssertEqual(ColorMath.pqNits(0.38), 26, accuracy: 1.5, "BT.2408: the grey card is 38% PQ")
  }

  func testCustomStopsNeedAKnownTransferUnlessALUTMakesTheStage() throws {
    let gpu = try requireGPU()
    let frame = try SyntheticFrame.neutral(.v210, width: 64, height: 1) { x, _ in 64 + x * 13 }
      .frame(gpu, signal: SignalDescription(encoding: .unknown))
    var state = MonitorState()
    state.falseColor.mode = .custom
    state.falseColor.customUnit = .stops
    state.falseColor.customBands = Self.stopBands
    state.falseColor.stage = .output
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let plain = try gpu.render(frame, state: MonitorState(), feed: feed)
    XCTAssertEqual(try gpu.render(frame, state: state, feed: feed, pass: pass).values, plain.values)
    XCTAssertEqual(pass.status.reason(for: .falseColor), .requiresKnownTransfer)
    // IRE needs no transfer.
    state.falseColor.customUnit = .ire
    _ = try gpu.render(frame, state: state, feed: feed, pass: pass)
    XCTAssertTrue(pass.status.isActive(.falseColor))
    // A burn-in LUT makes the output stage Rec.709 display R'G'B'.
    state.falseColor.customUnit = .stops
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try Self.halvingLUT())
    _ = try gpu.render(frame, state: state, feed: feed, pass: pass)
    XCTAssertTrue(pass.status.isActive(.falseColor))
  }

  static func halvingLUT() throws -> CubeLUT {
    var text = "LUT_3D_SIZE 2\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(Float(r) / 2) \(Float(g) / 2) \(Float(b) / 2)\n" } } }
    return try CubeLUT(text: text)
  }

  /// On a log source the output stage after a LUT is display-referred: stops come
  /// from the LUT result, not from the camera log.
  func testCustomStopsHonourTheStageOnALogSource() throws {
    let gpu = try requireGPU()
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 1) { x, _ in x }
    let frame = try picture.frame(gpu, signal: SignalDescription(range: .legal, encoding: Self.sLog3))
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try MonitorLUT(device: gpu.device, cube: try Self.halvingLUT())
    var state = MonitorState()
    state.falseColor.mode = .custom
    state.falseColor.customUnit = .stops
    state.falseColor.customBands = Self.stopBands
    for stage in SignalStage.allCases {
      state.falseColor.stage = stage
      let out = try gpu.render(frame, state: state, feed: feed)
      for code in 0..<1024 {
        let e = (Double(code) - 64) / 876
        // The LUT clamps its input to its domain.
        let lut = min(1, max(0, e)) / 2
        let stops: Double
        if stage == .source {
          let n = native(code, .legal, .native)
          stops = ColorMath.sLog3ExposureStops(ColorRGB(r: n, g: n, b: n), gamut: .sGamut3Cine) ?? -.infinity
        } else {
          let linear = ColorMath.bt709Linear(lut)
          stops = linear > 0 ? log2(linear / 0.18) : -.infinity
        }
        if Self.stopBands.contains(where: { abs($0.lower - stops) < 1e-3 }) { continue }
        let gap = stage == .source ? e : lut
        expect(out.rgb(code, 0), classified: FalseColorBands.color(stops, bands: Self.stopBands), gap: gap,
               "\(stage) code \(code)")
      }
    }
  }

  func testUnavailableModesReportWhyAndStillDrawThePicture() throws {
    let gpu = try requireGPU()
    let cases: [(FalseColorMode, SignalEncoding, MonitorUnavailableReason)] = [
      (.sonySLog3, .display(.bt709), .requiresLogSource),
      (.elZone, .unknown, .requiresLogSource),
      (.arriLogC, Self.sLog3, .unsupportedLogEncoding(.sLog3SGamut3Cine)),
      (.sonySLog3, .log(LogEncoding(curve: .arriLogC3, gamut: .rec709)), .unsupportedLogEncoding(LogEncoding(curve: .arriLogC3, gamut: .rec709))),
      (.arriStyleSLog3, .log(LogEncoding(curve: .sLog3, gamut: .rec2020)), .unsupportedLogEncoding(LogEncoding(curve: .sLog3, gamut: .rec2020))),
      (.custom, .display(.bt709), .noBands),
    ]
    let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 1) { x, _ in x }
    for (mode, encoding, reason) in cases {
      let frame = try picture.frame(gpu, signal: SignalDescription(encoding: encoding))
      var state = MonitorState()
      state.falseColor.mode = mode
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertEqual(pass.status.reason(for: .falseColor), reason, "\(mode)")
      XCTAssertFalse(pass.status.isActive(.falseColor))
      let plain = try gpu.render(frame, state: MonitorState())
      XCTAssertEqual(out.values, plain.values, "\(mode): the picture is drawn without false colour")
    }
  }

  /// Full containers of 8, 12 and 16 bits labelled `.fullRescaledToLegal` carry
  /// codes squeezed into their own legal range, 16s…235s (MATH.md 9.6): Sony
  /// Pattern 2 and the literal ARRI table read the camera's full-range signal
  /// at every depth, not the 10-bit (e·1023 - 64)/876.
  func testRescaledLogInFullContainersOfEveryDepth() throws {
    let gpu = try requireGPU()
    let profile = try XCTUnwrap(FalseColorTable.arriProfile(for: .arriLogC3))
    for layout in [PixelLayout.biplanar(.s444, bitDepth: 8), .bgra8, .biplanar(.s444, bitDepth: 12), .biplanar(.s444, bitDepth: 16)] {
      let depth = layout.bitDepth, maximum = (1 << depth) - 1
      // One pixel per container code at 8 bits, an even spread of the code space deeper.
      let code = { (x: Int) in depth == 8 ? min(x, maximum) : x * (maximum + 1) / 1024 }
      let picture = SyntheticFrame.neutral(layout, width: 1024, height: 2) { x, _ in code(x) }
      for curve in [LogCurve.sLog3, .arriLogC3] {
        let encoding = SignalEncoding.log(
          LogEncoding(curve: curve, gamut: curve == .sLog3 ? .sGamut3Cine : .arriWideGamut3, transport: .fullRescaledToLegal))
        let frame = try picture.frame(gpu, signal: SignalDescription(range: .full, matrix: .bt709, encoding: encoding))
        var state = MonitorState()
        state.falseColor.mode = curve == .sLog3 ? .sonySLog3 : .arriLogC
        let out = try gpu.render(frame, state: state, pass: gpu.engine.makePass())
        var checked = 0
        for x in 0..<(depth == 8 ? 256 : 1024) {
          let e = Double(code(x)) / Double(maximum)
          let t = curve.signal(expanded: e, range: .full, transport: .fullRescaledToLegal, bitDepth: depth)
          XCTAssertEqual(t, (Double(code(x)) - 16 * Double(1 << (depth - 8))) / (219 * Double(1 << (depth - 8))), accuracy: 1e-12)
          func color(_ t: Double) -> ColorRGB? {
            curve == .sLog3
              ? SonySLog3FalseColor.category(nativeSignalLuma: t)?.color
              : profile.category(achromaticCode: t * 1023, range: .full)?.color
          }
          // A value within float rounding of a band edge may classify either way.
          guard color(t - 1e-5) == color(t + 1e-5) else { continue }
          expect(out.rgb(x, 0), classified: color(t), gap: t, "\(layout) \(curve) code \(code(x))")
          checked += 1
        }
        XCTAssertGreaterThan(checked, depth == 8 ? 240 : 1000, "\(layout) \(curve)")
      }
    }
  }

  func testCleanFeedSuppressesFalseColor() throws {
    let (out, pass) = try sweep(.sonySLog3, encoding: Self.sLog3, range: .legal) { $0.clean = true }
    XCTAssertEqual(pass.status.reason(for: .falseColor), .cleanFeed)
    XCTAssertEqual(out.rgb(420, 0), SIMD3(repeating: Float(420 - 64) / 876), accuracy: 1e-6)
  }
}

func XCTAssertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(a - b)), accuracy, message, file: file, line: line)
}
