import CoreVideo
import Metal
import XCTest

@testable import MonitorKit

/// A test picture as codes, packed into any layout either as raw Metal textures
/// or as an IOSurface `CVPixelBuffer` mapped through the texture cache, with a
/// Double-precision CPU reference decode.
struct SyntheticFrame {
  let layout: PixelLayout
  let width: Int
  let height: Int
  /// Y'CbCr layouts: luma codes per pixel, chroma codes per chroma site.
  var y: [Int] = []
  var cb: [Int] = []
  var cr: [Int] = []
  /// RGB layouts: stored values, already normalized (unorm code / max, or float).
  var rgb: [SIMD3<Double>] = []

  var chromaWidth: Int { layout.subsampling == .s444 ? width : (width + 1) / 2 }
  var chromaHeight: Int { layout.subsampling == .s420 ? (height + 1) / 2 : height }
  var maxCode: Int { (1 << layout.bitDepth) - 1 }

  init(layout: PixelLayout, width: Int, height: Int) {
    self.layout = layout
    self.width = width
    self.height = height
  }

  /// Every code drawn uniformly over the whole code space, footroom and headroom included.
  static func random(_ layout: PixelLayout, width: Int, height: Int, seed: UInt64) -> SyntheticFrame {
    var f = SyntheticFrame(layout: layout, width: width, height: height)
    var rng = SeededRandom(seed)
    if layout.isRGB {
      f.rgb = (0..<(width * height)).map { _ in
        func v() -> Double {
          if case .rgb(let d, true) = layout {
            let x = Double.random(in: -0.1...1.2, using: &rng)
            return d == 16 ? Double(Float16(x)) : Double(Float(x))
          }
          let m = Double(f.maxCode)
          return Double(Int.random(in: 0...f.maxCode, using: &rng)) / m
        }
        return SIMD3(v(), v(), v())
      }
    } else {
      f.y = (0..<(width * height)).map { _ in Int.random(in: 0...f.maxCode, using: &rng) }
      let n = f.chromaWidth * f.chromaHeight
      f.cb = (0..<n).map { _ in Int.random(in: 0...f.maxCode, using: &rng) }
      f.cr = (0..<n).map { _ in Int.random(in: 0...f.maxCode, using: &rng) }
    }
    return f
  }

  /// Neutral picture: luma code `codes(x, y)`, chroma at its centre.
  static func neutral(_ layout: PixelLayout, width: Int, height: Int, codes: (Int, Int) -> Int) -> SyntheticFrame {
    var f = SyntheticFrame(layout: layout, width: width, height: height)
    if layout.isRGB {
      f.rgb = (0..<(width * height)).map { i in
        SIMD3(repeating: Double(codes(i % width, i / width)) / Double(f.maxCode))
      }
    } else {
      f.y = (0..<(width * height)).map { codes($0 % width, $0 / width) }
      let center = 1 << (layout.bitDepth - 1)
      f.cb = Array(repeating: center, count: f.chromaWidth * f.chromaHeight)
      f.cr = f.cb
    }
    return f
  }

  // MARK: - CPU reference

  /// Double-precision decode of every pixel, following `DecodeReference`.
  func reference(_ signal: SignalDescription) -> [(rgb: SIMD3<Double>, luma: Double)] {
    var out: [(SIMD3<Double>, Double)] = []
    out.reserveCapacity(width * height)
    let k = signal.matrix.coefficients
    for py in 0..<height {
      for px in 0..<width {
        if layout.isRGB {
          var v = rgb[py * width + px]
          if case .rgb(let d, false) = layout, signal.range == .legal {
            let l = CodeRange.legal.levels(bitDepth: d)
            v = (v * Double((1 << d) - 1) - SIMD3(repeating: l.black)) / l.span
          }
          out.append((v, v.y + k.r * (v.x - v.y) + k.b * (v.z - v.y)))
          continue
        }
        let t = DecodeReference.chromaTaps(
          x: px, y: py, width: width, height: height, subsampling: layout.subsampling,
          siting: signal.chromaSiting, vertical: signal.chromaVerticalSiting)
        func c(_ plane: [Int]) -> Double {
          func at(_ x: Int, _ y: Int) -> Double { Double(plane[y * chromaWidth + x]) }
          let top = at(t.x0, t.y0) * (1 - t.fx) + at(t.x1, t.y0) * t.fx
          let bottom = at(t.x0, t.y1) * (1 - t.fx) + at(t.x1, t.y1) * t.fx
          return top * (1 - t.fy) + bottom * t.fy
        }
        let d = DecodeReference.rgb(
          lumaCode: Double(y[py * width + px]), cbCode: c(cb), crCode: c(cr), bitDepth: layout.bitDepth,
          range: signal.range, matrix: signal.matrix)
        out.append((SIMD3(d.rgb.r, d.rgb.g, d.rgb.b), d.luma))
      }
    }
    return out
  }

