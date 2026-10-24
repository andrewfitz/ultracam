import XCTest

@testable import MonitorKitCore

final class ColorAnalysisTests: XCTestCase {
  func testELZonePublishedVectorChartAnchors() throws {
    XCTAssertEqual(ELZonePublicReference.stopLabels.count, 15)
    XCTAssertEqual(ELZonePublicReference.palette.count, 15)
    XCTAssertEqual(
      ELZonePublicReference.knownReferenceColor(stops: 0), ColorRGB(r: 0.533, g: 0.537, b: 0.506))
    XCTAssertEqual(
      ELZonePublicReference.knownReferenceColor(stops: 0.5), ColorRGB(r: 0.973, g: 0.949, b: 0))
    XCTAssertEqual(
      ELZonePublicReference.knownReferenceColor(stops: -0.5), ColorRGB(r: 0, g: 1, b: 0))
    XCTAssertEqual(
      ELZonePublicReference.knownReferenceColor(stops: 6), ColorRGB(r: 1, g: 1, b: 1))
    XCTAssertEqual(
      ELZonePublicReference.knownReferenceColor(stops: -7), ColorRGB(r: 0, g: 0, b: 0))
    XCTAssertNil(ELZonePublicReference.knownReferenceColor(stops: 0.25))
    XCTAssertNil(ELZonePublicReference.knownReferenceColor(stops: .nan))
    for stop in ELZonePublicReference.stopLabels {
      XCTAssertEqual(
        try XCTUnwrap(
          ColorMath.exposureStops(
            linearLuminance: XCTUnwrap(ELZonePublicReference.referenceLinearLuminance(stops: stop)))
        ), stop, accuracy: 1e-12)
    }
  }
  func testSonyPublishedNativeAnchors() throws {
    XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Encode(0)) * 1023, 95, accuracy: 1e-10)
    XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Encode(0.18)) * 1023, 420, accuracy: 1e-10)
    XCTAssertEqual((try XCTUnwrap(ColorMath.sLog3Encode(0.9)) * 1023).rounded(), 598)
    XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Decode(95.0 / 1023)), 0, accuracy: 1e-12)
    XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Decode(420.0 / 1023)), 0.18, accuracy: 1e-12)
    // Published white code is integer-rounded, so its inverse is approximate.
    XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Decode(598.0 / 1023)), 0.9, accuracy: 0.004)
    XCTAssertEqual(
      try XCTUnwrap(ColorMath.sLog3Encode(0.01125)) * 1023, 171.2102946929, accuracy: 1e-9)
    for x in [-0.01, 0, 0.01125.nextDown, 0.01125, 0.01125.nextUp, 0.18, 0.9, 10] {
      XCTAssertEqual(
        try XCTUnwrap(ColorMath.sLog3Decode(XCTUnwrap(ColorMath.sLog3Encode(x)))), x,
        accuracy: 1e-11)
    }
  }
  func testTransportAndNativeLogAreSeparate() throws {
    for depth in [8, 10, 12, 16] {
      let scale = pow(2, Double(depth - 8))
      XCTAssertEqual(
        try XCTUnwrap(CodeRange.legal.normalizeLuma(code: 16 * scale, bitDepth: depth)), 0)
      XCTAssertEqual(
        try XCTUnwrap(CodeRange.legal.normalizeLuma(code: 235 * scale, bitDepth: depth)), 1)
      XCTAssertEqual(
        try XCTUnwrap(CodeRange.legal.normalizeChroma(code: 128 * scale, bitDepth: depth)), 0
      )
      XCTAssertEqual(
        try XCTUnwrap(CodeRange.legal.normalizeChroma(code: 240 * scale, bitDepth: depth)),
        0.5)
    }
    XCTAssertLessThan(try XCTUnwrap(CodeRange.legal.normalizeLuma(code: 0, bitDepth: 10)), 0)
    XCTAssertGreaterThan(
      try XCTUnwrap(CodeRange.legal.normalizeLuma(code: 1023, bitDepth: 10)), 1)
    let mappedGray = 64 + 876 * 420.0 / 1023
    let gray = try XCTUnwrap(
      NativeLogCodeMapping.fullRescaledToLegal10Bit.nativeNormalized(transportCode: mappedGray))
    XCTAssertEqual(try XCTUnwrap(ColorMath.sLog3Decode(gray)), 0.18, accuracy: 1e-12)
    let native = try XCTUnwrap(
      NativeLogCodeMapping.native10Bit.nativeNormalized(transportCode: 420))
    XCTAssertEqual(gray, native, accuracy: 1e-12)
    XCTAssertNotEqual(CodeRange.legal.normalizeLuma(code: 420, bitDepth: 10), native)
  }
  func testSaturatedMatrixAndSourceGamut() throws {
    // Independently constructed BT.709 red YCbCr vector.
    let rgb = try XCTUnwrap(
      ColorMath.yCbCrToRGB(y: 0.2126, cb: -0.2126 / 1.8556, cr: 0.5, matrix: .bt709))
    XCTAssertEqual(rgb.r, 1, accuracy: 1e-12)
    XCTAssertEqual(rgb.g, 0, accuracy: 1e-12)
    XCTAssertEqual(rgb.b, 0, accuracy: 1e-12)
    let red = ColorRGB(r: 1, g: 0, b: 0)
    XCTAssertEqual(try XCTUnwrap(ColorMath.signalLuma(red, matrix: .bt2020)), 0.2627)
    XCTAssertEqual(
      try XCTUnwrap(ColorMath.linearLuminance(red, gamut: .sGamut3Cine)), 0.215075820115587)
    XCTAssertLessThan(
      try XCTUnwrap(
        ColorMath.linearLuminance(ColorRGB(r: 0, g: 0, b: 1), gamut: .sGamut3Cine)), 0)
    // Linear gamut coefficients sum to white; no saturation clamp before Y.
    for gamut in [ColorGamut.rec709, .rec2020, .sGamut3, .sGamut3Cine] {
      XCTAssertEqual(
        try XCTUnwrap(ColorMath.linearLuminance(ColorRGB(r: 1, g: 1, b: 1), gamut: gamut)),
        1, accuracy: 1e-12)
    }
    let gray = try XCTUnwrap(ColorMath.sLog3Encode(0.18))
    XCTAssertEqual(
      try XCTUnwrap(
        ColorMath.sLog3ExposureStops(
          ColorRGB(r: gray, g: gray, b: gray), gamut: .sGamut3Cine)), 0, accuracy: 1e-12)
  }
  func testExposureBandsAndZebraAndScopeRaster() throws {
    for stop in -12...12 {
      XCTAssertEqual(
        try XCTUnwrap(ColorMath.exposureStops(linearLuminance: 0.18 * pow(2, Double(stop)))),
        Double(stop), accuracy: 1e-12)
    }
    XCTAssertEqual(ColorMath.halfStopBand(stops: 0.24999), 0)
    XCTAssertEqual(ColorMath.halfStopBand(stops: 0.25), 1)
    XCTAssertEqual(ColorMath.halfStopBand(stops: -0.25), 0)
    XCTAssertTrue(ColorMath.zebra(ire: 65, threshold: 70, width: 10, above: false))
    XCTAssertFalse(ColorMath.zebra(ire: 75, threshold: 70, width: 10, above: false))
    XCTAssertTrue(ColorMath.zebra(ire: 100, threshold: 100, width: 0, above: true))
    XCTAssertEqual(ColorMath.scopeBin(normalized: -0.1, binCount: 256), 0)
    XCTAssertEqual(ColorMath.scopeBin(normalized: 0.5, binCount: 256), 127)
    XCTAssertEqual(ColorMath.scopeBin(normalized: 1.1, binCount: 256), 255)
  }
  func testSonyARRIStyleReferenceEncodingUsesExposureDomainCurve() throws {
    // ARRI's EI800 exposure-value coefficients, independently evaluated at anchors.
    for (linear, code) in [
      (0.0, 94.943607), (0.01, 149.85471765), (0.010591, 153.099964289415),
      (0.010591001, 153.09971385448137), (0.18, 399.9999891708677),
      (0.36, 473.3608804648376), (10.0, 835.7062534530921),
    ] {
      XCTAssertEqual(
        try XCTUnwrap(SonyARRIStyleFalseColor.referenceCode(sceneLinearLuma: linear)), code,
        accuracy: 1e-9)
    }
    XCTAssertNil(SonyARRIStyleFalseColor.referenceCode(sceneLinearLuma: .nan))
    XCTAssertNil(SonyARRIStyleFalseColor.referenceCode(sceneLinearLuma: .infinity))
  }
  func testSonyARRIStyleUsesDecodedSourceGamutLuminance() throws {
    // Native S-Log3 codes for linear red=0.8, green=blue=0.0.
    // Cine Y=.1720606561 maps to LogC3 code395.2974 (green); S-Gamut3
    // Y=0.2167837 maps to code 419.49 (unclassified). Encoded luma fails this.
    let red = ColorRGB(r: 0.5715295853251243, g: 95.0 / 1023, b: 95.0 / 1023)
    XCTAssertEqual(SonyARRIStyleFalseColor.category(rgb: red, gamut: .sGamut3Cine), .green)
    XCTAssertNil(SonyARRIStyleFalseColor.category(rgb: red, gamut: .sGamut3))
    XCTAssertEqual(
      SonyARRIStyleFalseColor.color(rgb: red, gamut: .sGamut3Cine), ColorRGB(r: 0, g: 1, b: 0))
    let neutralFixtures: [(Double, ARRIFalseColorCategory)] = [
      (0.09286412512218964, .purple), (0.10610801254574129, .blue),
      (0.41055718475073316, .green), (0.4845461233571402, .pink),
      (0.9725425133474429, .red),
    ]
    for (native, category) in neutralFixtures {
      let rgb = ColorRGB(r: native, g: native, b: native)
      XCTAssertEqual(SonyARRIStyleFalseColor.category(rgb: rgb, gamut: .sGamut3Cine), category)
      XCTAssertEqual(SonyARRIStyleFalseColor.category(rgb: rgb, gamut: .sGamut3), category)
    }
  }
  func testSonyARRIStylePreservesNativeAchromaticFallback() throws {
    let rgb = ColorRGB(r: 0.5844528420750745, g: 0.5844528420750745, b: 0.5844528420750745)
    let color = try XCTUnwrap(SonyARRIStyleFalseColor.color(rgb: rgb, gamut: .sGamut3Cine))
    XCTAssertEqual(color.r, 0.5844528420750745, accuracy: 1e-12)
    XCTAssertEqual(color.g, color.r)
    XCTAssertEqual(color.b, color.r)
    // Negative Cine luminance remains in the reference toe; it is not clipped to purple.
    let blue = ColorRGB(r: 95.0 / 1023, g: 95.0 / 1023, b: 0.5844528420750745)
    let fallback = try XCTUnwrap(SonyARRIStyleFalseColor.color(rgb: blue, gamut: .sGamut3Cine))
    XCTAssertEqual(fallback.r, 0.12835683048618793, accuracy: 1e-12)
    XCTAssertEqual(fallback.g, fallback.r)
    XCTAssertEqual(fallback.b, fallback.r)
  }
  func testSonyARRIStyleRejectsUnknownInterpretationsAndNonfiniteChannels() {
    XCTAssertEqual(
      SonyARRIStyleFalseColor.gamut(forSourceProfileID: "sony-slog3-sgamut3cine"), .sGamut3Cine)
    XCTAssertEqual(SonyARRIStyleFalseColor.gamut(forSourceProfileID: "sony-slog3-sgamut3"), .sGamut3)
    XCTAssertTrue(SonyARRIStyleFalseColor.supports(sourceProfileID: "sony-slog3-sgamut3"))
    for profile in [nil, "slog3-sgamut3cine", "arri-logc3-ei800", "unknown"] as [String?] {
      XCTAssertNil(SonyARRIStyleFalseColor.gamut(forSourceProfileID: profile))
      XCTAssertFalse(SonyARRIStyleFalseColor.supports(sourceProfileID: profile))
    }
    for gamut in [ColorGamut.rec709, .rec2020] {
      let rgb = ColorRGB(r: 0.4, g: 0.4, b: 0.4)
      XCTAssertNil(SonyARRIStyleFalseColor.category(rgb: rgb, gamut: gamut))
      XCTAssertNil(SonyARRIStyleFalseColor.color(rgb: rgb, gamut: gamut))
    }
    for rgb in [
      ColorRGB(r: .nan, g: 0, b: 0), ColorRGB(r: 0, g: .infinity, b: 0),
      ColorRGB(r: 0, g: 0, b: -.infinity), ColorRGB(r: 1e300, g: 0, b: 0),
    ] {
      XCTAssertNil(SonyARRIStyleFalseColor.category(rgb: rgb, gamut: .sGamut3Cine))
      XCTAssertNil(SonyARRIStyleFalseColor.color(rgb: rgb, gamut: .sGamut3Cine))
    }
  }
  func testARRIExactPublishedBoundariesAllProfilesAndRanges() {
    // Table 9/25 independently transcribed checkpoints; lower inclusive, upper exclusive.
    let fixtures: [(ARRIFalseColorProfile, CodeRange, [Double])] = [
      (.logC3EI800, .legal, [878, 940, 857, 878, 461, 480, 397, 415, 152, 172, 64, 152]),
      (.logC3EI800, .full, [951, 1023, 926, 951, 464, 486, 389, 410, 103, 127, 0, 103]),
      (.alexa35LogC4EI800, .legal, [808, 940, 789, 808, 351, 366, 300, 315, 149, 159, 64, 149]),
      (.alexa35LogC4EI800, .full, [868, 1023, 846, 868, 335, 353, 276, 293, 99, 111, 0, 99]),
    ]
    let categories: [ARRIFalseColorCategory] = [.red, .yellow, .pink, .green, .blue, .purple]
    for (profile, range, bounds) in fixtures {
      for (i, category) in categories.enumerated() {
        let low = bounds[2 * i]
        let high = bounds[2 * i + 1]
        XCTAssertEqual(profile.category(achromaticCode: low, range: range), category)
        XCTAssertEqual(profile.category(achromaticCode: high.nextDown, range: range), category)
        XCTAssertNotEqual(profile.category(achromaticCode: high, range: range), category)
        XCTAssertNotEqual(profile.category(achromaticCode: low.nextDown, range: range), category)
      }
      XCTAssertNil(profile.category(achromaticCode: range == .legal ? 940 : 1023, range: range))
      XCTAssertNil(profile.category(achromaticCode: -1, range: range))
    }
    XCTAssertEqual(ARRIFalseColorCategory.pink.color, ColorRGB(r: 1, g: 0.7, b: 0.7))
    XCTAssertEqual(ARRIFalseColorCategory.purple.color, ColorRGB(r: 0.7, g: 0, b: 1))
  }
  func testARRIAchromaticGrayFallbackAndInvalidInputs() throws {
    let rgb = ColorRGB(r: 0.8, g: 0.1, b: 0.4)
    let a = 0.8 * 0.2126 + 0.1 * 0.7152 + 0.4 * 0.0722
    XCTAssertEqual(
      ARRIFalseColorProfile.logC3EI800.color(rgb: rgb, range: .full), ColorRGB(r: a, g: a, b: a))
    XCTAssertNil(ColorMath.sLog3Encode(.nan))
    XCTAssertNil(ColorMath.sLog3Decode(.infinity))
    XCTAssertNil(ColorMath.exposureStops(linearLuminance: 0))
    XCTAssertNil(ColorMath.exposureStops(linearLuminance: -1))
    XCTAssertNil(CodeRange.legal.normalizeLuma(code: 1, bitDepth: 0))
    XCTAssertNil(CodeRange.full.normalizeChroma(code: .nan, bitDepth: 10))
    XCTAssertNil(NativeLogCodeMapping(transportedBlack: 10, transportedWhite: 10))
    let hugeMapping = NativeLogCodeMapping(transportedBlack: -.greatestFiniteMagnitude, transportedWhite: 0)!
    XCTAssertNil(hugeMapping.nativeNormalized(transportCode: .greatestFiniteMagnitude),
                 "overflow must not escape as infinity")
    XCTAssertNil(ColorMath.scopeBin(normalized: .nan, binCount: 256))
    XCTAssertNil(ColorMath.scopeBin(normalized: 0.5, binCount: 0))
    XCTAssertFalse(ColorMath.zebra(ire: .nan, threshold: 70, width: 10, above: true))
    XCTAssertNil(
      ARRIFalseColorProfile.logC3EI800.color(rgb: ColorRGB(r: .nan, g: 0, b: 0), range: .legal))
    XCTAssertNotNil(ColorMath.exposureStops(linearLuminance: .greatestFiniteMagnitude))
    XCTAssertEqual(ColorMath.scopeBin(normalized: 1, binCount: Int.max), Int.max - 1)
    XCTAssertNil(
      NativeLogCodeMapping(
        transportedBlack: -.greatestFiniteMagnitude, transportedWhite: .greatestFiniteMagnitude))
    XCTAssertFalse(ELZoneReferenceStatus.isQualified)
  }
}
