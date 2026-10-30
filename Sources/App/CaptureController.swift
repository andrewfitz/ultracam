import IOSurface
import CoreVideo
import CoreMedia
import Foundation
import os

struct CaptureUpdate: @unchecked Sendable {
  var message: String
  var input = "No signal"
  var output = ""
  var sourceFormat: SourceFormat?
  var sourceDuration: CMTime?
  var mediaTime: CMTime?
  var pipelineEnabledApplied: Bool?
  var frames: UInt64 = 0
  var dropped: UInt64 = 0
  /// Capture-to-delivery time of the latest frame: GPU queueing plus GPU work.
  var processingMS: Double = 0
  var previewDelivered = false
  var sourceDrops: UInt64 = 0
  /// Source frames refused by bounded core retention, distinct from device loss.
  var coreRejectedFrames: UInt64 = 0
  var retainedSourceFrames = 0
  var retainedSourceBytes = 0
  var maxRetainedSourceFrames = 0
  var maxRetainedSourceBytes = 0
  /// Frames the capture device itself reported dropped.
  var deviceDrops: UInt64 = 0
  /// Times the source reported no signal and then came back, and the frames
  /// those dropouts cost (measured on the source clock).
  var signalDropouts: UInt64 = 0
  var signalLostFrames: UInt64 = 0
  var ingestCPUCopyFrames: UInt64 = 0
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
  var audioActivityPeak: Float = 0
  var audioActivityRMS: Float = 0
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
  var activityPeak: Float? = nil
  var activityRMS: Float? = nil
  var sampleRate: Double? = nil
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
// Supported load preserves source cadence. Source retention has explicit slot,
// byte and duration budgets; overload is counted separately from device loss.
// Recording admission remains independent of processing/monitor overload.
struct CaptureRecordingDiscoveryPolicy: Sendable {
  let deadline: TimeInterval
  let retention: MediaRetentionPolicy
  static let standard = try! Self(deadline: 2, maximumBytes: 64 * 1024 * 1024,
    maximumDuration: 1, maximumSlots: 64)
  init(deadline: TimeInterval, maximumBytes: Int, maximumDuration: TimeInterval, maximumSlots: Int) throws {
    guard deadline.isFinite, deadline > 0 else { throw MediaRetentionFailure.invalidPolicy }
    self.deadline = deadline
    retention = try MediaRetentionPolicy(maximumBytes: maximumBytes, maximumDuration: maximumDuration,
      maximumSlots: maximumSlots)
  }
}

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
  /// frame. Callbacks installed between one source callback's frame and its
  /// audio would otherwise open the take on that audio, and the writer, which
  /// starts its session at the earliest sample, would begin the movie with a
  /// frame of no picture.
  private struct PendingRecordingVideo {
    let image: CVPixelBuffer
    let source: SourceAdmissionSnapshot
    let metadata: SourceAdmissionMetadata
    let timecode: Timecode?
    let lease: MediaRetentionLedger.Lease
  }
  private struct PendingRecordingAudio {
    let packet: CaptureAudioPacket
    let source: SourceAdmissionSnapshot
    let pair: CaptureFrameInfo?
    let lease: MediaRetentionLedger.Lease
  }
  private enum PendingRecordingMedia {
    case video(PendingRecordingVideo), audio(PendingRecordingAudio)
    var source: SourceAdmissionSnapshot {
      switch self { case .video(let frame): frame.source; case .audio(let audio): audio.source }
    }
  }
  /// All mutable discovery state is protected by the controller lock.
  private final class RecordingDiscoveryState {
    let budget: MediaRetentionLedger
    var pending: [PendingRecordingMedia] = []
    var deadlineScheduled = false
    var draining = false
    init(policy: CaptureRecordingDiscoveryPolicy) { budget = MediaRetentionLedger(policy: policy.retention) }
  }
  private struct RecordingRoute {
    let callbacks: SourceRecordingCallbackAdapter.Callbacks
    /// `recordingCallbackGeneration` at install: names this take's callbacks.
    let install: UInt64
    let discovery: RecordingDiscoveryState
    var videoStarted = false
    var sourceAdmissionAccepted = true
    var takeContextAccepted = true
    var takeContextBinding = false
    var takeContextRejected = false
    var pendingClockEvents: [RecordingClockMappingEvent] = []
    var boundTakeContext: RecordingTakeContext?
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
  // Signal dropouts: the source reported no signal, then frames came back.
  // The last valid timestamp survives `clearSignal`, so the frames the
  // dropout cost are measured on the source clock, apart from device skips.
  private var lastValidSourcePTS: CMTime?
  private var signalLostAt: TimeInterval?
  private var signalDropouts: UInt64 = 0
  private var signalLostFrames: UInt64 = 0
  private var lastReceived: Double = 0
  private var sourceSignalTimeout: TimeInterval = 2
  private var queuedFrames = 0
  private var maxQueuedFrames = 0
  // The processor, for the watchdog and status (thread-safe accessors only).
  private var gpuProcessor: LUTProcessor?
  // The processor's loaded LUT, and whether the effective configuration burns
  // it in (Apply LUT on, pipeline on), for the monitor's feed.
  private var loadedLUT: MonitorLUT?
  private var loadedLUTColorSpace = LUTColorSpaceContract.rec709Video
  private var burnInActive = false
  private var gpuStallReported = false
  private var rawAudioProvidesStats = false
  private var processedFrameHandler: ((ProcessedFrame<CVPixelBuffer>, UInt64) -> Void)?
  private let media = MediaState()
  private let camera = CameraLink()
  private let services: CaptureServices
  private let recordingDiscoveryPolicy: CaptureRecordingDiscoveryPolicy
  private let retentionBudget: CaptureAdmissionBudget
  // Driver-stream state under `lock`; declarations apply before recording callbacks.
  private var declaredSource: SourceFormat?
  private var declaredAdmission: SourceAdmissionSnapshot?
  private var declaredAudio: SourceAudioDeclaration = .unknown
  private struct PendingAudioAdmission {
    let declaration: SourceAudioDeclaration
    let epochID: CaptureEpochID
    let formatSignature: String
    let clockBindings: CaptureClockBindings
  }
  private var pendingAudioAdmission: PendingAudioAdmission?
  private var declaredNativeTimecode: Timecode?
  private var declaredMappingRevision: UInt64?
  private var videoClockMapping: ClockMapping?
  private var audioClockMapping: ClockMapping?
  // At most one pending update per declared clock (video/audio), metadata only.
  private var pendingClockMappings: [ClockInstanceID: CaptureClockMappingUpdate] = [:]
  private var declaredEpoch: CaptureEpochID?
  private var declaredSequence: UInt64 = 0
  private var sourceEpochRevision: UInt64 = 0
  private var pairedFrame: (sequence: UInt64, info: CaptureFrameInfo)?
  private var coreRejectedFrames: UInt64 = 0
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
  private var activeSourceFormat: SourceFormat?
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
  // Capture queue: the loss total at the last "Live" line, so a change logs
  // within five seconds and a quiet run only every 30 s.
  private var lastLoggedLosses: UInt64 = 0
  // Capture queue: one line per signal dropout (bounded), and one summary
  // line per run, under the label the run started with.
  private var signalLossLog = LossLogLimiter()
  private var runLabel = ""
  private var runStarted: Double = 0
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

  #if ULTRACAM_TEST_SUPPORT
  /// Metadata-only accounting for default-constructor retention regressions.
  struct AuditHooks: Sendable {
    var discoveryDeadlineObserved: (@Sendable () -> Void)? = nil
    var discoveryDeadlineFinished: (@Sendable () -> Void)? = nil
    var pendingAudioDequeued: (@Sendable () -> Void)? = nil
    var deliveryFinished: (@Sendable () -> Void)? = nil
  }
  private var auditHooks = AuditHooks()
  func setAuditHooksForTesting(_ hooks: AuditHooks) { lock.withLock { auditHooks = hooks } }
  var retentionSnapshotForTesting: CaptureAdmissionBudget.Snapshot { retentionBudget.snapshot }
  func recordingDiscoverySnapshotForTesting(feedID: FeedID) -> MediaRetentionLedger.Snapshot? {
    lock.withLock { recordingCallbacks[feedID]?.discovery.budget.snapshot }
  }
  var sourceSignalTimeoutForTesting: TimeInterval { lock.withLock { sourceSignalTimeout } }
  #endif

  #if ULTRACAM_TEST_SUPPORT
  func hostTimeForTesting(sourceTime: CMTime, duration: CMTime, image: CVPixelBuffer,
    reference: CaptureHostTimeReference, mapping: ClockMapping? = nil) -> CMTime {
    syncOnQueue { hostTime(for: sourceTime, duration: duration, image: image, reference: reference, mapping: mapping) }
  }
  #endif

