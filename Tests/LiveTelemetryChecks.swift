import CoreMedia
import XCTest

@objcMembers final class LiveTelemetryChecks: XCTestCase {
  func testSourceFormatChangePublishesWithUnchangedDisplayStrings() throws {
    var update = CaptureUpdate(message: "Capturing")
    let noDeclaration = CaptureUpdateState(update)
    update.sourceFormat = try SourceFormat(width: 1920, height: 1080, pixel: .v210,
      rate: .constant(VideoContract.fastDuration))
    XCTAssertNotEqual(CaptureUpdateState(update), noDeclaration)
    let declared = CaptureUpdateState(update)
    update.sourceFormat = try SourceFormat(width: 1920, height: 1080, pixel: .twoVuy,
      rate: .constant(VideoContract.fastDuration))
    XCTAssertNotEqual(CaptureUpdateState(update), declared)
  }

  func testCaptureStatePublishesExactDeclaredCadenceChanges() {
    var update = CaptureUpdate(message: "Capturing")
    update.sourceDuration = CMTime(value: 1001, timescale: 24_000)
    let film = CaptureUpdateState(update)
    update.sourceDuration = CMTime(value: 1, timescale: 25)
    let pal = CaptureUpdateState(update)
    XCTAssertNotEqual(film, pal)
    XCTAssertEqual(pal.sourceDuration, CMTime(value: 1, timescale: 25))
    update.frames = 100
    let firstFrame = CaptureUpdateState(update)
    update.frames = 101
    XCTAssertEqual(firstFrame, CaptureUpdateState(update))
  }

#if ULTRACAM_TEST_SUPPORT
  @MainActor func testTakeTelemetryClampsFileSizeToPresentationRange() throws {
    let suite = "org.ultracam.tests.telemetry.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let previousWarning = AudioMeterTap.warningLevel
    defer { AudioMeterTap.setWarningLevel(Double(previousWarning)) }
    let model = AppModel(settingsStore: AppSettingsStore(defaults: defaults),
      registryStore: VirtualCameraRegistryStore(defaults: defaults), registryPublisher: SyntheticRegistryPublisher(),
      recordingFolderStore: RecordingFolderStore(defaults: defaults), hardware: .offline)
    let bridge = UISessionBridge(model: model, interface: UIInterfaceState(defaults: defaults))
    var recording = UICameraRecording()
    bridge.applyTake(model.selectedFeedID, statistics: RecordingStatistics(fileBytes: .max),
      drives: [], to: &recording)
    XCTAssertEqual(recording.fileBytes, Int64.max)
  }
#endif

  /// The CPU copy count is a total since Start. A window opened (or reopened) long after a
  /// camera stopped copying reads that total first: no "CPU copy" pill for it; only growth
  /// after that first reading lights it, for a second.
  func testCPUCopyPillNeedsGrowthAfterTheFirstReading() {
    let first = UILiveSource.ingestActivity(previous: nil, count: 500, now: 100)
    XCTAssertFalse(100 - first.lastChange < 1, "The first reading of an old total is not copying now")
    let same = UILiveSource.ingestActivity(previous: first, count: 500, now: 100.25)
    XCTAssertFalse(100.25 - same.lastChange < 1)
    let grew = UILiveSource.ingestActivity(previous: same, count: 503, now: 100.5)
    XCTAssertTrue(100.5 - grew.lastChange < 1, "Copying now lights the pill")
    let quiet = UILiveSource.ingestActivity(previous: grew, count: 503, now: 101.75)
    XCTAssertFalse(101.75 - quiet.lastChange < 1, "A second without growth turns it off")
    let restarted = UILiveSource.ingestActivity(previous: grew, count: 2, now: 100.75)
    XCTAssertEqual(restarted.lastChange, -.infinity, "A lower total after restart establishes a new baseline")
    XCTAssertEqual(UILiveSource.ingestActivity(previous: restarted, count: 3, now: 101).lastChange, 101)
  }
}
