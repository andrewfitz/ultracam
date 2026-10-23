import Foundation

/// Which signal a tool measures. All three come from one decode per pixel.
public enum SignalStage: String, Codable, Sendable, CaseIterable {
  /// The camera signal as captured.
  case source
  /// After the burned-in LUT: what the output feed carries.
  case output
  /// After the monitor-only LUT: what this surface shows.
  case monitor
}

public enum ZebraMode: String, Codable, Sendable, CaseIterable {
  /// Stripes at `level` and above.
  case lowerLimit
  /// Stripes within `level ± range`, lower edge inclusive, upper edge exclusive.
  case band
}

public struct ZebraSet: Codable, Equatable, Sendable {
  public var enabled = false
  public var mode: ZebraMode = .lowerLimit
  /// IRE: 0 is black, 100 is nominal white. Values past 100 reach super-white.
  public var level = 95.0
  /// Half-width of a band, in IRE.
  public var range = 5.0
  public var opacity = 0.65
  public var stage: SignalStage = .output
  public init() {}
  public init(
    enabled: Bool = true, mode: ZebraMode, level: Double, range: Double = 5,
    opacity: Double = 0.65, stage: SignalStage = .output
  ) {
    self.enabled = enabled
    self.mode = mode
    self.level = level
    self.range = range
    self.opacity = opacity
    self.stage = stage
  }

  private enum CodingKeys: String, CodingKey { case enabled, mode, level, range, opacity, stage }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = c.lenient(.enabled, enabled)
    mode = c.lenient(.mode, mode)
    level = c.lenient(.level, level)
    range = c.lenient(.range, range)
    opacity = c.lenient(.opacity, opacity)
    stage = c.lenient(.stage, stage)
  }

  /// CPU reference: whether a pixel at `ire` is striped.
  public func covers(ire: Double) -> Bool {
    guard enabled, ire.isFinite else { return false }
    switch mode {
    case .lowerLimit: return ire >= level
    case .band: return ire >= level - range && ire < level + range
    }
  }
}

public enum FalseColorMode: String, Codable, Sendable, CaseIterable {
  case off
  /// Sony Monitor & Control Pattern 2 on native S-Log3 signal luma.
  case sonySLog3
  /// ARRI LogC3 EI800 reference bands from S-Log3 scene luminance.
  case arriStyleSLog3
  /// ARRI published code-value bands on a LogC3 or LogC4 source.
  case arriLogC
  /// Exposure in stops relative to 18% grey, public EL Zone chart. Provisional.
  case elZone
  /// Six bands on display IRE (Ultracam convention v1).
  case sixBand
  /// User bands on IRE or stops.
  case custom

  /// Modes that classify the scene-referred source signal.
  public var needsLogSource: Bool {
    switch self {
    case .sonySLog3, .arriStyleSLog3, .arriLogC, .elZone: return true
    case .off, .sixBand, .custom: return false
    }
  }
}

public struct FalseColorBand: Codable, Equatable, Sendable {
  /// Lower edge inclusive, upper edge exclusive. Use ±.infinity for open ends.
  public var lower: Double
  public var upper: Double
  public var color: ColorRGB
  public init(lower: Double, upper: Double, color: ColorRGB) {
    self.lower = lower
    self.upper = upper
    self.color = color
  }

  // JSON has no infinity: an open end is stored as an absent edge.
  private enum CodingKeys: String, CodingKey { case lower, upper, color }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    lower = try c.decodeIfPresent(Double.self, forKey: .lower) ?? -.infinity
    upper = try c.decodeIfPresent(Double.self, forKey: .upper) ?? .infinity
    color = try c.decode(ColorRGB.self, forKey: .color)
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if lower.isFinite { try c.encode(lower, forKey: .lower) }
    if upper.isFinite { try c.encode(upper, forKey: .upper) }
    try c.encode(color, forKey: .color)
  }
}

extension ColorRGB: Codable {
  private enum CodingKeys: String, CodingKey { case r, g, b }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      r: try c.decode(Double.self, forKey: .r), g: try c.decode(Double.self, forKey: .g),
      b: try c.decode(Double.self, forKey: .b))
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(r, forKey: .r)
    try c.encode(g, forKey: .g)
    try c.encode(b, forKey: .b)
  }
}

public enum FalseColorUnit: String, Codable, Sendable, CaseIterable { case ire, stops }

