import Foundation
import MonitorKitAudio
import Synchronization

/// One capture's broadcast audio meters (MonitorKitAudio: sample and true peak,
/// RMS, VU, PPM and EBU R 128 loudness), fed from the embedded audio the
/// DeckLink driver thread already hands `CaptureController.receiveRawAudio`.
///
/// Realtime contract on the driver thread (`ingest`): no copy (the meter reads
/// the packet's `Data` in place: the backend's one `NSData` per packet, which
/// recording uses too), no heap allocation or release, no lock, no Swift
/// concurrency; atomics only.
///
/// Demand driven: the meters run only while a view shows them (`attach` /
/// `detach`), so a feed nobody is metering pays one atomic load per packet.
/// Each time metering starts it starts on a new meter, allocated on the
/// attaching (main) thread, so the readings start over and integrated loudness
/// covers the time the meters have been shown. A new meter rather than
/// `AudioMeter.reset()`: a reset keeps the filters' signal memory (the
/// true-peak interpolator's history, the K-weighting), which is right for a
/// continuous stream but here would be the last audio metered before the
/// meters were hidden, possibly minutes earlier. Interpolating across that
/// jump latched a true-peak over that never happened into Max TP, and the
/// stale K-weighting put loudness into silence.
///
/// `AudioMeter` takes one producer at a time. The capture's generation guard
/// already rejects packets from a stopped stream; `producing` makes an overlap
/// of two driver threads (a restart racing the old stream's last packet) skip
/// that packet, counted, instead of corrupting the meter's state. `producing`
/// also tells `attach` whether a driver thread may still be in the previous
/// meter, which then stays alive until a later session start finds none.
final class AudioMeterTap: Sendable {
  /// The capture's fixed embedded-audio format: 48 kHz, 2 channels, Int32.
  static let configuration = AudioMeterConfiguration(
    sampleRate: EmbeddedAudioFormat.sampleRate, channelCount: EmbeddedAudioFormat.channelCount)

  /// The meters' owner; `attach` and `detach` only, never the driver thread.
  private struct Sessions {
    /// The current session's meter; nil until the first attach.
    var live: AudioMeter?
    /// Earlier meters a driver thread may still have been metering into when
    /// they were replaced.
    var retired: [AudioMeter] = []
  }

  private let sessions = Mutex(Sessions())
  /// `sessions.live` for the driver thread, unretained (`sessions` owns it).
  private let current = Atomic<Unmanaged<AudioMeter>?>(nil)
  /// Changed only under `sessions`.
  private let viewers = Atomic<Int>(0)
  private let producing = Atomic<Bool>(false)
  private let metered = Atomic<UInt64>(0)
  private let rejected = Atomic<UInt64>(0)
  private let overlapped = Atomic<UInt64>(0)

  // MARK: Driver thread

  /// Meters one packet, if a view is showing the meters. Driver thread only.
  func ingest(_ audio: CaptureRawAudio) {
    ingest(samples: audio.samples, sampleFrames: audio.sampleFrames, channels: audio.channels,
      bytesPerSample: audio.bytesPerSample)
  }

  func ingest(samples: Data?, sampleFrames: UInt64, channels: Int, bytesPerSample: Int) {
    // Acquiring: a viewer seen here implies its session's meter in `current`.
    guard viewers.load(ordering: .acquiring) > 0, let samples else { return }
    let meterChannels = Self.configuration.channelCount
    guard bytesPerSample == EmbeddedAudioFormat.sourceBytesPerSample, channels >= meterChannels,
      sampleFrames > 0, sampleFrames <= UInt64(Int.max / (channels * bytesPerSample)),
      samples.count >= Int(sampleFrames) * channels * bytesPerSample
    else {
      rejected.add(1, ordering: .relaxed)
      return
    }
    // Sequentially consistent with `startSession`: either it sees `producing`
    // set, or this load sees the meter it installed.
    guard !producing.exchange(true, ordering: .sequentiallyConsistent) else {
      overlapped.add(1, ordering: .relaxed)
      return
    }
    if let meter = current.load(ordering: .sequentiallyConsistent) {
      // Guaranteed: `sessions` keeps the meter alive while `producing` is set, so no retain or release here.
      meter._withUnsafeGuaranteedRef { meter in
        samples.withUnsafeBytes { raw in
          guard let base = raw.baseAddress else { return }
          meter.process(interleaved: base.assumingMemoryBound(to: Int32.self), frameCount: Int(sampleFrames),
            frameStride: channels)
        }
      }
      metered.add(1, ordering: .relaxed)
    }
    producing.store(false, ordering: .releasing)
  }

  // MARK: Any thread

  /// A view starts showing the meters, and gets the meter to show. The first
  /// viewer starts a new session on a new meter; later ones share it.
  @discardableResult func attach() -> AudioMeter {
    sessions.withLock { sessions in
      if viewers.load(ordering: .relaxed) == 0 { startSession(&sessions) }
      viewers.add(1, ordering: .releasing)
      guard let live = sessions.live else { preconditionFailure("A metering session has no meter") }
      return live
    }
  }

  /// A view stopped showing the meters; the last one stops the metering.
  /// Never goes below zero, so an unpaired call cannot stop another view's meters.
  func detach() {
    sessions.withLock { _ in
      if viewers.load(ordering: .relaxed) > 0 { viewers.subtract(1, ordering: .relaxed) }
    }
  }

  /// Installs a new meter for the driver thread. The previous one is released
  /// here unless a driver thread may still be in it (`producing` set); then it
  /// is kept with any earlier ones until a session start sees `producing`
  /// clear, which means every meter but the new one is out of use.
  private func startSession(_ sessions: inout Sessions) {
    let meter: AudioMeter
    do {
      meter = try AudioMeter(configuration: Self.configuration)
    } catch {
      preconditionFailure("The embedded-audio meter configuration is invalid: \(error)")
    }
    let previous = sessions.live
    sessions.live = meter
    current.store(Unmanaged.passUnretained(meter), ordering: .sequentiallyConsistent)
    if producing.load(ordering: .sequentiallyConsistent) {
      if let previous { sessions.retired.append(previous) }
    } else {
      sessions.retired.removeAll()
    }
  }

  var isMetering: Bool { viewers.load(ordering: .relaxed) > 0 }

  /// The current (or last) session's meter; nil before the first attach.
  var meter: AudioMeter? { sessions.withLock { $0.live } }

  /// Meters replaced while a driver thread may still have been in them, kept alive.
  var retiredMeterCount: Int { sessions.withLock { $0.retired.count } }

  struct Counters: Sendable, Equatable {
    /// Packets the meter processed.
    var metered: UInt64
    /// Packets refused for their format (not 32-bit, fewer than 2 channels, short data).
    var rejected: UInt64
    /// Packets skipped because another driver thread was metering at the same time.
    var overlapped: UInt64
  }

  var counters: Counters {
    Counters(metered: metered.load(ordering: .relaxed), rejected: rejected.load(ordering: .relaxed),
      overlapped: overlapped.load(ordering: .relaxed))
  }
}
