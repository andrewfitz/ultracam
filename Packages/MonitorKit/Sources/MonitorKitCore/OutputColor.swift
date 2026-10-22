import Foundation

/// The colour of the render target a surface draws into: what its pixel values mean.
/// Set it once per layer configuration; changing `headroom` costs nothing.
public struct MonitorOutputColor: Codable, Hashable, Sendable {
  public enum SDRTransfer: String, Codable, Sendable, CaseIterable {
    /// ITU-R BT.1886 with a black of 0: V = L^(1/2.4). The reference display for BT.709 video.
    case bt1886
    /// IEC 61966-2-1.
    case sRGB
    /// A pure 2.2 power.
    case gamma22
  }

  public enum Encoding: Hashable, Codable, Sendable {
    /// The picture's own non-linear R'G'B', unchanged: the signal's, or a display
    /// transform's result. The host tags the layer with that colour space
    /// (`layer(for:displayTransform:)`) and Core Animation colour-matches and tone-maps
    /// it. Pixel-identical to the picture before output colour existed.
    case signalNative
    /// Display-encoded SDR in `primaries`; 1.0 is graphics white.
    case sdr(SDRTransfer)
    /// EDR linear light in `primaries`: 1.0 is SDR/graphics white, values above use
    /// the display's headroom, negative values keep out-of-gamut colours. For
    /// `rgba16Float` layers in an extended linear colour space.
    case extendedLinear
    /// Absolute SMPTE ST 2084, BT.2100 PQ.
    case pq
    /// ITU-R BT.2100 HLG, encoded for its 1000 cd/m² reference display (the
    /// display applies its own OOTF for its peak).
    case hlg

    public var isHDR: Bool { self == .extendedLinear || self == .pq || self == .hlg }
  }

  public var primaries: ColorPrimaries
  public var encoding: Encoding
  /// Graphics white in cd/m²: where SDR white and the overlays land in an HDR
  /// encoding. 203 by default (Report ITU-R BT.2408-8 Table 1).
  public var referenceWhite: Double
  /// Nominal peak of the HLG display in cd/m² (BT.2100 Table 5's LW), 1000 by
  /// default. HLG is scene-referred, so the signal does not depend on it: MonitorKit
  /// always encodes HLG for the 1000 cd/m² reference display (Report ITU-R BT.2408-8
  /// §6.2), keeping 75% HLG graphics white. It is only the target PQ passthrough
  /// into HLG rolls highlights off to (at most 1000).
  public var hlgNominalPeak: Double
  /// The display's current EDR headroom (peak over SDR white, ≥ 1), e.g. from
  /// `NSScreen.maximumExtendedDynamicRangeColorComponentValue`. A uniform: changing
  /// it rebuilds nothing. Only extended linear output with HDR passthrough reads it.
  public var headroom: Double

  public init(
    primaries: ColorPrimaries = .rec709, encoding: Encoding = .signalNative, referenceWhite: Double = 203,
    hlgNominalPeak: Double = 1000, headroom: Double = 1
  ) {
    self.primaries = primaries
    self.encoding = encoding
    self.referenceWhite = referenceWhite
    self.hlgNominalPeak = hlgNominalPeak
    self.headroom = headroom
  }

  public static let signalNative = MonitorOutputColor()

