import Foundation

struct VendorDescriptor: Equatable, Sendable, Identifiable {
  let id: String
  let displayName: String
  let badgeText: String
  let signalHint: String?
  let sdkVersion: String?
  let sdkPresent: Bool
  var badgeAssetName: String? = nil
  var displayNameKey: String? = nil
  var signalHintKey: String? = nil
  var localizationTable: String? = nil
  func localizedDisplayName(in bundle: Bundle = .main) -> String {
    VendorDisplayLocalization.resolve(key: displayNameKey, fallback: displayName, table: localizationTable, in: bundle)
  }
  func localizedSignalHint(in bundle: Bundle = .main) -> String? {
    signalHint.map { VendorDisplayLocalization.resolve(key: signalHintKey, fallback: $0, table: localizationTable, in: bundle) }
  }
}

/// Keys are supplied explicitly by the owner of the resource. Device payload
/// values and fallback English text are never inferred to be localization keys.
enum VendorDisplayLocalization {
  static func resolve(key: String?, fallback: String, table: String? = nil, in bundle: Bundle = .main) -> String {
    guard let key, !key.isEmpty else { return fallback }
    return bundle.localizedString(forKey: key, value: fallback, table: table)
  }
}
