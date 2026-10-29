import Foundation

enum VendorSettingValue: Codable, Hashable, Sendable {
  case boolean(Bool), signed(Int64), unsigned(UInt64), decimal(Double), text(String), choice(String)
  func validate() throws {
    if case .decimal(let value) = self, !value.isFinite { throw PluginError.unsupported("Setting must be finite") }
  }
}

struct VendorSetting: Identifiable, Sendable {
  typealias ID = String
  struct Choice: Equatable, Sendable {
    let id: String
    let label: String
    var labelKey: String? = nil
    var localizationTable: String? = nil
    func localizedLabel(in bundle: Bundle = .main) -> String {
      VendorDisplayLocalization.resolve(key: labelKey, fallback: label, table: localizationTable, in: bundle)
    }
  }
  enum AllowedValues: Sendable {
    case unrestricted, choices([Choice]), signed(ClosedRange<Int64>), unsigned(ClosedRange<UInt64>), decimal(ClosedRange<Double>)
  }
  let id: ID
  let labelKey: String
  let value: VendorSettingValue
  let allowedValues: AllowedValues
  let mutable: Bool
  let availabilityReason: String?
  let interruptsCapture: Bool
  /// The displayed value is desired but its most recent SDK application failed.
  /// Keep the setting actionable so callers may retry or choose another value.
  var applicationError: PluginError? = nil
  var labelFallback: String? = nil
  var localizationTable: String? = nil
  var availabilityReasonKey: String? = nil
  func localizedLabel(in bundle: Bundle = .main) -> String {
    VendorDisplayLocalization.resolve(key: labelFallback == nil ? nil : labelKey,
      fallback: labelFallback ?? labelKey, table: localizationTable, in: bundle)
  }
  func localizedAvailabilityReason(in bundle: Bundle = .main) -> String? {
    availabilityReason.map { VendorDisplayLocalization.resolve(key: availabilityReasonKey,
      fallback: $0, table: localizationTable, in: bundle) }
  }
}
