import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// The scope checks of the retired MonitorTools tests, ported (map §8.2). The
/// MonitorKitTests port tables point here for the cases that need MonitorKitScopes.
///
/// | MonitorTools case | Here |
/// | --- | --- |
/// | `MonitorMetalTests.testGraticuleToggleChangesOnlyScopeGridPixels` (315) | `testGraticuleToggleChangesOnlyGraticulePixels` |
/// | `MonitorQualityTests.testScopeDensityIsStableAcrossSourceWidth` (156) | `testTraceDensityIsStableAcrossSourceWidth` |
/// | `MonitorMetalTests.testActualGPUZebraAndSpatialScope` (97), the scope half | `ScopeAccumulationTests.testWaveformLumaEveryLayout` and `ScopeRenderTests.testWaveformTraceMatchesReference` |
/// | `MonitorMetalTests.testScopeRGBOrderAndExtendedRangeAxesOnGPU` (176) | `ScopeRenderTests.testParadePanelsDrawTheirOwnChannel` and `ScopeLegacyLookTests.testLegacyRangeBins` |
/// | `SourcePictureGeometryTests.testScopeLatticeCountsEveryPixelOnceIncludingPartialEdgeCells` | `ScopeAccumulationTests.testWaveformLumaEveryLayout` (a 251 × 37 frame against the CPU bins, every pixel counted once) and `ScopeGroupTests.testOddAndTinyFrames` |
final class ScopePortedMonitorToolsTests: XCTestCase {
  static let width = ScopeSettings.ultracamLegacyImageWidth, height = ScopeSettings.ultracamLegacyImageHeight

  /// The legacy waveform of `frame` into a fresh `bgra8Unorm` target, as bytes,
  /// with the renderer (for its graticule raster).
  func render(
    _ frame: TestFrame, mode: WaveformMode, graticule: Bool, display: (inout ScopeDisplay) -> Void = { _ in }
  ) throws -> ([UInt8], ScopeRenderer) {
    let (device, _, engine) = try GPU.require()
    var s = ScopeSettings.ultracamLegacy(mode: mode, stage: .source)
    s.display.showsGraticule = graticule
    s.display.graticuleOpacity = 1
    display(&s.display)
    let accumulator = try engine.makeAccumulator(settings: s)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    let target = try makeTexture(device, .bgra8Unorm, Self.width, Self.height)
    let renderer = engine.makeRenderer()
    try GPU.run { cb in try renderer.render(accumulator, target: target, clear: true, into: cb) }
    var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
    bytes.withUnsafeMutableBytes {
      target.getBytes(
        $0.baseAddress!, bytesPerRow: Self.width * 4, from: MTLRegionMake2D(0, 0, Self.width, Self.height),
        mipmapLevel: 0)
    }
    return (bytes, renderer)
  }

  /// Turning the graticule on changes only graticule pixels: with it off, the
  /// rows its -10, 0, 50, 100 and 110 % lines sit on (255, 234, 127, 21, 0) hold
  /// no graticule anywhere, and every pixel the graticule raster does not cover is
  /// identical in both images. A flat 27 % picture keeps the trace off those rows.
  func testGraticuleToggleChangesOnlyGraticulePixels() throws {
    let frame = try TestFrame.make(
      .v210, width: 320, height: 32, codes: { _, _ in SIMD3(300, 512, 512) }, mirror: false)
    for mode in [WaveformMode.rgbParade, .luma] {
      let (off, _) = try render(frame, mode: mode, graticule: false)
      let (on, renderer) = try render(frame, mode: mode, graticule: true)
      let raster = try privateBytes(try XCTUnwrap(renderer.graticuleTexture))
      let rasterWidth = try XCTUnwrap(renderer.graticuleTexture).width
      func pixel(_ image: [UInt8], _ x: Int, _ y: Int) -> SIMD4<UInt8> {
        let i = (y * Self.width + x) * 4
        return SIMD4(image[i], image[i + 1], image[i + 2], image[i + 3])
      }
      let background = pixel(off, Self.width / 2, 64)
      XCTAssertEqual(SIMD3(background.x, background.y, background.z), .zero, "\(mode): the legacy background is black")
      var lineRows = 0
      for row in [255, 234, 127, 21, 0] {
        var lit = 0
        for x in 0..<Self.width {
          XCTAssertEqual(pixel(off, x, row), background, "\(mode): off, row \(row) column \(x)")
          if pixel(on, x, row) != background { lit += 1 }
        }
        if lit > Self.width / 2 { lineRows += 1 }
      }
      XCTAssertEqual(lineRows, 5, "\(mode): on, every predicted row carries its line")
      var changed = 0, outside = 0
      for y in 0..<Self.height {
        for x in 0..<Self.width where pixel(on, x, y) != pixel(off, x, y) {
          changed += 1
          if raster[y * rasterWidth + x] == 0 { outside += 1 }
        }
      }
      XCTAssertGreaterThan(changed, 5 * Self.width / 2, "\(mode)")
      XCTAssertEqual(outside, 0, "\(mode): a pixel the graticule does not cover changed")
    }
  }

