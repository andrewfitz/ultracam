import Foundation
import MonitorKitAudio

// What the app adds around a capture's meter tap: the over watch's state and
// log text, the per-take loudness summary, and readings for a camera without
// a live meter. Foundation and MonitorKitAudio only, so the test binary
// checks it (it compiles AudioMeterTap*.swift).

extension AudioMeterTap {
  /// The over watch's memory between packets. Meter queue only.
  struct OverWatch {
    static let channels = 16
    /// The meter these readings came from; a new session's meter starts over.
    var meter: ObjectIdentifier?
    var lastMax = [Float](repeating: -.infinity, count: channels)
    var lastClips = [UInt32](repeating: 0, count: channels)
    /// The meter's frame count at each channel's last over sample.
    var lastOverFrame = [UInt64?](repeating: nil, count: channels)
    /// Uptime of the last log line, in nanoseconds.
    var lastLog: UInt64?
    /// Overs not logged since the last line (the rate limit).
    var suppressed = 0
  }

  struct LogContext: Sendable, Equatable {
    var camera: String?
    var timecode: String?
  }

  struct TakeState: Sendable {
    var oversAtStart: UInt64
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
