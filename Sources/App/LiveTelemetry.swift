import CoreMedia
import Foundation
import Observation

// Slow session state and fast telemetry are published apart.
//
// `AppModel.cameraUpdates` and `RecordingModel.feeds` tell their observers (the window's
// root, the side columns, the menus) only when something the session shows as state
// changes: a signal, a format, a message, a take's status or failure. The values that
// change with every update (timecode, levels, frame counters, a take's clock, size and
// rate, free space) go to the per-camera `UICameraTelemetry` objects, which only the small
// views that draw those values read (`UILiveCamera`, `UILiveSession`). So a capture update
// (4 Hz per camera) or a take's statistics (2 Hz) re-evaluate a timecode, a clock or a
// readout, and never the window, its split view or its columns.

/// One camera's fast-changing values, as revisions: a view that shows them reads the
/// revision (so Observation ties it to this camera alone) and the current values from the
/// models. Observed only by the views that show them.
@MainActor @Observable final class UICameraTelemetry {
  /// Bumped with every capture update: timecode, audio levels, frame and drop counters (4 Hz while capturing).
  fileprivate(set) var capture: UInt64 = 0
  /// Bumped when a take's statistics change: clock, size, rate, drops (2 Hz while recording).
  fileprivate(set) var statistics: UInt64 = 0
}

/// Every camera's telemetry, made on first use.
@MainActor final class UITelemetryStore {
  private var cameras: [FeedID: UICameraTelemetry] = [:]

  func camera(_ id: FeedID) -> UICameraTelemetry {
    if let existing = cameras[id] { return existing }
    let made = UICameraTelemetry()
    cameras[id] = made
    return made
  }

  func captureChanged(_ id: FeedID) { camera(id).capture &+= 1 }
  func statisticsChanged(_ id: FeedID) { camera(id).statistics &+= 1 }
}

/// What of a capture update the interface shows as state, rather than as a running value.
/// A change here is published to every observer of `AppModel.cameraUpdates`; a change
/// only outside it (timecode, levels, counters, rates) goes to the camera's telemetry.
struct CaptureUpdateState: Equatable {
  var message: String
  var input: String
  var output: String
  var sourceDuration: CMTime?
  var pipelineEnabledApplied: Bool?
  var hasFrames: Bool
  var previewDelivered: Bool
  var audioPresent: Bool
  var cameraOutputActive: Bool
  var cameraMessage: String
  var stopped: Bool

  init(_ update: CaptureUpdate) {
    message = update.message
    input = update.input
    output = update.output
    sourceDuration = update.sourceDuration
    pipelineEnabledApplied = update.pipelineEnabledApplied
    hasFrames = update.frames > 0
    previewDelivered = update.previewDelivered
    audioPresent = update.audioPresent
    cameraOutputActive = update.cameraOutputActive
    cameraMessage = update.cameraMessage
    stopped = update.stopped
  }
}

/// What of a take's statistics the interface shows as state: whether it is under way,
/// failed, warned or dropped frames. The clock, size and rate are telemetry.
struct RecordingStatisticsState: Equatable {
  var present: Bool
  var waitingForVideo: Bool
  var dropped: Bool
  var failed: Bool
  var lastError: String?
  var warning: String?
  var fileURL: URL?

  init(_ statistics: RecordingStatistics?) {
    present = statistics != nil
    waitingForVideo = statistics?.encodedFrames == 0
    dropped = (statistics?.droppedVideoFrames ?? 0) > 0
    failed = statistics?.failed == true
    lastError = statistics?.lastError
    warning = statistics?.warning
    fileURL = statistics?.fileURL
  }
}
