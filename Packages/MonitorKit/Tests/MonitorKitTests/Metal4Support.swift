import Metal
import Synchronization
import XCTest

@testable import MonitorKit

/// A host's Metal 4 side for tests: one queue carrying the shared engine's work,
/// with the engine's residency set and a host set (frames, targets) attached,
/// submissions numbered from 1 and completions tracked from feedback handlers.
/// Committing and waiting happen only here, in the test host.
final class TestMTL4: @unchecked Sendable {
  static let shared = Result { try TestMTL4() }

  let gpu: TestGPU
  let queue: MTL4CommandQueue
  /// Host-owned textures: frames and targets.
  let host: MTLResidencySet
  private let state = Mutex<(next: UInt64, completed: UInt64, done: Set<UInt64>)>((1, 0, []))
  private let freeLock = NSLock()
  private var freeAllocators: [MTL4CommandAllocator] = []

  init() throws {
    gpu = try requireGPU()
    guard gpu.device.supportsFamily(.metal4), let queue = gpu.device.makeMTL4CommandQueue() else {
      throw XCTSkip("No Metal 4 device")
    }
    self.queue = queue
    let d = MTLResidencySetDescriptor()
    d.label = "MonitorKit tests host"
    host = try gpu.device.makeResidencySet(descriptor: d)
    queue.addResidencySet(gpu.engine.residency.set)
    queue.addResidencySet(host)
  }

  /// Makes host textures resident (a host does this once per texture, not per frame).
  func resident(_ textures: MTLTexture?...) {
    for t in textures { if let t { host.addAllocation(t) } }
    host.commit()
  }

  func resident(_ frame: MonitorFrame) {
    frame.addResidency(to: host)
    host.commit()
  }

  /// One command buffer being encoded.
  struct Pending {
    let commandBuffer: MTL4CommandBuffer
    let allocator: MTL4CommandAllocator
    let submission: MonitorSubmission
  }

  /// Starts a submission. `uniforms` routes the library's uniforms through a host allocator.
  func begin(uniforms: (any MonitorUniformAllocator)? = nil) -> Pending {
    let allocator = freeLock.withLock { freeAllocators.popLast() } ?? gpu.device.makeCommandAllocator()!
    let cb = gpu.device.makeCommandBuffer()!
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
    nonisolated(unsafe) let unsafeAllocator = p.allocator
    options.addFeedbackHandler { [self] feedback in
      let ms = feedback.error == nil ? (feedback.gpuEndTime - feedback.gpuStartTime) * 1000 : nil
      if let error = feedback.error { print("MTL4 feedback error: \(error)") }
      // Completions can arrive out of order: completed is the highest contiguous index.
      state.withLock { s in
        s.done.insert(index)
        while s.done.remove(s.completed + 1) != nil { s.completed += 1 }
      }
      unsafeAllocator.reset()
      freeLock.withLock { freeAllocators.append(unsafeAllocator) }
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

  /// A shared target the host makes resident.
  func target(_ width: Int, _ height: Int, format: MTLPixelFormat = .rgba32Float, usage: MTLTextureUsage = [.renderTarget, .shaderRead])
    -> MTLTexture
  {
    let t = gpu.texture(format, width, height, usage: usage)
    resident(t)
    return t
  }

  /// A frame whose textures the host has made resident.
  func frame(_ s: SyntheticFrame, signal: SignalDescription) throws -> MonitorFrame {
    let f = try s.frame(gpu, signal: signal)
    resident(f)
    return f
  }
}

func requireMTL4() throws -> TestMTL4 {
  _ = try requireGPU()
  return try TestMTL4.shared.get()
}

/// The raw bytes of a shared texture, for bit-exact comparisons in any format.
func rawBytes(_ t: MTLTexture) -> [UInt8] {
  let bytesPerPixel: Int
  switch t.pixelFormat {
  case .rgba32Float: bytesPerPixel = 16
  case .rgba16Float: bytesPerPixel = 8
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

/// A host bump allocator over one shared buffer, the shape of an encode context's uniforms.
final class TestUniformAllocator: MonitorUniformAllocator {
  let buffer: MTLBuffer
  private(set) var offset = 0
  private(set) var allocations = 0

  init(_ device: MTLDevice, residency: MTLResidencySet, length: Int = 64 * 1024) {
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
