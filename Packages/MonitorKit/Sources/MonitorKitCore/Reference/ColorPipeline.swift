import Foundation

/// "MonitorKit display assist v1": camera log to Rec.709 SDR for monitoring. Sony's
/// LC-709/s709 and ARRI's LUTs are not public, so this is MonitorKit's own curve,
/// every constant defined here (`Docs/MATH.md`, display transforms):
///
/// 1. Decode the log curve to scene-linear reflectance (18% grey = 0.18).
/// 2. Convert the camera gamut to linear Rec.709 (RP 177 from the published
///    primaries, `ColorGamut.conversion(to:)`). Out-of-gamut values clip to 0.
/// 3. Per channel, the ITU-R BT.709 OETF up to the knee, so shadows and mid-tones
///    are those of a standard Rec.709 camera (18% grey at 40.9%), then a highlight
///    shoulder, V = Vk + (1 - Vk)·(1 - (x/xk)^-q), which joins the OETF with
///    continuous slope and approaches 100% asymptotically (an exponential approach
///    in stops, time constant (1 - Vk)/(dV/dstop) = 1.20 stops).
/// 4. The result is BT.709 signal, shown on a BT.1886 display (the standard
///    Rec.709 chain).
///
/// Anchors: grey 40.9%, white card (90%) 85.4%, +4 stops over grey 96.4%, +6 stops 99.3%.
public enum DisplayAssist {
  public static let name = "MonitorKit display assist v1"
  /// The signal level where the shoulder starts (70%).
  public static let kneeSignal = 0.7
  /// Scene light at the knee: the BT.709 OETF's inverse of `kneeSignal`, 0.4924 (+1.45 stops over grey).
  public static let kneeScene = pow((kneeSignal + 0.099) / 1.099, 1 / 0.45)
  /// The shoulder's exponent: x·dV/dx of the OETF at the knee over (1 - Vk), so the
  /// slopes match there. 1.099·0.45·xk^0.45 / (1 - Vk).
  public static let shoulderExponent = 1.099 * 0.45 * pow(kneeScene, 0.45) / (1 - kneeSignal)

  /// Step 3: scene-linear Rec.709 to BT.709 signal.
  public static func signal(sceneLinear x: Double) -> Double {
    guard x > kneeScene else { return ColorMath.bt709OETF(x) }
    return kneeSignal + (1 - kneeSignal) * (1 - pow(x / kneeScene, -shoulderExponent))
  }

  /// Steps 1-4 for a range-expanded log sample of a `bitDepth` container (10 for float).
  public static func rec709(
    _ rgb: ColorRGB, log: LogEncoding, range: CodeRange, bitDepth: Int = 10
  ) -> ColorRGB {
    func linear(_ v: Double) -> Double {
      log.curve.decode(log.curve.signal(expanded: v, range: range, transport: log.transport, bitDepth: bitDepth)) ?? 0
    }
    let scene = log.gamut.conversion(to: .rec709).apply(ColorRGB(r: linear(rgb.r), g: linear(rgb.g), b: linear(rgb.b)))
    return ColorRGB(r: signal(sceneLinear: scene.r), g: signal(sceneLinear: scene.g), b: signal(sceneLinear: scene.b))
  }
}

/// HDR to SDR monitoring conversions (Report ITU-R BT.2408-8 §5.2 and Annex 5,
/// Report ITU-R BT.2446-1 §6, Report ITU-R BT.2407-0 §2).
public enum HDRToSDR {
  /// The HLG scene light of HDR Reference White (75% HLG): BT.2100's inverse OETF
  /// of 0.75, 0.26496 (BT.2408 §5.1.4.1 prints it rounded, 0.265).
  public static let hlgReferenceWhiteScene = ColorMath.hlgInverseOETF(0.75)
  /// The nominal peak an HLG signal is decoded for (BT.2408-8 §6.2's reference condition).
  public static let hlgReferencePeak = 1000.0