  private enum CodingKeys: String, CodingKey { case primaries, encoding, referenceWhite, hlgNominalPeak, headroom }
  /// Malformed or missing values decode as defaults.
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    primaries = c.lenient(.primaries, primaries)
    encoding = c.lenient(.encoding, encoding)
    referenceWhite = c.lenient(.referenceWhite, referenceWhite)
    hlgNominalPeak = c.lenient(.hlgNominalPeak, hlgNominalPeak)
    headroom = c.lenient(.headroom, headroom)
    self = normalized()
  }

  /// Values clamped to their ranges, non-finite values reset.
  public func normalized() -> MonitorOutputColor {
    func b(_ x: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
      x.isFinite ? min(r.upperBound, max(r.lowerBound, x)) : fallback
    }
    var v = self
    v.referenceWhite = b(referenceWhite, 48...1000, 203)
    v.hlgNominalPeak = b(hlgNominalPeak, 100...10_000, 1000)
    v.headroom = b(headroom, 1...64, 1)
    return v
  }

  /// The settings a pipeline depends on: everything but the headroom.
  public var withoutHeadroom: MonitorOutputColor {
    var v = self
    v.headroom = 1
    return v
  }

  /// Mirrors Ultracam's monitor picture rules: the signal's own encoding, tagged
  /// with its colour space. A declared camera log profile is a code-value Rec.709
  /// view unless a display transform is chosen. Primaries come from the signal's
  /// label, independently of its transfer (a PQ signal labelled BT.709 stays BT.709).
  /// Pair it with `layer(for:displayTransform:monitorStageHasLUT:)`.
  public static func recommended(
    for signal: SignalDescription, displayTransform: DisplayTransform = .none, monitorStageHasLUT: Bool = false
  ) -> MonitorOutputColor {
    let layer = signalNative.layer(
      for: signal, displayTransform: displayTransform, monitorStageHasLUT: monitorStageHasLUT)
    return MonitorOutputColor(primaries: layer.primaries, encoding: .signalNative)
  }

  /// The layer this output needs: pixel format, colour space, EDR. For
  /// `signalNative` it describes the picture's encoding for `signal` (after
  /// `displayTransform`; a LUT on the monitor stage makes it Rec.709 SDR, and no
  /// transform runs then); otherwise the signal does not matter. Re-tag when these change.
  public func layer(
    for signal: SignalDescription = .rec709, displayTransform: DisplayTransform = .none,
    monitorStageHasLUT: Bool = false
  ) -> MonitorLayerColor {
    switch encoding {
    case .signalNative:
      let picture = MonitorColorPipeline.nativePicture(
        signal: signal, transform: displayTransform, monitorStageHasLUT: monitorStageHasLUT)
      switch picture.transfer {
      case .pq: return MonitorLayerColor(primaries: picture.primaries, kind: .pq)
      case .hlg: return MonitorLayerColor(primaries: picture.primaries, kind: .hlg)
      case .linear: return MonitorLayerColor(primaries: picture.primaries, kind: .extendedLinear)
      case .sRGB: return MonitorLayerColor(primaries: picture.primaries, kind: .sdr(.sRGB))
      default: return MonitorLayerColor(primaries: picture.primaries, kind: .sdr(.bt1886))
      }
    case .sdr(let t): return MonitorLayerColor(primaries: primaries, kind: .sdr(t))
    case .extendedLinear: return MonitorLayerColor(primaries: primaries, kind: .extendedLinear)
    case .pq: return MonitorLayerColor(primaries: primaries, kind: .pq)
    case .hlg: return MonitorLayerColor(primaries: primaries, kind: .hlg)
    }
  }
}

