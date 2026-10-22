import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import QuartzCore
import Synchronization

/// What a host-driven view hands the host each display tick. Valid only inside
/// the call, on the display link's thread.
public struct MonitorDrawableContext {
  /// The drawable to present (nil for an offscreen draw).
  public let drawable: (any CAMetalDrawable)?
  /// The texture to draw into: the drawable's, or the offscreen target.
  public let texture: MTLTexture
  /// The view's scene renderer, for a host that draws the scene into its own
  /// command buffer (`renderer.encode(target:into:)`, classic or Metal 4).
  public let renderer: MonitorRenderer
  /// When the drawable reaches the glass (`CAMetalDisplayLink.Update`), 0 offscreen.
  public let targetPresentationTimestamp: CFTimeInterval
  public let pixelsPerPoint: Double
  /// The EDR headroom now (the view's screen's); already in the renderer's output colour.
  public let headroom: Double
  /// What the layer is tagged with: the view's `layerColorOverride`, else what the
  /// renderer resolved from the scene.
  public let layerColor: MonitorLayerColor
  /// Whether the scene changed since the renderer last encoded. A host that
  /// draws only the scene can return false when it is not.
  public let needsDisplay: Bool
  /// Where the host reports its finished GPU work, from any thread.
  public let completion: MonitorCompletionReporter

  /// `region` of this target in pixels.
  public func viewport(_ region: MonitorRegion = .full) -> MonitorViewport? {
    region.viewport(width: texture.width, height: texture.height, pixelsPerPoint: pixelsPerPoint)
  }
}

/// Reports a host-driven view's finished GPU work to its renderer from any
/// thread: a classic host passes the `renderer.encodeCount` read right after its
/// encode, a Metal 4 host the submission's index (or its queue's completed
/// index). Only ever larger values count. Taken by the next tick, or soon after
/// on the link's thread while the view is paused or hidden, so the frames its
/// last draws held are released without another tick. Allocates nothing while
/// the view draws; callable inside the tick too.
public final class MonitorCompletionReporter: @unchecked Sendable {
  private let reported = Atomic<UInt64>(0)
  /// Set once by the driver, before the reporter is shared; weak loads are thread-safe.
  weak var driver: MonitorDisplayDriver?

  init() {}

  /// The GPU finished the encodes (classic) or submissions (Metal 4) up to `index`.
  public func noteCompleted(through index: UInt64) {
    let before = reported.max(index, ordering: .relaxed).oldValue
    guard index > before, let driver, driver.isIdle else { return }
    // Always queued: a report from inside a tick must not re-enter its lock.
    MonitorDisplayDriver.perform(on: driver.linkRunLoop) { [weak driver] in driver?.releaseIdle() }
  }

  /// The largest index reported so far (0: none).
  public var completedIndex: UInt64 { reported.load(ordering: .relaxed) }
}

/// How a `MonitorMetalView` gets its pictures drawn.
public enum MonitorMetalViewMode {
  /// The view draws its scene on `queue` (one is created only if nil) and presents.
  case convenience(queue: MTLCommandQueue?)
  /// The host encodes into its own queue (classic or Metal 4) on the display
  /// link's thread and presents the drawable itself. Return true when it drew.
  /// The view adds no copy and no command buffer. The closure runs inside the
  /// tick, on the link's thread (so it is `@Sendable`): it must not call the
  /// view's `drawOffscreen`. A host drawing the scene reports finished GPU work
  /// with `context.completion.noteCompleted(through:)` from any thread (its
  /// completion handler or shared-event listener): replaced frames are then
  /// released at once rather than a few encodes later, and a paused or hidden
  /// view releases its last frames when that work completes.
  case hostDriven(@Sendable (MonitorDrawableContext) -> Bool)
}

/// Display-link settings. The defaults favour steady pacing on a shared GPU;
/// see each property for the lowest-latency choice.
public struct MonitorMetalViewConfiguration: Sendable {
  /// `CAMetalLayer.maximumDrawableCount`, 2 or 3. Three (the default) leaves a
  /// drawable free while two are queued for the glass, so a frame that runs
  /// long costs a refresh, not a stall. Two is the lowest latency but needs
  /// every frame done within one refresh.
  public var maximumDrawableCount: Int
  /// `CAMetalDisplayLink.preferredFrameLatency` in refreshes, 1 or 2. The link
  /// vends a drawable this many refreshes before it is shown: 1 is the lowest
  /// latency, 2 (the default, as Ultracam uses) absorbs GPU contention.
  public var preferredFrameLatency: Float
  public var preferredFrameRateRange: CAFrameRateRange
  /// `CAMetalLayer.framebufferOnly`. True suits render passes (the scene, the
  /// convenience mode); a host writing the drawable from a compute kernel
  /// (`MonitorPass.encodeCompute`) needs false.
  public var framebufferOnly: Bool
  /// Pinch and scroll magnify, drag pans, double click toggles pixel-exact.
  public var gesturesEnabled: Bool

