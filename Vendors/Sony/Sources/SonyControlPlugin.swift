import CryptoKit
import Foundation

/// Main-actor bridge ownership; the native worker serializes SDK operations.
/// Every connection has a unique native key, so late callbacks and cleanup can
/// never address a replacement generation's SDK handle.
@MainActor
final class SonyControlPlugin: CameraControlPlugin {
  nonisolated let descriptor: VendorDescriptor
  nonisolated let credentialService = "org.ultracam.sony-camera-control.credentials.v1"
  private let backend: UCSonyCameraControl
  private var handler: (@MainActor @Sendable (ControlEvent) -> Void)?
  private struct Session { var generation: UInt64; var key: String; var cameraID: String }
  private var sessions: [String: Session] = [:]
  private var pendingCleanup: [String: [UInt64: Session]] = [:]
  private var retired: [String: UInt64] = [:]
  private var tails: [String: Task<Void, Never>] = [:]
  private var closed = false

  init(backend: UCSonyCameraControl = UCSonyCameraControl()) {
    self.backend = backend
    descriptor = VendorDescriptor(id: "sony", displayName: "Sony", badgeText: "Sony",
      signalHint: nil, sdkVersion: backend.available ? backend.sdkVersion : nil, sdkPresent: backend.available, badgeAssetName: "SonyLogo",
      displayNameKey: "sony.descriptor.name", localizationTable: "SonyControl")
    backend.eventHandler = { [weak self] key, kind, message in
      MainActor.assumeIsolated {
        guard let self, !self.closed,
          let (feed, session) = self.sessions.first(where: { $0.value.key == key }) else { return }
        switch kind {
        case "changed": self.handler?(.changed(feedID: feed, generation: session.generation))
        case "disconnected": self.handler?(.disconnected(feedID: feed, generation: session.generation,
          reason: ControlDisconnectReason(code: .transport, retryable: true, message: message)))
        default: self.handler?(.error(feedID: feed, generation: session.generation,
          error: Self.failure(message)))
        }
      }
    }
  }

  nonisolated func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String {
    guard camera.pluginID == "sony" else { throw Self.failure("Invalid camera plugin.", .invalidRequest) }
    let mac = try Self.identity(camera.id)
    guard !fingerprint.isEmpty, fingerprint.utf8.count <= 1024 else {
      throw Self.failure("Invalid camera fingerprint.", .invalidRequest)
    }
    let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
    return mac + "." + digest
  }

  func setEventHandler(_ handler: @escaping @MainActor @Sendable (ControlEvent) -> Void) { self.handler = handler }

  func discover() async throws -> [ControlCamera] {
    try checkOpen()
    let cameras: [Camera] = try await request { backend.discover($0) }
    try checkCancellation()
    return cameras.map(\.value)
  }

