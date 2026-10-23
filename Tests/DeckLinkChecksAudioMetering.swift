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
    XCTAssertEqual(stalled.coalesced, UInt64(callbacks - AudioMeterTap.defaultPacketCapacity))
    XCTAssertEqual(tap.queuedPackets, AudioMeterTap.defaultPacketCapacity)

    gate.signal()
    tap.waitUntilMetered()
    XCTAssertEqual(tap.counters.metered, UInt64(AudioMeterTap.defaultPacketCapacity))
    meter.flush()
    XCTAssertEqual(meter.snapshot().frameCount, UInt64(AudioMeterTap.defaultPacketCapacity) * UInt64(samplesPerFrame))

    // The coalescing reaches the capture's diagnostics.
    let published = expectation(description: "diagnostics published")
    controller.onUpdate = { update in
      if update.audioMeterCoalesced == stalled.coalesced { published.fulfill() }
    }
    controller.setPreviewEnabled(false)
    wait(for: [published], timeout: 3)
  }
}
