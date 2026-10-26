// Installed-extension IPC checks. --run uses synthetic pixels; --consumer
// requests the source only, allowing the host's automatic feed to start.
// Neither mode displays/records images or submits an extension request.
// --monitor-gpu-check runs the monitor load offline, without CMIO.
import CoreMediaIO
import Foundation
import Darwin
import Security
@preconcurrency import Metal
import MonitorKit
import MonitorKitScopes

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() {
    fputs("CMIO_SMOKE assertion: \(message)\n", stderr)
    fflush(stderr)
    throw VideoError.message(message)
  }
}

func check(_ status: OSStatus, _ operation: String) throws {
  try require(status == noErr, "\(operation) failed (\(status)).")
}

func address(_ selector: Int) -> CMIOObjectPropertyAddress {
  CMIOObjectPropertyAddress(mSelector: UInt32(selector),
    mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
}

func ids(_ object: CMIOObjectID, _ selector: Int) throws -> [UInt32] {
  var property = address(selector)
  var size: UInt32 = 0
  try check(CMIOObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read CMIO list size")
  try require(size % UInt32(MemoryLayout<UInt32>.size) == 0, "Invalid CMIO list size.")
  var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
  if !values.isEmpty {
    try values.withUnsafeMutableBytes {
      try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, $0.baseAddress!), "Read CMIO list")
    }
  }
  return values
}

func string(_ object: CMIOObjectID, _ selector: Int) throws -> String {
  var property = address(selector)
  var value: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  try check(CMIOObjectGetPropertyData(object, &property, 0, nil, size, &size, &value), "Read CMIO identity")
  return value?.takeRetainedValue() as String? ?? ""
}

func log(_ message: String) { print(message); fflush(stdout) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func pollPause() { Thread.sleep(forTimeInterval: 0.002) }

/// A small, human-readable snapshot of the format CMIO reports for a stream.
/// Keep this separate from `SyntheticMode`: the latter is the producer's
/// requested contract, while this is the consumer-facing contract that the
/// installed extension actually negotiated. Those can differ when another
/// client (for example Zoom) owns the device-control lease, or when the
/// installed extension is from an older build.
struct StreamFormatSummary: CustomStringConvertible, Sendable {
  let width: Int32
  let height: Int32
  let pixelFormat: OSType
  let frameRate: Double?

  var description: String {
    let rate = frameRate.map { String(format: "%.6g fps", $0) } ?? "fps unavailable"
    return "\(width)x\(height) \(VideoContract.fourCC(pixelFormat)) \(rate)"
  }
}

func currentStreamFormat(_ stream: CMIOStreamID) -> StreamFormatSummary? {
  var property = address(kCMIOStreamPropertyFormatDescription)
  var value: Unmanaged<CMFormatDescription>?
  var size = UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size)
  guard CMIOObjectGetPropertyData(stream, &property, 0, nil, size, &size, &value) == noErr,
    let description = value?.takeRetainedValue() else { return nil }
  let dimensions = CMVideoFormatDescriptionGetDimensions(description)

  property.mSelector = UInt32(kCMIOStreamPropertyFrameRate)
  var frameRate: Double = 0
  var rateSize = UInt32(MemoryLayout<Double>.size)
  let rateStatus = CMIOObjectGetPropertyData(stream, &property, 0, nil, rateSize, &rateSize, &frameRate)
  return StreamFormatSummary(width: dimensions.width, height: dimensions.height,
    pixelFormat: CMFormatDescriptionGetMediaSubType(description),
    frameRate: rateStatus == noErr ? frameRate : nil)
}

// One thread owns all dequeues, including cleanup. The notification callback
// never dequeues, avoiding a concurrent-drain race. Paired monitor checks
// optionally record bounded token arrival metadata in a notification refCon.
// Apple CMIOHardwareStream.h documents the Copy-owned queue and that a nil
// callback unregisters notifications (and may return no queue):
// https://developer.apple.com/documentation/coremediaio/cmiostreamcopybufferqueue(_:_:_:_:)
// CMSimpleQueue.h documents that payload lifetime is managed externally:
// https://developer.apple.com/documentation/coremedia/cmsimplequeue-api
// A dequeued CMIO sample transfers the producer's payload retain to this
// consumer; takeRetainedValue releases that retain after inspection.
/// SDK CMIOHardwareStream.h specifies that input notifications follow insertion
/// and token is the inserted queue payload. Never retain/dereference payloads
/// here; only the one ordinary dequeue owner transfers sample ownership.
final class SourceArrivals: @unchecked Sendable {
  private let condition = NSCondition()
  private struct Entry: Equatable { let token: UInt; let time: Double; let ordinal: UInt64 }
  private var entries = [Entry?](repeating: nil, count: 64)
  private var ordinal: UInt64 = 0
  private var matched = 0, overlappingPointerNotifications = 0, peakPending = 0
  private var pending = 0
  private var closed = false
  private var failure: String?
  private let capacity = 64
  init() {}
  func record(_ token: UnsafeMutableRawPointer) {
    let arrival = now()
    condition.lock(); defer { condition.unlock() }
    guard !closed else { return }
    guard pending < capacity else {
      failure = "Receiver notification timestamp storage exceeded 64 bounded entries."
      condition.broadcast(); return
    }
    // Preallocated slots avoid callback allocations. A repeated pointer gets
    // a separate ordinal, so reuse never overwrites a live sample's arrival.
    guard let index = entries.firstIndex(where: { $0 == nil }) else { return }
    if entries.contains(where: { $0?.token == UInt(bitPattern: token) }) { overlappingPointerNotifications += 1 }
    ordinal &+= 1
    entries[index] = Entry(token: UInt(bitPattern: token), time: arrival, ordinal: ordinal)
    pending += 1
    peakPending = max(peakPending, pending)
    condition.signal()
  }
  func take(_ token: UnsafeRawPointer) throws -> Double {
    let key = UInt(bitPattern: token), deadline = Date(timeIntervalSinceNow: 0.1)
    condition.lock(); defer { condition.unlock() }
    func matchingIndex() -> Int? {
      entries.indices.filter { entries[$0]?.token == key }.min {
        entries[$0]!.ordinal < entries[$1]!.ordinal
      }
    }
    while matchingIndex() == nil && !closed && failure == nil {
      // Native insertion can win the notification race. Keep exactly this one
      // dequeued/retained sample while bounded-waiting for its callback record.
      if !condition.wait(until: deadline) { break }
    }
    if let failure { throw VideoError.message(failure) }
    guard let index = matchingIndex(), let entry = entries[index] else {
      throw VideoError.message("Receiver notification deadline: token=\(key) pending=\(pending) closed=\(closed).")
    }
    entries[index] = nil
    pending -= 1
    matched += 1
    return entry.time
  }
  func report() {
    condition.lock()
    let statistics = "callbackRecords=\(ordinal) matchedDequeues=\(matched) overlappingPointerNotifications=\(overlappingPointerNotifications) peakPending=\(peakPending) capacity=\(capacity) failure=\(failure ?? "none")"
    condition.unlock()
    log("CMIO_RECEIVER_TIMESTAMPS \(statistics)")
  }
  func close() {
    condition.lock(); closed = true
    for index in entries.indices { entries[index] = nil }
    pending = 0
    condition.broadcast(); condition.unlock()
  }
}

