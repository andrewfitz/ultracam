import Foundation
import MonitorKitAudio

// What the app adds around a capture's meter tap: the over watch's state and
// log text, the per-take loudness summary, and readings for a camera without
// a live meter. Foundation and MonitorKitAudio only, so the test binary
// checks it (it compiles AudioMeterTap*.swift).

extension AudioMeterTap {
  /// The over watch's memory between packets, for one meter. Meter queue only.
  struct OverWatch {
    static let channels = 16
    /// The meter (session or take number) these readings came from; a new one starts over.
    var source: UInt64?
    var lastMax = [Float](repeating: -.infinity, count: channels)
    var lastClips = [UInt32](repeating: 0, count: channels)
    /// The meter's frame count at each channel's last over sample.
    var lastOverFrame = [UInt64?](repeating: nil, count: channels)

    struct Event: Equatable {
      var channel: Int
      /// dBTP: the higher of the channel's maximum and its bar.
      var level: Float
      var clips: UInt32
    }

    /// Looks at the readings after a packet for a new over: a sample clipped,
    /// the true-peak maximum rose to −1 dBTP or above, or the true-peak bar is
    /// there. Overs on a channel less than a second of audio apart are one
    /// over; overs on several channels at once are one, named by the first.
    mutating func observe(_ snapshot: AudioMeterSnapshot, source: UInt64, sampleRate: Double = EmbeddedAudioFormat.sampleRate) -> Event? {
      if self.source != source { self = OverWatch(source: source) }
      let n = min(snapshot.channelCount, Self.channels)
      var event: Event?
      for c in 0..<n {
        let levels = snapshot.channels[c]
        // A peak reset lowers the maximum and clears the count: follow it.
        if levels.truePeakMax < lastMax[c] || levels.clipCount < lastClips[c] {
          lastMax[c] = levels.truePeakMax
          lastClips[c] = levels.clipCount
        }
        let clipped = levels.clipCount > lastClips[c]
        let rose = levels.truePeakMax > lastMax[c] && levels.truePeakMax >= -1
        let over = clipped || rose || levels.truePeak >= -1
        lastMax[c] = levels.truePeakMax
        lastClips[c] = levels.clipCount
        guard over else { continue }
        let previous = lastOverFrame[c]
        lastOverFrame[c] = snapshot.frameCount
        let gap = UInt64(sampleRate.rounded(.up))
        if event == nil, previous.map({ snapshot.frameCount &- $0 > gap }) ?? true {
          event = Event(channel: c, level: max(levels.truePeakMax, levels.truePeak), clips: levels.clipCount)
        }
      }
      return event
    }
  }

  /// The over log's rate limit: one line a second. Overs held back are counted
  /// in the next line, or flushed in a line of their own once their second is
  /// up, so the log never loses one. Times are uptime nanoseconds. Meter queue only.
  struct OverLogLimiter {
    static let interval: UInt64 = 1_000_000_000
    private(set) var lastLog: UInt64?
    /// Overs held back since the last line.
    private(set) var suppressed = 0
    /// The source timecode of the last over held back.
    private(set) var lastSuppressedTimecode: String?

    /// An over: the count held back to report in its line (0 for none), or nil
    /// when the over is held back.
    mutating func offer(now: UInt64, timecode: String?) -> Int? {
      if let lastLog, now &- lastLog < Self.interval {
        suppressed += 1
        lastSuppressedTimecode = timecode
        return nil
      }
      lastLog = now
      defer { suppressed = 0; lastSuppressedTimecode = nil }
      return suppressed
    }

    /// The overs held back, once a second has passed since the last line; nil when there are none or it's too soon.
    mutating func flush(now: UInt64) -> (count: Int, timecode: String?)? {
      guard suppressed > 0, let lastLog, now &- lastLog >= Self.interval else { return nil }
      self.lastLog = now
      defer { suppressed = 0; lastSuppressedTimecode = nil }
      return (suppressed, lastSuppressedTimecode)
    }

