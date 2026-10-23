import CoreVideo
import Foundation
import Metal
import MonitorKitCore
import Synchronization

/// Errors from MonitorKit's encodes, frames and engines. `LocalizedError`, so
/// `localizedDescription` in a host's UI is `description`, not a generic message.
public enum MonitorKitError: LocalizedError, Equatable, CustomStringConvertible {
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

  public var errorDescription: String? { description }
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
///
/// Texture formats of a host-built frame (`init(layout:width:height:…)`), each
/// plane at least the size given, read with `read()` (never sampled), usage
/// `.shaderRead`, any storage mode. They are what `wrap(_:cache:)` and
/// `MonitorTextureCache` make over CoreVideo's buffers, and what a Metal 4 host
/// creates with `makeTexture(descriptor:iosurface:plane:)`:
///
/// | Layout | Plane | Format | Size |
/// | --- | --- | --- | --- |
/// | `.v210` (`'v210'`) | `packed` | `rgba32Uint` | ⌈w/6⌉ × h (one texel per 6-pixel group) |
/// | `.uyvy8` (`'2vuy'`), `.yuyv8` (`'yuvs'`) | `packed` | `rgba8Uint` | ⌈w/2⌉ × h |
/// | `.biplanar(_, bitDepth: 8)` (`'420v'`, `'422v'`, …) | `luma`, `chroma` | `r8Unorm`, `rg8Unorm` | w × h, chroma subsampled |
/// | `.biplanar(_, bitDepth: 10 or 16)` (`'x420'`, `'x422'`, `'sv22'`, …) | `luma`, `chroma` | `r16Unorm`, `rg16Unorm` (high-aligned samples, not `r16Uint`) | as above |
/// | `.bgra8` | `luma` | `bgra8Unorm` or `rgba8Unorm` | w × h |
/// | `.rgb10a2` | `luma` | `bgr10a2Unorm` or `rgb10a2Unorm` | w × h |
/// | `.rgb(bitDepth: 16, float: false)` | `luma` | `rgba16Unorm` | w × h |
/// | `.rgba16Float`, `.rgba32Float` | `luma` | `rgba16Float`, `rgba32Float` | w × h |
///
/// Chroma planes are ⌈w/2⌉ wide for 4:2:0 and 4:2:2 and ⌈h/2⌉ high for 4:2:0.
/// On Metal 4 the host makes the textures resident once, when it first wraps
/// them (`addResidency(to:)`, or `MonitorTextureCache`, which does it for you).
public struct MonitorFrame: @unchecked Sendable {
  /// Identifies the picture this frame holds, for analysis that must belong to
  /// it (the focus mask). Every new `MonitorFrame` gets a fresh value, so wrap
  /// each frame; a host that reuses one value across pictures of the same
  /// texture sets a new `id` (e.g. a frame counter) for each picture.
  public var id: UInt64
  public let layout: PixelLayout
  public let width: Int
  public let height: Int
  /// Horizontal over vertical pixel spacing, finite and positive (1 when the
  /// frame's declared ratio is not). The declared value is kept: `geometry` reports
  /// a broken one (not finite, zero or negative) as 0, which the pass reports as
  /// `MonitorUnavailableReason.unsupportedGeometry` and shows with square pixels.
  public var pixelAspectRatio: Double {
    get { declaredPixelAspectRatio.isFinite && declaredPixelAspectRatio > 0 ? declaredPixelAspectRatio : 1 }
    set { declaredPixelAspectRatio = newValue }
  }
  /// The ratio as declared (the tag, or what the host set), possibly unusable.
  var declaredPixelAspectRatio: Double
  public var signal: SignalDescription
  /// The part of the frame that is picture, in pixels from the top-left corner
  /// (the clean aperture: ISO/IEC 14496-12 `clap`, CoreVideo's
  /// `kCVImageBufferCleanApertureKey`); nil shows the whole frame. The layout, the
  /// picture, the focus footprint, guides, the navigator and the display aspect
  /// all follow it; analysis still covers the whole frame. `wrap` reads it from the
  /// buffer. Set it to crop to any region of interest; one that is not finite or
  /// under a pixel once clipped to the frame shows the whole frame.
  public var cleanAperture: MonitorRect?
  /// The picture was processed after the camera (a programme mix, a scaled or
  /// graded render), so it is not the camera's own signal. Tools that classify or
  /// measure the camera's signal itself, log false colour and focus peaking, are
  /// then unavailable (`MonitorUnavailableReason.requiresCameraSignal`) and
  /// `MonitorFeed.analyze` encodes nothing for it. False by default.
  public var isProcessed = false
  /// v210: `rgba32Uint`, one texel per 6-pixel group. UYVY/YUYV: `rgba8Uint`, one texel per 2 pixels.
  public let packed: MTLTexture?
  /// Biplanar luma plane, or the RGB texture.
  public let luma: MTLTexture?
  /// Biplanar interleaved CbCr plane.
  public let chroma: MTLTexture?
  /// Keep texture-cache wrappers alive with the frame (two at most, so no array).
  let retained0: AnyObject?
  let retained1: AnyObject?
  /// Set on a frame `MonitorFeed.freeze` returned (its planes are the feed's), and
  /// on a `MonitorTextureCache` frame (its first plane's cache entry).
  var frozenPlanes: FrozenPlanes?
  /// A `MonitorTextureCache` frame's second plane's cache entry (biplanar chroma).
  var secondPlanes: FrozenPlanes?

