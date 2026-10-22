import CoreVideo
import CoreMedia
import Foundation
import os
import MonitorToolsCore

struct CaptureUpdate: @unchecked Sendable {
  var message: String
  var input = "No signal"
  var output = ""
  var inputFast: Bool?
  var sourceDuration: CMTime?
  var mediaTime: CMTime?
  var pipelineEnabledApplied: Bool?
  var frames: UInt64 = 0
  var dropped: UInt64 = 0
  var processingMS: Double = 0
  var previewDelivered = false
  var sourceDrops: UInt64 = 0
  var captureDrops: UInt64 = 0
  var poolDrops: UInt64 = 0
  var cameraDrops: UInt64 = 0
  var previewDrops: UInt64 = 0
  var previewFrames: UInt64 = 0
  var outputFPS: Double = 0
  var displayedFrames: UInt64 = 0
  var rendererDrops: UInt64 = 0
  var previewError: String?
  var timecode: String?
  var audioChannels: Int = 0
  var audioSampleRate: Int = 0
  var audioPackets: UInt64 = 0
  var audioSamples: UInt64 = 0
  var audioBytes: UInt64 = 0
  var audioDrops: UInt64 = 0
  var audioPeakLeft: Double = 0
  var audioPeakRight: Double = 0
  var audioRMSLeft: Double = 0
  var audioRMSRight: Double = 0
  var audioBitrateKbps: Double = 0
  var audioPresent = false
  var audioPacketTime: CMTime?
  var videoBitrateMbps: Double = 0
  var videoDrops: UInt64 = 0
  var cameraOutputActive = false
  var cameraMessage = "Ultracam camera not connected"
  var stopped = false
}

struct CaptureMediaStats: @unchecked Sendable {
  var timecode: String?
  var audioPacketTime: CMTime
  var audioSampleFrames: UInt64
  var audioChannels: Int
  var leftPeak: Double
  var rightPeak: Double
  var leftRMS: Double
  var rightRMS: Double
  var audioBytes: UInt64
  var audioPresent: Bool
}

struct CaptureRawAudio: @unchecked Sendable {
  var samples: Data?
  var packetTime: CMTime
  var sampleFrames: UInt64
  var channels: Int
  var bytesPerSample: Int
}

