import Foundation

/// Shared across feeds. Membership and exclusivity are serialized under lock.
final class CaptureDeviceClaims: @unchecked Sendable {
  private let lock = NSLock()
  private struct Claim { var owners: [String: Set<UUID?>]; let shareable: Bool }
  private var claims: [String: Claim] = [:]
  func claim(device: CaptureDeviceInfo, ownerID: String) throws {
    try claim(device: device, ownerID: ownerID, token: nil)
  }
  fileprivate func claim(device: CaptureDeviceInfo, ownerID: String, token: UUID?) throws {
    _ = try VendorRegistry.pluginID(for: device.id)
    try lock.withLock {
      if var claim = claims[device.id] {
        guard claim.owners[ownerID]?.contains(token) == true || (claim.shareable && device.shareable) else { throw PluginError.busy("Device already claimed: \(device.id)") }
        claim.owners[ownerID, default: []].insert(token); claims[device.id] = claim
      } else { claims[device.id] = Claim(owners: [ownerID: [token]], shareable: device.shareable) }
    }
  }
  func release(deviceID: String, ownerID: String) {
    lock.withLock {
      guard var claim = claims[deviceID] else { return }
      claim.owners.removeValue(forKey: ownerID)
      claims[deviceID] = claim.owners.isEmpty ? nil : claim
    }
  }
  fileprivate func release(deviceID: String, ownerID: String, token: UUID) {
    lock.withLock {
      guard var claim = claims[deviceID] else { return }
      claim.owners[ownerID]?.remove(token)
      if claim.owners[ownerID]?.isEmpty == true { claim.owners[ownerID] = nil }
      claims[deviceID] = claim.owners.isEmpty ? nil : claim
    }
  }
  func releaseAll(ownerID: String) {
    lock.withLock {
      for id in Array(claims.keys) {
        claims[id]?.owners.removeValue(forKey: ownerID)
        if claims[id]?.owners.isEmpty == true { claims[id] = nil }
      }
    }
  }
  func makeSession(plugin: any CaptureSourcePlugin, device: CaptureDeviceInfo, ownerID: String) -> any CaptureSession {
    ClaimedCaptureSession(session: plugin.makeSession(), claims: self, device: device, ownerID: ownerID)
  }
}
private final class ClaimedCaptureSession: CaptureSession, @unchecked Sendable {
  private let session: any CaptureSession
  private let claims: CaptureDeviceClaims
  private let device: CaptureDeviceInfo
  private let ownerID: String
  private let control = NSLock()
  private let token = UUID()
  private var stopped = false
  private var started: CaptureTiming?
  init(session: any CaptureSession, claims: CaptureDeviceClaims, device: CaptureDeviceInfo, ownerID: String) {
    self.session = session; self.claims = claims; self.device = device; self.ownerID = ownerID
  }
  var counters: CaptureCounters { session.counters }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    try control.withLock {
      guard !stopped, deviceID == device.id else { throw PluginError.invalidState("Stopped session or mismatched device") }
      if let started { guard started == timing else { throw PluginError.invalidState("Session configuration changed") }; return }
      try claims.claim(device: device, ownerID: ownerID, token: token)
      do { try session.start(deviceID: deviceID, timing: timing, handlers: handlers); started = timing }
      catch { stopped = true; session.stop(); claims.release(deviceID: device.id, ownerID: ownerID, token: token); throw error }
    }
  }
  func stop() {
    control.withLock {
      guard !stopped else { return }
      stopped = true; session.stop(); claims.release(deviceID: device.id, ownerID: ownerID, token: token)
    }
  }
  deinit { session.stop(); claims.release(deviceID: device.id, ownerID: ownerID, token: token) }
}
