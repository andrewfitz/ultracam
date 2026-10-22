import CoreVideo
import Metal
import XCTest
import simd

@testable import MonitorKit

/// The `MonitorToolsMetalTests/MonitorMetalTests` cases map §8.2 lists, ported.
/// The processed-output and correspondence mapping is in `PortedSupport.swift`.
///
/// | MonitorTools case (line) | Here |
/// | --- | --- |
/// | `testActualGPUZebraAndSpatialScope` (97) | `testZebraOnTheGPU` (the zebra half; the scope half needs `MonitorKitScopes`) |
/// | `testARRIUsesSourceBeforeOutputLUT` (117) | `testARRIUsesTheSourceBeforeTheOutputLUT` |
/// | `testSourceFocusUsesSourceEdgeDespiteFlatOutput` (145) | `testSourceFocusUsesTheSourceEdgeDespiteAFlatOutput` |
/// | `testScopeRGBOrderAndExtendedRangeAxesOnGPU` (176) | not here: needs `MonitorKitScopes` |
/// | `testZebraBandIsCenteredLikeIndependentScalarClassifier` (195) | `testZebraBandIsCentredLikeTheScalarClassifier` |
/// | `testUnknownOrHDRTransferDoesNotGetRetaggedAsSDR` (223) | `testUnknownAndHDRSignalsAreNotRetaggedAsSDR` (semantic difference) |
/// | `testARRIFullRescaledToLegalUsesIndependentlyRoundedFullTable` (243) | `testARRIFullRescaledToLegalUsesTheIndependentlyRoundedFullTable` |
/// | `testAsymmetricApertureShowsTheTopLeftOriginedCleanRect` (282) | `PortedCleanApertureTests.testAsymmetricApertureShowsTheTopLeftOriginedCleanRect` (R10) |
/// | `testGraticuleToggleChangesOnlyScopeGridPixels` (315) | not here: needs `MonitorKitScopes` |
/// | `testMalformedPlanarHeightCannotBeRead` (336) | `testMalformedPlanarHeightCannotBeRead` |
/// | `testEveryPublishedARRINativeTenBitBoundaryOnGPU` (359) | `testEveryPublishedARRINativeTenBitBoundaryThroughIOSurfaces` |
/// | `testDeclaredSourceLogShowsCodeViewWithNumericZebraAndSourceFocus` (414) | `testDeclaredLogSourceShowsTheCodeValueViewWithZebraAndSourceFocus` |
final class PortedMonitorMetalTests: XCTestCase {
  /// MonitorTools' fixture: a 64 × 32 BGRA buffer with every byte 192 (75.3 IRE).
  static func flat(_ code: Int = 192) -> SyntheticFrame { Ported.grey(width: 64, height: 32) { _, _ in code } }

