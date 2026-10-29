import CoreMedia

/// Source ownership and transport demand are independent of the UI selection.
enum FeedLifecycleDemandPolicy {
  static func programTransportRequired(programMode: Bool, cameraRequested: Bool,
                                       onAirProducerRunning: Bool) -> Bool {
    programMode && cameraRequested && onAirProducerRunning
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

  static func canEditTopology(loading: Bool, sourceActive: Bool, recordingActive: Bool) -> Bool {
    !loading && !sourceActive && !recordingActive
  }

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
