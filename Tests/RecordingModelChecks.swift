import Foundation
import AVFoundation
import XCTest

@MainActor @objcMembers final class RecordingModelChecks: XCTestCase {
  private final class Driver: RecordingSessionDriver {
    enum Operation: Equatable {
      case start(FeedID, RecordingConfiguration)
      case pause(FeedID)
      case resume(FeedID)
      case stop(FeedID)
    }

    var operations: [Operation] = []
    var failingFeeds = Set<FeedID>()

    func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.start(feedID, configuration))
    }

    func pauseRecording(feedID: FeedID) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.pause(feedID))
    }

    func resumeRecording(feedID: FeedID) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.resume(feedID))
    }

    func stopRecording(feedID: FeedID) throws {
      if failingFeeds.contains(feedID) { throw TestError.failed }
      operations.append(.stop(feedID))
    }
  }

  private enum TestError: Error { case failed }

  private final class Writer: SourceRecordingWriter {
    private(set) var started = false
    private(set) var finished = false
    var telemetry: SourceRecordingWriterTelemetry { SourceRecordingWriterTelemetry() }

    func start() throws { started = true }
    func appendVideo(_ sample: CMSampleBuffer) throws {}
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws { finished = true }
  }

  private final class SlowFinishingWriter: SourceRecordingWriter, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func start() throws {}
    func appendVideo(_ sample: CMSampleBuffer) throws {}
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws {
      entered.signal()
      guard release.wait(timeout: .now() + 3) == .success else { throw TestError.failed }
      if fail { throw TestError.failed }
    }
  }

  private final class StatisticsDriver: RecordingSessionDriver, RecordingSessionDriverStatistics {
    var snapshots: [FeedID: RecordingStatistics] = [:]
    func recordingStatistics() async -> [FeedID: RecordingStatistics] { snapshots }
    func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {}
    func pauseRecording(feedID: FeedID) throws {}
    func resumeRecording(feedID: FeedID) throws {}
    func stopRecording(feedID: FeedID) throws {}
  }

  private let first = FeedID(rawValue: "feed-a")
  private let second = FeedID(rawValue: "feed-b")

  func testActualSourceCadenceControlsNativeTimecodeConfiguration() throws {
    let slow = FrameRate.constant(CMTime(value: 1001, timescale: 30000))
    XCTAssertEqual(NativeRecordingSessionDriver.legacyFrameRate(for: slow), .fps2997)
    let timecode = try Timecode(hours: 1, minutes: 2, seconds: 3, frames: 12, dropFrame: true)
    let native = try XCTUnwrap(NativeRecordingSessionDriver.nativeTimecodeMetadata(timecode, rate: slow))
    XCTAssertEqual(native.frameRate, .fps2997)
    XCTAssertEqual(native.label, "01:02:03;12")
    let film = try Timecode(hours: 1, minutes: 2, seconds: 3, frames: 12, dropFrame: false)
    XCTAssertEqual(NativeRecordingSessionDriver.nativeTimecodeMetadata(film,
      rate: .constant(CMTime(value: 1, timescale: 25)))?.frameRate, .fps25)
    XCTAssertNil(NativeRecordingSessionDriver.nativeTimecodeMetadata(nil, rate: slow))
  }

  func testProfileChoicesUseExactCodecContractsAndSourceAvailability() throws {
    XCTAssertEqual(RecordingCodec.proResLT.matrixProfile.codec, kCMVideoCodecType_AppleProRes422LT)
    XCTAssertEqual(RecordingCodec.proRes4444.title, "ProRes 4444")
    XCTAssertEqual(RecordingCodec.hevcMain10.title, "HEVC Main 10")
    let source = try SourceFormat(width: 3840, height: 2160, pixel: .v210,
      rate: .constant(CMTime(value: 1001, timescale: 60000)))
    XCTAssertEqual(RecordingCodec.available(for: source), [.proResLT, .proRes422, .proRes42210Bit, .hevcMain10_422])
  }

  func testAudioOnlyTakeCannotPublishMovie() throws {
    XCTAssertFalse(NativeRecordingSessionDriver.canPublishMovie(appendedVideo: 0),
      "Accepted audio before video must cancel the output reservation")
    XCTAssertTrue(NativeRecordingSessionDriver.canPublishMovie(appendedVideo: 1))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-no-video-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = CaptureController(services: CaptureServices(
      start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    let driver = NativeRecordingSessionDriver(captureForFeed: { _ in capture }, recorderFactory: { configuration in
      try SourceRecorderCore(configuration: configuration, writerFactory: { Writer() })
    })
    try driver.startRecording(feedID: first, configuration: RecordingConfiguration(outputFolder: root))
    let output = try XCTUnwrap(driver.recordingOutputURL(feedID: first))
    try driver.stopRecording(feedID: first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    XCTAssertTrue(try RecordingRecovery.scan(root: root).isEmpty)
  }

  #if ULTRACAM_TEST_SUPPORT
  func testPendingAudioPreparationKeepsKnownVideoFormat() throws {
    let format = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .constant(CMTime(value: 1, timescale: 25)))
    let source = FakeCaptureSession(format: format, audio: .unknown)
    let feed = FeedID(rawValue: "pending-audio-video-format")
    let capture = CaptureController(services: .registryBridge(feedID: feed, makeSession: { _ in source }))
    capture.setCameraOutputEnabled(false)
    // "Waiting" is published as the source starts, before its declaration
    // arrives on the source's queue; the declaration publishes its own message.
    let ready = expectation(description: "Declared video")
    ready.assertForOverFulfill = false
    capture.onUpdate = { update in if update.message == "Source format declared" { ready.fulfill() } }
    defer { capture.onUpdate = nil; capture.stop() }
    capture.start(feedID: feed, deviceID: "fake:fixture", configuration: PipelineConfiguration(), pipelineEnabled: false, previewEnabled: false)
    wait(for: [ready], timeout: 2)
    XCTAssertNil(capture.recordingTakeContext)
    XCTAssertEqual(capture.recordingVideoFormat, format)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-audio-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var prepared: SourceRecordingConfiguration?
    let driver = NativeRecordingSessionDriver(captureForFeed: { _ in capture }, recorderFactory: { config in
      prepared = config
      return try SourceRecorderCore(configuration: config, writerFactory: { Writer() })
    })
    try driver.startRecording(feedID: feed, configuration: RecordingConfiguration(outputFolder: root))
    let configuration = try XCTUnwrap(prepared)
    XCTAssertEqual(configuration.width, 1920); XCTAssertEqual(configuration.height, 1080)
    XCTAssertEqual(configuration.sourceFrameRate, format.rate)
    XCTAssertEqual(configuration.frameRate, .fps25)
    XCTAssertNil(configuration.sourceAdmission, "Unresolved audio must not bind an epoch")
    try driver.stopRecording(feedID: feed)
  }
  #endif

  func testPerCameraConstantRatePreferenceIsImmutableForEachTake() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide", recordingConstantFrameRate: true),
      RecordingFeedDescriptor(id: second, name: "Tight")], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/recording-cfr")
    model.recordAll()
    guard case .start(_, let wide) = driver.operations[0],
      case .start(_, let tight) = driver.operations[1] else { return XCTFail("Expected take configuration") }
    XCTAssertTrue(wide.recordingConstantFrameRate)
    XCTAssertFalse(tight.recordingConstantFrameRate)
    model.updateFeeds([RecordingFeedDescriptor(id: first, name: "Wide", recordingConstantFrameRate: false),
      RecordingFeedDescriptor(id: second, name: "Tight", recordingConstantFrameRate: true)])
    XCTAssertTrue(wide.recordingConstantFrameRate, "Changing the camera setting cannot change a prepared take")
    XCTAssertFalse(tight.recordingConstantFrameRate)
    model.stop(feedID: first)
    model.record(feedID: first)
    guard let last = driver.operations.last, case .start(_, let next) = last else { return XCTFail("Expected next take") }
    XCTAssertFalse(next.recordingConstantFrameRate)
  }

  func testFinishedArtifactLookupUsesOriginalTakeFolderGrant() throws {
    final class ArtifactDriver: RecordingSessionDriver, RecordingSessionDriverArtifacts {
      let url: URL
      init(_ url: URL) { self.url = url }
      func startRecording(feedID: FeedID, configuration: RecordingConfiguration) throws {}
      func pauseRecording(feedID: FeedID) throws {}
      func resumeRecording(feedID: FeedID) throws {}
      func stopRecording(feedID: FeedID) throws {}
      func recordingOutputURL(feedID: FeedID) -> URL? { url }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("take-grants-\(UUID().uuidString)")
    let original = root.appendingPathComponent("A")
    let next = root.appendingPathComponent("B")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = original.appendingPathComponent("take.mov")
    try Data([1, 2, 3]).write(to: movie)
    var checkedScope: URL?
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide")],
      driver: ArtifactDriver(movie), resolveFinishedFile: { url, scope in
        checkedScope = scope
        guard scope == original, let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
      })
    model.outputFolder = original
    model.record(feedID: first)
    model.setOutputFolder(next, for: first)
    model.stop(feedID: first)
    XCTAssertEqual(checkedScope, original)
    XCTAssertEqual(model.feeds.first?.savedURL, movie)
  }

  func testFailedStartReleasesActiveRootForEmptyRecoveryPruning() throws {
    let suite = "failed-start-root-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = Driver(); driver.failingFeeds.insert(first)
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide")], driver: driver,
      folderStore: RecordingFolderStore(defaults: defaults))
    model.outputFolder = root
    model.record(feedID: first)
    let deadline = Date(timeIntervalSinceNow: 3)
    while !(defaults.dictionary(forKey: "recordingRecoveryRootBookmarks") ?? [:]).isEmpty && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(model.feeds.first?.status, .idle)
    XCTAssertTrue((defaults.dictionary(forKey: "recordingRecoveryRootBookmarks") ?? [:]).isEmpty)
  }

  func testCorruptRecoveryBookmarkKeepsValidSiblingAndRawEntry() throws {
    let suite = "mixed-roots-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecordingFolderStore(defaults: defaults)
    try store.saveRecoveryRoots([root])
    var raw = try XCTUnwrap(defaults.dictionary(forKey: "recordingRecoveryRootBookmarks"))
    let corrupt = Data([1, 2, 3])
    raw["/missing-corrupt"] = corrupt
    defaults.set(raw, forKey: "recordingRecoveryRootBookmarks")
    let restored = try store.loadRecoveryRoots()
    XCTAssertEqual(restored.map { $0.standardizedFileURL.path }, [root.standardizedFileURL.path])
    XCTAssertEqual(store.recoveryRootWarnings, ["/missing-corrupt"])
    try store.saveRecoveryRoots(restored)
    XCTAssertEqual(defaults.dictionary(forKey: "recordingRecoveryRootBookmarks")?["/missing-corrupt"] as? Data, corrupt)
    XCTAssertEqual(try store.loadRecoveryRoots().count, 1)
  }

  func testRecoveryRootBookmarksRoundTripAndDeduplicate() throws {
    let suite = "recovery-roots-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecordingFolderStore(defaults: defaults)
    try store.saveRecoveryRoots([root, root])
    let restored = try store.loadRecoveryRoots()
    XCTAssertEqual(restored.map { $0.standardizedFileURL.path }, [root.standardizedFileURL.path])
    try store.saveRecoveryRoots([])
    XCTAssertTrue(try store.loadRecoveryRoots().isEmpty)
  }

  func testOriginalTakeRootRemainsInRecoveryAfterNextFolderChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("take-roots-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("original")
    let next = root.appendingPathComponent("next")
    let manager = try RecordingOutputManager(rootDirectory: original, minimumFreeBytes: 0)
    let partial = try manager.beginExternalWriterSession(feedID: "Wide")
    try Data([1, 2, 3]).write(to: partial.temporaryURL)
    partial.preserveForRecovery()
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide")], driver: driver)
    model.outputFolder = original
    model.record(feedID: first)
    model.setOutputFolder(next, for: first)
    model.outputFolder = nil
    model.stop(feedID: first)
    let deadline = Date(timeIntervalSinceNow: 3)
    while model.interruptedRecordings.isEmpty && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(model.interruptedRecordings.count, 1)
    let discovered = try XCTUnwrap(model.interruptedRecordings.first)
    XCTAssertEqual(discovered.temporaryURL.resolvingSymlinksInPath(), partial.temporaryURL.resolvingSymlinksInPath(),
      "Changing or clearing next-take folders cannot hide an interrupted original")
    XCTAssertEqual(try Data(contentsOf: discovered.temporaryURL), Data([1, 2, 3]))
  }

  func testDefaultsExposeRequiredRecordingChoices() {
    XCTAssertEqual(RecordingCodec.allCases, [.proResLT, .proRes422, .proRes42210Bit, .proRes4444, .hevcMain, .hevcMain10, .hevcMain10_422])
    XCTAssertEqual(RecordingCodec.proRes42210Bit.title, "ProRes 422 HQ")
    XCTAssertEqual(RecordingCodec.hevcMain10_422.title, "HEVC Main 10 4:2:2")
    XCTAssertEqual(RecordingTimecodeMode.allCases, [.source, .recordStart, .wallClock])
    XCTAssertEqual(RecordingTimecodeMode.wallClock.title, "PC time")
    XCTAssertEqual(RecordingTimecodeMode.source.help,
      "Preserves available native source timecode. Variable-rate or late-arriving labels are retained in the sidecar when no movie timecode track exists.")
    XCTAssertEqual(RecordingTimecodeMode.wallClock.help,
      "Writes the computer's clock into the file, aligned to the first frame.")
    XCTAssertFalse(RecordingConfiguration().recordingConstantFrameRate)
    XCTAssertEqual(RecordingConfiguration().variableRateQuantizationPolicy, .nearest240000)
    XCTAssertEqual(RecordingConfiguration().codec, .proRes42210Bit)
    XCTAssertEqual(RecordingConfiguration().timecodeMode, .wallClock)
    XCTAssertEqual(RecordingModel().timecodeMode, .wallClock)
  }

  func testPerFeedFoldersOverrideDefaultAndChangesApplyToNextTake() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide"),
      RecordingFeedDescriptor(id: second, name: "Tight")], driver: driver)
    let shared = URL(fileURLWithPath: "/tmp/recordings-default", isDirectory: true)
    let wide = URL(fileURLWithPath: "/tmp/recordings-wide", isDirectory: true)
    let tight = URL(fileURLWithPath: "/tmp/recordings-tight", isDirectory: true)
    XCTAssertFalse(model.canRecordAny)
    model.setOutputFolder(wide, for: first)
    XCTAssertTrue(model.canRecordAny, "A camera folder must work without a default folder")
    model.recordAll()
    XCTAssertEqual(model.feeds.map(\.status), [.recording, .idle])
    XCTAssertEqual(model.feeds[1].error, RecordingUIError.outputFolderRequired.localizedDescription)
    model.setOutputFolder(tight, for: second)
    model.recordAll()
    XCTAssertEqual(driver.operations, [
      .start(first, RecordingConfiguration(outputFolder: wide, feedName: "Wide")),
      .start(second, RecordingConfiguration(outputFolder: tight, feedName: "Tight")),
    ])
    model.outputFolder = shared
    model.setOutputFolder(nil, for: first)
    XCTAssertEqual(model.outputFolder(for: first), shared)
    XCTAssertEqual(model.outputFolder(for: second), tight)
    XCTAssertEqual(driver.operations.count, 2, "Changing folders must leave active writers alone")
    model.stopAll()
    model.recordAll()
    XCTAssertEqual(Array(driver.operations.suffix(2)), [
      .start(first, RecordingConfiguration(outputFolder: shared, feedName: "Wide")),
      .start(second, RecordingConfiguration(outputFolder: tight, feedName: "Tight")),
    ])
    model.stopAll()
  }

  func testFeedFoldersPersistByIdentityAndClearIndependently() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-folders-\(UUID().uuidString)")
    let wide = root.appendingPathComponent("wide", isDirectory: true)
    let tight = root.appendingPathComponent("tight", isDirectory: true)
    try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tight, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "UltracamFeedFolders-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = RecordingFolderStore(defaults: defaults)
    let descriptors = [RecordingFeedDescriptor(id: first, name: "Wide"),
      RecordingFeedDescriptor(id: second, name: "Tight")]
    let model = RecordingModel(feeds: descriptors, folderStore: store)
    model.outputFolder = root
    model.setOutputFolder(wide, for: first)
    model.setOutputFolder(tight, for: second)
    let restored = RecordingModel(folderStore: store)
    restored.updateFeeds([RecordingFeedDescriptor(id: second, name: "Renamed"), descriptors[0]])
    XCTAssertEqual(restored.outputFolder(for: first)?.resolvingSymlinksInPath(), wide.resolvingSymlinksInPath())
    XCTAssertEqual(restored.outputFolder(for: second)?.resolvingSymlinksInPath(), tight.resolvingSymlinksInPath())
    // Removing feeds also removes their per-feed choices and bookmarks.
    restored.updateFeeds([])
    restored.updateFeeds(descriptors)
    XCTAssertNil(restored.customOutputFolder(for: first))
    XCTAssertNil(restored.customOutputFolder(for: second))
    XCTAssertEqual(restored.outputFolder(for: first)?.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    restored.setOutputFolder(wide, for: first)
    restored.setOutputFolder(tight, for: second)
    restored.updateFeeds([])
    let clearedByRemoval = RecordingModel(feeds: descriptors, folderStore: store)
    XCTAssertNil(clearedByRemoval.customOutputFolder(for: first))
    XCTAssertNil(clearedByRemoval.customOutputFolder(for: second))
    // Removal cleared both choices above. Restore the sibling before checking
    // that explicitly clearing the first leaves that sibling untouched.
    restored.setOutputFolder(tight, for: second)
    restored.setOutputFolder(nil, for: first)
    let cleared = RecordingModel(feeds: descriptors, folderStore: store)
    XCTAssertNil(cleared.customOutputFolder(for: first))
    XCTAssertEqual(cleared.outputFolder(for: first)?.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    XCTAssertEqual(cleared.outputFolder(for: second)?.resolvingSymlinksInPath(), tight.resolvingSymlinksInPath())
    cleared.outputFolder = nil
    XCTAssertNil(cleared.outputFolder(for: first))
    XCTAssertEqual(cleared.outputFolder(for: second)?.resolvingSymlinksInPath(), tight.resolvingSymlinksInPath())
  }

  func testRecoveryScansAllCameraFoldersWithoutDuplicates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-feed-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let wide = root.appendingPathComponent("wide", isDirectory: true)
    let tight = root.appendingPathComponent("tight", isDirectory: true)
    for folder in [wide, tight] {
      let manager = try RecordingOutputManager(rootDirectory: folder, minimumFreeBytes: 0)
      let output = try manager.beginExternalWriterSession(feedID: "Camera")
      try Data([1, 2, 3]).write(to: output.temporaryURL)
      output.preserveForRecovery()
    }
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide"),
      RecordingFeedDescriptor(id: second, name: "Tight")])
    model.outputFolder = wide
    model.setOutputFolder(wide, for: first)
    model.setOutputFolder(tight, for: second)
    let deadline = Date(timeIntervalSinceNow: 3)
    while model.interruptedRecordings.count != 2 && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(model.interruptedRecordings.count, 2)
    XCTAssertNil(model.recoveryMessage)
    // Recovery must still find its grant when no shared default is selected.
    model.outputFolder = nil
    let take = try XCTUnwrap(model.interruptedRecordings.first)
    model.recover(take)
    XCTAssertEqual(model.recoveringID, take.id)
    let recoveryDeadline = Date(timeIntervalSinceNow: 3)
    while model.recoveringID != nil && Date() < recoveryDeadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertNil(model.recoveringID)
    XCTAssertNotNil(model.recoveryMessage, "Invalid synthetic media should report an error from the recovery attempt")
  }

  func testSuccessfulRecoveryScanClearsAnEarlierScanError() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ultracam-scan-error-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = RecordingModel()
    model.outputFolder = root
    let failureDeadline = Date(timeIntervalSinceNow: 3)
    while model.recoveryMessage == nil && Date() < failureDeadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertNotNil(model.recoveryMessage)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    model.refreshRecovery()
    let successDeadline = Date(timeIntervalSinceNow: 3)
    while model.recoveryMessage != nil && Date() < successDeadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertNil(model.recoveryMessage)
    XCTAssertTrue(model.interruptedRecordings.isEmpty)
  }

  func testPerFeedControlsRemainIndependent() {
    let driver = Driver()
    let folder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)
    let model = RecordingModel(feeds: [
      RecordingFeedDescriptor(id: first, name: "Wide"),
      RecordingFeedDescriptor(id: second, name: "Tight"),
    ], driver: driver)
    model.outputFolder = folder
    model.codec = .hevcMain10_422
    model.timecodeMode = .recordStart

    model.record(feedID: first)
    model.record(feedID: second)
    XCTAssertEqual(model.feeds.map(\.status), [.recording, .recording])
    XCTAssertEqual(driver.operations.count, 2)
    var wideTake = model.configuration
    wideTake.feedName = "Wide"
    XCTAssertEqual(driver.operations[0], .start(first, wideTake))
    var tightTake = model.configuration
    tightTake.feedName = "Tight"
    XCTAssertEqual(driver.operations[1], .start(second, tightTake))

    model.pause(feedID: first)
    model.stop(feedID: second)
    XCTAssertEqual(model.feeds.map(\.status), [.paused, .idle])
    XCTAssertNil(model.feeds[0].error)
    XCTAssertNil(model.feeds[1].error)

    model.resume(feedID: first)
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertEqual(driver.operations.suffix(3).map { operation in
      switch operation {
      case .pause: return "pause"
      case .stop: return "stop"
      case .resume: return "resume"
      case .start: return "start"
      }
    }, ["pause", "stop", "resume"])
  }

  func testAllFeedActionsContinueAfterOneFeedError() {
    let driver = Driver()
    driver.failingFeeds = [second]
    let model = RecordingModel(feeds: [
      RecordingFeedDescriptor(id: first, name: "One"),
      RecordingFeedDescriptor(id: second, name: "Two"),
    ], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)

    model.recordAll()
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertEqual(model.feeds[1].status, .idle)
    XCTAssertNotNil(model.feeds[1].error)
    XCTAssertEqual(driver.operations.count, 1)

    model.stopAll()
    XCTAssertEqual(model.feeds[0].status, .idle)
    XCTAssertEqual(model.feeds[1].status, .idle)
    XCTAssertEqual(model.feeds[0].error, nil)
  }

  func testFailedStopReturnsTheFeedToIdleAndClosesTheTake() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "One")], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)
    model.record(feedID: first)
    var finished: [FeedID] = []
    model.onRecordingFinished = { feedID, _ in finished.append(feedID) }
    driver.failingFeeds = [first]

    model.stop(feedID: first)

    XCTAssertEqual(model.feeds[0].status, .idle)
    XCTAssertNotNil(model.feeds[0].error)
    XCTAssertEqual(finished, [first])
    driver.failingFeeds = []
    model.record(feedID: first)
    XCTAssertEqual(model.feeds[0].status, .recording)
  }

  func testFolderRequirementIsReportedPerFeed() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "One")], driver: driver)

    model.record(feedID: first)

    XCTAssertEqual(model.feeds[0].status, .idle)
    XCTAssertEqual(model.feeds[0].error, RecordingUIError.outputFolderRequired.localizedDescription)
    XCTAssertTrue(driver.operations.isEmpty)
  }

  func testFeedRefreshPreservesLiveStateAndDropsRemovedFeeds() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Old")], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/recordings", isDirectory: true)
    model.record(feedID: first)

    model.updateFeeds([
      RecordingFeedDescriptor(id: first, name: "Renamed"),
      RecordingFeedDescriptor(id: second, name: "Added"),
    ])

    XCTAssertEqual(model.feeds.map(\.id), [first, second])
    XCTAssertEqual(model.feeds[0].name, "Renamed")
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertEqual(model.feeds[1].status, .idle)
  }

  func testFeedRefreshRetainsRemovedActiveFeedUntilStopped() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "One")], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/recordings")
    model.record(feedID: first)

    model.updateFeeds([])
    XCTAssertEqual(model.feeds.map(\.id), [first],
      "An active recording must remain addressable after its descriptor is removed")
    XCTAssertEqual(model.feeds[0].status, .recording)

    model.stop(feedID: first)
    XCTAssertEqual(model.feeds[0].status, .idle)
    model.updateFeeds([])
    XCTAssertTrue(model.feeds.isEmpty,
      "Once stopped, the removed feed should disappear on the next refresh")
  }

  func testDuplicateFeedDescriptorsAreCollapsed() {
    let driver = Driver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "One")], driver: driver)
    model.updateFeeds([
      RecordingFeedDescriptor(id: first, name: "One"),
      RecordingFeedDescriptor(id: first, name: "One duplicate"),
      RecordingFeedDescriptor(id: second, name: "Two"),
      RecordingFeedDescriptor(id: second, name: "Two duplicate"),
    ])
    XCTAssertEqual(model.feeds.map(\.id), [first, second])
  }

  func testNativeDriverUsesPerFeedSourceRecorderAndReportsAudioGap() throws {
    let capture = CaptureController(services: CaptureServices(
      start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    var configurations: [SourceRecordingConfiguration] = []
    let driver = NativeRecordingSessionDriver(captureForFeed: { _ in capture },
      recorderFactory: { configuration in
        configurations.append(configuration)
        return try SourceRecorderCore(configuration: configuration, writerFactory: { Writer() })
      })
    let first = FeedID(rawValue: "feed-a")
    let second = FeedID(rawValue: "feed-b")
    let folder = URL(fileURLWithPath: "/tmp/ultracam-recordings", isDirectory: true)

    try driver.startRecording(feedID: first,
      configuration: RecordingConfiguration(codec: .hevcMain10_422, outputFolder: folder))
    try driver.startRecording(feedID: second,
      configuration: RecordingConfiguration(codec: .proRes42210Bit, outputFolder: folder))

    XCTAssertEqual(configurations.count, 2)
    XCTAssertEqual(configurations.map(\ .feedID.rawValue), [first.rawValue, second.rawValue])
    XCTAssertEqual(configurations.map(\ .videoCodec), [kCMVideoCodecType_HEVC, kCMVideoCodecType_AppleProRes422HQ])
    XCTAssertTrue(configurations.allSatisfy { $0.width == 3840 && $0.height == 2160 })
    XCTAssertEqual(driver.startWarning, .rawAudioUnavailable)
    XCTAssertTrue(configurations.allSatisfy { $0.timecodePolicy == .wallClock })
    XCTAssertTrue(configurations.allSatisfy { $0.timecodeSamplesComputerClockAtFirstFrame })

    let third = FeedID(rawValue: "feed-c")
    try driver.startRecording(feedID: third,
      configuration: RecordingConfiguration(codec: .hevcMain10_422, outputFolder: folder,
        timecodeMode: .source))
    XCTAssertEqual(configurations[2].timecodePolicy, .source)
    XCTAssertFalse(configurations[2].timecodeSamplesComputerClockAtFirstFrame)

    try driver.stopRecording(feedID: first)
    try driver.stopRecording(feedID: second)
    try driver.stopRecording(feedID: third)
  }

  func testNativeOutputUsesSafeFeedNamesAndKeepsDuplicateNamesDistinct() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-naming-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = CaptureController(services: CaptureServices(
      start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    let idsLock = NSLock()
    var sourceIDs: [String] = []
    let driver = NativeRecordingSessionDriver(captureForFeed: { _ in capture }, rawAudioCallbackAvailable: true,
      recorderFactory: { configuration in
        idsLock.withLock { sourceIDs.append(configuration.feedID.rawValue) }
        return try SourceRecorderCore(configuration: configuration, writerFactory: { Writer() })
      })
    let model = RecordingModel(feeds: [
      RecordingFeedDescriptor(id: .primary, name: "../Wide / Camera"),
      RecordingFeedDescriptor(id: second, name: "Wide : Camera"),
    ], driver: driver)
    model.outputFolder = root
    model.recordAll()
    XCTAssertEqual(model.feeds.map(\.status), [.recording, .recording])
    XCTAssertTrue(waitForStarts(model))
    XCTAssertTrue(model.feeds.allSatisfy { $0.error == nil })
    let firstURL = try XCTUnwrap(driver.recordingOutputURL(feedID: .primary))
    let secondURL = try XCTUnwrap(driver.recordingOutputURL(feedID: second))
    XCTAssertEqual(firstURL.deletingLastPathComponent(), root.appendingPathComponent("Wide Camera", isDirectory: true))
    XCTAssertEqual(secondURL.deletingLastPathComponent(), firstURL.deletingLastPathComponent())
    XCTAssertTrue(firstURL.lastPathComponent.hasPrefix("Wide Camera_"))
    XCTAssertFalse(firstURL.path.contains(FeedID.primary.rawValue))
    XCTAssertNotEqual(firstURL, secondURL)
    // The two takes start on workers, in either order.
    XCTAssertEqual(Set(idsLock.withLock { sourceIDs }), [FeedID.primary.rawValue, second.rawValue])
    model.stopAll()
  }

  func testSlowNativeFinalizationKeepsUIResponsiveAndQuitWaitsForCompletion() throws {
    for fail in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-stop-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let capture = CaptureController(services: CaptureServices(
        start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
      let writer = SlowFinishingWriter(fail: fail)
      let driver = NativeRecordingSessionDriver(captureForFeed: { _ in capture }, rawAudioCallbackAvailable: true,
        recorderFactory: { configuration in
          try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
        })
      let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide")], driver: driver)
      model.outputFolder = root
      model.record(feedID: first)
      let start = ProcessInfo.processInfo.systemUptime
      model.stop(feedID: first)
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
      XCTAssertEqual(writer.entered.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(model.feeds[0].status, .finishing)
      XCTAssertFalse(model.canStopAny)
      XCTAssertNotNil(driver.recordingOutputURL(feedID: first))
      model.record(feedID: first)
      model.stop(feedID: first)
      model.updateFeeds([])
      XCTAssertEqual(model.feeds.count, 1, "A finishing feed must remain reachable")
      var quitReady = false
      model.stopAll { quitReady = true }
      XCTAssertFalse(quitReady)
      var heartbeat = false
      DispatchQueue.main.async { heartbeat = true }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
      XCTAssertTrue(heartbeat, "The main queue must run while the media writer is blocked")
      writer.release.signal()
      let deadline = Date(timeIntervalSinceNow: 2)
      while model.hasActiveRecordings && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      }
      XCTAssertEqual(model.feeds[0].status, .idle)
      XCTAssertEqual(model.feeds[0].error != nil, fail)
      XCTAssertTrue(quitReady)
      XCTAssertNil(driver.recordingOutputURL(feedID: first))
    }
  }

  func testFailedNativeStopPreservesNonemptyOutputEvenWithoutAcceptedSampleTelemetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-failed-take-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = CaptureController(services: CaptureServices(
      start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    let writer = SlowFinishingWriter(fail: true)
    writer.release.signal()
    let media = Data([10, 20, 30])
    let driver = NativeRecordingSessionDriver(captureForFeed: { _ in capture }, recorderFactory: { configuration in
      try media.write(to: configuration.outputURL)
      return try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
    })
    try driver.startRecording(feedID: first, configuration: RecordingConfiguration(outputFolder: root, feedName: "Wide"))
    XCTAssertThrowsError(try driver.stopRecording(feedID: first))
    let take = try XCTUnwrap(RecordingRecovery.scan(root: root).first)
    XCTAssertEqual(try Data(contentsOf: take.temporaryURL), media)
    XCTAssertFalse(FileManager.default.fileExists(atPath: take.finalURL.path))
  }

  func testRestoredFolderOffersInterruptedTakeAcrossConcurrentLaunchScans() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-recovery-launch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = try RecordingOutputManager(rootDirectory: root, minimumFreeBytes: 0)
    let output = try manager.beginExternalWriterSession(feedID: "Wide")
    try Data([1, 2, 3]).write(to: output.temporaryURL)
    output.preserveForRecovery()
    let suite = "UltracamRecoveryLaunch-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = RecordingFolderStore(defaults: defaults)
    try store.save(root)
    let models = (0..<8).map { _ in RecordingModel(folderStore: store) }
    for model in models { model.refreshRecovery() }
    let deadline = Date(timeIntervalSinceNow: 3)
    while models.contains(where: { $0.interruptedRecordings.count != 1 }) && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    for model in models {
      XCTAssertEqual(model.interruptedRecordings.count, 1)
      XCTAssertNil(model.recoveryMessage)
    }
  }

  func testPerFeedStatisticsRemainAfterStopAndResetForANewTake() {
    let driver = StatisticsDriver()
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide"),
      RecordingFeedDescriptor(id: second, name: "Tight")], driver: driver)
    model.outputFolder = URL(fileURLWithPath: "/tmp/statistics-only")
    model.record(feedID: first)
    XCTAssertEqual(model.feeds[0].displayStatus, "Waiting for video")
    driver.snapshots = [first: RecordingStatistics(elapsed: 65, fileBytes: 1_000_000,
      encodedFrames: 120, droppedVideoFrames: 2), second: RecordingStatistics(elapsed: 3, encodedFrames: 60)]
    let updated = expectation(description: "Statistics applied")
    Task {
      await model.refreshStatistics()
      XCTAssertEqual(model.feeds[0].statistics?.elapsedText, "00:01:05")
      XCTAssertEqual(model.feeds[0].statistics?.droppedVideoFrames, 2)
      XCTAssertEqual(model.feeds[1].statistics?.encodedFrames, 60)
      model.stop(feedID: self.first)
      XCTAssertEqual(model.feeds[0].displayStatus, "Finished")
      XCTAssertEqual(model.feeds[0].statistics?.fileBytes, 1_000_000)
      model.record(feedID: self.first)
      XCTAssertEqual(model.feeds[0].statistics?.elapsed, 0)
      XCTAssertEqual(model.feeds[0].statistics?.droppedVideoFrames, 0)
      driver.snapshots.removeAll()
      model.stopAll()
      updated.fulfill()
    }
    wait(for: [updated], timeout: 3)
  }

  private func waitForStarts(_ model: RecordingModel, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while model.feeds.contains(where: \.isStarting) && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return !model.feeds.contains(where: \.isStarting)
  }

  private final class SlowStartingWriter: SourceRecordingWriter, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func start() throws {
      entered.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    func appendVideo(_ sample: CMSampleBuffer) throws {}
    func appendAudio(_ sample: CMSampleBuffer) throws {}
    func finish() throws {}
  }

  /// Record must not wait on the main thread for the encoder (about 100 ms
  /// cold, longer while the GPU kernel compiles): the take shows
  /// "Starting…" at once, capture connects only once the recorder is ready,
  /// and a Stop pressed meanwhile is honoured.
  func testNativeStartDoesNotBlockTheMainThread() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-start-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = CaptureController(services: CaptureServices(
      start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true }))
    let writer = SlowStartingWriter()
    let driver = NativeRecordingSessionDriver(captureForFeed: { _ in capture }, rawAudioCallbackAvailable: true,
      recorderFactory: { configuration in
        try SourceRecorderCore(configuration: configuration, writerFactory: { writer })
      })
    let model = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide")], driver: driver)
    model.outputFolder = root
    let started = ProcessInfo.processInfo.systemUptime
    model.record(feedID: first)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1, "Record returned only after the encoder")
    XCTAssertEqual(writer.entered.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertTrue(model.feeds[0].isStarting)
    XCTAssertEqual(model.feeds[0].displayStatus, "Starting…")
    XCTAssertFalse(model.canPauseAny, "Pause waits until the take records")
    XCTAssertNil(driver.recordingOutputURL(feedID: first), "Capture is not connected before the recorder is ready")
    var heartbeat = false
    DispatchQueue.main.async { heartbeat = true }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    XCTAssertTrue(heartbeat, "The main queue must run while the encoder is being prepared")
    writer.release.signal()
    XCTAssertTrue(waitForStarts(model))
    XCTAssertEqual(model.feeds[0].status, .recording)
    XCTAssertNotEqual(model.feeds[0].displayStatus, "Starting…")
    XCTAssertNotNil(driver.recordingOutputURL(feedID: first))
    var stopped = false
    model.stopAll { stopped = true }
    let deadline = Date(timeIntervalSinceNow: 3)
    while !stopped && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
    XCTAssertTrue(stopped)
    XCTAssertEqual(model.feeds[0].status, .idle)

    // Stop while the take is still starting: it finishes once the take exists.
    let second = SlowStartingWriter()
    let stopDriver = NativeRecordingSessionDriver(captureForFeed: { _ in capture }, rawAudioCallbackAvailable: true,
      recorderFactory: { configuration in
        try SourceRecorderCore(configuration: configuration, writerFactory: { second })
      })
    let stopModel = RecordingModel(feeds: [RecordingFeedDescriptor(id: first, name: "Wide")], driver: stopDriver)
    stopModel.outputFolder = root
    stopModel.record(feedID: first)
    XCTAssertEqual(second.entered.wait(timeout: .now() + 2), .success)
    stopModel.stop(feedID: first)
    XCTAssertEqual(stopModel.feeds[0].status, .finishing)
    var quit = false
    stopModel.stopAll { quit = true }
    XCTAssertFalse(quit)
    second.release.signal()
    let stopDeadline = Date(timeIntervalSinceNow: 3)
    while !quit && Date() < stopDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
    XCTAssertTrue(quit, "Quit waits for a take stopped while it started")
    XCTAssertEqual(stopModel.feeds[0].status, .idle)
    XCTAssertFalse(stopModel.feeds[0].isStarting)
    XCTAssertNil(stopDriver.recordingOutputURL(feedID: first))
  }

}
