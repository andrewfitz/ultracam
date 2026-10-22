import MonitorKitCore
import XCTest

@testable import MonitorKitUI

/// Gesture mapping onto `MonitorState.geometry.magnification`, checked against
/// the layouts Core builds from the result.
final class MagnifierTests: XCTestCase {
  func layout(_ m: Magnification, flip: FlipMode = .none, desqueeze: Double = 1, par: Double = 1) -> MonitorLayout {
    var g = ViewGeometry()
    g.magnification = m
    g.flip = flip
    g.desqueeze = desqueeze
    return MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1080, pixelAspectRatio: par, viewportWidth: 960, viewportHeight: 540,
      geometry: g)
  }

  func picturePoint(_ l: MonitorLayout, _ p: (x: Double, y: Double)) -> (x: Double, y: Double) {
    l.displayToPicture.apply(x: p.x, y: p.y)
  }

  /// The picture point under the pointer stays under it, zooming in and out,
  /// for every flip and with de-squeeze and pixel aspect.
  func testZoomKeepsThePointUnderThePointer() {
    for flip in FlipMode.allCases {
      for (desqueeze, par) in [(1.0, 1.0), (1.5, 1.0), (1.0, 1.33)] {
        var m = Magnification()
        var l = layout(m, flip: flip, desqueeze: desqueeze, par: par)
        for (factor, point) in [(2.0, (300.0, 200.0)), (2.5, (600.0, 120.0)), (0.7, (480.0, 300.0))] {
          let before = picturePoint(l, point)
          m = MonitorMagnifier.zoom(m, by: factor, about: point, layout: l)
          l = layout(m, flip: flip, desqueeze: desqueeze, par: par)
          let after = picturePoint(l, point)
          XCTAssertEqual(after.x, before.x, accuracy: 1e-6, "\(flip) \(desqueeze) \(par) ×\(factor)")
          XCTAssertEqual(after.y, before.y, accuracy: 1e-6, "\(flip) \(desqueeze) \(par) ×\(factor)")
        }
      }
    }
  }

  func testZoomClampsToTheRangeAndRecentresAtFit() {
    let m0 = Magnification()
    let l0 = layout(m0)
    let big = MonitorMagnifier.zoom(m0, by: 1000, about: (10, 10), layout: l0)
    XCTAssertEqual(big.zoom, 64)
    let out = MonitorMagnifier.zoom(big, by: 0.0001, about: (10, 10), layout: layout(big))
    XCTAssertEqual(out.zoom, 1)
    XCTAssertEqual(out.centerX, 0.5)
    XCTAssertEqual(out.centerY, 0.5)
    XCTAssertEqual(MonitorMagnifier.zoom(m0, by: .nan, about: (0, 0), layout: l0), m0)
    XCTAssertEqual(MonitorMagnifier.zoom(m0, by: -2, about: (0, 0), layout: l0), m0)
  }

  /// Zooming out of pixel-exact continues from the zoom it showed.
  func testPixelExactBecomesItsZoom() {
    var m = Magnification()
    m.pixelExact = true
    let l = layout(m)
    XCTAssertEqual(MonitorMagnifier.effectiveZoom(l), 2, accuracy: 1e-9, "1920 pixels in a 960-pixel fit")
    let z = MonitorMagnifier.zoom(m, by: 1, about: (480, 270), layout: l)
    XCTAssertFalse(z.pixelExact)
    XCTAssertEqual(z.zoom, 2, accuracy: 1e-9)
    XCTAssertEqual(layout(z).imageRect.width, l.imageRect.width, accuracy: 1e-6)
  }

  /// The picture follows the drag, in display space whatever the flip.
  func testPanFollowsTheDrag() {
    for flip in FlipMode.allCases {
      var m = Magnification()
      m.zoom = 4
      let l = layout(m, flip: flip)
      let p = MonitorMagnifier.pan(m, by: (dx: 37, dy: -21), layout: l)
      let l2 = layout(p, flip: flip)
      XCTAssertEqual(l2.imageRect.x, l.imageRect.x + 37, accuracy: 1e-6, "\(flip)")
      XCTAssertEqual(l2.imageRect.y, l.imageRect.y - 21, accuracy: 1e-6, "\(flip)")
    }
  }

  /// At an edge the stored centre is the shown one: reversing moves at once.
  func testPanHasNoDeadTravelAtTheEdges() {
    var m = Magnification()
    m.zoom = 3
    let far = MonitorMagnifier.pan(m, by: (dx: 100_000, dy: 100_000), layout: layout(m))
    let l = layout(far)
    XCTAssertEqual(l.imageRect.x, 0, accuracy: 1e-9)
    XCTAssertEqual(l.imageRect.y, 0, accuracy: 1e-9)
    let back = MonitorMagnifier.pan(far, by: (dx: -10, dy: -5), layout: l)
    XCTAssertEqual(layout(back).imageRect.x, -10, accuracy: 1e-6)
    XCTAssertEqual(layout(back).imageRect.y, -5, accuracy: 1e-6)
    // Not magnified: nothing to pan.
    XCTAssertEqual(MonitorMagnifier.pan(Magnification(), by: (dx: 50, dy: 50), layout: layout(Magnification())), Magnification())
  }

  /// Double click: pixel-exact centred on the clicked picture point, and back.
  func testPixelExactCentresOnTheClick() {
    for flip in FlipMode.allCases {
      let m = Magnification()
      let l = layout(m, flip: flip)
      let click = (x: 600.0, y: 300.0)
      let target = picturePoint(l, click)
      let exact = MonitorMagnifier.togglePixelExact(m, at: click, layout: l)
      XCTAssertTrue(exact.pixelExact)
      let shown = picturePoint(layout(exact, flip: flip), (480, 270))
      XCTAssertEqual(shown.x, target.x, accuracy: 1, "\(flip)")
      XCTAssertEqual(shown.y, target.y, accuracy: 1, "\(flip)")
      let back = MonitorMagnifier.togglePixelExact(exact, at: click, layout: layout(exact, flip: flip))
      XCTAssertFalse(back.pixelExact)
    }
  }

  func testNavigatorClickRecentres() throws {
    var m = Magnification()
    m.zoom = 4
    m.centerX = 0.1
    let l = layout(m)
    let nav = try XCTUnwrap(l.navigatorRect)
    let c = try XCTUnwrap(MonitorMagnifier.recenter(m, navigatorPoint: (nav.midX, nav.midY), layout: l))
    XCTAssertEqual(c.centerX, 0.5, accuracy: 1e-6)
    XCTAssertEqual(c.centerY, 0.5, accuracy: 1e-6)
    let corner = try XCTUnwrap(MonitorMagnifier.recenter(m, navigatorPoint: (nav.x + 0.001, nav.y + 0.001), layout: l))
    XCTAssertEqual(corner.centerX, 0, accuracy: 1e-3)
    XCTAssertNil(MonitorMagnifier.recenter(m, navigatorPoint: (1, 1), layout: l))
    XCTAssertNil(MonitorMagnifier.recenter(Magnification(), navigatorPoint: (900, 500), layout: layout(Magnification())))
  }

  func testResetKeepsTheNavigatorChoice() {
    var m = Magnification()
    m.zoom = 8
    m.pixelExact = true
    m.showsNavigator = false
    let r = MonitorMagnifier.reset(m)
    XCTAssertEqual(r.zoom, 1)
    XCTAssertFalse(r.pixelExact)
    XCTAssertFalse(r.showsNavigator)
    XCTAssertEqual(r.centerX, 0.5)
  }

  /// Every result is already what `normalized()` keeps.
  func testResultsAreNormalized() {
    var state = MonitorState()
    var m = Magnification()
    m.zoom = 5
    let l = layout(m)
    for edited in [
      MonitorMagnifier.zoom(m, by: 3, about: (0, 0), layout: l),
      MonitorMagnifier.pan(m, by: (dx: -1e9, dy: 1e9), layout: l),
      MonitorMagnifier.togglePixelExact(m, at: (959, 539), layout: l),
    ] {
      state.geometry.magnification = edited
      XCTAssertEqual(state.normalized().geometry.magnification, edited)
    }
  }
}
