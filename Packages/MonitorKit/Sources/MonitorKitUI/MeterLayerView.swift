// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitAudio
import QuartzCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// One frame of a meter, drawn as rectangles: each takes the next sublayer of a
/// pool, and a layer's properties are set only when they change. A frame that
/// looks like the last one sets nothing, so Core Animation commits nothing, and
/// nothing a frame does reaches SwiftUI or the view's layout.
@MainActor final class MeterLayers {
  private struct Look: Equatable {
    var frame: CGRect
    var fill: CGColor?
    var border: CGColor?
    var radius: CGFloat

    static func == (a: Look, b: Look) -> Bool {
      // Colours are resolved once per update, so identity is equality here.
      a.frame == b.frame && a.fill === b.fill && a.border === b.border && a.radius == b.radius
    }
  }

  let host = CALayer()
  private var layers: [CALayer] = []
  private var looks: [Look] = []
  private var used = 0
  private var height: CGFloat = 0
  private var scale: CGFloat = 2
  private var flipped = true
  /// Whether the last frame set any layer property.
  private(set) var changed = false

  init() {
    host.actions = Self.noActions
    host.masksToBounds = true
  }

  /// No implicit animation: a meter moves exactly to each frame's reading.
  static let noActions: [String: any CAAction] = [
    "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(),
    "borderColor": NSNull(), "borderWidth": NSNull(), "cornerRadius": NSNull(), "hidden": NSNull(),
    "sublayers": NSNull(), "contents": NSNull(),
  ]

  /// Starts a frame `size` points big, on a display of `scale` pixels per point.
  func begin(size: CGSize, scale: CGFloat) {
    used = 0
    changed = false
    height = size.height
    self.scale = max(1, scale)
    #if canImport(AppKit)
      // A layer-backed view's layer follows the view's flippedness; read it rather than assume it.
      flipped = host.contentsAreFlipped()
    #else
      flipped = true
    #endif
  }

  /// A filled rectangle, in top-left-origin points.
  func fill(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
    place(Look(frame: snapped(rect), fill: color, border: nil, radius: radius))
  }

  /// A rectangle's 1 pt outline.
  func outline(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
    place(Look(frame: snapped(rect), fill: nil, border: color, radius: radius))
  }

  /// Hides the layers this frame didn't use.
  func finish() {
    var i = used
    while i < layers.count {
      if !layers[i].isHidden {
        layers[i].isHidden = true
        changed = true
      }
      i += 1
    }
  }

  /// The rectangles drawn, in the view's top-left-origin points (for tests).
  var frames: [CGRect] { looks.prefix(used).map { viewRect($0.frame) } }
  /// The layer frames as set, in the host layer's own coordinates (for tests).
  var layerFrames: [CGRect] { layers.prefix(used).map(\.frame) }
  var layerCount: Int { layers.count }
  /// Whether the host layer's sublayers have a top-left origin on screen.
  var isFlipped: Bool { flipped }

  /// A layer frame back in the view's top-left-origin points.
  private func viewRect(_ r: CGRect) -> CGRect {
    flipped ? r : CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
  }

  /// Paints the last frame into a top-left-origin context: for a view drawn by
  /// `cacheDisplay` or printing, which see no sublayers.
  func paint(in context: CGContext) {
    var i = 0
    while i < used {
      let look = looks[i]
      let rect = viewRect(look.frame)
      let path = CGPath(roundedRect: rect, cornerWidth: look.radius, cornerHeight: look.radius, transform: nil)
      if let fill = look.fill {
        context.setFillColor(fill)
        context.addPath(path)
        context.fillPath()
      }
      if let border = look.border {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let r = max(0, look.radius - 0.5)
        context.setStrokeColor(border)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil))
        context.strokePath()
      }
      i += 1
    }
  }

  private func snapped(_ r: CGRect) -> CGRect {
    // Whole pixels: edges land where Core Animation draws them, and a bar
    // moves in steps of one pixel rather than shimmering across two.
    let s = scale
    let y = flipped ? r.minY : height - r.maxY
    let x0 = (r.minX * s).rounded() / s
    let y0 = (y * s).rounded() / s
    var x1 = (r.maxX * s).rounded() / s
    var y1 = ((y + r.height) * s).rounded() / s
    // Never thinner than a pixel: a hold or reference line always shows.
    if r.width > 0, x1 <= x0 { x1 = x0 + 1 / s }
    if r.height > 0, y1 <= y0 { y1 = y0 + 1 / s }
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  private func place(_ look: Look) {
    if used == layers.count {
      let layer = CALayer()
      layer.actions = Self.noActions
      layer.isOpaque = false
      host.addSublayer(layer)
      layers.append(layer)
      looks.append(Look(frame: .null, fill: nil, border: nil, radius: -1))
    }
    let layer = layers[used]
    let old = looks[used]
    if layer.isHidden {
      layer.isHidden = false
      changed = true
    }
    if old != look {
      if old.frame != look.frame { layer.frame = look.frame }
      if old.fill !== look.fill { layer.backgroundColor = look.fill }
      if old.border !== look.border {
        layer.borderColor = look.border
        layer.borderWidth = look.border == nil ? 0 : 1
      }
      if old.radius != look.radius { layer.cornerRadius = look.radius }
      looks[used] = look
      changed = true
    }
    used += 1
  }
}

