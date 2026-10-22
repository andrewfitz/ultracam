import Foundation
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import Synchronization

/// A rectangle of a view in fractions of its size, origin at the top left.
public struct MonitorRegion: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public static let full = MonitorRegion(x: 0, y: 0, width: 1, height: 1)

  /// The target pixels it covers. Edges are rounded, so regions that tile the
  /// view tile the target with no gap or overlap. Nil when empty or not finite.
  public func viewport(width w: Int, height h: Int, pixelsPerPoint: Double = 1) -> MonitorViewport? {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, w > 0, h > 0 else { return nil }
    func edge(_ v: Double, _ size: Int) -> Int { Int(min(max(v, 0), 1) * Double(size) + 0.5) }
    let x0 = edge(x, w), x1 = edge(x + width, w), y0 = edge(y, h), y1 = edge(y + height, h)
    guard x1 > x0, y1 > y0 else { return nil }
    return MonitorViewport(x: x0, y: y0, width: x1 - x0, height: y1 - y0, pixelsPerPoint: pixelsPerPoint)
  }

  /// Whether the normalized view point (`u`, `v`) lies inside.
  public func contains(u: Double, v: Double) -> Bool {
    u >= x && u < x + width && v >= y && v < y + height
  }
}

/// One video feed shown in a view: its latest frame and its LUTs.
///
/// Hand it frames from any thread (the capture or delivery thread): `submit`
/// swaps one value under a lock held for a pointer store and never waits for
/// the GPU or a renderer. It is a display slot, latest frame wins: a frame
/// replaced before a display tick took it is never drawn. Analysis that must
/// see every frame (scope statistics, recording checks) belongs in the host's
/// own per-frame pipeline, never behind this slot.
public final class MonitorSource: Sendable {
  private struct Slot {
    var frame: MonitorFrame?
    var sequence: UInt64 = 0
  }
  private struct LUTs {
    var burnIn: MonitorLUT?
    var monitor: MonitorLUT?
    var revision: UInt64 = 0
  }

  private let slot = Mutex(Slot())
  private let luts = Mutex(LUTs())

  public init() {}

  /// Makes `frame` the one the next display tick draws. The frame it replaces is
  /// released after the lock (a renderer that drew it keeps its own reference
  /// until its GPU work can have completed).
  public func submit(_ frame: MonitorFrame) {
    let replaced = slot.withLock { s -> MonitorFrame? in
      let old = s.frame
      s.frame = frame
      s.sequence &+= 1
      return old
    }
    _ = replaced
  }

  /// Drops the latest frame: the view shows black for this source.
  public func clear() {
    let replaced = slot.withLock { s -> MonitorFrame? in
      let old = s.frame
      s.frame = nil
      s.sequence &+= 1
      return old
    }
    _ = replaced
  }

  /// Counts `submit` and `clear` calls.
  public var sequence: UInt64 { slot.withLock { $0.sequence } }

  public var latestFrame: MonitorFrame? { slot.withLock { $0.frame } }

  /// The latest frame, if the sequence moved past `seen`.
  func frame(after seen: UInt64) -> (frame: MonitorFrame?, sequence: UInt64)? {
    slot.withLock { s in s.sequence == seen ? nil : (s.frame, s.sequence) }
  }

  /// Applied to this source's output stage and every surface of it (`LUTRouting.burnIn`).
  public var burnInLUT: MonitorLUT? {
    get { luts.withLock { $0.burnIn } }
    set { luts.withLock { $0.burnIn = newValue; $0.revision &+= 1 } }
  }

  /// Applied to the monitor stage of surfaces with `MonitorState.monitorLUT` on
  /// (`LUTRouting.monitorOnly`).
  public var monitorLUT: MonitorLUT? {
    get { luts.withLock { $0.monitor } }
    set { luts.withLock { $0.monitor = newValue; $0.revision &+= 1 } }
  }

  /// Puts `lut` in the slot `routing` names and empties the other, so one LUT is
  /// never applied twice. Nil empties both.
  public func setLUT(_ lut: MonitorLUT?, routing: LUTRouting) {
    luts.withLock {
      $0.burnIn = routing == .burnIn ? lut : nil
      $0.monitor = routing == .monitorOnly ? lut : nil
      $0.revision &+= 1
    }
  }