/// The SDK documents unregistering, not a synchronous join of in-flight C
/// callbacks. Keep at most six metadata-only refCons alive until process exit;
/// closed contexts ignore late callbacks and never own samples or pixel bytes.
final class SourceArrivalContexts: @unchecked Sendable {
  static let shared = SourceArrivalContexts()
  private let lock = NSLock()
  private var contexts: [SourceArrivals] = []
  func make() throws -> SourceArrivals {
    try lock.withLock {
      try require(contexts.count < 6, "At most six paired receiver arrival contexts are allowed.")
      let context = SourceArrivals(); contexts.append(context); return context
    }
  }
}

struct SourceCadenceGrid {
  let anchor: CMTime
  let duration: CMTime
  func nextEpoch() -> CMTime {
    let earliest = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.25, preferredTimescale: 60_000))
    let steps = max(0, Int32(ceil(CMTimeSubtract(earliest, anchor).seconds / duration.seconds)))
    return CMTimeAdd(anchor, CMTimeMultiply(duration, multiplier: steps))
  }
}

final class SourceQueue {
  let device: CMIODeviceID
  let stream: CMIOStreamID
  let queue: CMSimpleQueue
  let negotiatedFormat: StreamFormatSummary?
  private let arrivals: SourceArrivals?
  private var started = false
  private var closed = false
  private var closeStatus: OSStatus = noErr

  init(route: CameraSinkRoute, arrivals: SourceArrivals? = nil) throws {
    self.arrivals = arrivals
    guard let device = try ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
      .first(where: { try string($0, kCMIODevicePropertyDeviceUID) == route.deviceUID }),
      let stream = try ids(device, kCMIODevicePropertyStreams)
      .first(where: { try string($0, kCMIOObjectPropertyName) == route.sourceStreamName }) else {
      throw VideoError.message("Installed synthetic target/source was not discovered.")
    }
    self.device = device
    self.stream = stream
    var copied: Unmanaged<CMSimpleQueue>?
    let refCon = arrivals.map { Unmanaged.passUnretained($0).toOpaque() }
    try check(CMIOStreamCopyBufferQueue(stream, { _, token, refCon in
      guard let token, let refCon else { return }
      Unmanaged<SourceArrivals>.fromOpaque(refCon).takeUnretainedValue().record(token)
    }, refCon, &copied), "Copy source queue")
    guard let copied else { throw VideoError.message("Source queue is unavailable.") }
    queue = copied.takeRetainedValue()
    try check(CMIODeviceStartStream(device, stream), "Start installed camera source")
    started = true
    negotiatedFormat = currentStreamFormat(stream)
    let formatText = negotiatedFormat.map { " negotiated=\($0)" } ?? " negotiated=unavailable"
    log("CMIO_SMOKE sourceStarted device=\(device) stream=\(stream) queueCapacity=\(CMSimpleQueueGetCapacity(queue))\(formatText)")
  }

  func next() -> CMSampleBuffer? {
    guard let token = CMSimpleQueueDequeue(queue) else { return nil }
    return Unmanaged<CMSampleBuffer>.fromOpaque(token).takeRetainedValue()
  }

  func nextArrival() throws -> (sample: CMSampleBuffer, hostTime: Double)? {
    guard let token = CMSimpleQueueDequeue(queue) else { return nil }
    let sample = Unmanaged<CMSampleBuffer>.fromOpaque(token).takeRetainedValue()
    guard let arrivals else { throw VideoError.message("Receiver arrival tracking was not enabled.") }
    return (sample, try arrivals.take(token))
  }

  @discardableResult
  func stop() -> OSStatus {
    guard !closed else { return closeStatus }
    closed = true
    if started {
      let status = CMIODeviceStopStream(device, stream)
      log("CMIO_SMOKE sourceStop=\(status)")
      closeStatus = status
      started = false
    }
    var copied: Unmanaged<CMSimpleQueue>?
    let status = CMIOStreamCopyBufferQueue(stream, nil, nil, &copied)
    log("CMIO_SMOKE sourceUnregister=\(status)")
    if closeStatus == noErr { closeStatus = status }
    arrivals?.close()
    if let copied { _ = copied.takeRetainedValue() }
    // Stopped stream; release each remaining producer-owned sample once.
    for _ in 0..<CMSimpleQueueGetCapacity(queue) {
      guard let sample = next() else { break }
      withExtendedLifetime(sample) {}
    }
    return closeStatus
  }

  deinit { stop() }
}

struct SyntheticMode {
  let width: Int
  let height: Int
  let format: OSType
  var black: UInt16 { format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 64 }

  func summary(duration: CMTime) -> String {
    let fps = duration.seconds > 0 ? 1 / duration.seconds : 0
    return "\(width)x\(height) \(VideoContract.fourCC(format)) \(String(format: "%.6g fps", fps)) duration=\(duration.value)/\(duration.timescale)"
  }

  func row(marker: UInt16, plane: Int) -> [UInt8] {
    if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
      return [UInt8](repeating: plane == 0 ? UInt8(marker) : 128, count: width)
    }
    if format == kCVPixelFormatType_422YpCbCr10 {
      let y = UInt32(marker), c: UInt32 = 512
      let group = [c | (y << 10) | (c << 20), y | (c << 10) | (y << 20),
        c | (y << 10) | (c << 20), y | (c << 10) | (y << 20)]
      let words = (0..<(width / 6 * 4)).map { group[$0 % 4] }
      return words.withUnsafeBytes { Array($0) }
    }
    // Adjacent ten-bit luma codes deliberately exercise the lower two bits
    // that an accidental eight-bit transport would lose.
    let words = [UInt16](repeating: (plane == 0 ? marker : 512) << 6, count: width)
    return words.withUnsafeBytes { Array($0) }
  }
}

