@preconcurrency import AVFAudio
import Accelerate
import CoreMedia
import Foundation

/// Both tracks use the first outgoing picture's host time as their origin. During the
/// session each picture consumes its corresponding PCM interval.
/// The short playout delay admits embedded packets delivered just after their picture.
final class ProgramStreamMedia: @unchecked Sendable {
  struct Health {
    var audioReady = false
    var freshPicture = false
    var pictureFeedID: String?
    var missingAudio = false
    var peak: Float = 0
    var audioGaps: UInt64 = 0
    var sentFrames: UInt64 = 0
    var lastVideoSentAt: Date?
  }

  private struct Packet {
    let sample: Int64
    let end: Int64
    let buffer: AVAudioPCMBuffer
  }
  private struct Picture {
    let sample: CMSampleBuffer
    let fresh: Bool
    let audioRange: Range<Int64>?
  }
  private let lock = NSLock()
  private let wantsAudio: Bool
  private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
  private var publisher: (any ProgramStreamPublishing)?
  private var stopped = false
  private var packets: [Packet] = []
  private var pictures: [Picture] = []
  private var gapOpen = false
  private var nextSample: Int64?
  private var lastVideo: CMTime?
  private var lastAudioArrival: TimeInterval?
  private var lastFreshPicture: TimeInterval?
  private var metrics = Health()

  init(wantsAudio: Bool) { self.wantsAudio = wantsAudio }

  func attach(_ publisher: (any ProgramStreamPublishing)?) {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    self.publisher = publisher
    pictures.removeAll(keepingCapacity: true)
    gapOpen = false
    nextSample = nil
    lastVideo = nil
    lastFreshPicture = nil
    metrics.peak = 0
    metrics.missingAudio = false
    metrics.pictureFeedID = nil
    metrics.sentFrames = 0
    metrics.lastVideoSentAt = nil
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    stopped = true
    publisher = nil
    packets.removeAll()
    pictures.removeAll()
  }

  var health: Health {
    lock.lock()
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    var value = metrics
    value.audioReady = lastAudioArrival.map { now - $0 < 1 } ?? false
    value.freshPicture = lastFreshPicture.map { now - $0 < 0.75 } ?? false
    if !value.freshPicture { value.pictureFeedID = nil }
    return value
  }

  private func sampleIndex(_ time: CMTime) -> Int64? {
    guard time.isNumeric, time.epoch == 0, time.value > 0 else { return nil }
    let index = CMTimeConvertScale(time, timescale: 48_000, method: .roundHalfAwayFromZero)
    guard index.isNumeric, index.value > 0, index.value < Int64.max - 96_000 else { return nil }
    return index.value
  }

  func audio(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
    guard wantsAudio, buffer.format == audioFormat, buffer.frameLength > 0,
      buffer.frameLength <= 24_000, let start = sampleIndex(time) else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    // Out-of-order packets can arrive around a signal recovery. Late packets must
    // never overwrite already emitted silence or rewind the receiver's timeline.
    let end = start + Int64(buffer.frameLength)
    if let nextSample, end <= nextSample { return }
    let packet = Packet(sample: start, end: end, buffer: buffer)
    if let last = packets.last, last.sample >= start,
      let position = packets.firstIndex(where: { $0.sample >= start }) {
      if packets[position].sample == start { return }
      packets.insert(packet, at: position)
    } else {
      packets.append(packet)
    }
    lastAudioArrival = ProcessInfo.processInfo.systemUptime
    let cutoff = max(packets.last?.end ?? end, end) - 24_000
    if let first = packets.first, first.sample < cutoff { packets.removeAll { $0.end <= cutoff } }
    if packets.count > 128 { packets.removeFirst(packets.count - 128) }
  }

