import Foundation

/// Raw pixel layouts used by packed 4:2:2 and adjacent RGB inputs, without a
/// Core Video format declaration.  The descriptor is deliberately free of
/// GPU types: it is shared by capture admission and the packing kernels.
enum Packed422Format: String, CaseIterable, Sendable {
  case twoVuy = "2vuy"       // U Y0 V Y1
  case yuvs = "yuvs"          // Y0 U Y1 V
  case r210 = "r210"          // big-endian 2:10:10:10 RGB word
  case r12L = "R12L"          // packed little-endian 12-bit RGB components
  case uyva = "UYVA"          // UYVY image followed by a separate alpha plane
  case p216 = "P216"          // 16-bit luma/chroma planes

  var bitsPerComponent: Int { self == .r12L ? 12 : (self == .r210 ? 10 : (self == .p216 ? 16 : 8)) }
  var isPlanar: Bool { self == .p216 }
  var pixelsPerGroup: Int { self == .p216 || self == .r210 ? 1 : 2 }
  var bytesPerGroup: Int {
    switch self { case .twoVuy, .yuvs: 4; case .r210: 4; case .r12L: 9; case .uyva: 4; case .p216: 2 }
  }

  /// Minimum bytes in one physical row, with overflow checked.
  func minimumRowBytes(width: Int) throws -> Int {
    guard width > 0 else { throw Packed422AdmissionError.invalidDimensions }
    if self == .r210 || self == .p216 {
      let (bytes, overflow) = width.multipliedReportingOverflow(by: self == .r210 ? 4 : 2)
      guard !overflow else { throw Packed422AdmissionError.overflow }
      return bytes
    }
    if self == .r12L {
      let (bits, overflow) = width.multipliedReportingOverflow(by: 36)
      guard !overflow else { throw Packed422AdmissionError.overflow }
      return bits / 8 + (bits.isMultiple(of: 8) ? 0 : 1)
    }
    let groups = (width / 2) + (width.isMultiple(of: 2) ? 0 : 1)
    let (bytes, overflow) = groups.multipliedReportingOverflow(by: bytesPerGroup)
    guard !overflow, bytes > 0 else { throw Packed422AdmissionError.overflow }
    return bytes
  }

  func validate(width: Int, height: Int, rowBytes: Int, dataSize: Int = 0, planeCount: Int = 0, alphaRowBytes: Int? = nil) throws {
    guard width > 0, height > 0 else { throw Packed422AdmissionError.invalidDimensions }
    let minimum = try minimumRowBytes(width: width)
    guard rowBytes >= minimum, rowBytes.isMultiple(of: isPlanar ? 2 : 1) else { throw Packed422AdmissionError.invalidStride(minimum: minimum) }
    let (length, overflow) = rowBytes.multipliedReportingOverflow(by: height)
    guard !overflow, length > 0 else { throw Packed422AdmissionError.overflow }
    var required = length
    if self == .p216 {
      let (total, totalOverflow) = length.multipliedReportingOverflow(by: 2)
      guard !totalOverflow else { throw Packed422AdmissionError.overflow }
      required = total
    }
    if self == .uyva {
      guard let alphaRowBytes, alphaRowBytes >= width else { throw Packed422AdmissionError.invalidStride(minimum: width) }
      let (alphaBytes, alphaOverflow) = alphaRowBytes.multipliedReportingOverflow(by: height)
      let (total, totalOverflow) = length.addingReportingOverflow(alphaBytes)
      guard !alphaOverflow, !totalOverflow else { throw Packed422AdmissionError.overflow }
      required = total
    }
    guard dataSize >= 0, dataSize == 0 || required <= dataSize else { throw Packed422AdmissionError.allocationTooSmall }
    guard planeCount == (isPlanar ? 2 : 0) else { throw Packed422AdmissionError.invalidPlaneCount }
  }
}

enum Packed422AdmissionError: Error, Equatable, Sendable {
  case invalidDimensions, overflow, invalidStride(minimum: Int), allocationTooSmall, invalidPlaneCount
}
