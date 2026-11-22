import AVFAudio
import CoreMedia
import Foundation

/// One stream session's fixed embedded input. Capture submits immutable source packets;
/// conversion and the publisher handoff run on a private, duration-bounded worker.
final class ProgramStreamAudioTap: @unchecked Sendable {
  struct Statistics: Sendable {
    var packets: UInt64 = 0
    var dropped: UInt64 = 0
    var peak: Float = 0
    var lastHostTime: CMTime?
  }

  private let pairIndex: Int
  private let deliver: @Sendable (AVAudioPCMBuffer, CMTime) -> Void
  private let queue = DispatchQueue(label: "org.ultracam.program-stream.audio", qos: .userInitiated)
  private let lock = NSLock()
  private var stopped = false
  private var counters = Statistics()
  private let budget = MediaRetentionLedger(policy: try! MediaRetentionPolicy(
    maximumBytes: 8 * 1024 * 1024, maximumDuration: 0.25, maximumSlots: 32))

  // Worker-owned. When a capture reopens, both its sample grid and pairing are new.
  private var epoch: CaptureEpochID?
  private var converter: ClockMappedPCMConverter?
  private var lastPacketTime: CMTime?
  private var nextPacketTime: CMTime?
  private var lastPair: (audio: CMTime, host: CMTime)?
  private var rateObservation: (audio: CMTime, host: CMTime)?
  private var pairedRate = 1.0
  private var targetPairedRate = 1.0
  private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

  init(pairIndex: Int, deliver: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) {
    self.pairIndex = pairIndex
    self.deliver = deliver
  }

  var statistics: Statistics { lock.withLock { counters } }
  func stop() { lock.withLock { stopped = true } }

  func ingest(_ packet: CaptureAudioPacket, epoch: CaptureEpochID,
              pairedHostTime: CMTime?, audioMapping: ClockMapping?) {
    guard !lock.withLock({ stopped }) else { return }
    let duration = Double(packet.sampleFrameCount) / packet.format.sampleRate
    guard let lease = try? budget.admit(bytes: packet.planes.reduce(0) { $0 + $1.count }, duration: duration) else {
      lock.withLock { counters.dropped &+= 1 }
      return
    }
    queue.async { [weak self] in
      defer { lease.release() }
      self?.process(packet, epoch: epoch, duration: duration,
        pairedHostTime: pairedHostTime, audioMapping: audioMapping)
    }
  }

  private func process(_ packet: CaptureAudioPacket, epoch: CaptureEpochID, duration: Double,
                       pairedHostTime: CMTime?, audioMapping: ClockMapping?) {
    guard !lock.withLock({ stopped }) else { return }
    do {
      if self.epoch != epoch || converter?.format != packet.format {
        converter = try makeConverter(for: packet.format)
        self.epoch = epoch
        lastPacketTime = nil
        nextPacketTime = nil
        lastPair = nil
        rateObservation = nil
        pairedRate = 1
        targetPairedRate = 1
      }
      // Duplicate or late input cannot move the resampler back to an old grid.
      if let lastPacketTime, packet.packetTime <= lastPacketTime { throw ClockMappedPCMError.invalidPacket }
      let transform = try hostTransform(packet, pairedHostTime: pairedHostTime, audioMapping: audioMapping)
      // PCM timestamps identify samples, so detect even a single missed frame.
      if let expected = nextPacketTime,
        abs(CMTimeSubtract(packet.packetTime, expected).seconds) > 0.5 / packet.format.sampleRate {
        converter = try makeConverter(for: packet.format)
      }
      let chunk: ClockMappedPCMChunk
      do {
        chunk = try convert(packet, transform: transform)
      } catch ClockMappedPCMError.discontinuity, ClockMappedPCMError.slewLimit {
        // A new device clock anchor starts a grid at the actual time.
        // The stream timeline fills the intervening silence.
        converter = try makeConverter(for: packet.format)
        chunk = try convert(packet, transform: transform)
      }
      lastPacketTime = packet.packetTime
      nextPacketTime = CMTimeAdd(packet.packetTime,
        CMTime(seconds: duration, preferredTimescale: 1_000_000_000))
      if chunk.sampleFrameCount > 0 { try publish(chunk) }
    } catch {
      lock.withLock { counters.dropped &+= 1 }
    }
  }

