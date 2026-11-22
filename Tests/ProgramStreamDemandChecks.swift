#if ULTRACAM_TEST_SUPPORT
import AVFAudio
import CoreMedia
import CoreVideo
import Foundation
import XCTest

/// A receiver at the app/publisher boundary. Pixel and PCM values identify the originating
/// camera even when the switcher's state already reports a successful cut.
private final class ProgramStreamProbe: ProgramStreamPublishing, @unchecked Sendable {
  private let lock = NSLock()
  private let startupFailure: ProgramStreamPublisherError?
  private var luma: [UInt8] = []
  private var levels: [Float] = []
  private var connected = false
  private var bytes: UInt64 = 0
  private var seenFormats: [ProgramStreamFormat] = []
  private var videoSize = CGSize.zero
  private var duration = CMTime.invalid

  var formats: [ProgramStreamFormat] { lock.withLock { seenFormats } }
  var lastSize: CGSize { lock.withLock { videoSize } }
  var lastDuration: CMTime { lock.withLock { duration } }

  var pictures: [UInt8] { lock.withLock { luma } }
  var audioLevels: [Float] { lock.withLock { levels } }

  init(startupFailure: ProgramStreamPublisherError? = nil) { self.startupFailure = startupFailure }

  func connect(server: String, key: String, format: ProgramStreamFormat, onDisconnect: @escaping @Sendable (ProgramStreamDisconnectReason) -> Void) async throws {
    if let startupFailure { throw startupFailure }
    lock.withLock { connected = true; seenFormats.append(format) }
  }

  func appendVideo(_ sample: CMSampleBuffer) {
    guard let buffer = CMSampleBufferGetImageBuffer(sample),
      CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
    let offset = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * (CVPixelBufferGetHeight(buffer) / 2)
      + CVPixelBufferGetWidth(buffer) / 2
    let pixel = base.load(fromByteOffset: offset, as: UInt8.self)
    lock.withLock {
      if connected {
        videoSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        duration = CMSampleBufferGetDuration(sample)
        luma.append(pixel)
        bytes += 1200
      }
    }
  }

  func appendAudio(_ buffer: AVAudioPCMBuffer, at: AVAudioTime) {
    guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
    let level = channel[Int(buffer.frameLength / 2) * buffer.stride]
    lock.withLock { if connected { levels.append(level) } }
  }

  func close() async { lock.withLock { connected = false } }

  func statistics() async -> ProgramStreamTransportStatistics {
    lock.withLock { ProgramStreamTransportStatistics(connected: connected, bytesSent: bytes) }
  }
}

private final class ProgramStreamTestCredentials: ProgramStreamCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func read() throws -> Data? { lock.withLock { data } }
  func write(_ data: Data) throws { lock.withLock { self.data = data } }
  func remove() throws { lock.withLock { data = nil } }
}

@MainActor @objcMembers final class ProgramStreamDemandChecks: XCTestCase {
  private var fixture: AppHardwareSyntheticFixture!
  private var model: AppModel!
  private var session: ProgramStreamSession!
  private var probe: ProgramStreamProbe!
  private var ids: [FeedID] = []
  private let devices = ["fake:fixed", "fake:cutaway"]
  private var pictures: [CVPixelBuffer] = []
  private var sourceFormats: [SourceFormat] = []
  private var index: Int32 = 0

