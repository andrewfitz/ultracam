import CoreVideo
import Metal
import MonitorKitCore
import Synchronization

public enum MonitorKitError: Error, Equatable, CustomStringConvertible {
  case unsupportedPixelFormat(OSType)
  case invalidFrame(String)
  case textureMapping(plane: Int, status: CVReturn)
  case gpu(String)

  public var description: String {
    switch self {
    case .unsupportedPixelFormat(let type): return "Unsupported pixel format \(fourCC(type))."
    case .invalidFrame(let reason): return "Invalid frame: \(reason)"
    case .textureMapping(let plane, let status):
      return "Cannot map plane \(plane) for the GPU (CVReturn \(status))."
    case .gpu(let reason): return reason
    }
  }
}

func fourCC(_ type: OSType) -> String {
  let bytes = [24, 16, 8, 0].map { UInt8((type >> $0) & 0xFF) }
  return bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    ? String(decoding: bytes, as: UTF8.self) : String(type)
}

/// Mirrors `mk_FrameParams` in MKDecode.msl. 16-byte rows. `matrix.w` is the
/// 4:2:0 vertical chroma offset in luma rows (0 centred, -0.5 top, +0.5 bottom).
public struct FrameParameters: Equatable, Sendable {
  public var shape: SIMD4<UInt32>
  public var options: SIMD4<UInt32>
  public var matrix: SIMD4<Float>
  public var levels: SIMD4<Float>
  public var codeScale: SIMD4<Float>
}

/// One video frame, borrowed from the host. MonitorKit reads these textures in
/// place and never copies or retains them past the host's command buffer.
///
/// Keep the frame (and so any `CVMetalTexture` it holds) alive until every
/// command buffer that reads it has completed: the same rule as any texture
/// from a `CVMetalTextureCache`.
public struct MonitorFrame: @unchecked Sendable {
  /// Identifies the picture this frame holds, for analysis that must belong to
  /// it (the focus mask). Every new `MonitorFrame` gets a fresh value, so wrap
  /// each frame; a host that reuses one value across pictures of the same
  /// texture sets a new `id` (e.g. a frame counter) for each picture.
  public var id: UInt64
  public let layout: PixelLayout
  public let width: Int
  public let height: Int
  public var pixelAspectRatio: Double
  public var signal: SignalDescription
  /// v210: `rgba32Uint`, one texel per 6-pixel group. UYVY/YUYV: `rgba8Uint`, one texel per 2 pixels.
  public let packed: MTLTexture?
  /// Biplanar luma plane, or the RGB texture.
  public let luma: MTLTexture?
  /// Biplanar interleaved CbCr plane.
  public let chroma: MTLTexture?
  /// Keep texture-cache wrappers alive with the frame (two at most, so no array).
  let retained0: AnyObject?
  let retained1: AnyObject?

  private static let ids = Atomic<UInt64>(0)
  static func nextID() -> UInt64 { ids.add(1, ordering: .relaxed).newValue }

  /// Wraps textures the host already has. Throws if they do not match `layout`.
  public init(
    layout: PixelLayout, width: Int, height: Int, packed: MTLTexture? = nil,
    luma: MTLTexture? = nil, chroma: MTLTexture? = nil, signal: SignalDescription,
    pixelAspectRatio: Double = 1
  ) throws {
    try self.init(
      layout: layout, width: width, height: height, packed: packed, luma: luma, chroma: chroma,
      signal: signal, pixelAspectRatio: pixelAspectRatio, retained: (nil, nil))
  }

