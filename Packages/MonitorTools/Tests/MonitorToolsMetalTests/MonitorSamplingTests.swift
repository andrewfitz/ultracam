import Foundation
@preconcurrency import Metal
import XCTest
@testable import MonitorToolsMetal

final class MonitorSamplingTests: XCTestCase {
  private func context(extra: String = "") throws -> (MTLDevice, MTLCommandQueue, MTLLibrary) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("Metal unavailable") }
    return (device, queue, try KernelFixture.library(device, extra: extra))
  }

  /// The fused scope counts each pixel of its sampling lattice exactly once:
  /// at stride 1 (production) every pixel, and across all phases of a 4×4
  /// lattice every pixel exactly once in total. Checked against a CPU oracle
  /// of the bins and the scope density formula, including partial edge cells.
  func testScopeLatticeCountsEveryPixelOnceIncludingPartialEdgeCells() throws {
    let (device, queue, library) = try context()
    let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "scopeColumns")))
    let w = 13, h = 7
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    var channelsAt = [[UInt8]](repeating: [], count: w * h)
    for y in 0..<h { for x in 0..<w {
      let channels = [UInt8((x * 17 + y * 7) % 256),UInt8((x * 3 + y * 31) % 256),UInt8((x * 11 + y * 13) % 256)]
      let at = (y*w+x)*4
      bytes[at] = channels[2]; bytes[at+1] = channels[1]; bytes[at+2] = channels[0]; bytes[at+3] = 255
      channelsAt[y*w+x] = channels
    }}
    let planes = try KernelFixture.planes(device, bytes: bytes, format: 1, width: w, height: h, rowBytes: w * 4)
    func bins(step: Int, phase: Int) -> [UInt32] {
      var result = [UInt32](repeating: 0, count: 768 * 256)
      for y in stride(from: phase / step, to: h, by: step) { for x in stride(from: phase % step, to: w, by: step) {
        for c in 0..<3 {
          let bin = Int(min(1,max(0,(Float(channelsAt[y*w+x][c])/255+0.1)/1.2))*255)
          result[bin*768+c*256+x*256/w] += 1
        }
      }}
      return result
    }
    // Every pixel exactly once across the phase cycle, and at stride 1.
    var union = [UInt32](repeating: 0, count: 768 * 256)
    for phase in 0..<16 { for (i, v) in bins(step: 4, phase: phase).enumerated() { union[i] += v } }
    XCTAssertEqual(union, bins(step: 1, phase: 0))
    XCTAssertEqual(union.reduce(0,+), UInt32(w*h*3))
    for (step, phases) in [(1, [0]), (4, Array(0..<16))] { for phase in phases {
      var p = KernelParameters(); p.width = UInt32(w); p.height = UInt32(h); p.format = 1; p.coefficients.w = 1
      p.scopeSamplingStride = UInt32(step); p.scopeSamplingPhase = UInt32(phase); p.gain = 1; p.flags = 0
      let image = try scope(device, queue, pipeline, planes, p)
      let expected = bins(step: step, phase: phase)
      for y in 0..<256 { for x in 0..<768 {
        let column = x % 256, channel = x / 256
        let low = (column*w+255)/256, high = ((column+1)*w+255)/256
        func lattice(_ low: Int, _ high: Int, _ offset: Int) -> Int {
          let begin = low > offset ? (low-offset+step-1)/step : 0
          let end = high > offset ? (high-offset+step-1)/step : 0
          return max(0, end-begin)
        }
        let population = lattice(low, high, phase % step) * lattice(0, h, phase / step)
        let n = Float(expected[(255-y)*768+x])
        let v: Float = population > 0 ? 1-exp(-n*30.72/Float(population)) : 0
        let color: [Float] = channel == 0 ? [1,0.1,0.1] : channel == 1 ? [0.1,1,0.1] : [0.1,0.3,1]
        let at = (y*768+x)*4
        for (offset, component) in [color[2], color[1], color[0]].enumerated() {
          XCTAssertEqual(Int(image[at+offset]), Int((component*v*255).rounded()), accuracy: 1,
            "step \(step), phase \(phase), scope (\(x),\(y))")
        }
      }}
    }}
  }

  private func scope(_ device: MTLDevice, _ queue: MTLCommandQueue, _ pipeline: MTLComputePipelineState,
    _ planes: (MTLTexture, MTLTexture), _ parameters: KernelParameters) throws -> [UInt8] {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 768, height: 256, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    var p = parameters
    let command = try XCTUnwrap(queue.makeCommandBuffer()), encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline); encoder.setTexture(planes.0, index: 0); encoder.setTexture(planes.1, index: 1)
    encoder.setBytes(&p, length: MemoryLayout<KernelParameters>.stride, index: 0); encoder.setTexture(output, index: 2)
    encoder.dispatchThreadgroups(.init(width: 256, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted(); XCTAssertEqual(command.status, .completed)
    var bytes = [UInt8](repeating: 0, count: 768 * 256 * 4)
    output.getBytes(&bytes, bytesPerRow: 768 * 4, from: MTLRegionMake2D(0, 0, 768, 256), mipmapLevel: 0)
    return bytes
  }

  func testDirectYMatchesMatrixWeightedRGBForEverySupportedLayoutAndRange() throws {
    let extra = """
    kernel void verifyY(plane p0 [[texture(0)]],plane p1 [[texture(1)]],constant Params& p [[buffer(0)]],device float2* values [[buffer(2)]],uint2 xy [[thread_position_in_grid]]) {
      if(xy.x<p.width&&xy.y<p.height)values[xy.y*p.width+xy.x]=float2(readSignalY(p0,p1,xy.x,xy.y,p),signalLuma(readRGB(p0,p1,xy.x,xy.y,p),p));
    }
    """
    let (device,queue,library) = try context(extra: extra)
    let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "verifyY")))
    for format: UInt32 in 0...7 { for full in [false,true] { for coefficients in [SIMD4<Float>(0.2126,0.7152,0.0722,0),SIMD4<Float>(0.2627,0.678,0.0593,0)] {
      let w = 12,h = 4,stride = format == 0 ? 32 : format == 1 ? 48 : format >= 4 ? 32 : 16
      var bytes = [UInt8](repeating: 0,count: stride*h + (format < 2 ? 0 : stride*(format>=6 ? h : h/2)))
      if format == 0 {
        bytes.withUnsafeMutableBytes { storage in
          let words = storage.bindMemory(to: UInt32.self)
          for y in 0..<h { for group in 0..<2 {
            let yv = (0..<6).map { UInt32((50+(group*6+$0)*79+y*31)%1024) }
            let base = y*stride/4+group*4
            words[base] = 300 | (yv[0]<<10) | (700<<20)
            words[base+1] = yv[1] | (400<<10) | (yv[2]<<20)
            words[base+2] = 600 | (yv[3]<<10) | (500<<20)
            words[base+3] = yv[4] | (550<<10) | (yv[5]<<20)
          }}
        }
      } else if format == 1 {
        for y in 0..<h { for x in 0..<w { let at=y*stride+x*4;bytes[at]=UInt8((x*29+y*3)%256);bytes[at+1]=UInt8((x*13+y*11)%256);bytes[at+2]=UInt8((x*7+y*17)%256);bytes[at+3]=255 }}
      } else if format >= 4 {
        bytes.withUnsafeMutableBytes { storage in
          let words = storage.bindMemory(to: UInt16.self)
          for y in 0..<h { for x in 0..<w { words[y*stride/2+x]=UInt16((50+x*79+y*31)%1024)<<6 }}
          for i in (stride*h/2)..<words.count { words[i]=UInt16(300+(i%5)*80)<<6 }
        }
      } else {
        for y in 0..<h { for x in 0..<w { bytes[y*stride+x]=UInt8((20+x*19+y*11)%256) }}
        for i in (stride*h)..<bytes.count { bytes[i]=UInt8(64+(i%5)*25) }
      }
      let planes = try KernelFixture.planes(device, bytes: bytes, format: format, width: w, height: h, rowBytes: stride)
      let output = try XCTUnwrap(device.makeBuffer(length:w*h*8,options:.storageModeShared))
      var p=KernelParameters();p.width=UInt32(w);p.height=UInt32(h);p.format=format;p.coefficients=coefficients;p.coefficients.w=full ? 1 : 0
      let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
      encoder.setComputePipelineState(pipeline);encoder.setTexture(planes.0,index:0);encoder.setTexture(planes.1,index:1);encoder.setBytes(&p,length:MemoryLayout<KernelParameters>.stride,index:0);encoder.setBuffer(output,offset:0,index:2)
      encoder.dispatchThreads(.init(width:w,height:h,depth:1),threadsPerThreadgroup:.init(width:4,height:4,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertEqual(command.status,.completed)
      let values=output.contents().assumingMemoryBound(to:SIMD2<Float>.self)
      for i in 0..<(w*h) { XCTAssertEqual(values[i].x,values[i].y,accuracy:0.000002,"format \(format),full \(full),pixel \(i)") }
    }}}
  }
}
