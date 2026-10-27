import CoreMediaIO
import Foundation

/// A bounded control message, independent of the accounts running the host and
/// camera service. UserDefaults persists host intent; CMIO carries it to the
/// actual running provider. No images, paths or bookmarks cross this channel.
enum VirtualCameraRegistryWire {
  static let property = CMIOExtensionProperty(rawValue: "4cc_ucrg_glob_0000")
  static let selector: UInt32 = 0x75637267 // 'ucrg'
  static let maximumBytes = 64 * 1024
  static let maximumDevices = 32

  static func encode(_ snapshot: VirtualCameraRegistrySnapshot) throws -> String {
    try snapshot.validate()
    guard snapshot.devices.count <= maximumDevices else {
      throw VideoError.message("A virtual-camera registry supports at most 32 devices.")
    }
    let data = try JSONEncoder().encode(snapshot)
    guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
      throw VideoError.message("Virtual-camera registry is too large.")
    }
    return text
  }

  static func decode(_ text: String) throws -> VirtualCameraRegistrySnapshot {
    guard text.utf8.count <= maximumBytes else {
      throw VideoError.message("Virtual-camera registry is too large.")
    }
    let snapshot = try JSONDecoder().decode(VirtualCameraRegistrySnapshot.self, from: Data(text.utf8))
    _ = try encode(snapshot)
    return snapshot
  }

  static func update(_ desired: VirtualCameraRegistrySnapshot,
    after current: VirtualCameraRegistrySnapshot) throws -> VirtualCameraRegistrySnapshot? {
    // Zero is the local bootstrap baseline and max is exhausted; neither may
    // cross the transport publication boundary.
    guard desired.generation > 0, desired.generation < UInt64.max else {
      throw VirtualCameraRegistryError.invalidGeneration
    }
    _ = try encode(desired)
    _ = try encode(current)
    guard desired.appGroupIdentifier == current.appGroupIdentifier else {
      throw VirtualCameraRegistryError.appGroupMismatch(expected: desired.appGroupIdentifier,
        actual: current.appGroupIdentifier)
    }
    if desired.devices == current.devices { return nil }
    guard current.generation < UInt64.max else {
      throw VideoError.message("Virtual-camera registry generation is exhausted.")
    }
    var candidate = desired
    candidate.generation = max(desired.generation, current.generation + 1)
    return candidate
  }
}

enum VirtualCameraRegistryTransport {
  private static let lock = NSLock()

  private static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: selector,
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
  }

  private static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw VideoError.message("\(operation) (\(status)).") }
  }

  static func providerID() throws -> CMIOObjectID {
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var visibility = address(UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices))
    var allow: UInt32 = 1
    try check(CMIOObjectSetPropertyData(system, &visibility, 0, nil, 4, &allow),
      "Cannot discover virtual cameras")
    var bundleID: CFString = VideoContract.extensionID as CFString
    var result: CMIOObjectID = 0
    try withUnsafeMutablePointer(to: &bundleID) { input in
      try withUnsafeMutablePointer(to: &result) { output in
        var translation = AudioValueTranslation(mInputData: input,
          mInputDataSize: UInt32(MemoryLayout<CFString>.size), mOutputData: output,
          mOutputDataSize: UInt32(MemoryLayout<CMIOObjectID>.size))
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        var property = address(UInt32(kCMIOHardwarePropertyPlugInForBundleID))
        try check(CMIOObjectGetPropertyData(system, &property, 0, nil, size, &size, &translation),
          "Cannot find Ultracam camera provider")
      }
    }
    guard result != 0 else { throw VideoError.message("Install and enable the Ultracam camera extension.") }
    return result
  }

  static func read(_ provider: CMIOObjectID) throws -> VirtualCameraRegistrySnapshot {
    var property = address(VirtualCameraRegistryWire.selector)
    guard CMIOObjectHasProperty(provider, &property) else {
      throw VideoError.message("Update the installed Ultracam camera extension to synchronize feeds.")
    }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(CMIOObjectGetPropertyData(provider, &property, 0, nil, size, &size, &value),
      "Cannot read virtual-camera registry")
    guard let text = value?.takeRetainedValue() as String? else {
      throw VideoError.message("The camera provider returned no registry.")
    }
    return try VirtualCameraRegistryWire.decode(text)
  }

  /// Synchronous read/write/read acknowledgement. Called before sink discovery
  /// as well as on topology changes, so capture never targets a stale registry.
  @discardableResult
  static func synchronize(_ desired: VirtualCameraRegistrySnapshot) throws -> VirtualCameraRegistrySnapshot {
    lock.lock()
    defer { lock.unlock() }
    let provider = try providerID()
    let current = try read(provider)
    guard let candidate = try VirtualCameraRegistryWire.update(desired, after: current) else { return current }
    let text = try VirtualCameraRegistryWire.encode(candidate) as CFString
    var reference = Unmanaged.passUnretained(text).toOpaque()
    var property = address(VirtualCameraRegistryWire.selector)
    try check(CMIOObjectSetPropertyData(provider, &property, 0, nil,
      UInt32(MemoryLayout<CFString>.size), &reference), "Cannot update virtual-camera registry")
    // DAL caches custom properties and delivers the provider's change
    // notification asynchronously. Await that acknowledgement before the
    // caller attempts device discovery; this wait exists only at publication.
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
      let applied = try read(provider)
      if applied == candidate { return applied }
      Thread.sleep(forTimeInterval: 0.01)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw VideoError.message("The camera provider did not acknowledge the requested feeds.")
  }
}

/// Notifications only: no background timer, source stream or video work.
@MainActor
final class VirtualCameraRegistryPublisher {
  private final class Listener {
    let block: CMIOObjectPropertyListenerBlock
    init(_ block: @escaping CMIOObjectPropertyListenerBlock) { self.block = block }
    deinit {
      var property = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyDevices),
        mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
      _ = CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &property, .main, block)
    }
  }
  private var desired: VirtualCameraRegistrySnapshot?
  private var listener: Listener?

  init() {
    let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
      MainActor.assumeIsolated { self?.synchronize() }
    }
    var property = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyDevices),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &property, .main, block) == noErr {
      listener = Listener(block)
    }
  }

  func publish(_ snapshot: VirtualCameraRegistrySnapshot) {
    desired = snapshot
    synchronize()
  }

  private func synchronize() {
    guard let desired else { return }
    // Absence before installation is expected. A capture attempt performs the
    // same handshake and surfaces any error in its camera-output status.
    _ = try? VirtualCameraRegistryTransport.synchronize(desired)
  }
}
