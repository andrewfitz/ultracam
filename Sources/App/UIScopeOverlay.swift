import AppKit
import MonitorKit
import MonitorKitScopes
import SwiftUI

/// A scope's shape on screen: the waveforms and the histogram are wide, the vectorscope
/// is square. The scope draws at the size it is shown at (bins follow the drawn pixels,
/// `ScopeSettings.atNativeResolution`), so any size is accurate.
enum UIScopeCardShape: String, CaseIterable, Sendable {
  case wide, square

  init(_ kind: ScopeKind) { self = kind == .vectorscope ? .square : .wide }

  /// The smallest card, in points.
  var minimumSize: CGSize { self == .square ? CGSize(width: 96, height: 96) : CGSize(width: 180, height: 60) }
}

/// Where a picture's scope card sits and how big it is, as fractions of the picture, so
/// it keeps its place on any picture size. A square card's side is a fraction of the
/// picture's height. Nil until the user moves or resizes the card: then it takes the
/// default place above the picture's bottom labels.
struct UIScopeCardFrame: Equatable, Codable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double

  /// Space kept clear inside the picture's edges.
  static let margin: CGFloat = 8
  /// The picture's bottom labels (name, format, timecode) stay visible under a default card.
  static let bottomLabels: CGFloat = 44

  /// The card's default rectangle: a wide card at the bottom left, a square one at the
  /// bottom right, both above the bottom labels.
  static func defaultRect(_ shape: UIScopeCardShape, in size: CGSize) -> CGRect {
    switch shape {
    case .wide:
      let width = min(size.width * 0.5, 520)
      let height = width / 3
      return clamp(CGRect(x: 10, y: size.height - bottomLabels - height, width: width, height: height), shape, in: size)
    case .square:
      let side = min(size.height * 0.4, 280)
      return clamp(CGRect(x: size.width - 10 - side, y: size.height - bottomLabels - side, width: side, height: side),
        shape, in: size)
    }
  }

  /// `rect` kept inside the picture, at least the shape's minimum and square when the
  /// shape is. A picture smaller than the minimum gets the whole picture.
  static func clamp(_ rect: CGRect, _ shape: UIScopeCardShape, in size: CGSize) -> CGRect {
    let room = CGSize(width: max(0, size.width - 2 * margin), height: max(0, size.height - 2 * margin))
    func finite(_ v: CGFloat, _ fallback: CGFloat) -> CGFloat { v.isFinite ? v : fallback }
    var width = min(max(finite(rect.width, shape.minimumSize.width), shape.minimumSize.width), room.width)
    var height = min(max(finite(rect.height, shape.minimumSize.height), shape.minimumSize.height), room.height)
    if shape == .square {
      let side = min(max(width, height), room.width, room.height)
      width = side
      height = side
    }
    let x = min(max(finite(rect.minX, margin), margin), max(margin, size.width - margin - width))
    let y = min(max(finite(rect.minY, margin), margin), max(margin, size.height - margin - height))
    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// The rectangle this frame gives on a picture of `size`.
  func rect(_ shape: UIScopeCardShape, in size: CGSize) -> CGRect {
    let width = shape == .square ? height * size.height : width * size.width
    return Self.clamp(CGRect(x: x * size.width, y: y * size.height, width: width, height: height * size.height),
      shape, in: size)
  }

  /// The frame that gives `rect` on a picture of `size`.
  init(_ rect: CGRect, _ shape: UIScopeCardShape, in size: CGSize) {
    let w = max(size.width, 1), h = max(size.height, 1)
    x = rect.minX / w
    y = rect.minY / h
    width = rect.width / w
    height = rect.height / h
  }

  /// A move by `translation` from `start`.
  static func moved(_ start: CGRect, by translation: CGSize, _ shape: UIScopeCardShape, in size: CGSize) -> CGRect {
    clamp(start.offsetBy(dx: translation.width, dy: translation.height), shape, in: size)
  }

  /// A resize from the bottom-trailing corner by `translation`: a square card follows the
  /// larger of the two moves, so the corner stays under the pointer along the diagonal.
  static func resized(_ start: CGRect, by translation: CGSize, _ shape: UIScopeCardShape, in size: CGSize) -> CGRect {
    // Sizes as plain numbers: a CGRect with a negative size would flip it to the other side.
    var width: CGFloat
    var height: CGFloat
    if shape == .square {
      let grow = max(translation.width, translation.height)
      width = start.width + grow
      height = start.height + grow
    } else {
      width = start.width + translation.width
      height = start.height + translation.height
    }
    // Resizing never moves the card: what doesn't fit is taken off its size.
    width = min(max(width, shape.minimumSize.width), size.width - margin - start.minX)
    height = min(max(height, shape.minimumSize.height), size.height - margin - start.minY)
    if shape == .square {
      width = min(width, height)
      height = width
    }
    return clamp(CGRect(x: start.minX, y: start.minY, width: max(0, width), height: max(0, height)), shape, in: size)
  }
}

