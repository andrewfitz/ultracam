import Foundation

/// NDI storage planes. PA16's third full-resolution plane is alpha; v1 LUT
/// output ignores alpha, but raw ingest must retain and validate its storage.
enum NDIPlanarLayout: Sendable {
  case i420, pa16
  var pixelFormat: UInt32 { self == .i420 ? 0x49343230 : 0x50413136 }
  struct Plane: Equatable, Sendable {
    let width: Int; let height: Int; let components: Int; let componentBytes: Int; let minimumRowBytes: Int
  }
  enum LayoutError: Error { case invalidDimensions, overflow, invalidPlanes, overlappingPlanes, allocationTooSmall }
  func planes(width: Int, height: Int) throws -> [Plane] {
    guard width > 0, height > 0 else { throw LayoutError.invalidDimensions }
    let cw = width / 2 + width % 2, ch = height / 2 + height % 2
    let extents = self == .i420 ? [(width, height, 1, 1), (cw, ch, 1, 1), (cw, ch, 1, 1)] :
      [(width, height, 1, 2), (cw, height, 2, 2), (width, height, 1, 2)]
    return try extents.map { w, h, components, bytes in
      let (minimum, overflow) = w.multipliedReportingOverflow(by: components * bytes)
      guard !overflow, minimum > 0 else { throw LayoutError.overflow }
      return Plane(width: w, height: h, components: components, componentBytes: bytes, minimumRowBytes: minimum)
    }
  }
  func validate(width: Int, height: Int, offsets: [Int], strides: [Int], allocationBytes: Int) throws {
    let descriptors = try planes(width: width, height: height)
    guard offsets.count == descriptors.count, strides.count == descriptors.count, allocationBytes > 0 else { throw LayoutError.invalidPlanes }
    var ranges: [Range<Int>] = []
    for index in descriptors.indices {
      let plane = descriptors[index], offset = offsets[index], stride = strides[index]
      guard offset >= 0, offset.isMultiple(of: plane.componentBytes), stride >= plane.minimumRowBytes,
        stride.isMultiple(of: plane.componentBytes) else { throw LayoutError.invalidPlanes }
      let (length, overflow) = stride.multipliedReportingOverflow(by: plane.height)
      let (end, endOverflow) = offset.addingReportingOverflow(length)
      guard !overflow, !endOverflow, length > 0 else { throw LayoutError.overflow }
      guard end <= allocationBytes else { throw LayoutError.allocationTooSmall }
      let range = offset..<end
      guard !ranges.contains(where: { $0.overlaps(range) }) else { throw LayoutError.overlappingPlanes }
      ranges.append(range)
    }
  }
}
