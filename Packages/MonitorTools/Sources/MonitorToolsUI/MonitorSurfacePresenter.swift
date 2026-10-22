import AVFoundation
import AppKit
import MetalKit
import MonitorToolsCore
import MonitorToolsMetal
import SwiftUI

/// Native surfaces retain immutable module-owned results; no capture buffers enter view state.
public final class MonitorSurfacePresenter: ObservableObject, @unchecked Sendable {
  private let lock = NSLock()
  private var latest: MonitorDisplayResult?
  private var lastAcceptedStamp: MonitorFrameStamp?
  private var unavailableReason = "No Signal"
  private var frozen: MonitorDisplayResult?
  private var pendingFreeze = false
  private var clean = false
  private var scheduled = false
  private var lastStatusUpdate = 0.0
  private var statusTimer: Timer?
  private let presentationTarget: MonitorTargetID?
  private let presentationLedger: MonitorAdmissionLedger?
  private let presentationGPUTime: @Sendable (Double, Double) -> Void
  @MainActor private var pictureAllowance: MonitorResourceLease?
  @MainActor private var scopeAllowance: MonitorResourceLease?
  @MainActor private var pictureAllowanceBytes = 0
  @MainActor private var estimatedPictureBytes = 1920 * 1080 * 4 * 2
  @MainActor private var wantsPicture = false
  @MainActor private var wantsScopes = false
  @MainActor public var onPresentationAdmissionChange: ((Bool) -> Void)?
  @MainActor @Published public private(set) var isPresentationAdmitted = true
  @MainActor @Published public private(set) var presentationStatus = ""

