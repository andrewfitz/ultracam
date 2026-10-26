import Foundation

/// A source-demand route owned by the runtime coordinator.
///
/// Preview is deliberately represented as a route so the coordinator can
/// account for it in diagnostics, but it never keeps a source capture active.
enum DemandRoute: String, Hashable, Codable, Sendable {
  case dedicatedCamera
  case program
  case manualOutput
  case preview

  var contributesToSourceDemand: Bool {
    switch self {
    case .dedicatedCamera, .program, .manualOutput:
      return true
    case .preview:
      return false
    }
  }
}

/// One idempotent hold on a feed route. The lease is a value; releasing it
/// more than once is safe and releasing a stale lease cannot release a newer
/// lease for the same route.
struct RouteDemandLease: Hashable, Identifiable, Sendable {
  fileprivate let token: UInt64
  let feedID: String
  let route: DemandRoute
  fileprivate let ownerID: String?

  var id: UInt64 { token }
  var isPreviewOnly: Bool { route == .preview }
}

/// Lifecycle work requested after source demand has remained stable for the
/// configured debounce interval.
enum SourceDemandTransition: Equatable, Sendable {
  case start(feedID: String)
  case stop(feedID: String)

  var feedID: String {
    switch self {
    case .start(let feedID), .stop(let feedID): return feedID
    }
  }
}

/// The route truth table for one feed. `previewOnly` is exposed separately so
/// UI and diagnostics can explain why a preview is visible while capture is
/// idle.
struct FeedDemandSnapshot: Equatable, Sendable {
  let feedID: String
  let dedicatedCamera: Bool
  let program: Bool
  let manualOutput: Bool
  let previewOnly: Bool

  var sourceDemand: Bool {
    dedicatedCamera || program || manualOutput
  }

  var isPreviewOnly: Bool {
    previewOnly && !sourceDemand
  }
}

/// A pure, queue-confined coordinator for route-aware source demand.
///
/// `RouteDemandCoordinator` owns no timers or media resources. Callers report
/// route changes with `acquire`/`release`, advance the supplied monotonic clock
/// with `advance(to:)`, and execute the returned transitions in their capture
/// controller. Calling `drainTransitions()` is useful when a zero-duration
/// debounce emits work directly from an acquire/release operation.
struct RouteDemandCoordinator: Sendable {
  struct Debounce: Equatable, Sendable {
    var start: TimeInterval
    var stop: TimeInterval

    init(start: TimeInterval = 0, stop: TimeInterval = 0) {
      self.start = max(0, start.isFinite ? start : 0)
      self.stop = max(0, stop.isFinite ? stop : 0)
    }
  }

  private struct LeaseKey: Hashable, Sendable {
    let feedID: String
    let route: DemandRoute
    let ownerID: String?
  }

  private struct Pending: Sendable {
    let targetRunning: Bool
    let since: TimeInterval
  }

  private var leases: [LeaseKey: RouteDemandLease] = [:]
  private var running: Set<String> = []
  private var pending: [String: Pending] = [:]
  private var transitions: [SourceDemandTransition] = []
  private var nextToken: UInt64 = 1
  private var clock: TimeInterval = 0
  private(set) var debounce: Debounce

  init(startDebounce: TimeInterval = 0, stopDebounce: TimeInterval = 0) {
    debounce = Debounce(start: startDebounce, stop: stopDebounce)
  }

  init(debounce: Debounce) {
    self.debounce = debounce
  }

  /// The current selected feed for the Program output route, if any.
  var selectedProgramFeedID: String? {
    leases.first(where: { $0.key.route == .program && $0.key.ownerID == nil })?.key.feedID
  }

  /// The current selected feed for the explicit manual output route, if any.
  var selectedManualFeedID: String? {
    leases.first(where: { $0.key.route == .manualOutput && $0.key.ownerID == nil })?.key.feedID
  }

  /// Route-level demand has no implicit source polling. This is a pure lookup
  /// over leases currently held by callers. Preview-only leases are included
  /// because this property describes all active routes, including diagnostics.
  var activeFeedIDs: Set<String> {
    Set(leases.keys.map(\.feedID))
  }

