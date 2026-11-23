// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// CPU reference for MKDecode.msl: the same decode in Double, used to check the GPU.
public enum DecodeReference {
  /// Range-expanded R'G'B' and Y' from luma and chroma codes of `bitDepth`.
  public static func rgb(
    lumaCode: Double, cbCode: Double, crCode: Double, bitDepth: Int, range: CodeRange,
    matrix: YCbCrMatrix
  ) -> (rgb: ColorRGB, luma: Double) {
    let l = range.levels(bitDepth: bitDepth)
    let y = (lumaCode - l.black) / l.span
    let cb = (cbCode - l.center) / l.chromaSpan, cr = (crCode - l.center) / l.chromaSpan
    let rgb = ColorMath.yCbCrToRGB(y: y, cb: cb, cr: cr, matrix: matrix) ?? ColorRGB(r: y, g: y, b: y)
    return (rgb, y)
  }

  /// Chroma samples and weights for luma pixel (x, y): linear interpolation
  /// between the two nearest chroma sites per subsampled axis, clamped at the edges.
  /// Horizontal sites are at `2i` (left) or `2i + 0.5` (centre); 4:2:0 rows at
  /// `2j + 0.5 + vertical.offset` (`2j` top, `2j + 0.5` centre, `2j + 1` bottom).
  public static func chromaTaps(
    x: Int, y: Int, width: Int, height: Int, subsampling: ChromaSubsampling, siting: ChromaSiting,
    vertical: ChromaVerticalSiting = .center
  ) -> (x0: Int, x1: Int, fx: Double, y0: Int, y1: Int, fy: Double) {
    guard subsampling != .s444 else { return (x, x, 0, y, y, 0) }
    func taps(_ pixel: Int, count: Int, site: Double) -> (Int, Int, Double) {
      // Halve the integer coordinate first so the phase survives past Double's
      // exact integer range. An arithmetic shift rounds negative pixels down.
      let phase = (Double(pixel & 1) - site) / 2
      let lower = (pixel >> 1) - (phase < 0 ? 1 : 0)
      let last = (max(1, count) - 1) / 2
      return (min(max(lower, 0), last), min(max(lower + 1, 0), last), phase < 0 ? phase + 1 : phase)
    }
    let (x0, x1, fx) = taps(x, count: width, site: siting == .center ? 0.5 : 0)
    guard subsampling == .s420 else { return (x0, x1, fx, y, y, 0) }
    let (y0, y1, fy) = taps(y, count: height, site: 0.5 + vertical.offset)
    return (x0, x1, fx, y0, y1, fy)
  }

  /// Native normalized log code (code / 1023) of a code-valued curve (S-Log3)
  /// from a range-expanded value of a `bitDepth` container (10 for float).
  /// Legal containers are exact at every depth: legal levels and camera codes
  /// both scale by 2^(n-8). A full container labelled `.fullRescaledToLegal`
  /// is assumed squeezed into its own legal range (`unsqueezeLegal`).
  public static func nativeLog(
    expanded: Double, range: CodeRange, transport: LogTransport, bitDepth: Int = 10
  ) -> Double {
    switch (range, transport) {
    case (.full, .native), (.legal, .fullRescaledToLegal): return expanded
    case (.full, .fullRescaledToLegal): return unsqueezeLegal(expanded: expanded, bitDepth: bitDepth)
    case (.legal, .native): return (expanded * 876 + 64) / 1023
    }
  }

  /// The full-range signal from a full container's range-expanded value whose
  /// codes were squeezed into that container's own legal range, 16s…235s with
  /// s = 2^(n-8) (BT.709 item 3.4): t = (e·M - 16s)/(219s), M = 2^n - 1. At 10
  /// bits, (e·1023 - 64)/876. Mirrors `mk_unsqueezeLegal`.
  public static func unsqueezeLegal(expanded: Double, bitDepth: Int = 10) -> Double {
    let maximum = pow(2, Double(bitDepth)) - 1, s = (maximum + 1) / 256
    return (expanded * maximum - 16 * s) / (219 * s)
  }
}

extension ColorMath {
  /// ITU-R BT.709 inverse OETF (the stops measure of display-referred false colour).
  public static func bt709Linear(_ v: Double) -> Double {
    v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45)
  }

  /// IEC 61966-2-1 sRGB decode.
  public static func sRGBDecode(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
  }

  /// SMPTE ST 2084 EOTF: PQ signal 0…1 to display luminance in cd/m². The signal
  /// is clipped to 0…1 (BT.2100 Table 4's domain): above it the curve leaves
  /// 10 000 cd/m², and from about 1.99 its denominator turns negative (NaN).
  public static func pqNits(_ e: Double) -> Double {
    let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
    let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
    let p = pow(min(max(0, e), 1), 1 / m2)
    return 10000 * pow(max(0, p - c1) / (c2 - c3 * p), 1 / m1)
  }

  /// ITU-R BT.2100 HLG inverse OETF: signal 0…1 to normalized scene light 0…1.
  public static func hlgInverseOETF(_ e: Double) -> Double {
    let a = 0.17883277, b = 1 - 4 * a, c = 0.5 - a * log(4 * a)
    return e <= 0.5 ? e * e / 3 : (exp((e - c) / a) + b) / 12
  }

  /// ITU-R BT.2408 reference levels: the 18% grey card is 26 cd/m² in PQ and 38% of HLG signal.
  public static let bt2408GreyNits = 26.0
  public static let bt2408HLGGreySignal = 0.38
}