  private func makeConverter(for format: SourceAudioFormat) throws -> ClockMappedPCMConverter {
    guard pairIndex >= 0, pairIndex < max(1, format.channels / 2) else {
      throw ClockMappedPCMError.invalidPacket
    }
    let first = pairIndex * 2
    return try ClockMappedPCMConverter(format: format, outputSampleRate: 48_000,
      selectedChannels: first..<min(first + 2, format.channels))
  }

  private func convert(_ packet: CaptureAudioPacket, transform: PCMClockTransform) throws -> ClockMappedPCMChunk {
    guard let chunk = try converter?.convert(planes: packet.planes, sampleFrameCount: packet.sampleFrameCount,
      audioTime: packet.packetTime, mapping: transform) else { throw ClockMappedPCMError.invalidPacket }
    return chunk
  }

  private func hostTransform(_ packet: CaptureAudioPacket, pairedHostTime: CMTime?,
                             audioMapping: ClockMapping?) throws -> PCMClockTransform {
    switch packet.format.clock {
    case .deviceClock, .hostTime:
      if let audioMapping { return .host(audioMapping) }
      guard packet.format.clock == .hostTime else { throw ClockMappedPCMError.invalidPacket }
      return .paired(audioAnchor: packet.packetTime, videoAnchor: packet.packetTime)
    case .pairedWithFrames:
      // A driver may attach the last frame sequence to subsequent audio-only
      // callbacks. Consume each picture anchor once and extrapolate between them.
      if let host = pairedHostTime, host.isNumeric, host.epoch == 0, host > .zero,
        lastPair.map({ host > $0.host }) ?? true {
        // Estimate oscillator drift over a long window so packet jitter is
        // not turned into pitch changes. Limit slew between estimates.
        if let origin = rateObservation {
          let interval = CMTimeSubtract(packet.packetTime, origin.audio).seconds
          if interval >= 4 {
            let measured = CMTimeSubtract(host, origin.host).seconds / interval
            if (0.998...1.002).contains(measured) {
              targetPairedRate = measured
            }
            rateObservation = (packet.packetTime, host)
          }
        } else { rateObservation = (packet.packetTime, host) }
        pairedRate += min(0.00009, max(-0.00009, targetPairedRate - pairedRate))
        lastPair = (packet.packetTime, host)
      }
      guard let anchor = lastPair else { throw ClockMappedPCMError.invalidPacket }
      // Keep the quantized correction just inside the converter's ±2,000 ppm limit.
      let ppm = min(1999, max(-1999, Int64(((pairedRate - 1) * 1_000_000).rounded())))
      if ppm == 0 { return .paired(audioAnchor: anchor.audio, videoAnchor: anchor.host) }
      let rate = try Rational(1_000_000 + ppm, 1_000_000)
      return .host(try ClockMapping(sourceAnchor: anchor.audio, hostAnchor: anchor.host, rate: rate))
    }
  }

  private func publish(_ chunk: ClockMappedPCMChunk) throws {
    guard chunk.presentationTime.isNumeric, chunk.presentationTime.epoch == 0, chunk.presentationTime > .zero,
      lock.withLock({ counters.lastHostTime.map { chunk.presentationTime > $0 } ?? true }) else {
      throw ClockMappedPCMError.discontinuity
    }
    let count = AVAudioFrameCount(chunk.sampleFrameCount)
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: count),
      let planes = output.floatChannelData else { throw ClockMappedPCMError.workspaceLimit }
    output.frameLength = count
    let right = chunk.channels - 1
    var peak: Float = 0
    chunk.samples.withUnsafeBytes { bytes in
      let samples = bytes.bindMemory(to: Float.self)
      for frame in 0..<chunk.sampleFrameCount {
        let start = frame * chunk.channels
        let l = samples[start], r = samples[start + right]
        planes[0][frame] = l
        planes[1][frame] = r
        peak = max(peak, abs(l), abs(r))
      }
    }
    let accepted = lock.withLock {
      guard !stopped else { return false }
      counters.peak = peak
      counters.packets &+= 1
      counters.lastHostTime = chunk.presentationTime
      return true
    }
    if accepted { deliver(output, chunk.presentationTime) }
  }

  #if ULTRACAM_TEST_SUPPORT
  func drainForTesting() { queue.sync {} }
  #endif
}
