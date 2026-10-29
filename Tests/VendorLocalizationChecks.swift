#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class VendorLocalizationChecks: XCTestCase {
  func testExplicitKeyResolvesAndFallbackNeverBecomesAKey() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "\"sony.control.aperture\" = \"Localized aperture\";\n\"Raw camera value\" = \"Must not be used\";".write(
      to: directory.appendingPathComponent("SonyControl.strings"), atomically: true, encoding: .utf8)
    let bundle = try XCTUnwrap(Bundle(path: directory.path))
    var property = ControlProperty(id: "aperture", label: "Aperture", writable: true,
      value: .text("Raw camera value"), currentValueLabel: "Raw camera value", labelKey: "sony.control.aperture", localizationTable: "SonyControl")
    XCTAssertEqual(property.localizedLabel(in: bundle), "Localized aperture")
    XCTAssertEqual(property.currentValueLabel, "Raw camera value")
    property.labelKey = "missing.key"
    XCTAssertEqual(property.localizedLabel(in: bundle), "Aperture")
    XCTAssertEqual(VendorDisplayLocalization.resolve(key: nil, fallback: "Raw camera value", in: bundle), "Raw camera value")
  }
  func testVendorSettingLegacyFallbackAndExplicitKeys() throws {
    let legacy = VendorSetting(id: "fixture.mode", labelKey: "Input mode", value: .boolean(true),
      allowedValues: .unrestricted, mutable: true, availabilityReason: nil, interruptsCapture: false)
    XCTAssertEqual(legacy.localizedLabel(), "Input mode")
    let keyed = VendorSetting(id: "fixture.mode", labelKey: "fixture.setting.mode", value: .boolean(true),
      allowedValues: .unrestricted, mutable: true, availabilityReason: nil, interruptsCapture: false,
      labelFallback: "Input mode", localizationTable: "MissingVendorTable")
    XCTAssertEqual(keyed.localizedLabel(), "Input mode")
    let choice = VendorSetting.Choice(id: "hdmi", label: "HDMI", labelKey: "fixture.connector.hdmi", localizationTable: "MissingVendorTable")
    XCTAssertEqual(choice.localizedLabel(), "HDMI")
  }
  func testLegacyPayloadAndDescriptorDefaultsPreserveDisplayValues() throws {
    let option = ControlOption(id: "value", label: "Native value", value: .unsignedInteger(UInt64.max))
    let decoded = try JSONDecoder().decode(ControlOption.self, from: JSONEncoder().encode(option))
    XCTAssertNil(decoded.labelKey)
    XCTAssertEqual(decoded.localizedLabel(), "Native value")
    let descriptor = VendorDescriptor(id: "fixture", displayName: "Fixture", badgeText: "FIX", signalHint: "Signal hint", sdkVersion: nil, sdkPresent: true)
    XCTAssertEqual(descriptor.localizedDisplayName(), "Fixture")
    XCTAssertEqual(descriptor.localizedSignalHint(), "Signal hint")
  }
}
#endif
