@preconcurrency import CoreVideo
import Foundation
import IOSurface
@preconcurrency import Metal
import MonitorToolsCore

/// The shared GPU side of monitoring: one device, one Metal 4 queue, the
/// compiled pipelines, the residency set and the IOSurface texture cache.
/// Every monitor surface encodes through it. Nothing here copies pixels, and
/// nothing decides to skip a frame.
public final class MonitorRuntime: @unchecked Sendable {
  /// One runtime per process is the normal case; tests may make their own.
  public static let shared = MonitorRuntime()

  /// Guards the built context, the last failure and pending drawable sets.
  /// Held only for a few loads and stores, never across a shader compile, so
  /// main-thread readers (layer device, status, drawable attachment) never wait.
  private let stateLock = NSLock()
  /// Serializes the one-time build. Only callers that need a context take it.
  private let buildLock = NSLock()
  private let deviceProvider: () -> MTLDevice?
  private let shaderSource: String?
  private let gpuTiming: @Sendable (Double, Double) -> Void
  private var context: MonitorMetalContext?
  private var failure: Error?
  /// After a failed build, callers get the stored error until this uptime;
  /// the delay doubles per failure (1 s to 30 s) so a broken shader is not
  /// recompiled on every frame.
  private var retryAt = 0.0
  private var retryDelay = 1.0
  static let maximumRetryDelay = 30.0
  /// Drawable residency sets attached before the context exists.
  private var pendingDrawables: [ObjectIdentifier: MTLResidencySet] = [:]

  public init(
    sharedDevice: @escaping () -> MTLDevice? = { MTLCreateSystemDefaultDevice() },
    shaderSource: String? = nil,
    gpuTiming: @escaping @Sendable (Double, Double) -> Void = { _, _ in }
  ) {
    deviceProvider = sharedDevice
    self.shaderSource = shaderSource
    self.gpuTiming = gpuTiming
  }

  /// The GPU context, built once on first use. Concurrent callers wait for the
  /// one build instead of starting their own. A failure is kept and reported,
  /// and retried only after a growing delay.
  func metal() throws -> MonitorMetalContext {
    if let ready = try readyContext() { return ready }
    buildLock.lock()
    defer { buildLock.unlock() }
    // Another caller may have finished (or failed) the build while this one waited.
    if let ready = try readyContext() { return ready }
    let made: MonitorMetalContext
    do {
      guard let device = deviceProvider() else { throw MonitorPreviewError.shadersUnavailable }
      made = try MonitorMetalContext(device: device, source: shaderSource, gpuTiming: gpuTiming)
    } catch {
      stateLock.lock()
      failure = error
      retryAt = ProcessInfo.processInfo.systemUptime + retryDelay
      retryDelay = min(Self.maximumRetryDelay, retryDelay * 2)
      stateLock.unlock()
      throw error
    }
    stateLock.lock()
    context = made
    failure = nil
    retryDelay = 1
    // Under the lock so a concurrent detach cannot slip between the two.
    for set in pendingDrawables.values { made.attach(set) }
    pendingDrawables.removeAll()
    stateLock.unlock()
    return made
  }

  /// The built context, or the stored failure while its retry delay runs.
  private func readyContext() throws -> MonitorMetalContext? {
    stateLock.lock()
    defer { stateLock.unlock() }
    if let context { return context }
    if let failure, ProcessInfo.processInfo.systemUptime < retryAt { throw failure }
    return nil
  }

