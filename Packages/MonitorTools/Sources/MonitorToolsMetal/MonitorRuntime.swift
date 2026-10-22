import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Metal
import MonitorToolsCore

public final class MonitorScopeResult: @unchecked Sendable {
  public let texture: MTLTexture
  public let stamp: MonitorFrameStamp
  public let mode: MonitorScopeMode
  public let signal: MonitorFrameSignal?
  public let samplingStride: Int
  public let samplingPhase: Int
  public let minimumIRE = -10.0
  public let maximumIRE = 110.0
  private let lease: MonitorResourceLease
  init(
    texture: MTLTexture, stamp: MonitorFrameStamp, mode: MonitorScopeMode,
    lease: MonitorResourceLease, signal: MonitorFrameSignal? = nil, samplingStride: Int = 2,
    samplingPhase: Int = 0
  ) {
    self.texture = texture
    self.stamp = stamp
    self.mode = mode
    self.lease = lease
    self.signal = signal
    self.samplingStride = samplingStride
    self.samplingPhase = samplingPhase
  }
}
public struct MonitorDisplayResult: @unchecked Sendable {
  public let clean: MonitorOwnedFrame
  public let decorated: MonitorOwnedFrame?
  public let scope: MonitorScopeResult?
  public let configuration: MonitorConfiguration
  public let availability: [String]
  public let pictureSignal: MonitorFrameSignal?
  public init(
    clean: MonitorOwnedFrame, decorated: MonitorOwnedFrame? = nil, scope: MonitorScopeResult? = nil,
    configuration: MonitorConfiguration, availability: [String] = [],
    pictureSignal: MonitorFrameSignal? = nil
  ) {
    self.clean = clean
    self.decorated = decorated
    self.scope = scope
    self.configuration = configuration
    self.availability = availability
    self.pictureSignal = pictureSignal
  }
}
private enum MonitorResourceRetirement {
  static let queue = DispatchQueue(label: "MonitorTools.retirement", qos: .utility)
}
private final class AnalysisInputLease: @unchecked Sendable {
  var frame: MonitorFrameBundle?
  init(_ frame: MonitorFrameBundle) { self.frame = frame }
}
private enum PreparedAnalysis {
  case discarded
  case gpu(MTLCommandBuffer)
  case delivery(Result<MonitorDisplayResult, Error>, MonitorResourceLease?)
}
private final class WorkingSet: @unchecked Sendable {
  let key: [Int]
  let memory: MonitorResourceLease
  let nonFocusBytes: Int
  let maximumBytes: Int
  let expectedFocusWidth: Int
  let expectedFocusHeight: Int
  var focusAllowance: Int
  var buffers: [MTLBuffer?] = [nil, nil, nil]
  var focus: MTLTexture?
  var bins: MTLBuffer?
  init(
    key: [Int], memory: MonitorResourceLease, nonFocusBytes: Int, maximumBytes: Int,
    focusWidth: Int, focusHeight: Int
  ) {
    self.key = key
    self.memory = memory
    self.nonFocusBytes = nonFocusBytes
    self.maximumBytes = maximumBytes
    self.expectedFocusWidth = focusWidth
    self.expectedFocusHeight = focusHeight
    self.focusAllowance = maximumBytes - nonFocusBytes
  }
  deinit {
    let resources = ResourceBox((buffers, focus, bins, memory))
    MonitorResourceRetirement.queue.async { withExtendedLifetime(resources) {} }
  }
}
private final class ResourceBox<T>: @unchecked Sendable {
  let value: T
  init(_ value: T) { self.value = value }
}
/// Metadata-only rounds give every active feed a turn before repeating a cohort.
/// There is no queued source frame; rejected callers retry with their next frame.
final class MonitorAnalysisFairAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var targets: [(MonitorTargetID, Double)] = []
  private var eligible: Set<MonitorTargetID> = []
  private var active: Set<MonitorTargetID> = []
  private var seen: Set<MonitorTargetID> = []
  func tryBegin(_ target: MonitorTargetID, capacity: Int) -> Bool {
    guard capacity > 0, lock.try() else { return false }
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    targets.removeAll { now - $0.1 > 0.5 && !active.contains($0.0) }
    if let index = targets.firstIndex(where: { $0.0 == target }) {
      targets[index].1 = now
    } else {
      targets.append((target, now))
    }
    guard !active.contains(target), active.count < capacity else { return false }
    if eligible.isEmpty || seen.contains(target) {
      let cohort = Array(targets.filter { !active.contains($0.0) }.prefix(capacity - active.count))
      eligible = Set(cohort.map { $0.0 })
      targets.removeAll { eligible.contains($0.0) }
      targets.append(contentsOf: cohort)
      seen.removeAll(keepingCapacity: true)
    }
    seen.insert(target)
    guard eligible.contains(target) else { return false }
    active.insert(target)
    eligible.remove(target)
    return true
  }
  func complete(_ target: MonitorTargetID) {
    // A capture-side failed ledger acquisition must not block. At most capacity
    // completion records can wait here because active entries remain occupied.
    guard lock.try() else {
      MonitorResourceRetirement.queue.async { self.complete(target) }
      return
    }
    active.remove(target)
    lock.unlock()
  }
}
final class AnalysisJob: @unchecked Sendable {
  private let lock = NSLock()
  private var lease: MonitorResourceLease?
  private var expired = false
  private var timeoutAction: (@Sendable () -> Void)?
  private let target: MonitorTargetID
  private let fairness: MonitorAnalysisFairAdmission
  init(
    _ lease: MonitorResourceLease, target: MonitorTargetID, fairness: MonitorAnalysisFairAdmission
  ) {
    self.lease = lease
    self.target = target
    self.fairness = fairness
  }
  var deadlineExceeded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return expired
  }
  func armDeadline(after seconds: Double = 0.25, action: @escaping @Sendable () -> Void) {
    lock.lock()
    timeoutAction = action
    lock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let action = self.lease != nil ? self.timeoutAction : nil
      if action != nil { self.expired = true }
      self.timeoutAction = nil
      self.lock.unlock()
      action?()
    }
  }
  @discardableResult func release() -> Bool {
    lock.lock()
    let held = lease
    let deadlineWon = expired
    lease = nil
    timeoutAction = nil
    lock.unlock()
    if let held {
      held.release()
      fairness.complete(target)
    }
    return deadlineWon
  }
  deinit { release() }
}
final class RuntimeTelemetry: @unchecked Sendable {
  struct Entry {
    var policy = MonitorAdaptivePolicy()
    var accumulator = MonitorDiagnosticsAccumulator()
    var offers = 0, admissions = 0, skips = 0, rejected = 0
    var pressured = false
    var requestedScopeHz = 15
    var picture: MonitorFrameStamp?, scope: MonitorFrameStamp?
    var quality = MonitorEffectiveQuality()
    var diagnostic = MonitorDiagnostics()
  }
  private let lock = NSLock()
  private var entries: [MonitorTargetID: Entry] = [:]
  private var lastPublication = -Double.infinity
  func record(
    _ target: MonitorTargetID, offer: Bool = false, admission: Bool = false,
    skip: Bool = false, pressure: Bool = false, rejected: Bool = false,
    picture: MonitorFrameStamp? = nil, scope: MonitorFrameStamp? = nil, requestedScopeHz: Int? = nil
  ) {
    guard lock.try() else { return }
    var entry = entries[target] ?? Entry()
    if offer { entry.offers += 1 }
    if admission { entry.admissions += 1 }
    if skip { entry.skips += 1 }
    if rejected { entry.rejected += 1 }
    entry.pressured = entry.pressured || pressure
    if let picture {
      entry.accumulator.recordPicture(picture, now: ProcessInfo.processInfo.systemUptime)
    }
    if let scope { entry.accumulator.recordScope(scope, now: ProcessInfo.processInfo.systemUptime) }
    if let requestedScopeHz { entry.requestedScopeHz = requestedScopeHz }
    entries[target] = entry
    lock.unlock()
  }
  func quality(_ target: MonitorTargetID, requested: Int) -> MonitorEffectiveQuality {
    guard lock.try() else { return MonitorEffectiveQuality(requestedScopeHz: requested) }
    defer { lock.unlock() }
    return MonitorEffectiveQuality(
      tier: entries[target]?.policy.tier ?? .nominal, requestedScopeHz: requested)
  }
  func diagnostic(_ target: MonitorTargetID) -> MonitorDiagnostics {
    lock.lock()
    defer { lock.unlock() }
    return entries[target]?.diagnostic ?? MonitorDiagnostics()
  }
  func remove(_ target: MonitorTargetID) {
    lock.lock()
    entries.removeValue(forKey: target)
    lock.unlock()
  }
  func tick(
    now: Double, budget: @autoclosure () -> MonitorAdmissionSnapshot,
    critical: MonitorCriticalPipelineState = MonitorCriticalPipelineState(phase: .nominal)
  ) -> [(
    MonitorTargetID, MonitorDiagnostics
  )] {
    lock.lock()
    defer { lock.unlock() }
    let publish = now - lastPublication >= 1
    let currentBudget = publish ? budget() : nil
    var results: [(MonitorTargetID, MonitorDiagnostics)] = []
    for target in Array(entries.keys) {
      guard var entry = entries[target] else { continue }
      entry.policy.configure(requestedScopeHz: entry.requestedScopeHz)
      entry.quality = entry.policy.observe(now: now, pressured: entry.pressured)
      entry.pressured = false
      for _ in 0..<entry.offers { entry.accumulator.recordOffer(now: now) }
      for _ in 0..<entry.admissions { entry.accumulator.recordAdmission(now: now) }
      for _ in 0..<entry.skips { entry.accumulator.recordSkip() }
      for _ in 0..<entry.rejected { entry.accumulator.recordRejectedResult() }
      if let picture = entry.picture { entry.accumulator.recordPicture(picture, now: now) }
      if let scope = entry.scope { entry.accumulator.recordScope(scope, now: now) }
      entry.offers = 0
      entry.admissions = 0
      entry.skips = 0
      entry.rejected = 0
      entry.picture = nil
      entry.scope = nil
      if publish {
        entry.diagnostic = entry.accumulator.snapshot(
          now: now, budget: currentBudget!, quality: entry.quality,
          requestedScopeHz: entry.requestedScopeHz)
        critical.apply(to: &entry.diagnostic)
        results.append((target, entry.diagnostic))
      }
      entries[target] = entry
    }
    if publish { lastPublication = now }
    return results
  }
}
private final class MetalContext {
  let device: MTLDevice, queue: MTLCommandQueue
  let focus: MTLComputePipelineState, compose: MTLComputePipelineState,
    scopes: MTLComputePipelineState, scopeImage: MTLComputePipelineState
  var cache: CVMetalTextureCache?
  init(device: MTLDevice, source: String?) throws {
    self.device = device
    guard let queue = device.makeCommandQueue() else {
      throw MonitorPreviewError.shadersUnavailable
    }
    self.queue = queue
    let shader: String
    if let source {
      shader = source
    } else {
      guard let url = Bundle.module.url(forResource: "MonitorTools", withExtension: "metal.txt")
      else { throw MonitorPreviewError.shadersUnavailable }
      shader = try String(contentsOf: url, encoding: .utf8)
    }
    let options = MTLCompileOptions()
    options.mathMode = .safe
    let library = try device.makeLibrary(source: shader, options: options)
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      guard let f = library.makeFunction(name: name) else {
        throw MonitorPreviewError.shadersUnavailable
      }
      return try device.makeComputePipelineState(function: f)
    }
    focus = try pipeline("sourceFocus")
    compose = try pipeline("compose")
    scopes = try pipeline("scopes")
    scopeImage = try pipeline("scopeImage")
    guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
      throw MonitorPreviewError.allocationFailed
    }
  }
}
/// Lazy asynchronous analysis. Callbacks execute on the utility worker/GPU completion queue.
public final class MonitorRuntime: @unchecked Sendable {
  public var resourceStatistics: MonitorResourceStatistics {
    resourceCounters.snapshot(pool: compositePool.statsSnapshot())
  }
  private let resourceCounters = MonitorResourceCounters()
  private let compositePool: MonitorCompositePool
  private let fairness = MonitorAnalysisFairAdmission()
  private let telemetry = RuntimeTelemetry()
  private let criticalPipelines = MonitorCriticalPipelineRegistry()
  private var telemetryTimer: DispatchSourceTimer?
  private let onDiagnostics: @Sendable (MonitorTargetID, MonitorDiagnostics) -> Void
  public let ledger: MonitorAdmissionLedger
  public let cleanPreview: CleanPreviewService
  private let lock = NSLock(), worker = DispatchQueue(label: "MonitorTools.analysis", qos: .utility)
  private let delivery = DispatchQueue(
    label: "MonitorTools.analysis-delivery", qos: .utility, attributes: .concurrent)
  private var sessions: [MonitorTargetID: (UInt64, UInt64, MonitorConfiguration, UInt64)] = [:]
  private var scopeCache: [MonitorTargetID: MonitorScopeResult] = [:]
  private var evictionPending = false
  private var idleWork: [MonitorTargetID: WorkingSet] = [:]
  private var scopePhases: [MonitorTargetID: UInt32] = [:]
  private var scopeTimes: [MonitorTargetID: Double] = [:]
  private let deviceProvider: () -> MTLDevice?
  private let shaderSource: String?
  private let gpuTiming: @Sendable (Double, Double) -> Void
  private var context: MetalContext?, initializationFailed = false
  public init(
    ledger: MonitorAdmissionLedger = MonitorAdmissionLedger(
      maximumAnalysisJobs: 3, maximumCleanCopyJobs: 4),
    sharedDevice: @escaping () -> MTLDevice? = { MTLCreateSystemDefaultDevice() },
    shaderSource: String? = nil,
    gpuTiming: @escaping @Sendable (Double, Double) -> Void = { _, _ in },
    onDiagnostics: @escaping @Sendable (MonitorTargetID, MonitorDiagnostics) -> Void = { _, _ in }
  ) {
    self.ledger = ledger
    self.compositePool = MonitorCompositePool(ledger: ledger)
    self.cleanPreview = CleanPreviewService(budget: ledger)
    self.deviceProvider = sharedDevice
    self.shaderSource = shaderSource
    self.gpuTiming = gpuTiming
    self.onDiagnostics = onDiagnostics
    let timer = DispatchSource.makeTimerSource(queue: worker)
    timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(25))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      for (target, diagnostic) in telemetry.tick(
        now: ProcessInfo.processInfo.systemUptime, budget: ledger.snapshot,
        critical: criticalPipelines.snapshot())
      {
        self.onDiagnostics(target, diagnostic)
      }
    }
    telemetryTimer = timer
    timer.resume()
  }
  deinit { telemetryTimer?.cancel() }
  public func makeCriticalPipelineProducer(target: MonitorTargetID)
    -> MonitorCriticalPipelineProducer
  {
    criticalPipelines.makeProducer(target: target)
  }
  public func diagnostics(for target: MonitorTargetID) -> MonitorDiagnostics {
    var value = telemetry.diagnostic(target)
    criticalPipelines.snapshot().apply(to: &value)
    return value
  }
  public func recordPresentationGPUTime(start: Double, end: Double) {
    if end > start { gpuTiming(start, end) }
  }
  public func configure(
    target: MonitorTargetID, generation: UInt64, configurationRevision: UInt64,
    configuration: MonitorConfiguration, processingRevision: UInt64 = 0
  ) {
    lock.lock()
    applyConfiguration(
      target: target, generation: generation, configurationRevision: configurationRevision,
      configuration: configuration, processingRevision: processingRevision)
  }
  /// Capture-safe metadata update. Retry on a later offer when contention returns false.
  @discardableResult public func tryConfigure(
    target: MonitorTargetID, generation: UInt64, configurationRevision: UInt64,
    configuration: MonitorConfiguration, processingRevision: UInt64 = 0
  ) -> Bool {
    guard lock.try() else { return false }
    applyConfiguration(
      target: target, generation: generation, configurationRevision: configurationRevision,
      configuration: configuration, processingRevision: processingRevision)
    return true
  }
  /// Called with metadata lock held; unlocks before scheduling utility retirement.
  private func applyConfiguration(
    target: MonitorTargetID, generation: UInt64, configurationRevision: UInt64,
    configuration: MonitorConfiguration, processingRevision: UInt64
  ) {
    let old = sessions.updateValue(
      (generation, configurationRevision, configuration.normalized(), processingRevision),
      forKey: target)
    var retiredScope: MonitorScopeResult?
    var retiredWork: WorkingSet?
    if old?.0 != generation || old?.1 != configurationRevision || old?.3 != processingRevision {
      retiredScope = scopeCache.removeValue(forKey: target)
      scopeTimes.removeValue(forKey: target)
      scopePhases.removeValue(forKey: target)
      retiredWork = idleWork.removeValue(forKey: target)
    }
    lock.unlock()
    if let old, old.0 != generation || old.1 != configurationRevision || old.3 != processingRevision {
      worker.async { [compositePool] in compositePool.trim() }
    }
    if retiredScope != nil || retiredWork != nil || (old != nil && old?.0 != generation) {
      let retirement = ResourceBox((retiredScope, retiredWork))
      MonitorResourceRetirement.queue.async { [ledger] in
        if let old, old.0 != generation { ledger.retire(target: target, generation: old.0) }
        withExtendedLifetime(retirement) {}
      }
    }
  }
  public func remove(target: MonitorTargetID) {
    lock.lock()
    let old = sessions.removeValue(forKey: target)
    let retired = ResourceBox(
      (scopeCache.removeValue(forKey: target), idleWork.removeValue(forKey: target)))
    scopeTimes.removeValue(forKey: target)
    scopePhases.removeValue(forKey: target)
    lock.unlock()
    worker.async { [telemetry, compositePool] in
      telemetry.remove(target)
      compositePool.trim()
    }
    MonitorResourceRetirement.queue.async { [ledger] in
      if let old { ledger.retire(target: target, generation: old.0) }
      withExtendedLifetime(retired) {}
    }
  }
  /// True once the frame's target was removed or restarted with a new generation.
  /// Only then is in-flight work dropped and cached composite storage released.
  /// A configuration revision change or a busy lock is not a reason: rebuilding
  /// the pool on the next frame made the picture stutter and the scope go blank.
  private func generationRetired(_ stamp: MonitorFrameStamp) -> Bool {
    guard lock.try() else { return false }
    defer { lock.unlock() }
    guard let s = sessions[stamp.target] else { return true }
    return stamp.generation != s.0
  }
  private func current(_ stamp: MonitorFrameStamp) -> MonitorConfiguration? {
    guard lock.try() else { return nil }
    defer { lock.unlock() }
    guard let s = sessions[stamp.target],
      stamp.matches(target: stamp.target, generation: s.0, configurationRevision: s.1),
      stamp.processingRevision == s.3
    else { return nil }
    return s.2
  }
  private func evictIdleWork() {
    lock.lock()
    var released = idleWork
    idleWork.removeAll()
    lock.unlock()
    released.removeAll()
    compositePool.trim()
  }
  private func requestIdleEviction() {
    guard lock.try() else { return }
    guard !evictionPending else {
      lock.unlock()
      return
    }
    evictionPending = true
    lock.unlock()
    worker.async { [self] in
      evictIdleWork()
      lock.lock()
      evictionPending = false
      lock.unlock()
    }
  }
  private static func stagingBytes(_ input: CVPixelBuffer) -> Int {
    let planes = CVPixelBufferGetPlaneCount(input)
    let stride =
      planes == 0
      ? CVPixelBufferGetBytesPerRow(input) : CVPixelBufferGetBytesPerRowOfPlane(input, 0)
    let rows =
      CVPixelBufferGetHeight(input) + (planes > 1 ? CVPixelBufferGetHeightOfPlane(input, 1) : 0)
    return max(CVPixelBufferGetDataSize(input), stride * rows)
  }
  private static func signal(
    _ frame: MonitorFrameBundle, configuration: MonitorConfiguration, stage: MonitorStage
  ) -> MonitorFrameSignal? {
    if stage == .processedOutput, frame.output != nil, frame.output !== frame.source {
      return frame.outputSignal
    }
    return frame.sourceSignal.map {
      MonitorFrameSignal(
        range: configuration.sourceCodeRange ?? $0.range, matrix: $0.matrix, transfer: $0.transfer,
        profileID: $0.profileID)
    }
  }
  @discardableResult public func offer(
    _ frame: MonitorFrameBundle,
    completion: @escaping @Sendable (Result<MonitorDisplayResult, Error>) -> Void
  ) -> Bool {
    guard let config = current(frame.stamp) else { return false }
    telemetry.record(frame.stamp.target, offer: true, requestedScopeHz: config.scopes.refreshHz)
    let critical = criticalPipelines.snapshot()
    let quality = critical.cap(
      telemetry.quality(frame.stamp.target, requested: config.scopes.refreshHz),
      requestedScopeHz: config.scopes.refreshHz)
    let deliver = completion
    let completion: @Sendable (Result<MonitorDisplayResult, Error>) -> Void = {
      [weak self] result in
      if case .success(let value) = result {
        self?.telemetry.record(
          value.clean.stamp.target, picture: value.clean.stamp, scope: value.scope?.stamp)
      }
      deliver(result)
    }
    guard config.needsAnalysis && critical.phase != .paused else {
      let stamp = frame.stamp
      let pictureSignal = Self.signal(frame, configuration: config, stage: config.pictureStage)
      let accepted = cleanPreview.offer(frame, useOutput: config.pictureStage == .processedOutput) {
        [weak self] result in
        if case .success(let clean) = result {
          self?.resourceCounters.record(cleanCopiedBytes: MonitorResourceCounters.imageBytes(clean.pixelBuffer))
        }
        guard self?.current(stamp) != nil else { return }
        completion(
          result.map {
            MonitorDisplayResult(
              clean: $0, decorated: nil, scope: nil, configuration: config,
              availability: critical.reason.map { [$0] } ?? [],
              pictureSignal: pictureSignal)
          })
      }
      telemetry.record(stamp.target, admission: accepted, skip: !accepted, pressure: !accepted)
      return accepted
    }
    guard fairness.tryBegin(frame.stamp.target, capacity: ledger.maximumAnalysisJobs) else {
      telemetry.record(frame.stamp.target, skip: true, pressure: true)
      return false
    }
    guard
      let jobLease = ledger.tryAcquire(
        target: frame.stamp.target, generation: frame.stamp.generation, kind: .analysis, bytes: 0)
    else {
      fairness.complete(frame.stamp.target)
      telemetry.record(frame.stamp.target, skip: true, pressure: true)
      return false
    }
    let job = AnalysisJob(jobLease, target: frame.stamp.target, fairness: fairness)
    let picture = config.pictureStage == .source ? frame.source : (frame.output ?? frame.source)
    let scopeInput = config.scopeStage == .source ? frame.source : (frame.output ?? frame.source)
    let w = CVPixelBufferGetWidth(picture)
    let h = CVPixelBufferGetHeight(picture)
    let scale = min(
      1.0,
      min(
        Double(quality.pictureHeightLimit) * 16 / 9 / Double(w),
        Double(quality.pictureHeightLimit) / Double(h)))
    let ow = max(1, Int(Double(w) * scale))
    let oh = max(1, Int(Double(h) * scale))
    let cleanBytes = CleanPreviewService.reservation(picture)
    let focusRequested = config.focus.enabled && frame.correspondence != nil
    let key =
      [frame.source, picture, scopeInput].flatMap {
        [
          CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0),
          Int(CVPixelBufferGetPixelFormatType($0)), CVPixelBufferGetBytesPerRow($0),
        ]
      } + [
        focusRequested ? 1 : 0, config.scopes.enabled ? 1 : 0, frame.source === picture ? 1 : 0,
        scopeInput === picture ? 1 : 0, scopeInput === frame.source ? 1 : 0,
      ]
    var borrowed: WorkingSet?
    if lock.try() {
      borrowed = idleWork.removeValue(forKey: frame.stamp.target)
      lock.unlock()
    }
    if borrowed?.key != key { borrowed = nil }
    let needed =
      [picture] + ((config.focus.enabled || config.falseColor.mode == .arri || config.falseColor.mode == .sonySLog3 || config.falseColor.mode == .elZone) ? [frame.source] : [])
      + (config.scopes.enabled ? [scopeInput] : [])
    let uniqueInputs = needed.enumerated().filter { index, value in
      !needed.prefix(index).contains { $0 === value }
    }.map { $0.element }
    let inputBytes: Int = uniqueInputs.reduce(64 * 1024) { $0 + Self.stagingBytes($1) + 4096 }
    let focusBytes: Int =
      focusRequested
      ? CVPixelBufferGetWidth(frame.source) * CVPixelBufferGetHeight(frame.source) * 2 + 65536
      : 65536
    let scopeBytes: Int = config.scopes.enabled ? 768 * 256 * 4 : 0
    let workBytes: Int = inputBytes + focusBytes + scopeBytes
    if borrowed == nil {
      if let lease = ledger.tryAcquire(
        target: frame.stamp.target, generation: frame.stamp.generation, kind: .presentation,
        bytes: workBytes)
      {
        borrowed = WorkingSet(
          key: key, memory: lease, nonFocusBytes: inputBytes + scopeBytes, maximumBytes: workBytes,
          focusWidth: focusRequested ? CVPixelBufferGetWidth(frame.source) : 1,
          focusHeight: focusRequested ? CVPixelBufferGetHeight(frame.source) : 1)
      } else {
        requestIdleEviction()
      }
    }
    guard let working = borrowed,
      let cleanMemory = ledger.tryAcquire(
        target: frame.stamp.target, generation: frame.stamp.generation, kind: .cleanPresentation,
        bytes: cleanBytes)
    else {
      requestIdleEviction()
      telemetry.record(frame.stamp.target, skip: true, pressure: true)
      MonitorResourceRetirement.queue.async { job.release() }
      return false
    }
    telemetry.record(frame.stamp.target, admission: true)
    let input = AnalysisInputLease(frame)
    let stamp = frame.stamp
    worker.async(execute: { @Sendable [self] in
      let prepared: PreparedAnalysis = autoreleasepool { () -> PreparedAnalysis in
        self.prepareAnalysis(
          frame: input.frame!, config: config, cleanBytes: cleanBytes,
          cleanMemory: cleanMemory, width: ow, height: oh, working: working, job: job,
          quality: quality, completion: completion)
      }
      // Neither command completion nor owned delivery captures input. Drop the only
      // producer borrow before committing GPU work or releasing the admission slot.
      input.frame = nil
      switch prepared {
      case .discarded:
        cleanMemory.release()
        job.release()
      case .gpu(let command):
        guard !self.generationRetired(stamp) else {
          job.release()
          self.compositePool.trim()
          return
        }
        command.commit()
      case .delivery(let result, let failedReservation):
        job.release()
        self.deliver(
          result, stamp: stamp, failedReservation: failedReservation, completion: completion)
      }
    })
    return true
  }
  private func prepareAnalysis(
    frame: MonitorFrameBundle, config: MonitorConfiguration,
    cleanBytes: Int, cleanMemory: MonitorResourceLease, width: Int, height: Int,
    working: WorkingSet, job: AnalysisJob, quality: MonitorEffectiveQuality,
    completion: @escaping @Sendable (Result<MonitorDisplayResult, Error>) -> Void
  ) -> PreparedAnalysis {
    guard !generationRetired(frame.stamp) else { return .discarded }
    let picture = config.pictureStage == .source ? frame.source : (frame.output ?? frame.source)
    let scopeInput = config.scopeStage == .source ? frame.source : (frame.output ?? frame.source)
    let pictureSignal = Self.signal(frame, configuration: config, stage: config.pictureStage)
    do {
      let cleanBuffer = try CleanPreviewService.copy(picture, reservation: cleanBytes)
      resourceCounters.record(cleanCopiedBytes: MonitorResourceCounters.imageBytes(cleanBuffer))
      let clean = MonitorOwnedFrame(
        stamp: frame.stamp, pixelBuffer: cleanBuffer,
        releaseBudget: { cleanMemory.release() })
      let critical = criticalPipelines.snapshot()
      if critical.phase == .paused {
        return .delivery(
          .success(
            MonitorDisplayResult(
              clean: clean, configuration: config,
              availability: critical.reason.map { [$0] } ?? [], pictureSignal: pictureSignal)), nil)
      }
      let quality = critical.cap(quality, requestedScopeHz: config.scopes.refreshHz)
      let scale = min(1, Double(quality.pictureHeightLimit) / Double(height))
      let effectiveWidth = max(1, Int(Double(width) * scale))
      let effectiveHeight = max(1, Int(Double(height) * scale))
      // One worker attempt per admitted frame; failures retry only on a later offer.
      if context == nil {
        do {
          guard let device = deviceProvider() else { throw MonitorPreviewError.shadersUnavailable }
          context = try MetalContext(device: device, source: shaderSource)
          initializationFailed = false
        } catch {
          initializationFailed = true
          recordPreparationPressure(error, target: frame.stamp.target)
        }
      }
      guard let context else {
        return .delivery(
          .success(
            MonitorDisplayResult(
              clean: clean, configuration: config,
              availability: ["Analysis unavailable: shader/device initialization failed"],
              pictureSignal: pictureSignal)), nil)
      }
      guard !generationRetired(frame.stamp) else { return .discarded }
      do {
        return .gpu(
          try submit(
            frame: frame, config: config, picture: picture, scopeInput: scopeInput,
            clean: clean, context: context, width: effectiveWidth, height: effectiveHeight,
            working: working,
            job: job,
            quality: quality, completion: completion))
      } catch {
        recordPreparationPressure(error, target: frame.stamp.target)
        return .delivery(
          .success(
            MonitorDisplayResult(
              clean: clean, configuration: config,
              availability: ["Analysis unavailable: \(error)"], pictureSignal: pictureSignal)), nil)
      }
    } catch {
      recordPreparationPressure(error, target: frame.stamp.target)
      // Error-only callbacks have no owned pixel buffer, so retain their reservation
      // explicitly until the consumer returns, just like the clean-copy service.
      return .delivery(.failure(error), cleanMemory)
    }
  }
  private func recordPreparationPressure(_ error: Error, target: MonitorTargetID) {
    switch error {
    case MonitorPreviewError.allocationFailed, is MonitorCompositePool.AllocationError:
      telemetry.record(target, pressure: true)
    default: break
    }
  }
  private func deliver(
    _ result: Result<MonitorDisplayResult, Error>, stamp: MonitorFrameStamp,
    failedReservation: MonitorResourceLease? = nil,
    completion: @escaping @Sendable (Result<MonitorDisplayResult, Error>) -> Void
  ) {
    delivery.async { [weak self] in
      defer { failedReservation?.release() }
      guard let self else { return }
      guard self.current(stamp) != nil else {
        if self.generationRetired(stamp) {
          self.worker.async { [compositePool = self.compositePool] in compositePool.trim() }
        }
        return
      }
      completion(result)
    }
  }
  private func cacheWorking(_ working: WorkingSet, stamp: MonitorFrameStamp) {
    lock.lock()
    if let session = sessions[stamp.target], session.0 == stamp.generation,
      session.1 == stamp.configurationRevision, session.3 == stamp.processingRevision
    {
      // Four stable feeds can reuse four sets while active producer/GPU jobs stay at three.
      if idleWork[stamp.target] == nil && idleWork.count >= 4, let victim = idleWork.keys.first {
        idleWork.removeValue(forKey: victim)
      }
      idleWork[stamp.target] = working
    }
    lock.unlock()
  }
  func cachedWorkingSetIdentities() -> [MonitorTargetID: ObjectIdentifier] {
    lock.lock()
    defer { lock.unlock() }
    return idleWork.mapValues { ObjectIdentifier($0) }
  }
  private func stage(
    _ input: CVPixelBuffer, context: MetalContext, reusing existing: MTLBuffer? = nil,
    owned: Bool = false, ownedFallback: CVPixelBuffer? = nil
  ) throws -> (MTLBuffer, KernelParameters, Bool) {
    let f = CVPixelBufferGetPixelFormatType(input)
    let format: UInt32
    switch f {
    case kCVPixelFormatType_422YpCbCr10: format = 0
    case kCVPixelFormatType_32BGRA: format = 1
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: format = 2
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: format = 3
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: format = 4
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: format = 5
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: format = 6
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: format = 7
    default: throw MonitorPreviewError.unsupportedFormat
    }
    let w = CVPixelBufferGetWidth(input)
    let h = CVPixelBufferGetHeight(input)
    let planes = CVPixelBufferGetPlaneCount(input)
    let stride =
      planes == 0
      ? CVPixelBufferGetBytesPerRow(input) : CVPixelBufferGetBytesPerRowOfPlane(input, 0)
    let minimum = format == 0 ? ((w + 5) / 6) * 16 : format == 1 ? w * 4 : (format >= 4 ? w * 2 : w)
    guard stride >= minimum, format < 2 ? planes == 0 : planes == 2 && w % 2 == 0 else {
      throw MonitorPreviewError.invalidLayout
    }
    let size = stride * h + (planes == 0 ? 0 : stride * (format >= 6 ? h : (h + 1) / 2))
    var params = KernelParameters()
    params.width = UInt32(w)
    params.height = UInt32(h)
    params.stride = UInt32(stride)
    params.format = format
    // Only the clean monitor copy is eligible. Producer buffers are always staged
    // before the borrow ends, and an aliased binding is never cached in WorkingSet.
    if owned, let binding = OwnedMetalInput.make(
      pixelBuffer: input, device: context.device, requiredLength: size)
    {
      resourceCounters.record(ownedInputBoundBytes: MonitorResourceCounters.imageBytes(input))
      return (binding, params, true)
    }
    if owned, let ownedFallback {
      // Keep the original producer's proven staging layout when the owned copy
      // cannot bind directly. This copy still finishes before GPU commit.
      return try stage(ownedFallback, context: context, reusing: existing)
    }
    guard
      let buffer = (existing?.length ?? 0) >= size
        ? existing : context.device.makeBuffer(length: size, options: .storageModeShared),
      CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess
    else { throw MonitorPreviewError.allocationFailed }
    defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
    if planes == 0 {
      guard let src = CVPixelBufferGetBaseAddress(input) else {
        throw MonitorPreviewError.invalidLayout
      }
      memcpy(buffer.contents(), src, stride * h)
    } else {
      for p in 0..<2 {
        let rows = CVPixelBufferGetHeightOfPlane(input, p)
        let srcStride = CVPixelBufferGetBytesPerRowOfPlane(input, p)
        guard let src = CVPixelBufferGetBaseAddressOfPlane(input, p), srcStride >= minimum,
          rows == (p == 0 || format >= 6 ? h : (h + 1) / 2),
          CVPixelBufferGetWidthOfPlane(input, p) == (p == 0 ? w : w / 2)
        else { throw MonitorPreviewError.invalidLayout }
        for y in 0..<rows {
          memcpy(
            buffer.contents().advanced(by: (p == 0 ? 0 : stride * h) + y * stride),
            src.advanced(by: y * srcStride), minimum)
        }
      }
    }
    resourceCounters.record(stagingCopiedBytes: MonitorResourceCounters.imageBytes(input))
    return (buffer, params, false)
  }
  private func submit(
    frame: MonitorFrameBundle, config: MonitorConfiguration, picture: CVPixelBuffer,
    scopeInput: CVPixelBuffer, clean: MonitorOwnedFrame, context: MetalContext, width: Int,
    height: Int, working: WorkingSet, job: AnalysisJob, quality: MonitorEffectiveQuality,
    completion: @escaping @Sendable (Result<MonitorDisplayResult, Error>) -> Void
  ) throws -> MTLCommandBuffer {
    let pictureSignal = Self.signal(frame, configuration: config, stage: config.pictureStage)
    let scopeSignal = Self.signal(frame, configuration: config, stage: config.scopeStage)
    guard let pictureSignal else { throw MonitorPreviewError.unsupportedFormat }
    lock.lock()
    let previousScope = scopeCache[frame.stamp.target]
    let scopePhase = scopePhases[frame.stamp.target] ?? 0
    let interval = 1.0 / Double(max(1, min(30, quality.scopeRefreshHz)))
    let previousDeadline = scopeTimes[frame.stamp.target] ?? frame.stamp.hostTime
    let due = frame.stamp.hostTime >= previousDeadline
    let updateScope = config.scopes.enabled && scopeSignal != nil && due
    let nextScopeDeadline =
      previousDeadline + max(1, floor((frame.stamp.hostTime - previousDeadline) / interval) + 1)
      * interval
    lock.unlock()
    let (pictureBuffer, p0, pictureBound) = try stage(
      clean.pixelBuffer, context: context, reusing: working.buffers[0], owned: true,
      ownedFallback: picture)
    let (sourceBuffer, s0, sourceBound) =
      (!config.focus.enabled && config.falseColor.mode != .arri && config.falseColor.mode != .sonySLog3 && config.falseColor.mode != .elZone
        && !(updateScope && scopeInput === frame.source)) || frame.source === picture
      ? (pictureBuffer, p0, pictureBound) : try stage(frame.source, context: context, reusing: working.buffers[1])
    let (scopeBuffer, q0, scopeBound) =
      !updateScope || scopeInput === picture
      ? (pictureBuffer, p0, pictureBound)
      : scopeInput === frame.source
        ? (sourceBuffer, s0, sourceBound) : try stage(scopeInput, context: context, reusing: working.buffers[2])
    working.buffers[0] = pictureBound ? nil : pictureBuffer
    if sourceBuffer !== pictureBuffer { working.buffers[1] = sourceBound ? nil : sourceBuffer }
    if scopeBuffer !== pictureBuffer && scopeBuffer !== sourceBuffer {
      working.buffers[2] = scopeBound ? nil : scopeBuffer
    }
    var p = p0
    var s = s0
    var q = q0
    func signal(_ signal: MonitorFrameSignal?, _ params: inout KernelParameters) {
      if let signal {
        let c = signal.matrix.coefficients
        params.coefficients = SIMD4(
          Float(c.r), Float(c.g), Float(c.b), signal.range == .full ? 1 : 0)
      }
    }
    signal(pictureSignal, &p)
    signal(frame.sourceSignal, &s)
    signal(scopeSignal, &q)
    if let range = config.sourceCodeRange {
      s.coefficients.w = range == .full ? 1 : 0
      if config.pictureStage == .source { p.coefficients.w = s.coefficients.w }
      if config.scopeStage == .source { q.coefficients.w = s.coefficients.w }
    }
    p.outWidth = UInt32(width)
    p.outHeight = UInt32(height)
    p.threshold = Float(config.zebra.thresholdIRE)
    p.widthIRE = Float(config.zebra.widthIRE)
    p.opacity = Float(config.zebra.opacity)
    p.flags = config.effectiveZebraEnabled ? MonitorKernelFlag.zebra : 0
    if config.zebra.mode == .band { p.flags |= MonitorKernelFlag.zebraBand }
    var statuses = criticalPipelines.snapshot().reason.map { [$0] } ?? []
    if config.scopes.enabled && scopeSignal == nil {
      statuses.append("Scopes unavailable: signal interpretation missing")
    }
    let correspondenceMapping = frame.correspondence.map {
      SIMD4<Float>(Float($0.scaleX), Float($0.scaleY), Float($0.offsetX), Float($0.offsetY))
    }
    let mappingValid: Bool = {
      guard let m = correspondenceMapping,
        [m.x, m.y, m.z, m.w].allSatisfy({ $0.isFinite }),
        abs(m.x) >= Float.leastNormalMagnitude, abs(m.y) >= Float.leastNormalMagnitude
      else { return false }
      // The shader uses Float inverse coordinates and footprints. A finite
      // Double declaration alone does not guarantee these operations are safe.
      let extent = SIMD2<Float>(Float(p.width), Float(p.height))
      let scale = SIMD2<Float>(m.x, m.y), offset = SIMD2<Float>(m.z, m.w)
      let low = -offset / scale, high = (extent - offset) / scale, span = extent / scale
      return [low.x, low.y, high.x, high.y, span.x, span.y].allSatisfy { $0.isFinite }
    }()
    let geometryValid = mappingValid &&
      frame.correspondence?.map(MonitorPoint(x: 0, y: 0)) != nil && frame.sourceGeometry.isValid
      && frame.sourceGeometry.width == CVPixelBufferGetWidth(frame.source)
      && frame.sourceGeometry.height == CVPixelBufferGetHeight(frame.source)
      && frame.sourceGeometry.orientation == .upright
      && (frame.outputGeometry?.orientation ?? .upright) == .upright
    let focusAllowed =
      geometryValid && frame.sourceSignal != nil && config.focus.enabled
      && frame.correspondence != nil && frame.stamp.target.rawValue != "program"
    if focusAllowed {
      p.flags |= MonitorKernelFlag.focus
    } else if config.focus.enabled {
      statuses.append("Focus unavailable: source correspondence is unqualified")
    }
    s.sourceLogRescaled = config.sourceLogMapping == .fullRescaledToLegal10Bit ? 1 : 0
    let arriProfile = config.falseColor.profileID.flatMap(ARRIFalseColorProfile.init(rawValue:))
    let sourceTransfer = frame.sourceSignal?.transfer.lowercased() ?? ""
    let sourceFalseColorQualified =
      geometryValid && (s.sourceLogRescaled == 0 || s.coefficients.w == 0)
      && frame.correspondence != nil
      && frame.stamp.target.rawValue != "program"
    let literalARRIAllowed =
      sourceFalseColorQualified && config.falseColor.mode == .arri && arriProfile != nil
      && frame.sourceSignal?.profileID == arriProfile?.rawValue
      && config.falseColor.exposureIndex == 800
    let sonyGamut = SonyARRIStyleFalseColor.gamut(forSourceProfileID: config.sourceProfileID)
    let sonyAllowed =
      sourceFalseColorQualified && config.falseColor.mode == .arri
      && config.falseColor.profileID == SonyARRIStyleFalseColor.profileID
      && sonyGamut != nil && frame.sourceSignal?.profileID == config.sourceProfileID
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3"))
    let sonyPatternAllowed = sourceFalseColorQualified && config.falseColor.mode == .sonySLog3
      && config.falseColor.profileID == SonySLog3FalseColor.profileID
      && config.falseColor.specificationVersion == SonySLog3FalseColor.specificationVersion
      && SonySLog3FalseColor.supports(sourceProfileID: config.sourceProfileID)
      && frame.sourceSignal?.profileID == config.sourceProfileID
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3"))
    let elZoneAllowed = sourceFalseColorQualified && config.falseColor.mode == .elZone
      && config.falseColor.profileID == ELZoneProfile.profileID
      && config.falseColor.specificationVersion == ELZoneProfile.specificationVersion
      && ELZoneProfile.supports(sourceProfileID: config.sourceProfileID)
      && frame.sourceSignal?.profileID == config.sourceProfileID
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3"))
    let arriAllowed = literalARRIAllowed || sonyAllowed || sonyPatternAllowed || elZoneAllowed
    let pictureGeometry =
      config.pictureStage == .source || frame.output == nil
      ? frame.sourceGeometry
      : (frame.outputGeometry
        ?? MonitorGeometry(
          width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture)))
    let pictureGeometrySupported =
      pictureGeometry.isValid && (0.0625...16).contains(pictureGeometry.pixelAspectRatio)
      && pictureGeometry.orientation == .upright
      && pictureGeometry.width == CVPixelBufferGetWidth(picture)
      && pictureGeometry.height == CVPixelBufferGetHeight(picture)
    let transfer = pictureSignal.transfer.lowercased()
    let knownLogProfile =
      frame.sourceSignal?.profileID.map {
        [
          "sony-slog3-sgamut3cine", "sony-slog3-sgamut3", ARRIFalseColorProfile.logC3EI800.rawValue,
          ARRIFalseColorProfile.alexa35LogC4EI800.rawValue,
        ].contains($0)
      } ?? false
    let pictureIsSource =
      config.pictureStage == .source || frame.output == nil || frame.output === frame.source
    let sourceCodeView =
      pictureIsSource && knownLogProfile
      && (sourceTransfer.contains("slog3") || sourceTransfer.contains("s-log3")
        || sourceTransfer.contains("logc"))
    let compositionAllowed =
      pictureGeometrySupported
      && (arriAllowed || sourceCodeView || transfer.contains("709") || transfer.contains("srgb"))
    if sourceCodeView && !arriAllowed {
      statuses.append(
        "Source Log code-value view; no viewing transform or exposure calibration applied")
    }
    if !pictureGeometrySupported {
      statuses.append(
        "Picture composition unavailable: unsupported geometry; native clean preserved")
    } else if !compositionAllowed {
      statuses.append(
        "Picture composition unavailable: unsupported SDR transfer interpretation (\(pictureSignal.transfer)); native clean preserved"
      )
    }
    if elZoneAllowed {
      p.flags |= MonitorKernelFlag.elZone
      if ELZoneProfile.gamut(forSourceProfileID: config.sourceProfileID) == .sGamut3 {
        p.flags |= MonitorKernelFlag.sonySGamut3
      }
      p.referenceOffsetStops = Float(config.falseColor.referenceOffsetStops)
    } else if sonyPatternAllowed {
      p.flags |= MonitorKernelFlag.sonySLog3
    } else if sonyAllowed {
      // Sony source interpretation and the fixed LogC3 reference are independent
      // of any camera exposure-index setting and of the processed output look.
      p.flags |= MonitorKernelFlag.logC3 | MonitorKernelFlag.sonyARRIReference
      if sonyGamut == .sGamut3 { p.flags |= MonitorKernelFlag.sonySGamut3 }
    } else if literalARRIAllowed {
      p.flags |= arriProfile == .logC3EI800 ? MonitorKernelFlag.logC3 : MonitorKernelFlag.logC4
    } else if config.falseColor.mode != .off {
      statuses.append(
        "False color unavailable: source profile, signal, or correspondence is unqualified")
    }
    // Source pictures already use source pixel coordinates. Applying the
    // source-to-output transform here shifts source masks/classification and
    // stretches clamped border samples into lines when output is downscaled.
    if !pictureIsSource, geometryValid, let mapping = correspondenceMapping {
      p.mapping = mapping
    }
    p.focusOpacity = Float(config.focus.opacity)
    switch config.focus.color {
    case .red: p.peak = SIMD4(1, 0, 0, 1)
    case .green: p.peak = SIMD4(0, 1, 0, 1)
    case .blue: p.peak = SIMD4(0, 0, 1, 1)
    case .yellow: p.peak = SIMD4(1, 1, 0, 1)
    case .white: p.peak = SIMD4(1, 1, 1, 1)
    }
    s.focusThreshold = Float(0.02 + (1 - min(1, max(0, config.focus.sensitivity))) * 0.3)
    s.noise = Float(config.focus.noiseRejection)
    q.scopeMode = config.scopes.mode == .lumaWaveform ? 1 : 0
    q.gain = Float(config.scopes.gain)
    q.scopeSamplingStride = UInt32(quality.scopeSamplingStride)
    q.scopeSamplingPhase = scopePhase % (q.scopeSamplingStride * q.scopeSamplingStride)
    q.flags = config.scopes.graticule ? MonitorKernelFlag.scopeGraticule : 0
    func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, maximumStorage: Int) throws
      -> MTLTexture
    {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]
      guard context.device.heapTextureSizeAndAlign(descriptor: d).size <= maximumStorage else {
        throw MonitorPreviewError.allocationFailed
      }
      guard let t = context.device.makeTexture(descriptor: d), t.allocatedSize <= maximumStorage
      else {
        throw MonitorPreviewError.allocationFailed
      }
      return t
    }
    let focusWidth = focusAllowed ? Int(s.width) : 1
    let focusHeight = focusAllowed ? Int(s.height) : 1
    if working.focus?.width != focusWidth || working.focus?.height != focusHeight {
      working.focus = try texture(
        .r8Unorm, focusWidth, focusHeight, maximumStorage: working.focusAllowance)
    }
    guard let focus = working.focus else { throw MonitorPreviewError.allocationFailed }
    // Keep all staging and bins allowances, including resources lazily needed by a future
    // scope update under this key. Only the fully allocated, immutable focus storage shrinks.
    let focusDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: focusWidth, height: focusHeight, mipmapped: false)
    focusDescriptor.usage = [.shaderRead, .shaderWrite]
    let focusStorage = max(
      focus.allocatedSize, context.device.heapTextureSizeAndAlign(descriptor: focusDescriptor).size)
    guard focusStorage <= working.focusAllowance else { throw MonitorPreviewError.allocationFailed }
    if focusWidth == working.expectedFocusWidth && focusHeight == working.expectedFocusHeight {
      working.focusAllowance = focusStorage
    }
    let verifiedWorkBytes = working.nonFocusBytes + working.focusAllowance
    guard verifiedWorkBytes <= working.maximumBytes,
      working.memory.shrink(to: verifiedWorkBytes)
    else { throw MonitorPreviewError.allocationFailed }
    let outputBytes = max(1024 * 1024, width * height * 4 + 512 * height + 8192)
    var outputReservation = ledger.tryAcquire(
      target: frame.stamp.target, generation: frame.stamp.generation, kind: .presentation,
      bytes: outputBytes)
    if outputReservation == nil {
      evictIdleWork()
      outputReservation = ledger.tryAcquire(
        target: frame.stamp.target, generation: frame.stamp.generation, kind: .presentation,
        bytes: outputBytes)
    }
    guard let outputMemory = outputReservation else { throw MonitorPreviewError.allocationFailed }
    var scopeReservation =
      updateScope
      ? ledger.tryAcquire(
        target: frame.stamp.target, generation: frame.stamp.generation, kind: .presentation,
        bytes: 768 * 256 * 8) : nil
    if updateScope && scopeReservation == nil {
      evictIdleWork()
      scopeReservation = ledger.tryAcquire(
        target: frame.stamp.target, generation: frame.stamp.generation, kind: .presentation,
        bytes: 768 * 256 * 8)
    }
    let scopeMemory = scopeReservation
    if updateScope && scopeMemory == nil { throw MonitorPreviewError.allocationFailed }
    let scope =
      updateScope ? try texture(.bgra8Unorm, 768, 256, maximumStorage: 768 * 256 * 8) : nil
    if let scope, let scopeMemory {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 768, height: 256, mipmapped: false)
      descriptor.usage = [.shaderRead, .shaderWrite]
      let storage = max(
        scope.allocatedSize, context.device.heapTextureSizeAndAlign(descriptor: descriptor).size)
      guard storage <= 768 * 256 * 8, scopeMemory.shrink(to: storage) else {
        throw MonitorPreviewError.allocationFailed
      }
    }
    if updateScope && working.bins == nil {
      working.bins = context.device.makeBuffer(length: 768 * 256 * 4, options: .storageModePrivate)
    }
    let bins = working.bins
    if updateScope && bins == nil { throw MonitorPreviewError.allocationFailed }
    let allocatedBuffers = working.buffers.compactMap { $0 }.reduce(0) { $0 + $1.allocatedSize }
    guard allocatedBuffers + (bins?.allocatedSize ?? 0) <= working.nonFocusBytes else {
      throw MonitorPreviewError.allocationFailed
    }
    let pb: CVPixelBuffer
    do {
      pb = try compositePool.allocate(width: width, height: height, reservation: outputBytes)
    } catch MonitorCompositePool.AllocationError.budgetExceeded {
      // Cache pressure never permits an unbounded allocation. Release idle storage
      // and try once. Threshold exhaustion must preserve clean fallback rather
      // than resetting the eight-buffer limit while consumers hold all buffers.
      evictIdleWork()
      pb = try compositePool.allocate(width: width, height: height, reservation: outputBytes)
    }
    // Composites are bounded SDR display images; scale the picture aperture with pixels.
    let geometry =
      pictureGeometrySupported
      ? pictureGeometry
      : MonitorGeometry(
        width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture))
    let sx = Double(width) / Double(CVPixelBufferGetWidth(picture))
    let sy = Double(height) / Double(CVPixelBufferGetHeight(picture))
    let aperture: [CFString: Any] = [
      kCVImageBufferCleanApertureWidthKey: geometry.cleanAperture.width * sx,
      kCVImageBufferCleanApertureHeightKey: geometry.cleanAperture.height * sy,
      kCVImageBufferCleanApertureHorizontalOffsetKey:
        (geometry.cleanAperture.x + geometry.cleanAperture.width / 2 - Double(
          CVPixelBufferGetWidth(picture)) / 2) * sx,
      kCVImageBufferCleanApertureVerticalOffsetKey:
        -(geometry.cleanAperture.y + geometry.cleanAperture.height / 2 - Double(
          CVPixelBufferGetHeight(picture)) / 2) * sy,
    ]
    CVBufferSetAttachment(
      pb, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
    CVBufferSetAttachment(
      pb, kCVImageBufferPixelAspectRatioKey,
      [
        kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(
          (geometry.pixelAspectRatio * 1_000_000).rounded()),
        kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1_000_000,
      ] as CFDictionary, .shouldPropagate)
    CVBufferSetAttachment(
      pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(
      pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
      .shouldPropagate)
    if let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) {
      CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
    }
    var cvTexture: CVMetalTexture?
    guard let cache = context.cache,
      CVMetalTextureCacheCreateTextureFromImage(
        nil, cache, pb, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
      let cvTexture, let output = CVMetalTextureGetTexture(cvTexture),
      let command = context.queue.makeCommandBuffer()
    else { throw MonitorPreviewError.allocationFailed }
    if updateScope, let bins {
      guard let clear = command.makeBlitCommandEncoder() else {
        throw MonitorPreviewError.gpuFailed
      }
      clear.fill(buffer: bins, range: 0..<bins.length, value: 0)
      clear.endEncoding()
    }
    var sourceParams = s
    func encode(
      _ pipeline: MTLComputePipelineState, _ buffer: MTLBuffer, _ params: inout KernelParameters,
      _ textures: [MTLTexture], _ grid: MTLSize, _ extra: MTLBuffer? = nil
    ) throws {
      guard let e = command.makeComputeCommandEncoder() else { throw MonitorPreviewError.gpuFailed }
      e.setComputePipelineState(pipeline)
      e.setBuffer(buffer, offset: 0, index: 0)
      e.setBytes(&params, length: MemoryLayout<KernelParameters>.stride, index: 1)
      if pipeline === context.compose {
        e.setBuffer(sourceBuffer, offset: 0, index: 3)
        e.setBytes(&sourceParams, length: MemoryLayout<KernelParameters>.stride, index: 4)
      }
      if let extra { e.setBuffer(extra, offset: 0, index: 2) }
      for (i, t) in textures.enumerated() { e.setTexture(t, index: i) }
      e.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
      e.endEncoding()
    }
    if focusAllowed {
      try encode(
        context.focus, sourceBuffer, &s, [focus],
        MTLSize(width: Int(s.width), height: Int(s.height), depth: 1))
    }
    if compositionAllowed {
      try encode(
        context.compose, pictureBuffer, &p, [focus, output],
        MTLSize(width: width, height: height, depth: 1))
    }
    if updateScope, let bins, let scope {
      try encode(
        context.scopes, scopeBuffer, &q, [],
        MTLSize(width: (Int(q.width) + Int(q.scopeSamplingStride) - 1) / Int(q.scopeSamplingStride),
          height: (Int(q.height) + Int(q.scopeSamplingStride) - 1) / Int(q.scopeSamplingStride), depth: 1), bins)
      try encode(context.scopeImage, bins, &q, [scope], MTLSize(width: 768, height: 256, depth: 1))
    }
    let analyzedScopePhase = Int(q.scopeSamplingPhase)
    let availability = statuses
    guard CVPixelBufferGetDataSize(pb) <= outputBytes else {
      throw MonitorPreviewError.allocationFailed
    }
    let outputOwner = MonitorOwnedFrame(
      stamp: frame.stamp, pixelBuffer: pb, releaseBudget: { _ = outputMemory })
    let textureOwner = ResourceBox(cvTexture)
    let stamp = frame.stamp
    job.armDeadline { [weak self] in
      guard let self, self.current(stamp) != nil else { return }
      self.telemetry.record(stamp.target, pressure: true, rejected: true)
      self.deliver(
        .success(
          MonitorDisplayResult(
            clean: clean, configuration: config,
            availability: ["Monitoring GPU deadline exceeded; committed resources remain charged"],
            pictureSignal: pictureSignal)),
        stamp: stamp, completion: completion)
    }
    command.addCompletedHandler {
      [weak self, pictureBuffer, sourceBuffer, scopeBuffer, focus, bins, textureOwner] command in
      _ = [pictureBuffer, sourceBuffer, scopeBuffer]
      _ = focus
      _ = bins
      _ = textureOwner
      if command.status == .completed { self?.cacheWorking(working, stamp: stamp) }
      let deadlineExceeded = job.release()
      if command.gpuEndTime > command.gpuStartTime {
        self?.gpuTiming(command.gpuStartTime, command.gpuEndTime)
      }
      guard let self else { return }
      guard self.current(stamp) != nil else {
        if self.generationRetired(stamp) {
          self.worker.async { [compositePool = self.compositePool] in compositePool.trim() }
        }
        return
      }
      guard !deadlineExceeded else { return }
      guard command.status == .completed else {
        self.deliver(
          .success(
            MonitorDisplayResult(
              clean: clean, configuration: config,
              availability: ["Analysis GPU failed"], pictureSignal: pictureSignal)), stamp: stamp,
          completion: completion)
        return
      }
      let decorated = outputOwner
      let scopes: MonitorScopeResult?
      if let scope, let scopeMemory {
        scopes = MonitorScopeResult(
          texture: scope, stamp: stamp, mode: config.scopes.mode, lease: scopeMemory,
          signal: scopeSignal, samplingStride: quality.scopeSamplingStride,
          samplingPhase: analyzedScopePhase)
      } else {
        scopes = config.scopes.enabled ? previousScope : nil
      }
      if updateScope, let scopes {
        self.lock.lock()
        if let session = self.sessions[stamp.target], session.0 == stamp.generation,
          session.1 == stamp.configurationRevision, session.3 == stamp.processingRevision
        {
          self.scopeCache[stamp.target] = scopes
        }
        self.lock.unlock()
      }
      self.deliver(
        .success(
          MonitorDisplayResult(
            clean: clean, decorated: compositionAllowed ? decorated : nil,
            scope: scopes, configuration: config, availability: availability,
            pictureSignal: pictureSignal)),
        stamp: stamp, completion: completion)
    }
    if updateScope {
      lock.lock()
      if let session = sessions[stamp.target], session.0 == stamp.generation,
        session.1 == stamp.configurationRevision, session.3 == stamp.processingRevision
      {
        scopeTimes[stamp.target] = nextScopeDeadline
        scopePhases[stamp.target] = scopePhase &+ 1
      }
      lock.unlock()
    }
    return command
  }
}
