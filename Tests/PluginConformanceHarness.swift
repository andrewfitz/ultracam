#if ULTRACAM_TEST_SUPPORT
import Foundation

/// Vendor synthetic drivers supply the stimulus; assertions remain shared.
/// Hardware is never discovered or opened by this harness implicitly.
struct CaptureConformanceFactory {
  let name: String
  let deviceID: String
  let makeSession: () throws -> any CaptureSession
  let stimulate: (any CaptureSession) throws -> Void
}
enum PluginConformanceFailure: Error { case violation(String) }
enum PluginConformanceHarness {
  /// The supplied start closure may enter a vendor's synthetic callback seam.
  /// It is deliberately separate from hardware-start lifecycle assertions.
  static func serializedStopBarrier(session: any CaptureSession,
                                    start: (CaptureHandlers) throws -> Void,
                                    emit: @escaping @Sendable () -> Void) throws {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    let state = ConformanceSerializationState()
    try start(CaptureHandlers(deliver: { delivery in
      switch delivery.payload {
      case .event(.info("stop barrier")), .frame: break
      default: return
      }
      let first = state.enter()
      entered.signal()
      if first { _ = release.wait(timeout: .now() + 3) }
      state.leave()
    }))
    DispatchQueue.global().async { emit() }
    guard entered.wait(timeout: .now() + 3) == .success else {
      session.stop(); throw PluginConformanceFailure.violation("Synthetic stimulus did not enter callback")
    }
    let competingEmitter = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { emit(); competingEmitter.signal() }
    DispatchQueue.global().async { session.stop(); stopped.signal() }
    let early = stopped.wait(timeout: .now() + 0.03) == .success
    release.signal()
    let drained = early || stopped.wait(timeout: .now() + 3) == .success
    guard competingEmitter.wait(timeout: .now() + 3) == .success else {
      throw PluginConformanceFailure.violation("Concurrent stimulus did not quiesce")
    }
    let before = state.snapshot
    emit()
    guard !early, drained, state.snapshot == before, before.maximum == 1 else {
      throw PluginConformanceFailure.violation("Stop failed serialized callback quiescence")
    }
    session.stop()
    do { try session.start(deviceID: "conformance:retired", timing: .automatic, handlers: CaptureHandlers(deliver: { _ in })) }
    catch { return }
    throw PluginConformanceFailure.violation("Stopped session admitted restart")
  }
  static func captureDiscovery(_ plugin: any CaptureSourcePlugin) throws {
    let status = plugin.driverStatus()
    let devices: [CaptureDeviceInfo]
    do { devices = try plugin.devices() }
    catch { if !status.installed || !status.supported { return }; throw error }
    var ids = Set<String>()
    for device in devices {
      guard device.id.hasPrefix(plugin.descriptor.id + ":"),
        device.id.count > plugin.descriptor.id.count + 1, ids.insert(device.id).inserted else {
        throw PluginConformanceFailure.violation("Invalid or duplicate device identity")
      }
    }
    guard devices.isEmpty || (status.installed && status.supported) else {
      throw PluginConformanceFailure.violation("Unavailable driver advertises selectable devices")
    }
  }
  static func captureLifecycle(_ factory: CaptureConformanceFactory) throws {
    let session = try factory.makeSession()
    let counter = ConformanceCallbackCounter()
    try session.start(deviceID: factory.deviceID, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in counter.received() }))
    try session.start(deviceID: factory.deviceID, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in counter.replaced() }))
    try factory.stimulate(session)
    session.stop(); session.stop()
    let stopped = counter.snapshot
    try factory.stimulate(session)
    guard counter.snapshot == stopped, stopped.replacements == 0 else {
      throw PluginConformanceFailure.violation("\(factory.name): callback after stop or handler replacement")
    }
    do {
      try session.start(deviceID: factory.deviceID, timing: .automatic, handlers: CaptureHandlers(deliver: { _ in }))
    } catch { return }
    throw PluginConformanceFailure.violation("\(factory.name): stopped session restarted")
  }
  /// Run on each delivery stream. Epoch declarations are required before
  /// frames, and retired epochs cannot reappear even with a fresh sequence.
  struct Transcript {
    private var sequence: UInt64 = 0
    private var epoch: CaptureEpochID?
    private var retired = Set<CaptureEpochID>()
    private var clockBindings: CaptureClockBindings?
    private var declaredSignature: String?
    private var audioDeclaration: SourceAudioDeclaration?
    mutating func accept(_ delivery: CaptureDelivery) throws {
      guard delivery.sequence > sequence else { throw PluginConformanceFailure.violation("Duplicate or regressed delivery") }
      guard !retired.contains(delivery.epochID) else { throw PluginConformanceFailure.violation("Retired epoch delivery") }
      if let epoch, epoch != delivery.epochID {
        retired.insert(epoch); declaredSignature = nil; audioDeclaration = nil; clockBindings = nil
      }
      epoch = delivery.epochID; sequence = delivery.sequence
      if let clockBindings, clockBindings != delivery.clockBindings {
        throw PluginConformanceFailure.violation("Clock bindings changed without a new capture epoch")
      }
      if let declaredSignature, declaredSignature != delivery.formatSignature {
        throw PluginConformanceFailure.violation("Video contract changed without a new capture epoch")
      }
      clockBindings = delivery.clockBindings
      switch delivery.payload {
      case .event(.formatChanged(let format)):
        guard format.signature == delivery.formatSignature else { throw PluginConformanceFailure.violation("Declaration signature mismatch") }
        declaredSignature = format.signature
      case .event(.audioFormatChanged(let declaration)):
        if let audioDeclaration, audioDeclaration.isResolved, audioDeclaration != declaration {
          throw PluginConformanceFailure.violation("Audio contract changed without a new capture epoch")
        }
        audioDeclaration = declaration
      case .frame(_, let info), .cpuMemory(_, let info):
        guard audioDeclaration != nil, declaredSignature == delivery.formatSignature, info.epochID == delivery.epochID,
          info.formatSignature == delivery.formatSignature else { throw PluginConformanceFailure.violation("Frame before matching declarations") }
        try info.validate()
      case .rawAudio(let packet):
        guard declaredSignature == delivery.formatSignature,
          case .present(let format) = audioDeclaration, packet.format == format else {
          throw PluginConformanceFailure.violation("Audio before matching declarations")
        }
        if let paired = packet.pairedFrameSequence, paired >= delivery.sequence {
          throw PluginConformanceFailure.violation("Audio paired to future delivery")
        }
      case .media(let media):
        guard declaredSignature == delivery.formatSignature, let audioDeclaration,
          media.audioDeclaration == audioDeclaration else { throw PluginConformanceFailure.violation("Media before matching declarations") }
      default: break
      }
    }
  }
  @MainActor static func controlLifecycle(make: () -> any CameraControlPlugin, camera: ControlCamera) async throws {
    try await ControlPluginConformanceHarness.run(make: make, camera: camera)
  }
}
private final class ConformanceCallbackCounter: @unchecked Sendable {
  struct Snapshot: Equatable { var callbacks = 0; var replacements = 0 }
  private let lock = NSLock(); private var state = Snapshot()
  var snapshot: Snapshot { lock.withLock { state } }
  func received() { lock.withLock { state.callbacks += 1 } }
  func replaced() { lock.withLock { state.replacements += 1 } }
}
private final class ConformanceSerializationState: @unchecked Sendable {
  struct Snapshot: Equatable { var active = 0; var total = 0; var maximum = 0 }
  private let lock = NSLock()
  private var state = Snapshot()
  var snapshot: Snapshot { lock.withLock { state } }
  func enter() -> Bool { lock.withLock { state.active += 1; state.total += 1; state.maximum = max(state.maximum, state.active); return state.total == 1 } }
  func leave() { lock.withLock { state.active -= 1 } }
}
#endif