  /// HLG to Rec.709 SDR by display light, Report ITU-R BT.2446-1 Method C
  /// (`BT2446MethodC`): the BT.2100 EOTF for the 1000 cd/m² display (system gamma
  /// 1.2), eq. (5)'s tone map of the luminance at constant chromaticity to the
  /// 100 cd/m² SDR display, BT.2020 to BT.709 in linear light clipped to 0…1
  /// (Report ITU-R BT.2407 §2, to which §6.1 refers), and the BT.1886 inverse
  /// EOTF. 18% grey (38% HLG) lands at 53.2%, skin (50% HLG) at 70%, HDR
  /// Reference White (75% HLG) at 96%; luminance reaches 100% SDR at 334 cd/m²
  /// (about 83% HLG), and brighter light is the SDR peak, as on the 100 cd/m²
  /// display.
  public static func hlg(_ v: ColorRGB, primaries: ColorPrimaries) -> ColorRGB {
    let display = ColorMath.hlgEOTF(
      ColorRGB(r: max(v.r, 0), g: max(v.g, 0), b: max(v.b, 0)), peak: BT2446MethodC.hdrPeak,
      weights: primaries.luminanceCoefficients)
    let sdr = BT2446MethodC.toneMap(display, primaries: primaries)
    let k = 1 / BT2446MethodC.sdrPeak
    let l = primaries.conversion(to: .rec709).apply(ColorRGB(r: sdr.r * k, g: sdr.g * k, b: sdr.b * k))
    func encode(_ l: Double) -> Double { ColorMath.bt1886InverseEOTF(min(max(l, 0), 1)) }
    return ColorRGB(r: encode(l.r), g: encode(l.g), b: encode(l.b))
  }

  /// PQ to Rec.709 SDR by display light (§5.2: preferred, it keeps the HDR look):
  /// the Annex 5 EETF (maxRGB) from the mastering peak to graphics white, which
  /// is SDR peak white, then BT.2020 to BT.709 in linear light, clipped, and the
  /// BT.1886 inverse EOTF. Reference white (203 cd/m², 1000 cd/m² master) rolls
  /// off to 159.04 cd/m² and lands at 90.33%, within the 90-95% of §7.7; 18% grey
  /// (26 cd/m², below the knee) at 42.5%.
  public static func pq(_ v: ColorRGB, primaries: ColorPrimaries, sourcePeak: Double, referenceWhite: Double) -> ColorRGB {
    let nits = ColorRGB(r: ColorMath.pqNits(max(v.r, 0)), g: ColorMath.pqNits(max(v.g, 0)), b: ColorMath.pqNits(max(v.b, 0)))
    let mapped = ToneMapEETF(sourcePeak: sourcePeak, targetPeak: referenceWhite).apply(nits)
    let c = primaries.conversion(to: .rec709).apply(
      ColorRGB(r: mapped.r / referenceWhite, g: mapped.g / referenceWhite, b: mapped.b / referenceWhite))
    func encode(_ l: Double) -> Double { ColorMath.bt1886InverseEOTF(min(max(l, 0), 1)) }
    return ColorRGB(r: encode(c.r), g: encode(c.g), b: encode(c.b))
  }
}

/// The monitor-only white-point trim (temperature and tint, the Video Assist's LCD
/// temperature and tint): one gain per channel in linear display light, as a
/// display's white balance scales its R, G and B drives, so the picture's white
/// lands on the trimmed white.
///
/// The trimmed white lies on the CIE daylight locus at `temperature` (CIE 15:2004
/// §3.1, eqs. 3.3 and 3.4, defined from 4000 to 25 000 K), moved `tint` along the
/// locus normal in the CIE 1960 UCS (ANSI C78.377's Duv). The gains are its linear
/// RGB in the picture's primaries over that of the untrimmed white (the locus at
/// 6504 K, which is D65), scaled so the largest is 1: like a display, which cannot
/// drive a channel past full, the trim never clips white.
public enum WhitePointTrim {
  /// D65's correlated colour temperature on the daylight locus (6500 K with the
  /// 1968 radiation constant c2 = 1.4388e-2, CIE 15:2004 §3.1): no trim.
  public static let d65Temperature = 6504.0
  public static let temperatureRange = 4000.0...10_000.0
  public static let tintRange = -0.02...0.02

