import CoreVideo
import Foundation
import IOSurface
import Metal

/// Converts the capture original (packed v210) into the encoder's native
/// 10-bit 4:2:2 biplanar layout ('x422') on the GPU.
///
/// Measured on Apple Silicon (M4 Max, macOS 27): the hardware ProRes and HEVC
/// encoders do not list v210 among their native inputs. Handing them v210
/// makes VideoToolbox run `vt_Copy_v210_x422_internal` on the CPU for every
/// frame (about 4 ms of CPU per 4K frame; VTPixelTransferSession is also a
/// CPU path at about 2.3 ms). This kernel writes the identical x422 bits
/// (verified against VideoToolbox's own conversion) in about 0.15 ms of GPU
/// time, straight from the capture IOSurface into an IOSurface from the
/// encoder's pool. No CPU touches a pixel.
///
/// The conversion is a bit-exact repack: each 10-bit code value moves into
/// the top 10 bits of a 16-bit sample. Nothing is scaled, filtered or color
/// converted.
///
/// Metal 4, like `ProgramNormalizer`: one `MTL4CommandQueue`; a ring of
/// `MTL4CommandAllocator` + reusable `MTL4CommandBuffer` slots with their own
/// `MTL4ArgumentTable` and parameter buffer; one `MTLResidencySet` holding
/// every texture and parameter buffer; the pipeline built once per process by
/// `MTL4Compiler` from the source below (the app ships Metal source, not a
/// metallib: the recording module also builds standalone); completion through
/// commit feedback, which also reports GPU time; and a `MTLSharedEvent` that
/// gates allocator reuse.
///
/// Textures are cached by IOSurface ID. The encoder pool and the capture
/// driver both recycle a small fixed set of surfaces, so steady state makes
/// no texture at all. An entry retains only the IOSurface (never its
/// CVPixelBuffer, which would pin the pool's buffer), so its ID cannot be
/// reused while cached, and is evicted once idle and its last GPU use is done.
/// When the last recorder using the converter finishes, the whole cache is
/// released (after its GPU work completes), so no surface outlives its take.
final class RecordingPixelConverter: @unchecked Sendable {
  enum ConversionError: Error, LocalizedError {
    case metalUnavailable(String)
    case unsupportedSource(String)
    case gpuFailure(String)

    var errorDescription: String? {
      switch self {
      case let .metalUnavailable(message): return "The recording GPU converter is unavailable: \(message)"
      case let .unsupportedSource(message): return "The recording GPU converter cannot read this frame: \(message)"
      case let .gpuFailure(message): return "The recording GPU conversion failed: \(message)"
      }
    }
  }

  /// The encoder-native layout this converter produces.
  static let outputPixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
  /// Conversions in flight across every recorder. Each caller waits for its
  /// own, so this only matters with several feeds recording at once.
  static let slotCount = 8
  /// A cached surface idle this many conversions (about 2 s for four 59.94
  /// feeds) is released; the pools in use rotate far faster than that.
  static let idleConversions: UInt64 = 480
  static let maxCachedTextures = 384
  private let cacheByteLimit: Int
  private let cacheIdleAge: TimeInterval
  private let monotonicNow: () -> TimeInterval
  private let allocationBudget: GPUAllocationBudget
#if ULTRACAM_TEST_SUPPORT
  var cachedAllocationBytesForTesting: Int { lock.withLock { allocationBudget.snapshot().bytes } }
  func evictExpiredCacheForTesting() {
    lock.withLock { if evictIdleTextures(sequence: sequence) { residency.commit() } }
  }
#endif
  private static let gpuTimeout: TimeInterval = 2

  private struct TextureKey: Hashable {
    let surface: IOSurfaceID
    let plane: Int
    let format: UInt
  }

