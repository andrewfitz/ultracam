import AppKit
import Foundation
import MonitorKitAudio
import XCTest

/// Phase 4 of the UI plan: the Settings window's eight tabs and what they save. The tab comes
/// back, links open their tab, Channels Shown counts and measures as section 7 says, the
/// background shortcuts follow their one switch, and alerts, low space, the true-peak warning,
/// file naming and B14 persist and take effect.
@MainActor @objcMembers final class UISettingsChecks: XCTestCase {
  private func suite(_ name: String) -> (UserDefaults, () -> Void) {
    let suiteName = "org.ultracam.tests.settings-\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
  }

  // MARK: Tabs

  func testTabsAreEightInOrderAndSettingsReopensOnTheLastOne() {
    let (defaults, done) = suite("tab")
    defer { done() }
    XCTAssertEqual(UISettingsTab.allCases.map(\.title),
      ["General", "Hardware", "Virtual Cameras", "Recording", "Audio", "Switching", "Alerts", "Advanced"])
    XCTAssertEqual(UIInterfaceState(defaults: defaults).settingsTab, .general, "A first run opens on General")
    UIInterfaceState(defaults: defaults).settingsTab = .alerts
    XCTAssertEqual(UIInterfaceState(defaults: defaults).settingsTab, .alerts)
    defaults.set("monitor", forKey: UIInterfaceState.settingsTabKey)
    XCTAssertEqual(UIInterfaceState(defaults: defaults).settingsTab, .general, "A tab that's gone opens General")
  }

  func testSettingsLinksNameTheirTab() throws {
    XCTAssertEqual(UISettingsTab.linked(try XCTUnwrap(URL(string: "ultracam-settings:recording"))), .recording)
    XCTAssertEqual(UISettingsTab.linked(try XCTUnwrap(URL(string: "ultracam-settings:virtualCameras"))), .virtualCameras)
    XCTAssertNil(UISettingsTab.linked(try XCTUnwrap(URL(string: "https://example.com/recording"))))
    XCTAssertNil(UISettingsTab.linked(try XCTUnwrap(URL(string: "ultracam-settings:monitor"))))
  }

  // MARK: Channels Shown

  func testAsDetectedIsTheSmallestTierCoveringTheHighestPair() {
    XCTAssertEqual(UIChannelsShown.tier(covering: 0), 2, "Before anything is detected it reads 2")
    XCTAssertEqual([2, 4, 6, 8, 10, 16].map(UIChannelsShown.tier(covering:)), [2, 4, 8, 8, 16, 16])
    XCTAssertEqual(UIChannelsShown.asDetected.count(detected: 6, available: 8), 8)
    XCTAssertEqual(UIChannelsShown.asDetected.count(detected: 0, available: 8), 2)
    XCTAssertEqual(UIChannelsShown.sixteen.count(detected: 0, available: 8), 8, "Never more than the source has")
    XCTAssertEqual(UIChannelsShown.four.count(detected: 8, available: nil), 4, "A stopped camera keeps its choice")
    XCTAssertEqual(UIChannelsShown.status(shown: 2, of: 8), "Showing 2 of 8")
    XCTAssertEqual(UIChannelsShown.status(shown: 2, of: nil), "Stopped")
    XCTAssertEqual(UIChannelsShown.allCases.map(\.title), ["As Detected", "2", "4", "8", "16"], "Nothing is left out")
  }

  func testSignalIsATruePeakAboveMinus90() {
    // Channels 1–2 at −20 dB and channel 5 at −40 dB: the pair 5–6 covers 6 channels.
    let speaking = AudioMeterTap.snapshot(statusPeaks: [0.1, 0.1, 0, 0, 0.01, 0, 0, 0])
    XCTAssertEqual(AudioMeterTap.channelsWithSignal(speaking), 6)
    XCTAssertEqual(UIChannelsShown.tier(covering: AudioMeterTap.channelsWithSignal(speaking)), 8)
    // −100 dB is below one 16-bit step: not signal.
    let floor = AudioMeterTap.snapshot(statusPeaks: [0.1, 0.1, 0.000_01, 0, 0, 0, 0, 0])
    XCTAssertEqual(AudioMeterTap.channelsWithSignal(floor), 2)
    XCTAssertEqual(AudioMeterTap.channelsWithSignal(AudioMeterTap.snapshot(statusPeaks: [0, 0])), 0)
    // An over on a channel the strip hides is still found, and named by its channel.
    let hot = AudioMeterTap.snapshot(statusPeaks: [0.1, 0.1, 0, 0, 0, 0, 1, 0])
    XCTAssertEqual(AudioMeterTap.hiddenOver(hot, from: 2), 6)
    XCTAssertNil(AudioMeterTap.hiddenOver(hot, from: 8))
  }

