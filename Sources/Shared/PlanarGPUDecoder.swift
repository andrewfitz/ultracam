import CoreVideo
import Metal

enum PlanarGPUError: Error { case invalidLayout, overflow, unsupportedSiting, unsupportedGPU, textureMismatch }

enum PlanarGPUFormat: CaseIterable, Sendable {
  case video420, full420, p216
  var lumaFormat: MTLPixelFormat { self == .p216 ? .r16Unorm : .r8Unorm }
  var chromaFormat: MTLPixelFormat { self == .p216 ? .rg16Unorm : .rg8Unorm }
  var verticalSubsampling: Int { self == .p216 ? 1 : 2 }
  var componentBytes: Int { self == .p216 ? 2 : 1 }
  struct Layout { let chromaWidth: Int; let chromaHeight: Int; let planeBytes: [Int] }
  func layout(width: Int, height: Int, strides: [Int], dataSize: Int = 0) throws -> Layout {
    guard width > 0, height > 0, strides.count == 2, dataSize >= 0 else { throw PlanarGPUError.invalidLayout }
    let cw = width / 2 + width % 2
    let ch = height / verticalSubsampling + (height % verticalSubsampling == 0 ? 0 : 1)
    let (yBytes, yOverflow) = width.multipliedReportingOverflow(by: componentBytes)
    let (uvBytes, uvOverflow) = cw.multipliedReportingOverflow(by: componentBytes * 2)
    guard !yOverflow, !uvOverflow else { throw PlanarGPUError.overflow }
    var lengths: [Int] = []
    for index in 0..<2 {
      guard strides[index] >= (index == 0 ? yBytes : uvBytes), strides[index].isMultiple(of: componentBytes) else { throw PlanarGPUError.invalidLayout }
      let (length, overflow) = strides[index].multipliedReportingOverflow(by: index == 0 ? height : ch)
      guard !overflow, length > 0 else { throw PlanarGPUError.overflow }
      lengths.append(length)
    }
    let (total, overflow) = lengths[0].addingReportingOverflow(lengths[1])
    guard !overflow, dataSize == 0 || total <= dataSize else { throw PlanarGPUError.invalidLayout }
    return Layout(chromaWidth: cw, chromaHeight: ch, planeBytes: lengths)
  }
}

struct PlanarGPUChromaLocation: Sendable {
  let x: Float; let y: Float
  init(horizontal: Colorimetry.ChromaSiting, vertical: Colorimetry.ChromaSiting) throws {
    switch horizontal { case .left: x = 0; case .center: x = 0.5; default: throw PlanarGPUError.unsupportedSiting }
    switch vertical { case .top: y = 0; case .center: y = 0.5; case .bottom: y = 1; default: throw PlanarGPUError.unsupportedSiting }
  }
}

/// Encodes normalized Y, signed Cb/Cr into rgba32Float for subsequent matrix/LUT
/// processing. The caller owns command submission and retains Resources through
/// GPU completion. This primitive alone does not qualify a format's routes.
final class PlanarGPUDecoder {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  struct Resources { let parameters: MTLBuffer; let arguments: MTL4ArgumentTable; let textures: [MTLTexture] }
  init(device: MTLDevice) throws {
    guard device.supportsFamily(.metal4) else { throw PlanarGPUError.unsupportedGPU }
    self.device = device
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor(); libraryDescriptor.source = Self.shader
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    let function = MTL4LibraryFunctionDescriptor(); function.library = library; function.name = "decodePlanar"
    let descriptor = MTL4ComputePipelineDescriptor(); descriptor.computeFunctionDescriptor = function
    pipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
  }

  func encode(luma: MTLTexture, chroma: MTLTexture, destination: MTLTexture,
    format: PlanarGPUFormat, location: PlanarGPUChromaLocation, range: Colorimetry.Range,
    command: MTL4CommandBuffer, residency: MTLResidencySet) throws -> Resources {
    guard luma.pixelFormat == format.lumaFormat, chroma.pixelFormat == format.chromaFormat,
      chroma.width == luma.width / 2 + luma.width % 2,
      chroma.height == luma.height / format.verticalSubsampling + (luma.height % format.verticalSubsampling == 0 ? 0 : 1),
      destination.pixelFormat == .rgba32Float, destination.width == luma.width, destination.height == luma.height else { throw PlanarGPUError.textureMismatch }
    // All legal-range scales use the native bit depth; P216 carries 16 valid
    // bits, not high-aligned 10-bit values. Preserve foot/headroom without clamp.
    let maximum: Float = format == .p216 ? 65535 : 255
    let scale: Float = format == .p216 ? 256 : 1
    let full = range == .full
    var parameters = [SIMD4<Float>(Float(format.verticalSubsampling), location.x, format == .p216 ? 0 : location.y, 0),
      SIMD4<Float>(full ? 0 : 16 * scale, full ? maximum : 219 * scale, 128 * scale, full ? maximum : 224 * scale),
      SIMD4<Float>(maximum, 0, 0, 0)]
    guard let buffer = device.makeBuffer(bytes: &parameters, length: MemoryLayout<SIMD4<Float>>.stride * parameters.count, options: .storageModeShared) else { throw PlanarGPUError.invalidLayout }
    let td = MTL4ArgumentTableDescriptor(); td.maxBufferBindCount = 1; td.maxTextureBindCount = 3
    let arguments = try device.makeArgumentTable(descriptor: td)
    arguments.setAddress(buffer.gpuAddress, index: 0)
    for (index, texture) in [luma, chroma, destination].enumerated() {
      arguments.setTexture(texture.gpuResourceID, index: index); residency.addAllocation(texture)
    }
    residency.addAllocation(buffer)
    guard let encoder = command.makeComputeCommandEncoder() else { throw PlanarGPUError.invalidLayout }
    encoder.setComputePipelineState(pipeline); encoder.setArgumentTable(arguments)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: destination.width, height: destination.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
    encoder.endEncoding()
    return Resources(parameters: buffer, arguments: arguments, textures: [luma, chroma, destination])
  }

  static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void decodePlanar(constant float4* p [[buffer(0)]],
    texture2d<float, access::read> y [[texture(0)]],
    texture2d<float, access::sample> uv [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]], uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= out.get_width() || pos.y >= out.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 c = (float2(pos) - p[0].yz) / float2(2.0f, p[0].x) + 0.5f;
    float2 chroma = uv.sample(s, c).rg * p[2].x;
    float luma = y.read(pos).r * p[2].x;
    out.write(float4((luma-p[1].x)/p[1].y, (chroma-p[1].z)/p[1].w, 1.0f), pos);
  }
  """
}
