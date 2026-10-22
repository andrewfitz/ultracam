import Foundation

public enum AudioMeterError: Error, Equatable, Sendable {
  /// Sample rates from 8 kHz to 768 kHz are supported.
  case unsupportedSampleRate(Double)
  /// 1 to `audioMeterMaximumChannelCount` channels.
  case unsupportedChannelCount(Int)
  /// The loudness channel list must have one entry per input channel.
  case channelLayoutMismatch(expected: Int, actual: Int)
  case invalidParameter(String)
}

/// Sample formats `process` reads. Integers are full-scale normalized
/// (Int16 / 32768, Int32 / 2^31), so Int16 full scale reads -0.0003 dBFS.
public enum AudioSampleFormat: Sendable, Hashable {
  case float32, int16, int32

  var byteSize: Int {
    switch self {
    case .float32, .int32: return 4
    case .int16: return 2
    }
  }
}

/// The level of the alignment tone: a sine whose peak sits at `dBFS`.
public struct AlignmentLevel: Sendable, Hashable {
  public var dBFS: Double
  public init(dBFS: Double) { self.dBFS = dBFS }
  /// EBU R 68: alignment level -18 dBFS (0 dBu).
  public static let ebu = AlignmentLevel(dBFS: -18)
  /// SMPTE RP 155: reference level -20 dBFS.
  public static let smpte = AlignmentLevel(dBFS: -20)
}

/// The IEC 60268-10 quasi-peak programme meter types.
public enum PPMType: Sendable, Hashable, CaseIterable {
  /// Type I (DIN 45406): -2 dB for a 5 ms burst, 20 dB return in 1.5 s.
  case typeI
  /// Type IIa (BBC, scale 1-7): -2 dB for a 10 ms burst, 24 dB fall in 2.8 s.
  case typeIIa
  /// Type IIb (EBU, scale -12...+12 around TEST): Type IIa ballistics.
  case typeIIb

  public var ballistics: PPMBallistics {
    switch self {
    case .typeI: return .typeI
    case .typeIIa, .typeIIb: return .typeII
    }
  }

  /// Maps a reading in dB relative to the alignment level onto the meter's
  /// own scale: DIN dB re Permitted Maximum Level (alignment at -9), the BBC
  /// mark number (alignment at 4, 4 dB per mark) or EBU dB re TEST.
  public func scaleReading(dBRelativeToAlignment level: Double) -> Double {
    switch self {
    case .typeI: return level - 9
    case .typeIIa: return 4 + level / 4
    case .typeIIb: return level
    }
  }
}

/// Quasi-peak ballistics: two parallel charge paths (fast and slow) that only
/// charge while the signal exceeds them, summed with `fastWeight`, falling at
/// a constant dB rate. They charge from the signal on a grid of about
/// 192 kHz (the BS.1770-4 Annex 2 phases below 176.4 kHz, the samples
/// themselves above), as an analog rectifier sees the continuous waveform,
/// so the response is the same at every sample rate. The time constants are
/// fitted against that oversampled envelope to the IEC 60268-10 tone-burst
/// table (5 kHz bursts at reference level):
/// Type I 10/5/3/0.4 ms -> -1/-2/-4/-15 dB; Type II 10/5/1.5/0.5 ms -> -2/-4/-9/-17 dB.
/// A steady sine reads its peak level (the charge droop is calibrated out).
public struct PPMBallistics: Sendable, Hashable {
  public var fastTimeConstant: Double
  public var slowTimeConstant: Double
  public var fastWeight: Double
  /// Fall rate in dB per second.
  public var returnRate: Double

  public init(fastTimeConstant: Double, slowTimeConstant: Double, fastWeight: Double, returnRate: Double) {
    self.fastTimeConstant = fastTimeConstant
    self.slowTimeConstant = slowTimeConstant
    self.fastWeight = fastWeight
    self.returnRate = returnRate
  }

  /// 20 dB in 1.5 s (DIN 45406; inside IEC 60268-10's 1.7 +/- 0.3 s).
  public static let typeI = PPMBallistics(
    fastTimeConstant: 0.00084, slowTimeConstant: 0.00218, fastWeight: 0.477, returnRate: 20 / 1.5)
  /// 24 dB in 2.8 s.
  public static let typeII = PPMBallistics(
    fastTimeConstant: 0.00113, slowTimeConstant: 0.00503, fastWeight: 0.505, returnRate: 24 / 2.8)
}