  /// The context if it is already built. Never compiles and never waits.
  var builtContext: MonitorMetalContext? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return context
  }

  /// Nil while the GPU is usable (or not yet tried).
  public var unavailableReason: String? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return failure.map { "Monitor GPU unavailable: \($0)" }
  }

  public var device: MTLDevice? { try? metal().device }
  /// The device for a CAMetalLayer, without compiling shaders on the caller's thread.
  public var layerDevice: MTLDevice? {
    builtContext?.device ?? deviceProvider()
  }
  /// Builds the GPU context off the main thread so the first surface does not wait.
  public func prepare() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in _ = try? metal() }
  }
  /// The thread that runs every surface's display link and encodes its frames.
  public let renderThread = MonitorRenderThread()

  /// Counts of GPU objects the runtime has made. In steady state none of these grow.
  public var gpuStatistics: MonitorGPUStatistics {
    guard let metal = builtContext else { return MonitorGPUStatistics() }
    return MonitorGPUStatistics(
      wrappedTextures: metal.textures.made, cachedTextures: metal.textures.count,
      encodeContexts: metal.contextCount)
  }

  /// The GPU view of `bundle`: its IOSurfaces as cached textures, no copy.
  public func gpuFrame(_ bundle: MonitorFrameBundle) throws -> MonitorGPUFrame {
    try metal().textures.frame(bundle)
  }

  /// Ends residency of a frozen frame's owned copies once queued GPU work is done.
  public func release(_ frame: MonitorGPUFrame) {
    guard !frame.borrowsProducerBuffers, let metal = builtContext else { return }
    let context = metal.acquire()
    var textures = [frame.source.plane0]
    if frame.source.isBiplanar { textures.append(frame.source.plane1) }
    if let output = frame.output, !output.isSameImage(as: frame.source) {
      textures.append(output.plane0)
      if output.isBiplanar { textures.append(output.plane1) }
    }
    for texture in textures {
      context.retain(texture)
      context.retireResident(texture)
    }
    metal.commit(context, drawable: nil, completion: nil, kind: 0)
  }

  /// Begins a Metal 4 submission. Commit it with `commit(_:drawable:completion:kind:)`.
  public func beginEncoding() throws -> MonitorEncodeContext { try metal().acquire() }

  /// Commits `context`; with a drawable, the GPU waits for it and presents it after.
  public func commit(
    _ context: MonitorEncodeContext, drawable: MTLDrawable? = nil,
    completion: MonitorEncodeCompletion? = nil, kind: Int = 0
  ) {
    // A context only exists once the GPU context does.
    guard let metal = builtContext else { return }
    metal.commit(context, drawable: drawable, completion: completion, kind: kind)
  }

  /// Returns a context whose encoding failed before commit.
  public func abandon(_ context: MonitorEncodeContext) { builtContext?.abandon(context) }

  /// Keeps a layer's drawables resident for this runtime's queue. Safe on the
  /// main thread: before the context is built the set waits and is attached
  /// by the build.
  public func attachDrawables(_ set: MTLResidencySet) {
    stateLock.lock()
    guard let context else {
      pendingDrawables[ObjectIdentifier(set)] = set
      stateLock.unlock()
      return
    }
    stateLock.unlock()
    context.attach(set)
  }
  public func detachDrawables(_ set: MTLResidencySet) {
    stateLock.lock()
    pendingDrawables.removeValue(forKey: ObjectIdentifier(set))
    let context = context
    stateLock.unlock()
    context?.detach(set)
  }

  /// Drops the cached IOSurface textures of `target`'s frames, for example
  /// when its capture stops or changes device. Their residency ends after
  /// queued GPU work is done. Never compiles or waits.
  public func flushTextures(for target: MonitorTargetID) {
    builtContext?.flushTextures(for: target)
  }

  /// Test and tooling helper: renders one frame offscreen and waits for the GPU.
  /// The live app never calls this; surfaces encode on their display link.
  public func renderSnapshot(
    _ bundle: MonitorFrameBundle, configuration: MonitorConfiguration, clean: Bool = false,
    width: Int? = nil, height: Int? = nil, aperture: MonitorRect? = nil, scopes: Bool = true
  ) throws -> MonitorSnapshot {
    let metal = try metal()
    let frame = try metal.textures.frame(bundle)
    let renderer = MonitorToolsRenderer(runtime: self)
    let picture = frame.planes(for: configuration.pictureStage)
    let size =
      width.flatMap { w in height.map { (w, $0) } }
      ?? MonitorSnapshot.defaultSize(width: picture.width, height: picture.height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    guard let target = metal.device.makeTexture(descriptor: descriptor) else {
      throw MonitorPreviewError.allocationFailed
    }
    var scopeTarget: MTLTexture?
    if scopes {
      let scopeDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: MonitorToolsRenderer.scopeWidth,
        height: MonitorToolsRenderer.scopeHeight, mipmapped: false)
      scopeDescriptor.usage = [.shaderRead, .shaderWrite]
      scopeDescriptor.storageMode = .shared
      scopeTarget = metal.device.makeTexture(descriptor: scopeDescriptor)
    }
    metal.makeResident(target)
    if let scopeTarget { metal.makeResident(scopeTarget) }
    defer {
      metal.removeResident(target)
      if let scopeTarget { metal.removeResident(scopeTarget) }
      renderer.invalidate()
    }
    let state = MonitorRenderState(configuration: configuration, clean: clean, aperture: aperture)
    let encoder = MonitorSnapshotCompletion()
    let context = metal.acquire()
    let viewport = MonitorViewport(width: size.0, height: size.1)
    var scopeEncoded = false
    do {
      try renderer.encode(
        frame: frame, state: state, target: target, viewport: viewport, into: context)
      if let scopeTarget, renderer.wantsScopes(state) {
        try renderer.encodeScopes(frame: frame, state: state, target: scopeTarget, into: context)
        scopeEncoded = true
      }
    } catch {
      metal.abandon(context)
      throw error
    }
    metal.commit(context, drawable: nil, completion: encoder, kind: 0)
    guard encoder.wait() else { throw MonitorPreviewError.gpuFailed }
    return MonitorSnapshot(
      picture: target, scope: scopeEncoded ? scopeTarget : nil, availability: renderer.status,
      pictureSignal: frame.signal(for: configuration.pictureStage, configuration: configuration),
      scopeSignal: frame.signal(for: configuration.scopeStage, configuration: configuration))
  }
}

