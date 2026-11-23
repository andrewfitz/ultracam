import AVFoundation
import Foundation
import IOKit.audio

final class MacCameraCapturePlugin: CaptureSourcePlugin, @unchecked Sendable {
  private struct SessionClaim {
    let token: UUID
    weak var session: MacCameraCaptureSession?
  }
  private struct WeakDeviceObserver: Sendable { weak var value: DeviceObservation? }
  private struct WeakStatusObserver: Sendable { weak var value: DeviceStatusObservation? }
  private struct DeviceFallbacks {
    let device: ObjectIdentifier
    var byMode: [String: Set<OSType>] = [:]
  }

  let descriptor = VendorDescriptor(id: "maccamera", displayName: "Mac Camera", badgeText: "MAC",
    signalHint: "Check that the camera is connected and Camera access is enabled.", sdkVersion: nil,
    sdkPresent: true, displayNameKey: "vendor.name", signalHintKey: "vendor.signalHint",
    localizationTable: "MacCamera", missingDeviceHint: "Connect the assigned camera or select its current device in Input.",
    missingDeviceHintKey: "vendor.missingDeviceHint", captureAudio: .microphone)
  private let queue = DispatchQueue(label: "Ultracam.MacCamera.inventory", qos: .userInitiated)
  private let queueKey = DispatchSpecificKey<UInt8>()
  private var discovery: AVCaptureDevice.DiscoverySession?
  private var discoveryObservation: NSKeyValueObservation?
  private let identityDefaults: UserDefaults
  private var ambiguousUIDs: Set<String>
  private var deviceObservers: [UUID: WeakDeviceObserver] = [:]
  private var statusObservers: [UUID: WeakStatusObserver] = [:]
  private var statuses: [String: CaptureDeviceStatus] = [:]
  private var diagnostics: [String: DeviceDiagnostics] = [:]
  private var availableFallbacks: [String: DeviceFallbacks] = [:]
  private var sessions: [String: SessionClaim] = [:]
  private let desiredLock = NSLock()
  private var desired = VendorSettingsPolicy()
  @MainActor private static var videoAuthorization: Task<Bool, Never>?

  static let modeKey = "captureMode"
  static let fallbackKey = "captureFallback"
  private static let prefix = "maccamera:"
  private static let ambiguousUIDsKey = "ultracam.macCamera.ambiguousDeviceUIDs.v1"
  private static let ambiguousDevice = PluginError.unavailable(
    "Multiple connected cameras reported the same device ID. Ultracam cannot safely identify the assigned camera. Select a device with a unique ID.")
  private static let cameraAccessError = PluginError.unavailable(
    "Mac Camera access is disabled. Enable Ultracam in System Settings › Privacy & Security › Camera.")

  init(identityDefaults: UserDefaults = .standard) {
    self.identityDefaults = identityDefaults
    ambiguousUIDs = Set(identityDefaults.stringArray(forKey: Self.ambiguousUIDsKey) ?? [])
    queue.setSpecific(key: queueKey, value: 1)
  }

