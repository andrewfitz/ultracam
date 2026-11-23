import CoreMedia
import CoreVideo
import Foundation
import libaom
import ProgramAV1
import XCTest

final class ProgramAV1Tests: XCTestCase {
  func testDecodedUHD60SequenceHasCorrectIdentityTimingAndColor() throws {
    try roundTrip(width: 3840, height: 2160, step: CMTime(value: 1, timescale: 60))
  }

  func testFractionalRateAndForcedKeyOnLiveGap() throws {
    try roundTrip(width: 320, height: 180, step: CMTime(value: 1001, timescale: 30_000))
  }

  func testRejectsChangedFormatAndNonIncreasingTime() throws {
    let step = CMTime(value: 1, timescale: 30)
    let encoder = try ProgramAV1Encoder(width: 128, height: 128, frameDuration: step, bitrate: 200_000)
    let frame = try input(128, 128, y: 100, pts: .zero, duration: step)
    _ = try encoder.encode(frame)
    XCTAssertThrowsError(try encoder.encode(frame))
    XCTAssertThrowsError(try encoder.encode(input(64, 128, y: 200, pts: step, duration: step)))
    XCTAssertThrowsError(try ProgramAV1Encoder(width: 127, height: 128, frameDuration: step, bitrate: 200_000))
  }

  func testEquivalentDurationCanStartTheEncoder() throws {
    let step = CMTime(value: 36_000_000, timescale: 1_080_000_000)
    let encoder = try ProgramAV1Encoder(width: 128, height: 128, frameDuration: step, bitrate: 200_000)
    let canonicalDuration = CMTime(value: 1, timescale: 30)
    let frame = try input(128, 128, y: 100, pts: .zero, duration: canonicalDuration)
    XCTAssertEqual(try encoder.encode(frame).duration, canonicalDuration)
  }

  func testRejectsTimestampThatRoundsToAnAlreadyEncodedSlot() throws {
    let step = CMTime(value: 1, timescale: 30)
    let encoder = try ProgramAV1Encoder(width: 128, height: 128, frameDuration: step, bitrate: 200_000)
    _ = try encoder.encode(input(128, 128, y: 100, pts: .zero, duration: step))
    let duplicateSlot = try input(128, 128, y: 175, pts: CMTime(value: 1, timescale: 120), duration: step)
    XCTAssertThrowsError(try encoder.encode(duplicateSlot)) { error in
      guard case ProgramAV1Error.invalidInput = error else { return XCTFail("Expected invalid input, received \(error)") }
    }
    let next = try input(128, 128, y: 110, pts: step, duration: step)
    XCTAssertEqual(try encoder.encode(next).presentationTimeStamp, step)
  }

