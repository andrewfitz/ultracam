import Foundation
@preconcurrency import Metal
import XCTest
@testable import MonitorToolsMetal

final class TiledMonitorKernelTests: XCTestCase {
  private let scalarReference = """
  kernel void sourceFocusScalarReference(plane p0 [[texture(0)]],plane p1 [[texture(1)]],constant Params& p [[buffer(0)]],texture2d<float,access::write> mask [[texture(2)]],uint2 xy [[thread_position_in_grid]]) {
   if(xy.x>=p.width||xy.y>=p.height)return;
   uint l=xy.x?xy.x-1:0,r=min(xy.x+1,p.width-1),u=xy.y?xy.y-1:0,d=min(xy.y+1,p.height-1);
   float tl=readSignalY(p0,p1,l,u,p),tc=readSignalY(p0,p1,xy.x,u,p),tr=readSignalY(p0,p1,r,u,p);
   float ml=readSignalY(p0,p1,l,xy.y,p),mr=readSignalY(p0,p1,r,xy.y,p);
   float bl=readSignalY(p0,p1,l,d,p),bc=readSignalY(p0,p1,xy.x,d,p),br=readSignalY(p0,p1,r,d,p);
   float3 dx=float3(tr-tl,mr-ml,br-bl),dy=float3(bl-tl,bc-tc,br-tr);
   float gx=dot(dx,float3(3,10,3))/16,gy=dot(dy,float3(3,10,3))/16;
   float support=max(abs(directionalMedian(dx.x,dx.y,dx.z)),abs(directionalMedian(dy.x,dy.y,dy.z)));
   float confidence=support>p.noise?clamp((max(abs(gx),abs(gy))-p.focusThreshold)/max(.0001f,p.focusThreshold*.5f),0.0f,1.0f):0;
   mask.write(float4(confidence),xy);
  }

  // One thread per scope pixel: counts its bin over the whole sampled source
  // lattice, then the frozen scalar density, color and graticule formula.
  kernel void scopeScalarReference(plane p0 [[texture(0)]],plane p1 [[texture(1)]],constant Params& p [[buffer(0)]],texture2d<float,access::write> output [[texture(2)]],uint2 xy [[thread_position_in_grid]]){
   if(xy.x>=p.scopeWidth||xy.y>=p.scopeHeight)return;
   uint step=max(1u,p.scopeSamplingStride),phase=p.scopeSamplingPhase%(step*step);
   uint columns=p.scopeMode==1?p.scopeWidth:p.scopeWidth/3,column=xy.x%columns,channel=p.scopeMode==1?0:xy.x/columns;
   uint bin=p.scopeHeight-1-xy.y,n=0;
   for(uint y=phase/step;y<p.height;y+=step)for(uint x=phase%step;x<p.width;x+=step){
    if(x*columns/p.width!=column)continue;
    float3 rgb=readRGB(p0,p1,x,y,p);
    float value=p.scopeMode==1?signalLuma(rgb,p):rgb[channel];
    if(uint(clamp((value+.1f)/1.2f,0.0f,1.0f)*float(p.scopeHeight-1))==bin)n++;
   }
   uint low=(column*p.width+columns-1)/columns,high=((column+1)*p.width+columns-1)/columns;
   uint population=latticeCount(low,high,phase%step,step)*latticeCount(0,p.height,phase/step,step);
   float v=population?1-exp(-float(n)*p.gain*30.72f/float(population)):0;
   float3 color=p.scopeMode==1?float3(1):xy.x<columns?float3(1,.1,.1):xy.x<2*columns?float3(.1,1,.1):float3(.1,.3,1);
   float3 rendered=color*v;
   if(p.flags&ScopeGraticule){bool horizontal=xy.y==0||xy.y==21||xy.y==128||xy.y==234||xy.y==255;bool vertical=p.scopeMode==1?xy.x%192==0:xy.x%64==0;if(horizontal||vertical)rendered=max(rendered,float3(.16));}
   output.write(float4(rendered,1),xy);
  }

  """

