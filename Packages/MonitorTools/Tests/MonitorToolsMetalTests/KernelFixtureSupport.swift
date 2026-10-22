import Foundation
@preconcurrency import Metal
import XCTest

/// Kernel-level fixtures: raw packed or biplanar bytes (luma rows of
/// `rowBytes`, then chroma rows of `rowBytes`) uploaded into the plane
/// textures the renderer reads frames through.
enum KernelFixture {
  static func library(_ device: MTLDevice, extra: String = "") throws -> MTLLibrary {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/MonitorToolsMetal/Resources/MonitorTools.metal.txt"),
      encoding: .utf8)
    let options = MTLCompileOptions()
    options.mathMode = .safe
    return try device.makeLibrary(source: source + extra, options: options)
  }

  /// (plane0, plane1) for shader layout `format`; packed layouts reuse plane0.
  static func planes(
    _ device: MTLDevice, bytes: [UInt8], format: UInt32, width: Int, height: Int, rowBytes: Int
  ) throws -> (MTLTexture, MTLTexture) {
    func make(_ pixelFormat: MTLPixelFormat, _ w: Int, _ h: Int, offset: Int) throws -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat, width: max(1, w), height: max(1, h), mipmapped: false)
      descriptor.usage = [.shaderRead]
      let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
      bytes.withUnsafeBytes { storage in
        texture.replace(
          region: MTLRegionMake2D(0, 0, max(1, w), max(1, h)), mipmapLevel: 0,
          withBytes: storage.baseAddress!.advanced(by: offset), bytesPerRow: rowBytes)
      }
      return texture
    }
    switch format {
    case 0:
      let t = try make(.rgba32Uint, (width + 5) / 6, height, offset: 0)
      return (t, t)
    case 1:
      let t = try make(.rgba8Uint, width, height, offset: 0)
      return (t, t)
    default:
      let ten = format >= 4
      let chromaHeight = format >= 6 ? height : (height + 1) / 2
      let luma = try make(ten ? .r16Uint : .r8Uint, width, height, offset: 0)
      let chroma = try make(
        ten ? .rg16Uint : .rg8Uint, (width + 1) / 2, chromaHeight, offset: rowBytes * height)
      return (luma, chroma)
    }
  }
}
