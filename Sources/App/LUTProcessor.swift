import CoreVideo
import Foundation
import IOSurface
import Metal
import MonitorKit

// MonitorKit's LUT types under the app module's names, so the app files that do
// not import MonitorKit (AppModel, AppSettingsStore, CaptureController and the
// tests) can name them.
typealias CubeLUT = MonitorKitCore.CubeLUT
typealias MonitorLUT = MonitorKit.MonitorLUT

extension CubeLUT {
  /// The table sizes for the UI: "33³", "1D 1024", or "1D 4096 + 33³".
  var sizeDescription: String {
    let cube = "\(dimension)³"
    guard shaperSize > 0 else { return cube }
    return hasCube ? "1D \(shaperSize) + \(cube)" : "1D \(shaperSize)"
  }
}

/// GPU processing for one capture controller, on Metal 4.
///
/// Pipelined: `submit` validates, reserves an output buffer, encodes one
/// command buffer and commits it, then returns. Up to
/// `VideoContract.maxFramesInFlight` frames are on the GPU at once. Each
/// frame's completion runs on an internal serial queue, strictly in submission
/// order, as soon as the GPU finishes it; the caller fans the frame out from
/// there. Nothing on the submitting thread waits for the GPU except when all
/// slots are busy (bounded, reported as a stuck GPU after two seconds).
///
/// Threading: `submit`, `process`, `passthrough`, `load`, `prepare` and
/// `releaseIdleResources` belong to one owning serial queue (the capture
/// queue, or a test thread). Completions run on the processor's feedback queue.
///
/// Resources:
/// - One MTL4CommandQueue; a ring of command allocators, command buffers,
///   argument tables, parameter slices and input residency sets, one per
///   in-flight frame. A slot is reused only after its frame completed.
/// - A persistent residency set (parameters, intermediate, the placeholder
///   LUT) and an output residency set of textures cached per output IOSurface
///   (pools recycle their surfaces, so these are created once and stay
///   resident). The loaded `MonitorLUT` is immutable: each frame retains the
///   one it was encoded with and puts its texture in that frame's residency
///   set, so loading a LUT swaps it at once, without waiting for the GPU.
/// - Capture frames belong to the driver's pool, so they are mapped per frame
///   through CVMetalTextureCache (which does not keep driver surfaces alive);
///   their CVMetalTextures live in the frame record until completion.
final class LUTProcessor: @unchecked Sendable {
  /// Packed v210 frames the GPU read in place from the capture IOSurface.
  /// There is no copy path to count.
  struct PackedInputDiagnostics: Sendable {
    var noCopyFrames: UInt64 = 0
    var lastPath = "No packed processing"
  }

  struct WorkingResourceDiagnostics: Sendable {
    var floatTextureBytes: Int
    var outputPoolActive: Bool
  }

  /// Opt-in qualification timestamps, reported at completion. `waitReturn`
  /// is when the completion ran; the submitting thread never waits.
  struct CommandTiming: Sendable {
    let commitBegin: Double
    let commitReturn: Double
    let gpuStart: Double
    let gpuEnd: Double
    let waitReturn: Double
    let meterReturn: Double
  }

  /// Per-frame times on the `ProcessInfo.systemUptime` clock (GPU times on
  /// the Metal host clock, which is the same mach-based uptime).
  struct FrameTiming: Sendable {
    var submitted: Double = 0
    var committed: Double = 0
    var gpuStart: Double = 0
    var gpuEnd: Double = 0
    var completed: Double = 0
    var gpuMS: Double { gpuEnd > gpuStart ? (gpuEnd - gpuStart) * 1000 : 0 }
  }

  /// The completed frame. `@unchecked`: the pixel buffer is immutable once
  /// the GPU has finished, and ownership passes to the caller.
  struct Completed: @unchecked Sendable {
    let result: Result<CVPixelBuffer, Error>
    let timing: FrameTiming
  }

  typealias Completion = (Completed) -> Void

  // Configure on the owning queue before processing.
  var commandTimingObserver: (@Sendable (CommandTiming) -> Void)? {
    get { stateLock.withLock { timingObserver } }
    set { stateLock.withLock { timingObserver = newValue } }
  }

  private(set) var packedInputDiagnostics = PackedInputDiagnostics()

  private let device: MTLDevice
  private let commandQueue: MTL4CommandQueue
  private let feedbackQueue: DispatchQueue
  private let pipelines: [String: MTLComputePipelineState]
  private let slots: [Slot]
  private let slotPermits = DispatchSemaphore(value: VideoContract.maxFramesInFlight)
  private let parameterBuffer: MTLBuffer
  private static let parameterStride = 256
  private let persistentResidency: MTLResidencySet
  private let outputResidency: MTLResidencySet
  private var outputResidencyDirty = false
  private var textureCache: CVMetalTextureCache!
  private var textureCacheUses = 0
  // Often enough to release cache-held capture surfaces, never every frame.
  private static let textureCacheFlushInterval = 32
  private var pool: CVPixelBufferPool?
  private var poolConfiguration: PipelineConfiguration?
  private var poolSize: (Int, Int)?
  private var passthroughPool: CVPixelBufferPool?
  private var passthroughFormat: (type: OSType, width: Int, height: Int)?
  /// The burned-in LUT (tetrahedral; MonitorKit's `mk_applyLUT`), shared with
  /// the monitor. Owning queue only.
  private(set) var lut: MonitorLUT?
  /// Declared colour contract for the loaded LUT. The default is the
  /// historical Rec.709 identity contract; callers loading a camera-specific
  /// LUT must provide its input and output spaces explicitly.
  private(set) var lutColorSpace = LUTColorSpaceContract.rec709Video
  /// Bound when no LUT is loaded; the shader returns before reading it.
  private let placeholderLUT: MTLTexture
  private var horizontalTexture: MTLTexture?
  private var horizontalLease: GPUAllocationBudget.Lease?
  private var workingGeneration: UInt64 = 0
  private var outputTextures: [SurfaceKey: SurfaceEntry] = [:]
  private let outputCacheLock = NSRecursiveLock()
  private let allocationBudget: GPUAllocationBudget
  private let cacheIdleAge: TimeInterval
  private let monotonicNow: () -> TimeInterval
  private var ageSweepScheduled = false
  var cachedAllocationBytesForTesting: Int { allocationBudget.snapshot().bytes }
  var cachedAllocationCountForTesting: Int { allocationBudget.snapshot().allocations }
  func sweepOutputCacheForTesting() { evictIdleOutputTextures() }
  private var submitted: UInt64 = 0
  /// Input for warm-up frames, allocated once. Its outputs are discarded, so
  /// its contents never matter and nothing fills it on the CPU (fresh
  /// IOSurface memory is zero-filled by the kernel).
  private var warmSource: CVPixelBuffer?

  // Shared with the feedback queue.
  private let stateLock = NSLock()
  private var pending: [UInt64: InFlight] = [:]
  private var nextCompletion: UInt64 = 0
  private var inFlightPeak = 0
  private var timingObserver: (@Sendable (CommandTiming) -> Void)?

  // Pool allocations past this are an output stall (`outputBackPressure`).
  private var outputSlotBytes = 0
  private var passthroughSlotBytes = 0
  private func allocationLimit(slotBytes: Int) -> CFDictionary {
    let byteSlots = slotBytes > 0 ? allocationBudget.policy.maximumBytes / slotBytes : VideoContract.outputBufferLimit
    return [kCVPixelBufferPoolAllocationThresholdKey: max(1, min(VideoContract.outputBufferLimit, byteSlots))] as CFDictionary
  }

  private struct Slot {
    let allocator: MTL4CommandAllocator
    let commandBuffer: MTL4CommandBuffer
    let tables: [MTL4ArgumentTable]
    let inputResidency: MTLResidencySet
    let parameterOffset: Int
  }

  private struct SurfaceKey: Hashable {
    let id: IOSurfaceID
    let plane: Int
    let format: UInt
  }

  private final class SurfaceEntry {
    let surface: IOSurfaceRef
    let texture: MTLTexture
    var lastUsed: UInt64
    var lastUsedTime: TimeInterval
    let lease: GPUAllocationBudget.Lease
    init(surface: IOSurfaceRef, texture: MTLTexture, lastUsed: UInt64, time: TimeInterval, lease: GPUAllocationBudget.Lease) {
      self.surface = surface
      self.texture = texture
      self.lastUsed = lastUsed
      self.lastUsedTime = time
      self.lease = lease
    }
  }

  /// One committed frame. Holds every object the command buffer references
  /// that Metal 4 does not retain: the capture frame's CVMetalTextures, the
  /// output buffer, and the MonitorLUT and intermediate texture of that frame.
  private final class InFlight: @unchecked Sendable {
    let output: CVPixelBuffer
    let retained: [AnyObject]
    let completion: Completion
    var timing: FrameTiming
    var error: Error?
    var done = false
    /// Work to run right after this frame's completion, in order (frames the
    /// caller did not put on the GPU but must order behind this one).
    var followers: [@Sendable () -> Void] = []
    init(output: CVPixelBuffer, retained: [AnyObject], completion: @escaping Completion, timing: FrameTiming) {
      self.output = output
      self.retained = retained
      self.completion = completion
      self.timing = timing
    }
  }

