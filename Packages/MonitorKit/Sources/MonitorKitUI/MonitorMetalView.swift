import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import QuartzCore

#if canImport(AppKit)
  import AppKit
  /// `NSView` on macOS, `UIView` on iOS.
  public typealias MonitorPlatformView = NSView
#elseif canImport(UIKit)
  import UIKit
  /// `NSView` on macOS, `UIView` on iOS.
  public typealias MonitorPlatformView = UIView
#endif

/// A CAMetalLayer view that draws a `MonitorScene` at display rate.
///
/// - Display link: a `CAMetalDisplayLink` on the layer (macOS 14 / iOS 17 and
///   later), added to the main run loop or the host's render thread's
///   (`displayLinkRunLoop`). It vends each drawable with its vsync, so a tick
///   never blocks in `nextDrawable()`. It pauses while the view is out of a
///   window, hidden, occluded (macOS) or the app is in the background (iOS).
/// - Colour: the layer's pixel format, colour space, EDR flag and EDR metadata
///   follow the scene's `MonitorOutputColor` (resolved per tick, applied only
///   on change). The EDR headroom is read from the view's screen on the main
///   thread ten times a second while the link runs (not while paused) and on
///   every screen change; it reaches this view's renderer (not the shared scene,
///   which another view may show on another screen) as a uniform, so the tick
///   never waits for the main thread.
/// - Memory: replaced frames are released as soon as the GPU finished with them:
///   a convenience view watches the `status` of its last committed command
///   buffer, a host-driven one takes what the host reports through
///   `MonitorDrawableContext.completion` (or `completionReporter`). While the
///   view is paused or hidden it keeps no frame and no focus mask at all once
///   that work completed (a convenience view commits one empty marker buffer
///   whose completion handler releases them), so a capture pool needs no extra
///   buffers for a minimised monitor.
/// - Scopes: a convenience view presenting a drawable commits each tick's scope
///   accumulation in a second command buffer after the pictures', so the
///   drawable never waits for it; the scopes show the previous tick's bins
///   (`MonitorRenderer.encodePictures`). `drawOffscreen` accumulates first, so a
///   snapshot's scopes are its own frame's.
/// - Size: `drawableSize` follows the bounds times the backing scale, set only
///   when it changes; nothing is allocated per frame.
/// - Gestures: pinch or scroll to magnify about the pointer, drag to pan,
///   double click (double tap) for pixel-exact, a click in the navigator to
///   jump there; on macOS also + / - / 0 and the arrow keys. They edit the
///   surface's `MonitorState.geometry.magnification` (`MonitorMagnifier`) against
///   the layout of its current state in this view, so every event counts however
///   many arrive between draws, and report through `onSurfaceStateChange`.
///
/// Convenience mode draws on the queue it is given (or one it makes). Host
/// mode calls the host's closure with the drawable on the link's thread.
@MainActor
public final class MonitorMetalView: MonitorPlatformView {
  public let engine: MonitorEngine
  public let scene: MonitorScene
  public let metalLayer: CAMetalLayer
  public let configuration: MonitorMetalViewConfiguration
  /// Fixed headroom instead of the screen's (tests, a host that measures its own).
  public var headroomOverride: Double? {
    didSet { refreshHeadroom() }
  }
  /// The headroom in effect.
  public private(set) var headroom = 1.0
  /// Pauses drawing (the link also pauses by itself while the view is not visible).
  public var isPaused = false {
    didSet { updatePause() }
  }
  /// The layer's tag when the host draws something other than the scene (host
  /// mode with its own passes): applied on the next tick instead of the scene's.
  public var layerColorOverride: MonitorLayerColor? {
    get { driver.layerColorOverride }
    set { driver.layerColorOverride = newValue }
  }
  /// After a gesture edited a surface's state (on the main thread).
  public var onSurfaceStateChange: ((MonitorSurface) -> Void)?
  /// After a draw changed a surface's `status` (on the main thread).
  public var onStatusChange: (() -> Void)?
  /// After a draw changed a scope overlay's `graticule` (on the main thread).
  public var onGraticuleChange: (() -> Void)?
  /// After the renderer recorded an error (on the main thread): a scope engine
  /// that failed to build, a surface or scope that could not encode.
  public var onError: ((any Error) -> Void)?

  let driver: MonitorDisplayDriver
  let runLoop: RunLoop
  private var link: CAMetalDisplayLink?
  private var observers: [NSObjectProtocol] = []
  private(set) var headroomTimer: Timer?
  /// Whether the window has reported its occlusion since the view joined it.
  /// Until it does the view counts as visible: a window is usually still
  /// ordered out when its views are added, and pausing on that state would
  /// depend on a notification arriving later.
  private var occlusionReported = false
  private var dragSurface: MonitorSurface?
  private var lastDrag: CGPoint?