  /// Zebras at 50 IRE on a 75 IRE picture: pixel (0, 0) is on a stripe and lighter,
  /// pixel (8, 0) between stripes and untouched. MonitorKit's first zebra set stripes
  /// along x + y with a 16-pixel period at one pixel per point.
  func testZebraOnTheGPU() throws {
    let gpu = try requireGPU()
    let frame = try Ported.wrapped(gpu, Self.flat(), signal: SignalDescription(range: .full))
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 50)
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass)
    XCTAssertTrue(pass.status.isActive(.zebra1))
    XCTAssertGreaterThan(out.rgb(0, 0).x, 192.0 / 255)
    XCTAssertEqual(out.rgb(8, 0), SIMD3(repeating: 192.0 / 255))
  }

  /// Literal LogC3 false colour classifies the source (250, full-table red) even
  /// when the output look (burn-in LUT) is near black.
  func testARRIUsesTheSourceBeforeTheOutputLUT() throws {
    let gpu = try requireGPU()
    let frame = try Ported.wrapped(gpu, Self.flat(250), signal: Ported.signal(Ported.logC(.arriLogC3), range: .full))
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try Ported.constantLUT(gpu, Ported.flatLevels[0])
    var state = MonitorState()
    state.falseColor.mode = .arriLogC
    let out = try gpu.render(frame, state: state, feed: feed)
    XCTAssertEqual(ARRIFalseColorProfile.logC3EI800.category(achromaticCode: 250.0 / 255 * 1023, range: .full), .red)
    XCTAssertEqual(out.rgb(0, 0), SIMD3(1, 0, 0))
  }

  /// Source-stage peaking finds the source's edge at x = 32 although the output
  /// stage (a flat burn-in LUT) has none; a flat area stays neutral.
  func testSourceFocusUsesTheSourceEdgeDespiteAFlatOutput() throws {
    let gpu = try requireGPU()
    let frame = try Ported.wrapped(gpu, Ported.grey(width: 64, height: 32) { x, _ in x < 32 ? 0 : 255 }, signal: SignalDescription(range: .full))
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try Ported.constantLUT(gpu, 0.75)
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.stage = .source
    let out = try gpu.render(frame, state: state, feed: feed, analyze: true)
    let edge = out.rgb(31, 16), flat = out.rgb(8, 16)
    XCTAssertGreaterThan(edge.x, edge.y)
    XCTAssertEqual(flat.x, flat.z)
    XCTAssertEqual(flat, SIMD3(repeating: 0.75), accuracy: 1e-6)
    // On the output stage the same picture has no edge to peak.
    state.focus.stage = .output
    let output = try gpu.render(frame, state: state, feed: feed, analyze: true)
    XCTAssertEqual(output.rgb(31, 16), SIMD3(repeating: 0.75), accuracy: 1e-6)
  }

  /// MonitorTools' band `thresholdIRE 70, widthIRE 10` is 65…75 IRE (a full width
  /// centred on the threshold, `ColorMath.zebra`). MonitorKit's `range` is the
  /// half-width, so the same band is `level 70, range 5`. Code 166 (65.1 IRE) is
  /// striped, code 196 (76.9 IRE) is not.
  func testZebraBandIsCentredLikeTheScalarClassifier() throws {
    let gpu = try requireGPU()
    for code in [166, 196] {
      let frame = try Ported.wrapped(gpu, Self.flat(code), signal: SignalDescription(range: .full))
      var state = MonitorState()
      state.zebras[0] = ZebraSet(mode: .band, level: 70, range: 5)
      let out = try gpu.render(frame, state: state)
      let ire = Double(code) / 255 * 100
      XCTAssertEqual(state.zebras[0].covers(ire: ire), ColorMath.zebra(ire: ire, threshold: 70, width: 10, above: false))
      if code == 166 {
        XCTAssertGreaterThan(out.rgb(0, 0).x, Float(code) / 255)
      } else {
        XCTAssertEqual(out.rgb(0, 0).x, Float(code) / 255, accuracy: 1e-6)
      }
    }
  }

  /// Semantic difference: MonitorTools drew no tools on an unknown, PQ or HLG
  /// transfer ("unsupported SDR"). MonitorKit's zebras measure the stage's code IRE,
  /// which needs no transfer, so they are drawn (tools needing light, e.g. stops,
  /// still refuse an unlabelled signal: `FalseColorTests`). What the original
  /// protected holds: an HDR signal is not retagged or converted as SDR. Signal-native
  /// output keeps the PQ/HLG code (the 75.3 % between stripes is the source's own
  /// value) on a PQ/HLG layer, and the stripes are BT.2408 graphics white encoded for
  /// that transfer (58 % PQ, 75 % HLG), not code 1.0. An unknown transfer is shown as
  /// Rec.709 (the layer decision is in `PortedLayerColorTests`, MonitorKitCoreTests).
  func testUnknownAndHDRSignalsAreNotRetaggedAsSDR() throws {
    let gpu = try requireGPU()
    for encoding in [SignalEncoding.unknown, .display(.pq), .display(.hlg)] {
      let signal = SignalDescription(range: .full, encoding: encoding)
      let frame = try Ported.wrapped(gpu, Self.flat(), signal: signal)
      var state = MonitorState()
      state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 50, opacity: 1)
      let pass = gpu.engine.makePass()
      let out = try gpu.render(frame, state: state, pass: pass)
      XCTAssertTrue(pass.status.isActive(.zebra1), "\(encoding)")
      XCTAssertEqual(out.rgb(8, 0), SIMD3(repeating: 192.0 / 255), "\(encoding): the signal's own code")
      let white = pass.colorPipeline.overlayColor(ColorRGB(r: 1, g: 1, b: 1))
      XCTAssertEqual(out.rgb(0, 0), Ported.vector(white), accuracy: 1e-5, "\(encoding): graphics white for the layer")
      let layer = MonitorOutputColor.signalNative.layer(for: signal)
      switch encoding {
      case .display(.pq):
        XCTAssertEqual(layer.kind, .pq)
        XCTAssertEqual(Double(out.rgb(0, 0).x), ColorMath.pqSignal(nits: 203), accuracy: 1e-4)
      case .display(.hlg):
        XCTAssertEqual(layer.kind, .hlg)
        // 203 cd/m² on the 1000 cd/m² HLG reference display is 0.7499 (BT.2408 rounds it to 75 %).
        XCTAssertEqual(out.rgb(0, 0).x, 0.75, accuracy: 2e-4)
      default:
        XCTAssertEqual(layer.kind, .sdr(.bt1886))
        XCTAssertEqual(out.rgb(0, 0), SIMD3(repeating: 1))
      }
    }
  }

  /// A legal v210 container carrying full-range LogC3 codes squeezed into 64…940:
  /// code 878 is native (878 - 64)/876 · 1023 = 950.6, classified against ARRI's
  /// independently rounded full table (yellow, 926…951), not a rescaled legal table.
  func testARRIFullRescaledToLegalUsesTheIndependentlyRoundedFullTable() throws {
    let gpu = try requireGPU()
    let frame = try Ported.wrapped(gpu, SyntheticFrame.neutral(.v210, width: 64, height: 32) { _, _ in 878 },
                                   signal: Ported.signal(Ported.logC(.arriLogC3, transport: .fullRescaledToLegal), range: .legal))
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = try Ported.constantLUT(gpu, Ported.flatLevels[0])
    var state = MonitorState()
    state.falseColor.mode = .arriLogC
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, feed: feed, pass: pass)
    let category = ARRIFalseColorProfile.logC3EI800.category(achromaticCode: (878.0 - 64) / 876 * 1023, range: .full)
    XCTAssertEqual(category, .yellow)
    XCTAssertEqual(ARRIFalseColorProfile.logC3EI800.category(achromaticCode: 878, range: .legal), .red, "the legal table would say red")
    XCTAssertEqual(out.rgb(0, 0), Ported.vector(try XCTUnwrap(category?.color)))
    XCTAssertTrue(pass.status.activeLabels.contains(ARRIFalseColorProfile.logC3EI800.displayName + " · full range"))
  }

  /// A 4:2:0 buffer whose chroma plane is one row short is refused before any GPU
  /// read. MonitorTools threw `MonitorPreviewError` from the renderer; MonitorKit
  /// refuses when the frame is wrapped (`MonitorKitError`). Both the CoreVideo
  /// buffer and hand-made textures of that shape are refused.
  func testMalformedPlanarHeightCannotBeRead() throws {
    let gpu = try requireGPU()
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 64 * 47, alignment: 64)
    memset(storage, 0, 64 * 47)
    var addresses: [UnsafeMutableRawPointer?] = [storage, storage.advanced(by: 64 * 32)]
    var widths = [64, 32]
    var heights = [32, 15]
    var strides = [64, 64]
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithPlanarBytes(
      nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, storage, 64 * 47, 2, &addresses, &widths, &heights,
      &strides, { _, data, _, _, _ in if let data { UnsafeMutableRawPointer(mutating: data).deallocate() } }, nil, nil, &image)
    if status == kCVReturnSuccess, let image {
      XCTAssertThrowsError(try MonitorFrame.wrap(image, cache: gpu.cache)) { XCTAssertTrue($0 is MonitorKitError, "\($0)") }
    } else {
      storage.deallocate()  // Some OS versions reject malformed planes themselves.
    }
    let luma = gpu.texture(.r8Unorm, 64, 32), chroma = gpu.texture(.rg8Unorm, 32, 15)
    XCTAssertThrowsError(try MonitorFrame(layout: .nv12, width: 64, height: 32, luma: luma, chroma: chroma, signal: .rec709)) {
      guard case MonitorKitError.invalidFrame(let reason) = $0 else { return XCTFail("\($0)") }
      XCTAssertTrue(reason.contains("chroma"), reason)
    }
  }

  /// Each published LogC3 and LogC4 zone edge, one code below and the last code
  /// inside, in legal and full v210 IOSurface buffers through the texture cache.
  /// Gaps show the expanded grey (LogC fills the container's range).
  func testEveryPublishedARRINativeTenBitBoundaryThroughIOSurfaces() throws {
    let gpu = try requireGPU()
    for profile in ARRIFalseColorProfile.allCases {
      let curve: LogCurve = profile == .logC3EI800 ? .arriLogC3 : .arriLogC4
      for range in [CodeRange.legal, .full] {
        let codes = profile.zones(range: range).flatMap { [max(0, Int($0.lower) - 1), Int($0.lower), Int($0.upper) - 1, Int($0.upper)] }
        let picture = SyntheticFrame.neutral(.v210, width: codes.count * 6, height: 2) { x, _ in codes[x / 6] }
        let frame = try Ported.wrapped(gpu, picture, signal: Ported.signal(Ported.logC(curve), range: range))
        var state = MonitorState()
        state.falseColor.mode = .arriLogC
        let out = try gpu.render(frame, state: state)
        for x in 0..<(codes.count * 6) {
          let code = codes[x / 6]
          let category = profile.category(achromaticCode: Double(code), range: range)
          let grey = try XCTUnwrap(range.normalizeLuma(code: Double(code), bitDepth: 10))
          assertPorted(out.rgb(x, 0), category?.color ?? Ported.grey(grey), exact: category != nil,
                       "\(profile.rawValue) \(range) native code \(code)")
        }
      }
    }
  }

  /// A declared S-Log3 source shown as the source picture without a display
  /// transform is a code-value Rec.709 view: the picture is the codes (192 stays
  /// 75.3 %), tagged Rec.709 SDR, and the status says so (MonitorTools' "code-value
  /// view" availability string is `MonitorStatus.isCodeValueView` and the `.picture`
  /// entry, R14). Zebras read the code IRE and source-stage peaking finds the source edge.
  func testDeclaredLogSourceShowsTheCodeValueViewWithZebraAndSourceFocus() throws {
    let gpu = try requireGPU()
    let signal = Ported.signal(Ported.sLog3Cine, range: .full)
    let frame = try Ported.wrapped(gpu, Ported.grey(width: 64, height: 32) { x, _ in x < 32 ? 0 : 192 }, signal: signal)
    var state = MonitorState()
    state.pictureStage = .source
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 50)
    state.focus.enabled = true
    state.focus.stage = .source
    let pass = gpu.engine.makePass()
    let out = try gpu.render(frame, state: state, pass: pass, analyze: true)
    XCTAssertEqual(MonitorOutputColor.recommended(for: signal), MonitorOutputColor(primaries: .rec709, encoding: .signalNative))
    XCTAssertEqual(MonitorOutputColor.signalNative.layer(for: signal), MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))
    XCTAssertTrue(pass.status.isCodeValueView)
    XCTAssertEqual(pass.status.pictureStage, .source)
    let label = try XCTUnwrap(pass.status.active.first { $0.tool == .picture }?.label)
    XCTAssertTrue(label.localizedCaseInsensitiveContains("code value"), label)
    XCTAssertGreaterThan(out.rgb(48, 0).x, 192.0 / 255, "zebra on the 75 IRE code")
    XCTAssertEqual(out.rgb(56, 0), SIMD3(repeating: 192.0 / 255), "between stripes: the code value itself")
    let edge = out.rgb(32, 16)
    XCTAssertGreaterThan(edge.x, edge.y)
    // A display transform maps the codes for viewing: no longer a code-value view.
    state.displayTransform.mode = .logToRec709
    _ = try gpu.render(frame, state: state, pass: pass, analyze: true)
    XCTAssertFalse(pass.status.isCodeValueView)
  }
}
