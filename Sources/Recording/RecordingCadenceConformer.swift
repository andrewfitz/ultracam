import CoreMedia

/// Explicit per-take compatibility scheduler. Payloads are retained unchanged;
/// only whole frames are selected, repeated, or skipped on an exact CFR grid.
struct RecordingCadenceConformer<Frame> {
  enum Failure: Error { case invalidTime, regression, gapExceeded, overflow, finished }
  struct Output {
    let frame: Frame
    let presentationTime: CMTime
    let duration: CMTime
  }
  struct Statistics {
    var emitted = 0
    var repeated = 0
    var skipped = 0
  }
  let frameDuration: CMTime
  let maximumJobs: Int
  let maximumGapDuration: CMTime
  private(set) var statistics = Statistics()
  private var pending: (frame: Frame, pts: CMTime, duration: CMTime, used: Bool)?
  private var origin: CMTime?
  private var nextIndex: Int64 = 0
  private var outputBase: CMTime = .zero
  private var ended = false

  init(frameDuration: CMTime, maximumGapDuration: CMTime = CMTime(value: 10, timescale: 1), maximumJobs: Int = 4096) throws {
    guard Self.valid(frameDuration), frameDuration.value > 0, Self.valid(maximumGapDuration), maximumGapDuration.value > 0, maximumJobs > 0 else { throw Failure.invalidTime }
    self.frameDuration = frameDuration
    self.maximumGapDuration = maximumGapDuration
    self.maximumJobs = maximumJobs
  }

  mutating func append(frame: Frame, pts: CMTime, duration: CMTime) throws -> [Output] {
    guard !ended else { throw Failure.finished }
    guard Self.valid(pts), Self.valid(duration), duration.value > 0 else { throw Failure.invalidTime }
    if let pending, CMTimeCompare(pts, pending.pts) <= 0 { throw Failure.regression }
    if let pending {
      let gap = CMTimeSubtract(pts, pending.pts)
      guard Self.valid(gap), CMTimeCompare(gap, maximumGapDuration) <= 0 else { throw Failure.gapExceeded }
    }
    // Prepare on a value copy: refused gaps never consume the pending frame.
    var candidate = self
    if candidate.origin == nil { candidate.origin = pts }
    let outputs = try candidate.drain(before: pts)
    if let old = candidate.pending, !old.used { candidate.statistics.skipped += 1 }
    candidate.pending = (frame, pts, duration, false)
    self = candidate
    return outputs
  }

  mutating func finish() throws -> [Output] {
    guard !ended else { return [] }
    var candidate = self
    if let pending = candidate.pending {
      guard CMTimeCompare(pending.duration, maximumGapDuration) <= 0 else { throw Failure.gapExceeded }
    }
    let outputs = try candidate.pending.map { try candidate.drain(before: $0.pts, adding: $0.duration) } ?? []
    if let old = candidate.pending, !old.used { candidate.statistics.skipped += 1 }
    candidate.pending = nil
    candidate.ended = true
    self = candidate
    return outputs
  }

  /// Flush before pausing. The resumed source origin maps to the next CFR tick
  /// on the common output timeline, even when the source clock restarts.
  mutating func reanchor() throws -> [Output] {
    var candidate = self
    let outputs = try candidate.finish()
    candidate.outputBase = try candidate.gridTime(index: candidate.nextIndex)
    candidate.nextIndex = 0
    candidate.origin = nil
    candidate.ended = false
    self = candidate
    return outputs
  }

  private mutating func drain(before bound: CMTime, adding duration: CMTime = .zero) throws -> [Output] {
    guard let origin, var chosen = pending else { return [] }
    var outputs: [Output] = []
    while true {
      // Compare (origin + index*duration) with bound using exact integers.
      var numerator = Int128(bound.value) * Int128(origin.timescale) - Int128(origin.value) * Int128(bound.timescale)
      var denominator = Int128(bound.timescale) * Int128(origin.timescale)
      var divisor = Self.gcd(numerator, denominator)
      numerator /= divisor; denominator /= divisor
      if duration.value != 0 {
        let left = try Self.product([numerator, Int128(duration.timescale)])
        let right = try Self.product([Int128(duration.value), denominator])
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw Failure.overflow }
        numerator = sum
        denominator = try Self.product([denominator, Int128(duration.timescale)])
        divisor = Self.gcd(numerator, denominator)
        numerator /= divisor; denominator /= divisor
      }
      let lhs = try Self.product([Int128(nextIndex), Int128(frameDuration.value), denominator])
      let rhs = try Self.product([numerator, Int128(frameDuration.timescale)])
      guard lhs < rhs else { break }
      guard outputs.count < maximumJobs else { throw Failure.gapExceeded }
      let time = try gridTime(index: nextIndex)
      outputs.append(Output(frame: chosen.frame, presentationTime: time, duration: frameDuration))
      statistics.emitted += 1
      if chosen.used { statistics.repeated += 1 }
      chosen.used = true
      let (next, overflow) = nextIndex.addingReportingOverflow(1)
      guard !overflow else { throw Failure.overflow }
      nextIndex = next
    }
    pending = chosen
    return outputs
  }

  private func gridTime(index: Int64) throws -> CMTime {
    let product = Int128(index) * Int128(frameDuration.value)
    guard let value = Int64(exactly: product) else { throw Failure.overflow }
    let time = CMTimeAdd(outputBase, CMTime(value: value, timescale: frameDuration.timescale))
    guard Self.valid(time) else { throw Failure.overflow }
    return time
  }
  private static func gcd(_ a: Int128, _ b: Int128) -> Int128 {
    var x = abs(a), y = b
    while y != 0 { (x, y) = (y, x % y) }
    return max(x, 1)
  }
  private static func product(_ factors: [Int128]) throws -> Int128 {
    var value: Int128 = 1
    for factor in factors {
      let (next, overflow) = value.multipliedReportingOverflow(by: factor)
      guard !overflow else { throw Failure.overflow }
      value = next
    }
    return value
  }
  private static func valid(_ time: CMTime) -> Bool { time.isNumeric && time.timescale > 0 && time.epoch == 0 }
}
