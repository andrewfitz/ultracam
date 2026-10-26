import CoreMediaIO
import Foundation

/// The CMIO route whose source demand should keep one capture pipeline alive.
/// A route is keyed by the registry descriptor ID because CMIO object IDs are
/// process-local and can change when the extension reconciles its registry.
struct CameraDemandRoute: Equatable, Hashable, Identifiable, Sendable {
  let id: String
  let deviceUID: String
  let sourceStreamName: String
  let displayName: String

  init(id: String, deviceUID: String, sourceStreamName: String, displayName: String) {
    self.id = id
    self.deviceUID = deviceUID
    self.sourceStreamName = sourceStreamName
    self.displayName = displayName
  }

  init(descriptor: VirtualCameraDescriptor) {
    id = descriptor.id
    deviceUID = descriptor.deviceUID
    sourceStreamName = descriptor.displayName
    displayName = descriptor.displayName
  }

  /// The migrated route remains the default when callers have not published
  /// a registry yet, preserving existing single-camera behavior.
  static let legacy = CameraDemandRoute(
    descriptor: .feed(feedID: "default", displayName: VideoContract.cameraName))
}

/// One route-scoped demand update. `requested == nil` means the route could
/// not be discovered or read; `error` explains that condition.
struct CameraDemandChange: Equatable, Sendable {
  let route: CameraDemandRoute
  let requested: Bool?
  let error: String?
}

// Registers notifications only; it never starts a stream, allocates images,
// schedules a timer or polls the camera. All state and callbacks use main.
@MainActor
final class CameraDemandMonitor {
  private final class Listener {
    let object: CMIOObjectID
    var address: CMIOObjectPropertyAddress
    let block: CMIOObjectPropertyListenerBlock

    init(object: CMIOObjectID, address: CMIOObjectPropertyAddress, block: @escaping CMIOObjectPropertyListenerBlock) {
      self.object = object
      self.address = address
      self.block = block
    }

    deinit { _ = CMIOObjectRemovePropertyListenerBlock(object, &address, .main, block) }
  }

  private struct State: Equatable {
    let requested: Bool?
    let error: String?
  }

  private var topology: Listener?
  private var demand: [String: Listener] = [:]
  private var routesByID: [String: CameraDemandRoute] = [CameraDemandRoute.legacy.id: .legacy]
  private var states: [String: State] = [:]
  private var enabled = false

  var onRouteChange: ((CameraDemandChange) -> Void)?

  var routes: [CameraDemandRoute] { Array(routesByID.values).sorted { $0.id < $1.id } }

  init(routes: [CameraDemandRoute] = [.legacy]) { setRoutes(routes) }

  /// Replaces monitored topology without toggling the monitor. Duplicate route
  /// IDs collapse deterministically, and removed listeners are released first.
  func setRoutes(_ routes: [CameraDemandRoute]) {
    var next: [String: CameraDemandRoute] = [:]
    for route in routes where next[route.id] == nil { next[route.id] = route }
    if next.isEmpty { next[CameraDemandRoute.legacy.id] = .legacy }
    let removed = Set(routesByID.keys).subtracting(next.keys)
    for id in removed {
      demand[id] = nil
      states[id] = nil
    }
    routesByID = next
    if enabled { discover() }
  }

  func setRoutes(_ descriptors: [VirtualCameraDescriptor]) {
    setRoutes(descriptors.filter(\.enabled).map(CameraDemandRoute.init(descriptor:)))
  }

