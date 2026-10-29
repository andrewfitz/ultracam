import CoreMedia
import Foundation

// A take selects one immutable video track scale before opening its writer.
// This type prepares timing only; writer admission/finalization belongs to its caller.
struct RecordingTimebase: Sendable {
  enum Failure: Error, Equatable {
    case invalidTime, invalidDeclaredTimebase, exactScaleUnavailable
    case quantizationPolicyRequired, invalidQuantizationPolicy
    case incompatibleDuration, unrepresentableTime, timestampRegression
    case timestampCollision, nonpositiveDuration, policyExceeded
  }

  struct QuantizationPolicy: Hashable, Codable, Sendable {
    let maximumTimestampErrorSeconds: Double
    let maximumIntervalErrorSeconds: Double
    // Selecting this value explicitly authorizes nearest rounding at 240000.
    static let nearest240000 = Self(maximumTimestampErrorSeconds: 0.5 / 240000, maximumIntervalErrorSeconds: 1 / 240000)
    init(maximumTimestampErrorSeconds: Double, maximumIntervalErrorSeconds: Double) {
      self.maximumTimestampErrorSeconds = maximumTimestampErrorSeconds
      self.maximumIntervalErrorSeconds = maximumIntervalErrorSeconds
    }
    fileprivate func validate() throws {
      guard maximumTimestampErrorSeconds.isFinite, maximumIntervalErrorSeconds.isFinite,
        maximumTimestampErrorSeconds >= 0, maximumIntervalErrorSeconds >= 0,
        maximumTimestampErrorSeconds <= 0.5 / 240000,
        maximumIntervalErrorSeconds <= 1 / 240000 else { throw Failure.invalidQuantizationPolicy }
    }
  }

  struct Configuration: Hashable, Sendable {
    let frameRate: FrameRate
    let timescale: Int32
    let quantizationPolicy: QuantizationPolicy?
    var isQuantized: Bool { quantizationPolicy != nil }

    // Each declared timebase means a tick of 1 / scale. nil means the plugin
    // cannot declare future timestamp timebases; [] is not such a declaration.
    init(frameRate: FrameRate, declaredTimebases: [Int32]?, quantizationPolicy: QuantizationPolicy? = nil) throws {
      try frameRate.validate()
      if let quantizationPolicy { try quantizationPolicy.validate() }
      if let declaredTimebases, declaredTimebases.isEmpty || declaredTimebases.contains(where: { $0 <= 0 }) { throw Failure.invalidDeclaredTimebase }
      let durations: [CMTime]
      switch frameRate {
      case .constant(let duration): durations = [duration]
      case .variable(let nominal, let shortest, let longest): durations = [nominal, shortest, longest]
      }
      var scale: Int64 = 1
      // A CFR duration declares its own exact cadence scale. Undeclared
      // timestamp ticks remain checked sample by sample against that scale.
      let constantRate: Bool = { if case .constant = frameRate { return true }; return false }()
      var exactAvailable = declaredTimebases != nil || constantRate
      let denominators = (declaredTimebases ?? []).map(Int64.init) + durations.map(Self.reducedDenominator)
      for denominator in denominators {
        let divisor = Self.gcd(scale, denominator)
        let (candidate, overflow) = (scale / divisor).multipliedReportingOverflow(by: denominator)
        if overflow || candidate > Int32.max { exactAvailable = false; break }
        scale = candidate
      }
      self.frameRate = frameRate
      if exactAvailable {
        timescale = Int32(scale); self.quantizationPolicy = nil
      } else {
        guard let quantizationPolicy else { throw Failure.quantizationPolicyRequired }
        timescale = 240000; self.quantizationPolicy = quantizationPolicy
        // Even explicitly quantized CFR takes must represent cadence exactly.
        if case .constant(let duration) = frameRate,
          Int128(duration.value) * 240000 % Int128(duration.timescale) != 0 { throw Failure.exactScaleUnavailable }
      }
    }