/// The palette resolved to Core Graphics colours for one environment: built when
/// the view updates (appearance, palette), never per frame.
struct MeterLayerColors {
  let well: CGColor
  let reference: CGColor
  let outline: CGColor
  let over: CGColor
  private let lit: [CGColor]
  private let unlit: [CGColor]

  @MainActor init(_ palette: MeterPalette, in environment: EnvironmentValues) {
    func cg(_ c: Color) -> CGColor { c.resolve(in: environment).cgColor }
    let colors = LevelMeterColors(palette, scheme: environment.colorScheme)
    well = cg(colors.well)
    reference = cg(colors.reference)
    outline = cg(colors.outline)
    over = cg(palette.over)
    lit = [MeterZoneKind.normal, .target, .caution, .over].map { cg(palette.color($0)) }
    unlit = [MeterZoneKind.normal, .target, .caution, .over].map { cg(palette.color($0).opacity(palette.unlitOpacity)) }
  }

  private static func index(_ zone: MeterZoneKind?) -> Int {
    switch zone {
    case .normal?, nil: return 0
    case .target?: return 1
    case .caution?: return 2
    case .over?: return 3
    }
  }

  func lit(_ zone: MeterZoneKind?) -> CGColor { lit[Self.index(zone)] }

  /// `LevelMeterColors`'s colour for a part.
  func callAsFunction(_ part: LevelMeterPart) -> CGColor {
    switch part {
    case .well: return well
    case .unlit(let zone): return unlit[Self.index(zone)]
    case .lit(let zone): return lit(zone)
    case .hold(let zone): return lit(zone)
    case .reference: return reference
    }
  }
}

/// What a meter's drawing is told each frame.
struct MeterFrame {
  /// Seconds on the media clock: the display's next vsync on a tick.
  let time: Double
  let size: CGSize
  /// True on a display tick, false for the draw a view update asks for. Only a
  /// tick may write the readouts' state: an update must not change state.
  let isTick: Bool
}

#if canImport(AppKit)
  typealias MeterPlatformView = NSView
#elseif canImport(UIKit)
  typealias MeterPlatformView = UIView
#endif

