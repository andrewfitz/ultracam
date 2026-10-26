import Foundation

/// The two kinds of virtual camera published by the multi-camera extension.
/// A feed camera maps to one configured input; the program camera represents
/// the switcher's selected output.
enum VirtualCameraDeviceKind: String, Codable, Equatable, Sendable {
  case feed
  case program
}

/// A descriptor is the complete identity contract for one published camera.
/// The identity fields are derived from `kind` and `feedID`; callers should
/// create descriptors with the factory methods rather than inventing IDs.
struct VirtualCameraDescriptor: Codable, Equatable, Sendable, Identifiable {
  var kind: VirtualCameraDeviceKind
  var feedID: String?
  var id: String
  var deviceUID: String
  var sourceStreamID: String
  var sinkStreamID: String
  var displayName: String
  var enabled: Bool

  init(kind: VirtualCameraDeviceKind, feedID: String? = nil,
    displayName: String? = nil, enabled: Bool = true) {
    let normalizedFeedID = Self.normalizedFeedID(feedID)
    self.kind = kind
    self.feedID = kind == .feed ? normalizedFeedID : nil
    self.id = Self.stableID(for: kind, feedID: normalizedFeedID)
    self.deviceUID = Self.deviceUID(for: kind, feedID: normalizedFeedID)
    self.sourceStreamID = Self.sourceStreamID(for: kind, feedID: normalizedFeedID)
    self.sinkStreamID = Self.sinkStreamID(for: kind, feedID: normalizedFeedID)
    self.displayName = displayName ?? Self.defaultDisplayName(for: kind, feedID: normalizedFeedID)
    self.enabled = enabled
  }

  static func feed(feedID: String, displayName: String? = nil, enabled: Bool = true)
    -> VirtualCameraDescriptor {
    VirtualCameraDescriptor(kind: .feed, feedID: feedID, displayName: displayName, enabled: enabled)
  }

  static func program(displayName: String? = nil, enabled: Bool = true)
    -> VirtualCameraDescriptor {
    VirtualCameraDescriptor(kind: .program, displayName: displayName, enabled: enabled)
  }

  static func stableID(for kind: VirtualCameraDeviceKind, feedID: String? = nil) -> String {
    "org.ultracam.virtual-camera.\(kind.rawValue).\(encodedIdentity(for: kind, feedID: feedID))"
  }

  static func deviceUID(for kind: VirtualCameraDeviceKind, feedID: String? = nil) -> String {
    // Keep the migrated single-feed route discoverable by legacy CMIO clients.
    if kind == .feed && normalizedFeedID(feedID) == "default" {
      return "org.ultracam.camera.device"
    }
    return "org.ultracam.camera.device.\(encodedIdentity(for: kind, feedID: feedID))"
  }

  static func sourceStreamID(for kind: VirtualCameraDeviceKind, feedID: String? = nil) -> String {
    "org.ultracam.camera.stream.source.\(encodedIdentity(for: kind, feedID: feedID))"
  }

  static func sinkStreamID(for kind: VirtualCameraDeviceKind, feedID: String? = nil) -> String {
    "org.ultracam.camera.stream.sink.\(encodedIdentity(for: kind, feedID: feedID))"
  }