  init(
    layout: PixelLayout, width: Int, height: Int, packed: MTLTexture?, luma: MTLTexture?,
    chroma: MTLTexture?, signal: SignalDescription, pixelAspectRatio: Double, retained: (AnyObject?, AnyObject?)
  ) throws {
    guard layout.isValid else { throw MonitorKitError.invalidFrame("layout \(layout) is not valid") }
    guard width > 0, height > 0 else { throw MonitorKitError.invalidFrame("empty frame") }
    // Formats are compared directly, not through a collection, so wrapping a frame allocates nothing.
    func need(_ t: MTLTexture?, _ name: String, _ w: Int, _ h: Int, _ a: MTLPixelFormat, _ b: MTLPixelFormat = .invalid)
      throws
    {
      guard let t else { throw MonitorKitError.invalidFrame("\(name) texture missing") }
      guard t.width >= w, t.height >= h else {
        throw MonitorKitError.invalidFrame("\(name) texture is \(t.width)×\(t.height), needs \(w)×\(h)")
      }
      guard t.pixelFormat == a || (b != .invalid && t.pixelFormat == b) else {
        throw MonitorKitError.invalidFrame("\(name) texture format \(t.pixelFormat.rawValue) is not usable")
      }
    }
    switch layout {
    case .v210:
      try need(packed, "packed", (width + 5) / 6, height, .rgba32Uint)
    case .uyvy8, .yuyv8:
      try need(packed, "packed", (width + 1) / 2, height, .rgba8Uint)
    case .biplanar(let s, let depth):
      try need(luma, "luma", width, height, depth == 8 ? .r8Unorm : .r16Unorm)
      let cw = s == .s444 ? width : (width + 1) / 2
      let ch = s == .s420 ? (height + 1) / 2 : height
      try need(chroma, "chroma", cw, ch, depth == 8 ? .rg8Unorm : .rg16Unorm)
    case .rgb(let depth, let float):
      if float {
        try need(luma, "rgb", width, height, depth == 16 ? .rgba16Float : .rgba32Float)
      } else if depth == 8 {
        try need(luma, "rgb", width, height, .bgra8Unorm, .rgba8Unorm)
      } else if depth == 10 {
        try need(luma, "rgb", width, height, .bgr10a2Unorm, .rgb10a2Unorm)
      } else {
        try need(luma, "rgb", width, height, .rgba16Unorm)
      }
    }
    self.layout = layout
    self.width = width
    self.height = height
    self.packed = packed
    self.luma = luma
    self.chroma = chroma
    self.signal = signal
    self.pixelAspectRatio =
      pixelAspectRatio.isFinite && pixelAspectRatio > 0 ? pixelAspectRatio : 1
    retained0 = retained.0
    retained1 = retained.1
    id = Self.nextID()
  }

  /// The texture whose identity stands for this frame (the packed or luma/RGB texture).
  var primaryTexture: MTLTexture? { packed ?? luma }

  /// Parameters for `mk_FrameParams`.
  public var parameters: FrameParameters {
    let kind = layout.shaderKind
    let sub: UInt32 = layout.subsampling == .s444 ? 0 : (layout.subsampling == .s422 ? 1 : 2)
    let depth = layout.bitDepth
    // Float RGB is already normalized: it has no code range.
    let full = signal.range == .full || layout.isFloat
    var codeDepth = depth
    var lumaScale: Float = 1, chromaScale: Float = 1, rgbMax: Float = 1, isFloat: Float = 0
    switch layout {
    case .v210, .uyvy8, .yuyv8: break
    case .biplanar(_, let d):
      // 8-bit planes are r8Unorm; deeper samples are high-aligned in 16 bits.
      let scale: Float = d == 8 ? 255 : 65535 / Float(1 << (16 - d))
      lumaScale = scale
      chromaScale = scale
    case .rgb(let d, let float):
      if float {
        isFloat = 1
        codeDepth = 10
      } else {
        rgbMax = Float((1 << d) - 1)
      }
    }
    // Float RGB takes full 10-bit levels whatever its label: `mk_nativeLog` reads
    // a full container's maximum code from them.
    let levels = (full ? CodeRange.full : .legal).levels(bitDepth: codeDepth)
    let k = signal.matrix.coefficients
    // Every 10-bit integer layout carries exact codes the classifiers can restore.
    let integral10 = depth == 10 && !layout.isFloat
    let rescaled: Bool = {
      if case .log(let log) = signal.encoding { return log.transport == .fullRescaledToLegal }
      return false
    }()
    return FrameParameters(
      shape: SIMD4(kind, UInt32(width), UInt32(height), sub),
      options: SIMD4(
        signal.chromaSiting == .center ? 1 : 0, full ? 1 : 0, rescaled ? 1 : 0, integral10 ? 1 : 0),
      matrix: SIMD4(Float(k.r), Float(k.g), Float(k.b), Float(signal.chromaVerticalSiting.offset)),
      levels: SIMD4(
        Float(levels.black), Float(levels.span), Float(levels.center), Float(levels.chromaSpan)),
      codeScale: SIMD4(lumaScale, chromaScale, rgbMax, isFloat))
  }
}

