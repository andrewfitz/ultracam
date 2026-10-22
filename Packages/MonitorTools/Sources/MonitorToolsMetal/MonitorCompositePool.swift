@preconcurrency import CoreVideo
import Foundation
import IOSurface
import MonitorToolsCore

/// A bounded BGRA cache. Callers must separately charge every returned buffer's lifetime.
/// At most two geometry/reservation keys share the backing limit. LRU eviction releases
/// cache leases; outstanding buffers from retired entries remain charged by their callers.
final class MonitorCompositePool: @unchecked Sendable {
  struct Stats: Equatable, Sendable {
    var allocations = 0
    var reuses = 0
    var poolFailures = 0
    var poolCapacityBytes = 0
  }
  enum AllocationError: Error, Equatable {
    case invalidRequest
    case budgetExceeded
    case poolCreationFailed(CVReturn)
    case allocationFailed(CVReturn)
    case allocationExceedsReservation(actual: Int, reservation: Int)
  }
  private struct Key: Equatable {
    let width: Int
    let height: Int
    let reservation: Int
  }
  private final class Entry {
    let key: Key
    let pool: CVPixelBufferPool
    var surfaceLeases: [IOSurfaceID: MonitorResourceLease] = [:]
    init(key: Key, pool: CVPixelBufferPool) {
      self.key = key
      self.pool = pool
    }
  }
  private let lock = NSLock()
  private let ledger: MonitorAdmissionLedger
  private let maximumBuffers: Int
  private let cacheTarget = MonitorTargetID("composite-pool-\(UUID().uuidString)")
  // Least recently used first. Only worker allocations/trim mutate these under lock.
  private var entries: [Entry] = []
  private var stats = Stats()

  init(ledger: MonitorAdmissionLedger, maximumBuffers: Int = 8) {
    self.ledger = ledger
    self.maximumBuffers = min(8, max(1, maximumBuffers))
  }

  func allocate(width: Int, height: Int, reservation: Int) throws -> CVPixelBuffer {
    lock.lock()
    defer { lock.unlock() }
    do {
      guard width > 0, height > 0, reservation > 0 else {
        throw AllocationError.invalidRequest
      }
      let requested = Key(width: width, height: height, reservation: reservation)
      let cached: Entry?
      if let index = entries.firstIndex(where: { $0.key == requested }) {
        cached = entries.remove(at: index)
        entries.append(cached!)
      } else {
        cached = nil
        // A new geometry may retire old storage even when all its buffers are held.
        // The eight-buffer bound covers the cache, not separately charged retired frames.
        if entries.count == 2 || cachedSurfaceCount >= maximumBuffers {
          removeEntryLocked(at: 0)
        }
      }

      // Reserve before asking Core Video: it may allocate a new backing store even
      // when a previously returned buffer is eligible for reuse.
      guard let provisional = ledger.tryAcquire(
        target: cacheTarget, generation: 0, kind: .presentation, bytes: reservation)
      else { throw AllocationError.budgetExceeded }
      var retainedByCache = false
      defer { if !retainedByCache { provisional.release() } }

      let entry: Entry
      if let cached {
        entry = cached
      } else {
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
          nil,
          // No age-out: accounting and IOSurface identities stay valid until trim.
          [kCVPixelBufferPoolMaximumBufferAgeKey: 0] as CFDictionary,
          [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
          ] as CFDictionary,
          &created)
        guard status == kCVReturnSuccess, let created else {
          throw AllocationError.poolCreationFailed(status)
        }
        entry = Entry(key: requested, pool: created)
        entries.append(entry)
      }
      // Each Core Video pool must account for backings retained by the other key.
      // Existing entries never evict/recreate merely because their buffers are held.
      let otherSurfaces = entries.reduce(0) {
        $0 + ($1 === entry ? 0 : $1.surfaceLeases.count)
      }
      let threshold = maximumBuffers - otherSurfaces
      var buffer: CVPixelBuffer?
      let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        nil, entry.pool, [kCVPixelBufferPoolAllocationThresholdKey: threshold] as CFDictionary,
        &buffer)
      guard status == kCVReturnSuccess, let buffer else {
        if entry.surfaceLeases.isEmpty { removeEntryLocked(entry) }
        throw AllocationError.allocationFailed(status)
      }
      let actual = CVPixelBufferGetDataSize(buffer)
      guard actual <= reservation else {
        // Discard the offending cache; otherwise its retained storage would exceed
        // the reservation even though this buffer is never delivered.
        removeEntryLocked(entry)
        throw AllocationError.allocationExceedsReservation(actual: actual, reservation: reservation)
      }
      guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
        removeEntryLocked(entry)
        throw AllocationError.allocationFailed(kCVReturnInvalidPixelBufferAttributes)
      }
      let identifier = IOSurfaceGetID(surface)
      if entry.surfaceLeases[identifier] == nil {
        entry.surfaceLeases[identifier] = provisional
        retainedByCache = true
        stats.poolCapacityBytes += reservation
        stats.allocations += 1
      } else {
        stats.reuses += 1
      }
      return buffer
    } catch {
      stats.poolFailures += 1
      throw error
    }
  }

  func trim() {
    lock.lock()
    defer { lock.unlock() }
    trimLocked()
  }

  func statsSnapshot() -> Stats {
    lock.lock()
    defer { lock.unlock() }
    return stats
  }

  private func trimLocked() {
    entries.removeAll()
    stats.poolCapacityBytes = 0
  }

  private var cachedSurfaceCount: Int {
    entries.reduce(0) { $0 + $1.surfaceLeases.count }
  }

  private func removeEntryLocked(_ entry: Entry) {
    if let index = entries.firstIndex(where: { $0 === entry }) {
      removeEntryLocked(at: index)
    }
  }

  private func removeEntryLocked(at index: Int) {
    stats.poolCapacityBytes -= entries[index].surfaceLeases.count * entries[index].key.reservation
    entries.remove(at: index)
  }

  deinit { trim() }
}