func makePool(_ mode: SyntheticMode) throws -> CVPixelBufferPool {
  var pool: CVPixelBufferPool?
  let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
    [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.warmBufferCount] as CFDictionary,
    [kCVPixelBufferWidthKey: mode.width, kCVPixelBufferHeightKey: mode.height,
      kCVPixelBufferPixelFormatTypeKey: mode.format,
      kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
  try require(status == kCVReturnSuccess && pool != nil, "Cannot allocate bounded synthetic pool (\(status)).")
  return pool!
}

func image(marker: UInt16, pool: CVPixelBufferPool, mode: SyntheticMode) throws -> CVPixelBuffer {
  var created: CVPixelBuffer?
  let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
    [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary, &created)
  try require(status == kCVReturnSuccess && created != nil, "Cannot allocate synthetic IOSurface (\(status)).")
  let result = created!
  try require(CVPixelBufferGetIOSurface(result) != nil, "Synthetic image is not shareable.")
  try check(CVPixelBufferLockBaseAddress(result, []), "Lock synthetic image")
  defer { CVPixelBufferUnlockBaseAddress(result, []) }
  let planes = CVPixelBufferIsPlanar(result) ? CVPixelBufferGetPlaneCount(result) : 1
  for plane in 0..<planes {
    let planar = CVPixelBufferIsPlanar(result)
    guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(result, plane) : CVPixelBufferGetBaseAddress(result) else {
      throw VideoError.message("Synthetic plane is absent.")
    }
    let rows = planar ? CVPixelBufferGetHeightOfPlane(result, plane) : mode.height
    let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(result, plane) : CVPixelBufferGetBytesPerRow(result)
    let reference = mode.row(marker: marker, plane: plane)
    try require(stride >= reference.count, "Synthetic stride is shorter than active pixels.")
    memset(base, 0, stride * rows)
    reference.withUnsafeBytes { expected in
      for row in 0..<rows { memcpy(base.advanced(by: row * stride), expected.baseAddress!, reference.count) }
    }
  }
  return result
}

func inspect(_ sample: CMSampleBuffer, duration: CMTime, mode: SyntheticMode) throws -> UInt16 {
  try require(CMSampleBufferDataIsReady(sample), "Received unready sample.")
  guard let image = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("Received no image.") }
  try VideoBufferLayout.validate(image)
  let actualWidth = CVPixelBufferGetWidth(image)
  let actualHeight = CVPixelBufferGetHeight(image)
  let actualFormat = CVPixelBufferGetPixelFormatType(image)
  let actualDuration = CMSampleBufferGetDuration(sample)
  let actualSummary = "\(actualWidth)x\(actualHeight) \(VideoContract.fourCC(actualFormat)) duration=\(actualDuration.value)/\(actualDuration.timescale)"
  try require(actualWidth == mode.width && actualHeight == mode.height && actualFormat == mode.format,
    "Negotiated camera contract differs: requested \(mode.summary(duration: duration)); received \(actualSummary). " +
      "Another client may own CMIO device control, or the installed extension may be stale.")
  try require(actualDuration == duration,
    "Negotiated camera cadence differs: requested \(mode.summary(duration: duration)); received \(actualSummary).")
  try check(CVPixelBufferLockBaseAddress(image, .readOnly), "Lock received synthetic image")
  defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
  let planar = CVPixelBufferIsPlanar(image)
  guard let luma = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image) else {
    throw VideoError.message("Received no luma.")
  }
  let marker: UInt16
  if mode.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { marker = UInt16(luma.load(as: UInt8.self)) }
  else if planar { marker = luma.load(as: UInt16.self) >> 6 }
  else { marker = UInt16((luma.load(as: UInt32.self) >> 10) & 1023) }
  let planes = planar ? CVPixelBufferGetPlaneCount(image) : 1
  for plane in 0..<planes {
    guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, plane) : CVPixelBufferGetBaseAddress(image) else {
      throw VideoError.message("Received no plane.")
    }
    let rows = planar ? CVPixelBufferGetHeightOfPlane(image, plane) : mode.height
    let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, plane) : CVPixelBufferGetBytesPerRow(image)
    let reference = mode.row(marker: marker, plane: plane)
    try reference.withUnsafeBytes { expected in
      for row in 0..<rows {
        try require(memcmp(base.advanced(by: row * stride), expected.baseAddress!, reference.count) == 0,
          "Synthetic active pixels changed in plane \(plane), row \(row).")
      }
    }
  }
  return marker
}

