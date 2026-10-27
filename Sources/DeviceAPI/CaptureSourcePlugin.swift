import Foundation

enum Connector: String, Codable, Sendable { case hdmi, sdi, usb, network, optical }
struct CaptureDeviceInfo: Identifiable, Sendable {
  let id: String
  let name: String
  let connectors: [Connector]
  let shareable: Bool
  let mayPause: Duration?
  let supportedModes: String
}
struct CaptureDeviceSnapshot: Sendable {
  let status: DriverStatus
  let devices: [CaptureDeviceInfo]
  let error: PluginError?
}
enum CaptureTiming: Sendable { case automatic, fixed(SourceFormat) }
protocol CaptureSourcePlugin: Sendable {
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
  /// Repeated start while running throws invalidState. Stop is idempotent.
  /// Never call stop synchronously from a delivery callback.
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws
  /// Quiescence barrier; retained frames remain valid after it returns.
  func stop()
  var counters: CaptureCounters { get }
}
struct CaptureHandlers: Sendable { let deliver: @Sendable (CaptureDelivery) -> Void }
