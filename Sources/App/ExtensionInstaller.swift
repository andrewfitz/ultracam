import Foundation
import Observation
import Security
import SystemExtensions

struct ExtensionInstallPreflight: Sendable {
  static let entitlement = "com.apple.developer.system-extension.install"
  let developerSigned: Bool
  let hasInstallEntitlement: Bool
  let validLocalSignature: Bool
  let localDevelopmentBuild: Bool

  init(developerSigned: Bool, hasInstallEntitlement: Bool,
    validLocalSignature: Bool = false, localDevelopmentBuild: Bool = false) {
    self.developerSigned = developerSigned
    self.hasInstallEntitlement = hasInstallEntitlement
    self.validLocalSignature = validLocalSignature
    self.localDevelopmentBuild = localDevelopmentBuild
  }

  var unavailableReason: String? {
    guard hasInstallEntitlement,
      developerSigned || (localDevelopmentBuild && validLocalSignature) else {
      return localDevelopmentBuild ?
        "This local development build needs a valid code signature and the system-extension install entitlement. Capture and preview still work." :
        "Camera installation requires a developer-signed app with the system-extension install entitlement. Capture and preview still work."
    }
    return nil
  }

  var readyStatus: String {
    unavailableReason ?? (localDevelopmentBuild ?
      "Local camera-extension development build. macOS still controls installation and approval. Capture and preview still work." :
      "Camera extension has not been requested.")
  }

  static func current() -> Self {
    // Inspect the running code, not the source entitlements plist. Security's
    // public SDK documents effective task rights and embedded signing data:
    // https://developer.apple.com/documentation/security/sectaskcopyvalueforentitlement(_:_:_:)
    var code: SecCode?
    var information: CFDictionary?
    var staticCode: SecStaticCode?
    let flags = SecCSFlags(rawValue: 0)
    let valid = SecCodeCopySelf(flags, &code) == errSecSuccess && code != nil &&
      SecCodeCheckValidity(code!, flags, nil) == errSecSuccess
    var developerSigned = false
    var validLocalSignature = false
    if valid, let code, SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let details = information as? [String: Any],
      let signatureFlags = details[kSecCodeInfoFlags as String] as? NSNumber {
      validLocalSignature = details[kSecCodeInfoIdentifier as String] is String
      developerSigned = validLocalSignature &&
        (details[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false &&
        signatureFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0 &&
        (details[kSecCodeInfoCertificates as String] as? [SecCertificate])?.isEmpty == false
    }
    var entitled = false
    if let task = SecTaskCreateFromSelf(nil),
      let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil),
      CFGetTypeID(value) == CFBooleanGetTypeID() {
      entitled = (value as? Bool) == true
    }
#if ULTRACAM_LOCAL_DEVELOPMENT
    let localDevelopmentBuild = true
#else
    let localDevelopmentBuild = false
#endif
    return Self(developerSigned: developerSigned, hasInstallEntitlement: entitled,
      validLocalSignature: validLocalSignature, localDevelopmentBuild: localDevelopmentBuild)
  }
}

/// One version of the camera extension as macOS reports it (`OSSystemExtensionProperties`).
struct ExtensionSystemRecord: Equatable, Sendable {
  var bundleVersion: String
  var enabled: Bool
  var awaitingApproval: Bool
  var uninstalling: Bool
}

/// What macOS says about the camera extension, against the version this app carries.
/// A replaced version stays listed (uninstalling) until the Mac restarts, and a newly
/// enabled one may not have published its cameras yet.
struct ExtensionSystemState: Equatable, Sendable {
  /// The newest enabled version that isn't on its way out.
  var enabledVersion: String?
  var awaitingApproval: Bool
  /// A replaced version is waiting to be removed at the next restart.
  var replacing: Bool
  /// The version inside this app (CFBundleVersion), if known.
  var bundledVersion: String?

  init(records: [ExtensionSystemRecord], bundledVersion: String?) {
    let live = records.filter { $0.enabled && !$0.uninstalling }
    enabledVersion = live.map(\.bundleVersion).max { $0.compare($1, options: .numeric) == .orderedAscending }
    awaitingApproval = records.contains { $0.awaitingApproval && !$0.uninstalling }
    replacing = records.contains(where: \.uninstalling)
    self.bundledVersion = bundledVersion
  }

  var enabled: Bool { enabledVersion != nil }

  /// The enabled extension is older than the one this app would install.
  var outdated: Bool {
    guard let enabledVersion, let bundledVersion else { return false }
    return bundledVersion.compare(enabledVersion, options: .numeric) == .orderedDescending
  }

  /// CFBundleVersion of the extension inside this app.
  static func bundledVersion(in bundle: Bundle = .main) -> String? {
    let url = bundle.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(VideoContract.extensionID).systemextension")
    return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  }
}

/// Asks macOS for the camera extension's properties. Keeps itself alive until the answer comes.
private final class ExtensionPropertiesQuery: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
  private let completion: @Sendable ([ExtensionSystemRecord]?) -> Void
  private let lock = NSLock()
  private var retained: ExtensionPropertiesQuery?

  init(completion: @escaping @Sendable ([ExtensionSystemRecord]?) -> Void) {
    self.completion = completion
    super.init()
    retained = self
  }

  static func run(completion: @escaping @Sendable ([ExtensionSystemRecord]?) -> Void) {
    let query = ExtensionPropertiesQuery(completion: completion)
    let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
    request.delegate = query
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  private func answer(_ records: [ExtensionSystemRecord]?) {
    guard let query = lock.withLock({ () -> ExtensionPropertiesQuery? in defer { retained = nil }; return retained }) else { return }
    query.completion(records)
  }

  func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
    answer(properties.map { ExtensionSystemRecord(bundleVersion: $0.bundleVersion, enabled: $0.isEnabled,
      awaitingApproval: $0.isAwaitingUserApproval, uninstalling: $0.isUninstalling) })
  }

