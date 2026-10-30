import CoreVideo
import Foundation
import XCTest

@objcMembers final class LUTRoundTwoAuditChecks: XCTestCase {
  private func rgb(_ type: OSType, full: Bool) throws -> (CVPixelBuffer, [Double]) {
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made), bits = type == kCVPixelFormatType_32BGRA ? 8 : (type == 0x72323130 ? 10 : 12)
    let maximum = (1<<bits)-1, scale = 1<<(bits-8), black = full ? 0 : 16*scale, range = full ? maximum : 219*scale
    let levels = [black, black + (range+1)/2, black+range]
    CVPixelBufferLockBaseAddress(image, []); defer { CVPixelBufferUnlockBaseAddress(image, []) }
    let stride = CVPixelBufferGetBytesPerRow(image), bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
    for i in 0..<(stride*64) { bytes[i] = 0 }
    for y in 0..<64 { for x in 0..<128 {
      let c = levels[min(2,x*3/128)]
      if bits == 8 {
        for lane in 0..<3 { bytes[y*stride+x*4+lane] = UInt8(c) }; bytes[y*stride+x*4+3] = 255
      } else if bits == 10 {
        let word = UInt32(c)<<20 | UInt32(c)<<10 | UInt32(c)
        for lane in 0..<4 { bytes[y*stride+x*4+lane] = UInt8(truncatingIfNeeded: word >> ((3-lane)*8)) }
      } else {
        for component in 0..<3 { for bit in 0..<12 where (c & (1<<bit)) != 0 {
          let offset = x*36 + component*12 + bit
          bytes[y*stride+offset/8] |= UInt8(1<<(offset%8))
        } }
      }
    } }
    return (image, levels.map { Double($0-black)/Double(range) })
  }
  private func y(_ image: CVPixelBuffer, x: Int, row: Int) throws -> Int {
    CVPixelBufferLockBaseAddress(image,.readOnly); defer { CVPixelBufferUnlockBaseAddress(image,.readOnly) }
    let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image,0)).assumingMemoryBound(to: UInt8.self)
    return Int(p[row*CVPixelBufferGetBytesPerRowOfPlane(image,0)+x])
  }
  func testAuthoritativeRGBRangesApplyBeforeLUTAndResize() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal") }
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText(size:17,transform:{$0*$0})))
    for type: OSType in [kCVPixelFormatType_32BGRA,0x72323130,0x5231324c] {
      for full in [false,true] { for resize in [false,true] { for lut in [false,true] {
        let (source,levels) = try rgb(type,full:full)
        var config = PipelineConfiguration(applyLUT:lut,downscale:resize)
        config.resizeTarget = .hd720
        let declaration = Colorimetry(primaries:.rec709,transfer:.rec709,matrix:.identity,
          range:full ? .full : .video,horizontalChromaSiting:.unspecified,verticalChromaSiting:.unspecified)
        let output = try processor.process(source,configuration:config,declaredSourceColorimetry:declaration)
        let w = CVPixelBufferGetWidth(output),h = CVPixelBufferGetHeight(output)
        for band in 0..<3 {
          let expected = Int((16+219*(lut ? levels[band]*levels[band] : levels[band])).rounded())
          XCTAssertEqual(try y(output,x:(2*band+1)*w/6,row:h/2),expected,accuracy:1,"type=\(type) full=\(full) resize=\(resize) lut=\(lut)")
        }
        XCTAssertEqual(try LUTProcessor.sourceColorimetry(output).range,.video)
      } } }
    }
  }
  func testCatalogEncodingsSurviveEncodedDomainRepackResizeAndIdentityLUT() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal") }
    var made:CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil,128,64,kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&made),kCVReturnSuccess)
    let source = try XCTUnwrap(made)
    CVPixelBufferLockBaseAddress(source,[])
    let stride = CVPixelBufferGetBytesPerRow(source)/4
    let p = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to:UInt32.self)
    let words:[UInt32] = [512 | (502<<10) | (512<<20),502 | (512<<10) | (502<<20),512 | (502<<10) | (512<<20),502 | (512<<10) | (502<<20)]
    for row in 0..<64 { for word in 0..<stride { p[row*stride+word] = words[word%4] } }
    CVPixelBufferUnlockBaseAddress(source,[])
    let processor = try LUTProcessor()
    let p3 = SourceColorSpaceCatalog.Entry(id:"p3-native",title:"P3 preservation",color:Colorimetry(
      primaries:.p3D65,transfer:.sRGB,matrix:.rec709,range:.video,horizontalChromaSiting:.left,verticalChromaSiting:.center))
    for entry in SourceColorSpaceCatalog.entries + [p3] {
      for resize in [false,true] { for lut in [false,true] {
        var config = PipelineConfiguration(applyLUT:lut,downscale:resize)
        config.resizeTarget = .hd720; config.sourceColorimetryOverride = entry.color
        if lut { try processor.load(CubeLUT(text:cubeText()),colorSpace:LUTColorSpaceContract(input:entry.color,output:entry.color)) }
        let output = try processor.process(source,configuration:config)
        let declaration = try LUTProcessor.sourceColorimetry(output)
        XCTAssertEqual(declaration.primaries,entry.color.primaries)
        XCTAssertEqual(declaration.transfer,entry.color.transfer)
        XCTAssertEqual(declaration.matrix,lut ? entry.color.matrix : .rec709)
        XCTAssertEqual(try y(output,x:CVPixelBufferGetWidth(output)/2,row:CVPixelBufferGetHeight(output)/2),126,accuracy:1,entry.id)
      } }
    }
    let log = SourceColorSpaceCatalog.entries[1].color
    var config = PipelineConfiguration(downscale:false); config.sourceColorimetryOverride = log
    XCTAssertThrowsError(try processor.process(source,configuration:config,
      colorConversion:.sourceToLUTInput(from:log,to:.rec709Video),destinationColorimetry:.rec709Video),"Actual unsupported log→709 transform must still refuse")
  }
  func testOddHeight422DispatchWritesItsFinalRowAnd420RequiresAnEvenOutput() throws {
    guard LUTProcessor.sharedDevice != nil else { throw XCTSkip("No Metal") }
    var made:CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil,128,65,kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&made),kCVReturnSuccess)
    let source = try XCTUnwrap(made)
    CVPixelBufferLockBaseAddress(source,[])
    for plane in 0..<2 {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(source,plane)/2
      let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source,plane)).assumingMemoryBound(to:UInt16.self)
      for row in 0..<65 { for x in 0..<stride { p[row*stride+x] = UInt16(plane == 0 ? (row == 64 ? 940 : 64) : 512)<<6 } }
    }
    CVPixelBufferUnlockBaseAddress(source,[])
    let processor = try LUTProcessor()
    var config = PipelineConfiguration(downscale:false,convertTo420:false); config.sourceColorimetryOverride = .rec709Video
    let output = try processor.process(source,configuration:config)
    CVPixelBufferLockBaseAddress(output,.readOnly)
    let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output,0)).assumingMemoryBound(to:UInt16.self)
    XCTAssertEqual(p[64*CVPixelBufferGetBytesPerRowOfPlane(output,0)/2]>>6,940)
    CVPixelBufferUnlockBaseAddress(output,.readOnly)
    config.convertTo420 = true
    XCTAssertThrowsError(try processor.process(source,configuration:config))
    config.downscale = true; config.resizeTarget = .hd720
    XCTAssertNoThrow(try processor.process(source,configuration:config),"Odd input is supported when resized to an even 420 canvas")
  }
}
