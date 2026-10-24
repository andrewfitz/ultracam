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

enum UIAudioMath {
  static func normalized(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
  static func decibels(_ linear: Double) -> String {
    let level = normalized(linear)
    guard level > 0.000001 else { return "−∞ dB" }
    return String(format: "%.1f dB", max(-60, 20 * log10(level)))
  }
}

/// Peak/RMS bar for one channel: the filled bar is RMS, the marker is peak.
struct UILevelBar: View {
  let rms: Double
  let peak: Double
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.fill.tertiary)
        // Nothing but the track at silence: a level or peak mark at zero reads as a glitch.
        if rms > 0 {
          Capsule().fill(LinearGradient(colors: [.green, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(2, width * UIAudioMath.normalized(rms)))
        }
        if peak > 0 {
          Capsule().fill(Color.primary).frame(width: 2).offset(x: max(0, width * UIAudioMath.normalized(peak) - 1))
        }
      }
      .clipShape(Capsule())
    }
    .accessibilityHidden(true)
  }
}

/// Two-channel meter with a dB readout of the louder peak.
struct UIAudioMeter: View {
  let audio: UIAudioLevels
  var compact = false
  var body: some View {
    if compact {
      Group {
        if audio.present {
          VStack(spacing: 2) {
            UILevelBar(rms: audio.rmsLeft, peak: audio.peakLeft).frame(height: 3)
            UILevelBar(rms: audio.rmsRight, peak: audio.peakRight).frame(height: 3)
          }
        } else {
          Image(systemName: "speaker.slash").imageScale(.small).foregroundStyle(.tertiary)
            .help("No embedded audio")
        }
      }
      .frame(width: 42)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Audio level")
      .accessibilityValue(audio.present ? UIAudioMath.decibels(max(audio.peakLeft, audio.peakRight)) : "No embedded audio")
    } else {
      HStack(spacing: 8) {
        Text("L").font(.uiBadge).foregroundStyle(.secondary)
        UILevelBar(rms: audio.rmsLeft, peak: audio.peakLeft).frame(height: 6)
        Text("R").font(.uiBadge).foregroundStyle(.secondary)
        UILevelBar(rms: audio.rmsRight, peak: audio.peakRight).frame(height: 6)
        Text(audio.present ? UIAudioMath.decibels(max(audio.peakLeft, audio.peakRight)) : "No audio")
          .font(.uiMeta.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Embedded audio")
      .accessibilityValue(audio.present
        ? "Left peak \(UIAudioMath.decibels(audio.peakLeft)), right peak \(UIAudioMath.decibels(audio.peakRight))"
        : "No embedded audio")
    }
  }
}
