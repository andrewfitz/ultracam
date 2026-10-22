import CoreMedia
import CoreVideo
import Foundation
import MonitorToolsCore
import MonitorToolsMetal
import MonitorToolsUI

/// A capture-side endpoint. Offers never visit AppKit or the main actor.
final class MonitorCaptureSink: @unchecked Sendable {
  private static let generationLock = NSLock()
  nonisolated(unsafe) private static var nextGeneration: UInt64 = 0
  private let lock = NSLock()
  private let runtime: MonitorRuntime
  private let criticalPipelineProducer: MonitorCriticalPipelineProducer
  let target: MonitorTargetID
  private var configuration = MonitorConfiguration()
  private var consumers: [MonitorSurfacePresenter] = []
  private var captureGeneration: UInt64?
  private var rejectedCaptureGeneration: UInt64?
  private var generation: UInt64 = 0
  private var revision: UInt64 = 1
  private var processingRevision: UInt64 = 0
  private struct SignalIdentity: Equatable {
    let sourceGeometry: MonitorGeometry
    let outputGeometry: MonitorGeometry?
    let sourceRange: String
    let sourceMatrix: String
    let sourceTransfer: String
    let outputRange: String?
    let outputMatrix: String?
    let outputTransfer: String?
  }
  private var signalIdentity: SignalIdentity?
  private var lastSequence: UInt64 = 0
  private var lastOfferTime = -Double.infinity
  private var lastSourcePTS: CMTime?
  private var sourceFrameHz = 0.0
  /// Nil accepts every camera frame. A number is only for scope analysis.
  private var preferredHz: Double?
  private var configurationNeedsUpdate = false

  init(target: MonitorTargetID, runtime: MonitorRuntime) {
    self.target = target
    self.runtime = runtime
    criticalPipelineProducer = runtime.makeCriticalPipelineProducer(target: target)
  }

  /// The camera frame rate measured from picture timestamps. Zero until two
  /// frames have arrived.
  var observedSourceFrameHz: Double {
    lock.lock()
    defer { lock.unlock() }
    return sourceFrameHz
  }

  func configure(
    _ value: MonitorConfiguration, consumers: [MonitorSurfacePresenter],
    scopeVisible: Bool, preferredHz: Double? = nil
  ) {
    lock.lock()
    let activeChanged = self.consumers.isEmpty != consumers.isEmpty
    var effective = value.normalized()
    effective.scopes.enabled = value.scopes.enabled && scopeVisible
    if target.rawValue == "program" {
      effective.pictureStage = .processedOutput
      effective.scopeStage = .processedOutput
    }
    if configuration != effective || activeChanged {
      revision &+= 1
      lastOfferTime = -.infinity
    }
    configuration = effective
    self.consumers = consumers
    if let preferredHz, preferredHz.isFinite, preferredHz > 0 {
      self.preferredHz = preferredHz
    } else {
      self.preferredHz = nil
    }
    if consumers.isEmpty {
      runtime.remove(target: target)
    } else {
      runtime.configure(
        target: target, generation: generation, configurationRevision: revision,
        configuration: effective, processingRevision: processingRevision)
    }
    configurationNeedsUpdate = false
    lock.unlock()
  }

  func invalidate(rejectingCaptureGeneration rejected: UInt64? = nil) {
    lock.lock()
    if let rejected {
      rejectedCaptureGeneration = max(rejectedCaptureGeneration ?? rejected, rejected)
    }
    if let captureGeneration {
      rejectedCaptureGeneration = max(
        rejectedCaptureGeneration ?? captureGeneration, captureGeneration)
    }
    captureGeneration = nil
    // No-argument coordinator invalidation stops the latest producer health
    // epoch, which can advance while visible frame offers are suspended.
    criticalPipelineProducer.stop(generation: rejected)
    revision &+= 1
    lastSequence = 0
    lastOfferTime = -.infinity
    runtime.remove(target: target)
    lock.unlock()
  }

  /// Timing metadata stays independent of visible monitor consumers. A hidden
  /// producer can still compete for the same GPU as another feed's monitoring.
  func reportCriticalPipeline(
    captureGeneration: UInt64, queueAge: Double, processingTime: Double,
    frameInterval: Double, now: Double
  ) {
    criticalPipelineProducer.record(generation: captureGeneration, queueAge: queueAge,
      processingTime: processingTime, frameInterval: frameInterval, now: now)
  }

