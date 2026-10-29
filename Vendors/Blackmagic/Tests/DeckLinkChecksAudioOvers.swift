import Foundation
import MonitorKitAudio
import XCTest

/// The meter tap's over watch, its per-take summary, and the readings that
/// stand in for a camera without a live meter.
extension DeckLinkChecks {
  private static let overFrames = 1600

  /// A stereo Int32 packet at fs/4 with a 45° phase: every sample sits at
  /// 0.707 of the waveform's peak. `sampleDBFS` sets the samples, so the true
  /// peak between them is 3 dB higher.
  private static func quarterRatePacket(sampleDBFS: Double, frames: Int = overFrames) -> Data {
    let value = Int32(pow(10, sampleDBFS / 20) * Double(Int32.max))
    var samples = [Int32](repeating: 0, count: frames * 2)
    for i in 0..<frames {
      // sin(π/4 + iπ/2): +, +, −, −.
      let sign: Int32 = i % 4 < 2 ? 1 : -1
      samples[2 * i] = sign * value
      samples[2 * i + 1] = sign * value
    }
    return samples.withUnsafeBytes { Data($0) }
  }

  private static func feedPackets(_ tap: AudioMeterTap, _ packet: Data, seconds: Double) {
    let count = Int((seconds * EmbeddedAudioFormat.sampleRate / Double(overFrames)).rounded(.up))
    for _ in 0..<count {
      tap.ingest(samples: packet, sampleFrames: UInt64(overFrames), channels: 2,
        bytesPerSample: EmbeddedAudioFormat.sourceBytesPerSample)
    }
    tap.waitUntilMetered()
  }

  /// A take meters without a view, counts each over once (a burst is one
  /// over; two bursts two seconds apart are two), latches through silence,
  /// and reports its loudness, maximum true peak and overs at the end.
  @objc func testTakeCountsOversAndSummarizesLoudness() {
    let tap = AudioMeterTap()
    XCTAssertFalse(tap.isMetering)
    tap.setCameraName("Camera 1")
    tap.setTimecodeSource { "01:00:00:00" }
    tap.beginTake()
    XCTAssertTrue(tap.isMetering, "a take meters with no view showing the meter")
    let quiet = Self.quarterRatePacket(sampleDBFS: -20)
    let loud = Self.quarterRatePacket(sampleDBFS: -0.5)
    let silence = Data(count: Self.overFrames * 2 * EmbeddedAudioFormat.sourceBytesPerSample)
    Self.feedPackets(tap, quiet, seconds: 1)
    XCTAssertEqual(tap.overCount, 0)
    Self.feedPackets(tap, loud, seconds: 0.2)
    XCTAssertEqual(tap.overCount, 1, "a true-peak over with no clipped sample")
    let snapshot = tap.meter?.snapshot() ?? AudioMeterSnapshot()
    XCTAssertEqual(snapshot.channels[0].clipCount, 0)
    XCTAssertGreaterThan(snapshot.channels[0].truePeakMax, -1)
    Self.feedPackets(tap, silence, seconds: 2)
    XCTAssertTrue(tap.meter?.snapshot().isOver() ?? false, "the latch stays lit through silence")
    Self.feedPackets(tap, loud, seconds: 0.2)
    XCTAssertEqual(tap.overCount, 2, "a second burst after a gap is a second over")
    Self.feedPackets(tap, quiet, seconds: 1)
    guard let summary = tap.endTake() else { return XCTFail("no take summary") }
    XCTAssertFalse(tap.isMetering, "the take's metering ends with it")
    XCTAssertEqual(summary.overs, 2)
    XCTAssertGreaterThan(summary.maximumTruePeak, -1)
    XCTAssertTrue(summary.integrated.isFinite)
    XCTAssertGreaterThan(summary.duration, 4)
    XCTAssertTrue(summary.needsAttention)
    XCTAssertNil(tap.endTake(), "no take running")
    // No view showed the meter: the log still names the camera and the capture's timecode.
    XCTAssertTrue(tap.lastOverReport?.hasPrefix("Audio over on Camera 1, L: ") ?? false, tap.lastOverReport ?? "no report")
    XCTAssertTrue(tap.lastOverReport?.contains("at 01:00:00:00") ?? false, tap.lastOverReport ?? "no report")
  }