  /// The LUTs, if they changed since `seen`.
  func luts(after seen: UInt64) -> (burnIn: MonitorLUT?, monitor: MonitorLUT?, revision: UInt64)? {
    luts.withLock { l in l.revision == seen ? nil : (l.burnIn, l.monitor, l.revision) }
  }
}

/// One picture of a source in a view, with its own tool state. Thread-safe:
/// the UI edits `state` and `region`, the renderer publishes `status`, `layout`
/// and `viewport` after drawing.
public final class MonitorSurface: Sendable {
  public let source: MonitorSource

  private struct Shared {
    var state: MonitorState
    var region: MonitorRegion
    var revision: UInt64 = 0
    var status = MonitorStatus()
    var layout: MonitorLayout?
    var viewport: MonitorViewport?
  }
  private let shared: Mutex<Shared>

  public init(source: MonitorSource, state: MonitorState = MonitorState(), region: MonitorRegion = .full) {
    self.source = source
    shared = Mutex(Shared(state: state.normalized(), region: region))
  }

  /// Every tool setting of this surface, stored `normalized()`.
  public var state: MonitorState {
    get { shared.withLock { $0.state } }
    set {
      let next = newValue.normalized()
      shared.withLock {
        guard $0.state != next else { return }
        $0.state = next
        $0.revision &+= 1
      }
    }
  }

  /// Edits the state as one step and normalizes it; returns the stored state.
  /// `body` runs outside the lock and runs again if another thread edited the
  /// surface meanwhile, so no edit is lost and none lands in between.
  @discardableResult
  public func updateState(_ body: (inout MonitorState) -> Void) -> MonitorState {
    while true {
      let (current, revision) = shared.withLock { ($0.state, $0.revision) }
      var next = current
      body(&next)
      next = next.normalized()
      let stored: MonitorState? = shared.withLock { s in
        guard s.revision == revision else { return nil }
        if next != s.state {
          s.state = next
          s.revision &+= 1
        }
        return s.state
      }
      if let stored { return stored }
    }
  }

  /// Where it draws in the view.
  public var region: MonitorRegion {
    get { shared.withLock { $0.region } }
    set {
      shared.withLock {
        guard $0.region != newValue else { return }
        $0.region = newValue
        $0.revision &+= 1
      }
    }
  }

  /// What the last draw showed and why a tool that is on was not drawn.
  public var status: MonitorStatus { shared.withLock { $0.status } }
  /// Where the picture landed in the last draw, in viewport pixels. With the
  /// surface in several views, the last renderer that drew it wrote it; a view's
  /// gestures use their own layout of the current state instead.
  public var layout: MonitorLayout? { shared.withLock { $0.layout } }
  /// The target pixels the last draw covered (of whichever renderer drew last).
  public var viewport: MonitorViewport? { shared.withLock { $0.viewport } }

  func read(after seen: UInt64) -> (state: MonitorState, region: MonitorRegion, revision: UInt64)? {
    shared.withLock { s in s.revision == seen ? nil : (s.state, s.region, s.revision) }
  }

  var revision: UInt64 { shared.withLock { $0.revision } }

  func publish(status: MonitorStatus?, layout: MonitorLayout?, viewport: MonitorViewport?) {
    shared.withLock {
      if let status { $0.status = status }
      $0.layout = layout
      $0.viewport = viewport
    }
  }
}

/// A scope drawn over (or beside) the pictures in a view, from a source's
/// displayed frame. Thread-safe like `MonitorSurface`.
///
/// It accumulates every new frame it displays unless `accumulationInterval`
/// spaces the accumulations out (the host's scope rate). Hidden, it is not drawn
/// but still measured: its `statisticsReader` (clip %, luma extremes) stays live,
/// the statistics-only scope for a readout such as `ClipReadout`.
public final class MonitorScopeOverlay: Sendable {
  public let source: MonitorSource

