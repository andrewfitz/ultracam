import Foundation
import MonitorKitCore

public enum ScopeKind: String, Codable, Sendable, CaseIterable {
  case waveform, vectorscope, histogram
}

public enum WaveformMode: String, Codable, Sendable, CaseIterable {
  /// Y' of the stage, with the stage's luma weights.
  case luma
  /// R, G and B traces drawn on top of each other.
  case rgbOverlay
  /// R, G and B side by side.
  case rgbParade
  /// Y', Cb and Cr side by side. Chroma is offset so that neutral sits at 50%.
  case ycbcrParade

  public var channelCount: Int { self == .luma ? 1 : 3 }
  public var isParade: Bool { self == .rgbParade || self == .ycbcrParade }
}

public enum HistogramMode: String, Codable, Sendable, CaseIterable {
  case luma, rgbOverlay, rgbParade
  public var channelCount: Int { self == .luma ? 1 : 3 }
}

/// What the waveform's vertical axis (and the histogram's horizontal axis) is
/// labelled in. The bins are the same for every scale: the axis is always the
/// normalized signal level, so switching scale never re-accumulates.
public enum WaveformScale: String, Codable, Sendable, CaseIterable {
  /// 0 is black, 100 nominal white (IRE for SDR).
  case percent
  /// 10-bit code values of the frame's range.
  case codeValues
  /// SMPTE ST 2084 absolute luminance.
  case pqNits
  /// ITU-R BT.2100 HLG on a 1000-nit display.
  case hlgNits
}

public enum HistogramScale: String, Codable, Sendable, CaseIterable { case linear, logarithmic }

/// Colour-bar targets drawn on the vectorscope.
public enum VectorscopeTargets: String, Codable, Sendable, CaseIterable {
  case none, percent75, percent100, both
  public var amplitudes: [Double] {
    switch self {
    case .none: return []
    case .percent75: return [0.75]
    case .percent100: return [1]
    case .both: return [0.75, 1]
    }
  }
}

/// Y'CbCr weights for the drawn luma (waveform and histogram), the Y'CbCr
/// parade and the vectorscope. The statistics always measure the picture's stage luma.
public enum ScopeColorimetry: String, Codable, Sendable, CaseIterable {
  /// The frame's transport matrix for the source, Rec.709 after a LUT. The
  /// same rule as the picture pass's IRE, so zebras and the waveform agree.
  case auto
  case bt601, bt709, bt2020
  /// SMPTE 240M-1999 (legacy 1035i/1080i HD): Y' = 0.212 R' + 0.701 G' + 0.087 B'.
  case smpte240m

  public func matrix(source: YCbCrMatrix, lutApplied: Bool) -> YCbCrMatrix {
    switch self {
    case .auto: return lutApplied ? .bt709 : source
    case .bt601: return .bt601
    case .bt709: return .bt709
    case .bt2020: return .bt2020
    case .smpte240m: return .smpte240m
    }
  }
}

/// How bin density becomes trace brightness.
public enum ScopeIntensityCurve: String, Codable, Sendable, CaseIterable {
  /// log(1 + 16x) / log(1 + 256): sparse detail stays visible next to flat areas.
  case logarithmic
  /// (x / 16)^(1 / 2.2): closer to an analogue CRT trace.
  case gamma
}

/// The colours of the waveform's and histogram's traces.
public enum ScopeTracePalette: String, Codable, Sendable, CaseIterable {
  /// MonitorKit's colours: `ScopeTraceStyle` picks the single trace, channels
  /// are a light red, green and blue, and dense areas bloom towards white.
  case standard
  /// Ultracam's earlier MonitorTools scopes: a white single trace and
  /// R (1, 0.1, 0.1), G (0.1, 1, 0.1), B (0.1, 0.3, 1) channels (BT.709 SDR
  /// display R'G'B'), each scaled by the trace intensity without blooming.
  /// The vectorscope keeps its standard look; the Y'CbCr parade's chroma
  /// panels keep their standard colours, also without blooming.
  case ultracamLegacy
}

public enum ScopeTraceStyle: String, Codable, Sendable, CaseIterable {
  /// Green-white like a P31 phosphor for single traces; channel colours otherwise.
  case phosphor
  /// Neutral white single traces; channel colours otherwise.
  case white
  /// Vectorscope: each point in the hue it measures. Other scopes use `.phosphor`.
  case colorized
}