public struct FalseColorSettings: Codable, Equatable, Sendable {
  public var mode: FalseColorMode = .off
  /// Added to measured exposure, in stops (EL Zone and custom stops).
  public var referenceOffsetStops = 0.0
  /// Signal for `.sixBand` and custom bands. Log modes always use the source.
  /// Custom stops linearize the stage: a LUT result as Rec.709, an untouched
  /// source by its own log curve or display transfer.
  public var stage: SignalStage = .output
  public var customUnit: FalseColorUnit = .ire
  /// At most `FalseColorSettings.maximumCustomBands`; first match wins.
  public var customBands: [FalseColorBand] = []
  public static let maximumCustomBands = 16
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case mode, referenceOffsetStops, stage, customUnit, customBands
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = c.lenient(.mode, mode)
    referenceOffsetStops = c.lenient(.referenceOffsetStops, referenceOffsetStops)
    stage = c.lenient(.stage, stage)
    customUnit = c.lenient(.customUnit, customUnit)
    customBands = c.lenient(.customBands, customBands)
  }
}

public enum PeakingStyle: String, Codable, Sendable, CaseIterable {
  /// Edges drawn in the peaking colour.
  case coloredEdges
  /// Edges brightened, like traditional sharpness peaking.
  case peak
}

public enum PeakingColor: String, Codable, Sendable, CaseIterable {
  case red, yellow, blue, white, green
  public var rgb: ColorRGB {
    switch self {
    case .red: return ColorRGB(r: 1, g: 0, b: 0)
    case .yellow: return ColorRGB(r: 1, g: 1, b: 0)
    case .blue: return ColorRGB(r: 0, g: 0, b: 1)
    case .white: return ColorRGB(r: 1, g: 1, b: 1)
    case .green: return ColorRGB(r: 0, g: 1, b: 0)
    }
  }
}

public struct FocusSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var style: PeakingStyle = .coloredEdges
  public var color: PeakingColor = .red
  /// 0 detects only the strongest edges, 1 the faintest. Low/Mid/High are 0.25/0.5/0.75.
  public var sensitivity = 0.5
  /// Edges need this much directional support to count, rejecting sensor noise.
  public var noiseRejection = 0.02
  public var opacity = 0.85
  /// The signal edges are found in. `.source` is the camera's transport luma; the
  /// output and monitor stages are the Rec.709 luma after the feed's LUTs, so a
  /// contrasty look peaks the edges it shows. The feed analyses one stage per frame.
  public var stage: SignalStage = .source
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case enabled, style, color, sensitivity, noiseRejection, opacity, stage
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = c.lenient(.enabled, enabled)
    style = c.lenient(.style, style)
    color = c.lenient(.color, color)
    sensitivity = c.lenient(.sensitivity, sensitivity)
    noiseRejection = c.lenient(.noiseRejection, noiseRejection)
    opacity = c.lenient(.opacity, opacity)
    stage = c.lenient(.stage, stage)
  }

  /// Gradient threshold used by the edge detector (unchanged from MonitorTools).
  public var edgeThreshold: Double { 0.02 + (1 - min(1, max(0, sensitivity))) * 0.3 }
}

public enum FrameGuideStyle: String, Codable, Sendable, CaseIterable { case lines, matte, linesAndMatte }

public struct FrameGuide: Codable, Equatable, Sendable {
  /// Width over height, e.g. 2.39 or 9.0/16.
  public var aspect: Double
  public var style: FrameGuideStyle = .lines
  /// Matte darkness outside the frame.
  public var matteOpacity = 0.6
  public init(aspect: Double, style: FrameGuideStyle = .lines, matteOpacity: Double = 0.6) {
    self.aspect = aspect
    self.style = style
    self.matteOpacity = matteOpacity
  }
  private enum CodingKeys: String, CodingKey { case aspect, style, matteOpacity }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(aspect: c.lenient(.aspect, 16.0 / 9.0))
    style = c.lenient(.style, style)
    matteOpacity = c.lenient(.matteOpacity, matteOpacity)
  }

  /// Every ratio either device offers, plus 2.40.
  public static let standardAspects: [Double] = [
    9.0 / 16, 4.0 / 5, 1, 4.0 / 3, 13.0 / 9, 14.0 / 9, 15.0 / 9, 16.0 / 9, 17.0 / 9, 1.66, 1.85,
    1.91, 2, 2.35, 2.39, 2.40,
  ]
}

