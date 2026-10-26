import SwiftUI

// Shared visual language for the new interface. System colors and materials
// only, so light, dark and Increase Contrast work, and the system materials
// (sidebar, inspector, bars, popovers) go opaque with Reduce Transparency.
// Overlays on video are dark capsules (black at 72%), not glass or blur, so
// they need no Reduce Transparency fallback.

extension UITone {
  var color: Color {
    switch self {
    case .neutral: return .secondary
    case .positive: return .green
    case .warning: return .orange
    case .critical, .onAir: return .red
    }
  }
}

extension UITally {
  var ringColor: Color? {
    switch self {
    case .none: return nil
    case .onAir: return .red
    case .program: return nil
    case .next: return .green
    }
  }
}

/// The main window's type scale. On macOS `.caption` and `.caption2` are both
/// 10 pt, so they're only used for badges; anything a person reads is 11 pt or
/// larger. Use `.system(size:)` only for symbols inside fixed frames.
extension Font {
  /// Camera name in the strip (expanded and collapsed), popover titles. 13 pt bold.
  static let uiTitle = Font.headline
  /// Strip primary lines: record detail, folder, output, alert rows. 12 pt.
  static let uiRow = Font.callout
  /// Record title and alert titles in the strip. 12 pt semibold.
  static let uiRowEmphasis = Font.callout.weight(.semibold)
  /// Sizes, bitrates, drops, time left, shot timers. 12 pt.
  static let uiValue = Font.callout.monospacedDigit()
  /// Labels, subtitles, footnotes, the dB readout. 11 pt; pair with `.secondary`.
  static let uiMeta = Font.subheadline
  /// Badges and chips; the floor. 10 pt semibold.
  static let uiBadge = Font.caption.weight(.semibold)
  /// Text on the picture, in 24 pt capsules. 11 pt semibold.
  static let uiOverlay = Font.subheadline.weight(.semibold)
  /// The strip's recording clock. 17 pt.
  static let uiClock = Font.title2.weight(.semibold).monospacedDigit()
  /// Title inside a full-size picture placeholder. 15 pt.
  static let uiPlaceholderTitle = Font.title3.weight(.semibold)
}

/// Room around the camera pictures in the main window, in every layout.
enum UIPictureSpacing {
  /// From the sidebar, inspector, toolbar, status bar and window edges.
  static let margin: CGFloat = 20
  /// Between two cameras (side by side, four up, Program's sources).
  static let gutter: CGFloat = 20
  /// How far the selection ring sits outside its picture. It stays well inside the
  /// margin and half the gutter, so it's never clipped and never touches a neighbour.
  static let ringOutset: CGFloat = 4
}

extension View {
  /// Dark backing for text drawn over video, so it stays readable over bright pictures (≥ 4.5:1).
  /// A caller's own `.font` wins; the default is the overlay style.
  func uiPictureOverlay() -> some View {
    uiPictureMenuBacking()
      .foregroundStyle(.white)
      .environment(\.colorScheme, .dark)
  }

  /// The overlay's capsule for a menu on the picture. No dark scheme: a menu
  /// takes its appearance from the scheme around its button, so a forced dark
  /// scheme gave light mode a dark menu. The label colors itself white.
  func uiPictureMenuBacking() -> some View {
    font(.uiOverlay)
      .padding(.horizontal, 8).frame(height: 24)
      .background(Color.black.opacity(0.72), in: Capsule())
  }

  /// Backing for the interactive bars on the picture (monitor tools, view controls):
  /// the same dark capsule as the other picture overlays, so the bar reads the same over
  /// any video. (Glass here drew as a blank white panel in offscreen renders.)
  /// The controls color themselves white; the bar keeps the app's scheme, because
  /// the menus and popovers it opens inherit it and must match light mode.
  func uiPictureControls() -> some View {
    padding(.horizontal, 4).frame(height: 28)
      .background(Color.black.opacity(0.72), in: Capsule())
  }
}

/// A menu's label on the picture: white text and chevron over the dark capsule.
/// The system indicator follows the app's scheme, so it would draw dark here.
struct UIPictureMenuLabel: View {
  let title: String

  var body: some View {
    HStack(spacing: 3) {
      Text(title)
      Image(systemName: "chevron.down").font(.caption2.weight(.bold)).imageScale(.small)
    }
    .foregroundStyle(.white)
    .contentShape(Rectangle())
  }
}

/// A small status badge. Tone sets a colored dot; the words stay in a label
/// color so they read in light mode too (colored text at this size doesn't).
struct UIBadge: View {
  let text: String
  var tone: UITone = .neutral
  var filled = false

  /// The dot is drawn, never typed: VoiceOver would read a "●" aloud.
  private var words: String { text.hasPrefix("● ") ? String(text.dropFirst(2)) : text }

