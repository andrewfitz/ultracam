import MonitorKit
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
    /// The swatch's label in the captioned legend: "Green: 38.9–42.2 IRE" for
    /// Sony, the chart's stop ("≤−6", "+0.5", "≥+6") for EL Zone, else
    /// "name: range".
    public var swatchLabel: String
  }

  public var title: String
  public var unit: Unit
  /// In `FalseColorTable.bands` order (first match wins); `displayOrder` sorts brightest first.
  public var entries: [Entry]
  /// The mode's reference is not verified against the device it follows (EL Zone).
  public var isProvisional: Bool
  /// What a pixel in no band shows.
  public var gapNote: String?

  /// One line naming the mode, what it measures and the source:
  /// "Sony S-Log3 · Source IRE · Sony S-Gamut3.Cine / S-Log3". The source is
  /// left out when no signal was given.
  public var headline: String
  /// What the mode measures: "Source IRE", "Source stops", "Source 10-bit code".
  public var analysis: String
  /// The source's camera and log, from the signal: "Sony S-Gamut3 / S-Log3",
  /// "ARRI Wide Gamut 4 / LogC4"; "Unknown source profile" for a signal that is
  /// not log; nil without a signal.
  public var sourceName: String?
  /// The lines above the swatches: the reference the bands follow and how to
  /// read them (the Sony Pattern 2 thresholds, the EL Zone chart and offset,
  /// the ARRI table and range).
  public var captions: [String]
  /// The lines below the swatches: band-edge conventions and caveats.
  public var footnotes: [String]
  /// Why the mode's reference is provisional (EL Zone), for a tooltip.
  public var provisionalReason: String?
  /// Set when `signal` is not a source this mode classifies: Sony Pattern 2
  /// needs S-Log3 in any gamut (its thresholds are native S-Log3 IRE); EL Zone
  /// and the ARRI-style S-Log3 bands need S-Log3 in S-Gamut3 or S-Gamut3.Cine.
  /// The pass applies the same rule and reports it through `MonitorStatus`.
  public var unavailableNote: String?
  /// Whether the captioned legend lays its swatches out as a chart grid (the
  /// EL Zone stops) rather than labelled rows.
  public var showsSwatchesAsGrid: Bool

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
      let name = i < names.count ? names[i] : "Band \(i + 1)"
      let range = Self.range(band.lower, band.upper, unit: unit)
      entries.append(
        Entry(
          id: i, color: band.color, lower: band.lower, upper: band.upper, name: name, range: range,
          swatchLabel: Self.swatchLabel(
            settings.mode, index: i, count: bands.count, band: band, name: name, range: range)))
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
    analysis = Self.analysis(measure, stage: settings.stage)
    sourceName = signal.map { Self.sourceName($0.encoding.log) }
    showsSwatchesAsGrid = settings.mode == .elZone
    provisionalReason = settings.mode == .elZone ? ELZoneReferenceStatus.reason : nil
    unavailableNote =
      signal != nil && !Self.classifies(settings.mode, log: log)
      ? "Unavailable: choose a supported Sony S-Log3 source profile" : nil
    let text = Self.captions(settings, curve: log?.curve, full: full)
    captions = text.captions
    let rescaled = log?.transport == .fullRescaledToLegal
    footnotes = text.footnotes + (rescaled ? ["Log transport: full codes rescaled to legal"] : [])
    headline = ([Self.shortName(settings.mode, curve: log?.curve), analysis] + (sourceName.map { [$0] } ?? []))
      .joined(separator: " · ")
  }

  /// Whether `mode` classifies a source with `log`, by the rule the pass uses
  /// (`MonitorPass.resolveFalseColor`): Sony Pattern 2 classifies native S-Log3
  /// IRE, so any S-Log3 gamut; EL Zone and the ARRI-style bands are offered
  /// only on Sony's S-Gamut3 / S-Gamut3.Cine S-Log3 profiles
  /// (`ELZoneProfile.supports`). Other modes are not judged here (the ARRI LogC legend has no
  /// bands without LogC; six-band and custom need no log source).
  static func classifies(_ mode: FalseColorMode, log: LogEncoding?) -> Bool {
    let sLog3 = log?.curve == .sLog3
    let sGamut = sLog3 && (log?.gamut == .sGamut3 || log?.gamut == .sGamut3Cine)
    switch mode {
    case .sonySLog3: return sLog3
    case .elZone, .arriStyleSLog3: return sGamut
    case .off, .arriLogC, .sixBand, .custom: return true
    }
  }

  // Captions. Sony's are the Pattern 2 conventions (Sony Monitor & Control,
  // `SonySLog3FalseColor.specificationVersion`): thresholds on native S-Log3
  // IRE, independent of EI. EL Zone's are the public chart's (`ELZoneProfile`):
  // stops over 18% grey after an additive offset, interior band edges at the
  // midpoints between the chart's labels, black at or below −6 and white at or
  // above +6. ARRI's name the published 10-bit table and its range.
  static func captions(
    _ s: FalseColorSettings, curve: LogCurve?, full: Bool
  ) -> (captions: [String], footnotes: [String]) {
    let edges = "Lower edge included; upper excluded."
    switch s.mode {
    case .off:
      return ([], [])
    case .sonySLog3:
      return (
        ["Sony Monitor & Control Pattern 2 thresholds · MonitorKit display colours"],
        [
          "Lower edge included; upper excluded. Unassigned IRE stays grey.",
          "EI-independent source IRE bands do not guarantee Sony sensor clipping.",
        ]
      )
    case .elZone:
      return (
        [
          "Public-chart mapping · Sony M&C match not tested",
          "18% grey = 0 stops before monitor offset",
          "Additive monitor offset: \(String(format: "%+.2f", s.referenceOffsetStops)) stops · camera EI independent",
        ],
        ["Chart labels in stops · midpoint interior bands · black ≤−6, white ≥+6"]
      )
    case .arriStyleSLog3:
      return (
        [
          "ARRI LogC3 EI 800 reference bands from S-Log3 scene luminance · not an ARRI or Sony mode",
          "Full-range 10-bit reference codes (\(ARRIFalseColorProfile.specificationVersion))",
        ],
        [edges, "The EI 800 reference does not describe the Sony sensor's clipping or noise floor."]
      )
    case .arriLogC:
      let ei = curve.flatMap { FalseColorTable.arriProfile(for: $0) }?.exposureIndex ?? 800
      return (
        [
          "ARRI published 10-bit code table (\(ARRIFalseColorProfile.specificationVersion)) · EI \(ei)",
          full ? "Full-range codes (0–1023)" : "Legal-range codes (64–940)",
        ],
        [edges]
      )
    case .sixBand:
      return (["Six bands on \(s.stage.title.lowercased()) IRE"], [edges])
    case .custom:
      let unit = s.customUnit == .ire ? "IRE" : "stops"
      return (["Custom bands on \(s.stage.title.lowercased()) \(unit) · first match wins"], [edges])
    }
  }

  static func analysis(_ m: FalseColorTable.Measure, stage: SignalStage) -> String {
    switch m {
    case .sonyNativeIRE: return "Source IRE"
    case .sLog3Stops: return "Source stops"
    case .logCCode: return "Source 10-bit code"
    case .logC3ReferenceCode: return "LogC3 EI 800 reference code"
    case .stageIRE: return "\(stage.title) IRE"
    case .stageStops: return "\(stage.title) stops"
    }
  }

  /// The mode's name in the headline.
  static func shortName(_ mode: FalseColorMode, curve: LogCurve?) -> String {
    switch mode {
    case .elZone: return "EL Zone"
    case .arriLogC:
      return curve.flatMap { FalseColorTable.arriProfile(for: $0)?.displayName } ?? "ARRI LogC"
    default: return mode.title
    }
  }

  /// "Sony S-Gamut3.Cine / S-Log3", "ARRI Wide Gamut 3 / LogC3".
  static func sourceName(_ log: LogEncoding?) -> String {
    guard let log else { return "Unknown source profile" }
    let gamut: String
    switch log.gamut {
    case .rec709: gamut = "Rec.709"
    case .rec2020: gamut = "Rec.2020"
    case .sGamut3: gamut = "S-Gamut3"
    case .sGamut3Cine: gamut = "S-Gamut3.Cine"
    case .arriWideGamut3: gamut = "ARRI Wide Gamut 3"
    case .arriWideGamut4: gamut = "ARRI Wide Gamut 4"
    }
    switch log.curve {
    case .sLog3: return "Sony \(gamut) / S-Log3"
    case .arriLogC3: return "\(gamut) / LogC3"
    case .arriLogC4: return "\(gamut) / LogC4"
    }
  }

  /// Sony: "Green: 38.9–42.2 IRE" (one decimal, as Sony prints the thresholds).
  /// EL Zone: the chart's stop labels. Others: "name: range".
  static func swatchLabel(
    _ mode: FalseColorMode, index: Int, count: Int, band: FalseColorBand, name: String, range: String
  ) -> String {
    switch mode {
    case .sonySLog3:
      return "\(name): \(String(format: "%.1f", band.lower))–\(String(format: "%.1f", band.upper)) IRE"
    case .elZone:
      if index == 0 { return "≤−6" }
      if index == count - 1 { return "≥+6" }
      let labels = ELZoneProfile.stopLabels
      return index < labels.count ? String(format: "%+g", labels[index]) : range
    default:
      return "\(name): \(range)"
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

/// A false-colour legend. `.list`: a swatch, name and range per band, brightest
/// first. `.captioned`: the monitor-chrome legend, with the headline, the
/// reference's captions, a compact swatch per band (labelled rows, or the EL
/// Zone stops as a chart grid) and the footnotes. Both use label colours and
/// outlined swatches, so they read in light and dark appearances.
public struct FalseColorLegendView: View {
  public enum Style: Sendable, Equatable {
    case list
    case captioned
  }

  let legend: FalseColorLegend
  let style: Style
  let unavailable: MonitorUnavailableReason?

  public init(legend: FalseColorLegend) {
    self.legend = legend
    style = .list
    unavailable = nil
  }

  /// `unavailable` (the surface status's reason for `.falseColor`) replaces the
  /// swatches with why the mode is not drawn.
  public init(legend: FalseColorLegend, style: Style, unavailable: MonitorUnavailableReason? = nil) {
    self.legend = legend
    self.style = style
    self.unavailable = unavailable
  }

  public var body: some View {
    switch style {
    case .list: list
    case .captioned: captioned
    }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Text(legend.title).font(.caption.weight(.semibold))
        if legend.isProvisional { ProvisionalBadge(reason: legend.provisionalReason) }
        Spacer(minLength: 0)
        Text(legend.unit.symbol).font(.caption2).foregroundStyle(.secondary)
      }
      ForEach(legend.displayOrder) { e in
        HStack(spacing: 6) {
          Swatch(color: e.color, width: 14, height: 10)
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

  /// Why nothing is drawn: the surface's reason, else the legend's own check.
  var unavailableText: String? { unavailable.map { "Unavailable: \($0.description)" } ?? legend.unavailableNote }

  private var captioned: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Text(legend.headline).fixedSize(horizontal: false, vertical: true)
        if legend.isProvisional { ProvisionalBadge(reason: legend.provisionalReason) }
      }
      if let reason = unavailableText {
        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
      } else {
        ForEach(Array(legend.captions.enumerated()), id: \.offset) { _, line in Text(line) }
        if legend.showsSwatchesAsGrid {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), alignment: .leading)], alignment: .leading, spacing: 3) {
            swatches
          }
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { swatches }
            VStack(alignment: .leading, spacing: 3) { swatches }
          }
        }
        ForEach(Array(legend.footnotes.enumerated()), id: \.offset) { _, line in
          Text(line).foregroundStyle(.secondary)
        }
      }
    }
    .font(.caption2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("False colour legend, \(legend.headline)")
  }

  @ViewBuilder private var swatches: some View {
    ForEach(legend.entries) { e in
      HStack(spacing: 3) {
        Swatch(color: e.color, width: 9, height: 9)
        Text(e.swatchLabel).monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(e.name), \(e.range) \(legend.unit.symbol)")
    }
  }
}

/// A band's colour, outlined so white and black bands show on either appearance.
struct Swatch: View {
  let color: ColorRGB
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(color.color)
      .frame(width: width, height: height)
      .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
  }
}

struct ProvisionalBadge: View {
  let reason: String?

  var body: some View {
    Text("Provisional")
      .font(.caption2)
      .padding(.horizontal, 4)
      .background(Capsule().fill(Color.orange.opacity(0.3)))
      .help(reason ?? "")
      .accessibilityHint(reason ?? "")
  }
}
