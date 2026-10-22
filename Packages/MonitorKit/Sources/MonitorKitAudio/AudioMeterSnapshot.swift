import Foundation

/// One channel's readings. Levels are in dB; `-infinity` means silence (or a
/// meter that is turned off).
public struct AudioChannelLevels: Sendable, BitwiseCopyable, Equatable {
  /// Sample-peak bar in dBFS: instant attack, falls at the configured rate.
  public var samplePeak: Float
  /// Sample-peak hold marker in dBFS.
  public var samplePeakHold: Float
  /// True-peak bar in dBTP (BS.1770-4 Annex 2: 4x below 96 kHz, 2x from
  /// 96 kHz, so at least 192 kHz from 48 kHz up), never below the sample
  /// peak. Like any band-limited reconstruction it overshoots on a step in
  /// the signal itself; starting, resetting or re-attaching the meter
  /// mid-stream adds none.
  public var truePeak: Float
  public var truePeakHold: Float
  /// Highest true peak since the last peak reset, in dBTP.
  public var truePeakMax: Float
  /// Rectangular-window RMS in dBFS, scaled per `RMSScale`.
  public var rms: Float
  /// Volume indicator reading in VU (0 VU at the configured reference).
  public var vu: Float
  /// Quasi-peak reading in dB relative to the alignment level: the highest
  /// reading since the previous publish (one per `publishInterval` of audio,
  /// or per `process` call when calls are longer). A reader slower than the
  /// publishes sees the latest one; the slow fall (about 0.2 dB per 21 ms for
  /// Type II) bounds what it can miss.
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
  /// 400 ms window, LUFS. `-infinity` until the meter has seen 400 ms; a
  /// loudness reset does not interrupt it (the window slides over the audio).
  public var momentary: Float
  /// 3 s window, LUFS. `-infinity` until the meter has seen 3 s; a loudness
  /// reset does not interrupt it.
  public var shortTerm: Float
  /// Gated programme loudness, LUFS. `-infinity` until a block passes the gates.
  public var integrated: Float
  /// EBU Tech 3342 loudness range in LU.
  public var loudnessRange: Float
  /// Highest momentary reading over windows wholly after the last loudness
  /// reset: `-infinity` until 400 ms of the new measurement have passed.
  public var momentaryMax: Float
  /// Highest short-term reading over windows wholly after the last loudness
  /// reset: `-infinity` until 3 s of the new measurement have passed.
  public var shortTermMax: Float
  /// Audio measured since the last loudness reset, in seconds; paused audio
  /// does not count. A reset, like a pause, takes effect at the next 5 or
  /// 10 ms tick boundary, so the tick it falls in counts for neither measurement.
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

  /// What a loudness reset leaves: the sliding momentary and short-term
  /// windows carry on, the measurement (integrated, LRA, maxima, duration) starts over.
  var startingNewMeasurement: LoudnessSnapshot {
    LoudnessSnapshot(momentary: momentary, shortTerm: shortTerm)
  }
}

/// Everything an `AudioMeter` measured, as one consistent value. Fixed size,
/// so reading it never allocates.
public struct AudioMeterSnapshot: Sendable, BitwiseCopyable {
  /// Changes whenever the readings may have: it advances on every publish and
  /// on every reset request (a pending reset already shows in `snapshot()`).
  /// Unchanged means nothing new, so a view can redraw only when it moves.
  public var sequence: UInt64
  /// Frames processed since the meter was created or fully reset.
  public var frameCount: UInt64
  public var channelCount: Int
  /// Valid for `0..<channelCount`.
  public var channels: InlineArray<16, AudioChannelLevels>
  /// Programme loudness; default values when loudness is off.
  public var loudness: LoudnessSnapshot
  /// Bit c set when channel c belongs to the programme: the loudness
  /// layout's entries other than `.excluded` (LFE included, though its
  /// loudness weight is 0), or every channel when loudness is off.
  public var programmeChannelMask: UInt16
  /// The levels behind `vu` and `ppm`, so a UI can convert to dBFS.
  public var vuReferenceDBFS: Float
  public var ppmAlignmentDBFS: Float

  public init() {
    sequence = 0
    frameCount = 0
    channelCount = 0
    channels = InlineArray(repeating: AudioChannelLevels())
    loudness = LoudnessSnapshot()
    programmeChannelMask = 0
    vuReferenceDBFS = -18
    ppmAlignmentDBFS = -18
  }

  public subscript(channel: Int) -> AudioChannelLevels {
    precondition(channel >= 0 && channel < channelCount, "channel out of range")
    return channels[channel]
  }

  /// The highest true peak since the last peak reset across every channel,
  /// whether or not it belongs to the programme. For the programme's EBU R 128
  /// "Max TP" use `programmeMaximumTruePeak`.
  public var maximumTruePeak: Float { maximumTruePeak(channels: UInt16.max) }

  /// The programme's EBU R 128 / Tech 3341 "Max TP": the highest true peak
  /// since the last peak reset over `programmeChannelMask`, so another
  /// language pair or an ISO feed on the same embed does not count.
  public var programmeMaximumTruePeak: Float { maximumTruePeak(channels: programmeChannelMask) }

  private func maximumTruePeak(channels mask: UInt16) -> Float {
    var m = -Float.infinity
    var c = 0
    while c < channelCount {
      if mask & (1 << c) != 0 { m = max(m, channels[c].truePeakMax) }
      c += 1
    }
    return m
  }
}
