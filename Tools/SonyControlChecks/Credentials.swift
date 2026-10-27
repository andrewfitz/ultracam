import Foundation
import LocalAuthentication
import Security
import Darwin

/// Injected by store tests; no platform Keychain access occurs through this fake.
actor MemorySonyCameraCredentials: SonyCameraCredentialStoring {
  private var values: [String: SonyCameraCredential] = [:]
  func load(cameraID: String, fingerprint: String) async throws -> SonyCameraCredential? {
    values[try SonyCameraKeychain.account(cameraID: cameraID, fingerprint: fingerprint)]
  }
  func save(_ credential: SonyCameraCredential, cameraID: String, fingerprint: String) async throws {
    values[try SonyCameraKeychain.account(cameraID: cameraID, fingerprint: fingerprint)] = credential
  }
  func delete(cameraID: String, fingerprint: String) async throws {
    values.removeValue(forKey: try SonyCameraKeychain.account(cameraID: cameraID, fingerprint: fingerprint))
  }
}

@main
struct SonyCredentialChecks {
  static let camera = "02:00:00:00:00:01" // Locally administered synthetic identity.
  static let fingerprint = "synthetic-pinned-camera-identity"
  static func main() async {
    do { try await run() }
    catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(EXIT_FAILURE)
    }
  }
  static func run() async throws {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("--process-") {
      try await checkSeparateProcess(mode: CommandLine.arguments[1], service: CommandLine.arguments[2])
      return
    }
    let canonical = try SonyCameraKeychain.account(cameraID: camera, fingerprint: fingerprint)
    let normalized = try SonyCameraKeychain.account(cameraID: " 02-00-00-00-00-01\n", fingerprint: fingerprint)
    precondition(canonical == normalized)
    let otherPin = try SonyCameraKeychain.account(cameraID: camera, fingerprint: fingerprint + "-replacement")
    precondition(canonical != otherPin)
    for invalid in ["", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "02:00:00:00:00", "02:00:00:00:00:GG"] {
      do { _ = try SonyCameraKeychain.account(cameraID: invalid, fingerprint: fingerprint); preconditionFailure("Invalid identity accepted") }
      catch let error as SonyCameraCredentialStoreError { precondition(error.status == errSecParam) }
    }
    do { _ = try SonyCameraKeychain.account(cameraID: camera, fingerprint: ""); preconditionFailure("Unpinned identity accepted") }
    catch let error as SonyCameraCredentialStoreError { precondition(error.status == errSecParam) }
    let credential = SonyCameraCredential(user: "synthetic-user", password: UUID().uuidString)
    precondition(!String(describing: credential).contains(credential.password))
    precondition(!String(reflecting: credential).contains(credential.password))
    let payload = try JSONEncoder().encode(credential)
    let decoded = try JSONDecoder().decode(SonyCameraCredential.self, from: payload)
    precondition(decoded == credential)
    let fake: any SonyCameraCredentialStoring = MemorySonyCameraCredentials()
    try await checkRoundTrip(fake, credential: credential)
    print("Sony credential checks passed: normalized camera identity, pinned fingerprint isolation, redaction and injectable persistence.")

    // Explicit opt-in only: run from a provisioned, signed test app to qualify
    // actual macOS data-protection Keychain behavior. Never uses production
    // service/identities. A random test service is deleted before returning.
    if CommandLine.arguments.contains("--keychain") { try await checkPlatformKeychain(credential) }
  }

  static func checkSeparateProcess(mode: String, service: String) async throws {
    let prefix = "org.ultracam.sony-credential-checks."
    guard service.hasPrefix(prefix), UUID(uuidString: String(service.dropFirst(prefix.count))) != nil else {
      throw SonyCameraCredentialStoreError(action: "test service validation", status: errSecParam)
    }
    let store = SonyCameraKeychain(service: service)
    // Deliberately public, synthetic test data; never an actual camera secret.
    let initial = SonyCameraCredential(user: "synthetic-process-user", password: service + "-synthetic")
    let updated = SonyCameraCredential(user: "synthetic-process-user-updated", password: service + "-updated")
    switch mode {
    case "--process-save":
      let absent = try await store.load(cameraID: camera, fingerprint: fingerprint)
      precondition(absent == nil)
      try await store.save(initial, cameraID: camera, fingerprint: fingerprint)
      print("Signed helper A saved an isolated synthetic Keychain record.")
    case "--process-read-update":
      let loaded = try await store.load(cameraID: camera, fingerprint: fingerprint)
      precondition(loaded == initial)
      let changedPin = try await store.load(cameraID: camera, fingerprint: fingerprint + "-replacement")
      precondition(changedPin == nil)
      try await store.save(updated, cameraID: camera, fingerprint: fingerprint)
#if SONY_CREDENTIAL_UPDATE_CHECK
      print("Signed helper B at a new path and with changed executable content reopened and updated the record.")
#else
      print("Signed helper reopened and updated the record.")
#endif
    case "--process-verify-delete":
      let loaded = try await store.load(cameraID: camera, fingerprint: fingerprint)
      precondition(loaded == updated)
      try await store.delete(cameraID: camera, fingerprint: fingerprint)
      let removed = try await store.load(cameraID: camera, fingerprint: fingerprint)
      precondition(removed == nil)
      print("A fresh helper A process verified the update and deleted the isolated record.")
    case "--process-cleanup":
      try await store.delete(cameraID: camera, fingerprint: fingerprint)
    default: throw SonyCameraCredentialStoreError(action: "test mode validation", status: errSecParam)
    }
  }

  static func checkRoundTrip(_ store: any SonyCameraCredentialStoring, credential: SonyCameraCredential) async throws {
    let absent = try await store.load(cameraID: camera, fingerprint: fingerprint)
    try verify(absent == nil)
    try await store.save(credential, cameraID: camera, fingerprint: fingerprint)
    let saved = try await store.load(cameraID: camera, fingerprint: fingerprint)
    try verify(saved == credential)
    let differentIdentity = try await store.load(cameraID: camera, fingerprint: fingerprint + "-replacement")
    try verify(differentIdentity == nil)
    let updated = SonyCameraCredential(user: credential.user + "-updated", password: UUID().uuidString)
    try await store.save(updated, cameraID: camera, fingerprint: fingerprint)
    let replacement = try await store.load(cameraID: camera, fingerprint: fingerprint)
    try verify(replacement == updated)
    try await store.delete(cameraID: camera, fingerprint: fingerprint)
    try await store.delete(cameraID: camera, fingerprint: fingerprint)
    let deleted = try await store.load(cameraID: camera, fingerprint: fingerprint)
    try verify(deleted == nil)
  }

  static func verify(_ condition: Bool) throws {
    guard condition else { throw SonyCameraCredentialStoreError(action: "test verification", status: errSecInternalComponent) }
  }

  static func checkPlatformKeychain(_ credential: SonyCameraCredential) async throws {
    let service = "org.ultracam.sony-credential-checks." + UUID().uuidString
    let store = SonyCameraKeychain(service: service)
    do {
      try await checkRoundTrip(store, credential: credential)
      try await store.save(credential, cameraID: camera, fingerprint: fingerprint)
      // A new actor has no in-memory state: persistence must be in Keychain.
      let reopened = SonyCameraKeychain(service: service)
      let loaded = try await reopened.load(cameraID: camera, fingerprint: fingerprint)
      try verify(loaded == credential)
      var attributes: CFTypeRef?
      let authentication = LAContext()
      authentication.interactionNotAllowed = true
      let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: try SonyCameraKeychain.account(cameraID: camera, fingerprint: fingerprint),
        kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
        kSecUseAuthenticationContext as String: authentication,
        kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
      let status = SecItemCopyMatching(request as CFDictionary, &attributes)
      guard status == errSecSuccess, let item = attributes as? [String: Any] else {
        throw SonyCameraCredentialStoreError(action: "test attributes", status: status)
      }
      try verify(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
      try verify((item[kSecAttrSynchronizable as String] as? Bool) != true)
      try await reopened.delete(cameraID: camera, fingerprint: fingerprint)
      print("Sony isolated macOS Keychain checks passed: add, update, reopen, pin isolation, unlocked local policy and delete.")
    } catch {
      try? await store.delete(cameraID: camera, fingerprint: fingerprint)
      throw error
    }
  }
}