  private static let ids = Atomic<UInt64>(0)
  static func nextID() -> UInt64 { ids.add(1, ordering: .relaxed).newValue }

  /// Wraps textures the host already has (formats in the table above). Throws if
  /// they do not match `layout`, or if `cleanAperture` (frame pixels, top-left
  /// origin) is not a finite rect of at least a pixel inside the frame.
  /// Allocation-free.
  public init(
    layout: PixelLayout, width: Int, height: Int, packed: MTLTexture? = nil,
    luma: MTLTexture? = nil, chroma: MTLTexture? = nil, signal: SignalDescription,
    pixelAspectRatio: Double = 1, cleanAperture: MonitorRect? = nil
  ) throws {
    if let a = cleanAperture {
      // A hair of tolerance for apertures derived from rational CoreVideo values.
      let e = 1e-6
      guard a.x.isFinite, a.y.isFinite, a.width.isFinite, a.height.isFinite, a.width >= 1, a.height >= 1,
        a.x >= -e, a.y >= -e, a.maxX <= Double(width) + e, a.maxY <= Double(height) + e
      else { throw MonitorKitError.invalidFrame("clean aperture \(a) is not inside the \(width)×\(height) frame") }
    }
    try self.init(
      layout: layout, width: width, height: height, packed: packed, luma: luma, chroma: chroma,
      signal: signal, pixelAspectRatio: pixelAspectRatio, retained: (nil, nil), cleanAperture: cleanAperture)
  }

  init(
    layout: PixelLayout, width: Int, height: Int, packed: MTLTexture?, luma: MTLTexture?,
    chroma: MTLTexture?, signal: SignalDescription, pixelAspectRatio: Double, retained: (AnyObject?, AnyObject?),
    cleanAperture: MonitorRect? = nil
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
    declaredPixelAspectRatio = pixelAspectRatio
    self.cleanAperture = cleanAperture
    retained0 = retained.0
    retained1 = retained.1
    id = Self.nextID()
  }

  /// The frame's shape without its pixels, for `MonitorLayout(frame:state:…)` and
  /// the display aspect on any thread. A declared pixel aspect ratio that is not
  /// finite and positive is 0 here (equality-stable, and outside
  /// `MonitorFrameGeometry.pixelAspectRatioRange`, so it shows square pixels).
  public var geometry: MonitorFrameGeometry {
    MonitorFrameGeometry(
      width: width, height: height, pixelAspectRatio: Self.stablePixelAspectRatio(declaredPixelAspectRatio),
      cleanAperture: cleanAperture)
  }

  /// `ratio` when finite and positive, else 0: what `geometry` and the pass key
  /// carry, so a NaN never makes two equal frames compare unequal.
  static func stablePixelAspectRatio(_ ratio: Double) -> Double { ratio.isFinite && ratio > 0 ? ratio : 0 }

  /// The texture whose identity stands for this frame (the packed or luma/RGB texture).
  var primaryTexture: MTLTexture? { packed ?? luma }

  /// Metal 4: a frame whose planes their owner has since let go is no longer in
  /// the residency set, though the frame keeps the textures alive: a frame
  /// `MonitorFeed.freeze` returned once the feed released its planes
  /// (`unfreeze()`, or a freeze of another size), or a `MonitorTextureCache` frame
  /// once the cache swept, flushed or removed its textures (e.g. a stalled camera's
  /// last frame, still redrawn). This makes them resident again until the latest
  /// submission `residency` observed completes; for any other frame it does
  /// nothing. MonitorKit's own Metal 4 encodes (pictures, analysis, Freeze, scopes)
  /// call it after observing their submission; other work that reads frames calls
  /// it the same way. Allocation-free; it changes the residency set only for a
  /// released frame.
  public func keepResidentIfReleased(in residency: MonitorResidency) {
    // Sequentially consistent with the owner's store and `MonitorResidency`'s
    // submission counter: either this sees the release, or the release's
    // retirement covers the submission just observed.
    let first = frozenPlanes?.released.load(ordering: .sequentiallyConsistent) ?? false
    let second = secondPlanes?.released.load(ordering: .sequentiallyConsistent) ?? false
    guard first || second else { return }
    if let packed {
      residency.add(packed)
      residency.retire(packed, resident: packed)
    }
    if let luma {
      residency.add(luma)
      residency.retire(luma, resident: luma)
    }
    if let chroma {
      residency.add(chroma)
      residency.retire(chroma, resident: chroma)
    }
  }

