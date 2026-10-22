import XCTest

@testable import MonitorKitCore

final class LayoutTests: XCTestCase {
  func layout(_ pw: Int, _ ph: Int, _ vw: Int, _ vh: Int, par: Double = 1, _ configure: (inout ViewGeometry) -> Void = { _ in })
    -> MonitorLayout
  {
    var g = ViewGeometry()
    configure(&g)
    return MonitorLayout(pictureWidth: pw, pictureHeight: ph, pixelAspectRatio: par, viewportWidth: vw, viewportHeight: vh, geometry: g)
  }

  func testFitLetterboxesAndPillarboxesOnWholePixels() {
    let letter = layout(1920, 1080, 1000, 1000)
    XCTAssertEqual(letter.fitRect, MonitorRect(x: 0, y: 219, width: 1000, height: 562))
    XCTAssertEqual(letter.imageRect, letter.fitRect)
    XCTAssertFalse(letter.isMagnified)
    let pillar = layout(1080, 1920, 1000, 1000)
    XCTAssertEqual(pillar.fitRect.y, 0)
    XCTAssertEqual(pillar.fitRect.height, 1000)
    XCTAssertEqual(pillar.fitRect.x, pillar.fitRect.x.rounded())
    let exact = layout(3840, 2160, 1920, 1080)
    XCTAssertEqual(exact.fitRect, MonitorRect(x: 0, y: 0, width: 1920, height: 1080))
    XCTAssertEqual(exact.displayToPicture, AxisMap(scaleX: 2, scaleY: 2, offsetX: 0, offsetY: 0))
    XCTAssertEqual(exact.footprintX, 2)
    XCTAssertNil(exact.navigatorRect)
  }

  func testDesqueezeAndPixelAspectWidenThePicture() {
    let squeezed = layout(1920, 1080, 4000, 1080) { $0.desqueeze = 2 }
    XCTAssertEqual(squeezed.fitRect.width, 3840)
    XCTAssertEqual(squeezed.footprintX, 0.5)
    XCTAssertEqual(squeezed.footprintY, 1)
    let par = layout(1440, 1080, 4000, 1080, par: 4.0 / 3)
    XCTAssertEqual(par.fitRect.width, 1920)
    // Sony's "1.6x" is 1.65.
    let sony = layout(1000, 1000, 5000, 1000) { $0.desqueeze = 1.65 }
    XCTAssertEqual(sony.fitRect.width, 1650)
  }

  func testFlipsMapDisplayToMirroredPicture() {
    for flip in FlipMode.allCases {
      let l = layout(100, 50, 100, 50) { $0.flip = flip }
      let corner = l.displayToPicture.apply(x: 0.5, y: 0.5)
      XCTAssertEqual(corner.x, flip.flipsX ? 99.5 : 0.5)
      XCTAssertEqual(corner.y, flip.flipsY ? 49.5 : 0.5)
    }
  }

  func testZoomKeepsThePanPointCentredAndNeverShowsPastThePicture() {
    let centred = layout(1000, 500, 1000, 500) { $0.magnification.zoom = 2 }
    XCTAssertTrue(centred.isMagnified)
    XCTAssertEqual(centred.imageRect, MonitorRect(x: -500, y: -250, width: 2000, height: 1000))
    XCTAssertEqual(centred.visiblePictureRect, MonitorRect(x: 250, y: 125, width: 500, height: 250))
    let corner = layout(1000, 500, 1000, 500) {
      $0.magnification.zoom = 4
      $0.magnification.centerX = 0
      $0.magnification.centerY = 1
    }
    XCTAssertEqual(corner.imageRect.x, 0)
    XCTAssertEqual(corner.imageRect.maxY, 500)
    XCTAssertEqual(corner.visiblePictureRect, MonitorRect(x: 0, y: 375, width: 250, height: 125))
    // Flipped, the same picture point stays under the view centre.
    let flipped = layout(1000, 500, 1000, 500) {
      $0.magnification.zoom = 2
      $0.magnification.centerX = 0.3
      $0.flip = .horizontal
    }
    let centre = flipped.displayToPicture.apply(x: 500, y: 250)
    XCTAssertEqual(centre.x, 300, accuracy: 1e-9)
    XCTAssertEqual(flipped.visiblePictureRect.midX, 300, accuracy: 1e-9)
  }