/// How a scope is drawn. Changing these never re-accumulates.
public struct ScopeDisplay: Codable, Equatable, Sendable {
  /// Multiplies the trace, 0…4.
  public var brightness = 1.0
  /// Multiplies bin density before the intensity curve, 0.05…20.
  public var gain = 1.0
  public var intensity: ScopeIntensityCurve = .logarithmic
  public var trace: ScopeTraceStyle = .phosphor
  /// Waveform and histogram colours; `.ultracamLegacy` overrides `trace` there.
  public var palette: ScopeTracePalette = .standard
  /// Black behind the scope, 0…1. Below 1 the scope overlays the picture.
  public var backgroundOpacity = 0.85
  public var showsGraticule = true
  public var graticuleOpacity = 0.55
  public var waveformScale: WaveformScale = .percent
  public var histogramScale: HistogramScale = .linear
  public var vectorscopeTargets: VectorscopeTargets = .both
  public var showsSkinToneLine = true
  /// Degrees counter-clockwise from +Cb. 123° is the NTSC I axis in the U/V
  /// plane (SMPTE 170M), the line most component vectorscopes draw; on a Cb/Cr
  /// plot the I-axis hue itself lies at 132.5° (BT.601) or 134.5° (BT.709).
  public var skinToneAngle = 123.0
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case brightness, gain, intensity, trace, palette, backgroundOpacity, showsGraticule, graticuleOpacity,
      waveformScale, histogramScale, vectorscopeTargets, showsSkinToneLine, skinToneAngle
  }
  public init(from decoder: Decoder) throws {
    self.init()
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
    brightness = c.scopeLenient(.brightness, brightness)
    gain = c.scopeLenient(.gain, gain)
    intensity = c.scopeLenient(.intensity, intensity)
    trace = c.scopeLenient(.trace, trace)
    palette = c.scopeLenient(.palette, palette)
    backgroundOpacity = c.scopeLenient(.backgroundOpacity, backgroundOpacity)
    showsGraticule = c.scopeLenient(.showsGraticule, showsGraticule)
    graticuleOpacity = c.scopeLenient(.graticuleOpacity, graticuleOpacity)
    waveformScale = c.scopeLenient(.waveformScale, waveformScale)
    histogramScale = c.scopeLenient(.histogramScale, histogramScale)
    vectorscopeTargets = c.scopeLenient(.vectorscopeTargets, vectorscopeTargets)
    showsSkinToneLine = c.scopeLenient(.showsSkinToneLine, showsSkinToneLine)
    skinToneAngle = c.scopeLenient(.skinToneAngle, skinToneAngle)
    self = normalized()
  }

  /// Only what the graticule geometry depends on; the rest is applied per draw.
  var graticuleKey: ScopeDisplay {
    var key = ScopeDisplay()
    key.waveformScale = waveformScale
    key.vectorscopeTargets = vectorscopeTargets
    key.showsSkinToneLine = showsSkinToneLine
    key.skinToneAngle = skinToneAngle
    return key
  }

  public func normalized() -> ScopeDisplay {
    var v = self
    v.brightness = scopeClamp(brightness, 0...4, 1)
    v.gain = scopeClamp(gain, 0.05...20, 1)
    v.backgroundOpacity = scopeClamp(backgroundOpacity, 0...1, 0.85)
    v.graticuleOpacity = scopeClamp(graticuleOpacity, 0...1, 0.55)
    v.skinToneAngle = scopeClamp(skinToneAngle, 0...360, 123)
    return v
  }
}

/// One scope: what it measures, at what resolution, and how it is drawn.
/// Changing anything but `display` takes effect on the next accumulation.
public struct ScopeSettings: Codable, Equatable, Sendable {
  public static let schemaVersion = 1

  public var kind: ScopeKind = .waveform
  public var stage: SignalStage = .output
  public var waveformMode: WaveformMode = .luma
  public var histogramMode: HistogramMode = .rgbOverlay
  /// 1, 2 or 4. Accumulated at the zoomed scale, so zoom adds real resolution.
  public var vectorscopeZoom = 1
  public var colorimetry: ScopeColorimetry = .auto
  /// Waveform bins across the whole scope (split three ways in parade), 64…4096, even.
  public var waveformColumns = 1024
  /// Waveform bins over `levelRange` (-7% to 109% by default), 64…2048.
  public var waveformLevels = 512
  /// Histogram bins over `levelRange` (-7% to 109% by default), 64…4096, even.
  public var histogramBins = 512
  /// The level span of the waveform's and histogram's bins and graticule.
  /// Ignored by the vectorscope.
  public var levelRange: ScopeLevelRange = .standard
  /// Vectorscope bins per side, 64…2048, even.
  public var vectorscopeSize = 512
  /// Pixels at or above this level, in percent, count as clipped high, per
  /// channel (R', G', B' and Y' of the stage), -20…120. The same test as the
  /// picture's clip indicators (`ClipIndicatorSettings.high`), so with equal
  /// levels and stage the clip percentages count exactly the pixels it marks.
  /// Y' here (and in the luma statistics) is the picture's stage luma whatever
  /// `colorimetry` is: the transport Y' where no LUT touched the stage, Rec.709
  /// Y' of a LUT result.
  public var clipHighPercent = 100.0
  /// Pixels at or below this level, in percent, count as clipped low, -20…120
  /// (`ClipIndicatorSettings.low`).
  public var clipLowPercent = 0.0
  public var display = ScopeDisplay()

