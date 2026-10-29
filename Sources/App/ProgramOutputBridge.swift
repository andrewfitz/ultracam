import CoreMedia
import CoreVideo
import Foundation

/// Consumes the bounded Program output route and forwards its image buffers to
/// the Program virtual camera. The bridge wraps the existing `CVPixelBuffer`
/// in a sample; it never scales, converts, or copies pixels (conversion to the
/// contract happens on the GPU in `ProgramOutputRoute` before the route).
///
/// Two serial queues:
/// - `sendQueue` drains the route and calls `send`. The frame path only ever
///   schedules it asynchronously (`schedulePump`), so the publishing thread
///   never waits for CMIO.
/// - `controlQueue` connects and disconnects the sink. CMIO discovery can take
///   seconds; it never runs on the frame path or, in the app, the main actor.
///
/// The sink is touched by one queue at a time: before connecting or
/// disconnecting, the control queue marks the bridge not-connected and then
/// waits for any in-flight send (`sendQueue.sync {}`); sends only happen while
/// connected. The send queue never waits on the control queue, so there is no
/// lock-order cycle.
///
/// Timestamps: the Program clock starts at zero. Samples go out on the host
/// clock (the camera stream's clock, like every per-camera output), anchored
/// once per connection, so the extension never has to restamp them.
final class ProgramOutputBridge: @unchecked Sendable {
  struct Statistics: Equatable, Sendable {
    var delivered: UInt64 = 0
    /// CMIO's sink queue was full: the camera client is not keeping up.
    var dropped: UInt64 = 0
    var invalid: UInt64 = 0
    var sendErrors: UInt64 = 0
    /// Released because no sink was connected yet (or it was reconnecting).
    var withoutSink: UInt64 = 0
    var reconnects: UInt64 = 0
    /// Contract changes ignored because frames had already gone out on the
    /// current connection: cuts never renegotiate the camera.
    var contractChangesHeld: UInt64 = 0
    /// Frames converted for a previous contract that were still queued when
    /// the camera reconnected with a new one (before its first frame).
    var staleFormat: UInt64 = 0
    var lastRefusal: String?
    /// Sends issued on the main thread. Stays 0 when the app pumps from the
    /// delivery path.
    var mainThreadSends: UInt64 = 0
  }

  typealias Connect = (PipelineConfiguration, OSType) throws -> Void
  typealias Disconnect = () -> Void
  typealias Send = (CMSampleBuffer) throws -> Bool

  private enum Link { case disconnected, connecting, connected, failed }

  private let sendQueue: DispatchQueue
  private let controlQueue: DispatchQueue
  private let sendKey = DispatchSpecificKey<UInt8>()
  private let controlKey = DispatchSpecificKey<UInt8>()
  private let route: FrameRoute<CVPixelBuffer>
  private let connectSink: Connect
  private let disconnectSink: Disconnect
  private let sendSink: Send
  private let hostClock: () -> CMTime
  private let sampleFactory = VideoSampleFactory()  // sendQueue only
  // sendQueue only: Program → host clock offset for the current connection.
  private var hostOffset: CMTime?
  private var lastSentTime: CMTime?
  /// Since when (host seconds) frames have been more than two frames late with
  /// nothing queued behind them, and how late (seconds) they were then.
  private var lateSince: (start: Double, lateness: Double)?
  private var anchoredConnection: UInt64 = 0
  private var outputAdmission: (format: ProgramOutputFormat, contract: DerivedOutputContract)?

  private let lock = NSLock()
  private var link = Link.disconnected
  private var demand = false
  private var configuration: PipelineConfiguration?
  private var passthroughFormat: OSType?
  private var deliveredOnConnection: UInt64 = 0
  private var connection: UInt64 = 0
  private var pumpScheduled = false
  private var reconnectScheduled = false
  private var statistics = Statistics()
  private var contractHandler: (@Sendable (ProgramOutputFormat?) -> Void)?
  private var enforcesContract = false