/// What a `CAMetalLayer` needs for an output colour. MonitorKitUI maps it to Metal
/// and Core Graphics (`metalPixelFormat`, `cgColorSpace`, `caEDRMetadata`,
/// `apply(to:)`, `ColorSpace.cgName`).
public struct MonitorLayerColor: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case sdr(MonitorOutputColor.SDRTransfer)
    case extendedLinear, pq, hlg
  }
  public enum PixelFormat: Sendable {
    /// 10-bit SDR.
    case bgr10a2Unorm
    /// Half float, so Core Animation takes the EDR path.
    case rgba16Float
  }
  /// Named Core Graphics colour spaces (the `kCGColorSpace…` constant each stands for).
  public enum ColorSpace: String, Sendable, CaseIterable {
    case itur709 = "kCGColorSpaceITUR_709"
    case itur2020 = "kCGColorSpaceITUR_2020"
    case sRGB = "kCGColorSpaceSRGB"
    case displayP3 = "kCGColorSpaceDisplayP3"
    case itur2020sRGBGamma = "kCGColorSpaceITUR_2020_sRGBGamma"
    case extendedLinearSRGB = "kCGColorSpaceExtendedLinearSRGB"
    case extendedLinearDisplayP3 = "kCGColorSpaceExtendedLinearDisplayP3"
    case extendedLinearITUR2020 = "kCGColorSpaceExtendedLinearITUR_2020"
    case itur709PQ = "kCGColorSpaceITUR_709_PQ"
    case displayP3PQ = "kCGColorSpaceDisplayP3_PQ"
    case itur2100PQ = "kCGColorSpaceITUR_2100_PQ"
    case itur709HLG = "kCGColorSpaceITUR_709_HLG"
    case displayP3HLG = "kCGColorSpaceDisplayP3_HLG"
    case itur2100HLG = "kCGColorSpaceITUR_2100_HLG"
  }
  /// Suggested `CAEDRMetadata`.
  public enum EDRMetadata: Equatable, Sendable {
    /// `CAEDRMetadata.hdr10(minLuminance:maxLuminance:opticalOutputScale:)`.
    case hdr10(minLuminance: Double, maxLuminance: Double, opticalOutputScale: Double)
    /// `CAEDRMetadata.hlg`.
    case hlg
  }

  public let primaries: ColorPrimaries
  public let kind: Kind

  public init(primaries: ColorPrimaries, kind: Kind) {
    self.primaries = primaries
    self.kind = kind
  }

  public var pixelFormat: PixelFormat { kind == .extendedLinear || kind == .pq || kind == .hlg ? .rgba16Float : .bgr10a2Unorm }
  public var wantsExtendedDynamicRange: Bool { pixelFormat == .rgba16Float }

  /// Nil where Core Graphics has no named space (2.2 on any primaries): create one
  /// from an ICC profile. BT.1886 is tagged with the closest named space, as video
  /// is: ITU-R BT.709/2020 (Core Graphics decodes both as a pure 2.4 power), and
  /// Display P3 for P3 primaries (a P3-labelled BT.709 signal, e.g. a screen
  /// recording). Display P3 decodes with the sRGB curve, not 2.4 (V = 0.1 reads
  /// 0.0100, not 0.0040), so that pair is approximate; MonitorKitUI's
  /// `cgColorSpace` builds an exact power-law ICC space for it instead.
  public var colorSpace: ColorSpace? {
    switch (kind, primaries) {
    case (.sdr(.bt1886), .rec709): return .itur709
    case (.sdr(.bt1886), .rec2020): return .itur2020
    case (.sdr(.bt1886), .displayP3): return .displayP3
    case (.sdr(.sRGB), .rec709): return .sRGB
    case (.sdr(.sRGB), .displayP3): return .displayP3
    case (.sdr(.sRGB), .rec2020): return .itur2020sRGBGamma
    case (.extendedLinear, .rec709): return .extendedLinearSRGB
    case (.extendedLinear, .displayP3): return .extendedLinearDisplayP3
    case (.extendedLinear, .rec2020): return .extendedLinearITUR2020
    case (.pq, .rec709): return .itur709PQ
    case (.pq, .displayP3): return .displayP3PQ
    case (.pq, .rec2020): return .itur2100PQ
    case (.hlg, .rec709): return .itur709HLG
    case (.hlg, .displayP3): return .displayP3HLG
    case (.hlg, .rec2020): return .itur2100HLG
    default: return nil
    }
  }

  /// HDR10 defaults for PQ content without mastering metadata (1000 cd/m² peak,
  /// optical output scale 100, as Ultracam sets), the HLG metadata for HLG, none
  /// for SDR or extended linear (MonitorKit rolls highlights off to the headroom itself).
  public var edrMetadata: EDRMetadata? {
    switch kind {
    case .pq: return .hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)
    case .hlg: return .hlg
    default: return nil
    }
  }
}
