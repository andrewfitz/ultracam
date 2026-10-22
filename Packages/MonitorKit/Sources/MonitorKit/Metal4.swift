import Metal
import Synchronization

/// A host Metal 4 command buffer that MonitorKit encodes into, and how far the
/// GPU has got. Build one per command buffer (it allocates nothing).
///
/// Indices count the host's submissions on the one `MTL4CommandQueue` that
/// carries all of an engine's work: every encode into one command buffer
/// shares its `index`, and a later commit has a larger one. `completedIndex`
/// is the highest index whose work (and every earlier one's) has completed or
/// was abandoned. The library never commits, waits or adds handlers; it uses
/// the two indices to reuse uniform slots only once the GPU is done with them
/// and to release replaced resources only after their last use completed.
public struct MonitorSubmission {
  public var commandBuffer: any MTL4CommandBuffer
  /// This submission's index, ≥ 1.
  public var index: UInt64
  /// Submissions up to and including this index have completed (0: none known).
  public var completedIndex: UInt64
  /// Host transient uniforms, e.g. a bump allocator in its encode context. Nil
  /// uses the library's own rings (`MonitorEngine.framesInFlight` slots each).
  public var uniforms: (any MonitorUniformAllocator)?

  /// `index` must be ≥ 1: 0 is how the library marks "never used" and how
  /// `completedIndex` says "none completed", so a 0-based counter would let the
  /// first submission's uniforms and resources be reused while it runs.
  public init(
    commandBuffer: any MTL4CommandBuffer, index: UInt64, completedIndex: UInt64,
    uniforms: (any MonitorUniformAllocator)? = nil
  ) {
    precondition(index >= 1, "MonitorSubmission indices start at 1 (0 means none)")
    self.commandBuffer = commandBuffer
    self.index = index
    self.completedIndex = min(completedIndex, index &- 1)
    self.uniforms = uniforms
  }

  /// For a host that never has more than `framesInFlight` submissions on the GPU
  /// (this one included): it waits for submission `index - framesInFlight` before
  /// encoding `index`, e.g. with a semaphore.
  public init(
    commandBuffer: any MTL4CommandBuffer, index: UInt64, framesInFlight: Int,
    uniforms: (any MonitorUniformAllocator)? = nil
  ) {
    let inFlight = UInt64(max(1, framesInFlight))
    self.init(
      commandBuffer: commandBuffer, index: index, completedIndex: index > inFlight ? index - inFlight : 0,
      uniforms: uniforms)
  }
}

/// CPU-written memory the GPU reads in one submission.
public struct MonitorUniformAllocation {
  public var contents: UnsafeMutableRawPointer
  public var gpuAddress: MTLGPUAddress

  public init(contents: UnsafeMutableRawPointer, gpuAddress: MTLGPUAddress) {
    self.contents = contents
    self.gpuAddress = gpuAddress
  }
}

/// A host's transient uniform allocator (Metal 4 has no `set*Bytes`).
public protocol MonitorUniformAllocator: AnyObject {
  /// `length` bytes, 256-byte aligned, resident on the submission's queue and
  /// valid until the submission completes. A picture asks for
  /// `MonitorPass.uniformLength` bytes per encode, an analysis for
  /// `MonitorFeed.uniformLength`.
  func allocateUniforms(length: Int) -> MonitorUniformAllocation
}

/// The residency set holding every allocation MonitorKit owns or reads on the
/// host's behalf (placeholders, focus masks, Freeze planes, uniform rings and the
/// feeds' LUT textures), plus deferred release: Metal 4 retains nothing, so a
/// replaced resource stays alive and resident until the submission that last
/// could have used it completes.
///
/// Attach `set` to the host's `MTL4CommandQueue` once. Allocations are added
/// when created or first used and committed then, never per frame. Host-owned
/// frame and target textures stay the host's responsibility
/// (`MonitorFrame.addResidency(to:)` helps). Thread-safe.
public final class MonitorResidency: @unchecked Sendable {
  public let set: MTLResidencySet

  /// Only touched under `state`'s lock.
  private struct Retired: @unchecked Sendable {
    var object: AnyObject?
    var allocation: (any MTLAllocation)?
    var after: UInt64
  }

  private struct State: @unchecked Sendable {
    var counts: [ObjectIdentifier: Int] = [:]
    var retired: [Retired] = []
  }

  private let state = Mutex(State())
  private let latest = Atomic<UInt64>(0)
  private let completed = Atomic<UInt64>(0)
  private let pending = Atomic<Int>(0)
  private let commits = Atomic<Int>(0)

