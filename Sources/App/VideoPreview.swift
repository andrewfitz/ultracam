import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import SwiftUI

// The preview consumes the exact post-pipeline sample sent to the camera. The
// native video renderer performs GPU-backed display conversion and ColorSync;
// no CGImage readback, second LUT, pixel conversion, or SwiftUI frame state.
final class VideoPreviewRenderer: @unchecked Sendable {
  struct Diagnostics: Sendable {
    var received: UInt64 = 0
    var enqueued: UInt64 = 0
    /// Frames superseded by a newer one before the display layer took them.
    /// A display shows the newest frame per refresh; this counts the rest
    /// rather than queueing them behind the screen as latency.
    var late: UInt64 = 0
    var backPressure: UInt64 = 0
    var stagingDrops: UInt64 = 0
    var failed: UInt64 = 0
    var pending = 0
    var lastError: String?
    // Apple's performance counters belong to the renderer's lifetime, including
    // frames displayed before flush. Keep that scope explicit and never combine
    // these with per-run queue counters as though flush reset the native API.
    var rendererFrames: UInt64 = 0
    var rendererDropped: UInt64 = 0
    var rendererCorrupted: UInt64 = 0
#if CAPTURE_LIFECYCLE_TESTS
    var firstStagingMS = 0.0
    var maxStagingMS = 0.0
    var stagingTotalMS = 0.0
    var stagingFrames = 0
    var maxQueueWaitMS = 0.0
    var maxReadinessWaitMS = 0.0
    var firstStagingCPUMS = 0.0
    var maxStagingCPUMS = 0.0
#endif
  }

  @MainActor fileprivate let displayLayer: AVSampleBufferDisplayLayer
  @MainActor private weak var hostingView: VideoPreviewView?
  @MainActor var onVisibilityChange: (() -> Void)?
  // A preview in an open window still requests capture while another app
  // covers it. Rendering itself continues to follow native occlusion below.
  @MainActor private(set) var isPresented = false
  private let videoRenderer: AVSampleBufferVideoRenderer
  private let queue = DispatchQueue(label: "org.ultracam.preview", qos: .userInteractive)
  private let lock = NSLock()
  private var stager = CameraFrameStager()
  private var generation: UInt64 = 0
  private struct QueuedSample {
    let sample: CMSampleBuffer
    let generation: UInt64
#if CAPTURE_LIFECYCLE_TESTS
    let queuedAt = ProcessInfo.processInfo.systemUptime
#endif
  }
  // The newest frame not yet handed to the display layer. A newer frame
  // replaces it (counted late); the preview never builds a queue.
  private var pending: QueuedSample?
  private var scheduledGeneration: UInt64?
  private var visible = false
  private var boundSourceID: String?
  private var metricsPending = false
  private var metricsRequestedAt = -Double.infinity
#if CAPTURE_LIFECYCLE_TESTS
  // Bare command-line XCTest hosts may be classified as occluded by AppKit.
  // This exists only in test builds; production always follows native visibility.
  private var renderWhenUnattached = false
  private var readinessStartedAt = 0.0
  private var enqueuedTimes: [CMTime] = []
  private var nativeFlushNumber: UInt64 = 0
  private var enqueuedFlushNumbers: [UInt64] = []
  private var beforeStagingForTesting: (@Sendable () -> Void)?
#endif
  // Owned only by the preview queue; at most one readiness callback is armed.
  private var requestingGeneration: UInt64?
  private var diagnostics = Diagnostics()

  @MainActor init() {
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = NSColor.black.cgColor
    displayLayer = layer
    videoRenderer = layer.sampleBufferRenderer
  }

#if CAPTURE_LIFECYCLE_TESTS
  @MainActor convenience init(renderWhenUnattached: Bool) {
    self.init()
    self.renderWhenUnattached = renderWhenUnattached
    visible = renderWhenUnattached
  }

  func setVisibilityForTesting(_ value: Bool) { setVisible(value) }
  func enqueuedTimesForTesting() -> [CMTime] { lock.withLock { enqueuedTimes } }
  func enqueuedFlushNumbersForTesting() -> [UInt64] { lock.withLock { enqueuedFlushNumbers } }
  func blockQueueForTesting(entered: DispatchSemaphore, release: DispatchSemaphore) {
    queue.async {
      entered.signal()
      _ = release.wait(timeout: .now() + 2)
    }
  }
  func blockNextStagingForTesting(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock {
      beforeStagingForTesting = {
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
      }
    }
  }
#endif