  func testRejectsUndersizedNV12PlanesBeforeEncoding() throws {
    let width = 128, height = 128
    let duration = CMTime(value: 1, timescale: 30)
    let encoder = try ProgramAV1Encoder(width: width, height: height, frameDuration: duration, bitrate: 200_000)
    let lumaBytes = width * height
    let byteCount = lumaBytes + lumaBytes / 2
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
    defer { bytes.deallocate() }
    memset(bytes, 128, byteCount)
    for (plane, shortWidth) in [(0, true), (0, false), (1, true), (1, false)] {
      var addresses: [UnsafeMutableRawPointer?] = [bytes, bytes.advanced(by: lumaBytes)]
      var widths = [width, width / 2]
      var heights = [height, height / 2]
      var strides = [width, width]
      if shortWidth { widths[plane] -= 1 }
      else { heights[plane] -= 1 }
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreateWithPlanarBytes(nil, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bytes, byteCount, 2, &addresses, &widths,
        &heights, &strides, nil, nil, nil, &image), kCVReturnSuccess)
      let frame = try sample(XCTUnwrap(image), pts: .zero, duration: duration)
      XCTAssertThrowsError(try encoder.encode(frame)) { error in
        guard case ProgramAV1Error.invalidInput = error else { return XCTFail("Expected invalid input, received \(error)") }
      }
    }
    XCTAssertEqual(try encoder.encode(input(width, height, y: 100, pts: .zero, duration: duration)).presentationTimeStamp, .zero)
  }

  private func roundTrip(width: Int, height: Int, step: CMTime) throws {
    let encoder = try ProgramAV1Encoder(width: width, height: height, frameDuration: step, bitrate: 20_000_000)
    var decoded = aom_codec_ctx_t()
    var cfg = aom_codec_dec_cfg_t()
    cfg.threads = 4
    XCTAssertEqual(aom_codec_dec_init_ver(&decoded, aom_codec_av1_dx(), &cfg, 0, AOM_DECODER_ABI_VERSION), AOM_CODEC_OK)
    defer { aom_codec_destroy(&decoded) }
    let start = CMTime(value: 123_456_789, timescale: 30_000)
    var encoded: [CMSampleBuffer] = []
    for index in 0..<4 {
      let offset = index == 3 ? CMTime(seconds: 3, preferredTimescale: 30_000) : CMTimeMultiply(step, multiplier: Int32(index))
      let pts = CMTimeAdd(start, offset)
      let packet = try encoder.encode(input(width, height, y: UInt8(40 + 30 * index), pts: pts, duration: step))
      XCTAssertEqual(packet.presentationTimeStamp, pts)
      XCTAssertEqual(packet.duration, step)
      let format = try XCTUnwrap(packet.formatDescription)
      XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_AV1)
      let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data])
      let record = try XCTUnwrap(atoms["av1C"])
      XCTAssertEqual(record.first, 0x81)
      XCTAssertGreaterThan(record.count, 6)
      XCTAssertEqual(record[2] & 0x7f, 0x0c)
      let attachments = CMSampleBufferGetSampleAttachmentsArray(packet, createIfNecessary: true) as? [[String: Any]]
      XCTAssertEqual((attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false, (1...2).contains(index))
      encoded.append(packet)
    }
    // Decode only after all encodes so accidental references into libaom's reused output
    // memory would corrupt the earliest samples.
    for (index, packet) in encoded.enumerated() {
      let block = try XCTUnwrap(packet.dataBuffer)
      var size = 0, total = 0
      var pointer: UnsafeMutablePointer<Int8>?
      XCTAssertEqual(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &size, totalLengthOut: &total,
        dataPointerOut: &pointer), noErr)
      let bytes = UnsafeRawPointer(try XCTUnwrap(pointer)).assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(size, total)
      XCTAssertEqual(aom_codec_decode(&decoded, bytes, size, nil), AOM_CODEC_OK)
      var iterator: aom_codec_iter_t?
      let pixels = try XCTUnwrap(aom_codec_get_frame(&decoded, &iterator)).pointee
      XCTAssertEqual(Int(pixels.d_w), width)
      XCTAssertEqual(Int(pixels.d_h), height)
      XCTAssertEqual(pixels.cp, AOM_CICP_CP_BT_709)
      XCTAssertEqual(pixels.tc, AOM_CICP_TC_BT_709)
      XCTAssertEqual(pixels.mc, AOM_CICP_MC_BT_709)
      XCTAssertEqual(pixels.range, AOM_CR_STUDIO_RANGE)
      XCTAssertEqual(Int(pixels.planes.0![Int(pixels.stride.0) * (height / 2) + width / 2]), 40 + 30 * index, accuracy: 3)
      XCTAssertEqual(Int(pixels.planes.1![width / 4]), 86, accuracy: 3)
      XCTAssertEqual(Int(pixels.planes.2![width / 4]), 180, accuracy: 3)
    }
  }

  private func input(_ width: Int, _ height: Int, y: UInt8, pts: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    var storage: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage), kCVReturnSuccess)
    let image = try XCTUnwrap(storage)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
    memset(CVPixelBufferGetBaseAddressOfPlane(image, 0), Int32(y), CVPixelBufferGetBytesPerRowOfPlane(image, 0) * height)
    let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 1)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
    for row in 0..<(height / 2) {
      for column in 0..<(width / 2) { uv[row * stride + column * 2] = 86; uv[row * stride + column * 2 + 1] = 180 }
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    return try sample(image, pts: pts, duration: duration)
  }

  private func sample(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
      formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try XCTUnwrap(sample)
  }
}