  // MARK: - Packing

  func chroma(_ x: Int, _ y: Int) -> (Int, Int) {
    guard x < chromaWidth, y < chromaHeight else { return (1 << (layout.bitDepth - 1), 1 << (layout.bitDepth - 1)) }
    return (cb[y * chromaWidth + x], cr[y * chromaWidth + x])
  }
  func luma(_ x: Int, _ y: Int) -> Int { x < width ? self.y[y * width + x] : 0 }

  /// One row of the packed or plane-0 bytes.
  func row(plane: Int, _ py: Int, rgbFormat: MTLPixelFormat? = nil) -> [UInt8] {
    var bytes: [UInt8] = []
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    switch layout {
    case .v210:
      for g in 0..<((width + 5) / 6) {
        let x = g * 6, c = g * 3
        let (cb0, cr0) = chroma(c, py), (cb1, cr1) = chroma(c + 1, py), (cb2, cr2) = chroma(c + 2, py)
        u32(UInt32(cb0) | UInt32(luma(x, py)) << 10 | UInt32(cr0) << 20)
        u32(UInt32(luma(x + 1, py)) | UInt32(cb1) << 10 | UInt32(luma(x + 2, py)) << 20)
        u32(UInt32(cr1) | UInt32(luma(x + 3, py)) << 10 | UInt32(cb2) << 20)
        u32(UInt32(luma(x + 4, py)) | UInt32(cr2) << 10 | UInt32(luma(x + 5, py)) << 20)
      }
    case .uyvy8, .yuyv8:
      for p in 0..<((width + 1) / 2) {
        let (b, r) = chroma(p, py)
        let y0 = UInt8(luma(p * 2, py)), y1 = UInt8(luma(p * 2 + 1, py))
        bytes += layout == .uyvy8 ? [UInt8(b), y0, UInt8(r), y1] : [y0, UInt8(b), y1, UInt8(r)]
      }
    case .biplanar(_, let d):
      let shift = d == 8 ? 0 : 16 - d
      if plane == 0 {
        for x in 0..<width { d == 8 ? bytes.append(UInt8(luma(x, py))) : u16(UInt16(luma(x, py) << shift)) }
      } else {
        for x in 0..<chromaWidth {
          let (b, r) = chroma(x, py)
          if d == 8 { bytes += [UInt8(b), UInt8(r)] } else { u16(UInt16(b << shift)); u16(UInt16(r << shift)) }
        }
      }
    case .rgb(let d, let float):
      for x in 0..<width {
        let v = rgb[py * width + x]
        let m = Double((1 << d) - 1)
        func q(_ c: Double) -> Int { Int((c * m).rounded()) }
        switch (d, float, rgbFormat) {
        case (8, false, .some(.rgba8Unorm)): bytes += [UInt8(q(v.x)), UInt8(q(v.y)), UInt8(q(v.z)), 255]
        case (8, false, _): bytes += [UInt8(q(v.z)), UInt8(q(v.y)), UInt8(q(v.x)), 255]
        case (10, false, .some(.rgb10a2Unorm)): u32(UInt32(q(v.x)) | UInt32(q(v.y)) << 10 | UInt32(q(v.z)) << 20 | 3 << 30)
        case (10, false, _): u32(UInt32(q(v.z)) | UInt32(q(v.y)) << 10 | UInt32(q(v.x)) << 20 | 3 << 30)
        case (16, false, _): for c in [v.x, v.y, v.z, 1] { u16(UInt16(q(c))) }
        case (16, true, _): for c in [v.x, v.y, v.z, 1] { u16(Float16(c).bitPattern) }
        default: for c in [v.x, v.y, v.z, 1] { u32(Float(c).bitPattern) }
        }
      }
    }
    return bytes
  }

