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

  // MARK: - Clean aperture (R10)

  func aperture(_ crop: MonitorRect?, _ vw: Int, _ vh: Int, par: Double = 1, _ configure: (inout ViewGeometry) -> Void = { _ in })
    -> MonitorLayout
  {
    var g = ViewGeometry()
    configure(&g)
    return MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1088, pixelAspectRatio: par, viewportWidth: vw, viewportHeight: vh, geometry: g,
      cleanAperture: crop)
  }

  func testCleanApertureSetsTheAspectAndTheMap() {
    // H.264's 1920×1088 coded frame with a 1920×1080 picture at the top.
    let top = aperture(MonitorRect(x: 0, y: 0, width: 1920, height: 1080), 1920, 1080)
    XCTAssertEqual(top.fitRect, MonitorRect(x: 0, y: 0, width: 1920, height: 1080), "1:1, no letterbox for the 8 coded rows")
    XCTAssertEqual(top.displayToPicture, AxisMap(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0))
    XCTAssertEqual(top.pictureWidth, 1920)
    XCTAssertEqual(top.pictureHeight, 1080)
    XCTAssertEqual(top.aperture, MonitorRect(x: 0, y: 0, width: 1920, height: 1080))
    // An asymmetric aperture: viewport edges land on its edges, not the frame's.
    let crop = MonitorRect(x: 100, y: 40, width: 1600, height: 900)
    let l = aperture(crop, 800, 450)
    XCTAssertEqual(l.fitRect, MonitorRect(x: 0, y: 0, width: 800, height: 450))
    let a = l.displayToPicture.apply(x: 0, y: 0), b = l.displayToPicture.apply(x: 800, y: 450)
    XCTAssertEqual(a.x, 100)
    XCTAssertEqual(a.y, 40)
    XCTAssertEqual(b.x, 1700)
    XCTAssertEqual(b.y, 940)
    XCTAssertEqual(l.visiblePictureRect, crop)
    XCTAssertEqual(l.footprintX, 2)
    // Flipped, the crop's far edge comes first.
    let flipped = aperture(crop, 800, 450) { $0.flip = .rotate180 }
    let f0 = flipped.displayToPicture.apply(x: 0, y: 0), f1 = flipped.displayToPicture.apply(x: 800, y: 450)
    XCTAssertEqual(f0.x, 1700)
    XCTAssertEqual(f0.y, 940)
    XCTAssertEqual(f1.x, 100)
    XCTAssertEqual(f1.y, 40)
    XCTAssertEqual(flipped.visiblePictureRect, crop)
  }

  func testCleanApertureWithMagnificationAndPixelExact() {
    let crop = MonitorRect(x: 100, y: 40, width: 1600, height: 900)
    // Zoomed 2× about the aperture's centre: the visible region is its middle half.
    let zoomed = aperture(crop, 800, 450) { $0.magnification.zoom = 2 }
    XCTAssertTrue(zoomed.isMagnified)
    XCTAssertEqual(zoomed.visiblePictureRect, MonitorRect(x: 500, y: 265, width: 800, height: 450))
    // The navigator shows the whole aperture.
    let nav = try! XCTUnwrap(zoomed.navigatorRect)
    let n0 = zoomed.navigatorToPicture.apply(x: nav.x, y: nav.y), n1 = zoomed.navigatorToPicture.apply(x: nav.maxX, y: nav.maxY)
    XCTAssertEqual(n0.x, 100, accuracy: 1e-9)
    XCTAssertEqual(n0.y, 40, accuracy: 1e-9)
    XCTAssertEqual(n1.x, 1700, accuracy: 1e-9)
    XCTAssertEqual(n1.y, 940, accuracy: 1e-9)
    // Panned to the aperture's top-left corner: it stops at the aperture's edge.
    let corner = aperture(crop, 800, 450) {
      $0.magnification.zoom = 4
      $0.magnification.centerX = 0
      $0.magnification.centerY = 0
    }
    XCTAssertEqual(corner.visiblePictureRect.x, 100, accuracy: 1e-9)
    XCTAssertEqual(corner.visiblePictureRect.y, 40, accuracy: 1e-9)
    // Pixel exact: one aperture pixel per display pixel.
    let exact = aperture(crop, 1600, 900) { $0.magnification.pixelExact = true }
    XCTAssertEqual(exact.imageRect, MonitorRect(x: 0, y: 0, width: 1600, height: 900))
    XCTAssertFalse(exact.isMagnified)
    XCTAssertEqual(exact.displayToPicture, AxisMap(scaleX: 1, scaleY: 1, offsetX: 100, offsetY: 40))
  }

  func testUnusableAperturesShowTheWholeFrame() {
    let whole = aperture(nil, 1920, 1088)
    for bad in [
      MonitorRect(x: .nan, y: 0, width: 100, height: 100), MonitorRect(x: 0, y: 0, width: .infinity, height: 100),
      MonitorRect(x: 5000, y: 0, width: 100, height: 100), MonitorRect(x: 0, y: 0, width: 0.5, height: 100),
    ] {
      XCTAssertEqual(aperture(bad, 1920, 1088), whole, "\(bad)")
    }
    // Partly outside: clipped to the frame.
    let clipped = aperture(MonitorRect(x: 1800, y: -20, width: 400, height: 220), 120, 200)
    XCTAssertEqual(clipped.aperture, MonitorRect(x: 1800, y: 0, width: 120, height: 200))
  }

  func testFrameGeometryDisplayAspect() {
    let g = MonitorFrameGeometry(width: 1920, height: 1088, cleanAperture: MonitorRect(x: 0, y: 0, width: 1920, height: 1080))
    XCTAssertEqual(g.displayAspectRatio(), 16.0 / 9, accuracy: 1e-12)
    XCTAssertEqual(g.displayAspectRatio(desqueeze: 2), 32.0 / 9, accuracy: 1e-12)
    XCTAssertEqual(g.displayAspectRatio(desqueeze: 99), 64.0 / 9, accuracy: 1e-12, "de-squeeze clamps like the state")
    // DV NTSC: 720×480 coded, a 704×480 clean aperture at 10:11 pixels is 4:3 (SMPTE RP 187).
    let dv = MonitorFrameGeometry(
      width: 720, height: 480, pixelAspectRatio: 10.0 / 11, cleanAperture: MonitorRect(x: 8, y: 0, width: 704, height: 480))
    XCTAssertEqual(dv.displayAspectRatio(), 4.0 / 3, accuracy: 1e-12)
    var state = MonitorState()
    state.geometry.desqueeze = 1.33
    XCTAssertEqual(dv.displayAspectRatio(for: state), 4.0 / 3 * 1.33, accuracy: 1e-12)
    // An unusable pixel aspect ratio shows square pixels.
    for par in [0.0, -1, .nan, .infinity, 0.01, 17] {
      let broken = MonitorFrameGeometry(width: 1920, height: 1080, pixelAspectRatio: par)
      XCTAssertFalse(broken.hasUsablePixelAspectRatio, "\(par)")
      XCTAssertEqual(broken.displayAspectRatio(), 16.0 / 9, accuracy: 1e-12)
    }
    XCTAssertTrue(MonitorFrameGeometry(width: 1, height: 1, pixelAspectRatio: 16).hasUsablePixelAspectRatio)
    XCTAssertTrue(MonitorFrameGeometry(width: 1, height: 1, pixelAspectRatio: 0.0625).hasUsablePixelAspectRatio)
  }

  /// The main-thread query equals the layout the pass builds from the normalized state.
  func testLayoutQueryNormalizesTheGeometry() {
    let g = MonitorFrameGeometry(
      width: 1920, height: 1088, pixelAspectRatio: 1, cleanAperture: MonitorRect(x: 0, y: 4, width: 1920, height: 1080))
    var state = MonitorState()
    state.geometry.desqueeze = 9
    state.geometry.magnification.zoom = .nan
    state.geometry.magnification.centerX = 7
    let query = MonitorLayout(frame: g, state: state, viewportWidth: 1280, viewportHeight: 720)
    let direct = MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1088, pixelAspectRatio: 1, viewportWidth: 1280, viewportHeight: 720,
      geometry: state.normalized().geometry, cleanAperture: g.cleanAperture)
    XCTAssertEqual(query, direct)
    XCTAssertEqual(query.fitRect.width / query.fitRect.height, g.displayAspectRatio(for: state.normalized()), accuracy: 0.01)
  }
}