public struct GuideSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var frameGuides: [FrameGuide] = []
  /// Percent of the frame, e.g. 80, 90, 93.
  public var safeAreas: [Double] = []
  /// Safe areas and grids follow the first frame guide when there is one.
  public var followsFrameGuide = true
  public var thirds = true
  public var squareGrid = false
  /// Rows of the square grid; columns follow from the frame's aspect.
  public var squareGridRows = 4
  public var diagonals = false
  public var centerCross = false
  public var centerDot = false
  public var color = ColorRGB(r: 1, g: 1, b: 1)
  public var opacity = 0.65
  /// 0 draws plain lines; 1 adds a full dark outline so lines read on bright scenes.
  public var contrast = 1.0
  /// In points; multiplied by the surface's pixels per point.
  public var lineWidth = 1.0
  /// While the picture is magnified (zoomed, or pixel-exact and larger than the
  /// view) the guides lie on the magnified picture: they zoom and pan with it and
  /// the part on screen is drawn, as an overlay scaled with the picture would be
  /// (line widths stay as set). True hides them while magnified instead
  /// (`MonitorUnavailableReason.hiddenWhileMagnified`), as a camera's focus
  /// magnifier hides its frame lines.
  public var hidesWhileMagnified = false
  public init() {}

  /// Whether guides are drawn on a picture laid out as `layout`: enabled, and not
  /// hidden while it is magnified. What `GuideRaster` and `MonitorPass` follow.
  public func isShown(on layout: MonitorLayout) -> Bool {
    enabled && !(hidesWhileMagnified && layout.isMagnified)
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, frameGuides, safeAreas, followsFrameGuide, thirds, squareGrid, squareGridRows,
      diagonals, centerCross, centerDot, color, opacity, contrast, lineWidth, hidesWhileMagnified
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = c.lenient(.enabled, enabled)
    frameGuides = c.lenient(.frameGuides, frameGuides)
    safeAreas = c.lenient(.safeAreas, safeAreas)
    followsFrameGuide = c.lenient(.followsFrameGuide, followsFrameGuide)
    thirds = c.lenient(.thirds, thirds)
    squareGrid = c.lenient(.squareGrid, squareGrid)
    squareGridRows = c.lenient(.squareGridRows, squareGridRows)
    diagonals = c.lenient(.diagonals, diagonals)
    centerCross = c.lenient(.centerCross, centerCross)
    centerDot = c.lenient(.centerDot, centerDot)
    color = c.lenient(.color, color)
    opacity = c.lenient(.opacity, opacity)
    contrast = c.lenient(.contrast, contrast)
    lineWidth = c.lenient(.lineWidth, lineWidth)
    hidesWhileMagnified = c.lenient(.hidesWhileMagnified, hidesWhileMagnified)
  }
}

public enum FlipMode: String, Codable, Sendable, CaseIterable {
  case none, horizontal, vertical, rotate180
  public var flipsX: Bool { self == .horizontal || self == .rotate180 }
  public var flipsY: Bool { self == .vertical || self == .rotate180 }
}

public struct Magnification: Codable, Equatable, Sendable {
  /// 1 shows the whole picture. Larger values zoom in about `center`.
  public var zoom = 1.0
  /// One picture pixel per display pixel, ignoring `zoom`.
  public var pixelExact = false
  /// Normalized picture point kept at the centre of the view (clamped to the edges).
  public var centerX = 0.5
  public var centerY = 0.5
  public var showsNavigator = true
  public init() {}
  public var isActive: Bool { pixelExact || zoom > 1 }

  private enum CodingKeys: String, CodingKey { case zoom, pixelExact, centerX, centerY, showsNavigator }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    zoom = c.lenient(.zoom, zoom)
    pixelExact = c.lenient(.pixelExact, pixelExact)
    centerX = c.lenient(.centerX, centerX)
    centerY = c.lenient(.centerY, centerY)
    showsNavigator = c.lenient(.showsNavigator, showsNavigator)
  }
}

public struct ViewGeometry: Codable, Equatable, Sendable {
  /// Anamorphic de-squeeze factor, 1 for none. Sony's "1.6x" is 1.65.
  public var desqueeze = 1.0
  public var flip: FlipMode = .none
  public var magnification = Magnification()
  public init() {}

  public static let standardDesqueezeFactors: [Double] = [1, 1.3, 1.33, 1.5, 1.65, 1.66, 1.8, 2]