  func testPixelExactShowsOnePictureRowPerDisplayRow() {
    // Larger than the view: magnified, whole-pixel origin, the pan clamps.
    let big = layout(3840, 2160, 1000, 600) {
      $0.magnification.pixelExact = true
      $0.magnification.centerX = 0.25
    }
    XCTAssertTrue(big.isMagnified)
    XCTAssertEqual(big.imageRect.width, 3840)
    XCTAssertEqual(big.imageRect.height, 2160)
    XCTAssertEqual(big.imageRect.x, big.imageRect.x.rounded())
    XCTAssertEqual(big.footprintX, 1)
    XCTAssertEqual(big.footprintY, 1)
    XCTAssertEqual(big.visiblePictureRect.midX, 960, accuracy: 1)
    XCTAssertNotNil(big.navigatorRect)
    // Smaller than the view: centred at 1:1, not magnified, so guides still show.
    let small = layout(640, 360, 1920, 1080) { $0.magnification.pixelExact = true }
    XCTAssertFalse(small.isMagnified)
    XCTAssertEqual(small.imageRect, MonitorRect(x: 640, y: 360, width: 640, height: 360))
    XCTAssertNil(small.navigatorRect)
    // De-squeezed: rows stay 1:1, columns carry the factor.
    let anamorphic = layout(1000, 1000, 500, 500) {
      $0.magnification.pixelExact = true
      $0.desqueeze = 2
    }
    XCTAssertEqual(anamorphic.imageRect.width, 2000)
    XCTAssertEqual(anamorphic.footprintY, 1)
  }

  func testNavigatorSitsBottomRightAndMapsTheWholePicture() throws {
    let l = layout(1920, 1080, 1920, 1080) { $0.magnification.zoom = 3 }
    let nav = try XCTUnwrap(l.navigatorRect)
    XCTAssertEqual(nav.width, (0.22 * 1920).rounded())
    XCTAssertEqual(nav.width / nav.height, 16.0 / 9, accuracy: 0.01)
    let margin = (0.02 * 1080).rounded()
    XCTAssertEqual(nav.maxX, 1920 - margin)
    XCTAssertEqual(nav.maxY, 1080 - margin)
    let a = l.navigatorToPicture.apply(x: nav.x, y: nav.y), b = l.navigatorToPicture.apply(x: nav.maxX, y: nav.maxY)
    XCTAssertEqual(a.x, 0, accuracy: 1e-9)
    XCTAssertEqual(b.x, 1920, accuracy: 1e-9)
    XCTAssertEqual(b.y, 1080, accuracy: 1e-9)
    // A tall picture's navigator is limited to 30% of the height.
    let tall = try XCTUnwrap(layout(1080, 1920, 1920, 1080) { $0.magnification.zoom = 2 }.navigatorRect)
    XCTAssertLessThanOrEqual(tall.height, (0.3 * 1080).rounded())
    let hidden = layout(1920, 1080, 1920, 1080) {
      $0.magnification.zoom = 3
      $0.magnification.showsNavigator = false
    }
    XCTAssertNil(hidden.navigatorRect)
  }

  func testDegenerateInputsStayFinite() {
    let l = layout(0, 0, 0, 0, par: .nan) {
      $0.desqueeze = .nan
      $0.magnification.zoom = .infinity
      $0.magnification.centerX = .nan
    }
    for v in [l.fitRect.x, l.fitRect.width, l.imageRect.x, l.displayToPicture.scaleX, l.displayToPicture.offsetY] {
      XCTAssertTrue(v.isFinite)
    }
  }
}

final class GuideRasterTests: XCTestCase {
  func layout(_ w: Int = 960, _ h: Int = 540, zoom: Double = 1) -> MonitorLayout {
    var g = ViewGeometry()
    g.magnification.zoom = zoom
    return MonitorLayout(pictureWidth: w, pictureHeight: h, viewportWidth: w, viewportHeight: h, geometry: g)
  }

  func settings(_ configure: (inout GuideSettings) -> Void) -> GuideSettings {
    var g = GuideSettings()
    g.enabled = true
    g.thirds = false
    configure(&g)
    return g
  }

  func testOddStrokesCentreOnPixelsAndEvenStrokesOnEdges() {
    let thirds = settings { $0.thirds = true }
    let one = GuideRaster(layout: layout(), guides: thirds, pixelsPerPoint: 1)
    XCTAssertEqual(one.strokeWidth, 1)
    XCTAssertEqual(Set(one.segments.filter { $0.x0 == $0.x1 }.map(\.x0)), [320.5, 640.5])
    XCTAssertEqual(Set(one.segments.filter { $0.y0 == $0.y1 }.map(\.y0)), [180.5, 360.5])
    let two = GuideRaster(layout: layout(), guides: thirds, pixelsPerPoint: 2)
    XCTAssertEqual(two.strokeWidth, 2)
    XCTAssertEqual(Set(two.segments.filter { $0.x0 == $0.x1 }.map(\.x0)), [320, 640])
    XCTAssertTrue(two.segments.allSatisfy { $0.halfWidth == 1 })
    let three = GuideRaster(layout: layout(), guides: settings { $0.thirds = true; $0.lineWidth = 1.5 }, pixelsPerPoint: 2)
    XCTAssertEqual(three.strokeWidth, 3)
    XCTAssertEqual(Set(three.segments.filter { $0.x0 == $0.x1 }.map(\.x0)), [320.5, 640.5])
    // Every endpoint of an axis-aligned stroke lies on a pixel edge.
    for s in one.segments where s.x0 == s.x1 { XCTAssertEqual(s.y0, s.y0.rounded()); XCTAssertEqual(s.y1, s.y1.rounded()) }
  }

