import MonitorKitScopes
import SwiftUI

/// IRE scale marks for a waveform drawn on the scopes' level axis: the levels a
/// monitor prints beside its trace (−10, 0, 50, 100, 110 by default), placed
/// where the scope draws them. Built when the size or settings change, never
/// per frame.
///
/// IRE here is percent of the nominal range (0 black, 100 white), the scopes'
/// `WaveformScale.percent` unit, so level = IRE / 100. A level outside the axis
/// is left out rather than pinned to an edge, which would mislabel the trace
/// there: MonitorKit's waveform axis (`ScopeLevelAxis`, −7…109) keeps 0, 50 and
/// 100 of the defaults; a host drawing a −10…110 scope (`legacyAxis`) gets all five.
public struct ScopeIREScale: Equatable, Sendable {
  public struct Mark: Equatable, Sendable, Identifiable {
    /// The level's index in the levels given.
    public var id: Int
    public var ire: Double
    /// As printed: "-10", "0", "50", "100", "110".
    public var label: String
    /// Height fraction from the top of the scope (0 top, 1 bottom), as SwiftUI lays out.
    public var y: Double
    /// 0, 50 and 100 IRE.
    public var isMajor: Bool
  }

  /// The levels a monitor prints beside its waveform.
  public static let standardLevels: [Double] = [-10, 0, 50, 100, 110]
  /// MonitorKit's waveform and histogram level axis, in normalized level.
  public static let monitorKitAxis: ClosedRange<Double> = ScopeLevelAxis.low...ScopeLevelAxis.high
  /// A −10…110 IRE axis (Ultracam's MonitorTools scope image).
  public static let legacyAxis: ClosedRange<Double> = -0.1...1.1

  /// The axis, in normalized level (IRE / 100), bottom to top.
  public var axis: ClosedRange<Double>
  /// The levels on the axis, in the order given.
  public var marks: [Mark]

  /// `bins`: the waveform's level bins (`ScopeSettings` height). Given, each
  /// mark sits at the centre of the bin its level is counted in, as the scope's
  /// own graticule does (`ScopeLevelAxis.drawnFraction(ofLevel:bins:)`), so a
  /// legal-white trace sits on the 100 line at any bin count.
  public init(levels: [Double] = standardLevels, axis: ClosedRange<Double> = monitorKitAxis, bins: Int? = nil) {
    self.axis = axis
    var marks: [Mark] = []
    var i = 0
    while i < levels.count {
      let ire = levels[i]
      let level = ire / 100
      // A hair of slack so −7 on the −0.07 axis (-7 / 100 vs the literal) stays in.
      if ire.isFinite, level >= axis.lowerBound - 1e-9, level <= axis.upperBound + 1e-9 {
        marks.append(
          Mark(
            id: i, ire: ire, label: Self.label(ire), y: 1 - Self.fraction(ofLevel: level, axis: axis, bins: bins),
            isMajor: ire == 0 || ire == 50 || ire == 100))
      }
      i += 1
    }
    self.marks = marks
  }

  /// Where `level` is drawn, 0 at the bottom of the axis and 1 at the top. With
  /// `bins`, the centre of the bin the kernels count `level` in (the scopes'
  /// Float arithmetic, `mk_levelBin`), clamped to the end bins as the trace is.
  public static func fraction(ofLevel level: Double, axis: ClosedRange<Double>, bins: Int? = nil) -> Double {
    let span = axis.upperBound - axis.lowerBound
    guard span > 0 else { return 0 }
    guard let bins else { return (level - axis.lowerBound) / span }
    let n = max(1, bins)
    let scale = Float(Double(n) / span)
    let bin = min(max(((Float(level) - Float(axis.lowerBound)) * scale).rounded(.down), 0), Float(n - 1))
    return (Double(bin) + 0.5) / Double(n)
  }

  /// "-10", "0", "100"; a fractional level keeps one decimal.
  static func label(_ ire: Double) -> String {
    ire == ire.rounded() && abs(ire) < 1e6 ? String(Int(ire)) : String(format: "%.1f", ire)
  }

  /// "−10…110": the axis bounds in IRE.
  public var rangeText: String {
    func f(_ level: Double) -> String {
      let ire = (level * 1000).rounded() / 10
      let text = ire == ire.rounded() ? String(Int(abs(ire))) : String(format: "%.1f", abs(ire))
      return ire < 0 ? "−" + text : text
    }
    return f(axis.lowerBound) + "…" + f(axis.upperBound)
  }

  /// The line a monitor prints under its waveform: "Sampled signal · −7…109
  /// IRE · endpoints clamp outside scale" (levels beyond the axis count in its end bins).
  public var caption: String { "Sampled signal · \(rangeText) IRE · endpoints clamp outside scale" }

  /// "Scope scale minus 10 to 110 IRE".
  public var accessibilityLabel: String {
    let words = rangeText.replacingOccurrences(of: "−", with: "minus ").replacingOccurrences(of: "…", with: " to ")
    return "Scope scale \(words) IRE"
  }
}

/// The IRE scale drawn over a scope: a dashed line per mark and its level at
/// the leading edge, in the monitor look (8 pt monospaced). White on purpose:
/// a scope's background is black in either appearance. Draws nothing per
/// frame; place it over the scope's surface with the same frame.
public struct ScopeIREScaleView: View {
  let scale: ScopeIREScale
  let showsGrid: Bool

  public init(scale: ScopeIREScale = ScopeIREScale(), showsGrid: Bool = true) {
    self.scale = scale
    self.showsGrid = showsGrid
  }

  /// The label column's width; grid lines start after it.
  nonisolated static let labelInset = 25.0

  /// A label's centre: in the label column, kept 5 pt inside the top and bottom
  /// edges so the end labels are not cut off.
  nonisolated static func labelPosition(_ mark: ScopeIREScale.Mark, in size: CGSize) -> CGPoint {
    let y = size.height * mark.y
    return CGPoint(x: 12, y: min(max(5, size.height - 5), max(5, y)))
  }

  public var body: some View {
    Canvas { context, size in
      let marks = scale.marks
      var i = 0
      while i < marks.count {
        let mark = marks[i]
        let y = size.height * mark.y
        if showsGrid {
          var line = Path()
          line.move(to: CGPoint(x: Self.labelInset, y: y))
          line.addLine(to: CGPoint(x: size.width, y: y))
          context.stroke(
            line, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
        let text = Text(mark.label)
          .font(.system(size: 8, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.8))
        context.draw(text, at: Self.labelPosition(mark, in: size), anchor: .center)
        i += 1
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(scale.accessibilityLabel)
  }
}
