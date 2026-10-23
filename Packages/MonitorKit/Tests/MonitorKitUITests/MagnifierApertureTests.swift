import CoreGraphics
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitUI

/// Gestures on a picture with a clean aperture: `MonitorLayout` maps display
/// points to frame pixels inside the aperture, and the magnification centre is a
/// fraction of the aperture, so the magnifier must convert through
/// `pictureFraction`, not divide by the aperture's size.
final class MagnifierApertureTests: XCTestCase {
  /// A 1920x1080 frame in a 960x540 viewport with these apertures: a 4:3 centre
  /// cut, a letterbox (y offset) and an asymmetric one (both offsets, off centre).
  static let apertures = [
    MonitorRect(x: 240, y: 0, width: 1440, height: 1080),
    MonitorRect(x: 0, y: 140, width: 1920, height: 800),
    MonitorRect(x: 100, y: 60, width: 1200, height: 900),
  ]

  func layout(_ m: Magnification, flip: FlipMode, aperture: MonitorRect) -> MonitorLayout {
    var g = ViewGeometry()
    g.magnification = m
    g.flip = flip
    return MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 960, viewportHeight: 540, geometry: g,
      cleanAperture: aperture)
  }

  /// The frame pixel shown at the viewport centre.
  func shownCentre(_ l: MonitorLayout) -> (x: Double, y: Double) {
    l.displayToPicture.apply(x: l.viewportWidth / 2, y: l.viewportHeight / 2)
  }

  /// Regression: a double-click at the centre of the shown picture opened 1:1 off
  /// centre (frame x 960 over an aperture width of 1440 is 0.667, not 0.5).
  func testPixelExactAtThePictureCentreIsCentred() {
    for aperture in Self.apertures {
      for flip in FlipMode.allCases {
        let l = layout(Magnification(), flip: flip, aperture: aperture)
        let fit = l.fitRect
        let exact = MonitorMagnifier.togglePixelExact(Magnification(), at: (fit.midX, fit.midY), layout: l)
        XCTAssertTrue(exact.pixelExact)
        XCTAssertEqual(exact.centerX, 0.5, accuracy: 1e-6, "\(aperture) \(flip)")
        XCTAssertEqual(exact.centerY, 0.5, accuracy: 1e-6, "\(aperture) \(flip)")
        let shown = shownCentre(layout(exact, flip: flip, aperture: aperture))
        XCTAssertEqual(shown.x, aperture.midX, accuracy: 1, "\(aperture) \(flip)")
        XCTAssertEqual(shown.y, aperture.midY, accuracy: 1, "\(aperture) \(flip)")
      }
    }
  }

  /// Off centre (inside what the edges let pixel-exact centre on), the clicked
  /// frame pixel lands at the viewport centre.
  func testPixelExactCentresOnTheClickedPixel() {
    for aperture in Self.apertures {
      for flip in FlipMode.allCases {
        let l = layout(Magnification(), flip: flip, aperture: aperture)
        let fit = l.fitRect
        let click = (x: fit.x + 0.45 * fit.width, y: fit.y + 0.55 * fit.height)
        let target = l.displayToPicture.apply(x: click.x, y: click.y)
        XCTAssertTrue(aperture.contains(x: target.x, y: target.y), "\(aperture) \(flip)")
        let exact = MonitorMagnifier.togglePixelExact(Magnification(), at: click, layout: l)
        let f = MonitorMagnifier.pictureFraction(at: click, layout: l)
        XCTAssertEqual(exact.centerX, f.x)
        XCTAssertEqual(exact.centerY, f.y)
        let back = l.picturePoint(fractionX: f.x, fractionY: f.y)
        XCTAssertEqual(back.x, target.x, accuracy: 1e-6, "pictureFraction inverts to the clicked pixel")
        XCTAssertEqual(back.y, target.y, accuracy: 1e-6)
        let shown = shownCentre(layout(exact, flip: flip, aperture: aperture))
        XCTAssertEqual(shown.x, target.x, accuracy: 1, "\(aperture) \(flip)")
        XCTAssertEqual(shown.y, target.y, accuracy: 1, "\(aperture) \(flip)")
      }
    }
  }

  /// Points outside the picture clamp to its edges.
  func testPictureFractionClampsToTheAperture() {
    let l = layout(Magnification(), flip: .none, aperture: Self.apertures[2])
    let low = MonitorMagnifier.pictureFraction(at: (-100, -100), layout: l)
    let high = MonitorMagnifier.pictureFraction(at: (10_000, 10_000), layout: l)
    XCTAssertEqual(low.x, 0)
    XCTAssertEqual(low.y, 0)
    XCTAssertEqual(high.x, 1)
    XCTAssertEqual(high.y, 1)
  }

  /// Regression: a navigator click recentred on the frame-pixel point divided by
  /// the aperture's size, so the view moved to the wrong place.
  func testNavigatorClickRecentresInTheAperture() throws {
    for aperture in Self.apertures {
      for flip in FlipMode.allCases {
        var m = Magnification()
        m.zoom = 4
        m.centerX = 0.1
        m.centerY = 0.9
        let l = layout(m, flip: flip, aperture: aperture)
        let nav = try XCTUnwrap(l.navigatorRect)
        let middle = try XCTUnwrap(MonitorMagnifier.recenter(m, navigatorPoint: (nav.midX, nav.midY), layout: l))
        XCTAssertEqual(middle.centerX, 0.5, accuracy: 1e-6, "\(aperture) \(flip)")
        XCTAssertEqual(middle.centerY, 0.5, accuracy: 1e-6, "\(aperture) \(flip)")

        let point = (x: nav.x + 0.3 * nav.width, y: nav.y + 0.6 * nav.height)
        let target = l.navigatorToPicture.apply(x: point.x, y: point.y)
        XCTAssertTrue(aperture.contains(x: target.x, y: target.y), "\(aperture) \(flip)")
        let c = try XCTUnwrap(MonitorMagnifier.recenter(m, navigatorPoint: point, layout: l))
        let shown = shownCentre(layout(c, flip: flip, aperture: aperture))
        XCTAssertEqual(shown.x, target.x, accuracy: 1, "\(aperture) \(flip)")
        XCTAssertEqual(shown.y, target.y, accuracy: 1, "\(aperture) \(flip)")
      }
    }
  }

  /// The view maps a gesture through the layout the pass draws: the frame's clean
  /// aperture and usable pixel aspect ratio, and the normalized geometry. A
  /// double-click at the viewport centre of an apertured frame centres 1:1.
  @MainActor
  func testViewGesturesUseThePassLayout() throws {
    let gpu = try requireGPU()
    var frame = try gpu.sdrFrame(width: 64, height: 36)
    frame.cleanAperture = MonitorRect(x: 16, y: 4, width: 40, height: 30)
    let source = MonitorSource()
    source.submit(frame)
    var state = MonitorState()
    state.geometry.magnification.zoom = 1000  // normalized to the zoom range
    let surface = MonitorSurface(source: source, state: state)
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [surface]), mode: .convenience(queue: gpu.queue))
    view.metalLayer.drawableSize = CGSize(width: 320, height: 180)
    let base = try XCTUnwrap(view.gestureBase(surface))
    let viewport = MonitorViewport(width: 320, height: 180)
    let expected = MonitorLayout(frame: frame, state: state, viewport: viewport)
    XCTAssertEqual(base.layout(state), expected)
    XCTAssertEqual(base.layout(state).aperture, MonitorRect(x: 16, y: 4, width: 40, height: 30))

    // The pass draws with the same layout.
    view.headroomOverride = 1
    let target = gpu.texture(.bgra8Unorm, 320, 180)
    try gpu.run { view.drawOffscreen(into: target, commandBuffer: $0) }
    XCTAssertEqual(surface.layout, expected, "the published layout")

    surface.updateState { $0.geometry.magnification = Magnification() }
    view.edit(surface) { m, layout in
      MonitorMagnifier.togglePixelExact(m, at: (layout.fitRect.midX, layout.fitRect.midY), layout: layout)
    }
    let m = surface.state.geometry.magnification
    XCTAssertTrue(m.pixelExact)
    XCTAssertEqual(m.centerX, 0.5, accuracy: 1e-6)
    XCTAssertEqual(m.centerY, 0.5, accuracy: 1e-6)
  }
}

extension MonitorRect {
  fileprivate func contains(x px: Double, y py: Double) -> Bool { px >= x && px <= maxX && py >= y && py <= maxY }
}