  var body: some View {
    HStack(spacing: 4) {
      if tone != .neutral && !filled {
        Circle().fill(tone.color).frame(width: 6, height: 6)
      }
      Text(words)
    }
    .font(.uiBadge)
    .lineLimit(1)
    .padding(.horizontal, 6).frame(height: 18)
    .foregroundStyle(filled ? AnyShapeStyle(.white) : tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    .background(filled ? AnyShapeStyle(tone.color) : AnyShapeStyle(.fill.tertiary), in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(words)
  }
}

/// The tally badge drawn on a picture: ON AIR (red), PROGRAM (outlined), NEXT (green).
struct UITallyBadge: View {
  let tally: UITally
  var body: some View {
    if let text = tally.badge {
      Text(text)
        .font(.subheadline.weight(.bold))
        .padding(.horizontal, 9).frame(height: 24)
        .foregroundStyle(tally == .next ? Color.black : .white)
        .background(background, in: Capsule())
        .overlay(Capsule().strokeBorder(tally == .program ? Color.white.opacity(0.6) : .clear, lineWidth: 1.5))
        .accessibilityLabel(text.capitalized)
    }
  }
  private var background: Color {
    switch tally {
    case .onAir: return .red
    case .next: return .green
    default: return .black.opacity(0.72)
    }
  }
}

/// The single record control for a take: a round red button that becomes a stop square.
/// Disabled, it turns gray like a system control instead of fading to pink.
struct UIRecordButton: View {
  let active: Bool
  let enabled: Bool
  let help: String
  var size: CGFloat = 28
  let action: () -> Void
  @Environment(\.isEnabled) private var parentEnabled

  var body: some View {
    let on = enabled && parentEnabled
    let mark: Color = on ? .red : Color.secondary.opacity(0.5)
    Button(action: action) {
      ZStack {
        Circle().strokeBorder(on ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.4), lineWidth: 2)
        if active {
          RoundedRectangle(cornerRadius: size * 0.1).fill(mark).frame(width: size * 0.38, height: size * 0.38)
        } else {
          Circle().fill(mark).frame(width: size * 0.66, height: size * 0.66)
        }
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .help(help)
    .accessibilityLabel(active ? "Stop Recording" : "Record")
  }
}

/// An effect toggle chip: the system toggle button, so on/off, disabled,
/// inactive-window and Increase Contrast rendering all come from the system.
/// State is shown with a checkmark, not color alone.
struct UIChipToggle: View {
  let chip: UIChip
  let set: (Bool) -> Void

  var body: some View {
    Toggle(isOn: Binding(get: { chip.isOn }, set: { set($0) })) {
      if chip.isOn { Label(chip.title, systemImage: "checkmark") } else { Text(chip.title) }
    }
    .toggleStyle(.button)
    .buttonBorderShape(.capsule)
    .controlSize(.small)
    .disabled(!chip.enabled)
    .help(chip.help)
    .accessibilityLabel(chip.title)
  }
}

// The level meters live in UIAudioMeterPanel.swift, on MonitorKitUI's LevelMeterView and AudioMeterView.

/// The first of its candidates whose ideal width fits the row, like `ViewThatFits(in: .horizontal)`,
/// for rows that span their container. ViewThatFits measures every candidate at the offered width
/// in every layout pass, so a side column animating beside the row re-measured every candidate at
/// every frame. This measures each candidate once at its ideal width (a proposal that doesn't
/// change with the row's width, so it's laid out from cache) and changes its choice only when the
/// row crosses a candidate's width.
struct UIFirstFitting<Content: View>: View {
  @ViewBuilder let content: Content
  @State private var ideal: [Int: CGFloat] = [:]
  @State private var chosen = 0

  var body: some View {
    Group(subviews: content) { candidates in
      let index = min(chosen, max(0, candidates.count - 1))
      if !candidates.isEmpty {
        candidates[index]
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
              ForEach(candidates.indices, id: \.self) { candidate in
                candidates[candidate].fixedSize().hidden()
                  .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { ideal[candidate] = $0 }
              }
            }
            .frame(width: 0, height: 0, alignment: .topLeading)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
          }
          .onGeometryChange(for: Int.self) { [ideal, count = candidates.count] proxy in
            UIFitting.choice(ideal, count: count, width: proxy.size.width)
          } action: { chosen = $0 }
      }
    }
  }

}

enum UIFitting {
  /// The first candidate that fits `width` (the last when none does, or before any is measured, the first).
  nonisolated static func choice(_ ideal: [Int: CGFloat], count: Int, width: CGFloat) -> Int {
    guard count > 0, ideal.count == count else { return 0 }
    return (0..<count).first { (ideal[$0] ?? .infinity) <= width + 0.5 } ?? count - 1
  }
}
