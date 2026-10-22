import Foundation

/// Chroma resolution of a Y'CbCr layout.
public enum ChromaSubsampling: String, Codable, Sendable, CaseIterable {
  case s444, s422, s420
}

/// How the pixels of a frame are stored. Every layout can be read by the
/// monitor; the host's textures are used as they are, never copied.
public enum PixelLayout: Hashable, Codable, Sendable {
  /// Packed 10-bit 4:2:2. One `rgba32Uint` texel holds one 6-pixel group.
  case v210
  /// Packed 8-bit 4:2:2, Cb Y0 Cr Y1 ('2vuy'). One `rgba8Uint` texel per 2 pixels.
  case uyvy8
  /// Packed 8-bit 4:2:2, Y0 Cb Y1 Cr ('yuvs'). One `rgba8Uint` texel per 2 pixels.
  case yuyv8
  /// Y plane plus interleaved CbCr plane. 8-bit uses `r8Unorm`/`rg8Unorm`;
  /// deeper samples are high-aligned in 16 bits (`r16Unorm`/`rg16Unorm`).
  case biplanar(ChromaSubsampling, bitDepth: Int)
  /// One RGB(A) texture: BGRA8/RGBA8 (8), RGB10A2 (10), RGBA16 unorm (16) or float.
  case rgb(bitDepth: Int, float: Bool)

  public static let nv12 = PixelLayout.biplanar(.s420, bitDepth: 8)
  public static let p010 = PixelLayout.biplanar(.s420, bitDepth: 10)
  public static let p210 = PixelLayout.biplanar(.s422, bitDepth: 10)
  public static let p410 = PixelLayout.biplanar(.s444, bitDepth: 10)
  public static let bgra8 = PixelLayout.rgb(bitDepth: 8, float: false)
  public static let rgb10a2 = PixelLayout.rgb(bitDepth: 10, float: false)
  public static let rgba16Float = PixelLayout.rgb(bitDepth: 16, float: true)
  public static let rgba32Float = PixelLayout.rgb(bitDepth: 32, float: true)

  public var isRGB: Bool { if case .rgb = self { return true } else { return false } }
  public var isFloat: Bool { if case .rgb(_, true) = self { return true } else { return false } }

  /// Bits per sample as stored.
  public var bitDepth: Int {
    switch self {
    case .v210: return 10
    case .uyvy8, .yuyv8: return 8
    case .biplanar(_, let depth): return depth
    case .rgb(let depth, _): return depth
    }
  }

  public var subsampling: ChromaSubsampling {
    switch self {
    case .v210, .uyvy8, .yuyv8: return .s422
    case .biplanar(let s, _): return s
    case .rgb: return .s444
    }
  }

  /// Compares without building collections, so per-frame validation allocates nothing.
  public var isValid: Bool {
    switch self {
    case .v210, .uyvy8, .yuyv8: return true
    case .biplanar(_, let depth): return depth == 8 || depth == 10 || depth == 12 || depth == 16
    case .rgb(let depth, let float): return float ? depth == 16 || depth == 32 : depth == 8 || depth == 10 || depth == 16
    }
  }
}

/// Horizontal chroma position for subsampled Y'CbCr.
public enum ChromaSiting: String, Codable, Sendable, CaseIterable {
  /// Co-sited with the even luma sample (SMPTE 4:2:2, MPEG-2 4:2:0 "left").
  case left
  /// Midway between luma samples (MPEG-1/JPEG).
  case center
}

/// Vertical chroma position for 4:2:0 (ITU-T H.273 chroma sample location types:
/// 0 and 1 are centred, 2 and 3 top, 4 and 5 bottom). Ignored for 4:2:2 and 4:4:4.
public enum ChromaVerticalSiting: String, Codable, Sendable, CaseIterable {
  /// Midway between the two luma rows (MPEG-2, H.264 default).
  case center
  /// Co-sited with the even luma row (BT.2020/HDR HEVC "top-left", type 2).
  case top
  /// Co-sited with the odd luma row (types 4 and 5).
  case bottom

  /// The chroma row's position relative to midway, in luma rows: chroma row j
  /// sits at luma row 2j + 0.5 + offset.
  public var offset: Double {
    switch self {
    case .center: return 0
    case .top: return -0.5
    case .bottom: return 0.5
    }
  }
}

/// Camera log curves. Each case has a CPU reference in `LogCurve.decode` and
/// a matching MSL implementation. Add other makers' curves here.
public enum LogCurve: String, Codable, Sendable, CaseIterable {
  case sLog3
  case arriLogC3
  case arriLogC4