  /// The renderer behind the view. It is confined to the display link's thread:
  /// touch it only from there (a host-driven closure) or while the link runs on
  /// the main run loop.
  public var renderer: MonitorRenderer { driver.renderer }
  /// The queue a convenience view draws on.
  public var commandQueue: MTLCommandQueue? { driver.commandQueue }
  /// Where a host-driven view's host reports finished GPU work, from any thread
  /// (also handed to each tick as `MonitorDrawableContext.completion`).
  public nonisolated var completionReporter: MonitorCompletionReporter { driver.completion }
  /// Ticks that drew, and ticks that kept the picture on screen (nothing changed,
  /// a host returned false, or the layer was re-tagged).
  public var drawCount: Int { driver.drawCount }
  public var skippedCount: Int { driver.skippedCount }

  public init(
    engine: MonitorEngine, scene: MonitorScene = MonitorScene(), mode: MonitorMetalViewMode = .convenience(queue: nil),
    configuration: MonitorMetalViewConfiguration = MonitorMetalViewConfiguration(),
    scopeEngine: ScopeEngine? = nil, displayLinkRunLoop: RunLoop = .main
  ) {
    self.engine = engine
    self.scene = scene
    self.configuration = configuration
    runLoop = displayLinkRunLoop
    let layer = CAMetalLayer()
    metalLayer = layer
    driver = MonitorDisplayDriver(
      renderer: MonitorRenderer(engine: engine, scene: scene, scopeEngine: scopeEngine), layer: layer, mode: mode,
      runLoop: displayLinkRunLoop)
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    configureLayer()
    #if canImport(AppKit)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
    #elseif canImport(UIKit)
      layer.frame = bounds
      self.layer.addSublayer(layer)
      installGestures()
    #endif
    driver.notify = { [weak self] status, graticule, error in
      guard let self else { return }
      if status {
        self.updateAccessibility()
        self.onStatusChange?()
      }
      if graticule { self.onGraticuleChange?() }
      if let error { self.onError?(error) }
    }
    updateAccessibility()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("MonitorMetalView is created in code") }

  isolated deinit {
    link?.invalidate()
    headroomTimer?.invalidate()
    for o in observers { NotificationCenter.default.removeObserver(o) }
  }