  /// Feed IDs that currently have a route which requires source capture.
  /// Preview-only leases intentionally do not appear here: a visible preview
  /// can exist while its source capture remains idle.
  var activeSourceFeedIDs: Set<String> {
    Set(leases.keys.compactMap { key in
      key.route.contributesToSourceDemand ? key.feedID : nil
    })
  }

  /// Acquire a route lease. Repeating the same `(feed, route, ownerID)` call
  /// returns the original lease, so repeated notifications cannot inflate
  /// demand. Supplying distinct owner IDs allows independent clients to hold
  /// the same route without sharing a token.
  @discardableResult
  mutating func acquire(feedID: String, route: DemandRoute, ownerID: String? = nil,
    at time: TimeInterval? = nil) -> RouteDemandLease {
    let timestamp = recordTime(time)
    let key = LeaseKey(feedID: feedID, route: route, ownerID: ownerID)
    if let existing = leases[key] {
      reconcile(feedID: feedID, at: timestamp)
      return existing
    }
    let lease = RouteDemandLease(token: nextToken, feedID: feedID, route: route, ownerID: ownerID)
    nextToken &+= 1
    // Zero is reserved for an uninitialized token if the counter wraps. A
    // wrap is practically unreachable, but preserving a nonzero identity
    // keeps stale-lease checks unambiguous in long-lived hosts.
    if nextToken == 0 { nextToken = 1 }
    leases[key] = lease
    reconcile(feedID: feedID, at: timestamp)
    return lease
  }

  /// Argument-order convenience for route-first call sites.
  @discardableResult
  mutating func acquire(route: DemandRoute, feedID: String, ownerID: String? = nil,
    at time: TimeInterval? = nil) -> RouteDemandLease {
    acquire(feedID: feedID, route: route, ownerID: ownerID, at: time)
  }

  @discardableResult
  mutating func acquireDedicatedCamera(feedID: String, ownerID: String? = nil,
    at time: TimeInterval? = nil) -> RouteDemandLease {
    acquire(feedID: feedID, route: .dedicatedCamera, ownerID: ownerID, at: time)
  }

  @discardableResult
  mutating func acquirePreview(feedID: String, at time: TimeInterval? = nil) -> RouteDemandLease {
    acquire(feedID: feedID, route: .preview, at: time)
  }

  /// Release a lease. Unknown or already released leases are ignored.
  @discardableResult
  mutating func release(_ lease: RouteDemandLease, at time: TimeInterval? = nil) -> Bool {
    let timestamp = recordTime(time)
    let key = LeaseKey(feedID: lease.feedID, route: lease.route, ownerID: lease.ownerID)
    guard leases[key]?.token == lease.token else { return false }
    leases.removeValue(forKey: key)
    reconcile(feedID: lease.feedID, at: timestamp)
    return true
  }

  /// Release the idempotent default lease for a route without retaining its
  /// token. Owner-specific leases should use `release(_:)`.
  @discardableResult
  mutating func release(feedID: String, route: DemandRoute, at time: TimeInterval? = nil) -> Bool {
    guard let lease = leases[LeaseKey(feedID: feedID, route: route, ownerID: nil)] else { return false }
    return release(lease, at: time)
  }

  /// Releases an owner-specific route without requiring callers to retain the
  /// lease token. This is useful for CMIO clients whose disconnect callback
  /// carries a stable owner ID but not the original acquisition value.
  @discardableResult
  mutating func release(feedID: String, route: DemandRoute, ownerID: String?,
                        at time: TimeInterval? = nil) -> Bool {
    guard let lease = leases[LeaseKey(feedID: feedID, route: route, ownerID: ownerID)] else {
      return false
    }
    return release(lease, at: time)
  }

  /// Keep only one selected Program feed. A replacement releases the previous
  /// selection before acquiring the new one, while preserving debounce timing
  /// for each feed independently.
  mutating func selectProgram(feedID: String?, at time: TimeInterval? = nil) {
    let timestamp = recordTime(time)
    if selectedProgramFeedID == feedID { return }
    if let current = selectedProgramFeedID {
      _ = release(feedID: current, route: .program, at: timestamp)
    }
    if let feedID {
      _ = acquire(feedID: feedID, route: .program, at: timestamp)
    }
  }

