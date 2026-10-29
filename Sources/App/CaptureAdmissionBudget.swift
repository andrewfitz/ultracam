import Foundation

/// Metadata-only admission before retaining a source frame or dispatching a
/// delivery closure. The lease travels with that work until its final GPU or
/// consumer use ends. Recording has its own independent admission contract.
final class CaptureAdmissionBudget: @unchecked Sendable {
  struct Snapshot: Sendable {
    let currentSlots: Int
    let currentBytes: Int
    let currentDuration: Double
    let peakSlots: Int
    let peakBytes: Int
    let accepted: Int
    let rejected: Int
    let released: Int
  }
  final class Lease: Sendable {
    private let budget: CaptureAdmissionBudget
    private let bytes: Int
    private let duration: Double
    fileprivate init(budget: CaptureAdmissionBudget, bytes: Int, duration: Double) {
      self.budget = budget
      self.bytes = bytes
      self.duration = duration
    }
    deinit { budget.release(bytes: bytes, duration: duration) }
  }
  private let lock = NSLock()
  private let maximumSlots: Int
  private let maximumBytes: Int
  private let maximumDuration: Double
  private let minimumSlots: Int
  private var slots = 0
  private var bytes = 0
  private var duration = 0.0
  private var peakSlots = 0
  private var peakBytes = 0
  private var accepted = 0
  private var rejected = 0
  private var released = 0

  init(maximumSlots: Int, maximumBytes: Int, maximumDuration: Double, minimumSlots: Int) {
    precondition(maximumSlots > 0 && maximumBytes > 0 && maximumDuration.isFinite && maximumDuration > 0)
    precondition(minimumSlots > 0 && minimumSlots <= maximumSlots)
    self.maximumSlots = maximumSlots
    self.maximumBytes = maximumBytes
    self.maximumDuration = maximumDuration
    self.minimumSlots = minimumSlots
  }
  func admit(bytes candidateBytes: Int, duration candidateDuration: Double) -> Lease? {
    lock.withLock {
      let (nextBytes, overflow) = bytes.addingReportingOverflow(candidateBytes)
      let nextDuration = duration + candidateDuration
      guard candidateBytes > 0, candidateDuration.isFinite, candidateDuration > 0,
        !overflow, nextBytes <= maximumBytes, slots < maximumSlots, nextDuration.isFinite,
        slots < minimumSlots || nextDuration <= maximumDuration + maximumDuration.ulp * 4 else {
        rejected += 1
        return nil
      }
      slots += 1
      bytes = nextBytes
      duration = nextDuration
      peakSlots = max(peakSlots, slots)
      peakBytes = max(peakBytes, bytes)
      accepted += 1
      return Lease(budget: self, bytes: candidateBytes, duration: candidateDuration)
    }
  }
  private func release(bytes releasedBytes: Int, duration releasedDuration: Double) {
    lock.withLock {
      slots -= 1
      bytes -= releasedBytes
      duration = max(0, duration - releasedDuration)
      released += 1
      if slots == 0 { duration = 0 }
    }
  }
  var snapshot: Snapshot {
    lock.withLock {
      Snapshot(currentSlots: slots, currentBytes: bytes, currentDuration: duration,
        peakSlots: peakSlots, peakBytes: peakBytes, accepted: accepted, rejected: rejected, released: released)
    }
  }
}
