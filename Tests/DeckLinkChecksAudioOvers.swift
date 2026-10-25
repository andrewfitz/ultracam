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
    tap.setLogContext(camera: "Camera 1", timecode: "01:00:00:00")
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
  }
}
