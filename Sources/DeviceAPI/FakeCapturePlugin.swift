#if ULTRACAM_TEST_SUPPORT
import Foundation

/// Script-driven fixture. It never generates or accesses CPU video pixels.
final class FakeCapturePlugin: CaptureSourcePlugin, @unchecked Sendable {
  let format: SourceFormat
  let audio: SourceAudioDeclaration
  private let pluginLock = NSLock()
  private var connected = false
  private let deviceIDs: [String]
  private var createdSessions: [FakeCaptureSession] = []
  @MainActor private var observers: [WeakObservation] = []
  @MainActor private struct WeakObservation { weak var value: DeviceObservation? }
  @MainActor private var statusObservers: [WeakStatusObservation] = []
  @MainActor private struct WeakStatusObservation { weak var value: DeviceStatusObservation? }
  /// Scripted hardware facts, by device ID (`pluginLock`).
  struct Details: Sendable { var name: String; var model: String? = nil; var modes: [SourceFormat] = []; var connectors: [Connector] = [] }
  private var details: [String: Details] = [:]
  private var statuses: [String: CaptureDeviceStatus] = [:]
  private var scriptedSettings: [String: [VendorSetting]] = [:]
  private var idleRefreshCount = 0
  init(format: SourceFormat, audio: SourceAudioDeclaration, deviceIDs: [String] = ["fake:fixture"],
       descriptor: VendorDescriptor = VendorDescriptor(id: "fake", displayName: "Fake capture", badgeText: "FAKE", signalHint: nil, sdkVersion: nil, sdkPresent: true)) {
    precondition(!deviceIDs.isEmpty && Set(deviceIDs).count == deviceIDs.count && deviceIDs.allSatisfy { $0.hasPrefix("fake:") })
    self.format = format; self.audio = audio; self.deviceIDs = deviceIDs; self.descriptor = descriptor
  }
  /// Names, models and modes for the listed devices.
  func setDetails(_ value: Details, for deviceID: String) { pluginLock.withLock { details[deviceID] = value } }
  func setSettings(_ settings: [VendorSetting], for deviceID: String) { pluginLock.withLock { scriptedSettings[deviceID] = settings } }
  /// A status as the plugin's reader would publish it.
  @MainActor func setStatus(_ status: CaptureDeviceStatus, for deviceID: String) {
    pluginLock.withLock { statuses[deviceID] = status }
    statusObservers = statusObservers.filter { $0.value != nil }
    statusObservers.compactMap(\.value).forEach { $0.deliver(deviceID, status) }
  }
  /// How often the host asked for an idle read.
  var idleRefreshes: Int { pluginLock.withLock { idleRefreshCount } }
  func status(deviceID: String) -> CaptureDeviceStatus? { pluginLock.withLock { statuses[deviceID] } }
  @MainActor func observeStatus(_ handler: @escaping @MainActor @Sendable (String, CaptureDeviceStatus) -> Void) -> DeviceStatusObservation? {
    let observation = DeviceStatusObservation(handler)
    statusObservers.append(WeakStatusObservation(value: observation))
    return observation
  }
  func refreshIdleStatus() { pluginLock.withLock { idleRefreshCount += 1 } }
  var sessions: [FakeCaptureSession] { pluginLock.withLock { createdSessions } }
  @MainActor func setConnected(_ connected: Bool) {
    // A real plugin's cache forgets a device that leaves.
    pluginLock.withLock { self.connected = connected; if !connected { statuses = [:] } }
    let snapshot = CaptureDeviceSnapshot(status: driverStatus(), devices: (try? devices()) ?? [], error: nil)
    observers = observers.filter { $0.value != nil }
    observers.compactMap(\.value).forEach { $0.deliver(snapshot) }
  }
  let descriptor: VendorDescriptor
  func driverStatus() -> DriverStatus { DriverStatus(installed: true, supported: true, version: nil, reason: nil) }
  func devices() throws -> [CaptureDeviceInfo] {
    guard pluginLock.withLock({ connected }) else { return [] }
    let details = pluginLock.withLock { self.details }
    return deviceIDs.enumerated().map { index, id in
      let detail = details[id]
      return CaptureDeviceInfo(id: id, name: detail?.name ?? "Fixture source \(index + 1)", connectors: detail?.connectors ?? [],
        shareable: true, mayPause: nil, supportedModes: "Scripted fixture", model: detail?.model, modes: detail?.modes ?? [])
    }
  }
  @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation {
    let observation = DeviceObservation(handler)
    observers.append(WeakObservation(value: observation))
    observation.deliver(CaptureDeviceSnapshot(status: driverStatus(), devices: (try? devices()) ?? [], error: nil))
    return observation
  }
  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat? { format }
  func makeSession() -> any CaptureSession {
    let session = FakeCaptureSession(format: format, audio: audio, deviceIDs: deviceIDs)
    pluginLock.withLock { createdSessions.append(session) }
    return session
  }
  func diagnostics(deviceID: String) -> DeviceDiagnostics? { nil }
  func settings(deviceID: String) async throws -> [VendorSetting] { pluginLock.withLock { scriptedSettings[deviceID] ?? [] } }
  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String) async throws {
    try pluginLock.withLock {
      guard let index = scriptedSettings[deviceID]?.firstIndex(where: { $0.id == setting }),
        let old = scriptedSettings[deviceID]?[index] else { throw PluginError.unsupported("Fixture has no settings") }
      scriptedSettings[deviceID]?[index] = VendorSetting(id: old.id, labelKey: old.labelKey, value: value, allowedValues: old.allowedValues,
        mutable: old.mutable, availabilityReason: old.availabilityReason, interruptsCapture: old.interruptsCapture,
        labelFallback: old.labelFallback)
    }
  }
}

