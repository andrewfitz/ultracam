import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// One compiled engine for the whole test run.
enum GPU {
  static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
  static let queue: MTLCommandQueue? = device?.makeCommandQueue()
  /// Asynchronous, like a host's; the general render pipelines of the test
  /// targets' formats are built up front, so the first draw is not skipped.
  static let engine: ScopeEngine? = device.flatMap { device in
    guard let engine = try? ScopeEngine(device: device) else { return nil }
    for format in targetFormats { try? engine.prepare(pixelFormat: format) }
    return engine
  }
  static let targetFormats: [MTLPixelFormat] = [.rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .rgba32Float]
  /// Builds every specialized pipeline on first use, so tests exercise them deterministically.
  static let synchronousEngine: ScopeEngine? = device.flatMap { try? ScopeEngine(device: $0, specialization: .synchronous) }
  /// Never specializes: the general pipelines only.
  static let generalEngine: ScopeEngine? = device.flatMap { try? ScopeEngine(device: $0, specialization: .off) }

  static func require() throws -> (MTLDevice, MTLCommandQueue, ScopeEngine) {
    guard let device, let queue else { throw XCTSkip("No Metal device") }
    guard let engine else {
      // Surface the compile error instead of a bare nil.
      _ = try ScopeEngine(device: device)
      throw XCTSkip("Scope engine unavailable")
    }
    return (device, queue, engine)
  }

  /// Runs `encode` in one command buffer and waits for it.
  static func run(_ encode: (MTLCommandBuffer) throws -> Void) throws {
    let (_, queue, _) = try require()
    let cb = try XCTUnwrap(queue.makeCommandBuffer())
    try encode(cb)
    cb.commit()
    cb.waitUntilCompleted()
    if let error = cb.error { throw error }
  }

  /// Copies a private buffer into shared memory (test-only readback).
  static func read<T>(_ buffer: MTLBuffer, as: T.Type, count: Int) throws -> [T] {
    let (device, _, _) = try require()
    let length = max(buffer.length, 16)
    let shared = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
    try run { cb in
      let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
      blit.copy(from: buffer, sourceOffset: 0, to: shared, destinationOffset: 0, size: buffer.length)
      blit.endEncoding()
    }
    let p = shared.contents().bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: p, count: count))
  }
}

/// Deterministic pseudo-random numbers (SplitMix64).
struct SeededRandom {
  var state: UInt64
  init(_ seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
  }
  mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// A synthetic frame on the GPU plus a CPU mirror of `mk_decodeRGB`.
struct TestFrame {
  let frame: MonitorFrame
  let width: Int
  let height: Int
  /// Decoded RGB per pixel, row-major, computed with the shader's Float operations.
  let rgb: [SIMD3<Float>]
  /// Decoded transport Y' per pixel (`mk_decode(...).w`).
  let luma: [Float]

  init(frame: MonitorFrame, width: Int, height: Int, rgb: [SIMD3<Float>], luma: [Float]? = nil) {
    self.frame = frame
    self.width = width
    self.height = height
    self.rgb = rgb
    let k = frame.parameters.matrix
    self.luma = luma ?? rgb.map { mkLuma($0, SIMD3(k.x, k.y, k.z)) }
  }

  enum Kind: CustomStringConvertible {
    case v210, uyvy8, yuyv8, biplanar(ChromaSubsampling, Int), bgra8, rgba16Float
    var description: String {
      switch self {
      case .v210: return "v210"
      case .uyvy8: return "uyvy8"
      case .yuyv8: return "yuyv8"
      case .biplanar(let s, let d): return "biplanar \(s) \(d)-bit"
      case .bgra8: return "bgra8"
      case .rgba16Float: return "rgba16Float"
      }
    }
    static let all: [Kind] = [
      .v210, .uyvy8, .yuyv8, .biplanar(.s420, 8), .biplanar(.s422, 8), .biplanar(.s420, 10), .biplanar(.s422, 10),
      .biplanar(.s444, 10), .biplanar(.s420, 12), .biplanar(.s422, 16), .bgra8, .rgba16Float,
    ]
    /// The Y'CbCr layouts, which also come full range.
    static let ycbcr: [Kind] = all.filter { !$0.isRGB }
    var isRGB: Bool {
      switch self {
      case .bgra8, .rgba16Float: return true
      default: return false
      }
    }
    var bitDepth: Int {
      switch self {
      case .v210: return 10
      case .uyvy8, .yuyv8, .bgra8: return 8
      case .biplanar(_, let d): return d
      case .rgba16Float: return 16
      }
    }
  }

