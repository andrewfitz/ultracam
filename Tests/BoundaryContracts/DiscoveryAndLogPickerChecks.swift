#if DISCOVERY_AND_LOG_PICKER_CHECKS
import XCTest

@objcMembers final class DiscoveryAndLogPickerChecks: XCTestCase {
  @MainActor func testDiscoveryAdoptsSupportedModesOnlyChange() {
    let model = DiscoveryFixture()
    model.observeDevices([InputDevice(id: "fixture:input", name: "Input", supportedModes: "1080p")])
    model.observeDevices([InputDevice(id: "fixture:input", name: "Input", supportedModes: "2160p")])
    XCTAssertEqual(model.devices.first?.supportedModes, "2160p")
    XCTAssertEqual(model.bridgeInputs.first?.supportedModes, "2160p")
  }

  func testMonitorPickerIncludesEveryCatalogLogProfile() {
    let nonLog: Set<Colorimetry.Transfer> = [.unspecified, .rec709, .sRGB, .linear, .pq, .hlg]
    let logs = SourceColorSpaceCatalog.entries.filter { !nonLog.contains($0.color.transfer) }
    XCTAssertEqual(logs.count, 10)
    for entry in logs {
      XCTAssertTrue(UIFalseColorChoices.profiles.contains { $0.id == entry.id && !$0.title.isEmpty }, entry.id)
    }
    XCTAssertFalse(UIFalseColorChoices.profiles.contains { $0.id == "unknown-camera-log" })
    XCTAssertFalse(UIFalseColorChoices.profiles.contains { $0.id == "rec709-video" })
  }
}
#endif