  func testChannelsShownPersistsPerCameraAndDefaultsToAsDetected() {
    let (defaults, done) = suite("channels")
    defer { done() }
    let interface = UIInterfaceState(defaults: defaults)
    XCTAssertEqual(interface.channelsShown(for: "camera-1"), .asDetected)
    interface.setChannelsShown(.four, for: "camera-1")
    interface.setChannelsShown(.eight, for: "camera-2")
    let reloaded = UIInterfaceState(defaults: defaults)
    XCTAssertEqual(reloaded.channelsShown(for: "camera-1"), .four)
    XCTAssertEqual(reloaded.channelsShown(for: "camera-2"), .eight)
    reloaded.setChannelsShown(.asDetected, for: "camera-1")
    XCTAssertNil(reloaded.channelsShown["camera-1"], "As Detected is the default, so it isn't stored")
  }

#if ULTRACAM_TEST_SUPPORT
  /// A strip showing 2 of 8 meters the first two channels of the same packets, As Detected grows
  /// with the highest pair that carries signal and never shrinks, and a new capture starts it over.
  func testTapMetersAShownSubsetAndDetectsTheHighestPair() throws {
    let format = try SourceAudioFormat(sampleRate: 48_000, channels: 8, sample: .float32,
      interleaved: false, layout: AudioChannelMap(), clock: .hostTime)
    func packet(_ levels: [Float]) throws -> CaptureAudioPacket {
      let planes = levels.map { level in Array(repeating: level, count: 480).withUnsafeBytes { Data($0) } }
      return try CaptureAudioPacket(planes: planes, sampleFrameCount: 480, format: format, packetTime: .zero)
    }
    let tap = AudioMeterTap()
    try tap.configure(format: format)
    let full = tap.attach()
    defer { tap.detach() }
    XCTAssertNil(tap.displayMeter(channels: 8), "Every channel: the strip shows the full meter")
    let shown = try XCTUnwrap(tap.displayMeter(channels: 2))
    XCTAssertTrue(tap.displayMeter(channels: 2) === shown, "One meter per count, per session")
    tap.ingest(try packet([0.25, 0.25, 0, 0, 0.01, 0, 0, 0]))
    tap.waitUntilMetered()
    full.flush()
    shown.flush()
    XCTAssertEqual(shown.snapshot().channelCount, 2)
    XCTAssertEqual(shown.snapshot().frameCount, 480)
    XCTAssertEqual(shown.snapshot().channels[0].samplePeak, full.snapshot().channels[0].samplePeak)
    XCTAssertEqual(tap.detectedChannels, 6)
    tap.ingest(try packet([0.25, 0.25, 0, 0, 0, 0, 0, 0]))
    tap.waitUntilMetered()
    XCTAssertEqual(tap.detectedChannels, 6, "As Detected only grows")
    tap.noteGap()
    XCTAssertEqual(tap.detectedChannels, 0, "A new capture starts it over")
  }
#endif

  // MARK: Level warning

