import Foundation

/// How a capture device reaches the Mac, as its driver reports it.
enum DeviceLinkKind: String, Codable, Sendable { case pcie, thunderbolt, usb, ethernet, wifi, bluetooth, software, unknown }

/// Whether a device can be opened. Its plugin knows its own sessions, so it can tell
/// Ultracam's use from another app's; it can't name the other app.
enum DeviceAvailability: Equatable, Sendable { case unknown, free, inUseHere, inUseElsewhere }

/// One row of a device's expanded entry in Settings › Hardware. Groups fix the order, so a
/// host needs no vendor knowledge to lay them out. `values` are separate typed pieces
/// ("Thunderbolt", "PCIe x4 Gen3"), shown apart with spacing, never joined with dots.
struct DeviceFact: Equatable, Sendable, Identifiable {
  enum Group: Int, Sendable, Comparable {
    case identity, connection, signal, audio, sync, power, media, other
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }
  let id: String
  let group: Group
  let label: String
  let values: [String]
  var labelKey: String? = nil
  var localizationTable: String? = nil
  func localizedLabel(in bundle: Bundle = .main) -> String {
    VendorDisplayLocalization.resolve(key: labelKey, fallback: label, table: localizationTable, in: bundle)
  }
}

/// Something wrong with a device, in the plugin's words. The SDK can't always say why
/// (another app holding a device can't be named), and the text never pretends to.
struct DeviceProblem: Equatable, Sendable, Identifiable {
  let id: String
  let severity: DeviceSeverity
  let title: String
  var detail: String? = nil
  var titleKey: String? = nil
  var detailKey: String? = nil
  var localizationTable: String? = nil
  func localizedTitle(in bundle: Bundle = .main) -> String {
    VendorDisplayLocalization.resolve(key: titleKey, fallback: title, table: localizationTable, in: bundle)
  }
  func localizedDetail(in bundle: Bundle = .main) -> String? {
    detail.map { VendorDisplayLocalization.resolve(key: detailKey, fallback: $0, table: localizationTable, in: bundle) }
  }
}

/// A capture device's cached status. A nil field is unknown, never "no": an idle device
/// whose driver doesn't report a lock reads as unknown, not as "No signal".
struct CaptureDeviceStatus: Equatable, Sendable {
  var availability: DeviceAvailability = .unknown
  var link: DeviceLinkKind = .unknown
  /// The connector the device captures from, when the plugin knows it.
  var connector: Connector? = nil
  var signalLocked: Bool? = nil
  /// The detected input's size and rate.
  var detected: SourceFormat? = nil
  var facts: [DeviceFact] = []
  var problems: [DeviceProblem] = []
}

/// Main-actor delivery and cancellation share this token, as `DeviceObservation` does for
/// the device list. Queued notifications call `deliver`, which checks cancellation first.
@MainActor final class DeviceStatusObservation {
  private var handler: (@MainActor @Sendable (String, CaptureDeviceStatus) -> Void)?
  private var cleanup: (@MainActor @Sendable () -> Void)?
  init(_ handler: @escaping @MainActor @Sendable (String, CaptureDeviceStatus) -> Void) { self.handler = handler }
  func onCancel(_ cleanup: @escaping @MainActor @Sendable () -> Void) {
    guard handler != nil else { cleanup(); return }
    self.cleanup = cleanup
  }
  func cancel() {
    handler = nil
    let action = cleanup
    cleanup = nil
    action?()
  }
  deinit {
    let action = cleanup
    Task { @MainActor in action?() }
  }
  func deliver(_ deviceID: String, _ status: CaptureDeviceStatus) { handler?(deviceID, status) }
}

extension CaptureSourcePlugin {
  /// Cached. Never calls the driver on the caller's thread and never opens an input.
  func status(deviceID: String) -> CaptureDeviceStatus? { nil }
  /// Delivers each device's status on the main actor whenever it changes.
  @MainActor func observeStatus(_ handler: @escaping @MainActor @Sendable (String, CaptureDeviceStatus) -> Void) -> DeviceStatusObservation? { nil }
  /// Reads, once and on the plugin's own queue, the status of every device that has no
  /// Ultracam session (a session publishes its own). Reads only: it never selects a
  /// connector, writes an EDID or opens an input. The host calls it on a timer, and only
  /// while someone is looking.
  func refreshIdleStatus() {}
}
