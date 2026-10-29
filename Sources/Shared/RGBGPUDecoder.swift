import Foundation
import Metal

/// Encodes RGB unpacking into an owned float texture. The caller retains the
/// input buffer through command completion; this operation never waits on GPU.
final class RGBGPUDecoder {
  private let pipeline: MTLComputePipelineState
  init(device: MTLDevice) throws {
    guard device.supportsFamily(.metal4) else { throw SourceFormatError.invalid("RGB decode requires Metal 4") }
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor()
    libraryDescriptor.source = Self.shader
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    let function = MTL4LibraryFunctionDescriptor()
    function.library = library; function.name = "decodeRGBPacked"
    let descriptor = MTL4ComputePipelineDescriptor()
    descriptor.computeFunctionDescriptor = function
    pipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
  }

  /// Resources returned here must be held through queue feedback. Caller commits
  /// and attaches the residency set to its queue before submission.
  struct EncodingResources {
    let input: MTLBuffer
    let output: MTLTexture
    let parameters: MTLBuffer
    let arguments: MTL4ArgumentTable
  }

  func encode(input: MTLBuffer, output: MTLTexture, width: Int, height: Int,
              bytesPerRow: Int, format: RGBFormat, commandBuffer: MTL4CommandBuffer,
              residency: MTLResidencySet) throws -> EncodingResources {
    let minimum = try format.minimumRowBytes(width: width)
    let (size, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    guard height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
          bytesPerRow >= minimum, bytesPerRow <= Int(UInt32.max), !overflow,
          size <= input.length, output.width == width, output.height == height,
          output.pixelFormat == .rgba32Float else { throw SourceFormatError.invalid("Invalid RGB GPU storage") }
    let device = input.device
    let values: [UInt32] = [UInt32(width), UInt32(height), UInt32(bytesPerRow), UInt32(RGBFormat.allCases.firstIndex(of: format)!)]
    guard let parameters = device.makeBuffer(bytes: values, length: 16) else { throw SourceFormatError.invalid("RGB parameters allocation failed") }
    let descriptor = MTL4ArgumentTableDescriptor()
    descriptor.maxBufferBindCount = 2; descriptor.maxTextureBindCount = 1
    let table = try device.makeArgumentTable(descriptor: descriptor)
    table.setAddress(input.gpuAddress, index: 0)
    table.setAddress(parameters.gpuAddress, index: 1)
    table.setTexture(output.gpuResourceID, index: 0)
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw SourceFormatError.invalid("RGB encoder unavailable") }
    residency.addAllocation(input); residency.addAllocation(output); residency.addAllocation(parameters)
    encoder.setComputePipelineState(pipeline); encoder.setArgumentTable(table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
    encoder.endEncoding()
    return EncodingResources(input: input, output: output, parameters: parameters, arguments: table)
  }

  private static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void decodeRGBPacked(device const uchar *bytes [[buffer(0)]], constant uint4 &p [[buffer(1)]],
                              texture2d<float, access::write> out [[texture(0)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.x || xy.y >= p.y) return;
    device const uchar *row = bytes + ulong(xy.y) * p.z;
    float4 result;
    if (p.w < 2) {
      uint i = xy.x * 4;
      result = float4(row[i], row[i+1], row[i+2], row[i+3]) / 255.0;
      if (p.w == 0) result.rgb = result.bgr;
    } else if (p.w == 2) {
      uint i = xy.x * 4;
      uint word = (uint(row[i]) << 24) | (uint(row[i+1]) << 16) | (uint(row[i+2]) << 8) | uint(row[i+3]);
      result = float4((float3((word >> 20) & 1023, (word >> 10) & 1023, word & 1023) - 64.0) / 876.0, 1.0);
    } else {
      ulong bit = ulong(xy.x) * 36;
      uint3 codes;
      for (uint c = 0; c < 3; ++c) {
        ulong b = bit + c * 12; uint shift = uint(b & 7); ulong i = b >> 3;
        uint word = uint(row[i]) | (uint(row[i+1]) << 8);
        codes[c] = (word >> shift) & 4095;
      }
      result = float4(float3(codes) / 4095.0, 1.0);
    }
    out.write(result, xy);
  }
  """
}
