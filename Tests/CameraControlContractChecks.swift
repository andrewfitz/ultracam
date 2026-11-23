#if ULTRACAM_TEST_SUPPORT
import Foundation
import XCTest

@MainActor @objcMembers final class CameraControlContractChecks: XCTestCase {
    func testUnsignedValuesAndSecretRedaction() throws {
        let value = ControlValue.unsignedInteger(UInt64.max)
        XCTAssertEqual(try JSONDecoder().decode(ControlValue.self, from: JSONEncoder().encode(value)), value)
        let secret = ControlCredentials.usernamePassword(username: "private-user", password: "private-password")
        XCTAssertFalse(String(reflecting: secret).contains("private"))
        XCTAssertFalse(String(describing: secret).contains("private"))
        XCTAssertFalse(String(describing: secret.customMirror.children.map { String(describing: $0.value) }).contains("private"))
        XCTAssertFalse(ControlValue.decimal(.infinity).isValid)
    }

    func testPreparationIdentityAndTerminalGenerations() async throws {
        let descriptor = VendorDescriptor(id: "fake", displayName: "Fake", badgeText: "FAKE", signalHint: nil, sdkVersion: nil, sdkPresent: true)
        let camera = ControlCamera(pluginID: "fake", id: "identity", name: "Camera", transport: .network, address: "192.0.2.1", fingerprint: "pin")
        let plugin = FakeControlPlugin(descriptor: descriptor, cameras: [camera], properties: [
            .init(id: "fake:exposure", label: "Exposure", writable: true, value: .unsignedInteger(0))
        ])
        let prepared = try await plugin.prepare(.endpoint(.init(address: camera.address, expectedIdentity: camera.id, authenticationMode: .usernamePassword)))
        XCTAssertEqual(prepared.pairingRequirement, .usernamePassword(fingerprint: "pin"))
        do {
            _ = try await plugin.prepare(.endpoint(.init(address: camera.address, expectedIdentity: "different", authenticationMode: .none)))
            XCTFail("Mismatched endpoint identity was accepted")
        } catch let error as ControlError { XCTAssertEqual(error.code, .changedIdentity) }
        try await plugin.connect(feedID: "feed", generation: 1, camera: camera, credentials: nil)
        try await plugin.disconnect(feedID: "feed", generation: 1)
        do {
            try await plugin.connect(feedID: "feed", generation: 1, camera: camera, credentials: nil)
            XCTFail("Retired generation connected")
        } catch let error as ControlError { XCTAssertEqual(error.code, .staleGeneration) }
        try await plugin.connect(feedID: "feed", generation: 2, camera: camera, credentials: nil)
        try await plugin.disconnect(feedID: "feed", generation: 1)
        try await plugin.set("fake:exposure", value: .unsignedInteger(UInt64.max), feedID: "feed", generation: 2)
        let properties = try await plugin.properties(feedID: "feed", generation: 2)
        XCTAssertEqual(properties.first?.value, .unsignedInteger(UInt64.max))
        try await plugin.shutdown()
        do { _ = try await plugin.discover(); XCTFail("Shutdown admitted discovery") }
        catch let error as ControlError { XCTAssertEqual(error.code, .invalidState) }
    }
    func testFakeControlRejectsPinChangesAndRetiresCancelledConnects() async throws {
        let descriptor = VendorDescriptor(id: "fake", displayName: "Fake", badgeText: "FAKE", signalHint: nil, sdkVersion: nil, sdkPresent: true)
        let camera = ControlCamera(pluginID: "fake", id: "body", name: "Camera", transport: .usb, address: "usb", fingerprint: "current")
        let plugin = FakeControlPlugin(descriptor: descriptor, cameras: [camera])
        var stalePin = camera
        stalePin.fingerprint = "previous"
        do {
            _ = try await plugin.prepare(.camera(stalePin))
            XCTFail("Preparation accepted a changed fingerprint")
        } catch let error as ControlError { XCTAssertEqual(error.code, .changedIdentity) }
        let cancelled = Task { try await plugin.connect(feedID: "feed", generation: 1, camera: camera, credentials: nil) }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("The cancelled generation connected")
        } catch let error as ControlError { XCTAssertEqual(error.code, .cancelled) }
        do {
            try await plugin.connect(feedID: "feed", generation: 1, camera: camera, credentials: nil)
            XCTFail("The cancelled generation was reusable")
        } catch let error as ControlError { XCTAssertEqual(error.code, .staleGeneration) }
        try await plugin.connect(feedID: "feed", generation: 2, camera: camera, credentials: nil)
        try await plugin.disconnect(feedID: "feed", generation: 2)
        plugin.replaceCameras([])
        do {
            try await plugin.connect(feedID: "feed", generation: 3, camera: camera, credentials: nil)
            XCTFail("An absent fixture camera connected")
        } catch let error as ControlError { XCTAssertEqual(error.code, .removed) }
    }
    func testFakeControlEnforcesAdvertisedCapability() async throws {
        let descriptor = VendorDescriptor(id: "fake", displayName: "Fake", badgeText: "FAKE", signalHint: nil, sdkVersion: nil, sdkPresent: true)
        let camera = ControlCamera(pluginID: "fake", id: "body", name: "Camera", transport: .usb, address: "usb", fingerprint: nil)
        let plugin = FakeControlPlugin(descriptor: descriptor, cameras: [camera], properties: [
            .init(id: "gain", label: "Gain", writable: true, value: .integer(1),
                range: .init(minimum: .integer(1), maximum: .integer(4), step: nil)),
            .init(id: "mode", label: "Mode", writable: true, value: .choice("auto"),
                options: [.init(id: "auto", label: "Auto", value: .choice("auto"))]),
        ])
        try await plugin.connect(feedID: "feed", generation: 1, camera: camera, credentials: nil)
        let invalidWrites: [(String, ControlValue)] = [("gain", .integer(5)), ("gain", .decimal(2)), ("mode", .choice("other"))]
        for (property, value) in invalidWrites {
            do {
                try await plugin.set(property, value: value, feedID: "feed", generation: 1)
                XCTFail("Fixture accepted a value outside the advertised capability")
            } catch let error as ControlError { XCTAssertEqual(error.code, .invalidRequest) }
        }
        try await plugin.set("gain", value: .integer(4), feedID: "feed", generation: 1)
        let properties = try await plugin.properties(feedID: "feed", generation: 1)
        XCTAssertEqual(properties.map(\.value), [.integer(4), .choice("auto")])
    }
}
#endif
