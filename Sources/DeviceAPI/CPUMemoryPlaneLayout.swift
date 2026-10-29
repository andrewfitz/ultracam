import CoreVideo
import Foundation

/// Physical storage, independent of colour interpretation. Alpha planes remain
/// present and validated even where v1 image processing ignores their values.
struct CPUMemoryPlaneLayout: Equatable, Sendable {
  let width: Int
  let height: Int
  let components: Int
  let componentBytes: Int
  private let logicalRowBytes: Int?
  var textureRowBytes: Int { width * components * componentBytes }
  var minimumRowBytes: Int { logicalRowBytes ?? textureRowBytes }

  init(width: Int, height: Int, components: Int, componentBytes: Int, logicalRowBytes: Int? = nil) {
    self.width = width; self.height = height; self.components = components
    self.componentBytes = componentBytes; self.logicalRowBytes = logicalRowBytes
  }

  static func planes(pixelFormat: OSType, width: Int, height: Int) throws -> [Self] {
    guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else { throw NoCopyIngestError.invalidLength }
    let cw = width / 2 + width % 2, ch = height / 2 + height % 2
    func plane(_ w: Int, _ h: Int, _ c: Int = 1, _ b: Int = 1) -> Self { Self(width: w, height: h, components: c, componentBytes: b) }
    switch pixelFormat {
    case kCVPixelFormatType_32BGRA, 0x72323130: return [plane(width, height, 4)]
    case 0x5231324c:
      let bits = width.multipliedReportingOverflow(by: 36)
      guard !bits.overflow, bits.partialValue <= Int.max - 7 else { throw NoCopyIngestError.arithmeticOverflow }
      let logicalBytes = (bits.partialValue + 7) / 8
      let texels = logicalBytes / 8 + (logicalBytes % 8 == 0 ? 0 : 1)
      return [Self(width: texels, height: height, components: 4, componentBytes: 2, logicalRowBytes: logicalBytes)]
    case 0x49343230, 0x50413136:
      let kind: NDIPlanarLayout = pixelFormat == 0x49343230 ? .i420 : .pa16
      return try kind.planes(width: width, height: height).map {
        Self(width: $0.width, height: $0.height, components: $0.components, componentBytes: $0.componentBytes)
      }
    case 0x50323136: return [plane(width, height, 1, 2), plane(cw, height, 2, 2)]
    case 0x55595641:
      guard width.isMultiple(of: 2) else { throw NoCopyIngestError.invalidLength }
      return [plane(width / 2, height, 4), plane(width, height)]
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      return [plane(width, height), plane(cw, ch, 2)]
    default: throw NoCopyIngestError.unsupportedPixelFormat
    }
  }
}
