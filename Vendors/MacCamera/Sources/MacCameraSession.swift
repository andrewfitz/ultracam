import AppKit
import AVFoundation
import CoreVideo
import Foundation

final class MacCameraCaptureSession: NSObject, CaptureSession, AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let plugin: MacCameraCapturePlugin
  private let claimToken = UUID()
  private let queue = DispatchQueue(label: "Ultracam.MacCamera.session", qos: .userInitiated)
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let counterLock = NSLock()
  private var cachedDropCount: UInt64 = 0
  private var cachedFailureCount: UInt64 = 0
  private enum State { case fresh, running, stopped }
  private var state: State = .fresh
  private var deviceID: String?
  private var timing: CaptureTiming?
  private var handlers: CaptureHandlers?
  private var session: AVCaptureSession?
  private var videoInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var requested: MacCameraCapturePlugin.RequestedMode?
  private var activeMode: MacCameraMode?
  private var hardwareRate: FrameRate?
  private var negotiatedFallback: OSType?
  private var audio: MacCameraAudio?
  private var observers: [NSObjectProtocol] = []
  private var graphObservers: [NSObjectProtocol] = []
  private var observations: [NSKeyValueObservation] = []
  private var wakeObservers: [NSObjectProtocol] = []
  private var sleeping = false
  private var graphInterrupted = false
  private var lastReopen: TimeInterval?
  private var videoRecoveryGeneration: UInt64 = 0
  private var videoOnlyRetryPending = false
  private var delivering = false
  private var signal = false
  private var signalProblem: String?
  private var modeNote: String?
  private var inputRefusal: String?
  private var sequence: UInt64 = 0
  private var epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
  private var captureClock: CMClock?
  private var clockID = ClockInstanceID()
  private var bindings: CaptureClockBindings?
  private var mapping: ClockMapping?
  private var mappingRevision: UInt64 = 0
  private var mappingUpdated: TimeInterval = 0
  private var forceEpoch = false
  private var declaration: SourceFormat?
  private var admission: SourceAdmissionSnapshot?
  private var sampleDescription: CMFormatDescription?
  private var descriptionMatchesBuffer = false
  private var cadence = MacCameraCadence()
  private var pendingVariable: TimedVideoSample?
  private var audioDeclaration: SourceAudioDeclaration = .absent
  private var audioTimeline = MacCameraAudioTimeline()
  private var audioInterrupted = false
  private var audioProblem: String?
  private var microphoneReconnectPending = false
  private var microphoneRetryScheduled = false
  private var microphoneReconnectAttempts = 0
  private var lastAudioArrival: TimeInterval?
  private var openingDeadline: TimeInterval?
  private struct TimedVideoSample {
    let sample: CMSampleBuffer
    let pts: CMTime
    let clock: CMClock
  }
  private var openingVideo: [TimedVideoSample] = []
  private var invalidVideoClockSince: TimeInterval?
  private var reportedVideoClock: String?
  private var reportedAudioClock: String?
  private var rejectedVideoTimestamps: UInt64 = 0
  private var rejectedAudioTimestamps: UInt64 = 0
  private var timestampVideoOnly = false
  private var openingAudio: [(packet: CaptureAudioPacket, clock: CMClock)] = []
  private var openingAudioBytes = 0
  private let retention = MacCameraBufferRetention()
  private var deviceDrops: [String: UInt64] = [:]
  private var unresolvedDurations: UInt64 = 0
  private var lastReport: TimeInterval = 0
  private var ordinaryBuffer = false

  init(plugin: MacCameraCapturePlugin) {
    self.plugin = plugin
    super.init()
    queue.setSpecific(key: queueKey, value: 1)
  }

  private func withSessionQueue<T>(_ work: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
    return try queue.sync(execute: work)
  }

  func withDevice<T>(_ work: (AVCaptureDevice, Bool) throws -> T) throws -> T {
    try withSessionQueue {
      guard state == .running, let device = videoInput?.device else {
        throw PluginError.unavailable("The assigned Mac Camera is disconnected.")
      }
      return try work(device, true)
    }
  }
  deinit { stop() }

  var counters: CaptureCounters {
    let backlog = retention.snapshot
    return counterLock.withLock {
      CaptureCounters(deviceDroppedFrames: cachedDropCount, conversionFailures: cachedFailureCount,
        currentBacklog: backlog.current, maximumBacklog: backlog.peak)
    }
  }

  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    try withSessionQueue {
      if state == .running {
        guard self.deviceID == deviceID, self.timing == timing else {
          throw PluginError.invalidState("This Mac Camera session already has a fixed configuration.")
        }
        return
      }
      guard state == .fresh else { throw PluginError.invalidState("Create a new Mac Camera session after stopping capture.") }
      guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
        if case .unavailable(let error) = plugin.authorizationStatus(deviceID: nil) { throw error }
        throw PluginError.unavailable("Enable Mac Camera access before starting capture.")
      }
      try plugin.beginSession(deviceID, token: claimToken, owner: self)
      self.deviceID = deviceID
      self.timing = timing
      self.handlers = handlers
      do {
        try open(deviceID: deviceID, timing: timing)
        state = .running
        installLifecycleObservers()
        report()
      } catch {
        closeGraph()
        self.handlers = nil
        state = .stopped
        plugin.endSession(deviceID, token: claimToken)
        throw error
      }
    }
  }

  func stop() {
    withSessionQueue {
      precondition(!delivering, "Never stop synchronously from capture delivery")
      guard state != .stopped else { return }
      state = .stopped
      handlers = nil
      closeGraph()
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers.removeAll()
      if !wakeObservers.isEmpty {
        for observer in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        wakeObservers.removeAll()
      }
      #if CAPTURE_LIFECYCLE_TESTS
      beforeFixtureClaimRelease?()
      #endif
      if let deviceID { plugin.endSession(deviceID, token: claimToken) }
    }
  }

  private func open(deviceID: String, timing: CaptureTiming, allowAudio: Bool = true) throws {
    guard let device = plugin.device(deviceID), device.isConnected else {
      throw plugin.unavailableDeviceError(deviceID)
    }
    guard !device.isSuspended else { throw PluginError.unavailable("macOS paused the assigned camera.") }
    let requested = try plugin.resolveMode(for: device, id: deviceID, timing: timing)
    let prior = (device.activeFormat, device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration, device.isAutoVideoFrameRateEnabled)
    let graph = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureVideoDataOutput()
    let microphone = MacCameraAudio(selection: plugin.microphone(for: deviceID))
    session = graph
    videoInput = input
    videoOutput = output
    audio = microphone
    self.requested = requested

    do {
      try configureGraph(graph, input: input, output: output, microphone: allowAudio && !timestampVideoOnly ? microphone : nil, requested: requested)
      graph.startRunning()
      guard graph.isRunning else { throw PluginError.failed("AVFoundation could not start the assigned camera.") }
      // A macOS session can reselect the active hardware format at start.
      if !verify(requested, device: device) {
        graph.beginConfiguration()
        do {
          defer { graph.commitConfiguration() }
          try configureMode(requested, device: device, output: output)
        }
      }
      guard graph.isRunning, verify(requested, device: device) else {
        throw PluginError.failed("The camera could not keep the requested \(requested.label) after starting.")
      }
    } catch {
      let canRetryVideo = allowAudio && microphone.output != nil
      closeGraph()
      if device.isConnected, prior.0 != device.activeFormat || prior.1 != device.activeVideoMinFrameDuration ||
        prior.2 != device.activeVideoMaxFrameDuration || prior.3 != device.isAutoVideoFrameRateEnabled,
         (try? device.lockForConfiguration()) != nil {
        defer { device.unlockForConfiguration() }
        try? setMode(MacCameraMode(prior.0), minimum: prior.1, maximum: prior.2, device: device)
        if prior.3, !device.isAutoVideoFrameRateEnabled, device.activeFormat.isAutoVideoFrameRateSupported,
           !device.isVideoFrameDurationLocked, !device.isFollowingExternalSyncDevice {
          device.isAutoVideoFrameRateEnabled = true
        }
      }
      if canRetryVideo {
        try open(deviceID: deviceID, timing: timing, allowAudio: false)
        audioProblem = "The microphone prevented the selected video mode from opening. Capture is running with video only."
        return
      }
      throw error
    }
    activeMode = MacCameraMode(device.activeFormat)
    inputRefusal = nil
    modeNote = nil
    signalProblem = nil
    let currentRate = effectiveRate(for: device)
    hardwareRate = currentRate
    cadence.configure(rate: currentRate, advertised: activeMode?.ranges ?? [])
    lastAudioArrival = nil
    audioProblem = timestampVideoOnly ? "This camera and microphone could not share a verified clock. Capture is running with video only." : nil
    audioDeclaration = microphone.output == nil ? .absent : .unknown
    openingDeadline = nil
    installGraphObservers(graph, device: device)
  }

  private func configureGraph(_ graph: AVCaptureSession, input: AVCaptureDeviceInput, output: AVCaptureVideoDataOutput,
    microphone: MacCameraAudio?, requested: MacCameraCapturePlugin.RequestedMode) throws {
    graph.beginConfiguration()
    defer { graph.commitConfiguration() }
    guard graph.canAddInput(input) else { throw PluginError.busy("AVFoundation could not add the assigned camera.") }
    graph.addInputWithNoConnections(input)
    guard graph.canAddOutput(output) else { throw PluginError.failed("AVFoundation could not add the video output.") }
    graph.addOutputWithNoConnections(output)
    let ports = input.ports.filter { $0.mediaType == .video && $0.isEnabled }
    guard ports.count == 1 else { throw PluginError.unsupported("The assigned Mac Camera has no unique video port.") }
    let connection = AVCaptureConnection(inputPorts: ports, output: output)
    guard graph.canAddConnection(connection) else {
      throw PluginError.failed("AVFoundation could not connect the selected camera port.")
    }
    graph.addConnection(connection)
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = false
    }
    microphone?.attach(to: graph, cameraInput: input, delegate: self, queue: queue)
    try configureMode(requested, device: input.device, output: output)
  }

  private func configureMode(_ requested: MacCameraCapturePlugin.RequestedMode, device: AVCaptureDevice,
    output: AVCaptureVideoDataOutput) throws {
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    try setMode(requested.mode, minimum: requested.duration, maximum: requested.duration, device: device)
    let native = PixelFormatID(rawValue: requested.mode.pixel)
    let available = output.availableVideoPixelFormatTypes
    if let deviceID, !available.isEmpty { plugin.rememberFallbacks(available, modeID: requested.mode.id, deviceID: deviceID) }
    negotiatedFallback = nil
    if PixelFormatTable.entry(for: native)?.captureQualified != true, let fallback = requested.fallback {
      guard available.contains(fallback) else {
        throw PluginError.unsupported("This camera cannot deliver \(MacCameraMode.macCameraSubtypeName(fallback)) for the selected mode.")
      }
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: fallback]
      negotiatedFallback = fallback
    } else { output.videoSettings = [:] }
  }

  private func setMode(_ mode: MacCameraMode, minimum: CMTime?, maximum: CMTime?, device: AVCaptureDevice) throws {
    guard device.isConnected, device.formats.contains(mode.format) else {
      throw PluginError.unavailable("The capture format was removed before configuration.")
    }
    guard [minimum, maximum].compactMap({ $0 }).allSatisfy(mode.supports) else {
      throw PluginError.unsupported("The requested frame duration is outside the camera's supported ranges.")
    }
    if device.activeFormat != mode.format { device.activeFormat = mode.format }
    if let minimum, let maximum {
      guard !device.isVideoFrameDurationLocked, !device.isFollowingExternalSyncDevice else {
        throw PluginError.busy("The camera cadence is locked by another capture client or external sync.")
      }
      if device.isAutoVideoFrameRateEnabled {
        guard mode.format.isAutoVideoFrameRateSupported else {
          throw PluginError.unsupported("This camera does not permit changing its automatic Frame Rate.")
        }
        device.isAutoVideoFrameRateEnabled = false
      }
      let caps: [AVFrameRateRange?] = [
        device.isCenterStageActive ? mode.format.videoFrameRateRangeForCenterStage : nil,
        device.isPortraitEffectActive ? mode.format.videoFrameRateRangeForPortraitEffect : nil,
        device.isStudioLightActive ? mode.format.videoFrameRateRangeForStudioLight : nil,
        device.isBackgroundReplacementActive ? mode.format.videoFrameRateRangeForBackgroundReplacement : nil,
        device.reactionEffectsInProgress.isEmpty ? nil : mode.format.videoFrameRateRangeForReactionEffectsInProgress
      ]
      guard caps.compactMap({ $0 }).allSatisfy({ $0.minFrameDuration <= minimum && maximum <= $0.maxFrameDuration }) else {
        throw PluginError.unsupported("A macOS video effect limits the selected Frame Rate. Change the effect in Control Center or select another rate.")
      }
      if minimum > device.activeVideoMaxFrameDuration {
        device.activeVideoMaxFrameDuration = maximum
        device.activeVideoMinFrameDuration = minimum
      } else {
        device.activeVideoMinFrameDuration = minimum
        device.activeVideoMaxFrameDuration = maximum
      }
    }
  }

  private func verify(_ requested: MacCameraCapturePlugin.RequestedMode, device: AVCaptureDevice) -> Bool {
    guard device.activeFormat == requested.mode.format else { return false }
    guard let duration = requested.duration else { return true }
    return !device.isAutoVideoFrameRateEnabled &&
      device.activeVideoMinFrameDuration == duration && device.activeVideoMaxFrameDuration == duration
  }

  private func closeGraph() {
    observations.removeAll()
    for observer in graphObservers { NotificationCenter.default.removeObserver(observer) }
    graphObservers.removeAll()
    if let session {
      videoOutput?.setSampleBufferDelegate(nil, queue: nil)
      if session.isRunning { session.stopRunning() }
      session.beginConfiguration()
      audio?.detach(from: session)
      if let videoOutput, session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
      if let videoInput, session.inputs.contains(videoInput) { session.removeInput(videoInput) }
      session.commitConfiguration()
    }
    session = nil
    graphInterrupted = false
    videoInput = nil
    videoOutput = nil
    negotiatedFallback = nil
    hardwareRate = nil
    discardPendingDuration()
    openingVideo.removeAll()
    openingAudio.removeAll()
    openingAudioBytes = 0
    openingDeadline = nil
    microphoneReconnectPending = false
    microphoneReconnectAttempts = 0
  }

  private func installLifecycleObservers() {
    observeDevices(AVCaptureDevice.wasConnectedNotification, connected: true)
    observeDevices(AVCaptureDevice.wasDisconnectedNotification, connected: false)
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
      let sleeps = name == NSWorkspace.willSleepNotification
      wakeObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        self?.queue.async { [weak self] in
          guard let self, self.state == .running else { return }
          self.sleeping = sleeps
          if sleeps {
            self.videoRecoveryGeneration &+= 1
            self.pauseVideo("The Mac is sleeping.")
          }
          else { self.recoverVideo() }
        }
      })
    }
  }

  private func observeDevices(_ name: Notification.Name, connected: Bool) {
    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
      guard let device = note.object as? AVCaptureDevice else { return }
      let uid = device.uniqueID
      let identity = ObjectIdentifier(device)
      self?.queue.async { [weak self] in
        guard let self, self.state == .running else { return }
        self.deviceConnectionChanged(uid, identity: identity, connected: connected)
      }
    })
  }

  private func installGraphObservers(_ graph: AVCaptureSession, device: AVCaptureDevice) {
    observations = [
      device.observe(\.activeFormat) { [weak self] _, _ in
        self?.queue.async { [weak self] in self?.refreshMode() }
      },
      device.observe(\.activeVideoMinFrameDuration) { [weak self] _, _ in
        self?.queue.async { [weak self] in self?.refreshMode() }
      },
      device.observe(\.activeVideoMaxFrameDuration) { [weak self] _, _ in
        self?.queue.async { [weak self] in self?.refreshMode() }
      },
      device.observe(\.isInUseByAnotherApplication) { [weak self] _, _ in
        self?.queue.async { [weak self] in self?.report() }
      },
      device.observe(\.isSuspended) { [weak self] _, _ in
        self?.queue.async { [weak self] in
          guard let self, self.state == .running, let device = self.videoInput?.device else { return }
          if device.isSuspended { self.pauseVideo("macOS paused this camera.") }
          else { self.recoverVideo() }
        }
      }
    ]
    let graphID = ObjectIdentifier(graph)
    for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification,
                 AVCaptureSession.runtimeErrorNotification] {
      graphObservers.append(NotificationCenter.default.addObserver(forName: name, object: graph, queue: nil) { [weak self] note in
        let error = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
        self?.queue.async { [weak self] in
          guard let self, self.state == .running, let graph = self.session, ObjectIdentifier(graph) == graphID else { return }
          if name == AVCaptureSession.interruptionEndedNotification {
            self.graphInterrupted = false
            self.recoverVideo()
          }
          else if name == AVCaptureSession.runtimeErrorNotification {
            self.pauseVideo(error ?? "AVFoundation reported a camera interruption.")
            self.recoverVideo(reopenRunning: true)
          } else {
            self.graphInterrupted = true
            self.pauseVideo("macOS interrupted camera capture.")
          }
        }
      })
    }
  }

  private func refreshMode() {
    guard state == .running, let device = videoInput?.device else { return }
    let changedFormat = activeMode?.format != device.activeFormat
    if changedFormat { activeMode = MacCameraMode(device.activeFormat) }
    let currentRate = effectiveRate(for: device)
    guard changedFormat || currentRate != hardwareRate else { return }
    if let output = videoOutput, negotiatedFallback != nil {
      output.videoSettings = [:]
      negotiatedFallback = nil
      modeNote = "The saved Input Delivery conversion applies to the previously selected capture mode."
    } else {
      modeNote = device.isInUseByAnotherApplication ? "Another app changed this camera's capture mode." : "macOS changed the camera's capture mode."
    }
    hardwareRate = currentRate
    cadence.configure(rate: currentRate, advertised: activeMode?.ranges ?? [])
    discardPendingDuration()
    forceEpoch = declaration != nil
    report()
  }

  private func deviceConnectionChanged(_ uid: String, identity: ObjectIdentifier, connected: Bool) {
    if let deviceID, MacCameraCapturePlugin.id(for: uid) == deviceID {
      if connected {
        recoverVideo()
      } else {
        if let current = videoInput?.device, ObjectIdentifier(current) != identity, current.isConnected { return }
        videoRecoveryGeneration &+= 1
        pauseVideo("The assigned Mac Camera disconnected.")
        closeGraph()
      }
    } else if uid == audio?.deviceUID, session != nil {
      if connected {
        microphoneReconnectAttempts = 0
        reattachMicrophone()
      }
      else {
        guard audio?.isCurrentDisconnect(identity) == true else { return }
        microphoneReconnectPending = false
        let reason = "The selected microphone disconnected."
        interruptAudio(reason)
        audioProblem = reason
        report()
      }
    }
  }

  private func pauseVideo(_ reason: String) {
    let changed = signal || signalProblem != reason
    signal = false
    signalProblem = reason
    discardPendingDuration()
    interruptAudio(reason)
    if changed { emit(.event(.signalLost(reason: reason))) }
    report()
  }

  private func recoverVideo(reopenRunning: Bool = false) {
    videoRecoveryGeneration &+= 1
    recoverVideo(generation: videoRecoveryGeneration, attempt: 0, reopenRunning: reopenRunning)
  }

  private func recoverVideo(generation: UInt64, attempt: Int, reopenRunning: Bool) {
    guard state == .running, generation == videoRecoveryGeneration, !sleeping,
      let deviceID, let timing, !graphInterrupted else { return }
    if session?.isRunning == true, !reopenRunning { return }
    let now = ProcessInfo.processInfo.systemUptime
    let reopeningTooSoon = reopenRunning && (lastReopen.map { now - $0 < 2 } ?? false)
    if !reopeningTooSoon, let device = plugin.device(deviceID), device.isConnected, !device.isSuspended {
      lastReopen = now
      closeGraph()
      do {
        try open(deviceID: deviceID, timing: timing)
        forceEpoch = declaration != nil
        return
      } catch { pauseVideo(error.localizedDescription) }
    }
    // Connection notifications can precede the discovery refresh. A failed
    // open cannot rely on future frames or notifications to trigger recovery.
    let delays: [TimeInterval] = [0.25, 0.5, 1, 2, 4]
    guard attempt < delays.count else { return }
    queue.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
      self?.recoverVideo(generation: generation, attempt: attempt + 1, reopenRunning: reopenRunning)
    }
  }

  private func reattachMicrophone() {
    guard state == .running, !timestampVideoOnly, let graph = session, let input = videoInput, let audio else { return }
    guard graph.isRunning, !graphInterrupted, !sleeping else {
      scheduleMicrophoneRetry()
      return
    }
    if audio.output != nil, lastAudioArrival != nil, !audioInterrupted {
      microphoneReconnectPending = false
      return
    }
    guard handlers?.isRecording() != true else {
      if !microphoneReconnectPending {
        audioProblem = "The microphone can reconnect after this take ends."
        report()
      }
      scheduleMicrophoneRetry()
      return
    }
    microphoneReconnectPending = false
    microphoneReconnectAttempts += 1
    let device = input.device
    let oldFormat = device.activeFormat
    let oldMinimum = device.activeVideoMinFrameDuration
    let oldMaximum = device.activeVideoMaxFrameDuration
    let oldAutoRate = device.isAutoVideoFrameRateEnabled
    let previousClock = graph.synchronizationClock
    graph.beginConfiguration()
    if audio.output != nil { audio.detach(from: graph) }
    audio.attach(to: graph, cameraInput: input, delegate: self, queue: queue)
    graph.commitConfiguration()

    let captureModePreserved = {
      device.activeFormat == oldFormat && device.activeVideoMinFrameDuration == oldMinimum &&
        device.activeVideoMaxFrameDuration == oldMaximum && device.isAutoVideoFrameRateEnabled == oldAutoRate
    }
    if !graph.isRunning || !captureModePreserved() || !Self.hasUsableSessionClock(graph) {
      graph.beginConfiguration()
      if audio.output != nil { audio.detach(from: graph) }
      if !captureModePreserved(), (try? device.lockForConfiguration()) != nil {
        defer { device.unlockForConfiguration() }
        try? setMode(MacCameraMode(oldFormat), minimum: oldMinimum, maximum: oldMaximum, device: device)
        if oldAutoRate, !device.isAutoVideoFrameRateEnabled, device.activeFormat.isAutoVideoFrameRateSupported,
           !device.isVideoFrameDurationLocked, !device.isFollowingExternalSyncDevice {
          device.isAutoVideoFrameRateEnabled = true
        }
      }
      graph.commitConfiguration()
      if !graph.isRunning { graph.startRunning() }
      if !graph.isRunning || !captureModePreserved() || !Self.hasUsableSessionClock(graph) {
        reopenAfterMicrophoneDisturbedVideo()
      }
      audioProblem = "Reconnecting the microphone disturbed the camera's capture mode or clock. Capture will use video only."
      report()
      return
    }
    if let clock = graph.synchronizationClock, previousClock.map({ !CFEqual($0, clock) }) ?? false {
      replaceClock(clock)
      cadence.resetPresentationTime()
      discardPendingDuration()
    }
    if audio.output == nil, microphoneReconnectAttempts < 3 { scheduleMicrophoneRetry() }
    audioProblem = audio.output == nil ? audio.status : nil
    report()
  }

  private func scheduleMicrophoneRetry() {
    microphoneReconnectPending = true
    guard !microphoneRetryScheduled else { return }
    microphoneRetryScheduled = true
    queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      self.microphoneRetryScheduled = false
      if self.microphoneReconnectPending { self.reattachMicrophone() }
    }
  }

  private static func hasUsableSessionClock(_ graph: AVCaptureSession) -> Bool {
    guard let clock = graph.synchronizationClock else { return false }
    return clockMapping(clock, anchor: CMClockGetTime(clock)) != nil
  }

  private func reopenAfterMicrophoneDisturbedVideo() {
    guard let deviceID, let timing else { return }
    closeGraph()
    do {
      try open(deviceID: deviceID, timing: timing, allowAudio: false)
      forceEpoch = declaration != nil
    } catch { pauseVideo(error.localizedDescription) }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard state == .running else { return }
    if output === audio?.output { receiveAudio(sampleBuffer, from: connection) }
    else if output === videoOutput { receiveVideo(sampleBuffer, from: connection) }
  }

  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard state == .running, output === videoOutput else { return }
    let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
    noteDrop(reason ?? "Unknown")
  }

  private func noteDrop(_ reason: String) {
    deviceDrops[reason, default: 0] += 1
    counterLock.withLock { cachedDropCount += 1 }
    cadence.noteDriverDrop()
    discardPendingDuration()
    if reason == kCMSampleBufferDroppedFrameReason_Discontinuity as String {
      forceEpoch = declaration != nil
      cadence.resetPresentationTime()
    }
  }

  private func receiveVideo(_ sample: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard !sleeping, let graph = session, graph.isRunning, !graphInterrupted,
      videoInput?.device.isSuspended == false else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard let clock = graph.synchronizationClock,
      let normalized = normalizeTimestamp(sample, sessionClock: clock, connection: connection, audio: false) else {
      rejectedVideoTimestamps += 1
      discardPendingDuration()
      let since = invalidVideoClockSince ?? now
      invalidVideoClockSince = since
      if now - since >= 0.5, audio?.output != nil, !timestampVideoOnly {
        scheduleVideoOnlyRetry(after: 0)
      } else if now - since >= 0.5 {
        refuseVideo("The camera timeline cannot be synchronized to host time.")
      }
      return
    }
    invalidVideoClockSince = nil
    let video = TimedVideoSample(sample: sample, pts: normalized, clock: clock)
    if let pendingClock = openingAudio.last?.clock, !CFEqual(pendingClock, clock) {
      openingAudio.removeAll()
      openingAudioBytes = 0
      if declaration == nil, audio?.output != nil { audioDeclaration = .unknown }
    }
    if audioDeclaration == .unknown {
      let deadline = openingDeadline ?? now + 0.25
      openingDeadline = deadline
      if now < deadline, openingVideo.count < 4 {
        openingVideo.append(video)
        return
      }
      audioProblem = audioProblem ?? "The selected microphone has not delivered usable PCM."
      resolveOpeningAudio(.absent)
    }
    if case .present = audioDeclaration, let lastAudioArrival, now - lastAudioArrival > 0.25 {
      interruptAudio("The selected microphone stopped delivering samples.")
    }
    processVideo(video)
    if now - lastReport >= 1 {
      refreshMode()
      report()
    }
  }

  private func retryVideoWithoutAudio() {
    guard let deviceID, let timing else { return }
    if declaration != nil, handlers?.isRecording() == true {
      pauseVideo("The camera timeline cannot be verified. Video-only recovery will wait for this take to end.")
      scheduleVideoOnlyRetry(after: 0.5)
      return
    }
    timestampVideoOnly = true
    pauseVideo("The camera and selected microphone did not provide a usable shared timeline.")
    closeGraph()
    do {
      try open(deviceID: deviceID, timing: timing, allowAudio: false)
      forceEpoch = declaration != nil
      audioProblem = "This camera and microphone could not share a verified clock. Capture is running with video only."
      report()
    } catch { refuseVideo(error.localizedDescription) }
  }

  private func scheduleVideoOnlyRetry(after delay: TimeInterval) {
    guard !videoOnlyRetryPending else { return }
    videoOnlyRetryPending = true
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.videoOnlyRetryPending = false
      guard self.state == .running, !self.sleeping, !self.graphInterrupted,
        self.invalidVideoClockSince != nil, self.audio?.output != nil else { return }
      self.retryVideoWithoutAudio()
    }
  }

  // AVFoundation's output timestamps are on the session clock. Check the
  // projected host timestamp before publishing because a driver can still
  // submit a startup placeholder. The input port clock is diagnostic only.
  private func normalizeTimestamp(_ sample: CMSampleBuffer, sessionClock: CMClock, connection: AVCaptureConnection, audio: Bool) -> CMTime? {
    let raw = sample.presentationTimeStamp
    guard raw.isNumeric, raw.epoch == 0, raw >= .zero else { return nil }
    let host = CMClockGetHostTimeClock()
    let now = CMClockGetTime(host)
    let sessionHost = CFEqual(sessionClock, host) ? raw : CMSyncConvertTime(raw, from: sessionClock, to: host)
    if Self.plausibleHostCaptureTime(sessionHost, at: now) { return raw }
    if audio ? reportedAudioClock == nil : reportedVideoClock == nil {
      let portHost = connection.inputPorts.first?.clock.map { CMSyncConvertTime(raw, from: $0, to: host) } ?? .invalid
      let note = String(format: "PTS %.6f, output PTS %.6f, mapped via session %.6f, mapped via input %.6f, host %.6f",
        raw.seconds, sample.outputPresentationTimeStamp.seconds, sessionHost.seconds, portHost.seconds, now.seconds)
      if audio { reportedAudioClock = note } else { reportedVideoClock = note }
    }
    return nil
  }

  private static func plausibleHostCaptureTime(_ hostPTS: CMTime, at now: CMTime) -> Bool {
    guard hostPTS.isNumeric, hostPTS.epoch == 0, hostPTS >= .zero else { return false }
    let age = (now - hostPTS).seconds
    return (-0.2...2).contains(age)
  }

  private func receiveAudio(_ sample: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard !sleeping, let graph = session, let clock = graph.synchronizationClock,
          graph.isRunning, !graphInterrupted, videoInput?.device.isSuspended == false, let audio else { return }
    guard normalizeTimestamp(sample, sessionClock: clock, connection: connection, audio: true) != nil else {
      rejectedAudioTimestamps += 1
      let reason = "The microphone timeline cannot be synchronized to host time."
      if case .present = audioDeclaration { interruptAudio(reason) }
      audioProblem = reason
      return
    }
    let domain: AudioClockDomain = CFEqual(clock, CMClockGetHostTimeClock()) ? .hostTime : .deviceClock
    do {
      let packet = try audio.packet(from: sample, clock: domain)
      lastAudioArrival = ProcessInfo.processInfo.systemUptime
      if !audioInterrupted { audioProblem = nil }
      if audioDeclaration == .unknown {
        appendOpeningAudio(packet, clock: clock)
        resolveOpeningAudio(.present(packet.format))
      } else if declaration == nil {
        audioDeclaration = .present(packet.format)
        appendOpeningAudio(packet, clock: clock)
      } else { publishAudio(packet, clock: clock) }
    } catch MacCameraAudio.SampleError.unsupportedEncoding {
      graph.beginConfiguration()
      let retried = audio.requestPCMConversion()
      graph.commitConfiguration()
      if !retried { refuseAudio("The microphone did not deliver supported PCM.") }
    } catch { refuseAudio(error.localizedDescription) }
  }

  private func publishAudio(_ packet: CaptureAudioPacket, clock: CMClock) {
    let resumingPublishedSegment = audioInterrupted && openingAudio.isEmpty
    let overlapsInterruptedSegment = resumingPublishedSegment && audioTimeline.overlapsExpectedTime(packet)
    let transition = audioTimeline.ingest(packet)
    let sameClock = captureClock.map { CFEqual($0, clock) } == true
    let verifyingResume = transition == .gap || resumingPublishedSegment
    let compatible = !verifyingResume || mapContinuity(Self.clockMapping(clock, anchor: packet.packetTime), at: packet.packetTime)
    let changedClock = !sameClock || !compatible || transition == .reset || overlapsInterruptedSegment
    if forceEpoch || changedClock || audioDeclaration != .present(packet.format) {
      forceEpoch = true
      if changedClock {
        openingAudio.removeAll()
        openingAudioBytes = 0
        replaceClock(clock)
      }
      appendOpeningAudio(packet, clock: clock)
      return
    }
    if verifyingResume {
      microphoneReconnectPending = false
      audioInterrupted = false
      audioProblem = nil
      emit(.event(.audioResumed))
      report()
    }
    emit(.rawAudio(packet))
  }

  private func refuseAudio(_ reason: String) {
    if audioDeclaration == .unknown { resolveOpeningAudio(.absent) }
    else { interruptAudio(reason) }
    audioProblem = reason
    report()
  }

  private func appendOpeningAudio(_ packet: CaptureAudioPacket, clock: CMClock) {
    if let last = openingAudio.last, last.packet.format != packet.format || !CFEqual(last.clock, clock) {
      openingAudio.removeAll()
      openingAudioBytes = 0
    }
    let bytes = packet.planes.reduce(0) { $0 + $1.count }
    guard openingAudio.count < 12, openingAudioBytes + bytes <= 1024 * 1024 else { return }
    openingAudio.append((packet, clock))
    openingAudioBytes += bytes
  }

  private func resolveOpeningAudio(_ declaration: SourceAudioDeclaration) {
    audioDeclaration = declaration
    openingDeadline = nil
    let video = openingVideo
    openingVideo.removeAll()
    guard let clock = session?.synchronizationClock else { return }
    for sample in video where CFEqual(sample.clock, clock) { processVideo(sample) }
  }

  private func interruptAudio(_ reason: String) {
    guard case .present = audioDeclaration, declaration != nil, !audioInterrupted else { return }
    audioInterrupted = true
    audioProblem = reason
    emit(.event(.audioInterrupted(reason: reason)))
    report()
  }

  private func validateVideoDelivery(_ image: CVPixelBuffer) throws {
    // A queued device observation can follow the first affected sample.
    // Recheck the consented hardware mode before admitting converted video.
    if negotiatedFallback != nil { refreshMode() }
    let pixel = CVPixelBufferGetPixelFormatType(image)
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    if let activeMode {
      let fallback = activeMode.id == requested?.mode.id ? negotiatedFallback : nil
      try MacCameraMode.validateDelivery(native: activeMode.pixel, fallback: fallback, delivered: pixel)
      try MacCameraMode.validateDimensions(width: activeMode.width, height: activeMode.height,
        deliveredWidth: width, deliveredHeight: height)
    }
    #if CAPTURE_LIFECYCLE_TESTS
    if let fixtureNative {
      try MacCameraMode.validateDelivery(native: fixtureNative, fallback: fixtureFallback, delivered: pixel)
    }
    if let fixtureDimensions {
      try MacCameraMode.validateDimensions(width: Int(fixtureDimensions.width), height: Int(fixtureDimensions.height),
        deliveredWidth: width, deliveredHeight: height)
    }
    #endif
  }

  private func processVideo(_ video: TimedVideoSample) {
    let sample = video.sample
    let clock = video.clock
    guard CMSampleBufferDataIsReady(sample), let image = sample.imageBuffer, let description = sample.formatDescription else {
      let native = activeMode.map { MacCameraMode.macCameraSubtypeName($0.pixel) } ?? "native"
      refuseVideo("The camera's \(native) samples contain no image buffer. Choose an available Input Delivery conversion in Hardware.")
      return
    }
    let pts = video.pts
    guard pts.isNumeric, pts.epoch == 0, pts >= .zero else { return }
    do { try validateVideoDelivery(image) }
    catch {
      discardPendingDuration()
      refuseVideo(String(describing: error))
      return
    }
    let domain: VideoClockDomain = CFEqual(clock, CMClockGetHostTimeClock()) ? .hostTime : .deviceClock
    if captureClock.map({ CFEqual($0, clock) }) != true {
      replaceClock(clock)
      cadence.resetPresentationTime()
    } else if !forceEpoch { refreshMapping(clock, pts: pts) }
    let tick = cadence.observe(pts: pts, sampleDuration: sample.duration)
    if tick.reset { replaceClock(clock) }
    if tick.gap || forceEpoch { discardPendingDuration() }

    let matchesBuffer = CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: image)
    let sameDescription = descriptionMatchesBuffer && matchesBuffer &&
      (sampleDescription.map { $0 === description || CFEqual($0, description) } ?? false)
    do {
      let candidate: SourceFormat
      if sameDescription, let declaration, let admission, declaration.rate == cadence.rate, declaration.clock == domain {
        try MacCameraMode.validateRange(description: description, image: image, entry: admission.entry)
        candidate = declaration
      } else { candidate = try MacCameraMode.sourceFormat(rate: cadence.rate, clock: domain, sample: sample) }
      let duration = cadence.duration(for: sample.duration)
      if duration == nil, MacCameraMode.validDuration(sample.duration) {
        unresolvedDurations += 1
        discardPendingDuration()
        return
      }
      if forceEpoch || declaration != candidate {
        discardPendingDuration()
        try declare(candidate, image: image, pts: pts, duration: duration, clock: clock)
      } else if let pending = pendingVariable {
        pendingVariable = nil
        let delta = pts - pending.pts
        if let pendingImage = pending.sample.imageBuffer, cadence.contains(delta) {
          emitFrame(pendingImage, pts: pending.pts, duration: delta)
        } else { unresolvedDurations += 1 }
      }
      sampleDescription = description
      descriptionMatchesBuffer = matchesBuffer
      if let duration {
        guard emitFrame(image, pts: pts, duration: duration) else { return }
      }
      else { pendingVariable = video }
      flushOpeningAudio(clock: clock)
      if !signal || inputRefusal != nil {
        signal = true
        signalProblem = nil
        inputRefusal = nil
        report()
      }
    } catch { refuseVideo(String(describing: error)) }
  }

  private func declare(_ candidate: SourceFormat, image: CVPixelBuffer, pts: CMTime, duration: CMTime?, clock: CMClock) throws {
    let redeclaration = declaration != nil
    let nextEpoch = CaptureEpochID(sessionID: epoch.sessionID, epoch: epoch.epoch + (redeclaration ? 1 : 0))
    // A microphone change may arrive after the video epoch was queued. Bind
    // the new declaration to the staged packets from the video sample's clock.
    let nextAudio = openingAudio.last.flatMap { CFEqual($0.clock, clock) ? $0.packet.format : nil }
      .map(SourceAudioDeclaration.present) ?? audioDeclaration
    let audioBinding: ClockInstanceID? = if case .present = nextAudio { clockID } else { nil }
    let nextBindings = CaptureClockBindings(video: clockID, audio: audioBinding)
    let snapshot = try SourceAdmissionSnapshot(format: candidate, epochID: nextEpoch, clockBindings: nextBindings, stage: .capture)
    // A malformed post-change sample must not finalize the active take.
    try snapshot.validate(SourceAdmissionMetadata(pixelBuffer: image, presentationTime: pts,
      duration: duration ?? candidate.rate.nominal, epochID: nextEpoch, formatSignature: candidate.signature), stage: .capture)
    guard let nextMapping = Self.clockMapping(clock, anchor: pts) else {
      throw PluginError.failed("The camera's synchronization clock could not be mapped to host time.")
    }
    declaration = candidate
    admission = snapshot
    epoch = nextEpoch
    bindings = nextBindings
    audioDeclaration = nextAudio
    mappingRevision = 0
    forceEpoch = false
    if redeclaration {
      audioTimeline.reset()
      audioInterrupted = false
      emit(.event(.discontinuity))
    }
    emit(.event(.formatChanged(candidate)))
    emit(.event(.audioFormatChanged(audioDeclaration)))
    updateMapping(nextMapping)
  }

  private func flushOpeningAudio(clock: CMClock) {
    guard !forceEpoch, declaration != nil, !openingAudio.isEmpty else { return }
    let packets = openingAudio
    openingAudio.removeAll()
    openingAudioBytes = 0
    for entry in packets where CFEqual(entry.clock, clock) && audioDeclaration == .present(entry.packet.format) {
      publishAudio(entry.packet, clock: clock)
    }
  }

  @discardableResult
  private func emitFrame(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime) -> Bool {
    guard let admission else { return false }
    do {
      try admission.validate(SourceAdmissionMetadata(pixelBuffer: image, presentationTime: pts, duration: duration,
        epochID: epoch, formatSignature: admission.formatSignature), stage: .capture)
    } catch { refuseVideo(String(describing: error)); return false }
    guard retention.reserve(image) else { return false }
    ordinaryBuffer = CVPixelBufferGetIOSurface(image) == nil
    var info = CaptureFrameInfo(epochID: epoch, formatSignature: admission.formatSignature, presentationTime: pts,
      duration: duration, signalValid: true, timecode: nil)
    info.captureHostTime = try? mapping?.hostTime(for: pts)
    emit(.frame(CapturedPixelBuffer(immutable: image), info))
    return true
  }

  private func discardPendingDuration() {
    if pendingVariable != nil { unresolvedDurations += 1; pendingVariable = nil }
  }

  private func refuseVideo(_ reason: String) {
    discardPendingDuration()
    counterLock.withLock { cachedFailureCount += 1 }
    guard inputRefusal != reason else { return }
    inputRefusal = reason
    signal = false
    emit(.event(.unsupportedInput(reason)))
    report()
  }

  private func replaceClock(_ clock: CMClock) {
    captureClock = clock
    clockID = ClockInstanceID()
    forceEpoch = declaration != nil
  }

  private static func clockMapping(_ clock: CMClock, anchor: CMTime) -> ClockMapping? {
    let host = CMClockGetHostTimeClock()
    if CFEqual(clock, host) { return try? ClockMapping(sourceAnchor: anchor, hostAnchor: anchor, rate: .one) }
    var sourceRate: Double = 0
    var sourceAnchor = CMTime.invalid
    var hostAnchor = CMTime.invalid
    guard CMSyncGetRelativeRateAndAnchorTime(clock, relativeTo: host, relativeRateOut: &sourceRate,
      anchorTimeOut: &sourceAnchor, relativeToAnchorTimeOut: &hostAnchor) == noErr,
      sourceRate.isFinite, sourceRate > 0.5, sourceRate < 1.5,
      sourceAnchor.isNumeric, sourceAnchor.epoch == 0, hostAnchor.isNumeric, hostAnchor.epoch == 0,
      let ratio = try? Rational(Int64((1_000_000_000 / sourceRate).rounded()), 1_000_000_000) else { return nil }
    let projection = CMSyncConvertTime(anchor, from: clock, to: host)
    guard projection.isNumeric, projection.epoch == 0, projection >= .zero else { return nil }
    return try? ClockMapping(sourceAnchor: anchor, hostAnchor: projection, rate: ratio)
  }

  private func mapContinuity(_ next: ClockMapping?, at pts: CMTime) -> Bool {
    guard let next, let mapping, let previous = try? mapping.hostTime(for: pts) else { return false }
    let oldSlope = Double(mapping.rate.numerator) / Double(mapping.rate.denominator)
    let newSlope = Double(next.rate.numerator) / Double(next.rate.denominator)
    return abs((next.hostAnchor - previous).seconds) <= 0.020 && abs(newSlope / oldSlope - 1) <= 0.002
  }

  private func refreshMapping(_ clock: CMClock, pts: CMTime) {
    guard !CFEqual(clock, CMClockGetHostTimeClock()), ProcessInfo.processInfo.systemUptime - mappingUpdated > 5,
      let update = Self.clockMapping(clock, anchor: pts) else { return }
    if mapContinuity(update, at: pts) { updateMapping(update) }
    else { replaceClock(clock) }
  }

  private func updateMapping(_ update: ClockMapping) {
    let revision = mappingRevision + 1
    emit(.event(.clockMappingChanged(CaptureClockMappingUpdate(epochID: epoch, clockID: clockID,
      revision: revision, effectiveSequence: sequence + 2, mapping: update))))
    mapping = update
    mappingRevision = revision
    mappingUpdated = ProcessInfo.processInfo.systemUptime
  }

  private func emit(_ payload: CaptureDelivery.Payload) {
    guard let handlers else { return }
    sequence += 1
    delivering = true
    defer { delivering = false }
    handlers.deliver(CaptureDelivery(sequence: sequence, epochID: epoch, formatSignature: declaration?.signature ?? "",
      clockBindings: bindings ?? CaptureClockBindings(video: clockID), mappingRevision: mappingRevision, payload: payload))
  }

  private func effectiveRate(for device: AVCaptureDevice) -> FrameRate {
    let shortest = device.activeVideoMinFrameDuration
    let longest = device.activeVideoMaxFrameDuration
    if device.isAutoVideoFrameRateEnabled, let activeMode,
       let fastest = activeMode.ranges.map(\.shortest).min(), let slowest = activeMode.ranges.map(\.longest).max(),
       fastest < slowest {
      let nominal = MacCameraMode.validDuration(shortest) ? min(max(shortest, fastest), slowest) : fastest
      return .variable(nominal: nominal, shortest: fastest, longest: slowest)
    }
    if MacCameraMode.validDuration(shortest), MacCameraMode.validDuration(longest), shortest <= longest {
      return shortest == longest ? .constant(shortest) : .variable(nominal: shortest, shortest: shortest, longest: longest)
    }
    return .constant(requested?.duration ?? activeMode?.rates.first?.duration ?? CMTime(value: 1, timescale: 30))
  }

  private func report() {
    guard state == .running, let deviceID else { return }
    lastReport = ProcessInfo.processInfo.systemUptime
    var status = videoInput.map { MacCameraCapturePlugin.baseStatus($0.device, running: true) }
      ?? CaptureDeviceStatus(availability: .inUseHere)
    status.signalLocked = signal
    status.detected = signal ? declaration : nil
    var detail: [String] = [modeNote, inputRefusal, signalProblem].compactMap { $0 }
    var facts: [DeviceFact] = []
    if let requested { facts.append(.init(id: "requested", group: .signal, label: "Requested", values: [requested.label])) }
    if let declaration {
      let subtype = MacCameraMode.macCameraSubtypeName(declaration.pixel.rawValue)
      facts.append(.init(id: "delivered", group: .signal, label: "Delivered",
        values: ["\(declaration.width) × \(declaration.height)", subtype,
          declaration.rate.isVariable ? "Variable cadence" : MacCameraMode.rateLabel(declaration.rate.nominal)]))
      if let activeMode, declaration.width != activeMode.width || declaration.height != activeMode.height {
        detail.append("The camera delivers \(declaration.width) × \(declaration.height) from an active \(activeMode.width) × \(activeMode.height) mode.")
      }
      if let activeMode, declaration.pixel.rawValue != activeMode.pixel {
        detail.append("\(MacCameraMode.macCameraSubtypeName(activeMode.pixel)) delivered as \(subtype).")
      }
      if let duration = requested?.duration, declaration.rate != .constant(duration) {
        detail.append("Delivered cadence differs from the requested \(MacCameraMode.rateLabel(duration)).")
      }
      if declaration.colour.primaries == .unspecified || declaration.colour.transfer == .unspecified {
        facts.append(.init(id: "color-tags", group: .signal, label: "Color tags",
          values: ["Incomplete. Some outputs require a Camera Log or LUT input declaration."]))
      }
    }
    if inputRefusal != nil, let videoOutput {
      let formats = videoOutput.availableVideoPixelFormatTypes.filter {
        PixelFormatTable.entry(for: PixelFormatID(rawValue: $0))?.captureQualified == true
      }
      if !formats.isEmpty { facts.append(.init(id: "delivery-formats", group: .signal,
        label: "Available delivery subtypes", values: formats.map(MacCameraMode.macCameraSubtypeName))) }
    }
    if let device = videoInput?.device {
      let effects = [
        (device.isCenterStageActive, "Center Stage"), (device.isPortraitEffectActive, "Portrait"),
        (device.isStudioLightActive, "Studio Light"), (device.isBackgroundReplacementActive, "Background Replacement"),
        (device.canPerformReactionEffects, "Reactions")
      ].filter { $0.0 }.map { $0.1 }
      if !effects.isEmpty { facts.append(.init(id: "system-effects", group: .signal, label: "macOS camera effects", values: effects)) }
    }
    if let audio { facts.append(.init(id: "microphone", group: .audio, label: "Microphone", values: [audioProblem ?? audio.status])) }
    status.facts += facts
    status.signalDetail = detail.isEmpty ? nil : detail.joined(separator: " ")
    if let inputRefusal {
      status.problems.append(DeviceProblem(id: "unsupported-delivery", severity: .warning,
        title: "Unsupported camera delivery", detail: inputRefusal))
    }
    var fields = facts.map { DeviceDiagnostics.Field(label: $0.label, value: $0.values.joined(separator: " · ")) }
    if let measured = cadence.measuredFPS { fields.append(.init(label: "Measured cadence", value: String(format: "%.2f fps", measured))) }
    fields += deviceDrops.keys.sorted().map { .init(label: "AVFoundation drop · \($0)", value: String(deviceDrops[$0, default: 0])) }
    fields.append(.init(label: "Inferred timestamp gaps", value: String(cadence.inferredGaps)))
    fields.append(.init(label: "Unresolved frame durations", value: String(unresolvedDurations)))
    fields.append(.init(label: "Capture buffers refused at retention limit", value: String(retention.snapshot.refused)))
    if declaration != nil { fields.append(.init(label: "Delivered pixel storage", value: ordinaryBuffer ? "Ordinary CVPixelBuffer" : "IOSurface-backed CVPixelBuffer")) }
    if rejectedVideoTimestamps > 0 { fields.append(.init(label: "Unverified video timestamps", value: String(rejectedVideoTimestamps))) }
    if rejectedAudioTimestamps > 0 { fields.append(.init(label: "Unverified microphone timestamps", value: String(rejectedAudioTimestamps))) }
    if let reportedVideoClock { fields.append(.init(label: "Video clock observation", value: reportedVideoClock)) }
    if let reportedAudioClock { fields.append(.init(label: "Microphone clock observation", value: reportedAudioClock)) }
    plugin.publishSessionStatus(status, id: deviceID, diagnostics: DeviceDiagnostics(counters: counters, temperatureCelsius: nil,
      signalPresent: signal, hostTimeMapped: mapping != nil, vendorFields: fields), token: claimToken)
  }

  #if CAPTURE_LIFECYCLE_TESTS
  private var beforeFixtureClaimRelease: (@Sendable () -> Void)?
  func claimFixture(deviceID: String, beforeRelease: (@Sendable () -> Void)? = nil) throws {
    try withSessionQueue {
      try plugin.beginSession(deviceID, token: claimToken, owner: self)
      self.deviceID = deviceID
      self.beforeFixtureClaimRelease = beforeRelease
      state = .running
    }
  }

  private var fixtureRate: FrameRate?
  private var fixtureNative: OSType?
  private var fixtureFallback: OSType?
  private var fixtureDimensions: CMVideoDimensions?
  func startFixture(handlers: CaptureHandlers, rate: FrameRate? = nil, native: OSType? = nil,
    fallback: OSType? = nil, dimensions: CMVideoDimensions? = nil) {
    withSessionQueue {
      self.handlers = handlers
      fixtureRate = rate
      fixtureNative = native
      fixtureFallback = fallback
      fixtureDimensions = dimensions
      if let rate { cadence.configure(rate: rate) }
      audioDeclaration = .absent
      state = .running
    }
  }
  func setFixtureDimensions(_ dimensions: CMVideoDimensions) {
    withSessionQueue {
      fixtureDimensions = dimensions
      cadence.resetPresentationTime()
      discardPendingDuration()
      forceEpoch = declaration != nil
    }
  }
  func deliverFixtureFrame(_ sample: CMSampleBuffer, verifyHostAt now: CMTime? = nil) {
    withSessionQueue {
      guard state == .running else { return }
      if let now, !Self.plausibleHostCaptureTime(sample.presentationTimeStamp, at: now) {
        rejectedVideoTimestamps += 1
        discardPendingDuration()
        return
      }
      if fixtureRate == nil, declaration == nil, MacCameraMode.validDuration(sample.duration) {
        cadence.configure(rate: .constant(sample.duration))
      }
      processVideo(TimedVideoSample(sample: sample, pts: sample.presentationTimeStamp, clock: CMClockGetHostTimeClock()))
    }
  }
  func reportFixtureDrop(_ reason: String) {
    withSessionQueue {
      guard state == .running else { return }
      noteDrop(reason)
    }
  }
  func deliverFixtureAudio(_ packet: CaptureAudioPacket) {
    withSessionQueue {
      guard state == .running else { return }
      if declaration == nil {
        appendOpeningAudio(packet, clock: CMClockGetHostTimeClock())
      } else { publishAudio(packet, clock: CMClockGetHostTimeClock()) }
    }
  }
  func interruptFixtureAudio() {
    withSessionQueue { interruptAudio("Fixture microphone paused.") }
  }
  var fixtureTiming: (measuredFPS: Double?, inferredGaps: UInt64, unresolvedDurations: UInt64) {
    withSessionQueue { (cadence.measuredFPS, cadence.inferredGaps, unresolvedDurations) }
  }
  #endif
}

