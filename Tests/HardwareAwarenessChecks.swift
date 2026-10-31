#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import Foundation
import XCTest

/// Hardware awareness: the plugin API's status and body additions, absent hardware by its last
/// known name, nicknames that survive a relaunch, the battery's unit, body notices, a build
/// without a control SDK reading as normal, the idle reader's gating, and Copy Diagnostics.
/// Scripted plugins only: nothing opens a device or contacts a camera body.
@MainActor @objcMembers final class HardwareAwarenessChecks: XCTestCase {
  private static let hint = "Check the fixture's cable."
  private static let captureDescriptor = VendorDescriptor(id: "fake", displayName: "Fixture Capture", badgeText: "FIX",
    signalHint: nil, sdkVersion: "1.0", sdkPresent: true, missingDeviceHint: hint)
  private static let controlDescriptor = VendorDescriptor(id: "body", displayName: "Fixture Bodies", badgeText: "BODY",
    signalHint: nil, sdkVersion: "2.0", sdkPresent: true, missingDeviceHint: "Turn the body's remote on.")
  private static let body = ControlCamera(pluginID: "body", id: "aa:bb", name: "Body A", transport: .network,
    address: "192.0.2.10", model: "Model X")

  private struct Rig {
    let model: AppModel
    let capture: FakeCapturePlugin
    let control: FakeControlPlugin
    let defaults: UserDefaults
  }

  private func defaults() -> UserDefaults {
    let suite = "org.ultracam.tests.hardware.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    return UserDefaults(suiteName: suite)!
  }

