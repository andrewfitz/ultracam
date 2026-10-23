import Metal
import XCTest
import simd

@testable import MonitorKit

/// `MonitorToolsMetalTests/MonitorQualityTests` (9 cases), ported (map §8.2).
///
/// | MonitorTools case | Here |
/// | --- | --- |
/// | `testShaderCompilesAndExplicitParameterLayoutMatches` | `testShadersCompileAndParameterLayoutsMatchTheDocumentedSizes` |
/// | `testSonyEveryNativeCodeUsesPublishedPattern2AcrossTransport` | `testSonyEveryNativeCodeUsesPattern2AcrossTransportThroughIOSurfaces` |
/// | `testSonySignalIREUsesDeclaredMatrixForColoredSource` | `testSonySignalIREUsesTheDeclaredMatrixForAColouredSource` |
/// | `testPreviewMinificationAveragesCheckerboardAtTwoAndFourToOne` | `testMinificationAveragesACheckerboardAtTwoAndFourToOne` |
/// | `testFocusRejectsIsolatedImpulseButPreservesSupportedEdge` | `testFocusRejectsAnIsolatedImpulseButKeepsASupportedEdge` |
/// | `testScharrConfidenceMatchesIndependentCPUOracleOnSlantedEdgeAndNoise` | `testScharrConfidenceMatchesAnIndependentCPUOracle` |
/// | `testThinSourceFocusSurvivesTwoToOnePreviewMinification` | `testThinSourceFocusSurvivesTwoToOneMinification` |
/// | `testFractionalMinificationMatchesBoundedBilinearQuadratureOracle` | `testFractionalMinificationMatchesTheStratifiedBoxOracle` (semantic difference) |
/// | `testScopeDensityIsStableAcrossSourceWidth` | `MonitorKitScopesTests/ScopePortedMonitorToolsTests.testTraceDensityIsStableAcrossSourceWidth` (this target cannot import `MonitorKitScopes`) |
final class PortedQualityTests: XCTestCase {
  /// MonitorTools checked its `KernelParameters` offsets by hand. MonitorKit's
  /// structs are checked against shader reflection in `ABITests`; this port pins
  /// the sizes ARCHITECTURE.md documents for hosts (uniform sizes per encode) and
  /// that every entry point compiles from the shipped text.
  func testShadersCompileAndParameterLayoutsMatchTheDocumentedSizes() throws {
    let gpu = try requireGPU()
    for name in ["mk_fullscreen", "mk_picture", "mk_pictureKernel", "mk_focusMask", "mk_copyUint", "mk_copyFloat"] {
      XCTAssertNotNil(gpu.engine.library.makeFunction(name: name), name)
    }
    XCTAssertEqual(MemoryLayout<FrameParameters>.stride, 80)
    // The picture pass binds two at buffer 0 (the source and the output reading).
    XCTAssertEqual(MemoryLayout<PassFrameParameters>.stride, 160)
    // The documented sizes: a change here must update ARCHITECTURE.md's uniform sizes too.
    XCTAssertEqual(MemoryLayout<PassParameters>.stride, 1488)
    XCTAssertEqual(MemoryLayout<GuideParameters>.stride, 2592)
    XCTAssertEqual(MonitorPass.uniformLength, 5120)
    XCTAssertEqual(MonitorFeed.uniformLength, 1024)
  }

