import MonitorKit
import MonitorKitScopes
import MonitorKitUI
import SwiftUI

/// The scopes the app offers, in menu order. A choice changes only the scope's
/// kind and mode, so the rest of its settings (the classic 768 × 256 bins,
/// −10…110 IRE range and colours by default) stay as they were.
enum UIScopeChoice: String, CaseIterable, Identifiable, Sendable {
  case rgbParade, luma, rgbOverlay, ycbcrParade, vectorscope, histogram

  var id: String { rawValue }

  var title: String {
    switch self {
    case .rgbParade: return "RGB parade"
    case .luma: return "Luma waveform"
    case .rgbOverlay: return "RGB overlay"
    case .ycbcrParade: return "YCbCr parade"
    case .vectorscope: return "Vectorscope"
    case .histogram: return "Histogram"
    }
  }

  init(_ settings: ScopeSettings) {
    switch settings.kind {
    case .vectorscope: self = .vectorscope
    case .histogram: self = .histogram
    case .waveform:
      switch settings.waveformMode {
      case .rgbParade: self = .rgbParade
      case .luma: self = .luma
      case .rgbOverlay: self = .rgbOverlay
      case .ycbcrParade: self = .ycbcrParade
      }
    }
  }

  /// `settings` showing this scope; nothing else changes.
  func applied(to settings: ScopeSettings) -> ScopeSettings {
    var s = settings
    switch self {
    case .rgbParade: (s.kind, s.waveformMode) = (.waveform, .rgbParade)
    case .luma: (s.kind, s.waveformMode) = (.waveform, .luma)
    case .rgbOverlay: (s.kind, s.waveformMode) = (.waveform, .rgbOverlay)
    case .ycbcrParade: (s.kind, s.waveformMode) = (.waveform, .ycbcrParade)
    case .vectorscope: s.kind = .vectorscope
    case .histogram: s.kind = .histogram
    }
    return s
  }
}

/// The waveform's and histogram's level axis and trace colours. Classic is the
/// look of Ultracam's earlier scopes and the default (`ScopeSettings.ultracamLegacy`).
enum UIScopeLook: String, CaseIterable, Identifiable, Sendable {
  /// −10…110 IRE with the old channel colours.
  case classic
  /// MonitorKit's −7…109 % axis (every legal 10-bit code) and colours.
  case standard

  var id: String { rawValue }

  var title: String {
    switch self {
    case .classic: return "Classic, −10…110 IRE"
    case .standard: return "Standard, −7…109 %"
    }
  }

  /// nil when the range and colours don't belong to one look.
  init?(_ settings: ScopeSettings) {
    switch (settings.levelRange, settings.display.palette) {
    case (.minus10To110, .ultracamLegacy): self = .classic
    case (.standard, .standard): self = .standard
    default: return nil
    }
  }

  /// `settings` with this look's range and colours. The bins stay one per pixel
  /// of the 768 × 256 scope image.
  func applied(to settings: ScopeSettings) -> ScopeSettings {
    var s = settings
    switch self {
    case .classic:
      s.levelRange = .minus10To110
      s.display.palette = .ultracamLegacy
    case .standard:
      s.levelRange = .standard
      s.display.palette = .standard
    }
    return s
  }
}

/// What one target's scope measures and how it is labelled: the scope's
/// settings, the stage signal it measures (the source where no LUT touches the
/// stage, Rec.709 after the burn-in LUT) and the graticule labels, computed from
/// the same inputs MonitorKit draws the graticule lines from. Built only when the
/// settings or the shown signal change, never per frame.
struct UIScopeDescription: Equatable, Sendable {
  /// The size of the scope image the surface draws (`MonitorScopeNSView`).
  static let imageWidth = Double(ScopeSettings.ultracamLegacyImageWidth)
  static let imageHeight = Double(ScopeSettings.ultracamLegacyImageHeight)
  static var imageAspectRatio: Double { imageWidth / imageHeight }

  let settings: ScopeSettings
  let isProgram: Bool
  /// The signal of the measured stage; nil before a frame arrives.
  let signal: SignalDescription?
  /// A LUT changes the measured stage (it is then Rec.709).
  let lutApplied: Bool
  let context: ScopeContext

  init(scopes: MonitorScopePreferences, signal: SignalDescription?, burnInLUT: Bool, isProgram: Bool) {
    let s = scopes.settings.normalized()
    settings = s
    self.isProgram = isProgram
    let lut = s.stage != .source && burnInLUT
    lutApplied = lut
    self.signal = lut ? nil : signal
    // As `ScopeAccumulator` measures it: the frame's range, the matrix the
    // colorimetry picks for the stage.
    context = ScopeContext(
      range: signal?.range ?? .legal,
      matrix: s.colorimetry.matrix(source: signal?.matrix ?? .bt709, lutApplied: lut))
  }

  var choice: UIScopeChoice { UIScopeChoice(settings) }

