import Foundation

struct InputDevice: Identifiable, Equatable {
  let id: String
  /// The driver's model name, unchanged. Two units of one model share it; show `label`.
  let name: String
  var shareable: Bool = false
  var mayPause: Duration? = nil
  var supportedModes: String = ""

  init(id: String, name: String, shareable: Bool = false, mayPause: Duration? = nil, supportedModes: String = "") {
    self.id = id; self.name = name; self.shareable = shareable; self.mayPause = mayPause; self.supportedModes = supportedModes
  }
  init(_ device: CaptureDeviceInfo) {
    self.init(id: device.id, name: device.name, shareable: device.shareable, mayPause: device.mayPause, supportedModes: device.localizedSupportedModes())
  }
}

extension Array where Element == InputDevice {
  /// The device's label in this list (`UIInputLabels.label`); nil when it isn't listed.
  func label(for id: String) -> String? {
    guard let device = first(where: { $0.id == id }) else { return nil }
    return UIInputLabels.label(id: id, name: device.name, among: map { ($0.id, $0.name) })
  }
}

@MainActor protocol AppVirtualCameraRegistryPublishing {
  func publish(_ snapshot: VirtualCameraRegistrySnapshot)
}

extension VirtualCameraRegistryPublisher: AppVirtualCameraRegistryPublishing {}

/// AppModel's paths to capture plugins and the per-camera extension
/// streams. Tools that build a real model, such as ui-verify, pass `.offline`
/// so they can never open the user's capture device or send to their camera.
/// The Program stream connects only behind a running camera, which `.offline`
/// can't start.
@MainActor struct AppHardware {
  var captureServices: (FeedID) -> CaptureServices
  var devices: () throws -> [InputDevice]
  var driverWarning: () -> String?
  var observeDevices: (@escaping @MainActor @Sendable ([InputDevice]) -> Void) -> Any?
  /// Calls the handler whenever CMIO's device list changes (the camera extension starting,
  /// its cameras appearing). Holds the observation until the returned value is released.
  var observeVirtualCameras: (@escaping @MainActor @Sendable () -> Void) -> Any? = { _ in nil }
  var diagnostics: (String) -> DeviceDiagnostics?
  var settingsPlugins: () -> [any VendorSettingsProviding] = { [] }
  var controlPlugins: () -> [any CameraControlPlugin] = { [] }
  var captureDescriptor: (String) -> VendorDescriptor? = { _ in nil }
  var controlViewFactories: () -> [String: ControlViewFactory] = { [:] }
  var setCompatibilityPolicy: (RecordingCompatibilityPolicy) -> Void = { _ in }

  static let live: AppHardware = {
    var policy = VendorSettingsPolicy()
    var policyMessage: String?
    do { policy = try VendorSettingsPreferences().load() }
    catch { policyMessage = error.localizedDescription }
    do {
      let registry = try VendorRegistry.makeLive(settingsPolicy: policy)
      var hardware = AppHardware.registry(registry)
      hardware.observeVirtualCameras = { CMIODeviceListWatcher(changed: $0) }
      if let policyMessage {
        let previousWarning = hardware.driverWarning
        hardware.driverWarning = { [previousWarning] in [policyMessage, previousWarning()].compactMap { $0 }.joined(separator: "\n") }
      }
      return hardware
    } catch {
      var hardware = offline
      let message = error.localizedDescription
      hardware.driverWarning = { message }
      return hardware
    }
  }()

  /// Every feed resolves its plugin at start. Discovery failures affect only the
  /// failing vendor, and the projection preserves saved device IDs verbatim.
  static func registry(_ registry: VendorRegistry,
                       captureServices: ((FeedID) -> CaptureServices)? = nil) -> AppHardware {
    let claims = CaptureDeviceClaims()
    let compatibility = CaptureCompatibilityPolicySnapshot()
    return AppHardware(
      captureServices: captureServices ?? { id in
        .registry(feedID: id, plugins: registry.readyCapturePlugins, claims: claims,
          compatibilityPolicy: { _ in compatibility.snapshot })
      },
      devices: {
        registry.refresh()
        return registry.snapshot.devices.map { InputDevice($0) }
      },
      driverWarning: {
        let warning = registry.snapshot.capture.compactMap { vendor -> String? in
          if let error = vendor.error { return "\(vendor.descriptor.localizedDisplayName()): \(error.localizedDescription)" }
          guard !vendor.status.installed || !vendor.status.supported else { return nil }
          return "\(vendor.descriptor.localizedDisplayName()): \(vendor.status.reason ?? "Driver unavailable")"
        }.joined(separator: "\n")
        return warning.isEmpty ? nil : warning
      },
      observeDevices: { handler in
        registry.observe { snapshot in
          handler(snapshot.devices.map { InputDevice($0) })
        }
      },
      diagnostics: { id in (try? registry.capturePlugin(for: id))?.diagnostics(deviceID: id) },
      settingsPlugins: { registry.readyCapturePlugins.map { $0 as any VendorSettingsProviding } },
      controlPlugins: { registry.controlPlugins },
      captureDescriptor: { id in (try? registry.capturePlugin(for: id))?.descriptor },
      controlViewFactories: { registry.controlViewFactories },
      setCompatibilityPolicy: { compatibility.update($0) })
  }

  /// No devices; starting a camera fails with an error and nothing is sent.
  static let offline = AppHardware(
    captureServices: { _ in
      CaptureServices(
        startTyped: { _, _, _ in throw CocoaError(.featureUnsupported) },
        stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in false })
    },
    devices: { [] }, driverWarning: { nil }, observeDevices: { _ in nil }, diagnostics: { _ in nil })
}


/// SDK start queues read a value snapshot, never preferences or MainActor state.
final class CaptureCompatibilityPolicySnapshot: @unchecked Sendable {
  private let lock = NSLock()
  private var value = RecordingCompatibilityPolicy()
  var snapshot: RecordingCompatibilityPolicy { lock.withLock { value } }
  func update(_ policy: RecordingCompatibilityPolicy) { lock.withLock { value = policy } }
}