  private func context() throws -> (MTLDevice,MTLCommandQueue,MTLLibrary) {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw XCTSkip("Metal unavailable") }
    return (device,queue,try KernelFixture.library(device,extra:scalarReference))
  }

  func testFocusMatchesFrozenScalarForAllLayoutsRangesAndThreadgroupEdges() throws {
    let (device,queue,library)=try context()
    let tiled=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"sourceFocus")))
    let scalar=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"sourceFocusScalarReference")))
    for (width,height) in [(1,1),(17,19),(31,33)] {
      for format:UInt32 in 0...7 { for full in [false,true] {
        var p=KernelParameters();p.width=UInt32(width);p.height=UInt32(height);p.format=format
        p.focusThreshold=0.17;p.noise=0.02;p.coefficients.w=full ? 1 : 0
        var rowBytes:UInt32=0
        let bytes=fixture(width:width,height:height,format:format,stride:&rowBytes)
        let planes=try KernelFixture.planes(device,bytes:bytes,format:format,width:width,height:height,rowBytes:Int(rowBytes))
        for group in [(8,8),(16,16),(32,8)] { for padded in [false,true] {
          let actual=try run(device:device,queue:queue,pipeline:tiled,parameters:p,planes:planes,outputIndex:2,width:width,height:height,format:.r8Unorm,group:group,padded:padded)
          let expected=try run(device:device,queue:queue,pipeline:scalar,parameters:p,planes:planes,outputIndex:2,width:width,height:height,format:.r8Unorm,group:group,padded:padded)
          XCTAssertEqual(actual,expected,"focus \(width)x\(height),format\(format),full\(full),group\(group),padded\(padded)")
        }}
      }}
    }
  }

  /// The fused one-pass scope (threadgroup bins per column) matches the frozen
  /// scalar population/density formula across modes, sampling phases, scope
  /// sizes and threadgroup widths.
  func testFusedScopeMatchesFrozenScalarAcrossModesPhasesAndEdges() throws {
    let (device,queue,library)=try context()
    let fused=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"scopeColumns")))
    let scalar=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"scopeScalarReference")))
    for (width,height,mode) in [(1,1,1),(17,19,1),(31,33,1),(33,19,0),(768,256,0),(768,256,1)] {
      for format:UInt32 in [0,1] {
        let pw=35,ph=21
        var rowBytes:UInt32=0
        let bytes=fixture(width:pw,height:ph,format:format,stride:&rowBytes)
        let planes=try KernelFixture.planes(device,bytes:bytes,format:format,width:pw,height:ph,rowBytes:Int(rowBytes))
        for (step,phase):(UInt32,UInt32) in [(1,0),(4,0),(4,1),(4,7),(4,15)] {
          var p=KernelParameters();p.width=UInt32(pw);p.height=UInt32(ph);p.format=format;p.coefficients.w=1
          p.scopeWidth=UInt32(width);p.scopeHeight=UInt32(height);p.scopeMode=UInt32(mode)
          p.scopeSamplingStride=step;p.scopeSamplingPhase=phase;p.gain=0.25;p.flags=phase%2 == 0 ? MonitorKernelFlag.scopeGraticule : 0
          let expected=try run(device:device,queue:queue,pipeline:scalar,parameters:p,planes:planes,outputIndex:2,width:width,height:height,format:.bgra8Unorm,group:(8,8),padded:false)
          let columns=mode == 1 ? width : width/3
          for threads in [64,256] {
            let actual=try run(device:device,queue:queue,pipeline:fused,parameters:p,planes:planes,outputIndex:2,width:width,height:height,format:.bgra8Unorm,group:(threads,1),padded:true,groups:(columns,1))
            XCTAssertEqual(actual,expected,"scope\(width)x\(height),mode\(mode),format\(format),step\(step),phase\(phase),threads\(threads)")
          }
        }
      }
    }
  }

  private func run(device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLComputePipelineState,parameters:KernelParameters,planes:(MTLTexture,MTLTexture),outputIndex:Int,width:Int,height:Int,format:MTLPixelFormat,group:(Int,Int),padded:Bool,groups:(Int,Int)?=nil) throws -> [UInt8] {
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
    descriptor.usage=[.shaderRead,.shaderWrite]
    let output=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
    let pixelBytes=format == .r8Unorm ? 1 : 4,rowBytes=((width*pixelBytes+255)/256)*256
    let readback=try XCTUnwrap(device.makeBuffer(length:rowBytes*height,options:.storageModeShared))
    var p=parameters
    let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline);encoder.setTexture(planes.0,index:0);encoder.setTexture(planes.1,index:1)
    encoder.setBytes(&p,length:MemoryLayout<KernelParameters>.stride,index:0);encoder.setTexture(output,index:outputIndex)
    let threads=MTLSize(width:group.0,height:group.1,depth:1)
    if let groups { encoder.dispatchThreadgroups(.init(width:groups.0,height:groups.1,depth:1),threadsPerThreadgroup:threads) }
    else if padded { encoder.dispatchThreadgroups(.init(width:(width+group.0-1)/group.0,height:(height+group.1-1)/group.1,depth:1),threadsPerThreadgroup:threads) }
    else { encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:threads) }
    encoder.endEncoding()
    let blit=try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(from:output,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:width,height:height,depth:1),to:readback,destinationOffset:0,destinationBytesPerRow:rowBytes,destinationBytesPerImage:rowBytes*height)
    blit.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertEqual(command.status,.completed)
    let bytes=readback.contents().assumingMemoryBound(to:UInt8.self)
    var pixels=[UInt8]();pixels.reserveCapacity(width*height*pixelBytes)
    for y in 0..<height { pixels.append(contentsOf:UnsafeBufferPointer(start:bytes+y*rowBytes,count:width*pixelBytes)) }
    return pixels
  }

  private func fixture(width:Int,height:Int,format:UInt32,stride:inout UInt32) -> [UInt8] {
    let rowBytes=format == 0 ? ((width+5)/6)*16 : format == 1 ? width*4 : ((width*2+63)/64)*64
    stride=UInt32(rowBytes)
    var bytes=[UInt8](repeating:0,count:rowBytes*height+(format<2 ? 0 : rowBytes*(format>=6 ? height : (height+1)/2)))
    if format == 0 {
      bytes.withUnsafeMutableBytes { storage in
        let words=storage.bindMemory(to:UInt32.self)
        for y in 0..<height { for group in 0..<((width+5)/6) {
          let values=(0..<6).map { UInt32((50+(group*6+$0)*79+y*31)%1024) },at=y*rowBytes/4+group*4
          words[at]=300|(values[0]<<10)|(700<<20);words[at+1]=values[1]|(400<<10)|(values[2]<<20)
          words[at+2]=600|(values[3]<<10)|(500<<20);words[at+3]=values[4]|(550<<10)|(values[5]<<20)
        }}
      }
    } else if format == 1 {
      for y in 0..<height { for x in 0..<width { let at=y*rowBytes+x*4;bytes[at]=UInt8((x*29+y*3)%256);bytes[at+1]=UInt8((x*13+y*11)%256);bytes[at+2]=UInt8((x*7+y*17)%256);bytes[at+3]=255 }}
    } else if format>=4 {
      bytes.withUnsafeMutableBytes { storage in
        let words=storage.bindMemory(to:UInt16.self)
        for y in 0..<height { for x in 0..<width { words[y*rowBytes/2+x]=UInt16((50+x*79+y*31)%1024)<<6 }}
        for i in (rowBytes*height/2)..<words.count { words[i]=UInt16(300+(i%5)*80)<<6 }
      }
    } else {
      for y in 0..<height { for x in 0..<width { bytes[y*rowBytes+x]=UInt8((20+x*19+y*11)%256) }}
      for i in (rowBytes*height)..<bytes.count { bytes[i]=UInt8(64+(i%5)*25) }
    }
    return bytes
  }
}
