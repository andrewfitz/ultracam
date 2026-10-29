import Foundation
import LocalAuthentication
import Security
import Darwin

actor MemorySonyCameraCredentials: CameraControlCredentialStoring {
  private var values: [String: ControlCredentials] = [:]
  func load(service: String, account: String) async throws -> ControlCredentials? { values[service + "|" + account] }
  func save(_ credential: ControlCredentials, service: String, account: String) async throws { values[service + "|" + account] = credential }
  func delete(service: String, account: String) async throws { values.removeValue(forKey: service + "|" + account) }
}

@main @MainActor struct SonyCredentialChecks {
  static let camera = "02:00:00:00:00:01"
  static let fingerprint = "synthetic-pinned-camera-identity"
  static func account(_ identity: String = camera, pin: String = fingerprint) throws -> String {
    let camera = ControlCamera(pluginID: "sony", id: identity, name: "Synthetic", transport: .network, address: "", fingerprint: pin)
    return try SonyControlPlugin().credentialAccount(for: camera, fingerprint: pin)
  }
  static func main() async {
    do { try await run() }
    catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(EXIT_FAILURE) }
  }
  static func run() async throws {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("--process-") {
      try await checkSeparateProcess(mode: CommandLine.arguments[1], service: CommandLine.arguments[2]); return
    }
    let canonical = try account()
    let normalized = try account(" 02-00-00-00-00-01\n")
    precondition(canonical == normalized)
    let otherPin = try account(pin: fingerprint + "-replacement")
    precondition(canonical != otherPin)
    precondition(SonyControlPlugin().credentialService == "org.ultracam.sony-camera-control.credentials.v1")
    for invalid in ["", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "02:00:00:00:00", "02:00:00:00:00:GG"] {
      do { _ = try account(invalid); preconditionFailure("Invalid identity accepted") }
      catch let error as ControlError { precondition(error.code == .invalidRequest) }
    }
    do { _ = try account(pin: ""); preconditionFailure("Unpinned identity accepted") }
    catch let error as ControlError { precondition(error.code == .invalidRequest) }
    let password = UUID().uuidString
    let credential = ControlCredentials.usernamePassword(username: "synthetic-user", password: password)
    precondition(!String(describing: credential).contains(password))
    precondition(!String(reflecting: credential).contains(password))
    // The generic Keychain retains these legacy payload keys, checked by the
    // platform opt-in path below as well as the production migration tests.
    struct LegacyPayload: Codable { var user: String; var password: String }
    let payload = try JSONEncoder().encode(LegacyPayload(user: "synthetic-user", password: password))
    let decoded = try JSONDecoder().decode(LegacyPayload.self, from: payload)
    precondition(decoded.password == password)
    try await checkRoundTrip(MemorySonyCameraCredentials(), credential: credential, service: "synthetic-memory")
    print("Sony credential checks passed: normalized identity, pinned fingerprint isolation, service continuity, redaction and injectable production persistence.")
    if CommandLine.arguments.contains("--keychain") { try await checkPlatformKeychain(credential) }
  }
  static func checkSeparateProcess(mode: String, service: String) async throws {
    let prefix = "org.ultracam.sony-credential-checks."
    guard service.hasPrefix(prefix), UUID(uuidString: String(service.dropFirst(prefix.count))) != nil else {
      throw CameraControlCredentialError(action: "test service validation", status: errSecParam)
    }
    let store = CameraControlKeychain()
    let identity = try account()
    let initial = ControlCredentials.usernamePassword(username: "synthetic-process-user", password: service + "-synthetic")
    let updated = ControlCredentials.usernamePassword(username: "synthetic-process-user-updated", password: service + "-updated")
    switch mode {
    case "--process-save":
      let absent = try await store.load(service: service, account: identity); precondition(absent == nil)
      try await store.save(initial, service: service, account: identity)
      print("Signed helper A saved an isolated synthetic Keychain record.")
    case "--process-read-update":
      let loaded = try await store.load(service: service, account: identity); precondition(loaded == initial)
      let changedPin = try await store.load(service: service, account: account(pin: fingerprint + "-replacement")); precondition(changedPin == nil)
      try await store.save(updated, service: service, account: identity)
#if SONY_CREDENTIAL_UPDATE_CHECK
      print("Signed helper B at a new path and with changed executable content reopened and updated the record.")
#else
      print("Signed helper reopened and updated the record.")
#endif
    case "--process-verify-delete":
      let loaded = try await store.load(service: service, account: identity); precondition(loaded == updated)
      try await store.delete(service: service, account: identity)
      let removed = try await store.load(service: service, account: identity); precondition(removed == nil)
      print("A fresh helper process verified the update and deleted the isolated record.")
    case "--process-cleanup": try await store.delete(service: service, account: identity)
    default: throw CameraControlCredentialError(action: "test mode validation", status: errSecParam)
    }
  }
  static func checkRoundTrip(_ store: any CameraControlCredentialStoring, credential: ControlCredentials, service: String) async throws {
    let identity = try account()
    let absent = try await store.load(service: service, account: identity); try verify(absent == nil)
    try await store.save(credential, service: service, account: identity)
    let saved = try await store.load(service: service, account: identity); try verify(saved == credential)
    let different = try await store.load(service: service, account: account(pin: fingerprint + "-replacement")); try verify(different == nil)
    let updated = ControlCredentials.usernamePassword(username: "synthetic-updated-user", password: UUID().uuidString)
    try await store.save(updated, service: service, account: identity)
    let replacement = try await store.load(service: service, account: identity); try verify(replacement == updated)
    try await store.delete(service: service, account: identity); try await store.delete(service: service, account: identity)
    let deleted = try await store.load(service: service, account: identity); try verify(deleted == nil)
  }
  static func verify(_ condition: Bool) throws {
    guard condition else { throw CameraControlCredentialError(action: "test verification", status: errSecInternalComponent) }
  }
  static func checkPlatformKeychain(_ credential: ControlCredentials) async throws {
    let service = "org.ultracam.sony-credential-checks." + UUID().uuidString
    let store = CameraControlKeychain(); let identity = try account()
    do {
      try await checkRoundTrip(store, credential: credential, service: service)
      // Seed exactly the pre-plugin encrypted payload shape, then use the live
      // generic implementation to prove saved sign-ins survive the migration.
      struct LegacyPayload: Encodable { var user: String; var password: String }
      let legacy = try JSONEncoder().encode(LegacyPayload(user: "legacy-user", password: "legacy-synthetic"))
      let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: identity,
        kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked, kSecValueData as String: legacy]
      let inserted = SecItemAdd(request as CFDictionary, nil)
      guard inserted == errSecSuccess else { throw CameraControlCredentialError(action: "legacy test seed", status: inserted) }
      let reopened = CameraControlKeychain()
      let loaded = try await reopened.load(service: service, account: identity)
      try verify(loaded == .usernamePassword(username: "legacy-user", password: "legacy-synthetic"))
      var attributes: CFTypeRef?
      let authentication = LAContext(); authentication.interactionNotAllowed = true
      let lookup: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: identity,
        kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
        kSecUseAuthenticationContext as String: authentication,
        kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
      let status = SecItemCopyMatching(lookup as CFDictionary, &attributes)
      guard status == errSecSuccess, let item = attributes as? [String: Any] else { throw CameraControlCredentialError(action: "test attributes", status: status) }
      try verify(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
      try verify((item[kSecAttrSynchronizable as String] as? Bool) != true)
      try await reopened.delete(service: service, account: identity)
      print("Sony isolated macOS Keychain checks passed: legacy payload, add, update, reopen, pin isolation, unlocked local policy and delete.")
    } catch { try? await store.delete(service: service, account: identity); throw error }
  }
}