private struct MacCameraCadence {
  private(set) var rate: FrameRate = .constant(CMTime(value: 1, timescale: 30))
  private var lastPTS: CMTime?
  private var observed: Double?
  private var advertisedBounds: (shortest: CMTime, longest: CMTime)?
  private var candidateDuration: CMTime?
  private var candidateCount = 0
  private var candidateSeconds = 0.0
  private var driverDropped = false
  private(set) var inferredGaps: UInt64 = 0
  var measuredFPS: Double? { observed.map { 1 / $0 } }

  mutating func configure(rate: FrameRate, advertised: [VendorCaptureRateRange] = []) {
    self.rate = rate
    if let shortest = advertised.map(\.shortest).min(), let longest = advertised.map(\.longest).max() {
      advertisedBounds = (shortest, longest)
    } else { advertisedBounds = nil }
    resetPresentationTime()
  }

  mutating func resetPresentationTime() {
    lastPTS = nil
    observed = nil
    candidateDuration = nil
    candidateCount = 0
    candidateSeconds = 0
    driverDropped = false
  }

  mutating func noteDriverDrop() { driverDropped = true }

  mutating func observe(pts: CMTime, sampleDuration: CMTime) -> (gap: Bool, reset: Bool) {
    defer { lastPTS = pts; driverDropped = false }
    guard let lastPTS else { return (false, false) }
    let delta = pts - lastPTS
    guard delta > .zero else { resetPresentationTime(); return (true, true) }
    let expected = bounds.longest.seconds
    let gap = delta.seconds > expected * 1.5
    if gap { inferredGaps += 1 }
    if !driverDropped, delta.seconds < max(1, expected * 4) {
      observed = observed.map { $0 * 0.85 + delta.seconds * 0.15 } ?? delta.seconds
      assessRateChange(delta: delta, sampleDuration: sampleDuration)
    } else { candidateCount = 0; candidateSeconds = 0 }
    return (gap || driverDropped, false)
  }

