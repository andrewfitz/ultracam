import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
import XCTest

@objcMembers final class PlanarRecordingConverterChecks: XCTestCase {
  func testFullRange420GPUMapsBlackWhiteAndNeutralIntoVideoRange() throws {
    let converter = try makeConverter()
    let source = try image(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    let destination = try image(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    try fill(source, codes: [0, 16, 128, 235, 255], neutral: 128)
    CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    try converter.convert(source, into: destination)
    try check(destination, expected: [16, 30, 126, 218, 235], neutral: 128)
    var description: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: destination, formatDescriptionOut: &description), noErr)
    XCTAssertNotEqual(CMFormatDescriptionGetExtension(try XCTUnwrap(description), extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool, true)
    XCTAssertEqual(CVBufferCopyAttachment(destination, kCVImageBufferYCbCrMatrixKey, nil) as? String, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
    try encode(destination, codec: kCMVideoCodecType_HEVC, profile: kVTProfileLevel_HEVC_Main_AutoLevel)
  }

  func testAuthoritativeFullRange420vRequantizesIntoDistinctVideoStorage() throws {
    let converter = try makeConverter()
    let source = try image(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let destination = try image(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    try fill(source, codes: [0, 16, 128, 235, 255], neutral: 128)
    CVBufferSetAttachment(source, kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanTrue, .shouldPropagate)
    try converter.convert(source, sourceRange: .full, into: destination)
    XCTAssertFalse(source === destination)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(source), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    try check(source, expected: [0, 16, 128, 235, 255], neutral: 128)
    try check(destination, expected: [16, 30, 126, 218, 235], neutral: 128)
    var description: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: destination,
      formatDescriptionOut: &description), noErr)
    XCTAssertNotEqual(CMFormatDescriptionGetExtension(try XCTUnwrap(description),
      extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool, true)
    XCTAssertNotEqual(CVBufferCopyAttachment(destination, kCMFormatDescriptionExtension_FullRangeVideo, nil) as? Bool, true)
    try encode(destination, codec: kCMVideoCodecType_HEVC, profile: kVTProfileLevel_HEVC_Main_AutoLevel)
    XCTAssertThrowsError(try converter.convert(source, sourceRange: .full, into: source),
      "Range mapping must never mutate capture storage in place")
    XCTAssertEqual(converter.budget.snapshot().bytes, 0)
  }

  func testP216GPUQuantizesAllNativeLowBitsAndEncodersAcceptX422() throws {
    let converter = try makeConverter()
    let source = try image(0x50323136)
    let destination = try image(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    try fill(source, codes: [0, 4096, 4127, 4128, 65535], neutral: 32768)
    try converter.convert(source, into: destination)
    try check(destination, expected: [0, 4096, 4096, 4160, 65472], neutral: 32768)
    try encode(destination, codec: kCMVideoCodecType_AppleProRes422HQ, profile: nil)
    try encode(destination, codec: kCMVideoCodecType_HEVC, profile: kVTProfileLevel_HEVC_Main42210_AutoLevel)
  }

  func testNative420VideoIsAcceptedByHEVCMainWithoutConversion() throws {
    let source = try image(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    try fill(source, codes: [16, 64, 126, 192, 235], neutral: 128)
    try encode(source, codec: kCMVideoCodecType_HEVC, profile: kVTProfileLevel_HEVC_Main_AutoLevel)
  }

  func testDeclaredFullRangeP216ExpandsToEncoderVideoLevels() throws {
    let converter = try makeConverter()
    let source = try image(0x50323136)
    let destination = try image(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    try fill(source, codes: [0, 16384, 32768, 49152, 65535], neutral: 32768)
    try converter.convert(source, sourceRange: .full, into: destination)
    try check(destination, expected: [4096, 18112, 32128, 46144, 60160], neutral: 32768)
  }

  func testI420SeparateUVPlanesBecomeNative420vAndEncodeWithoutRelabeling() throws {
    let converter = try makeConverter()
    let source = try image(0x49343230)
    let destination = try image(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertEqual(CVPixelBufferGetPlaneCount(source), 3)
    CVPixelBufferLockBaseAddress(source, [])
    for plane in 0..<3 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane), rows = CVPixelBufferGetHeightOfPlane(source, plane)
      memset(base, 0xA5, stride * rows)
      for row in 0..<rows { for x in 0..<CVPixelBufferGetWidthOfPlane(source, plane) {
        base.storeBytes(of: UInt8(plane == 0 ? 126 : (plane == 1 ? 80 : 176)), toByteOffset: row * stride + x, as: UInt8.self)
      } }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    try converter.convert(source, into: destination)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(source), 0x49343230)
    CVPixelBufferLockBaseAddress(destination, .readOnly)
    let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(destination, 1)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
    for row in 0..<32 { for x in 0..<160 {
      XCTAssertEqual(uv[row * stride + 2 * x], 80)
      XCTAssertEqual(uv[row * stride + 2 * x + 1], 176)
    } }
    CVPixelBufferUnlockBaseAddress(destination, .readOnly)
    try encode(destination, codec: kCMVideoCodecType_HEVC, profile: kVTProfileLevel_HEVC_Main_AutoLevel)
  }

  func testPA16AlphaIsRetainedAndIgnoredWhileNative16VideoQuantizesToX422() throws {
    let converter = try makeConverter()
    let source = try image(0x50413136)
    let destination = try image(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    XCTAssertEqual(CVPixelBufferGetPlaneCount(source), 3)
    try fill(source, codes: [0, 4096, 4127, 4128, 65535], neutral: 32768)
    CVPixelBufferLockBaseAddress(source, [])
    let alpha = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 2)).assumingMemoryBound(to: UInt16.self)
    let alphaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 2) / 2
    for row in 0..<64 { for x in 0..<320 { alpha[row * alphaStride + x] = x.isMultiple(of: 2) ? 0 : 65535 } }
    CVPixelBufferUnlockBaseAddress(source, [])
    try converter.convert(source, into: destination)
    try check(destination, expected: [0, 4096, 4096, 4160, 65472], neutral: 32768)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(source), 0x50413136)
    CVPixelBufferLockBaseAddress(source, .readOnly)
    for row in 0..<64 { for x in 0..<320 { XCTAssertEqual(alpha[row * alphaStride + x], x.isMultiple(of: 2) ? 0 : 65535) } }
    CVPixelBufferUnlockBaseAddress(source, .readOnly)
    try encode(destination, codec: kCMVideoCodecType_AppleProRes422HQ, profile: nil)
  }

  func testFullRangeChromaExtremesAndDeclaredRangeOverrideUseCorrectCodes() throws {
    let converter = try makeConverter()
    let source = try image(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    let destination = try image(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    try fill(source, codes: [0, 64, 128, 192, 255], neutral: 128)
    CVPixelBufferLockBaseAddress(source, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 1)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
    let codes: [UInt8] = [0, 64, 128, 192, 255]
    for row in 0..<32 { for column in 0..<320 { base[row * stride + column] = codes[column / 64] } }
    CVPixelBufferUnlockBaseAddress(source, [])
    try converter.convert(source, into: destination)
    CVPixelBufferLockBaseAddress(destination, .readOnly)
    let converted = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(destination, 1)).assumingMemoryBound(to: UInt8.self)
    for (block, expected) in [16, 72, 128, 184, 240].enumerated() { XCTAssertEqual(Int(converted[block * 64 + 32]), expected) }
    CVPixelBufferUnlockBaseAddress(destination, .readOnly)
    try converter.convert(source, sourceRange: .video, into: destination)
    CVPixelBufferLockBaseAddress(destination, .readOnly)
    let unchanged = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(destination, 1)).assumingMemoryBound(to: UInt8.self)
    for (block, expected) in codes.enumerated() { XCTAssertEqual(unchanged[block * 64 + 32], expected) }
    CVPixelBufferUnlockBaseAddress(destination, .readOnly)
    XCTAssertEqual(converter.budget.snapshot().bytes, 0, "Completed submissions release all source/output/parameter leases")
  }

  private func makeConverter() throws -> PlanarRecordingConverter {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 required") }
    return try PlanarRecordingConverter(device: device)
  }

  private func image(_ type: OSType) throws -> CVPixelBuffer {
    try CPUMemoryPixelFormatRegistration.ensure(type)
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 320, 64, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
       kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary, &image), kCVReturnSuccess)
    return try XCTUnwrap(image)
  }

