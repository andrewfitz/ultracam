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
    desqueeze, flip, displayAdjustments, displayTransform, clipIndicators
  /// The picture itself, in one list at most: unavailable
  /// (`unsupportedGeometry`) when its pixel aspect ratio is unusable and it is shown
  /// with square pixels; otherwise active when there is something to say (a
  /// picture stage other than the default monitor stage, a code-value view).
  /// `MonitorStatus.pictureStage` and `isCodeValueView` hold either way.
  case picture
}

/// Why a tool that is switched on is not drawn, or (`unsupportedGeometry`, on
/// `.picture`) not drawn as declared. The picture itself is always drawn.
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
  /// The display transform maps PQ or HLG, and the signal is neither.
  case requiresHDRSource
  /// HDR passthrough needs an HDR output encoding (extended linear, PQ, HLG or
  /// signal-native on an HDR signal).
  case requiresHDROutput
  /// A display transform needs the camera's signal, and a LUT produces the
  /// monitor stage: LUT output is Rec.709 display R'G'B' (the burn-in or monitor LUT
  /// already maps the picture for display).
  case lutOnMonitorStage
  /// The tool classifies or measures the camera's own signal (log false colour,
  /// focus peaking), and the frame is a processed picture
  /// (`MonitorFrame.isProcessed`: a programme mix, a scaled or graded render).
  case requiresCameraSignal
  /// The frame's geometry cannot be shown as declared: its pixel aspect ratio is
  /// not finite or outside `MonitorFrameGeometry.pixelAspectRatioRange`. The
  /// picture is shown with square pixels.
  case unsupportedGeometry

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
    case .requiresHDRSource: return "Needs a PQ or HLG signal."
    case .requiresHDROutput: return "Needs an HDR output."
    case .lutOnMonitorStage: return "Not available while a LUT is applied; the LUT output is Rec.709."
    case .requiresCameraSignal: return "Needs a camera's own signal; this picture is processed."
    case .unsupportedGeometry: return "Unsupported picture geometry; shown with square pixels."
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

  /// What is drawn, with its label. `.burnInLUT` and `.monitorLUT` are listed only
  /// when something this surface draws passes through that LUT, their labels ending
  /// " · tools only" when the picture's own stage does not (a source picture
  /// whose zebras measure the output, an output picture with monitor-stage false colour).
  public internal(set) var active: [Entry] = []
  public internal(set) var unavailable: [Unavailable] = []
  /// The stage the picture shows (`MonitorState.pictureStage`).
  public internal(set) var pictureStage: SignalStage = .monitor
  /// The picture shows a signal's code values as they are: a declared log source
  /// (or an unlabelled one) on a picture stage no LUT touched, with no display
  /// transform and no false colour replacing it. Nothing maps it for viewing, and its brightness is not an exposure
  /// reading. The `.picture` entry's label says so; `codeValueViewNote` is the
  /// longer text.
  public internal(set) var isCodeValueView = false

  /// Explains a code-value view (`isCodeValueView`).
  public static let codeValueViewNote =
    "Code-value view: the signal's code values are shown as they are, with no LUT, viewing transform or exposure calibration."

  public init() {}

  public var activeLabels: [String] { active.map(\.label) }
  public func isActive(_ tool: MonitorTool) -> Bool { active.contains { $0.tool == tool } }
  public func reason(for tool: MonitorTool) -> MonitorUnavailableReason? {
    unavailable.first { $0.tool == tool }?.reason
  }
}
