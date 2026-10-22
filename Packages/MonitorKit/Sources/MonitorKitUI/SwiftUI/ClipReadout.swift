import MonitorKitScopes
import SwiftUI

/// Clip % readouts: the share of pixels at or above the scope's
/// `clipHighPercent` and at or below its `clipLowPercent`, per R, G, B and luma,
/// read ten times a second from a scope overlay's `statisticsReader` (no GPU
/// readback on the frame path, no frame copy).
///
/// The numbers come from a scope accumulation of that source and stage: show a
/// scope, or add a hidden overlay (`MonitorScopeOverlay(isHidden: true)`, a
/// histogram is the cheapest) with the clip levels of the picture's
/// `ClipIndicatorSettings`, which is measured without being drawn.
public struct ClipReadout: View {
  let overlay: MonitorScopeOverlay
  /// Polling period in seconds.
  static let period = 0.1

  public init(overlay: MonitorScopeOverlay) { self.overlay = overlay }

  public var body: some View {
    TimelineView(.periodic(from: .now, by: Self.period)) { _ in
      let lines = Self.lines(overlay.statisticsReader?.statistics)
      VStack(alignment: .leading, spacing: 1) {
        Text(lines.high)
        Text(lines.low)
      }
      .font(.system(.caption2, design: .monospaced))
      .monospacedDigit()
      .lineLimit(1)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Clipping")
      .accessibilityValue("\(lines.high), \(lines.low)")
    }
  }

  /// The two readout lines, "Over R 0.0% G 0.0% B 1.2% Y 0.3%" and "Under …",
  /// with dashes before the first accumulation lands.
  static func lines(_ s: ScopeStatistics?) -> (high: String, low: String) {
    guard let s, s.pixelCount > 0 else { return ("Over –", "Under –") }
    return ("Over " + channels(s.clippedHigh), "Under " + channels(s.clippedLow))
  }

  static func channels(_ v: SIMD4<Double>) -> String {
    "R \(percent(v.x)) G \(percent(v.y)) B \(percent(v.z)) Y \(percent(v.w))"
  }

  /// One decimal; a share too small to show as 0.1% but not zero reads "<0.1%",
  /// so a few clipped pixels are never shown as none.
  static func percent(_ fraction: Double) -> String {
    let p = min(max(fraction, 0), 1) * 100
    if p > 0 && p < 0.05 { return "<0.1%" }
    return String(format: "%.1f%%", p)
  }
}