  private mutating func assessRateChange(delta: CMTime, sampleDuration: CMTime) {
    let prior = bounds
    let seconds = delta.seconds
    let closest = seconds < prior.shortest.seconds ? prior.shortest.seconds : prior.longest.seconds
    let departure = abs(seconds / closest - 1)
    // Real devices can timestamp neighboring frames asymmetrically even
    // while delivering their fixed rate over time. Only several consistent
    // measurements well outside the current bounds can retire a recording epoch.
    if contains(delta) || departure < 0.12 || spacingContradictsDuration(seconds, sample: sampleDuration) {
      candidateCount = 0
      candidateSeconds = 0
      return
    }
    if candidateCount > 0, let candidateDuration, abs(candidateDuration.seconds / seconds - 1) <= 0.05 {
      candidateCount += 1
      candidateSeconds += seconds
    } else {
      candidateDuration = delta
      candidateCount = 1
      candidateSeconds = seconds
    }
    guard candidateCount >= (departure >= 0.30 ? 3 : 6), candidateSeconds >= 0.25, let candidateDuration else { return }
    let measured = MacCameraMode.validDuration(sampleDuration) &&
      abs(sampleDuration.seconds / candidateDuration.seconds - 1) <= 0.05 ? sampleDuration : candidateDuration
    let shortest = min(prior.shortest, advertisedBounds?.shortest ?? prior.shortest, measured)
    let longest = max(prior.longest, advertisedBounds?.longest ?? prior.longest, measured)
    rate = .variable(nominal: measured, shortest: shortest, longest: longest)
    candidateCount = 0
    candidateSeconds = 0
  }

