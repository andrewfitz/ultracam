import MonitorKit
import XCTest

@objcMembers final class MonitorDeclaredSignalChecks: XCTestCase {
  func testDeclaredColourOverridesConflictingBufferTags() {
    let declared = Colorimetry(primaries: .p3D65, transfer: .hlg, matrix: .rec2020,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .top)
    let value = MonitorFeedHost.declaredSignal(declared, over: SignalDescription())
    XCTAssertEqual(value.range, .full)
    XCTAssertEqual(value.primaries, .displayP3)
    XCTAssertEqual(value.encoding, .display(.hlg))
    XCTAssertEqual(value.matrix, .bt2020)
    XCTAssertEqual(value.chromaSiting, .center)
    XCTAssertEqual(value.chromaVerticalSiting, .top)
  }

  func testLogTransferNeverInventsCameraGamut() {
    let declared = Colorimetry(primaries: .unspecified, transfer: .sLog3, matrix: .rec709,
      range: .video, horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let native = MonitorFeedHost.declaredSignal(declared, over: SignalDescription(encoding: .display(.hlg)))
    XCTAssertEqual(native.encoding, .unknown)
    let camera = MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine")
    XCTAssertEqual(camera.applied(to: native).encoding,
      .log(LogEncoding(curve: .sLog3, gamut: .sGamut3Cine)))
    XCTAssertEqual(MonitorFeedHost.declaredSignal(nil, over: native), native)
  }
  func testEveryNewDeclaredLogCurveAndGamutMapsExactly() {
    let combinations: [(Colorimetry.Transfer, Colorimetry.Primaries, LogCurve, ColorGamut)] = [
      (.sLog3, .sGamut3, .sLog3, .sGamut3),
      (.sLog3, .sGamut3Cine, .sLog3, .sGamut3Cine),
      (.arriLogC3, .arriWideGamut3, .arriLogC3, .arriWideGamut3),
      (.arriLogC4, .arriWideGamut4, .arriLogC4, .arriWideGamut4),
      (.canonLog, .canonCinemaGamut, .canonLog, .canonCinemaGamut),
      (.canonLog2, .canonCinemaGamut, .canonLog2, .canonCinemaGamut),
      (.canonLog3, .canonCinemaGamut, .canonLog3, .canonCinemaGamut),
      (.vLog, .vGamut, .vLog, .vGamut),
      (.blackmagicFilmGen5, .blackmagicWideGamutGen5, .blackmagicFilmGen5, .blackmagicWideGamutGen5),
      (.redLog3G10, .redWideGamutRGB, .redLog3G10, .redWideGamutRGB)
    ]
    for (transfer, primaries, curve, gamut) in combinations {
      let declared = Colorimetry(primaries: primaries, transfer: transfer, matrix: .rec709,
        range: .full, horizontalChromaSiting: .left, verticalChromaSiting: .center)
      let value = MonitorFeedHost.declaredSignal(declared, over: SignalDescription())
      XCTAssertEqual(value.encoding, .log(LogEncoding(curve: curve, gamut: gamut)))
      XCTAssertEqual(value.range, .full)
      XCTAssertNil(value.primaries)
    }
  }

}
