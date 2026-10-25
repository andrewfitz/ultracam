import MonitorKit
import MonitorKitCore
import MonitorKitUI
import SwiftUI

// Shared pieces of the monitor tool popovers: bindings that keep Ultracam's
// master-switch rules, the slider row, captions, and the surface's reasons.

/// Bindings into one camera's monitor preferences.
@MainActor enum UIMonitorToolBindings {
  /// A tool's switch. Turning a tool on while the camera's tools are hidden
  /// starts from every tool off (`hideAllTools`), so tools left on underneath
  /// the master switch stay off; the switch then follows the tools.
  static func enabling(_ preferences: Binding<MonitorFeedPreferences>,
    _ keyPath: WritableKeyPath<MonitorFeedPreferences, Bool>) -> Binding<Bool> {
    Binding(
      get: { preferences.wrappedValue.toolsEnabled && preferences.wrappedValue[keyPath: keyPath] },
      set: { on in
        var next = preferences.wrappedValue
        if on && !next.toolsEnabled { next.hideAllTools() }
        next[keyPath: keyPath] = on
        next.toolsEnabled = next.anyToolOn
        preferences.wrappedValue = next
      })
  }

  /// The false-color mode, shown as Off while the camera's tools are hidden.
  static func falseColorMode(_ preferences: Binding<MonitorFeedPreferences>) -> Binding<FalseColorMode> {
    Binding(
      get: { preferences.wrappedValue.toolsEnabled ? preferences.wrappedValue.state.falseColor.mode : .off },
      set: { mode in
        var next = preferences.wrappedValue
        if mode != .off && !next.toolsEnabled { next.hideAllTools() }
        next.state.falseColor.mode = mode
        next.toolsEnabled = next.anyToolOn
        preferences.wrappedValue = next
      })
  }

  /// Zebra set `index`, safe on a state with fewer sets: reads the default set,
  /// and a write pads the list first.
  static func zebra(_ preferences: Binding<MonitorFeedPreferences>, _ index: Int) -> Binding<ZebraSet> {
    Binding(
      get: {
        let zebras = preferences.wrappedValue.state.zebras
        return index < zebras.count ? zebras[index] : MonitorFeedPreferences.defaultState.zebras[index]
      },
      set: { zebra in
        var next = preferences.wrappedValue
        padZebras(&next, through: index)
        next.state.zebras[index] = zebra
        preferences.wrappedValue = next
      })
  }

  /// Zebra set `index`'s switch, with the master-switch rules of `enabling`.
  static func zebraEnabled(_ preferences: Binding<MonitorFeedPreferences>, _ index: Int) -> Binding<Bool> {
    Binding(
      get: { preferences.wrappedValue.toolsEnabled && zebra(preferences, index).wrappedValue.enabled },
      set: { on in
        var next = preferences.wrappedValue
        if on && !next.toolsEnabled { next.hideAllTools() }
        padZebras(&next, through: index)
        next.state.zebras[index].enabled = on
        next.toolsEnabled = next.anyToolOn
        preferences.wrappedValue = next
      })
  }

  private static func padZebras(_ preferences: inout MonitorFeedPreferences, through index: Int) {
    while preferences.state.zebras.count <= index {
      preferences.state.zebras.append(MonitorFeedPreferences.defaultState.zebras[preferences.state.zebras.count])
    }
  }

  /// The picture stage. Zebra 1 measures the picture shown (`setPictureStage`).
  static func pictureStage(_ preferences: Binding<MonitorFeedPreferences>) -> Binding<SignalStage> {
    Binding(
      get: { preferences.wrappedValue.state.pictureStage },
      set: { stage in
        var next = preferences.wrappedValue
        next.setPictureStage(stage)
        preferences.wrappedValue = next
      })
  }
}

/// Ultracam's names for MonitorKit's settings (American spelling, as the app).
enum UIMonitorToolText {
  static func stage(_ stage: SignalStage) -> String {
    switch stage {
    case .source: return "Source"
    case .output: return "Output (LUT)"
    case .monitor: return "Monitor"
    }
  }

  static func falseColor(_ mode: FalseColorMode) -> String {
    switch mode {
    case .off: return "Off"
    case .sonySLog3: return "Sony S-Log3"
    case .arriStyleSLog3: return "ARRI-style (S-Log3)"
    case .arriLogC: return "ARRI LogC"
    case .sixBand: return "Six band (display IRE)"
    case .custom: return "Custom bands"
    }
  }