  private func prepare(firstSize: ResizeTarget = .uhd4K, publisherFailure: ProgramStreamPublisherError? = nil) throws {
    fixture = try AppHardwareSyntheticFixture(duration: VideoContract.slowDuration, deviceIDs: devices,
      width: firstSize.width, height: firstSize.height)
    fixture.connect()
    let suite = "org.ultracam.tests.stream.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let publisher = ProgramStreamProbe(startupFailure: publisherFailure)
    probe = publisher
    session = ProgramStreamSession(defaults: defaults, credentials: ProgramStreamTestCredentials(),
      makePublisher: { publisher })
    let installer = ExtensionInstaller(services: .init(
      preflight: { .init(developerSigned: false, hasInstallEntitlement: false) },
      makeRequest: { _ in fatalError("Unexpected extension install in streaming fixture") },
      submit: { _ in XCTFail("Unexpected installer submission") }, queryProperties: { $0([]) }))
    model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: fixture.publisher,
      recordingFolderStore: RecordingFolderStore(defaults: defaults), installer: installer,
      streamSession: session, hardware: fixture.hardware)
    model.refresh()
    _ = try XCTUnwrap(model.addFeed())
    ids = model.feedDescriptors.map(\.id)
    for (feed, device) in zip(ids, devices) {
      model.updateCamera(feed, shareProcessing: false) {
        $0.selectedDevice = device
        $0.previewEnabled = false
        $0.automaticFeed = true
      }
    }
    sourceFormats = [fixture.format, try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(fixture.duration))]
    pictures = try zip(sourceFormats, [UInt32(256), 848]).map { format, luma in
      try fixture.makePattern(lumaCode: luma, width: format.width, height: format.height)
    }
  }

  private func finish() {
    model.stopProgramStream()
    model.stopAllCameras()
    fixture.stop()
  }

  private func saveDestination(audio: Bool = true) throws {
    let configuration = ProgramStreamConfiguration(name: "Test ingest", server: "rtmps://fixture.invalid/live",
      audioFeedID: audio ? ids[0].rawValue : nil, firstChannel: 0)
    try model.saveProgramStream(configuration, key: "fixture")
    XCTAssertEqual(model.streamConfiguration, configuration)
    XCTAssertFalse(model.streamSnapshot.active)
  }

  private func emit(omitting device: String? = nil, until condition: () -> Bool, message: String, file: StaticString = #filePath,
                    line: UInt = #line) throws {
    let deadline = Date(timeIntervalSinceNow: 12)
    while !condition() && Date() < deadline {
      for i in devices.indices where devices[i] != device {
        try fixture.emit(pictures[i], index: index, forDevice: devices[i], firstChannelLevel: i == 0 ? 32 : -64,
          sourceFormat: sourceFormats[i])
      }
      index += 1
      RunLoop.main.run(until: Date(timeIntervalSinceNow: CMTimeGetSeconds(fixture.duration)))
    }
    if !condition() {
      let state = model.streamSnapshot
      XCTFail("\(message). phase=\(state.phase), reason=\(state.lastError ?? "none"), " +
        "pictures=\(probe.pictures.suffix(8)), audio=\(probe.audioLevels.suffix(8))", file: file, line: line)
    }
  }

  func testCopyDiagnosticsIncludesFailedStreamWithoutDestinationCredentials() throws {
    try prepare(firstSize: .hd720, publisherFailure: .unsupportedCodec)
    defer { finish() }
    let name = "Private broadcast label"
    let server = "rtmps://private-ingest.invalid/live?token=private-token"
    let key = "private-stream-key"
    var destination = ProgramStreamConfiguration(name: name, server: server, audioFeedID: nil, firstChannel: 0)
    destination.format.size = .hd720
    try model.saveProgramStream(destination, key: key)
    model.startProgramStream()
    try emit(until: { model.streamSnapshot.phase == .failed }, message: "The rejected codec reaches the Program stream failure state")
    XCTAssertTrue(model.streamSnapshot.lastError?.contains("\(name) does not accept H.264") == true)

    let summary = UIDiagnosticsText.summary(model: model)
    XCTAssertTrue(summary.contains("Program stream: Stream Failed"))
    XCTAssertTrue(summary.contains("Last stream error: The destination does not accept H.264"))
    for secret in [name, "private-ingest.invalid", "private-token", key] {
      XCTAssertFalse(summary.contains(secret))
    }
  }

  func testStreamAloneStartsAutomaticSourcesCutsPicturesAndKeepsOffAirEmbeddedSound() throws {
    try prepare()
    defer { finish() }
    try saveDestination()
    XCTAssertFalse(ids.contains(where: model.isCameraRunning))
    model.startProgramStream()
    try emit(until: {
      probe.pictures.contains { (45...90).contains($0) } && probe.audioLevels.contains { $0 > 0.1 }
    }, message: "The first camera's picture and fixed embedded PCM reach the publisher")
    var switcher = model.switcherSettings
    switcher.automatic = true
    switcher.strategy = .fixedInterval
    switcher.intervalSeconds = 0.6
    model.updateSwitcher(switcher)
    try emit(until: {
      model.switcherSelectedFeedID == ids[1] && probe.pictures.last.map { $0 >= 170 } == true
    }, message: "The automatic cut reaches the publisher as a visibly different picture")
    var hold = model.switcherSettings
    hold.naturalTalkingHead.manualHold = true
    model.updateSwitcher(hold)
    let audioBeforeHold = probe.audioLevels.count
    try emit(until: { probe.audioLevels.dropFirst(audioBeforeHold).filter { $0 > 0.1 }.count >= 5 },
      message: "Audio continues from the first input while holding the other picture")
    XCTAssertEqual(model.switcherSelectedFeedID, ids[1])
    XCTAssertFalse(probe.audioLevels.contains { $0 < -0.1 }, "Audio from the cutaway must never be published")
    let priorAudio = probe.audioLevels.count
    try emit(omitting: devices[0], until: {
      let emitted = probe.audioLevels.dropFirst(priorAudio)
      return emitted.count >= 8 && emitted.suffix(8).allSatisfy { $0 == 0 }
        && model.streamSnapshot.audioMissing && model.streamSnapshot.pictureFresh
    }, message: "Losing the fixed off-air feed produces silence while the other picture stays live")
    let priorRecovery = probe.audioLevels.count
    try emit(until: {
      probe.audioLevels.dropFirst(priorRecovery).contains { $0 > 0.1 } && !model.streamSnapshot.audioMissing
    }, message: "The same embedded feed resumes without reopening the stream")

    XCTAssertFalse(model.recordingModel.hasActiveRecordings)
    XCTAssertEqual(fixture.sink.connectAttempts, 0)
    XCTAssertEqual(fixture.programSink.connectAttempts, 0)
    model.stopProgramStream()
    try emit(until: { !ids.contains(where: model.isCameraRunning) },
      message: "Stopping the stream releases every automatic input it acquired")
  }

  func testVideoOnlyStreamSurvivesVirtualCameraRenegotiationAndStopsIndependently() throws {
    try prepare()
    defer { finish() }
    model.updateCamera(ids[0], shareProcessing: false) { $0.automaticFeed = false }
    model.startCamera(ids[0])
    model.setProgramDemandForTesting(requested: true)
    try emit(until: { fixture.programSink.sentCount > 0 }, message: "Existing virtual camera is receiving")
    try saveDestination(audio: false)
    model.startProgramStream()
    try emit(until: { probe.pictures.contains { (45...90).contains($0) } },
      message: "The second output joins the on-air picture")
    XCTAssertTrue(probe.audioLevels.isEmpty)
    XCTAssertEqual(model.programOutputDiagnostics.contract?.width, 1920)
    let priorConnections = fixture.programSink.connectAttempts
    let priorPictures = probe.pictures.count
    model.updateCamera(ids[0], shareProcessing: false) { $0.resizeTarget = .hd720 }
    try emit(until: {
      fixture.programSink.connectAttempts > priorConnections &&
        model.programOutputDiagnostics.contract?.width == 1280 &&
        probe.pictures.dropFirst(priorPictures).filter { (45...90).contains($0) }.count >= 5
    }, message: "The virtual camera switches to 720p while streaming sends fresh pictures")
    XCTAssertEqual(probe.formats, [ProgramStreamFormat()])
    XCTAssertEqual(probe.lastSize, CGSize(width: 1920, height: 1080))
    XCTAssertEqual(probe.lastDuration, FrameRateTarget.fps30.duration)
    let connections = fixture.programSink.connectAttempts
    model.stopProgramStream()
    let sent = fixture.programSink.sentCount
    try emit(until: { fixture.programSink.sentCount >= sent + 5 }, message: "Virtual camera keeps receiving")
    XCTAssertEqual(fixture.programSink.connectAttempts, connections, "Stopping streaming must not renegotiate the camera")
    model.setProgramDemandForTesting(requested: false)
    model.liveWatchTick(now: ProcessInfo.processInfo.systemUptime + LiveWatchLimits.clientRelease + 1)
    XCTAssertTrue(model.isCameraRunning(ids[0]), "Manual capture retains its own ownership")
    XCTAssertFalse(model.isCameraRunning(ids[1]), "Automatic capture releases after both consumers leave")
  }

  func testSourceSizeResolvesOnColdAutomaticStartAndStaysFixedAcrossALargerCut() throws {
    try prepare(firstSize: .hd720)
    defer { finish() }
    for id in ids { model.updateCamera(id, shareProcessing: false) { $0.pipelineEnabled = false } }
    var destination = ProgramStreamConfiguration(name: "Source-sized", server: "rtmps://fixture.invalid/live")
    destination.format.size = .source
    try model.saveProgramStream(destination, key: "fixture")
    XCTAssertFalse(ids.contains(where: model.isCameraRunning))
    model.startProgramStream()
    try emit(until: { probe.pictures.contains { (45...90).contains($0) } },
      message: "Starting the stream acquires a 720p source before freezing its canvas")
    XCTAssertEqual(probe.formats.map(\.size), [.hd720])
    XCTAssertEqual(probe.lastSize, CGSize(width: 1280, height: 720))
    XCTAssertEqual(model.streamConfiguration.format.size, .source)
    switch model.requestProgramCut(to: ids[1]) {
    case .queued, .coalesced, .selectedImmediately: break
    case let result: return XCTFail("The UHD cutaway request was rejected: \(result)")
    }
    try emit(until: { probe.pictures.last.map { $0 >= 170 } == true }, message: "The UHD cutaway is visible")
    XCTAssertEqual(probe.lastSize, CGSize(width: 1280, height: 720))
    XCTAssertEqual(probe.formats.count, 1)
    model.stopProgramStream()
    XCTAssertEqual(model.streamSnapshot.format.size, .source)
  }

  func testConfiguredStreamFormatReachesRendererAndPublisherAndLiveEditsApplyNextStart() throws {
    try prepare()
    defer { finish() }
    for id in ids { model.updateCamera(id, shareProcessing: false) { $0.pipelineEnabled = false } }
    var destination = ProgramStreamConfiguration(name: "Format fixture", server: "rtmps://fixture.invalid/live")
    let first = ProgramStreamFormat(size: .uhd4K, rate: .fps60, codec: .hevc, videoMbps: 27)
    destination.format = first
    try model.saveProgramStream(destination, key: "fixture")
    model.startProgramStream()
    try emit(until: { probe.pictures.contains { (45...90).contains($0) } },
      message: "UHD output reaches the publisher")
    XCTAssertEqual(probe.formats, [first])
    XCTAssertEqual(probe.lastSize, CGSize(width: 3840, height: 2160))
    XCTAssertEqual(probe.lastDuration, FrameRateTarget.fps60.duration)
    let next = ProgramStreamFormat(size: .hd720, rate: .fps23976, codec: .av1, videoMbps: 3)
    destination.format = next
    try model.saveProgramStream(destination, key: "")
    XCTAssertEqual(model.streamSnapshot.format, first)
    XCTAssertEqual(probe.formats, [first])
    model.stopProgramStream()
    XCTAssertEqual(model.streamSnapshot.format, next)
    model.startProgramStream()
    try emit(until: { probe.lastSize == CGSize(width: 1280, height: 720) && probe.lastDuration == FrameRateTarget.fps23976.duration },
      message: "The next start rebuilds video at its saved size and exact fractional cadence")
    XCTAssertEqual(probe.formats, [first, next])
    XCTAssertEqual(model.streamSnapshot.format, next)
  }

  func testRemovingIdleSecondCameraKeepsExistingStreamAndRefusesANewOne() throws {
    try prepare()
    defer { finish() }
    model.updateCamera(ids[1], shareProcessing: false) { $0.automaticFeed = false }
    try saveDestination()
    model.startProgramStream()
    try emit(until: { probe.pictures.contains { (45...90).contains($0) } },
      message: "Stream starts using the first feed while second camera is idle")
    XCTAssertTrue(model.removeFeed(ids[1]))
    XCTAssertFalse(model.programAvailable)
    let sent = probe.pictures.count
    try emit(until: { probe.pictures.dropFirst(sent).filter { (45...90).contains($0) }.count >= 4 },
      message: "The surviving source keeps supplying fresh video")
    model.stopProgramStream()
    try emit(until: { !model.isCameraRunning(ids[0]) }, message: "Stop remains effective")
    model.startProgramStream()
    XCTAssertFalse(model.streamSnapshot.active)
    XCTAssertFalse(model.isCameraRunning(ids[0]), "A new stream requires two configured cameras")
  }

  func testStopAllKeepsAnUnavailableAutomaticCameraStoppedWhenItReturns() throws {
    try prepare()
    defer { finish() }
    fixture.plugin.setConnectedDevices([devices[0]])
    model.refresh()
    XCTAssertFalse(model.devices.contains { $0.id == devices[1] })
    try saveDestination(audio: false)
    model.startProgramStream()
    try emit(until: { model.streamSnapshot.pictureFresh }, message: "The first camera starts the stream")
    XCTAssertTrue(model.isCameraRunning(ids[0]))
    XCTAssertFalse(model.isCameraRunning(ids[1]))

    model.stopAllCameras()
    fixture.connect()
    model.refresh()
    XCTAssertTrue(model.devices.contains { $0.id == devices[1] })
    try emit(until: { probe.pictures.last.map { $0 <= 20 } == true },
      message: "An empty Program sends black while the stream stays live")
    XCTAssertEqual(model.streamSnapshot.phase, .streaming)
    XCTAssertFalse(ids.contains(where: model.isCameraRunning), "Stop All also disarms cameras waiting for an input")
    model.startCamera(ids[1])
    try emit(until: { probe.pictures.last.map { $0 >= 170 } == true && model.streamSnapshot.pictureFresh },
      message: "Manually starting the returned camera restores the active stream")
    XCTAssertEqual(probe.formats.count, 1)
  }

  func testRemovingTheFixedAudioCameraKeepsTheOtherPictureAndSendsSilence() throws {
    try prepare()
    defer { finish() }
    try saveDestination()
    model.startProgramStream()
    try emit(until: { probe.audioLevels.contains { $0 > 0.1 } && model.streamSnapshot.pictureFresh },
      message: "The fixed audio camera starts the stream")
    _ = model.requestProgramCut(to: ids[1])
    try emit(until: { probe.pictures.last.map { $0 >= 170 } == true },
      message: "The other picture is on air before removing the audio camera")
    model.stopCamera(ids[0])
    try emit(until: { model.canRemoveCamera(ids[0]) }, message: "The stopped camera has released its input")
    XCTAssertTrue(model.removeFeed(ids[0]))
    XCTAssertFalse(model.programAvailable)
    let picturesBefore = probe.pictures.count
    let audioBefore = probe.audioLevels.count
    try emit(until: {
      let audio = probe.audioLevels.dropFirst(audioBefore)
      return audio.count >= 8 && audio.suffix(8).allSatisfy { $0 == 0 }
        && probe.pictures.dropFirst(picturesBefore).filter { $0 >= 170 }.count >= 5
        && model.streamSnapshot.audioMissing && model.streamSnapshot.pictureFresh
    }, message: "Removing the saved audio feed leaves the surviving picture live with silent audio")
    XCTAssertEqual(model.streamSnapshot.audioFeedID, ids[0].rawValue)
    XCTAssertEqual(probe.formats.count, 1)
  }

  func testOffAirBackupCameraKeepsCaptureForFixedAudioUntilStreamStops() throws {
    try prepare()
    defer { finish() }
    try saveDestination()
    model.startProgramStream()
    try emit(until: { probe.audioLevels.contains { $0 > 0.1 } && model.streamSnapshot.pictureFresh },
      message: "The fixed audio camera starts the stream")
    _ = model.requestProgramCut(to: ids[1])
    try emit(until: { probe.pictures.last.map { $0 >= 170 } == true }, message: "The second picture goes on air")

    model.updateCamera(ids[0], shareProcessing: false) {
      $0.automaticFeed = false
      $0.recordWithCameraApps = true
    }
    let sent = probe.audioLevels.count
    try emit(until: { probe.audioLevels.dropFirst(sent).filter { $0 > 0.1 }.count >= 5 },
      message: "The backup-only feed keeps supplying live fixed audio without a camera client or take")
    XCTAssertTrue(model.isCameraRunning(ids[0]))
    XCTAssertFalse(model.recordingModel.hasActiveRecordings)
    XCTAssertEqual(fixture.sink.openConnections, 0)
    model.stopProgramStream()
    try emit(until: { !ids.contains(where: model.isCameraRunning) },
      message: "Stopping streaming releases capture owned only for the stream")
  }

  func testActiveStreamBlocksResetAndConfirmedQuitBlocksRestart() throws {
    try prepare(firstSize: .hd720)
    defer { finish() }
    try saveDestination(audio: false)
    XCTAssertTrue(model.canResetSettings)
    let configuration = model.streamConfiguration
    model.startProgramStream()
    XCTAssertTrue(model.streamSnapshot.active)
    XCTAssertFalse(model.canResetSettings)
    XCTAssertFalse(model.resetAllSettings())
    XCTAssertTrue(model.streamSnapshot.active)
    XCTAssertEqual(model.streamConfiguration, configuration)

    model.beginTermination()
    model.stopProgramStream()
    model.startProgramStream()
    XCTAssertFalse(model.streamSnapshot.active)
    XCTAssertThrowsError(try model.saveProgramStream(configuration, key: "next"))
    XCTAssertFalse(model.canResetSettings)
  }
}
#endif
