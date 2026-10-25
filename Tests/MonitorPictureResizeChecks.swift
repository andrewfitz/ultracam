import AppKit
import MonitorKit
import QuartzCore
import XCTest

// The picture layer follows every layout pass, but its drawables are resized once the
// size settles: changing `drawableSize` makes Core Animation allocate new drawables,
// and following it on every frame of a side-column or strip animation hitched it.

extension MonitorCoordinatorChecks {
  /// A picture view on a presenter with no GPU: layout needs no Metal device.
  private func resizePicture() throws -> MonitorPictureNSView {
    let gpu = MonitorGPUContext(device: { nil })
    let host = MonitorFeedHost(target: "alpha", gpu: gpu)
    let presenter = MonitorSurfacePresenter(target: MonitorTargetID("alpha"), host: host, gpu: gpu)
    return try XCTUnwrap(presenter.makeView() as? MonitorPictureNSView)
  }

  private func resize(_ picture: MonitorPictureNSView, width: CGFloat) {
    picture.frame = CGRect(x: 0, y: 0, width: width, height: (width * 9 / 16).rounded())
    picture.layout()
  }

  func testPictureDrawablesFollowTheSettledSizeNotEveryLayout() throws {
    let picture = try resizePicture()
    let layer = picture.metalLayer
    // Outside a window the backing scale is 2. The first real size applies at once.
    resize(picture, width: 320)
    XCTAssertEqual(layer.drawableSize, CGSize(width: 640, height: 360))
    XCTAssertEqual(picture.drawableResizes, 1)
    // An animation: a layout pass per frame. The layer follows; the drawables don't.
    for step in 1...30 {
      resize(picture, width: 320 + CGFloat(step) * 8)
      XCTAssertEqual(layer.frame.width, 320 + CGFloat(step) * 8)
    }
    XCTAssertEqual(layer.drawableSize, CGSize(width: 640, height: 360), "No drawables are allocated mid-resize")
    XCTAssertEqual(layer.contentsGravity, .resize, "The compositor scales the drawables meanwhile")
    // Once the size holds still, one resize to the final size.
    let settled = Date().addingTimeInterval(MonitorPictureNSView.drawableSettleDelay * 4 + 1)
    while layer.drawableSize.width == 640, Date() < settled {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertEqual(layer.drawableSize, CGSize(width: 1120, height: 630))
    XCTAssertEqual(picture.drawableResizes, 2, "One allocation for the whole animation")
  }

  func testPictureDrawablesNeverWaitOnADegenerateSize() throws {
    let picture = try resizePicture()
    // Laid out at zero size first (a view that has just appeared), then given its size.
    resize(picture, width: 0)
    resize(picture, width: 480)
    XCTAssertEqual(picture.metalLayer.drawableSize, CGSize(width: 960, height: 540),
      "A picture that has just appeared draws at its size at once, never into a 1×1 drawable")
  }
}