  @MainActor @Published public private(set) var status = "No Signal"
  @MainActor @Published public private(set) var detail = ""
  @MainActor @Published public private(set) var isFrozen = false
  @MainActor @Published public private(set) var isFreezePending = false
  @MainActor @Published public private(set) var isClean = false
  @MainActor @Published public private(set) var pictureInterpretation =
    "Range / transfer interpretation unavailable"
  @MainActor @Published public private(set) var scopeTiming = "No scope signal"
  @MainActor @Published public private(set) var scopeInterpretation =
    "Range / transfer interpretation unavailable"
  @MainActor @Published public private(set) var pictureAspectRatio = 16.0 / 9.0
  @MainActor @Published public private(set) var configuration = MonitorConfiguration()
  @MainActor private weak var visibilityView: MonitorVisibilityNSView?
  @MainActor private weak var pictureView: MonitorPictureNSView?
  @MainActor private weak var scopeView: MonitorScopeNSView?
  @MainActor public var onVisibilityChange: ((Bool, Bool) -> Void)?
  @MainActor private var visibility = (presented: false, drawable: false)
  @MainActor private var visibilityReported = false
  @MainActor func reportVisibility(presented: Bool, drawable: Bool) {
    let first = !visibilityReported
    guard first || visibility.presented != presented || visibility.drawable != drawable
    else { return }
    visibilityReported = true
    visibility = (presented, drawable)
    refreshPresentationAdmission()
    // A first "not presented" report arrives before the view reaches its window.
    // Passing it on drops monitor demand, which stops and restarts automatic capture.
    if !(first && !presented && !drawable) { onVisibilityChange?(presented, drawable) }
    present(forceStatus: true)
  }
  public var currentStamp: MonitorFrameStamp? {
    lock.lock()
    defer { lock.unlock() }
    return (frozen ?? latest)?.clean.stamp
  }
  public init(
    target: MonitorTargetID? = nil, presentationLedger: MonitorAdmissionLedger? = nil,
    gpuTiming: @escaping @Sendable (Double, Double) -> Void = { _, _ in }
  ) {
    self.presentationTarget = target.map { _ in MonitorTargetID("surface:\(UUID().uuidString)") }
    self.presentationLedger = presentationLedger
    self.presentationGPUTime = gpuTiming
    DispatchQueue.main.async { [weak self] in
      self?.statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
        [weak self] _ in
        let presenter = self
        DispatchQueue.main.async { presenter?.refreshStatus() }
      }
    }
  }
  deinit { statusTimer?.invalidate() }
  @MainActor private func refreshStatus() {
    refreshPresentationAdmission()
    present(forceStatus: true)
  }
  /// Native compositor costs are conservative estimates, separate from exact owned image storage.
  @MainActor public func setPresentationDemand(picture: Bool, scopes: Bool) {
    wantsPicture = picture
    wantsScopes = scopes
    refreshPresentationAdmission()
  }
  @MainActor func resizePresentationBacking(_ size: CGSize) -> Bool {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      return isPresentationAdmitted
    }
    let width = min(32768, max(1, Int(ceil(size.width))))
    let height = min(32768, max(1, Int(ceil(size.height))))
    let bytes = MonitorPresentationEstimate.pictureBytes(backingWidth: width, backingHeight: height)
    if bytes != estimatedPictureBytes {
      estimatedPictureBytes = bytes
      refreshPresentationAdmission()
    }
    return presentationLedger == nil || pictureAllowance != nil
  }
  @MainActor private func refreshPresentationAdmission() {
    guard let presentationLedger, let presentationTarget else { return }
    let previousPictureAllowance = pictureAllowance
    let previousScopeAllowance = scopeAllowance
    let visible = visibility.presented && visibility.drawable
    let needsPicture = wantsPicture && visible
    let needsScopes = wantsScopes && visible
    if !needsPicture || (pictureAllowance != nil && pictureAllowanceBytes < estimatedPictureBytes) {
      let retired = pictureAllowance
      pictureAllowance = nil
      pictureAllowanceBytes = 0
      pictureView?.clear(retaining: retired)
    }
    if !needsScopes {
      scopeView?.presentationAllowance = nil
      scopeView?.result = nil
      scopeView?.releaseDrawables()
      scopeAllowance = nil
    }
    if needsPicture && pictureAllowance == nil {
      pictureAllowance = presentationLedger.tryAcquire(
        target: presentationTarget, generation: 0,
        kind: .cleanPresentation, bytes: estimatedPictureBytes)
      if pictureAllowance != nil { pictureAllowanceBytes = estimatedPictureBytes }
    }
    if needsScopes && scopeAllowance == nil {
      scopeAllowance = presentationLedger.tryAcquire(
        target: presentationTarget, generation: 0,
        kind: .cleanPresentation, bytes: MonitorPresentationEstimate.scopeBytes)
    }
    let admitted =
      (!needsPicture || pictureAllowance != nil) && (!needsScopes || scopeAllowance != nil)
    if !admitted {
      let retired = pictureAllowance
      pictureAllowance = nil
      pictureAllowanceBytes = 0
      pictureView?.clear(retaining: retired)
      scopeView?.presentationAllowance = nil
      scopeView?.result = nil
      scopeView?.releaseDrawables()
      scopeAllowance = nil
    }
    pictureView?.presentationAllowance = pictureAllowance
    scopeView?.presentationAllowance = scopeAllowance
    if pictureAllowance != nil && pictureAllowance !== previousPictureAllowance {
      pictureView?.needsLayout = true
    }
    if scopeAllowance != nil && scopeAllowance !== previousScopeAllowance {
      scopeView?.needsDisplay = true
    }
    let message =
      admitted
      ? "Additional monitor compositor allowance: \(pictureAllowanceBytes + (scopeAllowance == nil ? 0 : MonitorPresentationEstimate.scopeBytes)) bytes"
      : "Monitor unavailable: presentation memory allowance could not be admitted"
    if presentationStatus != message { presentationStatus = message }
    if isPresentationAdmitted != admitted {
      isPresentationAdmitted = admitted
      if admitted {
        pictureView?.needsLayout = true
        scopeView?.needsDisplay = true
      }
      onPresentationAdmissionChange?(admitted)
    }
  }
  public func accept(_ result: MonitorDisplayResult, ifCurrent: @Sendable () -> Bool = { true }) {
    lock.lock()
    let stamp = result.clean.stamp
    guard ifCurrent(), acceptsInOrder(stamp) else {
      lock.unlock()
      return
    }
    lastAcceptedStamp = stamp
    latest = result
    unavailableReason = "No Signal"
    if pendingFreeze {
      frozen = result
      pendingFreeze = false
    }
    let enqueue = !scheduled
    scheduled = true
    lock.unlock()
    if enqueue { DispatchQueue.main.async { [weak self] in self?.present() } }
  }
  /// Called only while the presentation lock is held; ordering survives display clearing.
  private func acceptsInOrder(_ stamp: MonitorFrameStamp) -> Bool {
    guard let previous = lastAcceptedStamp else { return true }
    guard stamp.target == previous.target, stamp.generation >= previous.generation else {
      return false
    }
    guard stamp.generation == previous.generation else { return true }
    guard stamp.configurationRevision >= previous.configurationRevision,
      stamp.processingRevision >= previous.processingRevision
    else { return false }
    let sameIdentity =
      stamp.configurationRevision == previous.configurationRevision
      && stamp.processingRevision == previous.processingRevision
    return !sameIdentity || stamp.sequence >= previous.sequence
  }
  @MainActor public func setUnavailable(_ reason: String) {
    lock.lock()
    latest = nil
    unavailableReason = reason
    pendingFreeze = false
    let hasFrozen = frozen != nil
    lock.unlock()
    isFreezePending = false
    if !hasFrozen {
      pictureView?.clear()
      scopeView?.result = nil
      status = reason
      detail = reason
    }
  }
  @MainActor public func requestFreezeOnNextFrame() {
    lock.lock()
    latest = nil
    frozen = nil
    pendingFreeze = true
    lock.unlock()
    isFreezePending = true
    isFrozen = false
    status = "Waiting to freeze next picture"
    detail = status
  }
  @MainActor public func cancelPendingFreeze() {
    let wasPending = isFreezePending
    lock.lock()
    pendingFreeze = false
    if wasPending { frozen = nil }
    lock.unlock()
    isFreezePending = false
    present(forceStatus: true)
  }
  @MainActor public func toggleFreeze() {
    lock.lock()
    if frozen != nil {
      frozen = nil
      isFrozen = false
    } else if let latest {
      frozen = latest
      isFrozen = true
    } else {
      detail = "Freeze unavailable: no admitted picture"
    }
    lock.unlock()
    present(forceStatus: true)
  }
  @MainActor public func setClean(_ enabled: Bool) {
    lock.lock()
    clean = enabled
    lock.unlock()
    isClean = enabled
    present(forceStatus: true)
  }
  @MainActor public func toggleClean() { setClean(!isClean) }
  @MainActor public func makeView() -> NSView {
    let view = MonitorPictureNSView()
    view.visibilityChanged = { [weak self, weak view] presented, drawable in
      guard let self, self.visibilityView === view else { return }
      self.reportVisibility(presented: presented, drawable: drawable)
    }
    visibilityView = view
    pictureView = view
    view.presentationAllowance = pictureAllowance
    view.prepareBackingSize = { [weak self] size in self?.resizePresentationBacking(size) ?? false }
    present(forceStatus: true)
    return view
  }
  @MainActor public func makeVisibilityView() -> NSView {
    lock.lock()
    latest = nil
    lock.unlock()
    wantsPicture = false
    wantsScopes = false
    let retiringPicture = pictureAllowance
    pictureAllowance = nil
    pictureAllowanceBytes = 0
    pictureView?.clear(retaining: retiringPicture)
    pictureView = nil
    scopeView?.result = nil
    let view = MonitorVisibilityNSView()
    view.visibilityChanged = { [weak self, weak view] presented, drawable in
      guard let self, self.visibilityView === view else { return }
      self.reportVisibility(presented: presented, drawable: drawable)
    }
    visibilityView = view
    return view
  }
  @MainActor public func makeScopeView() -> NSView {
    let view = MonitorScopeNSView()
    view.requiresAdmission = presentationLedger != nil
    view.presentationAllowance = scopeAllowance
    view.gpuTiming = presentationGPUTime
    scopeView = view
    present(forceStatus: true)
    return view
  }
  private static func describe(_ signal: MonitorFrameSignal?) -> String {
    guard let signal else { return "Range / transfer interpretation unavailable" }
    let range = signal.range == .full ? "Full range" : "Legal range"
    return
      "\(range) · \(signal.transfer.isEmpty ? "unknown transfer" : signal.transfer) · \(signal.matrix.rawValue) matrix"
  }
  @MainActor private func present(forceStatus: Bool = false) {
    lock.lock()
    scheduled = false
    let result = frozen ?? latest
    let clean = clean
    let frozen = frozen != nil
    let unavailableReason = unavailableReason
    let pendingFreeze = pendingFreeze
    lock.unlock()
    isFrozen = frozen
    isFreezePending = pendingFreeze
    let occluded = !frozen && visibilityReported && !visibility.drawable
    if pendingFreeze {
      status = "Waiting to freeze next picture"
      detail = status
      return
    }
    guard let result else {
      pictureView?.clear()
      scopeView?.result = nil
      scopeTiming = "No scope signal"
      if occluded {
        status = visibility.presented ? "Occluded" : "Paused / hidden"
      } else {
        status = unavailableReason
      }
      detail = status
      return
    }
    guard isPresentationAdmitted else {
      status = "Monitor unavailable"
      detail = presentationStatus
      return
    }
    if presentationLedger == nil || pictureAllowance != nil {
      pictureView?.display(clean ? result.clean : (result.decorated ?? result.clean))
    }
    if presentationLedger == nil || scopeAllowance != nil { scopeView?.result = result.scope }
    let now = ProcessInfo.processInfo.systemUptime
    if occluded {
      if forceStatus || now - lastStatusUpdate >= 0.5 {
        lastStatusUpdate = now
        configuration = result.configuration
      }
      status = visibility.presented ? "Occluded" : "Paused / hidden"
      detail = status
      return
    }
    if forceStatus || now - lastStatusUpdate >= 0.5 {
      lastStatusUpdate = now
      configuration = result.configuration
      pictureInterpretation = Self.describe(result.pictureSignal)
      scopeInterpretation = Self.describe(result.scope?.signal)
      let displaySize = CVImageBufferGetDisplaySize(result.clean.pixelBuffer)
      if displaySize.height > 0 { pictureAspectRatio = displaySize.width / displaySize.height }
      let age = max(0, now - result.clean.stamp.hostTime)
      status = frozen ? "Frozen" : age > 0.25 ? "Stale" : "Live"
      // Keep the last picture up. Clearing here erased the clean fallback
      // on the same tick that labeled it Stale.
      detail =
        "Picture PTS \(String(format: "%.3f", result.clean.stamp.sourcePTS)) · \(String(format: "%.1f", age)) s old"
      if let scope = result.scope {
        let scopeAge = max(0, now - scope.stamp.hostTime)
        let scopeState =
          frozen
          ? "Frozen"
          : scopeAge > max(0.25, 3.0 / Double(max(1, result.configuration.scopes.refreshHz)))
            ? "Stale" : "Live"
        scopeTiming =
          "\(scopeState) · Scope PTS \(String(format: "%.3f", scope.stamp.sourcePTS)) · \(String(format: "%.1f", scopeAge)) s old"
        detail += " · Scope PTS \(String(format: "%.3f", scope.stamp.sourcePTS))"
      }
      if result.scope == nil { scopeTiming = "No scope signal" }
      if !result.availability.isEmpty {
        detail += " · " + result.availability.joined(separator: " · ")
      }
    }
  }
}

