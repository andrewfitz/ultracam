import Foundation

/// The app-side projection of persisted feeds into the camera-extension
/// registry.  The extension deliberately knows nothing about AppSettings or
/// FeedDescriptor; this small adapter keeps the two targets' contracts
/// independent while giving every configured feed a stable CMIO identity.
extension VirtualCameraRegistrySnapshot {
  /// Whether the extension can take this snapshot. Its `validate()` is compiled into the
  /// extension, so the device limit is checked here: past it `synchronize` refuses the whole
  /// snapshot, and the publisher, which can't report that, would quietly lose the update.
  func validateDeviceCount() throws {
    guard devices.count <= VirtualCameraRegistryWire.maximumDevices else {
      throw VideoError.message("Ultracam supports at most \(VirtualCameraRegistryWire.maximumDevices) virtual cameras.")
    }
  }

  /// What meeting apps can see: one device per enabled camera, in order, then Program
  /// with two or more. Stable: only adding, removing or renaming a camera changes it,
  /// and every device's identity comes from its kind and feed ID.
  static func devices(for feeds: [FeedDescriptor]) -> [VirtualCameraDescriptor] {
    let enabled = feeds.filter(\.enabled)
    let cameras = enabled.map { feed in
      VirtualCameraDescriptor.feed(feedID: feed.id.rawValue, displayName: "Ultracam · \(feed.name)", enabled: true)
    }
    guard FeedLifecycleDemandPolicy.programPublished(enabledCameras: enabled.count) else { return cameras }
    return cameras + [.program(displayName: "Ultracam · Program")]
  }

  /// Builds a complete registry snapshot for the current feed collection. The
  /// previous generation is retained so the extension's stale-write fence works
  /// across app restarts.
  static func forFeeds(_ feeds: [FeedDescriptor], previous: VirtualCameraRegistrySnapshot? = nil,
                       appGroupIdentifier: String = Self.defaultAppGroupIdentifier)
    -> VirtualCameraRegistrySnapshot {
    // A previous snapshot is only a generation source when it is itself a
    // complete snapshot for this app group.  A malformed same-group value may
    // have come from a partial write or an older schema and must not advance
    // the rollback fence.
    let currentGeneration: UInt64
    if let previous, previous.appGroupIdentifier == appGroupIdentifier,
       (try? previous.validate()) != nil {
      currentGeneration = previous.generation
    } else {
      currentGeneration = 0
    }
    // UInt64.max cannot be advanced. Saving it is rejected, which keeps a
    // client from freezing every later publish by exhausting the counter.
    let generation = currentGeneration == UInt64.max ? currentGeneration : currentGeneration + 1
    return VirtualCameraRegistrySnapshot(
      generation: generation,
      appGroupIdentifier: appGroupIdentifier,
      devices: Self.devices(for: feeds))
  }
}