/// All lifecycle and deliveries are serialized on `queue`. Admission closes
/// under `lock` before stop drains that queue. Queue callbacks never acquire a
/// control queue, and callers must not synchronously stop from a handler.
final class FakeCaptureSession: CaptureSession, @unchecked Sendable {
  private let queue = DispatchQueue(label: "Ultracam.FakeCapture.delivery")
  private let queueKey = DispatchSpecificKey<Bool>()
  private let lock = NSLock()
  private let control = NSLock()
  private var stopped = false
  private var startedTiming: CaptureTiming?
  private var startedDeviceID: String?
  private let deviceIDs: [String]
  private var accepting = false
  private var stats = CaptureCounters()
  // Handler is queue-isolated; context fields are protected by lock.
  private var handlers: CaptureHandlers?
  private var epochID = CaptureEpochID(sessionID: UUID(), epoch: 0)
  private var sequence: UInt64 = 0
  private var mappingRevision: UInt64 = 0
  private var bindings = CaptureClockBindings(video: ClockInstanceID(), audio: nil)
  private var format: SourceFormat
  private var audio: SourceAudioDeclaration
  private let maximumPendingDeliveries: Int
  init(format: SourceFormat, audio: SourceAudioDeclaration = .absent, maximumPendingDeliveries: Int = 1024, deviceIDs: [String] = ["fake:fixture"]) {
    self.deviceIDs = deviceIDs
    precondition(maximumPendingDeliveries >= 2)
    self.maximumPendingDeliveries = maximumPendingDeliveries
    self.format = format
    self.audio = audio
    queue.setSpecific(key: queueKey, value: true)
  }
  var counters: CaptureCounters { lock.withLock { stats } }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    guard DispatchQueue.getSpecific(key: queueKey) == nil else { throw PluginError.invalidState("Start from delivery callback") }
    try control.withLock {
      guard !stopped else { throw PluginError.invalidState("Stopped session requires a fresh session") }
      if lock.withLock({ accepting }) {
        guard deviceID == startedDeviceID, startedTiming == timing else { throw PluginError.invalidState("Session already running with different configuration") }
        return
      }
      guard deviceIDs.contains(deviceID) else { throw PluginError.unavailable("Unknown fixture device") }
      if case .fixed(let requested) = timing, requested != format { throw PluginError.unsupported("Fixture format mismatch") }
      queue.sync {
        self.handlers = handlers
        epochID = CaptureEpochID(sessionID: UUID(), epoch: 0)
        sequence = 0
        bindings = CaptureClockBindings(video: ClockInstanceID(), audio: Self.audioBinding(audio))
      }
      startedTiming = timing
      startedDeviceID = deviceID
      // Declarations enter the queue before admission opens to other callers.
      lock.withLock {
        accepting = true
        enqueue([envelope(.event(.formatChanged(format))), envelope(.event(.audioFormatChanged(audio)))])
      }
    }
  }

  func stop() {
    precondition(DispatchQueue.getSpecific(key: queueKey) == nil, "stop must not run inside a delivery callback")
    control.withLock {
      lock.withLock { accepting = false }
      queue.sync { handlers = nil }
      stopped = true
    }
  }
  /// Admits complete callback groups atomically; there is no consumer-busy drop.
  /// Caller-created frames must use the current context returned by `context`.
  @discardableResult func submit(_ payload: CaptureDelivery.Payload) -> Bool { submitGroup([payload]) }
  @discardableResult func submitGroup(_ payloads: [CaptureDelivery.Payload]) -> Bool {
    lock.withLock {
      guard accepting else { return false }
      let saved = (format, audio, epochID, sequence, bindings, mappingRevision)
      var deliveries: [CaptureDelivery] = []
      for payload in payloads {
        switch payload {
        case .frame(_, let info), .cpuMemory(_, let info):
          guard info.epochID == epochID, info.formatSignature == format.signature,
            (try? info.validate()) != nil else {
            (format, audio, epochID, sequence, bindings, mappingRevision) = saved
            return false
          }
          deliveries.append(envelope(payload))
        case .event(.formatChanged(let value)) where value != format:
          format = value
          nextEpoch()
          deliveries += declarations()
        case .event(.audioFormatChanged(let value)) where value != audio:
          audio = value
          bindings = CaptureClockBindings(video: bindings.video, audio: Self.audioBinding(value))
          nextEpoch()
          deliveries += declarations()
        case .event(.discontinuity):
          bindings = CaptureClockBindings(video: ClockInstanceID(), audio: Self.audioBinding(audio))
          nextEpoch()
          deliveries.append(envelope(payload))
          deliveries += declarations()
        case .event(.clockMappingChanged(let update)):
          guard update.epochID == epochID, update.revision > mappingRevision,
            update.effectiveSequence == sequence + 2,
            update.clockID == bindings.video || update.clockID == bindings.audio else {
            (format, audio, epochID, sequence, bindings, mappingRevision) = saved
            return false
          }
          deliveries.append(envelope(payload))
          mappingRevision = update.revision
        default:
          deliveries.append(envelope(payload))
        }
      }
      guard deliveries.count <= maximumPendingDeliveries - stats.currentBacklog else {
        (format, audio, epochID, sequence, bindings, mappingRevision) = saved
        return false
      }
      enqueue(deliveries)
      return true
    }
  }
  private static func audioBinding(_ declaration: SourceAudioDeclaration) -> ClockInstanceID? {
    if case .present(let format) = declaration, format.clock != .pairedWithFrames { return ClockInstanceID() }
    return nil
  }
  // Requires lock. All context changes and generated declarations are atomic
  // with admission. Envelopes freeze context before asynchronous delivery.
  private func nextEpoch() {
    epochID = CaptureEpochID(sessionID: epochID.sessionID, epoch: epochID.epoch + 1)
    mappingRevision = 0
  }
  private func declarations() -> [CaptureDelivery] {
    [envelope(.event(.formatChanged(format))), envelope(.event(.audioFormatChanged(audio)))]
  }
  private func envelope(_ payload: CaptureDelivery.Payload) -> CaptureDelivery {
    sequence += 1
    return CaptureDelivery(sequence: sequence, epochID: epochID, formatSignature: format.signature,
      clockBindings: bindings, mappingRevision: mappingRevision, payload: payload)
  }
  private func enqueue(_ deliveries: [CaptureDelivery]) {
    stats.currentBacklog += deliveries.count
    stats.maximumBacklog = max(stats.maximumBacklog, stats.currentBacklog)
    queue.async { [self] in
      for delivery in deliveries {
        handlers?.deliver(delivery)
        lock.withLock { stats.currentBacklog -= 1 }
      }
    }
  }
  var context: (epochID: CaptureEpochID, formatSignature: String, clockBindings: CaptureClockBindings,
                mappingRevision: UInt64, nextSequence: UInt64) {
    lock.withLock { (epochID, format.signature, bindings, mappingRevision, sequence + 1) }
  }

}

#endif
