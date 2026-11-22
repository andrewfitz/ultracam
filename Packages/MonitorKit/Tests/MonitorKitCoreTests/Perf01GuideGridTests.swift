// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import MonitorKitCore

final class Perf01GuideGridTests: XCTestCase {
  // The original uncapped grid algorithm, including final clipping/truncation.
  private func naive(_ layout: MonitorLayout, rows: Int) -> [GuideRaster.Segment] {
    let r = layout.imageRect, half = 0.5
    let cell = r.height / Double(rows)
    var out: [GuideRaster.Segment] = []
    func across(_ v: Double, _ low: Double, _ high: Double) -> Double {
      min(max(v.rounded(.down) + 0.5, low + half), high - half)
    }
    func vertical(_ x: Double) {
      let x = across(x, r.x, r.maxX)
      out.append(.init(x0: x, y0: r.y.rounded(), x1: x, y1: r.maxY.rounded(), halfWidth: half))
    }
    for i in 1..<rows {
      let y = across(r.y + cell * Double(i), r.y, r.maxY)
      out.append(.init(x0: r.x.rounded(), y0: y, x1: r.maxX.rounded(), y1: y, halfWidth: half))
    }
    var k = 0.0
    while r.midX + k * cell < r.maxX - half {
      vertical(r.midX + k * cell)
      if k > 0 { vertical(r.midX - k * cell) }
      k += 1
    }
    // A later guide must still disappear if the grid already filled the prefix.
    out.append(.init(x0: r.midX.rounded(.down) + 0.5, y0: r.midY.rounded(.down) + 0.5,
      x1: r.midX.rounded(.down) + 0.5, y1: r.midY.rounded(.down) + 0.5, halfWidth: 2))
    if layout.isMagnified {
      let view = MonitorRect(x: 0, y: 0, width: layout.viewportWidth, height: layout.viewportHeight)
      out = out.compactMap { GuideRaster.clipped($0, to: view) }
    }
    return Array(out.prefix(GuideRaster.maximumSegments))
  }

  private func settings(rows: Int) -> GuideSettings {
    var g = GuideSettings()
    g.enabled = true
    g.thirds = false
    g.squareGrid = true
    g.squareGridRows = rows
    g.centerDot = true
    return g
  }

  func testCappedGridRetainsExactNaivePrefix() {
    for width in [32, 1920, 16384, 100000] {
      for rows in [2, 7, 16] {
        for zoom in [1.0, 3.0] {
          var geometry = ViewGeometry()
          geometry.magnification.zoom = zoom
          geometry.magnification.centerX = 0.1
          let layout = MonitorLayout(pictureWidth: width, pictureHeight: 100,
            viewportWidth: width, viewportHeight: 100, geometry: geometry)
          let actual = GuideRaster(layout: layout, guides: settings(rows: rows))
          XCTAssertEqual(actual.segments, naive(layout, rows: rows))
        }
      }
    }
  }

  // Run with MONITORKIT_PERF01_GRID_BENCH=1 swift test --filter Perf01GuideGridTests/testWideGridMicrobenchmark
  func testWideGridMicrobenchmark() throws {
    guard ProcessInfo.processInfo.environment["MONITORKIT_PERF01_GRID_BENCH"] == "1" else {
      throw XCTSkip("Opt-in grid microbenchmark")
    }
    let layout = MonitorLayout(pictureWidth: 100000, pictureHeight: 100,
      viewportWidth: 100000, viewportHeight: 100, geometry: ViewGeometry())
    let guides = settings(rows: 16)
    let clock = ContinuousClock()
    let oldStart = clock.now
    var checksum = 0
    for _ in 0..<100 { checksum += naive(layout, rows: 16).count }
    let oldTime = oldStart.duration(to: clock.now)
    let newStart = clock.now
    for _ in 0..<100 {
      checksum += GuideRaster(layout: layout, guides: guides).segments.count
    }
    let newTime = newStart.duration(to: clock.now)
    XCTAssertEqual(checksum, 25600)
    print("BENCH Perf01 wide grid naive=\(oldTime) capped=\(newTime) rounds=100")
  }
}
