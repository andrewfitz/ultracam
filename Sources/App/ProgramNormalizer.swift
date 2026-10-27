import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal

/// Converts a source camera's processed frame into the Program camera's fixed
/// output contract on the GPU, so a cut between cameras with different
/// processing settings never renegotiates the Program virtual camera.
///
/// Zero CPU pixel copies: source and destination are IOSurfaces wrapped as
/// Metal textures; one compute pass reads the source planes (4:2:0 8-bit,
/// 4:2:2 10-bit bi-planar, or packed v210) and writes the contract's planes
/// into an IOSurface pool owned here. Y'CbCr stays Y'CbCr (every format in the
/// pipeline is BT.709 video range), so the pass only rescales, resamples chroma
/// and requantizes. Integer ratios (1:1, 2:1, 4:1) use an exact box filter,
/// so identity planes are bit-exact; other ratios are bilinear.
///
/// Metal 4: one `MTL4CommandQueue`, a ring of `MTL4CommandAllocator` +
/// reusable `MTL4CommandBuffer` slots, `MTL4ArgumentTable` bindings, a
/// `MTLResidencySet` for every texture and parameter buffer, pipelines built
/// once by `MTL4Compiler` from the embedded source below, completion through
/// commit feedback (which also reports GPU time), and a `MTLSharedEvent` that
/// gates allocator reuse. `normalize` never waits for the GPU: the Program
/// route calls it under its lock from capture delivery threads, so a GPU too
/// far behind is a counted stall error, not a wait.
///
/// Texture residency is cached by IOSurface ID. Textures are made directly from
/// the IOSurface rather than through `CVMetalTextureCache`: a cached
/// `CVMetalTexture` retains its `CVPixelBuffer`, which would pin the capture
/// and Program pools' buffers and make every reuse a new allocation. The cache
/// entry retains only the IOSurface (so its ID cannot be reused while cached)
/// and is evicted once the surface is idle and its last GPU use has completed.
/// When conversions stop (no client, or every source already matches the
/// contract), a delayed sweep releases every completed surface and the output
/// pool, so an idle normalizer pins no capture or Program memory.
final class ProgramNormalizer: ProgramFrameNormalizing, @unchecked Sendable {
  struct Statistics: Equatable, Sendable {
    var frames: UInt64 = 0
    var failures: UInt64 = 0
    var lastGPUMilliseconds: Double = 0
    var maxGPUMilliseconds: Double = 0
    var totalGPUMilliseconds: Double = 0
    var cachedSurfaces = 0
    /// Frames not converted because every command slot was still on the GPU.
    var gpuStalls: UInt64 = 0
    /// Frames not converted because consumers held every output buffer.
    var outputStalls: UInt64 = 0
    var meanGPUMilliseconds: Double { frames == 0 ? 0 : totalGPUMilliseconds / Double(frames) }
  }

  private enum Code: UInt32 {
    case yuv420 = 0, yuv422 = 1, v210 = 2, yuv42010 = 3, yuv4228 = 4
    var is420: Bool { self == .yuv420 || self == .yuv42010 }
    var eight: Bool { self == .yuv420 || self == .yuv4228 }
  }

  /// Keeps both frames alive until the GPU is done. CVPixelBuffer is
  /// thread-safe to retain and release; nothing reads its pixels on the CPU.
  private struct RetainedBuffers: @unchecked Sendable {
    let source: CVPixelBuffer
    let output: CVPixelBuffer
  }

  private struct Params {
    var source: SIMD4<UInt32>
    var destination: SIMD4<UInt32>
  }

  private struct TextureKey: Hashable {
    let surface: IOSurfaceID
    let plane: Int
    let format: UInt
  }

  private final class CachedTexture {
    let surface: IOSurfaceRef
    let texture: MTLTexture
    var lastUsed: UInt64
    init(surface: IOSurfaceRef, texture: MTLTexture, lastUsed: UInt64) {
      self.surface = surface
      self.texture = texture
      self.lastUsed = lastUsed
    }
  }