  public init(device: MTLDevice, label: String = "MonitorKit") throws {
    let d = MTLResidencySetDescriptor()
    d.label = label
    d.initialCapacity = 32
    set = try device.makeResidencySet(descriptor: d)
  }

  /// Adds `allocation` and commits. Counted: an allocation added n times leaves
  /// the set after n releases, so a LUT shared by two feeds stays resident.
  public func add(_ allocation: any MTLAllocation) {
    state.withLock { s in
      let id = ObjectIdentifier(allocation)
      let n = s.counts[id, default: 0]
      s.counts[id] = n + 1
      if n == 0 {
        set.addAllocation(allocation)
        set.commit()
        commits.add(1, ordering: .relaxed)
      }
    }
  }

  /// Keeps `object` alive, and drops one count of `allocation` from the set, once
  /// every submission up to `after` (default: the latest one observed) has completed.
  public func retire(_ object: AnyObject?, resident allocation: (any MTLAllocation)?, after: UInt64? = nil) {
    guard object != nil || allocation != nil else { return }
    // Sequentially consistent with `observe` and with a released flag stored before
    // this call (`MonitorFrame.keepResidentIfReleased`): an encode that misses the
    // flag has its submission covered by this tag.
    let tag = after ?? latest.load(ordering: .sequentiallyConsistent)
    state.withLock { $0.retired.append(Retired(object: object, allocation: allocation, after: tag)) }
    pending.add(1, ordering: .relaxed)
    release(through: completed.load(ordering: .acquiring))
  }

  /// Records a submission (called by every Metal 4 encode) and releases what has completed.
  public func observe(_ submission: MonitorSubmission) {
    precondition(submission.index >= 1, "MonitorSubmission indices start at 1 (0 means none)")
    Self.raise(latest, to: submission.index)
    if Self.raise(completed, to: submission.completedIndex), pending.load(ordering: .relaxed) > 0 {
      release(through: submission.completedIndex)
    }
  }

  /// Releases everything retired after submissions up to `completedIndex`, which have completed.
  public func release(through completedIndex: UInt64) {
    Self.raise(completed, to: completedIndex)
    guard pending.load(ordering: .relaxed) > 0 else { return }
    let done = completed.load(ordering: .acquiring)
    // Objects are dropped outside the lock: a deinit may retire again.
    var dropped: [AnyObject] = []
    state.withLock { s in
      var removed = false
      var i = 0
      while i < s.retired.count {
        let r = s.retired[i]
        if r.after <= done {
          if let a = r.allocation {
            let id = ObjectIdentifier(a)
            let n = s.counts[id, default: 1] - 1
            if n <= 0 {
              s.counts[id] = nil
              set.removeAllocation(a)
              removed = true
            } else {
              s.counts[id] = n
            }
          }
          if let o = r.object { dropped.append(o) }
          s.retired.swapAt(i, s.retired.count - 1)
          s.retired.removeLast()
          pending.subtract(1, ordering: .relaxed)
        } else {
          i += 1
        }
      }
      if removed {
        set.commit()
        commits.add(1, ordering: .relaxed)
      }
    }
    dropped.removeAll()
  }

  /// The highest submission index observed.
  public var latestSubmission: UInt64 { latest.load(ordering: .acquiring) }
  /// The highest completed index observed.
  public var completedSubmission: UInt64 { completed.load(ordering: .acquiring) }
  /// Retired resources still waiting for their submissions to complete.
  public var pendingReleaseCount: Int { pending.load(ordering: .relaxed) }
  /// Residency commits so far: only when an allocation joins or leaves the set.
  public var commitCount: Int { commits.load(ordering: .relaxed) }

  public func contains(_ allocation: any MTLAllocation) -> Bool { set.containsAllocation(allocation) }

  /// Raises `atomic` to `value`; true when it moved.
  @discardableResult
  private static func raise(_ atomic: borrowing Atomic<UInt64>, to value: UInt64) -> Bool {
    var current = atomic.load(ordering: .sequentiallyConsistent)
    while value > current {
      let (exchanged, original) = atomic.compareExchange(
        expected: current, desired: value, ordering: .sequentiallyConsistent)
      if exchanged { return true }
      current = original
    }
    return false
  }
}