  private struct Shared {
    var settings: ScopeSettings
    var region: MonitorRegion
    var monitorLUTEnabled: Bool
    var isHidden = false
    var accumulationInterval = 0.0
    var revision: UInt64 = 0
    var graticule: ScopeGraticule?
    var viewport: MonitorViewport?
    var statisticsReader: ScopeStatisticsReader?
  }
  private let shared: Mutex<Shared>

  public init(
    source: MonitorSource, settings: ScopeSettings = ScopeSettings(), region: MonitorRegion = .full,
    monitorLUTEnabled: Bool = true, isHidden: Bool = false, accumulationInterval: Double = 0
  ) {
    self.source = source
    var initial = Shared(settings: settings.normalized(), region: region, monitorLUTEnabled: monitorLUTEnabled)
    initial.isHidden = isHidden
    initial.accumulationInterval = Self.interval(accumulationInterval)
    shared = Mutex(initial)
  }

  static func interval(_ seconds: Double) -> Double { seconds.isFinite ? min(max(seconds, 0), 3600) : 0 }

  /// Not drawn, still accumulated (statistics only). `MonitorScene.clean` hides
  /// every scope too, and stops the accumulation of those not hidden.
  public var isHidden: Bool {
    get { shared.withLock { $0.isHidden } }
    set {
      shared.withLock {
        guard $0.isHidden != newValue else { return }
        $0.isHidden = newValue
        $0.revision &+= 1
      }
    }
  }

  /// The least time between two accumulations, in seconds (0, the default: every
  /// new frame; e.g. 1/30 for 30 Hz scopes of a 60p source). A frame that
  /// arrives sooner is skipped, and the latest one is accumulated once the
  /// interval has passed even if no newer frame comes. Settings and LUT edits
  /// accumulate at once. Overlays accumulated together (one source, one
  /// monitor-LUT choice) follow the shortest interval among them. Clamped to 0…3600.
  public var accumulationInterval: Double {
    get { shared.withLock { $0.accumulationInterval } }
    set {
      let next = Self.interval(newValue)
      shared.withLock {
        guard $0.accumulationInterval != next else { return }
        $0.accumulationInterval = next
        $0.revision &+= 1
      }
    }
  }

  /// The statistics of this scope's accumulations (clip %, luma extremes), for UI
  /// threads, once a renderer has built its accumulator (of the renderer that
  /// built one last, when the overlay is in several views). A reference handoff:
  /// reading it never touches the frame path.
  public var statisticsReader: ScopeStatisticsReader? { shared.withLock { $0.statisticsReader } }

  /// Stored `normalized()`.
  public var settings: ScopeSettings {
    get { shared.withLock { $0.settings } }
    set {
      let next = newValue.normalized()
      shared.withLock {
        guard $0.settings != next else { return }
        $0.settings = next
        $0.revision &+= 1
      }
    }
  }

  public var region: MonitorRegion {
    get { shared.withLock { $0.region } }
    set {
      shared.withLock {
        guard $0.region != newValue else { return }
        $0.region = newValue
        $0.revision &+= 1
      }
    }
  }

  /// Whether a monitor-stage scope applies the source's monitor LUT (pass the
  /// surface's `MonitorState.monitorLUT`, so the scope measures what it shows).
  public var monitorLUTEnabled: Bool {
    get { shared.withLock { $0.monitorLUTEnabled } }
    set {
      shared.withLock {
        guard $0.monitorLUTEnabled != newValue else { return }
        $0.monitorLUTEnabled = newValue
        $0.revision &+= 1
      }
    }
  }

  /// The graticule of the last draw, with its label positions for the UI to draw as text.
  public var graticule: ScopeGraticule? { shared.withLock { $0.graticule } }
  public var viewport: MonitorViewport? { shared.withLock { $0.viewport } }

  struct Edit {
    var settings: ScopeSettings
    var region: MonitorRegion
    var lut: Bool
    var hidden: Bool
    var interval: Double
    var revision: UInt64
  }

  func read(after seen: UInt64) -> Edit? {
    shared.withLock { s in
      s.revision == seen
        ? nil
        : Edit(
          settings: s.settings, region: s.region, lut: s.monitorLUTEnabled, hidden: s.isHidden,
          interval: s.accumulationInterval, revision: s.revision)
    }
  }