  func prepare(_ request: ControlPreparationRequest) async throws -> ControlPreparationResult {
    try checkOpen()
    let camera: ControlCamera
    switch request {
    case .camera(let candidate):
      guard candidate.pluginID == "sony" else { throw Self.failure("Invalid camera plugin.", .invalidRequest) }
      guard let resolved = try await discover().first(where: { $0.id == candidate.id }) else {
        throw Self.failure("Camera is no longer in discovery. Scan again.", .unavailable)
      }
      if let fingerprint = candidate.fingerprint, fingerprint != resolved.fingerprint {
        throw Self.failure("Camera fingerprint changed. Verify its identity before pairing.", .changedIdentity)
      }
      camera = resolved
    case .endpoint(let endpoint):
      guard endpoint.transport == .network, let identity = endpoint.expectedIdentity else {
        throw Self.failure("Sony manual preparation requires the camera Wi-Fi MAC address.", .invalidRequest)
      }
      let mac = try Self.identity(identity)
      let resolved: Camera = try await self.request {
        backend.prepareCamera(address: endpoint.address, macAddress: mac,
          authentication: endpoint.authenticationMode == .usernamePassword, completion: $0)
      }
      guard try Self.identity(resolved.id) == mac, resolved.value.authenticationMode == endpoint.authenticationMode,
        resolved.address == endpoint.address.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw Self.failure("The resolved camera identity differs from the requested identity.", .changedIdentity)
      }
      camera = resolved.value
    }
    try checkCancellation()
    if camera.authenticationMode == .usernamePassword {
      guard let fingerprint = camera.fingerprint, !fingerprint.isEmpty else {
        throw Self.failure("Camera fingerprint could not be verified.", .authentication)
      }
      return ControlPreparationResult(camera: camera, pairingRequirement: .usernamePassword(fingerprint: fingerprint))
    }
    return ControlPreparationResult(camera: camera, pairingRequirement: .none)
  }

  func connect(feedID: String, generation: UInt64, camera: ControlCamera, credentials: ControlCredentials?) async throws {
    try checkOpen()
    guard camera.pluginID == "sony", sessions[feedID] == nil,
      retired[feedID].map({ generation > $0 }) ?? true else {
      throw Self.failure("Camera generation is no longer available.", .staleGeneration)
    }
    let identity = try Self.identity(camera.id)
    guard !sessions.values.contains(where: { $0.cameraID == identity }),
      !pendingCleanup.values.contains(where: { $0.values.contains(where: { $0.cameraID == identity }) }) else {
      throw Self.failure("This camera is already connected to another feed.", .busy)
    }
    let session = Session(generation: generation, key: UUID().uuidString, cameraID: identity)
    sessions[feedID] = session
    do {
      try await serial(feedID) {
        try self.current(feedID, generation)
        let user: String; let password: String
        if case .usernamePassword(let name, let secret) = credentials { user = name; password = secret }
        else { user = ""; password = "" }
        let _: [Property] = try await self.request {
          self.backend.connectFeed(session.key, camera: identity, address: camera.address,
            authentication: camera.authenticationMode == .usernamePassword, user: user, password: password,
            fingerprint: camera.fingerprint ?? "", completion: $0)
        }
        try self.current(feedID, generation)
      }
      try checkCancellation()
    } catch {
      if sessions[feedID]?.key == session.key { sessions.removeValue(forKey: feedID) }
      retired[feedID] = max(retired[feedID] ?? generation, generation)
      // Retain camera ownership throughout the suspended cleanup, including
      // timeout. A competing feed must never admit the same camera meanwhile.
      pendingCleanup[feedID, default: [:]][generation] = session
      do {
        let _: [Property] = try await request { backend.disconnectFeed(session.key, completion: $0) }
        if pendingCleanup[feedID]?[generation]?.key == session.key {
          pendingCleanup[feedID]?[generation] = nil
        }
      } catch {
        // Retained for an explicit disconnect retry using this exact native key.
      }
      throw error
    }
  }

  func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty] {
    try await serial(feedID) {
      let session = try self.current(feedID, generation)
      let properties: [Property] = try await self.request { self.backend.refreshFeed(session.key, completion: $0) }
      try self.current(feedID, generation)
      return Self.present(properties)
    }
  }

  func set(_ property: ControlProperty.ID, value: ControlValue, feedID: String, generation: UInt64) async throws {
    try await serial(feedID) {
      let session = try self.current(feedID, generation)
      let properties: [Property] = try await self.request { self.backend.refreshFeed(session.key, completion: $0) }
      try self.current(feedID, generation)
      if property == "cameraDisplay" {
        guard case .boolean(let enabled) = value,
          let display = properties.first(where: { $0.id == "monitoringDisplayHDMI" }), display.writable else {
          throw Self.failure("Camera display control is unavailable.", .invalidRequest)
        }
        for field in properties where ["monitoringDisplayHDMI", "faceEyeFrameDisplay"].contains(field.id) && field.writable {
          let raw: UInt64 = enabled ? 2 : 1
          guard field.choices.contains(where: { $0.value == raw }) else {
            throw Self.failure("The camera no longer allows this display value.", .invalidRequest)
          }
          try self.current(feedID, generation)
          let _: [Property] = try await self.request {
            self.backend.setFeed(session.key, code: field.code, value: raw, completion: $0)
          }
        }
        try self.current(feedID, generation)
        return
      }
      guard case .unsignedInteger(let raw) = value else {
        throw Self.failure("Sony settings require an unsigned value.", .invalidRequest)
      }
      guard let selected = properties.first(where: { $0.id == property }), selected.writable,
        selected.choices.contains(where: { $0.value == raw }) else {
        throw Self.failure("The camera no longer allows this value.", .invalidRequest)
      }
      let _: [Property] = try await self.request {
        self.backend.setFeed(session.key, code: selected.code, value: raw, completion: $0)
      }
      try self.current(feedID, generation)
    }
  }

  func disconnect(feedID: String, generation: UInt64) async throws {
    retired[feedID] = max(retired[feedID] ?? generation, generation)
    let key: String
    if let session = sessions[feedID], session.generation == generation {
      key = session.key
      sessions.removeValue(forKey: feedID)
      retired[feedID] = max(retired[feedID] ?? generation, generation)
      pendingCleanup[feedID, default: [:]][generation] = session
    } else if let pending = pendingCleanup[feedID]?[generation] { key = pending.key }
    else { return }
    do {
      try await serial(feedID) {
        let _: [Property] = try await self.request { self.backend.disconnectFeed(key, completion: $0) }
      }
      pendingCleanup[feedID]?[generation] = nil
    } catch { throw Self.failure(error.localizedDescription, .cleanupPending) }
  }

  func shutdown() async throws {
    closed = true
    for (feed, session) in sessions { retired[feed] = max(retired[feed] ?? session.generation, session.generation) }
    sessions.removeAll()
    for task in Array(tails.values) { await task.value }
    do {
      let _: [Property] = try await request { backend.shutdown($0) }
      pendingCleanup.removeAll()
    }
    catch { throw Self.failure(error.localizedDescription, .cleanupPending) }
  }

  private func serial<T: Sendable>(_ feed: String, _ body: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    let previous = tails[feed]
    let task = Task { @MainActor in
      await previous?.value
      return try await body()
    }
    tails[feed] = Task { _ = try? await task.value }
    let result = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
    try checkCancellation()
    return result
  }
  private func checkOpen() throws {
    guard !closed else { throw Self.failure("Camera control is shutting down.", .invalidState) }
  }
  @discardableResult private func current(_ feed: String, _ generation: UInt64) throws -> Session {
    try checkCancellation()
    guard let session = sessions[feed], session.generation == generation else {
      throw Self.failure("Camera generation has been retired.", .staleGeneration)
    }
    return session
  }
  private func checkCancellation() throws {
    if Task.isCancelled { throw Self.failure("Camera operation was cancelled.", .cancelled) }
    try checkOpen()
  }
  nonisolated private static func failure(_ message: String, _ code: ControlReasonCode = .sdkFailure) -> ControlError {
    ControlError(code: code, retryable: code != .invalidRequest && code != .changedIdentity, message: message)
  }
  nonisolated private static func identity(_ value: String) throws -> String {
    let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").lowercased()
    let digits = Array(compact.utf8)
    guard digits.count == 12, digits.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let first = UInt8(compact.prefix(2), radix: 16), first & 1 == 0, compact != "000000000000" else {
      throw failure("Invalid camera MAC address.", .invalidRequest)
    }
    return stride(from: 0, to: 12, by: 2).map { String(decoding: digits[$0..<($0 + 2)], as: UTF8.self) }.joined(separator: ":")
  }
  private func request<T: Decodable & Sendable>(_ call: (@escaping @Sendable (String?, String?) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      call { json, message in
        if let message {
          let code: ControlReasonCode
          if message.contains("unavailable in this build") { code = .unavailable }
          else if message.contains("fingerprint changed") || message.contains("fingerprint differs") || message.contains("changed after preparation") { code = .changedIdentity }
          else if message.contains("cannot mix") || message.contains("before adding a camera by IP") { code = .unsupported }
          else { code = .sdkFailure }
          continuation.resume(throwing: Self.failure(message, code)); return
        }
        guard let data = json?.data(using: .utf8) else {
          continuation.resume(throwing: Self.failure("Camera returned no settings.")); return
        }
        do { continuation.resume(returning: try JSONDecoder().decode(T.self, from: data)) }
        catch { continuation.resume(throwing: Self.failure("Camera returned invalid settings.")) }
      }
    }
  }
  private struct Camera: Decodable, Sendable {
    var id: String; var model: String; var address: String; var authentication: Bool
    var fingerprint: String; var fingerprintError: String; var name: String?
    var value: ControlCamera {
      ControlCamera(pluginID: "sony", id: id, name: name?.isEmpty == false ? name! : model,
        transport: .network, address: address, fingerprint: fingerprintError.isEmpty ? fingerprint : nil,
        authenticationMode: authentication ? .usernamePassword : .none)
    }
  }
  private struct Property: Decodable, Sendable {
    struct Choice: Decodable, Sendable { var value: UInt64; var label: String }
    var id: String; var title: String; var code: UInt32; var value: UInt64
    var writable: Bool; var choices: [Choice]; var label: String?
    var controlValue: ControlProperty {
      let timing = ["frameRate", "sqFrameRate", "hdmiResolution", "hdmiOutput4K", "hdmiRawFrameRate"]
      let overlay = ["iso", "aperture", "shutter", "shutterAngle", "whiteBalance", "temperature", "focusMode"]
      return ControlProperty(id: id, label: title, writable: writable, value: .unsignedInteger(self.value),
        options: choices.map { ControlOption(id: String($0.value), label: $0.label, value: .unsignedInteger($0.value),
          labelKey: $0.label == "On" ? "sony.control.choice.on" : $0.label == "Off" ? "sony.control.choice.off" : nil, localizationTable: "SonyControl") },
        role: ["monitoringDisplayHDMI", "faceEyeFrameDisplay"].contains(id) ? .hidden : timing.contains(id) ? .outputTiming : .standard,
        overlayOrder: overlay.firstIndex(of: id), currentValueLabel: label, labelKey: "sony.control.\(id)", localizationTable: "SonyControl")
    }
  }
  private static func present(_ properties: [Property]) -> [ControlProperty] {
    var result = properties.map(\.controlValue)
    if let display = properties.first(where: { $0.id == "monitoringDisplayHDMI" }) {
      result.append(ControlProperty(id: "cameraDisplay", label: "HDMI display", writable: display.writable,
        value: .boolean(display.value == 2), role: .cameraDisplay, labelKey: "sony.control.cameraDisplay", localizationTable: "SonyControl"))
    }
    return result
  }
}