  /// "RGB parade", "Histogram · Luma", …
  var kindTitle: String {
    switch settings.kind {
    case .histogram:
      switch settings.histogramMode {
      case .luma: return "Histogram · Luma"
      case .rgbOverlay: return "Histogram · RGB"
      case .rgbParade: return "Histogram · RGB parade"
      }
    default: return choice.title
    }
  }

  static func stageTitle(_ stage: SignalStage, isProgram: Bool) -> String {
    if isProgram { return "Program Output" }
    switch stage {
    case .source: return "Source"
    case .output: return "Output (LUT)"
    case .monitor: return "Monitor"
    }
  }

  var stageTitle: String { Self.stageTitle(settings.stage, isProgram: isProgram) }

  /// "RGB parade · Output (LUT)"
  var title: String { "\(kindTitle) · \(stageTitle)" }

  /// The measured stage's HDR transfer, if it is PQ or HLG.
  var hdrTransfer: DisplayTransfer? {
    guard let signal, case .display(let transfer) = signal.encoding, transfer == .pq || transfer == .hlg else {
      return nil
    }
    return transfer
  }

  /// Whether the scope has a level axis (waveform and histogram).
  var hasLevelAxis: Bool { settings.kind != .vectorscope }

  var levelRangeText: String {
    ScopeIREScale(axis: settings.levelRange.low...settings.levelRange.high).rangeText
  }

  static func scaleTitle(_ scale: WaveformScale) -> String {
    switch scale {
    case .percent: return "IRE %"
    case .codeValues: return "10-bit code values"
    case .pqNits: return "PQ cd/m²"
    case .hlgNits: return "HLG cd/m²"
    }
  }

  /// The scale a light-level reading suits for this stage: nits on PQ and HLG.
  var suggestedHDRScale: WaveformScale? {
    switch hdrTransfer {
    case .some(.pq): return .pqNits
    case .some(.hlg): return .hlgNits
    default: return nil
    }
  }

  /// Whether `scale` can be chosen for this stage: the nits scales need its transfer.
  func offers(_ scale: WaveformScale) -> Bool {
    switch scale {
    case .percent, .codeValues: return true
    case .pqNits: return hdrTransfer == .pq
    case .hlgNits: return hdrTransfer == .hlg
    }
  }

  /// Says when the chosen scale does not fit the measured signal.
  var scaleNote: String? {
    guard hasLevelAxis else { return nil }
    let scale = settings.display.waveformScale
    switch scale {
    case .pqNits where hdrTransfer != .pq, .hlgNits where hdrTransfer != .hlg:
      let name = scale == .pqNits ? "PQ" : "HLG"
      return signal == nil && !lutApplied
        ? "No signal yet; the \(name) marks assume a \(name) signal."
        : "This stage is not \(name); the \(name) marks don't read as light here."
    case .percent, .codeValues:
      guard let suggested = suggestedHDRScale else { return nil }
      return "\(hdrTransfer == .pq ? "PQ" : "HLG") signal: the \(Self.scaleTitle(suggested)) scale reads its light levels."
    default:
      return nil
    }
  }

  /// The footnote under the scope.
  var caption: String {
    let d = settings.display
    switch settings.kind {
    case .vectorscope:
      let targets: String
      switch d.vectorscopeTargets {
      case .none: targets = "no targets"
      case .percent75: targets = "75% targets"
      case .percent100: targets = "100% targets"
      case .both: targets = "75% and 100% targets"
      }
      let skin = d.showsSkinToneLine ? " · skin tone line" : ""
      return "Every pixel · Cb/Cr, \(Self.matrixTitle(context.matrix)) · \(settings.vectorscopeZoom)× · \(targets)\(skin)"
    case .waveform, .histogram:
      let counts = settings.kind == .histogram
        ? (d.histogramScale == .logarithmic ? " · logarithmic counts" : " · linear counts") : ""
      switch d.waveformScale {
      case .percent:
        return "Every pixel · \(levelRangeText) IRE · levels outside clamp to the edges\(counts)"
      case .codeValues:
        return "Every pixel · 10-bit code values, \(context.range == .legal ? "legal" : "full") range\(counts)"
      case .pqNits:
        return "Every pixel · PQ (SMPTE ST 2084) cd/m²\(counts)"
      case .hlgNits:
        return "Every pixel · HLG (BT.2100) cd/m² on a 1000 cd/m² display\(counts)"
      }
    }
  }

  static func matrixTitle(_ matrix: YCbCrMatrix) -> String {
    switch matrix {
    case .bt601: return "BT.601"
    case .bt709: return "BT.709"
    case .bt2020: return "BT.2020"
    case .smpte240m: return "SMPTE 240M"
    }
  }

  /// The graticule's labels, in normalized coordinates of the scope image:
  /// the same `ScopeGraticule` MonitorKit draws the lines from, on the same image.
  var labels: [ScopeLabel] {
    var labels = ScopeGraticule(
      settings: settings, context: context, viewportWidth: Self.imageWidth, viewportHeight: Self.imageHeight
    ).labels
    // Targets are labelled only where their boxes are drawn.
    if !settings.display.showsGraticule { labels.removeAll { $0.role == .target } }
    return labels
  }