  /// `temperature`, or exactly `d65Temperature` when it lies within `tolerance`
  /// kelvin of it. D65's 6504 K is on no round-number grid, so a control stepping
  /// through it (a 50 K slider lands on 6500 K) would leave a small trim on
  /// (`DisplayAdjustments.trimsWhitePoint` compares exactly); snapping within half
  /// the control's step lets it reach "no trim". Not finite: returned unchanged.
  public static func snappedToD65(_ temperature: Double, within tolerance: Double) -> Double {
    abs(temperature - d65Temperature) <= tolerance ? d65Temperature : temperature
  }

  /// The CIE daylight chromaticity at correlated colour temperature `t` kelvin.
  public static func daylight(_ t: Double) -> Chromaticity {
    let t = min(25_000, max(4000, t)), t2 = t * t, t3 = t2 * t
    let x =
      t <= 7000
      ? -4.6070e9 / t3 + 2.9678e6 / t2 + 0.09911e3 / t + 0.244063
      : -2.0064e9 / t3 + 1.9018e6 / t2 + 0.24748e3 / t + 0.237040
    return Chromaticity(x: x, y: -3.000 * x * x + 2.870 * x - 0.275)
  }

  /// CIE 1960 UCS (u, v) of a chromaticity, and back.
  static func uv(_ c: Chromaticity) -> (u: Double, v: Double) {
    let d = -2 * c.x + 12 * c.y + 3
    return (4 * c.x / d, 6 * c.y / d)
  }
  static func chromaticity(u: Double, v: Double) -> Chromaticity {
    let d = 2 * u - 8 * v + 4
    return Chromaticity(x: 3 * u / d, y: 2 * v / d)
  }

  /// The trimmed white.
  public static func white(temperature: Double, tint: Double) -> Chromaticity {
    let w = daylight(temperature)
    guard tint != 0 else { return w }
    // The locus's unit normal in uv, pointing above it (to green: v grows).
    let step = temperature * 1e-4
    let a = uv(daylight(temperature - step)), b = uv(daylight(temperature + step))
    let du = b.u - a.u, dv = b.v - a.v, length = (du * du + dv * dv).squareRoot()
    var n = (u: -dv / length, v: du / length)
    if n.v < 0 { n = (-n.u, -n.v) }
    let p = uv(w)
    return chromaticity(u: p.u + tint * n.u, v: p.v + tint * n.v)
  }

  /// The linear-light gains in `primaries`; (1, 1, 1) without a trim.
  public static func gains(temperature: Double, tint: Double, primaries: ColorPrimaries) -> ColorRGB {
    guard temperature != d65Temperature || tint != 0 else { return ColorRGB(r: 1, g: 1, b: 1) }
    let toRGB = primaries.toXYZ.inverse
    func rgb(_ c: Chromaticity) -> ColorRGB {
      let v = c.xyz
      return toRGB.apply(ColorRGB(r: v.x, g: v.y, b: v.z))
    }
    let trimmed = rgb(white(temperature: temperature, tint: tint)), white = rgb(daylight(d65Temperature))
    let g = ColorRGB(
      r: max(trimmed.r / white.r, 1e-6), g: max(trimmed.g / white.g, 1e-6), b: max(trimmed.b / white.b, 1e-6))
    let m = max(g.r, g.g, g.b)
    return ColorRGB(r: g.r / m, g: g.g / m, b: g.b / m)
  }

  /// `gains` for display adjustments.
  public static func gains(_ d: DisplayAdjustments, primaries: ColorPrimaries) -> ColorRGB {
    gains(temperature: d.temperature, tint: d.tint, primaries: primaries)
  }
}

/// Why a display transform that is chosen does not run.
public enum DisplayTransformUnavailable: Equatable, Sendable {
  /// `logToRec709` on a signal not labelled log.
  case requiresLogSource
  /// `hdrToSDR` or `hdrPassthrough` on a signal that is not PQ or HLG.
  case requiresHDRSource
  /// `hdrPassthrough` into an SDR output.
  case requiresHDROutput
  /// Any transform while a LUT produces the monitor stage (burn-in or monitor LUT):
  /// LUT output is Rec.709 display R'G'B' everywhere in MonitorKit (stage luma, false
  /// colour, scopes, the layer), so there is no camera or HDR signal left to transform.
  case lutOnMonitorStage
}