public struct MonitorGPUStatistics: Equatable, Sendable {
  /// IOSurface plane textures made since launch, and how many are cached now.
  public var wrappedTextures = 0
  public var cachedTextures = 0
  /// Pooled Metal 4 submissions (command buffer, allocator, argument table).
  public var encodeContexts = 0
  public init(wrappedTextures: Int = 0, cachedTextures: Int = 0, encodeContexts: Int = 0) {
    self.wrappedTextures = wrappedTextures
    self.cachedTextures = cachedTextures
    self.encodeContexts = encodeContexts
  }
}

/// A rendered offscreen picture and, when requested, its scope.
public struct MonitorSnapshot: @unchecked Sendable {
  public let picture: MTLTexture
  public let scope: MTLTexture?
  public let availability: [String]
  public let pictureSignal: MonitorFrameSignal?
  public let scopeSignal: MonitorFrameSignal?
  public var width: Int { picture.width }
  public var height: Int { picture.height }
  /// Tightly packed BGRA rows, `width * 4` bytes each.
  public var pictureBytes: [UInt8] { Self.bytes(picture) }
  public var scopeBytes: [UInt8]? { scope.map(Self.bytes) }
  public static func bytes(_ texture: MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
      &bytes, bytesPerRow: texture.width * 4,
      from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return bytes
  }
  /// The picture size the old composited monitor used: fit within 1920×1080.
  public static func defaultSize(width: Int, height: Int) -> (Int, Int) {
    let scale = min(1.0, min(1080.0 * 16 / 9 / Double(width), 1080.0 / Double(height)))
    return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
  }
}

/// Receives GPU completion for one committed encode context.
public protocol MonitorEncodeCompletion: AnyObject, Sendable {
  /// Called on the runtime's feedback queue once the GPU has finished.
  func encodeCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool)
}

private final class MonitorSnapshotCompletion: MonitorEncodeCompletion, @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private var succeeded = false
  func encodeCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    succeeded = !failed
    semaphore.signal()
  }
  func wait() -> Bool {
    _ = semaphore.wait(timeout: .now() + 30)
    return succeeded
  }
}

/// One reusable Metal 4 submission: command buffer, allocator, argument table,
/// a small uniforms buffer and the list of objects kept alive until the GPU
/// finishes. Contexts are pooled; steady state allocates nothing.
public final class MonitorEncodeContext: @unchecked Sendable {
  public let commandBuffer: MTL4CommandBuffer
  public let argumentTable: MTL4ArgumentTable
  let allocator: MTL4CommandAllocator
  let uniforms: MTLBuffer
  let commitList: [MTL4CommandBuffer]
  private var uniformOffset = 0
  private var retained: [AnyObject] = []
  private var retiredResidents: [MTLAllocation] = []
  fileprivate var completion: MonitorEncodeCompletion?
  fileprivate var kind = 0
  static let uniformStride = 256
  static let uniformCapacity = 16

