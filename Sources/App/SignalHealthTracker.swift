import Foundation

/// When a lost signal counts, and when a camera that lost one may take a cut again.
/// Dropouts on this rig last 23 to 33 ms, and Program repeats its last frame for 2 s, so
/// nothing reacts to one. No frames or updates arrive during a loss, so AppModel's own
/// timer drives `tick`. Every time here is on the `systemUptime` clock, like `CaptureSignal`.
struct SignalHealthTracker {
  /// Without signal this long, a camera is unhealthy: nothing cuts to it, and every
  /// surface says it's lost. Shorter than this it stays live on all of them.
  static let lossHold: TimeInterval = 1
  /// Steady signal this long makes it eligible again, so a flapping cable can't bounce Auto.
  static let returnHold: TimeInterval = 5

  enum Change: Equatable { case unhealthy(FeedID), eligible(FeedID) }

  private struct State {
    var lostSince: TimeInterval?
    var unhealthy = false
    var steadySince: TimeInterval?
  }
  private var cameras: [FeedID: State] = [:]

  /// A camera's newest signal. A loss dates from when frames stopped, not from now.
  mutating func note(_ id: FeedID, signal: CaptureSignal, now: TimeInterval) {
    var state = cameras[id] ?? State()
    switch signal {
    case .live:
      state.lostSince = nil
      if state.unhealthy, state.steadySince == nil { state.steadySince = now }
    case .lost(let since):
      state.lostSince = state.lostSince ?? since
      state.steadySince = nil
    case .unsupported:
      // Nothing usable arrives, which is a loss to anything that needs a picture.
      state.lostSince = state.lostSince ?? now
      state.steadySince = nil
    case .waiting:
      break
    }
    cameras[id] = state
  }

  /// The camera stopped: whatever it was doing has ended with it.
  mutating func remove(_ id: FeedID) { cameras[id] = nil }

  mutating func tick(now: TimeInterval) -> [Change] {
    var changes: [Change] = []
    for (id, state) in cameras.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      var next = state
      if !next.unhealthy, let lost = next.lostSince, now - lost >= Self.lossHold {
        next.unhealthy = true
        changes.append(.unhealthy(id))
      }
      if next.unhealthy, let steady = next.steadySince, now - steady >= Self.returnHold {
        next.unhealthy = false
        next.steadySince = nil
        changes.append(.eligible(id))
      }
      cameras[id] = next
    }
    return changes
  }

  func isUnhealthy(_ id: FeedID) -> Bool { cameras[id]?.unhealthy == true }

  /// Lost, but not yet for long enough to count.
  func isWithinLossHold(_ id: FeedID) -> Bool {
    guard let state = cameras[id] else { return false }
    return state.lostSince != nil && !state.unhealthy
  }

  /// Seconds of steady signal still needed; nil unless the signal is back and being watched.
  func secondsUntilEligible(_ id: FeedID, now: TimeInterval) -> TimeInterval? {
    guard let state = cameras[id], state.unhealthy, let steady = state.steadySince else { return nil }
    return max(0, Self.returnHold - (now - steady))
  }
}

/// Where Program goes when the camera on it has no picture: the next live camera in strip
/// order after it, wrapping round. Nil means nothing else has a picture, and Program stays.
enum ProgramFailover {
  static func nextLive(after current: FeedID, order: [FeedID], isLive: (FeedID) -> Bool) -> FeedID? {
    guard let start = order.firstIndex(of: current) else { return order.first(where: isLive) }
    return (order[(start + 1)...] + order[..<start]).first(where: isLive)
  }
}

/// A take that has outlived the meeting it was for. Needs a client seen during the takes
/// now rolling, so a recording with no meeting at all isn't told off, and an unreadable
/// route says nothing, because nobody can tell.
struct UnusedTakeWatch {
  private var clientSeenAt: TimeInterval?

  mutating func update(rolling: Bool, clientConnected: Bool, clientsUnknown: Bool, now: TimeInterval) -> Bool {
    guard rolling else {
      clientSeenAt = nil
      return false
    }
    if clientConnected { clientSeenAt = now }
    guard !clientsUnknown, let seen = clientSeenAt else { return false }
    return now - seen >= LiveWatchLimits.unusedTake
  }
}

/// How long a queue must stay full, and how long no one may have used Ultracam, before
/// either counts. Frames and clients come and go; these are what stays true.
enum LiveWatchLimits {
  /// The extension's queue stayed full this long: the client has stopped taking video.
  static let queueStall: TimeInterval = 2
  /// A client with no frames this long is waiting, not joining.
  static let clientWaiting: TimeInterval = 2
  /// How long a client's demand outlives it. A meeting app probing a camera opens and
  /// closes it: without this each probe would stop capture and restart the director.
  static let clientRelease: TimeInterval = 5
  /// A failed connect tries again this often while a client is waiting.
  static let connectRetry: TimeInterval = 1
  /// A take running this long after its last client left has outlived its meeting.
  static let unusedTake: TimeInterval = 120
}
