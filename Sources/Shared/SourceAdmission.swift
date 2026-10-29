import CoreMedia
import CoreVideo
import Foundation

enum SourceAdmissionStage: String, Sendable { case capture; case recordingSource = "recording source"; case lut }
struct SourceAdmissionRefusal: Error, CustomStringConvertible, Sendable {
  let stage: SourceAdmissionStage
  let formatDescription: String
  let reason: String
  var description: String { "\(stage.rawValue) refused \(formatDescription): \(reason)." }
}
struct SourceAdmissionMetadata: Sendable {
  var width: Int
  var height: Int
  var pixel: PixelFormatID
  var isPlanar: Bool
  var planeCount: Int
  var rowBytes: Int
  var dataSize: Int
  var presentationTime: CMTime
  var duration: CMTime
  var epochID: CaptureEpochID
  var formatSignature: String
  var planes: [VideoBufferLayout.Plane] = []
}
extension SourceAdmissionMetadata {
  init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime, epochID: CaptureEpochID, formatSignature: String) {
    self.init(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), pixel: PixelFormatID(rawValue: CVPixelBufferGetPixelFormatType(pixelBuffer)), isPlanar: CVPixelBufferIsPlanar(pixelBuffer), planeCount: CVPixelBufferGetPlaneCount(pixelBuffer), rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer), dataSize: CVPixelBufferGetDataSize(pixelBuffer), presentationTime: presentationTime, duration: duration, epochID: epochID, formatSignature: formatSignature,
      planes: (0..<CVPixelBufferGetPlaneCount(pixelBuffer)).map {
        VideoBufferLayout.Plane(width: CVPixelBufferGetWidthOfPlane(pixelBuffer, $0),
          height: CVPixelBufferGetHeightOfPlane(pixelBuffer, $0), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, $0))
      })
  }
}

// Immutable per-epoch value. Queued/GPU work retains this snapshot rather than
// borrowing the controller's latest declaration after asynchronous completion.
struct SourceAdmissionSnapshot: Sendable {
  let format: SourceFormat
  let epochID: CaptureEpochID
  let clockBindings: CaptureClockBindings
  let entry: PixelFormatTable.Entry
  let sourceSize: SourceSize
  var formatSignature: String { format.signature }

  init(format: SourceFormat, epochID: CaptureEpochID, clockBindings: CaptureClockBindings, stage: SourceAdmissionStage) throws {
    func refuse(_ reason: String) -> SourceAdmissionRefusal { Self.refusal(format, stage, reason) }
    let sourceSize: SourceSize
    do { try format.validate(); sourceSize = try SourceSizeAdmission.validate(format) }
    catch { throw refuse("invalid source size or declaration: \(error)") }
    guard format.scan == .progressive else { throw refuse("\(format.scan.rawValue) scan has no supported capture route") }
    guard let entry = PixelFormatTable.entry(for: format.pixel) else { throw refuse("pixel format has no registered descriptor") }
    try Self.validateRoute(entry: entry, format: format, stage: stage)
    self.format = format; self.epochID = epochID; self.clockBindings = clockBindings; self.entry = entry
    self.sourceSize = sourceSize
  }

  // Run before retention-budget admission, so malformed input is reported as a
  // contract failure rather than capacity loss. No CPU pixel access occurs.
  func validate(_ metadata: SourceAdmissionMetadata, stage: SourceAdmissionStage) throws {
    func refuse(_ reason: String) -> SourceAdmissionRefusal { Self.refusal(format, stage, reason) }
    try Self.validateRoute(entry: entry, format: format, stage: stage)
    guard metadata.epochID == epochID, metadata.formatSignature == formatSignature else { throw refuse("stale epoch or format signature") }
    guard metadata.width == format.width, metadata.height == format.height, metadata.pixel == format.pixel else { throw refuse("frame dimensions or pixel format differ from declaration") }
    guard metadata.presentationTime.isNumeric, metadata.presentationTime.timescale > 0,
      metadata.presentationTime.epoch == 0, metadata.presentationTime.value >= 0 else { throw refuse("presentation timestamp must be numeric, nonnegative and epoch zero") }
    guard metadata.duration.isNumeric, metadata.duration.timescale > 0, metadata.duration.epoch == 0,
      metadata.duration.value > 0 else { throw refuse("frame duration must be numeric, positive and epoch zero") }
    switch format.rate {
    case .constant(let duration):
      guard CMTimeCompare(metadata.duration, duration) == 0 else { throw refuse("frame duration differs from declared constant rate") }
    case .variable(_, let shortest, let longest):
      guard CMTimeCompare(metadata.duration, shortest) >= 0,
        CMTimeCompare(metadata.duration, longest) <= 0 else { throw refuse("frame duration falls outside declared variable-rate bounds") }
    }
    do { try Self.validateLayout(metadata, entry: entry) }
    catch { throw refuse("invalid plane geometry, stride, alignment or allocation: \(error)") }
  }

