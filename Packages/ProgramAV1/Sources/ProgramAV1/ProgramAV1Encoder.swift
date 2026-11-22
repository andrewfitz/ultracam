import CProgramAV1
import CoreMedia
import CoreVideo
import Foundation

public enum ProgramAV1Error: Error {
  case invalidSettings, invalidInput, initializationFailed, encodeFailed, invalidSequenceHeader
  case coreMedia(OSStatus)
}

/// Serial low-delay libaom encoder. Input frames are video-range NV12. Each returned sample
/// owns its compressed payload and carries the AV1 configuration record for Enhanced RTMP.
public final class ProgramAV1Encoder {
  private let context: OpaquePointer
  private let width: Int
  private let height: Int
  private let frameDuration: CMTime
  private var format: CMVideoFormatDescription?
  private var origin: CMTime?
  private var lastSlot: Int64 = -1

  public init(width: Int, height: Int, frameDuration: CMTime, bitrate: Int,
              keyframeInterval: Double = 2) throws {
    guard (2...8192).contains(width), (2...8192).contains(height), width.isMultiple(of: 2),
      height.isMultiple(of: 2), width * height <= 16_777_216,
      frameDuration.isNumeric, frameDuration.epoch == 0, (1.0 / 240...1.0).contains(frameDuration.seconds),
      (1_000...1_000_000_000).contains(bitrate), (0.1...60).contains(keyframeInterval) else {
      throw ProgramAV1Error.invalidSettings
    }
    // Core Media accepts unreduced times, including denominators beyond libaom's limit.
    var divisor = frameDuration.value
    var remainder = Int64(frameDuration.timescale)
    while remainder != 0 {
      (divisor, remainder) = (remainder, divisor % remainder)
    }
    let denominator = Int32(Int64(frameDuration.timescale) / divisor)
    guard denominator <= 1_000_000_000 else { throw ProgramAV1Error.invalidSettings }
    let numerator = Int32(frameDuration.value / divisor)
    let threads = max(1, min(16, ProcessInfo.processInfo.activeProcessorCount))
    guard let context = uc_av1_create(Int32(width), Int32(height), Int32(bitrate / 1000), Int32(threads),
      numerator, denominator, Int32(ceil(keyframeInterval / frameDuration.seconds))) else {
      throw ProgramAV1Error.initializationFailed
    }
    self.frameDuration = CMTime(value: Int64(numerator), timescale: denominator)
    self.context = context
    self.width = width
    self.height = height
  }

  deinit { uc_av1_destroy(context) }

