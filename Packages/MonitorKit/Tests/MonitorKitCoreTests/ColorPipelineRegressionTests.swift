import Foundation
import XCTest

@testable import MonitorKitCore

/// Regressions from the W2 colour-pipeline audit: one LUT convention, HLG encoded
/// for its reference display, identity conversions collapsed, overlays on every
/// native layer, the PQ EOTF's domain, and the white-point trim.
final class ColorPipelineRegressionTests: XCTestCase {
  let pq = SignalDescription(matrix: .bt2020, encoding: .display(.pq))
  let hlg = SignalDescription(matrix: .bt2020, encoding: .display(.hlg))
  let log = SignalDescription(encoding: .log(.sLog3SGamut3Cine))

  func pipeline(
    _ output: MonitorOutputColor, signal: SignalDescription = .rec709, mode: DisplayTransform = .none,
    lut: Bool = false
  ) -> MonitorColorPipeline {
    MonitorColorPipeline(
      output: output, signal: signal, transform: DisplayTransformSettings(mode: mode), monitorStageHasLUT: lut)
  }

  func grey(_ v: Double) -> ColorRGB { ColorRGB(r: v, g: v, b: v) }

  // MARK: - LUT convention

  /// LUT output is Rec.709 display R'G'B' in every mode, so no transform runs on it:
  /// the picture, the layer and the status agree.
  func testALUTOnTheMonitorStageMakesEveryTransformUnavailable() {
    let cases: [(SignalDescription, DisplayTransform, MonitorOutputColor)] = [
      (log, .logToRec709, .signalNative), (log, .logToRec709, MonitorOutputColor(encoding: .sdr(.bt1886))),
      (pq, .hdrToSDR, .signalNative), (hlg, .hdrToSDR, MonitorOutputColor(primaries: .rec2020, encoding: .pq)),
      (pq, .hdrPassthrough, MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear)),
      (hlg, .hdrPassthrough, .signalNative),
    ]
    for (signal, mode, output) in cases {
      let p = pipeline(output, signal: signal, mode: mode, lut: true)
      XCTAssertEqual(p.status, .unavailable(.lutOnMonitorStage), "\(mode)")
      XCTAssertEqual(p.transform, .none, "\(mode)")
      XCTAssertFalse(p.passthrough)
      XCTAssertFalse(p.rollsOff)
      XCTAssertEqual(p.picture, .init(transfer: .bt1886, primaries: .rec709), "\(mode)")
      // The layer the host tags agrees with the picture.
      let layer = MonitorOutputColor.recommended(for: signal, displayTransform: mode, monitorStageHasLUT: true)
        .layer(for: signal, displayTransform: mode, monitorStageHasLUT: true)
      XCTAssertEqual(layer.colorSpace, .itur709, "\(mode)")
      // A LUT's Rec.709 value is shown as Rec.709: on a native layer, unchanged.
      if output.encoding == .signalNative {
        XCTAssertEqual(p.present(grey(0.1)), grey(0.1), "\(mode)")
      }
    }
    // Without a LUT the same settings run.
    XCTAssertEqual(pipeline(.signalNative, signal: log, mode: .logToRec709).transform, .logToRec709)
    XCTAssertEqual(pipeline(.signalNative, signal: .rec709, mode: .none, lut: true).status, .off)
  }

  // MARK: - HLG

  /// HLG is encoded for the 1000 cd/m² reference display whatever the output's
  /// nominal peak: HLG to HLG is the identity and graphics white is 75% HLG.
  func testHLGIsEncodedForItsReferenceDisplayAtEveryNominalPeak() {
    for peak in [600.0, 1000, 2000] {
      let output = MonitorOutputColor(primaries: .rec2020, encoding: .hlg, hlgNominalPeak: peak)
      let p = pipeline(output, signal: hlg)
      XCTAssertEqual(p.hlgOutputPeak, 1000)
      XCTAssertFalse(p.convertsToTarget, "HLG to HLG is the identity at \(peak)")
      XCTAssertEqual(p.present(grey(0.75)).g, 0.75, accuracy: 1e-12)
      // Through the full conversion too (the CPU decode and encode agree).
      let l = p.linear(grey(0.75), transfer: .hlg, primaries: .rec2020)
      XCTAssertEqual(p.encode(l, transfer: .hlg, primaries: .rec2020).g, 0.75, accuracy: 1e-9)
      XCTAssertEqual(p.overlayColor(grey(1)).g, 0.75, accuracy: 2e-3, "graphics white at \(peak)")
      XCTAssertEqual(pipeline(output).present(grey(1)).g, 0.75, accuracy: 2e-3, "SDR white at \(peak)")
      let native = pipeline(MonitorOutputColor(hlgNominalPeak: peak), signal: hlg)
      XCTAssertEqual(native.overlayColor(grey(1)).g, 0.75, accuracy: 2e-3, "native overlay white at \(peak)")
    }
    // The nominal peak is the PQ-to-HLG roll-off target, at most the reference peak.
    let rolled = pipeline(MonitorOutputColor(primaries: .rec2020, encoding: .hlg, hlgNominalPeak: 600), signal: pq, mode: .hdrPassthrough)
    XCTAssertEqual(rolled.rolloff(headroom: 1)?.targetPeak, 600)
    let capped = pipeline(MonitorOutputColor(primaries: .rec2020, encoding: .hlg, hlgNominalPeak: 4000), signal: pq, mode: .hdrPassthrough)
    XCTAssertEqual(capped.rolloff(headroom: 1)?.targetPeak, 1000)
  }

  func testHLGToSDRIsLabelledAsTheSDRCameraConvention() {
    XCTAssertEqual(pipeline(.signalNative, signal: hlg, mode: .hdrToSDR).status, .active(label: "HLG → SDR · scene light, BT.709 OETF"))
  }

  // MARK: - Identity conversions

  func testAConversionToThePicturesOwnEncodingIsTheIdentity() {
    let identities: [(SignalDescription, MonitorOutputColor)] = [
      (pq, MonitorOutputColor(primaries: .rec2020, encoding: .pq)),
      (.rec709, MonitorOutputColor(encoding: .sdr(.bt1886))),
      (SignalDescription(encoding: .display(.sRGB)), MonitorOutputColor(encoding: .sdr(.sRGB))),
      (hlg, MonitorOutputColor(primaries: .rec2020, encoding: .hlg, hlgNominalPeak: 1500)),
      // A transform's Rec.709 SDR result onto a fixed Rec.709 SDR layer.
      (pq, MonitorOutputColor(encoding: .sdr(.bt1886))),
    ]
    for (i, (signal, output)) in identities.enumerated() {
      let mode: DisplayTransform = i == 4 ? .hdrToSDR : .none
      let p = pipeline(output, signal: signal, mode: mode)
      XCTAssertNotNil(p.target, "\(i)")
      XCTAssertFalse(p.convertsToTarget, "\(i)")
      // The full conversion would give the same values: the shortcut changes no pixel.
      for v in stride(from: 0.0, through: 1, by: 0.05) {
        let target = p.target!
        let full = p.encode(
          p.pictureToTarget.apply(p.linear(grey(v), transfer: p.picture.transfer, primaries: p.picture.primaries)),
          transfer: target.transfer, primaries: target.primaries)
        // PQ's inverse EOTF puts 0 cd/m² at 7.3e-7, not 0: within a 20-bit code.
        XCTAssertEqual(p.converted(grey(v)).g, full.g, accuracy: 1e-6, "\(i) \(v)")
      }
    }
    let conversions: [(SignalDescription, MonitorOutputColor, DisplayTransform)] = [
      (pq, MonitorOutputColor(primaries: .rec709, encoding: .pq), .none),
      (SignalDescription(range: .full, encoding: .display(.linear)), MonitorOutputColor(encoding: .extendedLinear), .none),
      (pq, MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear), .hdrPassthrough),
      (.rec709, MonitorOutputColor(encoding: .sdr(.gamma22)), .none),
    ]
    for (signal, output, mode) in conversions {
      XCTAssertTrue(pipeline(output, signal: signal, mode: mode).convertsToTarget, "\(output.encoding)")
    }
  }

  // MARK: - Overlays on native layers

  /// Overlays stay as authored only on a BT.1886 or sRGB Rec.709 layer; any other
  /// native picture gets them in its own transfer and primaries.
  func testNativeOverlaysFollowTheLayersPrimariesAndTransfer() {
    XCTAssertNil(pipeline(.signalNative).overlay)
    XCTAssertNil(pipeline(.signalNative, signal: SignalDescription(encoding: .display(.sRGB))).overlay)
    XCTAssertNil(pipeline(.signalNative, signal: log).overlay)
    let red = ColorRGB(r: 1, g: 0, b: 0)
    let sdr2020 = pipeline(.signalNative, signal: SignalDescription(matrix: .bt2020))
    XCTAssertEqual(sdr2020.overlay, .init(transfer: .bt1886, primaries: .rec2020))
    let wide = sdr2020.overlayColor(red)
    XCTAssertEqual(wide.r, pow(0.6274, 1 / 2.4), accuracy: 1e-4)
    XCTAssertEqual(wide.g, pow(0.0691, 1 / 2.4), accuracy: 1e-4)
    let linear = pipeline(.signalNative, signal: SignalDescription(range: .full, encoding: .display(.linear), primaries: .displayP3))
    XCTAssertEqual(linear.overlay, .init(transfer: .linear, primaries: .displayP3))
    // The dark zebra stripe (0.12 BT.1886) is 0.0062 in linear light, not 0.12.
    XCTAssertEqual(linear.overlayColor(grey(0.12)).g, pow(0.12, 2.4), accuracy: 1e-9)
    XCTAssertEqual(linear.overlayColor(grey(1)).g, 1, accuracy: 1e-12)
  }

  func testP3LabelledBT709SignalsGetANamedColourSpace() {
    let p3 = SignalDescription(primaries: .displayP3)
    let layer = MonitorOutputColor.recommended(for: p3).layer(for: p3)
    XCTAssertEqual(layer.kind, .sdr(.bt1886))
    XCTAssertEqual(layer.colorSpace, .displayP3)
  }

  // MARK: - PQ domain

  func testPQEOTFStaysInItsDomain() {
    XCTAssertEqual(ColorMath.pqNits(1), 10_000, accuracy: 1e-6)
    XCTAssertEqual(ColorMath.pqNits(1.09), 10_000, accuracy: 1e-6, "legal code 1019 is not 24 000 cd/m²")
    XCTAssertEqual(ColorMath.pqNits(2), 10_000, accuracy: 1e-6, "no NaN past the pole")
    XCTAssertEqual(ColorMath.pqNits(-0.5), 0)
    let p = pipeline(MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear), signal: pq)
    let out = p.converted(grey(2))
    XCTAssertTrue(out.isFinite)
    XCTAssertEqual(out.g, 10_000 / 203, accuracy: 1e-6)
  }

  // MARK: - White-point trim

  func testDaylightLocusAndTrimmedWhite() {
    // 6504 K on the daylight locus is D65 (CIE 15:2004 Table T.3: 0.31272, 0.32903),
    // to the 1e-4 the locus polynomials reproduce the tabulated illuminants.
    let d65 = WhitePointTrim.daylight(6504)
    XCTAssertEqual(d65.x, 0.31272, accuracy: 2e-5)
    XCTAssertEqual(d65.y, 0.32903, accuracy: 1e-4)
    // D50 (5003 K): 0.34567, 0.35850; D93-ish 9300 K is bluer.
    let d50 = WhitePointTrim.daylight(5003)
    XCTAssertEqual(d50.x, 0.34567, accuracy: 2e-4)
    XCTAssertEqual(d50.y, 0.35850, accuracy: 2e-4)
    XCTAssertLessThan(WhitePointTrim.daylight(9300).x, d65.x)
    // Tint moves along the locus normal by exactly that Δuv; positive is greener.
    let base = WhitePointTrim.uv(WhitePointTrim.white(temperature: 5600, tint: 0))
    let green = WhitePointTrim.uv(WhitePointTrim.white(temperature: 5600, tint: 0.01))
    let du = green.u - base.u, dv = green.v - base.v
    XCTAssertEqual((du * du + dv * dv).squareRoot(), 0.01, accuracy: 1e-9)
    XCTAssertGreaterThan(dv, 0)
    let a = WhitePointTrim.uv(WhitePointTrim.daylight(5590)), b = WhitePointTrim.uv(WhitePointTrim.daylight(5610))
    XCTAssertEqual(du * (b.u - a.u) + dv * (b.v - a.v), 0, accuracy: 1e-9, "normal to the locus")
  }

  func testWhiteTrimGainsMoveWhiteToTheTrimmedWhite() {
    let none = WhitePointTrim.gains(temperature: WhitePointTrim.d65Temperature, tint: 0, primaries: .rec709)
    XCTAssertEqual(none, ColorRGB(r: 1, g: 1, b: 1))
    for primaries in ColorPrimaries.allCases {
      for (t, tint) in [(5000.0, 0.0), (9300, 0), (6504, 0.005), (4000, -0.02), (10_000, 0.02)] {
        let g = WhitePointTrim.gains(temperature: t, tint: tint, primaries: primaries)
        XCTAssertEqual(max(g.r, g.g, g.b), 1, accuracy: 1e-12, "a display cannot drive past full")
        XCTAssertGreaterThan(min(g.r, g.g, g.b), 0.3)
        // Picture white (1, 1, 1) becomes the trimmed white's chromaticity.
        let xyz = primaries.toXYZ.apply(g)
        let sum = xyz.r + xyz.g + xyz.b
        let target = WhitePointTrim.white(temperature: t, tint: tint)
        // Relative to the untrimmed white: RP 177 white is D65 (0.3127, 0.3290), the
        // locus's 6504 K is 2e-5 away, so compare with that offset removed.
        let d65 = WhitePointTrim.daylight(WhitePointTrim.d65Temperature)
        XCTAssertEqual(xyz.r / sum - (target.x - d65.x), 0.3127, accuracy: 3e-4, "\(primaries) \(t) \(tint)")
        XCTAssertEqual(xyz.g / sum - (target.y - d65.y), 0.3290, accuracy: 3e-4, "\(primaries) \(t) \(tint)")
      }
    }
    let warm = WhitePointTrim.gains(temperature: 5000, tint: 0, primaries: .rec709)
    XCTAssertEqual(warm.r, 1)
    XCTAssertLessThan(warm.b, warm.g)
    let cool = WhitePointTrim.gains(temperature: 9300, tint: 0, primaries: .rec709)
    XCTAssertEqual(cool.b, 1)
    XCTAssertGreaterThan(WhitePointTrim.gains(temperature: 6504, tint: 0.01, primaries: .rec709).g, 0.999)
  }

  /// `whiteTrimmed` is a gain in linear display light in every picture transfer
  /// (HLG through its OOTF), and leaves the SDR curves unclipped.
  func testWhiteTrimIsAGainInLinearLight() {
    let g = ColorRGB(r: 1, g: 0.9, b: 0.7)
    let signals: [(SignalDescription, MonitorColorPipeline.Transfer)] = [
      (.rec709, .bt1886), (SignalDescription(encoding: .display(.sRGB)), .sRGB), (pq, .pq), (hlg, .hlg),
      (SignalDescription(range: .full, encoding: .display(.linear)), .linear),
    ]
    for (signal, transfer) in signals {
      let p = pipeline(.signalNative, signal: signal)
      XCTAssertEqual(p.picture.transfer, transfer)
      for v in [0.05, 0.3, 0.6, 0.75, 0.9] {
        let c = ColorRGB(r: v, g: v * 0.8, b: v * 0.5)
        let before = p.linear(c, transfer: transfer, primaries: p.picture.primaries)
        let after = p.linear(p.whiteTrimmed(c, gains: g), transfer: transfer, primaries: p.picture.primaries)
        XCTAssertEqual(after.r, before.r * g.r, accuracy: 1e-9 * max(1, before.r), "\(transfer) \(v)")
        XCTAssertEqual(after.g, before.g * g.g, accuracy: 1e-9 * max(1, before.g), "\(transfer) \(v)")
        XCTAssertEqual(after.b, before.b * g.b, accuracy: 1e-9 * max(1, before.b), "\(transfer) \(v)")
      }
    }
    // BT.1886 above white and below black stay (mirrored, unclipped).
    let p = pipeline(.signalNative)
    XCTAssertEqual(p.whiteTrimmed(grey(1.1), gains: g).r, 1.1, accuracy: 1e-12)
    XCTAssertEqual(p.whiteTrimmed(grey(-0.1), gains: g).b, -0.1 * pow(0.7, 1 / 2.4), accuracy: 1e-12)
  }

  func testTemperatureAndTintDecodeLenientlyAndNormalize() throws {
    var d = DisplayAdjustments()
    XCTAssertTrue(d.isIdentity)
    d.temperature = 5600
    XCTAssertFalse(d.isIdentity)
    XCTAssertTrue(d.trimsWhitePoint)
    d.temperature = WhitePointTrim.d65Temperature
    d.tint = 0.004
    XCTAssertFalse(d.isIdentity)
    let data = try JSONEncoder().encode(d)
    XCTAssertEqual(try JSONDecoder().decode(DisplayAdjustments.self, from: data), d)
    // Saved before the trim existed: no trim. Malformed values fall back.
    let old = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(#"{"brightness":0.1}"#.utf8))
    XCTAssertEqual(old.temperature, WhitePointTrim.d65Temperature)
    XCTAssertEqual(old.tint, 0)
    let junk = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(#"{"temperature":"warm","tint":[1]}"#.utf8))
    XCTAssertTrue(junk.isIdentity)
    var state = MonitorState()
    state.display.temperature = 1e9
    state.display.tint = .nan
    XCTAssertEqual(state.normalized().display.temperature, 10_000)
    XCTAssertEqual(state.normalized().display.tint, 0)
    state.display.temperature = 100
    XCTAssertEqual(state.normalized().display.temperature, 4000)
  }

  /// A linear picture written as it is (signal-native, on its extended linear
  /// layer) keeps its range, as the pass does; display-referred pictures clip to 0…1.
  func testNativeLinearPicturesKeepTheirRange() {
    let linear = SignalDescription(range: .full, encoding: .display(.linear))
    let native = MonitorColorPipeline(output: .recommended(for: linear), signal: linear)
    XCTAssertEqual(native.picture.transfer, .linear)
    XCTAssertFalse(native.convertsToTarget)
    let v = ColorRGB(r: 4, g: -0.25, b: 70_000)
    XCTAssertEqual(native.converted(v), ColorRGB(r: 4, g: -0.25, b: 65504))
    let sdr = MonitorColorPipeline(output: .signalNative, signal: .rec709)
    XCTAssertEqual(sdr.converted(v), ColorRGB(r: 1, g: 0, b: 1))
    let extended = MonitorColorPipeline(
      output: MonitorOutputColor(primaries: .rec709, encoding: .extendedLinear), signal: linear)
    XCTAssertEqual(extended.converted(ColorRGB(r: 4, g: -0.25, b: 0.5)), ColorRGB(r: 4, g: -0.25, b: 0.5))
  }
}
