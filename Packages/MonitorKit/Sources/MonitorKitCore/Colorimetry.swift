import Foundation
import simd

/// A CIE 1931 xy chromaticity.
public struct Chromaticity: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  /// CIE D65, the white of every gamut MonitorKit converts (ITU-R BT.709-6 item 1.4).
  public static let d65 = Chromaticity(x: 0.3127, y: 0.3290)

  /// XYZ with Y = 1.
  var xyz: SIMD3<Double> { SIMD3(x / y, 1, (1 - x - y) / y) }
}

/// A 3×3 colour matrix that maps RGB column vectors: `rows` are the output channels.
public struct ColorMatrix: Equatable, Sendable {
  public var red: ColorRGB
  public var green: ColorRGB
  public var blue: ColorRGB

  public init(red: ColorRGB, green: ColorRGB, blue: ColorRGB) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public static let identity = ColorMatrix(
    red: ColorRGB(r: 1, g: 0, b: 0), green: ColorRGB(r: 0, g: 1, b: 0), blue: ColorRGB(r: 0, g: 0, b: 1))

  init(_ m: simd_double3x3) {
    // simd matrices are column-major: m[column][row].
    self.init(
      red: ColorRGB(r: m[0][0], g: m[1][0], b: m[2][0]), green: ColorRGB(r: m[0][1], g: m[1][1], b: m[2][1]),
      blue: ColorRGB(r: m[0][2], g: m[1][2], b: m[2][2]))
  }

  var simd: simd_double3x3 {
    simd_double3x3(rows: [SIMD3(red.r, red.g, red.b), SIMD3(green.r, green.g, green.b), SIMD3(blue.r, blue.g, blue.b)])
  }

  public func apply(_ c: ColorRGB) -> ColorRGB {
    ColorRGB(
      r: red.r * c.r + red.g * c.g + red.b * c.b, g: green.r * c.r + green.g * c.g + green.b * c.b,
      b: blue.r * c.r + blue.g * c.g + blue.b * c.b)
  }

  public var inverse: ColorMatrix { ColorMatrix(simd.inverse) }

  /// `self` after `other`: (self · other)·c = self(other(c)).
  public func concatenating(_ other: ColorMatrix) -> ColorMatrix { ColorMatrix(simd * other.simd) }

  /// Normalized primary matrix, RGB to XYZ (SMPTE RP 177-1993 §3.3): the primaries'
  /// XYZ columns scaled so RGB = 1 is the white with Y = 1.
  public static func normalizedPrimaryMatrix(
    red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity = .d65
  ) -> ColorMatrix {
    let p = simd_double3x3(columns: (red.xyz, green.xyz, blue.xyz))
    let s = p.inverse * white.xyz
    return ColorMatrix(simd_double3x3(columns: (p.columns.0 * s.x, p.columns.1 * s.y, p.columns.2 * s.z)))
  }
}

/// Display primaries of an output or of a display-referred signal. All use a D65 white.
public enum ColorPrimaries: String, Codable, Sendable, CaseIterable {
  /// ITU-R BT.709-6 item 1.3 (also sRGB).
  case rec709
  /// Display P3: SMPTE EG 432-1 primaries with a D65 white.
  case displayP3
  /// ITU-R BT.2020-2 Table 3 (also BT.2100).
  case rec2020

  public var chromaticities: (red: Chromaticity, green: Chromaticity, blue: Chromaticity) {
    switch self {
    case .rec709: return (Chromaticity(x: 0.640, y: 0.330), Chromaticity(x: 0.300, y: 0.600), Chromaticity(x: 0.150, y: 0.060))
    case .displayP3: return (Chromaticity(x: 0.680, y: 0.320), Chromaticity(x: 0.265, y: 0.690), Chromaticity(x: 0.150, y: 0.060))
    case .rec2020: return (Chromaticity(x: 0.708, y: 0.292), Chromaticity(x: 0.170, y: 0.797), Chromaticity(x: 0.131, y: 0.046))
    }
  }

  /// RGB to XYZ.
  public var toXYZ: ColorMatrix {
    let c = chromaticities
    return .normalizedPrimaryMatrix(red: c.red, green: c.green, blue: c.blue)
  }

  /// Linear-light luminance weights: BT.709's and BT.2100's published rounded rows
  /// (the HLG OOTF is defined with BT.2100's), the derived Y row for Display P3.
  public var luminanceCoefficients: ColorRGB {
    switch self {
    case .rec709: return ColorGamut.rec709.luminanceCoefficients
    case .rec2020: return ColorGamut.rec2020.luminanceCoefficients
    case .displayP3: return toXYZ.green
    }
  }

  /// Linear RGB in `self` to linear RGB in `target`, through XYZ (same white, so
  /// every row sums to 1 and neutrals stay neutral).
  public func conversion(to target: ColorPrimaries) -> ColorMatrix {
    target == self ? .identity : target.toXYZ.inverse.concatenating(toXYZ)
  }
}

extension ColorGamut {
  /// Primaries of the gamut, each with a D65 white: Sony S-Gamut3/S-Gamut3.Cine
  /// (technical summary p.7), ARRI Wide Gamut 3 (LogC3 white paper appendix) and
  /// 4 (LogC4 specification §5), BT.709 and BT.2020.
  public var chromaticities: (red: Chromaticity, green: Chromaticity, blue: Chromaticity) {
    switch self {
    case .rec709: return ColorPrimaries.rec709.chromaticities
    case .rec2020: return ColorPrimaries.rec2020.chromaticities
    case .sGamut3:
      return (Chromaticity(x: 0.730, y: 0.280), Chromaticity(x: 0.140, y: 0.855), Chromaticity(x: 0.100, y: -0.050))
    case .sGamut3Cine:
      return (Chromaticity(x: 0.766, y: 0.275), Chromaticity(x: 0.225, y: 0.800), Chromaticity(x: 0.089, y: -0.087))
    case .arriWideGamut3:
      return (Chromaticity(x: 0.6840, y: 0.3130), Chromaticity(x: 0.2210, y: 0.8480), Chromaticity(x: 0.0861, y: -0.1020))
    case .arriWideGamut4:
      return (Chromaticity(x: 0.7347, y: 0.2653), Chromaticity(x: 0.1424, y: 0.8576), Chromaticity(x: 0.0991, y: -0.0308))
    }
  }

  public var toXYZ: ColorMatrix {
    let c = chromaticities
    return .normalizedPrimaryMatrix(red: c.red, green: c.green, blue: c.blue)
  }

  /// Scene-linear camera RGB to linear `primaries`.
  public func conversion(to primaries: ColorPrimaries) -> ColorMatrix {
    primaries.toXYZ.inverse.concatenating(toXYZ)
  }
}