  func withQueue<T>(_ action: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return try action() }
    return try queue.sync(execute: action)
  }

  func configureSettings(_ policy: VendorSettingsPolicy) throws {
    desiredLock.withLock { desired = policy }
  }

  func selection(for id: String, setting: String) -> VendorSettingValue? {
    desiredLock.withLock { desired.desiredByDevice[id]?[setting] ?? desired.inheritedByPlugin[descriptor.id]?[setting] }
  }

  private func setSelection(_ value: VendorSettingValue, for id: String, setting: String) {
    desiredLock.withLock { desired.desiredByDevice[id, default: [:]][setting] = value }
  }

  func microphone(for id: String) -> String? {
    if case .choice(let value) = selection(for: id, setting: MacCameraAudio.settingsKey) { return value }
    return nil
  }

  func authorizationStatus(deviceID: String?) -> CaptureAuthorizationStatus {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      if let deviceID, let selection = microphone(for: deviceID), selection != "off",
         AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { return .requestable }
      return .authorized
    case .notDetermined: return .requestable
    case .denied, .restricted: return .unavailable(Self.cameraAccessError)
    @unknown default: return .unavailable(Self.cameraAccessError)
    }
  }

  @MainActor func authorizeCapture(deviceID: String?) async throws {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: break
    case .notDetermined:
      let prompt = Self.videoAuthorization ?? Task { await AVCaptureDevice.requestAccess(for: .video) }
      Self.videoAuthorization = prompt
      let granted = await prompt.value
      Self.videoAuthorization = nil
      queue.async { [weak self] in self?.publishDevices() }
      guard granted else { throw Self.cameraAccessError }
    case .denied, .restricted: throw Self.cameraAccessError
    @unknown default: throw Self.cameraAccessError
    }
    try Task.checkCancellation()
    if let deviceID { await MacCameraAudio.authorize(selection: microphone(for: deviceID)) }
  }

  func driverStatus() -> DriverStatus {
    let reason: String?
    if case .unavailable(let error) = authorizationStatus(deviceID: nil) { reason = error.localizedDescription }
    else { reason = nil }
    return DriverStatus(installed: true, supported: reason == nil, version: nil, reason: reason, title: "AVFoundation")
  }

  private func allDevices() -> [AVCaptureDevice] {
    if discovery == nil {
      let session = AVCaptureDevice.DiscoverySession(deviceTypes: [
        .builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera
      ], mediaType: .video, position: .unspecified)
      discovery = session
      discoveryObservation = session.observe(\.devices, options: [.new]) { [weak self] _, change in
        // Preserve the observed collision even if another discovery update
        // removes one of the devices before the inventory queue runs.
        let identities = change.newValue.map(Self.discoveryIdentities) ?? []
        self?.queue.async { [weak self] in
          self?.quarantineDuplicateUIDs(identities)
          self?.publishDevices()
        }
      }
    }
    let devices = discovery?.devices.filter { Self.includes(uid: $0.uniqueID) && $0.isConnected } ?? []
    quarantineDuplicateUIDs(Self.discoveryIdentities(devices))
    var seen = Set<String>()
    return devices.filter { !ambiguousUIDs.contains($0.uniqueID) && seen.insert($0.uniqueID).inserted }
  }

  private struct DiscoveryIdentity: Sendable {
    let uid: String
    let object: ObjectIdentifier
  }

  private static func discoveryIdentities(_ devices: [AVCaptureDevice]) -> [DiscoveryIdentity] {
    devices.compactMap {
      guard includes(uid: $0.uniqueID), $0.isConnected else { return nil }
      return DiscoveryIdentity(uid: $0.uniqueID, object: ObjectIdentifier($0))
    }
  }

  private func quarantineDuplicateUIDs(_ identities: [DiscoveryIdentity]) {
    var objects: [String: ObjectIdentifier] = [:]
    var changed = false
    for identity in identities {
      if let prior = objects.updateValue(identity.object, forKey: identity.uid), prior != identity.object {
        if ambiguousUIDs.insert(identity.uid).inserted { changed = true }
      }
    }
    if changed { identityDefaults.set(ambiguousUIDs.sorted(), forKey: Self.ambiguousUIDsKey) }
  }

  func unavailableDeviceError(_ id: String) -> PluginError {
    withQueue {
      if id.hasPrefix(Self.prefix), ambiguousUIDs.contains(String(id.dropFirst(Self.prefix.count))) {
        return Self.ambiguousDevice
      }
      return .unavailable("The assigned Mac Camera is disconnected.")
    }
  }

  #if CAPTURE_LIFECYCLE_TESTS
  func observeFixtureIdentities(_ identities: [(String, ObjectIdentifier)]) {
    withQueue {
      quarantineDuplicateUIDs(identities.map { DiscoveryIdentity(uid: $0.0, object: $0.1) })
    }
  }

  @MainActor func observeFixtureStatus(_ handler: @escaping @MainActor @Sendable (String, CaptureDeviceStatus) -> Void)
    -> DeviceStatusObservation {
    registerStatusObserver(handler)
  }
  #endif

  static func includes(uid: String) -> Bool { !uid.isEmpty && !VirtualCameraDescriptor.isDeviceUID(uid) }
  static func id(for uid: String) -> String { prefix + uid }

  func device(_ id: String) -> AVCaptureDevice? {
    withQueue {
      guard id.hasPrefix(Self.prefix) else { return nil }
      let uid = String(id.dropFirst(Self.prefix.count))
      guard Self.includes(uid: uid) else { return nil }
      return allDevices().first { $0.uniqueID == uid }
    }
  }

  func devices() throws -> [CaptureDeviceInfo] {
    if case .unavailable(let error) = authorizationStatus(deviceID: nil) { throw error }
    return withQueue { allDevices().map(deviceInfo) }
  }

  private func deviceInfo(_ device: AVCaptureDevice) -> CaptureDeviceInfo {
    var seen = Set<SourceFormat>()
    let catalog = device.formats.map(MacCameraMode.init).filter { !$0.rates.isEmpty }
    let formats = catalog.flatMap { mode in
      mode.rates.compactMap { try? mode.sourceFormat(rate: .constant($0.duration), clock: .deviceClock) }
    }.filter { seen.insert($0).inserted }
    return CaptureDeviceInfo(id: Self.id(for: device.uniqueID), name: device.localizedName, connectors: [],
      shareable: false, mayPause: device.isContinuityCamera ? .seconds(30) : nil,
      supportedModes: "\(catalog.count) capture formats", model: device.modelID, modes: formats)
  }

  private func snapshot() -> CaptureDeviceSnapshot {
    let status = driverStatus()
    if let reason = status.reason {
      return CaptureDeviceSnapshot(status: status, devices: [], error: .unavailable(reason))
    }
    let devices = allDevices().map(deviceInfo)
    return CaptureDeviceSnapshot(status: status, devices: devices, error: nil)
  }

  @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation {
    let token = DeviceObservation(handler)
    let id = UUID()
    withQueue { deviceObservers[id] = WeakDeviceObserver(value: token) }
    token.onCancel { [weak self] in
      self?.queue.async { [weak self] in self?.deviceObservers.removeValue(forKey: id) }
    }
    queue.async { [weak self] in self?.publishDevices() }
    return token
  }

  private func publishDevices() {
    let snapshot = snapshot()
    let observations = Array(deviceObservers.values)
    DispatchQueue.main.async {
      for observation in observations { observation.value?.deliver(snapshot) }
    }
    refreshIdleStatuses()
  }

  func status(deviceID: String) -> CaptureDeviceStatus? { withQueue { statuses[deviceID] } }
  func diagnostics(deviceID: String) -> DeviceDiagnostics? { withQueue { diagnostics[deviceID] } }

  @MainActor func observeStatus(_ handler: @escaping @MainActor @Sendable (String, CaptureDeviceStatus) -> Void) -> DeviceStatusObservation? {
    let token = registerStatusObserver(handler)
    refreshIdleStatus()
    return token
  }

  @MainActor private func registerStatusObserver(_ handler: @escaping @MainActor @Sendable (String, CaptureDeviceStatus) -> Void)
    -> DeviceStatusObservation {
    let token = DeviceStatusObservation(handler)
    let id = UUID()
    withQueue { statusObservers[id] = WeakStatusObserver(value: token) }
    token.onCancel { [weak self] in
      self?.queue.async { [weak self] in self?.statusObservers.removeValue(forKey: id) }
    }
    return token
  }

  func refreshIdleStatus() { queue.async { [weak self] in self?.refreshIdleStatuses() } }

  private func refreshIdleStatuses() {
    let devices = allDevices()
    let connectedIDs = Set(devices.map { Self.id(for: $0.uniqueID) })
    let quarantined = ambiguousUIDs.map(Self.id)
    let activeIDs = connectedIDs.union(sessions.keys).union(quarantined)
    statuses = statuses.filter { activeIDs.contains($0.key) }
    diagnostics = diagnostics.filter { connectedIDs.contains($0.key) || sessions[$0.key] != nil }
    availableFallbacks = availableFallbacks.filter { connectedIDs.contains($0.key) }
    for id in quarantined where sessions[id] == nil {
      var status = CaptureDeviceStatus()
      status.problems = [DeviceProblem(id: "ambiguous-camera-id", severity: .warning,
        title: "Duplicate camera device ID", detail: Self.ambiguousDevice.localizedDescription)]
      publish(status, id: id)
    }
    for device in devices {
      let id = Self.id(for: device.uniqueID)
      if sessions[id] == nil { publish(Self.baseStatus(device, running: false), id: id) }
    }
  }

  func publish(_ status: CaptureDeviceStatus, id: String, diagnostics: DeviceDiagnostics? = nil) {
    if let diagnostics { self.diagnostics[id] = diagnostics }
    guard statuses[id] != status else { return }
    statuses[id] = status
    let observations = Array(statusObservers.values)
    DispatchQueue.main.async {
      for observation in observations { observation.value?.deliver(id, status) }
    }
  }

  func publishSessionStatus(_ status: CaptureDeviceStatus, id: String, diagnostics: DeviceDiagnostics,
    token: UUID) {
    queue.async { [weak self] in
      guard let self, self.sessions[id]?.token == token else { return }
      self.publish(status, id: id, diagnostics: diagnostics)
    }
  }

  func beginSession(_ id: String, token: UUID, owner: MacCameraCaptureSession) throws {
    try withQueue {
      // A weak reference clears before deinit completes. The value token
      // reserves this device until the old graph has fully stopped.
      guard sessions[id] == nil else { throw PluginError.busy("This Mac Camera is already capturing in Ultracam.") }
      sessions[id] = SessionClaim(token: token, session: owner)
      diagnostics[id] = nil
    }
  }

  func rememberFallbacks(_ pixels: [OSType], modeID: String, deviceID: String, device: ObjectIdentifier, token: UUID) {
    queue.async { [weak self] in
      guard let self, self.sessions[deviceID]?.token == token else { return }
      var cached = self.availableFallbacks[deviceID] ?? DeviceFallbacks(device: device)
      if cached.device != device { cached = DeviceFallbacks(device: device) }
      cached.byMode[modeID] = Set(pixels)
      self.availableFallbacks[deviceID] = cached
    }
  }

  private func fallbackPixels(device: AVCaptureDevice, deviceID: String, modeID: String) -> Set<OSType>? {
    withQueue {
      guard let cached = availableFallbacks[deviceID], cached.device == ObjectIdentifier(device) else { return nil }
      return cached.byMode[modeID]
    }
  }

  func endSession(_ id: String, token: UUID) {
    withQueue {
      guard sessions[id]?.token == token else { return }
      sessions[id] = nil
      if discovery != nil, let device = device(id) { publish(Self.baseStatus(device, running: false), id: id) }
      else {
        statuses[id] = nil
        diagnostics[id] = nil
        availableFallbacks[id] = nil
      }
    }
  }

  // Snapshot the running session under the inventory queue, then ask its own
  // queue to perform AVFoundation reads or writes. The inventory queue never
  // waits for a session queue.
  private func withDevice<T>(_ id: String, _ work: (AVCaptureDevice, Bool) throws -> T) throws -> T {
    if let claim = withQueue({ sessions[id] }) {
      // Promote the weak reference on the caller. Releasing the last strong
      // reference on the inventory queue would prevent deinit from using it.
      guard let session = claim.session else { throw PluginError.busy("The Mac Camera is stopping. Try again shortly.") }
      return try session.withDevice(work)
    }
    return try withQueue {
      guard let device = device(id) else { throw unavailableDeviceError(id) }
      guard sessions[id] == nil else { throw PluginError.busy("The Mac Camera is starting capture. Try again shortly.") }
      return try work(device, false)
    }
  }

  static func baseStatus(_ device: AVCaptureDevice, running: Bool) -> CaptureDeviceStatus {
    let link: DeviceLinkKind = switch Int(device.transportType) {
    case kIOAudioDeviceTransportTypePCI: .pcie
    case kIOAudioDeviceTransportTypeUSB: .usb
    case kIOAudioDeviceTransportTypeThunderbolt: .thunderbolt
    case kIOAudioDeviceTransportTypeBluetooth: .bluetooth
    case kIOAudioDeviceTransportTypeVirtual: .software
    default: .unknown
    }
    let kind: String?
    if device.deviceType == .deskViewCamera { kind = "Desk View" }
    else if device.isContinuityCamera { kind = "Continuity Camera" }
    else if device.deviceType == .builtInWideAngleCamera { kind = "Built-in camera" }
    else if link == .software { kind = "Virtual camera" }
    else { kind = nil }
    var status = CaptureDeviceStatus(availability: running ? .inUseHere :
      (device.isInUseByAnotherApplication ? .inUseElsewhere : .free), link: link)
    if let kind { status.facts.append(DeviceFact(id: "camera-kind", group: .identity, label: "Kind", values: [kind])) }
    if !device.manufacturer.isEmpty {
      status.facts.append(DeviceFact(id: "manufacturer", group: .identity, label: "Manufacturer", values: [device.manufacturer]))
    }
    if device.isSuspended {
      status.problems.append(DeviceProblem(id: "suspended", severity: .notice, title: "macOS paused this camera."))
    }
    return status
  }

  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat? {
    if case .fixed(let format) = timing { return format }
    return nil
  }

  func makeSession() -> any CaptureSession { MacCameraCaptureSession(plugin: self) }

  struct RequestedMode {
    let mode: MacCameraMode
    let duration: CMTime?
    let fallback: OSType?
    var label: String { [mode.label, duration.map(MacCameraMode.rateLabel)].compactMap { $0 }.joined(separator: " · ") }
  }

  func resolveMode(for device: AVCaptureDevice, id: String, timing: CaptureTiming) throws -> RequestedMode {
    let selection = selection(for: id, setting: Self.modeKey) ?? VendorCaptureMode.automatic
    let mode: MacCameraMode
    let duration: CMTime?
    if case .fixed(let requested) = timing {
      let matches = Self.catalog(device).filter {
        $0.width == requested.width && $0.height == requested.height &&
          $0.pixel == requested.pixel.rawValue && $0.supports(requested.rate.nominal)
      }
      guard !requested.rate.isVariable, matches.count == 1, let match = matches.first else {
        throw PluginError.unsupported("The fixed Mac Camera mode is missing or ambiguous. Select a specific Capture Format in Hardware.")
      }
      mode = match
      duration = requested.rate.nominal
    } else if selection == VendorCaptureMode.automatic {
      mode = MacCameraMode(device.activeFormat)
      duration = nil
    } else {
      guard let saved = VendorCaptureMode(selection: selection),
        let match = Self.catalog(device).first(where: { $0.id == saved.formatID }) else {
        throw PluginError.unsupported("The saved Mac Camera Capture Format is unavailable. Select another format in Hardware.")
      }
      guard match.supports(saved.duration) else {
        throw PluginError.unsupported("The saved Mac Camera Frame Rate is outside the format's advertised rate ranges.")
      }
      mode = match
      duration = saved.duration
    }
    let fallback = Self.parseFallback(selectionForFallback(id), modeID: Self.fallbackScope(formatID: mode.id, duration: duration))
    return RequestedMode(mode: mode, duration: duration, fallback: fallback)
  }

  private func selectionForFallback(_ id: String) -> VendorSettingValue {
    selection(for: id, setting: Self.fallbackKey) ?? .choice("native")
  }

  private static func catalog(_ device: AVCaptureDevice) -> [MacCameraMode] {
    var seen = Set<String>()
    return device.formats.map(MacCameraMode.init).filter { !$0.rates.isEmpty && seen.insert($0.id).inserted }
  }

  private static func fallbackScope(formatID: String, duration: CMTime?) -> String {
    let rate = duration.map(MacCameraMode.timeID) ?? "automatic"
    return formatID + "@" + rate
  }

  // Choices require consent for an exact source format and requested cadence. The driver's
  // output list is checked again with the active format before starting capture.
  private static let fallbackPixels: [PixelFormatID] = [.v210, .twoVuy, .video420, .full420, .bgra8]
  static func parseFallback(_ selection: VendorSettingValue, modeID: String) -> OSType? {
    guard case .choice(let id) = selection, id.hasPrefix(modeID + ":"),
      let pixel = OSType(id.dropFirst(modeID.count + 1)), fallbackPixels.contains(PixelFormatID(rawValue: pixel)) else { return nil }
    return pixel
  }

  func settings(deviceID: String) async throws -> [VendorSetting] {
    try withDevice(deviceID) { device, running in
      let reason = running ? "Stop capture to change this setting." : nil
      let selected = selection(for: deviceID, setting: Self.modeKey) ?? VendorCaptureMode.automatic
      let catalog = Self.catalog(device)
      var mode = VendorSetting(id: Self.modeKey, labelKey: "capture.format", value: selected, allowedValues: .unrestricted,
        mutable: !running, availabilityReason: reason, interruptsCapture: true,
        labelFallback: "Capture Format", localizationTable: "MacCamera")
      mode.captureFormats = catalog.map(\.settingFormat)
      if selected != VendorCaptureMode.automatic {
        if let saved = VendorCaptureMode(selection: selected), let match = catalog.first(where: { $0.id == saved.formatID }) {
          if !match.supports(saved.duration) { mode.applicationError = .unsupported("The saved Frame Rate is unavailable for this Capture Format.") }
        } else { mode.applicationError = .unsupported("The saved Capture Format is unavailable.") }
      }
      let active = MacCameraMode(device.activeFormat)
      let savedMode = VendorCaptureMode(selection: selected)
      let target = savedMode.flatMap { saved in catalog.first { $0.id == saved.formatID } } ?? active
      let fallbackScope = Self.fallbackScope(formatID: target.id, duration: savedMode?.duration)
      let available = fallbackPixels(device: device, deviceID: deviceID, modeID: target.id)
      let native = PixelFormatTable.entry(for: PixelFormatID(rawValue: target.pixel))
      let pixels = native?.captureQualified == true ? [] : Self.fallbackPixels.filter { available?.contains($0.rawValue) ?? true }
      let candidate = selectionForFallback(deviceID)
      let fallback = VendorSetting(id: Self.fallbackKey, labelKey: "capture.delivery",
        value: Self.parseFallback(candidate, modeID: fallbackScope) == nil || pixels.isEmpty ? .choice("native") : candidate,
        allowedValues: .choices([.init(id: "native", label: "Device Format")] + pixels.map { pixel in
          let subtype = MacCameraMode.macCameraSubtypeName(pixel.rawValue)
          let depth = PixelFormatTable.entry(for: pixel)?.bitDepth ?? 0
          return .init(id: "\(fallbackScope):\(pixel.rawValue)", label: "Allow \(subtype) · \(depth)-bit conversion")
        }), mutable: !running && !pixels.isEmpty, availabilityReason: reason, interruptsCapture: true,
        labelFallback: "Input Delivery", localizationTable: "MacCamera", interruption: .video)
      var audio = MacCameraAudio.setting(for: device, selected: microphone(for: deviceID))
      audio.interruption = .audio
      if running {
        audio = VendorSetting(id: audio.id, labelKey: audio.labelKey, value: audio.value, allowedValues: audio.allowedValues,
          mutable: false, availabilityReason: reason, interruptsCapture: true, labelFallback: audio.labelFallback,
          localizationTable: audio.localizationTable, interruption: .audio)
      }
      return [mode, fallback, audio] + Self.controls(for: device)
    }
  }

  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String) async throws {
    try value.validate()
    if setting == MacCameraAudio.settingsKey {
      try withDevice(deviceID) { device, running in
        guard !running else {
          if selection(for: deviceID, setting: setting) == value { return }
          throw PluginError.busy("Stop capture to change the microphone.")
        }
        let settings = MacCameraAudio.setting(for: device, selected: microphone(for: deviceID))
        guard case .choice(let uid) = value, case .choices(let choices) = settings.allowedValues,
          choices.contains(where: { $0.id == uid }) else { throw PluginError.unsupported("The selected microphone is unavailable.") }
        setSelection(value, for: deviceID, setting: setting)
      }
      if case .choice(let uid) = value { await MacCameraAudio.authorize(selection: uid) }
      return
    }
    try withDevice(deviceID) { device, running in
      switch setting {
      case Self.modeKey, Self.fallbackKey:
        if selection(for: deviceID, setting: setting) == value { return }
        guard !running else { throw PluginError.busy("Stop capture before changing the Mac Camera mode.") }
        if setting == Self.modeKey, value != VendorCaptureMode.automatic {
          guard let selected = VendorCaptureMode(selection: value),
            let format = Self.catalog(device).first(where: { $0.id == selected.formatID }),
            format.supports(selected.duration) else {
            throw PluginError.unsupported("Choose a capture format and a rate inside one of its supported ranges.")
          }
        }
        if setting == Self.fallbackKey, value != .choice("native") {
          let requested = try resolveMode(for: device, id: deviceID, timing: .automatic)
          guard PixelFormatTable.entry(for: PixelFormatID(rawValue: requested.mode.pixel))?.captureQualified != true,
            let pixel = Self.parseFallback(value, modeID: Self.fallbackScope(formatID: requested.mode.id, duration: requested.duration)),
            fallbackPixels(device: device, deviceID: deviceID, modeID: requested.mode.id)?.contains(pixel) != false else {
            throw PluginError.unsupported("Choose a delivery conversion for the selected Capture Format.")
          }
        }
        setSelection(value, for: deviceID, setting: setting)
      default: try Self.applyControl(value, setting: setting, device: device)
      }
    }
  }

  private static func controls(for device: AVCaptureDevice) -> [VendorSetting] {
    [
      control(id: "focus", label: "Focus", current: device.focusMode.rawValue,
        choices: [(.locked, "Locked"), (.autoFocus, "Auto"), (.continuousAutoFocus, "Continuous Auto")],
        supported: device.isFocusModeSupported),
      control(id: "exposure", label: "Exposure", current: device.exposureMode.rawValue,
        choices: [(.locked, "Locked"), (.autoExpose, "Auto"), (.continuousAutoExposure, "Continuous Auto")],
        supported: device.isExposureModeSupported),
      control(id: "whiteBalance", label: "White Balance", current: device.whiteBalanceMode.rawValue,
        choices: [(.locked, "Locked"), (.autoWhiteBalance, "Auto"), (.continuousAutoWhiteBalance, "Continuous Auto")],
        supported: device.isWhiteBalanceModeSupported)
    ].compactMap { $0 }
  }

  private static func control<Mode: RawRepresentable>(id: String, label: String, current: Int,
    choices: [(Mode, String)], supported: (Mode) -> Bool) -> VendorSetting? where Mode.RawValue == Int {
    let options = choices.filter { supported($0.0) }.map { VendorSetting.Choice(id: String($0.0.rawValue), label: $0.1) }
    guard !options.isEmpty else { return nil }
    return VendorSetting(id: id, labelKey: label, value: .choice(String(current)), allowedValues: .choices(options),
      mutable: options.count > 1, availabilityReason: nil, interruptsCapture: false)
  }

  private static func applyControl(_ value: VendorSettingValue, setting: String, device: AVCaptureDevice) throws {
    guard case .choice(let choice) = value, let raw = Int(choice),
      let control = controls(for: device).first(where: { $0.id == setting }),
      case .choices(let choices) = control.allowedValues, choices.contains(where: { $0.id == choice }) else {
      throw PluginError.unsupported("This Mac Camera does not support the requested control value.")
    }
    if control.value == value { return }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    guard device.isConnected else { throw PluginError.unavailable("The Mac Camera disconnected before applying its settings.") }
    switch setting {
    case "focus":
      guard let mode = AVCaptureDevice.FocusMode(rawValue: raw), device.isFocusModeSupported(mode) else { break }
      device.focusMode = mode
      if device.focusMode == mode { return }
    case "exposure":
      guard let mode = AVCaptureDevice.ExposureMode(rawValue: raw), device.isExposureModeSupported(mode) else { break }
      device.exposureMode = mode
      if device.exposureMode == mode { return }
    case "whiteBalance":
      guard let mode = AVCaptureDevice.WhiteBalanceMode(rawValue: raw), device.isWhiteBalanceModeSupported(mode) else { break }
      device.whiteBalanceMode = mode
      if device.whiteBalanceMode == mode { return }
    default: break
    }
    throw PluginError.failed("The Mac Camera did not apply the requested \(control.labelKey) mode.")
  }
}