  public func encode(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
    let pts = sample.presentationTimeStamp
    let duration = sample.duration
    guard pts.isNumeric, pts.epoch == 0,
      duration.isNumeric, duration.epoch == 0, duration > .zero,
      let image = sample.imageBuffer, CVPixelBufferGetWidth(image) == width,
      CVPixelBufferGetHeight(image) == height, CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      CVPixelBufferGetPlaneCount(image) == 2 else { throw ProgramAV1Error.invalidInput }
    let offset = CMTimeSubtract(pts, origin ?? pts)
    let nominal = CMTimeMultiplyByRatio(offset, multiplier: frameDuration.timescale, divisor: Int32(frameDuration.value))
    let nativePTS = CMTimeConvertScale(nominal, timescale: 1, method: .roundHalfAwayFromZero)
    // libaom sees frame slots, so two increasing source timestamps can still repeat a slot.
    guard duration == frameDuration, nativePTS.isNumeric, nativePTS.value > lastSlot,
      CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw ProgramAV1Error.invalidInput }
    let packet: UCAV1Packet
    do {
      defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
      guard let y = CVPixelBufferGetBaseAddressOfPlane(image, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(image, 1),
        let yStride = Int32(exactly: CVPixelBufferGetBytesPerRowOfPlane(image, 0)),
        let uvStride = Int32(exactly: CVPixelBufferGetBytesPerRowOfPlane(image, 1)) else { throw ProgramAV1Error.invalidInput }
      var output = UCAV1Packet()
      guard uc_av1_encode(context, y.assumingMemoryBound(to: UInt8.self), yStride,
        uv.assumingMemoryBound(to: UInt8.self), uvStride, nativePTS.value, 1, &output) == 1 else {
        throw ProgramAV1Error.encodeFailed
      }
      packet = output
    }
    origin = origin ?? pts
    lastSlot = nativePTS.value
    guard let bytes = packet.bytes, packet.count > 0 else { throw ProgramAV1Error.encodeFailed }
    if format == nil {
      guard packet.keyframe != 0 else { throw ProgramAV1Error.invalidSequenceHeader }
      let record = try Self.configurationRecord(in: UnsafeBufferPointer(start: bytes, count: packet.count))
      let extensions: [CFString: Any] = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": record],
        kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCMFormatDescriptionExtension_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCMFormatDescriptionExtension_FullRangeVideo: false
      ]
      try Self.check(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AV1, width: Int32(width),
        height: Int32(height), extensions: extensions as CFDictionary, formatDescriptionOut: &format))
    }
    var block: CMBlockBuffer?
    try Self.check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: packet.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: packet.count,
      flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block))
    guard let block, let format else { throw ProgramAV1Error.encodeFailed }
    try Self.check(CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet.count))
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: pts)
    var size = packet.count
    var compressed: CMSampleBuffer?
    try Self.check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &compressed))
    guard let compressed else { throw ProgramAV1Error.encodeFailed }
    if packet.keyframe == 0 {
      guard let attachments = CMSampleBufferGetSampleAttachmentsArray(compressed, createIfNecessary: true),
        let value = CFArrayGetValueAtIndex(attachments, 0) else { throw ProgramAV1Error.encodeFailed }
      let dictionary = unsafeBitCast(value, to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return compressed
  }

  private static func check(_ status: OSStatus) throws {
    if status != noErr { throw ProgramAV1Error.coreMedia(status) }
  }

  /// AV1 ISOBMFF AV1CodecConfigurationRecord from the encoder's first sequence_header_obu.
  /// libaom's realtime, non-still sequence uses no timing_info and an 8-bit Main 4:2:0 profile.
  private static func configurationRecord(in bytes: UnsafeBufferPointer<UInt8>) throws -> Data {
    var offset = 0
    while offset < bytes.count {
      let obuStart = offset
      let header = bytes[offset]
      offset += 1
      guard header & 0x83 == 0x02 else { throw ProgramAV1Error.invalidSequenceHeader }
      if header & 0x04 != 0 { offset += 1 }
      var payloadSize = 0
      var terminated = false
      for index in 0..<8 where offset < bytes.count {
        let next = bytes[offset]
        offset += 1
        payloadSize |= Int(next & 0x7f) << (7 * index)
        if next & 0x80 == 0 { terminated = true; break }
      }
      guard terminated, payloadSize <= bytes.count - offset else { throw ProgramAV1Error.invalidSequenceHeader }
      let end = offset + payloadSize
      if (header >> 3) & 0x0f == 1 {
        var bit = offset * 8
        func read(_ count: Int) throws -> UInt8 {
          guard bit + count <= end * 8 else { throw ProgramAV1Error.invalidSequenceHeader }
          var value: UInt8 = 0
          for _ in 0..<count {
            value = (value << 1) | ((bytes[bit / 8] >> (7 - bit % 8)) & 1)
            bit += 1
          }
          return value
        }
        let profile = try read(3)
        guard profile == 0, try read(1) == 0, try read(1) == 0, try read(1) == 0 else {
          throw ProgramAV1Error.invalidSequenceHeader
        }
        // initial_display_delay_present_flag, operating_points_cnt_minus_1, operating_point_idc[0].
        bit += 18
        let level = try read(5)
        let tier = level > 7 ? try read(1) : 0
        var record = Data([0x81, (profile << 5) | level, (tier << 7) | 0x0c, 0])
        record.append(bytes.baseAddress!.advanced(by: obuStart), count: end - obuStart)
        return record
      }
      offset = end
    }
    throw ProgramAV1Error.invalidSequenceHeader
  }
}