    func nanosecondsUntilFlush(now: UInt64) -> UInt64 {
      guard let lastLog else { return 0 }
      let elapsed = now &- lastLog
      return elapsed >= Self.interval ? 0 : Self.interval - elapsed
    }
  }

  /// A running take: its own meter, and the overs its own watch counted.
  struct TakeState {
    let meter: AudioMeter
    let number: UInt64
    /// The first packet (ring position) the take meters.
    let startPacket: Int
    var paused = false
    var overs = 0
  }

  /// The line for overs the rate limit held back: "Audio overs on Camera 1:
  /// 3 more since the last report, the last at 01:02:03:04".
  static func heldOversMessage(camera: String?, count: Int, lastTimecode: String?) -> String {
    var text = "Audio overs on \(camera ?? "a camera"): \(count) more since the last report"
    if let lastTimecode, !lastTimecode.isEmpty, lastTimecode != "—" { text += ", the last at \(lastTimecode)" }
    return text
  }

  /// One log line for an over: "Audio over on Camera 1, L: +0.4 dBTP, 3 clipped samples, at 01:02:03:04
  /// (2 more since the last report)".
  static func overMessage(
    camera: String?, channel: Int, channels: Int, level: Double, clips: UInt32, timecode: String?, suppressed: Int
  ) -> String {
    let name = channels == 2 ? (channel == 0 ? "L" : "R") : "channel \(channel + 1)"
    var text = "Audio over on \(camera ?? "a camera"), \(name): \(MeterText.level(level)) dBTP"
    if clips > 0 { text += ", \(clips) clipped sample\(clips == 1 ? "" : "s")" }
    if let timecode, !timecode.isEmpty, timecode != "—" { text += ", at \(timecode)" }
    if suppressed > 0 { text += " (\(suppressed) more since the last report)" }
    return text
  }

  /// Readings for a camera without a live meter (fixtures, previews, a camera
  /// not capturing): its 4 Hz status peaks (0…1 sample-peak amplitudes) as
  /// the bars, the hold and the maximum, on the same scale.
  static func snapshot(statusPeaks peaks: [Double]) -> AudioMeterSnapshot {
    var snapshot = AudioMeterSnapshot()
    let n = min(peaks.count, 16)
    snapshot.channelCount = n
    snapshot.programmeChannelMask = UInt16(truncatingIfNeeded: (1 << n) - 1)
    var sequence: UInt64 = 1
    for c in 0..<n {
      let peak = peaks[c]
      let level: Float = peak.isFinite && peak > 0 ? Float(20 * log10(min(peak, 1))) : -.infinity
      snapshot.channels[c] = AudioChannelLevels(
        samplePeak: level, samplePeakHold: level, truePeak: level, truePeakHold: level, truePeakMax: level)
      sequence = sequence &* 31 &+ UInt64(bitPattern: Int64((peak.isFinite ? peak : 0) * 1e6))
    }
    snapshot.sequence = sequence
    return snapshot
  }
}

/// A take's audio, measured by its camera's meter from the take's start.
struct AudioTakeSummary: Sendable, Equatable {
  /// EBU R 128 integrated loudness, LUFS; −∞ when nothing passed the gates.
  var integrated: Double
  /// The programme's maximum true peak, dBTP.
  var maximumTruePeak: Double
  var overs: Int
  /// Seconds of audio measured.
  var duration: Double

  /// For the take's note: "Audio −23.4 LUFS · max −2.1 dBTP · no overs".
  var note: String {
    let loudness = integrated.isFinite ? "\(MeterText.level(integrated)) LUFS" : "no programme loudness"
    let peak = maximumTruePeak.isFinite ? "max \(MeterText.level(maximumTruePeak)) dBTP" : "silent"
    let overText = overs == 0 ? "no overs" : overs == 1 ? "1 over" : "\(overs) overs"
    return "Audio \(loudness) · \(peak) · \(overText)"
  }

  /// Worth a warning: an over, or a true peak at or above −1 dBTP.
  var needsAttention: Bool { overs > 0 || maximumTruePeak >= -1 }
}