  /// Clicking OVER or Reset Loudness on a view during a take resets what the
  /// view shows, never the take's own numbers.
  @objc func testViewResetsLeaveTheTakeAlone() {
    let tap = AudioMeterTap()
    let view = tap.attach()
    defer { tap.detach() }
    tap.beginTake()
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -0.5), seconds: 0.5)
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -20), seconds: 0.1)
    XCTAssertTrue(view.snapshot().isOver())
    view.resetPeaks()
    view.resetLoudness()
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -20), seconds: 1)
    XCTAssertFalse(view.snapshot().isOver(), "the view's latch cleared")
    XCTAssertEqual(tap.takeSummarySoFar()?.overs, 1, "the take's count while it runs")
    guard let summary = tap.endTake() else { return XCTFail("no take summary") }
    XCTAssertEqual(summary.overs, 1)
    XCTAssertGreaterThan(summary.maximumTruePeak, -1, "the take keeps its Max TP")
    XCTAssertGreaterThan(summary.duration, 1.5, "the take keeps its loudness from the start")
    XCTAssertTrue(summary.needsAttention)
    XCTAssertTrue(tap.isMetering, "the view still meters")
  }

  /// A paused take leaves the paused audio out of its loudness, Max TP and overs.
  @objc func testPausedTakeLeavesThePausedAudioOut() {
    let tap = AudioMeterTap()
    tap.beginTake()
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -20), seconds: 1)
    tap.pauseTake(true)
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -0.5), seconds: 0.5)
    tap.pauseTake(false)
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -20), seconds: 1)
    guard let summary = tap.endTake() else { return XCTFail("no take summary") }
    XCTAssertEqual(summary.overs, 0)
    XCTAssertEqual(summary.maximumTruePeak, -17, accuracy: 0.5)
    XCTAssertLessThan(summary.duration, 2.3, "about 2 s measured, not the paused half second")
    XCTAssertFalse(summary.needsAttention)
    XCTAssertFalse(tap.isMetering)
  }

  /// A new take starts on a new meter; restarting a take holds one viewer, not two.
  @objc func testTakeRestartHoldsOneViewer() {
    let tap = AudioMeterTap()
    tap.beginTake()
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -0.5), seconds: 0.3)
    tap.beginTake()
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -20), seconds: 0.5)
    XCTAssertEqual(tap.endTake()?.overs, 0, "the restarted take is its own")
    XCTAssertFalse(tap.isMetering, "one endTake releases a restarted take")
  }

  /// Overs the rate limit holds back are reported a second later even when no
  /// over follows them.
  @objc func testHeldBackOversAreReportedLater() {
    let tap = AudioMeterTap()
    tap.setCameraName("Camera 2")
    tap.setTimecodeSource { "10:00:00:00" }
    tap.attach()
    defer { tap.detach() }
    let loud = Self.quarterRatePacket(sampleDBFS: -0.5)
    let silence = Data(count: Self.overFrames * 2 * EmbeddedAudioFormat.sourceBytesPerSample)
    // Three bursts two seconds of audio apart, metered in far less than a second.
    for _ in 0..<3 {
      Self.feedPackets(tap, loud, seconds: 0.1)
      Self.feedPackets(tap, silence, seconds: 2)
    }
    XCTAssertEqual(tap.overCount, 3)
    XCTAssertTrue(tap.lastOverReport?.hasPrefix("Audio over on Camera 2") ?? false)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, tap.lastOverReport?.hasPrefix("Audio overs on") != true {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(tap.lastOverReport, "Audio overs on Camera 2: 2 more since the last report, the last at 10:00:00:00")
  }

  @objc func testOverLogLimiterNeverLosesACount() {
    var limiter = AudioMeterTap.OverLogLimiter()
    let second = AudioMeterTap.OverLogLimiter.interval
    XCTAssertEqual(limiter.offer(now: 10, timecode: "a"), 0, "the first over logs")
    XCTAssertNil(limiter.offer(now: 20, timecode: "b"))
    XCTAssertNil(limiter.offer(now: 30, timecode: "c"))
    XCTAssertNil(limiter.flush(now: 40).map(\.count), "too soon to flush")
    XCTAssertEqual(limiter.nanosecondsUntilFlush(now: 40), second - 30)
    XCTAssertEqual(limiter.offer(now: 10 + second, timecode: "d"), 2, "the next line counts the two held back")
    XCTAssertNil(limiter.offer(now: 20 + second, timecode: "e"))
    let held = limiter.flush(now: 10 + 2 * second)
    XCTAssertEqual(held?.count, 1)
    XCTAssertEqual(held?.timecode, "e")
    XCTAssertEqual(limiter.suppressed, 0)
    XCTAssertNil(limiter.flush(now: 10 + 4 * second), "nothing left to flush")
  }

  /// A capture restart marks the gap: the true-peak interpolator starts on the
  /// new stream instead of ringing across a step that was never in the audio.
  @objc func testCaptureRestartGapDoesNotInterpolateAcrossTheJump() {
    func dc(_ value: Double) -> Data {
      let sample = Int32(value * Double(Int32.max))
      return [Int32](repeating: sample, count: Self.overFrames * 2).withUnsafeBytes { Data($0) }
    }
    func maximum(gap: Bool) -> Double {
      let tap = AudioMeterTap()
      let meter = tap.attach()
      defer { tap.detach() }
      Self.feedPackets(tap, dc(0.5), seconds: 0.2)
      if gap { tap.noteGap() }
      Self.feedPackets(tap, dc(-0.5), seconds: 0.2)
      return Double(meter.snapshot().channels[0].truePeakMax)
    }
    let marked = maximum(gap: true)
    XCTAssertEqual(marked, 20 * log10(0.5), accuracy: 0.2, "the restart's step adds no peak")
    XCTAssertGreaterThan(maximum(gap: false), marked + 0.3, "control: an unmarked step rings past the level")
  }

  /// A take started while a view meters starts the view's readings over too:
  /// the take's maximum and loudness are its own, and the view keeps metering after it.
  @objc func testTakeResetsASharedMeter() {
    let tap = AudioMeterTap()
    let meter = tap.attach()
    defer { tap.detach() }
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -0.5), seconds: 0.5)
    XCTAssertTrue(meter.snapshot().isOver())
    // The true-peak interpolator reads about six samples behind its input, so a
    // take that starts on the last loud sample would still see them. Start it after.
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -20), seconds: 0.1)
    tap.beginTake()
    XCTAssertFalse(meter.snapshot().isOver(), "the take starts the maxima over")
    Self.feedPackets(tap, Self.quarterRatePacket(sampleDBFS: -20), seconds: 1)
    let summary = tap.endTake()
    XCTAssertEqual(summary?.overs, 0)
    XCTAssertEqual(summary?.maximumTruePeak ?? 0, -17, accuracy: 0.5, "−20 dBFS samples, a −17 dBTP waveform (Annex 2 reads within a few tenths)")
    XCTAssertTrue(tap.isMetering, "the view still meters")
  }

  @objc func testOverLogMessageAndTakeNote() {
    XCTAssertEqual(AudioMeterTap.heldOversMessage(camera: nil, count: 1, lastTimecode: "—"),
      "Audio overs on a camera: 1 more since the last report")
    XCTAssertEqual(
      AudioMeterTap.overMessage(camera: "Camera 1", channel: 0, channels: 2, level: 0.44, clips: 3,
        timecode: "01:02:03:04", suppressed: 2),
      "Audio over on Camera 1, L: +0.4 dBTP, 3 clipped samples, at 01:02:03:04 (2 more since the last report)")
    XCTAssertEqual(
      AudioMeterTap.overMessage(camera: nil, channel: 4, channels: 8, level: -0.96, clips: 0, timecode: "—", suppressed: 0),
      "Audio over on a camera, channel 5: −1.0 dBTP")
    let take = AudioTakeSummary(integrated: -23.44, maximumTruePeak: -2.06, overs: 0, duration: 60)
    XCTAssertEqual(take.note, "Audio −23.4 LUFS · max −2.1 dBTP · no overs")
    XCTAssertFalse(take.needsAttention)
    let hot = AudioTakeSummary(integrated: -.infinity, maximumTruePeak: 0.3, overs: 1, duration: 1)
    XCTAssertEqual(hot.note, "Audio no programme loudness · max +0.3 dBTP · 1 over")
    XCTAssertTrue(hot.needsAttention)
  }

  /// A camera without a live meter shows its status peaks on the same scale.
  @objc func testStatusPeaksStandInForTheMeter() {
    let s = AudioMeterTap.snapshot(statusPeaks: [0.5, 0])
    XCTAssertEqual(s.channelCount, 2)
    XCTAssertEqual(Double(s.channels[0].truePeak), 20 * log10(0.5), accuracy: 1e-5)
    XCTAssertEqual(s.channels[0].truePeakMax, s.channels[0].truePeak)
    XCTAssertEqual(s.channels[1].truePeak, -.infinity, "silence")
    XCTAssertFalse(s.isOver())
    XCTAssertTrue(AudioMeterTap.snapshot(statusPeaks: [1, 0.1]).isOver(), "a full-scale peak lights the latch")
    XCTAssertNotEqual(s.sequence, AudioMeterTap.snapshot(statusPeaks: [0.4, 0]).sequence)
    XCTAssertEqual(AudioMeterTap.configuration.meters, [.samplePeak, .truePeak, .loudness, .correlation])
    XCTAssertEqual(AudioMeterTap.takeConfiguration.meters, [.samplePeak, .truePeak, .loudness])
    XCTAssertNotEqual(AudioMeterTap().identity, AudioMeterTap().identity, "views key on a tap's identity")
  }
}
