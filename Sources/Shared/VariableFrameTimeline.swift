import CoreMedia
import Foundation

/// A monotonic media clock for variable-frame-rate samples.
///
/// Source timestamps may use different timescales. Samples are projected onto a
/// fixed integer clock and rounded from their absolute offset, so rounding does
/// not accumulate over a long take. Calling `pause()` starts a new source epoch;
/// the next sample is placed immediately after the last emitted sample.
struct VariableFrameTimeline: Sendable {
  enum Failure: Error, Equatable {
    case invalidTime
    case nonpositiveDuration
    case timestampRegression
    case timestampCollision
    case overflow
  }

  struct Sample: Sendable, Equatable {
    let presentationTime: CMTime
    let duration: CMTime
    let sourcePresentationTime: CMTime
    let sourceDuration: CMTime
  }

  let timescale: Int32
  private(set) var lastSample: Sample?
  private var sourceOrigin: CMTime?
  private var lastSourcePTS: CMTime?
  private var paused = false
  private var outputBase: Int64 = 0

  init(timescale: Int32 = 240_000) throws {
    guard timescale > 0 else { throw Failure.invalidTime }
    self.timescale = timescale
  }

  /// Ends the current source epoch. The next appended sample follows the last
  /// sample boundary, regardless of the source timestamp gap while paused.
  mutating func pause() { paused = true; sourceOrigin = nil; lastSourcePTS = nil }

  var isPaused: Bool { paused }

  mutating func append(pts: CMTime, duration: CMTime) throws -> Sample {
    guard pts.isNumeric, pts.timescale > 0, duration.isNumeric, duration.timescale > 0,
      pts.epoch == 0, duration.epoch == 0 else { throw Failure.invalidTime }
    guard duration.value > 0 else { throw Failure.nonpositiveDuration }
    if !paused, let previous = lastSourcePTS, CMTimeCompare(pts, previous) <= 0 {
      throw Failure.timestampRegression
    }
    if paused || sourceOrigin == nil {
      sourceOrigin = pts
      lastSourcePTS = nil
      if let last = lastSample {
        let (base, overflow) = last.presentationTime.value.addingReportingOverflow(last.duration.value)
        guard !overflow else { throw Failure.overflow }
        outputBase = base
      } else { outputBase = 0 }
      paused = false
    }
    guard let origin = sourceOrigin else { throw Failure.invalidTime }
    let outputValue: Int64
    if lastSample != nil {
      let offset = try quantizedOffset(pts, from: origin)
      let candidate = Int128(outputBase) + Int128(offset)
      guard let value = Int64(exactly: candidate) else { throw Failure.overflow }
      outputValue = value
    } else {
      outputValue = outputBase
    }
    let d = try quantize(value: Int128(duration.value) * Int128(timescale), denominator: Int128(duration.timescale))
    guard d > 0, let durationValue = Int64(exactly: d) else { throw Failure.overflow }
    if let prior = lastSample, outputValue <= prior.presentationTime.value { throw Failure.timestampCollision }
    let sample = Sample(presentationTime: CMTime(value: outputValue, timescale: timescale),
      duration: CMTime(value: durationValue, timescale: timescale),
      sourcePresentationTime: pts, sourceDuration: duration)
    lastSample = sample
    lastSourcePTS = pts
    return sample
  }


  private func quantizedOffset(_ pts: CMTime, from origin: CMTime) throws -> Int64 {
    let numerator = Int128(pts.value) * Int128(origin.timescale) - Int128(origin.value) * Int128(pts.timescale)
    let denominator = Int128(pts.timescale) * Int128(origin.timescale)
    let q = try quantize(value: numerator * Int128(timescale), denominator: denominator)
    guard let result = Int64(exactly: q) else { throw Failure.overflow }
    return result
  }

  private func quantize(value: Int128, denominator: Int128) throws -> Int128 {
    guard denominator > 0 else { throw Failure.invalidTime }
    var q = value / denominator
    let remainder = value % denominator
    if abs(remainder) * 2 >= denominator { q += value < 0 ? -1 : 1 }
    return q
  }
}