  private func rig(defaults: UserDefaults? = nil, controlPresent: Bool = true, properties: [ControlProperty] = []) throws -> Rig {
    let defaults = defaults ?? self.defaults()
    let format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.slowDuration))
    let capture = FakeCapturePlugin(format: format, audio: .absent, deviceIDs: ["fake:left", "fake:right"],
      descriptor: Self.captureDescriptor)
    capture.setDetails(.init(name: "Recorder", model: "Recorder 12G", modes: [format], connectors: [.hdmi]), for: "fake:left")
    capture.setDetails(.init(name: "Recorder", model: "Recorder 12G"), for: "fake:right")
    capture.setConnected(true)
    var descriptor = Self.controlDescriptor
    if !controlPresent {
      descriptor = VendorDescriptor(id: "body", displayName: "Fixture Bodies", badgeText: "BODY", signalHint: nil,
        sdkVersion: nil, sdkPresent: false)
    }
    let control = FakeControlPlugin(descriptor: descriptor, cameras: [Self.body], properties: properties)
    let registry = try VendorRegistry(capture: [capture], control: [control])
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("No installer requests in this fixture") },
      submit: { _ in XCTFail("No installer submissions in this fixture") },
      queryProperties: { $0([]) }))
    var hardware = AppHardware.registry(registry)
    hardware.captureServices = AppHardware.offline.captureServices
    let model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: SyntheticRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer, hardware: hardware)
    return Rig(model: model, capture: capture, control: control, defaults: defaults)
  }

  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
  }

  // MARK: API additions

  func testStatusDispatchesThroughThePluginProtocolAndUnknownIsNil() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant(VideoContract.slowDuration))
    let plugin: any CaptureSourcePlugin = FakeCapturePlugin(format: format, audio: .absent)
    XCTAssertNil(plugin.status(deviceID: "fake:fixture"), "No reading yet is unknown")
    let fake = plugin as! FakeCapturePlugin
    let status = CaptureDeviceStatus(availability: .free, link: .thunderbolt, connector: .hdmi, signalLocked: nil)
    fake.setStatus(status, for: "fake:fixture")
    // A requirement, not only an extension: an existential call reaches the plugin's own.
    XCTAssertEqual(plugin.status(deviceID: "fake:fixture"), status)
    XCTAssertTrue(DeviceSeverity.info < .notice && DeviceSeverity.warning < .critical)
    XCTAssertEqual(UIHardwareDevice(id: "fake:fixture", name: "A", present: true, status: status).summary, ["HDMI", "Thunderbolt"],
      "An unknown lock says nothing rather than No signal")
  }

  func testSavedAssignmentsWithoutModelOrFirmwareStillDecode() throws {
    let legacy = #"{"pluginID":"body","id":"aa:bb","name":"Body A","transport":"network","address":"192.0.2.10","authenticationMode":"none"}"#
    let camera = try JSONDecoder().decode(ControlCamera.self, from: Data(legacy.utf8))
    XCTAssertNil(camera.model)
    XCTAssertNil(camera.firmware)
    let property = #"{"id":"iso","label":"ISO","writable":true,"value":{"unsignedInteger":{"_0":800}},"options":[],"role":"standard"}"#
    let decoded = try JSONDecoder().decode(ControlProperty.self, from: Data(property.utf8))
    XCTAssertNil(decoded.severity)
    XCTAssertNil(decoded.unit)
    XCTAssertNil(decoded.suggestedSourceProfileID)
  }

  // MARK: Absent hardware and nicknames

  func testAbsentAssignedHardwareIsListedByLastKnownNameWithItsPluginsHint() async throws {
    let defaults = defaults()
    defaults.set(["fake:gone": "Spare Recorder"], forKey: HardwareInventory.lastKnownNamesKey)
    let rig = try rig(defaults: defaults)
    let camera = rig.model.selectedFeedID
    rig.model.updateCamera(camera) { $0.selectedDevice = "fake:gone" }
    let groups = UISettingsHardwareGroups(model: rig.model)
    let devices = try XCTUnwrap(groups.capture.first { $0.vendor.id == "fake" }).devices
    let absent = try XCTUnwrap(devices.first { $0.id == "fake:gone" })
    XCTAssertFalse(absent.present)
    XCTAssertEqual(absent.health, .absent)
    XCTAssertTrue(absent.name.hasPrefix("Spare Recorder"), absent.name)
    XCTAssertEqual(absent.hint, Self.hint)
    XCTAssertEqual(absent.cameras.map(\.id), [camera.rawValue])
    // Only what a camera is assigned to: an unassigned, unlisted ID never appears.
    XCTAssertEqual(devices.filter { !$0.present }.count, 1)
    XCTAssertEqual(Set(devices.filter(\.present).map(\.id)), ["fake:left", "fake:right"])
  }

  func testNicknamesPersistAndNameTheInputEverywhere() throws {
    let defaults = defaults()
    let first = try rig(defaults: defaults)
    let camera = first.model.selectedFeedID
    first.model.updateCamera(camera) { $0.selectedDevice = "fake:left" }
    // Two units of one model: the driver's names collide until a nickname tells them apart.
    XCTAssertNotEqual(first.model.inputLabel("fake:left"), first.model.inputLabel("fake:right"))
    first.model.hardwareInventory.setNickname("  Left Recorder ", for: "fake:left")
    XCTAssertEqual(first.model.inputLabel("fake:left"), "Left Recorder")
    let relaunched = try rig(defaults: defaults)
    XCTAssertEqual(relaunched.model.hardwareInventory.nickname(for: "fake:left"), "Left Recorder")
    XCTAssertEqual(relaunched.model.inputLabel("fake:left"), "Left Recorder")
    XCTAssertEqual(relaunched.model.hardwareInventory.lastKnownNames["fake:right"], "Recorder", "Seen names are kept for absence")
    let groups = UISettingsHardwareGroups(model: relaunched.model)
    let left = try XCTUnwrap(groups.capture.first?.devices.first { $0.id == "fake:left" })
    XCTAssertEqual(left.name, "Left Recorder")
    XCTAssertNotNil(left.driverName)
    XCTAssertTrue(UIDiagnosticsText.summary(model: relaunched.model).contains("Left Recorder"))
    relaunched.model.hardwareInventory.setNickname("", for: "fake:left")
    XCTAssertNil(relaunched.model.hardwareInventory.nickname(for: "fake:left"), "An empty name brings the driver's back")
  }

  // MARK: Bodies

  func testBatteryUnitDecidesTheGlyphAndOnlyAKnownUnitWarns() {
    func power(_ value: UInt64, _ unit: ControlValueUnit?, _ severity: DeviceSeverity? = nil) -> [ControlProperty] {
      [ControlProperty(id: "battery", label: "Battery", writable: false, value: .unsignedInteger(value), role: .power,
        currentValueLabel: "\(value)", severity: severity, unit: unit)]
    }
    XCTAssertEqual(UIHardwareText.battery(power(78, .minutes)), .minutes(78), "78 minutes is never 78%")
    XCTAssertEqual(UIHardwareText.battery(power(78, .percent)), .percent(78))
    XCTAssertEqual(UIHardwareText.battery(power(78, nil)), .unknown("78"))
    XCTAssertNil(UIHardwareText.battery([]))
    let low = UIHardwareBody(camera: Self.body, feedID: "c", connected: true, properties: power(12, .percent, .warning))
    XCTAssertEqual(low.warnings.count, 1)
    XCTAssertEqual(low.health, .attention)
    let unknown = UIHardwareBody(camera: Self.body, feedID: "c", connected: true, properties: power(5, nil))
    XCTAssertTrue(unknown.warnings.isEmpty, "Without a unit a battery never warns")
  }

  func testNoticesAndALostBodyReachTheStoreAndTheProblemList() async throws {
    let rig = try rig()
    let feed = rig.model.selectedFeedID.rawValue
    await rig.model.cameraControls.connect(camera: Self.body, to: feed)
    let state = rig.model.cameraControls.state(for: feed)
    XCTAssertTrue(state.connected)
    rig.control.postNotice("The body's card is full", severity: .warning, feedID: feed)
    XCTAssertEqual(state.notice, "The body's card is full")
    rig.control.postNotice("Recovered", severity: .info, feedID: feed)
    XCTAssertNil(state.notice, "A recovery clears the notice")
    // The body drops on its own: a notice with Reconnect, never damage, since HDMI carries the picture.
    rig.control.replaceCameras([])
    XCTAssertNotNil(state.lostAt)
    let snapshot = try XCTUnwrap(UISessionBridge.body(model: rig.model, cameraID: feed))
    XCTAssertTrue(snapshot.lost)
    var camera = UICameraSnapshot(id: feed, name: "Camera 1")
    camera.body = snapshot
    var session = UISessionSnapshot()
    session.cameras = [camera]
    let problem = try XCTUnwrap(UIPresentationBuilder.problems(session).first { $0.id == "body.\(feed)" })
    XCTAssertEqual(problem.level, .notice)
    XCTAssertEqual(problem.action?.action, .reconnectCameraBody(cameraID: feed))
    XCTAssertNil(problem.stripText, "The strip keeps its row for the picture's problems")
    // A manual disconnect isn't a loss.
    await rig.model.cameraControls.disconnect(feed)
    XCTAssertNil(state.lostAt)
  }

  func testOverheatingRaisesAProblemThatIsDamageOnlyWhileRolling() throws {
    var camera = UICameraSnapshot(id: "c", name: "Camera 1")
    camera.body = UICameraBody(name: "Body A", id: "aa:bb", warning: .init(text: "Overheating", short: "Overheating"))
    var session = UISessionSnapshot()
    session.cameras = [camera]
    let idle = try XCTUnwrap(UIPresentationBuilder.problems(session).first { $0.id == "bodywarn.c" })
    XCTAssertEqual(idle.level, .notice)
    XCTAssertEqual(idle.action?.action, .openHardware(itemID: "aa:bb"))
    session.cameras[0].recording.status = .recording
    XCTAssertEqual(UIPresentationBuilder.problems(session).first { $0.id == "bodywarn.c" }?.level, .damage)
  }

  func testABuildWithoutTheControlSDKReadsAsNormal() async throws {
    let first = try rig(controlPresent: false)
    let feed = first.model.selectedFeedID.rawValue
    XCTAssertTrue(UISettingsHardwareGroups(model: first.model).bodies.isEmpty, "No section, nothing counted")
    XCTAssertNil(UISessionBridge.body(model: first.model, cameraID: feed))
    // A saved pairing from a build that had the SDK: kept, muted, never a problem.
    let saved = CameraControlAssignmentSnapshot(plugins: ["body": [feed: CameraControlAssignment(camera: Self.body)]])
    first.defaults.set(try JSONEncoder().encode(saved), forKey: CameraControlPreferences.preferencesKey)
    let relaunched = try rig(defaults: first.defaults, controlPresent: false)
    let bodies = try XCTUnwrap(UISettingsHardwareGroups(model: relaunched.model).bodies.first)
    XCTAssertFalse(bodies.available)
    XCTAssertEqual(bodies.bodies.map(\.id), [Self.body.id])
    XCTAssertFalse(bodies.bodies[0].lost)
    XCTAssertNil(UISessionBridge.body(model: relaunched.model, cameraID: feed))
    let session = UISessionBridge.live(model: relaunched.model, interface: UIInterfaceState(defaults: first.defaults)).context().session
    XCTAssertFalse(UIPresentationBuilder.problems(session).contains { $0.id.hasPrefix("body") })
  }

  // MARK: Setup

  func testSetupAdvisesOnlyWhenFactsConflictWithOneAction() {
    let format = try! SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let properties = [
      ControlProperty(id: "hdmiResolution", label: "HDMI", writable: false, value: .unsignedInteger(1), role: .outputTiming, currentValueLabel: "2160p"),
      ControlProperty(id: "hdmi4K", label: "4K", writable: false, value: .unsignedInteger(2), role: .outputTiming, currentValueLabel: "59.94p · 10-bit"),
      ControlProperty(id: "gamma", label: "Gamma", writable: false, value: .unsignedInteger(3), role: .colorProfile,
        currentValueLabel: "S-Log3", suggestedSourceProfileID: "sony-slog3-sgamut3cine"),
      ControlProperty(id: "gamut", label: "Gamut", writable: false, value: .unsignedInteger(4), role: .colorProfile, currentValueLabel: "S-Gamut3.Cine"),
    ]
    let conflict = UIBodySetup(properties: properties, cameraName: "Camera 2", declaredProfileID: "rec709-video",
      captureName: "Right Recorder", detected: format, timecodeMode: .wallClock)
    XCTAssertEqual(conflict.rows.first?.pieces, ["2160p", "59.94p", "10-bit"], "Dot-joined values are shown apart")
    XCTAssertEqual(conflict.rows.first?.note, "Matches Right Recorder")
    XCTAssertEqual(conflict.advisory?.title, "Camera 2 is declared Rec.709")
    XCTAssertEqual(conflict.advisory?.actionTitle, "Use S-Log3")
    XCTAssertEqual(conflict.advisory?.action, .useSourceProfile("sony-slog3-sgamut3cine"))
    let agreed = UIBodySetup(properties: properties, cameraName: "Camera 1", declaredProfileID: "sony-slog3-sgamut3cine",
      captureName: "Left Recorder", detected: format, timecodeMode: .wallClock)
    XCTAssertNil(agreed.advisory)
    XCTAssertEqual(agreed.rows.last?.note, "Camera 1 declares S-Log3")
    let slow = try! SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.slowDuration))
    let mismatch = UIBodySetup(properties: properties, cameraName: "Camera 1", declaredProfileID: "sony-slog3-sgamut3cine",
      captureName: "Left Recorder", detected: slow, timecodeMode: .wallClock)
    XCTAssertEqual(mismatch.rows.first?.tone, .warning)
    // An undeclared camera reads as Rec.709, so a Rec.709 body raises nothing.
    XCTAssertTrue(UIBodySetup.same("rec709-video", "unspecified"))
  }

  // MARK: Idle reader and diagnostics

  func testIdleStatusIsReadOnlyWhileSomeoneIsLooking() async throws {
    let rig = try rig()
    var hardware = AppHardware.offline
    let counter = PollCounter()
    hardware.refreshIdleStatus = { counter.count += 1 }
    let inventory = HardwareInventory(defaults: rig.defaults, hardware: hardware, interval: .milliseconds(10))
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(counter.count, 0, "Nobody looking: no reads")
    XCTAssertFalse(inventory.polling)
    inventory.beginWatching()
    inventory.beginWatching()
    XCTAssertTrue(inventory.polling)
    await settle { counter.count >= 3 }
    XCTAssertGreaterThanOrEqual(counter.count, 3)
    inventory.endWatching()
    XCTAssertTrue(inventory.polling, "Still one window showing hardware")
    inventory.endWatching()
    XCTAssertFalse(inventory.polling)
    try await Task.sleep(for: .milliseconds(30))
    let stopped = counter.count
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(counter.count, stopped, "Every window closed: reads stop")
    inventory.endWatching()
    XCTAssertFalse(inventory.polling, "An extra end never goes negative")
    // The model's own reader asks the plugins.
    rig.model.hardwareInventory.beginWatching()
    await settle { rig.capture.idleRefreshes > 0 }
    XCTAssertGreaterThan(rig.capture.idleRefreshes, 0)
    rig.model.hardwareInventory.endWatching()
  }

  func testStatusUpdatesReachTheInventoryAndCopyDiagnosticsNamesTheHardware() async throws {
    let rig = try rig()
    let feed = rig.model.selectedFeedID
    rig.model.updateCamera(feed) { $0.selectedDevice = "fake:left" }
    rig.model.hardwareInventory.setNickname("Left Recorder", for: "fake:left")
    rig.capture.setStatus(CaptureDeviceStatus(availability: .inUseElsewhere, link: .thunderbolt, connector: .sdi,
      facts: [DeviceFact(id: "temperature", group: .other, label: "Temperature", values: ["52 °C"])],
      problems: [DeviceProblem(id: "busy", severity: .warning, title: "In use by another app")]), for: "fake:left")
    XCTAssertEqual(rig.model.hardwareInventory.statuses["fake:left"]?.connector, .sdi)
    let left = try XCTUnwrap(UISettingsHardwareGroups(model: rig.model).capture.first?.devices.first { $0.id == "fake:left" })
    XCTAssertEqual(left.health, .attention)
    // The left pane names the connector only when it isn't HDMI.
    let snapshot = UISessionBridge.live(model: rig.model, interface: UIInterfaceState(defaults: rig.defaults)).context()
      .session.cameras.first { $0.id == feed.rawValue }
    XCTAssertEqual(snapshot?.inputConnector, "SDI")
    rig.model.updateCamera(feed) { $0.selectedDevice = "fake:gone" }
    await rig.model.cameraControls.connect(camera: Self.body, to: "other-camera")
    let text = UIDiagnosticsText.summary(model: rig.model)
    for expected in ["[Hardware]", "Fixture Capture (fake)", "Left Recorder", "ID fake:left", "connector SDI", "link Thunderbolt",
      "in use by another app", "temperature 52 °C", "absent", "ID fake:gone", "Fixture Bodies (body)", "Body A", "model Model X"] {
      XCTAssertTrue(text.contains(expected), "Copy Diagnostics is missing \(expected)")
    }
    XCTAssertFalse(text.contains("password"))
  }
}

@MainActor private final class PollCounter { var count = 0 }
#endif