  var needsOutput: Bool {
    // try() failing means the lock is busy, not that the consumer left.
    // Treating that as "no destination" drops the frame.
    guard lock.try() else { return true }
    defer { lock.unlock() }
    return !consumers.isEmpty
      && (configuration.pictureStage == .processedOutput
        || (configuration.toolsEnabled && configuration.scopes.enabled
          && configuration.scopeStage == .processedOutput))
  }

#if CAPTURE_LIFECYCLE_TESTS
  func withLockHeldForTesting(_ body: () -> Void) {
    lock.lock()
    body()
    lock.unlock()
  }
#endif

  /// The early source offer is used only when every requested signal is Source.
  /// Otherwise the atomic Output offer supplies both buffers from the same frame.
  func offer(
    source: CVPixelBuffer, output: CVPixelBuffer?, pts: CMTime,
    captureGeneration: UInt64, sequence: UInt64, processingRevision: UInt64,
    sourceOnly: Bool, correspondence: MonitorCorrespondence? = nil
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    guard lock.try() else { return }
    guard !consumers.isEmpty else {
      lock.unlock()
      return
    }
    if let rejectedCaptureGeneration, captureGeneration <= rejectedCaptureGeneration {
      lock.unlock()
      return
    }
    let generationChanged = self.captureGeneration != captureGeneration
    let processingChanged = self.processingRevision != processingRevision
    let sourceGeometry = Self.geometry(source)
    let outputGeometry = output.map(Self.geometry)
    let sourceSignal = Self.signal(
      source, profile: configuration.sourceProfileID,
      rangeOverride: configuration.sourceCodeRange)
    let outputSignal = output.map { Self.signal($0, profile: nil) }
    // Output metadata is compared only at its paired tap, not against the early
    // source-only offer (which intentionally has no output yet).
    let identity = SignalIdentity(
      sourceGeometry: sourceGeometry, outputGeometry: outputGeometry,
      sourceRange: sourceSignal.range.rawValue, sourceMatrix: sourceSignal.matrix.rawValue,
      sourceTransfer: sourceSignal.transfer, outputRange: outputSignal?.range.rawValue,
      outputMatrix: outputSignal?.matrix.rawValue, outputTransfer: outputSignal?.transfer)
    let routeMatches =
      sourceOnly
      != (configuration.pictureStage == .processedOutput
        || (configuration.toolsEnabled && configuration.scopes.enabled
          && configuration.scopeStage == .processedOutput))
    let signalChanged = routeMatches && signalIdentity != identity
    if signalChanged {
      signalIdentity = identity
      revision &+= 1
    }
    if generationChanged {
      guard Self.generationLock.try() else {
        lock.unlock()
        return
      }
      Self.nextGeneration &+= 1
      generation = Self.nextGeneration
      Self.generationLock.unlock()
      self.captureGeneration = captureGeneration
      lastSequence = 0
    }
    self.processingRevision = processingRevision
    let config = configuration
    if generationChanged || processingChanged || signalChanged || configurationNeedsUpdate {
      lastOfferTime = -.infinity
      configurationNeedsUpdate = true
      guard
        runtime.tryConfigure(
          target: target, generation: generation, configurationRevision: revision,
          configuration: config, processingRevision: processingRevision)
      else {
        lock.unlock()
        return
      }
      configurationNeedsUpdate = false
    }
    let requiresOutput =
      config.pictureStage == .processedOutput
      || (config.toolsEnabled && config.scopes.enabled && config.scopeStage == .processedOutput)
    guard sourceOnly != requiresOutput else {
      lock.unlock()
      return
    }
    noteSourceFrameRate(pts)
    if let preferredHz, now - lastOfferTime < 1 / preferredHz - 0.001 {
      lock.unlock()
      return
    }
    lastOfferTime = now
    let stamp = MonitorFrameStamp(
      target: target, generation: generation, sequence: sequence,
      sourcePTS: pts.seconds, hostTime: now, configurationRevision: revision,
      processingRevision: processingRevision)
    lock.unlock()

    let bundle = MonitorFrameBundle(
      stamp: stamp, source: source, output: output,
      sourceGeometry: sourceGeometry, outputGeometry: outputGeometry,
      correspondence: correspondence, sourceSignal: sourceSignal, outputSignal: outputSignal)
    let completion: @Sendable (Result<MonitorDisplayResult, Error>) -> Void = {
      [weak self] result in
      switch result {
      case .success(let display): self?.publish(display)
      case .failure: break  // Independent clean staging below remains available.
      }
    }
    if !runtime.offer(bundle, completion: completion) {
      _ = runtime.cleanPreview.offer(bundle, useOutput: config.pictureStage == .processedOutput) {
        result in
        completion(
          result.map {
            MonitorDisplayResult(
              clean: $0, decorated: nil, scope: nil, configuration: config,
              availability: config.needsAnalysis ? ["Monitoring busy — clean picture"] : [],
              pictureSignal: config.pictureStage == .source ? sourceSignal : outputSignal)
          })
      }
    }
  }

