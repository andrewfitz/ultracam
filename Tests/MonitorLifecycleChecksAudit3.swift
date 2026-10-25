import Foundation
import MonitorKitCore
import XCTest

// Audit round 3 (app glue): regressions for bugs found in the app's MonitorKit glue.
extension MonitorLifecycleChecks {
  /// Custom false colour with no bands draws nothing (MonitorKit reports it
  /// unavailable, the editor says "shows nothing until you add one"), so it
  /// must not hide zebra; with a band it is drawn and zebra steps aside.
  func testAudit3CustomFalseColorWithoutBandsKeepsZebra() {
    var value = MonitorFeedPreferences()
    value.toolsEnabled = true
    value.state.zebras[0].enabled = true
    value.state.falseColor.mode = .custom
    value.state.falseColor.customBands = []
    XCTAssertTrue(value.surfaceState(isProgram: false).zebras[0].enabled, "No bands: zebra still shows")
    XCTAssertTrue(value.surfaceState(isProgram: true).zebras[0].enabled, "No bands on Program: zebra still shows")
    value.state.falseColor.customBands = [
      FalseColorBand(lower: 90, upper: .infinity, color: ColorRGB(r: 1, g: 0, b: 0))
    ]
    XCTAssertFalse(value.surfaceState(isProgram: false).zebras[0].enabled, "A drawn band suppresses zebra")
    XCTAssertFalse(value.surfaceState(isProgram: true).zebras[0].enabled)
    // Choosing Custom in the picker is still allowed with no bands yet.
    XCTAssertTrue(MonitorFeedPreferences.falseColorModeIsAvailable(.custom, profile: nil))
  }
}