  private final class CachedTexture {
    let surface: IOSurfaceRef
    let texture: MTLTexture
    var lastUsed: UInt64
    var lastUsedTime: TimeInterval
    let allocationLease: GPUAllocationBudget.Lease
    init(surface: IOSurfaceRef, texture: MTLTexture, lastUsed: UInt64,
      time: TimeInterval, lease: GPUAllocationBudget.Lease) {
      self.surface = surface
      self.texture = texture
      self.lastUsed = lastUsed
      self.lastUsedTime = time
      self.allocationLease = lease
    }
  }

  private final class Slot {
    let allocator: MTL4CommandAllocator
    let commandBuffer: MTL4CommandBuffer
    let table: MTL4ArgumentTable
    let parameters: MTLBuffer
    var lastSequence: UInt64 = 0
    init(allocator: MTL4CommandAllocator, commandBuffer: MTL4CommandBuffer, table: MTL4ArgumentTable,
         parameters: MTLBuffer) {
      self.allocator = allocator
      self.commandBuffer = commandBuffer
      self.table = table
      self.parameters = parameters
    }
  }

  /// One conversion's outcome, filled by the commit feedback. It also keeps
  /// both frames alive until the GPU is done with them, even if the caller
  /// stopped waiting. Nothing reads their pixels on the CPU.
  private final class Completion: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var error: Error?
    var gpuMilliseconds = 0.0
    var buffers: [CVPixelBuffer]
    init(_ buffers: [CVPixelBuffer]) { self.buffers = buffers }
  }

  private let device: MTLDevice
  private let queue: MTL4CommandQueue
  private let residency: MTLResidencySet
  private let event: MTLSharedEvent
  private let pipeline: MTLComputePipelineState
  private let threadgroup: MTLSize
  private let slots: [Slot]
  /// Guards the ring, the cache and the residency set while one conversion
  /// is encoded (tens of microseconds). Never held while waiting for the GPU.
  private let lock = NSLock()
  private var sequence: UInt64 = 0
  private var textures: [TextureKey: CachedTexture] = [:]
  /// Recorders currently converting through this instance.
  private var users = 0
  /// A purge is waiting for in-flight GPU work (at most one is scheduled).
  private var purgeScheduled = false
  private var ageSweepScheduled = false
  /// How long a purge waits for GPU work still in flight before it retries.
  static let purgeRetryInterval: TimeInterval = 0.25

  /// One converter per process: the kernel compiles once and every recorder
  /// reuses the warm pipeline. Swift initializes the static exactly once.
  private static let sharedResult: Result<RecordingPixelConverter, ConversionError> = {
    do { return .success(try RecordingPixelConverter()) }
    catch let error as ConversionError { return .failure(error) }
    catch { return .failure(.metalUnavailable(error.localizedDescription)) }
  }()

  static func shared() throws -> RecordingPixelConverter { try sharedResult.get() }

  /// Compiles the kernel in the background (about 200 ms cold) so the first
  /// take does not wait for it.
  static func prewarm() {
    DispatchQueue.global(qos: .utility).async { _ = try? shared() }
  }

  init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), cacheMaximumBytes: Int = 2 * 1024 * 1024 * 1024,
    cacheIdleAge: TimeInterval = 2, monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
    guard cacheMaximumBytes > 0, cacheIdleAge.isFinite, cacheIdleAge > 0 else {
      throw ConversionError.metalUnavailable("Invalid recording GPU cache policy.")
    }
    self.cacheByteLimit = cacheMaximumBytes
    self.cacheIdleAge = cacheIdleAge
    self.monotonicNow = monotonicNow
    allocationBudget = GPUAllocationBudget(policy: try GPUAllocationBudgetPolicy(maximumBytes: cacheMaximumBytes, minimumSlots: 1))
    guard let device else { throw ConversionError.metalUnavailable("No Metal device.") }
    self.device = device
    do {
      let queueDescriptor = MTL4CommandQueueDescriptor()
      queueDescriptor.label = "Ultracam recording v210 to x422"
      // Feedback runs on Metal's own queue (see ProgramNormalizer).
      queue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
      let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
      let libraryDescriptor = MTL4LibraryDescriptor()
      libraryDescriptor.source = Self.shaderSource
      libraryDescriptor.name = "RecordingPixelConverter"
      let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
      let function = MTL4LibraryFunctionDescriptor()
      function.name = "ultracamRecordingV210ToX422"
      function.library = library
      let pipelineDescriptor = MTL4ComputePipelineDescriptor()
      pipelineDescriptor.computeFunctionDescriptor = function
      pipeline = try compiler.makeComputePipelineState(descriptor: pipelineDescriptor)
      let residencyDescriptor = MTLResidencySetDescriptor()
      residencyDescriptor.label = "Ultracam recording converter"
      residencyDescriptor.initialCapacity = 64
      residency = try device.makeResidencySet(descriptor: residencyDescriptor)
      guard let event = device.makeSharedEvent() else {
        throw ConversionError.metalUnavailable("No Metal shared event.")
      }
      self.event = event
      let tableDescriptor = MTL4ArgumentTableDescriptor()
      tableDescriptor.maxTextureBindCount = 3
      tableDescriptor.maxBufferBindCount = 1
      var slots: [Slot] = []
      for _ in 0..<Self.slotCount {
        guard let allocator = device.makeCommandAllocator(),
          let commandBuffer = device.makeCommandBuffer(),
          let parameters = device.makeBuffer(length: 16, options: .storageModeShared) else {
          throw ConversionError.metalUnavailable("Metal could not allocate command resources.")
        }
        let table = try device.makeArgumentTable(descriptor: tableDescriptor)
        residency.addAllocation(parameters)
        slots.append(Slot(allocator: allocator, commandBuffer: commandBuffer, table: table, parameters: parameters))
      }
      self.slots = slots
    } catch let error as ConversionError {
      throw error
    } catch {
      throw ConversionError.metalUnavailable(error.localizedDescription)
    }
    let width = min(32, pipeline.threadExecutionWidth)
    threadgroup = MTLSize(width: width,
      height: max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / width)), depth: 1)
    residency.commit()
    queue.addResidencySet(residency)
  }

  deinit {
    // Allocators and argument tables must outlive the GPU work that uses them.
    if sequence > 0 { _ = event.wait(untilSignaledValue: sequence, timeoutMS: 2_000) }
    queue.removeResidencySet(residency)
  }

  /// Repacks `source` (v210, IOSurface-backed) into `destination` (x422,
  /// IOSurface-backed) and returns once the GPU has written it. Call on the
  /// recorder's encoder queue, never the capture thread. Returns the GPU
  /// execution time in ms.
  @discardableResult
  func convert(_ source: CVPixelBuffer, into destination: CVPixelBuffer, sourceRange: Colorimetry.Range = .video) throws -> Double {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_422YpCbCr10 else {
      throw ConversionError.unsupportedSource("The source is not v210.")
    }
    guard CVPixelBufferGetPixelFormatType(destination) == Self.outputPixelFormat,
      CVPixelBufferGetPlaneCount(destination) == 2 else {
      throw ConversionError.unsupportedSource("The destination is not x422.")
    }
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    guard width > 0, height > 0, CVPixelBufferGetWidth(destination) == width,
      CVPixelBufferGetHeight(destination) == height else {
      throw ConversionError.unsupportedSource("Source and destination sizes differ.")
    }
    guard let sourceSurface = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue(),
      let destinationSurface = CVPixelBufferGetIOSurface(destination)?.takeUnretainedValue() else {
      throw ConversionError.unsupportedSource("A buffer is not IOSurface-backed.")
    }
    let sourceRowBytes = IOSurfaceGetBytesPerRow(sourceSurface)
    let groups = (width + 5) / 6
    guard sourceRowBytes % 16 == 0, sourceRowBytes >= groups * 16 else {
      throw ConversionError.unsupportedSource("The v210 row stride \(sourceRowBytes) is invalid.")
    }
    let completion = Completion([source, destination])
    try encode(completion: completion, width: width, height: height, groups: groups,
      source: (sourceSurface, sourceRowBytes / 4), destination: destinationSurface, fullRange: sourceRange == .full)
    guard completion.done.wait(timeout: .now() + Self.gpuTimeout) == .success else {
      throw ConversionError.gpuFailure("The GPU did not finish the repack within 2 seconds.")
    }
    if let error = completion.error { throw ConversionError.gpuFailure(error.localizedDescription) }
    return completion.gpuMilliseconds
  }

  /// Encodes and commits one conversion under `lock`.
  private func encode(completion: Completion, width: Int, height: Int, groups: Int,
    source: (surface: IOSurfaceRef, words: Int), destination: IOSurfaceRef, fullRange: Bool) throws {
    lock.lock()
    defer { lock.unlock() }
    // Committed to `self.sequence` only once the work is on the GPU, so a
    // failed encode never leaves the shared event waiting for a value.
    let sequence = self.sequence &+ 1
    let slot = slots[Int(sequence % UInt64(slots.count))]
    if slot.lastSequence > 0, event.signaledValue < slot.lastSequence {
      // Every slot is busy: wait for this one's previous work, never skip.
      guard event.wait(untilSignaledValue: slot.lastSequence, timeoutMS: 2_000) else {
        throw ConversionError.gpuFailure("The GPU stalled for more than 2 seconds.")
      }
    }
    // Mapping/budget/encoder failures must not leave entries tagged with a
    // sequence that will never be signalled. Keep previous completion pins.
    let previous = textures.mapValues { ($0.lastUsed, $0.lastUsedTime) }
    var committed = false
    defer {
      if !committed {
        for (key, entry) in textures where entry.lastUsed == sequence {
          if let old = previous[key] {
            entry.lastUsed = old.0; entry.lastUsedTime = old.1
          } else {
            residency.removeAllocation(entry.texture)
            textures.removeValue(forKey: key)
          }
        }
        residency.commit()
      }
    }
    var residencyChanged = false
    let sourceTexture = try texture(source.surface, plane: 0, format: .r32Uint, width: source.words,
      height: height, usage: .shaderRead, sequence: sequence, changed: &residencyChanged)
    let lumaTexture = try texture(destination, plane: 0, format: .r16Uint, width: width,
      height: height, usage: .shaderWrite, sequence: sequence, changed: &residencyChanged)
    let chromaTexture = try texture(destination, plane: 1, format: .rg16Uint, width: (width + 1) / 2,
      height: height, usage: .shaderWrite, sequence: sequence, changed: &residencyChanged)
    residencyChanged = evictIdleTextures(sequence: sequence) || residencyChanged
    if residencyChanged { residency.commit() }

    var pixelWidth = UInt32(width)
    slot.parameters.contents().copyMemory(from: &pixelWidth, byteCount: MemoryLayout<UInt32>.size)
    var rangeFlag: UInt32 = fullRange ? 1 : 0
    slot.parameters.contents().advanced(by: 4).copyMemory(from: &rangeFlag, byteCount: 4)
    slot.table.setTexture(sourceTexture.gpuResourceID, index: 0)
    slot.table.setTexture(lumaTexture.gpuResourceID, index: 1)
    slot.table.setTexture(chromaTexture.gpuResourceID, index: 2)
    slot.table.setAddress(slot.parameters.gpuAddress, index: 0)

    slot.allocator.reset()
    let command = slot.commandBuffer
    command.beginCommandBuffer(allocator: slot.allocator)
    command.label = "Recording v210 to x422"
    guard let encoder = command.makeComputeCommandEncoder() else {
      command.endCommandBuffer()
      throw ConversionError.gpuFailure("Metal could not create a compute encoder.")
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setArgumentTable(slot.table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: groups, height: height, depth: 1),
      threadsPerThreadgroup: threadgroup)
    encoder.endEncoding()
    command.endCommandBuffer()

    let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in
      completion.error = feedback.error
      completion.gpuMilliseconds = max(0, (feedback.gpuEndTime - feedback.gpuStartTime) * 1_000)
      completion.buffers.removeAll()
      completion.done.signal()
    }
    queue.commit([command], options: options)
    committed = true
    queue.signalEvent(event, value: sequence)
    scheduleAgeSweepLocked()
    slot.lastSequence = sequence
    self.sequence = sequence
  }

  /// Under `lock`. Wrapping an IOSurface maps, never copies.
  private func texture(_ surface: IOSurfaceRef, plane: Int, format: MTLPixelFormat, width: Int, height: Int,
    usage: MTLTextureUsage, sequence: UInt64, changed: inout Bool) throws -> MTLTexture {
    let key = TextureKey(surface: IOSurfaceGetID(surface), plane: plane, format: format.rawValue)
    if let cached = textures[key], cached.surface === surface,
      cached.texture.width == width, cached.texture.height == height {
      cached.lastUsed = sequence
      cached.lastUsedTime = monotonicNow()
      return cached.texture
    }
    if let stale = textures.removeValue(forKey: key) {
      residency.removeAllocation(stale.texture)
      changed = true
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
      width: width, height: height, mipmapped: false)
    descriptor.usage = usage
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane) else {
      throw ConversionError.unsupportedSource("Metal could not wrap the IOSurface.")
    }
    // Every texture view of one IOSurface shares the same allocation charge.
    // Actual IOSurface size includes all plane padding and allocator overhead.
    let bytes = IOSurfaceGetAllocSize(surface)
    let lease: GPUAllocationBudget.Lease
    do {
      lease = try allocationBudget.acquire(backingID: UInt64(IOSurfaceGetID(surface)), bytes: bytes,
        generation: 0, owner: surface)
    } catch {
      // Pressure can evict completed cache entries, never pending GPU work.
      _ = evictIdleTextures(sequence: sequence, pressure: true)
      lease = try allocationBudget.acquire(backingID: UInt64(IOSurfaceGetID(surface)), bytes: bytes,
        generation: 0, owner: surface)
    }
    textures[key] = CachedTexture(surface: surface, texture: texture, lastUsed: sequence,
      time: monotonicNow(), lease: lease)
    residency.addAllocation(texture)
    changed = true
    return texture
  }

  /// Under `lock`: drops surfaces idle long enough whose last GPU use has
  /// completed.
  private func evictIdleTextures(sequence: UInt64, pressure: Bool = false) -> Bool {
    let completed = event.signaledValue
    let now = monotonicNow()
    var removed = false
    for (key, entry) in textures where entry.lastUsed <= completed &&
      (pressure || (now >= entry.lastUsedTime && now - entry.lastUsedTime >= cacheIdleAge)) {
      residency.removeAllocation(entry.texture)
      textures.removeValue(forKey: key)
      removed = true
    }
    return removed
  }

  /// A paused source still ages out completed cached storage. One lightweight
  /// timer is pending per converter, independent of frame rate and slot count.
  private func scheduleAgeSweepLocked() {
    guard !ageSweepScheduled, !textures.isEmpty else { return }
    ageSweepScheduled = true
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cacheIdleAge) { [weak self] in
      guard let self else { return }
      self.lock.withLock {
        self.ageSweepScheduled = false
        if self.evictIdleTextures(sequence: self.sequence) { self.residency.commit() }
        self.scheduleAgeSweepLocked()
      }
    }
  }

  /// A recorder starts converting through this instance.
  func beginUse() {
    lock.withLock { users += 1 }
  }

  /// A recorder finished. Once no recorder is left, every cached surface
  /// whose GPU work is done is released at once (the x422 pool surfaces and
  /// capture surfaces of a 4K take are about 0.5 GB), and the rest as soon
  /// as their work completes. While other recorders still convert, the idle
  /// eviction in `encode` releases this take's surfaces as usual.
  func endUse() {
    lock.withLock { users = max(0, users - 1) }
    purgeWhenIdle()
  }

  /// `attempt` bounds the retries to about the GPU timeout's length: work
  /// that has not completed by then has failed, and the next take's idle
  /// eviction releases what is left.
  private func purgeWhenIdle(attempt: Int = 0) {
    let retry = lock.withLock { () -> Bool in
      guard users == 0 else { return false }
      if purgeCompletedLocked() { residency.commit() }
      // Entries still in GPU use are retried shortly; the cache is otherwise empty.
      guard !textures.isEmpty, !purgeScheduled,
        Double(attempt) * Self.purgeRetryInterval < Self.gpuTimeout * 2 else { return false }
      purgeScheduled = true
      return true
    }
    guard retry else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.purgeRetryInterval) { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.purgeScheduled = false }
      self.purgeWhenIdle(attempt: attempt + 1)
    }
  }

  /// Under `lock`: drops every surface whose last GPU use has completed.
  /// Returns whether the residency set changed.
  private func purgeCompletedLocked() -> Bool {
    let completed = event.signaledValue
    var removed = false
    for (key, entry) in textures where entry.lastUsed <= completed {
      residency.removeAllocation(entry.texture)
      textures.removeValue(forKey: key)
      removed = true
    }
    return removed
  }

  /// Surfaces currently wrapped as textures. For tests and diagnostics.
  var cachedTextureCount: Int { lock.withLock { textures.count } }

  // v210: each 16-byte group holds six pixels as four little-endian words of
  // three 10-bit fields: [Cb0 Y0 Cr0] [Y1 Cb1 Y2] [Cr1 Y3 Cb2] [Y4 Cr2 Y5].
  // x422: plane 0 is 16-bit Y, plane 1 is interleaved 16-bit Cb/Cr, each
  // code value in the top 10 bits.
  private static let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void ultracamRecordingV210ToX422(
    texture2d<uint, access::read> source [[texture(0)]],
    texture2d<uint, access::write> luma [[texture(1)]],
    texture2d<uint, access::write> chroma [[texture(2)]],
    constant uint2 &parameters [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    const uint width = parameters.x;
    const uint x0 = gid.x * 6;
    if (x0 >= width || gid.y >= luma.get_height() || gid.x * 4 + 3 >= source.get_width()) return;
    const uint w0 = source.read(uint2(gid.x * 4 + 0, gid.y)).x;
    const uint w1 = source.read(uint2(gid.x * 4 + 1, gid.y)).x;
    const uint w2 = source.read(uint2(gid.x * 4 + 2, gid.y)).x;
    const uint w3 = source.read(uint2(gid.x * 4 + 3, gid.y)).x;
    const uint ys[6] = { (w0 >> 10) & 0x3ff, w1 & 0x3ff, (w1 >> 20) & 0x3ff,
      (w2 >> 10) & 0x3ff, w3 & 0x3ff, (w3 >> 20) & 0x3ff };
    const uint cbs[3] = { w0 & 0x3ff, (w1 >> 10) & 0x3ff, (w2 >> 20) & 0x3ff };
    const uint crs[3] = { (w0 >> 20) & 0x3ff, w2 & 0x3ff, (w3 >> 10) & 0x3ff };
    for (uint i = 0; i < 6; i++) {
      if (x0 + i < width) {
        const uint y = parameters.y != 0 ? 64u + (ys[i] * 876u + 511u) / 1023u : ys[i];
        luma.write(uint4(y << 6, 0, 0, 0), uint2(x0 + i, gid.y));
      }
    }
    for (uint i = 0; i < 3; i++) {
      const uint cx = gid.x * 3 + i;
      if (cx < chroma.get_width()) {
        const uint cb = parameters.y != 0 ? 64u + (cbs[i] * 896u + 511u) / 1023u : cbs[i];
        const uint cr = parameters.y != 0 ? 64u + (crs[i] * 896u + 511u) / 1023u : crs[i];
        chroma.write(uint4(cb << 6, cr << 6, 0, 0), uint2(cx, gid.y));
      }
    }
  }
  """
}
