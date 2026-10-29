import CoreVideo
import Foundation

/// Validation for bi-planar 4:2:0 Core Video images (420v and 420f).
/// Plane dimensions are physical allocation extents: chroma rounds up for odd
/// source dimensions, while its interleaved samples require two bytes/pixel.
enum Planar420Formats {
  enum Kind: Equatable, Sendable { case video, full
    var pixelFormat: OSType { self == .video ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange }
    var range: Colorimetry.Range { self == .video ? .video : .full }
  }

  struct Metadata: Equatable, Sendable {
    let width: Int; let height: Int; let kind: Kind
    private(set) var pixelFormat: OSType
    let planeWidths: [Int]; let planeHeights: [Int]; let strides: [Int]; let dataSize: Int
    init(width: Int, height: Int, kind: Kind, planeWidths: [Int], planeHeights: [Int], strides: [Int], dataSize: Int = 0) {
      self.width = width; self.height = height; self.kind = kind
      self.pixelFormat = kind.pixelFormat
      self.planeWidths = planeWidths; self.planeHeights = planeHeights; self.strides = strides; self.dataSize = dataSize
    }
    init(_ image: CVPixelBuffer) {
      let pixelFormat = CVPixelBufferGetPixelFormatType(image)
      let kind: Kind = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? .full : .video
      let count = CVPixelBufferGetPlaneCount(image)
      self.init(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image), kind: kind,
                planeWidths: (0..<count).map { CVPixelBufferGetWidthOfPlane(image, $0) },
                planeHeights: (0..<count).map { CVPixelBufferGetHeightOfPlane(image, $0) },
                strides: (0..<count).map { CVPixelBufferGetBytesPerRowOfPlane(image, $0) }, dataSize: CVPixelBufferGetDataSize(image))
      self.pixelFormat = pixelFormat
    }
  }

  static func validate(_ image: CVPixelBuffer, expected: SourceFormat? = nil) throws {
    guard CVPixelBufferIsPlanar(image) else { throw VideoError.message("420 requires a planar buffer.") }
    try validate(Metadata(image), expected: expected)
  }

  static func validate(_ metadata: Metadata, expected: SourceFormat? = nil) throws {
    guard metadata.width > 0, metadata.height > 0, metadata.dataSize >= 0,
          metadata.pixelFormat == metadata.kind.pixelFormat else { throw VideoError.message("Unsupported 420 pixel format.") }
    guard metadata.planeWidths.count == 2, metadata.planeHeights.count == 2, metadata.strides.count == 2 else { throw VideoError.message("420 requires exactly two planes.") }
    let chromaWidth = try ceilDivide(metadata.width, 2), chromaHeight = try ceilDivide(metadata.height, 2)
    guard metadata.planeWidths == [metadata.width, chromaWidth], metadata.planeHeights == [metadata.height, chromaHeight] else { throw VideoError.message("Invalid 420 plane extents.") }
    let (chromaBytes, chromaOverflow) = chromaWidth.multipliedReportingOverflow(by: 2)
    guard !chromaOverflow, chromaBytes > 0 else { throw VideoError.message("420 chroma stride arithmetic overflow.") }
    let minimums = [metadata.width, chromaBytes]
    var total = 0
    for index in 0..<2 {
      let stride = metadata.strides[index]
      let (length, overflow) = stride.multipliedReportingOverflow(by: metadata.planeHeights[index])
      guard stride >= minimums[index], !overflow, length > 0,
            metadata.dataSize == 0 || length <= metadata.dataSize else { throw VideoError.message("Invalid 420 plane \(index) stride or allocation extent.") }
      let (sum, sumOverflow) = total.addingReportingOverflow(length)
      guard !sumOverflow else { throw VideoError.message("420 allocation arithmetic overflow.") }
      total = sum
    }
    guard metadata.dataSize == 0 || total <= metadata.dataSize else { throw VideoError.message("420 allocation is smaller than both plane extents.") }
    if let expected {
      guard expected.width == metadata.width, expected.height == metadata.height,
            expected.pixel == PixelFormatID(rawValue: metadata.kind.pixelFormat),
            expected.colour.range == metadata.kind.range else { throw VideoError.message("420 frame metadata does not match its format declaration.") }
    }
  }

  static func ceilDivide(_ value: Int, _ divisor: Int) throws -> Int {
    guard value > 0, divisor > 0 else { throw VideoError.message("Invalid 420 extent divisor.") }
    return value / divisor + (value % divisor == 0 ? 0 : 1)
  }
}
