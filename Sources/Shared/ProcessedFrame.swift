import CoreMedia
import Foundation

/// The immutable description that travels with a processed image.
///
/// A route must never infer timing or layout from the payload. The producer
/// fills this value once, then every route sees the same metadata.
public struct ProcessedFrameMetadata: @unchecked Sendable, Equatable {
  public let presentationTime: CMTime
  public let duration: CMTime
  public let width: Int
  public let height: Int
  public let pixelFormat: UInt32
  public let maximumRepeatDuration: Double
  public let repeatCount: Int
  public let processingRevision: UInt64

  public init(presentationTime: CMTime, duration: CMTime, width: Int, height: Int,
              pixelFormat: UInt32, processingRevision: UInt64 = 0, repeatCount: Int = 1, maximumRepeatDuration: Double = 2) {
    self.presentationTime = presentationTime
    self.duration = duration
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
    self.maximumRepeatDuration = maximumRepeatDuration.isFinite ? max(0, maximumRepeatDuration) : 0
    self.repeatCount = max(1, repeatCount)
    self.processingRevision = processingRevision
  }
}

/// A queue-owned frame whose payload is retained until its producer and every
/// route lease release their references.
///
/// `Payload` is deliberately generic so ownership can be tested with a small
/// value or object and later instantiated with a CVPixelBuffer by the capture
/// pipeline. The class does not perform any pixel work or route scheduling.
public final class ProcessedFrame<Payload>: @unchecked Sendable {
  private let storage: FrameStorage<Payload>

  public var payload: Payload { storage.payload }
  public var metadata: ProcessedFrameMetadata { storage.metadata }

  public init(payload: Payload, metadata: ProcessedFrameMetadata,
              onReleased: (() -> Void)? = nil) {
    storage = FrameStorage(payload: payload, metadata: metadata, onReleased: onReleased)
  }

  /// Retains one independent route reference. The returned lease must be
  /// released by the consumer; deinitialization is an idempotent safety net.
  public func retainLease() -> FrameLease<Payload> {
    storage.retainReference()
    return FrameLease(storage: storage)
  }

  deinit { storage.releaseReference() }
}

/// One route's explicit ownership of a processed frame.
public final class FrameLease<Payload>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: FrameStorage<Payload>?

  fileprivate init(storage: FrameStorage<Payload>) { self.storage = storage }

  public var isReleased: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storage == nil
  }

  /// The payload is unavailable after `release` returns. Consumers should
  /// read it before releasing the lease.
  public var payload: Payload? {
    lock.lock()
    defer { lock.unlock() }
    return storage?.payload
  }

  public var metadata: ProcessedFrameMetadata? {
    lock.lock()
    defer { lock.unlock() }
    return storage?.metadata
  }

  /// Releases this route's reference exactly once. Calling it repeatedly is
  /// harmless, which lets cancellation and consumer cleanup race safely.
  public func release() {
    let retained: FrameStorage<Payload>?
    lock.lock()
    retained = storage
    storage = nil
    lock.unlock()
    retained?.releaseReference()
  }

  deinit { release() }
}

/// What a full route does with a new frame. Routes never drop to stay
/// current: a full route keeps every pending lease and reports the rejection,
/// which the producer counts and shows as a stall.
public enum FrameQueueOverflowPolicy: Equatable, Sendable {
  /// Keep all pending leases and report backpressure to the producer.
  case reject
}

public enum FrameRouteEnqueueResult: Equatable, Sendable {
  case enqueued
  case rejected
  case cancelled
}

/// Per-publish totals across every route, without building the per-route
/// report dictionary (the Program path publishes every frame).
public struct FrameFanOutSummary: Equatable, Sendable {
  public var enqueued = 0
  /// Distinct cadence slots accepted by at least one route.
  public var publishedSamples = 0
  public var rejected = 0
  public var routerClosed = false
}

public struct FrameFanOutReport: Equatable, Sendable {
  public let outcomes: [String: FrameRouteEnqueueResult]
  public let routerClosed: Bool

  public init(outcomes: [String: FrameRouteEnqueueResult], routerClosed: Bool = false) {
    self.outcomes = outcomes
    self.routerClosed = routerClosed
  }

  public subscript(routeID: String) -> FrameRouteEnqueueResult? { outcomes[routeID] }
}

public enum FrameFanOutError: Error, Equatable {
  case invalidRouteID
  case invalidCapacity
  case routerClosed
  case duplicateRoute(String)
}

/// A single output route with a bounded pending queue.
public final class FrameRoute<Payload>: @unchecked Sendable {
  public let id: String
  private weak var owner: FrameFanOut<Payload>?
  // Route IDs can be reused after cancellation. Keep a registration token so
  // an old handle cannot operate a later route with the same ID.
  private let token: AnyObject