  private func fill(_ image: CVPixelBuffer, codes: [UInt16], neutral: UInt16) throws {
    CVPixelBufferLockBaseAddress(image, []); defer { CVPixelBufferUnlockBaseAddress(image, []) }
    let sixteen = [OSType(0x50323136), OSType(0x50413136)].contains(CVPixelBufferGetPixelFormatType(image))
    for plane in 0..<2 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane), rows = CVPixelBufferGetHeightOfPlane(image, plane)
      memset(base, 0xA5, stride * rows)
      for row in 0..<rows { for column in 0..<320 {
        let code = plane == 0 ? codes[column / 64] : neutral
        if sixteen { base.storeBytes(of: code, toByteOffset: row * stride + column * 2, as: UInt16.self) }
        else { base.storeBytes(of: UInt8(code), toByteOffset: row * stride + column, as: UInt8.self) }
      } }
    }
  }

  private func check(_ image: CVPixelBuffer, expected: [UInt16], neutral: UInt16) throws {
    CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let sixteen = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    for plane in 0..<2 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      for row in 0..<CVPixelBufferGetHeightOfPlane(image, plane) { for column in 0..<320 {
        let value = sixteen ? base.load(fromByteOffset: row * stride + column * 2, as: UInt16.self) : UInt16(base.load(fromByteOffset: row * stride + column, as: UInt8.self))
        XCTAssertEqual(value, plane == 0 ? expected[column / 64] : neutral)
      } }
    }
  }

  private final class Encoded: @unchecked Sendable { var sample: CMSampleBuffer?; var status: OSStatus = noErr }
  private func encode(_ image: CVPixelBuffer, codec: CMVideoCodecType, profile: CFString?) throws {
    let state = Encoded()
    var encoder: VTCompressionSession?
    XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: 320, height: 64, codecType: codec,
      encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
      imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(image)] as CFDictionary,
      compressedDataAllocator: nil, outputCallback: { refcon, _, status, _, sample in
        let state = Unmanaged<Encoded>.fromOpaque(refcon!).takeUnretainedValue(); state.status = status; state.sample = sample
      }, refcon: Unmanaged.passUnretained(state).toOpaque(), compressionSessionOut: &encoder), noErr)
    let session = try XCTUnwrap(encoder); defer { VTCompressionSessionInvalidate(session) }
    if let profile { XCTAssertEqual(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile), noErr) }
    XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(session), noErr)
    let pool = try XCTUnwrap(VTCompressionSessionGetPixelBufferPool(session))
    let attributes = try XCTUnwrap(CVPixelBufferPoolGetPixelBufferAttributes(pool)) as NSDictionary
    let accepted = (attributes[kCVPixelBufferPixelFormatTypeKey] as? [NSNumber])?.map(\.uint32Value) ??
      (attributes[kCVPixelBufferPixelFormatTypeKey] as? NSNumber).map { [$0.uint32Value] } ?? []
    XCTAssertEqual(accepted, [CVPixelBufferGetPixelFormatType(image)], "Encoder's native pool must use exactly the requested layout")
    XCTAssertEqual(VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: .zero,
      duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
    XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
    XCTAssertEqual(state.status, noErr)
    let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(XCTUnwrap(state.sample)))
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), codec)
  }
}