/// How a surface's picture becomes target pixel values, resolved from the output
/// colour, the signal and the display transform. `MonitorPass` builds its pipeline
/// and uniforms from it, and its `present` / `overlayColor` are the CPU reference
/// the GPU is tested against.
///
/// Per pixel: monitor stage → display transform (to the picture encoding) →
/// display adjustments → output conversion (decode the picture transfer to linear
/// display light with 1.0 = graphics white, convert primaries with a 3×3 matrix in
/// linear light, optionally roll highlights off, encode to the target) → overlays
/// in target values (`overlayColor`). Out of gamut: values are clipped to the
/// target after conversion (0…1 for SDR, 0…peak for PQ and HLG); extended linear,
/// and a linear picture written as it is, keep negative and super-white values.
/// No step produces NaN.
public struct MonitorColorPipeline: Equatable, Sendable {
  /// Transfer codes, shared with MKMonitor.msl (`MK_PICTURE_TF`, `MK_TARGET_TF`, `MK_OVERLAY_TF`).
  public enum Transfer: UInt32, Sendable {
    /// BT.709 video on a BT.1886 display, black 0: L = V^2.4.
    case bt1886 = 1, sRGB = 2, gamma22 = 3, linear = 4, pq = 5, hlg = 6
  }
  /// `MK_TRANSFORM`.
  public enum Transform: UInt32, Sendable {
    case none = 0, logToRec709 = 1, pqToSDR = 2, hlgToSDR = 3
  }
  public enum Status: Equatable, Sendable {
    case off
    case active(label: String)
    case unavailable(DisplayTransformUnavailable)
  }
  public struct Encoded: Equatable, Sendable {
    public var transfer: Transfer
    public var primaries: ColorPrimaries
  }

  public let transform: Transform
  /// HDR passthrough is in effect.
  public let passthrough: Bool
  public let status: Status
  /// The picture's encoding after the display transform.
  public let picture: Encoded
  /// The target's encoding; nil for `signalNative` (no conversion).
  public let target: Encoded?
  /// Whether the pass converts the picture into `target`. False for `signalNative`
  /// and for a target that already is the picture's encoding (same transfer and
  /// primaries, nothing rolled off): then the conversion is the identity and the
  /// pass writes the picture unchanged. Extended linear always converts (a linear
  /// picture into it is the identity, up to float rounding of the matrix).
  public let convertsToTarget: Bool
  /// What overlay colours are encoded into; nil when they stay as authored (Rec.709 SDR).
  public let overlay: Encoded?
  public let referenceWhite: Double
  /// The peak HLG is encoded and decoded for: always the 1000 cd/m² reference
  /// display (`HDRToSDR.hlgReferencePeak`, BT.2408-8 §6.2). HLG is scene-referred:
  /// the display applies its own OOTF, so the signal does not depend on its peak,
  /// HLG to HLG is the identity, and graphics white is 75% HLG on every display.
  public let hlgOutputPeak: Double
  /// What PQ passthrough into HLG rolls highlights off to: the output's
  /// `hlgNominalPeak`, at most the reference peak the signal is encoded for.
  public let hlgRolloffPeak: Double
  /// PQ mastering peak for `pqToSDR` and the PQ roll-off.
  public let pqSourcePeak: Double
  public let log: LogEncoding?
  /// The signal's primaries, which the HDR transforms convert from.
  public let sourcePrimaries: ColorPrimaries
  /// Linear picture primaries to target primaries.
  public let pictureToTarget: ColorMatrix
  /// Linear source gamut to Rec.709 for `logToRec709`, `pqToSDR` and `hlgToSDR`.
  public let transformMatrix: ColorMatrix
  /// Linear Rec.709 to the overlay primaries.
  public let overlayMatrix: ColorMatrix
  /// Whether highlights are rolled off before the target encode (HDR passthrough
  /// into extended linear, or PQ into HLG).
  public let rollsOff: Bool