/// Optional read-only subscriber, offered only after the producer has sent the
/// original sample. It runs the app's monitor GPU path offscreen: the app's own
/// `MonitorGPUContext` core (one `MTL4CommandQueue`, pooled encode contexts with
/// their allocators and uniforms, the engine's residency set and the IOSurface
/// texture cache), MonitorKit's Metal 4 encodes, focus analysis and the picture
/// pass (zebra, focus peaking, the output stage) into a 1080p target, and the
/// scope (the earlier 768 × 256 RGB parade) in its own submission. The targets
/// join the queue through a residency set, as the app's drawables do. The CMIO
/// payload is read in place through the cache's IOSurface textures, never copied.
final class MonitorComparison: MonitorGPUCompletion, @unchecked Sendable {
  /// The app's GPU core and MonitorKit's objects for one feed and one surface.
  /// The encoders are confined: only the offering thread (the producer loop, and
  /// `prewarm` before it) touches them.
  private struct GPU {
    let context: MonitorGPUContext
    let core: MonitorGPUContext.Core
    let feed: MonitorFeed
    let pass: MonitorPass
    let scope: ScopeAccumulator
    let scopeRenderer: ScopeRenderer
    let targets: [MTLTexture]
    let scopeTargets: [MTLTexture]
    let targetResidency: MTLResidencySet
  }
  /// Submission kinds: bit 0 scope, bit 1 warmup, the sequence above them.
  private static let scopeBit = 1, warmupBit = 2, sequenceShift = 2
  let target = "cmio-synthetic-comparison"
  private let lock = NSLock()
  private var warmReady = false
  private var pictures = Set<UInt64>(), scopes = Set<UInt64>()
  private var pictureAges: [Double] = [], scopeAges: [Double] = [], schedulingDelays: [Double] = []
  /// Source host time per measured sequence, for the completion handler (one run's worth).
  private var hostTimes: [UInt64: Double] = [:]
  private var failure: String?
  private var offered = 0, admitted = 0, callbacks = 0
  private var failureMetadata: [String] = []
  private let gpu: GPU?
  private let unavailableReason: String?
  private var state = MonitorState()
  private let scopeRefreshHz = 15
  private var lastScopeTime = -Double.infinity
  init() {
    state.pictureStage = .output
    state.zebras[0].enabled = true
    state.focus.enabled = true
    do {
      gpu = try Self.makeGPU()
      unavailableReason = nil
    } catch {
      gpu = nil
      unavailableReason = "Monitor GPU unavailable: \(error)"
    }
  }
  deinit {
    if let gpu { gpu.context.detachDrawables(gpu.targetResidency) }
  }
  private static func makeGPU() throws -> GPU {
    // The app's context, built and warmed here (every pipeline a first frame
    // needs), before any measurement.
    let context = MonitorGPUContext(gpuTiming: { _, _ in })
    let core = try context.core()
    try core.warmUp()
    let device = core.device
    let scope = try core.scopeEngine.makeAccumulator(settings: .plainWaveform(mode: .rgbParade, stage: .output))
    func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      descriptor.usage = [.shaderRead, .renderTarget]
      descriptor.storageMode = .private
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw VideoError.message("Cannot allocate a \(width)x\(height) monitor target.")
      }
      return texture
    }
    let targets = try (0..<3).map { _ in try texture(1920, 1080) }
    let scopeTargets = try (0..<3).map { _ in
      try texture(ScopeSettings.plainWaveformImageWidth, ScopeSettings.plainWaveformImageHeight)
    }
    let residency = MTLResidencySetDescriptor()
    residency.label = "CameraSmoke monitor targets"
    residency.initialCapacity = targets.count + scopeTargets.count
    let targetResidency = try device.makeResidencySet(descriptor: residency)
    for texture in targets + scopeTargets { targetResidency.addAllocation(texture) }
    targetResidency.commit()
    context.attachDrawables(targetResidency)
    return GPU(
      context: context, core: core, feed: core.engine.makeFeed(), pass: core.engine.makePass(), scope: scope,
      scopeRenderer: core.scopeEngine.makeRenderer(), targets: targets, scopeTargets: scopeTargets,
      targetResidency: targetResidency)
  }
  private static func kind(sequence: UInt64, warmup: Bool, isScope: Bool) -> Int {
    Int(sequence) << sequenceShift | (warmup ? warmupBit : 0) | (isScope ? scopeBit : 0)
  }
  /// MonitorGPUCompletion: one committed submission finished on the GPU (Metal's feedback queue).
  func gpuCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    let sequence = UInt64(kind >> Self.sequenceShift)
    let warmup = kind & Self.warmupBit != 0, isScope = kind & Self.scopeBit != 0
    let finished = now()
    lock.lock(); defer { lock.unlock() }
    if !warmup { callbacks += 1 }
    if failed {
      failure = "Monitor GPU work failed"
      failureMetadata.append("gpuFailed=true sequence=\(sequence)")
      return
    }
    if warmup { warmReady = true; return }
    guard let host = hostTimes[sequence] else { return }
    if isScope {
      if scopes.insert(sequence).inserted { scopeAges.append(finished - host) }
    } else if pictures.insert(sequence).inserted {
      pictureAges.append(finished - host)
    }
  }
  func offer(_ sample: CMSampleBuffer, sequence: UInt64, warmup: Bool = false,
    sourceHostTime: Double? = nil) {
    let time = now()
    // Offer every successfully enqueued original sample; nothing is thinned.
    guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
    if !warmup { lock.withLock { offered += 1 } }
    if let sourceHostTime, !warmup { lock.withLock { schedulingDelays.append(time - sourceHostTime) } }
    let host = sourceHostTime ?? time
    let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    let metadata = "target=\(target) generation=1 sequence=\(sequence) sourcePTS=\(sourcePTS) sourceHost=\(host) offerHost=\(time) warmup=\(warmup)"
    guard let gpu else {
      lock.withLock { failure = unavailableReason ?? "Monitor GPU unavailable" }
      return
    }
    if !warmup { lock.withLock { hostTimes[sequence] = host } }
    let core = gpu.core
    do {
      // The synthetic source is legal-range Rec.709. The cache's textures wrap the
      // payload's IOSurface; the frame retains the pixel buffer.
      let frame = try core.frames.frame(image, signal: .rec709)
      // A failed body is committed (abandoned) by `submit`, which then rethrows.
      try core.submit(completion: self, kind: Self.kind(sequence: sequence, warmup: warmup, isScope: false)) {
        context in
        context.keep(frame)
        try gpu.feed.analyze(frame, focus: state.focus, into: context.submission)
        try gpu.pass.encode(
          frame: frame, feed: gpu.feed, state: state, target: gpu.targets[Int(sequence % UInt64(gpu.targets.count))],
          clear: true, into: context.submission)
      }
      let unavailable = gpu.pass.status.unavailable
      if !unavailable.isEmpty {
        let reasons = unavailable.map { "\($0.tool.rawValue): \($0.reason)" }.joined(separator: ", ")
        lock.withLock { failure = "GPU analysis unavailable: \(reasons)" }
      }
      // Scopes at the requested rate, in their own submission.
      if time - lastScopeTime >= 1 / Double(scopeRefreshHz) - 0.002 {
        lastScopeTime = time
        try core.submit(completion: self, kind: Self.kind(sequence: sequence, warmup: warmup, isScope: true)) {
          context in
          context.keep(frame)
          try gpu.scope.accumulate(frame, feed: gpu.feed, into: context.submission)
          try gpu.scopeRenderer.render(
            gpu.scope, target: gpu.scopeTargets[Int(sequence % UInt64(gpu.scopeTargets.count))], clear: true,
            into: context.submission)
        }
      }
      if !warmup { lock.withLock { admitted += 1 } }
    } catch {
      lock.withLock {
        failure = "\(error)"
        failureMetadata.append("encodeError=\(error) \(metadata)")
      }
    }
  }
  func prewarm(_ sample: CMSampleBuffer) throws {
    let deadline = now() + 8
    while now() < deadline {
      offer(sample, sequence: 0, warmup: true)
      let state = lock.withLock { (warmReady, failure) }
      if let failure = state.1 { throw VideoError.message(failure) }
      if state.0 { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw VideoError.message("Monitor GPU warmup deadline expired.")
  }
  func finish(seconds: Double) throws {
    Thread.sleep(forTimeInterval: 0.15)
    let snapshot = lock.withLock { (pictures.count, scopes.count, pictureAges, scopeAges, failure) }
    let pictureHz = Double(snapshot.0) / seconds, scopeHz = Double(snapshot.1) / seconds
    let metrics = lock.withLock { (offered, admitted, callbacks, schedulingDelays, failureMetadata) }
    let gpuStatistics = gpu?.context.statistics ?? MonitorGPUContext.Statistics()
    // Defer diagnostic output until measurement ends; failure reporting must not
    // add per-frame console I/O to the ordinary receiver/monitor scheduling.
    log("CMIO_MONITOR sourceAgeOrigin=successfulSenderEnqueue offered=\(metrics.0) admitted=\(metrics.1) callbacks=\(metrics.2) uniquePictures=\(snapshot.0) uniqueScopes=\(snapshot.1) monitorSchedulingP95MS=\(percentile(metrics.3,0.95)*1000) pictureHz=\(pictureHz) scopeHz=\(scopeHz) pictureAgeMS=\(percentile(snapshot.2, 0.95)*1000) scopeAgeMS=\(percentile(snapshot.3, 0.95)*1000) warmupExcluded=true")
    log("CMIO_MONITOR_GPU path=metal4 texturesMade=\(gpuStatistics.texturesMade) texturesCached=\(gpuStatistics.texturesCached) encodeContexts=\(gpuStatistics.encodeContexts) uniformChunksGrown=\(gpuStatistics.uniformChunksGrown) residencyCommits=\(gpuStatistics.residencyCommits) submissions=\(gpuStatistics.submissions) completedSubmissions=\(gpuStatistics.completedSubmissions) failedEncodes=\(gpuStatistics.failedEncodes)")
    for metadata in metrics.4 { log("CMIO_MONITOR_DIAGNOSTIC \(metadata)") }
    if let failure = snapshot.4 { throw VideoError.message(failure) }
    try require(gpuStatistics.failedEncodes == 0, "Monitor encodes failed: \(gpuStatistics.failedEncodes).")
    try require(pictureHz >= 20 && scopeHz >= 10,
      "Monitor useful-rate gate failed: picture=\(pictureHz)Hz scope=\(scopeHz)Hz.")
    try require(percentile(snapshot.2, 0.95) <= 0.100 && percentile(snapshot.3, 0.95) <= 0.200,
      "Monitor age gate failed (picture p95 <=100ms, scope p95 <=200ms).")
  }
}

func percentile(_ values: [Double], _ quantile: Double) -> Double {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return .infinity }
  return sorted[Int(ceil(Double(sorted.count - 1) * quantile))]
}

func logLatencyDistribution(_ segment: String, values: [Double]) {
  let bounds = [0.0, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100]
  var counts = [Int](repeating: 0, count: bounds.count + 1)
  for value in values {
    let bucket = bounds.firstIndex(where: { value < $0 }) ?? bounds.count
    counts[bucket] += 1
  }
  log("CMIO_LATENCY_DISTRIBUTION segment=\(segment) count=\(values.count) minMS=\(values.min() ?? .infinity) p50MS=\(percentile(values,0.5)) p95MS=\(percentile(values,0.95)) p99MS=\(percentile(values,0.99)) maxMS=\(values.max() ?? .infinity) bucketUpperExclusiveMS=\(bounds) bucketCounts=\(counts) finalBucketUpper=infinity trimming=false")
}

struct CameraReceipt {
  let latencyMS: [Double]
  let retries: Int
}