  public init() {}
  public init(kind: ScopeKind, stage: SignalStage = .output) {
    self.kind = kind
    self.stage = stage
  }

  public static let waveformColumnRange = 64...4096
  public static let waveformLevelRange = 64...2048
  public static let histogramBinRange = 64...4096
  public static let vectorscopeSizeRange = 64...2048
  public static let vectorscopeZooms = [1, 2, 4]

  /// Channels the bins hold.
  public var channelCount: Int {
    switch kind {
    case .waveform: return waveformMode.channelCount
    case .histogram: return histogramMode.channelCount
    case .vectorscope: return 1
    }
  }

  /// Waveform bin columns per channel. Even, so two columns share a packed word.
  public var waveformColumnsPerChannel: Int {
    let columns = waveformMode.isParade ? waveformColumns / 3 : waveformColumns
    return max(2, columns & ~1)
  }

  /// Everything clamped to its documented range; non-finite values reset.
  public func normalized() -> ScopeSettings {
    var v = self
    func clampInt(_ x: Int, _ r: ClosedRange<Int>) -> Int { min(r.upperBound, max(r.lowerBound, x)) }
    // Compared directly: `contains` allocates in unoptimized builds, and this runs every frame.
    v.vectorscopeZoom = vectorscopeZoom == 2 || vectorscopeZoom == 4 ? vectorscopeZoom : 1
    v.waveformColumns = clampInt(waveformColumns, Self.waveformColumnRange) & ~1
    v.waveformLevels = clampInt(waveformLevels, Self.waveformLevelRange)
    v.histogramBins = clampInt(histogramBins, Self.histogramBinRange) & ~1
    v.vectorscopeSize = clampInt(vectorscopeSize, Self.vectorscopeSizeRange) & ~1
    // The picture's clip indicator range.
    v.clipHighPercent = scopeClamp(clipHighPercent, -20...120, 100)
    v.clipLowPercent = scopeClamp(clipLowPercent, -20...120, 0)
    v.display = display.normalized()
    return v
  }

  /// The part of the settings that shapes the bins. Equal keys share bins.
  public var accumulationKey: AccumulationKey {
    let n = normalized()
    return AccumulationKey(
      kind: n.kind, stage: n.stage,
      mode: n.shaderMode,
      colorimetry: n.colorimetry,
      width: n.kind == .waveform
        ? n.waveformColumns : (n.kind == .histogram ? n.histogramBins : n.vectorscopeSize),
      height: n.kind == .waveform ? n.waveformLevels : (n.kind == .vectorscope ? n.vectorscopeZoom : 1),
      clipHigh: n.clipHighPercent, clipLow: n.clipLowPercent,
      levelRange: n.kind == .vectorscope ? .standard : n.levelRange)
  }

