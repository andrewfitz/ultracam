import CoreVideo

/// Validates physical storage only. Admission separately requires proven GPU
/// routes; a recognized layout never authorizes an unsupported capture format.
enum VideoBufferLayout {
  struct Plane: Sendable {
    var width: Int
    var height: Int
    var rowBytes: Int
  }
  struct Metadata: Sendable {
    var width: Int
    var height: Int
    var pixelFormat: OSType
    var isPlanar: Bool
    var rowBytes: Int
    var dataSize: Int
    var planes: [Plane]
  }

  static func validate(_ image: CVPixelBuffer) throws {
    let planes = (0..<CVPixelBufferGetPlaneCount(image)).map {
      Plane(width: CVPixelBufferGetWidthOfPlane(image, $0),
        height: CVPixelBufferGetHeightOfPlane(image, $0), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, $0))
    }
    try validate(Metadata(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
      pixelFormat: CVPixelBufferGetPixelFormatType(image), isPlanar: CVPixelBufferIsPlanar(image),
      rowBytes: CVPixelBufferGetBytesPerRow(image), dataSize: CVPixelBufferGetDataSize(image), planes: planes))
  }

  static func validate(_ image: Metadata) throws {
    func fail() -> VideoError { .message("Invalid video plane dimensions, row stride or allocation extent.") }
    guard image.width > 0, image.height > 0, image.dataSize >= 0 else { throw fail() }
    func multiply(_ a: Int, _ b: Int) throws -> Int {
      let (value, overflow) = a.multipliedReportingOverflow(by: b)
      guard !overflow, value > 0 else { throw fail() }
      return value
    }
    func rowBytes(groupPixels: Int, groupBytes: Int) throws -> Int {
      let groups = image.width / groupPixels + (image.width % groupPixels == 0 ? 0 : 1)
      return try multiply(groups, groupBytes)
    }
    let type = image.pixelFormat
    let minimumPacked: Int?
    let packedAlignment: Int
    switch type {
    case kCVPixelFormatType_422YpCbCr10:
      minimumPacked = try rowBytes(groupPixels: 6, groupBytes: 16); packedAlignment = 128
    case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs:
      minimumPacked = try rowBytes(groupPixels: 2, groupBytes: 4); packedAlignment = 1
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, 0x72323130: // r210
      minimumPacked = try multiply(image.width, 4); packedAlignment = 1
    case 0x5231324c: // R12L: contiguous little-endian 12-bit RGB components
      let bits = try multiply(image.width, 36)
      minimumPacked = bits / 8 + (bits % 8 == 0 ? 0 : 1); packedAlignment = 1
    default:
      minimumPacked = nil; packedAlignment = 1
    }
    if let minimumPacked {
      guard !image.isPlanar, image.planes.isEmpty, image.rowBytes >= minimumPacked,
        image.rowBytes.isMultiple(of: packedAlignment) else { throw fail() }
      let length = try multiply(image.rowBytes, image.height)
      guard image.dataSize == 0 || length <= image.dataSize else { throw fail() }
      return
    }

    // Custom NDI Core Video registrations preserve alpha even when v1 picture
    // processing ignores it. UYVA's CV colour plane reports full image width
    // at two bytes/pixel; its GPU rgba8 view instead has one texel per pair.
    if type == 0x55595641 || type == 0x49343230 || type == 0x50413136 {
      let cw = image.width / 2 + image.width % 2
      let ch = image.height / 2 + image.height % 2
      let extents: [(width: Int, height: Int, components: Int, bytes: Int)]
      switch type {
      case 0x55595641:
        guard image.width.isMultiple(of: 2) else { throw fail() }
        extents = [(image.width, image.height, 2, 1), (image.width, image.height, 1, 1)]
      case 0x49343230:
        extents = [(image.width, image.height, 1, 1), (cw, ch, 1, 1), (cw, ch, 1, 1)]
      default:
        extents = [(image.width, image.height, 1, 2), (cw, image.height, 2, 2), (image.width, image.height, 1, 2)]
      }
      guard image.isPlanar, image.planes.count == extents.count else { throw fail() }
      var total = 0
      for (plane, extent) in zip(image.planes, extents) {
        let minimum = try multiply(extent.width, extent.components * extent.bytes)
        guard plane.width == extent.width, plane.height == extent.height,
          plane.rowBytes >= minimum, plane.rowBytes.isMultiple(of: extent.bytes) else { throw fail() }
        let length = try multiply(plane.rowBytes, extent.height)
        let (sum, overflow) = total.addingReportingOverflow(length)
        guard !overflow else { throw fail() }; total = sum
      }
      guard image.dataSize == 0 || total <= image.dataSize else { throw fail() }
      return
    }

    let componentBytes: Int
    let verticalSubsampling: Int
    switch type {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      componentBytes = 1; verticalSubsampling = 2
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
      componentBytes = 2; verticalSubsampling = 2
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
      componentBytes = 1; verticalSubsampling = 1
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, 0x50323136: // P216
      componentBytes = 2; verticalSubsampling = 1
    default:
      throw VideoError.message("Unsupported video pixel format.")
    }
    guard image.isPlanar, image.planes.count == 2 else { throw fail() }
    let chromaWidth = image.width / 2 + image.width % 2
    let chromaHeight = image.height / verticalSubsampling + (image.height % verticalSubsampling == 0 ? 0 : 1)
    var total = 0
    for index in 0..<2 {
      let plane = image.planes[index]
      let width = index == 0 ? image.width : chromaWidth
      let height = index == 0 ? image.height : chromaHeight
      let minimum = try multiply(width, componentBytes * (index == 0 ? 1 : 2))
      guard plane.width == width, plane.height == height, plane.rowBytes >= minimum,
        plane.rowBytes.isMultiple(of: componentBytes) else { throw fail() }
      let length = try multiply(plane.rowBytes, height)
      let (sum, overflow) = total.addingReportingOverflow(length)
      guard !overflow else { throw fail() }; total = sum
    }
    // Core Video may report zero aggregate storage for externally owned planes.
    guard image.dataSize == 0 || total <= image.dataSize else { throw fail() }
  }
}
