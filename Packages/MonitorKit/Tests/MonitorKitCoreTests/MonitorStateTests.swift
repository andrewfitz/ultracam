import Foundation
import XCTest

@testable import MonitorKitCore

final class MonitorStateTests: XCTestCase {
  static func everythingChanged() -> MonitorState {
    var s = MonitorState()
    s.clean = true
    s.zebras = [
      ZebraSet(mode: .band, level: 70, range: 5, opacity: 0.4, stage: .source),
      ZebraSet(mode: .lowerLimit, level: 100, opacity: 0.9, stage: .monitor),
    ]
    s.falseColor.mode = .custom
    s.falseColor.referenceOffsetStops = -1.5
    s.falseColor.stage = .monitor
    s.falseColor.customUnit = .stops
    s.falseColor.customBands = [FalseColorBand(lower: -.infinity, upper: -2, color: ColorRGB(r: 0, g: 0, b: 1))]
    s.focus = FocusSettings()
    s.focus.enabled = true
    s.focus.style = .peak
    s.focus.color = .yellow
    s.focus.sensitivity = 0.75
    s.focus.noiseRejection = 0.05
    s.focus.opacity = 0.6
    s.focus.stage = .output
    s.guides.enabled = true
    s.guides.frameGuides = [FrameGuide(aspect: 2.39, style: .matte, matteOpacity: 0.8)]
    s.guides.safeAreas = [90, 93]
    s.guides.followsFrameGuide = false
    s.guides.thirds = false
    s.guides.squareGrid = true
    s.guides.squareGridRows = 6
    s.guides.diagonals = true
    s.guides.centerCross = true
    s.guides.centerDot = true
    s.guides.color = ColorRGB(r: 1, g: 0.5, b: 0)
    s.guides.opacity = 0.3
    s.guides.contrast = 0.2
    s.guides.lineWidth = 2
    s.geometry.desqueeze = 1.65
    s.geometry.flip = .rotate180
    s.geometry.magnification.zoom = 4
    s.geometry.magnification.pixelExact = true
    s.geometry.magnification.centerX = 0.2
    s.geometry.magnification.centerY = 0.9
    s.geometry.magnification.showsNavigator = false
    s.display.brightness = 0.1
    s.display.contrast = 1.3
    s.display.saturation = 0.4
    s.display.monochrome = .blueOnly
    s.monitorLUT = false
    s.displayTransform = DisplayTransformSettings(mode: .hdrToSDR, pqSourcePeak: 4000)
    s.clipIndicators.enabled = true
    s.clipIndicators.stage = .source
    s.clipIndicators.luma = false
    s.clipIndicators.showsUnder = false
    s.clipIndicators.high = 98
    s.clipIndicators.low = 2
    s.clipIndicators.coloring = .uniform
    s.clipIndicators.overColor = ColorRGB(r: 1, g: 0, b: 1)
    s.clipIndicators.opacity = 0.5
    s.pictureStage = .source
    return s
  }