  fileprivate init(device: MTLDevice) throws {
    guard let allocator = device.makeCommandAllocator(),
      let commandBuffer = device.makeCommandBuffer(),
      let uniforms = device.makeBuffer(
        length: Self.uniformStride * Self.uniformCapacity, options: .storageModeShared)
    else { throw MonitorPreviewError.allocationFailed }
    let tableDescriptor = MTL4ArgumentTableDescriptor()
    tableDescriptor.maxBufferBindCount = 4
    tableDescriptor.maxTextureBindCount = 8
    argumentTable = try device.makeArgumentTable(descriptor: tableDescriptor)
    self.allocator = allocator
    self.commandBuffer = commandBuffer
    self.uniforms = uniforms
    commitList = [commandBuffer]
    retained.reserveCapacity(32)
    retiredResidents.reserveCapacity(4)
  }

  fileprivate func begin() {
    allocator.reset()
    uniformOffset = 0
    commandBuffer.beginCommandBuffer(allocator: allocator)
  }

  /// Copies `value` into this submission's uniforms and returns its GPU address.
  public func uniform<T>(_ value: T) -> MTLGPUAddress {
    precondition(MemoryLayout<T>.stride <= Self.uniformStride)
    precondition(uniformOffset < Self.uniformStride * Self.uniformCapacity, "Too many uniforms")
    var copy = value
    withUnsafeBytes(of: &copy) {
      uniforms.contents().advanced(by: uniformOffset).copyMemory(
        from: $0.baseAddress!, byteCount: $0.count)
    }
    let address = uniforms.gpuAddress + UInt64(uniformOffset)
    uniformOffset += Self.uniformStride
    return address
  }

  /// Keeps `object` alive until this submission's GPU work completes.
  public func retain(_ object: AnyObject) { retained.append(object) }
  /// Removes `allocation` from residency once this submission completes.
  func retireResident(_ allocation: MTLAllocation) { retiredResidents.append(allocation) }

  fileprivate func finish() -> [MTLAllocation] {
    retained.removeAll(keepingCapacity: true)
    let retired = retiredResidents
    retiredResidents.removeAll(keepingCapacity: true)
    completion = nil
    return retired
  }
}