  /// Y'CbCr codes at `bitDepth` for each luma pixel; chroma is taken at the
  /// chroma sample positions (even columns, even rows for 4:2:0).
  typealias CodeSource = (_ x: Int, _ y: Int) -> SIMD3<Int>
  /// Normalized RGB for RGB layouts.
  typealias RGBSource = (_ x: Int, _ y: Int) -> SIMD3<Float>

  /// `mirror: false` skips the CPU decode (for benchmarks).
  static func make(
    _ kind: Kind, width: Int, height: Int, signal: SignalDescription = .rec709, codes: CodeSource? = nil,
    rgb: RGBSource? = nil, mirror: Bool = true
  ) throws -> TestFrame {
    let (device, _, _) = try GPU.require()
    func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ bytes: UnsafeRawPointer, _ rowBytes: Int) throws
      -> MTLTexture
    {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
      d.usage = .shaderRead
      d.storageMode = .shared
      let t = try XCTUnwrap(device.makeTexture(descriptor: d))
      t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: rowBytes)
      return t
    }
    switch kind {
    case .bgra8, .rgba16Float:
      let source = try XCTUnwrap(rgb)
      var values = [SIMD3<Float>](repeating: .zero, count: width * height)
      let frame: MonitorFrame
      if case .bgra8 = kind {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
          for x in 0..<width {
            let v = source(x, y)
            let q = SIMD3<UInt8>(
              UInt8(max(0, min(255, (v.x * 255).rounded()))), UInt8(max(0, min(255, (v.y * 255).rounded()))),
              UInt8(max(0, min(255, (v.z * 255).rounded()))))
            let i = (y * width + x) * 4
            bytes[i] = q.z
            bytes[i + 1] = q.y
            bytes[i + 2] = q.x
            values[y * width + x] = SIMD3(Float(q.x) / 255, Float(q.y) / 255, Float(q.z) / 255)
          }
        }
        let t = try bytes.withUnsafeBytes { try texture(.bgra8Unorm, width, height, $0.baseAddress!, width * 4) }
        frame = try MonitorFrame(layout: .bgra8, width: width, height: height, luma: t, signal: signal)
      } else {
        var halves = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
          for x in 0..<width {
            let v = source(x, y)
            let i = (y * width + x) * 4
            halves[i] = Float16(v.x)
            halves[i + 1] = Float16(v.y)
            halves[i + 2] = Float16(v.z)
            values[y * width + x] = SIMD3(Float(halves[i]), Float(halves[i + 1]), Float(halves[i + 2]))
          }
        }
        let t = try halves.withUnsafeBytes {
          try texture(.rgba16Float, width, height, $0.baseAddress!, width * 8)
        }
        frame = try MonitorFrame(layout: .rgba16Float, width: width, height: height, luma: t, signal: signal)
      }
      // Full-range RGB: decode is the texel value itself.
      let p = frame.parameters
      if p.codeScale.w == 0 && p.options.y == 0 {
        values = values.map { ($0 * p.codeScale.z - p.levels.x) / p.levels.y }
      }
      return TestFrame(frame: frame, width: width, height: height, rgb: values)

    case .v210, .uyvy8, .yuyv8, .biplanar:
      let source = try XCTUnwrap(codes)
      let sub: ChromaSubsampling
      let depth: Int
      switch kind {
      case .v210: (sub, depth) = (.s422, 10)
      case .uyvy8, .yuyv8: (sub, depth) = (.s422, 8)
      case .biplanar(let s, let d): (sub, depth) = (s, d)
      default: fatalError()
      }
      let cw = sub == .s444 ? width : (width + 1) / 2
      let ch = sub == .s420 ? (height + 1) / 2 : height
      let maxCode = (1 << depth) - 1
      func clampCode(_ v: Int) -> Int { max(0, min(maxCode, v)) }
      var yPlane = [Int](repeating: 0, count: width * height)
      var cPlane = [SIMD2<Int>](repeating: .zero, count: cw * ch)
      for y in 0..<height {
        for x in 0..<width { yPlane[y * width + x] = clampCode(source(x, y).x) }
      }
      for cy in 0..<ch {
        for cx in 0..<cw {
          let lx = sub == .s444 ? cx : cx * 2, ly = sub == .s420 ? cy * 2 : cy
          let v = source(min(lx, width - 1), min(ly, height - 1))
          cPlane[cy * cw + cx] = SIMD2(clampCode(v.y), clampCode(v.z))
        }
      }
      let frame: MonitorFrame
      // What the GPU reads for each stored code, as `mk_lumaCode`/`mk_chromaSample` return it.
      var lumaRead: (Int) -> Float = { Float($0) }
      switch kind {
      case .v210:
        let groups = (width + 5) / 6
        var words = [UInt32](repeating: 0, count: groups * 4 * height)
        for y in 0..<height {
          for g in 0..<groups {
            func Y(_ i: Int) -> UInt32 { let x = g * 6 + i; return x < width ? UInt32(yPlane[y * width + x]) : 0 }
            func C(_ i: Int) -> SIMD2<UInt32> {
              let c = g * 3 + i
              return c < cw ? SIMD2(UInt32(cPlane[y * cw + c].x), UInt32(cPlane[y * cw + c].y)) : .zero
            }
            let base = (y * groups + g) * 4
            words[base] = C(0).x | Y(0) << 10 | C(0).y << 20
            words[base + 1] = Y(1) | C(1).x << 10 | Y(2) << 20
            words[base + 2] = C(1).y | Y(3) << 10 | C(2).x << 20
            words[base + 3] = Y(4) | C(2).y << 10 | Y(5) << 20
          }
        }
        let t = try words.withUnsafeBytes { try texture(.rgba32Uint, groups, height, $0.baseAddress!, groups * 16) }
        frame = try MonitorFrame(layout: .v210, width: width, height: height, packed: t, signal: signal)
      case .uyvy8, .yuyv8:
        let yuyv = { if case .yuyv8 = kind { return true } else { return false } }()
        let pairs = (width + 1) / 2
        var bytes = [UInt8](repeating: 0, count: pairs * 4 * height)
        for y in 0..<height {
          for p in 0..<pairs {
            let i = (y * pairs + p) * 4
            let c = cPlane[y * cw + p]
            let y0 = UInt8(yPlane[y * width + p * 2])
            let y1 = p * 2 + 1 < width ? UInt8(yPlane[y * width + p * 2 + 1]) : 0
            // 2vuy: Cb Y0 Cr Y1. yuvs: Y0 Cb Y1 Cr.
            let order = yuyv ? [y0, UInt8(c.x), y1, UInt8(c.y)] : [UInt8(c.x), y0, UInt8(c.y), y1]
            for j in 0..<4 { bytes[i + j] = order[j] }
          }
        }
        let t = try bytes.withUnsafeBytes { try texture(.rgba8Uint, pairs, height, $0.baseAddress!, pairs * 4) }
        frame = try MonitorFrame(
          layout: yuyv ? .yuyv8 : .uyvy8, width: width, height: height, packed: t, signal: signal)
      case .biplanar(let s, let d):
        let layout = PixelLayout.biplanar(s, bitDepth: d)
        if d == 8 {
          let yBytes = yPlane.map { UInt8($0) }
          let cBytes = cPlane.flatMap { [UInt8($0.x), UInt8($0.y)] }
          let yt = try yBytes.withUnsafeBytes { try texture(.r8Unorm, width, height, $0.baseAddress!, width) }
          let ct = try cBytes.withUnsafeBytes { try texture(.rg8Unorm, cw, ch, $0.baseAddress!, cw * 2) }
          frame = try MonitorFrame(layout: layout, width: width, height: height, luma: yt, chroma: ct, signal: signal)
          let scale = frame.parameters.codeScale.x
          lumaRead = { Float($0) / 255 * scale }
        } else {
          let shift = 16 - d
          let yWords = yPlane.map { UInt16($0 << shift) }
          let cWords = cPlane.flatMap { [UInt16($0.x << shift), UInt16($0.y << shift)] }
          let yt = try yWords.withUnsafeBytes { try texture(.r16Unorm, width, height, $0.baseAddress!, width * 2) }
          let ct = try cWords.withUnsafeBytes { try texture(.rg16Unorm, cw, ch, $0.baseAddress!, cw * 4) }
          frame = try MonitorFrame(layout: layout, width: width, height: height, luma: yt, chroma: ct, signal: signal)
          let scale = frame.parameters.codeScale.x
          lumaRead = { Float($0 << shift) / 65535 * scale }
        }
      default: fatalError()
      }
      let p = frame.parameters
      let chromaRead = lumaRead
      func chromaSample(_ cx: Int, _ cy: Int) -> SIMD2<Float> {
        let c = cPlane[cy * cw + cx]
        return SIMD2(chromaRead(c.x), chromaRead(c.y))
      }
      func mix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> { a + (b - a) * t }
      // Mirrors mk_chromaCode.
      func chromaCode(_ x: Int, _ y: Int) -> SIMD2<Float> {
        if sub == .s444 { return chromaSample(x, y) }
        let cx = (Float(x) - (p.options.x != 0 ? 0.5 : 0)) * 0.5
        let fx0 = cx.rounded(.down), fx = cx - fx0
        let x0 = max(0, min(cw - 1, Int(fx0))), x1 = max(0, min(cw - 1, Int(fx0) + 1))
        if sub == .s422 {
          let a = chromaSample(x0, y)
          if fx == 0 { return a }
          return mix(a, chromaSample(x1, y), fx)
        }
        let cy = (Float(y) - 0.5 - p.matrix.w) * 0.5
        let fy0 = cy.rounded(.down), fy = cy - fy0
        let y0 = max(0, min(ch - 1, Int(fy0))), y1 = max(0, min(ch - 1, Int(fy0) + 1))
        let top = mix(chromaSample(x0, y0), chromaSample(x1, y0), fx)
        let bottom = mix(chromaSample(x0, y1), chromaSample(x1, y1), fx)
        return mix(top, bottom, fy)
      }
      let m = p.matrix
      guard mirror else { return TestFrame(frame: frame, width: width, height: height, rgb: [], luma: []) }
      var values = [SIMD3<Float>](repeating: .zero, count: width * height)
      var lumas = [Float](repeating: 0, count: width * height)
      for y in 0..<height {
        for x in 0..<width {
          let yn = (lumaRead(yPlane[y * width + x]) - p.levels.x) / p.levels.y
          lumas[y * width + x] = yn
          let code = chromaCode(x, y)
          let c = SIMD2((code.x - p.levels.z) / p.levels.w, (code.y - p.levels.z) / p.levels.w)
          if c.x == 0 && c.y == 0 {
            values[y * width + x] = SIMD3(repeating: yn)
          } else {
            let r = yn + 2 * (1 - m.x) * c.y, b = yn + 2 * (1 - m.z) * c.x
            values[y * width + x] = SIMD3(r, (yn - m.x * r - m.z * b) / m.y, b)
          }
        }
      }
      return TestFrame(frame: frame, width: width, height: height, rgb: values, luma: lumas)
    }
  }

  /// A busy, deterministic picture: gradients, noise and flat patches.
  static func natural(
    _ kind: Kind, width: Int, height: Int, seed: UInt64 = 1, signal: SignalDescription = .rec709,
    mirror: Bool = true
  ) throws -> TestFrame {
    var random = SeededRandom(seed)
    let depth: Int
    switch kind {
    case .v210: depth = 10
    case .uyvy8, .yuyv8: depth = 8
    case .biplanar(_, let d): depth = d
    default: depth = 8
    }
    let scale = 1 << (depth - 8)
    var noise = [Int](repeating: 0, count: width * height * 3)
    for i in noise.indices { noise[i] = random.int(-40...40) }
    let codes: CodeSource = { x, y in
      let i = (y * width + x) * 3
      if x < width / 4 { return SIMD3(512 * scale / 4 + y, 128 * scale, 128 * scale) }  // flat-ish column patch
      let fy = Double(y) / Double(max(1, height - 1)), fx = Double(x) / Double(max(1, width - 1))
      let luma = Int((4 + fy * 250) * Double(scale)) + noise[i] * scale / 2
      let cb = Int((128 + (fx - 0.5) * 200) * Double(scale)) + noise[i + 1] * scale
      let cr = Int((128 + (0.5 - fy) * 180) * Double(scale)) + noise[i + 2] * scale
      return SIMD3(luma, cb, cr)
    }
    let rgb: RGBSource = { x, y in
      let i = (y * width + x) * 3
      let fy = Float(y) / Float(max(1, height - 1)), fx = Float(x) / Float(max(1, width - 1))
      let n = SIMD3(Float(noise[i]), Float(noise[i + 1]), Float(noise[i + 2])) / 400
      if x < width / 4 { return SIMD3(0.4, 0.42, 0.38) }
      // Float RGB may leave 0…1, as camera floats do.
      return SIMD3(fx * 1.1 - 0.03, fy, 1 - fx) + n
    }
    return try make(kind, width: width, height: height, signal: signal, codes: codes, rgb: rgb, mirror: mirror)
  }
}