  /// Every native 10-bit code, natively and squeezed into the legal range, from a
  /// real `kCVPixelFormatType_422YpCbCr10` buffer through the texture cache. Pattern 2
  /// classifies native signal IRE whatever the transport. The original sampled one
  /// pixel per 6-pixel group; this checks every pixel.
  func testSonyEveryNativeCodeUsesPattern2AcrossTransportThroughIOSurfaces() throws {
    let gpu = try requireGPU()
    for transport in LogTransport.allCases {
      let codes = (0..<1024).map { Ported.transported($0, transport) }
      let picture = SyntheticFrame.neutral(.v210, width: 1024, height: 2) { x, _ in codes[x] }
      let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3(.sGamut3Cine, transport: transport), range: .legal))
      var state = MonitorState()
      state.falseColor.mode = .sonySLog3
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertTrue(pass.status.isActive(.falseColor), "\(transport)")
      for x in 0..<1024 {
        let native = Ported.native(transported: codes[x], transport)
        let expected = try XCTUnwrap(SonySLog3FalseColor.color(nativeSignalLuma: native))
        assertPorted(out.rgb(x, 1), expected, exact: SonySLog3FalseColor.category(nativeSignalLuma: native) != nil,
                     "\(transport) code \(codes[x])")
      }
    }
  }

  /// A coloured BGRA source: Pattern 2 reads the signal luma of the declared
  /// Y'CbCr matrix (BT.709 and BT.2020 weights differ for (204, 76, 51)).
  func testSonySignalIREUsesTheDeclaredMatrixForAColouredSource() throws {
    let gpu = try requireGPU()
    let picture = Ported.bgra(width: 6, height: 4) { _, _ in (204, 76, 51) }
    var colours: [SIMD3<Float>] = []
    for matrix in [YCbCrMatrix.bt709, .bt2020] {
      let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.sLog3Cine, range: .full, matrix: matrix))
      var state = MonitorState()
      state.falseColor.mode = .sonySLog3
      let out = try gpu.render(frame, state: state)
      let rgb = ColorRGB(r: 204.0 / 255, g: 76.0 / 255, b: 51.0 / 255)
      let expected = try XCTUnwrap(SonySLog3FalseColor.color(rgb: rgb, matrix: matrix))
      let luma = try XCTUnwrap(ColorMath.signalLuma(rgb, matrix: matrix))
      for x in 0..<6 {
        assertPorted(out.rgb(x, 0), expected, exact: SonySLog3FalseColor.category(nativeSignalLuma: luma) != nil, "\(matrix)")
      }
      colours.append(out.rgb(0, 0))
    }
    // BT.709 weights give 39.1 IRE (green), BT.2020 42.2 IRE (just past green, an
    // unbanded grey), so a shader ignoring the declared matrix fails one of them.
    XCTAssertNotEqual(colours[0], colours[1])
  }

  /// A one-pixel checkerboard of 0 and 255 averages to exactly mid-grey at 2:1 and
  /// 4:1 (box minification, no aliasing). The original checked one row inside its
  /// borders; every pixel is exact here. Zebras above white keep the tools pipeline,
  /// as the original did.
  func testMinificationAveragesACheckerboardAtTwoAndFourToOne() throws {
    let gpu = try requireGPU()
    for ratio in [2, 4] {
      let picture = Ported.grey(width: 192, height: 1080 * ratio) { x, y in (x + y) % 2 == 0 ? 0 : 255 }
      let frame = try Ported.wrapped(gpu, picture, signal: SignalDescription(range: .full))
      var state = MonitorState()
      state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 110, stage: .source)
      let out = try gpu.render(frame, state: state, width: 192 / ratio, height: 1080)
      for y in 0..<1080 {
        for x in 0..<(192 / ratio) {
          XCTAssertEqual(out.rgb(x, y), SIMD3(repeating: 0.5), "\(ratio):1 at \(x),\(y)")
        }
      }
    }
  }

  /// A lone hot pixel has no directional support and is not peaked; a real edge is,
  /// at full strength.
  func testFocusRejectsAnIsolatedImpulseButKeepsASupportedEdge() throws {
    let gpu = try requireGPU()
    let picture = Ported.grey(width: 48, height: 32) { x, y in x == 8 && y == 8 ? 255 : (x >= 32 ? 240 : 100) }
    let frame = try Ported.wrapped(gpu, picture, signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.color = .red
    state.focus.opacity = 1
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass, analyze: true)
    XCTAssertTrue(pass.status.isActive(.focusPeaking))
    for y in 6...10 {
      for x in 6...10 {
        let c = out.rgb(x, y)
        XCTAssertEqual(c.x, c.z, "a single impulse has no directional edge support (\(x),\(y))")
        XCTAssertEqual(c.y, c.z)
      }
    }
    for y in 0..<32 {
      XCTAssertEqual(out.rgb(31, y), SIMD3(1, 0, 0), "edge row \(y)")
      XCTAssertEqual(out.rgb(32, y), SIMD3(1, 0, 0), "edge row \(y)")
    }
  }

  /// The detector against an oracle written from MonitorTools' definition: Scharr
  /// 3-10-3 central differences over 16, support = the larger |median| of the three
  /// directional differences, confidence = (|g| - t) / (t / 2) with t = 0.17 at the
  /// default sensitivity, clamped, stored as unorm8 in the mask. Green is the picture
  /// mixed toward red by that confidence, on a slanted edge with ±2-code noise.
  func testScharrConfidenceMatchesAnIndependentCPUOracle() throws {
    let gpu = try requireGPU()
    let w = 48, h = 32
    func value(_ x: Int, _ y: Int) -> Int { x >= 20 + y / 4 ? 155 : 100 + (x * 7 + y * 3) % 5 }
    let frame = try Ported.wrapped(gpu, Ported.grey(width: w, height: h, value), signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.opacity = 1
    XCTAssertEqual(state.focus.edgeThreshold, 0.17, accuracy: 1e-12, "MonitorTools' default threshold")
    let out = try gpu.render(frame, state: state, analyze: true)
    func v(_ x: Int, _ y: Int) -> Double { Double(value(max(0, min(w - 1, x)), max(0, min(h - 1, y)))) / 255 }
    func median(_ a: Double, _ b: Double, _ c: Double) -> Double { [a, b, c].sorted()[1] }
    var peaked = 0
    for y in 0..<h {
      for x in 0..<w {
        let dx = (-1...1).map { v(x + 1, y + $0) - v(x - 1, y + $0) }
        let dy = (-1...1).map { v(x + $0, y + 1) - v(x + $0, y - 1) }
        let gx = (3 * dx[0] + 10 * dx[1] + 3 * dx[2]) / 16
        let gy = (3 * dy[0] + 10 * dy[1] + 3 * dy[2]) / 16
        let support = max(abs(median(dx[0], dx[1], dx[2])), abs(median(dy[0], dy[1], dy[2])))
        let confidence = support > 0.02 ? max(0, min(1, (max(abs(gx), abs(gy)) - 0.17) / 0.085)) : 0
        let quantized = (confidence * 255).rounded() / 255
        if confidence > 0 { peaked += 1 }
        let expectedGreen = v(x, y) * (1 - quantized)
        // One mask code either way where float and double round a confidence differently.
        XCTAssertEqual(Double(out.rgb(x, y).y), expectedGreen, accuracy: v(x, y) / 255 + 1e-5, "Scharr confidence at \(x),\(y)")
      }
    }
    XCTAssertGreaterThan(peaked, h, "the slanted edge is found")
  }

  /// A one-pixel line in a 2:1 minified picture stays fully peaked: each display
  /// pixel takes the maximum confidence under its footprint.
  func testThinSourceFocusSurvivesTwoToOneMinification() throws {
    let gpu = try requireGPU()
    let frame = try Ported.wrapped(gpu, Ported.grey(width: 192, height: 2160) { x, _ in x == 48 ? 255 : 100 },
                                   signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.opacity = 1
    let out = try gpu.render(frame, state: state, width: 96, height: 1080, analyze: true)
    for y in 0..<1080 {
      XCTAssertEqual(out.rgb(24, y).x, 1, "row \(y)")
      XCTAssertEqual(out.rgb(24, y).y, 0, "the footprint maximum keeps the line's neighbouring gradient (row \(y))")
    }
  }

  /// Semantic difference: MonitorTools minified with bilinear taps at stratified
  /// positions ("bounded bilinear quadrature"). MonitorKit's box is stratified
  /// nearest taps (`mk_axis`: n = ceil(footprint - 0.001) taps per axis, at most 8,
  /// spaced footprint/n, each reading the pixel that contains it), exact for
  /// integral ratios. The oracle below is that definition, written independently of
  /// `PictureTests.filtered`, on MonitorTools' 13 × 2700 ramp into a 5-wide window
  /// (footprints 2.6 and 2.60…, both fractional; the picture is letterboxed).
  func testFractionalMinificationMatchesTheStratifiedBoxOracle() throws {
    let gpu = try requireGPU()
    let width = 13, height = 2700
    func sample(_ x: Int, _ y: Int) -> Int { 20 + (x * 37 + y * 17) % 200 }
    let frame = try Ported.wrapped(gpu, Ported.grey(width: width, height: height, sample), signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 110, stage: .source)
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass, width: 5, height: 1080)
    let layout = MonitorLayout(pictureWidth: width, pictureHeight: height, viewportWidth: 5, viewportHeight: 1080, geometry: ViewGeometry())
    XCTAssertEqual(pass.layout, layout)
    let image = layout.imageRect, map = layout.displayToPicture
    XCTAssertGreaterThan(map.scaleX, 2.5)
    XCTAssertNotEqual(map.scaleX, map.scaleX.rounded())
    XCTAssertNotEqual(map.scaleY, map.scaleY.rounded())
    /// Tap pixels of display pixel `i` on one axis, or nil when a tap sits within
    /// float rounding of a pixel edge (either neighbour is a correct reading).
    func taps(_ i: Int, _ scale: Double, _ offset: Double, _ size: Int) -> [Int]? {
      let footprint = abs(scale), centre = (Double(i) + 0.5) * scale + offset
      let n = min(8, max(1, Int((footprint - 0.001).rounded(.up))))
      let step = footprint / Double(n), first = centre - footprint / 2 + step / 2
      var result: [Int] = []
      for k in 0..<n {
        let p = first + Double(k) * step
        if abs(p - p.rounded()) < 1e-3 { return nil }
        result.append(min(size - 1, max(0, Int(p.rounded(.down)))))
      }
      return result
    }
    var checked = 0, outside = 0
    for y in 0..<1080 {
      for x in 0..<5 {
        guard Double(x) + 0.5 >= image.x, Double(x) + 0.5 < image.maxX, Double(y) + 0.5 >= image.y, Double(y) + 0.5 < image.maxY
        else {
          XCTAssertEqual(out.rgb(x, y), .zero, "letterbox at \(x),\(y)")
          outside += 1
          continue
        }
        guard let columns = taps(x, map.scaleX, map.offsetX, width), let rows = taps(y, map.scaleY, map.offsetY, height) else { continue }
        var total = 0.0
        for row in rows { for column in columns { total += Double(sample(column, row)) } }
        let expected = total / Double(rows.count * columns.count) / 255
        XCTAssertEqual(Double(out.rgb(x, y).x), expected, accuracy: 2e-5, "at \(x),\(y)")
        checked += 1
      }
    }
    XCTAssertGreaterThan(outside, 0, "the 13 × 2700 picture is letterboxed in 5 × 1080")
    XCTAssertGreaterThan(checked, 4000)
  }
}
