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
}

struct ControlEndpoint: Equatable, Sendable {
    var address: String
    var expectedIdentity: String?
    var authenticationMode: ControlAuthenticationMode
    var transport: ControlTransport = .network
}
enum ControlPreparationRequest: Equatable, Sendable {
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

enum ControlValue: Codable, Equatable, Sendable {
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
}
struct ControlRange: Codable, Equatable, Sendable {
    var minimum: ControlValue
    var maximum: ControlValue
    var step: ControlValue?
}
struct ControlProperty: Codable, Equatable, Identifiable, Sendable {
    typealias ID = String
    var id: ID
    var label: String
    var writable: Bool
    var unavailableReason: String? = nil
    var value: ControlValue
    var options: [ControlOption] = []
    var range: ControlRange? = nil
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
}