  /// Checks both the descriptor's shape and its deterministic identity fields.
  func validate() throws {
    let normalizedFeedID = Self.normalizedFeedID(feedID)
    guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw VirtualCameraRegistryError.invalidDescriptor(id, reason: "display name is empty")
    }
    switch kind {
    case .feed:
      guard let feedID, !normalizedFeedID.isEmpty else {
        throw VirtualCameraRegistryError.invalidDescriptor(id, reason: "feed device has no feed ID")
      }
      guard feedID == normalizedFeedID else {
        throw VirtualCameraRegistryError.invalidDescriptor(id, reason: "feed ID is not normalized")
      }
    case .program:
      guard feedID == nil else {
        throw VirtualCameraRegistryError.invalidDescriptor(id, reason: "program device has a feed ID")
      }
    }
    guard id == Self.stableID(for: kind, feedID: normalizedFeedID),
      deviceUID == Self.deviceUID(for: kind, feedID: normalizedFeedID),
      sourceStreamID == Self.sourceStreamID(for: kind, feedID: normalizedFeedID),
      sinkStreamID == Self.sinkStreamID(for: kind, feedID: normalizedFeedID) else {
      throw VirtualCameraRegistryError.invalidDescriptor(id, reason: "identity does not match kind and feed ID")
    }
  }

  private static func normalizedFeedID(_ feedID: String?) -> String {
    feedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func encodedIdentity(for kind: VirtualCameraDeviceKind, feedID: String?) -> String {
    let identity = kind == .program ? "program" : "feed:\(normalizedFeedID(feedID))"
    // Hex encoding keeps IDs stable and safe for CMIO names, regardless of
    // punctuation or Unicode in a user-created feed identifier.
    return identity.utf8.map { String(format: "%02x", $0) }.joined()
  }

  private static func defaultDisplayName(for kind: VirtualCameraDeviceKind, feedID: String?) -> String {
    switch kind {
    case .feed: return "Ultracam · Feed \(normalizedFeedID(feedID))"
    case .program: return "Ultracam · Program"
    }
  }
}

enum VirtualCameraRegistryError: Error, Equatable, LocalizedError, Sendable {
  case invalidSchemaVersion(Int)
  case invalidGeneration
  case invalidAppGroupIdentifier
  case invalidDescriptor(String, reason: String)
  case duplicateDeviceID(String)
  case duplicateStreamID(String)
  case multipleProgramDevices
  case appGroupMismatch(expected: String, actual: String)
  case staleGeneration(current: UInt64, candidate: UInt64)
  case noValidSnapshot
  case writeVerificationFailed
  case unavailableContainer

  var errorDescription: String? {
    switch self {
    case .invalidSchemaVersion(let version): return "Unsupported virtual-camera registry schema version \(version)."
    case .invalidGeneration: return "Virtual-camera registry generation is invalid."
    case .invalidAppGroupIdentifier: return "Virtual-camera registry app-group identifier is invalid."
    case .invalidDescriptor(_, let reason): return "Invalid virtual-camera descriptor: \(reason)."
    case .duplicateDeviceID(let id): return "Duplicate virtual-camera device ID \(id)."
    case .duplicateStreamID(let id): return "Duplicate virtual-camera stream ID \(id)."
    case .multipleProgramDevices: return "A registry may contain at most one program device."
    case .appGroupMismatch(let expected, let actual):
      return "Virtual-camera registry belongs to app group \(actual), expected \(expected)."
    case .staleGeneration(let current, let candidate):
      return "Virtual-camera registry generation \(candidate) is not newer than \(current)."
    case .noValidSnapshot: return "No valid virtual-camera registry snapshot is available."
    case .writeVerificationFailed: return "Virtual-camera registry write could not be verified."
    case .unavailableContainer: return "Virtual-camera registry app-group container is unavailable."
    }
  }
}

/// Complete, versioned registry state exchanged by the host app and extension.
/// A snapshot is the unit of publication: readers never need to combine
/// individual descriptor writes.
struct VirtualCameraRegistrySnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
#if ULTRACAM_LOCAL_DEVELOPMENT
  /// The staged ad-hoc build rewrites both bundle entitlements to this group.
  /// Keep the runtime suite name in lockstep with that signing step.
  static let defaultAppGroupIdentifier = "group.org.ultracam.local"
#else
  static let defaultAppGroupIdentifier = "group.org.ultracam.shared"
