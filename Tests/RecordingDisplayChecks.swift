#if ULTRACAM_TEST_SUPPORT
import CoreMedia
import Foundation
import XCTest

/// What the interface says about space, finished takes and channels. The recorder's own
/// cautious figure stays untouched: these are display numbers.
@objcMembers final class RecordingDisplayChecks: XCTestCase {
  private let uhd5994 = CMTime(value: 1001, timescale: 60000)

  // MARK: B9

  func testIdleHEVCFigureIsWhatTakesReallyWrite() {
    let shown = UIRecordingLibrary.displayMegabits(codec: .hevcMain10_422, width: 3840, height: 2160, frameDuration: uhd5994)
    let pixels = 3840.0 * 2160 * 60000 / 1001
    XCTAssertEqual(shown, pixels * 0.014 * 8 / 1_000_000 + 2.304, accuracy: 0.001)
    XCTAssertEqual(shown, 58, accuracy: 1, "The real 4K take runs about 53 Mb/s of video")
  }

  func testTheAdmissionFigureStaysCautious() throws {
    let guardRate = try XCTUnwrap(RecordingSizeEstimator(codec: .hevcMain10_422, width: 3840, height: 2160, frameDuration: uhd5994))
    XCTAssertEqual(guardRate.megabitsPerSecond, 597, accuracy: 1, "It guards free space, so it must not follow the display")
  }

  func testPCMIsAddedAndCountsChannels() {
    XCTAssertEqual(UIRecordingLibrary.pcmMegabits(channels: 8), 9.216, accuracy: 0.001, "8 × 24 bits × 48 kHz")
    let two = UIRecordingLibrary.displayMegabits(codec: .proRes42210Bit, frameDuration: uhd5994, audioChannels: 2)
    let eight = UIRecordingLibrary.displayMegabits(codec: .proRes42210Bit, frameDuration: uhd5994, audioChannels: 8)
    XCTAssertEqual(eight - two, 9.216 - 2.304, accuracy: 0.001)
    XCTAssertEqual(two, (UIRecordingLibrary.nominalMegabits(codec: .proRes42210Bit, width: 3840, height: 2160, frameDuration: uhd5994) ?? 0) + 2.304,
      accuracy: 0.001, "ProRes is close already: only HEVC is corrected")
  }

  func testMeasuredRateComesFirstAndAFirstSampleKeepsTheEstimate() {
    XCTAssertEqual(UIRecordingLibrary.rollingMegabits(measuredVideo: 53, estimate: 58, audioChannels: 8), 62.216, accuracy: 0.001)
    XCTAssertEqual(UIRecordingLibrary.rollingMegabits(measuredVideo: 0, estimate: 58, audioChannels: 8), 58, "A take's first sample measures nothing")
    XCTAssertEqual(UIRecordingLibrary.rollingMegabits(measuredVideo: nil, estimate: 58, audioChannels: 8), 58)
  }

  // MARK: B10