  /// De-squeeze 1…4, zoom 1…64 and the centre 0…1, non-finite values reset (the
  /// geometry part of `MonitorState.normalized()`). Allocation-free.
  public func normalized() -> ViewGeometry {
    func b(_ x: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
      x.isFinite ? min(r.upperBound, max(r.lowerBound, x)) : fallback
    }
    var v = self
    v.desqueeze = b(desqueeze, 1...4, 1)
    v.magnification.zoom = b(magnification.zoom, 1...64, 1)
    v.magnification.centerX = b(magnification.centerX, 0...1, 0.5)
    v.magnification.centerY = b(magnification.centerY, 0...1, 0.5)
    return v
  }

  private enum CodingKeys: String, CodingKey { case desqueeze, flip, magnification }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    desqueeze = c.lenient(.desqueeze, desqueeze)
    flip = c.lenient(.flip, flip)
    magnification = c.lenient(.magnification, magnification)
  }
}

public enum MonochromeMode: String, Codable, Sendable, CaseIterable {
  case off
  /// Rec.709 luma of the monitor picture.
  case luma
  /// The blue channel in greyscale, for noise and focus.
  case blueOnly
}

/// Changes to the monitor picture only: never to output, tools or legends.
public struct DisplayAdjustments: Codable, Equatable, Sendable {
  /// Added to every channel, -1…1.
  public var brightness = 0.0
  /// Gain about mid-grey (0.5), 0…2.
  public var contrast = 1.0
  /// 0 is greyscale, 1 unchanged, 2 doubled.
  public var saturation = 1.0
  /// White-point trim: the correlated colour temperature of the white the picture's
  /// white is moved to, in kelvin on the CIE daylight locus, 4000…10 000. 6504 (D65)
  /// is no trim (`WhitePointTrim`).
  public var temperature = WhitePointTrim.d65Temperature
  /// White-point trim off the daylight locus, as the CIE 1960 Δuv of the trimmed
  /// white, -0.02…0.02: positive is greener (above the locus), negative more
  /// magenta (ANSI C78.377's Duv sign). 0 is no trim.
  public var tint = 0.0
  public var monochrome: MonochromeMode = .off
  public init() {}
  public var isIdentity: Bool {
    brightness == 0 && contrast == 1 && saturation == 1 && monochrome == .off && !trimsWhitePoint
  }
  /// Whether the white-point trim moves the white.
  public var trimsWhitePoint: Bool { temperature != WhitePointTrim.d65Temperature || tint != 0 }

  private enum CodingKeys: String, CodingKey { case brightness, contrast, saturation, monochrome, temperature, tint }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    brightness = c.lenient(.brightness, brightness)
    contrast = c.lenient(.contrast, contrast)
    saturation = c.lenient(.saturation, saturation)
    monochrome = c.lenient(.monochrome, monochrome)
    temperature = c.lenient(.temperature, temperature)
    tint = c.lenient(.tint, tint)
  }
}

/// Monitor-only picture transforms, applied after the monitor LUT (Sony "Gamma
/// Display Assist", the Video Assist's HDR/SDR monitoring). They change only what
/// this surface shows: zebras, false colour, peaking, clip indicators and scopes
/// keep measuring their stage. They need the camera's own signal: with a burn-in
/// or monitor LUT on the surface, LUT output is Rec.709 display R'G'B' (the
/// convention of every LUT stage), so a transform is unavailable
/// (`MonitorUnavailableReason.lutOnMonitorStage`), as Sony's Gamma Display Assist
/// is while a LUT is applied.
public enum DisplayTransform: String, Codable, Sendable, CaseIterable {
  case none
  /// A log source (S-Log3/S-Gamut3(.Cine), LogC3/AWG3, LogC4/AWG4) to Rec.709 SDR:
  /// "MonitorKit display assist v1" (`DisplayAssist`).
  case logToRec709
  /// PQ or HLG to Rec.709 SDR: PQ through the BT.2408 Annex 5 EETF (display
  /// light); HLG by MonitorKit's SDR-camera scene-light convention, BT.2408
  /// §5.1.4.1's scaling (75% HLG is graphics white) then the BT.709 OETF
  /// (`HDRToSDR.hlg`). It does not invert BT.2408's scene-light up-mapping.
  case hdrToSDR
  /// PQ or HLG stays HDR on an HDR output, its highlights rolled off to what the
  /// output holds (the EDR headroom for extended linear).
  case hdrPassthrough
}

