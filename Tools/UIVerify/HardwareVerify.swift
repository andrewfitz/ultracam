import AppKit
import CoreMedia
import SwiftUI

/// Settings › Hardware with a scripted rig: two capture devices of one model told apart by
/// nickname, two camera bodies paired and connected, an absent assigned device with its
/// plugin's hint, and the expanded rows with connector, formats, Setup and an advisory.
/// Fixture plugins only: nothing opens a capture device or contacts a camera body.
@MainActor enum HardwareVerify {
  static let hint = "If it is plugged in, check its cable and hub."

  static func run(verifier: Verifier, render: (String, AnyView, CGSize) -> Void) {
    let suite = "org.ultracam.ui-verify.hardware.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { verifier.check("hardware: defaults suite", false); return }
    defer { defaults.removePersistentDomain(forName: suite) }
    guard let rig = try? Rig(defaults: defaults) else { verifier.check("hardware: fixture builds", false); return }
    let model = rig.model
    func settle(_ label: String, until condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(3)
      while !condition() && Date() < deadline { MainLoop.run(seconds: 0.01) }
      verifier.check(label, condition())
    }
    settle("hardware: both bodies connect and read") {
      model.feedDescriptors.allSatisfy { model.cameraControls.state(for: $0.id.rawValue).connected &&
        !model.cameraControls.state(for: $0.id.rawValue).properties.isEmpty }
    }
    settle("hardware: device settings load") { !model.vendorSettings.state(for: "fake:left").settings.isEmpty }
    // Camera 1 runs (a fixture session), so its device's connector is read-only with the reason.
    let camera1 = model.feedDescriptors[0].id
    model.startCamera(camera1)
    settle("hardware: camera 1 runs on its fixture session") { model.isCameraRunning(camera1) }
    let interface = UIInterfaceState(defaults: defaults)
    let width = UISettingsLayout.width

    func pane(_ expanded: Set<String> = []) -> some View {
      UISettingsHardwarePane(model: model, interface: interface, initiallyExpanded: expanded).frame(width: width)
    }
    func text(_ view: some View, height: CGFloat = 1400) -> [String] {
      let hosted = HostedView(view, size: CGSize(width: width, height: height), dark: false)
      hosted.settle(0.4)
      let nodes = Accessibility.nodes(in: hosted.host).map(\.text)
      hosted.close()
      return nodes
    }
    func missing(_ words: [String], in nodes: [String]) -> [String] { words.filter { word in !nodes.contains { $0.contains(word) } } }

    // Collapsed: health, nickname, camera, signal and link; bodies with battery.
    let present = text(pane())
    let presentMissing = missing(["Left Recorder", "Right Recorder", "Fixture Capture", "Fixture Bodies", "Find Camera Bodies",
      "Add by Address", "2160p 59.94", "Thunderbolt", "Body A", "Connected"], in: present)
    verifier.check("hardware: collapsed rows show health, name, camera, state and link", presentMissing.isEmpty,
      "missing \(presentMissing.joined(separator: ", "))", viewDependent: true)
    verifier.check("hardware: opening Settings never scans for bodies",
      rig.control.discoveries == 0 && model.cameraControls.scanning.isEmpty, "\(rig.control.discoveries) scans")
    render("settings-hardware-present", AnyView(pane()), CGSize(width: width, height: SettingsVerify.measure(pane())))

    // Expanded: the device's name, settings, signal and formats; the body's Setup and advisory.
    let open: Set<String> = ["fake:left", Rig.bodyB.id]
    let expanded = text(pane(open), height: 1800)
    let expandedMissing = missing(["Stays on this Mac", "Input connector", "Advertise HDR to cameras", "Stop Camera 1 to change",
      "Supported formats", "Device ID", "fake:left", "PCIe x4 Gen3", "Setup", "Matches Right Recorder",
      "Camera 2 is declared Rec.709", "Use S-Log3", "firmware 7.02", "Camera Control…", "Unassign"], in: expanded)
    verifier.check("hardware: expanded rows carry settings, formats, Setup and the advisory", expandedMissing.isEmpty,
      "missing \(expandedMissing.joined(separator: ", "))", viewDependent: true)
    verifier.check("hardware: formats use human names, never frame durations", !expanded.contains { $0.contains("1001/") },
      viewDependent: true)
    render("settings-hardware-expanded", AnyView(pane(open)), CGSize(width: width, height: SettingsVerify.measure(pane(open))))

    // Absent: Camera 2's device isn't listed; it keeps its last known name and the plugin's hint.
    let camera2 = model.feedDescriptors[1].id
    model.updateCamera(camera2) { $0.selectedDevice = "fake:spare" }
    let absent = text(pane())
    let absentMissing = missing(["Spare Recorder", "Not connected", hint], in: absent)
    verifier.check("hardware: an absent assigned device keeps its name and its plugin's hint", absentMissing.isEmpty,
      "missing \(absentMissing.joined(separator: ", "))", viewDependent: true)
    render("settings-hardware-absent", AnyView(pane()), CGSize(width: width, height: SettingsVerify.measure(pane())))
    model.updateCamera(camera2) { $0.selectedDevice = "fake:right" }

    // The idle reader runs only while the pane is on screen.
    let shown = HostedView(pane(), size: CGSize(width: width, height: 900), dark: false)
    shown.settle(0.3)
    verifier.check("hardware: the idle reader runs while Hardware is visible", model.hardwareInventory.polling, viewDependent: true)
    shown.close()
    MainLoop.run(seconds: 0.2)
    verifier.check("hardware: the idle reader stops once nothing shows hardware", !model.hardwareInventory.polling, viewDependent: true)
    verifier.check("hardware: the idle reader asked the plugin", rig.capture.idleRefreshes > 0, "\(rig.capture.idleRefreshes)",
      viewDependent: true)
    model.stopCamera(camera1)
  }

