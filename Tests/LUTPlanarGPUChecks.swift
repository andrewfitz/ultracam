import CoreVideo
import XCTest

@objcMembers final class LUTPlanarGPUChecks: XCTestCase {
  func testPlanarFormatsExecuteThroughNonlinearLUTWithNativeRanges() throws {
    for type: OSType in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 0x50323136] {
      let source = try graySource(type: type)
      let sourceColour = try LUTProcessor.sourceColorimetry(source)
      let processor = try LUTProcessor()
      try processor.load(CubeLUT(text: cubeText(size: 17, transform: { $0 * $0 })),
        colorSpace: LUTColorSpaceContract(input: sourceColour, output: .rec709Video))
      let output = try processor.process(source, configuration: PipelineConfiguration(applyLUT: true, downscale: false))
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Int(p[64]), 71, accuracy: 1, "Format \(type) must decode at native bit depth/range before applying LUT")
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
  }

  func testDeclaredPlanarRangeAndSitingConfigureDecodeBeforeAllocation() throws {
    let source = try graySource(type: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    var parameters = LUTProcessor.parameters(for: source, matrix: nil, lut: nil)
    let colour = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .bottom)
    try LUTProcessor.configurePlanarParameters(&parameters, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, colour: colour)
    XCTAssertEqual(parameters.decodeRange, SIMD4<Float>(0, 255, 128, 255))
    XCTAssertEqual(parameters.chroma, SIMD4<Float>(0.5, 1, 255, 2))
  }

  func testPlanarSourceChromaAttachmentsChangeActualGPUReconstruction() throws {
    let source = try graySource(type: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    CVPixelBufferLockBaseAddress(source, [])
    let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 1)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
    for row in 0..<CVPixelBufferGetHeightOfPlane(source, 1) {
      for column in 0..<CVPixelBufferGetWidthOfPlane(source, 1) {
        p[row * stride + column * 2] = column == 0 ? 128 : 160
      }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    let processor = try LUTProcessor()
    var configuration = PipelineConfiguration(applyLUT: false, downscale: false)
    configuration.colorTarget = .yuv4228
    for (location, expected) in [(kCVImageBufferChromaLocation_Left, 136), (kCVImageBufferChromaLocation_Center, 132)] {
      CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate)
      let output = try processor.process(source, configuration: configuration)
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 1)).assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Int(uv[0]), expected, accuracy: 1)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
    CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_TopLeft, .shouldPropagate)
    XCTAssertEqual(try LUTProcessor.sourceColorimetry(source).verticalChromaSiting, .top)
    var plain: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &plain), kCVReturnSuccess)
    let unknown = try XCTUnwrap(plain)
    CVBufferSetAttachment(unknown, kCVImageBufferChromaLocationTopFieldKey, "unknown-location" as CFString, .shouldPropagate)
    XCTAssertThrowsError(try LUTProcessor.sourceColorimetry(unknown))
  }

  private func graySource(type: OSType) throws -> CVPixelBuffer {
    if type == 0x50323136 {
      let base = try XCTUnwrap(CVPixelFormatDescriptionCreateWithPixelFormatType(nil, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange))
      var description = base as! [String: Any]
      description[kCVPixelFormatConstant as String] = type
      CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(description as CFDictionary, type)
    }
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image), kCVReturnSuccess)
    let source = try XCTUnwrap(image)
    CVPixelBufferLockBaseAddress(source, [])
    defer { CVPixelBufferUnlockBaseAddress(source, []) }
    for plane in 0..<2 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane))
      let count = CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane)
      if type == 0x50323136 {
        let p = base.assumingMemoryBound(to: UInt16.self)
        for i in 0..<count / 2 { p[i] = plane == 0 ? 32128 : 32768 }
      } else {
        let p = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count { p[i] = plane == 0 ? (type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 128 : 126) : 128 }
      }
    }
    return source
  }
}