  deinit {
    // Every executing queue/callback method holds self strongly. Deinit can
    // therefore stop the remaining weak callback without concurrent rendering.
    videoRenderer.stopRequestingMediaData()
  }

  // Capture can check demand without visiting AppKit or dispatching to the main
  // thread for every frame. The owning view publishes visibility on UI events.
  var isVisible: Bool { lock.withLock { visible } }

  // At most one frame waits for the display layer, plus at most one in the
  // executing work item. Latency stays one frame, whatever the display does.
  func bindSource(_ sourceID: String) {
    lock.withLock {
      guard boundSourceID != sourceID else { return }
      boundSourceID = sourceID
      flushLocked(resetDiagnostics: true)
    }
  }

  func enqueue(_ sample: CMSampleBuffer, sourceID: String? = nil) {
    lock.withLock {
      guard visible else { return }
      if let boundSourceID, sourceID != boundSourceID { return }
      diagnostics.received &+= 1
      if pending != nil { diagnostics.late &+= 1 }
      pending = QueuedSample(sample: sample, generation: generation)
      guard scheduledGeneration != generation else { return }
      scheduleDrainLocked(generation: generation)
    }
  }

  func flush() {
    lock.withLock {
      flushLocked(resetDiagnostics: true)
    }
  }

  @MainActor fileprivate func ownsView(_ view: VideoPreviewView) -> Bool { hostingView === view }

  @MainActor fileprivate func publishViewVisibility(_ value: Bool, from view: VideoPreviewView,
    presented: Bool? = nil) {
    guard ownsView(view) else { return }
#if CAPTURE_LIFECYCLE_TESTS
    guard !renderWhenUnattached else { return }
#endif
    let nextPresented = presented ?? (view.window?.isVisible == true && view.window?.isMiniaturized == false
      && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty)
    let presentationChanged = nextPresented != isPresented
    isPresented = nextPresented
    let visibilityChanged = setVisible(value)
    if presentationChanged || visibilityChanged { onVisibilityChange?() }
  }

  @discardableResult private func setVisible(_ value: Bool) -> Bool {
    lock.withLock {
      guard visible != value else { return false }
      visible = value
      if !value { flushLocked(resetDiagnostics: false) }
      return true
    }
  }

  // Caller holds lock so invalidation/flush is ordered before a reappearing
  // view's first enqueue. Hidden views release pending/native images promptly.
  private func flushLocked(resetDiagnostics: Bool) {
    generation &+= 1
    pending = nil
    scheduledGeneration = nil
    let token = generation
    if resetDiagnostics {
      let lifetime = (diagnostics.rendererFrames, diagnostics.rendererDropped, diagnostics.rendererCorrupted)
      diagnostics = Diagnostics()
#if CAPTURE_LIFECYCLE_TESTS
      enqueuedTimes.removeAll(keepingCapacity: true)
      enqueuedFlushNumbers.removeAll(keepingCapacity: true)
#endif
      (diagnostics.rendererFrames, diagnostics.rendererDropped, diagnostics.rendererCorrupted) = lifetime
    }
    // Queue insertion under the same lock orders the flush before any new
    // generation's enqueue. Stale work cannot redisplay a stopped frame.
    queue.async { [weak self] in
      guard let self else { return }
      if self.requestingGeneration != nil {
        self.videoRenderer.stopRequestingMediaData()
        self.requestingGeneration = nil
      }
      self.videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
#if CAPTURE_LIFECYCLE_TESTS
      self.lock.withLock { self.nativeFlushNumber &+= 1 }
#endif
      self.stager = CameraFrameStager()
      self.lock.withLock {
        guard token == self.generation, self.pending != nil,
          self.scheduledGeneration != token else { return }
        self.scheduleDrainLocked(generation: token)
      }
    }
  }

  func diagnosticsSnapshot() -> Diagnostics {
    lock.withLock {
      var result = diagnostics
      result.pending = pending == nil ? 0 : 1
      return result
    }
  }

  @MainActor func makeView() -> VideoPreviewView {
    let view = VideoPreviewView(renderer: self, displayLayer: displayLayer)
    hostingView = view
    let wasPresented = isPresented
    isPresented = false
#if CAPTURE_LIFECYCLE_TESTS
    if !renderWhenUnattached {
      let wasVisible = setVisible(false)
      if wasPresented || wasVisible { onVisibilityChange?() }
    }
#else
    let wasVisible = setVisible(false)
    if wasPresented || wasVisible { onVisibilityChange?() }
#endif
    return view
  }