private final class MonitorWindowObservations: @unchecked Sendable {
  var tokens: [NSObjectProtocol] = []
  func clear() {
    tokens.forEach { NotificationCenter.default.removeObserver($0) }
    tokens = []
  }
  deinit { clear() }
}

@MainActor class MonitorVisibilityNSView: NSView {
  var visibilityChanged: ((Bool, Bool) -> Void)?
  private let windowObservers = MonitorWindowObservations()
  private var closing = false
  override var isHidden: Bool { didSet { reportVisibility() } }
  override func viewDidHide() {
    super.viewDidHide()
    reportVisibility()
  }
  override func viewDidUnhide() {
    super.viewDidUnhide()
    reportVisibility()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowObservers.clear()
    closing = false
    if let window {
      for name in [
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
      ] {
        windowObservers.tokens.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] notification in
            let isClosing = notification.name == NSWindow.willCloseNotification
            MainActor.assumeIsolated {
              if isClosing { self?.closing = true }
              self?.reportVisibility()
            }
          })
      }
    }
    reportVisibility()
  }
  private func reportVisibility() {
    let presented = window != nil && !isHiddenOrHasHiddenAncestor && !closing
    let drawable =
      presented && window?.isVisible == true && window?.isMiniaturized == false
      && window?.occlusionState.contains(.visible) == true
    visibilityChanged?(presented, drawable)
  }
}