  public struct AccumulationKey: Hashable, Sendable {
    public let kind: ScopeKind
    public let stage: SignalStage
    public let mode: UInt32
    public let colorimetry: ScopeColorimetry
    public let width: Int
    public let height: Int
    public let clipHigh: Double
    public let clipLow: Double
    /// `levelRange` of a waveform or histogram; `.standard` for a vectorscope.
    public let levelRange: ScopeLevelRange
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, kind, stage, waveformMode, histogramMode, vectorscopeZoom, colorimetry,
      waveformColumns, waveformLevels, histogramBins, vectorscopeSize, levelRange, clipHighPercent,
      clipLowPercent, display
  }
  /// Unknown versions and malformed values decode as defaults; this never
  /// throws, so a scope preference cannot invalidate the host's other settings.
  public init(from decoder: Decoder) throws {
    self.init()
    guard let c = try? decoder.container(keyedBy: CodingKeys.self),
      c.scopeLenient(.schemaVersion, Self.schemaVersion) == Self.schemaVersion
    else { return }
    kind = c.scopeLenient(.kind, kind)
    stage = c.scopeLenient(.stage, stage)
    waveformMode = c.scopeLenient(.waveformMode, waveformMode)
    histogramMode = c.scopeLenient(.histogramMode, histogramMode)
    vectorscopeZoom = c.scopeLenient(.vectorscopeZoom, vectorscopeZoom)
    colorimetry = c.scopeLenient(.colorimetry, colorimetry)
    waveformColumns = c.scopeLenient(.waveformColumns, waveformColumns)
    waveformLevels = c.scopeLenient(.waveformLevels, waveformLevels)
    histogramBins = c.scopeLenient(.histogramBins, histogramBins)
    vectorscopeSize = c.scopeLenient(.vectorscopeSize, vectorscopeSize)
    levelRange = c.scopeLenient(.levelRange, levelRange)
    clipHighPercent = c.scopeLenient(.clipHighPercent, clipHighPercent)
    clipLowPercent = c.scopeLenient(.clipLowPercent, clipLowPercent)
    display = c.scopeLenient(.display, display)
    self = normalized()
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(Self.schemaVersion, forKey: .schemaVersion)
    try c.encode(kind, forKey: .kind)
    try c.encode(stage, forKey: .stage)
    try c.encode(waveformMode, forKey: .waveformMode)
    try c.encode(histogramMode, forKey: .histogramMode)
    try c.encode(vectorscopeZoom, forKey: .vectorscopeZoom)
    try c.encode(colorimetry, forKey: .colorimetry)
    try c.encode(waveformColumns, forKey: .waveformColumns)
    try c.encode(waveformLevels, forKey: .waveformLevels)
    try c.encode(histogramBins, forKey: .histogramBins)
    try c.encode(vectorscopeSize, forKey: .vectorscopeSize)
    try c.encode(levelRange, forKey: .levelRange)
    try c.encode(clipHighPercent, forKey: .clipHighPercent)
    try c.encode(clipLowPercent, forKey: .clipLowPercent)
    try c.encode(display, forKey: .display)
  }
}

extension ScopeSettings {
  /// The size of the scope image of Ultracam's earlier MonitorTools monitor,
  /// 768 × 256 pixels: draw `ultracamLegacy(…)` into a viewport this size for
  /// one bin per pixel, as it had. Levels land within one row of the old image,
  /// not on identical rows: MonitorKit bins uniformly, bin ⌊f · 256⌋ of the
  /// axis fraction f = (v + 0.1) / 1.2, where MonitorTools took ⌊f · 255⌋
  /// (`scopeBin`), up to one bin lower. So 50% is drawn on row 127 from the
  /// top (MonitorTools: 128) and 100% white on row 21, the row of the old 100%
  /// graticule line (MonitorTools drew its white on row 22). The old graticule
  /// rows, -10/0/50/100/110% on 255/234/128/21/0, are 255/234/127/21/0 here.
  public static let ultracamLegacyImageWidth = 768
  public static let ultracamLegacyImageHeight = 256

  /// The look of Ultracam's earlier MonitorTools waveform: `mode` (it had RGB
  /// parade and luma) with 768 columns (256 per parade channel) × 256 levels
  /// over -10…110 IRE (`ScopeLevelRange.minus10To110`), the old channel colours
  /// (`ScopeTracePalette.ultracamLegacy`) and an opaque black background. The
  /// trace density curve and the uniform level binning stay MonitorKit's
  /// (`display.intensity`; levels within one row of the old image, see
  /// `ultracamLegacyImageWidth`); everything not named here keeps its default.
  public static func ultracamLegacy(mode: WaveformMode = .rgbParade, stage: SignalStage = .output) -> ScopeSettings {
    var s = ScopeSettings(kind: .waveform, stage: stage)
    s.waveformMode = mode
    s.waveformColumns = ultracamLegacyImageWidth
    s.waveformLevels = ultracamLegacyImageHeight
    s.levelRange = .minus10To110
    s.display.palette = .ultracamLegacy
    s.display.backgroundOpacity = 1
    return s
  }
}

func scopeClamp(_ x: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
  x.isFinite ? min(r.upperBound, max(r.lowerBound, x)) : fallback
}

extension KeyedDecodingContainer {
  /// The decoded value, or `fallback` when the key is missing or malformed.
  func scopeLenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
    ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
  }
}
