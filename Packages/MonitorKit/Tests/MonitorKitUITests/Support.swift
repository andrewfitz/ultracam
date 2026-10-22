import Darwin
import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

/// One device, queue and engine for every test (pipelines built synchronously,
/// so the first draw is the specialized one).
final class UIGPU: @unchecked Sendable {
  static let shared = Result { try UIGPU() }

  let device: MTLDevice
  let queue: MTLCommandQueue
  let engine: MonitorEngine
  private let scopeLock = NSLock()
  private var scopes: ScopeEngine?

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw XCTSkip("No Metal device")
    }
    self.device = device
    self.queue = queue
    engine = try MonitorEngine(device: device, specialization: .synchronous)
  }

  /// Shares the engine's residency set, as an app would.
  func scopeEngine() throws -> ScopeEngine {
    try scopeLock.withLock {
      if let scopes { return scopes }
      let s = try ScopeEngine(device: device, specialization: .synchronous, residency: engine.residency)
      scopes = s
      return s
    }
  }

  /// Encodes, commits and waits (the test host's job, never the library's).
  func run(_ body: (MTLCommandBuffer) throws -> Void) throws {
    let cb = queue.makeCommandBuffer()!
    try body(cb)
    cb.commit()
    cb.waitUntilCompleted()
    if let error = cb.error { throw error }
  }

  func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, usage: MTLTextureUsage = [.shaderRead, .renderTarget])
    -> MTLTexture
  {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = usage
    d.storageMode = .shared
    return device.makeTexture(descriptor: d)!
  }

  /// An 8-bit Rec.709 frame: a horizontal ramp in R, a vertical one in G, B constant.
  func sdrFrame(width: Int = 64, height: Int = 36, seed: UInt8 = 0) throws -> MonitorFrame {
    let t = texture(.bgra8Unorm, width, height, usage: [.shaderRead])
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        bytes[i + 0] = 90 &+ seed  // B
        bytes[i + 1] = UInt8(y * 255 / max(1, height - 1))  // G
        bytes[i + 2] = UInt8(x * 255 / max(1, width - 1))  // R
        bytes[i + 3] = 255
      }
    }
    t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    return try MonitorFrame(
      layout: .bgra8, width: width, height: height, luma: t,
      signal: SignalDescription(range: .full, encoding: .display(.bt709)))
  }

  /// A half-float PQ (BT.2100) frame: a horizontal ramp of PQ signal 0…1 in every channel.
  func pqFrame(width: Int = 64, height: Int = 16, primaries: ColorPrimaries? = .rec2020) throws -> MonitorFrame {
    let t = texture(.rgba16Float, width, height, usage: [.shaderRead])
    var values = [Float16](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let v = Float16(Float(x) / Float(width - 1))
        let i = (y * width + x) * 4
        values[i] = v
        values[i + 1] = v
        values[i + 2] = v
        values[i + 3] = 1
      }
    }
    t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: values, bytesPerRow: width * 8)
    return try MonitorFrame(
      layout: .rgba16Float, width: width, height: height, luma: t,
      signal: SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq), primaries: primaries))
  }
}

func requireGPU() throws -> UIGPU {
  guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
  return try UIGPU.shared.get()
}

/// Allocation counts are meaningless under the Metal debug layer, which allocates per call.
func skipUnderTheDebugLayer() throws {
  let env = ProcessInfo.processInfo.environment
  if env["MTL_DEBUG_LAYER"] == "1" || env["MTL_SHADER_VALIDATION"] == "1" {
    throw XCTSkip("allocation counts are not meaningful under the Metal debug layer")
  }
}

/// RGBA texels of a shared texture, as Float (8-bit unorm, 10-bit unorm or half float).
struct Texels: Equatable {
  let width: Int, height: Int
  let values: [SIMD4<Float>]

  init(_ t: MTLTexture) {
    width = t.width
    height = t.height
    var out = [SIMD4<Float>](repeating: .zero, count: t.width * t.height)
    switch t.pixelFormat {
    case .bgra8Unorm, .bgra8Unorm_srgb:
      var b = [UInt8](repeating: 0, count: t.width * t.height * 4)
      t.getBytes(&b, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
      for i in 0..<out.count {
        out[i] = SIMD4(Float(b[i * 4 + 2]), Float(b[i * 4 + 1]), Float(b[i * 4]), Float(b[i * 4 + 3])) / 255
      }
    case .rgba16Float:
      var h = [Float16](repeating: 0, count: t.width * t.height * 4)
      t.getBytes(&h, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
      for i in 0..<out.count {
        out[i] = SIMD4(Float(h[i * 4]), Float(h[i * 4 + 1]), Float(h[i * 4 + 2]), Float(h[i * 4 + 3]))
      }
    case .bgr10a2Unorm:
      var w = [UInt32](repeating: 0, count: t.width * t.height)
      t.getBytes(&w, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
      for i in 0..<out.count {
        let v = w[i]
        out[i] = SIMD4(
          Float((v >> 20) & 1023) / 1023, Float((v >> 10) & 1023) / 1023, Float(v & 1023) / 1023,
          Float(v >> 30) / 3)
      }
    default:
      fatalError("unsupported read-back format \(t.pixelFormat.rawValue)")
    }
    values = out
  }

  subscript(x: Int, y: Int) -> SIMD4<Float> { values[y * width + x] }

  /// The texels of `vp`.
  func region(_ vp: MonitorViewport) -> [SIMD4<Float>] {
    var out: [SIMD4<Float>] = []
    for y in vp.y..<(vp.y + vp.height) {
      for x in vp.x..<(vp.x + vp.width) { out.append(self[x, y]) }
    }
    return out
  }
}

/// Counts heap allocations made on the calling thread, through libmalloc's logger hook.
enum AllocationCounter {
  typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
  nonisolated(unsafe) static var count = 0
  nonisolated(unsafe) static var thread: pthread_t?
  nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? = dlsym(
    UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger"
  ).map { $0.assumingMemoryBound(to: Logger?.self) }

  /// Allocations made by `body` on this thread, or nil when the hook is unavailable.
  static func measure(_ body: () throws -> Void) rethrows -> Int? {
    guard let slot, slot.pointee == nil else {
      try body()
      return nil
    }
    count = 0
    thread = pthread_self()
    slot.pointee = { type, _, _, _, _, _ in
      // MALLOC_LOG_TYPE_ALLOCATE
      if type & 2 != 0, let t = AllocationCounter.thread, pthread_equal(pthread_self(), t) != 0 {
        AllocationCounter.count += 1
      }
    }
    defer {
      slot.pointee = nil
      thread = nil
    }
    try body()
    return count
  }
}
