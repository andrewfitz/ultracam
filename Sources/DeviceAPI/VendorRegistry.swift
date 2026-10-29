import Foundation

struct CaptureVendorSnapshot: Sendable {
  let descriptor: VendorDescriptor
  let status: DriverStatus
  let devices: [CaptureDeviceInfo]
  let error: PluginError?
}
struct VendorRegistrySnapshot: Sendable {
  let capture: [CaptureVendorSnapshot]
  var devices: [CaptureDeviceInfo] { capture.flatMap(\.devices) }
}
@MainActor final class VendorRegistryObservation {
  private var handler: (@MainActor @Sendable (VendorRegistrySnapshot) -> Void)?
  init(_ handler: @escaping @MainActor @Sendable (VendorRegistrySnapshot) -> Void) { self.handler = handler }
  func cancel() { handler = nil }
  func deliver(_ snapshot: VendorRegistrySnapshot) { handler?(snapshot) }
}

@MainActor final class VendorRegistry {
  nonisolated let capturePlugins: [any CaptureSourcePlugin]
  nonisolated let controlPlugins: [any CameraControlPlugin]
  let controlViewFactories: [String: ControlViewFactory]
  private(set) var snapshot: VendorRegistrySnapshot
  private var observations: [DeviceObservation] = []
  nonisolated private let configurationErrors: [String: PluginError]
  private var subscribers: [UUID: WeakObservation] = [:]
  private var pending: [VendorRegistrySnapshot] = []
  private var publishing = false
  private struct WeakObservation { weak var value: VendorRegistryObservation? }

  #if !ULTRACAM_REGISTRY_STANDALONE
  nonisolated static let capture: [any CaptureSourcePlugin] = [DeckLinkCapturePlugin()]
  static let control: [any CameraControlPlugin] = [SonyControlPlugin()]
  static func makeLive(settingsPolicy: VendorSettingsPolicy) throws -> VendorRegistry {
    try VendorRegistry(capture: capture, control: control, settingsPolicy: settingsPolicy)
  }
  #endif

  init(capture: [any CaptureSourcePlugin], control: [any CameraControlPlugin] = [],
       controlViewFactories: [String: ControlViewFactory] = [:],
       settingsPolicy: VendorSettingsPolicy = .init()) throws {
    var ids = Set<String>()
    for plugin in capture {
      guard Self.validPluginID(plugin.descriptor.id), ids.insert(plugin.descriptor.id).inserted else {
        throw PluginError.invalidState("Invalid or duplicate capture plugin ID: \(plugin.descriptor.id)")
      }
    }
    ids.removeAll()
    for plugin in control {
      guard Self.validPluginID(plugin.descriptor.id), ids.insert(plugin.descriptor.id).inserted else {
        throw PluginError.invalidState("Invalid or duplicate control plugin ID: \(plugin.descriptor.id)")
      }
    }
    var configurationErrors: [String: PluginError] = [:]
    for plugin in capture {
      do { try plugin.configureSettings(settingsPolicy) }
      catch { configurationErrors[plugin.descriptor.id] = (error as? PluginError) ?? .failed(error.localizedDescription) }
    }
    self.configurationErrors = configurationErrors
    capturePlugins = capture; controlPlugins = control
    self.controlViewFactories = controlViewFactories
    snapshot = VendorRegistrySnapshot(capture: capture.map { plugin in
      if let error = configurationErrors[plugin.descriptor.id] {
        return CaptureVendorSnapshot(descriptor: plugin.descriptor, status: plugin.driverStatus(), devices: [], error: error)
      }
      return Self.enumerate(plugin)
    })
    for (index, plugin) in capture.enumerated() {
      guard configurationErrors[plugin.descriptor.id] == nil else { continue }
      observations.append(plugin.observeDevices { [weak self] update in self?.update(index: index, update: update) })
    }
  }
  nonisolated static func validPluginID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
  }
  nonisolated static func pluginID(for deviceID: String) throws -> String {
    guard let colon = deviceID.firstIndex(of: ":"), deviceID.index(after: colon) < deviceID.endIndex else {
      throw PluginError.invalidState("Malformed device ID")
    }
    let prefix = String(deviceID[..<colon])
    guard validPluginID(prefix) else { throw PluginError.invalidState("Malformed device prefix") }
    return prefix
  }
  nonisolated var readyCapturePlugins: [any CaptureSourcePlugin] {
    capturePlugins.filter { configurationErrors[$0.descriptor.id] == nil }
  }
  nonisolated func capturePlugin(for deviceID: String) throws -> any CaptureSourcePlugin {
    let id = try Self.pluginID(for: deviceID)
    if let error = configurationErrors[id] { throw error }
    guard let plugin = capturePlugins.first(where: { $0.descriptor.id == id }) else { throw PluginError.unavailable("Unknown capture plugin: \(id)") }
    return plugin
  }
  nonisolated func controlPlugin(id: String) -> (any CameraControlPlugin)? { controlPlugins.first { $0.descriptor.id == id } }
  private static func enumerate(_ plugin: any CaptureSourcePlugin) -> CaptureVendorSnapshot {
    do { return checked(plugin.descriptor, CaptureDeviceSnapshot(status: plugin.driverStatus(), devices: try plugin.devices(), error: nil)) }
    catch { return checked(plugin.descriptor, CaptureDeviceSnapshot(status: plugin.driverStatus(), devices: [], error: (error as? PluginError) ?? .failed(error.localizedDescription))) }
  }
  private static func checked(_ descriptor: VendorDescriptor, _ update: CaptureDeviceSnapshot) -> CaptureVendorSnapshot {
    var error = update.error
    var seen = Set<String>()
    if error == nil {
      for device in update.devices {
        if (try? pluginID(for: device.id)) != descriptor.id || !seen.insert(device.id).inserted {
          error = .invalidState("Invalid or duplicate device ID: \(device.id)"); break
        }
      }
    }
    return CaptureVendorSnapshot(descriptor: descriptor, status: update.status, devices: error == nil ? update.devices : [], error: error)
  }
  func refresh() {
    snapshot = VendorRegistrySnapshot(capture: capturePlugins.map { plugin in
      if let error = configurationErrors[plugin.descriptor.id] { return CaptureVendorSnapshot(descriptor: plugin.descriptor, status: plugin.driverStatus(), devices: [], error: error) }
      return Self.enumerate(plugin)
    }); publish()
  }
  private func update(index: Int, update: CaptureDeviceSnapshot) {
    var values = snapshot.capture
    values[index] = Self.checked(capturePlugins[index].descriptor, update)
    snapshot = VendorRegistrySnapshot(capture: values); publish()
  }
  func observe(_ handler: @escaping @MainActor @Sendable (VendorRegistrySnapshot) -> Void) -> VendorRegistryObservation {
    let token = VendorRegistryObservation(handler)
    subscribers[UUID()] = WeakObservation(value: token)
    token.deliver(snapshot)
    return token
  }
  private func publish() {
    pending.append(snapshot)
    guard !publishing else { return }
    publishing = true
    defer { publishing = false }
    while !pending.isEmpty {
      let value = pending.removeFirst()
      subscribers = subscribers.filter { $0.value.value != nil }
      let current = subscribers.values.compactMap(\.value)
      current.forEach { $0.deliver(value) }
    }
  }
}