@MainActor final class MonitorPictureNSView: MonitorVisibilityNSView {
  private let displayLayer = AVSampleBufferDisplayLayer()
  private(set) var heldFrame: MonitorOwnedFrame?
  var prepareBackingSize: ((CGSize) -> Bool)?
  var presentationAllowance: MonitorResourceLease?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    displayLayer.videoGravity = .resizeAspect
    layer?.addSublayer(displayLayer)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    let scale = window?.backingScaleFactor ?? 2
    guard
      prepareBackingSize?(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        ?? true
    else {
      displayLayer.frame = .zero
      return
    }
    displayLayer.frame = bounds
  }
  func clear(retaining allowance: MonitorResourceLease? = nil) {
    let retiring = allowance ?? presentationAllowance
    presentationAllowance = nil
    displayLayer.sampleBufferRenderer.flush(
      removingDisplayedImage: true, completionHandler: { [retiring] in _ = retiring })
    heldFrame = nil
  }
  func flushIfFailed(_ status: AVQueuedSampleBufferRenderingStatus) {
    guard status == .failed else { return }
    displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    heldFrame = nil
  }
  func display(_ frame: MonitorOwnedFrame) {
    flushIfFailed(displayLayer.sampleBufferRenderer.status)
    guard heldFrame !== frame else { return }
    guard displayLayer.sampleBufferRenderer.isReadyForMoreMediaData else { return }
    var description: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer,
        formatDescriptionOut: &description) == noErr, let description
    else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer,
        formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
      let sample
    else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    displayLayer.sampleBufferRenderer.enqueue(sample)
    heldFrame = frame
  }
}