/// The scope cards' saved places, one per shape, shared by every picture.
@MainActor @Observable final class UIScopeCardPlaces {
  static let shared = UIScopeCardPlaces()
  static func key(_ shape: UIScopeCardShape) -> String { "ui.scopes.card.\(shape.rawValue)" }

  @ObservationIgnored private let defaults: UserDefaults
  private var frames: [UIScopeCardShape: UIScopeCardFrame]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    var frames: [UIScopeCardShape: UIScopeCardFrame] = [:]
    for shape in UIScopeCardShape.allCases {
      if let data = defaults.data(forKey: Self.key(shape)),
        let frame = try? JSONDecoder().decode(UIScopeCardFrame.self, from: data),
        [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
      {
        frames[shape] = frame
      }
    }
    self.frames = frames
  }

  func rect(_ shape: UIScopeCardShape, in size: CGSize) -> CGRect {
    frames[shape]?.rect(shape, in: size) ?? UIScopeCardFrame.defaultRect(shape, in: size)
  }

  func save(_ rect: CGRect, _ shape: UIScopeCardShape, in size: CGSize) {
    let frame = UIScopeCardFrame(rect, shape, in: size)
    frames[shape] = frame
    if let data = try? JSONEncoder().encode(frame) { defaults.set(data, forKey: Self.key(shape)) }
  }

  /// Back to the default place.
  func reset(_ shape: UIScopeCardShape) {
    frames[shape] = nil
    defaults.removeObject(forKey: Self.key(shape))
  }
}

/// The pictures whose scope is in its own window, and the main window's picture
/// presenters, observed, so a Scopes window finds its camera's scope when the picture
/// appears and the picture drops its card while the window is open.
@MainActor @Observable final class UIScopePopOuts {
  static let shared = UIScopePopOuts()
  private(set) var open: Set<String> = []

  func setOpen(_ isOpen: Bool, target: String) {
    if isOpen != open.contains(target) {
      if isOpen { open.insert(target) } else { open.remove(target) }
    }
  }
}

/// The Scopes window's id; its value is the picture's target ID.
enum UIScopeWindow {
  static let id = "scopes"

  /// A wide scope opens wide, a vectorscope square.
  static func defaultSize(_ shape: UIScopeCardShape) -> CGSize {
    shape == .square ? CGSize(width: 520, height: 600) : CGSize(width: 900, height: 380)
  }
}

/// A picture's scope as a card over it: drag it anywhere on the picture, resize it from
/// its corner (a vectorscope stays square), double-click it to put it back. On hover it
/// names the scope and offers Pop Out (its own window) and Hide (turns the scope off).
struct UIScopeCard<Scope: View>: View {
  let description: UIScopeDescription
  let size: CGSize
  var onPopOut: () -> Void
  var onHide: () -> Void
  @ViewBuilder var scope: () -> Scope

  @State private var hovering = false
  /// The card's rectangle while it is being dragged or resized; saved when the drag ends.
  @State private var live: CGRect?
  @State private var start: CGRect?
  private var places: UIScopeCardPlaces { .shared }
  private var shape: UIScopeCardShape { UIScopeCardShape(description.settings.kind) }

