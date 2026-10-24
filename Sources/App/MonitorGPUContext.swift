import CoreVideo
import Foundation
import IOSurface
import Metal
import MonitorKit
import MonitorKitScopes

/// Receives GPU completion for one committed monitor submission.
protocol MonitorGPUCompletion: AnyObject, Sendable {
  /// Called on Metal's feedback queue once the GPU has finished (or failed) the submission.
  func gpuCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool)
}

/// The monitor's shared GPU side on MonitorKit: one device (`LUTProcessor.sharedDevice`,
/// so burn-in and monitor share every `MonitorLUT`), one `MTL4CommandQueue` for all
/// monitor work (MonitorKit's barriers rely on it), the `MonitorEngine` and
/// `ScopeEngine` (one residency set), the IOSurface texture cache, a pool of encode
/// contexts and the submission clock. Nothing here copies pixels or skips a frame.
///
/// Built lazily, off the main thread (`prepare()`), with a growing retry delay after a
/// failure, as MonitorTools' runtime was. Every surface encodes on `renderThread`.
///
/// Zero overhead per frame: contexts (command buffer, allocator, 32 KB of uniforms)
/// are pooled; residency changes only when a texture, LUT or context is made or
/// retired; nothing waits.
final class MonitorGPUContext: @unchecked Sendable {
  /// Uniform bytes per encode context: 32 KB holds five pictures and their analyses
  /// (`MonitorPass.uniformLength` + `MonitorFeed.uniformLength` each), or a scope
  /// tick of three grouped scopes with every graticule rebuilt. A context that needs
  /// more grows by another chunk (counted, never a failure).
  static let uniformCapacity = 32 * 1024
  static let maximumRetryDelay = 30.0

  /// The thread that runs every surface's display link and encodes its frames.
  let renderThread = RenderThread(name: "Ultracam.monitor.render")

  /// Guards the built core, the last failure and pending drawable sets. Held only
  /// for loads and stores, never across a shader compile.
  private let stateLock = NSLock()
  /// Serializes the one-time build.
  private let buildLock = NSLock()
  private let deviceProvider: @Sendable () -> MTLDevice?
  private let gpuTiming: @Sendable (Double, Double) -> Void
  /// Where MonitorKit keeps its pipeline warm start (`MonitorPipelineArchive`
  /// files of both engines); nil for none.
  let pipelineCacheDirectory: URL?
  private var built: Core?
  private var failure: Error?
  private var retryAt = 0.0
  private var retryDelay = 1.0
  /// Drawable residency sets attached before the core exists.
  private var pendingDrawables: [ObjectIdentifier: MTLResidencySet] = [:]

  init(
    device: @escaping @Sendable () -> MTLDevice? = { LUTProcessor.sharedDevice },
    gpuTiming: @escaping @Sendable (Double, Double) -> Void = { start, end in
      AppGPUActivity.shared.record(start: start, end: end)
    },
    pipelineCacheDirectory: URL? = nil
  ) {
    deviceProvider = device
    self.gpuTiming = gpuTiming
    self.pipelineCacheDirectory = pipelineCacheDirectory
  }

  /// The app's pipeline warm start: `Library/Caches/<bundle id>/MonitorKitPipelines`
  /// (inside the app's container under the sandbox). Nil in a process with no
  /// bundle identifier (tests, tools), so they never touch the app's files: an
  /// archive save removes the files other shader builds left there. The directory
  /// is made by the first save (`MonitorPipelineArchive.save`), off the frame path.
  static func pipelineCacheDirectory(bundleIdentifier: String?, caches: URL?) -> URL? {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty, let caches else { return nil }
    return caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent("MonitorKitPipelines", isDirectory: true)
  }

