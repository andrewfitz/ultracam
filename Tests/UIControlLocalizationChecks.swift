#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class UIControlLocalizationChecks: XCTestCase {
  func testNamedTablePresentationLocalizesMetadataAndPreservesSDKValues() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try #""property.key" = "Localized property"; "option.key" = "Localized option"; "SDK value" = "Wrong replacement";"#.write(to: directory.appendingPathComponent("VendorControls.strings"), atomically: true, encoding: .utf8)
    let bundle = try XCTUnwrap(Bundle(path: directory.path))
    let option = ControlOption(id: "on", label: "Option fallback", value: .choice("on"), labelKey: "option.key", localizationTable: "VendorControls")
    var property = ControlProperty(id: "fixture:property", label: "Property fallback", writable: true, value: .choice("on"), options: [option], overlayOrder: 0, labelKey: "property.key", localizationTable: "VendorControls")
    XCTAssertEqual(UIControlPresentation.overlay([property], in: bundle), "Localized property Localized option")
    property.currentValueLabel = "SDK value"
    XCTAssertEqual(UIControlPresentation.overlay([property], in: bundle), "Localized property SDK value")
    property.labelKey = "missing.key"
    XCTAssertEqual(UIControlPresentation.overlay([property], in: bundle), "Property fallback SDK value")
  }
}
#endif