  /// Mirrors `Parameters` in LUTShaders.metal: ten 16-byte rows, the last five
  /// MonitorKit's `mk_LUTParams`.
  struct Parameters {
    var geometry: SIMD4<UInt32>
    var decodeRange: SIMD4<Float>
    var decodeMatrix: SIMD4<Float>
    var encodeMatrix: SIMD4<Float>
    var chroma: SIMD4<Float>
    var lut: LUTParameters
    var inputConversion = SIMD4<UInt32>(repeating: 0)
    var outputConversion = SIMD4<UInt32>(repeating: 0)
    var scaling = SIMD4<Float>(repeating: 0)
  }

  var workingResourceDiagnostics: WorkingResourceDiagnostics {
    WorkingResourceDiagnostics(floatTextureBytes: horizontalTexture?.allocatedSize ?? 0,
      outputPoolActive: pool != nil)
  }

  /// Frames committed whose completion has not run yet.
  var framesInFlight: Int { stateLock.withLock { pending.count } }

  struct InFlightStatus: Sendable {
    var count: Int
    /// The most frames in flight at once since `resetInFlightPeak`.
    var peak: Int
    /// Commit time of the oldest unfinished frame (watchdog).
    var oldestCommit: Double?
  }

  /// Thread-safe.
  var inFlight: InFlightStatus {
    stateLock.withLock {
      InFlightStatus(count: pending.count, peak: inFlightPeak,
        oldestCommit: pending[nextCompletion].map { $0.timing.committed })
    }
  }

  func resetInFlightPeak() { stateLock.withLock { inFlightPeak = pending.count } }

  /// The one GPU of the capture, LUT and monitor work. A `MonitorLUT` is bound
  /// to the device it was built on, so the one built per LUT load serves the
  /// burn-in and the monitor only when both run here.
  static let sharedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

  /// The processing library: MonitorKit's MKLUT.msl, then LUTShaders.metal
  /// (then `extra`), as one compilation unit with `MonitorShaders.compileOptions`,
  /// so `mk_applyLUT` compiles exactly as in MonitorKit's own passes.
  static func libraryDescriptor(extra: String = "") throws -> MTL4LibraryDescriptor {
    let url = ProcessInfo.processInfo.environment["ULTRACAM_SHADER"].map { URL(fileURLWithPath: $0) }
      ?? Bundle.main.url(forResource: "LUTShaders", withExtension: "metal")
    guard let url else { throw VideoError.message("GPU shader resource is missing.") }
    let source = try String(contentsOf: url, encoding: .utf8)
    return try MonitorShaders.libraryDescriptor(parts: [.lut], extra: extra.isEmpty ? source : source + "\n" + extra,
      name: "LUTShaders")
  }

  init(device: MTLDevice? = LUTProcessor.sharedDevice, qos: DispatchQoS = .userInteractive,
    cacheMaximumBytes: Int = 1024 * 1024 * 1024, cacheIdleAge: TimeInterval = 4,
    monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
    guard cacheIdleAge.isFinite, cacheIdleAge > 0 else { throw GPUAllocationBudgetFailure.invalidPolicy }
    allocationBudget = GPUAllocationBudget(policy: try GPUAllocationBudgetPolicy(maximumBytes: cacheMaximumBytes, minimumSlots: VideoContract.maxFramesInFlight))
    self.cacheIdleAge = cacheIdleAge
    self.monotonicNow = monotonicNow
    guard let device else { throw VideoError.message("A Metal GPU is required.") }
    // Parameters embed MonitorKit's mk_LUTParams, layout 2 (80 bytes); the
    // shader source refuses to compile against any other MKLUT.msl.
    guard MonitorShaders.lutLayoutVersion == 2, MemoryLayout<LUTParameters>.size == 80,
      MemoryLayout<Parameters>.size == 208, MemoryLayout<Parameters>.size <= Self.parameterStride else {
      throw VideoError.message("The LUT shader parameters do not match MonitorKit's LUT layout.")
    }
    self.device = device
    feedbackQueue = DispatchQueue(label: "org.ultracam.gpu-completion", qos: qos)
    let queueDescriptor = MTL4CommandQueueDescriptor()
    queueDescriptor.label = "Ultracam capture processing"
    queueDescriptor.feedbackQueue = feedbackQueue
    commandQueue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
    // The descriptor's `feedbackQueue` is an `assign` property, but the
    // command queue releases it when it goes away; without this one retain
    // the queue is over-released (libdispatch traps "Over-release of an
    // object") when the processor is deallocated. Verified on macOS 27.
    // Taken only once the command queue exists: a failed creation never
    // takes ownership, so retaining first would leak the queue.
    _ = Unmanaged.passRetained(feedbackQueue)

    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let library: MTLLibrary
    if let path = ProcessInfo.processInfo.environment["ULTRACAM_METALLIB"] {
      // Prebuilt from the same unit as `libraryDescriptor` (MKLUT.msl, then
      // LUTShaders.metal, safe math); LUTShaders.metal alone does not compile.
      library = try device.makeLibrary(URL: URL(fileURLWithPath: path))
    } else {
      library = try compiler.makeLibrary(descriptor: Self.libraryDescriptor())
    }
    var pipelines: [String: MTLComputePipelineState] = [:]
    for name in ["fullPackedNV12", "fullPacked422", "fullPlanarNV12", "fullPlanar422",
      "horizontalPacked", "horizontalPlanar", "verticalNV12", "vertical422",
      "fullRGBNV12", "fullRGB422", "horizontalRGB",
      "fullI420NV12", "fullI420422", "horizontalI420",
      "fullPacked8NV12", "fullPacked8422", "horizontalPacked8"] {
      let function = MTL4LibraryFunctionDescriptor()
      function.name = name
      function.library = library
      let descriptor = MTL4ComputePipelineDescriptor()
      descriptor.computeFunctionDescriptor = function
      descriptor.label = name
      pipelines[name] = try compiler.makeComputePipelineState(descriptor: descriptor, compilerTaskOptions: nil)
    }
    self.pipelines = pipelines

    guard let parameters = device.makeBuffer(length: Self.parameterStride * VideoContract.maxFramesInFlight,
      options: .storageModeShared) else { throw VideoError.message("Cannot allocate GPU parameters.") }
    parameterBuffer = parameters
    let tableDescriptor = MTL4ArgumentTableDescriptor()
    tableDescriptor.maxTextureBindCount = 6
    tableDescriptor.maxBufferBindCount = 1
    var slots: [Slot] = []
    for index in 0..<VideoContract.maxFramesInFlight {
      guard let allocator = device.makeCommandAllocator(), let commandBuffer = device.makeCommandBuffer() else {
        throw VideoError.message("Cannot allocate GPU command memory.")
      }
      let residency = MTLResidencySetDescriptor()
      residency.label = "Capture frame \(index)"
      residency.initialCapacity = 3
      slots.append(Slot(allocator: allocator, commandBuffer: commandBuffer,
        tables: try (0..<2).map { _ in try device.makeArgumentTable(descriptor: tableDescriptor) },
        inputResidency: try device.makeResidencySet(descriptor: residency),
        parameterOffset: index * Self.parameterStride))
    }
    self.slots = slots
    let persistent = MTLResidencySetDescriptor()
    persistent.label = "Processing working set"
    persistentResidency = try device.makeResidencySet(descriptor: persistent)
    let outputs = MTLResidencySetDescriptor()
    outputs.label = "Output surfaces"
    outputs.initialCapacity = 32
    outputResidency = try device.makeResidencySet(descriptor: outputs)
    placeholderLUT = try Self.makePlaceholderLUT(device: device)
    persistentResidency.addAllocations([parameterBuffer, placeholderLUT])
    persistentResidency.commit()
    commandQueue.addResidencySets([persistentResidency, outputResidency])
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    guard status == kCVReturnSuccess else { throw VideoError.message("Cannot create GPU texture cache.") }
  }

  deinit {
    _ = waitUntilIdle(timeout: 2)
    commandQueue.removeResidencySets([persistentResidency, outputResidency])
  }

