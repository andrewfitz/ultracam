// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import MonitorKitCore

final class CoreStateAuditRegressionTests: XCTestCase {
  func testDirectLayoutNormalizesExtremeZoom() {
    var geometry = ViewGeometry()
    geometry.magnification.zoom = .greatestFiniteMagnitude
    let layout = MonitorLayout(pictureWidth: 1920, pictureHeight: 1080,
      viewportWidth: 1920, viewportHeight: 1080, geometry: geometry)
    XCTAssertEqual(layout.imageRect.width, 1920 * 64)
    XCTAssertTrue(layout.displayToPicture.offsetX.isFinite)
    XCTAssertTrue(layout.visiblePictureRect.width.isFinite)
  }

  func testRasterBoundsUnnormalizedGridRowsAndHandlesNonfiniteDensity() {
    let layout = MonitorLayout(pictureWidth: 1920, pictureHeight: 1080,
      viewportWidth: 1920, viewportHeight: 1080, geometry: ViewGeometry())
    var guides = GuideSettings()
    guides.enabled = true
    guides.squareGrid = true
    guides.squareGridRows = .max
    guides.lineWidth = .infinity
    let raster = GuideRaster(layout: layout, guides: guides, pixelsPerPoint: .infinity)
    XCTAssertEqual(raster.strokeWidth, 1)
    XCTAssertFalse(raster.segments.isEmpty)
    XCTAssertLessThanOrEqual(raster.segments.count, GuideRaster.maximumSegments)
    XCTAssertTrue(raster.segments.allSatisfy { $0.x0.isFinite && $0.y0.isFinite })
  }

  func testFittingRejectsInfiniteAspect() {
    let rect = MonitorRect(x: 0, y: 0, width: 1920, height: 1080)
    XCTAssertEqual(rect.fitting(aspect: .infinity), rect)
  }

  func testExtremeBitDepthDoesNotOverflowIntegerArithmetic() {
    let levels = CodeRange.legal.levels(bitDepth: .min)
    XCTAssertEqual(levels.black, 0)
    XCTAssertEqual(levels.span, 0)
  }
}
