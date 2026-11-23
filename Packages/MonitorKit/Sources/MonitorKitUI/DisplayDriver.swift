// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

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
  /// Whether this target needs a draw. An offscreen encode leaves the next
  /// drawable due for presentation even when its dimensions match.
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
  /// latency, 2 (the default) absorbs GPU contention.
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
    self.preferredFrameLatency = preferredFrameLatency.isFinite ? min(2, max(1, preferredFrameLatency)) : 2
    self.preferredFrameRateRange = preferredFrameRateRange
    self.framebufferOnly = framebufferOnly
    self.gesturesEnabled = gesturesEnabled
  }

  /// Configuration is mutable, so validate again where it reaches Core Animation.
  func normalized() -> Self {
    Self(
      maximumDrawableCount: maximumDrawableCount, preferredFrameLatency: preferredFrameLatency,
      preferredFrameRateRange: preferredFrameRateRange, framebufferOnly: framebufferOnly,
      gesturesEnabled: gesturesEnabled)
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
  private var lastOwnEncode: UInt64 = 0
  private var idleMarkerEncode: UInt64 = 0
  /// Both halves of a split draw carry the same index. Caller-owned buffers
  /// can commit in any order, including after newer own-queue buffers.
  private var pendingCommands: [(buffer: MTLCommandBuffer, encode: UInt64, onOwnQueue: Bool)] = []
  /// The last tracked buffer, for diagnostics of split draws.
  var lastTrackedBuffer: MTLCommandBuffer? { pendingCommands.last?.buffer }
  // Only caller-supplied snapshot buffers need an independent completion
  // wakeup. The live display path watches its own queue without a handler.
  private let callerFrames = CallerFrames()
  private lazy var callerCompletion: MTLCommandBufferHandler = { [weak self, callerFrames] _ in
    withExtendedLifetime(callerFrames) {
      guard let self, self.isIdle else { return }
      self.performOnLink { self.releaseIdle() }
    }
  }
  private final class CallerFrames: Sendable {
    let frames = Mutex<[MonitorFrame]>([])
  }
  /// An offscreen encode updated the renderer's key without presenting it.
  private var needsPresentation = false
  /// The scope buffer the last own-queue draw committed after its pictures' (for tests).
  private(set) var lastScopeBuffer: ObjectIdentifier?
  /// Host-driven completions, reported from any thread.
  let completion = MonitorCompletionReporter()
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
    pendingCommands.reserveCapacity(max(8, renderer.engine.framesInFlight * 2))
    if hostEncode == nil { renderer.usesExplicitClassicCompletion = true }
    completion.driver = self
  }

  deinit {
    guard !pendingCommands.isEmpty else { return }
    let frames = renderer.uncompletedClassicFrames()
    guard !frames.isEmpty else { return }
    // Metal retains the textures but does not know about a frame's Core Video
    // backing. The caller's handlers and the queue tail can outlive the view.
    callerFrames.frames.withLock { $0 = frames }
    if let tail = pendingCommands.last(where: {
      guard $0.onOwnQueue else { return false }
      let status = $0.buffer.status
      return status != .completed && status != .error
    })?.buffer {
      // The buffer has already been committed. The background thread only waits.
      nonisolated(unsafe) let committed = tail
      DispatchQueue.global().async {
        withExtendedLifetime(frames) { committed.waitUntilCompleted() }
      }
    }
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
    // An explicit offscreen draw is allowed while paused. It creates new GPU
    // work after the transition to idle, so arrange its completion release too.
    if drawable == nil, isIdle { releaseIdle() }
    report(status: changes.status, graticule: changes.graticule, error: changes.error)
  }

  private func report(status: Bool, graticule: Bool, error: (any Error)?) {
    guard status || graticule || error != nil, let notify else { return }
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
    let error = checkCommandBuffers()
    if isIdle, let queue, !pendingCommands.isEmpty, lastOwnEncode > idleMarkerEncode,
      let marker = queue.makeCommandBuffer() {
      // Wake after outstanding own-queue work. Caller buffers have their own wakeup.
      marker.label = "MonitorKitUI idle marker"
      marker.addCompletedHandler { [weak self] _ in
        guard let driver = self else { return }
        driver.performOnLink { driver.releaseIdle() }
      }
      marker.commit()
      idleMarkerEncode = lastOwnEncode
    }
    if isIdle { renderer.releaseIdleResources() }
    lock.unlock()
    if let error { report(status: false, graticule: false, error: error) }
  }

  /// What the host reported finished, to the renderer.
  private func noteHostCompletion() {
    let done = completion.completedIndex
    if done > 0 { renderer.noteCompleted(through: done) }
  }

  func trackCommandBuffer(_ commandBuffer: MTLCommandBuffer, onOwnQueue: Bool = false) {
    pendingCommands.append((commandBuffer, renderer.encodeCount, onOwnQueue))
  }

  /// The status reader also lets tests exercise independent buffer failures
  /// without deliberately faulting the GPU. Called under the driver's lock.
  @discardableResult
  func checkCommandBuffers(
    status: (MTLCommandBuffer) -> MTLCommandBufferStatus = { $0.status }
  ) -> (any Error)? {
    guard !pendingCommands.isEmpty else { return nil }
    var failure: (any Error)?
    var invalidated = false
    var completedThrough = renderer.encodeCount
    var held = 0
    var i = 0
    while i < pendingCommands.count {
      let (commandBuffer, index, _) = pendingCommands[i]
      let state = status(commandBuffer)
      if state == .error {
        invalidated = true
        if failure == nil { failure = commandBuffer.error }
      } else if state != .completed {
        completedThrough = min(completedThrough, index > 0 ? index - 1 : 0)
        if held != i { pendingCommands[held] = pendingCommands[i] }
        held += 1
      }
      i += 1
    }
    pendingCommands.removeLast(pendingCommands.count - held)
    if invalidated { renderer.invalidateGPUResults() }
    renderer.noteCompleted(through: completedThrough)
    return failure
  }

  /// The tick's work under `lock`; returns whether a status or a graticule changed.
  private func locked(
    drawable: (any CAMetalDrawable)?, texture: MTLTexture, timestamp: CFTimeInterval,
    commandBuffer: MTLCommandBuffer?
  ) -> (status: Bool, graticule: Bool, error: (any Error)?) {
    renderer.pixelsPerPoint = pixelsPerPoint
    renderer.displayHeadroom = headroom
    noteHostCompletion()
    let commandError = checkCommandBuffers()
    do { try renderer.update(width: texture.width, height: texture.height) } catch { return (false, false, error) }
    let needs = (drawable != nil && needsPresentation)
      || renderer.needsDisplay(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
    let wanted = override.withLock { $0 } ?? renderer.layerColor
    if appliedLayerColor != wanted {
      applyLayerColor(wanted)
      // The drawable in hand was vended under the old tag: keep the frame on
      // screen and draw the next one in the new encoding.
      if drawable != nil {
        skips.add(1, ordering: .relaxed)
        renderer.setNeedsDisplay()
        return (false, false, commandError)
      }
    }
    let drew: Bool
    if let hostEncode {
      let context = MonitorDrawableContext(
        drawable: drawable, texture: texture, renderer: renderer, targetPresentationTimestamp: timestamp,
        pixelsPerPoint: pixelsPerPoint, headroom: renderer.headroom, layerColor: wanted, needsDisplay: needs,
        completion: completion)
      drew = hostEncode(context)
    } else {
      drew = (needs || drawable == nil) && draw(texture: texture, drawable: drawable, commandBuffer: commandBuffer)
    }
    if drew {
      needsPresentation = drawable == nil
      draws.add(1, ordering: .relaxed)
    } else {
      skips.add(1, ordering: .relaxed)
    }
    return (renderer.takeStatusChanges(), renderer.takeGraticuleChanges(), commandError)
  }

  /// A drawable on the view's own queue: the pictures in one command buffer,
  /// presented and committed, then the scope accumulations (if any are due) in a
  /// second, so the drawable never waits for them; the scopes show the previous
  /// accumulation until the next tick. Offscreen (nothing is presented) the
  /// scopes are accumulated first, so a snapshot shows its own frame's scopes;
  /// into a caller's buffer, all of it there.
  private func draw(texture: MTLTexture, drawable: (any CAMetalDrawable)?, commandBuffer: MTLCommandBuffer?) -> Bool {
    if let commandBuffer {
      // A throw may follow partial encoding. Track that work as well.
      defer {
        trackCommandBuffer(commandBuffer)
        commandBuffer.addCompletedHandler(callerCompletion)
      }
      do {
        try renderer.encode(target: texture, into: commandBuffer)
      } catch {
        return false
      }
      if let drawable { commandBuffer.present(drawable) }
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
    trackCommandBuffer(cb, onOwnQueue: true)
    lastOwnEncode = renderer.encodeCount
    lastScopeBuffer = nil
    if drawable != nil, renderer.scopesDue, let scopes = queue.makeCommandBuffer() {
      renderer.encodeScopes(into: scopes)
      scopes.commit()
      trackCommandBuffer(scopes, onOwnQueue: true)
      lastScopeBuffer = ObjectIdentifier(scopes)
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
