import Darwin
import Foundation

final class RecordingSessionClock: @unchecked Sendable {
  private let lock = NSLock()
  private let now: @Sendable () -> TimeInterval
  private var activeSince: TimeInterval?
  private var accumulated: TimeInterval = 0
  init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.now = now
    activeSince = now()
  }
  func pause() {
    lock.withLock {
      if let start = activeSince { accumulated += max(0, now() - start) }
      activeSince = nil
    }
  }
  func resume() { lock.withLock { if activeSince == nil { activeSince = now() } } }
  var elapsed: TimeInterval {
    lock.withLock { accumulated + (activeSince.map { max(0, now() - $0) } ?? 0) }
  }
}

struct RecordingStatistics: Equatable, Sendable {
  var elapsed: TimeInterval = 0
  var fileBytes: UInt64 = 0
  var encodedFrames: UInt64 = 0
  var droppedVideoFrames: UInt64 = 0
  var droppedAudioPackets: UInt64 = 0
  var encoderErrors: UInt64 = 0
  var writerErrors: UInt64 = 0
  var queueSamples: Int = 0
  var queueCapacity: Int = 0
  var encoderPendingFrames: Int = 0
  var framesPerSecond: Double = 0
  var videoMegabitsPerSecond: Double = 0
  var encoderLatencyMS: Double?
  var maxEncoderLatencyMS: Double?
  var hardwareEncoder: Bool?
  var encoderID: String?
  var failed = false
  var lastError: String?
  /// Something a healthy take should show (never its error), such as frames
  /// VideoToolbox converted on the CPU or frames the device skipped.
  var warning: String?
  var fileURL: URL?
  /// How frames reach the encoder (e.g. "x422 (GPU repack from v210)"), and
  /// how many VideoToolbox had to convert on the CPU (zero on the GPU route).
  var encoderInput: String?
  var cpuConvertedFrames: UInt64 = 0
  /// Frames the capture device skipped during the take (part of `droppedVideoFrames`).
  var deviceSkippedFrames: UInt64 = 0
  /// Encoded media waiting for the disk, and the limit before the take fails.
  var writerBufferedBytes = 0
  var writerBufferCapacityBytes = 0

  var elapsedText: String {
    let seconds = Int(max(0, elapsed))
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }
  var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: fileBytes), countStyle: .file) }
}

/// Sampling uses cumulative counters so a delayed UI refresh cannot change the
/// totals. FPS and bitrate are interval values, not whole-app or lifetime estimates.
struct RecordingStatisticsSampler: Sendable {
  private var previousTime: TimeInterval?
  private var previousFrames: UInt64 = 0
  private var previousBytes: UInt64 = 0
  mutating func sample(_ source: SourceRecordingTelemetry, elapsed: TimeInterval,
    fileBytes: UInt64, fileURL: URL?, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
    stopped: Bool = false) -> RecordingStatistics {
    let interval = previousTime.map { max(0, now - $0) } ?? 0
    let fps = interval > 0 ? Double(source.encodedVideo >= previousFrames ? source.encodedVideo - previousFrames : 0) / interval : 0
    let rate = interval > 0 ? Double(source.encodedVideoBytes >= previousBytes ? source.encodedVideoBytes - previousBytes : 0) * 8 / interval / 1_000_000 : 0
    previousTime = now
    previousFrames = source.encodedVideo
    previousBytes = source.encodedVideoBytes
    return RecordingStatistics(elapsed: elapsed, fileBytes: fileBytes, encodedFrames: source.encodedVideo,
      droppedVideoFrames: source.droppedVideo + source.droppedEncodedVideo,
      droppedAudioPackets: source.droppedAudio, encoderErrors: source.encoderErrors,
      writerErrors: source.writerErrors, queueSamples: source.queueSamples, queueCapacity: source.queueCapacity,
      encoderPendingFrames: source.encoderPendingFrames, framesPerSecond: stopped ? 0 : fps,
      videoMegabitsPerSecond: stopped ? 0 : rate, encoderLatencyMS: source.encoderLatencyMS,
      maxEncoderLatencyMS: source.maxEncoderLatencyMS, hardwareEncoder: source.hardwareEncoder,
      encoderID: source.encoderID, failed: source.state == .failed, lastError: source.lastError,
      warning: source.warning, fileURL: fileURL,
      encoderInput: source.encoderInputFormat, cpuConvertedFrames: source.cpuConvertedFrames,
      deviceSkippedFrames: source.deviceSkippedFrames,
      writerBufferedBytes: source.writerBufferedBytes,
      writerBufferCapacityBytes: source.writerBufferCapacityBytes)
  }
}
