import CoreMedia
import Foundation

struct CMIOQueuePlane: Sendable { let rowBytes: Int; let rows: Int }
enum CMIOQueueBudgetError: Error, Equatable { case invalidPolicy, byteLimit, slotLimit, overflow, closed }

/// Admission accounting for the fixed CMIO queue. The queue itself remains
/// owned by CMIO; this ledger only admits/rejects producer retains and never
/// releases a consumer's dequeued ownership.
final class CMIOQueueBudget: @unchecked Sendable {
  let queueSlots: Int
  let frameDuration: CMTime
  let maximumDuration: CMTime
  let maximumBytes: UInt64
  let minimumSlots: Int
  private(set) var currentBytes: UInt64 = 0
  private(set) var currentSlots = 0
  private(set) var peakBytes: UInt64 = 0
  private(set) var peakSlots = 0
  private var closed = false
  private let lock = NSLock()
  init(queueSlots: Int = 8, frameDuration: CMTime, maxBytes: UInt64, minimumSlots: Int = 0) throws {
    guard (1...64).contains(queueSlots), frameDuration.isNumeric, frameDuration.epoch == 0,
      frameDuration.value > 0, frameDuration.timescale > 0, maxBytes > 0,
      minimumSlots >= 0, minimumSlots <= queueSlots else { throw CMIOQueueBudgetError.invalidPolicy }
    self.queueSlots = queueSlots; self.frameDuration = frameDuration
    self.maximumDuration = CMTimeMultiply(frameDuration, multiplier: Int32(queueSlots))
    self.maximumBytes = maxBytes; self.minimumSlots = minimumSlots
  }
  @discardableResult func admit(bytes: UInt64) throws -> Bool {
    try lock.withLock {
      guard !closed else { throw CMIOQueueBudgetError.closed }
      guard bytes > 0 else { throw CMIOQueueBudgetError.overflow }
      guard currentSlots < queueSlots else { throw CMIOQueueBudgetError.slotLimit }
      let (sum, overflow) = currentBytes.addingReportingOverflow(bytes)
      guard !overflow, sum <= maximumBytes else { throw CMIOQueueBudgetError.byteLimit }
      currentBytes = sum; currentSlots += 1; peakBytes = max(peakBytes, sum); peakSlots = max(peakSlots, currentSlots); return true
    }
  }
  final class Lease: @unchecked Sendable {
    private weak var owner: CMIOQueueBudget?; private let bytes: UInt64; private let lock = NSLock(); private var active = true
    fileprivate init(_ owner: CMIOQueueBudget, bytes: UInt64) { self.owner = owner; self.bytes = bytes }
    func release() { lock.withLock { guard active else { return }; active = false; owner?.releaseOne(bytes: bytes) } }
    deinit { release() }
  }
  func admitLease(bytes: UInt64) throws -> Lease { _ = try admit(bytes: bytes); return Lease(self, bytes: bytes) }
  func releaseOne(bytes: UInt64) { lock.withLock { currentBytes = currentBytes >= bytes ? currentBytes - bytes : 0; currentSlots = max(0, currentSlots - 1) } }
  func closeAdmission() { lock.withLock { closed = true } }
  static func allocationBytes(planes: [CMIOQueuePlane], pixelBufferDataSize: Int, ioSurfaceAllocationSize: Int) throws -> UInt64 {
    guard !planes.isEmpty, pixelBufferDataSize >= 0, ioSurfaceAllocationSize >= 0 else { throw CMIOQueueBudgetError.invalidPolicy }
    var total: UInt64 = 0
    for plane in planes {
      guard plane.rowBytes > 0, plane.rows > 0 else { throw CMIOQueueBudgetError.invalidPolicy }
      let (bytes, overflow) = UInt64(plane.rowBytes).multipliedReportingOverflow(by: UInt64(plane.rows)); guard !overflow else { throw CMIOQueueBudgetError.overflow }
      let (sum, overflow2) = total.addingReportingOverflow(bytes); guard !overflow2 else { throw CMIOQueueBudgetError.overflow }; total = sum
    }
    total = max(total, UInt64(pixelBufferDataSize), UInt64(ioSurfaceAllocationSize)); guard total > 0 else { throw CMIOQueueBudgetError.invalidPolicy }; return total
  }
}