  /// The curve's signal value from a range-expanded sample of a `bitDepth`
  /// container (10 for float). S-Log3 is defined on 10-bit codes whatever the
  /// container (Sony technical summary), so a legal container carries
  /// code / 1023 as-is. ARRI LogC fills the container's nominal range (ARRI's
  /// legal and full false-colour tables: legal code = 64 + 876 t, full code =
  /// 1023 t), so the expanded value is the signal, except when full-range codes
  /// were squeezed into the legal range and then labelled full.
  public func signal(expanded: Double, range: CodeRange, transport: LogTransport, bitDepth: Int = 10) -> Double {
    switch self {
    case .sLog3:
      return DecodeReference.nativeLog(expanded: expanded, range: range, transport: transport, bitDepth: bitDepth)
    case .arriLogC3, .arriLogC4:
      return range == .full && transport == .fullRescaledToLegal
        ? DecodeReference.unsqueezeLegal(expanded: expanded, bitDepth: bitDepth) : expanded
    }
  }

  /// Normalized native code (code / 1023) to scene-linear reflectance.
  public func decode(_ native: Double) -> Double? {
    switch self {
    case .sLog3: return ColorMath.sLog3Decode(native)
    case .arriLogC3:
      // ARRI LogC3 EI800 (ALEXA, 2017 white paper).
      guard native.isFinite else { return nil }
      let cut = 0.010591, a = 5.555556, b = 0.052272, c = 0.247190, d = 0.385537
      let e = 5.367655, f = 0.092809
      return native > e * cut + f ? (pow(10, (native - d) / c) - b) / a : (native - f) / e
    case .arriLogC4:
      // ARRI LogC4 (ALEXA 35 specification, 2022).
      guard native.isFinite else { return nil }
      let a = (pow(2.0, 18) - 16) / 117.45, b = (1023 - 95) / 1023.0, c = 95 / 1023.0
      let s = (7 * log(2.0) * pow(2.0, 7 - 14 * c / b)) / (a * b)
      let t = (pow(2.0, 14 * (-c / b) + 6) - 64) / a
      return native >= 0 ? (pow(2, 14 * (native - c) / b + 6) - 64) / a : native * s + t
    }
  }
}

/// The scene-referred meaning of a log signal: curve, primaries and how the
/// camera's native codes were carried in the transport.
public struct LogEncoding: Hashable, Codable, Sendable {
  public var curve: LogCurve
  public var gamut: ColorGamut
  /// `fullRescaledToLegal`: the camera's full-range codes were squeezed into
  /// the legal range (64–940 at 10 bits) by a recorder or converter. A full
  /// container so labelled is assumed squeezed into its own depth's legal range
  /// (16s…235s, s = 2^(n-8)). A container's range flag alone does not establish this.
  public var transport: LogTransport

  public init(curve: LogCurve, gamut: ColorGamut, transport: LogTransport = .native) {
    self.curve = curve
    self.gamut = gamut
    self.transport = transport
  }

  public static let sLog3SGamut3Cine = LogEncoding(curve: .sLog3, gamut: .sGamut3Cine)
  public static let sLog3SGamut3 = LogEncoding(curve: .sLog3, gamut: .sGamut3)

  /// Profile identifiers shared with saved settings and the false-color references.
  public var profileID: String? {
    switch (curve, gamut) {
    case (.sLog3, .sGamut3Cine): return "sony-slog3-sgamut3cine"
    case (.sLog3, .sGamut3): return "sony-slog3-sgamut3"
    case (.arriLogC3, _): return ARRIFalseColorProfile.logC3EI800.rawValue
    case (.arriLogC4, _): return ARRIFalseColorProfile.alexa35LogC4EI800.rawValue
    default: return nil
    }
  }

  public init?(profileID: String, transport: LogTransport = .native) {
    switch profileID {
    case "sony-slog3-sgamut3cine": self.init(curve: .sLog3, gamut: .sGamut3Cine, transport: transport)
    case "sony-slog3-sgamut3": self.init(curve: .sLog3, gamut: .sGamut3, transport: transport)
    case ARRIFalseColorProfile.logC3EI800.rawValue:
      self.init(curve: .arriLogC3, gamut: .arriWideGamut3, transport: transport)
    case ARRIFalseColorProfile.alexa35LogC4EI800.rawValue:
      self.init(curve: .arriLogC4, gamut: .arriWideGamut4, transport: transport)
    default: return nil
    }
  }
}

public enum LogTransport: String, Codable, Sendable, CaseIterable {
  case native, fullRescaledToLegal
}

/// Display-referred transfer functions.
public enum DisplayTransfer: String, Codable, Sendable, CaseIterable {
  case bt709, sRGB, pq, hlg, linear

