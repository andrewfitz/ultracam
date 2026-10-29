import Foundation

/// Desired values are scoped by opaque device ID. Inherited defaults apply only
/// when no per-device value exists, including devices first seen in a later run.
struct VendorSettingsPolicy: Codable, Equatable, Sendable {
    var version = 1
    var desiredByDevice: [String: [VendorSetting.ID: VendorSettingValue]] = [:]
    var inheritedByPlugin: [String: [VendorSetting.ID: VendorSettingValue]] = [:]
}

protocol VendorSettingsProviding: Sendable {
    var descriptor: VendorDescriptor { get }
    func settings(deviceID: String) async throws -> [VendorSetting]
    func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String) async throws
}
