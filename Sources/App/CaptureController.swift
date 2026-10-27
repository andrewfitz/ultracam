import CoreVideo
import CoreMedia
import Foundation
import os

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
  /// Capture-to-delivery time of the latest frame: GPU queueing plus GPU work.
  var processingMS: Double = 0
  var previewDelivered = false
  var sourceDrops: UInt64 = 0
  /// Frames the capture device itself reported dropped (DeckLink).
  var deviceDrops: UInt64 = 0
  /// Output stalls: frames that could not get an output buffer because a
  /// consumer held every one (`VideoContract.outputBufferLimit`).
  var poolDrops: UInt64 = 0
  /// Camera stalls and failures: the CMIO queue was full or the send failed.
  var cameraDrops: UInt64 = 0
  var outputFPS: Double = 0
  /// Frames committed to the GPU and not yet complete, now and at most.
  var framesInFlight = 0
  var maxFramesInFlight = 0
  /// Frames received from the driver and waiting for the capture queue.
  var captureBacklog = 0
  var maxCaptureBacklog = 0
  /// Frames whose processing began more than two frame intervals after capture.
  var lateFrames: UInt64 = 0
  /// Latest frame: GPU execution time, capture-thread CPU time to encode it,
  /// and capture callback → camera/preview hand-off.
  var gpuMS: Double = 0
  var captureCPUMS: Double = 0
  var latencyMS: Double = 0
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
  /// This capture's embedded-audio packets left out of the broadcast meters
  /// because the meter queue fell a full hand-off ring behind
  /// (`AudioMeterTap.Counters.coalesced` since the capture started; 0 when
  /// stopped). A meter-only loss: recording and video got every packet and frame.
  var audioMeterCoalesced: UInt64 = 0
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