/// A meter's bars as Core Animation layers, redrawn by the display link while
/// live and visible, and once on each view update otherwise. Clicks pass through
/// to the SwiftUI view around it.
@MainActor final class MeterLayerView: MeterPlatformView {
  let layers = MeterLayers()
  var colors: MeterLayerColors?
  var draw: ((MeterFrame, MeterLayers, MeterLayerColors) -> Void)?
  /// Whether readings move on their own (a live meter with audio): the display link runs.
  var isLive = false {
    didSet { if isLive != oldValue { updateLink() } }
  }
  private var link: CADisplayLink?
  /// Display ticks drawn, for tests and diagnostics.
  private(set) var tickCount = 0
  #if canImport(AppKit)
    private var occlusion: (any NSObjectProtocol)?
    /// Whether the window has reported an occlusion change. Until it has, its
    /// state can read "not visible" for a window on screen (as `MonitorMetalView` finds).
    private var occlusionReported = false
  #endif

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(AppKit)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
      layer?.addSublayer(layers.host)
    #else
      isUserInteractionEnabled = false
      isOpaque = false
      layer.addSublayer(layers.host)
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("MeterLayerView is created in code") }

  isolated deinit {
    link?.invalidate()
    #if canImport(AppKit)
      if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    #endif
  }

  /// Draws now, outside a tick.
  func redraw() { render(MeterFrame(time: CACurrentMediaTime(), size: bounds.size, isTick: false)) }

  /// Ticks drawn by every meter in the process.
  static var totalTicks = 0

  /// One display tick (tests call it directly).
  func step(at time: Double) {
    tickCount += 1
    Self.totalTicks += 1
    render(MeterFrame(time: time, size: bounds.size, isTick: true))
  }

  private func render(_ frame: MeterFrame) {
    guard let draw, let colors, frame.size.width > 0, frame.size.height > 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if layers.host.frame != CGRect(origin: .zero, size: frame.size) {
      layers.host.frame = CGRect(origin: .zero, size: frame.size)
    }
    layers.begin(size: frame.size, scale: displayScale)
    draw(frame, layers, colors)
    layers.finish()
    CATransaction.commit()
  }

  private var displayScale: CGFloat {
    #if canImport(AppKit)
      window?.backingScaleFactor ?? 2
    #else
      traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    #endif
  }

  // MARK: Display link

  private var isVisible: Bool {
    #if canImport(AppKit)
      guard let window, !isHiddenOrHasHiddenAncestor else { return false }
      return !occlusionReported || window.occlusionState.contains(.visible)
    #else
      return window != nil && !isHidden
    #endif
  }

  private func updateLink() {
    let run = isLive && isVisible
    if run, link == nil {
      let target = MeterLinkTarget(self)
      #if canImport(AppKit)
        let link = displayLink(target: target, selector: #selector(MeterLinkTarget.tick(_:)))
      #else
        let link = CADisplayLink(target: target, selector: #selector(MeterLinkTarget.tick(_:)))
      #endif
      link.add(to: .main, forMode: .common)
      self.link = link
    } else if !run, let link {
      link.invalidate()
      self.link = nil
    }
  }

  /// Whether the display link runs (for tests).
  var isLinkRunning: Bool { link != nil }

  #if canImport(AppKit)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // On screen the sublayers are the picture: the backing layer gets no bitmap.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    /// Only for drawing into a context (`cacheDisplay`, printing), which sees no sublayers.
    override func draw(_ dirtyRect: NSRect) {
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      layers.paint(in: context)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
      occlusion = nil
      occlusionReported = false
      if let window {
        occlusion = NotificationCenter.default.addObserver(
          forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.occlusionReported = true
            self?.updateLink()
          }
        }
      }
      updateLink()
      redraw()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      redraw()
    }

    override func viewDidHide() {
      super.viewDidHide()
      updateLink()
    }

    override func viewDidUnhide() {
      super.viewDidUnhide()
      updateLink()
    }

    override func layout() {
      super.layout()
      redraw()
    }
  #else
    override func didMoveToWindow() {
      super.didMoveToWindow()
      updateLink()
      redraw()
    }

    override var isHidden: Bool {
      didSet { updateLink() }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      redraw()
    }
  #endif
}

/// The display link's target: the link retains it, not the view. The link is on
/// the main run loop, so it ticks on the main thread.
@MainActor private final class MeterLinkTarget: NSObject {
  weak var view: MeterLayerView?

  init(_ view: MeterLayerView) { self.view = view }

  @objc func tick(_ link: CADisplayLink) { view?.step(at: link.targetTimestamp) }
}

/// `MeterLayerView` in SwiftUI. A view update hands it the newest drawing and
/// draws once; a live meter then redraws on its own at the display rate.
struct MeterLayerRepresentable {
  let live: Bool
  let palette: MeterPalette
  let draw: @MainActor (MeterFrame, MeterLayers, MeterLayerColors) -> Void

  @MainActor func update(_ view: MeterLayerView, _ environment: EnvironmentValues) {
    view.colors = MeterLayerColors(palette, in: environment)
    view.draw = draw
    view.isLive = live
    view.redraw()
  }
}

#if canImport(AppKit)
  extension MeterLayerRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> MeterLayerView { MeterLayerView(frame: .zero) }
    func updateNSView(_ view: MeterLayerView, context: Context) { update(view, context.environment) }
  }
#else
  extension MeterLayerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MeterLayerView { MeterLayerView(frame: .zero) }
    func updateUIView(_ view: MeterLayerView, context: Context) { update(view, context.environment) }
  }
#endif

/// What the meters' drawing reports, for a host's diagnostics and performance checks.
public enum MeterDiagnostics {
  /// Display frames drawn so far by every level and audio meter in the process,
  /// counting each meter's bars separately.
  @MainActor public static var displayTicks: Int { MeterLayerView.totalTicks }
}

/// A spoken or tooltip summary that a meter's ticks refresh at most once a
/// second, and only when its words change.
@MainActor @Observable final class MeterSummaryStore {
  private(set) var text = ""
  @ObservationIgnored private var last = -Double.infinity

  func update(at time: Double, _ make: () -> String) {
    guard time - last >= 1 || time < last else { return }
    last = time
    let t = make()
    if t != text { text = t }
  }
}