  static func flip(_ mode: FlipMode) -> String {
    switch mode {
    case .none: return "None"
    case .horizontal: return "Horizontal"
    case .vertical: return "Vertical"
    case .rotate180: return "Rotate 180°"
    }
  }

  static func displayTransform(_ mode: DisplayTransform) -> String {
    switch mode {
    case .none: return "None"
    case .logToRec709: return "Log to Rec.709"
    case .hdrToSDR: return "HDR to SDR"
    case .hdrPassthrough: return "HDR passthrough"
    }
  }

  static func monochrome(_ mode: MonochromeMode) -> String {
    switch mode {
    case .off: return "Color"
    case .luma: return "Mono"
    case .blueOnly: return "Blue only"
    }
  }

  static func frameGuideStyle(_ style: FrameGuideStyle) -> String {
    switch style {
    case .lines: return "Lines"
    case .matte: return "Matte"
    case .linesAndMatte: return "Both"
    }
  }

  /// "16:9", "2.39:1".
  static func aspect(_ value: Double) -> String {
    let named: [(Int, Int)] = [(9, 16), (4, 5), (1, 1), (4, 3), (13, 9), (14, 9), (15, 9), (16, 9), (17, 9), (2, 1)]
    for (n, d) in named where abs(value - Double(n) / Double(d)) < 1e-9 { return "\(n):\(d)" }
    return String(format: "%.2f:1", value)
  }

  /// "Off", "1.33×", "2×".
  static func desqueeze(_ factor: Double) -> String {
    guard factor != 1 else { return "Off" }
    var text = String(format: "%.2f", factor)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text + "×"
  }

  /// "90%", "92.5%".
  static func percent(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
  }
}

/// A labelled slider with its value beside it, read out as one element.
struct UIMonitorSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double?
  let format: (Double) -> String

  init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
    format: @escaping (Double) -> String) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
    self.format = format
  }

  /// Percent of 0…1.
  init(_ title: String, percent value: Binding<Double>, in range: ClosedRange<Double> = 0...1) {
    self.init(title, value: value, in: range, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
  }

  var body: some View {
    LabeledContent {
      HStack {
        Group {
          if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
        }
        .frame(minWidth: 100)
        Text(format(value))
          .font(.uiMeta.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
      }
    } label: { Text(title) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(format(value))
    .accessibilityAdjustableAction { direction in
      let delta = step ?? (range.upperBound - range.lowerBound) / 20
      switch direction {
      case .increment: value = min(range.upperBound, value + delta)
      case .decrement: value = max(range.lowerBound, value - delta)
      @unknown default: break
      }
    }
  }
}

/// A secondary caption under a group of controls.
struct UIMonitorToolCaption: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}

/// Why a tool that is on isn't drawn on this camera's picture, from MonitorKit's
/// status for the picture on screen. Nothing when the camera has no picture
/// open (fixtures, Program) or every tool draws.
struct UIMonitorStatusNote: View {
  let cameraID: String
  let tools: [MonitorTool]
  /// Also explain a code-value view (a log picture nothing maps for viewing).
  var explainsCodeValues = false

  var body: some View {
    if let presenter = UIMonitorBridge.presenter(for: cameraID) {
      Observed(presenter: presenter, tools: tools, explainsCodeValues: explainsCodeValues)
    }
  }

  /// The reasons for `tools` in `status`, once each.
  static func reasons(_ status: MonitorStatus, tools: [MonitorTool]) -> [String] {
    var seen: [String] = []
    for tool in tools {
      if let reason = status.reason(for: tool), !seen.contains(reason.description) { seen.append(reason.description) }
    }
    return seen
  }

  private struct Observed: View {
    @ObservedObject var presenter: MonitorSurfacePresenter
    let tools: [MonitorTool]
    let explainsCodeValues: Bool
    var body: some View {
      if explainsCodeValues && presenter.shownStatus.isCodeValueView {
        UIMonitorToolCaption(MonitorStatus.codeValueViewNote)
      }
      ForEach(UIMonitorStatusNote.reasons(presenter.shownStatus, tools: tools), id: \.self) { reason in
        Label(reason, systemImage: "exclamationmark.triangle")
          .font(.uiMeta).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Unavailable: \(reason)")
      }
    }
  }
}