#endif

  var schemaVersion: Int
  var generation: UInt64
  var appGroupIdentifier: String
  var devices: [VirtualCameraDescriptor]

  init(schemaVersion: Int = Self.currentSchemaVersion, generation: UInt64 = 0,
    appGroupIdentifier: String = Self.defaultAppGroupIdentifier,
    devices: [VirtualCameraDescriptor] = []) {
    self.schemaVersion = schemaVersion
    self.generation = generation
    self.appGroupIdentifier = appGroupIdentifier
    self.devices = devices
  }

  init(schemaVersion: Int = Self.currentSchemaVersion, generation: UInt64 = 0,
    appGroupIdentifier: String = Self.defaultAppGroupIdentifier,
    descriptors: [VirtualCameraDescriptor]) {
    self.init(schemaVersion: schemaVersion, generation: generation,
      appGroupIdentifier: appGroupIdentifier, devices: descriptors)
  }

  /// Throws unless this is a complete snapshot safe for publication.
  func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw VirtualCameraRegistryError.invalidSchemaVersion(schemaVersion)
    }
    // UInt64 cannot be negative; explicitly reject the reserved zero value
    // only when a caller asks for a publishable update via `applying`.
    guard appGroupIdentifier == appGroupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
      !appGroupIdentifier.isEmpty,
      !appGroupIdentifier.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) else {
      throw VirtualCameraRegistryError.invalidAppGroupIdentifier
    }
    var deviceIDs = Set<String>()
    var streamIDs = Set<String>()
    guard devices.filter({ $0.kind == .program }).count <= 1 else {
      throw VirtualCameraRegistryError.multipleProgramDevices
    }
    for device in devices {
      try device.validate()
      guard deviceIDs.insert(device.id).inserted else {
        throw VirtualCameraRegistryError.duplicateDeviceID(device.id)
      }
      for streamID in [device.sourceStreamID, device.sinkStreamID] {
        guard streamIDs.insert(streamID).inserted else {
          throw VirtualCameraRegistryError.duplicateStreamID(streamID)
        }
      }
    }
  }

  func validated() -> VirtualCameraRegistrySnapshot? {
    do {
      try validate()
      return self
    } catch {
      return nil
    }
  }

  /// Produces the next complete snapshot without mutating the current one.
  /// The precondition makes generation overflow impossible to publish.
  func advancing(to devices: [VirtualCameraDescriptor]) -> VirtualCameraRegistrySnapshot {
    precondition(generation < UInt64.max, "Virtual-camera registry generation overflow")
    return VirtualCameraRegistrySnapshot(schemaVersion: schemaVersion, generation: generation + 1,
      appGroupIdentifier: appGroupIdentifier, devices: devices)
  }

  /// Accepts a candidate only when it is complete, belongs to this app group,
  /// and moves generation forward. This is the in-memory rollback fence used
  /// by persistence and by an extension reconciling a new registry.
  func applying(_ candidate: VirtualCameraRegistrySnapshot) throws -> VirtualCameraRegistrySnapshot {
    try validate()
    try candidate.validate()
    // Generation zero is the in-memory baseline used by the extension's
    // legacy fallback. It must never cross the publication/reconciliation
    // boundary, because it would allow a reset snapshot to bypass the
    // monotonic rollback fence.
    guard candidate.generation > 0, candidate.generation < UInt64.max else {
      throw VirtualCameraRegistryError.invalidGeneration
    }
    guard candidate.appGroupIdentifier == appGroupIdentifier else {
      throw VirtualCameraRegistryError.appGroupMismatch(expected: appGroupIdentifier,
        actual: candidate.appGroupIdentifier)
    }
    guard candidate.generation > generation else {
      throw VirtualCameraRegistryError.staleGeneration(current: generation, candidate: candidate.generation)
    }
    return candidate
  }
}

/// UserDefaults-backed publication with an independent backup slot. The
/// settings store owns its own keys; this store never reads or writes them.
final class VirtualCameraRegistryStore {
  static let key = "ultracam.virtual-camera-registry.v1"
  static let backupKey = "ultracam.virtual-camera-registry.v1.backup"

  private let defaults: UserDefaults?
  private let appGroupIdentifier: String

  /// The suite this store publishes to.  Keeping this available lets a host
  /// construct an in-memory baseline with the same app-group identity when a
  /// store is empty or both persistence slots are corrupt.
  var groupIdentifier: String { appGroupIdentifier }

