import AVFoundation
import Foundation

private struct SmokeError: LocalizedError {
  let errorDescription: String?
  init(_ text: String) { errorDescription = text }
}

private struct TakeResult: Encodable {
  let name: String
  let encodedFrames: UInt64
  let droppedVideoFrames: UInt64
}

/// Count real inputs to the publisher separately from VT and network drops.
private final class MediaCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var pictures = 0
  private var audioSamples: Int64 = 0
  private var gaps = 0
  private var previous: CMTime?
  private var awaitingFirstFrame = false
  private var reconnectGaps = [Double]()
  private let frameDuration: Double
  init(frameDuration: Double) { self.frameDuration = frameDuration }
  func connected() { lock.withLock { awaitingFirstFrame = true } }
  var interruptionDurations: [Double] { lock.withLock { reconnectGaps } }
  var inputCounts: (pictures: Int, audioSamples: Int64) { lock.withLock { (pictures, audioSamples) } }
  func video(_ sample: CMSampleBuffer) {
    lock.withLock {
      if awaitingFirstFrame {
        if let previous { reconnectGaps.append((sample.presentationTimeStamp - previous).seconds) }
        awaitingFirstFrame = false
      }
      if let previous, (sample.presentationTimeStamp - previous).seconds > 1.5 * frameDuration { gaps += 1 }
      pictures += 1
      previous = sample.presentationTimeStamp
    }
  }
  func audio(_ buffer: AVAudioPCMBuffer) {
    lock.withLock { audioSamples += Int64(buffer.frameLength) }
  }
  var report: String {
    lock.withLock { "publisher inputs \(pictures) pictures, \(gaps) gaps, \(audioSamples) PCM frames" }
  }
}