// Queues:
// - capture (`queue`): owns configuration, detection, the camera connection
//   state machine and the processor. Validates, gates and encodes each frame,
//   commits it to the GPU and returns; it never waits for a frame's GPU work.
// - delivery: fans each completed frame out (monitor, Program, preview,
//   camera) in commit order, after its GPU work finished.
// - control: virtual camera connect/disconnect (up to seconds), so it never
//   blocks the frame path.
// - watchdog: the signal/GPU watchdog timer, on its own queue so a slow
//   camera connect can't delay it.
// Every frame the driver delivers is processed; nothing is dropped for being
// busy. A stage that can't keep up shows up as a counted, visible stall.
final class CaptureController: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.ultracam.capture", qos: .userInteractive)
  private let deliveryQueue = DispatchQueue(label: "org.ultracam.capture.delivery", qos: .userInteractive)
  private let controlQueue = DispatchQueue(label: "org.ultracam.capture.control", qos: .userInitiated)
  private let watchdogQueue = DispatchQueue(label: "org.ultracam.capture.watchdog", qos: .userInitiated)
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let controlKey = DispatchSpecificKey<UInt8>()
  private let lock = NSLock()
  /// This capture's broadcast audio meters: handed each packet on the driver
  /// thread while shown, metered on the tap's own queue.
  let audioMeterTap = AudioMeterTap()
  private var generation: UInt64 = 0
  private var accepting = false
  private var activeFeedID: FeedID?
  /// One feed's installed recording callbacks (one take). A take starts on
  /// video: its audio is forwarded only after the take admitted its first
  /// frame. Callbacks installed between one DeckLink callback's frame and its
  /// audio would otherwise open the take on that audio, and the writer, which
  /// starts its session at the earliest sample, would begin the movie with a
  /// frame of no picture.
  private struct RecordingRoute {
    let callbacks: SourceRecordingCallbackAdapter.Callbacks
    /// `recordingCallbackGeneration` at install: names this take's callbacks.
    let install: UInt64
    var videoStarted = false
  }
  private var recordingCallbacks: [FeedID: RecordingRoute] = [:]
  // Bumped under `lock` on every setRecordingCallbacks. stop()'s queued
  // cleanup captures the value it observed and must not delete a newer map.
  private var recordingCallbackGeneration: UInt64 = 0
  // FeedCapturePool sets this only after it has released the device. A start
  // on that discarded object must not open a second backend.
  private var retiredFromPool = false
  // Under `lock`: driver-thread bookkeeping and pipeline depth.
  private var sourceDrops: UInt64 = 0
  private var sourceDuration = VideoContract.fastDuration
  private var lastSourcePTS: CMTime?
  private var lastReceived: Double = 0
  private var queuedFrames = 0
  private var maxQueuedFrames = 0
  // The processor, for the watchdog and status (thread-safe accessors only).
  private var gpuProcessor: LUTProcessor?
  // The processor's loaded LUT, and whether the effective configuration burns
  // it in (Apply LUT on, pipeline on), for the monitor's feed.
  private var loadedLUT: MonitorLUT?
  private var burnInActive = false
  private var gpuStallReported = false
  private var rawAudioProvidesStats = false
  private var processedFrameHandler: ((ProcessedFrame<CVPixelBuffer>, UInt64) -> Void)?
  private let media = MediaState()
  private let camera = CameraLink()
  private let services: CaptureServices
  private var monitorSink: (any MonitorFrameSink)?
  private var monitorLifecycleSink: (any MonitorFrameSink)?
  private var monitorSequence: UInt64 = 0
  // Delivery-queue owned.
  private let sampleFactory = VideoSampleFactory()
  private var processor: LUTProcessor?
  private var configuration = PipelineConfiguration()
  private var pipelineEnabled = true
  private var previewEnabled = true
  private var activeConfiguration: PipelineConfiguration?
  private var activeInputType: OSType?
  private var preparedConfiguration: PipelineConfiguration?
  private var detected: InputFormat?
  private var renderedFormat: InputFormat?
  private var inputMetadataChanged = false
  private var inputLabel = "No signal"
  private var outputLabel = ""
  private var applied: Bool?
  private var frames: UInt64 = 0
  private var cameraDrops: UInt64 = 0
  private var poolDrops: UInt64 = 0
  private var lateFrames: UInt64 = 0
  // Source → host clock mapping, advanced at encode time in commit order.
  private var firstSourceTime: CMTime?
  private var firstHostTime: CMTime = .zero
  private var lastMappedSourceTime: CMTime?
  private var lastMappedHostTime: CMTime?
  private var lastDeliveredSourceTime: CMTime?
  private var rateStart: Double = 0
  private var rateFrames: UInt64 = 0
  private var outputFPS: Double = 0
  private var processingMS: Double = 0
  private var gpuMS: Double = 0
  private var captureCPUMS: Double = 0
  private var latencyMS: Double = 0
  private var videoRateStart: Double = 0
  private var videoRateBytes: UInt64 = 0
  private var videoBitrateMbps = 0.0
  /// `audioMeterTap.counters.coalesced` when this capture started; capture queue.
  private var audioMeterCoalescedAtStart: UInt64 = 0
  private var lastPublished: Double = 0
  // `fail` and the app's stopped-update handler both call `stop`. Without
  // this latch every stopped publish schedules another one.
  private var stopNotified = false
  // Camera connection state machine (capture queue). `cameraAttempt` mirrors
  // the CameraLink attempt; a frame carries the attempt it was encoded under
  // and is sent only through that same connection.
  private var cameraConnected = false
  private var cameraConnecting = false
  private var cameraAttempt: UInt64 = 0
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
  // Capture queue: virtual camera output reporting. The first send after a
  // connect, and full-queue windows: the first full send at once, then the
  // counts at most every five seconds while it lasts.
  private var cameraFirstSendPending = false
  private var cameraWasStalled = false
  private var cameraWindowStart: Double = 0
  private var cameraWindowSent: UInt64 = 0
  private var cameraWindowFull: UInt64 = 0
  private var cameraLabel: String { activeFeed?.rawValue ?? "an idle controller" }
  // Program output consumes processed frames through FeedCoordinator. When it
  // is enabled, this controller keeps capture and GPU work alive without
  // opening a per-feed CMIO sink; the Program bridge owns that sink.
  private var cameraOutputEnabled = true

  var onUpdate: (@Sendable (CaptureUpdate) -> Void)?
  /// Carries the capture generation that produced the frame. Consumers that
  /// hop to another queue must compare this token before publishing so a
  /// callback already in flight cannot enter a later start session.
  /// Called on the delivery queue, in capture order, after GPU completion,
  /// and after the frame's preview and camera hand-off. Set from any thread
  /// (stored under the lock; each frame reads it once at encode).
  var onProcessedFrame: ((ProcessedFrame<CVPixelBuffer>, UInt64) -> Void)? {
    get { lock.withLock { processedFrameHandler } }
    set { lock.withLock { processedFrameHandler = newValue } }
  }

  var activeFeed: FeedID? { lock.withLock { activeFeedID } }

  /// Identifies the latest start/stop generation for lifecycle consumers.
  /// This is separate from FeedSession's state generation because callers may
  /// stop the native controller more than once during one session teardown.
  var generationToken: UInt64 { lock.withLock { generation } }

  init(services: CaptureServices) {
    self.services = services
    queue.setSpecific(key: queueKey, value: 1)
    controlQueue.setSpecific(key: controlKey, value: 1)
    // The over log names the source timecode at the over, read from the
    // capture (under its media lock, on the meter queue), not from a view.
    audioMeterTap.setTimecodeSource { [media] in media.snapshot().timecode }
  }

  deinit {
    // Every executing controller operation retains self, and so does every
    // committed GPU frame and queued delivery. Final release therefore has
    // exclusive resource access, even if its owner omitted an explicit Stop.
    // Keep teardown on the capture queue; services and renderer state are
    // queue-owned and deinit may run on an arbitrary owner thread.
    syncOnQueue { stopResources() }
    flushControlQueue()
  }

  /// Waits for queued camera connect/disconnect work. Never called from the
  /// control queue, which never waits on the capture queue.
  private func flushControlQueue() {
    guard DispatchQueue.getSpecific(key: controlKey) == nil else { return }
    controlQueue.sync {}
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
      closeCamera()
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

  /// The LUT this camera burns in, nil while it burns none in (Apply LUT off,
  /// LUT forgotten, complete bypass, nothing loaded): the same immutable
  /// `MonitorLUT` the app built for the load, so the monitor's output stage
  /// (`MonitorFeed.burnInLUT`) shows exactly what Program, recording and the
  /// virtual camera get. Follows each configuration change. Thread-safe.
  var burnInLUT: MonitorLUT? { lock.withLock { burnInActive ? loadedLUT : nil } }

  /// Capture queue: publishes whether frames burn the loaded LUT in, as
  /// `effectiveConfiguration` decides for each frame.
  private func publishBurnIn() {
    let active = pipelineEnabled && configuration.applyLUT
    lock.withLock { burnInActive = active }
  }

  /// Burns `lut` in from the next frame (no wait for frames in flight).
  /// `lut` must be on `LUTProcessor.sharedDevice`, tetrahedral (the app's only
  /// interpolation).
  func load(_ lut: MonitorLUT, expectedGeneration: UInt64? = nil,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async {
      do {
        if let expectedGeneration, !self.isCurrent(expectedGeneration) {
          throw VideoError.message("Camera changed before its LUT finished loading.")
        }
        try self.makeProcessor().load(lut)
        self.lock.withLock { self.loadedLUT = lut }
        lutLog.notice("LUT \"\(lut.cube.title, privacy: .public)\" in the pipeline of \(self.cameraLabel, privacy: .public) (controller \(UInt(bitPattern: ObjectIdentifier(self).hashValue), format: .hex, privacy: .public)); burned in: \(self.pipelineEnabled && self.configuration.applyLUT, privacy: .public)")
        DispatchQueue.main.async { completion(.success(())) }
      } catch {
        lutLog.error("LUT not loaded into \(self.cameraLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  /// Uploads `cube` on the shared device, then `load(_:)`s it (tests, tools).
  func load(_ cube: CubeLUT, expectedGeneration: UInt64? = nil,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    let lut: MonitorLUT
    do { lut = try LUTProcessor.makeLUT(cube) } catch {
      DispatchQueue.main.async { completion(.failure(error)) }
      return
    }
    load(lut, expectedGeneration: expectedGeneration, completion: completion)
  }

  func start(feedID: FeedID, deviceID: String, configuration: PipelineConfiguration,
    pipelineEnabled: Bool = true, previewEnabled: Bool = true) {
    let token = lock.withLock { () -> UInt64? in
      if retiredFromPool { return nil }
      generation &+= 1
      accepting = false
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
        self.publishBurnIn()
        self.previewEnabled = previewEnabled
        let lutTitle = self.lock.withLock { self.loadedLUT?.cube.title }
        self.logger.notice("Start \(self.cameraLabel, privacy: .public) on controller \(UInt(bitPattern: ObjectIdentifier(self).hashValue), format: .hex, privacy: .public): processing \(pipelineEnabled ? "on" : "off", privacy: .public), Apply LUT \(configuration.applyLUT ? "on" : "off", privacy: .public), LUT in memory: \(lutTitle ?? "none", privacy: .public), burned in: \(pipelineEnabled && configuration.applyLUT && lutTitle != nil, privacy: .public)")
        self.activeConfiguration = nil
        self.activeInputType = nil
        self.detected = nil
        self.inputLabel = "Waiting for detected input"
        self.outputLabel = ""
        self.applied = nil
        self.frames = 0
        self.cameraDrops = 0
        self.poolDrops = 0
        self.lateFrames = 0
        self.firstSourceTime = nil
        self.lastMappedSourceTime = nil
        self.lastMappedHostTime = nil
        self.lastDeliveredSourceTime = nil
        self.rateStart = 0
        self.rateFrames = 0
        self.outputFPS = 0
        self.processingMS = 0
        self.gpuMS = 0
        self.captureCPUMS = 0
        self.latencyMS = 0
        self.media.reset()
        self.audioMeterCoalescedAtStart = self.audioMeterTap.counters.coalesced
        // A new stream: its first packet does not follow the last one metered.
        self.audioMeterTap.noteGap()
        self.processor?.resetInFlightPeak()
        self.videoRateStart = 0
        self.videoRateBytes = 0
        self.videoBitrateMbps = 0
        self.lastPublished = 0
        self.lastLogged = 0
        self.frameRateGate = FrameRateGate()
        self.resetSampleFormat()
        self.cameraConnected = false
        self.cameraFirstSendPending = false
        self.cameraWasStalled = false
        self.cameraWindowStart = 0
        self.cameraWindowSent = 0
        self.cameraWindowFull = 0
        self.cameraMessage = "Waiting for detected input"
        // Connect and warm before enabling driver callbacks, so the first
        // frames find the camera and GPU ready. This connection waits for the
        // control queue; no frame can arrive yet. Later reconnects never block
        // capture. The remembered rate is provisional: the first validated
        // frame still establishes the exact contract, and only received data
        // sets metadata.
        let warm = self.effectiveConfiguration(inputFast: configuration.inputFast)
        if let type = self.services.capturePixelFormat {
          self.establish(warm, inputType: type, synchronous: true)
        } else if self.services.startAutomatic == nil {
          self.establish(warm, inputType: kCVPixelFormatType_422YpCbCr10, synchronous: true)
        }
        guard self.isCurrent(token) else {
          self.stopResources(preserveRecordingCallbacks: true)
          return
        }
        let hasPreview = previewEnabled && self.services.preview != nil
        // Every consumer that makes the first frame do GPU work, including a
        // headless Program source. The monitor is not one: it shows the source
        // (and the burn-in LUT in its own shader), so it never forces processing.
        let hasProgram = self.lock.withLock { self.processedFrameHandler != nil }
        if self.cameraConnected || hasPreview || hasProgram {
          if !warm.untouched { _ = try self.makeProcessor() }
          try self.ensurePrepared(warm, wait: true)
        }
        guard self.isCurrent(token) else {
          self.stopResources(preserveRecordingCallbacks: true)
          return
        }
        self.lock.withLock {
          self.accepting = true
          self.sourceDrops = 0
          self.lastSourcePTS = nil
          self.sourceDuration = configuration.inputFast ? VideoContract.fastDuration : VideoContract.slowDuration
          self.lastReceived = ProcessInfo.processInfo.systemUptime
          self.maxQueuedFrames = self.queuedFrames
          self.gpuStallReported = false
          self.rawAudioProvidesStats = false
        }
        // Driver events change capture-queue state (signal loss, fatal errors);
        // they are rare, so they stay on the capture queue.
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
        let mediaHandler: (CaptureMediaStats) -> Void = { [weak self] stats in
          self?.receiveMedia(stats, token: token)
        }
        if let automatic = self.services.startAutomatic {
          if let automaticWithSourceAudio = self.services.startAutomaticWithSourceAudio {
            try automaticWithSourceAudio(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, mediaHandler, { [weak self] audio in
              self?.receiveRawAudio(audio, token: token)
            }, event)
          } else if let automaticWithRawAudio = self.services.startAutomaticWithRawAudio {
            self.lock.withLock { self.rawAudioProvidesStats = true }
            try automaticWithRawAudio(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, { [weak self] audio in
              self?.receiveRawAudio(audio, token: token)
            }, event)
          } else if let automaticWithMedia = self.services.startAutomaticWithMedia {
            try automaticWithMedia(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, mediaHandler, event)
          } else {
            try automatic(deviceID, { [weak self] image, pts, duration, valid in
              self?.receive(image, at: pts, duration: duration, signalValid: valid, token: token)
            }, event)
          }
        } else if let startWithSourceAudio = self.services.startWithSourceAudio {
          try startWithSourceAudio(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, mediaHandler, { [weak self] audio in
            self?.receiveRawAudio(audio, token: token)
          }, event)
        } else if let startWithRawAudio = self.services.startWithRawAudio {
          self.lock.withLock { self.rawAudioProvidesStats = true }
          try startWithRawAudio(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, { [weak self] audio in
            self?.receiveRawAudio(audio, token: token)
          }, event)
        } else if let startWithMedia = self.services.startWithMedia {
          try startWithMedia(deviceID, configuration.inputFast, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, mediaHandler, event)
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
        self.startWatchdog(token: token)
      } catch { self.fail(error.localizedDescription, token: token) }
    }
  }

  /// Signal and GPU watchdog, on its own queue: it must still fire when the
  /// capture queue is busy or a camera connect holds the control queue. It
  /// only hops to the capture queue to act.
  private func startWatchdog(token: UInt64) {
    let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
    timer.schedule(deadline: .now() + 2, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let now = ProcessInfo.processInfo.systemUptime
      let state = self.lock.withLock { () -> (accepting: Bool, last: Double, stuck: Bool) in
        let accepting = self.generation == token && self.accepting
        let oldest = self.gpuProcessor?.inFlight.oldestCommit
        let stuck = accepting && !self.gpuStallReported && oldest.map { now - $0 > 2 } == true
        if stuck { self.gpuStallReported = true }
        return (accepting, self.lastReceived, stuck)
      }
      guard state.accepting else { return }
      if state.stuck {
        self.queue.async {
          self.fail("The GPU stopped responding: a frame has been on the GPU for over two seconds.", token: token)
        }
        return
      }
      guard now - state.last > 2 else { return }
      self.queue.async {
        guard self.isAccepting(token) else { return }
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
    watchdog = timer
    timer.resume()
  }

  func reconfigure(configuration: PipelineConfiguration, pipelineEnabled: Bool) {
    let token = lock.withLock { generation }
    queue.async {
      guard self.isAccepting(token) else { return }
      let changes = Self.describeChanges(from: self.configuration, pipeline: self.pipelineEnabled,
        to: configuration, pipeline: pipelineEnabled)
      self.logger.notice("Reconfigure \(self.cameraLabel, privacy: .public): \(changes, privacy: .public)")
      self.configuration = configuration
      self.pipelineEnabled = pipelineEnabled
      self.publishBurnIn()
      if !self.cameraConnected { self.reconnectRequested = true }
      self.applied = nil
      self.outputLabel = ""
      self.resetSampleFormat()
      self.message = self.detected == nil ? "Waiting for UltraStudio signal…" : "Updating output…"
      self.publishCurrent(token: token)
      // First new frame establishes the exact source-dependent output contract.
    }
  }

  /// "applyLUT off→on, downscale on→off", or "no change", for logs.
  static func describeChanges(from old: PipelineConfiguration, pipeline oldPipeline: Bool,
    to new: PipelineConfiguration, pipeline newPipeline: Bool) -> String {
    func flag(_ value: Bool) -> String { value ? "on" : "off" }
    var parts: [String] = []
    if oldPipeline != newPipeline { parts.append("processing \(flag(oldPipeline))→\(flag(newPipeline))") }
    if old.applyLUT != new.applyLUT { parts.append("applyLUT \(flag(old.applyLUT))→\(flag(new.applyLUT))") }
    if old.downscale != new.downscale { parts.append("downscale \(flag(old.downscale))→\(flag(new.downscale))") }
    if old.convertTo420 != new.convertTo420 { parts.append("4:2:0 \(flag(old.convertTo420))→\(flag(new.convertTo420))") }
    if old.reduceFrameRate != new.reduceFrameRate {
      parts.append("29.97 limit \(flag(old.reduceFrameRate))→\(flag(new.reduceFrameRate))")
    }
    if old.inputFast != new.inputFast { parts.append("input \(old.inputFast ? "59.94" : "29.97")→\(new.inputFast ? "59.94" : "29.97")") }
    return parts.isEmpty ? "no change" : parts.joined(separator: ", ")
  }

  func setPreviewEnabled(_ enabled: Bool) {
    let token = lock.withLock { generation }
    queue.async {
      guard self.isAccepting(token) else { return }
      self.previewEnabled = enabled
      self.publishCurrent(token: token)
    }
  }

  /// The monitor's endpoint for this camera: every frame's source buffer, in
  /// capture order, from the delivery queue.
  func setMonitorSink(_ sink: (any MonitorFrameSink)?) {
    lock.withLock { monitorLifecycleSink = sink }
    queue.async { self.monitorSink = sink }
  }

  func stop() {
    let request = makeStopRequest()
    request.sink?.invalidate(rejectingCaptureGeneration: request.stoppedGeneration)
    // Admission is dropped under the lock above. Cleanup stays queued so a
    // capture worker busy encoding cannot deadlock stop().
    queue.async { self.performStop(request) }
  }

  private struct StopRequest {
    var token: UInt64
    var stoppedGeneration: UInt64
    var callbackGeneration: UInt64
    var sink: (any MonitorFrameSink)?
  }

  private func makeStopRequest() -> StopRequest {
    lock.withLock {
      let stoppedGeneration = generation
      generation &+= 1
      accepting = false
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
    flushControlQueue()
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
      if let callbacks {
        recordingCallbacks[feedID] = RecordingRoute(callbacks: callbacks, install: recordingCallbackGeneration)
      } else {
        recordingCallbacks.removeValue(forKey: feedID)
      }
    }
  }

  func isAccepting(feedID: FeedID) -> Bool {
    lock.withLock { accepting && activeFeedID == feedID }
  }

  var hasActiveFeed: Bool {
    lock.withLock { accepting && activeFeedID != nil }
  }

  /// The latest embedded (RP188) timecode label, `HH:MM:SS;FF` when the source
  /// flags drop-frame. Recording reads it once at take start to follow the
  /// source's drop-frame flag. Thread-safe; nil without source timecode.
  var latestSourceTimecode: String? { media.snapshot().timecode }

  private func stopResources(preserveRecordingCallbacks: Bool = false,
    callbackGeneration: UInt64? = nil) {
    watchdog?.cancel()
    watchdog = nil
    if let activity = realtimeActivity { ProcessInfo.processInfo.endActivity(activity) }
    realtimeActivity = nil
    services.stop()
    closeCamera()
    // Committed frames reference GPU resources and are about to be delivered
    // (and discarded as stale). Wait for them before releasing anything.
    _ = processor?.waitUntilIdle(timeout: 2)
    reconnectAttempts = 0
    cameraOutage = false
    reconnectRequested = false
    reconnectAfter = 0
    cameraMessage = "Ultracam camera not connected"
    activeConfiguration = nil
    activeInputType = nil
    // Every completion is now queued for delivery, where the stale generation
    // is discarded.
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

  /// Stops sending at once and closes the virtual camera on the control
  /// queue. A pending connect for an older attempt is ignored when it lands.
  private func closeCamera() {
    camera.invalidate()
    cameraAttempt = camera.currentAttempt
    cameraConnected = false
    cameraConnecting = false
    let services = self.services
    controlQueue.async { services.disconnect() }
  }

  private func resetSampleFormat() {
    deliveryQueue.async { self.sampleFactory.reset() }
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

  /// Creates the processor on first demand and publishes it for the watchdog.
  private func makeProcessor() throws -> LUTProcessor {
    if let processor { return processor }
    let created = try LUTProcessor()
    processor = created
    lock.withLock {
      gpuProcessor = created
      gpuStallReported = false
    }
    return created
  }

  /// `wait` only before capture starts. On the live path the warm frames are
  /// committed ahead of the frame and the capture thread does not wait.
  private func ensurePrepared(_ next: PipelineConfiguration, wait: Bool) throws {
    if preparedConfiguration?.applyLUT != next.applyLUT || preparedConfiguration?.downscale != next.downscale ||
      preparedConfiguration?.convertTo420 != next.convertTo420 {
      try processor?.prepare(configuration: next, wait: wait)
      preparedConfiguration = next
    }
  }

  // MARK: - Virtual camera connection (capture-queue state, control-queue work)

  private func establish(_ next: PipelineConfiguration, inputType: OSType, synchronous: Bool = false) {
    let prior = activeConfiguration
    let priorType = activeInputType
    let sameContract = prior.map {
      $0.width == next.width && $0.height == next.height &&
        $0.pixelFormat == next.pixelFormat && $0.duration == next.duration &&
        $0.untouched == next.untouched && activeInputType == inputType
    } ?? false
    activeConfiguration = next
    activeInputType = inputType
    if sameContract {
      reconnectIfDue()
      return
    }
    if prior?.duration != next.duration { frameRateGate = FrameRateGate() }
    func describe(_ value: PipelineConfiguration?, _ type: OSType?) -> String {
      guard let value else { return "none" }
      return "\(value.width)×\(value.height) \(fourCC(value.untouched ? (type ?? 0) : value.pixelFormat)) " +
        "\(value.duration.value)/\(value.duration.timescale) s\(value.untouched ? " untouched" : "")"
    }
    cameraOutputLog.notice("Camera contract: \(self.cameraLabel, privacy: .public) \(describe(prior, priorType), privacy: .public) → \(describe(next, inputType), privacy: .public)\(self.cameraOutputEnabled ? "" : " (camera output off)", privacy: .public)")
    resetSampleFormat()
    guard cameraOutputEnabled else {
      if cameraConnected || cameraConnecting { closeCamera() }
      return
    }
    requestConnect(next, inputType: inputType, synchronous: synchronous)
  }

  /// Connects the virtual camera now if it should be and isn't: CMIO's cameras changed (the
  /// camera extension started after this camera did). A camera that never connected otherwise
  /// waits for a change of settings.
  func requestCameraReconnect() {
    let token = lock.withLock { generation }
    queue.async {
      guard self.isAccepting(token), self.cameraOutputEnabled, !self.cameraConnected, !self.cameraConnecting else { return }
      cameraOutputLog.notice("Camera reconnect requested: \(self.cameraLabel, privacy: .public) (virtual cameras changed)")
      self.reconnectRequested = true
      self.reconnectAfter = 0
      self.reconnectIfDue()
    }
  }

  /// Retries a lost camera (or an explicit reconfigure request) once its
  /// retry time has come. Driven by frames and by a timer.
  private func reconnectIfDue() {
    guard cameraOutputEnabled, !cameraConnected, !cameraConnecting,
      reconnectRequested || reconnectAttempts > 0,
      ProcessInfo.processInfo.systemUptime >= reconnectAfter,
      let next = activeConfiguration, let type = activeInputType else { return }
    if reconnectAttempts > 0 { reconnectAttempts -= 1 }
    cameraOutputLog.notice("Camera reconnect: \(self.cameraLabel, privacy: .public) (\(self.reconnectRequested ? "requested" : "recovering", privacy: .public), \(self.reconnectAttempts, privacy: .public) recovery attempts left)")
    requestConnect(next, inputType: type, synchronous: false)
  }

  private func scheduleReconnect() {
    guard cameraOutputEnabled, reconnectRequested || reconnectAttempts > 0 else { return }
    let token = lock.withLock { generation }
    let delay = max(0, reconnectAfter - ProcessInfo.processInfo.systemUptime)
    cameraOutputLog.notice("Camera reconnect scheduled: \(self.cameraLabel, privacy: .public) in \(String(format: "%.1f", delay), privacy: .public) s")
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.isAccepting(token) else { return }
      self.reconnectIfDue()
    }
  }

  private func requestConnect(_ next: PipelineConfiguration, inputType: OSType, synchronous: Bool) {
    let wasConnected = cameraConnected
    cameraConnected = false
    cameraConnecting = true
    reconnectRequested = false
    reconnectAfter = ProcessInfo.processInfo.systemUptime + max(0, services.cameraRetryInterval)
    let attempt = camera.begin()
    cameraAttempt = attempt
    let services = self.services, link = camera
    let work: @Sendable () -> Error? = {
      services.disconnect()
      do {
        try services.connect(next, inputType)
        // Open for sending immediately; frames encoded under this attempt
        // need not wait for the capture queue to learn the result.
        _ = link.enable(attempt)
        return nil
      } catch { return error }
    }
    if synchronous {
      finishConnect(attempt, error: controlQueue.sync(execute: work), wasConnected: wasConnected)
    } else {
      controlQueue.async {
        let error = work()
        self.queue.async { self.finishConnect(attempt, error: error, wasConnected: wasConnected) }
      }
    }
  }

  private func finishConnect(_ attempt: UInt64, error: Error?, wasConnected: Bool) {
    guard attempt == cameraAttempt, cameraConnecting else { return }
    cameraConnecting = false
    if let error {
      cameraMessage = "Camera output unavailable — \(error.localizedDescription)"
      // Only a lost connection retries; a camera that never connected
      // (extension not running) stays quiet until the user reconfigures.
      if wasConnected { beginCameraRecovery() }
      scheduleReconnect()
    } else {
      cameraConnected = true
      cameraFirstSendPending = true
      cameraMessage = "Ultracam camera connected. Choose it in your meeting app."
    }
  }

  /// Capture queue, per delivered frame: at most every five seconds while the
  /// queue has been full in the window, the frames the camera took and refused.
  private func reportCameraWindow() {
    let now = ProcessInfo.processInfo.systemUptime
    if cameraWindowStart == 0 { cameraWindowStart = now }
    guard now - cameraWindowStart >= 5 else { return }
    if cameraWindowFull > 0 {
      cameraOutputLog.error("Camera queue full: \(self.cameraLabel, privacy: .public): \(self.cameraWindowFull, privacy: .public) frames refused, \(self.cameraWindowSent, privacy: .public) taken in the last \(String(format: "%.0f", now - self.cameraWindowStart), privacy: .public) s")
    } else if cameraWasStalled {
      cameraWasStalled = false
      cameraOutputLog.notice("Camera queue flowing again: \(self.cameraLabel, privacy: .public), \(self.cameraWindowSent, privacy: .public) frames taken in the last \(String(format: "%.0f", now - self.cameraWindowStart), privacy: .public) s")
    }
    cameraWindowStart = now
    cameraWindowSent = 0
    cameraWindowFull = 0
  }

  private func beginCameraRecovery() {
    guard !cameraOutage else { return }
    cameraOutage = true
    reconnectAttempts = 3
  }

  // MARK: - Driver callbacks

  private func receive(_ image: CVPixelBuffer, at pts: CMTime, duration: CMTime?,
    signalValid: Bool, token: UInt64) {
    // One lock acquisition per frame on the driver thread (two on a take's first frame).
    let admitted = lock.withLock { () -> (RecordingRoute?, CMTime, UInt64?, FeedID?)? in
      guard generation == token, accepting else { return nil }
      let feed = activeFeedID
      let route = feed.flatMap { recordingCallbacks[$0] }
      let recordingDuration = duration ?? sourceDuration
      guard signalValid else { return (route, recordingDuration, nil, feed) }
      let now = ProcessInfo.processInfo.systemUptime
      lastReceived = now
      let frameDuration = duration ?? sourceDuration
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
      monitorSequence &+= 1
      queuedFrames += 1
      maxQueuedFrames = max(maxQueuedFrames, queuedFrames)
      return (route, frameDuration, monitorSequence, feed)
    }
    guard let admitted else { return }
    // Recording takes every valid source frame directly on the driver thread,
    // independent of processing. Metadata-only checks: no pixel scan,
    // conversion or waiting. Malformed inputs stay out of the recorder while
    // its invalid-sample telemetry and processing's error reporting remain.
    if let route = admitted.0 {
      let duration = admitted.1
      let validRecordingFrame = signalValid && pts.isNumeric && pts.epoch == 0 && pts.value >= 0 &&
        duration.epoch == 0 &&
        (duration == VideoContract.fastDuration || duration == VideoContract.slowDuration) &&
        CVPixelBufferGetWidth(image) == 3840 && CVPixelBufferGetHeight(image) == 2160 &&
        VideoContract.tenBit422.contains(CVPixelBufferGetPixelFormatType(image)) &&
        (try? VideoBufferLayout.validate(image)) != nil
      // The take's first admitted frame opens it to audio, on this thread
      // before this callback's audio arrives; a newer install starts over.
      if route.callbacks.video(image, pts, duration, validRecordingFrame), !route.videoStarted,
        let feed = admitted.3 {
        lock.withLock {
          if recordingCallbacks[feed]?.install == route.install { recordingCallbacks[feed]?.videoStarted = true }
        }
      }
    }
    guard let sequence = admitted.2 else { return }
    let frame = CapturedFrame(image: image, pts: pts, duration: admitted.1,
      receivedAt: ProcessInfo.processInfo.systemUptime, sequence: sequence)
    queue.async {
      // DeckLink callbacks arrive at video cadence for hours. CoreMedia and
      // AVFoundation create autoreleased wrappers while a frame is encoded;
      // drain them after each serial work item.
      autoreleasepool {
        defer { self.lock.withLock { self.queuedFrames -= 1 } }
        guard self.isAccepting(token) else { return }
        self.process(frame, token: token)
      }
    }
  }

  /// Media statistics are a few counters under their own lock, recorded on
  /// the driver thread: never queued behind video, never dropped.
  private func receiveMedia(_ stats: CaptureMediaStats, token: UInt64) {
    guard isAccepting(token) else { return }
    media.record(stats)
  }

  private func receiveRawAudio(_ audio: CaptureRawAudio, token: UInt64) {
    let state = lock.withLock { () -> (SourceRecordingCallbackAdapter.Callbacks?, Bool)? in
      guard generation == token, accepting else { return nil }
      // A take takes audio from its first frame on (see `RecordingRoute`).
      let route = activeFeedID.flatMap { recordingCallbacks[$0] }
      return (route.flatMap { $0.videoStarted ? $0.callbacks : nil }, rawAudioProvidesStats)
    }
    guard let state else { return }
    let validRawFormat = audio.bytesPerSample == EmbeddedAudioFormat.sourceBytesPerSample
    if let samples = audio.samples, audio.sampleFrames > 0, audio.channels > 0, validRawFormat {
      _ = state.0?.rawAudio(samples, Int(audio.sampleFrames), audio.packetTime,
        audio.channels, audio.bytesPerSample)
    }
    if state.1 {
      receiveMedia(CaptureMediaStats(timecode: nil, audioPacketTime: audio.packetTime,
        audioSampleFrames: audio.sampleFrames, audioChannels: audio.channels,
        leftPeak: 0, rightPeak: 0, leftRMS: 0, rightRMS: 0,
        audioBytes: UInt64(audio.samples?.count ?? 0), audioPresent: audio.samples != nil), token: token)
    }
    // Last, after the generation guard: recording admission never waits on the
    // meters, and a stopped stream's packets are never metered. The tap only
    // hands the packet to its meter queue (a retain and an atomic publish);
    // the metering itself never runs on the driver thread.
    audioMeterTap.ingest(audio)
  }

  // MARK: - Frame path

  private func process(_ frame: CapturedFrame, token: UInt64) {
    let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let input = frame.image
    videoRateBytes &+= UInt64(max(0, CVPixelBufferGetDataSize(input)))
    let actual = InputFormat(width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input),
      type: CVPixelBufferGetPixelFormatType(input), duration: frame.duration)
    let metadataChanged = detected != actual
    if detected != actual {
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
      establish(effective, inputType: actual.type)
      let entryTime = ProcessInfo.processInfo.systemUptime
      let entryQueueAge = max(0, entryTime - frame.receivedAt)
      if entryQueueAge > 2 * actual.duration.seconds { lateFrames &+= 1 }
      // Every monitor offer is made on the delivery queue, in capture order:
      // the source frame only, when the GPU work completes (and for frames
      // that skip the GPU, ordered behind the frames still on it). The
      // monitor never keeps processing alive on its own.
      let sink = monitorSink
      let hasPreview = previewEnabled && services.preview != nil
      let processedHandler = lock.withLock { processedFrameHandler }
      // No downstream demand: keep metadata/detection alive without allocating,
      // submitting GPU work or staging raw buffers that nobody can consume.
      guard cameraConnected || cameraConnecting || hasPreview || processedHandler != nil else {
        if let sink { offerSourceOnlyInOrder(sink, frame: frame, token: token, untouched: effective.untouched) }
        if preparedConfiguration != nil {
          processor?.releaseIdleResources()
          preparedConfiguration = nil
        }
        applied = nil
        outputLabel = ""
        processingMS = 0
        outputFPS = 0
        message = "Camera ready — no active video destination."
        publishIfDue(token: token, force: metadataChanged)
        return
      }
      // Temporal selection happens before any GPU work or buffer allocation;
      // complete bypass keeps the source duration and so every frame.
      guard frameRateGate.shouldDeliver(frame.pts, duration: effective.duration) else {
        if let sink { offerSourceOnlyInOrder(sink, frame: frame, token: token, untouched: effective.untouched) }
        return
      }
      // Created on first demand; a complete bypass still uses it for the owned GPU copy.
      let processor = try makeProcessor()
      try ensurePrepared(effective, wait: false)
      let item = DeliveryItem(token: token, sequence: frame.sequence, source: sink == nil ? nil : input,
        pts: frame.pts, hostTime: hostTime(for: frame.pts, duration: effective.duration, image: input),
        duration: effective.duration, receivedAt: frame.receivedAt, encodeStart: entryTime,
        pipelineEnabled: pipelineEnabled, applyLUT: effective.applyLUT,
        preview: previewEnabled ? services.preview : nil,
        cameraAttempt: cameraAttempt, monitorSink: sink, untouched: effective.untouched,
        processedHandler: processedHandler)
      let completion: LUTProcessor.Completion = { [self] completed in
        // GPU completion queue: the frame is finished. Hand it to delivery in
        // commit order (the processor releases completions in order).
        deliveryQueue.async { autoreleasepool { self.deliver(item, completed) } }
      }
      if effective.untouched {
        // The preview, the meeting-app camera and Program get an owned copy;
        // the capture card may reuse its buffer while they still display it.
        try processor.submitPassthrough(input, isCurrent: { isAccepting(token) }, completion: completion)
      } else {
        try processor.submit(input, configuration: effective, isCurrent: { isAccepting(token) },
          completion: completion)
      }
      captureCPUMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
      // The delivered frame publishes the new input metadata.
      if metadataChanged { inputMetadataChanged = true }
    } catch VideoError.outputBackPressure {
      poolDrops &+= 1
      message = VideoError.outputBackPressure.localizedDescription
      // The first stall is shown at once; a sustained one updates at the
      // normal status rate instead of a main-actor hop per frame.
      publishIfDue(token: token, force: poolDrops == 1)
    } catch VideoError.cancelled {
      return
    } catch { fail(error.localizedDescription, token: token) }
  }

  /// A monitor offer for a frame that skips the GPU (no other consumer, or
  /// removed by the frame-rate gate). Ordered behind every frame already on
  /// the GPU, whose offers are made when they complete.
  private func offerSourceOnlyInOrder(
    _ sink: any MonitorFrameSink, frame: CapturedFrame, token: UInt64, untouched: Bool
  ) {
    let offer: @Sendable () -> Void = { [deliveryQueue] in
      deliveryQueue.async {
        sink.offer(frame.image, pts: frame.pts, captureGeneration: token, sequence: frame.sequence,
          untouched: untouched)
      }
    }
    if let processor { processor.afterCommittedFrames(offer) } else { offer() }
  }

  /// Delivery queue, in commit order, after the frame's GPU work completed.
  /// Monitor, preview and camera first; Program last, so a Program stall
  /// can't hold this camera's own outputs.
  private func deliver(_ item: DeliveryItem, _ completed: LUTProcessor.Completed) {
    let rendered: CVPixelBuffer
    switch completed.result {
    case .success(let output): rendered = output
    case .failure(let error):
      queue.async { self.fail(error.localizedDescription, token: item.token) }
      return
    }
    guard isAccepting(item.token) else { return }
    let timing = completed.timing
    let outputWidth = CVPixelBufferGetWidth(rendered), outputHeight = CVPixelBufferGetHeight(rendered)
    let outputType = CVPixelBufferGetPixelFormatType(rendered)
    if let sink = item.monitorSink, let source = item.source {
      sink.offer(source, pts: item.pts, captureGeneration: item.token, sequence: item.sequence,
        untouched: item.untouched)
    }
    let processingMS = (timing.completed - item.encodeStart) * 1000
    services.didProcess(processingMS, (item.encodeStart - item.receivedAt) * 1000)
    let sample: CMSampleBuffer
    do { sample = try sampleFactory.sample(rendered, at: item.hostTime, duration: item.duration) }
    catch {
      queue.async { self.fail(error.localizedDescription, token: item.token) }
      return
    }
    item.preview?(sample)
    let outcome = camera.send(sample, attempt: item.cameraAttempt, using: services.send)
    if let handler = item.processedHandler {
      let metadata = ProcessedFrameMetadata(
        presentationTime: item.pts, duration: item.duration,
        width: outputWidth, height: outputHeight, pixelFormat: UInt32(outputType))
      handler(ProcessedFrame(payload: rendered, metadata: metadata), item.token)
    }
    let report = DeliveryReport(item: item, outcome: outcome,
      output: InputFormat(width: outputWidth, height: outputHeight, type: outputType, duration: item.duration),
      processingMS: processingMS, gpuMS: timing.gpuMS,
      latencyMS: (ProcessInfo.processInfo.systemUptime - item.receivedAt) * 1000)
    queue.async { self.didDeliver(report) }
  }

  /// Capture queue: counters, camera recovery and status for a delivered frame.
  private func didDeliver(_ report: DeliveryReport) {
    let item = report.item
    guard isAccepting(item.token) else { return }
    var metadataChanged = inputMetadataChanged
    inputMetadataChanged = false
    switch report.outcome {
    case .sent:
      cameraWindowSent &+= 1
      if item.cameraAttempt == cameraAttempt {
        if cameraFirstSendPending || cameraOutage {
          cameraOutputLog.notice("Camera output \(self.cameraOutage ? "recovered" : "sending", privacy: .public): \(self.cameraLabel, privacy: .public), first frame accepted by the camera queue")
          cameraFirstSendPending = false
        }
        // An opened queue is not proof of recovery. Only a successful frame
        // send ends the outage and permits a fresh retry budget.
        cameraOutage = false
        reconnectAttempts = 0
      }
    case .full:
      // The extension's queue is full: it has stalled. Counted and shown.
      cameraDrops &+= 1
      cameraWindowFull &+= 1
      if !cameraWasStalled {
        cameraWasStalled = true
        cameraOutputLog.error("Camera queue full: \(self.cameraLabel, privacy: .public); the camera extension is not taking frames")
      }
    case .failed(let description):
      cameraDrops &+= 1
      cameraOutputLog.error("Camera send failed: \(self.cameraLabel, privacy: .public): \(description, privacy: .public); closing and reconnecting")
      if item.cameraAttempt == cameraAttempt {
        closeCamera()
        beginCameraRecovery()
        reconnectRequested = false
        reconnectAfter = ProcessInfo.processInfo.systemUptime + max(0, services.cameraRetryInterval)
        cameraMessage = "Camera output disconnected — \(description)"
        scheduleReconnect()
        metadataChanged = true
      }
    case .notSent: break
    }
    reportCameraWindow()
    frames &+= 1
    lastDeliveredSourceTime = item.pts
    processingMS = report.processingMS
    gpuMS = report.gpuMS
    latencyMS = report.latencyMS
    metadataChanged = metadataChanged || applied != item.pipelineEnabled
    applied = item.pipelineEnabled
    if renderedFormat != report.output || outputLabel.isEmpty {
      metadataChanged = true
      renderedFormat = report.output
      outputLabel = report.output.label
    }
    message = item.pipelineEnabled ? (item.applyLUT ? "Processing enabled — LUT applied" : "Processing enabled — LUT off") : "Complete bypass — original camera signal"
    publishIfDue(token: item.token, force: frames == 1 || metadataChanged)
  }

  /// Maps source time onto the host clock at encode time, in commit order.
  /// The DeckLink backend attaches the frame's hardware capture time on the
  /// host clock when it has one; that anchors the mapping instead of "now".
  private func hostTime(for sourceTime: CMTime, duration: CMTime, image: CVPixelBuffer) -> CMTime {
    let now: CMTime
    if let captured = (CVBufferCopyAttachment(image, UltracamCaptureHostTimeAttachmentKey as CFString, nil)
      as? NSNumber)?.doubleValue,
      captured.isFinite, captured > 0 {
      now = CMTime(seconds: captured, preferredTimescale: 1_000_000_000)
    } else {
      now = services.hostTime()
    }
    var reset = firstSourceTime == nil
    if let last = lastMappedSourceTime, CMTimeCompare(sourceTime, last) < 0 { reset = true }
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
      if let last = lastMappedHostTime {
        firstHostTime = CMTimeMaximum(firstHostTime, CMTimeAdd(last, duration))
      }
    }
    let mapped = CMTimeAdd(firstHostTime, CMTimeSubtract(sourceTime, firstSourceTime!))
    lastMappedSourceTime = sourceTime
    lastMappedHostTime = mapped
    return mapped
  }

  private func publishIfDue(token: UInt64, force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastPublished >= 0.25 else { return }
    let elapsed = now - rateStart
    outputFPS = rateStart == 0 ? 0 : Double(frames - rateFrames) / elapsed
    rateStart = now
    rateFrames = frames
    if videoRateStart == 0 { videoRateStart = now }
    if now - videoRateStart >= 0.25 {
      videoBitrateMbps = Double(videoRateBytes) * 8 / (now - videoRateStart) / 1_000_000
      videoRateBytes = 0
      videoRateStart = now
    }
    media.updateRates(now: now)
    lastPublished = now
    if now - lastLogged >= 5 {
      lastLogged = now
      let peak = processor?.inFlight.peak ?? 0
      let depth = lock.withLock { (sourceDrops, peak, maxQueuedFrames) }
      logger.notice("Live fps=\(self.outputFPS) delivered=\(self.frames) sourceDrops=\(depth.0) outputStalls=\(self.poolDrops) cameraStalls=\(self.cameraDrops) lateFrames=\(self.lateFrames) maxInFlight=\(depth.1) maxBacklog=\(depth.2) gpuMS=\(self.gpuMS) latencyMS=\(self.latencyMS)")
    }
    publishCurrent(token: token)
  }

  private func publishCurrent(token: UInt64, stopped: Bool = false) {
    let gpu = processor?.inFlight
    let depth = lock.withLock {
      (sourceDrops: sourceDrops, inFlight: gpu?.count ?? 0, maxInFlight: gpu?.peak ?? 0,
        backlog: queuedFrames, maxBacklog: maxQueuedFrames)
    }
    let deviceDrops = services.deviceDroppedFrames()
    let audio = media.snapshot()
    let visiblePreview = previewEnabled && services.preview != nil
    let videoLosses = depth.sourceDrops + deviceDrops + poolDrops + cameraDrops
    let update = CaptureUpdate(message: message, input: inputLabel, output: outputLabel,
      inputFast: detected.map { $0.duration == VideoContract.fastDuration }, sourceDuration: detected?.duration,
      mediaTime: stopped ? nil : lastDeliveredSourceTime,
      pipelineEnabledApplied: applied, frames: frames, dropped: videoLosses,
      processingMS: processingMS, previewDelivered: visiblePreview && !outputLabel.isEmpty && !stopped,
      sourceDrops: depth.sourceDrops, deviceDrops: deviceDrops, poolDrops: poolDrops, cameraDrops: cameraDrops,
      outputFPS: outputFPS,
      framesInFlight: depth.inFlight, maxFramesInFlight: depth.maxInFlight,
      captureBacklog: depth.backlog, maxCaptureBacklog: depth.maxBacklog, lateFrames: lateFrames,
      gpuMS: gpuMS, captureCPUMS: captureCPUMS, latencyMS: latencyMS,
      timecode: stopped ? nil : audio.timecode,
      audioChannels: stopped ? 0 : audio.channels, audioSampleRate: stopped ? 0 : audio.sampleRate,
      audioPackets: stopped ? 0 : audio.packets, audioSamples: stopped ? 0 : audio.samples,
      audioBytes: stopped ? 0 : audio.bytes, audioDrops: stopped ? 0 : audio.drops,
      audioPeakLeft: stopped ? 0 : audio.peakLeft, audioPeakRight: stopped ? 0 : audio.peakRight,
      audioRMSLeft: stopped ? 0 : audio.rmsLeft, audioRMSRight: stopped ? 0 : audio.rmsRight,
      audioBitrateKbps: stopped ? 0 : audio.bitrateKbps, audioPresent: stopped ? false : audio.present,
      audioPacketTime: stopped ? nil : audio.packetTime,
      audioMeterCoalesced: stopped ? 0 : audioMeterTap.counters.coalesced &- audioMeterCoalescedAtStart,
      videoBitrateMbps: stopped ? 0 : videoBitrateMbps,
      videoDrops: stopped ? 0 : videoLosses,
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

/// Everything delivery needs, frozen at encode time on the capture queue.
private struct DeliveryItem: @unchecked Sendable {
  let token: UInt64
  let sequence: UInt64
  /// The capture frame, kept for the monitor's offer when there is a monitor.
  let source: CVPixelBuffer?
  let pts: CMTime
  let hostTime: CMTime
  let duration: CMTime
  let receivedAt: Double
  let encodeStart: Double
  let pipelineEnabled: Bool
  let applyLUT: Bool
  let preview: ((CMSampleBuffer) -> Void)?
  let cameraAttempt: UInt64
  let monitorSink: (any MonitorFrameSink)?
  /// Published as captured (the passthrough copy): the monitor's offer says so.
  let untouched: Bool
  let processedHandler: ((ProcessedFrame<CVPixelBuffer>, UInt64) -> Void)?
}

private struct DeliveryReport: @unchecked Sendable {
  let item: DeliveryItem
  let outcome: CameraLink.Outcome
  let output: InputFormat
  let processingMS: Double
  let gpuMS: Double
  let latencyMS: Double
}

/// The open virtual camera connection, shared by the capture queue (which
/// opens and closes it through attempts), the control queue (which completes
/// a connect) and the delivery queue (which sends). Sending holds the lock, so
/// once `invalidate` returns no send is in progress or can start, and the
/// sink may be disconnected without racing a send.
private final class CameraLink: @unchecked Sendable {
  enum Outcome: Sendable {
    case notSent, sent, full
    case failed(String)
  }

  private let lock = NSLock()
  private var attempt: UInt64 = 0
  private var openAttempt: UInt64?

  var currentAttempt: UInt64 { lock.withLock { attempt } }

  func begin() -> UInt64 {
    lock.withLock {
      attempt &+= 1
      openAttempt = nil
      return attempt
    }
  }

  func invalidate() {
    lock.withLock {
      attempt &+= 1
      openAttempt = nil
    }
  }

  func enable(_ candidate: UInt64) -> Bool {
    lock.withLock {
      guard attempt == candidate else { return false }
      openAttempt = candidate
      return true
    }
  }

  func send(_ sample: CMSampleBuffer, attempt frameAttempt: UInt64,
    using send: (CMSampleBuffer) throws -> Bool) -> Outcome {
    lock.lock()
    defer { lock.unlock() }
    guard openAttempt == frameAttempt else { return .notSent }
    do { return try send(sample) ? .sent : .full }
    catch {
      openAttempt = nil
      return .failed(error.localizedDescription)
    }
  }
}

/// Audio and timecode statistics, written on the driver's media callback.
private final class MediaState: @unchecked Sendable {
  struct Snapshot {
    var timecode: String?
    var channels = 0
    var sampleRate = 0
    var packets: UInt64 = 0
    var samples: UInt64 = 0
    var bytes: UInt64 = 0
    var drops: UInt64 = 0
    var peakLeft = 0.0
    var peakRight = 0.0
    var rmsLeft = 0.0
    var rmsRight = 0.0
    var present = false
    var packetTime: CMTime?
    var bitrateKbps = 0.0
  }

  private let lock = NSLock()
  private var state = Snapshot()
  private var lastSampleFrames: UInt64 = 0
  private var rateStart: Double = 0
  private var rateBytes: UInt64 = 0

  func reset() {
    lock.withLock {
      state = Snapshot()
      lastSampleFrames = 0
      rateStart = 0
      rateBytes = 0
    }
  }

  func snapshot() -> Snapshot { lock.withLock { state } }

  func updateRates(now: Double) {
    lock.withLock {
      if rateStart == 0 { rateStart = now }
      let elapsed = now - rateStart
      guard elapsed >= 0.25 else { return }
      state.bitrateKbps = Double(rateBytes) * 8 / elapsed / 1_000
      rateBytes = 0
      rateStart = now
    }
  }

  func record(_ stats: CaptureMediaStats) {
    lock.withLock {
      state.timecode = stats.timecode
      state.channels = max(0, stats.audioChannels)
      state.packets &+= 1
      state.samples &+= stats.audioSampleFrames
      state.bytes &+= stats.audioBytes
      rateBytes &+= stats.audioBytes
      state.present = stats.audioPresent
      state.peakLeft = max(0, min(1, stats.leftPeak))
      state.peakRight = max(0, min(1, stats.rightPeak))
      state.rmsLeft = max(0, min(1, stats.leftRMS))
      state.rmsRight = max(0, min(1, stats.rightRMS))
      // The native input is always enabled at 48 kHz (the DeckLink callback
      // does not carry a sample-rate field). Use that fixed contract directly;
      // inferring a rate from the previous packet hides missing packets because
      // a gap makes the inferred rate fall in proportion to the gap.
      if stats.audioPresent && stats.audioSampleFrames > 0 {
        state.sampleRate = Int(EmbeddedAudioFormat.sampleRate)
      }
      let packetTime = stats.audioPacketTime
      guard packetTime.isNumeric, stats.audioSampleFrames > 0 else { return }
      if let prior = state.packetTime, prior.isNumeric {
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(packetTime, prior))
        if elapsed > 0 {
          let expected = Int((elapsed * EmbeddedAudioFormat.sampleRate).rounded())
          if expected > Int(lastSampleFrames) { state.drops &+= UInt64(expected - Int(lastSampleFrames)) }
        }
      }
      // Do not move the baseline backwards after a malformed/regressed packet;
      // the next valid packet should still be compared with the last source
      // clock position rather than silently masking the discontinuity.
      if let prior = state.packetTime, CMTimeCompare(packetTime, prior) < 0 { return }
      state.packetTime = packetTime
      lastSampleFrames = stats.audioSampleFrames
    }
  }
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
/// default factory makes a controller with its own `CaptureServices.live(feedID:)`
/// value and therefore an independent UltracamBackend control queue, DeckLink
/// input lease, and camera sink.
final class FeedCapturePool: @unchecked Sendable {
  typealias Factory = (FeedID) -> CaptureController

  private let lock = NSLock()
  private let factory: Factory
  private var controllers: [FeedID: CaptureController]

  init(factory: @escaping Factory = { feedID in
    CaptureController(services: .live(feedID: feedID))
  }) {
    controllers = [:]
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
  /// Frames the device reported dropped since capture started.
  var deviceDroppedFrames: () -> UInt64 = { 0 }
  var cameraRetryInterval: TimeInterval = 2

  static func live(feedID: FeedID) -> CaptureServices {
    let backend = UltracamBackend()
    let sink = CameraSink(feedID: feedID)
    var services = CaptureServices(
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
    services.deviceDroppedFrames = { backend.deviceDroppedFrames }
    return services
  }
}

/// A monitor target's frame endpoint: a camera's source frames from its capture
/// delivery queue, in capture order (frames that skip the GPU are ordered behind
/// the ones still on it), or Program's from the Program route's publishing
/// thread. Only the source is offered; the monitor computes its Output stage
/// (source plus burn-in LUT) in its own shader. Never blocks, never waits for
/// the GPU, never copies pixels. `MonitorFeedHost` is the MonitorKit endpoint.
protocol MonitorFrameSink: AnyObject, Sendable {
  /// `untouched`: the camera publishes this frame as captured, its tags included
  /// (`PipelineConfiguration.untouched`, the passthrough copy); otherwise
  /// LUTProcessor decodes it for the published frame.
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64, untouched: Bool)
  /// The capture stopped: rejects `rejected` (and every older generation) and
  /// drops the stopped generation's state.
  func invalidate(rejectingCaptureGeneration rejected: UInt64?)
}

extension MonitorFrameSink {
  /// A frame the camera processes (or Program's, already processed).
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64) {
    offer(image, pts: pts, captureGeneration: captureGeneration, sequence: sequence, untouched: false)
  }
}