  func testTruePeakWarningPersistsAndSetsTheOverLevel() {
    let (defaults, done) = suite("warning")
    defer { done(); AudioMeterTap.setWarningLevel(-1) }
    let interface = UIInterfaceState(defaults: defaults)
    XCTAssertEqual(interface.truePeakWarning, -1)
    interface.truePeakWarning = -3
    XCTAssertEqual(AudioMeterTap.warningLevel, -3)
    XCTAssertEqual(UIInterfaceState(defaults: defaults).truePeakWarning, -3)
    defaults.set(-7.0, forKey: UIInterfaceState.truePeakWarningKey)
    XCTAssertEqual(UIInterfaceState(defaults: defaults).truePeakWarning, -1, "Only −1, −2 or −3")
    XCTAssertEqual(UITruePeakWarning.levels.map(UITruePeakWarning.title), ["−1 dBTP", "−2 dBTP", "−3 dBTP"])
    // −2 dBTP counts a −1.5 dBTP peak as an over; the default doesn't.
    var watch = AudioMeterTap.OverWatch()
    var snapshot = AudioMeterTap.snapshot(statusPeaks: [0.84, 0])
    XCTAssertNil(watch.observe(snapshot, source: 1))
    watch = AudioMeterTap.OverWatch()
    snapshot = AudioMeterTap.snapshot(statusPeaks: [0.84, 0])
    XCTAssertNotNil(watch.observe(snapshot, source: 1, level: -2))
    let summary = AudioTakeSummary(integrated: -23, maximumTruePeak: -1.5, overs: 0, duration: 60, warningLevel: -2)
    XCTAssertTrue(summary.needsAttention)
    XCTAssertFalse(AudioTakeSummary(integrated: -23, maximumTruePeak: -1.5, overs: 0, duration: 60).needsAttention)
  }

  // MARK: General

  func testBackgroundShortcutsRegisterOnlyWhileTheirSwitchIsOn() {
    let (defaults, done) = suite("shortcuts")
    defer { done() }
    let shortcuts = UIBackgroundShortcuts(defaults: defaults)
    XCTAssertFalse(shortcuts.enabled, "Off by default")
    shortcuts.start()
    XCTAssertEqual(shortcuts.registeredCount, 0, "Nothing registers while off")
    shortcuts.enabled = true
    // A chord another app holds is reported, not lost: together they are all ten.
    XCTAssertEqual(shortcuts.registeredCount + shortcuts.unavailable.count, UIBackgroundShortcut.all.count)
    XCTAssertTrue(UIBackgroundShortcuts(defaults: defaults).enabled, "The switch is saved")
    shortcuts.enabled = false
    XCTAssertEqual(shortcuts.registeredCount, 0, "Off unregisters every chord")
    XCTAssertTrue(shortcuts.unavailable.isEmpty)
  }

  func testAskBeforeEndingIsOnUntilTurnedOff() {
    let (defaults, done) = suite("ask")
    defer { done() }
    XCTAssertTrue(UIInterfaceState(defaults: defaults).askBeforeEnding)
    defaults.set(false, forKey: UIInterfaceState.askBeforeEndingKey)
    XCTAssertFalse(UIInterfaceState(defaults: defaults).askBeforeEnding)
  }

  // MARK: Recording

  func testFolderActionAndTimecodeFootnote() {
    XCTAssertEqual(UISettingsRecordingPane.folderAction(hasFolder: false, rolling: false), "Choose…")
    XCTAssertEqual(UISettingsRecordingPane.folderAction(hasFolder: true, rolling: false), "Change…")
    XCTAssertEqual(UISettingsRecordingPane.folderAction(hasFolder: true, rolling: true), "Folder for Next Take…")
    XCTAssertEqual(UISettingsRecordingPane.firstSentence(RecordingTimecodeMode.source.help),
      "Preserves available native source timecode.")
  }

  func testFileNamingPersistsAndResets() {
    let (defaults, done) = suite("naming")
    defer { done() }
    let store = AppSettingsStore(defaults: defaults)
    XCTAssertEqual(store.recordingNaming, .standard)
    let naming = RecordingFileNaming(tokens: [.date, .camera], cameraSubfolders: false)
    store.recordingNaming = naming
    XCTAssertEqual(AppSettingsStore(defaults: defaults).recordingNaming, naming)
    store.resetAll()
    XCTAssertEqual(AppSettingsStore(defaults: defaults).recordingNaming, .standard)
    let preview = UISettingsRecordingPane.preview(naming: naming, camera: "Camera 1")
    XCTAssertTrue(preview.hasSuffix("_Camera 1_9F2C41D0-5B7E-4E0A-8C3D-2A61F0B7C9E4.mov"), preview)
    XCTAssertFalse(preview.contains("/"), "No camera subfolder")
  }

