import XCTest

@testable import MonitorKitCore

/// CPU halves of the MonitorTools cases ported in `MonitorKitTests/Ported*.swift`
/// (map §8.2): the conventions those GPU ports rely on, pinned against the
/// MonitorTools definitions so a reader can see each mapping is exact.
final class PortedReferenceTests: XCTestCase {
  /// MonitorTools' `MonitorSourceLogMapping` (`NativeLogCodeMapping`) and
  /// MonitorKit's `LogTransport` give the same native S-Log3 value at every 10-bit
  /// code: `.native10Bit` in a legal container is code/1023 (Sony stores codes
  /// verbatim), `.fullRescaledToLegal10Bit` is (code - 64)/876.
  func testMonitorToolsLogMappingsAreMonitorKitsTransports() throws {
    for code in 0..<1024 {
      let c = Double(code)
      let legal = try XCTUnwrap(CodeRange.legal.normalizeLuma(code: c, bitDepth: 10))
      let full = try XCTUnwrap(CodeRange.full.normalizeLuma(code: c, bitDepth: 10))
      let native = try XCTUnwrap(NativeLogCodeMapping.native10Bit.nativeNormalized(transportCode: c))
      let rescaled = try XCTUnwrap(NativeLogCodeMapping.fullRescaledToLegal10Bit.nativeNormalized(transportCode: c))
      XCTAssertEqual(DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .native), native, accuracy: 1e-14, "\(code)")
      XCTAssertEqual(DecodeReference.nativeLog(expanded: full, range: .full, transport: .native), native, accuracy: 1e-14, "\(code)")
      XCTAssertEqual(DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .fullRescaledToLegal), rescaled, accuracy: 1e-14)
      // Pattern 2 colours agree under either convention.
      XCTAssertEqual(
        SonySLog3FalseColor.category(nativeSignalLuma: native),
        SonySLog3FalseColor.category(nativeSignalLuma: DecodeReference.nativeLog(expanded: legal, range: .legal, transport: .native)))
    }
  }

  /// MonitorTools' zebra band `(threshold, width)` is centred: [t - w/2, t + w/2).
  /// MonitorKit's `ZebraSet.range` is the half-width, so `(70, 10)` is `(70, 5)`.
  func testMonitorToolsZebraBandIsAHalfWidthRange() {
    for (threshold, width) in [(70.0, 10.0), (50, 4), (95, 0), (100, 30)] {
      let set = ZebraSet(mode: .band, level: threshold, range: width / 2)
      let lower = ZebraSet(mode: .lowerLimit, level: threshold)
      var ire = -20.0
      while ire <= 120 {
        XCTAssertEqual(set.covers(ire: ire), ColorMath.zebra(ire: ire, threshold: threshold, width: width, above: false), "\(threshold)±\(width) at \(ire)")
        XCTAssertEqual(lower.covers(ire: ire), ColorMath.zebra(ire: ire, threshold: threshold, width: width, above: true))
        ire += 0.125
      }
    }
    // The original's two codes: 166 (65.1 IRE) inside, 196 (76.9 IRE) outside.
    let set = ZebraSet(mode: .band, level: 70, range: 5)
    XCTAssertTrue(set.covers(ire: 166.0 / 255 * 100))
    XCTAssertFalse(set.covers(ire: 196.0 / 255 * 100))
  }

  /// The Scharr oracle's constants are MonitorKit's at the default sensitivity:
  /// threshold 0.17, ramp 0.085 (t/2), support 0.02.
  func testFocusConstantsMatchMonitorTools() {
    let focus = FocusSettings()
    XCTAssertEqual(focus.sensitivity, 0.5)
    XCTAssertEqual(focus.edgeThreshold, 0.17, accuracy: 1e-15)
    XCTAssertEqual(focus.edgeThreshold * 0.5, 0.085, accuracy: 1e-15)
    XCTAssertEqual(focus.noiseRejection, 0.02)
  }

  /// `testARRIFullRescaledToLegalUsesIndependentlyRoundedFullTable`'s arithmetic: a
  /// rescaled legal 878 is native 950.6, yellow in the full table; rescaling the
  /// rounded legal table instead would call it red.
  func testRescaledLegalLogC3ReadsTheFullTable() throws {
    let encoding = LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3, transport: .fullRescaledToLegal)
    let signal = SignalDescription(range: .legal, encoding: .log(encoding))
    XCTAssertTrue(FalseColorTable.usesFullRangeARRI(signal: signal, layout: .v210))
    let e = try XCTUnwrap(CodeRange.legal.normalizeLuma(code: 878, bitDepth: 10))
    let t = LogCurve.arriLogC3.signal(expanded: e, range: .legal, transport: .fullRescaledToLegal)
    XCTAssertEqual(t * 1023, 950.6, accuracy: 0.05)
    XCTAssertEqual(ARRIFalseColorProfile.logC3EI800.category(achromaticCode: t * 1023, range: .full), .yellow)
    XCTAssertEqual(ARRIFalseColorProfile.logC3EI800.category(achromaticCode: 878, range: .legal), .red)
  }

  /// MonitorTools' layer decision (map §2, pinned by
  /// `testUnknownOrHDRTransferDoesNotGetRetaggedAsSDR` and the MonitorToolsUI layer
  /// cases) from MonitorKit's `MonitorOutputColor.signalNative.layer(for:)`:
  /// declared log or unknown → Rec.709 SDR; HLG → EDR HLG; PQ → EDR PQ with HDR10
  /// metadata (0.005…1000 cd/m², optical scale 100); BT.2020 primaries with an SDR
  /// transfer → BT.2020 SDR; anything else Rec.709.
  func testLayerColourFollowsTheFiveWayDecision() {
    func layer(_ s: SignalDescription) -> MonitorLayerColor { MonitorOutputColor.signalNative.layer(for: s) }
    let rec709 = MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886))
    for s in [
      SignalDescription(encoding: .log(.sLog3SGamut3Cine)), SignalDescription(encoding: .unknown), .rec709,
      SignalDescription(encoding: .log(LogEncoding(curve: .arriLogC4, gamut: .arriWideGamut4))),
    ] {
      XCTAssertEqual(layer(s), rec709, "\(s.encoding)")
      XCTAssertEqual(layer(s).pixelFormat, .bgr10a2Unorm)
      XCTAssertFalse(layer(s).wantsExtendedDynamicRange)
      XCTAssertNil(layer(s).edrMetadata)
      XCTAssertEqual(layer(s).colorSpace, .itur709)
    }
    let hlg = layer(SignalDescription(matrix: .bt2020, encoding: .display(.hlg)))
    XCTAssertEqual(hlg.colorSpace, .itur2100HLG)
    XCTAssertEqual(hlg.pixelFormat, .rgba16Float)
    XCTAssertTrue(hlg.wantsExtendedDynamicRange)
    XCTAssertEqual(hlg.edrMetadata, .hlg)
    let pq = layer(SignalDescription(matrix: .bt2020, encoding: .display(.pq)))
    XCTAssertEqual(pq.colorSpace, .itur2100PQ)
    XCTAssertEqual(pq.pixelFormat, .rgba16Float)
    XCTAssertTrue(pq.wantsExtendedDynamicRange)
    XCTAssertEqual(pq.edrMetadata, .hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100))
    let sdr2020 = layer(SignalDescription(matrix: .bt2020, encoding: .display(.bt709), primaries: .rec2020))
    XCTAssertEqual(sdr2020.colorSpace, .itur2020)
    XCTAssertEqual(sdr2020.pixelFormat, .bgr10a2Unorm)
    XCTAssertNil(sdr2020.edrMetadata)
    // HDR is never retagged as SDR, whatever the matrix label.
    for t in [DisplayTransfer.pq, .hlg] {
      for m in [YCbCrMatrix.bt709, .bt2020] {
        XCTAssertTrue(layer(SignalDescription(matrix: m, encoding: .display(t))).wantsExtendedDynamicRange, "\(t) \(m)")
      }
    }
  }
}
