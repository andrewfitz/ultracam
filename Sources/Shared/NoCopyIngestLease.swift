import Foundation

/// A retained SDK allocation that may be wrapped by a no-copy GPU buffer.
public final class NoCopyIngestAllocation: @unchecked Sendable {
  public let baseAddress: UInt
  public let length: Int
  public let generation: UInt64
  private let releaseBody: () -> Void

  public init(baseAddress: UnsafeRawPointer, length: Int, generation: UInt64,
              retain: () -> Void = {}, release: @escaping () -> Void = {}) {
    self.baseAddress = UInt(bitPattern: baseAddress)
    self.length = length
    self.generation = generation
    self.releaseBody = release
    retain()
  }

  deinit { releaseBody() }
}

public enum NoCopyIngestError: Error, Equatable {
  case missingAllocationOwnership
  case invalidLength
  case unsupportedPixelFormat
  case arithmeticOverflow
  case outsideAllocation
  case roundedRangeOutsideAllocation
  case splitVMRegion
  case generationMismatch
  case invalidVMPageSize
}

/// VM-region evidence supplied by the allocator/SDK boundary. The default
/// implementation is conservative: callers must provide ownership evidence.
public struct NoCopyVMRange: Equatable, Sendable {
  public let baseAddress: UInt
  public let length: Int
  public let generation: UInt64
  public init(baseAddress: UInt, length: Int, generation: UInt64) {
    self.baseAddress = baseAddress; self.length = length; self.generation = generation
  }
}

public typealias NoCopyVMInspector = (_ roundedBase: UInt, _ roundedLength: Int) -> NoCopyVMRange?

/// Owns a vendor frame lease and its no-copy allocation until GPU completion.
/// The GPU buffer/residency wrapper must be discarded before `completeGPU`
/// releases the frame lease; `onGPUResourcesReleased` is the ordering hook.
public final class NoCopyIngestLease: @unchecked Sendable {
  public let allocation: NoCopyIngestAllocation
  public let byteOffset: Int
  public let byteLength: Int
  public let roundedBaseAddress: UInt
  public let roundedLength: Int
  public let pixelOffset: Int
  private let lock = NSLock()
  private var callbacks: (frameRelease: () -> Void, onGPUResourcesReleased: () -> Void)?
  private var submitted = false

  public init(pointer: UnsafeRawPointer, length: Int,
              allocation: NoCopyIngestAllocation?, vmPageSize: Int = Int(getpagesize()),
              inspectVM: NoCopyVMInspector? = nil,
              frameRelease: @escaping () -> Void = {},
              onGPUResourcesReleased: @escaping () -> Void = {}) throws {
    guard let allocation else { throw NoCopyIngestError.missingAllocationOwnership }
    guard length > 0, allocation.length > 0 else { throw NoCopyIngestError.invalidLength }
    guard vmPageSize > 0, vmPageSize.nonzeroBitCount == 1 else { throw NoCopyIngestError.invalidVMPageSize }
    let start = UInt(bitPattern: pointer)
    let endResult = start.addingReportingOverflow(UInt(length))
    guard !endResult.overflow else { throw NoCopyIngestError.arithmeticOverflow }
    let end = endResult.partialValue
    let allocEndResult = allocation.baseAddress.addingReportingOverflow(UInt(allocation.length))
    guard !allocEndResult.overflow else { throw NoCopyIngestError.arithmeticOverflow }
    guard start >= allocation.baseAddress, end <= allocEndResult.partialValue else { throw NoCopyIngestError.outsideAllocation }
    let roundedBase = start - (start % UInt(vmPageSize))
    let roundedEndResult = end.addingReportingOverflow(UInt(vmPageSize - 1))
    guard !roundedEndResult.overflow else { throw NoCopyIngestError.arithmeticOverflow }
    let roundedEnd = roundedEndResult.partialValue - (roundedEndResult.partialValue % UInt(vmPageSize))
    guard roundedEnd >= roundedBase, roundedEnd - roundedBase <= UInt(Int.max) else { throw NoCopyIngestError.arithmeticOverflow }
    guard roundedBase >= allocation.baseAddress, roundedEnd <= allocEndResult.partialValue else { throw NoCopyIngestError.roundedRangeOutsideAllocation }
    let roundedLength = Int(roundedEnd - roundedBase)
    guard let inspectVM else { throw NoCopyIngestError.splitVMRegion }
    do {
      guard let region = inspectVM(roundedBase, roundedLength) else { throw NoCopyIngestError.splitVMRegion }
      // An inspector may return the whole VM region containing a frame slice.
      guard region.baseAddress <= roundedBase, region.length > 0 else { throw NoCopyIngestError.splitVMRegion }
      let regionEnd = region.baseAddress.addingReportingOverflow(UInt(region.length))
      guard !regionEnd.overflow, roundedEnd <= regionEnd.partialValue else { throw NoCopyIngestError.splitVMRegion }
      guard region.generation == allocation.generation else { throw NoCopyIngestError.generationMismatch }
    }
    self.roundedBaseAddress = roundedBase
    self.roundedLength = roundedLength
    self.pixelOffset = Int(start - roundedBase)
    self.allocation = allocation
    self.byteOffset = Int(start - allocation.baseAddress)
    self.byteLength = length
    self.callbacks = (frameRelease, onGPUResourcesReleased)
  }

  /// Hands this lease to an asynchronous GPU submission. The submitter must
  /// invoke the completion callback exactly once after its buffer/residency
  /// wrapper is retired. Only the first submission is accepted.
  public func submitGPU(_ submit: (@escaping () -> Void) -> Void) {
    lock.lock()
    let alreadyCompleted = callbacks == nil || submitted
    if !alreadyCompleted { submitted = true }
    lock.unlock()
    guard !alreadyCompleted else { return }
    submit { [self] in completeGPU() }
  }

  public func completeGPU() {
    let completedCallbacks = lock.withLock {
      let pending = callbacks
      callbacks = nil
      return pending
    }
    completedCallbacks?.onGPUResourcesReleased()
    completedCallbacks?.frameRelease()
    // Allocation lifetime belongs to its shared owner, not one frame.
    // Other in-flight frames may reference the same SDK allocation.
  }

  deinit { completeGPU() }
}