/// IEC 60268-17 volume indicator: a critically shaped second-order movement on
/// the full-wave rectified signal. A step to reference level reaches 99 % of
/// the reference deflection in `riseTime` and overshoots by `overshoot`
/// (the standard allows 300 ms +/- 10 % and 1 % to 1.5 %).
public struct VUBallistics: Sendable, Hashable {
  public var riseTime: Double
  public var overshoot: Double

  public init(riseTime: Double = 0.3, overshoot: Double = 0.0125) {
    self.riseTime = riseTime
    self.overshoot = overshoot
  }

  public static let iec60268_17 = VUBallistics()

  /// Damping ratio for the overshoot: M = exp(-pi zeta / sqrt(1 - zeta^2)).
  public var dampingRatio: Double {
    let l = -log(overshoot)
    return l / (Double.pi * Double.pi + l * l).squareRoot()
  }

  /// Natural frequency (rad/s) at which the step response first reaches 0.99 at `riseTime`.
  public var naturalFrequency: Double {
    let zeta = dampingRatio
    let wd = (1 - zeta * zeta).squareRoot()
    func step(_ t: Double) -> Double {
      1 - exp(-zeta * t) * (cos(wd * t) + zeta / wd * sin(wd * t))
    }
    // The normalized response rises monotonically up to its peak at pi / wd.
    var lo = 0.0
    var hi = Double.pi / wd
    for _ in 0..<80 {
      let mid = (lo + hi) / 2
      if step(mid) < 0.99 { lo = mid } else { hi = mid }
    }
    return (lo + hi) / 2 / riseTime
  }
}

/// How RMS is expressed.
public enum RMSScale: Sendable, Hashable {
  /// AES17: +3.01 dB, so a sine reads the same as its peak level.
  case aes17
  /// Plain 20 log10(rms): a full-scale sine reads -3.01 dBFS.
  case unscaled
}

/// The meters an `AudioMeter` runs. Turning one off removes its work.
public struct AudioMeterKinds: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let samplePeak = AudioMeterKinds(rawValue: 1 << 0)
  /// BS.1770-4 Annex 2 true peak: 4x oversampled below 96 kHz, 2x from 96 kHz.
  public static let truePeak = AudioMeterKinds(rawValue: 1 << 1)
  public static let rms = AudioMeterKinds(rawValue: 1 << 2)
  public static let vu = AudioMeterKinds(rawValue: 1 << 3)
  /// Quasi-peak programme meter. It charges from the signal on a grid of
  /// about 192 kHz: the true-peak phases below 176.4 kHz, the samples
  /// themselves from 176.4 kHz (see `PPMBallistics`).
  public static let ppm = AudioMeterKinds(rawValue: 1 << 4)
  /// BS.1770-4 / EBU R 128 programme loudness over the configured channels.
  public static let loudness = AudioMeterKinds(rawValue: 1 << 5)

  public static let all: AudioMeterKinds = [.samplePeak, .truePeak, .rms, .vu, .ppm, .loudness]
}

/// A channel's role in BS.1770-4 programme loudness (Table 3 weights).
public enum LoudnessChannel: Sendable, Hashable {
  case left, right, center
  /// Low-frequency effects: excluded by BS.1770-4.
  case lfe
  /// Surround channels at azimuth 60-120 degrees (5.1 surrounds, 7.1 side
  /// surrounds): weight 1.41 (+1.5 dB). Rear surrounds beyond 120 degrees
  /// weigh 1.0 (`.weighted(1)`).
  case leftSurround, rightSurround
  /// Any other position, with an explicit weight.
  case weighted(Double)
  /// Not part of this programme (e.g. another language pair on SDI).
  case excluded

  public var weight: Double {
    switch self {
    case .left, .right, .center: return 1.0
    case .leftSurround, .rightSurround: return 1.41
    case .lfe, .excluded: return 0
    case .weighted(let w): return w
    }
  }