public struct DisplayTransformSettings: Codable, Equatable, Sendable {
  public var mode: DisplayTransform = .none
  /// Peak of the PQ content's mastering display in cd/m², the EETF's source peak.
  /// 1000 by default, the reference condition of Report ITU-R BT.2408-8 §6.2.
  public var pqSourcePeak = 1000.0
  public init() {}
  public init(mode: DisplayTransform, pqSourcePeak: Double = 1000) {
    self.mode = mode
    self.pqSourcePeak = pqSourcePeak
  }

  private enum CodingKeys: String, CodingKey { case mode, pqSourcePeak }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = c.lenient(.mode, mode)
    pqSourcePeak = c.lenient(.pqSourcePeak, pqSourcePeak)
  }
}

public enum ClipIndicatorColoring: String, Codable, Sendable, CaseIterable {
  /// Each channel in its own colour, added: red, green and blue, so two clipped
  /// channels show their mix and all three white. Under-range pixels show the same
  /// mix at half level. Luma alone (no channel shown) is white, or grey under.
  case perChannel
  /// `overColor` and `underColor` whatever the channel.
  case uniform
}

/// Per-channel clip overlay. Clip percentages are scope statistics, not part of this.
public struct ClipIndicatorSettings: Codable, Equatable, Sendable {
  public var enabled = false
  /// The signal measured. A channel's value is the stage's R', G' or B' in percent
  /// (100 is nominal white: code 940 in a 10-bit legal container); luma is the stage's Y'.
  public var stage: SignalStage = .output
  public var red = true
  public var green = true
  public var blue = true
  public var luma = true
  /// Over: a value at or above `high` percent (inclusive).
  public var showsOver = true
  public var high = 100.0
  /// Under: a value at or below `low` percent (inclusive).
  public var showsUnder = true
  public var low = 0.0
  public var coloring: ClipIndicatorColoring = .perChannel
  public var overColor = ColorRGB(r: 1, g: 0, b: 0)
  public var underColor = ColorRGB(r: 0, g: 0, b: 1)
  public var opacity = 1.0
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case enabled, stage, red, green, blue, luma, showsOver, high, showsUnder, low, coloring, overColor,
      underColor, opacity
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = c.lenient(.enabled, enabled)
    stage = c.lenient(.stage, stage)
    red = c.lenient(.red, red)
    green = c.lenient(.green, green)
    blue = c.lenient(.blue, blue)
    luma = c.lenient(.luma, luma)
    showsOver = c.lenient(.showsOver, showsOver)
    high = c.lenient(.high, high)
    showsUnder = c.lenient(.showsUnder, showsUnder)
    low = c.lenient(.low, low)
    coloring = c.lenient(.coloring, coloring)
    overColor = c.lenient(.overColor, overColor)
    underColor = c.lenient(.underColor, underColor)
    opacity = c.lenient(.opacity, opacity)
  }

  /// Whether anything can be flagged.
  public var isEffective: Bool { enabled && (red || green || blue || luma) && (showsOver || showsUnder) }

  /// CPU reference: the Rec.709 display colour a pixel with stage R'G'B' `rgb` and
  /// Y' `luma` is flagged with (values normalized, 1 = 100%), or nil.
  public func indicator(rgb: ColorRGB, luma y: Double) -> ColorRGB? {
    guard isEffective else { return nil }
    func over(_ v: Double) -> Bool { showsOver && v * 100 >= high }
    func under(_ v: Double) -> Bool { showsUnder && v * 100 <= low }
    let o = (red && over(rgb.r), green && over(rgb.g), blue && over(rgb.b), luma && over(y))
    let u = (red && under(rgb.r), green && under(rgb.g), blue && under(rgb.b), luma && under(y))
    if o.0 || o.1 || o.2 || o.3 {
      return Self.color(coloring, channels: (o.0, o.1, o.2), over: true, uniform: overColor)
    }
    if u.0 || u.1 || u.2 || u.3 {
      return Self.color(coloring, channels: (u.0, u.1, u.2), over: false, uniform: underColor)
    }
    return nil
  }

  /// The colour for a set of flagged channels; none flagged means luma alone.
  public static func color(
    _ coloring: ClipIndicatorColoring, channels c: (Bool, Bool, Bool), over: Bool, uniform: ColorRGB
  ) -> ColorRGB {
    guard coloring == .perChannel else { return uniform }
    let level = over ? 1.0 : 0.5
    if !c.0 && !c.1 && !c.2 { return ColorRGB(r: level, g: level, b: level) }
    return ColorRGB(r: c.0 ? level : 0, g: c.1 ? level : 0, b: c.2 ? level : 0)
  }
}

