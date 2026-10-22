import Foundation
import XCTest

@testable import MonitorKitCore

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
    let fixtures: [(Double, ColorRGB)] = [
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
    for gamut in [ColorGamut.sGamut3Cine, .sGamut3] {
      let gray = ColorRGB(r: 420.0 / 1023, g: 420.0 / 1023, b: 420.0 / 1023)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: gray, gamut: gamut), ColorRGB(r: 0.533, g: 0.537, b: 0.506))
      XCTAssertEqual(
        ELZoneProfile.color(rgb: gray, gamut: gamut, referenceOffsetStops: 1),
        ColorRGB(r: 1, g: 0.992, b: 0.463))
      XCTAssertEqual(
        ELZoneProfile.color(rgb: gray, gamut: gamut, referenceOffsetStops: -1),
        ColorRGB(r: 0.192, g: 0.878, b: 0.141))
      let plusOne = ColorRGB(r: 0.4845461233571402, g: 0.4845461233571402, b: 0.4845461233571402)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: plusOne, gamut: gamut), ColorRGB(r: 1, g: 0.992, b: 0.463))
      let minusOne = ColorRGB(r: 0.33930198763522507, g: 0.33930198763522507, b: 0.33930198763522507)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: minusOne, gamut: gamut), ColorRGB(r: 0.192, g: 0.878, b: 0.141))
    }
  }

  func testSaturatedChannelsDecodeBeforeSourceGamutLuminance() {
    // Linear red=.65, green=blue=0; Cine exposure=-.36464, S-Gamut3=-.03130.
    let red = ColorRGB(r: 0.5487944012659178, g: 95.0 / 1023, b: 95.0 / 1023)
    XCTAssertEqual(ELZoneProfile.color(rgb: red, gamut: .sGamut3Cine), ColorRGB(r: 0, g: 1, b: 0))
    XCTAssertEqual(
      ELZoneProfile.color(rgb: red, gamut: .sGamut3), ColorRGB(r: 0.533, g: 0.537, b: 0.506))
    // Linear blue=.8: both gamuts' blue Y weights are negative (Cine -.1001,
    // S-Gamut3 -.0576), so Y is nonpositive and the zone is black.
    let blue = ColorRGB(r: 95.0 / 1023, g: 95.0 / 1023, b: 0.5715295853251243)
    XCTAssertEqual(ELZoneProfile.color(rgb: blue, gamut: .sGamut3Cine), ColorRGB(r: 0, g: 0, b: 0))
    XCTAssertEqual(ELZoneProfile.color(rgb: blue, gamut: .sGamut3), ColorRGB(r: 0, g: 0, b: 0))
  }

  func testNonpositiveFiniteLuminanceIsBlackDespitePositiveOffset() {
    for value in [-0.5, 0, 95.0 / 1023] {
      let rgb = ColorRGB(r: value, g: value, b: value)
      XCTAssertEqual(
        ELZoneProfile.color(rgb: rgb, gamut: .sGamut3Cine, referenceOffsetStops: 10),
        ColorRGB(r: 0, g: 0, b: 0))
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
    for gamut in [ColorGamut.rec709, .rec2020] {
      XCTAssertNil(ELZoneProfile.color(rgb: .init(r: 0.4, g: 0.4, b: 0.4), gamut: gamut))
    }
    XCTAssertNil(ELZoneProfile.gamut(forSourceProfileID: nil))
    XCTAssertNil(ELZoneProfile.gamut(forSourceProfileID: "arri-logc3-ei800"))
    XCTAssertFalse(ELZoneProfile.supports(sourceProfileID: "unknown"))
    XCTAssertEqual(ELZoneProfile.gamut(forSourceProfileID: "sony-slog3-sgamut3cine"), .sGamut3Cine)
    XCTAssertEqual(ELZoneProfile.gamut(forSourceProfileID: "sony-slog3-sgamut3"), .sGamut3)
  }
}