  func video(_ sample: CMSampleBuffer, fresh: Bool) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    guard let start = sampleIndex(pts) else { return }
    let audioRange: Range<Int64>?
    if wantsAudio {
      // Round absolute boundaries independently. Fractional-rate pictures span
      // different PCM lengths (e.g. 1601 or 1602 samples at 29.97 fps).
      let duration = CMSampleBufferGetDuration(sample)
      guard duration.isNumeric, duration.epoch == 0, duration.value > 0,
        let end = sampleIndex(CMTimeAdd(pts, duration)), end > start else { return }
      audioRange = start..<end
    } else {
      audioRange = nil
    }
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    guard let publisher else {
      lastFreshPicture = fresh ? ProcessInfo.processInfo.systemUptime : nil
      return
    }
    if let lastVideo, CMTimeCompare(pts, lastVideo) <= 0 { return }
    lastVideo = pts
    var picture = Picture(sample: sample, fresh: fresh, audioRange: audioRange)
    if wantsAudio {
      pictures.append(picture)
      guard pictures.count > 3 else { return }
      picture = pictures.removeFirst()
    }
    if metrics.sentFrames == 0 {
      publisher.setMediaEpoch(picture.sample.presentationTimeStamp, includesAudio: wantsAudio)
    }
    if let range = picture.audioRange {
      // Preserve the sound of skipped pictures. A sleep or long scheduler stall can
      // outrun the bounded PCM history; catch up at most 250 ms, counting the current frame.
      let index = range.lowerBound
      let end = range.upperBound
      let previous = nextSample ?? index
      let pictureStart = abs(index - previous) <= 1 ? previous : index
      var cursor = max(previous, end - 12_000)
      if cursor > previous { openAudioGap() }
      var hasPictureAudio = false
      var peak: Float = 0
      while cursor < end {
        // End the catch-up portion precisely at the new picture boundary. The final
        // packet's level and gap status then describe the picture now being submitted.
        let boundary = cursor < pictureStart ? pictureStart : end
        let count = Int(min(4_096, boundary - cursor))
        if let rendered = renderAudio(start: cursor, frames: count) {
          let time = CMTime(value: cursor, timescale: 48_000)
          publisher.appendAudio(rendered.buffer,
            at: AVAudioTime(hostTime: CMClockConvertHostTimeToSystemUnits(time), sampleTime: cursor, atRate: 48_000))
          if cursor >= pictureStart {
            hasPictureAudio = hasPictureAudio || rendered.hasAudio
            peak = max(peak, rendered.peak)
          }
        } else {
          openAudioGap()
        }
        cursor += Int64(count)
      }
      nextSample = cursor
      metrics.missingAudio = !hasPictureAudio
      metrics.peak = min(1, peak)
    }
    publisher.appendVideo(picture.sample)
    metrics.pictureFeedID = picture.fresh ? CMGetAttachment(picture.sample,
      key: "org.ultracam.program-stream.feed-id" as CFString, attachmentModeOut: nil) as? String : nil
    metrics.lastVideoSentAt = Date()
    metrics.sentFrames &+= 1
    lastFreshPicture = picture.fresh ? ProcessInfo.processInfo.systemUptime : nil
  }

  private func openAudioGap() {
    if !gapOpen { metrics.audioGaps &+= 1 }
    gapOpen = true
  }

  /// Caller holds the media lock. Copy the overlapping sample intervals and pad precise gaps.
  private func renderAudio(start: Int64, frames: Int) -> (buffer: AVAudioPCMBuffer, hasAudio: Bool, peak: Float)? {
    guard let output = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames)),
      let outputChannels = output.floatChannelData else { return nil }
    output.frameLength = AVAudioFrameCount(frames)
    let end = start + Int64(frames)
    var hasAudio = false
    var cursor = start
    var peak: Float = 0
    func fillGap(until next: Int64) {
      guard next > cursor else { return }
      for channel in 0..<2 {
        outputChannels[channel].advanced(by: Int(cursor - start)).update(repeating: 0, count: Int(next - cursor))
      }
      openAudioGap()
    }
    for packet in packets {
      if packet.sample >= end { break }
      let from = max(cursor, packet.sample)
      let until = min(end, packet.end)
      guard until > from, let input = packet.buffer.floatChannelData else { continue }
      fillGap(until: from)
      let count = Int(until - from)
      for channel in 0..<2 {
        let source = input[channel].advanced(by: Int(from - packet.sample))
        outputChannels[channel].advanced(by: Int(from - start)).update(from: source, count: count)
        var channelPeak: Float = 0
        vDSP_maxmgv(source, 1, &channelPeak, vDSP_Length(count))
        peak = max(peak, channelPeak)
      }
      cursor = until
      hasAudio = true
      gapOpen = false
    }
    fillGap(until: end)
    if let first = packets.first, first.sample < end { packets.removeAll { $0.end <= end } }
    return (output, hasAudio, peak)
  }
}