  var body: some View {
    let rect = live ?? places.rect(shape, in: size)
    let chrome = hovering || live != nil
    UIScopeImage(description: description, scope: scope)
      .frame(width: rect.width, height: rect.height)
      .background(Color.black.opacity(0.6))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(chrome ? 0.35 : 0.12), lineWidth: 1)
      }
      .overlay(alignment: .top) { if chrome { header } }
      .overlay(alignment: .bottomTrailing) { if chrome { grip(rect) } }
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .gesture(move(rect))
      .onTapGesture(count: 2) { places.reset(shape) }
      .onHover { hovering = $0 }
      .help("Drag to move, drag the corner to resize, double-click to put it back")
      .position(x: rect.midX, y: rect.midY)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(description.title)
      .accessibilityAction(named: "Pop Out") { onPopOut() }
      .accessibilityAction(named: "Hide") { onHide() }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Text(description.title).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
      Spacer(minLength: 4)
      Button(action: onPopOut) { Image(systemName: UISymbol.scopePopOut) }
        .help("Open this scope in its own window")
        .accessibilityLabel("Pop Out")
      Button(action: onHide) { Image(systemName: UISymbol.close) }
        .help("Hide the scope")
        .accessibilityLabel("Hide Scope")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.white.opacity(0.85))
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(.black.opacity(0.55))
    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
  }

  private func grip(_ rect: CGRect) -> some View {
    Image(systemName: UISymbol.resizeGrip)
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.white.opacity(0.7))
      .frame(width: 18, height: 18)
      .contentShape(Rectangle())
      .gesture(resize(rect))
      .accessibilityHidden(true)
  }

  private func move(_ rect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        let from = start ?? rect
        start = from
        live = UIScopeCardFrame.moved(from, by: value.translation, shape, in: size)
      }
      .onEnded { _ in finish() }
  }

  private func resize(_ rect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        let from = start ?? rect
        start = from
        live = UIScopeCardFrame.resized(from, by: value.translation, shape, in: size)
      }
      .onEnded { _ in finish() }
  }

  private func finish() {
    if let live { places.save(live, shape, in: size) }
    live = nil
    start = nil
  }
}

/// A camera's (or Program's) scope in its own window, sized and placed like any window,
/// at native resolution. It shows the main window's picture's scope, so it needs that
/// picture on screen; while it is open the picture shows no card.
struct UIScopeWindowView: View {
  let model: AppModel
  let target: String
  @ObservedObject var coordinator: MonitorCoordinator
  @State private var settingsShown = false

  private var targetID: MonitorTargetID { MonitorTargetID(target) }
  private var isProgram: Bool { targetID.isProgram }
  private var preferences: MonitorFeedPreferences { coordinator.preferences(for: targetID) }
  private var presenter: MonitorSurfacePresenter? { UIMonitorBridge.presenter(for: target) }

  private var name: String {
    isProgram ? "Program" : model.descriptor(for: FeedID(rawValue: target))?.name ?? "Camera"
  }

  var body: some View {
    content
      .frame(minWidth: 240, minHeight: 160)
      .background(Color.black)
      .navigationTitle("\(name) Scope")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button { settingsShown.toggle() } label: { Label("Scope Settings", systemImage: UISymbol.scopeSettings) }
            .help("Choose the scope and how it reads")
            .popover(isPresented: $settingsShown, arrowEdge: .bottom) {
              UIScopeSettingsView(
                scopes: Binding(get: { preferences.scopes }, set: { value in
                  var next = preferences
                  next.scopes = value
                  coordinator.setPreferences(next, for: targetID)
                }),
                isProgram: isProgram, signal: presenter?.shownSignal,
                stageLUT: presenter?.scopeMeasuresLUT(preferences) == true)
              .padding(16)
              .frame(width: 320)
            }
        }
      }
      .onAppear { UIScopePopOuts.shared.setOpen(true, target: target) }
      .onDisappear { UIScopePopOuts.shared.setOpen(false, target: target) }
  }

  @ViewBuilder private var content: some View {
    if !preferences.scopesShown {
      placeholder("The scope is off", action: "Turn On Scope") {
        coordinator.setPreferences(UIMonitorBridge.toggled(.scopes, in: preferences, isProgram: isProgram), for: targetID)
      }
    } else if let presenter {
      UIScopeWindowScope(presenter: presenter, preferences: preferences, isProgram: isProgram)
    } else {
      placeholder("Show \(name) in the main window to see its scope", action: nil) {}
    }
  }

  private func placeholder(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
    VStack(spacing: 10) {
      Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let action { Button(action, action: perform) }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The pop-out's scope, its labels and its clip readout.
private struct UIScopeWindowScope: View {
  @ObservedObject var presenter: MonitorSurfacePresenter
  let preferences: MonitorFeedPreferences
  let isProgram: Bool

  var body: some View {
    let displayed = presenter.isFrozen ? presenter.shownPreferences : preferences
    let description = UIScopeDescription(scopes: displayed.scopes, signal: presenter.shownSignal,
      stageLUT: presenter.scopeMeasuresLUT(displayed), isProgram: isProgram)
    VStack(alignment: .leading, spacing: 6) {
      UIScopeImage(description: description) { MonitorNativeScope(presenter: presenter) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(description.title)
      HStack(alignment: .bottom) {
        UIScopeClipReadoutView(reader: presenter.scopeStatisticsReader, settings: description.settings,
          isLive: !presenter.isFrozen)
        Spacer(minLength: 8)
        Text(description.caption).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
          .multilineTextAlignment(.trailing)
      }
    }
    .padding(10)
    .environment(\.colorScheme, .dark)
  }
}