  init(services: CaptureServices, retentionBudget: CaptureAdmissionBudget = CaptureAdmissionBudget(
    maximumSlots: 12, maximumBytes: 384 * 1024 * 1024, maximumDuration: 0.25, minimumSlots: 3),
    recordingDiscoveryPolicy: CaptureRecordingDiscoveryPolicy = .standard) {
    self.services = services
    self.recordingDiscoveryPolicy = recordingDiscoveryPolicy
    self.retentionBudget = retentionBudget
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
      guard isCurrent(token) else { return }
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
  func load(_ lut: MonitorLUT, colorSpace: LUTColorSpaceContract = .rec709Video,
    expectedGeneration: UInt64? = nil,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    let token = expectedGeneration ?? generationToken
    queue.async {
      do {
        if !self.isCurrent(token) {
          throw VideoError.message("Camera changed before its LUT finished loading.")
        }
        try self.makeProcessor().load(lut, colorSpace: colorSpace)
        guard self.isCurrent(token) else {
          throw VideoError.message("Camera changed before its LUT finished loading.")
        }
        self.lock.withLock { self.loadedLUT = lut; self.loadedLUTColorSpace = colorSpace }
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
          options: [.userInitiated, .latencyCritical], reason: "Live source video processing")
        self.configuration = configuration
        self.pipelineEnabled = pipelineEnabled
        self.publishBurnIn()
        self.previewEnabled = previewEnabled
        let pause = try self.services.sourcePauseAllowance?(deviceID)
        self.lock.withLock { self.sourceSignalTimeout = pause.map { max(2, $0) } ?? 2 }
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
        self.lastLoggedLosses = 0
        self.signalLossLog = LossLogLimiter()
        self.runLabel = self.cameraLabel
        self.runStarted = ProcessInfo.processInfo.systemUptime
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
        let warm = self.effectiveConfiguration(duration: configuration.resolvedSourceDuration)
        if let type = self.services.capturePixelFormat {
          self.establish(warm, inputType: type, synchronous: true)
        } else if !self.services.followsSourceTiming {
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
          self.lastValidSourcePTS = nil
          self.signalLostAt = nil
          self.signalDropouts = 0
          self.signalLostFrames = 0
          self.sourceDuration = configuration.resolvedSourceDuration
          self.lastReceived = ProcessInfo.processInfo.systemUptime
          self.maxQueuedFrames = self.queuedFrames
          self.gpuStallReported = false
          self.rawAudioProvidesStats = false
          self.declaredSource = nil
          self.declaredAdmission = nil
          self.declaredAudio = .unknown
          self.declaredNativeTimecode = nil
          self.pendingAudioAdmission = nil
          self.declaredMappingRevision = nil
          self.videoClockMapping = nil
          self.audioClockMapping = nil
          self.pendingClockMappings.removeAll(keepingCapacity: true)
          self.declaredEpoch = nil
          self.declaredSequence = 0
          self.pairedFrame = nil
          self.coreRejectedFrames = 0
        }
        // Driver events change capture-queue state (signal loss, fatal errors);
        // they are rare, so they stay on the capture queue.
        #if ULTRACAM_TEST_SUPPORT
        let event: (String) -> Void = { [weak self] value in
          guard let self else { return }
          let signalLost = value.localizedCaseInsensitiveContains("no ") && value.localizedCaseInsensitiveContains("video signal")
          if signalLost { self.noteSignalLost(token: token) }
          self.queue.async {
            guard self.isAccepting(token) else { return }
            if value.hasPrefix("Capture error: ") {
              self.fail(value, token: token)
              return
            }
            self.message = value
            if signalLost || value.localizedCaseInsensitiveContains("unsupported") {
              self.clearSignal(resetSourceClock: !signalLost)
              self.inputLabel = value
            }
            self.publishCurrent(token: token)
          }
        }
        let mediaHandler: (CaptureMediaStats) -> Void = { [weak self] stats in
          self?.receiveMedia(stats, token: token)
        }
        if let typed = self.services.startTyped {
          try typed(deviceID, .automatic, CaptureHandlers { [weak self] delivery in
            self?.receiveTyped(delivery, token: token)
          })
        } else if let automatic = self.services.startAutomatic {
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
          try startWithSourceAudio(deviceID, configuration.resolvedSourceDuration.seconds < 1.0 / 45.0, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, mediaHandler, { [weak self] audio in
            self?.receiveRawAudio(audio, token: token)
          }, event)
        } else if let startWithRawAudio = self.services.startWithRawAudio {
          self.lock.withLock { self.rawAudioProvidesStats = true }
          try startWithRawAudio(deviceID, configuration.resolvedSourceDuration.seconds < 1.0 / 45.0, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, { [weak self] audio in
            self?.receiveRawAudio(audio, token: token)
          }, event)
        } else if let startWithMedia = self.services.startWithMedia {
          try startWithMedia(deviceID, configuration.resolvedSourceDuration.seconds < 1.0 / 45.0, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, mediaHandler, event)
        } else {
          try self.services.start(deviceID, configuration.resolvedSourceDuration.seconds < 1.0 / 45.0, { [weak self] image, pts, valid in
            self?.receive(image, at: pts, duration: nil, signalValid: valid, token: token)
          }, event)
        }
        #else
        try self.services.startTyped(deviceID, .automatic, CaptureHandlers { [weak self] delivery in
          self?.receiveTyped(delivery, token: token)
        })
        #endif
        guard self.isCurrent(token) else {
          self.stopResources(preserveRecordingCallbacks: true)
          return
        }
        self.message = "Waiting for signal…"
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
      let state = self.lock.withLock { () -> (accepting: Bool, last: Double, stuck: Bool, timeout: TimeInterval) in
        let accepting = self.generation == token && self.accepting
        let oldest = self.gpuProcessor?.inFlight.oldestCommit
        let stuck = accepting && !self.gpuStallReported && oldest.map { now - $0 > 2 } == true
        if stuck { self.gpuStallReported = true }
        return (accepting, self.lastReceived, stuck, self.sourceSignalTimeout)
      }
      guard state.accepting else { return }
      if state.stuck {
        self.queue.async {
          self.fail("The GPU stopped responding: a frame has been on the GPU for over two seconds.", token: token)
        }
        return
      }
      guard now - state.last > state.timeout else { return }
      self.queue.async {
        guard self.isAccepting(token) else { return }
        if self.services.followsSourceTiming {
          if self.detected != nil || self.message == "Waiting for signal…" {
            // Once per outage: `clearSignal` forgets the detected input.
            if self.detected != nil {
              self.logger.notice("No video from \(self.runLabel, privacy: .public) for \(String(format: "%.1f", now - state.last), privacy: .public) s; waiting for the source.")
            }
            self.clearSignal()
            self.message = "No video signal — waiting for source."
            self.publishCurrent(token: token)
          }
        } else {
          self.fail("No valid video signal for two seconds. Check the source connection.", token: token)
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
      self.message = self.detected == nil ? "Waiting for signal…" : "Updating output…"
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
    if old.resolvedSourceDuration != new.resolvedSourceDuration {
      parts.append("source duration \(old.resolvedSourceDuration.seconds)→\(new.resolvedSourceDuration.seconds)")
    }
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
      pendingAudioAdmission = nil
      activeFeedID = nil
      return StopRequest(token: generation, stoppedGeneration: stoppedGeneration,
        callbackGeneration: recordingCallbackGeneration, sink: monitorLifecycleSink)
    }
  }

  private func performStop(_ request: StopRequest) {
    guard isCurrent(request.token) else { return }
    guard !stopNotified else { return }
    stopNotified = true
    logRunSummary()
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
  private func isAccepting(_ token: UInt64, epochRevision: UInt64) -> Bool {
    lock.withLock { generation == token && accepting && sourceEpochRevision == epochRevision }
  }

  /// Installs one feed's raw callback fan-out. The callback itself performs
  /// only bounded SourceRecorderCore admission and is safe to call on the
  /// native source callback thread.
  func setRecordingCallbacks(feedID: FeedID,
    callbacks: SourceRecordingCallbackAdapter.Callbacks?) {
    let pending = lock.withLock { () -> (SourceAdmissionSnapshot, UInt64, UInt64)? in
      recordingCallbackGeneration &+= 1
      if let callbacks {
        let snapshot = accepting && activeFeedID == feedID ? declaredAdmission : nil
        var route = RecordingRoute(callbacks: callbacks, install: recordingCallbackGeneration,
          discovery: RecordingDiscoveryState(policy: recordingDiscoveryPolicy))
        route.sourceAdmissionAccepted = snapshot == nil || callbacks.sourceAdmission == nil
        route.takeContextAccepted = snapshot == nil || callbacks.takeContext == nil
        recordingCallbacks[feedID] = route
        if let snapshot { return (snapshot, recordingCallbackGeneration, generation) }
      } else {
        recordingCallbacks.removeValue(forKey: feedID)
      }
      return nil
    }
    if let pending {
      bindRecordingAdmission(pending.0, feedID: feedID, install: pending.1, token: pending.2)
    }
  }

  private func bindRecordingAdmission(_ snapshot: SourceAdmissionSnapshot, feedID: FeedID,
    install: UInt64, token: UInt64) {
    let incompatible = lock.withLock { () -> Bool in
      guard let pending = recordingCallbacks[feedID]?.discovery.pending else { return false }
      return pending.contains { media in
        if media.source.epochID.sessionID != snapshot.epochID.sessionID ||
          media.source.epochID.epoch > snapshot.epochID.epoch ||
          media.source.formatSignature != snapshot.formatSignature ||
          media.source.clockBindings.video != snapshot.clockBindings.video { return true }
        if case .audio(let audio) = media {
          return audio.source.clockBindings.audio != snapshot.clockBindings.audio ||
            (declaredAudio.isResolved && declaredAudio != .present(audio.packet.format))
        }
        return false
      }
    }
    if incompatible {
      rejectRecordingMetadata(feedID: feedID, install: install, token: token,
        message: "Recording audio discovery crossed a changed video format or clock; start a new take.")
      return
    }
    let route = lock.withLock { () -> RecordingRoute? in
      guard generation == token, accepting, let route = recordingCallbacks[feedID], route.install == install,
        !route.takeContextRejected else { return nil }
      if !route.discovery.deadlineScheduled, route.boundTakeContext == nil {
        route.discovery.deadlineScheduled = true
        watchdogQueue.asyncAfter(deadline: .now() + recordingDiscoveryPolicy.deadline) { [weak self] in
          self?.expireRecordingDiscovery(feedID: feedID, install: install, token: token)
        }
      }
      guard declaredAudio.isResolved else {
        // A prepared encoder is not a bound take. Discovery may legitimately
        // resolve in a new epoch before any recording media is admitted.
        recordingCallbacks[feedID]?.sourceAdmissionAccepted = false
        recordingCallbacks[feedID]?.takeContextAccepted = false
        return nil
      }
      recordingCallbacks[feedID]?.sourceAdmissionAccepted = route.callbacks.sourceAdmission == nil
      return route
    }
    guard let route else { return }
    let accepted = route.callbacks.sourceAdmission?(snapshot) ?? true
    lock.withLock {
      guard generation == token, recordingCallbacks[feedID]?.install == install else { return }
      recordingCallbacks[feedID]?.sourceAdmissionAccepted = accepted
    }
    if accepted { bindRecordingTakeContext(feedID: feedID, install: install, token: token) }
    else { rejectRecordingMetadata(feedID: feedID, install: install, token: token) }
  }

  /// Capture-side work binds immutable actual declarations and enqueues metadata
  /// before media. JSON/file operations stay on the recorder's private queue.
  private func bindRecordingTakeContext(feedID: FeedID, install: UInt64, token: UInt64) {
    let pending = lock.withLock { () -> (SourceRecordingCallbackAdapter.Callbacks, RecordingTakeContext)? in
      guard generation == token, accepting, let route = recordingCallbacks[feedID], route.install == install,
        !route.takeContextBinding, !route.takeContextRejected else { return nil }
      guard route.sourceAdmissionAccepted, let source = declaredAdmission, declaredAudio.isResolved else {
        recordingCallbacks[feedID]?.takeContextAccepted = route.callbacks.takeContext == nil && route.sourceAdmissionAccepted
        return nil
      }
      if case .present(let audio) = declaredAudio, audio.clock != .pairedWithFrames,
        (videoClockMapping == nil || audioClockMapping == nil) {
        recordingCallbacks[feedID]?.takeContextAccepted = false
        return nil
      }
      let context = RecordingTakeContext(sourceAdmission: source, audioDeclaration: declaredAudio,
        mappingRevision: declaredMappingRevision, videoMapping: videoClockMapping, audioMapping: audioClockMapping)
      if let prior = route.boundTakeContext, route.takeContextAccepted, prior.sameContract(as: context),
        prior.mappingRevision == context.mappingRevision, prior.videoMapping == context.videoMapping,
        prior.audioMapping == context.audioMapping { return nil }
      if route.boundTakeContext == nil, route.callbacks.clockMapping != nil {
        // A take joining between an update and its next effective delivery must
        // preserve that already-known event after its initial context metadata.
        let future = pendingClockMappings.values.filter {
          $0.epochID == source.epochID && $0.effectiveSequence > declaredSequence
        }.sorted { $0.effectiveSequence < $1.effectiveSequence }
        for update in future {
          recordingCallbacks[feedID]?.pendingClockEvents.append(RecordingClockMappingEvent(
            epochID: update.epochID, clockID: update.clockID, revision: update.revision,
            effectiveSequence: update.effectiveSequence, mapping: update.mapping))
        }
      }
      recordingCallbacks[feedID]?.takeContextBinding = true
      recordingCallbacks[feedID]?.takeContextAccepted = false
      return (route.callbacks, context)
    }
    guard let pending else { return }
    guard pending.0.takeContext?(pending.1) ?? true else {
      rejectRecordingMetadata(feedID: feedID, install: install, token: token)
      return
    }
    // At most 64 journal enqueues per bind, even if another thread continues
    // delivering clock events. Readiness is published only after those enqueues.
    for drained in 0...64 {
      let step = lock.withLock { () -> (event: RecordingClockMappingEvent?, ready: Bool, overflow: Bool) in
        guard generation == token, accepting, let route = recordingCallbacks[feedID], route.install == install,
          route.sourceAdmissionAccepted, !route.takeContextRejected else {
          if recordingCallbacks[feedID]?.install == install { recordingCallbacks[feedID]?.takeContextBinding = false }
          return (nil, false, false)
        }
        if route.pendingClockEvents.isEmpty {
          recordingCallbacks[feedID]?.boundTakeContext = pending.1
          recordingCallbacks[feedID]?.takeContextAccepted = true
          recordingCallbacks[feedID]?.takeContextBinding = false
          return (nil, true, false)
        }
        guard drained < 64 else { return (nil, false, true) }
        let event = route.pendingClockEvents[0]
        recordingCallbacks[feedID]?.pendingClockEvents.removeFirst()
        return (event, false, false)
      }
      if step.ready {
        drainRecordingDiscovery(feedID: feedID, install: install, token: token)
        return
      }
      if step.overflow {
        rejectRecordingMetadata(feedID: feedID, install: install, token: token,
          message: "Recording clock metadata queue is full; start a new take.")
        return
      }
      guard let event = step.event else { return }
      if pending.0.clockMapping?(event) == false {
        rejectRecordingMetadata(feedID: feedID, install: install, token: token)
        return
      }
    }
  }

  private func rejectRecordingMetadata(feedID: FeedID, install: UInt64, token: UInt64, message: String? = nil,
    onlyWhileDiscoveryUnbound: Bool = false) {
    let callbacks = lock.withLock { () -> SourceRecordingCallbackAdapter.Callbacks? in
      guard generation == token, let route = recordingCallbacks[feedID], route.install == install,
        !route.takeContextRejected, !onlyWhileDiscoveryUnbound || route.boundTakeContext == nil else { return nil }
      recordingCallbacks[feedID]?.takeContextAccepted = false
      recordingCallbacks[feedID]?.takeContextBinding = false
      recordingCallbacks[feedID]?.takeContextRejected = true
      recordingCallbacks[feedID]?.pendingClockEvents.removeAll(keepingCapacity: false)
      route.discovery.pending.removeAll(keepingCapacity: false)
      route.discovery.draining = false
      return route.callbacks
    }
    if let message { callbacks?.metadataFailure?(message) }
  }

  private func bindActiveRecordingTakeContext(token: UInt64) {
    let route = lock.withLock { () -> (feed: FeedID, install: UInt64, unboundSource: SourceAdmissionSnapshot?)? in
      guard generation == token, accepting, let feed = activeFeedID, let route = recordingCallbacks[feed] else { return nil }
      let unbound = !route.sourceAdmissionAccepted && !route.takeContextRejected && declaredAudio.isResolved
        ? declaredAdmission : nil
      return (feed, route.install, unbound)
    }
    if let route {
      if let source = route.unboundSource {
        bindRecordingAdmission(source, feedID: route.feed, install: route.install, token: token)
      } else { bindRecordingTakeContext(feedID: route.feed, install: route.install, token: token) }
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
  /// Declared video content for pending recording preflight, independent of
  /// audio discovery. This does not establish an epoch or recording clock map.
  var recordingVideoFormat: SourceFormat? {
    lock.withLock { accepting ? declaredAdmission?.format : nil }
  }

  var recordingTakeContext: RecordingTakeContext? {
    lock.withLock {
      guard accepting, let source = declaredAdmission, declaredAudio.isResolved else { return nil }
      return RecordingTakeContext(sourceAdmission: source, audioDeclaration: declaredAudio,
        mappingRevision: declaredMappingRevision, videoMapping: videoClockMapping, audioMapping: audioClockMapping)
    }
  }
  var latestNativeTimecode: Timecode? { lock.withLock { declaredNativeTimecode } }

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

  /// `resetSourceClock: false` for a signal-lost event: the driver thread
  /// already handles the dropout's gap, and this queued reset could land
  /// after frames resumed and hide the next device skip.
  private func clearSignal(resetSourceClock: Bool = true) {
    if resetSourceClock { lock.withLock { lastSourcePTS = nil } }
    detected = nil
    inputLabel = "No signal"
    outputLabel = ""
    applied = nil
    outputFPS = 0
    firstSourceTime = nil
    frameRateGate = FrameRateGate()
  }

  /// Driver thread, on the source's signal-lost event: a dropout begins if
  /// frames were arriving. The next valid frame measures what it cost.
  private func noteSignalLost(token: UInt64) {
    lock.withLock {
      guard generation == token, accepting, signalLostAt == nil, lastValidSourcePTS != nil else { return }
      signalLostAt = ProcessInfo.processInfo.systemUptime
      signalDropouts &+= 1
    }
  }

  /// Capture queue: one line per dropout, bounded by `signalLossLog`.
  private func logSignalReturn(_ recovered: (frames: UInt64, seconds: TimeInterval), token: UInt64) {
    guard isAccepting(token) else { return }
    let ms = Int((recovered.seconds * 1000).rounded())
    let decision = signalLossLog.note(frames: recovered.frames, at: ProcessInfo.processInfo.systemUptime)
    switch decision {
    case .log, .logLast:
      // Over 10 s is an outage, not a dropout: its frames aren't counted.
      let lost = recovered.seconds < 10 ? "\(recovered.frames) frames lost" : "frames not counted"
      logger.notice("Signal back on \(self.runLabel, privacy: .public) after a dropout: \(lost, privacy: .public) (\(ms) ms without video). This run: \(self.signalLossLog.events) dropouts, \(self.signalLossLog.frames) frames.")
      if decision == .logLast {
        logger.notice("Further signal dropouts on \(self.runLabel, privacy: .public) are summarized at most once a minute.")
      }
    case .summary(let events, let frames):
      logger.notice("Signal dropouts on \(self.runLabel, privacy: .public): \(events) more, \(frames) frames lost. This run: \(self.signalLossLog.events) dropouts, \(self.signalLossLog.frames) frames.")
    case .quiet:
      break
    }
  }

  /// Capture queue, when a run stops: one line with its losses, so a take's
  /// health is in the log even when nothing went wrong.
  private func logRunSummary() {
    guard runStarted > 0 else { return }
    let minutes = (ProcessInfo.processInfo.systemUptime - runStarted) / 60
    runStarted = 0
    let counts = lock.withLock { (sourceDrops, signalDropouts, signalLostFrames, coreRejectedFrames) }
    let deviceDrops = services.deviceDroppedFrames()
    let unlogged = signalLossLog.flush()
    logger.notice("Capture summary \(self.runLabel, privacy: .public): \(String(format: "%.1f", minutes), privacy: .public) min, delivered=\(self.frames) signalDropouts=\(counts.1) signalLostFrames=\(counts.2) sourceDrops=\(counts.0) deviceDrops=\(deviceDrops) coreRefusals=\(counts.3) outputStalls=\(self.poolDrops) cameraStalls=\(self.cameraDrops) lateFrames=\(self.lateFrames)\(unlogged.map { " (\($0.events) dropouts not logged one by one)" } ?? "", privacy: .public)")
  }

  private func fail(_ value: String, token: UInt64) {
    guard isCurrent(token), !stopNotified else { return }
    stopNotified = true
    lock.withLock { accepting = false }
    logRunSummary()
    let sink = lock.withLock { monitorLifecycleSink }
    sink?.invalidate(rejectingCaptureGeneration: token)
    stopResources()
    applied = nil
    outputLabel = ""
    message = value
    logger.error("Capture stopped: \(value, privacy: .public)")
    publishCurrent(token: token, stopped: true)
  }

  private func effectiveConfiguration(source: SourceAdmissionSnapshot? = nil,
    duration: CMTime? = nil) -> PipelineConfiguration {
    var result = pipelineEnabled ? configuration : PipelineConfiguration(
      applyLUT: false, downscale: false, convertTo420: false, reduceFrameRate: false)
    result.sourceDuration = duration ?? source?.format.rate.nominal ?? configuration.resolvedSourceDuration
    if let source {
      result.sourceWidth = source.sourceSize.width
      result.sourceHeight = source.sourceSize.height
      result.sourcePixelAspect = source.sourceSize.pixelAspect
      result.sourceDuration = duration ?? source.format.rate.nominal
    }
    return result
  }

  /// Creates the processor on first demand and publishes it for the watchdog.
  private func makeProcessor() throws -> LUTProcessor {
    if let processor { return processor }
    let created = try LUTProcessor()
    let retainedLUT = lock.withLock { (loadedLUT, loadedLUTColorSpace) }
    if let lut = retainedLUT.0 { try created.load(lut, colorSpace: retainedLUT.1) }
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
      preparedConfiguration?.pixelFormat != next.pixelFormat || preparedConfiguration?.width != next.width ||
      preparedConfiguration?.height != next.height || preparedConfiguration?.sourceWidth != next.sourceWidth ||
      preparedConfiguration?.sourceHeight != next.sourceHeight ||
      preparedConfiguration?.resolvedSourcePixelAspect != next.resolvedSourcePixelAspect ||
      preparedConfiguration?.scalingMode != next.scalingMode {
      try processor?.prepare(configuration: next, wait: wait)
      preparedConfiguration = next
    }
  }

  // MARK: - Virtual camera connection (capture-queue state, control-queue work)

  private func establish(_ next: PipelineConfiguration, inputType: OSType, synchronous: Bool = false,
    sourceFormat: SourceFormat? = nil) {
    let prior = activeConfiguration
    let priorType = activeInputType
    let sameContract = prior.map {
      $0.width == next.width && $0.height == next.height &&
        $0.pixelFormat == next.pixelFormat && $0.duration == next.duration &&
        $0.untouched == next.untouched && activeInputType == inputType && activeSourceFormat == sourceFormat
    } ?? false
    activeConfiguration = next
    activeInputType = inputType
    activeSourceFormat = sourceFormat
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
    requestConnect(next, inputType: inputType, synchronous: synchronous, sourceFormat: sourceFormat)
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
    requestConnect(next, inputType: type, synchronous: false, sourceFormat: activeSourceFormat)
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

  private func requestConnect(_ next: PipelineConfiguration, inputType: OSType, synchronous: Bool,
    sourceFormat: SourceFormat? = nil) {
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
        if let typed = services.connectWithSource { try typed(next, inputType, sourceFormat) }
        else { try services.connect(next, inputType) }
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

  /// The session serializes this stream. Contract state changes synchronously
  /// before the next recording callback, independently of capture queue load.
  private func receiveTyped(_ delivery: CaptureDelivery, token: UInt64) {
    let admission = lock.withLock { () -> (accepted: Bool, newEpoch: Bool, changedTake: (FeedID, UInt64)?) in
      guard generation == token, accepting, delivery.sequence > declaredSequence else { return (false, false, nil) }
      if let epoch = declaredEpoch {
        guard epoch.sessionID == delivery.epochID.sessionID, delivery.epochID.epoch >= epoch.epoch else { return (false, false, nil) }
      }
      let newEpoch = declaredEpoch != delivery.epochID
      let declaresContract: Bool
      switch delivery.payload {
      case .event(.formatChanged), .event(.audioFormatChanged), .event(.discontinuity): declaresContract = true
      default: declaresContract = false
      }
      var changedTake: (FeedID, UInt64)?
      if newEpoch && declaresContract {
        if let feed = activeFeedID, let route = recordingCallbacks[feed], route.callbacks.takeContext != nil,
          route.boundTakeContext != nil || route.takeContextBinding {
          changedTake = (feed, route.install)
        }
        // Retire old queued/GPU work on the first declaration/reset envelope,
        // before a producer can pause ahead of the remaining declarations.
        sourceEpochRevision &+= 1
        declaredEpoch = delivery.epochID
        declaredSource = nil
        declaredAdmission = nil
        declaredAudio = .unknown
        declaredNativeTimecode = nil
        pendingAudioAdmission = nil
        declaredMappingRevision = nil
        videoClockMapping = nil
        audioClockMapping = nil
        pendingClockMappings.removeAll(keepingCapacity: true)
        pairedFrame = nil
        lastSourcePTS = nil
      }
      declaredSequence = delivery.sequence
      return (true, newEpoch, changedTake)
    }
    guard admission.accepted else { return }
    if admission.newEpoch { media.resetPacketBaseline() }
    if let changed = admission.changedTake {
      rejectRecordingMetadata(feedID: changed.0, install: changed.1, token: token,
        message: "Recording source or audio declaration changed during the take; start a new take.")
    }
    let snapshot = lock.withLock { declaredAdmission }
    let carriesMedia: Bool
    let requiresBoundHeader: Bool
    switch delivery.payload {
    case .frame, .cpuMemory, .media, .rawAudio: carriesMedia = true; requiresBoundHeader = true
    case .event(.audioFormatChanged), .event(.clockMappingChanged): carriesMedia = false; requiresBoundHeader = true
    default: carriesMedia = false; requiresBoundHeader = false
    }
    if requiresBoundHeader {
      if let snapshot, snapshot.epochID == delivery.epochID {
        guard delivery.formatSignature == snapshot.formatSignature,
          delivery.clockBindings == snapshot.clockBindings else {
          refuseSourceContract(SourceAdmissionRefusal(stage: .capture,
            formatDescription: FormatDisplayIdentity(snapshot.format).detail,
            reason: "delivery signature or clock bindings changed without a new capture epoch"), token: token)
          return
        }
      } else if carriesMedia {
        refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "undeclared source",
          reason: "matching source declarations are required before media"), token: token)
        return
      }
    }
    let mappingsBecomeEffective = lock.withLock { !pendingClockMappings.isEmpty }
    let mappingProblem = lock.withLock { () -> String? in
      let previous = declaredMappingRevision
      let effective = Array(pendingClockMappings.values)
      for update in effective {
        guard update.effectiveSequence == delivery.sequence else {
          return "clock mapping effective sequence did not identify the next delivery"
        }
        guard update.revision == delivery.mappingRevision else {
          return "next delivery did not carry the declared clock mapping revision"
        }
      }
      for update in effective {
        if update.clockID == delivery.clockBindings.video { videoClockMapping = update.mapping }
        if update.clockID == delivery.clockBindings.audio { audioClockMapping = update.mapping }
        pendingClockMappings.removeValue(forKey: update.clockID)
      }
      if let previous, previous != delivery.mappingRevision, effective.isEmpty {
        // A session may begin with an actual revision whose mapping values are
        // unavailable. Never manufacture anchors for that declared revision.
        videoClockMapping = nil
        audioClockMapping = nil
      }
      declaredMappingRevision = delivery.mappingRevision
      return nil
    }
    if let mappingProblem {
      refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "source clock",
        reason: mappingProblem), token: token)
      return
    }
    if carriesMedia || mappingsBecomeEffective { bindActiveRecordingTakeContext(token: token) }
    switch delivery.payload {
    case .event(let event):
      switch event {
      case .formatChanged(let format):
        do {
          let snapshot = try SourceAdmissionSnapshot(format: format, epochID: delivery.epochID,
            clockBindings: delivery.clockBindings, stage: .capture)
          guard snapshot.formatSignature == delivery.formatSignature else {
            throw SourceAdmissionRefusal(stage: .capture,
              formatDescription: FormatDisplayIdentity(format).detail, reason: "declaration signature differs from delivery envelope")
          }
          let pending = lock.withLock { pendingAudioAdmission }
          if let pending {
            guard pending.epochID == snapshot.epochID, pending.clockBindings == snapshot.clockBindings,
              pending.formatSignature.isEmpty || pending.formatSignature == snapshot.formatSignature else {
              throw SourceAdmissionRefusal(stage: .capture,
                formatDescription: FormatDisplayIdentity(format).detail,
                reason: "pending audio declaration differs from the video epoch, signature or clock bindings")
            }
          }
          let prior = lock.withLock { declaredAdmission }
          if let prior, prior.epochID == snapshot.epochID,
            (prior.formatSignature != snapshot.formatSignature || prior.clockBindings != snapshot.clockBindings) {
            throw SourceAdmissionRefusal(stage: .capture,
              formatDescription: FormatDisplayIdentity(format).detail, reason: "contract changed without a new capture epoch")
          }
          let route = lock.withLock { () -> (FeedID, UInt64)? in
            guard generation == token, accepting else { return nil }
            if declaredEpoch != delivery.epochID {
              sourceEpochRevision &+= 1
              declaredAudio = .unknown
              pairedFrame = nil
            }
            declaredEpoch = delivery.epochID
            declaredSource = format
            declaredAdmission = snapshot
            if let pending { declaredAudio = pending.declaration }
            pendingAudioAdmission = nil
            sourceDuration = format.rate.nominal
            lastSourcePTS = nil
            guard let feed = activeFeedID, let recording = recordingCallbacks[feed] else { return nil }
            return (feed, recording.install)
          }
          if case .present(let audio) = lock.withLock({ declaredAudio }) {
            do { try audioMeterTap.configure(format: audio) }
            catch { refuseSourceContract(error, token: token); return }
          }
          if let route { bindRecordingAdmission(snapshot, feedID: route.0, install: route.1, token: token) }
          queue.async {
            guard self.isAccepting(token), self.lock.withLock({ self.declaredAdmission?.epochID == snapshot.epochID }) else { return }
            if prior?.epochID != snapshot.epochID {
              self.clearSignal()
              self.lastDeliveredSourceTime = nil
              self.lastMappedSourceTime = nil
            }
            self.inputLabel = "\(format.width) × \(format.height) · \(format.pixel.rawValue) · pixel aspect \(format.pixelAspect.numerator):\(format.pixelAspect.denominator)"
            self.message = "Source format declared"
            self.publishCurrent(token: token)
          }
        } catch { refuseSourceContract(error, token: token) }
      case .audioFormatChanged(let declaration):
        let problem = lock.withLock { () -> String? in
          if declaredAdmission != nil {
            if declaredAudio.isResolved && declaredAudio != declaration {
              return "audio declaration changed without a new capture epoch"
            }
            declaredAudio = declaration
          } else {
            if let pending = pendingAudioAdmission,
              (pending.epochID != delivery.epochID || pending.clockBindings != delivery.clockBindings ||
               (!pending.formatSignature.isEmpty && !delivery.formatSignature.isEmpty && pending.formatSignature != delivery.formatSignature)) {
              return "pending audio declaration changed epoch, signature or clock bindings"
            }
            // Native detection may know audio before any video signature. Only
            // this initial pending declaration permits an empty video signature;
            // its explicit audio contract still requires matching epoch/clocks.
            pendingAudioAdmission = PendingAudioAdmission(declaration: declaration,
              epochID: delivery.epochID, formatSignature: delivery.formatSignature, clockBindings: delivery.clockBindings)
          }
          return nil
        }
        if let problem {
          refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "source audio",
            reason: problem), token: token)
        } else {
          if case .present(let audio) = declaration {
            do { try audioMeterTap.configure(format: audio) }
            catch { refuseSourceContract(error, token: token); return }
          }
          bindActiveRecordingTakeContext(token: token)
        }
      case .discontinuity:
        guard admission.newEpoch else {
          refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "source clock",
            reason: "a discontinuity requires a new capture epoch"), token: token)
          return
        }
        queue.async { if self.isAccepting(token) { self.clearSignal() } }
      case .clockMappingChanged(let update):
        let (nextSequence, overflow) = delivery.sequence.addingReportingOverflow(1)
        guard !overflow, update.effectiveSequence == nextSequence else {
          refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "source clock",
            reason: "clock mapping update must target the next delivery"), token: token)
          return
        }
        guard let source = lock.withLock({ declaredAdmission }), update.epochID == source.epochID,
          update.clockID == source.clockBindings.video || update.clockID == source.clockBindings.audio,
          update.revision > delivery.mappingRevision,
          update.mapping.sourceAnchor.epoch == 0, update.mapping.hostAnchor.epoch == 0 else {
          refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "source clock",
            reason: "clock mapping update does not match its declared epoch, clock or revision"), token: token)
          return
        }
        let event = RecordingClockMappingEvent(epochID: update.epochID, clockID: update.clockID,
          revision: update.revision, effectiveSequence: update.effectiveSequence, mapping: update.mapping)
        let route = lock.withLock { () -> (callbacks: SourceRecordingCallbackAdapter.Callbacks?, feed: FeedID?, install: UInt64, overflow: Bool) in
          guard generation == token, accepting else { return (nil, nil, 0, false) }
          pendingClockMappings[update.clockID] = update
          guard let feed = activeFeedID, let route = recordingCallbacks[feed], route.sourceAdmissionAccepted,
            !route.takeContextRejected, route.callbacks.clockMapping != nil else { return (nil, nil, 0, false) }
          if route.takeContextBinding {
            guard route.pendingClockEvents.count < 64 else { return (nil, feed, route.install, true) }
            recordingCallbacks[feed]?.pendingClockEvents.append(event)
            return (nil, nil, 0, false)
          }
          guard route.takeContextAccepted, route.boundTakeContext != nil else { return (nil, nil, 0, false) }
          return (route.callbacks, feed, route.install, false)
        }
        if let feed = route.feed {
          if route.overflow {
            rejectRecordingMetadata(feedID: feed, install: route.install, token: token,
              message: "Recording clock metadata queue is full; start a new take.")
          } else if route.callbacks?.clockMapping?(event) == false {
            rejectRecordingMetadata(feedID: feed, install: route.install, token: token)
          }
        }
      case .fatal(let reason):
        failFromSource(reason, token: token)
      case .waitingForSignal, .signalLost, .unsupportedInput, .info:
        // Before the next frame can arrive on this thread, not on the queue.
        if case .signalLost = event { noteSignalLost(token: token) }
        queue.async {
          guard self.isAccepting(token) else { return }
          switch event {
          case .waitingForSignal:
            self.message = "Waiting for signal…"
          case .signalLost(let reason):
            self.clearSignal(resetSourceClock: false); self.message = "No video signal: \(reason)"
          case .unsupportedInput(let reason):
            self.clearSignal(); self.message = "Unsupported input: \(reason)"
          case .info(let message): self.message = message
          default: break
          }
          self.publishCurrent(token: token)
        }
      }
    case .frame(let buffer, let info):
      do {
        guard let snapshot = lock.withLock({ declaredAdmission }) else {
          throw SourceAdmissionRefusal(stage: .capture, formatDescription: "undeclared source",
            reason: "format declaration is required before video")
        }
        let metadata = SourceAdmissionMetadata(pixelBuffer: buffer.value,
          presentationTime: info.presentationTime, duration: info.duration,
          epochID: info.epochID, formatSignature: info.formatSignature)
        try snapshot.validate(metadata, stage: .capture)
        guard delivery.epochID == info.epochID, delivery.formatSignature == info.formatSignature,
          delivery.clockBindings == snapshot.clockBindings else {
          throw SourceAdmissionRefusal(stage: .capture,
            formatDescription: FormatDisplayIdentity(snapshot.format).detail,
            reason: "frame envelope differs from the declared epoch, signature or clock bindings")
        }
        lock.withLock {
          if info.signalValid { pairedFrame = (delivery.sequence, info); declaredNativeTimecode = info.timecode }
        }
        receive(buffer.value, at: info.presentationTime, duration: info.duration,
          signalValid: info.signalValid, token: token, recordingFormatValid: true,
          sourceAdmission: snapshot, sourceMetadata: metadata, hostTimeReference: info.hostTimeReference, nativeTimecode: info.timecode, captureHostTime: info.captureHostTime)
      } catch { refuseSourceContract(error, token: token) }
    case .cpuMemory:
      refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "CPU-memory source",
        reason: "CPU-memory frames must cross the ordered GPU ingest boundary"), token: token)
    case .media(let info):
      let matches = lock.withLock { declaredEpoch == delivery.epochID && declaredSource?.signature == delivery.formatSignature }
      guard matches else { return }
      guard lock.withLock({ declaredAudio == info.audioDeclaration }) else {
        refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "source audio",
          reason: "audio media declaration differs from the immutable source audio contract"), token: token)
        return
      }
      let audio: SourceAudioFormat?
      if case .present(let format) = info.audioDeclaration { audio = format } else { audio = nil }
      let tc = info.timecode.map {
        String(format: "%02d:%02d:%02d%@%02d", $0.hours, $0.minutes, $0.seconds, $0.dropFrame ? ";" : ":", $0.frames)
      }
      receiveMedia(CaptureMediaStats(timecode: tc, audioPacketTime: info.audioPacketTime ?? .invalid,
        audioSampleFrames: UInt64(max(0, info.sampleFrameCount)), audioChannels: audio?.channels ?? 0,
        leftPeak: info.peaks.first ?? 0, rightPeak: info.peaks.dropFirst().first ?? 0,
        leftRMS: info.rms.first ?? 0, rightRMS: info.rms.dropFirst().first ?? 0,
        audioBytes: UInt64(max(0, info.byteCount)),
        audioPresent: audio != nil && info.audioPacketTime != nil && info.sampleFrameCount > 0,
        activityPeak: SourceAudioMeterInput.activity(peaks: info.peaks, rms: info.rms).peak,
        activityRMS: SourceAudioMeterInput.activity(peaks: info.peaks, rms: info.rms).rms,
        sampleRate: audio?.sampleRate), token: token)
    case .rawAudio(let packet):
      let state = lock.withLock { () -> (Bool, CaptureFrameInfo?) in
        let matches = declaredEpoch == delivery.epochID && declaredSource?.signature == delivery.formatSignature &&
          declaredAudio == .present(packet.format)
        let pair = packet.pairedFrameSequence.flatMap { sequence in
          pairedFrame.flatMap { $0.sequence == sequence && $0.info.signalValid ? $0.info : nil }
        }
        return (matches, pair)
      }
      guard state.0 else {
        refuseSourceContract(SourceAdmissionRefusal(stage: .capture, formatDescription: "source audio",
          reason: "raw audio format differs from the immutable source audio contract"), token: token)
        return
      }
      audioMeterTap.ingest(packet)
      let pending = lock.withLock { () -> (FeedID, UInt64, SourceAdmissionSnapshot)? in
        guard let feed = activeFeedID, let route = recordingCallbacks[feed], let source = declaredAdmission else { return nil }
        return (feed, route.install, source)
      }
      if let pending {
        if retainRecordingAudioDiscovery(packet, source: pending.2, pair: state.1,
          feed: pending.0, install: pending.1, token: token) { return }
        deliverRecordingAudio(packet, pair: state.1, source: pending.2, feed: pending.0, install: pending.1, token: token)
      }

    }
  }

  private func deliverRecordingAudio(_ packet: CaptureAudioPacket, pair: CaptureFrameInfo?, source: SourceAdmissionSnapshot?,
    feed: FeedID, install: UInt64, token: UInt64) {
    let selected = lock.withLock { () -> (RecordingRoute, RecordingTakeContext)? in
      guard generation == token, accepting, activeFeedID == feed, let route = recordingCallbacks[feed],
        route.install == install, route.sourceAdmissionAccepted, route.takeContextAccepted,
        let context = route.boundTakeContext else { return nil }
      return (route, context)
    }
    guard let (route, context) = selected else { return }
    if packet.format.clock == .pairedWithFrames, pair == nil {
      rejectRecordingMetadata(feedID: feed, install: install, token: token,
        message: "Recording paired source audio requires an explicit matching video frame.")
      return
    }
    let accepted: Bool
    if let source, let callback = route.callbacks.sourceAudioWithAdmission {
      // The writer owns declared layout, sample-grid conversion and exact high24
      // scaling. Packet PTS stays rational; sample rate does not imply a CMTime grid.
      accepted = callback(packet.planes, packet.sampleFrameCount, packet.format, packet.packetTime, context, source,
        pair?.presentationTime)
    } else if packet.format.clock != .pairedWithFrames, let callback = route.callbacks.sourceAudio {
      accepted = callback(packet.planes, packet.sampleFrameCount, packet.format, packet.packetTime, context)
    } else {
      #if ULTRACAM_TEST_SUPPORT
      // Compatibility-only callback spies have no declaration binders. Shipping
      // recorder adapters always use the declared PCM route above.
      if route.callbacks.sourceAdmission == nil, route.callbacks.takeContext == nil,
        packet.format.interleaved, packet.format.sample == .int32,
        packet.format.sampleRate == EmbeddedAudioFormat.sampleRate, packet.planes.count == 1 {
        receiveRawAudio(CaptureRawAudio(samples: packet.planes[0], packetTime: packet.packetTime,
          sampleFrames: UInt64(packet.sampleFrameCount), channels: packet.format.channels, bytesPerSample: 4),
          token: token, preparePair: true, pairTime: pair?.presentationTime, pairDuration: pair?.duration,
          meterPacket: false, expectedRecording: (feed, install))
        return
      }
      #endif
      rejectRecordingMetadata(feedID: feed, install: install, token: token,
        message: "Recording paired source audio requires a declaration-aware PCM recording callback.")
      return
    }
    if !accepted {
      rejectRecordingMetadata(feedID: feed, install: install, token: token,
        message: packet.format.clock == .pairedWithFrames ? "Recording paired source audio admission was refused." : nil)
    }
  }

  private func retainRecordingAudioDiscovery(_ packet: CaptureAudioPacket, source: SourceAdmissionSnapshot,
    pair: CaptureFrameInfo?, feed: FeedID, install: UInt64, token: UInt64) -> Bool {
    let outcome = lock.withLock { () -> Int in
      guard generation == token, accepting, let route = recordingCallbacks[feed], route.install == install,
        !route.takeContextRejected else { return 1 }
      let state = route.discovery
      guard !route.sourceAdmissionAccepted || !route.takeContextAccepted || state.draining || !state.pending.isEmpty else { return 0 }
      guard let audioClock = source.clockBindings.audio, packet.format.clock != .pairedWithFrames else {
        // Paired PCM still uses its explicit frame association; its video clock
        // is checked when the queue is reconciled with the resolved contract.
        if packet.format.clock != .pairedWithFrames { return 2 }
        return enqueueRecordingAudio(packet, source: source, pair: pair, state: state)
      }
      if let original = state.pending.compactMap({ media -> PendingRecordingAudio? in
        if case .audio(let audio) = media { return audio }; return nil
      }).first, original.source.clockBindings.audio != audioClock { return 2 }
      return enqueueRecordingAudio(packet, source: source, pair: pair, state: state)
    }
    if outcome == 2 {
      rejectRecordingMetadata(feedID: feed, install: install, token: token,
        message: "Recording audio discovery pending-media limit or clock contract exceeded; start a new take.")
    }
    return outcome != 0
  }

  /// Controller lock held; charge original PCM planes, with no conversion/copy.
  private func enqueueRecordingAudio(_ packet: CaptureAudioPacket, source: SourceAdmissionSnapshot,
    pair: CaptureFrameInfo?, state: RecordingDiscoveryState) -> Int {
    var bytes = 0
    for plane in packet.planes {
      let sum = bytes.addingReportingOverflow(plane.count)
      guard !sum.overflow else { return 2 }
      bytes = sum.partialValue
    }
    do {
      let lease = try state.budget.admit(bytes: bytes,
        duration: Double(packet.sampleFrameCount) / packet.format.sampleRate)
      state.pending.append(.audio(PendingRecordingAudio(packet: packet, source: source, pair: pair, lease: lease)))
      return 1
    } catch { return 2 }
  }

  /// Closes admission before scheduling visible failure, so malformed inputs
  /// cannot enter recording or be mislabeled as capacity/signal loss.
  private func refuseSourceContract(_ error: Error, token: UInt64) {
    let message = (error as? SourceAdmissionRefusal)?.description ?? "capture refused source contract: \(error)"
    failFromSource(message, token: token)
  }

  private func failFromSource(_ message: String, token: UInt64) {
    let close = lock.withLock { () -> Bool in
      guard generation == token, accepting else { return false }
      accepting = false
      pendingAudioAdmission = nil
      return true
    }
    guard close else { return }
    queue.async { self.fail(message, token: token) }
  }

  /// Counts padded backing storage using metadata only, without mapping pixels.
  private static func storageBytes(_ image: CVPixelBuffer) -> Int {
    let count = CVPixelBufferGetPlaneCount(image)
    let planes: [MediaStorageExtent.Plane]
    if count == 0 {
      planes = [.init(rowBytes: CVPixelBufferGetBytesPerRow(image), rows: CVPixelBufferGetHeight(image))]
    } else {
      planes = (0..<count).map { .init(rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, $0),
        rows: CVPixelBufferGetHeightOfPlane(image, $0)) }
    }
    let surfaceBytes = CVPixelBufferGetIOSurface(image).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) }
    return (try? MediaStorageExtent.allocationBytes(planes: planes,
      pixelBufferDataSize: CVPixelBufferGetDataSize(image), ioSurfaceAllocationSize: surfaceBytes)) ?? 0
  }

  private func appendRecordingVideo(_ route: RecordingRoute, image: CVPixelBuffer, pts: CMTime,
    duration: CMTime, signalValid: Bool, recordingFormatValid: Bool, sourceAdmission: SourceAdmissionSnapshot?,
    sourceMetadata: SourceAdmissionMetadata?, nativeTimecode: Timecode?, feed: FeedID?) {
    if route.sourceAdmissionAccepted, route.takeContextAccepted, recordingFormatValid {
      let validRecordingFrame: Bool
      if sourceAdmission != nil, sourceMetadata != nil {
        validRecordingFrame = recordingFormatValid && signalValid
      } else {
        #if ULTRACAM_TEST_SUPPORT
        // Legacy injected/derived-format fixtures retain their existing checks.
        validRecordingFrame = recordingFormatValid && signalValid && pts.isNumeric && pts.epoch == 0 && pts.value >= 0 &&
        duration.epoch == 0 &&
        (duration == VideoContract.fastDuration || duration == VideoContract.slowDuration) &&
        CVPixelBufferGetWidth(image) == 3840 && CVPixelBufferGetHeight(image) == 2160 &&
        VideoContract.tenBit422.contains(CVPixelBufferGetPixelFormatType(image)) &&
        (try? VideoBufferLayout.validate(image)) != nil
        #else
        validRecordingFrame = false
        #endif
      }
      let appended: Bool
      if let sourceAdmission, let sourceMetadata, let nativeVideo = route.callbacks.videoWithTimecode {
        appended = nativeVideo(image, sourceMetadata, sourceAdmission, validRecordingFrame, nativeTimecode)
      } else if let sourceAdmission, let sourceMetadata, let typedVideo = route.callbacks.videoWithAdmission {
        appended = typedVideo(image, sourceMetadata, sourceAdmission, validRecordingFrame)
      } else {
        appended = route.callbacks.video(image, pts, duration, validRecordingFrame)
      }
      // The take's first admitted frame opens it to audio, on this thread
      // before this callback's audio arrives; a newer install starts over.
      if appended, !route.videoStarted,
        let feed = feed {
        lock.withLock {
          if recordingCallbacks[feed]?.install == route.install { recordingCallbacks[feed]?.videoStarted = true }
        }
      }
    }
  }

  private func expireRecordingDiscovery(feedID: FeedID, install: UInt64, token: UInt64) {
    let expired = lock.withLock {
      generation == token && accepting && recordingCallbacks[feedID]?.install == install &&
        recordingCallbacks[feedID]?.boundTakeContext == nil && recordingCallbacks[feedID]?.takeContextRejected == false
    }
    #if ULTRACAM_TEST_SUPPORT
    defer { lock.withLock { auditHooks.discoveryDeadlineFinished }?() }
    #endif
    if expired {
      #if ULTRACAM_TEST_SUPPORT
      lock.withLock { auditHooks.discoveryDeadlineObserved }?()
      #endif
      rejectRecordingMetadata(feedID: feedID, install: install, token: token,
        message: "Recording audio discovery deadline expired; start a new take after the source resolves.",
        onlyWhileDiscoveryUnbound: true)
    }
  }

  /// Returns true when the frame is retained or the pending take was refused.
  private func retainRecordingDiscovery(_ route: RecordingRoute, image: CVPixelBuffer,
    source: SourceAdmissionSnapshot, metadata: SourceAdmissionMetadata, timecode: Timecode?,
    feed: FeedID, token: UInt64) -> Bool {
    let outcome = lock.withLock { () -> Int in
      guard generation == token, accepting, let current = recordingCallbacks[feed],
        current.install == route.install, !current.takeContextRejected else { return 1 }
      let state = current.discovery
      guard !current.sourceAdmissionAccepted || !current.takeContextAccepted || state.draining || !state.pending.isEmpty else { return 0 }
      do {
        let lease = try state.budget.admit(bytes: Self.storageBytes(image), duration: metadata.duration.seconds)
        state.pending.append(.video(PendingRecordingVideo(image: image, source: source, metadata: metadata,
          timecode: timecode, lease: lease)))
        return 1
      } catch { return 2 }
    }
    if outcome == 2 {
      rejectRecordingMetadata(feedID: feed, install: route.install, token: token,
        message: "Recording audio discovery pending-media limit exceeded; start a new take after the source resolves.")
    }
    return outcome != 0
  }

  private func drainRecordingDiscovery(feedID: FeedID, install: UInt64, token: UInt64) {
    let acquired = lock.withLock { () -> Bool in
      guard generation == token, accepting, let route = recordingCallbacks[feedID], route.install == install,
        !route.takeContextRejected, !route.discovery.draining else { return false }
      route.discovery.draining = true
      return true
    }
    guard acquired else { return }
    for _ in 0..<recordingDiscoveryPolicy.retention.maximumSlots {
      let item = lock.withLock { () -> (RecordingRoute, PendingRecordingMedia)? in
        guard generation == token, accepting, let route = recordingCallbacks[feedID], route.install == install,
          !route.takeContextRejected, route.takeContextAccepted else { return nil }
        guard !route.discovery.pending.isEmpty else { route.discovery.draining = false; return nil }
        return (route, route.discovery.pending.removeFirst())
      }
      guard let (route, media) = item else { return }
      switch media {
      case .video(let frame):
        appendRecordingVideo(route, image: frame.image, pts: frame.metadata.presentationTime,
          duration: frame.metadata.duration, signalValid: true, recordingFormatValid: true,
          sourceAdmission: frame.source, sourceMetadata: frame.metadata, nativeTimecode: frame.timecode, feed: feedID)
      case .audio(let audio):
        #if ULTRACAM_TEST_SUPPORT
        lock.withLock { auditHooks.pendingAudioDequeued }?()
        #endif
        deliverRecordingAudio(audio.packet, pair: audio.pair, source: audio.source, feed: feedID, install: install, token: token)
      }
    }
    let exhausted = lock.withLock { () -> Bool in
      guard let route = recordingCallbacks[feedID], route.install == install else { return false }
      route.discovery.draining = false
      return !route.discovery.pending.isEmpty
    }
    if exhausted {
      rejectRecordingMetadata(feedID: feedID, install: install, token: token,
        message: "Recording audio discovery replay could not drain its bounded queue; start a new take.")
    }
  }

  private func receive(_ image: CVPixelBuffer, at pts: CMTime, duration: CMTime?,
    signalValid: Bool, token: UInt64, recordingFormatValid: Bool = true,
    sourceAdmission: SourceAdmissionSnapshot? = nil, sourceMetadata: SourceAdmissionMetadata? = nil,
    hostTimeReference: CaptureHostTimeReference = .presentationStart, nativeTimecode: Timecode? = nil,
    captureHostTime: CMTime? = nil) {
    // One lock acquisition per frame on the driver thread (two on a take's first frame).
    var recovered: (frames: UInt64, seconds: TimeInterval)?
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
        lastValidSourcePTS = nil
      }
      if let lostAt = signalLostAt {
        // The first frame after a dropout: its gap is the dropout's cost,
        // never a device skip.
        signalLostAt = nil
        // VFR has no per-frame interval to count losses by.
        var lost: UInt64 = 0
        if sourceAdmission?.format.rate.isVariable != true, pts.isNumeric, let prior = lastValidSourcePTS,
          sourceDuration.isNumeric, sourceDuration.seconds > 0 {
          let elapsed = CMTimeSubtract(pts, prior).seconds
          if elapsed > 0, elapsed < 10 { lost = UInt64(max(0, (elapsed / sourceDuration.seconds).rounded() - 1)) }
        }
        let total = signalLostFrames.addingReportingOverflow(lost)
        signalLostFrames = total.overflow ? UInt64.max : total.partialValue
        lastSourcePTS = nil
        recovered = (lost, now - lostAt)
      }
      if pts.isNumeric {
        lastValidSourcePTS = pts
        if let prior = lastSourcePTS, sourceDuration.isNumeric, sourceDuration.seconds > 0 {
          let elapsed = CMTimeSubtract(pts, prior).seconds
          let intervals = elapsed / sourceDuration.seconds
          // A long timestamp jump is a discontinuity at every source cadence.
          // VFR has no expected per-frame interval from which to infer losses.
          if sourceAdmission?.format.rate.isVariable != true, elapsed > 0, elapsed < 10,
            intervals > 1.5, let missing = UInt64(exactly: intervals.rounded() - 1) {
            let total = sourceDrops.addingReportingOverflow(missing)
            sourceDrops = total.overflow ? UInt64.max : total.partialValue
          }
        }
        lastSourcePTS = pts
      }
      monitorSequence &+= 1
      return (route, frameDuration, monitorSequence, feed)
    }
    if let recovered { queue.async { self.logSignalReturn(recovered, token: token) } }
    guard let admitted else { return }
    // Recording takes every valid source frame directly on the driver thread,
    // independent of processing. Metadata-only checks: no pixel scan,
    // conversion or waiting. Malformed inputs stay out of the recorder while
    // its invalid-sample telemetry and processing's error reporting remain.
    if let route = admitted.0 {
      let pending: Bool
      if signalValid, recordingFormatValid, let sourceAdmission, let sourceMetadata, let feed = admitted.3 {
        pending = retainRecordingDiscovery(route, image: image, source: sourceAdmission,
          metadata: sourceMetadata, timecode: nativeTimecode, feed: feed, token: token)
      } else { pending = false }
      if !pending {
        appendRecordingVideo(route, image: image, pts: pts, duration: admitted.1, signalValid: signalValid,
          recordingFormatValid: recordingFormatValid, sourceAdmission: sourceAdmission,
          sourceMetadata: sourceMetadata, nativeTimecode: nativeTimecode, feed: admitted.3)
      }
    }
    guard let sequence = admitted.2 else { return }
    guard let lease = retentionBudget.admit(bytes: Self.storageBytes(image), duration: admitted.1.seconds) else {
      lock.withLock { coreRejectedFrames &+= 1 }
      return
    }
    lock.withLock {
      queuedFrames += 1
      maxQueuedFrames = max(maxQueuedFrames, queuedFrames)
    }
    let frame = CapturedFrame(image: image, pts: pts, duration: admitted.1,
      receivedAt: ProcessInfo.processInfo.systemUptime, sequence: sequence, retention: lease,
      epochRevision: lock.withLock { sourceEpochRevision }, sourceAdmission: sourceAdmission,
      sourceMetadata: sourceMetadata, hostTimeReference: hostTimeReference, captureHostTime: captureHostTime,
      videoMapping: lock.withLock { videoClockMapping })
    queue.async {
      // Source callbacks arrive at video cadence for hours. CoreMedia and
      // AVFoundation create autoreleased wrappers while a frame is encoded;
      // drain them after each serial work item.
      autoreleasepool {
        defer { self.lock.withLock { self.queuedFrames -= 1 } }
        guard self.isAccepting(token, epochRevision: frame.epochRevision) else { return }
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

  private func receiveRawAudio(_ audio: CaptureRawAudio, token: UInt64,
    preparePair: Bool = false, pairTime: CMTime? = nil, pairDuration: CMTime? = nil, meterPacket: Bool = true,
    expectedRecording: (FeedID, UInt64)? = nil) {
    let state = lock.withLock { () -> (SourceRecordingCallbackAdapter.Callbacks?, Bool)? in
      guard generation == token, accepting else { return nil }
      // A take takes audio from its first frame on (see `RecordingRoute`).
      let route = activeFeedID.flatMap { recordingCallbacks[$0] }
      let matchesInstall = expectedRecording.map { activeFeedID == $0.0 && route?.install == $0.1 } ?? true
      return (matchesInstall ? route.flatMap { $0.videoStarted && $0.sourceAdmissionAccepted && $0.takeContextAccepted ? $0.callbacks : nil } : nil, rawAudioProvidesStats)
    }
    guard let state else { return }
    if preparePair { state.0?.audioPair?(pairTime, pairDuration) }
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
    if meterPacket { audioMeterTap.ingest(audio) }
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
    #if ULTRACAM_TEST_SUPPORT
    if frame.sourceAdmission == nil {
    guard actual.width == 3840, actual.height == 2160, VideoContract.tenBit422.contains(actual.type) else {
      fail("Unsupported detected input: \(actual.label). Expected 4K 10-bit 4:2:2.", token: token)
      return
    }
    guard frame.pts.isNumeric, frame.pts.epoch == 0, actual.duration.epoch == 0,
      actual.duration == VideoContract.fastDuration || actual.duration == VideoContract.slowDuration else {
      fail("Unsupported or invalid detected frame timing.", token: token)
      return
    }
    }
    #endif
    do {
      if frame.sourceAdmission == nil { try VideoBufferLayout.validate(input) }
      let effective = effectiveConfiguration(
        source: frame.sourceAdmission, duration: frame.duration)
      establish(effective, inputType: actual.type, sourceFormat: frame.sourceAdmission?.format)
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
      // Temporal selection happens before any GPU work or buffer allocation;
      // complete bypass keeps the source duration and so every frame. The
      // monitor shows the output's frames only, so with a lower output rate
      // (59.94 to 29.97) the picture runs at that rate too.
      let selected = frameRateGate.shouldDeliver(frame.pts, duration: effective.duration)
      // No downstream demand: keep metadata/detection alive without allocating,
      // submitting GPU work or staging raw buffers that nobody can consume.
      guard cameraConnected || cameraConnecting || hasPreview || processedHandler != nil else {
        if let sink, selected { offerSourceOnlyInOrder(sink, frame: frame, token: token, untouched: effective.untouched) }
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
      guard selected else { return }
      // Created on first demand; a complete bypass still uses it for the owned GPU copy.
      let processor = try makeProcessor()
      try ensurePrepared(effective, wait: false)
      let item = DeliveryItem(token: token, sequence: frame.sequence, source: sink == nil ? nil : input,
        pts: frame.pts, hostTime: hostTime(for: frame.pts, duration: effective.duration, image: input,
          reference: frame.hostTimeReference, sourceDuration: frame.duration, mapping: frame.videoMapping, captureHostTime: frame.captureHostTime),
        duration: effective.duration, receivedAt: frame.receivedAt, encodeStart: entryTime,
        pipelineEnabled: pipelineEnabled, applyLUT: effective.applyLUT,
        preview: previewEnabled ? services.preview : nil,
        cameraAttempt: cameraAttempt, monitorSink: sink, untouched: effective.untouched,
        processedHandler: processedHandler, retention: frame.retention, epochRevision: frame.epochRevision,
        sourceAdmission: frame.sourceAdmission)
      let completion: LUTProcessor.Completion = { [self] completed in
        // GPU completion queue: the frame is finished. Hand it to delivery in
        // commit order (the processor releases completions in order).
        deliveryQueue.async { autoreleasepool { self.deliver(item, completed) } }
      }
      if let source = frame.sourceAdmission, let metadata = frame.sourceMetadata {
        if effective.untouched {
          try processor.submitPassthrough(input, source: source, metadata: metadata,
            isCurrent: { isAccepting(token, epochRevision: frame.epochRevision) }, completion: completion)
        } else {
          try processor.submit(input, configuration: effective, source: source, metadata: metadata,
            isCurrent: { isAccepting(token, epochRevision: frame.epochRevision) }, completion: completion)
        }
      } else {
        #if ULTRACAM_TEST_SUPPORT
      if effective.untouched {
        // The preview, the meeting-app camera and Program get an owned copy;
        // the capture card may reuse its buffer while they still display it.
        try processor.submitPassthrough(input, isCurrent: { isAccepting(token, epochRevision: frame.epochRevision) }, completion: completion)
      } else {
        try processor.submit(input, configuration: effective, isCurrent: { isAccepting(token, epochRevision: frame.epochRevision) },
          completion: completion)
      }
        #else
        throw VideoError.message("capture refused undeclared source contract")
        #endif
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

  /// A monitor offer for a frame that skips the GPU (no other consumer).
  /// Ordered behind every frame already on the GPU, whose offers are made
  /// when they complete.
  private func offerSourceOnlyInOrder(
    _ sink: any MonitorFrameSink, frame: CapturedFrame, token: UInt64, untouched: Bool
  ) {
    let offer: @Sendable () -> Void = { [self, deliveryQueue] in
      deliveryQueue.async {
        defer { withExtendedLifetime(frame.retention) {} }
        guard self.isAccepting(token, epochRevision: frame.epochRevision) else { return }
        sink.offer(frame.image, pts: frame.pts, captureGeneration: token, sequence: frame.sequence,
          untouched: untouched, sourceFormat: frame.sourceAdmission?.format)
      }
    }
    if let processor { processor.afterCommittedFrames(offer) } else { offer() }
  }

  /// Delivery queue, in commit order, after the frame's GPU work completed.
  /// Monitor, preview and camera first; Program last, so a Program stall
  /// can't hold this camera's own outputs.
  private func deliver(_ item: DeliveryItem, _ completed: LUTProcessor.Completed) {
    defer { withExtendedLifetime(item.retention) {} }
    #if ULTRACAM_TEST_SUPPORT
    defer { lock.withLock { auditHooks.deliveryFinished }?() }
    #endif
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
    let rendered: CVPixelBuffer
    switch completed.result {
    case .success(let output): rendered = output
    case .failure(let error):
      queue.async { self.fail(error.localizedDescription, token: item.token) }
      return
    }
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
    let timing = completed.timing
    let outputWidth = CVPixelBufferGetWidth(rendered), outputHeight = CVPixelBufferGetHeight(rendered)
    let outputType = CVPixelBufferGetPixelFormatType(rendered)
    if let sink = item.monitorSink, let source = item.source {
      sink.offer(source, pts: item.pts, captureGeneration: item.token, sequence: item.sequence,
        untouched: item.untouched, sourceFormat: item.sourceAdmission?.format)
    }
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
    let processingMS = (timing.completed - item.encodeStart) * 1000
    services.didProcess(processingMS, (item.encodeStart - item.receivedAt) * 1000)
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
    let sample: CMSampleBuffer
    do { sample = try sampleFactory.sample(rendered, at: item.hostTime, duration: item.duration) }
    catch {
      queue.async { self.fail(error.localizedDescription, token: item.token) }
      return
    }
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
    item.preview?(sample)
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
    let outcome = camera.send(sample, attempt: item.cameraAttempt, using: services.send)
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
    if let handler = item.processedHandler {
      let metadata = ProcessedFrameMetadata(
        presentationTime: item.pts, duration: item.duration,
        width: outputWidth, height: outputHeight, pixelFormat: UInt32(outputType))
      handler(ProcessedFrame(payload: rendered, metadata: metadata), item.token)
    }
    let report = DeliveryReport(item: DeliveryMetadata(item), outcome: outcome,
      output: InputFormat(width: outputWidth, height: outputHeight, type: outputType, duration: item.duration),
      processingMS: processingMS, gpuMS: timing.gpuMS,
      latencyMS: (ProcessInfo.processInfo.systemUptime - item.receivedAt) * 1000)
    queue.async { self.didDeliver(report) }
  }

  /// Capture queue: counters, camera recovery and status for a delivered frame.
  private func didDeliver(_ report: DeliveryReport) {
    let item = report.item
    guard isAccepting(item.token, epochRevision: item.epochRevision) else { return }
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
  /// A source backend attaches the frame's hardware capture time on the
  /// host clock when it has one; that anchors the mapping instead of "now".
  private func hostTime(for sourceTime: CMTime, duration: CMTime, image: CVPixelBuffer,
    reference: CaptureHostTimeReference = .presentationStart, sourceDuration: CMTime? = nil,
    mapping: ClockMapping? = nil, captureHostTime: CMTime? = nil) -> CMTime {
    // An explicit mapping is an immutable per-frame capture revision. Its
    // nonzero origins and clock rate take precedence over arrival/legacy tags.
    if let mapping { return (try? mapping.hostTime(for: sourceTime)) ?? .invalid }
    let now: CMTime
    if let captured = captureHostTime, captured.isNumeric, captured.epoch == 0, captured >= .zero {
      now = reference == .presentationEnd ? CMTimeSubtract(captured, sourceDuration ?? duration) : captured
    } else if let captured = (CVBufferCopyAttachment(image, DeviceAPI.captureHostTimeAttachmentKey as CFString, nil)
      as? NSNumber)?.doubleValue,
      captured.isFinite, captured > 0 {
      let attached = CMTime(seconds: captured, preferredTimescale: 1_000_000_000)
      now = reference == .presentationEnd ? CMTimeSubtract(attached, sourceDuration ?? duration) : attached
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
      let peak = processor?.inFlight.peak ?? 0
      let depth = lock.withLock { (sourceDrops, peak, maxQueuedFrames, signalDropouts, signalLostFrames, coreRejectedFrames) }
      // Within five seconds of a new loss, otherwise every 30 s: about 120
      // lines an hour per camera, while every loss stays near its time.
      let losses = depth.0 &+ depth.4 &+ depth.5 &+ poolDrops &+ cameraDrops &+ lateFrames
      if losses != lastLoggedLosses || now - lastLogged >= 30 {
        lastLogged = now
        lastLoggedLosses = losses
        logger.notice("Live \(self.runLabel, privacy: .public) fps=\(self.outputFPS) delivered=\(self.frames) sourceDrops=\(depth.0) signalDropouts=\(depth.3) signalLostFrames=\(depth.4) outputStalls=\(self.poolDrops) cameraStalls=\(self.cameraDrops) lateFrames=\(self.lateFrames) maxInFlight=\(depth.1) maxBacklog=\(depth.2) gpuMS=\(self.gpuMS) latencyMS=\(self.latencyMS)")
      }
    }
    publishCurrent(token: token)
  }

  private func publishCurrent(token: UInt64, stopped: Bool = false) {
    let gpu = processor?.inFlight
    let depth = lock.withLock {
      (sourceDrops: sourceDrops, inFlight: gpu?.count ?? 0, maxInFlight: gpu?.peak ?? 0,
        backlog: queuedFrames, maxBacklog: maxQueuedFrames,
        signalDropouts: signalDropouts, signalLostFrames: signalLostFrames)
    }
    let retained = retentionBudget.snapshot
    let coreRefusals = lock.withLock { coreRejectedFrames }
    let deviceDrops = services.deviceDroppedFrames()
    let audio = media.snapshot()
    let visiblePreview = previewEnabled && services.preview != nil
    let videoLosses = depth.sourceDrops + depth.signalLostFrames + deviceDrops + coreRefusals + poolDrops + cameraDrops
    let update = CaptureUpdate(message: message, input: inputLabel, output: outputLabel,
      sourceFormat: lock.withLock { declaredAdmission?.format },
      sourceDuration: detected?.duration,
      mediaTime: stopped ? nil : lastDeliveredSourceTime,
      pipelineEnabledApplied: applied, frames: frames, dropped: videoLosses,
      processingMS: processingMS, previewDelivered: visiblePreview && !outputLabel.isEmpty && !stopped,
      sourceDrops: depth.sourceDrops, coreRejectedFrames: coreRefusals,
      retainedSourceFrames: retained.currentSlots, retainedSourceBytes: retained.currentBytes,
      maxRetainedSourceFrames: retained.peakSlots, maxRetainedSourceBytes: retained.peakBytes,
      deviceDrops: deviceDrops, signalDropouts: depth.signalDropouts, signalLostFrames: depth.signalLostFrames,
      ingestCPUCopyFrames: services.ingestCPUCopyFrames(), poolDrops: poolDrops, cameraDrops: cameraDrops,
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
      audioActivityPeak: stopped ? 0 : audio.activityPeak, audioActivityRMS: stopped ? 0 : audio.activityRMS,
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
  let retention: CaptureAdmissionBudget.Lease
  let epochRevision: UInt64
  let sourceAdmission: SourceAdmissionSnapshot?
  let sourceMetadata: SourceAdmissionMetadata?
  let hostTimeReference: CaptureHostTimeReference
  let captureHostTime: CMTime?
  let videoMapping: ClockMapping?
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
  let retention: CaptureAdmissionBudget.Lease
  let epochRevision: UInt64
  let sourceAdmission: SourceAdmissionSnapshot?
}

/// Scalar reporting never pins source storage, consumer closures, or admission leases.
private struct DeliveryMetadata: Sendable {
  let token: UInt64
  let pts: CMTime
  let cameraAttempt: UInt64
  let pipelineEnabled: Bool
  let applyLUT: Bool
  let epochRevision: UInt64
  init(_ item: DeliveryItem) {
    token = item.token; pts = item.pts; cameraAttempt = item.cameraAttempt
    pipelineEnabled = item.pipelineEnabled; applyLUT = item.applyLUT; epochRevision = item.epochRevision
  }
}

private struct DeliveryReport: @unchecked Sendable {
  let item: DeliveryMetadata
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
    var activityPeak: Float = 0
    var activityRMS: Float = 0
    var present = false
    var packetTime: CMTime?
    var bitrateKbps = 0.0
  }

  private let lock = NSLock()
  private var state = Snapshot()
  private var lastSampleFrames: UInt64 = 0
  private var lastPacketRate: Double?
  private var rateStart: Double = 0
  private var rateBytes: UInt64 = 0

  func reset() {
    lock.withLock {
      state = Snapshot()
      lastSampleFrames = 0
      lastPacketRate = nil
      rateStart = 0
      rateBytes = 0
    }
  }

  func resetPacketBaseline() {
    lock.withLock { state.packetTime = nil; lastSampleFrames = 0; lastPacketRate = nil }
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
      state.activityPeak = stats.activityPeak ?? Float(max(stats.leftPeak, stats.rightPeak))
      state.activityRMS = stats.activityRMS ?? Float(sqrt((stats.leftRMS * stats.leftRMS + stats.rightRMS * stats.rightRMS) / 2))
      // Typed media declares its actual PCM rate. Legacy callbacks without a
      // declaration retain their 48 kHz boundary contract.
      let packetRate = stats.sampleRate ?? EmbeddedAudioFormat.sampleRate
      guard packetRate.isFinite, packetRate > 0 else { return }
      if stats.audioPresent && stats.audioSampleFrames > 0 {
        state.sampleRate = Int(exactly: packetRate.rounded()) ?? 0
      }
      let packetTime = stats.audioPacketTime
      guard packetTime.isNumeric, stats.audioSampleFrames > 0 else { return }
      if lastPacketRate != packetRate {
        state.packetTime = nil
        lastSampleFrames = 0
        lastPacketRate = packetRate
      }
      if let prior = state.packetTime, prior.isNumeric {
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(packetTime, prior))
        if elapsed > 0, elapsed < 10,
          let expected = UInt64(exactly: (elapsed * packetRate).rounded()), expected > lastSampleFrames {
          let total = state.drops.addingReportingOverflow(expected - lastSampleFrames)
          state.drops = total.overflow ? UInt64.max : total.partialValue
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
/// lazily, so idle feeds allocate no Metal, CMIO, or source resources.  The
/// default factory makes a controller with its own `CaptureServices.live(feedID:)`
/// value and therefore an independent source session, input lease, and camera sink.
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
  /// Production uses one ordered typed stream. The legacy closures below are
  /// retained for fixture injection while those fixtures migrate independently.
  #if ULTRACAM_TEST_SUPPORT
  var startTyped: ((String, CaptureTiming, CaptureHandlers) throws -> Void)?
  var start: (String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void
  var startWithMedia: ((String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  var startWithRawAudio: ((String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    @escaping (CaptureRawAudio) -> Void, @escaping (String) -> Void) throws -> Void)?
  var startWithSourceAudio: ((String, Bool, @escaping (CVPixelBuffer, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void, @escaping (CaptureRawAudio) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  #else
  var startTyped: (String, CaptureTiming, CaptureHandlers) throws -> Void
  #endif
  var stop: () -> Void
  var connectWithSource: ((PipelineConfiguration, OSType, SourceFormat?) throws -> Void)? = nil
  var connect: (PipelineConfiguration, OSType) throws -> Void
  var disconnect: () -> Void
  var send: (CMSampleBuffer) throws -> Bool
  var preview: ((CMSampleBuffer) -> Void)?
  var didProcess: (Double, Double) -> Void = { _, _ in }
  #if ULTRACAM_TEST_SUPPORT
  var startAutomatic: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void, @escaping (String) -> Void) throws -> Void)?
  var startAutomaticWithMedia: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  var startAutomaticWithRawAudio: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void,
    @escaping (CaptureRawAudio) -> Void, @escaping (String) -> Void) throws -> Void)?
  var startAutomaticWithSourceAudio: ((String, @escaping (CVPixelBuffer, CMTime, CMTime, Bool) -> Void,
    @escaping (CaptureMediaStats) -> Void, @escaping (CaptureRawAudio) -> Void,
    @escaping (String) -> Void) throws -> Void)?
  #endif
  var followsSourceTiming: Bool {
    #if ULTRACAM_TEST_SUPPORT
    startTyped != nil || startAutomatic != nil
    #else
    true
    #endif
  }
  // Known backend storage layout is used only to prepare transport memory;
  // displayed input metadata always comes from received buffers and duration.
  var capturePixelFormat: OSType?
  var hostTime: () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
  /// Frames the device reported dropped since capture started.
  var ingestCPUCopyFrames: () -> UInt64 = { 0 }
  var sourcePauseAllowance: ((String) throws -> TimeInterval?)? = nil
  var deviceDroppedFrames: () -> UInt64 = { 0 }
  var cameraRetryInterval: TimeInterval = 2

  static func live(feedID: FeedID) -> CaptureServices {
    registryLive(feedID: feedID)
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
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64,
    untouched: Bool, sourceFormat: SourceFormat?)
  /// The capture stopped: rejects `rejected` (and every older generation) and
  /// drops the stopped generation's state.
  func invalidate(rejectingCaptureGeneration rejected: UInt64?)
}

extension MonitorFrameSink {
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64,
    untouched: Bool, sourceFormat: SourceFormat?) {
    offer(image, pts: pts, captureGeneration: captureGeneration, sequence: sequence, untouched: untouched)
  }

  /// A frame the camera processes (or Program's, already processed).
  func offer(_ image: CVPixelBuffer, pts: CMTime, captureGeneration: UInt64, sequence: UInt64) {
    offer(image, pts: pts, captureGeneration: captureGeneration, sequence: sequence, untouched: false)
  }
}
