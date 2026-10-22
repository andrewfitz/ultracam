import Foundation
import Metal

/// MonitorKit's Metal sources. They compile at runtime with the system's Metal
/// compiler, so neither the library nor its hosts need the Metal toolchain.
public enum MonitorShaders {
  public enum Part: String, CaseIterable, Sendable {
    /// `mk_LUTParams`, `mk_applyLUT`. Self-contained: prepend to a host kernel
    /// source to burn a LUT in with no extra pass.
    case lut = "MKLUT"
    /// `mk_FrameParams`, `mk_decodeRGB`, `mk_decodeLuma`, `mk_nativeLog`.
    case decode = "MKDecode"
    /// The picture pass (`mk_filtered`, `mk_stages`, false colour, overlays) and
    /// focus analysis. Compiled on its own every tool tier is on.
    case monitor = "MKMonitor"
  }

  /// Source text of `parts`, in order, as one compilation unit.
  public static func source(_ parts: [Part]) throws -> String {
    try parts.map { part in
      guard let url = Bundle.module.url(forResource: part.rawValue, withExtension: "msl", subdirectory: "Shaders")
        ?? Bundle.module.url(forResource: part.rawValue, withExtension: "msl")
      else { throw MonitorKitError.gpu("MonitorKit shader \(part.rawValue) is missing from the bundle.") }
      return try String(contentsOf: url, encoding: .utf8)
    }.joined(separator: "\n")
  }

  /// Compiles `parts` for `device`, with `prefix` before them (e.g. macro
  /// definitions) and `extra` host source after.
  public static func makeLibrary(device: MTLDevice, parts: [Part], prefix: String = "", extra: String = "")
    throws -> MTLLibrary
  {
    let options = MTLCompileOptions()
    options.mathMode = .safe
    // MSL 4.1 on macOS/iOS 27; 4.0 is the floor.
    if #available(macOS 27.0, iOS 27.0, *) {
      options.languageVersion = .version4_1
    } else {
      options.languageVersion = .version4_0
    }
    return try device.makeLibrary(source: prefix + "\n" + (try source(parts)) + "\n" + extra, options: options)
  }
}
