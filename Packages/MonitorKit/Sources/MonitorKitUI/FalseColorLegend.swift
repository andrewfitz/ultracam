import MonitorKitCore
import SwiftUI

/// The legend of a false-colour mode: the exact bands the GPU classifies with
/// (`FalseColorTable.bands`), each with its name, its range in the mode's unit
/// and its colour. Built when the settings change, never per frame.
public struct FalseColorLegend: Equatable, Sendable {
  public enum Unit: Equatable, Sendable {
    /// IRE: 0 black, 100 nominal white. Sony's mode uses native S-Log3 IRE.
    case ire
    /// 10-bit code values (the ARRI tables).
    case code
    /// Stops over 18% grey.
    case stops

    public var symbol: String {
      switch self {
      case .ire: return "IRE"
      case .code: return "10-bit code"
      case .stops: return "stops"
      }
    }
  }

  public struct Entry: Equatable, Sendable, Identifiable {
    /// The band's index in `FalseColorTable.bands`.
    public var id: Int
    public var color: ColorRGB
    /// Lower edge inclusive, upper exclusive, in `unit`; infinite for open ends.
    public var lower: Double
    public var upper: Double
    public var name: String
    /// The range as printed: "38.4–43.4", "≥ 99", "< 2.5".
    public var range: String
  }

  public var title: String
  public var unit: Unit
  /// In `FalseColorTable.bands` order (first match wins); `displayOrder` sorts brightest first.
  public var entries: [Entry]
  /// The mode's reference is not verified against the device it follows (EL Zone).
  public var isProvisional: Bool
  /// What a pixel in no band shows.
  public var gapNote: String?

  /// Nil when the mode is off or has no bands (an ARRI LogC table without a
  /// LogC signal, custom with none). `signal` picks the ARRI table: its curve,
  /// and the full-range table by the picture's rule
  /// (`FalseColorTable.usesFullRangeARRI(signal:layout:)`: a full or float
  /// container, or a transport rescaled from full). `arriFullRange` overrides that.
  public init?(
    settings: FalseColorSettings, signal: SignalDescription? = nil, layout: PixelLayout? = nil,
    arriFullRange: Bool? = nil
  ) {
    guard let measure = FalseColorTable.measure(for: settings) else { return nil }
    let log = signal?.encoding.log
    let full = arriFullRange ?? signal.map { FalseColorTable.usesFullRangeARRI(signal: $0, layout: layout) } ?? false
    let bands = FalseColorTable.bands(for: settings, arriCurve: log?.curve, arriFullRange: full)
    guard !bands.isEmpty else { return nil }
    let names = Self.names(settings.mode, count: bands.count, curve: log?.curve, full: full)
    switch measure {
    case .sonyNativeIRE, .stageIRE: unit = .ire
    case .logC3ReferenceCode, .logCCode: unit = .code
    case .sLog3Stops, .stageStops: unit = .stops
    }
    var entries: [Entry] = []
    for (i, band) in bands.enumerated() {
      entries.append(
        Entry(
          id: i, color: band.color, lower: band.lower, upper: band.upper,
          name: i < names.count ? names[i] : "Band \(i + 1)",
          range: Self.range(band.lower, band.upper, unit: unit)))
    }
    self.entries = entries
    isProvisional = settings.mode == .elZone
    switch settings.mode {
    case .sonySLog3, .arriStyleSLog3, .arriLogC, .sixBand, .custom: gapNote = "Other levels show in greyscale."
    case .elZone, .off: gapNote = nil
    }
    switch settings.mode {
    case .arriLogC:
      let profile = log.flatMap { FalseColorTable.arriProfile(for: $0.curve) }
      title = (profile?.displayName ?? "ARRI LogC") + (full ? " · full range" : " · legal range")
    default:
      title = settings.mode.title
    }
  }

  /// Brightest band first, as a monitor's legend reads top to bottom.
  public var displayOrder: [Entry] { entries.sorted { ($0.lower, $0.upper) > ($1.lower, $1.upper) } }

