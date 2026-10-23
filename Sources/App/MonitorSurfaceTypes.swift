import Foundation

// App-owned monitor identity and diagnostics (integration map §6.3). The names
// are the ones MonitorTools used, so the main actor's code reads the same; no
// app file imports MonitorTools' UI or runtime any more.

/// A monitor target: a camera feed's raw ID, or "program". Encodes as its raw
/// string, the same JSON as before.
struct MonitorTargetID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
  let rawValue: String
  var id: String { rawValue }
  init(rawValue: String) { self.rawValue = rawValue }
  init(_ rawValue: String) { self.rawValue = rawValue }

  static let program = MonitorTargetID(MonitorFeedHost.programTarget)
  var isProgram: Bool { rawValue == MonitorFeedHost.programTarget }
}

/// A target a monitor tile or window can show.
struct MonitorTargetOption: Identifiable, Hashable, Sendable {
  var id: MonitorTargetID
  var title: String
  var isAvailable: Bool
  init(id: MonitorTargetID, title: String, isAvailable: Bool = true) {
    self.id = id
    self.title = title
    self.isAvailable = isAvailable
  }
}

enum MonitorAvailability: Equatable, Sendable {
  case noSignal, starting, live, paused, stale
  case unsupported(String)
  case degraded(String)
  case failed(String)
}

/// Per-target monitoring counters. Rates are per second over the last window.
/// Nothing in the monitor skips frames: a source frame that is never shown was
/// replaced by a newer one before the display refreshed (`supersededFrames`).
struct MonitorDiagnostics: Equatable, Sendable {
  /// Frames the producer offered and the rate they arrived at.
  var offeredFrames: UInt64 = 0
  var offeredFPS: Double = 0
  /// New frames presented on screen, and their rate.
  var presentedFrames: UInt64 = 0
  var pictureFPS: Double = 0
  /// Frames replaced by a newer frame before any display refresh took them.
  var supersededFrames: UInt64 = 0
  var scopeFPS: Double = 0
  /// Scope updates that were due but not drawn: the GPU still had earlier scopes
  /// in flight (busy), or the scope layer gave no drawable for a whole scope
  /// interval (or for 0.5 s, when the frame waiting for it is dropped). Scopes are
  /// analysis; the picture never waits for them.
  var scopeSkippedBusy: UInt64 = 0
  var scopeSkippedNoDrawable: UInt64 = 0
  var pictureAge: Double?
  var scopeAge: Double?
  var requestedPictureHz = 60.0
  var requestedScopeHz = 15
  /// Mean GPU time per presented picture and per scope update, in milliseconds.
  var gpuMilliseconds: Double?
  var scopeGPUMilliseconds: Double?
  /// Encode or GPU failures; each is shown, never silently dropped.
  var failures: UInt64 = 0
  var availability: MonitorAvailability = .noSignal
  /// Where the target's monitor-only LUT file stands; a failed load is shown.
  var monitorLUT: MonitorFeedHost.MonitorLUTState = .none
  init() {}
}

/// Counters for one surface. Rates are refreshed about once a second.
struct MonitorSurfaceStatistics: Equatable, Sendable {
  /// Display refreshes the picture's display link offered (drawn or not).
  var refreshes: UInt64 = 0
  var acceptedFrames: UInt64 = 0
  var presentedFrames: UInt64 = 0
  /// Frames replaced by a newer one before any display refresh took them.
  var supersededFrames: UInt64 = 0
  var scopeUpdates: UInt64 = 0
  /// Scope updates that were due but not drawn: the previous scopes were still on
  /// the GPU (busy), or the scope layer gave no drawable for a whole scope interval.
  var scopeSkippedBusy: UInt64 = 0
  var scopeSkippedNoDrawable: UInt64 = 0
  var failures: UInt64 = 0
  var acceptedFPS = 0.0
  var presentedFPS = 0.0
  var scopeFPS = 0.0
  /// Mean GPU milliseconds over the last window.
  var pictureGPUMilliseconds: Double?
  var scopeGPUMilliseconds: Double?
  var lastPresented: MonitorFeedHost.Stamp?
  var lastScope: MonitorFeedHost.Stamp?
  var lastFailure: String?
  init() {}
}
