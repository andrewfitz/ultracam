import CoreGraphics
import Metal
import MonitorKitCore
import QuartzCore

/// Maps Core's description of a layer's colour onto Metal, Core Graphics and
/// Core Animation.
extension MonitorLayerColor {
  public var metalPixelFormat: MTLPixelFormat {
    switch pixelFormat {
    case .bgr10a2Unorm: return .bgr10a2Unorm
    case .rgba16Float: return .rgba16Float
    }
  }

  /// The named Core Graphics space when its curve is the one the pass writes,
  /// else an exact power-law one (`calibrated`): BT.1886 is a pure 2.4 power with
  /// a black of 0 (ITU-R BT.1886 Annex 1 with Lb = 0) and gamma 2.2 a pure 2.2
  /// power, on the primaries' RP 177 matrix with a D65 white.
  ///
  /// BT.1886 on Display P3 is calibrated too: `kCGColorSpaceDisplayP3` (which
  /// Core names for it) decodes with the sRGB curve, so shadows written as a 2.4
  /// power would show about 2.5 times too bright (V = 0.1: 0.0100 instead of 0.0040).
  public var cgColorSpace: CGColorSpace {
    if let name = namedColorSpace, let space = CGColorSpace(name: name.cgName) { return space }
    return Self.calibrated(primaries: primaries, gamma: kind == .sdr(.gamma22) ? 2.2 : 2.4)
  }

  /// Whether `cgColorSpace` is a named Core Graphics space (false: calibrated).
  public var hasNamedColorSpace: Bool { namedColorSpace != nil }

  /// Core's named space, unless its curve differs from the encoding's.
  var namedColorSpace: ColorSpace? {
    if kind == .sdr(.bt1886), primaries == .displayP3 { return nil }
    return colorSpace
  }

  /// The suggested `CAEDRMetadata`, or nil for SDR and extended linear.
  public var caEDRMetadata: CAEDRMetadata? {
    switch edrMetadata {
    case .hdr10(let minimum, let maximum, let scale)?:
      return CAEDRMetadata.hdr10(
        minLuminance: Float(minimum), maxLuminance: Float(maximum), opticalOutputScale: Float(scale))
    case .hlg?: return CAEDRMetadata.hlg
    case nil: return nil
    }
  }

  /// Configures `layer` for this colour: pixel format, colour space, EDR and its
  /// metadata. Set it when the colour changes, not per frame: a new pixel format
  /// makes Core Animation reallocate the drawables.
  public func apply(to layer: CAMetalLayer) {
    let format = metalPixelFormat
    if layer.pixelFormat != format { layer.pixelFormat = format }
    let space = cgColorSpace
    if layer.colorspace.map({ $0 != space }) ?? true { layer.colorspace = space }
    if layer.wantsExtendedDynamicRangeContent != wantsExtendedDynamicRange {
      layer.wantsExtendedDynamicRangeContent = wantsExtendedDynamicRange
    }
    layer.edrMetadata = caEDRMetadata
  }

  /// An RGB space of `primaries` (D65 white) whose channels decode as an exact
  /// `gamma` power. The layer's cases are made once, so re-applying a colour keeps
  /// the same object.
  ///
  /// Built as an ICC v4 profile with parametric curves of type 3 and no linear
  /// segment (ICC.1:2022 §10.18: Y = (aX + b)^g for X ≥ d, with a = 1, b = c = d = 0).
  /// `CGColorSpace(calibratedRGBWhitePoint:…)` and type-0 gamma curves are not
  /// exact: ColorSync gives them a slope-1/16 toe, which lifts V = 0.1 at 2.4 from
  /// 0.0040 to 0.0063 of white.
  static func calibrated(primaries: ColorPrimaries, gamma: Double) -> CGColorSpace {
    if gamma == 2.4 || gamma == 2.2 {
      var i = 0
      while i < calibratedSpaces.count {
        let c = calibratedSpaces[i]
        if c.primaries == primaries, c.gamma == gamma { return c.space }
        i += 1
      }
    }
    return makeCalibrated(primaries: primaries, gamma: gamma)
  }

  private static let calibratedSpaces: [(primaries: ColorPrimaries, gamma: Double, space: CGColorSpace)] =
    ColorPrimaries.allCases.flatMap { p in [2.2, 2.4].map { (p, $0, makeCalibrated(primaries: p, gamma: $0)) } }

  private static func makeCalibrated(primaries: ColorPrimaries, gamma: Double) -> CGColorSpace {
    CGColorSpace(iccData: ICCProfile.powerRGB(primaries: primaries, gamma: gamma) as CFData)
      ?? CGColorSpace(name: CGColorSpace.itur_709)!
  }
}

/// A minimal ICC v4 display profile (ICC.1:2022): header, description, copyright,
/// media white, the D65-to-D50 adaptation and the three colorants and curves.
enum ICCProfile {
  /// The profile connection space's illuminant, D50 (ICC.1:2022 §7.2.16).
  static let d50 = ColorRGB(r: 0.9642, g: 1.0, b: 0.8249)
  /// Bradford cone response (ICC.1:2022 Annex E.3).
  static let bradford = ColorMatrix(
    red: ColorRGB(r: 0.8951, g: 0.2664, b: -0.1614), green: ColorRGB(r: -0.7502, g: 1.7135, b: 0.0367),
    blue: ColorRGB(r: 0.0389, g: -0.0685, b: 1.0296))