  /// Relative light for exposure in stops, scaled so the 18% grey card is 0.18:
  /// - `bt709`: the ITU-R BT.709 inverse OETF (scene light).
  /// - `sRGB`: the IEC 61966-2-1 decode.
  /// - `pq`: SMPTE ST 2084 display light, with ITU-R BT.2408's grey card (26 cd/m²) at 0.18.
  /// - `hlg`: the ITU-R BT.2100 inverse OETF (scene light), with BT.2408's grey
  ///   card (38% signal) at 0.18.
  /// - `linear`: the value itself.
  public func exposureLinear(_ v: Double) -> Double {
    switch self {
    case .bt709: return ColorMath.bt709Linear(v)
    case .sRGB: return ColorMath.sRGBDecode(v)
    case .pq: return ColorMath.pqNits(max(0, v)) * (0.18 / ColorMath.bt2408GreyNits)
    case .hlg: return ColorMath.hlgInverseOETF(max(0, v)) * (0.18 / ColorMath.hlgInverseOETF(ColorMath.bt2408HLGGreySignal))
    case .linear: return v
    }
  }
}

/// What the code values of a frame mean.
public enum SignalEncoding: Hashable, Codable, Sendable {
  case display(DisplayTransfer)
  case log(LogEncoding)
  /// Unlabelled. Shown as-is; tools that need a calibrated signal report unavailable.
  case unknown

  public var log: LogEncoding? { if case .log(let value) = self { return value } else { return nil } }
}

/// Everything needed to turn a frame's codes into normalized values.
public struct SignalDescription: Hashable, Codable, Sendable {
  public var range: CodeRange
  public var matrix: YCbCrMatrix
  /// Horizontal chroma siting.
  public var chromaSiting: ChromaSiting
  public var encoding: SignalEncoding
  /// Vertical chroma siting of 4:2:0 frames.
  public var chromaVerticalSiting: ChromaVerticalSiting
  /// Colour primaries of a display-referred signal; nil when unlabelled
  /// (`effectivePrimaries` then infers them). Log signals carry theirs in the gamut.
  public var primaries: ColorPrimaries?

  public init(
    range: CodeRange = .legal, matrix: YCbCrMatrix = .bt709, chromaSiting: ChromaSiting = .left,
    encoding: SignalEncoding = .display(.bt709), chromaVerticalSiting: ChromaVerticalSiting = .center,
    primaries: ColorPrimaries? = nil
  ) {
    self.range = range
    self.matrix = matrix
    self.chromaSiting = chromaSiting
    self.encoding = encoding
    self.chromaVerticalSiting = chromaVerticalSiting
    self.primaries = primaries
  }

  /// The labelled primaries, else BT.2020 for PQ, HLG or a BT.2020 matrix (BT.2100
  /// signals are BT.2020 by definition) and BT.709 otherwise.
  public var effectivePrimaries: ColorPrimaries {
    if let primaries { return primaries }
    if case .display(let t) = encoding, t == .pq || t == .hlg { return .rec2020 }
    return matrix == .bt2020 ? .rec2020 : .rec709
  }

  /// PQ or HLG.
  public var isHDR: Bool {
    if case .display(let t) = encoding { return t == .pq || t == .hlg }
    return false
  }

  private enum CodingKeys: String, CodingKey {
    case range, matrix, chromaSiting, encoding, chromaVerticalSiting, primaries
  }
  /// Lenient, like every persisted MonitorKit setting, so a description saved by
  /// another version cannot invalidate the host's other settings: a missing or
  /// unknown field decodes as `rec709`'s (an unknown encoding as `.unknown`,
  /// which tools treat as unlabelled). Descriptions saved before vertical siting
  /// or primaries existed decode as centred and unlabelled.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = SignalDescription.rec709
    self.init(
      range: c.lenient(.range, d.range), matrix: c.lenient(.matrix, d.matrix),
      chromaSiting: c.lenient(.chromaSiting, d.chromaSiting),
      encoding: c.lenient(.encoding, SignalEncoding.unknown),
      chromaVerticalSiting: c.lenient(.chromaVerticalSiting, d.chromaVerticalSiting),
      primaries: c.lenient(.primaries, ColorPrimaries?.none))
  }

  public static let rec709 = SignalDescription()
}

extension CodeRange {
  /// Luma black, luma span, chroma centre and chroma span in codes of `bitDepth`.
  /// Matches `normalizeLuma`/`normalizeChroma` exactly.
  public func levels(bitDepth: Int) -> (black: Double, span: Double, center: Double, chromaSpan: Double) {
    let scale = pow(2, Double(bitDepth - 8))
    let maximum = pow(2, Double(bitDepth)) - 1
    let center = pow(2, Double(bitDepth - 1))
    return self == .full
      ? (0, maximum, center, maximum) : (16 * scale, 219 * scale, center, 224 * scale)
  }
}