  static func validateLayout(_ metadata: SourceAdmissionMetadata, entry: PixelFormatTable.Entry) throws {
    func invalid() -> SourceFormatError { .invalid("Invalid source storage layout") }
    guard metadata.width > 0, metadata.height > 0, metadata.dataSize >= 0,
      metadata.pixel == entry.id, entry.rowAlignment > 0 else { throw invalid() }
    guard entry.id != .uyva || metadata.width.isMultiple(of: 2) else { throw invalid() }
    if entry.packed {
      guard !metadata.isPlanar, metadata.planeCount == 0, metadata.planes.isEmpty,
        metadata.rowBytes >= (try minimumPackedRowBytes(entry: entry, width: metadata.width)),
        metadata.rowBytes.isMultiple(of: entry.rowAlignment) else { throw invalid() }
      let (length, overflow) = metadata.rowBytes.multipliedReportingOverflow(by: metadata.height)
      guard !overflow, length > 0, metadata.dataSize == 0 || length <= metadata.dataSize else { throw invalid() }
      return
    }
    guard metadata.isPlanar, metadata.planeCount == entry.planes.count,
      metadata.planes.count == entry.planes.count else { throw invalid() }
    var total = 0
    for index in entry.planes.indices {
      let descriptor = entry.planes[index]
      let physical = try physicalPlaneExtent(entry: entry, plane: index, width: metadata.width, height: metadata.height)
      let plane = metadata.planes[index]
      let minimum = try minimumRowBytes(plane: descriptor, width: physical.width)
      guard plane.width == physical.width, plane.height == physical.height,
        plane.rowBytes >= minimum, plane.rowBytes.isMultiple(of: entry.rowAlignment) else { throw invalid() }
      let (length, overflow) = plane.rowBytes.multipliedReportingOverflow(by: physical.height)
      let (sum, sumOverflow) = total.addingReportingOverflow(length)
      guard !overflow, !sumOverflow, length > 0 else { throw invalid() }; total = sum
    }
    guard metadata.dataSize == 0 || total <= metadata.dataSize else { throw invalid() }
  }

  static func minimumPackedRowBytes(entry: PixelFormatTable.Entry, width: Int) throws -> Int {
    guard entry.packed, let plane = entry.planes.first, width > 0, plane.pixelsPerGroup > 0, plane.bytesPerGroup > 0 else { throw SourceFormatError.invalid("Invalid packed descriptor") }
    return try minimumRowBytes(plane: plane, width: width)
  }

  private static func minimumRowBytes(plane: PixelFormatTable.Plane, width: Int) throws -> Int {
    guard width > 0, plane.pixelsPerGroup > 0, plane.bytesPerGroup > 0 else { throw SourceFormatError.invalid("Invalid row descriptor") }
    if let bitsPerPixel = plane.packedBitsPerPixel {
      let (bits, overflow) = width.multipliedReportingOverflow(by: bitsPerPixel)
      guard bitsPerPixel > 0, !overflow else { throw SourceFormatError.invalid("Packed row overflow") }
      return bits / 8 + (bits % 8 == 0 ? 0 : 1)
    }
    let groups = width / plane.pixelsPerGroup + (width % plane.pixelsPerGroup == 0 ? 0 : 1)
    let (bytes, overflow) = groups.multipliedReportingOverflow(by: plane.bytesPerGroup)
    guard !overflow, bytes > 0 else { throw SourceFormatError.invalid("Packed row overflow") }
    return bytes
  }

  static func physicalPlaneExtent(entry: PixelFormatTable.Entry, plane: Int, width: Int, height: Int) throws -> (width: Int, height: Int) {
    guard entry.planes.indices.contains(plane), width > 0, height > 0 else { throw SourceFormatError.invalid("Invalid plane extent") }
    // For packed formats, subsampling describes chroma within each packing
    // group; it never shrinks the physical plane's full image extent.
    if entry.packed { return (width, height) }
    let descriptor = entry.planes[plane]
    return (try subsampledExtent(width, divisor: descriptor.horizontalSubsampling), try subsampledExtent(height, divisor: descriptor.verticalSubsampling))
  }

  static func subsampledExtent(_ extent: Int, divisor: Int) throws -> Int {
    guard extent > 0, divisor > 0 else { throw SourceFormatError.invalid("Invalid subsampling extent or divisor") }
    // Quotient/remainder avoids overflowing extent + divisor - 1.
    return extent / divisor + (extent % divisor == 0 ? 0 : 1)
  }

  private static func validateRoute(entry: PixelFormatTable.Entry, format: SourceFormat,
                                    stage: SourceAdmissionStage) throws {
    let required: Set<String>
    switch stage {
    case .capture: required = ["input", "lut", "program", "recording", "monitor", "extension"]
    case .recordingSource: required = ["recording"]
    case .lut: required = ["lut"]
    }
    if stage == .capture, !entry.captureQualified {
      throw refusal(format, stage, "GPU routes are not qualified for complete capture and writer integration")
    }
    guard required.isSubset(of: entry.routes), required.isSubset(of: entry.gpuRoutes) else {
      throw refusal(format, stage, "pixel format lacks required supported GPU routes: \(required.subtracting(entry.gpuRoutes.intersection(entry.routes)).sorted().joined(separator: ", "))")
    }
  }

  private static func refusal(_ format: SourceFormat, _ stage: SourceAdmissionStage, _ reason: String) -> SourceAdmissionRefusal {
    SourceAdmissionRefusal(stage: stage, formatDescription: "\(format.width) × \(format.height) \(String(format: "0x%08x", format.pixel.rawValue)) \(format.scan.rawValue) \(format.rate.nominal.value)/\(format.rate.nominal.timescale)", reason: reason)
  }
}