extension MonitorFrame {
  /// The layout and texture formats CoreVideo uses for `pixelFormat`, if supported.
  public static func layout(for pixelFormat: OSType) -> (layout: PixelLayout, range: CodeRange)? {
    switch pixelFormat {
    case kCVPixelFormatType_422YpCbCr10: return (.v210, .legal)
    case kCVPixelFormatType_422YpCbCr8: return (.uyvy8, .legal)
    case kCVPixelFormatType_422YpCbCr8_yuvs: return (.yuyv8, .legal)
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return (.biplanar(.s420, bitDepth: 8), .legal)
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return (.biplanar(.s420, bitDepth: 8), .full)
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: return (.biplanar(.s422, bitDepth: 8), .legal)
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: return (.biplanar(.s422, bitDepth: 8), .full)
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: return (.biplanar(.s444, bitDepth: 8), .legal)
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: return (.biplanar(.s444, bitDepth: 8), .full)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return (.biplanar(.s420, bitDepth: 10), .legal)
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return (.biplanar(.s420, bitDepth: 10), .full)
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: return (.biplanar(.s422, bitDepth: 10), .legal)
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: return (.biplanar(.s422, bitDepth: 10), .full)
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return (.biplanar(.s444, bitDepth: 10), .legal)
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: return (.biplanar(.s444, bitDepth: 10), .full)
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange: return (.biplanar(.s422, bitDepth: 16), .legal)
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange: return (.biplanar(.s444, bitDepth: 16), .legal)
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA: return (.bgra8, .full)
    case kCVPixelFormatType_ARGB2101010LEPacked: return (.rgb10a2, .full)
    case kCVPixelFormatType_64RGBALE: return (.rgb(bitDepth: 16, float: false), .full)
    case kCVPixelFormatType_64RGBAHalf: return (.rgba16Float, .full)
    case kCVPixelFormatType_128RGBAFloat: return (.rgba32Float, .full)
    default: return nil
    }
  }