  // MARK: Alerts

  func testAlertEventsLowSpaceAndTheirEffect() {
    let (defaults, done) = suite("alerts")
    defer { done() }
    let preferences = UIAlertPreferences(defaults: defaults)
    XCTAssertEqual(preferences.events, Set(UIAlertEvent.allCases), "Every event notifies by default")
    XCTAssertEqual(preferences.lowSpaceMinutes, 30)
    preferences.setNotifies(.driveLow, false)
    preferences.lowSpaceMinutes = 60
    let reloaded = UIAlertPreferences(defaults: defaults)
    XCTAssertFalse(reloaded.notifies(.driveLow))
    XCTAssertTrue(reloaded.notifies(.takeEndedEarly))
    XCTAssertEqual(reloaded.lowSpaceMinutes, 60)
    XCTAssertEqual(UIInterfaceState(defaults: defaults).lowSpaceSeconds, 3600, "The drive rows read the same level")
    XCTAssertEqual(UIAlertPreferences.lowSpaceChoices.map(UISettingsAlertsPane.minutesTitle),
      ["15 minutes", "30 minutes", "1 hour", "2 hours"])

    // A turned-off event isn't notified; the panel doesn't follow the event switches.
    var session = UISessionSnapshot()
    session.drives = [UIDrive(name: "8TB", availableBytes: 500_000_000_000, totalBytes: 8_000_000_000_000, secondsLeft: 20 * 60)]
    let low = UIPresentationBuilder.problems(session)
    XCTAssertEqual(low.compactMap(\.alert?.event), [.driveLow])
    var tracker = UIAlertTracker()
    let off = tracker.plan(problems: low, live: false, notifications: true, panel: true, sound: false,
      timeSensitiveEntitled: false, events: reloaded.events)
    XCTAssertTrue(off.post.isEmpty)
    var fresh = UIAlertTracker()
    XCTAssertEqual(fresh.plan(problems: low, live: false, notifications: true, panel: true, sound: false,
      timeSensitiveEntitled: false).post.count, 1)

    var drive = UIDrive(name: "8TB", availableBytes: 1, totalBytes: 2, secondsLeft: 45 * 60)
    XCTAssertFalse(UIPresentationBuilder.isLow(drive))
    drive.lowSeconds = 3600
    XCTAssertTrue(UIPresentationBuilder.isLow(drive))
  }

  func testPermissionIsReadFromMacOS() {
    let allowed = UIUserNotifications.permission(status: .authorized, style: .banner, timeSensitive: .enabled)
    XCTAssertEqual(allowed, UIAlertPermission(status: .allowed, banners: true, timeSensitive: true))
    XCTAssertEqual(UIUserNotifications.permission(status: .denied, style: .none, timeSensitive: .disabled).status, .denied)
    XCTAssertEqual(UIUserNotifications.permission(status: .notDetermined, style: .none, timeSensitive: .notSupported).status,
      .notDetermined)
    XCTAssertEqual(UIUserNotifications.permission(status: .provisional, style: .none, timeSensitive: .disabled).status,
      .notDetermined, "Quiet delivery can't reach anyone live, so Settings still offers Turn On Alerts")
  }

  // MARK: Switching

  func testTranscriptAssistedRunsAsLowLatencyUntilASourceExists() throws {
    var settings = NaturalTalkingHeadSettings(mode: .transcriptAssisted)
    settings.normalizeForRuntime()
    XCTAssertFalse(NaturalTalkingHeadSettings.transcriptSourceAvailable)
    XCTAssertEqual(settings.mode, .lowLatency, "Nothing feeds a transcript, so the director never waits for one (B14)")
    let saved = try JSONDecoder().decode(NaturalTalkingHeadSettings.self,
      from: JSONEncoder().encode(NaturalTalkingHeadSettings(mode: .transcriptAssisted)))
    XCTAssertEqual(saved.mode, .transcriptAssisted, "The saved choice is left alone for when a source exists")
  }
}
