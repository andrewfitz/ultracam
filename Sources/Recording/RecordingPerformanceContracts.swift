import CoreMedia
import Foundation

/// Storage layouts used at the recording boundary. These values describe the
/// bytes retained by a source pixel buffer before compression; they do not
/// claim an encoded file bitrate.
public enum RecordingPixelStorage: String, Equatable, Sendable {
  case packedV210
  case biPlanar42210
  case nv12
}

/// A deterministic memory and ingress-bandwidth budget for one or more feeds.
/// Keeping this arithmetic beside the recording contracts prevents a queue
/// limit expressed in frames from hiding a multi-hundred-megabyte allocation.
public struct RecordingPerformanceBudget: Equatable, Sendable {
  public let storage: RecordingPixelStorage
  public let width: Int
  public let height: Int
  public let frameDuration: CMTime
  public let feedCount: Int
  public let queueFramesPerFeed: Int

  public init?(storage: RecordingPixelStorage, width: Int, height: Int,
    frameDuration: CMTime, feedCount: Int = 1, queueFramesPerFeed: Int = 0) {
    guard width > 0, height > 0, feedCount > 0, queueFramesPerFeed >= 0,
      frameDuration.isValid, frameDuration.isNumeric, frameDuration.value > 0,
      frameDuration.timescale > 0, frameDuration.epoch == 0 else { return nil }
    if storage == .nv12 && (!width.isMultiple(of: 2) || !height.isMultiple(of: 2)) { return nil }
    self.storage = storage
    self.width = width
    self.height = height
    self.frameDuration = frameDuration
    self.feedCount = feedCount
    self.queueFramesPerFeed = queueFramesPerFeed
  }

  /// Active media bytes in one retained pixel buffer.
  public var bytesPerFrame: Int64? {
    let pixels = Int64(width).multipliedReportingOverflow(by: Int64(height))
    guard !pixels.overflow else { return nil }
    switch storage {
    case .packedV210:
      // Avoid overflowing the width while rounding up to a six-pixel v210
      // group. The initializer intentionally accepts very large dimensions
      // so callers can query the budget without allocating a buffer.
      let (roundedWidth, widthOverflow) = width.addingReportingOverflow(5)
      guard !widthOverflow else { return nil }
      let groups = roundedWidth / 6
      let row = Int64(groups).multipliedReportingOverflow(by: 16)
      guard !row.overflow else { return nil }
      let total = row.partialValue.multipliedReportingOverflow(by: Int64(height))
      return total.overflow ? nil : total.partialValue
    case .biPlanar42210:
      let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
      return bytes.overflow ? nil : bytes.partialValue
    case .nv12:
      // NV12 is 12 bits per pixel, represented as 3 bytes per 2 pixels.
      let bytes = pixels.partialValue.multipliedReportingOverflow(by: 3)
      return bytes.overflow ? nil : bytes.partialValue / 2
    }
  }

  /// Uncompressed ingress rate for all configured feeds, rounded up so a
  /// storage admission check never underestimates the required bandwidth.
  public var aggregateBytesPerSecond: Int64? {
    guard let bytesPerFrame, frameDuration.value > 0 else { return nil }
    let numerator = bytesPerFrame.multipliedReportingOverflow(by: Int64(frameDuration.timescale))
    guard !numerator.overflow else { return nil }
    let feedBytes = numerator.partialValue.multipliedReportingOverflow(by: Int64(feedCount))
    guard !feedBytes.overflow else { return nil }
    let denominator = frameDuration.value
    guard denominator > 0 else { return nil }
    let quotient = feedBytes.partialValue / denominator
    return feedBytes.partialValue % denominator == 0 ? quotient : quotient + 1
  }

  /// Native bytes retained by the configured admission queues across feeds.
  public var retainedQueueBytes: Int64? {
    guard let bytesPerFrame else { return nil }
    let frameCount = Int64(queueFramesPerFeed).multipliedReportingOverflow(by: Int64(feedCount))
    guard !frameCount.overflow else { return nil }
    let bytes = bytesPerFrame.multipliedReportingOverflow(by: frameCount.partialValue)
    return bytes.overflow ? nil : bytes.partialValue
  }

  public var isTwoFeed: Bool { feedCount == 2 }
}

/// Drop counters that can be reported without conflating queue pressure with
/// invalid media or a stopped recorder. A zero total is the only lossless
/// state; appended and encoded counts remain separate telemetry concerns.
public struct RecordingDropSummary: Equatable, Sendable {
  public let queueFull: UInt64
  public let paused: UInt64
  public let notRecording: UInt64
  public let invalidSample: UInt64
  public let writerNotReady: UInt64
  public let appendFailure: UInt64

  public init(queueFull: UInt64 = 0, paused: UInt64 = 0, notRecording: UInt64 = 0,
    invalidSample: UInt64 = 0, writerNotReady: UInt64 = 0, appendFailure: UInt64 = 0) {
    self.queueFull = queueFull
    self.paused = paused
    self.notRecording = notRecording
    self.invalidSample = invalidSample
    self.writerNotReady = writerNotReady
    self.appendFailure = appendFailure
  }

  public var total: UInt64 {
    // Saturate rather than wrap: wrapping to zero would incorrectly report an
    // overflowing set of drops as lossless.
    [queueFull, paused, notRecording, invalidSample, writerNotReady, appendFailure]
      .reduce(UInt64.zero) { total, value in total > UInt64.max - value ? UInt64.max : total + value }
  }

  public var isLossless: Bool { total == 0 }
}

extension SourceRecordingTelemetry {
  /// A stable recording-specific view of drop telemetry for diagnostics and
  /// qualification. It intentionally does not infer loss from asynchronous
  /// enqueued/appended counts while work is still in flight.
  var performanceDropSummary: RecordingDropSummary {
    RecordingDropSummary(queueFull: droppedQueueFull, paused: droppedPaused,
      notRecording: droppedNotRecording, invalidSample: droppedInvalidSample,
      writerNotReady: droppedWriterNotReady, appendFailure: droppedAppendFailure)
  }

  var isPerformanceLossless: Bool { performanceDropSummary.isLossless }
}