/// Scope texture is already display-ready. Blitting avoids CPU image readback.
@MainActor final class MonitorScopeNSView: MTKView, MTKViewDelegate {
  var result: MonitorScopeResult? {
    didSet {
      if let texture = result?.texture {
        if device?.registryID != texture.device.registryID {
          device = texture.device
          queue = texture.device.makeCommandQueue()
        }
        drawableSize = CGSize(width: texture.width, height: texture.height)
      }
      needsDisplay = true
    }
  }
  var requiresAdmission = false
  var presentationAllowance: MonitorResourceLease?
  var gpuTiming: @Sendable (Double, Double) -> Void = { _, _ in }
  private var queue: MTLCommandQueue?
  private var inFlight = false
  init() {
    super.init(frame: .zero, device: nil)
    framebufferOnly = false
    autoResizeDrawable = false
    colorPixelFormat = .bgra8Unorm
    isPaused = true
    enableSetNeedsDisplay = true
    delegate = self
    (layer as? CAMetalLayer)?.maximumDrawableCount = 2
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    guard !requiresAdmission || presentationAllowance != nil else { return }
    guard !inFlight, let drawable = currentDrawable, let command = queue?.makeCommandBuffer() else {
      return
    }
    let submitted = result
    let allowance = presentationAllowance
    let timing = gpuTiming
    if let result {
      let texture = result.texture
      guard texture.width == drawable.texture.width, texture.height == drawable.texture.height,
        texture.pixelFormat == drawable.texture.pixelFormat,
        let blit = command.makeBlitCommandEncoder()
      else { return }
      blit.copy(
        from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
        sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
        to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: .init(x: 0, y: 0, z: 0))
      blit.endEncoding()
      command.addCompletedHandler { [result] _ in _ = result }
    } else {
      let descriptor = MTLRenderPassDescriptor()
      descriptor.colorAttachments[0].texture = drawable.texture
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].storeAction = .store
      descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
      guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
      encoder.endEncoding()
    }
    inFlight = true
    command.addCompletedHandler { [weak self, submitted, allowance] command in
      _ = allowance
      if command.gpuEndTime > command.gpuStartTime {
        timing(command.gpuStartTime, command.gpuEndTime)
      }
      let view = self
      DispatchQueue.main.async {
        guard let view else { return }
        view.inFlight = false
        if view.result !== submitted { view.needsDisplay = true }
      }
    }
    command.present(drawable)
    command.commit()
  }
}

public struct MonitorNativePicture: NSViewRepresentable {
  public let presenter: MonitorSurfacePresenter
  public init(presenter: MonitorSurfacePresenter) { self.presenter = presenter }
  public func makeNSView(context: Context) -> NSView { presenter.makeView() }
  public func updateNSView(_ nsView: NSView, context: Context) {}
  public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    (nsView as? MonitorPictureNSView)?.clear()
  }
}
public struct MonitorNativeScope: NSViewRepresentable {
  public let presenter: MonitorSurfacePresenter
  public init(presenter: MonitorSurfacePresenter) { self.presenter = presenter }
  public func makeNSView(context: Context) -> NSView { presenter.makeScopeView() }
  public func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Tracks the existing native preview without acquiring module display resources.
public struct MonitorSurfaceVisibility: NSViewRepresentable {
  public let presenter: MonitorSurfacePresenter
  public init(presenter: MonitorSurfacePresenter) { self.presenter = presenter }
  public func makeNSView(context: Context) -> NSView { presenter.makeVisibilityView() }
  public func updateNSView(_ nsView: NSView, context: Context) {}
}