/// Eight immutable image fixtures plus bounded timing wrappers. Only the tiny
/// already-prepared enqueue runs with the controlled hardware-source policy.
final class ControlledCameraProducer: @unchecked Sendable {
  let samples: [CMSampleBuffer]
  let sink: CameraSink
  let period: Double
  let lock = NSLock()
  private var emissions: [Double] = [], cpuMS: [Double] = []
  private var error: String?
  private var cancelled = false
  private var setup: kern_return_t = KERN_FAILURE, restore: kern_return_t = KERN_FAILURE
  private var active = false
  private var postReadback: kern_return_t = KERN_FAILURE
  private var postActive = false
  let finished = DispatchSemaphore(value: 0)
  init(samples: [CMSampleBuffer], sink: CameraSink, period: Double) {
    self.samples = samples; self.sink = sink; self.period = period
    emissions.reserveCapacity(samples.count); cpuMS.reserveCapacity(samples.count)
  }
  func snapshot() -> (times: [Double], cpu: [Double], error: String?, active: Bool, setup: kern_return_t, restore: kern_return_t, postReadback: kern_return_t, postActive: Bool) {
    lock.withLock { (emissions, cpuMS, error, active, setup, restore, postReadback, postActive) }
  }
  func cancel() { lock.withLock { cancelled = true } }
  func start() {
    let producer = Thread { [self] in
      var timebase = mach_timebase_info_data_t()
      guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
        lock.withLock { error = "Cannot read Mach timebase." }; finished.signal(); return
      }
      func ticks(_ seconds: Double) -> UInt64 {
        UInt64((seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)).rounded())
      }
      let thread = pthread_mach_thread_np(pthread_self())
      let words = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
      var policy = thread_time_constraint_policy_data_t(period: UInt32(ticks(period)),
        computation: UInt32(ticks(0.0005)), constraint: UInt32(ticks(0.001)), preemptible: 1)
      let applied = withUnsafeMutablePointer(to: &policy) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
          thread_policy_set(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, words)
        }
      }
      defer {
        var after = thread_time_constraint_policy_data_t()
        var afterCount = words
        var afterDefaults: boolean_t = 0
        let afterStatus = withUnsafeMutablePointer(to: &after) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
            thread_policy_get(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &afterCount, &afterDefaults)
          }
        }
        let afterVerified = afterStatus == KERN_SUCCESS && afterDefaults == 0 &&
          after.period == policy.period && after.computation == policy.computation && after.constraint == policy.constraint
        var standard: integer_t = 0
        let result = thread_policy_set(thread, thread_policy_flavor_t(THREAD_STANDARD_POLICY), &standard, 0)
        lock.withLock { restore = result; postReadback = afterStatus; postActive = afterVerified }
        finished.signal()
      }
      var observed = thread_time_constraint_policy_data_t()
      var count = words
      var defaults: boolean_t = 0
      let read = withUnsafeMutablePointer(to: &observed) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
          thread_policy_get(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &count, &defaults)
        }
      }
      let verified = applied == KERN_SUCCESS && read == KERN_SUCCESS && defaults == 0 &&
        observed.period == policy.period && observed.computation == policy.computation && observed.constraint == policy.constraint
      lock.withLock {
        setup = applied == KERN_SUCCESS ? read : applied; active = verified
        if !verified { error = "Controlled source policy setup/readback failed." }
      }
      guard verified else { return }
      let origin = CMClockConvertHostTimeToSystemUnits(CMSampleBufferGetPresentationTimeStamp(samples[0]))
      var prior: UInt64?
      for (index, sample) in samples.enumerated() {
        let deadline = origin + ticks(Double(index) * period)
        while mach_absolute_time() < deadline { mach_wait_until(deadline) }
        if lock.withLock({ cancelled }) { return }
        let wake = mach_absolute_time()
        // No catchup: an OS scheduling miss invalidates this synthetic source,
        // rather than emitting an immediate second frame on the old deadline.
        if wake > deadline + ticks(period * 0.1) || prior.map({ wake - $0 < ticks(period * 0.9) }) == true {
          lock.withLock { error = "Controlled source missed its hardware-cadence deadline; no catchup emitted." }
          return
        }
        var before = timespec(), after = timespec()
        let beforeStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &before)
        do {
          try lock.withLock {
            guard try sink.send(sample) else { throw VideoError.message("Controlled producer queue is full; no retry/catchup emitted.") }
            emissions.append(now())
          }
        } catch {
          lock.withLock { self.error = error.localizedDescription }; return
        }
        let afterStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &after)
        let elapsed = beforeStatus == 0 && afterStatus == 0 ?
          Double(after.tv_sec - before.tv_sec) * 1000 + Double(after.tv_nsec - before.tv_nsec) / 1_000_000 : .infinity
        lock.withLock { cpuMS.append(elapsed) }
        if elapsed > 0.5 { lock.withLock { error = "Prepared source enqueue exceeded its 0.5ms CPU budget." }; return }
        prior = wake
      }
    }
    producer.qualityOfService = .userInteractive
    producer.start()
  }
}

