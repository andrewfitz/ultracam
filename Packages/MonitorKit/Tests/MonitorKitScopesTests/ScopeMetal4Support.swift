import Metal
import MonitorKit
import MonitorKitCore
import Synchronization
import XCTest

@testable import MonitorKitScopes

/// A host's Metal 4 side for the scope tests: one queue with every test
/// engine's residency set and a host set (frames, targets) attached, submissions
/// numbered from 1 and completions tracked from feedback handlers. Committing and
/// waiting happen only here, in the test host.
final class ScopeMTL4: @unchecked Sendable {
  static let shared = Result { try ScopeMTL4() }

  let device: MTLDevice
  let queue: MTL4CommandQueue
  /// Host-owned resources: frames, targets, readback buffers.
  let host: MTLResidencySet
  private let state = Mutex<(next: UInt64, completed: UInt64, done: Set<UInt64>)>((1, 0, []))
  private let attached = Mutex<Set<ObjectIdentifier>>([])
  private let freeLock = NSLock()
  private var freeAllocators: [MTL4CommandAllocator] = []

  init() throws {
    let (device, _, _) = try GPU.require()
    guard device.supportsFamily(.metal4), let queue = device.makeMTL4CommandQueue() else {
      throw XCTSkip("No Metal 4 device")
    }
    self.device = device
    self.queue = queue
    let d = MTLResidencySetDescriptor()
    d.label = "MonitorKit scope tests host"
    host = try device.makeResidencySet(descriptor: d)
    queue.addResidencySet(host)
    for engine in [GPU.engine, GPU.synchronousEngine, GPU.generalEngine] { if let engine { attach(engine) } }
  }

  /// Attaches an engine's residency set once (a host does this at setup).
  func attach(_ engine: ScopeEngine) {
    let set = engine.residency.set
    guard attached.withLock({ $0.insert(ObjectIdentifier(set)).inserted }) else { return }
    queue.addResidencySet(set)
  }

  func resident(_ allocations: (any MTLAllocation)?...) {
    for a in allocations { if let a { host.addAllocation(a) } }
    host.commit()
  }

  func resident(_ frame: MonitorFrame) {
    frame.addResidency(to: host)
    host.commit()
  }

  struct Pending {
    let commandBuffer: MTL4CommandBuffer
    let allocator: MTL4CommandAllocator
    let submission: MonitorSubmission
  }

  func begin(uniforms: (any MonitorUniformAllocator)? = nil) -> Pending {
    let allocator = freeLock.withLock { freeAllocators.popLast() } ?? device.makeCommandAllocator()!
    let cb = device.makeCommandBuffer()!
    cb.beginCommandBuffer(allocator: allocator)
    let (index, completed) = state.withLock { s -> (UInt64, UInt64) in
      defer { s.next += 1 }
      return (s.next, s.completed)
    }
    return Pending(
      commandBuffer: cb, allocator: allocator,
      submission: MonitorSubmission(commandBuffer: cb, index: index, completedIndex: completed, uniforms: uniforms))
  }

  /// Commits without waiting; `done` runs with the GPU time in ms (nil on error).
  func commit(_ p: Pending, done: (@Sendable (Double?) -> Void)? = nil) {
    p.commandBuffer.endCommandBuffer()
    let options = MTL4CommitOptions()
    let index = p.submission.index
    nonisolated(unsafe) let allocator = p.allocator
    options.addFeedbackHandler { [self] feedback in
      let ms = feedback.error == nil ? (feedback.gpuEndTime - feedback.gpuStartTime) * 1000 : nil
      if let error = feedback.error { print("MTL4 feedback error: \(error)") }
      state.withLock { s in
        s.done.insert(index)
        while s.done.remove(s.completed + 1) != nil { s.completed += 1 }
      }
      allocator.reset()
      freeLock.withLock { freeAllocators.append(allocator) }
      done?(ms)
    }
    queue.commit([p.commandBuffer], options: options)
  }

  /// Encodes one submission, commits it and waits; returns its GPU time in ms.
  @discardableResult
  func run(uniforms: (any MonitorUniformAllocator)? = nil, _ body: (MonitorSubmission) throws -> Void) throws -> Double {
    let p = begin(uniforms: uniforms)
    try body(p.submission)
    let semaphore = DispatchSemaphore(value: 0)
    let result = Mutex<Double?>(nil)
    commit(p) { ms in
      result.withLock { $0 = ms }
      semaphore.signal()
    }
    semaphore.wait()
    let ms = result.withLock { $0 }
    XCTAssertNotNil(ms, "Metal 4 submission failed")
    return ms ?? .nan
  }

  /// Waits until every submission so far has completed.
  func drain() {
    let last = state.withLock { $0.next - 1 }
    while state.withLock({ $0.completed }) < last { usleep(200) }
  }

  var completedIndex: UInt64 { state.withLock { $0.completed } }

  /// A shared texture the host makes resident.
  func target(
    _ width: Int, _ height: Int, format: MTLPixelFormat = .rgba32Float,
    usage: MTLTextureUsage = [.renderTarget, .shaderRead], sampleCount: Int = 1
  ) throws -> MTLTexture {
    let t = try makeTexture(device, format, width, height, usage: usage, sampleCount: sampleCount)
    resident(t)
    return t
  }
}

