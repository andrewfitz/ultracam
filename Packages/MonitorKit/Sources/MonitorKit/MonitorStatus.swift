import MonitorKitCore

/// Where a surface draws inside its render target, in target pixels.
public struct MonitorViewport: Equatable, Sendable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int
  /// Target pixels per UI point, 0.25…16: guide strokes and zebra stripes scale with it.
  public var pixelsPerPoint: Double {
    didSet { pixelsPerPoint = Self.clamp(pixelsPerPoint) }
  }

  public init(x: Int = 0, y: Int = 0, width: Int, height: Int, pixelsPerPoint: Double = 1) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.pixelsPerPoint = Self.clamp(pixelsPerPoint)
  }

  static func clamp(_ v: Double) -> Double { v.isFinite ? min(16, max(0.25, v)) : 1 }
}

/// The tools a surface can show.
public enum MonitorTool: String, Sendable, CaseIterable, Codable {
  case falseColor, zebra1, zebra2, focusPeaking, guides, burnInLUT, monitorLUT, magnification,
    desqueeze, flip, displayAdjustments
}

/// Why a tool that is switched on is not drawn. The picture is always drawn.
public enum MonitorUnavailableReason: Equatable, Sendable, CustomStringConvertible {
  /// The surface is in clean mode.
  case cleanFeed
  /// The mode classifies a log signal, and the frame is not labelled as one.
  case requiresLogSource
  /// The frame is log, but not an encoding this mode classifies.
  case unsupportedLogEncoding(LogEncoding)
  /// Custom false colour has no bands.
  case noBands
  /// The mode measures light (stops), and the signal's transfer is unknown.
  case requiresKnownTransfer
  /// Peaking is on, but the feed has no focus mask for this frame on this
  /// surface's stage: call `analyze` with the same `FocusSettings.stage` first.
  case focusNotAnalyzed
  /// Guides are hidden while the picture is magnified.
  case hiddenWhileMagnified

  public var description: String {
    switch self {
    case .cleanFeed: return "Clean feed is on."
    case .requiresLogSource: return "Needs a log source; this signal is not labelled as log."
    case .unsupportedLogEncoding(let e):
      return "Not available for \(e.curve.rawValue) / \(e.gamut.rawValue)."
    case .noBands: return "No custom bands are defined."
    case .requiresKnownTransfer: return "Needs a known transfer function; this signal is unlabelled."
    case .focusNotAnalyzed: return "No focus analysis for this frame and signal stage."
    case .hiddenWhileMagnified: return "Hidden while magnified."
    }
  }
}

/// What a surface is showing and why anything switched on is not. Rebuilt only
/// when the state, signal or feed changes, never per frame.
public struct MonitorStatus: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public var tool: MonitorTool
    public var label: String
    /// The mode's reference is not verified against the device it follows.
    public var isProvisional: Bool
  }
  public struct Unavailable: Equatable, Sendable {
    public var tool: MonitorTool
    public var reason: MonitorUnavailableReason
  }

  public internal(set) var active: [Entry] = []
  public internal(set) var unavailable: [Unavailable] = []

  public init() {}

  public var activeLabels: [String] { active.map(\.label) }
  public func isActive(_ tool: MonitorTool) -> Bool { active.contains { $0.tool == tool } }
  public func reason(for tool: MonitorTool) -> MonitorUnavailableReason? {
    unavailable.first { $0.tool == tool }?.reason
  }
}