/// The viewport within the target, in target pixels.
public struct MonitorViewport: Equatable, Sendable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int
  public init(x: Int = 0, y: Int = 0, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// What a renderer draws for one surface: the tools and whether the view is clean.
public struct MonitorRenderState: Equatable, Sendable {
  public var configuration: MonitorConfiguration
  public var clean: Bool
  /// The picture region to show; nil shows the stage's clean aperture.
  public var aperture: MonitorRect?
  public init(configuration: MonitorConfiguration, clean: Bool = false, aperture: MonitorRect? = nil) {
    self.configuration = configuration
    self.clean = clean
    self.aperture = aperture
  }
}

/// The seam between monitor surfaces and the code that draws pixels. A surface
/// owns one picture renderer; it encodes into the surface's Metal 4 command
/// buffer and never commits or waits.
public protocol MonitorPictureRenderer: AnyObject {
  func encode(
    frame: MonitorGPUFrame, state: MonitorRenderState, target: MTLTexture,
    viewport: MonitorViewport, into context: MonitorEncodeContext) throws
  /// Why a requested tool is not drawn, from the last encode.
  var status: [String] { get }
  /// Releases persistent GPU resources once in-flight work no longer needs them.
  func invalidate()
}

/// Scope counterpart: draws the scope image for `frame` into `target`.
public protocol MonitorScopeRenderer: AnyObject {
  func wantsScopes(_ state: MonitorRenderState) -> Bool
  func encodeScopes(
    frame: MonitorGPUFrame, state: MonitorRenderState, target: MTLTexture,
    into context: MonitorEncodeContext) throws
}

/// Device-wide Metal 4 objects. Thread-safe.
final class MonitorMetalContext: @unchecked Sendable {
  let device: MTLDevice
  let queue: MTL4CommandQueue
  let focus: MTLComputePipelineState
  let compose: MTLComputePipelineState
  let scopes: MTLComputePipelineState
  let clear: MTLComputePipelineState
  let residency: MTLResidencySet
  let textures: MonitorSurfaceTextureCache
  private let lock = NSLock()
  private var free: [MonitorEncodeContext] = []
  private var contexts = 0
  var contextCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return contexts
  }
  private let gpuTiming: @Sendable (Double, Double) -> Void

  init(device: MTLDevice, source: String?, gpuTiming: @escaping @Sendable (Double, Double) -> Void)
    throws
  {
    self.device = device
    self.gpuTiming = gpuTiming
    let queueDescriptor = MTL4CommandQueueDescriptor()
    queueDescriptor.label = "MonitorTools"
    guard let queue = try? device.makeMTL4CommandQueue(descriptor: queueDescriptor) else {
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
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor()
    libraryDescriptor.source = shader
    let options = MTLCompileOptions()
    options.mathMode = .safe
    libraryDescriptor.options = options
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      let function = MTL4LibraryFunctionDescriptor()
      function.name = name
      function.library = library
      let descriptor = MTL4ComputePipelineDescriptor()
      descriptor.computeFunctionDescriptor = function
      return try compiler.makeComputePipelineState(descriptor: descriptor)
    }
    focus = try pipeline("sourceFocus")
    compose = try pipeline("compose")
    scopes = try pipeline("scopeColumns")
    clear = try pipeline("clearTarget")
    let residencyDescriptor = MTLResidencySetDescriptor()
    residencyDescriptor.label = "MonitorTools"
    residencyDescriptor.initialCapacity = 64
    residency = try device.makeResidencySet(descriptor: residencyDescriptor)
    queue.addResidencySet(residency)
    textures = MonitorSurfaceTextureCache(device: device)
    textures.context = self
    // Idle textures and retired residency end even when no surface encodes
    // (every feed stopped), at a low rate off the main and render threads.
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in self?.maintain() }
    timer.resume()
    maintenance = timer
  }

  deinit { maintenance?.cancel() }

  private var maintenance: DispatchSourceTimer?

  /// Ends residency of retired allocations and releases idle cached textures.
  func maintain() {
    sweepGraveyard()
    textures.sweepIdle(now: ProcessInfo.processInfo.systemUptime)
  }

  func flushTextures(for target: MonitorTargetID) {
    let removed = textures.flush(target: target)
    if !removed.isEmpty { retire(removed) }
  }

  func makeResident(_ allocation: MTLAllocation) {
    lock.lock()
    residency.addAllocation(allocation)
    residency.commit()
    lock.unlock()
  }

  func removeResident(_ allocation: MTLAllocation) {
    lock.lock()
    residency.removeAllocation(allocation)
    residency.commit()
    lock.unlock()
  }

  /// Earlier submissions on the queue may still read an allocation after a
  /// later one completes, so residency ends one second after retirement.
  private var graveyard: [(time: Double, allocation: MTLAllocation)] = []
  func retire(_ allocations: [MTLAllocation]) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    for allocation in allocations { graveyard.append((now, allocation)) }
    lock.unlock()
  }
  private func sweepGraveyard() {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    guard let first = graveyard.first, now - first.time > 1 else {
      lock.unlock()
      return
    }
    var removed = false
    while let entry = graveyard.first, now - entry.time > 1 {
      residency.removeAllocation(entry.allocation)
      graveyard.removeFirst()
      removed = true
    }
    if removed { residency.commit() }
    lock.unlock()
  }

  func updateResidency(adding: MTLAllocation?, removing: [MTLAllocation]) {
    lock.lock()
    if let adding { residency.addAllocation(adding) }
    for allocation in removing { residency.removeAllocation(allocation) }
    residency.commit()
    lock.unlock()
  }

  /// Adds and removes a layer's drawable residency set from the queue.
  func attach(_ set: MTLResidencySet) { queue.addResidencySet(set) }
  func detach(_ set: MTLResidencySet) { queue.removeResidencySet(set) }

  /// A free submission, or a new one when every existing one is still on the GPU.
  /// Growth happens only while the GPU is behind; it is counted, never a skip.
  func acquire() -> MonitorEncodeContext {
    sweepGraveyard()
    textures.sweepIfDue(now: ProcessInfo.processInfo.systemUptime)
    lock.lock()
    let reused = free.popLast()
    lock.unlock()
    let context: MonitorEncodeContext
    if let reused {
      context = reused
    } else {
      // A device that can run Metal 4 can make these; failure here is fatal misconfiguration.
      context = try! MonitorEncodeContext(device: device)
      lock.lock()
      contexts += 1
      residency.addAllocation(context.uniforms)
      residency.commit()
      lock.unlock()
    }
    context.begin()
    return context
  }

  /// Ends and commits `context`. With a drawable, waits for it on the GPU
  /// timeline and presents it after the work.
  func commit(
    _ context: MonitorEncodeContext, drawable: MTLDrawable?, completion: MonitorEncodeCompletion?,
    kind: Int
  ) {
    context.completion = completion
    context.kind = kind
    context.commandBuffer.endCommandBuffer()
    if let drawable { queue.waitForDrawable(drawable) }
    // A commit's feedback handlers run once, for that commit only, so each
    // commit takes fresh options. The handler keeps the context alive while it
    // is on the GPU; the pool owns it again afterwards.
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { [weak self] feedback in
      self?.completed(context, feedback: feedback)
    }
    queue.commit(context.commitList, options: options)
    if let drawable {
      queue.signalDrawable(drawable)
      drawable.present()
    }
  }

  /// Returns a context whose encoding failed before commit.
  func abandon(_ context: MonitorEncodeContext) {
    context.commandBuffer.endCommandBuffer()
    let retired = context.finish()
    if !retired.isEmpty { retire(retired) }
    lock.lock()
    free.append(context)
    lock.unlock()
  }

  private func completed(_ context: MonitorEncodeContext, feedback: MTL4CommitFeedback) {
    let completion = context.completion
    let kind = context.kind
    let start = feedback.gpuStartTime, end = feedback.gpuEndTime
    let failed = feedback.error != nil
    let retired = context.finish()
    if !retired.isEmpty { retire(retired) }
    lock.lock()
    free.append(context)
    lock.unlock()
    if end > start { gpuTiming(start, end) }
    completion?.encodeCompleted(kind: kind, gpuStart: start, gpuEnd: end, failed: failed)
  }
}

