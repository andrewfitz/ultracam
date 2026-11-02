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

  /// The picture overlay shows a value in camera notation alone; VoiceOver keeps every full name.
  func testOverlayShowsCameraNotationWithoutLabels() {
    func field(_ label: String, _ value: String, _ order: Int) -> ControlProperty {
      ControlProperty(id: "fixture:\(order)", label: label, writable: false, value: .text(value), overlayOrder: order, currentValueLabel: value)
    }
    let fields = [field("ISO", "800", 0), field("Aperture", "ƒ/2.8", 1), field("Shutter speed", "1/50 s", 2),
      field("Shutter angle", "180°", 3), field("White balance", "Daylight", 4), field("Color temperature", "5600 K", 5),
      field("Focus mode", "AF-C", 6)]
    XCTAssertEqual(UIControlPresentation.overlayPieces(fields), ["ISO 800", "ƒ/2.8", "1/50", "180°", "White balance Daylight", "5600 K", "AF-C"])
    XCTAssertEqual(UIControlPresentation.overlayPieces(fields, compact: true), ["ISO 800", "ƒ/2.8", "1/50"])
    XCTAssertEqual(UIControlPresentation.overlay(fields, compact: true), "ISO 800, Aperture ƒ/2.8, Shutter speed 1/50 s")
    XCTAssertEqual(UIControlPresentation.notation("f/4"), "f/4")
    XCTAssertEqual(UIControlPresentation.notation("1/100"), "1/100")
    XCTAssertEqual(UIControlPresentation.notation("0.5 s"), "0.5 s")
    XCTAssertEqual(UIControlPresentation.notation("MF"), "MF")
    XCTAssertNil(UIControlPresentation.notation("Closed"), "An iris that's closed keeps its name")
    XCTAssertNil(UIControlPresentation.notation("Bulb"))
    XCTAssertNil(UIControlPresentation.notation("—"))
    XCTAssertNil(UIControlPresentation.notation("Auto"))
  }
}
#endif
