import Metal

/// A Metal 4 encoding primitive. The caller owns parameter slices, argument
/// tables, residency and source/output lifetime through command feedback.
final class Packed422GPU4 {
  private let pipeline: MTLComputePipelineState
  private let texturePipeline: MTLComputePipelineState

  init(device: MTLDevice) throws {
    guard device.supportsFamily(.metal4) else { throw Packed422GPU.Failure.unsupportedFormat }
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor()
    libraryDescriptor.name = "Packed 8-bit 422 decode"
    libraryDescriptor.source = Packed422GPU.shader + Self.textureShader
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    let function = MTL4LibraryFunctionDescriptor()
    function.name = "unpack8Bit422"; function.library = library
    let descriptor = MTL4ComputePipelineDescriptor()
    descriptor.computeFunctionDescriptor = function
    pipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
    function.name = "unpack8Bit422Texture"
    descriptor.computeFunctionDescriptor = function
    texturePipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
  }

  func encode(encoder: MTL4ComputeCommandEncoder, table: MTL4ArgumentTable,
              parameters: MTLBuffer, parameterOffset: Int = 0,
              source: MTLBuffer, rowBytes: Int, width: Int, height: Int,
              format: Packed422Format, alphaRowBytes: Int? = nil,
              luma: MTLTexture, chroma: MTLTexture) throws {
    guard format == .twoVuy || format == .yuvs || format == .uyva else { throw Packed422GPU.Failure.unsupportedFormat }
    guard width > 0, width.isMultiple(of: 2), height > 0,
      width <= UInt32.max, height <= UInt32.max, rowBytes <= UInt32.max,
      parameterOffset >= 0, parameterOffset.isMultiple(of: 16),
      parameters.length >= 16, parameterOffset <= parameters.length - 16,
      parameters.storageMode == .shared else { throw Packed422GPU.Failure.invalidLayout }
    try format.validate(width: width, height: height, rowBytes: rowBytes,
      dataSize: source.length, alphaRowBytes: alphaRowBytes)
    guard luma.pixelFormat == .r16Uint, chroma.pixelFormat == .rg16Uint,
      luma.width == width, luma.height == height,
      chroma.width == width / 2, chroma.height == height,
      luma.usage.contains(.shaderWrite), chroma.usage.contains(.shaderWrite),
      source.device.registryID == pipeline.device.registryID,
      parameters.device.registryID == pipeline.device.registryID,
      luma.device.registryID == pipeline.device.registryID,
      chroma.device.registryID == pipeline.device.registryID else { throw Packed422GPU.Failure.invalidTexture }
    var p = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(rowBytes), format == .yuvs ? 1 : 0)
    withUnsafeBytes(of: &p) { parameters.contents().advanced(by: parameterOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    table.setAddress(source.gpuAddress, index: 0)
    table.setAddress(parameters.gpuAddress + UInt64(parameterOffset), index: 1)
    table.setTexture(luma.gpuResourceID, index: 0)
    table.setTexture(chroma.gpuResourceID, index: 1)
    encoder.setComputePipelineState(pipeline)
    encoder.setArgumentTable(table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: width / 2, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(32, pipeline.threadExecutionWidth), height: 1, depth: 1))
  }
  /// Direct packed texture path for IOSurface mapping. A four-byte texel is
  /// one two-pixel group. No staging allocation or CPU pixel access is needed.
  func encodeTexture(encoder: MTL4ComputeCommandEncoder, table: MTL4ArgumentTable,
                     parameters: MTLBuffer, parameterOffset: Int = 0,
                     source: MTLTexture, format: Packed422Format,
                     luma: MTLTexture, chroma: MTLTexture) throws {
    guard format == .twoVuy || format == .yuvs || format == .uyva else { throw Packed422GPU.Failure.unsupportedFormat }
    guard source.pixelFormat == .rgba8Uint, source.width > 0,
      source.width <= Int(UInt32.max) / 2, source.height <= UInt32.max,
      luma.pixelFormat == .r16Uint, chroma.pixelFormat == .rg16Uint,
      luma.width == source.width * 2, luma.height == source.height,
      chroma.width == source.width, chroma.height == source.height,
      source.usage.contains(.shaderRead), luma.usage.contains(.shaderWrite), chroma.usage.contains(.shaderWrite),
      parameterOffset >= 0, parameterOffset.isMultiple(of: 16), parameters.length >= 16,
      parameterOffset <= parameters.length - 16, parameters.storageMode == .shared,
      source.device.registryID == texturePipeline.device.registryID,
      luma.device.registryID == texturePipeline.device.registryID,
      chroma.device.registryID == texturePipeline.device.registryID,
      parameters.device.registryID == texturePipeline.device.registryID else { throw Packed422GPU.Failure.invalidTexture }
    var p = SIMD4<UInt32>(UInt32(luma.width), UInt32(luma.height), 0, format == .yuvs ? 1 : 0)
    withUnsafeBytes(of: &p) { parameters.contents().advanced(by: parameterOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    table.setAddress(parameters.gpuAddress + UInt64(parameterOffset), index: 1)
    table.setTexture(luma.gpuResourceID, index: 0)
    table.setTexture(chroma.gpuResourceID, index: 1)
    table.setTexture(source.gpuResourceID, index: 2)
    encoder.setComputePipelineState(texturePipeline); encoder.setArgumentTable(table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: source.width, height: source.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(32, texturePipeline.threadExecutionWidth), height: 1, depth: 1))
  }

  private static let textureShader = """
  kernel void unpack8Bit422Texture(constant uint4& p [[buffer(1)]],
      texture2d<ushort, access::write> luma [[texture(0)]],
      texture2d<ushort, access::write> chroma [[texture(1)]],
      texture2d<ushort, access::read> source [[texture(2)]],
      uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= p.x / 2 || pos.y >= p.y) return;
    ushort4 v = source.read(pos);
    ushort y0 = p.w ? v.x : v.y, y1 = p.w ? v.z : v.w;
    ushort u = p.w ? v.y : v.x, cr = p.w ? v.w : v.z;
    luma.write(ushort4(y0 << 8), uint2(pos.x * 2, pos.y));
    luma.write(ushort4(y1 << 8), uint2(pos.x * 2 + 1, pos.y));
    chroma.write(ushort4(u << 8, cr << 8, 0, 0), pos);
  }
  """

}