/// `mk_luma`: g + kr(r - g) + kb(b - g), exact for neutrals.
func mkLuma(_ rgb: SIMD3<Float>, _ k: SIMD3<Float>) -> Float { rgb.y + k.x * (rgb.x - rgb.y) + k.z * (rgb.z - rgb.y) }

extension ScopeKernelParameters {
  /// The Y' a scope draws for a pixel: the transport luma, or `mk_luma` of the
  /// stage RGB with the colorimetry's weights.
  func scopeLuma(_ rgb: SIMD3<Float>, transport: Float) -> Float {
    weights.w != 0 ? transport : mkLuma(rgb, SIMD3(weights.x, weights.y, weights.z))
  }

  /// The stage Y' the statistics measure, as the picture's `mk_stageLuma`: the
  /// transport luma where no LUT touched the stage, Rec.709 Y' of a LUT result.
  func statisticsLuma(_ rgb: SIMD3<Float>, transport: Float) -> Float {
    luts.x != 0 || luts.y != 0 ? mkLuma(rgb, SIMD3(0.2126, 0.7152, 0.0722)) : transport
  }
}

/// CPU reference binning that tolerates float noise at bin edges: a value
/// within `epsilon` bins of an edge may land in either neighbour.
struct BinReference {
  var certain: [Int]
  var possible: [Int]
  var ambiguous = 0
  var dropped = 0

