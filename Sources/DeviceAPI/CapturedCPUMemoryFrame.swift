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
  // Plane geometry and the declared allocation range are immutable. VM evidence
  // still belongs to the instant a GPU lease is acquired.
  private let storage: Result<(layouts: [CPUMemoryPlaneLayout], length: Int), Error>

  init(pointer: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
    allocation: NoCopyIngestAllocation, inspectVM: @escaping NoCopyVMInspector,
    frameOwner: AnyObject, pixelFormat: OSType = kCVPixelFormatType_32BGRA,
    planes: [Plane]? = nil) {
    self.pointer = pointer; self.width = width; self.height = height
    self.bytesPerRow = bytesPerRow; self.pixelFormat = pixelFormat
    let planes = planes ?? [Plane(offset: 0, bytesPerRow: bytesPerRow, height: height)]
    self.planes = planes
    self.allocation = allocation; self.inspectVM = inspectVM; self.frameOwner = frameOwner
    storage = Result {
      try Self.validateStorage(pointer: pointer, width: width, height: height, bytesPerRow: bytesPerRow,
        pixelFormat: pixelFormat, planes: planes, allocation: allocation)
    }
  }

  private static func validateStorage(pointer: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
    pixelFormat: OSType, planes: [Plane], allocation: NoCopyIngestAllocation) throws -> (layouts: [CPUMemoryPlaneLayout], length: Int) {
    let layouts = try CPUMemoryPlaneLayout.planes(pixelFormat: pixelFormat, width: width, height: height)
    guard planes.count == layouts.count, planes.first?.bytesPerRow == bytesPerRow else { throw NoCopyIngestError.invalidLength }
    var previousEnd = 0
    for (plane, layout) in zip(planes, layouts) {
      guard plane.offset >= previousEnd, plane.height == layout.height,
        plane.bytesPerRow >= layout.minimumRowBytes,
        (pixelFormat == 0x5231324c || plane.bytesPerRow.isMultiple(of: layout.componentBytes)),
        (pixelFormat == 0x5231324c || plane.offset.isMultiple(of: layout.componentBytes)) else { throw NoCopyIngestError.invalidLength }
      // The stride locates each row. Both ingest paths read only the active
      // bytes in the final row, so its trailing padding need not be owned.
      let lastRow = plane.bytesPerRow.multipliedReportingOverflow(by: plane.height - 1)
      let extent = lastRow.partialValue.addingReportingOverflow(layout.minimumRowBytes)
      let end = plane.offset.addingReportingOverflow(extent.partialValue)
      guard !lastRow.overflow, !extent.overflow, !end.overflow else { throw NoCopyIngestError.arithmeticOverflow }
      previousEnd = end.partialValue
    }
    guard allocation.length > 0 else { throw NoCopyIngestError.invalidLength }
    let start = UInt(bitPattern: pointer)
    let end = start.addingReportingOverflow(UInt(previousEnd))
    let allocationEnd = allocation.baseAddress.addingReportingOverflow(UInt(allocation.length))
    guard !end.overflow, !allocationEnd.overflow else { throw NoCopyIngestError.arithmeticOverflow }
    guard start >= allocation.baseAddress, end.partialValue <= allocationEnd.partialValue else { throw NoCopyIngestError.outsideAllocation }
    return (layouts, previousEnd)
  }

  func validatedPlaneLayouts() throws -> [CPUMemoryPlaneLayout] { try storage.get().layouts }
  func validatedCPUReadableLength() throws -> Int { try storage.get().length }

  func lease() throws -> NoCopyIngestLease {
    let length = try validatedCPUReadableLength()
    let owner = frameOwner
    return try NoCopyIngestLease(pointer: pointer, length: length,
      allocation: allocation, vmPageSize: Int(getpagesize()), inspectVM: inspectVM,
      frameRelease: { withExtendedLifetime(owner) {} })
  }
}
