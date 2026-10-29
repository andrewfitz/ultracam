import Foundation
import LocalAuthentication
import Security

protocol CameraControlCredentialStoring: Sendable {
    func load(service: String, account: String) async throws -> ControlCredentials?
    func save(_ credentials: ControlCredentials, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
}

struct CameraControlCredentialError: LocalizedError, Sendable {
    let action: String
    let status: OSStatus
    var errorDescription: String? { "Camera Keychain \(action) failed (OSStatus \(status))." }
}

/// Plugins own service/account identities; this actor owns encrypted storage.
/// The payload keys preserve existing encrypted Keychain credential items.
actor CameraControlKeychain: CameraControlCredentialStoring {
    private struct Payload: Codable { var user: String; var password: String }
    private func query(_ service: String, _ account: String) throws -> [String: Any] {
        guard !service.isEmpty, !account.isEmpty, service.utf8.count <= 1024, account.utf8.count <= 4096 else {
            throw CameraControlCredentialError(action: "identity validation", status: errSecParam)
        }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false]
    }
    func load(service: String, account: String) async throws -> ControlCredentials? {
        var request = try query(service, account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let authentication = LAContext(); authentication.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = authentication
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CameraControlCredentialError(action: "load", status: status) }
        guard let data = result as? Data, data.count <= 65536,
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            !payload.user.isEmpty, !payload.password.isEmpty else {
            throw CameraControlCredentialError(action: "decode", status: errSecDecode)
        }
        return .usernamePassword(username: payload.user, password: payload.password)
    }
    func save(_ credentials: ControlCredentials, service: String, account: String) async throws {
        let request = try query(service, account)
        let payload: Payload
        switch credentials { case .usernamePassword(let username, let password): payload = .init(user: username, password: password) }
        guard !payload.user.isEmpty, !payload.password.isEmpty, payload.user.utf8.count <= 16384,
            payload.password.utf8.count <= 16384 else { throw CameraControlCredentialError(action: "encode", status: errSecParam) }
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 65536 else { throw CameraControlCredentialError(action: "encode", status: errSecParam) }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request; attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw CameraControlCredentialError(action: "save", status: status) }
    }
    func delete(service: String, account: String) async throws {
        let status = SecItemDelete(try query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CameraControlCredentialError(action: "delete", status: status)
        }
    }
}