  /// Mono (1), stereo (2), 5.0 (L R C Ls Rs) and 5.1 (SMPTE order L R C LFE
  /// Ls Rs). Any other count is read as an SDI or DeckLink embed carrying the
  /// programme on its first pair: channels 1 and 2 as stereo, the rest
  /// excluded (summing every pair would read 3 LU high per duplicate pair and
  /// count a 7.1 LFE). Pass `surround71`, `programmePair` or an explicit list
  /// for anything else.
  public static func standardLayout(channelCount: Int) -> [LoudnessChannel] {
    switch channelCount {
    case 1: return mono
    case 2: return stereo
    case 5: return surround50
    case 6: return surround51
    default: return programmePair(channelCount: channelCount)
    }
  }

  public static let mono: [LoudnessChannel] = [.center]
  public static let stereo: [LoudnessChannel] = [.left, .right]
  /// L R C Ls Rs.
  public static let surround50: [LoudnessChannel] = [.left, .right, .center, .leftSurround, .rightSurround]
  /// SMPTE order: L R C LFE Ls Rs.
  public static let surround51: [LoudnessChannel] = [.left, .right, .center, .lfe, .leftSurround, .rightSurround]
  /// SMPTE 7.1 order L R C LFE Lss Rss Lrs Rrs (ITU-R BS.2051 System I,
  /// 0+7+0): side surrounds at +/-90 degrees weigh 1.41, rear surrounds at
  /// +/-135 to 150 degrees 1.0, LFE excluded (BS.1770-4 Annex 1 position weights).
  public static let surround71: [LoudnessChannel] = [
    .left, .right, .center, .lfe, .leftSurround, .rightSurround, .weighted(1), .weighted(1),
  ]

  /// One stereo programme on channels `first` and `first + 1` (0-based) of
  /// `channelCount`, every other channel excluded; one channel (with `first`
  /// 0) reads as mono. A pair outside the channels (a stale selection after a format
  /// change, say) gives a layout that measures nothing, which the meters
  /// reject with `.invalidParameter` rather than read silence for ever.
  public static func programmePair(channelCount: Int, first: Int = 0) -> [LoudnessChannel] {
    var layout = [LoudnessChannel](repeating: .excluded, count: max(channelCount, 0))
    if channelCount == 1, first == 0 { return mono }
    if first >= 0, first + 1 < channelCount {
      layout[first] = .left
      layout[first + 1] = .right
    }
    return layout
  }
}

public struct AudioMeterConfiguration: Sendable, Equatable {
  public var sampleRate: Double
  public var channelCount: Int
  public var meters: AudioMeterKinds
  /// How long the peak-hold markers stay before falling. `.infinity` holds until reset.
  public var peakHoldTime: Double
  /// Fall rate of the peak bars and released hold markers, in dB per second.
  /// The default is IEC 60268-18's 20 dB in 1.7 s.
  public var peakDecayRate: Double
  /// Samples at or above this level count as clipped.
  public var clipLevelDBFS: Double
  /// 0 VU sits at this sine level.
  public var vuReference: AlignmentLevel
  public var vuBallistics: VUBallistics
  public var ppmType: PPMType
  /// Replaces the type's ballistics, e.g. for a national variant.
  public var customPPMBallistics: PPMBallistics?
  /// The PPM's alignment mark (BBC 4, EBU TEST, DIN -9) sits at this sine level.
  public var ppmAlignment: AlignmentLevel
  /// Rectangular RMS window, rounded to the meter's 5 to 10 ms tick.
  public var rmsWindow: Double
  public var rmsScale: RMSScale
  /// An explicit loudness layout, or nil for the standard layout of
  /// whatever `channelCount` is (`LoudnessChannel.standardLayout`), so a
  /// stored configuration follows a format change by itself. An explicit
  /// layout does not: it must be reassigned when `channelCount` changes.
  /// Equality compares this, so nil and an explicit copy of the standard
  /// layout are different configurations that measure the same.
  public var loudnessLayout: [LoudnessChannel]?
  /// One entry per input channel: `loudnessLayout`, or the standard layout
  /// for `channelCount`. Setting it stores an explicit layout. Only used when
  /// `meters` contains `.loudness`, and then its entries other than
  /// `.excluded` are also the programme behind
  /// `AudioMeterSnapshot.programmeMaximumTruePeak` (every channel otherwise).
  public var loudnessChannels: [LoudnessChannel] {
    get { loudnessLayout ?? LoudnessChannel.standardLayout(channelCount: channelCount) }
    set { loudnessLayout = newValue }
  }
  /// Readings are published at most once per this much audio (rounded to
  /// whole frames; 0 publishes on every `process` call). Peak holds, maxima,
  /// clip counts and the PPM's per-publish maximum lose nothing in between;
  /// a reset publishes at once, and `AudioMeter.flush()` (or a zero-length
  /// `process` call) publishes what is pending when a stream stops.
  public var publishInterval: Double

