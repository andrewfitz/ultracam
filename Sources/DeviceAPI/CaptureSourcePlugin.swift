import Foundation

enum Connector: String, Codable, Sendable { case hdmi, sdi, usb, network, optical }
struct CaptureDeviceInfo: Identifiable, Sendable {
  let id: String
  let name: String
  let connectors: [Connector]
  let shareable: Bool
  let mayPause: Duration?
  let supportedModes: String
  var supportedModesKey: String? = nil
  var localizationTable: String? = nil
  func localizedSupportedModes(in bundle: Bundle = .main) -> String {
    VendorDisplayLocalization.resolve(key: supportedModesKey, fallback: supportedModes, table: localizationTable, in: bundle)
  }
}
struct CaptureDeviceSnapshot: Sendable {
  let status: DriverStatus
  let devices: [CaptureDeviceInfo]
  let error: PluginError?
}
enum CaptureTiming: Equatable, Sendable { case automatic, fixed(SourceFormat) }
protocol CaptureSourcePlugin: VendorSettingsProviding {
  /// Seeds desired policy before SDK discovery/EDID initialization. No capture-start writes.
  func configureSettings(_ policy: VendorSettingsPolicy) throws
  var descriptor: VendorDescriptor { get }
  func driverStatus() -> DriverStatus
  func devices() throws -> [CaptureDeviceInfo]
  @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation
  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat?
  func makeSession() -> any CaptureSession
  func diagnostics(deviceID: String) -> DeviceDiagnostics?
  func settings(deviceID: String) async throws -> [VendorSetting]
  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String) async throws
}
protocol CaptureSession: AnyObject, Sendable {
  /// Same-configuration start is idempotent and preserves original handlers.
  /// Different configuration or a start after stop throws. Stop is idempotent.
  /// Never call stop synchronously from a delivery callback.
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws
  /// Quiescence barrier; retained frames remain valid after it returns.
  func stop()
  var counters: CaptureCounters { get }
}
struct CaptureHandlers: Sendable { let deliver: @Sendable (CaptureDelivery) -> Void }

extension CaptureSourcePlugin {
  func configureSettings(_ policy: VendorSettingsPolicy) throws {}
}