  init(appGroupIdentifier: String = VirtualCameraRegistrySnapshot.defaultAppGroupIdentifier,
    defaults: UserDefaults? = nil) {
    self.appGroupIdentifier = appGroupIdentifier
    // A missing suite must not fall back to UserDefaults.standard. That domain
    // is per-process and can publish a different camera set than the app group.
    self.defaults = defaults ?? UserDefaults(suiteName: appGroupIdentifier)
  }

  /// Returns the newest valid slot and repairs a corrupt or stale primary
  /// slot from it. A nil result means both slots failed validation.
  func load() -> VirtualCameraRegistrySnapshot? {
    guard let defaults else { return nil }
    let primary = decode(data: defaults.data(forKey: Self.key))
    let backup = decode(data: defaults.data(forKey: Self.backupKey))
    guard let selected = [primary, backup].compactMap({ $0 }).max(by: { $0.generation < $1.generation }) else {
      return nil
    }
    if primary != selected {
      if let data = try? JSONEncoder().encode(selected) { defaults.set(data, forKey: Self.key) }
    }
    return selected
  }

  /// Publishes a complete newer snapshot. The current primary bytes are
  /// copied to backup before replacement, so a torn write can roll back.
  func save(_ snapshot: VirtualCameraRegistrySnapshot) throws {
    guard let defaults else { throw VirtualCameraRegistryError.unavailableContainer }
    try snapshot.validate()
    guard snapshot.generation < UInt64.max else {
      throw VirtualCameraRegistryError.invalidGeneration
    }
    guard snapshot.appGroupIdentifier == appGroupIdentifier else {
      throw VirtualCameraRegistryError.appGroupMismatch(expected: appGroupIdentifier,
        actual: snapshot.appGroupIdentifier)
    }
    // A zero-generation snapshot is a local fallback baseline, not a
    // publishable registry state. Reject it before touching either slot.
    guard snapshot.generation > 0 else {
      throw VirtualCameraRegistryError.invalidGeneration
    }
    let current = load()
    if let current {
      guard snapshot.generation > current.generation else {
        if snapshot == current { return }
        throw VirtualCameraRegistryError.staleGeneration(current: current.generation,
          candidate: snapshot.generation)
      }
    }
    // Preserve only a decodable, same-group primary value. Copying arbitrary
    // bytes here would turn a corrupt or foreign primary into the backup and
    // leave both slots unusable if the replacement write fails.
    let previousData = defaults.data(forKey: Self.key)
    // `load()` above may have selected a newer, valid backup while the primary
    // is stale (for example after a torn write).  Back up that selected
    // snapshot rather than blindly copying the primary bytes; otherwise a
    // failed write would roll back past the newest known registry generation.
    let previousSnapshot = current ?? decode(data: previousData)
    if let previousSnapshot,
       let backupData = try? JSONEncoder().encode(previousSnapshot) {
      defaults.set(backupData, forKey: Self.backupKey)
    } else {
      defaults.removeObject(forKey: Self.backupKey)
    }
    let encoded = try JSONEncoder().encode(snapshot)
    defaults.set(encoded, forKey: Self.key)
    guard decode(data: defaults.data(forKey: Self.key)) == snapshot else {
      if let previousSnapshot,
         let previousEncoded = try? JSONEncoder().encode(previousSnapshot) {
        defaults.set(previousEncoded, forKey: Self.key)
      } else {
        defaults.removeObject(forKey: Self.key)
      }
      throw VirtualCameraRegistryError.writeVerificationFailed
    }
  }

  private func decode(data: Data?) -> VirtualCameraRegistrySnapshot? {
    guard let data,
      let snapshot = try? JSONDecoder().decode(VirtualCameraRegistrySnapshot.self, from: data),
      snapshot.appGroupIdentifier == appGroupIdentifier,
      (try? snapshot.validate()) != nil else { return nil }
    return snapshot
  }
}