  /// The production bridge uses the dedicated Program CMIO destination.
  convenience init(route: FrameRoute<CVPixelBuffer>, queueLabel: String = "org.ultracam.program-output-bridge") {
    let sink = CameraSink(route: CameraSinkRoute(descriptor: .program()))
    self.init(route: route, connect: { configuration, passthroughFormat in
      try sink.connect(configuration: configuration, passthroughFormat: passthroughFormat)
    }, disconnect: { sink.disconnect() }, send: { sample in
      try sink.send(sample)
    }, queueLabel: queueLabel)
  }

  /// Injectable sink operations keep lifecycle and ownership tests independent
  /// of an installed camera extension. The production initializer above is the
  /// only path that supplies the real `CameraSink`.
  init(route: FrameRoute<CVPixelBuffer>, connect: @escaping Connect,
       disconnect: @escaping Disconnect, send: @escaping Send,
       queueLabel: String = "org.ultracam.program-output-bridge",
       hostClock: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }) {
    self.route = route
    connectSink = connect
    disconnectSink = disconnect
    sendSink = send
    self.hostClock = hostClock
    sendQueue = DispatchQueue(label: queueLabel + ".send", qos: .userInteractive)
    controlQueue = DispatchQueue(label: queueLabel + ".control", qos: .userInitiated)
    sendQueue.setSpecific(key: sendKey, value: 1)
    controlQueue.setSpecific(key: controlKey, value: 1)
  }

  deinit {
    // No queue can still reference self here; tear down inline.
    if link == .connected || link == .failed { disconnectSink() }
    while let lease = route.dequeue() { lease.release() }
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  var isDemanded: Bool { locked { demand } }
  var isConnected: Bool { locked { link == .connected } }
  var currentStatistics: Statistics { locked { statistics } }

  /// The format the Program camera negotiated, or nil while not connected.
  var contract: ProgramOutputFormat? {
    locked {
      guard link == .connected, let configuration, let passthroughFormat else { return nil }
      return ProgramOutputFormat(configuration: configuration, passthroughFormat: passthroughFormat)
    }
  }

  /// When true, a frame that doesn't match the negotiated contract is counted
  /// as stale and skipped instead of being sent (and failing in CMIO). The
  /// route converts every frame to the contract, so only frames queued across
  /// a contract change can be stale. Set by `FeedCoordinator` when wired.
  var enforceContract: Bool {
    get { locked { enforcesContract } }
    set { locked { enforcesContract = newValue } }
  }

  /// Called on the control queue whenever the negotiated contract changes
  /// (nil when the sink closes).
  var onContractChange: (@Sendable (ProgramOutputFormat?) -> Void)? {
    get { locked { contractHandler } }
    set { locked { contractHandler = newValue } }
  }

  /// Opens the Program sink only while there is an active CMIO consumer, and
  /// waits for the result. Tests use this; the app uses `requestDemand`.
  func setDemand(_ active: Bool, configuration: PipelineConfiguration,
                 passthroughFormat: OSType, renegotiate: Bool = false) throws {
    try onControl {
      try applyDemand(active, configuration: configuration, passthroughFormat: passthroughFormat,
        renegotiate: renegotiate)
    }
  }

  /// Asynchronous `setDemand`: returns at once; `completion` runs on the
  /// control queue with the connection error, if any.
  func requestDemand(_ active: Bool, configuration: PipelineConfiguration,
                     passthroughFormat: OSType, renegotiate: Bool = false,
                     completion: @escaping @Sendable (Error?) -> Void) {
    controlQueue.async { [self] in
      do {
        try applyDemand(active, configuration: configuration, passthroughFormat: passthroughFormat,
          renegotiate: renegotiate)
        completion(nil)
      } catch {
        completion(error)
      }
    }
  }

  /// Drains queued frames now and waits. The frame path uses `schedulePump`.
  func pump() {
    if DispatchQueue.getSpecific(key: sendKey) != nil { pumpOnSendQueue(); return }
    sendQueue.sync { pumpOnSendQueue() }
  }

  /// Schedules one drain on the send queue. Coalesces: frames published while
  /// a drain is pending are picked up by it, in order.
  func schedulePump() {
    let schedule = locked { () -> Bool in
      guard !pumpScheduled else { return false }
      pumpScheduled = true
      return true
    }
    guard schedule else { return }
    sendQueue.async { [self] in pumpOnSendQueue() }
  }

  /// Waits until queued control and send work has run. For tests.
  func waitUntilIdle() {
    controlQueue.sync {}
    sendQueue.sync {}
  }

  /// Closes the Program sink and releases any pending leases. The route itself
  /// remains registered so a later demand transition can resume output.
  func disconnect() {
    onControl {
      locked { demand = false }
      closeLink()
    }
  }

  // MARK: - Control queue

  private func onControl<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: controlKey) != nil { return try body() }
    return try controlQueue.sync(execute: body)
  }

  /// `renegotiate` is for the session owner's own format changes (cadence
  /// detected after connect, settings edited); cuts never pass it.
  private func applyDemand(_ active: Bool, configuration: PipelineConfiguration,
                           passthroughFormat: OSType, renegotiate: Bool) throws {
    guard active else {
      locked { demand = false }
      closeLink()
      return
    }
    let next = ProgramOutputFormat(configuration: configuration, passthroughFormat: passthroughFormat)
    let keep = locked { () -> Bool in
      demand = true
      guard link == .connected, let current = self.configuration, let pass = self.passthroughFormat else {
        return false
      }
      if ProgramOutputFormat(configuration: current, passthroughFormat: pass) == next { return true }
      // One fixed contract per client session. Before the first frame the
      // contract may still settle (e.g. input cadence detected after
      // connect); after it, cuts and settings changes are converted on the
      // GPU instead of renegotiating the camera.
      if deliveredOnConnection > 0, !renegotiate {
        statistics.contractChangesHeld &+= 1
        return true
      }
      return false
    }
    if keep { schedulePump(); return }
    try connect(configuration: configuration, passthroughFormat: passthroughFormat)
  }

  /// Connects (or reconnects) the sink. Control queue only.
  private func connect(configuration: PipelineConfiguration, passthroughFormat: OSType) throws {
    let wasLinked = locked { () -> Bool in
      let linked = link == .connected || link == .failed
      link = .connecting
      return linked
    }
    sendQueue.sync {}  // no send is in flight past this point
    if wasLinked {
      disconnectSink()
      locked { contractHandler }?(nil)
    }
    do {
      // CameraSink also serves feed routes, where rate controls may only
      // reduce source cadence. Program owns a CFR clock and may repeat up to
      // its explicitly selected rate, so negotiate that output cadence here.
      var transportConfiguration = configuration
      if configuration.reduceFrameRate {
        transportConfiguration.sourceDuration = configuration.frameRateTarget.duration
      }
      try connectSink(transportConfiguration, passthroughFormat)
    } catch {
      locked {
        link = .disconnected
        demand = false
      }
      drainRoute()
      throw error
    }
    let handler = locked { () -> (@Sendable (ProgramOutputFormat?) -> Void)? in
      link = .connected
      self.configuration = configuration
      self.passthroughFormat = passthroughFormat
      deliveredOnConnection = 0
      self.connection &+= 1
      return contractHandler
    }
    handler?(ProgramOutputFormat(configuration: configuration, passthroughFormat: passthroughFormat))
    schedulePump()
  }

  private func closeLink() {
    let wasLinked = locked { () -> Bool in
      let linked = link == .connected || link == .failed
      link = .connecting  // blocks sends while the sink closes
      return linked
    }
    sendQueue.sync {}
    if wasLinked { disconnectSink() }
    let handler = locked { () -> (@Sendable (ProgramOutputFormat?) -> Void)? in
      link = .disconnected
      configuration = nil
      passthroughFormat = nil
      return contractHandler
    }
    handler?(nil)
    drainRoute()
  }

  /// After a failed send: keep demand, reconnect with the same contract.
  /// Retries once a second while the client still wants the camera.
  private func scheduleReconnect(after delay: TimeInterval) {
    let schedule = locked { () -> Bool in
      guard !reconnectScheduled else { return false }
      reconnectScheduled = true
      return true
    }
    guard schedule else { return }
    controlQueue.asyncAfter(deadline: .now() + delay) { [self] in
      let target = locked { () -> (PipelineConfiguration, OSType)? in
        reconnectScheduled = false
        guard demand, link == .failed, let configuration, let passthroughFormat else { return nil }
        return (configuration, passthroughFormat)
      }
      guard let (configuration, passthroughFormat) = target else { return }
      locked { statistics.reconnects &+= 1 }
      do {
        try connect(configuration: configuration, passthroughFormat: passthroughFormat)
      } catch {
        // `connect` cleared demand on failure; restore it and keep trying.
        locked {
          demand = true
          link = .failed
          self.configuration = configuration
          self.passthroughFormat = passthroughFormat
        }
        scheduleReconnect(after: 1)
      }
    }
  }

  private func drainRoute() {
    var released: UInt64 = 0
    while let lease = route.dequeue() { lease.release(); released &+= 1 }
    if released > 0 { locked { statistics.withoutSink &+= released } }
  }

  // MARK: - Send queue

  private func pumpOnSendQueue() {
    locked { pumpScheduled = false }
    while let lease = route.dequeue() {
      defer { lease.release() }
      let (connected, expected, connection) = locked { () -> (Bool, ProgramOutputFormat?, UInt64) in
        guard link == .connected, demand else { return (false, nil, self.connection) }
        guard enforcesContract, let configuration, let passthroughFormat else { return (true, nil, self.connection) }
        return (true, ProgramOutputFormat(configuration: configuration, passthroughFormat: passthroughFormat),
          self.connection)
      }
      guard connected else {
        locked { statistics.withoutSink &+= 1 }
        continue
      }
      if let expected, let metadata = lease.metadata,
        !expected.matches(metadata) || !DerivedOutputContract.sameDuration(metadata.duration, expected.duration) {
        locked { statistics.staleFormat &+= 1; statistics.lastRefusal = "Program frame differs from negotiated output \(expected)" }
        continue
      }
      guard let image = lease.payload, let metadata = lease.metadata,
        metadata.presentationTime.isValid, metadata.presentationTime.isNumeric,
        metadata.presentationTime.epoch == 0,
        metadata.duration.isValid, metadata.duration.isNumeric,
        metadata.duration.epoch == 0, metadata.duration.value > 0,
        CVPixelBufferGetWidth(image) == metadata.width,
        CVPixelBufferGetHeight(image) == metadata.height,
        CVPixelBufferGetPixelFormatType(image) == OSType(metadata.pixelFormat) else {
        locked { statistics.invalid &+= 1 }
        continue
      }
      if let expected {
        do {
          if outputAdmission?.format != expected {
            let description = try expected.formatDescription()
            outputAdmission = (expected, DerivedOutputContract(format: description, duration: expected.duration))
          }
          if let refusal = outputAdmission?.contract.mismatch(image: image, time: metadata.presentationTime, duration: metadata.duration) {
            locked { statistics.invalid &+= 1; statistics.lastRefusal = refusal }
            continue
          }
        } catch {
          locked { statistics.invalid &+= 1; statistics.lastRefusal = error.localizedDescription }
          continue
        }
      }
      if connection != anchoredConnection {
        anchoredConnection = connection
        hostOffset = nil
        lateSince = nil
        lastSentTime = nil
      }
      let time = hostTime(for: metadata.presentationTime, duration: metadata.duration,
        backlogged: route.pendingCount > 0)
      do {
        let sample = try sampleFactory.sample(image, at: time, duration: metadata.duration)
        let accepted = try sendSink(sample)
        lastSentTime = time
        locked {
          if Thread.isMainThread { statistics.mainThreadSends &+= 1 }
          if accepted {
            statistics.delivered &+= 1
            deliveredOnConnection &+= 1
          } else {
            statistics.dropped &+= 1
          }
        }
      } catch {
        // A failed enqueue usually means the CMIO client released the virtual
        // camera between our demand check and this send. Keep demand asserted
        // and reconnect on the control queue; never block the frame path.
        locked {
          statistics.sendErrors &+= 1
          if link == .connected { link = .failed }
        }
        scheduleReconnect(after: 0)
      }
    }
  }
}

