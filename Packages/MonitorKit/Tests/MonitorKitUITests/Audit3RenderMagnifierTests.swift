// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitCore
import XCTest

@testable import MonitorKitUI

/// Pixel-exact pans: the layout rounds the image origin down to a whole pixel,
/// so a pan measured from that origin lost each sub-pixel (and, through float
/// error, each one-pixel) drag to the right and doubled each one to the left.
final class Audit3RenderMagnifierTests: XCTestCase {
  func layout(_ m: Magnification, flip: FlipMode = .none) -> MonitorLayout {
    var g = ViewGeometry()
    g.magnification = m
    g.flip = flip
    return MonitorLayout(
      pictureWidth: 3840, pictureHeight: 2160, viewportWidth: 1917, viewportHeight: 1079, geometry: g)
  }

  func testPixelExactPanFollowsSmallDragsBothWays() {
    for flip in FlipMode.allCases {
      for d in [1.0, 0.5, -0.5, -1.0, 3.0, 0.25] {
        var m = Magnification()
        m.pixelExact = true
        var l = layout(m, flip: flip)
        let x0 = l.imageRect.x, y0 = l.imageRect.y
        let steps = 40
        for _ in 0..<steps {
          m = MonitorMagnifier.pan(m, by: (dx: d, dy: -d), layout: l)
          l = layout(m, flip: flip)
        }
        let want = Double(steps) * d
        // Whole-pixel origins: within a pixel of the drag, whichever way.
        XCTAssertEqual(l.imageRect.x - x0, want, accuracy: 1, "\(flip) dx \(d)")
        XCTAssertEqual(l.imageRect.y - y0, -want, accuracy: 1, "\(flip) dy \(-d)")
      }
    }
  }

  /// At an edge the stored centre is the one shown, so reversing moves at once.
  func testPixelExactPanAtAnEdgeHasNoDeadTravel() {
    var m = Magnification()
    m.pixelExact = true
    var l = layout(m)
    m = MonitorMagnifier.pan(m, by: (dx: 100_000, dy: 0), layout: l)
    l = layout(m)
    XCTAssertEqual(l.imageRect.x, 0, "stopped at the left edge of the picture")
    m = MonitorMagnifier.pan(m, by: (dx: -2, dy: 0), layout: l)
    XCTAssertEqual(layout(m).imageRect.x, -2, accuracy: 1)
    XCTAssertLessThan(layout(m).imageRect.x, 0)
  }

  /// A stored centre past the reachable range (pixel-exact toggled at a corner)
  /// pans from the centre shown, with no dead travel either.
  func testPanFromAnUnclampedStoredCentre() {
    var m = Magnification()
    m.pixelExact = true
    m.centerX = 0
    let l = layout(m)
    XCTAssertEqual(l.imageRect.x, 0)
    let p = MonitorMagnifier.pan(m, by: (dx: -10, dy: 0), layout: l)
    XCTAssertEqual(layout(p).imageRect.x, -10, accuracy: 1)
  }

  /// Zoom mode has no rounding: pans move the picture by exactly the drag,
  /// accumulated over many events, for every flip and with de-squeeze.
  func testZoomPansAreExact() {
    var rng = SplitMix64(seed: 7)
    for flip in FlipMode.allCases {
      for desqueeze in [1.0, 1.65] {
        func zoomed(_ m: Magnification) -> MonitorLayout {
          var g = ViewGeometry()
          g.magnification = m
          g.flip = flip
          g.desqueeze = desqueeze
          return MonitorLayout(
            pictureWidth: 3840, pictureHeight: 2160, viewportWidth: 1917, viewportHeight: 1079, geometry: g)
        }
        var m = Magnification()
        m.zoom = 2.5
        var l = zoomed(m)
        var x = l.imageRect.x, y = l.imageRect.y
        for _ in 0..<60 {
          let d = (dx: Double.random(in: -3...3, using: &rng), dy: Double.random(in: -3...3, using: &rng))
          m = MonitorMagnifier.pan(m, by: d, layout: l)
          l = zoomed(m)
          // The picture can only go as far as its edges.
          x = min(0, max(l.viewportWidth - l.imageRect.width, x + d.dx))
          y = min(0, max(l.viewportHeight - l.imageRect.height, y + d.dy))
          XCTAssertEqual(l.imageRect.x, x, accuracy: 1e-9, "\(flip) \(desqueeze)")
          XCTAssertEqual(l.imageRect.y, y, accuracy: 1e-9, "\(flip) \(desqueeze)")
        }
      }
    }
  }

  /// Pixel-exact with a fractional displayed width (de-squeeze): the edges still
  /// stop the pan and a reversal moves at once.
  func testPixelExactPanAtAFractionalEdge() {
    var g = ViewGeometry()
    g.desqueeze = 1.65
    g.magnification.pixelExact = true
    func layout(_ m: Magnification) -> MonitorLayout {
      g.magnification = m
      return MonitorLayout(pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 1917, viewportHeight: 1079, geometry: g)
    }
    var m = g.magnification
    var l = layout(m)
    m = MonitorMagnifier.pan(m, by: (dx: -100_000, dy: 0), layout: l)
    l = layout(m)
    let right = l.imageRect.x
    XCTAssertEqual(right, (l.viewportWidth - l.imageRect.width).rounded(.down), accuracy: 1)
    m = MonitorMagnifier.pan(m, by: (dx: 3, dy: 0), layout: l)
    XCTAssertEqual(layout(m).imageRect.x, right + 3, accuracy: 1)
  }

  /// Where the picture fits the view, a drag along the other axis keeps the
  /// stored centre of the fitting axis (it used to reset it to 0.5), so a later
  /// zoom comes back to where it was.
  func testPanKeepsTheCentreOfAnAxisThatFits() {
    var g = ViewGeometry()
    g.magnification.pixelExact = true
    g.magnification.centerX = 0.3
    g.magnification.centerY = 0.4
    // 1920 wide in a 2400-pixel view: x fits, y (1080 in 700) does not.
    let l = MonitorLayout(pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 2400, viewportHeight: 700, geometry: g)
    XCTAssertTrue(l.isMagnified)
    let p = MonitorMagnifier.pan(g.magnification, by: (dx: 50, dy: -20), layout: l)
    XCTAssertEqual(p.centerX, 0.3, "x fits: nothing to pan, centre kept")
    XCTAssertNotEqual(p.centerY, 0.4)
    var back = g
    back.magnification = p
    let l2 = MonitorLayout(
      pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 2400, viewportHeight: 700, geometry: back)
    XCTAssertEqual(l2.imageRect.x, l.imageRect.x, "still centred on the fitting axis")
    XCTAssertEqual(l2.imageRect.y, l.imageRect.y - 20, accuracy: 1)
  }
}

/// A deterministic generator, so a failing drag sequence reproduces.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