  private final class Slot {
    let allocator: MTL4CommandAllocator
    let commandBuffer: MTL4CommandBuffer
    let tables: [MTL4ArgumentTable]
    let params: MTLBuffer
    var lastSequence: UInt64 = 0
    init(allocator: MTL4CommandAllocator, commandBuffer: MTL4CommandBuffer,
         tables: [MTL4ArgumentTable], params: MTLBuffer) {
      self.allocator = allocator
      self.commandBuffer = commandBuffer
      self.tables = tables
      self.params = params
    }
  }

  /// Command slots. The Program stage holds at most
  /// `ProgramOutputRoute.stageCapacity` conversions, so a slot is always free
  /// unless the GPU itself has stopped; then `normalize` reports a stall.
  static let slotCount = ProgramOutputRoute.stageCapacity + 8
  /// An idle cached surface is released after this many frames (~2 s at 60 fps).
  static let idleSurfaceFrames: UInt64 = 120
  static let maxCachedSurfaces = 96

  /// With no conversion for this long, completed surfaces and the pool go.
  let idleReleaseDelay: TimeInterval

  private let lock = NSLock()
  private let statsLock = NSLock()
  private let device: MTLDevice
  private let feedbackQueue = DispatchQueue(label: "org.ultracam.program-normalizer.completion",
    qos: .userInteractive)
  private let queue: MTL4CommandQueue
  private let residency: MTLResidencySet
  private let event: MTLSharedEvent
  private let lumaState: MTLComputePipelineState
  private let chromaState: MTLComputePipelineState
  private let v210State: MTLComputePipelineState
  private let slots: [Slot]
  private var sequence: UInt64 = 0
  private var textures: [TextureKey: CachedTexture] = [:]
  private var pool: CVPixelBufferPool?
  private var poolFormat: ProgramOutputFormat?
  private var statistics = Statistics()
  private var idleSweepScheduled = false