extension ProgramOutputBridge {
  /// How long frames must stay equally late before the host-time anchor moves
  /// (seconds): longer than a stall's catch-up burst, short against a gap on air.
  static let lateReanchorDelay = 0.25

  /// Program time on the host clock: one offset per connection, so spacing is
  /// exactly the Program clock's. Re-anchored, never backwards, when the Program
  /// clock restarts or steps back, strays more than two frames ahead of real time,
  /// or falls behind it as a gap on air does: after a short gap Program time
  /// continues where it left off while real time moved on, and every later frame
  /// would go out that much late. Such frames arrive at the Program spacing with
  /// nothing queued behind them, equally late (within two frames) for
  /// `lateReanchorDelay`. Lateness that changes or has a backlog behind it (a slow
  /// send, a starved send queue, a stalled burst catching up) recovers once the
  /// backlog drains, so it keeps the offset: moving the anchor then would leave
  /// every later frame that far ahead. Delivery jitter within two frames keeps the
  /// offset; a burst at one moment keeps the spacing (the anchor is then the
  /// previous frame plus one duration).
  fileprivate func hostTime(for programTime: CMTime, duration: CMTime, backlogged: Bool) -> CMTime {
    // On the Program timescale, so mapped spacing stays exact.
    let clock = hostClock()
    let now = CMTimeConvertScale(clock, timescale: programTime.timescale, method: .roundTowardZero)
    if let hostOffset {
      let mapped = CMTimeAdd(programTime, hostOffset)
      let ahead = CMTimeSubtract(mapped, now).seconds
      let tolerance = 2 * duration.seconds
      if lastSentTime.map({ CMTimeCompare(mapped, $0) > 0 }) ?? true {
        if abs(ahead) <= tolerance {
          lateSince = nil
          return mapped
        }
        if ahead < -tolerance {
          let lateness = -ahead
          if backlogged {
            lateSince = nil
            return mapped
          }
          guard let since = lateSince, abs(lateness - since.lateness) <= tolerance else {
            lateSince = (clock.seconds, lateness)
            return mapped
          }
          if clock.seconds - since.start < Self.lateReanchorDelay { return mapped }
        }
      }
    }
    lateSince = nil
    var anchor = now
    if let lastSentTime { anchor = CMTimeMaximum(anchor, CMTimeAdd(lastSentTime, duration)) }
    hostOffset = CMTimeSubtract(anchor, programTime)
    return anchor
  }
}

/// Feeds the Program monitor from the Program route's publishing thread.
/// The sink is lock-based and non-blocking, so the monitor gets every Program
/// frame in order without a main-actor hop. Program's frame is its only
/// picture (no output twin): it is already processed, so its sink has no
/// burn-in LUT and no source correspondence. Generation changes at each cut
/// so the monitor restarts its per-source state.
final class ProgramMonitorTap: @unchecked Sendable {
  private let sink: any MonitorFrameSink
  private let lock = NSLock()
  private var generation: UInt64 = 1
  private var sequence: UInt64 = 0

  init(sink: any MonitorFrameSink) { self.sink = sink }

  /// Starts a new monitor generation, e.g. when Program becomes available
  /// again after the monitor invalidated the Program sink.
  func restart() {
    lock.lock()
    generation &+= 1
    lock.unlock()
  }

  func offer(frame: ProcessedFrame<CVPixelBuffer>, sourcePTS: CMTime, cutApplied: Bool) {
    lock.lock()
    if cutApplied { generation &+= 1 }
    sequence &+= 1
    let generation = self.generation
    let sequence = self.sequence
    lock.unlock()
    sink.offer(frame.payload, pts: sourcePTS, captureGeneration: generation, sequence: sequence)
  }
}
