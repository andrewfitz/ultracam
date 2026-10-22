import CoreVideo
import Metal
import XCTest

@testable import MonitorKit

/// The GPU objects every test shares: one device, queue and engine, plus test
/// kernels that call MonitorKit's fusable MSL functions the way a host would.
final class TestGPU: @unchecked Sendable {
  static let shared = Result { try TestGPU() }

  let device: MTLDevice
  let queue: MTLCommandQueue
  let engine: MonitorEngine
  let cache: CVMetalTextureCache
  let decode: MTLComputePipelineState
  let lut: MTLComputePipelineState
  let hostOutput: MTLComputePipelineState
  let readMask: MTLComputePipelineState

  static let kernels = """
    kernel void test_decode(texture2d<uint, access::read> packed [[texture(0)]],
                            texture2d<float, access::read> luma [[texture(1)]],
                            texture2d<float, access::read> chroma [[texture(2)]],
                            constant mk_FrameParams& f [[buffer(0)]],
                            device float4* out [[buffer(1)]],
                            uint2 xy [[thread_position_in_grid]]) {
      if (xy.x >= f.shape.y || xy.y >= f.shape.z) return;
      out[xy.y * f.shape.y + xy.x] = mk_decode(packed, luma, chroma, xy, f);
    }
    kernel void test_lut(device const float4* input [[buffer(0)]],
                         texture3d<float, access::sample> lut [[texture(0)]],
                         constant mk_LUTParams& p [[buffer(1)]],
                         device float4* out [[buffer(2)]],
                         uint i [[thread_position_in_grid]]) {
      out[i] = float4(mk_applyLUT(input[i].rgb, lut, p), 1);
    }
    // A host's own output kernel with the LUT burned in (the fused tier).
    kernel void test_hostOutput(texture2d<uint, access::read> packed [[texture(0)]],
                                texture2d<float, access::read> luma [[texture(1)]],
                                texture2d<float, access::read> chroma [[texture(2)]],
                                texture3d<float, access::sample> burnLUT [[texture(3)]],
                                texture3d<float, access::sample> monitorLUT [[texture(4)]],
                                texture2d<float, access::write> out [[texture(5)]],
                                constant mk_FrameParams& f [[buffer(0)]],
                                constant mk_LUTParams& burn [[buffer(1)]],
                                constant mk_LUTParams& monitor [[buffer(2)]],
                                uint2 xy [[thread_position_in_grid]]) {
      if (xy.x >= f.shape.y || xy.y >= f.shape.z) return;
      float3 rgb = mk_applyLUT(mk_decodeRGB(packed, luma, chroma, xy, f), burnLUT, burn);
      rgb = mk_applyLUT(rgb, monitorLUT, monitor);
      out.write(float4(clamp(rgb, 0.0f, 1.0f), 1), xy);
    }
    kernel void test_readMask(texture2d<float, access::read> mask [[texture(0)]],
                              device float* out [[buffer(0)]],
                              uint2 xy [[thread_position_in_grid]]) {
      if (xy.x >= mask.get_width() || xy.y >= mask.get_height()) return;
      out[xy.y * mask.get_width() + xy.x] = mask.read(xy).r;
    }
    """

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw XCTSkip("No Metal device")
    }
    self.device = device
    self.queue = queue
    // Synchronous specialization: every frame of a test draws with its final pipeline.
    engine = try MonitorEngine(device: device, specialization: .synchronous)
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    self.cache = cache!
    let library = try MonitorShaders.makeLibrary(device: device, parts: [.lut, .decode], extra: Self.kernels)
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
    }
    decode = try pipeline("test_decode")
    lut = try pipeline("test_lut")
    hostOutput = try pipeline("test_hostOutput")
    readMask = try pipeline("test_readMask")
  }

  func run(_ body: (MTLCommandBuffer) throws -> Void) rethrows {
    let cb = queue.makeCommandBuffer()!
    try body(cb)
    cb.commit()
    cb.waitUntilCompleted()
    XCTAssertNil(cb.error)
  }

  func buffer<T>(_ values: [T]) -> MTLBuffer {
    values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count))! }
  }

  func buffer(length: Int) -> MTLBuffer { device.makeBuffer(length: max(16, length), options: .storageModeShared)! }

  func texture(
    _ format: MTLPixelFormat, _ width: Int, _ height: Int, bytes: UnsafeRawBufferPointer? = nil,
    bytesPerRow: Int = 0, usage: MTLTextureUsage = .shaderRead
  ) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = usage
    d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    if let bytes {
      t.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes.baseAddress!,
        bytesPerRow: bytesPerRow)
    }
    return t
  }

  func target(_ width: Int, _ height: Int, format: MTLPixelFormat = .rgba32Float) -> MTLTexture {
    texture(format, width, height, usage: [.renderTarget, .shaderRead])
  }

  /// `mk_decode` at every pixel: R'G'B' in xyz, Y' in w.
  func decode(_ frame: MonitorFrame) -> [SIMD4<Float>] {
    let out = buffer(length: frame.width * frame.height * 16)
    run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(decode)
      e.setTexture(frame.packed ?? engine.emptyPacked, index: 0)
      e.setTexture(frame.luma ?? engine.emptyFloat, index: 1)
      e.setTexture(frame.chroma ?? engine.emptyFloat, index: 2)
      var p = frame.parameters
      e.setBytes(&p, length: MemoryLayout<FrameParameters>.stride, index: 0)
      e.setBuffer(out, offset: 0, index: 1)
      e.dispatchThreads(
        MTLSize(width: frame.width, height: frame.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
      e.endEncoding()
    }
    return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: frame.width * frame.height))
  }

  func readMask(_ feed: MonitorFeed) -> [Float] {
    let mask = feed.focusMask!
    let out = buffer(length: mask.width * mask.height * 4)
    run { cb in
      let e = cb.makeComputeCommandEncoder()!
      e.setComputePipelineState(readMask)
      e.setTexture(mask, index: 0)
      e.setBuffer(out, offset: 0, index: 0)
      e.dispatchThreads(
        MTLSize(width: mask.width, height: mask.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
      e.endEncoding()
    }
    return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Float.self), count: mask.width * mask.height))
  }

  /// One frame through `pass` into a fresh float target, read back.
  func render(
    _ frame: MonitorFrame, state: MonitorState, feed: MonitorFeed? = nil, pass: MonitorPass? = nil,
    width: Int? = nil, height: Int? = nil, format: MTLPixelFormat = .rgba32Float,
    viewport: MonitorViewport? = nil, analyze: Bool = false
  ) throws -> Pixels {
    let feed = feed ?? engine.makeFeed()
    let pass = pass ?? engine.makePass()
    let t = target(width ?? frame.width, height ?? frame.height, format: format)
    try run { cb in
      if analyze { try feed.analyze(frame, focus: state.focus, into: cb) }
      try pass.encode(frame: frame, feed: feed, state: state, target: t, viewport: viewport, into: cb)
    }
    return Pixels(t)
  }
}