  func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    answer(nil)
  }

  func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { answer(nil) }
  func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}
  func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .cancel }
}

/// The request in flight, readable from the delegate's nonisolated callbacks.
/// Requests are compared by reference, not by address: a request that has
/// finished can be freed, and a newer one allocated at the same address.
private final class ExtensionRequestIdentity: @unchecked Sendable {
  private let lock = NSLock()
  private var current: (request: OSSystemExtensionRequest, token: UUID)?

  func set(_ request: OSSystemExtensionRequest) { lock.withLock { current = (request, UUID()) } }
  func clear() { lock.withLock { current = nil } }
  func token(for request: OSSystemExtensionRequest) -> UUID? {
    lock.withLock { current?.request === request ? current?.token : nil }
  }
  func matches(_ token: UUID) -> Bool { lock.withLock { current?.token == token } }
}

/// Carries a callback's request to the main actor. Holding it there keeps it
/// alive, so it can't share an address with a newer request when compared.
private struct ExtensionRequestReference: @unchecked Sendable {
  let request: OSSystemExtensionRequest
}

@MainActor @Observable
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
  enum Change { case install, remove }

  struct Services {
    var preflight: () -> ExtensionInstallPreflight
    var makeRequest: (Change) -> OSSystemExtensionRequest
    var submit: (OSSystemExtensionRequest) -> Void
    /// Asks macOS which versions of the extension it knows (nil when it couldn't say).
    var queryProperties: (@escaping @Sendable ([ExtensionSystemRecord]?) -> Void) -> Void = { _ in }
    var bundledVersion: () -> String? = { nil }

    static func live() -> Self {
      Self(preflight: { ExtensionInstallPreflight.current() }, makeRequest: { change in
        switch change {
        case .install:
          return .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        case .remove:
          return .deactivationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        }
      }, submit: { OSSystemExtensionManager.shared.submitRequest($0) },
      queryProperties: { ExtensionPropertiesQuery.run(completion: $0) },
      bundledVersion: { ExtensionSystemState.bundledVersion() })
    }
  }

  private(set) var status: String
  private(set) var pending = false
  private(set) var unavailableReason: String?
  var canRequestChanges: Bool { unavailableReason == nil }
  /// What macOS last said about the extension; nil until it answers (or when it can't be asked).
  private(set) var system: ExtensionSystemState?

  @ObservationIgnored private let services: Services
  @ObservationIgnored private var activeRequest: OSSystemExtensionRequest?
  @ObservationIgnored private var activeChange: Change?
  private nonisolated let requestIdentity = ExtensionRequestIdentity()

  override convenience init() { self.init(services: .live()) }

  init(services: Services) {
    self.services = services
    let preflight = services.preflight()
    unavailableReason = preflight.unavailableReason
    status = preflight.readyStatus
    super.init()
    refreshSystemState()
  }

  /// Asks macOS about the extension again: at launch and after each install or removal.
  /// Its cameras alone can't tell "not installed" from "enabled, not started yet".
  func refreshSystemState() {
    guard canRequestChanges else { return }
    let bundled = services.bundledVersion()
    services.queryProperties { [weak self] records in
      guard let records else { return }
      Task { @MainActor [weak self] in self?.system = ExtensionSystemState(records: records, bundledVersion: bundled) }
    }
  }

  func install() { requestChange(.install) }
  func uninstall() { requestChange(.remove) }

  private func requestChange(_ change: Change) {
    guard !pending else { return }
    let preflight = services.preflight()
    unavailableReason = preflight.unavailableReason
    guard canRequestChanges else { status = unavailableReason!; return }
    let request = services.makeRequest(change)
    activeRequest = request
    activeChange = change
    requestIdentity.set(request)
    pending = true
    let scope = preflight.localDevelopmentBuild ? "local development camera extension" : "camera extension"
    status = change == .install ? "Requesting \(scope) activation…" : "Requesting \(scope) removal…"
    request.delegate = self
    services.submit(request)
  }

  /// True when this callback belongs to the request that is still in flight,
  /// even if its identity token was lost. An older request never matches.
  private func isCurrentRequest(_ request: OSSystemExtensionRequest) -> Bool {
    activeRequest === request
  }

  private func finish(_ request: OSSystemExtensionRequest, message: String) {
    guard isCurrentRequest(request) else { return }
    requestIdentity.clear()
    activeRequest?.delegate = nil
    activeRequest = nil
    activeChange = nil
    pending = false
    status = message
    refreshSystemState()
  }

  /// Drops the identity token while leaving the in-flight request pending.
  /// Tests use this to cover a callback whose token was already lost.
  func testingForgetRequestToken() { requestIdentity.clear() }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    guard let identity = requestIdentity.token(for: request) else { return }
    Task { @MainActor in
      guard self.requestIdentity.matches(identity) else { return }
      self.status = "Approve Ultracam in System Settings › General › Login Items & Extensions › Camera Extensions."
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    let completed = result == .completed
    let reference = ExtensionRequestReference(request: request)
    Task { @MainActor in
      guard self.isCurrentRequest(reference.request) else { return }
      let removed = self.activeChange == .remove
      self.finish(reference.request, message: completed ? (removed ? "Camera extension removed." :
        "Camera extension request completed. Refresh inputs, then choose Ultracam in your meeting app.") :
        "Camera extension change requires a restart.")
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    let description = error.localizedDescription
    let reference = ExtensionRequestReference(request: request)
    Task { @MainActor in
      self.finish(reference.request, message: "Camera extension change failed: \(description). Capture and preview still work.")
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
    requestIdentity.token(for: request) != nil ? .replace : .cancel
  }
}