  fileprivate init(id: String, owner: FrameFanOut<Payload>, token: AnyObject) {
    self.id = id
    self.owner = owner
    self.token = token
  }

  public var isCancelled: Bool { owner?.routeIsCancelled(id, token: token) ?? true }
  public var pendingCount: Int { owner?.routePendingCount(id, token: token) ?? 0 }
  /// Changes when pending work is invalidated; in-flight owners remain valid
  /// for retirement but must not publish a retired repeat schedule.
  public var generation: UInt64 { owner?.routeGeneration(id, token: token) ?? .max }

  /// Removes and transfers the oldest pending lease to the caller.
  public func dequeue() -> FrameLease<Payload>? { owner?.dequeue(routeID: id, token: token) }

  /// Cancels this route and synchronously releases all leases still pending in
  /// its queue. A dequeued lease remains valid for its current consumer.
  public func cancel() { owner?.cancel(routeID: id, token: token) }
}

/// Serial, synchronous fan-out coordinator. Every mutation, including route
/// cancellation and final teardown, runs on one private serial queue. This
/// makes ownership and queue bounds deterministic without coupling the
/// contract to CaptureController or CameraSink.
public final class FrameFanOut<Payload>: @unchecked Sendable {
  private final class RouteState {
    let capacity: Int
    let policy: FrameQueueOverflowPolicy
    let compactRepeats: Bool
    let token = NSObject()
    var pending: [FrameLease<Payload>] = []
    var generation: UInt64 = 0

    init(capacity: Int, policy: FrameQueueOverflowPolicy, compactRepeats: Bool) {
      self.capacity = capacity
      self.policy = policy
      self.compactRepeats = compactRepeats
    }

    /// Detaches pending leases before releasing them. Release callbacks are
    /// user code and may synchronously mutate the fan-out; clearing first
    /// keeps those callbacks from invalidating an active queue traversal.
    func detachPending() -> [FrameLease<Payload>] {
      let leases = pending
      pending.removeAll(keepingCapacity: false)
      return leases
    }
  }

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()
  private var routes: [String: RouteState] = [:] {
    // Publishing visits routes in a stable order; sort once per topology
    // change, not once per frame.
    didSet { orderedRouteIDs = routes.keys.sorted() }
  }
  private var orderedRouteIDs: [String] = []
  private var closed = false

  public init(label: String = "org.ultracam.frame-fanout") {
    queue = DispatchQueue(label: label, qos: .userInteractive)
    queue.setSpecific(key: queueKey, value: 1)
  }

  public func addRoute(id: String, capacity: Int,
                      policy: FrameQueueOverflowPolicy, compactRepeats: Bool = false) throws -> FrameRoute<Payload> {
    guard !id.isEmpty else { throw FrameFanOutError.invalidRouteID }
    guard capacity > 0 else { throw FrameFanOutError.invalidCapacity }
    return try sync {
      guard !closed else { throw FrameFanOutError.routerClosed }
      guard routes[id] == nil else { throw FrameFanOutError.duplicateRoute(id) }
      let state = RouteState(capacity: capacity, policy: policy, compactRepeats: compactRepeats)
      routes[id] = state
      return FrameRoute(id: id, owner: self, token: state.token)
    }
  }

  /// Publishes one frame to every active route. Each accepted route receives a
  /// separate lease; routes never share release state or queue capacity.
  @discardableResult
  public func publish(_ frame: ProcessedFrame<Payload>) -> FrameFanOutReport {
    sync {
      guard !closed else { return FrameFanOutReport(outcomes: [:], routerClosed: true) }
      var outcomes: [String: FrameRouteEnqueueResult] = [:]
      for id in orderedRouteIDs {
        guard let route = routes[id] else { continue }
        outcomes[id] = enqueueLocked(frame, on: route)
      }
      return FrameFanOutReport(outcomes: outcomes)
    }
  }

  /// `publish` without the per-route report: counts only, no allocation.
  @discardableResult
  public func publishSummary(_ frame: ProcessedFrame<Payload>) -> FrameFanOutSummary {
    sync {
      var summary = FrameFanOutSummary()
      guard !closed else { summary.routerClosed = true; return summary }
      for id in orderedRouteIDs {
        guard let route = routes[id] else { continue }
        if enqueueLocked(frame, on: route) == .enqueued { summary.enqueued += 1 } else { summary.rejected += 1 }
      }
      return summary
    }
  }

