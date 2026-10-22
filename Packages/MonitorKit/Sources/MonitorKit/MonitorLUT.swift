import Metal
import MonitorKitCore

/// Mirrors `mk_LUTParams` in MKLUT.msl. 16-byte rows.
public struct LUTParameters: Equatable, Sendable {
  public var domainLow: SIMD4<Float>
  public var domainScale: SIMD4<Float>
  /// x: lattice size, y: interpolation, z: enabled, w: 1D shaper entries (0 for none).
  public var shape: SIMD4<UInt32>
  /// xyz: the shaper's input minimum; w: 1 when there is no 3D table.
  public var shaperLow: SIMD4<Float>
  /// xyz: 1 / (shaper input maximum - minimum).
  public var shaperScale: SIMD4<Float>

  public init(
    domainLow: SIMD4<Float>, domainScale: SIMD4<Float>, shape: SIMD4<UInt32>, shaperLow: SIMD4<Float> = .zero,
    shaperScale: SIMD4<Float> = SIMD4(repeating: 1)
  ) {
    self.domainLow = domainLow
    self.domainScale = domainScale
    self.shape = shape
    self.shaperLow = shaperLow
    self.shaperScale = shaperScale
  }

  /// Passes RGB through unchanged.
  public static let disabled = LUTParameters(
    domainLow: .zero, domainScale: SIMD4(repeating: 1), shape: SIMD4(2, 0, 0, 0))
}

/// A LUT on the GPU: one `rgba32Float` 3D texture built once per load. Slices
/// `0..<n` hold the n³ lattice; a 1D shaper follows in further slices of the
/// texture's width × height (at least `shaperOnlyLattice`², so a small lattice
/// still fits a 65536-entry shaper), so the whole LUT is still one texture and
/// `mk_applyLUT` keeps its three arguments.
/// Immutable and safe to share across feeds, surfaces and threads.
///
/// Fused use: prepend `MonitorShaders.source([.lut])` to your kernel source,
/// bind `texture` and `parameters`, and call `mk_applyLUT(rgb, lut, params)`.
public final class MonitorLUT: @unchecked Sendable {
  public let cube: CubeLUT
  public let texture: MTLTexture
  /// The interpolation in effect. `.hardware` falls back to `.trilinear` on
  /// GPUs that cannot filter 32-bit float textures.
  public let interpolation: LUTInterpolation
  public let parameters: LUTParameters
  /// What the LUT's output means: Rec.709 display R'G'B' (MonitorKit's convention
  /// for every LUT stage; `outputEncoding.signal` tags a host's output buffer).
  public let outputEncoding: LUTOutputEncoding

  /// Lattice size of the placeholder 3D table of a 1D-only LUT, and the least
  /// width and height of a texture with a shaper: 64 entries a slice, so a
  /// 65536-entry shaper (`CubeLUT.maximumShaperSize`) takes 1024 slices, within
  /// the 2048-slice depth limit beside any lattice.
  static let shaperOnlyLattice = 8