  /// The 2³ identity lattice bound while no LUT is applied
  /// (`LUTParameters.disabled`: the shader returns before reading it).
  private static func makePlaceholderLUT(device: MTLDevice) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor()
    descriptor.textureType = .type3D
    descriptor.pixelFormat = .rgba32Float
    descriptor.width = 2
    descriptor.height = 2
    descriptor.depth = 2
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw VideoError.message("Cannot upload LUT to GPU.")
    }
    let rgba: [Float] = [0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1]
    rgba.withUnsafeBytes { bytes in
      texture.replace(region: MTLRegionMake3D(0, 0, 0, 2, 2, 2), mipmapLevel: 0, slice: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: 32, bytesPerImage: 64)
    }
    texture.label = "No LUT"
    return texture
  }

  /// Burns `lut` in from the next submitted frame. No wait: `MonitorLUT` is
  /// immutable, and every frame in flight retains (and keeps resident) the one
  /// it was encoded with. Ultracam interpolates tetrahedrally only, burn-in and
  /// monitor alike. Owning queue only.
  func load(_ lut: MonitorLUT) throws {
    guard lut.texture.device === device else {
      throw VideoError.message("The LUT was uploaded to a different GPU than the one processing this camera.")
    }
    guard lut.interpolation == .tetrahedral else {
      throw VideoError.message("Ultracam applies LUTs with tetrahedral interpolation only.")
    }
    self.lut = lut
    lutColorSpace = .rec709Video
  }

  func load(_ lut: MonitorLUT, colorSpace: LUTColorSpaceContract) throws {
    try load(lut)
    lutColorSpace = colorSpace
  }

  /// Uploads `cube` on this processor's device, then `load(_:)`s it.
  func load(_ cube: CubeLUT) throws {
    try load(Self.makeLUT(cube, device: device))
  }

  func load(_ cube: CubeLUT, colorSpace: LUTColorSpaceContract) throws {
    try load(Self.makeLUT(cube, device: device), colorSpace: colorSpace)
  }

  /// The one `MonitorLUT` of a LUT load (tetrahedral), on the shared device:
  /// the burn-in and the monitor take this same object.
  static func makeLUT(_ cube: CubeLUT, device: MTLDevice? = sharedDevice) throws -> MonitorLUT {
    guard let device else { throw VideoError.message("A Metal GPU is required.") }
    do { return try MonitorLUT(device: device, cube: cube) } catch let error as MonitorKitError {
      throw VideoError.message("Cannot upload the LUT to the GPU: \(error.description)")
    }
  }

  /// Blocks the owning queue until every committed frame has completed.
  /// Used before releasing or replacing anything a committed frame uses.
  @discardableResult
  func waitUntilIdle(timeout: TimeInterval) -> Bool {
    let deadline = DispatchTime.now() + timeout
    var acquired = 0
    for _ in 0..<VideoContract.maxFramesInFlight {
      guard slotPermits.wait(timeout: deadline) == .success else { break }
      acquired += 1
    }
    for _ in 0..<acquired { slotPermits.signal() }
    return acquired == VideoContract.maxFramesInFlight
  }

  /// Allocates the working texture, the output pool and its first frames,
  /// and maps their surfaces, by running `warmBufferCount` frames whose
  /// outputs are discarded. `wait` true (before native capture starts, when
  /// no live frame can arrive) blocks until they finish. On the live path
  /// (`wait` false) they are committed ahead of the next live frame and the
  /// capture thread does not wait for the GPU; an untouched configuration
  /// then keeps the idle resources until the next stop or idle period instead
  /// of waiting for frames in flight to release them.
  func prepare(configuration: PipelineConfiguration, wait: Bool = true) throws {
    if configuration.untouched {
      if wait { releaseIdleResources() }
      return
    }
    let source = try warmInput()
    guard wait else {
      // Best effort: a warm frame that can't get a buffer or slot is not an
      // error of its own; the live frame that follows reports any stall.
      for _ in 0..<VideoContract.warmBufferCount {
        do { try submit(source, configuration: configuration) { _ in } } catch { break }
      }
      return
    }
    var warm = [CVPixelBuffer]()
    for _ in 0..<VideoContract.warmBufferCount { warm.append(try process(source, configuration: configuration)) }
    withExtendedLifetime(warm) {}
  }

  private func warmInput() throws -> CVPixelBuffer {
    if let warmSource { return warmSource }
    var source: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &source)
    guard status == kCVReturnSuccess, let source else {
      throw VideoError.message("Cannot prepare capture processing buffers (\(status)).")
    }
    warmSource = source
    return source
  }

  private func preparePool(_ configuration: PipelineConfiguration, width: Int, height: Int) throws -> CVPixelBufferPool {
    if let previous = poolConfiguration, poolSize?.0 == width,
      poolSize?.1 == height, previous.pixelFormat == configuration.pixelFormat,
      let pool { return pool }
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil,
      [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.outputPoolMinimum] as CFDictionary, [
      kCVPixelBufferPixelFormatTypeKey: configuration.pixelFormat,
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw VideoError.message("Cannot allocate output pool.") }
    self.pool = pool
    poolConfiguration = configuration
    outputSlotBytes = 0
    poolSize = (width, height)
    return pool
  }

  /// The downscale intermediate (decode + LUT + horizontal result). Half
  /// float: 1920 × 2160 × 8 bytes, written once and read once per frame.
  private func intermediate(width: Int, height: Int) throws -> MTLTexture {
    if let horizontalTexture, horizontalTexture.width == width, horizontalTexture.height == height {
      return horizontalTexture
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let result = device.makeTexture(descriptor: descriptor) else {
      throw VideoError.message("Cannot allocate GPU working texture.")
    }
    result.label = "Horizontal Lanczos"
    if let horizontalTexture {
      guard waitUntilIdle(timeout: 2) else { throw VideoError.message("The GPU stopped responding.") }
      persistentResidency.removeAllocation(horizontalTexture)
      persistentResidency.commit()
      self.horizontalTexture = nil
    }
    horizontalLease = nil
    workingGeneration &+= 1
    let lease: GPUAllocationBudget.Lease
    do {
      lease = try allocationBudget.acquire(backingID: UInt64.max - workingGeneration, bytes: result.allocatedSize,
        generation: workingGeneration, owner: result)
    } catch {
      evictIdleOutputTextures(pressure: true)
      lease = try allocationBudget.acquire(backingID: UInt64.max - workingGeneration, bytes: result.allocatedSize,
        generation: workingGeneration, owner: result)
    }
    horizontalLease = lease
    persistentResidency.addAllocation(result)
    persistentResidency.commit()
    horizontalTexture = result
    return result
  }

  private func releaseIntermediate() {
    guard let horizontalTexture else { return }
    persistentResidency.removeAllocation(horizontalTexture)
    persistentResidency.commit()
    self.horizontalTexture = nil
    horizontalLease = nil
  }

  // Owning queue only. Waits for committed frames first: Metal 4 command
  // buffers do not retain what they use. Published pixel buffers stay valid;
  // the loaded LUT and compiled pipelines stay.
  func releaseIdleResources() {
    let hadResources = horizontalTexture != nil || pool != nil || passthroughPool != nil || outputCacheLock.withLock({ !outputTextures.isEmpty })
    guard hadResources else { return }
    guard waitUntilIdle(timeout: 2) else { return }
    releaseIntermediate()
    pool = nil
    poolConfiguration = nil
    passthroughPool = nil
    passthroughFormat = nil
    outputCacheLock.withLock {
      for entry in outputTextures.values { outputResidency.removeAllocation(entry.texture) }
      outputResidency.commit()
      outputTextures.removeAll()
      outputResidencyDirty = false
    }
    CVMetalTextureCacheFlush(textureCache, 0)
  }

  // MARK: - Synchronous wrappers (warm-up and tests)

  func process(_ input: CVPixelBuffer, configuration: PipelineConfiguration,
    colorConversion: LUTColorSpaceConversion = .none, destinationColorimetry: Colorimetry? = nil) throws -> CVPixelBuffer {
    if try validate(input, untouched: configuration.untouched && colorConversion == .none && destinationColorimetry == nil) { releaseIdleResources(); return input }
    return try waitFor { try submit(input, configuration: configuration, colorConversion: colorConversion,
      destinationColorimetry: destinationColorimetry, completion: $0) }
  }

  /// Processing off: one GPU copy of the capture frame into an IOSurface this
  /// process owns. See `submitPassthrough`.
  func passthrough(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
    try waitFor { try submitPassthrough(input, completion: $0) }
  }

  private final class Waiter: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var result: Result<CVPixelBuffer, Error>?
  }

  private func waitFor(_ submit: (@escaping Completion) throws -> Void) throws -> CVPixelBuffer {
    let waiter = Waiter()
    try submit { completed in
      waiter.result = completed.result
      waiter.done.signal()
    }
    guard waiter.done.wait(timeout: .now() + 2) == .success, let result = waiter.result else {
      throw VideoError.message("GPU processing timed out.")
    }
    return try result.get()
  }

  // MARK: - Pipelined submission

  /// Returns true for an untouched configuration (the input is the output).
  private func validate(_ input: CVPixelBuffer, untouched: Bool) throws -> Bool {
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    guard width > 0, height > 0 else {
      throw VideoError.message("LUT input dimensions must be positive.")
    }
    let supported: Set<OSType> = Set(VideoContract.tenBit422).union([
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      0x50323136, 0x32767579, 0x79757673, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA,
      0x72323130, 0x5231324c, 0x55595641, 0x49343230, 0x50413136])
    guard supported.contains(CVPixelBufferGetPixelFormatType(input)) else {
      throw VideoError.message("Expected 10-bit 4:2:2 input.")
    }
    try VideoBufferLayout.validate(input)
    return untouched
  }

  /// Declared source entry point used by capture delivery. Legacy overloads
  /// remain for derived-format fixtures and warm-up, not source negotiation.
  func submit(_ input: CVPixelBuffer, configuration: PipelineConfiguration,
    source: SourceAdmissionSnapshot, metadata: SourceAdmissionMetadata,
    colorConversion: LUTColorSpaceConversion = .none, destinationColorimetry: Colorimetry? = nil,
    isCurrent: () -> Bool = { true }, completion: @escaping Completion) throws {
    try validateSource(input, source: source, metadata: metadata)
    try submit(input, configuration: configuration, colorConversion: colorConversion,
      destinationColorimetry: destinationColorimetry, declaredSourceColorimetry: source.format.colour,
      isCurrent: isCurrent, completion: completion)
  }

  func submitPassthrough(_ input: CVPixelBuffer, source: SourceAdmissionSnapshot,
    metadata: SourceAdmissionMetadata, isCurrent: () -> Bool = { true },
    completion: @escaping Completion) throws {
    try validateSource(input, source: source, metadata: metadata)
    let colour = source.format.colour
    let aspect = source.format.pixelAspect
    try submitPassthrough(input, isCurrent: isCurrent) { completed in
      if case .success(let output) = completed.result {
        Self.stampDeclaredColorimetry(colour, on: output)
        CVBufferSetAttachment(output, kCVImageBufferPixelAspectRatioKey,
          [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: NSNumber(value: aspect.numerator),
           kCVImageBufferPixelAspectRatioVerticalSpacingKey: NSNumber(value: aspect.denominator)] as CFDictionary, .shouldPropagate)
      }
      completion(completed)
    }
  }

  private func validateSource(_ input: CVPixelBuffer, source: SourceAdmissionSnapshot,
    metadata: SourceAdmissionMetadata) throws {
    // The snapshot may originate at the capture gate: independently require
    // this consumer's route before allocating output or retaining GPU work.
    let route = try SourceAdmissionSnapshot(format: source.format, epochID: source.epochID,
      clockBindings: source.clockBindings, stage: .lut)
    try route.validate(metadata, stage: .lut)
    var actual = metadata
    actual.width = CVPixelBufferGetWidth(input)
    actual.height = CVPixelBufferGetHeight(input)
    actual.pixel = PixelFormatID(rawValue: CVPixelBufferGetPixelFormatType(input))
    actual.isPlanar = CVPixelBufferIsPlanar(input)
    actual.planeCount = CVPixelBufferGetPlaneCount(input)
    actual.rowBytes = CVPixelBufferGetBytesPerRow(input)
    actual.dataSize = CVPixelBufferGetDataSize(input)
    actual.planes = (0..<actual.planeCount).map {
      VideoBufferLayout.Plane(width: CVPixelBufferGetWidthOfPlane(input, $0),
        height: CVPixelBufferGetHeightOfPlane(input, $0), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(input, $0))
    }
    try route.validate(actual, stage: .lut)
    guard actual.width == metadata.width, actual.height == metadata.height,
      actual.pixel == metadata.pixel, actual.isPlanar == metadata.isPlanar,
      actual.planeCount == metadata.planeCount, actual.rowBytes == metadata.rowBytes,
      actual.dataSize == metadata.dataSize else {
      throw SourceAdmissionRefusal(stage: .lut, formatDescription: source.formatSignature,
        reason: "actual pixel buffer layout differs from source metadata")
    }
  }

  /// Encodes and commits one processed frame. `completion` runs on the
  /// processor's completion queue after the GPU finished, in submission order.
  /// `isCurrent` lets a caller abandon a frame waiting for a GPU slot.
  func submit(_ input: CVPixelBuffer, configuration: PipelineConfiguration,
    colorConversion: LUTColorSpaceConversion = .none,
    destinationColorimetry: Colorimetry? = nil, declaredSourceColorimetry: Colorimetry? = nil,
    isCurrent: () -> Bool = { true }, completion: @escaping Completion) throws {
    let preparedSequence = submitted
    defer { if submitted == preparedSequence { discardUnsubmittedOutputTextures(sequence: preparedSequence) } }
    let submittedAt = ProcessInfo.processInfo.systemUptime
    if try validate(input, untouched: configuration.untouched && colorConversion == .none && destinationColorimetry == nil) {
      throw VideoError.message("An untouched configuration has no GPU work; use passthrough.")
    }
    let applied = configuration.applyLUT ? lut : nil
    guard !configuration.applyLUT || applied != nil else { throw VideoError.message("Load a LUT or turn off Apply LUT.") }
    let sourceColour = try configuration.sourceColorimetryOverride ?? declaredSourceColorimetry ?? Self.sourceColorimetry(input)
    let nativeOutput = Colorimetry(primaries: sourceColour.primaries, transfer: sourceColour.transfer,
      matrix: sourceColour.matrix == .identity ? .rec709 : sourceColour.matrix, range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .center)
    if configuration.applyLUT, let negotiated = configuration.lutOutputColorimetry,
       !LUTColorSpaceContract.sameRGBEncoding(negotiated, lutColorSpace.output) {
      throw LUTColorSpaceContractError.outputMismatch(expected: negotiated, actual: lutColorSpace.output)
    }
    let destination = destinationColorimetry ?? (configuration.applyLUT ? (configuration.lutOutputColorimetry ?? lutColorSpace.output) : nativeOutput)
    if configuration.applyLUT {
      try lutColorSpace.validate(source: sourceColour, destination: destination, conversion: colorConversion)
    } else if colorConversion != .none || destination.primaries != sourceColour.primaries || destination.transfer != sourceColour.transfer {
      try LUTColorSpaceContract(input: destination, output: destination)
        .validate(source: sourceColour, destination: destination, conversion: colorConversion)
    }
    guard destination.range == .video, [.rec709, .rec2020, .rec601].contains(destination.matrix),
      [.rec709, .rec2020].contains(destination.primaries),
      [.rec709, .sRGB, .linear, .pq, .hlg].contains(destination.transfer) else {
      throw VideoError.message("Unsupported LUT output range or matrix.")
    }
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    let matrix: String? = sourceColour.matrix == .rec2020 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 as String :
      (sourceColour.matrix == .rec601 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String : kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    var parameters = Self.parameters(for: input, matrix: matrix, lut: applied)
    if CVPixelBufferIsPlanar(input), type != 0x55595641 {
      try Self.configurePlanarParameters(&parameters, pixelFormat: type, colour: sourceColour)
    }
    if type == kCVPixelFormatType_422YpCbCr10 {
      parameters.decodeRange = sourceColour.range == .full ? SIMD4(0, 1023, 512, 1023) : SIMD4(64, 876, 512, 896)
      switch sourceColour.horizontalChromaSiting {
      case .left: parameters.chroma.x = 0
      case .center: parameters.chroma.x = 0.5
      default: throw VideoError.message("Unsupported horizontal packed chroma siting.")
      }
    }
    if [OSType(0x55595641), kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs].contains(type) {
      parameters.decodeRange = sourceColour.range == .full ? SIMD4(0, 1020, 512, 1020) : SIMD4(64, 876, 512, 896)
      parameters.chroma.x = sourceColour.horizontalChromaSiting == .center ? 0.5 : 0
    }
    parameters.geometry.z = configuration.outputColor.isEightBit ? 8 : 10
    if configuration.applyLUT {
      parameters.inputConversion = try Self.conversionParameters(from: sourceColour, to: lutColorSpace.input)
      parameters.outputConversion = try Self.conversionParameters(from: lutColorSpace.output, to: destination)
    } else {
      parameters.inputConversion = try Self.conversionParameters(from: sourceColour, to: destination)
    }
    parameters.encodeMatrix.x = destination.matrix == .rec2020 ? 0.2627 : (destination.matrix == .rec601 ? 0.299 : 0.2126)
    parameters.encodeMatrix.y = destination.matrix == .rec2020 ? 0.0593 : (destination.matrix == .rec601 ? 0.114 : 0.0722)
    // Reserve output before mapping a borrowed capture frame. A consumer that
    // holds every output buffer is a stall, reported by the caller.
    let outputWidth = configuration.downscale ? configuration.width : width
    let outputHeight = configuration.downscale ? configuration.height : height
    guard outputWidth.isMultiple(of: 2), !configuration.outputColor.is420 || outputHeight.isMultiple(of: 2) else {
      throw VideoError.message("The selected YUV output requires even chroma geometry; choose a resized output.")
    }
    let pool = try preparePool(configuration, width: outputWidth, height: outputHeight)
    var created: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, allocationLimit(slotBytes: outputSlotBytes), &created)
    if status == kCVReturnWouldExceedAllocationThreshold { throw VideoError.outputBackPressure }
    guard status == kCVReturnSuccess, let output = created else {
      throw VideoError.message("Output buffers are unavailable (\(status)).")
    }
    outputSlotBytes = CVPixelBufferGetIOSurface(output).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) } ?? 0
    flushTextureCache()
    let y = try outputTexture(output, plane: 0, format: configuration.outputColor.isEightBit ? .r8Unorm : .r16Unorm)
    let uv = try outputTexture(output, plane: 1, format: configuration.outputColor.isEightBit ? .rg8Unorm : .rg16Unorm)
    var inputs: [MTLTexture] = []
    var wrappers: [AnyObject] = []
    let rgbTypes: [OSType: UInt32] = [kCVPixelFormatType_32BGRA: 1, kCVPixelFormatType_32RGBA: 2, 0x72323130: 3, 0x5231324c: 4]
    let rgbInput = rgbTypes[type] != nil
    let packed = type == kCVPixelFormatType_422YpCbCr10
    let i420 = type == 0x49343230
    let packed8 = type == kCVPixelFormatType_422YpCbCr8 || type == kCVPixelFormatType_422YpCbCr8_yuvs || type == 0x55595641
    if let rgbKind = rgbTypes[type] {
      parameters.chroma.w = Float(rgbKind)
      let textureWidth = rgbKind == 4 ? (width * 36 + 7) / 8 : width
      let (wrapper, rgb) = try view(input, plane: 0, format: rgbKind == 4 ? .r8Uint : .rgba8Uint,
        width: textureWidth, height: height)
      inputs.append(rgb); wrappers.append(wrapper)
    } else if packed8 {
      parameters.chroma.w = type == kCVPixelFormatType_422YpCbCr8_yuvs ? 1 : 0
      let (wrapper, groups) = try view(input, plane: 0, format: .rgba8Uint, width: width / 2 + width % 2, height: height)
      inputs.append(groups); wrappers.append(wrapper)
    } else if packed {
      // SDK 16 capture frames are IOSurface-backed, so the GPU reads the
      // capture memory through the texture cache. There is no copy path.
      guard CVPixelBufferGetIOSurface(input) != nil else {
        throw VideoError.message("The capture frame is not IOSurface-backed. Update Desktop Video.")
      }
      let (wrapper, groups) = try view(input, plane: 0, format: .rgba32Uint, width: (width + 5) / 6, height: height)
      inputs.append(groups)
      wrappers.append(wrapper)
      packedInputDiagnostics.noCopyFrames &+= 1
      packedInputDiagnostics.lastPath = "No copy"
    } else if i420 {
      for plane in 0..<3 {
        let (wrapper, texture) = try view(input, plane: plane, format: .r8Unorm,
          width: CVPixelBufferGetWidthOfPlane(input, plane), height: CVPixelBufferGetHeightOfPlane(input, plane))
        inputs.append(texture); wrappers.append(wrapper)
      }
    } else {
      let eightBit = type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || type == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
      let (yWrapper, luma) = try view(input, plane: 0, format: eightBit ? .r8Unorm : .r16Unorm,
        width: CVPixelBufferGetWidthOfPlane(input, 0), height: CVPixelBufferGetHeightOfPlane(input, 0))
      let (uvWrapper, chroma) = try view(input, plane: 1, format: eightBit ? .rg8Unorm : .rg16Unorm,
        width: CVPixelBufferGetWidthOfPlane(input, 1), height: CVPixelBufferGetHeightOfPlane(input, 1))
      inputs += [luma, chroma]
      wrappers += [yWrapper, uvWrapper]
    }
    let scaling = try ProgramScalingPolicy.plan(sourceWidth: width, sourceHeight: height,
      targetWidth: outputWidth, targetHeight: outputHeight, mode: configuration.scalingMode,
      pixelAspect: configuration.resolvedSourcePixelAspect)
    parameters.scaling = SIMD4(Float(scaling.scaledWidth), Float(scaling.scaledHeight),
      Float(scaling.offsetX - scaling.cropLeft), Float(scaling.offsetY - scaling.cropTop))
    let resizing = outputWidth != width || outputHeight != height || scaling.hasPillarboxOrLetterbox || scaling.hasCrop
    let horizontal = resizing ? try intermediate(width: outputWidth, height: height) : nil
    // Frames in flight may still use it: release at an idle moment (normally
    // the next frame) rather than wait for the GPU on the capture thread.
    if !resizing, horizontalTexture != nil, framesInFlight == 0 { releaseIntermediate() }
    stampAttachments(output, from: input, configuration: configuration, matrix: matrix, destination: destination, geometryConverted: resizing, colourEncodingChanged: !LUTColorSpaceContract.sameRGBEncoding(sourceColour, destination))
    // The frame retains its LUT and keeps its texture resident until it completes.
    let lutTexture = applied?.texture ?? placeholderLUT
    try encode(output: output, retained: wrappers + [input] + (applied.map { [$0] } ?? []) + (horizontal.map { [$0] } ?? []),
      inputResidency: inputs + (applied.map { [$0.texture] } ?? []), timing: FrameTiming(submitted: submittedAt), isCurrent: isCurrent,
      label: "LUT → Lanczos → output format", completion: completion) { encoder, slot in
      withUnsafeBytes(of: &parameters) { bytes in
        parameterBuffer.contents().advanced(by: slot.parameterOffset)
          .copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
      }
      let parameterAddress = parameterBuffer.gpuAddress + UInt64(slot.parameterOffset)
      let first = slot.tables[0]
      first.setAddress(parameterAddress, index: 0)
      first.setTexture(inputs[0].gpuResourceID, index: 0)
      if inputs.count > 1 { first.setTexture(inputs[1].gpuResourceID, index: 1) }
      if i420 { first.setTexture(inputs[2].gpuResourceID, index: 5) }
      first.setTexture(lutTexture.gpuResourceID, index: 2)
      encoder.setArgumentTable(first)
      if let horizontal {
        first.setTexture(horizontal.gpuResourceID, index: 3)
        guard let state = pipelines[i420 ? "horizontalI420" : (rgbInput ? "horizontalRGB" : (packed8 ? "horizontalPacked8" : (packed ? "horizontalPacked" : "horizontalPlanar")))] else { return false }
        encoder.setComputePipelineState(state)
        // 128 outputs per threadgroup; 1920 / 128 = 15 groups per row.
        encoder.dispatchThreadgroups(threadgroupsPerGrid: MTLSize(width: (horizontal.width + 127) / 128,
          height: horizontal.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
        encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
        let second = slot.tables[1]
        second.setAddress(parameterAddress, index: 0)
        second.setTexture(horizontal.gpuResourceID, index: 0)
        second.setTexture(y.gpuResourceID, index: 3)
        second.setTexture(uv.gpuResourceID, index: 4)
        encoder.setArgumentTable(second)
        guard let vertical = pipelines[configuration.outputColor.is420 ? "verticalNV12" : "vertical422"] else { return false }
        encoder.setComputePipelineState(vertical)
        dispatchBlocks(encoder, state: vertical, width: outputWidth, height: outputHeight,
          is420: configuration.outputColor.is420)
      } else {
        first.setTexture(y.gpuResourceID, index: 3)
        first.setTexture(uv.gpuResourceID, index: 4)
        let name = (i420 ? "fullI420" : (rgbInput ? "fullRGB" : (packed8 ? "fullPacked8" : (packed ? "fullPacked" : "fullPlanar")))) + (configuration.outputColor.is420 ? "NV12" : "422")
        guard let state = pipelines[name] else { return false }
        encoder.setComputePipelineState(state)
        dispatchBlocks(encoder, state: state, width: width, height: height, is420: configuration.outputColor.is420)
      }
      return true
    }
  }

  /// Missing labels retain the legacy Rec.709 interpretation. Unknown labels
  /// refuse: they cannot authorize a transform with known endpoints.
  static var declaredColorimetryAttachmentKey: CFString { "UltracamColorimetryContract" as CFString }

  static func sourceColorimetry(_ image: CVPixelBuffer) throws -> Colorimetry {
    if let payload = CVBufferCopyAttachment(image, declaredColorimetryAttachmentKey, nil) as? Data {
      return try JSONDecoder().decode(ColorimetryContract.self, from: payload).colorimetry
    }
    func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(image, key, nil) as? String }
    func read<T>(_ key: CFString, values: [(CFString, T)], fallback: T) throws -> T {
      guard let value = tag(key) else { return fallback }
      guard let match = values.first(where: { $0.0 as String == value }) else {
        throw VideoError.message("Unsupported source colour attachment.")
      }
      return match.1
    }
    let primaries: Colorimetry.Primaries = try read(kCVImageBufferColorPrimariesKey,
      values: [(kCVImageBufferColorPrimaries_ITU_R_709_2, .rec709),
               (kCVImageBufferColorPrimaries_ITU_R_2020, .rec2020)], fallback: .rec709)
    let transfer: Colorimetry.Transfer = try read(kCVImageBufferTransferFunctionKey,
      values: [(kCVImageBufferTransferFunction_ITU_R_709_2, .rec709),
        (kCVImageBufferTransferFunction_sRGB, .sRGB), (kCVImageBufferTransferFunction_Linear, .linear),
        (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .pq),
        (kCVImageBufferTransferFunction_ITU_R_2100_HLG, .hlg)], fallback: .rec709)
    let matrix: Colorimetry.Matrix = try read(kCVImageBufferYCbCrMatrixKey,
      values: [(kCVImageBufferYCbCrMatrix_ITU_R_709_2, .rec709),
        (kCVImageBufferYCbCrMatrix_ITU_R_2020, .rec2020), (kCVImageBufferYCbCrMatrix_ITU_R_601_4, .rec601)], fallback: .rec709)
    let horizontal: Colorimetry.ChromaSiting
    let vertical: Colorimetry.ChromaSiting
    switch tag(kCVImageBufferChromaLocationTopFieldKey) ?? (kCVImageBufferChromaLocation_Left as String) {
    case let location where location == kCVImageBufferChromaLocation_Left as String: horizontal = .left; vertical = .center
    case let location where location == kCVImageBufferChromaLocation_Center as String: horizontal = .center; vertical = .center
    case let location where location == kCVImageBufferChromaLocation_TopLeft as String: horizontal = .left; vertical = .top
    case let location where location == kCVImageBufferChromaLocation_Top as String: horizontal = .center; vertical = .top
    case let location where location == kCVImageBufferChromaLocation_BottomLeft as String: horizontal = .left; vertical = .bottom
    case let location where location == kCVImageBufferChromaLocation_Bottom as String: horizontal = .center; vertical = .bottom
    default: throw VideoError.message("Unsupported source chroma location attachment.")
    }
    return Colorimetry(primaries: primaries, transfer: transfer, matrix: matrix,
      range: [kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, OSType(0x5231324c)].contains(CVPixelBufferGetPixelFormatType(image)) ? .full : .video,
      horizontalChromaSiting: horizontal, verticalChromaSiting: vertical)
  }

  static func conversionParameters(from: Colorimetry, to: Colorimetry) throws -> SIMD4<UInt32> {
    if from.primaries == to.primaries && from.transfer == to.transfer { return .zero }
    func transferID(_ t: Colorimetry.Transfer) throws -> UInt32 {
      switch t { case .linear: return 1; case .rec709: return 2; case .sRGB: return 3; case .pq: return 4; case .hlg: return 5
      default: throw VideoError.message("Unsupported colour conversion transfer function.") }
    }
    guard [.rec709, .rec2020].contains(from.primaries), [.rec709, .rec2020].contains(to.primaries) else {
      throw VideoError.message("Unsupported colour conversion primaries.")
    }
    return try SIMD4(transferID(from.transfer), transferID(to.transfer),
      from.primaries == to.primaries ? 0 : (from.primaries == .rec709 ? 1 : 2), 0)
  }

  /// The kernel parameters for one input frame: its decode (size, range,
  /// matrix `matrix`, chroma siting), the output encode, and `lut` burned in
  /// (`LUTParameters.disabled` when nil: Apply LUT off).
  static func parameters(for input: CVPixelBuffer, matrix: String?, lut: MonitorLUT?) -> Parameters {
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    let chromaLocation = CVBufferCopyAttachment(input, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
    // SMPTE/QuickTime 4:2:2 is left-cosited unless the producer labels it centered.
    let chromaOffset: Float = chromaLocation == kCVImageBufferChromaLocation_Center as String ||
      chromaLocation == kCVImageBufferChromaLocation_Top as String ||
      chromaLocation == kCVImageBufferChromaLocation_Bottom as String ? 0.5 : 0
    let kr: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.2627 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.299 : 0.2126)
    let kb: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.0593 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.114 : 0.0722)
    let kg = 1 - kr - kb
    let fullRange = type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    return Parameters(
      geometry: SIMD4(UInt32(width), UInt32(height), 0, 0),
      decodeRange: SIMD4(fullRange ? 0 : 64, fullRange ? 1023 : 876, 512, fullRange ? 1023 : 896),
      decodeMatrix: SIMD4(2 * (1 - kr), 2 * (1 - kb), 2 * kb * (1 - kb) / kg, 2 * kr * (1 - kr) / kg),
      encodeMatrix: SIMD4(lut != nil ? 0.2126 : kr, lut != nil ? 0.0722 : kb, 0, 0),
      chroma: SIMD4(chromaOffset, 0, 65535.0 / 64.0, 1),
      lut: lut?.parameters ?? .disabled)
  }

  /// Planar input words are converted to their native code domain before YCbCr
  /// decoding. Declared range and siting override legacy fourCC/attachment defaults.
  static func configurePlanarParameters(_ parameters: inout Parameters, pixelFormat: OSType, colour: Colorimetry) throws {
    let eight = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, OSType(0x49343230)].contains(pixelFormat)
    let sixteen = pixelFormat == 0x50323136 || pixelFormat == 0x50413136 // NDI P216: 16 valid bits, no container shift.
    let is420 = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, OSType(0x49343230)].contains(pixelFormat)
    let scale: Float = eight ? 1 : (sixteen ? 256 : 4)
    let maximum: Float = eight ? 255 : (sixteen ? 65535 : 1023)
    parameters.decodeRange = SIMD4(colour.range == .full ? 0 : 16 * scale,
      colour.range == .full ? maximum : 219 * scale, 128 * scale,
      colour.range == .full ? maximum : 224 * scale)
    switch colour.horizontalChromaSiting {
    case .left: parameters.chroma.x = 0
    case .center: parameters.chroma.x = 0.5
    default: throw VideoError.message("Unsupported horizontal planar chroma siting.")
    }
    if is420 {
      switch colour.verticalChromaSiting {
      case .top: parameters.chroma.y = 0
      case .center: parameters.chroma.y = 0.5
      case .bottom: parameters.chroma.y = 1
      default: throw VideoError.message("Unsupported vertical 4:2:0 chroma siting.")
      }
    } else { parameters.chroma.y = 0 }
    parameters.chroma.z = eight ? 255 : (sixteen ? 65535 : 65535.0 / 64.0)
    parameters.chroma.w = is420 ? 2 : 1
  }

  /// One thread per 2×2 (4:2:0) or 2×1 (4:2:2) output block.
  private func dispatchBlocks(_ encoder: MTL4ComputeCommandEncoder, state: MTLComputePipelineState,
    width: Int, height: Int, is420: Bool) {
    let w = state.threadExecutionWidth
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: width / 2, height: is420 ? height / 2 : height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: max(1, min(8, state.maxTotalThreadsPerThreadgroup / w)), depth: 1))
  }

  /// Processing off: one GPU copy of the capture frame into an IOSurface this
  /// process owns. The source reuses its buffer once our frame reference is gone,
  /// even while the window server or a meeting app still shows it; a pool
  /// buffer is not recycled while another process is using its IOSurface.
  /// Pipelined like `submit`.
  func submitPassthrough(_ input: CVPixelBuffer, isCurrent: () -> Bool = { true },
    completion: @escaping Completion) throws {
    let preparedSequence = submitted
    defer { if submitted == preparedSequence { discardUnsubmittedOutputTextures(sequence: preparedSequence) } }
    let submittedAt = ProcessInfo.processInfo.systemUptime
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    try VideoBufferLayout.validate(input)
    guard CVPixelBufferGetIOSurface(input) != nil else {
      throw VideoError.message("The capture frame is not IOSurface-backed. Update Desktop Video.")
    }
    let planes = try Self.copyPlanes(type: type, width: width, height: height)
    if passthroughFormat?.type != type || passthroughFormat?.width != width || passthroughFormat?.height != height {
      var next: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(nil,
        [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.outputPoolMinimum] as CFDictionary,
        [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height, kCVPixelBufferPixelFormatTypeKey: type,
          kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &next)
      guard status == kCVReturnSuccess, let next else { throw VideoError.message("Cannot allocate passthrough frames (\(status)).") }
      passthroughPool = next
      passthroughFormat = (type, width, height)
      passthroughSlotBytes = 0
    }
    var created: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, passthroughPool!, allocationLimit(slotBytes: passthroughSlotBytes), &created)
    if status == kCVReturnWouldExceedAllocationThreshold { throw VideoError.outputBackPressure }
    guard status == kCVReturnSuccess, let output = created else {
      throw VideoError.message("Passthrough frames are unavailable (\(status)).")
    }
    passthroughSlotBytes = CVPixelBufferGetIOSurface(output).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) } ?? 0
    flushTextureCache()
    var copies: [(MTLTexture, MTLTexture, CopyPlane)] = []
    var wrappers: [AnyObject] = []
    var inputs: [MTLTexture] = []
    for plane in planes {
      let (wrapper, source) = try view(input, plane: plane.index, format: plane.format, width: plane.width, height: plane.height)
      let target = try outputTexture(output, plane: plane.index, format: plane.format, width: plane.width, height: plane.height)
      wrappers.append(wrapper)
      inputs.append(source)
      copies.append((source, target, plane))
    }
    CVBufferRemoveAllAttachments(output)
    CVBufferPropagateAttachments(input, output)
    // A copy owns independent storage: nonpropagating attachments can hold
    // source SDK leases and must not follow it. Preserve only standard image
    // interpretation metadata when a producer marked that metadata local.
    for key in [kCVImageBufferCGColorSpaceKey, kCVImageBufferICCProfileKey,
      kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
      kCVImageBufferYCbCrMatrixKey, kCVImageBufferGammaLevelKey,
      kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey,
      kCVImageBufferChromaSubsamplingKey, kCVImageBufferCleanApertureKey,
      kCVImageBufferPreferredCleanApertureKey, kCVImageBufferPixelAspectRatioKey,
      kCVImageBufferDisplayDimensionsKey, kCVImageBufferFieldCountKey,
      kCVImageBufferFieldDetailKey, kCVImageBufferAlphaChannelModeKey,
      kCVImageBufferMasteringDisplayColorVolumeKey, kCVImageBufferContentLightLevelInfoKey,
      kCVImageBufferAmbientViewingEnvironmentKey, kCVImageBufferLogTransferFunctionKey] {
      var mode = CVAttachmentMode.shouldPropagate
      if let value = CVBufferCopyAttachment(input, key, &mode), mode == .shouldNotPropagate {
        CVBufferSetAttachment(output, key, value, mode)
      }
    }
    try encode(output: output, retained: wrappers + [input], inputResidency: inputs, timing: FrameTiming(submitted: submittedAt),
      isCurrent: isCurrent, label: "Passthrough", completion: completion) { encoder, _ in
      for (source, target, plane) in copies {
        encoder.copy(sourceTexture: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: plane.width, height: plane.height, depth: 1),
          destinationTexture: target, destinationSlice: 0, destinationLevel: 0,
          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      }
      return true
    }
  }

  /// Waits for a slot, encodes into it and commits. Everything fallible
  /// except encoder creation happened before, so a sequence number is always
  /// committed once taken.
  private func encode(output: CVPixelBuffer, retained: [AnyObject], inputResidency inputs: [MTLTexture],
    timing: FrameTiming, isCurrent: () -> Bool, label: String, completion: @escaping Completion,
    body: (MTL4ComputeCommandEncoder, Slot) -> Bool) throws {
    try acquireSlot(isCurrent: isCurrent)
    outputCacheLock.lock()
    if outputResidencyDirty {
      outputResidency.commit()
      outputResidencyDirty = false
    }
    outputCacheLock.unlock()
    let sequence = submitted
    let slot = slots[Int(sequence % UInt64(slots.count))]
    let commandBuffer = slot.commandBuffer
    slot.allocator.reset()
    slot.inputResidency.removeAllAllocations()
    slot.inputResidency.addAllocations(inputs)
    slot.inputResidency.commit()
    commandBuffer.beginCommandBuffer(allocator: slot.allocator)
    commandBuffer.label = label
    commandBuffer.useResidencySet(slot.inputResidency)
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      commandBuffer.endCommandBuffer()
      slotPermits.signal()
      throw VideoError.message("Cannot create GPU encoder.")
    }
    encoder.label = label
    // Frames share the intermediate texture: order this frame after earlier
    // frames' GPU work. Encoding and committing still overlap the GPU.
    encoder.barrier(afterQueueStages: [.dispatch, .blit], beforeStages: [.dispatch, .blit], visibilityOptions: .device)
    let encoded = body(encoder, slot)
    encoder.endEncoding()
    commandBuffer.endCommandBuffer()
    guard encoded else {
      slotPermits.signal()
      throw VideoError.message("Missing GPU pipeline for \(label).")
    }
    submitted &+= 1
    var timing = timing
    timing.committed = ProcessInfo.processInfo.systemUptime
    let cacheRetained: [AnyObject] = outputCacheLock.withLock {
      outputTextures.values.filter { $0.lastUsed == sequence }.map { $0 as AnyObject }
    }
    let record = InFlight(output: output, retained: retained + cacheRetained, completion: completion, timing: timing)
    stateLock.withLock {
      pending[sequence] = record
      inFlightPeak = max(inFlightPeak, pending.count)
    }
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { [self] feedback in
      complete(sequence, error: feedback.error, gpuStart: feedback.gpuStartTime, gpuEnd: feedback.gpuEndTime)
    }
    commandQueue.commit([commandBuffer], options: options)
    evictIdleOutputTextures()
  }

  /// Runs `body` once every frame committed so far has run its completion,
  /// in order with those completions (on the feedback queue). For work about
  /// frames that skip the GPU and must stay ordered behind the ones on it.
  /// Owning queue only.
  func afterCommittedFrames(_ body: @escaping @Sendable () -> Void) {
    let attached = stateLock.withLock { () -> Bool in
      // The newest committed frame completes last; attach to it while it is
      // still pending. Once it left `pending`, its completion is running or
      // has run on the feedback queue, so queueing there orders after it.
      guard submitted > 0, let last = pending[submitted &- 1] else { return false }
      last.followers.append(body)
      return true
    }
    if !attached { feedbackQueue.async(execute: body) }
  }

  private func acquireSlot(isCurrent: () -> Bool) throws {
    let start = ProcessInfo.processInfo.systemUptime
    while slotPermits.wait(timeout: .now() + 0.05) == .timedOut {
      guard isCurrent() else { throw VideoError.cancelled }
      if ProcessInfo.processInfo.systemUptime - start > 2 {
        throw VideoError.message("The GPU stopped responding: \(VideoContract.maxFramesInFlight) frames have been in flight for over 2 seconds.")
      }
    }
  }

  /// Feedback queue. Completions are released strictly in submission order.
  private func complete(_ sequence: UInt64, error: Error?, gpuStart: Double, gpuEnd: Double) {
    let now = ProcessInfo.processInfo.systemUptime
    let (ready, observer) = stateLock.withLock { () -> ([InFlight], (@Sendable (CommandTiming) -> Void)?) in
      if let record = pending[sequence] {
        record.done = true
        record.error = error
        record.timing.gpuStart = gpuStart
        record.timing.gpuEnd = gpuEnd
        record.timing.completed = now
      }
      var ready: [InFlight] = []
      while let next = pending[nextCompletion], next.done {
        pending.removeValue(forKey: nextCompletion)
        nextCompletion &+= 1
        ready.append(next)
      }
      return (ready, timingObserver)
    }
    for record in ready {
      AppGPUActivity.shared.record(start: record.timing.gpuStart, end: record.timing.gpuEnd)
      if let observer {
        observer(CommandTiming(commitBegin: record.timing.submitted, commitReturn: record.timing.committed,
          gpuStart: record.timing.gpuStart, gpuEnd: record.timing.gpuEnd, waitReturn: record.timing.completed,
          meterReturn: ProcessInfo.processInfo.systemUptime))
      }
      let result: Result<CVPixelBuffer, Error> = record.error.map {
        .failure(VideoError.message("GPU processing failed: \($0.localizedDescription)"))
      } ?? .success(record.output)
      record.completion(Completed(result: result, timing: record.timing))
      record.followers.forEach { $0() }
      withExtendedLifetime(record.retained) {}
      // After the completion has handed the frame on, so a caller that waits
      // for idle sees every completion already dispatched.
      slotPermits.signal()
    }
  }

  // MARK: - Textures

  private struct CopyPlane { var index: Int; var format: MTLPixelFormat; var width: Int; var height: Int }

  /// Texture views that cover each plane's media exactly. v210 is read as one
  /// RGBA32Uint texel per 6-pixel group (four packed 32-bit words).
  private static func copyPlanes(type: OSType, width: Int, height: Int) throws -> [CopyPlane] {
    switch type {
    case kCVPixelFormatType_422YpCbCr10:
      return [CopyPlane(index: 0, format: .rgba32Uint, width: (width + 5) / 6, height: height)]
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, OSType(0x50323136):
      return [CopyPlane(index: 0, format: .r16Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg16Uint, width: (width + 1) / 2, height: height)]
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r16Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg16Uint, width: (width + 1) / 2, height: (height + 1) / 2)]
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
      return [CopyPlane(index: 0, format: .r8Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg8Uint, width: (width + 1) / 2, height: height)]
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r8Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg8Uint, width: (width + 1) / 2, height: (height + 1) / 2)]
    case OSType(0x49343230):
      return [CopyPlane(index: 0, format: .r8Uint, width: width, height: height),
        CopyPlane(index: 1, format: .r8Uint, width: (width + 1) / 2, height: (height + 1) / 2),
        CopyPlane(index: 2, format: .r8Uint, width: (width + 1) / 2, height: (height + 1) / 2)]
    case OSType(0x50413136):
      return [CopyPlane(index: 0, format: .r16Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg16Uint, width: (width + 1) / 2, height: height),
        CopyPlane(index: 2, format: .r16Uint, width: width, height: height)]
    case OSType(0x55595641):
      return [CopyPlane(index: 0, format: .rgba8Uint, width: (width + 1) / 2, height: height),
        CopyPlane(index: 1, format: .r8Uint, width: width, height: height)]
    case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs:
      return [CopyPlane(index: 0, format: .rgba8Uint, width: (width + 1) / 2, height: height)]
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, OSType(0x72323130):
      return [CopyPlane(index: 0, format: .rgba8Uint, width: width, height: height)]
    case OSType(0x5231324c):
      return [CopyPlane(index: 0, format: .r8Uint, width: (width * 36 + 7) / 8, height: height)]
    default:
      throw VideoError.message("Passthrough does not support \(VideoContract.fourCC(type)) frames.")
    }
  }

  /// A capture frame's plane, through the texture cache. The wrapper must
  /// outlive the GPU work.
  private func view(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int)
    throws -> (AnyObject, MTLTexture) {
    var wrapper: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
      width, height, plane, &wrapper)
    if status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) {
      return (wrapper, texture)
    }
    // A final partial packing group may exceed Core Video's media-pixel
    // interpretation of an integer view. Validated backing storage still
    // contains the complete group; map that exact IOSurface extent directly.
    if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
      descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
      if let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane) { return (texture, texture) }
    }
    throw VideoError.message("Cannot map frame plane \(plane) for the GPU (\(status)).")
  }

  private func outputTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> MTLTexture {
    try outputTexture(buffer, plane: plane, format: format,
      width: CVPixelBufferGetWidthOfPlane(buffer, plane), height: CVPixelBufferGetHeightOfPlane(buffer, plane))
  }

  /// Output surfaces come from our own pools, which recycle a fixed set of
  /// IOSurfaces. Each gets one texture, kept resident, keyed by IOSurface ID.
  /// The entry retains its surface, so the ID cannot be reused while cached;
  /// identity is still checked.
  private func outputTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
    width: Int, height: Int) throws -> MTLTexture {
    outputCacheLock.lock(); defer { outputCacheLock.unlock() }
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
      throw VideoError.message("Output frame is not IOSurface-backed.")
    }
    let key = SurfaceKey(id: IOSurfaceGetID(surface), plane: plane, format: format.rawValue)
    if let entry = outputTextures[key], entry.surface === surface {
      entry.lastUsed = submitted
      entry.lastUsedTime = monotonicNow()
      return entry.texture
    }
    if let stale = outputTextures.removeValue(forKey: key) {
      guard waitUntilIdle(timeout: 2) else { throw VideoError.message("The GPU stopped responding.") }
      outputResidency.removeAllocation(stale.texture)
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
      mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane) else {
      throw VideoError.message("Cannot map output plane \(plane) for the GPU.")
    }
    let bytes = IOSurfaceGetAllocSize(surface)
    try allocationBudget.policy.validateMinimum(bytesPerSlot: bytes)
    let lease: GPUAllocationBudget.Lease
    do {
      lease = try allocationBudget.acquire(backingID: UInt64(IOSurfaceGetID(surface)), bytes: bytes, generation: 0, owner: surface)
    } catch {
      evictIdleOutputTextures(pressure: true)
      lease = try allocationBudget.acquire(backingID: UInt64(IOSurfaceGetID(surface)), bytes: bytes, generation: 0, owner: surface)
    }
    outputTextures[key] = SurfaceEntry(surface: surface, texture: texture, lastUsed: submitted, time: monotonicNow(), lease: lease)
    scheduleAgeSweepLocked()
    outputResidency.addAllocation(texture)
    outputResidencyDirty = true
    return texture
  }

  /// Preparing a frame may fail before a command is committed. Those views
  /// have no GPU user and must not strand a byte-budget reservation.
  private func discardUnsubmittedOutputTextures(sequence: UInt64) {
    outputCacheLock.withLock {
      let unused = outputTextures.filter { $0.value.lastUsed == sequence }
      for (key, entry) in unused {
        outputTextures.removeValue(forKey: key)
        outputResidency.removeAllocation(entry.texture)
      }
      if !unused.isEmpty { outputResidency.commit() }
    }
  }

  /// Age is monotonic elapsed time, independent of frame rate. A backing
  /// stays charged and resident until its final GPU use has completed.
  private func evictIdleOutputTextures(pressure: Bool = false) {
    outputCacheLock.lock(); defer { outputCacheLock.unlock() }
    let completed = stateLock.withLock { nextCompletion }
    let now = monotonicNow()
    let stale = outputTextures.filter {
      $0.value.lastUsed < completed && (pressure ||
        (now >= $0.value.lastUsedTime && now - $0.value.lastUsedTime >= cacheIdleAge))
    }
    guard !stale.isEmpty else { return }
    for (key, entry) in stale {
      outputTextures.removeValue(forKey: key)
      outputResidency.removeAllocation(entry.texture)
    }
    outputResidency.commit()
  }

  private func scheduleAgeSweepLocked() {
    guard !ageSweepScheduled, !outputTextures.isEmpty else { return }
    ageSweepScheduled = true
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cacheIdleAge) { [weak self] in
      guard let self else { return }
      self.outputCacheLock.withLock {
        self.ageSweepScheduled = false
        self.evictIdleOutputTextures()
        self.scheduleAgeSweepLocked()
      }
    }
  }

  /// Releases capture surfaces the texture cache still holds. Runs before a
  /// frame maps its input, preferably when no frame is in flight (normally
  /// true between frames: GPU work takes a fraction of a frame).
  private func flushTextureCache() {
    textureCacheUses &+= 1
    guard textureCacheUses >= Self.textureCacheFlushInterval else { return }
    // Prefer an idle moment; under sustained load flush anyway (frames in
    // flight hold their CVMetalTextures, which keeps their textures valid).
    guard framesInFlight == 0 || textureCacheUses >= Self.textureCacheFlushInterval * 4 else { return }
    textureCacheUses = 0
    CVMetalTextureCacheFlush(textureCache, 0)
  }

  // MARK: - Metadata

  /// A bit-exact typed copy inherits the immutable source declaration, even
  /// when raw CPU ingest supplied no Core Video colour attachments. Preserve
  /// the complete contract for spaces Core Video cannot represent directly.
  static func stampDeclaredColorimetry(_ colour: Colorimetry, on output: CVPixelBuffer) {
    for key in [kCVImageBufferCGColorSpaceKey, kCVImageBufferICCProfileKey,
      kCVImageBufferGammaLevelKey, kCVImageBufferLogTransferFunctionKey, kCVImageBufferColorPrimariesKey,
      kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
      CVBufferRemoveAttachment(output, key)
    }
    let primaries: [Colorimetry.Primaries: CFString] = [.rec709: kCVImageBufferColorPrimaries_ITU_R_709_2,
      .rec2020: kCVImageBufferColorPrimaries_ITU_R_2020, .p3D65: kCVImageBufferColorPrimaries_P3_D65]
    let transfers: [Colorimetry.Transfer: CFString] = [.rec709: kCVImageBufferTransferFunction_ITU_R_709_2,
      .sRGB: kCVImageBufferTransferFunction_sRGB, .linear: kCVImageBufferTransferFunction_Linear,
      .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG]
    let matrices: [Colorimetry.Matrix: CFString] = [.rec709: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
      .rec2020: kCVImageBufferYCbCrMatrix_ITU_R_2020, .rec601: kCVImageBufferYCbCrMatrix_ITU_R_601_4]
    for (key, value) in [(kCVImageBufferColorPrimariesKey, primaries[colour.primaries]),
      (kCVImageBufferTransferFunctionKey, transfers[colour.transfer]),
      (kCVImageBufferYCbCrMatrixKey, matrices[colour.matrix])] {
      if let value { CVBufferSetAttachment(output, key, value, .shouldPropagate) }
    }
    let location: CFString?
    switch (colour.horizontalChromaSiting, colour.verticalChromaSiting) {
    case (.left, .top): location = kCVImageBufferChromaLocation_TopLeft
    case (.left, .center): location = kCVImageBufferChromaLocation_Left
    case (.left, .bottom): location = kCVImageBufferChromaLocation_BottomLeft
    case (.center, .top): location = kCVImageBufferChromaLocation_Top
    case (.center, .center): location = kCVImageBufferChromaLocation_Center
    case (.center, .bottom): location = kCVImageBufferChromaLocation_Bottom
    default: location = nil
    }
    if let location { CVBufferSetAttachment(output, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate) }
    if let data = try? JSONEncoder().encode(ColorimetryContract(colour)) {
      CVBufferSetAttachment(output, declaredColorimetryAttachmentKey, data as CFData, .shouldPropagate)
    }
  }

  private func stampAttachments(_ output: CVPixelBuffer, from input: CVPixelBuffer,
    configuration: PipelineConfiguration, matrix: String?, destination: Colorimetry, geometryConverted: Bool, colourEncodingChanged: Bool) {
    // Pool buffers can carry attachments from their previous use. Start from a
    // clean attachment set, then carry the source's geometry/timing metadata
    // into the new image. Color labels are overridden below after the exact
    // decode/encode matrix is known; this avoids dropping pixel aspect ratio,
    // clean aperture, and producer-specific metadata on LUT-processed frames.
    CVBufferRemoveAllAttachments(output)
    CVBufferPropagateAttachments(input, output)
    CVBufferRemoveAttachment(output, Self.declaredColorimetryAttachmentKey)
    // Encoders average each pair/block, producing centered chroma even if input
    // samples were left-cosited. Never carry the source's location onto output.
    CVBufferSetAttachment(output, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
    CVBufferRemoveAttachment(output, kCVImageBufferChromaLocationBottomFieldKey)
    if geometryConverted {
      CVBufferRemoveAttachment(output, kCVImageBufferPixelAspectRatioKey)
      CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
      CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey)
    }
    // Encoding always writes video-range centered chroma. Stamp that actual
    // transport through the same writer used by typed bit-exact copies, and
    // discard stale ICC/CGColorSpace/gamma tags that could override it.
    let encoded = Colorimetry(primaries: destination.primaries, transfer: destination.transfer,
      matrix: destination.matrix, range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .center)
    Self.stampDeclaredColorimetry(encoded, on: output)
    if configuration.applyLUT || colourEncodingChanged {
      CVBufferRemoveAttachment(output, kCVImageBufferMasteringDisplayColorVolumeKey)
      CVBufferRemoveAttachment(output, kCVImageBufferContentLightLevelInfoKey)
    }
  }
}