// All media resources/configuration are queue-owned. Driver admission is bounded
// to twelve retained frames, covering measured source bursts plus queue delay.
// Preview visibility never controls camera processing.
final class CaptureController: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.ultracam.capture", qos: .userInteractive)
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var accepting = false
  private var activeFeedID: FeedID?
  private var recordingCallbacks: [FeedID: SourceRecordingCallbackAdapter.Callbacks] = [:]
  // Bumped under `lock` on every setRecordingCallbacks. stop()'s queued
  // cleanup captures the value it observed and must not delete a newer map.
  private var recordingCallbackGeneration: UInt64 = 0
  // FeedCapturePool sets this only after it has released the device. A start
  // on that discarded object must not open a second backend.
  private var retiredFromPool = false
  // Keep admission counters per generation. A driver callback may pass the
  // lock just before Stop advances the generation and enqueue stale work just
  // after the next Start begins; one global counter would underflow when that
  // stale work completes and could disable backpressure for the new run.
  private var inFlight: [UInt64: UInt64] = [:]
  private var mediaInFlight: [UInt64: UInt64] = [:]
  private var callbackDrops: UInt64 = 0
  private var mediaDropSamples: UInt64 = 0
  /// Admission drops already included in `mediaDropSamples`. The next packet's
  /// timestamp gap covers those same samples, so they must not be added again.
  private var accountedAdmissionAudioDrops: UInt64 = 0
  private var sourceDrops: UInt64 = 0
  private var sourceDuration = VideoContract.fastDuration
  private var lastSourcePTS: CMTime?
  private var lastReceived: Double = 0
  private let services: CaptureServices
  private let previewRenderers: [VideoPreviewRenderer]
  private var legacyPreviewOwner = true
  private var monitorSink: MonitorCaptureSink?
  private var monitorLifecycleSink: MonitorCaptureSink?
  private var monitorSequence: UInt64 = 0
  private var monitorProcessingRevision: UInt64 = 0
  private var monitorPipelineConfiguration: PipelineConfiguration?
  private var ownedPreviewRenderers: [VideoPreviewRenderer] { legacyPreviewOwner ? previewRenderers : [] }
  private let sampleFactory = VideoSampleFactory()
  private var deliveryStager = CameraFrameStager()
  private var processor: LUTProcessor?
  private var configuration = PipelineConfiguration()
  private var pipelineEnabled = true
  private var previewEnabled = true
  private var activeConfiguration: PipelineConfiguration?
  private var activeInputType: OSType?
  private var preparedConfiguration: PipelineConfiguration?
  private var detected: InputFormat?
  private var renderedFormat: InputFormat?
  private var inputLabel = "No signal"
  private var outputLabel = ""
  private var applied: Bool?
  private var frames: UInt64 = 0
  private var cameraDrops: UInt64 = 0
  private var poolDrops: UInt64 = 0
  private var firstSourceTime: CMTime?
  private var lastDeliveredSourceTime: CMTime?
  private var lastDeliveredHostTime: CMTime?
  private var firstHostTime: CMTime = .zero
  private var rateStart: Double = 0
  private var rateFrames: UInt64 = 0
  private var outputFPS: Double = 0
  private var processingMS: Double = 0
  private var timecode: String?
  private var audioChannels = 0
  private var audioSampleRate = 0
  private var audioPackets: UInt64 = 0
  private var audioSamples: UInt64 = 0
  private var audioBytes: UInt64 = 0
  private var audioDrops: UInt64 = 0
  private var audioPeakLeft = 0.0
  private var audioPeakRight = 0.0
  private var audioRMSLeft = 0.0
  private var audioRMSRight = 0.0
  private var audioPresent = false
  private var lastAudioPacketTime: CMTime?
  private var lastAudioSampleFrames: UInt64 = 0
  private var audioRateStart: Double = 0
  private var audioRateBytes: UInt64 = 0
  private var audioBitrateKbps = 0.0
  // Raw-only backends need a synthesized media-stat update. The native live
  // backend supplies both callbacks, so its raw packet must not be counted a
  // second time through the stats path.
  private var rawAudioProvidesStats = false
  private var videoRateStart: Double = 0
  private var videoRateBytes: UInt64 = 0
  private var videoBitrateMbps = 0.0
  private var lastPublished: Double = 0
  // `fail` and the app's stopped-update handler both call `stop`. Without
  // this latch every stopped publish schedules another one.
  private var stopNotified = false
  private var cameraConnected = false
  private var reconnectAttempts = 0
  private var cameraOutage = false
  private var reconnectRequested = false
  private var reconnectAfter: Double = 0
  private var cameraMessage = "Ultracam camera not connected"
  private var message = "Stopped"
  private var frameRateGate = FrameRateGate()
  private var watchdog: DispatchSourceTimer?
  private var realtimeActivity: NSObjectProtocol?
  private let logger = Logger(subsystem: "org.ultracam.app", category: "capture")
  private var lastLogged: Double = 0
  // Program output consumes processed frames through FeedCoordinator. When it
  // is enabled, this controller keeps capture and GPU work alive without
  // opening a per-feed CMIO sink; the Program bridge owns that sink.
  private var cameraOutputEnabled = true

  var onUpdate: (@Sendable (CaptureUpdate) -> Void)?
  /// Carries the capture generation that produced the frame. Consumers that
  /// hop to another queue must compare this token before publishing so a
  /// callback already in flight cannot enter a later start session.
  var onProcessedFrame: ((ProcessedFrame<CVPixelBuffer>, UInt64) -> Void)?

  var activeFeed: FeedID? { lock.withLock { activeFeedID } }

  /// Identifies the latest start/stop generation for lifecycle consumers.
  /// This is separate from FeedSession's state generation because callers may
  /// stop the native controller more than once during one session teardown.
  var generationToken: UInt64 { lock.withLock { generation } }

  init(services: CaptureServices = .live(), previewRenderer: VideoPreviewRenderer? = nil,
    additionalPreviewRenderers: [VideoPreviewRenderer] = []) {
    self.services = services
    previewRenderers = (previewRenderer.map { [$0] } ?? []) + additionalPreviewRenderers
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    // Every executing controller operation retains self. Final release has
    // exclusive resource access, even if its owner omitted an explicit Stop.
    // Keep teardown on the capture queue; services and renderer state are
    // queue-owned and deinit may run on an arbitrary owner thread.
    syncOnQueue { stopResources() }
  }

  func setCameraOutputEnabled(_ enabled: Bool) {
    let token = lock.withLock { generation }
    syncOnQueue {
      cameraOutputEnabled = enabled
      if enabled {
        reconnectRequested = true
        reconnectAfter = 0
        return
      }
      services.disconnect()
      cameraConnected = false
      cameraMessage = "Ultracam camera not connected"
      publishCurrent(token: token)
    }
  }

  /// Camera output toggles are normally called from the main actor, but a
  /// service callback can also request one while capture work is executing on
  /// the capture queue. Avoid synchronously waiting on our own serial queue in
  /// that case; DispatchQueue.sync would deadlock the capture pipeline.
  private func syncOnQueue<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
    return try queue.sync(execute: body)
  }

  func load(_ cube: CubeLUT, expectedGeneration: UInt64? = nil,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async {
      do {
        if let expectedGeneration, !self.isCurrent(expectedGeneration) {
          throw VideoError.message("Camera changed before its LUT finished loading.")
        }
        if self.processor == nil { self.processor = try LUTProcessor() }
        try self.processor!.load(cube)
        self.monitorProcessingRevision &+= 1
        if self.pipelineEnabled && self.configuration.applyLUT {
          self.ownedPreviewRenderers.forEach { $0.flush() }
        }
        DispatchQueue.main.async { completion(.success(())) }
      } catch { DispatchQueue.main.async { completion(.failure(error)) } }
    }
  }

  func start(deviceID: String, configuration: PipelineConfiguration,
    pipelineEnabled: Bool = true, previewEnabled: Bool = true) {
    start(feedID: nil, deviceID: deviceID, configuration: configuration,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled)
  }

  func start(feedID: FeedID, deviceID: String, configuration: PipelineConfiguration,
    pipelineEnabled: Bool = true, previewEnabled: Bool = true) {
    start(feedID: Optional(feedID), deviceID: deviceID, configuration: configuration,
      pipelineEnabled: pipelineEnabled, previewEnabled: previewEnabled)
  }

  private func start(feedID: FeedID?, deviceID: String, configuration: PipelineConfiguration,
    pipelineEnabled: Bool, previewEnabled: Bool) {
    let token = lock.withLock { () -> UInt64? in
      if retiredFromPool { return nil }
      generation &+= 1
      accepting = false
      // Any callbacks admitted for the previous generation are stale once a
      // new start is requested. Their queued work still releases its token,
      // but the old counters must not survive across runs if that work is
      // delayed or cancelled during teardown.
      inFlight.removeAll(keepingCapacity: true)
      mediaInFlight.removeAll(keepingCapacity: true)
      activeFeedID = feedID
      return generation
    }
    guard let token else { return }
    queue.async { [self] in
      guard self.isCurrent(token) else { return }
      self.stopNotified = false
      // Recording can be armed while the feed is idle. Tearing the previous
      // session down must not delete the callbacks just installed for it.
      self.stopResources(preserveRecordingCallbacks: true)
      do {
        self.realtimeActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .latencyCritical], reason: "Live UltraStudio video processing")
        self.configuration = configuration
        self.pipelineEnabled = pipelineEnabled
        self.previewEnabled = previewEnabled
        self.activeConfiguration = nil
        self.activeInputType = nil
        self.detected = nil
        self.inputLabel = "Waiting for detected input"
        self.outputLabel = ""
        self.applied = nil
        self.frames = 0
        self.cameraDrops = 0
        self.poolDrops = 0
        self.firstSourceTime = nil
        self.lastDeliveredSourceTime = nil
        self.lastDeliveredHostTime = nil
        self.rateStart = 0
        self.rateFrames = 0
        self.outputFPS = 0
        self.processingMS = 0
        self.timecode = nil
        self.audioChannels = 0
        self.audioSampleRate = 0
        self.audioPackets = 0
        self.audioSamples = 0
        self.audioBytes = 0
        self.audioDrops = 0
        self.accountedAdmissionAudioDrops = 0
        self.audioPeakLeft = 0
        self.audioPeakRight = 0
        self.audioRMSLeft = 0
        self.audioRMSRight = 0
        self.audioPresent = false
        self.lastAudioPacketTime = nil
        self.lastAudioSampleFrames = 0
        self.audioRateStart = 0
        self.audioRateBytes = 0
        self.audioBitrateKbps = 0
        self.rawAudioProvidesStats = false
        self.videoRateStart = 0
        self.videoRateBytes = 0
        self.videoBitrateMbps = 0
        self.lastPublished = 0
        self.lastLogged = 0
        self.frameRateGate = FrameRateGate()
        self.sampleFactory.reset()
        self.cameraConnected = false
        self.cameraMessage = "Waiting for detected input"
        // Connect and warm before enabling driver callbacks. Cold CMIO/GPU
        // setup on the first frame can otherwise overflow the admission FIFO.
        // The remembered rate is provisional: the first validated frame still
        // establishes the exact contract, and only received data sets metadata.
        let warm = self.effectiveConfiguration(inputFast: configuration.inputFast)
        if let type = self.services.capturePixelFormat {
          try self.establish(warm, inputType: type)
        } else if self.services.startAutomatic == nil {
          try self.establish(warm, inputType: kCVPixelFormatType_422YpCbCr10)
        }
        guard self.isCurrent(token) else {
        self.stopResources(preserveRecordingCallbacks: true)
        return
      }
        let hasPreview = previewEnabled &&
          (self.ownedPreviewRenderers.contains { $0.isVisible } || self.services.preview != nil)
        if self.cameraConnected || hasPreview {
          if !warm.untouched, self.processor == nil { self.processor = try LUTProcessor() }
          try self.ensurePrepared(warm)
        }
        guard self.isCurrent(token) else {
        self.stopResources(preserveRecordingCallbacks: true)
        return
      }
        self.lock.withLock {
          self.accepting = true
          self.callbackDrops = 0
          self.sourceDrops = 0
          self.mediaDropSamples = 0
          self.accountedAdmissionAudioDrops = 0
          self.lastSourcePTS = nil
          self.sourceDuration = configuration.inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
          self.lastReceived = ProcessInfo.processInfo.systemUptime
        }
        let event: (String) -> Void = { [weak self] value in
          guard let self else { return }
          self.queue.async {
            guard self.isAccepting(token) else { return }
            if value.hasPrefix("Capture error: ") {
              self.fail(value, token: token)
              return
            }
            self.message = value
            if value.localizedCaseInsensitiveContains("no video signal") ||
              value.localizedCaseInsensitiveContains("no HDMI video signal") ||
              value.localizedCaseInsensitiveContains("unsupported") {
              self.clearSignal()
              self.inputLabel = value
            }
            self.publishCurrent(token: token)
          }
        }
        let media: (CaptureMediaStats) -> Void = { [weak self] stats in
            guard let self else { return }
            self.receiveMedia(stats, token: token)
          }
        if let automatic = self.services.startAutomatic {
          if let automaticWithSourceAudio = self.services.startAutomaticWithSourceAudio {
            try automaticWithSourceAudio(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, media, { [weak self] audio in
              self?.receiveRawAudio(audio, token: token)
            }, event)
          } else if let automaticWithRawAudio = self.services.startAutomaticWithRawAudio {
            self.rawAudioProvidesStats = true
            try automaticWithRawAudio(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, { [weak self] audio in
              self?.receiveRawAudio(audio, token: token)
            }, event)
          } else if let automaticWithMedia = self.services.startAutomaticWithMedia {
            try automaticWithMedia(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, media, event)
          } else {
            try automatic(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, event)
          }
        } else if let startWithSourceAudio = self.services.startWithSourceAudio {
          try startWithSourceAudio(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, media, { [weak self] audio in
            self?.receiveRawAudio(audio, token: token)
          }, event)
        } else if let startWithRawAudio = self.services.startWithRawAudio {
          self.rawAudioProvidesStats = true
          try startWithRawAudio(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, { [weak self] audio in
            self?.receiveRawAudio(audio, token: token)
          }, event)
        } else if let startWithMedia = self.services.startWithMedia {
          try startWithMedia(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, media, event)
        } else {
          try self.services.start(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, event)
        }
        guard self.isCurrent(token) else {
        self.stopResources(preserveRecordingCallbacks: true)
        return
      }
        self.message = "Waiting for UltraStudio signal…"
        self.publishCurrent(token: token)
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
          guard let self, self.isAccepting(token) else { return }
          let last = self.lock.withLock { self.lastReceived }
          if ProcessInfo.processInfo.systemUptime - last > 2 {
            if self.services.startAutomatic != nil {
              if self.detected != nil || self.message == "Waiting for UltraStudio signal…" {
                self.clearSignal()
                self.message = "No video signal — waiting for HDMI."
                self.publishCurrent(token: token)
              }
            } else {
              self.fail("No valid video signal for two seconds. Check the FX3 HDMI output.", token: token)
            }
          }
        }
        self.watchdog = timer
        timer.resume()
      } catch { self.fail(error.localizedDescription, token: token) }
    }
  }

  func reconfigure(configuration: PipelineConfiguration, pipelineEnabled: Bool) {
    let token = lock.withLock { generation }
    queue.async {
      guard self.isAccepting(token) else { return }
      self.configuration = configuration
      self.pipelineEnabled = pipelineEnabled
      self.monitorProcessingRevision &+= 1
      if !self.cameraConnected { self.reconnectRequested = true }
      self.applied = nil
      self.outputLabel = ""
      self.sampleFactory.reset()
      self.ownedPreviewRenderers.forEach { $0.flush() }
      self.message = self.detected == nil ? "Waiting for UltraStudio signal…" : "Updating output…"
      self.publishCurrent(token: token)
      // First new frame establishes the exact source-dependent output contract.
    }
  }

  func setPreviewEnabled(_ enabled: Bool) {
    let token = lock.withLock { generation }
    queue.async {
      guard self.isAccepting(token) else { return }
      self.previewEnabled = enabled
      if !enabled { self.ownedPreviewRenderers.forEach { $0.flush() } }
      self.publishCurrent(token: token)
    }
  }

  func setLegacyPreviewOwnership(_ enabled: Bool) {
    queue.async { self.legacyPreviewOwner = enabled }
  }

  func setMonitorSink(_ sink: MonitorCaptureSink?) {
    lock.withLock { monitorLifecycleSink = sink }
    queue.async { self.monitorSink = sink }
  }

  func stop() {
    let request = makeStopRequest()
    request.sink?.invalidate(rejectingCaptureGeneration: request.stoppedGeneration)
    // Admission is dropped under the lock above. Cleanup stays queued so a
    // capture worker blocked in preview or GPU work cannot deadlock stop().
    queue.async { self.performStop(request) }
  }

  private struct StopRequest {
    var token: UInt64
    var stoppedGeneration: UInt64
    var callbackGeneration: UInt64
    var sink: MonitorCaptureSink?
  }

  private func makeStopRequest() -> StopRequest {
    lock.withLock {
      let stoppedGeneration = generation
      generation &+= 1
      accepting = false
      inFlight.removeAll(keepingCapacity: true)
      mediaInFlight.removeAll(keepingCapacity: true)
      activeFeedID = nil
      return StopRequest(token: generation, stoppedGeneration: stoppedGeneration,
        callbackGeneration: recordingCallbackGeneration, sink: monitorLifecycleSink)
    }
  }

  private func performStop(_ request: StopRequest) {
    guard isCurrent(request.token) else { return }
    guard !stopNotified else { return }
    stopNotified = true
    stopResources(callbackGeneration: request.callbackGeneration)
    detected = nil
    inputLabel = "No signal"
    outputLabel = ""
    applied = nil
    message = "Stopped"
    publishCurrent(token: request.token, stopped: true)
  }

  /// Finishes `stopResources` before returning when called off the capture
  /// queue. Nil means a newer start won; the caller must keep this controller.
  /// `fileprivate` so `FeedCapturePool.remove` in this file can call it.
  fileprivate func stopReleasingResources() -> UInt64? {
    let request = makeStopRequest()
    request.sink?.invalidate(rejectingCaptureGeneration: request.stoppedGeneration)
    syncOnQueue { self.performStop(request) }
    return lock.withLock {
      generation == request.token && !accepting ? request.token : nil
    }
  }

  /// Shares `lock` with `start` so removal and a racing start cannot both own
  /// the device. Already-retired generations stay retired.
  /// `fileprivate` so `FeedCapturePool.remove` in this file can call it.
  fileprivate func retireIfStillStopped(_ token: UInt64) -> Bool {
    lock.withLock {
      guard generation == token, !accepting else { return false }
      retiredFromPool = true
      return true
    }
  }

  private func isCurrent(_ token: UInt64) -> Bool { lock.withLock { generation == token } }
  private func isAccepting(_ token: UInt64) -> Bool { lock.withLock { generation == token && accepting } }

  /// Installs one feed's raw callback fan-out. The callback itself performs
  /// only bounded SourceRecorderCore admission and is safe to call on the
  /// native DeckLink callback thread.
  func setRecordingCallbacks(feedID: FeedID,
    callbacks: SourceRecordingCallbackAdapter.Callbacks?) {
    lock.withLock {
      recordingCallbackGeneration &+= 1
      if let callbacks { recordingCallbacks[feedID] = callbacks }
      else { recordingCallbacks.removeValue(forKey: feedID) }
    }
  }

  func isAccepting(feedID: FeedID) -> Bool {
    lock.withLock { accepting && activeFeedID == feedID }
  }

  var hasActiveFeed: Bool {
    lock.withLock { accepting && activeFeedID != nil }
  }

  private func stopResources(preserveRecordingCallbacks: Bool = false,
    callbackGeneration: UInt64? = nil) {
    watchdog?.cancel()
    watchdog = nil
    if let activity = realtimeActivity { ProcessInfo.processInfo.endActivity(activity) }
    realtimeActivity = nil
    flushPreviewsIfEnabled()
    services.stop()
    services.disconnect()
    cameraConnected = false
    reconnectAttempts = 0
    cameraOutage = false
    reconnectRequested = false
    reconnectAfter = 0
    cameraMessage = "Ultracam camera not connected"
    activeConfiguration = nil
    activeInputType = nil
    deliveryStager = CameraFrameStager()
    processor?.releaseIdleResources()
    preparedConfiguration = nil
    if !preserveRecordingCallbacks {
      lock.withLock {
        // Callbacks installed after this stop began belong to the next take.
        // The following start preserves the map, so wiping them here leaves
        // that take with no picture or audio.
        if let callbackGeneration, recordingCallbackGeneration != callbackGeneration { return }
        recordingCallbacks.removeAll(keepingCapacity: true)
      }
    }
  }

  /// Headless Program controllers share no UI renderer. Flushing a renderer
  /// they do not own clears the window that belongs to the selected feed.
  private func flushPreviewsIfEnabled() {
    guard previewEnabled else { return }
    ownedPreviewRenderers.forEach { $0.flush() }
  }

  private func clearSignal() {
    lock.withLock { lastSourcePTS = nil }
    detected = nil
    inputLabel = "No signal"
    outputLabel = ""
    applied = nil
    outputFPS = 0
    firstSourceTime = nil
    frameRateGate = FrameRateGate()
    flushPreviewsIfEnabled()
  }

  private func fail(_ value: String, token: UInt64) {
    guard isCurrent(token), !stopNotified else { return }
    stopNotified = true
    lock.withLock { accepting = false }
    stopResources()
    applied = nil
    outputLabel = ""
    message = value
    logger.error("Capture stopped: \(value, privacy: .public)")
    publishCurrent(token: token, stopped: true)
  }

  private func effectiveConfiguration(inputFast: Bool) -> PipelineConfiguration {
    var result = pipelineEnabled ? configuration : PipelineConfiguration(
      applyLUT: false, downscale: false, convertTo420: false, reduceFrameRate: false)
    result.inputFast = inputFast
    return result
  }

  private func ensurePrepared(_ next: PipelineConfiguration) throws {
    if preparedConfiguration?.applyLUT != next.applyLUT || preparedConfiguration?.downscale != next.downscale ||
      preparedConfiguration?.convertTo420 != next.convertTo420 {
      try processor?.prepare(configuration: next)
      preparedConfiguration = next
    }
  }

  private func establish(_ next: PipelineConfiguration, inputType: OSType) throws {
    let prior = activeConfiguration
    let sameContract = prior.map {
      $0.width == next.width && $0.height == next.height &&
        $0.pixelFormat == next.pixelFormat && $0.duration == next.duration &&
        $0.untouched == next.untouched && activeInputType == inputType
    } ?? false
    let now = ProcessInfo.processInfo.systemUptime
    if sameContract {
      activeConfiguration = next
      guard !cameraConnected, (reconnectRequested || reconnectAttempts > 0), now >= reconnectAfter else { return }
      if reconnectAttempts > 0 { reconnectAttempts -= 1 }
    }
    let wasConnected = cameraConnected
    services.disconnect()
    cameraConnected = false
    reconnectRequested = false
    reconnectAfter = now + max(0, services.cameraRetryInterval)
    // A retry of the same contract must preserve prepared transport resources
    // and the existing source cadence used by the surviving local preview.
    if prior != nil && !sameContract { deliveryStager = CameraFrameStager() }
    guard cameraOutputEnabled else {
      activeConfiguration = next
      activeInputType = inputType
      if prior?.duration != next.duration { frameRateGate = FrameRateGate() }
      if !sameContract { sampleFactory.reset() }
      return
    }
    do {
      try services.connect(next, inputType)
      cameraConnected = true
      cameraMessage = "Ultracam camera connected. Choose it in your meeting app."
    } catch {
      cameraMessage = "Camera output unavailable — \(error.localizedDescription)"
      // Only a lost connection retries. Each attempt blocks the capture queue
      // for up to seconds, so a camera that never connected (extension not
      // running) would stall capture three more times before giving up.
      if wasConnected { beginCameraRecovery() }
    }
    activeConfiguration = next
    activeInputType = inputType
    if prior?.duration != next.duration { frameRateGate = FrameRateGate() }
    if !sameContract { sampleFactory.reset() }
  }

  private func beginCameraRecovery() {
    guard !cameraOutage else { return }
    cameraOutage = true
    reconnectAttempts = 3
  }

  private func receive(_ image: CVPixelBuffer, at pts: CMTime, duration: CMTime?,
    signalValid: Bool, token: UInt64) {
    let recording = lock.withLock { () -> (SourceRecordingCallbackAdapter.Callbacks?, CMTime) in
      let frameDuration = duration ?? sourceDuration
      guard generation == token, accepting else { return (nil, frameDuration) }
      return (activeFeedID.flatMap { recordingCallbacks[$0] }, frameDuration)
    }
    // Recording admission must not depend on the bounded processing FIFO:
    // synchronous preview/GPU work can occupy every slot for many source frames.
    // These are metadata-only checks, with no pixel scan, conversion or waiting.
    // Keep malformed inputs out of the recorder while retaining its invalid-sample
    // telemetry and the processing path's existing signal/error reporting.
    if let callbacks = recording.0 {
      let duration = recording.1
      let validRecordingFrame = signalValid && pts.isNumeric && pts.epoch == 0 && pts.value >= 0 &&
        duration.epoch == 0 &&
        (duration == VideoContract.fastDuration || duration == VideoContract.slowDuration) &&
        CVPixelBufferGetWidth(image) == 3840 && CVPixelBufferGetHeight(image) == 2160 &&
        VideoContract.tenBit422.contains(CVPixelBufferGetPixelFormatType(image)) &&
        (try? VideoBufferLayout.validate(image)) != nil
      guard isAccepting(token) else { return }
      _ = callbacks.video(image, pts, duration, validRecordingFrame)
    }
    if !signalValid { return }
    let accepted = lock.withLock { () -> CMTime? in
      guard generation == token, accepting else { return nil }
      let frameDuration = duration ?? sourceDuration
      lastReceived = ProcessInfo.processInfo.systemUptime
      if frameDuration.isNumeric, frameDuration.seconds > 0, frameDuration != sourceDuration {
        sourceDuration = frameDuration
        lastSourcePTS = nil
      }
      if pts.isNumeric {
        if let prior = lastSourcePTS, sourceDuration.isNumeric, sourceDuration.seconds > 0 {
          let intervals = CMTimeSubtract(pts, prior).seconds / sourceDuration.seconds
          if intervals > 1.5, intervals < 600 { sourceDrops &+= UInt64(intervals.rounded() - 1) }
        }
        lastSourcePTS = pts
      }
      let pending = inFlight[token, default: 0]
      if pending >= UInt64(VideoContract.captureAdmissionLimit) {
        callbackDrops &+= 1
        return nil
      }
      inFlight[token] = pending + 1
      return frameDuration
    }
    guard let accepted else { return }
    // Assigned on the serial driver callback route, under the admission lock.
    let sequence = lock.withLock { monitorSequence &+= 1; return monitorSequence }
    let frame = CapturedFrame(image: image, pts: pts, duration: accepted,
      receivedAt: ProcessInfo.processInfo.systemUptime, sequence: sequence)
    queue.async {
      // DeckLink callbacks arrive at video cadence for hours. CoreMedia and
      // AVFoundation create autoreleased wrappers while a frame is staged,
      // processed and fanned out; drain them after each serial work item so
      // bounded admission also bounds Objective-C autorelease memory.
      autoreleasepool {
        defer { self.releaseFrame(token) }
        guard self.isAccepting(token) else { return }
        self.process(frame, token: token)
      }
    }
  }

  private func receiveMedia(_ stats: CaptureMediaStats, token: UInt64) {
    let accepted = lock.withLock { () -> Bool in
      guard generation == token, accepting else { return false }
      let pending = mediaInFlight[token, default: 0]
      if pending >= UInt64(VideoContract.captureAdmissionLimit) {
        // Preserve packet sample counts when a metadata update is dropped so
        // the resulting audio-gap counter remains useful under video stalls.
        mediaDropSamples &+= stats.audioSampleFrames
        return false
      }
      mediaInFlight[token] = pending + 1
      return true
    }
    guard accepted else { return }
    queue.async {
      autoreleasepool {
        defer { self.releaseMedia(token) }
        guard self.isAccepting(token) else { return }
        self.recordMedia(stats)
      }
    }
  }

  private func receiveRawAudio(_ audio: CaptureRawAudio, token: UInt64) {
    let recording = lock.withLock { () -> SourceRecordingCallbackAdapter.Callbacks? in
      guard generation == token, accepting else { return nil }
      return activeFeedID.flatMap { recordingCallbacks[$0] }
    }
    let validRawFormat = audio.bytesPerSample == EmbeddedAudioFormat.sourceBytesPerSample
    if let samples = audio.samples, audio.sampleFrames > 0, audio.channels > 0, validRawFormat {
      _ = recording?.rawAudio(samples, Int(audio.sampleFrames), audio.packetTime,
        audio.channels, audio.bytesPerSample)
    }
    if lock.withLock({ rawAudioProvidesStats }) {
      receiveMedia(CaptureMediaStats(timecode: nil, audioPacketTime: audio.packetTime,
        audioSampleFrames: audio.sampleFrames, audioChannels: audio.channels,
        leftPeak: 0, rightPeak: 0, leftRMS: 0, rightRMS: 0,
        audioBytes: UInt64(audio.samples?.count ?? 0), audioPresent: audio.samples != nil), token: token)
    }
  }

  private func releaseFrame(_ token: UInt64) {
    lock.withLock {
      guard let pending = inFlight[token] else { return }
      if pending <= 1 { inFlight.removeValue(forKey: token) }
      else { inFlight[token] = pending - 1 }
    }
  }

  private func releaseMedia(_ token: UInt64) {
    lock.withLock {
      guard let pending = mediaInFlight[token] else { return }
      if pending <= 1 { mediaInFlight.removeValue(forKey: token) }
      else { mediaInFlight[token] = pending - 1 }
    }
  }

  private func recordMedia(_ stats: CaptureMediaStats) {
    timecode = stats.timecode
    audioChannels = max(0, stats.audioChannels)
    audioPackets &+= 1
    audioSamples &+= stats.audioSampleFrames
    audioBytes &+= stats.audioBytes
    audioRateBytes &+= stats.audioBytes
    audioPresent = stats.audioPresent
    audioPeakLeft = max(0, min(1, stats.leftPeak))
    audioPeakRight = max(0, min(1, stats.rightPeak))
    audioRMSLeft = max(0, min(1, stats.leftRMS))
    audioRMSRight = max(0, min(1, stats.rightRMS))
    // The native input is always enabled at 48 kHz (the DeckLink callback
    // does not carry a sample-rate field). Use that fixed contract directly;
    // inferring a rate from the previous packet hides missing packets because
    // a gap makes the inferred rate fall in proportion to the gap.
    if stats.audioPresent && stats.audioSampleFrames > 0 {
      audioSampleRate = Int(EmbeddedAudioFormat.sampleRate)
    }
    let packetTime = stats.audioPacketTime
    if packetTime.isNumeric, stats.audioSampleFrames > 0 {
      if let prior = lastAudioPacketTime, prior.isNumeric {
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(packetTime, prior))
        if elapsed > 0 {
          let expected = Int((elapsed * EmbeddedAudioFormat.sampleRate).rounded())
          if expected > Int(lastAudioSampleFrames) {
            let missing = UInt64(expected - Int(lastAudioSampleFrames))
            let admission = lock.withLock { mediaDropSamples }
            let fresh = admission > accountedAdmissionAudioDrops ? admission - accountedAdmissionAudioDrops : 0
            let overlap = min(missing, fresh)
            accountedAdmissionAudioDrops += overlap
            audioDrops &+= missing - overlap
          }
        }
      }
      // Do not move the baseline backwards after a malformed/regressed packet;
      // the next valid packet should still be compared with the last source
      // clock position rather than silently masking the discontinuity.
      if let prior = lastAudioPacketTime {
        if CMTimeCompare(packetTime, prior) >= 0 {
          lastAudioPacketTime = packetTime
          lastAudioSampleFrames = stats.audioSampleFrames
        }
      } else {
        lastAudioPacketTime = packetTime
        lastAudioSampleFrames = stats.audioSampleFrames
      }
    }
  }

  private func process(_ frame: CapturedFrame, token: UInt64) {
    let input = frame.image
    videoRateBytes &+= UInt64(max(0, CVPixelBufferGetDataSize(input)))
    let actual = InputFormat(width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input),
      type: CVPixelBufferGetPixelFormatType(input), duration: frame.duration)
    var metadataChanged = detected != actual
    if detected != actual {
      monitorProcessingRevision &+= 1
      if detected != nil { flushPreviewsIfEnabled() }
      if detected?.duration != actual.duration { firstSourceTime = nil; frameRateGate = FrameRateGate() }
      detected = actual
      inputLabel = actual.label
    }
    guard actual.width == 3840, actual.height == 2160, VideoContract.tenBit422.contains(actual.type) else {
      fail("Unsupported detected input: \(actual.label). Expected 4K 10-bit 4:2:2.", token: token)
      return
    }
    guard frame.pts.isNumeric, frame.pts.epoch == 0, actual.duration.epoch == 0,
      actual.duration == VideoContract.fastDuration || actual.duration == VideoContract.slowDuration else {
      fail("Unsupported or invalid detected frame timing.", token: token)
      return
    }
    do {
      try VideoBufferLayout.validate(input)
      let effective = effectiveConfiguration(inputFast: actual.duration == VideoContract.fastDuration)
      try establish(effective, inputType: actual.type)
      guard isAccepting(token) else { return }
      if monitorPipelineConfiguration != effective {
        monitorPipelineConfiguration = effective
        monitorProcessingRevision &+= 1
      }
      let entryTime = ProcessInfo.processInfo.systemUptime
      let inputFrameInterval = actual.duration.seconds
      let entryQueueAge = max(0, entryTime - frame.receivedAt)
      if entryQueueAge > inputFrameInterval {
        monitorSink?.reportCriticalPipeline(captureGeneration: token, queueAge: entryQueueAge,
          processingTime: 0, frameInterval: inputFrameInterval, now: entryTime)
      }
      monitorSink?.offer(source: input, output: nil, pts: frame.pts, captureGeneration: token,
        sequence: frame.sequence, processingRevision: monitorProcessingRevision,
        sourceOnly: true, correspondence: .identity)
      let visible = previewEnabled ? ownedPreviewRenderers.filter { $0.isVisible } : []
      let hasPreview = previewEnabled && (!visible.isEmpty || services.preview != nil)
      let hasProcessedOutput = onProcessedFrame != nil
      let hasMonitorOutput = monitorSink?.needsOutput == true
      // No downstream demand: keep metadata/detection alive without allocating,
      // submitting GPU work or staging raw buffers that nobody can consume.
      guard cameraConnected || hasPreview || hasProcessedOutput || hasMonitorOutput else {
        let idleTime = ProcessInfo.processInfo.systemUptime
        monitorSink?.reportCriticalPipeline(captureGeneration: token,
          queueAge: max(0, idleTime - frame.receivedAt), processingTime: 0,
          frameInterval: inputFrameInterval, now: idleTime)
        if preparedConfiguration != nil {
          processor?.releaseIdleResources()
          preparedConfiguration = nil
          deliveryStager = CameraFrameStager()
        }
        applied = nil
        outputLabel = ""
        processingMS = 0
        outputFPS = 0
        message = "Camera ready — no active video destination."
        publishIfDue(token: token, force: metadataChanged)
        return
      }
      // Created on first demand; a complete bypass still uses it for the owned GPU copy.
      if processor == nil { self.processor = try LUTProcessor() }
      let processor = self.processor
      try ensurePrepared(effective)
      let start = ProcessInfo.processInfo.systemUptime
      let rendered: CVPixelBuffer
      if effective.untouched {
        // The preview, the meeting-app camera and Program get an owned copy;
        // the capture card may reuse its buffer while they still display it.
        guard let processor else { throw VideoError.message("GPU processor is unavailable.") }
        rendered = try processor.passthrough(input)
      } else {
        guard let processor else { throw VideoError.message("GPU processor is unavailable.") }
        rendered = try processor.process(input, configuration: effective)
      }
      let processingEnd = ProcessInfo.processInfo.systemUptime
      processingMS = (processingEnd - start) * 1000
      monitorSink?.reportCriticalPipeline(captureGeneration: token,
        queueAge: max(0, start - frame.receivedAt), processingTime: processingEnd - start,
        frameInterval: inputFrameInterval, now: processingEnd)
      services.didProcess(processingMS, (start - frame.receivedAt) * 1000)
      guard isAccepting(token) else { return }
      // Temporal selection remains last; bypass retains the source duration.
      guard frameRateGate.shouldDeliver(frame.pts, duration: effective.duration) else { return }
      let correspondence = MonitorCorrespondence(
        scaleX: Double(CVPixelBufferGetWidth(rendered)) / Double(actual.width),
        scaleY: Double(CVPixelBufferGetHeight(rendered)) / Double(actual.height),
        offsetX: 0, offsetY: 0)
      monitorSink?.offer(source: input, output: rendered, pts: frame.pts, captureGeneration: token,
        sequence: frame.sequence, processingRevision: monitorProcessingRevision,
        sourceOnly: false, correspondence: correspondence)
      if let onProcessedFrame {
        let metadata = ProcessedFrameMetadata(
          presentationTime: frame.pts,
          duration: effective.duration,
          width: CVPixelBufferGetWidth(rendered),
          height: CVPixelBufferGetHeight(rendered),
          pixelFormat: UInt32(CVPixelBufferGetPixelFormatType(rendered)),
          processingRevision: monitorProcessingRevision)
        onProcessedFrame(ProcessedFrame(payload: rendered, metadata: metadata), token)
      }
      let time = hostTime(for: frame.pts, duration: effective.duration)
      let original = try sampleFactory.sample(rendered, at: time, duration: effective.duration)
      let sample: CMSampleBuffer
      if effective.untouched && (cameraConnected || !visible.isEmpty) {
        guard isAccepting(token) else { return }
        sample = try deliveryStager.stage(original)
      } else { sample = original }
      guard isAccepting(token) else { return }
      if previewEnabled {
        let sourceID = lock.withLock { activeFeedID?.rawValue }
        visible.forEach { $0.enqueue(sample, sourceID: sourceID) }
        services.preview?(sample)
      }
      if cameraConnected {
        do {
          if try services.send(sample) {
            // An opened queue is not proof of recovery. Only a successful
            // frame send ends the outage and permits a fresh retry budget.
            cameraOutage = false
            reconnectAttempts = 0
          } else { cameraDrops &+= 1 }
        }
        catch {
          cameraDrops &+= 1
          services.disconnect()
          cameraConnected = false
          beginCameraRecovery()
          reconnectRequested = false
          reconnectAfter = ProcessInfo.processInfo.systemUptime + max(0, services.cameraRetryInterval)
          cameraMessage = "Camera output disconnected — \(error.localizedDescription)"
        }
      }
      frames &+= 1
      lastDeliveredSourceTime = frame.pts
      lastDeliveredHostTime = time
      metadataChanged = metadataChanged || applied != pipelineEnabled
      applied = pipelineEnabled
      let output = InputFormat(width: CVPixelBufferGetWidth(rendered), height: CVPixelBufferGetHeight(rendered),
        type: CVPixelBufferGetPixelFormatType(rendered), duration: effective.duration)
      if renderedFormat != output || outputLabel.isEmpty {
        metadataChanged = true
        renderedFormat = output
        outputLabel = output.label
      }
      message = pipelineEnabled ? (effective.applyLUT ? "Processing enabled — LUT applied" : "Processing enabled — LUT off") : "Complete bypass — original camera signal"
      publishIfDue(token: token, force: frames == 1 || metadataChanged)
    } catch VideoError.outputBackPressure { poolDrops &+= 1 }
    catch { fail(error.localizedDescription, token: token) }
  }

  private func hostTime(for sourceTime: CMTime, duration: CMTime) -> CMTime {
    let now = services.hostTime()
    var reset = firstSourceTime == nil
    if let last = lastDeliveredSourceTime, CMTimeCompare(sourceTime, last) < 0 { reset = true }
    if let origin = firstSourceTime {
      let mapped = CMTimeAdd(firstHostTime, CMTimeSubtract(sourceTime, origin))
      // Preserve normal source cadence independently of GPU completion jitter.
      // A discontinuous source clock must not schedule output seconds into the
      // future. Late processing alone must preserve source cadence, including
      // a costly hot change that temporarily puts its first frame behind now.
      if CMTimeSubtract(mapped, now).seconds > 0.5 { reset = true }
    }
    if reset {
      firstSourceTime = sourceTime
      firstHostTime = now
      if let last = lastDeliveredHostTime {
        firstHostTime = CMTimeMaximum(firstHostTime, CMTimeAdd(last, duration))
      }
    }
    return CMTimeAdd(firstHostTime, CMTimeSubtract(sourceTime, firstSourceTime!))
  }

  private func publishIfDue(token: UInt64, force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastPublished >= 0.25 else { return }
    let elapsed = now - rateStart
    outputFPS = rateStart == 0 ? 0 : Double(frames - rateFrames) / elapsed
    rateStart = now
    rateFrames = frames
    if audioRateStart == 0 { audioRateStart = now }
    if videoRateStart == 0 { videoRateStart = now }
    let mediaElapsed = now - audioRateStart
    if mediaElapsed >= 0.25 {
      audioBitrateKbps = Double(audioRateBytes) * 8 / mediaElapsed / 1_000
      audioRateBytes = 0
      audioRateStart = now
      let videoElapsed = max(0.001, now - videoRateStart)
      videoBitrateMbps = Double(videoRateBytes) * 8 / videoElapsed / 1_000_000
      videoRateBytes = 0
      videoRateStart = now
    }
    lastPublished = now
    ownedPreviewRenderers.filter { previewEnabled && $0.isVisible }.forEach { $0.refreshPerformanceMetrics() }
    if now - lastLogged >= 5 {
      lastLogged = now
      if let packed = processor?.packedInputDiagnostics {
        logger.notice("Packed input noCopy=\(packed.noCopyFrames) copiedFallback=\(packed.copiedFrames)")
      }
      let losses = lock.withLock { (sourceDrops, callbackDrops, mediaDropSamples) }
      logger.notice("Live fps=\(self.outputFPS) delivered=\(self.frames) sourceDrops=\(losses.0) captureDrops=\(losses.1) mediaDropSamples=\(losses.2) poolDrops=\(self.poolDrops)")
    }
    publishCurrent(token: token)
  }

  private func publishCurrent(token: UInt64, stopped: Bool = false) {
    let losses = lock.withLock { (sourceDrops, callbackDrops, mediaDropSamples) }
    let audioLosses = audioDrops &+ losses.2
    let diagnostics = ownedPreviewRenderers.map { $0.diagnosticsSnapshot() }
    let previewLosses = diagnostics.reduce(UInt64(0)) {
      $0 + $1.stagingDrops + $1.replaced + $1.failed + $1.rendererDropped + $1.rendererCorrupted
    }
    let visiblePreview = previewEnabled && (ownedPreviewRenderers.contains { $0.isVisible } || services.preview != nil)
    let update = CaptureUpdate(message: message, input: inputLabel, output: outputLabel,
      inputFast: detected.map { $0.duration == VideoContract.fastDuration }, sourceDuration: detected?.duration,
      mediaTime: stopped ? nil : lastDeliveredSourceTime,
      pipelineEnabledApplied: applied, frames: frames, dropped: losses.0 + losses.1 + poolDrops + cameraDrops,
      processingMS: processingMS, previewDelivered: visiblePreview && !outputLabel.isEmpty && !stopped,
      sourceDrops: losses.0, captureDrops: losses.1, poolDrops: poolDrops, cameraDrops: cameraDrops,
      previewDrops: previewLosses, previewFrames: diagnostics.reduce(0) { $0 + $1.enqueued },
      outputFPS: outputFPS, displayedFrames: diagnostics.reduce(0) { $0 + $1.rendererFrames },
      rendererDrops: diagnostics.reduce(0) { $0 + $1.rendererDropped },
      previewError: diagnostics.compactMap(\.lastError).first,
      timecode: stopped ? nil : timecode,
      audioChannels: stopped ? 0 : audioChannels, audioSampleRate: stopped ? 0 : audioSampleRate,
      audioPackets: stopped ? 0 : audioPackets, audioSamples: stopped ? 0 : audioSamples,
      audioBytes: stopped ? 0 : audioBytes, audioDrops: stopped ? 0 : audioLosses,
      audioPeakLeft: stopped ? 0 : audioPeakLeft, audioPeakRight: stopped ? 0 : audioPeakRight,
      audioRMSLeft: stopped ? 0 : audioRMSLeft, audioRMSRight: stopped ? 0 : audioRMSRight,
      audioBitrateKbps: stopped ? 0 : audioBitrateKbps, audioPresent: stopped ? false : audioPresent,
      audioPacketTime: stopped ? nil : lastAudioPacketTime,
      videoBitrateMbps: stopped ? 0 : videoBitrateMbps,
      videoDrops: stopped ? 0 : losses.0 + losses.1 + poolDrops + cameraDrops,
      cameraOutputActive: cameraConnected, cameraMessage: cameraMessage, stopped: stopped)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrent(token) else { return }
      self.onUpdate?(update)
    }
  }
}