  func publish(graticule: ScopeGraticule?, viewport: MonitorViewport?) {
    shared.withLock {
      if let graticule { $0.graticule = graticule }
      $0.viewport = viewport
    }
  }

  func publish(statisticsReader: ScopeStatisticsReader) {
    shared.withLock { $0.statisticsReader = statisticsReader }
  }
}

/// What a view draws: picture surfaces in order (the first clears the target),
/// then scope overlays, all in one output colour. Thread-safe.
public final class MonitorScene: Sendable {
  private struct Shared {
    var surfaces: [MonitorSurface] = []
    var scopes: [MonitorScopeOverlay] = []
    var outputColor = MonitorOutputColor.signalNative
    var headroom = 1.0
    var clean = false
    var revision: UInt64 = 0
  }
  private let shared = Mutex(Shared())

  public init(surfaces: [MonitorSurface] = [], scopes: [MonitorScopeOverlay] = []) {
    shared.withLock {
      $0.surfaces = surfaces
      $0.scopes = scopes
    }
  }

  public var surfaces: [MonitorSurface] {
    get { shared.withLock { $0.surfaces } }
    set { shared.withLock { $0.surfaces = newValue; $0.revision &+= 1 } }
  }

  public var scopes: [MonitorScopeOverlay] {
    get { shared.withLock { $0.scopes } }
    set { shared.withLock { $0.scopes = newValue; $0.revision &+= 1 } }
  }

  /// What the target's values mean. With `signalNative` (the default) the layer is
  /// tagged with the first drawn surface's picture encoding and that surface draws
  /// its signal untouched; every other surface and scope is encoded for that tag.
  /// Its `headroom` is ignored here: see `headroom`.
  public var outputColor: MonitorOutputColor {
    get { shared.withLock { $0.outputColor } }
    set {
      let next = newValue.normalized().withoutHeadroom
      shared.withLock {
        guard $0.outputColor != next else { return }
        $0.outputColor = next
        $0.revision &+= 1
      }
    }
  }

  /// The clean feed: one switch for the whole view. Every surface draws as with
  /// `MonitorState.clean` (no tool, guide, peaking or navigator; LUTs and
  /// geometry stay) and no scope is drawn; scopes not `isHidden` stop
  /// accumulating too, hidden ones keep measuring. The surfaces' own states are
  /// untouched, so turning it off restores them. Text overlays live in the UI
  /// layer: pass it as `MonitorStatusOverlay`'s `clean`.
  public var clean: Bool {
    get { shared.withLock { $0.clean } }
    set {
      shared.withLock {
        guard $0.clean != newValue else { return }
        $0.clean = newValue
        $0.revision &+= 1
      }
    }
  }

  /// The display's EDR headroom for renderers that are given none of their own
  /// (`MonitorRenderer.displayHeadroom`), a uniform of every surface (see
  /// `MonitorDisplayHeadroom`). A `MonitorMetalView` uses its own screen's and
  /// leaves this alone, so one scene can be shown on two screens.
  public var headroom: Double {
    get { shared.withLock { $0.headroom } }
    set {
      let next = MonitorDisplayHeadroom.sanitized(newValue)
      shared.withLock { $0.headroom = next }
    }
  }

  struct Snapshot {
    var surfaces: [MonitorSurface]
    var scopes: [MonitorScopeOverlay]
    var outputColor: MonitorOutputColor
    var headroom: Double
    var clean: Bool
    var revision: UInt64
  }

  /// One consistent read: the arrays are shared (retained), not copied.
  func snapshot() -> Snapshot {
    shared.withLock {
      Snapshot(
        surfaces: $0.surfaces, scopes: $0.scopes, outputColor: $0.outputColor, headroom: $0.headroom, clean: $0.clean,
        revision: $0.revision)
    }
  }

  /// Membership, output colour and clean revision only.
  func revision() -> UInt64 { shared.withLock { $0.revision } }
  func headroomValue() -> Double { shared.withLock { $0.headroom } }
}