/// Every tool setting for one monitor surface. A value type: changing it costs
/// nothing on the GPU except when guides must be redrawn.
///
/// Persisted JSON is fail-closed: it carries a positive discriminator
/// (`"kind": "MonitorKit.MonitorState"`) and `schemaVersion` 2, and decoding
/// throws `DecodingError.dataCorrupted` for anything else (another type's JSON,
/// such as Ultracam's old `MonitorConfiguration`, which also said `schemaVersion`
/// 1; MonitorKit's own discriminator-less schema 1; a non-object). Inside a
/// genuine MonitorKit blob decoding stays lenient: a missing or malformed field
/// decodes as its default and out-of-range values are normalized, so one bad value
/// cannot cost the other settings. A host catches the error and falls back to
/// defaults (or its own legacy decoder).
///
/// Embedded in a host's synthesized `Codable` type, a throwing field would fail
/// the whole outer value (`decodeIfPresent` rethrows when the key is present), so
/// a foreign or old blob would cost the host's other settings. Declare such a
/// field `@LenientMonitorState var state: MonitorState` (it decodes to defaults
/// and encodes the state as it is), or decode with
/// `MonitorState(decodingOrDefault:)` / `MonitorState.decodedOrDefault(from:)`.
public struct MonitorState: Codable, Equatable, Sendable {
  /// The schema written. 2 since the discriminator; versions above it from a newer
  /// MonitorKit decode field by field (schema changes within one `codingKind` are additive).
  public static let schemaVersion = 2
  /// The JSON discriminator, written as `"kind"` and required to decode.
  public static let codingKind = "MonitorKit.MonitorState"
  /// Turns every overlay and analysis off in one switch. LUTs, display
  /// adjustments, de-squeeze, flip and magnification still apply.
  public var clean = false
  public var zebras: [ZebraSet] = [ZebraSet(), ZebraSet()]
  public var falseColor = FalseColorSettings()
  public var focus = FocusSettings()
  public var guides = GuideSettings()
  public var geometry = ViewGeometry()
  public var display = DisplayAdjustments()
  /// Whether this surface applies the feed's monitor-only LUT.
  public var monitorLUT = true
  /// Monitor-only display transform after the monitor LUT. Not an overlay: a
  /// clean surface keeps it, as it keeps LUTs.
  public var displayTransform = DisplayTransformSettings()
  public var clipIndicators = ClipIndicatorSettings()
  /// The stage the picture itself shows. `.monitor` (the default) is the picture
  /// after both LUTs; `.output` shows what the output carries (the burn-in LUT,
  /// not the monitor LUT); `.source` shows the camera signal with no LUT, so a
  /// display transform can apply even while the feed burns a LUT in. Tools keep
  /// measuring their own stages. Each choice is fixed in a specialized pipeline.
  public var pictureStage: SignalStage = .monitor
  public static let maximumZebraSets = 2

  public init() {}

