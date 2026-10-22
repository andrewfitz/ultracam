import Foundation
import XCTest

@testable import MonitorKitCore

/// Regressions for the gap-picture audit: the layout's two picture spaces with a
/// clean aperture, and a `MonitorState` embedded in a host's synthesized Codable.
final class GapPictureCoreTests: XCTestCase {
  // MARK: - Aperture fractions

  /// The finding's example: 1920×1080 with the aperture (200, 140, 1600, 800). The
  /// maps land in frame pixels, so the aperture centre is (1000, 540); dividing by
  /// `pictureWidth` gives (0.625, 0.675), `pictureFraction` gives (0.5, 0.5).
  func testMapsLandInFramePixelsAndFractionsAreOfTheAperture() {
    let aperture = MonitorRect(x: 200, y: 140, width: 1600, height: 800)
    let layout = MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 1600, viewportHeight: 800, geometry: ViewGeometry(),
      cleanAperture: aperture)
    XCTAssertEqual(layout.aperture, aperture)
    XCTAssertEqual(layout.pictureWidth, 1600)
    let p = layout.displayToPicture.apply(x: 800, y: 400)
    XCTAssertEqual(p.x, 1000, accuracy: 1e-9)
    XCTAssertEqual(p.y, 540, accuracy: 1e-9)
    XCTAssertEqual(p.x / layout.pictureWidth, 0.625, accuracy: 1e-9, "the wrong normalization")
    let f = layout.pictureFraction(x: p.x, y: p.y)
    XCTAssertEqual(f.x, 0.5, accuracy: 1e-12)
    XCTAssertEqual(f.y, 0.5, accuracy: 1e-12)
    let d = layout.pictureFraction(displayX: 0, displayY: 0)
    XCTAssertEqual(d.x, 0, accuracy: 1e-12)
    XCTAssertEqual(d.y, 0, accuracy: 1e-12)
    XCTAssertEqual(layout.visiblePictureRect, aperture, "the visible rect is in frame pixels")
    let back = layout.picturePoint(fractionX: 0.25, fractionY: 0.75)
    XCTAssertEqual(back.x, 600, accuracy: 1e-9)
    XCTAssertEqual(back.y, 740, accuracy: 1e-9)
  }

  /// With an offset aperture, magnification and every flip, the aperture fraction
  /// under the view's centre is the stored centre, and so is the navigator's
  /// visible-rect centre: what a magnifier stores round-trips.
  func testFractionsRoundTripTheMagnificationCentre() {
    let aperture = MonitorRect(x: 200, y: 140, width: 1600, height: 800)
    for flip in FlipMode.allCases {
      for (cx, cy) in [(0.3, 0.6), (0.5, 0.5), (0.7, 0.35)] {
        var g = ViewGeometry()
        g.flip = flip
        g.magnification.zoom = 4
        g.magnification.centerX = cx
        g.magnification.centerY = cy
        let layout = MonitorLayout(
          pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 960, viewportHeight: 480, geometry: g,
          cleanAperture: aperture)
        let c = layout.pictureFraction(displayX: 480, displayY: 240)
        XCTAssertEqual(c.x, cx, accuracy: 1e-9, "\(flip)")
        XCTAssertEqual(c.y, cy, accuracy: 1e-9, "\(flip)")
        let v = layout.visiblePictureRect
        XCTAssertGreaterThanOrEqual(v.x, aperture.x - 1e-9)
        XCTAssertLessThanOrEqual(v.maxX, aperture.maxX + 1e-9)
        let vc = layout.pictureFraction(x: v.midX, y: v.midY)
        XCTAssertEqual(vc.x, cx, accuracy: 1e-9)
        XCTAssertEqual(vc.y, cy, accuracy: 1e-9)
        // The navigator's centre is the aperture's centre.
        let nav = try! XCTUnwrap(layout.navigatorRect)
        let n = layout.navigatorToPicture.apply(x: nav.midX, y: nav.midY)
        let nf = layout.pictureFraction(x: n.x, y: n.y)
        XCTAssertEqual(nf.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(nf.y, 0.5, accuracy: 1e-9)
        // A new centre from a pixel-exact double-click at the view centre lands on itself.
        var exact = g
        exact.magnification.zoom = 1
        exact.magnification.pixelExact = true
        exact.magnification.centerX = c.x
        exact.magnification.centerY = c.y
        let e = MonitorLayout(
          pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 960, viewportHeight: 480, geometry: exact,
          cleanAperture: aperture)
        let ec = e.pictureFraction(displayX: 480, displayY: 240)
        XCTAssertEqual(ec.x, cx, accuracy: 1.0 / 1600, "\(flip): within a frame pixel")
        XCTAssertEqual(ec.y, cy, accuracy: 1.0 / 800)
      }
    }
  }

  /// Without an aperture the fraction is the old `p / pictureWidth`.
  func testFractionsWithoutApertureAreOfTheFrame() {
    let layout = MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 960, viewportHeight: 540, geometry: ViewGeometry())
    let p = layout.displayToPicture.apply(x: 123, y: 456)
    let f = layout.pictureFraction(x: p.x, y: p.y)
    XCTAssertEqual(f.x, p.x / layout.pictureWidth, accuracy: 1e-12)
    XCTAssertEqual(f.y, p.y / layout.pictureHeight, accuracy: 1e-12)
  }

  // MARK: - R13 embedded in synthesized Codable

  struct Preferences: Codable, Equatable {
    var name: String
    @LenientMonitorState var monitor = MonitorState()
  }

  struct Plain: Codable {
    var name: String
    var monitor: MonitorState?
  }

  static let v1 = #"{"schemaVersion":1,"zebra":{"enabled":true,"level":70},"falseColor":"sixBand"}"#

  func json(_ monitor: String?) -> Data {
    Data((monitor.map { #"{"name":"A cam","monitor":\#($0)}"# } ?? #"{"name":"A cam"}"#).utf8)
  }

  /// A plain optional field (`decodeIfPresent`) rethrows the fail-closed error and
  /// costs the host its other settings; the wrapped field decodes to the defaults.
  func testLenientFieldSurvivesForeignBlobsInASynthesizedType() throws {
    XCTAssertThrowsError(try JSONDecoder().decode(Plain.self, from: json(Self.v1)), "the problem the wrapper solves")
    for blob in [Self.v1, "null", "42", #""text""#, "[]", #"{"kind":"Other","schemaVersion":3}"#, nil] {
      let p = try JSONDecoder().decode(Preferences.self, from: json(blob))
      XCTAssertEqual(p.name, "A cam", blob ?? "missing")
      XCTAssertEqual(p.monitor, MonitorState(), blob ?? "missing")
    }
  }

  /// A genuine blob decodes as usual, and the wrapper encodes flat: the same JSON
  /// as a plain `MonitorState` field, so existing blobs and the wrapper interoperate.
  func testLenientFieldRoundTripsFlat() throws {
    var state = MonitorState()
    state.zebras[0].enabled = true
    state.zebras[0].level = 70
    state.pictureStage = .source
    let prefs = Preferences(name: "B", monitor: state)
    let data = try JSONEncoder().encode(prefs)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let monitor = try XCTUnwrap(object["monitor"] as? [String: Any])
    XCTAssertEqual(monitor["kind"] as? String, MonitorState.codingKind, "no wrapper object")
    XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), prefs)
    let plain = try JSONDecoder().decode(Plain.self, from: data)
    XCTAssertEqual(plain.monitor, state)
    let plainData = try JSONEncoder().encode(Plain(name: "B", monitor: state))
    XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: plainData), prefs)
    XCTAssertEqual(Preferences(name: "C").monitor, MonitorState(), "defaults by default")
  }

  /// The plain entry points: never throw, defaults for anything foreign.
  func testDecodingOrDefaultEntryPoints() throws {
    XCTAssertEqual(MonitorState.decodedOrDefault(from: Data(Self.v1.utf8)), MonitorState())
    XCTAssertEqual(MonitorState.decodedOrDefault(from: Data("not json".utf8)), MonitorState())
    var state = MonitorState()
    state.clean = true
    XCTAssertEqual(MonitorState.decodedOrDefault(from: try JSONEncoder().encode(state)), state)

    struct Host: Decodable {
      var monitor: MonitorState
      enum CodingKeys: CodingKey { case monitor }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitor = (try? c.superDecoder(forKey: .monitor)).map(MonitorState.init(decodingOrDefault:)) ?? MonitorState()
      }
    }
    XCTAssertEqual(try JSONDecoder().decode(Host.self, from: Data(#"{"monitor":\#(Self.v1)}"#.utf8)).monitor, MonitorState())
    let good = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    XCTAssertEqual(try JSONDecoder().decode(Host.self, from: Data(#"{"monitor":\#(good)}"#.utf8)).monitor, state)
  }
}
