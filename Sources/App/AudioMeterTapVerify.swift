#if UI_VERIFY
import Foundation
import MonitorKitAudio
import Synchronization

/// AudioMeterTap's metering sessions, against the real MonitorKitAudio: a
/// session that starts after a gap reads exactly like a meter that never ran
/// (no stale filter history: no false true-peak over, no loudness in silence),
/// viewers share a session, and a driver thread handing packets over through
/// repeated sessions never waits for the meter queue, which meters each
/// session's packets into that session's meter only.
@MainActor enum AudioMeterTapVerify {
  static let frames = 1600

  /// One stereo Int32 packet of a 1 kHz sine at `dBFS`, from `phase` (radians).
  static func sine(dBFS: Double, phase: Double, frames: Int = frames) -> Data {
    let amplitude = pow(10, dBFS / 20) * Double(Int32.max)
    var samples = [Int32](repeating: 0, count: frames * 2)
    for i in 0..<frames {
      let value = Int32(amplitude * sin(phase + 2 * Double.pi * 1000 * Double(i) / EmbeddedAudioFormat.sampleRate))
      samples[2 * i] = value
      samples[2 * i + 1] = value
    }
    return samples.withUnsafeBytes { Data($0) }
  }

  static let silence = Data(count: frames * 2 * EmbeddedAudioFormat.sourceBytesPerSample)

  /// Hands `times` packets over (fewer than the ring holds), then waits for the meter queue.
  static func feed(_ tap: AudioMeterTap, _ packet: Data, times: Int) {
    for _ in 0..<times {
      tap.ingest(samples: packet, sampleFrames: UInt64(frames), channels: 2,
        bytesPerSample: EmbeddedAudioFormat.sourceBytesPerSample)
    }
    tap.waitUntilMetered()
  }