  func loadPerformanceMetrics(_ completion: @escaping @Sendable (AVVideoPerformanceMetrics?) -> Void) {
    videoRenderer.loadVideoPerformanceMetrics(completionHandler: completion)
  }

  func refreshPerformanceMetrics() {
    let now = ProcessInfo.processInfo.systemUptime
    let token = lock.withLock { () -> UInt64? in
      guard visible, !metricsPending, now - metricsRequestedAt >= 1 else { return nil }
      metricsPending = true
      metricsRequestedAt = now
      return generation
    }
    guard let token else { return }
    videoRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
      guard let self else { return }
      self.lock.withLock {
        self.metricsPending = false
        guard token == self.generation, let metrics else { return }
        self.diagnostics.rendererFrames = UInt64(max(0, metrics.totalNumberOfFrames))
        self.diagnostics.rendererDropped = UInt64(max(0, metrics.numberOfDroppedFrames))
        self.diagnostics.rendererCorrupted = UInt64(max(0, metrics.numberOfCorruptedFrames))
      }
    }
  }

  private func scheduleDrainLocked(generation token: UInt64) {
    scheduledGeneration = token
    queue.async { [weak self] in self?.drainOne(generation: token) }
  }

  private func drainOne(generation token: UInt64) {
    let next = lock.withLock { () -> QueuedSample? in
      // A queued drain from before flush must never steal the new generation's
      // samples and enqueue them ahead of the queued native flush operation.
      guard token == generation, scheduledGeneration == token else { return nil }
      let next = pending
      pending = nil
#if CAPTURE_LIFECYCLE_TESTS
      if let next {
        diagnostics.maxQueueWaitMS = max(diagnostics.maxQueueWaitMS,
          (ProcessInfo.processInfo.systemUptime - next.queuedAt) * 1000)
      }
#endif
      return next
    }
    if let next, !render(next) { return }
    lock.withLock {
      guard token == generation, scheduledGeneration == token else { return }
      if pending == nil { scheduledGeneration = nil }
      else { scheduleDrainLocked(generation: token) }
    }
  }

  // false means a readiness callback owns resumption; never spin on readiness.
  private func render(_ queued: QueuedSample) -> Bool {
    let sample = queued.sample, token = queued.generation
    guard lock.withLock({ visible && token == generation }) else { return true }
    if videoRenderer.status == .failed || videoRenderer.requiresFlushToResumeDecoding {
      let error = videoRenderer.error?.localizedDescription ?? "Preview renderer required a reset."
      recordFailure(error, generation: token)
      videoRenderer.flush()
    }
    guard videoRenderer.isReadyForMoreMediaData else {
      let current = lock.withLock { () -> Bool in
        guard visible && token == generation else { return false }
        diagnostics.backPressure &+= 1
        // Keep this frame for the display unless a newer one already waits.
        if pending == nil { pending = queued } else { diagnostics.late &+= 1 }
        return true
      }
      guard current else { return true }
      if requestingGeneration != token {
        if requestingGeneration != nil { videoRenderer.stopRequestingMediaData() }
        requestingGeneration = token
#if CAPTURE_LIFECYCLE_TESTS
        readinessStartedAt = ProcessInfo.processInfo.systemUptime
#endif
        videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in
          guard let self, self.requestingGeneration == token else { return }
#if CAPTURE_LIFECYCLE_TESTS
          self.lock.withLock {
            guard self.visible && token == self.generation else { return }
            self.diagnostics.maxReadinessWaitMS = max(self.diagnostics.maxReadinessWaitMS,
              (ProcessInfo.processInfo.systemUptime - self.readinessStartedAt) * 1000)
          }
#endif
          self.videoRenderer.stopRequestingMediaData()
          self.requestingGeneration = nil
          self.drainOne(generation: token)
        }
      }
      return false
    }
    do {
      // Preview frames are the capture or processor IOSurfaces; staging only checks that.
#if CAPTURE_LIFECYCLE_TESTS
      let beforeStaging = lock.withLock { () -> (@Sendable () -> Void)? in
        let result = beforeStagingForTesting
        beforeStagingForTesting = nil
        return result
      }
      beforeStaging?()
      let stagingStarted = ProcessInfo.processInfo.systemUptime
      let stagingCPUStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
#endif
      let staged = try stager.stage(sample)
#if CAPTURE_LIFECYCLE_TESTS
      let stagingMS = (ProcessInfo.processInfo.systemUptime - stagingStarted) * 1000
      let stagingCPUMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - stagingCPUStarted) / 1_000_000
      lock.withLock {
        guard visible && token == generation else { return }
        if diagnostics.stagingFrames == 0 {
          diagnostics.firstStagingMS = stagingMS
          diagnostics.firstStagingCPUMS = stagingCPUMS
        }
        diagnostics.maxStagingCPUMS = max(diagnostics.maxStagingCPUMS, stagingCPUMS)
        diagnostics.maxStagingMS = max(diagnostics.maxStagingMS, stagingMS)
        diagnostics.stagingTotalMS += stagingMS
        diagnostics.stagingFrames += 1
      }
