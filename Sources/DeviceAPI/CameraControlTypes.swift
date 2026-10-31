import Foundation

enum ControlTransport: String, Codable, Sendable { case network, usb, bluetooth, other }
enum ControlAuthenticationMode: String, Codable, Sendable { case none, usernamePassword }

struct ControlCamera: Codable, Identifiable, Equatable, Sendable {
    var pluginID: String
    var id: String
    var name: String
    var transport: ControlTransport
    var address: String
    var fingerprint: String?
    var authenticationMode: ControlAuthenticationMode = .none
    /// The body's model and firmware when the plugin knows them. Optional on purpose: saved
    /// assignments decode with synthesized Codable, which accepts a missing key only for optionals.
    var model: String? = nil
    var firmware: String? = nil
}

struct ControlEndpoint: Codable, Equatable, Sendable {
    var address: String
    var expectedIdentity: String?
    var authenticationMode: ControlAuthenticationMode
    var transport: ControlTransport = .network
}
enum ControlPreparationRequest: Codable, Equatable, Sendable {
    case camera(ControlCamera)
    case endpoint(ControlEndpoint)
}
enum PairingRequirement: Equatable, Sendable {
    case none
    case usernamePassword(fingerprint: String)
    case unsupported(reason: String)
}
struct ControlPreparationResult: Equatable, Sendable {
    var camera: ControlCamera
    var pairingRequirement: PairingRequirement
}

/// Deliberately not Codable: secrets may be encoded only by the Keychain owner.
enum ControlCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case usernamePassword(username: String, password: String)
    var description: String { "ControlCredentials(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["payload": "<redacted>"]) }
}

enum ControlValue: Codable, Hashable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case decimal(Double)
    case text(String)
    case choice(String)

    var isValid: Bool {
        if case .decimal(let value) = self { return value.isFinite }
        return true
    }
}
struct ControlOption: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var value: ControlValue
    var labelKey: String? = nil
    var localizationTable: String? = nil
    func localizedLabel(in bundle: Bundle = .main) -> String {
        VendorDisplayLocalization.resolve(key: labelKey, fallback: label, table: localizationTable, in: bundle)
    }
}
struct ControlRange: Codable, Equatable, Sendable {
    var minimum: ControlValue
    var maximum: ControlValue
    var step: ControlValue?
}
/// Where a host places a property, never by its ID. `outputTiming` and `cameraDisplay` are how the
/// body drives its HDMI output; the rest are read-only facts the host shows by meaning: `power`
/// (battery, with its `unit`), `thermal`, `media`, `timecodeOutput` and `hdmiAudio` (what the
/// body puts on HDMI), `colorProfile` (its picture, possibly with a suggested source profile)
/// and `firmware`.
enum ControlPropertyRole: String, Codable, Sendable {
    case standard, outputTiming, cameraDisplay, hidden
    case power, thermal, media, timecodeOutput, hdmiAudio, colorProfile, firmware
}
/// The unit of a numeric reading. A host must never read 78 minutes of battery as 78%.
enum ControlValueUnit: String, Codable, Sendable { case percent, minutes, volts, celsius }

struct ControlProperty: Codable, Equatable, Identifiable, Sendable {
    typealias ID = String
    var id: ID
    var label: String
    var writable: Bool
    var unavailableReason: String? = nil
    var value: ControlValue
    var options: [ControlOption] = []
    var range: ControlRange? = nil
    var role: ControlPropertyRole = .standard
    var overlayOrder: Int? = nil
    var currentValueLabel: String? = nil
    var labelKey: String? = nil
    var localizationTable: String? = nil
    var unavailableReasonKey: String? = nil
    /// Set by the plugin when the value itself is a problem (a low battery, overheating).
    /// Nil is fine, and a battery in an unknown unit is never a problem.
    var severity: DeviceSeverity? = nil
    /// The unit of a numeric reading, when the body reports one.
    var unit: ControlValueUnit? = nil
    /// For a `colorProfile` property: the source profile (a `SourceColorSpaceCatalog` ID)
    /// this picture matches, so the host can compare it with the camera's declaration.
    var suggestedSourceProfileID: String? = nil
    func localizedLabel(in bundle: Bundle = .main) -> String {
        VendorDisplayLocalization.resolve(key: labelKey, fallback: label, table: localizationTable, in: bundle)
    }
    func localizedUnavailableReason(in bundle: Bundle = .main) -> String? {
        unavailableReason.map { VendorDisplayLocalization.resolve(key: unavailableReasonKey, fallback: $0, table: localizationTable, in: bundle) }
    }
}

enum ControlReasonCode: String, Codable, Sendable {
    case manual, removed, transport, authentication, changedIdentity, unavailable, sdkFailure
    case invalidRequest, invalidState, staleGeneration, cancelled, unsupported, busy, cleanupPending
}
struct ControlError: Error, LocalizedError, Equatable, Sendable {
    var code: ControlReasonCode
    var retryable: Bool
    var message: String
    var errorDescription: String? { message }
}
struct ControlDisconnectReason: Equatable, Sendable {
    var code: ControlReasonCode
    var retryable: Bool
    var message: String
}
enum ControlEvent: Equatable, Sendable {
    case changed(feedID: String, generation: UInt64)
    case disconnected(feedID: String, generation: UInt64, reason: ControlDisconnectReason)
    case error(feedID: String, generation: UInt64, error: ControlError)
    /// Something the body reported that doesn't end the connection (reconnecting, card full).
    case notice(feedID: String, generation: UInt64, message: String, severity: DeviceSeverity)
}
