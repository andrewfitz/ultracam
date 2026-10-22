import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import MonitorToolsCore
import MonitorToolsMetal
import MonitorToolsUI

/// MonitorTools' capture-side endpoint. Unused since the surfaces moved to
/// MonitorKit (`MonitorFeedHost`, `MonitorSurfacePresenter`); it stays only
/// because CaptureController's MonitorTools bridge (`extension MonitorCaptureSink:
/// MonitorFrameSink`) still names it. Delete both together. The app's own
/// `MonitorTargetID` and `MonitorSurfacePresenter` shadow MonitorTools' names, so
/// those are qualified here.
final class MonitorCaptureSink: @unchecked Sendable {
  private static let generationLock = NSLock()
  nonisolated(unsafe) private static var nextGeneration: UInt64 = 0
  private let lock = NSLock()
  let target: MonitorToolsCore.MonitorTargetID
  private var configuration = MonitorConfiguration()
  private var consumers: [MonitorToolsUI.MonitorSurfacePresenter] = []
  private var captureGeneration: UInt64?
  private var rejectedCaptureGeneration: UInt64?
  private var generation: UInt64 = 0
  private var revision: UInt64 = 1
  private var processingRevision: UInt64 = 0
  /// Drops this target's cached GPU textures when the sink is invalidated.
  private let runtime: MonitorRuntime?
  private struct SignalIdentity: Equatable {
    let sourceGeometry: MonitorGeometry
    let outputGeometry: MonitorGeometry?
    let sourceSignal: MonitorFrameSignal
    let outputSignal: MonitorFrameSignal?
  }
  private var signalIdentity: SignalIdentity?
  /// The last source and output signals, reused while the buffer's color
  /// tags, format, profile and processing revision are unchanged.
  private var sourceInterpretation: Interpretation?
  private var outputInterpretation: Interpretation?
  /// Geometry per pooled IOSurface. Core Video rebuilds a dictionary
  /// attachment (clean aperture, pixel aspect) on every read, so they are read
  /// once per surface, size, format and processing revision, and again after
  /// the capture generation changes. Steady state reads nothing that allocates.
  private struct GeometryKey: Hashable {
    let surface: IOSurfaceID
    let width: Int
    let height: Int
    let format: OSType
    let processingRevision: UInt64
  }
  private var geometries: [GeometryKey: MonitorGeometry] = [:]
  private static let geometryCacheLimit = 32
  private var lastSourcePTS: CMTime?
  private var sourceFrameHz = 0.0
  private var offered: UInt64 = 0
  private var rateWindow = (start: 0.0, offered: UInt64(0))
  private var offeredFPS = 0.0

  init(target: MonitorToolsCore.MonitorTargetID, runtime: MonitorRuntime? = nil) {
    self.target = target
    self.runtime = runtime
  }

  /// The camera frame rate measured from picture timestamps. Zero until two
  /// frames have arrived.
  var observedSourceFrameHz: Double {
    lock.lock()
    defer { lock.unlock() }
    return sourceFrameHz
  }

  /// Frames offered to live surfaces, and their rate over the last second.
  var offerStatistics: (frames: UInt64, fps: Double) {
    lock.lock()
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    if now - rateWindow.start >= 1 {
      if rateWindow.start > 0 {
        offeredFPS = Double(offered - rateWindow.offered) / (now - rateWindow.start)
      }
      rateWindow = (now, offered)
    }
    return (offered, offeredFPS)
  }