  public init(
    maximumDrawableCount: Int = 3, preferredFrameLatency: Float = 2,
    preferredFrameRateRange: CAFrameRateRange = .default, framebufferOnly: Bool = true, gesturesEnabled: Bool = true
  ) {
    self.maximumDrawableCount = min(3, max(2, maximumDrawableCount))
    self.preferredFrameLatency = min(2, max(1, preferredFrameLatency))
    self.preferredFrameRateRange = preferredFrameRateRange
    self.framebufferOnly = framebufferOnly
    self.gesturesEnabled = gesturesEnabled
  }
}

/// The display link's delegate. Everything here runs on the link's run loop
/// thread (or the main thread for an offscreen draw), one tick at a time under
/// `lock`, so the confined renderer is never entered twice.
///
/// `presentsWithTransaction` stays false: the drawable is presented as soon as
/// its GPU work is scheduled, not with the next Core Animation commit, which
/// would add up to a frame of latency and tie presentation to the main thread.
final class MonitorDisplayDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
  let renderer: MonitorRenderer
  let layer: CAMetalLayer
  private let queue: MTLCommandQueue?
  private let hostEncode: (@Sendable (MonitorDrawableContext) -> Bool)?
  /// The link's run loop (thread-safe to perform on and wake).
  nonisolated(unsafe) let linkRunLoop: CFRunLoop
  private let linkIsMain: Bool
  /// Convenience mode: one committed command buffer watched through `status`,
  /// with the renderer's encode it carried (the last buffer of that encode).
  /// Buffers of a queue complete in commit order, so once it completed every
  /// earlier encode has too: replaced frames go a frame or two after their GPU
  /// work, with no handler, event or allocation per frame, and no more than one
  /// buffer held back from Metal's reuse.
  private(set) var probe: MTLCommandBuffer?
  private var probeEncode: UInt64 = 0
  /// The probe is an idle marker, whose completion handler releases again.
  private var probeIsMarker = false
  /// The last encode a completed probe vouched for.
  private var vouched: UInt64 = 0
  /// The scope buffer the last own-queue draw committed after its pictures' (for tests).
  private(set) var lastScopeBuffer: ObjectIdentifier?
  /// Host-driven completions, reported from any thread.
  let completion = MonitorCompletionReporter()
  /// An encode into a caller's command buffer (`drawOffscreen`) the probe cannot
  /// vouch for: completions are reported below it until the renderer's own
  /// window has passed it.
  private var unvouched: UInt64 = 0
  private let lock = NSLock()
  private var appliedLayerColor: MonitorLayerColor?
  /// A host-driven view's own tag, instead of the scene's.
  private let override = Mutex<MonitorLayerColor?>(nil)
  /// Called on the main thread when a surface's status or a scope's graticule
  /// changes, or the renderer recorded an error.
  nonisolated(unsafe) var notify: (@MainActor (_ status: Bool, _ graticule: Bool, _ error: (any Error)?) -> Void)?
  /// Target pixels per point, from the view.
  private let scale = AtomicDouble(1)
  /// The view's screen headroom (NaN: none yet, the scene's applies).
  private let screenHeadroom = AtomicDouble(.nan)
  /// Whether the view is paused or not visible: idle releases then drop frames too.
  private let idle = Atomic<Bool>(false)
  private var reportedErrors: UInt64 = 0

  /// Written on the link's thread, read from the main thread.
  private let draws = Atomic<Int>(0)
  private let skips = Atomic<Int>(0)
  private let layerTags = Atomic<Int>(0)
  var drawCount: Int { draws.load(ordering: .relaxed) }
  var skippedCount: Int { skips.load(ordering: .relaxed) }
  var layerChanges: Int { layerTags.load(ordering: .relaxed) }

  init(renderer: MonitorRenderer, layer: CAMetalLayer, mode: MonitorMetalViewMode, runLoop: RunLoop = .main) {
    self.renderer = renderer
    self.layer = layer
    linkIsMain = runLoop === RunLoop.main
    linkRunLoop = runLoop.getCFRunLoop()
    switch mode {
    case .convenience(let queue):
      if let queue {
        self.queue = queue
      } else {
        let own = renderer.engine.device.makeCommandQueue()
        own?.label = "MonitorKitUI"
        self.queue = own
      }
      hostEncode = nil
    case .hostDriven(let encode):
      self.queue = nil
      hostEncode = encode
    }
    super.init()
    completion.driver = self
  }

  /// Runs `body` on the link's run loop: now when called there on the main
  /// thread, else queued and the run loop woken (CFRunLoop's perform and wake-up
  /// are thread-safe; RunLoop's `perform` is neither, nor does it wake a run loop
  /// parked on a port).
  func performOnLink(_ body: @escaping @Sendable () -> Void) {
    if linkIsMain && Thread.isMainThread {
      body()
    } else {
      Self.perform(on: linkRunLoop, body)
    }
  }

  static func perform(on runLoop: CFRunLoop, _ body: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, body)
    CFRunLoopWakeUp(runLoop)
  }

  var pixelsPerPoint: Double {
    get { scale.load() }
    set { scale.store(newValue) }
  }

  var commandQueue: MTLCommandQueue? { queue }

  var headroom: Double? {
    get {
      let h = screenHeadroom.load()
      return h.isNaN ? nil : h
    }
    set { screenHeadroom.store(newValue ?? .nan) }
  }

  var isIdle: Bool {
    get { idle.load(ordering: .relaxed) }
    set { idle.store(newValue, ordering: .relaxed) }
  }

  var layerColorOverride: MonitorLayerColor? {
    get { override.withLock { $0 } }
    set { override.withLock { $0 = newValue } }
  }

  /// The layer starts tagged as `color` (the view applies it at init).
  func noteApplied(_ color: MonitorLayerColor) { lock.withLock { appliedLayerColor = color } }

  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    tick(drawable: update.drawable, texture: update.drawable.texture, timestamp: update.targetPresentationTimestamp,
         commandBuffer: nil)
  }

  /// One tick. With `drawable` nil it draws offscreen into `texture`, into
  /// `commandBuffer` when given (else its own, committed).
  func tick(
    drawable: (any CAMetalDrawable)?, texture: MTLTexture, timestamp: CFTimeInterval,
    commandBuffer: MTLCommandBuffer?
  ) {
    lock.lock()
    var changes = locked(drawable: drawable, texture: texture, timestamp: timestamp, commandBuffer: commandBuffer)
    if renderer.errorCount != reportedErrors {
      reportedErrors = renderer.errorCount
      changes.error = renderer.lastError
    }
    lock.unlock()
    guard changes.status || changes.graticule || changes.error != nil, let notify else { return }
    let status = changes.status, graticule = changes.graticule
    let error = changes.error
    if Thread.isMainThread {
      MainActor.assumeIsolated { notify(status, graticule, error) }
    } else {
      DispatchQueue.main.async { notify(status, graticule, error) }
    }
  }

  /// Releases what finished GPU work held; while the view is idle (paused or not
  /// visible) each source's frame too, so no host buffer stays pinned. Runs on
  /// the link's run loop, under the tick's lock. While an encode is not yet known
  /// to be complete, a convenience view commits one empty marker buffer whose
  /// completion handler runs this again (one closure per pause, never per
  /// frame), however long the GPU is busy; a host-driven view runs it again on
  /// each completion it reports.
  func releaseIdle() {
    lock.lock()
    noteHostCompletion()
    noteCompletion()
    if isIdle, let queue, !probeIsMarker, renderer.encodeCount > vouched, let marker = queue.makeCommandBuffer() {
      // An empty buffer after the last frame: once it completes, every encode has.
      marker.label = "MonitorKitUI idle marker"
      marker.addCompletedHandler { [weak self] _ in
        guard let driver = self else { return }
        driver.performOnLink { driver.releaseIdle() }
      }
      marker.commit()
      probe = marker
      probeEncode = renderer.encodeCount
      probeIsMarker = true
    }
    if isIdle { renderer.releaseIdleResources() }
    lock.unlock()
  }

  /// What the host reported finished, to the renderer.
  private func noteHostCompletion() {
    let done = completion.completedIndex
    if done > 0 { renderer.noteCompleted(through: done) }
  }

  /// The encodes the view's completed command buffers vouch for, to the renderer.
  private func noteCompletion() {
    guard let cb = probe else { return }
    let status = cb.status
    guard status == .completed || status == .error else { return }
    probe = nil
    probeIsMarker = false
    vouched = probeEncode
    var done = probeEncode
    if unvouched > 0 {
      let window = UInt64(max(3, renderer.engine.framesInFlight))
      if renderer.encodeCount >= unvouched &+ window {
        unvouched = 0
      } else {
        done = min(done, unvouched - 1)
      }
    }
    renderer.noteCompleted(through: done)
  }

  /// The tick's work under `lock`; returns whether a status or a graticule changed.
  private func locked(
    drawable: (any CAMetalDrawable)?, texture: MTLTexture, timestamp: CFTimeInterval,
    commandBuffer: MTLCommandBuffer?
  ) -> (status: Bool, graticule: Bool, error: (any Error)?) {
    renderer.pixelsPerPoint = pixelsPerPoint
    renderer.displayHeadroom = headroom
    noteHostCompletion()
    noteCompletion()
    do { try renderer.update() } catch { return (false, false, error) }
    let wanted = override.withLock { $0 } ?? renderer.layerColor
    if appliedLayerColor != wanted {
      applyLayerColor(wanted)
      // The drawable in hand was vended under the old tag: keep the frame on
      // screen and draw the next one in the new encoding.
      if drawable != nil {
        skips.add(1, ordering: .relaxed)
        renderer.setNeedsDisplay()
        return (false, false, nil)
      }
    }
    let needs = renderer.needsDisplay(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
    if let hostEncode {
      let context = MonitorDrawableContext(
        drawable: drawable, texture: texture, renderer: renderer, targetPresentationTimestamp: timestamp,
        pixelsPerPoint: pixelsPerPoint, headroom: renderer.headroom, layerColor: wanted, needsDisplay: needs,
        completion: completion)
      if hostEncode(context) { draws.add(1, ordering: .relaxed) } else { skips.add(1, ordering: .relaxed) }
    } else if (needs || drawable == nil) && draw(texture: texture, drawable: drawable, commandBuffer: commandBuffer) {
      draws.add(1, ordering: .relaxed)
    } else {
      skips.add(1, ordering: .relaxed)
    }
    return (renderer.takeStatusChanges(), renderer.takeGraticuleChanges(), nil)
  }

  /// A drawable on the view's own queue: the pictures in one command buffer,
  /// presented and committed, then the scope accumulations (if any are due) in a
  /// second, so the drawable never waits for them; the scopes show the previous
  /// accumulation until the next tick. Offscreen (nothing is presented) the
  /// scopes are accumulated first, so a snapshot shows its own frame's scopes;
  /// into a caller's buffer, all of it there.
  private func draw(texture: MTLTexture, drawable: (any CAMetalDrawable)?, commandBuffer: MTLCommandBuffer?) -> Bool {
    if let commandBuffer {
      do {
        try renderer.encode(target: texture, into: commandBuffer)
      } catch {
        return false
      }
      if let drawable { commandBuffer.present(drawable) }
      unvouched = renderer.encodeCount
      return true
    }
    guard let queue, let cb = queue.makeCommandBuffer() else { return false }
    var drew = true
    do {
      if let drawable {
        try renderer.encodePictures(target: texture, into: cb)
        cb.present(drawable)
      } else {
        try renderer.encode(target: texture, into: cb)
      }
    } catch {
      // What was encoded before the failure still runs; the drawable is not presented.
      drew = false
    }
    cb.commit()
    var last = cb
    lastScopeBuffer = nil
    if drawable != nil, renderer.scopesDue, let scopes = queue.makeCommandBuffer() {
      renderer.encodeScopes(into: scopes)
      scopes.commit()
      last = scopes
      lastScopeBuffer = ObjectIdentifier(scopes)
    }
    // The last buffer of the encode: the scope buffer reads its frames too.
    if probe == nil {
      probe = last
      probeEncode = renderer.encodeCount
    }
    return drew
  }

  private func applyLayerColor(_ color: MonitorLayerColor) {
    let main = Thread.isMainThread
    if !main {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
    }
    color.apply(to: layer)
    if !main { CATransaction.commit() }
    appliedLayerColor = color
    layerTags.add(1, ordering: .relaxed)
  }
}

/// A Double shared between the main thread and the display link's thread.
final class AtomicDouble: Sendable {
  private let bits: Atomic<UInt64>
  init(_ value: Double) { bits = Atomic(value.bitPattern) }
  func load() -> Double { Double(bitPattern: bits.load(ordering: .relaxed)) }
  func store(_ value: Double) { bits.store(value.bitPattern, ordering: .relaxed) }
}