  /// `pipelineCacheDirectory(bundleIdentifier:caches:)` for this process.
  static var appPipelineCacheDirectory: URL? {
    pipelineCacheDirectory(
      bundleIdentifier: Bundle.main.bundleIdentifier,
      caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
  }

  deinit { renderThread.stop() }

  /// The GPU core, built once on first use. Concurrent callers wait for the one build.
  /// A failure is kept and rethrown until its retry delay (1 s, doubling to 30 s) runs out.
  func core() throws -> Core {
    if let ready = try readyCore() { return ready }
    buildLock.lock()
    defer { buildLock.unlock() }
    if let ready = try readyCore() { return ready }
    let made: Core
    do {
      guard let device = deviceProvider() else {
        throw MonitorKitError.gpu("No Metal device for the monitor.")
      }
      made = try Core(device: device, gpuTiming: gpuTiming, pipelineCacheDirectory: pipelineCacheDirectory)
    } catch {
      stateLock.withLock {
        failure = error
        retryAt = ProcessInfo.processInfo.systemUptime + retryDelay
        retryDelay = min(Self.maximumRetryDelay, retryDelay * 2)
      }
      throw error
    }
    stateLock.withLock {
      built = made
      failure = nil
      retryDelay = 1
      // Under the lock, so a concurrent detach cannot slip between the two.
      for set in pendingDrawables.values { made.queue.addResidencySet(set) }
      pendingDrawables.removeAll()
    }
    return made
  }

  private func readyCore() throws -> Core? {
    try stateLock.withLock {
      if let built { return built }
      if let failure, ProcessInfo.processInfo.systemUptime < retryAt { throw failure }
      return nil
    }
  }

  /// The core if it is built. Never compiles and never waits.
  var builtCore: Core? { stateLock.withLock { built } }

  /// Nil while the GPU is usable (or not yet tried).
  var unavailableReason: String? {
    stateLock.withLock { failure.map { "Monitor GPU unavailable: \($0)" } }
  }

  /// The device for a `CAMetalLayer`, without compiling anything on the caller's thread.
  var layerDevice: MTLDevice? { builtCore?.device ?? deviceProvider() }

  /// Builds the core and its pipelines off the main thread, so the first surface
  /// neither compiles nor waits.
  func prepare(warmUp: Bool = true) {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      guard let core = try? core(), warmUp else { return }
      _ = try? core.warmUp()
    }
  }

  /// Keeps a layer's drawables resident for the monitor queue. Safe on the main
  /// thread: before the core exists the set waits and the build attaches it. Call
  /// again when a pixel-format change gives the layer a new set.
  func attachDrawables(_ set: MTLResidencySet) {
    let core = stateLock.withLock { () -> Core? in
      if built == nil { pendingDrawables[ObjectIdentifier(set)] = set }
      return built
    }
    core?.queue.addResidencySet(set)
  }

  func detachDrawables(_ set: MTLResidencySet) {
    let core = stateLock.withLock { () -> Core? in
      pendingDrawables.removeValue(forKey: ObjectIdentifier(set))
      return built
    }
    core?.queue.removeResidencySet(set)
  }

  /// Drops the cached textures of one feed's frames (its camera stopped or changed
  /// device). Their residency ends once the submissions that may read them complete.
  func flushFrames(owner: UInt64) { builtCore?.frames.flush(owner: owner) }

  /// Counts of GPU objects made. In steady state none of these grow.
  var statistics: Statistics { builtCore?.statistics ?? Statistics() }

  struct Statistics: Equatable, Sendable {
    /// IOSurface plane textures made since the core was built, and held now.
    var texturesMade = 0
    var texturesCached = 0
    /// Pooled encode contexts, and uniform chunks added past their first 32 KB.
    var encodeContexts = 0
    var uniformChunksGrown = 0
    /// Residency commits by MonitorKit (only when an allocation joins or leaves).
    var residencyCommits = 0
    /// Submissions handed out, and the contiguous completion watermark.
    var submissions: UInt64 = 0
    var completedSubmissions: UInt64 = 0
    /// Submissions whose encode failed, and those of them that held a drawable (the
    /// GPU waited for it and signalled it; it was not presented).
    var failedEncodes = 0
    var abandonedDrawables = 0
  }

  // MARK: - Core