func controlledComparison(sink: CameraSink, source: SourceQueue, factory: VideoSampleFactory,
  fixtures: [CVPixelBuffer], mode: SyntheticMode, duration: CMTime, count: Int,
  monitor: MonitorComparison?, grid: SourceCadenceGrid) throws -> CameraReceipt {
  let fixtureCount = fixtures.count
  let epoch = grid.nextEpoch()
  log("CMIO_SEGMENT monitorEnabled=\(monitor != nil) epochPTS=\(epoch.value)/\(epoch.timescale) gridAnchorPTS=\(grid.anchor.value)/\(grid.anchor.timescale) connectionReused=true receiverArrival=CMIOInsertionCallback")
  let samples = try (0..<count).map {
    try factory.sample(fixtures[$0 % fixtureCount],
      at: CMTimeAdd(epoch, CMTimeMultiply(duration, multiplier: Int32($0))), duration: duration)
  }
  let producer = ControlledCameraProducer(samples: samples, sink: sink, period: duration.seconds)
  producer.start()
  var joined = false
  defer {
    producer.cancel()
    if !joined, producer.finished.wait(timeout: .now() + 1) != .success {
      // A blocked sender must never race stream disconnect or fixture release.
      // The process watchdog is the final boundary for a stuck system call.
      fputs("CMIO_SMOKE FAIL controlled sender could not join before cleanup.\n", stderr)
      _exit(124)
    }
  }
  let deadline = now() + Double(count) * duration.seconds + 5
  var received = 0, monitorOffered = 0, excludedWarm = 0, excludedStandby = 0
  var previous: CMTime?
  var latenciesMS: [Double] = [], inspectionDelaysMS: [Double] = []
  while received < count && now() < deadline {
    let state = producer.snapshot()
    if let error = state.error { throw VideoError.message(error) }
    while monitorOffered < state.times.count {
      monitor?.offer(samples[monitorOffered], sequence: UInt64(monitorOffered + 1),
        sourceHostTime: state.times[monitorOffered])
      monitorOffered += 1
    }
    while let delivery = try source.nextArrival() {
      let sample = delivery.sample, arrival = delivery.hostTime
      let inspectionStart = now()
      let marker = try inspect(sample, duration: duration, mode: mode)
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      let sent = producer.snapshot().times
      let expected = CMTimeAdd(epoch, CMTimeMultiply(duration, multiplier: Int32(received)))
      let context = "marker=\(marker) index=\(received) sentCount=\(sent.count) actualPTS=\(time.value)/\(time.timescale) expectedPTS=\(expected.value)/\(expected.timescale) epochPTS=\(epoch.value)/\(epoch.timescale) arrivalHost=\(arrival) lastEnqueueHost=\(sent.last ?? -1)"
      try require(time.isNumeric && time.epoch == 0, "Controlled receiver invalid timestamp: \(context)")
      // Shader initialization and immutable fixture preparation are excluded
      // warmup. The installed extension emits black after 0.5s without input;
      // those already-queued pre-epoch standby samples are not source frames.
      // Once measurement begins, no black/warm/stale/duplicate is tolerated.
      if CMTimeCompare(time, epoch) < 0 && (marker == 63 || marker == mode.black) {
        if marker == 63 { excludedWarm += 1 } else { excludedStandby += 1 }
        continue
      }
      try require(received < sent.count, "Controlled consumer received an unsent/duplicate frame: \(context)")
      try require(marker == UInt16(64 + received % fixtureCount), "Controlled synthetic marker order mismatch: \(context)")
      try require(time == expected, "Controlled receiver changed exact original PTS or frame order: \(context)")
      if let previous { try require(CMTimeSubtract(time, previous) == duration, "Controlled receiver rational cadence changed.") }
      previous = time
      latenciesMS.append((arrival - sent[received]) * 1000)
      inspectionDelaysMS.append((inspectionStart - arrival) * 1000)
      received += 1
    }
    pollPause()
  }
  try require(received == count, "Controlled receiver deadline expired after \(received)/\(count) frames.")
  // Main-thread monitor submission can lag the last receive slightly; it stays
  // outside the source thread and is always after successful original enqueue.
  let finalTimes = producer.snapshot().times
  while monitorOffered < finalTimes.count {
    monitor?.offer(samples[monitorOffered], sequence: UInt64(monitorOffered + 1),
      sourceHostTime: finalTimes[monitorOffered]); monitorOffered += 1
  }
  try require(producer.finished.wait(timeout: .now() + 1) == .success, "Controlled source teardown deadline.")
  joined = true
  let state = producer.snapshot()
  if let error = state.error { throw VideoError.message(error) }
  try require(state.setup == KERN_SUCCESS && state.active && state.postReadback == KERN_SUCCESS && state.postActive && state.restore == KERN_SUCCESS,
    "Controlled source policy pre/post readback and restore must all succeed.")
  try require(state.times.count == count && state.cpu.count == count && (state.cpu.max() ?? .infinity) <= 0.5,
    "Controlled source must enqueue every precomputed sample within its bounded CPU budget.")
  let intervals = zip(state.times.dropFirst(), state.times).map { $0.0 - $0.1 }
  let span = (state.times.last ?? 0) - (state.times.first ?? 0)
  let observedHz = Double(count - 1) / span, nominalHz = 1 / duration.seconds
  log("CMIO_PRODUCER monitorEnabled=\(monitor != nil) nominalHz=\(nominalHz) observedHz=\(observedHz) intervalMinMS=\((intervals.min() ?? 0)*1000) intervalP95MS=\(percentile(intervals,0.95)*1000) intervalP99MS=\(percentile(intervals,0.99)*1000) minimumIntervalMS=\(duration.seconds*0.90*1000) minimumHz=\(nominalHz*0.98) timestampOrigin=successfulSenderEnqueue sourceCallbackCPUMaxMS=\(state.cpu.max() ?? .infinity) sourcePolicySetup=\(state.setup) sourcePolicyActive=\(state.active) sourcePolicyPostReadback=\(state.postReadback) sourcePolicyPostActive=\(state.postActive) sourcePolicyRestore=\(state.restore) fixtureImages=\(fixtureCount) warmupExcluded=true")
  try require(observedHz >= nominalHz * 0.98, "Controlled source rate below 98% nominal.")
  try require((intervals.min() ?? 0) >= duration.seconds * 0.90, "Controlled source interval below 90% nominal.")
  try monitor?.finish(seconds: Double(count) * duration.seconds)
  log("CMIO_SMOKE PASS sent=\(state.times.count) received=\(received) requested=\(mode.summary(duration:duration)) exactPixels=true exactPTS=true retries=0 monitorEnabled=\(monitor != nil) receiverCallbackP95MS=\(percentile(latenciesMS,0.95)) receiverCallbackP99MS=\(percentile(latenciesMS,0.99)) callbackToInspectionP95MS=\(percentile(inspectionDelaysMS,0.95)) callbackToInspectionP99MS=\(percentile(inspectionDelaysMS,0.99)) controlledSource=true excludedPreEpochWarm=\(excludedWarm) excludedPreEpochStandby=\(excludedStandby)")
  return CameraReceipt(latencyMS: latenciesMS, retries: 0)
}

