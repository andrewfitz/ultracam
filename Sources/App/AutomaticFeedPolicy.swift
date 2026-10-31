import CoreMedia

/// Source ownership and transport demand are independent of the UI selection.
enum FeedLifecycleDemandPolicy {
  /// Any running camera keeps the sink open, not just the one on air: with none of its
  /// frames the client gets standby black, its format stays locked, and a cut or a move
  /// back on air doesn't have to reopen a device the client is holding.
  static func programTransportRequired(programMode: Bool, cameraRequested: Bool,
                                       anyCameraRunning: Bool) -> Bool {
    programMode && cameraRequested && anyCameraRunning
  }

  static func programContract(configuration: PipelineConfiguration, pipelineEnabled: Bool,
                              detectedSourceDuration: CMTime?) -> PipelineConfiguration {
    var result = configuration
    if !pipelineEnabled {
      result.applyLUT = false
      result.downscale = false
      result.convertTo420 = false
      result.reduceFrameRate = false
    }
    if let duration = detectedSourceDuration,
       duration.isNumeric, duration.epoch == 0, CMTimeCompare(duration, .zero) > 0 {
      result.sourceDuration = duration
    }
    return result
  }

  static func canStartSource(automaticEnabled: Bool, manuallyStopped: Bool, deviceAvailable: Bool, loading: Bool) -> Bool {
    automaticEnabled && !manuallyStopped && deviceAvailable && !loading
  }

  /// Reset wipes every setting and quits, so it alone still needs the whole app idle.
  static func canResetSettings(loading: Bool, sourceActive: Bool, recordingActive: Bool) -> Bool {
    !loading && !sourceActive && !recordingActive
  }

  /// One camera's removal waits on that camera alone: the others can run and record.
  static func canRemoveCamera(cameraCount: Int, loading: Bool, sourceActive: Bool, recordingActive: Bool) -> Bool {
    cameraCount > 1 && !loading && !sourceActive && !recordingActive
  }

  /// Every camera is a device, and so is Program, inside the extension's device limit.
  static let maximumCameras = VirtualCameraRegistryWire.maximumDevices - 1

  static func canAddCamera(enabledCameras: Int) -> Bool { enabledCameras < maximumCameras }

  static func retainsAutomaticOwnership(automaticEnabled: Bool, wasAutomaticallyStarted: Bool) -> Bool {
    automaticEnabled && wasAutomaticallyStarted
  }
}

// Attempt a start once while either preview or camera apps need capture.
// Repeated notifications must never create an automatic retry loop.
struct AutomaticFeedPolicy {
  enum Action: Equatable { case start, stop }
  private(set) var requested = false
  private(set) var previewRequested = false
  var captureRequested: Bool { requested || previewRequested }
  private var attempted = false

  mutating func demand(_ requested: Bool) {
    let wasRequested = captureRequested
    self.requested = requested
    if wasRequested != captureRequested { attempted = false }
  }

  mutating func previewDemand(_ requested: Bool) {
    let wasRequested = captureRequested
    previewRequested = requested
    if wasRequested != captureRequested { attempted = false }
  }

  mutating func retry() { attempted = false }

  mutating func action(ready: Bool, running: Bool) -> Action? {
    if !captureRequested { return running ? .stop : nil }
    guard ready, !running, !attempted else { return nil }
    attempted = true
    return .start
  }
}