  /// Keep only one selected explicit manual output feed.
  mutating func selectManualOutput(feedID: String?, at time: TimeInterval? = nil) {
    let timestamp = recordTime(time)
    if selectedManualFeedID == feedID { return }
    if let current = selectedManualFeedID {
      _ = release(feedID: current, route: .manualOutput, at: timestamp)
    }
    if let feedID {
      _ = acquire(feedID: feedID, route: .manualOutput, at: timestamp)
    }
  }

  /// Advance the injected monotonic clock and return lifecycle work whose
  /// debounce interval has elapsed. Time moving backwards is ignored.
  @discardableResult
  mutating func advance(to time: TimeInterval) -> [SourceDemandTransition] {
    let timestamp = recordTime(time)
    let feeds = Set(leases.keys.map(\.feedID)).union(running).union(pending.keys)
    for feedID in feeds.sorted() {
      reconcile(feedID: feedID, at: timestamp)
    }
    return drainTransitions()
  }

  /// Mark the actual capture state after a runtime start/stop completes. A
  /// failed start can therefore be represented by `running: false` and will
  /// retry after the configured start debounce.
  mutating func setRunning(feedID: String, running isRunning: Bool,
    at time: TimeInterval? = nil) {
    let timestamp = recordTime(time)
    if isRunning { running.insert(feedID) } else { running.remove(feedID) }
    pending.removeValue(forKey: feedID)
    reconcile(feedID: feedID, at: timestamp)
  }

  /// Return queued transitions emitted by zero-duration debounce or a prior
  /// `setRunning` call.
  mutating func drainTransitions() -> [SourceDemandTransition] {
    defer { transitions.removeAll(keepingCapacity: true) }
    return transitions
  }

  func snapshot(for feedID: String) -> FeedDemandSnapshot {
    var dedicated = false
    var program = false
    var manual = false
    var preview = false
    for key in leases.keys where key.feedID == feedID {
      switch key.route {
      case .dedicatedCamera: dedicated = true
      case .program: program = true
      case .manualOutput: manual = true
      case .preview: preview = true
      }
    }
    return FeedDemandSnapshot(feedID: feedID, dedicatedCamera: dedicated,
      program: program, manualOutput: manual, previewOnly: preview)
  }

  func sourceDemand(for feedID: String) -> Bool {
    snapshot(for: feedID).sourceDemand
  }

  func demand(for feedID: String) -> Bool {
    sourceDemand(for: feedID)
  }

  func isRunning(feedID: String) -> Bool {
    running.contains(feedID)
  }

  func leaseCount(feedID: String, route: DemandRoute) -> Int {
    leases.keys.reduce(into: 0) { count, key in
      if key.feedID == feedID && key.route == route { count += 1 }
    }
  }

  /// Standalone truth-table function used by policy checks and callers that do
  /// not need to create leases yet.
  static func sourceDemand(dedicatedCamera: Bool, program: Bool,
    manualOutput: Bool, previewOnly: Bool = false) -> Bool {
    _ = previewOnly
    return dedicatedCamera || program || manualOutput
  }

  private mutating func recordTime(_ requested: TimeInterval?) -> TimeInterval {
    guard let requested, requested.isFinite else { return clock }
    if requested > clock { clock = requested }
    return clock
  }

  private mutating func reconcile(feedID: String, at time: TimeInterval) {
    let desired = sourceDemand(for: feedID)
    let actual = running.contains(feedID)
    guard desired != actual else {
      pending.removeValue(forKey: feedID)
      return
    }
    let target = desired
    if let current = pending[feedID], current.targetRunning == target {
      let interval = target ? debounce.start : debounce.stop
      guard time - current.since >= interval else { return }
      pending.removeValue(forKey: feedID)
    } else {
      pending[feedID] = Pending(targetRunning: target, since: time)
      if (target ? debounce.start : debounce.stop) > 0 { return }
      pending.removeValue(forKey: feedID)
    }
    if target {
      running.insert(feedID)
      transitions.append(.start(feedID: feedID))
    } else {
      running.remove(feedID)
      transitions.append(.stop(feedID: feedID))
    }
  }
}
