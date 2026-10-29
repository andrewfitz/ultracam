import Metal

/// I420/PA16 source decoder. V1 explicitly ignores alpha in PA16 rather than
/// treating it as premultiplied, while retaining its storage through completion.
final class NDIPlanarGPUDecoder {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  struct Resources { let textures: [MTLTexture]; let parameters: MTLBuffer; let arguments: MTL4ArgumentTable }
  init(device: MTLDevice) throws {
    guard device.supportsFamily(.metal4) else { throw PlanarGPUError.unsupportedGPU }
    self.device = device
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let ld = MTL4LibraryDescriptor(); ld.source = Self.shader
    let library = try compiler.makeLibrary(descriptor: ld)
    let function = MTL4LibraryFunctionDescriptor(); function.library = library; function.name = "decodeNDIPlanar"
    let pd = MTL4ComputePipelineDescriptor(); pd.computeFunctionDescriptor = function
    pipeline = try compiler.makeComputePipelineState(descriptor: pd)
  }
  func encode(planes: [MTLTexture], destination: MTLTexture, layout: NDIPlanarLayout,
    location: PlanarGPUChromaLocation, range: Colorimetry.Range,
    command: MTL4CommandBuffer, residency: MTLResidencySet) throws -> Resources {
    guard planes.count == 3, destination.pixelFormat == .rgba32Float else { throw PlanarGPUError.textureMismatch }
    let descriptors = try layout.planes(width: destination.width, height: destination.height)
    for index in descriptors.indices {
      let d = descriptors[index]
      let expected: MTLPixelFormat = d.componentBytes == 1 ? .r8Unorm : (d.components == 2 ? .rg16Unorm : .r16Unorm)
      guard planes[index].width == d.width, planes[index].height == d.height, planes[index].pixelFormat == expected,
        planes[index].device === device else { throw PlanarGPUError.textureMismatch }
    }
    guard destination.device === device else { throw PlanarGPUError.textureMismatch }
    let sixteen = layout == .pa16, full = range == .full
    let scale: Float = sixteen ? 256 : 1, maximum: Float = sixteen ? 65535 : 255
    let values = [SIMD4<Float>(sixteen ? 1 : 2, location.x, sixteen ? 0 : location.y, sixteen ? 1 : 0),
      SIMD4<Float>(full ? 0 : 16 * scale, full ? maximum : 219 * scale, 128 * scale, full ? maximum : 224 * scale),
      SIMD4<Float>(maximum, 0, 0, 0)]
    guard let parameters = device.makeBuffer(bytes: values, length: values.count * 16) else { throw PlanarGPUError.invalidLayout }
    let td = MTL4ArgumentTableDescriptor(); td.maxBufferBindCount = 1; td.maxTextureBindCount = 4
    let arguments = try device.makeArgumentTable(descriptor: td)
    arguments.setAddress(parameters.gpuAddress, index: 0); residency.addAllocation(parameters)
    for (index, texture) in (planes + [destination]).enumerated() {
      arguments.setTexture(texture.gpuResourceID, index: index); residency.addAllocation(texture)
    }
    guard let encoder = command.makeComputeCommandEncoder() else { throw PlanarGPUError.invalidLayout }
    encoder.setComputePipelineState(pipeline); encoder.setArgumentTable(arguments)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: destination.width, height: destination.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
    encoder.endEncoding()
    return Resources(textures: planes + [destination], parameters: parameters, arguments: arguments)
  }
  private static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void decodeNDIPlanar(constant float4* p [[buffer(0)]], texture2d<float,access::read> y [[texture(0)]],
    texture2d<float,access::sample> u [[texture(1)]], texture2d<float,access::sample> v [[texture(2)]],
    texture2d<float,access::write> out [[texture(3)]], uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= out.get_width() || pos.y >= out.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 coordinate = (float2(pos) - p[0].yz) / float2(2.0f,p[0].x) + .5f;
    float2 c = p[0].w == 1.0f ? u.sample(s,coordinate).rg : float2(u.sample(s,coordinate).r,v.sample(s,coordinate).r);
    float l = y.read(pos).r * p[2].x;
    out.write(float4((l-p[1].x)/p[1].y,(c*p[2].x-p[1].z)/p[1].w,1.0f),pos);
  }
  """
}
