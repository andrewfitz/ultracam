import CoreMedia
import CoreVideo
import Foundation
import MonitorKitAudio
import XCTest

/// The broadcast meters run off the DeckLink callback: the driver thread only
/// hands each packet to the tap's meter queue, recording takes every packet
/// and frame first, and a meter queue that falls behind coalesces (counted)
/// instead of delaying or dropping anything else.
extension DeckLinkChecks {
  private static let meterFrames = 1600

  private static func stereoPacket(_ value: Int32, frames: Int = meterFrames) -> Data {
    var samples = [Int32](repeating: 0, count: frames * 2)
    var index = 0
    while index < samples.count {
      samples[index] = index % 4 < 2 ? value : -value
      index += 1
    }
    return samples.withUnsafeBytes { Data($0) }
  }

  private static func ingest(_ tap: AudioMeterTap, _ packet: Data, frames: Int = meterFrames) {
    tap.ingest(samples: packet, sampleFrames: UInt64(frames), channels: 2,
      bytesPerSample: EmbeddedAudioFormat.sourceBytesPerSample)
  }

  /// A blocked meter queue: the hand-off returns at once, the meter has
  /// processed nothing, a full ring coalesces (counted), and once the queue
  /// runs every queued packet is metered in order.
  @objc func testMeteringRunsOnItsOwnQueueAndCoalescesWhenBehind() {
    let tap = AudioMeterTap(packetCapacity: 8)
    let meter = tap.attach()
    defer { tap.detach() }
    let gate = DispatchSemaphore(value: 0)
    let blocked = DispatchSemaphore(value: 0)
    tap.meterQueue.async { blocked.signal(); gate.wait() }
    blocked.wait()
    let packet = Self.stereoPacket(1 << 28)
    let began = ProcessInfo.processInfo.systemUptime
    var handed = 0
    while handed < 11 {
      Self.ingest(tap, packet)
      handed += 1
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    var counters = tap.counters
    XCTAssertEqual(counters.metered, 0, "No metering may run on the ingesting thread")
    XCTAssertEqual(tap.queuedPackets, 8)
    XCTAssertEqual(counters.coalesced, 3, "A full ring leaves the newest packets out of the meters, counted")
    XCTAssertEqual(counters.maxQueued, 8)
    XCTAssertLessThan(elapsed, 0.05, "The hand-off never waits for the meter queue")
    gate.signal()
    tap.waitUntilMetered()
    counters = tap.counters
    XCTAssertEqual(counters.metered, 8)
    XCTAssertEqual(tap.queuedPackets, 0)
    Self.ingest(tap, packet)
    tap.waitUntilMetered()
    XCTAssertEqual(tap.counters.metered, 9, "The packet after a coalesced run is metered")
    XCTAssertEqual(tap.counters.stale, 0)
    XCTAssertEqual(tap.counters.overlapped, 0)
    meter.flush()
    XCTAssertEqual(meter.snapshot().frameCount, UInt64(9 * Self.meterFrames))
  }

  /// The tap meters exactly what a meter fed directly reads, and a packet a
  /// previous session left in the ring never reaches the next session's meter.
  @objc func testHandOffMetersExactlyAndKeepsSessionsApart() throws {
    let tap = AudioMeterTap()
    let loud = Self.stereoPacket(Int32.max / 2)
    let quiet = Self.stereoPacket(1 << 20)
    let first = tap.attach()
    var index = 0
    while index < 20 {
      Self.ingest(tap, index % 2 == 0 ? loud : quiet)
      index += 1
    }
    tap.waitUntilMetered()
    first.flush()
    let reference = try AudioMeter(configuration: AudioMeterTap.configuration)
    index = 0
    while index < 20 {
      (index % 2 == 0 ? loud : quiet).withUnsafeBytes { raw in
        reference.process(interleaved: raw.baseAddress!.assumingMemoryBound(to: Int32.self),
          frameCount: Self.meterFrames, frameStride: 2)
      }
      index += 1
    }
    reference.flush()
    let tapped = first.snapshot()
    let direct = reference.snapshot()
    XCTAssertEqual(tapped.frameCount, direct.frameCount)
    XCTAssertEqual(tapped.loudness, direct.loudness)
    XCTAssertEqual(tapped.channels[0], direct.channels[0])
    XCTAssertEqual(tapped.channels[1], direct.channels[1])

    // Packets still queued when the meters close and open again belong to the
    // session they were handed over in: the old one's meter, or none once the
    // meter queue has moved past that session. Never a later session's meter.
    let gate = DispatchSemaphore(value: 0)
    let blocked = DispatchSemaphore(value: 0)
    tap.meterQueue.async { blocked.signal(); gate.wait() }
    blocked.wait()
    Self.ingest(tap, loud)  // Session 1, still current for the meter queue: metered into `first`.
    tap.detach()
    let second = tap.attach()
    Self.ingest(tap, loud)  // Session 2, already passed when it is drained: stale.
    tap.detach()
    let third = tap.attach()
    defer { tap.detach() }
    Self.ingest(tap, quiet)  // Session 3.
    gate.signal()
    tap.waitUntilMetered()
    first.flush()
    second.flush()
    third.flush()
    XCTAssertEqual(tap.counters.stale, 1, "A packet of a session the meter queue has passed is dropped, counted")
    XCTAssertEqual(first.snapshot().frameCount, UInt64(21 * Self.meterFrames),
      "A packet goes to the meter of the session it was handed over in")
    XCTAssertEqual(second.snapshot().frameCount, 0)
    XCTAssertEqual(third.snapshot().frameCount, UInt64(Self.meterFrames),
      "The new session meters only its own packet")
    XCTAssertEqual(third.snapshot().channels[0].truePeakMax, fresh(quiet).channels[0].truePeakMax)
  }

  private func fresh(_ packet: Data) -> AudioMeterSnapshot {
    guard let meter = try? AudioMeter(configuration: AudioMeterTap.configuration) else { return AudioMeterSnapshot() }
    packet.withUnsafeBytes { raw in
      meter.process(interleaved: raw.baseAddress!.assumingMemoryBound(to: Int32.self),
        frameCount: Self.meterFrames, frameStride: 2)
    }
    meter.flush()
    return meter.snapshot()
  }

  private final class DriverHarness: @unchecked Sendable {
    let lock = NSLock()
    var frames: ((CVPixelBuffer, CMTime, CMTime, Bool) -> Void)?
    var audio: ((CaptureRawAudio) -> Void)?
    var recordedVideo: [CMTime] = []
    var recordedAudio: [CMTime] = []
    var recordedAudioBytes = 0
    var services: CaptureServices {
      var services = CaptureServices(
        start: { _, _, _, _ in }, stop: {}, connect: { _, _ in }, disconnect: {}, send: { _ in true })
      services.startAutomatic = { _, _, _ in }
      services.startAutomaticWithRawAudio = { _, frames, audio, _ in
        self.lock.withLock {
          self.frames = frames
          self.audio = audio
        }
      }
      return services
    }
    var callbacks: SourceRecordingCallbackAdapter.Callbacks {
      SourceRecordingCallbackAdapter.Callbacks(
        video: { _, pts, _, _ in self.lock.withLock { self.recordedVideo.append(pts) }; return true },
        audio: { _ in true },
        rawAudio: { samples, _, pts, _, _ in
          self.lock.withLock {
            self.recordedAudio.append(pts)
            self.recordedAudioBytes += samples.count
          }
          return true
        })
    }
  }

  /// The capture's own path, with the meters shown and their queue stalled:
  /// recording still gets every frame and every packet at its exact source
  /// time, in callback order, while the meters only coalesce.
  @objc func testRecordingGetsEveryPacketAndFrameWhileTheMetersStall() throws {
    let image = try syntheticRamp()
    let harness = DriverHarness()
    let controller = CaptureController(services: harness.services, previewRenderer: nil)
    defer {
      controller.onUpdate = nil
      controller.stop()
    }
    let feed = FeedID(rawValue: "meter-hand-off")
    let started = expectation(description: "capture started")
    controller.onUpdate = { if $0.message.hasPrefix("Waiting") { started.fulfill() } }
    controller.start(feedID: feed, deviceID: "synthetic",
      configuration: PipelineConfiguration(downscale: false, convertTo420: false),
      pipelineEnabled: false, previewEnabled: false)
    wait(for: [started], timeout: 3)
    controller.onUpdate = nil
    controller.setRecordingCallbacks(feedID: feed, callbacks: harness.callbacks)
    let tap = controller.audioMeterTap
    let meter = tap.attach()
    defer { tap.detach() }
    let gate = DispatchSemaphore(value: 0)
    let blocked = DispatchSemaphore(value: 0)
    tap.meterQueue.async { blocked.signal(); gate.wait() }
    blocked.wait()

    let (frames, audio) = harness.lock.withLock { (harness.frames, harness.audio) }
    let deliver = try XCTUnwrap(frames)
    let report = try XCTUnwrap(audio)
    let callbacks = 200
    let duration = VideoContract.fastDuration
    let samplesPerFrame = Int64(800)
    let packet = Self.stereoPacket(1 << 26, frames: Int(samplesPerFrame))
    let driver = DispatchQueue(label: "synthetic-driver", qos: .userInteractive)
    let done = DispatchSemaphore(value: 0)
    driver.async {
      var index: Int64 = 0
      while index < Int64(callbacks) {
        // The backend's order within one DeckLink callback: the frame, then its audio.
        deliver(image, CMTimeMultiply(duration, multiplier: Int32(index)), duration, true)
        report(CaptureRawAudio(samples: packet, packetTime: CMTime(value: index * samplesPerFrame, timescale: 48_000),
          sampleFrames: UInt64(samplesPerFrame), channels: 2, bytesPerSample: EmbeddedAudioFormat.sourceBytesPerSample))
        index += 1
      }
      done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "The driver thread waited on the stalled meters")
    let recorded = harness.lock.withLock { (harness.recordedVideo, harness.recordedAudio, harness.recordedAudioBytes) }
    var expectedVideo: [CMTime] = []
    var expectedAudio: [CMTime] = []
    var index: Int64 = 0
    while index < Int64(callbacks) {
      expectedVideo.append(CMTimeMultiply(duration, multiplier: Int32(index)))
      expectedAudio.append(CMTime(value: index * samplesPerFrame, timescale: 48_000))
      index += 1
    }
    XCTAssertEqual(recorded.0, expectedVideo, "Recording must take every frame while the meters stall")
    XCTAssertEqual(recorded.1, expectedAudio, "Recording must take every packet, at its source time, in order")
    XCTAssertEqual(recorded.2, callbacks * packet.count)
    let stalled = tap.counters
    XCTAssertEqual(stalled.metered, 0)
    XCTAssertEqual(stalled.coalesced, 0, "The default ring holds over a minute of callbacks: a stall loses no audio")
    XCTAssertEqual(tap.queuedPackets, callbacks)

    gate.signal()
    tap.waitUntilMetered()
    XCTAssertEqual(tap.counters.metered, UInt64(callbacks), "Every packet the stall held back is metered")
    meter.flush()
    XCTAssertEqual(meter.snapshot().frameCount, UInt64(callbacks) * UInt64(samplesPerFrame))
  }

  /// The default ring is sized so a meter queue stall cannot realistically
  /// fill it: over a minute of DeckLink callbacks at the highest frame rate.
  @objc func testDefaultMeterRingHoldsOverAMinuteOfCallbacks() {
    let fastest = VideoContract.fastDuration.seconds
    XCTAssertGreaterThanOrEqual(Double(AudioMeterTap.defaultPacketCapacity) * fastest, 60)
  }

  private static func waitForUpdate(_ test: XCTestCase, _ controller: CaptureController, _ label: String,
    trigger: () -> Void, _ match: @escaping @Sendable (CaptureUpdate) -> Bool) {
    let seen = test.expectation(description: label)
    seen.assertForOverFulfill = false
    controller.onUpdate = { update in
      if match(update) { seen.fulfill() }
    }
    trigger()
    test.wait(for: [seen], timeout: 3)
    controller.onUpdate = nil
  }

  /// Fills the controller tap's ring with its meter queue blocked, so exactly
  /// `extra` packets coalesce, then lets the queue drain.
  private static func coalesce(_ tap: AudioMeterTap, extra: Int) {
    let gate = DispatchSemaphore(value: 0)
    let blocked = DispatchSemaphore(value: 0)
    tap.meterQueue.async { blocked.signal(); gate.wait() }
    blocked.wait()
    let packet = stereoPacket(1 << 24, frames: 16)
    var index = 0
    while index < AudioMeterTap.defaultPacketCapacity + extra {
      ingest(tap, packet, frames: 16)
      index += 1
    }
    gate.signal()
    tap.waitUntilMetered()
  }

  /// `CaptureUpdate.audioMeterCoalesced` is this capture's count: a stopped
  /// capture reports none, and a new start begins again at zero, so one past
  /// stall never leaves a warning on later captures.
  @objc func testCoalescedMeterPacketsArePerCaptureAndZeroWhenStopped() throws {
    let harness = DriverHarness()
    let controller = CaptureController(services: harness.services, previewRenderer: nil)
    defer {
      controller.onUpdate = nil
      controller.stop()
    }
    let tap = controller.audioMeterTap
    tap.attach()
    defer { tap.detach() }
    let configuration = PipelineConfiguration(downscale: false, convertTo420: false)
    let start = {
      controller.start(feedID: FeedID(rawValue: "meter-coalesced"), deviceID: "synthetic",
        configuration: configuration, pipelineEnabled: false, previewEnabled: false)
    }
    Self.waitForUpdate(self, controller, "first start", trigger: start) { $0.message.hasPrefix("Waiting") }

    Self.coalesce(tap, extra: 5)
    XCTAssertEqual(tap.counters.coalesced, 5)
    Self.waitForUpdate(self, controller, "coalesced published",
      trigger: { controller.setPreviewEnabled(false) }) { $0.audioMeterCoalesced == 5 }

    Self.waitForUpdate(self, controller, "stopped", trigger: { controller.stop() }) {
      $0.message == "Stopped" && $0.audioMeterCoalesced == 0
    }

    Self.waitForUpdate(self, controller, "second start", trigger: start) {
      $0.message.hasPrefix("Waiting") && $0.audioMeterCoalesced == 0
    }
    XCTAssertEqual(tap.counters.coalesced, 5, "The tap's own count still covers its whole life")
    Self.waitForUpdate(self, controller, "fresh capture starts at zero",
      trigger: { controller.setPreviewEnabled(false) }) { $0.audioMeterCoalesced == 0 }

    Self.coalesce(tap, extra: 3)
    Self.waitForUpdate(self, controller, "the second capture's own count",
      trigger: { controller.setPreviewEnabled(false) }) { $0.audioMeterCoalesced == 3 }
  }

  /// Recording callbacks installed between one DeckLink callback's frame and
  /// its audio: the take starts on video. The split callback's audio, which
  /// precedes the take's first frame, is not recorded, so the writer's session
  /// (the earliest sample) starts at the first recorded frame instead of one
  /// frame earlier with no picture. Installing another feed's callbacks
  /// mid-take never holds back the running take's audio.
  @objc func testATakeArmedMidCallbackStartsOnItsFirstFrame() throws {
    let image = try syntheticRamp()
    let harness = DriverHarness()
    let other = DriverHarness()
    let controller = CaptureController(services: harness.services, previewRenderer: nil)
    defer {
      controller.onUpdate = nil
      controller.stop()
    }
    let feed = FeedID(rawValue: "take-start")
    Self.waitForUpdate(self, controller, "capture started", trigger: {
      controller.start(feedID: feed, deviceID: "synthetic",
        configuration: PipelineConfiguration(downscale: false, convertTo420: false),
        pipelineEnabled: false, previewEnabled: false)
    }) { $0.message.hasPrefix("Waiting") }
    let (frames, audio) = harness.lock.withLock { (harness.frames, harness.audio) }
    let deliver = try XCTUnwrap(frames)
    let report = try XCTUnwrap(audio)
    let duration = VideoContract.fastDuration
    let samplesPerFrame = Int64(800)
    let packet = Self.stereoPacket(1 << 26, frames: Int(samplesPerFrame))
    let video = { (index: Int64) in CMTimeMultiply(duration, multiplier: Int32(index)) }
    // Each packet starts with its callback's frame (59.94p packets alternate 800 and 801 samples).
    let audioTime = { (index: Int64) in CMTimeMultiply(duration, multiplier: Int32(index)) }
    let sound = { (index: Int64) in
      report(CaptureRawAudio(samples: packet, packetTime: audioTime(index), sampleFrames: UInt64(samplesPerFrame),
        channels: 2, bytesPerSample: EmbeddedAudioFormat.sourceBytesPerSample))
    }

    deliver(image, video(0), duration, true)
    controller.setRecordingCallbacks(feedID: feed, callbacks: harness.callbacks)
    sound(0)
    deliver(image, video(1), duration, true)
    sound(1)
    deliver(image, video(2), duration, true)
    controller.setRecordingCallbacks(feedID: FeedID(rawValue: "another-feed"), callbacks: other.callbacks)
    sound(2)
    deliver(image, video(3), duration, true)
    sound(3)

    var recorded = harness.lock.withLock { (harness.recordedVideo, harness.recordedAudio) }
    XCTAssertEqual(recorded.0, [video(1), video(2), video(3)])
    XCTAssertEqual(recorded.1, [audioTime(1), audioTime(2), audioTime(3)],
      "Audio before the take's first frame is left out; after it, every packet is recorded")
    let first = try XCTUnwrap(recorded.0.first)
    let sessionStart = CMTimeMinimum(first, try XCTUnwrap(recorded.1.first))
    XCTAssertEqual(sessionStart, first, "The take's session starts at its first recorded frame")
    XCTAssertTrue(other.lock.withLock { other.recordedVideo.isEmpty && other.recordedAudio.isEmpty })

    // A new take on the same feed, armed mid-callback again, starts on its own
    // first frame (frame 4 still went to the take before it).
    deliver(image, video(4), duration, true)
    controller.setRecordingCallbacks(feedID: feed, callbacks: nil)
    controller.setRecordingCallbacks(feedID: feed, callbacks: harness.callbacks)
    sound(4)
    deliver(image, video(5), duration, true)
    sound(5)
    recorded = harness.lock.withLock { (harness.recordedVideo, harness.recordedAudio) }
    XCTAssertEqual(recorded.0, [video(1), video(2), video(3), video(4), video(5)])
    XCTAssertEqual(recorded.1, [audioTime(1), audioTime(2), audioTime(3), audioTime(5)])
  }
}