  init(count: Int) {
    certain = Array(repeating: 0, count: count)
    possible = Array(repeating: 0, count: count)
  }

  /// Candidate bins of one axis for `position` (in bins): one bin, or two
  /// when within `epsilon` of an edge. -1 means outside 0..<n (when not
  /// clamping). `epsilon` must stay below 0.5 bins, or the two candidates can
  /// straddle the true bin.
  @inline(__always)
  static func candidates(_ position: Float, _ n: Int, epsilon: Float, clamp: Bool) -> (Int, Int) {
    precondition(epsilon < 0.5, "a candidate pair brackets one bin edge")
    func bin(_ v: Float) -> Int {
      if v.isNaN { return 0 }
      let f = v.rounded(.down)
      let b = f < -1 ? -1 : (f > Float(n) ? n : Int(f))
      if clamp { return max(0, min(n - 1, b)) }
      return b < 0 || b >= n ? -1 : b
    }
    return (bin(position - epsilon), bin(position + epsilon))
  }

  mutating func add(_ a: Int, _ b: Int) {
    if a == b {
      if a >= 0 { certain[a] += 1 } else { dropped += 1 }
    } else {
      ambiguous += 1
      if a >= 0 { possible[a] += 1 }
      if b >= 0 { possible[b] += 1 }
    }
  }

