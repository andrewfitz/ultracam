import Synchronization

/// How many resets of each kind have been requested, or applied.
struct ResetGenerations: Sendable, BitwiseCopyable, Equatable {
  var peaks: UInt64 = 0
  var loudness: UInt64 = 0
  var all: UInt64 = 0

  /// Every request so far; moves on each one.
  var total: UInt64 { peaks &+ loudness &+ all }
}

/// The resets readers have asked for, as generation counters rather than
/// flags the producer clears. The producer publishes the generations it has
/// applied next to its readings, so a reader compares the two and applies
/// any newer request to what it read: a reset shows from the moment it is
/// requested and never disappears again, whenever the producer applies it
/// (a flag cleared when `process` starts, but published only when it ends,
/// would let a reader in between see the old readings come back).
final class ResetRequests: Sendable {
  private let peaks = Atomic<UInt64>(0)
  private let loudness = Atomic<UInt64>(0)
  private let all = Atomic<UInt64>(0)

  func requestPeaks() { peaks.add(1, ordering: .releasing) }
  func requestLoudness() { loudness.add(1, ordering: .releasing) }
  func requestAll() { all.add(1, ordering: .releasing) }

  /// Any thread. Generations only grow, so after reading a publish this is
  /// never behind the generations that publish carries.
  func load() -> ResetGenerations {
    ResetGenerations(
      peaks: peaks.load(ordering: .acquiring), loudness: loudness.load(ordering: .acquiring),
      all: all.load(ordering: .acquiring))
  }
}

/// A meter's published value: its readings and the resets they include.
struct Published<Readings: BitwiseCopyable>: BitwiseCopyable {
  var readings: Readings
  var resets = ResetGenerations()
}