  /// Device-wide Metal 4 objects. Thread-safe.
  final class Core: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTL4CommandQueue
    let compiler: MTL4Compiler
    let engine: MonitorEngine
    let scopeEngine: ScopeEngine
    /// IOSurface → texture, once per surface, plane and format; resident in
    /// `engine.residency`, released after two idle seconds or on `flush(owner:)`.
    let frames: MonitorTextureCache
    /// Host allocations: the encode contexts' uniforms.
    let hostResidency: MTLResidencySet
    let clock = SubmissionClock()
    private let gpuTiming: @Sendable (Double, Double) -> Void
    private let lock = NSLock()
    private var free: [EncodeContext] = []
    private var contexts = 0
    private var grownChunks = 0
    private var failedEncodes = 0
    private var abandonedDrawables = 0
    private var maintenance: DispatchSourceTimer?

    /// With `pipelineCacheDirectory`, both engines warm-start from the pipeline
    /// archives earlier launches saved there and save this session's (MonitorKit
    /// builds with the archive's own compiler then); an engine that cannot be made
    /// with the cache is made without it, so a bad cache never costs the monitor.
    init(
      device: MTLDevice, gpuTiming: @escaping @Sendable (Double, Double) -> Void,
      pipelineCacheDirectory: URL? = nil
    ) throws {
      guard device.supportsFamily(.metal4) else {
        throw MonitorKitError.gpu("The monitor needs a Metal 4 device.")
      }
      self.device = device
      self.gpuTiming = gpuTiming
      let queueDescriptor = MTL4CommandQueueDescriptor()
      queueDescriptor.label = "Ultracam monitor"
      queue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
      let hostCompiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
      let cached = pipelineCacheDirectory.flatMap { try? MonitorEngine(device: device, cacheDirectory: $0) }
      let engine = try cached ?? MonitorEngine(device: device, compiler: hostCompiler)
      let shared = engine.residency
      let cachedScopes = pipelineCacheDirectory.flatMap {
        try? ScopeEngine(device: device, residency: shared, cacheDirectory: $0)
      }
      self.engine = engine
      compiler = engine.compiler ?? hostCompiler
      scopeEngine = try cachedScopes ?? ScopeEngine(device: device, residency: shared)
      frames = MonitorTextureCache(device: device, residency: engine.residency)
      let residency = MTLResidencySetDescriptor()
      residency.label = "Ultracam monitor host"
      residency.initialCapacity = 16
      hostResidency = try device.makeResidencySet(descriptor: residency)
      queue.addResidencySet(engine.residency.set)
      queue.addResidencySet(hostResidency)
      free.reserveCapacity(8)
      // Idle textures and retired resources leave residency even while no surface
      // encodes (every feed stopped), at a low rate off the main and render threads.
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(500))
      timer.setEventHandler { [weak self] in self?.maintain() }
      timer.resume()
      maintenance = timer
    }

    deinit { maintenance?.cancel() }

    /// Builds every picture, focus, Freeze and scope pipeline the app's three layer
    /// formats can need, so a switch to an HDR layer never compiles on the render
    /// thread. Returns the pipelines built. With a pipeline cache both engines save
    /// their archives before returning (`prepare()` runs this off the main thread).
    @discardableResult
    func warmUp() throws -> Int {
      let built = try engine.warmUp()
      try scopeEngine.prepare()
      return built
    }

    func maintain() {
      frames.sweep()
      engine.residency.release(through: clock.completedIndex)
    }

    /// A free encode context, or a new one while every existing one is on the GPU
    /// (growth happens only while the GPU is behind; it is counted, never a skip).
    /// Every context handed out must be committed or abandoned: its submission index
    /// completes only then, and the watermark waits for it.
    func begin() throws -> EncodeContext {
      let reused = lock.withLock { free.popLast() }
      let context: EncodeContext
      if let reused {
        context = reused
      } else {
        context = try EncodeContext(core: self)
        lock.withLock { contexts += 1 }
      }
      let (index, completed) = clock.reserve()
      context.begin(index: index, completedIndex: completed)
      return context
    }

    /// Ends and commits `context`. With a drawable, the GPU waits for it before the
    /// work and signals it after, and the drawable is presented unless `present` is false.
    func commit(
      _ context: EncodeContext, drawable: MTLDrawable? = nil, completion: MonitorGPUCompletion? = nil,
      kind: Int = 0, present: Bool = true
    ) {
      context.completion = completion
      context.kind = kind
      context.commandBuffer.endCommandBuffer()
      if let drawable { queue.waitForDrawable(drawable) }
      // A commit's feedback handlers run once, for that commit only, so each commit
      // takes fresh options. The handler keeps the context alive while it is on the
      // GPU; the pool owns it again afterwards.
      let options = MTL4CommitOptions()
      options.addFeedbackHandler { [weak self] feedback in
        self?.completed(
          context, gpuStart: feedback.gpuStartTime, gpuEnd: feedback.gpuEndTime,
          failed: feedback.error != nil)
      }
      queue.commit(context.commitList, options: options)
      if let drawable {
        queue.signalDrawable(drawable)
        if present {
          drawable.present()
        } else {
          lock.withLock { abandonedDrawables += 1 }
        }
      }
    }

    /// A context whose encoding failed: committed with whatever it holds, so its
    /// submission index completes and the watermark moves on. The body may already
    /// have rendered into `drawable`, so the GPU still waits for the drawable before
    /// that work and signals it after; the half-drawn drawable is not presented (the
    /// layer keeps its last good picture).
    func abandon(_ context: EncodeContext, drawable: MTLDrawable? = nil) {
      lock.withLock { failedEncodes += 1 }
      commit(context, drawable: drawable, present: false)
    }

    /// Encodes one submission and commits it (also when `body` throws, then rethrows).
    func submit(
      drawable: MTLDrawable? = nil, completion: MonitorGPUCompletion? = nil, kind: Int = 0,
      _ body: (EncodeContext) throws -> Void
    ) throws {
      let context = try begin()
      do {
        try body(context)
      } catch {
        abandon(context, drawable: drawable)
        throw error
      }
      commit(context, drawable: drawable, completion: completion, kind: kind)
    }

    private func completed(_ context: EncodeContext, gpuStart: Double, gpuEnd: Double, failed: Bool) {
      let completion = context.completion
      let kind = context.kind
      let index = context.index
      context.finish()
      lock.withLock { free.append(context) }
      // Feedback can arrive out of order: MonitorKit gets the contiguous watermark.
      engine.residency.release(through: clock.complete(index))
      if gpuEnd > gpuStart { gpuTiming(gpuStart, gpuEnd) }
      completion?.gpuCompleted(kind: kind, gpuStart: gpuStart, gpuEnd: gpuEnd, failed: failed)
    }

    /// A new uniform chunk for a context that outgrew its 32 KB (rare; counted).
    fileprivate func makeUniformChunk(length: Int) -> MTLBuffer {
      // A device that runs Metal 4 makes a 32 KB shared buffer; failing here is fatal misconfiguration.
      let buffer = device.makeBuffer(length: length, options: [.storageModeShared, .cpuCacheModeWriteCombined])!
      buffer.label = "Ultracam monitor uniforms"
      lock.withLock {
        hostResidency.addAllocation(buffer)
        hostResidency.commit()
      }
      return buffer
    }

    /// Takes a replaced uniform chunk out of residency. Its context's previous
    /// submission has completed (contexts are reused only then), so nothing reads it.
    fileprivate func retireUniformChunk(_ buffer: MTLBuffer) {
      lock.withLock {
        hostResidency.removeAllocation(buffer)
        hostResidency.commit()
      }
    }

    fileprivate func noteChunkGrown() { lock.withLock { grownChunks += 1 } }

    var statistics: Statistics {
      let (contexts, grown, failed, abandoned) = lock.withLock {
        (self.contexts, grownChunks, failedEncodes, abandonedDrawables)
      }
      let (reserved, completed) = clock.counts
      return Statistics(
        texturesMade: frames.texturesMade, texturesCached: frames.count, encodeContexts: contexts,
        uniformChunksGrown: grown, residencyCommits: engine.residency.commitCount, submissions: reserved,
        completedSubmissions: completed, failedEncodes: failed, abandonedDrawables: abandoned)
    }
  }

  // MARK: - Encode context

  /// One reusable submission: command buffer, allocator, a bump uniform allocator
  /// (256-byte aligned, resident, valid until completion) and what the GPU work
  /// reads, kept alive until it completes. Used by one thread at a time (the render
  /// thread, then the feedback handler). Steady state allocates nothing.
  final class EncodeContext: MonitorUniformAllocator, @unchecked Sendable {
    let commandBuffer: MTL4CommandBuffer
    fileprivate let commitList: [MTL4CommandBuffer]
    private let allocator: MTL4CommandAllocator
    private weak var core: Core?
    private var chunks: [MTLBuffer]
    private var chunk = 0
    private var offset = 0
    private var retained: [AnyObject] = []
    private var kept: [MonitorFrame] = []
    fileprivate var completion: MonitorGPUCompletion?
    fileprivate var kind = 0
    /// This submission's index on the monitor queue (≥ 1), and the watermark when it began.
    private(set) var index: UInt64 = 0
    private(set) var completedIndex: UInt64 = 0

    fileprivate init(core: Core) throws {
      guard let allocator = core.device.makeCommandAllocator(),
        let commandBuffer = core.device.makeCommandBuffer()
      else { throw MonitorKitError.gpu("Cannot allocate a monitor command buffer.") }
      self.allocator = allocator
      self.commandBuffer = commandBuffer
      commitList = [commandBuffer]
      self.core = core
      chunks = [core.makeUniformChunk(length: MonitorGPUContext.uniformCapacity)]
      chunks.reserveCapacity(4)
      retained.reserveCapacity(32)
      kept.reserveCapacity(8)
    }

    fileprivate func begin(index: UInt64, completedIndex: UInt64) {
      self.index = index
      self.completedIndex = completedIndex
      chunk = 0
      offset = 0
      allocator.reset()
      commandBuffer.beginCommandBuffer(allocator: allocator)
    }

    /// What MonitorKit encodes into: this command buffer, its index, the completion
    /// watermark and these uniforms.
    var submission: MonitorSubmission {
      MonitorSubmission(commandBuffer: commandBuffer, index: index, completedIndex: completedIndex, uniforms: self)
    }

    func allocateUniforms(length: Int) -> MonitorUniformAllocation {
      let size = (max(1, length) + 255) / 256 * 256
      if offset + size > chunks[chunk].length {
        chunk += 1
        offset = 0
        if chunk == chunks.count, let core {
          chunks.append(core.makeUniformChunk(length: max(MonitorGPUContext.uniformCapacity, size)))
          core.noteChunkGrown()
        }
        if chunks[chunk].length < size, let core {
          let replaced = chunks[chunk]
          chunks[chunk] = core.makeUniformChunk(length: size)
          core.retireUniformChunk(replaced)
          core.noteChunkGrown()
        }
      }
      let buffer = chunks[chunk]
      let allocation = MonitorUniformAllocation(
        contents: buffer.contents().advanced(by: offset), gpuAddress: buffer.gpuAddress + UInt64(offset))
      offset += size
      return allocation
    }

    /// Keeps `object` alive (a pixel buffer, a replaced LUT, a target) until this
    /// submission's GPU work completes.
    func retain(_ object: AnyObject) { retained.append(object) }
    /// Keeps `frame`'s textures and pixel buffer alive until this submission completes.
    func keep(_ frame: MonitorFrame) { kept.append(frame) }

    fileprivate func finish() {
      retained.removeAll(keepingCapacity: true)
      kept.removeAll(keepingCapacity: true)
      completion = nil
    }
  }

  // MARK: - Submission clock

  /// Submission indices for the one monitor queue, from 1, and the highest
  /// *contiguous* completed index (feedback handlers can complete out of order;
  /// reporting the highest seen would reuse uniforms and free resources in flight).
  final class SubmissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 1
    private var completed: UInt64 = 0
    private var done = Set<UInt64>()

    init() { done.reserveCapacity(64) }

    /// The next index and the watermark now.
    func reserve() -> (index: UInt64, completed: UInt64) {
      lock.withLock {
        defer { next += 1 }
        return (next, completed)
      }
    }

    /// Records `index` as completed (any order); returns the new watermark.
    func complete(_ index: UInt64) -> UInt64 {
      lock.withLock {
        if index > completed { done.insert(index) }
        while done.remove(completed + 1) != nil { completed += 1 }
        return completed
      }
    }

    var completedIndex: UInt64 { lock.withLock { completed } }
    /// Indices handed out, and the watermark.
    var counts: (reserved: UInt64, completed: UInt64) { lock.withLock { (next - 1, completed) } }
  }

  // MARK: - Render thread

  /// A thread with a run loop for display links and frame encoding, so pictures never
  /// wait on the main thread and the main thread never waits on them. The thread holds
  /// only a small shared state box, never its owner, so `stop()` (or the owner's
  /// deinit) ends its run loop and the thread exits.
  final class RenderThread: @unchecked Sendable {
    private final class State: @unchecked Sendable {
      let lock = NSLock()
      var runLoop: CFRunLoop?
      /// The thread's `RunLoop`, published with `runLoop` when the thread starts.
      var foundationRunLoop: RunLoop?
      var stopped = false
      var exited = false
      let ready = DispatchSemaphore(value: 0)
    }

    private let state = State()
    private let name: String
    private var started = false

    init(name: String) { self.name = name }

    deinit { stop() }

    /// The run loop, starting the thread on first use; nil once stopped.
    private func start() -> CFRunLoop? {
      let state = self.state
      state.lock.lock()
      if state.stopped {
        state.lock.unlock()
        return nil
      }
      if let loop = state.runLoop {
        state.lock.unlock()
        return loop
      }
      let first = !started
      started = true
      state.lock.unlock()
      if first {
        let thread = Thread {
          let loop = CFRunLoopGetCurrent()
          let foundationLoop = RunLoop.current
          state.lock.withLock {
            state.runLoop = loop
            state.foundationRunLoop = foundationLoop
          }
          // A port keeps the run loop alive between display link callbacks.
          RunLoop.current.add(NSMachPort(), forMode: .default)
          state.ready.signal()
          while !state.lock.withLock({ state.stopped }) {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
          }
          state.lock.withLock {
            state.runLoop = nil
            state.foundationRunLoop = nil
            state.exited = true
          }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        state.ready.wait()
      } else {
        // Another caller is starting it: wait until its run loop is published.
        while state.lock.withLock({ state.runLoop == nil && !state.stopped && !state.exited }) { usleep(100) }
      }
      return state.lock.withLock { state.stopped ? nil : state.runLoop }
    }

    /// The run loop display links are scheduled on (nil once stopped). Never waits on
    /// the render thread, so it is safe from any thread, the render thread included,
    /// and while `stop()` runs.
    var runLoopForDisplayLinks: RunLoop? {
      guard start() != nil else { return nil }
      return state.lock.withLock { state.stopped ? nil : state.foundationRunLoop }
    }

    /// Runs `block` on the render thread; dropped once the thread has stopped. A
    /// block queued just before `stop()` may also be dropped, so never use one for
    /// cleanup that must happen (detach residency sets directly; that is thread-safe).
    func perform(_ block: @escaping () -> Void) {
      guard let loop = start() else { return }
      CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
      CFRunLoopWakeUp(loop)
    }

    /// Ends the run loop; the thread exits once the current callback returns.
    func stop() {
      let loop = state.lock.withLock { () -> CFRunLoop? in
        state.stopped = true
        return state.runLoop
      }
      guard let loop else { return }
      CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
      CFRunLoopStop(loop)
      CFRunLoopWakeUp(loop)
    }

    /// Whether the thread has left its run loop (tests).
    var hasExited: Bool { state.lock.withLock { state.exited } }
  }
}