  init(idleReleaseDelay: TimeInterval = 2) throws {
    self.idleReleaseDelay = idleReleaseDelay
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw VideoError.message("A Metal GPU is required for Program output.")
    }
    self.device = device
    let queueDescriptor = MTL4CommandQueueDescriptor()
    queueDescriptor.label = "Program normalizer"
    queueDescriptor.feedbackQueue = feedbackQueue
    queue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
    // The descriptor's `feedbackQueue` is an `assign` property, but the
    // command queue releases it when it goes away; without one extra retain
    // libdispatch traps "Over-release of an object" at teardown (observed on
    // macOS 27, as in LUTProcessor). Taken only once the queue exists, so a
    // failed creation leaks nothing.
    _ = Unmanaged.passRetained(feedbackQueue)
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor()
    libraryDescriptor.source = Self.shaderSource
    libraryDescriptor.name = "ProgramNormalizer"
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      let function = MTL4LibraryFunctionDescriptor()
      function.name = name
      function.library = library
      let descriptor = MTL4ComputePipelineDescriptor()
      descriptor.computeFunctionDescriptor = function
      return try compiler.makeComputePipelineState(descriptor: descriptor)
    }
    lumaState = try pipeline("programNormalizeLuma")
    chromaState = try pipeline("programNormalizeChroma")
    v210State = try pipeline("programNormalizeV210")
    let residencyDescriptor = MTLResidencySetDescriptor()
    residencyDescriptor.label = "Program normalizer"
    residencyDescriptor.initialCapacity = 64
    residency = try device.makeResidencySet(descriptor: residencyDescriptor)
    guard let event = device.makeSharedEvent() else {
      throw VideoError.message("Cannot create the Program GPU event.")
    }
    self.event = event
    let tableDescriptor = MTL4ArgumentTableDescriptor()
    tableDescriptor.maxTextureBindCount = 3
    tableDescriptor.maxBufferBindCount = 1
    var slots: [Slot] = []
    for _ in 0..<Self.slotCount {
      guard let allocator = device.makeCommandAllocator(),
        let commandBuffer = device.makeCommandBuffer(),
        let params = device.makeBuffer(length: 256, options: .storageModeShared) else {
        throw VideoError.message("Cannot allocate Program GPU command resources.")
      }
      let tables = try (0..<2).map { _ in try device.makeArgumentTable(descriptor: tableDescriptor) }
      residency.addAllocation(params)
      slots.append(Slot(allocator: allocator, commandBuffer: commandBuffer, tables: tables, params: params))
    }
    self.slots = slots
    residency.commit()
    queue.addResidencySet(residency)
  }

  deinit {
    // Allocators and argument tables must outlive the GPU work that uses them.
    if sequence > 0 { _ = event.wait(untilSignaledValue: sequence, timeoutMS: 2_000) }
  }

  var currentStatistics: Statistics {
    statsLock.lock()
    defer { statsLock.unlock() }
    return statistics
  }

  static func supportsSource(_ format: OSType) -> Bool { sourceCode(format) != nil }

  static func supportsDestination(_ format: OSType) -> Bool { destinationCode(format) != nil }

  func canNormalize(_ metadata: ProcessedFrameMetadata, to contract: ProgramOutputFormat) -> Bool {
    Self.supportsSource(OSType(metadata.pixelFormat)) && Self.supportsDestination(contract.pixelFormat)
      && metadata.width > 0 && metadata.height > 0
  }

  /// Encodes and commits one conversion, then returns; never waits for the
  /// GPU. `completion` runs once, on the feedback queue, after the GPU
  /// finished writing `output`.
  func normalize(_ source: CVPixelBuffer, to contract: ProgramOutputFormat,
                 completion: @escaping @Sendable (Result<CVPixelBuffer, Error>) -> Void) throws {
    let sourceFormat = CVPixelBufferGetPixelFormatType(source)
    guard let sourceCode = Self.sourceCode(sourceFormat),
      let destinationCode = Self.destinationCode(contract.pixelFormat) else {
      throw VideoError.message("Program can't convert \(VideoContract.fourCC(sourceFormat)) to \(VideoContract.fourCC(contract.pixelFormat)).")
    }
    guard let sourceSurface = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue() else {
      throw VideoError.message("The Program source frame is not IOSurface-backed.")
    }
    lock.lock()
    defer { lock.unlock() }
    // Committed to `self.sequence` only once the work is on the GPU, so a
    // failed encode never leaves the shared event waiting for a value.
    let sequence = self.sequence &+ 1
    let slot = slots[Int(sequence % UInt64(slots.count))]
    if slot.lastSequence > 0, event.signaledValue < slot.lastSequence {
      // The GPU is `slotCount` conversions behind: it has stopped. Waiting
      // here would hold the Program route lock and every capture delivery
      // queue behind it, so this is a counted stall error instead.
      recordStall(output: false)
      throw VideoError.message("The Program GPU conversion stalled: \(Self.slotCount) frames are still on the GPU.")
    }
    let output: CVPixelBuffer
    do { output = try makeOutput(contract) } catch VideoError.outputBackPressure {
      recordStall(output: true)
      throw VideoError.outputBackPressure
    }
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let resized = width != contract.width || height != contract.height
    Self.stampAttachments(output, from: source, resized: resized,
      chromaResampled: resized || sourceCode.is420 != destinationCode.is420)
    let fullRange: UInt32 = sourceFormat == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? 1 : 0
    var residencyChanged = false
    let sourcePlanes: [MTLTexture]
    switch sourceCode {
    case .yuv420, .yuv42010:
      sourcePlanes = [
        try texture(sourceSurface, plane: 0, format: sourceCode.eight ? .r8Uint : .r16Uint, width: width, height: height,
          sequence: sequence, changed: &residencyChanged),
        try texture(sourceSurface, plane: 1, format: sourceCode.eight ? .rg8Uint : .rg16Uint, width: (width + 1) / 2,
          height: (height + 1) / 2, sequence: sequence, changed: &residencyChanged),
      ]
    case .yuv422, .yuv4228:
      sourcePlanes = [
        try texture(sourceSurface, plane: 0, format: sourceCode.eight ? .r8Uint : .r16Uint, width: width, height: height,
          sequence: sequence, changed: &residencyChanged),
        try texture(sourceSurface, plane: 1, format: sourceCode.eight ? .rg8Uint : .rg16Uint, width: (width + 1) / 2,
          height: height, sequence: sequence, changed: &residencyChanged),
      ]
    case .v210:
      let packed = try texture(sourceSurface, plane: -1, format: .rgba32Uint,
        width: (width + 5) / 6, height: height, sequence: sequence, changed: &residencyChanged)
      sourcePlanes = [packed, packed]
    }
    guard let outputSurface = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue() else {
      throw VideoError.message("The Program output pool is not IOSurface-backed.")
    }
    let dw = contract.width, dh = contract.height
    var passes: [(MTLComputePipelineState, MTLTexture, MTLSize)] = []
    switch destinationCode {
    case .yuv420, .yuv422, .yuv42010, .yuv4228:
      let eight = destinationCode.eight
      let chromaHeight = destinationCode.is420 ? (dh + 1) / 2 : dh
      let y = try texture(outputSurface, plane: 0, format: eight ? .r8Uint : .r16Uint,
        width: dw, height: dh, sequence: sequence, changed: &residencyChanged)
      let c = try texture(outputSurface, plane: 1, format: eight ? .rg8Uint : .rg16Uint,
        width: (dw + 1) / 2, height: chromaHeight, sequence: sequence, changed: &residencyChanged)
      passes = [(lumaState, y, MTLSize(width: dw, height: dh, depth: 1)),
                (chromaState, c, MTLSize(width: (dw + 1) / 2, height: chromaHeight, depth: 1))]
    case .v210:
      let packed = try texture(outputSurface, plane: -1, format: .rgba32Uint,
        width: (dw + 5) / 6, height: dh, sequence: sequence, changed: &residencyChanged)
      passes = [(v210State, packed, MTLSize(width: (dw + 5) / 6, height: dh, depth: 1))]
    }
    residencyChanged = evictIdleTextures(sequence: sequence) || residencyChanged
    if residencyChanged { residency.commit() }

    var params = Params(
      source: SIMD4(UInt32(width), UInt32(height), sourceCode.rawValue, fullRange),
      destination: SIMD4(UInt32(dw), UInt32(dh), destinationCode.rawValue, 0))
    slot.params.contents().copyMemory(from: &params, byteCount: MemoryLayout<Params>.size)

    slot.allocator.reset()
    let command = slot.commandBuffer
    command.beginCommandBuffer(allocator: slot.allocator)
    command.label = "Program normalize"
    guard let encoder = command.makeComputeCommandEncoder() else {
      command.endCommandBuffer()
      recordFailure()
      throw VideoError.message("The Program GPU encoder is unavailable.")
    }
    // The passes write disjoint planes and read only completed source frames,
    // so they need no barrier between them.
    for (index, pass) in passes.enumerated() {
      let table = slot.tables[index]
      table.setTexture(sourcePlanes[0].gpuResourceID, index: 0)
      table.setTexture(sourcePlanes[1].gpuResourceID, index: 1)
      table.setTexture(pass.1.gpuResourceID, index: 2)
      table.setAddress(slot.params.gpuAddress, index: 0)
      encoder.setComputePipelineState(pass.0)
      encoder.setArgumentTable(table)
      encoder.dispatchThreads(threadsPerGrid: pass.2,
        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }
    encoder.endEncoding()
    command.endCommandBuffer()

    let options = MTL4CommitOptions()
    // The feedback handler owns the only references the completion needs:
    // the source and output CVPixelBuffers stay alive until the GPU is done.
    let retained = RetainedBuffers(source: source, output: output)
    options.addFeedbackHandler { [weak self] feedback in
      let milliseconds = max(0, (feedback.gpuEndTime - feedback.gpuStartTime) * 1_000)
      if let error = feedback.error {
        self?.recordFailure()
        completion(.failure(error))
      } else {
        self?.recordFrame(milliseconds: milliseconds)
        completion(.success(retained.output))
      }
      // After `completion`, which takes the route lock: the route calls
      // `normalize` under its lock, so this lock is never held across it.
      self?.scheduleIdleSweep()
    }
    queue.commit([command], options: options)
    queue.signalEvent(event, value: sequence)
    slot.lastSequence = sequence
    self.sequence = sequence
  }

  /// Releases every cached surface whose GPU work has completed, and the
  /// output pool (in-flight frames keep their own buffers). Surfaces still on
  /// the GPU are released by the idle sweep once they complete.
  func releaseIdleResources() {
    lock.lock()
    defer { lock.unlock() }
    releaseCompletedLocked()
    if !textures.isEmpty { scheduleIdleSweepLocked() }
  }

  /// Pool buffers keep the attachments of their previous frame, which may be
  /// another camera's (HDR tags on an SDR picture). Start clean, then carry
  /// this source's tags: the pass changes no matrix, primaries or transfer. A
  /// resized image has no source clean aperture or display size, and resampled
  /// chroma is centered (the pass samples chroma as center-sited).
  private static func stampAttachments(_ output: CVPixelBuffer, from source: CVPixelBuffer,
                                       resized: Bool, chromaResampled: Bool) {
    CVBufferRemoveAllAttachments(output)
    CVBufferPropagateAttachments(source, output)
    if resized {
      CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
      CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey)
    }
    if chromaResampled {
      CVBufferSetAttachment(output, kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocation_Center, .shouldPropagate)
      CVBufferRemoveAttachment(output, kCVImageBufferChromaLocationBottomFieldKey)
    }
  }

  // MARK: - Resources

  // Pool allocations past this are an output stall (`outputBackPressure`).
  nonisolated(unsafe) private static let allocationLimit =
    [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary

  private func makeOutput(_ contract: ProgramOutputFormat) throws -> CVPixelBuffer {
    if poolFormat != contract || pool == nil {
      var created: CVPixelBufferPool?
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: contract.pixelFormat,
        kCVPixelBufferWidthKey: contract.width,
        kCVPixelBufferHeightKey: contract.height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      let status = CVPixelBufferPoolCreate(nil,
        [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
        attributes as CFDictionary, &created)
      guard status == kCVReturnSuccess, let created else {
        throw VideoError.message("Cannot create the Program output pool (\(status)).")
      }
      pool = created
      poolFormat = contract
    }
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool!, Self.allocationLimit, &output)
    // A consumer (camera client, monitor) holding this many Program frames
    // has stalled; shown as a counted error by the route.
    if status == kCVReturnWouldExceedAllocationThreshold { throw VideoError.outputBackPressure }
    guard status == kCVReturnSuccess, let output else {
      throw VideoError.message("Cannot allocate a Program output frame (\(status)).")
    }
    return output
  }

  /// `plane` -1 wraps a non-planar surface (v210).
  private func texture(_ surface: IOSurfaceRef, plane: Int, format: MTLPixelFormat,
                       width: Int, height: Int, sequence: UInt64,
                       changed: inout Bool) throws -> MTLTexture {
    let key = TextureKey(surface: IOSurfaceGetID(surface), plane: plane, format: format.rawValue)
    if let cached = textures[key], cached.surface === surface,
      cached.texture.width == width, cached.texture.height == height {
      cached.lastUsed = sequence
      return cached.texture
    }
    if let stale = textures.removeValue(forKey: key) {
      residency.removeAllocation(stale.texture)
      changed = true
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
      height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface,
      plane: max(plane, 0)) else {
      throw VideoError.message("Cannot map a Program frame for the GPU.")
    }
    textures[key] = CachedTexture(surface: surface, texture: texture, lastUsed: sequence)
    residency.addAllocation(texture)
    changed = true
    return texture
  }

  /// Removes surfaces that have been idle long enough (or, with `all`, any
  /// surface) whose last GPU use has completed. Pools rotate a small fixed
  /// set, so steady state never evicts.
  private func evictIdleTextures(sequence: UInt64, all: Bool = false) -> Bool {
    let completed = event.signaledValue
    var removed = false
    let overCap = textures.count > Self.maxCachedSurfaces
    for (key, entry) in textures where entry.lastUsed <= completed &&
      (all || overCap || sequence &- entry.lastUsed > Self.idleSurfaceFrames) {
      residency.removeAllocation(entry.texture)
      textures.removeValue(forKey: key)
      removed = true
    }
    let count = textures.count
    statsLock.lock()
    statistics.cachedSurfaces = count
    statsLock.unlock()
    return removed
  }

  /// Lock held.
  private func releaseCompletedLocked() {
    if evictIdleTextures(sequence: sequence, all: true) { residency.commit() }
    pool = nil
    poolFormat = nil
  }

  /// Runs after every completion; one sweep is pending at a time.
  private func scheduleIdleSweep() {
    lock.lock()
    defer { lock.unlock() }
    scheduleIdleSweepLocked()
  }

  private func scheduleIdleSweepLocked() {
    guard !idleSweepScheduled else { return }
    idleSweepScheduled = true
    let mark = sequence
    feedbackQueue.asyncAfter(deadline: .now() + idleReleaseDelay) { [weak self] in
      self?.sweepIfIdle(since: mark)
    }
  }

  /// Releases everything completed if nothing was encoded since `mark`. While
  /// conversions continue, or work is still on the GPU, it looks again later.
  private func sweepIfIdle(since mark: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    idleSweepScheduled = false
    let idle = sequence == mark
    if idle { releaseCompletedLocked() }
    if !idle || !textures.isEmpty { scheduleIdleSweepLocked() }
  }

  private func recordFrame(milliseconds: Double) {
    statsLock.lock()
    statistics.frames &+= 1
    statistics.lastGPUMilliseconds = milliseconds
    statistics.maxGPUMilliseconds = max(statistics.maxGPUMilliseconds, milliseconds)
    statistics.totalGPUMilliseconds += milliseconds
    statsLock.unlock()
  }

  private func recordFailure() {
    statsLock.lock()
    statistics.failures &+= 1
    statsLock.unlock()
  }

  private func recordStall(output: Bool) {
    statsLock.lock()
    if output { statistics.outputStalls &+= 1 } else { statistics.gpuStalls &+= 1 }
    statistics.failures &+= 1
    statsLock.unlock()
  }

  private static func sourceCode(_ format: OSType) -> Code? {
    switch format {
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return .yuv42010
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: return .yuv4228
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return .yuv420
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: return .yuv422
    case kCVPixelFormatType_422YpCbCr10: return .v210
    default: return nil
    }
  }

  private static func destinationCode(_ format: OSType) -> Code? {
    switch format {
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return .yuv42010
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: return .yuv4228
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return .yuv420
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: return .yuv422
    case kCVPixelFormatType_422YpCbCr10: return .v210
    default: return nil
    }
  }

  // MARK: - Shader

  /// Compiled once by MTL4Compiler. Values are carried as 10-bit code values
  /// (8-bit sources scaled by 4, x422's MSB-aligned samples shifted down), so
  /// 8↔10-bit conversion is exact up to the final rounding to 8 bits.
  static let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct ProgramNormalizeParams {
    uint4 source;       // width, height, format code, full range
    uint4 destination;  // width, height, format code, 0
  };

  constant uint kYUV420 = 0;
  constant uint kYUV422 = 1;
  constant uint kYUV42010 = 3;
  constant uint kYUV4228 = 4;

  struct Taps { int index[4]; float weight[4]; int count; };

  static Taps axisTaps(int d, int srcSize, int dstSize) {
    Taps t;
    if (srcSize % dstSize == 0 && srcSize / dstSize <= 4) {
      int n = srcSize / dstSize;
      t.count = n;
      for (int k = 0; k < 4; k++) {
        t.index[k] = d * n + min(k, n - 1);
        t.weight[k] = k < n ? 1.0f / float(n) : 0.0f;
      }
    } else {
      float s = clamp((float(d) + 0.5f) * float(srcSize) / float(dstSize) - 0.5f,
        0.0f, float(srcSize - 1));
      int i0 = int(floor(s));
      int i1 = min(i0 + 1, srcSize - 1);
      float f = s - float(i0);
      t.count = 2;
      t.index[0] = i0; t.index[1] = i1; t.index[2] = i1; t.index[3] = i1;
      t.weight[0] = 1.0f - f; t.weight[1] = f; t.weight[2] = 0.0f; t.weight[3] = 0.0f;
    }
    return t;
  }

  static uint v210Luma(uint4 g, uint lane) {
    switch (lane) {
      case 0: return (g.x >> 10) & 1023;
      case 1: return g.y & 1023;
      case 2: return (g.y >> 20) & 1023;
      case 3: return (g.z >> 10) & 1023;
      case 4: return g.w & 1023;
      default: return (g.w >> 20) & 1023;
    }
  }

  static uint2 v210Chroma(uint4 g, uint pair) {
    if (pair == 0) return uint2(g.x & 1023, (g.x >> 20) & 1023);
    if (pair == 1) return uint2((g.y >> 10) & 1023, g.z & 1023);
    return uint2((g.z >> 20) & 1023, (g.w >> 10) & 1023);
  }

  static float fetchLuma(texture2d<uint, access::read> p0, constant ProgramNormalizeParams &p,
                         int x, int y) {
    float v;
    if ((p.source.z == kYUV420 || p.source.z == kYUV4228)) v = float(p0.read(uint2(x, y)).x) * 4.0f;
    else if ((p.source.z == kYUV422 || p.source.z == kYUV42010)) v = float(p0.read(uint2(x, y)).x >> 6);
    else v = float(v210Luma(p0.read(uint2(x / 6, y)), uint(x % 6)));
    if (p.source.w != 0) v = 64.0f + v * (876.0f / 1023.0f);
    return v;
  }

  static float2 fetchChroma(texture2d<uint, access::read> p0, texture2d<uint, access::read> p1,
                            constant ProgramNormalizeParams &p, int x, int y) {
    float2 c;
    if ((p.source.z == kYUV420 || p.source.z == kYUV4228)) c = float2(p1.read(uint2(x, y)).xy) * 4.0f;
    else if ((p.source.z == kYUV422 || p.source.z == kYUV42010)) c = float2(p1.read(uint2(x, y)).xy >> 6);
    else c = float2(v210Chroma(p0.read(uint2(x / 3, y)), uint(x % 3)));
    if (p.source.w != 0) c = 512.0f + (c - 512.0f) * (896.0f / 1023.0f);
    return c;
  }

  static float sampleLuma(texture2d<uint, access::read> p0, constant ProgramNormalizeParams &p,
                          int dx, int dy) {
    Taps tx = axisTaps(dx, int(p.source.x), int(p.destination.x));
    Taps ty = axisTaps(dy, int(p.source.y), int(p.destination.y));
    float sum = 0.0f;
    for (int j = 0; j < ty.count; j++) {
      for (int i = 0; i < tx.count; i++) {
        sum += tx.weight[i] * ty.weight[j] * fetchLuma(p0, p, tx.index[i], ty.index[j]);
      }
    }
    return sum;
  }

  static int2 chromaSize(uint4 g) {
    return int2((int(g.x) + 1) / 2, (g.z == kYUV420 || g.z == kYUV42010) ? (int(g.y) + 1) / 2 : int(g.y));
  }

  static float2 sampleChroma(texture2d<uint, access::read> p0, texture2d<uint, access::read> p1,
                             constant ProgramNormalizeParams &p, int dx, int dy) {
    int2 s = chromaSize(p.source);
    int2 d = chromaSize(p.destination);
    Taps tx = axisTaps(dx, s.x, d.x);
    Taps ty = axisTaps(dy, s.y, d.y);
    float2 sum = float2(0.0f);
    for (int j = 0; j < ty.count; j++) {
      for (int i = 0; i < tx.count; i++) {
        sum += tx.weight[i] * ty.weight[j] * fetchChroma(p0, p1, p, tx.index[i], ty.index[j]);
      }
    }
    return sum;
  }

  static uint quantize(float v, uint format) {
    if ((format == kYUV420 || format == kYUV4228)) return uint(clamp(floor(v * 0.25f + 0.5f), 0.0f, 255.0f));
    uint ten = uint(clamp(floor(v + 0.5f), 0.0f, 1023.0f));
    return (format == kYUV422 || format == kYUV42010) ? (ten << 6) : ten;
  }

  kernel void programNormalizeLuma(texture2d<uint, access::read> src0 [[texture(0)]],
                                   texture2d<uint, access::read> src1 [[texture(1)]],
                                   texture2d<uint, access::write> dst [[texture(2)]],
                                   constant ProgramNormalizeParams &p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.destination.x || gid.y >= p.destination.y) return;
    float v = sampleLuma(src0, p, int(gid.x), int(gid.y));
    dst.write(uint4(quantize(v, p.destination.z), 0, 0, 0), gid);
  }

  kernel void programNormalizeChroma(texture2d<uint, access::read> src0 [[texture(0)]],
                                     texture2d<uint, access::read> src1 [[texture(1)]],
                                     texture2d<uint, access::write> dst [[texture(2)]],
                                     constant ProgramNormalizeParams &p [[buffer(0)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    int2 d = chromaSize(p.destination);
    if (int(gid.x) >= d.x || int(gid.y) >= d.y) return;
    float2 c = sampleChroma(src0, src1, p, int(gid.x), int(gid.y));
    dst.write(uint4(quantize(c.x, p.destination.z), quantize(c.y, p.destination.z), 0, 0), gid);
  }

  kernel void programNormalizeV210(texture2d<uint, access::read> src0 [[texture(0)]],
                                   texture2d<uint, access::read> src1 [[texture(1)]],
                                   texture2d<uint, access::write> dst [[texture(2)]],
                                   constant ProgramNormalizeParams &p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    int width = int(p.destination.x);
    int groups = (width + 5) / 6;
    if (int(gid.x) >= groups || gid.y >= p.destination.y) return;
    int chromaWidth = (width + 1) / 2;
    uint y[6];
    for (int i = 0; i < 6; i++) {
      int x = int(gid.x) * 6 + i;
      y[i] = x < width ? quantize(sampleLuma(src0, p, x, int(gid.y)), 2) : 64;
    }
    uint2 c[3];
    for (int j = 0; j < 3; j++) {
      int x = int(gid.x) * 3 + j;
      if (x < chromaWidth) {
        float2 v = sampleChroma(src0, src1, p, x, int(gid.y));
        c[j] = uint2(quantize(v.x, 2), quantize(v.y, 2));
      } else {
        c[j] = uint2(512, 512);
      }
    }
    uint4 g;
    g.x = c[0].x | (y[0] << 10) | (c[0].y << 20);
    g.y = y[1] | (c[1].x << 10) | (y[2] << 20);
    g.z = c[1].y | (y[3] << 10) | (c[2].x << 20);
    g.w = y[4] | (c[2].y << 10) | (y[5] << 20);
    dst.write(g, gid);
  }
  """
}

/// Builds the normalizer (one MTL4Compiler compile, tens of milliseconds)
/// in the background, never on the frame path. `warm()` starts it when
/// Program mode is on or a Program bridge is prepared, long before a camera
/// client connects; until it is ready, a frame that needs conversion is a
/// counted, reported error rather than a compile under the route lock.
final class ProgramNormalizerLoader: @unchecked Sendable {
  private let lock = NSLock()
  private var value: ProgramNormalizer?
  private var started = false

  func warm() {
    let start = lock.withLock { () -> Bool in
      guard !started else { return false }
      started = true
      return true
    }
    guard start else { return }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let created = try? ProgramNormalizer()
      lock.withLock { value = created }
    }
  }

  /// Nil until built; never compiles.
  var loadedNormalizer: ProgramNormalizer? { lock.withLock { value } }
}