func requireScopeMTL4() throws -> ScopeMTL4 {
  _ = try GPU.require()
  return try ScopeMTL4.shared.get()
}

/// Metal's debug layer allocates inside its own calls, so allocation counts mean
/// nothing under `MTL_DEBUG_LAYER`.
func skipUnderTheDebugLayer() throws {
  if ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"].map({ $0 != "0" }) ?? false {
    throw XCTSkip("the Metal debug layer allocates inside Metal calls")
  }
}

/// Timing budgets mean nothing under Metal's API or shader validation, which
/// slows encoding and every shader several times; the benchmark classes skip.
func skipTimingUnderValidation() throws {
  let env = ProcessInfo.processInfo.environment
  for name in ["MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"] where env[name].map({ $0 != "0" }) ?? false {
    throw XCTSkip("\(name) is set: GPU and CPU timings are not representative")
  }
}

/// A timing measured again while it misses its budget, `rounds` times at most,
/// as the picture benchmarks do. The GPU and the cores are shared with other
/// processes during a full test run, so a round that loses to contention is
/// measured again; code that meets the budget cannot lose every round. The
/// caller asserts its budget on the result: the first passing round, or the
/// last one. Each round is reported with `label` for the log.
func remeasured<T>(
  _ label: String, rounds: Int = 3, _ measure: () throws -> T, until passes: (T) -> Bool
) rethrows -> T {
  var result = try measure()
  var round = 1
  while round < rounds && !passes(result) {
    print("BENCH \(label): round \(round) missed its budget (\(result)); measuring again")
    result = try measure()
    round += 1
  }
  return result
}

/// A shared (or, multisampled, private) texture for both paths' targets.
func makeTexture(
  _ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int,
  usage: MTLTextureUsage = [.renderTarget, .shaderRead], sampleCount: Int = 1
) throws -> MTLTexture {
  let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
  d.usage = usage
  if sampleCount > 1 {
    d.textureType = .type2DMultisample
    d.sampleCount = sampleCount
    d.storageMode = .private
  } else {
    d.storageMode = .shared
  }
  return try XCTUnwrap(device.makeTexture(descriptor: d))
}

/// The raw bytes of a shared texture, for bit-exact comparisons in any format.
func rawBytes(_ t: MTLTexture) -> [UInt8] {
  let bytesPerPixel: Int
  switch t.pixelFormat {
  case .rgba32Float: bytesPerPixel = 16
  case .rgba16Float, .rgba16Unorm: bytesPerPixel = 8
  case .r16Unorm: bytesPerPixel = 2
  case .r8Unorm: bytesPerPixel = 1
  default: bytesPerPixel = 4
  }
  var bytes = [UInt8](repeating: 0, count: t.width * t.height * bytesPerPixel)
  bytes.withUnsafeMutableBytes {
    t.getBytes(
      $0.baseAddress!, bytesPerRow: t.width * bytesPerPixel, from: MTLRegionMake2D(0, 0, t.width, t.height),
      mipmapLevel: 0)
  }
  return bytes
}

/// A private texture's bytes, copied out on the classic queue (test-only readback).
func privateBytes(_ t: MTLTexture) throws -> [UInt8] {
  let (device, _, _) = try GPU.require()
  let copy = try makeTexture(device, t.pixelFormat, t.width, t.height, usage: .shaderRead)
  try GPU.run { cb in
    let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
    blit.copy(from: t, to: copy)
    blit.endEncoding()
  }
  return rawBytes(copy)
}

/// rgba32Float pixels.
func floatPixels(_ t: MTLTexture) -> [SIMD4<Float>] {
  var out = [SIMD4<Float>](repeating: .zero, count: t.width * t.height)
  out.withUnsafeMutableBytes {
    t.getBytes($0.baseAddress!, bytesPerRow: t.width * 16, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
  }
  return out
}

/// Every statistics word of both slots, for exact comparisons.
func statisticsWords(_ a: ScopeAccumulator) -> [UInt32] {
  let p = a.statisticsBuffer.contents().bindMemory(to: UInt32.self, capacity: 2 * ScopeStatisticsWord.slotWords)
  return Array(UnsafeBufferPointer(start: p, count: 2 * ScopeStatisticsWord.slotWords))
}

/// A host bump allocator over one shared buffer, the shape of an encode context's uniforms.
final class ScopeUniformAllocator: MonitorUniformAllocator {
  let buffer: MTLBuffer
  private(set) var offset = 0
  private(set) var allocations = 0

  init(_ device: MTLDevice, residency: MTLResidencySet, length: Int = 256 * 1024) {
    buffer = device.makeBuffer(length: length, options: .storageModeShared)!
    residency.addAllocation(buffer)
    residency.commit()
  }

  func reset() { offset = 0 }

  func allocateUniforms(length: Int) -> MonitorUniformAllocation {
    precondition(offset + length <= buffer.length, "test allocator exhausted")
    let a = MonitorUniformAllocation(contents: buffer.contents() + offset, gpuAddress: buffer.gpuAddress + UInt64(offset))
    offset += (length + 255) / 256 * 256
    allocations += 1
    return a
  }
}
