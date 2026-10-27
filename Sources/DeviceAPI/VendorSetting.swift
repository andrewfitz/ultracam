import Foundation

enum VendorSettingValue: Equatable, Sendable {
  case boolean(Bool), signed(Int64), unsigned(UInt64), decimal(Double), text(String), choice(String)
  func validate() throws {
    if case .decimal(let value) = self, !value.isFinite { throw PluginError.unsupported("Setting must be finite") }
  }
}

struct VendorSetting: Identifiable, Sendable {
  typealias ID = String
  struct Choice: Equatable, Sendable { let id: String; let label: String }
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
}
