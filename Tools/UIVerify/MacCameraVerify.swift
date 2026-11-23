import AppKit
import AVFoundation
import CoreVideo
import SwiftUI

/// Two scripted capture vendors exercise the shipping views and action bridge
/// without opening an AVCaptureSession or a real virtual camera.
@MainActor enum MacCameraVerify {
  typealias Render = (String, AnyView, CGSize) -> Void

  static func run(verifier: Verifier, render: Render) {
    do { try verify(verifier, render: render) }
    catch { verifier.check("Mac Camera scenario", false, String(describing: error)) }
  }

  private static func verify(_ verifier: Verifier, render: Render) throws {
    let suite = verifier.makeDefaultsDomain()
    guard let defaults = UserDefaults(suiteName: suite) else { throw PluginError.failed("Cannot create fixture defaults") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let webID = "maccamera:web", spareID = "maccamera:spare", deckID = "decklink:recorder"
    let webcam = FeedID(rawValue: "webcam"), deck = FeedID(rawValue: "deck")
    let duration = FrameRateTarget.fps60.duration
    let native = try SourceFormat(width: 1920, height: 1080, pixel: .video420, rate: .constant(duration))
    let deckFormat = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration))
    let mac = FakeCapturePlugin(format: native, audio: .absent, deviceIDs: [webID, spareID],
      descriptor: VendorDescriptor(id: "maccamera", displayName: "Mac Camera", badgeText: "MAC", signalHint: nil,
        sdkVersion: nil, sdkPresent: true, missingDeviceHint: "Check the webcam connection.", captureAudio: .microphone), shareable: false)
    let deckLink = FakeCapturePlugin(format: deckFormat, audio: .absent, deviceIDs: [deckID],
      descriptor: VendorDescriptor(id: "decklink", displayName: "DeckLink", badgeText: "DL", signalHint: nil,
        sdkVersion: nil, sdkPresent: true), shareable: false)
    mac.setDetails(.init(name: "USB Webcam", modes: [native]), for: webID)
    mac.setDetails(.init(name: "Built-in Camera", modes: [native]), for: spareID)
    deckLink.setDetails(.init(name: "DeckLink Recorder", modes: [deckFormat], connectors: [.hdmi]), for: deckID)
    let modeID = "maccamera:capture-mode", micID = "maccamera:mic"
    let formats = [VendorCaptureFormat(id: "1080-420v", label: "1920 × 1080 · 420v",
      rates: [.init(duration: duration, label: "60 fps")],
      ranges: [.init(shortest: duration, longest: FrameRateTarget.fps30.duration)])]
    let mode = VendorCaptureMode.value(formatID: formats[0].id, duration: duration)
    let microphone = VendorSettingValue.choice("usb-mic")
    let hardwareSettings = [
      VendorSetting(id: modeID, labelKey: "Capture Format", value: VendorCaptureMode.automatic,
        allowedValues: .unrestricted, mutable: true, availabilityReason: nil, interruptsCapture: true,
        captureFormats: formats, interruption: .video),
      VendorSetting(id: micID, labelKey: "Microphone", value: .choice("none"),
        allowedValues: .choices([.init(id: "none", label: "None"), .init(id: "usb-mic", label: "USB Microphone")]),
        mutable: true, availabilityReason: nil, interruptsCapture: true, interruption: .audio),
    ]
    for id in [webID, spareID] { mac.setSettings(hardwareSettings, for: id) }
    deckLink.setConnected(true)
    mac.setStatus(.init(availability: .free, link: .usb, signalLocked: true, detected: native,
      facts: [.init(id: "kind", group: .identity, label: "Device type", values: ["Webcam"])],
      signalDetail: "Fixture delivery detail"), for: webID)
    let plugins = [mac, deckLink]
    let registry = try VendorRegistry(capture: plugins)
    let sink = Output(), claims = CaptureDeviceClaims()
    var hardware = AppHardware.registry(registry, captureServices: { feed in
      var services = CaptureServices.registry(feedID: feed, plugins: plugins, claims: claims)
      services.connect = { _, _ in }
      services.connectWithSource = { configuration, pixel, source in
        _ = try CameraSink.requestedFormat(configuration: configuration, passthroughFormat: pixel, sourceFormat: source)
      }
      services.preNegotiate = nil
      services.disconnect = {}
      services.send = { sink.send($0) }
      return services
    })
    var authorization = CaptureAuthorizationStatus.requestable
    var permissionRequests = 0
    hardware.captureAuthorization = { id, _ in id == mac.descriptor.id ? authorization : .authorized }
    hardware.authorizeCapture = { id, _ in
      guard id == mac.descriptor.id else { throw PluginError.failed("Wrong permission vendor") }
      permissionRequests += 1
      authorization = .authorized
      mac.setConnected(true)
    }
    let settings = AppSettingsStore(defaults: defaults)
    settings.saveSnapshot(.init(feeds: [
      FeedDescriptor(id: webcam, name: "Camera 1", selectedDevice: webID, applyLUT: false, downscale: false, convertTo420: false),
      FeedDescriptor(id: deck, name: "Camera 2", selectedDevice: deckID, applyLUT: false),
    ], selectedFeedID: webcam, outputMode: .separateCameras))
    func makeModel() -> AppModel {
      let installer = ExtensionInstaller(services: .init(
        preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
        makeRequest: { _ in fatalError("No install requests in this fixture") },
        submit: { _ in }, queryProperties: { $0([]) }))
      return AppModel(settingsStore: settings, registryStore: VirtualCameraRegistryStore(defaults: defaults),
        registryPublisher: SyntheticRegistryPublisher(), recordingFolderStore: RecordingFolderStore(defaults: defaults),
        installer: installer, hardware: hardware)
    }
    let model = makeModel()
    defer { model.stopCamera(webcam) }
    let interface = UIInterfaceState(defaults: defaults)
    interface.alertsDisabled = true
    var settingsOpened = false
    let bridge = UISessionBridge.live(model: model, interface: interface, openSettings: { settingsOpened = true })
    let inspectorSize = CGSize(width: 372, height: 1000)
    let hardwareSize = CGSize(width: UISettingsLayout.defaultSize.width, height: 1000)
    func settle(_ name: String, until condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(4)
      while !condition() && Date() < deadline { MainLoop.run(seconds: 0.012) }
      verifier.check("Mac Camera: \(name)", condition())
    }
    func inspector() -> some View {
      UIInspectorView(context: bridge.context()).defaultAppStorage(defaults)
    }
    func hardwareView() -> some View {
      UISettingsHardwarePane(model: model, interface: interface)
    }
    func checkText(_ view: some View, size: CGSize, _ expected: [String], _ label: String) {
      let host = HostedView(view, size: size, dark: false)
      defer { host.close() }
      let nodes = Accessibility.nodes(in: host.host).map(\.text)
      let missing = expected.filter { word in !nodes.contains { $0.contains(word) } }
      verifier.check("Mac Camera: \(label)", missing.isEmpty, "missing \(missing); AX \(nodes.filter { !$0.isEmpty })", viewDependent: true)
    }
    func choose(_ item: NSMenuItem?) -> Bool {
      guard let item, item.isEnabled, let menu = item.menu, let index = menu.items.firstIndex(of: item) else { return false }
      menu.performActionForItem(at: index)
      MainLoop.run(seconds: 0.03)
      return true
    }
    let permissionHost = HostedView(hardwareView(), size: hardwareSize, dark: false)
    let enable = Accessibility.nodes(in: permissionHost.host).first { $0.text.contains("Enable Camera Access") }
    verifier.check("Mac Camera: Hardware offers camera access with no enumerated camera",
      enable != nil && model.devices.map(\.id) == [deckID], viewDependent: true)
    if let enable { _ = Accessibility.press(enable) }
    settle("permission action refreshes inventory without opening the webcam") {
      permissionRequests == 1 && model.devices.contains { $0.id == webID } && mac.sessions.isEmpty
    }
    permissionHost.close()
    settle("both per-device editors load") {
      [webID, spareID].allSatisfy { model.vendorSettings.state(for: $0).settings.count == 2 && !model.vendorSettings.state(for: $0).busy }
    }
    let context = bridge.context()
    let groups = UIInputPicker.groups(context.inputs)
    let deckInput = context.inputs.first { $0.id == deckID }
    let options = UIInputLabels.options(context.inputs.map { ($0.id, $0.name) }, cameras: context.session.cameras, for: webcam.rawValue)
    verifier.check("Mac Camera: Input picker groups both vendors and disables the claimed DeckLink source",
      Set(groups.compactMap(\.title)) == ["Mac Camera", "DeckLink"] &&
        deckInput.map { !UIInputPicker.selectable($0, usedBy: options.first { $0.id == deckID }?.usedBy, selectedID: webID) } == true)
    bridge.perform(.setInput(cameraID: webcam.rawValue, deviceID: deckID))
    verifier.check("Mac Camera: the claimed assignment is refused by the action bridge", model.descriptor(for: webcam)?.selectedDevice == webID)
    let inspectorHost = HostedView(inspector(), size: inspectorSize, dark: false)
    if let link = Accessibility.nodes(in: inspectorHost.host).first(where: { $0.text.contains("Supported formats and settings") }) {
      _ = Accessibility.press(link)
    }
    inspectorHost.settle()
    verifier.check("Mac Camera: Inspector Hardware link selects the assigned device",
      settingsOpened && interface.settingsTab == .hardware && interface.hardwareFocus == webID, viewDependent: true)
    inspectorHost.close()
    checkText(hardwareView(), size: hardwareSize,
      ["Mac Camera", "DeckLink", "USB Webcam", "USB", "Capture Format", "Frame Rate", "Microphone", "Supported formats"],
      "Hardware expands the camera editor with USB transport")
    render("mac-camera-hardware", AnyView(UISettingsHardwarePane(model: model, interface: interface, initiallyExpanded: [webID])), hardwareSize)