  public init(
    output o: MonitorOutputColor, signal: SignalDescription, transform settings: DisplayTransformSettings = .init(),
    monitorStageHasLUT: Bool = false
  ) {
    let output = o.normalized()
    referenceWhite = output.referenceWhite
    hlgOutputPeak = HDRToSDR.hlgReferencePeak
    hlgRolloffPeak = min(output.hlgNominalPeak, HDRToSDR.hlgReferencePeak)
    pqSourcePeak = settings.pqSourcePeak.isFinite ? min(10_000, max(100, settings.pqSourcePeak)) : 1000
    log = signal.encoding.log
    sourcePrimaries = signal.effectivePrimaries
    var transform = Transform.none
    var passthrough = false
    var status = Status.off
    let hdrTransfer: Transfer? = {
      guard case .display(let t) = signal.encoding else { return nil }
      return t == .pq ? .pq : (t == .hlg ? .hlg : nil)
    }()
    switch settings.mode {
    case .none: break
    case _ where monitorStageHasLUT:
      status = .unavailable(.lutOnMonitorStage)
    case .logToRec709:
      if let log = signal.encoding.log {
        transform = .logToRec709
        status = .active(label: "\(Self.curveName(log.curve)) → Rec.709 · \(DisplayAssist.name)")
      } else {
        status = .unavailable(.requiresLogSource)
      }
    case .hdrToSDR:
      switch hdrTransfer {
      case .pq?:
        transform = .pqToSDR
        status = .active(label: "PQ → SDR · BT.2408 EETF")
      case .hlg?:
        transform = .hlgToSDR
        status = .active(label: "HLG → SDR · BT.2446 Method C")
      default: status = .unavailable(.requiresHDRSource)
      }
    case .hdrPassthrough:
      if hdrTransfer == nil {
        status = .unavailable(.requiresHDRSource)
      } else if case .sdr = output.encoding {
        status = .unavailable(.requiresHDROutput)
      } else {
        passthrough = true
        status = .active(label: "HDR passthrough")
      }
    }
    self.transform = transform
    self.passthrough = passthrough
    self.status = status

    let picture = Self.nativePicture(
      signal: signal, transform: transform == .none ? .none : settings.mode, monitorStageHasLUT: monitorStageHasLUT)
    self.picture = picture
    let target: Encoded?, overlay: Encoded?
    switch output.encoding {
    case .signalNative:
      target = nil
      // Overlays are authored as BT.1886 Rec.709, so on a layer tagged that way (or
      // sRGB Rec.709, W1's convention) they stay as authored. Any other picture
      // (PQ, HLG, extended linear, BT.2020 or P3 SDR) gets them in its own transfer
      // and primaries, as its layer is tagged.
      let asAuthored = picture.primaries == .rec709 && (picture.transfer == .bt1886 || picture.transfer == .sRGB)
      overlay = asAuthored ? nil : picture
    case .sdr(let t):
      target = Encoded(transfer: t == .bt1886 ? .bt1886 : (t == .sRGB ? .sRGB : .gamma22), primaries: output.primaries)
      overlay = target
    case .extendedLinear:
      target = Encoded(transfer: .linear, primaries: output.primaries)
      overlay = target
    case .pq:
      target = Encoded(transfer: .pq, primaries: output.primaries)
      overlay = target
    case .hlg:
      target = Encoded(transfer: .hlg, primaries: output.primaries)
      overlay = target
    }
    self.target = target
    self.overlay = overlay
    pictureToTarget = target.map { picture.primaries.conversion(to: $0.primaries) } ?? .identity
    overlayMatrix = overlay.map { ColorPrimaries.rec709.conversion(to: $0.primaries) } ?? .identity
    switch transform {
    case .logToRec709: transformMatrix = (log?.gamut ?? .rec709).conversion(to: .rec709)
    case .pqToSDR, .hlgToSDR: transformMatrix = sourcePrimaries.conversion(to: .rec709)
    case .none: transformMatrix = .identity
    }
    let hdrPicture = picture.transfer == .pq || picture.transfer == .hlg
    let rollsOff =
      passthrough && hdrPicture
      && (target?.transfer == .linear || (target?.transfer == .hlg && picture.transfer == .pq))
    self.rollsOff = rollsOff
    if let target {
      convertsToTarget = rollsOff || target.transfer == .linear || target != picture
    } else {
      convertsToTarget = false
    }
  }