#endif
      guard CMSampleBufferGetImageBuffer(staged) != nil,
        CMSampleBufferGetFormatDescription(staged) != nil, CMSampleBufferDataIsReady(staged) else {
        throw VideoError.message("Preview sample has no ready video image.")
      }
      var preview: CMSampleBuffer?
      // Retain the existing image/format pairing rather than reconstructing it.
      // Shared native image consumers can add color metadata after the source
      // sample was created; revalidation then intermittently rejects that valid
      // original sample with InvalidMediaFormat. Copying the sample preserves
      // its original format and timing without copying pixels, while providing
      // independent per-sample attachment dictionaries for preview scheduling.
      let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
        sampleBuffer: staged, sampleBufferOut: &preview)
      guard status == noErr, let preview else { throw VideoError.message("Cannot copy preview sample (\(status)).") }
      // Independent sample attachments leave the camera's original sample and
      // media timing untouched. A live preview always shows the newest image.
      guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
        preview, createIfNecessary: true), CFArrayGetCount(attachmentArray) > 0 else {
        throw VideoError.message("Preview sample attachments are unavailable.")
      }
      let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachmentArray, 0),
        to: CFMutableDictionary.self)
      CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
      lock.withLock {
        guard visible && token == generation else { return }
        videoRenderer.enqueue(preview)
        diagnostics.enqueued &+= 1
        diagnostics.lastError = nil
#if CAPTURE_LIFECYCLE_TESTS
        if enqueuedTimes.count == 64 {
          enqueuedTimes.removeFirst()
          enqueuedFlushNumbers.removeFirst()
        }
        enqueuedTimes.append(CMSampleBufferGetPresentationTimeStamp(preview))
        enqueuedFlushNumbers.append(nativeFlushNumber)
#endif
      }
    } catch {
      recordFailure(error.localizedDescription, generation: token)
    }
    return true
  }

  private func recordFailure(_ message: String, generation token: UInt64) {
    lock.withLock {
      guard visible && token == generation else { return }
      diagnostics.failed &+= 1
      diagnostics.lastError = message
    }
  }
}

struct VideoPreview: NSViewRepresentable {
  let renderer: VideoPreviewRenderer

  func makeNSView(context: Context) -> VideoPreviewView {
    renderer.makeView()
  }

  func updateNSView(_ nsView: VideoPreviewView, context: Context) {}
}

@MainActor final class VideoPreviewView: NSView {
  private let renderer: VideoPreviewRenderer
  private let displayLayer: AVSampleBufferDisplayLayer

  init(renderer: VideoPreviewRenderer, displayLayer: AVSampleBufferDisplayLayer) {
    self.renderer = renderer
    self.displayLayer = displayLayer
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.masksToBounds = true
    displayLayer.masksToBounds = true
    layer?.addSublayer(displayLayer)
  }

  required init?(coder: NSCoder) { nil }

  deinit { NotificationCenter.default.removeObserver(self) }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: nil)
    if let window {
      NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
        name: NSWindow.didChangeOcclusionStateNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
        name: NSWindow.willCloseNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
        name: NSWindow.didMiniaturizeNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
        name: NSWindow.didDeminiaturizeNotification, object: window)
    }
    publishVisibility()
  }

  override func viewDidHide() {
    super.viewDidHide()
    publishVisibility()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    publishVisibility()
  }

  @objc private func windowVisibilityChanged(_ notification: Notification) {
    if notification.name == NSWindow.willCloseNotification {
      renderer.publishViewVisibility(false, from: self, presented: false)
    }
    else { publishVisibility() }
  }

  private func publishVisibility() {
    renderer.publishViewVisibility(window?.isVisible == true && window?.occlusionState.contains(.visible) == true
      && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty, from: self)
  }

#if CAPTURE_LIFECYCLE_TESTS
  func publishVisibilityForTesting(_ value: Bool) { renderer.publishViewVisibility(value, from: self) }
#endif

  override func layout() {
    super.layout()
    guard renderer.ownsView(self), displayLayer.superlayer === layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
    publishVisibility()
  }
}