  /// Compact consumers retain one image/schedule; ordinary consumers retain
  /// independent sample leases. Both share the original backing ownership.
  public func publishRepeatedSummary(_ frame: ProcessedFrame<Payload>, count: Int) -> FrameFanOutSummary {
    sync {
      var summary = FrameFanOutSummary()
      guard !closed else { summary.routerClosed = true; return summary }
      let metadata = frame.metadata
      for id in orderedRouteIDs {
        guard let route = routes[id] else { continue }
        let sends = route.compactRepeats ? 1 : count
        var acceptedSamples = 0
        for index in 0..<sends {
          let timed = ProcessedFrame(payload: frame.payload, metadata: ProcessedFrameMetadata(
            presentationTime: CMTimeAdd(metadata.presentationTime, CMTimeMultiply(metadata.duration, multiplier: Int32(index))),
            duration: metadata.duration, width: metadata.width, height: metadata.height,
            pixelFormat: metadata.pixelFormat, processingRevision: metadata.processingRevision,
            repeatCount: route.compactRepeats ? count : 1, maximumRepeatDuration: metadata.maximumRepeatDuration), onReleased: { withExtendedLifetime(frame) {} })
          let logicalCount = route.compactRepeats ? count : 1
          if enqueueLocked(timed, on: route) == .enqueued { summary.enqueued += logicalCount; acceptedSamples += logicalCount }
          else { summary.rejected += logicalCount }
        }
        summary.publishedSamples = max(summary.publishedSamples, acceptedSamples)
      }
      return summary
    }
  }

  /// A full route keeps its pending leases and rejects the new frame.
  private func enqueueLocked(_ frame: ProcessedFrame<Payload>, on route: RouteState) -> FrameRouteEnqueueResult {
    guard route.pending.count < route.capacity else { return .rejected }
    route.pending.append(frame.retainLease())
    return .enqueued
  }

  fileprivate func dequeue(routeID: String, token: AnyObject) -> FrameLease<Payload>? {
    sync {
      guard let route = routes[routeID], route.token === token, !closed else { return nil }
      return route.pending.isEmpty ? nil : route.pending.removeFirst()
    }
  }

  fileprivate func routePendingCount(_ routeID: String, token: AnyObject) -> Int {
    sync {
      guard let route = routes[routeID], route.token === token else { return 0 }
      return route.pending.count
    }
  }

  fileprivate func routeIsCancelled(_ routeID: String, token: AnyObject) -> Bool {
    sync {
      guard !closed, let route = routes[routeID] else { return true }
      return route.token !== token
    }
  }

  fileprivate func routeGeneration(_ routeID: String, token: AnyObject) -> UInt64 {
    sync { guard let route = routes[routeID], route.token === token else { return .max }; return route.generation }
  }

  fileprivate func cancel(routeID: String, token: AnyObject) {
    sync {
      guard let route = routes[routeID], route.token === token else { return }
      routes.removeValue(forKey: routeID)
      route.detachPending().forEach { $0.release() }
    }
  }

  /// Stops admission and drains every route synchronously. Calling `close`
  /// more than once is harmless. Leases already dequeued remain caller-owned.
  public func close() {
    sync {
      guard !closed else { return }
      closed = true
      // Remove all registrations before releasing payloads. A release
      // callback may re-enter the router and must observe a closed router
      // without mutating a dictionary currently being enumerated.
      let activeRoutes = Array(routes.values)
      routes.removeAll(keepingCapacity: false)
      for route in activeRoutes {
        route.detachPending().forEach { $0.release() }
      }
    }
  }

  /// Releases all queued leases while keeping routes registered for a later
  /// session generation. Dequeued leases remain owned by their consumers.
  public func drain() {
    sync {
      guard !closed else { return }
      // Snapshot route state before invoking callbacks. A callback can cancel
      // another route, which mutates `routes` while this operation is active.
      let activeRoutes = Array(routes.values)
      for route in activeRoutes { route.generation &+= 1 }
      for route in activeRoutes {
        route.detachPending().forEach { $0.release() }
      }
    }
  }

  public var isClosed: Bool { sync { closed } }

  deinit { close() }

  private func sync<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
    return try queue.sync(execute: body)
  }
}

private final class FrameStorage<Payload>: @unchecked Sendable {
  let payload: Payload
  let metadata: ProcessedFrameMetadata
  private let lock = NSLock()
  private let onReleased: (() -> Void)?
  private var references = 1

  init(payload: Payload, metadata: ProcessedFrameMetadata, onReleased: (() -> Void)?) {
    self.payload = payload
    self.metadata = metadata
    self.onReleased = onReleased
  }

  func retainReference() {
    lock.lock()
    references += 1
    lock.unlock()
  }

  func releaseReference() {
    var callback: (() -> Void)?
    lock.lock()
    if references > 0 {
      references -= 1
      if references == 0 { callback = onReleased }
    }
    lock.unlock()
    callback?()
  }
}