  /// Whether the picture this state shows came out of a LUT: a burn-in LUT on the
  /// output or monitor stage, or the monitor LUT (when `monitorLUT`) on the monitor
  /// stage. LUT output is Rec.709 display R'G'B', so such a picture is Rec.709 SDR
  /// and display transforms are unavailable.
  public func pictureHasLUT(burnInLUT: Bool, monitorLUT hasMonitorLUT: Bool) -> Bool {
    switch pictureStage {
    case .source: return false
    case .output: return burnInLUT
    case .monitor: return burnInLUT || (monitorLUT && hasMonitorLUT)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind, schemaVersion, clean, zebras, falseColor, focus, guides, geometry, display, monitorLUT,
      displayTransform, clipIndicators, pictureStage
  }
  /// Throws unless the JSON is a MonitorKit `MonitorState` (`kind` and a
  /// `schemaVersion` of at least 2); every field inside decodes leniently.
  public init(from decoder: Decoder) throws {
    self.init()
    let c: KeyedDecodingContainer<CodingKeys>
    do {
      c = try decoder.container(keyedBy: CodingKeys.self)
    } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Not a \(Self.codingKind) object", underlyingError: error))
    }
    guard (try? c.decodeIfPresent(String.self, forKey: .kind)) == Self.codingKind else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath + [CodingKeys.kind],
          debugDescription: "Not a \(Self.codingKind): the \"kind\" discriminator is missing or different"))
    }
    guard let version = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil, version >= Self.schemaVersion
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath + [CodingKeys.schemaVersion],
          debugDescription: "\(Self.codingKind) needs schemaVersion \(Self.schemaVersion) or later"))
    }
    clean = c.lenient(.clean, clean)
    zebras = c.lenient(.zebras, zebras)
    falseColor = c.lenient(.falseColor, falseColor)
    focus = c.lenient(.focus, focus)
    guides = c.lenient(.guides, guides)
    geometry = c.lenient(.geometry, geometry)
    display = c.lenient(.display, display)
    monitorLUT = c.lenient(.monitorLUT, monitorLUT)
    displayTransform = c.lenient(.displayTransform, displayTransform)
    clipIndicators = c.lenient(.clipIndicators, clipIndicators)
    pictureStage = c.lenient(.pictureStage, pictureStage)
    self = normalized()
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(Self.codingKind, forKey: .kind)
    try c.encode(Self.schemaVersion, forKey: .schemaVersion)
    try c.encode(clean, forKey: .clean)
    try c.encode(zebras, forKey: .zebras)
    try c.encode(falseColor, forKey: .falseColor)
    try c.encode(focus, forKey: .focus)
    try c.encode(guides, forKey: .guides)
    try c.encode(geometry, forKey: .geometry)
    try c.encode(display, forKey: .display)
    try c.encode(monitorLUT, forKey: .monitorLUT)
    try c.encode(displayTransform, forKey: .displayTransform)
    try c.encode(clipIndicators, forKey: .clipIndicators)
    try c.encode(pictureStage, forKey: .pictureStage)
  }

  /// Every value clamped to its documented range; non-finite values reset.
  ///
  /// Allocation-free when nothing needs to change, even unoptimized: arrays are
  /// rebuilt, and their elements written, only when a value is out of range, and
  /// they are scanned with plain index loops (no iterators). Passes call this
  /// whenever the state changes, e.g. every frame of a slider drag.
  public func normalized() -> MonitorState {
    var v = self
    func b(_ x: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
      x.isFinite ? min(r.upperBound, max(r.lowerBound, x)) : fallback
    }
    if v.zebras.count != Self.maximumZebraSets {
      v.zebras = Array(zebras.prefix(Self.maximumZebraSets))
      while v.zebras.count < Self.maximumZebraSets { v.zebras.append(ZebraSet()) }
    }
    var i = 0
    while i < Self.maximumZebraSets {
      let z = v.zebras[i]
      let level = b(z.level, -20...120, 95), range = b(z.range, 0...30, 5), opacity = b(z.opacity, 0...1, 0.65)
      // Writes only on change: a write into an array element copies the shared buffer.
      if level != z.level || range != z.range || opacity != z.opacity {
        v.zebras[i].level = level
        v.zebras[i].range = range
        v.zebras[i].opacity = opacity
      }
      i += 1
    }
    v.falseColor.referenceOffsetStops = b(falseColor.referenceOffsetStops, -6...6, 0)
    let bands = falseColor.customBands
    var bandsValid = bands.count <= FalseColorSettings.maximumCustomBands
    i = 0
    while bandsValid && i < bands.count {
      let band = bands[i]
      bandsValid = !band.lower.isNaN && !band.upper.isNaN && band.color.isFinite
      i += 1
    }
    if !bandsValid {
      v.falseColor.customBands = Array(
        bands.filter { !$0.lower.isNaN && !$0.upper.isNaN && $0.color.isFinite }
          .prefix(FalseColorSettings.maximumCustomBands))
    }
    v.focus.sensitivity = b(focus.sensitivity, 0...1, 0.5)
    v.focus.noiseRejection = b(focus.noiseRejection, 0...1, 0.02)
    v.focus.opacity = b(focus.opacity, 0...1, 0.85)
    func validAspect(_ a: Double) -> Bool { a.isFinite && a >= 0.1 && a <= 10 }
    let frameGuides = guides.frameGuides
    var guidesValid = frameGuides.count <= 4
    i = 0
    while guidesValid && i < frameGuides.count {
      let g = frameGuides[i]
      guidesValid = validAspect(g.aspect) && g.matteOpacity == b(g.matteOpacity, 0...1, 0.6)
      i += 1
    }
    if !guidesValid {
      v.guides.frameGuides = Array(frameGuides.filter { validAspect($0.aspect) }.prefix(4)).map {
        var g = $0
        g.matteOpacity = b(g.matteOpacity, 0...1, 0.6)
        return g
      }
    }
    func validSafeArea(_ x: Double) -> Bool { x.isFinite && x >= 10 && x <= 100 }
    let safeAreas = guides.safeAreas
    var safeValid = safeAreas.count <= 4
    i = 0
    while safeValid && i < safeAreas.count {
      safeValid = validSafeArea(safeAreas[i])
      i += 1
    }
    if !safeValid { v.guides.safeAreas = Array(safeAreas.filter(validSafeArea).prefix(4)) }
    v.guides.squareGridRows = min(16, max(2, guides.squareGridRows))
    v.guides.opacity = b(guides.opacity, 0...1, 0.65)
    v.guides.contrast = b(guides.contrast, 0...1, 1)
    v.guides.lineWidth = b(guides.lineWidth, 0.5...8, 1)
    if !guides.color.isFinite { v.guides.color = ColorRGB(r: 1, g: 1, b: 1) }
    v.geometry = geometry.normalized()
    v.display.brightness = b(display.brightness, -1...1, 0)
    v.display.contrast = b(display.contrast, 0...2, 1)
    v.display.saturation = b(display.saturation, 0...2, 1)
    v.display.temperature = b(display.temperature, WhitePointTrim.temperatureRange, WhitePointTrim.d65Temperature)
    v.display.tint = b(display.tint, WhitePointTrim.tintRange, 0)
    v.displayTransform.pqSourcePeak = b(displayTransform.pqSourcePeak, 100...10_000, 1000)
    v.clipIndicators.high = b(clipIndicators.high, -20...120, 100)
    v.clipIndicators.low = b(clipIndicators.low, -20...120, 0)
    v.clipIndicators.opacity = b(clipIndicators.opacity, 0...1, 1)
    if !clipIndicators.overColor.isFinite { v.clipIndicators.overColor = ColorRGB(r: 1, g: 0, b: 0) }
    if !clipIndicators.underColor.isFinite { v.clipIndicators.underColor = ColorRGB(r: 0, g: 0, b: 1) }
    return v
  }
}

