import Foundation
import Metal
import XCTest

@objcMembers final class LUTShaderGoldenChecks: XCTestCase {
  func testHDRAndSDRConversionsExecuteInLinearLightOnGPU() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 unavailable") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let lut = try String(contentsOf: root.appendingPathComponent("Packages/MonitorKit/Sources/MonitorKit/Shaders/MKLUT.msl"), encoding: .utf8)
    let shader = try String(contentsOf: root.appendingPathComponent("Sources/App/LUTShaders.metal"), encoding: .utf8)
    let test = """
    kernel void checkConversions(device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
      if (i == 0) out[0] = float4(convertColour(float3(.5080784215f), uint4(4,1,0,0)), 1);
      if (i == 1) out[1] = float4(convertColour(convertColour(float3(.18f,.4f,.7f), uint4(2,4,1,0)), uint4(4,2,2,0)), 1);
      if (i == 2) out[2] = float4(convertColour(convertColour(float3(.18f,.4f,.7f), uint4(2,5,1,0)), uint4(5,2,2,0)), 1);
    }
    """
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let ld = MTL4LibraryDescriptor(); ld.source = lut + shader + test
    let library = try compiler.makeLibrary(descriptor: ld)
    let function = MTL4LibraryFunctionDescriptor(); function.library = library; function.name = "checkConversions"
    let pd = MTL4ComputePipelineDescriptor(); pd.computeFunctionDescriptor = function
    let pipeline = try compiler.makeComputePipelineState(descriptor: pd)
    let buffer = try XCTUnwrap(device.makeBuffer(length: 48, options: .storageModeShared))
    let td = MTL4ArgumentTableDescriptor(); td.maxBufferBindCount = 1
    let table = try device.makeArgumentTable(descriptor: td); table.setAddress(buffer.gpuAddress, index: 0)
    let allocator = try XCTUnwrap(device.makeCommandAllocator())
    let command = try XCTUnwrap(device.makeCommandBuffer()); command.beginCommandBuffer(allocator: allocator)
    let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline); encoder.setArgumentTable(table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: 3, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 3, height: 1, depth: 1))
    encoder.endEncoding(); command.endCommandBuffer()
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor()); residency.addAllocation(buffer); residency.commit()
    let queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor()); queue.addResidencySet(residency)
    let done = DispatchSemaphore(value: 0); let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in XCTAssertNil(feedback.error); done.signal() }
    queue.commit([command], options: options)
    XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
    withExtendedLifetime((table, command, allocator)) {}
    let values = buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
    for component in 0..<3 { XCTAssertEqual(values[0][component], 1, accuracy: 0.001) }
    for row in 1...2 {
      XCTAssertEqual(values[row].x, 0.18, accuracy: 0.001)
      XCTAssertEqual(values[row].y, 0.4, accuracy: 0.001)
      XCTAssertEqual(values[row].z, 0.7, accuracy: 0.001)
    }
    queue.removeResidencySet(residency)
  }
}
