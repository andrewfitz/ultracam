import MonitorKit
import MonitorKitCore
import SwiftUI

extension Binding where Value == MonitorState {
  /// The same state, but every write stores `normalized()`: derive the controls'
  /// bindings from it (`$state.normalizing.zebras[0].level`) and no control needs
  /// range logic of its own. Core is the one place values are clamped.
  public var normalizing: Binding<MonitorState> {
    Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0.normalized() })
  }
}

extension ColorRGB {
  /// The colour as a SwiftUI colour. Values are Rec.709 display R'G'B', drawn
  /// as sRGB (the same primaries; UI swatches need no closer match).
  public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

  /// From a SwiftUI colour, as sRGB components clamped to 0…1.
  public init(_ color: Color, in environment: EnvironmentValues = EnvironmentValues()) {
    let c = color.resolve(in: environment)
    func clamp(_ v: Float) -> Double { min(1, max(0, Double(v))) }
    self.init(r: clamp(c.red), g: clamp(c.green), b: clamp(c.blue))
  }
}

/// A `ColorRGB` binding as a `Color` binding, for `ColorPicker`.
func colorBinding(_ rgb: Binding<ColorRGB>) -> Binding<Color> {
  Binding(get: { rgb.wrappedValue.color }, set: { rgb.wrappedValue = ColorRGB($0) })
}

/// A titled group of controls with the compact, dark-friendly look of an
/// on-camera monitor menu.
public struct MonitorControlSection<Content: View>: View {
  let title: String
  let content: Content

  public init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      content
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
  }
}

extension View {
  /// Compact controls in a dark appearance, as the monitor panels are designed.
  public func monitorControlStyle() -> some View {
    controlSize(.small)
      .font(.callout)
      .environment(\.colorScheme, .dark)
  }
}

/// A labelled slider with its value printed beside it (monospaced digits) and
/// read out by VoiceOver.
struct ValueSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double?
  let format: (Double) -> String

  init(
    _ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
    format: @escaping (Double) -> String
  ) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
    self.format = format
  }

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        if let step {
          Slider(value: $value, in: range, step: step)
        } else {
          Slider(value: $value, in: range)
        }
        Text(format(value))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(minWidth: 52, alignment: .trailing)
      }
    } label: {
      Text(title)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(format(value))
    .accessibilityAdjustableAction { direction in
      let s = step ?? (range.upperBound - range.lowerBound) / 20
      switch direction {
      case .increment: value = min(range.upperBound, value + s)
      case .decrement: value = max(range.lowerBound, value - s)
      @unknown default: break
      }
    }
  }
}

/// Why a tool that is on is not drawn, from the surface's status.
struct UnavailableNote: View {
  let reason: MonitorUnavailableReason?

  var body: some View {
    if let reason {
      Label(reason.description, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityLabel("Unavailable: \(reason.description)")
    }
  }
}

/// Number formats shared by the controls.
enum MonitorFormat {
  static func ire(_ v: Double) -> String { String(format: "%.0f IRE", v) }
  static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
  static func signedPercent(_ v: Double) -> String { String(format: "%+.0f%%", v * 100) }
  static func gain(_ v: Double) -> String { String(format: "%.2f×", v) }
  static func stops(_ v: Double) -> String { String(format: "%+.1f st", v) }
  static func kelvin(_ v: Double) -> String { String(format: "%.0f K", v) }
  static func duv(_ v: Double) -> String { String(format: "%+.3f", v) }
  static func points(_ v: Double) -> String { String(format: "%.1f pt", v) }
  static func nits(_ v: Double) -> String { String(format: "%.0f cd/m²", v) }
  static func zoom(_ v: Double) -> String { v < 10 ? String(format: "%.1f×", v) : String(format: "%.0f×", v) }
  static func number(_ v: Double, digits: Int = 2) -> String {
    var s = String(format: "%.\(digits)f", v)
    while s.contains("."), s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
  }

  /// The ratios the trade names as whole numbers (15:9, not 5:3); the rest read as N:1.
  static let namedAspects: [(Int, Int)] = [
    (9, 16), (4, 5), (1, 1), (4, 3), (13, 9), (14, 9), (15, 9), (16, 9), (17, 9), (2, 1),
  ]