  func testOutlinesStayInsideTheirRectAndCloseTheCorners() {
    let r = GuideRaster(layout: layout(), guides: settings { $0.safeAreas = [100] }, pixelsPerPoint: 1)
    XCTAssertEqual(r.segments.count, 4)
    let verticals = r.segments.filter { $0.x0 == $0.x1 }
    XCTAssertEqual(Set(verticals.map(\.x0)), [0.5, 959.5])
    XCTAssertTrue(verticals.allSatisfy { $0.y0 == 0 && $0.y1 == 540 })
    let horizontals = r.segments.filter { $0.y0 == $0.y1 }
    XCTAssertEqual(Set(horizontals.map(\.y0)), [0.5, 539.5])
  }

  func testFrameGuideMatteAndFollowing() throws {
    let r = GuideRaster(
      layout: layout(), guides: settings {
        $0.frameGuides = [FrameGuide(aspect: 2.4, style: .linesAndMatte, matteOpacity: 0.5)]
        $0.thirds = true
      }, pixelsPerPoint: 1)
    let matte = try XCTUnwrap(r.matteRect)
    XCTAssertEqual(matte, MonitorRect(x: 0, y: 70, width: 960, height: 400))
    XCTAssertEqual(r.matteOpacity, 0.5)
    // Thirds follow the frame guide: the horizontal thirds of 70..<470.
    XCTAssertTrue(r.segments.contains { $0.y0 == $0.y1 && $0.y0 == (70 + 400.0 / 3).rounded(.down) + 0.5 })
    let free = GuideRaster(
      layout: layout(), guides: settings {
        $0.frameGuides = [FrameGuide(aspect: 2.4, style: .matte)]
        $0.thirds = true
        $0.followsFrameGuide = false
      }, pixelsPerPoint: 1)
    XCTAssertTrue(free.segments.contains { $0.y0 == $0.y1 && $0.y0 == 180.5 })
    XCTAssertEqual(free.segments.count, 4, "a matte-only guide draws no outline")
  }

  func testGridCrossDotAndDiagonals() {
    let r = GuideRaster(
      layout: layout(), guides: settings {
        $0.squareGrid = true
        $0.squareGridRows = 4
        $0.centerCross = true
        $0.centerDot = true
        $0.diagonals = true
      }, pixelsPerPoint: 1)
    // Square cells of 135 px: rows at 135, 270, 405; columns symmetric about the centre.
    let rows = Set(r.segments.filter { $0.y0 == $0.y1 && $0.x1 - $0.x0 == 960 }.map(\.y0))
    XCTAssertEqual(rows, [135.5, 270.5, 405.5])
    let columns = r.segments.filter { $0.x0 == $0.x1 && $0.y1 - $0.y0 == 540 }.map(\.x0).sorted()
    XCTAssertEqual(columns.first! + columns.last!, 960 + 1, "symmetric about the centre column")
    XCTAssertTrue(r.segments.contains { $0.x0 == 0 && $0.y0 == 0 && $0.x1 == 960 && $0.y1 == 540 })
    let dot = r.segments.first { $0.x0 == $0.x1 && $0.y0 == $0.y1 }
    XCTAssertEqual(dot?.x0, 480.5)
    XCTAssertEqual(dot?.halfWidth, 2)
    // Cross arms end on pixel edges: 22 pixels either side of the centre pixel.
    let arm = r.segments.first { $0.y0 == $0.y1 && $0.y0 == 270.5 && $0.x1 - $0.x0 < 100 }
    XCTAssertEqual(arm?.x0, 480.5 - 22 - 0.5)
    XCTAssertEqual(arm?.x1, 480.5 + 22 + 0.5)
  }

  func testDisabledHiddenAndCapped() {
    XCTAssertEqual(GuideRaster(layout: layout(), guides: GuideSettings()).segments.count, 0)
    XCTAssertEqual(GuideRaster(layout: layout(zoom: 2), guides: settings { $0.thirds = true }).segments.count, 0)
    let many = GuideRaster(
      layout: layout(), guides: settings {
        $0.squareGrid = true
        $0.squareGridRows = 16
        $0.safeAreas = [80, 85, 90, 95]
        $0.frameGuides = (0..<4).map { FrameGuide(aspect: 1 + Double($0) * 0.3) }
        $0.thirds = true
      }.normalizedGuides, pixelsPerPoint: 0.5)
    XCTAssertLessThanOrEqual(many.segments.count, GuideRaster.maximumSegments)
  }
}

extension GuideSettings {
  var normalizedGuides: GuideSettings {
    var s = MonitorState()
    s.guides = self
    return s.normalized().guides
  }
}
