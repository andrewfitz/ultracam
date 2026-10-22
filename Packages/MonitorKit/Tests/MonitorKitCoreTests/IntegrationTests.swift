import XCTest

@testable import MonitorKitCore

/// Shared rules that used to be copied between the picture pass and MonitorKitUI.
final class IntegrationTests: XCTestCase {
  /// ARRI's full-range tables follow how the codes reached us: a full or float
  /// container, or full-range codes squeezed into a legal one (ARRI-FC §3.1).
  func testFullRangeARRITableRule() {
    let logC3 = LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3)
    let rescaled = LogEncoding(curve: .arriLogC3, gamut: .arriWideGamut3, transport: .fullRescaledToLegal)
    let legal = SignalDescription(encoding: .log(logC3))
    let full = SignalDescription(range: .full, encoding: .log(logC3))
    let squeezed = SignalDescription(encoding: .log(rescaled))
    XCTAssertFalse(FalseColorTable.usesFullRangeARRI(signal: legal))
    XCTAssertFalse(FalseColorTable.usesFullRangeARRI(signal: legal, layout: .v210))
    XCTAssertTrue(FalseColorTable.usesFullRangeARRI(signal: legal, layout: .rgb(bitDepth: 16, float: true)))
    XCTAssertFalse(FalseColorTable.usesFullRangeARRI(signal: legal, layout: .rgb(bitDepth: 16, float: false)))
    XCTAssertTrue(FalseColorTable.usesFullRangeARRI(signal: full, layout: .v210))
    XCTAssertTrue(FalseColorTable.usesFullRangeARRI(signal: squeezed, layout: .v210))
  }
}