private struct CapturedFrame: @unchecked Sendable {
  let image: CVPixelBuffer
  let pts: CMTime
  let duration: CMTime
  let receivedAt: Double
  let sequence: UInt64
}

private struct InputFormat: Equatable {
  let width: Int
  let height: Int
  let type: OSType
  let duration: CMTime

  var label: String {
    let color: String
    switch type {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: color = "4:2:0 8-bit"
    case kCVPixelFormatType_422YpCbCr10, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: color = "4:2:2 10-bit"
    default: color = "Unknown color format"
    }
    let rate = duration.isNumeric && duration.seconds > 0 ? String(format: "%.2f fps", 1 / duration.seconds) : "Rate unknown"
    return "\(width) × \(height) · \(VideoContract.fourCC(type)) · \(color) · \(rate)"
  }
}

/// Owns one capture controller per configured feed.  A controller is created
/// lazily, so idle feeds allocate no Metal, CMIO, or DeckLink resources.  The
/// default factory calls `CaptureController()` for each feed; that in turn
/// creates an independent `CaptureServices.live()` value and therefore an
/// independent UltracamBackend control queue, DeckLink input lease, and camera
/// sink.  The initial map lets the legacy primary UI keep its existing
/// preview-renderer-backed controller while joining the same ownership model.
final class FeedCapturePool: @unchecked Sendable {
  typealias Factory = (FeedID) -> CaptureController

