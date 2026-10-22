import Foundation

/// Six bands on display IRE, in the style of on-camera-monitor false colour.
/// The manufacturer publishes band names but not edges, so these edges are
/// Ultracam's own convention, versioned so saved looks never shift silently.
public enum SixBandFalseColor {
  public static let profileID = "ultracam-six-band-v1"
  public static let displayName = "Six band"
  /// Rec.709 18% grey is 40.9 IRE; one stop over it is 59.5 IRE.
  public static let bands: [FalseColorBand] = [
    FalseColorBand(lower: -.infinity, upper: 2.5, color: ColorRGB(r: 0.6, g: 0, b: 1)),  // black clip
    FalseColorBand(lower: 2.5, upper: 8, color: ColorRGB(r: 0, g: 0.3, b: 1)),  // near black
    FalseColorBand(lower: 38.4, upper: 43.4, color: ColorRGB(r: 0, g: 1, b: 0)),  // middle grey
    FalseColorBand(lower: 56.4, upper: 62.4, color: ColorRGB(r: 1, g: 0.45, b: 0.75)),  // +1 stop, skin
    FalseColorBand(lower: 93, upper: 99, color: ColorRGB(r: 1, g: 1, b: 0)),  // near white clip
    FalseColorBand(lower: 99, upper: .infinity, color: ColorRGB(r: 1, g: 0, b: 0)),  // white clip
  ]
}

public enum FalseColorBands {
  /// First band containing `value` (lower inclusive, upper exclusive), or nil for a gap.
  /// Infinite values classify too: no light at all is -∞ stops, inside an open lowest band.
  public static func color(_ value: Double, bands: [FalseColorBand]) -> ColorRGB? {
    guard !value.isNaN else { return nil }
    return bands.first { value >= $0.lower && value < $0.upper }?.color
  }
}

/// What a false-colour mode classifies, and the bands it classifies with. The
/// GPU reads exactly these tables, so the Core references and the shader share
/// one set of constants.
public enum FalseColorTable {
  /// The unit a mode's bands are written in.
  public enum Measure: Sendable, Equatable {
    /// Native S-Log3 signal IRE, `(code - 64) / 876 * 100` (Sony Pattern 2).
    case sonyNativeIRE
    /// LogC3 EI800 full-range 10-bit code of S-Log3 scene-linear Y (ARRI-style).
    case logC3ReferenceCode
    /// The LogC transport code in the declared table range (literal ARRI).
    case logCCode
    /// Stops over 18% grey of S-Log3 scene-linear Y, plus the user offset (EL Zone).
    case sLog3Stops
    /// IRE of the chosen stage.
    case stageIRE
    /// Stops over 18% grey: scene-linear Y of a log source, else the stage's Rec.709 signal.
    case stageStops
  }

  public static func measure(for settings: FalseColorSettings) -> Measure? {
    switch settings.mode {
    case .off: return nil
    case .sonySLog3: return .sonyNativeIRE
    case .arriStyleSLog3: return .logC3ReferenceCode
    case .arriLogC: return .logCCode
    case .elZone: return .sLog3Stops
    case .sixBand: return .stageIRE
    case .custom: return settings.customUnit == .ire ? .stageIRE : .stageStops
    }
  }

  /// Whether a frame classifies against ARRI's full-range LogC tables: the
  /// container is full range or float (float RGB carries full 10-bit levels), or
  /// the camera's full-range codes were squeezed into a legal container
  /// (`.fullRescaledToLegal`). The range follows how the codes reached us, not
  /// only the container flag. `MonitorPass` and legends share this rule.
  public static func usesFullRangeARRI(signal: SignalDescription, layout: PixelLayout? = nil) -> Bool {
    signal.range == .full || layout?.isFloat == true || signal.encoding.log?.transport == .fullRescaledToLegal
  }

  /// The literal ARRI table for a LogC curve.
  public static func arriProfile(for curve: LogCurve) -> ARRIFalseColorProfile? {
    switch curve {
    case .arriLogC3: return .logC3EI800
    case .arriLogC4: return .alexa35LogC4EI800
    case .sLog3: return nil
    }
  }

  /// Bands in the unit of `measure(for:)`, lower edge inclusive, upper exclusive,
  /// first match wins. `arriCurve` and `arriFullRange` select the literal ARRI table.
  public static func bands(
    for settings: FalseColorSettings, arriCurve: LogCurve? = nil, arriFullRange: Bool = false
  ) -> [FalseColorBand] {
    switch settings.mode {
    case .off: return []
    case .sonySLog3:
      return SonySLog3FalseColor.zones.map {
        FalseColorBand(lower: $0.lowerIRE, upper: $0.upperIRE, color: $0.category.color)
      }
    case .arriStyleSLog3:
      return arriBands(.logC3EI800, range: .full)
    case .arriLogC:
      guard let curve = arriCurve, let profile = arriProfile(for: curve) else { return [] }
      return arriBands(profile, range: arriFullRange ? .full : .legal)
    case .elZone:
      // Black owns -6 itself: its upper edge is the next value after -6, in the
      // GPU's Float as well as in Double.
      let t = ELZoneProfile.transitions, p = ELZoneProfile.palette
      var bands = [FalseColorBand(lower: -.infinity, upper: Double(Float(t[0]).nextUp), color: p[0])]
      bands.append(FalseColorBand(lower: Double(Float(t[0]).nextUp), upper: t[1], color: p[1]))
      for i in 2..<t.count { bands.append(FalseColorBand(lower: t[i - 1], upper: t[i], color: p[i])) }
      bands.append(FalseColorBand(lower: t[t.count - 1], upper: .infinity, color: p[t.count]))
      return bands
    case .sixBand: return SixBandFalseColor.bands
    case .custom: return Array(settings.customBands.prefix(FalseColorSettings.maximumCustomBands))
    }
  }

  static func arriBands(_ profile: ARRIFalseColorProfile, range: CodeRange) -> [FalseColorBand] {
    profile.zones(range: range).map {
      FalseColorBand(lower: $0.lower, upper: $0.upper, color: $0.category.color)
    }
  }
}