/// The shared GPU, skipping when there is no Metal device. A device whose setup
/// fails (e.g. a shader that does not compile) is a failure, not a skip.
func requireGPU() throws -> TestGPU {
  guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
  return try TestGPU.shared.get()
}

/// A read-back float or 8-bit target.
struct Pixels {
  let width: Int, height: Int
  let values: [SIMD4<Float>]

  init(_ t: MTLTexture) {
    width = t.width
    height = t.height
    switch t.pixelFormat {
    case .rgba32Float:
      var v = [SIMD4<Float>](repeating: .zero, count: t.width * t.height)
      v.withUnsafeMutableBytes {
        t.getBytes($0.baseAddress!, bytesPerRow: t.width * 16, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
      }
      values = v
    case .bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb:
      var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
      bytes.withUnsafeMutableBytes {
        t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
      }
      let bgra = t.pixelFormat == .bgra8Unorm || t.pixelFormat == .bgra8Unorm_srgb
      values = (0..<(t.width * t.height)).map { i in
        let p = SIMD4<Float>(Float(bytes[i * 4]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4 + 2]), Float(bytes[i * 4 + 3])) / 255
        return bgra ? SIMD4(p.z, p.y, p.x, p.w) : p
      }
    default: fatalError("unsupported read-back format")
    }
  }

  subscript(x: Int, y: Int) -> SIMD4<Float> { values[y * width + x] }
  func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> { let v = self[x, y]; return SIMD3(v.x, v.y, v.z) }
}

/// Deterministic test values.
struct SeededRandom: RandomNumberGenerator {
  var state: UInt64
  init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

extension SIMD3 where Scalar == Float {
  init(_ c: ColorRGB) { self.init(Float(c.r), Float(c.g), Float(c.b)) }
}