extension KeyedDecodingContainer {
  /// The decoded value, or `fallback` when the key is missing or malformed.
  func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
    ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
  }
}

extension MonitorState {
  /// The state `decoder` holds, or the defaults when it is not a MonitorKit
  /// `MonitorState` (another type's JSON, MonitorKit's discriminator-less schema 1,
  /// a non-object): the fail-closed decode without the error, for hosts that
  /// embed a state in their own `Decodable` types. Never throws.
  public init(decodingOrDefault decoder: Decoder) {
    self = (try? MonitorState(from: decoder)) ?? MonitorState()
  }

  /// `data` (JSON) as a state, or the defaults when it is not a MonitorKit `MonitorState`.
  public static func decodedOrDefault(from data: Data) -> MonitorState {
    (try? JSONDecoder().decode(MonitorState.self, from: data)) ?? MonitorState()
  }
}

/// A `MonitorState` field that falls back to the defaults instead of throwing, so
/// a host's synthesized `Codable` type survives a foreign or old monitor blob
/// (integration map R13: fail closed to defaults, keep the other settings):
///
///     struct FeedPreferences: Codable {
///       var name: String
///       @LenientMonitorState var monitor: MonitorState
///     }
///
/// Decoding: a missing key, `null`, or anything `MonitorState`'s fail-closed
/// decoder rejects is `MonitorState()`; a genuine blob decodes as usual. Encoding
/// writes the state itself under the key (no wrapper object), so the JSON is the
/// same as a plain `MonitorState` field's.
@propertyWrapper
public struct LenientMonitorState: Codable, Equatable, Sendable {
  public var wrappedValue: MonitorState

  public init(wrappedValue: MonitorState = MonitorState()) { self.wrappedValue = wrappedValue }

  public init(from decoder: Decoder) {
    let isNull = (try? decoder.singleValueContainer().decodeNil()) ?? false
    wrappedValue = isNull ? MonitorState() : MonitorState(decodingOrDefault: decoder)
  }

  public func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}

extension KeyedDecodingContainer {
  /// A missing `@LenientMonitorState` key decodes to the defaults (synthesized
  /// `Decodable` calls this for a wrapped field) instead of `keyNotFound`.
  public func decode(_ type: LenientMonitorState.Type, forKey key: Key) throws -> LenientMonitorState {
    guard contains(key) else { return LenientMonitorState() }
    return (try? decodeIfPresent(type, forKey: key) ?? nil) ?? LenientMonitorState()
  }
}