  private let lock = NSLock()
  private let factory: Factory
  private var controllers: [FeedID: CaptureController]

  init(initial: [FeedID: CaptureController] = [:], factory: @escaping Factory = { feedID in
    CaptureController(services: .live(feedID: feedID))
  }) {
    controllers = initial
    self.factory = factory
  }

  /// Returns the stable controller for a feed, creating it once on demand.
  func controller(for feedID: FeedID) -> CaptureController {
    lock.withLock {
      if let existing = controllers[feedID] { return existing }
      let created = factory(feedID)
      controllers[feedID] = created
      return created
    }
  }

  /// Returns an existing controller without warming a new capture pipeline.
  func existingController(for feedID: FeedID) -> CaptureController? {
    lock.withLock { controllers[feedID] }
  }

  var feedIDs: [FeedID] {
    lock.withLock { Array(controllers.keys) }
  }

  /// Stops and releases an idle feed controller.  An active controller stays
  /// owned until its caller stops it, preventing a late callback from being
  /// routed into a replacement backend for the same feed ID.
  @discardableResult
  func remove(_ feedID: FeedID) -> Bool {
    lock.lock()
    guard let controller = controllers[feedID] else {
      lock.unlock()
      return true
    }
    if controller.hasActiveFeed {
      lock.unlock()
      return false
    }
    lock.unlock()
    // Release the device before dropping the controller. Do not hold this
    // lock across the capture queue: stop syncs when invoked off that queue.
    // A start that wins the generation race keeps the live controller.
    guard let token = controller.stopReleasingResources() else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard controllers[feedID] === controller else { return true }
    guard controller.retireIfStillStopped(token) else { return false }
    controllers.removeValue(forKey: feedID)
    return true
  }

