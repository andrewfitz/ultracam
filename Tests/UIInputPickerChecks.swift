#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@objcMembers final class UIInputPickerChecks: XCTestCase {
    func testVendorGroupsPreserveInputIDsAndSourceOrder() {
        let first = VendorDescriptor(id: "first", displayName: "First", badgeText: "F", signalHint: nil, sdkVersion: nil, sdkPresent: true)
        let second = VendorDescriptor(id: "second", displayName: "Second", badgeText: "S", signalHint: nil, sdkVersion: nil, sdkPresent: true)
        let inputs = [UIInput(id: "first:opaque:a", name: "Same", vendor: first), UIInput(id: "second:b", name: "Same", vendor: second), UIInput(id: "first:opaque:c", name: "Other", vendor: first)]
        let groups = UIInputPicker.groups(inputs)
        XCTAssertEqual(groups.map(\.id), ["first", "second"])
        XCTAssertEqual(groups.map(\.title), ["First", "Second"])
        XCTAssertEqual(groups[0].inputs.map(\.id), ["first:opaque:a", "first:opaque:c"])
        XCTAssertNil(UIInputPicker.groups([inputs[0]]).first?.title)
    }
    func testSupportedModesProjectionPreservesPluginTextAndExplainsUnknowns() {
        let device = CaptureDeviceInfo(id: "fixture", name: "Fixture", connectors: [], shareable: true,
          mayPause: nil, supportedModes: "1920 × 1080 at 25 fps; 10-bit packed YUV")
        let projected = InputDevice(device)
        let input = UIInput(id: projected.id, name: projected.name, supportedModes: projected.supportedModes)
        XCTAssertEqual(UIInputPicker.supportedModes(input), device.supportedModes)
        XCTAssertTrue(UIInputPicker.supportedModes(nil).contains("Choose an input"))
        XCTAssertTrue(UIInputPicker.supportedModes(UIInput(id: "unknown", name: "Unknown")).contains("does not report"))
    }
    func testShareableInputRemainsSelectableWhenAssignedToPeer() {
        let shared = UIInput(id: "network:shared", name: "Shared", shareable: true)
        XCTAssertTrue(UIInputPicker.selectable(shared, usedBy: "Peer", selectedID: nil))
        XCTAssertFalse(UIInputPicker.selectable(.init(id: "capture:exclusive", name: "Exclusive"), usedBy: "Peer", selectedID: nil))
        XCTAssertTrue(UIInputPicker.selectable(.init(id: "capture:exclusive", name: "Exclusive"), usedBy: "Peer", selectedID: "capture:exclusive"))
    }
}
#endif
