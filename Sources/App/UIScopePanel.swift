import MonitorKit
import MonitorKitScopes
import SwiftUI

/// The graticule's labels over a scope image: level ticks, parade channel names
/// and vectorscope targets, from `UIScopeDescription.visibleLabels`, which uses
/// the same `ScopeGraticule` MonitorKit draws the lines from. White on purpose:
/// a scope's background is black in either appearance. Draws nothing per frame.
struct UIScopeLabelsView: View {
  let description: UIScopeDescription

  var body: some View {
    Canvas { context, size in
      let labels = description.visibleLabels(width: size.width, height: size.height)
      for label in labels {
        let text = Text(label.text)
          .font(.system(size: label.role == .channel ? 9 : 8, weight: label.role == .channel ? .semibold : .regular,
            design: .monospaced))
          .foregroundStyle(Color.white.opacity(label.isMajor ? 0.85 : 0.6))
        let (point, anchor) = Self.placement(label, in: size)
        context.draw(text, at: point, anchor: anchor)
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  /// Where a label is drawn: its anchor point, kept inside the image so the end
  /// labels (and targets just outside the plot) are not cut off.
  static func placement(_ label: ScopeLabel, in size: CGSize) -> (CGPoint, UnitPoint) {
    let x = label.position.x * size.width
    let y = label.position.y * size.height
    func inside(_ v: Double, _ limit: Double, margin: Double) -> Double {
      min(max(margin, limit - margin), max(margin, v))
    }
    switch label.anchor {
    case .leading: return (CGPoint(x: x + 2, y: inside(y, size.height, margin: 5)), .leading)
    case .top: return (CGPoint(x: inside(x, size.width, margin: 8), y: y + 2), .top)
    case .bottom: return (CGPoint(x: inside(x, size.width, margin: 8), y: y - 1), .bottom)
    case .center: return (CGPoint(x: inside(x, size.width, margin: 8), y: inside(y, size.height, margin: 6)), .center)
    }
  }

  private var accessibilityLabel: String {
    let ticks = description.labels.filter { $0.role == .tick && $0.isMajor }.map(\.text)
    let scale = description.hasLevelAxis
      ? UIScopeDescription.scaleTitle(description.settings.display.waveformScale) : "Cb/Cr"
    return ticks.isEmpty ? "Scope scale \(scale)" : "Scope scale \(scale): \(ticks.joined(separator: ", "))"
  }
}

/// A scope image with its labels. The image is 768 × 256 and stretched to the
/// view, so a waveform or histogram fills the width; a vectorscope keeps the
/// image's 3:1 shape, so its round plot in the middle stays round.
struct UIScopeImage<Scope: View>: View {
  let description: UIScopeDescription
  var showsLabels = true
  @ViewBuilder var scope: () -> Scope

  var body: some View {
    let image = scope()
      .overlay { if showsLabels { UIScopeLabelsView(description: description) } }
    if description.settings.kind == .vectorscope {
      image.aspectRatio(UIScopeDescription.imageAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
    } else {
      image
    }
  }
}

/// The clip readout under a scope, from its accumulator's statistics: read four
/// times a second from the shared statistics buffer the GPU writes, never a GPU
/// readback on the frame path. Dashes until the first measurement, or when the
/// surface offers no statistics.
struct UIScopeClipReadoutView: View {
  let reader: ScopeStatisticsReader?
  let settings: ScopeSettings
  /// While false (a frozen or hidden scope) the last numbers stay without polling.
  var isLive = true
  /// Shown when there is no reader: numbers measured earlier.
  var held: UIScopeReadout?
  static let period = 0.25

  var body: some View {
    if let reader, isLive {
      TimelineView(.periodic(from: .now, by: Self.period)) { _ in
        lines(UIScopeReadout(reader.statistics))
      }
    } else if let reader {
      lines(UIScopeReadout(reader.statistics))
    } else {
      lines(held)
    }
  }

  private func lines(_ readout: UIScopeReadout?) -> some View {
    let text = UIScopeReadout.lines(readout, settings: settings)
    return VStack(alignment: .leading, spacing: 1) {
      Text(text.high)
      Text(text.low)
      Text(text.luma)
    }
    .font(.system(.caption2, design: .monospaced))
    .monospacedDigit()
    .lineLimit(1)
    .minimumScaleFactor(0.8)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Clipping")
    .accessibilityValue("\(text.high), \(text.low), \(text.luma)")
  }
}

/// The scopes pane of a monitor tile: title (scope · stage), Dock/Expand, the
/// scope with its labels, the clip readout (with a statistics reader or held
/// numbers), timing, interpretation and footnote.
struct UIScopePanel<Scope: View>: View {
  let description: UIScopeDescription
  @Binding var expanded: Bool
  var statistics: ScopeStatisticsReader?
  var isLive = true
  /// The readout without a statistics reader.
  var heldReadout: UIScopeReadout?
  var timing = ""
  var interpretation = ""
  var dockedHeight = 120.0
  var expandedHeight = 240.0
  @ViewBuilder var scope: () -> Scope

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(description.title).font(.caption)
        Spacer()
        Button(expanded ? "Dock" : "Expand") { expanded.toggle() }.font(.caption)
          .help(expanded ? "Make the scope smaller" : "Make the scope larger")
      }
      UIScopeImage(description: description, scope: scope)
        .frame(height: expanded ? expandedHeight : dockedHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(description.title)
      // Only where there are numbers to show: a surface without a statistics
      // reader would show three lines of dashes that never fill in.
      if statistics != nil || heldReadout != nil {
        UIScopeClipReadoutView(reader: statistics, settings: description.settings, isLive: isLive, held: heldReadout)
      }
      if !timing.isEmpty { Text(timing).font(.caption2).foregroundStyle(.secondary) }
      if !interpretation.isEmpty { Text(interpretation).font(.caption2).foregroundStyle(.secondary) }
      Text(description.caption).font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let note = description.scaleNote {
        Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