  /// The scripted rig.
  @MainActor struct Rig {
    static let bodyA = ControlCamera(pluginID: "body", id: "02:00:00:00:00:0a", name: "Body A", transport: .network,
      address: "192.0.2.41", model: "Model X")
    static let bodyB = ControlCamera(pluginID: "body", id: "02:00:00:00:00:0b", name: "Body B", transport: .network,
      address: "192.0.2.42", model: "Model X")
    let model: AppModel
    let capture: FakeCapturePlugin
    let control: FakeControlPlugin

    init(defaults: UserDefaults) throws {
      let rates = [VideoContract.slowDuration, VideoContract.fastDuration, CMTime(value: 1001, timescale: 24000)]
      let uhd = try rates.map { try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant($0)) }
      let hd = try rates.map { try SourceFormat(width: 1920, height: 1080, pixel: .v210, rate: .constant($0)) }
      let descriptor = VendorDescriptor(id: "fake", displayName: "Fixture Capture", badgeText: "FIX", signalHint: nil,
        sdkVersion: "1.0", sdkPresent: true, missingDeviceHint: HardwareVerify.hint)
      capture = FakeCapturePlugin(format: uhd[1], audio: .absent, deviceIDs: ["fake:left", "fake:right"], descriptor: descriptor)
      for id in ["fake:left", "fake:right"] {
        capture.setDetails(.init(name: "Recorder", model: "Recorder 12G", modes: uhd + hd, connectors: [.hdmi, .sdi]), for: id)
        capture.setSettings([
          VendorSetting(id: "fake:connector", labelKey: "fake.connector", value: .choice("hdmi"),
            allowedValues: .choices([.init(id: "hdmi", label: "HDMI"), .init(id: "sdi", label: "SDI")]), mutable: true,
            availabilityReason: nil, interruptsCapture: true, labelFallback: "Input connector"),
          VendorSetting(id: "fake:hdr", labelKey: "fake.hdr", value: .boolean(false), allowedValues: .unrestricted, mutable: true,
            availabilityReason: nil, interruptsCapture: true, labelFallback: "Advertise HDR to cameras"),
        ], for: id)
      }
      capture.setConnected(true)
      let properties = [
        ControlProperty(id: "battery", label: "Battery", writable: false, value: .unsignedInteger(78), role: .power,
          currentValueLabel: "78%", unit: .percent),
        ControlProperty(id: "slot1", label: "Slot 1", writable: false, value: .unsignedInteger(0), role: .media, currentValueLabel: "OK"),
        ControlProperty(id: "slot2", label: "Slot 2", writable: false, value: .unsignedInteger(1), role: .media, currentValueLabel: "No card"),
        ControlProperty(id: "hdmiResolution", label: "HDMI output resolution", writable: false, value: .unsignedInteger(1),
          role: .outputTiming, currentValueLabel: "2160p"),
        ControlProperty(id: "hdmi4K", label: "HDMI 4K output timing", writable: false, value: .unsignedInteger(2),
          role: .outputTiming, currentValueLabel: "59.94p · 10-bit"),
        ControlProperty(id: "cameraDisplay", label: "HDMI display", writable: true, value: .boolean(false), role: .cameraDisplay),
        ControlProperty(id: "hdmiTimecode", label: "Timecode out", writable: false, value: .unsignedInteger(2), role: .timecodeOutput,
          currentValueLabel: "On"),
        ControlProperty(id: "hdmiAudio", label: "Audio on HDMI", writable: false, value: .unsignedInteger(3), role: .hdmiAudio,
          currentValueLabel: "CH1/CH2"),
        ControlProperty(id: "gamma", label: "Gamma", writable: false, value: .unsignedInteger(4), role: .colorProfile,
          currentValueLabel: "S-Log3", suggestedSourceProfileID: "sony-slog3-sgamut3cine"),
        ControlProperty(id: "colorMode", label: "Color mode", writable: false, value: .unsignedInteger(5), role: .colorProfile,
          currentValueLabel: "S-Gamut3.Cine"),
        ControlProperty(id: "firmware", label: "Firmware", writable: false, value: .unsignedInteger(0), role: .firmware,
          currentValueLabel: "7.02"),
      ]
      control = FakeControlPlugin(descriptor: VendorDescriptor(id: "body", displayName: "Fixture Bodies", badgeText: "BODY",
        signalHint: nil, sdkVersion: "2.0", sdkPresent: true, missingDeviceHint: "Turn the body's remote control on."),
        cameras: [Self.bodyA, Self.bodyB], properties: properties)
      let registry = try VendorRegistry(capture: [capture], control: [control])
      // Fixture sessions and sinks only, as in `AppHardwareSyntheticFixture`: a started camera
      // never reaches a capture device or the Mac's virtual cameras.
      let plugin = capture, sink = SyntheticCameraSink(), claims = CaptureDeviceClaims()
      let hardware = AppHardware.registry(registry, captureServices: { id in
        var services = CaptureServices.registry(feedID: id, plugins: [plugin], claims: claims)
        services.connect = { _, _ in try sink.connect() }
        services.connectWithSource = { _, _, _ in try sink.connect() }
        services.preNegotiate = nil
        services.disconnect = { sink.disconnect() }
        services.send = { sink.send($0) }
        return services
      })
      let installer = ExtensionInstaller(services: .init(
        preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
        makeRequest: { _ in fatalError("No installer requests in this fixture") },
        submit: { _ in }, queryProperties: { $0([]) }))
      defaults.set(["fake:spare": "Recorder"], forKey: HardwareInventory.lastKnownNamesKey)
      model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
        registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: SyntheticRegistryPublisher(),
        recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer, hardware: hardware)
      let first = model.selectedFeedID
      let second = model.addFeed() ?? first
      model.updateCamera(first) { $0.selectedDevice = "fake:left"; $0.sourceProfileID = "sony-slog3-sgamut3cine" }
      model.updateCamera(second) { $0.selectedDevice = "fake:right"; $0.sourceProfileID = "rec709-video" }
      model.hardwareInventory.setNickname("Left Recorder", for: "fake:left")
      model.hardwareInventory.setNickname("Right Recorder", for: "fake:right")
      model.hardwareInventory.setNickname("Spare Recorder", for: "fake:spare")
      let detected = uhd[1]
      for id in ["fake:left", "fake:right"] {
        capture.setStatus(CaptureDeviceStatus(availability: .free, link: .thunderbolt, connector: .hdmi, signalLocked: true,
          detected: detected, facts: [
            DeviceFact(id: "connection", group: .connection, label: "Connection", values: ["Thunderbolt", "PCIe x4 Gen3"]),
            DeviceFact(id: "signal", group: .signal, label: "Signal", values: ["2160p", "59.94", "10-bit 4:2:2", "Rec.709", "SDR"]),
            DeviceFact(id: "temperature", group: .other, label: "Temperature", values: ["52 °C"]),
          ]), for: id)
      }
      let store = model.cameraControls
      Task {
        await store.connect(camera: Self.bodyA, to: first.rawValue)
        await store.connect(camera: Self.bodyB, to: second.rawValue)
      }
      capture.setStatus(CaptureDeviceStatus(availability: .inUseHere, link: .thunderbolt, connector: .hdmi, signalLocked: true,
        detected: detected, facts: [
          DeviceFact(id: "connection", group: .connection, label: "Connection", values: ["Thunderbolt", "PCIe x4 Gen3"]),
          DeviceFact(id: "temperature", group: .other, label: "Temperature", values: ["52 °C"]),
        ]), for: "fake:left")
    }
  }
}