  func configure(
    _ value: MonitorConfiguration, consumers: [MonitorToolsUI.MonitorSurfacePresenter], scopeVisible: Bool
  ) {
    lock.lock()
    let activeChanged = self.consumers.isEmpty != consumers.isEmpty
    var effective = value.normalized()
    effective.scopes.enabled = value.scopes.enabled && scopeVisible
    if target.rawValue == "program" {
      effective.pictureStage = .processedOutput
      effective.scopeStage = .processedOutput
    }
    if configuration != effective || activeChanged { revision &+= 1 }
    configuration = effective
    self.consumers = consumers
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
    revision &+= 1
    geometries.removeAll(keepingCapacity: true)
    lock.unlock()
    // The stopped generation's frames are gone; so are their textures.
    runtime?.flushTextures(for: target)
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
  /// Otherwise the paired Output offer supplies both buffers from the same frame.
  func offer(
    source: CVPixelBuffer, output: CVPixelBuffer?, pts: CMTime,
    captureGeneration: UInt64, sequence: UInt64, processingRevision: UInt64,
    sourceOnly: Bool, correspondence: MonitorCorrespondence? = nil
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    defer { lock.unlock() }
    guard !consumers.isEmpty else { return }
    if let rejectedCaptureGeneration, captureGeneration <= rejectedCaptureGeneration { return }
    let config = configuration
    let requiresOutput =
      config.pictureStage == .processedOutput
      || (config.toolsEnabled && config.scopes.enabled && config.scopeStage == .processedOutput)
    guard sourceOnly != requiresOutput else { return }
    if self.captureGeneration != captureGeneration {
      Self.generationLock.lock()
      Self.nextGeneration &+= 1
      generation = Self.nextGeneration
      Self.generationLock.unlock()
      self.captureGeneration = captureGeneration
      geometries.removeAll(keepingCapacity: true)
    }
    self.processingRevision = processingRevision
    let sourceSignal = Self.interpret(
      source, cache: &sourceInterpretation, profile: config.sourceProfileID,
      rangeOverride: config.sourceCodeRange, processingRevision: processingRevision)
    let outputSignal = output.map {
      Self.interpret(
        $0, cache: &outputInterpretation, profile: nil, rangeOverride: nil,
        processingRevision: processingRevision)
    }
    let sourceGeometry = cachedGeometry(source, processingRevision: processingRevision)
    let outputGeometry = output.map { cachedGeometry($0, processingRevision: processingRevision) }
    let identity = SignalIdentity(
      sourceGeometry: sourceGeometry, outputGeometry: outputGeometry,
      sourceSignal: sourceSignal, outputSignal: outputSignal)
    if signalIdentity != identity {
      signalIdentity = identity
      revision &+= 1
    }
    noteSourceFrameRate(pts)
    offered &+= 1
    let stamp = MonitorFrameStamp(
      target: target, generation: generation, sequence: sequence,
      sourcePTS: pts.seconds, hostTime: now, configurationRevision: revision,
      processingRevision: processingRevision)
    let bundle = MonitorFrameBundle(
      stamp: stamp, source: source, output: output,
      sourceGeometry: sourceGeometry, outputGeometry: outputGeometry,
      correspondence: correspondence, sourceSignal: sourceSignal, outputSignal: outputSignal)
    // Under the sink lock, so a configure() that removes a surface cannot race
    // a frame into it. accept() only swaps a slot; it never calls back here.
    for presenter in consumers { presenter.accept(bundle, configuration: config) }
  }

  /// Records the camera interval from every offered frame's timestamp.
  private func noteSourceFrameRate(_ pts: CMTime) {
    guard pts.isNumeric, pts.epoch == 0 else { return }
    if let lastSourcePTS, lastSourcePTS.isNumeric {
      let delta = CMTimeSubtract(pts, lastSourcePTS).seconds
      if delta > 0, delta.isFinite { sourceFrameHz = 1 / delta }
    }
    lastSourcePTS = pts
  }

  /// A buffer's color tags. Core Video returns these as interned constant
  /// strings: reading only retains them, and comparing is identity or CFEqual.
  private struct ColorTags {
    let matrix: CFTypeRef?
    let transfer: CFTypeRef?
    let primaries: CFTypeRef?
    init(_ image: CVPixelBuffer) {
      matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil)
      transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil)
      primaries = CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil)
    }
    func matches(_ other: ColorTags) -> Bool {
      Self.same(matrix, other.matrix) && Self.same(transfer, other.transfer)
        && Self.same(primaries, other.primaries)
    }
    private static func same(_ a: CFTypeRef?, _ b: CFTypeRef?) -> Bool {
      switch (a, b) {
      case (nil, nil): return true
      case let (a?, b?): return a === b || CFEqual(a, b)
      default: return false
      }
    }
  }

  private struct Interpretation {
    let tags: ColorTags
    let format: OSType
    let processingRevision: UInt64
    let profile: String?
    let rangeOverride: MonitorCodeRange?
    let signal: MonitorFrameSignal
  }

  /// The cached signal while nothing it depends on changed; otherwise a fresh
  /// one (which may allocate), cached for the next frame.
  private static func interpret(
    _ image: CVPixelBuffer, cache: inout Interpretation?, profile: String?,
    rangeOverride: MonitorCodeRange?, processingRevision: UInt64
  ) -> MonitorFrameSignal {
    let tags = ColorTags(image)
    let format = CVPixelBufferGetPixelFormatType(image)
    if let cached = cache, cached.format == format,
      cached.processingRevision == processingRevision, cached.profile == profile,
      cached.rangeOverride == rangeOverride, cached.tags.matches(tags)
    {
      return cached.signal
    }
    let value = signal(format: format, tags: tags, profile: profile, rangeOverride: rangeOverride)
    cache = Interpretation(
      tags: tags, format: format, processingRevision: processingRevision, profile: profile,
      rangeOverride: rangeOverride, signal: value)
    return value
  }

  /// Called with the lock held.
  private func cachedGeometry(_ image: CVPixelBuffer, processingRevision: UInt64)
    -> MonitorGeometry
  {
    guard let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
      return Self.geometry(image)
    }
    let key = GeometryKey(
      surface: IOSurfaceGetID(surface), width: CVPixelBufferGetWidth(image),
      height: CVPixelBufferGetHeight(image), format: CVPixelBufferGetPixelFormatType(image),
      processingRevision: processingRevision)
    if let cached = geometries[key] { return cached }
    let value = Self.geometry(image)
    if geometries.count >= Self.geometryCacheLimit { geometries.removeAll(keepingCapacity: true) }
    geometries[key] = value
    return value
  }

  static func geometry(_ image: CVPixelBuffer) -> MonitorGeometry {
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    var aperture: MonitorRect?
    if let values = dictionary(CVBufferCopyAttachment(image, kCVImageBufferCleanApertureKey, nil)),
      let w = number(values, kCVImageBufferCleanApertureWidthKey),
      let h = number(values, kCVImageBufferCleanApertureHeightKey)
    {
      let x = number(values, kCVImageBufferCleanApertureHorizontalOffsetKey) ?? 0
      let y = number(values, kCVImageBufferCleanApertureVerticalOffsetKey) ?? 0
      aperture = MonitorRect(
        x: (Double(width) - w) / 2 + x, y: (Double(height) - h) / 2 - y, width: w, height: h)
    }
    var pixelAspect = 1.0
    if let values = dictionary(
      CVBufferCopyAttachment(image, kCVImageBufferPixelAspectRatioKey, nil)),
      let h = number(values, kCVImageBufferPixelAspectRatioHorizontalSpacingKey),
      let v = number(values, kCVImageBufferPixelAspectRatioVerticalSpacingKey), v > 0
    {
      pixelAspect = h / v
    }
    return MonitorGeometry(
      width: width, height: height, cleanAperture: aperture, pixelAspectRatio: pixelAspect)
  }

  private static func dictionary(_ value: CFTypeRef?) -> CFDictionary? {
    guard let value, CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
    return unsafeBitCast(value, to: CFDictionary.self)
  }

  /// A CFNumber value of `dictionary` read in place, without bridging.
  private static func number(_ dictionary: CFDictionary, _ key: CFString) -> Double? {
    guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque())
    else { return nil }
    let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
    var result = 0.0
    guard CFNumberGetValue(unsafeBitCast(value, to: CFNumber.self), .float64Type, &result)
    else { return nil }
    return result
  }

  static func signal(
    _ image: CVPixelBuffer, profile: String?, rangeOverride: MonitorCodeRange? = nil
  ) -> MonitorFrameSignal {
    signal(
      format: CVPixelBufferGetPixelFormatType(image), tags: ColorTags(image),
      profile: profile, rangeOverride: rangeOverride)
  }

  private static func signal(
    format: OSType, tags: ColorTags, profile: String?, rangeOverride: MonitorCodeRange?
  ) -> MonitorFrameSignal {
    var coefficients = MonitorYCbCrMatrix.bt709
    if let matrix = tags.matrix {
      if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
        coefficients = .bt2020
      } else if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
        coefficients = .bt601
      }
    }
    let full: Bool
    switch format {
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
      full = true
    default:
      full = false
    }
    let transfer = tags.transfer as? String
    return MonitorFrameSignal(
      range: rangeOverride ?? (full ? .full : .legal), matrix: coefficients,
      transfer: profile ?? transfer ?? "Unknown", profileID: profile,
      primaries: tags.primaries as? String, transferFunction: transfer)
  }
}
