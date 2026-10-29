import Metal

/// GPU-only bridge from packed 8-bit 4:2:2 to the existing x422 texture
/// contract (10-bit codes in the most significant bits of UInt16). This does
/// no range or matrix conversion and preserves headroom/footroom exactly.
final class Packed422GPU {
  enum Failure: Error { case unsupportedFormat, invalidLayout, invalidTexture, encoderUnavailable }
  private let pipeline: MTLComputePipelineState

  init(device: MTLDevice) throws {
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    guard let function = library.makeFunction(name: "unpack8Bit422") else { throw Failure.unsupportedFormat }
    pipeline = try device.makeComputePipelineState(function: function)
  }

  func encode(commandBuffer: MTLCommandBuffer, source: MTLBuffer, rowBytes: Int,
              width: Int, height: Int, format: Packed422Format, alphaRowBytes: Int? = nil,
              luma: MTLTexture, chroma: MTLTexture) throws {
    guard format == .twoVuy || format == .yuvs || format == .uyva else { throw Failure.unsupportedFormat }
    guard width > 0, width.isMultiple(of: 2), height > 0,
      width <= UInt32.max, height <= UInt32.max, rowBytes <= UInt32.max else { throw Failure.invalidLayout }
    try format.validate(width: width, height: height, rowBytes: rowBytes, dataSize: source.length, alphaRowBytes: alphaRowBytes)
    guard luma.pixelFormat == .r16Uint, chroma.pixelFormat == .rg16Uint,
      luma.width == width, luma.height == height,
      chroma.width == width / 2, chroma.height == height,
      luma.usage.contains(.shaderWrite), chroma.usage.contains(.shaderWrite),
      source.device.registryID == pipeline.device.registryID,
      luma.device.registryID == pipeline.device.registryID,
      chroma.device.registryID == pipeline.device.registryID else { throw Failure.invalidTexture }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw Failure.encoderUnavailable }
    var parameters = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(rowBytes), format == .yuvs ? 1 : 0)
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(source, offset: 0, index: 0)
    encoder.setBytes(&parameters, length: MemoryLayout.size(ofValue: parameters), index: 1)
    encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
    encoder.dispatchThreads(MTLSize(width: width / 2, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(32, pipeline.threadExecutionWidth), height: 1, depth: 1))
    encoder.endEncoding()
  }

  // Byte order: Apple's CoreVideo/CVPixelBuffer.h (2vuy/yuvs).
  // UYVA physical planes: https://docs.ndi.video/all/developing-with-ndi/sdk/frame-types
  // Alpha is deliberately ignored by the v1 pipeline.
  static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void unpack8Bit422(device const uchar* source [[buffer(0)]],
                           constant uint4& p [[buffer(1)]],
                           texture2d<ushort, access::write> luma [[texture(0)]],
                           texture2d<ushort, access::write> chroma [[texture(1)]],
                           uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= p.x / 2 || pos.y >= p.y) return;
    const ulong offset = ulong(pos.y) * ulong(p.z) + ulong(pos.x) * 4;
    ushort a = ushort(source[offset]), b = ushort(source[offset + 1]);
    ushort c = ushort(source[offset + 2]), d = ushort(source[offset + 3]);
    ushort y0 = p.w ? a : b, y1 = p.w ? c : d;
    ushort u = p.w ? b : a, v = p.w ? d : c;
    luma.write(ushort4(y0 << 8), uint2(pos.x * 2, pos.y));
    luma.write(ushort4(y1 << 8), uint2(pos.x * 2 + 1, pos.y));
    chroma.write(ushort4(u << 8, v << 8, 0, 0), pos);
  }
  """
}