  func testTimeLeftCountsEveryCameraAssignedToTheDrive() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let one = try XCTUnwrap(UIRecordingLibrary.drives(for: [folder], recordingRates: [], assignedRates: [(folder, 60)]).first?.secondsLeft)
    let two = try XCTUnwrap(UIRecordingLibrary.drives(for: [folder, folder], recordingRates: [],
      assignedRates: [(folder, 60), (folder, 60)]).first?.secondsLeft)
    XCTAssertEqual(two, one / 2, accuracy: one * 0.01)
    let rolling = try XCTUnwrap(UIRecordingLibrary.drives(for: [folder, folder], recordingRates: [(folder, 60)],
      assignedRates: [(folder, 60), (folder, 60)]).first?.secondsLeft)
    XCTAssertEqual(rolling, one, accuracy: one * 0.01, "A rolling take measures what's really being written")
  }

  // MARK: B12

  private func camera(running: Bool = true, signal: UISignal = .live(format: "2160p 59.94"), dropped: Int = 0, gaps: Int = 0) -> UICameraSnapshot {
    var camera = UICameraSnapshot(id: "camera-1", name: "Camera 1")
    camera.running = running
    camera.signal = running ? signal : .none
    camera.recording.folderPath = "/Volumes/8TB/Takes"
    camera.recording.savedFileName = "Camera 1_001.mov"
    camera.recording.savedDuration = 751
    camera.recording.droppedFrames = dropped
    camera.recording.sourceGaps = gaps
    return camera
  }

  private func presented(_ camera: UICameraSnapshot) -> UICameraPresentation {
    var session = UISessionSnapshot()
    session.cameras = [camera]
    return UIPresentationBuilder.camera(camera, index: 0, in: session)
  }

  func testSavedOutlastsAStop() {
    XCTAssertEqual(presented(camera(running: false)).stripState, .saved, "The take's result is still the news")
    XCTAssertEqual(presented(camera(signal: .noSignal)).stripState, .saved)
    var next = camera(running: false)
    next.recording.savedFileName = nil
    XCTAssertEqual(presented(next).stripState, .stopped)
  }

  func testSavedKeepsItsLostFrames() {
    // The losses take the file name's place on the detail line: they're what the next look is for.
    XCTAssertEqual(presented(camera(dropped: 60, gaps: 5)).recordDetail, "60 frames lost in 5 gaps")
    XCTAssertEqual(presented(camera(dropped: 1, gaps: 1)).recordDetail, "1 frame lost in 1 gap")
    XCTAssertEqual(presented(camera(dropped: 2)).recordDetail, "2 frames lost")
    XCTAssertNil(presented(camera()).recordingNote)
    var noted = camera(dropped: 60, gaps: 5)
    noted.recording.note = "The input was missing 60 frames in 5 gaps during this take."
    XCTAssertEqual(presented(noted).recordDetail, "60 frames lost in 5 gaps", "Said once, plainly")
    XCTAssertNil(presented(noted).recordingNote, "The writer's sentence is for Diagnostics")
  }

  func testTakesListReadsSidecarCountsAndOlderTakesShowNothing() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("take.mov")
    XCTAssertNil(UITakeDurations.lostFrames(sidecarOf: movie), "No sidecar")
    let sidecar = try RecordingTakeSidecar(movieURL: movie, metadata: .init(sourceSignature: "s", outputSignature: "o"))
    XCTAssertNil(UITakeDurations.lostFrames(sidecarOf: movie), "An older take has no count")
    try sidecar.updateCounters(["recording.sourceVideoLost": 60, "recording.sourceSkippedFrames": 40])
    XCTAssertEqual(UITakeDurations.lostFrames(sidecarOf: movie), 60, "Skips are already inside the loss")
  }

  // MARK: B17

  func testStillRecordingNeedsAMeetingThatEnded() {
    var watch = UnusedTakeWatch()
    XCTAssertFalse(watch.update(rolling: true, clientConnected: false, clientsUnknown: false, now: 0))
    XCTAssertFalse(watch.update(rolling: true, clientConnected: false, clientsUnknown: false, now: 600), "A recording with no meeting is fine")
    XCTAssertFalse(watch.update(rolling: true, clientConnected: true, clientsUnknown: false, now: 601))
    XCTAssertFalse(watch.update(rolling: true, clientConnected: false, clientsUnknown: false, now: 601 + 119))
    XCTAssertTrue(watch.update(rolling: true, clientConnected: false, clientsUnknown: false, now: 601 + 120))
    XCTAssertFalse(watch.update(rolling: true, clientConnected: false, clientsUnknown: true, now: 900), "Nobody can tell")
    XCTAssertTrue(watch.update(rolling: true, clientConnected: false, clientsUnknown: false, now: 901))
    XCTAssertFalse(watch.update(rolling: true, clientConnected: true, clientsUnknown: false, now: 902), "They came back")
    XCTAssertFalse(watch.update(rolling: false, clientConnected: false, clientsUnknown: false, now: 2000))
    XCTAssertFalse(watch.update(rolling: true, clientConnected: false, clientsUnknown: false, now: 3000), "A new take starts clean")
  }

  // MARK: B18

  func testUnlabeledChannelsAreNumbered() {
    XCTAssertNil(UIChannelLabels.labels(2), "A stereo pair stays L and R")
    XCTAssertEqual(UIChannelLabels.labels(8), ["1", "2", "3", "4", "5", "6", "7", "8"], "Not 7.1 names")
    XCTAssertEqual(UIChannelLabels.labels(6), ["1", "2", "3", "4", "5", "6"])
  }

  @MainActor func testPopoverSaysTheRealFormat() {
    var camera = UICameraSnapshot(id: "a", name: "A")
    XCTAssertNil(UIStatusPopover.audioFormat(camera))
    camera.audioChannels = 8
    camera.audioSampleRate = 48000
    XCTAssertEqual(UIStatusPopover.audioFormat(camera)?.rate, "48 kHz")
    XCTAssertEqual(UIStatusPopover.audioFormat(camera)?.channels, "8 ch")
    camera.audioSampleRate = 44100
    XCTAssertEqual(UIStatusPopover.audioFormat(camera)?.rate, "44.1 kHz")
  }

  /// The strip and the fixtures show what the rig really sends.
  @MainActor func testFixturesMatchTheLiveStrip() {
    let camera = UIFixtures.camera(1)
    XCTAssertEqual(camera.audio.meterSnapshot.channelCount, 8)
    XCTAssertEqual(camera.audioChannels, 8)
    XCTAssertNotNil(UIContext.fixture(UIFixtures.programMeeting()).cameraControls)
  }
}
#endif
