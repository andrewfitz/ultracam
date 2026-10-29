import XCTest

@objcMembers final class NoCopyIngestLeaseChecks: XCTestCase {
  func testUnalignedRangeRetainsAllocationAndReleasesResourcesBeforeFrame() throws {
    var events: [String] = []
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096)
    defer { raw.deallocate() }
    let allocation = NoCopyIngestAllocation(baseAddress: raw, length: 8192, generation: 7,
      retain: { events.append("allocation-retain") }, release: { events.append("allocation-release") })
    let lease = try NoCopyIngestLease(pointer: raw.advanced(by: 17), length: 100,
      allocation: allocation, vmPageSize: 4096,
      inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 7) },
      frameRelease: { events.append("frame-release") },
      onGPUResourcesReleased: { events.append("gpu-release") })
    XCTAssertEqual(lease.byteOffset, 17)
    lease.completeGPU()
    XCTAssertEqual(events, ["allocation-retain", "gpu-release", "frame-release"])
    lease.completeGPU()
    XCTAssertEqual(events.count, 3)
  }

  func testSubmitGPUKeepsLeaseUntilCompletion() throws {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { raw.deallocate() }
    let allocation = NoCopyIngestAllocation(baseAddress: raw, length: 4096, generation: 1)
    var completion: (() -> Void)?
    var released = false
    let lease = try NoCopyIngestLease(pointer: raw, length: 32, allocation: allocation, inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 1) },
      frameRelease: { released = true })
    lease.submitGPU { done in completion = done }
    XCTAssertFalse(released)
    completion?()
    XCTAssertTrue(released)
  }

  func testPointerOnlyInputIsRejected() {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    defer { raw.deallocate() }
    XCTAssertThrowsError(try NoCopyIngestLease(pointer: raw, length: 8, allocation: nil)) { error in
      XCTAssertEqual(error as? NoCopyIngestError, .missingAllocationOwnership)
    }
  }

  func testSplitVMAndGenerationMismatchAreRejected() {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096)
    defer { raw.deallocate() }
    let allocation = NoCopyIngestAllocation(baseAddress: raw, length: 8192, generation: 2)
    XCTAssertThrowsError(try NoCopyIngestLease(pointer: raw.advanced(by: 1), length: 8,
      allocation: allocation, inspectVM: { _, _ in nil })) { XCTAssertEqual($0 as? NoCopyIngestError, .splitVMRegion) }
    XCTAssertThrowsError(try NoCopyIngestLease(pointer: raw, length: 8,
      allocation: allocation, inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 3) })) { XCTAssertEqual($0 as? NoCopyIngestError, .generationMismatch) }
  }

  func testOverflowAndOutsideAllocationAreRejected() {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
    defer { raw.deallocate() }
    let allocation = NoCopyIngestAllocation(baseAddress: raw, length: 32, generation: 1)
    XCTAssertThrowsError(try NoCopyIngestLease(pointer: raw.advanced(by: 24), length: 16, allocation: allocation, inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 1) })) { XCTAssertEqual($0 as? NoCopyIngestError, .outsideAllocation) }
    XCTAssertThrowsError(try NoCopyIngestLease(pointer: UnsafeRawPointer(bitPattern: UInt.max)!, length: 2, allocation: allocation, inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 1) })) { XCTAssertEqual($0 as? NoCopyIngestError, .arithmeticOverflow) }
  }
}