  /// Adds the frame's textures to a host residency set (Metal 4: host frames are
  /// the host's to make resident). Does not commit the set, so a host batches
  /// several frames into one commit. Do it when a texture is first wrapped (e.g.
  /// in an IOSurface-keyed cache), not per frame.
  public func addResidency(to set: MTLResidencySet) {
    if let packed { set.addAllocation(packed) }
    if let luma { set.addAllocation(luma) }
    if let chroma { set.addAllocation(chroma) }
  }

  /// Removes the frame's textures from a host residency set, without committing.
  public func removeResidency(from set: MTLResidencySet) {
    if let packed { set.removeAllocation(packed) }
    if let luma { set.removeAllocation(luma) }
    if let chroma { set.removeAllocation(chroma) }
  }

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

  /// Signal description from CoreVideo attachments (matrix, transfer, primaries,
  /// chroma siting). Log encodings cannot be inferred from attachments; pass them
  /// explicitly. Reads the attachments as CF values without bridging, so it
  /// allocates nothing per frame.
  ///
  /// A buffer with no transfer function attachment, or one MonitorKit does not
  /// read (e.g. SMPTE ST 428-1, a gamma), is taken as BT.709. This is also what
  /// `wrap` and `MonitorTextureCache.frame` use when given no `signal`. A host that
  /// wants such a picture shown as unlabelled code values (the code-value view,
  /// and `.requiresKnownTransfer` for tools that need light) passes
  /// `signal(of:range:untaggedTransfer: .unknown)` as the frame's `signal`.
  public static func signal(of pixelBuffer: CVPixelBuffer, range: CodeRange) -> SignalDescription {
    signal(of: pixelBuffer, range: range, untaggedTransfer: .display(.bt709))
  }