    mac.setConnectedDevices([spareID])
    settle("disconnect retains the old assignment") {
      !model.devices.contains(where: { $0.id == webID }) && model.descriptor(for: webcam)?.selectedDevice == webID
    }
    checkText(hardwareView(), size: hardwareSize, ["USB Webcam", "Not connected", "Check the webcam connection."],
      "missing camera keeps its name and reconnect hint")
    mac.setConnected(true)
    settle("reconnect enumerates the persisted identity") { model.devices.contains { $0.id == webID } }
    MainLoop.run(seconds: 0.05)
    settle("reconnected device settings are ready for edits") {
      let state = model.vendorSettings.state(for: webID)
      return state.settings.count == 2 && !state.busy
    }
    Task {
      await model.vendorSettings.apply(mode, to: modeID, deviceID: webID, pluginID: mac.descriptor.id)
      await model.vendorSettings.apply(microphone, to: micID, deviceID: webID, pluginID: mac.descriptor.id)
    }
    func savedSettings() -> [String: [String: VendorSettingValue]] {
      (try? VendorSettingsPreferences(defaults: defaults).load().desiredByDevice) ?? [:]
    }
    try stagedMode(verifier, model: model, deviceID: spareID, settingID: modeID, saved: savedSettings)
    settle("mode and microphone save under the selected device") {
      savedSettings()[webID]?[modeID] == mode && savedSettings()[webID]?[micID] == microphone
    }