  private func configureLayer() {
    let l = metalLayer
    l.device = engine.device
    l.framebufferOnly = configuration.framebufferOnly
    l.maximumDrawableCount = configuration.maximumDrawableCount
    l.presentsWithTransaction = false
    l.isOpaque = true
    l.backgroundColor = CGColor(gray: 0, alpha: 1)
    l.needsDisplayOnBoundsChange = false
    l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "drawableSize": NSNull()]
    let initial = MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886))
    initial.apply(to: l)
    driver.noteApplied(initial)
  }

  // MARK: - Drawing without a drawable

  /// Draws exactly what a display tick draws, into `texture` instead of a
  /// drawable: the drawable-free path for tests, snapshots and thumbnails. The
  /// layer is re-tagged as a tick would. In convenience mode it encodes into
  /// `commandBuffer` (the caller commits), or into one of its own that it
  /// commits; in host mode it calls the host's closure with no drawable.
  public func drawOffscreen(into texture: MTLTexture, commandBuffer: MTLCommandBuffer? = nil) {
    updateDrawableSize()
    refreshHeadroom()
    driver.tick(drawable: nil, texture: texture, timestamp: 0, commandBuffer: commandBuffer)
  }

  // MARK: - Display link

  private func startLink() {
    guard link == nil else { return }
    let link = CAMetalDisplayLink(metalLayer: metalLayer)
    link.delegate = driver
    link.preferredFrameLatency = configuration.preferredFrameLatency
    link.preferredFrameRateRange = configuration.preferredFrameRateRange
    self.link = link
    updatePause()
    if runLoop === RunLoop.main {
      link.add(to: .main, forMode: .common)
    } else {
      // Queued and the run loop woken: a render thread parked in `run()` on a
      // port would otherwise not attach the link until something else woke it.
      nonisolated(unsafe) let l = link
      MonitorDisplayDriver.perform(on: runLoop.getCFRunLoop()) { l.add(to: .current, forMode: .common) }
    }
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
    updateHeadroomTimer(running: false)
    becameIdle()
  }

  /// Samples the screen's headroom while the link runs; stopped while paused, so
  /// a hidden monitor does not wake the main thread (screen changes are observed
  /// either way). The screen is read on the main thread whatever thread the link
  /// runs on; the value reaches the tick, which then takes no main-thread hop.
  func updateHeadroomTimer(running: Bool) {
    guard running != (headroomTimer != nil) else { return }
    if !running {
      headroomTimer?.invalidate()
      headroomTimer = nil
      return
    }
    refreshHeadroom()
    let timer = Timer(timeInterval: Self.headroomInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshHeadroom() }
    }
    // Lets the system coalesce the wakeups of many monitors.
    timer.tolerance = Self.headroomInterval / 2
    RunLoop.main.add(timer, forMode: .common)
    headroomTimer = timer
  }

  private var isVisible: Bool {
    #if canImport(AppKit)
      guard let window, !isHiddenOrHasHiddenAncestor else { return false }
      return !occlusionReported || window.occlusionState.contains(.visible)
    #elseif canImport(UIKit)
      guard let window, !isHidden else { return false }
      return window.windowScene?.activationState != .background
    #endif
  }

  private func updatePause() {
    let paused = isPaused || !isVisible
    link?.isPaused = paused
    updateHeadroomTimer(running: link != nil && !paused)
    if paused { becameIdle() } else { driver.isIdle = false }
  }

  /// Nothing draws from now on: release the frames, on the link's thread, now and
  /// again whenever the last GPU work is known to have completed (the idle
  /// marker's handler, or the host's report), however long that takes.
  private func becameIdle() {
    guard !driver.isIdle else { return }
    driver.isIdle = true
    let driver = self.driver
    driver.performOnLink { driver.releaseIdle() }
  }

  /// Whether the display link exists and is not paused (for tests and diagnostics).
  var isDisplayLinkRunning: Bool { link.map { !$0.isPaused } ?? false }

  private func windowChanged() {
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers.removeAll()
    occlusionReported = false
    guard let window else {
      stopLink()
      return
    }
    let center = NotificationCenter.default
    func observe(_ name: Notification.Name, _ object: AnyObject?) {
      observers.append(
        center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDrawableSize()
            self?.refreshHeadroom()
            self?.updatePause()
          }
        })
    }
    #if canImport(AppKit)
      observers.append(
        center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            self?.occlusionReported = true
            self?.updatePause()
          }
        })
      observe(NSWindow.didChangeScreenNotification, window)
      observe(NSWindow.didChangeBackingPropertiesNotification, window)
      observe(NSApplication.didChangeScreenParametersNotification, nil)
    #elseif canImport(UIKit)
      observe(UIApplication.didEnterBackgroundNotification, nil)
      observe(UIApplication.willEnterForegroundNotification, nil)
      observe(UIScreen.modeDidChangeNotification, nil)
    #endif
    updateDrawableSize()
    refreshHeadroom()
    startLink()
    updatePause()
  }

  // MARK: - Size and headroom

  private var backingScale: Double {
    #if canImport(AppKit)
      Double(window?.backingScaleFactor ?? metalLayer.contentsScale)
    #elseif canImport(UIKit)
      Double(window?.screen.scale ?? traitCollection.displayScale)
    #endif
  }

  func updateDrawableSize() {
    let scale = max(1, backingScale)
    if metalLayer.contentsScale != CGFloat(scale) { metalLayer.contentsScale = CGFloat(scale) }
    #if canImport(UIKit)
      if metalLayer.frame != bounds { metalLayer.frame = bounds }
    #endif
    let size = CGSize(
      width: max(1, (bounds.width * CGFloat(scale)).rounded()), height: max(1, (bounds.height * CGFloat(scale)).rounded()))
    if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    driver.pixelsPerPoint = scale
  }

  /// Target pixels per point along x (drawable over bounds).
  private var pixelsPerPointX: Double {
    bounds.width > 0 ? Double(metalLayer.drawableSize.width / bounds.width) : backingScale
  }

  private var pixelsPerPointY: Double {
    bounds.height > 0 ? Double(metalLayer.drawableSize.height / bounds.height) : backingScale
  }

  private func screenHeadroom() -> Double {
    #if canImport(AppKit)
      MonitorDisplayHeadroom.current(for: window?.screen)
    #elseif canImport(UIKit)
      MonitorDisplayHeadroom.current(for: window?.windowScene?.screen)
    #endif
  }

  func refreshHeadroom() {
    let h = headroomOverride.map(MonitorDisplayHeadroom.sanitized) ?? screenHeadroom()
    guard h != headroom || driver.headroom != h else { return }
    headroom = h
    driver.headroom = h
  }

  /// How often the headroom is sampled while the link runs: it ramps over a few
  /// hundred milliseconds when the brightness or ambient light changes.
  static let headroomInterval = 0.1

  // MARK: - Gestures

  /// What a gesture on `surface` maps through in this view: its viewport in this
  /// view's drawable and its source's picture. Computed here rather than read
  /// from the last draw, so it holds before any draw, in host mode, and when the
  /// scene is shown in another view of another size too.
  struct GestureBase {
    var viewport: MonitorViewport
    var pictureWidth: Int
    var pictureHeight: Int
    var pixelAspectRatio: Double

    func layout(_ geometry: ViewGeometry) -> MonitorLayout {
      MonitorLayout(
        pictureWidth: pictureWidth, pictureHeight: pictureHeight, pixelAspectRatio: pixelAspectRatio,
        viewportWidth: viewport.width, viewportHeight: viewport.height, geometry: geometry)
    }
  }

  func gestureBase(_ surface: MonitorSurface) -> GestureBase? {
    let size = metalLayer.drawableSize
    guard let frame = surface.source.latestFrame,
      let vp = surface.region.viewport(width: Int(size.width), height: Int(size.height))
    else { return nil }
    return GestureBase(
      viewport: vp, pictureWidth: frame.width, pictureHeight: frame.height, pixelAspectRatio: frame.pixelAspectRatio)
  }

  /// The topmost surface under `point` (view points, origin top left), the layout
  /// of its current state and the point in its viewport's pixels.
  private func surface(at point: CGPoint) -> (MonitorSurface, MonitorLayout, (x: Double, y: Double))? {
    let px = Double(point.x) * pixelsPerPointX, py = Double(point.y) * pixelsPerPointY
    let surfaces = scene.surfaces
    var i = surfaces.count - 1
    while i >= 0 {
      let s = surfaces[i]
      i -= 1
      guard let base = gestureBase(s) else { continue }
      let vp = base.viewport
      let x = px - Double(vp.x), y = py - Double(vp.y)
      if x >= 0, y >= 0, x < Double(vp.width), y < Double(vp.height) {
        return (s, base.layout(s.state.geometry), (x, y))
      }
    }
    return nil
  }

  /// Applies one gesture step to the surface's stored state, through the layout
  /// that state shows: a second event before the next draw builds on the first.
  func edit(_ surface: MonitorSurface, _ body: (Magnification, MonitorLayout) -> Magnification?) {
    guard let base = gestureBase(surface) else { return }
    var changed = false
    surface.updateState { s in
      changed = false
      if let m = body(s.geometry.magnification, base.layout(s.geometry)), m != s.geometry.magnification {
        s.geometry.magnification = m
        changed = true
      }
    }
    if changed { onSurfaceStateChange?(surface) }
  }

  private func zoom(by factor: Double, at point: CGPoint) {
    guard configuration.gesturesEnabled, let (surface, _, p) = surface(at: point) else { return }
    edit(surface) { m, layout in MonitorMagnifier.zoom(m, by: factor, about: p, layout: layout) }
  }

  private func beginDrag(at point: CGPoint) {
    dragSurface = configuration.gesturesEnabled ? surface(at: point)?.0 : nil
    lastDrag = point
  }

  private func drag(to point: CGPoint) {
    guard let surface = dragSurface, let last = lastDrag else { return }
    lastDrag = point
    let d = (dx: Double(point.x - last.x) * pixelsPerPointX, dy: Double(point.y - last.y) * pixelsPerPointY)
    edit(surface) { m, layout in MonitorMagnifier.pan(m, by: d, layout: layout) }
  }

  private func endDrag() {
    dragSurface = nil
    lastDrag = nil
  }

  private func toggleExact(at point: CGPoint) {
    guard configuration.gesturesEnabled, let (surface, _, p) = surface(at: point) else { return }
    edit(surface) { m, layout in MonitorMagnifier.togglePixelExact(m, at: p, layout: layout) }
  }

  /// True when the point was in a navigator inset (the view recentred there).
  private func navigatorClick(at point: CGPoint) -> Bool {
    guard configuration.gesturesEnabled, let (surface, layout, p) = surface(at: point),
      MonitorMagnifier.recenter(Magnification(), navigatorPoint: p, layout: layout) != nil
    else { return false }
    edit(surface) { m, layout in MonitorMagnifier.recenter(m, navigatorPoint: p, layout: layout) }
    return true
  }

  /// Keyboard and accessibility actions act on the first surface.
  private func keyboardEdit(_ body: (Magnification, MonitorLayout) -> Magnification?) {
    guard configuration.gesturesEnabled, let surface = scene.surfaces.first else { return }
    edit(surface, body)
  }

  private func centre(of layout: MonitorLayout) -> (x: Double, y: Double) {
    (layout.viewportWidth / 2, layout.viewportHeight / 2)
  }

  private func updateAccessibility() {
    let labels = scene.surfaces.first?.status.activeLabels ?? []
    let value = labels.isEmpty ? "No tools" : labels.joined(separator: ", ")
    #if canImport(AppKit)
      setAccessibilityElement(true)
      setAccessibilityRole(.image)
      setAccessibilityLabel("Video monitor")
      setAccessibilityValue(value)
      setAccessibilityHelp("Pinch or scroll to magnify, drag to pan, double-click for pixel-exact, 0 to fit.")
    #elseif canImport(UIKit)
      isAccessibilityElement = true
      accessibilityTraits = .image
      accessibilityLabel = "Video monitor"
      accessibilityValue = value
      accessibilityHint = "Pinch to magnify, drag to pan, double-tap for pixel-exact."
    #endif
  }

  #if canImport(AppKit)
    public override func makeBackingLayer() -> CALayer { metalLayer }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { configuration.gesturesEnabled }
    public override var isOpaque: Bool { true }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      windowChanged()
    }

    public override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      updateDrawableSize()
      refreshHeadroom()
    }

    public override func viewDidHide() {
      super.viewDidHide()
      updatePause()
    }

    public override func viewDidUnhide() {
      super.viewDidUnhide()
      updatePause()
    }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    public override func magnify(with event: NSEvent) {
      zoom(by: 1 + Double(event.magnification), at: location(event))
    }

    public override func scrollWheel(with event: NSEvent) {
      let dy = Double(event.scrollingDeltaY)
      guard dy != 0 else { return super.scrollWheel(with: event) }
      // A wheel notch is 10%; a trackpad's continuous deltas are in points.
      let factor = event.hasPreciseScrollingDeltas ? exp(dy * 0.01) : pow(1.1, dy)
      zoom(by: factor, at: location(event))
    }

    public override func mouseDown(with event: NSEvent) {
      let p = location(event)
      if event.clickCount == 2 {
        toggleExact(at: p)
        return
      }
      if navigatorClick(at: p) { return }
      beginDrag(at: p)
    }

    public override func mouseDragged(with event: NSEvent) { drag(to: location(event)) }
    public override func mouseUp(with event: NSEvent) { endDrag() }

    public override func keyDown(with event: NSEvent) {
      guard configuration.gesturesEnabled else { return super.keyDown(with: event) }
      let step = 0.1
      switch event.charactersIgnoringModifiers {
      case "+", "=": keyboardEdit { m, l in MonitorMagnifier.zoom(m, by: 1.25, about: centre(of: l), layout: l) }
      case "-": keyboardEdit { m, l in MonitorMagnifier.zoom(m, by: 0.8, about: centre(of: l), layout: l) }
      case "0": keyboardEdit { m, _ in MonitorMagnifier.reset(m) }
      default:
        switch Int(event.keyCode) {
        case 123: keyboardEdit { m, l in MonitorMagnifier.pan(m, by: (l.viewportWidth * step, 0), layout: l) }
        case 124: keyboardEdit { m, l in MonitorMagnifier.pan(m, by: (-l.viewportWidth * step, 0), layout: l) }
        case 125: keyboardEdit { m, l in MonitorMagnifier.pan(m, by: (0, -l.viewportHeight * step), layout: l) }
        case 126: keyboardEdit { m, l in MonitorMagnifier.pan(m, by: (0, l.viewportHeight * step), layout: l) }
        default: super.keyDown(with: event)
        }
      }
    }
  #elseif canImport(UIKit)
    public override func didMoveToWindow() {
      super.didMoveToWindow()
      windowChanged()
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      updateDrawableSize()
    }

    public override var isHidden: Bool {
      didSet { updatePause() }
    }

    private func installGestures() {
      addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
      let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
      addGestureRecognizer(pan)
      let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
      double.numberOfTapsRequired = 2
      addGestureRecognizer(double)
      let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      single.require(toFail: double)
      addGestureRecognizer(single)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
      guard g.state == .changed || g.state == .ended else { return }
      zoom(by: Double(g.scale), at: g.location(in: self))
      g.scale = 1
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
      let p = g.location(in: self)
      switch g.state {
      case .began: beginDrag(at: p)
      case .changed: drag(to: p)
      default: endDrag()
      }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) { toggleExact(at: g.location(in: self)) }
    @objc private func tapped(_ g: UITapGestureRecognizer) { _ = navigatorClick(at: g.location(in: self)) }
  #endif
}
