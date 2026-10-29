import Foundation

/// Byte budget for GPU-visible backing allocations. GPU command concurrency and
/// this budget are independent: a lease represents retained storage, not a
/// frame-in-flight slot. Plane/texture views share `backingID` and are charged
/// once until every lease is released.
public enum GPUAllocationBudgetFailure: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidPolicy, invalidAllocation, generationMismatch, overflow, minimumDoesNotFit(required: Int, limit: Int), byteLimit(required: Int, limit: Int)
  public var description: String {
    switch self {
    case .invalidPolicy: return "Invalid GPU allocation budget policy."
    case .invalidAllocation: return "Invalid GPU backing allocation."
    case .generationMismatch: return "GPU backing identity was reused across generations while still retained."
    case .overflow: return "GPU allocation size arithmetic overflow."
    case .minimumDoesNotFit(let required, let limit): return "GPU minimum retention requires \(required) bytes, exceeding the \(limit)-byte budget."
    case .byteLimit(let required, let limit): return "GPU allocation budget exceeded (\(required) > \(limit) bytes)."
    }
  }
}

public struct GPUAllocationBudgetPolicy: Hashable, Sendable {
  public let maximumBytes: Int
  public let minimumSlots: Int
  public init(maximumBytes: Int, minimumSlots: Int) throws {
    guard maximumBytes > 0, minimumSlots > 0 else { throw GPUAllocationBudgetFailure.invalidPolicy }
    self.maximumBytes = maximumBytes; self.minimumSlots = minimumSlots
  }
  public func validateMinimum(bytesPerSlot: Int) throws {
    guard bytesPerSlot > 0 else { throw GPUAllocationBudgetFailure.invalidAllocation }
    let (required, overflow) = bytesPerSlot.multipliedReportingOverflow(by: minimumSlots)
    guard !overflow else { throw GPUAllocationBudgetFailure.overflow }
    guard required <= maximumBytes else { throw GPUAllocationBudgetFailure.minimumDoesNotFit(required: required, limit: maximumBytes) }
  }
}

public final class GPUAllocationBudget: @unchecked Sendable {
  public final class Lease: @unchecked Sendable {
    private var budget: GPUAllocationBudget?
    private let key: UInt64
    private let lock = NSLock()
    private var released = false
    fileprivate init(budget: GPUAllocationBudget, key: UInt64) { self.budget = budget; self.key = key }
    public func release() {
      lock.lock(); guard !released else { lock.unlock(); return }; released = true
      let owner = budget; budget = nil; lock.unlock()
      owner?.release(key: key)
    }
    deinit { release() }
  }
  private struct Entry { var bytes: Int; var references: Int; var generation: UInt64; var owner: AnyObject? }
  public struct Snapshot: Sendable, Equatable { public let bytes: Int; public let allocations: Int; public let leases: Int; public let peakBytes: Int }
  public let policy: GPUAllocationBudgetPolicy
  private let lock = NSLock()
  private var entries: [UInt64: Entry] = [:]
  private var leaseCount = 0
  private var peak = 0
  public init(policy: GPUAllocationBudgetPolicy) { self.policy = policy }

  /// Strongly retains the backing owner (normally IOSurface), never a CVPixelBuffer.
  /// Multiple plane/texture views must pass the same backing ID.
  public func acquire(backingID: UInt64, bytes: Int, generation: UInt64, owner: AnyObject? = nil) throws -> Lease {
    guard backingID != 0, bytes > 0 else { throw GPUAllocationBudgetFailure.invalidAllocation }
    return try lock.withLock {
      if var entry = entries[backingID] {
        guard entry.bytes == bytes else { throw GPUAllocationBudgetFailure.invalidAllocation }
        guard entry.generation == generation else { throw GPUAllocationBudgetFailure.generationMismatch }
        entry.references += 1
        if entry.owner == nil, let owner { entry.owner = owner }
        entries[backingID] = entry
      } else {
        let (required, overflow) = currentBytes().addingReportingOverflow(bytes)
        guard !overflow else { throw GPUAllocationBudgetFailure.overflow }
        guard required <= policy.maximumBytes else { throw GPUAllocationBudgetFailure.byteLimit(required: required, limit: policy.maximumBytes) }
        entries[backingID] = Entry(bytes: bytes, references: 1, generation: generation, owner: owner)
        peak = max(peak, required)
      }
      leaseCount += 1
      return Lease(budget: self, key: backingID)
    }
  }
  public func snapshot() -> Snapshot { lock.withLock { Snapshot(bytes: currentBytes(), allocations: entries.count, leases: leaseCount, peakBytes: peak) } }
  private func currentBytes() -> Int {
    entries.values.reduce(0) { partial, entry in
      let (sum, overflow) = partial.addingReportingOverflow(entry.bytes)
      return overflow ? Int.max : sum
    }
  }
  private func release(key: UInt64) { lock.withLock { guard var e = entries[key] else { return }; e.references -= 1; leaseCount = max(0, leaseCount - 1); if e.references == 0 { entries.removeValue(forKey: key) } else { entries[key] = e } } }
}

public enum GPUCacheAge {
  public static func expired(lastUsed: TimeInterval, now: TimeInterval, idleAge: TimeInterval) throws -> Bool {
    guard lastUsed.isFinite, now.isFinite, idleAge.isFinite, lastUsed >= 0, now >= lastUsed, idleAge > 0 else { throw GPUAllocationBudgetFailure.invalidAllocation }
    return now - lastUsed >= idleAge
  }
}