/// Wraps producer IOSurfaces as Metal textures once and keeps them, keyed by
/// IOSurface ID, plane and view format. Capture and processing pools recycle
/// a small set of surfaces, so steady state makes no textures and changes no
/// residency. A cached texture retains only the IOSurface, not the pixel
/// buffer, so pools still recycle; each frame's pixel buffer is retained until
/// its GPU work completes. Entries unused for two seconds are released.
final class MonitorSurfaceTextureCache: @unchecked Sendable {
  private struct Key: Hashable {
    let surface: IOSurfaceID
    let plane: Int
    let format: UInt
    let width: Int
    let height: Int
  }
  private struct Entry {
    let texture: MTLTexture
    let surface: IOSurfaceRef
    var lastUse: Double
    /// The target whose frame last used this texture, for flushing.
    var target: MonitorTargetID
  }
  private let device: MTLDevice
  weak var context: MonitorMetalContext?
  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]
  private var lastSweep = 0.0
  private var madeCount = 0
  var made: Int {
    lock.lock()
    defer { lock.unlock() }
    return madeCount
  }
  static let idleLifetime = 2.0

  init(device: MTLDevice) {
    self.device = device
    entries.reserveCapacity(64)
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  func frame(_ bundle: MonitorFrameBundle) throws -> MonitorGPUFrame {
    let target = bundle.stamp.target
    let source = try planes(bundle.source, target: target)
    let output: MonitorPlanes? =
      bundle.output.map { $0 === bundle.source } == true
      ? source : try bundle.output.map { try planes($0, target: target) }
    return MonitorGPUFrame(bundle: bundle, source: source, output: output)
  }

  func planes(_ buffer: CVPixelBuffer, target: MonitorTargetID) throws -> MonitorPlanes {
    let type = CVPixelBufferGetPixelFormatType(buffer)
    guard let (format, lumaFormat, chromaFormat) = MonitorPlanes.layout(type) else {
      throw MonitorPreviewError.unsupportedFormat
    }
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
      throw MonitorPreviewError.notIOSurfaceBacked
    }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let planeCount = CVPixelBufferGetPlaneCount(buffer)
    let now = ProcessInfo.processInfo.systemUptime
    if let chromaFormat {
      let chromaHeight = format >= 6 ? height : (height + 1) / 2
      guard planeCount == 2, width % 2 == 0,
        CVPixelBufferGetWidthOfPlane(buffer, 0) == width,
        CVPixelBufferGetHeightOfPlane(buffer, 0) == height,
        CVPixelBufferGetWidthOfPlane(buffer, 1) == width / 2,
        CVPixelBufferGetHeightOfPlane(buffer, 1) == chromaHeight
      else { throw MonitorPreviewError.invalidLayout }
      let luma = try texture(
        surface, plane: 0, format: lumaFormat, width, height, now: now, target: target)
      let chroma = try texture(
        surface, plane: 1, format: chromaFormat, width / 2, chromaHeight, now: now,
        target: target)
      return MonitorPlanes(
        format: format, width: width, height: height, pixelFormat: type, plane0: luma,
        plane1: chroma)
    }
    guard planeCount == 0 else { throw MonitorPreviewError.invalidLayout }
    let texelWidth = format == 0 ? (width + 5) / 6 : width
    guard CVPixelBufferGetBytesPerRow(buffer) >= texelWidth * (format == 0 ? 16 : 4) else {
      throw MonitorPreviewError.invalidLayout
    }
    let packed = try texture(
      surface, plane: 0, format: lumaFormat, texelWidth, height, now: now, target: target)
    return MonitorPlanes(
      format: format, width: width, height: height, pixelFormat: type, plane0: packed,
      plane1: packed)
  }

  private func texture(
    _ surface: IOSurfaceRef, plane: Int, format: MTLPixelFormat, _ width: Int, _ height: Int,
    now: Double, target: MonitorTargetID
  ) throws -> MTLTexture {
    let key = Key(
      surface: IOSurfaceGetID(surface), plane: plane, format: format.rawValue, width: width,
      height: height)
    lock.lock()
    if entries[key]?.surface === surface {
      entries[key]!.lastUse = now
      if entries[key]!.target != target { entries[key]!.target = target }
      let texture = entries[key]!.texture
      let sweep = now - lastSweep > 1
      lock.unlock()
      if sweep { sweepIdle(now: now) }
      return texture
    }
    lock.unlock()
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane)
    else { throw MonitorPreviewError.invalidLayout }
    lock.lock()
    let replaced = entries.updateValue(
      Entry(texture: texture, surface: surface, lastUse: now, target: target), forKey: key)
    madeCount += 1
    lock.unlock()
    context?.updateResidency(adding: texture, removing: replaced.map { [$0.texture] } ?? [])
    return texture
  }

  /// Sweeps if the last sweep was more than a second ago.
  func sweepIfDue(now: Double) {
    lock.lock()
    let due = now - lastSweep > 1
    lock.unlock()
    if due { sweepIdle(now: now) }
  }

  func sweepIdle(now: Double) {
    lock.lock()
    lastSweep = now
    guard entries.contains(where: { now - $0.value.lastUse > Self.idleLifetime }) else {
      lock.unlock()
      return
    }
    var removed: [MTLAllocation] = []
    for (key, entry) in entries where now - entry.lastUse > Self.idleLifetime {
      removed.append(entry.texture)
      entries.removeValue(forKey: key)
    }
    lock.unlock()
    // Unused for two seconds: no queued GPU work can still read these.
    if !removed.isEmpty { context?.updateResidency(adding: nil, removing: removed) }
  }

  /// Removes `target`'s entries now and returns their textures; the caller
  /// retires their residency once queued GPU work is done.
  func flush(target: MonitorTargetID) -> [MTLAllocation] {
    lock.lock()
    defer { lock.unlock() }
    var removed: [MTLAllocation] = []
    for (key, entry) in entries where entry.target == target {
      removed.append(entry.texture)
      entries.removeValue(forKey: key)
    }
    return removed
  }
}