  /// The trace's brightness is a density (hits per source column), not a count:
  /// a flat picture 512 or 1024 pixels wide draws the same pixel at the same row
  /// and column, within one 8-bit code. A flat column is 256 times the uniform
  /// density, so the lowest gain (0.05) and the gamma curve keep the trace off the
  /// curve's top (12.8 of 16): a count, twice the density at twice the width, would
  /// read 10 % brighter, and half the column's pixels on the level (the control)
  /// reads dimmer.
  func testTraceDensityIsStableAcrossSourceWidth() throws {
    /// The brightest pixel of the middle column, or the pixel on `onRow`.
    func brightest(width: Int, halfAtAnotherLevel: Bool = false, onRow: Int? = nil) throws -> (row: Int, value: SIMD4<UInt8>) {
      let frame = try TestFrame.make(
        .bgra8, width: width, height: 8,
        rgb: { _, y in SIMD3(repeating: (halfAtAnotherLevel && y >= 4 ? 200 : 100) / 255) })
      let (image, _) = try render(frame, mode: .luma, graticule: false) {
        $0.gain = 0.05
        $0.intensity = .gamma
        $0.brightness = 0.5
      }
      let x = Self.width / 2
      if let onRow {
        let i = (onRow * Self.width + x) * 4
        return (onRow, SIMD4(image[i], image[i + 1], image[i + 2], image[i + 3]))
      }
      var row = 0, best = SIMD4<UInt8>.zero
      for y in 0..<Self.height {
        let i = (y * Self.width + x) * 4
        let p = SIMD4(image[i], image[i + 1], image[i + 2], image[i + 3])
        if Int(p.x) + Int(p.y) + Int(p.z) > Int(best.x) + Int(best.y) + Int(best.z) { (row, best) = (y, p) }
      }
      return (row, best)
    }
    let narrow = try brightest(width: 512), wide = try brightest(width: 1024)
    print("PORTED trace density: 512 wide \(narrow), 1024 wide \(wide)")
    XCTAssertLessThan(max(narrow.value.x, narrow.value.y, narrow.value.z), 230, "the trace is not saturated")
    let sparse = try brightest(width: 512, halfAtAnotherLevel: true, onRow: narrow.row)
    XCTAssertLessThan(Int(sparse.value.x) + 10, Int(narrow.value.x), "the control: half the density reads dimmer")
    XCTAssertGreaterThan(Int(narrow.value.x) + Int(narrow.value.y) + Int(narrow.value.z), 60, "a trace is drawn")
    XCTAssertEqual(narrow.row, wide.row, "the same level")
    for c in 0..<3 {
      XCTAssertLessThanOrEqual(abs(Int(narrow.value[c]) - Int(wide.value[c])), 1, "channel \(c): \(narrow) vs \(wide)")
    }
  }
}