  /// The labels that fit an image `width` × `height` points: every tick label
  /// when they keep `spacing` apart, otherwise the major ticks that keep clear
  /// of each other and then the axis ends that keep clear of those. Measured
  /// where the labels are drawn (kept inside the image), per parade panel.
  func visibleLabels(width: Double, height: Double, spacing: Double = 11) -> [ScopeLabel] {
    let all = labels
    let ticks = all.filter { $0.role == .tick }
    guard !ticks.isEmpty else { return all }
    let horizontal = settings.kind == .histogram
    let length = horizontal ? width : height
    let margin = horizontal ? 8.0 : 5.0
    // Side by side, labels need room for their width (up to five characters).
    let spacing = horizontal ? max(spacing, 26) : spacing
    func drawn(_ label: ScopeLabel) -> Double {
      let v = (horizontal ? label.position.x : label.position.y) * length
      return min(max(margin, length - margin), max(margin, v))
    }
    func clear(_ label: ScopeLabel, of others: [ScopeLabel]) -> Bool {
      others.allSatisfy { abs(drawn($0) - drawn(label)) >= spacing }
    }
    var kept: [ScopeLabel] = []
    // The Y'CbCr parade's chroma panel has its own ticks at its own x.
    for panel in Set(ticks.map { horizontal ? 0 : $0.position.x }) {
      let group = ticks.filter { (horizontal ? 0 : $0.position.x) == panel }.sorted { drawn($0) < drawn($1) }
      if zip(group, group.dropFirst()).allSatisfy({ drawn($1) - drawn($0) >= spacing }) {
        kept += group
        continue
      }
      var chosen: [ScopeLabel] = []
      for label in group where label.isMajor && clear(label, of: chosen) { chosen.append(label) }
      for label in [group.first, group.last].compactMap({ $0 }) where !chosen.contains(label) {
        if clear(label, of: chosen) { chosen.append(label) }
      }
      kept += chosen
    }
    return all.filter { $0.role != .tick } + ticks.filter { kept.contains($0) }
  }
}

/// A clip readout from a scope's GPU statistics: the share of pixels at or above
/// the scope's high clip level and at or below its low one, per R, G, B and luma,
/// plus the luma extremes and average. Built from the values, so it can be shown
/// and checked without a GPU.
struct UIScopeReadout: Equatable, Sendable {
  var pixelCount: Int
  var clippedHigh: SIMD4<Double>
  var clippedLow: SIMD4<Double>
  var lumaMinimum: Double
  var lumaMaximum: Double
  var lumaAverage: Double

  init(
    pixelCount: Int, clippedHigh: SIMD4<Double>, clippedLow: SIMD4<Double>, lumaMinimum: Double,
    lumaMaximum: Double, lumaAverage: Double
  ) {
    self.pixelCount = pixelCount
    self.clippedHigh = clippedHigh
    self.clippedLow = clippedLow
    self.lumaMinimum = lumaMinimum
    self.lumaMaximum = lumaMaximum
    self.lumaAverage = lumaAverage
  }

  init?(_ statistics: ScopeStatistics?) {
    guard let s = statistics, s.pixelCount > 0 else { return nil }
    self.init(
      pixelCount: s.pixelCount, clippedHigh: s.clippedHigh, clippedLow: s.clippedLow, lumaMinimum: s.lumaMinimum,
      lumaMaximum: s.lumaMaximum, lumaAverage: s.lumaAverage)
  }

  /// One decimal; a share too small for 0.1% but not zero reads "<0.1%", so a
  /// few clipped pixels never read as none.
  static func percent(_ fraction: Double) -> String {
    guard fraction.isFinite else { return "—" }
    let p = min(max(fraction, 0), 1) * 100
    if p > 0 && p < 0.05 { return "<0.1%" }
    return String(format: "%.1f%%", p)
  }

  static func level(_ value: Double) -> String {
    value.isFinite ? String(format: "%.0f", value * 100) : "—"
  }

  static func channels(_ v: SIMD4<Double>) -> String {
    "R \(percent(v.x))  G \(percent(v.y))  B \(percent(v.z))  Y \(percent(v.w))"
  }

  /// "Over 100%  R 0.0%  G 0.0%  B 1.2%  Y 0.3%", "Under 0%  …" and the luma
  /// line; dashes before the first measurement.
  static func lines(_ readout: UIScopeReadout?, settings: ScopeSettings) -> (high: String, low: String, luma: String) {
    let high = "Over \(level(settings.clipHighPercent / 100))%"
    let low = "Under \(level(settings.clipLowPercent / 100))%"
    guard let r = readout else { return (high + "  —", low + "  —", "Luma  —") }
    return (
      high + "  " + channels(r.clippedHigh), low + "  " + channels(r.clippedLow),
      "Luma  min \(level(r.lumaMinimum))%  avg \(level(r.lumaAverage))%  max \(level(r.lumaMaximum))%"
    )
  }
}