/// Uniform slots the CPU writes and the GPU reads, in one shared buffer created
/// on first use. A slot is rewritten only when the parameters change, and only
/// once the submission that last read it has completed, so the GPU never reads
/// a half-written slot. In steady state every encode binds the same slot and
/// writes nothing. Should a host keep more submissions in flight than there are
/// slots, the ring doubles (the old buffer is retired, not freed).
public struct MonitorUniformRing: ~Copyable {
  /// Bytes per slot, a multiple of 256.
  public let slotLength: Int
  public private(set) var buffer: MTLBuffer?
  /// Slots written so far, for tests: constant in steady state.
  public private(set) var writes = 0
  private var lastUse: [UInt64] = []
  /// The parameter generation each slot holds.
  private var held: [UInt64] = []
  private var current = -1
  private let label: String

  public init(slotLength: Int, label: String) {
    self.slotLength = (max(1, slotLength) + 255) / 256 * 256
    self.label = label
  }

  public var slots: Int { lastUse.count }

  /// The slot `submission` reads, holding parameters `generation` (any value
  /// that changes whenever they do). `contents` is non-nil when the caller must
  /// write the parameters there before the GPU runs. The buffer is created on
  /// first use with `initialSlots` slots and added to `residency`.
  public mutating func slot(
    for submission: MonitorSubmission, generation: UInt64, device: MTLDevice, residency: MonitorResidency,
    initialSlots: Int = 3
  ) throws -> (contents: UnsafeMutableRawPointer?, address: MTLGPUAddress) {
    if buffer == nil { try grow(device, residency, slots: initialSlots) }
    if current >= 0, held[current] == generation {
      lastUse[current] = max(lastUse[current], submission.index)
      return (nil, address(current))
    }
    var chosen = -1
    if current >= 0, lastUse[current] <= submission.completedIndex {
      chosen = current
    } else {
      var i = 0
      while i < lastUse.count {
        if lastUse[i] <= submission.completedIndex {
          chosen = i
          break
        }
        i += 1
      }
    }
    if chosen < 0 {
      chosen = lastUse.count
      try grow(device, residency, slots: lastUse.count * 2)
    }
    current = chosen
    lastUse[chosen] = submission.index
    held[chosen] = generation
    writes += 1
    return (buffer!.contents().advanced(by: chosen * slotLength), address(chosen))
  }

  private func address(_ slot: Int) -> MTLGPUAddress { buffer!.gpuAddress + UInt64(slot * slotLength) }

  /// `slot(for:generation:device:residency:)` with the engine's device, residency
  /// and `framesInFlight`; a new buffer counts in `resourcesCreated`.
  mutating func slot(
    for submission: MonitorSubmission, generation: UInt64, engine: MonitorEngine
  ) throws -> (contents: UnsafeMutableRawPointer?, address: MTLGPUAddress) {
    let before = buffer
    let slot = try self.slot(
      for: submission, generation: generation, device: engine.device, residency: engine.residency,
      initialSlots: engine.framesInFlight)
    if buffer !== before { engine.noteCreated() }
    return slot
  }

  /// A new shared, write-combined buffer of `slots` slots (the CPU only writes
  /// it); the old one is retired with its last use.
  private mutating func grow(_ device: MTLDevice, _ residency: MonitorResidency, slots: Int) throws {
    let length = max(1, slots) * slotLength
    guard let next = device.makeBuffer(length: length, options: [.storageModeShared, .cpuCacheModeWriteCombined])
    else { throw MonitorKitError.gpu("Cannot allocate a \(length)-byte uniform ring.") }
    next.label = label
    residency.add(next)
    if let old = buffer {
      var last: UInt64 = 0, i = 0
      while i < lastUse.count {
        last = max(last, lastUse[i])
        i += 1
      }
      residency.retire(old, resident: old, after: last)
    }
    buffer = next
    // Every slot starts free; generations are invalid until written.
    lastUse = [UInt64](repeating: 0, count: max(1, slots))
    held = [UInt64](repeating: .max, count: max(1, slots))
    current = -1
  }

  /// Hands the buffer to `residency` until its last submission completes.
  public mutating func retire(to residency: MonitorResidency) {
    guard let old = buffer else { return }
    var last: UInt64 = 0, i = 0
    while i < lastUse.count {
      last = max(last, lastUse[i])
      i += 1
    }
    residency.retire(old, resident: old, after: last)
    buffer = nil
    lastUse = []
    held = []
    current = -1
  }
}

/// Copies `value` into uniform memory at `offset`.
@inline(__always)
func store<T>(_ value: T, _ base: UnsafeMutableRawPointer, _ offset: Int) {
  withUnsafeBytes(of: value) { base.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
}

@inline(__always)
func align256(_ n: Int) -> Int { (n + 255) / 256 * 256 }
