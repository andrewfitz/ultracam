import Foundation

public struct MonitorFrameStamp: Hashable, Codable, Sendable {
  public var target: MonitorTargetID
  public var generation: UInt64
  public var sequence: UInt64
  public var sourcePTS: Double
  public var hostTime: Double
  public var configurationRevision: UInt64
  public var processingRevision: UInt64
  public init(
    target: MonitorTargetID, generation: UInt64, sequence: UInt64, sourcePTS: Double,
    hostTime: Double, configurationRevision: UInt64, processingRevision: UInt64 = 0
  ) {
    self.target = target
    self.generation = generation
    self.sequence = sequence
    self.sourcePTS = sourcePTS
    self.hostTime = hostTime
    self.configurationRevision = configurationRevision
    self.processingRevision = processingRevision
  }
  public func matches(target: MonitorTargetID, generation: UInt64, configurationRevision: UInt64)
    -> Bool
  {
    self.target == target && self.generation == generation
      && self.configurationRevision == configurationRevision
  }
}
public enum MonitorAvailability: Equatable, Sendable {
  case noSignal, starting, live, paused, stale
  case unsupported(String)
  case degraded(String)
  case failed(String)
}
/// Per-target monitoring counters. Rates are per second over the last window.
/// Nothing in the monitor skips frames: a source frame that is never shown
/// was replaced by a newer one before the display refreshed (`supersededFrames`).
public struct MonitorDiagnostics: Equatable, Sendable {
  /// Frames the producer offered and the rate they arrived at.
  public var offeredFrames: UInt64 = 0
  public var offeredFPS: Double = 0
  /// New frames presented on screen, and their rate.
  public var presentedFrames: UInt64 = 0
  public var pictureFPS: Double = 0
  /// Frames replaced by a newer frame before any display refresh took them.
  public var supersededFrames: UInt64 = 0
  public var scopeFPS: Double = 0
  /// Scope updates that were due but not drawn: the GPU still had earlier
  /// scopes in flight (busy), or the scope layer gave no drawable for a whole
  /// scope interval. Scopes are analysis; the picture never waits for them.
  public var scopeSkippedBusy: UInt64 = 0
  public var scopeSkippedNoDrawable: UInt64 = 0
  public var pictureAge: Double?
  public var scopeAge: Double?
  public var requestedPictureHz = 60.0
  public var requestedScopeHz = 15
  /// Mean GPU time per presented picture and per scope update, in milliseconds.
  public var gpuMilliseconds: Double?
  public var scopeGPUMilliseconds: Double?
  /// Encode or GPU failures; each is shown, never silently dropped.
  public var failures: UInt64 = 0
  public var availability: MonitorAvailability = .noSignal
  public init() {}
}