  func stop(_ feedID: FeedID) {
    existingController(for: feedID)?.stop()
  }

  func stopAll() {
    let active = lock.withLock { Array(controllers.values) }
    active.forEach { $0.stop() }
  }
}

struct CaptureServices: @unchecked Sendable {
  var start: (String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void
  var startWithMedia: ((String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  var startWithRawAudio: ((String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    @escaping (CaptureRawAudio) -> Void, @escaping (String) -> Void) throws -> Void)?
  var startWithSourceAudio: ((String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void, @escaping (CaptureRawAudio) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  var stop: () -> Void
  var connect: (PipelineConfiguration, OSType) throws -> Void
  var disconnect: () -> Void
  var send: (CMSampleBuffer) throws -> Bool
  var preview: ((CMSampleBuffer) -> Void)?
  var didProcess: (Double, Double) -> Void = { _, _ in }
  var startAutomatic: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void)?
  var startAutomaticWithMedia: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  var startAutomaticWithRawAudio: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void,
    @escaping (CaptureRawAudio) -> Void, @escaping (String) -> Void) throws -> Void)?
  var startAutomaticWithSourceAudio: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void, @escaping (CaptureRawAudio) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  // Known backend storage layout is used only to prepare transport memory;
  // displayed input metadata always comes from received buffers and duration.
  var capturePixelFormat: OSType?
  var hostTime: () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
  var cameraRetryInterval: TimeInterval = 2

  static func live(feedID: FeedID? = nil) -> CaptureServices {
    let backend = UltracamBackend()
    let sink = CameraSink(feedID: feedID)
    return CaptureServices(
      start: { id, fast, frame, event in
        try backend.start(deviceID: id, inputFast: fast, frameHandler: frame, eventHandler: event)
      },
      startWithMedia: { id, fast, frame, media, event in
        try backend.start(deviceID: id, inputFast: fast, frameHandler: frame,
          mediaHandler: { tc, packetTime, frames, channels, lp, rp, lr, rr, bytes, present in
            media(CaptureMediaStats(timecode: tc, audioPacketTime: packetTime,
              audioSampleFrames: UInt64(frames), audioChannels: Int(channels),
              leftPeak: Double(lp), rightPeak: Double(rp), leftRMS: Double(lr), rightRMS: Double(rr),
              audioBytes: UInt64(bytes), audioPresent: present))
          }, eventHandler: event)
      },
      startWithRawAudio: { id, fast, frame, audio, event in
        try backend.start(deviceID: id, inputFast: fast, frameHandler: frame,
          rawAudioHandler: { samples, packetTime, frames, channels, bytesPerSample in
            audio(CaptureRawAudio(samples: samples, packetTime: packetTime,
              sampleFrames: UInt64(frames), channels: Int(channels),
              bytesPerSample: Int(bytesPerSample)))
          }, eventHandler: event)
      },
      startWithSourceAudio: { id, fast, frame, media, audio, event in
        try backend.start(deviceID: id, inputFast: fast, frameHandler: frame,
          mediaHandler: { tc, packetTime, frames, channels, lp, rp, lr, rr, bytes, present in
            media(CaptureMediaStats(timecode: tc, audioPacketTime: packetTime,
              audioSampleFrames: UInt64(frames), audioChannels: Int(channels),
              leftPeak: Double(lp), rightPeak: Double(rp), leftRMS: Double(lr), rightRMS: Double(rr),
              audioBytes: UInt64(bytes), audioPresent: present))
          }, rawAudioHandler: { samples, packetTime, frames, channels, bytesPerSample in
            audio(CaptureRawAudio(samples: samples, packetTime: packetTime,
              sampleFrames: UInt64(frames), channels: Int(channels),
              bytesPerSample: Int(bytesPerSample)))
          }, eventHandler: event)
      },
      stop: { backend.stop() },
      connect: { config, format in try sink.connect(configuration: config, passthroughFormat: format) },
      disconnect: { sink.disconnect() },
      send: { try sink.send($0) },
      startAutomatic: { id, frame, event in
        try backend.startAuto(deviceID: id, frameHandler: frame, eventHandler: event)
      },
      startAutomaticWithMedia: { id, frame, media, event in
        try backend.startAuto(deviceID: id, frameHandler: frame,
          mediaHandler: { tc, packetTime, frames, channels, lp, rp, lr, rr, bytes, present in
            media(CaptureMediaStats(timecode: tc, audioPacketTime: packetTime,
              audioSampleFrames: UInt64(frames), audioChannels: Int(channels),
              leftPeak: Double(lp), rightPeak: Double(rp), leftRMS: Double(lr), rightRMS: Double(rr),
              audioBytes: UInt64(bytes), audioPresent: present))
          }, eventHandler: event)
      },
      startAutomaticWithRawAudio: { id, frame, audio, event in
        try backend.startAuto(deviceID: id, frameHandler: frame,
          rawAudioHandler: { samples, packetTime, frames, channels, bytesPerSample in
            audio(CaptureRawAudio(samples: samples, packetTime: packetTime,
              sampleFrames: UInt64(frames), channels: Int(channels),
              bytesPerSample: Int(bytesPerSample)))
          }, eventHandler: event)
      },
      startAutomaticWithSourceAudio: { id, frame, media, audio, event in
        try backend.startAuto(deviceID: id, frameHandler: frame,
          mediaHandler: { tc, packetTime, frames, channels, lp, rp, lr, rr, bytes, present in
            media(CaptureMediaStats(timecode: tc, audioPacketTime: packetTime,
              audioSampleFrames: UInt64(frames), audioChannels: Int(channels),
              leftPeak: Double(lp), rightPeak: Double(rp), leftRMS: Double(lr), rightRMS: Double(rr),
              audioBytes: UInt64(bytes), audioPresent: present))
          }, rawAudioHandler: { samples, packetTime, frames, channels, bytesPerSample in
            audio(CaptureRawAudio(samples: samples, packetTime: packetTime,
              sampleFrames: UInt64(frames), channels: Int(channels),
              bytesPerSample: Int(bytesPerSample)))
          }, eventHandler: event)
      }, capturePixelFormat: kCVPixelFormatType_422YpCbCr10)
  }
}
