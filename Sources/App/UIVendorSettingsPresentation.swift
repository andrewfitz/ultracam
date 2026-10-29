import Foundation

/// Resolve only explicit metadata keys in the plugin's declared table. Runtime
/// values, opaque IDs and already-resolved strings never become lookup keys.
enum UIVendorSettingsPresentation {
  static func property(_ setting: VendorSetting, in bundle: Bundle = .main) -> ControlProperty {
    let options: [ControlOption]
    if case .choices(let choices) = setting.allowedValues {
      options = choices.map { .init(id: $0.id, label: $0.localizedLabel(in: bundle), value: .choice($0.id)) }
    } else { options = [] }
    return .init(id: setting.id, label: setting.localizedLabel(in: bundle), writable: setting.mutable,
      unavailableReason: setting.localizedAvailabilityReason(in: bundle), value: value(setting.value), options: options)
  }
  private static func value(_ value: VendorSettingValue) -> ControlValue {
    switch value {
    case .boolean(let value): return .boolean(value)
    case .signed(let value): return .integer(value)
    case .unsigned(let value): return .unsignedInteger(value)
    case .decimal(let value): return .decimal(value)
    case .text(let value): return .text(value)
    case .choice(let value): return .choice(value)
    }
  }
}
