import Foundation

/// Keeps loss logging useful without letting a flaky source flood the system
/// log: the first `burst` losses of a run are logged one by one, later ones
/// are counted and summarized at most once per `interval`. `events` and
/// `frames` keep the run's totals for the end-of-run summary.
struct LossLogLimiter: Sendable {
  enum Decision: Equatable {
    /// Log this loss on its own line.
    case log
    /// The last loss logged on its own: say that later ones are summarized.
    case logLast
    /// Counted; nothing to log yet.
    case quiet
    /// One line for the losses since the last line, this one included.
    case summary(events: UInt64, frames: UInt64)
  }

  let burst: Int
  let interval: TimeInterval
  private(set) var events: UInt64 = 0
  private(set) var frames: UInt64 = 0
  private var logged = 0
  private var pendingEvents: UInt64 = 0
  private var pendingFrames: UInt64 = 0
  private var windowStart: TimeInterval?

  init(burst: Int = 20, interval: TimeInterval = 60) {
    self.burst = max(1, burst)
    self.interval = max(1, interval)
  }

  mutating func note(frames lost: UInt64, at now: TimeInterval) -> Decision {
    events &+= 1
    frames = frames.addingReportingOverflow(lost).overflow ? .max : frames + lost
    if logged < burst {
      logged += 1
      if logged == burst { windowStart = now; return .logLast }
      return .log
    }
    pendingEvents &+= 1
    pendingFrames = pendingFrames.addingReportingOverflow(lost).overflow ? .max : pendingFrames + lost
    guard let start = windowStart, now - start >= interval else { return .quiet }
    defer { pendingEvents = 0; pendingFrames = 0; windowStart = now }
    return .summary(events: pendingEvents, frames: pendingFrames)
  }

  /// Losses counted but not yet logged; the caller logs them with the run's summary.
  mutating func flush() -> (events: UInt64, frames: UInt64)? {
    guard pendingEvents > 0 else { return nil }
    defer { pendingEvents = 0; pendingFrames = 0 }
    return (pendingEvents, pendingFrames)
  }
}
