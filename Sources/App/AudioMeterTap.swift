import Foundation
import MonitorKitAudio
import Synchronization

/// One capture's broadcast audio meters (MonitorKitAudio: sample and true peak,
/// RMS, VU, PPM and EBU R 128 loudness), fed from the embedded audio the
/// DeckLink driver thread already hands `CaptureController.receiveRawAudio`.
///
/// Realtime contract on the driver thread (`ingest`): no copy (the meter reads
/// the packet's `Data` in place: the backend's one `NSData` per packet, which
/// recording uses too), no heap allocation, no lock, no Swift concurrency;
/// atomics only. The meter is allocated once, here.
///
/// Demand driven: the meters run only while a view shows them (`attach` /
/// `detach`), so a feed nobody is metering pays one relaxed load per packet.
/// Each time metering starts the readings start over, so integrated loudness
/// covers the time the meters have been shown.
///
/// `AudioMeter` takes one producer at a time. The capture's generation guard
/// already rejects packets from a stopped stream; `producing` makes an overlap
/// of two driver threads (a restart racing the old stream's last packet) skip
/// that packet, counted, instead of corrupting the meter's state.
final class AudioMeterTap: Sendable {
  /// The capture's fixed embedded-audio format: 48 kHz, 2 channels, Int32.
  static let configuration = AudioMeterConfiguration(
    sampleRate: EmbeddedAudioFormat.sampleRate, channelCount: EmbeddedAudioFormat.channelCount)

  let meter: AudioMeter
  private let viewers = Atomic<Int>(0)
  private let producing = Atomic<Bool>(false)
  private let metered = Atomic<UInt64>(0)
  private let rejected = Atomic<UInt64>(0)
  private let overlapped = Atomic<UInt64>(0)

  init() {
    do {
      meter = try AudioMeter(configuration: Self.configuration)
    } catch {
      preconditionFailure("The embedded-audio meter configuration is invalid: \(error)")
    }
  }

  // MARK: Driver thread

  /// Meters one packet, if a view is showing the meters. Driver thread only.
  func ingest(_ audio: CaptureRawAudio) {
    ingest(samples: audio.samples, sampleFrames: audio.sampleFrames, channels: audio.channels,
      bytesPerSample: audio.bytesPerSample)
  }

  func ingest(samples: Data?, sampleFrames: UInt64, channels: Int, bytesPerSample: Int) {
    guard viewers.load(ordering: .relaxed) > 0, let samples else { return }
    let meterChannels = Self.configuration.channelCount
    guard bytesPerSample == EmbeddedAudioFormat.sourceBytesPerSample, channels >= meterChannels,
      sampleFrames > 0, sampleFrames <= UInt64(Int.max / (channels * bytesPerSample)),
      samples.count >= Int(sampleFrames) * channels * bytesPerSample
    else {
      rejected.add(1, ordering: .relaxed)
      return
    }
    guard !producing.exchange(true, ordering: .acquiring) else {
      overlapped.add(1, ordering: .relaxed)
      return
    }
    samples.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      meter.process(interleaved: base.assumingMemoryBound(to: Int32.self), frameCount: Int(sampleFrames),
        frameStride: channels)
    }
    producing.store(false, ordering: .releasing)
    metered.add(1, ordering: .relaxed)
  }

  // MARK: Any thread

  /// A view starts showing the meters. The first viewer starts a new measurement.
  func attach() {
    if viewers.add(1, ordering: .relaxed).oldValue == 0 { meter.reset() }
  }

  /// A view stopped showing the meters; the last one stops the metering.
  /// Never goes below zero, so an unpaired call cannot stop another view's meters.
  func detach() {
    var current = viewers.load(ordering: .relaxed)
    while current > 0 {
      let (exchanged, original) = viewers.compareExchange(
        expected: current, desired: current - 1, ordering: .relaxed)
      if exchanged { return }
      current = original
    }
  }

  var isMetering: Bool { viewers.load(ordering: .relaxed) > 0 }

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