  func start() {
    guard !enabled else { return }
    enabled = true
    do {
      // CMIO requires each process to opt in to enumerating virtual cameras.
      // Do this without opening either stream (the producer normally opts in
      // during connect, which is intentionally deferred in automatic mode).
      var visibility = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
      var allow: UInt32 = 1
      try check(CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &visibility,
        0, nil, UInt32(MemoryLayout<UInt32>.size), &allow))
      topology = try listen(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) { [weak self] in
        self?.discover()
      }
      discover()
    } catch {
      // A failed registration can be retried after a mode or device change.
      enabled = false
      remove(&demand)
      remove(&topology)
      emitError(error.localizedDescription, for: routes)
    }
  }

  func stop() {
    enabled = false
    remove(&demand)
    remove(&topology)
    states.removeAll(keepingCapacity: true)
  }

  func refresh() {
    if enabled {
      discover()
    } else if onRouteChange != nil {
      // `start()` can fail before it installs the topology listener. Retry
      // must be able to rebuild that registration.
      start()
    }
  }

  private func discover() {
    guard enabled else { return }
    do {
      let devices = try ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
      for route in routes { discover(route, devices: devices) }
    } catch { emitError(error.localizedDescription, for: routes) }
  }

  private func discover(_ route: CameraDemandRoute, devices: [UInt32]) {
    do {
      guard let device = try devices.first(where: { try string($0, kCMIODevicePropertyDeviceUID) == route.deviceUID }) else {
        throw VideoError.message("Install and enable the \(route.displayName) virtual camera to use automatic feed.")
      }
      let streams = try ids(device, kCMIODevicePropertyStreams).map { ($0, try string($0, kCMIOObjectPropertyName)) }
      guard let source = Self.sourceStream(streams, named: route.sourceStreamName) else {
        throw VideoError.message("The \(route.displayName) virtual camera does not publish its source stream.")
      }
      if demand[route.id]?.object != source {
        demand[route.id] = nil
        var property = address(Int(VideoContract.demandSelector))
        guard CMIOObjectHasProperty(source, &property) else {
          throw VideoError.message("Update the installed \(route.displayName) camera extension to use automatic feed.")
        }
        // Subscribe before reading the initial state, including when enabled
        // after Zoom has already opened the camera.
        demand[route.id] = try listen(source, Int(VideoContract.demandSelector)) { [weak self] in
          self?.readDemand(routeID: route.id)
        }
      }
      readDemand(routeID: route.id)
    } catch {
      demand[route.id] = nil
      emitError(error.localizedDescription, for: route)
    }
  }

  /// The device's source stream. A running extension keeps the stream names it
  /// published, so after a camera is renamed the expected name is missing; the
  /// device UID already selected the camera, so take the stream that isn't its input.
  static func sourceStream(_ streams: [(id: UInt32, name: String)], named name: String) -> UInt32? {
    if let exact = streams.first(where: { $0.name == name })?.id { return exact }
    return CameraStreamNames.pair(streams.map { ($0.id, $0.name, nil) }, sinkName: name + " Input", sourceName: name)?.source
  }

  private func readDemand(routeID: String) {
    guard enabled, let source = demand[routeID]?.object, let route = routesByID[routeID] else { return }
    do {
      let value = try string(source, Int(VideoContract.demandSelector))
      guard value == "0" || value == "1" else { throw VideoError.message("Invalid virtual camera activity state.") }
      emit(CameraDemandChange(route: route, requested: value == "1", error: nil))
    } catch { emitError(error.localizedDescription, for: route) }
  }

  private func emitError(_ message: String, for routes: [CameraDemandRoute]) {
    for route in routes { emitError(message, for: route) }
  }

  private func emitError(_ message: String, for route: CameraDemandRoute) {
    emit(CameraDemandChange(route: route, requested: nil, error: message))
  }

  private func emit(_ change: CameraDemandChange) {
    let next = State(requested: change.requested, error: change.error)
    guard states[change.route.id] != next else { return }
    states[change.route.id] = next
    onRouteChange?(change)
  }

  private func listen(_ object: CMIOObjectID, _ selector: Int, changed: @escaping () -> Void) throws -> Listener {
    var property = address(selector)
    let block: CMIOObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { changed() } }
    try check(CMIOObjectAddPropertyListenerBlock(object, &property, .main, block))
    return Listener(object: object, address: property, block: block)
  }

  private func remove(_ listener: inout Listener?) { listener = nil }
  private func remove(_ listeners: inout [String: Listener]) { listeners.removeAll() }

  private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
      mElement: UInt32(kCMIOObjectPropertyElementMain))
  }

  private func ids(_ object: CMIOObjectID, _ selector: Int) throws -> [UInt32] {
    var property = address(selector)
    var size: UInt32 = 0
    try check(CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &size))
    guard size % 4 == 0, size <= 64 * 1024 else { throw VideoError.message("Invalid camera device list.") }
    var result = [UInt32](repeating: 0, count: Int(size) / 4)
    if !result.isEmpty {
      try result.withUnsafeMutableBytes {
        try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, $0.baseAddress!))
      }
    }
    return result
  }

  private func string(_ object: CMIOObjectID, _ selector: Int) throws -> String {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, &value))
    return value?.takeRetainedValue() as String? ?? ""
  }

  private func check(_ status: OSStatus) throws {
    guard status == noErr else { throw VideoError.message("Cannot monitor virtual camera activity (\(status)).") }
  }
}
