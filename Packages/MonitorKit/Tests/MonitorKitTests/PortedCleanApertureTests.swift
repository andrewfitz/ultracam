import CoreVideo
import Metal
import XCTest
import simd

@testable import MonitorKit

/// The clean-aperture cases (R10), ported:
/// - `MonitorMetalTests.testAsymmetricApertureShowsTheTopLeftOriginedCleanRect` (map §8.2).
/// - The app's `testActualDownscaleKeepsSourceFocusAlignedAcrossAsymmetricAperture`
///   (map §8.1: "Aperture alignment becomes a MonitorKit pixel test").
///
/// MonitorTools took the aperture as a producer-resolved top-left rect on the
/// output geometry. MonitorKit carries it on the frame (`MonitorFrame.cleanAperture`,
/// top-left origin) and reads CoreVideo's `kCVImageBufferCleanApertureKey` in `wrap`
/// (size plus the centre's offset from the frame centre, y down), so both are tested.
final class PortedCleanApertureTests: XCTestCase {
  /// MonitorTools' 64 × 32 fixture: blue = 3x, green = 5y, red 0.
  static let gradient = Ported.bgra(width: 64, height: 32) { x, y in (0, y * 5, x * 3) }
  /// The original's asymmetric aperture: 40 × 20 at (5, 3).
  static let aperture = MonitorRect(x: 5, y: 3, width: 40, height: 20)

  /// The same aperture as CoreVideo attachments: centre offsets (5 + 20) - 32 = -7
  /// and (3 + 10) - 16 = -3.
  static func attachAperture(_ buffer: CVPixelBuffer) {
    let clap: [CFString: Any] = [
      kCVImageBufferCleanApertureWidthKey: 40.0, kCVImageBufferCleanApertureHeightKey: 20.0,
      kCVImageBufferCleanApertureHorizontalOffsetKey: -7.0, kCVImageBufferCleanApertureVerticalOffsetKey: -3.0,
    ]
    CVBufferSetAttachment(buffer, kCVImageBufferCleanApertureKey, clap as CFDictionary, .shouldPropagate)
  }

  func frames(_ gpu: TestGPU, _ picture: SyntheticFrame) throws -> [(String, MonitorFrame)] {
    var declared = try Ported.wrapped(gpu, picture, signal: SignalDescription(range: .full))
    XCTAssertNil(declared.cleanAperture)
    declared.cleanAperture = Self.aperture
    let buffer = try XCTUnwrap(picture.pixelBuffer(range: .full))
    Self.attachAperture(buffer)
    XCTAssertEqual(MonitorFrame.cleanAperture(of: buffer), Self.aperture)
    let geometry = MonitorFrame.geometry(of: buffer)
    XCTAssertEqual(geometry.shownRect, Self.aperture)
    XCTAssertEqual(geometry.displayAspectRatio(), 2, accuracy: 1e-12)
    let attached = try MonitorFrame.wrap(buffer, cache: gpu.cache, signal: SignalDescription(range: .full))
    XCTAssertEqual(attached.cleanAperture, Self.aperture)
    return [("declared", declared), ("attachment", attached)]
  }

  /// Display pixel (0, 0) is aperture origin (5, 3), measured from the top (not
  /// mirrored vertically), and the last is (44, 22): every pixel of a 1:1 draw is
  /// the aperture's, with the tools on.
  func testAsymmetricApertureShowsTheTopLeftOriginedCleanRect() throws {
    let gpu = try requireGPU()
    for (path, frame) in try frames(gpu, Self.gradient) {
      var state = MonitorState()
      state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 95, stage: .source)
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass, width: 40, height: 20)
      XCTAssertEqual(pass.layout?.aperture, Self.aperture)
      XCTAssertEqual(out.rgb(0, 0), SIMD3(0, 15, 15) / 255, "\(path)")
      XCTAssertEqual(out.rgb(39, 19), SIMD3(0, 110, 132) / 255, "\(path)")
      for y in 0..<20 {
        for x in 0..<40 {
          XCTAssertEqual(out.rgb(x, y), SIMD3(0, Float((y + 3) * 5), Float((x + 5) * 3)) / 255, "\(path) at \(x),\(y)")
        }
      }
      // The aspect follows the aperture: 2:1, so a 60 × 40 window letterboxes it to 60 × 30.
      let wide = try gpu.render(frame, state: state, pass: pass, width: 60, height: 40)
      let layout = try XCTUnwrap(pass.layout)
      XCTAssertEqual(layout.imageRect, MonitorRect(x: 0, y: 5, width: 60, height: 30))
      XCTAssertEqual(wide.rgb(30, 2), .zero, "\(path): letterbox above the 2:1 aperture")
    }
  }

  /// Focus analysis covers the whole frame; the picture and the peaking footprint
  /// follow the aperture. A vertical edge at source x = 20 (above source row 10) and
  /// a horizontal one at source y = 10 (left of source column 20) land at display
  /// x = 14…15 and y = 6…7 at 1:1, and stay peaked at 2:1 minification (display
  /// x = 7, y = 3). An aperture mirrored or centred would put them elsewhere.
  func testSourceFocusStaysAlignedAcrossAnAsymmetricAperture() throws {
    let gpu = try requireGPU()
    let picture = Ported.grey(width: 64, height: 32) { x, y in x >= 20 || y >= 10 ? 200 : 60 }
    for (path, frame) in try frames(gpu, picture) {
      var state = MonitorState()
      state.focus.enabled = true
      state.focus.opacity = 1
      let feed = gpu.engine.makeFeed()
      let out = try gpu.render(frame, state: state, feed: feed, width: 40, height: 20, analyze: true)
      let mask = gpu.readMask(feed)
      XCTAssertEqual(mask.count, 64 * 32, "\(path): the mask covers the whole frame")
      var plain = state
      plain.focus.enabled = false
      let base = try gpu.render(frame, state: plain, feed: feed, width: 40, height: 20)
      for y in 0..<20 {
        for x in 0..<40 {
          let k = mask[(y + 3) * 64 + x + 5], c = base.rgb(x, y)
          XCTAssertEqual(out.rgb(x, y), c + (SIMD3(1, 0, 0) - c) * k, accuracy: 1e-6, "\(path) at \(x),\(y)")
        }
      }
      XCTAssertEqual(out.rgb(14, 2), SIMD3(1, 0, 0), "\(path): vertical edge")
      XCTAssertEqual(out.rgb(15, 2), SIMD3(1, 0, 0), "\(path)")
      XCTAssertEqual(out.rgb(5, 6), SIMD3(1, 0, 0), "\(path): horizontal edge")
      XCTAssertEqual(out.rgb(5, 7), SIMD3(1, 0, 0), "\(path)")
      XCTAssertNotEqual(out.rgb(5, 5), SIMD3(1, 0, 0), "\(path): one row above the edge's support")
      XCTAssertNotEqual(out.rgb(5, 2), SIMD3(1, 0, 0), "\(path): flat")
      let half = try gpu.render(frame, state: state, feed: feed, width: 20, height: 10, analyze: true)
      XCTAssertEqual(half.rgb(7, 1), SIMD3(1, 0, 0), "\(path): 2:1 vertical edge")
      XCTAssertEqual(half.rgb(2, 3), SIMD3(1, 0, 0), "\(path): 2:1 horizontal edge")
      XCTAssertNotEqual(half.rgb(2, 1), SIMD3(1, 0, 0), "\(path): 2:1 flat")
    }
  }
}
