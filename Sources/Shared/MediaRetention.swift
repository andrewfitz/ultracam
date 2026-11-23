import Foundation

enum MediaRetentionFailure: Error, Hashable, Sendable {
  case invalidPolicy, invalidMedia, byteLimit, durationLimit, slotLimit, invalidAllocation
}

struct MediaRetentionPolicy: Hashable, Sendable {
  let maximumBytes: Int
  let maximumDuration: Double
  let maximumSlots: Int
  let minimumSlots: Int

  init(maximumBytes: Int, maximumDuration: Double, maximumSlots: Int = .max, minimumSlots: Int = 0) throws {
    guard maximumBytes > 0, maximumDuration.isFinite, maximumDuration > 0,
      maximumSlots > 0, minimumSlots >= 0, minimumSlots <= maximumSlots else {
      throw MediaRetentionFailure.invalidPolicy
    }
    self.maximumBytes = maximumBytes
    self.maximumDuration = maximumDuration
    self.maximumSlots = maximumSlots
    self.minimumSlots = minimumSlots
  }
}

final class MediaRetentionLedger: @unchecked Sendable {
  struct Snapshot: Sendable {
    let currentSlots: Int
    let currentBytes: Int
    let currentDuration: Double
    let peakSlots: Int
    let peakBytes: Int
    let peakDuration: Double
    let accepted: UInt64
    let rejected: UInt64
    let released: UInt64
  }

  final class Lease: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: MediaRetentionLedger?
    private let bytes: Int
    private let duration: Double

    fileprivate init(ledger: MediaRetentionLedger, bytes: Int, duration: Double) {
      self.ledger = ledger; self.bytes = bytes; self.duration = duration
    }

    func release() {
      let owner = lock.withLock { let owner = ledger; ledger = nil; return owner }
      owner?.release(bytes: bytes, duration: duration)
    }

    deinit { release() }
  }

  let policy: MediaRetentionPolicy
  private let lock = NSLock()
  private var slots = 0, bytes = 0, peakSlots = 0, peakBytes = 0
  private var durationSum = 0.0, durationCorrection = 0.0, peakDuration = 0.0
  private var accepted: UInt64 = 0, rejected: UInt64 = 0, released: UInt64 = 0

  init(policy: MediaRetentionPolicy) { self.policy = policy }

  func admit(bytes candidateBytes: Int, duration candidateDuration: Double) throws -> Lease {
    try lock.withLock {
      do {
        guard candidateBytes > 0, candidateDuration.isFinite, candidateDuration > 0 else {
          throw MediaRetentionFailure.invalidMedia
        }
        let (nextBytes, overflow) = bytes.addingReportingOverflow(candidateBytes)
        guard !overflow, nextBytes <= policy.maximumBytes else { throw MediaRetentionFailure.byteLimit }
        guard slots < policy.maximumSlots else { throw MediaRetentionFailure.slotLimit }
        let (nextSum, nextCorrection) = addingDuration(candidateDuration)
        let nextDuration = nextSum + nextCorrection
        guard nextSum.isFinite, nextDuration.isFinite else { throw MediaRetentionFailure.invalidMedia }
        guard slots < policy.minimumSlots || nextDuration <= policy.maximumDuration + policy.maximumDuration.ulp * 4 else {
          throw MediaRetentionFailure.durationLimit
        }
        slots += 1; bytes = nextBytes
        durationSum = nextSum; durationCorrection = nextCorrection
        peakSlots = max(peakSlots, slots); peakBytes = max(peakBytes, bytes); peakDuration = max(peakDuration, nextDuration)
        accepted += 1
        return Lease(ledger: self, bytes: candidateBytes, duration: candidateDuration)
      } catch { rejected += 1; throw error }
    }
  }

  private func release(bytes releasedBytes: Int, duration releasedDuration: Double) {
    lock.withLock {
      slots -= 1; bytes -= releasedBytes
      if slots == 0 {
        durationSum = 0
        durationCorrection = 0
      } else {
        (durationSum, durationCorrection) = addingDuration(-releasedDuration)
      }
      released += 1
    }
  }

  private func addingDuration(_ delta: Double) -> (sum: Double, correction: Double) {
    let sum = durationSum + delta
    // Neumaier summation retains short samples even after a much longer
    // sample is released. It also keeps a full cadence window available.
    let lost = abs(durationSum) >= abs(delta)
      ? (durationSum - sum) + delta
      : (delta - sum) + durationSum
    return (sum, durationCorrection + lost)
  }

  var snapshot: Snapshot {
    lock.withLock { Snapshot(currentSlots: slots, currentBytes: bytes, currentDuration: max(0, durationSum + durationCorrection), peakSlots: peakSlots, peakBytes: peakBytes, peakDuration: peakDuration, accepted: accepted, rejected: rejected, released: released) }
  }
}

enum MediaStorageExtent {
  struct Plane: Hashable, Sendable { let rowBytes: Int; let rows: Int }

  static func allocationBytes(planes: [Plane], pixelBufferDataSize: Int, ioSurfaceAllocationSize: Int?) throws -> Int {
    guard pixelBufferDataSize >= 0, ioSurfaceAllocationSize.map({ $0 > 0 }) ?? true else { throw MediaRetentionFailure.invalidAllocation }
    var total = 0
    for plane in planes {
      guard plane.rowBytes > 0, plane.rows > 0 else { throw MediaRetentionFailure.invalidAllocation }
      let (length, productOverflow) = plane.rowBytes.multipliedReportingOverflow(by: plane.rows)
      let (sum, sumOverflow) = total.addingReportingOverflow(length)
      guard !productOverflow, !sumOverflow else { throw MediaRetentionFailure.invalidAllocation }
      total = sum
    }
    let allocation = max(total, pixelBufferDataSize, ioSurfaceAllocationSize ?? 0)
    guard allocation > 0 else { throw MediaRetentionFailure.invalidAllocation }
    return allocation
  }
}

struct MediaCachePolicy: Hashable, Sendable {
  let maximumBytes: Int
  let idleAge: Double

  init(maximumBytes: Int, idleAge: Double) throws {
    guard maximumBytes > 0, idleAge.isFinite, idleAge > 0 else { throw MediaRetentionFailure.invalidPolicy }
    self.maximumBytes = maximumBytes; self.idleAge = idleAge
  }

  func isExpired(lastUsed: Double, now: Double) throws -> Bool {
    guard lastUsed.isFinite, now.isFinite, lastUsed >= 0, now >= lastUsed else { throw MediaRetentionFailure.invalidMedia }
    return now - lastUsed >= idleAge
  }
}
