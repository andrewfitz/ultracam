import AppKit
import MonitorKit
import MonitorKitCore
import SwiftUI
import XCTest

@testable import MonitorKitUI

@MainActor
final class StatusOverlayTests: XCTestCase {
  /// The overlay covers exactly the target pixels its surface draws into: the
  /// renderer's viewport of the region in a drawable of the view's size at the
  /// screen scale, back in points. Tiled regions tile without gap or overlap.
  func testFrameMatchesTheRendererViewport() throws {
    for (size, scale) in [(CGSize(width: 640, height: 360), 2.0), (CGSize(width: 333.5, height: 201), 2), (CGSize(width: 1001, height: 777), 1)] {
      let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
      let quads = [
        MonitorRegion(x: 0, y: 0, width: 0.5, height: 0.5), MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 0.5),
        MonitorRegion(x: 0, y: 0.5, width: 0.5, height: 0.5), MonitorRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
      ]
      var area: CGFloat = 0
      for region in quads {
        let rect = try XCTUnwrap(MonitorStatusOverlay.frame(of: region, in: size, scale: scale))
        let vp = try XCTUnwrap(region.viewport(width: w, height: h))
        XCTAssertEqual(rect.minX * scale, CGFloat(vp.x), accuracy: 1e-9)
        XCTAssertEqual(rect.minY * scale, CGFloat(vp.y), accuracy: 1e-9)
        XCTAssertEqual(rect.width * scale, CGFloat(vp.width), accuracy: 1e-9)
        XCTAssertEqual(rect.height * scale, CGFloat(vp.height), accuracy: 1e-9)
        area += rect.width * rect.height * scale * scale
      }
      XCTAssertEqual(area, CGFloat(w * h), accuracy: 1e-6, "the quads tile the view")
    }
    XCTAssertNil(MonitorStatusOverlay.frame(of: MonitorRegion(x: 0, y: 0, width: 0, height: 1), in: CGSize(width: 100, height: 100), scale: 2))
    XCTAssertNil(MonitorStatusOverlay.frame(of: .full, in: .zero, scale: 2))
  }

  func testCornerTextsAndDescription() {
    let m = MonitorOverlayMetadata(
      timecode: "01:00:00:00", format: "UHD 23.98", lutName: "Rec709 Look", tally: .recording,
      labels: [.init("CAM A", corner: .topLeading), .init("ISO 800", corner: .bottomTrailing)])
    XCTAssertEqual(m.texts(in: .topLeading), ["UHD 23.98", "CAM A"])
    XCTAssertEqual(m.texts(in: .topTrailing), ["01:00:00:00"])
    XCTAssertEqual(m.texts(in: .bottomLeading), ["Rec709 Look"])
    XCTAssertEqual(m.texts(in: .bottomTrailing), ["ISO 800"])
    XCTAssertEqual(
      m.accessibilityDescription, "Recording, UHD 23.98, Timecode 01:00:00:00, LUT Rec709 Look, CAM A, ISO 800")
    XCTAssertNil(MonitorStatusOverlay.tallyColor(.off))
    XCTAssertNotNil(MonitorStatusOverlay.tallyColor(.preview))
    XCTAssertEqual(MonitorStatusOverlay.tallyColor(.program), MonitorStatusOverlay.tallyColor(.recording))
    XCTAssertNotEqual(MonitorStatusOverlay.tallyColor(.program), MonitorStatusOverlay.tallyColor(.preview))
    XCTAssertEqual(MonitorOverlayMetadata().accessibilityDescription, "")
  }

  /// It lays out over a region, and the clean switch removes it.
  func testOverlayLaysOutAndCleanHidesIt() {
    let m = MonitorOverlayMetadata(timecode: "10:00:00:00", format: "HD 25", tally: .program)
    func host(clean: Bool) -> NSHostingView<some View> {
      let view = MonitorStatusOverlay(metadata: m, region: MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1), clean: clean)
        .frame(width: 400, height: 200)
      let hosting = NSHostingView(rootView: view)
      hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
      hosting.layoutSubtreeIfNeeded()
      return hosting
    }
    let shown = host(clean: false)
    XCTAssertEqual(shown.fittingSize.width, 400)
    let image = shown.bitmapImageRepForCachingDisplay(in: shown.bounds)!
    shown.cacheDisplay(in: shown.bounds, to: image)
    // The tally border runs inside the right half only.
    func alpha(_ x: Int, _ y: Int) -> CGFloat { image.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
    let s = Int(image.pixelsWide / 400)
    XCTAssertGreaterThan(alpha(201 * s, 100 * s), 0.5, "the border's left edge at the region's edge")
    XCTAssertEqual(alpha(150 * s, 100 * s), 0, "nothing over the left surface")
    let clean = host(clean: true)
    let cleanImage = clean.bitmapImageRepForCachingDisplay(in: clean.bounds)!
    clean.cacheDisplay(in: clean.bounds, to: cleanImage)
    XCTAssertEqual(cleanImage.colorAt(x: 201 * s, y: 100 * s)?.alphaComponent ?? 0, 0, "clean hides the overlay")
  }
}