/// A thread with a run loop for display links and frame encoding, so monitor
/// pictures never wait on the main thread and the main thread never waits on them.
public final class MonitorRenderThread: @unchecked Sendable {
  private let ready = DispatchSemaphore(value: 0)
  private var runLoop: CFRunLoop?
  private let lock = NSLock()
  private var thread: Thread?

  public init() {}

  private func start() -> CFRunLoop {
    lock.lock()
    defer { lock.unlock() }
    if let runLoop { return runLoop }
    let thread = Thread { [weak self] in
      guard let self else { return }
      self.runLoop = CFRunLoopGetCurrent()
      // A port keeps the run loop alive between display link callbacks.
      RunLoop.current.add(NSMachPort(), forMode: .default)
      self.ready.signal()
      while true { autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) } }
    }
    thread.name = "MonitorTools.render"
    thread.qualityOfService = .userInteractive
    thread.start()
    self.thread = thread
    ready.wait()
    return runLoop!
  }

  /// The run loop that display links are scheduled on.
  public var runLoopForDisplayLinks: RunLoop {
    let loop = start()
    var result: RunLoop?
    let done = DispatchSemaphore(value: 0)
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
      result = RunLoop.current
      done.signal()
    }
    CFRunLoopWakeUp(loop)
    done.wait()
    return result!
  }

  /// Runs `block` on the render thread.
  public func perform(_ block: @escaping () -> Void) {
    let loop = start()
    CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(loop)
  }
}
