import Darwin
import CoreVideo
import Foundation

/// SDK allocation proof is separate from the immutable frame owner. A driver
/// pointer and nominal frame byte count alone do not establish page ownership.
struct CapturedCPUMemoryFrame: @unchecked Sendable {
  struct Plane: Sendable {
    let offset: Int
    let bytesPerRow: Int
    let height: Int
  }
  let pointer: UnsafeRawPointer
  let width: Int
  let height: Int
  let bytesPerRow: Int
  let pixelFormat: OSType
  let planes: [Plane]
  let allocation: NoCopyIngestAllocation
  let inspectVM: NoCopyVMInspector
  let frameOwner: AnyObject

  init(pointer: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
    allocation: NoCopyIngestAllocation, inspectVM: @escaping NoCopyVMInspector,
    frameOwner: AnyObject, pixelFormat: OSType = kCVPixelFormatType_32BGRA,
    planes: [Plane]? = nil) {
    self.pointer = pointer; self.width = width; self.height = height
    self.bytesPerRow = bytesPerRow; self.pixelFormat = pixelFormat
    self.planes = planes ?? [Plane(offset: 0, bytesPerRow: bytesPerRow, height: height)]
    self.allocation = allocation; self.inspectVM = inspectVM; self.frameOwner = frameOwner
  }

  func validatedPlaneLayouts() throws -> [CPUMemoryPlaneLayout] {
    let layouts = try CPUMemoryPlaneLayout.planes(pixelFormat: pixelFormat, width: width, height: height)
    guard planes.count == layouts.count, planes.first?.bytesPerRow == bytesPerRow else { throw NoCopyIngestError.invalidLength }
    var previousEnd = 0
    for (plane, layout) in zip(planes, layouts) {
      guard plane.offset >= previousEnd, plane.height == layout.height,
        plane.bytesPerRow >= layout.minimumRowBytes,
        (pixelFormat == 0x5231324c || plane.bytesPerRow.isMultiple(of: layout.componentBytes)),
        (pixelFormat == 0x5231324c || plane.offset.isMultiple(of: layout.componentBytes)) else { throw NoCopyIngestError.invalidLength }
      let extent = plane.bytesPerRow.multipliedReportingOverflow(by: plane.height)
      let end = plane.offset.addingReportingOverflow(extent.partialValue)
      guard !extent.overflow, !end.overflow else { throw NoCopyIngestError.arithmeticOverflow }
      previousEnd = end.partialValue
    }
    return layouts
  }

  func minimumRowBytes() throws -> Int {
    try CPUMemoryPlaneLayout.planes(pixelFormat: pixelFormat, width: width, height: height)[0].minimumRowBytes
  }

  /// CPU compatibility may read only this owned range; VM page rounding is
  /// separately established when requesting a no-copy GPU lease.
  func validatedCPUReadableLength() throws -> Int {
    _ = try validatedPlaneLayouts()
    let last = planes.last!
    let extent = last.bytesPerRow.multipliedReportingOverflow(by: last.height)
    let length = last.offset.addingReportingOverflow(extent.partialValue)
    guard !extent.overflow, !length.overflow else { throw NoCopyIngestError.arithmeticOverflow }
    guard allocation.length > 0 else { throw NoCopyIngestError.invalidLength }
    let start = UInt(bitPattern: pointer)
    let end = start.addingReportingOverflow(UInt(length.partialValue))
    let allocationEnd = allocation.baseAddress.addingReportingOverflow(UInt(allocation.length))
    guard !end.overflow, !allocationEnd.overflow else { throw NoCopyIngestError.arithmeticOverflow }
    guard start >= allocation.baseAddress, end.partialValue <= allocationEnd.partialValue else { throw NoCopyIngestError.outsideAllocation }
    return length.partialValue
  }

  func lease() throws -> NoCopyIngestLease {
    let length = try validatedCPUReadableLength()
    let owner = frameOwner
    return try NoCopyIngestLease(pointer: pointer, length: length,
      allocation: allocation, vmPageSize: Int(getpagesize()), inspectVM: inspectVM,
      frameRelease: { withExtendedLifetime(owner) {} })
  }
}