  /// The picture encoding a signal has after `transform`: the signal's own for
  /// display-referred signals (Rec.709 for unlabelled ones), a code-value Rec.709
  /// view for log, Rec.709 SDR after an SDR transform. A LUT on the monitor stage
  /// (burn-in or monitor) produces Rec.709 display R'G'B', the convention every
  /// LUT stage follows (stage luma, false colour, scopes); no transform runs then.
  static func nativePicture(signal: SignalDescription, transform: DisplayTransform, monitorStageHasLUT: Bool = false)
    -> Encoded
  {
    switch transform {
    case .logToRec709 where signal.encoding.log != nil: return Encoded(transfer: .bt1886, primaries: .rec709)
    case .hdrToSDR where signal.isHDR: return Encoded(transfer: .bt1886, primaries: .rec709)
    default: break
    }
    if monitorStageHasLUT { return Encoded(transfer: .bt1886, primaries: .rec709) }
    guard case .display(let t) = signal.encoding else { return Encoded(transfer: .bt1886, primaries: .rec709) }
    let transfer: Transfer
    switch t {
    case .bt709: transfer = .bt1886
    case .sRGB: transfer = .sRGB
    case .pq: transfer = .pq
    case .hlg: transfer = .hlg
    case .linear: transfer = .linear
    }
    return Encoded(transfer: transfer, primaries: signal.effectivePrimaries)
  }

  static func curveName(_ curve: LogCurve) -> String {
    switch curve {
    case .sLog3: return "S-Log3"
    case .arriLogC3: return "LogC3"
    case .arriLogC4: return "LogC4"
    }
  }

  /// The roll-off for a display headroom, or nil when there is none. Extended
  /// linear: to headroom × graphics white; HLG: to its nominal peak.
  public func rolloff(headroom: Double) -> ToneMapEETF? {
    guard rollsOff, let target else { return nil }
    let source = picture.transfer == .pq ? pqSourcePeak : HDRToSDR.hlgReferencePeak
    let h = headroom.isFinite ? min(64, max(1, headroom)) : 1
    let peak = target.transfer == .hlg ? hlgRolloffPeak : h * referenceWhite
    return ToneMapEETF(sourcePeak: source, targetPeak: peak)
  }

  /// The tone map `pqToSDR` uses.
  public var sdrToneMap: ToneMapEETF { ToneMapEETF(sourcePeak: pqSourcePeak, targetPeak: referenceWhite) }

  // MARK: - CPU reference

  /// Linear display light relative to graphics white, from a value of `transfer`.
  public func linear(_ v: ColorRGB, transfer: Transfer, primaries: ColorPrimaries) -> ColorRGB {
    func each(_ f: (Double) -> Double) -> ColorRGB { ColorRGB(r: f(v.r), g: f(v.g), b: f(v.b)) }
    switch transfer {
    case .bt1886: return each(ColorMath.bt1886EOTF)
    case .sRGB: return each(ColorMath.sRGBDecodeMirrored)
    case .gamma22: return each(ColorMath.gamma22EOTF)
    case .linear: return v
    case .pq: return each { ColorMath.pqNits(max($0, 0)) / referenceWhite }
    case .hlg:
      let f = ColorMath.hlgEOTF(v, peak: HDRToSDR.hlgReferencePeak, weights: primaries.luminanceCoefficients)
      return ColorRGB(r: f.r / referenceWhite, g: f.g / referenceWhite, b: f.b / referenceWhite)
    }
  }

  /// Linear display light relative to graphics white, encoded with `transfer`
  /// and clipped to what it holds. HLG is encoded for its 1000 cd/m² reference
  /// display, the one `linear` decodes it with.
  public func encode(_ l: ColorRGB, transfer: Transfer, primaries: ColorPrimaries) -> ColorRGB {
    func each(_ f: (Double) -> Double) -> ColorRGB { ColorRGB(r: f(l.r), g: f(l.g), b: f(l.b)) }
    func unit(_ x: Double) -> Double { min(max(x, 0), 1) }
    switch transfer {
    case .bt1886: return each { ColorMath.bt1886InverseEOTF(unit($0)) }
    case .sRGB: return each { ColorMath.sRGBEncode(unit($0)) }
    case .gamma22: return each { ColorMath.gamma22InverseEOTF(unit($0)) }
    case .linear: return each { min(max($0, -65504), 65504) }
    case .pq: return each { ColorMath.pqSignal(nits: $0 * referenceWhite) }
    case .hlg:
      return ColorMath.hlgInverseEOTF(
        ColorRGB(r: l.r * referenceWhite, g: l.g * referenceWhite, b: l.b * referenceWhite), peak: hlgOutputPeak,
        weights: primaries.luminanceCoefficients)
    }
  }