  /// Uploads `cube`. `interpolation` defaults to tetrahedral; `.trilinear` is
  /// bit-compatible with Ultracam's original LUT shader (and with a host kernel
  /// calling `mk_applyLUT` with these `parameters`). `outputEncoding` declares what
  /// the LUT outputs; Rec.709, the default, is the only one modelled.
  public init(
    device: MTLDevice, cube: CubeLUT, interpolation: LUTInterpolation = .tetrahedral,
    outputEncoding: LUTOutputEncoding = .rec709
  ) throws {
    let n = cube.hasCube ? cube.dimension : Self.shaperOnlyLattice
    // Shaper rows are the texture's width: a small lattice sits in the corner of
    // wider slices. Without a shaper the texture is exactly the lattice.
    let side = cube.shaperSize > 0 ? max(n, Self.shaperOnlyLattice) : n
    let perSlice = side * side
    let shaperSlices = (cube.shaperSize + perSlice - 1) / perSlice
    guard n + shaperSlices <= 2048 else {
      throw MonitorKitError.gpu(
        "A \(cube.shaperSize)-entry shaper does not fit beside a \(n)³ lattice (3D textures are at most 2048 deep).")
    }
    let d = MTLTextureDescriptor()
    d.textureType = .type3D
    d.pixelFormat = .rgba32Float
    d.width = side
    d.height = side
    d.depth = n + shaperSlices
    d.usage = .shaderRead
    d.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: d) else {
      throw MonitorKitError.gpu("Cannot allocate a \(n)³ LUT texture.")
    }
    if cube.hasCube && side == n {
      cube.rgba.withUnsafeBytes { bytes in
        texture.replace(
          region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
          withBytes: bytes.baseAddress!, bytesPerRow: n * 16, bytesPerImage: n * n * 16)
      }
    } else if cube.hasCube {
      // A small lattice in wider slices: the padding repeats the edge, so hardware
      // filtering at the lattice's edge (a zero weight) reads finite values.
      var padded = [Float](repeating: 0, count: perSlice * n * 4)
      for z in 0..<n {
        for y in 0..<side {
          for x in 0..<side {
            let source = ((z * n + min(y, n - 1)) * n + min(x, n - 1)) * 4
            let target = ((z * side + y) * side + x) * 4
            for c in 0..<4 { padded[target + c] = cube.rgba[source + c] }
          }
        }
      }
      padded.withUnsafeBytes { bytes in
        texture.replace(
          region: MTLRegionMake3D(0, 0, 0, side, side, n), mipmapLevel: 0, slice: 0,
          withBytes: bytes.baseAddress!, bytesPerRow: side * 16, bytesPerImage: perSlice * 16)
      }
    }
    if shaperSlices > 0 {
      // Entry i is texel (i % w, i / w % w, n + i / w²), w the texture's width; the
      // padding repeats the last entry.
      var entries = [Float](repeating: 0, count: shaperSlices * perSlice * 4)
      for i in 0..<(shaperSlices * perSlice) {
        let source = min(i, cube.shaperSize - 1) * 3
        entries[i * 4] = cube.shaper[source]
        entries[i * 4 + 1] = cube.shaper[source + 1]
        entries[i * 4 + 2] = cube.shaper[source + 2]
        entries[i * 4 + 3] = 1
      }
      entries.withUnsafeBytes { bytes in
        texture.replace(
          region: MTLRegionMake3D(0, 0, n, side, side, shaperSlices), mipmapLevel: 0, slice: 0,
          withBytes: bytes.baseAddress!, bytesPerRow: side * 16, bytesPerImage: perSlice * 16)
      }
    }
    texture.label = "MonitorKit LUT \(cube.title)"
    let effective: LUTInterpolation =
      interpolation == .hardware && !device.supports32BitFloatFiltering ? .trilinear : interpolation
    let scale = SIMD3<Float>(repeating: 1) / (cube.domainMax - cube.domainMin)
    let shaperScale = SIMD3<Float>(repeating: 1) / (cube.shaperDomainMax - cube.shaperDomainMin)
    self.cube = cube
    self.texture = texture
    self.interpolation = effective
    self.outputEncoding = outputEncoding
    let mode: UInt32 = effective == .tetrahedral ? 0 : (effective == .trilinear ? 1 : 2)
    parameters = LUTParameters(
      domainLow: SIMD4(cube.domainMin, 0), domainScale: SIMD4(scale, 0),
      shape: SIMD4(UInt32(n), mode, 1, UInt32(cube.shaperSize)),
      shaperLow: SIMD4(cube.shaperDomainMin, cube.hasCube ? 0 : 1), shaperScale: SIMD4(shaperScale, 0))
  }

  /// Bytes of the LUT texture.
  public var memoryBytes: Int { texture.allocatedSize }
}