  // Names. Sony publishes Pattern 2 by colour only, so its bands are named by
  // colour. ARRI's meanings are ARRI's (ALEXA false-colour documentation):
  // purple black clipping, blue just above black, green 18% grey, pink one stop
  // over grey (skin), yellow just below white clipping, red white clipping. The
  // six-band names are the Video Assist chart's labels.
  static func names(_ mode: FalseColorMode, count: Int, curve: LogCurve?, full: Bool) -> [String] {
    switch mode {
    case .off: return []
    case .sonySLog3: return SonySLog3FalseColor.zones.map { colorName($0.category.rawValue) }
    case .arriStyleSLog3: return ARRIFalseColorProfile.logC3EI800.zones(range: .full).map { arriName($0.category) }
    case .arriLogC:
      guard let curve, let profile = FalseColorTable.arriProfile(for: curve) else { return [] }
      return profile.zones(range: full ? .full : .legal).map { arriName($0.category) }
    case .elZone:
      return ELZoneProfile.stopLabels.map { s in
        switch s {
        case 0: return "18% grey"
        case ...(-6): return "−6 stops and below"
        case 6...: return "+6 stops and above"
        default: return Self.signed(s) + (abs(s) == 1 || abs(s) == 0.5 ? " stop" : " stops")
        }
      }
    case .sixBand: return ["Black clip", "Near black", "18% grey", "+1 stop · skin", "Near white clip", "White clip"]
    case .custom: return (0..<count).map { "Band \($0 + 1)" }
    }
  }

  static func arriName(_ c: ARRIFalseColorCategory) -> String {
    switch c {
    case .red: return "White clipping"
    case .yellow: return "Just below white clipping"
    case .pink: return "One stop over grey · skin"
    case .green: return "18% grey"
    case .blue: return "Just above black clipping"
    case .purple: return "Black clipping"
    }
  }

  /// "lightPink" → "Light pink".
  static func colorName(_ raw: String) -> String {
    var out = ""
    for ch in raw {
      if ch.isUppercase {
        out.append(" ")
        out.append(Character(ch.lowercased()))
      } else {
        out.append(ch)
      }
    }
    return out.prefix(1).uppercased() + out.dropFirst()
  }

  static func range(_ lower: Double, _ upper: Double, unit: Unit) -> String {
    func f(_ v: Double) -> String {
      switch unit {
      case .ire: return MonitorFormat.number(v, digits: 1)
      case .code: return MonitorFormat.number(v, digits: 0)
      case .stops: return signed(v)
      }
    }
    switch (lower.isFinite, upper.isFinite) {
    case (false, false): return "all"
    case (false, true):
      // An edge one Float step above a printed value (EL Zone's black owns −6) is inclusive of it.
      let shown = (upper * 100).rounded() / 100
      return upper > shown && upper - shown < 1e-5 ? "≤ \(f(shown))" : "< \(f(upper))"
    case (true, false): return "≥ \(f(lower))"
    case (true, true): return "\(f(lower)) – \(f(upper))"
    }
  }

  /// "+0.5", "−1", "0".
  static func signed(_ v: Double) -> String {
    let shown = (v * 100).rounded() / 100
    let text = MonitorFormat.number(abs(shown), digits: 2)
    return shown > 0 ? "+" + text : shown < 0 ? "−" + text : text
  }
}

/// A false-colour legend: a swatch, name and range per band, brightest first.
public struct FalseColorLegendView: View {
  let legend: FalseColorLegend

  public init(legend: FalseColorLegend) { self.legend = legend }

  public var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Text(legend.title).font(.caption.weight(.semibold))
        if legend.isProvisional {
          Text("Provisional")
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(Capsule().fill(Color.orange.opacity(0.3)))
        }
        Spacer(minLength: 0)
        Text(legend.unit.symbol).font(.caption2).foregroundStyle(.secondary)
      }
      ForEach(legend.displayOrder) { e in
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2)
            .fill(e.color.color)
            .frame(width: 14, height: 10)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
          Text(e.name).font(.caption)
          Spacer(minLength: 4)
          Text(e.range).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(e.name), \(e.range) \(legend.unit.symbol)")
      }
      if let note = legend.gapNote {
        Text(note).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("False colour legend, \(legend.title)")
  }
}