@main enum ProgramStreamAppSmoke {
  @MainActor static func main() async throws {
    let args = CommandLine.arguments
    guard (4...5).contains(args.count), let seconds = Double(args[3]), seconds >= 18 else {
      throw SmokeError("Expected a loopback endpoint, output folder, run duration and optional profile.")
    }
    let profile = args.count == 5 ? args[4] : "legacy"
    let macCamera = profile == "maccamera-1080"
    let streamFormat: ProgramStreamFormat
    switch profile {
    case "legacy", "maccamera-1080": streamFormat = .init()
    case "uhd60-hevc": streamFormat = .init(size: .uhd4K, rate: .fps60, codec: .hevc, videoMbps: 25)
    case "720p2997-av1": streamFormat = .init(size: .hd720, rate: .fps2997, codec: .av1, videoMbps: 4)
    default: throw SmokeError("Unknown stream profile \(profile)")
    }
    let folder = URL(fileURLWithPath: args[2], isDirectory: true)
    let suite = "org.ultracam.tests.programstream.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { throw SmokeError("Could not create isolated defaults") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = FixtureKeychain()
    let devices = ["fake:audio", "fake:cutaway"]
    let fixture = try AppHardwareSyntheticFixture(duration: VideoContract.slowDuration, deviceIDs: devices, audioChannels: 4,
      width: macCamera ? 1920 : 3840, height: macCamera ? 1080 : 2160, pixel: macCamera ? .video420 : .v210)
    fixture.connect()
    let counts = MediaCounter(frameDuration: streamFormat.rate.duration.seconds)
    let publisher: @Sendable () -> any ProgramStreamPublishing = {
      FixturePublisher(loopbackPlaintext: true, didConnect: { counts.connected() }, didAppendVideo: { counts.video($0) },
        didAppendAudio: { buffer, _ in counts.audio(buffer) })
    }
    let session = ProgramStreamSession(defaults: defaults, credentials: credentials, makePublisher: publisher)
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("Unexpected camera install") },
      submit: { _ in fatalError("Unexpected camera install") }, queryProperties: { $0([]) }))
    let model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: fixture.publisher,
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      streamSession: session, hardware: fixture.hardware)
    defer { model.stopProgramStream(); model.stopAllCameras(); fixture.stop() }
    model.refresh()
    guard model.addFeed() != nil else { throw SmokeError("Could not add second input") }
    let ids = model.feedDescriptors.map(\.id)
    for (index, id) in ids.enumerated() {
      model.updateCamera(id, shareProcessing: false) {
        $0.selectedDevice = devices[index]
        $0.automaticFeed = true
        $0.previewEnabled = false
        if profile == "uhd60-hevc" { $0.resizeTarget = .uhd4K }
      }
    }
    var config = ProgramStreamConfiguration(name: "Local decode", server: args[1],
      audioFeedID: ids[0].rawValue, firstChannel: 2)
    if profile != "legacy" { config.format = streamFormat }
    try model.saveProgramStream(config, key: "qualification")
    if profile == "legacy" {
      // Installed versions persisted the same destination envelope without a format field.
      guard let data = try credentials.read(),
            var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var oldSettings = envelope["configuration"] as? [String: Any] else {
        throw SmokeError("Could not construct the legacy saved destination")
      }
      oldSettings.removeValue(forKey: "format")
      envelope["configuration"] = oldSettings
      try credentials.write(JSONSerialization.data(withJSONObject: envelope))
    }
    let restored = ProgramStreamSession(defaults: defaults, credentials: credentials, makePublisher: publisher)
    guard restored.configuration == config, !restored.snapshot.active else { throw SmokeError("Settings restore failed") }
    model.recordingModel.setOutputFolder(folder, for: ids[0])
    model.recordingModel.codec = .proRes42210Bit
    let testMotion = profile == "uhd60-hevc"
    let fast = try SourceFormat(width: testMotion ? 3840 : 1920, height: testMotion ? 2160 : 1080,
      pixel: fixture.format.pixel, rate: .constant(VideoContract.fastDuration))
    let cameraA = try fixture.makePattern(lumaCode: 256)
    let cameraB = try fixture.makePattern(lumaCode: testMotion ? 624 : 720, width: fast.width, height: fast.height)
    let cameraBOdd = testMotion ? try fixture.makePattern(lumaCode: 752, width: fast.width, height: fast.height) : cameraB
    let flashA = try fixture.makePattern(lumaCode: 940)
    let flashB = try fixture.makePattern(lumaCode: 940, width: fast.width, height: fast.height)
    let dt = fast.rate.nominal.seconds
    // Source timestamps refer to exposure end. Preserve capture/processing latency on
    // the selected clock, including the shorter playout window of the 60 fps profile.
    let hostOrigin = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()),
      CMTimeMultiply(testMotion ? fast.rate.nominal : fixture.duration, multiplier: 3))
    let ticks = AsyncStream<TimeInterval>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var iterator = ticks.stream.makeAsyncIterator()
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "fixture.capture.clock", qos: .userInteractive))
    let target = ProcessInfo.processInfo.systemUptime
    timer.schedule(deadline: .now(), repeating: .nanoseconds(Int((dt * 1e9).rounded())), leeway: .nanoseconds(0))
    timer.setEventHandler { ticks.continuation.yield(ProcessInfo.processInfo.systemUptime) }
    timer.resume()
    defer { timer.cancel(); ticks.continuation.finish() }
    var previousIndex: Int32 = -1
    var skippedInputSlots: Int32 = 0
    func pump() async throws {
      guard let now = await iterator.next(isolation: MainActor.shared) else { throw SmokeError("Synthetic camera clock stopped") }
      let index = Int32(((now - target) / dt).rounded())
      guard index > previousIndex else { return }
      skippedInputSlots += index - previousIndex - 1
      let slowIndex = index / 2
      let pulse = (30..<42).contains(Int(slowIndex % 60))
      if previousIndex < 0 || slowIndex > previousIndex / 2 {
        let aEnd = CMTimeAdd(hostOrigin, CMTimeMultiply(fixture.duration, multiplier: slowIndex + 1))
        try fixture.emit(pulse ? flashA : cameraA, index: slowIndex, forDevice: devices[0],
                         firstChannelLevel: 46, toneHz: pulse ? 900 : 0, firstPairToneHz: 2000,
                         captureEndHostTime: aEnd)
      }
      let pictureB = index.isMultiple(of: 2) ? cameraB : cameraBOdd
      let bEnd = CMTimeAdd(hostOrigin, CMTimeMultiply(fast.rate.nominal, multiplier: index + 1))
      try fixture.emit(pulse ? flashB : pictureB, index: index, forDevice: devices[1],
                       firstChannelLevel: 66, toneHz: 2000, captureEndHostTime: bEnd, sourceFormat: fast)
      previousIndex = index
    }
    func pumpFor(_ seconds: Double) async throws {
      let end = ProcessInfo.processInfo.systemUptime + seconds
      while ProcessInfo.processInfo.systemUptime < end { try await pump() }
    }
    func pumpUntil(_ condition: () -> Bool, failure: String) async throws {
      let end = ProcessInfo.processInfo.systemUptime + 8
      while !condition() && ProcessInfo.processInfo.systemUptime < end { try await pump() }
      guard condition() else { throw SmokeError(failure) }
    }
    func take(_ label: String) async throws -> TakeResult {
      model.recordingModel.record(feedID: ids[0])
      try await pumpFor(4)
      model.recordingModel.stop(feedID: ids[0])
      let end = ProcessInfo.processInfo.systemUptime + 10
      while model.recordingModel.hasActiveRecordings && ProcessInfo.processInfo.systemUptime < end { try await pump() }
      guard let take = model.recordingModel.feeds.first(where: { $0.id == ids[0] }),
        take.error == nil, let url = take.savedURL, let stats = take.statistics, stats.encodedFrames > 30 else {
        throw SmokeError("\(label) ISO failed: \(String(describing: model.recordingModel.feeds.first?.error))")
      }
      print("\(label): \(stats.encodedFrames) ISO frames, \(stats.droppedVideoFrames) drops, \(url.lastPathComponent)")
      return TakeResult(name: url.lastPathComponent, encodedFrames: stats.encodedFrames,
        droppedVideoFrames: stats.droppedVideoFrames)
    }
    model.startCamera(ids[0])
    model.setProgramDemandForTesting(requested: true)
    try await pumpUntil({ ids.allSatisfy(model.isCameraRunning) && fixture.programSink.sentCount > 0 },
      failure: "The baseline requires both captures and the virtual Program camera")
    try await pumpFor(0.5)
    let baseline = try await take("baseline")
    model.setProgramDemandForTesting(requested: false)
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + LiveWatchLimits.clientRelease + 1)
    try await pumpUntil({ fixture.programSink.openConnections == 0 },
      failure: "The baseline virtual camera did not close")
    let baselineConnections = fixture.programSink.connectAttempts
    model.startProgramStream()
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    while model.streamSnapshot.phase != .streaming && ProcessInfo.processInfo.systemUptime < deadline {
      try await pump()
      guard model.streamSnapshot.phase != .failed else { throw SmokeError(model.streamSnapshot.lastError ?? "Start failed") }
    }
    guard model.streamSnapshot.phase == .streaming, fixture.programSink.connectAttempts == baselineConnections else {
      throw SmokeError("Network stream did not start independently")
    }
    let beforeSimultaneous = fixture.programSink.sentCount
    model.setProgramDemandForTesting(requested: true)
    try await pumpUntil({ ids.allSatisfy(model.isCameraRunning) && fixture.programSink.sentCount > beforeSimultaneous },
      failure: "The simultaneous take requires both captures and the virtual Program camera")
    let simultaneous = try await take("streaming")
    try JSONEncoder().encode(["baseline": baseline, "streaming": simultaneous])
      .write(to: folder.appendingPathComponent("iso-results.json"))
    guard simultaneous.droppedVideoFrames <= baseline.droppedVideoFrames, fixture.programSink.openConnections == 1 else {
      throw SmokeError("ISO or camera output regression")
    }
    model.setProgramDemandForTesting(requested: false)
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + LiveWatchLimits.clientRelease + 1)
    var settings = model.switcherSettings
    settings.automatic = true
    settings.strategy = .fixedInterval
    settings.intervalSeconds = 2
    model.updateSwitcher(settings)
    let started = ProcessInfo.processInfo.systemUptime
    var reconnecting = false
    var sawCutaway = false
    var nextProgress = 0.0
    var previousPhase: ProgramStreamPhase?
    while ProcessInfo.processInfo.systemUptime - started < seconds {
      try await pump()
      let snapshot = model.streamSnapshot
      if previousPhase != snapshot.phase {
        print("Stream \(snapshot.phase.rawValue) at \(Date().ISO8601Format()), most recent interruption: " +
          (snapshot.lastInterruption?.rawValue ?? "none"))
        fflush(nil)
        previousPhase = snapshot.phase
      }
      reconnecting = reconnecting || snapshot.phase == .reconnecting
      sawCutaway = sawCutaway || model.switcherSelectedFeedID == ids[1]
      guard snapshot.phase != .failed else { throw SmokeError(snapshot.lastError ?? "Stream failed") }
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      if elapsed >= nextProgress {
        print("Live \(Int(elapsed))s: \(snapshot.phase.rawValue), drops \(snapshot.droppedVideo), gaps \(snapshot.audioGaps)")
        print("\(counts.report), route video drops \(model.streamVideoDrops), PCM drops \(model.streamAudioDrops)")
        nextProgress += 60
        fflush(nil)
      }
    }
    guard reconnecting, model.streamSnapshot.phase == .streaming, sawCutaway else {
      throw SmokeError("Reconnect/cut incomplete: reconnecting=\(reconnecting), cutaway=\(sawCutaway)")
    }
    guard !model.programInUse, fixture.programSink.openConnections == 0, !model.recordingModel.hasActiveRecordings else {
      throw SmokeError("Streaming-only auto cuts require an idle camera sink and recording")
    }
    model.setProgramDemandForTesting(requested: true)
    try await pumpUntil({ fixture.programSink.openConnections == 1 },
      failure: "The virtual camera did not reopen while streaming")
    print("Final \(counts.report), route video drops \(model.streamVideoDrops), PCM drops \(model.streamAudioDrops), " +
      "transport drops \(model.streamSnapshot.droppedVideo)")
    print("Synthetic capture missed \(skippedInputSlots) of \(previousIndex + 1) high-rate source slots")
    model.stopProgramStream()
    await model.finishProgramStreamShutdown()
    try JSONEncoder().encode(counts.interruptionDurations)
      .write(to: folder.appendingPathComponent("interruption-seconds.json"))
    let stoppedInputs = counts.inputCounts
    let before = fixture.programSink.sentCount
    try await pumpFor(0.5)
    guard !model.streamSnapshot.active, !model.streamNeedsShutdown, counts.inputCounts == stoppedInputs else {
      throw SmokeError("Publisher did not finish closing or received media after Stop")
    }
    guard model.isCameraRunning(ids[0]), fixture.programSink.sentCount > before else {
      throw SmokeError("Stopping stream disturbed capture or camera output")
    }
    model.setProgramDemandForTesting(requested: false)
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + LiveWatchLimits.clientRelease + 1)
    try await pumpUntil({
      fixture.programSink.openConnections == 0 && model.isCameraRunning(ids[0]) && !model.isCameraRunning(ids[1])
    }, failure: "Closing the virtual camera failed to release automatic capture or disturbed manual capture")
    print("Local Program app smoke passed")
  }
}