  /// Bradford adaptation from `white` to D50.
  static func adaptation(from white: ColorRGB) -> ColorMatrix {
    let s = bradford.apply(white), d = bradford.apply(d50)
    let scale = ColorMatrix(
      red: ColorRGB(r: d.r / s.r, g: 0, b: 0), green: ColorRGB(r: 0, g: d.g / s.g, b: 0),
      blue: ColorRGB(r: 0, g: 0, b: d.b / s.b))
    return bradford.inverse.concatenating(scale).concatenating(bradford)
  }

  static func powerRGB(primaries: ColorPrimaries, gamma: Double) -> Data {
    let toXYZ = primaries.toXYZ
    let chad = adaptation(from: toXYZ.apply(ColorRGB(r: 1, g: 1, b: 1)))
    // Colorants are the primaries' XYZ adapted to D50: the columns of chad · M.
    let m = chad.concatenating(toXYZ)
    let curve = para(gamma)
    let tags: [(String, [UInt8])] = [
      ("desc", mluc("MonitorKit \(primaries.rawValue) gamma \(gamma)")), ("cprt", mluc("No copyright")),
      ("wtpt", xyz(d50)), ("chad", sf32(chad)),
      ("rXYZ", xyz(ColorRGB(r: m.red.r, g: m.green.r, b: m.blue.r))),
      ("gXYZ", xyz(ColorRGB(r: m.red.g, g: m.green.g, b: m.blue.g))),
      ("bXYZ", xyz(ColorRGB(r: m.red.b, g: m.green.b, b: m.blue.b))),
      ("rTRC", curve), ("gTRC", curve), ("bTRC", curve),
    ]
    var table = u32(UInt32(tags.count))
    var data: [UInt8] = []
    var offset = 128 + 4 + 12 * tags.count
    for (name, bytes) in tags {
      table += sig(name) + u32(UInt32(offset)) + u32(UInt32(bytes.count))
      var padded = bytes
      while padded.count % 4 != 0 { padded.append(0) }
      data += padded
      offset += padded.count
    }
    var header = u32(UInt32(128 + table.count + data.count)) + zeros(4)
    header += [4, 0x40, 0, 0] + sig("mntr") + sig("RGB ") + sig("XYZ ") + zeros(12)
    header += sig("acsp") + sig("APPL") + zeros(4 + 4 + 4 + 8 + 4) + xyz(d50).suffix(12)
    header += zeros(128 - header.count)
    return Data(header + table + data)
  }

  static func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
  static func s15Fixed16(_ v: Double) -> [UInt8] { u32(UInt32(bitPattern: Int32((v * 65536).rounded()))) }
  static func sig(_ s: String) -> [UInt8] { Array(s.utf8) }
  static func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
  static func xyz(_ c: ColorRGB) -> [UInt8] { sig("XYZ ") + zeros(4) + s15Fixed16(c.r) + s15Fixed16(c.g) + s15Fixed16(c.b) }
  static func para(_ gamma: Double) -> [UInt8] {
    sig("para") + zeros(4) + [0, 3, 0, 0] + s15Fixed16(gamma) + s15Fixed16(1) + zeros(12)
  }
  static func sf32(_ m: ColorMatrix) -> [UInt8] {
    sig("sf32") + zeros(4) + [m.red, m.green, m.blue].flatMap { s15Fixed16($0.r) + s15Fixed16($0.g) + s15Fixed16($0.b) }
  }
  static func mluc(_ text: String) -> [UInt8] {
    let utf16 = text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
    return sig("mluc") + zeros(4) + u32(1) + u32(12) + sig("enUS") + u32(UInt32(utf16.count)) + u32(28) + utf16
  }
}

extension MonitorLayerColor.ColorSpace {
  /// The `kCGColorSpace…` constant itself, so a name missing from the SDK fails to compile.
  public var cgName: CFString {
    switch self {
    case .itur709: return CGColorSpace.itur_709
    case .itur2020: return CGColorSpace.itur_2020
    case .sRGB: return CGColorSpace.sRGB
    case .displayP3: return CGColorSpace.displayP3
    case .itur2020sRGBGamma: return CGColorSpace.itur_2020_sRGBGamma
    case .extendedLinearSRGB: return CGColorSpace.extendedLinearSRGB
    case .extendedLinearDisplayP3: return CGColorSpace.extendedLinearDisplayP3
    case .extendedLinearITUR2020: return CGColorSpace.extendedLinearITUR_2020
    case .itur709PQ: return CGColorSpace.itur_709_PQ
    case .displayP3PQ: return CGColorSpace.displayP3_PQ
    case .itur2100PQ: return CGColorSpace.itur_2100_PQ
    case .itur709HLG: return CGColorSpace.itur_709_HLG
    case .displayP3HLG: return CGColorSpace.displayP3_HLG
    case .itur2100HLG: return CGColorSpace.itur_2100_HLG
    }
  }
}

extension MonitorOutputColor {
  /// An explicit encoding that writes what `layer` is tagged with: what a second
  /// surface sharing a signal-native surface's layer draws with.
  public func explicit(for layer: MonitorLayerColor) -> MonitorOutputColor {
    var v = self
    v.primaries = layer.primaries
    switch layer.kind {
    case .sdr(let t): v.encoding = .sdr(t)
    case .extendedLinear: v.encoding = .extendedLinear
    case .pq: v.encoding = .pq
    case .hlg: v.encoding = .hlg
    }
    return v
  }
}
