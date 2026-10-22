import CoreVideo
import Foundation
import IOSurface
import Metal

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
/// - A persistent residency set (LUT texture, parameters, intermediate) and
///   an output residency set of textures cached per output IOSurface (pools
///   recycle their surfaces, so these are created once and stay resident).
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
  private var passthroughPool: CVPixelBufferPool?
  private var passthroughFormat: (type: OSType, width: Int, height: Int)?
  private var cube: CubeLUT?
  private var lutTexture: MTLTexture
  private var horizontalTexture: MTLTexture?
  private var outputTextures: [SurfaceKey: SurfaceEntry] = [:]
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
  nonisolated(unsafe) private static let allocationLimit = [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary

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
    init(surface: IOSurfaceRef, texture: MTLTexture, lastUsed: UInt64) {
      self.surface = surface
      self.texture = texture
      self.lastUsed = lastUsed
    }
  }

  /// One committed frame. Holds every object the command buffer references
  /// that Metal 4 does not retain: the capture frame's CVMetalTextures, the
  /// output buffer, and the LUT/intermediate textures of that frame.
  private final class InFlight: @unchecked Sendable {
    let output: CVPixelBuffer
    let retained: [AnyObject]
    let completion: Completion
    var timing: FrameTiming
    var error: Error?
    var done = false
    /// Work to run right after this frame's completion, in order (frames the
    /// caller did not put on the GPU but must order behind this one).
    var followers: [() -> Void] = []
    init(output: CVPixelBuffer, retained: [AnyObject], completion: @escaping Completion, timing: FrameTiming) {
      self.output = output
      self.retained = retained
      self.completion = completion
      self.timing = timing
    }
  }

  private struct Parameters {
    var geometry: SIMD4<UInt32>
    var decodeRange: SIMD4<Float>
    var decodeMatrix: SIMD4<Float>
    var encodeMatrix: SIMD4<Float>
    var chroma: SIMD4<Float>
    var lutDomainLow: SIMD4<Float>
    var lutDomainScale: SIMD4<Float>
    var lutShape: SIMD4<UInt32>
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

  init(qos: DispatchQoS = .userInteractive) throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw VideoError.message("A Metal GPU is required.") }
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
      library = try device.makeLibrary(URL: URL(fileURLWithPath: path))
    } else {
      let url = ProcessInfo.processInfo.environment["ULTRACAM_SHADER"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.url(forResource: "LUTShaders", withExtension: "metal")
      guard let url else { throw VideoError.message("GPU shader resource is missing.") }
      let descriptor = MTL4LibraryDescriptor()
      descriptor.source = try String(contentsOf: url, encoding: .utf8)
      descriptor.name = "LUTShaders"
      library = try compiler.makeLibrary(descriptor: descriptor)
    }
    var pipelines: [String: MTLComputePipelineState] = [:]
    for name in ["fullPackedNV12", "fullPacked422", "fullPlanarNV12", "fullPlanar422",
      "horizontalPacked", "horizontalPlanar", "verticalNV12", "vertical422"] {
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
    tableDescriptor.maxTextureBindCount = 5
    tableDescriptor.maxBufferBindCount = 1
    var slots: [Slot] = []
    for index in 0..<VideoContract.maxFramesInFlight {
      guard let allocator = device.makeCommandAllocator(), let commandBuffer = device.makeCommandBuffer() else {
        throw VideoError.message("Cannot allocate GPU command memory.")
      }
      let residency = MTLResidencySetDescriptor()
      residency.label = "Capture frame \(index)"
      residency.initialCapacity = 2
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
    // Bound when no LUT is applied; the shader returns before reading it.
    lutTexture = try Self.makeLUTTexture(device: device, dimension: 2,
      rgba: [0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1])
    persistentResidency.addAllocations([parameterBuffer, lutTexture])
    persistentResidency.commit()
    commandQueue.addResidencySets([persistentResidency, outputResidency])
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    guard status == kCVReturnSuccess else { throw VideoError.message("Cannot create GPU texture cache.") }
  }

  deinit {
    _ = waitUntilIdle(timeout: 2)
    commandQueue.removeResidencySets([persistentResidency, outputResidency])
  }

  private static func makeLUTTexture(device: MTLDevice, dimension n: Int, rgba: [Float]) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor()
    descriptor.textureType = .type3D
    descriptor.pixelFormat = .rgba32Float
    descriptor.width = n
    descriptor.height = n
    descriptor.depth = n
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard rgba.count == n * n * n * 4, let texture = device.makeTexture(descriptor: descriptor) else {
      throw VideoError.message("Cannot upload LUT to GPU.")
    }
    rgba.withUnsafeBytes { bytes in
      texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: n * 16, bytesPerImage: n * n * 16)
    }
    texture.label = "LUT \(n)³"
    return texture
  }

  func load(_ cube: CubeLUT) throws {
    let texture = try Self.makeLUTTexture(device: device, dimension: cube.dimension, rgba: cube.rgba)
    // Frames in flight reference the old LUT; replace it only once they finish.
    guard waitUntilIdle(timeout: 2) else { throw VideoError.message("The GPU stopped responding; the LUT was not loaded.") }
    persistentResidency.removeAllocation(lutTexture)
    persistentResidency.addAllocation(texture)
    persistentResidency.commit()
    lutTexture = texture
    self.cube = cube
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

  private func preparePool(_ configuration: PipelineConfiguration) throws -> CVPixelBufferPool {
    if let previous = poolConfiguration, previous.width == configuration.width,
      previous.height == configuration.height, previous.pixelFormat == configuration.pixelFormat,
      let pool { return pool }
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil,
      [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.outputPoolMinimum] as CFDictionary, [
      kCVPixelBufferPixelFormatTypeKey: configuration.pixelFormat,
      kCVPixelBufferWidthKey: configuration.width,
      kCVPixelBufferHeightKey: configuration.height,
      kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw VideoError.message("Cannot allocate output pool.") }
    self.pool = pool
    poolConfiguration = configuration
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
    }
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
  }

  // Owning queue only. Waits for committed frames first: Metal 4 command
  // buffers do not retain what they use. Published pixel buffers stay valid;
  // the loaded LUT and compiled pipelines stay.
  func releaseIdleResources() {
    let hadResources = horizontalTexture != nil || pool != nil || passthroughPool != nil || !outputTextures.isEmpty
    guard hadResources else { return }
    guard waitUntilIdle(timeout: 2) else { return }
    releaseIntermediate()
    pool = nil
    poolConfiguration = nil
    passthroughPool = nil
    passthroughFormat = nil
    for entry in outputTextures.values { outputResidency.removeAllocation(entry.texture) }
    outputResidency.commit()
    outputTextures.removeAll()
    outputResidencyDirty = false
    CVMetalTextureCacheFlush(textureCache, 0)
  }

  // MARK: - Synchronous wrappers (warm-up and tests)

  func process(_ input: CVPixelBuffer, configuration: PipelineConfiguration) throws -> CVPixelBuffer {
    if try validate(input, untouched: configuration.untouched) { releaseIdleResources(); return input }
    return try waitFor { try submit(input, configuration: configuration, completion: $0) }
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
    guard width == 3840, height == 2160 else {
      throw VideoError.message("Expected 3840 × 2160 input; received \(width) × \(height).")
    }
    guard VideoContract.tenBit422.contains(CVPixelBufferGetPixelFormatType(input)) else {
      throw VideoError.message("Expected 10-bit 4:2:2 input.")
    }
    try VideoBufferLayout.validate(input)
    return untouched
  }

  /// Encodes and commits one processed frame. `completion` runs on the
  /// processor's completion queue after the GPU finished, in submission order.
  /// `isCurrent` lets a caller abandon a frame waiting for a GPU slot.
  func submit(_ input: CVPixelBuffer, configuration: PipelineConfiguration,
    isCurrent: () -> Bool = { true }, completion: @escaping Completion) throws {
    let submittedAt = ProcessInfo.processInfo.systemUptime
    if try validate(input, untouched: configuration.untouched) {
      throw VideoError.message("An untouched configuration has no GPU work; use passthrough.")
    }
    guard !configuration.applyLUT || cube != nil else { throw VideoError.message("Load a LUT or turn off Apply LUT.") }
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    let chromaLocation = CVBufferCopyAttachment(input, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
    // SMPTE/QuickTime 4:2:2 is left-cosited unless the producer labels it centered.
    let chromaOffset: Float = chromaLocation == kCVImageBufferChromaLocation_Center as String ||
      chromaLocation == kCVImageBufferChromaLocation_Top as String ||
      chromaLocation == kCVImageBufferChromaLocation_Bottom as String ? 0.5 : 0
    let matrix = CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil) as? String
    let kr: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.2627 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.299 : 0.2126)
    let kb: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.0593 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.114 : 0.0722)
    let kg = 1 - kr - kb
    let fullRange = type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    let low = cube?.domainMin ?? .zero
    let scale = SIMD3<Float>(repeating: 1) / ((cube?.domainMax ?? SIMD3(repeating: 1)) - low)
    var parameters = Parameters(
      geometry: SIMD4(UInt32(width), UInt32(height), 0, 0),
      decodeRange: SIMD4(fullRange ? 0 : 64, fullRange ? 1023 : 876, 512, fullRange ? 1023 : 896),
      decodeMatrix: SIMD4(2 * (1 - kr), 2 * (1 - kb), 2 * kb * (1 - kb) / kg, 2 * kr * (1 - kr) / kg),
      encodeMatrix: SIMD4(configuration.applyLUT ? 0.2126 : kr, configuration.applyLUT ? 0.0722 : kb, 0, 0),
      chroma: SIMD4(chromaOffset, 0, 0, 0),
      lutDomainLow: SIMD4(low, 0), lutDomainScale: SIMD4(scale, 0),
      lutShape: SIMD4(UInt32(cube?.dimension ?? 2), 1, configuration.applyLUT ? 1 : 0, 0))
    // Reserve output before mapping a borrowed capture frame. A consumer that
    // holds every output buffer is a stall, reported by the caller.
    let pool = try preparePool(configuration)
    var created: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, Self.allocationLimit, &created)
    if status == kCVReturnWouldExceedAllocationThreshold { throw VideoError.outputBackPressure }
    guard status == kCVReturnSuccess, let output = created else {
      throw VideoError.message("Output buffers are unavailable (\(status)).")
    }
    flushTextureCache()
    let y = try outputTexture(output, plane: 0, format: configuration.convertTo420 ? .r8Unorm : .r16Unorm)
    let uv = try outputTexture(output, plane: 1, format: configuration.convertTo420 ? .rg8Unorm : .rg16Unorm)
    var inputs: [MTLTexture] = []
    var wrappers: [AnyObject] = []
    let packed = type == kCVPixelFormatType_422YpCbCr10
    if packed {
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
    } else {
      let (yWrapper, luma) = try view(input, plane: 0, format: .r16Unorm,
        width: CVPixelBufferGetWidthOfPlane(input, 0), height: CVPixelBufferGetHeightOfPlane(input, 0))
      let (uvWrapper, chroma) = try view(input, plane: 1, format: .rg16Unorm,
        width: CVPixelBufferGetWidthOfPlane(input, 1), height: CVPixelBufferGetHeightOfPlane(input, 1))
      inputs += [luma, chroma]
      wrappers += [yWrapper, uvWrapper]
    }
    let horizontal = configuration.downscale ? try intermediate(width: configuration.width, height: height) : nil
    // Frames in flight may still use it: release at an idle moment (normally
    // the next frame) rather than wait for the GPU on the capture thread.
    if !configuration.downscale, horizontalTexture != nil, framesInFlight == 0 { releaseIntermediate() }
    stampAttachments(output, from: input, configuration: configuration, matrix: matrix)
    let lut = lutTexture
    try encode(output: output, retained: wrappers + [input, lut] + (horizontal.map { [$0] } ?? []),
      inputResidency: inputs, timing: FrameTiming(submitted: submittedAt), isCurrent: isCurrent,
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
      first.setTexture(lut.gpuResourceID, index: 2)
      encoder.setArgumentTable(first)
      if let horizontal {
        first.setTexture(horizontal.gpuResourceID, index: 3)
        guard let state = pipelines[packed ? "horizontalPacked" : "horizontalPlanar"] else { return false }
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
        guard let vertical = pipelines[configuration.convertTo420 ? "verticalNV12" : "vertical422"] else { return false }
        encoder.setComputePipelineState(vertical)
        dispatchBlocks(encoder, state: vertical, width: configuration.width, height: configuration.height,
          is420: configuration.convertTo420)
      } else {
        first.setTexture(y.gpuResourceID, index: 3)
        first.setTexture(uv.gpuResourceID, index: 4)
        let name = (packed ? "fullPacked" : "fullPlanar") + (configuration.convertTo420 ? "NV12" : "422")
        guard let state = pipelines[name] else { return false }
        encoder.setComputePipelineState(state)
        dispatchBlocks(encoder, state: state, width: width, height: height, is420: configuration.convertTo420)
      }
      return true
    }
  }

  /// One thread per 2×2 (4:2:0) or 2×1 (4:2:2) output block.
  private func dispatchBlocks(_ encoder: MTL4ComputeCommandEncoder, state: MTLComputePipelineState,
    width: Int, height: Int, is420: Bool) {
    let w = state.threadExecutionWidth
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: width / 2, height: is420 ? height / 2 : height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: max(1, min(8, state.maxTotalThreadsPerThreadgroup / w)), depth: 1))
  }

  /// Processing off: one GPU copy of the capture frame into an IOSurface this
  /// process owns. DeckLink reuses its buffer once our frame reference is gone,
  /// even while the window server or a meeting app still shows it; a pool
  /// buffer is not recycled while another process is using its IOSurface.
  /// Pipelined like `submit`.
  func submitPassthrough(_ input: CVPixelBuffer, isCurrent: () -> Bool = { true },
    completion: @escaping Completion) throws {
    let submittedAt = ProcessInfo.processInfo.systemUptime
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
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
    }
    var created: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, passthroughPool!, Self.allocationLimit, &created)
    if status == kCVReturnWouldExceedAllocationThreshold { throw VideoError.outputBackPressure }
    guard status == kCVReturnSuccess, let output = created else {
      throw VideoError.message("Passthrough frames are unavailable (\(status)).")
    }
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
    if let attachments = CVBufferCopyAttachments(input, .shouldNotPropagate) {
      CVBufferSetAttachments(output, attachments, .shouldNotPropagate)
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
    if outputResidencyDirty {
      outputResidency.commit()
      outputResidencyDirty = false
    }
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
    let record = InFlight(output: output, retained: retained, completion: completion, timing: timing)
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
  func afterCommittedFrames(_ body: @escaping () -> Void) {
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
  /// RGBA32Uint texel per 6-pixel group, as in the DeckLink SDK's Metal sample.
  private static func copyPlanes(type: OSType, width: Int, height: Int) throws -> [CopyPlane] {
    switch type {
    case kCVPixelFormatType_422YpCbCr10:
      return [CopyPlane(index: 0, format: .rgba32Uint, width: (width + 5) / 6, height: height)]
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r16Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg16Uint, width: width / 2, height: height)]
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r16Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg16Uint, width: width / 2, height: height / 2)]
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r8Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg8Uint, width: width / 2, height: height / 2)]
    default:
      throw VideoError.message("Passthrough does not support \(VideoContract.fourCC(type)) frames.")
    }
  }

  /// A capture frame's plane, through the texture cache. The wrapper must
  /// outlive the GPU work.
  private func view(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int)
    throws -> (CVMetalTexture, MTLTexture) {
    var wrapper: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
      width, height, plane, &wrapper)
    guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
      throw VideoError.message("Cannot map frame plane \(plane) for the GPU (\(status)).")
    }
    return (wrapper, texture)
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
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
      throw VideoError.message("Output frame is not IOSurface-backed.")
    }
    let key = SurfaceKey(id: IOSurfaceGetID(surface), plane: plane, format: format.rawValue)
    if let entry = outputTextures[key], entry.surface === surface {
      entry.lastUsed = submitted
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
    outputTextures[key] = SurfaceEntry(surface: surface, texture: texture, lastUsed: submitted)
    outputResidency.addAllocation(texture)
    outputResidencyDirty = true
    return texture
  }

  /// Surfaces of a replaced pool stop being used; release them after four
  /// seconds of frames. Far longer than any committed frame can be in flight.
  private func evictIdleOutputTextures() {
    guard submitted % 120 == 0 else { return }
    let completed = stateLock.withLock { nextCompletion }
    let stale = outputTextures.filter { $0.value.lastUsed + 240 < submitted && $0.value.lastUsed < completed }
    guard !stale.isEmpty else { return }
    for (key, entry) in stale {
      outputTextures.removeValue(forKey: key)
      outputResidency.removeAllocation(entry.texture)
    }
    outputResidency.commit()
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

  private func stampAttachments(_ output: CVPixelBuffer, from input: CVPixelBuffer,
    configuration: PipelineConfiguration, matrix: String?) {
    // Pool buffers can carry attachments from their previous use. Start from a
    // clean attachment set, then carry the source's geometry/timing metadata
    // into the new image. Color labels are overridden below after the exact
    // decode/encode matrix is known; this avoids dropping pixel aspect ratio,
    // clean aperture, and producer-specific metadata on LUT-processed frames.
    CVBufferRemoveAllAttachments(output)
    CVBufferPropagateAttachments(input, output)
    // Encoders average each pair/block, producing centered chroma even if input
    // samples were left-cosited. Never carry the source's location onto output.
    CVBufferSetAttachment(output, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
    CVBufferRemoveAttachment(output, kCVImageBufferChromaLocationBottomFieldKey)
    if configuration.downscale {
      CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
      CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey)
    }
    // Only preserve a matrix we actually decoded. An arbitrary attachment is
    // not a valid color contract: the decode path intentionally falls back to
    // Rec.709 for unknown values, so carrying that unknown value to the output
    // would make downstream clients interpret the encoded pixels differently
    // from the matrix used to produce them.
    let outputMatrix: CFString
    if configuration.applyLUT {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
    } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    } else {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }
    CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, outputMatrix, .shouldPropagate)
    if configuration.applyLUT {
      CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
  }
}