  func testCodableRoundTripKeepsEverySetting() throws {
    let s = Self.everythingChanged()
    let data = try JSONEncoder().encode(s)
    XCTAssertEqual(try JSONDecoder().decode(MonitorState.self, from: data), s)
    XCTAssertEqual(try JSONDecoder().decode(MonitorState.self, from: try JSONEncoder().encode(MonitorState())), MonitorState())
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["schemaVersion"] as? Int, MonitorState.schemaVersion)
    XCTAssertEqual(json["schemaVersion"] as? Int, 2)
    XCTAssertEqual(json["kind"] as? String, "MonitorKit.MonitorState")
    XCTAssertEqual(json["pictureStage"] as? String, "source")
  }

  func testOpenBandEdgesSurviveJSON() throws {
    var s = MonitorState()
    s.falseColor.customBands = SixBandFalseColor.bands
    let data = try JSONEncoder().encode(s)
    XCTAssertEqual(try JSONDecoder().decode(MonitorState.self, from: data).falseColor.customBands, SixBandFalseColor.bands)
  }

  /// The JSON header every genuine blob carries.
  static let header = #""kind": "MonitorKit.MonitorState", "schemaVersion": 2"#

  func testLenientInsideAGenuineBlob() throws {
    func decode(_ fields: String) throws -> MonitorState {
      let body = fields.isEmpty ? Self.header : Self.header + ", " + fields
      return try JSONDecoder().decode(MonitorState.self, from: Data("{\(body)}".utf8))
    }
    XCTAssertEqual(try decode(""), MonitorState(), "a header alone is the defaults")
    let partial = try decode(
      #""clean": "yes", "focus": {"enabled": true, "color": "magenta", "sensitivity": "high"}, "display": {"saturation": 1.5}, "pictureStage": "nonsense""#)
    XCTAssertFalse(partial.clean, "malformed values fall back")
    XCTAssertTrue(partial.focus.enabled)
    XCTAssertEqual(partial.focus.color, .red)
    XCTAssertEqual(partial.focus.sensitivity, 0.5)
    XCTAssertEqual(partial.display.saturation, 1.5)
    XCTAssertEqual(partial.pictureStage, .monitor, "an unknown picture stage decodes as the default")
    XCTAssertEqual(try decode(#""pictureStage": "output""#).pictureStage, .output)
    // Out-of-range values are normalized on decode.
    let wild = try decode(#""zebras": [{"level": 500, "range": -3}], "geometry": {"desqueeze": 0.2, "magnification": {"zoom": 1000}}"#)
    XCTAssertEqual(wild.zebras.count, 2)
    XCTAssertEqual(wild.zebras[0].level, 120)
    XCTAssertEqual(wild.zebras[0].range, 0)
    XCTAssertEqual(wild.geometry.desqueeze, 1)
    XCTAssertEqual(wild.geometry.magnification.zoom, 64)
    // A newer MonitorKit's schema decodes what this one knows (changes within a kind are additive).
    let newer = try JSONDecoder().decode(
      MonitorState.self,
      from: Data(#"{"kind": "MonitorKit.MonitorState", "schemaVersion": 3, "clean": true, "futureField": 1}"#.utf8))
    XCTAssertTrue(newer.clean)
  }

  /// R13: anything that is not a MonitorKit MonitorState throws instead of decoding partially.
  func testForeignJSONFailsClosed() {
    let foreign = [
      "{}", "[]", "1", "null", #""MonitorKit.MonitorState""#,
      #"{"schemaVersion": 1, "clean": true}"#,  // MonitorKit's own discriminator-less schema 1
      #"{"schemaVersion": 2, "clean": true}"#,  // a version without the discriminator
      #"{"kind": "MonitorKit.MonitorState", "clean": true}"#,  // no version
      #"{"kind": "MonitorKit.MonitorState", "schemaVersion": 1, "clean": true}"#,
      #"{"kind": "MonitorKit.MonitorState", "schemaVersion": "2"}"#,
      #"{"kind": "MonitorKit.ScopeSettings", "schemaVersion": 2}"#,
      #"{"kind": 7, "schemaVersion": 2}"#,
    ]
    for json in foreign {
      XCTAssertThrowsError(try JSONDecoder().decode(MonitorState.self, from: Data(json.utf8)), json) { error in
        guard case DecodingError.dataCorrupted = error else { return XCTFail("\(json): \(error)") }
      }
    }
  }

  /// A realistic blob of Ultracam's old `MonitorConfiguration` (Packages/MonitorTools,
  /// `MonitorConfiguration.swift`, its synthesized keys and values) as AppSettingsStore
  /// saved it: the user had switched the master tools switch off with guides,
  /// peaking and false colour configured. Decoded as MonitorState it used to come
  /// back partially, with those tools on (integration map §5.2); it must throw.
  func testOldMonitorConfigurationBlobThrows() throws {
    let old = #"""
      {
        "schemaVersion": 1,
        "toolsEnabled": false,
        "guides": {"enabled": true, "thirds": true, "centerCross": true, "safeArea": true, "opacity": 0.65, "contrast": 1},
        "zebra": {"enabled": true, "thresholdIRE": 95, "widthIRE": 5, "mode": "aboveThreshold", "opacity": 0.65},
        "falseColor": {"mode": "sonySLog3", "profileID": "sony-slog3-false-color-v1",
                       "specificationVersion": "sony-monitor-control-pattern2-v1", "exposureIndex": 800,
                       "referenceOffsetStops": 0},
        "focus": {"enabled": true, "color": "red", "sensitivity": 0.5, "noiseRejection": 0.02, "opacity": 0.85},
        "scopes": {"enabled": true, "mode": "rgbParade", "gain": 1, "graticule": true, "refreshHz": 15},
        "pictureStage": "processedOutput",
        "scopeStage": "processedOutput",
        "sourceProfileID": "sony-slog3-sgamut3cine",
        "sourceCodeRange": "legal",
        "sourceLogMapping": "native10Bit"
      }
      """#
    XCTAssertThrowsError(try JSONDecoder().decode(MonitorState.self, from: Data(old.utf8)))
    // The same blob nested in a host's settings: the host's own lenient wrapper sees
    // an error, not a partial state, and keeps its fallback.
    struct Feed: Decodable {
      var monitor: MonitorState?
      enum CodingKeys: CodingKey { case monitor }
      init(from decoder: Decoder) throws {
        monitor = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(MonitorState.self, forKey: .monitor)
      }
    }
    let feed = try JSONDecoder().decode(Feed.self, from: Data(#"{"monitor": \#(old)}"#.utf8))
    XCTAssertNil(feed.monitor)
    // And the defaults the host falls back to keep every tool off.
    let d = MonitorState()
    XCTAssertFalse(d.guides.enabled || d.focus.enabled || d.zebras[0].enabled || d.falseColor.mode != .off)
  }

  func testPictureStageRule() {
    var s = MonitorState()
    XCTAssertEqual(s.pictureStage, .monitor)
    XCTAssertTrue(s.pictureHasLUT(burnInLUT: true, monitorLUT: false))
    XCTAssertTrue(s.pictureHasLUT(burnInLUT: false, monitorLUT: true))
    XCTAssertFalse(s.pictureHasLUT(burnInLUT: false, monitorLUT: false))
    s.monitorLUT = false
    XCTAssertFalse(s.pictureHasLUT(burnInLUT: false, monitorLUT: true), "the surface does not apply the monitor LUT")
    s.monitorLUT = true
    s.pictureStage = .output
    XCTAssertTrue(s.pictureHasLUT(burnInLUT: true, monitorLUT: true))
    XCTAssertFalse(s.pictureHasLUT(burnInLUT: false, monitorLUT: true), "the output stage has no monitor LUT")
    s.pictureStage = .source
    XCTAssertFalse(s.pictureHasLUT(burnInLUT: true, monitorLUT: true))
  }

  func testNormalizationClampsAndResetsNonFinite() {
    var s = MonitorState()
    s.zebras = [ZebraSet(mode: .band, level: .nan, range: 99), ZebraSet(), ZebraSet()]
    s.focus.sensitivity = 2
    s.guides.lineWidth = .infinity
    s.guides.safeAreas = [5, 90, .nan, 101, 80, 93, 95]
    s.guides.frameGuides = [FrameGuide(aspect: 0), FrameGuide(aspect: 2.39)]
    s.guides.squareGridRows = 40
    s.guides.color = ColorRGB(r: .nan, g: 0, b: 0)
    s.falseColor.customBands = Array(repeating: FalseColorBand(lower: 0, upper: 1, color: ColorRGB(r: 1, g: 1, b: 1)), count: 20)
      + [FalseColorBand(lower: .nan, upper: 1, color: ColorRGB(r: 1, g: 1, b: 1))]
    let n = s.normalized()
    XCTAssertEqual(n.zebras.count, MonitorState.maximumZebraSets)
    XCTAssertEqual(n.zebras[0].level, 95)
    XCTAssertEqual(n.zebras[0].range, 30)
    XCTAssertEqual(n.focus.sensitivity, 1)
    XCTAssertEqual(n.guides.lineWidth, 1)
    XCTAssertEqual(n.guides.safeAreas, [90, 80, 93, 95])
    XCTAssertEqual(n.guides.frameGuides.map(\.aspect), [2.39])
    XCTAssertEqual(n.guides.squareGridRows, 16)
    XCTAssertEqual(n.guides.color, ColorRGB(r: 1, g: 1, b: 1))
    XCTAssertEqual(n.falseColor.customBands.count, FalseColorSettings.maximumCustomBands)
    XCTAssertEqual(n.normalized(), n, "idempotent")
  }

  func testZebraCoverageIsHalfOpen() {
    let lower = ZebraSet(mode: .lowerLimit, level: 95)
    XCTAssertTrue(lower.covers(ire: 95))
    XCTAssertFalse(lower.covers(ire: 95.0.nextDown))
    XCTAssertTrue(lower.covers(ire: 120))
    let band = ZebraSet(mode: .band, level: 70, range: 5)
    XCTAssertTrue(band.covers(ire: 65))
    XCTAssertTrue(band.covers(ire: 75.0.nextDown))
    XCTAssertFalse(band.covers(ire: 75))
    XCTAssertFalse(band.covers(ire: 65.0.nextDown))
    XCTAssertFalse(ZebraSet().covers(ire: 100), "disabled")
    XCTAssertFalse(lower.covers(ire: .nan))
  }

  func testSensitivityMapsToTheEdgeThreshold() {
    var f = FocusSettings()
    for (sensitivity, threshold) in [(0.0, 0.32), (0.25, 0.245), (0.5, 0.17), (0.75, 0.095), (1.0, 0.02), (-1, 0.32), (3, 0.02)] {
      f.sensitivity = sensitivity
      XCTAssertEqual(f.edgeThreshold, threshold, accuracy: 1e-12, "\(sensitivity)")
    }
  }

  func testModeMetadata() {
    XCTAssertEqual(FalseColorMode.allCases.filter(\.needsLogSource), [.sonySLog3, .arriStyleSLog3, .arriLogC, .elZone])
    XCTAssertTrue(FlipMode.rotate180.flipsX && FlipMode.rotate180.flipsY)
    XCTAssertTrue(FlipMode.horizontal.flipsX && !FlipMode.horizontal.flipsY)
    var m = Magnification()
    XCTAssertFalse(m.isActive)
    m.pixelExact = true
    XCTAssertTrue(m.isActive)
    XCTAssertTrue(DisplayAdjustments().isIdentity)
    XCTAssertEqual(ViewGeometry.standardDesqueezeFactors, [1, 1.3, 1.33, 1.5, 1.65, 1.66, 1.8, 2])
    XCTAssertEqual(FrameGuide.standardAspects.count, 16)
  }
}

final class FalseColorTableTests: XCTestCase {
  func testTablesAreTheCoreReferenceTables() throws {
    var s = FalseColorSettings()
    s.mode = .sonySLog3
    XCTAssertEqual(FalseColorTable.bands(for: s).map(\.lower), SonySLog3FalseColor.zones.map(\.lowerIRE))
    XCTAssertEqual(FalseColorTable.bands(for: s).map(\.color), SonySLog3FalseColor.zones.map(\.category.color))
    s.mode = .arriStyleSLog3
    XCTAssertEqual(FalseColorTable.bands(for: s).map(\.upper), ARRIFalseColorProfile.logC3EI800.zones(range: .full).map(\.upper))
    s.mode = .arriLogC
    XCTAssertEqual(FalseColorTable.bands(for: s), [], "needs a curve")
    for (curve, profile) in [(LogCurve.arriLogC3, ARRIFalseColorProfile.logC3EI800), (.arriLogC4, .alexa35LogC4EI800)] {
      for range in [CodeRange.legal, .full] {
        let bands = FalseColorTable.bands(for: s, arriCurve: curve, arriFullRange: range == .full)
        XCTAssertEqual(bands.map(\.lower), profile.zones(range: range).map(\.lower))
        XCTAssertEqual(bands.map(\.upper), profile.zones(range: range).map(\.upper))
      }
    }
    s.mode = .sixBand
    XCTAssertEqual(FalseColorTable.bands(for: s), SixBandFalseColor.bands)
    s.mode = .custom
    s.customBands = Array(repeating: FalseColorBand(lower: 0, upper: 1, color: ColorRGB(r: 0, g: 0, b: 0)), count: 30)
    XCTAssertEqual(FalseColorTable.bands(for: s).count, 16)
    XCTAssertEqual(FalseColorTable.measure(for: s), .stageIRE)
    s.customUnit = .stops
    XCTAssertEqual(FalseColorTable.measure(for: s), .stageStops)
  }

  /// The EL Zone table classifies like `ELZoneProfile.zoneIndex`, black owning -6.
  func testELZoneTableMatchesTheProfileIncludingMinusSix() throws {
    var s = FalseColorSettings()
    s.mode = .elZone
    let bands = FalseColorTable.bands(for: s)
    XCTAssertEqual(bands.count, 15)
    var values: [Double] = [-100, -6, 6, 100]
    for t in ELZoneProfile.transitions { values += [t, t.nextDown, t.nextUp, Double(Float(t).nextDown), Double(Float(t).nextUp)] }
    for i in stride(from: -80, through: 80, by: 1) { values.append(Double(i) / 10) }
    for v in values {
      let expected = ELZoneProfile.zoneIndex(stops: v).map { ELZoneProfile.palette[$0] }
      // Values strictly between -6 and Float(-6).nextUp exist only in Double.
      if v > -6 && v < Double(Float(-6).nextUp) { continue }
      XCTAssertEqual(FalseColorBands.color(v, bands: bands), expected, "\(v)")
    }
  }

  func testBandsAreHalfOpenAndInfiniteValuesClassify() {
    let bands = [
      FalseColorBand(lower: -.infinity, upper: 0, color: ColorRGB(r: 1, g: 0, b: 0)),
      FalseColorBand(lower: 10, upper: .infinity, color: ColorRGB(r: 0, g: 1, b: 0)),
    ]
    XCTAssertEqual(FalseColorBands.color(-.infinity, bands: bands), ColorRGB(r: 1, g: 0, b: 0))
    XCTAssertNil(FalseColorBands.color(0, bands: bands))
    XCTAssertEqual(FalseColorBands.color(10, bands: bands), ColorRGB(r: 0, g: 1, b: 0))
    XCTAssertNil(FalseColorBands.color(.infinity, bands: bands), "upper edges are exclusive, even open ones")
    XCTAssertNil(FalseColorBands.color(.nan, bands: bands))
  }
}

final class DecodeReferenceTests: XCTestCase {
  func testChromaTapsFollowTheSiting() {
    // 4:2:2 left-sited: even pixels are co-sited, odd ones midway.
    var t = DecodeReference.chromaTaps(x: 4, y: 3, width: 10, height: 4, subsampling: .s422, siting: .left)
    XCTAssertEqual(t.x0, 2); XCTAssertEqual(t.fx, 0); XCTAssertEqual(t.y0, 3); XCTAssertEqual(t.fy, 0)
    t = DecodeReference.chromaTaps(x: 5, y: 3, width: 10, height: 4, subsampling: .s422, siting: .left)
    XCTAssertEqual(t.x0, 2); XCTAssertEqual(t.x1, 3); XCTAssertEqual(t.fx, 0.5)
    // Centred: a quarter of the way, clamped at the left edge.
    t = DecodeReference.chromaTaps(x: 0, y: 0, width: 10, height: 4, subsampling: .s422, siting: .center)
    XCTAssertEqual(t.x0, 0); XCTAssertEqual(t.x1, 0); XCTAssertEqual(t.fx, 0.75)
    t = DecodeReference.chromaTaps(x: 3, y: 0, width: 10, height: 4, subsampling: .s422, siting: .center)
    XCTAssertEqual(t.x0, 1); XCTAssertEqual(t.x1, 2); XCTAssertEqual(t.fx, 0.25)
    // The last column of an odd width clamps to the last chroma sample.
    t = DecodeReference.chromaTaps(x: 8, y: 0, width: 9, height: 4, subsampling: .s422, siting: .left)
    XCTAssertEqual(t.x0, 4); XCTAssertEqual(t.x1, 4)
    // 4:2:0 rows sit between luma rows: row 0 and the last row clamp.
    t = DecodeReference.chromaTaps(x: 0, y: 0, width: 8, height: 6, subsampling: .s420, siting: .left)
    XCTAssertEqual(t.y0, 0); XCTAssertEqual(t.y1, 0); XCTAssertEqual(t.fy, 0.75)
    t = DecodeReference.chromaTaps(x: 0, y: 1, width: 8, height: 6, subsampling: .s420, siting: .left)
    XCTAssertEqual(t.y0, 0); XCTAssertEqual(t.y1, 1); XCTAssertEqual(t.fy, 0.25)
    t = DecodeReference.chromaTaps(x: 0, y: 5, width: 8, height: 6, subsampling: .s420, siting: .left)
    XCTAssertEqual(t.y0, 2); XCTAssertEqual(t.y1, 2)
    t = DecodeReference.chromaTaps(x: 3, y: 2, width: 8, height: 6, subsampling: .s444, siting: .center)
    XCTAssertEqual(t.x0, 3); XCTAssertEqual(t.y0, 2); XCTAssertEqual(t.fx, 0)
  }

  func testRGBAndNativeLogFollowTheCodeRanges() throws {
    for depth in [8, 10, 12, 16] {
      for range in [CodeRange.legal, .full] {
        let l = range.levels(bitDepth: depth)
        XCTAssertEqual(l.black, range == .full ? 0 : 16 * pow(2, Double(depth - 8)))
        let white = DecodeReference.rgb(lumaCode: l.black + l.span, cbCode: l.center, crCode: l.center, bitDepth: depth, range: range, matrix: .bt709)
        XCTAssertEqual(white.rgb, ColorRGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(try XCTUnwrap(range.normalizeLuma(code: l.black + l.span, bitDepth: depth)), 1, accuracy: 1e-15)
      }
    }
    // Red at 75%: Cr pushes R, Cb and Cr pull G.
    let red = DecodeReference.rgb(lumaCode: 64 + 876 * 0.2126 * 0.75, cbCode: 512 - 0.1146 * 0.75 * 896, crCode: 512 + 0.5 * 0.75 * 896, bitDepth: 10, range: .legal, matrix: .bt709)
    XCTAssertEqual(red.rgb.r, 0.75, accuracy: 1e-3)
    XCTAssertEqual(red.rgb.g, 0, accuracy: 1e-3)
    XCTAssertEqual(red.rgb.b, 0, accuracy: 1e-3)
    // Native log codes: legal container native → code / 1023; rescaled → the legal range is the camera's full range.
    for code in [0.0, 64, 95, 420, 940, 1023] {
      let legal = CodeRange.legal.normalizeLuma(code: code, bitDepth: 10)!
      XCTAssertEqual(DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .native), code / 1023, accuracy: 1e-12)
      XCTAssertEqual(DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .fullRescaledToLegal),
                     NativeLogCodeMapping.fullRescaledToLegal10Bit.nativeNormalized(transportCode: code)!, accuracy: 1e-12)
      let full = code / 1023
      XCTAssertEqual(DecodeReference.nativeLog(expanded: full, range: .full, transport: .native), full)
      XCTAssertEqual(DecodeReference.nativeLog(expanded: full, range: .full, transport: .fullRescaledToLegal),
                     NativeLogCodeMapping.fullRescaledToLegal10Bit.nativeNormalized(transportCode: code)!, accuracy: 1e-12)
    }
  }

  func testLogCurvesInvertTheirEncodes() throws {
    // S-Log3 18% grey is code 420; LogC3 EI800 18% grey is 0.391007; LogC4 18% grey is 0.278396.
    XCTAssertEqual(try XCTUnwrap(LogCurve.sLog3.decode(420.0 / 1023)), 0.18, accuracy: 1e-12)
    XCTAssertEqual(try XCTUnwrap(LogCurve.arriLogC3.decode(0.391007)), 0.18, accuracy: 1e-5)
    XCTAssertEqual(try XCTUnwrap(LogCurve.arriLogC4.decode(0.278396)), 0.18, accuracy: 1e-5)
    XCTAssertEqual(ColorMath.bt709Linear(0.0405), 0.009, accuracy: 1e-12)
    XCTAssertEqual(ColorMath.bt709Linear(0.409), 0.18, accuracy: 2e-4)
    XCTAssertEqual(ColorMath.bt709Linear(1), 1, accuracy: 1e-12)
  }
}

extension MonitorStateTests {
  /// State saved before display transforms and clip indicators existed (W1)
  /// decodes with their defaults and keeps everything else.
  func testStateSavedBeforeW2DecodesWithDefaults() throws {
    var old = Self.everythingChanged()
    old.displayTransform = DisplayTransformSettings()
    old.clipIndicators = ClipIndicatorSettings()
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(old)) as? [String: Any])
    json["displayTransform"] = nil
    json["clipIndicators"] = nil
    let decoded = try JSONDecoder().decode(MonitorState.self, from: try JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(decoded, old)
    XCTAssertEqual(decoded.displayTransform.mode, DisplayTransform.none)
    XCTAssertFalse(decoded.clipIndicators.enabled)
    // Malformed new values fall back without losing the rest.
    json["displayTransform"] = ["mode": "sideways", "pqSourcePeak": "high"]
    json["clipIndicators"] = ["enabled": true, "high": "x", "coloring": 3]
    let lenient = try JSONDecoder().decode(MonitorState.self, from: try JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(lenient.displayTransform, DisplayTransformSettings())
    XCTAssertTrue(lenient.clipIndicators.enabled)
    XCTAssertEqual(lenient.clipIndicators.coloring, ClipIndicatorColoring.perChannel)
    XCTAssertEqual(lenient.clipIndicators.high, 100)
    XCTAssertEqual(lenient.zebras, old.zebras)
  }

  func testNewSettingsNormalize() {
    var s = MonitorState()
    s.displayTransform.pqSourcePeak = .nan
    s.clipIndicators.high = 500
    s.clipIndicators.low = -.infinity
    s.clipIndicators.opacity = 2
    s.clipIndicators.overColor = ColorRGB(r: .nan, g: 0, b: 0)
    let n = s.normalized()
    XCTAssertEqual(n.displayTransform.pqSourcePeak, 1000)
    XCTAssertEqual(n.clipIndicators.high, 120)
    XCTAssertEqual(n.clipIndicators.low, 0)
    XCTAssertEqual(n.clipIndicators.opacity, 1)
    XCTAssertEqual(n.clipIndicators.overColor, ColorRGB(r: 1, g: 0, b: 0))
    s.displayTransform.pqSourcePeak = 50
    XCTAssertEqual(s.normalized().displayTransform.pqSourcePeak, 100)
  }

  /// 100% is inclusive (a 10-bit legal 940 is flagged, 939 is not); 0% is inclusive
  /// below (64 is flagged, 65 is not). Per-channel colours add.
  func testClipIndicatorBoundariesAndColours() {
    var c = ClipIndicatorSettings()
    c.enabled = true
    func v(_ code: Double) -> Double { (code - 64) / 876 }
    func flag(_ r: Double, _ g: Double, _ b: Double) -> ColorRGB? {
      c.indicator(rgb: ColorRGB(r: r, g: g, b: b), luma: 0.2126 * r + 0.7152 * g + 0.0722 * b)
    }
    XCTAssertEqual(v(940), 1)
    XCTAssertEqual(flag(v(940), 0.5, 0.5), ColorRGB(r: 1, g: 0, b: 0))
    XCTAssertNil(flag(v(939), 0.5, 0.5))
    XCTAssertEqual(flag(v(940), v(940), 0.5), ColorRGB(r: 1, g: 1, b: 0))
    XCTAssertEqual(flag(v(940), v(940), v(940)), ColorRGB(r: 1, g: 1, b: 1))
    XCTAssertEqual(flag(0.5, v(64), 0.5), ColorRGB(r: 0, g: 0.5, b: 0))
    XCTAssertNil(flag(0.5, v(65), 0.5))
    XCTAssertEqual(flag(v(64), v(64), v(64)), ColorRGB(r: 0.5, g: 0.5, b: 0.5))
    // Over wins over under on the same pixel.
    XCTAssertEqual(flag(v(940), v(64), 0.5), ColorRGB(r: 1, g: 0, b: 0))
    // Luma alone.
    c.red = false
    c.green = false
    c.blue = false
    XCTAssertEqual(flag(1, 1, 1), ColorRGB(r: 1, g: 1, b: 1))
    XCTAssertNil(flag(1, 0, 0))
    c.coloring = .uniform
    XCTAssertEqual(flag(1, 1, 1), c.overColor)
    XCTAssertEqual(flag(0, 0, 0), c.underColor)
    c.showsUnder = false
    XCTAssertNil(flag(0, 0, 0))
    c.enabled = false
    XCTAssertNil(flag(1, 1, 1))
  }
}
