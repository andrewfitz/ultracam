import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
import XCTest

private final class RecordingRGBEncodedFrame: @unchecked Sendable {
  var sample: CMSampleBuffer?
  var image: CVPixelBuffer?
  var status: OSStatus = noErr
}

@objcMembers final class RecordingRGBEncoderConformanceChecks: XCTestCase {
  private func image(_ type: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
    var output: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
      &output), kCVReturnSuccess)
    return try XCTUnwrap(output)
  }

  private func roundTrip(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
    let state = RecordingRGBEncodedFrame()
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: nil, width: Int32(CVPixelBufferGetWidth(input)),
      height: Int32(CVPixelBufferGetHeight(input)), codecType: kCMVideoCodecType_AppleProRes4444,
      encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
      imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: RecordingRGBPixelConverter.outputPixelFormat] as CFDictionary,
      compressedDataAllocator: nil, outputCallback: { refcon, _, status, _, sample in
        let state = Unmanaged<RecordingRGBEncodedFrame>.fromOpaque(refcon!).takeUnretainedValue()
        state.status = status; state.sample = sample
      }, refcon: Unmanaged.passUnretained(state).toOpaque(), compressionSessionOut: &session)
    XCTAssertEqual(status, noErr)
    let encoder = try XCTUnwrap(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    for (key, value) in [
      (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
      (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    ] { XCTAssertEqual(VTSessionSetProperty(encoder, key: key, value: value), noErr) }
    XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(encoder), noErr)
    XCTAssertEqual(VTCompressionSessionEncodeFrame(encoder, imageBuffer: input,
      presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 30), frameProperties: nil,
      sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
    XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
    XCTAssertEqual(state.status, noErr)
    let sample = try XCTUnwrap(state.sample)
    let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_AppleProRes4444)
    var decoder: VTDecompressionSession?
    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
      let state = Unmanaged<RecordingRGBEncodedFrame>.fromOpaque(refcon!).takeUnretainedValue()
      state.status = status; state.image = image
    }, decompressionOutputRefCon: Unmanaged.passUnretained(state).toOpaque())
    XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
      decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
      outputCallback: &callback, decompressionSessionOut: &decoder), noErr)
    let decode = try XCTUnwrap(decoder)
    defer { VTDecompressionSessionInvalidate(decode) }
    XCTAssertEqual(VTDecompressionSessionDecodeFrame(decode, sampleBuffer: sample, flags: [],
      frameRefcon: nil, infoFlagsOut: nil), noErr)
    XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(decode), noErr)
    XCTAssertEqual(state.status, noErr)
    return try XCTUnwrap(state.image)
  }

  func testBGRAFullRangeRepackAndActualProRes4444ColorRoundTrip() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    let colors: [[UInt8]] = [[0, 0, 0], [255, 255, 255], [0, 0, 255], [0, 255, 0], [255, 0, 0]]
    let source = try image(kCVPixelFormatType_32BGRA, width: 320, height: 64)
    let output = try image(RecordingRGBPixelConverter.outputPixelFormat, width: 320, height: 64)
    CVPixelBufferLockBaseAddress(source, [])
    let input = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<64 { for x in 0..<320 {
      let offset = y * CVPixelBufferGetBytesPerRow(source) + x * 4
      for c in 0..<3 { input[offset + c] = colors[x / 64][c] }
      input[offset + 3] = 17
    } }
    CVPixelBufferUnlockBaseAddress(source, [])
    try converter.convert(source, format: .bgra8, sourceRange: .full, into: output)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    let expanded = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
    for block in 0..<5 {
      let offset = 32 * CVPixelBufferGetBytesPerRow(output) / 2 + (block * 64 + 32) * 4
      XCTAssertEqual(expanded[offset], UInt16(colors[block][2]) * 257)
      XCTAssertEqual(expanded[offset + 1], UInt16(colors[block][1]) * 257)
      XCTAssertEqual(expanded[offset + 2], UInt16(colors[block][0]) * 257)
      XCTAssertEqual(expanded[offset + 3], 65535)
    }
    CVPixelBufferUnlockBaseAddress(output, .readOnly)
    let decoded = try roundTrip(output)
    CVPixelBufferLockBaseAddress(decoded, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded)).assumingMemoryBound(to: UInt8.self)
    for block in 0..<5 {
      let offset = 32 * CVPixelBufferGetBytesPerRow(decoded) + (block * 64 + 32) * 4
      for c in 0..<3 { XCTAssertEqual(Int(pixels[offset + c]), Int(colors[block][c]), accuracy: 3, "block \(block), BGRA component \(c)") }
    }
  }

  func testR210VideoRangeLegalBlackWhiteAndClippedHeadroomRoundTrip() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    let codes = [0, 64, 502, 940, 1023]
    let source = try image(0x72323130, width: 320, height: 64)
    let output = try image(RecordingRGBPixelConverter.outputPixelFormat, width: 320, height: 64)
    CVPixelBufferLockBaseAddress(source, [])
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<64 { for x in 0..<320 {
      let code = UInt32(codes[x / 64]); let word = code << 20 | code << 10 | code
      let offset = y * CVPixelBufferGetBytesPerRow(source) + x * 4
      for c in 0..<4 { bytes[offset + c] = UInt8(truncatingIfNeeded: word >> (24 - c * 8)) }
    } }
    CVPixelBufferUnlockBaseAddress(source, [])
    try converter.convert(source, format: .r210, sourceRange: .video, into: output)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    let samples = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
    for block in 0..<5 {
      let expected = UInt16((max(0, min(876, codes[block] - 64)) * 65535 + 438) / 876)
      let offset = 32 * CVPixelBufferGetBytesPerRow(output) / 2 + (block * 64 + 32) * 4
      for c in 0..<3 { XCTAssertEqual(samples[offset + c], expected) }
    }
    CVPixelBufferUnlockBaseAddress(output, .readOnly)
    let decoded = try roundTrip(output)
    CVPixelBufferLockBaseAddress(decoded, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded)).assumingMemoryBound(to: UInt8.self)
    for (block, expected) in [0, 0, 128, 255, 255].enumerated() {
      let offset = 32 * CVPixelBufferGetBytesPerRow(decoded) + (block * 64 + 32) * 4
      for c in 0..<3 { XCTAssertEqual(Int(pixels[offset + c]), expected, accuracy: 3, "r210 block \(block)") }
    }
  }
}