  /// Two axes: up to four candidate bins of a row-major plane `n` wide.
  mutating func add(x: (Int, Int), y: (Int, Int), n: Int) {
    func index(_ bx: Int, _ by: Int) -> Int { bx < 0 || by < 0 ? -1 : by * n + bx }
    if x.0 == x.1 && y.0 == y.1 { return add(index(x.0, y.0), index(x.0, y.0)) }
    ambiguous += 1
    var seen = [Int](repeating: -2, count: 4)
    var count = 0
    for bx in [x.0, x.1] {
      for by in [y.0, y.1] {
        let i = index(bx, by)
        if i >= 0 && !seen[0..<count].contains(i) {
          seen[count] = i
          count += 1
          possible[i] += 1
        }
      }
    }
  }

  /// Every GPU bin is within what the CPU allows.
  func check(_ gpu: [UInt32], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(gpu.count, certain.count, message, file: file, line: line)
    var failures = 0
    for i in certain.indices where Int(gpu[i]) < certain[i] || Int(gpu[i]) > certain[i] + possible[i] {
      if failures < 5 {
        XCTFail(
          "\(message): bin \(i) GPU \(gpu[i]) CPU \(certain[i]) (+\(possible[i]) ambiguous)", file: file, line: line)
      }
      failures += 1
    }
    let total = gpu.reduce(0) { $0 + Int($1) }
    let sure = certain.reduce(0, +)
    XCTAssertTrue(
      total >= sure && total <= sure + ambiguous, "\(message): total \(total) vs \(sure)+\(ambiguous)", file: file,
      line: line)
    XCTAssertLessThan(ambiguous, max(16, certain.count), "\(message): too many ambiguous samples", file: file, line: line)
  }
}

/// Unpacks an accumulator's bins into 32-bit counts.
func readBins(_ accumulator: ScopeAccumulator) throws -> [UInt32] {
  let layout = accumulator.layout
  if layout.bytesPerBin == 2 {
    let halves = try GPU.read(accumulator.bins, as: UInt16.self, count: layout.binCount)
    return halves.map { UInt32($0) }
  }
  return try GPU.read(accumulator.bins, as: UInt32.self, count: layout.binCount)
}