  /// "16:9", "9:16", "2.39:1".
  static func aspect(_ a: Double) -> String {
    for (n, d) in namedAspects where abs(a - Double(n) / Double(d)) < 1e-9 { return "\(n):\(d)" }
    return String(format: "%.2f:1", a)
  }

  static func desqueeze(_ f: Double) -> String { f == 1 ? "Off" : "\(number(f))×" }
}

// MARK: - Titles

extension SignalStage {
  var title: String {
    switch self {
    case .source: return "Source"
    case .output: return "Output"
    case .monitor: return "Monitor"
    }
  }
}

extension ZebraMode {
  var title: String { self == .lowerLimit ? "Lower limit" : "Band" }
}

extension FalseColorMode {
  var title: String {
    switch self {
    case .off: return "Off"
    case .sonySLog3: return SonySLog3FalseColor.displayName
    case .arriStyleSLog3: return SonyARRIStyleFalseColor.displayName
    case .arriLogC: return "ARRI LogC"
    case .elZone: return ELZoneProfile.displayName
    case .sixBand: return SixBandFalseColor.displayName
    case .custom: return "Custom"
    }
  }
}

extension FalseColorUnit {
  var title: String { self == .ire ? "IRE" : "Stops" }
}

extension PeakingStyle {
  var title: String { self == .coloredEdges ? "Colour" : "Peak" }
}

extension PeakingColor {
  var title: String { rawValue.capitalized }
}

extension FrameGuideStyle {
  var title: String {
    switch self {
    case .lines: return "Lines"
    case .matte: return "Matte"
    case .linesAndMatte: return "Lines + matte"
    }
  }
}

extension FlipMode {
  var title: String {
    switch self {
    case .none: return "None"
    case .horizontal: return "Horizontal"
    case .vertical: return "Vertical"
    case .rotate180: return "Rotate 180°"
    }
  }
}

extension MonochromeMode {
  var title: String {
    switch self {
    case .off: return "Off"
    case .luma: return "Mono"
    case .blueOnly: return "Blue only"
    }
  }
}

extension DisplayTransform {
  var title: String {
    switch self {
    case .none: return "None"
    case .logToRec709: return "Log → Rec.709"
    case .hdrToSDR: return "HDR → SDR"
    case .hdrPassthrough: return "HDR passthrough"
    }
  }
}

extension ClipIndicatorColoring {
  var title: String { self == .perChannel ? "Per channel" : "Uniform" }
}

extension LUTRouting {
  var title: String { self == .monitorOnly ? "Monitor only" : "Burn in" }
}

extension LUTInterpolation {
  var title: String {
    switch self {
    case .tetrahedral: return "Tetrahedral"
    case .trilinear: return "Trilinear"
    case .hardware: return "Hardware"
    }
  }
}

extension ColorPrimaries {
  var title: String {
    switch self {
    case .rec709: return "Rec.709"
    case .displayP3: return "Display P3"
    case .rec2020: return "Rec.2020"
    }
  }
}

/// The output encodings a control offers, in menu order.
enum OutputEncodingChoice: String, CaseIterable, Identifiable {
  case signalNative, bt1886, sRGB, gamma22, extendedLinear, pq, hlg
  var id: String { rawValue }

  var encoding: MonitorOutputColor.Encoding {
    switch self {
    case .signalNative: return .signalNative
    case .bt1886: return .sdr(.bt1886)
    case .sRGB: return .sdr(.sRGB)
    case .gamma22: return .sdr(.gamma22)
    case .extendedLinear: return .extendedLinear
    case .pq: return .pq
    case .hlg: return .hlg
    }
  }

  init(_ e: MonitorOutputColor.Encoding) {
    switch e {
    case .signalNative: self = .signalNative
    case .sdr(.bt1886): self = .bt1886
    case .sdr(.sRGB): self = .sRGB
    case .sdr(.gamma22): self = .gamma22
    case .extendedLinear: self = .extendedLinear
    case .pq: self = .pq
    case .hlg: self = .hlg
    }
  }

  var title: String {
    switch self {
    case .signalNative: return "Signal native"
    case .bt1886: return "SDR · BT.1886"
    case .sRGB: return "SDR · sRGB"
    case .gamma22: return "SDR · gamma 2.2"
    case .extendedLinear: return "EDR · extended linear"
    case .pq: return "HDR · PQ"
    case .hlg: return "HDR · HLG"
    }
  }
}