  /// Records the camera interval. The picture path calls this for every frame,
  /// including frames a scope cap later declines to analyze.
  private func noteSourceFrameRate(_ pts: CMTime) {
    guard pts.isNumeric, pts.epoch == 0 else { return }
    if let lastSourcePTS, lastSourcePTS.isNumeric {
      let delta = CMTimeSubtract(pts, lastSourcePTS).seconds
      if delta > 0, delta.isFinite { sourceFrameHz = 1 / delta }
    }
    lastSourcePTS = pts
  }

  private func publish(_ result: MonitorDisplayResult) {
    guard lock.try() else { return }
    let stamp = result.clean.stamp
    guard stamp.matches(target: target, generation: generation, configurationRevision: revision),
      stamp.processingRevision == processingRevision, stamp.sequence >= lastSequence,
      !consumers.isEmpty
    else {
      lock.unlock()
      return
    }
    lastSequence = stamp.sequence
    let recipients = consumers
    lock.unlock()
    recipients.forEach { presenter in
      presenter.accept(
        result,
        ifCurrent: { [weak self] in
          self?.canPublish(stamp, to: presenter) ?? false
        })
    }
  }

  /// Recheck at the presenter's final storage boundary: another completion or
  /// a visibility/configuration change may have overtaken the recipient snapshot.
  private func canPublish(_ stamp: MonitorFrameStamp, to presenter: MonitorSurfacePresenter) -> Bool
  {
    guard lock.try() else { return false }
    defer { lock.unlock() }
    return stamp.matches(target: target, generation: generation, configurationRevision: revision)
      && stamp.processingRevision == processingRevision && stamp.sequence >= lastSequence
      && consumers.contains { $0 === presenter }
  }

  static func geometry(_ image: CVPixelBuffer) -> MonitorGeometry {
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    var aperture: MonitorRect?
    if let values = CVBufferCopyAttachment(image, kCVImageBufferCleanApertureKey, nil)
      as? [String: Any],
      let w = values[kCVImageBufferCleanApertureWidthKey as String] as? NSNumber,
      let h = values[kCVImageBufferCleanApertureHeightKey as String] as? NSNumber
    {
      let x =
        (values[kCVImageBufferCleanApertureHorizontalOffsetKey as String] as? NSNumber)?.doubleValue
        ?? 0
      let y =
        (values[kCVImageBufferCleanApertureVerticalOffsetKey as String] as? NSNumber)?.doubleValue
        ?? 0
      aperture = MonitorRect(
        x: (Double(width) - w.doubleValue) / 2 + x,
        y: (Double(height) - h.doubleValue) / 2 - y, width: w.doubleValue, height: h.doubleValue)
    }
    var pixelAspect = 1.0
    if let values = CVBufferCopyAttachment(image, kCVImageBufferPixelAspectRatioKey, nil)
      as? [String: Any],
      let h = values[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber,
      let v = values[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber,
      v.doubleValue > 0
    {
      pixelAspect = h.doubleValue / v.doubleValue
    }
    return MonitorGeometry(
      width: width, height: height, cleanAperture: aperture,
      pixelAspectRatio: pixelAspect)
  }

  static func signal(
    _ image: CVPixelBuffer, profile: String?, rangeOverride: MonitorCodeRange? = nil
  ) -> MonitorFrameSignal {
    let matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) as? String
    let coefficients: MonitorYCbCrMatrix =
      matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
      ? .bt2020 : matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? .bt601 : .bt709
    let format = CVPixelBufferGetPixelFormatType(image)
    let full = [
      kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
    ].contains(format)
    let transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil) as? String
    return MonitorFrameSignal(
      range: rangeOverride ?? (full ? .full : .legal), matrix: coefficients,
      transfer: profile ?? transfer ?? "Unknown", profileID: profile)
  }
}