  var planeHeights: [Int] {
    if case .biplanar = layout { return [height, chromaHeight] }
    return [height]
  }

  // MARK: - Raw textures

  func frame(_ gpu: TestGPU, signal: SignalDescription, rgbFormat: MTLPixelFormat? = nil) throws -> MonitorFrame {
    func make(_ format: MTLPixelFormat, _ w: Int, plane: Int, rows: Int) -> MTLTexture {
      let data = (0..<rows).flatMap { row(plane: plane, $0, rgbFormat: rgbFormat) }
      return data.withUnsafeBytes { gpu.texture(format, w, rows, bytes: $0, bytesPerRow: data.count / rows) }
    }
    switch layout {
    case .v210:
      return try MonitorFrame(
        layout: layout, width: width, height: height,
        packed: make(.rgba32Uint, (width + 5) / 6, plane: 0, rows: height), signal: signal)
    case .uyvy8, .yuyv8:
      return try MonitorFrame(
        layout: layout, width: width, height: height,
        packed: make(.rgba8Uint, (width + 1) / 2, plane: 0, rows: height), signal: signal)
    case .biplanar(_, let d):
      return try MonitorFrame(
        layout: layout, width: width, height: height,
        luma: make(d == 8 ? .r8Unorm : .r16Unorm, width, plane: 0, rows: height),
        chroma: make(d == 8 ? .rg8Unorm : .rg16Unorm, chromaWidth, plane: 1, rows: chromaHeight), signal: signal)
    case .rgb(let d, let float):
      let format =
        rgbFormat
        ?? (float ? (d == 16 ? .rgba16Float : .rgba32Float) : (d == 8 ? .bgra8Unorm : d == 10 ? .bgr10a2Unorm : .rgba16Unorm))
      return try MonitorFrame(
        layout: layout, width: width, height: height, luma: make(format, width, plane: 0, rows: height),
        signal: signal)
    }
  }

  // MARK: - IOSurface pixel buffers

  func pixelFormat(range: CodeRange) -> OSType? {
    let full = range == .full
    switch layout {
    case .v210: return kCVPixelFormatType_422YpCbCr10
    case .uyvy8: return kCVPixelFormatType_422YpCbCr8
    case .yuyv8: return kCVPixelFormatType_422YpCbCr8_yuvs
    case .biplanar(.s420, 8): return full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case .biplanar(.s422, 8): return full ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
    case .biplanar(.s444, 8): return full ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
    case .biplanar(.s420, 10): return full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .biplanar(.s422, 10): return full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    case .biplanar(.s444, 10): return full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
    case .biplanar(.s422, 16): return kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
    case .biplanar(.s444, 16): return kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
    case .rgb(8, false): return kCVPixelFormatType_32BGRA
    case .rgb(10, false): return kCVPixelFormatType_ARGB2101010LEPacked
    case .rgb(16, false): return kCVPixelFormatType_64RGBALE
    case .rgb(16, true): return kCVPixelFormatType_64RGBAHalf
    case .rgb(32, true): return kCVPixelFormatType_128RGBAFloat
    default: return nil
    }
  }

  /// An IOSurface-backed, Metal-compatible pixel buffer holding this picture, or nil
  /// when CoreVideo has no such format.
  func pixelBuffer(range: CodeRange) -> CVPixelBuffer? {
    guard let type = pixelFormat(range: range) else { return nil }
    var pb: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
    ]
    guard CVPixelBufferCreate(nil, width, height, type, attributes as CFDictionary, &pb) == kCVReturnSuccess,
      let pb
    else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let planar = CVPixelBufferIsPlanar(pb)
    for (plane, rows) in planeHeights.enumerated() {
      let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, plane)! : CVPixelBufferGetBaseAddress(pb)!
      let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, plane) : CVPixelBufferGetBytesPerRow(pb)
      for r in 0..<rows {
        let bytes = row(plane: plane, r)
        precondition(bytes.count <= stride)
        bytes.withUnsafeBytes { (base + r * stride).copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
      }
    }
    return pb
  }
}
