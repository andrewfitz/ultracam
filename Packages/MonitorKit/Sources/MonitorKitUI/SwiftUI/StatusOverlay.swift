import MonitorKit
import MonitorKitCore
import SwiftUI

/// Host metadata shown over a surface: timecode, format, LUT name, a tally
/// border and free labels. The library knows none of these values; the host
/// supplies them (its capture, recording and switcher state). Text lives in the
/// UI layer, never in the frames.
public struct MonitorOverlayMetadata: Equatable, Sendable {
  /// The surface's on-air state, drawn as a border: green on preview, red on
  /// program and while recording (recording also shows REC).
  public enum Tally: Equatable, Sendable, CaseIterable { case off, preview, program, recording }

  public enum Corner: Equatable, Hashable, Sendable, CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

  /// A host label in a corner, after the standard items of that corner.
  public struct Label: Equatable, Sendable {
    public var text: String
    public var corner: Corner
    public init(_ text: String, corner: Corner) {
      self.text = text
      self.corner = corner
    }
  }

  /// Shown top trailing, e.g. "01:00:00:00".
  public var timecode: String?
  /// Shown top leading, e.g. "UHD 23.98 · S-Log3".
  public var format: String?
  /// Shown bottom leading.
  public var lutName: String?
  public var tally: Tally
  public var labels: [Label]

  public init(
    timecode: String? = nil, format: String? = nil, lutName: String? = nil, tally: Tally = .off, labels: [Label] = []
  ) {
    self.timecode = timecode
    self.format = format
    self.lutName = lutName
    self.tally = tally
    self.labels = labels
  }

  /// The texts of `corner`, in order: the standard item there, then the host's labels.
  public func texts(in corner: Corner) -> [String] {
    var out: [String] = []
    switch corner {
    case .topLeading: if let format { out.append(format) }
    case .topTrailing: if let timecode { out.append(timecode) }
    case .bottomLeading: if let lutName { out.append(lutName) }
    case .bottomTrailing: break
    }
    for label in labels where label.corner == corner { out.append(label.text) }
    return out
  }

  /// What VoiceOver reads.
  public var accessibilityDescription: String {
    var parts: [String] = []
    switch tally {
    case .off: break
    case .preview: parts.append("Preview")
    case .program: parts.append("Program")
    case .recording: parts.append("Recording")
    }
    if let format { parts.append(format) }
    if let timecode { parts.append("Timecode \(timecode)") }
    if let lutName { parts.append("LUT \(lutName)") }
    parts += labels.map(\.text)
    return parts.joined(separator: ", ")
  }
}

/// Metadata that changes at video rate (a timecode every frame), observed only
/// by the overlays that show it: the view holding the `MonitorMetalView` is not
/// re-evaluated on each tick, only the overlay's text.
@MainActor @Observable
public final class MonitorOverlayModel {
  public var metadata: MonitorOverlayMetadata

  public init(_ metadata: MonitorOverlayMetadata = MonitorOverlayMetadata()) { self.metadata = metadata }
}

/// Draws `MonitorOverlayMetadata` over one surface of a `MonitorView` or
/// `MonitorSceneView`: lay it in an `.overlay` of the same size as the view.
/// It covers exactly the target pixels the surface's `region` draws into (the
/// renderer's rounding, at the screen's scale), with the tally border inset
/// inside them. `clean` (pass the surface's `MonitorState.clean`, or the scene's
/// `clean`) hides it all, like every other overlay. It redraws only when its
/// inputs change. For a timecode that changes every frame, pass a
/// `MonitorOverlayModel` the parent does not read: its edits then redraw only this.
public struct MonitorStatusOverlay: View {
  private let value: MonitorOverlayMetadata?
  private let model: MonitorOverlayModel?
  let region: MonitorRegion
  let clean: Bool
  @Environment(\.displayScale) private var displayScale

  public init(metadata: MonitorOverlayMetadata, region: MonitorRegion = .full, clean: Bool = false) {
    value = metadata
    model = nil
    self.region = region
    self.clean = clean
  }

  public init(model: MonitorOverlayModel, region: MonitorRegion = .full, clean: Bool = false) {
    value = nil
    self.model = model
    self.region = region
    self.clean = clean
  }

  /// Read in `body`, so a model's edits invalidate only this view.
  var metadata: MonitorOverlayMetadata { model?.metadata ?? value ?? MonitorOverlayMetadata() }

  /// Tally border width in points (inside the surface's edge).
  static let tallyWidth: CGFloat = 4

  /// The surface's rectangle in view points: its viewport in a drawable of the
  /// view's size at `scale`, as the renderer computes it, back in points.
  public static func frame(of region: MonitorRegion, in size: CGSize, scale: CGFloat) -> CGRect? {
    let s = max(1, scale)
    let w = Int(max(1, (size.width * s).rounded())), h = Int(max(1, (size.height * s).rounded()))
    guard size.width > 0, size.height > 0, let vp = region.viewport(width: w, height: h) else { return nil }
    return CGRect(
      x: CGFloat(vp.x) / s, y: CGFloat(vp.y) / s, width: CGFloat(vp.width) / s, height: CGFloat(vp.height) / s)
  }

  static func tallyColor(_ tally: MonitorOverlayMetadata.Tally) -> Color? {
    switch tally {
    case .off: return nil
    case .preview: return Color(red: 0.1, green: 0.85, blue: 0.3)
    case .program, .recording: return Color(red: 1, green: 0.15, blue: 0.1)
    }
  }

  public var body: some View {
    let metadata = self.metadata
    // Once per body: it builds and joins a string array.
    let description = clean ? "" : metadata.accessibilityDescription
    GeometryReader { geo in
      if !clean, let rect = Self.frame(of: region, in: geo.size, scale: displayScale) {
        content(metadata)
          .frame(width: rect.width, height: rect.height)
          .offset(x: rect.minX, y: rect.minY)
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Monitor status")
    .accessibilityValue(description)
    .accessibilityHidden(description.isEmpty)
  }

  private func content(_ metadata: MonitorOverlayMetadata) -> some View {
    ZStack {
      if let color = Self.tallyColor(metadata.tally) {
        Rectangle().strokeBorder(color, lineWidth: Self.tallyWidth)
      }
      VStack(spacing: 0) {
        HStack(alignment: .top) {
          corner(metadata.texts(in: .topLeading), alignment: .leading)
          Spacer(minLength: 8)
          if metadata.tally == .recording {
            Text("● REC").foregroundStyle(Color(red: 1, green: 0.2, blue: 0.15)).modifier(OverlayText())
          }
          Spacer(minLength: 8)
          corner(metadata.texts(in: .topTrailing), alignment: .trailing)
        }
        Spacer(minLength: 0)
        HStack(alignment: .bottom) {
          corner(metadata.texts(in: .bottomLeading), alignment: .leading)
          Spacer(minLength: 8)
          corner(metadata.texts(in: .bottomTrailing), alignment: .trailing)
        }
      }
      .padding(Self.tallyWidth + 4)
    }
  }

  private func corner(_ texts: [String], alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      ForEach(texts.indices, id: \.self) { i in
        Text(texts[i]).modifier(OverlayText())
      }
    }
  }
}

/// Monitor-style readout text: small monospaced digits on a dark plate, legible
/// over any picture.
struct OverlayText: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.system(.caption, design: .monospaced).weight(.medium))
      .monospacedDigit()
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.black.opacity(0.55)))
  }
}