  /// `signal(of:range:)` with `untaggedTransfer` as the encoding of a buffer whose
  /// transfer function is missing or not one MonitorKit reads. It reads BT.709
  /// (`kCVImageBufferTransferFunction_ITU_R_709_2`, and `ITU_R_2020`, the same
  /// OETF per ITU-R BT.2020 Table 4), PQ, HLG, sRGB and linear. `.unknown` makes an
  /// untagged capture-card buffer unlabelled code values, as MonitorTools showed it.
  /// Allocates nothing per frame. The range comes from `layout(for:)`.
  public static func signal(
    of pixelBuffer: CVPixelBuffer, range: CodeRange, untaggedTransfer: SignalEncoding
  ) -> SignalDescription {
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
    let transfer: DisplayTransfer? =
      equal(t, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ? .pq
      : equal(t, kCVImageBufferTransferFunction_ITU_R_2100_HLG) ? .hlg
      : equal(t, kCVImageBufferTransferFunction_sRGB) ? .sRGB
      : equal(t, kCVImageBufferTransferFunction_Linear) ? .linear
      : equal(t, kCVImageBufferTransferFunction_ITU_R_709_2) || equal(t, kCVImageBufferTransferFunction_ITU_R_2020)
        ? .bt709 : nil
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
    // Primaries are read on their own, never inferred from the transfer: an HLG or
    // PQ buffer may carry BT.709 primaries. Unlisted ones stay unlabelled.
    let p = attachment(kCVImageBufferColorPrimariesKey)
    let primaries: ColorPrimaries? =
      equal(p, kCVImageBufferColorPrimaries_ITU_R_709_2) ? .rec709
      : equal(p, kCVImageBufferColorPrimaries_ITU_R_2020) ? .rec2020
      : equal(p, kCVImageBufferColorPrimaries_P3_D65) ? .displayP3 : nil
    return SignalDescription(
      range: range, matrix: matrix, chromaSiting: centred ? .center : .left,
      encoding: transfer.map { .display($0) } ?? untaggedTransfer,
      chromaVerticalSiting: vertical, primaries: primaries)
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

  /// The clean aperture from `kCVImageBufferCleanApertureKey`, in pixels from the
  /// top-left corner, clipped to the frame; nil when absent, not finite, or under a
  /// pixel once clipped. CoreVideo stores the aperture's size and the offset of its
  /// centre from the frame's centre, x to the right and y down (ISO/IEC 14496-12
  /// `clap`: pcY = vertOff + (height − 1) / 2), so the top edge is
  /// (height − apertureHeight) / 2 + verticalOffset, which is what
  /// `CVImageBufferGetCleanRect` returns once its lower-left origin is flipped.
  /// Reads CF values without bridging; CoreVideo itself allocates a small block to
  /// hand out a dictionary attachment (macOS 27), so read it once per format, not
  /// per frame, where that matters.
  public static func cleanAperture(of pixelBuffer: CVPixelBuffer) -> MonitorRect? {
    guard let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, nil),
      CFGetTypeID(value) == CFDictionaryGetTypeID()
    else { return nil }
    let dictionary = unsafeDowncast(value, to: CFDictionary.self)
    let w = spacing(dictionary, kCVImageBufferCleanApertureWidthKey)
    let h = spacing(dictionary, kCVImageBufferCleanApertureHeightKey)
    let dx = spacing(dictionary, kCVImageBufferCleanApertureHorizontalOffsetKey)
    let dy = spacing(dictionary, kCVImageBufferCleanApertureVerticalOffsetKey)
    let fw = Double(CVPixelBufferGetWidth(pixelBuffer)), fh = Double(CVPixelBufferGetHeight(pixelBuffer))
    guard w.isFinite, h.isFinite, dx.isFinite, dy.isFinite, w > 0, h > 0 else { return nil }
    let rect = MonitorRect(x: (fw - w) / 2 + dx, y: (fh - h) / 2 + dy, width: w, height: h)
      .intersection(MonitorRect(x: 0, y: 0, width: fw, height: fh))
    return rect.width >= 1 && rect.height >= 1 ? rect : nil
  }

  /// The geometry of `pixelBuffer` (size, pixel aspect ratio, clean aperture) without
  /// mapping any texture: for sizing a layer on the main thread, or once per format
  /// for `MonitorTextureCache.frame(_:signal:geometry:owner:now:)`. MonitorKit
  /// allocates nothing here; CoreVideo allocates a small block for each dictionary
  /// attachment present (clean aperture, pixel aspect ratio) on macOS 27.
  public static func geometry(of pixelBuffer: CVPixelBuffer) -> MonitorFrameGeometry {
    MonitorFrameGeometry(
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
      pixelAspectRatio: pixelAspectRatio(of: pixelBuffer), cleanAperture: cleanAperture(of: pixelBuffer))
  }

  /// Horizontal over vertical spacing from the pixel aspect attachment: 1 when the
  /// buffer has none, 0 when it has one that is broken (not a dictionary, a spacing
  /// missing, zero, negative or not a number, or a ratio that is not finite), which
  /// the pass reports as `MonitorUnavailableReason.unsupportedGeometry`.
  static func pixelAspectRatio(of pixelBuffer: CVPixelBuffer) -> Double {
    guard let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil) else { return 1 }
    guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { return 0 }
    let dictionary = unsafeDowncast(value, to: CFDictionary.self)
    let h = spacing(dictionary, kCVImageBufferPixelAspectRatioHorizontalSpacingKey)
    let v = spacing(dictionary, kCVImageBufferPixelAspectRatioVerticalSpacingKey)
    return h > 0 && v > 0 && (h / v).isFinite ? h / v : 0
  }

  private static func spacing(_ dictionary: CFDictionary, _ key: CFString) -> Double {
    guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return 0 }
    let object = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    guard CFGetTypeID(object) == CFNumberGetTypeID() else { return 0 }
    var value = 0.0
    return CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .doubleType, &value) ? value : 0
  }

  /// Wraps an IOSurface-backed pixel buffer through the host's texture cache.
  /// No pixels are copied. `signal` overrides what the attachments say; the pixel
  /// aspect ratio and the clean aperture come from the attachments.
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
      pixelAspectRatio: pixelAspectRatio(of: pixelBuffer), retained: wrappers,
      cleanAperture: cleanAperture(of: pixelBuffer))
  }
}

/// One set of a feed's Freeze planes, shared by the frames frozen into it, or one
/// `MonitorTextureCache` entry, shared by the frames made over it. The owner marks
/// it released when it lets the planes go, so a frame still held can be made
/// resident again (`MonitorFrame.keepResidentIfReleased(in:)`).
final class FrozenPlanes: Sendable {
  let released = Atomic<Bool>(false)

  /// Marks the planes let go, before their retirement reads the submission counter.
  func markReleased() { released.store(true, ordering: .sequentiallyConsistent) }
}
