import Foundation
import simd

/// How a 3D LUT is sampled between lattice points.
public enum LUTInterpolation: String, Codable, Sendable, CaseIterable {
  /// Six-tetrahedron interpolation from four lattice reads. The quality default:
  /// neutral inputs stay neutral and gradients have no trilinear "crease".
  case tetrahedral
  /// Eight explicit reads at 32-bit float. Bit-compatible with Ultracam's
  /// original LUT shader.
  case trilinear
  /// The texture unit's filter. Fastest; precision is the hardware's.
  case hardware
}

extension CubeLUT {
  /// Lattice value at integer coordinates; red varies fastest.
  @inline(__always) func lattice(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
    let i = ((z * dimension + y) * dimension + x) * 4
    return SIMD3(rgba[i], rgba[i + 1], rgba[i + 2])
  }

  /// The 1D table per channel, linear between entries, input clamped to its domain.
  /// Same Float operations as `mk_shaper`.
  public func applyShaper(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
    let m = shaperSize
    guard m > 0 else { return rgb }
    let scale = SIMD3<Float>(repeating: 1) / (shaperDomainMax - shaperDomainMin)
    let p = simd_clamp((rgb - shaperDomainMin) * scale, .zero, SIMD3(repeating: 1)) * Float(m - 1)
    var out = SIMD3<Float>()
    for c in 0..<3 {
      let i0 = Int(p[c].rounded(.down)), i1 = min(i0 + 1, m - 1)
      let t = p[c] - Float(i0)
      let a = shaper[i0 * 3 + c], b = shaper[i1 * 3 + c]
      out[c] = a + (b - a) * t
    }
    return out
  }

  /// CPU reference for the GPU sampler: the 1D table, then the 3D table.
  /// `.hardware` is evaluated as trilinear. Uses the same Float operations, in
  /// the same order, as the shader.
  public func apply(_ rgb: SIMD3<Float>, interpolation: LUTInterpolation = .tetrahedral)
    -> SIMD3<Float>
  {
    let rgb = applyShaper(rgb)
    guard hasCube else { return rgb }
    let n = dimension
    let scale = SIMD3<Float>(repeating: 1) / (domainMax - domainMin)
    var p = (rgb - domainMin) * scale
    p = simd_clamp(p, .zero, SIMD3(repeating: 1)) * Float(n - 1)
    let lo = SIMD3<Int>(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), Int(p.z.rounded(.down)))
    let hi = SIMD3<Int>(min(lo.x + 1, n - 1), min(lo.y + 1, n - 1), min(lo.z + 1, n - 1))
    let t = p - SIMD3<Float>(Float(lo.x), Float(lo.y), Float(lo.z))
    func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
    if interpolation != .tetrahedral {
      let a = mix(lattice(lo.x, lo.y, lo.z), lattice(hi.x, lo.y, lo.z), t.x)
      let b = mix(lattice(lo.x, hi.y, lo.z), lattice(hi.x, hi.y, lo.z), t.x)
      let c = mix(lattice(lo.x, lo.y, hi.z), lattice(hi.x, lo.y, hi.z), t.x)
      let d = mix(lattice(lo.x, hi.y, hi.z), lattice(hi.x, hi.y, hi.z), t.x)
      return mix(mix(a, b, t.y), mix(c, d, t.y), t.z)
    }
    let c000 = lattice(lo.x, lo.y, lo.z), c111 = lattice(hi.x, hi.y, hi.z)
    if t.x > t.y {
      if t.y > t.z {
        return (1 - t.x) * c000 + (t.x - t.y) * lattice(hi.x, lo.y, lo.z)
          + (t.y - t.z) * lattice(hi.x, hi.y, lo.z) + t.z * c111
      } else if t.x > t.z {
        return (1 - t.x) * c000 + (t.x - t.z) * lattice(hi.x, lo.y, lo.z)
          + (t.z - t.y) * lattice(hi.x, lo.y, hi.z) + t.y * c111
      } else {
        return (1 - t.z) * c000 + (t.z - t.x) * lattice(lo.x, lo.y, hi.z)
          + (t.x - t.y) * lattice(hi.x, lo.y, hi.z) + t.y * c111
      }
    } else {
      if t.z > t.y {
        return (1 - t.z) * c000 + (t.z - t.y) * lattice(lo.x, lo.y, hi.z)
          + (t.y - t.x) * lattice(lo.x, hi.y, hi.z) + t.x * c111
      } else if t.z > t.x {
        return (1 - t.y) * c000 + (t.y - t.z) * lattice(lo.x, hi.y, lo.z)
          + (t.z - t.x) * lattice(lo.x, hi.y, hi.z) + t.x * c111
      } else {
        return (1 - t.y) * c000 + (t.y - t.x) * lattice(lo.x, hi.y, lo.z)
          + (t.x - t.z) * lattice(hi.x, hi.y, lo.z) + t.z * c111
      }
    }
  }
}

/// Where a LUT applies. Monitoring tools never reach output in either case.
public enum LUTRouting: String, Codable, Sendable, CaseIterable {
  /// Monitor surfaces only (a "display LUT").
  case monitorOnly
  /// The real output feed and every preview of it.
  case burnIn
}

/// What a LUT's output values mean, declared per LUT. MonitorKit's convention is
/// that every LUT outputs Rec.709 display R'G'B' (BT.709 primaries and matrix,
/// the BT.1886 reference display, 0…1 nominal range), as camera viewing LUTs do,
/// so a LUT stage is a Rec.709 SDR picture and its luma is weighted as Rec.709.
/// It is the only encoding modelled; HDR or wide-gamut LUT outputs are not.
public enum LUTOutputEncoding: String, Codable, Sendable, CaseIterable {
  /// Rec.709 display R'G'B'. The default.
  case rec709

  /// The signal a LUT stage carries, e.g. to tag a host's processed output buffer
  /// (CoreVideo's matrix, primaries and transfer attachments) so its colour matches
  /// the monitor's. Its `range` is nominal (0…1 values); the code range is the
  /// output container's (`MonitorFrame.layout(for:)`), so a host sets it from that.
  public var signal: SignalDescription {
    switch self {
    case .rec709: return SignalDescription(range: .full, encoding: .display(.bt709), primaries: .rec709)
    }
  }
}
