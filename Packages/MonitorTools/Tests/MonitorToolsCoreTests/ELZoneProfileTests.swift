import Foundation
import XCTest

@testable import MonitorToolsCore

final class ELZoneProfileTests: XCTestCase {
  func testAllInteriorTransitionsAndExtremaOwnTheirSpecifiedEdges() {
    let transitions = [-6.0, -4.5, -3.5, -2.5, -1.5, -0.75, -0.25, 0.25, 0.75, 1.5, 2.5, 3.5, 4.5, 6]
    for (index, boundary) in transitions.enumerated() {
      XCTAssertEqual(ELZoneProfile.zoneIndex(stops: boundary - 1e-8), index)
      XCTAssertEqual(ELZoneProfile.zoneIndex(stops: boundary + 1e-8), index + 1)
      XCTAssertEqual(ELZoneProfile.zoneIndex(stops: boundary), boundary == -6 ? 0 : index + 1)
    }
    XCTAssertEqual(ELZoneProfile.zoneIndex(stops: -100), 0)
    XCTAssertEqual(ELZoneProfile.zoneIndex(stops: 100), 14)
    XCTAssertEqual(ELZoneProfile.zoneIndex(stops: -0.25), 7)
    XCTAssertEqual(ELZoneProfile.zoneIndex(stops: 0.25), 8)
  }

  func testPublishedChartAnchorsRetainTheirNumericalRGB() {
    let fixtures: [(Double, MonitorRGB)] = [
      (-6, .init(r: 0, g: 0, b: 0)), (-5, .init(r: 0.439, g: 0.188, b: 0.627)),
      (-4, .init(r: 0, g: 0.439, b: 0.753)), (-3, .init(r: 0, g: 0.69, b: 0.941)),
      (-2, .init(r: 0.0824, g: 0.651, b: 0.0549)), (-1, .init(r: 0.192, g: 0.878, b: 0.141)),
      (-0.5, .init(r: 0, g: 1, b: 0)), (0, .init(r: 0.533, g: 0.537, b: 0.506)),
      (0.5, .init(r: 0.973, g: 0.949, b: 0)), (1, .init(r: 1, g: 0.992, b: 0.463)),
      (2, .init(r: 1, g: 0.565, b: 0)), (3, .init(r: 1, g: 0.694, b: 0.357)),
      (4, .init(r: 1, g: 0, b: 0)), (5, .init(r: 1, g: 0.412, b: 0.412)),
      (6, .init(r: 1, g: 1, b: 1)),
    ]
    for (index, fixture) in fixtures.enumerated() {
      XCTAssertEqual(ELZoneProfile.zoneIndex(stops: fixture.0), index)
      XCTAssertEqual(ELZoneProfile.color(stops: fixture.0), fixture.1)
    }
  }

