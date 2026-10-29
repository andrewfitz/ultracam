import XCTest

@objcMembers final class NoCopyGPUIngestChecks: XCTestCase {
  func testCompletionOwnsLeaseAfterProducerDropsReference() throws {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096)
    defer { raw.deallocate() }
    var released = false
    var completion: (() -> Void)?
    var lease: NoCopyIngestLease? = try NoCopyIngestLease(pointer: raw, length: 32,
      allocation: NoCopyIngestAllocation(baseAddress: raw, length: 8192, generation: 1),
      inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 1) },
      frameRelease: { released = true })
    lease!.submitGPU { completion = $0 }
    lease = nil
    XCTAssertFalse(released)
    completion?()
    XCTAssertTrue(released)
  }

  func testInvalidAllocationLengthsRefuseWithoutTrapping() {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { raw.deallocate() }
    for length in [-1, 0] {
      XCTAssertThrowsError(try NoCopyIngestLease(pointer: raw, length: 4,
        allocation: NoCopyIngestAllocation(baseAddress: raw, length: length, generation: 1))) {
        XCTAssertEqual($0 as? NoCopyIngestError, .invalidLength)
      }
    }
  }

  func testCompletingOneFrameDoesNotUnpinSharedAllocation() throws {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { raw.deallocate() }
    var releases = 0
    var allocation: NoCopyIngestAllocation? = NoCopyIngestAllocation(baseAddress: raw, length: 4096,
      generation: 1, release: { releases += 1 })
    var first: NoCopyIngestLease? = try NoCopyIngestLease(pointer: raw, length: 4,
      allocation: allocation, inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 1) })
    var second: NoCopyIngestLease? = try NoCopyIngestLease(pointer: raw, length: 4,
      allocation: allocation, inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 1) })
    allocation = nil
    first?.completeGPU(); first = nil
    XCTAssertEqual(releases, 0)
    second?.completeGPU(); second = nil
    XCTAssertEqual(releases, 1)
  }

  func testRoundedRangeMustRemainInsideOwnedAllocation() {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096)
    defer { raw.deallocate() }
    XCTAssertThrowsError(try NoCopyIngestLease(pointer: raw.advanced(by: 17), length: 32,
      allocation: NoCopyIngestAllocation(baseAddress: raw.advanced(by: 17), length: 32, generation: 1),
      inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 1) }))
  }
}