    private static func reducedDenominator(_ time: CMTime) -> Int64 {
      // magnitude handles Int64.min without trapping.
      var a = time.value.magnitude, b = UInt64(time.timescale)
      while b != 0 { (a, b) = (b, a % b) }
      return Int64(time.timescale) / Int64(max(a, 1))
    }
    private static func gcd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
      var a = lhs, b = rhs
      while b != 0 { (a, b) = (b, a % b) }
      return a
    }
  }

  // Plain fields preserve original timing for a sidecar without system-type
  // Codable conformances. These descriptors never decide writer timing.
  struct TimeDescriptor: Hashable, Codable, Sendable {
    let value: Int64
    let timescale: Int32
    let epoch: Int64
    let flags: UInt32
    fileprivate init(_ time: CMTime) {
      value = time.value; timescale = time.timescale; epoch = time.epoch; flags = time.flags.rawValue
    }
  }
  struct OriginalTiming: Hashable, Codable, Sendable {
    let presentationTime: TimeDescriptor
    let duration: TimeDescriptor
    let takeOrigin: TimeDescriptor
  }
  struct SampleTiming: Sendable {
    let presentationTime: CMTime
    let duration: CMTime
    let original: OriginalTiming?
    let timestampErrorSeconds: Double
    let durationErrorSeconds: Double
    let intervalErrorSeconds: Double
  }
  struct Diagnostics: Hashable, Codable, Sendable {
    fileprivate(set) var acceptedSamples: UInt64 = 0
    fileprivate(set) var quantizedSamples: UInt64 = 0
    fileprivate(set) var rejectedSamples: UInt64 = 0
    fileprivate(set) var timestampCollisions: UInt64 = 0
    fileprivate(set) var maximumTimestampErrorSeconds: Double = 0
    fileprivate(set) var maximumDurationErrorSeconds: Double = 0
    fileprivate(set) var maximumIntervalErrorSeconds: Double = 0
  }

  let configuration: Configuration
  let origin: CMTime
  private(set) var diagnostics = Diagnostics()
  private var lastSourcePTS: CMTime?
  private var lastTrackPTS: Int64?

  init(configuration: Configuration, origin: CMTime) throws {
    try Self.validateNumeric(origin)
    self.configuration = configuration; self.origin = origin
  }

  mutating func append(pts: CMTime, duration: CMTime) throws -> SampleTiming {
    do {
      let timing = try prepare(pts: pts, duration: duration)
      lastSourcePTS = pts; lastTrackPTS = timing.presentationTime.value
      diagnostics.acceptedSamples += 1
      if timing.original != nil { diagnostics.quantizedSamples += 1 }
      diagnostics.maximumTimestampErrorSeconds = max(diagnostics.maximumTimestampErrorSeconds, timing.timestampErrorSeconds)
      diagnostics.maximumDurationErrorSeconds = max(diagnostics.maximumDurationErrorSeconds, timing.durationErrorSeconds)
      diagnostics.maximumIntervalErrorSeconds = max(diagnostics.maximumIntervalErrorSeconds, timing.intervalErrorSeconds)
      return timing
    } catch {
      diagnostics.rejectedSamples += 1
      if let failure = error as? Failure, failure == .timestampCollision { diagnostics.timestampCollisions += 1 }
      throw error
    }
  }

  private func prepare(pts: CMTime, duration: CMTime) throws -> SampleTiming {
    try Self.validateNumeric(pts); try Self.validateNumeric(duration)
    guard pts.epoch == origin.epoch, duration.epoch == 0 else { throw Failure.invalidTime }
    guard duration.value > 0 else { throw Failure.nonpositiveDuration }
    guard CMTimeCompare(pts, origin) >= 0 else { throw Failure.timestampRegression }
    if let lastSourcePTS, CMTimeCompare(pts, lastSourcePTS) <= 0 { throw Failure.timestampRegression }
    switch configuration.frameRate {
    case .constant(let expected):
      guard CMTimeCompare(duration, expected) == 0 else { throw Failure.incompatibleDuration }
    case .variable(_, let shortest, let longest):
      guard CMTimeCompare(duration, shortest) >= 0, CMTimeCompare(duration, longest) <= 0 else { throw Failure.incompatibleDuration }
    }
    let scale = Int128(configuration.timescale)
    // Int64 values × positive Int32 scales × Int32 output scales fit Int128.
    // Subtract exact absolute timestamps first; never accumulate rounded durations.
    let numerator = Int128(pts.value) * Int128(origin.timescale) - Int128(origin.value) * Int128(pts.timescale)
    let denominator = Int128(pts.timescale) * Int128(origin.timescale)
    let p = try quantize(numerator: numerator, denominator: denominator)
    let d = try quantize(numerator: Int128(duration.value), denominator: Int128(duration.timescale))
    guard d.value > 0 else { throw Failure.nonpositiveDuration }
    if let lastTrackPTS, p.value <= lastTrackPTS { throw Failure.timestampCollision }
    var intervalError = 0.0
    if let lastSourcePTS, let lastTrackPTS {
      let n = Int128(pts.value) * Int128(lastSourcePTS.timescale) - Int128(lastSourcePTS.value) * Int128(pts.timescale)
      let den = Int128(pts.timescale) * Int128(lastSourcePTS.timescale)
      let trackInterval = Int128(p.value) - Int128(lastTrackPTS)
      intervalError = abs(Double(trackInterval * den - n * scale) / Double(den * scale))
    }
    if let policy = configuration.quantizationPolicy {
      guard p.error <= policy.maximumTimestampErrorSeconds,
        d.error <= policy.maximumTimestampErrorSeconds,
        intervalError <= policy.maximumIntervalErrorSeconds else { throw Failure.policyExceeded }
    }
    let quantized = p.error > 0 || d.error > 0
    return SampleTiming(presentationTime: CMTime(value: p.value, timescale: configuration.timescale), duration: CMTime(value: d.value, timescale: configuration.timescale), original: quantized ? OriginalTiming(presentationTime: TimeDescriptor(pts), duration: TimeDescriptor(duration), takeOrigin: TimeDescriptor(origin)) : nil, timestampErrorSeconds: p.error, durationErrorSeconds: d.error, intervalErrorSeconds: intervalError)
  }

  private func quantize(numerator: Int128, denominator: Int128) throws -> (value: Int64, error: Double) {
    let scaled = numerator * Int128(configuration.timescale)
    let remainder = scaled % denominator
    if remainder != 0, configuration.quantizationPolicy == nil { throw Failure.unrepresentableTime }
    var rounded = scaled / denominator
    // Nearest, with exact half ticks away from zero, independent of FP precision.
    if abs(remainder) * 2 >= denominator { rounded += scaled < 0 ? -1 : 1 }
    guard let value = Int64(exactly: rounded) else { throw Failure.unrepresentableTime }
    let error = abs(Double(rounded * denominator - scaled) / Double(denominator * Int128(configuration.timescale)))
    return (value, error)
  }

  private static func validateNumeric(_ time: CMTime) throws {
    guard time.isNumeric, time.timescale > 0 else { throw Failure.invalidTime }
  }
}