  /// A meter that never ran, fed only `packets`.
  static func fresh(_ packets: [Data]) -> AudioMeterSnapshot {
    guard let meter = try? AudioMeter(configuration: AudioMeterTap.configuration) else { return AudioMeterSnapshot() }
    for packet in packets {
      packet.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        meter.process(interleaved: base.assumingMemoryBound(to: Int32.self), frameCount: frames, frameStride: 2)
      }
    }
    meter.flush()
    return meter.snapshot()
  }

  /// Every reading but the sequence equal (channel levels and loudness).
  static func same(_ a: AudioMeterSnapshot, _ b: AudioMeterSnapshot) -> Bool {
    a.channelCount == b.channelCount && a.frameCount == b.frameCount && a.loudness == b.loudness
      && (0..<a.channelCount).allSatisfy { a.channels[$0] == b.channels[$0] }
  }

  static func describe(_ s: AudioMeterSnapshot) -> String {
    "Max TP \(s.channels[0].truePeakMax) TP hold \(s.channels[0].truePeakHold) M \(s.loudness.momentary) "
      + "I \(s.loudness.integrated) frames \(s.frameCount)"
  }

  static func run(verifier: Verifier) {
    reopen(verifier: verifier)
    sharing(verifier: verifier)
    concurrent(verifier: verifier)
  }

  /// Loud programme, meters hidden, shown again: the new session is a fresh meter's.
  private static func reopen(verifier: Verifier) {
    let loud = sine(dBFS: -1, phase: 0)
    // This offline reference comparison submits just over two seconds at once.
    let tap = AudioMeterTap(maxBufferedSeconds: 3)
    verifier.check("audio meter tap: no meter before the first viewer", tap.meter == nil && !tap.isMetering)
    feed(tap, loud, times: 3)
    verifier.check("audio meter tap: nothing metered without a viewer", tap.counters.metered == 0)

    let first = tap.attach()
    feed(tap, loud, times: 30)
    tap.detach()
    first.flush()
    let closed = first.snapshot()
    feed(tap, loud, times: 3)
    verifier.check("audio meter tap: a hidden meter stops metering",
      !tap.isMetering && tap.counters.metered == 30 && same(first.snapshot(), closed))

    // Reopened on digital silence (the audit's case: a false over and loudness from stale history).
    let second = tap.attach()
    verifier.check("audio meter tap: showing again starts a new meter", second !== first && tap.meter === second)
    feed(tap, silence, times: 30)
    second.flush()
    let quiet = second.snapshot()
    let freshQuiet = fresh(Array(repeating: silence, count: 30))
    verifier.check("audio meter tap: reopened on silence reads as a meter that never ran", same(quiet, freshQuiet),
      "tap \(describe(quiet)); fresh \(describe(freshQuiet))")
    verifier.check("audio meter tap: reopened on silence shows no true peak and no loudness",
      quiet.channels[0].truePeakMax == -.infinity && quiet.channels[0].truePeakHold == -.infinity
        && quiet.loudness.integrated == -.infinity, describe(quiet))
    verifier.check("audio meter tap: the previous session's meter keeps its readings", same(first.snapshot(), closed))
    tap.detach()

    // Reopened on programme that jumps in phase from where the last session ended.
    tap.attach()
    feed(tap, loud, times: 2)
    tap.detach()
    let jump = sine(dBFS: -1, phase: Double.pi * 0.7)
    let quieter = sine(dBFS: -30, phase: 0.3)
    let fourth = tap.attach()
    feed(tap, jump, times: 1)
    feed(tap, quieter, times: 60)
    fourth.flush()
    let programme = fourth.snapshot()
    let freshProgramme = fresh([jump] + Array(repeating: quieter, count: 60))
    verifier.check("audio meter tap: reopened on programme reads as a meter that never ran",
      same(programme, freshProgramme), "tap \(describe(programme)); fresh \(describe(freshProgramme))")
    tap.detach()
    verifier.check("audio meter tap: sessions one after another leave nothing stale or coalesced",
      tap.counters.stale == 0 && tap.counters.coalesced == 0, "\(tap.counters)")
  }

  /// A second viewer shares the session; an unpaired detach cannot end it.
  private static func sharing(verifier: Verifier) {
    let tap = AudioMeterTap()
    let packet = sine(dBFS: -20, phase: 0)
    let a = tap.attach()
    feed(tap, packet, times: 10)
    let b = tap.attach()
    feed(tap, packet, times: 10)
    tap.detach()
    feed(tap, packet, times: 10)
    a.flush()
    verifier.check("audio meter tap: a second viewer shares the session",
      a === b && tap.isMetering && a.snapshot().frameCount == UInt64(30 * frames), describe(a.snapshot()))
    tap.detach()
    tap.detach()
    verifier.check("audio meter tap: an unpaired detach stays at zero", !tap.isMetering)
    let c = tap.attach()
    verifier.check("audio meter tap: the next viewer after zero starts a new session", c !== a && tap.isMetering)
    tap.detach()
  }

  private final class Stop: Sendable {
    let requested = Atomic<Bool>(false)
    let attempted = Atomic<UInt64>(0)
    let done = DispatchSemaphore(value: 0)
  }

  /// A driver thread handing packets over without pause while views come and
  /// go. Long packets (5 s each) keep the meter queue far behind, so the ring
  /// stays full: the driver never waits (the meters coalesce, counted), and
  /// the meter queue holds the meter it is metering into, so no session start
  /// ever releases a meter in use.
  private static func concurrent(verifier: Verifier) {
    // Deliberately enlarge time/byte budgets to isolate slot saturation with
    // synthetic five-second packets; production defaults bound live retention.
    let capacity = 128
    let tap = AudioMeterTap(packetCapacity: capacity, maxBufferedSeconds: 700,
      maxBufferedBytes: 256 * 1024 * 1024)
    let sampleFrames = 240_000
    let packet = sine(dBFS: -6, phase: 0, frames: sampleFrames)
    let stop = Stop()
    // Keep demand continuously active, so every attempted packet must appear
    // exactly once in a delivery or loss counter. Declarations exercise real
    // session replacement without an unaccountable no-viewer interval.
    let attachment = AudioMeterTap.Attachment(tap: tap)
    let driver = Thread {
      while !stop.requested.load(ordering: .relaxed) {
        stop.attempted.add(1, ordering: .relaxed)
        tap.ingest(samples: packet, sampleFrames: UInt64(sampleFrames), channels: 2,
          bytesPerSample: EmbeddedAudioFormat.sourceBytesPerSample)
      }
      stop.done.signal()
    }
    driver.start()
    for index in 0..<300 {
      do {
        let format = try SourceAudioFormat(sampleRate: index.isMultiple(of: 2) ? 48_000 : 48_001,
          channels: 2, sample: .int32, interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
        try tap.configure(format: format)
      } catch {
        verifier.check("audio meter tap: synthetic declaration is admitted", false, "\(error)")
      }
      // A second view still shares demand through each declaration.
      tap.attach()
      tap.detach()
      usleep(200)
    }
    usleep(20_000)
    stop.requested.store(true, ordering: .relaxed)
    let stopped = stop.done.wait(timeout: .now() + 3) == .success
    verifier.check("audio meter tap: the driver never waits for session retirement", stopped)
    guard stopped else { return }
    tap.waitUntilMetered()
    let counters = tap.counters
    let attempted = stop.attempted.load(ordering: .relaxed)
    let accounted = counters.metered + counters.stale + counters.coalesced + counters.overlapped + counters.rejected
    verifier.check("audio meter tap: all handoffs through 300 declaration changes are delivered or counted",
      counters.metered > 0 && counters.rejected == 0 && accounted == attempted
        && tap.queuedPackets == 0 && tap.queuedPCMBytes == 0 && tap.viewerCount == 1,
      "\(counters), \(attempted) attempted, \(accounted) accounted")
    verifier.check("audio meter tap: a stalled meter queue coalesces within its slot and byte bounds",
      counters.coalesced > 0 && counters.maxQueued == capacity, "\(counters)")

    // Once the producer stops, commit a final declaration and give that exact
    // replacement one packet. The stable attachment must expose that meter,
    // rather than a previously returned meter that a deferred request replaced.
    do {
      let format = try SourceAudioFormat(sampleRate: 48_000, channels: 2, sample: .int32,
        interleaved: true, layout: AudioChannelMap(), clock: .hostTime)
      try tap.configure(format: format)
    } catch {
      verifier.check("audio meter tap: final declaration is admitted", false, "\(error)")
    }
    let finalPacket = sine(dBFS: -6, phase: 0)
    ingestFinalPacket(tap, finalPacket)
    tap.waitUntilMetered()
    let final = attachment.meter
    final?.flush()
    verifier.check("audio meter tap: a stable attachment meters only its final session's packet",
      final === tap.meter && final?.snapshot().frameCount == UInt64(frames)
        && tap.counters.metered == counters.metered + 1 && tap.queuedPCMBytes == 0,
      "\(tap.counters)")
  }

  private static func ingestFinalPacket(_ tap: AudioMeterTap, _ packet: Data) {
    tap.ingest(samples: packet, sampleFrames: UInt64(frames), channels: 2,
      bytesPerSample: EmbeddedAudioFormat.sourceBytesPerSample)
  }
}
#endif