  public init(
    sampleRate: Double,
    channelCount: Int,
    meters: AudioMeterKinds = .all,
    peakHoldTime: Double = 2,
    peakDecayRate: Double = 20 / 1.7,
    clipLevelDBFS: Double = -0.01,
    vuReference: AlignmentLevel = .ebu,
    vuBallistics: VUBallistics = .iec60268_17,
    ppmType: PPMType = .typeIIb,
    customPPMBallistics: PPMBallistics? = nil,
    ppmAlignment: AlignmentLevel = .ebu,
    rmsWindow: Double = 0.3,
    rmsScale: RMSScale = .aes17,
    loudnessChannels: [LoudnessChannel]? = nil,
    publishInterval: Double = 0.005
  ) {
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.meters = meters
    self.peakHoldTime = peakHoldTime
    self.peakDecayRate = peakDecayRate
    self.clipLevelDBFS = clipLevelDBFS
    self.vuReference = vuReference
    self.vuBallistics = vuBallistics
    self.ppmType = ppmType
    self.customPPMBallistics = customPPMBallistics
    self.ppmAlignment = ppmAlignment
    self.rmsWindow = rmsWindow
    self.rmsScale = rmsScale
    self.loudnessLayout = loudnessChannels
    self.publishInterval = publishInterval
  }

  /// The ballistics the PPM runs.
  public var ppmBallistics: PPMBallistics { customPPMBallistics ?? ppmType.ballistics }

  func validate() throws(AudioMeterError) {
    try validateFormat(sampleRate: sampleRate, channelCount: channelCount)
    if meters.contains(.loudness) {
      try validateLoudnessChannels(loudnessChannels, channelCount: channelCount)
    }
    guard peakHoldTime >= 0, !peakHoldTime.isNaN else { throw .invalidParameter("peakHoldTime") }
    guard peakDecayRate > 0, peakDecayRate.isFinite else { throw .invalidParameter("peakDecayRate") }
    guard clipLevelDBFS.isFinite else { throw .invalidParameter("clipLevelDBFS") }
    guard vuReference.dBFS.isFinite, ppmAlignment.dBFS.isFinite else {
      throw .invalidParameter("alignment level")
    }
    guard vuBallistics.riseTime > 0, vuBallistics.riseTime.isFinite,
      vuBallistics.overshoot > 0, vuBallistics.overshoot < 0.5
    else { throw .invalidParameter("vuBallistics") }
    guard rmsWindow > 0, rmsWindow <= 60 else { throw .invalidParameter("rmsWindow") }
    guard publishInterval >= 0, publishInterval <= 1 else { throw .invalidParameter("publishInterval") }
    let ppm = ppmBallistics
    guard min(ppm.fastTimeConstant, ppm.slowTimeConstant) * sampleRate >= 1,
      ppm.fastTimeConstant.isFinite, ppm.slowTimeConstant.isFinite,
      (0...1).contains(ppm.fastWeight), ppm.returnRate > 0, ppm.returnRate.isFinite
    else { throw .invalidParameter("ppm ballistics") }
  }
}

func validateFormat(sampleRate: Double, channelCount: Int) throws(AudioMeterError) {
  guard sampleRate >= 8000, sampleRate <= 768_000 else { throw .unsupportedSampleRate(sampleRate) }
  guard (1...audioMeterMaximumChannelCount).contains(channelCount) else {
    throw .unsupportedChannelCount(channelCount)
  }
}

func validateLoudnessChannels(_ channels: [LoudnessChannel], channelCount: Int) throws(AudioMeterError) {
  guard channels.count == channelCount else {
    throw .channelLayoutMismatch(expected: channelCount, actual: channels.count)
  }
  var measured = false
  for channel in channels {
    guard channel.weight >= 0, channel.weight.isFinite else { throw .invalidParameter("loudness weight") }
    if channel.weight > 0 { measured = true }
  }
  // Every channel excluded (or LFE) would read -infinity for ever, like silence.
  guard measured else { throw .invalidParameter("loudness layout measures no channel") }
}