  func testNativeSonyNeutralAnchorsAndAdditiveOffset() {
    for gamut in [MonitorRGBGamut.sGamut3Cine, .sGamut3] {
      let gray = MonitorRGB(r: 420.0 / 1023, g: 420.0 / 1023, b: 420.0 / 1023)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: gray, gamut: gamut), MonitorRGB(r: 0.533, g: 0.537, b: 0.506))
      XCTAssertEqual(
        ELZoneProfile.color(rgb: gray, gamut: gamut, referenceOffsetStops: 1),
        MonitorRGB(r: 1, g: 0.992, b: 0.463))
      XCTAssertEqual(
        ELZoneProfile.color(rgb: gray, gamut: gamut, referenceOffsetStops: -1),
        MonitorRGB(r: 0.192, g: 0.878, b: 0.141))
      let plusOne = MonitorRGB(r: 0.4845461233571402, g: 0.4845461233571402, b: 0.4845461233571402)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: plusOne, gamut: gamut), MonitorRGB(r: 1, g: 0.992, b: 0.463))
      let minusOne = MonitorRGB(r: 0.33930198763522507, g: 0.33930198763522507, b: 0.33930198763522507)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: minusOne, gamut: gamut), MonitorRGB(r: 0.192, g: 0.878, b: 0.141))
    }
  }

  func testSaturatedChannelsDecodeBeforeSourceGamutLuminance() {
    // Linear red=.65, green=blue=0; Cine exposure=-.36464, S-Gamut3=-.03130.
    let red = MonitorRGB(r: 0.5487944012659178, g: 95.0 / 1023, b: 95.0 / 1023)
    XCTAssertEqual(ELZoneProfile.color(rgb: red, gamut: .sGamut3Cine), MonitorRGB(r: 0, g: 1, b: 0))
    XCTAssertEqual(
      ELZoneProfile.color(rgb: red, gamut: .sGamut3), MonitorRGB(r: 0.533, g: 0.537, b: 0.506))
    // Both gamuts give saturated blue a negative Y, so it reads black.
    let blue = MonitorRGB(r: 95.0 / 1023, g: 95.0 / 1023, b: 0.5715295853251243)
    XCTAssertEqual(ELZoneProfile.color(rgb: blue, gamut: .sGamut3Cine), MonitorRGB(r: 0, g: 0, b: 0))
    XCTAssertEqual(ELZoneProfile.color(rgb: blue, gamut: .sGamut3), MonitorRGB(r: 0, g: 0, b: 0))
  }

  func testNonpositiveFiniteLuminanceIsBlackDespitePositiveOffset() {
    for value in [-0.5, 0, 95.0 / 1023] {
      let rgb = MonitorRGB(r: value, g: value, b: value)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: rgb, gamut: .sGamut3Cine, referenceOffsetStops: 10),
        MonitorRGB(r: 0, g: 0, b: 0))
    }
  }

  func testUnsupportedGamutsAndNonfiniteInputsAreUnavailable() {
    for value in [Double.nan, .infinity, -.infinity] {
      XCTAssertNil(ELZoneProfile.zoneIndex(stops: value))
      XCTAssertNil(ELZoneProfile.color(stops: value))
      XCTAssertNil(ELZoneProfile.color(rgb: .init(r: value, g: 0.4, b: 0.4), gamut: .sGamut3Cine))
      XCTAssertNil(ELZoneProfile.color(
        rgb: .init(r: 0.4, g: 0.4, b: 0.4), gamut: .sGamut3Cine, referenceOffsetStops: value))
    }
    XCTAssertNil(ELZoneProfile.color(
      rgb: .init(r: .greatestFiniteMagnitude, g: 0.4, b: 0.4), gamut: .sGamut3Cine))
    for gamut in [MonitorRGBGamut.rec709, .rec2020] {
      XCTAssertNil(ELZoneProfile.color(rgb: .init(r: 0.4, g: 0.4, b: 0.4), gamut: gamut))
    }
    XCTAssertNil(ELZoneProfile.gamut(forSourceProfileID: nil))
    XCTAssertNil(ELZoneProfile.gamut(forSourceProfileID: "arri-logc3-ei800"))
    XCTAssertFalse(ELZoneProfile.supports(sourceProfileID: "unknown"))
    XCTAssertEqual(ELZoneProfile.gamut(forSourceProfileID: "sony-slog3-sgamut3cine"), .sGamut3Cine)
    XCTAssertEqual(ELZoneProfile.gamut(forSourceProfileID: "sony-slog3-sgamut3"), .sGamut3)
  }

  func testPreviousPublicChartIdentityMigratesAndNormalizationIsIdempotent() {
    var config = MonitorConfiguration()
    config.sourceProfileID = "sony-slog3-sgamut3cine"
    config.falseColor.mode = .elZone
    config.falseColor.profileID = "elzone-panasonic-varicam-fw9-public-chart"
    config.falseColor.specificationVersion = "old"
    config.falseColor.exposureIndex = 1600
    config.falseColor.referenceOffsetStops = -0.75
    let normalized = config.normalized()
    XCTAssertEqual(normalized.falseColor.mode, .elZone)
    XCTAssertEqual(normalized.falseColor.profileID, "ultracam-elzone-public-chart-v1")
    XCTAssertEqual(normalized.falseColor.exposureIndex, 1600)
    XCTAssertEqual(normalized.falseColor.referenceOffsetStops, -0.75)
    XCTAssertEqual(normalized.normalized(), normalized)
  }

  func testLegacyELZoneConfigurationQualifiesPublicChartProfile() throws {
    for source in ["sony-slog3-sgamut3cine", "sony-slog3-sgamut3"] {
      let json = """
        {"sourceProfileID":"\(source)","falseColor":{"mode":"elZone",
         "exposureIndex":12800,"referenceOffsetStops":1.25}}
        """
      let config = try JSONDecoder().decode(MonitorConfiguration.self, from: Data(json.utf8))
      XCTAssertEqual(config.falseColor.mode, .elZone)
      XCTAssertEqual(config.falseColor.profileID, "ultracam-elzone-public-chart-v1")
      XCTAssertEqual(config.falseColor.specificationVersion, "Ultracam-PanasonicFW9-Midpoints-v1")
      XCTAssertEqual(config.falseColor.exposureIndex, 12800)
      XCTAssertEqual(config.falseColor.referenceOffsetStops, 1.25)
      XCTAssertEqual(
        try JSONDecoder().decode(MonitorConfiguration.self, from: JSONEncoder().encode(config)), config)
    }
  }

  func testELZoneConfigurationRejectsUnknownSourceAndProfile() {
    for source in [nil, "slog3-sgamut3cine", "arri-logc3-ei800", "unknown"] as [String?] {
      var config = MonitorConfiguration()
      config.falseColor.mode = .elZone
      config.sourceProfileID = source
      XCTAssertEqual(config.normalized().falseColor.mode, .off)
    }
    var config = MonitorConfiguration()
    config.sourceProfileID = "sony-slog3-sgamut3cine"
    config.falseColor.mode = .elZone
    config.falseColor.profileID = "unknown"
    XCTAssertEqual(config.normalized().falseColor.mode, .off)
  }
}