    model.setCameraDemandForTesting(webcam, requested: true)
    bridge.perform(.startCamera(cameraID: webcam.rawValue))
    settle("capture starts the scripted webcam") { model.isCameraRunning(webcam) && mac.sessions.last?.deviceID == webID }
    guard let session = mac.sessions.last else { return }
    mac.setStatus(.init(availability: .inUseHere, link: .usb, signalLocked: true, detected: native,
      signalDetail: "Fixture delivery detail"), for: webID)
    let pattern = try makePattern(native)
    var frame: Int32 = 0
    func emit(_ count: Int) {
      for _ in 0..<count {
        let context = session.context
        let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
          presentationTime: CMTimeMultiply(duration, multiplier: frame), duration: duration, signalValid: true, timecode: nil)
        if !session.submit(.frame(CapturedPixelBuffer(immutable: pattern), info)) {
          verifier.check("Mac Camera: fixture frame admitted", false, "frame \(frame)")
        }
        frame += 1
        MainLoop.run(seconds: 0.014)
      }
    }
    emit(8)
    let firstFrameDeadline = Date().addingTimeInterval(4)
    while !sink.matches(width: native.width, height: native.height, pixel: .video420, duration: duration),
      Date() < firstFrameDeadline { emit(1) }
    settle("capture delivers a live 1080p60 source") {
      guard let snapshot = bridge.context().snapshot(webcam.rawValue) else { return false }
      return model.cameraUpdate(webcam)?.sourceFormat == native &&
        UIInspectorViewContent.signalText(snapshot).contains("1080p 60")
    }
    checkText(inspector(), size: inspectorSize, ["Device", "Signal", "Fixture delivery detail", "Hardware…"],
      "running inspector keeps the native Signal and Hardware link")
    bridge.perform(.setInput(cameraID: webcam.rawValue, deviceID: spareID))
    verifier.check("Mac Camera: a running device cannot be reassigned", model.descriptor(for: webcam)?.selectedDevice == webID)
    checkText(UISettingsHardwarePane(model: model, interface: interface, initiallyExpanded: [webID]), size: hardwareSize,
      ["Capture Format", "Frame Rate", "Microphone", "Stop Camera 1"], "interrupting device settings explain the stop requirement")

    let folder = verifier.pngDirectory.deletingLastPathComponent().appendingPathComponent("mac-camera-take", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    model.recordingModel.codec = .hevcMain
    model.recordingModel.setOutputFolder(folder, for: webcam)
    bridge.perform(.toggleRecording(cameraID: webcam.rawValue))
    func recordingState() -> RecordingFeedState? { model.recordingModel.feeds.first { $0.id == webcam } }
    settle("source take rolls") { recordingState()?.status == .recording && recordingState()?.isStarting == false }
    emit(8)

    func selectStripEffect(_ effect: String, value: String) -> Bool {
      let context = bridge.context()
      guard let camera = context.presentation.selected else { return false }
      let host = HostedView(UIEffectsMenu(camera: camera, snapshot: context.snapshot(camera.id), context: context),
        size: CGSize(width: 130, height: 42), dark: false)
      defer { host.close() }
      let items = Menus.items(in: host.host, containing: effect)
      guard let submenu = items.first(where: { $0.title == effect })?.submenu else { return false }
      submenu.update()
      return choose(submenu.items.first { $0.title == value })
    }
    let resizeSelected = selectStripEffect("Output size", value: "720p")
    let colorSelected = selectStripEffect("Color format", value: ColorTarget.yuv4228.title)
    verifier.check("Mac Camera: strip changes Output size and Color format",
      resizeSelected && colorSelected && model.descriptor(for: webcam)?.resizeTarget == .hd720 &&
        model.descriptor(for: webcam)?.colorTarget == .yuv4228, viewDependent: true)
    if model.descriptor(for: webcam)?.resizeTarget != .hd720 { bridge.perform(.setResizeTarget(cameraID: webcam.rawValue, .hd720)) }
    if model.descriptor(for: webcam)?.colorTarget != .yuv4228 { bridge.perform(.setColorTarget(cameraID: webcam.rawValue, .yuv4228)) }
    defaults.set(true, forKey: "ui.inspector.open.effects")
    let inspectorContext = bridge.context()
    if let snapshot = inspectorContext.snapshot(webcam.rawValue) {
      UIInspectorViewContent(context: inspectorContext)
        .frameRateSelection(cameraID: snapshot.id, current: snapshot.frameRateTarget).wrappedValue = .fps30
    }
    verifier.check("Mac Camera: inspector's Frame-rate cap binding changes the live setting",
      model.descriptor(for: webcam)?.frameRateTarget == .fps30)
    emit(18)
    settle("only live output changes to 720p 4:2:2 at 30 fps") {
      sink.matches(width: 1280, height: 720, pixel: PixelFormatID(rawValue: ColorTarget.yuv4228.pixelFormat), duration: FrameRateTarget.fps30.duration) &&
        model.cameraUpdate(webcam)?.sourceFormat == native && recordingState()?.status == .recording
    }
    checkText(inspector(), size: inspectorSize, ["Output size", "720p", "Color format", "4:2:2 8-bit", "Frame-rate cap", "30 fps"],
      "inspector shows the effected output choices")
    render("mac-camera-inspector-effects", AnyView(inspector()), inspectorSize)
    let effected = bridge.context()
    if let camera = effected.presentation.selected {
      let menu = HostedView(UIEffectsMenu(camera: camera, snapshot: effected.snapshot(camera.id), context: effected),
        size: CGSize(width: 120, height: 40), dark: false)
      let items = Menus.items(in: menu.host, containing: "Output size")
      let titles = items.map(\.title)
      verifier.check("Mac Camera: strip exposes the same three output controls",
        ["Output size", "Color format", "Frame-rate cap"].allSatisfy(titles.contains), "\(titles)", viewDependent: true)
      menu.close()
    }
    bridge.perform(.setProcessing(cameraID: webcam.rawValue, false))
    emit(12)
    settle("Effects Off delivers a distinct buffer with the native format, cadence and pixels") {
      sink.matches(width: native.width, height: native.height, pixel: .video420, duration: duration) &&
        sink.matchesPixels(of: pattern)
    }
    bridge.perform(.setProcessing(cameraID: webcam.rawValue, true))
    emit(12)
    settle("Effects On restores the saved live effects") {
      sink.matches(width: 1280, height: 720, pixel: PixelFormatID(rawValue: ColorTarget.yuv4228.pixelFormat), duration: FrameRateTarget.fps30.duration)
    }
    bridge.perform(.toggleRecording(cameraID: webcam.rawValue))
    settle("source take finalizes") { recordingState()?.savedURL != nil }
    if let url = recordingState()?.savedURL {
      var takeFormat: (CMVideoDimensions, Float)?
      Task {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
          let dimensions = try? await track.load(.formatDescriptions).first.map(CMVideoFormatDescriptionGetDimensions),
          let rate = try? await track.load(.nominalFrameRate) { takeFormat = (dimensions, rate) }
      }
      settle("the saved source take remains 1920 × 1080 at 60 fps") {
        guard let (dimensions, rate) = takeFormat else { return false }
        return dimensions.width == 1920 && dimensions.height == 1080 && abs(rate - 60) < 0.2
      }
    }
    bridge.perform(.setSyncCameras(true, sourceID: webcam.rawValue))
    verifier.check("Mac Camera: Sync Cameras shares effects while preserving per-device mode and microphone",
      model.descriptor(for: deck)?.resizeTarget == .hd720 && model.descriptor(for: deck)?.frameRateTarget == .fps30 &&
        model.descriptor(for: deck)?.selectedDevice == deckID && savedSettings()[deckID]?[modeID] == nil &&
        savedSettings()[webID]?[modeID] == mode && savedSettings()[webID]?[micID] == microphone &&
        savedSettings()[spareID]?[modeID] != mode && savedSettings()[spareID]?[micID] != microphone)
    model.stopCamera(webcam)
    mac.setSettings(hardwareSettings, for: webID)
    let relaunched = makeModel()
    settle("a fresh model restores the stopped camera's per-device selection") {
      let values = Dictionary(uniqueKeysWithValues: relaunched.vendorSettings.state(for: webID).settings.map { ($0.id, $0.value) })
      return values[modeID] == mode && values[micID] == microphone && !relaunched.vendorSettings.state(for: webID).busy
    }
  }

  private static func stagedMode(_ verifier: Verifier, model: AppModel, deviceID: String, settingID: String,
    saved: () -> [String: [String: VendorSettingValue]]) throws {
    let store = model.vendorSettings
    let state = store.state(for: deviceID)
    guard let setting = state.settings.first(where: { $0.id == settingID }),
      let formats = setting.captureFormats, let format = formats.first else {
      throw PluginError.failed("Missing staged capture editor fixture")
    }
    let original = setting.value
    let originalPreference = saved()[deviceID]?[settingID]
    let duration = CMTime(value: 1001, timescale: 60_000)
    let expected = VendorCaptureMode.value(formatID: format.id, duration: duration)
    let size = CGSize(width: 620, height: 260)
    var writes: [VendorSettingValue] = []

    func draft(fps: String) -> UICaptureModeDraft {
      var value = UICaptureModeDraft()
      value.selectFormat(format.id, formats: formats, committed: original)
      value.selectCustomRate(fps)
      return value
    }
    func editor(_ draft: UICaptureModeDraft = .init()) -> HostedView {
      HostedView(Form {
        UICaptureModeSettings(setting: setting, formats: formats, busy: false, stopReason: nil, draft: draft) { value in
          writes.append(value)
          Task { await store.apply(value, to: settingID, deviceID: deviceID, pluginID: "maccamera") }
        }
      }, size: size, dark: false)
    }
    func button(_ label: String, in host: HostedView) -> AXNode? {
      Accessibility.nodes(in: host.host).first { $0.role == "AXButton" && $0.text.contains(label) }
    }
    func untouched() -> Bool {
      writes.isEmpty && state.settings.first(where: { $0.id == settingID })?.value == original &&
        saved()[deviceID]?[settingID] == originalPreference
    }

    let invalid = editor(draft(fps: "15"))
    verifier.check("Mac Camera: custom FPS outside the selected format range disables Apply",
      button("Apply Capture Mode", in: invalid)?.enabled == false, viewDependent: true)
    invalid.close()

    let valid = draft(fps: "60000/1001")
    verifier.check("Mac Camera: the draft resolves the new format with the exact custom rate",
      valid.pendingValue(formats: formats, committed: original) == expected && untouched())
    let cancelled = editor(valid)
    let didCancel = button("Cancel", in: cancelled).map(Accessibility.press) ?? false
    cancelled.settle()
    verifier.check("Mac Camera: Cancel clears the staged editor without applying settings",
      didCancel && button("Apply Capture Mode", in: cancelled) == nil && untouched(), viewDependent: true)
    cancelled.close()

    editor(valid).close()
    let reopened = editor()
    verifier.check("Mac Camera: closing without Apply reopens at the committed selection",
      button("Apply Capture Mode", in: reopened) == nil && untouched(), viewDependent: true)
    reopened.close()

    let applying = editor(valid)
    let didApply = button("Apply Capture Mode", in: applying).map(Accessibility.press) ?? false
    let deadline = Date().addingTimeInterval(4)
    while saved()[deviceID]?[settingID] != expected && Date() < deadline { MainLoop.run(seconds: 0.012) }
    verifier.check("Mac Camera: Apply saves the exact format and FPS in one setting write",
      didApply && writes == [expected] && saved()[deviceID]?[settingID] == expected &&
        state.settings.first(where: { $0.id == settingID })?.value == expected, viewDependent: true)
    applying.close()
  }

  private static func makePattern(_ format: SourceFormat) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    guard CVPixelBufferCreate(nil, format.width, format.height, format.pixel.rawValue, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
      let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw PluginError.failed("Cannot allocate webcam pattern") }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
      guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { throw PluginError.failed("Webcam pattern has no pixels") }
      let bytes = base.assumingMemoryBound(to: UInt8.self)
      for y in 0..<rows {
        for x in 0..<format.width {
          bytes[stride * y + x] = plane == 0 ? UInt8(16 + (x + y) % 219) : UInt8(100 + x % 51)
        }
      }
    }
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
    return buffer
  }

  private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CMSampleBuffer?
    func send(_ sample: CMSampleBuffer) -> Bool { lock.withLock { latest = sample }; return true }
    func matches(width: Int, height: Int, pixel: PixelFormatID, duration: CMTime) -> Bool {
      lock.withLock {
        guard let latest, let image = CMSampleBufferGetImageBuffer(latest) else { return false }
        return CVPixelBufferGetWidth(image) == width && CVPixelBufferGetHeight(image) == height &&
          CVPixelBufferGetPixelFormatType(image) == pixel.rawValue && CMTimeCompare(CMSampleBufferGetDuration(latest), duration) == 0
      }
    }
    func matchesPixels(of input: CVPixelBuffer) -> Bool {
      lock.withLock {
        guard let latest, let output = CMSampleBufferGetImageBuffer(latest), output !== input,
          CVPixelBufferGetIOSurface(output) != nil, CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        let keys = [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
          kCVImageBufferChromaLocationTopFieldKey]
        guard keys.allSatisfy({ key in
          guard let actual = CVBufferCopyAttachment(output, key, nil), let expected = CVBufferCopyAttachment(input, key, nil) else { return false }
          return CFEqual(actual, expected)
        }) else { return false }
        return (0..<CVPixelBufferGetPlaneCount(input)).allSatisfy { plane in
          guard let actual = CVPixelBufferGetBaseAddressOfPlane(output, plane),
            let expected = CVPixelBufferGetBaseAddressOfPlane(input, plane) else { return false }
          let outputStride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
          let inputStride = CVPixelBufferGetBytesPerRowOfPlane(input, plane)
          let activeBytes = CVPixelBufferGetWidth(input)
          return (0..<CVPixelBufferGetHeightOfPlane(input, plane)).allSatisfy { row in
            memcmp(actual.advanced(by: outputStride * row), expected.advanced(by: inputStride * row), activeBytes) == 0
          }
        }
      }
    }
  }
}
