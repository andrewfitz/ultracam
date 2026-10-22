import Foundation

/// One channel's readings. Levels are in dB; `-infinity` means silence (or a
/// meter that is turned off).
public struct AudioChannelLevels: Sendable, BitwiseCopyable, Equatable {
  /// Sample-peak bar in dBFS: instant attack, falls at the configured rate.
  public var samplePeak: Float
  /// Sample-peak hold marker in dBFS.
  public var samplePeakHold: Float
  /// True-peak bar in dBTP (BS.1770-4 Annex 2, oversampled to about
  /// 192 kHz), never below the sample peak. Like any band-limited
  /// reconstruction it overshoots on a step in the signal itself; starting,
  /// resetting or re-attaching the meter mid-stream adds none.
  public var truePeak: Float
  public var truePeakHold: Float
  /// Highest true peak since the last peak reset, in dBTP.
  public var truePeakMax: Float
  /// Rectangular-window RMS in dBFS, scaled per `RMSScale`.
  public var rms: Float
  /// Volume indicator reading in VU (0 VU at the configured reference).
  public var vu: Float
  /// Quasi-peak reading in dB relative to the alignment level: the highest
  /// reading since the previous publish (one per `process` call). A reader
  /// slower than the publishes sees the latest one; the slow fall (about
  /// 0.2 dB per 21 ms for Type II) bounds what it can miss.
  public var ppm: Float
  /// Samples at or above the clip level since the last peak reset.
  public var clipCount: UInt32

  public init(
    samplePeak: Float = -.infinity, samplePeakHold: Float = -.infinity,
    truePeak: Float = -.infinity, truePeakHold: Float = -.infinity, truePeakMax: Float = -.infinity,
    rms: Float = -.infinity, vu: Float = -.infinity, ppm: Float = -.infinity, clipCount: UInt32 = 0
  ) {
    self.samplePeak = samplePeak
    self.samplePeakHold = samplePeakHold
    self.truePeak = truePeak
    self.truePeakHold = truePeakHold
    self.truePeakMax = truePeakMax
    self.rms = rms
    self.vu = vu
    self.ppm = ppm
    self.clipCount = clipCount
  }
}

/// BS.1770-4 / EBU R 128 loudness readings.
public struct LoudnessSnapshot: Sendable, BitwiseCopyable, Equatable {
  /// 400 ms window, LUFS. `-infinity` until 400 ms have been measured.
  public var momentary: Float
  /// 3 s window, LUFS. `-infinity` until 3 s have been measured.
  public var shortTerm: Float
  /// Gated programme loudness, LUFS. `-infinity` until a block passes the gates.
  public var integrated: Float
  /// EBU Tech 3342 loudness range in LU.
  public var loudnessRange: Float
  public var momentaryMax: Float
  public var shortTermMax: Float
  /// Audio measured since the last loudness reset, in seconds.
  public var duration: Double

  public init(
    momentary: Float = -.infinity, shortTerm: Float = -.infinity, integrated: Float = -.infinity,
    loudnessRange: Float = 0, momentaryMax: Float = -.infinity, shortTermMax: Float = -.infinity,
    duration: Double = 0
  ) {
    self.momentary = momentary
    self.shortTerm = shortTerm
    self.integrated = integrated
    self.loudnessRange = loudnessRange
    self.momentaryMax = momentaryMax
    self.shortTermMax = shortTermMax
    self.duration = duration
  }
}

/// Everything an `AudioMeter` measured, as one consistent value. Fixed size,
/// so reading it never allocates.
public struct AudioMeterSnapshot: Sendable, BitwiseCopyable {
  /// Increments on every publish; unchanged means nothing new.
  public var sequence: UInt64
  /// Frames processed since the meter was created or fully reset.
  public var frameCount: UInt64
  public var channelCount: Int
  /// Valid for `0..<channelCount`.
  public var channels: InlineArray<16, AudioChannelLevels>
  /// Programme loudness; default values when loudness is off.
  public var loudness: LoudnessSnapshot
  /// The levels behind `vu` and `ppm`, so a UI can convert to dBFS.
  public var vuReferenceDBFS: Float
  public var ppmAlignmentDBFS: Float

  public init() {
    sequence = 0
    frameCount = 0
    channelCount = 0
    channels = InlineArray(repeating: AudioChannelLevels())
    loudness = LoudnessSnapshot()
    vuReferenceDBFS = -18
    ppmAlignmentDBFS = -18
  }

  public subscript(channel: Int) -> AudioChannelLevels {
    precondition(channel >= 0 && channel < channelCount, "channel out of range")
    return channels[channel]
  }

  /// The highest true peak since reset across all channels (EBU R 128 "Max TP").
  public var maximumTruePeak: Float {
    var m = -Float.infinity
    var c = 0
    while c < channelCount {
      m = max(m, channels[c].truePeakMax)
      c += 1
    }
    return m
  }
}