func smoke() throws {
  var arguments = Array(CommandLine.arguments.dropFirst())
  var segmentSeconds: Double?
  if let index = arguments.firstIndex(of: "--segment-seconds") {
    try require(index + 1 < arguments.count, "--segment-seconds needs a duration.")
    guard let seconds = Double(arguments[index + 1]), seconds.isFinite, seconds >= 1, seconds <= 60 else {
      throw VideoError.message("--segment-seconds must be between 1 and 60.")
    }
    segmentSeconds = seconds
    arguments.removeSubrange(index...index + 1)
  }
  let monitorComparison = arguments.contains("--monitor")
  try require(segmentSeconds == nil || monitorComparison, "--segment-seconds is available only with --monitor.")
  try require(arguments.first == "--run" && Set(arguments).isSubset(of: ["--run", "--full", "--monitor"]),
    "Pass --run (optionally --full and --monitor) for the synthetic installed-camera check.")
  // CMIO's synchronous IPC APIs have no per-call timeout. Bound even a stalled
  // service call with a process-local watchdog; normal paths stop both streams.
  let profileCount = arguments.contains("--full") ? 6.0 : 2.0
  let watchdog = monitorComparison ? max(180.0, (segmentSeconds ?? 6) * 2 * profileCount + 90) : 60.0
  DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + watchdog) {
    fputs("CMIO_SMOKE FAIL process watchdog expired.\n", stderr)
    _exit(124)
  }
  var code: SecCode?
  try check(SecCodeCopySelf([], &code), "Read helper signature")
  var requirement: SecRequirement?
  try check(SecRequirementCreateWithString("identifier \"org.ultracam.app\"" as CFString, [], &requirement), "Create helper signing requirement")
  try check(SecCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate), requirement), "Validate helper signature and producer identifier")
  var staticCode: SecStaticCode?
  try check(SecCodeCopyStaticCode(code!, [], &staticCode), "Read helper static code")
  var signing: CFDictionary?
  try check(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &signing), "Read helper signing identifier")
  let identifier = (signing as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
  try require(identifier == "org.ultracam.app", "Helper must be signed as the authorized synthetic producer.")
  log("CMIO_SMOKE begin pid=\(ProcessInfo.processInfo.processIdentifier) signingID=\(identifier!) syntheticOnly=true")
  let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Bounded synthetic camera IPC verification")
  defer { ProcessInfo.processInfo.endActivity(activity) }
  var modes = [SyntheticMode(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
  if arguments.contains("--full") {
    modes += [SyntheticMode(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
      SyntheticMode(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10)]
  }
  let route = try currentRoute()
  for mode in modes {
    let pool = try makePool(mode)
    for fast in [false, true] {
      let duration = fast ? VideoContract.fastDuration : VideoContract.slowDuration
      let count = segmentSeconds.map { Int(ceil($0 / duration.seconds)) } ?? (monitorComparison ? 180 : 60)
      log("CMIO_WORKLOAD segmentRequestedSeconds=\(segmentSeconds.map { String($0) } ?? "default") framesPerSegment=\(count) effectiveSegmentSeconds=\(Double(count) * duration.seconds) allOutliersRetained=true")
      try runCase(fast: fast, pool: pool, mode: mode, route: route,
        frameCount: count, pairedMonitor: monitorComparison)
    }
  }
}

@discardableResult
func runCase(fast: Bool, pool: CVPixelBufferPool, mode: SyntheticMode,
  route: CameraSinkRoute, monitorEnabled: Bool = false, frameCount: Int = 60,
  pairedMonitor: Bool = false) throws -> CameraReceipt {
  let duration = fast ? VideoContract.fastDuration : VideoContract.slowDuration
  log("CMIO_SMOKE case requested=\(mode.summary(duration: duration))")
  let sink = CameraSink(route: route, registrySnapshot: { nil })
  defer { sink.disconnect(); log("CMIO_SMOKE producerDisconnected") }
  var configuration = PipelineConfiguration()
  configuration.inputFast = fast
  configuration.downscale = mode.width == 1920
  configuration.convertTo420 = mode.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  let discoveryDeadline = now() + 5
  var connected = false
  var lastError = ""
  repeat {
    do {
      try sink.connect(configuration: configuration, passthroughFormat: mode.format)
      connected = true
      break
    } catch {
      lastError = error.localizedDescription
      // Discovery can lag extension activation. Authorization, negotiation and
      // stream-start errors require investigation, not repeated OS requests.
      guard lastError.hasPrefix("Install and approve") else { throw error }
      Thread.sleep(forTimeInterval: 0.1)
    }
  } while now() < discoveryDeadline
  try require(connected, "Producer connection deadline: \(lastError)")
  log("CMIO_SMOKE producerConnected")
  let arrivalContext = pairedMonitor ? try SourceArrivalContexts.shared.make() : nil
  let source = try SourceQueue(route: route, arrivals: arrivalContext)
  defer { source.stop() }
  log("CMIO_SMOKE contract requested=\(mode.summary(duration: duration)) negotiated=\(source.negotiatedFormat.map { $0.description } ?? "unavailable")")
  let factory = VideoSampleFactory()
  let hostClock = CMClockGetHostTimeClock()
  let warm = try factory.sample(image(marker: 63, pool: pool, mode: mode), at: CMClockGetTime(hostClock), duration: duration)
  let warmSent = try sink.send(warm)
  try require(warmSent, "Warmup producer queue is full.")
  let warmDeadline = now() + 3
  var warmReceived = false
  var standby = 0
  func nextWarm() throws -> CMSampleBuffer? {
    if pairedMonitor { return try source.nextArrival()?.sample }
    return source.next()
  }
  repeat {
    if let sample = try nextWarm() {
      let marker = try inspect(sample, duration: duration, mode: mode)
      if marker == 63 { warmReceived = true; break }
      try require(marker == mode.black, "Unexpected preflight marker \(marker).")
      standby += 1
    } else { pollPause() }
  } while now() < warmDeadline
  try require(warmReceived, "No synthetic warmup returned through installed extension within 3 seconds.")
  log("CMIO_SMOKE warmupReceived standby=\(standby)")
  if pairedMonitor {
    let monitor = MonitorComparison()
    try monitor.prewarm(warm) // compile/warm before BOTH connected measurements
    let fixtures = try (0..<8).map { try image(marker: UInt16(64 + $0), pool: pool, mode: mode) }
    let grid = SourceCadenceGrid(anchor: CMTimeConvertScale(CMClockGetTime(hostClock),
      timescale: 60_000, method: .default), duration: duration)
    let baseline = try controlledComparison(sink: sink, source: source, factory: factory,
      fixtures: fixtures, mode: mode, duration: duration, count: frameCount, monitor: nil, grid: grid)
    let enabled = try controlledComparison(sink: sink, source: source, factory: factory,
      fixtures: fixtures, mode: mode, duration: duration, count: frameCount, monitor: monitor, grid: grid)
    let p95 = percentile(enabled.latencyMS, 0.95), p99 = percentile(enabled.latencyMS, 0.99)
    let baseline95 = percentile(baseline.latencyMS, 0.95), baseline99 = percentile(baseline.latencyMS, 0.99)
    log("CMIO_MONITOR_COMPARISON receiverArrival=CMIOInsertionCallback sameConnection=true sameCadenceGrid=true baselineP95MS=\(baseline95) enabledP95MS=\(p95) baselineP99MS=\(baseline99) enabledP99MS=\(p99) p95ToleranceMS=2 p99ToleranceMS=5")
    arrivalContext?.report()
    logLatencyDistribution("baseline", values: baseline.latencyMS)
    logLatencyDistribution("enabled", values: enabled.latencyMS)
    let p95Limit = baseline95 + 2, p99Limit = baseline99 + 5
    log("CMIO_LATENCY_EXCEEDANCES enabledAboveBaselineP95Plus2MS=\(enabled.latencyMS.filter { $0 > p95Limit }.count) enabledAboveBaselineP99Plus5MS=\(enabled.latencyMS.filter { $0 > p99Limit }.count) enabledCount=\(enabled.latencyMS.count) baselineCount=\(baseline.latencyMS.count) p95LimitMS=\(p95Limit) p99LimitMS=\(p99Limit) trimming=false")
    for (index, latency) in enabled.latencyMS.enumerated() where latency > p99Limit {
      log("CMIO_LATENCY_OUTLIER segment=enabled index=\(index) callbackLatencyMS=\(latency) baselineP99Plus5LimitMS=\(p99Limit)")
    }
    try require(p95 <= baseline95 + 2 && p99 <= baseline99 + 5,
      "Receiver callback latency regression: p95=\(p95) baseline=\(baseline95)+2ms p99=\(p99) baseline=\(baseline99)+5ms.")
    try require(enabled.retries <= baseline.retries, "Monitoring increased producer queue-full retries.")
    log("CMIO_MONITOR_COMPARISON PASS requested=\(mode.summary(duration: duration)) exactPixelsPTSCountsCadence=true physicalCapture=false")
    return enabled
  }
  let monitor = monitorEnabled ? MonitorComparison() : nil
  try monitor?.prewarm(warm)
  let count = frameCount
  let epoch = CMTimeConvertScale(CMClockGetTime(hostClock), timescale: 60_000, method: .default)
  let start = now()
  var received = 0
  var sent = 0
  var retries = 0
  var previous: CMTime?
  var origins: [Double] = [], emittedAt: [Double] = [], latenciesMS: [Double] = []
  func consume() throws {
    while let sample = source.next() {
      let arrival = now()
      let marker = try inspect(sample, duration: duration, mode: mode)
      if marker == 63 { continue }
      try require(received < sent, "Received an unsent or duplicate synthetic frame.")
      try require(marker == UInt16(64 + received), "Synthetic marker order/count mismatch: expected \(64 + received), received \(marker).")
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      let expected = CMTimeAdd(epoch, CMTimeMultiply(duration, multiplier: Int32(received)))
      try require(time.isNumeric && time.epoch == 0 && time == expected, "Installed camera changed producer timestamp for marker \(marker).")
      if let previous { try require(CMTimeSubtract(time, previous) == duration, "Output cadence differs from the negotiated rational duration.") }
      previous = time
      latenciesMS.append((arrival - origins[received]) * 1000)
      received += 1
    }
  }
  for index in 0..<count {
    let deadline = start + Double(index) * duration.seconds
    while now() < deadline { try consume(); pollPause() }
    origins.append(now())
    let sample = try factory.sample(image(marker: UInt16(64 + index), pool: pool, mode: mode),
      at: CMTimeAdd(epoch, CMTimeMultiply(duration, multiplier: Int32(index))), duration: duration)
    let sendDeadline = now() + 0.25
    while try !sink.send(sample) {
      retries += 1
      try consume()
      try require(now() < sendDeadline, "Producer queue remained full for 250 milliseconds.")
      pollPause()
    }
    emittedAt.append(now()) // actual successful CMIO enqueue, after source CPU work
    sent += 1
    monitor?.offer(sample, sequence: UInt64(index + 1))
    try consume()
  }
  let finalDeadline = now() + 3
  while received < count && now() < finalDeadline { try consume(); pollPause() }
  try require(received == count, "Consumer deadline: received \(received) of \(count) synthetic frames.")
  try monitor?.finish(seconds: Double(count) * duration.seconds)
  try check(source.stop(), "Stop and unregister synthetic consumer")
  log("CMIO_SMOKE PASS sent=\(sent) received=\(received) requested=\(mode.summary(duration: duration)) negotiated=\(source.negotiatedFormat.map { $0.description } ?? "unavailable") exactPixels=true exactPTS=true retries=\(retries) monitorEnabled=\(monitorEnabled) receiverP95MS=\(percentile(latenciesMS, 0.95)) receiverP99MS=\(percentile(latenciesMS, 0.99))")
  return CameraReceipt(latencyMS: latenciesMS, retries: retries)
}

/// --monitor-gpu-check: MonitorComparison's monitor load (the app's Metal 4
/// monitor path) over the same synthetic IOSurface frames, offered at both camera
/// cadences, with no CMIO connection: it never touches the installed extension.
/// --full adds the 4K ten-bit x422 and v210 profiles. The rate, age and
/// failed-encode gates are MonitorComparison's.
func monitorGPUCheck(full: Bool) throws {
  DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 120) {
    fputs("CMIO_SMOKE FAIL process watchdog expired.\n", stderr)
    _exit(124)
  }
  var modes = [SyntheticMode(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
  if full {
    modes += [SyntheticMode(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
      SyntheticMode(width: 3840, height: 2160, format: kCVPixelFormatType_422YpCbCr10)]
  }
  let factory = VideoSampleFactory()
  let hostClock = CMClockGetHostTimeClock()
  for mode in modes {
    let pool = try makePool(mode)
    for fast in [false, true] {
      let duration = fast ? VideoContract.fastDuration : VideoContract.slowDuration
      let count = 180
      let monitor = MonitorComparison()
      let warm = try factory.sample(image(marker: 63, pool: pool, mode: mode),
        at: CMClockGetTime(hostClock), duration: duration)
      try monitor.prewarm(warm)
      let fixtures = try (0..<8).map { try image(marker: UInt16(64 + $0), pool: pool, mode: mode) }
      let epoch = CMClockGetTime(hostClock)
      let start = now()
      for index in 0..<count {
        let deadline = start + Double(index) * duration.seconds
        while now() < deadline { pollPause() }
        let sample = try factory.sample(fixtures[index % fixtures.count],
          at: CMTimeAdd(epoch, CMTimeMultiply(duration, multiplier: Int32(index))), duration: duration)
        monitor.offer(sample, sequence: UInt64(index + 1), sourceHostTime: now())
      }
      try monitor.finish(seconds: Double(count) * duration.seconds)
      log("CMIO_MONITOR_GPU_CHECK PASS requested=\(mode.summary(duration: duration)) frames=\(count) cmio=false")
    }
  }
}

func currentRoute() throws -> CameraSinkRoute {
  let registry = try VirtualCameraRegistryTransport.read(VirtualCameraRegistryTransport.providerID())
  guard let descriptor = registry.devices.first(where: \.enabled) else {
    throw VideoError.message("No enabled Ultracam camera is published.")
  }
  return CameraSinkRoute(descriptor: descriptor)
}

func consumerRequest(seconds: Double) throws {
  try require(seconds >= 1 && seconds <= 45, "Consumer duration must be 1…45 seconds.")
  DispatchQueue.global().asyncAfter(deadline: .now() + 60) { _exit(124) }
  var visibility = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
  var allow: UInt32 = 1
  try check(CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &visibility,
    0, nil, UInt32(MemoryLayout<UInt32>.size), &allow), "Enumerate virtual cameras")
  let source = try SourceQueue(route: currentRoute())
  defer { source.stop() }
  let deadline = now() + seconds
  var count = 0
  var previous: CMTime?
  var discontinuities = 0
  var description = ""
  while now() < deadline {
    if let sample = source.next() {
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      try require(time.isNumeric, "Consumer received invalid timestamp.")
      if let previous, CMTimeCompare(time, previous) <= 0 { discontinuities += 1 }
      previous = time
      count += 1
      if let format = CMSampleBufferGetFormatDescription(sample) {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        description = "\(size.width)x\(size.height) \(VideoContract.fourCC(CMFormatDescriptionGetMediaSubType(format)))"
      }
    } else { pollPause() }
  }
  try check(source.stop(), "Stop requested source")
  try require(count > 0, "Consumer received no frames.")
  log("CMIO_CONSUMER PASS frames=\(count) lastFormat=\(description) nonmonotonicPTS=\(discontinuities) duration=\(seconds) imagesRead=false")
}

func registryCheck() throws {
  let provider = try VirtualCameraRegistryTransport.providerID()
  let original = try VirtualCameraRegistryTransport.read(provider)
  defer {
    do { _ = try VirtualCameraRegistryTransport.synchronize(original) }
    catch { log("CMIO_REGISTRY restore failed: \(error.localizedDescription)") }
  }
  let feed = VirtualCameraDescriptor.feed(feedID: FeedID.primary.rawValue, displayName: "Ultracam · Registry Test")
  let other = VirtualCameraDescriptor.feed(feedID: "registry-second", displayName: "Ultracam · Second Test")
  let mode = SyntheticMode(width: 1920, height: 1080, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
  let pool = try makePool(mode)
  for descriptors in [[feed, other], [.program()], [], [feed]] {
    let desired = VirtualCameraRegistrySnapshot(generation: 1, devices: descriptors)
    let applied = try VirtualCameraRegistryTransport.synchronize(desired)
    try require(applied.devices == descriptors, "Live registry acknowledgement differs from request.")
    log("CMIO_REGISTRY applied generation=\(applied.generation) devices=\(descriptors.count)")
    if let descriptor = descriptors.first {
      // CMIO's topology notification is asynchronous to the synchronous
      // registry acknowledgement. Allow device discovery to receive it.
      let deadline = now() + 5
      while !(try ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        .contains(where: { try string($0, kCMIODevicePropertyDeviceUID) == descriptor.deviceUID })) && now() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
      }
      try runCase(fast: false, pool: pool, mode: mode, route: CameraSinkRoute(descriptor: descriptor))
    }
  }
  let restored = try VirtualCameraRegistryTransport.synchronize(original)
  try require(restored.devices == original.devices, "Original registry was not restored.")
  log("CMIO_REGISTRY PASS feedToProgram=true emptyRegistryRecovery=true physicalCapture=false")
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  if args == ["--registry-check"] { try registryCheck() }
  else if args == ["--monitor-gpu-check"] || args == ["--monitor-gpu-check", "--full"] {
    try monitorGPUCheck(full: args.count == 2)
  }
  else if args.count == 2, args[0] == "--consumer", let seconds = Double(args[1]) {
    try consumerRequest(seconds: seconds)
  } else { try smoke() }
}
catch { fputs("CMIO_SMOKE FAIL \(error.localizedDescription)\n", stderr); exit(1) }
