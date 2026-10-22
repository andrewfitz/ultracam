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

    static func live() -> Self {
      Self(preflight: { ExtensionInstallPreflight.current() }, makeRequest: { change in
        switch change {
        case .install:
          return .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        case .remove:
          return .deactivationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        }
      }, submit: { OSSystemExtensionManager.shared.submitRequest($0) })
    }
  }

  private(set) var status: String
  private(set) var pending = false
  private(set) var unavailableReason: String?
  var canRequestChanges: Bool { unavailableReason == nil }

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
