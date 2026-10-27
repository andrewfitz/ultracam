import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct SonyCameraCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  var user: String
  var password: String
  var description: String { "SonyCameraCredential(redacted)" }
  var debugDescription: String { description }
}

protocol SonyCameraCredentialStoring: Sendable {
  func load(cameraID: String, fingerprint: String) async throws -> SonyCameraCredential?
  func save(_ credential: SonyCameraCredential, cameraID: String, fingerprint: String) async throws
  func delete(cameraID: String, fingerprint: String) async throws
}

/// Sanitized failures never include a camera identity, username or secret data.
struct SonyCameraCredentialStoreError: LocalizedError, Sendable {
  let action: String
  let status: OSStatus
  var errorDescription: String? { "Camera Keychain \(action) failed (OSStatus \(status))." }
}

/// The system owns encryption and the signed app's access policy. Items live
/// outside preferences/app containers and survive same-team, same-app-ID updates
/// and reinstalls on this Mac. Changing signing identity/access group can prevent
/// access; there is deliberately no fallback to a less protected credential file.
actor SonyCameraKeychain: SonyCameraCredentialStoring {
  static let defaultService = "org.ultracam.sony-camera-control.credentials.v1"
  private let service: String

  init(service: String = SonyCameraKeychain.defaultService) { self.service = service }

  /// Username is part of the encrypted payload, not searchable item metadata.
  /// Hashing the exact pinned fingerprint bounds the account size and ensures
  /// a replacement camera using the same MAC cannot receive the old secret.
  static func account(cameraID: String, fingerprint: String) throws -> String {
    let compact = cameraID.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").lowercased()
    let digits = Array(compact.utf8)
    guard digits.count == 12, digits.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let first = UInt8(compact.prefix(2), radix: 16), first & 1 == 0,
      compact != "000000000000", !fingerprint.isEmpty, fingerprint.utf8.count <= 1024 else {
      throw SonyCameraCredentialStoreError(action: "identity validation", status: errSecParam)
    }
    let mac = stride(from: 0, to: 12, by: 2).map { index in
      String(decoding: digits[index..<(index + 2)], as: UTF8.self)
    }.joined(separator: ":")
    let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
    return mac + "." + digest
  }

  private func query(cameraID: String, fingerprint: String) throws -> [String: Any] {
    guard !service.isEmpty, service.utf8.count <= 1024 else {
      throw SonyCameraCredentialStoreError(action: "service validation", status: errSecParam)
    }
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: try Self.account(cameraID: cameraID, fingerprint: fingerprint),
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false
      // Omit kSecAttrAccess/kSecAttrAccessGroup: the system restricts access to
      // this signed app's default group, without paths or a permissive ACL.
    ]
  }

  func load(cameraID: String, fingerprint: String) async throws -> SonyCameraCredential? {
    var request = try query(cameraID: cameraID, fingerprint: fingerprint)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    // Automatic reconnect must fail once when locked/unavailable, never open
    // a system authentication prompt as a side effect of launching the app.
    let authentication = LAContext()
    authentication.interactionNotAllowed = true
    request[kSecUseAuthenticationContext as String] = authentication
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw SonyCameraCredentialStoreError(action: "load", status: status) }
    guard let data = result as? Data, data.count <= 65536,
      let credential = try? JSONDecoder().decode(SonyCameraCredential.self, from: data),
      !credential.user.isEmpty, !credential.password.isEmpty else {
      throw SonyCameraCredentialStoreError(action: "decode", status: errSecDecode)
    }
    return credential
  }

  func save(_ credential: SonyCameraCredential, cameraID: String, fingerprint: String) async throws {
    let request = try query(cameraID: cameraID, fingerprint: fingerprint)
    guard !credential.user.isEmpty, !credential.password.isEmpty,
      credential.user.utf8.count <= 16384, credential.password.utf8.count <= 16384,
      let data = try? JSONEncoder().encode(credential), data.count <= 65536 else {
      throw SonyCameraCredentialStoreError(action: "encode", status: errSecParam)
    }
    let attributes: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
    var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = request
      attributes.forEach { item[$0.key] = $0.value }
      status = SecItemAdd(item as CFDictionary, nil)
      // Another signed process/instance may have inserted the same identity
      // between update and add. Update that one item; never delete/recreate it.
      if status == errSecDuplicateItem { status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary) }
    }
    guard status == errSecSuccess else { throw SonyCameraCredentialStoreError(action: "save", status: status) }
  }

  func delete(cameraID: String, fingerprint: String) async throws {
    let request = try query(cameraID: cameraID, fingerprint: fingerprint)
    let status = SecItemDelete(request as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SonyCameraCredentialStoreError(action: "delete", status: status)
    }
  }
}