  /// Signal description from CoreVideo attachments. Log encodings cannot be
  /// inferred from attachments; pass them explicitly. Reads the attachments as
  /// CF values without bridging, so it allocates nothing per frame.
  public static func signal(of pixelBuffer: CVPixelBuffer, range: CodeRange) -> SignalDescription {
    func attachment(_ key: CFString) -> CFTypeRef? { CVBufferCopyAttachment(pixelBuffer, key, nil) }
    func equal(_ value: CFTypeRef?, _ constant: CFString) -> Bool {
      guard let value else { return false }
      return CFEqual(value, constant)
    }
    let m = attachment(kCVImageBufferYCbCrMatrixKey)
    let matrix: YCbCrMatrix =
      equal(m, kCVImageBufferYCbCrMatrix_ITU_R_2020) ? .bt2020
      : equal(m, kCVImageBufferYCbCrMatrix_ITU_R_601_4) ? .bt601
      : equal(m, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) ? .smpte240m : .bt709
    let t = attachment(kCVImageBufferTransferFunctionKey)
    let transfer: DisplayTransfer =
      equal(t, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ? .pq
      : equal(t, kCVImageBufferTransferFunction_ITU_R_2100_HLG) ? .hlg
      : equal(t, kCVImageBufferTransferFunction_sRGB) ? .sRGB
      : equal(t, kCVImageBufferTransferFunction_Linear) ? .linear : .bt709
    // H.273 chroma sample location types. SMPTE/QuickTime 4:2:2 is left-cosited
    // unless the producer labels it otherwise; 4:2:0 is vertically centred by default.
    let l = attachment(kCVImageBufferChromaLocationTopFieldKey)
    let centred =
      equal(l, kCVImageBufferChromaLocation_Center) || equal(l, kCVImageBufferChromaLocation_Top)
      || equal(l, kCVImageBufferChromaLocation_Bottom)
    let vertical: ChromaVerticalSiting =
      equal(l, kCVImageBufferChromaLocation_TopLeft) || equal(l, kCVImageBufferChromaLocation_Top) ? .top
      : equal(l, kCVImageBufferChromaLocation_BottomLeft) || equal(l, kCVImageBufferChromaLocation_Bottom)
        ? .bottom : .center
    return SignalDescription(
      range: range, matrix: matrix, chromaSiting: centred ? .center : .left, encoding: .display(transfer),
      chromaVerticalSiting: vertical)
  }

  /// One plane through the texture cache: the texture and the wrapper that keeps it valid.
  /// A static function, not a closure, so wrapping allocates no capture context.
  private static func map(
    _ pixelBuffer: CVPixelBuffer, _ cache: CVMetalTextureCache, _ plane: Int, _ format: MTLPixelFormat, _ w: Int,
    _ h: Int
  ) throws -> (MTLTexture, AnyObject) {
    var wrapper: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, format, w, h, plane, &wrapper)
    guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper)
    else { throw MonitorKitError.textureMapping(plane: plane, status: status) }
    return (texture, wrapper)
  }

  /// Horizontal over vertical spacing from the pixel aspect attachment, 1 when absent.
  static func pixelAspectRatio(of pixelBuffer: CVPixelBuffer) -> Double {
    guard let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil),
      CFGetTypeID(value) == CFDictionaryGetTypeID()
    else { return 1 }
    let dictionary = unsafeDowncast(value, to: CFDictionary.self)
    let h = spacing(dictionary, kCVImageBufferPixelAspectRatioHorizontalSpacingKey)
    let v = spacing(dictionary, kCVImageBufferPixelAspectRatioVerticalSpacingKey)
    return h > 0 && v > 0 && (h / v).isFinite ? h / v : 1
  }

  private static func spacing(_ dictionary: CFDictionary, _ key: CFString) -> Double {
    guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return 0 }
    let object = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    guard CFGetTypeID(object) == CFNumberGetTypeID() else { return 0 }
    var value = 0.0
    return CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .doubleType, &value) ? value : 0
  }

  /// Wraps an IOSurface-backed pixel buffer through the host's texture cache.
  /// No pixels are copied. `signal` overrides what the attachments say.
  public static func wrap(
    _ pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache, signal: SignalDescription? = nil
  ) throws -> MonitorFrame {
    let type = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard let (layout, range) = layout(for: type) else {
      throw MonitorKitError.unsupportedPixelFormat(type)
    }
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
    var packed: MTLTexture?, luma: MTLTexture?, chroma: MTLTexture?
    var wrappers: (AnyObject?, AnyObject?) = (nil, nil)
    switch layout {
    case .v210:
      (packed, wrappers.0) = try map(pixelBuffer, cache, 0, .rgba32Uint, (width + 5) / 6, height)
    case .uyvy8, .yuyv8:
      (packed, wrappers.0) = try map(pixelBuffer, cache, 0, .rgba8Uint, (width + 1) / 2, height)
    case .biplanar(_, let depth):
      (luma, wrappers.0) = try map(
        pixelBuffer, cache, 0, depth == 8 ? .r8Unorm : .r16Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
        CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
      (chroma, wrappers.1) = try map(
        pixelBuffer, cache, 1, depth == 8 ? .rg8Unorm : .rg16Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
        CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
    case .rgb(let depth, let float):
      let format: MTLPixelFormat =
        float
        ? (depth == 16 ? .rgba16Float : .rgba32Float)
        : depth == 8
          ? (type == kCVPixelFormatType_32RGBA ? .rgba8Unorm : .bgra8Unorm)
          : depth == 10 ? .bgr10a2Unorm : .rgba16Unorm
      (luma, wrappers.0) = try map(pixelBuffer, cache, 0, format, width, height)
    }
    return try MonitorFrame(
      layout: layout, width: width, height: height, packed: packed, luma: luma, chroma: chroma,
      signal: signal ?? Self.signal(of: pixelBuffer, range: range),
      pixelAspectRatio: pixelAspectRatio(of: pixelBuffer), retained: wrappers)
  }
}
