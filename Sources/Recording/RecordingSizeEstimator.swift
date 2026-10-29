import CoreMedia
import Foundation

/// Nominal encoded disk rate, separate from uncompressed buffer retention.
/// Content-dependent codecs can vary; a measured take rate supersedes this estimate.
public struct RecordingSizeEstimator: Sendable, Equatable {
  public enum Codec: Sendable { case proResLT, proRes422, proRes422HQ, proRes4444, hevcMain, hevcMain10, hevcMain10_422 }
  public let bytesPerSecond: Double
  public var megabitsPerSecond: Double { bytesPerSecond * 8 / 1_000_000 }

  public init?(codec: Codec, width: Int, height: Int, frameDuration: CMTime, bitDepth: Int = 10) {
    guard width > 0, height > 0, (bitDepth == 8 || bitDepth == 10 || bitDepth == 12),
      frameDuration.isNumeric, frameDuration.epoch == 0,
      frameDuration.value > 0, frameDuration.timescale > 0 else { return nil }
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow else { return nil }
    let bytesPerPixel: Double
    switch codec { case .proResLT: bytesPerPixel = 0.21; case .proRes4444: bytesPerPixel = 0.67; case .hevcMain: bytesPerPixel = 0.10; case .hevcMain10: bytesPerPixel = 0.12; case .proRes422: bytesPerPixel = 0.30; case .proRes422HQ: bytesPerPixel = 0.444; case .hevcMain10_422: bytesPerPixel = 0.15 }
    guard codec == .hevcMain || bitDepth >= 10 else { return nil }
    let rate = Double(pixels) * Double(frameDuration.timescale) / Double(frameDuration.value) * bytesPerPixel
    guard rate.isFinite, rate > 0, rate < Double(Int64.max) else { return nil }
    bytesPerSecond = rate
  }

  public func bytes(for duration: TimeInterval) -> Int64? {
    guard duration.isFinite, duration >= 0 else { return nil }
    let bytes = (bytesPerSecond * duration).rounded(.up)
    guard bytes.isFinite, bytes < Double(Int64.max) else { return nil }
    return Int64(bytes)
  }
  public func seconds(availableBytes: Int64) -> TimeInterval? {
    guard availableBytes >= 0 else { return nil }
    return Double(availableBytes) / bytesPerSecond
  }
}
