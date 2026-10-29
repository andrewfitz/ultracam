#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class UIVendorSettingsLocalizationChecks: XCTestCase {
  func testNamedTableProjectionLocalizesOnlyExplicitMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try #""capture.setting" = "Localized setting"; "capture.choice" = "Localized choice"; "capture.reason" = "Localized reason"; "Legacy English" = "Incorrect inferred lookup"; "SDK value" = "Incorrect SDK lookup";"#.write(to: directory.appendingPathComponent("CaptureControls.strings"), atomically: true, encoding: .utf8)
    let bundle = try XCTUnwrap(Bundle(path: directory.path))
    let choice = VendorSetting.Choice(id: "native-choice", label: "Choice fallback", labelKey: "capture.choice", localizationTable: "CaptureControls")
    let setting = VendorSetting(id: "fixture:setting", labelKey: "capture.setting", value: .choice("native-choice"), allowedValues: .choices([choice]), mutable: false, availabilityReason: "Reason fallback", interruptsCapture: true, labelFallback: "Setting fallback", localizationTable: "CaptureControls", availabilityReasonKey: "capture.reason")
    let property = UIVendorSettingsPresentation.property(setting, in: bundle)
    XCTAssertEqual(property.label, "Localized setting")
    XCTAssertEqual(property.options.first?.label, "Localized choice")
    XCTAssertEqual(property.unavailableReason, "Localized reason")
    XCTAssertEqual(property.value, .choice("native-choice"))
    let legacy = VendorSetting(id: "fixture:legacy", labelKey: "Legacy English", value: .text("SDK value"), allowedValues: .unrestricted, mutable: true, availabilityReason: nil, interruptsCapture: false)
    let untouched = UIVendorSettingsPresentation.property(legacy, in: bundle)
    XCTAssertEqual(untouched.label, "Legacy English")
    XCTAssertEqual(untouched.value, .text("SDK value"))
  }
  func testMissingKeysUseEnglishFallbackAndKeepUnsignedValue() {
    let setting = VendorSetting(id: "fixture:integer", labelKey: "absent.key", value: .unsigned(UInt64.max), allowedValues: .unrestricted, mutable: true, availabilityReason: "English reason", interruptsCapture: false, labelFallback: "English label", localizationTable: "AbsentTable", availabilityReasonKey: "absent.reason")
    let property = UIVendorSettingsPresentation.property(setting)
    XCTAssertEqual(property.label, "English label")
    XCTAssertEqual(property.unavailableReason, "English reason")
    XCTAssertEqual(property.value, .unsignedInteger(UInt64.max))
  }
}
#endif