  /// The display transform alone: a monitor-stage value (range-expanded, in the
  /// source's encoding) to the picture encoding.
  public func transformed(_ v: ColorRGB, range: CodeRange = .legal, bitDepth: Int = 10) -> ColorRGB {
    switch transform {
    case .none: return v
    case .logToRec709:
      guard let log else { return v }
      return DisplayAssist.rec709(v, log: log, range: range, bitDepth: bitDepth)
    case .pqToSDR:
      return HDRToSDR.pq(v, primaries: sourcePrimaries, sourcePeak: pqSourcePeak, referenceWhite: referenceWhite)
    case .hlgToSDR: return HDRToSDR.hlg(v, primaries: sourcePrimaries)
    }
  }

  /// The output conversion alone: a picture value to the target value. Without a
  /// conversion (`signalNative` or an identical target) it only clips, as the pass
  /// does: to 0…1, or for a linear picture (an extended linear layer) to ±65504.
  public func converted(_ v: ColorRGB, headroom: Double = 1) -> ColorRGB {
    guard let target, convertsToTarget else {
      let (low, high) = picture.transfer == .linear ? (-65504.0, 65504.0) : (0, 1)
      return ColorRGB(r: min(max(v.r, low), high), g: min(max(v.g, low), high), b: min(max(v.b, low), high))
    }
    var l = pictureToTarget.apply(linear(v, transfer: picture.transfer, primaries: picture.primaries))
    if let r = rolloff(headroom: headroom) {
      let w = referenceWhite
      let m = r.apply(ColorRGB(r: l.r * w, g: l.g * w, b: l.b * w))
      l = ColorRGB(r: m.r / w, g: m.g / w, b: m.b / w)
    }
    return encode(l, transfer: target.transfer, primaries: target.primaries)
  }

  /// Transform, then conversion: what the pass shows for a monitor-stage value
  /// with display adjustments and overlays off.
  public func present(_ v: ColorRGB, range: CodeRange = .legal, bitDepth: Int = 10, headroom: Double = 1) -> ColorRGB {
    converted(transformed(v, range: range, bitDepth: bitDepth), headroom: headroom)
  }

  /// The white-point trim on a picture value (after the other display
  /// adjustments): `gains` (`WhitePointTrim.gains` in the picture's primaries)
  /// applied in linear display light, then back into the picture's transfer. The
  /// SDR curves stay mirrored and unclipped, so later stages see the range they
  /// would without the trim.
  public func whiteTrimmed(_ v: ColorRGB, gains g: ColorRGB) -> ColorRGB {
    let l = linear(v, transfer: picture.transfer, primaries: picture.primaries)
    let t = ColorRGB(r: l.r * g.r, g: l.g * g.g, b: l.b * g.b)
    func each(_ f: (Double) -> Double) -> ColorRGB { ColorRGB(r: f(t.r), g: f(t.g), b: f(t.b)) }
    switch picture.transfer {
    case .bt1886: return each(ColorMath.bt1886InverseEOTF)
    case .sRGB: return each(ColorMath.sRGBEncode)
    case .gamma22: return each(ColorMath.gamma22InverseEOTF)
    case .linear: return t
    case .pq, .hlg: return encode(t, transfer: picture.transfer, primaries: picture.primaries)
    }
  }

  /// An overlay colour authored as Rec.709 SDR display R'G'B' at graphics white,
  /// in target values: unchanged on an SDR native layer, else through BT.1886 to
  /// linear light, Rec.709 to the target primaries, and the target's encoding (white
  /// is 58% PQ, 75% HLG, 1.0 extended linear at 203 cd/m²).
  public func overlayColor(_ c: ColorRGB) -> ColorRGB {
    guard let overlay else { return c }
    let unit = ColorRGB(r: min(max(c.r, 0), 1), g: min(max(c.g, 0), 1), b: min(max(c.b, 0), 1))
    let l = overlayMatrix.apply(linear(unit, transfer: .bt1886, primaries: .rec709))
    return encode(l, transfer: overlay.transfer, primaries: overlay.primaries)
  }
}
