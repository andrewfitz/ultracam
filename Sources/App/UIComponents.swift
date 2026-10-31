import SwiftUI

// The reusable pieces of the visual language (07 section 3): each draws one kind of fact the
// same way on every surface. State is symbol plus color, never color alone, and words stay
// in a label color. All of them are values with no state of their own, so a row can hold
// several without adding to a live view's body.

/// One small glyph for a state. A warning is never just an orange dot.
enum UIState: Sendable, Equatable { case recording, paused, warning, healthy, starting, inactive }

struct UIStateGlyph: View {
  let state: UIState
  var size: CGFloat = 8

  var body: some View {
    switch state {
    case .recording: Circle().fill(.red).frame(width: size, height: size).accessibilityHidden(true)
    case .healthy: Circle().fill(.green).frame(width: size, height: size).accessibilityHidden(true)
    case .inactive:
      Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: size, height: size).accessibilityHidden(true)
    case .paused:
      Image(systemName: UISymbol.paused).imageScale(.small).foregroundStyle(.orange).accessibilityHidden(true)
    case .warning:
      Image(systemName: UISymbol.warning).imageScale(.small).foregroundStyle(.orange).accessibilityHidden(true)
    case .starting: ProgressView().controlSize(.mini).accessibilityHidden(true)
    }
  }
}

/// A number and its unit, as drawn: "1 h 52 m" is 1 and 52 strong, h and m small and dim.
struct UIValuePart: Sendable, Equatable {
  var number: String
  var unit: String = ""
}

/// Value plus unit on one baseline, with one accessibility label.
struct UIValue: View {
  let parts: [UIValuePart]
  var strong = true

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      ForEach(parts.indices, id: \.self) { index in
        Text(parts[index].number).font(strong ? .uiValueStrong : .uiValue)
        if !parts[index].unit.isEmpty {
          Text(parts[index].unit).font(.uiMeta).foregroundStyle(.secondary)
            .padding(.trailing, index < parts.count - 1 ? 2 : 0)
        }
      }
    }
    .lineLimit(1)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(parts.map { "\($0.number) \($0.unit)" }.joined(separator: " "))
  }
}

/// A symbol, then a value. The value keeps its width and the label truncates first. The help
/// and the label are required: a glyph by itself says nothing to VoiceOver.
struct UIIconValue: View {
  let symbol: String
  var tint: Color = .secondary
  var label: String? = nil
  var parts: [UIValuePart] = []
  let help: String
  let accessibilityLabel: String

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).imageScale(.small).foregroundStyle(tint)
      if let label { Text(label).lineLimit(1).truncationMode(.tail) }
      if !parts.isEmpty { UIValue(parts: parts).layoutPriority(1) }
    }
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }
}

/// A symbol and a count, shown only above zero.
struct UICountChip: View {
  let symbol: String
  let count: Int
  let help: String

  var body: some View {
    if count > 0 {
      HStack(spacing: 3) {
        Image(systemName: symbol).imageScale(.small).foregroundStyle(.orange)
        Text("\(count)").monospacedDigit()
      }
      .font(.uiBadge)
      .help(help)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(help)
    }
  }
}

/// A 4 pt capsule beside a number: gray fill, orange when low, yellow past a soft limit.
/// `width` nil is full width.
struct UILevelBar: View {
  var fraction: Double
  var tint: Color = .secondary
  var width: CGFloat? = 28

  var body: some View {
    Capsule().fill(.fill.tertiary)
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, fraction)))
        }
      }
      .clipShape(Capsule())
      .frame(width: width, height: 4)
      .frame(maxWidth: width == nil ? .infinity : nil)
      .accessibilityHidden(true)
  }
}

/// The battery as its camera body reports it. A percentage and minutes are different facts:
/// a low-battery warning must never read 78 minutes as 78 percent.
enum UIBattery: Sendable, Equatable {
  case percent(Int)
  case minutes(Int)
  /// A value in a unit nobody can name: shown as it came, with no warning.
  case unknown(String)
}

struct UIBatteryGlyph: View {
  let battery: UIBattery
  /// Under this percentage it turns orange.
  static let warningPercent = 20

  private var symbol: String {
    switch battery {
    case .percent(let percent): return UISymbol.battery(percent: percent)
    case .minutes, .unknown: return UISymbol.batteryMinutes
    }
  }

  private var low: Bool {
    if case .percent(let percent) = battery { return percent < Self.warningPercent }
    return false
  }

  private var text: String {
    switch battery {
    case .percent(let percent): return "\(percent)%"
    case .minutes(let minutes): return "\(minutes) min"
    case .unknown(let value): return value
    }
  }

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).imageScale(.small).foregroundStyle(low ? Color.orange : .secondary)
      Text(text).monospacedDigit()
    }
    .help("Camera battery: \(text)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Battery \(text)")
  }
}

/// A camera's number: the same digit the toolbar's cut button and ⌃n use.
struct UINumberCapsule: View {
  let number: Int
  /// On a picture: the 24 pt dark capsule. Otherwise the small chip of sidebar rows.
  var onPicture = false

  var body: some View {
    Text("\(number)")
      .font(onPicture ? .uiTitle.monospacedDigit() : .uiBadge.monospacedDigit())
      .padding(.horizontal, onPicture ? 6 : 0)
      .frame(minWidth: onPicture ? 24 : 16, minHeight: onPicture ? 24 : 16)
      .foregroundStyle(onPicture ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .background(onPicture ? AnyShapeStyle(Color.black.opacity(0.72)) : AnyShapeStyle(.fill.tertiary),
        in: RoundedRectangle(cornerRadius: onPicture ? 12 : 5))
      .accessibilityHidden(true)
  }
}

/// The REC pill and its states, in one view: never truncates. `elapsed` only when the strip
/// doesn't already show the clock (one clock per camera).
struct UIPictureStatePill: View {
  enum Style: Sendable, Equatable { case recording, paused, noSignal }
  let style: Style
  var count = 1
  var elapsed: String? = nil
  /// The menu bar card's smaller scale.
  var compact = false

  var body: some View {
    HStack(spacing: 4) {
      switch style {
      case .recording: UIStateGlyph(state: .recording, size: compact ? 7 : 8)
      case .noSignal: UIStateGlyph(state: .warning)
      case .paused: UIStateGlyph(state: .paused)
      }
      Text(words).monospacedDigit()
    }
    .font(compact ? .uiCompactOverlay : .uiOverlay)
    .fixedSize()
    .uiPictureOverlay()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
  }

  private var words: String {
    let name = style == .paused ? "Paused" : "REC"
    return [name, count > 1 ? "\(count)" : nil, elapsed].compactMap { $0 }.joined(separator: " ")
  }

  private var label: String {
    let clock = elapsed.map { " \($0)" } ?? ""
    switch style {
    case .recording: return "Recording\(clock)"
    case .paused: return "Recording paused\(clock)"
    case .noSignal: return "Recording\(clock), no signal"
    }
  }
}