  private func spacingContradictsDuration(_ seconds: Double, sample: CMTime) -> Bool {
    guard contains(sample) else { return false }
    let frames = seconds / sample.seconds
    // A valid duration at the established rate plus periodic gaps is not
    // evidence of longer exposures. Short catch-up bursts are also ambiguous.
    return frames < 0.88 || (frames > 1.5 && abs(frames - frames.rounded()) <= 0.05)
  }

  private var bounds: (shortest: CMTime, longest: CMTime) {
    switch rate {
    case .constant(let duration): (duration, duration)
    case .variable(_, let shortest, let longest): (shortest, longest)
    }
  }

  func contains(_ duration: CMTime) -> Bool {
    MacCameraMode.validDuration(duration) && bounds.shortest <= duration && duration <= bounds.longest
  }

  func duration(for sample: CMTime) -> CMTime? {
    switch rate {
    case .constant(let duration): duration
    case .variable: contains(sample) ? sample : nil
    }
  }
}

private final class MacCameraBufferRetention: @unchecked Sendable {
  private let lock = NSLock()
  private var current = 0
  private var peak = 0
  private var refused: UInt64 = 0

  var snapshot: (current: Int, peak: Int, refused: UInt64) { lock.withLock { (current, peak, refused) } }

  private static let leaseKey = "org.ultracam.maccamera.retainedBuffer"

  func reserve(_ image: CVPixelBuffer) -> Bool {
    if let lease = CVBufferCopyAttachment(image, Self.leaseKey as CFString, nil) as? Lease, lease.retention === self {
      return true
    }
    let lease: Lease? = lock.withLock {
      guard current < 6 else { refused += 1; return nil }
      current += 1
      peak = max(current, peak)
      return Lease(self)
    }
    guard let lease else { return false }
    CVBufferSetAttachment(image, Self.leaseKey as CFString, lease, .shouldNotPropagate)
    return true
  }

  private func release() { lock.withLock { current -= 1 } }

  private final class Lease: NSObject {
    let retention: MacCameraBufferRetention
    fileprivate init(_ retention: MacCameraBufferRetention) { self.retention = retention }
    deinit { retention.release() }
  }
}
