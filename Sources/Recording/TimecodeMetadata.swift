import CoreMedia
import Foundation

/// Lossless metadata for a native SMPTE timecode carried by a capture source.
/// The source label is retained alongside its decoded frame number so the
/// drop-frame separator and capture epoch survive a recording boundary.
public struct TimecodeMetadata: Equatable, Codable, Sendable {
  public let label: String
  public let frameRate: RecordingFrameRate
  public let frameNumber: Int64
  public let epoch: CMTimeEpoch
  public let dropFrame: Bool

  private enum CodingKeys: String, CodingKey { case label, rateNumerator, rateDenominator, frameNumber, epoch, dropFrame }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let numerator = try c.decode(Int64.self, forKey: .rateNumerator)
    let denominator = try c.decode(Int64.self, forKey: .rateDenominator)
    guard let rate = RecordingFrameRate(numerator: numerator, denominator: denominator) else {
      throw DecodingError.dataCorruptedError(forKey: .rateNumerator, in: c, debugDescription: "Unsupported recording frame rate")
    }
    let label = try c.decode(String.self, forKey: .label)
    guard let parsed = Self(label: label, frameRate: rate, epoch: try c.decode(CMTimeEpoch.self, forKey: .epoch)) else {
      throw DecodingError.dataCorruptedError(forKey: .label, in: c, debugDescription: "Invalid SMPTE timecode label")
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(label, forKey: .label)
    try c.encode(frameRate.rateNumerator, forKey: .rateNumerator)
    try c.encode(frameRate.rateDenominator, forKey: .rateDenominator)
    try c.encode(frameNumber, forKey: .frameNumber); try c.encode(epoch, forKey: .epoch); try c.encode(dropFrame, forKey: .dropFrame)
  }

  public init?(label: String, frameRate: RecordingFrameRate, epoch: CMTimeEpoch = 0) {
    guard let parsed = RecordingTimecode(string: label, frameRate: frameRate) else { return nil }
    self.label = parsed.stringValue
    self.frameRate = frameRate
    self.frameNumber = parsed.frameNumber
    self.epoch = epoch
    self.dropFrame = parsed.dropFrame
  }

  public init(timecode: RecordingTimecode, epoch: CMTimeEpoch = 0) {
    self.label = timecode.stringValue
    self.frameRate = timecode.frameRate
    self.frameNumber = timecode.frameNumber
    self.epoch = epoch
    self.dropFrame = timecode.dropFrame
  }

  /// Parses the native RP188/QuickTime spelling and preserves its DF/NDF flag.
  public static func native(label: String, frameRate: RecordingFrameRate,
                            epoch: CMTimeEpoch = 0) -> Self? {
    Self(label: label, frameRate: frameRate, epoch: epoch)
  }

  /// Returns the frame number at `offset`, retaining the source's 24-hour wrap.
  public func frameNumber(at offset: CMTime) -> Int64? {
    guard offset.isValid, offset.isNumeric, offset.epoch == epoch,
      offset.timescale > 0 else { return nil }
    let frames = (Double(offset.value) * Double(frameRate.rateNumerator) /
      Double(offset.timescale) / Double(frameRate.rateDenominator)).rounded()
    guard frames.isFinite, abs(frames) <= Double(Int64.max - abs(frameNumber)) else { return nil }
    return RecordingTimecode(frameNumber: frameNumber + Int64(frames),
      frameRate: frameRate, dropFrame: dropFrame).frameNumber
  }

  /// The normalized native label after advancing by a media offset.
  public func label(at offset: CMTime) -> String? {
    guard let value = frameNumber(at: offset) else { return nil }
    return RecordingTimecode(frameNumber: value, frameRate: frameRate,
      dropFrame: dropFrame).stringValue
  }
}
